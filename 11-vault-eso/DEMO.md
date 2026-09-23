# Demo — Vault → Kubernetes with ESO (what to show, in ~10 min)

A short, runnable walk-through. Run it from any host that has a kubeconfig for the **management**
cluster and for the **workload** cluster.

> Nothing below names a real environment. Fill the `NAMES` block once; the rest uses the variables.

## NAMES (fill once — all placeholders)

```bash
# kubeconfigs
MG="kubectl --kubeconfig <mgmt.kubeconfig>"          # the management cluster
DS="kubectl --kubeconfig <workload.kubeconfig>"      # the workload cluster

# Vault
VAULT_NS=<vault-namespace>        # namespace running Vault
VAULT_POD=<vault-pod>            # e.g. <release>-0
VAULT_INIT=<vault-init-secret>   # the Secret holding root_token (unseal output)
VAULT_HOST=<vault-host>          # UI/API hostname, e.g. vault.example.com
KV_ITEM=<kv-item>                # KV v2 item, e.g. app/credentials

# ESO + the override (operator config)
ESO_NS=<eso-namespace>           # where ESO runs (both clusters)
ESO_APP=<eso-app-id>             # the ESO app id
FLUX_NS=<flux-namespace>         # the GitOps/flux namespace on the clusters
OVR_NS=<override-namespace>      # where the ESO AppDeployment + override CM live (on mgmt)
OVR_CM=<override-configmap>      # the UI-visible override ConfigMap
STORE_MGMT=<store-mgmt>          # ClusterSecretStore on the management cluster
STORE_WS=<store-ws>              # ClusterSecretStore on the workload cluster

# the consumer (a non-operator concern)
WS_NS=<workspace-namespace>      # the workload cluster's workspace ns on mgmt
APP_NS=<app-namespace>
ES=<externalsecret-name>         # ExternalSecret
SEC=<secret-name>                # the synced Secret
DEPLOY=<deployment-name>         # the demo Deployment
```

## What it demonstrates

1. A secret lives in **HashiCorp Vault** (`$KV_ITEM`).
2. The **External Secrets Operator** pulls it into a **native Kubernetes Secret**.
3. The **credential store** (`ClusterSecretStore`) is configured **as an AppDeployment override** —
   a *Helm value* editable in the **NKP UI**, not a hand-applied CR.
4. The same works **on the workload cluster** — ESO is installed there too.

## Walk-through (4 acts)

**Act 1 — the secret is in Vault.**
```bash
T=$($MG -n "$VAULT_NS" get secret "$VAULT_INIT" -o jsonpath='{.data.root_token}' | base64 -d)
V(){ $MG -n "$VAULT_NS" exec "$VAULT_POD" -- env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="$T" vault "$@" </dev/null; }
V kv get "$KV_ITEM"                      # -> username / password
```
*(show the UI: `https://$VAULT_HOST/ui`, sign in with the token)*

**Act 2 — the store is set by the AppDeployment override (UI-visible).**
```bash
$MG -n "$OVR_NS" get cm "$OVR_CM" -o jsonpath='{.data.values\.yaml}'      # ONLY the ClusterSecretStore
$MG -n "$OVR_NS" get hr -o jsonpath='{range .items[*]}{.spec.valuesFrom}{"\n"}{end}'   # the CM is in valuesFrom
$MG -n "$OVR_NS" get appdeployment -o jsonpath='{range .items[*]}{.spec.configOverrides}{"\n"}{end}'   # the UI reference
```

**Act 3 — ESO pulls it (management cluster).**
```bash
$MG get clustersecretstore "$STORE_MGMT"          # READY True ("store validated")
$MG -n "$APP_NS" get externalsecret "$ES"         # SecretSynced
$MG -n "$APP_NS" logs deploy/"$DEPLOY" --tail=4   # username / password
```

**Act 4 — the same on the workload cluster (ESO installed there).**
```bash
$DS -n "$ESO_NS" get deploy                        # ESO controller (+ webhook) Running
$DS get clustersecretstore "$STORE_WS"             # READY True ("store validated")
$DS -n "$APP_NS" get externalsecret "$ES"          # SecretSynced
$DS -n "$APP_NS" get secret "$SEC" -o jsonpath='{.data.password}' | base64 -d; echo
$DS -n "$APP_NS" logs deploy/"$DEPLOY" --tail=4    # the value, pulled from Vault
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
   (`kubernetes-<cluster>`) — a management-bound mount rejects workload tokens.
4. A stale `${...}` in another app's override CM broke the whole workspace `postBuild` substitution
   (`envsubst ... unable to parse variable name`) → no new app could land. Removing it fixed it.

## Validate the cluster is fully operational (Flux end-to-end)

```bash
$DS -n "$FLUX_NS" get deploy          # helm/kustomize/source/notification controllers 1/1
$DS -n "$FLUX_NS" get gitrepository   # Ready, current revision
$DS -n "$WS_NS" get kustomization | grep -v True
$DS get hr -A | grep -v True
# the real proof: an app was actually installed through the pipeline:
$DS -n "$WS_NS" get kustomization | grep "$ESO_APP"
```

## Copy-paste (the 30-second version)

```bash
MG="kubectl --kubeconfig <mgmt.kubeconfig>"; DS="kubectl --kubeconfig <workload.kubeconfig>"
VAULT_NS=<vault-namespace>; VAULT_POD=<vault-pod>; VAULT_INIT=<vault-init-secret>; KV_ITEM=<kv-item>
APP_NS=<app-namespace>; ES=<externalsecret-name>; SEC=<secret-name>; DEPLOY=<deployment-name>
T=$($MG -n "$VAULT_NS" get secret "$VAULT_INIT" -o jsonpath='{.data.root_token}' | base64 -d)
$MG -n "$VAULT_NS" exec "$VAULT_POD" -- env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="$T" vault kv get "$KV_ITEM" </dev/null
$MG -n "$APP_NS" logs deploy/"$DEPLOY" --tail=4
$DS -n "$APP_NS" get externalsecret "$ES"; $DS -n "$APP_NS" logs deploy/"$DEPLOY" --tail=4
```
