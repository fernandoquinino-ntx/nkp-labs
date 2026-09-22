# Procedure — a long-lived ServiceAccount token + kubeconfig

Give an external app / CI job a **kubeconfig** of its own, backed by a **ServiceAccount** with
**least-privilege** RBAC. Copy-paste procedure (no scripts required); the hands-on version is
[lab 06](../06-long-lived-token-kubeconfig/).

> Validated on Kubernetes **1.35** (Nutanix NKP), 2026-09-22.

## The three ways to authenticate an app

| Option | Expires? | How |
|---|---|---|
| **A. Long-lived token Secret** | **No** (`exp` absent) | `Secret type: kubernetes.io/service-account-token` + annotation `kubernetes.io/service-account.name` → the token controller fills `.data.token`. **Still works on 1.35.** |
| **B. Bound token** | **Yes** (server-capped) | `kubectl -n NS create token <sa> --duration 24h` |
| **C. Client certificate** | cert lifetime (~1y+) | issue an x509 client cert + RBAC |

> Since Kubernetes **1.24** a ServiceAccount no longer auto-creates a token Secret — create the
> `kubernetes.io/service-account-token` Secret **explicitly** for option A.

---

## 1. ServiceAccount
```bash
NS=labs; SA=lab-app
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create serviceaccount "$SA"
```

## 2. Least-privilege RBAC (a Role, not cluster-admin)
```bash
# quick: bind the built-in `view` ClusterRole to the SA *in this namespace only*
kubectl -n "$NS" create rolebinding "$SA-view" \
  --clusterrole=view --serviceaccount="${NS}:${SA}"
```
Or a hand-written Role with exactly the verbs/resources the app needs:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: lab-app, namespace: labs }
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "configmaps", "services", "secrets", "events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch"]
```
```bash
kubectl -n "$NS" create -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: lab-app, namespace: labs }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: lab-app }
subjects: [{ kind: ServiceAccount, name: lab-app, namespace: labs }]
YAML
```

## 3. The long-lived token Secret (option A)
```bash
kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SA}-token
  namespace: ${NS}
  annotations:
    kubernetes.io/service-account.name: ${SA}
type: kubernetes.io/service-account-token
EOF
# the controller populates it within ~1s:
kubectl -n "$NS" get secret "${SA}-token" -o jsonpath='{.data.token}' | base64 -d
```
**Confirm it is non-expiring** (no `exp` claim):
```bash
kubectl -n "$NS" get secret "${SA}-token" -o jsonpath='{.data.token}' \
  | base64 -d | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
# expect:  "sub": "system:serviceaccount:<ns>:<sa>"   and NO "exp"
```

## 4. Build a self-contained kubeconfig
```bash
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
TOKEN="$(kubectl -n "$NS" get secret "${SA}-token" -o jsonpath='{.data.token}' | base64 -d)"
CAF="$(mktemp)"; printf '%s' "$CA" | base64 -d > "$CAF"
K=./app-kubeconfig
kubectl config set-cluster lab      --server="$SERVER" --certificate-authority="$CAF" --embed-certs=true --kubeconfig "$K"
kubectl config set-credentials "$SA" --token="$TOKEN"                                  --kubeconfig "$K"
kubectl config set-context "$SA@$NS" --cluster=lab --user="$SA" --namespace="$NS"      --kubeconfig "$K"
kubectl config use-context "$SA@$NS" --kubeconfig "$K"
chmod 600 "$K"; rm -f "$CAF"
echo "wrote $K"
```
(One-shot helper: [`../06-long-lived-token-kubeconfig/build-kubeconfig.sh`](../06-long-lived-token-kubeconfig/build-kubeconfig.sh).)

## 5. Validate
```bash
kubectl --kubeconfig "$K" auth whoami            # system:serviceaccount:<ns>:<sa>
kubectl --kubeconfig "$K" get pods -n "$NS"      # ALLOWED by the Role
kubectl --kubeconfig "$K" get nodes             # FORBIDDEN (least privilege — good)
```

---

## Option B — a short-lived bound token (no Secret)
```bash
kubectl -n "$NS" create token "$SA" --duration=24h
# build a kubeconfig directly from it:
kubectl config set-credentials "$SA" \
  --token="$(kubectl -n "$NS" create token "$SA" --duration=24h)" --kubeconfig "$K"
```
Bound tokens embed an **`exp`** (capped by the apiserver's `--service-account-max-token-expiration`) and
are invalidated when the SA/namespace is deleted. **Prefer this for CI** where the token can be refreshed.

## Security notes
- **Least privilege** — never bind `cluster-admin` for a generic app.
- A long-lived token is a **permanent credential** — store it in a secret manager, `chmod 600`, never
  commit it.
- **Revoke**: delete the SA/Secret (option A) or let the token expire (option B).
- Nutanix guidance: for **user** logins use the kubeconfig from the UI/REST API; use Service Accounts for
  **machine** integrations (CI), scoped narrowly.

## Cleanup
```bash
kubectl -n "$NS" delete secret "${SA}-token" rolebinding "${SA}-view" serviceaccount "$SA" --ignore-not-found
rm -f "$K"
```
