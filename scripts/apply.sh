#!/usr/bin/env bash
# apply.sh <lab-dir> — render the lab with local.env and `kubectl apply` it.
#   ./scripts/apply.sh 00-prereqs
#   ./scripts/apply.sh 01-pvc-rwx-busybox
#
# Applies ONLY the lab's top-level manifests. Sub-directories (e.g. an optional Traefik
# IngressRoute under `ingressroute/`) are NOT applied — apply them explicitly when wanted.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LAB="$(basename "${1:?usage: apply.sh <lab-dir>   e.g. 00-prereqs}")"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

"$ROOT/scripts/render.sh" "$LAB"
NS="$( . "$ROOT/local.env"; echo "${NAMESPACE:-default}" )"

shopt -s nullglob
files=("$ROOT/rendered/$LAB"/*.yaml)          # top-level only (skip subdirs)
shopt -u nullglob
[ "${#files[@]}" -gt 0 ] || { echo "no manifests in rendered/$LAB/" >&2; exit 1; }

# Concatenate to a real temp file, with `---` BETWEEN files (a plain `cat f1 f2` would merge the
# last doc of one file with the first of the next, and kubectl would silently drop them).
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
for f in "${files[@]}"; do
  printf -- '---\n' >> "$tmp"
  cat "$f" >> "$tmp"
  printf '\n' >> "$tmp"
done
kubectl apply -f "$tmp"

echo
echo "applied '$LAB' into namespace '$NS' (${#files[@]} files).  Watch it:"
echo "  kubectl -n $NS get all,pvc,ingress -o wide -w"
