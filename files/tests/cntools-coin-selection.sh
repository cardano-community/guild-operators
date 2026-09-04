#!/usr/bin/env bash
# CNTools deterministic coin-selection and change-planning tests.
# shellcheck disable=SC1090,SC2034,SC2154

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools coin-selection tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TX_A="$(printf 'aa%.0s' {1..32})"
TX_B="$(printf 'bb%.0s' {1..32})"
TX_C="$(printf 'cc%.0s' {1..32})"
TX_D="$(printf 'dd%.0s' {1..32})"
POLICY="$(printf 'ee%.0s' {1..28})"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="${3:-values differ}"

  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

for required in bash jq sort; do
  command -v "${required}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required}"
done

# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/number.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/utxo.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/coin-selection.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/change-plan.sh"

cntools_transaction_calculate_min_utxo_into() {
  local output_name="${1:-}"

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  output_ref="1000000"
}

set_defaults() {
  CNTOOLS_TX_SELECTION_STRATEGY="balanced"
  CNTOOLS_TX_TOKEN_FRAGMENTATION="N"
  CNTOOLS_TX_TOKEN_MAX_ASSETS=20
  CNTOOLS_TX_UTXO_MANAGEMENT="Y"
  CNTOOLS_TX_UTXO_TARGET_COUNT=4
  CNTOOLS_TX_UTXO_PERCENTAGES="10,20,30"
  CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS=3
  CNTOOLS_TX_UTXO_MIN_LOVELACE="2000000"
  CNTOOLS_TX_COLLATERAL_MANAGEMENT="Y"
  CNTOOLS_TX_COLLATERAL_TARGET_COUNT=1
  CNTOOLS_TX_COLLATERAL_LOVELACE="5000000"
}

build_inventory() {
  cntools_utxo_reset
  cntools_utxo_add "${TX_A}#0" addr_test1wallet 2000000 N N
  cntools_utxo_add "${TX_B}#0" addr_test1wallet 6000000 N N
  cntools_utxo_add "${TX_C}#0" addr_test1wallet 10000000 N N
  cntools_utxo_add_asset 2 "${POLICY}.746f6b656e" 1
  cntools_utxo_add "${TX_D}#0" addr_test1wallet 5000000 N N
}

test_exact_integer_helpers() {
  local result=""

  cntools_uint_add_into result 9007199254740993 9007199254740993
  assert_eq "${result}" 18014398509481986 "lossless addition"
  cntools_uint_subtract_into result 18014398509481986 9007199254740993
  assert_eq "${result}" 9007199254740993 "lossless subtraction"
  cntools_uint_percent_into result 9007199254740993 30
  assert_eq "${result}" 2702159776422297 "lossless percentage"
}

test_fee_reserve() {
  local protocol_file=""
  local reserve=""

  protocol_file="$(mktemp)" || fail "fee-reserve fixture could not be created"
  printf '%s\n' \
    '{"txFeeFixed":2,"txFeePerByte":4,"maxTxSize":100000}' \
    > "${protocol_file}"
  cntools_coin_fee_reserve_into reserve "${protocol_file}" ||
    fail "valid protocol fee parameters were rejected"
  assert_eq "${reserve}" 400002 "conservative fee reserve"
  printf '%s\n' \
    '{"txFeeFixed":2,"txFeePerByte":4,"maxTxSize":100001}' \
    > "${protocol_file}"
  if cntools_coin_fee_reserve_into reserve "${protocol_file}"; then
    fail "oversized protocol fee parameter was accepted"
  fi
  rm -f -- "${protocol_file}"
}

