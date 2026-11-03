variable "vm_name" {
  type    = string
  default = "k3s-vm-1"
}

variable "vcpu" {
  type    = number
  default = 2
}

variable "memory_mib" {
  type    = number
  default = 4096
}

variable "disk_gib" {
  type    = number
  default = 30
}

variable "base_image" {
  description = "Image Debian 12 cloud existante, utilisée en lecture seule comme base"
  type        = string
  default     = "/var/lib/libvirt/images/debian-12-generic-amd64.qcow2"
}

variable "ssh_pubkey_path" {
  type    = string
  default = "~/.ssh/homelab_ansible_ed25519.pub"
}
