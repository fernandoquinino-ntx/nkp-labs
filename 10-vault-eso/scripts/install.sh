#!/usr/bin/env bash
# install.sh — OPTIONAL shortcut for Path A (steps 04-05): create the demo namespace, the ESO
# AppDeployment override (the "credential store" as Helm values) and the AppDeployment that installs
# ESO on the workload cluster and points at that override.
#
# It does NOT do the Vault-side glue (step 02) or the seed (step 03) — see scripts/vault-remote-auth.sh
# and vault/kv-seed.md. It also assumes the override ConfigMap values in local.env are already correct.
#
# Usage:
#   ./10-vault-eso/scripts/install.sh                 # dry-run (render + show what would be applied)
#   ./10-vault-eso/scripts/install.sh --apply         # do it
#
# Kubeconfigs (from local.env, optional — otherwise the current context is used):
#   MGMT_KUBECONFIG       -> the management cluster  (override CM + AppDeployment)
#   WORKLOAD_KUBECONFIG   -> the workload cluster    (the demo namespace)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/scripts/render.sh" ] && [ "$ROOT" != "/" ]; do ROOT="$(dirname "$ROOT")"; done
[ -f "$ROOT/scripts/render.sh" ] || { echo "cannot locate the nkp-labs repo root upward from $HERE" >&2; exit 1; }
LAB="$(basename "$(dirname "$HERE")")"
ENV_FILE="${ENV_FILE:-$ROOT/local.env}"

MODE="dry-run"
for a in "$@"; do
  case "$a" in
    --apply) MODE="apply" ;;
    --dry-run) MODE="dry-run" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a (use --apply | --dry-run)" >&2; exit 2 ;;
  esac
done

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE — cp local.env.example local.env and edit it" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

: "${NAMESPACE:?set NAMESPACE in local.env}"
: "${WORKSPACE_NS:?set WORKSPACE_NS (the workspace namespace of the workload cluster) in local.env}"
: "${WORKLOAD_CLUSTER:?set WORKLOAD_CLUSTER in local.env}"
ESO_OVERRIDES_CM="${ESO_OVERRIDES_CM:-external-secrets-overrides}"

# Talk to the right cluster: --kubeconfig when provided, else the current context.
K()  { kubectl ${MGMT_KUBECONFIG:+--kubeconfig "$MGMT_KUBECONFIG"} "$@"; }        # management
KS() { kubectl ${WORKLOAD_KUBECONFIG:+--kubeconfig "$WORKLOAD_KUBECONFIG"} "$@"; } # workload

echo "== render ($ENV_FILE) =="
"$ROOT/scripts/render.sh" "$LAB" >/dev/null
R="$ROOT/rendered/$LAB"
NS_YAML="$R/namespace.yaml"
OVERRIDE="$R/overrides/eso-overrides.example.yaml"
APPDEP="$R/overrides/appdeployment.example.yaml"
for f in "$NS_YAML" "$OVERRIDE" "$APPDEP"; do [ -f "$f" ] || { echo "render produced no $f" >&2; exit 1; }; done

if [ "$MODE" = "dry-run" ]; then
  echo "== dry-run: would apply =="
  echo "   [workload:${WORKLOAD_CLUSTER}] kubectl apply -f rendered/$LAB/namespace.yaml"
  echo "   [mgmt:ns ${WORKSPACE_NS}]      kubectl apply -f rendered/$LAB/overrides/eso-overrides.example.yaml"
  echo "   [mgmt:ns ${WORKSPACE_NS}]      kubectl apply --server-side -f rendered/$LAB/overrides/appdeployment.example.yaml"
  echo
  echo "   (ensure VAULT_CA_BUNDLE is set — run scripts/fetch-vault-ca.sh first)"
  echo "re-run with --apply to do it."
  exit 0
fi

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

if [ -z "${VAULT_CA_BUNDLE:-}" ]; then
  echo "WARNING: VAULT_CA_BUNDLE is empty — run scripts/fetch-vault-ca.sh, else the store will be NotReady" >&2
fi

echo "== 1/3 demo namespace on the workload =="
KS apply -f "$NS_YAML"

echo "== 2/3 override ConfigMap on the management cluster =="
K -n "$WORKSPACE_NS" apply -f "$OVERRIDE"

echo "== 3/3 AppDeployment (installs ESO on ${WORKLOAD_CLUSTER} + points at the override) =="
K -n "$WORKSPACE_NS" apply --server-side -f "$APPDEP"

echo
echo "applied. watch it:"
echo "  kubectl --kubeconfig \$WORKLOAD_KUBECONFIG get clustersecretstore,externalsecret -A -w"
echo "then: scripts/verify.sh"
