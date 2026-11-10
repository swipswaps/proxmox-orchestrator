variable "proxmox_api_url" { type = string; default = "https://192.168.1.100:8006/api2/json" }
variable "proxmox_api_token_id" { type = string; default = "root@pam!orchestrator" }
variable "proxmox_api_token_secret" { type = string; sensitive = true }
variable "target_node" { type = string; default = "pve" }
variable "instance_name" { type = string; default = "managed-node-01" }
variable "instance_type" { type = string; default = "lxc" }
variable "cores" { type = number; default = 2 }
variable "memory" { type = number; default = 2048 }
