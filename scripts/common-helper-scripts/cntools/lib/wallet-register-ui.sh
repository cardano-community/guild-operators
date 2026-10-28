#!/usr/bin/env bash
# Stake lifecycle actions follow the shared transaction UI contract.
# shellcheck disable=SC2034

cntools_wallet_register_begin() {
  cntools_ui_action_begin "${CNTOOLS_WALLET_REGISTER_TITLE}" "${CNTOOLS_WALLET_REGISTER_PATH}"
}

cntools_wallet_register_render_plan() {
  local widths="" fee="" expiry_label="No expiry" action="Stake ${CNTOOLS_WALLET_REGISTER_NOUN}"
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != delegate ]] || action='Stake pool delegation'
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != vote-delegate ]] || action='Voting delegation'
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != drep-* ]] || action="${CNTOOLS_WALLET_REGISTER_INTENT}"
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != gov-vote ]] || action='DRep governance vote'
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  cntools_transaction_ui_fee_into fee || return 1
  if [[ -n "${CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER:-}" ]]; then
    cntools_slot_datetime_into expiry_label "${CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER}" || expiry_label='Date unavailable'
  fi
  cntools_ui_render_detail 'Transaction information' || return 1
  {
    printf 'Transaction detail\tValue\n'
    cntools_transaction_ui_styled_row Wallet "${CNTOOLS_WALLET_REGISTER_WALLET}" identifier
    cntools_transaction_ui_styled_row Action "${action}" accent
    if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == gov-vote ]]; then
      cntools_gov_vote_render_rows
    elif [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-* ]]; then
      cntools_drep_lifecycle_render_rows
    else
      cntools_transaction_ui_styled_row 'Stake address' "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}" address
      cntools_transaction_ui_styled_row 'Return address' "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" address
    fi
    if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == delegate ]]; then
      cntools_delegate_render_pool_rows
    elif [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == vote-delegate ]]; then
      cntools_vote_render_rows
    fi
    if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != drep-update && "${CNTOOLS_WALLET_REGISTER_OPERATION}" != gov-vote ]] &&
       [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != delegate || "${CNTOOLS_DELEGATE_REGISTER}" == Y ]] &&
       [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != vote-delegate || "${CNTOOLS_VOTE_REGISTER:-N}" == Y ]]; then
      cntools_transaction_ui_styled_row "${CNTOOLS_WALLET_REGISTER_DEPOSIT_LABEL}" "$(cntools_number_format_lovelace "${CNTOOLS_WALLET_REGISTER_DEPOSIT}")" number
    fi
    cntools_transaction_ui_styled_row Fee "$(cntools_number_format_lovelace "${fee}")" number
    cntools_transaction_ui_render_policy_rows "${CNTOOLS_TX_SELECTION_STRATEGY}" "${#CNTOOLS_WALLET_REGISTER_INPUTS[@]}"
    cntools_funding_render_untouched_row
    cntools_transaction_ui_styled_row Expires "${expiry_label}" number
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == deregister ]]; then
    cntools_ui_render_status warn 'De-registering ends stake-pool and DRep delegation. Lingering rewards earned but not yet credited or paid out will be forfeited.'
  fi
}

