# nkp-labs

Small, self-contained **Kubernetes teaching labs** — scenarios you can apply, watch, and clean up in
minutes. Written for **Nutanix Kubernetes Platform (NKP)** but the core labs run on any cluster.

The manifests are **portable templates** (they use `${PLACEHOLDERS}`); you supply the values in
`local.env` and the scripts render + apply them.

## Labs

| # | Lab | What you learn |
|---|---|---|
| 00 | [00-prereqs](00-prereqs/) | a namespace, a **ReadWriteMany StorageClass**, an ingress class, a **domain/DNS** (+ optional default TLS cert) |
| 01 | [01-pvc-rwx-busybox](01-pvc-rwx-busybox/) | a **ReadWriteMany** volume shared by **two pods** (writer + reader) |
| 02 | [02-apache-rwx-multireplica](02-apache-rwx-multireplica/) | one html volume served by **N replicas**, with **two containers in the same pod** sharing it |
| 03 | [03-apache-metallb](03-apache-metallb/) | expose a Service with `type: LoadBalancer` (an external IP, e.g. MetalLB) |
| 04 | [04-apache-traefik-ingress](04-apache-traefik-ingress/) | route a **hostname → Service** through the cluster ingress controller |
| 05 | [05-nkp-appdeployment](05-nkp-appdeployment/) | deploy an application the **NKP way** (`AppDeployment` + config overrides) |

## Quick start

```bash
# 1) set your values (gitignored)
cp local.env.example local.env
$EDITOR local.env

# 2) run a lab (renders templates -> rendered/<lab>/ then kubectl apply)
./scripts/apply.sh 00-prereqs
./scripts/apply.sh 01-pvc-rwx-busybox

# 3) watch it
kubectl -n "$(grep ^NAMESPACE= local.env | cut -d= -f2)" get pvc,pods -w

# 4) clean up
./scripts/cleanup.sh 01-pvc-rwx-busybox
```

Prefer the raw commands? `./scripts/render.sh <lab>` writes `rendered/<lab>/` and you run
`kubectl apply -f rendered/<lab>/` yourself (every lab README shows the exact commands).

## Requirements

- `kubectl` pointing at your cluster.
- **A ReadWriteMany StorageClass** (lab 01/02 need it) — e.g. Nutanix **NUS** `nus-files`, CephFS, NFS,
  Amazon EFS…
- (lab 03) a **LoadBalancer** implementation — e.g. **MetalLB**.
- (lab 04) an **ingress controller** (Traefik/nginx) **+ a DNS name** for the app host; for HTTPS, a TLS
  cert — the cluster's **default cert** or your own Secret.

## Placeholders (`local.env`)

| Variable | Meaning | Example |
|---|---|---|
| `NAMESPACE` | where the labs run | `labs` |
| `RWX_STORAGE_CLASS` | a **ReadWriteMany** StorageClass | `<your-rwx-sc>` (Nutanix: `nus-files`) |
| `PVC_SIZE` | volume size | `1Gi` |
| `DOMAIN` | base domain for the ingress lab | `example.com` |
| `APP_HOST` | hostname label → `<APP_HOST>.<DOMAIN>` | `apache` |
| `INGRESS_CLASS` | the cluster ingress class | `<your-ingress-class>` (NKP: `kommander-traefik`) |
| `REPLICAS` | apache replicas (lab 02) | `3` |

## Layout

```
local.env.example   # documented defaults (copy to local.env)
scripts/            # render.sh, apply.sh, cleanup.sh, dns-add.sh
rendered/           # generated (gitignored)
00-prereqs/ … 05-nkp-appdeployment/
```

## License
MIT (or your choice).
