#!/usr/bin/env bash
# verify.sh — OPTIONAL shortcut for STEP 08: check the pieces exist and that the route
# redirects an unauthenticated request to Okta (the whole point of the lab).
#
# Usage: ./09-traefik-oidc-okta/scripts/verify.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/scripts/render.sh" ] && [ "$ROOT" != "/" ]; do ROOT="$(dirname "$ROOT")"; done
ENV_FILE="${ENV_FILE:-$ROOT/local.env}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; } || true
NS="${NS:-${NAMESPACE:-labs}}"
HOST="${OIDC_HOST:-whoami}.${DOMAIN:-example.com}"
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

echo "== namespace $NS =="
kubectl get ns "$NS" >/dev/null 2>&1 && echo "  ok" || echo "  MISSING (apply namespace.yaml / run lab 00)"

echo
echo "== objects =="
kubectl -n "$NS" get deploy/whoami svc/whoami secret/okta-oidc 2>&1 | sed 's/^/  /'
kubectl -n "$NS" get middleware oidc-auth 2>&1 | sed 's/^/  /'
kubectl -n "$NS" get ingressroute whoami 2>&1 | sed 's/^/  /'

echo
echo "== Traefik plugin loaded? (static config — needs a Traefik restart after step 03) =="
DEPLOY="$(kubectl -n "${TRAEFIK_NS:-kommander}" get deploy -o name 2>/dev/null | grep -i traefik | head -1 || true)"
if [ -n "$DEPLOY" ]; then
  kubectl -n "${TRAEFIK_NS:-kommander}" logs "$DEPLOY" 2>/dev/null | grep -i -E 'plugin|traefikoidc' | tail -5 | sed 's/^/  /' \
    || echo "  (no plugin lines — is experimental.plugins set? does Traefik have egress to plugins.traefik.io?)"
  kubectl -n "${TRAEFIK_NS:-kommander}" get "$DEPLOY" -o jsonpath='  image: {.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null || true
else
  echo "  (no traefik Deployment in ${TRAEFIK_NS:-kommander})"
fi

echo
echo "== HTTP probe: https://$HOST/ =="
code="$(curl -skI -o /dev/null -w '%{http_code}' "https://$HOST/" 2>/dev/null || echo 'curl-failed')"
loc="$(curl -skI "https://$HOST/" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}' | head -1 || true)"
echo "  status : $code"
echo "  location: ${loc:-<none>}"
case "$code" in
  302|303) echo "  ✅ unauthenticated request is redirected to the IdP (expected)";;
  200)     echo "  ⚠ 200 — the route may be UNAUTHENTICATED (missing/incorrect middleware) or you sent a session cookie";;
  000|curl-failed) echo "  ⚠ could not reach https://$HOST — DNS? cert? ingress LB?";;
  *)       echo "  ⚠ unexpected ($code) — see steps/09-troubleshooting.md";;
esac
