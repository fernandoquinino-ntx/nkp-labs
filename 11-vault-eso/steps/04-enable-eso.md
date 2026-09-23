# Step 04 — Enable ESO on the workload cluster

On NKP the **management** cluster ships ESO pre-installed. A **workload** cluster does not — you
enable the platform app for it.

## Path A — the UI (recommended)

1. Open the Kommander UI → **Management Cluster Workspace** dashboard.
2. Left nav → **Applications**.
3. Find the **External Secrets Operator** (app id `external-secrets`) card → **Enable**.
4. Select the workload cluster **`ds-cluster01`**.
5. **Save/Enable.**

The UI creates the `AppDeployment` (in the cluster's **workspace** namespace) and, if you edit the
overrides there, the `external-secrets-overrides` ConfigMap — the same objects step 05 applies.

## Path B — the CLI / YAML

```bash
MG="kubectl --kubeconfig ~/dc1-nkp-cl01.conf"

# what version is available?
$MG get clusterapp | grep external-secrets
#   external-secrets-2.3.0   external-secrets   2.3.0   management

# create the AppDeployment (see ../overrides/appdeployment.example.yaml), in the WORKSPACE namespace:
$MG -n datascience-xmfnz apply --server-side -f appdeployment.yaml
```

> The AppDeployment is **not** created in a namespace named after the cluster — it goes in that
> cluster's **workspace** namespace (here `datascience-xmfnz`, workspace `datascience`). Manage-only
> apps (like the management ESO) sit in `kommander`.

## Verify

```bash
DS="kubectl --kubeconfig ~/ds-cluster01.conf"
$MG -n datascience-xmfnz get appdeployment external-secrets
$DS -n external-secrets get deploy,pods
#   -> external-secrets, external-secrets-cert-controller, external-secrets-webhook Running
$DS get crd | grep external-secrets.io
#   -> clustersecretstores.external-secrets.io, externalsecrets.external-secrets.io, ...
```

Do not continue until the ESO controller is `Running` on the workload cluster.

## ⚠ Observed caveat — a raw AppDeployment alone is not enough

A **raw `AppDeployment` alone did NOT deliver ESO** to `ds-cluster01` in this lab. The app reached the
management side (`AppDeploymentInstance` `GitReconciled`), but the workload never received it because
**app delivery to the workload was broken upstream**:

- the workload's `management` GitRepository was pinned to an 11-day-old revision
  (`kubectl -n kommander-flux get gitrepository management` → `main@sha1:ddf9c599…`) and a forced
  `flux reconcile source git management` did not advance it; and
- the mgmt `git-operator-controller-manager` was CrashLooping/restarting (12 restarts) with
  `GitClaimUser .../datascience-xmfnz-ds-cluster01-l12 … 401 Authorization Required`.

So before relying on this step, confirm the delivery pipeline is healthy:

```bash
# workload: the revision must ADVANCE after you enable an app
$DS -n kommander-flux get gitrepository management -o jsonpath='{.status.artifact.revision}{"\n"}'
# workload: a per-app Kustomization must appear (e.g. external-secrets / external-secrets-release)
$DS -n datascience-xmfnz get kustomization | grep -i external-secret
# mgmt: the ADI must reach KustomizationHealthy (not just GitReconciled)
$MG -n datascience-xmfnz get appdeploymentinstance -o name | grep external-secret
```

If those are stuck, fix the git-operator / workload Flux first — otherwise **every** platform app
(not just ESO) will fail to land. Enable ESO from the **workspace Applications page** (the UI adds it
to the workspace's platform-app bundle, which the doc says must be deployed per workspace).

> **Workaround while delivery is broken:** the same override mechanism works on a cluster whose app
> delivery is healthy. It was exercised on the **management** cluster (`kommander` ns +
> `external-secrets-overrides`) — see [`../vault/validate-in-vault-ui.md`](../vault/validate-in-vault-ui.md).

---

Next: [05 — set the store via the AppDeployment override](05-override-store.md)
