#!/bin/bash
# shellcheck disable=SC1090,SC2086

# get common env variables
. "$(dirname $0)"/env

# get cntools config parameters
. "$(dirname $0)"/cntools.config

# get cntools helper functions
. "$(dirname $0)"/cntools.library

# get log file from config file specified in env
unset logfile
if [[ "${CONFIG##*.}" = "yaml" ]]; then
  [[ $(grep "scName.*\.json" "${CONFIG}") =~ scName:.\"(.+\.json)\" ]] && logfile="${BASH_REMATCH[1]}"
elif [[ "${CONFIG##*.}" = "json" ]]; then
  logfile=$(jq -r '.setupScribes[] | select (.scFormat == "ScJson") | .scName' "${CONFIG}")
fi
[[ -z "${logfile}" ]] && echo -e "${RED}Error:${NC} Failed to locate json logfile in node configuration file\na setupScribe of format ScJson with extension .json expected" && exit 1

# Create temp dir if needed
if [[ -z "${TMP_FOLDER}" ]]; then
  echo -e "${RED}Error:${NC} Temp directory not set in cntools.config!" && exit 1
elif [[ ! -d "${TMP_FOLDER}" ]];then
  mkdir -p "${TMP_FOLDER}" || { 
    echo -e "${RED}Error:${NC} Failed to create cntools temp directory: ${TMP_FOLDER}"
    exit 1
  }
fi

# Create BLOCK_LOG_DIR if needed
if [[ -z "${BLOCK_LOG_DIR}" ]]; then
  echo -e "${RED}Error:${NC} 'BLOCK_LOG_DIR' not configured in cntools.config" && exit 1
elif [[ ! -d "${BLOCK_LOG_DIR}" ]];then
  mkdir -p "${BLOCK_LOG_DIR}" || {
    echo -e "${RED}Error:${NC} Failed to create 'BLOCK_LOG_DIR' directory: ${BLOCK_LOG_DIR}"
    exit 1
  }
fi

echo " "
echo " ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo " ~~ BLOCK COLLECTOR STARTED ~~"
echo "monitoring json logfile for block traces"

# Continuously parse cardano-node json log file for block traces
while read -r logentry; do
  if grep -q "TraceNodeIsLeader" <<< "${logentry}"; then
    at="$(jq -r '.at' <<< ${logentry})"
    at_local="$(date '+%F_%T_%Z' -d "${at}")"
    slot="$(jq -r '.data.slot' <<< ${logentry})"
    epoch=$(getEpoch)
    # create epoch block file if missing
    blocks_file="${BLOCK_LOG_DIR}/blocks_${epoch}.json"
    [[ ! -f "${blocks_file}" ]] && echo "[]" > "${blocks_file}"
    echo " "
    echo " ~~ LEADER EVENT ~~"
    printTable ',' "Epoch,Slot,At\n${epoch},${slot},${at_local}"
    # check if entry already exist, bug noticed at log rollover that block traces can repeat
    slot_search=$(jq --arg _slot "${slot}" '.[] | select(.slot == $_slot)' "${blocks_file}")
    if [[ -n ${slot_search} ]]; then
      echo "Duplicate slot entry, already added from previous leader trace, skipping"
    else
      jq --arg _at "${at}" \
      --arg _slot "${slot}" \
      '. += [{"at": $_at,"slot": $_slot}]' \
      "${blocks_file}" > "${TMP_FOLDER}/blocks.json" && mv -f "${TMP_FOLDER}/blocks.json" "${blocks_file}"
    fi
  elif grep -q "TraceAdoptedBlock" <<< "${logentry}"; then
    slot="$(jq -r '.data.slot' <<< ${logentry})"
    [[ "$(jq -r '.data.blockHash' <<< ${logentry})" =~ ([[:alnum:]]+) ]] && block_hash="${BASH_REMATCH[1]}" || block_hash=""
    block_size="$(jq -r '.data.blockSize' <<< ${logentry})"
    epoch=$(( slot / $(jq -r .epochLength "${GENESIS_JSON}") ))
    echo " ~~ ADOPTED BLOCK ~~"
    printTable ',' "Size,Hash\n${block_size},${block_hash}"
    jq --arg _slot "${slot}" \
    --arg _block_size "${block_size}" \
    --arg _block_hash "${block_hash}" \
    '[.[] | select(.slot == $_slot) += {"size": $_block_size,"hash": $_block_hash}]' \
    "${blocks_file}" > "${TMP_FOLDER}/blocks.json" && mv -f "${TMP_FOLDER}/blocks.json" "${blocks_file}"
  elif grep -q "TraceForgedInvalidBlock" <<< "${logentry}"; then
    slot="$(jq -r '.data.slot' <<< ${logentry})"
    epoch=$(( slot / $(jq -r .epochLength "${GENESIS_JSON}") ))
    echo " ~~ INVALID BLOCK ~~"
    echo "Base 64 encoded json trace"
    echo -e "run this command to decode:\necho ${logentry} | base64 -d | jq -r"
    jq --arg _slot "${slot}" \
    --arg _json_trace "Invalid Block (base64 enc json): $(jq -c -r '. | @base64' <<< ${logentry})" \
    '[.[] | select(.slot == $_slot) += {"hash": $_json_trace}]' \
    "${blocks_file}" > "${TMP_FOLDER}/blocks.json" && mv -f "${TMP_FOLDER}/blocks.json" "${blocks_file}"
  fi
done < <(tail -F -n0 "${logfile}")