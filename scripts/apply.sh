#!/usr/bin/env bash
# apply.sh <lab-dir> — render the lab with local.env and `kubectl apply` it.
#   ./scripts/apply.sh 00-prereqs
#   ./scripts/apply.sh 01-pvc-rwx-busybox
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LAB="$(basename "${1:?usage: apply.sh <lab-dir>   e.g. 00-prereqs}")"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

"$ROOT/scripts/render.sh" "$LAB"
NS="$( . "$ROOT/local.env"; echo "${NAMESPACE:-default}" )"

kubectl apply -f "$ROOT/rendered/$LAB/"
echo
echo "applied '$LAB' into namespace '$NS'.  Watch it:"
echo "  kubectl -n $NS get all,pvc,ingress -o wide -w"
