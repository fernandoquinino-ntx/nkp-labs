#!/usr/bin/env bash
# Write cloud-init-offline.yaml from cloud-init.yaml with NKP_MODE=offline, so both stay
# the same file apart from the mode. CI runs this with --check and fails when the
# committed copy is out of date.
#
#   ./scripts/make-offline-cloud-init.sh           regenerate cloud-init-offline.yaml
#   ./scripts/make-offline-cloud-init.sh --check   exit 1 if it is out of date
set -Eeuo pipefail

LAB="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${LAB}/cloud-init.yaml"
DEST="${LAB}/cloud-init-offline.yaml"
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

grep -q '^      NKP_MODE=online$' "${SRC}" || { echo "NKP_MODE=online not found in ${SRC}" >&2; exit 1; }
{
  echo '#cloud-config'
  echo '# OFFLINE cloud-init (generated from cloud-init.yaml by scripts/make-offline-cloud-init.sh,'
  echo '# do not edit). Nothing here uses the internet or git. After boot the VM waits for the'
  echo '# offline bundle, checks it, and installs only from it:'
  echo '#   client$ ./scripts/get-offline-bundle.sh'
  echo '#   client$ ./scripts/push-offline-bundle.sh dist/nkp-bootstrap-offline-*.tar.gz ubuntu@<vm-ip> --follow'
  echo '# Ubuntu 24.04 amd64 only. Progress: nkp-bootstrap-status. Log: /var/log/nkp-bootstrap.log'
  echo '# Details: steps/07-offline-bootstrap.md'
  # Drop every online-only block (downloads, git settings, the air-gap download service).
  tail -n +2 "${SRC}" \
    | sed -e '/# >>> online-only/,/# <<< online-only/d' \
          -e 's/^      NKP_MODE=online$/      NKP_MODE=offline/' \
          -e '/scripts\/make-offline-cloud-init.sh by/d' -e '/cloud-init-offline.yaml by scripts/d'
} > "${TMP}"

# The offline file must not reach the network.
if grep -nE 'https?://|curl |wget |git clone|raw\.githubusercontent' "${TMP}"; then
  echo "cloud-init-offline.yaml would still download something (lines above)" >&2
  exit 1
fi
grep -q '^      NKP_MODE=offline$' "${TMP}" || { echo "NKP_MODE=offline missing" >&2; exit 1; }

if [ "${1:-}" = "--check" ]; then
  if ! cmp -s "${TMP}" "${DEST}"; then
    echo "cloud-init-offline.yaml is out of date. Run ./scripts/make-offline-cloud-init.sh and commit it." >&2
    exit 1
  fi
  echo "cloud-init-offline.yaml is up to date"
  exit 0
fi
cp "${TMP}" "${DEST}"
echo "wrote ${DEST}"
