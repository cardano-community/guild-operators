#!/usr/bin/env bash
# Wallet stake-registration transaction acceptance tests.
# shellcheck disable=SC1090,SC2034,SC2153,SC2154,SC2317,SC2329

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet registration tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-register.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
CNTOOLS_TMP_DIR="${TEST_ROOT}/tmp"
FAKE_CLI="${TEST_ROOT}/cardano-cli"
CLI_TRACE="${TEST_ROOT}/cardano-cli.trace"
LOG_TRACE="${TEST_ROOT}/cntools.log"
PAYMENT_KEY="$(printf '11%.0s' {1..32})"
STAKE_KEY="$(printf '22%.0s' {1..32})"
PAYMENT_CREDENTIAL="${PAYMENT_KEY:0:56}"
STAKE_CREDENTIAL="${STAKE_KEY:0:56}"
TX_A="$(printf 'aa%.0s' {1..32})"
TX_B="$(printf 'bb%.0s' {1..32})"
TX_C="$(printf 'dd%.0s' {1..32})"
POLICY="$(printf 'cc%.0s' {1..28})"
ASSET_NAME="74657374"

cleanup_test() {
  chmod -R u+rwx -- "${TEST_ROOT}" 2>/dev/null || true
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
  local context="${3:-values differ}"

  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

assert_file_contains() {
  local file="$1"
  local value="$2"
  local context="${3:-file content missing}"

  grep -F -- "${value}" "${file}" >/dev/null ||
    fail "${context}: '${value}' was not found"
}

assert_pinned_cardano_cli_versions() {
  local implementation=""
  local manifest=""
  local version=""

  for implementation in cnode dingo amaru; do
    manifest="${REPO_ROOT}/files/node-implementations/${implementation}/release.json"
    version="$(jq -er '.companions["cardano-cli"].version' "${manifest}")" ||
      fail "${implementation} does not pin a Cardano CLI companion"
    assert_eq "${version}" "11.0.0.0" \
      "${implementation} Cardano CLI registration-test contract"
  done
}

write_vkey() {
  local file="$1"
  local role="$2"
  local key="$3"
  local type="PaymentVerificationKeyShelley_ed25519"

  [[ "${role}" != "stake" ]] || type="StakeVerificationKeyShelley_ed25519"
  jq -n --arg type "${type}" --arg cbor "5820${key}" '
    {type: $type, description: "Test verification key", cborHex: $cbor}
  ' > "${file}"
  chmod 0600 "${file}"
}

for required in awk bash chmod grep jq mktemp rm sort; do
  command -v "${required}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required}"
done

mkdir -p "${CNTOOLS_TMP_DIR}"
chmod 0700 "${TEST_ROOT}" "${CNTOOLS_TMP_DIR}"
: > "${CLI_TRACE}"
: > "${LOG_TRACE}"
chmod 0600 "${CLI_TRACE}" "${LOG_TRACE}"
assert_pinned_cardano_cli_versions

cat > "${FAKE_CLI}" <<'FAKE_CLI_EOF'
#!/usr/bin/env bash
set -euo pipefail

arg_value() {
  local wanted="$1"
  shift
  while (( $# > 0 )); do
    if [[ "$1" == "${wanted}" ]]; then
      (( $# >= 2 )) || exit 90
      printf '%s\n' "$2"
      return 0
    fi
    shift
  done
  return 1
}

jq -cn --args '$ARGS.positional' -- "$@" >> "${FAKE_CLI_TRACE}"
path="${1:-}/${2:-}/${3:-}"
case "${path}" in
  version//)
    printf 'cardano-cli 11.0.0.0 - linux-x86_64\n'
    ;;
  latest/stake-address/key-hash)
    key="$(arg_value --stake-verification-key "$@")"
    printf '%s\n' "${key:0:56}"
    ;;
  query/stake-address-info/--address)
    reward="$(arg_value --address "$@")"
    jq -n --arg reward "${reward}" '[{
      address: $reward,
      stakeDelegation: null,
      voteDelegation: null,
      rewardAccountBalance: 0,
      stakeRegistrationDeposit: 2345678,
      govActionDeposits: {}
    }]'
    ;;
  latest/stake-address/registration-certificate|latest/stake-address/deregistration-certificate)
    output="$(arg_value --out-file "$@")"
    description="Stake registration"
    [[ "${path}" != *'/deregistration-certificate' ]] ||
      description="Stake de-registration"
    jq -n --arg description "${description}" '
      {type: "CertificateConway", description: $description,
       cborHex: "82008200581caaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    ' > "${output}"
    ;;
  latest/transaction/calculate-min-required-utxo)
    printf 'Lovelace 1000000\n'
    ;;
  latest/transaction/build|latest/transaction/build-estimate)
    output="$(arg_value --out-file "$@")"
    required='[]'
    arguments=("$@")
    for (( index = 0; index < ${#arguments[@]}; index++ )); do
      [[ "${arguments[index]}" == "--required-signer-hash" ]] || continue
      required="$(jq -c --arg value "${arguments[index + 1]}" \
        '. + [$value]' <<< "${required}")"
    done
    jq -n --argjson required "${required}" '
      {
        type: "Tx ConwayEra",
        description: "Fake registration transaction",
        cborHex: "aa00",
        fakeView: {
          "validity range": {"lower bound": null, "upper bound": null},
          "required signers (payment key hashes needed for scripts)": $required,
          "reference inputs": [],
          scripts: [],
          witnesses: []
        }
      }
    ' > "${output}"
    ;;
  latest/transaction/txid)
    printf '%064d\n' 7
    ;;
  debug/transaction/view)
    file="$(arg_value --tx-body-file "$@" 2>/dev/null ||
      arg_value --tx-file "$@")"
    jq -e '.fakeView' "${file}"
    ;;
  *)
    printf 'unsupported fake command: %s\n' "${path}" >&2
    exit 91
    ;;
