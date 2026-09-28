# Cluster Addons Module

Installs the cluster addons that RKE2 deliberately leaves out once
`cni: none`/`disable-kube-proxy: true` are set (see `modules/rke2-config`).

## Responsibilities

This module manages:

- Cilium, as both CNI and kube-proxy replacement, with L2 announcements
  and (optionally) Hubble Relay/UI turned on

The `CiliumLoadBalancerIPPool` and `CiliumL2AnnouncementPolicy` that give
LoadBalancer services their addresses are **not** here: they live in the
k8s-infra repository (`charts/cilium-lb-ipam`), reconciled by Argo CD. Only
the CNI itself has to exist before Argo CD can run.

It expects a bootstrapped cluster whose RKE2 config already sets `cni: none`
and `disable-kube-proxy: true`, and it expects the `helm` provider to be
configured by the caller.

## RKE2/kube-vip specifics

The Helm values deviate from Cilium's defaults in a few ways:

- `ipam.mode: kubernetes`, so pod addresses come from the node podCIDR
- `cgroup.autoMount.enabled: false`, because Ubuntu (systemd) already mounts
  cgroupv2 itself, same as Talos did
- `SYS_MODULE` dropped from the agent capabilities — not strictly required
  under RKE2/Ubuntu the way it was under Talos, but harmless to keep, since
  nothing here needs Cilium to load kernel modules at runtime (that happens
  once, in `packer/`)
- `k8sServiceHost`/`k8sServicePort` point at the kube-vip-advertised
  control-plane VIP (`6443`) rather than a Service IP Cilium would have to
  route itself — the RKE2-world replacement for Talos's node-local KubePrism
  proxy. kube-vip is a `hostNetwork` pod using ARP, so it's reachable even
  while Cilium is still the thing bringing pod networking up.

## Load balancer addressing

See k8s-infra's `charts/cilium-lb-ipam` and its README: the pool range, and
which nodes answer ARP for it, are configured there.

## Hubble

`enable_hubble_ui = true` (the default) turns on Hubble Relay and Hubble UI,
giving a web dashboard of the CNI's live traffic: the service map, L3/L4/L7
flows, DNS, and policy verdicts. Flow visibility itself (`hubble.enabled`) is
already on by default in the chart; Relay aggregates every agent's flow feed,
and the UI is the dashboard that talks to Relay.

`hubble_ui_service_type` defaults to `ClusterIP`: the LB-IPAM pool only
appears later, from k8s-infra, so a LoadBalancer Service here would leave
`helm_release.cilium`'s wait hanging. k8s-infra's `lb-services` chart adds a
separate LoadBalancer Service in front of Hubble UI instead.

## Inputs

- `cilium_version`
- `k8s_service_host`, `k8s_service_port`
- `k8s_client_rate_limit`
- `enable_hubble_ui`
- `hubble_ui_service_type`
- `cilium_extra_values`
- `helm_timeout`

## Outputs

- `cilium_version`
