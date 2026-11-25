#!/usr/bin/env bash
# Copy the latest lab 12 files onto a bastion that has no internet.
# Run this on a machine that does. Your env, values.local.yaml, create-cluster.env,
# kubeconfigs, registry/ and airgap/ on the bastion are not touched.
#
#   curl -fsSL -o update-bastion.sh https://raw.githubusercontent.com/fernandoquinino-ntx/nkp-labs/main/12-bootstrap-machine/scripts/update-bastion.sh
#   bash update-bastion.sh ubuntu@<bastion-ip>
#
# No GitHub login. The bastion password is asked once.
set -Eeuo pipefail
trap 'echo "ERROR: [update-bastion] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

TARGET="${1:?usage: update-bastion.sh ubuntu@<bastion-ip>}"
REPO="${NKP_LABS_GH_REPO:-fernandoquinino-ntx/nkp-labs}"
BASE="https://github.com/${REPO}/releases/download/offline-bundle"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "=== downloading the lab update ==="
if ! curl -fL --retry 3 --retry-all-errors -o "${WORK}/update.tar.gz" "${BASE}/nkp-labs-update.tar.gz"; then
  # Some release assets only answer on the API until the download CDN catches up.
  asset="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/tags/offline-bundle" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(a["url"] for a in d["assets"] if a["name"]=="nkp-labs-update.tar.gz"))')"
  curl -fL -H "Accept: application/octet-stream" -o "${WORK}/update.tar.gz" "${asset}"
fi
tar -xzf "${WORK}/update.tar.gz" -C "${WORK}"

SRC="${WORK}/12-bootstrap-machine"
[ -d "${SRC}/scripts" ] || { echo "update archive has no scripts/" >&2; exit 1; }

echo "=== copying lab files to ${TARGET}:~/nkp-workspace ==="
echo "    kept on the bastion: env, values.local.yaml, create-cluster.env, registry/, airgap/, *.kubeconfig"
# tar over ssh overwrites only the files in the archive. Secrets are not in it.
# shellcheck disable=SC2029
tar -C "${SRC}" -czf - \
  --exclude env --exclude values.local.yaml --exclude create-cluster.env \
  --exclude registry --exclude airgap --exclude kommander.yaml \
  --exclude '*.kubeconfig' \
  . | ssh -o StrictHostKeyChecking=accept-new "${TARGET}" 'mkdir -p ~/nkp-workspace && tar -xzf - -C ~/nkp-workspace && chmod 0755 ~/nkp-workspace/scripts/*.sh && echo updated $(find ~/nkp-workspace/scripts -name "*.sh" | wc -l) scripts'

echo "=== done. On the bastion the new files are in ~/nkp-workspace ==="
echo "Install with nkp create cluster (not the Helm chart):"
echo "  cp create-cluster.nkp-mgmt-prodtgu01.env create-cluster.env"
echo "  # set the Prism password, storage container, and registry password"
echo "  ./scripts/create-cluster.sh"
