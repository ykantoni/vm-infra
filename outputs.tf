output "nodes" {
  value = module.proxmox_vm.nodes
}

output "controlplane_ips" {
  value = module.rke2_cluster.controlplane_ips
}

output "worker_ips" {
  value = module.rke2_cluster.worker_ips
}

output "kubeconfig" {
  sensitive = true
  value     = module.rke2_cluster.kubeconfig
}

output "ssh_admin_user" {
  value = module.rke2_config.ssh_admin_user
}

output "ssh_private_key" {
  description = "Terraform-managed SSH private key for ssh_admin_user, for manual access (e.g. `terraform output -raw ssh_private_key > ~/.ssh/rke2_admin` per Justfile's generate recipe)"
  sensitive   = true
  value       = module.rke2_config.ssh_private_key_pem
}

output "kubeconfig_path" {
  value = local_sensitive_file.kubeconfig.filename
}

output "argocd_namespace" {
  description = "Namespace Argo CD runs in. Initial admin password: just argocd-password"
  value       = module.argocd.namespace
}

output "sealed_secrets_key_restored" {
  description = "false on a first build: back the controller's generated key up with `just seal-key-backup` once k8s-infra has installed it"
  value       = module.argocd.sealed_secrets_key_restored
}
