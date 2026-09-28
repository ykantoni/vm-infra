locals {
  cilium_values = {
    # Pod IPs come from the podCIDR that kube-controller-manager hands each node.
    ipam = {
      mode = "kubernetes"
    }

    # RKE2 is configured with cni: none and disable-kube-proxy: true (see
    # modules/rke2-config), so Cilium must take over service routing. L2
    # announcements also require it.
    kubeProxyReplacement = true

    # kube-vip's control-plane VIP is what fronts the API server here (the
    # RKE2-world replacement for Talos's KubePrism), reachable independently
    # of the CNI since it's a hostNetwork pod using ARP, not routed
    # pod-network traffic -- so Cilium can reach it even while it's the thing
    # bringing pod networking up in the first place.
    k8sServiceHost = var.k8s_service_host
    k8sServicePort = var.k8s_service_port

    # Ubuntu (systemd) already mounts cgroupv2 itself, same as Talos did;
    # kept false so Cilium doesn't try to remount it. Validate this still
    # holds under RKE2/Ubuntu 24.04 rather than assuming.
    cgroup = {
      autoMount = {
        enabled = false
      }

      hostRoot = "/sys/fs/cgroup"
    }

    # Talos forbade workloads from loading kernel modules; nothing on
    # Ubuntu/RKE2 requires the same restriction, but dropping SYS_MODULE from
    # Cilium's capability set is still harmless (kernel modules load once,
    # via packer/, not from a running Cilium agent), so it stays dropped.
    securityContext = {
      capabilities = {
        ciliumAgent = [
          "CHOWN",
          "KILL",
          "NET_ADMIN",
          "NET_RAW",
          "IPC_LOCK",
          "SYS_ADMIN",
          "SYS_RESOURCE",
          "DAC_OVERRIDE",
          "FOWNER",
          "SETGID",
          "SETUID",
        ]

        cleanCiliumState = [
          "NET_ADMIN",
          "SYS_ADMIN",
          "SYS_RESOURCE",
        ]
      }
    }

    # Answers ARP for LoadBalancer IPs so the pool is reachable on the LAN
    # without BGP.
    l2announcements = {
      enabled = true
    }

    # Leader election between announcing nodes is chatty against the API server.
    k8sClientRateLimit = {
      qps   = var.k8s_client_rate_limit.qps
      burst = var.k8s_client_rate_limit.burst
    }

    # Relay aggregates every agent's flow feed; the UI is the web dashboard
    # that talks to Relay. Both ride on hubble.enabled's flow visibility,
    # which is on by default in the chart.
    hubble = {
      relay = {
        enabled = var.enable_hubble_ui
      }

      ui = {
        enabled = var.enable_hubble_ui

        service = {
          type = var.hubble_ui_service_type
        }
      }
    }
  }
}

resource "helm_release" "cilium" {
  name      = "cilium"
  namespace = "kube-system"

  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version

  wait    = true
  timeout = var.helm_timeout

  # Later entries win, so callers can override any of the defaults above.
  values = [
    yamlencode(local.cilium_values),
    yamlencode(var.cilium_extra_values),
  ]
}

# The LoadBalancer address pool and L2 announcement policy that go with
# l2announcements above live in k8s-infra (charts/cilium-lb-ipam), reconciled
# by Argo CD: only the CNI itself has to exist before Argo CD can run.
