terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.9"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

# Disque de la VM, en copie sur écriture au-dessus de l'image de base
resource "libvirt_volume" "disk" {
  name     = "${var.vm_name}.qcow2"
  pool     = "images"
  capacity = var.disk_gib * 1024 * 1024 * 1024

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = var.base_image
    format = { type = "qcow2" }
  }
}

# ISO cloud-init : nom d'hôte, utilisateur ansible et sa clé
resource "libvirt_cloudinit_disk" "init" {
  name = "${var.vm_name}-cidata"

  user_data = <<-EOF
    #cloud-config
    hostname: ${var.vm_name}
    users:
      - name: ansible
        groups: sudo
        shell: /bin/bash
        sudo: ALL=(ALL) NOPASSWD:ALL
        ssh_authorized_keys:
          - ${trimspace(file(pathexpand(var.ssh_pubkey_path)))}
  EOF

  meta_data = yamlencode({
    instance-id    = var.vm_name
    local-hostname = var.vm_name
  })
}

# L'ISO est déposée dans le pool pour être branchée à la VM
resource "libvirt_volume" "cidata" {
  name = "${var.vm_name}-cidata.iso"
  pool = "images"

  create = {
    content = {
      url = libvirt_cloudinit_disk.init.path
    }
  }
}

resource "libvirt_domain" "k3s" {
  name        = var.vm_name
  type        = "kvm"
  vcpu        = var.vcpu
  memory      = var.memory_mib
  memory_unit = "MiB"
  running     = true
  autostart   = false

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
  }
  cpu = {
    mode = "host-passthrough"
  }
  features = {
    acpi = true
    apic = {}
  }
  devices = {

    serials = [
      { target = { type = "isa-serial", port = 0 } }
    ]
    consoles = [
      { target = { type = "serial", port = 0 } }
    ]
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.disk.pool
            volume = libvirt_volume.disk.name
          }
        }
        target = { bus = "virtio", dev = "vda" }
        driver = { type = "qcow2" }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_volume.cidata.pool
            volume = libvirt_volume.cidata.name
          }
        }
        target = { bus = "sata", dev = "sda" }
      }
    ]

    interfaces = [
      {
        type   = "network"
        model  = { type = "virtio" }
        source = { network = { network = "default" } }
      }
    ]

    graphics = [
      { vnc = { auto_port = true, listen = "127.0.0.1" } }
    ]
  }
}

data "libvirt_domain_interface_addresses" "k3s" {
  domain = libvirt_domain.k3s.name
  source = "lease"
}

output "ip" {
  value = try(
    data.libvirt_domain_interface_addresses.k3s.interfaces[0].addrs[0].addr,
    "pas encore de bail DHCP : relancer terraform apply -refresh-only"
  )
}
