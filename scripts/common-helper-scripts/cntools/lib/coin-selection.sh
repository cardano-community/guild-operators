#!/usr/bin/env bash
# Deterministic, backend-neutral coin selection. Functions only.
# Loaded after number.sh and utxo.sh.
# shellcheck disable=SC2034

CNTOOLS_COIN_ERROR=""
CNTOOLS_COIN_REQUIRED_LOVELACE="0"
CNTOOLS_COIN_SELECTED_LOVELACE="0"
CNTOOLS_COIN_SELECTED_ASSET_COUNT=0
CNTOOLS_COIN_PROTECTED_COLLATERAL_INDEX=""
CNTOOLS_COIN_SELECTION_REASON=""
# Y when every usable UTxO was selected and the total was still short.
CNTOOLS_COIN_SHORT=N
declare -ag CNTOOLS_COIN_SELECTED_INDICES=()
declare -ag CNTOOLS_COIN_SELECTED_REFS=()
declare -ag CNTOOLS_COIN_SELECTED_ASSET_IDS=()
declare -Ag CNTOOLS_COIN_SELECTED_MAP=()
declare -Ag CNTOOLS_COIN_SELECTED_ASSETS=()

cntools_coin_reset() {
  CNTOOLS_COIN_ERROR=""
  CNTOOLS_COIN_REQUIRED_LOVELACE="0"
  CNTOOLS_COIN_SELECTED_LOVELACE="0"
  CNTOOLS_COIN_SELECTED_ASSET_COUNT=0
  CNTOOLS_COIN_PROTECTED_COLLATERAL_INDEX=""
  CNTOOLS_COIN_SELECTION_REASON=""
  CNTOOLS_COIN_SHORT=N
  CNTOOLS_COIN_SELECTED_INDICES=()
  CNTOOLS_COIN_SELECTED_REFS=()
  CNTOOLS_COIN_SELECTED_ASSET_IDS=()
  CNTOOLS_COIN_SELECTED_MAP=()
  CNTOOLS_COIN_SELECTED_ASSETS=()
}

cntools_coin_fail() {
  CNTOOLS_COIN_ERROR="${1:-Coin selection failed.}"
  return 1
}

cntools_coin_fail_input_limit() {
  cntools_coin_fail "This needs more than 100 UTxOs, the safe input limit. Combine small UTxOs first with Funds → Collect UTxOs."
}

# Every usable UTxO is selected and still short: say how much is needed.
cntools_coin_fail_short() {
  CNTOOLS_COIN_SHORT=Y
  cntools_coin_fail "Not enough spendable ADA: this needs at least $(cntools_number_format_lovelace "$1"), and the wallet's usable UTxOs hold $(cntools_number_format_lovelace "${CNTOOLS_COIN_SELECTED_LOVELACE}")."
}

cntools_coin_initial_fee_into() {
  local _cntools_output_name="${1:-}"
  local protocol_file="${2:-}"
  local record=""
  local fixed=""
  local per_byte=""
  local max_size=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     -f "${protocol_file}" && ! -L "${protocol_file}" ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  record="$(jq -er '
    [
      (.txFeeFixed // .minFeeB),
      (.txFeePerByte // .minFeeA),
      .maxTxSize
    ] as $fee |
    if ($fee | all(.[]; type == "number" and floor == . and . >= 0)) and
       $fee[0] <= 1000000000 and
       $fee[1] <= 1000000 and
       $fee[2] <= 100000
    then $fee | map(tostring) | join("\u001f") else empty end
  ' "${protocol_file}")" || return 1
  IFS=$'\037' read -r fixed per_byte max_size <<< "${record}"
  # The fixed fee is a protocol lower bound, not a maximum-size reserve. Actual
  # body/witness pricing expands input selection during balancing if necessary.
  _cntools_output_ref="${fixed}"
}

cntools_coin_required_for_stake_into() {
  local _cntools_output_name="${1:-}"
  local operation="${2:-}"
  local deposit="${3:-}"
  local fee_reserve="${4:-}"
  local _cntools_required=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  cntools_uint_normalize_into deposit "${deposit}" || return 2
  cntools_uint_normalize_into fee_reserve "${fee_reserve}" || return 2
  case "${operation}" in
    register|delegate|vote-delegate|drep-register|drep-update|gov-vote|pool-register|pool-modify|pool-retire)
      cntools_uint_add_into _cntools_required \
        "${deposit}" "${fee_reserve}" || return 1
      ;;
    deregister|withdraw|drep-retire)
      # The credit is the returned deposit or the full reward withdrawal.
      if cntools_uint_greater "${fee_reserve}" "${deposit}"; then
        cntools_uint_subtract_into _cntools_required \
          "${fee_reserve}" "${deposit}" || return 1
      else
        _cntools_required=1
      fi
      ;;
    *) return 2 ;;
  esac
  _cntools_output_ref="${_cntools_required}"
}

