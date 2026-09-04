# Durable S3 storage VM (Garage) — lives in its OWN Terraform root with its
# own state, so `tofu destroy` in the cluster root cannot touch it. Protected
# two more ways: prevent_destroy (Terraform refuses to plan its destruction)
# and protection=true (Proxmox itself refuses to remove the VM or its disks).
#
# Runs a single Garage node (https://garagehq.deuxfleurs.fr). Apps in the
# cluster talk plain S3 to http://<garage_ip>:3900 — no CSI driver, no
# StorageClass, nothing to install on the nodes. Reuses the parent root's
# credentials: `ln -s ../terraform.tfvars .`
#
# Why a single node with replication_factor = 1: there is one Proxmox host,
# so three Garage replicas would land on the same physical disks anyway.
# Durability comes from ZFS underneath and from backing up the VM. If a
# second Proxmox host ever appears, add a second Garage VM there and raise
# the replication factor with a layout change.
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

  # VM placement. k8s nodes are 3020-3022 / 10.130.0.30-41, MetalLB hands
  # out 10.130.0.50-54 — keep this IP out of the DHCP scope too.
  vm_id       = 3010
  vm_name     = "garage-1"
  garage_ip   = "10.130.0.20"
  gateway     = "10.130.0.1"
  nameservers = ["10.130.0.1"]
  prefix_len  = 16
  cores       = 1
  memory      = 1024 # MB

  # Data disk (scsi1, /dev/sdb in the guest): one XFS filesystem holding both
  # Garage's metadata and data directories. XFS rather than ext4 because
  # Garage stores many small block files and ext4 runs out of inodes first.
  data_disk_size = 100 # GB

  # Garage. Static musl binary from the official release server; bump the
  # version here for new VMs, see README for upgrading a running one.
  garage_version = "v2.3.0"
  garage_url     = "https://garagehq.deuxfleurs.fr/_releases/${local.garage_version}/x86_64-unknown-linux-musl/garage"
  # Layout: how much of the data disk Garage may use, and the zone name.
  # Slightly under the disk size to leave room for metadata and snapshots.
  garage_capacity = "90G"
  garage_zone     = "pve"
}

# Own copy of the cloud image (distinct file name) so this root shares no
# resources with the cluster root — the template there may come and go.
resource "proxmox_download_file" "ubuntu" {
  node_name    = var.pve_node
  datastore_id = "local"
  content_type = "import"
  url          = local.image_url
  file_name    = "ubuntu-${local.ubuntu_release}-cloudimg-amd64-garage.qcow2"

  checksum           = local.image_checksum
  checksum_algorithm = "sha256"
  overwrite          = false
  # If the file is already on the datastore but not in this state (e.g. the
  # state was lost), take it over instead of failing.
  overwrite_unmanaged = true
}

# Same trick as instances.tf in the cluster root: Proxmox's generated network
# config matches the NIC by MAC and renames it to eth0, which fails on the
# Ubuntu 26.04 image (dracut brings the NIC up before cloud-init). Matching
# "en*" applies regardless of the interface name.
resource "proxmox_virtual_environment_file" "garage_network_config" {
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
            addresses: ["${local.garage_ip}/${local.prefix_len}"]
            routes:
              - to: default
                via: "${local.gateway}"
            nameservers:
              addresses: [${join(", ", local.nameservers)}]
              search: [lab.local]
    EOT
  }
}

