#!/usr/bin/env bash
# Copy the latest lab 12 files onto a bastion that has no internet.
# Run this on a machine that does. Your env, values.local.yaml, create-cluster.env,
# kubeconfigs, registry/ and airgap/ on the bastion are not touched.
#
#   bash update-bastion.sh ubuntu@<bastion-ip> [--dry-run] [--rollback]
#
# Downloads the SHA256-verified nkp-labs-update.tar.gz from the public offline-bundle
# release (falling back to GitHub main codeload if the release is unavailable), backs up
# the previous scripts on the bastion, preserves +x on both *.sh and *.py, refreshes
# /usr/local/lib/nkp-bootstrap/ when passwordless sudo is available, and records the version.
set -Eeuo pipefail
trap 'echo "ERROR: [update-bastion] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

TARGET=""
DRY_RUN="false"
ROLLBACK="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN="true"; shift ;;
    --rollback) ROLLBACK="true"; shift ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2; exit 2 ;;
    *)
      [ -z "${TARGET}" ] || { echo "unexpected argument: $1" >&2; exit 2; }
      TARGET="$1"; shift ;;
  esac
done
[ -n "${TARGET}" ] || { echo "usage: update-bastion.sh ubuntu@<bastion-ip> [--dry-run] [--rollback]" >&2; exit 1; }

REPO="${NKP_LABS_GH_REPO:-fernandoquinino-ntx/nkp-labs}"
RELEASE_BASE="https://github.com/${REPO}/releases/download/offline-bundle"
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

if [ "${DRY_RUN}" = "true" ]; then
  echo "=== dry-run: would copy $(find "${SRC}" -type f | wc -l) files (commit=${COMMIT}, source=${SOURCE_LABEL}) to ${TARGET}:~/nkp-workspace ==="
  find "${SRC}/scripts" -maxdepth 1 -type f | sort | sed "s|${SRC}/|  |"
  exit 0
fi

echo "=== copying lab files to ${TARGET}:~/nkp-workspace (commit=${COMMIT}) ==="
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
    printf 'commit=%s\nupdated_at=%s\nmode=bastion-push\nsource=%s\n' '${COMMIT}' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" '${SOURCE_LABEL}' > ~/nkp-workspace/.nkp-labs-version
    if sudo -n true 2>/dev/null && [ -d /usr/local/lib/nkp-bootstrap ]; then
      for f in bootstrap-host.sh expand-root-disk.sh update-workspace.sh; do
        [ -f ~/nkp-workspace/scripts/\${f} ] && sudo install -m 0755 ~/nkp-workspace/scripts/\${f} /usr/local/lib/nkp-bootstrap/\${f}
      done
    fi
    echo \"updated \$(find ~/nkp-workspace/scripts -maxdepth 1 \( -name '*.sh' -o -name '*.py' \) | wc -l) executable scripts (commit=${COMMIT})\"
  "

echo "=== done. On the bastion the new files are in ~/nkp-workspace ==="
echo "Install with nkp create cluster (not the Helm chart):"
echo "  cp create-cluster.env.example create-cluster.env"
echo "  # set the Prism password, storage container, and registry password"
echo "  ./scripts/create-cluster.sh"
