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