# WALLET names the chosen wallet in outcome lines (it may have been the only one).
cntools_wallet_register_render_collect_error() {
  local status="${1:-1}" message="" fallback="The stake ${CNTOOLS_WALLET_REGISTER_NOUN} data could not be collected. See ${CNTOOLS_LOG}."
  local wallet="${2:-${CNTOOLS_WALLET_REGISTER_WALLET:-This wallet}}"
  # DRep and vote collection is not stake data and reports through the transaction error.
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-* || "${CNTOOLS_WALLET_REGISTER_OPERATION}" == gov-vote ]]; then
    fallback="${CNTOOLS_TRANSACTION_ERROR:-The ${CNTOOLS_WALLET_REGISTER_NOUN} data could not be collected. See ${CNTOOLS_LOG}.}"
  fi
  message="${CNTOOLS_WALLET_REGISTER_ERROR:-${fallback}}"

  case "${status}" in
    4) message="Nothing to register: ${wallet}'s stake address is already registered." ;;
    5) message="${wallet} has no spendable UTxOs at its base or payment address." ;;
    7)
      message="${wallet}'s stake address is not registered."
      [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != deregister ]] || message="Nothing to de-register: ${message}"
      [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != vote-delegate ]] || message+=' Use Wallet → Register first.'
      ;;
    8)
      message="${wallet} has unclaimed rewards. Withdraw all rewards before de-registering its stake address."
      ;;
    9)
      message="${CNTOOLS_WALLET_REGISTER_ERROR:-The wallet does not contain a safe set of UTxOs for this transaction.}"
      ;;
  esac
  if [[ ( "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-* || "${CNTOOLS_WALLET_REGISTER_OPERATION}" == gov-vote ) && -n "${CNTOOLS_WALLET_REGISTER_ERROR}" ]]; then
    message="${CNTOOLS_WALLET_REGISTER_ERROR}"
  fi
  if (( status == 4 || status == 7 )); then
    cntools_ui_render_status info "${message}"
  elif (( status == 8 )); then
    cntools_ui_render_status warn "${message}"
  else
    cntools_ui_render_status error "${message}"
  fi
}

# The signed package must load and carry every witness.
cntools_wallet_register_signed_check() {
  local signed_file="${1:-}"
  cntools_transaction_package_load "${signed_file}" || {
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"
    return 1
  }
  if [[ "${CNTOOLS_TRANSACTION_COMPLETE}" != "Y" ]]; then
    cntools_wallet_register_set_error \
      "The selected local sources did not produce a complete ${CNTOOLS_WALLET_REGISTER_NOUN} package."
    return 1
  fi
}

cntools_wallet_register_result() {
  cntools_transaction_ui_render_result "$@" || return 1
  CNTOOLS_WALLET_REGISTER_RESULT_SHOWN=Y
}

declare -ag CNTOOLS_WALLET_REGISTER_SAVED=()
# Voting delegation target state a review 'Change DRep' keeps or restores.
declare -ag CNTOOLS_WALLET_REGISTER_VOTE_STATE=(CNTOOLS_VOTE_TARGET CNTOOLS_VOTE_KIND CNTOOLS_VOTE_HASH CNTOOLS_VOTE_INACTIVE_CONFIRMED
  CNTOOLS_VOTE_REGISTRATION_CONFIRMED CNTOOLS_DREP_STATUS CNTOOLS_DREP_ACTIVE CNTOOLS_DREP_SOURCE CNTOOLS_DREP_DETAILS)

# Save the named review values a 'Change …' step may replace.
cntools_wallet_register_save() {
  local saved_name=''
  CNTOOLS_WALLET_REGISTER_SAVED=()
  for saved_name in "$@"; do CNTOOLS_WALLET_REGISTER_SAVED+=("${saved_name}" "${!saved_name-}"); done
}

cntools_wallet_register_restore() {
  local saved_index=0
  for (( saved_index = 0; saved_index + 1 < ${#CNTOOLS_WALLET_REGISTER_SAVED[@]}; saved_index += 2 )); do
    printf -v "${CNTOOLS_WALLET_REGISTER_SAVED[saved_index]}" '%s' "${CNTOOLS_WALLET_REGISTER_SAVED[saved_index+1]}"
  done
}

# Review 'Change DRep': any non-zero status keeps the reviewed target.
cntools_wallet_register_vote_change_target() {
  local status=0
  cntools_wallet_register_save "${CNTOOLS_WALLET_REGISTER_VOTE_STATE[@]}"
  cntools_vote_choose_target || status=$?
  (( status != 0 )) || return 0
  cntools_wallet_register_restore
  cntools_transaction_log CHOICE "Voting delegation target unchanged status=${status} target=${CNTOOLS_VOTE_TARGET}"
  return "${status}"
}

# Rebuild after a review change. A failed rebuild restores the saved values,
# rebuilds those and warns; the action continues.
cntools_wallet_register_rebuild_into() {
  local rebuild_target="$1" rebuild_what="$2" rebuild_message="$3" rebuild_reason=''
  CNTOOLS_WALLET_REGISTER_ERROR=''; cntools_transaction_clear_error
  cntools_ui_spin_function "${rebuild_message}" cntools_wallet_register_build_package_into "${rebuild_target}" && return 0
  rebuild_reason="${CNTOOLS_WALLET_REGISTER_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-The transaction could not be rebuilt.}}"
  cntools_wallet_register_restore
  CNTOOLS_TRANSACTION_UI_NOTICE=''
  CNTOOLS_WALLET_REGISTER_ERROR=''; cntools_transaction_clear_error
  cntools_ui_spin_function 'Restoring the reviewed transaction…' cntools_wallet_register_build_package_into "${rebuild_target}" || return 2
  cntools_transaction_log CHOICE "${CNTOOLS_WALLET_REGISTER_TITLE} rebuild failed; previous ${rebuild_what} kept"
  cntools_ui_render_status warn "The new ${rebuild_what} could not be built, so the previous one is kept. ${rebuild_reason}"
}

# Rebuild after 'Change signers'; a failed rebuild restores the signers and
# the workflow, can-sign and lifetime values they changed.
cntools_wallet_register_signers_rebuild_into() {
  local wsr_target="$1" wsr_workflow="$2" wsr_message="$3" wsr_reason=''
  CNTOOLS_WALLET_REGISTER_ERROR=''; cntools_transaction_clear_error
  cntools_ui_spin_function "${wsr_message}" cntools_wallet_register_build_package_into "${wsr_target}" && return 0
  wsr_reason="${CNTOOLS_WALLET_REGISTER_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-The transaction could not be rebuilt.}}"
  cntools_multisig_signers_restore_into "${wsr_workflow}" CNTOOLS_WALLET_REGISTER_CAN_SIGN CNTOOLS_WALLET_REGISTER_LIFETIME
  CNTOOLS_WALLET_REGISTER_ERROR=''; cntools_transaction_clear_error
  cntools_ui_spin_function 'Restoring the reviewed transaction…' cntools_wallet_register_build_package_into "${wsr_target}" || return 2
  cntools_transaction_log CHOICE "${CNTOOLS_WALLET_REGISTER_TITLE} rebuild failed; previous signers kept"
  cntools_ui_render_status warn "The new signers could not be built, so the previous ones are kept. ${wsr_reason}"
}

# De-Register: 0 when the wallet picker already knows the wallet holds rewards.
cntools_wallet_register_known_rewards() {
  local known_address=''
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == deregister ]] &&
    cntools_wallet_read_address "$1" reward known_address &&
    [[ "${CNTOOLS_SELECTION_REWARDS[${known_address}]:-0}" =~ ^[1-9][0-9]*$ ]]
}

# 0 when the picker offers another wallet not known to hold rewards.
cntools_wallet_register_other_candidate() {
  local other_index=0 other_annotation=''
  for other_index in "${!CNTOOLS_WALLET_PATHS[@]}"; do
    [[ "${CNTOOLS_WALLET_PATHS[other_index]}" != "$1" ]] || continue
    cntools_wallet_selection_candidate_into other_annotation "${other_index}" "${CNTOOLS_WALLET_REGISTER_OPERATION}" || continue
    cntools_wallet_register_known_rewards "${CNTOOLS_WALLET_PATHS[other_index]}" || return 0
  done
  return 1
}

cntools_wallet_register_choose_signers() {
  if [[ ( "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-* || "${CNTOOLS_WALLET_REGISTER_OPERATION}" == gov-vote ) &&
    ( "${CNTOOLS_DREP_LIFECYCLE_KIND:-key}" == script || "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE:-}" == MultiSig ) ]]; then
    cntools_multisig_drep_choose_signers || return $?
  elif [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE:-}" == MultiSig ]]; then
    cntools_multisig_stake_choose_signers cntools_wallet_register_begin || return $?
    CNTOOLS_WALLET_REGISTER_CAN_SIGN="${CNTOOLS_STAKE_CAN_SIGN}"
  fi
}

# 0 when the review can offer 'Change signers': stake multisig wallets with a
# real choice of participants (DRep scripts keep their own selection).
cntools_wallet_register_signers_changeable() {
  [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE:-}" == MultiSig && "${CNTOOLS_WALLET_REGISTER_OPERATION}" != drep-* &&
     "${CNTOOLS_WALLET_REGISTER_OPERATION}" != gov-vote ]] && cntools_multisig_signers_changeable
}

# Says why only an unsigned package is offered when the wallet's keys are encrypted.
cntools_wallet_register_unsigned_reason() {
  local -a urk_keys=()
  [[ "${CNTOOLS_WALLET_REGISTER_CAN_SIGN}" != Y && "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE:-}" != MultiSig &&
     -n "${CNTOOLS_WALLET_REGISTER_DIRECTORY:-}" ]] || return 0
  urk_keys=("${CNTOOLS_WALLET_REGISTER_DIRECTORY}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}")
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-* || "${CNTOOLS_WALLET_REGISTER_OPERATION}" == gov-vote ]]; then
    urk_keys+=("${CNTOOLS_WALLET_REGISTER_DIRECTORY}/${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}")
  else
    urk_keys+=("${CNTOOLS_WALLET_REGISTER_DIRECTORY}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}")
  fi
  cntools_transaction_ui_encrypted_reason_set 'Wallet → Decrypt' "${urk_keys[@]}" || true
}

