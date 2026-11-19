#!/usr/bin/env bash
# Install a self-managed NKP cluster from this workspace.
# Same sequence as nkp-infra-tf: kind bootstrap, helm nkp-cluster, kubeconfig, pivot.
# Kommander runs only when INSTALL_KOMMANDER=true.
set -Eeuo pipefail
trap 'echo "ERROR: [install-nkp] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

WORKSPACE="$(cd "$(dirname "$0")" && pwd)"
cd "${WORKSPACE}"

if [ -f "${WORKSPACE}/env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${WORKSPACE}/env"
  set +a
fi

CLUSTER="${CLUSTER_NAME:-nkp-mgmt}"
NAMESPACE="${NAMESPACE:-kommander}"
EXPECTED="${EXPECTED:-5}"
BOOTSTRAP_TIMEOUT="${BOOTSTRAP_TIMEOUT:-20m}"
INSTALL_KOMMANDER="${INSTALL_KOMMANDER:-false}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-1h}"
SKIP_PIVOT="${SKIP_PIVOT:-false}"

VALUES="${WORKSPACE}/values.local.yaml"
BOOT_KC="${WORKSPACE}/bootstrap.kubeconfig"
WORK_KC="${WORKSPACE}/${CLUSTER}.kubeconfig"
CHART="${WORKSPACE}/helm-charts/nkp-cluster"

[ -f "${VALUES}" ] || {
  echo "missing ${VALUES}" >&2
  echo "  cp values.example.yaml values.local.yaml && edit Prism, SSH key, IPs, and the NKP image name" >&2
  exit 1
}
command -v nkp >/dev/null 2>&1 || { echo "nkp CLI is not installed" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm is not installed" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is not installed" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker is not installed" >&2; exit 1; }
if ! docker info >/dev/null 2>&1; then
  echo "docker is installed but this user cannot talk to the daemon." >&2
  echo "Log out and back in so the docker group applies, then re-run." >&2
  exit 1
fi
# The chart rejects an empty key at apply time (infra gotcha: sshPublicKey is required).
# Fail before `nkp create bootstrap` so a bad values file does not leave a kind cluster behind.
ssh_key="$(awk -F': ' '/^sshPublicKey:/ {print $2; exit}' "${VALUES}" | tr -d "\"'")"
if [ -z "${ssh_key}" ] || [ "${ssh_key}" = "''" ]; then
  echo "sshPublicKey is empty in ${VALUES}. Set the NKP node SSH public key before install." >&2
  exit 1
fi

echo "=== [install-nkp] cluster=${CLUSTER} workspace=${WORKSPACE} ==="

if [ -f "${WORK_KC}" ] && kubectl --kubeconfig "${WORK_KC}" get nodes >/dev/null 2>&1; then
  echo "[install-nkp] management cluster already reachable (${WORK_KC})"
else
  if [ -f "${BOOT_KC}" ]; then
    echo "bootstrap kubeconfig already exists at ${BOOT_KC}"
  else
    echo "=== nkp create bootstrap ==="
    nkp create bootstrap --kubeconfig "${BOOT_KC}" --timeout "${BOOTSTRAP_TIMEOUT}"
  fi

  echo "=== helm upgrade --install nkp-cluster ==="
  helm upgrade --install nkp-cluster "${CHART}" \
    -f "${CHART}/values.yaml" \
    -f "${VALUES}" \
    -n "${NAMESPACE}" --create-namespace

  echo "=== waiting for ${EXPECTED} machines to be Ready ==="
  ready=0
  for _ in $(seq 1 180); do
    ready="$(kubectl --kubeconfig "${BOOT_KC}" get machines -n "${NAMESPACE}" \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
      | grep -c True || true)"
    echo "  machines ready=${ready}/${EXPECTED}"
    [ "${ready}" -ge "${EXPECTED}" ] && break
    sleep 20
  done
  [ "${ready}" -ge "${EXPECTED}" ] || { echo "timed out waiting for machines" >&2; exit 1; }

  echo "=== nkp get kubeconfig ==="
  nkp get kubeconfig -c "${CLUSTER}" -n "${NAMESPACE}" --kubeconfig "${BOOT_KC}" > "${WORK_KC}"
  chmod 600 "${WORK_KC}"
