locals {
  controlplanes = {
    for key, node in var.nodes :
    key => node
    if node.role == "controlplane"
  }

  bootstrap_node = values(local.controlplanes)[0]
}

# Shared by every node so agents and the server agree on it without a
# bootstrap-order dependency: unlike RKE2's own auto-generated token (only
# readable from the server after it's already up), this is known at plan
# time and can go into every node's cloud-init in a single pass.
resource "random_password" "rke2_token" {
  length  = 48
  special = false
}

# Terraform's own key for reaching nodes over SSH after boot (readiness
# polling and kubeconfig fetch, in modules/rke2-cluster). The private key
# never touches a node; only the public half goes into cloud-init.
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "proxmox_virtual_environment_file" "cloudinit" {
  for_each = var.nodes

  content_type = "snippets"
  datastore_id = var.snippet_datastore_id
  node_name    = var.proxmox_node

  source_raw {
    file_name = "rke2-${each.key}.cloud-config.yaml"

    data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
      hostname       = each.value.name
      role           = each.value.role
      ssh_admin_user = var.ssh_admin_user
      ssh_public_key = tls_private_key.ssh.public_key_openssh

      cni              = var.cni
      rke2_token       = random_password.rke2_token.result
      bootstrap_ip     = local.bootstrap_node.ip
      controlplane_vip = var.controlplane_vip
      external_ip      = var.external_ip
      cluster_cidr     = var.cluster_cidr
      service_cidr     = var.service_cidr
    })
  }
}