test_balanced_selection() {
  set_defaults
  build_inventory
  cntools_coin_select_lovelace 6000000 balanced ||
    fail "balanced selection rejected an exact ADA-only match"
  assert_eq "${#CNTOOLS_COIN_SELECTED_INDICES[@]}" 1 \
    "balanced exact input count"
  assert_eq "${CNTOOLS_COIN_SELECTED_REFS[0]}" "${TX_B}#0" \
    "balanced exact input"

  cntools_coin_select_lovelace 7000000 balanced ||
    fail "balanced selection could not combine ADA-only inputs"
  assert_eq "${#CNTOOLS_COIN_SELECTED_INDICES[@]}" 2 \
    "balanced combined input count"
  assert_eq "${CNTOOLS_COIN_SELECTED_REFS[*]}" \
    "${TX_B}#0 ${TX_A}#0" "deterministic balanced order"
  [[ -z "${CNTOOLS_COIN_SELECTED_MAP[3]+x}" ]] ||
    fail "balanced selection consumed the protected collateral candidate"
  assert_eq "${CNTOOLS_COIN_SELECTED_ASSET_COUNT}" 0 \
    "balanced token avoidance"
}

test_fewest_input_selection() {
  set_defaults
  build_inventory
  cntools_coin_select_lovelace 7000000 fewest-inputs ||
    fail "fewest-input selection failed"
  assert_eq "${#CNTOOLS_COIN_SELECTED_INDICES[@]}" 1 \
    "fewest-input count"
  assert_eq "${CNTOOLS_COIN_SELECTED_REFS[0]}" "${TX_C}#0" \
    "fewest-input choice"
  assert_eq "${CNTOOLS_COIN_SELECTED_ASSET_COUNT}" 1 \
    "fewest-input token consequence"
}

test_token_fragmentation() {
  local index=0
  local asset_id=""

  set_defaults
  CNTOOLS_TX_TOKEN_FRAGMENTATION="Y"
  CNTOOLS_TX_UTXO_MANAGEMENT="N"
  cntools_utxo_reset
  cntools_utxo_add "${TX_A}#0" addr_test1wallet 30000000 N N
  for (( index = 0; index < 45; index++ )); do
    printf -v asset_id '%s.%02x' "${POLICY}" "${index}"
    cntools_utxo_add_asset 0 "${asset_id}" 1
  done
  cntools_coin_select_lovelace 1 balanced ||
    fail "token inventory could not be selected"
  cntools_change_plan_stake register 2000000 1000000 \
    /unused/protocol.json addr_test1wallet ||
    fail "fragmented token change could not be planned"
  assert_eq "${#CNTOOLS_CHANGE_OUTPUTS[@]}" 3 \
    "fragmented token output count"
  assert_eq "${CNTOOLS_CHANGE_OUTPUT_ASSET_COUNTS[*]}" "20 20 5" \
    "fragmented token bundle sizes"
  [[ "${CNTOOLS_CHANGE_TOKEN_STATUS}" == Applied* ]] ||
    fail "token fragmentation was not reported as applied"
}

test_percentage_change_management() {
  set_defaults
  cntools_utxo_reset
  cntools_utxo_add "${TX_A}#0" addr_test1wallet 20000000 N N
  cntools_coin_select_lovelace 1 balanced ||
    fail "ADA change inventory could not be selected"
  cntools_change_plan_stake register 2000000 1000000 \
    /unused/protocol.json addr_test1wallet ||
    fail "ADA-only change could not be planned"
  assert_eq "${#CNTOOLS_CHANGE_OUTPUTS[@]}" 3 \
    "managed ADA output count"
  assert_eq "${CNTOOLS_CHANGE_OUTPUT_TYPES[*]}" \
    "Collateral candidate ADA liquidity 20% ADA liquidity 30%" \
    "managed ADA output types"
  assert_eq "${CNTOOLS_CHANGE_OUTPUT_LOVELACE[*]}" \
    "5000000 2400000 3600000" "percentage amounts use a frozen base"
  assert_eq "${CNTOOLS_CHANGE_RESIDUAL_LOVELACE}" 6000000 \
    "managed residual change"
  assert_eq "${#CNTOOLS_COIN_SELECTED_INDICES[@]}" 1 \
    "change management did not pull housekeeping inputs"
}

test_exact_integer_helpers
test_fee_reserve
test_balanced_selection
test_fewest_input_selection
test_token_fragmentation
test_percentage_change_management

printf 'CNTools coin-selection and change-planning tests passed\n'
