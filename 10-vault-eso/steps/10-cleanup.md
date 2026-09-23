# Step 10 — Cleanup

Remove things in reverse order. Deleting the **store** does not delete the synced Secret if it was
created with `creationPolicy: Owner` — ESO garbage-collects it, but check.

```bash
MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"
DS="kubectl --kubeconfig ~/ds-cluster01.conf"
NS="${NAMESPACE:-labs}"; WS="${WORKSPACE_NS:-datascience-xmfnz}"
SS="${SECRETSTORE_NAME:-vault-backend}"; ES="${EXTERNAL_SECRET_NAME:-lab-app-credentials}"

# --- Path A (override): clear the extraObjects -> Helm removes store+secret+demo ---------------
#   Easiest: edit the override in the UI and delete the extraObjects block, OR delete the ConfigMap
#   and re-point the AppDeployment. To tear the whole app down for the cluster:
$MG -n "$WS" delete appdeployment "${ESO_APP_ID:-external-secrets}" --ignore-not-found
#   (this also uninstalls ESO from ds-cluster01 — only do it if you don't want it there)

# --- Path B (raw manifests) -------------------------------------------------------------------
$DS -n "$NS" delete deploy lab-eso-demo --ignore-not-found
$DS -n "$NS" delete externalsecret "$ES" --ignore-not-found
$DS delete clustersecretstore "$SS" --ignore-not-found
$DS -n "$NS" delete secret "$ES" --ignore-not-found          # if leftovers
$DS delete ns "$NS" --ignore-not-found                        # only if the lab created it

# --- the Vault glue on the workload -----------------------------------------------------------
$DS delete clusterrolebinding vault-auth-delegator --ignore-not-found
$DS -n external-secrets delete secret vault-auth-token --ignore-not-found
$DS -n external-secrets delete serviceaccount vault-auth --ignore-not-found
$DS -n external-secrets delete serviceaccount eso-vault --ignore-not-found
```

Optional — remove the management-side auth mount (only if nothing else uses it):

```bash
MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"
T=$($MG -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
$MG -n vault exec -i vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  VAULT_TOKEN="$T" vault auth disable kubernetes-ds-cluster01
```

> **Do not** disable the management cluster's own `kubernetes` mount — the platform's ESO uses it.
> The KV item `secret/app-credentials` can stay; delete it with
> `vault kv metadata delete secret/app-credentials` if you want a clean slate.

**Verify:** `$DS get clustersecretstore,externalsecret -A` shows nothing from this lab, and
`$MG -n "$WS" get appdeployment external-secrets` is gone (if you removed the app).
