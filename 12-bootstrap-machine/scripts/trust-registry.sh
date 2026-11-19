#!/usr/bin/env bash
# Put the bastion registry CA into the NKP cluster the way CAREN expects it:
# an Opaque Secret with username, password, and ca.crt (not a docker-registry Secret).
# Source: nkp-deployer/configure/registry/runbooks/01-registry-not-set.md
set -Eeuo pipefail
trap 'echo "ERROR: [trust-registry] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

LAB="$(cd "$(dirname "$0")/.." && pwd)"
STATE="${REGISTRY_STATE_DIR:-${LAB}/registry}"
NS="${CLUSTER_NAMESPACE:-kommander}"
SECRET="${REGISTRY_SECRET_NAME:-nkp-registry-credentials}"
CREDS="${STATE}/credentials.env"

[ -f "${STATE}/certs/ca.crt" ] || { echo "missing ${STATE}/certs/ca.crt — run scripts/setup-local-registry.sh" >&2; exit 1; }
[ -f "${CREDS}" ] || { echo "missing ${CREDS}" >&2; exit 1; }
# shellcheck disable=SC1090
. "${CREDS}"

command -v kubectl >/dev/null 2>&1 || { echo "kubectl is not installed" >&2; exit 1; }
kubectl get ns "${NS}" >/dev/null 2>&1 || { echo "namespace ${NS} not found. Set KUBECONFIG to the management cluster." >&2; exit 1; }

kubectl -n "${NS}" create secret generic "${SECRET}" \
  --from-literal=username="${REGISTRY_USER}" \
  --from-literal=password="${REGISTRY_PASSWORD}" \
  --from-file=ca.crt="${STATE}/certs/ca.crt" \
  --dry-run=client -o yaml | kubectl -n "${NS}" apply -f -

echo "=== secret ${NS}/${SECRET} has username, password, and ca.crt ==="
echo "Point clusterConfig at it (rolls nodes). Example:"
cat <<EOF
spec:
  topology:
    variables:
      - name: clusterConfig
        value:
          globalImageRegistryMirror:
            url: https://${REGISTRY_HOST}:${REGISTRY_PORT}
            credentials:
              secretRef:
                name: ${SECRET}
          imageRegistries:
            - url: https://${REGISTRY_HOST}:${REGISTRY_PORT}
              credentials:
                secretRef:
                  name: ${SECRET}
EOF
echo "CAREN writes that CA into /etc/containerd/certs.d on each node."
echo "Push a bundle with the CA trusted on this host:"
echo "  nkp push bundle --bundle <bundle.tar> --to-registry oci://${REGISTRY_HOST}:${REGISTRY_PORT} --to-registry-username ${REGISTRY_USER} --to-registry-password <from ${CREDS}>"