esac
FAKE_CLI_EOF
chmod 0700 "${FAKE_CLI}"
export FAKE_CLI_TRACE="${CLI_TRACE}"

# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/log.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/number.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet-query.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/utxo.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/transaction.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/transaction-build.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/transaction-sign.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/transaction-submit.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/coin-selection.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/change-plan.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet-register.sh"

cntools_log() {
  printf '%s\t%s\n' "${1:-INFO}" "${2:-}" >> "${LOG_TRACE}"
}

CNTOOLS_ACTION_ID="wallet/register"
CNTOOLS_CLI="${FAKE_CLI}"
CNTOOLS_CLI_TIMEOUT=3
CNTOOLS_TRANSACTION_TIMEOUT=3
CNTOOLS_TIMEOUT_BIN=""
CNTOOLS_NETWORK="preview"
CNTOOLS_MODE="light"
CNTOOLS_LOCAL_CLI_CAPABLE="false"
CNTOOLS_SOCKET="${TEST_ROOT}/missing.socket"
CNTOOLS_KOIOS_ENABLED="Y"
CNTOOLS_KOIOS_API="https://preview.koios.rest/api/v1"
CNTOOLS_TX_SELECTION_STRATEGY="balanced"
CNTOOLS_TX_TOKEN_FRAGMENTATION="N"
CNTOOLS_TX_TOKEN_MAX_ASSETS=20
CNTOOLS_TX_UTXO_MANAGEMENT="N"
CNTOOLS_TX_UTXO_TARGET_COUNT=4
CNTOOLS_TX_UTXO_PERCENTAGES="10,20,30"
CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS=3
CNTOOLS_TX_UTXO_MIN_LOVELACE="2000000"
CNTOOLS_TX_COLLATERAL_MANAGEMENT="Y"
CNTOOLS_TX_COLLATERAL_TARGET_COUNT=1
CNTOOLS_TX_COLLATERAL_LOVELACE="5000000"
CNTOOLS_WALLET_REGISTER_WALLET="Registration_test"
CNTOOLS_WALLET_REGISTER_WALLET_TYPE="CLI"
CNTOOLS_WALLET_REGISTER_BASE_ADDRESS="addr_test1_base"
CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS="addr_test1_payment"
CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS="stake_test1_reward"
CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY="${TEST_ROOT}/payment.vkey"
CNTOOLS_WALLET_REGISTER_STAKE_VKEY="${TEST_ROOT}/stake.vkey"
CNTOOLS_WALLET_REGISTER_PAYMENT_CREDENTIAL="${PAYMENT_CREDENTIAL}"
CNTOOLS_WALLET_REGISTER_STAKE_CREDENTIAL="${STAKE_CREDENTIAL}"
CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE=""
CNTOOLS_WALLET_REGISTER_STAKE_SOURCE=""
CNTOOLS_WALLET_REGISTER_CAN_SIGN="N"
write_vkey "${CNTOOLS_WALLET_REGISTER_PAYMENT_VKEY}" payment "${PAYMENT_KEY}"
write_vkey "${CNTOOLS_WALLET_REGISTER_STAKE_VKEY}" stake "${STAKE_KEY}"

