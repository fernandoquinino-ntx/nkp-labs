# Demo — Vault → Kubernetes with ESO (what to show, in ~10 min)

A short, runnable walk-through of this environment. Everything runs **on jump-01** (`10.161.195.110`).
Copy-paste block at the bottom.

## What it demonstrates

1. A secret lives in **HashiCorp Vault** (`secret/app-credentials`).
2. The **External Secrets Operator** pulls it into a **native Kubernetes Secret**.
3. The **credential store** (`ClusterSecretStore`) is configured **as an AppDeployment override** —
   a *Helm value* editable in the **NKP UI**, not a hand-applied CR.
4. The same works **on the workload cluster `ds-cluster01`** — ESO is installed there too.

## The environment

| Piece | Where |
|---|---|
| Vault (`vault-0`, v1.17.2, KV v2 `secret/`) | **mgmt** `dc1-nkp-cl01`, ns `vault` — UI `https://vault.nkp.ntnxlab.local/ui` (→ `10.161.195.5`) |
| ESO on mgmt (`external-secrets-2.3.0`) | override `ConfigMap/external-secrets-overrides` (ns `kommander`) → store `vault-backend-lab10` |
| ESO on **workload** | `ds-cluster01`, ns `external-secrets` — override `ConfigMap/external-secrets-overrides` (ns `datascience-xmfnz`) → store `vault-backend` |
| Workload secret path | Vault → (mgmt ESO) → `PushSecret` → `ds-cluster01` **and** ESO-on-workload pull |

## Walk-through (4 acts)

**Act 1 — the secret is in Vault.**
```bash
MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"
T=$($MG -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
V(){ $MG -n vault exec vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="$T" vault "$@" </dev/null; }
V kv get secret/app-credentials          # username=admin  password=SuperSecretPassword123
```
*(show the UI: `https://vault.nkp.ntnxlab.local/ui`, sign in with the token)*

**Act 2 — the store is set by the AppDeployment override (UI-visible).**
```bash
$MG -n kommander get cm external-secrets-overrides -o jsonpath='{.data.values\.yaml}'   # ONLY the ClusterSecretStore
$MG -n kommander get hr external-secrets -o jsonpath='{.spec.valuesFrom}'               # the CM is in valuesFrom
$MG -n kommander get appdeployment external-secrets -o jsonpath='{.spec.configOverrides}'  # the UI reference
```

**Act 3 — ESO pulls it (mgmt).**
```bash
$MG get clustersecretstore vault-backend-lab10          # READY True ("store validated")
$MG -n labs get externalsecret lab-app-credentials      # SecretSynced
$MG -n labs logs deploy/lab-eso-demo --tail=4           # admin / SuperSecretPassword123
```

**Act 4 — the same on the workload `ds-cluster01` (ESO installed there).**
```bash
DS="kubectl --kubeconfig ~/ds-cluster01.conf"
$DS -n external-secrets get deploy                      # external-secrets (+ webhook) Running
$DS get clustersecretstore vault-backend                # READY True ("store validated")
$DS -n labs get externalsecret lab-app-credentials      # SecretSynced
$DS -n labs get secret lab-app-credentials -o jsonpath='{.data.password}' | base64 -d; echo
$DS -n labs logs deploy/lab-eso-demo --tail=4           # admin / SuperSecretPassword123  ← from Vault
```

## Punchline (why it's interesting)

- The **`ClusterSecretStore`** — *where Vault is + how to authenticate* — is a **value in an
  AppDeployment override**, so a platform user edits it in the **UI**.
- The chart's **`extraObjects`** value is the bridge that turns that Helm value into a real CR.
- **Operator config ≠ app config:** only the store is in the operator's override; the
  `ExternalSecret` + app are applied by the consumer.

## Gotchas we hit (say them — they're the interesting part)

1. **CRDs must exist before the CR.** A `ClusterSecretStore` in the ESO chart's `extraObjects` fails
   on the *first* install (`no matches for kind "ClusterSecretStore"`), because the CRD is created by
   the same release. **Two-pass install:** install ESO **without** the store → then add the store to
   the override (Helm upgrade → CRD exists → works).
2. **Override changes need the platform to re-emit.** Editing the override ConfigMap alone didn't
   regenerate the target CMs; the platform (app-management + git-operator) had to reconcile — restarting
   those controllers forced a new revision. Normally a **UI save** of the app does this.
3. **Workload-bound Vault auth**: the workload needs its **own** `kubernetes` auth mount
   (`kubernetes-ds-cluster01`) — the mgmt-bound mount rejects workload tokens.
4. A stale `${...}` in another app's override CM (`external-dns-config-overrides`) was breaking the
   whole workspace `postBuild` substitution — fixed.

## Validate the cluster is fully operational (Flux end-to-end)

```bash
DS="kubectl --kubeconfig ~/ds-cluster01.conf"
$DS -n kommander-flux get deploy          # helm/kustomize/source/notification controllers 1/1
$DS -n kommander-flux get gitrepository   # Ready, current revision
$DS -n datascience-xmfnz get kustomization | grep -v True   # (should be empty except nkp-insights)
$DS get hr -A | grep -v True
# the real proof: an app was actually installed through the pipeline:
$DS -n datascience-xmfnz get kustomization | grep external-secrets   # external-secrets* Ready
```
The only red is the **pre-existing** `nkp-insights` (its CloudNativePG `Cluster` CRD is absent → its
postgres job loops). Unrelated to Vault/ESO; disabling or fixing the Insights app clears it.

## Copy-paste (the 30-second version)

```bash
MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"; DS="kubectl --kubeconfig ~/ds-cluster01.conf"
T=$($MG -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
$MG -n vault exec vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="$T" vault kv get secret/app-credentials </dev/null
$MG get clustersecretstore vault-backend-lab10; $MG -n labs logs deploy/lab-eso-demo --tail=4
$DS -n labs get externalsecret lab-app-credentials; $DS -n labs logs deploy/lab-eso-demo --tail=4
```
