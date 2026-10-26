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
       { [[ "${mode}" != mnemonic ]] || cntools_multisig_mnemonic_path_valid "${normal}" "${role}"; } &&
       { [[ "${mode}" != hardware ]] || cntools_multisig_hardware_path_valid "${normal}"; }; then
      printf -v "${destination}" '%s' "${normal}"; return 0
    fi
    if [[ "${mode}" == mnemonic ]]; then
      cntools_ui_render_status warn "Use purpose/coin_type/account/role/index with role ${role_hint}, and H for hardened indices. Each index must be 0–2,147,483,647."
    elif [[ "${mode}" == hardware ]]; then
      cntools_ui_render_status warn 'Use purpose/coin_type/account/role/index with a hardened purpose other than 44H, and H for hardened indices. Each index must be 0–2,147,483,647.'
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

# Standard 1854 account/index or custom paths, with the current paths as the
# defaults. Esc (1) keeps them.
cntools_multisig_derive_paths_into() {
  local _msd_pay_name="$1" _msd_stake_name="$2" _msd_mode="$3" _msd_layout='' _msd_account=0 _msd_index=0 _msd_pay='' _msd_stake=''
  local _msd_breadcrumb='/ Advanced / MultiSig / Derive Keys'
  cntools_ui_choose _msd_layout 'Derivation paths' 'Standard multisig (1854)' 'Custom payment and stake paths' Cancel || return $?
  cntools_log CHOICE "Multisig derivation layout selected=${_msd_layout}" || true
  case "${_msd_layout}" in
    'Standard multisig (1854)')
      if [[ "${!_msd_pay_name}" =~ ^1854H/1815H/([0-9]+)H/0/([0-9]+)$ ]]; then _msd_account="${BASH_REMATCH[1]}"; _msd_index="${BASH_REMATCH[2]}"; fi
      cntools_wallet_mnemonic_prompt_index_into _msd_account 'Account number' 'Derive Keys' "${_msd_breadcrumb}" "${_msd_account}" &&
        cntools_wallet_mnemonic_prompt_index_into _msd_index 'Key index' 'Derive Keys' "${_msd_breadcrumb}" "${_msd_index}" || return $?
      _msd_pay="1854H/1815H/${_msd_account}H/0/${_msd_index}"; _msd_stake="1854H/1815H/${_msd_account}H/2/${_msd_index}" ;;
    'Custom payment and stake paths')
      cntools_multisig_prompt_path _msd_pay 'Payment derivation path' "${!_msd_pay_name}" payment "${_msd_mode}" &&
        cntools_multisig_prompt_path _msd_stake 'Stake derivation path' "${!_msd_stake_name}" stake "${_msd_mode}" || return $? ;;
    *) return 1 ;;
  esac
  printf -v "${_msd_pay_name}" '%s' "${_msd_pay}"; printf -v "${_msd_stake_name}" '%s' "${_msd_stake}"
  cntools_log CHOICE "Multisig derivation paths payment=${_msd_pay} stake=${_msd_stake}" || true
}

