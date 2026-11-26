#!/usr/bin/env bash
# Copy the latest lab 12 files onto a bastion that has no internet.
# Run this on a machine that does. Your env, values.local.yaml, create-cluster.env,
# kubeconfigs, registry/ and airgap/ on the bastion are not touched.
#
#   bash update-bastion.sh ubuntu@<bastion-ip> [--dry-run] [--rollback] [--force]
#
# Checks the bastion's currently installed version before transferring and enforces
# the 3-previous-versions backward-compatibility policy (same MAJOR, up to 3 minor
# versions behind). Downloads the SHA256-verified nkp-labs-update.tar.gz from the
# public offline-bundle release (falling back to GitHub main codeload), backs up
# previous scripts, sets +x on *.sh and *.py, and refreshes /usr/local/lib/nkp-bootstrap/.
set -Eeuo pipefail
trap 'echo "ERROR: [update-bastion] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

TARGET=""
DRY_RUN="false"
ROLLBACK="false"
FORCE="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN="true"; shift ;;
    --rollback) ROLLBACK="true"; shift ;;
    --force)    FORCE="true"; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2; exit 2 ;;
    *)
      [ -z "${TARGET}" ] || { echo "unexpected argument: $1" >&2; exit 2; }
      TARGET="$1"; shift ;;
  esac
done
[ -n "${TARGET}" ] || { echo "usage: update-bastion.sh ubuntu@<bastion-ip> [--dry-run] [--rollback] [--force]" >&2; exit 1; }

REPO="${NKP_LABS_GH_REPO:-fernandoquinino-ntx/nkp-labs}"
RELEASE_BASE="${NKP_LABS_RELEASE_BASE:-https://github.com/${REPO}/releases/download/offline-bundle}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new)

