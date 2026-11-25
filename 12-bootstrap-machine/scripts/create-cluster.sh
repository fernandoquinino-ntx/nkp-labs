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
if [ -n "${EXTRA_SANS:-}" ]; then
  args+=(--extra-sans "${EXTRA_SANS}")
fi
if [ -n "${CONTROL_PLANE_PC_CATEGORIES:-}" ]; then
  args+=(--control-plane-pc-categories "${CONTROL_PLANE_PC_CATEGORIES}")
fi
if [ -n "${WORKER_PC_CATEGORIES:-}" ]; then
  args+=(--worker-pc-categories "${WORKER_PC_CATEGORIES}")
fi
if [ "${AIRGAPPED:-false}" = "true" ]; then
  args+=(--airgapped)
fi

# Air-gap: point the cluster at the bastion registry. Leave the URL empty or CHANGE-ME to skip.
has_mirror=false
case "${REGISTRY_MIRROR_URL:-}" in
  ""|*CHANGE-ME*) ;;
  *)
    has_mirror=true
    case "${REGISTRY_MIRROR_PASSWORD:-}" in
      ""|*CHANGE-ME*) echo "set REGISTRY_MIRROR_PASSWORD from registry/credentials.env" >&2; exit 1 ;;
    esac
    args+=(
      --registry-mirror-url "${REGISTRY_MIRROR_URL}"
      --registry-mirror-username "${REGISTRY_MIRROR_USERNAME:-nkp}"
      --registry-mirror-password "${REGISTRY_MIRROR_PASSWORD}"
    )
    if [ -n "${REGISTRY_MIRROR_CACERT:-}" ]; then
      args+=(--registry-mirror-cacert "${REGISTRY_MIRROR_CACERT}")
    fi
    ;;
esac

# Validate or auto-detect local bootstrap cluster image tarball for air-gapped installs.
case "${BOOTSTRAP_CLUSTER_IMAGE_PATH:-}" in
  http://*|https://*)
    echo "BOOTSTRAP_CLUSTER_IMAGE_PATH must be a local .tar file (e.g. airgap/nkp-v2.19.1/konvoy-bootstrap-image-v2.19.1.tar), not a URL." >&2
    echo "Put the registry URL in REGISTRY_MIRROR_URL instead." >&2
    exit 1
    ;;
esac
if [ -z "${BOOTSTRAP_CLUSTER_IMAGE_PATH:-}" ] && [ "${has_mirror}" = "true" ] && [ -d "${LAB}/airgap" ]; then
  detected_bootstrap="$(find "${LAB}/airgap" -maxdepth 4 -type f -name 'konvoy-bootstrap-image-*.tar' 2>/dev/null | head -n 1 || true)"
  if [ -z "${detected_bootstrap}" ]; then
    detected_bootstrap="$(find "${LAB}/airgap" -maxdepth 4 -type f -iname '*bootstrap*.tar' 2>/dev/null | head -n 1 || true)"
  fi
  if [ -n "${detected_bootstrap}" ]; then
    BOOTSTRAP_CLUSTER_IMAGE_PATH="${detected_bootstrap}"
    echo "=== [create-cluster] auto-detected bootstrap image: ${BOOTSTRAP_CLUSTER_IMAGE_PATH} ==="
  fi
