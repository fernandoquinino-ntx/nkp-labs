#!/usr/bin/env bash
# Pull the latest nkp-labs from git and refresh /home/ubuntu/nkp-workspace.
# Installed on the bastion as `nkp-update`.
#
#   nkp-update            refresh the workspace and the bootstrap scripts
#   nkp-update --rerun    also run nkp-bootstrap.service again (finished steps are skipped)
#
# With NKP_MODE=offline the source is the lab inside the last pushed offline bundle
# (push a new one with push-offline-bundle.sh, which also re-runs the bootstrap).
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

  if [ "${NKP_MODE:-online}" = "offline" ]; then
    # The loader unpacks each pushed bundle. Its lab snapshot is the source here.
    src="${NKP_OFFLINE_DIR:-/opt/nkp-offline}/labs/12-bootstrap-machine"
    [ -d "${src}/scripts" ] || { say "no lab in the offline bundle (${src}). Push a bundle first."; return 1; }
    say "offline mode: workspace from the bundle ($(awk -F= '$1 == "git_commit" {print $2}' "${src}/../../MANIFEST.txt" 2>/dev/null))"
  else
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
  fi

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

  if [ "${NKP_MODE:-online}" != "offline" ]; then
    say "workspace ${ws} now at $(git -C "${labs}" log -1 --format='%h %cd %s' --date=format:'%Y-%m-%d %H:%M')"
  fi

  if [ "${1:-}" = "--rerun" ]; then
    rm -f "${state}/complete"
    systemctl reset-failed nkp-bootstrap.service 2>/dev/null || true
    systemctl start --no-block nkp-bootstrap.service
    say "nkp-bootstrap.service started. Follow it: journalctl -u nkp-bootstrap -f"
  fi
}

main "$@"