cntools_coin_find_collateral_candidate() {
  local index=0
  local amount=""
  local best=""
  local comparison=0
  local target="${CNTOOLS_TX_COLLATERAL_LOVELACE:-5000000}"
  local upper=""

  CNTOOLS_COIN_PROTECTED_COLLATERAL_INDEX=""
  [[ "${CNTOOLS_TX_UTXO_MANAGEMENT:-N}" == "Y" &&
     "${CNTOOLS_TX_COLLATERAL_MANAGEMENT:-Y}" == "Y" ]] || return 0
  cntools_uint_multiply_small_into upper "${target}" 2 || return 1
  for index in "${!CNTOOLS_UTXO_REFS[@]}"; do
    (( CNTOOLS_UTXO_ASSET_COUNTS[index] == 0 )) || continue
    [[ "${CNTOOLS_UTXO_HAS_DATUM[index]}" == "N" &&
       "${CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT[index]}" == "N" ]] || continue
    amount="${CNTOOLS_UTXO_LOVELACE[index]}"
    cntools_uint_greater_equal "${amount}" "${target}" || continue
    cntools_uint_greater_equal "${upper}" "${amount}" || continue
    if [[ -z "${best}" ]]; then
      best="${index}"
      continue
    fi
    cntools_uint_compare_into comparison \
      "${amount}" "${CNTOOLS_UTXO_LOVELACE[best]}" || return 1
    if (( comparison < 0 )) ||
       { (( comparison == 0 )) &&
         [[ "${CNTOOLS_UTXO_REFS[index]}" < "${CNTOOLS_UTXO_REFS[best]}" ]]; }; then
      best="${index}"
    fi
  done
  CNTOOLS_COIN_PROTECTED_COLLATERAL_INDEX="${best}"
}

cntools_coin_candidate_class_into() {
  local _cntools_output_name="${1:-}"
  local index="${2:-}"
  local complex=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${index}" =~ ^[0-9]+$ &&
     -n "${CNTOOLS_UTXO_REFS[index]+x}" ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  [[ "${CNTOOLS_UTXO_HAS_DATUM[index]}" == "N" &&
     "${CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT[index]}" == "N" ]] || complex=1
  if (( CNTOOLS_UTXO_ASSET_COUNTS[index] == 0 )); then
    if [[ "${index}" == "${CNTOOLS_COIN_PROTECTED_COLLATERAL_INDEX}" ]]; then
      _cntools_output_ref=2
    elif (( complex == 0 )); then
      _cntools_output_ref=0
    else
      _cntools_output_ref=1
    fi
  elif (( complex == 0 )); then
    _cntools_output_ref=3
  else
    _cntools_output_ref=4
  fi
}

cntools_coin_balanced_class_limit_into() {
  local _cntools_output_name="${1:-}"
  local required="${2:-}"
  local limit=0
  local index=0
  local class=0
  local total="0"
  local next=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  for limit in 0 1 2 3 4; do
    total=0
    for index in "${!CNTOOLS_UTXO_REFS[@]}"; do
      cntools_coin_candidate_class_into class "${index}" || return 1
      (( class <= limit )) || continue
      cntools_uint_add_into next "${total}" \
        "${CNTOOLS_UTXO_LOVELACE[index]}" || return 1
      total="${next}"
    done
    if cntools_uint_greater_equal "${total}" "${required}"; then
      _cntools_output_ref="${limit}"
      return 0
    fi
  done
  _cntools_output_ref=4
}

