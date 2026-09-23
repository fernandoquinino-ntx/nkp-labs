# Step 06 — Create the OIDC Middleware

`[◀ Step 05](05-deploy-demo-app.md)` · `[README](../README.md)` · `[Step 07 ▶](07-protected-ingressroute.md)`

## Goal
Create a `Middleware` whose handler is the **`traefikoidc` plugin**, wired to Okta and to
the Secret from step 04.

## Why it matters
This object is the whole authentication policy: provider, credentials, callback, session
and **authorization** (which domains/groups may enter).

## The manifest
`oidc/middleware.yaml`:
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: oidc-auth
  namespace: ${NAMESPACE}
spec:
  plugin:
    traefikoidc:
      providerURL: "${OKTA_ISSUER}"
      clientID: urn:k8s:secret:okta-oidc:CLIENT_ID
      clientSecret: urn:k8s:secret:okta-oidc:CLIENT_SECRET
      sessionEncryptionKey: urn:k8s:secret:okta-oidc:SESSION_KEY
      callbackURL: /oauth2/callback
      logoutURL: /oauth2/logout
      postLogoutRedirectURI: /
      allowedUserDomains:
        - ${OIDC_ALLOWED_DOMAINS}
      minimalHeaders: true
      logLevel: info
```

### Field-by-field
| Field | Why |
|---|---|
| `providerURL` | OIDC issuer; Traefik discovers endpoints from `/.well-known/openid-configuration`. Must equal the token `iss`. |
| `clientID` | identifies the app to Okta (from the Secret). |
| `clientSecret` | client auth at the token endpoint — **`urn:k8s:secret:<name>:<key>`**, never inline. |
| `sessionEncryptionKey` | encrypts the session cookie; **≥ 32 bytes**. |
| `callbackURL` | path Okta redirects to; the full URL `https://<host>/oauth2/callback` must be registered in Okta. |
| `logoutURL` / `postLogoutRedirectURI` | RP-initiated logout. |
| `allowedUserDomains` | **authorization**: only these email domains. |
| `allowedRolesAndGroups` / `groupClaimName` | optional group-based authorization (needs the `groups` claim + `scopes: [groups]`). |
| `minimalHeaders` | forward fewer identity headers (avoids HTTP 431). |
| `logLevel` | `debug` while learning. |

> `urn:k8s:secret:<name>:<key>` is resolved by Traefik's **Kubernetes CRD provider**, which
> reads the Secret from the **Middleware's own namespace** — so `okta-oidc` must be in
> `${NAMESPACE}`. `${ENV}` does **not** expand in a Kubernetes CR. (Requires a recent
> Traefik v3; on older releases keep the values out of the CR another way.)

## Apply
```bash
./scripts/render.sh 09-traefik-oidc-okta
kubectl apply -f rendered/09-traefik-oidc-okta/oidc/middleware.yaml
```

## Expected output
```bash
kubectl -n "$NS" get middleware oidc-auth
# NAME        AGE
# oidc-auth   ...
```

## Gotchas
- **`invalid handler type: <nil>`** → the plugin isn't enabled (step 03), a config value is
  invalid, or an environment variable name used `${...}` contains the literal `API`.
- A too-short `sessionEncryptionKey` or a non-HTTPS `providerURL` makes the plugin
  **fail closed** (the route returns an error) — check Traefik logs.
- `allowedRolesAndGroups` without a `groups` claim silently **denies everyone**; verify the
  claim actually exists before enabling it.

## ✅ Checkpoint
- [ ] `middleware/oidc-auth` exists and Traefik logs no handler error.

Next: **[Step 07 — Create the protected IngressRoute ▶](07-protected-ingressroute.md)**