# First-boot provisioning. Everything secret (rpc_secret, admin token) is
# generated ON the VM by the firstboot script, so nothing sensitive passes
# through Terraform state or this repo.
#
# The node's identity (node_key) and the cluster layout live in metadata_dir
# on the data disk, so rebuilding the OS disk while keeping the data disk
# yields the same node with the same buckets. A fresh rpc_secret on such a
# rebuild is harmless: it only has to match between nodes, and there is one.
resource "proxmox_virtual_environment_file" "garage_vendor_data" {
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
        - xfsprogs
      write_files:
        - path: /etc/garage.toml
          owner: root:root
          permissions: "0640"
          content: |
            # Managed by cloud-init at first boot; edit in place afterwards and
            # `systemctl restart garage`.
            metadata_dir = "/var/lib/garage/meta"
            data_dir     = "/var/lib/garage/data"
            db_engine    = "sqlite"

            # fsync metadata writes so a VM snapshot or crash leaves a
            # consistent database. Data blocks are content-addressed and
            # re-verifiable, so they can skip it.
            metadata_fsync = true
            data_fsync     = false
            # Built-in metadata snapshots, kept under metadata_dir/snapshots.
            metadata_auto_snapshot_interval = "6h"

            # Single Proxmox host: replication would only copy data onto the
            # same disks. See the header comment in main.tf.
            replication_factor = 1

            rpc_bind_addr   = "[::]:3901"
            rpc_public_addr = "${local.garage_ip}:3901"
            rpc_secret      = "__RPC_SECRET__"

            [s3_api]
            s3_region     = "garage"
            api_bind_addr = "[::]:3900"
            # Only matters for virtual-host-style requests; apps use
            # path-style against http://${local.garage_ip}:3900.
            root_domain   = ".s3.lab.local"

            [admin]
            api_bind_addr = "[::]:3903"
            admin_token   = "__ADMIN_TOKEN__"

        - path: /etc/systemd/system/garage.service
          permissions: "0644"
          content: |
            [Unit]
            Description=Garage S3 object store
            Documentation=https://garagehq.deuxfleurs.fr/documentation/
            After=network-online.target
            Wants=network-online.target
            # Never start against an empty mount point.
            RequiresMountsFor=/var/lib/garage

            [Service]
            User=garage
            Group=garage
            ExecStart=/usr/local/bin/garage -c /etc/garage.toml server
            Restart=always
            RestartSec=5
            LimitNOFILE=65536
            # Hardening: read-only system, writable only where it needs to be.
            ProtectSystem=strict
            ProtectHome=true
            PrivateTmp=true
            NoNewPrivileges=true
            ReadWritePaths=/var/lib/garage

            [Install]
            WantedBy=multi-user.target

        - path: /usr/local/sbin/garage-firstboot.sh
          permissions: "0755"
          content: |
            #!/bin/bash
            # Idempotent: safe to re-run by hand. Formats the data disk (once),
            # installs the pinned Garage binary, generates secrets (once) and
            # starts the service.
            set -euo pipefail

            DATA_DEV=/dev/sdb
            MOUNT=/var/lib/garage
            VERSION="${local.garage_version}"
            URL="${local.garage_url}"

            # --- data disk -------------------------------------------------
            # Only format if no filesystem carries our label yet, so a
            # reprovisioned VM with a surviving data disk keeps its data.
            if ! blkid -L garage >/dev/null 2>&1; then
              mkfs.xfs -L garage "$DATA_DEV"
            fi
            mkdir -p "$MOUNT"
            if ! grep -q "LABEL=garage" /etc/fstab; then
              echo "LABEL=garage $MOUNT xfs defaults,nofail 0 2" >> /etc/fstab
              systemctl daemon-reload
            fi
            mountpoint -q "$MOUNT" || mount "$MOUNT"

            # --- user and directories --------------------------------------
            id garage >/dev/null 2>&1 || useradd --system --home-dir "$MOUNT" \
              --shell /usr/sbin/nologin garage
            mkdir -p "$MOUNT/meta" "$MOUNT/data"
            chown -R garage:garage "$MOUNT"
            chgrp garage /etc/garage.toml

            # --- binary ----------------------------------------------------
            if ! /usr/local/bin/garage --version 2>/dev/null | grep -q "$VERSION"; then
              curl -fsSL -o /usr/local/bin/garage.tmp "$URL"
              chmod 755 /usr/local/bin/garage.tmp
              mv /usr/local/bin/garage.tmp /usr/local/bin/garage
            fi

            # --- secrets (generated once, never leave the VM) --------------
            if grep -q __RPC_SECRET__ /etc/garage.toml; then
              sed -i "s/__RPC_SECRET__/$(openssl rand -hex 32)/" /etc/garage.toml
            fi
            if grep -q __ADMIN_TOKEN__ /etc/garage.toml; then
              sed -i "s/__ADMIN_TOKEN__/$(openssl rand -hex 32)/" /etc/garage.toml
            fi

            # --- service ---------------------------------------------------
            systemctl daemon-reload
            systemctl enable --now garage

        - path: /usr/local/sbin/garage-init-layout.sh
          permissions: "0755"
          content: |
            #!/bin/bash
            # A fresh Garage node has no role until a layout is applied. Do it
            # once; on later runs (or a reprovisioned OS disk over an existing
            # data disk) the layout is already in metadata_dir and this is a
            # no-op. Never re-apply --version 1 on a cluster that has a layout.
            set -euo pipefail

            ZONE="${local.garage_zone}"
            CAPACITY="${local.garage_capacity}"

            # Wait for the server to answer.
            for _ in $(seq 1 60); do
              garage status >/dev/null 2>&1 && break
              sleep 2
            done

            if ! garage status | grep -q "NO ROLE ASSIGNED"; then
              echo "layout already applied, nothing to do"
              exit 0
            fi

            # Node ID: first hex ID in the HEALTHY NODES table.
            NODE_ID=$(garage status | grep -oE '^[0-9a-f]{16,}' | head -n 1)
            if [ -z "$NODE_ID" ]; then
              echo "could not determine node id from 'garage status'" >&2
              exit 1
            fi

            garage layout assign -z "$ZONE" -c "$CAPACITY" "$NODE_ID"
            garage layout apply --version 1
            garage layout show

      runcmd:
        - systemctl enable --now qemu-guest-agent
        - /usr/local/sbin/garage-firstboot.sh
        - /usr/local/sbin/garage-init-layout.sh
    EOT
  }
}

resource "proxmox_virtual_environment_vm" "garage" {
  node_name = var.pve_node
  vm_id     = local.vm_id
  name      = local.vm_name
  tags      = ["garage", "storage"]

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
    cores = local.cores
    type  = "host"
  }

  memory {
    dedicated = local.memory
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

  # The data disk Garage lives on (/dev/sdb in the guest).
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
    bridge  = "vmbr0"
    model   = "virtio"
    vlan_id = 30 # same VLAN as the k8s nodes
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

    vendor_data_file_id  = proxmox_virtual_environment_file.garage_vendor_data.id
    network_data_file_id = proxmox_virtual_environment_file.garage_network_config.id

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

output "garage_ip" {
  value = local.garage_ip
}

output "s3_endpoint" {
  value = "http://${local.garage_ip}:3900"
}
