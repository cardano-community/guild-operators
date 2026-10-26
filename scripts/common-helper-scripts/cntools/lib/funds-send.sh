#!/usr/bin/env bash
# Exact-value transfers with frozen metadata and verified key/native wallets.
# shellcheck disable=SC2034

CNTOOLS_SEND_WALLET=""
CNTOOLS_SEND_DIRECTORY=""
CNTOOLS_SEND_TYPE=""
CNTOOLS_SEND_ADDRESS=""
CNTOOLS_SEND_CHANGE_ADDRESS=""
CNTOOLS_SEND_PAYMENT=""
CNTOOLS_SEND_VKEY=""
CNTOOLS_SEND_SOURCE=""
CNTOOLS_SEND_CREDENTIAL=""
CNTOOLS_SEND_MODE=exact
CNTOOLS_SEND_FEE=0
CNTOOLS_SEND_EXPIRY=""
CNTOOLS_SEND_POLICY='{}'
# AMOUNTS are what the user entered; PAID are the built outputs (minimum ADA
# raised, Max / Send everything resolved) and are empty until a build.
declare -ag CNTOOLS_SEND_ADDRESSES=() CNTOOLS_SEND_LABELS=() CNTOOLS_SEND_AMOUNTS=() CNTOOLS_SEND_PAID=()
declare -ag CNTOOLS_SEND_HANDLES=() CNTOOLS_SEND_RESOLUTIONS=()
declare -ag CNTOOLS_SEND_OUTPUTS=() CNTOOLS_SEND_CHANGE_IDS=()
# A recipient whose assets exceed one output's value-size limit gets several
# outputs to the same address: PARTS counts them, FIRST_ASSETS holds the first
# output's assets, and EXTRA_OUTPUTS/EXTRA_LOVELACE the others and their
# minimum ADA. Set by cntools_send_demands.
declare -ag CNTOOLS_SEND_PARTS=() CNTOOLS_SEND_FIRST_ASSETS=() CNTOOLS_SEND_EXTRA_LOVELACE=() CNTOOLS_SEND_EXTRA_OUTPUTS=()
declare -Ag CNTOOLS_SEND_ASSETS=() CNTOOLS_SEND_DEMAND=() CNTOOLS_SEND_CHANGE_ASSETS=()

cntools_send_fail() {
  cntools_transaction_set_error "${1:-The funds transfer could not be prepared safely.}"
  return 1
}

cntools_send_prepare_wallet() {
  local field="" source=""
  cntools_payment_prepare_wallet "$@" || return 1
  for field in TYPE ADDRESS PAYMENT VKEY SOURCE CREDENTIAL DIRECTORY WALLET; do
    source="CNTOOLS_PAYMENT_${field}"
    printf -v "CNTOOLS_SEND_${field}" '%s' "${!source}"
  done
  CNTOOLS_SEND_ADDRESSES=(); CNTOOLS_SEND_LABELS=(); CNTOOLS_SEND_AMOUNTS=(); CNTOOLS_SEND_ASSETS=()
  CNTOOLS_SEND_HANDLES=(); CNTOOLS_SEND_RESOLUTIONS=(); CNTOOLS_SEND_PAID=()
  CNTOOLS_SEND_MODE=exact
  CNTOOLS_SEND_CHANGE_ADDRESS="${CNTOOLS_SEND_ADDRESS}"
}

# Send prices no reference scripts, so it never spends their UTxOs.
cntools_send_funding_collect() {
  cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" &&
    cntools_funding_exclude_reference_scripts
}

# Quantity of an asset in a recipient's output; Send everything carries all.
cntools_send_asset_quantity_into() {
  local -n send_quantity_ref="$1"
  if [[ "${CNTOOLS_SEND_MODE}" == sweep ]]; then
    send_quantity_ref="${CNTOOLS_FUNDING_ASSETS[$3]:-0}"
  else
    send_quantity_ref="${CNTOOLS_SEND_ASSETS[$2|$3]:-0}"
  fi
}

cntools_send_output_into() {
  local output_name="${1:-}" index="${2:-}" amount="${3:-}" asset="" value="" quantity=""
  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "${index}" =~ ^[0-9]+$ ]] || return 2
  local -n send_output_ref="${output_name}"
  value="${CNTOOLS_SEND_ADDRESSES[index]}+${amount}"
  if (( ${CNTOOLS_SEND_PARTS[index]:-1} > 1 )); then
    send_output_ref="${value}${CNTOOLS_SEND_FIRST_ASSETS[index]}"
    return 0
  fi
  for asset in "${CNTOOLS_FUNDING_ASSET_IDS[@]}"; do
    cntools_send_asset_quantity_into quantity "${index}" "${asset}"
    [[ "${quantity}" != 0 ]] || continue
    value+=" + ${quantity} ${asset%.}"
  done
  send_output_ref="${value}"
}

