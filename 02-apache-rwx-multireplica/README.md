# Lab 02 — Apache on a shared RWX volume, many replicas, two containers per pod

**Learn:** multiple **replicas** of a workload can serve the **same** content when they mount a shared
**RWX** volume; and **two containers in the same pod** can read/write that same volume.

## What it creates
| File | Object |
|---|---|
| `pvc.yaml` | PVC `lab-web` — **RWX** (shared by all replicas) |
| `deployment.yaml` | Deployment `apache` — `${REPLICAS}` × `httpd:2.4` **+ a `page-writer` (busybox) sidecar** |
| `service.yaml` | Service `apache` (ClusterIP:80) |

The pod has **two containers**: `apache` serves `/usr/local/apache2/htdocs` and `page-writer` keeps
rewriting `/web/index.html` — **the same PVC**, so every replica serves the same, live page.

## Run
```bash
NS="$(grep ^NAMESPACE= local.env | cut -d= -f2)"; NS=${NS:-labs}

./scripts/apply.sh 02-apache-rwx-multireplica
kubectl -n "$NS" get pvc lab-web            # Bound
kubectl -n "$NS" rollout status deploy/apache
kubectl -n "$NS" get pods -o wide           # REPLICAS pods, each with 2/2 containers
```

## Observe "shared + multi-container"
```bash
# the page served by the Service (load-balanced over the replicas)
kubectl -n "$NS" run curl-$RANDOM --rm -it --restart=Never --image=curlimages/curl -- \
  sh -c 'curl -s http://apache/'

# show the containers of one pod (apache + page-writer)
kubectl -n "$NS" get pod -l app=apache -o jsonpath='{range .items[0].spec.containers[*]}{.name}{"\n"}{end}'

# the sidecar wrote the file into the SHARED volume:
kubectl -n "$NS" exec deploy/apache -c apache -- cat /usr/local/apache2/htdocs/index.html
kubectl -n "$NS" exec deploy/apache -c page-writer -- cat /web/index.html   # SAME file

# scale and confirm the new replica serves the same page
kubectl -n "$NS" scale deploy/apache --replicas=5
```

## Talking points
- `replicas: ${REPLICAS}` — the Service spreads requests across pods.
- Why RWX? All replicas mount the **same** PVC → the html is identical everywhere.
- **Two containers, one volume** — a classic sidecar pattern (writer here; could be a log shipper, etc.).

## Cleanup
```bash
./scripts/cleanup.sh 02-apache-rwx-multireplica
```