test_local_utxo_parser() {
  local fixture="${TEST_ROOT}/local-utxos.json"

  jq -n --arg first "${TX_A}#0" --arg second "${TX_B}#1" \
    --arg policy "${POLICY}" --arg asset "${ASSET_NAME}" '
      {
        ($first): {
          address: "addr_test1_base",
          value: {lovelace: 3000000, ($policy): {($asset): 2}}
        },
        ($second): {
          address: "addr_test1_payment",
          value: {lovelace: 4500000, ($policy): {($asset): 3}}
        }
      }
    ' > "${fixture}"
  chmod 0600 "${fixture}"
  cntools_wallet_register_reset_chain_state
  cntools_wallet_register_parse_local_utxos "${fixture}" ||
    fail "valid local UTxOs were rejected"
  assert_eq "${#CNTOOLS_WALLET_REGISTER_INPUTS[@]}" 2 \
    "local input count"
  assert_eq "${CNTOOLS_WALLET_REGISTER_LOVELACE}" 7500000 \
    "local lovelace aggregation"
  assert_eq "${CNTOOLS_WALLET_REGISTER_ASSETS[${POLICY}.${ASSET_NAME}]}" 5 \
    "local asset aggregation"
  assert_eq "${CNTOOLS_WALLET_REGISTER_TOTAL_VALUE}" \
    "7500000 + 5 ${POLICY}.${ASSET_NAME}" \
    "local build-estimate total value"
}

test_koios_utxo_parser() {
  local fixture="${TEST_ROOT}/koios-utxos.json"

  jq -n --arg tx_a "${TX_A}" --arg tx_b "${TX_B}" \
    --arg policy "${POLICY}" --arg asset "${ASSET_NAME}" '
      [
        {tx_hash: $tx_a, tx_index: 0, address: "addr_test1_base",
         value: "3000000",
         asset_list: [{policy_id: $policy, asset_name: $asset,
                       quantity: "2"}]},
        {tx_hash: $tx_b, tx_index: 1, address: "addr_test1_payment",
         value: "4500000",
         asset_list: [{policy_id: $policy, asset_name: $asset,
                       quantity: "3"}]}
      ]
    ' > "${fixture}"
  chmod 0600 "${fixture}"
  cntools_wallet_register_reset_chain_state
  cntools_wallet_register_parse_koios_utxos "${fixture}" ||
    fail "valid Koios UTxOs were rejected"
  assert_eq "${#CNTOOLS_WALLET_REGISTER_INPUTS[@]}" 2 \
    "Koios input count"
  assert_eq "${CNTOOLS_WALLET_REGISTER_LOVELACE}" 7500000 \
    "Koios lovelace aggregation"
  assert_eq "${CNTOOLS_WALLET_REGISTER_ASSETS[${POLICY}.${ASSET_NAME}]}" 5 \
    "Koios asset aggregation"

  jq -n '[{tx_hash: "bad", tx_index: 0, address: "addr_test1_base",
            value: "1", asset_list: []}]' > "${fixture}"
  if cntools_wallet_register_parse_koios_utxos "${fixture}"; then
    fail "an invalid Koios transaction reference was accepted"
  fi
}