cntools_coin_add_index() {
  local index="${1:-}"
  local asset_id=""
  local key=""
  local current=""
  local total=""
  local -a asset_ids=()

  [[ "${index}" =~ ^[0-9]+$ &&
     -n "${CNTOOLS_UTXO_REFS[index]+x}" &&
     -z "${CNTOOLS_COIN_SELECTED_MAP[${index}]+x}" ]] || return 2
  CNTOOLS_COIN_SELECTED_INDICES+=("${index}")
  CNTOOLS_COIN_SELECTED_REFS+=("${CNTOOLS_UTXO_REFS[index]}")
  CNTOOLS_COIN_SELECTED_MAP["${index}"]="Y"
  cntools_uint_add_into total "${CNTOOLS_COIN_SELECTED_LOVELACE}" \
    "${CNTOOLS_UTXO_LOVELACE[index]}" || return 1
  CNTOOLS_COIN_SELECTED_LOVELACE="${total}"
  if [[ -n "${CNTOOLS_UTXO_ASSET_LISTS[index]}" ]]; then
    read -r -a asset_ids <<< "${CNTOOLS_UTXO_ASSET_LISTS[index]}" || return 1
  fi
  for asset_id in "${asset_ids[@]}"; do
    key="${index}|${asset_id}"
    if [[ -z "${CNTOOLS_COIN_SELECTED_ASSETS[${asset_id}]+x}" ]]; then
      CNTOOLS_COIN_SELECTED_ASSET_IDS+=("${asset_id}")
      CNTOOLS_COIN_SELECTED_ASSETS["${asset_id}"]="${CNTOOLS_UTXO_ASSET_QUANTITIES[${key}]}"
    else
      current="${CNTOOLS_COIN_SELECTED_ASSETS[${asset_id}]}"
      cntools_uint_add_into total "${current}" \
        "${CNTOOLS_UTXO_ASSET_QUANTITIES[${key}]}" || return 1
      CNTOOLS_COIN_SELECTED_ASSETS["${asset_id}"]="${total}"
    fi
  done
  CNTOOLS_COIN_SELECTED_ASSET_COUNT="${#CNTOOLS_COIN_SELECTED_ASSET_IDS[@]}"
}

cntools_coin_best_sufficient_balanced_into() {
  local _cntools_output_name="${1:-}"
  local required="${2:-}"
  local maximum_class="${3:-4}"
  local index=0
  local class=0
  local best=""
  local best_class=99
  local comparison=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  for index in "${!CNTOOLS_UTXO_REFS[@]}"; do
    cntools_uint_greater_equal "${CNTOOLS_UTXO_LOVELACE[index]}" \
      "${required}" || continue
    cntools_coin_candidate_class_into class "${index}" || return 1
    (( class <= maximum_class )) || continue
    if [[ -z "${best}" ]] || (( class < best_class )); then
      best="${index}"
      best_class="${class}"
      continue
    fi
    (( class == best_class )) || continue
    cntools_uint_compare_into comparison \
      "${CNTOOLS_UTXO_LOVELACE[index]}" \
      "${CNTOOLS_UTXO_LOVELACE[best]}" || return 1
    if (( comparison < 0 )) ||
       { (( comparison == 0 )) &&
         [[ "${CNTOOLS_UTXO_REFS[index]}" < "${CNTOOLS_UTXO_REFS[best]}" ]]; }; then
      best="${index}"
    fi
  done
  _cntools_output_ref="${best}"
}

# 0 for a plain UTxO, 1 when it carries a datum or reference script: those are
# spent only when nothing else covers the amount (every strategy).
cntools_coin_complex_into() {
  local -n _cntools_complex_ref="$1"
  _cntools_complex_ref=0
  [[ "${CNTOOLS_UTXO_HAS_DATUM[$2]}" == "N" &&
     "${CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT[$2]}" == "N" ]] || _cntools_complex_ref=1
}

# ALLOW_COMPLEX=N skips datum and reference-script UTxOs: the caller passes it
# when plain UTxOs together cover the amount.
# Lovelace in UTxOs without a datum or reference script.
cntools_coin_plain_total_into() {
  local -n _cntools_plain_ref="$1"
  local plain_index=0 plain_complex=0
  _cntools_plain_ref=0
  for plain_index in "${!CNTOOLS_UTXO_REFS[@]}"; do
    cntools_coin_complex_into plain_complex "${plain_index}"
    (( plain_complex == 0 )) || continue
    cntools_uint_add_into _cntools_plain_ref "${_cntools_plain_ref}" "${CNTOOLS_UTXO_LOVELACE[plain_index]}" || return 1
  done
}

