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

Bring up the kubernetes cluster and verify that it's up and running

```sh
cd ansible && ansible-playbook cluster.yml
# verify cluster is up and running
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
```

## Secrets

Secrets are managed with [sealed-secrets](https://github.com/bitnami/sealed-secrets):
encrypted with the cluster's public key, so the sealed files are safe to
commit to this (public) repo. Argo CD applies them like any other manifest
and the in-cluster controller turns them into regular `Secret`s.

One-time: install the `kubeseal` CLI. Then, to create a secret:

```sh
kubectl create secret generic myapp-db --from-literal=password=hunter2 \
  --dry-run=client -o yaml | kubeseal --format yaml > k8s/myapp/db-sealed.yaml
# commit + push — Argo CD deploys it
```

or add more keys to an existing secret:

```sh
kubectl create secret generic myapp-db \
  --from-literal=NEW_KEY=value \
  --dry-run=client -o yaml | kubeseal --format yaml --merge-into k8s/myapp/db-sealed.yaml
```

or create a secret from a file:

```sh
kubectl create secret generic myapp-db \
  --from-env-file=secrets.env \
  --dry-run=client -o yaml | kubeseal --format yaml --merge-into k8s/myapp/db-sealed.yaml
```

The playbook backs up the sealing key to `ansible/sealed-secrets-key.yaml`
(gitignored — keep it safe). If that file exists when the playbook runs
against a rebuilt cluster, the key is restored first, so already-committed
sealed secrets remain decryptable.

## Tearing down

Destroy the template and instances.

```sh
tofu destroy
```
