# Step 03 — Enable the Traefik OIDC plugin (static config)

`[◀ Step 02](02-okta-setup.md)` · `[README](../README.md)` · `[Step 04 ▶](04-create-secret.md)`

## Goal
Make the **`traefikoidc`** plugin available to Traefik. Plugins are **static** configuration:
Traefik downloads and loads them **at startup**, so this is a cluster-wide change that
**restarts Traefik** (brief NKP-UI blip).

## Why it matters
A `Middleware` that references `spec.plugin.traefikoidc` only works if the plugin was
declared in Traefik's **static** config. On NKP that config is owned by the `traefik`
**AppDeployment**, so we add an override ConfigMap (see lab 05) instead of editing Helm.

---

## A) The override ConfigMap

`traefik-plugin/overrides.example.yaml` (render it with `./scripts/render.sh 09-traefik-oidc-okta`):
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: traefik-oidc-overrides
  namespace: ${TRAEFIK_NS}
data:
  values.yaml: |
    experimental:
      abortOnPluginFailure: false
      plugins:
        traefikoidc:
          moduleName: github.com/lukaszraczylo/traefikoidc
          version: ${OIDC_PLUGIN_VERSION}
```
- The key **`traefikoidc`** must equal the name used in the Middleware (`spec.plugin.traefikoidc`).
- `moduleName`/`version` identify the module Traefik fetches from `plugins.traefik.io`.
- The chart **requires both** `moduleName` and `version` (it fails the render otherwise) and
  automatically mounts a `plugins` emptyDir at `/plugins-storage` — you don't add a volume.

## B) Find the Traefik AppDeployment
```bash
kubectl get appdeployments -A | grep -i traefik
# On NKP: usually  traefik   in namespace  kommander   (the platform ClusterApp).
# (Managed clusters can carry a workspace-scoped one — pick the one for YOUR cluster.)
```
Convenience:
```bash
TRAEFIK_NS=kommander                       # set in local.env
kubectl -n "$TRAEFIK_NS" get appdeployment traefik -o yaml | sed -n '1,40p'
```

## C) Apply the override and point the AppDeployment at it
```bash
./scripts/render.sh 09-traefik-oidc-okta
kubectl -n "$TRAEFIK_NS" apply -f rendered/09-traefik-oidc-okta/traefik-plugin/overrides.example.yaml

kubectl -n "$TRAEFIK_NS" patch appdeployment traefik --type merge \
  -p '{"spec":{"configOverrides":{"name":"traefik-oidc-overrides"}}}'
```
> Kommander's git-operator merges this ConfigMap into the app's HelmRelease
> (`valuesFrom`), then rolls Traefik. Create the **ConfigMap first**, then patch.

### Manual alternative
In the Kommander UI you can edit the `traefik` AppDeployment's **Configuration** (the same
`configOverrides` field), or `kubectl -n "$TRAEFIK_NS" edit appdeployment traefik` and set
`spec.configOverrides.name: traefik-oidc-overrides`.

### Not on NKP? (plain Helm)
```bash
helm -n traefik upgrade traefik traefik/traefik --reuse-values \
  --set experimental.plugins.traefikoidc.moduleName=github.com/lukaszraczylo/traefikoidc \
  --set experimental.plugins.traefikoidc.version="${OIDC_PLUGIN_VERSION}"
```

## D) Watch it roll out + confirm the plugin loaded
```bash
kubectl -n "$TRAEFIK_NS" get pods -l app.kubernetes.io/name=traefik -w
# or:
kubectl -n "$TRAEFIK_NS" rollout status deploy/traefik
kubectl -n "$TRAEFIK_NS" logs deploy/traefik | grep -iE 'plugin|traefikoidc' | tail
```
You should see the plugin being fetched/loaded. If the pod restarts in a loop, read
[step 09](09-troubleshooting.md) (usually **no egress** or a **bad version**).

> **Takes a moment.** Patching the AppDeployment is not instant: Kommander's
> git-operator/app-management renders the new Helm values, commits them to the app git
> repo, and the target cluster's Flux pulls them before Traefik rolls. If the plugin args
> (`kubectl -n "$TRAEFIK_NS" get deploy traefik -o yaml | grep plugin`) don't appear after a
> few minutes, that pipeline may be lagging or unhealthy — check the workspace app
> Kustomization / git-operator. **Fallback:** the Traefik HelmRelease already declares an
> optional `traefik-overrides` ConfigMap in its `valuesFrom`, so you can apply the same
> values directly in the cluster's Traefik namespace and it merges immediately:
> ```bash
> # same values.yaml as above, but named traefik-overrides, in the cluster Traefik namespace:
> kubectl -n <cluster-traefik-ns> create configmap traefik-overrides \
>   --from-literal=values.yaml="$(sed -n '/values.yaml: |/,$p' rendered/09-traefik-oidc-okta/traefik-plugin/overrides.example.yaml | tail -n +2)"
> ```

## Air-gapped clusters (`localPlugins`)
No internet from the cluster? Vendor the plugin and mount it instead:
```yaml
experimental:
  localPlugins:
    traefikoidc:
      moduleName: github.com/lukaszraczylo/traefikoidc
# + a volume at /plugins-local/src/github.com/lukaszraczylo/traefikoidc holding the source
```
(`version` is ignored for local plugins.) Download the source somewhere with egress:
`git clone --depth 1 --branch ${OIDC_PLUGIN_VERSION} https://github.com/lukaszraczylo/traefikoidc`.

## ✅ Checkpoint
- [ ] `traefik-oidc-overrides` ConfigMap exists in `$TRAEFIK_NS`.
- [ ] `appdeployment/traefik` has `spec.configOverrides.name: traefik-oidc-overrides`.
- [ ] Traefik pods are `Running` and the logs mention the plugin (no crash-loop).

Next: **[Step 04 — Create the Secret ▶](04-create-secret.md)**
