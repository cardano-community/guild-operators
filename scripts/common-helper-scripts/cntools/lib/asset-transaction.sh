#!/usr/bin/env bash
# Native single-policy mint/burn using shared selection, change and signing.
# shellcheck disable=SC2034,SC2015
CNTOOLS_ASSET_TX_OPERATION=mint CNTOOLS_ASSET_TX_ID='' CNTOOLS_ASSET_TX_QUANTITY=0
CNTOOLS_ASSET_TX_DIRECTORY='' CNTOOLS_ASSET_TX_BACKEND='' CNTOOLS_ASSET_TX_FEE=0
CNTOOLS_ASSET_TX_SKIPPED=0 CNTOOLS_ASSET_TX_OUTPUT_COUNT=0
declare -a CNTOOLS_ASSET_TX_INPUTS=()
declare -A CNTOOLS_ASSET_TX_OUTPUT_ASSETS=()

cntools_asset_tx_fail() { cntools_transaction_set_error "$1"; return 1; }

cntools_asset_tx_quantity_into() {
  local output="$1" entered="$2" normalized=''
  cntools_number_normalize_into normalized "${entered}" && [[ "${normalized}" =~ ^[1-9][0-9]{0,18}$ ]] &&
    cntools_uint_greater_equal 9223372036854775807 "${normalized}" || return 2
  printf -v "${output}" '%s' "${normalized}"
}

