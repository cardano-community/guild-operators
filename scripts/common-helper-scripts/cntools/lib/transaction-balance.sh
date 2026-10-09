#!/usr/bin/env bash
# Backend/action-neutral exact-fee convergence and ledger-value sizing.
# Actions supply a body-preparation callback and their own effect validator.
# No fee padding or action-specific certificate routing lives here.
# shellcheck disable=SC2034

# Exact CBOR header/integer sizes, compared as decimal strings rather than Bash
# signed integers. Used for ledger values, not an approximate per-asset budget.
cntools_transaction_cbor_uint_size_into() {
  local _cntools_cbor_target="$1" _cntools_cbor_value="$2" _cntools_cbor_threshold='' _cntools_cbor_size=1
  [[ "${_cntools_cbor_target}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_cbor_result="${_cntools_cbor_target}"
  cntools_uint_normalize_into _cntools_cbor_value "${_cntools_cbor_value}" || return 1
  cntools_uint_greater '18446744073709551616' "${_cntools_cbor_value}" || return 1
  for _cntools_cbor_threshold in 24 256 65536 4294967296; do
    if cntools_uint_greater "${_cntools_cbor_threshold}" "${_cntools_cbor_value}"; then
      _cntools_cbor_result="${_cntools_cbor_size}"; return 0
    fi
    case "${_cntools_cbor_size}" in 1) _cntools_cbor_size=2 ;; 2) _cntools_cbor_size=3 ;; 3) _cntools_cbor_size=5 ;; 5) _cntools_cbor_size=9 ;; esac
  done
  _cntools_cbor_result=9
}

