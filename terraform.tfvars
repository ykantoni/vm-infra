proxmox_node = "jupiter"

datastore_id = "sdc-storage"
bridge       = "vmbr0"

cluster_name     = "proxclus"
controlplane_vip = "192.168.1.99"

cni            = "cilium"
cilium_version = "1.19.6"

# Longhorn, Prometheus, metrics-server, the GPU operator and the
# LoadBalancer address pool (192.168.1.60-98) are configured in k8s-infra.

gateway = "192.168.1.1"

nameservers = [
  "192.168.1.1",
  "1.1.1.1"
]

nodes = {
  cp1 = {
    vm_id  = 10000
    name   = "cp1"
    ip     = "192.168.1.201"
    mac    = "BC:24:11:00:01:01"
    role   = "controlplane"
    cores  = 2
    memory = 6144
    disk   = 50
  }

  worker1 = {
    vm_id  = 10001
    name   = "w1"
    ip     = "192.168.1.202"
    mac    = "BC:24:11:00:01:02"
    role   = "worker"
    cores  = 4
    memory = 12284
    disk   = 50
    pcigpu = "RTX5060Ti"
  }

  worker2 = {
    vm_id  = 10002
    name   = "w2"
    ip     = "192.168.1.203"
    mac    = "BC:24:11:00:01:03"
    role   = "worker"
    cores  = 4
    memory = 8192
    disk   = 50
  }

  worker3 = {
    vm_id  = 10003
    name   = "w3"
    ip     = "192.168.1.204"
    mac    = "BC:24:11:00:01:04"
    role   = "worker"
    cores  = 4
    memory = 8192
    disk   = 50
  }

  worker4 = {
    vm_id  = 10004
    name   = "w4"
    ip     = "192.168.1.205"
    mac    = "BC:24:11:00:01:05"
    role   = "worker"
    cores  = 4
    memory = 8192
    disk   = 50
  }

  worker5 = {
    vm_id  = 10005
    name   = "w5"
    ip     = "192.168.1.206"
    mac    = "BC:24:11:00:01:06"
    role   = "worker"
    cores  = 4
    memory = 8192
    disk   = 50
  }
}