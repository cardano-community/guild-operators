#!/usr/bin/env bash
# DRep-specific choices; review/sign/submit follow the common transaction flow.
# shellcheck disable=SC2034

cntools_drep_lifecycle_render_rows() {
  local current_url='' current_hash='' value=''
  cntools_transaction_ui_styled_row 'DRep ID' "${CNTOOLS_DREP_LIFECYCLE_ID}" identifier
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-retire ]]; then
    cntools_transaction_ui_styled_row Effect 'Ends this DRep · delegators must choose another DRep' warning
    # What retiring gives up, when the source reports it (Koios).
    value="$(jq -r '.amount // "" | tostring' <<< "${CNTOOLS_DREP_DETAILS}" 2>/dev/null)" || value=''
    [[ ! "${value}" =~ ^[0-9]+$ ]] || cntools_transaction_ui_styled_row "${CNTOOLS_DREP_POWER_LABEL:-Voting power}" "$(cntools_number_format_lovelace "${value}")" number
    value="$(jq -r '.live_delegator_count // "" | tostring' <<< "${CNTOOLS_DREP_DETAILS}" 2>/dev/null)" || value=''
    [[ ! "${value}" =~ ^[0-9]+$ ]] || cntools_transaction_ui_styled_row Delegators "$(cntools_number_format "${value}")" number
    return 0
  fi
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-update ]]; then
    cntools_drep_lifecycle_current_anchor_into current_url current_hash
    if [[ "${current_url}" == "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" && "${current_hash}" == "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}" ]]; then
      if [[ -z "${current_url}" ]]; then
        cntools_transaction_ui_styled_row Metadata 'No metadata anchor · unchanged' value
      else
        cntools_transaction_ui_styled_row Metadata 'Unchanged' value
        cntools_transaction_ui_styled_row 'Metadata URL' "${current_url}" address
      fi
      return 0
    fi
    if [[ -n "${current_url}" ]]; then
      cntools_transaction_ui_styled_row 'Current metadata URL' "${current_url}" address
    else
      cntools_transaction_ui_styled_row 'Current metadata' 'No metadata anchor' value
    fi
    if [[ -z "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" ]]; then
      cntools_transaction_ui_styled_row 'New metadata' 'Removed · no anchor' warning
      return 0
    fi
    cntools_transaction_ui_styled_row 'New metadata URL' "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" address
    cntools_transaction_ui_styled_row 'New metadata hash' "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}" identifier
  elif [[ -n "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" ]]; then
    cntools_transaction_ui_styled_row 'Metadata URL' "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" address
    cntools_transaction_ui_styled_row 'Metadata hash' "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}" identifier
  else
    cntools_transaction_ui_styled_row Metadata 'No metadata anchor' value
  fi
}

# Context for the metadata menu: what the DRep has now and what this costs.
cntools_drep_lifecycle_render_metadata_context() {
  local current_url="$1" current_hash="$2" widths=''
  cntools_wallet_register_begin
  cntools_transaction_ui_table_widths_into widths 24 || return 2
  {
    printf 'DRep detail\tValue\n'
    cntools_transaction_ui_styled_row Wallet "${CNTOOLS_WALLET_REGISTER_WALLET}" identifier
    cntools_transaction_ui_styled_row Action "${CNTOOLS_WALLET_REGISTER_INTENT}" accent
    cntools_transaction_ui_styled_row 'DRep ID' "${CNTOOLS_DREP_LIFECYCLE_ID}" identifier
    if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-update ]]; then
      if [[ -n "${current_url}" ]]; then
        cntools_transaction_ui_styled_row 'Current metadata URL' "${current_url}" address
        cntools_transaction_ui_styled_row 'Current metadata hash' "${current_hash}" identifier
      else
        cntools_transaction_ui_styled_row 'Current metadata' 'No metadata anchor' value
      fi
    else
      cntools_transaction_ui_styled_row "${CNTOOLS_WALLET_REGISTER_DEPOSIT_LABEL}" "$(cntools_number_format_lovelace "${CNTOOLS_WALLET_REGISTER_DEPOSIT}")" number
    fi
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 2
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-update ]]; then
    cntools_ui_render_status info 'This DRep is already registered. Updating costs only the transaction fee and renews DRep activity.'
  else
    cntools_ui_render_status info 'Registering charges the current DRep deposit plus the transaction fee. Metadata is optional; publish a prepared CIP-119 JSON document before using its URL. Its URL and hash are public on-chain; never include secrets.'
  fi
}

