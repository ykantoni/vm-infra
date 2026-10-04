locals {
  controlplanes = {
    for key, node in var.nodes :
    key => node
    if node.role == "controlplane"
  }

  workers = {
    for key, node in var.nodes :
    key => node
    if node.role == "worker"
  }

  controlplane_ips = [
    for node in values(local.controlplanes) :
    node.ip
  ]

  ssh_key_path = "${path.module}/.ssh_key_${md5(var.ssh_private_key_pem)}"

  kubeconfig_raw_path = var.kubeconfig_raw_path != "" ? var.kubeconfig_raw_path : "${path.module}/.kubeconfig_raw"
}

# The private key never appears in state on its own here (it's an input
# variable, already stored in state by modules/rke2-config regardless), but
# local-exec's ssh/scp need it as a file. Written under path.module, not
# /tmp, so it doesn't collide with anything else and is cleaned up by
# terraform_data's own lifecycle rather than left behind.
resource "local_sensitive_file" "ssh_key" {
  filename        = local.ssh_key_path
  content         = var.ssh_private_key_pem
  file_permission = "0600"
}

# Cloud-init + RKE2's own install/start is asynchronous after the VM boots
# (unlike Talos's talos_machine_bootstrap, which is a synchronous API call),
# so this is the first real gate: poll over SSH until the bootstrap node's
# rke2-server unit is active. Narrower and faster than waiting for the full
# API to answer, and doesn't need a token/kubeconfig -- just SSH reachability.
resource "terraform_data" "wait_for_rke2_server" {
  count = var.wait_for_api ? 1 : 0

  # Forces this to run on every apply, not just on creation -- otherwise,
  # once this resource exists in state, Terraform considers it permanently
  # satisfied and never reruns its provisioner again, even after a later
  # apply destroys and recreates the bootstrap node itself (e.g. a
  # cluster-cidr/service-cidr change forces cp1 to be replaced). Without
  # this, downstream dependents (module.cilium, module.argocd) would see an
  # "unchanged" rke2_cluster module and proceed immediately, racing the new
  # VM's own RKE2/kube-vip startup.
  triggers_replace = [timestamp()]

  depends_on = [
    local_sensitive_file.ssh_key,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      end=$(( $(date +%s) + ${var.api_wait_timeout} ))
      until ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=5 -i "${local.ssh_key_path}" \
          "${var.ssh_admin_user}@${var.bootstrap_ip}" \
          "systemctl is-active --quiet rke2-server" >/dev/null 2>&1; do
        if [ "$(date +%s)" -ge "$end" ]; then
          echo "rke2-server on ${var.bootstrap_ip} was not active within ${var.api_wait_timeout}s" >&2
          exit 1
        fi
        sleep ${var.api_wait_interval}
      done
    EOT
  }
}

# Fetches RKE2's own kubeconfig from the bootstrap node and rewrites its
# embedded "server: https://127.0.0.1:6443" to the VIP, so the file this
# module hands back is immediately usable by clients outside that one node
# -- the same role talos_cluster_kubeconfig plays today, just over SSH
# instead of the talos provider's API.
resource "terraform_data" "fetch_kubeconfig" {
  count = var.wait_for_api ? 1 : 0

  # See wait_for_rke2_server above: always rerun, not just on creation.
  triggers_replace = [timestamp()]

  depends_on = [
    terraform_data.wait_for_rke2_server,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      mkdir -p "$(dirname "${local.kubeconfig_raw_path}")"
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i "${local.ssh_key_path}" \
        "${var.ssh_admin_user}@${var.bootstrap_ip}" \
        "sudo cat /etc/rancher/rke2/rke2.yaml" \
        | sed "s#https://127.0.0.1:6443#https://${var.controlplane_vip}:6443#" \
        > "${local.kubeconfig_raw_path}"
      chmod 600 "${local.kubeconfig_raw_path}"
    EOT
  }
}

