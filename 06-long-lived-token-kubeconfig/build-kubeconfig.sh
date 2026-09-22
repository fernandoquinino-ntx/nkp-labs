#!/usr/bin/env bash
# build-kubeconfig.sh — build a ready-to-use kubeconfig for the lab ServiceAccount.
#
# It reads the CLUSTER server + CA from your CURRENT kubeconfig, and the SA token from the
# `kubernetes.io/service-account-token` Secret (see token-secret.yaml), then writes a self-contained
# kubeconfig (CA embedded) bound to that ServiceAccount.
#
# Usage:
#   ./build-kubeconfig.sh                         # uses NAMESPACE/SA_NAME from local.env
#   ./build-kubeconfig.sh --namespace labs --sa lab-app --out ./lab-kubeconfig
#   ./build-kubeconfig.sh --duration 24h          # OPTIONAL: mint a SHORT-LIVED bound token instead
#                                                 # (no Secret needed; NOT non-expiring)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[ -f "$ROOT/local.env" ] && { set -a; . "$ROOT/local.env"; set +a; } || true

NAMESPACE="${NAMESPACE:-labs}"
SA_NAME="${SA_NAME:-lab-app}"
OUT="${OUT:-$ROOT/lab-kubeconfig}"
DURATION=""
while [ $# -gt 0 ]; do case "$1" in
  --namespace) NAMESPACE="${2:?}"; shift 2 ;;
  --sa)        SA_NAME="${2:?}"; shift 2 ;;
  --out)       OUT="${2:?}"; shift 2 ;;
  --duration)  DURATION="${2:?}"; shift 2 ;;
  -h|--help)   sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; done

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA_DATA="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)"
[ -n "$SERVER" ] || { echo "cannot read the API server from the current kubeconfig" >&2; exit 1; }

if [ -n "$DURATION" ]; then
  echo ">> minting a BOUND token for ${NAMESPACE}/${SA_NAME} (duration ${DURATION}) — expires!" >&2
  TOKEN="$(kubectl -n "$NAMESPACE" create token "$SA_NAME" --duration="$DURATION")"
else
  SECRET="${SA_NAME}-token"
  TOKEN="$(kubectl -n "$NAMESPACE" get secret "$SECRET" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [ -n "$TOKEN" ] || { echo "no token in secret ${NAMESPACE}/${SECRET} — apply token-secret.yaml first (or pass --duration)" >&2; exit 1; }
fi

CAFILE=""
if [ -n "$CA_DATA" ]; then CAFILE="$(mktemp)"; printf '%s' "$CA_DATA" | base64 -d > "$CAFILE"; fi
cleanup() { [ -n "$CAFILE" ] && rm -f "$CAFILE"; }
trap cleanup EXIT

CLUSTER_NAME="lab-${NAMESPACE}"
CTX="${SA_NAME}@${NAMESPACE}"
KA=(--kubeconfig "$OUT")
kubectl config set-cluster "$CLUSTER_NAME" --server="$SERVER" "${KA[@]}" \
  $( [ -n "$CAFILE" ] && echo --certificate-authority="$CAFILE" --embed-certs=true )
kubectl config set-credentials "$SA_NAME" --token="$TOKEN" "${KA[@]}"
kubectl config set-context "$CTX" --cluster="$CLUSTER_NAME" --user="$SA_NAME" --namespace="$NAMESPACE" "${KA[@]}"
kubectl config use-context "$CTX" "${KA[@]}" >/dev/null
chmod 600 "$OUT"

echo "wrote $OUT  (context ${CTX})"
echo
echo "test it:"
echo "  kubectl --kubeconfig $OUT get pods -n $NAMESPACE     # allowed by the Role"
echo "  kubectl --kubeconfig $OUT get nodes                 # expected: Forbidden (least privilege)"
