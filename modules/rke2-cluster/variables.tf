variable "controlplane_vip" {
  type = string
}

variable "cluster_name" {
  description = "RKE2's own generated kubeconfig hardcodes the cluster/context/user name to \"default\" -- fetch_kubeconfig rewrites every occurrence to this instead, so kubectl config current-context (and anyone merging this kubeconfig with others) shows something more meaningful than \"default\"."
  type        = string
}

variable "bootstrap_ip" {
  description = "IP of the node to SSH into for readiness polling and kubeconfig retrieval (module.rke2_config.bootstrap_ip)"
  type        = string
}

variable "ssh_admin_user" {
  type = string
}

variable "ssh_private_key_pem" {
  sensitive = true
  type      = string
}

variable "wait_for_api" {
  description = "Poll the bootstrap node over SSH until rke2-server is active, then fetch the kubeconfig. Turn off to plan against a cluster that is down."
  type        = bool
  default     = true
}

variable "api_wait_timeout" {
  type    = number
  default = 300
}

variable "api_wait_interval" {
  type    = number
  default = 5
}

variable "kubeconfig_raw_path" {
  description = "Where the fetched kubeconfig is written and read back from. Must survive between runs (it's read at plan time to configure the helm and kubernetes providers), so in CI it must live outside the checkout, which actions/checkout wipes. Empty means inside this module's directory."
  type        = string
  default     = ""
}

variable "nodes" {
  description = "module.proxmox_vm.nodes -- deliberately VM-output-derived, not the raw var.nodes, so this module's resources only run once the VMs actually exist"

  type = map(object({
    vm_id  = number
    name   = string
    ip     = string
    cidr   = number
    mac    = string
    role   = string
    pcigpu = string
  }))
}
