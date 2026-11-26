#!/bin/bash
# Run by nkp-bootstrap.service. Every step is skipped once its .done marker exists,
# so a re-run after a network failure or a VM restart continues where it stopped.
#
# Online (NKP_MODE=online): the cloud-init loader downloads the latest copy of this file
# from nkp-labs before every run, and every file below comes from the internet.
# Offline (NKP_MODE=offline): the loader unpacks the bundle from build-offline-bundle.sh
# into NKP_OFFLINE_DIR and the same files come from there. No internet is used.
#
#   bootstrap-host.sh --print-config   versions, packages, and URLs (read by build-offline-bundle.sh)
set -Eeuo pipefail
export PATH="$PATH:/usr/sbin:/sbin:/usr/bin:/bin"
export HOME="${HOME:-/root}"
[ -f /etc/default/nkp-bootstrap ] && . /etc/default/nkp-bootstrap
_VERSIONS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/versions.env"
if [ -f "${_VERSIONS_FILE}" ]; then
  # Load defaults from versions.env without overriding explicit env or /etc/default/nkp-bootstrap
  while IFS='=' read -r _k _v; do
    case "${_k}" in ''|\#*) continue ;; esac
    _v="${_v#\"}"; _v="${_v%\"}"
    if [ -z "${!_k:-}" ]; then export "${_k}=${_v}"; fi
  done < "${_VERSIONS_FILE}"
fi

NKP_VERSION="${NKP_VERSION:-v2.19.1}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.36.2}"
HELM_VERSION="${HELM_VERSION:-v3.22.1}"
FLUX_VERSION="${FLUX_VERSION:-v2.10.0}"
K9S_VERSION="${K9S_VERSION:-v0.51.0}"
YQ_VERSION="${YQ_VERSION:-v4.47.1}"
NKP_BASE_URL="${NKP_DOWNLOAD_BASE_URL:-https://downloads.d2iq.com/dkp}"
APT_PACKAGES="ca-certificates curl gnupg jq tar unzip wget git rsync openssh-server cloud-guest-utils gdisk lvm2 e2fsprogs xfsprogs parted conntrack ebtables iptables socat sshpass make python3 util-linux"
DOCKER_PACKAGES="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
DNF_PACKAGES="ca-certificates curl gnupg2 jq tar unzip wget git rsync openssh-server cloud-utils-growpart gdisk lvm2 e2fsprogs xfsprogs parted conntrack ebtables iptables socat sshpass make python3 util-linux"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2}"

if [ "${1:-}" = "--print-config" ]; then
  arch="${NKP_ARCH:-amd64}"
else
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 3 ;;
  esac
fi
URL_KUBECTL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"
URL_HELM="https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz"
URL_FLUX="https://github.com/fluxcd/flux2/releases/download/${FLUX_VERSION}/flux_${FLUX_VERSION#v}_linux_${arch}.tar.gz"
URL_K9S="https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${arch}.tar.gz"
URL_YQ="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}"
URL_NKP="${NKP_DOWNLOAD_URL:-${NKP_BASE_URL}/${NKP_VERSION}/nkp_${NKP_VERSION}_linux_${arch}.tar.gz}"
if [ -z "${NKP_SHA256:-}" ] && [ "${NKP_VERSION}" = "v2.19.1" ] && [ "${arch}" = "amd64" ]; then
  NKP_SHA256=3d311ecb1848eadfd9e749f1ed4b451f0f16b63679fd537d62763051b396f770
fi

if [ "${1:-}" = "--print-config" ]; then
  for v in NKP_VERSION KUBECTL_VERSION HELM_VERSION FLUX_VERSION K9S_VERSION YQ_VERSION NKP_SHA256 \
      APT_PACKAGES DOCKER_PACKAGES REGISTRY_IMAGE; do
    printf "%s='%s'\n" "${v}" "${!v:-}"
  done
  printf "URLS='%s'\n" "${URL_KUBECTL} ${URL_HELM} ${URL_FLUX} ${URL_K9S} ${URL_YQ} ${URL_NKP}"
  exit 0
