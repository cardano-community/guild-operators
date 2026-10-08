#!/usr/bin/env bash
# Deterministic threshold script creation; public artifacts only.
# shellcheck disable=SC2034,SC2015
declare -ag CNTOOLS_MULTISIG_PAYMENT_HASHES=() CNTOOLS_MULTISIG_STAKE_HASHES=() CNTOOLS_MULTISIG_LABELS=()

cntools_multisig_participants_reset() {
  CNTOOLS_MULTISIG_PAYMENT_HASHES=(); CNTOOLS_MULTISIG_STAKE_HASHES=(); CNTOOLS_MULTISIG_LABELS=()
}

cntools_multisig_participant_add() {
  local payment="${1,,}" stake="${2,,}" label="$3" existing=''
  [[ "${payment}" =~ ^[0-9a-f]{56}$ && ( -z "${stake}" || "${stake}" =~ ^[0-9a-f]{56}$ ) &&
      ${#label} -le 64 && -n "${label}" && ! "${label}" =~ [[:cntrl:]] ]] || return 2
  (( ${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]} < 20 )) || {
    cntools_multisig_fail 'At most 20 participants are supported.'; return 1;
  }
  for existing in "${CNTOOLS_MULTISIG_PAYMENT_HASHES[@]}"; do
    [[ "${existing}" != "${payment}" ]] || { cntools_multisig_fail 'That payment participant is already included.'; return 1; }
  done
  if [[ -n "${stake}" ]]; then
    for existing in "${CNTOOLS_MULTISIG_STAKE_HASHES[@]}"; do
      [[ "${existing}" != "${stake}" ]] || { cntools_multisig_fail 'That stake participant is already included.'; return 1; }
    done
  fi
  CNTOOLS_MULTISIG_PAYMENT_HASHES+=("${payment}"); CNTOOLS_MULTISIG_STAKE_HASHES+=("${stake}"); CNTOOLS_MULTISIG_LABELS+=("${label}")
}

cntools_multisig_script_write() {
  local target="$1" hashes_name="$2" threshold="$3" after="$4" before="$5" hashes=''
  local -n ms_hashes="${hashes_name}"
  [[ "${threshold}" =~ ^[1-9][0-9]?$ ]] && ((threshold<=${#ms_hashes[@]})) || return 2
  hashes="$(printf '%s\n' "${ms_hashes[@]}" | jq -Rsc 'split("\n")[:-1]|sort')" || return 1
  jq -n --argjson hashes "${hashes}" --argjson required "${threshold}" --arg after "${after}" --arg before "${before}" '
    {type:"atLeast",required:$required,scripts:[$hashes[]|{type:"sig",keyHash:.}]} as $threshold |
    ([if $after!="" then {type:"after",slot:($after|tonumber)} else empty end,
      if $before!="" then {type:"before",slot:($before|tonumber)} else empty end]) as $bounds |
    if ($bounds|length)==0 then $threshold else {type:"all",scripts:($bounds+[$threshold])} end
  ' > "${target}"
}

cntools_wallet_multisig_required_entries_valid() {
  local directory="$1" credential='' entry='' name='' mode='' count=0
  local -a required=("${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}" "${CNTOOLS_WALLET_PAY_ADDR_FILENAME}" "${CNTOOLS_WALLET_PAY_SCRIPT_CRED_FILENAME}")
  cntools_wallet_directory_safe "${directory}" && cntools_wallet_create_directory_private "${directory}" || return 1
  if [[ -f "${directory}/${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}" ]]; then
    required+=("${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}" "${CNTOOLS_WALLET_BASE_ADDR_FILENAME}"
      "${CNTOOLS_WALLET_STAKE_ADDR_FILENAME}" "${CNTOOLS_WALLET_STAKE_SCRIPT_CRED_FILENAME}")
  fi
  for name in "${required[@]}"; do
    entry="${directory}/${name}"
    [[ -f "${entry}" && ! -L "${entry}" && -O "${entry}" ]] || return 1
    chmod 0600 -- "${entry}" || return 1
  done
  for entry in "${directory}"/* "${directory}"/.[!.]* "${directory}"/..?*; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    name="${entry##*/}"
    case " ${required[*]} " in *" ${name} "*) ;; *) return 1 ;; esac
    [[ -f "${entry}" && ! -L "${entry}" && -O "${entry}" ]] || return 1
    cntools_wallet_create_mode_into mode "${entry}" && [[ "${mode}" == 600 || "${mode}" == 0600 ]] || return 1
    count=$((count+1))
  done
  ((count == ${#required[@]})) || return 1
  chmod 0700 -- "${directory}" || return 1
  cntools_transaction_native_script_valid "${directory}/${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}" &&
    cntools_wallet_address_validate "${directory}/${CNTOOLS_WALLET_PAY_ADDR_FILENAME}" payment &&
    cntools_wallet_id_read_credential "${directory}" script-payment credential || return 1
  if [[ -f "${directory}/${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}" ]]; then
    cntools_transaction_native_script_valid "${directory}/${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}" &&
      cntools_wallet_address_validate "${directory}/${CNTOOLS_WALLET_BASE_ADDR_FILENAME}" base &&
      cntools_wallet_address_validate "${directory}/${CNTOOLS_WALLET_STAKE_ADDR_FILENAME}" reward &&
      cntools_wallet_id_read_credential "${directory}" script-stake credential || return 1
  fi
  [[ "$(cntools_wallet_type "${directory}")" == MultiSig ]]
}

cntools_multisig_wallet_create() {
  local name="$1" threshold="$2" staking="$3" after="${4:-}" before="${5:-}" target='' stage='' bound=''
  CNTOOLS_MULTISIG_ERROR=''; CNTOOLS_WALLET_CREATED_DIRECTORY=''
  cntools_wallet_create_environment_ready && cntools_wallet_create_root_prepare &&
    cntools_wallet_create_target_into target "${name}" || return 1
  cntools_wallet_create_target_available "${name}" || { cntools_multisig_fail 'That wallet already exists. Nothing was changed.'; return 1; }
  [[ "${staking}" == Y || "${staking}" == N ]] || return 2
  (( ${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]} >= 1 && ${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]} <= 20 )) || return 2
  for bound in "${after}" "${before}"; do
    [[ -z "${bound}" ]] || { cntools_transaction_slot_value_valid "${bound}" && ((bound<=9007199254740991)); } || return 2
  done
  [[ -z "${after}" || -z "${before}" ]] || ((after<before)) || return 2
  if [[ "${staking}" == Y ]]; then
    for bound in "${CNTOOLS_MULTISIG_STAKE_HASHES[@]}"; do [[ "${bound}" =~ ^[0-9a-f]{56}$ ]] || return 2; done
    (( ${#CNTOOLS_MULTISIG_STAKE_HASHES[@]} == ${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]} )) || return 2
  fi
  cntools_wallet_create_stage_into stage || return 1
  cntools_multisig_script_write "${stage}/${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}" CNTOOLS_MULTISIG_PAYMENT_HASHES "${threshold}" "${after}" "${before}" || return 1
  if [[ "${staking}" == Y ]]; then
    # Staking follows the same participant threshold, not a spending timelock.
    cntools_multisig_script_write "${stage}/${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}" CNTOOLS_MULTISIG_STAKE_HASHES "${threshold}" '' '' || return 1
  fi
  chmod 0600 "${stage}"/* || return 1
  cntools_wallet_address_materialize "${stage}" && cntools_wallet_id_materialize_credentials "${stage}" &&
    cntools_wallet_multisig_required_entries_valid "${stage}" || {
    cntools_multisig_fail 'The generated script wallet failed artifact validation.'; return 1;
  }
  cntools_wallet_create_publish "${stage}" "${target}" cntools_wallet_multisig_required_entries_valid || return 1
  CNTOOLS_WALLET_CREATED_DIRECTORY="${target}"; CNTOOLS_WALLET_CREATED_NAME="${name}"
  cntools_log WALLET "Multisig wallet created wallet=${name} threshold=${threshold}/${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]} staking=${staking} after=${after:-none} before=${before:-none}" || true
}