test_koios_stake_deposit_query() {
  local captured_endpoint=""

  cntools_wallet_query_http() {
    captured_endpoint="$1"
    jq -n --arg reward "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}" '[{
      stake_address: $reward,
      status: "registered",
      delegated_pool: null,
      delegated_drep: null,
      rewards_available: "0",
      deposit: "2345678"
    }]' > "$3"
  }
  cntools_wallet_query_reset
  cntools_wallet_query_koios_stake \
    "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}" ||
    fail "valid Koios stake state with recorded deposit was rejected"
  assert_eq "${CNTOOLS_WALLET_REGISTERED}" yes \
    "Koios stake registration state"
  assert_eq "${CNTOOLS_WALLET_REWARD_LOVELACE}" 0 \
    "Koios exact claimable rewards"
  assert_eq "${CNTOOLS_WALLET_STAKE_DEPOSIT}" 2345678 \
    "Koios recorded stake deposit"
  [[ "${captured_endpoint}" == *'deposit%3A%3Atext'* ]] ||
    fail "Koios account_info did not request the recorded stake deposit"
}

test_local_stake_deposit_query() {
  CNTOOLS_WALLET_NETWORK_ARGS=(--testnet-magic 2)
  cntools_wallet_query_reset
  cntools_wallet_query_local_stake \
    "${CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS}" ||
    fail "valid local stake state with recorded deposit was rejected"
  assert_eq "${CNTOOLS_WALLET_REGISTERED}" yes \
    "local stake registration state"
  assert_eq "${CNTOOLS_WALLET_REWARD_LOVELACE}" 0 \
    "local exact claimable rewards"
  assert_eq "${CNTOOLS_WALLET_STAKE_DEPOSIT}" 2345678 \
    "local recorded stake deposit"
}

test_stake_coin_selection() {
  local protocol="${TEST_ROOT}/selection-protocol.json"

  jq -n '{stakeAddressDeposit: 2000000, txFeeFixed: 155381,
           txFeePerByte: 44, maxTxSize: 16384}' > "${protocol}"
  chmod 0600 "${protocol}"
  cntools_wallet_register_operation_set register
  cntools_wallet_register_reset_chain_state
  cntools_utxo_add "${TX_A}#0" addr_test1_base 3000000 N N
  cntools_utxo_add_asset 0 "${POLICY}.${ASSET_NAME}" 2
  cntools_utxo_add "${TX_B}#1" addr_test1_payment 4500000 N N
  cntools_utxo_add_asset 1 "${POLICY}.${ASSET_NAME}" 3
  cntools_utxo_add "${TX_C}#0" addr_test1_base 6000000 N N
  cntools_wallet_register_inventory_use_all ||
    fail "wallet inventory could not be aggregated"
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${protocol}"
  CNTOOLS_WALLET_REGISTER_DEPOSIT="2000000"
  cntools_wallet_register_select_inputs ||
    fail "stake registration coin selection failed: ${CNTOOLS_WALLET_REGISTER_ERROR}"
  assert_eq "${CNTOOLS_WALLET_REGISTER_AVAILABLE_INPUT_COUNT}" 3 \
    "available selection input count"
  assert_eq "${#CNTOOLS_WALLET_REGISTER_INPUTS[@]}" 1 \
    "selected stake input count"
  assert_eq "${CNTOOLS_WALLET_REGISTER_INPUTS[0]}" "${TX_C}#0" \
    "ADA-only stake input preference"
  assert_eq "${CNTOOLS_WALLET_REGISTER_LOVELACE}" 6000000 \
    "selected stake input balance"
  assert_eq "${CNTOOLS_WALLET_REGISTER_ASSET_COUNT}" 0 \
    "stake selection avoids native assets"
  assert_eq "${#CNTOOLS_CHANGE_OUTPUTS[@]}" 0 \
    "disabled change management leaves standard change"
  jq -e '
    .selection == "balanced" and
    .tokenFragmentation.enabled == false and
    .utxoManagement.enabled == false
  ' <<< "${CNTOOLS_WALLET_REGISTER_POLICY_JSON}" >/dev/null ||
    fail "applied transaction policy was not recorded"
}

