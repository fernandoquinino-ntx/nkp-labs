#!/usr/bin/env bash
# render.sh <lab-dir|all> — substitute ${PLACEHOLDERS} from local.env into rendered/<lab>/.
# Recurses into subdirectories (e.g. a lab's "alternative" manifests) so they render too.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/local.env}"
OUT="$ROOT/rendered"

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE — copy local.env.example to local.env and edit it" >&2; exit 1; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "usage: $0 <lab-dir|all>   e.g. $0 01-pvc-rwx-busybox" >&2; exit 1; }

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

KEYS="NAMESPACE RWX_STORAGE_CLASS PVC_SIZE DOMAIN APP_HOST INGRESS_CLASS REPLICAS SA_NAME VELERO_NS DNS_SERVER DNS_ZONE OTEL_NAMESPACE OTEL_RELEASE CHART_VERSION SPLUNK_CLUSTER_NAME SPLUNK_HEC_ENDPOINT SPLUNK_HEC_TOKEN SPLUNK_INDEX SPLUNK_METRICS_INDEX OIDC_HOST OIDC_PLUGIN_VERSION TRAEFIK_NS OKTA_ISSUER OKTA_CLIENT_ID OKTA_CLIENT_SECRET OIDC_SESSION_KEY OIDC_ALLOWED_DOMAINS OIDC_ALLOWED_GROUPS VAULT_NAMESPACE VAULT_RELEASE VAULT_HOST VAULT_STORAGE_CLASS VAULT_REPLICAS VAULT_APP_VERSION WORKLOAD_CLUSTER WORKSPACE_NS ESO_APP_ID ESO_APP_VERSION ESO_CLUSTERAPP ESO_OVERRIDES_CM ESO_NAMESPACE ESO_SA SECRETSTORE_NAME EXTERNAL_SECRET_NAME VAULT_SERVER VAULT_CA_BUNDLE VAULT_AUTH_MOUNT VAULT_ROLE VAULT_POLICY VAULT_KV_MOUNT VAULT_SECRET_PATH VAULT_USERNAME VAULT_PASSWORD DEMO_IMAGE"

rm -rf "$OUT"; mkdir -p "$OUT"
if [ "$TARGET" = "all" ]; then mapfile -t LABS < <(cd "$ROOT" && ls -d [0-9][0-9]-*/ 2>/dev/null); else mapfile -t LABS < <(echo "${TARGET%/}/"); fi

for d in "${LABS[@]}"; do
  src="$ROOT/${d%/}"; [ -d "$src" ] || { echo "no such lab: $src" >&2; exit 1; }
  lab="$(basename "$src")"
  while IFS= read -r f; do
    rel="${f#"$src"/}"; out="$OUT/$lab/$rel"; mkdir -p "$(dirname "$out")"
    cp "$f" "$out"
    for key in $KEYS; do
      val="${!key:-}"; [ -n "$val" ] || continue
      sed -i "s|\${${key}}|${val}|g" "$out"
    done
  done < <(find "$src" -type f -name '*.yaml' | sort)
done
echo "rendered -> $OUT"
