variable "namespace" {
  description = "Namespace Argo CD, its AppProjects and the k8s-infra Applications live in"
  type        = string
  default     = "argocd"
}

variable "apps_namespace" {
  description = "Namespace the k8s-apps Applications live in. Argo CD is configured to watch it (application.namespaces), and only the k8s-apps AppProject accepts Applications from it."
  type        = string
  default     = "argocd-apps"
}

variable "apps_destination_namespaces" {
  description = "Namespaces k8s-apps Applications may deploy into. Add one per new app under k8s-apps."
  type        = list(string)
  default     = ["ollama", "postgres"]
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version. Check https://github.com/argoproj/argo-helm/releases for the latest before relying on this default."
  type        = string
  default     = "8.3.0"
}

variable "argocd_apps_chart_version" {
  description = "argocd-apps Helm chart version (2.x: projects and applications as maps). Check https://github.com/argoproj/argo-helm/releases."
  type        = string
  default     = "2.0.2"
}

variable "k8s_infra_repo_url" {
  description = "Git repository root-k8s-infra syncs from"
  type        = string
}

variable "k8s_apps_repo_url" {
  description = "Git repository root-k8s-apps syncs from"
  type        = string
}

variable "target_revision" {
  description = "Branch, tag or commit both root Applications track"
  type        = string
  default     = "main"
}

variable "k8s_infra_chart_repos" {
  description = "Helm chart repositories k8s-infra's Applications may pull from, in addition to the k8s-infra repo itself"
  type        = list(string)
  default = [
    "https://bitnami-labs.github.io/sealed-secrets",
    "https://charts.longhorn.io",
    "https://kubernetes-sigs.github.io/metrics-server/",
    "https://cloudnative-pg.github.io/charts",
    "https://prometheus-community.github.io/helm-charts",
    "https://helm.ngc.nvidia.com/nvidia",
  ]
}

variable "k8s_apps_chart_repos" {
  description = "Helm chart repositories k8s-apps' Applications may pull from, in addition to the k8s-apps repo itself"
  type        = list(string)
  default = [
    "https://otwld.github.io/ollama-helm/",
    "https://helm.openwebui.com/",
  ]
}

variable "sealed_secrets_key_file" {
  description = "Backup of the Sealed Secrets controller's key pair (output of `kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml`), restored before Argo CD installs the controller. Lives on the runner host only, never in Git. Missing file (first build) means the controller generates a new key."
  type        = string
  default     = null
}

variable "sealed_secrets_namespace" {
  description = "Namespace the Sealed Secrets controller runs in. Must match k8s-infra's sealed-secrets Application."
  type        = string
  default     = "kube-system"
}

variable "argocd_extra_values" {
  description = "Extra argo-cd Helm values merged over the defaults"
  type        = any
  default     = {}
}

variable "helm_timeout" {
  description = "Seconds to wait for the Argo CD release to become ready"
  type        = number
  default     = 600
}
