#!/usr/bin/env bash
# Push the offline NKP Pulse image bundle to the local TLS registry using `nkp push bundle`,
# verify the images exist in the registry, and fix stuck NKP Pulse Kubernetes Job manifests
# (such as nkp-pulse-management-apply-crds and nkp-pulse-management-cm-postdelete) that
# still reference docker.io/mesosphere/... in air-gapped environments.
#
# Usage on the air-gapped bastion:
#   ./scripts/fix-pulse-airgap.sh [--bundle airgap/nkp-pulse-image-bundle-v2.19.1.tar]
#   ./scripts/fix-pulse-airgap.sh --dry-run
#   ./scripts/fix-pulse-airgap.sh --skip-push --image-registry registry.nkp.local:5000
#   ./scripts/fix-pulse-airgap.sh --reconcile
#
# Offline manifest transform (for testing or exporting fixed YAML without cluster access):
#   ./scripts/fix-pulse-airgap.sh --fix-manifest-file job.yaml --image-registry registry.nkp.local:5000
#
# Options:
#   --bundle <tar>               Path to nkp-pulse-image-bundle-*.tar (auto-detected if omitted)
#   --to-registry <url>          Target registry URL (e.g. https://10.0.0.5:5000)
#   --image-registry <host:port> Registry host:port written into Job manifests (defaults to --to-registry host:port)
#   --username <user>            Registry username (defaults to registry/credentials.env)
#   --password <pass>            Registry password (defaults to registry/credentials.env)
#   --ca-cert <path>             Registry CA cert path (defaults to registry/certs/ca.crt)
#   --insecure                   Pass --to-registry-insecure-skip-tls-verify to nkp push bundle
#   --namespace <ns>             Kubernetes namespace (default: kommander)
#   --jobs <csv>                 Comma-separated Job names (default: auto-discover all nkp-pulse* Jobs)
#   --image-pull-secret <name>   Optional imagePullSecret to inject into recreated Jobs
#   --kubeconfig <path>          Kubeconfig path (defaults to $KUBECONFIG or ~/nkp-workspace/*.conf)
#   --skip-push                  Skip `nkp push bundle` and only fix Kubernetes manifests
#   --skip-jobs                  Only push & verify bundle images; do not touch Kubernetes Jobs
#   --reconcile                  Trigger Flux HelmRelease reconciliation for nkp-pulse-management after fixing
#   --dry-run                    Show exact patched Job YAML without deleting/recreating Jobs
#   --fix-manifest-file <yaml>   Rewrite a local Job YAML file to stdout (no registry/cluster needed)
set -Eeuo pipefail
trap 'echo "ERROR: [fix-pulse-airgap] failed at line $LINENO on command: $BASH_COMMAND" >&2' ERR

LAB="$(cd "$(dirname "$0")/.." && pwd)"
AIRGAP_DIR="${AIRGAP_DIR:-${LAB}/airgap}"
STATE="${REGISTRY_STATE_DIR:-${LAB}/registry}"

BUNDLE=""
PUSH_URL="${REGISTRY_PUSH_URL:-}"
IMAGE_REGISTRY=""
REG_USER=""
REG_PASS=""
CA_CERT=""
INSECURE="false"
NAMESPACE="kommander"
JOBS_CSV=""
PULL_SECRET=""
KC="${KUBECONFIG:-}"
SKIP_PUSH="false"
SKIP_JOBS="false"
RECONCILE="false"
DRY_RUN="false"
FIX_MANIFEST_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle)            BUNDLE="${2:?missing path after --bundle}"; shift 2 ;;
    --to-registry)       PUSH_URL="${2:?missing URL after --to-registry}"; shift 2 ;;
    --image-registry)    IMAGE_REGISTRY="${2:?missing host:port after --image-registry}"; shift 2 ;;
    --username)          REG_USER="${2:?missing user after --username}"; shift 2 ;;
    --password)          REG_PASS="${2:?missing password after --password}"; shift 2 ;;
    --ca-cert)           CA_CERT="${2:?missing path after --ca-cert}"; shift 2 ;;
    --insecure)          INSECURE="true"; shift ;;
    --namespace)         NAMESPACE="${2:?missing namespace after --namespace}"; shift 2 ;;
    --jobs)              JOBS_CSV="${2:?missing job names after --jobs}"; shift 2 ;;
    --image-pull-secret) PULL_SECRET="${2:?missing secret name after --image-pull-secret}"; shift 2 ;;
    --kubeconfig)        KC="${2:?missing path after --kubeconfig}"; shift 2 ;;
    --skip-push)         SKIP_PUSH="true"; shift ;;
    --skip-jobs)         SKIP_JOBS="true"; shift ;;
    --reconcile)         RECONCILE="true"; shift ;;
    --dry-run)           DRY_RUN="true"; shift ;;
    --fix-manifest-file) FIX_MANIFEST_FILE="${2:?missing path after --fix-manifest-file}"; shift 2 ;;
    -h|--help)
      sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