cntools_multisig_derive_workflow() {
  local selected='' directory='' choice='' mode='' pay_path='' stake_path='' phrase='' status=0 source='' note='' payment='' stake='' proceed=''
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
    # Standard 1854 at account and index 0 unless Detailed asks; the review
    # offers 'Change derivation paths' in both styles.
    pay_path='1854H/1815H/0H/0/0'; stake_path='1854H/1815H/0H/2/0'
    if cntools_flow_quick; then cntools_log CHOICE 'Multisig derivation default=1854 account=0 index=0 flow=quick' || true
    else cntools_multisig_derive_paths_into pay_path stake_path "${mode}" || return $?; fi
  fi
  [[ "${mode}" != mnemonic ]] || cntools_multisig_address_tool_ready || return 2
  cntools_multisig_source_label_into source "${mode}"
  [[ "${mode}" == hardware ]] && proceed='Add keys from the connected device' || proceed='Add participant keys'
  # New key material is confirmed in both flow styles.
  while true; do
    cntools_multisig_begin 'Derive Keys'
    {
      cntools_table_pair Wallet "${directory##*/}" identifier
      cntools_table_pair Source "${source}" value
      [[ "${mode}" == cli ]] || { cntools_table_pair 'Payment path' "${pay_path}" identifier; cntools_table_pair 'Stake path' "${stake_path}" identifier; }
    } | cntools_table_render 'Participant keys' || return 2
    # An auto-picked source names the tools that would offer the others.
    [[ -z "${note}" ]] || cntools_ui_render_status info "${note}"
    case "${mode}" in
      mnemonic) cntools_ui_render_status warn 'Use software-wallet recovery words only. Never enter hardware-wallet recovery words into CNTools.' ;;
      hardware) cntools_ui_render_status info 'Connect and unlock the hardware device. Support for the chosen paths depends on its firmware.' ;;
      *)
        cntools_ui_confirm 'Add these participant keys without replacing existing files?' false || return $?
        break ;;
    esac
    cntools_ui_choose choice 'Participant keys' "${proceed}" 'Change derivation paths' Cancel || return $?
    case "${choice}" in
      "${proceed}") break ;;
      'Change derivation paths')
        status=0; cntools_multisig_derive_paths_into pay_path stake_path "${mode}" || status=$?
        ((status == 0 || status == 1)) || return "${status}" ;;
      *) return 1 ;;
    esac
  done
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
  # Wallets already added are not offered again.
  CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS=()
  for directory in "${CNTOOLS_MULTISIG_DIRECTORIES[@]}"; do [[ -z "${directory}" ]] || CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS+=("${directory}"); done
  cntools_wallet_choose selected Cancel multisig-participant || status=$?
  CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS=()
  ((status == 0)) || return "${status}"
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
  cntools_multisig_participant_add "${payment}" "${stake}" "${directory##*/}" "${directory}" || return 2
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

# Spending window. A rejected 'Spendable before' asks only that bound again.
cntools_multisig_prompt_bounds_into() {
  local _msb_after_name="$1" _msb_before_name="$2" _msb_after='' _msb_before='' _msb_now='' _msb_date=''
  cntools_multisig_prompt_bound _msb_after 'Spendable from' || return $?
  while true; do
    cntools_multisig_prompt_bound _msb_before 'Spendable before' || return $?
    if [[ -n "${_msb_after}" && -n "${_msb_before}" ]] && ((_msb_after >= _msb_before)); then
      cntools_ui_render_status warn 'Spendable before must be later than Spendable from. Choose it again.'; continue
    fi
    # A past expiry creates an address whose funds can never be spent.
    _msb_now="$(cntools_health_reference_slot "${CNTOOLS_NETWORK:-}" 2>/dev/null)" || _msb_now=''
    if [[ -n "${_msb_before}" && "${_msb_now}" =~ ^[0-9]+$ ]] && ((_msb_before <= _msb_now)); then
      cntools_slot_datetime_into _msb_date "${_msb_before}" || _msb_date="slot ${_msb_before}"
      cntools_ui_render_status warn "Spendable before (${_msb_date}) has already passed, so funds sent to this address could never be spent. Choose a future bound or No bound."
      continue
    fi
    break
  done
  printf -v "${_msb_after_name}" '%s' "${_msb_after}"; printf -v "${_msb_before_name}" '%s' "${_msb_before}"
  cntools_log CHOICE "Multisig time bounds after=${_msb_after:-none} before=${_msb_before:-none}" || true
}

