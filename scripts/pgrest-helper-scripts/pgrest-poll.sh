#!/usr/bin/env bash

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
dbtip=$(curl -f -H "Accept: text/plain" "http://${3}:${4}/epoch?select=end_time::text&order=id.desc.nullslast&limit=1" 2>/dev/null)
currtip=$(TZ='UTC' date "+%Y-%m-%d %H:%M:%S")
echo ${dbtip} - ${currtip}
if [[ -n "{dbtip}" ]] ; then
  [[ $(( $(date -d "${currtip}" +%s) - $(date -d "${dbtip}" +%s) )) -lt 120 ]] && exit 0 || exit 2
else
  exit 1
fi
