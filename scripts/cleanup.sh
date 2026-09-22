#!/usr/bin/env bash
# cleanup.sh <lab-dir> — delete everything a lab created.
#   ./scripts/cleanup.sh 01-pvc-rwx-busybox
# NOTE: for many storage classes the PVC deletion also deletes the data (reclaimPolicy=Delete).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LAB="$(basename "${1:?usage: cleanup.sh <lab-dir>   e.g. 01-pvc-rwx-busybox}")"

[ -d "$ROOT/rendered/$LAB" ] || "$ROOT/scripts/render.sh" "$LAB" >/dev/null
kubectl delete -f "$ROOT/rendered/$LAB/" --ignore-not-found
echo "deleted '$LAB'."
