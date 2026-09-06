#!/usr/bin/env bash
# Exact-value transfers with optional frozen metadata; no script spending.
# shellcheck disable=SC2034

CNTOOLS_SEND_WALLET=""
CNTOOLS_SEND_DIRECTORY=""
CNTOOLS_SEND_TYPE=""
CNTOOLS_SEND_ADDRESS=""
CNTOOLS_SEND_PAYMENT=""
CNTOOLS_SEND_VKEY=""
CNTOOLS_SEND_SOURCE=""
CNTOOLS_SEND_CREDENTIAL=""
CNTOOLS_SEND_MODE=exact
CNTOOLS_SEND_FEE=0
CNTOOLS_SEND_EXPIRY=""
CNTOOLS_SEND_POLICY='{}'
declare -ag CNTOOLS_SEND_ADDRESSES=() CNTOOLS_SEND_LABELS=() CNTOOLS_SEND_AMOUNTS=()
declare -ag CNTOOLS_SEND_HANDLES=() CNTOOLS_SEND_RESOLUTIONS=()
declare -ag CNTOOLS_SEND_OUTPUTS=() CNTOOLS_SEND_CHANGE_IDS=()
declare -Ag CNTOOLS_SEND_ASSETS=() CNTOOLS_SEND_DEMAND=() CNTOOLS_SEND_CHANGE_ASSETS=()

cntools_send_fail() {
  cntools_transaction_set_error "${1:-The funds transfer could not be prepared safely.}"
  return 1
}

cntools_send_prepare_wallet() {
  local directory="${1:-}" kind="" identity="" role="" file=""
  cntools_wallet_directory_safe "${directory}" || return 1
  cntools_wallet_prepare_selected_material "${directory}" || return 1
  CNTOOLS_SEND_TYPE="$(cntools_wallet_type "${directory}")" || return 1
  [[ "${CNTOOLS_SEND_TYPE}" != MultiSig ]] || {
    cntools_send_fail "Multisig spending is not available in this Send slice."; return 1;
  }
  CNTOOLS_SEND_ADDRESS=""; CNTOOLS_SEND_PAYMENT=""; CNTOOLS_SEND_SOURCE=""
  cntools_wallet_read_address "${directory}" payment CNTOOLS_SEND_PAYMENT || {
    cntools_send_fail "This source needs a valid payment address and public payment key."; return 1;
  }
  cntools_wallet_read_address "${directory}" base CNTOOLS_SEND_ADDRESS || CNTOOLS_SEND_ADDRESS="${CNTOOLS_SEND_PAYMENT}"
  cntools_recipient_validate "${CNTOOLS_SEND_ADDRESS}" || return 1
  CNTOOLS_SEND_VKEY="${directory}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"
  cntools_wallet_key_validate "${CNTOOLS_SEND_VKEY}" payment any || {
    cntools_send_fail "The source wallet's payment verification key is invalid."; return 1;
  }
  cntools_wallet_id_read_credential "${directory}" payment CNTOOLS_SEND_CREDENTIAL || {
    cntools_send_fail "The source wallet's payment credential is missing or invalid."; return 1;
  }
  file="${directory}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}"
  [[ "${CNTOOLS_SEND_TYPE}" != Hardware ]] || file="${directory}/${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}"
  if cntools_transaction_source_kind_into kind "${file}"; then
    case "${CNTOOLS_SEND_TYPE}:${kind}" in
      Hardware:hardware|CLI:cli|Mnemonic:cli) CNTOOLS_SEND_SOURCE="${file}" ;;
    esac
  fi
  # Re-derive public addresses in private temporary files, never replace cached
  # artifacts. A stale address must not redirect change away from this key.
  for role in payment base; do
    [[ "${role}" != base || "${CNTOOLS_SEND_ADDRESS}" != "${CNTOOLS_SEND_PAYMENT}" ]] || continue
    cntools_transaction_temp_file file send-address || return 1
    local errors=""
    cntools_transaction_temp_file errors send-address-error || return 1
    local -a args=(--payment-verification-key-file "${CNTOOLS_SEND_VKEY}") network=()
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
      [[ "${identity}" == "${CNTOOLS_SEND_PAYMENT}" ]] || {
        cntools_send_fail "The cached payment address does not match this wallet's key. Review its public artifacts."; return 1;
      }
    else
      [[ "${identity}" == "${CNTOOLS_SEND_ADDRESS}" ]] || {
        cntools_send_fail "The cached base address does not match this wallet's keys. Review its public artifacts."; return 1;
      }
    fi
  done
  CNTOOLS_SEND_DIRECTORY="${directory}"; CNTOOLS_SEND_WALLET="${directory##*/}"
  CNTOOLS_SEND_ADDRESSES=(); CNTOOLS_SEND_LABELS=(); CNTOOLS_SEND_AMOUNTS=(); CNTOOLS_SEND_ASSETS=()
  CNTOOLS_SEND_HANDLES=(); CNTOOLS_SEND_RESOLUTIONS=()
  CNTOOLS_SEND_MODE=exact
}

