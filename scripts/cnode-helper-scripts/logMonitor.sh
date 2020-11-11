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
[[ -z "${logfile}" ]] && echo -e "${FG_RED}Error:${NC} failed to locate json logfile in node configuration file\na setupScribe of format ScJson with extension .json expected" && exit 1

# Create BLOCKLOG_DIR if needed
if ! mkdir -p "${BLOCKLOG_DIR}"; then echo "ERROR: failed to create directory to store blocklog: ${BLOCKLOG_DIR}" && exit 1; fi

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
      at="$(jq -r '.at' <<< ${logentry})"
      slot="$(jq -r '.data.slot' <<< ${logentry})"
      epoch=$(getEpoch)
      blocks_file="${BLOCKLOG_DIR}/blocks_${epoch}.json"
      [[ ! -f "${blocks_file}" ]] && echo "[]" > "${blocks_file}"
      echo "leader event [epoch=${epoch},slot=${slot},at=${at}]"
      slot_search=$(jq --arg _slot "${slot}" '.[] | select(.slot == $_slot)' "${blocks_file}")
      if [[ -n ${slot_search} ]]; then
        echo "duplicate slot entry, skipping"
      else
        jq --arg _at "${at}" \
        --arg _slot "${slot}" \
        '. += [{"at": $_at,"slot": $_slot,"status": "leader"}]' \
        "${blocks_file}" > "/tmp/blocks.json" && mv -f "/tmp/blocks.json" "${blocks_file}"
      fi
      ;;
    *TraceAdoptedBlock* )
      slot="$(jq -r '.data.slot' <<< ${logentry})"
      [[ "$(jq -r '.data.blockHash' <<< ${logentry})" =~ ([[:alnum:]]+) ]] && block_hash="${BASH_REMATCH[1]}" || block_hash=""
      block_size="$(jq -r '.data.blockSize' <<< ${logentry})"
      epoch=$(getEpoch)
      blocks_file="${BLOCKLOG_DIR}/blocks_${epoch}.json"
      echo "block adopted [epoch=${epoch},slot=${slot},size=${block_size},hash=${block_hash}]"
      jq --arg _slot "${slot}" \
      --arg _block_size "${block_size}" \
      --arg _block_hash "${block_hash}" \
      '[.[] | select(.slot == $_slot) += {"size": $_block_size,"hash": $_block_hash,"status": "adopted"}]' \
      "${blocks_file}" > "/tmp/blocks.json" && mv -f "/tmp/blocks.json" "${blocks_file}"
      ;;
    *TraceForgedInvalidBlock* )
      slot="$(jq -r '.data.slot' <<< ${logentry})"
      json_trace="$(jq -c -r '. | @base64' <<< ${logentry})"
      epoch=$(getEpoch)
      blocks_file="${BLOCKLOG_DIR}/blocks_${epoch}.json"
      echo "invalid block [epoch=${epoch},slot=${slot}]"
      echo "base 64 encoded json trace, run this command to decode:"
      echo "echo ${json_trace} | base64 -d | jq -r"
      jq --arg _slot "${slot}" \
      --arg _json_trace "base64: ${json_trace}" \
      '[.[] | select(.slot == $_slot) += {"hash": $_json_trace,"status": "invalid"}}]' \
      "${blocks_file}" > "${TMP_FOLDER}/blocks.json" && mv -f "${TMP_FOLDER}/blocks.json" "${blocks_file}"
      ;;
    * ) : ;; # ignore
  esac
done < <(tail -F -n0 "${logfile}")