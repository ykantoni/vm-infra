output "controlplane_ips" {
  value = local.controlplane_ips
}

output "worker_ips" {
  value = [
    for node in values(local.workers) :
    node.ip
  ]
}

output "kubeconfig" {
  sensitive = true
  value     = try(data.local_file.kubeconfig[0].content, null)
}

# A plain local, not a resource/data source -- providers.tf falls back to
# reading this path directly with a bare file() call during `terraform
# destroy`, when the data source above reads back null (see providers.tf).
output "kubeconfig_raw_path" {
  value = local.kubeconfig_raw_path
}
