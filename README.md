# Infrastructure

Proxmox + OpenTofu + Ansible homelab running a kubeadm Kubernetes cluster
(Calico CNI) with MetalLB, Traefik, Argo CD and sealed-secrets, plus a
separate Garage VM for S3-compatible object storage.

| What              | Where                                    |
| ----------------- | ---------------------------------------- |
| k8s control plane | 10.130.0.30 (VM 3020)                    |
| k8s workers       | 10.130.0.40-41 (VM 3021-3022)            |
| MetalLB pool      | 10.130.0.50-54                           |
| Garage (S3) VM    | 10.130.0.20 (VM 3010), `storage/` root   |
| S3 endpoint       | http://10.130.0.20:3900, region `garage` |

Argo CD deploys everything under `k8s/` in this repo automatically —
pushing to master is deploying.

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

### Storage (once, survives cluster rebuilds)

The Garage VM has its own Terraform root and state in `storage/`, so nothing
in the cluster root can destroy it. Deploy it first; the cluster only needs
its IP.

```sh
cd storage
ln -s ../terraform.tfvars .   # reuse the credentials
tofu init && tofu plan && tofu apply
```

First boot formats the data disk, installs the pinned Garage binary,
generates the RPC secret and admin token on the VM (they never leave it),
and applies a single-node layout. Check it came up:

```sh
ssh ubuntu@10.130.0.20
sudo cloud-init status --wait     # 0 or 2 = done
sudo garage status                # one healthy node, zone pve, capacity 90G
sudo garage layout show
```

### Cluster

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
kubectl create secret generic myapp --from-literal=password=hunter2 \
  --dry-run=client -o yaml | kubeseal --format yaml > k8s/myapp/secrets-sealed.yaml
# commit + push — Argo CD deploys it
```

or add more keys to an existing secret:

```sh
kubectl create secret generic myapp \
  --from-literal=NEW_KEY=value \
  --dry-run=client -o yaml | kubeseal --format yaml --merge-into k8s/myapp/secrets-sealed.yaml
```

or create a secret from a file:

```sh
kubectl create secret generic myapp \
  --from-env-file=secrets.env \
  --dry-run=client -o yaml | kubeseal --format yaml --merge-into k8s/myapp/secrets-sealed.yaml
```

The playbook backs up the sealing key to `ansible/sealed-secrets-key.yaml`
(gitignored — keep it safe). If that file exists when the playbook runs
against a rebuilt cluster, the key is restored first, so already-committed
sealed secrets remain decryptable.

## Object storage (Garage)

Every app gets its own bucket and key. On the Garage VM, as root:

```sh
garage bucket create myapp
garage key create myapp-key      # prints Key ID and Secret key — copy them now
garage bucket allow --read --write --owner myapp --key myapp-key
garage bucket info myapp
```

Hand them to the app as a sealed secret (path-style addressing, plain HTTP
on the LAN):

```sh
kubectl create secret generic myapp \
  --from-literal=S3_ENDPOINT=http://10.130.0.20:3900 \
  --from-literal=S3_REGION=garage \
  --from-literal=S3_BUCKET=myapp \
  --from-literal=AWS_ACCESS_KEY_ID=GK... \
  --from-literal=AWS_SECRET_ACCESS_KEY=... \
  --dry-run=client -o yaml | kubeseal --format yaml --merge-into k8s/myapp/secrets-sealed.yaml
```

Test from a workstation with the AWS CLI:

```sh
aws --endpoint-url http://10.130.0.20:3900 --region garage s3 ls s3://myapp/
```

### Public files (\*.static.dennisek.se)

Anything that must be reachable by browsers goes in a bucket of its own,
served anonymously by Garage's web endpoint. `k8s/common/garage-web.yaml`
exposes that endpoint as a Service; each app adds an Ingress rule in its own
manifest that points its hostname (`<app>.static.dennisek.se`) at it. Garage
picks the bucket by the Host header, so alias the bucket to the hostname.
Whatever the app uses to build its public links must be that hostname.

```sh
# Bucket and key, as root on the Garage VM
garage bucket create myapp
garage key create myapp-key      # prints Key ID and Secret key — copy them now
garage bucket allow --read --write --owner myapp --key myapp-key
garage bucket alias myapp myapp.static.dennisek.se   # Host header -> bucket
garage bucket website --allow myapp                  # anonymous GET on :3902
```

Upgrading: cloud-init only runs at first boot, so bumping `garage_version`
in `storage/main.tf` affects new VMs only. For the running one, download the
new static binary from the same URL pattern to `/usr/local/bin/garage` and
`systemctl restart garage`. Read the release notes first; major versions
may need a migration step.

Backups: `protection=true` prevents deletion, it does not protect the data.
Add the VM to a vzdump/PBS schedule. `metadata_fsync = true` keeps the
metadata database consistent under crash-style snapshots, and Garage takes
its own metadata snapshots every 6 hours under `/var/lib/garage/meta/snapshots`.

## Tearing down

Destroy the template and instances. The Garage VM is untouched; its data
survives.

```sh
tofu destroy
```

To remove the Garage VM on purpose, lift both guards first: set
`protection = false` and remove `prevent_destroy` in `storage/main.tf`,
apply, then `tofu destroy` in `storage/`.
