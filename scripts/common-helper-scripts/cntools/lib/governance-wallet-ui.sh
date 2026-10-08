#!/usr/bin/env bash
# Wallet-scoped DRep key setup and read-only on-chain status.
# shellcheck disable=SC2034,SC2153

cntools_governance_wallet_select_into() {
  local output_name="$1" selected="" title="$2"
  cntools_ui_action_begin "${title}" "/ Vote / Governance / ${title}"
  cntools_wallet_catalog_build || return 2
  if ((${#CNTOOLS_WALLET_NAMES[@]} == 0)); then
    cntools_ui_render_status info 'No wallets found. Create or import a wallet first.'; cntools_ui_wait; return 1
  fi
  cntools_wallet_choose selected Cancel || return $?
  printf -v "${output_name}" '%s' "${CNTOOLS_WALLET_PATHS[selected]}"
}

cntools_governance_wallet_failure() {
  cntools_ui_render_status error "${CNTOOLS_DREP_KEY_ERROR:-DRep wallet information could not be validated. Existing files were retained; see the log.}"
  cntools_log ERROR "${CNTOOLS_DREP_KEY_ERROR:-DRep wallet operation failed validation.}" || true
  cntools_ui_wait
  return 2
}

cntools_governance_action_keys() {
  local directory="" method="" account=0 phrase="" widths="" status=0 path="Not derived · back up the signing key"
  # Existing mnemonic controls share presentation but keep the governance path.
  local CNTOOLS_MNEMONIC_INPUT_PATH='/ Vote / Governance / Derive Keys'
  cntools_governance_wallet_select_into directory 'Derive Keys' || return $?
  cntools_drep_key_preflight "${directory}" || { cntools_governance_wallet_failure; return $?; }
  cntools_ui_render_status info 'Create a separate DRep identity in this wallet. This does not register it or change your voting delegation.'
  cntools_ui_choose method 'DRep key source' 'Derive from recovery phrase' 'Generate new CLI keys' Cancel || return $?
  cntools_log CHOICE "DRep key source=${method} wallet=${directory##*/}" || true
  case "${method}" in
    'Derive from recovery phrase')
      method=mnemonic
      cntools_wallet_mnemonic_prompt_index_into account Account 'Derive Keys' "${CNTOOLS_MNEMONIC_INPUT_PATH}" || return $?
      path="1852H/1815H/${account}H/3/0"
      ;;
    'Generate new CLI keys') method=cli ;;
    Cancel) return 1 ;;
    *) return 2 ;;
  esac
  cntools_ui_action_begin 'Derive Keys' "${CNTOOLS_MNEMONIC_INPUT_PATH}"
  cntools_transaction_ui_table_widths_into widths 20 || return 2
  {
    printf 'DRep keys\tValue\n'
    cntools_transaction_ui_styled_row Wallet "${directory##*/}" identifier
    cntools_transaction_ui_styled_row Method "${method}" accent
    cntools_transaction_ui_styled_row 'Derivation path' "${path}" identifier
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 2
  if [[ "${method}" == mnemonic ]]; then
    cntools_ui_render_status warn 'Use an air-gapped machine for recovery phrases where possible. The phrase is not saved. Back up this DRep recovery phrase and account separately if they differ from the payment wallet; the payment/stake keys cannot recover it.'
  else
    cntools_ui_render_status warn 'This independently generated DRep key cannot be recovered from a wallet recovery phrase. Back up the new signing key.'
  fi
  cntools_ui_confirm 'Add these DRep keys to the selected wallet?' false || return $?
  cntools_log CHOICE "DRep key creation confirmed wallet=${directory##*/} method=${method} account=${account}" || true
  if [[ "${method}" == mnemonic ]]; then
    cntools_wallet_mnemonic_collect_import_into phrase || return $?
  fi
  # Do not pass the recovery phrase through an external spinner/argv or log it.
  cntools_drep_key_create "${directory}" "${method}" "${account}" "${phrase}" || status=$?
  unset phrase
  cntools_ui_action_begin 'Derive Keys' "${CNTOOLS_MNEMONIC_INPUT_PATH}"
  ((status == 0)) || { cntools_governance_wallet_failure; return $?; }
  cntools_drep_key_inspect "${directory}" || { cntools_governance_wallet_failure; return $?; }
  {
    printf 'DRep keys\tValue\n'
    cntools_transaction_ui_styled_row Wallet "${directory##*/}" identifier
    cntools_transaction_ui_styled_row 'DRep ID' "${CNTOOLS_DREP_KEY_ID}" identifier
    cntools_transaction_ui_styled_row 'Saved in' "${directory}" identifier
    [[ -z "${CNTOOLS_DREP_KEY_PATH}" ]] || cntools_transaction_ui_styled_row 'Derivation path' "${CNTOOLS_DREP_KEY_PATH}" identifier
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 2
  cntools_ui_render_status success 'DRep keys created. No transaction was made. Back up the keys, then use Wallet → Encrypt to protect all private wallet keys, including the DRep key.'
  cntools_ui_wait
}

cntools_governance_status_collect() {
  local status=0
  CNTOOLS_DREP_STATUS=unknown CNTOOLS_DREP_ACTIVE=unknown CNTOOLS_DREP_SOURCE=Offline CNTOOLS_DREP_DETAILS='{}'
  [[ "${CNTOOLS_MODE:-offline}" != offline ]] || return 0
  if [[ "${CNTOOLS_MODE}" == local && "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == true ]]; then
    cntools_drep_query "${CNTOOLS_DREP_KEY_ID}" "${CNTOOLS_DREP_KEY_KIND}" "${CNTOOLS_DREP_KEY_HASH}" local || status=$?
    ((status == 0 || status == 4)) && return 0
    cntools_log WARN 'Local DRep status unavailable; trying Koios if enabled' || true
  fi
  status=0
  if [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == Y ]]; then
    cntools_drep_query "${CNTOOLS_DREP_KEY_ID}" "${CNTOOLS_DREP_KEY_KIND}" "${CNTOOLS_DREP_KEY_HASH}" koios || status=$?
    ((status == 0 || status == 4)) && return 0
  fi
  CNTOOLS_DREP_STATUS=unknown CNTOOLS_DREP_ACTIVE=unknown CNTOOLS_DREP_SOURCE=Unavailable CNTOOLS_DREP_DETAILS='{}'
  cntools_log WARN 'DRep registration/activity could not be queried; retaining local identity information' || true
}

cntools_governance_status_rows() {
  local field="" value="" label="" role="" registration=Unavailable activity='Unavailable from local state'
  case "${CNTOOLS_DREP_STATUS}" in
    registered) registration=Registered ;;
    deregistered) registration=Retired ;;
    not_registered) registration='Not registered' ;;
  esac
  [[ "${CNTOOLS_DREP_SOURCE}" != Offline ]] || registration='Not queried · offline'
  cntools_transaction_ui_styled_row Registration "${registration}" "$([[ "${CNTOOLS_DREP_STATUS}" == unknown ]] && printf muted || printf value)"
  cntools_transaction_ui_styled_row 'Status source' "${CNTOOLS_DREP_SOURCE}" value
  if [[ "${CNTOOLS_DREP_STATUS}" == registered ]]; then
    case "${CNTOOLS_DREP_ACTIVE}" in true) activity=Active ;; false) activity=Inactive ;; esac
    cntools_transaction_ui_styled_row Activity "${activity}" "$([[ "${CNTOOLS_DREP_ACTIVE}" == true ]] && printf success || printf warning)"
    for field in deposit expiry amount live_delegator_count meta_url meta_hash; do
      value="$(jq -r --arg field "${field}" '.[$field] | select(type == "string" or type == "number")' <<< "${CNTOOLS_DREP_DETAILS}")" || return 1
      [[ -n "${value}" ]] || continue
      role=number
      case "${field}" in
        deposit|amount)
          [[ "${value}" =~ ^[0-9]+$ ]] || continue
          value="$(cntools_number_format_units "${value}" 6) ADA" || return 1
          label=Deposit; [[ "${field}" != amount ]] || label='Voting power (snapshot)'
          ;;
        expiry|live_delegator_count)
          [[ "${value}" =~ ^[0-9]+$ ]] || continue
          value="$(cntools_number_format "${value}")" || return 1
          label='Expiry epoch'; [[ "${field}" != live_delegator_count ]] || label=Delegators
          [[ "${field}:${CNTOOLS_DREP_SOURCE}" != 'expiry:Local node' ]] || label='Ledger expiry epoch'
          ;;
        meta_url) label='Metadata URL'; role=identifier ;;
        meta_hash) label='Metadata hash'; role=identifier ;;
      esac
      cntools_transaction_ui_styled_row "${label}" "${value}" "${role}"
    done
  fi
}

