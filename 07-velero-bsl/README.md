# Lab 07 — Velero: configure a Backup Storage Location (BSL)

**Learn:** where Velero stores its backups (a **Backup Storage Location**, or *BSL*) and how to
configure it **the NKP/Kommander way** — from the **UI** (via the AppDeployment overrides) *and* from
the **CLI** — plus the native Velero **CRDs** behind it.

> Validated against a live NKP deployment: Velero **v1.18.0** (chart **12.0.0**), BSLs
> `default` (Rook-Ceph RGW) + `secondary-offsite` (MinIO/S3), schedules `velero-default` &
> `velero-secondary-manifests`.

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
kubectl -n "$NS" get schedule
kubectl -n "$NS" get backup | tail
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

## 7. Schedules & where backups go

The `schedules:` block in the values creates `Schedule` CRDs (NKP names them `velero-<key>`, e.g.
`velero-default`, `velero-secondary-manifests`). Each `template.storageLocation` selects **which BSL**
that schedule writes to. `snapshotVolumes: false` = **manifests only** (no volume data).

```bash
kubectl -n "$NS" get schedule -o custom-columns='NAME:.metadata.name,CRON:.spec.schedule,BSL:.spec.template.storageLocation,PAUSED:.spec.paused'
```

## 8. Troubleshooting & security

| Symptom | Fix |
|---|---|
| BSL `Unavailable` | wrong creds / `profile` not in the `cloud` file / wrong `region` or `s3Url`; for MinIO/Objects set `s3ForcePathStyle: "true"` |
| Backup `Failed`/`ValidationFailed` | the referenced `storageLocation` name doesn't exist; check the BSL name |
| Overrides seem ignored | confirm `AppDeployment.spec.configOverrides.name` == your ConfigMap; create the CM **before** the AppDeployment |
| Hand-made CR "reverts" | NKP's BSL updater owns it — change the **values** instead (Path A/B) |

**Security:** the credentials Secret is a **long-lived S3 credential** — restrict the bucket, `chmod 600`,
never commit it; prefer short-lived/rotated keys where your S3 supports it.

## 9. Lessons from a live validation (2026-09, MinIO on an NKP cluster)

Validated end-to-end on a real cluster: added a **new MinIO BSL** through the **override ConfigMap** →
`Available` in **~20 s**, and a manifests-only `Backup` to it → **`Completed`** (0 errors).

Four things you only learn the hard way:

1. **The per-cluster override wins for *list* values.** The HelmRelease merges `valuesFrom` in order —
   `[<app>-config-defaults, <configOverrides> (workspace/UI), <app>-cluster-overrides]` — and for a
   **list** (`configuration.backupStorageLocation`) a later source **replaces** it. So if the
   **per-cluster** CM (`<app>-cluster-overrides`) also defines the BSL list, your **workspace/UI** edit is
   **shadowed** and nothing appears. → Put BSL changes in the **cluster override** (or keep both in sync).
   (We edited the workspace CM first: no effect; the BSL appeared only after editing the cluster CM.)
2. **Give every BSL its own bucket.** Velero validates the bucket **root** and rejects unexpected
   top-level directories. Reusing a bucket with a `prefix` flipped the *other* BSL to
   `Unavailable` → `Backup store contains invalid top-level directories: [...]`. One bucket per BSL.
3. **MinIO speaks SigV4** — `curl -u user:pass` returns `400`; use the AWS SDK / `mc` / `aws` (and the
   MinIO `mc` download URL has changed, `dl.min.io` no longer serves the raw binary).
4. **`kubectl get backup` is ambiguous** (see §6) — always the fully-qualified `backups.velero.io`.

## 10. Reference
- Your fuller playbook (nkp-deployer): `configure/velero/` — the automation script
  `configure-velero-secondary-bsl.sh`, `runbooks/velero-bsl.md`, `runbooks/nkp-cephfs-dr.md`.
- Velero docs: <https://velero.io/docs/> (BSL: *Locations → Backup Storage Location*).