fi

LOG="${NKP_LOG:-/var/log/nkp-bootstrap.log}"
STATE="${NKP_STATE_DIR:-/var/lib/nkp-bootstrap}"
BIN="${NKP_BIN_DIR:-/usr/local/bin}"
WS="${NKP_WORKSPACE:-/home/ubuntu/nkp-workspace}"
LIB="${NKP_LIB_DIR:-/usr/local/lib/nkp-bootstrap}"
NKP_USER="${NKP_USER:-ubuntu}"
OFF=""
if [ "${NKP_MODE:-online}" = "offline" ]; then
  OFF="${NKP_OFFLINE_DIR:-/opt/nkp-offline}"
  export NKP_OFFLINE_DIR="${OFF}"
fi
mkdir -p "${STATE}"
touch "${LOG}"
chmod 0644 "${LOG}"
exec > >(tee -a "${LOG}") 2>&1
if command -v flock >/dev/null 2>&1; then
  exec 9>"${STATE}/.lock"
  flock -n 9 || { echo "another nkp bootstrap run holds ${STATE}/.lock"; exit 0; }
fi
attempt=$(( $(cat "${STATE}/attempts" 2>/dev/null || echo 0) + 1 ))
echo "${attempt}" > "${STATE}/attempts"
echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) nkp bootstrap start pid=$$ attempt=${attempt} mode=${NKP_MODE:-online} ====="
trap 'rc=$?; echo "===== FAILED line ${LINENO} exit ${rc} cmd=${BASH_COMMAND} at $(date -u +%Y-%m-%dT%H:%M:%SZ). systemd retries in 60s. ====="; exit ${rc}' ERR
set -x
RETRY_MAX="${RETRY_MAX:-8}"
RETRY_DELAY="${RETRY_DELAY:-10}"
NET_WAIT_SECONDS="${NET_WAIT_SECONDS:-1800}"

if [ -n "${OFF}" ]; then
  [ -f "${OFF}/SHA256SUMS" ] || { echo "offline bundle not found in ${OFF}" >&2; exit 1; }
  cat "${OFF}/MANIFEST.txt" || true
fi

retry() {
  local n=0 delay="${RETRY_DELAY}"
  until "$@"; do
    n=$((n + 1))
    if [ "${n}" -ge "${RETRY_MAX}" ]; then
      echo "retry: giving up after ${n} tries: $*"
      return 1
    fi
    echo "retry ${n}/${RETRY_MAX} in ${delay}s: $*"
    sleep "${delay}"
    delay=$((delay * 2)); [ "${delay}" -le 300 ] || delay=300
  done
}
fetch() {
  rm -f "$2.part"
  retry curl -fsSL --connect-timeout 20 --max-time 1800 -o "$2.part" "$1"
  mv -f "$2.part" "$2"
}
# Offline, the bundle holds each download under downloads/<basename of the URL>.
get_file() {
  if [ -n "${OFF}" ]; then
    cp -f "${OFF}/downloads/$(basename "$1")" "$2"
  else
    fetch "$1" "$2"
  fi
}
stage() {
  local name="$1"; shift
  if [ -f "${STATE}/${name}.done" ]; then
    echo "----- skip ${name} (done)"
    return 0
  fi
  echo "----- $(date -u +%Y-%m-%dT%H:%M:%SZ) stage ${name}"
  "$@"
  date -u +%Y-%m-%dT%H:%M:%SZ > "${STATE}/${name}.done"
  echo "----- stage ${name} done"
}

