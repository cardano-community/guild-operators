#!/bin/bash

# get common env variables
. "$(dirname $0)"/env

# get cntools config parameters
. "$(dirname $0)"/cntools.config

# get log file from config file specified in env
[[ $(grep scName.*\.json "${CONFIG}") =~ scName:.\"(.+\.json)\" ]] && logfile="${BASH_REMATCH[1]}" || logfile=""

[[ -z "${logfile}" ]] && say "${RED}Error:${NC} Failed to locate json logfile in node configuration file\na setupScribe of format ScJson with extension .json expected" && exit 1

[[ -z "${BLOCK_LOG_FILE}" ]] && say "${RED}Error:${NC} 'BLOCK_LOG_FILE' not configured in cntools.config" && exit 1

# create BLOCK_LOG_FILE if missing
[[ ! -f "${BLOCK_LOG_FILE}" ]] && echo "[]" > "${BLOCK_LOG_FILE}"

echo " ~~ BLOCK COLLECTOR ~~"
echo "monitoring nodes json logfile for blocks (TraceAdoptedBlock)"

# Continuously parse cardano-node json log file for block traces
while read logentry; do
  _jq() {
    echo ${logentry} | base64 --decode | jq -r "${1}"
  }
  if [[ $(_jq '.data.kind') = "TraceAdoptedBlock" ]]; then
    # extract important parts
    at="$(_jq '.at')"
    at_local="$(date -d ${at})"
    slot="$(_jq '.data.slot')"
    [[ "$(_jq '.data."block hash"')" =~ unHashHeader.=.([[:alnum:]]+) ]] && block_hash="${BASH_REMATCH[1]}" || block_hash=""
    epoch=$(( slot / $(jq -r .epochLength ${GENESIS_JSON}) ))
    echo -e "\n ~~ NEW BLOCK ~~"
    echo "at    : ${at_local}"
    echo "epoch : ${epoch}"
    echo "slot  : ${slot}"
    echo "hash  : ${block_hash}"
    cat <<< $( \
    jq --arg _at ${at} \
    --arg _epoch ${epoch} \
    --arg _slot ${slot} \
    --arg _block_hash ${block_hash} \
    '. += [{"at": $_at,"epoch": $_epoch,"slot": $_slot,"hash": $_block_hash}]' "${BLOCK_LOG_FILE}" ) > "${BLOCK_LOG_FILE}"
  fi
done < <(tail -F -n0 "${logfile}" | jq -c -r '. | @base64')