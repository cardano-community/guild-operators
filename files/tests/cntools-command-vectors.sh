#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2154
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools command-vector tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
CNTOOLS_LIBRARY="${REPO_ROOT}/scripts/common-helper-scripts/cntools.library"
VECTOR_FIXTURE="${REPO_ROOT}/files/tests/fixtures/cntools-command-vectors.json"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-vectors.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
BASE_PATH="${PATH}"
FAKE_BIN="${TEST_ROOT}/fake-bin"
CLI_LOG="${TEST_ROOT}/cardano-cli.log"
NETWORK_LOG="${TEST_ROOT}/network.log"
FAKE_CLI="${FAKE_BIN}/cardano-cli"

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

assert_file_content() {
  local path="$1"
  local expected="$2"
  local context="$3"
  [[ -f "${path}" ]] || fail "${context}: file is missing: ${path}"
  assert_eq "$(< "${path}")" "${expected}" "${context}"
}

file_mode() {
  local path="$1"
  if stat -c '%a' "${path}" >/dev/null 2>&1; then
    stat -c '%a' "${path}"
  else
    stat -f '%Lp' "${path}"
  fi
}

assert_vectors() {
  local category="$1"
  local witness_path="${2:-}"
  local actual expected

  actual="$(< "${CLI_LOG}")"
  expected="$(
    jq -r \
      --arg category "${category}" \
      --arg root "${TEST_ROOT}" \
      --arg witness "${witness_path}" '
        .vectors[$category][] |
        map(
          gsub("\\{ROOT\\}"; $root) |
          gsub("\\{WITNESS\\}"; $witness)
        ) |
        @tsv
      ' "${VECTOR_FIXTURE}"
  )" || fail "unable to load ${category} vectors"
  assert_eq "${actual}" "${expected}" "${category} command vectors"
}

write_fake_cli() {
  local command_name
  mkdir -p "${FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'first=true' \
    'for argument in "$@"; do' \
    '  if [[ "${first}" == true ]]; then' \
    '    first=false' \
    '  else' \
    '    printf "\\t" >> "${CNTOOLS_VECTOR_LOG:?}"' \
    '  fi' \
    '  printf "%s" "${argument}" >> "${CNTOOLS_VECTOR_LOG:?}"' \
    'done' \
    'printf "\\n" >> "${CNTOOLS_VECTOR_LOG:?}"' \
    'if [[ -n "${CNTOOLS_VECTOR_FAIL_PREFIX:-}" && "$*" == "${CNTOOLS_VECTOR_FAIL_PREFIX}"* ]]; then' \
    '  printf "forced cardano-cli failure\\n" >&2' \
    '  exit 61' \
    'fi' \
    'out_file=""' \
    'previous=""' \
    'for argument in "$@"; do' \
    '  case "${previous}" in' \
    '    --out-file|--operational-certificate-issue-counter-file)' \
    '      mkdir -p "$(dirname "${argument}")"' \
    '      printf "fixture-output\\n" > "${argument}"' \
    '      [[ "${previous}" == "--out-file" ]] && out_file="${argument}"' \
    '      ;;' \
    '    --verification-key-file|--signing-key-file)' \
    '      case "${1:-} ${2:-}" in' \
    '        "address key-gen"|"node key-gen-KES")' \
    '          mkdir -p "$(dirname "${argument}")"' \
    '          printf "fixture-output\\n" > "${argument}"' \
    '          ;;' \
    '      esac' \
    '      ;;' \
    '  esac' \
    '  previous="${argument}"' \
    'done' \
    'case "$*" in' \
    '  "address build "*)' \
    '    if [[ -n "${out_file}" ]]; then' \
    '      printf "addr_test1_vector\\n" > "${out_file}"' \
    '    else' \
    '      printf "addr_test1_base_vector\\n"' \
    '    fi' \
    '    ;;' \
    '  "address key-hash "*) printf "policy_key_hash_vector\\n" ;;' \
    '  "hash script "*)' \
    '    if [[ -n "${out_file}" ]]; then' \
    '      printf "policy_id_vector\\n" > "${out_file}"' \
    '    else' \
    '      printf "policy_id_vector\\n"' \
    '    fi' \
    '    ;;' \
    '  "latest governance drep id "*) printf "drep1vector\\n" ;;' \
    '  "latest transaction calculate-min-fee "*) printf "177777 Lovelace\\n" ;;' \
    '  "latest transaction txid "*) printf "txid_vector\\n" ;;' \
    'esac' \
    'exit 0' \
    > "${FAKE_CLI}"
  chmod 0755 "${FAKE_CLI}"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf "%s" "${0##*/}" >> "${CNTOOLS_VECTOR_NETWORK_LOG:?}"' \
      'printf "\\t%s" "$@" >> "${CNTOOLS_VECTOR_NETWORK_LOG:?}"' \
      'printf "\\n" >> "${CNTOOLS_VECTOR_NETWORK_LOG:?}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
  : > "${NETWORK_LOG}"
}

