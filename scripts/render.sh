#!/usr/bin/env bash
# render.sh <lab-dir|all> — substitute ${PLACEHOLDERS} from local.env into rendered/<lab>/.
# Recurses into subdirectories (e.g. a lab's "alternative" manifests) so they render too.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/local.env}"
OUT="$ROOT/rendered"

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE — copy local.env.example to local.env and edit it" >&2; exit 1; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "usage: $0 <lab-dir|all>   e.g. $0 01-pvc-rwx-busybox" >&2; exit 1; }

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

KEYS="NAMESPACE RWX_STORAGE_CLASS PVC_SIZE DOMAIN APP_HOST INGRESS_CLASS REPLICAS SA_NAME DNS_SERVER DNS_ZONE"

rm -rf "$OUT"; mkdir -p "$OUT"
if [ "$TARGET" = "all" ]; then mapfile -t LABS < <(cd "$ROOT" && ls -d [0-9][0-9]-*/ 2>/dev/null); else mapfile -t LABS < <(echo "${TARGET%/}/"); fi

for d in "${LABS[@]}"; do
  src="$ROOT/${d%/}"; [ -d "$src" ] || { echo "no such lab: $src" >&2; exit 1; }
  lab="$(basename "$src")"
  while IFS= read -r f; do
    rel="${f#"$src"/}"; out="$OUT/$lab/$rel"; mkdir -p "$(dirname "$out")"
    cp "$f" "$out"
    for key in $KEYS; do
      val="${!key:-}"; [ -n "$val" ] || continue
      sed -i "s|\${${key}}|${val}|g" "$out"
    done
  done < <(find "$src" -type f -name '*.yaml' | sort)
done
echo "rendered -> $OUT"
