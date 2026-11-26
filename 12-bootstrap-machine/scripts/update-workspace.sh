#!/usr/bin/env bash
# Pull the latest nkp-labs from git (or an offline bundle / update tarball) and refresh
# /home/ubuntu/nkp-workspace. Installed on the bastion as `nkp-update`.
#
#   nkp-update                          refresh the workspace and bootstrap scripts
#   nkp-update --rerun                  also run nkp-bootstrap.service again (finished steps skipped)
#   nkp-update --status                 show installed commit/date and compare with source
#   nkp-update --check                  exit 0 if up-to-date, 10 if a newer revision exists
#   nkp-update --from-tarball <file>    update air-gapped bastion from nkp-labs-update.tar.gz
#   nkp-update --rollback               restore the pre-update snapshot without touching local env/data
#
# Nothing of yours is deleted: env, values.local.yaml, create-cluster.env, kubeconfigs,
# registry/ and airgap/ are not in git. Files that are in git are overwritten with the
# latest version, so keep your edits in the gitignored copies, not in *.example files.
set -Eeuo pipefail

# The whole script is one function so bash has read all of it before this run
# replaces the file on disk.
main() {
  local action="update"
  local rerun="false"
  local tarball=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --rerun)        rerun="true"; shift ;;
      --status)       action="status"; shift ;;
      --check)        action="check"; shift ;;
      --rollback)     action="rollback"; shift ;;
      --from-tarball) tarball="${2:?--from-tarball needs a path to nkp-labs-update.tar.gz}"; shift 2 ;;
      -h|--help)
        sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
        return 0
        ;;
      *)
        echo "unknown option: $1 (try --help)" >&2
        return 2
        ;;
    esac
  done

  if [ "${action}" != "status" ] && [ "${action}" != "check" ] && [ "$(id -u)" -ne 0 ]; then
    local args=()
    [ "${action}" = "rollback" ] && args+=(--rollback)
    [ "${rerun}" = "true" ] && args+=(--rerun)
    [ -n "${tarball}" ] && args+=(--from-tarball "${tarball}")
    exec sudo -E bash "$0" "${args[@]}"
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
  local backup_dir="${NKP_BACKUP_DIR:-/var/backups/nkp-workspace}"
  local owner="${NKP_USER:-ubuntu}"
  local log="${NKP_LOG:-/var/log/nkp-bootstrap.log}"
  local ver_file="${ws}/.nkp-labs-version"
  local mode="${NKP_MODE:-online}"
  local i f src new_commit="" src_label=""

  say() {
    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [nkp-update] $*"
    echo "${line}"
    echo "${line}" >> "${log}" 2>/dev/null || true
  }

  read_installed_commit() {
    if [ -f "${ver_file}" ]; then
      awk -F= '$1 == "commit" {print $2}' "${ver_file}" 2>/dev/null || true
    fi
  }

  get_available_commit() {
    if [ "${mode}" = "offline" ]; then
      local mf="${NKP_OFFLINE_DIR:-/opt/nkp-offline}/MANIFEST.txt"
      [ -f "${mf}" ] && awk -F= '$1 == "git_commit" {print $2}' "${mf}" 2>/dev/null || true
    else
      if command -v git >/dev/null 2>&1; then
        git ls-remote "${repo}" "refs/heads/${ref}" 2>/dev/null | awk '{print substr($1,1,12)}' || true
      fi
    fi
  }

  if [ "${action}" = "status" ] || [ "${action}" = "check" ]; then
    local cur avail
    cur="$(read_installed_commit)"
    avail="$(get_available_commit)"
    if [ "${action}" = "status" ]; then
      echo "workspace : ${ws}"
      echo "mode      : ${mode}"
      if [ -f "${ver_file}" ]; then
        sed 's/^/  /' "${ver_file}"
      else
        echo "  installed : unknown (run nkp-update to record version)"
      fi
      echo "available : ${avail:-unavailable}"
      echo "rollback  : $([ -d "${backup_dir}/prev" ] && echo "available (${backup_dir}/prev)" || echo "none")"
      return 0
    fi
    if [ -z "${avail}" ]; then
      echo "could not determine latest available revision (mode=${mode})" >&2
      return 1
    fi
    if [ -n "${cur}" ] && [[ "${avail}" == "${cur}"* || "${cur}" == "${avail}"* ]]; then
      echo "up-to-date (${cur})"
      return 0
    fi
    echo "update available: installed=${cur:-unknown} available=${avail}"
    return 10
  fi

  if [ "${action}" = "rollback" ]; then
    [ -d "${backup_dir}/prev" ] || { say "no rollback snapshot found in ${backup_dir}/prev"; return 1; }
    mkdir -p "${ws}"
    cp -a "${backup_dir}/prev/." "${ws}/"
    chown -R "${owner}:${owner}" "${ws}"
    chmod 0755 "${ws}"/scripts/*.sh 2>/dev/null || true
    chmod 0755 "${ws}"/scripts/*.py 2>/dev/null || true
    mkdir -p "${lib}"
    for f in bootstrap-host.sh expand-root-disk.sh update-workspace.sh; do
      if [ -f "${ws}/scripts/${f}" ]; then
        install -m 0755 "${ws}/scripts/${f}" "${lib}/${f}.new"
        mv -f "${lib}/${f}.new" "${lib}/${f}"
      fi
    done
    say "rolled back ${ws} from ${backup_dir}/prev ($(read_installed_commit))"
    return 0
  fi

  # Backup tracked workspace files (excluding secrets, env, registry, airgap, kubeconfigs)
  if [ -d "${ws}/scripts" ]; then
    mkdir -p "${backup_dir}"
    rm -rf "${backup_dir}/prev.new"
    mkdir -p "${backup_dir}/prev.new"
    tar -C "${ws}" \
      --exclude='./env' --exclude='./values.local.yaml' --exclude='./create-cluster.env' \
      --exclude='./kommander.yaml' --exclude='./registry' --exclude='./airgap' \
      --exclude='./*.kubeconfig' --exclude='./kubeconfig*' \
      -cf - . 2>/dev/null | tar -C "${backup_dir}/prev.new" -xf - 2>/dev/null || true
    rm -rf "${backup_dir}/prev"
    mv "${backup_dir}/prev.new" "${backup_dir}/prev"
  fi

  local tmp_extract=""
  if [ -n "${tarball}" ]; then
    [ -f "${tarball}" ] || { say "tarball not found: ${tarball}"; return 1; }
    if [ -f "${tarball}.sha256" ]; then
      local expected got
      expected="$(awk '{print $1}' "${tarball}.sha256")"
      got="$(sha256sum "${tarball}" | awk '{print $1}')"
      [ "${got}" = "${expected}" ] || { say "checksum mismatch for ${tarball}"; return 1; }
    fi
    tmp_extract="$(mktemp -d)"
    tar -xzf "${tarball}" -C "${tmp_extract}"
    if [ -d "${tmp_extract}/12-bootstrap-machine/scripts" ]; then
      src="${tmp_extract}/12-bootstrap-machine"
    elif [ -d "${tmp_extract}/scripts" ]; then
      src="${tmp_extract}"
    else
      rm -rf "${tmp_extract}"
      say "tarball ${tarball} does not contain scripts/"
      return 1
    fi
    new_commit="tarball:$(sha256sum "${tarball}" | awk '{print substr($1,1,12)}')"
    src_label="tarball:${tarball}"
    say "updating workspace from tarball ${tarball}"
  elif [ "${mode}" = "offline" ]; then
    # The loader unpacks each pushed bundle. Its lab snapshot is the source here.
    src="${NKP_OFFLINE_DIR:-/opt/nkp-offline}/labs/12-bootstrap-machine"
    [ -d "${src}/scripts" ] || { say "no lab in the offline bundle (${src}). Push a bundle first."; return 1; }
    new_commit="$(awk -F= '$1 == "git_commit" {print $2}' "${src}/../../MANIFEST.txt" 2>/dev/null || echo "offline")"
    src_label="offline-bundle"
    say "offline mode: workspace from the bundle (${new_commit})"
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
    new_commit="$(git -C "${labs}" rev-parse --short=12 HEAD 2>/dev/null || echo "unknown")"
    src_label="${repo}@${ref}"
  fi

  mkdir -p "${ws}"
  cp -a "${src}/." "${ws}/"
  chown -R "${owner}:${owner}" "${ws}"
  chmod 0755 "${ws}"/scripts/*.sh 2>/dev/null || true
  chmod 0755 "${ws}"/scripts/*.py 2>/dev/null || true

  cat > "${ver_file}" <<EOF
commit=${new_commit}
updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mode=${mode}
source=${src_label}
EOF
  chown "${owner}:${owner}" "${ver_file}"

  # Same files the cloud-init loader fetches. A rename keeps a running copy intact.
  mkdir -p "${lib}"
  for f in bootstrap-host.sh expand-root-disk.sh update-workspace.sh; do
    if [ -f "${src}/scripts/${f}" ]; then
      install -m 0755 "${src}/scripts/${f}" "${lib}/${f}.new"
      mv -f "${lib}/${f}.new" "${lib}/${f}"
    fi
  done
  ln -sf "${lib}/update-workspace.sh" "${bin}/nkp-update"

  [ -n "${tmp_extract}" ] && rm -rf "${tmp_extract}"

  if [ -z "${tarball}" ] && [ "${mode}" != "offline" ]; then
    say "workspace ${ws} now at $(git -C "${labs}" log -1 --format='%h %cd %s' --date=format:'%Y-%m-%d %H:%M')"
  else
    say "workspace ${ws} updated (commit=${new_commit})"
  fi

  if [ "${rerun}" = "true" ]; then
    rm -f "${state}/complete"
    systemctl reset-failed nkp-bootstrap.service 2>/dev/null || true
    systemctl start --no-block nkp-bootstrap.service
    say "nkp-bootstrap.service started. Follow it: journalctl -u nkp-bootstrap -f"
  fi
}

main "$@"
