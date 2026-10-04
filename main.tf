
module "rke2_config" {
  source = "./modules/rke2-config"

  proxmox_node         = var.proxmox_node
  snippet_datastore_id = var.datastore_id
  cni                  = var.cni
  controlplane_vip     = var.controlplane_vip
  external_ip          = var.external_ip
  ssh_admin_user       = var.ssh_admin_user
  cluster_cidr         = var.cluster_cidr
  service_cidr         = var.service_cidr

  nodes = var.nodes
}

module "proxmox_vm" {
  source = "./modules/proxmox-vm"

  proxmox_node = var.proxmox_node
  datastore_id = var.datastore_id
  bridge       = var.bridge
  gateway      = var.gateway
  nameservers  = var.nameservers

  template_vm_id_common = var.template_vm_id_common
  template_vm_id_gpu    = var.template_vm_id_gpu

  cloudinit_file_ids = module.rke2_config.cloudinit_file_ids

  nodes = var.nodes
}

module "rke2_cluster" {
  source = "./modules/rke2-cluster"

  controlplane_vip    = var.controlplane_vip
  bootstrap_ip        = module.rke2_config.bootstrap_ip
  ssh_admin_user      = module.rke2_config.ssh_admin_user
  ssh_private_key_pem = module.rke2_config.ssh_private_key_pem
  wait_for_api        = var.wait_for_api
  api_wait_timeout    = var.api_wait_timeout
  api_wait_interval   = var.api_wait_interval
  kubeconfig_raw_path = pathexpand("~/.kube/rke2-raw.yaml")

  nodes = module.proxmox_vm.nodes
}

# A copy for humans and kubectl (e.g. Justfile's destroy recipe). Terraform's
# own providers read module.rke2_cluster.kubeconfig directly.
resource "local_sensitive_file" "kubeconfig" {
  filename = pathexpand("~/.kube/config")
  content  = module.rke2_cluster.kubeconfig

  file_permission      = "0600"
  directory_permission = "0700"
}
