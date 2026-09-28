# Packer templates

Builds the two Proxmox VM templates `modules/proxmox-vm` clones from —
replaces Talos's Image Factory schematic + `vm-templates/build-template.sh`
pipeline. See the root README's "VM image" section for the full picture.

- `ubuntu-common.pkr.hcl` → `template_vm_id_common` (default 9100): hardened
  Ubuntu 24.04 + RKE2 binaries + Longhorn's host dependencies.
- `ubuntu-gpu.pkr.hcl` → `template_vm_id_gpu` (default 9101): the same, plus
  the NVIDIA driver (`${NVIDIA_DRIVER_BRANCH}-server`, open kernel
  modules, default branch 580) and container toolkit. There's no containerd
  config here: RKE2 detects `nvidia-container-runtime` and registers the
  `nvidia` runtime itself (see `scripts/install-nvidia.sh`).

Both clone `../vm-templates/import-ubuntu-cloud-image.sh`'s output (a plain
imported Ubuntu cloud image with a cloud-init drive attached, default vm_id
9099) rather than building from an ISO — run that script once first.

## Build order

```bash
sudo ./vm-templates/import-ubuntu-cloud-image.sh   # once, or on Ubuntu release bumps

cd packer
export PROXMOX_URL=https://192.168.1.15:8006/api2/json
export PROXMOX_USERNAME=terraform@pve!packer
export PROXMOX_TOKEN=...
packer init .
packer build -var packer_ssh_private_key_file=~/.ssh/packer_id_ed25519 ubuntu-common.pkr.hcl
packer build -var packer_ssh_private_key_file=~/.ssh/packer_id_ed25519 ubuntu-gpu.pkr.hcl
```

`Justfile`'s `t-create`/`t-destroy` recipes wrap this.

## Why Packer instead of cloud-init-only

Hardening and RKE2 installation are baked into the image once here, rather
than run by every node's cloud-init at clone time — faster node boot, and
closer to this cluster's previous Talos-style "bake once, clone many"
model. `modules/rke2-config`'s per-node cloud-init is deliberately thin as a
result: identity, RKE2's role config, and (control-plane only) the kube-vip
manifest — nothing package-install-shaped.

## Verify before relying on this

RKE2 disable-component names (`packer/scripts` doesn't set these — see
`modules/rke2-config/templates/user-data.yaml.tftpl`), the NVIDIA driver
branch (`NVIDIA_DRIVER_BRANCH` in `scripts/install-nvidia.sh`; check
`ubuntu-drivers list --gpgpu` on a noble host if its packages don't resolve),
and the Proxmox Packer plugin's `proxmox-clone` builder options should all be
checked against current docs before the first real build — this is new,
untested infrastructure, not a port of something already running.