cntools_send_output_into() {
  local output_name="${1:-}" index="${2:-}" amount="${3:-}" asset="" value=""
  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "${index}" =~ ^[0-9]+$ ]] || return 2
  local -n send_output_ref="${output_name}"
  value="${CNTOOLS_SEND_ADDRESSES[index]}+${amount}"
  for asset in "${CNTOOLS_FUNDING_ASSET_IDS[@]}"; do
    [[ "${CNTOOLS_SEND_ASSETS[${index}|${asset}]:-0}" != 0 ]] || continue
    value+=" + ${CNTOOLS_SEND_ASSETS[${index}|${asset}]} ${asset%.}"
  done
  send_output_ref="${value}"
}

# calculate-min-required-utxo depends on the serialized coin size too; settle
# the amount before accepting a minimum, rather than calculating only at zero.
cntools_send_minimum_into() {
  local output_name="${1:-}" output="${2:-}" result="" current="" tail=""
  local attempt=0
  local -n minimum_ref="${output_name}"
  tail="${output#*+}"; current="${tail%% *}"
  for (( attempt=0; attempt<4; attempt++ )); do
    cntools_transaction_calculate_min_utxo_into result "${CNTOOLS_FUNDING_PROTOCOL}" "${output}" || return 1
    if cntools_uint_greater_equal "${current}" "${result}"; then minimum_ref="${result}"; return 0; fi
    output="${output%%+*}+${result}${tail#"${current}"}"
    current="${result}"; tail="${output#*+}"
  done
  return 1
}

