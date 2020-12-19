#!/bin/bash
#shellcheck disable=SC2086,SC2001
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

[[ ! -f ${BLOCKLOG_DB} ]] && echo "${FG_RED}ERROR:${NC} blocklog db missing, please run 'cncli.sh init' to create and initialize it" && exit 1

getEpoch() {
  data=$(curl -s -m ${EKG_TIMEOUT} -H 'Accept: application/json' "http://${EKG_HOST}:${EKG_PORT}/" 2>/dev/null)
  jq -er '.cardano.node.ChainDB.metrics.epoch.int.val //0' <<< "${data}"
}

echo "~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "~~ LOG MONITOR STARTED ~~"
echo "monitoring ${logfile} for traces"

# Continuously parse cardano-node json log file for traces
while read -r logentry; do
  # Traces monitored: TraceNodeIsLeader, TraceAdoptedBlock, TraceForgedInvalidBlock
  case "${logentry}" in
    *TraceNodeIsLeader* )
      if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceNodeIsLeader]: invalid json schema, '.at' not found" && continue; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
      if ! slot="$(jq -er '.data.val.slot' <<< ${logentry})"; then echo "ERROR[TraceNodeIsLeader]: invalid json schema, '.data.val.slot' not found" && continue; fi
      if ! epoch=$(getEpoch); then echo "ERROR[TraceNodeIsLeader]: failed to grab current epoch number from EKG metrics" && continue; fi
      echo "LEADER: epoch[${epoch}] slot[${slot}] at[${at}]"
      sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO blocklog (slot,at,epoch,status) values (${slot},'${at}',${epoch},'leader');"
      ;;
    *TraceAdoptedBlock* )
      if ! slot="$(jq -er '.data.val.slot' <<< ${logentry})"; then echo "ERROR[TraceAdoptedBlock]: invalid json schema, '.data.val.slot' not found" && continue; fi
      if ! hash="$(jq -er '.data.val.blockHash' <<< ${logentry})"; then echo "ERROR[TraceAdoptedBlock]: invalid json schema, '.data.val.blockHash' not found" && continue; fi
      if ! size="$(jq -er '.data.val.blockSize' <<< ${logentry})"; then echo "ERROR[TraceAdoptedBlock]: invalid json schema, '.data.val.blockSize' not found" && continue; fi
      echo "ADOPTED: slot[${slot}] size=${size} hash=${hash}"
      sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'adopted', size = ${size}, hash = '${hash}' WHERE slot = ${slot};"
      ;;
    *TraceForgedInvalidBlock* )
      if ! slot="$(jq -er '.data.val.slot' <<< ${logentry})"; then echo "ERROR[TraceForgedInvalidBlock]: invalid json schema, '.data.val.slot' not found" && continue; fi
      json_trace="$(jq -c -r '. | @base64' <<< ${logentry})"
      echo "INVALID: slot[${slot}] - base 64 encoded json trace, run this command to decode:"
      echo "echo ${json_trace} | base64 -d | jq -r"
      sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'invalid', hash = '${json_trace}' WHERE slot = ${slot};"
      ;;
    * ) : ;; # ignore
  esac
done < <(tail -F -n0 "${logfile}")