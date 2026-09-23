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
| 06 | [06-long-lived-token-kubeconfig](06-long-lived-token-kubeconfig/) | a **long-lived ServiceAccount token** + a ready **kubeconfig** for an app/CI (least privilege) |
| 07 | [07-velero-bsl](07-velero-bsl/) | configure a **Velero Backup Storage Location (BSL)** (UI + CLI), write **backup policies** (`Schedule`s), **back up & restore a persistent app** (volumes), + the Velero/NKP **CRDs** |
| 08 | [08-splunk-otel-helm](08-splunk-otel-helm/) | install the **Splunk OpenTelemetry Collector** with **plain `helm`** (no catalog) — every setting explained, **logs + metrics** to Splunk over HEC, and **troubleshooting** |
| 09 | [09-traefik-oidc-okta](09-traefik-oidc-okta/) | protect an app with **Okta OIDC** using the **Traefik OIDC plugin middleware** — a hands-on lab with a **page per step** (`steps/01…10`), no oauth2-proxy, no Dex |
| 10 | [10-vault-install](10-vault-install/) | install **HashiCorp Vault** (dev / standalone / HA), **initialize + unseal** it, enable a **KV v2** engine and reach the UI — the prerequisite for lab 11 |
| 11 | [11-vault-eso](11-vault-eso/) | pull a secret from **Vault** with the **External Secrets Operator** — the **`ClusterSecretStore`** (the "credential store") set via an **NKP `AppDeployment` override** (`extraObjects`), so it is **visible/editable in the UI** |

## Procedures (step-by-step, copy-paste)

| Doc | What |
|---|---|
| [docs/long-lived-token-kubeconfig.md](docs/long-lived-token-kubeconfig.md) | a **long-lived ServiceAccount token** + a ready **kubeconfig** for an app/CI (least privilege) |

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
- `helm` (v3) for **lab 08** (the Splunk OTel Collector chart).
- **A ReadWriteMany StorageClass** (lab 01/02 need it) — e.g. Nutanix **NUS** `nus-files`, CephFS, NFS,
  Amazon EFS…
- (lab 03) a **LoadBalancer** implementation — e.g. **MetalLB**.
- (lab 04) an **ingress controller** (Traefik/nginx) **+ a DNS name** for the app host; for HTTPS, a TLS
  cert — the cluster's **default cert** or your own Secret.
- (lab 08) a **Splunk HEC endpoint + token**, and the two indexes the token allows; the cluster nodes
  must reach the endpoint on `:8088`.

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
| `SA_NAME` | ServiceAccount name (lab 06) | `lab-app` |
| `VELERO_NS` | namespace where Velero runs (lab 07) | `kommander` |
| `OTEL_NAMESPACE` / `OTEL_RELEASE` / `CHART_VERSION` | collector namespace / Helm release / chart version (lab 08) | `splunk-otel` / `splunk-otel-collector` / `0.160.0` |
| `SPLUNK_CLUSTER_NAME` | `k8s.cluster.name` — unique per cluster (lab 08) | `dc1-nkp-cl01` |
| `SPLUNK_HEC_ENDPOINT` | Splunk HEC URL (lab 08) | `https://<stack>.splunkcloud.com:8088/services/collector/event` |
| `SPLUNK_HEC_TOKEN` | **secret** HEC token (lab 08) — gitignored only | `<uuid>` |
| `SPLUNK_INDEX` / `SPLUNK_METRICS_INDEX` | events / metrics indexes, both **token-allowed** (lab 08) | `k8s_logs` / `k8s_metrics` |
| `OIDC_HOST` | app host label for the OIDC lab → `<OIDC_HOST>.<DOMAIN>` (lab 09) | `whoami` |
| `TRAEFIK_NS` | namespace where Traefik runs (lab 09: the plugin override) | `kommander` |
| `OIDC_PLUGIN_VERSION` | `traefikoidc` plugin version (lab 09) | `v1.0.36` |
| `OKTA_ISSUER` | Okta OIDC issuer URL (lab 09) | `https://<org>.okta.com` |
| `OKTA_CLIENT_ID` / `OKTA_CLIENT_SECRET` | Okta app credentials (lab 09) | `<id>` / `<secret>` (**secret**) |
| `OIDC_SESSION_KEY` | cookie encryption key, ≥32 bytes (lab 09) | `openssl rand -base64 32` (**secret**) |
| `OIDC_ALLOWED_DOMAINS` / `OIDC_ALLOWED_GROUPS` | authorization filters (lab 09) | `example.com` / `My-App-Users` |
| `VAULT_NAMESPACE` / `VAULT_RELEASE` | where Vault runs / its Helm release name (lab 10) | `vault` / `vault` |
| `VAULT_HOST` / `VAULT_STORAGE_CLASS` | ingress hostname / PVC storage class for Vault (lab 10) | `vault.nkp.ntnxlab.local` / `nutanix-volume` |
| `VAULT_REPLICAS` | Vault HA replicas (1 = standalone, 3 = HA raft) (lab 10) | `1` |
| `VAULT_APP_VERSION` | NKP catalog Vault app version (lab 10) | `0.34.1` |
| `WORKLOAD_CLUSTER` / `WORKSPACE_NS` | target workload cluster / its **workspace** namespace on the mgmt cluster (lab 11) | `ds-cluster01` / `datascience-xmfnz` |
| `ESO_APP_ID` / `ESO_APP_VERSION` / `ESO_CLUSTERAPP` / `ESO_OVERRIDES_CM` | ESO platform app + the AppDeployment override ConfigMap (lab 11) | `external-secrets` / `2.3.0` / `external-secrets-2.3.0` / `external-secrets-overrides` |
| `ESO_NAMESPACE` / `ESO_SA` | where ESO runs / the SA it presents to Vault (lab 11) | `external-secrets` / `eso-vault` |
| `SECRETSTORE_NAME` / `EXTERNAL_SECRET_NAME` | the `ClusterSecretStore` / the `ExternalSecret` (lab 11) | `vault-backend` / `lab-app-credentials` |
| `VAULT_SERVER` / `VAULT_CA_BUNDLE` | Vault endpoint reachable from the workload / base64 PEM of its CA (lab 11) | `https://vault.nkp.ntnxlab.local` / `scripts/fetch-vault-ca.sh` (**secret-ish**) |
| `VAULT_AUTH_MOUNT` / `VAULT_ROLE` / `VAULT_POLICY` | Vault kubernetes auth mount / role / policy (lab 11) | `kubernetes-ds-cluster01` / `eso` / `eso-ds-cluster01` |
| `VAULT_KV_MOUNT` / `VAULT_SECRET_PATH` | KV v2 engine mount / item path (lab 11) | `secret` / `app-credentials` |
| `VAULT_USERNAME` / `VAULT_PASSWORD` | the demo secret seeded in Vault (lab 11, **secret**) | `admin` / `CHANGE-ME` |
| `DEMO_IMAGE` | demo consumer image (lab 11) | `busybox:1.36` |

## Layout

```
local.env.example   # documented defaults (copy to local.env)
scripts/            # render.sh, apply.sh, cleanup.sh, dns-add.sh
rendered/           # generated (gitignored)
00-prereqs/ … 11-vault-eso/
```

## License
MIT (or your choice).
