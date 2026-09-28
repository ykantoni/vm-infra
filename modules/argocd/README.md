# Argo CD Module

Installs Argo CD and hands the rest of the cluster over to it. This is the
last thing vm-infra's Terraform does; everything above it (addons, apps) is
reconciled by Argo CD from two other repositories.

## What it creates

- `argocd` namespace (PSA `baseline`) and the Argo CD release itself
- `argocd-apps` namespace (PSA `restricted`), which Argo CD is told to watch
  via `application.namespaces`
- optionally, the Sealed Secrets controller's key pair in `kube-system`,
  restored from `sealed_secrets_key_file` (see below)
- via the `argocd-apps` chart, four AppProjects and two root Applications:

| AppProject        | May create                                       | Used by                     |
| ----------------- | ------------------------------------------------ | --------------------------- |
| `bootstrap-infra` | `Application` in `argocd` only                   | `root-k8s-infra`            |
| `bootstrap-apps`  | `Application` in `argocd-apps` only              | `root-k8s-apps`             |
| `k8s-infra`       | anything, any namespace, any cluster resource    | k8s-infra's child apps      |
| `k8s-apps`        | `apps_destination_namespaces` only; cluster kinds limited to `Namespace`, `PersistentVolume`, `StorageClass`; Applications accepted only from `argocd-apps` | k8s-apps' child apps |

`root-k8s-infra` syncs `bootstrap/` of `k8s_infra_repo_url` into `argocd`;
`root-k8s-apps` syncs `bootstrap/` of `k8s_apps_repo_url` into
`argocd-apps`. Both auto-sync with prune and self-heal, and retry forever
with backoff, which is how k8s-apps waits for k8s-infra's CRDs and
StorageClasses without any cross-root ordering.

Because k8s-apps' Applications live in `argocd-apps` and only the `k8s-apps`
project lists that as a source namespace, an Application in the k8s-apps repo
that claims `project: k8s-infra` is rejected by Argo CD rather than being
granted cluster-wide rights.

## Sync waves between child Applications

Argo CD stopped assessing the health of `Application` resources in 1.8, which
makes sync waves in an app-of-apps meaningless. This module restores the
standard `resource.customizations.health.argoproj.io_Application` Lua check
in `argocd-cm`, so k8s-infra's waves wait on the previous wave being Healthy.

## Sealed Secrets key

A new cluster means a new Sealed Secrets controller, and a new controller
generates a new key, so every `SealedSecret` in Git stops decrypting. To make
rebuilds painless:

1. First build: leave `sealed_secrets_key_file` pointing at a file that
   doesn't exist yet. The controller (installed by k8s-infra) generates a key.
2. Run `just seal-key-backup` on the runner host. It writes the key to
   `sealed_secrets_key_file`. Keep a second copy off the host.
3. Every later build restores that key here, before Argo CD installs the
   controller, which then adopts it.

## Reaching the UI

The `argocd-server` Service is ClusterIP. k8s-infra's `lb-services` chart
adds a separate LoadBalancer Service for it once Cilium LB-IPAM exists; until
then, `kubectl -n argocd port-forward svc/argocd-server 8080:443`. The
initial admin password: `just argocd-password`.
