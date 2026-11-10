output "instance_ip" {
  value = try(proxmox_lxc.container[0].ssh_host,
              proxmox_vm_qemu.vm[0].default_ipv4_address, "unknown")
}
