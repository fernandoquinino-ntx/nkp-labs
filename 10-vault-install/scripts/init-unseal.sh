#!/usr/bin/env bash
# init-unseal.sh — initialize a fresh Vault and unseal it (needs 3 of 5 keys).
# Saves the init output (root token + unseal keys) into Secret/<vault-init> in the Vault namespace.
#
# Requires: kubectl, jq.  Works for standalone (one pod) and HA (all pods).
#
# Usage:
#   ./10-vault-install/scripts/init-unseal.sh            # dry-run (prints what it would do)
#   ./10-vault-install/scripts/init-unseal.sh --apply
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/scripts/render.sh" ] && [ "$ROOT" != "/" ]; do ROOT="$(dirname "$ROOT")"; done
ENV_FILE="${ENV_FILE:-$ROOT/local.env}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; } || true
NS="${VAULT_NAMESPACE:-vault}"
R="${VAULT_RELEASE:-vault}"
SECRET="${VAULT_INIT_SECRET:-vault-init}"

MODE="dry-run"
for a in "$@"; do case "$a" in --apply) MODE="apply";; --dry-run) MODE="dry-run";; -h|--help) sed -n '2,11p' "$0"; exit 0;; *) echo "unknown flag: $a" >&2; exit 2;; esac; done

if [ "$MODE" = "dry-run" ]; then
  cat <<EOF
== dry-run: init + unseal (ns=$NS release=$R) ==

# 1) initialize (ONCE) and store the output in Secret/$SECRET
kubectl -n $NS exec $R-0 -- vault operator init -key-shares=5 -key-threshold=3 -format=json > /tmp/init.json
kubectl -n $NS create secret generic $SECRET --from-file=init.json=/tmp/init.json \\
  --from-literal=root_token=\$(jq -r .root_token /tmp/init.json) \\
  --from-literal=unseal_key_1=\$(jq -r '.unseal_keys_b64[0]' /tmp/init.json) ... (1..5)

# 2) unseal every vault pod with 3 of the keys
for pod in \$($R-0 [$R-1 $R-2]); do for k in 1 2 3; do kubectl -n $NS exec \$pod -- \\
  vault operator unseal "\$(kubectl -n $NS get secret $SECRET -o jsonpath="{.data.unseal_key_\$k}" | base64 -d)"; done; done

re-run with --apply to do it.
EOF
  exit 0
fi

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

# --- init (skip if the secret already exists) ---
if kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
  echo "== Secret/$SECRET already exists — skipping init (reusing keys) =="
else
  echo "== initializing Vault (once) =="
  OUT="$(kubectl -n "$NS" exec "$R-0" -- vault operator init -key-shares=5 -key-threshold=3 -format=json)"
  args=(--from-literal=root_token="$(printf '%s' "$OUT" | jq -r .root_token)"
        --from-literal=unseal_keys_b64="$(printf '%s' "$OUT" | jq -c '.unseal_keys_b64')")
  for i in 1 2 3 4 5; do
    args+=(--from-literal="unseal_key_${i}=$(printf '%s' "$OUT" | jq -r ".unseal_keys_b64[$((i-1))]")")
  done
  kubectl -n "$NS" create secret generic "$SECRET" "${args[@]}"
  echo "   stored in Secret/$SECRET  —  KEEP IT SAFE (root token + unseal keys)"
fi

# --- unseal every pod ---
PODS="$(kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=$R" -o name | sed 's|^pod/||')"
[ -n "$PODS" ] || PODS="$R-0"
echo "== sealing check / unseal =="
for pod in $PODS; do
  sealed="$(kubectl -n "$NS" exec "$pod" -- vault status -format=json 2>/dev/null | jq -r .sealed || echo true)"
  if [ "$sealed" != "true" ]; then echo "   $pod: already unsealed"; continue; fi
  for k in 1 2 3; do
    key="$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath="{.data.unseal_key_$k}" | base64 -d)"
    kubectl -n "$NS" exec "$pod" -- vault operator unseal "$key" >/dev/null
  done
  echo "   $pod: unsealed"
done

echo
echo "done. status:"
kubectl -n "$NS" exec "${PODS%% *}" -- vault status 2>/dev/null | sed 's/^/  /' || true
