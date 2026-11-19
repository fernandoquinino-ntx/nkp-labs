#!/usr/bin/env bash
# Build the offline bootstrap bundle on a machine with internet and Docker (CI or a laptop).
#
#   ./scripts/build-offline-bundle.sh [OUT_DIR]     default OUT_DIR: ./dist
#
# Output: OUT_DIR/nkp-bootstrap-offline-<nkp version>-noble-amd64.tar.gz and a .sha256 file.
# Inside (top folder nkp-offline/):
#   downloads/   the same files the online bootstrap downloads (nkp, kubectl, helm, flux, k9s, yq)
#   debs/        Ubuntu 24.04 amd64 packages + Docker CE with every dependency, as an apt repository
#   images/      registry:2 saved with `docker save`
#   labs/        this lab from git (committed files only, so no env or secrets)
#   MANIFEST.txt, SHA256SUMS
# Versions and package names come from bootstrap-host.sh --print-config, so the bundle always
# matches what the online install would fetch.
#
# Downloads resume after an interruption: run the same command again.
set -Eeuo pipefail
trap 'echo "ERROR: [build-offline-bundle] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

LAB="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "${LAB}/.." && pwd)"
OUT="${1:-${LAB}/dist}"
UBUNTU_IMAGE="${UBUNTU_IMAGE:-ubuntu:24.04}"
SKIP_DOCKER="${SKIP_DOCKER:-false}"

eval "$(bash "${LAB}/scripts/bootstrap-host.sh" --print-config)"
NAME="nkp-bootstrap-offline-${NKP_VERSION}-noble-amd64"
WORK="${OUT}/.build"
STAGE="${WORK}/nkp-offline"
CACHE="${OUT}/.cache"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
if [ "${SKIP_DOCKER}" != "true" ]; then
  command -v docker >/dev/null 2>&1 || {
    echo "Docker is required for the Ubuntu packages and the registry image." >&2
    echo "No Docker here? Download the CI build instead: ./scripts/get-offline-bundle.sh" >&2
    exit 1
  }
  docker info >/dev/null 2>&1 || { echo "Docker is installed but not running" >&2; exit 1; }
fi

rm -rf "${WORK}"
mkdir -p "${STAGE}/downloads" "${STAGE}/debs" "${STAGE}/images" "${STAGE}/labs" "${CACHE}"

echo "=== [1/5] downloads (cache: ${CACHE}) ==="
for url in ${URLS}; do
  f="$(basename "${url}")"
  if [ ! -f "${CACHE}/${f}" ]; then
    echo "  ${url}"
    curl -fL --retry 8 --retry-all-errors --retry-delay 5 --connect-timeout 30 -C - -sS \
      -o "${CACHE}/${f}.part" "${url}"
    mv -f "${CACHE}/${f}.part" "${CACHE}/${f}"
  else
    echo "  cached ${f}"
  fi
  cp -f "${CACHE}/${f}" "${STAGE}/downloads/${f}"
done
nkp_tar="${STAGE}/downloads/nkp_${NKP_VERSION}_linux_amd64.tar.gz"
if [ -n "${NKP_SHA256}" ] && [ -f "${nkp_tar}" ]; then
  if [ "$(sha256 "${nkp_tar}" | awk '{print $1}')" != "${NKP_SHA256}" ]; then
    rm -f "${CACHE}/$(basename "${nkp_tar}")"
    echo "nkp archive checksum mismatch. Removed from the cache. Run again." >&2
    exit 1
  fi
  echo "  nkp sha256 ok"
fi

echo "=== [2/5] lab snapshot from git ($(git -C "${REPO_ROOT}" rev-parse --short HEAD)) ==="
git -C "${REPO_ROOT}" archive --format=tar HEAD 12-bootstrap-machine | tar -xf - -C "${STAGE}/labs"
if [ -n "$(git -C "${REPO_ROOT}" status --porcelain -- 12-bootstrap-machine)" ]; then
  echo "  WARN uncommitted changes in 12-bootstrap-machine are NOT in the bundle (git archive HEAD)"
fi

if [ "${SKIP_DOCKER}" = "true" ]; then
  echo "=== [3/5] [4/5] SKIP_DOCKER=true: no Ubuntu packages and no registry image (test bundle only) ==="
else
  echo "=== [3/5] Ubuntu 24.04 packages with dependencies (${UBUNTU_IMAGE}, linux/amd64) ==="
  docker run --rm --platform linux/amd64 \
    -e PKGS="${APT_PACKAGES} ${DOCKER_PACKAGES}" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "${STAGE}/debs:/out" "${UBUNTU_IMAGE}" bash -Eeuo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg apt-utils >/dev/null
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL --retry 5 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -qq
      # The full dependency tree, not only what this container lacks: the bundle must
      # install on a VM that has any subset of these already.
      all="$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
        --no-breaks --no-replaces --no-enhances ${PKGS} | grep "^[a-zA-Z0-9]" | sed "s/:any$//" | sort -u)"
      cd /out
      if ! apt-get download -q ${all} >/dev/null 2>/tmp/dl.err; then
        for p in ${all}; do apt-get download -q "${p}" >/dev/null 2>&1 || echo "  no candidate: ${p}"; done
      fi
      apt-ftparchive packages . > Packages
      apt-ftparchive release . > Release
      echo "  $(ls *.deb | wc -l) packages, $(du -sh . | cut -f1)"
      chown -R "${HOST_UID}:${HOST_GID}" /out'

  echo "=== [4/5] ${REGISTRY_IMAGE} image ==="
  docker pull --platform linux/amd64 "${REGISTRY_IMAGE}"
  docker save "${REGISTRY_IMAGE}" -o "${STAGE}/images/registry-2.tar"
fi

echo "=== [5/5] manifest, checksums, tarball ==="
{
  echo "name=${NAME}"
  echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "git_commit=$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
  echo "complete=$([ "${SKIP_DOCKER}" = "true" ] && echo false || echo true)"
  for v in NKP_VERSION KUBECTL_VERSION HELM_VERSION FLUX_VERSION K9S_VERSION YQ_VERSION REGISTRY_IMAGE; do
    echo "${v}=${!v}"
  done
  echo "apt_packages=${APT_PACKAGES} ${DOCKER_PACKAGES}"
  echo "debs=$(find "${STAGE}/debs" -name '*.deb' | wc -l | tr -d ' ')"
} > "${STAGE}/MANIFEST.txt"
(cd "${STAGE}" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort | while read -r f; do sha256 "${f}"; done > SHA256SUMS)
tar -czf "${OUT}/${NAME}.tar.gz.part" -C "${WORK}" nkp-offline
mv -f "${OUT}/${NAME}.tar.gz.part" "${OUT}/${NAME}.tar.gz"
(cd "${OUT}" && sha256 "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256")
rm -rf "${WORK}"
cat "${OUT}/${NAME}.tar.gz.sha256"
ls -lh "${OUT}/${NAME}.tar.gz"
echo "next: ./scripts/push-offline-bundle.sh ${OUT}/${NAME}.tar.gz ubuntu@<bootstrap-ip>"