fi
if [ -n "${BOOTSTRAP_CLUSTER_IMAGE_PATH:-}" ]; then
  case "${BOOTSTRAP_CLUSTER_IMAGE_PATH}" in
    /*|./*|../*|*.tar|*.tar.gz)
      [ -f "${BOOTSTRAP_CLUSTER_IMAGE_PATH}" ] || { echo "BOOTSTRAP_CLUSTER_IMAGE_PATH file not found: ${BOOTSTRAP_CLUSTER_IMAGE_PATH}" >&2; exit 1; }
      ;;
  esac
  args+=(--bootstrap-cluster-image "${BOOTSTRAP_CLUSTER_IMAGE_PATH}")
fi

if [ "${DRY_RUN}" = "true" ]; then
  args+=(--dry-run -o yaml)
fi

# Bastion /etc/hosts: registry name -> mirror IP, and Kommander name -> ingress IP.
add_bastion_host() {
  local ip="$1" name="$2" tmp
  [ -n "${ip}" ] && [ -n "${name}" ] || return 0
  if grep -qE "^${ip}[[:space:]]+${name}([[:space:]]|$)" /etc/hosts; then
    echo "hosts already has ${ip} ${name}"
    return 0
  fi
  tmp="$(mktemp)"
  grep -vE "(^|[[:space:]])${name}([[:space:]]|$)" /etc/hosts > "${tmp}" || true
  echo "${ip} ${name}" >> "${tmp}"
  if [ "$(id -u)" -eq 0 ]; then
    cat "${tmp}" > /etc/hosts
  else
    sudo cp "${tmp}" /etc/hosts
  fi
  rm -f "${tmp}"
  echo "hosts: ${ip} ${name}"
}
reg_ip="${REGISTRY_MIRROR_URL:-}"
reg_ip="${reg_ip#*://}"
reg_ip="${reg_ip%%/*}"
reg_ip="${reg_ip%%:*}"
case "${reg_ip}" in
  ""|*[!0-9.]*) reg_ip="${REGISTRY_IP:-}" ;;
esac
add_bastion_host "${reg_ip}" "${REGISTRY_HOST:-registry.nkp.local}"
add_bastion_host "${KOMMANDER_INGRESS_IP:-}" "${CLUSTER_HOSTNAME:-}"

# Dex looks up CLUSTER_HOSTNAME while nkp create cluster is still installing
# Kommander. The hosts entry has to land as soon as CoreDNS exists, not after
# nkp returns. This watcher runs beside nkp and retries on transient API errors.
patch_coredns_once() {
  local kc="$1" corefile
  corefile="$(mktemp)"
  if ! kubectl --kubeconfig "${kc}" -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' > "${corefile}" 2>/dev/null; then
    rm -f "${corefile}"
    return 1
  fi
  if [ ! -s "${corefile}" ]; then
    rm -f "${corefile}"
    return 1
  fi
  if ! python3 - "${corefile}" "${KOMMANDER_INGRESS_IP}" "${CLUSTER_HOSTNAME}" <<'PY'
import pathlib, re, sys
path, ip, name = sys.argv[1:]
text = pathlib.Path(path).read_text()
if re.search(rf'^\s*{re.escape(ip)}\s+{re.escape(name)}(\s|$)', text, re.M):
    sys.exit(0)
# If a hosts block already exists, insert our entry at the start of it; otherwise anchor before forward or closing brace.
m_hosts = re.search(r'^([ \t]*)hosts\s*\{[^\n]*\n', text, re.M)
if m_hosts:
    indent = m_hosts.group(1) + "    "
    insert_at = m_hosts.end()
    text = text[:insert_at] + f"{indent}{ip} {name}\n" + text[insert_at:]
else:
    m_fwd = re.search(r'^([ \t]*)forward\b', text, re.M)
    if m_fwd:
        indent = m_fwd.group(1)
        block = f"{indent}hosts {{\n{indent}    {ip} {name}\n{indent}    fallthrough\n{indent}}}\n"
        text = text[:m_fwd.start()] + block + text[m_fwd.start():]
    else:
        m_end = re.search(r'^(\s*)\}\s*$', text, re.M)
        if not m_end:
            sys.exit("Corefile has no hosts, forward, or closing brace to anchor the hosts block")
        indent = m_end.group(1) + "    "
        block = f"{indent}hosts {{\n{indent}    {ip} {name}\n{indent}    fallthrough\n{indent}}}\n"
        text = text[:m_end.start()] + block + text[m_end.start():]
pathlib.Path(path).write_text(text)
PY
  then
    rm -f "${corefile}"
    return 1
  fi
  if ! (kubectl --kubeconfig "${kc}" -n kube-system create configmap coredns \
      --from-file=Corefile="${corefile}" --dry-run=client -o yaml \
      | kubectl --kubeconfig "${kc}" apply -f - >/dev/null 2>&1 \
      && kubectl --kubeconfig "${kc}" -n kube-system rollout restart deployment coredns >/dev/null 2>&1); then
    rm -f "${corefile}"
    return 1
  fi
  rm -f "${corefile}"
  return 0
}

apply_coredns_hosts() {
  local kc="" candidate
  echo "=== waiting to add CoreDNS hosts: ${KOMMANDER_INGRESS_IP} ${CLUSTER_HOSTNAME} ==="
  for _ in $(seq 1 360); do
    kc=""
    for candidate in "${LAB}/${CLUSTER_NAME}.conf" "${LAB}/${CLUSTER_NAME}.kubeconfig" "${HOME}/${CLUSTER_NAME}.conf" "${LAB}/kubeconfig"; do
      [ -f "${candidate}" ] && kc="${candidate}" && break
    done
    if [ -n "${kc}" ] && patch_coredns_once "${kc}"; then
      echo "=== CoreDNS restarted with ${CLUSTER_HOSTNAME} (${KOMMANDER_INGRESS_IP}) ==="
      return 0
    fi
    sleep 10
  done
  echo "coredns ConfigMap did not appear in time for Dex" >&2
  return 1
}

dns_pid=""
if [ "${DRY_RUN}" != "true" ] && [ -n "${KOMMANDER_INGRESS_IP:-}" ] && [ -n "${CLUSTER_HOSTNAME:-}" ]; then
  apply_coredns_hosts &
  dns_pid=$!
fi

# Redact registry password when printing the command line.
display_args=()
mask_next=false
for a in "${args[@]}"; do
  if [ "${mask_next}" = "true" ]; then
    display_args+=("***")
    mask_next=false
  elif [ "${a}" = "--registry-mirror-password" ]; then
    display_args+=("${a}")
    mask_next=true
  else
    display_args+=("${a}")
  fi
done
echo "=== [create-cluster] nkp ${display_args[*]} ==="
set +e
nkp "${args[@]}"
nkp_rc=$?
set -e
if [ -n "${dns_pid}" ]; then
  if [ "${nkp_rc}" -ne 0 ]; then
    kill "${dns_pid}" 2>/dev/null || true
    wait "${dns_pid}" 2>/dev/null || true
  else
    wait "${dns_pid}"
  fi
fi
exit "${nkp_rc}"
