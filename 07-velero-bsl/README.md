# Lab 07 — Velero: configure a Backup Storage Location (BSL)

**Learn:** where Velero stores backups (a **Backup Storage Location**, or *BSL*), how to configure it
**the NKP/Kommander way** — from the **UI** (via the AppDeployment overrides) *and* the **CLI** — how to
write **backup policies** (`Schedule`s), and how to back up a **persistent app** (volume data). Plus the
native Velero **CRDs** behind all of it.

> Reference environment (NKP): Velero **v1.18.0** (chart **12.0.0**), BSLs `default` (object store) +
> `secondary-offsite` (MinIO/S3), schedules `velero-default` & `velero-secondary-manifests`.

| File | What |
|---|---|
| [`credentials-secret.example.yaml`](credentials-secret.example.yaml) | S3 credentials Secret (`cloud` INI) |
| [`velero-overrides.example.yaml`](velero-overrides.example.yaml) | the override ConfigMap (BSLs + schedules) the UI edits |
| [`velero-appdeployment.example.yaml`](velero-appdeployment.example.yaml) | the `AppDeployment` wiring the override |
| [`bsl-cr.example.yaml`](bsl-cr.example.yaml) / [`schedule-cr.example.yaml`](schedule-cr.example.yaml) | raw `BackupStorageLocation` / `Schedule` CRs |
| [`persistent-app.yaml`](persistent-app.yaml) | a small **stateful** app (Postgres + PVC) to back up |
| [`backup-policy.example.yaml`](backup-policy.example.yaml) | a **backup policy** (`Schedule`): when/what/where/retention/volumes |
| [`restore.example.yaml`](restore.example.yaml) | a **`Restore`** (with volume data) |
| [`verify.sh`](verify.sh) | inspect BSLs/schedules/backups + a smoke test |

---

## 1. Concepts (30 seconds)

- **Velero** backs up & restores **cluster resources** and (optionally) **volumes**. On NKP it is a
  platform **ClusterApp** deployed **per cluster** by an **`AppDeployment`**.
- A **BSL** (`BackupStorageLocation`, `velero.io`) is **where backups live**: an **S3-compatible
  bucket** — AWS S3, MinIO, Nutanix Objects, Ceph RGW, … It has a **bucket**, **region**,
  **endpoint** (`s3Url`, for non-AWS), **path-style** toggle and **credentials**.
- **Credentials** are an AWS-style INI file (`aws_access_key_id` / `aws_secret_access_key`) stored in a
  Kubernetes **Secret** (key `cloud`). A BSL's `profile` selects the `[profile]` inside that file.
