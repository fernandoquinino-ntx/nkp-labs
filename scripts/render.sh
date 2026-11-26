#!/usr/bin/env bash
# render.sh <lab-dir|all> — substitute ${PLACEHOLDERS} from local.env into rendered/<lab>/.
# Recurses into subdirectories (e.g. a lab's "alternative" manifests) so they render too.
# Skips 12-bootstrap-machine in `all` mode because Lab 12 uses its own bastion env files.
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

# Derive substitution keys dynamically from ENV_FILE so new placeholders never need manual sync.
mapfile -t KEYS < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | cut -d= -f1 | sort -u)

rm -rf "$OUT"; mkdir -p "$OUT"
if [ "$TARGET" = "all" ]; then
  mapfile -t LABS < <(cd "$ROOT" && for d in [0-9][0-9]-*/; do [ "$d" = "12-bootstrap-machine/" ] && continue; echo "$d"; done)
else
  mapfile -t LABS < <(echo "${TARGET%/}/")
fi

# Prefer Python 3 for cross-platform (Linux + macOS) substitution safe with `|` and `&` in values.
if command -v python3 >/dev/null 2>&1; then
  KEYS_JOINED="$(IFS=,; echo "${KEYS[*]}")"
  python3 - "$ROOT" "$OUT" "$KEYS_JOINED" "${LABS[@]}" <<'PY'
import os, sys

root, out_root, keys_csv = sys.argv[1], sys.argv[2], sys.argv[3]
labs = sys.argv[4:]
keys = [k for k in keys_csv.split(",") if k]
values = {k: os.environ.get(k, "") for k in keys if os.environ.get(k, "")}

for d in labs:
    src = os.path.join(root, d.rstrip("/"))
    if not os.path.isdir(src):
        sys.exit(f"no such lab: {src}")
    lab = os.path.basename(src)
    for cur_dir, _, files in os.walk(src):
        for fn in sorted(files):
            if not fn.endswith(".yaml"):
                continue
            full = os.path.join(cur_dir, fn)
            rel = os.path.relpath(full, src)
            dst = os.path.join(out_root, lab, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(full, "r", encoding="utf-8") as fh:
                content = fh.read()
            for k, v in values.items():
                content = content.replace("${" + k + "}", v)
            with open(dst, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(content)
PY
else
  for d in "${LABS[@]}"; do
    src="$ROOT/${d%/}"; [ -d "$src" ] || { echo "no such lab: $src" >&2; exit 1; }
    lab="$(basename "$src")"
    while IFS= read -r f; do
      rel="${f#"$src"/}"; out="$OUT/$lab/$rel"; mkdir -p "$(dirname "$out")"
      cp "$f" "$out"
      for key in "${KEYS[@]}"; do
        val="${!key:-}"; [ -n "$val" ] || continue
        esc="${val//\\/\\\\}"; esc="${esc//&/\\&}"; esc="${esc//|/\\|}"
        tmp="${out}.tmp"
        sed "s|\${${key}}|${esc}|g" "$out" > "$tmp" && mv "$tmp" "$out"
      done
    done < <(find "$src" -type f -name '*.yaml' | sort)
  done
fi
echo "rendered -> $OUT"
