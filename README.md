# Infrastructure

## Setup

Perform the following steps on the Proxmox machine.

```sh
# Role with the permissions the bpg provider needs
pveum role add TerraformProv -privs "Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Sys.Audit Sys.Console Sys.Modify SDN.Use VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Migrate VM.Monitor VM.PowerMgmt User.Modify"

# A user in the PVE realm (not PAM, so it has no shell login)
pveum user add terraform@pve

# Grant the role at the root path
pveum aclmod / -user terraform@pve -role TerraformProv

# Create the token. --privsep 0 means the token inherits the user's permissions
pveum user token add terraform@pve tf --privsep 0
```

Specify credentials in `terraform.tfvars`:

```sh
pve_endpoint = "https://pve.example.com:8006/"
pve_api_token = "terraform@pve!tf=xxxxxxxx-..."
ssh_public_key = "..."
```

## Deploying

Create the template and instances.

```sh
tofu init      # downloads the bpg provider into .terraform/
tofu plan      # shows what would happen; nothing is changed
tofu apply     # does it, after you type "yes"
```

## Tearing down

Destroy the template and instances.

```sh
tofu destroy
```
