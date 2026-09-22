# Lab 04 — route a hostname to Apache with an Ingress (Traefik)

**Learn:** an **Ingress** routes an HTTP **hostname** → a `Service`, through the cluster's ingress
controller. You get a friendly URL instead of a `ClusterIP`/external IP.

## What it creates
| File | Object |
|---|---|
| `deployment.yaml` | ConfigMap `apache-html` + Deployment `apache` (2 × `httpd:2.4`) |
| `service.yaml` | Service `apache` (ClusterIP:80) |
| `ingress.yaml` | **Ingress** `apache` — host `${APP_HOST}.${DOMAIN}`, class `${INGRESS_CLASS}` |

## Prereq: DNS + a cert
1. **DNS** — `${APP_HOST}.${DOMAIN}` must resolve to the **ingress controller's** external IP.
   - Wildcard (e.g. `*.apps.<cluster>.<domain>`) → nothing to do; just choose `APP_HOST`.
   - Otherwise add one record (`scripts/dns-add.sh` uses `nsupdate` on a dynamic BIND zone):
     ```bash
     NAME=apache.apps.example.com IP=<ingress-LB-IP> RSH=you@<dns-server> ./scripts/dns-add.sh
     ```
   - Find the ingress LB IP: `kubectl -n <ingress-ns> get svc <ingress-controller> -o wide`
     (NKP: `kubectl get svc -A | grep kommander-traefik`).
2. **Cert** — omit the `tls:` block to use the ingress controller's **default certificate** (the hostname
   must fall under its SANs). Otherwise set `tls.secretName` to your own `kubernetes.io/tls` Secret **in
   the same namespace**.

## Run
```bash
NS="$(grep ^NAMESPACE= local.env | cut -d= -f2)"; NS=${NS:-labs}

./scripts/apply.sh 04-apache-traefik-ingress
kubectl -n "$NS" get ingress apache          # ADDRESS should show the ingress LB IP
```

## Use it
```bash
curl "http://apache.$DOMAIN/"                # or https://…  (cert depends on your setup)
# via the ingress LB directly with a Host header:
curl -H "Host: apache.$DOMAIN" "http://<ingress-LB-IP>/"
```

## Understanding the objects
- **Ingress vs Service**: the Service is the in-cluster target; the Ingress is the **routing rule**
  (host + path → Service) that the controller (Traefik) turns into a router.
- `ingressClassName: ${INGRESS_CLASS}` picks **which** controller handles this Ingress.
- One hostname, many apps: each app gets its own `host:` (or a different `path:`).

## Troubleshooting
- `404`/default backend → the Host header doesn't match, or the wrong ingress class.
- Cert warning in the browser → using the default cert but the hostname isn't in its SANs (issue a cert
  for the host, or add a wildcard).

## Cleanup
```bash
./scripts/cleanup.sh 04-apache-traefik-ingress
```
