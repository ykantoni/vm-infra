# Same as ubuntu-common.pkr.hcl, plus the NVIDIA driver and container
# toolkit (packer/scripts/install-nvidia.sh) -- only for nodes with a
# pcigpu set in var.nodes. See ubuntu-common.pkr.hcl for the comments on the
# shared build shape; not repeated here.

source "proxmox-clone" "ubuntu_gpu" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  insecure_skip_tls_verify = true

  node                 = var.proxmox_node
  clone_vm_id          = var.seed_template_vm_id
  full_clone           = true
  vm_id                = var.template_vm_id_gpu
  vm_name              = "ubuntu-24.04-rke2-gpu"
  template_name        = "ubuntu-24.04-rke2-gpu"
  template_description = "Hardened Ubuntu 24.04 + RKE2 + NVIDIA driver/toolkit. Built by packer/ubuntu-gpu.pkr.hcl."

  cores  = 2
  memory = 2048

  cloud_init              = true
  cloud_init_storage_pool = var.datastore_id

  ssh_username         = "packer"
  ssh_private_key_file = var.packer_ssh_private_key_file
  ssh_timeout          = "10m"
}

build {
  sources = ["source.proxmox-clone.ubuntu_gpu"]

  provisioner "shell" {
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "${path.root}/scripts/harden.sh",
      "${path.root}/scripts/install-rke2.sh",
      "${path.root}/scripts/install-longhorn-deps.sh",
      "${path.root}/scripts/install-nvidia.sh",
    ]
  }

  provisioner "shell" {
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cloud-init clean --logs",
      "truncate -s 0 /etc/machine-id",
      "rm -f /var/lib/dbus/machine-id",
    ]
  }
}
