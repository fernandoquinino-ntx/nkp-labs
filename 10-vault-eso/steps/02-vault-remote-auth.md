# Step 02 — Teach Vault to trust ServiceAccount tokens from `ds-cluster01`

> Full explanation + the exact commands: [`../vault/remote-auth.md`](../vault/remote-auth.md).
> Optional shortcut: `../scripts/vault-remote-auth.sh [--apply]`.

**The problem.** Vault verifies a Kubernetes ServiceAccount token by calling **that cluster's**
TokenReview API. The management cluster already has a `kubernetes` auth mount, but it is bound to the
**management** cluster — a token minted by `ds-cluster01` will be **rejected**. You need a **second**
mount for the workload cluster.

Shortcut (writes to the workload + management clusters):

```bash
./10-vault-eso/scripts/vault-remote-auth.sh                 # dry-run: print the commands
./10-vault-eso/scripts/vault-remote-auth.sh --apply         # do it
```

By hand:

```bash
MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"
DS="kubectl --kubeconfig ~/ds-cluster01.conf"

# --- on ds-cluster01: the ESO SA + a reviewer SA with a non-expiring token ---
$DS -n external-secrets create serviceaccount eso-vault
$DS -n external-secrets create serviceaccount vault-auth
$DS create clusterrolebinding vault-auth-delegator \
      --clusterrole=system:auth-delegator \
      --serviceaccount=external-secrets:vault-auth
cat <<'YAML' | $DS apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-token
  namespace: external-secrets
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
YAML

# --- on the management cluster: a ds-cluster01-bound auth mount + role ---
T=$($MG -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
V() { $MG -n vault exec -i vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 \
        VAULT_SKIP_VERIFY=true VAULT_TOKEN="$T" vault "$@"; }

JWT=$($DS -n external-secrets get secret vault-auth-token -o jsonpath='{.data.token}' | base64 -d)
CA=$($DS -n external-secrets get secret vault-auth-token -o jsonpath='{.data.ca\.crt}' | base64 -d)
API=$($DS config view --minify -o jsonpath='{.clusters[0].cluster.server}')   # e.g. https://10.161.195.6:6443

V auth enable -path=kubernetes-ds-cluster01 kubernetes
V write auth/kubernetes-ds-cluster01/config \
    kubernetes_host="$API" kubernetes_ca_cert="$CA" token_reviewer_jwt="$JWT" \
    disable_local_ca_jwt=true disable_iss_validation=true
# use a DISTINCT policy name — the management cluster already has a policy called `eso` (with PKI
# grants) used by the platform's own ESO; reusing the name would overwrite it.
V policy write eso-ds-cluster01 - <<'POL'
path "secret/*" { capabilities = ["read","list"] }
POL
V write auth/kubernetes-ds-cluster01/role/eso \
    bound_service_account_names=eso-vault \
    bound_service_account_namespaces=external-secrets \
    policies=eso-ds-cluster01 ttl=1h
```

**Verify** (a real login round-trip):

```bash
JWT=$($DS -n external-secrets create token eso-vault --duration=10m)
$MG -n vault exec -i vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  VAULT_TOKEN="$T" vault write auth/kubernetes-ds-cluster01/login role=eso jwt="$JWT"
# -> client_token + token_policies [eso-ds-cluster01, default]
```

**Gotchas**

- `disable_local_ca_jwt=true` is required for a **remote** cluster (otherwise Vault uses its own pod's
  CA/JWT). Drop `disable_iss_validation=true` only if your Vault build rejects the field.
- The reviewer SA **needs** `system:auth-delegator` or the TokenReview fails with `403`.
- `kubernetes.io/service-account-token` Secrets take a few seconds to be populated — `kubectl get
  secret vault-auth-token -o jsonpath='{.data.token}'` must be non-empty before step c.

---

Next: [03 — seed the Vault secret](03-seed-vault-secret.md)