cntools_governance_action_info() {
  local directory="" widths="" status=0 protection=Absent verification=Absent
  cntools_governance_wallet_select_into directory 'Info & Status' || return $?
  cntools_drep_key_inspect "${directory}" || status=$?
  if ((status == 4)); then
    cntools_ui_render_status info 'No usable DRep identity found. Create keys through Governance → Derive Keys if none exist. Missing public files require Cardano CLI and an open key; restore the public verification key for encrypted/hardware keys.'
    cntools_ui_wait; return 0
  fi
  ((status == 0)) || { cntools_governance_wallet_failure; return $?; }
  if [[ "${CNTOOLS_MODE:-offline}" == offline ]]; then
    cntools_governance_status_collect
  else
    cntools_ui_spin_function 'Checking DRep status…' cntools_governance_status_collect || return 2
  fi
  cntools_ui_action_begin 'Info & Status' '/ Vote / Governance / Info & Status'
  [[ ! -f "${directory}/${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}" ]] || verification=Available
  [[ ! -f "${directory}/${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}" ]] || protection='Unencrypted signing key'
  [[ ! -f "${directory}/${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}.gpg" ]] || protection=Encrypted
  [[ ! -f "${directory}/${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}" ]] || protection='Hardware reference (device not checked)'
  cntools_transaction_ui_table_widths_into widths 24 || return 2
  {
    printf 'DRep\tValue\n'
    cntools_transaction_ui_styled_row Wallet "${directory##*/}" identifier
    cntools_transaction_ui_styled_row 'DRep ID' "${CNTOOLS_DREP_KEY_ID}" identifier
    cntools_transaction_ui_styled_row 'Credential (hex)' "${CNTOOLS_DREP_KEY_HASH}" identifier
    cntools_transaction_ui_styled_row 'Verification key' "${verification}" value
    cntools_transaction_ui_styled_row 'Identity check' "$([[ "${CNTOOLS_DREP_KEY_VERIFIED}" == Y ]] && printf 'Matches verification key' || printf 'Cached ID checksum only')" value
    cntools_transaction_ui_styled_row 'Private key' "${protection}" "$([[ "${protection}" == 'Unencrypted signing key' ]] && printf warning || printf value)"
    [[ -z "${CNTOOLS_DREP_KEY_PATH}" ]] || cntools_transaction_ui_styled_row 'Derivation path' "${CNTOOLS_DREP_KEY_PATH}" identifier
    cntools_governance_status_rows
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 2
  cntools_public_metadata_offer "$(jq -r '.meta_url // ""' <<< "${CNTOOLS_DREP_DETAILS}")" \
    "$(jq -r '.meta_hash // ""' <<< "${CNTOOLS_DREP_DETAILS}")"
  cntools_ui_wait
}