prepare_runtime() {
  mkdir -p \
    "${TEST_ROOT}/tmp-base" \
    "${TEST_ROOT}/wallet" \
    "${TEST_ROOT}/pool" \
    "${TEST_ROOT}/asset" \
    "${TEST_ROOT}/keys" \
    "${TEST_ROOT}/home" \
    "${TEST_ROOT}/node-home" \
    "${TEST_ROOT}/logs"

  PATH="${FAKE_BIN}:${BASE_PATH}"
  HOME="${TEST_ROOT}/home"
  NODE_HOME="${TEST_ROOT}/node-home"
  CNODE_HOME="${NODE_HOME}"
  TMP_DIR="${TEST_ROOT}/tmp-base"
  WALLET_FOLDER="${TEST_ROOT}/wallet"
  POOL_FOLDER="${TEST_ROOT}/pool"
  ASSET_FOLDER="${TEST_ROOT}/asset"
  LOG_DIR="${TEST_ROOT}/logs"
  CNTOOLS_MODE="offline"
  NETWORK_NAME="Preview"
  NETWORK_IDENTIFIER="--testnet-magic 42"
  ADVANCED_MODE="true"
  ENABLE_ADVANCED="true"
  ENABLE_CHATTR="false"
  CCLI="${FAKE_CLI}"
  CNTOOLS_VECTOR_LOG="${CLI_LOG}"
  CNTOOLS_VECTOR_NETWORK_LOG="${NETWORK_LOG}"
  http_proxy=http://127.0.0.1:9
  https_proxy=http://127.0.0.1:9
  HTTP_PROXY=http://127.0.0.1:9
  HTTPS_PROXY=http://127.0.0.1:9
  export PATH HOME NODE_HOME CNODE_HOME
  export CNTOOLS_VECTOR_LOG CNTOOLS_VECTOR_NETWORK_LOG
  export http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

  WALLET_PAY_VK_FILENAME="payment.vkey"
  WALLET_PAY_SK_FILENAME="payment.skey"
  WALLET_PAY_ADDR_FILENAME="payment.addr"
  WALLET_PAY_SCRIPT_FILENAME="payment.script"
  WALLET_BASE_ADDR_FILENAME="base.addr"
  WALLET_STAKE_VK_FILENAME="stake.vkey"
  WALLET_STAKE_SK_FILENAME="stake.skey"
  WALLET_STAKE_SCRIPT_FILENAME="stake.script"
  WALLET_GOV_DREP_VK_FILENAME="drep.vkey"
  WALLET_GOV_DREP_SK_FILENAME="drep.skey"
  WALLET_GOV_DREP_ID_FILENAME="drep.id"
  WALLET_GOV_DREP_SCRIPT_FILENAME="drep.script"
  WALLET_GOV_HW_DREP_SK_FILENAME="drep.hwsfile"
  WALLET_GOV_CC_COLD_VK_FILENAME="cc-cold.vkey"
  WALLET_GOV_CC_COLD_SK_FILENAME="cc-cold.skey"
  WALLET_GOV_CC_COLD_ID_FILENAME="cc-cold.id"
  WALLET_GOV_HW_CC_COLD_SK_FILENAME="cc-cold.hwsfile"
  WALLET_GOV_CC_HOT_VK_FILENAME="cc-hot.vkey"
  WALLET_GOV_CC_HOT_SK_FILENAME="cc-hot.skey"
  WALLET_GOV_CC_HOT_ID_FILENAME="cc-hot.id"
  WALLET_GOV_HW_CC_HOT_SK_FILENAME="cc-hot.hwsfile"
  WALLET_MULTISIG_PREFIX="ms_"

  POOL_HOTKEY_VK_FILENAME="hot.vkey"
  POOL_HOTKEY_SK_FILENAME="hot.skey"
  POOL_COLDKEY_VK_FILENAME="cold.vkey"
  POOL_COLDKEY_SK_FILENAME="cold.skey"
  POOL_HW_COLDKEY_SK_FILENAME="cold.hwsfile"
  POOL_OPCERT_COUNTER_FILENAME="cold.counter"
  POOL_OPCERT_FILENAME="op.cert"
  POOL_CURRENT_KES_START="kes.start"

  ASSET_POLICY_VK_FILENAME="policy.vkey"
  ASSET_POLICY_SK_FILENAME="policy.skey"
  ASSET_POLICY_SCRIPT_FILENAME="policy.script"
  ASSET_POLICY_ID_FILENAME="policy.id"

  FG_BLUE=""
  FG_GREEN=""
  FG_GRAY=""
  FG_RED=""
  FG_YELLOW=""
  FG_LBLUE=""
  FG_LGRAY=""
  NC=""

  myExit() {
    fail "cntools.library initialization unexpectedly exited: $*"
  }

  set +u
  . "${CNTOOLS_LIBRARY}"
  . "${CNTOOLS_SCRIPT}"

  println() { :; }
  clear() { :; }
  formatLovelace() { printf '%s\n' "$1"; }
  bech32() {
    local encoded_value
    if [[ $# -eq 0 ]]; then
      IFS= read -r encoded_value
      [[ "${encoded_value}" == "drep1vector" ]] || return 1
      printf 'drep_key_hash_vector\n'
    else
      printf '%s_vector\n' "$1"
    fi
  }
  date() {
    if [[ "$*" == "+%s" ]]; then
      printf '1700000000\n'
    else
      command date "$@"
    fi
  }
}

run_wallet_contract() {
  local key_root="${TEST_ROOT}/keys"
  mkdir -p "${WALLET_FOLDER}/alice"
  printf '{"description":"Payment Verification Key"}\n' \
    > "${WALLET_FOLDER}/alice/${WALLET_PAY_VK_FILENAME}"
  printf '{"description":"Payment Verification Key"}\n' \
    > "${key_root}/payment.vkey"
  printf '{"description":"Stake Verification Key"}\n' \
    > "${key_root}/stake.vkey"

  : > "${CLI_LOG}"
  getPayAddress alice || fail "getPayAddress failed"
  assert_eq "${pay_addr}" "addr_test1_vector" "payment address result"
  assert_file_content \
    "${WALLET_FOLDER}/alice/${WALLET_PAY_ADDR_FILENAME}" \
    "addr_test1_vector" "payment address artifact"

  getBaseAddress "${key_root}/payment.vkey" "${key_root}/stake.vkey" ||
    fail "getBaseAddress explicit-key path failed"
  assert_eq "${base_addr}" "addr_test1_base_vector" "base address result"
  assert_vectors wallet
}

run_governance_contract() {
  printf '{"description":"DRep Verification Key"}\n' \
    > "${TEST_ROOT}/keys/drep.vkey"
  : > "${CLI_LOG}"
  getCredential drep "${TEST_ROOT}/keys/drep.vkey" ||
    fail "getCredential drep path failed"
  assert_eq "${cred}" "drep_key_hash_vector" "DRep credential result"
  assert_vectors governance
}

run_pool_contract() {
  local pool_dir="${POOL_FOLDER}/alpha"
  local path
  mkdir -p "${pool_dir}"
  printf '{"description":"Stake Pool Operator Verification Key"}\n' \
    > "${pool_dir}/${POOL_COLDKEY_VK_FILENAME}"
  printf '{"description":"Stake Pool Operator Signing Key"}\n' \
    > "${pool_dir}/${POOL_COLDKEY_SK_FILENAME}"

  pool_name="alpha"
  op_mode="online"
  getCurrentKESperiod() { printf '123\n'; }
  kesExpiration() { [[ "$1" == "123" ]]; }

  : > "${CLI_LOG}"
  rotatePoolKeys 9 || fail "rotatePoolKeys fixture failed"
  assert_vectors pool
  assert_file_content "${pool_dir}/${POOL_CURRENT_KES_START}" "123" \
    "saved KES period"
  for path in \
    "${pool_dir}/${POOL_HOTKEY_VK_FILENAME}" \
    "${pool_dir}/${POOL_HOTKEY_SK_FILENAME}" \
    "${pool_dir}/${POOL_OPCERT_COUNTER_FILENAME}" \
    "${pool_dir}/${POOL_OPCERT_FILENAME}"; do
    [[ -s "${path}" ]] || fail "pool rotation artifact is missing or empty: ${path}"
    assert_eq "$(file_mode "${path}")" "700" "pool artifact mode"
  done
}

run_transaction_contract() {
  local raw_file="${TMP_DIR}/tx.raw"
  local signing_key="${TEST_ROOT}/keys/payment.skey"
  local witness_file
  printf '{}\n' > "${TMP_DIR}/protparams.json"
  printf '{"description":"Payment Signing Key"}\n' > "${signing_key}"
  build_args=(
    --tx-in "deadbeef#0"
    --tx-out "addr_test1_vector+1234567 lovelace"
    --fee 200000
    --out-canonical-cbor
    --out-file "${raw_file}"
  )

  : > "${CLI_LOG}"
  buildTx "" || fail "buildTx fixture failed"
  [[ -s "${raw_file}" ]] || fail "raw transaction artifact is missing"
  calcMinFee "${raw_file}" 1 1 2 || fail "calcMinFee fixture failed"
  assert_eq "${min_fee}" "177777" "minimum fee result"
  witnessTx "${raw_file}" "${signing_key}" || fail "witnessTx fixture failed"
  assert_file_content "${signing_key}" \
    '{"description":"Payment Signing Key"}' \
    "transaction signing-key input"
  assert_eq "${#tx_witness_files[@]}" "1" "witness result count"
  witness_file="${tx_witness_files[0]}"
  [[ -s "${witness_file}" ]] || fail "witness artifact is missing or empty"
  assembleTx "${raw_file}" || fail "assembleTx fixture failed"
  assert_file_content "${tx_signed}" "fixture-output" "signed transaction artifact"
  submitTxNode "${tx_signed}" || fail "submitTxNode fixture failed"
  assert_eq "${tx_id}" "txid_vector" "transaction ID result"
  assert_vectors transaction "${witness_file}"
}

run_submit_retry_contract() (
  local submit_calls=0
  local prompt_calls=0
  local submit_status=0
  local retry_choice=0
  local signed_file="${TMP_DIR}/retry-contract.signed"

  printf 'fixture-output\n' > "${signed_file}"
  CNTOOLS_MODE="LOCAL"
  tput() { :; }
  submitTxNode() {
    submit_calls=$((submit_calls + 1))
    (( submit_calls >= 2 ))
  }
  select_opt() {
    [[ "$1" == "[y] Yes" && "$2" == "[n] No" ]] ||
      fail "submit retry prompt options changed"
    prompt_calls=$((prompt_calls + 1))
    return "${retry_choice}"
  }

  set +e
  submitTx "${signed_file}"
  submit_status=$?
  set -e
  assert_eq "${submit_status}" "0" "submit retry success status"
  assert_eq "${submit_calls}" "2" "submit retry attempt count"
  assert_eq "${prompt_calls}" "1" "submit retry prompt count"

  submit_calls=0
  prompt_calls=0
  retry_choice=1
  submitTxNode() {
    submit_calls=$((submit_calls + 1))
    return 1
  }
  set +e
  submitTx "${signed_file}"
  submit_status=$?
  set -e
  assert_eq "${submit_status}" "1" "submit cancellation status"
  assert_eq "${submit_calls}" "1" "submit cancellation attempt count"
  assert_eq "${prompt_calls}" "1" "submit cancellation prompt count"
)

run_asset_action_contract() (
  local -a choices=(a a c h q)
  local choice_cursor=0
  local answer_count=0
  local policy_dir="${ASSET_FOLDER}/vector_policy"
  local option selected_index

  CNTOOLS_MODE="OFFLINE"
  CNTOOLS_MODE_COLOR=""
  CNTOOLS_VERSION="characterized"
  NETWORK_NAME="Preview"
  ADVANCED_MODE="true"
  BLOCKLOG_DB="${TEST_ROOT}/absent-blocklog.db"
  price_now=""

  getEpoch() { printf '0\n'; }
  timeUntilNextEpoch() { printf '0\n'; }
  timeLeft() { printf '00:00:00\n'; }
  waitToProceed() { return 0; }
  isNumber() { [[ "$1" =~ ^[0-9]+$ ]]; }
  getAnswerAnyCust() {
    case "$1" in
      policy_name) policy_name="vector policy" ;;
      ttl_enter) ttl_enter="0" ;;
      *) fail "asset action requested unexpected input variable: $1" ;;
    esac
    answer_count=$((answer_count + 1))
  }
  select_opt() {
    local choice="${choices[choice_cursor]}"
    choice_cursor=$((choice_cursor + 1))
    selected_index=0
    for option in "$@"; do
      if [[ "${option}" == "[${choice}]"* ]]; then
        selected_value="${option}"
        return "${selected_index}"
      fi
      selected_index=$((selected_index + 1))
    done
    fail "asset action choice '${choice}' was not displayed"
  }
  myExit() {
    local status="${1:-0}"
    [[ "${status}" == "0" ]] || fail "asset action exited with ${status}: $*"
    [[ "${choice_cursor}" == "${#choices[@]}" ]] ||
      fail "asset action did not consume every scripted menu choice"
    [[ "${answer_count}" == "2" ]] ||
      fail "asset action input sequence changed"
    assert_vectors asset
    assert_file_content "${policy_dir}/${ASSET_POLICY_ID_FILENAME}" \
      "policy_id_vector" "asset policy ID"
    jq -e \
      '. == {keyHash: "policy_key_hash_vector", type: "sig"}' \
      "${policy_dir}/${ASSET_POLICY_SCRIPT_FILENAME}" >/dev/null ||
      fail "asset policy script changed"
    for path in \
      "${policy_dir}/${ASSET_POLICY_VK_FILENAME}" \
      "${policy_dir}/${ASSET_POLICY_SK_FILENAME}" \
      "${policy_dir}/${ASSET_POLICY_SCRIPT_FILENAME}" \
      "${policy_dir}/${ASSET_POLICY_ID_FILENAME}"; do
      assert_eq "$(file_mode "${path}")" "600" "asset policy artifact mode"
    done
    exit 0
  }

  : > "${CLI_LOG}"
  main >/dev/null
  exit 99
)