test_registration_package() {
  local protocol="${TEST_ROOT}/protocol.json"
  local package=""
  local build_trace=""
  local token_change="addr_test1_base+1000000 + 5 ${POLICY}.${ASSET_NAME}"

  jq -n '{stakeAddressDeposit: 2000000}' > "${protocol}"
  chmod 0600 "${protocol}"
  cntools_wallet_register_operation_set register
  cntools_wallet_register_reset_chain_state
  CNTOOLS_WALLET_REGISTER_BACKEND="koios"
  CNTOOLS_WALLET_REGISTER_SOURCE="Koios API · https://preview.koios.rest/api/v1"
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${protocol}"
  CNTOOLS_WALLET_REGISTER_DEPOSIT="2000000"
  CNTOOLS_WALLET_REGISTER_LOVELACE="7500000"
  CNTOOLS_WALLET_REGISTER_INPUTS=("${TX_A}#0" "${TX_B}#1")
  CNTOOLS_WALLET_REGISTER_ASSET_IDS=("${POLICY}.${ASSET_NAME}")
  CNTOOLS_WALLET_REGISTER_ASSETS["${POLICY}.${ASSET_NAME}"]="5"
  cntools_wallet_register_total_value_build
  CNTOOLS_CHANGE_OUTPUTS=("${token_change}")
  CNTOOLS_CHANGE_OUTPUT_TYPES=("Token change")
  CNTOOLS_CHANGE_OUTPUT_LOVELACE=("1000000")
  CNTOOLS_CHANGE_OUTPUT_ASSET_COUNTS=("1")
  CNTOOLS_WALLET_REGISTER_POLICY_JSON="$(cntools_change_policy_json)"
  cntools_wallet_register_build_package_into package ||
    fail "registration transaction package could not be built: ${CNTOOLS_WALLET_REGISTER_ERROR}"
  cntools_transaction_package_load "${package}" ||
    fail "generated registration package could not be reopened"
  jq -e --arg payment "${PAYMENT_CREDENTIAL}" \
    --arg stake "${STAKE_CREDENTIAL}" '
      .intent.kind == "Wallet stake registration" and
      .intent.summary.action == "stake-address-registration" and
      .intent.summary.depositLovelace == "2000000" and
      .intent.summary.inputCount == "2" and
      (.intent.summary.selectedInputs | length) == 2 and
      (.intent.summary.plannedChangeOutputs | length) == 1 and
      ([.signing.required[].credential] | sort) == ([$payment, $stake] | sort)
    ' "${CNTOOLS_TRANSACTION_PACKAGE_FILE}" >/dev/null ||
    fail "registration package metadata or signer plan is incorrect"
  build_trace="$(jq -c \
    'select(.[0:3] == ["latest", "transaction", "build-estimate"])' \
    "${CLI_TRACE}" | tail -n 1)"
  [[ -n "${build_trace}" ]] || fail "build-estimate was not invoked"
  jq -e --arg first "${TX_A}#0" --arg second "${TX_B}#1" \
    --arg change "${token_change}" \
    --arg total "7500000 + 5 ${POLICY}.${ASSET_NAME}" '
      (index("--shelley-key-witnesses") != null) and
      (index("2") != null) and
      (index($first) != null) and (index($second) != null) and
      (index($change) != null) and
      (index($total) != null) and
      (index("--certificate-file") != null)
    ' <<< "${build_trace}" >/dev/null ||
    fail "build-estimate did not receive the complete registration inputs"
  assert_file_contains "${CLI_TRACE}" '"--key-reg-deposit-amt","2000000"' \
    "registration certificate deposit"
  cntools_transaction_cleanup
  cntools_transaction_package_reset_loaded
}

