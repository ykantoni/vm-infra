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
  # Same path module.rke2_cluster is given (main.tf) -- duplicated as a
  # plain root-level local, deliberately NOT read back through the module,
  # so kubeconfig_from_disk below has zero reference to module.rke2_cluster.
  # See its comment for why that matters.
  kubeconfig_raw_path = pathexpand("~/.kube/rke2-raw.yaml")

  kubeconfig_from_module = try(yamldecode(module.rke2_cluster.kubeconfig), null)

  # On `terraform destroy`, module.rke2_cluster.kubeconfig comes back null
  # -- and so, it turns out, does every other module.rke2_cluster.* output,
  # even a plain pass-through local with no data source or resource
  # reference at all (confirmed empirically: adding
  # module.rke2_cluster.kubeconfig_raw_path and reading *that* path still
  # produced the same null here). Whatever the exact mechanism, referencing
  # ANY output of a module that's itself being destroyed in this run isn't
  # safe for provider configuration -- a provider block can't tolerate an
  # unknown/deferred value, so it silently fell back to its http://localhost
  # default instead of erroring, and every kubernetes/helm resource then
  # failed to delete with "connection refused" rather than a clear error.
  #
  # The raw kubeconfig file itself isn't managed by Terraform at all
  # (written by a local-exec provisioner inside the module, never cleaned
  # up by any destroy), so it's still on disk throughout a destroy --
  # reading it via the root-level local above, with no module reference at
  # all, recovers a real value.
  kubeconfig_from_disk = try(yamldecode(file(local.kubeconfig_raw_path)), null)

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
