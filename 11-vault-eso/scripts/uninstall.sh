#!/usr/bin/env bash
# uninstall.sh — OPTIONAL shortcut for step 10: remove what the lab created.
#
# Usage:
#   ./11-vault-eso/scripts/uninstall.sh              # raw objects + the Vault glue on the workload
#   ./11-vault-eso/scripts/uninstall.sh --app        # ALSO delete the ESO AppDeployment (uninstalls ESO)
#   ./11-vault-eso/scripts/uninstall.sh --vault-mount # ALSO disable the ds-cluster01 auth mount on Vault
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/scripts/render.sh" ] && [ "$ROOT" != "/" ]; do ROOT="$(dirname "$ROOT")"; done
ENV_FILE="${ENV_FILE:-$ROOT/local.env}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; } || true
NS="${NS:-${NAMESPACE:-labs}}"
WS="${WORKSPACE_NS:-datascience-xmfnz}"
SS="${SECRETSTORE_NAME:-vault-backend}"
ES="${EXTERNAL_SECRET_NAME:-lab-app-credentials}"
MG="${MGMT_KUBECONFIG:-}"; DS="${WORKLOAD_KUBECONFIG:-}"
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
K()  { kubectl ${MG:+--kubeconfig "$MG"} "$@"; }
KS() { kubectl ${DS:+--kubeconfig "$DS"} "$@"; }

APP=0; VM=0
for a in "$@"; do case "$a" in --app) APP=1;; --vault-mount) VM=1;; esac; done

echo "== raw objects on the workload =="
KS -n "$NS" delete deploy lab-eso-demo --ignore-not-found
KS -n "$NS" delete externalsecret "$ES" --ignore-not-found
KS delete clustersecretstore "$SS" --ignore-not-found
KS -n "$NS" delete secret "$ES" --ignore-not-found

echo "== the Vault glue on the workload =="
KS delete clusterrolebinding vault-auth-delegator --ignore-not-found
KS -n external-secrets delete secret vault-auth-token --ignore-not-found
KS -n external-secrets delete serviceaccount vault-auth --ignore-not-found
KS -n external-secrets delete serviceaccount eso-vault --ignore-not-found

if [ "$APP" = 1 ]; then
  echo "== ESO AppDeployment (uninstalls ESO from the workload) =="
  K -n "$WS" delete appdeployment "${ESO_APP_ID:-external-secrets}" --ignore-not-found
  echo "== override ConfigMap =="
  K -n "$WS" delete configmap "${ESO_OVERRIDES_CM:-external-secrets-overrides}" --ignore-not-found
fi

if [ "$VM" = 1 ]; then
  echo "== management-side auth mount =="
  T=$(K -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d)
  K -n vault exec -i vault-0 -- env VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
    VAULT_TOKEN="$T" vault auth disable "${VAULT_AUTH_MOUNT:-kubernetes-ds-cluster01}"
fi

echo; echo "done.  (the management cluster's own 'kubernetes' mount was left untouched)"