test_deregistration_package() {
  local protocol="${TEST_ROOT}/deregister-protocol.json"
  local package=""
  local build_trace=""
  local token_change="addr_test1_base+1000000 + 5 ${POLICY}.${ASSET_NAME}"

  jq -n '{stakeAddressDeposit: 2000000}' > "${protocol}"
  chmod 0600 "${protocol}"
  cntools_wallet_register_operation_set deregister
  cntools_wallet_register_reset_chain_state
  CNTOOLS_WALLET_REGISTER_BACKEND="koios"
  CNTOOLS_WALLET_REGISTER_SOURCE="Koios API · https://preview.koios.rest/api/v1"
  CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${protocol}"
  CNTOOLS_WALLET_REGISTER_DEPOSIT="2000000"
  CNTOOLS_WALLET_REGISTER_LOVELACE="7500000"
  CNTOOLS_WALLET_REGISTER_INPUTS=("${TX_A}#0" "${TX_B}#1")
  CNTOOLS_WALLET_REGISTER_ASSET_IDS=("${POLICY}.${ASSET_NAME}")
  CNTOOLS_WALLET_REGISTER_ASSETS["${POLICY}.${ASSET_NAME}"]="5"
  cntools_wallet_register_total_value_build
  CNTOOLS_CHANGE_OUTPUTS=("${token_change}")
  CNTOOLS_CHANGE_OUTPUT_TYPES=("Token change")
  CNTOOLS_CHANGE_OUTPUT_LOVELACE=("1000000")
  CNTOOLS_CHANGE_OUTPUT_ASSET_COUNTS=("1")
  CNTOOLS_WALLET_REGISTER_POLICY_JSON="$(cntools_change_policy_json)"
  cntools_wallet_register_build_package_into package ||
    fail "de-registration transaction package could not be built: ${CNTOOLS_WALLET_REGISTER_ERROR}"
  cntools_transaction_package_load "${package}" ||
    fail "generated de-registration package could not be reopened"
  jq -e --arg payment "${PAYMENT_CREDENTIAL}" \
    --arg stake "${STAKE_CREDENTIAL}" '
      .intent.kind == "Wallet stake de-registration" and
      .intent.summary.action == "stake-address-deregistration" and
      .intent.summary.depositLovelace == "2000000" and
      .intent.summary.depositEffect == "refunded" and
      .intent.summary.inputCount == "2" and
      ([.signing.required[].credential] | sort) == ([$payment, $stake] | sort)
    ' "${CNTOOLS_TRANSACTION_PACKAGE_FILE}" >/dev/null ||
    fail "de-registration package metadata or signer plan is incorrect"
  build_trace="$(jq -c \
    'select(.[0:3] == ["latest", "transaction", "build-estimate"])' \
    "${CLI_TRACE}" | tail -n 1)"
  [[ -n "${build_trace}" ]] ||
    fail "de-registration did not invoke build-estimate"
  jq -e --arg first "${TX_A}#0" --arg second "${TX_B}#1" \
    --arg change "${token_change}" \
    --arg total "7500000 + 5 ${POLICY}.${ASSET_NAME}" '
      (index("--shelley-key-witnesses") != null) and
      (index("2") != null) and
      (index($first) != null) and (index($second) != null) and
      (index($change) != null) and
      (index($total) != null) and
      (index("--certificate-file") != null)
    ' <<< "${build_trace}" >/dev/null ||
    fail "de-registration build-estimate did not receive all inputs"
  assert_file_contains "${CLI_TRACE}" \
    '"latest","stake-address","deregistration-certificate"' \
    "stake de-registration certificate command"
  cntools_transaction_cleanup
  cntools_transaction_package_reset_loaded
}

