# Step 05 — Set the Vault "credential store" via the AppDeployment override

This is the heart of the lab: the `ClusterSecretStore` (+ the `ExternalSecret` + the demo) are written
**as Helm values** in the ESO app's override ConfigMap, and the ESO chart renders them via
**`extraObjects`**.

> Why not a plain `ClusterSecretStore` YAML? Because an `AppDeployment` can only feed **Helm values**.
> `extraObjects` is the bridge: a list of manifests the chart renders (each through `tpl`) as part of
> the release — so the store becomes a *value you can set in the UI*.

## The override ConfigMap

Copy and fill [`../overrides/eso-overrides.example.yaml`](../overrides/eso-overrides.example.yaml)
(rendered with your `local.env` values):

```bash
./scripts/render.sh 10-vault-eso            # -> rendered/10-vault-eso/overrides/eso-overrides.example.yaml
cp rendered/10-vault-eso/overrides/eso-overrides.example.yaml eso-overrides.yaml
$EDITOR eso-overrides.yaml                  # (already substituted if local.env is set)

MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"
$MG -n "${WORKSPACE_NS:-datascience-xmfnz}" apply -f eso-overrides.yaml
```

The three `extraObjects` entries are exactly the raw manifests in `eso/` and `app/` — compare them
side by side; that is the "CR ⇄ override" contrast this lab is about:

| `extraObjects` entry | raw file |
|---|---|
| `ClusterSecretStore/vault-backend` | `eso/clustersecretstore.example.yaml` |
| `ExternalSecret/lab-app-credentials` | `eso/externalsecret.example.yaml` |
| `Deployment/lab-eso-demo` | `app/deployment.yaml` |

## Point the AppDeployment at it

If you used the UI in step 04, the AppDeployment may already name `external-secrets-overrides`. Ensure
**both** fields point at it:

```yaml
spec:
  configOverrides:            {name: external-secrets-overrides}
  clusterConfigOverrides:
    - appVersion: "2.3.0"
      clusterSelector: {matchExpressions: [{key: kommander.d2iq.io/cluster-name, operator: In, values: ["ds-cluster01"]}]}
      configMapName: external-secrets-overrides
```

```bash
$MG -n "${WORKSPACE_NS:-datascience-xmfnz}" apply --server-side -f appdeployment.yaml
```

## Watch it land

```bash
DS="kubectl --kubeconfig ~/ds-cluster01.conf"
$DS get clustersecretstore "${SECRETSTORE_NAME:-vault-backend}" -w
#   NAME            AGE   STATUS   CAPABILITIES   READY
#   vault-backend   10s   Valid    ReadWrite      True

$DS -n "${NAMESPACE:-labs}" get externalsecret -w
#   NAME                  STORE           STATUS         READY
#   lab-app-credentials   vault-backend   SecretSynced   True
```

**Verify the override really drove it** — the store/secret carry the ESO release as owner:

```bash
$DS get clustersecretstore vault-backend -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep -i helm
```

**Gotchas**

- The override ConfigMap must exist **before** (or be applied alongside) the AppDeployment.
- Edit in the **UI** afterwards and the same ConfigMap updates → the store changes. That re-sync is
  the whole point of doing it this way.

## Making the override visible **in the AppDeployment** (UI)

Two ways NKP links an override ConfigMap to an app — know which one you're looking at:

| Style | Where the link is | Shows in the AppDeployment / UI? |
|---|---|---|
| **By convention** | the app's `HelmRelease.spec.valuesFrom` hard-lists `<app>-overrides` (optional) — e.g. the **platform-managed** ESO on the mgmt cluster | **No.** `spec.configOverrides.name` is empty; the values still apply, but the AppDeployment shows no reference. |
| **Explicit** | `AppDeployment.spec.configOverrides.name` **and** `spec.clusterConfigOverrides[].configMapName` → the ADI maps the CM to `<app>-config-overrides` / `<app>-cluster-overrides` | **Yes** — the UI shows the referenced ConfigMap |

To make your override show up **in the AppDeployment** (what a UI user expects), set both fields —
which is what `overrides/appdeployment.example.yaml` already does:

```bash
$MG -n "${WORKSPACE_NS:-datascience-xmfnz}" patch appdeployment "${ESO_APP_ID:-external-secrets}" \
  --type=merge -p "{\"spec\":{\"configOverrides\":{\"name\":\"${ESO_OVERRIDES_CM:-external-secrets-overrides}\"},\"clusterConfigOverrides\":[{\"appVersion\":\"${ESO_APP_VERSION:-2.3.0}\",\"clusterSelector\":{\"matchExpressions\":[{\"key\":\"kommander.d2iq.io/cluster-name\",\"operator\":\"In\",\"values\":[\"${WORKLOAD_CLUSTER:-ds-cluster01}\"]}]},\"configMapName\":\"${ESO_OVERRIDES_CM:-external-secrets-overrides}\"}]}}"
# verify
$MG -n "${WORKSPACE_NS:-datascience-xmfnz}" get appdeployment "${ESO_APP_ID:-external-secrets}" \
  -o jsonpath='configOverrides={.spec.configOverrides}{"\n"}clusterConfigOverrides={.spec.clusterConfigOverrides[0].configMapName}{"\n"}'
# the AppDeploymentInstance then carries the mapping:
$MG -n "${WORKSPACE_NS:-datascience-xmfnz}" get appdeploymentinstance -o name | grep external-secrets | \
  xargs -I{} $MG -n "${WORKSPACE_NS:-datascience-xmfnz}" get {} -o jsonpath='{.spec.configOverrides}'; echo
```

> The values **live in the ConfigMap** either way — the AppDeployment only ever holds a *reference*.
> So "I don't see it in the AppDeployment" means the link is by-convention (or unset), **not** that
> your values are ignored. Verified live: patching both fields made the reference appear and changed
> nothing functionally (store stayed `Ready`, ExternalSecret stayed `SecretSynced`).

---

Next: [06 — inspect the objects](06-inspect.md)