# Collects the chain state, then (fail early) checks a stake multisig wallet's
# time locks at the current slot before any target or signer is asked.
cntools_wallet_register_collect_checked() {
  local wrc_slot=''
  cntools_wallet_register_collect || return $?
  [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE:-}" == MultiSig && "${CNTOOLS_WALLET_REGISTER_OPERATION}" != drep-* &&
     "${CNTOOLS_WALLET_REGISTER_OPERATION}" != gov-vote ]] || return 0
  # The build checks again; an unavailable tip is not a reason to stop here.
  cntools_funding_tip_into wrc_slot "${CNTOOLS_WALLET_REGISTER_BACKEND}" || return 0
  cntools_multisig_stake_window_check "${wrc_slot}" || {
    CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"; return 1;
  }
}

# Pre-submit rechecks run only when due (none yet, or the signing took a while).
cntools_wallet_register_recheck_marked() {
  "$@" || return $?
  cntools_transaction_ui_recheck_mark
}

cntools_wallet_register_workflow() {
  local selected_index="" wallet_directory="" wallet_name="" workflow="" proceed="" choice=""
  local staged="" signed="" saved="" backend="" signed_body="" txid="" status=0 collecting='Checking stake state and spendable funds…' prefix='stake '
  local building='' signing=''
  CNTOOLS_WALLET_REGISTER_RESULT_SHOWN=N
  CNTOOLS_WALLET_REGISTER_SAVED_PACKAGE=""
  case "${CNTOOLS_WALLET_REGISTER_OPERATION}" in
    register) collecting='Checking stake registration and spendable funds…' ;;
    deregister) collecting='Checking stake state, rewards and spendable funds…' ;;
    vote-delegate) collecting='Checking stake state, voting delegation and spendable funds…'; prefix='' ;;
    drep-*) collecting='Checking DRep registration, deposit and spendable funds…'; prefix='' ;;
    gov-vote) collecting='Checking DRep registration, active proposals and spendable funds…'; prefix='' ;;
  esac
  cntools_wallet_register_begin
  cntools_transaction_require_cli || return 2
  cntools_wallet_catalog_build || return 2
  # Check the chain first; signers are chosen only once the action can go ahead.
  while true; do
    # No (suitable) wallet returns 3: the reason was shown and acknowledged.
    cntools_wallet_choose selected_index Cancel "${CNTOOLS_WALLET_REGISTER_OPERATION}" || return $?
    wallet_directory="${CNTOOLS_WALLET_PATHS[selected_index]}"
    wallet_name="${CNTOOLS_WALLET_NAMES[selected_index]}"
    status=0
    if cntools_wallet_register_known_rewards "${wallet_directory}"; then
      status=8 # Known from the picker; no chain check needed.
    else
      cntools_wallet_register_prepare_wallet "${wallet_directory}" "${wallet_name}" || return 2
      # A hardware wallet needs cardano-hw-cli even to build: say so now.
      if [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE:-}" == Hardware ]]; then
        cntools_transaction_require_hwcli || { CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR}"; return 2; }
      fi
      cntools_ui_spin_function "${collecting}" cntools_wallet_register_collect_checked || status=$?
    fi
    (( status != 0 )) || break
    # Rewards block de-registration: say why and pick again while another wallet can.
    if (( status == 8 )) && cntools_wallet_register_other_candidate "${wallet_directory}"; then
      cntools_transaction_log CHOICE "De-register wallet=${wallet_name} has rewards; choosing again"
      cntools_ui_render_status warn "${wallet_name} has unclaimed rewards. Withdraw them first (Funds → Withdraw Rewards), or choose another wallet."
      continue
    fi
    cntools_wallet_register_begin
    cntools_wallet_register_render_collect_error "${status}" "${wallet_name}"
    CNTOOLS_WALLET_REGISTER_RESULT_SHOWN=Y
    [[ "${status}" != 4 && "${status}" != 7 ]] || return 0
    return 2
  done
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == delegate ]]; then
    cntools_delegate_choose_target || return $?
  elif [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == vote-delegate ]]; then
    cntools_vote_choose_target || return $?
  elif [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-* ]]; then
    cntools_drep_lifecycle_choose_metadata || return $?
  elif [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == gov-vote ]]; then
    cntools_gov_vote_choose || return $?
  fi
  cntools_wallet_register_choose_signers || return $?
  cntools_wallet_register_unsigned_reason
  # Asked only once the chain state and target are known to allow the action.
  cntools_transaction_ui_initial_workflow_into workflow "${CNTOOLS_WALLET_REGISTER_CAN_SIGN}" || return $?
  cntools_transaction_ui_initial_expiry_into CNTOOLS_WALLET_REGISTER_LIFETIME || return $?
  building="Building ${prefix}${CNTOOLS_WALLET_REGISTER_NOUN}…"
  signing="${prefix}${CNTOOLS_WALLET_REGISTER_NOUN}"
  cntools_ui_spin_function "${building}" cntools_wallet_register_build_package_into staged || return 2
  local -a review_options=('Change expiry' 'Change workflow')
  case "${CNTOOLS_WALLET_REGISTER_OPERATION}" in
    drep-register|drep-update) review_options=('Change metadata' "${review_options[@]}") ;;
    delegate) review_options=('Change pool' "${review_options[@]}") ;;
    vote-delegate) review_options=('Change DRep' "${review_options[@]}") ;;
    gov-vote) ! declare -F cntools_gov_vote_change >/dev/null || review_options=('Change vote' "${review_options[@]}") ;;
  esac
  ! cntools_wallet_register_signers_changeable || review_options+=('Change signers')
  while true; do
    cntools_transaction_ui_proceed_into proceed "${workflow}" || return 2
    cntools_transaction_ui_review_into choice "${staged}" "${proceed}" \
      cntools_wallet_register_begin cntools_wallet_register_render_plan "${review_options[@]}" || return $?
    # In every 'Change …' step Esc keeps the reviewed value; Ctrl+C cancels.
    status=0
    case "${choice}" in
      "${proceed}") break ;;
      'Change workflow')
        # Quick gives an unsigned package a day to be signed, so that rebuilds.
        cntools_wallet_register_save CNTOOLS_WALLET_REGISTER_LIFETIME
        cntools_transaction_ui_workflow_into workflow "${CNTOOLS_WALLET_REGISTER_CAN_SIGN}" || status=$?
        (( status <= 1 )) || return "${status}"
        (( status == 0 )) || continue
        cntools_transaction_ui_unsigned_lifetime_into CNTOOLS_WALLET_REGISTER_LIFETIME "${workflow}" || continue
        cntools_wallet_register_rebuild_into staged expiry "${building}" || return $? ;;
      'Change pool'|'Change DRep')
        if [[ "${choice}" == 'Change pool' ]]; then
          cntools_delegate_change_target || status=$?
        else
          cntools_wallet_register_vote_change_target || status=$?
        fi
        (( status != 1 )) || continue
        if (( status == 2 )); then
          cntools_ui_render_status warn "${CNTOOLS_WALLET_REGISTER_ERROR:-The new ${choice#Change } could not be checked.} The reviewed ${choice#Change } is kept."
          CNTOOLS_WALLET_REGISTER_ERROR=""
          continue
        fi
        (( status == 0 )) || return "${status}"
        # The same pool or DRep again needs no rebuild.
        [[ "${!CNTOOLS_WALLET_REGISTER_SAVED[0]}" != "${CNTOOLS_WALLET_REGISTER_SAVED[1]}" ]] || continue
        cntools_wallet_register_rebuild_into staged "${choice#Change }" "${building}" || return $? ;;
      'Change metadata')
        cntools_wallet_register_save CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH
        cntools_drep_lifecycle_choose_metadata change || status=$?
        (( status != 1 )) || continue
        (( status == 0 )) || return "${status}"
        # The same metadata again (Keep current metadata) needs no rebuild.
        [[ "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" != "${CNTOOLS_WALLET_REGISTER_SAVED[1]}" ||
           "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}" != "${CNTOOLS_WALLET_REGISTER_SAVED[3]}" ]] || continue
        cntools_wallet_register_rebuild_into staged metadata "${building}" || return $? ;;
      'Change vote')
        cntools_wallet_register_save CNTOOLS_GOV_VOTE_DECISION CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH
        cntools_gov_vote_change || status=$?
        (( status != 1 )) || continue
        (( status == 0 )) || return "${status}"
        cntools_wallet_register_rebuild_into staged vote "${building}" || return $? ;;
      'Change expiry')
        cntools_wallet_register_save CNTOOLS_WALLET_REGISTER_LIFETIME
        cntools_transaction_ui_expiry_into CNTOOLS_WALLET_REGISTER_LIFETIME || status=$?
        (( status != 1 )) || continue
        (( status == 0 )) || return "${status}"
        [[ "${CNTOOLS_WALLET_REGISTER_LIFETIME}" != "${CNTOOLS_WALLET_REGISTER_SAVED[1]}" ]] || continue
        cntools_wallet_register_rebuild_into staged expiry "${building}" || return $? ;;
      'Change signers')
        cntools_multisig_signers_change_into workflow CNTOOLS_WALLET_REGISTER_CAN_SIGN CNTOOLS_WALLET_REGISTER_LIFETIME stake cntools_wallet_register_begin || status=$?
        (( status != 1 )) || continue
        (( status == 0 )) || return "${status}"
        cntools_wallet_register_signers_rebuild_into staged workflow "${building}" || return $? ;;
      *) return 2 ;;
    esac
  done
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == vote-delegate ]]; then
    cntools_ui_spin_function 'Rechecking stake state, DRep and selected inputs…' cntools_wallet_register_recheck_marked cntools_vote_recheck || return 2
  elif [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-* ]]; then
    cntools_ui_spin_function 'Rechecking DRep state, deposit and selected inputs…' cntools_wallet_register_recheck_marked cntools_drep_lifecycle_recheck || return 2
  elif [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == gov-vote ]]; then
    cntools_ui_spin_function 'Rechecking DRep, proposal, previous vote and selected inputs…' cntools_wallet_register_recheck_marked cntools_gov_vote_recheck || return 2
  fi
  if [[ "${workflow}" != 'Create unsigned package' ]]; then
    cntools_transaction_signed_path_into signed || return 2
    if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == delegate ]]; then
      cntools_ui_spin_function 'Rechecking stake state, pool and selected inputs…' cntools_wallet_register_recheck_marked cntools_delegate_recheck || return 2
    fi
    # A device or key failure offers Retry, Save unsigned package or Cancel.
    status=0
    cntools_transaction_ui_sign_staged "${signing}" "${staged}" "${signed}" || status=$?
    case "${status}" in
      0) cntools_wallet_register_signed_check "${signed}" || return 2 ;;
      4) workflow='Create unsigned package' ;;
      1|130) return "${status}" ;;
      *) CNTOOLS_WALLET_REGISTER_ERROR="${CNTOOLS_TRANSACTION_ERROR:-}"; return 2 ;;
    esac
  fi
  if [[ "${workflow}" == 'Create unsigned package' ]]; then
    cntools_transaction_save_into saved "${staged}" unsigned "${CNTOOLS_WALLET_REGISTER_FILE_SUFFIX}" || return 2
    CNTOOLS_WALLET_REGISTER_SAVED_PACKAGE="${saved}"
    cntools_wallet_register_begin
    cntools_wallet_register_result success 'Ready for offline signing · Transaction → Sign, then Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
  cntools_transaction_save_into saved "${signed}" signed "${CNTOOLS_WALLET_REGISTER_FILE_SUFFIX}" || return 2
  CNTOOLS_WALLET_REGISTER_SAVED_PACKAGE="${saved}"
  if [[ "${workflow}" == 'Create and sign' ]]; then
    cntools_wallet_register_begin
    cntools_wallet_register_result success 'Signed · ready for Transaction → Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
  cntools_transaction_submit_input_prepare "${saved}" || return 2
  signed_body="${CNTOOLS_TRANSACTION_SIGNED_FILE}"; txid="${CNTOOLS_TRANSACTION_SUBMIT_ID}"
  cntools_transaction_ui_submission_backend_into backend || return 2
  cntools_transaction_ui_confirm_submit "${backend}" || status=$?
  if (( status != 0 )); then
    cntools_wallet_register_begin
    cntools_wallet_register_result warning 'Not submitted · signed package retained' "${txid}" "${saved}"
    return $?
  fi
  cntools_ui_spin_function "Submitting ${prefix}${CNTOOLS_WALLET_REGISTER_NOUN}…" \
    cntools_wallet_register_submit_checked "${backend}" "${signed_body}" "${txid}" || status=$?
  cntools_wallet_register_begin
  if (( status != 0 )); then
    cntools_wallet_register_result danger "${CNTOOLS_TRANSACTION_ERROR:-Submission could not be confirmed. Check the chain before retrying.}" "${txid}" "${saved}" || return 2
    return 2
  fi
  cntools_wallet_register_result success "${CNTOOLS_TRANSACTION_SUBMIT_MESSAGE} Submission is not confirmation of inclusion." "${txid}" || return 2
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-register ]]; then
    cntools_ui_render_status info "DRep registration does not delegate this wallet's voting power. Use Governance → Delegate to choose this DRep if you want to self-delegate."
  fi
  cntools_transaction_ui_offer_monitor "${txid}"
}

