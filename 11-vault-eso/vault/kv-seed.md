# Seed the secret in Vault (KV v2)

The lab syncs **one** KV v2 item, `secret/app-credentials`, holding `username` + `password`. This is the
only thing the lab *writes* to Vault.

> `secret/app-credentials` means: engine mount **`secret`** (KV v2) + item **`app-credentials`**.
> In the ClusterSecretStore that maps to `path: secret` + `remoteRef.key: app-credentials`.

Run on **jump-01** (the management kubeconfig). Vault's CLI runs **inside the pod**:

```bash
MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"
T=$($MG -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
V() { $MG -n vault exec -i vault-0 -- \
        env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="$T" vault "$@"; }

# write (create or overwrite) the item
V kv put secret/app-credentials username=admin password='CHANGE-ME'

# read it back (values are stored under data.* for KV v2)
V kv get secret/app-credentials
```

The value you set here is exactly what will appear in the synced Kubernetes Secret (and in the demo
pod's logs).

**Try the sync later** (Lab README step 08): change the password with the same `kv put`, wait for
`refreshInterval` (1h) — or force a refresh:

```bash
kubectl --kubeconfig ~/ds-cluster01.conf -n "$NAMESPACE" annotate externalsecret "${EXTERNAL_SECRET_NAME}" \
  force-sync="$(date +%s)" --overwrite
```
