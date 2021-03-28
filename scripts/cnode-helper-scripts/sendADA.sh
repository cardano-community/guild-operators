#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2086,SC2206,SC2015,SC2154,SC2034
function usage() {
  printf "\n%s\n\n" "Usage: $(basename "$0") <Destination Address> <Amount> <Source Address> <Source Sign Key> [--include-fee]"
  printf "  %-20s\t%s\n" \
    "Destination Address" "Address or path to Address file." \
    "Amount" "Amount in ADA, number(fraction of ADA valid) or the string 'all'." \
    "Source Address" "Address or path to Address file." \
    "Source Sign Key" "Path to Signature (skey) file. For staking address payment skey is to be used." \
    "--include-fee" "Optional argument to specify that amount to send should be reduced by fee instead of payed by sender." \
    "" "" "Script does NOT support sending of assets other than Ada" ""
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

CNTOOLS_LOG=/dev/null # disable logging
exec 6>&1 7>&2 8>&1 9>&2 # Link file descriptors to be compatible with CNTools sourced functions

customExit() {
  if { true >&6; } 2<> /dev/null; then
    exec 1>&6 2>&7 3>&- 6>&- 7>&- 8>&- 9>&- # Restore stdout/stderr and close tmp file descriptors
  fi
  exit $1
}

# create temporary directory if missing
mkdir -p "${TMP_FOLDER}" # Create if missing
if [[ ! -d "${TMP_FOLDER}" ]]; then
  echo
  echo -e "${RED}ERROR${NC}: Failed to create directory for temporary files:"
  echo -e "${TMP_FOLDER}"
  echo && customExit 1
fi

# start with a clean slate
rm -f "${TMP_FOLDER}"/*

# Get protocol parameters and save to ${TMP_FOLDER}/protparams.json
${CCLI} query protocol-parameters ${NETWORK_IDENTIFIER} --out-file ${TMP_FOLDER}/protparams.json || {
  echo
  echo -e "${RED}ERROR${NC}: failed to query protocol parameters, node running and env parameters correct?"
  customExit 1
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
  echo && customExit 1
fi

if [[ $# -eq 5 ]]; then
  [[ $5 = "--include-fee" ]] && include_fee="yes" || usage
else
  include_fee="no"
fi

getBalance ${s_addr}
if [[ ${assets[lovelace]} -gt 0 ]]; then
  echo -e "$(printf "\n%s\t${CYAN}%s${NC} ADA" "Funds in source wallet:"  "$(formatLovelace ${assets[lovelace]})")" "log"
else
  echo -e "${RED}ERROR${NC}: no funds available in source address"
  echo && customExit 1
fi
declare -gA assets_left=()
for asset in "${!assets[@]}"; do
  assets_left[${asset}]=${assets[${asset}]}
done

amountADA="$2"
if  [[ ${amountADA} != "all" ]]; then
  if ! AdaToLovelace "${amountADA}" >/dev/null; then
    echo && customExit 1
  fi
  amount_lovelace=$(AdaToLovelace "${amountADA}")
  [[ ${amount_lovelace} -gt ${assets[lovelace]} ]] && echo -e "\n${FG_RED}ERROR${NC}: not enough funds on address, ${FG_LBLUE}$(formatLovelace ${assets[lovelace]})${NC} Ada available but trying to send ${FG_LBLUE}$(formatLovelace ${amount_lovelace})${NC} Ada" && echo && customExit 1
else
  amount_lovelace=${assets[lovelace]}
  echo -e "\nAda to send set to total supply: ${FG_LBLUE}$(formatLovelace ${amount_lovelace})${NC}"
  include_fee="yes"
fi

if [[ ${amount_lovelace} -eq ${assets[lovelace]} ]]; then
  unset assets_left
else
  assets_left[lovelace]=$(( assets_left[lovelace] - amount_lovelace ))
fi

declare -gA assets_to_send=()
assets_to_send[lovelace]=${amount_lovelace}

s_payment_sk_file="${payment_sk_file}"

echo
if ! sendAssets >&1; then
  echo && customExit 1
fi

if ! waitNewBlockCreated >&1; then
  echo && customExit 1
fi

getBalance ${s_addr}

while [[ ${assets[lovelace]} -ne ${newBalance} ]]; do
  echo
  echo -e "${ORANGE}WARN${NC}: Balance mismatch, transaction not included in latest block ($(formatLovelace ${assets[lovelace]}) != $(formatLovelace ${newBalance}))"
  if ! waitNewBlockCreated; then
    echo "" && customExit 1
  fi
  getBalance ${s_addr}
done

echo -e "$(printf "\n%s\t\t${CYAN}%s${NC} ADA" "Funds in source wallet:"  "$(formatLovelace ${assets[lovelace]})")" "log"

getBalance ${d_addr}
echo -e "$(printf "%s\t${CYAN}%s${NC} ADA" "Funds in destination wallet:"  "$(formatLovelace ${assets[lovelace]})")" "log"

echo -e "\n## Finished! ##\n"

customExit 0
