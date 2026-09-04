#!/usr/bin/env bash
# Native-token and ADA-only change planning. Functions only.
# Loaded after number.sh, utxo.sh, coin-selection.sh, and transaction-build.sh.
# shellcheck disable=SC2034

CNTOOLS_CHANGE_ERROR=""
CNTOOLS_CHANGE_TOKEN_STATUS=""
CNTOOLS_CHANGE_UTXO_STATUS=""
CNTOOLS_CHANGE_COLLATERAL_STATUS=""
CNTOOLS_CHANGE_REQUIRED_EXTRA="0"
CNTOOLS_CHANGE_RESIDUAL_LOVELACE="0"
CNTOOLS_CHANGE_EFFECTIVE_MIN_LOVELACE="0"
CNTOOLS_CHANGE_TOKEN_MIN_TOTAL="0"
CNTOOLS_CHANGE_EXISTING_LIQUID=0
CNTOOLS_CHANGE_EXISTING_COLLATERAL=0
declare -ag CNTOOLS_CHANGE_OUTPUTS=()
declare -ag CNTOOLS_CHANGE_OUTPUT_TYPES=()
declare -ag CNTOOLS_CHANGE_OUTPUT_LOVELACE=()
declare -ag CNTOOLS_CHANGE_OUTPUT_ASSET_COUNTS=()

cntools_change_reset() {
  CNTOOLS_CHANGE_ERROR=""
  CNTOOLS_CHANGE_TOKEN_STATUS=""
  CNTOOLS_CHANGE_UTXO_STATUS=""
  CNTOOLS_CHANGE_COLLATERAL_STATUS=""
  CNTOOLS_CHANGE_REQUIRED_EXTRA="0"
  CNTOOLS_CHANGE_RESIDUAL_LOVELACE="0"
  CNTOOLS_CHANGE_EFFECTIVE_MIN_LOVELACE="0"
  CNTOOLS_CHANGE_TOKEN_MIN_TOTAL="0"
  CNTOOLS_CHANGE_EXISTING_LIQUID=0
  CNTOOLS_CHANGE_EXISTING_COLLATERAL=0
  CNTOOLS_CHANGE_OUTPUTS=()
  CNTOOLS_CHANGE_OUTPUT_TYPES=()
  CNTOOLS_CHANGE_OUTPUT_LOVELACE=()
  CNTOOLS_CHANGE_OUTPUT_ASSET_COUNTS=()
}

cntools_change_fail() {
  CNTOOLS_CHANGE_ERROR="${1:-Change planning failed.}"
  return 1
}

cntools_change_output_add() {
  local type="${1:-}"
  local output="${2:-}"
  local lovelace="${3:-}"
  local asset_count="${4:-0}"

  [[ -n "${type}" && -n "${output}" &&
     "${output}" != *$'\n'* && "${output}" != *$'\r'* &&
     "${asset_count}" =~ ^[0-9]+$ ]] || return 2
  cntools_uint_normalize_into lovelace "${lovelace}" || return 2
  CNTOOLS_CHANGE_OUTPUT_TYPES+=("${type}")
  CNTOOLS_CHANGE_OUTPUTS+=("${output}")
  CNTOOLS_CHANGE_OUTPUT_LOVELACE+=("${lovelace}")
  CNTOOLS_CHANGE_OUTPUT_ASSET_COUNTS+=("${asset_count}")
}

cntools_change_plain_min_into() {
  local _cntools_output_name="${1:-}"
  local protocol_file="${2:-}"
  local address="${3:-}"
  local protocol_min=""
  local configured="${CNTOOLS_TX_UTXO_MIN_LOVELACE:-2000000}"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  cntools_transaction_calculate_min_utxo_into \
    protocol_min "${protocol_file}" "${address}+0" || return 1
  if cntools_uint_greater "${protocol_min}" "${configured}"; then
    _cntools_output_ref="${protocol_min}"
  else
    _cntools_output_ref="${configured}"
  fi
}

