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

  # On `terraform destroy`, module.rke2_cluster.kubeconfig -- and every
  # other module.rke2_cluster.* output, even a plain pass-through local
  # with no data source or resource behind it -- comes back as an UNKNOWN
  # value, not a concrete null. Confirmed empirically across three attempts:
  # removing triggers_replace from upstream resources didn't help, and
  # neither did adding a second module output and reading it; both still
  # produced the same http://localhost fallback. A value-derived check like
  # `local.kubeconfig_from_module != null` can't tell unknown apart from a
  # real value at plan time -- comparing an unknown against anything is
  # itself unknown, so the ternary that used to pick a fallback here was
  # itself unknown, and Terraform silently resolved the unknown provider
  # argument to empty/http://localhost rather than erroring.
  #
  # The raw kubeconfig file on disk isn't managed by Terraform at all
  # (written by a local-exec provisioner inside the module, never cleaned
  # up by any destroy), so it's still there throughout a destroy. Reading it
  # via the root-level local above has zero reference to module.rke2_cluster,
  # so it can't inherit that module's unknown-during-destroy behavior.
  kubeconfig_from_disk = try(yamldecode(file(local.kubeconfig_raw_path)), null)

  # var.is_destroy (set by the Justfile's destroy recipe) is a plain input
  # variable, always concretely known -- unlike a value-derived condition,
  # it's safe to branch on here. Destroy always prefers disk, bypassing the
  # module entirely so it can't inherit its unknown-during-destroy values.
  # Every other operation prefers the module (so a control-plane replace's
  # new kubeconfig takes effect within that same apply), falling back to
  # disk only if the module's value is a genuine, concrete null -- safe in
  # this branch since that unknown-during-destroy behavior doesn't apply
  # outside of destroy.
  kubeconfig = var.is_destroy ? local.kubeconfig_from_disk : (
    local.kubeconfig_from_module != null ? local.kubeconfig_from_module : local.kubeconfig_from_disk
  )
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
