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
  endpoint  = var.pve_endpoint  # e.g. https://pve.example.com:8006/
  api_token = var.pve_api_token # "terraform@pve!tf=xxxxxxxx-..."
  insecure  = true              # true if you use the self-signed cert

  # SSH is only needed for a few operations (e.g. uploading snippets on
  # some storage types). Harmless to leave configured.
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

locals {
  ubuntu_release = "26.04"
  # Pin to a dated release, not "current", so the template is reproducible.
  # Grab the checksum from the SHA256SUMS file next to the image.
  image_url      = "https://cloud-images.ubuntu.com/releases/${local.ubuntu_release}/release-20260731/ubuntu-${local.ubuntu_release}-server-cloudimg-amd64.img"
  image_checksum = "9dc7c5363c0146a08ba0c9aa834d82c2c6dfbb1c471ad9a2f0aba1189e21be05"
  k8s_version    = "1.31"
  template_name  = "ubuntu-2604-k8s-${replace(local.k8s_version, ".", "")}"
}

# 1. Fetch the upstream cloud image onto a storage that allows "import"/"iso" content.
resource "proxmox_download_file" "ubuntu" {
  node_name    = var.pve_node
  datastore_id = "local"
  content_type = "import" # bpg accepts .img here; it lands as a .img on the iso store
  url          = local.image_url
  file_name    = "ubuntu-${local.ubuntu_release}-cloudimg-amd64.qcow2"

  checksum           = local.image_checksum
  checksum_algorithm = "sha256"
  overwrite          = false
}

# 2. A vendor-data snippet applied to every VM cloned from the template.
#    This is where you bake in Kubernetes prerequisites at first boot.
#    (If you'd rather bake them into the disk itself, do a Packer proxmox-clone
#    pass on top of this template instead.)
resource "proxmox_virtual_environment_file" "k8s_vendor_data" {
  node_name    = var.pve_node
  datastore_id = "local" # must have "Snippets" enabled in Datacenter > Storage
  content_type = "snippets"

  source_raw {
    file_name = "k8s-vendor-data.yaml"
    data      = <<-EOT
      #cloud-config
      package_update: true
      packages:
        - qemu-guest-agent
        - apt-transport-https
        - ca-certificates
        - curl
        - gpg
        - containerd
        - conntrack
        - socat
      write_files:
        - path: /etc/modules-load.d/k8s.conf
          content: |
            overlay
            br_netfilter
        - path: /etc/sysctl.d/k8s.conf
          content: |
            net.bridge.bridge-nf-call-iptables  = 1
            net.bridge.bridge-nf-call-ip6tables = 1
            net.ipv4.ip_forward                 = 1
      runcmd:
        - systemctl enable --now qemu-guest-agent
        - modprobe overlay && modprobe br_netfilter
        - sysctl --system
        - swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab
        - mkdir -p /etc/containerd
        - containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' > /etc/containerd/config.toml
        - systemctl restart containerd
        - curl -fsSL https://pkgs.k8s.io/core:/stable:/v${local.k8s_version}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        - echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${local.k8s_version}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
        - apt-get update
        - apt-get install -y kubelet kubeadm kubectl
        - apt-mark hold kubelet kubeadm kubectl
    EOT
  }
}

# 3. The template VM itself. Never started; just imports the disk and flips template=true.
resource "proxmox_virtual_environment_vm" "k8s_template" {
  node_name = var.pve_node
  vm_id     = 300
  name      = local.template_name
  tags      = ["template", "ubuntu", "k8s"]

  template = true
  started  = false

  machine = "q35"
  bios    = "ovmf" # drop to "seabios" and remove efi_disk if you prefer

  efi_disk {
    datastore_id = "local-zfs"
    type         = "4m"
  }

  agent {
    enabled = true
  }

  cpu {
    cores = 2
    type  = "x86-64-v2-AES" # "host" is faster but breaks live migration across dissimilar CPUs
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = "local-zfs"
    import_from  = proxmox_download_file.ubuntu.id
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    size         = 20 # GB; larger than the image so growpart expands it on first boot
  }

  scsi_hardware = "virtio-scsi-single"

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  serial_device {} # cloud images expect a serial console
  vga {
    type = "serial0"
  }

  operating_system {
    type = "l26"
  }

  # The cloud-init drive. Clones inherit this; per-instance user/keys/IP get
  # set on the clone, the vendor-data snippet stays attached.
  initialization {
    datastore_id = "local-zfs"
    interface    = "ide2"

    vendor_data_file_id = proxmox_virtual_environment_file.k8s_vendor_data.id

    ip_config {
      ipv4 { address = "dhcp" }
    }
  }
}

output "template_vm_id" {
  value = proxmox_virtual_environment_vm.k8s_template.vm_id
}
