# Step 10 — Cleanup

`[◀ Step 09](09-troubleshooting.md)` · `[README](../README.md)`

## Goal
Remove everything the lab created, in the safe order, and (optionally) revert the
cluster-wide plugin change.

## Order matters
```mermaid
flowchart LR
    IR[IngressRoute] --> MW[Middleware] --> APP[Deployment+Service] --> SEC[Secret] --> PLG[plugin override]
```
Delete the **route first** (stop serving), then the middleware, then the workload/secret, and
only then consider the plugin.

## Option A — scripts
```bash
./09-traefik-oidc-okta/scripts/uninstall.sh            # app + secret + middleware + route
./09-traefik-oidc-okta/scripts/uninstall.sh --plugin   # + revert the Traefik override
```

## Option B — by hand
```bash
NS="$(grep ^NAMESPACE= local.env | cut -d= -f2)"; NS=${NS:-labs}
TRAEFIK_NS=kommander

kubectl -n "$NS" delete ingressroute whoami --ignore-not-found
kubectl -n "$NS" delete middleware oidc-auth --ignore-not-found
kubectl -n "$NS" delete deploy/whoami svc/whoami --ignore-not-found
kubectl -n "$NS" delete secret okta-oidc --ignore-not-found
```

### Revert the plugin (only if you enabled it for this lab)
```bash
# detach the override from the AppDeployment
kubectl -n "$TRAEFIK_NS" patch appdeployment traefik --type json \
  -p '[{"op":"remove","path":"/spec/configOverrides"}]'

# delete the override ConfigMap
kubectl -n "$TRAEFIK_NS" delete configmap traefik-oidc-overrides --ignore-not-found

# Traefik rolls back (plugin unloaded)
kubectl -n "$TRAEFIK_NS" rollout status deploy/traefik --timeout=180s
```

## Keep the plugin, drop the app?
That's fine — leaving `experimental.plugins` in place is harmless (Traefik just has the
plugin loaded). Only revert it if another workload shouldn't rely on it.

## Okta side (optional)
Delete the Okta app (`traefik-oidc-lab`) so no redirect URIs stay registered.

## ✅ Done
- [ ] route, middleware, app, secret deleted
- [ ] (if reverting) `configOverrides` removed and Traefik rolled out clean
