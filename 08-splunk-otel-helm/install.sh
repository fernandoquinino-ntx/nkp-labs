#!/usr/bin/env bash
# install.sh — install the Splunk OpenTelemetry Collector with plain `helm`, from this lab.
#
# Steps (all visible, nothing hidden):
#   1. render  values.example.yaml -> rendered/08-splunk-otel-helm/values.example.yaml (from local.env)
#   2. add the public Splunk chart repo (no NKP catalog involved)
#   3. helm upgrade --install
#
# Usage:
#   ./08-splunk-otel-helm/install.sh              # dry-run (safe preview), then tells you to --apply
#   ./08-splunk-otel-helm/install.sh --apply      # install / upgrade
#   ./08-splunk-otel-helm/install.sh --template   # render with `helm template` and `kubectl apply`
#                                                 #   (no Helm release state — GitOps-style)
#
# Requires: helm, kubectl. Config comes from ./local.env (copy local.env.example first).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Repo root = the nearest ancestor containing scripts/render.sh. This works no matter
# which directory you call the script from (and through symlinks).
ROOT="$HERE"
while [ ! -f "$ROOT/scripts/render.sh" ] && [ "$ROOT" != "/" ]; do ROOT="$(dirname "$ROOT")"; done
[ -f "$ROOT/scripts/render.sh" ] || { echo "cannot locate the nkp-labs repo root (scripts/render.sh) upward from $HERE" >&2; exit 1; }
LAB="$(basename "$HERE")"
ENV_FILE="${ENV_FILE:-$ROOT/local.env}"

MODE="dry-run"
for a in "$@"; do
  case "$a" in
    --apply)    MODE="apply" ;;
    --dry-run)  MODE="dry-run" ;;
    --template) MODE="template" ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a (use --apply | --dry-run | --template)" >&2; exit 2 ;;
  esac
done

command -v helm >/dev/null    || { echo "helm not found — install Helm or use the render-only commands in the README" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE — cp local.env.example local.env and edit it" >&2; exit 1; }

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
: "${OTEL_NAMESPACE:?set OTEL_NAMESPACE in local.env}"
: "${OTEL_RELEASE:?set OTEL_RELEASE in local.env}"
: "${CHART_VERSION:?set CHART_VERSION in local.env}"
: "${SPLUNK_HEC_ENDPOINT:?set SPLUNK_HEC_ENDPOINT in local.env}"
: "${SPLUNK_HEC_TOKEN:?set SPLUNK_HEC_TOKEN in local.env}"
: "${SPLUNK_INDEX:?set SPLUNK_INDEX in local.env}"
: "${SPLUNK_METRICS_INDEX:?set SPLUNK_METRICS_INDEX in local.env}"
: "${SPLUNK_CLUSTER_NAME:?set SPLUNK_CLUSTER_NAME in local.env}"

REPO_NAME="splunk-otel-collector-chart"
REPO_URL="https://signalfx.github.io/splunk-otel-collector-chart"

echo "== 1/3 render values (from $ENV_FILE) =="
"$ROOT/scripts/render.sh" "$LAB" >/dev/null
VALUES="$ROOT/rendered/$LAB/values.example.yaml"
[ -f "$VALUES" ] || { echo "render produced no values.example.yaml" >&2; exit 1; }
echo "   $VALUES"

echo "== 2/3 helm repo add/update ($REPO_NAME) =="
helm repo add "$REPO_NAME" "$REPO_URL" >/dev/null 2>&1 || true
helm repo update "$REPO_NAME" >/dev/null

CHART="$REPO_NAME/splunk-otel-collector"
echo "== 3/3 chart $CHART --version $CHART_VERSION  ->  ns/$OTEL_NAMESPACE release/$OTEL_RELEASE =="
HELM_ARGS=(--version "$CHART_VERSION" -n "$OTEL_NAMESPACE" --create-namespace -f "$VALUES")

case "$MODE" in
  dry-run)
    helm template "$OTEL_RELEASE" "$CHART" "${HELM_ARGS[@]}" >/dev/null
    echo "   dry-run OK (the chart rendered). Now install it:"
    echo "     $HERE/install.sh --apply"
    ;;
  apply)
    helm upgrade --install "$OTEL_RELEASE" "$CHART" "${HELM_ARGS[@]}"
    echo
    echo "installed. watch it:"
    echo "  kubectl -n $OTEL_NAMESPACE get ds,deploy,pods"
    echo "then verify:  $HERE/verify.sh"
    ;;
  template)
    echo "   (no Helm release — applying rendered manifests with kubectl)"
    helm template "$OTEL_RELEASE" "$CHART" "${HELM_ARGS[@]}" | kubectl apply -f -
    echo
    echo "applied. NOTE: there is no Helm release, so use './uninstall.sh --template' to remove it."
    ;;
esac