# Splits recipient INDEX's assets across outputs to the same address when they
# exceed one output's value-size limit. The first output keeps the recipient's
# ADA amount; each further output carries its own minimum ADA.
cntools_send_split_recipient() {
  local ssr_index="$1" ssr_asset='' ssr_quantity='' ssr_sorted='' ssr_part='' ssr_minimum='' ssr_extra=0 ssr_run=0 ssr_start=0 ssr_i=0
  local -a ssr_ids=() ssr_pieces=() ssr_runs=()
  CNTOOLS_SEND_PARTS[ssr_index]=1; CNTOOLS_SEND_FIRST_ASSETS[ssr_index]=''; CNTOOLS_SEND_EXTRA_LOVELACE[ssr_index]=0
  (( ${#CNTOOLS_FUNDING_ASSET_IDS[@]} > 0 )) || return 0
  ssr_sorted="$(printf '%s\n' "${CNTOOLS_FUNDING_ASSET_IDS[@]}" | LC_ALL=C sort)" || return 1
  mapfile -t ssr_ids <<< "${ssr_sorted}"
  for ssr_asset in "${ssr_ids[@]}"; do
    cntools_send_asset_quantity_into ssr_quantity "${ssr_index}" "${ssr_asset}"
    [[ "${ssr_quantity}" != 0 ]] || continue
    ssr_pieces+=("${ssr_quantity} ${ssr_asset%.}")
  done
  (( ${#ssr_pieces[@]} > 0 )) || return 0
  cntools_transaction_value_runs_into ssr_runs "${CNTOOLS_FUNDING_PROTOCOL}" 0 "${ssr_pieces[@]}" || {
    cntools_send_fail 'The native assets could not be sized for the ledger value-size limit.'; return 1;
  }
  (( ${#ssr_runs[@]} > 1 )) || return 0
  for ssr_run in "${ssr_runs[@]}"; do
    ssr_part=''
    for (( ssr_i = ssr_start; ssr_i < ssr_start + ssr_run; ssr_i++ )); do ssr_part+=" + ${ssr_pieces[ssr_i]}"; done
    if (( ssr_start == 0 )); then
      CNTOOLS_SEND_FIRST_ASSETS[ssr_index]="${ssr_part}"
    else
      cntools_send_minimum_into ssr_minimum "${CNTOOLS_SEND_ADDRESSES[ssr_index]}+0${ssr_part}" || return 1
      CNTOOLS_SEND_EXTRA_OUTPUTS+=("${CNTOOLS_SEND_ADDRESSES[ssr_index]}+${ssr_minimum}${ssr_part}")
      cntools_uint_add_into ssr_extra "${ssr_extra}" "${ssr_minimum}" || return 1
    fi
    ssr_start=$((ssr_start + ssr_run))
  done
  CNTOOLS_SEND_PARTS[ssr_index]="${#ssr_runs[@]}"; CNTOOLS_SEND_EXTRA_LOVELACE[ssr_index]="${ssr_extra}"
  cntools_transaction_log TRANSACTION "recipient=$((ssr_index+1)) assets split into ${#ssr_runs[@]} outputs (value-size limit) extra_lovelace=${ssr_extra}"
}

# ADA the further outputs of split recipients carry.
cntools_send_extra_total_into() {
  local -n set_total="$1"
  local set_amount=''
  set_total=0
  for set_amount in "${CNTOOLS_SEND_EXTRA_LOVELACE[@]}"; do
    cntools_uint_add_into set_total "${set_total}" "${set_amount:-0}" || return 1
  done
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
  CNTOOLS_SEND_DEMAND=(); CNTOOLS_SEND_PAID=("${CNTOOLS_SEND_AMOUNTS[@]}")
  CNTOOLS_SEND_PARTS=(); CNTOOLS_SEND_FIRST_ASSETS=(); CNTOOLS_SEND_EXTRA_LOVELACE=(); CNTOOLS_SEND_EXTRA_OUTPUTS=()
  # Metadata-only actions return every selected asset/coin as normal wallet
  # change. They use exactly the same selection, minimum-ADA and fee engine.
  if [[ "${CNTOOLS_SEND_MODE}" == metadata ]]; then
    (( ${#CNTOOLS_SEND_ADDRESSES[@]} == 0 && ${#CNTOOLS_SEND_AMOUNTS[@]} == 0 && ${#CNTOOLS_SEND_ASSETS[@]} == 0 )) &&
      [[ -n "${CNTOOLS_METADATA_CUSTOM:-}" && -z "${CNTOOLS_METADATA_MESSAGE:-}" ]] || return 2
    return 0
  fi
  case "${CNTOOLS_SEND_MODE}" in exact|max|sweep) ;; *) return 2 ;; esac
  (( ${#CNTOOLS_SEND_ADDRESSES[@]} >= 1 && ${#CNTOOLS_SEND_ADDRESSES[@]} <= 20 )) || return 2
  [[ "${CNTOOLS_SEND_MODE}" == exact || ${#CNTOOLS_SEND_ADDRESSES[@]} == 1 ]] || return 1
  # Send everything takes the whole current inventory without storing it as
  # the recipient's asset choice, so a later edit starts from no assets.
  [[ "${CNTOOLS_SEND_MODE}" != sweep ]] || CNTOOLS_SEND_ASSETS=()
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
      cntools_send_asset_quantity_into quantity "${index}" "${asset}"
      [[ "${quantity}" != 0 ]] || continue
      cntools_uint_add_into sum "${CNTOOLS_SEND_DEMAND[${asset}]:-0}" "${quantity}" || return 1
      cntools_uint_greater_equal "${CNTOOLS_FUNDING_ASSETS[${asset}]}" "${sum}" || {
        cntools_send_fail "Recipients request more than the available quantity of ${asset}."; return 1;
      }
      CNTOOLS_SEND_DEMAND["${asset}"]="${sum}"
    done
    cntools_send_split_recipient "${index}" || return 1
    cntools_send_output_into output "${index}" "${CNTOOLS_SEND_AMOUNTS[index]}" || return 1
    cntools_send_minimum_into minimum "${output}" || return 1
    if [[ "${CNTOOLS_SEND_MODE}" == exact ]] &&
       ! cntools_uint_greater_equal "${CNTOOLS_SEND_AMOUNTS[index]}" "${minimum}"; then
      # The review shows this raise next to the entered amount before signing.
      cntools_transaction_log TRANSACTION "recipient=$((index+1)) minimum ADA adjustment old=${CNTOOLS_SEND_AMOUNTS[index]} new=${minimum}"
      CNTOOLS_SEND_PAID[index]="${minimum}"
    fi
  done
}

cntools_send_plan_signers() {
  local group="" stake_source=""
  cntools_transaction_plan_reset "${1:-Send funds}" \
    "${2:-Transfer from ${CNTOOLS_SEND_WALLET}; rewards and deposits are not withdrawn.}" exact || return 1
  if [[ "${CNTOOLS_SEND_TYPE}" == MultiSig ]]; then
    cntools_multisig_spend_plan
    return $?
  fi
  [[ "${CNTOOLS_SEND_TYPE}" != Hardware ]] || group=send-wallet
  cntools_transaction_plan_add_signer "${CNTOOLS_SEND_WALLET} payment" spending \
    "${CNTOOLS_SEND_VKEY}" "${CNTOOLS_SEND_SOURCE}" "${CNTOOLS_SEND_CREDENTIAL}" "${group}" || return 1
  if [[ "${CNTOOLS_SEND_TYPE}" == Hardware ]]; then
    cntools_transaction_plan_add_change_key "Payment change" "${CNTOOLS_SEND_VKEY}" \
      "${CNTOOLS_SEND_SOURCE}" "${group}" || return 1
    if [[ "${CNTOOLS_SEND_CHANGE_ADDRESS:-${CNTOOLS_SEND_ADDRESS}}" != "${CNTOOLS_SEND_PAYMENT}" ]]; then
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
  local primary="${CNTOOLS_SEND_ADDRESS}"
  local CNTOOLS_SEND_ADDRESS="${CNTOOLS_SEND_CHANGE_ADDRESS:-${CNTOOLS_SEND_ADDRESS}}"
  [[ "${CNTOOLS_SEND_ADDRESS}" == "${primary}" ||
     "${CNTOOLS_SEND_ADDRESS}" == "${CNTOOLS_SEND_PAYMENT}" ]] || return 1
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
  if [[ "${CNTOOLS_SEND_MODE}" == exact || "${CNTOOLS_SEND_MODE}" == metadata ]]; then
    cntools_uint_add_into cost "${cost}" "${minimum}" || return 1
  fi
  if ! cntools_uint_greater_equal "${CNTOOLS_COIN_SELECTED_LOVELACE}" "${cost}"; then
    cntools_uint_subtract_into CNTOOLS_CHANGE_REQUIRED_EXTRA "${cost}" "${CNTOOLS_COIN_SELECTED_LOVELACE}" || return 1
    return 3
  fi
  if [[ "${CNTOOLS_SEND_MODE}" != exact && "${CNTOOLS_SEND_MODE}" != metadata ]]; then
    cntools_uint_subtract_into remaining "${CNTOOLS_COIN_SELECTED_LOVELACE}" "${cost}" || return 1
    CNTOOLS_SEND_PAID[0]="${remaining}"
    # Name a skipped change feature only when it is switched on.
    CNTOOLS_CHANGE_UTXO_STATUS=Disabled CNTOOLS_CHANGE_COLLATERAL_STATUS=Disabled
    if [[ "${CNTOOLS_TX_UTXO_MANAGEMENT:-N}" == Y ]]; then
      CNTOOLS_CHANGE_UTXO_STATUS="Skipped for Max ADA / Send everything"
      [[ "${CNTOOLS_TX_COLLATERAL_MANAGEMENT:-N}" != Y ]] ||
        CNTOOLS_CHANGE_COLLATERAL_STATUS="Skipped for Max ADA / Send everything"
    fi
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

cntools_send_prepare_balanced_body() {
  # The wrapper owns persistent shortfall and metadata/intent context.
  local total=0 required=0 index=0 status=0 body='' minimum='' output='' policy='' summary=''
  local -a arguments=()
  # Further outputs of split recipients are paid like the recipients' own.
  cntools_send_extra_total_into total || return 1
  if [[ "${CNTOOLS_SEND_MODE}" == exact || "${CNTOOLS_SEND_MODE}" == metadata ]]; then
    for index in "${!CNTOOLS_SEND_PAID[@]}"; do
      cntools_uint_add_into total "${total}" "${CNTOOLS_SEND_PAID[index]}" || return 1
    done
    cntools_uint_add_into required "${total}" "${CNTOOLS_SEND_FEE}" || return 1
    cntools_uint_add_into required "${required}" "${extra}" || return 1
    cntools_coin_select_value "${required}" CNTOOLS_SEND_DEMAND "${CNTOOLS_TX_SELECTION_STRATEGY}" || {
      cntools_send_fail "${CNTOOLS_COIN_ERROR}"
      # A lone recipient can take everything after the fee instead.
      if [[ "${CNTOOLS_COIN_ERROR}" == 'Not enough spendable ADA'* && "${CNTOOLS_SEND_MODE}" == exact && ${#CNTOOLS_SEND_ADDRESSES[@]} == 1 ]]; then
        if declare -F cntools_flow_quick >/dev/null && cntools_flow_quick; then
          cntools_send_fail "${CNTOOLS_COIN_ERROR} Lower the amount, or enter max to send all ADA after the fee."
        else
          cntools_send_fail "${CNTOOLS_COIN_ERROR} Lower the amount, or choose Max ADA to send all ADA after the fee."
        fi
      fi
      return 1
    }
  else
    cntools_coin_reset
    (( ${#CNTOOLS_UTXO_REFS[@]} <= 100 )) || {
      cntools_send_fail "Max ADA and Send everything spend every UTxO, and ${CNTOOLS_SEND_WALLET} has $(cntools_number_format "${#CNTOOLS_UTXO_REFS[@]}"), more than the safe limit of 100. Combine them first with Funds → Collect UTxOs."
      return 1
    }
    for index in "${!CNTOOLS_UTXO_REFS[@]}"; do cntools_coin_add_index "${index}" || return 1; done
  fi
  status=0
  cntools_send_change "${total}" || status=$?
  if (( status == 3 )) && [[ "${CNTOOLS_SEND_MODE}" == exact || "${CNTOOLS_SEND_MODE}" == metadata ]]; then
    cntools_uint_add_into extra "${extra}" "${CNTOOLS_CHANGE_REQUIRED_EXTRA}" || return 1
    return 3
  fi
  if (( status == 3 )); then
    cntools_send_fail "Not enough ADA: $(cntools_number_format_lovelace "${CNTOOLS_CHANGE_REQUIRED_EXTRA}") more is needed for the fee and the minimum ADA of the outputs and change."
    return 1
  fi
  (( status == 0 )) || { cntools_send_fail "${CNTOOLS_CHANGE_ERROR:-The change for this transfer could not be planned.}"; return 1; }
  CNTOOLS_SEND_OUTPUTS=(); arguments=()
  for index in "${!CNTOOLS_SEND_ADDRESSES[@]}"; do
    cntools_send_output_into output "${index}" "${CNTOOLS_SEND_PAID[index]}" || return 1
    cntools_send_minimum_into minimum "${output}" || return 1
    cntools_uint_greater_equal "${CNTOOLS_SEND_PAID[index]}" "${minimum}" || {
      cntools_send_fail "The amount left to send is below the destination's minimum ADA."; return 1;
    }
    CNTOOLS_SEND_OUTPUTS+=("${output}")
  done
  CNTOOLS_SEND_OUTPUTS+=("${CNTOOLS_SEND_EXTRA_OUTPUTS[@]}" "${CNTOOLS_CHANGE_OUTPUTS[@]}")
  for output in "${CNTOOLS_SEND_OUTPUTS[@]}"; do
    cntools_transaction_validate_value_size "${output}" "${CNTOOLS_FUNDING_PROTOCOL}" || return 1
    arguments+=(--tx-out "${output}")
  done
  for index in "${CNTOOLS_COIN_SELECTED_INDICES[@]}"; do
    arguments+=(--tx-in "${CNTOOLS_UTXO_REFS[index]}")
    [[ "${CNTOOLS_SEND_TYPE}" != MultiSig ]] || cntools_multisig_input_arguments arguments || return 1
  done
  cntools_transaction_temp_file body send-body || return 1
  cntools_transaction_temp_remove "${body}" || return 1
  cntools_transaction_build_body build-raw "${body}" -- "${arguments[@]}" "${metadata_arguments[@]}" --fee "${CNTOOLS_SEND_FEE}" || return 1
  CNTOOLS_TRANSACTION_TEMP_FILES+=("${body}")
  policy="$(cntools_change_policy_json | jq -c --arg mode "${CNTOOLS_SEND_MODE}" \
    '. + {selectionApplied: (if $mode == "exact" or $mode == "metadata" then .selection else "all-inputs" end)}')" || return 1
  CNTOOLS_SEND_POLICY="${policy}"
  summary="$(jq -cn --arg wallet "${CNTOOLS_SEND_WALLET}" --arg mode "${CNTOOLS_SEND_MODE}" \
    --arg fee "${CNTOOLS_SEND_FEE}" --arg source "${CNTOOLS_FUNDING_BACKEND}" \
    --argjson transactionPolicy "${policy}" --argjson context "${context}" \
    --arg metadata "${CNTOOLS_METADATA_MODE:-none}" \
    --argjson resolutions "$(printf '%s\n' "${CNTOOLS_SEND_RESOLUTIONS[@]}" | jq -sc '[.[] | select(type == "object")]')" \
    '$context + {wallet:$wallet,amountMode:$mode,feeLovelace:$fee,dataSource:$source,transactionPolicy:$transactionPolicy,messageMode:$metadata,handleResolutions:$resolutions}')" || return 1
  cntools_transaction_plan_set_summary "${summary}" || return 1
  CNTOOLS_TRANSACTION_BALANCE_INPUT_COUNT="${#CNTOOLS_COIN_SELECTED_INDICES[@]}"
  CNTOOLS_TRANSACTION_BALANCE_OUTPUT_COUNT="${#CNTOOLS_SEND_OUTPUTS[@]}"
  printf -v "$1" '%s' "${body}"
}

cntools_send_build_into() {
  local output_name="${1:-}" extra=0
  local intent="${2:-Send funds}" description="${3:-Transfer from ${CNTOOLS_SEND_WALLET}; rewards and deposits are not withdrawn.}"
  local context="${4:-}"; [[ -n "${context}" ]] || context='{"action":"send"}'
  jq -e 'type == "object"' <<< "${context}" >/dev/null || return 2
  local -a metadata_arguments=()
  local -n send_package_ref="${output_name}"
  send_package_ref=""
  if declare -F cntools_metadata_arguments_into >/dev/null; then
    cntools_metadata_arguments_into metadata_arguments || {
      cntools_send_fail "${CNTOOLS_METADATA_ERROR:-Could not prepare transaction metadata.}"; return 1;
    }
  fi
  cntools_send_demands || return 1
  cntools_send_plan_signers "${intent}" "${description}" || return 1
  CNTOOLS_SEND_FEE=0
  cntools_transaction_balance_into "${output_name}" CNTOOLS_SEND_FEE "${CNTOOLS_FUNDING_PROTOCOL}" \
    cntools_send_prepare_balanced_body "" || return 1
}
