#!/usr/bin/env bash
# Practical hardening baseline (not full CIS/DISA-STIG via Ubuntu Security
# Guide -- see the root README's "Hardening" section for why). Applied once
# here, at image-build time, so it's identical across every node and never
# has to be re-applied per clone.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# cloud-init's own first-boot modules (package index refresh, etc.) can
# still be holding the apt lock right when SSH becomes available -- wait for
# it to fully finish before touching apt ourselves. Exit code 2 means
# "finished, but some module hit a recoverable error" -- still fine for our
# purposes, we only care that it's done, not that every module succeeded.
cloud-init status --wait || [ "$?" -eq 2 ]

apt-get update
apt-get install -y --no-install-recommends \
  ufw \
  unattended-upgrades \
  auditd \
  audispd-plugins \
  qemu-guest-agent

# modules/proxmox-vm sets agent { enabled = true } on every real node clone,
# which needs this running to report back IPs etc. -- packer's own
# qemu_agent = false in *.pkr.hcl only means "don't rely on it during THIS
# build" (it isn't installed yet at that point), not "skip installing it".
systemctl enable --now qemu-guest-agent

# --- SSH: key-only, no root login ---
# modules/rke2-config's cloud-init is the only thing that ever adds an
# authorized_keys entry (for var.ssh_admin_user); nothing here needs to add
# one for the packer build user, since Packer manages its own temporary
# access through the seed template's own cloud-init (see
# vm-templates/import-ubuntu-cloud-image.sh), not through this file.
sed -i \
  -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
  -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
  -e 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' \
  /etc/ssh/sshd_config

# --- ufw: default-deny, only what this cluster actually needs open ---
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp     comment "SSH"
ufw allow 6443/tcp   comment "Kubernetes API (kube-vip VIP + control-plane)"
ufw allow 9345/tcp   comment "RKE2 agent registration"
ufw allow 10250/tcp  comment "kubelet API"
ufw allow 2379:2380/tcp comment "etcd (control-plane only, harmless open elsewhere)"
ufw allow from 192.168.1.0/24 comment "cluster/LAN pod+service traffic (Cilium, Longhorn, kube-vip ARP)"
ufw --force enable

# --- unattended-upgrades: security patches only, no auto-reboot ---
cat >/etc/apt/apt.conf.d/51unattended-upgrades-rke2 <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
systemctl enable --now unattended-upgrades

# --- auditd: on, default ruleset ---
systemctl enable --now auditd

# --- swap: off, disabled at boot (kubelet requires this) ---
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab

# --- sysctls: standard hardening set, layered on top of RKE2's own
# CIS sysctls from install-rke2.sh (which must run before this, so this
# file doesn't clobber /etc/sysctl.d/60-rke2-cis.conf) ---
cat >/etc/sysctl.d/61-hardening.conf <<'EOF'
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_redirects = 0
kernel.dmesg_restrict = 1
fs.suid_dumpable = 0
EOF
sysctl -p /etc/sysctl.d/61-hardening.conf

# AppArmor is enabled by default on Ubuntu; just confirm rather than assume.
systemctl is-enabled apparmor >/dev/null
