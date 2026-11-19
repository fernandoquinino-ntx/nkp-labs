#!/usr/bin/env bash
# One command on the client: download the latest offline bundle that CI built from main,
# check its sha256, and print the push command. Without gh (or without a CI build) it
# builds the bundle here instead, which needs Docker.
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

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  run="$(gh run list -R "${REPO}" --workflow offline-bundle.yml --branch main --status success --limit 1 \
    --json databaseId,headSha,createdAt -q '.[0] | "\(.databaseId) \(.headSha[0:7]) \(.createdAt)"' || true)"
  if [ -n "${run}" ]; then
    set -- ${run}
    echo "=== CI run $1, commit $2, built $3 ==="
    rm -f "${OUT}/${NAME}.tar.gz" "${OUT}/${NAME}.tar.gz.sha256"
    gh run download "$1" -R "${REPO}" -n "${NAME}" -D "${OUT}"
    (cd "${OUT}" && sha256 -c "${NAME}.tar.gz.sha256")
    ls -lh "${OUT}/${NAME}.tar.gz"
    echo "next: ${LAB}/scripts/push-offline-bundle.sh ${OUT}/${NAME}.tar.gz ubuntu@<bootstrap-ip> --follow"
    exit 0
  fi
  echo "no successful offline-bundle CI run on ${REPO} main"
else
  echo "gh is not installed or not logged in (gh auth login)"
fi
echo "=== building the bundle here instead (needs Docker) ==="
exec bash "${LAB}/scripts/build-offline-bundle.sh" "${OUT}"
