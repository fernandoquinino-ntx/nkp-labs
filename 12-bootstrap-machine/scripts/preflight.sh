#!/usr/bin/env bash
# Fast pre-flight check before running scripts/create-cluster.sh.
# Validates create-cluster.env, bastion disk/Docker/CLI tools, local registry TLS + pushed
# image bundles, bootstrap image tar, VIP conflicts, and Prism Central objects (PE cluster,
# subnet, OS image, storage container, categories).
#
#   ./scripts/preflight.sh
#
# Optional toggles:
#   SKIP_PRISM_CHECK=true   skip live Prism Central API checks
#   SKIP_PING_CHECK=true    skip VIP ping conflict checks
set -Eeuo pipefail

LAB="$(cd "$(dirname "$0")/.." && pwd)"
cd "${LAB}"

PASS=0
WARN=0
FAIL=0

pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

echo "=== NKP pre-flight check (${LAB}) ==="

# 1. Load create-cluster.env
if [ ! -f "${LAB}/create-cluster.env" ]; then
  fail "missing ${LAB}/create-cluster.env (run: cp create-cluster.env.example create-cluster.env)"
  echo "Summary: ${PASS} pass, ${WARN} warn, ${FAIL} fail"
  exit 1
fi
set -a
# shellcheck disable=SC1091
. "${LAB}/create-cluster.env"
set +a
pass "loaded create-cluster.env"

# 2. Toolchain & Docker
for bin in nkp kubectl docker curl openssl python3; do
  if command -v "${bin}" >/dev/null 2>&1; then
    pass "binary found: ${bin}"
  else
    fail "missing required command: ${bin}"
  fi
done
if docker info >/dev/null 2>&1; then
  pass "docker daemon reachable by $(id -un)"
else
  fail "cannot talk to docker daemon (log out and back in for the docker group)"
fi

# 3. Bastion disk space
avail_gb="$(df -BG --output=avail "${LAB}" 2>/dev/null | tail -n 1 | tr -dc '0-9' || true)"
if [ -n "${avail_gb}" ]; then
  if [ "${avail_gb}" -lt 5 ]; then
    fail "only ${avail_gb} GiB free in ${LAB} (need at least 20 GiB for kind bootstrap and logs)"
  elif [ "${avail_gb}" -lt 20 ]; then
    warn "only ${avail_gb} GiB free in ${LAB} (20+ GiB recommended)"
  else
    pass "bastion free disk space: ${avail_gb} GiB"
  fi
fi

# 4. Required env values & placeholders
required_vars=(
  CLUSTER_NAME NUTANIX_USER NUTANIX_PASSWORD NUTANIX_ENDPOINT
  NUTANIX_PRISM_ELEMENT_CLUSTER_NAME NUTANIX_SUBNET_NAME
  NUTANIX_STORAGE_CONTAINER_NAME CONTROL_PLANE_ENDPOINT_IP LB_IP_RANGE
  NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME SSH_PUBKEY
)
for v in "${required_vars[@]}"; do
  val="${!v:-}"
  if [ -z "${val}" ]; then
    fail "${v} is empty in create-cluster.env"
  elif [[ "${val}" == *CHANGE-ME* ]]; then
    fail "${v} still contains CHANGE-ME"
  fi
done
if [ -n "${SSH_PUBKEY:-}" ]; then
  if [ -f "${SSH_PUBKEY}" ] && grep -qE '^(ssh-|ecdsa-)' "${SSH_PUBKEY}"; then
    pass "SSH public key valid: ${SSH_PUBKEY}"
  else
    fail "SSH_PUBKEY missing or not a public key: ${SSH_PUBKEY}"
  fi
fi
if [ "${DRY_RUN:-false}" = "true" ]; then
  warn "DRY_RUN=true (create-cluster.sh will only print YAML; set DRY_RUN=false for real install)"
else
  pass "DRY_RUN=false"
