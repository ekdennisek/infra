# Durable storage VM — lives in its OWN Terraform root with its own state,
# so `tofu destroy` in the cluster root cannot touch it. Protected two more
# ways: prevent_destroy (Terraform refuses to plan its destruction) and
# protection=true (Proxmox itself refuses to remove the VM or its disks).
#
# Serves /export/k8s over NFS to the cluster; consumed by csi-driver-nfs.
# Reuses the parent root's credentials: `ln -s ../terraform.tfvars .`
#
# NOTE: protection is not backup — point vzdump/PBS at this VM.

terraform {
  required_version = ">= 1.5"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
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

  storage_ip     = "10.130.0.40"
  gateway        = "10.130.0.1"
  nameservers    = ["10.130.0.1"]
  prefix_len     = 16
  data_disk_size = 100 # GB
  # Only the LAN may mount the export. no_root_squash is required: the
  # csi-driver-nfs controller creates per-PVC subdirectories as root.
  export_clients = "10.130.0.0/16"
}

# Own copy of the cloud image (distinct file name) so this root shares no
# resources with the cluster root — the template there may come and go.
resource "proxmox_download_file" "ubuntu" {
  node_name    = var.pve_node
  datastore_id = "local"
  content_type = "import"
  url          = local.image_url
  file_name    = "ubuntu-${local.ubuntu_release}-cloudimg-amd64-storage.qcow2"

  checksum           = local.image_checksum
  checksum_algorithm = "sha256"
  overwrite          = false
}

resource "proxmox_virtual_environment_file" "nfs_vendor_data" {
  node_name    = var.pve_node
  datastore_id = "local"
  content_type = "snippets"

  source_raw {
    file_name = "nfs-vendor-data.yaml"
    data      = <<-EOT
      #cloud-config
      package_update: true
      packages:
        - qemu-guest-agent
        - nfs-kernel-server
      # Format the data disk on first boot only — overwrite:false leaves an
      # existing filesystem (and its data) alone on later reprovisioning.
      fs_setup:
        - device: /dev/sdb
          filesystem: ext4
          label: k8sdata
          overwrite: false
      mounts:
        - ["LABEL=k8sdata", "/export/k8s", "ext4", "defaults,nofail", "0", "2"]
      write_files:
        - path: /etc/exports
          content: |
            /export/k8s ${local.export_clients}(rw,sync,no_subtree_check,no_root_squash)
      runcmd:
        - systemctl enable --now qemu-guest-agent
        - exportfs -ra
    EOT
  }
}

resource "proxmox_virtual_environment_vm" "storage" {
  node_name = var.pve_node
  vm_id     = 3020
  name      = "storage-1"
  tags      = ["storage", "nfs"]

  started = true
  on_boot = true

  # Proxmox-level guard: removal is refused (API, qm, web UI) until the
  # flag is explicitly lifted.
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
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  # OS disk, imported from the cloud image.
  disk {
    datastore_id = "local-zfs"
    import_from  = proxmox_download_file.ubuntu.id
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    size         = 10
  }

  # The data disk all NFS exports live on (/dev/sdb in the guest).
  disk {
    datastore_id = "local-zfs"
    interface    = "scsi1"
    iothread     = true
    discard      = "on"
    size         = local.data_disk_size
    file_format  = "raw"
  }

  scsi_hardware = "virtio-scsi-single"

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  serial_device {}
  vga {
    type = "serial0"
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = "local-zfs"
    interface    = "ide2"

    vendor_data_file_id = proxmox_virtual_environment_file.nfs_vendor_data.id

    ip_config {
      ipv4 {
        address = "${local.storage_ip}/${local.prefix_len}"
        gateway = local.gateway
      }
    }

    dns {
      servers = local.nameservers
      domain  = "lab.local"
    }

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

output "nfs_server" {
  value = local.storage_ip
}

output "nfs_export" {
  value = "/export/k8s"
}
