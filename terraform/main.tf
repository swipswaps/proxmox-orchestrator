terraform {
  required_version = ">= 1.16.0"
  required_providers { proxmox = { source = "Telmate/proxmox", version = "3.0.2-rc10" } }
}
provider "proxmox" {
  pm_api_url = var.proxmox_api_url
  pm_api_token_id = var.proxmox_api_token_id
  pm_api_token_secret = var.proxmox_api_token_secret
  pm_tls_insecure = true
}
resource "proxmox_lxc" "container" {
  count = var.instance_type == "lxc" ? 1 : 0
  target_node = var.target_node; hostname = var.instance_name
  ostemplate = "local:vztmpl/debian-12-standard_12.2-1_amd64.zst"
  cores = var.cores; memory = var.memory; unprivileged = true; start = true
  rootfs { storage = "local-lvm"; size = "8G" }
  network { name = "eth0"; bridge = "vmbr0"; ip = "dhcp" }
}
resource "proxmox_vm_qemu" "vm" {
  count = var.instance_type == "vm" ? 1 : 0
  name = var.instance_name; target_node = var.target_node
  clone = "debian-12-template"; cores = var.cores; memory = var.memory
  agent = 1; os_type = "cloud-init"
  disk { size = "10G"; type = "scsi"; storage = "local-lvm" }
  network { model = "virtio"; bridge = "vmbr0" }
}
