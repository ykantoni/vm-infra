# The only in-cluster pieces vm-infra still owns: what has to exist before
# Argo CD can run (Cilium, since RKE2 brings up no pod networking itself when
# cni is cilium), and Argo CD itself. Every other addon lives in k8s-infra,
# every application in k8s-apps, both reconciled by Argo CD.

module "cilium" {
  source = "./modules/addons/cilium"

  count = var.cni == "cilium" ? 1 : 0

  cilium_version         = var.cilium_version
  k8s_service_host       = var.controlplane_vip
  enable_hubble_ui       = var.enable_hubble_ui
  hubble_ui_service_type = var.hubble_ui_service_type

  depends_on = [
    module.rke2_cluster,
  ]
}

module "argocd" {
  source = "./modules/argocd"

  argocd_chart_version      = var.argocd_chart_version
  argocd_apps_chart_version = var.argocd_apps_chart_version
  k8s_infra_repo_url        = var.k8s_infra_repo_url
  k8s_apps_repo_url         = var.k8s_apps_repo_url
  target_revision           = var.gitops_target_revision
  sealed_secrets_key_file   = var.sealed_secrets_key_file

  # Argo CD's own pods need pod networking. Referencing the bare module (no
  # index) is still valid when cni is flannel and module.cilium has zero
  # instances; RKE2's bundled Canal covers CNI readiness in that case.
  depends_on = [
    module.rke2_cluster,
    module.cilium,
  ]
}
