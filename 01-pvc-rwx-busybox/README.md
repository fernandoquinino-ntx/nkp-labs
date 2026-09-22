# Lab 01 — a ReadWriteMany volume shared by two pods

**Learn:** a `PersistentVolumeClaim` with `accessModes: [ReadWriteMany]` can be mounted by **many pods**
at once (possibly on **different nodes**). One pod writes, another reads — they see the same files.

## What it creates
| File | Object |
|---|---|
| `pvc.yaml` | PVC `lab-rwx` — **RWX**, `${PVC_SIZE}`, storageClass `${RWX_STORAGE_CLASS}` |
| `pod-writer.yaml` | `rwx-writer` — appends a line to `/data/hello.txt` every 5 s |
| `pod-reader.yaml` | `rwx-reader` — `tail -f` the same file |

## Run
```bash
NS="$(grep ^NAMESPACE= local.env | cut -d= -f2)"; NS=${NS:-labs}

./scripts/apply.sh 01-pvc-rwx-busybox

kubectl -n "$NS" get pvc lab-rwx            # wait for STATUS: Bound
kubectl -n "$NS" get pods -o wide           # the two pods may be on DIFFERENT nodes
```

## Observe the sharing
```bash
kubectl -n "$NS" logs -f rwx-reader         # lines appear here (written by the writer)
kubectl -n "$NS" exec rwx-writer -- cat /data/hello.txt
```
Both pods see the **same** file → the volume is shared, not a copy.

## Why RWX (vs RWO)
A `ReadWriteOnce` volume is attachable to **one node** at a time, so two pods scheduled on different
nodes could not both mount it. RWX storage (NFS, CephFS, Nutanix **NUS Files** …) allows it.

## Understanding the objects
```bash
kubectl -n "$NS" get pvc lab-rwx -o yaml | grep -A3 accessModes
kubectl -n "$NS" describe pvc lab-rwx        # Events: provisioning / bound
```

## Cleanup
```bash
./scripts/cleanup.sh 01-pvc-rwx-busybox
# = kubectl -n "$NS" delete pod rwx-writer rwx-reader pvc lab-rwx
```
> On most storage classes the PV reclaim policy is `Delete`, so deleting the PVC **deletes the data**.