- **`Schedule`** = periodic backups; **`Backup`**/**`Restore`** = a single run; **`PodVolumeBackup`** =
  file-level volume backup (Restic/Kopia).

## 2. The NKP / Kommander CRDs involved

| CRD | Group / version | What it is |
|---|---|---|
| **`AppDeployment`** | `apps.kommander.d2iq.io/v1alpha3` | Kommander CRD that **deploys Velero**. `spec.configOverrides.name` = the ConfigMap the **UI reads & writes**. |
| **`App` / `ClusterApp`** | `apps.kommander.d2iq.io/v1alpha3` | the app being deployed (`velero-12.0.0`). |
| **`BackupStorageLocation`** | `velero.io/v1` | a **BSL** (bucket + endpoint + creds). |
| **`Schedule`** | `velero.io/v1` | periodic backups. |
| **`Backup`** / **`Restore`** | `velero.io/v1` | a backup / restore run. |
| **`PodVolumeBackup`** / **`PodVolumeRestore`** | `velero.io/v1` | file-level volume backup/restore. |
| **`VolumeSnapshotLocation`** | `velero.io/v1` | CSI/cloud volume snapshots (optional). |

> On NKP the **Helm values (via the AppDeployment override) are the source of truth** — a
> `velero-backup-storage-location-updater` controller keeps the `BackupStorageLocation` CRDs in sync,
> so editing the values (UI/CLI) is the reliable path; a hand-made CR can be overwritten.

Inspect the live state:
```bash
NS=<velero-ns>                                  # NKP: `kommander` (mgmt) or the workspace ns
kubectl -n "$NS" get appdeployment velero -o yaml | head -30
kubectl -n "$NS" get backupstoragelocation
kubectl -n "$NS" get schedules.velero.io
kubectl -n "$NS" get backups.velero.io | tail
```

---

## 3. Path A — configure from the **UI** (recommended, no YAML-by-hand)

The Kommander UI edits the AppDeployment's **`configOverrides` ConfigMap** — so your change is
declarative **and** visible/editable in the UI.

1. **Create the credentials Secret first** (the UI manages *values*, not secret contents):
   ```bash
   cp credentials-secret.example.yaml velero-offsite-credentials.yaml   # fill the keys
   kubectl -n <ns> apply -f velero-offsite-credentials.yaml
   ```
2. Open the **Kommander UI** → your **workspace** → **Applications** → **velero** → **⋯  → Edit**
   (a.k.a. *Configuration*). This edits ConfigMap **`velero-overrides`** (`data.values.yaml`).
3. Paste/extend the `values.yaml` with a `configuration.backupStorageLocation` entry and a
   `schedules` block — see [`velero-overrides.example.yaml`](velero-overrides.example.yaml).
4. **Save.** The AppDeployment updates → the HelmRelease reconciles → the new
   **`BackupStorageLocation`** appears. Confirm with §6.

> Tip: keep the **built-in `default`** BSL and **add** a `secondary-offsite` one (dual-BSL) so you keep
> local backups *and* get offsite copies.

## 4. Path B — configure from the **CLI**

```bash
NS=<velero-ns>; WS=<workspace>                       # e.g. kommander / kommander-workspace
# 1) credentials Secret
kubectl -n "$NS" apply -f velero-offsite-credentials.yaml
# 2) the override ConfigMap (the same object the UI edits)
kubectl -n "$NS" apply -f velero-overrides.yaml       # from velero-overrides.example.yaml
# 3) point the AppDeployment at it
nkp create appdeployment velero --app velero-12.0.0 \
    --workspace "$WS" -c velero-overrides --kubeconfig <kubeconfig>
#   …or apply the ready YAML and let the controller reconcile:
kubectl -n "$NS" apply --server-side -f velero-appdeployment.yaml
```
Find the live app version/name first:
```bash
kubectl -n "$NS" get appdeployment velero -o jsonpath='{.spec.appRef.name}{"\n"}'
```

## 5. Path C — a raw **BackupStorageLocation** / **Schedule** CR

For understanding, or a Velero you manage yourself (on NKP this may be overwritten — see §2):
```bash
kubectl -n <ns> apply -f bsl-cr.example.yaml
kubectl -n <ns> apply -f schedule-cr.example.yaml
```

---

## 6. Verify (and a smoke test)

```bash
./07-velero-bsl/verify.sh            # inspects BSLs + schedules and runs a tiny test Backup
# manual (⚠ use the FULLY-QUALIFIED resource names — see the gotcha below):
kubectl -n "$NS" get backupstoragelocations.velero.io   # PHASE must be `Available`
kubectl -n "$NS" get schedules.velero.io                # STATUS `Enabled`
kubectl -n "$NS" get backups.velero.io                  # your test backup -> `Completed`
```
> ⚠️ **`kubectl get backup` is ambiguous** on clusters that also run **CloudNativePG** — there are **two**
> CRDs: `backups.velero.io` **and** `backups.postgresql.cnpg.io`, and the short name can bind to the wrong
> one (you'll see an empty list and think backups vanished). Always use the **fully-qualified**
> `backups.velero.io` (same for `backupstoragelocations.velero.io`, `schedules.velero.io`). The `velero`
> CLI inside the pod works too: `kubectl -n "$NS" exec deploy/velero -c velero -- /velero backup get`.
A BSL stuck **`Unavailable`** almost always means **credentials** (wrong keys / missing profile) or the
**bucket/endpoint** is unreachable — check the `velero` pod logs:
```bash
kubectl -n "$NS" logs deploy/velero --tail=50 | grep -iE "error|bucket|credential"
```

## 7. Backup policies (`Schedule`s) & backing up **persistent apps**

A **backup policy** is a Velero **`Schedule`** CR — *when* it runs, *what* it captures, *where* it goes and
*how long* it's kept. With the AppDeployment override, the `schedules:` block in the values creates them
(NKP names them `velero-<key>`, e.g. `velero-default`); you can also apply a `Schedule` directly — see
[`backup-policy.example.yaml`](backup-policy.example.yaml).

### 7.1 The policy fields (a `Schedule.template` is exactly a `Backup` spec)

| Field | Meaning |
|---|---|
| `schedule` | **when** — cron (UTC): `"0 3 * * *"`, `"*/30 * * * *"`, `@every 6h` |
| `paused` | suspend the policy without deleting it |
| `includedNamespaces` / `excludedNamespaces` | **what** (namespaces; `["*"]` = all) |
| `includedResources` / `excludedResources` | **what** (resource types: `deployments,secrets,persistentvolumeclaims,…`) |
| `labelSelector` / `orLabelSelectors` | **what** (only objects carrying these labels) |
| `includeClusterResources` | also capture cluster-scoped objects (CRDs, ClusterRoles, …) |
| `snapshotVolumes` | include **volumes** in the backup |
| `defaultVolumesToFsBackup` | back volumes up with the **file-system** uploader (**Kopia**/Restic) |
| `storageLocation` | **where** (which **BSL**; omit = the default BSL) |
| `ttl` | **retention** — delete the backup after this (`720h` = 30 days) |
| `hooks` | run commands around the backup (quiesce a DB → *application-consistent*) |

