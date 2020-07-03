#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2086,SC2206,SC2015,SC2154
function usage() {
  printf "\n%s\n\n" "Usage: $(basename "$0") <Destination Address> <Amount> <Source Address> <Source Sign Key> [--include-fee]"
  printf "  %-20s\t%s\n" \
    "Destination Address" "Address or path to Address file." \
    "Amount" "Amount in ADA, number(fraction of ADA valid) or the string 'all'." \
    "Source Address" "Address or path to Address file." \
    "Source Sign Key" "Path to Signature (skey) file. For staking address payment skey is to be used." \
    "--include-fee" "Optional argument to specify that amount to send should be reduced by fee instead of payed by sender."
  printf "\n"
  exit 1
}

if [[ $# -lt 4 ]]; then
  usage
fi

# source env
. "$(dirname $0)"/env
. "$(dirname $0)"/cntools.library
. "$(dirname $0)"/cntools.config

# create temporary directory if missing
mkdir -p "${TMP_FOLDER}" # Create if missing
if [[ ! -d "${TMP_FOLDER}" ]]; then
  echo ""
  say "${RED}ERROR${NC}: Failed to create directory for temporary files:"
  say "${TMP_FOLDER}"
  echo "" && exit 1
fi

# start with a clean slate
rm -f "${TMP_FOLDER}"/*

# Get protocol parameters and save to ${TMP_FOLDER}/protparams.json
${CCLI} shelley query protocol-parameters --testnet-magic ${NWMAGIC} --out-file ${TMP_FOLDER}/protparams.json || {
  echo ""
  say "${RED}ERROR${NC}: failed to query protocol parameters, node running and env parameters correct?"
  exit 1
}

# Handle script arguments
if [[ ! -f "$1" ]]; then
  D_ADDR="$1"
else
  D_ADDR="$(cat $1)"
fi

LOVELACE="$2"
re_number='^[0-9]+([.][0-9]+)?$'
if [[ ${LOVELACE} =~ ${re_number} ]]; then
  # /1 is to remove decimals from bc command
  LOVELACE=$(echo "${LOVELACE} * 1000000 / 1" | bc)
elif [[ ${LOVELACE} != "all" ]]; then
  say "${RED}ERROR${NC}: 'Amount in ADA' must be a valid number or the string 'all'"
  echo "" && exit 1
fi

if [[ ! -f "$3" ]]; then
  S_ADDR="$3"
else
  S_ADDR="$(cat $3)"
fi

if [[ -f "$4" ]]; then 
  S_SKEY="$4" 
else
  say "${RED}ERROR${NC}: Source Sign file(skey) not found!"
  say "$4"
  echo "" && exit 1
fi

if [[ $# -eq 5 ]]; then
  [[ $5 = "--include-fee" ]] && INCL_FEE="yes" || usage
else
  INCL_FEE="no"
fi

getBalance ${S_ADDR}
if [[ ${base_lovelace} -gt 0 ]]; then
  say "$(printf "\n%s\t${CYAN}%s${NC} ADA" "Funds in source wallet:"  "$(numfmt --grouping ${base_ada})")" "log"
else
  say "${RED}ERROR${NC}: no funds available in source address"
  echo "" && exit 1
fi

if ! sendADA "${D_ADDR}" "${LOVELACE}" "${S_ADDR}" "${S_SKEY}" "${INCL_FEE}"; then
  echo "" && exit 1
fi

if ! waitNewBlockCreated; then
  echo "" && exit 1
fi

getBalance ${S_ADDR}

while [[ ${base_lovelace} -ne ${newBalance} ]]; do
  say ""
  say "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(numfmt --grouping ${base_lovelace}) != $(numfmt --grouping ${newBalance}))"
  if ! waitNewBlockCreated; then
    break
  fi
  getBalance ${S_ADDR}
done

echo "## Finished! ##"