# "change" (from the review) always asks. Quick otherwise keeps an update's
# current anchor and registers without one (the review offers Change
# metadata). Retirement has nothing to choose: its review shows the effect.
cntools_drep_lifecycle_choose_metadata() {
  local choice="" url="" hash="" current_url="" current_hash="" status=0 auto=N
  local -a choices=('No metadata' 'Add / replace metadata' Cancel)
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != drep-retire ]] || return 0
  cntools_drep_lifecycle_current_anchor_into current_url current_hash || return 2
  # Without a current anchor, keeping and removing are the same choice.
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != drep-update || -z "${current_url}" ]] ||
    choices=('Keep current metadata' 'Add / replace metadata' 'Remove metadata' Cancel)
  [[ "${1:-}" == change ]] || ! cntools_flow_quick || auto=Y
  [[ "${auto}" == Y ]] || cntools_drep_lifecycle_render_metadata_context "${current_url}" "${current_hash}" || return 2
  while true; do
    if [[ "${auto}" == Y ]]; then
      choice='No metadata'
      [[ -z "${current_url}" ]] || choice='Keep current metadata'
      cntools_transaction_log CHOICE "DRep metadata default=${choice} flow=quick"
    else
      cntools_ui_choose choice 'DRep metadata' "${choices[@]}" || return $?
      cntools_transaction_log CHOICE "DRep metadata choice=${choice}"
    fi
    case "${choice}" in
      Cancel) return 1 ;;
      'Keep current metadata') url="${current_url}"; hash="${current_hash}" ;;
      'No metadata'|'Remove metadata') url=""; hash="" ;;
      'Add / replace metadata')
        status=0
        cntools_ui_input url 'Published metadata URL' 'https://… or ipfs://… (maximum 128 bytes)' || status=$?
        ((status == 0)) || { ((status == 1)) && continue; return "${status}"; }
        # Check the URL before hashing so a typo is not found only afterwards.
        if ! cntools_drep_lifecycle_anchor_valid "${url}" "$(printf '%064d' 0)"; then
          cntools_ui_render_status warn 'Use an HTTP(S) or IPFS URL of at most 128 bytes, without spaces/control characters.'; continue
        fi
        cntools_public_metadata_anchor_hash_into hash "${url}" 'DRep metadata' Metadata cntools_drep_lifecycle_hash_file_into 262144 \
          'The hash covers this exact local file. Publish identical bytes at the URL; CNTools does not upload it or validate the full CIP-119 schema.' || status=$?
        ((status == 0)) || { ((status == 1)) && continue; return "${status}"; }
        ;;
      *) return 2 ;;
    esac
    if ! cntools_drep_lifecycle_anchor_valid "${url}" "${hash}"; then
      # A Quick default that cannot be used falls back to the menu, with context.
      [[ "${auto}" != Y ]] || cntools_drep_lifecycle_render_metadata_context "${current_url}" "${current_hash}" || return 2
      auto=N
      cntools_ui_render_status warn 'Use an HTTP(S) or IPFS URL of at most 128 bytes, without spaces/control characters, and a 64-character hexadecimal hash.'
      continue
    fi
    CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL="${url}" CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH="${hash}"
    cntools_transaction_log CHOICE "DRep anchor url=${url} hash=${hash} operation=${CNTOOLS_WALLET_REGISTER_OPERATION}"
    return 0
  done
}

cntools_governance_action_drep_register() {
  cntools_wallet_register_operation_set drep-register || return 1
  cntools_wallet_action_stake_lifecycle
}

cntools_governance_action_drep_retire() {
  cntools_wallet_register_operation_set drep-retire || return 1
  cntools_wallet_action_stake_lifecycle
}
