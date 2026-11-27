#!/usr/bin/env bash
# Build an offline OCI image bundle tarball compatible with `nkp push bundle` containing
# the NKP Pulse images (mesosphere/kubectl, mesosphere/nkp-pulse-management,
# mesosphere/nkp-pulse-workspace) plus any optional --extra-image entries.
#
# Run on a machine with internet access (or in CI):
#   ./scripts/build-pulse-bundle.sh [OUT_DIR]
#   ./scripts/build-pulse-bundle.sh --out-dir ./dist --extra-image docker.io/org/img:tag
#
# Output:
#   OUT_DIR/nkp-pulse-image-bundle-<NKP_VERSION>.tar
#   OUT_DIR/nkp-pulse-image-bundle-<NKP_VERSION>.tar.sha256
set -Eeuo pipefail
trap 'echo "ERROR: [build-pulse-bundle] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

LAB="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${LAB}/dist"
IMAGES_FILE="${LAB}/pulse-images.yaml"
PLATFORM="${PLATFORM:-linux/amd64}"
EXTRA_IMAGES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir)      OUT="${2:?missing path after --out-dir}"; shift 2 ;;
    --images-file)  IMAGES_FILE="${2:?missing path after --images-file}"; shift 2 ;;
    --platform)     PLATFORM="${2:?missing platform after --platform}"; shift 2 ;;
    --extra-image)  EXTRA_IMAGES+=("${2:?missing image ref after --extra-image}"); shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    *)
      OUT="$1"; shift ;;
  esac
done

[ -f "${IMAGES_FILE}" ] || { echo "images file not found: ${IMAGES_FILE}" >&2; exit 1; }

# Load NKP_VERSION from versions.env (single source of truth)
NKP_VERSION="${NKP_VERSION:-v2.19.1}"
if [ -f "${LAB}/versions.env" ]; then
  v="$(awk -F= '$1 == "NKP_VERSION" {gsub(/"/, "", $2); print $2; exit}' "${LAB}/versions.env")"
  [ -n "${v}" ] && NKP_VERSION="${v}"
fi

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"
  else shasum -a 256 "$1"; fi
}

# Locate `nkp` (preferred) or `mindthegap`; auto-download nkp CLI into a temp dir if neither is present
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

BUNDLE_TOOL=""
if [ -n "${NKP_BIN:-}" ] && [ -x "${NKP_BIN}" ]; then
  BUNDLE_TOOL="${NKP_BIN}"
elif command -v nkp >/dev/null 2>&1; then
  BUNDLE_TOOL="$(command -v nkp)"
elif command -v mindthegap >/dev/null 2>&1; then
  BUNDLE_TOOL="$(command -v mindthegap)"
else
  arch="amd64"
  case "$(uname -m)" in
    arm64|aarch64) arch="arm64" ;;
  esac
  os_name="$(uname -s | tr '[:upper:]' '[:lower:]')"
  nkp_url="https://downloads.d2iq.com/dkp/${NKP_VERSION}/nkp_${NKP_VERSION}_${os_name}_${arch}.tar.gz"
  echo "=== nkp CLI not found on PATH; downloading ${nkp_url} ==="
  curl -fsSL --retry 5 --retry-all-errors "${nkp_url}" | tar -xz -C "${WORK}" nkp
  chmod +x "${WORK}/nkp"
  BUNDLE_TOOL="${WORK}/nkp"
fi

# Merge any --extra-image flags into a working copy of images.yaml
MERGED_FILE="${WORK}/images.yaml"
cp "${IMAGES_FILE}" "${MERGED_FILE}"
if [ "${#EXTRA_IMAGES[@]}" -gt 0 ]; then
  python3 - "${MERGED_FILE}" "${EXTRA_IMAGES[@]}" <<'PY'
import sys, yaml
path, extras = sys.argv[1], sys.argv[2:]
data = yaml.safe_load(open(path, encoding="utf-8")) or {}
for ref in extras:
    if ":" not in ref.rsplit("/", 1)[-1]:
        sys.exit(f"extra image must include a tag: {ref}")
    repo_part, tag = ref.rsplit(":", 1)
    parts = repo_part.split("/", 1)
    if len(parts) == 2 and ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        reg, repo = parts[0], parts[1]
    else:
        reg, repo = "docker.io", repo_part
    imgs = data.setdefault(reg, {}).setdefault("images", {})
    tags = imgs.setdefault(repo, [])
    if tag not in tags:
        tags.append(tag)
with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(data, fh, sort_keys=False)
PY
fi

mkdir -p "${OUT}"
BUNDLE_NAME="nkp-pulse-image-bundle-${NKP_VERSION}.tar"
BUNDLE_PATH="${OUT}/${BUNDLE_NAME}"

echo "=== building ${BUNDLE_PATH} (platform=${PLATFORM}) using $(basename "${BUNDLE_TOOL}") ==="
cat "${MERGED_FILE}"

"${BUNDLE_TOOL}" create bundle \
  --images-file "${MERGED_FILE}" \
  --platform "${PLATFORM}" \
  --output-file "${BUNDLE_PATH}" \
  --overwrite

(
  cd "${OUT}"
  sha256_file "${BUNDLE_NAME}" > "${BUNDLE_NAME}.sha256"
)

echo "=== built ${BUNDLE_PATH} ($(du -h "${BUNDLE_PATH}" | awk '{print $1}')) ==="
echo "    sha256: $(awk '{print $1}' "${BUNDLE_PATH}.sha256")"
echo ""
echo "Next steps on the air-gapped bastion:"
echo "  scp ${BUNDLE_PATH} ${BUNDLE_PATH}.sha256 ubuntu@<bastion-ip>:~/nkp-workspace/airgap/"
echo "  ssh ubuntu@<bastion-ip> 'cd ~/nkp-workspace && ./scripts/fix-pulse-airgap.sh --bundle airgap/${BUNDLE_NAME}'"