wait_cloud_init() {
  if command -v cloud-init >/dev/null 2>&1; then
    timeout 900 cloud-init status --wait >/dev/null 2>&1 || true
  fi
}
net_up() {
  local url
  for url in https://downloads.d2iq.com https://github.com https://dl.k8s.io; do
    curl -sS -o /dev/null --connect-timeout 10 --max-time 20 "${url}" && return 0
  done
  return 1
}
wait_network() {
  local waited=0
  until net_up; do
    if [ "${waited}" -ge "${NET_WAIT_SECONDS}" ]; then
      echo "no internet after ${waited}s (DNS, proxy, or gateway). Exiting so systemd retries."
      return 1
    fi
    echo "waiting for internet (${waited}s)"
    sleep 15
    waited=$((waited + 15))
  done
}
apt_get() {
  retry apt-get -o Acquire::Retries=5 -o DPkg::Lock::Timeout=600 "$@"
}
# apt with only the bundle's local repository as a source.
offline_apt() {
  mkdir -p "${OFF}/apt/sources.list.d"
  echo "deb [trusted=yes] file:${OFF}/debs ./" > "${OFF}/apt/offline.list"
  apt-get -o Dir::Etc::SourceList="${OFF}/apt/offline.list" \
    -o Dir::Etc::SourceParts="${OFF}/apt/sources.list.d" \
    -o APT::Get::List-Cleanup=0 -o DPkg::Lock::Timeout=600 "$@"
}
install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a || true
    if [ -n "${OFF}" ]; then
      [ -f "${OFF}/debs/Packages" ] || { echo "the offline bundle has no debs/Packages. Rebuild it with Docker." >&2; return 3; }
      offline_apt update
      # shellcheck disable=SC2086
      offline_apt install -y --no-install-recommends ${APT_PACKAGES}
    else
      apt_get update
      apt_get install -y -f
      # shellcheck disable=SC2086
      apt_get install -y ${APT_PACKAGES}
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if [ -n "${OFF}" ]; then
      echo "the offline bundle carries Ubuntu 24.04 packages only" >&2
      return 3
    fi
    # shellcheck disable=SC2086
    retry dnf install -y --setopt=retries=10 ${DNF_PACKAGES}
  else
    echo "no apt-get or dnf" >&2
    return 3
  fi
}
install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if [ -n "${OFF}" ]; then
      offline_apt update
      # shellcheck disable=SC2086
      offline_apt install -y --no-install-recommends ${DOCKER_PACKAGES}
    elif command -v apt-get >/dev/null 2>&1; then
      . /etc/os-release
      install -m 0755 -d /etc/apt/keyrings
      fetch https://download.docker.com/linux/ubuntu/gpg /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
      apt_get update
      # shellcheck disable=SC2086
      apt_get install -y ${DOCKER_PACKAGES}
    else
      fetch https://download.docker.com/linux/centos/docker-ce.repo /etc/yum.repos.d/docker-ce.repo
      # shellcheck disable=SC2086
      retry dnf install -y --setopt=retries=10 ${DOCKER_PACKAGES}
    fi
  fi
  if command -v apt-get >/dev/null 2>&1; then
    systemctl enable --now ssh
  else
    systemctl enable --now sshd
  fi
  systemctl enable --now docker
  usermod -aG docker "${NKP_USER}" || true
}
install_kubectl() {
  get_file "${URL_KUBECTL}" /tmp/kubectl
  install -m 0755 /tmp/kubectl "${BIN}/kubectl"
  rm -f /tmp/kubectl
  "${BIN}/kubectl" version --client
}
install_helm() {
  get_file "${URL_HELM}" /tmp/helm.tar.gz
  tar -xzf /tmp/helm.tar.gz -C /tmp "linux-${arch}/helm"
  install -m 0755 "/tmp/linux-${arch}/helm" "${BIN}/helm"
  rm -rf /tmp/helm.tar.gz "/tmp/linux-${arch}"
  "${BIN}/helm" version
}
install_flux() {
  get_file "${URL_FLUX}" /tmp/flux.tar.gz
  tar -xzf /tmp/flux.tar.gz -C /tmp flux
  install -m 0755 /tmp/flux "${BIN}/flux"
  rm -f /tmp/flux /tmp/flux.tar.gz
  "${BIN}/flux" version --client || "${BIN}/flux" --version
}
install_k9s() {
  get_file "${URL_K9S}" /tmp/k9s.tar.gz
  tar -xzf /tmp/k9s.tar.gz -C /tmp k9s
  install -m 0755 /tmp/k9s "${BIN}/k9s"
  rm -f /tmp/k9s /tmp/k9s.tar.gz
  "${BIN}/k9s" version
}
install_yq() {
  get_file "${URL_YQ}" /tmp/yq
  install -m 0755 /tmp/yq "${BIN}/yq"
  rm -f /tmp/yq
  "${BIN}/yq" --version
}
install_nkp() {
  local tmp bin
  echo "nkp from ${URL_NKP}"
  get_file "${URL_NKP}" /tmp/nkp.tar.gz
  if [ -n "${NKP_SHA256:-}" ]; then
    if [ "$(sha256sum /tmp/nkp.tar.gz | awk '{print $1}')" != "${NKP_SHA256}" ]; then
      rm -f /tmp/nkp.tar.gz
      echo "nkp archive checksum mismatch. Removed it so the next run gets it again." >&2
      return 1
    fi
  fi
  tmp="$(mktemp -d)"
  tar -xzf /tmp/nkp.tar.gz -C "${tmp}"
  bin="$(find "${tmp}" -type f -name nkp | head -n1)"
  [ -n "${bin}" ] || { echo "nkp binary not found in archive" >&2; return 1; }
  install -m 0755 "${bin}" "${BIN}/nkp"
  rm -rf "${tmp}" /tmp/nkp.tar.gz
  "${BIN}/nkp" version || true
}
sync_workspace() {
  # Every run, not a stage: the workspace always gets the latest lab (git, or the bundle).
  if bash "${LIB}/update-workspace.sh"; then
    return 0
  fi
  if [ -d "${WS}/scripts" ]; then
    echo "WARN could not refresh ${WS}. Keeping the copy already there."
    return 0
  fi
  return 1
}
registry_image() {
  # setup-local-registry.sh needs this image after the host loses internet.
  if [ -n "${OFF}" ]; then
    docker load -i "${OFF}/images/registry-2.tar"
  else
    retry docker pull "${REGISTRY_IMAGE}"
  fi
}

