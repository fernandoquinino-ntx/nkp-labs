#!/usr/bin/env bash
# apply-raw.sh — OPTIONAL shortcut for Path B: apply the raw manifests (no AppDeployment override):
#   [store] the ClusterSecretStore              — the credential store, applied directly
#   [TEST ] the ExternalSecret + demo Deployment — a consumer, to prove it works
#
# Use this to see the "CR" form side-by-side with the override form (Path A). Do NOT run both at once
# (same object names).
#
# Usage:
#   ./11-vault-eso/scripts/apply-raw.sh              # dry-run (render + show)
#   ./11-vault-eso/scripts/apply-raw.sh --apply
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/scripts/render.sh" ] && [ "$ROOT" != "/" ]; do ROOT="$(dirname "$ROOT")"; done
LAB="$(basename "$(dirname "$HERE")")"
ENV_FILE="${ENV_FILE:-$ROOT/local.env}"

MODE="dry-run"
for a in "$@"; do case "$a" in --apply) MODE="apply";; --dry-run) MODE="dry-run";; -h|--help) sed -n '2,14p' "$0"; exit 0;; *) echo "unknown flag: $a" >&2; exit 2;; esac; done

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
KS() { kubectl ${WORKLOAD_KUBECONFIG:+--kubeconfig "$WORKLOAD_KUBECONFIG"} "$@"; }

"$ROOT/scripts/render.sh" "$LAB" >/dev/null
R="$ROOT/rendered/$LAB"
FILES=("$R/namespace.yaml" "$R/eso/clustersecretstore.example.yaml" "$R/eso/externalsecret.example.yaml" "$R/app/deployment.yaml")
for f in "${FILES[@]}"; do [ -f "$f" ] || { echo "render produced no $f" >&2; exit 1; }; done

if [ "$MODE" = "dry-run" ]; then
  echo "== dry-run: would apply (Path B, raw) =="
  echo "  [store] $R/eso/clustersecretstore.example.yaml"
  echo "  [TEST ] $R/eso/externalsecret.example.yaml"
  echo "  [TEST ] $R/app/deployment.yaml"
  echo "re-run with --apply to do it."
  exit 0
fi

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

for f in "${FILES[@]}"; do echo "== apply $(basename "$f") =="; KS apply -f "$f"; done
echo; echo "applied (raw). verify: scripts/verify.sh"
