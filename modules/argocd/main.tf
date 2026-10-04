locals {
  in_cluster = "https://kubernetes.default.svc"

  # `kubectl get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml`
  # returns a List; a single `kubectl get secret <name> -o yaml` returns the
  # Secret itself. Accept either shape.
  sealed_secrets_key_present = var.sealed_secrets_key_file != null && fileexists(var.sealed_secrets_key_file)
  sealed_secrets_key_doc     = local.sealed_secrets_key_present ? yamldecode(file(var.sealed_secrets_key_file)) : null
  sealed_secrets_key         = local.sealed_secrets_key_present ? try(local.sealed_secrets_key_doc.items[0], local.sealed_secrets_key_doc) : null

  # Argo CD dropped health assessment of Application resources in 1.8, so an
  # app-of-apps parent reports Healthy the moment its children exist, and
  # sync waves between child Applications stop meaning anything. Restoring
  # it makes k8s-infra's waves (Longhorn before Prometheus, and so on)
  # actually wait on the previous wave's health.
  application_health_lua = <<-EOT
    hs = {}
    hs.status = "Progressing"
    hs.message = ""
    if obj.status ~= nil then
      if obj.status.health ~= nil then
        hs.status = obj.status.health.status
        if obj.status.health.message ~= nil then
          hs.message = obj.status.health.message
        end
      end
    end
    return hs
  EOT

  argocd_values = {
    configs = {
      params = {
        # Applications for k8s-apps live in their own namespace, so the
        # k8s-apps AppProject can be restricted to that namespace via
        # sourceNamespaces: an Application there claiming the k8s-infra
        # project is rejected by Argo CD itself, not just by convention.
        "application.namespaces" = var.apps_namespace
      }

      cm = {
        "resource.customizations.health.argoproj.io_Application" = local.application_health_lua
      }
    }
  }

  sync_policy = {
    automated = {
      prune    = true
      selfHeal = true
    }

    # k8s-apps' children depend on CRDs and StorageClasses k8s-infra
    # installs; with no cross-root ordering in Argo CD, retrying forever is
    # what lets both roots be created at once and still converge.
    retry = {
      limit = -1
      backoff = {
        duration    = "30s"
        factor      = 2
        maxDuration = "10m"
      }
    }
  }

  argocd_apps_values = {
    projects = {
      # Two narrow projects for the roots themselves: each may only create
      # Application objects, and only in its own namespace.
      bootstrap-infra = {
        namespace = var.namespace
        # No ": " in this string -- the argocd-apps chart renders
        # description unquoted (`description: {{ . }}`), and an embedded
        # colon-space produces invalid YAML ("mapping values are not
        # allowed in this context").
        description = "Root app-of-apps for k8s-infra -- Applications in ${var.namespace} only"
        sourceRepos = [var.k8s_infra_repo_url]
        destinations = [{
          server    = local.in_cluster
          namespace = var.namespace
        }]
        clusterResourceWhitelist   = []
        namespaceResourceWhitelist = [{ group = "argoproj.io", kind = "Application" }]
      }

      bootstrap-apps = {
        namespace = var.namespace
        # See bootstrap-infra above: no ": " in this string either.
        description = "Root app-of-apps for k8s-apps -- Applications in ${var.apps_namespace} only"
        sourceRepos = [var.k8s_apps_repo_url]
        destinations = [{
          server    = local.in_cluster
          namespace = var.apps_namespace
        }]
        clusterResourceWhitelist   = []
        namespaceResourceWhitelist = [{ group = "argoproj.io", kind = "Application" }]
      }

      # Platform addons: any namespace, any cluster-scoped resource. The
      # Helm chart repositories each addon pulls from are listed in
      # sourceRepos alongside k8s-infra itself.
      k8s-infra = {
        namespace   = var.namespace
        description = "Cluster addons from k8s-infra"
        sourceRepos = concat([var.k8s_infra_repo_url], var.k8s_infra_chart_repos)
        destinations = [{
          server    = local.in_cluster
          namespace = "*"
        }]
        clusterResourceWhitelist = [{ group = "*", kind = "*" }]
      }

      # Applications: only the namespaces listed in var.apps_destination_namespaces,
      # and only the handful of cluster-scoped kinds apps legitimately need.
      k8s-apps = {
        namespace        = var.namespace
        description      = "Applications from k8s-apps"
        sourceRepos      = concat([var.k8s_apps_repo_url], var.k8s_apps_chart_repos)
        sourceNamespaces = [var.apps_namespace]
        destinations = [
          for ns in var.apps_destination_namespaces : {
            server    = local.in_cluster
            namespace = ns
          }
        ]
        clusterResourceWhitelist = [
          { group = "", kind = "Namespace" },
          { group = "", kind = "PersistentVolume" },
          { group = "storage.k8s.io", kind = "StorageClass" },
        ]
      }
    }

    applications = {
      root-k8s-infra = {
        namespace = var.namespace
        project   = "bootstrap-infra"
        source = {
          repoURL        = var.k8s_infra_repo_url
          targetRevision = var.target_revision
          path           = "bootstrap"
        }
        destination = {
          server    = local.in_cluster
          namespace = var.namespace
        }
        syncPolicy = local.sync_policy
      }

      root-k8s-apps = {
        namespace = var.namespace
        project   = "bootstrap-apps"
        source = {
          repoURL        = var.k8s_apps_repo_url
          targetRevision = var.target_revision
          path           = "bootstrap"
        }
        destination = {
          server    = local.in_cluster
          namespace = var.apps_namespace
        }
        syncPolicy = local.sync_policy
      }
    }
  }
}

# Managed here rather than with create_namespace, so they carry Pod Security
# labels: RKE2's CIS profile enforces "restricted" by default.
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.namespace

    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

resource "kubernetes_namespace" "apps" {
  metadata {
    name = var.apps_namespace

    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

# Restores the Sealed Secrets controller's key pair from a backup on the
# runner host before k8s-infra installs the controller, so every SealedSecret
# already committed to k8s-infra/k8s-apps still decrypts on a rebuilt cluster.
# On the very first build there's no backup yet: the controller generates a
# key, and `just seal-key-backup` saves it to var.sealed_secrets_key_file.
resource "kubernetes_secret_v1" "sealed_secrets_key" {
  count = local.sealed_secrets_key_present ? 1 : 0

  metadata {
    name      = local.sealed_secrets_key.metadata.name
    namespace = var.sealed_secrets_namespace

    labels = {
      "sealedsecrets.bitnami.com/sealed-secrets-key" = "active"
    }
  }

  type = "kubernetes.io/tls"

  # Already base64 in the backup, so binary_data rather than data.
  binary_data = {
    "tls.crt" = local.sealed_secrets_key.data["tls.crt"]
    "tls.key" = local.sealed_secrets_key.data["tls.key"]
  }
}

resource "helm_release" "argocd" {
  depends_on = [
    kubernetes_namespace.argocd,
    kubernetes_namespace.apps,
    kubernetes_secret_v1.sealed_secrets_key,
  ]

  name      = "argocd"
  namespace = var.namespace

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  wait    = true
  timeout = var.helm_timeout

  # Later entries win, so callers can override any of the defaults above.
  values = [
    yamlencode(local.argocd_values),
    yamlencode(var.argocd_extra_values),
  ]
}

# AppProjects and the two root Applications. A separate release because
# their CRDs come from helm_release.argocd and don't exist at plan time.
resource "helm_release" "argocd_apps" {
  depends_on = [
    helm_release.argocd,
  ]

  name      = "argocd-apps"
  namespace = var.namespace

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version

  values = [
    yamlencode(local.argocd_apps_values),
  ]
}
