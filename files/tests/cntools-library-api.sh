#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools library API tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_LIBRARY="${REPO_ROOT}/scripts/common-helper-scripts/cntools.library"
ENV_LIBRARY="${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library"
FIXTURE_ROOT="${REPO_ROOT}/files/tests/fixtures/cntools-koios"
STATE_FIXTURE="${FIXTURE_ROOT}/global-state.json"
COLLISION_FIXTURE="${FIXTURE_ROOT}/global-collisions.json"
REQUEST_FIXTURE="${FIXTURE_ROOT}/curl-argv.json"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-library-api.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
BASE_PATH="${PATH}"
FAKE_BIN="${TEST_ROOT}/fake-bin"
CURL_LOG="${TEST_ROOT}/curl.log"
UNEXPECTED_NETWORK_LOG="${TEST_ROOT}/unexpected-network.log"

cleanup_test() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="$3"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

assert_contains() {
  local content="$1"
  local expected="$2"
  local context="$3"
  [[ "${content}" == *"${expected}"* ]] ||
    fail "${context}: missing '${expected}'"
}

assert_var_unset() {
  local variable_name="$1"
  local context="$2"
  ! declare -p "${variable_name}" >/dev/null 2>&1 ||
    fail "${context}: ${variable_name} is set"
}

assert_assoc_value() {
  local array_name="$1"
  local key="$2"
  local expected="$3"
  local context="$4"
  local -n array_ref="${array_name}"
  [[ -n ${array_ref[${key}]+_} ]] ||
    fail "${context}: ${array_name}[${key}] is unset"
  assert_eq "${array_ref[${key}]}" "${expected}" "${context}"
}

assert_assoc_key_unset() {
  local array_name="$1"
  local key="$2"
  local context="$3"
  local -n array_ref="${array_name}"
  [[ -z ${array_ref[${key}]+_} ]] ||
    fail "${context}: unexpected ${array_name}[${key}]"
}

for required_command in awk cat comm diff jq sed sort tail uname; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

[[ -f "${CNTOOLS_LIBRARY}" && -f "${ENV_LIBRARY}" ]] ||
  fail "CNTools library sources are missing"
jq -e '
  .schemaVersion == 1 and
  (.calls | type == "array" and length == 3) and
  ([.calls[].id] | length == (unique | length)) and
  all(.calls[];
    (.id | type == "string" and length > 0) and
    (.helper | type == "string" and length > 0) and
    (.resultGlobals | type == "array") and
    (.incidentalGlobals | type == "array") and
    (.expectedNewGlobals | type == "array") and
    ((.resultGlobals + .incidentalGlobals | sort) ==
     (.expectedNewGlobals | sort)) and
    (.expectedNewGlobals | length == (unique | length))
  )
' "${STATE_FIXTURE}" >/dev/null ||
  fail "global-state fixture is invalid"
jq -e '
  .schemaVersion == 1 and
  (.requests | type == "array" and length == 16) and
  ([.requests[].id] | length == (unique | length)) and
  all(.requests[];
    (.id | type == "string" and length > 0) and
    (.argv | type == "array" and length > 1) and
    (.argv[0] == "curl") and
    all(.argv[]; type == "string")
  )
' "${REQUEST_FIXTURE}" >/dev/null ||
  fail "curl argv fixture is invalid"
jq -e '
  .schemaVersion == 1 and
  (.calls | type == "array" and length == 3) and
  ([.calls[].id] | length == (unique | length)) and
  all(.calls[];
    (.id | type == "string" and length > 0) and
    (.helper | type == "string" and length > 0) and
    (.variables | type == "array" and length > 0) and
    ([.variables[].name] | length == (unique | length)) and
    all(.variables[];
      (.name | type == "string" and length > 0) and
      (.seed.type | IN("scalar", "integer", "indexed", "associative")) and
      (.expected.type | IN("scalar", "integer", "indexed", "associative")) and
      (.behavior | type == "string" and length > 0)
    )
  )
' "${COLLISION_FIXTURE}" >/dev/null ||
  fail "global collision fixture is invalid"