cntools_change_token_value_into() {
  local _cntools_output_name="${1:-}"
  local address="${2:-}"
  local lovelace="${3:-0}"
  local start="${4:-0}"
  local count="${5:-0}"
  local position=0
  local asset_id=""
  local cli_asset_id=""
  local _cntools_value=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${start}" =~ ^[0-9]+$ && "${count}" =~ ^[0-9]+$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  cntools_uint_normalize_into lovelace "${lovelace}" || return 2
  _cntools_value="${address}+${lovelace}"
  for (( position = start; position < start + count; position++ )); do
    asset_id="${CNTOOLS_COIN_SELECTED_ASSET_IDS[position]}"
    cli_asset_id="${asset_id}"
    [[ "${cli_asset_id}" != *. ]] || cli_asset_id="${cli_asset_id%.}"
    _cntools_value+=" + ${CNTOOLS_COIN_SELECTED_ASSETS[${asset_id}]} ${cli_asset_id}"
  done
  _cntools_output_ref="${_cntools_value}"
}

cntools_change_plan_tokens() {
  local protocol_file="${1:-}"
  local address="${2:-}"
  local asset_total="${#CNTOOLS_COIN_SELECTED_ASSET_IDS[@]}"
  local maximum="${asset_total}"
  local start=0
  local count=0
  local value=""
  local minimum=""
  local output=""
  local total="0"
  local next=""
  local sorted=""
  local safety_split="N"
  local -a sorted_assets=()

  (( asset_total > 0 )) || {
    if [[ "${CNTOOLS_TX_TOKEN_FRAGMENTATION:-N}" == "Y" ]]; then
      CNTOOLS_CHANGE_TOKEN_STATUS="Enabled · not needed (no token change)"
    else
      CNTOOLS_CHANGE_TOKEN_STATUS="Disabled · no token change"
    fi
    return 0
  }
  sorted="$(printf '%s\n' "${CNTOOLS_COIN_SELECTED_ASSET_IDS[@]}" |
    LC_ALL=C sort)" || return 1
  mapfile -t sorted_assets <<< "${sorted}"
  CNTOOLS_COIN_SELECTED_ASSET_IDS=("${sorted_assets[@]}")
  if [[ "${CNTOOLS_TX_TOKEN_FRAGMENTATION:-N}" == "Y" ]]; then
    maximum="${CNTOOLS_TX_TOKEN_MAX_ASSETS:-20}"
  fi
  (( maximum >= 1 )) || return 2
  while (( start < asset_total )); do
    count="${maximum}"
    (( start + count <= asset_total )) || count=$((asset_total - start))
    cntools_change_token_value_into value "${address}" 0 "${start}" "${count}" ||
      return 1
    while ! cntools_transaction_calculate_min_utxo_into \
        minimum "${protocol_file}" "${value}"; do
      if (( count <= 1 )); then
        cntools_change_fail \
          "Cardano CLI could not calculate minimum ADA for a token-change output."
        return 1
      fi
      count=$(((count + 1) / 2))
      safety_split="Y"
      cntools_change_token_value_into value \
        "${address}" 0 "${start}" "${count}" || return 1
    done
    cntools_change_token_value_into output \
      "${address}" "${minimum}" "${start}" "${count}" || return 1
    cntools_change_output_add "Token change" \
      "${output}" "${minimum}" "${count}" || return 1
    cntools_uint_add_into next "${total}" "${minimum}" || return 1
    total="${next}"
    start=$((start + count))
  done
  [[ "${safety_split}" != "Y" ]] || cntools_transaction_clear_error
  if [[ "${CNTOOLS_TX_TOKEN_FRAGMENTATION:-N}" != "Y" &&
        "${safety_split}" == "Y" ]]; then
    CNTOOLS_CHANGE_TOKEN_STATUS="Disabled · protocol safety split into ${#CNTOOLS_CHANGE_OUTPUTS[@]} outputs"
  elif [[ "${CNTOOLS_TX_TOKEN_FRAGMENTATION:-N}" != "Y" ]]; then
    CNTOOLS_CHANGE_TOKEN_STATUS="Disabled · one token-change output"
  elif (( ${#CNTOOLS_CHANGE_OUTPUTS[@]} > 1 )); then
    CNTOOLS_CHANGE_TOKEN_STATUS="Applied · ${#CNTOOLS_CHANGE_OUTPUTS[@]} outputs · maximum ${maximum} assets"
  else
    CNTOOLS_CHANGE_TOKEN_STATUS="Enabled · not needed (${asset_total} assets)"
  fi
  CNTOOLS_CHANGE_TOKEN_MIN_TOTAL="${total}"
}

cntools_change_existing_inventory() {
  local index=0
  local selected_collateral=""
  local target="${CNTOOLS_TX_COLLATERAL_LOVELACE:-5000000}"
  local upper=""

  CNTOOLS_CHANGE_EXISTING_LIQUID=0
  CNTOOLS_CHANGE_EXISTING_COLLATERAL=0
  cntools_uint_multiply_small_into upper "${target}" 2 || return 1
  for index in "${!CNTOOLS_UTXO_REFS[@]}"; do
    [[ -z "${CNTOOLS_COIN_SELECTED_MAP[${index}]+x}" ]] || continue
    (( CNTOOLS_UTXO_ASSET_COUNTS[index] == 0 )) || continue
    [[ "${CNTOOLS_UTXO_HAS_DATUM[index]}" == "N" &&
       "${CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT[index]}" == "N" ]] || continue
    cntools_uint_greater_equal "${CNTOOLS_UTXO_LOVELACE[index]}" \
      "${CNTOOLS_CHANGE_EFFECTIVE_MIN_LOVELACE}" || continue
    if [[ "${CNTOOLS_TX_COLLATERAL_MANAGEMENT:-Y}" == "Y" &&
       -z "${selected_collateral}" ]] &&
       cntools_uint_greater_equal "${CNTOOLS_UTXO_LOVELACE[index]}" "${target}" &&
       cntools_uint_greater_equal "${upper}" "${CNTOOLS_UTXO_LOVELACE[index]}"; then
      selected_collateral="${index}"
      CNTOOLS_CHANGE_EXISTING_COLLATERAL=1
      continue
    fi
    CNTOOLS_CHANGE_EXISTING_LIQUID=$((CNTOOLS_CHANGE_EXISTING_LIQUID + 1))
  done
}

cntools_change_plan_ada() {
  local address="${1:-}"
  local available="${2:-}"
  local base=""
  local remaining=""
  local amount=""
  local percentage=""
  local created=0
  local planned_residual=0
  local deficit=0
  local collateral_deficit=0
  local -a percentages=()

  cntools_uint_normalize_into available "${available}" || return 2
  cntools_change_existing_inventory || return 1
  if [[ "${CNTOOLS_TX_UTXO_MANAGEMENT:-N}" != "Y" ]]; then
    CNTOOLS_CHANGE_UTXO_STATUS="Disabled"
    CNTOOLS_CHANGE_COLLATERAL_STATUS="Disabled with ADA-only management"
    CNTOOLS_CHANGE_RESIDUAL_LOVELACE="${available}"
    return 0
  fi

  collateral_deficit=$((
    CNTOOLS_TX_COLLATERAL_TARGET_COUNT - CNTOOLS_CHANGE_EXISTING_COLLATERAL
  ))
  (( collateral_deficit > 0 )) || collateral_deficit=0
  if [[ "${CNTOOLS_TX_COLLATERAL_MANAGEMENT:-Y}" == "Y" &&
        ${collateral_deficit} -gt 0 ]]; then
    if cntools_uint_greater_equal "${available}" \
        "${CNTOOLS_TX_COLLATERAL_LOVELACE}"; then
      cntools_uint_subtract_into remaining \
        "${available}" "${CNTOOLS_TX_COLLATERAL_LOVELACE}" || return 1
      if cntools_uint_greater_equal "${remaining}" \
          "${CNTOOLS_CHANGE_EFFECTIVE_MIN_LOVELACE}"; then
        cntools_change_output_add "Collateral candidate" \
          "${address}+${CNTOOLS_TX_COLLATERAL_LOVELACE}" \
          "${CNTOOLS_TX_COLLATERAL_LOVELACE}" 0 || return 1
        available="${remaining}"
        CNTOOLS_CHANGE_COLLATERAL_STATUS="Applied · 5 ADA candidate created"
      else
        CNTOOLS_CHANGE_COLLATERAL_STATUS="Enabled · insufficient change"
      fi
    else
      CNTOOLS_CHANGE_COLLATERAL_STATUS="Enabled · insufficient change"
    fi
  elif [[ "${CNTOOLS_TX_COLLATERAL_MANAGEMENT:-Y}" == "Y" ]]; then
    CNTOOLS_CHANGE_COLLATERAL_STATUS="Enabled · existing candidate preserved"
  else
    CNTOOLS_CHANGE_COLLATERAL_STATUS="Disabled"
  fi

  base="${available}"
  if cntools_uint_greater_equal "${available}" \
      "${CNTOOLS_CHANGE_EFFECTIVE_MIN_LOVELACE}"; then
    planned_residual=1
  fi
  deficit=$((
    CNTOOLS_TX_UTXO_TARGET_COUNT - CNTOOLS_CHANGE_EXISTING_LIQUID - planned_residual
  ))
  (( deficit > 0 )) || deficit=0
  if (( deficit == 0 )); then
    CNTOOLS_CHANGE_UTXO_STATUS="Enabled · target already satisfied"
    CNTOOLS_CHANGE_RESIDUAL_LOVELACE="${available}"
    return 0
  fi
  IFS=',' read -r -a percentages <<< "${CNTOOLS_TX_UTXO_PERCENTAGES}"
  for percentage in "${percentages[@]}"; do
    (( created < deficit &&
       created < CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS )) || break
    cntools_uint_percent_into amount "${base}" "${percentage}" || return 1
    cntools_uint_greater_equal "${amount}" \
      "${CNTOOLS_CHANGE_EFFECTIVE_MIN_LOVELACE}" || continue
    cntools_uint_greater_equal "${available}" "${amount}" || continue
    cntools_uint_subtract_into remaining "${available}" "${amount}" || return 1
    cntools_uint_greater_equal "${remaining}" \
      "${CNTOOLS_CHANGE_EFFECTIVE_MIN_LOVELACE}" || continue
    cntools_change_output_add "ADA liquidity ${percentage}%" \
      "${address}+${amount}" "${amount}" 0 || return 1
    available="${remaining}"
    created=$((created + 1))
  done
  CNTOOLS_CHANGE_RESIDUAL_LOVELACE="${available}"
  if (( created > 0 )); then
    if (( created == 1 )); then
      CNTOOLS_CHANGE_UTXO_STATUS="Applied · 1 percentage output"
    else
      CNTOOLS_CHANGE_UTXO_STATUS="Applied · ${created} percentage outputs"
    fi
  else
    CNTOOLS_CHANGE_UTXO_STATUS="Enabled · insufficient useful change"
  fi
}

cntools_change_plan_stake() {
  local operation="${1:-}"
  local deposit="${2:-}"
  local fee_reserve="${3:-}"
  local protocol_file="${4:-}"
  local address="${5:-}"
  local available="${CNTOOLS_COIN_SELECTED_LOVELACE:-0}"
  local after_ledger=""
  local mandatory=""
  local balance_cost=""
  local shortfall=""
  local token_min="0"
  local residual_min="0"

  cntools_change_reset
  cntools_change_plain_min_into \
    CNTOOLS_CHANGE_EFFECTIVE_MIN_LOVELACE \
    "${protocol_file}" "${address}" || {
      cntools_change_fail "Cardano CLI could not calculate the current minimum ADA output."
      return 1
    }
  cntools_change_plan_tokens "${protocol_file}" "${address}" || return 1
  token_min="${CNTOOLS_CHANGE_TOKEN_MIN_TOTAL:-0}"
  if [[ "${token_min}" != "0" ||
        "${CNTOOLS_TX_UTXO_MANAGEMENT:-N}" == "Y" ]]; then
    residual_min="${CNTOOLS_CHANGE_EFFECTIVE_MIN_LOVELACE}"
  fi
  case "${operation}" in
    register)
      cntools_uint_add_into balance_cost \
        "${deposit}" "${fee_reserve}" || return 1
      cntools_uint_add_into balance_cost \
        "${balance_cost}" "${token_min}" || return 1
      cntools_uint_add_into mandatory \
        "${balance_cost}" "${residual_min}" ||
        return 1
      if ! cntools_uint_greater_equal "${available}" "${mandatory}"; then
        cntools_uint_subtract_into shortfall "${mandatory}" "${available}" ||
          return 1
        CNTOOLS_CHANGE_REQUIRED_EXTRA="${shortfall}"
        CNTOOLS_CHANGE_ERROR="Selected inputs need ${shortfall} more lovelace for fees and valid token change."
        return 3
      fi
      cntools_uint_subtract_into after_ledger \
        "${available}" "${balance_cost}" ||
        return 1
      ;;
    deregister)
      cntools_uint_add_into after_ledger "${available}" "${deposit}" || return 1
      cntools_uint_add_into balance_cost "${fee_reserve}" "${token_min}" ||
        return 1
      cntools_uint_add_into mandatory \
        "${balance_cost}" "${residual_min}" ||
        return 1
      if ! cntools_uint_greater_equal "${after_ledger}" "${mandatory}"; then
        cntools_uint_subtract_into shortfall "${mandatory}" "${after_ledger}" ||
          return 1
        CNTOOLS_CHANGE_REQUIRED_EXTRA="${shortfall}"
        CNTOOLS_CHANGE_ERROR="Selected inputs need ${shortfall} more lovelace for fees and valid token change."
        return 3
      fi
      cntools_uint_subtract_into after_ledger \
        "${after_ledger}" "${balance_cost}" || return 1
      ;;
    *) return 2 ;;
  esac
  cntools_change_plan_ada "${address}" "${after_ledger}" || return 1
}

