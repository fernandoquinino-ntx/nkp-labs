# Demo — Vault → Kubernetes with ESO (what to show, in ~10 min)

A short, runnable walk-through. Run it from any host that has a kubeconfig for the **management**
cluster and for the **workload** cluster.

> The names below are the lab's generic object names; substitute your own host/cluster values.
> The lab variables (`${WORKLOAD_CLUSTER}`, `${WORKSPACE_NS}`, …) live in `local.env`.

## Set the names once

```bash
MG="kubectl --kubeconfig <management-kubeconfig>"     # the management cluster
DS="kubectl --kubeconfig <workload-kubeconfig>"       # the workload cluster
VAULT_NS=vault                                        # where Vault runs
VAULT_HOST=<vault-hostname>                           # UI/API host, e.g. vault.<your-domain>
WS_NS=<workspace-namespace>                           # the workload cluster's workspace ns on mgmt
```

## What it demonstrates

1. A secret lives in **HashiCorp Vault** (`secret/app-credentials`).
2. The **External Secrets Operator** pulls it into a **native Kubernetes Secret**.
3. The **credential store** (`ClusterSecretStore`) is configured **as an AppDeployment override** —
   a *Helm value* editable in the **NKP UI**, not a hand-applied CR.
4. The same works **on the workload cluster** — ESO is installed there too.

## The environment (generic)

| Piece | Where |
|---|---|
| Vault (KV v2 `secret/`) | management cluster, ns `vault` — UI at `https://$VAULT_HOST/ui` |
| ESO on the management cluster | override `ConfigMap/external-secrets-overrides` (ns `kommander`) → store `vault-backend-lab10` |
| ESO on the workload cluster | override `ConfigMap/external-secrets-overrides` (ns `$WS_NS`) → store `vault-backend` |

## Walk-through (4 acts)

**Act 1 — the secret is in Vault.**
```bash
T=$($MG -n "$VAULT_NS" get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
V(){ $MG -n "$VAULT_NS" exec vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="$T" vault "$@" </dev/null; }
V kv get secret/app-credentials          # -> username / password
```
*(show the UI: `https://$VAULT_HOST/ui`, sign in with the token)*

**Act 2 — the store is set by the AppDeployment override (UI-visible).**
```bash
$MG -n kommander get cm external-secrets-overrides -o jsonpath='{.data.values\.yaml}'      # ONLY the ClusterSecretStore
$MG -n kommander get hr external-secrets -o jsonpath='{.spec.valuesFrom}'                  # the CM is in valuesFrom
$MG -n kommander get appdeployment external-secrets -o jsonpath='{.spec.configOverrides}'  # the UI reference
```

**Act 3 — ESO pulls it (management cluster).**
```bash
$MG get clustersecretstore vault-backend-lab10        # READY True ("store validated")
$MG -n labs get externalsecret lab-app-credentials    # SecretSynced
$MG -n labs logs deploy/lab-eso-demo --tail=4         # username / password
```

**Act 4 — the same on the workload cluster (ESO installed there).**
```bash
$DS -n external-secrets get deploy                    # external-secrets (+ webhook) Running
$DS get clustersecretstore vault-backend              # READY True ("store validated")
$DS -n labs get externalsecret lab-app-credentials    # SecretSynced
$DS -n labs get secret lab-app-credentials -o jsonpath='{.data.password}' | base64 -d; echo
$DS -n labs logs deploy/lab-eso-demo --tail=4         # the value, pulled from Vault
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
   regenerate the target CMs; the platform (app-management + git-operator) had to reconcile — a **UI
   save** of the app normally does this.
3. **Workload-bound Vault auth**: a workload cluster needs its **own** `kubernetes` auth mount
   (e.g. `kubernetes-<cluster>`) — a management-bound mount rejects workload tokens.
4. A stale `${...}` in another app's override CM broke the whole workspace `postBuild` substitution
   (`envsubst ... unable to parse variable name`) → no new app could land. Removing it fixed it.

## Validate the cluster is fully operational (Flux end-to-end)

```bash
$DS -n kommander-flux get deploy          # helm/kustomize/source/notification controllers 1/1
$DS -n kommander-flux get gitrepository   # Ready, current revision
$DS -n "$WS_NS" get kustomization | grep -v True
$DS get hr -A | grep -v True
# the real proof: an app was actually installed through the pipeline:
$DS -n "$WS_NS" get kustomization | grep external-secrets    # external-secrets* Ready
```

## Copy-paste (the 30-second version)

```bash
MG="kubectl --kubeconfig <management-kubeconfig>"; DS="kubectl --kubeconfig <workload-kubeconfig>"
T=$($MG -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
$MG -n vault exec vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="$T" vault kv get secret/app-credentials </dev/null
$MG get clustersecretstore vault-backend-lab10; $MG -n labs logs deploy/lab-eso-demo --tail=4
$DS -n labs get externalsecret lab-app-credentials; $DS -n labs logs deploy/lab-eso-demo --tail=4
```
