#!/usr/bin/env bash
# fetch-vault-ca.sh — populate VAULT_CA_BUNDLE in local.env with the base64 PEM of the CA that signed
# Vault's server certificate.
#
# ESO's Vault provider needs to trust Vault's TLS cert. Vault presents <leaf> + <root>, so the ROOT is
# the LAST certificate of the chain returned by the endpoint.
#
# Usage:
#   ./10-vault-eso/scripts/fetch-vault-ca.sh                    # use VAULT_SERVER from local.env
#   ./10-vault-eso/scripts/fetch-vault-ca.sh https://vault.example:8200
#   ./10-vault-eso/scripts/fetch-vault-ca.sh --print            # do not edit local.env, just print
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE"
while [ ! -f "$ROOT/scripts/render.sh" ] && [ "$ROOT" != "/" ]; do ROOT="$(dirname "$ROOT")"; done
ENV_FILE="${ENV_FILE:-$ROOT/local.env}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; } || true

PRINT_ONLY=0
ARG=""
for a in "$@"; do case "$a" in --print) PRINT_ONLY=1;; -*) echo "unknown flag: $a" >&2; exit 2;; *) ARG="$a";; esac; done

SRV="${ARG:-${VAULT_SERVER:-}}"
[ -n "$SRV" ] || { echo "no VAULT_SERVER (set it in local.env or pass a URL)" >&2; exit 1; }
HOST="$(printf '%s' "$SRV" | sed -E 's#^https?://##; s#[/:].*$##')"
PORT="$(printf '%s' "$SRV" | sed -nE 's#^https?://[^:/]+:([0-9]+).*#\1#p')"; PORT="${PORT:-443}"
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }

echo "fetching chain from ${HOST}:${PORT} ..." >&2
CHAIN="$(openssl s_client -showcerts -connect "${HOST}:${PORT}" -servername "$HOST" </dev/null 2>/dev/null || true)"
[ -n "$CHAIN" ] || { echo "could not connect / no certs (network? DNS? port?)" >&2; exit 1; }

# last certificate in the chain = the root (self-signed) that signed the leaf
ROOT_PEM="$(printf '%s\n' "$CHAIN" | awk '
  /-----BEGIN CERTIFICATE-----/ {buf=""; on=1}
  on {buf=buf $0 "\n"}
  /-----END CERTIFICATE-----/ {last=buf; on=0}
  END{printf "%s", last}')"
[ -n "$ROOT_PEM" ] || { echo "no certificate found in the chain" >&2; exit 1; }

SUBJECT="$(printf '%s\n' "$ROOT_PEM" | openssl x509 -noout -subject 2>/dev/null || echo '?')"
ISSUER="$(printf '%s\n' "$ROOT_PEM" | openssl x509 -noout -issuer 2>/dev/null || echo '?')"
B64="$(printf '%s' "$ROOT_PEM" | base64 | tr -d '\n')"

echo "root subject: $SUBJECT" >&2
echo "root issuer : $ISSUER" >&2

if [ "$PRINT_ONLY" = 1 ] || [ ! -f "$ENV_FILE" ]; then
  printf 'VAULT_CA_BUNDLE=%s\n' "$B64"
  [ "$PRINT_ONLY" = 1 ] || echo "(no $ENV_FILE — printed above)" >&2
  exit 0
fi

if grep -q '^VAULT_CA_BUNDLE=' "$ENV_FILE"; then
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  awk -v b64="$B64" '
    /^VAULT_CA_BUNDLE=/ {print "VAULT_CA_BUNDLE=" b64; next} {print}
  ' "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
  echo "updated VAULT_CA_BUNDLE in $ENV_FILE" >&2
else
  printf '\nVAULT_CA_BUNDLE=%s\n' "$B64" >> "$ENV_FILE"
  echo "appended VAULT_CA_BUNDLE to $ENV_FILE" >&2
fi