rewrite_job_manifest() {
  local in_file="$1" out_file="$2" target_reg="$3" pull_secret="$4"
  python3 - "${in_file}" "${out_file}" "${target_reg}" "${pull_secret}" <<'PY'
import json, re, sys

in_path, out_path, target_reg, pull_secret = sys.argv[1:5]
target_reg = target_reg.strip().rstrip("/")
raw = open(in_path, encoding="utf-8").read()

try:
    import yaml
    doc = yaml.safe_load(raw)
    dump_yaml = True
except ImportError:
    doc = json.loads(raw)
    dump_yaml = False

if not isinstance(doc, dict) or doc.get("kind") != "Job":
    sys.exit(f"expected a Kubernetes Job manifest in {in_path}")

def rewrite_image(img):
    if not img:
        return img
    # Rewrite docker.io/mesosphere/... or bare mesosphere/... -> <target_reg>/mesosphere/...
    m = re.match(r"^(?:docker\.io/)?(mesosphere/.+)$", img.strip())
    if m:
        return f"{target_reg}/{m.group(1)}"
    # Rewrite docker.io/<org>/<repo> -> <target_reg>/<org>/<repo>
    m2 = re.match(r"^docker\.io/(.+)$", img.strip())
    if m2:
        return f"{target_reg}/{m2.group(1)}"
    return img

# Strip runtime/immutable metadata fields so recreated Job applies cleanly
meta = doc.get("metadata") or {}
for k in ("uid", "resourceVersion", "creationTimestamp", "generation", "managedFields", "selfLink"):
    meta.pop(k, None)
if isinstance(meta.get("labels"), dict):
    for k in ("controller-uid", "batch.kubernetes.io/controller-uid", "job-name", "batch.kubernetes.io/job-name"):
        meta["labels"].pop(k, None)
    if not meta["labels"]:
        meta.pop("labels", None)
doc["metadata"] = meta

# Strip status and immutable selector
doc.pop("status", None)
spec = doc.get("spec") or {}
spec.pop("selector", None)
spec.pop("manualSelector", None)

tpl = spec.get("template") or {}
tpl_meta = tpl.get("metadata") or {}
tpl_meta.pop("creationTimestamp", None)
if isinstance(tpl_meta.get("labels"), dict):
    for k in ("controller-uid", "batch.kubernetes.io/controller-uid", "job-name", "batch.kubernetes.io/job-name"):
        tpl_meta["labels"].pop(k, None)
    if not tpl_meta["labels"]:
        tpl_meta.pop("labels", None)
tpl["metadata"] = tpl_meta

pod_spec = tpl.get("spec") or {}
changed = 0
for group in ("containers", "initContainers", "ephemeralContainers"):
    for c in pod_spec.get(group) or []:
        old = c.get("image", "")
        new = rewrite_image(old)
        if new != old:
            c["image"] = new
            changed += 1

if pull_secret:
    secrets = list(pod_spec.get("imagePullSecrets") or [])
    if not any(isinstance(s, dict) and s.get("name") == pull_secret for s in secrets):
        secrets.append({"name": pull_secret})
    pod_spec["imagePullSecrets"] = secrets

tpl["spec"] = pod_spec
spec["template"] = tpl
doc["spec"] = spec

if dump_yaml:
    out_txt = yaml.safe_dump(doc, sort_keys=False)
else:
    out_txt = json.dumps(doc, indent=2) + "\n"

if out_path == "-":
    sys.stdout.write(out_txt)
else:
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(out_txt)
PY
}