fi

if [ "${SKIP_PIVOT}" = "true" ]; then
  echo "=== pivot skipped (SKIP_PIVOT=true). kubeconfig: ${WORK_KC} ==="
  exit 0
fi

if [ -f "${BOOT_KC}" ] && kubectl --kubeconfig "${BOOT_KC}" get nodes >/dev/null 2>&1; then
  echo "=== nkp create capi-components ==="
  nkp create capi-components --kubeconfig "${WORK_KC}" || echo "capi-components returned non-zero (reconciling)"
  echo "=== nkp move capi-resources ==="
  nkp move capi-resources \
    --from-kubeconfig "${BOOT_KC}" \
    --to-kubeconfig "${WORK_KC}" \
    --namespace "${NAMESPACE}" \
    --nkp-namespace "${NAMESPACE}" \
    --to-nkp-namespace "${NAMESPACE}" \
    || echo "move returned non-zero (reconciling)"
  echo "=== nkp delete bootstrap ==="
  nkp delete bootstrap --kubeconfig "${BOOT_KC}" || true
else
  echo "[install-nkp] bootstrap cluster already gone — pivot skipped"
fi

if [ "${INSTALL_KOMMANDER}" != "true" ]; then
  echo "=== done. kubeconfig: ${WORK_KC} ==="
  echo "Set INSTALL_KOMMANDER=true in env to install Kommander."
  exit 0
fi

export KUBECONFIG="${WORK_KC}"
echo "=== helm upgrade --install nkp-kommander ==="
helm upgrade --install nkp-kommander "${WORKSPACE}/helm-charts/nkp-kommander" \
  -f "${VALUES}" -n "${NAMESPACE}" --create-namespace --wait --timeout 15m

kubectl -n "${NAMESPACE}" get configmap kommander-installer-config \
  -o jsonpath='{.data.kommander\.yaml}' > "${WORKSPACE}/kommander.yaml"

echo "=== waiting for kommander-bootstrap job ==="
for _ in $(seq 1 60); do
  status="$(kubectl -n "${NAMESPACE}" get job kommander-bootstrap -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  [ "${status}" = "1" ] && break
  sleep 10
done
failed="$(kubectl -n "${NAMESPACE}" get job kommander-bootstrap -o jsonpath='{.status.failed}' 2>/dev/null || true)"
[ "${failed}" = "1" ] && { echo "kommander-bootstrap job failed" >&2; exit 1; }

if kubectl get kommandercluster >/dev/null 2>&1; then
  echo "kommandercluster already exists"
else
  nkp install kommander \
    --installer-config "${WORKSPACE}/kommander.yaml" \
    --kubeconfig "${WORK_KC}" \
    --wait --wait-timeout "${INSTALL_TIMEOUT}" \
    || echo "nkp install kommander returned non-zero (still reconciling)"
fi

# Same follow-up as nkp-infra-tf kommander.sh: point Docker Hub OCI repos at
# dockerhub-auth, or Flux pulls anonymously and hits the rate limit.
if kubectl -n "${NAMESPACE}" get secret dockerhub-auth >/dev/null 2>&1; then
  echo "=== patching Docker Hub OCIRepository secretRef ==="
  kubectl -n "${NAMESPACE}" get ocirepository \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.url}{"\n"}{end}' 2>/dev/null \
    | awk '$2 ~ /docker\.io/ {print $1}' \
    | while read -r repo; do
        [ -n "${repo}" ] || continue
        kubectl -n "${NAMESPACE}" patch ocirepository "${repo}" --type merge \
          -p '{"spec":{"secretRef":{"name":"dockerhub-auth"}}}' >/dev/null 2>&1 \
          && echo "  patched ${repo}"
      done
else
  echo "no dockerhub-auth secret. Set registry.username and registry.password in values.local.yaml or Kommander image pulls stay anonymous."
fi

echo "=== done. kubeconfig: ${WORK_KC} ==="
