#!/usr/bin/env bash
# Copy the offline bundle from this client to the bootstrap VM and start the offline install.
#
#   ./scripts/push-offline-bundle.sh <bundle.tar.gz> <user@vm> [--airgap <nkp-air-gapped-bundle.tar.gz>] [--follow]
#
# The VM must run cloud-init.yaml with NKP_MODE=offline. Password or SSH key both work.
# One SSH connection is shared, so a password is asked once. Set SSHPASS to skip the prompt
# (needs sshpass on this client). An interrupted copy resumes when you run the same command again.
set -Eeuo pipefail
trap 'echo "ERROR: [push-offline-bundle] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ $# -ge 2 ] || usage
BUNDLE="$1"; TARGET="$2"; shift 2
AIRGAP=""; FOLLOW=false
while [ $# -gt 0 ]; do
  case "$1" in
    --airgap) AIRGAP="${2:?--airgap needs a file}"; shift 2 ;;
    --follow) FOLLOW=true; shift ;;
    *) usage ;;
  esac
done
[ -f "${BUNDLE}" ] || { echo "bundle not found: ${BUNDLE}" >&2; exit 1; }
[ -z "${AIRGAP}" ] || [ -f "${AIRGAP}" ] || { echo "air-gapped bundle not found: ${AIRGAP}" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
if [ -f "${BUNDLE}.sha256" ]; then
  echo "=== checking ${BUNDLE} against ${BUNDLE}.sha256 ==="
  [ "$(sha256 "${BUNDLE}" | awk '{print $1}')" = "$(awk '{print $1}' "${BUNDLE}.sha256")" ] \
    || { echo "checksum mismatch. Download the bundle again." >&2; exit 1; }
fi

CTL="/tmp/nkp-push-$$"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30
  -o ControlMaster=auto -o ControlPath="${CTL}" -o ControlPersist=15m)
PRE=()
if [ -n "${SSHPASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
  PRE=(sshpass -e)
fi
ssh_vm() { ${PRE[@]+"${PRE[@]}"} ssh "${SSH_OPTS[@]}" "${TARGET}" "$@"; }
cleanup() { ssh -o ControlPath="${CTL}" -O exit "${TARGET}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Remote paths are relative to the SSH user's home.
# Copy to a .part name and rename at the end, so the VM never unpacks half a file.
copy() {
  local src="$1" dest="$2" tries
  for tries in 1 2 3 4 5; do
    if command -v rsync >/dev/null 2>&1 && ssh_vm 'command -v rsync' >/dev/null 2>&1; then
      ${PRE[@]+"${PRE[@]}"} rsync --partial --inplace --progress -e "ssh ${SSH_OPTS[*]}" "${src}" "${TARGET}:${dest}.part" && break
    else
      ${PRE[@]+"${PRE[@]}"} scp "${SSH_OPTS[@]}" "${src}" "${TARGET}:${dest}.part" && break
    fi
    [ "${tries}" -lt 5 ] || { echo "copy failed 5 times" >&2; return 1; }
    echo "copy interrupted (try ${tries}/5). Resuming in 10s"
    sleep 10
  done
  ssh_vm "mv -f '${dest}.part' '${dest}'"
}

echo "=== connecting to ${TARGET} ==="
ssh_vm 'echo "connected to $(hostname) as $(id -un)"; df -h ~ | tail -1'

name="$(basename "${BUNDLE}")"
echo "=== copying ${name} ($(du -h "${BUNDLE}" | cut -f1)) ==="
# Offline bundles older than this one are removed so the loader picks this one.
ssh_vm "find ~ -maxdepth 1 -name 'nkp-bootstrap-offline-*.tar.gz' ! -name '${name}' -delete"
copy "${BUNDLE}" "${name}"

if [ -n "${AIRGAP}" ]; then
  aname="$(basename "${AIRGAP}")"
  size="$(wc -c < "${AIRGAP}" | tr -d ' ')"
  echo "=== copying ${aname} (${size} bytes) to ~/nkp-workspace/airgap ==="
  ssh_vm 'mkdir -p ~/nkp-workspace/airgap'
  copy "${AIRGAP}" "nkp-workspace/airgap/${aname}"
  ssh_vm "[ \"\$(wc -c < ~/nkp-workspace/airgap/${aname})\" = '${size}' ] && echo '${size}' > ~/nkp-workspace/airgap/${aname}.complete"
  echo "  size matches. Marked complete."
fi

echo "=== starting the offline bootstrap ==="
ssh_vm 'grep -q "^NKP_MODE=offline" /etc/default/nkp-bootstrap || echo "WARN /etc/default/nkp-bootstrap is not NKP_MODE=offline. Set it: sudo sed -i s/^NKP_MODE=.*/NKP_MODE=offline/ /etc/default/nkp-bootstrap"
  sudo rm -f /var/lib/nkp-bootstrap/complete
  sudo systemctl reset-failed nkp-bootstrap.service 2>/dev/null || true
  sudo systemctl start --no-block nkp-bootstrap.service
  echo "started. Status: nkp-bootstrap-status"'

if [ "${FOLLOW}" = true ]; then
  echo "=== following /var/log/nkp-bootstrap.log (Ctrl-C stops watching, not the install) ==="
  ${PRE[@]+"${PRE[@]}"} ssh -t "${SSH_OPTS[@]}" "${TARGET}" 'sudo tail -n 20 -f /var/log/nkp-bootstrap.log' || true
fi
