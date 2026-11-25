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
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "=== downloading latest ${REPO} main ==="
curl -fL --retry 5 --retry-all-errors -o "${WORK}/src.tar.gz" \
  "https://codeload.github.com/${REPO}/tar.gz/refs/heads/main"
tar -xzf "${WORK}/src.tar.gz" -C "${WORK}"

SRC="$(echo "${WORK}"/nkp-labs-*/12-bootstrap-machine)"
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