# Offline single-file transform mode (no cluster or registry required)
if [ -n "${FIX_MANIFEST_FILE}" ]; then
  [ -f "${FIX_MANIFEST_FILE}" ] || { echo "manifest file not found: ${FIX_MANIFEST_FILE}" >&2; exit 1; }
  [ -n "${IMAGE_REGISTRY}" ] || { echo "--image-registry <host:port> is required with --fix-manifest-file" >&2; exit 1; }
  rewrite_job_manifest "${FIX_MANIFEST_FILE}" "-" "${IMAGE_REGISTRY}" "${PULL_SECRET}"
  exit 0
fi

# 1. Load local bastion registry defaults when present
CREDS="${STATE}/credentials.env"
REG_CERT="${STATE}/certs/registry.crt"
if [ -f "${CREDS}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${CREDS}"
  set +a
fi
[ -n "${REG_USER}" ] || REG_USER="${REGISTRY_USER:-}"
[ -n "${REG_PASS}" ] || REG_PASS="${REGISTRY_PASSWORD:-}"
[ -n "${CA_CERT}" ] || [ ! -f "${STATE}/certs/ca.crt" ] || CA_CERT="${STATE}/certs/ca.crt"

# Prefer non-loopback IP SAN on registry.crt for `nkp push bundle`
if [ -z "${PUSH_URL}" ] && [ -f "${REG_CERT}" ]; then
  cert_ip="$(openssl x509 -in "${REG_CERT}" -noout -text 2>/dev/null \
    | grep -oE 'IP Address:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
    | cut -d: -f2 \
    | grep -v '^127\.' | head -n 1 || true)"
  if [ -n "${cert_ip}" ]; then
    PUSH_URL="https://${cert_ip}:${REGISTRY_PORT:-5000}"
  fi
fi
if [ -z "${PUSH_URL}" ] && [ -n "${REGISTRY_URL:-}" ]; then
  PUSH_URL="${REGISTRY_URL}"
fi
if [ -z "${PUSH_URL}" ]; then
  PUSH_URL="https://${REGISTRY_HOST:-registry.nkp.local}:${REGISTRY_PORT:-5000}"
fi
PUSH_URL="${PUSH_URL%/}"

# Determine registry host:port used inside Kubernetes manifests
if [ -z "${IMAGE_REGISTRY}" ]; then
  IMAGE_REGISTRY="${PUSH_URL#https://}"
  IMAGE_REGISTRY="${IMAGE_REGISTRY#http://}"
  IMAGE_REGISTRY="${IMAGE_REGISTRY%%/*}"
fi

