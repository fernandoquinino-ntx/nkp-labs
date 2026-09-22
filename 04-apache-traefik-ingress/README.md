# Lab 04 — route a hostname to Apache (Ingress **or** Traefik IngressRoute)

**Learn:** expose Apache on a **hostname** through the cluster's ingress controller. Two flavours:
- **A) the standard Kubernetes `Ingress`** (portable — works with any controller), and
- **B) a Traefik `IngressRoute`** (Traefik-native CRD — richer Traefik features, no ingress class).

## What it creates
| File | Object |
|---|---|
| `deployment.yaml` | ConfigMap `apache-html` + Deployment `apache` (2 × `httpd:2.4`) |
| `service.yaml` | Service `apache` (ClusterIP:80) |
| `ingress.yaml` | **Ingress** `apache` — host `${APP_HOST}.${DOMAIN}` (option A, applied by `apply.sh`) |
| `ingressroute/ingressroute.yaml` | **Traefik `IngressRoute`** (option B — apply it **instead of** `ingress.yaml`) |

> Creating **both** would make two routers for the same host — pick one.

## The default ingress class
```bash
kubectl get ingressclass
# NAME                CONTROLLER                      AGE
# kommander-traefik   traefik.io/ingress-controller   10d
kubectl get ingressclass -o jsonpath='{range .items[?(@.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}'
# kommander-traefik
```
When a class is **default**, an `Ingress` may **omit** `ingressClassName` — the default controller
picks it up. (This lab sets it explicitly via `${INGRESS_CLASS}` so it's obvious.)

## Prereq: DNS + a cert
1. **DNS** — `${APP_HOST}.${DOMAIN}` must resolve to the **ingress controller's** external IP.
   - If you have a **wildcard** (e.g. `*.apps.<cluster>.<domain>`), nothing to do — just pick `APP_HOST`.
   - Otherwise add one record (`scripts/dns-add.sh`, `nsupdate` on a dynamic BIND zone):
     ```bash
     NAME=apache.apps.example.com IP=<ingress-LB-IP> RSH=you@<dns-server> ./scripts/dns-add.sh
     ```
   - Ingress LB IP: `kubectl get svc -A | grep -E 'traefik|ingress'` (NKP: `kommander-traefik`).
2. **Cert** — omit `tls:` to use the controller's **default certificate**, or set `tls.secretName` to your
   own `kubernetes.io/tls` Secret in the same namespace.

## A) Standard Ingress (portable)
```bash
NS="$(grep ^NAMESPACE= local.env | cut -d= -f2)"; NS=${NS:-labs}
./scripts/apply.sh 04-apache-traefik-ingress
kubectl -n "$NS" get ingress apache                # ADDRESS = the ingress LB IP
curl "http://$APP_HOST.$DOMAIN/"                   # or via the LB with a Host header:
curl -H "Host: $APP_HOST.$DOMAIN" "http://<ingress-LB-IP>/"
```

## B) Traefik `IngressRoute` (Traefik-native)
Apply it **instead of** the Ingress (delete the Ingress first if you already applied it):
```bash
kubectl -n "$NS" delete ingress apache --ignore-not-found
./scripts/render.sh 04-apache-traefik-ingress
kubectl -n "$NS" apply -f rendered/04-apache-traefik-ingress/ingressroute/ingressroute.yaml
kubectl -n "$NS" get ingressroute apache
curl -sk "https://$APP_HOST.$DOMAIN/"           # HTTPS (uses the default cert)
```
- **entryPoints**: this cluster's Traefik `web` (:8000) **redirects to https**, and `websecure` (:8443)
  is the TLS entrypoint — so the example uses **`websecure` + `tls: {}`**. (A plain `web`-only route
  would just redirect and then 404 on https.)
- Traefik CRDs carry **no `ingressClassName`** — Traefik always handles them, which is why they're handy
  for Traefik-only features (middlewares, weighted services, TCP/UDP, redirect-to-https). Docs:
  <https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/>.

## Troubleshooting
- `404` / default backend → the `Host` header doesn't match, or the wrong class/controller.
- Cert warning → using the default cert but the host isn't in its SANs (issue a cert for the host or a
  wildcard). **NKP/Traefik:** a wildcard secret (e.g. `apps-default-tls`) only helps if it's the
  **default** — point `TLSStore/default` at it, or reference it via `tls.secretName` in the same namespace.
- HTTP `301` → the controller redirects http→https; use `https://` (or the `-k` flag for a self-signed/default cert).

## Cleanup
```bash
./scripts/cleanup.sh 04-apache-traefik-ingress
kubectl -n "$NS" delete ingressroute apache --ignore-not-found   # if you used option B
```
