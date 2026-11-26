#!/usr/bin/env bash
# enable-plugin.sh — OPTIONAL shortcut for STEP 03: enable the `traefikoidc` plugin on
# the cluster's Traefik (NKP: the `traefik` AppDeployment) via a configOverrides ConfigMap.
#
# Prefer to click through it by hand? See steps/03-enable-traefik-plugin.md — this script
# only runs the same commands for you.
#
# Usage:
#   ./09-traefik-oidc-okta/scripts/enable-plugin.sh            # dry-run: show what it would do
#   ./09-traefik-oidc-okta/scripts/enable-plugin.sh --apply    # create CM + patch AppDeployment + wait
#   ./09-traefik-oidc-okta/scripts/enable-plugin.sh --revert   # remove the override (rollback)
#
# Override auto-detection if needed:
#   TRAEFIK_APPDEPLOYMENT=traefik TRAEFIK_APPDEPLOY_NS=kommander ./.../enable-plugin.sh --apply
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# repo root = nearest ancestor with scripts/render.sh
ROOT="$HERE"
while [ ! -f "$ROOT/scripts/render.sh" ] && [ "$ROOT" != "/" ]; do ROOT="$(dirname "$ROOT")"; done
[ -f "$ROOT/scripts/render.sh" ] || { echo "cannot locate the nkp-labs repo root upward from $HERE" >&2; exit 1; }
LAB="$(basename "$(dirname "$HERE")")"
ENV_FILE="${ENV_FILE:-$ROOT/local.env}"

MODE="dry-run"
for a in "$@"; do
  case "$a" in
    --apply)  MODE="apply" ;;
    --revert) MODE="revert" ;;
    --dry-run) MODE="dry-run" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a (use --apply | --revert | --dry-run)" >&2; exit 2 ;;
  esac
done

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE — cp local.env.example local.env and edit it" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
: "${TRAEFIK_NS:?set TRAEFIK_NS in local.env}"

CM="traefik-oidc-overrides"
APPDEPLOYMENT="${TRAEFIK_APPDEPLOYMENT:-}"
APPDEPLOY_NS="${TRAEFIK_APPDEPLOY_NS:-$TRAEFIK_NS}"

# ------------------------------------------------------------------ auto-detect the AppDeployment
if [ -z "$APPDEPLOYMENT" ]; then
  found="$(kubectl get appdeployments -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
            | grep -iE 'traefik([0-9]|$)' | grep -iv 'forward' | head -1 || true)"
  if [ -n "$found" ]; then
    APPDEPLOY_NS="$(echo "$found" | awk '{print $1}')"
    APPDEPLOYMENT="$(echo "$found" | awk '{print $2}')"
  else
    APPDEPLOYMENT="traefik"   # conventional name on a single/management cluster
  fi
fi

echo "== lab 09 — Traefik OIDC plugin =="
echo "   lab              : $LAB"
echo "   override ConfigMap: $CM (namespace=$APPDEPLOY_NS)"
echo "   AppDeployment    : $APPDEPLOYMENT (namespace=$APPDEPLOY_NS)"
echo

# ------------------------------------------------------------------ revert
if [ "$MODE" = "revert" ]; then
  echo "== revert: detach the override from $APPDEPLOYMENT and delete $CM =="
  kubectl -n "$APPDEPLOY_NS" patch appdeployment "$APPDEPLOYMENT" --type json \
    -p '[{"op":"remove","path":"/spec/configOverrides"}]' 2>/dev/null || \
    echo "   (no configOverrides set — nothing to detach)"
  kubectl -n "$APPDEPLOY_NS" delete configmap "$CM" --ignore-not-found
  echo "   done. watch Traefik roll back: kubectl -n $TRAEFIK_NS rollout status deploy/$TRAEFIK_NS-traefik"
  exit 0
fi

# ------------------------------------------------------------------ render + build the CM
"$ROOT/scripts/render.sh" "$LAB" >/dev/null
SRC="$ROOT/rendered/$LAB/traefik-plugin/overrides.example.yaml"
[ -f "$SRC" ] || { echo "render produced no traefik-plugin/overrides.example.yaml" >&2; exit 1; }

if [ "$MODE" = "dry-run" ]; then
  echo "== dry-run: this is the ConfigMap that WOULD be applied =="
  sed 's/^/   /' "$SRC"
  echo
  echo "then it would run:"
  echo "   kubectl -n $APPDEPLOY_NS patch appdeployment $APPDEPLOYMENT --type merge \\"
  echo "     -p '{\"spec\":{\"configOverrides\":{\"name\":\"$CM\"}}}'"
  echo
  echo "re-run with --apply to do it."
  exit 0
fi

echo "== 1/3 apply the override ConfigMap =="
kubectl apply -f "$SRC"

echo "== 2/3 point AppDeployment/$APPDEPLOYMENT at it =="
kubectl -n "$APPDEPLOY_NS" patch appdeployment "$APPDEPLOYMENT" --type merge \
  -p "{\"spec\":{\"configOverrides\":{\"name\":\"$CM\"}}}"

echo "== 3/3 wait for Traefik to roll out =="
DEPLOY="$(kubectl -n "$TRAEFIK_NS" get deploy -o name 2>/dev/null | grep -i traefik | head -1 || true)"
if [ -n "$DEPLOY" ]; then
  kubectl -n "$TRAEFIK_NS" rollout status "$DEPLOY" --timeout=180s || true
  echo
  echo "check the plugin loaded (look for 'plugin' / 'traefikoidc'):"
  echo "  kubectl -n $TRAEFIK_NS logs $DEPLOY | grep -i -E 'plugin|traefikoidc' | tail"
else
  echo "   (could not find a traefik Deployment in $TRAEFIK_NS — check the namespace)"
fi
echo
echo "next: steps/04-create-secret.md"
