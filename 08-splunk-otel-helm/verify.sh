#!/usr/bin/env bash
# verify.sh — check the Splunk OTel Collector end to end, and explain what is wrong.
#
# Read-only. It checks, in order:
#   1. the Helm release / workloads exist and are ready
#   2. whether the collector is DROPPING data (bad index/token)
#   3. the collector's OWN counters — the ground truth ("no drops" != healthy!)
#   4. a live HEC probe for BOTH indexes with your token (needs curl)
#   5. the SPL to run in the Splunk UI
#
# Usage: ./08-splunk-otel-helm/verify.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
[ -f "$ROOT/local.env" ] && { set -a; . "$ROOT/local.env"; set +a; } || true
NS="${OTEL_NAMESPACE:-splunk-otel}"
REL="${OTEL_RELEASE:-splunk-otel-collector}"
IDX="${SPLUNK_INDEX:-k8s_logs}"
MIDX="${SPLUNK_METRICS_INDEX:-k8s_metrics}"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
FAIL=0

echo "=============================================================="
echo " Splunk OTel Collector verification   ns=$NS  release=$REL"
echo "=============================================================="

echo
echo "== 1. workloads =="
if command -v helm >/dev/null; then
  helm -n "$NS" list 2>/dev/null | grep -E "NAME|$REL" || echo "  (no Helm release named $REL in $NS)"
  echo
fi
kubectl -n "$NS" get ds,deploy 2>/dev/null || echo "  (nothing in ns $NS — did you install?)"
echo
kubectl -n "$NS" get pods -o wide 2>/dev/null | head -12

NOTREADY="$(kubectl -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[*].ready}{"\n"}{end}' 2>/dev/null | grep -c 'false' || true)"
[ "${NOTREADY:-0}" = "0" ] || { echo "  !! $NOTREADY pod(s) not Ready"; FAIL=1; }

echo
echo "== 2. is data being DROPPED? (bad index / bad token) =="
DROPS="$(kubectl -n "$NS" logs -l app=splunk-otel-collector --tail=3000 --since=15m 2>/dev/null | grep -c 'Dropping data' || true)"
echo "  'Dropping data' lines in the last 15m: $DROPS"
if [ "${DROPS:-0}" != "0" ]; then
  FAIL=1
  echo "  !! DROPS DETECTED. The reason is in the same lines:"
  kubectl -n "$NS" logs -l app=splunk-otel-collector --tail=3000 --since=15m 2>/dev/null \
    | grep 'Dropping data' | tail -1 | grep -oE 'HTTP[^"]*|x509[^"]*|Incorrect index|Forbidden' | sed 's/^/     /' || true
  echo "     - HTTP 400 \"Incorrect index\" -> add the index to the HEC token's allowed list"
  echo "     - HTTP 403 \"Forbidden\"        -> wrong/stale token; fix it and restart the DaemonSet"
fi

echo
echo "== 3. collector counters (the real 'is it working?') =="
POD="$(kubectl -n "$NS" get pod -l app=splunk-otel-collector -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "$POD" ]; then
  kubectl -n "$NS" port-forward "pod/$POD" 18889:8889 >/dev/null 2>&1 &
  PF=$!; sleep 3
  METRICS="$(curl -s --max-time 8 localhost:18889/metrics 2>/dev/null || true)"
  kill "$PF" >/dev/null 2>&1 || true
  if [ -n "$METRICS" ]; then
    echo "  agent $POD"
    echo "$METRICS" | grep -E 'otelcol_receiver_accepted_log_records|otelcol_receiver_accepted_metric_points' | grep -v '^#' | sed 's/^/    /'
    echo "  failures (should be absent/zero):"
    echo "$METRICS" | grep -E 'otelcol_exporter_send_failed' | grep -v '^#' | sed 's/^/    /' || echo "    (none)"
    # the kubelet trap: 0 points + 0 errors, no drops
    if echo "$METRICS" | grep -q 'receiver="kubelet_stats"' && ! echo "$METRICS" | grep -qE 'receiver="kubelet_stats"[^}]*\} [1-9]'; then
      FAIL=1
      echo "  !! kubelet_stats accepted 0 points -> see the kubelet TLS fix in values.example.yaml"
      echo "     (kubectl -n $NS logs -l app=splunk-otel-collector | grep 'IP SAN')"
    fi
  else
    echo "  (could not read :8889 — port-forward blocked? the rest of the checks still apply)"
  fi
else
  echo "  (no agent pod found)"
  FAIL=1
fi

echo
echo "== 4. HEC probe with your token (needs curl) =="
if command -v curl >/dev/null; then
  for I in "$IDX" "$MIDX"; do
    printf "  index=%-14s -> " "$I"
    curl -sk --max-time 15 -H "Authorization: Splunk ${SPLUNK_HEC_TOKEN:-}" \
      -d "{\"event\":\"lab-verify\",\"index\":\"$I\"}" "${SPLUNK_HEC_ENDPOINT:-}" || echo "(curl failed)"
    echo
  done
  echo "  want {\"text\":\"Success\",\"code\":0}. 'Incorrect index' => fix the token's allowed indexes."
else
  echo "  (curl not installed — run the probe from the README)"
fi

echo
echo "== 5. search in the Splunk UI (https://<stack>.splunkcloud.com) =="
cat <<SPL
    index=$IDX earliest=-15m | stats count by k8s.cluster.name
    index=$IDX sourcetype=kube:journald:* earliest=-15m | head 20
    index=$IDX sourcetype=kube:kernel earliest=-15m | head 20
    | mcatalog values(metric_name) WHERE index=$MIDX
    | mstats avg(_value) WHERE index=$MIDX metric_name="k8s.node.condition_ready" span=1m
SPL

echo
if [ "$FAIL" = 0 ]; then
  echo "RESULT: checks passed (also confirm it in the Splunk UI above)."
else
  echo "RESULT: problems found — see the hints above and the lab README section 'Troubleshooting'."
fi
exit "$FAIL"
