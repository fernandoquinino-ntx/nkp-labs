#!/usr/bin/env bash
# Safely clean up a stuck kind bootstrap cluster on the bastion after a failed
# `nkp create cluster` or `install-nkp.sh` run. Does NOT touch the local registry
# (`nkp-registry`), `registry/`, `airgap/`, env files, or kubeconfigs.
#
#   ./scripts/cleanup-bootstrap.sh [-y|--yes]
set -Eeuo pipefail

AUTO_YES=false
if [ "${1:-}" = "-y" ] || [ "${1:-}" = "--yes" ]; then
  AUTO_YES=true
fi

if ! docker info >/dev/null 2>&1; then
  echo "docker daemon is not reachable by $(id -un)." >&2
  exit 1
fi

mapfile -t leftovers < <(docker ps -a --format '{{.Names}}' | grep -E '^(konvoy-capi-bootstrapper|kind-)' | grep -v '^nkp-registry$' || true)

if [ "${#leftovers[@]}" -eq 0 ]; then
  echo "No leftover kind/NKP bootstrap containers found."
  exit 0
fi

echo "Found leftover bootstrap container(s):"
printf '  - %s\n' "${leftovers[@]}"
echo "Untouched: nkp-registry, ~/nkp-workspace/registry/, airgap/, create-cluster.env, env, values.local.yaml"

if [ "${AUTO_YES}" != "true" ]; then
  read -r -p "Remove these bootstrap container(s)? [y/N] " ans
  case "${ans}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

if command -v nkp >/dev/null 2>&1; then
  echo "=== running nkp delete bootstrap ==="
  nkp delete bootstrap || true
fi

mapfile -t remaining < <(docker ps -a --format '{{.Names}}' | grep -E '^(konvoy-capi-bootstrapper|kind-)' | grep -v '^nkp-registry$' || true)
if [ "${#remaining[@]}" -gt 0 ]; then
  echo "=== removing remaining bootstrap container(s): ${remaining[*]} ==="
  docker rm -f "${remaining[@]}"
fi

echo "=== bootstrap cleanup complete ==="
echo "Note: if VMs had already started creating in Prism Central, check Prism Central for orphaned cluster VMs before retrying."
