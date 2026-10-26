#!/usr/bin/env bash
# Guided, cancellable participant derivation and threshold wallet creation.
# shellcheck disable=SC2034

cntools_multisig_begin() {
  cntools_gum_clear
  cntools_ui_action_begin "$1" "/ Advanced / MultiSig / $1"
}

cntools_multisig_prompt_path() {
  local destination="$1" prompt="$2" default="$3" role="$4" mode="$5" entered='' normal='' role_hint='0 or 1'
  [[ "${role}" == payment ]] || role_hint=2
  while true; do
    cntools_ui_input entered "${prompt}" "${default}" || return $?
    [[ -n "${entered}" ]] || entered="${default}"
    if cntools_multisig_path_into normal "${entered}" &&
       { [[ "${mode}" != mnemonic ]] || cntools_multisig_mnemonic_path_valid "${normal}" "${role}"; }; then
      printf -v "${destination}" '%s' "${normal}"; return 0
    fi
    if [[ "${mode}" == mnemonic ]]; then
      cntools_ui_render_status warn "Use purpose/coin_type/account/role/index with role ${role_hint}, and H for hardened indices. Each index must be 0–2,147,483,647."
    else
      cntools_ui_render_status warn 'Use 3–10 slash-separated indices, with H for hardened indices. Each index must be 0–2,147,483,647.'
    fi
  done
}

cntools_multisig_source_label_into() {
  case "$2" in
    mnemonic) printf -v "$1" '%s' 'Existing recovery phrase' ;;
    hardware) printf -v "$1" '%s' 'Hardware device' ;;
    *) printf -v "$1" '%s' 'New independent CLI keys' ;;
  esac
}