# Signing a moment ago needs no second recheck before submitting; a device or
# another system that took a while does (cntools_transaction_ui_recheck_due).
cntools_wallet_register_submit_checked() {
  if ! cntools_transaction_ui_recheck_due; then
    :
  elif [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == gov-vote ]]; then
    cntools_gov_vote_recheck || {
      cntools_transaction_set_error "Not submitted: ${CNTOOLS_WALLET_REGISTER_ERROR:-Governance vote could not be rechecked.}"
      return 1
    }
  elif [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-* ]]; then
    cntools_drep_lifecycle_recheck || {
      cntools_transaction_set_error "Not submitted: ${CNTOOLS_WALLET_REGISTER_ERROR:-DRep state could not be rechecked.}"
      return 1
    }
  elif [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == delegate ]]; then
    cntools_delegate_recheck || {
      cntools_transaction_set_error "Not submitted: ${CNTOOLS_WALLET_REGISTER_ERROR:-Delegation state could not be rechecked.}"
      return 1
    }
  elif [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == vote-delegate ]]; then
    cntools_vote_recheck || {
      cntools_transaction_set_error "Not submitted: ${CNTOOLS_WALLET_REGISTER_ERROR:-Voting delegation state could not be rechecked.}"
      return 1
    }
  fi
  cntools_transaction_ui_recheck_mark
  cntools_transaction_ui_submit_selected "$@"
}

