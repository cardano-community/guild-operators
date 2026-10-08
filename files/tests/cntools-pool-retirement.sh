#!/usr/bin/env bash
# Retirement safety/UI contracts and real, node-free pinned cnode transactions.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-pool-retirement.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'chmod -R u+rwX "${TEST_ROOT}"; rm -rf -- "${TEST_ROOT}"' EXIT
umask 077
while IFS= read -r lib; do . "${CNTOOLS_ROOT}/lib/${lib}"; done < <(jq -r '.libs[]' "${CNTOOLS_ROOT}/modules/root/pool/retire/module.json")
fail() { printf 'FAIL: %s (%s / %s)\n' "$*" "${CNTOOLS_WALLET_REGISTER_ERROR:-}" "${CNTOOLS_TRANSACTION_ERROR:-}" >&2; tail -12 "${TEST_ROOT}/test.log" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-comparison}: $1 != $2"; }
reject() { if "$@"; then fail "unexpected success: $*"; fi; }
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/test.log"; }
cntools_log_sanitize_line() { printf '%s' "${1//[[:cntrl:]]/ }"; }
cntools_run_command_timeout() { local mask="$2"; shift 3; (( ${#mask} == $# )) || fail 'audit mask mismatch'; printf '%q ' "$@" >> "${TEST_ROOT}/test.log"; printf '\n' >> "${TEST_ROOT}/test.log"; "$@"; }
if [[ "${OSTYPE:-}" == darwin* ]]; then
  REAL_CHMOD="$(type -P chmod)" REAL_LN="$(type -P ln)"
  chmod() { local arg=''; local -a args=(); for arg in "$@"; do [[ "${arg}" == -- ]] || args+=("${arg}"); done; "${REAL_CHMOD}" "${args[@]}"; }
  ln() { if [[ "${1:-}" == -T ]]; then shift; [[ ! -d "${3}" ]] || return 1; fi; "${REAL_LN}" "$@"; }
fi
CNTOOLS_TMP_DIR="${TEST_ROOT}" CNTOOLS_NODE_HOME="${TEST_ROOT}" CNTOOLS_NETWORK=preview CNTOOLS_MODE=light
CNTOOLS_LOG="${TEST_ROOT}/test.log" CNTOOLS_TRANSACTION_OPENSSL="${CNTOOLS_TEST_OPENSSL:-}"
CNTOOLS_WALLET_DIR="${TEST_ROOT}/wallets" CNTOOLS_POOL_DIR="${TEST_ROOT}/pools"
CNTOOLS_TX_SELECTION_STRATEGY=balanced CNTOOLS_TX_TOKEN_FRAGMENTATION=N CNTOOLS_TX_TOKEN_MAX_ASSETS=20
CNTOOLS_TX_UTXO_MANAGEMENT=N CNTOOLS_TX_COLLATERAL_MANAGEMENT=N CNTOOLS_TX_UTXO_TARGET_COUNT=4 CNTOOLS_TX_UTXO_PERCENTAGES=10,20,30
cntools_pool_registration_operation_set pool-retire
CNTOOLS_POOL_REG_OWNERS='[]'
CNTOOLS_POOL_REG_INDEX=0 CNTOOLS_POOL_NAMES=(Example)
CNTOOLS_POOL_CHAIN_STATUS=(Registered) CNTOOLS_POOL_CHAIN_SOURCE=('Local node') CNTOOLS_POOL_FUTURE=('{}') CNTOOLS_POOL_RETIREMENT=('')
CNTOOLS_POOL_CURRENT=('{"spsAccountId":{"scriptHash":"abc"}}')
state=''; cntools_pool_registration_state_into state
jq -e '.registered and .current.spsAccountId.scriptHash == "abc"' <<< "${state}" >/dev/null || fail 'retirement unnecessarily requires owner/VRF/reward keys'
CNTOOLS_POOL_CHAIN_STATUS=(Unavailable); reject cntools_pool_registration_state_into state
CNTOOLS_POOL_CHAIN_STATUS=('Not indexed'); cntools_pool_registration_state_into state; eq "${state}" '{"registered":false}'
CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
# Production tip parser: epoch must come from the chosen chain source, not slot/time.
(
  CNTOOLS_CLI=fixture CNTOOLS_SOCKET=/fixture CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://fixture.invalid/api/v1
  cntools_transaction_run_cli() { printf '%s\n' '{"slot":1000,"epoch":100}' > "$1"; }
  cntools_funding_get() { printf '%s\n' '[{"abs_slot":1000,"epoch_no":101}]' > "$2"; }
  slot=''; cntools_funding_tip_into slot local; eq "${CNTOOLS_FUNDING_EPOCH}" 100
  cntools_funding_tip_into slot koios; eq "${CNTOOLS_FUNDING_EPOCH}" 101
)
fixture_epoch=100 fixture_tip_failure=N
cntools_funding_tip_into() { [[ "${fixture_tip_failure}" == N ]] || return 1; printf -v "$1" '%s' 1000; CNTOOLS_FUNDING_EPOCH="${fixture_epoch}"; }
cntools_pool_retirement_window_collect
eq "${CNTOOLS_POOL_RETIRE_MIN}" 101; eq "${CNTOOLS_POOL_RETIRE_MAX}" 118
for epoch in 101 118; do CNTOOLS_POOL_RETIRE_EPOCH="${epoch}"; cntools_pool_retirement_window_check || fail 'inclusive window boundaries'; done
for epoch in 100 119 -1 01 1.5 2147483648; do CNTOOLS_POOL_RETIRE_EPOCH="${epoch}"; reject cntools_pool_retirement_window_check; done
CNTOOLS_POOL_RETIRE_EPOCH=101 fixture_epoch=101; reject cntools_pool_retirement_window_check
fixture_epoch=100 fixture_tip_failure=Y; reject cntools_pool_retirement_window_check; fixture_tip_failure=N
fixture_epoch=''; reject cntools_pool_retirement_window_collect; fixture_epoch=100
CNTOOLS_MODE=offline; reject cntools_pool_retirement_window_collect; CNTOOLS_MODE=light
CNTOOLS_POOL_REG_STATE='{"registered":false}'; reject cntools_pool_retirement_collect
# Epoch prompt: Enter default, comma normalization, cancellation and invalid retry.
(
  cntools_ui_spin_function() { shift; "$@"; }
  cntools_pool_registration_begin() { :; }; cntools_pool_retirement_rows() { :; }; cntools_table_render() { :; }
  cntools_ui_render_status() { :; }; cntools_ui_wait() { :; }
  CNTOOLS_POOL_REG_ID=poolfixture CNTOOLS_POOL_RETIRE_EPOCH=''
  cntools_ui_input() { printf -v "$1" '%s' ''; }
  cntools_pool_retirement_select_epoch; eq "${CNTOOLS_POOL_RETIRE_EPOCH}" 101 'default epoch'
  fixture_epoch=1000; cntools_ui_input() { printf -v "$1" '%s' '1,002'; }
  cntools_pool_retirement_select_epoch; eq "${CNTOOLS_POOL_RETIRE_EPOCH}" 1002
  cntools_ui_input() { return 1; }; reject cntools_pool_retirement_select_epoch
  attempts=0; cntools_ui_input() { attempts=$((attempts+1)); if ((attempts==1)); then printf -v "$1" '%s' bad; else printf -v "$1" '%s' 1003; fi; }
  cntools_pool_retirement_select_epoch; eq "${attempts}" 2; eq "${CNTOOLS_POOL_RETIRE_EPOCH}" 1003
)
# Recheck checks both selected inputs/state and the current retirement window.
(
  fixture_ref="$(printf 'ee%.0s' {1..32})#0" fixture_state='{"registered":true,"retirement":""}' fixture_spent=N
  cntools_funding_collect() {
    CNTOOLS_FUNDING_BACKEND=koios CNTOOLS_FUNDING_PROTOCOL="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json" CNTOOLS_FUNDING_SLOT=1000
    cntools_utxo_reset; [[ "${fixture_spent}" == Y ]] || cntools_utxo_add "${fixture_ref}" fixture 20000000
  }
  cntools_pool_registration_query_state_into() { printf -v "$1" '%s' "${fixture_state}"; }
  CNTOOLS_WALLET_REGISTER_BASE_ADDRESS=fixture CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS=fixture
  cntools_pool_registration_collect
  eq "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" 0 'no immediate refund/charge'
  CNTOOLS_WALLET_REGISTER_INPUTS=("${fixture_ref}") CNTOOLS_WALLET_REGISTER_EXPIRY='' CNTOOLS_POOL_RETIRE_EPOCH=101
  cntools_pool_registration_recheck || fail 'unchanged recheck'
  fixture_epoch=101; reject cntools_pool_registration_recheck; fixture_epoch=100
  fixture_state='{"registered":true,"retirement":"102"}'; reject cntools_pool_registration_recheck
  fixture_state="${CNTOOLS_POOL_REG_STATE}" fixture_spent=Y; reject cntools_pool_registration_recheck
)
printf 'CNTools pool retirement deterministic tests passed.\n'
(( $# > 0 )) || exit 0
CNTOOLS_CLI="$1" PINNED_HWCLI="${2:-}"
version="$("${CNTOOLS_CLI}" version | head -1)"; version="${version#cardano-cli }"; version="${version%% *}"
eq "${version}" "$(jq -r '.companions["cardano-cli"].version' "${REPO_ROOT}/files/node-implementations/cnode/release.json")" 'cnode deployment CLI pin'
mkdir -m 700 "${CNTOOLS_WALLET_DIR}" "${CNTOOLS_POOL_DIR}"
pool="${CNTOOLS_POOL_DIR}/Example" payer="${CNTOOLS_WALLET_DIR}/Funding"
mkdir -m 700 "${pool}" "${payer}"
"${CNTOOLS_CLI}" latest node key-gen --cold-signing-key-file "${pool}/cold.skey" --cold-verification-key-file "${pool}/cold.vkey" --operational-certificate-issue-counter-file "${pool}/cold.counter"
"${CNTOOLS_CLI}" address key-gen --signing-key-file "${payer}/payment.skey" --verification-key-file "${payer}/payment.vkey"
"${CNTOOLS_CLI}" address build --payment-verification-key-file "${payer}/payment.vkey" --testnet-magic 2 --out-file "${payer}/payment.addr"
before="$(cksum "${pool}"/*)"
cntools_pool_catalog_build
cntools_pool_registration_prepare_identity 0 || fail 'cold-only pool identity'
[[ ! -f "${pool}/vrf.vkey" ]] || fail 'retirement generated unneeded artifacts'
CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY="${payer}/payment.vkey" CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE="${payer}/payment.skey"
CNTOOLS_WALLET_REGISTER_PAYMENT_CREDENTIAL="$("${CNTOOLS_CLI}" address key-hash --payment-verification-key-file "${payer}/payment.vkey")"
CNTOOLS_WALLET_REGISTER_DIRECTORY="${payer}" CNTOOLS_WALLET_REGISTER_WALLET=Funding CNTOOLS_WALLET_REGISTER_WALLET_TYPE=CLI
CNTOOLS_WALLET_REGISTER_BASE_ADDRESS="$(< "${payer}/payment.addr")" CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS="$(< "${payer}/payment.addr")"
CNTOOLS_POOL_REG_STATE='{"registered":true,"retirement":""}'
ref="$(printf 'ee%.0s' {1..32})#0" policy="$(printf 'cd%.0s' {1..28})"
read -r -a scenarios <<< "${CNTOOLS_POOL_RETIRE_TEST_SCENARIOS:-ada tokens no-expiry offline}"
for scenario in "${scenarios[@]}"; do
  case "${scenario}" in ada|tokens|no-expiry|offline) ;; *) fail 'unknown retirement test scenario' ;; esac
  cntools_wallet_register_reset_chain_state
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
  CNTOOLS_WALLET_REGISTER_DEPOSIT=0 CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_POOL_RETIRE_EPOCH=101
  CNTOOLS_WALLET_REGISTER_LIFETIME=1800; [[ "${scenario}" != no-expiry ]] || CNTOOLS_WALLET_REGISTER_LIFETIME=0
  CNTOOLS_POOL_REG_COLD_SOURCE="${pool}/cold.skey"; [[ "${scenario}" != offline ]] || CNTOOLS_POOL_REG_COLD_SOURCE=''
  cntools_utxo_add "${ref}" "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" 20000000
  [[ "${scenario}" != tokens ]] || cntools_utxo_add_asset 0 "${policy}.01" 9007199254740993
  cntools_wallet_register_inventory_use_all
  can_sign=''; cntools_pool_registration_can_sign_into can_sign
  if [[ "${scenario}" == offline ]]; then eq "${can_sign}" N; else eq "${can_sign}" Y; fi
  package=''; cntools_pool_registration_build_into package || fail "build ${scenario}"
  eq "${CNTOOLS_TRANSACTION_REQUIRED_COUNT}" 2 'only funding and cold witnesses'
  body="${CNTOOLS_TRANSACTION_BODY_FILE}"
  cntools_pool_registration_validate_body "${body}" || fail 'decoded retirement'
  view=''; cntools_transaction_view_into view "${body}"
  sum="$(jq '[.outputs[].amount.lovelace]|add' <<< "${view}")"; fee="$(jq -r '.fee|split(" ")[0]' <<< "${view}")"
  ((sum+fee==20000000)) || fail 'retirement incorrectly refunded pool deposit'
  [[ "${scenario}" != tokens || "${view}" == *9007199254740993* ]] || fail 'asset precision/conservation'
  [[ "${scenario}" != no-expiry ]] || eq "$(jq -r '."validity range"."upper bound"' <<< "${view}")" null
  CNTOOLS_POOL_RETIRE_EPOCH=102; reject cntools_pool_registration_validate_body "${body}"; CNTOOLS_POOL_RETIRE_EPOCH=101
  saved_hex="${CNTOOLS_POOL_REG_HEX}"; CNTOOLS_POOL_REG_HEX="${policy}"; reject cntools_pool_registration_validate_body "${body}"; CNTOOLS_POOL_REG_HEX="${saved_hex}"
  if [[ -n "${PINNED_HWCLI}" ]]; then
    "${PINNED_HWCLI}" transaction transform --tx-file "${body}" --out-file "${TEST_ROOT}/hardware.body"
    cntools_pool_registration_validate_body "${TEST_ROOT}/hardware.body" || fail 'hardware normalization changed retirement'
  fi
  if [[ "${scenario}" == offline ]]; then
    sources=("${payer}/payment.skey" "${pool}/cold.skey"); changes=()
    signed="${TEST_ROOT}/${scenario}.signed"
    cntools_transaction_sign_package "${package}" "${signed}" sources changes || fail 'offline signer imports'
  else
    signed="${TEST_ROOT}/${scenario}.signed"
    cntools_transaction_sign_registered "${package}" "${signed}" || fail 'registered signing'
  fi
  cntools_transaction_package_load "${signed}"; eq "${CNTOOLS_TRANSACTION_COMPLETE}" Y
  size="$(jq -r '.cborHex|length/2' "${CNTOOLS_TRANSACTION_SIGNED_FILE}")"
  ((fee==155381+44*(size-1))) || fail "non-exact signed fee ${scenario}"
  printf 'Pinned pool retirement transaction passed: %s\n' "${scenario}"
done
# Pinned hw-cli needs the cold reference in every Ledger retirement call.
# Hardware funding therefore shares a confirmed device session with cold;
# CLI funding can instead collect a separate cold hardware witness.
jq --arg chain "$(printf '00%.0s' {1..32})" '{type:"StakePoolHWSigningFile_ed25519",path:"1853H/1815H/0H/0H",cborXPubKeyHex:("5840"+.cborHex[4:]+$chain)}' "${pool}/cold.vkey" > "${pool}/cold.hwsfile"
jq --arg chain "$(printf '00%.0s' {1..32})" '{type:"PaymentHWSigningFileShelley_ed25519",path:"1852H/1815H/0H/0/0",cborXPubKeyHex:("5840"+.cborHex[4:]+$chain)}' "${payer}/payment.vkey" > "${payer}/payment.hwsfile"
(
  CNTOOLS_POOL_REG_COLD_SOURCE="${pool}/cold.hwsfile" CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE="${payer}/payment.hwsfile"
  CNTOOLS_POOL_REG_COMBINE_HARDWARE=Y CNTOOLS_POOL_RETIRE_EPOCH=101
  # Stale registration-owner state must never leak into a retirement manifest.
  CNTOOLS_POOL_REG_OWNERS='[{"hash":"stale","source":"","vkey":""}]'
  cntools_pool_registration_plan_create
  jq -e 'length==2 and all(.[];.hardwareGroup=="pool-operator")' <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}" >/dev/null || fail 'hardware cold reference missing from payment session'
  can_sign=''; cntools_pool_registration_can_sign_into can_sign; eq "${can_sign}" Y
  cntools_payment_prepare_wallet() {
    CNTOOLS_PAYMENT_TYPE=Hardware CNTOOLS_PAYMENT_WALLET=Funding CNTOOLS_PAYMENT_ADDRESS="${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}"
    CNTOOLS_PAYMENT_PAYMENT="${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" CNTOOLS_PAYMENT_SOURCE="${payer}/payment.hwsfile"
    CNTOOLS_PAYMENT_VKEY="${payer}/payment.vkey" CNTOOLS_PAYMENT_CREDENTIAL="${CNTOOLS_WALLET_REGISTER_PAYMENT_CREDENTIAL}"
  }
  CNTOOLS_POOL_REG_COLD_SOURCE="${pool}/cold.skey"; reject cntools_pool_registration_prepare_funding "${payer}"
  CNTOOLS_POOL_REG_COLD_SOURCE="${pool}/cold.hwsfile"; cntools_pool_registration_prepare_funding "${payer}" || fail 'hardware retirement funding'
  cntools_ui_render_status() { :; }
  cntools_ui_choose() { printf -v "$1" '%s' 'Yes, same Ledger device'; }
  cntools_pool_registration_hardware_choice; eq "${CNTOOLS_POOL_REG_COMBINE_HARDWARE}" Y
  cntools_ui_choose() { printf -v "$1" '%s' 'No, use another funding wallet'; }; reject cntools_pool_registration_hardware_choice
)
# Double only the physical device boundary. CLI-generated witnesses still go
# through real cryptographic identity/signature/assembly validation.
(
  if [[ -n "${PINNED_HWCLI}" ]]; then
    CNTOOLS_TRANSACTION_HWCLI="${PINNED_HWCLI}"
  else
    cntools_transaction_prepare_hardware_body_into() { printf -v "$1" '%s' "$2"; }
    cntools_transaction_hardware_body_signable() { return 0; }
  fi
  hardware_calls=0
  cntools_transaction_witness_hardware_batch() {
    local hw_body="$1" hw_index=0 hw_key=''
    local -n hw_sources="$2" hw_outputs="$3"
    hardware_calls=$((hardware_calls+1))
    [[ "${hw_sources[*]}" == *"${pool}/cold.hwsfile"* ]] || fail 'cold reference absent from hardware call'
    for hw_index in "${!hw_sources[@]}"; do
      if [[ "${hw_sources[hw_index]}" == "${pool}/cold.hwsfile" ]]; then hw_key="${pool}/cold.skey"; else hw_key="${payer}/payment.skey"; fi
      cntools_transaction_witness_cli "${hw_body}" "${hw_key}" "${hw_outputs[hw_index]}" || return 1
    done
  }
  for hardware_mode in cold combined; do
    cntools_wallet_register_reset_chain_state
    CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${REPO_ROOT}/files/tests/fixtures/transaction-protocol-conway.json"
    CNTOOLS_WALLET_REGISTER_DEPOSIT=0 CNTOOLS_WALLET_REGISTER_BACKEND=koios CNTOOLS_POOL_RETIRE_EPOCH=101 CNTOOLS_WALLET_REGISTER_LIFETIME=0
    CNTOOLS_POOL_REG_COLD_SOURCE="${pool}/cold.hwsfile" CNTOOLS_POOL_REG_COMBINE_HARDWARE=N
    CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE="${payer}/payment.skey"
    if [[ "${hardware_mode}" == combined ]]; then CNTOOLS_POOL_REG_COMBINE_HARDWARE=Y; CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE="${payer}/payment.hwsfile"; fi
    cntools_utxo_add "${ref}" "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" 20000000
    cntools_wallet_register_inventory_use_all
    hardware_calls=0; package=''
    cntools_pool_registration_build_into package || fail 'hardware retirement build'
    eq "${CNTOOLS_TRANSACTION_PACKAGE_HARDWARE_PREPARED}" Y
    signed="${TEST_ROOT}/hardware-${hardware_mode}.signed"
    cntools_transaction_sign_registered "${package}" "${signed}" || fail 'hardware retirement witness dispatch'
    cntools_transaction_package_load "${signed}"; eq "${CNTOOLS_TRANSACTION_COMPLETE}" Y; eq "${hardware_calls}" 1
    size="$(jq -r '.cborHex|length/2' "${CNTOOLS_TRANSACTION_SIGNED_FILE}")"
    ((CNTOOLS_WALLET_REGISTER_FEE==155381+44*(size-1))) || fail 'non-exact hardware retirement signed fee'
    printf 'Pinned pool retirement hardware-boundary test passed: %s\n' "${hardware_mode}"
  done
)
[[ "$(cksum "${pool}/cold.counter" "${pool}/cold.skey" "${pool}/cold.vkey")" == "${before}" ]] || fail 'retirement changed cold artifacts'
cntools_transaction_cleanup
printf 'CNTools pool retirement pinned tests passed (cnode CLI %s).\n' "${version}"