# Enter keeps the current threshold (all participants at first).
cntools_multisig_prompt_threshold_into() {
  local _mst_output="$1" _mst_count="${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]}" _mst_current="${2:-}" _mst_entered='' _mst_normalized=''
  [[ -n "${_mst_current}" ]] || _mst_current="${_mst_count}"
  while true; do
    cntools_ui_input _mst_entered "Required signatures (1–${_mst_count})" "${_mst_current}" || return $?
    [[ -n "${_mst_entered}" ]] || _mst_entered="${_mst_current}"
    if cntools_number_normalize_into _mst_normalized "${_mst_entered}" && [[ "${_mst_normalized}" =~ ^[1-9][0-9]?$ ]] && ((_mst_normalized<=_mst_count)); then
      printf -v "${_mst_output}" '%s' "${_mst_normalized}"
      cntools_log CHOICE "Multisig threshold selected=${_mst_normalized} of ${_mst_count}" || true
      return 0
    fi
    cntools_ui_render_status warn 'The threshold must be at least one and no greater than the participant count.'
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

# The participant list. Esc or Cancel returns 1: at the start that cancels
# the action; from the review it keeps the previous participants.
cntools_multisig_participants_edit() {
  local choice='' payment='' stake='' status=0 warning=''
  local -a options=()
  # Refusals show on the redrawn list instead of behind a Press Enter.
  while true; do
    cntools_multisig_begin Create
    cntools_multisig_render_participants || return 2
    [[ -z "${warning}" ]] || cntools_ui_render_status warn "${warning}"
    [[ -z "${CNTOOLS_MULTISIG_NOTICE}" ]] || cntools_ui_render_status info "${CNTOOLS_MULTISIG_NOTICE}"
    warning=''; CNTOOLS_MULTISIG_NOTICE=''; CNTOOLS_MULTISIG_ERROR=''
    options=('Add CNTools wallet' 'Add external key hashes')
    (( ${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]} == 0 )) || options+=('Remove last participant' 'Done')
    cntools_ui_choose choice 'Participants' "${options[@]}" Cancel || return $?
    cntools_log CHOICE "Multisig creation participant menu selected=${choice}" || true
    case "${choice}" in
      'Add CNTools wallet'|'Add external key hashes')
        if (( ${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]} >= 20 )); then warning='At most 20 participants are supported.'; continue; fi ;;&
      'Add CNTools wallet')
        # 1 = cancelled pick; 3 = no suitable wallet, already shown and
        # acknowledged; Ctrl+C cancels the action.
        status=0; cntools_multisig_local_participant || status=$?
        ((status != 130)) || return 130
        if ((status != 0 && status != 1 && status != 3)); then warning="${CNTOOLS_MULTISIG_ERROR:-Could not add that participant.}"; CNTOOLS_MULTISIG_NOTICE=''; fi
        ;;
      'Add external key hashes')
        # Esc returns to the participant list; Ctrl+C cancels the action.
        status=0
        cntools_ui_input payment 'Payment key hash (56 hex characters)' '' &&
          cntools_ui_input stake 'Stake key hash (blank = payment-only participant)' '' || status=$?
        ((status != 130)) || return 130
        ((status == 0)) || continue
        if ! cntools_multisig_participant_add "${payment}" "${stake}" "External $((${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]}+1))"; then
          warning="${CNTOOLS_MULTISIG_ERROR:-Invalid participant hashes.}"
        fi
        ;;
      'Remove last participant')
        unset 'CNTOOLS_MULTISIG_PAYMENT_HASHES[-1]' 'CNTOOLS_MULTISIG_STAKE_HASHES[-1]' 'CNTOOLS_MULTISIG_LABELS[-1]' 'CNTOOLS_MULTISIG_DIRECTORIES[-1]' ;;
      Done) return 0 ;;
      *) return 1 ;;
    esac
  done
}

# Y when every participant has a stake key hash (a stake script is possible).
cntools_multisig_staking_possible() {
  local hash=''
  for hash in "${CNTOOLS_MULTISIG_STAKE_HASHES[@]}"; do [[ -n "${hash}" ]] || return 1; done
}