# 1/130 cancel straight back to the menu (naming a saved package, if any);
# 3 means nothing to choose and the reason was already shown and acknowledged.
cntools_wallet_action_stake_lifecycle() {
  local status=0
  cntools_transaction_clear_error
  cntools_wallet_register_workflow || status=$?
  case "${status}" in
    0)
      if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == delegate && -n "${CNTOOLS_WALLET_REGISTER_SAVED_PACKAGE:-}" ]]; then
        cntools_delegate_reminder
      fi
      cntools_ui_wait ;;
    1|130)
      cntools_transaction_ui_log CHOICE "${CNTOOLS_WALLET_REGISTER_TITLE} cancelled status=${status} saved=${CNTOOLS_WALLET_REGISTER_SAVED_PACKAGE:-none}"
      [[ -n "${CNTOOLS_WALLET_REGISTER_SAVED_PACKAGE:-}" ]] || return 0
      cntools_ui_render_status info "Cancelled. The saved package remains available: ${CNTOOLS_WALLET_REGISTER_SAVED_PACKAGE}"
      cntools_ui_wait ;;
    3) ;;
    *)
      if [[ "${CNTOOLS_WALLET_REGISTER_RESULT_SHOWN:-N}" != Y ]]; then
        cntools_wallet_register_result danger "${CNTOOLS_WALLET_REGISTER_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-Transaction failed. See ${CNTOOLS_LOG}.}}" '' "${CNTOOLS_WALLET_REGISTER_SAVED_PACKAGE:-}"
      fi
      cntools_ui_wait
      return 1 ;;
  esac
}

cntools_wallet_action_register() {
  cntools_wallet_register_operation_set register || return 1
  cntools_wallet_action_stake_lifecycle
}

cntools_wallet_action_deregister() {
  cntools_wallet_register_operation_set deregister || return 1
  cntools_wallet_action_stake_lifecycle
}
