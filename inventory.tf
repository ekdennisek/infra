# Renders the Ansible inventory from local.nodes so the node list
# lives in exactly one place (instances.tf).
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/ansible/inventory.ini"
  file_permission = "0644"

  content = <<-EOT
    [control_plane]
    ${join("\n", [for name, cfg in local.nodes : "${name} ansible_host=${cfg.ip}" if cfg.role == "control"])}

    [workers]
    ${join("\n", [for name, cfg in local.nodes : "${name} ansible_host=${cfg.ip}" if cfg.role == "worker"])}

    [all:vars]
    ansible_user=ubuntu
  EOT
}