cntools_multisig_create_workflow() {
  local name='' choice='' payment='' stake='' threshold='' staking=N wanted=Y after='' before='' status=0 count=0 previous_count=0 warning=''
  local -a review=() saved_payment=() saved_stake=() saved_labels=() saved_directories=()
  CNTOOLS_MULTISIG_NOTICE=''; CNTOOLS_WALLET_CREATED_DIRECTORY=''
  cntools_multisig_participants_reset
  cntools_multisig_begin Create
  cntools_wallet_create_environment_ready || return 2
  while true; do
    cntools_ui_input name 'New multisig wallet name' '' || return $?
    cntools_wallet_create_name_valid "${name}" && cntools_wallet_create_target_available "${name}" && break
    cntools_ui_render_status warn 'Use a valid unused wallet name (1–64 letters, numbers, dots, underscores or hyphens).'
  done
  cntools_multisig_participants_edit || return $?
  count="${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]}"
  # Quick uses all participants, a stake script when every participant has a
  # stake key, and no time bounds; the review changes each of them.
  threshold="${count}"
  if (( count == 1 )); then
    cntools_log CHOICE 'Multisig threshold auto-selected=1 (single participant)' || true
  elif cntools_flow_quick; then
    cntools_log CHOICE "Multisig threshold default=${count} of ${count} flow=quick" || true
  else
    cntools_multisig_prompt_threshold_into threshold || return $?
  fi
  if cntools_multisig_staking_possible && ! cntools_flow_quick; then
    cntools_ui_choose choice 'Stake address' 'Include threshold stake script' 'Payment-only wallet' Cancel || return $?
    case "${choice}" in 'Include threshold stake script') ;; 'Payment-only wallet') wanted=N ;; *) return 1 ;; esac
  fi
  if cntools_flow_quick; then cntools_log CHOICE 'Multisig time bounds default=none flow=quick' || true
  else cntools_multisig_prompt_bounds_into after before || return $?; fi
  # Inside a Change step Esc keeps the current values; Ctrl+C cancels.
  while true; do
    count="${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]}"
    staking=N; ! cntools_multisig_staking_possible || staking="${wanted}"
    review=('Create multisig wallet' 'Change participants')
    (( count == 1 )) || review+=('Change threshold')
    ! cntools_multisig_staking_possible || review+=('Change stake address')
    review+=('Change time bounds')
    cntools_multisig_begin Create
    cntools_multisig_render_participants || return 2
    cntools_multisig_render_script_wallet "${name}" "${threshold}" "${staking}" "${after}" "${before}" 'Script wallet' || return 2
    cntools_multisig_staking_possible || cntools_ui_render_status info 'At least one participant has no stake key hash, so this is a payment-only wallet.'
    warning='Participants, threshold and timelocks cannot be changed for this address.'
    [[ -z "${before}" ]] || warning+=' Its spending expiry permanently locks any funds left after it.'
    cntools_ui_render_status warn "${warning} Check and back up participant keys before funding it."
    cntools_ui_choose choice 'Review multisig wallet' "${review[@]}" Cancel || return $?
    cntools_log CHOICE "Multisig creation review selected=${choice}" || true
    status=0
    case "${choice}" in
      'Create multisig wallet')
        # An expiry can lock funds for good, so it is asked again (default No).
        [[ -n "${before}" ]] || break
        cntools_ui_confirm "Create ${name} with a spending expiry?" false || status=$?
        ((status == 0)) && break ;;
      'Change participants')
        saved_payment=("${CNTOOLS_MULTISIG_PAYMENT_HASHES[@]}"); saved_stake=("${CNTOOLS_MULTISIG_STAKE_HASHES[@]}")
        saved_labels=("${CNTOOLS_MULTISIG_LABELS[@]}"); saved_directories=("${CNTOOLS_MULTISIG_DIRECTORIES[@]}")
        previous_count="${count}"
        cntools_multisig_participants_edit || status=$?
        if ((status != 0)); then
          CNTOOLS_MULTISIG_PAYMENT_HASHES=("${saved_payment[@]}"); CNTOOLS_MULTISIG_STAKE_HASHES=("${saved_stake[@]}")
          CNTOOLS_MULTISIG_LABELS=("${saved_labels[@]}"); CNTOOLS_MULTISIG_DIRECTORIES=("${saved_directories[@]}")
        else
          # All participants stay all; a lower threshold stays within the new count.
          count="${#CNTOOLS_MULTISIG_PAYMENT_HASHES[@]}"
          if (( threshold == previous_count || threshold > count )); then threshold="${count}"; fi
          cntools_log CHOICE "Multisig participants changed count=${count} threshold=${threshold}" || true
        fi ;;
      'Change threshold') cntools_multisig_prompt_threshold_into threshold "${threshold}" || status=$? ;;
      'Change stake address')
        cntools_ui_choose choice 'Stake address' 'Include threshold stake script' 'Payment-only wallet' Cancel || status=$?
        if ((status == 0)); then
          case "${choice}" in 'Include threshold stake script') wanted=Y ;; 'Payment-only wallet') wanted=N ;; *) status=1 ;; esac
        fi ;;
      'Change time bounds') cntools_multisig_prompt_bounds_into after before || status=$? ;;
      *) return 1 ;;
    esac
    ((status == 0 || status == 1)) || return "${status}"
  done
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
