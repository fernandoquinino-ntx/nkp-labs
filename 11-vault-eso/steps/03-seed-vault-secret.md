# Step 03 — Seed the secret in Vault (KV v2)

> Details: [`../vault/kv-seed.md`](../vault/kv-seed.md).

```bash
MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"
T=$($MG -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
V() { $MG -n vault exec -i vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 \
        VAULT_SKIP_VERIFY=true VAULT_TOKEN="$T" vault "$@"; }

V kv put secret/app-credentials username=admin password='CHANGE-ME'
V kv get secret/app-credentials
```

`secret/app-credentials` = KV v2 engine **`secret`** + item **`app-credentials`**. In the store that is:

```yaml
path: secret                 # engine mount
remoteRef: {key: app-credentials}   # item  (NOT "secret/app-credentials")
```

**Verify:** `V kv get -field=username secret/app-credentials` prints `admin`.

---

Next: [04 — enable ESO on the workload cluster](04-enable-eso.md)
