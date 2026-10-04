variable "proxmox_node" {
  description = "Proxmox node on which the VMs are created"
  type        = string
}

variable "datastore_id" {
  description = "Proxmox datastore for Talos VM disks"
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Proxmox network bridge"
  type        = string
  default     = "vmbr0"
}

variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
}

variable "ssh_admin_user" {
  description = "Username created on every node via cloud-init, with passwordless sudo and the Terraform-managed SSH key as its only auth method. modules/rke2-cluster uses this account to poll readiness and fetch the kubeconfig; nothing else needs interactive SSH access as a matter of course."
  type        = string
  default     = "rke2admin"
}

variable "template_vm_id_common" {
  description = "Proxmox template ID cloned by nodes without a pcigpu. Built by packer/ubuntu-common.pkr.hcl; see packer/README.md."
  type        = number
  default     = 9100
}

variable "template_vm_id_gpu" {
  description = "Proxmox template ID cloned by nodes with a pcigpu set. Built by packer/ubuntu-gpu.pkr.hcl; see packer/README.md."
  type        = number
  default     = 9101
}

variable "api_wait_timeout" {
  description = "Seconds to poll the bootstrap node over SSH for an active rke2-server before giving up, when wait_for_api is on"
  type        = number
  default     = 300
}

variable "api_wait_interval" {
  description = "Seconds between polls, when wait_for_api is on"
  type        = number
  default     = 5
}

variable "gateway" {
  description = "Default network gateway"
  type        = string
}

variable "nameservers" {
  description = "DNS servers"
  type        = list(string)
}

variable "controlplane_vip" {
  description = "Floating IP kube-vip advertises for the API server (ARP mode, run as an RKE2 auto-deployed manifest on the control-plane node). Kept as a stable endpoint distinct from any one node's own IP, the same property Talos's Layer2VIPConfig gave this cluster, ready for a second control-plane node later without reconfiguring every client."
  type        = string
  default     = "192.168.1.99"
}

variable "external_ip" {
  description = "Public IP address or hostname a router NATs through to controlplane_vip, so the cluster can be reached from outside the LAN. Added to the control-plane's RKE2 tls-san; the NAT rule itself is configured on the router, not by Terraform. Leave null (the default) to keep the cluster LAN-only."
  type        = string
  default     = "91.152.206.161"
}

variable "cni" {
  description = "Cluster CNI. cilium sets cni: none and disable-kube-proxy: true in every node's RKE2 config (see modules/rke2-config) and installs Cilium in their place."
  type        = string
  default     = "cilium"

  validation {
    condition     = contains(["flannel", "cilium"], var.cni)
    error_message = "cni must be either flannel or cilium."
  }
}

variable "cluster_cidr" {
  description = "Pod network CIDR, passed to modules/rke2-config and written into the control-plane's RKE2 config.yaml as cluster-cidr. Cilium's ipam.mode = \"kubernetes\" (module.cilium) hands out pod IPs per node from whatever RKE2 allocates here, so no other module needs this value."
  type        = string
  default     = "1.1.0.0/16"
}

variable "service_cidr" {
  description = "ClusterIP service CIDR, passed to modules/rke2-config and written into the control-plane's RKE2 config.yaml as service-cidr. Must stay clear of cluster_cidr and of every node/VIP address on the LAN (192.168.1.0/24 here)."
  type        = string
  default     = "2.2.0.0/16"
}

variable "cilium_version" {
  description = "Cilium Helm chart version"
  type        = string
  default     = "1.19.6"
}

variable "enable_hubble_ui" {
  description = "Install Hubble Relay + Hubble UI behind Cilium, giving a web dashboard of live CNI traffic (service map, policy verdicts, DNS, L7 flows). Touches no machine configuration and needs no reboot, so it defaults on. Ignored when cni != \"cilium\"."
  type        = bool
  default     = true
}

variable "hubble_ui_service_type" {
  description = "Kubernetes Service type Hubble UI's web UI is exposed as. ClusterIP (the default): the LB-IPAM pool comes later from k8s-infra, and k8s-infra's lb-services chart puts a LoadBalancer Service in front of Hubble UI once it exists."
  type        = string
  default     = "ClusterIP"
}

variable "wait_for_api" {
  description = "Poll the bootstrap node over SSH until rke2-server is active, then fetch its kubeconfig, before installing addons. Turn off to plan against a cluster that is down."
  type        = bool
  default     = true
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version; see modules/argocd"
  type        = string
  default     = "8.3.0"
}

variable "argocd_apps_chart_version" {
  description = "argocd-apps Helm chart version; see modules/argocd"
  type        = string
  default     = "2.0.2"
}

variable "k8s_infra_repo_url" {
  description = "Git repository Argo CD reconciles cluster addons from"
  type        = string
  default     = "https://github.com/ykantoni/k8s-infra.git"
}

variable "k8s_apps_repo_url" {
  description = "Git repository Argo CD reconciles applications from"
  type        = string
  default     = "https://github.com/ykantoni/k8s-apps.git"
}

variable "gitops_target_revision" {
  description = "Branch, tag or commit Argo CD tracks in both k8s-infra and k8s-apps"
  type        = string
  default     = "main"
}

variable "sealed_secrets_key_file" {
  description = "Backup of the Sealed Secrets controller's key pair on the machine running Terraform (the self-hosted runner), restored on every build so committed SealedSecrets keep decrypting. Written by `just seal-key-backup` after the first build; never committed. See modules/argocd/README.md."
  type        = string
  default     = "/var/lib/terraform/sealed-secrets-key.yaml"
}

variable "nodes" {
  description = "Cluster nodes"

  type = map(object({
    vm_id = number
    name  = string
    ip    = string
    cidr  = optional(number, 24)
    mac   = string
    role  = string

    pcigpu = optional(string, null)
    cores  = optional(number, 4)
    memory = optional(number, 4096)
    disk   = optional(number, 32)
  }))

  validation {
    condition = alltrue([
      for node in values(var.nodes) :
      contains(["controlplane", "worker"], node.role)
    ])

    error_message = "role must be either controlplane or worker."
  }
}