# rke2-server reporting active (wait_for_rke2_server) only means the local
# process on the bootstrap node started -- it says nothing about the VIP,
# which kube-vip only starts advertising once its own pod is scheduled,
# image-pulled, started, and has won leader election. Every consumer of this
# module's kubeconfig (helm/kubernetes providers, Cilium, Argo CD) talks to
# the VIP specifically (fetch_kubeconfig rewrites the server URL to it), so
# without this gate the first of them to run would race kube-vip's own
# startup: "dial tcp <vip>:6443: connect: no route to host", transient and
# gone by the time anyone checks manually a few seconds later.
resource "terraform_data" "wait_for_vip" {
  count = var.wait_for_api ? 1 : 0

  # See wait_for_rke2_server above: always rerun, not just on creation.
  triggers_replace = [timestamp()]

  depends_on = [
    terraform_data.fetch_kubeconfig,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      end=$(( $(date +%s) + ${var.api_wait_timeout} ))
      until curl -sk --max-time 5 -o /dev/null "https://${var.controlplane_vip}:6443/version"; do
        if [ "$(date +%s)" -ge "$end" ]; then
          echo "VIP ${var.controlplane_vip}:6443 was not reachable within ${var.api_wait_timeout}s" >&2
          exit 1
        fi
        sleep ${var.api_wait_interval}
      done
    EOT
  }
}

# A lone control-plane node is also the only etcd member: replacing it (e.g.
# a cluster-cidr/service-cidr change forces cp1 to be recreated) produces an
# entirely new cluster -- fresh CA, fresh token validation -- even though it
# keeps the same name and IP. Existing workers are untouched by that replace
# (nothing about their own cloud-init changed), so they keep running
# rke2-agent against what is, from their point of view, an impostor server:
# "certificate signed by unknown authority", permanently, since RKE2 pins
# the server's CA on first join and never re-trusts a different one.
#
# Detect that by comparing each worker's pinned CA against the current
# cluster's (already fetched into kubeconfig_raw_path above) and only reset
# the ones that actually mismatch -- an unaffected apply (most of them)
# finds every worker already pinned to the right CA and touches nothing.
resource "terraform_data" "resync_workers" {
  count = var.wait_for_api ? 1 : 0

  triggers_replace = [timestamp()]

  depends_on = [
    terraform_data.wait_for_vip,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      current_ca="$(grep -m1 'certificate-authority-data' "${local.kubeconfig_raw_path}" | awk '{print $2}')"
      %{for node in values(local.workers)~}
      remote_ca="$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=5 -i "${local.ssh_key_path}" \
          "${var.ssh_admin_user}@${node.ip}" \
          "sudo base64 -w0 /var/lib/rancher/rke2/agent/client-ca.crt 2>/dev/null || true")"
      if [ "$remote_ca" != "$current_ca" ]; then
        echo "CA mismatch on ${node.ip} -- resetting rke2-agent to rejoin the current cluster"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -i "${local.ssh_key_path}" \
          "${var.ssh_admin_user}@${node.ip}" \
          "sudo systemctl stop rke2-agent && sudo rm -rf /var/lib/rancher/rke2/agent && sudo systemctl start rke2-agent"
        end=$(( $(date +%s) + ${var.api_wait_timeout} ))
        until ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 -i "${local.ssh_key_path}" \
            "${var.ssh_admin_user}@${node.ip}" \
            "systemctl is-active --quiet rke2-agent" >/dev/null 2>&1; do
          if [ "$(date +%s)" -ge "$end" ]; then
            echo "rke2-agent on ${node.ip} did not come back active within ${var.api_wait_timeout}s" >&2
            exit 1
          fi
          sleep ${var.api_wait_interval}
        done
      fi
      %{endfor~}
    EOT
  }
}

data "local_file" "kubeconfig" {
  count = var.wait_for_api ? 1 : 0

  depends_on = [
    terraform_data.wait_for_vip,
    terraform_data.resync_workers,
  ]

  filename = local.kubeconfig_raw_path
}
