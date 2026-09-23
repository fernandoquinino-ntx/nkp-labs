# Step 01 — Prerequisites

`[◀ README](../README.md)` · `[Step 02 ▶](02-okta-setup.md)`

## Goal
Confirm the cluster, the ingress controller and DNS/TLS, and fill in `local.env`.

## Why it matters
Almost every failure in this lab is actually an *environment* problem: the host doesn't
resolve, the cert doesn't cover the host, or the ingress class isn't Traefik. Check these
first so step 09 stays short.

## 1) Cluster + ingress class
```bash
kubectl config current-context
kubectl get nodes
kubectl get ingressclass
# NAME                CONTROLLER                      AGE
# kommander-traefik   traefik.io/ingress-controller   ...
```
The lab uses **Traefik CRDs** (`traefik.io/v1alpha1`). Any Traefik works; on NKP it is
`kommander-traefik` and runs in the `kommander` namespace.

```bash
kubectl get svc -A | grep -i traefik       # find the Traefik LoadBalancer + its namespace
```

## 2) DNS + TLS for the app host
The app will be served at **`${OIDC_HOST}.${DOMAIN}`** (e.g. `whoami.apps.<cluster>.<domain>`).
```bash
getent hosts "${OIDC_HOST:-whoami}.${DOMAIN:-example.com}"   # must resolve to the ingress LB
```
- **Wildcard DNS** (`*.apps.<cluster>.<domain>` → ingress LB) → just pick `OIDC_HOST`.
- Otherwise add an A record (`scripts/dns-add.sh`, `nsupdate` on a dynamic BIND zone):
  ```bash
  NAME=whoami.apps.example.com IP=<ingress-LB-IP> RSH=you@<dns-server> ./scripts/dns-add.sh
  ```
- **TLS**: an `IngressRoute` with `tls: {}` uses Traefik's **default certificate**. If that
  cert doesn't include your host, either point `TLSStore/default` at a wildcard Secret or
  set `tls.secretName`. (NKP often has a wildcard `apps-default-tls`.)

## 3) Fill in `local.env`
```bash
cp local.env.example local.env      # gitignored
```
Set at least:
```ini
OIDC_HOST=whoami
DOMAIN=apps.<cluster>.<domain>
TRAEFIK_NS=kommander
OIDC_PLUGIN_VERSION=v1.0.36
OKTA_ISSUER=https://<org>.okta.com
OKTA_CLIENT_ID=<from step 02>
OKTA_CLIENT_SECRET=<from step 02>
OIDC_SESSION_KEY=<openssl rand -base64 32>
OIDC_ALLOWED_DOMAINS=example.com
```

## 4) (Re)check the namespace
```bash
NS="$(grep ^NAMESPACE= local.env | cut -d= -f2)"; NS=${NS:-labs}
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
# or: ./scripts/apply.sh 00-prereqs
```

## Expected output
`kubectl get ingressclass` lists a Traefik class, and `getent hosts` returns the ingress
LoadBalancer IP.

## ✅ Checkpoint
- [ ] Traefik is the ingress and its namespace is known (`TRAEFIK_NS`).
- [ ] `${OIDC_HOST}.${DOMAIN}` resolves to the ingress LB.
- [ ] `local.env` exists with a real `DOMAIN` and a 32-byte `OIDC_SESSION_KEY`.

Next: **[Step 02 — Create the Okta OIDC app ▶](02-okta-setup.md)**