cntools_multisig_derive_workflow() {
  local selected='' directory='' choice='' mode='' account='' index='' pay_path='' stake_path='' phrase='' status=0 source='' note='' payment='' stake=''
  local -a sources=() missing=()
  local CNTOOLS_MNEMONIC_INPUT_PATH='/ Advanced / MultiSig / Derive Keys'
  cntools_multisig_begin 'Derive Keys'
  # Only open wallets without participant keys can take new ones.
  cntools_wallet_catalog_build || return 2
  cntools_wallet_choose selected Cancel multisig-derive || return $?
  directory="${CNTOOLS_WALLET_PATHS[selected]}"
  cntools_multisig_key_preflight "${directory}" || return 2
  # Offer only the sources whose tool is installed, and say which are missing.
  if type -P "${CNTOOLS_MULTISIG_ADDRESS_TOOL:-cardano-address}" >/dev/null 2>&1; then sources+=('Existing recovery phrase')
  else missing+=('cardano-address (recovery phrase)'); fi
  sources+=('New independent CLI keys')
  if type -P "${CNTOOLS_HWCLI:-cardano-hw-cli}" >/dev/null 2>&1; then sources+=('Hardware device')
  else missing+=('cardano-hw-cli (hardware device)'); fi
  if (( ${#missing[@]} > 0 )); then
    printf -v note '%s · ' "${missing[@]}"; note="Not offered until installed: ${note% · }."
  fi
  if (( ${#sources[@]} == 1 )); then
    choice="${sources[0]}"
    cntools_log CHOICE "Multisig key source auto-selected=${choice} (other tools unavailable)" || true
  else
    cntools_ui_render_status info 'Add a separate participant payment/stake key pair. Existing wallet keys and addresses stay unchanged.'
    [[ -z "${note}" ]] || cntools_ui_render_status info "${note}"
    note='' # Seen with the picker; the review need not repeat it.
    cntools_ui_choose choice 'Participant key source' "${sources[@]}" Cancel || return $?
    cntools_log CHOICE "Multisig key source selected=${choice}" || true
  fi
  case "${choice}" in
    'Existing recovery phrase') mode=mnemonic ;;
    'New independent CLI keys') mode=cli ;;
    'Hardware device') mode=hardware ;;
    *) return 1 ;;
  esac
  if [[ "${mode}" != cli ]]; then
    if cntools_flow_quick; then choice='Standard multisig (1854)'
    else cntools_ui_choose choice 'Derivation paths' 'Standard multisig (1854)' 'Custom payment and stake paths' Cancel || return $?; fi
    cntools_log CHOICE "Multisig derivation layout selected=${choice}" || true
    case "${choice}" in
      'Standard multisig (1854)')
        cntools_wallet_mnemonic_prompt_index_into account 'Account number (default: 0)' 'Derive Keys' '/ Advanced / MultiSig / Derive Keys' &&
          cntools_wallet_mnemonic_prompt_index_into index 'Key index (default: 0)' 'Derive Keys' '/ Advanced / MultiSig / Derive Keys' || return $?
        pay_path="1854H/1815H/${account}H/0/${index}"; stake_path="1854H/1815H/${account}H/2/${index}"
        ;;
      'Custom payment and stake paths')
        cntools_multisig_prompt_path pay_path 'Payment derivation path' '1854H/1815H/0H/0/0' payment "${mode}" &&
          cntools_multisig_prompt_path stake_path 'Stake derivation path' '1854H/1815H/0H/2/0' stake "${mode}" || return $?
        ;;
      *) return 1 ;;
    esac
  fi
  cntools_multisig_source_label_into source "${mode}"
  cntools_multisig_begin 'Derive Keys'
  {
    cntools_table_pair Wallet "${directory##*/}" identifier
    cntools_table_pair Source "${source}" value
    [[ "${mode}" == cli ]] || { cntools_table_pair 'Payment path' "${pay_path}" identifier; cntools_table_pair 'Stake path' "${stake_path}" identifier; }
  } | cntools_table_render 'Participant keys' || return 2
  [[ -z "${note}" ]] || cntools_ui_render_status info "${note}"
  if [[ "${mode}" == mnemonic ]]; then
    cntools_multisig_address_tool_ready || return 2
    cntools_ui_render_status warn 'Use software-wallet recovery words only. Never enter hardware-wallet recovery words into CNTools.'
    cntools_ui_flow_confirm 'Add these participant keys without replacing existing files?' false || return $?
  elif [[ "${mode}" == hardware ]]; then
    # The device step follows at once, so both styles stop here.
    cntools_ui_render_status info 'Connect and unlock the hardware device. Support for the chosen paths depends on its firmware.'
    cntools_ui_confirm 'The hardware device is connected and unlocked. Add these participant keys?' true || return $?
  else
    cntools_ui_flow_confirm 'Add these participant keys without replacing existing files?' false || return $?
  fi
  cntools_log CHOICE "Multisig key generation confirmed wallet=${directory##*/} mode=${mode} payment_path=${pay_path:-none} stake_path=${stake_path:-none}" || true
  if [[ "${mode}" == mnemonic ]]; then
    cntools_wallet_mnemonic_collect_import_into phrase || return $?
  fi
  cntools_ui_spin_function 'Creating and validating participant keys…' cntools_multisig_key_generate "${directory}" "${mode}" "${pay_path}" "${stake_path}" "${phrase}" || status=$?
  unset phrase
  ((status == 0)) || return 2
  cntools_wallet_id_read_credential "${directory}" ms-payment payment || payment=Unavailable
  cntools_wallet_id_read_credential "${directory}" ms-stake stake || stake=Unavailable
  cntools_multisig_begin 'Derive Keys'
  {
    cntools_table_pair Wallet "${directory##*/}" identifier
    cntools_table_pair Result 'Participant keys added; existing keys unchanged' success
    cntools_table_pair 'Payment key hash' "${payment}" identifier
    cntools_table_pair 'Stake key hash' "${stake}" identifier
    cntools_table_pair Files "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}* in ${directory}" identifier
  } | cntools_table_render 'Participant keys'
  cntools_ui_render_status info 'Other participants add these hashes with MultiSig → Create → Add external key hashes.'
  # An auto-picked source names the tools that would offer the others.
  [[ -z "${note}" ]] || cntools_ui_render_status info "${note}"
  cntools_ui_render_status warn 'Back up these participant keys. Use Wallet → Encrypt to protect software signing keys.'
}

cntools_multisig_action_derive() {
  local status=0 traced=N
  case "$-" in *x*) traced=Y; set +x ;; esac
  cntools_multisig_derive_workflow || status=$?
  case "${status}" in
    0) cntools_ui_wait ;;
    3) status=0 ;; # Nothing to choose; the reason was shown and acknowledged.
    1|130) cntools_log CHOICE 'Multisig derivation cancelled' || true ;;
    *)
      cntools_multisig_fail "${CNTOOLS_MULTISIG_ERROR:-${CNTOOLS_WALLET_HARDWARE_ERROR:-${CNTOOLS_WALLET_CREATE_ERROR:-Participant derivation could not complete.}}}" || true
      cntools_ui_render_status error "${CNTOOLS_MULTISIG_ERROR} See ${CNTOOLS_LOG} for details."
      cntools_ui_wait
      status=1 ;; # Shown and acknowledged above; no second failure banner.
  esac
  [[ "${traced}" != Y ]] || set -x
  return "${status}"
}

