# The glue: make Vault trust ServiceAccount tokens from `ds-cluster01`

**Why this exists.** Vault's `kubernetes` auth method verifies the presented ServiceAccount token by
calling the **Kubernetes TokenReview API of one specific cluster**. The management cluster already has
a `auth/kubernetes` mount — but it is bound to the **management** cluster (`dc1-nkp-cl01`), so it will
**reject** a token minted by `ds-cluster01`.

> **One `kubernetes` auth mount per cluster.** To let ESO *on `ds-cluster01`* log in to Vault, you add a
> **second** mount whose `kubernetes_host` is the `ds-cluster01` API, plus a long-lived reviewer token
> from `ds-cluster01` that Vault uses to perform those TokenReviews.

```text
ds-cluster01                                    dc1-nkp-cl01 (Vault)
  SA eso-vault ──────────── login(jwt) ─────────▶ auth/kubernetes-ds-cluster01
                                                      │ TokenReview
  SA vault-auth (reviewer) ◀─── uses its JWT ─────────┘  (kubernetes_host = ds-cluster01 API)
  + ClusterRoleBinding system:auth-delegator
```

Everything below runs **on jump-01** (`10.161.195.110`), which holds both kubeconfigs:
`~/dc1-nkp-cl01.conf` (mgmt) and `~/ds-cluster01.conf` (workload).

---

## 1. On `ds-cluster01`: the ESO SA + a reviewer SA/token

```bash
DS="kubectl --kubeconfig ~/ds-cluster01.conf"

# a) the ServiceAccount ESO will present to Vault (referenced by the ClusterSecretStore)
$DS -n external-secrets create serviceaccount eso-vault

# b) a reviewer SA + the RBAC Vault needs to call TokenReview
$DS -n external-secrets create serviceaccount vault-auth
$DS create clusterrolebinding vault-auth-delegator \
      --clusterrole=system:auth-delegator \
      --serviceaccount=external-secrets:vault-auth

# c) a NON-EXPIRING token for the reviewer (k8s ≥1.24 no longer auto-creates these)
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

# d) wait until the token controller fills it, then capture the JWT + the cluster CA
$DS -n external-secrets get secret vault-auth-token -o jsonpath='{.data.token}' | base64 -d
$DS -n external-secrets get secret vault-auth-token -o jsonpath='{.data.ca\.crt}' | base64 -d
```

Find the API the **management** side must dial (the cluster VIP):

```bash
$DS cluster-info | head -1        # e.g. https://10.161.195.6:6443
```

---

## 2. On the management cluster: enable the ds-cluster01-bound mount + role

```bash
MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"

# Vault's CLI lives INSIDE the pod (there is no `vault` binary on the jump host).
T=$($MG -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
V() { $MG -n vault exec -i vault-0 -- \
        env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true VAULT_TOKEN="$T" vault "$@"; }

REVIEWER_JWT=$($DS -n external-secrets get secret vault-auth-token -o jsonpath='{.data.token}' | base64 -d)
DS_CA=$($DS -n external-secrets get secret vault-auth-token -o jsonpath='{.data.ca\.crt}' | base64 -d)

# a) a NEW kubernetes auth mount just for ds-cluster01
V auth enable -path=kubernetes-ds-cluster01 kubernetes

# b) point it at ds-cluster01 and give it the reviewer token + CA.
#    disable_local_ca_jwt=true  -> don't use the local pod's CA/JWT (this is a REMOTE cluster)
#    disable_iss_validation=true -> don't validate the JWT issuer (default off since Vault 1.9;
#                                   drop this field if your build rejects it)
V write auth/kubernetes-ds-cluster01/config \
    kubernetes_host="https://10.161.195.6:6443" \
    kubernetes_ca_cert="$DS_CA" \
    token_reviewer_jwt="$REVIEWER_JWT" \
    disable_local_ca_jwt=true \
    disable_iss_validation=true

# c) a policy ESO's role may use (KV read/list).
#    Use a DISTINCT name — the management cluster's existing role also uses a policy called `eso`
#    (with extra PKI grants). Reusing the name would overwrite it and break the platform's own ESO.
V policy write eso-ds-cluster01 - <<'POL'
path "secret/*" { capabilities = ["read","list"] }
POL

# d) the role bound to the SA the ClusterSecretStore references
V write auth/kubernetes-ds-cluster01/role/eso \
    bound_service_account_names=eso-vault \
    bound_service_account_namespaces=external-secrets \
    policies=eso-ds-cluster01 ttl=1h
```

---

## 3. Verify

```bash
# the mount exists and shows the ds-cluster01 API
V read auth/kubernetes-ds-cluster01/config

# a real login round-trip (mint a token for eso-vault and try to authenticate)
JWT=$($DS -n external-secrets create token eso-vault --duration=10m)
V write auth/kubernetes-ds-cluster01/login role=eso jwt="$JWT"
# -> should print a client_token and a token_policies list containing "eso-ds-cluster01"
```

If the login fails, `vault read auth/kubernetes-ds-cluster01/config`, check the reviewer SA has
`system:auth-delegator`, and confirm the mgmt pods can reach `https://10.161.195.6:6443`.

> **Management cluster already has a `kubernetes` mount + role `eso`** bound to *its own* SA — that one
> is used by the platform's own ESO. Do **not** touch it; this lab adds a separate mount.
