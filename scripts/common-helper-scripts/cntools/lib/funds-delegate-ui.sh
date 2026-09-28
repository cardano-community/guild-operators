#!/usr/bin/env bash
# Pool selection and delegation presentation; signing/export use shared stake UI.
# shellcheck disable=SC2034

cntools_delegate_pool_local_into() {
  local result_name="$1" selected="" directory="" file="" name="" response="" errors="" status=0 index=0
  local cold="${CNTOOLS_POOL_COLD_VKEY_FILENAME:-cold.vkey}" id="${CNTOOLS_POOL_ID_FILENAME:-pool.id}"
  local -a labels=() directories=()
  [[ "${cold}" =~ ^[A-Za-z0-9_.-]+$ && "${id}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 2
  if [[ -n "${CNTOOLS_POOL_DIR:-}" ]] && cntools_transaction_path_components_safe "${CNTOOLS_POOL_DIR}" && [[ -d "${CNTOOLS_POOL_DIR}" ]]; then
    for directory in "${CNTOOLS_POOL_DIR}"/*; do
      [[ -d "${directory}" && ! -L "${directory}" ]] || continue
      name="${directory##*/}"
      [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9_.\ -]*$ ]] || continue
      if cntools_transaction_file_safe "${directory}/${cold}" 65536 || cntools_transaction_file_safe "${directory}/${id}" 1024; then
        labels+=("${name}"); directories+=("${directory}")
      fi
    done
  fi
  if (( ${#labels[@]} == 0 )); then
    cntools_ui_render_status info 'No readable local pool public keys or pool IDs were found. Enter a pool ID instead.'
    return 3
  fi
  cntools_ui_choose selected 'Local stake pool' "${labels[@]}" Cancel || return $?
  [[ "${selected}" != Cancel ]] || return 1
  for index in "${!labels[@]}"; do [[ "${labels[index]}" != "${selected}" ]] || break; done
  [[ "${labels[index]}" == "${selected}" ]] || return 2
  directory="${directories[index]}"; file="${directory}/${cold}"
  if cntools_transaction_file_safe "${file}" 65536; then
    cntools_transaction_temp_file response pool-id || return 2
    cntools_transaction_temp_file errors pool-id-errors || return 2
    cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" latest stake-pool id \
      --cold-verification-key-file "${file}" --output-bech32 || status=$?
    if ((status != 0)); then
      cntools_transaction_log_cli_failure 'Could not read local pool identity' "${status}" "${errors}" "${response}"; return 2
    fi
    printf -v "${result_name}" '%s' "$(< "${response}")"
  else
    file="${directory}/${id}"
    cntools_transaction_file_safe "${file}" 1024 || return 2
    printf -v "${result_name}" '%s' "$(< "${file}")"
  fi
  cntools_transaction_log CHOICE "Delegate local pool selected=${selected} directory=${directory}"
}

cntools_delegate_render_pool_rows() {
  cntools_transaction_ui_styled_row 'Current stake pool' "${CNTOOLS_DELEGATE_CURRENT_POOL:-Not delegated}" identifier
  cntools_transaction_ui_styled_row 'Target stake pool' "${CNTOOLS_DELEGATE_POOL_ID}" identifier
  [[ -z "${CNTOOLS_POOL_NAME}" ]] || cntools_transaction_ui_styled_row 'Pool name (metadata)' "${CNTOOLS_POOL_NAME}" value
  [[ -z "${CNTOOLS_POOL_TICKER}" ]] || cntools_transaction_ui_styled_row 'Ticker (metadata)' "${CNTOOLS_POOL_TICKER}" value
  cntools_transaction_ui_styled_row 'Pool status' "${CNTOOLS_POOL_STATUS}" "$([[ "${CNTOOLS_POOL_STATUS}" == retiring ]] && printf warning || printf success)"
  [[ -z "${CNTOOLS_DELEGATE_RETIRING}" ]] || cntools_transaction_ui_styled_row 'Retirement epoch' "$(cntools_number_format "${CNTOOLS_DELEGATE_RETIRING}")" warning
  cntools_transaction_ui_styled_row 'Pool checked through' "${CNTOOLS_POOL_SOURCE}" value
  cntools_transaction_ui_styled_row 'Stake registration' "$([[ "${CNTOOLS_DELEGATE_REGISTER}" == Y ]] && printf 'Register in this transaction' || printf 'Already registered')" value
}

cntools_delegate_choose_target() {
  local choice="" entered="" status=0 widths=""
  CNTOOLS_DELEGATE_POOL_ID=""; CNTOOLS_DELEGATE_POOL_HEX=""; CNTOOLS_DELEGATE_RETIRING=""
  CNTOOLS_DELEGATE_REGISTRATION_CONFIRMED=N
  while true; do
    cntools_wallet_register_begin
    cntools_transaction_ui_table_widths_into widths 22 || return 2
    {
      printf 'Wallet detail\tValue\n'
      cntools_transaction_ui_styled_row Wallet "${CNTOOLS_WALLET_REGISTER_WALLET}" identifier
      cntools_transaction_ui_styled_row 'Current stake pool' "${CNTOOLS_DELEGATE_CURRENT_POOL:-Not delegated}" identifier
    } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 2
    cntools_ui_choose choice 'Stake pool' 'Enter pool ID' 'Local pool' Cancel || return $?
    cntools_transaction_log CHOICE "Delegate target source=${choice}"
    case "${choice}" in
      'Enter pool ID') cntools_ui_input entered 'Stake pool ID' 'pool1… or 56-character hex ID' || return $? ;;
      'Local pool')
        status=0; cntools_delegate_pool_local_into entered || status=$?
        (( status != 3 )) || { cntools_ui_wait; continue; }
        (( status == 0 )) || return "${status}" ;;
      Cancel) return 1 ;;
      *) return 2 ;;
    esac
    if ! cntools_pool_id_into CNTOOLS_DELEGATE_POOL_ID CNTOOLS_DELEGATE_POOL_HEX "${entered}"; then
      cntools_ui_render_status warn 'Invalid stake pool ID. Check the full ID and checksum.'; cntools_ui_wait; continue
    fi
    if [[ "${CNTOOLS_DELEGATE_CURRENT_POOL}" == "${CNTOOLS_DELEGATE_POOL_ID}" ]]; then
      cntools_ui_render_status info 'This wallet already delegates to that pool. No transaction is needed.'; cntools_ui_wait; continue
    fi
    status=0
    cntools_ui_spin_function 'Checking the target stake pool…' cntools_pool_query \
      "${CNTOOLS_DELEGATE_POOL_ID}" "${CNTOOLS_DELEGATE_POOL_HEX}" "${CNTOOLS_WALLET_REGISTER_BACKEND}" || status=$?
    if (( status == 4 )); then
      cntools_ui_render_status warn 'The pool is not registered on this network, or has retired.'; cntools_ui_wait; continue
    elif (( status != 0 )); then
      cntools_wallet_register_set_error 'The target pool could not be verified. Check the node/API and try again.'; return 2
    fi
    CNTOOLS_DELEGATE_RETIRING="${CNTOOLS_POOL_RETIRING}"
    cntools_wallet_register_begin
    { printf 'Pool detail\tValue\n'; cntools_delegate_render_pool_rows; } |
      cntools_ui_table --separator $'\t' --widths "${widths}" || return 2
    if [[ "${CNTOOLS_POOL_STATUS}" == retiring ]]; then
      status=0
      cntools_ui_confirm "This pool retires in epoch $(cntools_number_format "${CNTOOLS_POOL_RETIRING}"). Delegate to it anyway?" false || status=$?
      cntools_transaction_log CHOICE "Delegate retiring pool confirmation status=${status}"
      (( status == 0 )) || return "${status}"
    fi
    if [[ "${CNTOOLS_DELEGATE_REGISTER}" == Y ]]; then
      status=0
      cntools_ui_confirm "Register this stake address in the same transaction? Deposit: $(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_REGISTER_DEPOSIT}") plus the transaction fee." false || status=$?
      cntools_transaction_log CHOICE "Delegate registration confirmation status=${status} deposit=${CNTOOLS_WALLET_REGISTER_DEPOSIT}"
      (( status == 0 )) || return "${status}"
      CNTOOLS_DELEGATE_REGISTRATION_CONFIRMED=Y
    fi
    cntools_transaction_log CHOICE "Delegate target=${CNTOOLS_DELEGATE_POOL_ID} registration=${CNTOOLS_DELEGATE_REGISTER}"
    return 0
  done
}

cntools_delegate_reminder() {
  cntools_ui_render_status info 'Existing DRep delegation is unchanged. Under current Conway rules, reward withdrawals require voting delegation to a DRep or a predefined option (Abstain / No Confidence). If not already set, do this separately before withdrawing rewards; ordinary fund transfers are unaffected.'
}

cntools_funds_action_delegate() {
  CNTOOLS_DELEGATE_REGISTRATION_CONFIRMED=N
  cntools_wallet_register_operation_set delegate || return 1
  cntools_wallet_action_stake_lifecycle
}
