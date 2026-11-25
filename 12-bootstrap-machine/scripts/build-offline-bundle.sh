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
nkp_file="$(basename "${nkp_tar}")"
if [ -n "${NKP_SHA256}" ] && [ -f "${nkp_tar}" ]; then
  nkp_url=""
  for url in ${URLS}; do
    if [ "$(basename "${url}")" = "${nkp_file}" ]; then nkp_url="${url}"; break; fi
  done
  ok=false
  for attempt in 1 2 3; do
    got="$(sha256 "${nkp_tar}" | awk '{print $1}')"
    if [ "${got}" = "${NKP_SHA256}" ]; then
      ok=true
      break
    fi
    echo "  nkp sha256 mismatch on attempt ${attempt} (got ${got}), retrying clean download..." >&2
    rm -f "${CACHE}/${nkp_file}" "${CACHE}/${nkp_file}.part" "${nkp_tar}"
    if [ -n "${nkp_url}" ] && [ "${attempt}" -lt 3 ]; then
      curl -fL --http1.1 --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 30 -sS \
        -o "${CACHE}/${nkp_file}.part" "${nkp_url}"
      mv -f "${CACHE}/${nkp_file}.part" "${CACHE}/${nkp_file}"
      cp -f "${CACHE}/${nkp_file}" "${nkp_tar}"
    fi
  done
  if [ "${ok}" != "true" ]; then
    echo "nkp archive checksum mismatch after retries. Removed from the cache." >&2
    exit 1
  fi
  echo "  nkp sha256 ok"
fi

# kubectl, helm, flux, k9s, yq and nkp are not .deb packages. They ship as binaries.
# A static binary has no shared libraries. A dynamic one must be refused here, because
# the .deb set was not built to satisfy it.
python3 - "${STAGE}/downloads" <<'PY'
import os, struct, sys
root = sys.argv[1]

def needed(blob):
    if blob[:4] != b"\x7fELF" or blob[4] != 2 or blob[5] != 1:
        return None
    e_phoff = struct.unpack_from("<Q", blob, 32)[0]
    e_phentsize, e_phnum = struct.unpack_from("<HH", blob, 54)
    dyn = None
    loads = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", blob, off)[0]
        p_offset, p_vaddr, _, p_filesz, _, _ = struct.unpack_from("<QQQQQQ", blob, off + 8)
        if p_type == 1:
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == 2:
            dyn = blob[p_offset:p_offset + p_filesz]
    if dyn is None:
        return []
    ents = []
    for i in range(0, len(dyn), 16):
        tag, val = struct.unpack_from("<QQ", dyn, i)
        ents.append((tag, val))
        if tag == 0:
            break
    strtab = next(v for t, v in ents if t == 5)
    so = next(fo + (strtab - va) for va, fo, sz in loads if va <= strtab < va + sz)
    libs = []
    for t, v in ents:
        if t == 1:
            end = blob.index(b"\0", so + v)
            libs.append(blob[so + v:end].decode())
    return libs

bad = False
for dirpath, _, files in os.walk(root):
    for name in files:
        path = os.path.join(dirpath, name)
        blob = open(path, "rb").read(4)
        if blob != b"\x7fELF":
            inner = path
            if name.endswith(".tar.gz"):
                import tarfile
                tf = tarfile.open(path)
                for m in tf.getmembers():
                    if not m.isfile():
                        continue
                    data = tf.extractfile(m).read()
                    if data[:4] != b"\x7fELF":
                        continue
                    libs = needed(data)
                    print(f"  {name}:{m.name} libs={libs or 'static'}")
                    bad = bad or bool(libs)
            continue
        libs = needed(open(path, "rb").read())
        print(f"  {name} libs={libs or 'static'}")
        bad = bad or bool(libs)
if bad:
    sys.exit("a bundled installer needs a shared library. Add the providing Ubuntu package to APT_PACKAGES and rebuild.")
PY

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
