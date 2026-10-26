#!/usr/bin/env bash
# Governance delegation reuses the shared stake transaction UX and signers.
# shellcheck disable=SC2034
declare -ag CNTOOLS_VOTE_LOCAL_LABELS=() CNTOOLS_VOTE_LOCAL_IDS=()
# Y once the local DRep wallets were inspected (each Change DRep reuses them).
CNTOOLS_VOTE_LOCAL_COLLECTED=N

cntools_vote_label() {
  case "$1" in
    '') printf 'Not delegated' ;;
    drep_always_abstain) printf 'Always Abstain' ;;
    drep_always_no_confidence) printf 'Always No Confidence' ;;
    *) printf '%s' "$1" ;;
  esac
}

cntools_vote_target_status_into() {
  local ts_label='' ts_role=success
  case "${CNTOOLS_DREP_STATUS}:${CNTOOLS_DREP_ACTIVE}" in
    predefined:*) ts_label=Predefined ;;
    registered:true) ts_label='Registered · active' ;;
    registered:false) ts_label='Registered · inactive'; ts_role=warning ;;
    registered:*) ts_label='Registered · activity unknown'; ts_role=value ;;
    *) ts_label="${CNTOOLS_DREP_STATUS:-Unknown}"; ts_role=value ;;
  esac
  printf -v "$1" '%s' "${ts_label}"
  printf -v "$2" '%s' "${ts_role}"
}

cntools_vote_render_rows() {
  local label='' role=''
  cntools_vote_target_status_into label role
  cntools_transaction_ui_styled_row 'Current voting delegation' "$(cntools_vote_label "${CNTOOLS_VOTE_CURRENT}")" identifier
  cntools_transaction_ui_styled_row 'Target voting delegation' "$(cntools_vote_label "${CNTOOLS_VOTE_TARGET}")" identifier
  # Only what needs attention: an inactive DRep, or activity not known.
  # Abstain and No Confidence are ledger options; nothing was queried.
  case "${CNTOOLS_DREP_STATUS}:${CNTOOLS_DREP_ACTIVE}" in
    predefined:*|registered:true) ;;
    *) cntools_transaction_ui_styled_row 'Target status' "${label}" "${role}" ;;
  esac
}

# Registration of the chosen target, plus (local build, Koios enabled) the
# activity the ledger state lacks, so an inactive DRep is caught.
cntools_vote_target_check() {
  cntools_drep_query "${CNTOOLS_VOTE_TARGET}" "${CNTOOLS_VOTE_KIND}" "${CNTOOLS_VOTE_HASH}" "${CNTOOLS_WALLET_REGISTER_BACKEND}" || return $?
  [[ "${CNTOOLS_DREP_STATUS}" == registered && "${CNTOOLS_DREP_ACTIVE}" == unknown ]] || return 0
  cntools_drep_koios_enrich "${CNTOOLS_VOTE_TARGET}" "${CNTOOLS_VOTE_KIND}" "${CNTOOLS_VOTE_HASH}" || return 0
  CNTOOLS_DREP_ACTIVE="$(jq -r '.active | if . == true then "true" elif . == false then "false" else "unknown" end' <<< "${CNTOOLS_DREP_KOIOS_DETAILS}")" ||
    CNTOOLS_DREP_ACTIVE=unknown
  [[ "${CNTOOLS_DREP_ACTIVE}" == unknown ]] || CNTOOLS_DREP_SOURCE='Local node · Koios activity'
}

