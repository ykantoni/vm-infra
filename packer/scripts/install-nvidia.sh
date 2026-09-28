#!/usr/bin/env bash
# GPU image only (packer/ubuntu-gpu.pkr.hcl). Replaces the
# siderolabs/nvidia-open-gpu-kernel-modules-production and
# siderolabs/nvidia-container-toolkit-production Talos system extensions:
# the NVIDIA driver and container toolkit on the host, so k8s-infra's
# gpu-operator can run with its own driver and toolkit components disabled.
#
# Containerd runtime registration is deliberately NOT done here: RKE2 detects
# nvidia-container-runtime on the host at startup and adds an "nvidia" runtime
# to the containerd config it generates. Writing
# /var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl (as
# `nvidia-ctk runtime configure` would) replaces RKE2's whole generated config
# with that file, dropping everything else RKE2 puts there. The gpu-operator
# creates the matching "nvidia" RuntimeClass.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Production server branch. Blackwell cards (the RTX 5060 Ti) need 570+ and the
# open kernel modules. `ubuntu-drivers list --gpgpu` on a noble host lists the
# branches Ubuntu currently ships.
NVIDIA_DRIVER_BRANCH="${NVIDIA_DRIVER_BRANCH:-580}"

# Canonical's prebuilt, signed kernel modules: no DKMS build here or on
# kernel updates. The -generic metapackage follows the generic kernel, so a
# security kernel from unattended-upgrades brings matching modules with it --
# which only holds if this image actually runs the generic kernel.
case "$(uname -r)" in
  *-generic) ;;
  *)
    echo "Kernel $(uname -r) is not the -generic flavour that linux-modules-nvidia-*-generic tracks." >&2
    exit 1
    ;;
esac

apt-get update
apt-get install -y --no-install-recommends \
  "linux-modules-nvidia-${NVIDIA_DRIVER_BRANCH}-server-open-generic" \
  "nvidia-headless-no-dkms-${NVIDIA_DRIVER_BRANCH}-server-open" \
  "nvidia-utils-${NVIDIA_DRIVER_BRANCH}-server"

# nvidia-container-toolkit isn't in Ubuntu's archive; it comes from NVIDIA's
# own libnvidia-container repository.
apt-get install -y --no-install-recommends ca-certificates curl gnupg
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update
apt-get install -y --no-install-recommends nvidia-container-toolkit

echo "NVIDIA ${NVIDIA_DRIVER_BRANCH}-server (open modules) and nvidia-container-toolkit installed. Verify with nvidia-smi after first boot on real hardware -- Packer's build VM has no GPU passed through, so nvidia-smi will not work during this provisioning step itself."
