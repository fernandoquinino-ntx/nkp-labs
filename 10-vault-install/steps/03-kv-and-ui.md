# Step 03 — Enable a KV v2 engine + reach the UI

```bash
NS="${VAULT_NAMESPACE:-vault}"; R="${VAULT_RELEASE:-vault}"
T=$(kubectl -n "$NS" get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
V(){ kubectl -n "$NS" exec "$R-0" -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$T" vault "$@" </dev/null; }
```

## Enable KV v2 at `secret/`

```bash
V secrets enable -path=secret kv-v2        # idempotent-ish: errors if it already exists (fine)
V secrets list                             # -> secret/  kv
```

## Write + read a value

```bash
V kv put secret/app-credentials username=admin password='SuperSecretPassword123'
V kv get secret/app-credentials
V kv list secret/                          # -> app-credentials
```
KV v2 maps `secret/app-credentials` to the API path `secret/data/app-credentials`; in ESO (lab 11)
that's `path: secret` **+** `remoteRef.key: app-credentials`.

## Reach the UI

**Port-forward (no DNS/TLS needed):**
```bash
kubectl -n "$NS" port-forward "svc/$R" 8200:8200       # http://localhost:8200/ui
```
**Or the ingress** (if you enabled it in `values.yaml` and registered DNS → the Traefik LB IP):
`https://${VAULT_HOST}/ui` — sign in with the **root token** (Token method).

## Handy: where does the token live?

```bash
kubectl -n "$NS" get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d; echo
```

**Next:** [04 — teardown](04-teardown.md), or go to **[Lab 11 — ESO](../../11-vault-eso/README.md)**
to pull `secret/app-credentials` into a Kubernetes Secret.