wait_cloud_init
[ -n "${OFF}" ] || wait_network
stage packages install_packages
# Not a stage: it is idempotent and picks up a disk grown in Prism after the first boot.
bash "${LIB}/expand-root-disk.sh" || echo "WARN disk expansion failed. Check the lines above. The next run tries again."
stage docker install_docker
stage kubectl install_kubectl
stage helm install_helm
stage flux install_flux
stage k9s install_k9s
stage yq install_yq
stage nkp install_nkp
sync_workspace
stage registry-image registry_image

echo "=== bootstrap toolchain ==="
docker --version
"${BIN}/kubectl" version --client
"${BIN}/helm" version
"${BIN}/k9s" version || true
"${BIN}/yq" --version
"${BIN}/nkp" version || true
echo "workspace: ${WS}"
date -u +%Y-%m-%dT%H:%M:%SZ > "${STATE}/complete"

if [ -n "${OFF}" ]; then
  echo "offline mode: copy the air-gapped bundle with push-offline-bundle.sh --airgap <file>"
elif [ "${NKP_SKIP_AIRGAP:-false}" != "true" ]; then
  echo "===== starting nkp-airgap-download.service (resumes after restarts) ====="
  systemctl enable nkp-airgap-download.service
  systemctl start --no-block nkp-airgap-download.service
else
  echo "NKP_SKIP_AIRGAP=true — bundle not downloaded"
fi
set +x
echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) nkp bootstrap done ====="
echo "log: ${LOG}"