# Sets CNTOOLS_MULTISIG_NOTICE for the redrawn participant list.
cntools_multisig_local_participant() {
  local selected='' directory='' prefix='' choice='' payment='' stake='' output='' errors='' role='' file='' hash='' status=0
  local -a pairs=()
  # Lists only non-script wallets with a payment verification key. 3 = none.
  cntools_wallet_catalog_build || return 2
  cntools_wallet_choose selected Cancel multisig-participant || return $?
  directory="${CNTOOLS_WALLET_PATHS[selected]}"
  cntools_wallet_prepare_selected_material "${directory}" || return 2
  # Offer only the key pairs this wallet has; a lone pair needs no question.
  [[ ! -e "${directory}/${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" ]] || pairs+=('Multisig participant keys')
  [[ ! -e "${directory}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" ]] || pairs+=('Regular wallet keys')
  case "${#pairs[@]}" in
    0) cntools_multisig_fail 'This wallet has no payment verification key to add as a participant.'; return 2 ;;
    1)
      choice="${pairs[0]}"
      cntools_log CHOICE "Multisig participant key pair auto-selected=${choice}" || true
      CNTOOLS_MULTISIG_NOTICE="Used ${choice,}, the only key pair in ${directory##*/}." ;;
    *) cntools_ui_choose choice 'Participant key pair' "${pairs[@]}" Cancel || return $? ;;
  esac
  case "${choice}" in
    'Multisig participant keys') prefix="${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}" ;;
    'Regular wallet keys')
      CNTOOLS_MULTISIG_NOTICE="${CNTOOLS_MULTISIG_NOTICE:+${CNTOOLS_MULTISIG_NOTICE} }Regular wallet keys are valid native-script participants. Dedicated 1854 keys keep signing roles separate." ;;
    *) return 1 ;;
  esac
  cntools_transaction_temp_file output multisig-hash && cntools_transaction_temp_file errors multisig-errors || return 2
  for role in payment stake; do
    if [[ "${role}" == payment ]]; then file="${directory}/${prefix}${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"; else file="${directory}/${prefix}${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"; fi
    if [[ ! -e "${file}" && "${role}" == stake ]]; then continue; fi
    cntools_wallet_key_validate "${file}" "${role}" any || { cntools_multisig_fail 'That participant verification key is missing or invalid.'; return 2; }
    status=0
    if [[ "${role}" == payment ]]; then
      cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" address key-hash --payment-verification-key-file "${file}" || status=$?
    else
      cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" latest stake-address key-hash --stake-verification-key-file "${file}" || status=$?
    fi
    ((status == 0)) || return 2
    hash="$(< "${output}")"
    [[ "${role}" != payment ]] && stake="${hash}" || payment="${hash}"
  done
  cntools_multisig_participant_add "${payment}" "${stake}" "${directory##*/}" || return 2
}

cntools_multisig_render_participants() {
  local index=0
  (( ${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]} > 0 )) || return 0
  {
    for index in "${!CNTOOLS_MULTISIG_PAYMENT_HASHES[@]}"; do
      cntools_table_pair "$((index+1)) · Participant" "${CNTOOLS_MULTISIG_LABELS[index]}" identifier
      cntools_table_pair 'Payment key hash' "${CNTOOLS_MULTISIG_PAYMENT_HASHES[index]}" identifier
      [[ -z "${CNTOOLS_MULTISIG_STAKE_HASHES[index]}" ]] || cntools_table_pair 'Stake key hash' "${CNTOOLS_MULTISIG_STAKE_HASHES[index]}" identifier
    done
  } | cntools_table_render Participants
}

cntools_multisig_prompt_bound() {
  local destination="$1" title="$2" entered='' units='' choice=''
  cntools_ui_choose choice "${title}" 'No bound' 'Start of epoch' 'Absolute slot' Cancel || return $?
  case "${choice}" in 'No bound') printf -v "${destination}" ''; return 0 ;; Cancel) return 1 ;; esac
  while true; do
    cntools_ui_input entered "${title} · $([[ "${choice}" == 'Start of epoch' ]] && printf Epoch || printf Slot) (blank = no bound)" '' || return $?
    if [[ -z "${entered}" ]]; then printf -v "${destination}" ''; return 0; fi
    if [[ "${choice}" == 'Start of epoch' ]]; then
      if cntools_number_normalize_into units "${entered}" && cntools_epoch_start_slot_into units "${units}"; then
        printf -v "${destination}" '%s' "${units}"; return 0
      fi
      cntools_ui_render_status warn 'Enter an epoch number from 0 through 9,999,999, or leave blank.'
      continue
    fi
    if cntools_number_normalize_into units "${entered}" && cntools_transaction_slot_value_valid "${units}" && ((units<=9999999999999)); then
      printf -v "${destination}" '%s' "${units}"; return 0
    fi
    cntools_ui_render_status warn 'Enter a non-negative absolute slot number, optionally with commas, or leave blank.'
  done
}

