#!/usr/bin/env bash

PARENT="$(dirname $0)"
. "${PARENT}"/env offline
function usage() {
  echo -e "\nUsage: $(basename "$0") <haproxy IP> <haproxy port> <server IP> <server port>\n"
  echo -e "Polling script used by haproxy to query server IP at server Port, and check that slot is almost on tip\n\n"
  exit 1
}

if [[ $# -ne 4 ]]; then
  usage
fi

haproxy_ip="${1}"
haproxy_port="${2}"
server="${3}"
port="${4}"
dbtip=$(curl -f -s "http://${3}:${4}/block?select=slot_no&order=slot_no.desc.nullslast&limit=1" 2>/dev/null | jq -r .[0].slot_no)
currtip=$(getSlotTipRef)
if [[ -n "{dbtip}" ]] || [[ -n "${currtip}" ]]; then
  [[ $(( currtip - dbtip )) -lt 120 ]] && exit 0 || exit 1
else
  exit 1
fi
