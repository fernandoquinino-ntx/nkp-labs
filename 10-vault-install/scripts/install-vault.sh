#!/usr/bin/env bash
# install-vault.sh — install a simple Vault via Helm (Option B). Renders values.example.yaml with your
# local.env, then runs `helm repo add hashicorp` + `helm upgrade --install`.
#
# Usage:
#   ./10-vault-install/scripts/install-vault.sh            # dry-run (render + show the helm commands)
#   ./10-vault-install/scripts/install-vault.sh --apply
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/scripts/render.sh" ] && [ "$ROOT" != "/" ]; do ROOT="$(dirname "$ROOT")"; done
[ -f "$ROOT/scripts/render.sh" ] || { echo "cannot locate the nkp-labs repo root from $HERE" >&2; exit 1; }
LAB="$(basename "$(dirname "$HERE")")"
ENV_FILE="${ENV_FILE:-$ROOT/local.env}"

MODE="dry-run"
for a in "$@"; do case "$a" in --apply) MODE="apply";; --dry-run) MODE="dry-run";; -h|--help) sed -n '2,12p' "$0"; exit 0;; *) echo "unknown flag: $a" >&2; exit 2;; esac; done

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE — cp local.env.example local.env and edit it" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
NS="${VAULT_NAMESPACE:-vault}"
R="${VAULT_RELEASE:-vault}"

"$ROOT/scripts/render.sh" "$LAB" >/dev/null
VALUES="$ROOT/rendered/$LAB/values.example.yaml"
[ -f "$VALUES" ] || { echo "render produced no $VALUES" >&2; exit 1; }

CHART="hashicorp/vault"
CMD_INSTALL=(helm upgrade --install "$R" "$CHART" -n "$NS" --create-namespace -f "$VALUES")

if [ "$MODE" = "dry-run" ]; then
  echo "== dry-run: install Vault (standalone) =="
  echo "  helm repo add hashicorp https://helm.releases.hashicorp.com"
  echo "  helm repo update"
  echo "  ${CMD_INSTALL[*]}"
  echo
  echo "  values: rendered/$LAB/values.example.yaml  (ns=$NS release=$R storageClass=${VAULT_STORAGE_CLASS:-<default>})"
  echo "  then unseal:  scripts/init-unseal.sh --apply"
  exit 0
fi

command -v helm >/dev/null || { echo "helm not found" >&2; exit 1; }
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
"${CMD_INSTALL[@]}"

echo
echo "installed. wait for the pod, then initialize + unseal:"
echo "  kubectl -n $NS get pod $R-0 -w"
echo "  scripts/init-unseal.sh --apply"
