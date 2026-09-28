# Builds the plain (no GPU) hardened Ubuntu 24.04 + RKE2 Proxmox template.
# Clones the cloud-init-capable seed template that
# vm-templates/import-ubuntu-cloud-image.sh creates, boots it with a
# temporary Packer-managed SSH key (via the seed's own cloud-init drive,
# untouched by modules/rke2-config -- that module's cloud-init only ever
# targets real node clones of *this* template, not the seed), provisions it,
# and re-templates the result.
#
# packer/variables.pkr.hcl documents every variable referenced with var.* below.

source "proxmox-clone" "ubuntu_common" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  insecure_skip_tls_verify = true

  node                 = var.proxmox_node
  clone_vm_id          = var.seed_template_vm_id
  full_clone           = true
  vm_id                = var.template_vm_id_common
  vm_name              = "ubuntu-24.04-rke2-common"
  template_name        = "ubuntu-24.04-rke2-common"
  template_description = "Hardened Ubuntu 24.04 + RKE2 (no GPU). Built by packer/ubuntu-common.pkr.hcl."

  cores  = 2
  memory = 2048

  # Ephemeral cloud-init identity for this build only -- overwritten
  # entirely by modules/rke2-config on every real clone of the resulting
  # template.
  cloud_init              = true
  cloud_init_storage_pool = var.datastore_id

  ssh_username         = "packer"
  ssh_private_key_file = var.packer_ssh_private_key_file
  ssh_timeout          = "10m"
}

build {
  sources = ["source.proxmox-clone.ubuntu_common"]

  provisioner "shell" {
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "${path.root}/scripts/harden.sh",
      "${path.root}/scripts/install-rke2.sh",
      "${path.root}/scripts/install-longhorn-deps.sh",
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
