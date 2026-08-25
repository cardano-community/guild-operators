# Command     : buildTx [out_file]
# Description : Helper function to build a raw transaction
#             : populate an array variable called 'build_args' with all data
# Parameters  : out_file  >  (optional) output file of tx build command needed for HW transform
buildTx() {
  println ACTION "${CCLI} latest transaction build-raw ${build_args[*]}"
  if ! stdout=$(${CCLI} latest transaction build-raw "${build_args[@]}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during transaction building!\n${stdout}"; return 1
  fi
  if [[ -n $1 ]] && command -v "cardano-hw-cli" &>/dev/null; then
    HWCLIversionCheck || return 1
    transformRawTx "$1" || return 1
  fi
}

# Command     : calcMinFee [rax tx file]
# Description : Helper function to calculate minimum fee from a build transaction
# Parameters  : $1 = raw tx file > the transaction body file to use for calculating fee
#               $2 = Count of transaction inputs (spent txo count)
#               $3 = Count of transaction outputs
#               $4 = Count of witnesses required to sign the transaction
calcMinFee() {
  min_fee_args=(
    latest
    transaction calculate-min-fee
    --tx-body-file "$1"
    --tx-in-count $2
    --tx-out-count $3
    --witness-count $4
    --byron-witness-count 0
    --protocol-params-file "${TMP_DIR}"/protparams.json
  )
  println ACTION "${CCLI} ${min_fee_args[*]}"
  if ! stdout=$(${CCLI} "${min_fee_args[@]}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during minimum fee calculation!\n${stdout}"; return 1
  fi
  min_fee=$([[ ${stdout} =~ ([0-9]+) ]] && echo ${BASH_REMATCH[1]})
  println LOG "fee is $(formatLovelace ${min_fee}) ADA"
}

# Command     : witnessTx [raw tx file] [signing keys ...]
# Description : Helper function to witness a raw transaction
# Parameters  : raw tx file   >  the transaction file to sign
#             : signing keys  >  list of signing keys to use when witnessing the transaction
witnessTx() {
  tx_raw="$1"
  shift
  tx_witness_files=()
  unset isHW
  for skey in "$@"; do
    [[ -z ${skey//[[:blank:]]/} ]] && continue
    skey_name=$(basename "${skey}")
    if [[ ! -f "${skey}" ]]; then
      println ERROR "\n${FG_RED}ERROR${NC}: file not found: ${skey}"
      return 1
    elif [[ $(jq -r '.description' "${skey}") = *"Hardware"* ]]; then # HW signing key
      if [[ ${isHW} = 'Y' ]]; then
        # just add key and output to witness_command()
        tx_witness="$(mktemp "${TMP_DIR}/tx.witness_XXXXXXXXXX")"
        hw_witness_command+=(
          --hw-signing-file "${skey}"
          --change-output-key-file "${skey}"
          --out-file "${tx_witness}"
        )
      else
        isHW=Y
        tx_witness="$(mktemp "${TMP_DIR}/tx.witness_XXXXXXXXXX")"
        hw_witness_command=(
          cardano-hw-cli transaction witness
          --tx-file "${tx_raw}"
          --hw-signing-file "${skey}"
          --change-output-key-file "${skey}"
          --out-file "${tx_witness}"
          ${NETWORK_IDENTIFIER}
        )
      fi
    else
      tx_witness="$(mktemp "${TMP_DIR}/tx.witness_XXXXXXXXXX")"
      witness_command=(
        ${CCLI} latest transaction witness
        --tx-body-file "${tx_raw}"
        --signing-key-file "${skey}"
        ${NETWORK_IDENTIFIER}
        --out-file "${tx_witness}"
      )
      println ACTION "${witness_command[@]}"
      if ! stdout=$("${witness_command[@]}" 2>&1); then println ERROR "\n${FG_RED}ERROR${NC}: during transaction signing !!\n${stdout}" && return 1; fi
    fi
    tx_witness_files+=( "${tx_witness}" )
  done

  # Special case for HW
  if [[ ${isHW} = 'Y' ]]; then
    if ! unlockHWDevice "witness the transaction"; then return 1; fi
    println ACTION "${hw_witness_command[@]}"
    if ! stdout=$("${hw_witness_command[@]}" 2>&1); then println ERROR "\n${FG_RED}ERROR${NC}: during hardware wallet signing !!\n${stdout}" && return 1; fi
  fi
}

# Command     : assembleTx [raw tx file]
# Description : Helper function to witnessTx for assembling a signed tx using witnesses from tx_witness_files[] array
assembleTx() {
  tx_raw="$1"
  tx_signed="${TMP_DIR}/tx.signed_$(date +%s)"
  if [[ ${#tx_witness_files[@]} -gt 0 ]]; then # assemble witness files and sign
    tx_witness_out=()
    for witness in "${tx_witness_files[@]}"; do
      [[ -z ${witness//[[:blank:]]/} || ! -s "${witness}" ]] && continue
      if [[ -f "${witness}" ]]; then
        tx_witness_out+=( "--witness-file ${witness}" )
      else
        println ERROR "\n${FG_RED}ERROR${NC}: witness file not found: ${witness}"
        return 1
      fi
    done
    sign_command=(
      ${CCLI} latest transaction assemble
      --tx-body-file "${tx_raw}"
      ${tx_witness_out[@]}
      --out-canonical-cbor
      --out-file "${tx_signed}"
    )
    println ACTION "${sign_command[@]}"
    if ! stdout=$("${sign_command[@]}" 2>&1); then println ERROR "\n${FG_RED}ERROR${NC}: during hardware wallet signing !!\n${stdout}" && return 1; fi
  else
    println ERROR "\n${FG_RED}ERROR${NC}: no witness files provided, unable to assemble tx!"
    return 1
  fi
}

# Command     : submitTx [signed tx file]
# Description : Helper function to submit signed transaction file
# Parameters  : signed tx file   >  the signed transaction file to submit
submitTx() {
  tx_signed="$1"
  answer=0
  while true; do
    if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
      submitTxNode ${tx_signed} && break
    else
      submitTxKoiosOgmios ${tx_signed} && break
    fi
    tput sc
    println DEBUG "\nRetry transaction submit?"
    select_opt "[y] Yes" "[n] No"
    answer=$?
    tput rc && tput ed
    case ${answer} in
      0) : ;;
      1) break ;;
    esac
  done
  return ${answer}
}

# Command     : submitTxNode [signed tx file]
# Description : Helper function to submit signed transaction file using local node
# Parameters  : signed tx file   >  the signed transaction file to submit
submitTxNode() {
  getTxId $1 || return $?
  submit_command=(
    ${CCLI} latest transaction submit
    --tx-file "$1"
    ${NETWORK_IDENTIFIER}
  )
  println ACTION "${submit_command[@]}"
  if ! stdout=$("${submit_command[@]}" 2>&1); then println ERROR "\n${FG_RED}ERROR${NC}: Transaction submit failed !!\n${stdout}"; return 1; fi
}

# Command     : getTxId [tx file]
# Description : Helper function to calculate transaction id
# Parameters  : signed tx file   >  the signed transaction file to submit
# Info        : tx_id set to hash of transaction body
getTxId() {
  txid_command=(
    ${CCLI} latest transaction txid
    --output-text
    --tx-file "$1"
  )
  println ACTION "${txid_command[@]}"
  if ! tx_id=$("${txid_command[@]}" 2>&1); then println ERROR "\n${FG_RED}ERROR${NC}: during transaction hashing !!\n${tx_id}" && return 1; fi
}

# Command     : submitTxKoiosSubmitAPI [signed tx file]
# Description : Helper function to submit signed transaction file using koios submitapi endpoint
# Parameters  : signed tx file   >  the signed transaction file to submit
submitTxKoiosSubmitAPI() {
  getTxId $1 || return $?
  cborHex=$(jq -er '.cborHex' "$1" 2>/dev/null) || { println ERROR "\n${FG_RED}ERROR${NC}: Invalid tx file format, 'cborHex' missing in: $1"; return 1; }
  txdata="$(mktemp "${TMP_DIR}/tx.signed_XXXXXXXXXX")"
  xxd -p -r <<< ${cborHex} > ${txdata}
  HEADERS=("${KOIOS_API_HEADERS[@]}" -H "Content-Type: application/cbor")
  println ACTION "curl -sfSL -X POST ${HEADERS[*]} --data-binary @${txdata} \"${KOIOS_API}/submittx\""
  if ! stdout=$(curl -sfSL -X POST "${HEADERS[@]}" --data-binary @${txdata} "${KOIOS_API}/submittx" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: Transaction submit failed !!\n${stdout}"; return 1
  fi
  println LOG "Submit result: ${stdout}"
}

# Command     : submitTxKoiosOgmios [signed tx file]
# Description : Helper function to submit signed transaction file using koios submitapi endpoint
# Parameters  : signed tx file   >  the signed transaction file to submit
submitTxKoiosOgmios() {
  getTxId $1 || return $?
  cborHex=$(jq -er '.cborHex' "$1" 2>/dev/null) || { println ERROR "\n${FG_RED}ERROR${NC}: Invalid tx file format, 'cborHex' missing in: $1"; return 1; }
  jsonrpc=$(jq -n -c --arg cbor "${cborHex}" '{jsonrpc: "2.0", method: "submitTransaction", params: {transaction: {cbor: $cbor}}}')
  unset ogmios_error
  HEADERS=("${KOIOS_API_HEADERS[@]}" -H "accept: application/json" -H "Content-Type: application/json")
  println ACTION "curl -sSL -X POST ${HEADERS[*]} -d \"${jsonrpc}\" \"${KOIOS_API}/ogmios/\""
  stdout=$(curl -sSL -X POST "${HEADERS[@]}" -d "${jsonrpc}" "${KOIOS_API}/ogmios/" 2>&1)
  if [[ -z ${stdout} ]] || ogmios_error=$(jq -er '.error //empty' <<< "${stdout}") || ! jq -er '.result //empty' <<< "${stdout}" &>/dev/null; then
    println ERROR "\n${FG_RED}ERROR${NC}: Transaction submit failed !!"
    if [[ -n ${ogmios_error} ]]; then
      jq -r . <<< "${ogmios_error}"
      println LOG "$(jq -rc . <<< ${ogmios_error})"
    else
      println ERROR "Ogmios API error: ${stdout}"
    fi
    return 1
  fi
  ogmios_res=$(jq -erc '.result' <<< "${stdout}") && println LOG "Submit result: ${ogmios_res}"
}

# Command     : transformRawTx [raw tx file]
# Description : Transform raw tx to be in canonical order for HW wallets
# Parameters  : raw tx file  >  path to raw tx to correct
transformRawTx() {
  tx_raw="$1"
  tx_raw_tmp="$(mktemp "${TMP_DIR}/tx.raw_XXXXXXXXXX")"
  println ACTION "cardano-hw-cli transaction transform --tx-file ${tx_raw} --out-file ${tx_raw_tmp}"
  if ! stdout=$(cardano-hw-cli transaction transform --tx-file "${tx_raw}" --out-file "${tx_raw_tmp}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: Transaction transform failed !!\n${stdout}"; return 1
  fi
  println ACTION "mv ${tx_raw_tmp} ${tx_raw}"
  if ! stdout=$(mv "${tx_raw_tmp}" "${tx_raw}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: Transaction transform failure moving temporary file to ${tx_raw} !!\n${stdout}"; return 1
  fi
}

# Command     : unlockHWDevice [action]
# Description : Directions to unlock and open HW device
cnodeManifestToolMinimumVersion() {
  local tool_key="$1"
  local manifest="${NODE_HOME:-${CNODE_HOME:-}}/files/cnode-release.json"

  command -v jq >/dev/null 2>&1 || {
    printf 'jq is required to validate cnode tool compatibility metadata.\n' >&2
    return 1
  }
  [[ -f "${manifest}" && ! -L "${manifest}" && -s "${manifest}" ]] || {
    printf 'Cnode release metadata is missing or unsafe: %s\n' "${manifest}" >&2
    return 1
  }
  jq -er --arg tool "${tool_key}" '
    select(
      .schemaVersion == 1 and
      .implementation == "cnode" and
      (.tools[$tool].minimumVersion | type == "string" and length > 0)
    ) |
    .tools[$tool].minimumVersion
  ' "${manifest}"
}

# Parameters  : action  >  message for action to be taken
unlockHWDevice() {
  if ! HWCLIversionCheck; then waitToProceed && return 1; fi
  waitToProceed "${FG_BLUE}INFO${NC}: please connect and unlock hardware device" "\n  ${FG_YELLOW}Ledger${NC} - Unlock with pin and open Cardano app" "\n  ${FG_YELLOW}Trezor${NC} - Make sure trezor bridge is installed (https://wallet.trezor.io/#/bridge) " "\n\nwhen done, press any key to continue"
  println ACTION "cardano-hw-cli device version"
  if ! device_app=$(cardano-hw-cli device version 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: accessing hardware device failed !!\n${device_app}"; return 1
  fi
  device_app_vendor="$(cut -d' ' -f1 <<< "${device_app}")"
  device_app_version="$(cut -d' ' -f4 <<< "${device_app}")"
  println LOG "hardware device: vendor=${device_app_vendor} version=${device_app_version}"
  if [[ ! ${device_app_version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    println ERROR "${FG_RED}ERROR${NC}: unable to identify connected hardware device, is the device plugged in and unlocked?"
    println ERROR "Make sure device is seen by OS using tools like lsusb etc and is working correctly"
    waitToProceed && return 1
  fi
  println DEBUG "\n${FG_BLUE}INFO${NC}: follow directions on hardware device to $1"
}

HWCLIversionCheck() {
  local minimum_version

  ! command -v "cardano-hw-cli" &>/dev/null && echo "cardano-hw-cli not found, please install using guild-deploy.sh with '-s w' option" && return 1
  if ! minimum_version="$(cnodeManifestToolMinimumVersion "cardano-hw-cli")"; then
    println ERROR "${FG_RED}ERROR${NC}: invalid cardano-hw-cli compatibility metadata in the installed cnode release manifest."
    return 1
  fi
  println ACTION "cardano-hw-cli version"
  HWCLI_version="$(cardano-hw-cli version 2>/dev/null | head -n 1 | cut -d' ' -f6)"
  println LOG "cardano-hw-cli version: ${HWCLI_version}"
  if ! versionCheck "${minimum_version}" "${HWCLI_version}"; then
    println ERROR "${FG_RED}ERROR${NC}: Vacuumlabs cardano-hw-cli ${FG_LGRAY}v${HWCLI_version}${NC} installed on system, minimum required version is ${FG_GREEN}v${minimum_version}${NC} !!"
    println ERROR "Please run ${FG_LGRAY}guild-deploy.sh -s w${NC} to upgrade."
    return 1
  fi
  return 0
}

# Command     : selectOpMode
# Description : Helper function to choose operational mode
selectOpMode() {
  println OFF "\nOnline mode  -  The default mode to use if all keys are available\n"\
		"Hybrid mode  -  1) Go through steps to build a transaction file"\
		"                2) Copy built tx file to offline computer"\
		"                3) Sign it using 'Sign Tx' with keys on offline computer"\
		"                   (CNTools started in offline mode '-o' without node connection)"\
		"                4) Copy the signed tx file back to online computer and submit using 'Submit Tx'\n"
  select_opt "[o] Online" "[h] Hybrid" "[Esc] Cancel"
  case $? in
    0) op_mode="online" ;;
    1) op_mode="hybrid" ;;
    2) return 1 ;;
  esac
}

# Command     : to_cbor
# Description : converts different majortypes and there values into a cborHexString
# Original src: SPO Scripts (https://github.com/gitmachtl/scripts/blob/master/cardano/testnet/00_common.sh#L979)
to_cbor() {

  # ${1} type: unsigned, negative, bytes, string, array, map, tag
  # ${2} value: unsigned int value or hexstring for bytes

  local type=${1}
  local value="${2}"

  # majortypes
  #  unsigned      000x|xxxx       majortype 0     not limited, but above 18446744073709551615 (2^64), the numbers are represented via tag2 + bytearray
  #  bytes         010x|xxxx       majortype 2     limited to max. 65535 here
  #  array         100x|xxxx       majortype 4     limited to max. 65535 here
  #  map           101x|xxxx       majortype 5     limited to max. 65535 here
  # extras - not used yet but implemented for the future
  #  negative    001x|xxxx    majortype 1    not limited, but below -18446744073709551616 (-2^64 -1), the numbers are represented via tag3 + bytearray
  #  string    011x|xxxx    majortype 3    limited to max. 65535 chars
  #  tag           110x|xxxx       majortype 6     limited to max. 65535 here

  case ${type} in
    #unsigned - input is an unsigned integer, range is selected via a bc query because bash can't handle big numbers
    unsigned )
      if [[ $(bc <<< "${value} < 24") -eq 1 ]]; then printf -v cbor "%02x" $((10#${value})) #1byte total value below 24
      elif [[ $(bc <<< "${value} < 256") -eq 1 ]]; then printf -v cbor "%04x" $((0x1800 + 10#${value})) #2bytes total: first 0x1800 + 1 lower byte value
      elif [[ $(bc <<< "${value} < 65536") -eq 1 ]]; then printf -v cbor "%06x" $((0x190000 + 10#${value})) #3bytes total: first 0x190000 + 2 lowerbytes value
      elif [[ $(bc <<< "${value} < 4294967296") -eq 1 ]]; then printf -v cbor "%10x" $((0x1A00000000 + 10#${value})) #5bytes total: 0x1A00000000 + 4 lower bytes value
      elif [[ $(bc <<< "${value} < 18446744073709551616") -eq 1 ]]; then local tmp;tmp="00$(bc <<< "obase=16;ibase=10;${value}+498062089990157893632")"; cbor="${tmp: -18}" #9bytes total: first 0x1B0000000000000000 + 8 lower bytes value
      #if value does not fit into an 8byte unsigned integer, the cbor representation is tag2(pos.bignum)+bytearray of the value
      else local cbor;cbor=$(to_cbor "tag" 2); local tmp;tmp="00$(bc <<< "obase=16;ibase=10;${value}")"; tmp=${tmp: -$(( (${#tmp}-1)/2*2 ))}; local cbor;cbor+=$(to_cbor "bytes" ${tmp}) #fancy calc to get a leading zero in the hex array if needed
      fi
      ;;
    #bytestring - input is a hexstring
    bytes )
      local bytesLength=$(( ${#value} / 2 ))  #bytesLength is length of value /2 because of hex encoding (2chars -> 1byte)
      if [[ ${bytesLength} -lt 24 ]]; then printf -v cbor "%02x${value}" $((0x40 + 10#${bytesLength})) #1byte total 0x40 + lower part value & bytearrayitself
      elif [[ ${bytesLength} -lt 256 ]]; then printf -v cbor "%04x${value}" $((0x5800 + 10#${bytesLength})) #2bytes total: first 0x4000 + 0x1800 + 1 lower byte value & bytearrayitself
      elif [[ ${bytesLength} -lt 65536 ]]; then printf -v cbor "%06x${value}" $((0x590000 + 10#${bytesLength})) #3bytes total: first 0x400000 + 0x190000 + 2 lower bytes value & bytearrayitself
      fi
      ;;
    #array - input is an unsigned integer
    array )
      if [[ ${value} -lt 24 ]]; then printf -v cbor "%02x" $((0x80 + 10#${value})) #1byte total 0x80 + lower part value
      elif [[ ${value} -lt 256 ]]; then printf -v cbor "%04x" $((0x9800 + 10#${value})) #2bytes total: first 0x8000 + 0x1800 & 1 lower byte value
      elif [[ ${value} -lt 65536 ]]; then printf -v cbor "%06x" $((0x990000 + 10#${value})) #3bytes total: first 0x800000 + 0x190000 & 2 lower bytes value
      fi
      ;;
    #map - input is an unsigned integer
    map )
      if [[ ${value} -lt 24 ]]; then printf -v cbor "%02x" $((0xA0 + 10#${value})) #1byte total 0xA0 + lower part value
      elif [[ ${value} -lt 256 ]]; then printf -v cbor "%04x" $((0xB800 + 10#${value})) #2bytes total: first 0xA000 + 0x1800 & 1 lower byte value
      elif [[ ${value} -lt 65536 ]]; then printf -v cbor "%06x" $((0xB90000 + 10#${value})) #3bytes total: first 0xA00000 + 0x190000 & 2 lower bytes value
      fi
      ;;
    ###
    ### the following types are not used in these scripts yet, but added to have a more complete function for the future
    ###
    #negative - input is a negative unsigned integer, range is selected via a bc query because bash can't handle big numbers
    negative )
      local value;value="$(bc <<< "${value//-/} -1")" #negative representation in cbor is the neg. number as a pos. number minus 1, so a -500 will be represented as a 499
      if [[ $(bc <<< "${value} < 24") -eq 1 ]]; then printf -v cbor "%02x" $((0x20 + 10#${value})) #1byte total 0x20 value below 24
      elif [[ $(bc <<< "${value} < 256") -eq 1 ]]; then printf -v cbor "%04x" $((0x3800 + 10#${value})) #2bytes total: first 0x2000 + 0x1800 + 1 lower byte value
      elif [[ $(bc <<< "${value} < 65536") -eq 1 ]]; then printf -v cbor "%06x" $((0x390000 + 10#${value})) #3bytes total: first 0x200000 + 0x190000 + 2 lowerbytes value
      elif [[ $(bc <<< "${value} < 4294967296") -eq 1 ]]; then printf -v cbor "%10x" $((0x3A00000000 + 10#${value})) #5bytes total: 0x2000000000 + 0x1A00000000 + 4 lower bytes value
      elif [[ $(bc <<< "${value} < 18446744073709551616") -eq 1 ]]; then local tmp;tmp="00$(bc <<< "obase=16;ibase=10;${value}+1088357900348863545344")"; cbor="${tmp: -18}" #9bytes total: first 0x3B0000000000000000 + 8 lower bytes value
      #if value does not fit into an 8byte unsigned integer, the cbor representation is tag3(neg.bignum)+bytearray of the value
      else local cbor;cbor=$(to_cbor "tag" 3); local tmp;tmp="00$(bc <<< "obase=16;ibase=10;${value}")"; tmp=${tmp: -$(( (${#tmp}-1)/2*2 ))}; local cbor;cbor+=$(to_cbor "bytes" ${tmp}) #fancy calc to get a leading zero in the hex array if needed
      fi
      ;;
    #tag - input is an unsigned integer
    tag )
      if [[ ${value} -lt 24 ]]; then printf -v cbor "%02x" $((0xC0 + 10#${value})) #1byte total 0xC0 + lower part value
      elif [[ ${value} -lt 256 ]]; then printf -v cbor "%04x" $((0xD800 + 10#${value})) #2bytes total: first 0xC000 + 0x1800 & 1 lower byte value
      elif [[ ${value} -lt 65536 ]]; then printf -v cbor "%06x" $((0xD90000 + 10#${value})) #3bytes total: first 0xC00000 + 0x190000 & 2 lower bytes value
      fi
      ;;
    #textstring - input is a utf8-string
    string )
      local value;value="$(echo -ne "${value}" | xxd -p -c 65536 | tr -d '\n')" #convert the given string into a hexstring and process it further like a bytearray
      local bytesLength;bytesLength=$(( ${#value} / 2 ))  #bytesLength is length of value /2 because of hex encoding (2chars -> 1byte)
      if [[ ${bytesLength} -lt 24 ]]; then printf -v cbor "%02x${value}" $((0x60 + 10#${bytesLength})) #1byte total 0x60 + lower part value & bytearrayitself
      elif [[ ${bytesLength} -lt 256 ]]; then printf -v cbor "%04x${value}" $((0x7800 + 10#${bytesLength})) #2bytes total: first 0x6000 + 0x1800 + 1 lower byte value & bytearrayitself
      elif [[ ${bytesLength} -lt 65536 ]]; then printf -v cbor "%06x${value}" $((0x790000 + 10#${bytesLength})) #3bytes total: first 0x600000 + 0x190000 + 2 lower bytes value & bytearrayitself
      fi
      ;;
  esac
  echo -n "${cbor^^}" #return the cbor in uppercase
}

# Command     : getPriceInfo
# Description : fetch current ADA price from coingecko in selected currency
getPriceInfo() {

  [[ -z ${CURRENCY_URL} ]] && return

  if ! price_info=$(curl -sSL -f -m 3 "${CURRENCY_URL}" 2>&1); then
    logln "ERROR" "${price_info}"
    return
  fi
  if ! jq -e ".cardano.${CURRENCY}" <<< ${price_info} &>/dev/null; then
    logln "ERROR" "invalid currency set, please check config!"
    return
  fi

  price_info_tsv=$(jq -r "[
  .cardano.${CURRENCY} //0,
  .cardano.${CURRENCY}_24h_change //0
  ] | @tsv" <<< "${price_info}")

  read -ra price_info_arr <<< ${price_info_tsv}

  price_now=${price_info_arr[0]}
  price_24h=$(LC_NUMERIC=C printf "%.2f" "${price_info_arr[1]}")
}

# Command     : getPriceString
# Description : construct the ada value price string in set currency from lovelace value
getPriceString() {
  unset price_str
  if [[ -n ${price_now} && $1 -ne 0 ]]; then
    ada_value=$(bc -l <<< "${price_now}*($1/1000000)")
    getDecimalPlaces ${ada_value}
    decimals=$?
    price_str=$(LC_NUMERIC=C printf " (${FG_LBLUE}%s${NC} ${CURRENCY^^})" "$(formatAsset "$(LC_NUMERIC=C printf "%.${decimals}f" "${ada_value}")")")
  fi
}
