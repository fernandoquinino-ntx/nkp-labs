#!/usr/bin/env bash
# uninstall.sh — OPTIONAL shortcut for STEP 10: remove everything this lab created.
# It does NOT touch the Traefik plugin unless you pass --plugin.
#
# Usage:
#   ./09-traefik-oidc-okta/scripts/uninstall.sh            # app + secret + middleware + route
#   ./09-traefik-oidc-okta/scripts/uninstall.sh --plugin   # ALSO revert the Traefik override
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/scripts/render.sh" ] && [ "$ROOT" != "/" ]; do ROOT="$(dirname "$ROOT")"; done
ENV_FILE="${ENV_FILE:-$ROOT/local.env}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; } || true
NS="${NS:-${NAMESPACE:-labs}}"
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

PLUGIN=0
for a in "$@"; do case "$a" in --plugin) PLUGIN=1 ;; esac; done

echo "== delete route -> middleware -> app -> secret (order matters) =="
kubectl -n "$NS" delete ingressroute whoami --ignore-not-found
kubectl -n "$NS" delete middleware oidc-auth --ignore-not-found
kubectl -n "$NS" delete deploy/whoami svc/whoami --ignore-not-found
kubectl -n "$NS" delete secret okta-oidc --ignore-not-found

if [ "$PLUGIN" = 1 ]; then
  echo
  echo "== revert the Traefik override =="
  "$HERE/enable-plugin.sh" --revert
fi
echo
echo "done."
