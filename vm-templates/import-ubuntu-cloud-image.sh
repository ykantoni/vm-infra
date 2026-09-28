#!/usr/bin/env bash
# One-time seed-template import, run once (or whenever bumping the Ubuntu
# release) before `packer build` in ../packer/ can clone from it. Unlike
# Talos's Image Factory (customization.yaml -> schematic -> nocloud raw
# image, all in vm-templates/build-template.sh), Ubuntu's cloud image needs
# no customization step of its own -- all hardening/RKE2/NVIDIA provisioning
# happens later, inside Packer, against a clone of this seed. This script's
# only job is: get a stock Ubuntu cloud image into Proxmox as a
# cloud-init-capable template Packer's proxmox-clone builder can boot.
#
# Usage: sudo ./import-ubuntu-cloud-image.sh [vmid]
set -euo pipefail

VMID="${1:-9099}"
UBUNTU_RELEASE="noble"        # 24.04 LTS, "Noble Numbat"
STORAGE="sdc-storage"          # must match root main.tf's var.datastore_id
IMAGE_URL="https://cloud-images.ubuntu.com/releases/${UBUNTU_RELEASE}/release/ubuntu-24.04-server-cloudimg-amd64.img"
IMAGE_FILE="/tmp/ubuntu-24.04-server-cloudimg-amd64.img"

if [ ! -f "${IMAGE_FILE}" ]; then
  wget -O "${IMAGE_FILE}" "${IMAGE_URL}"
fi

qm create "${VMID}" \
  --name "ubuntu-24.04-cloudimg-seed" \
  --memory 2048 \
  --cores 2 \
  --cpu host \
  --machine q35 \
  --bios ovmf \
  --net0 virtio,bridge=vmbr0

qm set "${VMID}" --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0"

qm importdisk "${VMID}" "${IMAGE_FILE}" "${STORAGE}"
qm set "${VMID}" --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:${VMID}/vm-${VMID}-disk-1.raw"

# Cloud-init drive: this is what lets Packer's proxmox-clone builder boot a
# clone of this seed with temporary credentials (an SSH key it controls) to
# run provisioners over. modules/rke2-config's per-node cloud-init replaces
# this drive's content entirely on every real node clone later -- this one
# is only ever used by Packer, never by a production node.
qm set "${VMID}" --ide2 "${STORAGE}:cloudinit"
qm set "${VMID}" --boot order=scsi0
qm set "${VMID}" --serial0 socket --vga std
qm set "${VMID}" --agent enabled=1

qm template "${VMID}"

echo "Seed template ${VMID} ready. Point packer/*.pkr.hcl's proxmox_vmid at it."