cntools_change_policy_json() {
  local fragmentation=false
  local management=false
  local collateral=false

  [[ "${CNTOOLS_TX_TOKEN_FRAGMENTATION:-N}" != "Y" ]] || fragmentation=true
  [[ "${CNTOOLS_TX_UTXO_MANAGEMENT:-N}" != "Y" ]] || management=true
  if [[ "${CNTOOLS_TX_UTXO_MANAGEMENT:-N}" == "Y" &&
        "${CNTOOLS_TX_COLLATERAL_MANAGEMENT:-N}" == "Y" ]]; then
    collateral=true
  fi
  jq -cn \
    --arg strategy "${CNTOOLS_TX_SELECTION_STRATEGY:-balanced}" \
    --argjson fragmentation "${fragmentation}" \
    --argjson maxAssets "${CNTOOLS_TX_TOKEN_MAX_ASSETS:-20}" \
    --argjson management "${management}" \
    --argjson target "${CNTOOLS_TX_UTXO_TARGET_COUNT:-4}" \
    --arg percentages "${CNTOOLS_TX_UTXO_PERCENTAGES:-10,20,30}" \
    --argjson collateral "${collateral}" \
    --arg tokenResult "${CNTOOLS_CHANGE_TOKEN_STATUS}" \
    --arg utxoResult "${CNTOOLS_CHANGE_UTXO_STATUS}" \
    --arg collateralResult "${CNTOOLS_CHANGE_COLLATERAL_STATUS}" '
      {
        selection: $strategy,
        tokenFragmentation: {
          enabled: $fragmentation,
          maxAssetsPerOutput: $maxAssets,
          result: $tokenResult
        },
        utxoManagement: {
          enabled: $management,
          targetCount: $target,
          percentages: ($percentages | split(",") | map(tonumber)),
          result: $utxoResult,
          collateralEnabled: $collateral,
          collateralResult: $collateralResult
        }
      }
    '
}
