#!/usr/bin/env bash
# vault-remote-auth.sh — OPTIONAL shortcut for step 02: teach the management Vault to trust
# ServiceAccount tokens minted by the WORKLOAD cluster, by adding a dedicated kubernetes auth mount.
#
#   workload : SA eso-vault, reviewer SA vault-auth (+ system:auth-delegator), long-lived token Secret
#   vault    : auth enable -path=<VAULT_AUTH_MOUNT>, config (remote host + reviewer token + CA),
#              policy <VAULT_POLICY>, role <VAULT_ROLE>
#
# Usage:
#   ./11-vault-eso/scripts/vault-remote-auth.sh           # dry-run (prints the steps)
#   ./11-vault-eso/scripts/vault-remote-auth.sh --apply
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/scripts/render.sh" ] && [ "$ROOT" != "/" ]; do ROOT="$(dirname "$ROOT")"; done
ENV_FILE="${ENV_FILE:-$ROOT/local.env}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; } || { echo "missing $ENV_FILE" >&2; exit 1; }
NS="${ESO_NAMESPACE:-external-secrets}"
SA="${ESO_SA:-eso-vault}"
MOUNT="${VAULT_AUTH_MOUNT:-kubernetes-ds-cluster01}"
ROLE="${VAULT_ROLE:-eso}"
# Use a DISTINCT policy name: the management cluster's own ESO role/prove uses policy `eso` — do not clobber it.
POLICY="${VAULT_POLICY:-eso-ds-cluster01}"
VAULT_NS="${VAULT_NAMESPACE:-vault}"
K()  { kubectl ${MGMT_KUBECONFIG:+--kubeconfig "$MGMT_KUBECONFIG"} "$@"; }
KS() { kubectl ${WORKLOAD_KUBECONFIG:+--kubeconfig "$WORKLOAD_KUBECONFIG"} "$@"; }

MODE="dry-run"
for a in "$@"; do case "$a" in --apply) MODE="apply";; --dry-run) MODE="dry-run";; -h|--help) sed -n '2,16p' "$0"; exit 0;; *) echo "unknown flag: $a" >&2; exit 2;; esac; done

if [ "$MODE" = "dry-run" ]; then
  cat <<EOF
== dry-run: step 02 would do the following ==

# on the workload (${WORKLOAD_CLUSTER:-<workload>}):
kubectl -n $NS create serviceaccount $SA
kubectl -n $NS create serviceaccount vault-auth
kubectl create clusterrolebinding vault-auth-delegator --clusterrole=system:auth-delegator \\
        --serviceaccount=$NS:vault-auth
kubectl -n $NS apply -f - <<'YAML'
apiVersion: v1
kind: Secret
metadata: {name: vault-auth-token, namespace: $NS, annotations: {kubernetes.io/service-account.name: vault-auth}}
type: kubernetes.io/service-account-token
YAML
# then read JWT + ca.crt + the API URL from that Secret / the kubeconfig

# on the management cluster (Vault, ns $VAULT_NS, exec vault-0):
vault auth enable -path=$MOUNT kubernetes
vault write auth/$MOUNT/config kubernetes_host=<API> kubernetes_ca_cert=<CA> \\
      token_reviewer_jwt=<JWT> disable_local_ca_jwt=true disable_iss_validation=true
vault policy write $POLICY -            # secret/* read+list
vault write auth/$MOUNT/role/$ROLE bound_service_account_names=$SA \\
      bound_service_account_namespaces=$NS policies=$POLICY ttl=1h

re-run with --apply to do it.
EOF
  exit 0
fi

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

: "${VAULT_AUTH_MOUNT:?set VAULT_AUTH_MOUNT in local.env}"

echo "== 1/4 workload: ServiceAccounts + reviewer RBAC + token =="
KS -n "$NS" create serviceaccount "$SA" --dry-run=client -o yaml | KS apply -f -
KS -n "$NS" create serviceaccount vault-auth --dry-run=client -o yaml | KS apply -f -
KS create clusterrolebinding vault-auth-delegator --clusterrole=system:auth-delegator \
   --serviceaccount="$NS:vault-auth" --dry-run=client -o yaml | KS apply -f -
KS -n "$NS" apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-token
  namespace: $NS
  annotations: {kubernetes.io/service-account.name: vault-auth}
type: kubernetes.io/service-account-token
YAML

echo "== 2/4 waiting for the reviewer token to be populated ... =="
for _ in $(seq 1 30); do
  JWT="$(KS -n "$NS" get secret vault-auth-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [ -n "$JWT" ] && break
  sleep 2
done
[ -n "$JWT" ] || { echo "token never populated — is the serviceaccount-token controller running?" >&2; exit 1; }
CA="$(KS -n "$NS" get secret vault-auth-token -o jsonpath='{.data.ca\.crt}' | base64 -d)"
API="$(KS config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
echo "   API=$API   (JWT + CA captured)"

echo "== 3/4 Vault: enable + configure the mount =="
T="$(K -n "$VAULT_NS" get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)"
V() { K -n "$VAULT_NS" exec -i vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 \
        VAULT_SKIP_VERIFY=true VAULT_TOKEN="$T" vault "$@"; }
V auth enable -path="$MOUNT" kubernetes || true
V write "auth/$MOUNT/config" kubernetes_host="$API" kubernetes_ca_cert="$CA" \
        token_reviewer_jwt="$JWT" disable_local_ca_jwt=true disable_iss_validation=true

echo "== 4/4 Vault: policy + role =="
V policy write "$POLICY" - <<'POL'
path "secret/*" { capabilities = ["read","list"] }
POL
V write "auth/$MOUNT/role/$ROLE" bound_service_account_names="$SA" \
        bound_service_account_namespaces="$NS" policies="$POLICY" ttl=1h

echo "== verify (login round-trip) =="
V write "auth/$MOUNT/login" role="$ROLE" jwt="$(KS -n "$NS" create token "$SA" --duration=10m)"
