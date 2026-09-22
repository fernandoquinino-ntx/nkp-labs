#!/usr/bin/env bash
# uninstall.sh — remove the Splunk OTel Collector installed by this lab.
#
#   ./08-splunk-otel-helm/uninstall.sh            # helm uninstall the release
#   ./08-splunk-otel-helm/uninstall.sh --template # remove what `install.sh --template` applied
#   ./08-splunk-otel-helm/uninstall.sh --purge    # also delete the namespace
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
[ -f "$ROOT/local.env" ] && { set -a; . "$ROOT/local.env"; set +a; } || true
NS="${OTEL_NAMESPACE:-splunk-otel}"
REL="${OTEL_RELEASE:-splunk-otel-collector}"

MODE="helm"; PURGE=0
for a in "$@"; do
  case "$a" in
    --template) MODE="template" ;;
    --purge)    PURGE=1 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

if [ "$MODE" = "helm" ]; then
  helm -n "$NS" uninstall "$REL" 2>/dev/null || echo "(no helm release $REL in $NS)"
else
  kubectl -n "$NS" delete -l app.kubernetes.io/instance="$REL" ds,deploy,svc,sa,cm,secret,clusterrole,clusterrolebinding --ignore-not-found 2>/dev/null || true
  echo "(best-effort delete of the rendered objects)"
fi

if [ "$PURGE" = 1 ]; then
  kubectl delete namespace "$NS" --ignore-not-found
  echo "uninstalled and deleted namespace $NS."
else
  echo "uninstalled (kept namespace $NS)."
fi
