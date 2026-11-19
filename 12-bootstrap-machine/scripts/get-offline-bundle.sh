#!/usr/bin/env bash
# One command on the client: download the latest offline bundle from the public GitHub
# release, check its sha256, and print the push command. No login. Without that release
# it builds the bundle here instead, which needs Docker.
#
#   ./scripts/get-offline-bundle.sh [OUT_DIR]      default OUT_DIR: ./dist
set -Eeuo pipefail
trap 'echo "ERROR: [get-offline-bundle] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

LAB="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-${LAB}/dist}"
REPO="${NKP_LABS_GH_REPO:-fernandoquinino-ntx/nkp-labs}"
eval "$(bash "${LAB}/scripts/bootstrap-host.sh" --print-config)"
NAME="nkp-bootstrap-offline-${NKP_VERSION}-noble-amd64"
mkdir -p "${OUT}"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

BASE="https://github.com/${REPO}/releases/download/offline-bundle"
FILE="${OUT}/${NAME}.tar.gz"
echo "=== ${BASE}/${NAME}.tar.gz ==="
if curl -fL --retry 8 --retry-all-errors --retry-delay 5 -C - -o "${FILE}" "${BASE}/${NAME}.tar.gz" \
    && curl -fL --retry 5 --retry-all-errors -o "${FILE}.sha256" "${BASE}/${NAME}.tar.gz.sha256"; then
  (cd "${OUT}" && sha256 -c "${NAME}.tar.gz.sha256")
  curl -fL --retry 5 --retry-all-errors -o "${OUT}/cloud-init-offline.yaml" "${BASE}/cloud-init-offline.yaml" || true
  ls -lh "${FILE}"
  echo "next: ${LAB}/scripts/push-offline-bundle.sh ${FILE} ubuntu@<bootstrap-ip> --follow"
  exit 0
fi
rm -f "${FILE}" "${FILE}.sha256"
echo "=== the public release is not there yet. Building the bundle here instead (needs Docker) ==="
exec bash "${LAB}/scripts/build-offline-bundle.sh" "${OUT}"