cntools_coin_best_sufficient_fewest_into() {
  local _cntools_output_name="${1:-}"
  local required="${2:-}"
  local allow_complex="${3:-Y}"
  local index=0
  local best=""
  local best_assets=0
  local best_complex=0
  local complex=0
  local comparison=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  for index in "${!CNTOOLS_UTXO_REFS[@]}"; do
    cntools_uint_greater_equal "${CNTOOLS_UTXO_LOVELACE[index]}" \
      "${required}" || continue
    cntools_coin_complex_into complex "${index}"
    [[ "${allow_complex}" == Y ]] || (( complex == 0 )) || continue
    if [[ -z "${best}" ]] || (( complex < best_complex )); then
      best="${index}"
      best_assets="${CNTOOLS_UTXO_ASSET_COUNTS[index]}"
      best_complex="${complex}"
      continue
    fi
    (( complex == best_complex )) || continue
    if (( CNTOOLS_UTXO_ASSET_COUNTS[index] < best_assets )); then
      best="${index}"
      best_assets="${CNTOOLS_UTXO_ASSET_COUNTS[index]}"
      continue
    fi
    (( CNTOOLS_UTXO_ASSET_COUNTS[index] == best_assets )) || continue
    cntools_uint_compare_into comparison \
      "${CNTOOLS_UTXO_LOVELACE[index]}" \
      "${CNTOOLS_UTXO_LOVELACE[best]}" || return 1
    if (( comparison < 0 )) ||
       { (( comparison == 0 )) &&
         [[ "${CNTOOLS_UTXO_REFS[index]}" < "${CNTOOLS_UTXO_REFS[best]}" ]]; }; then
      best="${index}"
    fi
  done
  _cntools_output_ref="${best}"
}

cntools_coin_next_largest_into() {
  local _cntools_output_name="${1:-}"
  local strategy="${2:-balanced}"
  local maximum_class="${3:-4}"
  local index=0
  local class=0
  local best=""
  local best_class=99
  local complex=0
  local best_complex=0
  local comparison=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  for index in "${!CNTOOLS_UTXO_REFS[@]}"; do
    [[ -z "${CNTOOLS_COIN_SELECTED_MAP[${index}]+x}" ]] || continue
    cntools_coin_candidate_class_into class "${index}" || return 1
    (( class <= maximum_class )) || continue
    if [[ "${strategy}" == "balanced" ]]; then
      if [[ -z "${best}" ]] || (( class < best_class )); then
        best="${index}"
        best_class="${class}"
        continue
      fi
      (( class == best_class )) || continue
    else
      # Fewest inputs takes the largest, but datum and reference-script UTxOs last.
      cntools_coin_complex_into complex "${index}"
      if [[ -z "${best}" ]] || (( complex < best_complex )); then
        best="${index}"
        best_class="${class}"
        best_complex="${complex}"
        continue
      fi
      (( complex == best_complex )) || continue
    fi
    cntools_uint_compare_into comparison \
      "${CNTOOLS_UTXO_LOVELACE[index]}" \
      "${CNTOOLS_UTXO_LOVELACE[best]}" || return 1
    if (( comparison > 0 )) ||
       { (( comparison == 0 )) && (( class < best_class )); } ||
       { (( comparison == 0 && class == best_class )) &&
         [[ "${CNTOOLS_UTXO_REFS[index]}" < "${CNTOOLS_UTXO_REFS[best]}" ]]; }; then
      best="${index}"
      best_class="${class}"
    fi
  done
  _cntools_output_ref="${best}"
}

