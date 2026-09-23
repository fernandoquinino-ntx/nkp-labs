# Step 04 — Create the OIDC Secret

`[◀ Step 03](03-enable-traefik-plugin.md)` · `[README](../README.md)` · `[Step 05 ▶](05-deploy-demo-app.md)`

## Goal
Store the Okta **Client Secret** and the **session encryption key** in a Kubernetes Secret
in the app namespace. The Middleware reads them via `urn:k8s:secret:...` (step 06) so they
never appear in a Custom Resource.

## Why it matters
A `Middleware` is a cluster object that anyone with read access can inspect — secrets must
not live in it. Keeping them in a Secret also lets you rotate them without editing the CR.

## Option A — create it from `local.env` (recommended, nothing hand-edited)
```bash
NS="$(grep ^NAMESPACE= local.env | cut -d= -f2)"; NS=${NS:-labs}
set -a; . ./local.env; set +a

kubectl -n "$NS" create secret generic okta-oidc \
  --from-literal=CLIENT_ID="$OKTA_CLIENT_ID" \
  --from-literal=CLIENT_SECRET="$OKTA_CLIENT_SECRET" \
  --from-literal=SESSION_KEY="$OIDC_SESSION_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Option B — the manifest
```bash
./scripts/render.sh 09-traefik-oidc-okta
kubectl -n "$NS" apply -f rendered/09-traefik-oidc-okta/oidc/secret.example.yaml
```
`oidc/secret.example.yaml` (COPY to `oidc/secret.yaml` if you edit by hand — never commit it):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: okta-oidc
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  CLIENT_ID: "${OKTA_CLIENT_ID}"
  CLIENT_SECRET: "${OKTA_CLIENT_SECRET}"
  SESSION_KEY: "${OIDC_SESSION_KEY}"
```

## Generate a session key if you don't have one
```bash
openssl rand -base64 32        # >= 32 bytes; put it in OIDC_SESSION_KEY
```
> A key shorter than 32 bytes makes the plugin **fail closed** at startup
> (`Session encryption key too short`).

## Expected output
```bash
kubectl -n "$NS" get secret okta-oidc
# NAME        TYPE     DATA   AGE
# okta-oidc   Opaque   3      ...
```

## Gotchas
- Traefik resolves `urn:k8s:secret:<name>:<key>` from the **Middleware's namespace**, so the
  Secret must be in `${NAMESPACE}` (the same namespace as the Middleware/IngressRoute).
- Don't confuse **Okta's** client secret with the **session key** — both live here.

## ✅ Checkpoint
- [ ] `secret/okta-oidc` exists with 3 keys (`CLIENT_ID`, `CLIENT_SECRET`, `SESSION_KEY`).

Next: **[Step 05 — Deploy the demo app ▶](05-deploy-demo-app.md)**
