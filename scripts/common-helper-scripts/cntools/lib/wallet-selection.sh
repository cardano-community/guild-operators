#!/usr/bin/env bash
# Action-specific candidates. Missing/unknown chain state is never treated as zero.
# shellcheck disable=SC2034
declare -Ag CNTOOLS_SELECTION_REGISTERED=() CNTOOLS_SELECTION_REWARDS=()
CNTOOLS_SELECTION_CHECKED=0 CNTOOLS_SELECTION_SCOPE=''

cntools_wallet_selection_material() {
  local directory="$1" role="$2" name=''
  local -a names=()
  case "${role}" in
    payment) names=("${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}.gpg" "${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}") ;;
    stake) names=("${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}.gpg" "${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}") ;;
    drep) names=("${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}" "${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}" "${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}.gpg" "${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}" "${CNTOOLS_WALLET_DREP_SCRIPT_FILENAME:-drep.script}") ;;
    *) return 1 ;;
  esac
  for name in "${names[@]}"; do [[ ! -L "${directory}/${name}" && -f "${directory}/${name}" ]] && return 0; done
  return 1
}

cntools_wallet_selection_collect() {
  local context="$1" directory='' address='' payload='' response='' now=0 registered='' rewards='' status='' offset=0 snapshot=''
  local -a addresses=() batch=()
  # "funding" is "send" for actions that cannot spend from a native script.
  if [[ "${context}" =~ ^(send|funding|funding-software)$ ]]; then
    # Koios answers every wallet in one batch, so light mode shows balances.
    declare -F cntools_wallet_list_query_koios_funding >/dev/null 2>&1 || return 0
    cntools_wallet_list_query_reset
    [[ "${CNTOOLS_MODE:-offline}" == light ]] || return 0
    cntools_wallet_list_collect_addresses || return 0
    cntools_wallet_list_query_koios_funding || cntools_wallet_log WARN 'Send wallet balances unavailable; wallets remain selectable'
    cntools_wallet_list_project_koios_results || true
    cntools_wallet_query_cleanup
    return 0
  fi
  case "${context}" in register|deregister|delegate|vote-delegate|withdraw) ;; *) return 0 ;; esac
  printf -v now '%(%s)T' -1
  local scope="${CNTOOLS_NETWORK}|${CNTOOLS_MODE:-offline}|${CNTOOLS_KOIOS_ENABLED:-N}|${CNTOOLS_KOIOS_API:-}|${CNTOOLS_SOCKET:-}|${CNTOOLS_WALLET_PATHS[*]}"
  [[ "${scope}" != "${CNTOOLS_SELECTION_SCOPE}" || $((now-CNTOOLS_SELECTION_CHECKED)) -ge 60 ]] || return 0
  CNTOOLS_SELECTION_REGISTERED=() CNTOOLS_SELECTION_REWARDS=()
  CNTOOLS_SELECTION_SCOPE="${scope}" CNTOOLS_SELECTION_CHECKED="${now}"
  [[ "${CNTOOLS_MODE:-offline}" != offline ]] || return 0
  for directory in "${CNTOOLS_WALLET_PATHS[@]}"; do
    cntools_wallet_read_address "${directory}" reward address || continue
    addresses+=("${address}")
  done
  (( ${#addresses[@]} > 0 )) || return 0
  if [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && "${CNTOOLS_KOIOS_API:-}" == https://* ]]; then
    cntools_wallet_query_temp_file response || return 0
    for ((offset=0; offset<${#addresses[@]}; offset+=100)); do
      batch=("${addresses[@]:offset:100}")
      payload="$(printf '%s\n' "${batch[@]}" | jq -Rsc '{_stake_addresses:(split("\n")[:-1]|unique)}')" || return 0
      if ! cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/account_info" "${payload}" "${response}" ||
        ! jq -se --argjson requested "$(jq -c ._stake_addresses <<< "${payload}")" 'length == 1 and (.[0] | type == "array" and
          length == (map(.stake_address)|unique|length) and all(.[];
            (.stake_address as $a | $requested | index($a) != null) and
            (.status == "registered" or .status == "not registered" or .status == "not_registered" or .status == "deregistered") and
            (.rewards_available | type == "string" and test("^[0-9]+$"))))' "${response}" >/dev/null; then
        cntools_wallet_log WARN 'Wallet suitability batch unavailable; unknown wallets remain selectable'
        continue
      fi
      while IFS=$'\037' read -r address status rewards; do
        [[ "${status}" != registered ]] && registered=no || registered=yes
        CNTOOLS_SELECTION_REGISTERED["${address}"]="${registered}" CNTOOLS_SELECTION_REWARDS["${address}"]="${rewards}"
      done < <(jq -r '.[] | [.stake_address,.status,.rewards_available] | join("\u001f")' "${response}")
      # Absence means never used only after a successful validated batch.
      for address in "${batch[@]}"; do
        [[ -n "${CNTOOLS_SELECTION_REGISTERED[${address}]+x}" ]] || { CNTOOLS_SELECTION_REGISTERED["${address}"]=no; CNTOOLS_SELECTION_REWARDS["${address}"]=0; }
      done
    done
  fi
  # Bound single-address local calls; stop at the first unavailable node. The
  # selected wallet always receives a fresh authoritative check before building.
  if [[ "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == true && -x "${CNTOOLS_CLI:-}" ]] && cntools_wallet_query_local_socket_ready; then
    cntools_wallet_query_network_arguments || return 0
    offset=0
    for address in "${addresses[@]}"; do
      [[ -z "${CNTOOLS_SELECTION_REGISTERED[${address}]+x}" ]] || continue
      ((offset < 10)) || break
      offset=$((offset+1))
      snapshot="$(cntools_wallet_query_local_stake "${address}" && printf '%s %s' "${CNTOOLS_WALLET_REGISTERED}" "${CNTOOLS_WALLET_REWARD_LOVELACE}")" || break
      read -r registered rewards <<< "${snapshot}"
      [[ "${registered}" =~ ^(yes|no)$ && "${rewards}" =~ ^[0-9]+$ ]] || continue
      CNTOOLS_SELECTION_REGISTERED["${address}"]="${registered}" CNTOOLS_SELECTION_REWARDS["${address}"]="${rewards}"
    done
  fi
}

cntools_wallet_selection_present() {
  local directory="$1" name=''
  shift
  for name in "$@"; do
    [[ ! -e "${directory}/${name}" && ! -L "${directory}/${name}" &&
       ! -e "${directory}/${name}.gpg" ]] || return 0
  done
  return 1
}

# Any DRep material, identity record or certificate already in the wallet.
cntools_wallet_selection_drep_present() {
  local directory="$1"
  cntools_wallet_selection_material "${directory}" drep && return 0
  cntools_wallet_selection_present "${directory}" "${CNTOOLS_WALLET_DREP_ID_FILENAME:-drep.id}" drep.derivation.path \
    "${CNTOOLS_WALLET_DREP_REGISTER_CERT_FILENAME:-drep-reg.cert}" "${CNTOOLS_WALLET_DREP_RETIRE_CERT_FILENAME:-drep-ret.cert}"
}

# Why a context left no wallets, shown once by cntools_wallet_choose. The
# reason names only causes that were actually checked.
cntools_wallet_selection_empty_reason_into() {
  local destination="$1" context="$2" reason='' index=0 directory='' stake=0 stake_only=0 scripts=0 hardware=0
  # stake counts only wallets that meet every stake-action prerequisite the
  # candidate check applies (payment and stake material, or both scripts), so
  # "already registered" is never claimed for a wallet that was not eligible.
  for index in "${!CNTOOLS_WALLET_PATHS[@]}"; do
    directory="${CNTOOLS_WALLET_PATHS[index]}"
    case "${CNTOOLS_WALLET_TYPES[index]}" in
      MultiSig) scripts=$((scripts + 1))
        cntools_wallet_file_present "${directory}" "${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}" || continue
        if cntools_wallet_file_present "${directory}" "${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}"; then
          stake=$((stake + 1))
        else stake_only=$((stake_only + 1)); fi ;;
      Unknown) ;;
      *) [[ "${CNTOOLS_WALLET_TYPES[index]}" != Hardware ]] || hardware=$((hardware + 1))
        cntools_wallet_selection_material "${directory}" stake || continue
        if cntools_wallet_selection_material "${directory}" payment; then
          stake=$((stake + 1))
        else stake_only=$((stake_only + 1)); fi ;;
    esac
  done
  case "${context}" in
    send|collect) reason='No wallet has a payment key or payment script.' ;;
    funding|funding-software)
      reason='No wallet can fund this action'
      (( scripts == 0 )) || reason+=': MultiSig wallets cannot fund it'
      if [[ "${context}" == funding-software ]] && (( hardware > 0 )); then
        reason+="$( (( scripts > 0 )) && printf ', and' || printf ':') hardware wallets need the pool cold key on the same Ledger"
      fi
      reason+='. A CLI or mnemonic wallet with a payment key is needed.' ;;
    register|deregister|withdraw|delegate|vote-delegate)
      if (( stake == 0 && stake_only > 0 )); then
        reason='No wallet has both a payment and a stake key (or both scripts); the fee is paid from the same wallet.'
      elif (( stake == 0 )); then
        reason='No wallet has a stake key or stake script.'
      else
        case "${context}" in
          register) reason='Every wallet with stake keys is already registered.' ;;
          deregister) reason='No wallet with stake keys has a registered stake address.' ;;
          withdraw) reason='No wallet with stake keys has rewards to withdraw.' ;;
          *) reason='No wallet has the stake key or stake script needed to delegate.' ;;
        esac
      fi ;;
    catalyst) reason='No wallet has the payment and stake keys needed for Catalyst registration.' ;;
    catalyst-key) reason='No wallet has a Catalyst voting public key. Register for Catalyst first.' ;;
    catalyst-qr) reason='No wallet has an unencrypted Catalyst voting signing key. Register for Catalyst, or decrypt the wallet first.' ;;
    drep-info|drep-register|drep-update|drep-retire|gov-vote) reason='No wallet has a DRep key or DRep script. Use Vote → Governance → Derive Keys or MultiSig DRep first.' ;;
    drep-key) reason='No wallet has a DRep verification key.' ;;
    drep-create) reason='No wallet can take new DRep keys: it must be an open CLI or mnemonic wallet without existing DRep files.' ;;
    drep-script-create) reason='No wallet can take a DRep script: every wallet already has DRep files.' ;;
    multisig-derive) reason='No wallet can take participant keys: it must be unencrypted and must not already hold participant keys.' ;;
    multisig-participant) reason='No wallet has a payment verification key to add as a participant.' ;;
    pool-owner) reason='No wallet has a stake verification key for a pool owner or reward account.' ;;
    *) reason='No suitable wallets for this action.' ;;
  esac
  printf -v "${destination}" '%s' "${reason}"
}