if [ "${ROLLBACK}" = "true" ]; then
  echo "=== rolling back ${TARGET}:~/nkp-workspace from ~/.nkp-workspace-backup/prev ==="
  ssh "${SSH_OPTS[@]}" "${TARGET}" '
    set -euo pipefail
    [ -d ~/.nkp-workspace-backup/prev ] || { echo "no backup at ~/.nkp-workspace-backup/prev" >&2; exit 1; }
    cp -a ~/.nkp-workspace-backup/prev/. ~/nkp-workspace/
    chmod 0755 ~/nkp-workspace/scripts/*.sh ~/nkp-workspace/scripts/*.py 2>/dev/null || true
    echo "rolled back ~/nkp-workspace"
    [ -f ~/nkp-workspace/.nkp-labs-version ] && cat ~/nkp-workspace/.nkp-labs-version || true
  '
  exit 0
fi

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

read_env_key() {
  local file="$1" key="$2" val=""
  [ -f "${file}" ] || return 0
  val="$(awk -F= -v k="${key}" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "${file}" 2>/dev/null || true)"
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "${val}"
}

check_compat() {
  local cur="$1" tgt="$2" win="${3:-3}" allow_force="${4:-false}"
  if [ -z "${tgt}" ] || [ "${tgt}" = "unknown" ]; then
    echo "=== Compatibility check: bastion=${cur} -> target=unknown (proceeding) ==="
    return 0
  fi
  if [ -z "${cur}" ] || [ "${cur}" = "none" ]; then
    echo "=== Compatibility check: fresh bastion -> target ${tgt} -- BACKWARD-COMPATIBLE (initial install) ==="
    return 0
  fi
  if ! [[ "${cur}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! [[ "${tgt}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "=== Compatibility check: bastion ${cur} -> target ${tgt} -- NOT BACKWARD-COMPATIBLE (invalid version) ===" >&2
    [ "${allow_force}" = "true" ] && { echo "WARNING: --force specified; overriding." >&2; return 0; }
    return 20
  fi
  local c_maj c_min c_pat t_maj t_min t_pat
  IFS='.' read -r c_maj c_min c_pat <<< "${cur}"
  IFS='.' read -r t_maj t_min t_pat <<< "${tgt}"
  : "${c_pat}" "${t_pat}"
  if [ "${c_maj}" -ne "${t_maj}" ]; then
    echo "=== Compatibility check: bastion ${cur} -> target ${tgt} (major mismatch) -- NOT BACKWARD-COMPATIBLE ===" >&2
    [ "${allow_force}" = "true" ] && { echo "WARNING: --force specified; overriding." >&2; return 0; }
    echo "Automatic update blocked. Pass --force to override." >&2
    return 20
  fi
  local delta=$(( t_min - c_min ))
  if [ "${delta}" -lt 0 ]; then
    echo "=== Compatibility check: bastion ${cur} -> target ${tgt} (downgrade) -- NOT BACKWARD-COMPATIBLE ===" >&2
    [ "${allow_force}" = "true" ] && { echo "WARNING: --force specified; overriding." >&2; return 0; }
    echo "Automatic update blocked (downgrade). Use --rollback or pass --force." >&2
    return 20
  fi
  if [ "${delta}" -le "${win}" ]; then
    echo "=== Compatibility check: bastion ${cur} -> target ${tgt} (${delta} version(s) behind, max allowed: ${win}) -- BACKWARD-COMPATIBLE ==="
    return 0
  fi
  echo "=== Compatibility check: bastion ${cur} -> target ${tgt} (${delta} version(s) behind, max allowed: ${win}) -- NOT BACKWARD-COMPATIBLE ===" >&2
  if [ "${allow_force}" = "true" ]; then
    echo "WARNING: --force specified; overriding 3-version backward-compatibility guard." >&2
    return 0
  fi
  echo "Automatic update blocked: only up to ${win} previous versions are guaranteed backward-compatible. Upgrade via an intermediate version or pass --force." >&2
  return 20
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

COMMIT="main"
SOURCE_LABEL=""
if curl -fsSL --retry 4 --retry-all-errors -o "${WORK}/update.tar.gz" "${RELEASE_BASE}/nkp-labs-update.tar.gz"; then
  if curl -fsSL --retry 3 --retry-all-errors -o "${WORK}/update.tar.gz.sha256" "${RELEASE_BASE}/nkp-labs-update.tar.gz.sha256"; then
    expected="$(awk '{print $1}' "${WORK}/update.tar.gz.sha256")"
    got="$(sha256_file "${WORK}/update.tar.gz")"
    if [ "${got}" != "${expected}" ]; then
      echo "ERROR: sha256 mismatch for nkp-labs-update.tar.gz (expected ${expected}, got ${got})" >&2
      exit 1
    fi
    echo "=== downloaded nkp-labs-update.tar.gz from offline-bundle release (sha256 ok) ==="
  else
    echo "=== downloaded nkp-labs-update.tar.gz from offline-bundle release ==="
  fi
  if curl -fsSL -o "${WORK}/MANIFEST.json" "${RELEASE_BASE}/MANIFEST.json" 2>/dev/null; then
    COMMIT="$(grep -o '"git_sha"[[:space:]]*:[[:space:]]*"[^"]*"' "${WORK}/MANIFEST.json" | head -n1 | cut -d'"' -f4 || echo "release")"
  else
    COMMIT="release:$(sha256_file "${WORK}/update.tar.gz" | cut -c1-12)"
  fi
  tar -xzf "${WORK}/update.tar.gz" -C "${WORK}"
  SRC="${WORK}/12-bootstrap-machine"
  SOURCE_LABEL="release:offline-bundle"
else
  echo "=== release unavailable; downloading latest ${REPO} main ==="
  curl -fL --retry 5 --retry-all-errors -o "${WORK}/src.tar.gz" \
    "https://codeload.github.com/${REPO}/tar.gz/refs/heads/main"
  tar -xzf "${WORK}/src.tar.gz" -C "${WORK}"
  SRC="$(echo "${WORK}"/nkp-labs-*/12-bootstrap-machine)"
  SOURCE_LABEL="github:${REPO}@main"
fi
[ -d "${SRC}/scripts" ] || { echo "update archive has no scripts/" >&2; exit 1; }

TARGET_VER="$(read_env_key "${SRC}/versions.env" "LAB_VERSION")"
COMPAT_WIN="$(read_env_key "${SRC}/versions.env" "LAB_COMPAT_WINDOW")"
COMPAT_WIN="${COMPAT_WIN:-3}"