cntools_send_demands() {
  local index=0 asset="" quantity="" sum="" minimum="" output="" key=""
  CNTOOLS_SEND_DEMAND=()
  case "${CNTOOLS_SEND_MODE}" in exact|max|sweep) ;; *) return 2 ;; esac
  (( ${#CNTOOLS_SEND_ADDRESSES[@]} >= 1 && ${#CNTOOLS_SEND_ADDRESSES[@]} <= 20 )) || return 2
  [[ "${CNTOOLS_SEND_MODE}" == exact || ${#CNTOOLS_SEND_ADDRESSES[@]} == 1 ]] || return 1
  if [[ "${CNTOOLS_SEND_MODE}" == sweep ]]; then
    CNTOOLS_SEND_ASSETS=()
    for asset in "${CNTOOLS_FUNDING_ASSET_IDS[@]}"; do
      CNTOOLS_SEND_ASSETS["0|${asset}"]="${CNTOOLS_FUNDING_ASSETS[${asset}]}"
    done
  fi
  # A refresh can remove an asset from the available inventory. Never silently
  # drop a previously requested asset merely because it is no longer present.
  for key in "${!CNTOOLS_SEND_ASSETS[@]}"; do
    [[ "${CNTOOLS_SEND_ASSETS[${key}]}" != 0 ]] || continue
    asset="${key#*|}"; index="${key%%|*}"
    [[ "${index}" =~ ^[0-9]+$ && -n "${CNTOOLS_SEND_ADDRESSES[index]+x}" &&
       -n "${CNTOOLS_FUNDING_ASSETS[${asset}]+x}" ]] || {
      cntools_send_fail "A requested asset is no longer available. Edit the recipients or refresh the wallet."; return 1;
    }
  done
  for index in "${!CNTOOLS_SEND_ADDRESSES[@]}"; do
    for asset in "${CNTOOLS_FUNDING_ASSET_IDS[@]}"; do
      quantity="${CNTOOLS_SEND_ASSETS[${index}|${asset}]:-0}"
      [[ "${quantity}" != 0 ]] || continue
      cntools_uint_add_into sum "${CNTOOLS_SEND_DEMAND[${asset}]:-0}" "${quantity}" || return 1
      cntools_uint_greater_equal "${CNTOOLS_FUNDING_ASSETS[${asset}]}" "${sum}" || {
        cntools_send_fail "Recipients request more than the available quantity of ${asset}."; return 1;
      }
      CNTOOLS_SEND_DEMAND["${asset}"]="${sum}"
    done
    cntools_send_output_into output "${index}" "${CNTOOLS_SEND_AMOUNTS[index]}" || return 1
    cntools_send_minimum_into minimum "${output}" || return 1
    if [[ "${CNTOOLS_SEND_MODE}" == exact ]] &&
       ! cntools_uint_greater_equal "${CNTOOLS_SEND_AMOUNTS[index]}" "${minimum}"; then
      # UI reviews this explicit adjustment before any signing or publication.
      cntools_transaction_log TRANSACTION "recipient=$((index+1)) minimum ADA adjustment old=${CNTOOLS_SEND_AMOUNTS[index]} new=${minimum}"
      CNTOOLS_SEND_AMOUNTS[index]="${minimum}"
    fi
  done
}

cntools_send_plan_signers() {
  local group="" stake_source=""
  cntools_transaction_plan_reset "Send funds" \
    "Transfer from ${CNTOOLS_SEND_WALLET}; rewards and deposits are not withdrawn." exact || return 1
  [[ "${CNTOOLS_SEND_TYPE}" != Hardware ]] || group=send-wallet
  cntools_transaction_plan_add_signer "${CNTOOLS_SEND_WALLET} payment" spending \
    "${CNTOOLS_SEND_VKEY}" "${CNTOOLS_SEND_SOURCE}" "${CNTOOLS_SEND_CREDENTIAL}" "${group}" || return 1
  if [[ "${CNTOOLS_SEND_TYPE}" == Hardware ]]; then
    cntools_transaction_plan_add_change_key "Payment change" "${CNTOOLS_SEND_VKEY}" \
      "${CNTOOLS_SEND_SOURCE}" "${group}" || return 1
    if [[ "${CNTOOLS_SEND_ADDRESS}" != "${CNTOOLS_SEND_PAYMENT}" ]]; then
      stake_source="${CNTOOLS_SEND_DIRECTORY}/${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}"
      cntools_transaction_plan_add_change_key "Stake change" \
        "${CNTOOLS_SEND_DIRECTORY}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" \
        "${stake_source}" "${group}" || return 1
    fi
  fi
  cntools_transaction_plan_set_validity "" "${CNTOOLS_SEND_EXPIRY}"
}

cntools_send_change() {
  local outputs_total="${1:-}" asset="" remaining="" minimum="" available="" cost=""
  CNTOOLS_SEND_CHANGE_IDS=(); CNTOOLS_SEND_CHANGE_ASSETS=()
  for asset in "${CNTOOLS_COIN_SELECTED_ASSET_IDS[@]}"; do
    cntools_uint_subtract_into remaining "${CNTOOLS_COIN_SELECTED_ASSETS[${asset}]}" \
      "${CNTOOLS_SEND_DEMAND[${asset}]:-0}" || return 1
    [[ "${remaining}" != 0 ]] || continue
    CNTOOLS_SEND_CHANGE_IDS+=("${asset}"); CNTOOLS_SEND_CHANGE_ASSETS["${asset}"]="${remaining}"
  done
  # Dynamic scope supplies the existing token planner with residual assets only.
  local -a CNTOOLS_COIN_SELECTED_ASSET_IDS=("${CNTOOLS_SEND_CHANGE_IDS[@]}")
  local -A CNTOOLS_COIN_SELECTED_ASSETS=()
  for asset in "${CNTOOLS_SEND_CHANGE_IDS[@]}"; do
    CNTOOLS_COIN_SELECTED_ASSETS["${asset}"]="${CNTOOLS_SEND_CHANGE_ASSETS[${asset}]}"
  done
  cntools_change_reset
  cntools_change_plan_tokens "${CNTOOLS_FUNDING_PROTOCOL}" "${CNTOOLS_SEND_ADDRESS}" || return 1
  # Recheck token output minima using their nonzero coin values.
  local index=0 output=""
  CNTOOLS_CHANGE_TOKEN_MIN_TOTAL=0
  for index in "${!CNTOOLS_CHANGE_OUTPUTS[@]}"; do
    cntools_send_minimum_into minimum "${CNTOOLS_CHANGE_OUTPUTS[index]}" || return 1
    output="${CNTOOLS_CHANGE_OUTPUTS[index]#*+}"
    CNTOOLS_CHANGE_OUTPUTS[index]="${CNTOOLS_SEND_ADDRESS}+${minimum}${output#"${CNTOOLS_CHANGE_OUTPUT_LOVELACE[index]}"}"
    CNTOOLS_CHANGE_OUTPUT_LOVELACE[index]="${minimum}"
    cntools_uint_add_into CNTOOLS_CHANGE_TOKEN_MIN_TOTAL "${CNTOOLS_CHANGE_TOKEN_MIN_TOTAL}" "${minimum}" || return 1
  done
  cntools_uint_add_into cost "${outputs_total}" "${CNTOOLS_SEND_FEE}" || return 1
  cntools_uint_add_into cost "${cost}" "${CNTOOLS_CHANGE_TOKEN_MIN_TOTAL}" || return 1
  cntools_send_minimum_into minimum "${CNTOOLS_SEND_ADDRESS}+0" || return 1
  if [[ "${CNTOOLS_SEND_MODE}" == exact ]]; then
    cntools_uint_add_into cost "${cost}" "${minimum}" || return 1
  fi
  if ! cntools_uint_greater_equal "${CNTOOLS_COIN_SELECTED_LOVELACE}" "${cost}"; then
    cntools_uint_subtract_into CNTOOLS_CHANGE_REQUIRED_EXTRA "${cost}" "${CNTOOLS_COIN_SELECTED_LOVELACE}" || return 1
    return 3
  fi
  if [[ "${CNTOOLS_SEND_MODE}" != exact ]]; then
    cntools_uint_subtract_into remaining "${CNTOOLS_COIN_SELECTED_LOVELACE}" "${cost}" || return 1
    CNTOOLS_SEND_AMOUNTS[0]="${remaining}"
    CNTOOLS_CHANGE_UTXO_STATUS="Skipped for Max ADA / Send everything"
    CNTOOLS_CHANGE_COLLATERAL_STATUS="Skipped for Max ADA / Send everything"
    return 0
  fi
  cntools_uint_subtract_into available "${CNTOOLS_COIN_SELECTED_LOVELACE}" "${cost}" || return 1
  cntools_uint_add_into available "${available}" "${minimum}" || return 1
  cntools_change_plain_min_into CNTOOLS_CHANGE_EFFECTIVE_MIN_LOVELACE \
    "${CNTOOLS_FUNDING_PROTOCOL}" "${CNTOOLS_SEND_ADDRESS}" || return 1
  cntools_change_plan_ada "${CNTOOLS_SEND_ADDRESS}" "${available}" || return 1
  cntools_change_output_add "Residual ADA" "${CNTOOLS_SEND_ADDRESS}+${CNTOOLS_CHANGE_RESIDUAL_LOVELACE}" \
    "${CNTOOLS_CHANGE_RESIDUAL_LOVELACE}" 0
}

cntools_send_build_into() {
  local output_name="${1:-}" total=0 required=0 extra=0 index=0 attempt=0 status=0
  local body="" package="" next_fee="" minimum="" output="" asset="" policy="" summary=""
  local max_size=0 max_value=0 value_bytes=0 body_bytes=0 witnesses=0
  local -a arguments=() metadata_arguments=()
  local -n send_package_ref="${output_name}"
  send_package_ref=""
  if declare -F cntools_metadata_arguments_into >/dev/null; then
    cntools_metadata_arguments_into metadata_arguments || {
      cntools_send_fail "${CNTOOLS_METADATA_ERROR:-Could not prepare transaction metadata.}"; return 1;
    }
  fi
  cntools_send_demands || return 1
  cntools_send_plan_signers || return 1
  CNTOOLS_SEND_FEE=0
  max_size="$(jq -er '.maxTxSize | select(type == "number" and . > 0 and . <= 100000) | floor' "${CNTOOLS_FUNDING_PROTOCOL}")" || return 1
  max_value="$(jq -er '.maxValueSize | select(type == "number" and . > 0 and . <= 100000) | floor' "${CNTOOLS_FUNDING_PROTOCOL}")" || return 1
  for (( attempt=0; attempt<20; attempt++ )); do
    total=0
    if [[ "${CNTOOLS_SEND_MODE}" == exact ]]; then
      for index in "${!CNTOOLS_SEND_AMOUNTS[@]}"; do
        cntools_uint_add_into total "${total}" "${CNTOOLS_SEND_AMOUNTS[index]}" || return 1
      done
      cntools_uint_add_into required "${total}" "${CNTOOLS_SEND_FEE}" || return 1
      cntools_uint_add_into required "${required}" "${extra}" || return 1
      cntools_coin_select_value "${required}" CNTOOLS_SEND_DEMAND "${CNTOOLS_TX_SELECTION_STRATEGY}" || {
        cntools_send_fail "${CNTOOLS_COIN_ERROR}"; return 1;
      }
    else
      cntools_coin_reset
      (( ${#CNTOOLS_UTXO_REFS[@]} <= 100 )) || { cntools_send_fail "Max/sweep exceeds the 100-input safety limit."; return 1; }
      for index in "${!CNTOOLS_UTXO_REFS[@]}"; do cntools_coin_add_index "${index}" || return 1; done
    fi
    status=0
    cntools_send_change "${total}" || status=$?
    if (( status == 3 )) && [[ "${CNTOOLS_SEND_MODE}" == exact ]]; then
      cntools_uint_add_into extra "${extra}" "${CNTOOLS_CHANGE_REQUIRED_EXTRA}" || return 1
      continue
    fi
    (( status == 0 )) || { cntools_send_fail "Insufficient ADA for recipient outputs, fees and token change."; return 1; }
    CNTOOLS_SEND_OUTPUTS=(); arguments=()
    for index in "${!CNTOOLS_SEND_ADDRESSES[@]}"; do
      cntools_send_output_into output "${index}" "${CNTOOLS_SEND_AMOUNTS[index]}" || return 1
      cntools_send_minimum_into minimum "${output}" || return 1
      cntools_uint_greater_equal "${CNTOOLS_SEND_AMOUNTS[index]}" "${minimum}" || {
        cntools_send_fail "The amount left to send is below the destination's minimum ADA."; return 1;
      }
      CNTOOLS_SEND_OUTPUTS+=("${output}")
    done
    CNTOOLS_SEND_OUTPUTS+=("${CNTOOLS_CHANGE_OUTPUTS[@]}")
    for output in "${CNTOOLS_SEND_OUTPUTS[@]}"; do
      # Conservative CBOR bound (no reliance on policy sharing); reject oversized
      # bundles before building. Asset strings and quantities were validated.
      value_bytes=12
      local -a parts=()
      read -r -a parts <<< "${output}"
      for asset in "${parts[@]}"; do
        [[ "${asset}" =~ ^[0-9a-f]{56}(\.[0-9a-f]*)?$ ]] || continue
        value_bytes=$((value_bytes + 52 + (${#asset} - 56) / 2))
      done
      (( value_bytes <= max_value )) || { cntools_send_fail "An output's asset bundle exceeds the conservative value-size limit. Split its assets between recipients."; return 1; }
      arguments+=(--tx-out "${output}")
    done
    for index in "${CNTOOLS_COIN_SELECTED_INDICES[@]}"; do arguments+=(--tx-in "${CNTOOLS_UTXO_REFS[index]}"); done
    cntools_transaction_temp_file body send-body || return 1
    cntools_transaction_temp_remove "${body}" || return 1
    cntools_transaction_build_body build-raw "${body}" -- "${arguments[@]}" "${metadata_arguments[@]}" --fee "${CNTOOLS_SEND_FEE}" || return 1
    CNTOOLS_TRANSACTION_TEMP_FILES+=("${body}")
    cntools_transaction_calculate_min_fee_into next_fee "${body}" "${#CNTOOLS_COIN_SELECTED_INDICES[@]}" \
      "${#CNTOOLS_SEND_OUTPUTS[@]}" "${CNTOOLS_FUNDING_PROTOCOL}" || return 1
    witnesses="$(cntools_transaction_plan_witness_count)" || return 1
    body_bytes="$(jq -er '.cborHex | length / 2' "${body}")" || return 1
    (( body_bytes + witnesses * 112 + 32 <= max_size )) || {
      cntools_send_fail "The transaction exceeds the conservative signed-size limit. Send fewer assets/recipients."; return 1;
    }
    if cntools_uint_greater "${next_fee}" "${CNTOOLS_SEND_FEE}"; then
      CNTOOLS_SEND_FEE="${next_fee}"; continue
    fi
    policy="$(cntools_change_policy_json | jq -c --arg mode "${CNTOOLS_SEND_MODE}" \
      '. + {selectionApplied: (if $mode == "exact" then .selection else "all-inputs" end)}')" || return 1
    CNTOOLS_SEND_POLICY="${policy}"
    summary="$(jq -cn --arg wallet "${CNTOOLS_SEND_WALLET}" --arg mode "${CNTOOLS_SEND_MODE}" \
      --arg fee "${CNTOOLS_SEND_FEE}" --arg source "${CNTOOLS_FUNDING_BACKEND}" \
      --argjson transactionPolicy "${policy}" \
      --arg metadata "${CNTOOLS_METADATA_MODE:-none}" \
      --argjson resolutions "$(printf '%s\n' "${CNTOOLS_SEND_RESOLUTIONS[@]}" | jq -sc '[.[] | select(type == "object")]')" \
      '{action:"send",wallet:$wallet,amountMode:$mode,feeLovelace:$fee,dataSource:$source,transactionPolicy:$transactionPolicy,messageMode:$metadata,handleResolutions:$resolutions}')" || return 1
    cntools_transaction_plan_set_summary "${summary}" || return 1
    cntools_transaction_package_create_staged_into package "${body}" || return 1
    if [[ "${CNTOOLS_SEND_TYPE}" == Hardware ]]; then
      # Packaging may normalize the body for the hardware CLI. Fund and size-check
      # that final representation too; never rely only on pre-transform bytes.
      cntools_transaction_calculate_min_fee_into next_fee "${CNTOOLS_TRANSACTION_BODY_FILE}" \
        "${#CNTOOLS_COIN_SELECTED_INDICES[@]}" "${#CNTOOLS_SEND_OUTPUTS[@]}" "${CNTOOLS_FUNDING_PROTOCOL}" || return 1
      body_bytes="$(jq -er '.cborHex | length / 2' "${CNTOOLS_TRANSACTION_BODY_FILE}")" || return 1
      (( body_bytes + witnesses * 112 + 32 <= max_size )) || {
        cntools_send_fail "The hardware-prepared transaction exceeds the signed-size limit."; return 1;
      }
      if cntools_uint_greater "${next_fee}" "${CNTOOLS_SEND_FEE}"; then
        CNTOOLS_SEND_FEE="${next_fee}"; continue
      fi
    fi
    send_package_ref="${package}"
    cntools_transaction_log TRANSACTION "Send built mode=${CNTOOLS_SEND_MODE} inputs=${#CNTOOLS_COIN_SELECTED_INDICES[@]} outputs=${#CNTOOLS_SEND_OUTPUTS[@]} fee=${CNTOOLS_SEND_FEE} policy=${policy}"
    return 0
  done
  cntools_send_fail "Fee and change balancing did not converge within the safety limit."
}
