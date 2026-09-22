# Lab 05 — deploy an application the NKP way (AppDeployment + overrides)

**Learn:** how NKP (Kommander) deploys applications **declaratively** with an `AppDeployment`, and how to
customise them with a **config override** ConfigMap that also shows up in the UI.

> This lab is **NKP-specific** (the `apps.kommander.d2iq.io` CRDs). The other labs are plain Kubernetes.

## The model
```
AppDeployment ──spec.appRef──►  App            (an app from a catalog collection)
                            └►  ClusterApp      (a platform/built-in app)
        │
        └─spec.clusterSelector: which cluster(s) it lands on
        └─spec.configOverrides.name:  a ConfigMap of Helm values  ← the field the UI reads/writes
        └─spec.clusterConfigOverrides[]: per-cluster overrides
```
The controller merges the override CM into the target `HelmRelease`:

```
HelmRelease.spec.valuesFrom = [ <app>-config-defaults,  ← the app's own defaults
                                <configOverrides.name>,  ← your workspace override (UI-visible)
                                <app>-cluster-overrides ] ← per-cluster
```
(later wins).

## Files
| File | What |
|---|---|
| `appdeployment.example.yaml` | the `AppDeployment` (appRef + clusterSelector + overrides) |
| `overrides.example.yaml` | the override `ConfigMap` (`values.yaml`) |

## Run it (fill the EDIT-ME placeholders first)
```bash
NS=<workspace-namespace>                 # e.g. kommander (kommander-workspace) or a project ns
# 1) find an app id + version
kubectl -n "$NS" get apps | grep <name>

# 2) create the override CM FIRST (the AppDeployment waits for it)
kubectl -n "$NS" apply -f overrides.yaml

# 3) create the AppDeployment
kubectl -n "$NS" apply --server-side -f appdeployment.yaml
```

### CLI equivalent
```bash
# list catalog apps:  nkp create appdeployment --help
nkp create appdeployment <deployment-name> --app <app-id>-<version> \
    --workspace <workspace> [--project <project>] [--clusters <cluster>] \
    --config-overrides <deployment-name>-overrides \
    --kubeconfig <kubeconfig>
# preview:
nkp create appdeployment <name> --app <app-id>-<version> --workspace <workspace> --dry-run -o yaml
```

## Verify
```bash
kubectl -n "$NS" get appdeployment <deployment-name> -o yaml | sed -n '/status:/,$p'
kubectl -n <app-namespace> get helmrelease,pods        # the app actually running
# the app (and its configuration) appears in the Kommander UI under the workspace/Applications
```

## Notes / gotchas
- `configOverrides.name` is the **UI-visible** field — this is how you customise an app *and* keep the
  config visible/editable in the UI (vs a one-off `kubectl edit`).
- Create the override **ConfigMap before** the `AppDeployment` (Kommander waits for the referent).
- `kind: App` (catalog) apps are **namespace-scoped** (deployable only in their workspace/project);
  `kind: ClusterApp` platform apps are cluster-scoped.
- Installing an app that targets a namespace already used by another release collides — pick another
  cluster/namespace or change the app's target namespace.

## Reference (this repo's sibling project)
- Catalog repo & onboarding: `github.com/fernandoquinino-ntx/nkp-app-catalog`
- Full write-ups (nkp-deployer): `docs/configure/10-nkp-custom-catalog.md`,
  `configure/vault/catalog/runbooks/{10,11,12}-*.md`