A one-off **`Backup`** uses the same fields (it's what a `Schedule` runs on a cron) — handy to test.

### 7.2 Backing up a **persistent** app (volume data)

The manifests-only schedules in §4 do **not** copy data (`snapshotVolumes: false`). Two ways to capture volumes:

| | **File-system backup** (Kopia/Restic) | **CSI snapshot** |
|---|---|---|
| What | Velero reads the **files** and uploads them to the **BSL** | the storage's **CSI** takes a point-in-time copy |
| Enable | `snapshotVolumes: true` + `defaultVolumesToFsBackup: true` | `snapshotVolumes: true` + CSI snapshot support |
| Needs | the Velero **node-agent** DaemonSet on every node | Velero `--features=EnableCSI` + a CSI driver + a **`VolumeSnapshotClass`** |
| Data lives | **in the BSL** → portable / restores anywhere | in the storage backend (needs a compatible class) |
| Good for | most workloads, cross-cluster restores | large volumes, storage-native snapshots |

**Check the prerequisites:**
```bash
NS=<velero-ns>
kubectl -n "$NS" get ds velero-node-agent      # FS backup needs one node-agent pod per node
kubectl get volumesnapshotclass                # CSI snapshot needs a VolumeSnapshotClass
kubectl get crd | grep -E 'volumesnapshots.*snapshot\.storage'   # CSI snapshot CRDs
```
No node-agent? enable it via the Velero values (`deployNodeAgent: true` / `nodeAgent.enabled: true`,
per chart) through the AppDeployment override — then it reconciles like any other value.

### 7.3 Try it: back up **and restore** a stateful app

```bash
NS=<velero-ns>; APP=<app-namespace>
# 1) deploy a small stateful app (Postgres + PVC) and seed data
kubectl apply -f persistent-app.yaml                 # rendered with your ${NAMESPACE}
kubectl -n "$APP" exec deploy/postgres -- psql -U postgres -c \
  "create table t(i int); insert into t values (1),(2),(3);"

# 2) a POLICY that captures the data (edit <BSL>) — apply it in the VELERO namespace
kubectl -n "$NS" apply -f backup-policy.yaml

# 3) trigger one run now (identical fields to the policy) and watch it
kubectl -n "$NS" apply -f - <<YAML
apiVersion: velero.io/v1
kind: Backup
metadata: { name: pg-once, namespace: $NS }
spec:
  includedNamespaces: ["$APP"]
  snapshotVolumes: true
  defaultVolumesToFsBackup: true
  ttl: 720h
  storageLocation: <BSL>
YAML
kubectl -n "$NS" get backups.velero.io pg-once -w

# 4) prove the VOLUME was captured (file-system backup -> PodVolumeBackup objects)
kubectl -n "$NS" get podvolumebackups.velero.io

# 5) restore into a NEW namespace to prove the data comes back
#    edit restore.example.yaml (backupName + namespaceMapping) then:
kubectl -n "$NS" apply -f restore.yaml
kubectl -n "$NS" get restores.velero.io -w
kubectl -n "$APP-restore" exec deploy/postgres -- psql -U postgres -c "select * from t;"
```

> **Consistency matters.** A file-system backup copies files *while the app runs*; for a database add a
> Velero **hook** (`pre`/`post` `exec`) to quiesce it, or use a **CSI snapshot**. The Postgres here is a
> lab toy — not a production backup strategy.

### 7.4 Where a policy writes
Each `template.storageLocation` selects **which BSL** that policy writes to:
```bash
kubectl -n "$NS" get schedules.velero.io -o custom-columns='NAME:.metadata.name,CRON:.spec.schedule,BSL:.spec.template.storageLocation,FS:.spec.template.defaultVolumesToFsBackup,PAUSED:.spec.paused'
```

## 8. Troubleshooting & security

| Symptom | Fix |
|---|---|
| BSL `Unavailable` | wrong creds / `profile` not in the `cloud` file / wrong `region` or `s3Url`; for MinIO/Objects set `s3ForcePathStyle: "true"` |
| Backup `Failed`/`ValidationFailed` | the referenced `storageLocation` name doesn't exist; check the BSL name |
| Overrides seem ignored | confirm `AppDeployment.spec.configOverrides.name` == your ConfigMap; create the CM **before** the AppDeployment |
| Hand-made CR "reverts" | NKP's BSL updater owns it — change the **values** instead (Path A/B) |
| Backup `Completed` but `get podvolumebackups.velero.io` is empty | volumes weren't captured — set `snapshotVolumes: true` **and** `defaultVolumesToFsBackup: true` (FS), and make sure the **node-agent** DaemonSet is running |
| Restore brought objects back but the volume is empty | `Restore.spec.restorePVs` is `false` by default → set it **`true`**, and back up with volumes enabled |
| CSI snapshot fails (`VolumeSnapshotClass` not found / `EnableCSI`) | enable the CSI feature + provide a `VolumeSnapshotClass`, or fall back to the file-system backup |
| Restored DB inconsistent | the app wasn't quiesced — add a `pre`/`post` Velero **hook**, or use CSI snapshots |

**Security:** the credentials Secret is a **long-lived S3 credential** — restrict the bucket, `chmod 600`,
never commit it; prefer short-lived/rotated keys where your S3 supports it.

## 9. Knowledge base — how BSL configuration behaves on NKP

### Override precedence for *list* values
The HelmRelease merges `valuesFrom` in order:

```
[ <app>-config-defaults ,  <configOverrides> (the workspace/UI field) ,  <app>-cluster-overrides ]
```

For a **list** — e.g. `configuration.backupStorageLocation` — a later source **replaces** the earlier one
(it does not merge element-by-element). **Consequence:** if the per-cluster ConfigMap
(`<app>-cluster-overrides`) also defines the BSL list, the **workspace/UI override is shadowed** and an
edit there appears to do nothing.
→ Put BSL-list changes in the **cluster override**, or keep both ConfigMaps in sync.

### One bucket per BSL
Velero validates the bucket **root** and rejects unexpected top-level directories. Pointing a second BSL at
an existing bucket with a `prefix` makes the *other* BSL go `Unavailable`
(`Backup store contains invalid top-level directories: [...]`).
→ give each BSL its **own bucket**.

### What a healthy BSL looks like
A correctly configured BSL reaches `Available` within seconds, and a manifests-only `Backup` to it
completes with `0` errors and shows up under `kubectl get backups.velero.io`.

### MinIO / S3-compatible endpoints
MinIO speaks **SigV4** — `curl -u user:pass` returns `400`; use the AWS SDK / `mc` / `aws`. (The `mc`
download URL from `dl.min.io` no longer serves the raw binary.)

### Resource names
`kubectl get backup` is **ambiguous** when both `backups.velero.io` and `backups.postgresql.cnpg.io`
exist — always use fully-qualified names (`backups.velero.io`, `backupstoragelocations.velero.io`,
`schedules.velero.io`), or the `velero` CLI inside the pod (`… exec deploy/velero -c velero -- /velero backup get`).

## 10. Reference
- Your fuller playbook (nkp-deployer): `configure/velero/` — the automation script
  `configure-velero-secondary-bsl.sh`, `runbooks/velero-bsl.md`, `runbooks/nkp-cephfs-dr.md`.
- Velero docs: <https://velero.io/docs/> (BSL: *Locations → Backup Storage Location*).
