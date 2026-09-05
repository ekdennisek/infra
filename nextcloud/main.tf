# Nextcloud + Euro-Office document server VM — its own Terraform root with its
# own state, like storage/, so `tofu destroy` in the cluster root cannot touch
# it. Reuses the parent root's credentials: `ln -s ../terraform.tfvars .`
#
# The VM is deliberately thin: files live in Garage (S3 primary storage), the
# database is the external PostgreSQL server, and all software is installed
# by ansible/nextcloud.yml. This root only has to produce a reachable Ubuntu
# box and an inventory line for the playbook.
#
# Guarded like the Garage VM (prevent_destroy + protection) even though the
# data lives elsewhere: config/config.php on the OS disk holds the instance
# secret and password salt, without which the database is useless. The
# playbook backs that file up to ansible/nextcloud-config.php (gitignored).

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

  # VM placement. Garage is 3010 / .20, k8s nodes are 3020-3022 / .30-.41,
  # MetalLB hands out .50-.54 — keep this IP out of the DHCP scope too.
  vm_id        = 3015
  vm_name      = "nextcloud-1"
  nextcloud_ip = "10.130.0.25"
  gateway      = "10.130.0.1"
  nameservers  = ["10.130.0.1"]
  prefix_len   = 16
  # Euro-Office alone wants 4 GB; bump here if the box turns out too small.
  cores  = 2
  memory = 4096 # MB
  # OS, PHP, Nextcloud code, caches and the ~5 GB Euro-Office image. User
  # files go to Garage, so this stays small.
  disk_size = 40 # GB
}

# Own copy of the cloud image (distinct file name) so this root shares no
# resources with the other roots.
resource "proxmox_download_file" "ubuntu" {
  node_name    = var.pve_node
  datastore_id = "local"
  content_type = "import"
  url          = local.image_url
  file_name    = "ubuntu-${local.ubuntu_release}-cloudimg-amd64-nextcloud.qcow2"

  checksum            = local.image_checksum
  checksum_algorithm  = "sha256"
  overwrite           = false
  overwrite_unmanaged = true
}

# Same trick as instances.tf in the cluster root: match "en*" instead of
# relying on Proxmox's MAC-based rename to eth0, which fails on the Ubuntu
# 26.04 image. See the comment there for the full story.
resource "proxmox_virtual_environment_file" "nextcloud_network_config" {
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
            addresses: ["${local.nextcloud_ip}/${local.prefix_len}"]
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
# up. Everything else is Ansible's job (ansible/nextcloud.yml), which is
# re-runnable and keeps secrets out of Terraform state.
resource "proxmox_virtual_environment_file" "nextcloud_vendor_data" {
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

resource "proxmox_virtual_environment_vm" "nextcloud" {
  node_name = var.pve_node
  vm_id     = local.vm_id
  name      = local.vm_name
  tags      = ["nextcloud"]

  started = true
  on_boot = true

  # Proxmox-level guard: removal is refused until the flag is lifted.
  protection = true

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
    vlan_id = 30 # same VLAN as Garage and the k8s nodes
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

    vendor_data_file_id  = proxmox_virtual_environment_file.nextcloud_vendor_data.id
    network_data_file_id = proxmox_virtual_environment_file.nextcloud_network_config.id

    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }

  # Terraform-level guard: any plan that would destroy this VM fails.
  lifecycle {
    prevent_destroy = true
  }
}

# Inventory for ansible/nextcloud.yml, so the address lives in one place.
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/nextcloud-inventory.ini"
  file_permission = "0644"

  content = <<-EOT
    [nextcloud]
    ${local.vm_name} ansible_host=${local.nextcloud_ip}

    [nextcloud:vars]
    ansible_user=ubuntu
  EOT
}

output "nextcloud_ip" {
  value = local.nextcloud_ip
}
