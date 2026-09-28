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

data "local_file" "kubeconfig" {
  count = var.wait_for_api ? 1 : 0

  depends_on = [
    terraform_data.fetch_kubeconfig,
  ]

  filename = local.kubeconfig_raw_path
}
