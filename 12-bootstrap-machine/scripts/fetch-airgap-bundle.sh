#!/usr/bin/env bash
# Download the NKP 2.19.1 air-gapped bundle while this host still has a path to the internet.
# The file is about 33 GiB. Resume with the same command (curl -C -).
set -Eeuo pipefail
trap 'echo "ERROR: [fetch-airgap-bundle] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

LAB="$(cd "$(dirname "$0")/.." && pwd)"
URL="${AIRGAP_URL:-https://downloads.d2iq.com/dkp/v2.19.1/nkp-air-gapped-bundle_v2.19.1_linux_amd64.tar.gz}"
DEST="${AIRGAP_DIR:-${LAB}/airgap}"
FILE="${DEST}/$(basename "${URL}")"

if [ "${1:-}" = "--print" ]; then
  echo "${URL}"
  exit 0
fi

mkdir -p "${DEST}"
echo "=== downloading ${URL} ==="
echo "    to ${FILE}"
curl -fL --retry 3 -C - -o "${FILE}" "${URL}"
ls -lh "${FILE}"
echo "Extract on a disk with room (the lab used ~200 GB): tar -xzf ${FILE} -C ${DEST}"
