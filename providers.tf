provider "proxmox" {
  insecure = true

  # Proxmox's API has no upload endpoint for snippets at all, so
  # proxmox_virtual_environment_file (modules/rke2-config's per-node
  # cloud-init) always writes them over SSH regardless of storage content
  # types. github-runner has its own keypair for this, self-authorized
  # (not root): see runner/README.md.
  ssh {
    agent       = false
    username    = "github-runner"
    private_key = file("/home/github-runner/.ssh/id_ed25519")
  }
}

# The helm and kubernetes providers are configured from the kubeconfig
# module.rke2_cluster fetches, not from a file path, so a fresh build works in
# one apply: on the first plan these values are unknown and Terraform defers
# them until the cluster exists. try() keeps plan working when wait_for_api is
# off and there's no kubeconfig at all.
locals {
  kubeconfig_from_module = try(yamldecode(module.rke2_cluster.kubeconfig), null)

  # `terraform destroy` never reads a data source whose depends_on resource
  # is itself being destroyed in that same run -- it comes back null
  # instead of erroring, silently (module.rke2_cluster.kubeconfig goes
  # through exactly that: data.local_file.kubeconfig depends_on
  # terraform_data.wait_for_vip, which destroy is also tearing down). That
  # null previously fell straight through to kube_host below, and the
  # providers quietly defaulted to http://localhost instead -- every
  # kubernetes/helm resource then failed to delete with "connection
  # refused" rather than a clear error. The raw kubeconfig file itself
  # isn't managed by Terraform at all (written by a local-exec provisioner,
  # never cleaned up by any destroy), so it's still on disk throughout a
  # destroy; reading it with a bare file() call -- not a data source, so
  # none of the above applies to it -- recovers a real value.
  kubeconfig_from_disk = try(yamldecode(file(module.rke2_cluster.kubeconfig_raw_path)), null)

  kubeconfig   = local.kubeconfig_from_module != null ? local.kubeconfig_from_module : local.kubeconfig_from_disk
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
