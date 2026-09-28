variable "cilium_version" {
  description = "Cilium Helm chart version"
  type        = string
  default     = "1.19.6"
}

variable "k8s_service_host" {
  description = "Address Cilium uses to reach the Kubernetes API: the kube-vip-advertised control-plane VIP, reachable independently of the CNI since kube-vip is a hostNetwork pod using ARP, not routed pod-network traffic."
  type        = string
}

variable "k8s_service_port" {
  description = "Port Cilium uses to reach the Kubernetes API"
  type        = number
  default     = 6443
}

variable "k8s_client_rate_limit" {
  description = "API server client rate limit for the Cilium agent, raised to absorb L2 announcement leader election"

  type = object({
    qps   = number
    burst = number
  })

  default = {
    qps   = 50
    burst = 100
  }
}

variable "enable_hubble_ui" {
  description = "Install Hubble Relay and Hubble UI, giving a web dashboard of live CNI traffic (service map, policy verdicts, DNS, L7). Touches no machine configuration and needs no reboot."
  type        = bool
  default     = true
}

variable "hubble_ui_service_type" {
  description = "Kubernetes Service type Hubble UI's web UI (port 80) is exposed as. ClusterIP (the default) because the LB-IPAM pool comes later, from k8s-infra via Argo CD: a LoadBalancer Service here would never get an address in time and helm_release's wait would hang. k8s-infra's lb-services chart adds a separate LoadBalancer Service for it."
  type        = string
  default     = "ClusterIP"
}

variable "cilium_extra_values" {
  description = "Extra Cilium Helm values merged over the defaults, for example to enable Hubble"
  type        = any
  default     = {}
}

variable "helm_timeout" {
  description = "Seconds to wait for the Cilium release to become ready"
  type        = number
  default     = 900
}
