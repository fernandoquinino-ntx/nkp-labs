#!/usr/bin/env bash
# Day-0 cluster handoff & health summary after create-cluster.sh or install-nkp.sh.
# Prints nodes, CAPI status, CoreDNS hosts verification, Flux HelmRelease health,
# Kommander dashboard URL, initial admin credentials, and the workstation hosts entry.
#
#   ./scripts/post-install-info.sh [--hide-password]
set -Eeuo pipefail

LAB="$(cd "$(dirname "$0")/.." && pwd)"
cd "${LAB}"

HIDE_PASSWORD="${HIDE_PASSWORD:-false}"
if [ "${1:-}" = "--hide-password" ]; then
  HIDE_PASSWORD=true
fi

# Load env hints if present
if [ -f "${LAB}/create-cluster.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${LAB}/create-cluster.env"
  set +a
elif [ -f "${LAB}/env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${LAB}/env"
  set +a
fi

CLUSTER_NAME="${CLUSTER_NAME:-nkp-mgmt}"
KC="${KUBECONFIG:-}"
if [ -z "${KC}" ] || [ ! -f "${KC}" ]; then
  for candidate in \
    "${LAB}/${CLUSTER_NAME}.conf" \
    "${LAB}/${CLUSTER_NAME}.kubeconfig" \
    "${HOME}/${CLUSTER_NAME}.conf" \
    "${LAB}/kubeconfig"; do
    if [ -f "${candidate}" ]; then
      KC="${candidate}"
      break
    fi
  done
fi
[ -n "${KC}" ] && [ -f "${KC}" ] || {
  echo "kubeconfig not found. Set KUBECONFIG=/path/to/${CLUSTER_NAME}.conf and re-run." >&2
  exit 1
}

export KUBECONFIG="${KC}"
echo "=== Kubeconfig: ${KUBECONFIG} ==="

echo ""
echo "=== Nodes ==="
kubectl get nodes -o wide

echo ""
echo "=== CAPI Clusters & Machines ==="
kubectl get clusters.cluster.x-k8s.io,machines.cluster.x-k8s.io -A 2>/dev/null || echo "(CAPI CRDs not found)"

echo ""
echo "=== CoreDNS check ==="
corefile="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' 2>/dev/null || true)"
if [ -n "${CLUSTER_HOSTNAME:-}" ]; then
  if echo "${corefile}" | grep -qF "${CLUSTER_HOSTNAME}"; then
    echo "[OK] CoreDNS Corefile contains ${CLUSTER_HOSTNAME}"
  else
    echo "[WARN] CoreDNS Corefile does NOT contain ${CLUSTER_HOSTNAME}"
  fi
else
  echo "(CLUSTER_HOSTNAME not set in env)"
fi

echo ""
echo "=== Flux HelmReleases ==="
if kubectl get helmreleases.helm.toolkit.fluxcd.io -A >/dev/null 2>&1; then
  total="$(kubectl get helmreleases.helm.toolkit.fluxcd.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  not_ready="$(kubectl get helmreleases.helm.toolkit.fluxcd.io -A --no-headers 2>/dev/null | awk '$4 != "True"' || true)"
  echo "Total HelmReleases: ${total}"
  if [ -n "${not_ready}" ]; then
    echo "[WARN] Not-ready HelmReleases:"
    echo "${not_ready}"
  else
    echo "[OK] All HelmReleases are Ready"
  fi
else
  echo "(Kommander / Flux HelmReleases not installed yet)"
fi

echo ""
echo "=== Kommander Dashboard ==="
lb_ip="$(kubectl -n kommander get svc kommander-traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [ -z "${lb_ip}" ]; then
  lb_ip="$(kubectl -n kommander get svc kommander-traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
fi
display_host="${CLUSTER_HOSTNAME:-${lb_ip:-<ingress-ip>}}"
echo "URL:      https://${display_host}/dkp/kommander/dashboard"
[ -n "${lb_ip}" ] && echo "Ingress:  ${lb_ip}"

user="$(kubectl -n kommander get secret dkp-credentials -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)"
pass="$(kubectl -n kommander get secret dkp-credentials -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [ -n "${user}" ]; then
  echo "Username: ${user}"
  if [ "${HIDE_PASSWORD}" = "true" ]; then
    echo "Password: (hidden; re-run without --hide-password to display)"
  elif [ -n "${pass}" ]; then
    echo "Password: ${pass}"
  fi
else
  echo "Credentials: secret kommander/dkp-credentials not found yet"
fi

hosts_ip="${lb_ip:-${KOMMANDER_INGRESS_IP:-}}"
if [ -n "${CLUSTER_HOSTNAME:-}" ] && [ -n "${hosts_ip}" ]; then
  echo ""
  echo "=== Workstation hosts entry (Windows: C:\\Windows\\System32\\drivers\\etc\\hosts) ==="
  echo "${hosts_ip} ${CLUSTER_HOSTNAME}"
fi