test_deregistration_guards() {
  local status=0

  cntools_wallet_register_operation_set deregister
  CNTOOLS_WALLET_REGISTERED="no"
  CNTOOLS_WALLET_REWARD_LOVELACE="0"
  if cntools_wallet_register_chain_state_validate; then
    fail "an unregistered stake address was accepted for de-registration"
  else
    status=$?
  fi
  assert_eq "${status}" 7 "unregistered stake-address guard"

  CNTOOLS_WALLET_REGISTERED="yes"
  CNTOOLS_WALLET_REWARD_LOVELACE="1"
  CNTOOLS_WALLET_STAKE_DEPOSIT="2000000"
  if cntools_wallet_register_chain_state_validate; then
    fail "a stake address with rewards was accepted for de-registration"
  else
    status=$?
  fi
  assert_eq "${status}" 8 "unclaimed reward guard"

  CNTOOLS_WALLET_REWARD_LOVELACE="0"
  cntools_wallet_register_chain_state_validate ||
    fail "a registered stake address with zero rewards was rejected"
  assert_eq "${CNTOOLS_WALLET_STAKE_DEPOSIT}" 2000000 \
    "registered stake deposit"
}

test_koios_bulk_request() {
  local captured_endpoint=""
  local captured_payload=""

  cntools_wallet_query_http() {
    captured_endpoint="$1"
    captured_payload="$2"
    printf '[]\n' > "$3"
  }
  cntools_wallet_register_reset_chain_state
  cntools_wallet_register_utxos_koios ||
    fail "empty Koios UTxO result was not handled as a valid response"
  [[ "${captured_endpoint}" == *'/address_utxos?'* ]] ||
    fail "Wallet Register did not use the Koios address_utxos endpoint"
  [[ "${captured_endpoint}" == *'datum_hash'* &&
     "${captured_endpoint}" == *'inline_datum'* &&
     "${captured_endpoint}" == *'reference_script'* ]] ||
    fail "Wallet Register did not request UTxO complexity markers"
  jq -e --arg base "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}" \
    --arg payment "${CNTOOLS_WALLET_REGISTER_PAYMENT_ADDRESS}" '
      ._extended == true and
      (._addresses | sort) == ([$base, $payment] | unique | sort)
    ' <<< "${captured_payload}" >/dev/null ||
    fail "Koios UTxO request was not one extended bulk-address request"
}

test_local_utxo_parser
test_koios_utxo_parser
test_local_stake_deposit_query
test_koios_stake_deposit_query
test_koios_bulk_request
test_stake_coin_selection
test_registration_package
test_deregistration_guards
test_deregistration_package

jq -e '.libs == [
  "number.sh", "wallet.sh", "wallet-material.sh", "wallet-key.sh",
  "wallet-address.sh", "wallet-id.sh", "wallet-query.sh", "utxo.sh", "transaction.sh",
  "transaction-build.sh", "transaction-sign.sh", "transaction-submit.sh",
  "transaction-ui.sh", "coin-selection.sh", "change-plan.sh",
  "wallet-register.sh", "wallet-register-ui.sh"
]' "${CNTOOLS_ROOT}/modules/root/wallet/register/module.json" >/dev/null ||
  fail "Wallet Register module library order is incorrect"
grep -F 'cntools_wallet_action_register' \
  "${CNTOOLS_ROOT}/modules/root/wallet/register/action.sh" >/dev/null ||
  fail "Wallet Register action does not call the functional entrypoint"
jq -e --slurpfile register \
  "${CNTOOLS_ROOT}/modules/root/wallet/register/module.json" \
  '.libs == $register[0].libs' \
  "${CNTOOLS_ROOT}/modules/root/wallet/deregister/module.json" >/dev/null ||
  fail "Wallet De-Register does not load the shared stake transaction stack"
grep -F 'cntools_wallet_action_deregister' \
  "${CNTOOLS_ROOT}/modules/root/wallet/deregister/action.sh" >/dev/null ||
  fail "Wallet De-Register action does not call the functional entrypoint"
grep -F 'Create unsigned package' \
  "${CNTOOLS_ROOT}/lib/wallet-register-ui.sh" >/dev/null ||
  fail "Wallet stake operations do not expose offline package creation"
grep -F 'Create, sign, and submit' \
  "${CNTOOLS_ROOT}/lib/wallet-register-ui.sh" >/dev/null ||
  fail "Wallet stake operations do not expose direct live submission"

printf 'CNTools wallet stake lifecycle tests passed\n'