cntools_transaction_value_size_into() {
  local _cntools_value_target="$1" _cntools_value_output="$2" _cntools_value_coin='' _cntools_value_policy='' _cntools_value_name='' _cntools_value_id='' _cntools_value_quantity='' _cntools_value_size=0 _cntools_value_head=0 _cntools_value_i=0
  local -a _cntools_value_pieces=()
  local -A _cntools_value_quantities=() _cntools_value_policy_counts=()
  [[ "${_cntools_value_target}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_value_value_size_result="${_cntools_value_target}"
  read -r -a _cntools_value_pieces <<< "${_cntools_value_output}"
  (( ${#_cntools_value_pieces[@]} > 0 && (${#_cntools_value_pieces[@]} - 1) % 3 == 0 )) || return 1
  [[ "${_cntools_value_pieces[0]}" == *+* ]] || return 1
  _cntools_value_coin="${_cntools_value_pieces[0]##*+}"
  cntools_transaction_cbor_uint_size_into _cntools_value_size "${_cntools_value_coin}" || return 1
  for ((_cntools_value_i=1; _cntools_value_i<${#_cntools_value_pieces[@]}; _cntools_value_i+=3)); do
    [[ "${_cntools_value_pieces[_cntools_value_i]}" == + ]] || return 1
    _cntools_value_quantity="${_cntools_value_pieces[_cntools_value_i+1]}"; _cntools_value_id="${_cntools_value_pieces[_cntools_value_i+2]}"
    [[ "${_cntools_value_id}" =~ ^[0-9a-f]{56}(\.([0-9a-f]{2}){0,32})?$ ]] || return 1
    cntools_uint_normalize_into _cntools_value_quantity "${_cntools_value_quantity}" || return 1
    [[ "${_cntools_value_quantity}" != 0 ]] || continue
    _cntools_value_policy="${_cntools_value_id:0:56}"; _cntools_value_name="${_cntools_value_id:57}"; _cntools_value_id="${_cntools_value_policy}.${_cntools_value_name}"
    if [[ -z "${_cntools_value_quantities[${_cntools_value_id}]+x}" ]]; then
      _cntools_value_policy_counts["${_cntools_value_policy}"]=$(( ${_cntools_value_policy_counts[${_cntools_value_policy}]:-0} + 1 ))
    fi
    cntools_uint_add_into _cntools_value_quantity "${_cntools_value_quantities[${_cntools_value_id}]:-0}" "${_cntools_value_quantity}" || return 1
    _cntools_value_quantities["${_cntools_value_id}"]="${_cntools_value_quantity}"
  done
  if (( ${#_cntools_value_quantities[@]} == 0 )); then _cntools_value_value_size_result="${_cntools_value_size}"; return 0; fi
  # [coin, {policy: {assetName: quantity}}]. Each policy's 28-byte key is shared.
  cntools_transaction_cbor_uint_size_into _cntools_value_head "${#_cntools_value_policy_counts[@]}" || return 1
  _cntools_value_size=$((_cntools_value_size + 1 + _cntools_value_head))
  for _cntools_value_policy in "${!_cntools_value_policy_counts[@]}"; do
    cntools_transaction_cbor_uint_size_into _cntools_value_head "${_cntools_value_policy_counts[${_cntools_value_policy}]}" || return 1
    _cntools_value_size=$((_cntools_value_size + 30 + _cntools_value_head))
  done
  for _cntools_value_id in "${!_cntools_value_quantities[@]}"; do
    _cntools_value_name="${_cntools_value_id#*.}"
    cntools_transaction_cbor_uint_size_into _cntools_value_head "$((${#_cntools_value_name}/2))" || return 1
    _cntools_value_size=$((_cntools_value_size + _cntools_value_head + ${#_cntools_value_name}/2))
    cntools_transaction_cbor_uint_size_into _cntools_value_head "${_cntools_value_quantities[${_cntools_value_id}]}" || return 1
    _cntools_value_size=$((_cntools_value_size + _cntools_value_head))
  done
  _cntools_value_value_size_result="${_cntools_value_size}"
}

cntools_transaction_validate_value_size() {
  local output="$1" protocol="$2" value_size=0 maximum=''
  maximum="$(jq -er '.maxValueSize | select(type == "number" and . > 0 and . <= 100000 and floor == .)' "${protocol}")" || return 1
  cntools_transaction_value_size_into value_size "${output}" || return 1
  (( value_size <= maximum )) || {
    cntools_transaction_set_error 'An output exceeds the ledger value-size limit. Split its assets or enable token fragmentation.'; return 1;
  }
}

# A rebuild flag requests another build until exact convergence. Discretionary
# ADA change may shrink, but must not regrow when a smaller fee frees a few
# lovelace: that would alternate layouts rather than converge to an exact fee.
# The cap is local to a builder call; it never changes persistent user settings.
cntools_transaction_balance_fee_update() {
  local target="$1" calculated="$2" optional=0 type=''
  local -n balance_fee_result="${target}"
  cntools_uint_normalize_into calculated "${calculated}" || return 1
  CNTOOLS_TRANSACTION_BALANCE_REBUILD=N
  [[ "${balance_fee_result}" != "${calculated}" ]] || return 0
  if cntools_uint_greater "${balance_fee_result}" "${calculated}"; then
    for type in "${CNTOOLS_CHANGE_OUTPUT_TYPES[@]-}"; do
      case "${type}" in 'Collateral candidate'|'ADA liquidity '*) optional=$((optional+1)) ;; esac
    done
    if [[ -z "${CNTOOLS_TRANSACTION_BALANCE_CHANGE_CAP:-}" ]] ||
        (( optional < CNTOOLS_TRANSACTION_BALANCE_CHANGE_CAP )); then
      CNTOOLS_TRANSACTION_BALANCE_CHANGE_CAP="${optional}"
    fi
  fi
  balance_fee_result="${calculated}"
  CNTOOLS_TRANSACTION_BALANCE_REBUILD=Y
}

cntools_transaction_validate_change_output() {
  local output="$1" protocol="$2" minimum="" amount=""
  cntools_transaction_validate_value_size "${output}" "${protocol}" || return 1
  cntools_transaction_calculate_min_utxo_into minimum "${protocol}" "${output}" || return 1
  amount="${output#*+}"; amount="${amount%% *}"
  cntools_uint_greater_equal "${amount}" "${minimum}" || {
    cntools_transaction_set_error 'A change output does not contain the minimum required ADA.'; return 1;
  }
}

# prepare(body-output-name) sets input/output counts and builds one raw body.
# Return 3 to request input/min-ADA replanning without signing or publishing.
cntools_transaction_balance_into() {
  local _bal_output="$1" _bal_fee_name="$2" _bal_protocol="$3" _bal_prepare="$4" _bal_validate="${5:-}"
  local _bal_body='' _bal_package='' _bal_next='' _bal_attempt=0 _bal_status=0 _bal_max=0 _bal_bytes=0 _bal_witnesses=0
  local CNTOOLS_TRANSACTION_BALANCE_CHANGE_CAP='' CNTOOLS_TRANSACTION_BALANCE_REBUILD=N
  local CNTOOLS_TRANSACTION_BALANCE_INPUT_COUNT=0 CNTOOLS_TRANSACTION_BALANCE_OUTPUT_COUNT=0
  [[ "${_bal_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "${_bal_fee_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  declare -F "${_bal_prepare}" >/dev/null || return 2
  [[ -z "${_bal_validate}" ]] || declare -F "${_bal_validate}" >/dev/null || return 2
  local -n _bal_result="${_bal_output}"
  _bal_result=''
  _bal_max="$(jq -er '.maxTxSize|select(type=="number" and .>0 and .<=100000 and floor==.)' "${_bal_protocol}")" || return 1
  for ((_bal_attempt=0; _bal_attempt<20; _bal_attempt++)); do
    _bal_status=0; "${_bal_prepare}" _bal_body || _bal_status=$?
    (( _bal_status != 3 )) || continue
    (( _bal_status == 0 )) || return "${_bal_status}"
    cntools_transaction_package_create_staged_into _bal_package "${_bal_body}" || return 1
    cntools_transaction_package_load "${_bal_package}" || return 1
    # Price only the final representation. Pricing the pre-transform body first
    # can alternate between smaller raw and larger hardware-normalized fees.
    cntools_transaction_calculate_min_fee_into _bal_next "${CNTOOLS_TRANSACTION_BODY_FILE}" "${CNTOOLS_TRANSACTION_BALANCE_INPUT_COUNT}" \
      "${CNTOOLS_TRANSACTION_BALANCE_OUTPUT_COUNT}" "${_bal_protocol}" || return 1
    cntools_transaction_balance_fee_update "${_bal_fee_name}" "${_bal_next}" || return 1
    [[ "${CNTOOLS_TRANSACTION_BALANCE_REBUILD}" != Y ]] || continue
    [[ -z "${_bal_validate}" ]] || "${_bal_validate}" "${CNTOOLS_TRANSACTION_BODY_FILE}" || return 1
    _bal_bytes="$(jq -er '.cborHex|length/2' "${CNTOOLS_TRANSACTION_BODY_FILE}")" || return 1
    _bal_witnesses="$(cntools_transaction_plan_witness_count)" || return 1
    # This is a conservative maximum-size guard, never an input to fee pricing.
    (( _bal_bytes + _bal_witnesses * 112 + 32 <= _bal_max )) || {
      cntools_transaction_set_error 'The transaction exceeds the signed-size safety limit. Reduce inputs, assets or change outputs.'; return 1;
    }
    _bal_result="${_bal_package}"
    cntools_transaction_log TRANSACTION "Exact balanced transaction fee=${!_bal_fee_name} inputs=${CNTOOLS_TRANSACTION_BALANCE_INPUT_COUNT} outputs=${CNTOOLS_TRANSACTION_BALANCE_OUTPUT_COUNT} attempts=$((_bal_attempt+1))"
    return 0
  done
  cntools_transaction_set_error 'Exact fee/change balancing did not converge within the safety limit. Nothing was signed.'
  return 1
}
