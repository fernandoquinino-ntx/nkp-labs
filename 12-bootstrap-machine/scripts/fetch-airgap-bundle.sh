#!/usr/bin/env bash
# Download the NKP 2.19.1 air-gapped bundle while this host still has a path to the internet.
# The file is about 33 GiB. Re-run the same command at any time: it resumes from the last byte,
# and a finished, size-checked file leaves <file>.complete so later runs exit at once.
# Cloud-init starts this through nkp-airgap-download.service, which restarts it after a
# failure or a VM restart. Output is also appended to /var/log/nkp-bootstrap.log when writable.
#
# Exit 0 done, 1 retryable (network, short file), 3 needs you (disk too small, bad checksum).
set -Eeuo pipefail

LAB="$(cd "$(dirname "$0")/.." && pwd)"
URL="${AIRGAP_URL:-https://downloads.d2iq.com/dkp/v2.19.1/nkp-air-gapped-bundle_v2.19.1_linux_amd64.tar.gz}"
DEST="${AIRGAP_DIR:-${LAB}/airgap}"
FILE="${DEST}/$(basename "${URL}")"
DONE="${FILE}.complete"
# Room left on the disk after the bundle lands.
MARGIN="${AIRGAP_FREE_MARGIN_BYTES:-5368709120}"
MAX_ATTEMPTS="${AIRGAP_MAX_ATTEMPTS:-30}"
RETRY_DELAY="${AIRGAP_RETRY_DELAY:-30}"
PROGRESS_SECONDS="${AIRGAP_PROGRESS_SECONDS:-60}"
LOG="${NKP_LOG:-/var/log/nkp-bootstrap.log}"

log() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [airgap] $*"
  echo "${line}"
  if [ -w "${LOG}" ] || { [ ! -e "${LOG}" ] && [ -w "$(dirname "${LOG}")" ]; }; then
    echo "${line}" >> "${LOG}" 2>/dev/null || true
  fi
}
size_of() {
  if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi
}
remote_size() {
  curl -fsSIL --connect-timeout 20 --max-time 120 --retry 5 --retry-all-errors --retry-delay 10 "${URL}" \
    | tr -d '\r' | awk 'tolower($1) == "content-length:" {n = $2} END {if (n != "") print n}'
}

trap 'rc=$?; log "FAILED line ${LINENO} exit ${rc} cmd=${BASH_COMMAND}"; exit ${rc}' ERR

if [ "${1:-}" = "--print" ]; then
  echo "${URL}"
  exit 0
fi

mkdir -p "${DEST}"
if command -v flock >/dev/null 2>&1; then
  exec 9>"${DEST}/.download.lock"
  if ! flock -n 9; then
    log "another download already holds ${DEST}/.download.lock"
    exit 0
  fi
fi

if [ -f "${DONE}" ] && [ "$(size_of "${FILE}")" = "$(cat "${DONE}")" ]; then
  log "already complete: ${FILE} ($(cat "${DONE}") bytes)"
  exit 0
fi
rm -f "${DONE}"

log "url=${URL}"
log "file=${FILE}"
expected="${AIRGAP_SIZE:-}"
if [ -z "${expected}" ]; then
  expected="$(remote_size || true)"
fi
case "${expected}" in
  ''|*[!0-9]*)
    log "could not read the bundle size from ${URL} (no internet, DNS, or proxy). Retry later."
    exit 1
    ;;
esac
have="$(size_of "${FILE}")"
log "expected_bytes=${expected} have_bytes=${have}"
if [ "${have}" -gt "${expected}" ]; then
  log "local file is larger than the remote one. Starting over."
  rm -f "${FILE}"
  have=0
fi

if [ "${have}" -lt "${expected}" ]; then
  df -h "${DEST}" | while read -r row; do log "df ${row}"; done
  free_bytes="$(df -Pk "${DEST}" | awk 'NR==2 {printf "%.0f", $4 * 1024}')"
  need=$((expected - have + MARGIN))
  log "free_bytes=${free_bytes} need_bytes=${need}"
  case "${free_bytes}" in
    ''|*[!0-9]*)
      log "could not read free space. Refusing to download."
      exit 3
      ;;
  esac
  if [ "${free_bytes}" -lt "${need}" ]; then
    log "not enough free space for the air-gapped bundle. Grow the Prism disk (about 200 GiB), run sudo /usr/local/sbin/expand-root-disk.sh, then re-run."
    exit 3
  fi

  ( while sleep "${PROGRESS_SECONDS}"; do log "progress bytes=$(size_of "${FILE}")/${expected}"; done ) &
  watcher=$!
  trap 'kill "${watcher}" 2>/dev/null || true' EXIT

  attempt=0
  delay="${RETRY_DELAY}"
  while [ "$(size_of "${FILE}")" -lt "${expected}" ]; do
    attempt=$((attempt + 1))
    log "download attempt ${attempt}/${MAX_ATTEMPTS} from byte $(size_of "${FILE}")"
    # No curl --retry: with -C - each attempt here restarts from the bytes already on disk.
    # speed-limit/speed-time drops a stalled connection instead of hanging for hours.
    if curl -fL -sS --connect-timeout 30 --speed-limit 10240 --speed-time 300 \
        -C - -o "${FILE}" "${URL}"; then
      break
    else
      rc=$?
    fi
    log "curl exit ${rc} at byte $(size_of "${FILE}")"
    if [ "${attempt}" -ge "${MAX_ATTEMPTS}" ]; then
      log "giving up after ${attempt} attempts. The partial file stays. Re-run to resume."
      exit 1
    fi
    sleep "${delay}"
    delay=$((delay * 2))
    [ "${delay}" -le 600 ] || delay=600
  done
fi

got="$(size_of "${FILE}")"
if [ "${got}" != "${expected}" ]; then
  log "size mismatch got=${got} expected=${expected}"
  [ "${got}" -le "${expected}" ] || rm -f "${FILE}"
  exit 1
fi
if [ -n "${AIRGAP_SHA256:-}" ]; then
  log "checking sha256"
  if [ "$(sha256sum "${FILE}" | awk '{print $1}')" != "${AIRGAP_SHA256}" ]; then
    log "sha256 mismatch. Removing ${FILE}. Check AIRGAP_SHA256 and re-run."
    rm -f "${FILE}"
    exit 3
  fi
fi
echo "${got}" > "${DONE}"
log "download done bytes=${got}"
ls -lh "${FILE}"
log "extract when you are ready: tar -xzf ${FILE} -C ${DEST}"
