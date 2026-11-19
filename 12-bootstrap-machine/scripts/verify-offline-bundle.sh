#!/usr/bin/env bash
# Prove an offline bundle installs with no network: run the cloud-init loader in
# NKP_MODE=offline inside an Ubuntu 24.04 container started with --network none.
# systemd and the Docker daemon do not exist in a container, so systemctl is a stand-in
# and the first run stops at `docker load`. The second run adds a docker stand-in for
# `load` only and must finish, which also checks that finished steps are skipped.
#
#   ./scripts/verify-offline-bundle.sh dist/nkp-bootstrap-offline-<version>-noble-amd64.tar.gz
set -Eeuo pipefail
trap 'echo "ERROR: [verify-offline-bundle] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

BUNDLE="$(cd "$(dirname "${1:?bundle path}")" && pwd)/$(basename "$1")"
LAB="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# The loader exactly as cloud-init writes it.
python3 - "${LAB}/cloud-init.yaml" "${TMP}/loader.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
f = [w for w in d["write_files"] if w["path"].endswith("install-nkp-bootstrap-tools.sh")][0]
open(sys.argv[2], "w").write(f["content"])
PY

docker run --rm --network none --platform linux/amd64 \
  -v "${BUNDLE}:/drop/$(basename "${BUNDLE}"):ro" -v "${TMP}/loader.sh:/loader.sh:ro" \
  ubuntu:24.04 bash -Eeuo pipefail -c '
    id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu
    cp /drop/*.tar.gz /home/ubuntu/
    printf "%s\n" NKP_MODE=offline NKP_OFFLINE_DIR=/opt/nkp-offline NKP_OFFLINE_DROP=/home/ubuntu \
      > /etc/default/nkp-bootstrap
    printf "#!/bin/sh\necho \"systemctl (stand-in) \$*\"\n" > /usr/local/sbin/systemctl
    chmod +x /usr/local/sbin/systemctl

    echo "=== run 1: no network, expected to stop at docker load ==="
    if bash /loader.sh > /tmp/run1.log 2>&1; then echo "run 1 should have stopped at docker load"; exit 1; fi
    grep -E "^\S+ \[loader\]|^----- " /tmp/run1.log
    for s in packages docker kubectl helm flux k9s yq nkp; do
      [ -f /var/lib/nkp-bootstrap/${s}.done ] || { echo "step ${s} did not finish"; tail -n 60 /tmp/run1.log; exit 1; }
    done

    printf "#!/bin/sh\nif [ \"\$1\" = load ]; then tar -tf \"\$3\" manifest.json >/dev/null && echo \"docker load (stand-in): image tar ok\"; exit \$?; fi\nexec /usr/bin/docker \"\$@\"\n" \
      > /usr/local/sbin/docker
    chmod +x /usr/local/sbin/docker
    echo "=== run 2: must finish ==="
    bash /loader.sh > /tmp/run2.log 2>&1 || { tail -n 60 /tmp/run2.log; exit 1; }
    grep -E "^----- skip|^----- .* stage|nkp bootstrap done" /tmp/run2.log
    [ -f /var/lib/nkp-bootstrap/complete ]

    echo "=== installed ==="
    /usr/bin/docker --version
    dpkg-query -W -f "\${Package} \${Version}\n" docker-ce containerd.io openssh-server lvm2 jq git rsync
    kubectl version --client
    helm version --short
    flux version --client
    k9s version --short || k9s version
    yq --version
    nkp version || true
    ls -l /home/ubuntu/nkp-workspace/scripts/install-nkp.sh /usr/local/bin/nkp-update
    echo "OFFLINE BUNDLE OK"'
