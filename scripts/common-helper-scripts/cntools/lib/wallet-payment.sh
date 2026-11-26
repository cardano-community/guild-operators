#!/usr/bin/env bash
# Shared, verified payment identity and change address for key-wallet actions.
# shellcheck disable=SC2034

cntools_payment_prepare_wallet() {
  local directory="${1:-}" kind="" identity="" role="" file=""
  cntools_wallet_directory_safe "${directory}" || {
    cntools_transaction_set_error 'The funding wallet directory is unsafe or inaccessible.'; return 1;
  }
  cntools_wallet_prepare_selected_material "${directory}" || {
    cntools_transaction_set_error 'The funding wallet public keys, addresses or credentials could not be prepared safely.'; return 1;
  }
  CNTOOLS_PAYMENT_TYPE="$(cntools_wallet_type "${directory}")" || return 1
  if [[ "${CNTOOLS_PAYMENT_TYPE}" == MultiSig ]]; then
    if [[ "${2:-}" == multisig ]] && declare -F cntools_multisig_spend_prepare >/dev/null; then
      cntools_multisig_spend_prepare "${directory}"
      return $?
    fi
    cntools_transaction_set_error "Multisig spending is not yet supported for this action."; return 1
  fi
  CNTOOLS_PAYMENT_ADDRESS=""; CNTOOLS_PAYMENT_PAYMENT=""; CNTOOLS_PAYMENT_SOURCE=""
  cntools_wallet_read_address "${directory}" payment CNTOOLS_PAYMENT_PAYMENT || {
    cntools_transaction_set_error "This source needs a valid payment address and public payment key."; return 1;
  }
  cntools_wallet_read_address "${directory}" base CNTOOLS_PAYMENT_ADDRESS || CNTOOLS_PAYMENT_ADDRESS="${CNTOOLS_PAYMENT_PAYMENT}"
  cntools_recipient_validate "${CNTOOLS_PAYMENT_ADDRESS}" || return 1
  CNTOOLS_PAYMENT_VKEY="${directory}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"
  cntools_wallet_key_validate "${CNTOOLS_PAYMENT_VKEY}" payment any || {
    cntools_transaction_set_error "The source wallet's payment verification key is invalid."; return 1;
  }
  cntools_wallet_id_read_credential "${directory}" payment CNTOOLS_PAYMENT_CREDENTIAL || {
    cntools_transaction_set_error "The source wallet's payment credential is missing or invalid."; return 1;
  }
  file="${directory}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}"
  [[ "${CNTOOLS_PAYMENT_TYPE}" != Hardware ]] || file="${directory}/${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}"
  if cntools_transaction_source_kind_into kind "${file}"; then
    case "${CNTOOLS_PAYMENT_TYPE}:${kind}" in
      Hardware:hardware|CLI:cli|Mnemonic:cli) CNTOOLS_PAYMENT_SOURCE="${file}" ;;
    esac
  fi
  # Re-derive public addresses in private temporary files, never replace cached
  # artifacts. A stale address must not redirect change away from this key.
  for role in payment base; do
    [[ "${role}" != base || "${CNTOOLS_PAYMENT_ADDRESS}" != "${CNTOOLS_PAYMENT_PAYMENT}" ]] || continue
    cntools_transaction_temp_file file payment-address || return 1
    local errors=""
    cntools_transaction_temp_file errors payment-address-error || return 1
    local -a args=(--payment-verification-key-file "${CNTOOLS_PAYMENT_VKEY}") network=()
    [[ "${role}" != base ]] || args+=(--stake-verification-key-file "${directory}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}")
    cntools_transaction_network_arguments_into network "${CNTOOLS_NETWORK}" || return 1
    local status=0
    cntools_transaction_run_cli "${file}" "${errors}" -- "${CNTOOLS_CLI}" address build \
      "${args[@]}" "${network[@]}" || status=$?
    if (( status != 0 )); then
      cntools_transaction_log_cli_failure "Could not verify source wallet addresses" "${status}" "${errors}" "${file}"
      return 1
    fi
    identity="$(< "${file}")"
    if [[ "${role}" == payment ]]; then
      [[ "${identity}" == "${CNTOOLS_PAYMENT_PAYMENT}" ]] || {
        cntools_transaction_set_error "The cached payment address does not match this wallet's key. Review its public artifacts."; return 1;
      }
    else
      [[ "${identity}" == "${CNTOOLS_PAYMENT_ADDRESS}" ]] || {
        cntools_transaction_set_error "The cached base address does not match this wallet's keys. Review its public artifacts."; return 1;
      }
    fi
  done
  CNTOOLS_PAYMENT_DIRECTORY="${directory}"; CNTOOLS_PAYMENT_WALLET="${directory##*/}"
}
