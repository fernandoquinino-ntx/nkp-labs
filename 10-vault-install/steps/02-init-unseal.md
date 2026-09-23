# Step 02 — Initialize + unseal

A fresh Vault is **not initialized** and **sealed**. `vault operator init` creates the master key
(Shamir-split into N shares; M are required to reconstruct it) and prints the **unseal keys** and a
**root token** — **once**. Store them safely.

```bash
NS="${VAULT_NAMESPACE:-vault}"; R="${VAULT_RELEASE:-vault}"
```

## 1. Initialize

```bash
kubectl -n "$NS" exec "$R-0" -- vault operator init -key-shares=5 -key-threshold=3 -format=json
```
Copy the output somewhere safe (it contains `unseal_keys_b64[]` and `root_token`). The helper stores
it in `Secret/vault-init`:

```bash
./10-vault-install/scripts/init-unseal.sh --apply
```

## 2. Unseal (needs 3 of 5 keys)

```bash
KEY1=...; KEY2=...; KEY3=...      # unseal_keys_b64 from the init output
kubectl -n "$NS" exec "$R-0" -- vault operator unseal "$KEY1"
kubectl -n "$NS" exec "$R-0" -- vault operator unseal "$KEY2"
kubectl -n "$NS" exec "$R-0" -- vault operator unseal "$KEY3"
kubectl -n "$NS" exec "$R-0" -- vault status        # Sealed=false
```

For **HA**, repeat the three `unseal` calls for **every** pod (`$R-0`, `$R-1`, `$R-2`) — with the
*same* keys.

> After a pod restart/upgrade Vault is **sealed again** → re-unseal. (Auto-unseal needs a cloud KMS;
> out of scope here.)

## 3. Log in with the root token

```bash
TOKEN=$(kubectl -n "$NS" get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
kubectl -n "$NS" exec "$R-0" -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$TOKEN" vault login "$TOKEN"
```

**Verify:** `vault status` shows `Initialized true`, `Sealed false`.

Next: [03 — KV v2 + UI](03-kv-and-ui.md)