cntools_asset_tx_eligible_inventory() {
  local index=0 added=0 asset='' quantity=''
  local -a refs=("${CNTOOLS_UTXO_REFS[@]}") addresses=("${CNTOOLS_UTXO_ADDRESSES[@]}") coins=("${CNTOOLS_UTXO_LOVELACE[@]}")
  local -a lists=("${CNTOOLS_UTXO_ASSET_LISTS[@]}") datums=("${CNTOOLS_UTXO_HAS_DATUM[@]}") scripts=("${CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT[@]}")
  local -A quantities=()
  local -a input_assets=()
  for asset in "${!CNTOOLS_UTXO_ASSET_QUANTITIES[@]}"; do quantities["${asset}"]="${CNTOOLS_UTXO_ASSET_QUANTITIES[${asset}]}"; done
  cntools_utxo_reset; CNTOOLS_ASSET_TX_SKIPPED=0
  CNTOOLS_FUNDING_TOTAL=0; CNTOOLS_FUNDING_ASSET_IDS=(); CNTOOLS_FUNDING_ASSETS=()
  for index in "${!refs[@]}"; do
    if [[ "${datums[index]}" != N || "${scripts[index]}" != N ]]; then CNTOOLS_ASSET_TX_SKIPPED=$((CNTOOLS_ASSET_TX_SKIPPED+1)); continue; fi
    [[ "${addresses[index]}" == "${CNTOOLS_SEND_ADDRESS}" || "${addresses[index]}" == "${CNTOOLS_SEND_PAYMENT}" ]] || return 1
    added="${#CNTOOLS_UTXO_REFS[@]}"
    cntools_utxo_add "${refs[index]}" "${addresses[index]}" "${coins[index]}" || return 1
    IFS=' ' read -r -a input_assets <<< "${lists[index]}"
    for asset in "${input_assets[@]}"; do
      [[ -n "${asset}" ]] || continue
      quantity="${quantities[${index}|${asset}]}"
      cntools_utxo_add_asset "${added}" "${asset}" "${quantity}" || return 1
    done
    cntools_utxo_value_add_index "${added}" CNTOOLS_FUNDING_TOTAL CNTOOLS_FUNDING_ASSET_IDS CNTOOLS_FUNDING_ASSETS || return 1
  done
  (( ${#CNTOOLS_UTXO_REFS[@]} > 0 )) || { cntools_asset_tx_fail 'No eligible UTxOs remain. Datum and reference-script outputs are not consumed.'; return 1; }
}

cntools_asset_tx_validity() {
  local lifetime="$1" policy_end="${CNTOOLS_POLICY_SELECTED_BEFORE}" policy_start="${CNTOOLS_POLICY_SELECTED_AFTER}"
  cntools_transaction_expiry_into CNTOOLS_SEND_EXPIRY "${CNTOOLS_FUNDING_SLOT}" "${lifetime}" || return 1
  [[ -z "${policy_start}" ]] || (( CNTOOLS_FUNDING_SLOT >= policy_start )) || { cntools_asset_tx_fail 'This policy is not valid yet.'; return 1; }
  if [[ -n "${policy_end}" ]]; then
    (( CNTOOLS_FUNDING_SLOT < policy_end )) || { cntools_asset_tx_fail 'This policy has expired; neither minting nor burning is possible.'; return 1; }
    if [[ -z "${CNTOOLS_SEND_EXPIRY}" ]] || (( CNTOOLS_SEND_EXPIRY > policy_end )); then CNTOOLS_SEND_EXPIRY="${policy_end}"; fi
  fi
}

cntools_asset_tx_plan() {
  local key_id='' policy='' summary=''
  cntools_send_plan_signers "${CNTOOLS_ASSET_TX_OPERATION^} asset" "${CNTOOLS_ASSET_TX_OPERATION^} a native asset into/from ${CNTOOLS_SEND_WALLET}." || return 1
  cntools_transaction_plan_set_validity "${CNTOOLS_POLICY_SELECTED_AFTER}" "${CNTOOLS_SEND_EXPIRY}" || return 1
  cntools_transaction_plan_add_signer "${CNTOOLS_ASSET_TX_DIRECTORY##*/} policy" minting \
    "${CNTOOLS_POLICY_SELECTED_VKEY}" "${CNTOOLS_POLICY_SELECTED_SOURCE}" "${CNTOOLS_POLICY_SELECTED_CREDENTIAL}" || return 1
  cntools_transaction_key_id_from_verification_file_into key_id "${CNTOOLS_POLICY_SELECTED_VKEY}" || return 1
  cntools_transaction_plan_add_native_script "${CNTOOLS_ASSET_TX_DIRECTORY##*/} policy" mint "${CNTOOLS_POLICY_SELECTED_SCRIPT}" "${key_id}" || return 1
  policy="$(cntools_change_policy_json)" || return 1
  summary="$(jq -cn --arg op "${CNTOOLS_ASSET_TX_OPERATION}" --arg id "${CNTOOLS_ASSET_TX_ID}" --arg q "${CNTOOLS_ASSET_TX_QUANTITY}" \
    --arg wallet "${CNTOOLS_SEND_WALLET}" --arg fee "${CNTOOLS_ASSET_TX_FEE}" --argjson policy "${policy}" \
    '{action:$op,asset:$id,quantity:$q,wallet:$wallet,feeLovelace:$fee,transactionPolicy:$policy}')" || return 1
  cntools_transaction_plan_set_summary "${summary}"
}

cntools_asset_tx_change() {
  local held="${CNTOOLS_COIN_SELECTED_ASSETS[${CNTOOLS_ASSET_TX_ID}]:-0}" remaining='' asset=''
  if [[ "${CNTOOLS_ASSET_TX_OPERATION}" == mint ]]; then
    cntools_uint_add_into remaining "${held}" "${CNTOOLS_ASSET_TX_QUANTITY}" || return 1
  else
    cntools_uint_subtract_into remaining "${held}" "${CNTOOLS_ASSET_TX_QUANTITY}" || return 1
  fi
  [[ "${held}" != 0 ]] || CNTOOLS_COIN_SELECTED_ASSET_IDS+=("${CNTOOLS_ASSET_TX_ID}")
  CNTOOLS_COIN_SELECTED_ASSETS["${CNTOOLS_ASSET_TX_ID}"]="${remaining}"
  CNTOOLS_ASSET_TX_OUTPUT_ASSETS=()
  local -a residual_ids=()
  for asset in "${CNTOOLS_COIN_SELECTED_ASSET_IDS[@]}"; do
    [[ "${CNTOOLS_COIN_SELECTED_ASSETS[${asset}]}" != 0 ]] || continue
    residual_ids+=("${asset}")
    CNTOOLS_ASSET_TX_OUTPUT_ASSETS["${asset}"]="${CNTOOLS_COIN_SELECTED_ASSETS[${asset}]}"
  done
  CNTOOLS_COIN_SELECTED_ASSET_IDS=("${residual_ids[@]}")
  CNTOOLS_COIN_SELECTED_ASSET_COUNT="${#residual_ids[@]}"
  cntools_change_plan_stake collect 0 "${CNTOOLS_ASSET_TX_FEE}" "${CNTOOLS_FUNDING_PROTOCOL}" "${CNTOOLS_SEND_ADDRESS}"
}

cntools_asset_tx_validate_body() {
  local body="$1" view='' mint_quantity="${CNTOOLS_ASSET_TX_QUANTITY}" rows='' policy='' name='' value='' total=0 expected='' asset='' combined=''
  local -A actual_assets=()
  [[ "${CNTOOLS_ASSET_TX_OPERATION}" != burn ]] || mint_quantity="-${mint_quantity}"
  cntools_transaction_view_into view "${body}" || return 1
  cntools_transaction_log TRANSACTION "Asset body verification view=${view}"
  jq -e --arg address "${CNTOOLS_SEND_ADDRESS}" --arg fee "${CNTOOLS_ASSET_TX_FEE} Lovelace" \
    --arg policy "policy ${CNTOOLS_ASSET_TX_ID%%.*}" --arg name "asset ${CNTOOLS_ASSET_TX_ID#*.}" --arg quantity "${mint_quantity}" '
    .fee==$fee and (.certificates==null or .certificates==[]) and (.withdrawals==null or .withdrawals==[]) and
    (.outputs|length>0 and all(.[];.address==$address and (.datum==null) and (."reference script"==null))) and
    (.mint as $m | ($m|keys)==[$policy] and ($m[$policy]|length)==1 and
      ($m[$policy]|to_entries[0]|(.key|if .=="default asset" then "asset " else split(" (")[0] end)==$name and (.value|tostring)==$quantity))
  ' <<< "${view}" >/dev/null || { cntools_asset_tx_fail 'The built asset transaction does not match its reviewed authority, mint/burn amount or outputs.'; return 1; }
  expected="$(printf '%s\n' "${CNTOOLS_ASSET_TX_INPUTS[@]}" | LC_ALL=C sort)"
  [[ "$(jq -r '.inputs[]' <<< "${view}" | LC_ALL=C sort)" == "${expected}" ]] || return 1
  rows="$(jq -r '.outputs[].amount|to_entries[]|if .key=="lovelace" then ["ada","lovelace",(.value|tostring)] else
    .key as $p | .value|to_entries[]|[$p,(.key|if .=="default asset" then "asset " else split(" (")[0] end),(.value|tostring)] end|@tsv' <<< "${view}")" || return 1
  while IFS=$'\t' read -r policy name value; do
    if [[ "${policy}" == ada ]]; then
      cntools_uint_add_into total "${total}" "${value}" || return 1
    else
      asset="${policy#policy }.${name#asset }"
      [[ "${asset}" =~ ^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$ ]] || return 1
      cntools_uint_add_into combined "${actual_assets[${asset}]:-0}" "${value}" || return 1
      actual_assets["${asset}"]="${combined}"
    fi
  done <<< "${rows}"
  cntools_uint_add_into total "${total}" "${CNTOOLS_ASSET_TX_FEE}" || return 1
  [[ "${total}" == "${CNTOOLS_COIN_SELECTED_LOVELACE}" && "${#actual_assets[@]}" == "${#CNTOOLS_ASSET_TX_OUTPUT_ASSETS[@]}" ]] || return 1
  for asset in "${!CNTOOLS_ASSET_TX_OUTPUT_ASSETS[@]}"; do
    [[ "${actual_assets[${asset}]:-}" == "${CNTOOLS_ASSET_TX_OUTPUT_ASSETS[${asset}]}" ]] || return 1
  done
}

cntools_asset_tx_prepare_balanced_body() {
  # The wrapper retains minimum funding, cumulative shortfall and metadata.
  local body='' output='' input='' required=0 status=0 mint_quantity=''
  local -a arguments=()
  cntools_uint_add_into required "${minimum}" "${CNTOOLS_ASSET_TX_FEE}" && cntools_uint_add_into required "${required}" "${extra}" || return 1
  cntools_coin_select_value "${required}" demands "${CNTOOLS_TX_SELECTION_STRATEGY:-balanced}" || { cntools_asset_tx_fail "${CNTOOLS_COIN_ERROR}"; return 1; }
  CNTOOLS_ASSET_TX_INPUTS=("${CNTOOLS_COIN_SELECTED_REFS[@]}")
  status=0; cntools_asset_tx_change || status=$?
  if ((status == 3)); then cntools_uint_add_into extra "${extra}" "${CNTOOLS_CHANGE_REQUIRED_EXTRA}" || return 1; return 3; fi
  ((status == 0)) || { cntools_asset_tx_fail "${CNTOOLS_CHANGE_ERROR:-Asset change could not be planned.}"; return 1; }
  cntools_asset_tx_plan || return 1
  arguments=(); mint_quantity="${CNTOOLS_ASSET_TX_QUANTITY}"
  [[ "${CNTOOLS_ASSET_TX_OPERATION}" != burn ]] || mint_quantity="-${mint_quantity}"
  for input in "${CNTOOLS_ASSET_TX_INPUTS[@]}"; do arguments+=(--tx-in "${input}"); done
  for output in "${CNTOOLS_CHANGE_OUTPUTS[@]}" "${CNTOOLS_SEND_ADDRESS}+${CNTOOLS_CHANGE_RESIDUAL_LOVELACE}"; do
    cntools_transaction_validate_change_output "${output}" "${CNTOOLS_FUNDING_PROTOCOL}" || return 1
    arguments+=(--tx-out "${output}")
  done
  CNTOOLS_ASSET_TX_OUTPUT_COUNT=$((${#CNTOOLS_CHANGE_OUTPUTS[@]}+1))
  arguments+=(--mint "${mint_quantity} ${CNTOOLS_ASSET_TX_ID%.}" --mint-script-file "${CNTOOLS_POLICY_SELECTED_SCRIPT}" --fee "${CNTOOLS_ASSET_TX_FEE}")
  cntools_transaction_temp_file body asset-body && cntools_transaction_temp_remove "${body}" || return 1
  cntools_transaction_build_body build-raw "${body}" -- "${arguments[@]}" "${metadata_arguments[@]}" || return 1
  CNTOOLS_TRANSACTION_TEMP_FILES+=("${body}")
  CNTOOLS_TRANSACTION_BALANCE_INPUT_COUNT="${#CNTOOLS_ASSET_TX_INPUTS[@]}"
  CNTOOLS_TRANSACTION_BALANCE_OUTPUT_COUNT="${CNTOOLS_ASSET_TX_OUTPUT_COUNT}"
  printf -v "$1" '%s' "${body}"
}

cntools_asset_tx_build_into() {
  local -n asset_package="$1"
  local extra=0 minimum=''
  local -a metadata_arguments=()
  local -A demands=()
  asset_package=''; CNTOOLS_ASSET_TX_FEE=0
  [[ "${CNTOOLS_ASSET_TX_OPERATION}" == mint || "${CNTOOLS_ASSET_TX_OPERATION}" == burn ]] &&
    [[ "${CNTOOLS_ASSET_TX_ID%%.*}" == "${CNTOOLS_POLICY_ID}" ]] &&
    cntools_asset_tx_quantity_into CNTOOLS_ASSET_TX_QUANTITY "${CNTOOLS_ASSET_TX_QUANTITY}" || return 2
  [[ "${CNTOOLS_ASSET_TX_OPERATION}" != burn ]] || demands["${CNTOOLS_ASSET_TX_ID}"]="${CNTOOLS_ASSET_TX_QUANTITY}"
  cntools_metadata_arguments_into metadata_arguments || return 1
  cntools_change_plain_min_into minimum "${CNTOOLS_FUNDING_PROTOCOL}" "${CNTOOLS_SEND_ADDRESS}" || return 1
  cntools_transaction_balance_into "$1" CNTOOLS_ASSET_TX_FEE "${CNTOOLS_FUNDING_PROTOCOL}" \
    cntools_asset_tx_prepare_balanced_body "cntools_asset_tx_validate_body" || return 1
}
cntools_asset_tx_refresh_build_into() {
  local output="$1" lifetime="$2"
  cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" && cntools_asset_tx_eligible_inventory || return 1
  CNTOOLS_ASSET_TX_BACKEND="${CNTOOLS_FUNDING_BACKEND}"
  cntools_asset_tx_validity "${lifetime}" && cntools_asset_tx_build_into "${output}"
}

cntools_asset_tx_recheck() {
  local input=''
  cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" || return 1
  [[ "${CNTOOLS_FUNDING_BACKEND}" == "${CNTOOLS_ASSET_TX_BACKEND}" ]] &&
    { [[ -z "${CNTOOLS_SEND_EXPIRY}" ]] || (( CNTOOLS_FUNDING_SLOT < CNTOOLS_SEND_EXPIRY )); } &&
    { [[ -z "${CNTOOLS_POLICY_SELECTED_AFTER}" ]] || (( CNTOOLS_FUNDING_SLOT >= CNTOOLS_POLICY_SELECTED_AFTER )); } || {
      cntools_asset_tx_fail 'Asset transaction expired or its data source changed. Rebuild and review it.'; return 1;
    }
  for input in "${CNTOOLS_ASSET_TX_INPUTS[@]}"; do
    [[ -n "${CNTOOLS_UTXO_INDEX_BY_REF[${input}]+x}" ]] || { cntools_asset_tx_fail 'A selected input was spent. Rebuild and review the asset transaction.'; return 1; }
  done
}