fi
if [ -n "${CLUSTER_HOSTNAME:-}" ] && [ -z "${KOMMANDER_INGRESS_IP:-}" ]; then
  warn "CLUSTER_HOSTNAME is set (${CLUSTER_HOSTNAME}) but KOMMANDER_INGRESS_IP is empty (CoreDNS auto-patch will not run)"
elif [ -n "${CLUSTER_HOSTNAME:-}" ] && [ -n "${KOMMANDER_INGRESS_IP:-}" ]; then
  pass "CoreDNS auto-patch configured: ${CLUSTER_HOSTNAME} -> ${KOMMANDER_INGRESS_IP}"
fi

# 5. Local registry & air-gap bundle checks
has_mirror=false
case "${REGISTRY_MIRROR_URL:-}" in
  ""|*CHANGE-ME*) warn "REGISTRY_MIRROR_URL not set (assuming online install)" ;;
  *) has_mirror=true ;;
esac

if [ "${has_mirror}" = "true" ]; then
  if [[ "${REGISTRY_MIRROR_URL}" == *"://127."* ]]; then
    fail "REGISTRY_MIRROR_URL uses loopback (${REGISTRY_MIRROR_URL}); NKP nodes need the bastion LAN IP"
  else
    pass "REGISTRY_MIRROR_URL uses non-loopback address: ${REGISTRY_MIRROR_URL}"
  fi

  case "${BOOTSTRAP_CLUSTER_IMAGE_PATH:-}" in
    http://*|https://*)
      fail "BOOTSTRAP_CLUSTER_IMAGE_PATH must be a local .tar file, not a URL (${BOOTSTRAP_CLUSTER_IMAGE_PATH})"
      ;;
    "")
      auto_bs="$(find "${LAB}/airgap" -maxdepth 4 -type f -name 'konvoy-bootstrap-image-*.tar' 2>/dev/null | head -n 1 || true)"
      if [ -n "${auto_bs}" ]; then
        pass "bootstrap image tar auto-detectable: ${auto_bs}"
      else
        fail "BOOTSTRAP_CLUSTER_IMAGE_PATH is empty and no konvoy-bootstrap-image-*.tar found under ${LAB}/airgap"
      fi
      ;;
    *)
      if [ -f "${BOOTSTRAP_CLUSTER_IMAGE_PATH}" ]; then
        pass "bootstrap image tar exists: ${BOOTSTRAP_CLUSTER_IMAGE_PATH}"
      else
        fail "BOOTSTRAP_CLUSTER_IMAGE_PATH not found: ${BOOTSTRAP_CLUSTER_IMAGE_PATH}"
      fi
      ;;
  esac

  if [ -z "${REGISTRY_MIRROR_PASSWORD:-}" ] || [[ "${REGISTRY_MIRROR_PASSWORD}" == *CHANGE-ME* ]]; then
    fail "REGISTRY_MIRROR_PASSWORD is missing or CHANGE-ME"
  fi
  if [ -n "${REGISTRY_MIRROR_CACERT:-}" ] && [ ! -f "${REGISTRY_MIRROR_CACERT}" ]; then
    fail "REGISTRY_MIRROR_CACERT not found: ${REGISTRY_MIRROR_CACERT}"
  else
    curl_ca=()
    [ -n "${REGISTRY_MIRROR_CACERT:-}" ] && curl_ca=(--cacert "${REGISTRY_MIRROR_CACERT}")
    reg_url="${REGISTRY_MIRROR_URL%/}"
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
      "${curl_ca[@]}" -u "${REGISTRY_MIRROR_USERNAME:-nkp}:${REGISTRY_MIRROR_PASSWORD:-}" \
      "${reg_url}/v2/" 2>/dev/null || echo "000")"
    if [ "${http_code}" = "200" ]; then
      pass "local registry TLS + auth ok (${reg_url}/v2/ -> 200)"
      catalog="$(curl -fsS --connect-timeout 5 --max-time 10 "${curl_ca[@]}" \
        -u "${REGISTRY_MIRROR_USERNAME:-nkp}:${REGISTRY_MIRROR_PASSWORD:-}" \
        "${reg_url}/v2/_catalog?n=2000" 2>/dev/null || true)"
      if [ -n "${catalog}" ]; then
        repo_info="$(python3 - "${catalog}" <<'PY'