# 2. Push the NKP Pulse offline image bundle with `nkp push bundle`
if [ "${SKIP_PUSH}" != "true" ]; then
  command -v nkp >/dev/null 2>&1 || { echo "nkp CLI is not installed" >&2; exit 1; }
  if [ -z "${BUNDLE}" ]; then
    for cand in \
      "${AIRGAP_DIR}"/nkp-pulse-image-bundle*.tar \
      "${LAB}"/nkp-pulse-image-bundle*.tar \
      "${HOME}"/nkp-pulse-image-bundle*.tar \
      ./nkp-pulse-image-bundle*.tar; do
      if [ -f "${cand}" ]; then
        BUNDLE="${cand}"
        break
      fi
    done
  fi
  [ -n "${BUNDLE}" ] && [ -f "${BUNDLE}" ] || {
    echo "NKP Pulse image bundle not found. Download it from the offline-bundle release or build it with:" >&2
    echo "  ./scripts/build-pulse-bundle.sh" >&2
    echo "Then pass --bundle /path/to/nkp-pulse-image-bundle-v2.19.1.tar" >&2
    exit 1
  }

  if [ -f "${BUNDLE}.sha256" ]; then
    expected="$(awk '{print $1}' "${BUNDLE}.sha256")"
    got="$(sha256sum "${BUNDLE}" | awk '{print $1}')"
    if [ "${got}" != "${expected}" ]; then
      echo "ERROR: sha256 mismatch for ${BUNDLE} (expected ${expected}, got ${got})" >&2
      exit 1
    fi
    echo "=== bundle checksum ok (${BUNDLE}) ==="
  fi

  if [[ "${PUSH_URL}" == *"://127."* ]]; then
    echo "ERROR: refusing loopback registry URL (${PUSH_URL}); pass --to-registry https://<bastion-ip>:5000" >&2
    exit 1
  fi

  push_args=(
    push bundle
    --bundle "${BUNDLE}"
    --to-registry "${PUSH_URL}"
  )
  [ -n "${REG_USER}" ] && push_args+=(--to-registry-username "${REG_USER}")
  [ -n "${REG_PASS}" ] && push_args+=(--to-registry-password "${REG_PASS}")
  if [ "${INSECURE}" = "true" ]; then
    push_args+=(--to-registry-insecure-skip-tls-verify)
  elif [ -n "${CA_CERT}" ] && [ -f "${CA_CERT}" ]; then
    push_args+=(--to-registry-ca-cert-file "${CA_CERT}")
  fi

  if [ "${DRY_RUN}" = "true" ]; then
    echo "=== [dry-run] would run: nkp push bundle --bundle ${BUNDLE} --to-registry ${PUSH_URL} ==="
  else
    echo "=== pushing ${BUNDLE} -> ${PUSH_URL} ==="
    nkp "${push_args[@]}"
  fi

  # Verify the pushed manifests exist in the target registry
  if [ "${DRY_RUN}" != "true" ] && command -v curl >/dev/null 2>&1; then
    curl_auth_cfg=""
    curl_opts=(-sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15)
    if [ "${INSECURE}" = "true" ]; then
      curl_opts+=(-k)
    elif [ -n "${CA_CERT}" ] && [ -f "${CA_CERT}" ]; then
      curl_opts+=(--cacert "${CA_CERT}")
    fi
    if [ -n "${REG_USER}" ]; then
      curl_auth_cfg="$(mktemp)"
      chmod 600 "${curl_auth_cfg}"
      printf 'user = "%s:%s"\n' "${REG_USER}" "${REG_PASS}" > "${curl_auth_cfg}"
      curl_opts+=(-K "${curl_auth_cfg}")
    fi
    curl_opts+=(-H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json")

    echo "=== verifying Pulse images in ${PUSH_URL} ==="
    for pair in \
      "mesosphere/kubectl:v1.36.2" \
      "mesosphere/nkp-pulse-management:0.5.1" \
      "mesosphere/nkp-pulse-workspace:0.5.1"; do
      repo="${pair%%:*}"
      tag="${pair##*:}"
      code="$(curl "${curl_opts[@]}" "${PUSH_URL}/v2/${repo}/manifests/${tag}" || echo "000")"
      if [ "${code}" = "200" ]; then
        echo "  [OK 200] ${IMAGE_REGISTRY}/${repo}:${tag}"
      else
        echo "  [WARN ${code}] ${IMAGE_REGISTRY}/${repo}:${tag} not verified via /v2 API" >&2
      fi
    done
    [ -n "${curl_auth_cfg}" ] && rm -f "${curl_auth_cfg}"
  fi
fi

if [ "${SKIP_JOBS}" = "true" ]; then
  echo "=== done (--skip-jobs specified) ==="
  exit 0
fi

# 3. Locate kubeconfig and fix stuck NKP Pulse Jobs / Deployments
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required to fix Job manifests" >&2; exit 1; }
if [ -z "${KC}" ]; then
  for cand in "${LAB}"/*.conf "${LAB}"/*.kubeconfig "${HOME}"/*.conf "${HOME}/.kube/config"; do
    if [ -f "${cand}" ]; then
      KC="${cand}"
      break
    fi
  done
fi
KC_ARGS=()
[ -n "${KC}" ] && [ -f "${KC}" ] && KC_ARGS=(--kubeconfig "${KC}")

echo "=== inspecting namespace ${NAMESPACE} (image registry: ${IMAGE_REGISTRY}) ==="
JOBS=()
if [ -n "${JOBS_CSV}" ]; then
  IFS=',' read -r -a JOBS <<< "${JOBS_CSV}"
else
  while IFS= read -r j; do
    [ -n "${j}" ] && JOBS+=("${j}")
  done < <(kubectl "${KC_ARGS[@]}" -n "${NAMESPACE}" get jobs -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '^nkp-pulse' || true)
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
BACKUP_DIR="${LAB}/backups/pulse-jobs-$(date -u +%Y%m%dT%H%M%SZ)"

if [ "${#JOBS[@]}" -eq 0 ]; then
  echo "no nkp-pulse* Jobs currently exist in namespace ${NAMESPACE}"
else
  for job in "${JOBS[@]}"; do
    orig_json="${WORK}/${job}.orig.json"
    fixed_yaml="${WORK}/${job}.fixed.yaml"
    if ! kubectl "${KC_ARGS[@]}" -n "${NAMESPACE}" get job "${job}" -o json > "${orig_json}" 2>/dev/null; then
      echo "  [skip] Job ${job} not found in namespace ${NAMESPACE}"
      continue
    fi
    if ! grep -qE '"image"[[:space:]]*:[[:space:]]*"(docker\.io/)?mesosphere/' "${orig_json}"; then
      echo "  [skip] Job ${job} does not reference docker.io/mesosphere/* images"
      continue
    fi
    rewrite_job_manifest "${orig_json}" "${fixed_yaml}" "${IMAGE_REGISTRY}" "${PULL_SECRET}"

    if [ "${DRY_RUN}" = "true" ]; then
      echo "=== [dry-run] fixed manifest for Job ${NAMESPACE}/${job} ==="
      cat "${fixed_yaml}"
      continue
    fi

    mkdir -p "${BACKUP_DIR}"
    kubectl "${KC_ARGS[@]}" -n "${NAMESPACE}" get job "${job}" -o yaml > "${BACKUP_DIR}/${job}.orig.yaml"
    echo "=== recreating Job ${NAMESPACE}/${job} with ${IMAGE_REGISTRY}/mesosphere/... (backup: ${BACKUP_DIR}/${job}.orig.yaml) ==="
    kubectl "${KC_ARGS[@]}" -n "${NAMESPACE}" delete job "${job}" --wait=true
    kubectl "${KC_ARGS[@]}" -n "${NAMESPACE}" apply -f "${fixed_yaml}"
    if ! kubectl "${KC_ARGS[@]}" -n "${NAMESPACE}" wait --for=condition=complete "job/${job}" --timeout=180s; then
      echo "  [WARN] Job ${job} did not complete within 180s; inspect: kubectl -n ${NAMESPACE} describe job ${job}" >&2
    fi
  done
fi

# Also patch any nkp-pulse* Deployments still referencing docker.io/mesosphere/*
while IFS= read -r dep; do
  [ -n "${dep}" ] || continue
  dep_json="${WORK}/dep-${dep}.json"
  kubectl "${KC_ARGS[@]}" -n "${NAMESPACE}" get deployment "${dep}" -o json > "${dep_json}" 2>/dev/null || continue
  patches="$(python3 - "${dep_json}" "${IMAGE_REGISTRY}" <<'PY'
import json, re, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
reg = sys.argv[2].rstrip("/")
for c in (doc.get("spec", {}).get("template", {}).get("spec", {}).get("containers") or []):
    img = c.get("image", "")
    m = re.match(r"^(?:docker\.io/)?(mesosphere/.+)$", img)
    if m:
        print(f"{c['name']}={reg}/{m.group(1)}")
PY
)"
  if [ -n "${patches}" ]; then
    if [ "${DRY_RUN}" = "true" ]; then
      echo "=== [dry-run] would patch Deployment ${NAMESPACE}/${dep}: ${patches} ==="
    else
      echo "=== patching Deployment ${NAMESPACE}/${dep} -> ${IMAGE_REGISTRY} ==="
      # shellcheck disable=SC2086
      kubectl "${KC_ARGS[@]}" -n "${NAMESPACE}" set image "deployment/${dep}" ${patches}
    fi
  fi
done < <(kubectl "${KC_ARGS[@]}" -n "${NAMESPACE}" get deployments -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '^nkp-pulse' || true)

# Optional Flux HelmRelease reconciliation
if [ "${RECONCILE}" = "true" ] && [ "${DRY_RUN}" != "true" ]; then
  for hr in nkp-pulse-management nkp-pulse-workspace; do
    if kubectl "${KC_ARGS[@]}" -n "${NAMESPACE}" get helmrelease "${hr}" >/dev/null 2>&1; then
      echo "=== reconciling HelmRelease ${NAMESPACE}/${hr} ==="
      if command -v flux >/dev/null 2>&1; then
        flux "${KC_ARGS[@]}" reconcile helmrelease "${hr}" -n "${NAMESPACE}" --force || true
      else
        kubectl "${KC_ARGS[@]}" -n "${NAMESPACE}" annotate helmrelease "${hr}" \
          "reconcile.fluxcd.io/requestedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
      fi
    fi
  done
fi

echo "=== done. Verify with: kubectl -n ${NAMESPACE} get jobs,pods,helmreleases | grep pulse ==="
