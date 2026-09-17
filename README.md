# Infrastructure

Proxmox + OpenTofu + Ansible homelab running a kubeadm Kubernetes cluster
(Calico CNI) with MetalLB, Traefik, Argo CD and sealed-secrets, plus a
separate Garage VM for S3-compatible object storage, a Nextcloud VM and a
monitoring VM (Prometheus + Grafana).

| What              | Where                                       |
| ----------------- | ------------------------------------------- |
| k8s control plane | 10.130.0.30 (VM 3020)                       |
| k8s workers       | 10.130.0.40-41 (VM 3021-3022)               |
| MetalLB pool      | 10.130.0.50-54                              |
| Garage (S3) VM    | 10.130.0.20 (VM 3010), `storage/` root      |
| S3 endpoint       | http://10.130.0.20:3900, region `garage`    |
| Nextcloud VM      | 10.130.0.25 (VM 3015), `nextcloud/` root    |
| Monitoring VM     | 10.130.0.15 (VM 3005), `monitoring/` root   |
| Grafana           | https://monitoring.dennisek.se              |
| Prometheus        | http://10.130.0.15:9090 (LAN only, no auth) |

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

## Nextcloud + Euro-Office

A VM of its own (`nextcloud/` root, guarded like Garage) running Nextcloud
from the upstream tarball and the Euro-Office document server in Docker.
Files live in Garage (S3 primary storage), the database on the external
PostgreSQL server at 10.130.0.10, so the VM holds only code, config and
caches. Traefik routes `nextcloud.dennisek.se` and `eods.dennisek.se` to it
via `k8s/nextcloud/nextcloud.yaml`.

Prepare, once:

```sh
# 1. Bucket and key, as root on the Garage VM (see "Object storage")
garage bucket create nextcloud
garage key create nextcloud-key
garage bucket allow --read --write --owner nextcloud --key nextcloud-key

# 2. Database and role on the PostgreSQL server, plus a pg_hba.conf rule
#    that lets 10.130.0.25 connect to it
CREATE USER nextcloud WITH PASSWORD '...';
CREATE DATABASE nextcloud OWNER nextcloud ENCODING 'UTF8' TEMPLATE template0;

# 3. Secrets for the playbook
cp ansible/nextcloud-secrets.example.yml ansible/nextcloud-secrets.yml
$EDITOR ansible/nextcloud-secrets.yml
```

Deploy:

```sh
cd nextcloud
ln -s ../terraform.tfvars .   # reuse the credentials
tofu init && tofu plan && tofu apply   # also writes ansible/nextcloud-inventory.ini

cd ../ansible && ansible-playbook -i nextcloud-inventory.ini nextcloud.yml
# commit + push k8s/nextcloud/ — Argo CD deploys the Ingresses
```

Point DNS for both hostnames at the proxy in front of Traefik, like the other
`*.dennisek.se` names. The proxy should also send the HSTS header, or
Nextcloud's admin overview will nag about it.

The Euro-Office JWT secret is generated on the VM at first run
(`/etc/euro-office/jwt-secret`) and only ever shared with Nextcloud, so
nobody else can open or convert documents through `eods.dennisek.se`.
Its state and logs live in the `euro-office-*` Docker volumes (bind mounts
break the unprivileged services inside the image). Logs:
`sudo docker exec euro-office tail -f /var/log/euro-office/documentserver/docservice/out.log`.

The playbook fetches `config/config.php` to `ansible/nextcloud-config.php`
(gitignored — keep it safe): it holds the instance secret and password salt,
and is restored first when the playbook runs against a rebuilt VM, so the
existing database keeps working.

Upgrading: Euro-Office — bump `eods_image` in `ansible/nextcloud.yml` and
re-run the playbook. Nextcloud — the playbook installs but does not upgrade;
use the built-in updater or `occ upgrade` on the VM, then bump
`nextcloud_version` so a rebuild installs the same version.

## Monitoring (Prometheus + Grafana)

A VM of its own (`monitoring/` root) so it keeps running, and keeps its
history, while the cluster is rebuilt. Prometheus comes from the upstream
release tarball, Grafana from Grafana's apt repository. Prometheus pulls:
every target runs an exporter and the VM scrapes it.

```sh
cd monitoring
ln -s ../terraform.tfvars .   # reuse the credentials
tofu init && tofu plan && tofu apply   # also writes ansible/monitoring-inventory.ini

cd ../ansible && ansible-playbook -i monitoring-inventory.ini monitoring.yml
# commit + push k8s/monitoring/ — Argo CD deploys the Ingress
```

Traefik routes `monitoring.dennisek.se` to Grafana on the VM via
`k8s/monitoring/monitoring.yaml`; point DNS for it at the proxy in front of
Traefik, like the other `*.dennisek.se` names. Grafana's own login is the
only thing between the internet and the dashboards. Its session cookie is
HTTPS-only, so log in through the hostname, not http://10.130.0.15:3000.
Prometheus is not published and must not be: it has no authentication.

Log in to Grafana as `admin`; the password is generated on the VM at first
run: `sudo cat /etc/grafana/admin-password`. It is only read when Grafana
creates its database, so changing it later in the UI does not update the file.

Scrape targets live in the `Write Prometheus config` task of
`ansible/monitoring.yml`; add a job there and re-run the playbook (a config
change is a reload, not a restart). http://10.130.0.15:9090/targets shows
whether each one answers.

| Job          | Target          | What                                  |
| ------------ | --------------- | ------------------------------------- |
| `prometheus` | localhost:9090  | Prometheus itself                     |
| `node`       | localhost:9100  | the monitoring VM (disk, memory)      |
| `compute`    | 10.130.0.5:9100 | compute server, including its AMD GPU |

The playbook does not touch the compute server. It needs a `node_exporter`
on port 9100, reachable from 10.130.0.15, started with `--collector.drm`:
that collector is off by default and is what provides GPU utilisation and
VRAM (`node_drm_*`, read from the `amdgpu` driver's sysfs files, no ROCm
needed). Temperatures, power and fan speed come from the `hwmon` collector,
which is on by default. Until it answers, the `compute` target is simply
down and the GPU dashboard empty.

Dashboards under `ansible/monitoring-dashboards/` are provisioned into
Grafana and read-only there: edit a copy in the UI, export its JSON, commit
it and re-run the playbook. `compute-gpu.json` is the GPU board; for the
hosts themselves import "Node Exporter Full" (ID 1860) in the UI.

The VM is not guarded against `tofu destroy`: losing it loses metric
history and dashboards made in the UI, nothing else. Retention is one year
or 25 GB, whichever comes first (`prom_retention_*` in the playbook).

Upgrading: Prometheus — bump `prom_version` in `ansible/monitoring.yml` and
re-run the playbook. Grafana — `sudo apt update && sudo apt upgrade` on the
VM; if dpkg asks about `grafana.ini`, keep the installed one.

## Tearing down

Destroy the template and instances. The Garage VM is untouched; its data
survives.

```sh
tofu destroy
```

To remove the Garage VM on purpose, lift both guards first: set
`protection = false` and remove `prevent_destroy` in `storage/main.tf`,
apply, then `tofu destroy` in `storage/`.