# One table for the review and the result: what the address will enforce.
cntools_multisig_render_script_wallet() {
  local name="$1" threshold="$2" staking="$3" after="$4" before="$5" title="$6" date='' now='' role=value
  now="$(cntools_health_reference_slot "${CNTOOLS_NETWORK:-}" 2>/dev/null)" || now=''
  {
    cntools_table_pair Wallet "${name}" identifier
    cntools_table_pair Threshold "${threshold} of ${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]}" number
    cntools_table_pair Staking "$([[ "${staking}" == Y ]] && printf 'Threshold stake script' || printf 'Payment only')" value
    date='Immediately'; [[ -z "${after}" ]] || cntools_slot_datetime_into date "${after}" || date="Slot ${after}"
    # A start more than a year away is easy to mistype.
    [[ -z "${after}" || ! "${now}" =~ ^[0-9]+$ ]] || (( after - now <= 31536000 )) || { date+=' · more than a year away'; role=warning; }
    cntools_table_pair 'Spending starts' "${date}" "${role}"
    date='No expiry'; [[ -z "${before}" ]] || cntools_slot_datetime_into date "${before}" || date="Slot ${before}"
    cntools_table_pair 'Spending ends' "${date}" warning
    [[ -z "${CNTOOLS_WALLET_CREATED_DIRECTORY:-}" || -z "${7:-}" ]] || cntools_table_pair "$7" "$8" address
  } | cntools_table_render "${title}"
}

