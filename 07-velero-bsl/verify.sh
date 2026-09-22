#!/usr/bin/env bash
# verify.sh — inspect the Velero Backups Storage Locations + Schedules and run a smoke-test backup.
#
# Read-only except for creating one small test Backup (delete it afterwards).
#
# NOTE: `kubectl get backup` is AMBIGUOUS when both `backups.velero.io` and
# `backups.postgresql.cnpg.io` exist — always use the FULLY-QUALIFIED names here.
#
# Usage: NS=<velero-ns> ./verify.sh        # default ns from local.env VELERO_NS, else kommander
#        BACKUP=0 NS=kommander ./verify.sh  # skip the smoke-test backup
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
[ -f "$ROOT/local.env" ] && { set -a; . "$ROOT/local.env"; set +a; } || true
NS="${NS:-${VELERO_NS:-kommander}}"
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

BSL=backupstoragelocations.velero.io
SCH=schedules.velero.io
BK=backups.velero.io

echo "== Velero pod (ns $NS) =="
kubectl -n "$NS" get pods 2>/dev/null | grep -i velero || echo "  (none in $NS — pick the ns where Velero runs)"
echo
echo "== BackupStorageLocations =="
kubectl -n "$NS" get "$BSL" 2>/dev/null || kubectl get "$BSL" -A 2>/dev/null || echo "  (none)"
echo
echo "== Schedules =="
kubectl -n "$NS" get "$SCH" 2>/dev/null || echo "  (none)"
echo
echo "== Recent Backups (velero.io) =="
kubectl -n "$NS" get "$BK" 2>/dev/null | tail -8 || echo "  (none)"

[ "${BACKUP:-1}" = 0 ] && { echo; echo "(BACKUP=0 — skipping the smoke test)"; exit 0; }

DEF="$(kubectl -n "$NS" get "$BSL" -o jsonpath='{range .items[?(@.spec.default==true)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)"
DEF="${DEF:-default}"
B="lab-test-$(date +%s)"
echo
echo "== smoke test: $BK/$B (storageLocation=$DEF) =="
kubectl -n "$NS" apply -f - <<YAML
apiVersion: velero.io/v1
kind: Backup
metadata: { name: $B, namespace: $NS }
spec:
  includedNamespaces: ["$NS"]
  snapshotVolumes: false
  ttl: 24h
  storageLocation: $DEF
YAML
for i in $(seq 1 24); do
  ph="$(kubectl -n "$NS" get "$BK" "$B" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  echo "  ${i}: ${ph:-<pending>}"
  case "$ph" in Completed|PartiallyFailed|Failed|ValidationFailed) break ;; esac
  sleep 5
done
echo
kubectl -n "$NS" get "$BK" "$B" 2>/dev/null
echo "clean up with:  kubectl -n $NS delete $BK $B"
