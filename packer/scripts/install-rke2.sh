#!/usr/bin/env bash
# Installs the RKE2 binaries and dependencies, but leaves the cluster role
# (server vs agent) and actual startup to modules/rke2-config's per-node
# cloud-init at clone time -- this only needs to run once, at image-build
# time, since the binary itself is identical for every node regardless of
# role.
set -euo pipefail

RKE2_CHANNEL="${RKE2_CHANNEL:-stable}"

# get.rke2.io resolves RKE2_CHANNEL to a version via a separate call to
# update.rke2.io; a transient failure there makes it silently fall back to
# treating the channel name itself as the version (e.g. a literal "stable"
# release, which 404s), rather than a clean error. Retry the whole install
# rather than special-casing that -- indistinguishable from a worse-but-also-
# transient failure further into the same pipeline.
for attempt in 1 2 3; do
  if curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL="${RKE2_CHANNEL}" sh -; then
    break
  elif [ "$attempt" -eq 3 ]; then
    exit 1
  fi
  sleep 5
done

# CIS-profile prerequisites (modules/rke2-config sets profile: cis in every
# node's config.yaml). RKE2 ships the required sysctls alongside the binary;
# see https://docs.rke2.io/security/hardening_guide for the current list --
# this just applies whatever that install shipped, so it tracks RKE2 version
# changes automatically rather than hardcoding values here. get.rke2.io
# installs under /usr/local (not /usr/share) -- without this, rke2-server
# crash-loops at startup with "invalid kernel parameter value" for whichever
# of these it validates, since profile: cis enforces them regardless of
# whether this file made it onto the running kernel.
if [ -f /usr/local/share/rke2/rke2-cis-sysctl.conf ]; then
  cp /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
  sysctl -p /etc/sysctl.d/60-rke2-cis.conf
fi

getent group etcd >/dev/null || groupadd --system etcd
getent passwd etcd >/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin --gid etcd etcd