cntools_vote_choose_target() {
  local choice="" entered="" status=0 widths="" notice=""
  local -a options=('Specific DRep')
  CNTOOLS_VOTE_TARGET="" CNTOOLS_VOTE_KIND="" CNTOOLS_VOTE_HASH="" CNTOOLS_VOTE_INACTIVE_CONFIRMED=N
  # The review shows the deposit row and offers Cancel; no separate approval.
  if [[ "${CNTOOLS_VOTE_REGISTER}" == Y ]]; then
    CNTOOLS_VOTE_REGISTRATION_CONFIRMED=Y
    cntools_transaction_log CHOICE "Combined stake registration approved deposit=${CNTOOLS_WALLET_REGISTER_DEPOSIT}"
  fi
  # Offer local DReps only when one exists; inspected once per action.
  if [[ "${CNTOOLS_VOTE_LOCAL_COLLECTED}" != Y ]]; then
    cntools_ui_spin_function 'Checking local DRep wallets…' cntools_vote_local_collect || return 2
  fi
  ((${#CNTOOLS_VOTE_LOCAL_IDS[@]} == 0)) || options+=('Local DRep wallet')
  options+=('Always Abstain' 'Always No Confidence' Cancel)
  notice='Voting delegation does not change your stake pool or withdraw rewards.'
  if [[ "${CNTOOLS_VOTE_REGISTER}" == Y ]]; then
    notice+=" This stake address is not registered yet, so the transaction also registers it (refundable deposit $(cntools_number_format_lovelace "${CNTOOLS_WALLET_REGISTER_DEPOSIT}"))."
  fi
  while true; do
    cntools_wallet_register_begin
    cntools_transaction_ui_table_widths_into widths 26 || return 2
    {
      printf 'Wallet detail\tValue\n'
      cntools_transaction_ui_styled_row Wallet "${CNTOOLS_WALLET_REGISTER_WALLET}" identifier
      cntools_transaction_ui_styled_row 'Current voting delegation' "$(cntools_vote_label "${CNTOOLS_VOTE_CURRENT}")" identifier
    } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 2
    cntools_ui_render_status info "${notice}"
    cntools_ui_choose choice 'Voting delegation' "${options[@]}" || return $?
    cntools_transaction_log CHOICE "Voting delegation target choice=${choice}"
    status=0
    case "${choice}" in
      'Specific DRep') cntools_ui_input entered 'DRep ID' 'drep1… (CIP-129 or legacy); legacy drep_script1… also supported' || status=$? ;;
      'Local DRep wallet') cntools_vote_choose_local_into entered || status=$? ;;
      'Always Abstain') entered=drep_always_abstain ;;
      'Always No Confidence') entered=drep_always_no_confidence ;;
      Cancel) return 1 ;;
      *) return 2 ;;
    esac
    # Esc in the ID field or the local list returns to the target choice.
    ((status == 0)) || { ((status == 1)) && continue; return "${status}"; }
    # Warnings repeat under the next header, so no extra Press Enter.
    if ! cntools_drep_id_into CNTOOLS_VOTE_TARGET CNTOOLS_VOTE_KIND CNTOOLS_VOTE_HASH "${entered}"; then
      cntools_ui_render_status warn 'Invalid DRep ID. Enter the complete Bech32 ID with its checksum, not a bare hash.'; continue
    fi
    if [[ "${CNTOOLS_VOTE_TARGET}" == "${CNTOOLS_VOTE_CURRENT}" ]]; then
      cntools_ui_render_status warn 'This wallet already uses that voting delegation. No transaction is needed.'; continue
    fi
    status=0
    cntools_ui_spin_function 'Checking the voting delegation target…' cntools_vote_target_check || status=$?
    if ((status == 4)); then
      cntools_ui_render_status warn 'The DRep is not registered on this network or has retired.'; continue
    elif ((status != 0)); then
      cntools_wallet_register_set_error 'The target DRep could not be verified. Check the node/API and try again.'; return 2
    fi
    if [[ "${CNTOOLS_DREP_ACTIVE}" == false ]]; then
      status=0
      cntools_ui_confirm 'This DRep is registered but currently inactive. Delegate to it anyway?' false || status=$?
      cntools_transaction_log CHOICE "Inactive DRep confirmation status=${status} target=${CNTOOLS_VOTE_TARGET}"
      # Declining returns to the target choice.
      ((status == 0)) || { ((status == 1)) && continue; return "${status}"; }
      CNTOOLS_VOTE_INACTIVE_CONFIRMED=Y
    fi
    cntools_transaction_log CHOICE "Voting delegation target=${CNTOOLS_VOTE_TARGET} kind=${CNTOOLS_VOTE_KIND} previous=${CNTOOLS_VOTE_CURRENT}"
    return 0
  done
}

# Verified key and script DReps held by CNTools wallets (public files only).
cntools_vote_local_collect() {
  local directory="" index=0
  CNTOOLS_VOTE_LOCAL_LABELS=() CNTOOLS_VOTE_LOCAL_IDS=()
  for directory in "${CNTOOLS_WALLET_PATHS[@]}"; do
    [[ -f "${directory}/${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}" || -f "${directory}/${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}" ||
       -f "${directory}/${CNTOOLS_WALLET_DREP_SCRIPT_FILENAME:-drep.script}" ]] || continue
    if cntools_drep_key_inspect "${directory}" && [[ "${CNTOOLS_DREP_KEY_VERIFIED}" == Y ]]; then
      index=$((index+1))
      CNTOOLS_VOTE_LOCAL_LABELS+=("${index} · ${directory##*/} · ${CNTOOLS_DREP_KEY_ID}$([[ "${CNTOOLS_DREP_KEY_KIND}" != script ]] || printf ' · script')")
      CNTOOLS_VOTE_LOCAL_IDS+=("${CNTOOLS_DREP_KEY_ID}")
    fi
  done
  CNTOOLS_DREP_KEY_ERROR='' CNTOOLS_VOTE_LOCAL_COLLECTED=Y
}

cntools_vote_choose_local_into() {
  local destination="$1" selection="" index=0
  ((${#CNTOOLS_VOTE_LOCAL_IDS[@]} > 0)) || return 1
  if (( ${#CNTOOLS_VOTE_LOCAL_IDS[@]} == 1 )); then
    # The target check and review follow at once and show the DRep ID.
    printf -v "${destination}" '%s' "${CNTOOLS_VOTE_LOCAL_IDS[0]}"
    cntools_transaction_log CHOICE "Local DRep wallet auto-selected only=${CNTOOLS_VOTE_LOCAL_LABELS[0]}"
    return 0
  fi
  cntools_ui_choose selection 'Local DRep wallet · registration checked next' "${CNTOOLS_VOTE_LOCAL_LABELS[@]}" Cancel || return $?
  [[ "${selection}" != Cancel ]] || return 1
  for index in "${!CNTOOLS_VOTE_LOCAL_LABELS[@]}"; do
    [[ "${selection}" != "${CNTOOLS_VOTE_LOCAL_LABELS[index]}" ]] || { printf -v "${destination}" '%s' "${CNTOOLS_VOTE_LOCAL_IDS[index]}"; return 0; }
  done
  return 2
}

cntools_governance_action_delegate() {
  cntools_wallet_register_operation_set vote-delegate || return 1
  cntools_wallet_action_stake_lifecycle
}
