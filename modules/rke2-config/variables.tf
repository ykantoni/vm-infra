variable "proxmox_node" {
  type = string
}

variable "snippet_datastore_id" {
  description = "Proxmox datastore that has the \"snippets\" content type enabled, where each node's rendered cloud-init user-data is uploaded. This is a one-time, host-side Proxmox storage setting (Datacenter > Storage > <datastore> > Content), not something Terraform can turn on — the same kind of out-of-band prerequisite as the PCI resource mapping GPU nodes reference."
  type        = string
}

variable "cni" {
  description = "Cluster CNI. cilium sets cni: none and disable-kube-proxy: true in RKE2's server config, leaving both to Cilium (module.cilium). flannel leaves RKE2's own bundled Canal + kube-proxy running instead, and module.cilium must not be enabled alongside it."
  type        = string
  default     = "cilium"

  validation {
    condition     = contains(["flannel", "cilium"], var.cni)
    error_message = "cni must be either flannel or cilium."
  }
}

variable "cluster_cidr" {
  description = "Pod network CIDR, written into the control-plane's RKE2 config.yaml as cluster-cidr. Cilium's ipam.mode = \"kubernetes\" (module.cilium) delegates pod IP allocation to whatever podCIDR kube-controller-manager hands out per node from this range, so it has no CIDR of its own to keep in sync."
  type        = string
  default     = "1.1.0.0/16"
}

variable "service_cidr" {
  description = "ClusterIP service CIDR, written into the control-plane's RKE2 config.yaml as service-cidr. Must not overlap cluster_cidr or any node/VIP address on the LAN."
  type        = string
  default     = "2.2.0.0/16"
}

variable "controlplane_vip" {
  description = "Floating IP kube-vip advertises for the API server (ARP mode), written into the control-plane node's kube-vip manifest and every node's RKE2 tls-san / cluster-facing config."
  type        = string
}

variable "external_ip" {
  description = "Public IP or hostname a router NATs through to controlplane_vip. Added to the control-plane's RKE2 tls-san so its certificate validates once traffic arrives. Leave null to keep the cluster LAN-only."
  type        = string
  default     = null
}

variable "ssh_admin_user" {
  description = "Username created on every node via cloud-init, with passwordless sudo and the Terraform-managed SSH key as its only auth method. modules/rke2-cluster uses this account to poll readiness and fetch the kubeconfig."
  type        = string
  default     = "rke2admin"
}

variable "nodes" {
  type = map(object({
    vm_id = number
    name  = string
    ip    = string
    cidr  = optional(number, 24)
    mac   = string
    role  = string

    cores  = optional(number, 4)
    memory = optional(number, 4096)
    disk   = optional(number, 32)
    pcigpu = optional(string, null)
  }))

  validation {
    condition     = length([for n in values(var.nodes) : n if n.role == "controlplane"]) > 0
    error_message = "at least one node must have role = \"controlplane\"."
  }
}
