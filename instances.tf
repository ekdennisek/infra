variable "ssh_public_key" {
  type = string
}

locals {
  gateway     = "10.130.0.1"
  nameservers = ["10.130.0.1"]
  # Subnet prefix length
  prefix_len = 16

  # Role → per-host settings. Adding a node = adding a line here.
  nodes = {
    "k8s-cp-1" = { role = "control", ip = "10.130.0.2", vm_id = 3010, cores = 2, memory = 4096 }
    "k8s-w-1"  = { role = "worker", ip = "10.130.0.3", vm_id = 3011, cores = 4, memory = 8192 }
    "k8s-w-2"  = { role = "worker", ip = "10.130.0.4", vm_id = 3012, cores = 4, memory = 8192 }
  }
}

# Per-node cloud-init network config, replacing the one Proxmox generates from
# `ip_config`. Why: Proxmox's generated config matches the NIC by MAC and
# renames it to "eth0". The Ubuntu 26.04 cloud image builds its initramfs with
# dracut, which brings the NIC up with DHCP *before* cloud-init runs, so the
# rename fails ("[busy]") and the interface keeps its predictable name (ens18).
# The generated netplan config only matches an interface named "eth0", so it
# never applies and the node keeps the initramfs DHCP lease instead of its
# static IP. This snippet matches "en*" without renaming, so it applies no
# matter what the NIC is called, and it alphabetically outranks dracut's
# catch-all DHCP unit (zzzz-dracut-default.network) in systemd-networkd.
# The alternative fix (net.ifnames=0 on the kernel cmdline) would require
# modifying the disk image outside Terraform; this keeps `tofu apply` the only
# step. Trade-off: the Proxmox UI's Cloud-Init tab no longer shows the IP.
resource "proxmox_virtual_environment_file" "node_network_config" {
  for_each     = local.nodes
  node_name    = var.pve_node
  datastore_id = "local" # must have "Snippets" enabled, same as the vendor-data
  content_type = "snippets"

  source_raw {
    file_name = "${each.key}-network-config.yaml"
    data      = <<-EOT
      network:
        version: 2
        ethernets:
          primary:
            match:
              name: "en*"
            dhcp4: false
            addresses: ["${each.value.ip}/${local.prefix_len}"]
            routes:
              - to: default
                via: "${local.gateway}"
            nameservers:
              addresses: [${join(", ", local.nameservers)}]
              search: [lab.local]
    EOT
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.nodes

  node_name = var.pve_node
  vm_id     = each.value.vm_id
  name      = each.key
  tags      = ["k8s", each.value.role]

  clone {
    vm_id = proxmox_virtual_environment_vm.k8s_template.vm_id
    full  = true
  }

  started = true
  on_boot = true

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  # Optional: override the inherited disk size per role.
  disk {
    datastore_id = "local-zfs"
    interface    = "scsi0"
    size         = each.value.role == "worker" ? 60 : 30
    discard      = "on"
    iothread     = true
  }

  network_device {
    bridge  = "vmbr0"
    model   = "virtio"
    vlan_id = 30
  }

  initialization {
    datastore_id = "local-zfs"
    interface    = "ide2"

    # Re-attach the template's vendor-data so the k8s prereqs still run.
    vendor_data_file_id = proxmox_virtual_environment_file.k8s_vendor_data.id

    # IP/gateway/DNS come from the network-config snippet above, not from
    # `ip_config`/`dns` blocks — see the comment on node_network_config.
    network_data_file_id = proxmox_virtual_environment_file.node_network_config[each.key].id

    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }

  lifecycle {
    # Don't recreate a node because the template got rebuilt.
    ignore_changes = [clone]
  }
}

output "node_ips" {
  value = { for name, cfg in local.nodes : name => cfg.ip }
}

# Handy for generating an Ansible inventory later.
output "control_plane" {
  value = [for name, cfg in local.nodes : name if cfg.role == "control"]
}

output "workers" {
  value = [for name, cfg in local.nodes : name if cfg.role == "worker"]
}