cntools_wallet_selection_candidate_into() {
  local destination="$1" index="$2" context="$3" directory="${CNTOOLS_WALLET_PATHS[$2]}" address='' candidate_annotation='' registration=''
  [[ -n "${context}" ]] || { printf -v "${destination}" ''; return 0; }
  if [[ "${CNTOOLS_WALLET_TYPES[index]}" == MultiSig ]]; then
    case "${context}" in
      send|collect) ;;
      funding|funding-software) return 1 ;; # These actions cannot spend from a native script.
      drep-script-create)
        ! cntools_wallet_selection_drep_present "${directory}" || return 1
        printf -v "${destination}" '%s' ''; return 0 ;;
      drep-register|drep-update|drep-retire|gov-vote|drep-info) cntools_wallet_selection_material "${directory}" drep || return 1 ;;
      register|deregister|delegate|vote-delegate|withdraw)
        cntools_wallet_file_present "${directory}" "${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}" || return 1 ;;
      *) return 1 ;;
    esac
    cntools_wallet_file_present "${directory}" "${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}" || return 1
    candidate_annotation='Native script · participants selected after wallet'
  else
    [[ "${CNTOOLS_WALLET_TYPES[index]}" != Unknown ]] || return 1
    # Read-only and key-creation contexts check only what their action needs.
    case "${context}" in
      drep-create)
        [[ "${CNTOOLS_WALLET_TYPES[index]}" == CLI || "${CNTOOLS_WALLET_TYPES[index]}" == Mnemonic ]] || return 1
        [[ "${CNTOOLS_WALLET_PROTECTIONS[index]}" == Open ]] || return 1
        ! cntools_wallet_selection_drep_present "${directory}" || return 1
        printf -v "${destination}" '%s' ''; return 0 ;;
      drep-script-create)
        # Only public script files are added, so type and protection don't matter.
        ! cntools_wallet_selection_drep_present "${directory}" || return 1
        printf -v "${destination}" '%s' ''; return 0 ;;
      multisig-derive)
        [[ "${CNTOOLS_WALLET_PROTECTIONS[index]}" == Open ]] || return 1
        cntools_wallet_selection_present "${directory}" "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" \
          "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" && return 1
        printf -v "${destination}" '%s' ''; return 0 ;;
      multisig-participant)
        cntools_wallet_selection_present "${directory}" "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" \
          "${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" || return 1
        printf -v "${destination}" '%s' ''; return 0 ;;
      pool-owner)
        cntools_wallet_file_present "${directory}" "${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" || return 1
        printf -v "${destination}" '%s' ''; return 0 ;;
      catalyst-key)
        cntools_wallet_file_present "${directory}" "${CNTOOLS_WALLET_CATALYST_VKEY_FILENAME:-catalyst.vkey}" || return 1
        printf -v "${destination}" '%s' ''; return 0 ;;
      catalyst-qr)
        cntools_wallet_file_present "${directory}" "${CNTOOLS_WALLET_CATALYST_SKEY_FILENAME:-catalyst.skey}" || return 1
        printf -v "${destination}" '%s' ''; return 0 ;;
      drep-info)
        cntools_wallet_selection_material "${directory}" drep || return 1
        printf -v "${destination}" '%s' ''; return 0 ;;
      drep-key)
        [[ ! -L "${directory}/${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}" && -f "${directory}/${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}" ]] || return 1
        printf -v "${destination}" '%s' ''; return 0 ;;
    esac
    cntools_wallet_selection_material "${directory}" payment || return 1
    case "${context}" in
      register|deregister|delegate|vote-delegate|withdraw|catalyst) cntools_wallet_selection_material "${directory}" stake || return 1 ;;
      drep-register|drep-update|drep-retire|gov-vote) cntools_wallet_selection_material "${directory}" drep || return 1 ;;
    esac
  fi
  if [[ "${context}" =~ ^(register|deregister|delegate|vote-delegate|withdraw)$ ]]; then
    candidate_annotation='Stake status checked after selection'
    if cntools_wallet_read_address "${directory}" reward address; then
      registration="${CNTOOLS_SELECTION_REGISTERED[${address}]:-}"
      [[ "${context}:${registration}" != register:yes && "${context}:${registration}" != deregister:no ]] || return 1
      [[ "${context}" != withdraw || "${CNTOOLS_SELECTION_REWARDS[${address}]:-unknown}" != 0 ]] || return 1
      if [[ "${context}" == withdraw && -n "${CNTOOLS_SELECTION_REWARDS[${address}]:-}" ]]; then
        candidate_annotation="Rewards $(cntools_number_format_lovelace "${CNTOOLS_SELECTION_REWARDS[${address}]}")"
      elif [[ "${context}" == deregister && "${CNTOOLS_SELECTION_REWARDS[${address}]:-0}" =~ ^[1-9][0-9]*$ ]]; then
        candidate_annotation="Rewards $(cntools_number_format_lovelace "${CNTOOLS_SELECTION_REWARDS[${address}]}") · withdraw first"
      elif [[ -n "${registration}" ]]; then
        [[ "${registration}" == yes ]] && candidate_annotation=Registered || candidate_annotation='Not registered · registration needed'
      fi
    fi
    [[ "${CNTOOLS_WALLET_TYPES[index]}" != MultiSig ]] || candidate_annotation="Native script · ${candidate_annotation}"
  fi
  if [[ "${context}" == funding-software && "${CNTOOLS_WALLET_TYPES[index]}" == Hardware ]]; then
    return 1 # A CLI or public-only pool cold key cannot share a Ledger session.
  fi
  if [[ "${context}" =~ ^(send|funding|funding-software)$ && "${CNTOOLS_WALLET_LIST_UTXO_LOVELACE[index]:-}" =~ ^[0-9]+$ ]]; then
    candidate_annotation="$(cntools_number_format_lovelace "${CNTOOLS_WALLET_LIST_UTXO_LOVELACE[index]}")${candidate_annotation:+ · ${candidate_annotation}}"
  fi
  printf -v "${destination}" '%s' "${candidate_annotation}"
}