run_failure_contract() {
  local failure_wallet="${WALLET_FOLDER}/failure"
  local expected_call
  mkdir -p "${failure_wallet}"
  printf '{"description":"Payment Verification Key"}\n' \
    > "${failure_wallet}/${WALLET_PAY_VK_FILENAME}"
  : > "${CLI_LOG}"
  export CNTOOLS_VECTOR_FAIL_PREFIX="address build"
  if getPayAddress failure; then
    unset CNTOOLS_VECTOR_FAIL_PREFIX
    fail "getPayAddress accepted a cardano-cli failure"
  fi
  unset CNTOOLS_VECTOR_FAIL_PREFIX
  [[ -z ${pay_addr+x} ]] || fail "failed getPayAddress leaked an old result"
  [[ ! -e "${failure_wallet}/${WALLET_PAY_ADDR_FILENAME}" ]] ||
    fail "failed getPayAddress left a payment address artifact"
  printf -v expected_call \
    'address\tbuild\t--payment-verification-key-file\t%s\t--out-file\t%s\t--testnet-magic\t42' \
    "${failure_wallet}/${WALLET_PAY_VK_FILENAME}" \
    "${failure_wallet}/${WALLET_PAY_ADDR_FILENAME}"
  assert_eq "$(< "${CLI_LOG}")" "${expected_call}" \
    "failed getPayAddress cardano-cli call"
}

for required_command in jq stat; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done
jq -e '
  .schemaVersion == 1 and
  (.vectors | keys == ["asset", "governance", "pool", "transaction", "wallet"]) and
  (all(.vectors[]; type == "array" and length > 0)) and
  (all(.vectors[][]; type == "array" and length > 0))
' "${VECTOR_FIXTURE}" >/dev/null || fail "invalid command-vector fixture"

write_fake_cli
prepare_runtime
run_wallet_contract
run_governance_contract
run_pool_contract
run_transaction_contract
run_submit_retry_contract
run_asset_action_contract || fail "asset create-policy action contract failed"
run_failure_contract

[[ ! -s "${NETWORK_LOG}" ]] ||
  fail "unexpected network command attempted: $(< "${NETWORK_LOG}")"

printf 'CNTools command-vector tests passed\n'