mkdir -p "${FAKE_BIN}"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "curl" >> "${CNTOOLS_CURL_LOG:?}"' \
  'for argument do printf "\\t%s" "${argument}" >> "${CNTOOLS_CURL_LOG:?}"; done' \
  'printf "\\n" >> "${CNTOOLS_CURL_LOG:?}"' \
  'status=${CNTOOLS_FAKE_CURL_STATUS:-0}' \
  'if [ "${status}" -ne 0 ]; then' \
  '  printf "%s\\n" "${CNTOOLS_FAKE_CURL_ERROR:-fake curl failure}" >&2' \
  '  exit "${status}"' \
  'fi' \
  'fixture=${CNTOOLS_FAKE_CURL_FIXTURE:-}' \
  '[ -n "${fixture}" ] || exit 0' \
  '[ -f "${fixture}" ] && [ ! -L "${fixture}" ] || exit 96' \
  'cat -- "${fixture}"' \
  > "${FAKE_BIN}/curl"
chmod 0755 "${FAKE_BIN}/curl"

for network_command in wget git ssh nc; do
  printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\\n" "${0##*/}" >> "${CNTOOLS_UNEXPECTED_NETWORK_LOG:?}"' \
    'exit 97' \
    > "${FAKE_BIN}/${network_command}"
  chmod 0755 "${FAKE_BIN}/${network_command}"
done

export PATH="${FAKE_BIN}:${BASE_PATH}"
export CNTOOLS_CURL_LOG="${CURL_LOG}"
export CNTOOLS_UNEXPECTED_NETWORK_LOG="${UNEXPECTED_NETWORK_LOG}"
export http_proxy=http://127.0.0.1:9
export https_proxy=http://127.0.0.1:9
export HTTP_PROXY=http://127.0.0.1:9
export HTTPS_PROXY=http://127.0.0.1:9
: > "${CURL_LOG}"
: > "${UNEXPECTED_NETWORK_LOG}"

# Supply only the ambient state required by the legacy source contract. The
# shared env library provides the real hex decoder used by the Koios address
# parser; it has no runtime initialization in this fixture.
HOME="${TEST_ROOT}/home"
TMP_DIR="${TEST_ROOT}/runtime/tmp"
WALLET_FOLDER="${TEST_ROOT}/runtime/wallet"
POOL_FOLDER="${TEST_ROOT}/runtime/pool"
ASSET_FOLDER="${TEST_ROOT}/runtime/asset"
LOG_DIR="${TEST_ROOT}/runtime/logs"
CNTOOLS_MODE="LIGHT"
NETWORK_NAME="Preview"
ADVANCED_MODE="false"
ENABLE_ADVANCED="false"
ENABLE_CHATTR="false"
FG_BLUE="blue"
FG_GREEN="green"
FG_GRAY="gray"
FG_RED="red"
NC="none"
KOIOS_API="https://koios.invalid/api/v1"
KOIOS_API_HEADERS=()
CURL_TIMEOUT=1
mkdir -p "${HOME}" "${LOG_DIR}"

myExit() {
  fail "legacy cntools.library source-time initialization failed: $*"
}

set +u
. "${ENV_LIBRARY}"
. "${CNTOOLS_LIBRARY}"
set -u

# Inventories below require these helper outputs and scratch names to start
# absent even if a developer happens to export a similarly named variable.
unset HEADERS _reward_addr account_info_list addr_list addr_list_joined
unset asset_amount_maxlen_arr asset_name_maxlen_arr assets delegated_drep
unset delegated_pool deposit pool_delegations response reward_addr_list
unset reward_status rewards_available stake_address stake_deposits status
unset tx_in_arr utxos utxos_cnt vote_action_count vote_delegations

# Keep API diagnostics deterministic and away from the production history log.
println() { :; }
logln() { :; }
# Asset quantity formatting is presentation-only and the production helper uses
# GNU sed syntax that is unavailable on macOS. Keep this parser suite portable
# by returning the unformatted integer; parsing and stored values are unchanged.
formatAsset() { printf '%s\n' "$1"; }

# CNTools production does not enable nounset, and these legacy helpers read
# unset array entries while accumulating results. Keep the harness strict but
# execute only the helper call with production-compatible nounset semantics.
call_legacy_helper() {
  local legacy_call_status
  set +u
  "$@"
  legacy_call_status=$?
  set -u
  return "${legacy_call_status}"
}

configure_fake_curl() {
  local fixture="$1"
  local status="${2:-0}"
  local error_text="${3:-fake curl failure}"
  export CNTOOLS_FAKE_CURL_FIXTURE="${fixture}"
  export CNTOOLS_FAKE_CURL_STATUS="${status}"
  export CNTOOLS_FAKE_CURL_ERROR="${error_text}"
  : > "${CURL_LOG}"
}

assert_exact_curl_call() {
  local contract_id="$1"
  local expected_file="${TEST_ROOT}/${contract_id}.curl.expected"
  jq -r --arg id "${contract_id}" \
    '.requests[] | select(.id == $id) | .argv | join("\t")' \
    "${REQUEST_FIXTURE}" > "${expected_file}"
  [[ -s "${expected_file}" ]] ||
    fail "curl argv contract is missing: ${contract_id}"
  diff -u "${expected_file}" "${CURL_LOG}" ||
    fail "curl argv changed for ${contract_id}"
}

snapshot_variable_names() {
  local destination="$1"
  compgen -A variable | LC_ALL=C sort -u > "${destination}"
}

assert_global_inventory() {
  local contract_id="$1"
  local before_file="$2"
  local after_file="$3"
  local actual_new="$4"
  local expected_new="$5"
  local removed="$6"

  comm -13 "${before_file}" "${after_file}" > "${actual_new}"
  jq -r --arg id "${contract_id}" \
    '.calls[] | select(.id == $id) | .expectedNewGlobals[]' \
    "${STATE_FIXTURE}" | LC_ALL=C sort > "${expected_new}"
  diff -u "${expected_new}" "${actual_new}" ||
    fail "global variables created by ${contract_id} changed"

  comm -23 "${before_file}" "${after_file}" > "${removed}"
  [[ ! -s "${removed}" ]] ||
    fail "${contract_id} removed caller variables: $(< "${removed}")"
}

variable_type() {
  local variable_name="$1"
  local declaration
  declaration="$(declare -p "${variable_name}" 2>/dev/null)" || return 1
  case "${declaration}" in
    'declare -a '*) printf 'indexed\n' ;;
    'declare -A '*) printf 'associative\n' ;;
    'declare -i '*) printf 'integer\n' ;;
    'declare -- '*) printf 'scalar\n' ;;
    *) printf 'other\n' ;;
  esac
}

