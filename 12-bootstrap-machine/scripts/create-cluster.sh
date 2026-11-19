#!/usr/bin/env bash
# Traditional NKP install: one `nkp create cluster nutanix --self-managed`.
# Flags match nkp-deployer install/management-cluster/traditional/nkp-installer.sh
# (build_cluster_command). This is the other path from scripts/install-nkp.sh,
# which creates a kind bootstrap and applies the Helm chart.
set -Eeuo pipefail
trap 'echo "ERROR: [create-cluster] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

LAB="$(cd "$(dirname "$0")/.." && pwd)"
cd "${LAB}"

if [ -f "${LAB}/create-cluster.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${LAB}/create-cluster.env"
  set +a
else
  echo "missing ${LAB}/create-cluster.env" >&2
  echo "  cp create-cluster.env.example create-cluster.env" >&2
  exit 1
fi

: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${NUTANIX_USER:?NUTANIX_USER is required}"
: "${NUTANIX_PASSWORD:?NUTANIX_PASSWORD is required}"
: "${NUTANIX_ENDPOINT:?NUTANIX_ENDPOINT is required}"
: "${NUTANIX_PRISM_ELEMENT_CLUSTER_NAME:?NUTANIX_PRISM_ELEMENT_CLUSTER_NAME is required}"
: "${NUTANIX_SUBNET_NAME:?NUTANIX_SUBNET_NAME is required}"
: "${NUTANIX_STORAGE_CONTAINER_NAME:?NUTANIX_STORAGE_CONTAINER_NAME is required}"
: "${CONTROL_PLANE_ENDPOINT_IP:?CONTROL_PLANE_ENDPOINT_IP is required}"
: "${LB_IP_RANGE:?LB_IP_RANGE is required}"
: "${NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME:?NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME is required}"
: "${SSH_PUBKEY:?SSH_PUBKEY is required}"

NUTANIX_PORT="${NUTANIX_PORT:-9440}"
PODS_CIDR="${PODS_CIDR:-10.95.0.0/16}"
SERVICES_CIDR="${SERVICES_CIDR:-10.96.0.0/12}"
CONTROL_PLANE_REPLICAS="${CONTROL_PLANE_REPLICAS:-3}"
CONTROL_PLANE_DISKSIZE="${CONTROL_PLANE_DISKSIZE:-80}"
CONTROL_PLANE_MEMORY="${CONTROL_PLANE_MEMORY:-16}"
CONTROL_PLANE_VCPUS="${CONTROL_PLANE_VCPUS:-4}"
WORKER_REPLICAS="${WORKER_REPLICAS:-2}"
WORKER_DISKSIZE="${WORKER_DISKSIZE:-80}"
WORKER_MEMORY="${WORKER_MEMORY:-32}"
WORKER_VCPUS="${WORKER_VCPUS:-8}"
SSH_USERNAME="${SSH_USERNAME:-konvoy}"
NTP_SERVERS="${NTP_SERVERS:-pool.ntp.org,time.google.com}"
DRY_RUN="${DRY_RUN:-false}"

command -v nkp >/dev/null 2>&1 || { echo "nkp CLI is not installed" >&2; exit 1; }
[ -f "${SSH_PUBKEY}" ] || { echo "SSH public key file not found: ${SSH_PUBKEY}" >&2; exit 1; }
if ! docker info >/dev/null 2>&1; then
  echo "docker is installed but this user cannot talk to the daemon." >&2
  echo "Log out and back in so the docker group applies, then re-run." >&2
  exit 1
fi

export NUTANIX_USER NUTANIX_PASSWORD

args=(
  create cluster nutanix
  --cluster-name "${CLUSTER_NAME}"
  --endpoint "https://${NUTANIX_ENDPOINT}:${NUTANIX_PORT}"
  --insecure
  --kubernetes-pod-network-cidr "${PODS_CIDR}"
  --kubernetes-service-cidr "${SERVICES_CIDR}"
  --kubernetes-service-load-balancer-ip-range "${LB_IP_RANGE}"
  --control-plane-endpoint-ip "${CONTROL_PLANE_ENDPOINT_IP}"
  --control-plane-vm-image "${NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME}"
  --control-plane-prism-element-cluster "${NUTANIX_PRISM_ELEMENT_CLUSTER_NAME}"
  --control-plane-subnets "${NUTANIX_SUBNET_NAME}"
  --control-plane-replicas "${CONTROL_PLANE_REPLICAS}"
  --control-plane-disk-size "${CONTROL_PLANE_DISKSIZE}"
  --control-plane-memory "${CONTROL_PLANE_MEMORY}"
  --control-plane-vcpus "${CONTROL_PLANE_VCPUS}"
  --worker-vm-image "${NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME}"
  --worker-prism-element-cluster "${NUTANIX_PRISM_ELEMENT_CLUSTER_NAME}"
  --worker-subnets "${NUTANIX_SUBNET_NAME}"
  --worker-replicas "${WORKER_REPLICAS}"
  --worker-disk-size "${WORKER_DISKSIZE}"
  --worker-memory "${WORKER_MEMORY}"
  --worker-vcpus "${WORKER_VCPUS}"
  --csi-storage-container "${NUTANIX_STORAGE_CONTAINER_NAME}"
  --ssh-public-key-file "${SSH_PUBKEY}"
  --ssh-username "${SSH_USERNAME}"
  --ntp-servers "${NTP_SERVERS}"
  --self-managed
  --verbose 10
)
if [ -n "${CLUSTER_HOSTNAME:-}" ]; then
  args+=(--cluster-hostname "${CLUSTER_HOSTNAME}")
fi
if [ -n "${BOOTSTRAP_CLUSTER_IMAGE_PATH:-}" ]; then
  args+=(--bootstrap-cluster-image "${BOOTSTRAP_CLUSTER_IMAGE_PATH}")
fi
if [ "${DRY_RUN}" = "true" ]; then
  args+=(--dry-run -o yaml)
fi

echo "=== [create-cluster] nkp ${args[*]} ==="
nkp "${args[@]}"