import json, sys
repos = (json.loads(sys.argv[1]).get("repositories") or [])
has_konvoy = any(any(k in r for k in ("calico", "cilium", "kube-apiserver", "konvoy", "capi")) for r in repos)
has_kommander = any(any(k in r for k in ("kommander", "traefik", "dex", "flux")) for r in repos)
print(f"{len(repos)} {int(has_konvoy)} {int(has_kommander)}")
PY
)"
        read -r r_count r_konvoy r_kommander <<< "${repo_info}"
        if [ "${r_count}" -eq 0 ]; then
          fail "local registry has 0 images pushed (run ./scripts/push-airgap-bundles.sh)"
        else
          pass "local registry contains ${r_count} image repositories"
          [ "${r_konvoy}" -eq 1 ] && pass "konvoy bundle images detected in registry" || warn "could not confirm konvoy images in registry catalog"
          [ "${r_kommander}" -eq 1 ] && pass "kommander bundle images detected in registry" || fail "kommander bundle images not found in registry (push kommander-image-bundle-*.tar)"
        fi
      fi
    else
      fail "local registry check failed (${reg_url}/v2/ returned HTTP ${http_code}; check cert IP SAN, password, and container)"
    fi
  fi
fi

# 6. VIP IP conflict checks (best-effort ping)
if [ "${SKIP_PING_CHECK:-false}" != "true" ] && command -v ping >/dev/null 2>&1; then
  for vip_var in CONTROL_PLANE_ENDPOINT_IP KOMMANDER_INGRESS_IP; do
    vip="${!vip_var:-}"
    [ -n "${vip}" ] || continue
    if ping -c 1 -W 1 "${vip}" >/dev/null 2>&1; then
      fail "${vip_var} (${vip}) already responds to ping — possible IP conflict!"
    else
      pass "${vip_var} (${vip}) is free (no ping reply)"
    fi
  done
fi

# 7. Prism Central live validation
if [ "${SKIP_PRISM_CHECK:-false}" != "true" ] && [ -n "${NUTANIX_ENDPOINT:-}" ] && [ -n "${NUTANIX_USER:-}" ] && [ -n "${NUTANIX_PASSWORD:-}" ]; then
  pc_out="$(python3 - <<'PY'
import base64, json, os, ssl, urllib.error, urllib.request

host = os.environ["NUTANIX_ENDPOINT"].strip()
port = os.environ.get("NUTANIX_PORT", "9440").strip()
base = host if host.startswith(("http://", "https://")) else f"https://{host}:{port}"
base = base.rstrip("/")
user = os.environ["NUTANIX_USER"]
pw = os.environ["NUTANIX_PASSWORD"]
auth = "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()
ctx = ssl._create_unverified_context()

def req(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    r = urllib.request.Request(base + path, data=data, method=method)
    r.add_header("Authorization", auth)
    r.add_header("Accept", "application/json")
    if data is not None:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, context=ctx, timeout=15) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            parsed = json.loads(raw) if raw else {}
        except Exception:
            parsed = {"raw": raw[:300]}
        return e.code, parsed
    except Exception as e:
        return 0, {"error": str(e)}

def list_v3(kind):
    names = []
    offset = 0
    while True:
        code, body = req("POST", f"/api/nutanix/v3/{kind}/list", {"kind": kind[:-1] if kind.endswith("s") else kind, "length": 250, "offset": offset})
        if code != 200:
            return code, None, body
        ents = body.get("entities") or []
        for e in ents:
            n = (e.get("spec") or {}).get("name") or (e.get("status") or {}).get("name")
            if n:
                names.append(n)
        total = (body.get("metadata") or {}).get("total_matches")
        offset += len(ents)
        if not ents or len(ents) < 250 or (total is not None and offset >= total):
            return 200, names, None

