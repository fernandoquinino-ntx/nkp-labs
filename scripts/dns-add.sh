#!/usr/bin/env bash
# dns-add.sh — add/remove a DNS A record for the ingress lab (lab 04) when there's no wildcard.
# Uses `nsupdate` against a DYNAMIC BIND zone (file edits + `rndc reload` are ignored there).
#
# Usage:
#   NAME=apache.apps.example.com IP=<ingress-LB-IP> ./scripts/dns-add.sh          # add
#   RSH=you@<dns-server> NAME=apache.apps.example.com IP=<LB> ./scripts/dns-add.sh # run nsupdate on the server
#   ACTION=delete NAME=apache.apps.example.com ./scripts/dns-add.sh
#   ACTION=show   NAME=apache.apps.example.com ./scripts/dns-add.sh
#   # or set DNS_SERVER / DNS_ZONE in local.env and just run it
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
[ -f "$ROOT/local.env" ] && { set -a; . "$ROOT/local.env"; set +a; } || true

NAME="${NAME:?set NAME (e.g. apache.apps.example.com)}"
IP="${IP:-}"
DNS_SERVER="${DNS_SERVER:?set DNS_SERVER (or in local.env)}"
ZONE="${DNS_ZONE:-${ZONE:-}}"
TTL="${TTL:-300}"
ACTION="${ACTION:-add}"
RSH="${RSH:-}"

case "$ACTION" in
  add)    [ -n "$IP" ] || { echo "set IP for ACTION=add" >&2; exit 2; }; update="update add ${NAME} ${TTL} A ${IP}" ;;
  delete) update="update delete ${NAME} A" ;;
  show)   update="" ;;
  *) echo "ACTION must be add|delete|show" >&2; exit 2 ;;
esac

echo ">> ${ACTION}  ${NAME}${IP:+ ${IP}}   (server ${DNS_SERVER}${ZONE:+, zone ${ZONE}})"
if [ "$ACTION" != "show" ]; then
  NF="$(mktemp)"; trap 'rm -f "$NF"' EXIT
  { echo "server ${DNS_SERVER}"; [ -n "$ZONE" ] && echo "zone ${ZONE}"; echo "$update"; echo "send"; } > "$NF"
  sed 's/^/   /' "$NF"
  if [ -n "$RSH" ]; then ssh -o StrictHostKeyChecking=no "$RSH" "sudo nsupdate -v" < "$NF"; else sudo nsupdate -v < "$NF"; fi
fi

echo ">> verify:"; getent hosts "$NAME" || true
