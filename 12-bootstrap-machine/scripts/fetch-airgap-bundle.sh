#!/usr/bin/env bash
# Download the NKP 2.19.1 air-gapped bundle while this host still has a path to the internet.
# The file is about 33 GiB. Resume with the same command (curl -C -).
# Cloud-init runs this after the toolchain is installed. Output is also appended to
# /var/log/nkp-bootstrap.log when that file exists.
set -Eeuo pipefail

LAB="$(cd "$(dirname "$0")/.." && pwd)"
URL="${AIRGAP_URL:-https://downloads.d2iq.com/dkp/v2.19.1/nkp-air-gapped-bundle_v2.19.1_linux_amd64.tar.gz}"
DEST="${AIRGAP_DIR:-${LAB}/airgap}"
FILE="${DEST}/$(basename "${URL}")"
# Published size of the 2.19.1 bundle, plus 5 GiB for the filesystem.
NEED="${AIRGAP_MIN_FREE_BYTES:-41230000000}"
LOG="${NKP_LOG:-/var/log/nkp-bootstrap.log}"

log() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [airgap] $*"
  echo "${line}"
  if [ -w "${LOG}" ] || [ -w "$(dirname "${LOG}")" ]; then
    echo "${line}" >> "${LOG}" 2>/dev/null || true
  fi
}

trap 'rc=$?; log "FAILED line ${LINENO} exit ${rc} cmd=${BASH_COMMAND}"; exit ${rc}' ERR

if [ "${1:-}" = "--print" ]; then
  echo "${URL}"
  exit 0
fi

mkdir -p "${DEST}"
log "url=${URL}"
log "file=${FILE}"
df -h "${DEST}" | while read -r row; do log "df ${row}"; done
free_bytes="$(df -Pk "${DEST}" | awk 'NR==2 {print $4 * 1024}')"
log "free_bytes=${free_bytes} need_bytes=${NEED}"
case "${free_bytes}" in
  ''|*[!0-9]*)
    log "could not read free space. Refusing to download."
    exit 1
    ;;
esac
if [ "${free_bytes}" -lt "${NEED}" ]; then
  log "not enough free space for the air-gapped bundle. Grow the Prism disk (about 200 GiB) and re-run."
  exit 1
fi

log "download start"
doneflag="$(mktemp)"
(
  while [ ! -f "${doneflag}" ]; do
    if [ -f "${FILE}" ]; then
      log "progress bytes=$(wc -c < "${FILE}" | tr -d ' ')"
    fi
    sleep 60
  done
) &
watcher=$!
cleanup() { touch "${doneflag}"; wait "${watcher}" 2>/dev/null || true; rm -f "${doneflag}"; }
trap 'rc=$?; cleanup; log "FAILED line ${LINENO} exit ${rc} cmd=${BASH_COMMAND}"; exit ${rc}' ERR
curl -fL --retry 5 --retry-all-errors --retry-delay 10 -C - -sS -o "${FILE}" "${URL}"
cleanup
trap 'log "FAILED line ${LINENO} exit $? cmd=${BASH_COMMAND}"' ERR
log "download done bytes=$(wc -c < "${FILE}" | tr -d ' ')"
ls -lh "${FILE}"
log "extract when you are ready: tar -xzf ${FILE} -C ${DEST}"
