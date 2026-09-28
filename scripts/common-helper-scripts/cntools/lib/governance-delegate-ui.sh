#!/usr/bin/env bash
# Governance delegation reuses the shared stake transaction UX and signers.
# shellcheck disable=SC2034

cntools_vote_label() {
  case "$1" in
    '') printf 'Not delegated' ;;
    drep_always_abstain) printf 'Always Abstain' ;;
    drep_always_no_confidence) printf 'Always No Confidence' ;;
    *) printf '%s' "$1" ;;
  esac
}

cntools_vote_render_rows() {
  cntools_transaction_ui_styled_row 'Current voting delegation' "$(cntools_vote_label "${CNTOOLS_VOTE_CURRENT}")" identifier
  cntools_transaction_ui_styled_row 'Target voting delegation' "$(cntools_vote_label "${CNTOOLS_VOTE_TARGET}")" identifier
  cntools_transaction_ui_styled_row 'Target status' "$([[ "${CNTOOLS_DREP_ACTIVE}" == false ]] && printf 'Registered · inactive' || printf '%s' "${CNTOOLS_DREP_STATUS}")" \
    "$([[ "${CNTOOLS_DREP_ACTIVE}" == false ]] && printf warning || printf success)"
  cntools_transaction_ui_styled_row 'Target checked through' "${CNTOOLS_DREP_SOURCE}" value
}

cntools_vote_choose_target() {
  local choice="" entered="" status=0 widths=""
  CNTOOLS_VOTE_TARGET="" CNTOOLS_VOTE_KIND="" CNTOOLS_VOTE_HASH="" CNTOOLS_VOTE_INACTIVE_CONFIRMED=N
  while true; do
    cntools_wallet_register_begin
    cntools_transaction_ui_table_widths_into widths 26 || return 2
    {
      printf 'Wallet detail\tValue\n'
      cntools_transaction_ui_styled_row Wallet "${CNTOOLS_WALLET_REGISTER_WALLET}" identifier
      cntools_transaction_ui_styled_row 'Current voting delegation' "$(cntools_vote_label "${CNTOOLS_VOTE_CURRENT}")" identifier
    } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 2
    cntools_ui_render_status info 'Voting delegation changes only your voting representative. Pool delegation, rewards and stake registration remain unchanged. No additional deposit is required.'
    cntools_ui_choose choice 'Voting delegation' 'Specific DRep' 'Always Abstain' 'Always No Confidence' Cancel || return $?
    cntools_transaction_log CHOICE "Voting delegation target choice=${choice}"
    case "${choice}" in
      'Specific DRep') cntools_ui_input entered 'DRep ID' 'drep1… (CIP-129 or legacy); legacy drep_script1… also supported' || return $? ;;
      'Always Abstain') entered=drep_always_abstain ;;
      'Always No Confidence') entered=drep_always_no_confidence ;;
      Cancel) return 1 ;;
      *) return 2 ;;
    esac
    if ! cntools_drep_id_into CNTOOLS_VOTE_TARGET CNTOOLS_VOTE_KIND CNTOOLS_VOTE_HASH "${entered}"; then
      cntools_ui_render_status warn 'Invalid DRep ID. Enter the complete Bech32 ID with its checksum, not a bare hash.'; cntools_ui_wait; continue
    fi
    if [[ "${CNTOOLS_VOTE_TARGET}" == "${CNTOOLS_VOTE_CURRENT}" ]]; then
      cntools_ui_render_status info 'This wallet already uses that voting delegation. No transaction is needed.'; cntools_ui_wait; continue
    fi
    status=0
    cntools_ui_spin_function 'Checking the voting delegation target…' cntools_drep_query \
      "${CNTOOLS_VOTE_TARGET}" "${CNTOOLS_VOTE_KIND}" "${CNTOOLS_VOTE_HASH}" "${CNTOOLS_WALLET_REGISTER_BACKEND}" || status=$?
    if ((status == 4)); then
      cntools_ui_render_status warn 'The DRep is not registered on this network or has retired.'; cntools_ui_wait; continue
    elif ((status != 0)); then
      cntools_wallet_register_set_error 'The target DRep could not be verified. Check the node/API and try again.'; return 2
    fi
    if [[ "${CNTOOLS_DREP_ACTIVE}" == false ]]; then
      status=0
      cntools_ui_confirm 'This DRep is registered but currently inactive. Delegate to it anyway?' false || status=$?
      cntools_transaction_log CHOICE "Inactive DRep confirmation status=${status} target=${CNTOOLS_VOTE_TARGET}"
      ((status == 0)) || return "${status}"
      CNTOOLS_VOTE_INACTIVE_CONFIRMED=Y
    fi
    cntools_transaction_log CHOICE "Voting delegation target=${CNTOOLS_VOTE_TARGET} kind=${CNTOOLS_VOTE_KIND} previous=${CNTOOLS_VOTE_CURRENT}"
    return 0
  done
}

cntools_governance_action_delegate() {
  cntools_wallet_register_operation_set vote-delegate || return 1
  cntools_wallet_action_stake_lifecycle
}
