#!/usr/bin/env bash
# DRep-specific choices; review/sign/submit follow the common transaction flow.
# shellcheck disable=SC2034

cntools_drep_lifecycle_render_rows() {
  cntools_transaction_ui_styled_row 'DRep ID' "${CNTOOLS_DREP_LIFECYCLE_ID}" identifier
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != drep-retire ]]; then
    if [[ -n "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" ]]; then
      cntools_transaction_ui_styled_row 'Metadata URL' "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_URL}" address
      cntools_transaction_ui_styled_row 'Metadata hash' "${CNTOOLS_DREP_LIFECYCLE_ANCHOR_HASH}" identifier
    else
      cntools_transaction_ui_styled_row Metadata 'No metadata anchor' value
    fi
  fi
}

cntools_drep_lifecycle_choose_metadata() {
  local choice="" method="" url="" hash="" file="" widths=""
  local -a choices=('Add / replace metadata' 'No metadata' Cancel)
  cntools_wallet_register_begin
  cntools_transaction_ui_table_widths_into widths 24 || return 2
  {
    printf 'DRep detail\tValue\n'
    cntools_transaction_ui_styled_row Wallet "${CNTOOLS_WALLET_REGISTER_WALLET}" identifier
    cntools_transaction_ui_styled_row Action "${CNTOOLS_WALLET_REGISTER_INTENT}" accent
    cntools_transaction_ui_styled_row 'DRep ID' "${CNTOOLS_DREP_LIFECYCLE_ID}" identifier
    if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" != drep-update ]]; then
      cntools_transaction_ui_styled_row "${CNTOOLS_WALLET_REGISTER_DEPOSIT_LABEL}" "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_REGISTER_DEPOSIT}")" number
    fi
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 2
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-retire ]]; then
    cntools_ui_render_status warn 'Retirement ends your DRep registration. The recorded deposit is returned to this wallet, less the transaction fee. Delegators will need to choose another representative.'
    cntools_ui_confirm 'Prepare this DRep retirement?' false
    return $?
  fi
  if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == drep-update ]]; then
    choices=('Keep current metadata' 'Add / replace metadata' 'Remove metadata' Cancel)
    cntools_ui_render_status info 'This DRep is already registered. Updating costs only the transaction fee and renews DRep activity. Keeping metadata preserves its current anchor.'
  else
    cntools_ui_render_status info 'Registering charges the current DRep deposit plus the transaction fee. Metadata is optional; publish a prepared CIP-119 JSON document before using its URL. Its URL and hash are public on-chain; never include secrets.'
  fi
  while true; do
    cntools_ui_choose choice 'DRep metadata' "${choices[@]}" || return $?
    cntools_transaction_log CHOICE "DRep metadata choice=${choice}"
    case "${choice}" in
      Cancel) return 1 ;;
      'Keep current metadata')
        url="$(jq -r '.url // ""' <<< "${CNTOOLS_DREP_LIFECYCLE_STATE}")" || return 2
        hash="$(jq -r '.hash // ""' <<< "${CNTOOLS_DREP_LIFECYCLE_STATE}")" || return 2
        ;;
      'No metadata'|'Remove metadata') url=""; hash="" ;;
      'Add / replace metadata')
        cntools_ui_input url 'Published metadata URL' 'https://… or ipfs://… (maximum 128 bytes)' || return $?
        cntools_ui_choose method 'Metadata hash' 'Hash local JSON file' 'Enter known hash' Cancel || return $?
        case "${method}" in
          Cancel) continue ;;
          'Hash local JSON file')
            cntools_ui_input file 'Metadata JSON file' 'Absolute path to the exact published JSON bytes' || return $?
            if ! cntools_ui_spin_function 'Hashing DRep metadata…' cntools_drep_lifecycle_hash_file_into hash "${file}"; then
              cntools_ui_render_status warn "${CNTOOLS_TRANSACTION_ERROR:-Could not hash that metadata file.}"; continue
            fi
            cntools_ui_render_status info 'The hash covers the exact local file bytes. Make sure the published document is identical. CNTools does not upload or validate the complete CIP-119 schema.'
            ;;
          'Enter known hash') cntools_ui_input hash 'Metadata hash' '64 hexadecimal characters (Blake2b-256)' || return $?; hash="${hash,,}" ;;
          *) return 2 ;;
        esac
        ;;
      *) return 2 ;;
    esac
    if ! cntools_drep_lifecycle_anchor_valid "${url}" "${hash}"; then
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
