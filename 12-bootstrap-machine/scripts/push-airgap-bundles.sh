#!/usr/bin/env bash
# Extract the 33 GB NKP air-gapped bundle (if needed) and push every image bundle
# (konvoy + kommander) to the bastion's local TLS registry. Idempotent: skips bundles
# already pushed to the same registry unless --force is given.
#
#   ./scripts/push-airgap-bundles.sh [--force] [--force-extract] [--to-registry https://<ip>:5000]
set -Eeuo pipefail
trap 'echo "ERROR: [push-airgap-bundles] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

LAB="$(cd "$(dirname "$0")/.." && pwd)"
AIRGAP_DIR="${AIRGAP_DIR:-${LAB}/airgap}"
STATE="${REGISTRY_STATE_DIR:-${LAB}/registry}"
PUSH_URL="${REGISTRY_PUSH_URL:-}"
FORCE=false
FORCE_EXTRACT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=true ;;
    --force-extract) FORCE_EXTRACT=true ;;
    --to-registry) PUSH_URL="${2:?missing URL after --to-registry}"; shift ;;
    -h|--help)
      echo "usage: $0 [--force] [--force-extract] [--to-registry https://<bastion-ip>:5000]"
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v nkp >/dev/null 2>&1 || { echo "nkp CLI is not installed" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
if ! docker info >/dev/null 2>&1; then
  echo "docker daemon is not reachable by $(id -un). Log out and back in for the docker group." >&2
  exit 1
fi

# 1. Load local registry credentials & CA
CREDS="${STATE}/credentials.env"
CA_CERT="${STATE}/certs/ca.crt"
REG_CERT="${STATE}/certs/registry.crt"
[ -f "${CREDS}" ] || { echo "missing ${CREDS}. Run: sudo REGISTRY_IP=<bastion-ip> ./scripts/setup-local-registry.sh" >&2; exit 1; }
[ -f "${CA_CERT}" ] || { echo "missing ${CA_CERT}. Run setup-local-registry.sh first." >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "${CREDS}"
set +a

# 2. Pick a non-loopback push URL (prefer IP SAN on registry.crt so nkp push bundle inside Docker reaches it)
if [ -z "${PUSH_URL}" ] && [ -f "${REG_CERT}" ]; then
  cert_ip="$(openssl x509 -in "${REG_CERT}" -noout -text 2>/dev/null \
    | grep -oE 'IP Address:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
    | cut -d: -f2 \
    | grep -v '^127\.' | head -n 1 || true)"
  if [ -n "${cert_ip}" ]; then
    PUSH_URL="https://${cert_ip}:${REGISTRY_PORT:-5000}"
  fi
fi
if [ -z "${PUSH_URL}" ]; then
  PUSH_URL="https://${REGISTRY_HOST:-registry.nkp.local}:${REGISTRY_PORT:-5000}"
fi
PUSH_URL="${PUSH_URL%/}"
if [[ "${PUSH_URL}" == *"://127."* ]]; then
  echo "refusing loopback registry URL (${PUSH_URL}); nkp push bundle runs in a container and cannot reach 127.x." >&2
  echo "Recreate certs with your LAN IP: sudo rm -rf ${STATE}/certs && sudo REGISTRY_IP=<bastion-ip> ./scripts/setup-local-registry.sh" >&2
  exit 1
fi

echo "=== verifying registry ${PUSH_URL} ==="
http_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 \
  --cacert "${CA_CERT}" -u "${REGISTRY_USER}:${REGISTRY_PASSWORD}" \
  "${PUSH_URL}/v2/" || echo "000")"
if [ "${http_code}" != "200" ]; then
  echo "registry check failed: ${PUSH_URL}/v2/ returned HTTP ${http_code}" >&2
  echo "Check that the registry container is running and ${REG_CERT} lists this IP/host." >&2
  exit 1
fi
echo "registry ok (${PUSH_URL} -> HTTP 200)"

# 3. Extract the outer 33 GB tarball if container-images/*.tar is not there yet
find_image_bundles() {
  find "${AIRGAP_DIR}" -maxdepth 4 -type f \( -path '*/container-images/*-image-bundle-*.tar' -o -name 'nkp-pulse-image-bundle*.tar' \) 2>/dev/null | sort
}

mapfile -t bundles < <(find_image_bundles)
if [ "${#bundles[@]}" -eq 0 ] || [ "${FORCE_EXTRACT}" = "true" ]; then
  outer="${AIRGAP_TAR:-$(find "${AIRGAP_DIR}" -maxdepth 2 -type f -name 'nkp-air-gapped-bundle_*.tar.gz' 2>/dev/null | sort | tail -n 1 || true)}"
  [ -n "${outer}" ] && [ -f "${outer}" ] || {
    echo "no extracted container-images/*.tar and no nkp-air-gapped-bundle_*.tar.gz found under ${AIRGAP_DIR}" >&2
    exit 1
  }
  avail_gb="$(df -BG --output=avail "${AIRGAP_DIR}" 2>/dev/null | tail -n 1 | tr -dc '0-9' || echo 0)"
  if [ "${avail_gb}" -lt 40 ]; then
    echo "need at least 40 GiB free in ${AIRGAP_DIR} to extract ${outer} (only ${avail_gb} GiB free)" >&2
    exit 1
  fi
  echo "=== extracting ${outer} into ${AIRGAP_DIR} ==="
  tar -xzf "${outer}" -C "${AIRGAP_DIR}"
  mapfile -t bundles < <(find_image_bundles)
fi

if [ "${#bundles[@]}" -eq 0 ]; then
  echo "no *-image-bundle-*.tar files found under ${AIRGAP_DIR}" >&2
  exit 1
fi

# 4. Push each image bundle with an idempotent completion marker
MARKER_DIR="${AIRGAP_DIR}/.pushed"
mkdir -p "${MARKER_DIR}"

for tar_path in "${bundles[@]}"; do
  bname="$(basename "${tar_path}")"
  fsize="$(stat -c '%s' "${tar_path}" 2>/dev/null || stat -f '%z' "${tar_path}")"
  marker="${MARKER_DIR}/${bname}.done"
  expected="${PUSH_URL}|${fsize}"
  if [ "${FORCE}" != "true" ] && [ -f "${marker}" ] && [ "$(cat "${marker}")" = "${expected}" ]; then
    echo "=== skipping ${bname} (already pushed to ${PUSH_URL}; use --force to re-push) ==="
    continue
  fi
  echo "=== pushing ${bname} -> ${PUSH_URL} ==="
  nkp push bundle \
    --bundle "${tar_path}" \
    --to-registry "${PUSH_URL}" \
    --to-registry-username "${REGISTRY_USER}" \
    --to-registry-password "${REGISTRY_PASSWORD}" \
    --to-registry-ca-cert-file "${CA_CERT}"
  printf '%s\n' "${expected}" > "${marker}"
done

bootstrap_tar="$(find "${AIRGAP_DIR}" -maxdepth 4 -type f -name 'konvoy-bootstrap-image-*.tar' 2>/dev/null | head -n 1 || true)"
echo "=== done pushing ${#bundles[@]} image bundle(s) to ${PUSH_URL} ==="
if [ -n "${bootstrap_tar}" ]; then
  echo "Bootstrap image tar: ${bootstrap_tar}"
fi
echo "Next: ./scripts/preflight.sh && ./scripts/create-cluster.sh"
