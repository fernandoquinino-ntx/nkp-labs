#!/usr/bin/env bash
# Pull the latest nkp-labs from git (or an offline bundle / update tarball) and refresh
# /home/ubuntu/nkp-workspace. Installed on the bastion as `nkp-update`.
#
#   nkp-update                          refresh the workspace and bootstrap scripts
#   nkp-update --rerun                  also run nkp-bootstrap.service again (finished steps skipped)
#   nkp-update --status                 show installed version/commit and backward-compatibility status
#   nkp-update --check                  exit 0 if up-to-date, 10 if compatible update, 20 if incompatible
#   nkp-update --from-tarball <file>    update air-gapped bastion from nkp-labs-update.tar.gz
#   nkp-update --rollback               restore the pre-update snapshot without touching local env/data
#   nkp-update --force                  override the 3-previous-versions backward-compatibility guard
#
# Backward-compatibility guarantee: automatic updates are allowed only when the installed
# version is up to 3 previous minor versions behind the target (same MAJOR).
# Nothing of yours is deleted: env, values.local.yaml, create-cluster.env, kubeconfigs,
# registry/ and airgap/ are not in git.
set -Eeuo pipefail

# The whole script is one function so bash has read all of it before this run
# replaces the file on disk.
main() {
  local action="update"
  local rerun="false"
  local force="false"
  local tarball=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --rerun)        rerun="true"; shift ;;
      --force)        force="true"; shift ;;
      --status)       action="status"; shift ;;
      --check)        action="check"; shift ;;
      --rollback)     action="rollback"; shift ;;
      --from-tarball) tarball="${2:?--from-tarball needs a path to nkp-labs-update.tar.gz}"; shift 2 ;;
      -h|--help)
        sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
        return 0
        ;;
      *)
        echo "unknown option: $1 (try --help)" >&2
        return 2
        ;;
    esac
  done

  if [ "${action}" != "status" ] && [ "${action}" != "check" ] && [ "${NKP_NO_SUDO:-false}" != "true" ] && [ "$(id -u)" -ne 0 ]; then
    local args=()
    [ "${action}" = "rollback" ] && args+=(--rollback)
    [ "${rerun}" = "true" ] && args+=(--rerun)
    [ "${force}" = "true" ] && args+=(--force)
    [ -n "${tarball}" ] && args+=(--from-tarball "${tarball}")
    exec sudo -E bash "$0" "${args[@]}"
  fi

  export PATH="$PATH:/usr/sbin:/sbin:/usr/bin:/bin"
  [ -f /etc/default/nkp-bootstrap ] && . /etc/default/nkp-bootstrap
  local repo="${NKP_LABS_REPO:-https://github.com/fernandoquinino-ntx/nkp-labs.git}"
  local gh_repo="${NKP_LABS_GH_REPO:-fernandoquinino-ntx/nkp-labs}"
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
  local compat_window="${LAB_COMPAT_WINDOW:-3}"
  local i f src new_commit="" src_label="" new_lab_ver=""

  say() {
    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [nkp-update] $*"
    echo "${line}"
    echo "${line}" >> "${log}" 2>/dev/null || true
  }

  read_env_key() {
    local file="$1" key="$2" val=""
    [ -f "${file}" ] || return 0
    val="$(awk -F= -v k="${key}" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "${file}" 2>/dev/null || true)"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    printf '%s' "${val}"
  }

  read_installed_commit() {
    read_env_key "${ver_file}" "commit"
  }

  read_installed_lab_version() {
    local v=""
    v="$(read_env_key "${ver_file}" "lab_version")"
    if [ -z "${v}" ]; then
      v="$(read_env_key "${ws}/versions.env" "LAB_VERSION")"
    fi
    if [ -z "${v}" ]; then
      # Legacy pre-versioning inference so existing bastions report accurately
      if [ -f "${ws}/scripts/create-prism-role.ps1" ]; then
        v="1.2.0"
      elif [ -f "${ws}/scripts/setup-local-registry.sh" ]; then
        v="1.1.0"
      elif [ -d "${ws}/scripts" ]; then
        v="1.0.0"
      else
        v="none"
      fi
    fi
    printf '%s' "${v}"
  }

  # Evaluate 3-previous-versions backward compatibility between installed and target.
  # Returns: 0 = compatible (or fresh install), 20 = NOT backward-compatible.
  check_version_compat() {
    local cur="$1" tgt="$2" win="${3:-3}" allow_force="${4:-false}"
    if [ -z "${tgt}" ] || [ "${tgt}" = "unknown" ]; then
      say "Compatibility check: installed=${cur} -> target=unknown (version metadata absent; proceeding)."
      return 0
    fi
    if [ -z "${cur}" ] || [ "${cur}" = "none" ]; then
      say "Compatibility check: fresh workspace -> target ${tgt} — BACKWARD-COMPATIBLE (initial install)."
      return 0
    fi
    if ! [[ "${cur}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! [[ "${tgt}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      say "Compatibility check: installed=${cur} -> target=${tgt} — NOT BACKWARD-COMPATIBLE (invalid version format)."
      if [ "${allow_force}" = "true" ]; then
        say "WARNING: --force specified; overriding compatibility check."
        return 0
      fi
      return 20
    fi

    local c_maj c_min c_pat t_maj t_min t_pat
    IFS='.' read -r c_maj c_min c_pat <<< "${cur}"
    IFS='.' read -r t_maj t_min t_pat <<< "${tgt}"
    : "${c_pat}" "${t_pat}"

    if [ "${c_maj}" -ne "${t_maj}" ]; then
      say "Compatibility check: installed ${cur} -> target ${tgt} (major version mismatch) — NOT BACKWARD-COMPATIBLE."
      if [ "${allow_force}" = "true" ]; then
        say "WARNING: --force specified; overriding backward-compatibility guard."
        return 0
      fi
      say "Automatic update blocked: major version jump is not backward-compatible. Pass --force to override."
      return 20
    fi

    local delta=$(( t_min - c_min ))
    if [ "${delta}" -lt 0 ]; then
      say "Compatibility check: installed ${cur} -> target ${tgt} (downgrade by $((-delta)) minor version(s)) — NOT BACKWARD-COMPATIBLE."
      if [ "${allow_force}" = "true" ]; then
        say "WARNING: --force specified; overriding downgrade guard."
        return 0
      fi
      say "Automatic update blocked: downgrade detected. Use --rollback or pass --force to override."
      return 20
    fi

    if [ "${delta}" -le "${win}" ]; then
      say "Compatibility check: installed ${cur} -> target ${tgt} (${delta} version(s) behind, max allowed: ${win}) — BACKWARD-COMPATIBLE."
      return 0
    fi

    say "Compatibility check: installed ${cur} -> target ${tgt} (${delta} version(s) behind, max allowed: ${win}) — NOT BACKWARD-COMPATIBLE."
    if [ "${allow_force}" = "true" ]; then
      say "WARNING: --force specified; overriding 3-version backward-compatibility guard."
      return 0
    fi
    say "Automatic update blocked: only up to ${win} previous versions are guaranteed backward-compatible. Upgrade via an intermediate version or pass --force to override."
    return 20
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

  get_available_lab_version() {
    if [ "${mode}" = "offline" ]; then
      read_env_key "${NKP_OFFLINE_DIR:-/opt/nkp-offline}/labs/12-bootstrap-machine/versions.env" "LAB_VERSION"
    else
      if command -v curl >/dev/null 2>&1; then
        local mf_url="${NKP_LABS_RELEASE_BASE:-https://github.com/${gh_repo}/releases/download/offline-bundle}/MANIFEST.json"
        curl -fsSL --connect-timeout 5 --max-time 10 "${mf_url}" 2>/dev/null \
          | grep -o '"lab_version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | cut -d'"' -f4 || true
      fi
    fi
  }

  if [ "${action}" = "status" ] || [ "${action}" = "check" ]; then
    local cur avail cur_ver avail_ver
    cur="$(read_installed_commit)"
    avail="$(get_available_commit)"
    cur_ver="$(read_installed_lab_version)"
    avail_ver="$(get_available_lab_version)"
    if [ "${action}" = "status" ]; then
      echo "workspace     : ${ws}"
      echo "mode          : ${mode}"
      echo "lab_version   : ${cur_ver}"
      echo "compat_window : up to ${compat_window} previous versions"
      if [ -f "${ver_file}" ]; then
        sed 's/^/  /' "${ver_file}"
      else
        echo "  installed   : legacy/unrecorded (run nkp-update to record version)"
      fi
      echo "available     : ${avail:-unavailable} (lab_version=${avail_ver:-unknown})"
      if [ -n "${avail_ver}" ]; then
        check_version_compat "${cur_ver}" "${avail_ver}" "${compat_window}" "false" || true
      fi
      echo "rollback      : $([ -d "${backup_dir}/prev" ] && echo "available (${backup_dir}/prev)" || echo "none")"
      return 0
    fi
    if [ -n "${avail_ver}" ]; then
      if ! check_version_compat "${cur_ver}" "${avail_ver}" "${compat_window}" "${force}"; then
        return 20
      fi
    fi
    if [ -z "${avail}" ]; then
      echo "could not determine latest available revision (mode=${mode})" >&2
      return 1
    fi
    if [ -n "${cur}" ] && [[ "${avail}" == "${cur}"* || "${cur}" == "${avail}"* ]]; then
      echo "up-to-date (version=${cur_ver}, commit=${cur})"
      return 0
    fi
    echo "update available: installed=${cur_ver} (${cur:-unknown}) -> available=${avail_ver:-unknown} (${avail})"
    return 10
  fi

  if [ "${action}" = "rollback" ]; then
    [ -d "${backup_dir}/prev" ] || { say "no rollback snapshot found in ${backup_dir}/prev"; return 1; }
    mkdir -p "${ws}"
    cp -a "${backup_dir}/prev/." "${ws}/"
    [ "${NKP_NO_SUDO:-false}" = "true" ] || chown -R "${owner}:${owner}" "${ws}"
    chmod 0755 "${ws}"/scripts/*.sh 2>/dev/null || true
    chmod 0755 "${ws}"/scripts/*.py 2>/dev/null || true
    if [ "${NKP_NO_SUDO:-false}" != "true" ]; then
      mkdir -p "${lib}"
      for f in bootstrap-host.sh expand-root-disk.sh update-workspace.sh; do
        if [ -f "${ws}/scripts/${f}" ]; then
          install -m 0755 "${ws}/scripts/${f}" "${lib}/${f}.new"
          mv -f "${lib}/${f}.new" "${lib}/${f}"
        fi
      done
    fi
    say "rolled back ${ws} from ${backup_dir}/prev (version=$(read_installed_lab_version), commit=$(read_installed_commit))"
    return 0
  fi

  local cur_lab_ver tmp_extract=""
  cur_lab_ver="$(read_installed_lab_version)"

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
    say "staging workspace update from tarball ${tarball}"
  elif [ "${mode}" = "offline" ]; then
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
    src="${labs}.new/12-bootstrap-machine"
    new_commit="$(git -C "${labs}.new" rev-parse --short=12 HEAD 2>/dev/null || echo "unknown")"
    src_label="${repo}@${ref}"
  fi

  # Determine target version and enforce 3-previous-versions backward compatibility BEFORE modifying workspace
  new_lab_ver="$(read_env_key "${src}/versions.env" "LAB_VERSION")"
  local tgt_win
  tgt_win="$(read_env_key "${src}/versions.env" "LAB_COMPAT_WINDOW")"
  [ -n "${tgt_win}" ] && compat_window="${tgt_win}"
  if ! check_version_compat "${cur_lab_ver}" "${new_lab_ver:-unknown}" "${compat_window}" "${force}"; then
    [ -n "${tmp_extract}" ] && rm -rf "${tmp_extract}"
    [ -d "${labs}.new" ] && rm -rf "${labs}.new"
    return 20
  fi

  if [ -z "${tarball}" ] && [ "${mode}" != "offline" ] && [ -d "${labs}.new" ]; then
    rm -rf "${labs}"
    mv "${labs}.new" "${labs}"
    src="${labs}/12-bootstrap-machine"
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

  mkdir -p "${ws}"
  cp -a "${src}/." "${ws}/"
  [ "${NKP_NO_SUDO:-false}" = "true" ] || chown -R "${owner}:${owner}" "${ws}"
  chmod 0755 "${ws}"/scripts/*.sh 2>/dev/null || true
  chmod 0755 "${ws}"/scripts/*.py 2>/dev/null || true

  cat > "${ver_file}" <<EOF
lab_version=${new_lab_ver:-unknown}
commit=${new_commit}
updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mode=${mode}
source=${src_label}
EOF
  [ "${NKP_NO_SUDO:-false}" = "true" ] || chown "${owner}:${owner}" "${ver_file}"

  # Same files the cloud-init loader fetches. A rename keeps a running copy intact.
  if [ "${NKP_NO_SUDO:-false}" != "true" ]; then
    mkdir -p "${lib}"
    for f in bootstrap-host.sh expand-root-disk.sh update-workspace.sh; do
      if [ -f "${src}/scripts/${f}" ]; then
        install -m 0755 "${src}/scripts/${f}" "${lib}/${f}.new"
        mv -f "${lib}/${f}.new" "${lib}/${f}"
      fi
    done
    ln -sf "${lib}/update-workspace.sh" "${bin}/nkp-update"
  fi

  [ -n "${tmp_extract}" ] && rm -rf "${tmp_extract}"

  if [ -z "${tarball}" ] && [ "${mode}" != "offline" ]; then
    say "workspace ${ws} now at version=${new_lab_ver:-unknown} ($(git -C "${labs}" log -1 --format='%h %cd %s' --date=format:'%Y-%m-%d %H:%M'))"
  else
    say "workspace ${ws} updated (version=${new_lab_ver:-unknown}, commit=${new_commit})"
  fi

  if [ "${rerun}" = "true" ]; then
    rm -f "${state}/complete"
    systemctl reset-failed nkp-bootstrap.service 2>/dev/null || true
    systemctl start --no-block nkp-bootstrap.service
    say "nkp-bootstrap.service started. Follow it: journalctl -u nkp-bootstrap -f"
  fi
}

main "$@"
