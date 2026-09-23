# Step 05 — Deploy the demo application

`[◀ Step 04](04-create-secret.md)` · `[README](../README.md)` · `[Step 06 ▶](06-create-middleware.md)`

## Goal
Run a tiny app behind a `ClusterIP` Service. We use **`traefik/whoami`** because it prints
the request headers — so once auth works you can **see** `X-Forwarded-User` and friends.

## Why it matters
The app must be reachable **only** through Traefik. A `ClusterIP` Service (never
`LoadBalancer`/`NodePort`, never a plain `Ingress` on the same host) leaves no bypass.

## Manifests
`app/deployment.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector: { matchLabels: { app: whoami } }
  template:
    metadata: { labels: { app: whoami } }
    spec:
      containers:
        - name: whoami
          image: traefik/whoami:v1.12.0
          args: ["--port=80"]
          ports: [{ name: http, containerPort: 80 }]
```
`app/service.yaml`
```yaml
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  selector: { app: whoami }
  ports: [{ name: http, port: 80, targetPort: http }]
```

## Apply
```bash
./scripts/render.sh 09-traefik-oidc-okta
kubectl apply -f rendered/09-traefik-oidc-okta/namespace.yaml \
              -f rendered/09-traefik-oidc-okta/app/deployment.yaml \
              -f rendered/09-traefik-oidc-okta/app/service.yaml
kubectl -n "$NS" rollout status deploy/whoami
```

## Expected output
```bash
kubectl -n "$NS" get deploy,svc,pod -l app=whoami
# deploy/whoami   1/1   ...
# svc/whoami      ClusterIP   ...
```
Quick sanity check **from inside the cluster** (no auth involved yet):
```bash
kubectl -n "$NS" run curl --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s http://whoami/
```

## Gotchas
- Don't create an `Ingress`/`IngressRoute` for `whoami` **without** the Middleware — that
  would expose it unauthenticated (step 07).
- If the image can't be pulled, the pod stays `ImagePullBackOff` (check registry/egress).

## ✅ Checkpoint
- [ ] `deploy/whoami` is `1/1` Ready and `svc/whoami` is `ClusterIP`.

Next: **[Step 06 — Create the Middleware ▶](06-create-middleware.md)**
