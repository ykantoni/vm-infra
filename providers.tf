provider "proxmox" {
  insecure = true
}

# The helm and kubernetes providers are configured from the kubeconfig
# module.rke2_cluster fetches, not from a file path, so a fresh build works in
# one apply: on the first plan these values are unknown and Terraform defers
# them until the cluster exists. try() keeps plan working when wait_for_api is
# off and there's no kubeconfig at all.
locals {
  kubeconfig   = try(yamldecode(module.rke2_cluster.kubeconfig), null)
  kube_cluster = try(local.kubeconfig.clusters[0].cluster, null)
  kube_user    = try(local.kubeconfig.users[0].user, null)

  kube_host                   = try(local.kube_cluster.server, null)
  kube_cluster_ca_certificate = try(base64decode(local.kube_cluster["certificate-authority-data"]), null)
  kube_client_certificate     = try(base64decode(local.kube_user["client-certificate-data"]), null)
  kube_client_key             = try(base64decode(local.kube_user["client-key-data"]), null)
}

provider "helm" {
  kubernetes = {
    host                   = local.kube_host
    cluster_ca_certificate = local.kube_cluster_ca_certificate
    client_certificate     = local.kube_client_certificate
    client_key             = local.kube_client_key
  }
}

# Used only for the handful of raw Kubernetes objects (namespaces with Pod
# Security labels, the restored Sealed Secrets key) that don't belong inside
# a Helm release. Configured the same way as the helm provider.
provider "kubernetes" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_cluster_ca_certificate
  client_certificate     = local.kube_client_certificate
  client_key             = local.kube_client_key
}