# Auth + PE cluster check
code, clusters, err = list_v3("clusters")
if code == 0:
    print(f"FAIL|cannot reach Prism Central {base}: {err.get('error')}")
    raise SystemExit(0)
if code in (401, 403):
    print(f"FAIL|Prism Central auth/permission failed ({code}) for user {user}")
    raise SystemExit(0)
if code != 200:
    print(f"WARN|Prism Central cluster list returned HTTP {code}")
else:
    print(f"PASS|Prism Central reachable and authenticated as {user}")
    pe = os.environ.get("NUTANIX_PRISM_ELEMENT_CLUSTER_NAME", "")
    if pe in clusters:
        print(f"PASS|Prism Element cluster found: {pe}")
    else:
        print(f"FAIL|Prism Element cluster '{pe}' not found (available: {', '.join(clusters[:10])})")

# Subnet check
code, subnets, _ = list_v3("subnets")
if code == 200:
    sn = os.environ.get("NUTANIX_SUBNET_NAME", "")
    if sn in subnets:
        print(f"PASS|Subnet found in Prism Central: {sn}")
    else:
        print(f"FAIL|Subnet '{sn}' not found in Prism Central (available: {', '.join(subnets[:10])})")
else:
    print(f"WARN|Could not list subnets (HTTP {code})")

# Image check
code, images, _ = list_v3("images")
if code == 200:
    img = os.environ.get("NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME", "")
    if img in images:
        print(f"PASS|OS image found in Prism Central: {img}")
    else:
        print(f"FAIL|OS image '{img}' not found in Prism Central")
else:
    print(f"WARN|Could not list images (HTTP {code})")

# Storage container check (optional permission on NKP role)
sc_name = os.environ.get("NUTANIX_STORAGE_CONTAINER_NAME", "")
if sc_name:
    sc_found = None
    for ver in ("v4.0", "v4.0.b1"):
        code, body = req("GET", f"/api/storage/{ver}/config/storage-containers?$limit=100")
        if code == 200:
            names = [r.get("name") for r in (body.get("data") or []) if r.get("name")]
            sc_found = sc_name in names
            break
    if sc_found is True:
        print(f"PASS|Storage container found: {sc_name}")
    elif sc_found is False:
        print(f"FAIL|Storage container '{sc_name}' not found via storage API")
    else:
        print(f"WARN|Could not verify storage container '{sc_name}' (View Storage Container permission is optional)")

# Optional Prism Central categories check
for env_var in ("CONTROL_PLANE_PC_CATEGORIES", "WORKER_PC_CATEGORIES"):
    raw = os.environ.get(env_var, "").strip()
    if not raw:
        continue
    for item in [x.strip() for x in raw.split(",") if x.strip()]:
        if "=" not in item:
            print(f"FAIL|{env_var} entry '{item}' must be in Key=Value format")
            continue
        k, v = item.split("=", 1)
        code, body = req("POST", f"/api/nutanix/v3/categories/{k}/list", {"kind": "category", "length": 100})
        if code == 200:
            vals = [e.get("value") for e in (body.get("entities") or [])]
            if v in vals:
                print(f"PASS|Prism category found ({env_var}): {k}={v}")
            else:
                print(f"FAIL|Prism category value '{k}={v}' not found in Prism Central")
        else:
            print(f"WARN|Could not verify Prism category '{k}={v}' (HTTP {code})")
PY
)"
  while IFS='|' read -r lvl msg; do
    [ -n "${lvl}" ] || continue
    case "${lvl}" in
      PASS) pass "${msg}" ;;
      WARN) warn "${msg}" ;;
      FAIL) fail "${msg}" ;;
    esac
  done <<< "${pc_out}"
fi

echo "=== Summary: ${PASS} pass, ${WARN} warn, ${FAIL} fail ==="
[ "${FAIL}" -eq 0 ]
