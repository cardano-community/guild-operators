#!/bin/bash
# shellcheck disable=SC1090,SC2086

# get common env variables
. "$(dirname $0)"/env

# get cntools config parameters
. "$(dirname $0)"/cntools.config

# get log file from config file specified in env
unset logfile
if [[ "${CONFIG##*.}" = "yaml" ]]; then
  [[ $(grep "scName.*\.json" "${CONFIG}") =~ scName:.\"(.+\.json)\" ]] && logfile="${BASH_REMATCH[1]}"
elif [[ "${CONFIG##*.}" = "json" ]]; then
  jq -r '.setupScribes[] | select (.scFormat == "ScJson") | .scName' "${CONFIG}"
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

echo " ~~ BLOCK COLLECTOR ~~"
echo "monitoring json logfile for blocks (TraceAdoptedBlock)"

# Continuously parse cardano-node json log file for block traces
while read -r logentry; do
  _jq() {
    echo "${logentry}" | base64 --decode | jq -r "${1}"
  }
  if [[ $(_jq '.data.kind') = "TraceAdoptedBlock" ]]; then
    # extract important parts
    at="$(_jq '.at')"
    at_local="$(date '+%F %T %Z' -d "${at}")"
    slot="$(_jq '.data.slot')"
    [[ "$(_jq '.data."block hash"')" =~ unHashHeader.=.([[:alnum:]]+) ]] && block_hash="${BASH_REMATCH[1]}" || block_hash=""
    block_size="$(_jq '.data."block size"')"
    epoch=$(( slot / $(jq -r .epochLength "${GENESIS_JSON}") ))
    # create epoch block file if missing
    blocks_file="${BLOCK_LOG_DIR}/blocks_${epoch}.json"
    [[ ! -f "${blocks_file}" ]] && echo "[]" > "${blocks_file}"
    echo -e "\n ~~ NEW BLOCK ~~"
    echo "at    : ${at_local}"
    echo "epoch : ${epoch}"
    echo "slot  : ${slot}"
    echo "hash  : ${block_hash}"
    echo "size  : ${block_size}"
    jq --arg _at "${at}" \
    --arg _slot "${slot}" \
    --arg _block_hash "${block_hash}" \
    --arg _block_size "${block_size}" \
    '. += [{"at": $_at,"slot": $_slot,"size": $_block_size,"hash": $_block_hash}]' \
    "${blocks_file}" > "${TMP_FOLDER}/blocks.json" && mv -f "${TMP_FOLDER}/blocks.json" "${blocks_file}"
  fi
done < <(tail -F -n0 "${logfile}" | jq -c -r '. | @base64')