assert_collision_variable() {
  local contract_id="$1"
  local variable_name="$2"
  local phase="$3"
  local expected_type actual_type expected_value expected_count index key value
  local -n collision_ref="${variable_name}"

  expected_type="$(jq -r \
    --arg id "${contract_id}" \
    --arg name "${variable_name}" \
    --arg phase "${phase}" \
    '.calls[] | select(.id == $id) | .variables[] |
     select(.name == $name) | .[$phase].type' \
    "${COLLISION_FIXTURE}")"
  actual_type="$(variable_type "${variable_name}")" ||
    fail "${contract_id} ${phase}: ${variable_name} is unset"
  assert_eq "${actual_type}" "${expected_type}" \
    "${contract_id} ${phase} type for ${variable_name}"

  case "${expected_type}" in
    scalar|integer)
      expected_value="$(jq -r \
        --arg id "${contract_id}" \
        --arg name "${variable_name}" \
        --arg phase "${phase}" \
        '.calls[] | select(.id == $id) | .variables[] |
         select(.name == $name) | .[$phase].value' \
        "${COLLISION_FIXTURE}")"
      assert_eq "${collision_ref}" "${expected_value}" \
        "${contract_id} ${phase} value for ${variable_name}"
      ;;
    indexed)
      expected_count="$(jq -r \
        --arg id "${contract_id}" \
        --arg name "${variable_name}" \
        --arg phase "${phase}" \
        '.calls[] | select(.id == $id) | .variables[] |
         select(.name == $name) | .[$phase].values | length' \
        "${COLLISION_FIXTURE}")"
      assert_eq "${#collision_ref[@]}" "${expected_count}" \
        "${contract_id} ${phase} size for ${variable_name}"
      for ((index=0; index<expected_count; index++)); do
        expected_value="$(jq -r \
          --arg id "${contract_id}" \
          --arg name "${variable_name}" \
          --arg phase "${phase}" \
          --argjson index "${index}" \
          '.calls[] | select(.id == $id) | .variables[] |
           select(.name == $name) | .[$phase].values[$index]' \
          "${COLLISION_FIXTURE}")"
        assert_eq "${collision_ref[index]}" "${expected_value}" \
          "${contract_id} ${phase} ${variable_name}[${index}]"
      done
      ;;
    associative)
      expected_count="$(jq -r \
        --arg id "${contract_id}" \
        --arg name "${variable_name}" \
        --arg phase "${phase}" \
        '.calls[] | select(.id == $id) | .variables[] |
         select(.name == $name) | .[$phase].entries | length' \
        "${COLLISION_FIXTURE}")"
      assert_eq "${#collision_ref[@]}" "${expected_count}" \
        "${contract_id} ${phase} size for ${variable_name}"
      while IFS=$'\t' read -r key value; do
        assert_assoc_value "${variable_name}" "${key}" "${value}" \
          "${contract_id} ${phase} entry"
      done < <(jq -r \
        --arg id "${contract_id}" \
        --arg name "${variable_name}" \
        --arg phase "${phase}" \
        '.calls[] | select(.id == $id) | .variables[] |
         select(.name == $name) | .[$phase].entries |
         to_entries[] | [.key, .value] | @tsv' \
        "${COLLISION_FIXTURE}")
      while IFS= read -r key; do
        assert_assoc_key_unset "${variable_name}" "${key}" \
          "${contract_id} ${phase} absent key"
      done < <(jq -r \
        --arg id "${contract_id}" \
        --arg name "${variable_name}" \
        --arg phase "${phase}" \
        '.calls[] | select(.id == $id) | .variables[] |
         select(.name == $name) | (.[$phase].absentKeys // [])[]' \
        "${COLLISION_FIXTURE}")
      ;;
  esac
}

assert_collision_state() {
  local contract_id="$1"
  local phase="$2"
  local variable_name
  while IFS= read -r variable_name; do
    assert_collision_variable "${contract_id}" "${variable_name}" "${phase}"
  done < <(jq -r --arg id "${contract_id}" \
    '.calls[] | select(.id == $id) | .variables[].name' \
    "${COLLISION_FIXTURE}")
}

test_address_success_inventory() (
  local call_status=0
  local prefix token_key
  local before_file="${TEST_ROOT}/address-success.before"
  local after_file="${TEST_ROOT}/address-success.after"
  local actual_new="${TEST_ROOT}/address-success.new"
  local expected_new="${TEST_ROOT}/address-success.expected"
  local removed="${TEST_ROOT}/address-success.removed"

  configure_fake_curl "${FIXTURE_ROOT}/address-utxos-success.csv"
  declare -ga addr_list=(addr_test1 addr_test2)
  snapshot_variable_names "${before_file}"
  call_legacy_helper getBalanceKoios true || call_status=$?
  snapshot_variable_names "${after_file}"

  assert_eq "${call_status}" "0" "address success status"
  assert_assoc_value assets "addr_test1,lovelace" 1500000 \
    "first address lovelace"
  assert_assoc_value assets "addr_test2,lovelace" 2500000 \
    "second address lovelace"
  prefix="11111111111111111111111111111111111111111111111111111111"
  token_key="addr_test1,${prefix}.546f6b656e"
  assert_assoc_value assets "${token_key}" 42 "native asset quantity"
  assert_assoc_value utxos_cnt addr_test1 1 "first address UTxO count"
  assert_assoc_value utxos_cnt addr_test2 1 "second address UTxO count"
  assert_contains "${tx_in_arr[addr_test1]}" \
    '--tx-in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#0' \
    "first address transaction input"
  assert_global_inventory getBalanceKoios.success \
    "${before_file}" "${after_file}" "${actual_new}" "${expected_new}" "${removed}"
  assert_exact_curl_call address-success
)

test_address_empty() (
  local call_status=0
  configure_fake_curl "${FIXTURE_ROOT}/empty.response"
  declare -ga addr_list=(addr_empty)
  call_legacy_helper getBalanceKoios true || call_status=$?
  assert_eq "${call_status}" "0" "empty address response status"
  assert_eq "${#assets[@]}" "0" "empty address assets"
  assert_eq "${#utxos[@]}" "0" "empty address UTxOs"
  assert_exact_curl_call address-empty
)

test_address_malformed() (
  local call_status=0
  local stderr_file="${TEST_ROOT}/address-malformed.stderr"
  configure_fake_curl "${FIXTURE_ROOT}/address-utxos-malformed.csv"
  declare -ga addr_list=(addr_malformed)
  call_legacy_helper getBalanceKoios true 2> "${stderr_file}" || call_status=$?
  assert_eq "${call_status}" "0" "malformed nested asset response status"
  assert_assoc_value assets "addr_malformed,lovelace" 700000 \
    "malformed response retains outer lovelace field"
  assert_eq "${#assets[@]}" "1" \
    "malformed nested asset data is skipped"
  [[ -s "${stderr_file}" ]] ||
    fail "malformed nested asset JSON produced no parser diagnostic"
  assert_exact_curl_call address-malformed
)

test_address_transport_failure() (
  local simulated_status="$1"
  local label="$2"
  local call_status=0
  configure_fake_curl "${FIXTURE_ROOT}/address-utxos-success.csv" \
    "${simulated_status}" "simulated ${label}"
  declare -ga addr_list=(addr_transport_failure)
  call_legacy_helper getBalanceKoios true || call_status=$?
  assert_eq "${call_status}" "1" "address ${label} maps to helper failure"
  assert_eq "${#assets[@]}" "0" "address ${label} leaves empty assets"
  assert_exact_curl_call "address-${label}"
)

test_rewards_success_inventory() (
  local call_status=0
  local before_file="${TEST_ROOT}/rewards-success.before"
  local after_file="${TEST_ROOT}/rewards-success.after"
  local actual_new="${TEST_ROOT}/rewards-success.new"
  local expected_new="${TEST_ROOT}/rewards-success.expected"
  local removed="${TEST_ROOT}/rewards-success.removed"

  configure_fake_curl "${FIXTURE_ROOT}/account-info-success.csv"
  declare -ga reward_addr_list=(stake_test1 stake_test2 stake_missing)
  snapshot_variable_names "${before_file}"
  call_legacy_helper getRewardInfoKoios || call_status=$?
  snapshot_variable_names "${after_file}"

  assert_eq "${call_status}" "0" "reward success status"
  assert_assoc_value reward_status stake_test1 registered \
    "first reward registration"
  assert_assoc_value rewards_available stake_test1 1234567 \
    "first available rewards"
  assert_assoc_value pool_delegations stake_test1 pool1 \
    "first pool delegation"
  assert_assoc_value vote_delegations stake_test1 alwaysAbstain \
    "first vote delegation"
  assert_assoc_value vote_delegations stake_test2 alwaysNoConfidence \
    "second vote delegation"
  assert_assoc_value stake_deposits stake_test2 2000000 \
    "second stake deposit"
  assert_assoc_value reward_status stake_missing 'not registered' \
    "missing account default status"
  assert_assoc_value rewards_available stake_missing 0 \
    "missing account default rewards"
  assert_assoc_key_unset pool_delegations stake_missing \
    "missing account pool delegation"
  assert_global_inventory getRewardInfoKoios.success \
    "${before_file}" "${after_file}" "${actual_new}" "${expected_new}" "${removed}"
  assert_exact_curl_call rewards-success
)

test_rewards_empty() (
  local call_status=0
  configure_fake_curl "${FIXTURE_ROOT}/empty.response"
  declare -ga reward_addr_list=(stake_empty)
  call_legacy_helper getRewardInfoKoios || call_status=$?
  assert_eq "${call_status}" "0" "empty reward response status"
  assert_assoc_value reward_status stake_empty 'not registered' \
    "empty reward default status"
  assert_assoc_value rewards_available stake_empty 0 \
    "empty reward default amount"
  assert_assoc_key_unset pool_delegations stake_empty \
    "empty reward pool delegation"
  assert_exact_curl_call rewards-empty
)

test_rewards_malformed() (
  local call_status=0
  configure_fake_curl "${FIXTURE_ROOT}/account-info-malformed.csv"
  declare -ga reward_addr_list=(stake_expected)
  call_legacy_helper getRewardInfoKoios || call_status=$?
  assert_eq "${call_status}" "0" "malformed reward response status"
  assert_assoc_value reward_status stake_expected 'not registered' \
    "malformed reward preserves requested-address default"
  assert_assoc_value reward_status not-a-stake-address registered \
    "malformed reward creates unexpected-address status"
  assert_exact_curl_call rewards-malformed
)

test_governance_success_inventory() (
  local call_status=0
  local before_file="${TEST_ROOT}/governance-success.before"
  local after_file="${TEST_ROOT}/governance-success.after"
  local actual_new="${TEST_ROOT}/governance-success.new"
  local expected_new="${TEST_ROOT}/governance-success.expected"
  local removed="${TEST_ROOT}/governance-success.removed"

  configure_fake_curl "${FIXTURE_ROOT}/proposal-count-success.csv"
  snapshot_variable_names "${before_file}"
  call_legacy_helper getActiveGovActionCount || call_status=$?
  snapshot_variable_names "${after_file}"

  assert_eq "${call_status}" "0" "governance count success status"
  assert_eq "${vote_action_count}" "7" "governance action count"
  assert_global_inventory getActiveGovActionCount.success \
    "${before_file}" "${after_file}" "${actual_new}" "${expected_new}" "${removed}"
  assert_exact_curl_call governance-success
)

test_governance_empty() (
  local call_status=0
  configure_fake_curl "${FIXTURE_ROOT}/empty.response"
  vote_action_count=stale
  call_legacy_helper getActiveGovActionCount || call_status=$?
  assert_eq "${call_status}" "0" "empty governance count status"
  assert_eq "${vote_action_count}" "" \
    "empty governance count clears stale output"
  assert_exact_curl_call governance-empty
)

test_governance_malformed() (
  local call_status=0
  configure_fake_curl "${FIXTURE_ROOT}/proposal-count-malformed.csv"
  call_legacy_helper getActiveGovActionCount || call_status=$?
  assert_eq "${call_status}" "0" "malformed governance count status"
  assert_eq "${vote_action_count}" "not-a-number" \
    "malformed governance count is accepted verbatim"
  assert_exact_curl_call governance-malformed
)

test_governance_transport_failure() (
  local simulated_status="$1"
  local label="$2"
  local call_status=0
  configure_fake_curl "${FIXTURE_ROOT}/proposal-count-success.csv" \
    "${simulated_status}" "simulated ${label}"
  vote_action_count=stale
  call_legacy_helper getActiveGovActionCount || call_status=$?
  assert_eq "${call_status}" "1" "governance ${label} maps to helper failure"
  assert_eq "${vote_action_count}" stale \
    "governance ${label} retains stale output"
  assert_exact_curl_call "governance-${label}"
)

test_balance_preexisting_globals() (
  local call_status=0
  local contract_id=getBalanceKoios.preexisting
  configure_fake_curl "${FIXTURE_ROOT}/address-utxos-success.csv"
  declare -ga addr_list=(addr_test1 addr_test2)
  declare -ga HEADERS=(sentinel-header)
  declare -g -- assets=sentinel-assets
  declare -gA utxos_cnt=([sentinel]=9)
  assert_collision_state "${contract_id}" seed

  call_legacy_helper getBalanceKoios true || call_status=$?
  assert_eq "${call_status}" "0" "pre-existing balance globals status"
  assert_collision_state "${contract_id}" expected
  assert_exact_curl_call collision-balance
)

test_rewards_preexisting_globals() (
  local call_status=0
  local contract_id=getRewardInfoKoios.preexisting
  configure_fake_curl "${FIXTURE_ROOT}/account-info-success.csv"
  declare -ga reward_addr_list=(stake_test1 stake_test2 stake_missing)
  declare -ga HEADERS=(sentinel-header)
  declare -g -- reward_status=sentinel-status
  declare -gA rewards_available=([sentinel]=999)
  declare -g -- status=sentinel-row-status
  declare -gi deposit=9
  assert_collision_state "${contract_id}" seed

  call_legacy_helper getRewardInfoKoios || call_status=$?
  assert_eq "${call_status}" "0" "pre-existing reward globals status"
  assert_collision_state "${contract_id}" expected
  assert_exact_curl_call collision-rewards
)

test_governance_preexisting_globals() (
  local call_status=0
  local contract_id=getActiveGovActionCount.preexisting
  configure_fake_curl "${FIXTURE_ROOT}/proposal-count-success.csv"
  declare -ga HEADERS=(sentinel-header)
  declare -g -- response=sentinel-response
  declare -gi vote_action_count=99
  assert_collision_state "${contract_id}" seed

  call_legacy_helper getActiveGovActionCount || call_status=$?
  assert_eq "${call_status}" "0" "pre-existing governance globals status"
  assert_collision_state "${contract_id}" expected
  assert_exact_curl_call collision-governance
)

test_address_success_inventory
test_address_empty
test_address_malformed
test_address_transport_failure 28 timeout
test_address_transport_failure 130 cancellation
test_rewards_success_inventory
test_rewards_empty
test_rewards_malformed
test_governance_success_inventory
test_governance_empty
test_governance_malformed
test_governance_transport_failure 28 timeout
test_governance_transport_failure 130 cancellation
test_balance_preexisting_globals
test_rewards_preexisting_globals
test_governance_preexisting_globals

[[ ! -s "${UNEXPECTED_NETWORK_LOG}" ]] ||
  fail "unexpected network command attempted: $(< "${UNEXPECTED_NETWORK_LOG}")"

printf 'CNTools library API characterization tests passed\n'