cntools_coin_select_lovelace() {
  local required="${1:-}"
  local strategy="${2:-${CNTOOLS_TX_SELECTION_STRATEGY:-balanced}}"
  local remaining=""
  local candidate=""
  local maximum_class=4
  local plain_total=0
  local allow_complex=Y

  cntools_coin_reset
  cntools_uint_normalize_into required "${required}" || return 2
  case "${strategy}" in balanced|fewest-inputs) ;; *) return 2 ;; esac
  (( ${#CNTOOLS_UTXO_REFS[@]} > 0 )) ||
    cntools_coin_fail "No spendable UTxOs are available." || return 1
  CNTOOLS_COIN_REQUIRED_LOVELACE="${required}"
  cntools_coin_find_collateral_candidate || return 1
  if [[ "${strategy}" == "balanced" ]]; then
    cntools_coin_balanced_class_limit_into maximum_class "${required}" ||
      return 1
    cntools_coin_best_sufficient_balanced_into \
      candidate "${required}" "${maximum_class}" ||
      return 1
  else
    # Datum and reference-script UTxOs only when plain ones cannot cover it.
    cntools_coin_plain_total_into plain_total || return 1
    allow_complex=Y
    ! cntools_uint_greater_equal "${plain_total}" "${required}" || allow_complex=N
    cntools_coin_best_sufficient_fewest_into candidate "${required}" "${allow_complex}" ||
      return 1
  fi
  if [[ -n "${candidate}" ]]; then
    cntools_coin_add_index "${candidate}" || return 1
  else
    while ! cntools_uint_greater_equal \
        "${CNTOOLS_COIN_SELECTED_LOVELACE}" "${required}"; do
      (( ${#CNTOOLS_COIN_SELECTED_INDICES[@]} < 100 )) || {
        cntools_coin_fail_input_limit; return 1;
      }
      cntools_coin_next_largest_into \
        candidate "${strategy}" "${maximum_class}" || return 1
      [[ -n "${candidate}" ]] || {
        cntools_coin_fail_short "${required}"; return 1;
      }
      cntools_coin_add_index "${candidate}" || return 1
    done
  fi
  cntools_uint_subtract_into remaining \
    "${CNTOOLS_COIN_SELECTED_LOVELACE}" "${required}" || return 1
  CNTOOLS_COIN_SELECTION_REASON="Selected ${#CNTOOLS_COIN_SELECTED_INDICES[@]} of ${#CNTOOLS_UTXO_REFS[@]} UTxOs; ${CNTOOLS_COIN_SELECTED_ASSET_COUNT} native assets touched; conservative balance margin ${remaining} lovelace."
}

# Cover an exact asset demand first, then ADA. The demand is an associative
# array keyed by policy.hex-name with integer-string quantities.
cntools_coin_select_value() {
  local required="${1:-}" demand_name="${2:-}" strategy="${3:-balanced}"
  local asset="" needed="" held="" candidate="" class=0 best_class=99
  local index=0 compare=0
  [[ "${demand_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n demand_ref="${demand_name}"
  case "${strategy}" in balanced|fewest-inputs) ;; *) return 2 ;; esac
  if (( ${#demand_ref[@]} == 0 )); then
    cntools_coin_select_lovelace "${required}" "${strategy}"
    return $?
  fi
  cntools_coin_reset
  cntools_uint_normalize_into CNTOOLS_COIN_REQUIRED_LOVELACE "${required}" || return 2
  cntools_coin_find_collateral_candidate || return 1
  local sorted=""
  sorted="$(printf '%s\n' "${!demand_ref[@]}" | LC_ALL=C sort)" || return 1
  while IFS= read -r asset; do
    [[ "${asset}" =~ ^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$ ]] || return 2
    cntools_uint_normalize_into needed "${demand_ref[${asset}]}" || return 2
    while ! cntools_uint_greater_equal "${CNTOOLS_COIN_SELECTED_ASSETS[${asset}]:-0}" "${needed}"; do
      candidate=""; best_class=99
      for index in "${!CNTOOLS_UTXO_REFS[@]}"; do
        [[ -z "${CNTOOLS_COIN_SELECTED_MAP[${index}]+x}" ]] || continue
        held="${CNTOOLS_UTXO_ASSET_QUANTITIES[${index}|${asset}]:-0}"
        [[ "${held}" != 0 ]] || continue
        cntools_coin_candidate_class_into class "${index}" || return 1
        if [[ -z "${candidate}" ]]; then
          candidate="${index}"; best_class="${class}"; continue
        fi
        cntools_uint_compare_into compare "${held}" \
          "${CNTOOLS_UTXO_ASSET_QUANTITIES[${candidate}|${asset}]}" || return 1
        if { [[ "${strategy}" == balanced ]] && (( class < best_class )); } ||
           { { [[ "${strategy}" == fewest-inputs ]] || (( class == best_class )); } &&
             { (( compare > 0 )) || { (( compare == 0 )) &&
               [[ "${CNTOOLS_UTXO_REFS[index]}" < "${CNTOOLS_UTXO_REFS[candidate]}" ]]; }; }; }; then
          candidate="${index}"; best_class="${class}"
        fi
      done
      [[ -n "${candidate}" ]] || { cntools_coin_fail "The wallet does not hold enough of ${asset}."; return 1; }
      (( ${#CNTOOLS_COIN_SELECTED_INDICES[@]} < 100 )) || { cntools_coin_fail_input_limit; return 1; }
      cntools_coin_add_index "${candidate}" || return 1
    done
  done <<< "${sorted}"
  while ! cntools_uint_greater_equal "${CNTOOLS_COIN_SELECTED_LOVELACE}" "${required}"; do
    cntools_coin_next_largest_into candidate "${strategy}" 4 || return 1
    [[ -n "${candidate}" ]] || { cntools_coin_fail_short "${required}"; return 1; }
    (( ${#CNTOOLS_COIN_SELECTED_INDICES[@]} < 100 )) || { cntools_coin_fail_input_limit; return 1; }
    cntools_coin_add_index "${candidate}" || return 1
  done
  CNTOOLS_COIN_SELECTION_REASON="Selected ${#CNTOOLS_COIN_SELECTED_INDICES[@]} of ${#CNTOOLS_UTXO_REFS[@]} UTxOs to cover ADA and requested native assets."
}
