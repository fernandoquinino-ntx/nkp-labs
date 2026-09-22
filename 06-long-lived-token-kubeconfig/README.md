# Lab 06 — a long-lived ServiceAccount kubeconfig (for apps / CI)

**Learn:** give an external app (Jenkins, a script, an operator…) a **kubeconfig** of its own, backed
by a **ServiceAccount**, with **least-privilege** RBAC — using a **long-lived (non-expiring) token**.

## The three ways to authenticate an app

| Option | Expires? | How | When |
|---|---|---|---|
| **A. Long-lived token Secret** (this lab) | **No** (`exp` absent) | `Secret type: kubernetes.io/service-account-token` + the `kubernetes.io/service-account.name` annotation → the token controller fills `.data.token` | stable/trusted apps; the classic approach. **Still works on modern clusters** (validated on 1.35) |
| **B. Bound token** (`kubectl create token`) | **Yes** (server-capped) | `kubectl -n NS create token <sa> --duration 24h` | CI/short-lived jobs; **not** stored in a Secret; invalidated if the SA is deleted |
| **C. Client certificate** | Depends on the cert (often ~1y) | issue an x509 client cert for a user + RBAC | when you can't use SA tokens |

> ⚠️ Since Kubernetes 1.24 a ServiceAccount no longer gets a token Secret automatically — you create
> the `kubernetes.io/service-account-token` Secret **explicitly** (option A).

## What this lab creates
| File | Object |
|---|---|
| `sa.yaml` | **ServiceAccount** `${SA_NAME}` + a scoped **Role** + **RoleBinding** (read pods/configmaps/services/… in `${NAMESPACE}` only) |
| `token-secret.yaml` | **Secret** `${SA_NAME}-token` (the long-lived token) |
| `build-kubeconfig.sh` | builds `./lab-kubeconfig` (server + CA from your current kubeconfig + the token) |

## Run it
```bash
NS="$(grep ^NAMESPACE= local.env | cut -d= -f2)"; NS=${NS:-labs}
SA="$(grep ^SA_NAME= local.env | cut -d= -f2)"; SA=${SA:-lab-app}

./scripts/apply.sh 00-prereqs               # the namespace
./scripts/apply.sh 06-long-lived-token-kubeconfig

# build a standalone kubeconfig for the app
./scripts/render.sh 06-long-lived-token-kubeconfig
./06-long-lived-token-kubeconfig/build-kubeconfig.sh           # -> ./lab-kubeconfig (chmod 600)
```
(If you didn't render, `build-kubeconfig.sh` still reads `local.env` directly.)

## Use it
```bash
export KUBECONFIG="$PWD/lab-kubeconfig"
kubectl config current-context          # lab-app@labs
kubectl get pods -n "$NS"               # ALLOWED  (role grants pods get/list/watch)
kubectl get nodes                       # FORBIDDEN (least privilege — good!)
kubectl auth whoami                     # system:serviceaccount:labs:lab-app
```

## The short-lived alternative (option B)
No Secret needed — mint a **bound** token on demand (great for a CI pipeline step):
```bash
./06-long-lived-token-kubeconfig/build-kubeconfig.sh --duration 24h --out ./ci-kubeconfig
# or add a token to an existing kubeconfig:
kubectl -n "$NS" create token "$SA" --duration 24h
```
Bound tokens embed an **`exp`** and are invalidated when the SA (or its namespace) is deleted.

## Widening permissions (deliberately)
The lab Role is intentionally small. To widen:
- add rules to the `Role`, or
- **namespace-scoped**: `kubectl -n "$NS" create rolebinding app-view --clusterrole=view --serviceaccount="$NS:$SA"`
- **cluster-wide** (careful!): `kubectl create clusterrolebinding app-admin --clusterrole=cluster-admin --serviceaccount="$NS:$SA"`

## Security notes (important)
- **Least privilege**: bind only what the app needs; never `cluster-admin` for a generic app.
- **A long-lived token is a permanent credential** — treat it like a password: store it in a secret
  manager, `chmod 600`, never commit it. Prefer **option B** (expiring) where you can.
- **Revocation**: delete the SA/Secret (option A) or let it expire (option B).
- On **Nutanix NKP**, for *user* logins prefer the kubeconfig the UI/REST API gives you; use Service
  Accounts for **machine** integrations (CI), and scope them narrowly.

## Cleanup
```bash
./scripts/cleanup.sh 06-long-lived-token-kubeconfig
rm -f lab-kubeconfig
# = kubectl -n "$NS" delete secret "$SA-token" role "$SA" rolebinding "$SA" serviceaccount "$SA"
```
