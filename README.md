# vm-infra

Hardened Ubuntu 24.04 + RKE2 Kubernetes cluster on Proxmox VE, up to the
point where Argo CD takes over.

Part of [proxclus](https://github.com/ykantoni/proxclus), which pins three
repositories:

| Repository    | Owns                                                                 | Applied by                                      |
| ------------- | -------------------------------------------------------------------- | ----------------------------------------------- |
| **vm-infra**  | golden images, Proxmox VMs, RKE2, Cilium (CNI), Argo CD              | Terraform/Packer via GitHub Actions on a self-hosted runner |
| k8s-infra     | LB-IPAM pool, Sealed Secrets, Longhorn, metrics-server, CNPG operator, kube-prometheus-stack, NVIDIA GPU operator | Argo CD (`root-k8s-infra`) |
| k8s-apps      | Ollama + Open WebUI, Postgres (CNPG `Cluster`)                       | Argo CD (`root-k8s-apps`)                       |

This repository stops at the smallest set of things Argo CD needs before it
can run: VMs, Kubernetes, pod networking (Cilium), and Argo CD itself, plus
the two root Applications that point Argo CD at k8s-infra and k8s-apps.

## Layout

Provisioning is three modules, not the more obvious two, because of one
ordering constraint: a VM's cloud-init content has to exist *before* the VM
is created, while checking that the cluster actually came up can only happen
*after*. One module can't sit on both sides of that dependency.

- `modules/rke2-config` — renders and uploads each node's cloud-init
  user-data (hostname, RKE2 role config, the kube-vip manifest on the
  control-plane node) as a Proxmox snippet; generates the shared RKE2 join
  token and the SSH keypair Terraform itself uses afterward. Runs *before*
  `modules/proxmox-vm`, not after.
- `modules/proxmox-vm` — Proxmox VM creation, cloned from the templates
  `packer/` builds; wires in each node's cloud-init snippet by ID
- `modules/rke2-cluster` — waits for `rke2-server` to come up on the
  bootstrap node (over SSH) and fetches its kubeconfig. Runs *after*
  `modules/proxmox-vm`, keyed off its VM outputs rather than the raw node
  list, so Terraform knows to wait for the VMs to exist first.
- `modules/addons/cilium` — Cilium as CNI and kube-proxy replacement
- `modules/argocd` — Argo CD, its AppProjects, the two root Applications,
  and the Sealed Secrets key restore; see `modules/argocd/README.md`
- `addons.tf` — where Cilium and Argo CD are composed
- `packer/` — builds the two Proxmox VM templates (plain and GPU) that
  `modules/proxmox-vm` clones from; see `packer/README.md`
- `vm-templates/import-ubuntu-cloud-image.sh` — one-time import of the stock
  Ubuntu cloud image that `packer/` then clones and provisions
- `proxmox-host/` — host-side files (VFIO, GPU BAR resize) installed by hand
- `runner/` — how the self-hosted GitHub Actions runner is set up
- `.github/workflows/` — `terraform.yml` (plan on PR, approved apply on
  `main`) and `packer.yml` (approved template rebuilds)

## How changes are applied

| Change                               | Flow                                                                           |
| ------------------------------------ | ------------------------------------------------------------------------------ |
| Terraform (`*.tf`, `terraform.tfvars`) | PR → `plan` on the self-hosted runner → merge to `main` → approve the `proxmox` environment → `apply` |
| Golden image (`packer/**`)           | merge to `main` → approve → `just t-destroy` + `just t-create`; then replace the VMs (taint or recreate the nodes) so they boot from the new template |
| Addon (k8s-infra)                    | PR + merge in k8s-infra; Argo CD syncs it. No runner, no Terraform.            |
| Application (k8s-apps)               | PR + merge in k8s-apps; Argo CD syncs it.                                      |

Pull requests from forks never run on the self-hosted runner. See
`runner/README.md` for the runner, its secrets and the `proxmox` environment.

## Usage

Task running is [`just`](https://github.com/casey/just), not Make; see
`Justfile` for the full recipe list (`just --list`).

```bash
just t-create          # once, builds the Proxmox templates (see packer/README.md)
just apply             # VMs → RKE2 → Cilium → Argo CD → root Applications
just generate          # writes ~/.kube/config and ~/.ssh/rke2_admin
just argocd-password   # initial Argo CD admin password
just seal-key-backup   # once, after the first build (see below)
```

Run these on the runner host: Terraform state is local to it (`backend.tf`).

The `helm` and `kubernetes` providers are configured from the kubeconfig
`modules/rke2-cluster` fetches (`providers.tf`), not from a file path, so a
fresh build completes in one apply. That kubeconfig is kept at
`~/.kube/rke2-raw.yaml`, outside the checkout, since it's read back at plan
time; `terraform apply` also writes a copy to `~/.kube/config`, replacing
whatever is there, for `kubectl`.

## First build and Sealed Secrets

Secrets in k8s-infra and k8s-apps are committed as `SealedSecret`s, which only
the controller holding the matching key can decrypt. A rebuilt cluster would
generate a new key, so `modules/argocd` restores the previous one from
`sealed_secrets_key_file` (default `/var/lib/terraform/sealed-secrets-key.yaml`)
before Argo CD installs the controller.

1. First build: `just apply`. No key file yet; the controller generates one
   when k8s-infra's `sealed-secrets` Application syncs.
2. `just seal-key-backup` to save it; copy it somewhere off the host too.
3. `just seal-cert > ../k8s-infra/pub-cert.pem` (and the same for k8s-apps),
   then seal and commit the secrets those repos expect; see their READMEs.

Every later build restores the key automatically
(`terraform output sealed_secrets_key_restored` shows whether it did).

## VM image

`packer/` is the single source of truth for what's on every node's disk:
hardening, the RKE2 binary, and (on the GPU template) the NVIDIA driver and
container toolkit are all baked in once, at image-build time — see
`packer/README.md` for the build steps and why Packer instead of doing all
of this in cloud-init on every clone.

Updating the image (a new RKE2 version, a new hardening step) means
rebuilding the templates (`just t-create`, or the Packer workflow) and then
replacing each node's VM — there's no in-place "upgrade" command.

## Networking

`cni = "cilium"` (the default) sets `cni: none` and `disable-kube-proxy: true`
in every node's RKE2 config (`modules/rke2-config`), and `module.cilium`
installs Cilium to cover both roles. Set `cni = "flannel"` to leave RKE2's
own bundled Canal + kube-proxy running instead.

LoadBalancer services get an address from the Cilium LB-IPAM pool, announced
on the LAN over ARP by Cilium L2 announcements. The pool itself is defined in
k8s-infra (`charts/cilium-lb-ipam/values.yaml`), not here: Cilium's own chart only turns
L2 announcements on. The range has to be free on the node subnet: outside
any DHCP scope, clear of the node addresses and of `controlplane_vip`.

| Setting                  | Value                                   |
| ------------------------ | --------------------------------------- |
| Nodes                    | 192.168.1.201-192.168.1.206             |
| Control-plane VIP        | 192.168.1.99                            |
| LoadBalancer pool        | 192.168.1.60-192.168.1.98 (k8s-infra)   |

The control-plane VIP is advertised by **kube-vip**, run as an RKE2
auto-deployed manifest (`/var/lib/rancher/rke2/server/manifests/kube-vip.yaml`,
written by `modules/rke2-config`) on the control-plane node. It's a
`hostNetwork` pod using ARP, so it's reachable even before Cilium brings up
pod networking. With only one control-plane node today, this mainly buys a
stable address independent of that node's own IP; a second control-plane
node later would get automatic failover via kube-vip's leader election with
no client reconfiguration.

Setting `external_ip` to a public IP or hostname adds it as a SAN on the
control-plane's RKE2 `tls-san`, so a client outside the LAN validates TLS
once it reaches the cluster. It doesn't configure the router: forwarding
that public IP's port 6443 to `controlplane_vip` is a manual NAT/port-forward
rule you set up separately, and the external client needs its own
kubeconfig with the endpoint changed to `external_ip`.

`enable_hubble_ui = true` (the default) installs Hubble Relay and Hubble UI
alongside Cilium. Its Service is `ClusterIP` here, since the LB-IPAM pool
doesn't exist yet while Cilium installs; k8s-infra's `lb-services` chart adds
LoadBalancer Services for Hubble UI and the Argo CD server.

## GPU

Setting `pcigpu` on a node in `var.nodes` passes that PCI device through to
the VM (see `modules/proxmox-vm`) and clones it from the GPU template
instead of the common one (`template_vm_id_gpu`, built by
`packer/ubuntu-gpu.pkr.hcl` with the NVIDIA driver and container toolkit
already baked in; RKE2 detects the toolkit's runtime and registers `nvidia`
in containerd itself). Everything
Kubernetes-side — the `nvidia` RuntimeClass, the device plugin, node
labelling via NFD — comes from the NVIDIA GPU operator in k8s-infra, with its
driver and toolkit components disabled because the image already has both.

## Hardening

Every node's image (`packer/scripts/harden.sh`) gets a practical baseline:
SSH key-only auth with root login disabled, `ufw` default-deny with only the
ports RKE2/SSH/Longhorn/Cilium/kube-vip actually need open,
`unattended-upgrades` for security patches, `auditd`, a standard hardening
sysctl set layered on top of RKE2's own, swap disabled, and AppArmor
confirmed enforcing (Ubuntu's default).

RKE2 itself runs with `profile: cis` in every node's config
(`modules/rke2-config`), which also enforces the `restricted` Pod Security
Standard by default; namespaces that need more (Longhorn, monitoring, the
GPU operator) are labelled by the Application that creates them in
k8s-infra.

## Ordering

Cloud-init + RKE2's own startup are asynchronous after a VM boots, so
`modules/rke2-cluster` provides one gate, `wait_for_api` (on by default):
poll the bootstrap node over SSH until `rke2-server` is active, then fetch
its kubeconfig. Cilium depends on that; Argo CD depends on Cilium, since its
pods need pod networking. Ordering among addons and apps is Argo CD's job
(sync waves in k8s-infra, retries in k8s-apps).

`wait_for_api = false` disables the gate, which is also how you plan against
a cluster that is powered off.
