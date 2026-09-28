# Self-hosted GitHub Actions runner

`.github/workflows/terraform.yml` and `packer.yml` run on a self-hosted
runner, because both need the Proxmox API, SSH to the cluster nodes, and
(for `just t-destroy`) `qm` on the Proxmox host itself. k8s-infra and
k8s-apps need no runner: Argo CD pulls from them, and their lint jobs run on
GitHub-hosted runners.

## Host

Runs on the Proxmox host (`jupiter`) itself, as the `github-runner` user,
registered with the labels:

```
self-hosted, linux, terraform, proxmox
```

Installed on the host, on `github-runner`'s `PATH`: `terraform` (pinned by
the workflow via `hashicorp/setup-terraform`, so only its prerequisites),
`packer`, `just`, `kubectl`, `ssh`/`scp`.

`github-runner` needs passwordless sudo for exactly `qm status` and
`qm destroy` (used by `just t-destroy`):

```
github-runner ALL=(root) NOPASSWD: /usr/sbin/qm status *, /usr/sbin/qm destroy *
```

## State and files that live only on this host

| Path                                          | What                                                                 |
| --------------------------------------------- | -------------------------------------------------------------------- |
| `/var/lib/terraform/talos-proxmox/terraform.tfstate` | Terraform state (`backend.tf`). Back it up.                    |
| `/var/lib/terraform/sealed-secrets-key.yaml`  | Sealed Secrets key pair, written by `just seal-key-backup` after the first build and restored by `modules/argocd` on every later one. Also keep a copy off this host. |
| `/var/lib/terraform/packer_ssh_key`           | Private key for the seed template's cloud-init user (`PKR_VAR_packer_ssh_private_key_file`); override the path with the repository variable `PACKER_SSH_PRIVATE_KEY_FILE`. |
| `~github-runner/.kube/rke2-raw.yaml`          | Kubeconfig fetched from the bootstrap node; read at plan time to configure the helm/kubernetes providers. Lives outside the checkout because `actions/checkout` wipes untracked files. |
| `~github-runner/.kube/config`                 | Copy of the same kubeconfig, for `kubectl`.                          |

All of these must be readable and writable by `github-runner` and nobody else.

Because state is local to this host, manual `just apply` runs must happen
here too (as `github-runner`, or with the same state path), never from a
laptop with its own state.

## Repository settings

- Repository secrets `PROXMOX_VE_ENDPOINT` and `PROXMOX_VE_API_TOKEN`
  (`user@realm!tokenid=secret`). Repository-level rather than per-environment
  because the plan job needs them too. GitHub never passes secrets to
  workflows triggered from forks.
- Environment `proxmox`: required reviewer (you), deployment branch `main`
  only. Every apply and every template rebuild waits for that approval.
- Actions → General → "Fork pull request workflows from outside
  collaborators": **Require approval for all outside collaborators**. The
  workflow additionally skips pull requests from forks entirely, since the
  repository is public and this runner sits on the Proxmox host.
