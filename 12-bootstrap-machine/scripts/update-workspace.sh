#!/usr/bin/env bash
# Pull the latest nkp-labs from git and refresh /home/ubuntu/nkp-workspace.
# Installed on the bastion as `nkp-update`.
#
#   nkp-update            refresh the workspace and the bootstrap scripts
#   nkp-update --rerun    also run nkp-bootstrap.service again (finished steps are skipped)
#
# Nothing of yours is deleted: env, values.local.yaml, create-cluster.env, kubeconfigs,
# registry/ and airgap/ are not in git. Files that are in git are overwritten with the
# latest version, so keep your edits in the gitignored copies, not in *.example files.
set -Eeuo pipefail

# The whole script is one function so bash has read all of it before this run
# replaces the file on disk.
main() {
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo -E bash "$0" "$@"
  fi
  export PATH="$PATH:/usr/sbin:/sbin:/usr/bin:/bin"
  [ -f /etc/default/nkp-bootstrap ] && . /etc/default/nkp-bootstrap
  local repo="${NKP_LABS_REPO:-https://github.com/fernandoquinino-ntx/nkp-labs.git}"
  local ref="${NKP_LABS_REF:-main}"
  local labs="${NKP_LABS_DIR:-/opt/nkp-labs}"
  local ws="${NKP_WORKSPACE:-/home/ubuntu/nkp-workspace}"
  local lib="${NKP_LIB_DIR:-/usr/local/lib/nkp-bootstrap}"
  local bin="${NKP_BIN_DIR:-/usr/local/bin}"
  local state="${NKP_STATE_DIR:-/var/lib/nkp-bootstrap}"
  local owner="${NKP_USER:-ubuntu}"
  local log="${NKP_LOG:-/var/log/nkp-bootstrap.log}"
  local i f src

  say() {
    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [nkp-update] $*"
    echo "${line}"
    echo "${line}" >> "${log}" 2>/dev/null || true
  }

  command -v git >/dev/null 2>&1 || { say "git is not installed"; return 1; }
  say "repo=${repo} ref=${ref}"
  for i in 1 2 3 4 5; do
    rm -rf "${labs}.new"
    if git clone -q --depth 1 --branch "${ref}" "${repo}" "${labs}.new"; then
      break
    fi
    if [ "${i}" -eq 5 ]; then
      rm -rf "${labs}.new"
      say "git clone failed 5 times (no internet or GitHub down). Nothing changed."
      return 1
    fi
    say "git clone failed (try ${i}/5), retrying in $((i * 10))s"
    sleep $((i * 10))
  done
  rm -rf "${labs}"
  mv "${labs}.new" "${labs}"
  src="${labs}/12-bootstrap-machine"

  mkdir -p "${ws}"
  cp -a "${src}/." "${ws}/"
  chown -R "${owner}:${owner}" "${ws}"
  chmod 0755 "${ws}"/scripts/*.sh

  # Same files the cloud-init loader fetches. A rename keeps a running copy intact.
  mkdir -p "${lib}"
  for f in bootstrap-host.sh expand-root-disk.sh update-workspace.sh; do
    install -m 0755 "${src}/scripts/${f}" "${lib}/${f}.new"
    mv -f "${lib}/${f}.new" "${lib}/${f}"
  done
  ln -sf "${lib}/update-workspace.sh" "${bin}/nkp-update"

  say "workspace ${ws} now at $(git -C "${labs}" log -1 --format='%h %cd %s' --date=format:'%Y-%m-%d %H:%M')"

  if [ "${1:-}" = "--rerun" ]; then
    rm -f "${state}/complete"
    systemctl reset-failed nkp-bootstrap.service 2>/dev/null || true
    systemctl start --no-block nkp-bootstrap.service
    say "nkp-bootstrap.service started. Follow it: journalctl -u nkp-bootstrap -f"
  fi
}

main "$@"
