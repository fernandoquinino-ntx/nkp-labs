#!/usr/bin/env bash
# verify.sh — check the whole flow: ESO on the workload, the store, the ExternalSecret, the synced
# Secret and the demo pod's view of it.
#
# Usage: ./11-vault-eso/scripts/verify.sh
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
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
K()  { kubectl ${MGMT_KUBECONFIG:+--kubeconfig "$MGMT_KUBECONFIG"} "$@"; }
KS() { kubectl ${WORKLOAD_KUBECONFIG:+--kubeconfig "$WORKLOAD_KUBECONFIG"} "$@"; }

rc=0
echo "== ESO running on the workload cluster? =="
if KS -n external-secrets get deploy external-secrets >/dev/null 2>&1; then
  KS -n external-secrets get deploy external-secrets | sed 's/^/  /'
else
  echo "  MISSING — enable ESO (step 04)"; rc=1
fi

echo; echo "== ClusterSecretStore $SS =="
if KS get clustersecretstore "$SS" >/dev/null 2>&1; then
  KS get clustersecretstore "$SS" | sed 's/^/  /'
  KS get clustersecretstore "$SS" -o jsonpath='{.status.conditions[*].message}{"\n"}' | sed 's/^/  msg: /'
else
  echo "  MISSING — apply the override (step 05)"; rc=1
fi

echo; echo "== ExternalSecret $ES (ns $NS) =="
if KS -n "$NS" get externalsecret "$ES" >/dev/null 2>&1; then
  KS -n "$NS" get externalsecret "$ES" | sed 's/^/  /'
  KS -n "$NS" get externalsecret "$ES" -o jsonpath='{.status.conditions[*].message}{"\n"}' | sed 's/^/  msg: /'
else
  echo "  MISSING"; rc=1
fi

echo; echo "== synced Kubernetes Secret =="
if KS -n "$NS" get secret "$ES" >/dev/null 2>&1; then
  KS -n "$NS" get secret "$ES" -o custom-columns='NAME:.metadata.name,KEYS:.data' | sed 's/^/  /'
  echo "  username=$(KS -n "$NS" get secret "$ES" -o jsonpath='{.data.username}' | base64 -d)"
else
  echo "  MISSING (not synced yet?)"; rc=1
fi

echo; echo "== demo pod view =="
if KS -n "$NS" get deploy lab-eso-demo >/dev/null 2>&1; then
  KS -n "$NS" logs deploy/lab-eso-demo --tail=20 | sed 's/^/  /' || true
else
  echo "  (no demo Deployment — path A renders it, or apply path B)"
fi

echo
if [ "$rc" = 0 ]; then echo "✅ looks good"; else echo "⚠ some pieces are missing — see steps/09-troubleshooting.md"; fi
exit "$rc"
