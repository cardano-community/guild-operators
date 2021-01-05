#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2086,SC2206,SC2015,SC2154,SC2034
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

# source files
. "$(dirname $0)"/env
. "$(dirname $0)"/cntools.config
. "$(dirname $0)"/cntools.library

# create temporary directory if missing
mkdir -p "${TMP_FOLDER}" # Create if missing
if [[ ! -d "${TMP_FOLDER}" ]]; then
  echo
  echo -e "${RED}ERROR${NC}: Failed to create directory for temporary files:"
  echo -e "${TMP_FOLDER}"
  echo && exit 1
fi

# start with a clean slate
rm -f "${TMP_FOLDER}"/*

# Get protocol parameters and save to ${TMP_FOLDER}/protparams.json
${CCLI} query protocol-parameters ${ERA_IDENTIFIER} ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} --out-file ${TMP_FOLDER}/protparams.json || {
  echo
  echo -e "${RED}ERROR${NC}: failed to query protocol parameters, node running and env parameters correct?"
  exit 1
}

# Handle script arguments
if [[ ! -f "$1" ]]; then
  d_addr="$1"
else
  d_addr="$(cat $1)"
fi

if [[ ! -f "$3" ]]; then
  s_addr="$3"
else
  s_addr="$(cat $3)"
fi

if [[ -f "$4" ]]; then 
  payment_sk_file="$4" 
else
  echo -e "${RED}ERROR${NC}: Source Sign file(skey) not found!"
  echo -e "$4"
  echo && exit 1
fi

if [[ $# -eq 5 ]]; then
  [[ $5 = "--include-fee" ]] && include_fee="yes" || usage
else
  include_fee="no"
fi

getBalance ${s_addr}
if [[ ${lovelace} -gt 0 ]]; then
  echo -e "$(printf "\n%s\t${CYAN}%s${NC} ADA" "Funds in source wallet:"  "$(formatLovelace ${lovelace})")" "log"
else
  echo -e "${RED}ERROR${NC}: no funds available in source address"
  echo && exit 1
fi

amount_lovelace="$2"
if [[ ${amount_lovelace} != "all" ]]; then
  if ! ADAtoLovelace "${amount_lovelace}" >/dev/null; then
    echo && exit 1
  fi
  amount_lovelace=$(ADAtoLovelace "${amount_lovelace}")
  if [[ ${amount_lovelace} -gt ${lovelace} ]]; then
    echo -e "${RED}ERROR${NC}: not enough funds available in source address"
    echo && exit 1
  fi
else
  amount_lovelace=${lovelace}
  echo -e "$(printf "\n%s\t${CYAN}%s${NC} ADA" "ADA to send set to total supply:"  "$(formatLovelace ${lovelace})")" "log"
  include_fee="yes"
fi

if ! sendADA; then
  echo && exit 1
fi

if ! waitNewBlockCreated; then
  echo && exit 1
fi

getBalance ${s_addr}

while [[ ${lovelace} -ne ${newBalance} ]]; do
  echo
  echo -e "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(formatLovelace ${lovelace}) != $(formatLovelace ${newBalance}))"
  if ! waitNewBlockCreated; then
    echo "" && exit 1
  fi
  getBalance ${s_addr}
done

echo -e "$(printf "\n%s\t\t${CYAN}%s${NC} ADA" "Funds in source wallet:"  "$(formatLovelace ${lovelace})")" "log"

getBalance ${d_addr}
echo -e "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds in destination wallet:"  "$(formatLovelace ${lovelace})")" "log"

echo -e "\n## Finished! ##\n"
