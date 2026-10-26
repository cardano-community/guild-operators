#!/usr/bin/env bash
# Pool selection and delegation presentation; signing/export use shared stake UI.
# shellcheck disable=SC2034

declare -ag CNTOOLS_DELEGATE_LOCAL_LABELS=() CNTOOLS_DELEGATE_LOCAL_DIRECTORIES=()
CNTOOLS_DELEGATE_LOCAL_NAME=""

cntools_delegate_local_pools_collect() {
  local directory="" name=""
  local cold="${CNTOOLS_POOL_COLD_VKEY_FILENAME:-cold.vkey}" id="${CNTOOLS_POOL_ID_FILENAME:-pool.id}"
  CNTOOLS_DELEGATE_LOCAL_LABELS=(); CNTOOLS_DELEGATE_LOCAL_DIRECTORIES=()
  [[ "${cold}" =~ ^[A-Za-z0-9_.-]+$ && "${id}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 2
  if [[ -n "${CNTOOLS_POOL_DIR:-}" ]] && cntools_filesystem_path_components_safe "${CNTOOLS_POOL_DIR}" && [[ -d "${CNTOOLS_POOL_DIR}" ]]; then
    for directory in "${CNTOOLS_POOL_DIR}"/*; do
      [[ -d "${directory}" && ! -L "${directory}" ]] || continue
      name="${directory##*/}"
      [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9_.\ -]*$ ]] || continue
      if cntools_transaction_file_safe "${directory}/${cold}" 65536 || cntools_transaction_file_safe "${directory}/${id}" 1024; then
        CNTOOLS_DELEGATE_LOCAL_LABELS+=("${name}"); CNTOOLS_DELEGATE_LOCAL_DIRECTORIES+=("${directory}")
      fi
    done
  fi
}