cntools_multisig_create_workflow() {
  local name='' choice='' payment='' stake='' threshold='' normalized='' staking=N after='' before='' date='' status=0 warning='' now=''
  CNTOOLS_MULTISIG_NOTICE=''; CNTOOLS_WALLET_CREATED_DIRECTORY=''
  cntools_multisig_participants_reset
  cntools_multisig_begin Create
  cntools_wallet_create_environment_ready || return 2
  while true; do
    cntools_ui_input name 'New multisig wallet name' '' || return $?
    cntools_wallet_create_name_valid "${name}" && cntools_wallet_create_target_available "${name}" && break
    cntools_ui_render_status warn 'Use a valid unused wallet name (1–64 letters, numbers, dots, underscores or hyphens).'
  done
  # Refusals show on the redrawn list instead of behind a Press Enter.
  while true; do
    cntools_multisig_begin Create
    cntools_multisig_render_participants || return 2
    [[ -z "${warning}" ]] || cntools_ui_render_status warn "${warning}"
    [[ -z "${CNTOOLS_MULTISIG_NOTICE}" ]] || cntools_ui_render_status info "${CNTOOLS_MULTISIG_NOTICE}"
    warning=''; CNTOOLS_MULTISIG_NOTICE=''; CNTOOLS_MULTISIG_ERROR=''
    cntools_ui_choose choice 'Participants' 'Add CNTools wallet' 'Add external key hashes' 'Remove last participant' 'Done' Cancel || return $?
    cntools_log CHOICE "Multisig creation participant menu selected=${choice}" || true
    case "${choice}" in
      'Add CNTools wallet'|'Add external key hashes')
        if (( ${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]} >= 20 )); then warning='At most 20 participants are supported.'; continue; fi ;;&
      'Add CNTools wallet')
        # 1/130 = cancelled pick; 3 = no suitable wallet, already shown and acknowledged.
        status=0; cntools_multisig_local_participant || status=$?
        if ((status != 0 && status != 1 && status != 130 && status != 3)); then warning="${CNTOOLS_MULTISIG_ERROR:-Could not add that participant.}"; CNTOOLS_MULTISIG_NOTICE=''; fi
        ;;
      'Add external key hashes')
        cntools_ui_input payment 'Payment key hash (56 hex characters)' '' || continue
        cntools_ui_input stake 'Stake key hash (blank = payment-only participant)' '' || continue
        if ! cntools_multisig_participant_add "${payment}" "${stake}" "External $((${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]}+1))"; then
          warning="${CNTOOLS_MULTISIG_ERROR:-Invalid participant hashes.}"
        fi
        ;;
      'Remove last participant')
        if (( ${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]} > 0 )); then
          unset 'CNTOOLS_MULTISIG_PAYMENT_HASHES[-1]' 'CNTOOLS_MULTISIG_STAKE_HASHES[-1]' 'CNTOOLS_MULTISIG_LABELS[-1]'
        else warning='There are no participants to remove.'; fi ;;
      Done)
        (( ${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]} > 0 )) && break
        warning='Add at least one participant before continuing.' ;;
      *) return 1 ;;
    esac
  done
  if (( ${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]} == 1 )); then
    threshold=1 # One participant: 1 of 1 is the only threshold.
    cntools_log CHOICE 'Multisig threshold auto-selected=1 (single participant)' || true
  else
    while true; do
      cntools_ui_input threshold "Required signatures (1–${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]})" "${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]}" || return $?
      [[ -n "${threshold}" ]] || threshold="${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]}"
      if cntools_number_normalize_into normalized "${threshold}" && [[ "${normalized}" =~ ^[1-9][0-9]?$ ]] && ((normalized<=${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]})); then threshold="${normalized}"; break; fi
      cntools_ui_render_status warn 'The threshold must be at least one and no greater than the participant count.'
    done
  fi
  staking=Y
  for stake in "${CNTOOLS_MULTISIG_STAKE_HASHES[@]}"; do [[ -n "${stake}" ]] || staking=N; done
  if [[ "${staking}" == Y ]]; then
    cntools_ui_choose choice 'Stake address' 'Include threshold stake script' 'Payment-only wallet' Cancel || return $?
    case "${choice}" in 'Include threshold stake script') ;; 'Payment-only wallet') staking=N ;; *) return 1 ;; esac
  else
    cntools_ui_render_status info 'At least one participant has no stake hash. This will be a payment-only wallet.'
  fi
  while true; do
    cntools_multisig_prompt_bound after 'Spendable from' && cntools_multisig_prompt_bound before 'Spendable before' || return $?
    if [[ -n "${after}" && -n "${before}" ]] && ((after >= before)); then
      cntools_ui_render_status warn 'The spending start must be before its expiry. Choose the time bounds again.'; continue
    fi
    # A past expiry creates an address whose funds can never be spent.
    now="$(cntools_health_reference_slot "${CNTOOLS_NETWORK:-}" 2>/dev/null)" || now=''
    if [[ -n "${before}" && "${now}" =~ ^[0-9]+$ ]] && ((before <= now)); then
      cntools_slot_datetime_into date "${before}" || date="slot ${before}"
      cntools_ui_render_status warn "Spendable before (${date}) has already passed, so funds sent to this address could never be spent. Choose a future bound or No bound."
      continue
    fi
    break
  done
  cntools_multisig_begin Create
  cntools_multisig_render_participants || return 2
  cntools_multisig_render_script_wallet "${name}" "${threshold}" "${staking}" "${after}" "${before}" 'Script wallet' || return 2
  cntools_ui_render_status warn 'Participants, threshold and timelocks cannot be changed for this address. An expiry permanently locks remaining funds. Check and back up participant keys before funding it.'
  # An expiry can lock funds for good, so it is confirmed in both styles.
  if [[ -n "${before}" ]]; then cntools_ui_confirm 'Create this multisig wallet with a spending expiry?' false || return $?
  else cntools_ui_flow_confirm 'Create this multisig wallet?' false || return $?; fi
  cntools_log CHOICE "Multisig creation confirmed wallet=${name} threshold=${threshold} staking=${staking} after=${after:-none} before=${before:-none}" || true
  cntools_multisig_wallet_create "${name}" "${threshold}" "${staking}" "${after}" "${before}" || return 2
  cntools_wallet_address_primary_into "${CNTOOLS_WALLET_CREATED_DIRECTORY}" payment choice stake || return 2
  cntools_multisig_begin Create
  cntools_ui_render_status success 'Multisig wallet created. No funds were spent and no participant private keys were copied.'
  cntools_multisig_render_script_wallet "${name}" "${threshold}" "${staking}" "${after}" "${before}" Wallet "${choice}" "${payment}"
}

cntools_multisig_action_create() {
  local status=0
  CNTOOLS_MULTISIG_ERROR=''
  cntools_multisig_create_workflow || status=$?
  case "${status}" in
    0) cntools_ui_wait ;;
    1|130) cntools_log CHOICE 'Multisig creation cancelled' || true ;;
    *)
      cntools_ui_render_status error "${CNTOOLS_MULTISIG_ERROR:-${CNTOOLS_WALLET_CREATE_ERROR:-Multisig creation failed.}} See ${CNTOOLS_LOG} for details."
      cntools_ui_wait
      status=1 ;; # Shown and acknowledged above; no second failure banner.
  esac
  return "${status}"
}
