#!/bin/bash
#shellcheck disable=SC2086
#shellcheck source=/dev/null

######################################
# Do NOT modify code below           #
######################################

PARENT="$(dirname $0)"
if [[ ! -f "${PARENT}"/env ]]; then
  echo "ERROR: could not find common env file, please run prereqs.sh or manually download"
  exit 1
fi
if ! . "${PARENT}"/env; then exit 1; fi

# get log file from config file specified in env
unset logfile
if [[ "${CONFIG##*.}" = "yaml" ]]; then
  [[ $(grep "scName.*\.json" "${CONFIG}") =~ scName:.\"(.+\.json)\" ]] && logfile="${BASH_REMATCH[1]}"
elif [[ "${CONFIG##*.}" = "json" ]]; then
  logfile=$(jq -r '.setupScribes[] | select (.scFormat == "ScJson") | .scName' "${CONFIG}")
fi
[[ -z "${logfile}" ]] && echo -e "${FG_RED}ERROR:${NC} failed to locate json logfile in node configuration file\na setupScribe of format ScJson with extension .json expected" && exit 1

createBlocklogDB || exit 1 # create db if needed

getEpoch() {
  data=$(curl -s -m ${EKG_TIMEOUT} -H 'Accept: application/json' "http://${EKG_HOST}:${EKG_PORT}/" 2>/dev/null)
  jq '.cardano.node.ChainDB.metrics.epoch.int.val //0' <<< "${data}"
}

echo "~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "~~ LOG MONITOR STARTED ~~"
echo "monitoring ${logfile} for traces"

# Continuously parse cardano-node json log file for traces
while read -r logentry; do
  # Traces monitored: TraceNodeIsLeader, TraceAdoptedBlock, TraceForgedInvalidBlock
  case "${logentry}" in
    *TraceNodeIsLeader* )
      at="$(jq -r '.at' <<< ${logentry} | sed 's/\.[0-9]\{2\}Z/+00:00/')"
      slot="$(jq -r '.data.slot' <<< ${logentry})"
      epoch=$(getEpoch)
      echo "LEADER: epoch[${epoch}] slot[${slot}] at[${at}]"
      sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO blocklog (slot,at,epoch,status) values (${slot},'${at}',${epoch},'leader');"
      ;;
    *TraceAdoptedBlock* )
      slot="$(jq -r '.data.slot' <<< ${logentry})"
      [[ "$(jq -r '.data.blockHash' <<< ${logentry})" =~ ([[:alnum:]]+) ]] && hash="${BASH_REMATCH[1]}" || hash=""
      size="$(jq -r '.data.blockSize' <<< ${logentry})"
      echo "ADOPTED: slot[${slot}] size=${size} hash=${hash}"
      sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'adopted', size = ${size}, hash = '${hash}' WHERE slot = ${slot};"
      ;;
    *TraceForgedInvalidBlock* )
      slot="$(jq -r '.data.slot' <<< ${logentry})"
      json_trace="$(jq -c -r '. | @base64' <<< ${logentry})"
      echo "INVALID: slot[${slot}] - base 64 encoded json trace, run this command to decode:"
      echo "echo ${json_trace} | base64 -d | jq -r"
      sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'invalid', hash = '${json_trace}' WHERE slot = ${slot};"
      ;;
    * ) : ;; # ignore
  esac
done < <(tail -F -n0 "${logfile}")