cntools_delegate_pool_local_into() {
  local result_name="$1" selected="" directory="" file="" response="" errors="" status=0 index=0
  local cold="${CNTOOLS_POOL_COLD_VKEY_FILENAME:-cold.vkey}" id="${CNTOOLS_POOL_ID_FILENAME:-pool.id}"
  local -a labels=() directories=()
  cntools_delegate_local_pools_collect || return 2
  labels=("${CNTOOLS_DELEGATE_LOCAL_LABELS[@]}"); directories=("${CNTOOLS_DELEGATE_LOCAL_DIRECTORIES[@]}")
  if (( ${#labels[@]} == 0 )); then
    cntools_ui_render_status info 'No readable local pool public keys or pool IDs were found. Enter a pool ID instead.'
    return 3
  fi
  if (( ${#labels[@]} == 1 )); then
    # The review names it in its 'Local pool' row.
    selected="${labels[0]}"
  else
    cntools_ui_choose selected 'Local stake pool' "${labels[@]}" Cancel || return $?
    [[ "${selected}" != Cancel ]] || return 1
  fi
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
  CNTOOLS_DELEGATE_LOCAL_NAME="${selected}"
  cntools_transaction_log CHOICE "Delegate local pool selected=${selected} directory=${directory}"
}

cntools_delegate_render_pool_rows() {
  cntools_transaction_ui_styled_row 'Current stake pool' "${CNTOOLS_DELEGATE_CURRENT_POOL:-Not delegated}" identifier
  cntools_transaction_ui_styled_row 'Target stake pool' "${CNTOOLS_DELEGATE_POOL_ID}" identifier
  [[ -z "${CNTOOLS_DELEGATE_LOCAL_NAME}" ]] || cntools_transaction_ui_styled_row 'Local pool' "${CNTOOLS_DELEGATE_LOCAL_NAME}" value
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
    CNTOOLS_DELEGATE_LOCAL_NAME=""
    cntools_wallet_register_begin
    cntools_transaction_ui_table_widths_into widths 22 || return 2
    {
      printf 'Wallet detail\tValue\n'
      cntools_transaction_ui_styled_row Wallet "${CNTOOLS_WALLET_REGISTER_WALLET}" identifier
      cntools_transaction_ui_styled_row 'Current stake pool' "${CNTOOLS_DELEGATE_CURRENT_POOL:-Not delegated}" identifier
    } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 2
    cntools_delegate_local_pools_collect || return 2
    entered=""
    if (( ${#CNTOOLS_DELEGATE_LOCAL_LABELS[@]} == 0 )); then
      # Without local pools the only source is an ID.
      choice='Enter pool ID'
    elif cntools_flow_quick; then
      # One field: an ID, or Enter to pick a local pool.
      cntools_ui_input entered 'Stake pool' 'pool1…, hex ID, or Enter to pick a local pool' || return $?
      entered="${entered//[[:space:]]/}"
      choice='Enter pool ID'; [[ -n "${entered}" ]] || choice='Local pool'
    else
      cntools_ui_choose choice 'Stake pool' 'Enter pool ID' 'Local pool' Cancel || return $?
    fi
    cntools_transaction_log CHOICE "Delegate target source=${choice}"
    case "${choice}" in
      'Enter pool ID') [[ -n "${entered}" ]] || cntools_ui_input entered 'Stake pool ID' 'pool1… or 56-character hex ID' || return $? ;;
      'Local pool')
        status=0; cntools_delegate_pool_local_into entered || status=$?
        (( status != 3 )) || { cntools_ui_wait; continue; }
        (( status != 1 )) || continue
        (( status == 0 )) || return "${status}" ;;
      Cancel) return 1 ;;
      *) return 2 ;;
    esac
    # Warnings carry to the redrawn pool field until it is answered.
    if ! cntools_pool_id_into CNTOOLS_DELEGATE_POOL_ID CNTOOLS_DELEGATE_POOL_HEX "${entered}"; then
      cntools_ui_render_status warn 'Invalid stake pool ID. Check the full ID and checksum.'; continue
    fi
    if [[ "${CNTOOLS_DELEGATE_CURRENT_POOL}" == "${CNTOOLS_DELEGATE_POOL_ID}" ]]; then
      cntools_ui_render_status warn 'This wallet already delegates to that pool. No transaction is needed; choose another pool or cancel.'; continue
    fi
    status=0
    cntools_ui_spin_function 'Checking the target stake pool…' cntools_pool_query \
      "${CNTOOLS_DELEGATE_POOL_ID}" "${CNTOOLS_DELEGATE_POOL_HEX}" "${CNTOOLS_WALLET_REGISTER_BACKEND}" || status=$?
    if (( status == 4 )); then
      cntools_ui_render_status warn 'The pool is not registered on this network, or has retired.'; continue
    elif (( status != 0 )); then
      cntools_wallet_register_set_error 'The target pool could not be verified. Check the node/API and try again.'; return 2
    fi
    CNTOOLS_DELEGATE_RETIRING="${CNTOOLS_POOL_RETIRING}"
    if [[ "${CNTOOLS_POOL_STATUS}" == retiring ]]; then
      cntools_wallet_register_begin
      { printf 'Pool detail\tValue\n'; cntools_delegate_render_pool_rows; } |
        cntools_ui_table --separator $'\t' --widths "${widths}" || return 2
      status=0
      cntools_ui_confirm "This pool retires in epoch $(cntools_number_format "${CNTOOLS_POOL_RETIRING}"). Delegate to it anyway?" false || status=$?
      cntools_transaction_log CHOICE "Delegate retiring pool confirmation status=${status}"
      # No (or Esc) returns to the pool field; Ctrl+C cancels.
      (( status != 130 )) || return 130
      (( status == 0 )) || continue
    fi
    # Registering is required to delegate; the review shows it and the deposit.
    [[ "${CNTOOLS_DELEGATE_REGISTER}" != Y ]] || CNTOOLS_DELEGATE_REGISTRATION_CONFIRMED=Y
    cntools_transaction_log CHOICE "Delegate target=${CNTOOLS_DELEGATE_POOL_ID} registration=${CNTOOLS_DELEGATE_REGISTER} deposit=${CNTOOLS_WALLET_REGISTER_DEPOSIT}"
    return 0
  done
}

# Review 'Change pool': any non-zero status keeps the reviewed pool.
cntools_delegate_change_target() {
  local status=0
  local -a saved=("${CNTOOLS_DELEGATE_POOL_ID}" "${CNTOOLS_DELEGATE_POOL_HEX}" "${CNTOOLS_DELEGATE_RETIRING}"
    "${CNTOOLS_DELEGATE_REGISTRATION_CONFIRMED}" "${CNTOOLS_DELEGATE_LOCAL_NAME}" "${CNTOOLS_POOL_STATUS}"
    "${CNTOOLS_POOL_RETIRING}" "${CNTOOLS_POOL_NAME}" "${CNTOOLS_POOL_TICKER}" "${CNTOOLS_POOL_SOURCE}")
  cntools_delegate_choose_target || status=$?
  (( status != 0 )) || return 0
  CNTOOLS_DELEGATE_POOL_ID="${saved[0]}" CNTOOLS_DELEGATE_POOL_HEX="${saved[1]}" CNTOOLS_DELEGATE_RETIRING="${saved[2]}"
  CNTOOLS_DELEGATE_REGISTRATION_CONFIRMED="${saved[3]}" CNTOOLS_DELEGATE_LOCAL_NAME="${saved[4]}" CNTOOLS_POOL_STATUS="${saved[5]}"
  CNTOOLS_POOL_RETIRING="${saved[6]}" CNTOOLS_POOL_NAME="${saved[7]}" CNTOOLS_POOL_TICKER="${saved[8]}" CNTOOLS_POOL_SOURCE="${saved[9]}"
  cntools_transaction_log CHOICE "Delegate pool unchanged status=${status} pool=${CNTOOLS_DELEGATE_POOL_ID}"
  return "${status}"
}

# Only when the stake query showed no voting delegation; unknown stays quiet.
cntools_delegate_reminder() {
  [[ -z "${CNTOOLS_WALLET_DREP_DELEGATION:-}" && "${CNTOOLS_WALLET_DREP_DELEGATION_VALID:-Y}" == Y ]] || return 0
  cntools_ui_render_status info 'This wallet has no voting (DRep) delegation. Reward withdrawals need one: Vote → Governance → Delegate.'
}

cntools_funds_action_delegate() {
  CNTOOLS_DELEGATE_REGISTRATION_CONFIRMED=N CNTOOLS_DELEGATE_LOCAL_NAME=""
  cntools_wallet_register_operation_set delegate || return 1
  cntools_wallet_action_stake_lifecycle
}
