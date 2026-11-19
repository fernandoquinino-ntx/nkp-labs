#!/usr/bin/env bash
# Local TLS registry on the bastion for an air-gapped NKP install.
# Creates a self-signed CA, a registry certificate signed by that CA, and
# (unless SKIP_DOCKER=true) a registry:2 container. The CA file is what the
# NKP cluster must trust (scripts/trust-registry.sh).
set -Eeuo pipefail
trap 'echo "ERROR: [setup-local-registry] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

LAB="$(cd "$(dirname "$0")/.." && pwd)"
STATE="${REGISTRY_STATE_DIR:-${LAB}/registry}"
HOST="${REGISTRY_HOST:-registry.nkp.local}"
PORT="${REGISTRY_PORT:-5000}"
IP="${REGISTRY_IP:-}"
if [ -z "${IP}" ] && command -v hostname >/dev/null 2>&1; then
  IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi
REG_USER="${REGISTRY_USER:-nkp}"
REG_PASSWORD="${REGISTRY_PASSWORD:-}"
SKIP_DOCKER="${SKIP_DOCKER:-false}"

mkdir -p "${STATE}/certs" "${STATE}/auth" "${STATE}/data"
chmod 700 "${STATE}" "${STATE}/certs" "${STATE}/auth"

# Keep the password from an earlier run. A new one would break the secret already in the cluster.
if [ -z "${REG_PASSWORD}" ] && [ -f "${STATE}/credentials.env" ]; then
  REG_PASSWORD="$(awk -F= '$1 == "REGISTRY_PASSWORD" {print substr($0, index($0, "=") + 1)}' "${STATE}/credentials.env")"
fi
if [ -z "${REG_PASSWORD}" ]; then
  REG_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
fi
umask 077
cat > "${STATE}/credentials.env" <<EOF
REGISTRY_HOST=${HOST}
REGISTRY_PORT=${PORT}
REGISTRY_USER=${REG_USER}
REGISTRY_PASSWORD=${REG_PASSWORD}
REGISTRY_URL=https://${HOST}:${PORT}
EOF
chmod 600 "${STATE}/credentials.env"

if [ ! -f "${STATE}/certs/ca.crt" ]; then
  openssl genrsa -out "${STATE}/certs/ca.key" 4096
  openssl req -x509 -new -nodes -key "${STATE}/certs/ca.key" -sha256 -days 825 \
    -out "${STATE}/certs/ca.crt" -subj "/CN=nkp-registry-ca"
  openssl genrsa -out "${STATE}/certs/registry.key" 2048
  openssl req -new -key "${STATE}/certs/registry.key" -out "${STATE}/certs/registry.csr" \
    -subj "/CN=${HOST}"
  san="DNS:${HOST},DNS:localhost,IP:127.0.0.1"
  if [ -n "${IP}" ]; then
    san="${san},IP:${IP}"
  fi
  cat > "${STATE}/certs/san.cnf" <<EOF
subjectAltName=${san}
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
EOF
  openssl x509 -req -in "${STATE}/certs/registry.csr" \
    -CA "${STATE}/certs/ca.crt" -CAkey "${STATE}/certs/ca.key" -CAcreateserial \
    -out "${STATE}/certs/registry.crt" -days 825 -sha256 \
    -extfile "${STATE}/certs/san.cnf"
  chmod 600 "${STATE}/certs/ca.key" "${STATE}/certs/registry.key"
fi
openssl verify -CAfile "${STATE}/certs/ca.crt" "${STATE}/certs/registry.crt"

hash="$(openssl passwd -apr1 "${REG_PASSWORD}")"
printf '%s:%s\n' "${REG_USER}" "${hash}" > "${STATE}/auth/htpasswd"
chmod 600 "${STATE}/auth/htpasswd"

# Bastion Docker trusts this registry. Cluster nodes get the same CA via trust-registry.sh.
if [ -d /etc/docker ] && [ "$(id -u)" -eq 0 ]; then
  install -d -m 0755 "/etc/docker/certs.d/${HOST}:${PORT}"
  install -m 0644 "${STATE}/certs/ca.crt" "/etc/docker/certs.d/${HOST}:${PORT}/ca.crt"
fi
if [ -n "${IP}" ] && [ "$(id -u)" -eq 0 ] && ! getent hosts "${HOST}" >/dev/null 2>&1; then
  echo "${IP} ${HOST}" >> /etc/hosts
fi
install -d -m 0755 "${STATE}/docker-certs.d/${HOST}:${PORT}"
install -m 0644 "${STATE}/certs/ca.crt" "${STATE}/docker-certs.d/${HOST}:${PORT}/ca.crt"

if [ "${SKIP_DOCKER}" = "true" ]; then
  echo "=== certs ready in ${STATE} (docker start skipped) ==="
  echo "CA: ${STATE}/certs/ca.crt"
  echo "URL: https://${HOST}:${PORT}"
  exit 0
fi

command -v docker >/dev/null 2>&1 || { echo "docker is not installed" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "this user cannot talk to docker" >&2; exit 1; }

if docker ps -a --format '{{.Names}}' | grep -qx nkp-registry; then
  docker rm -f nkp-registry >/dev/null
fi
docker run -d --restart=always --name nkp-registry \
  -p "${PORT}:5000" \
  -v "${STATE}/certs:/certs:ro" \
  -v "${STATE}/auth:/auth:ro" \
  -v "${STATE}/data:/var/lib/registry" \
  -e REGISTRY_HTTP_ADDR=0.0.0.0:5000 \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
  -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
  -e REGISTRY_AUTH=htpasswd \
  -e REGISTRY_AUTH_HTPASSWD_REALM="NKP registry" \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  registry:2

echo "=== registry https://${HOST}:${PORT} user ${REG_USER} ==="
echo "credentials: ${STATE}/credentials.env"
echo "cluster trust: ./scripts/trust-registry.sh"
