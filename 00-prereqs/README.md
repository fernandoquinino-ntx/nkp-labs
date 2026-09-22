# Lab 00 — prerequisites

Sets up the shared namespace and documents what the other labs assume.

## What this lab creates
- a **Namespace** (`${NAMESPACE}`, default `labs`) where every lab deploys.

```bash
./scripts/apply.sh 00-prereqs
kubectl get ns "$(grep ^NAMESPACE= local.env | cut -d= -f2)"
```

## Before you start — check your cluster
```bash
kubectl config current-context
kubectl get nodes
```

### 1) A ReadWriteMany StorageClass (labs 01 & 02 need it)
The busybox/Apache labs share **one volume between several pods** → the volume must be **RWX**.
```bash
kubectl get storageclass            # look for one that supports ReadWriteMany
```
Examples: Nutanix **NUS** `nus-files`, CephFS, NFS (`nfs-client`), Amazon EFS, Azure Files.
Set it in `local.env`:
```
RWX_STORAGE_CLASS=nus-files
```

### 2) An ingress controller (lab 04)
```bash
kubectl get ingressclass            # e.g. kommander-traefik (NKP), nginx
```
Set `INGRESS_CLASS=` in `local.env`.

### 3) A domain + DNS for the ingress lab (lab 04)
The app is served at `${APP_HOST}.${DOMAIN}` (e.g. `apache.apps.example.com`). The name must resolve to
the **ingress controller's external IP**.
- If your platform gives you a **wildcard** (e.g. `*.apps.<cluster>.<domain>` → the ingress LB), just pick
  `APP_HOST`.
- Otherwise add one A record (see `scripts/dns-add.sh`, which uses `nsupdate` against a dynamic BIND zone):
  ```bash
  NAME=apache.apps.example.com IP=<ingress-LB-IP> RSH=you@<dns-server> ./scripts/dns-add.sh
  ```

### 4) TLS / the "default certificate" (lab 04, HTTPS)
If your ingress controller has a **default TLS certificate** installed, an ingress with **no** `tls:`
block will serve HTTPS using it (hostname must match the cert's SANs). Otherwise:
- use HTTP (port 80), or
- reference your own cert Secret in the ingress (`tls.secretName`).

**Nutanix NKP (Traefik, managed cluster) note:** a wildcard cert `apps-default-tls` is often installed;
point Traefik's default at it so any host under the wildcard is trusted:
```bash
kubectl -n <traefik-ns> patch tlsstore default --type merge \
  -p '{"spec":{"defaultCertificate":{"secretName":"apps-default-tls"}}}'
```

## Placeholders used in `local.env`
| Var | Meaning |
|---|---|
| `NAMESPACE` | namespace for all labs |
| `RWX_STORAGE_CLASS` | a ReadWriteMany StorageClass |
| `PVC_SIZE` | volume size (e.g. `1Gi`) |
| `DOMAIN` / `APP_HOST` | ingress host = `${APP_HOST}.${DOMAIN}` |
| `INGRESS_CLASS` | the cluster's ingress class |
| `REPLICAS` | apache replicas (lab 02) |
