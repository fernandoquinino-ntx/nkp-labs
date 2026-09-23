#!/usr/bin/env bash
# install.sh — OPTIONAL shortcut for STEPS 04-07: deploy the demo app, the OIDC Secret,
# the Middleware and the protected IngressRoute. Every command is shown in the step docs;
# this just runs them in the right order. It does NOT enable the plugin (step 03) — run
# scripts/enable-plugin.sh for that.
#
# Usage:
#   ./09-traefik-oidc-okta/scripts/install.sh            # dry-run (render + show)
#   ./09-traefik-oidc-okta/scripts/install.sh --apply    # apply everything
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
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a (use --apply | --dry-run)" >&2; exit 2 ;;
  esac
done

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE — cp local.env.example local.env and edit it" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
: "${NAMESPACE:?set NAMESPACE in local.env}"
: "${DOMAIN:?set DOMAIN in local.env}"
: "${OIDC_HOST:?set OIDC_HOST in local.env}"

echo "== 1/5 render ($ENV_FILE) =="
"$ROOT/scripts/render.sh" "$LAB" >/dev/null
R="$ROOT/rendered/$LAB"

FILES=(
  "$R/namespace.yaml"
  "$R/app/deployment.yaml"
  "$R/app/service.yaml"
  "$R/oidc/secret.example.yaml"
  "$R/oidc/middleware.yaml"
  "$R/ingressroute/ingressroute.yaml"
)
for f in "${FILES[@]}"; do [ -f "$f" ] || { echo "render produced no $f" >&2; exit 1; }; done

if [ "$MODE" = "dry-run" ]; then
  echo "== dry-run: would apply, in order =="
  printf '   %s\n' "${FILES[@]#"$ROOT"/}"
  echo
  echo "   (the Secret is rendered from local.env; its values are shown only in rendered/)"
  echo "re-run with --apply to do it."
  exit 0
fi

echo "== 2/5 namespace =="
kubectl apply -f "$R/namespace.yaml"

echo "== 3/5 demo app =="
kubectl apply -f "$R/app/deployment.yaml" -f "$R/app/service.yaml"
kubectl -n "$NAMESPACE" rollout status deploy/whoami --timeout=120s

echo "== 4/5 OIDC Secret + Middleware =="
kubectl apply -f "$R/oidc/secret.example.yaml"
kubectl apply -f "$R/oidc/middleware.yaml"

echo "== 5/5 protected IngressRoute =="
kubectl apply -f "$R/ingressroute/ingressroute.yaml"

echo
echo "applied. check:"
echo "  kubectl -n $NAMESPACE get middleware,ingressroute,secret,pods"
echo "  curl -kI https://$OIDC_HOST.$DOMAIN/       # expect 302 to Okta"
echo "then: steps/08-test-the-flow.md"