echo "=== checking currently installed version on ${TARGET} ==="
REMOTE_VER="$(ssh "${SSH_OPTS[@]}" "${TARGET}" '
  v=""
  [ -f ~/nkp-workspace/.nkp-labs-version ] && v="$(awk -F= "\$1 == \"lab_version\" {print \$2; exit}" ~/nkp-workspace/.nkp-labs-version 2>/dev/null || true)"
  if [ -z "$v" ] && [ -f ~/nkp-workspace/versions.env ]; then
    v="$(awk -F= "\$1 == \"LAB_VERSION\" {gsub(/\"/, \"\", \$2); print \$2; exit}" ~/nkp-workspace/versions.env 2>/dev/null || true)"
  fi
  if [ -z "$v" ]; then
    if [ -f ~/nkp-workspace/scripts/create-prism-role.ps1 ]; then v="1.2.0"
    elif [ -f ~/nkp-workspace/scripts/setup-local-registry.sh ]; then v="1.1.0"
    elif [ -d ~/nkp-workspace/scripts ]; then v="1.0.0"
    else v="none"; fi
  fi
  printf "%s" "$v"
' || echo "none")"

check_compat "${REMOTE_VER}" "${TARGET_VER:-unknown}" "${COMPAT_WIN}" "${FORCE}"

if [ "${DRY_RUN}" = "true" ]; then
  echo "=== dry-run: would copy $(find "${SRC}" -type f | wc -l) files (version=${TARGET_VER:-unknown}, commit=${COMMIT}, source=${SOURCE_LABEL}) to ${TARGET}:~/nkp-workspace ==="
  find "${SRC}/scripts" -maxdepth 1 -type f | sort | sed "s|${SRC}/|  |"
  exit 0
fi

echo "=== copying lab files to ${TARGET}:~/nkp-workspace (version=${TARGET_VER:-unknown}, commit=${COMMIT}) ==="
echo "    kept on the bastion: env, values.local.yaml, create-cluster.env, registry/, airgap/, *.kubeconfig"
# tar over ssh overwrites only the files in the archive. Secrets are not in it.
# shellcheck disable=SC2029
tar -C "${SRC}" -czf - \
  --exclude env --exclude values.local.yaml --exclude create-cluster.env \
  --exclude registry --exclude airgap --exclude kommander.yaml \
  --exclude '*.kubeconfig' \
  . | ssh "${SSH_OPTS[@]}" "${TARGET}" "
    set -euo pipefail
    mkdir -p ~/nkp-workspace ~/.nkp-workspace-backup
    if [ -d ~/nkp-workspace/scripts ]; then
      rm -rf ~/.nkp-workspace-backup/prev.new && mkdir -p ~/.nkp-workspace-backup/prev.new
      tar -C ~/nkp-workspace --exclude='./env' --exclude='./values.local.yaml' --exclude='./create-cluster.env' \
        --exclude='./kommander.yaml' --exclude='./registry' --exclude='./airgap' --exclude='./*.kubeconfig' \
        -cf - . 2>/dev/null | tar -C ~/.nkp-workspace-backup/prev.new -xf - 2>/dev/null || true
      rm -rf ~/.nkp-workspace-backup/prev && mv ~/.nkp-workspace-backup/prev.new ~/.nkp-workspace-backup/prev
    fi
    tar -xzf - -C ~/nkp-workspace
    chmod 0755 ~/nkp-workspace/scripts/*.sh ~/nkp-workspace/scripts/*.py 2>/dev/null || true
    printf 'lab_version=%s\ncommit=%s\nupdated_at=%s\nmode=bastion-push\nsource=%s\n' '${TARGET_VER:-unknown}' '${COMMIT}' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" '${SOURCE_LABEL}' > ~/nkp-workspace/.nkp-labs-version
    if sudo -n true 2>/dev/null && [ -d /usr/local/lib/nkp-bootstrap ]; then
      for f in bootstrap-host.sh expand-root-disk.sh update-workspace.sh; do
        [ -f ~/nkp-workspace/scripts/\${f} ] && sudo install -m 0755 ~/nkp-workspace/scripts/\${f} /usr/local/lib/nkp-bootstrap/\${f}
      done
    fi
    echo \"updated \$(find ~/nkp-workspace/scripts -maxdepth 1 \( -name '*.sh' -o -name '*.py' \) | wc -l) executable scripts (version=${TARGET_VER:-unknown}, commit=${COMMIT})\"
  "

echo "=== done. On the bastion the new files are in ~/nkp-workspace ==="
echo "Install with nkp create cluster (not the Helm chart):"
echo "  cp create-cluster.env.example create-cluster.env"
echo "  # set the Prism password, storage container, and registry password"
echo "  ./scripts/create-cluster.sh"
