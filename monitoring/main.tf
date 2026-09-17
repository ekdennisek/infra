# Monitoring VM (Prometheus + Grafana) — its own Terraform root with its own
# state, like storage/ and nextcloud/, so `tofu destroy` in the cluster root
# cannot touch it. Reuses the parent root's credentials:
# `ln -s ../terraform.tfvars .`
#
# Lives outside the cluster on purpose: it should keep working (and keep its
# history) while the cluster is being rebuilt. All software is installed by
# ansible/monitoring.yml; this root only has to produce a reachable Ubuntu
# box and an inventory line for the playbook.
#
# Not guarded like Garage and Nextcloud: the scrape config and the
# provisioned dashboards come from this repo, so a rebuilt VM loses only the
# metric history and whatever was clicked together in Grafana's UI. Add
# `protection = true` and `prevent_destroy` if that starts to matter.

terraform {
  required_version = ">= 1.5"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = var.pve_api_token
  insecure  = true

  ssh {
    agent    = true
    username = "root"
  }
}

variable "pve_endpoint" {
  type = string
}

variable "pve_api_token" {
  type      = string
  sensitive = true
}

variable "pve_node" {
  type    = string
  default = "pve"
}

variable "ssh_public_key" {
  type = string
}

locals {
  ubuntu_release = "26.04"
  image_url      = "https://cloud-images.ubuntu.com/releases/${local.ubuntu_release}/release-20260731/ubuntu-${local.ubuntu_release}-server-cloudimg-amd64.img"
  image_checksum = "9dc7c5363c0146a08ba0c9aa834d82c2c6dfbb1c471ad9a2f0aba1189e21be05"

  # VM placement. Garage is 3010 / .20, Nextcloud 3015 / .25, k8s nodes are
  # 3020-3022 / .30-.41, MetalLB hands out .50-.54 — keep this IP out of the
  # DHCP scope too.
  vm_id         = 3005
  vm_name       = "monitoring-1"
  monitoring_ip = "10.130.0.15"
  gateway       = "10.130.0.1"
  nameservers   = ["10.130.0.1"]
  prefix_len    = 16
  cores         = 2
  memory        = 2048 # MB
  # OS plus the Prometheus TSDB. A handful of node_exporter targets at a 15 s
  # interval is well under 100 MB a day; the playbook also caps the TSDB by
  # size (prom_retention_size) so it can never fill this disk.
  disk_size = 40 # GB
}

# Own copy of the cloud image (distinct file name) so this root shares no
# resources with the other roots.
resource "proxmox_download_file" "ubuntu" {
  node_name    = var.pve_node
  datastore_id = "local"
  content_type = "import"
  url          = local.image_url
  file_name    = "ubuntu-${local.ubuntu_release}-cloudimg-amd64-monitoring.qcow2"

  checksum            = local.image_checksum
  checksum_algorithm  = "sha256"
  overwrite           = false
  overwrite_unmanaged = true
}

# Same trick as instances.tf in the cluster root: match "en*" instead of
# relying on Proxmox's MAC-based rename to eth0, which fails on the Ubuntu
# 26.04 image. See the comment there for the full story.
resource "proxmox_virtual_environment_file" "monitoring_network_config" {
  node_name    = var.pve_node
  datastore_id = "local" # must have "Snippets" enabled
  content_type = "snippets"

  source_raw {
    file_name = "${local.vm_name}-network-config.yaml"
    data      = <<-EOT
      network:
        version: 2
        ethernets:
          primary:
            match:
              name: "en*"
            dhcp4: false
            addresses: ["${local.monitoring_ip}/${local.prefix_len}"]
            routes:
              - to: default
                via: "${local.gateway}"
            nameservers:
              addresses: [${join(", ", local.nameservers)}]
              search: [lab.local]
    EOT
  }
}

# Minimal first boot: just the guest agent so Terraform can see the VM come
# up. Everything else is Ansible's job (ansible/monitoring.yml), which is
# re-runnable.
resource "proxmox_virtual_environment_file" "monitoring_vendor_data" {
  node_name    = var.pve_node
  datastore_id = "local"
  content_type = "snippets"

  source_raw {
    file_name = "${local.vm_name}-vendor-data.yaml"
    data      = <<-EOT
      #cloud-config
      package_update: true
      packages:
        - qemu-guest-agent
      runcmd:
        - systemctl enable --now qemu-guest-agent
    EOT
  }
}

resource "proxmox_virtual_environment_vm" "monitoring" {
  node_name = var.pve_node
  vm_id     = local.vm_id
  name      = local.vm_name
  tags      = ["monitoring"]

  started = true
  on_boot = true

  machine = "q35"
  bios    = "ovmf"

  efi_disk {
    datastore_id = "local-zfs"
    type         = "4m"
  }

  agent {
    enabled = true
  }

  cpu {
    cores = local.cores
    type  = "host"
  }

  memory {
    dedicated = local.memory
  }

  disk {
    datastore_id = "local-zfs"
    import_from  = proxmox_download_file.ubuntu.id
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    size         = local.disk_size
  }

  scsi_hardware = "virtio-scsi-single"

  network_device {
    bridge  = "vmbr0"
    model   = "virtio"
    vlan_id = 30 # same VLAN as Garage, Nextcloud and the k8s nodes
  }

  serial_device {} # cloud images expect a serial console
  vga {
    type = "serial0"
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = "local-zfs"
    interface    = "ide2"

    vendor_data_file_id  = proxmox_virtual_environment_file.monitoring_vendor_data.id
    network_data_file_id = proxmox_virtual_environment_file.monitoring_network_config.id

    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }
}

# Inventory for ansible/monitoring.yml, so the address lives in one place.
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/monitoring-inventory.ini"
  file_permission = "0644"

  content = <<-EOT
    [monitoring]
    ${local.vm_name} ansible_host=${local.monitoring_ip}

    [monitoring:vars]
    ansible_user=ubuntu
  EOT
}

output "monitoring_ip" {
  value = local.monitoring_ip
}
