#!/usr/bin/env bash
# Focused Wallet -> Remove acceptance tests.
# shellcheck disable=SC1090,SC2016,SC2034,SC2154,SC2317,SC2329

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet-removal tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
REMOVE_MODULE="${CNTOOLS_ROOT}/modules/root/wallet/remove"
CNODE_RELEASE="${REPO_ROOT}/files/node-implementations/cnode/release.json"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet-remove.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
CNTOOLS_WALLET_DIR="${TEST_ROOT}/wallets"
CNTOOLS_TMP_DIR="${TEST_ROOT}/tmp"
FAKE_CLI="${TEST_ROOT}/cardano-cli"
CLI_TRACE="${TEST_ROOT}/cli.log"
LOG_TRACE="${TEST_ROOT}/cntools.log"
UI_TRACE="${TEST_ROOT}/ui.log"
DREP_ID="drep1ygqqupvw653m83jgv5yftq83vp8px9u0thetaefcuxukyqcdjrjaa"

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

assert_contains() {
  local actual="$1"
  local expected="$2"
  local context="${3:-text is missing}"

  [[ "${actual}" == *"${expected}"* ]] ||
    fail "${context}: '${expected}' was not found"
}

for required_file in \
  "${CNTOOLS_ROOT}/lib/wallet-remove.sh" \
  "${CNTOOLS_ROOT}/lib/wallet-remove-ui.sh" \
  "${REMOVE_MODULE}/module.json" \
  "${REMOVE_MODULE}/action.sh" \
  "${CNODE_RELEASE}"; do
  [[ -f "${required_file}" && ! -L "${required_file}" &&
     -s "${required_file}" ]] ||
    fail "required wallet-removal source is missing or unsafe: ${required_file}"
done

assert_eq \
  "$(jq -er '.companions["cardano-cli"].version' "${CNODE_RELEASE}")" \
  "11.0.0.0" \
  "pinned Cardano CLI contract; review DRep commands when the deployment pin changes"

for required_command in bash chmod jq mkdir mktemp rm rmdir; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required test command is unavailable: ${required_command}"
done

bash -n \
  "${CNTOOLS_ROOT}/lib/wallet-remove.sh" \
  "${CNTOOLS_ROOT}/lib/wallet-remove-ui.sh" \
  "${REMOVE_MODULE}/action.sh" ||
  fail "wallet-removal sources have invalid Bash syntax"

jq -e '.kind == "action" and .label == "Remove" and
  .modes == ["local", "light", "offline"] and .libs == [
    "number.sh",
    "wallet.sh",
    "wallet-material.sh",
    "wallet-key.sh",
    "wallet-address.sh",
    "wallet-id.sh",
    "wallet-query.sh",
    "wallet-remove.sh",
    "wallet-remove-ui.sh"
  ]' "${REMOVE_MODULE}/module.json" >/dev/null ||
  fail "Remove metadata does not declare the focused removal stack"
grep -F 'cntools_wallet_action_remove' \
  "${REMOVE_MODULE}/action.sh" >/dev/null ||
  fail "Remove action does not call its functional entrypoint"
grep -F 'cntools_wallet_query_cleanup' \
  "${REMOVE_MODULE}/action.sh" >/dev/null ||
  fail "Remove action does not clean query temporary files"
grep -F 'CNTOOLS_WALLET_DREP_VKEY_FILENAME="${WALLET_GOV_DREP_VK_FILENAME:-drep.vkey}"' \
  "${CNTOOLS_ROOT}/core/startup.sh" >/dev/null ||
  fail "startup does not normalize the existing DRep filename contract"

mkdir -p "${CNTOOLS_WALLET_DIR}" "${CNTOOLS_TMP_DIR}"
chmod 0700 "${TEST_ROOT}" "${CNTOOLS_WALLET_DIR}" "${CNTOOLS_TMP_DIR}"
: > "${CLI_TRACE}"
: > "${LOG_TRACE}"
: > "${UI_TRACE}"
chmod 0600 "${CLI_TRACE}" "${LOG_TRACE}" "${UI_TRACE}"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$*" >> "${FAKE_CLI_TRACE}"' \
  'if [[ "$*" == *"latest governance drep id"* ]]; then' \
  '  output=""' \
  '  while (( $# > 0 )); do' \
  '    if [[ "$1" == "--out-file" ]]; then output="$2"; shift 2; else shift; fi' \
  '  done' \
  '  printf "%s\n" "${FAKE_DREP_ID}" > "${output}"' \
  'elif [[ "$*" == *"latest query drep-state"* ]]; then' \
  '  if [[ "${FAKE_DREP_SCENARIO:-registered}" == "registered" ]]; then' \
  '    printf "[[{\"keyHash\":\"11111111111111111111111111111111111111111111111111111111\"},{\"deposit\":500000000}]]\n"' \
  '  elif [[ "${FAKE_DREP_SCENARIO}" == "missing" ]]; then' \
  '    printf "[]\n"' \
  '  else' \
  '    printf "query failed\n" >&2' \
  '    exit 9' \
  '  fi' \
  'else' \
  '  exit 10' \
  'fi' > "${FAKE_CLI}"
chmod 0700 "${FAKE_CLI}"
export FAKE_CLI_TRACE="${CLI_TRACE}"
export FAKE_DREP_ID="${DREP_ID}"
export FAKE_DREP_SCENARIO="registered"

# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/log.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/number.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet-query.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet-remove.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/lib/wallet-remove-ui.sh"

CNTOOLS_LOG="${LOG_TRACE}"
CNTOOLS_ACTION_ID="wallet/remove"
CNTOOLS_CLI="${FAKE_CLI}"
CNTOOLS_CLI_TIMEOUT="3"
CNTOOLS_TIMEOUT_BIN=""
CNTOOLS_NETWORK="preview"
CNTOOLS_IMPLEMENTATION="cnode"
CNTOOLS_IMPLEMENTATION_NAME="cardano-node"
CNTOOLS_LOCAL_CLI_CAPABLE="true"
CNTOOLS_SOCKET="${TEST_ROOT}/node.socket"
CNTOOLS_KOIOS_ENABLED="Y"
CNTOOLS_KOIOS_API="https://preview.koios.rest/api/v1"
CNTOOLS_MODE="local"
CNTOOLS_BACKEND="cnode"
CNTOOLS_WALLET_PAY_VKEY_FILENAME="payment.vkey"
CNTOOLS_WALLET_PAY_SKEY_FILENAME="payment.skey"
CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME="payment.hwsfile"
CNTOOLS_WALLET_PAY_ADDR_FILENAME="payment.addr"
CNTOOLS_WALLET_PAY_SCRIPT_FILENAME="payment.script"
CNTOOLS_WALLET_PAY_CRED_FILENAME="payment.cred"
CNTOOLS_WALLET_PAY_SCRIPT_CRED_FILENAME="payment.script.cred"
CNTOOLS_WALLET_BASE_ADDR_FILENAME="base.addr"
CNTOOLS_WALLET_STAKE_VKEY_FILENAME="stake.vkey"
CNTOOLS_WALLET_STAKE_SKEY_FILENAME="stake.skey"
CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME="stake.hwsfile"
CNTOOLS_WALLET_STAKE_ADDR_FILENAME="reward.addr"
CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME="stake.script"
CNTOOLS_WALLET_STAKE_CRED_FILENAME="stake.cred"
CNTOOLS_WALLET_STAKE_SCRIPT_CRED_FILENAME="stake.script.cred"
CNTOOLS_WALLET_DERIVATION_PATH_FILENAME="derivation.path"
CNTOOLS_WALLET_MULTISIG_PREFIX="ms_"
CNTOOLS_WALLET_DREP_VKEY_FILENAME="drep.vkey"
CNTOOLS_WALLET_DREP_SKEY_FILENAME="drep.skey"
CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME="drep.hwsfile"
CNTOOLS_WALLET_DREP_ID_FILENAME="drep.id"
CNTOOLS_WALLET_DREP_SCRIPT_FILENAME="drep.script"
CNTOOLS_WALLET_DREP_REGISTER_CERT_FILENAME="drep-reg.cert"
CNTOOLS_WALLET_DREP_RETIRE_CERT_FILENAME="drep-ret.cert"

cntools_log() {
  printf '%s\t%s\t%s\n' \
    "${1:-INFO}" "${CNTOOLS_ACTION_ID:-session}" "${2:-}" >> "${LOG_TRACE}"
}

make_wallet() {
  local name="$1"
  local wallet="${CNTOOLS_WALLET_DIR}/${name}"

  mkdir "${wallet}"
  chmod 0700 "${wallet}"
  printf '{}\n' > "${wallet}/payment.vkey"
  printf '{}\n' > "${wallet}/stake.vkey"
  chmod 0600 "${wallet}/payment.vkey" "${wallet}/stake.vkey"
  printf '%s\n' "${wallet}"
}

# DRep artifacts are detected separately from stake vote delegation. A valid
# cached ID is preferred, while an absent ID can be regenerated from drep.vkey.
wallet="$(make_wallet drep-id)"
printf '%s\n' "${DREP_ID}" > "${wallet}/drep.id"
chmod 0600 "${wallet}/drep.id"
cntools_wallet_remove_drep_material_present "${wallet}" ||
  fail "DRep material was not detected"
cntools_wallet_remove_resolve_drep_id "${wallet}" ||
  fail "valid cached DRep ID was rejected"
assert_eq "${CNTOOLS_WALLET_REMOVE_DREP_ID}" "${DREP_ID}" \
  "cached DRep ID"

wallet="$(make_wallet drep-derived)"
printf '{}\n' > "${wallet}/drep.vkey"
chmod 0600 "${wallet}/drep.vkey"
CNTOOLS_WALLET_REMOVE_DREP_ID=""
cntools_wallet_remove_resolve_drep_id "${wallet}" ||
  fail "DRep ID could not be derived from its verification key"
assert_eq "${CNTOOLS_WALLET_REMOVE_DREP_ID}" "${DREP_ID}" \
  "derived DRep ID"
grep -F 'latest governance drep id --drep-verification-key-file' \
  "${CLI_TRACE}" >/dev/null ||
  fail "DRep ID derivation omitted the pinned latest command form"

# Local DRep state uses the pinned cardano-cli 11 command form and treats an
# empty successful response as not registered rather than a query failure.
cntools_wallet_query_local_socket_ready() { return 0; }
CNTOOLS_WALLET_REMOVE_DREP_STATUS="unknown"
FAKE_DREP_SCENARIO="registered"
export FAKE_DREP_SCENARIO
cntools_wallet_remove_query_drep_local "${wallet}" ||
  fail "registered local DRep query failed"
assert_eq "${CNTOOLS_WALLET_REMOVE_DREP_STATUS}" "registered" \
  "registered local DRep state"
assert_eq "${CNTOOLS_WALLET_REMOVE_DREP_SOURCE}" "cardano-node" \
  "local DRep source"
grep -F 'latest query drep-state --drep-verification-key-file' \
  "${CLI_TRACE}" >/dev/null ||
  fail "local DRep query omitted the pinned latest command form"
grep -F -- '--testnet-magic 2 --socket-path' "${CLI_TRACE}" >/dev/null ||
  fail "local DRep query omitted the preview network or socket"

FAKE_DREP_SCENARIO="missing"
export FAKE_DREP_SCENARIO
cntools_wallet_remove_query_drep_local "${wallet}" ||
  fail "empty local DRep query failed"
assert_eq "${CNTOOLS_WALLET_REMOVE_DREP_STATUS}" "not-registered" \
  "empty local DRep state"

# Koios checks use one bulk-array request and distinguish registered,
# deregistered, absent, and malformed responses.
KOIOS_SCENARIO="registered"
KOIOS_ENDPOINT=""
KOIOS_PAYLOAD=""
cntools_wallet_query_http() {
  KOIOS_ENDPOINT="$1"
  KOIOS_PAYLOAD="$2"
  case "${KOIOS_SCENARIO}" in
    registered)
      jq -cn --arg id "${DREP_ID}" \
        '[{drep_id:$id,drep_status:"registered"}]' > "$3"
      ;;
    deregistered)
      jq -cn --arg id "${DREP_ID}" \
        '[{drep_id:$id,drep_status:"deregistered"}]' > "$3"
      ;;
    absent) printf '[]\n' > "$3" ;;
    invalid) printf '{"unexpected":true}\n' > "$3" ;;
    *) return 1 ;;
  esac
}

cntools_wallet_remove_query_drep_koios "${DREP_ID}" ||
  fail "registered Koios DRep query failed"
assert_eq "${CNTOOLS_WALLET_REMOVE_DREP_STATUS}" "registered" \
  "registered Koios DRep state"
assert_eq "${KOIOS_ENDPOINT}" \
  "https://preview.koios.rest/api/v1/drep_info" "Koios DRep endpoint"
jq -e --arg id "${DREP_ID}" '._drep_ids == [$id]' \
  <<< "${KOIOS_PAYLOAD}" >/dev/null ||
  fail "Koios DRep request did not use its bulk-array contract"

KOIOS_SCENARIO="deregistered"
cntools_wallet_remove_query_drep_koios "${DREP_ID}" ||
  fail "deregistered Koios DRep query failed"
assert_eq "${CNTOOLS_WALLET_REMOVE_DREP_STATUS}" "not-registered" \
  "deregistered Koios DRep state"
KOIOS_SCENARIO="absent"
cntools_wallet_remove_query_drep_koios "${DREP_ID}" ||
  fail "absent Koios DRep query failed"
assert_eq "${CNTOOLS_WALLET_REMOVE_DREP_STATUS}" "not-registered" \
  "absent Koios DRep state"
KOIOS_SCENARIO="invalid"
if cntools_wallet_remove_query_drep_koios "${DREP_ID}"; then
  fail "malformed Koios DRep response was accepted"
fi

# Evaluate clean, risky, and unverifiable state without converting unknown
# online/offline results into a clean safety report.
wallet="$(make_wallet evaluate)"
CNTOOLS_WALLET_TOTAL_LOVELACE="0"
CNTOOLS_WALLET_REWARD_LOVELACE="0"
CNTOOLS_WALLET_ASSET_COUNT="0"
CNTOOLS_WALLET_REGISTERED="no"
CNTOOLS_WALLET_REMOVE_DREP_STATUS="not-present"
cntools_wallet_remove_reset
CNTOOLS_WALLET_TOTAL_LOVELACE="0"
CNTOOLS_WALLET_REWARD_LOVELACE="0"
CNTOOLS_WALLET_ASSET_COUNT="0"
CNTOOLS_WALLET_REGISTERED="no"
cntools_wallet_remove_evaluate "${wallet}" Y Y N
assert_eq "${CNTOOLS_WALLET_REMOVE_WARNING_COUNT}" "0" \
  "clean wallet warning count"
assert_eq "${CNTOOLS_WALLET_REMOVE_UTXO_STATUS}" "empty" \
  "clean UTxO state"

cntools_wallet_remove_reset
CNTOOLS_WALLET_TOTAL_LOVELACE="0"
CNTOOLS_WALLET_REWARD_LOVELACE="0"
CNTOOLS_WALLET_ASSET_COUNT="1"
CNTOOLS_WALLET_REGISTERED="no"
cntools_wallet_remove_evaluate "${wallet}" Y Y N
assert_eq "${CNTOOLS_WALLET_REMOVE_HAS_FUNDS}" "Y" \
  "native asset fund warning"
assert_eq "${CNTOOLS_WALLET_REMOVE_WARNING_COUNT}" "1" \
  "native asset warning count"

printf '{}\n' > "${wallet}/drep.vkey"
chmod 0600 "${wallet}/drep.vkey"
cntools_wallet_remove_reset
CNTOOLS_WALLET_TOTAL_LOVELACE="1250000"
CNTOOLS_WALLET_REWARD_LOVELACE="750000"
CNTOOLS_WALLET_ASSET_COUNT="2"
CNTOOLS_WALLET_REGISTERED="yes"
CNTOOLS_WALLET_REMOVE_DREP_STATUS="registered"
cntools_wallet_remove_evaluate "${wallet}" Y Y N
assert_eq "${CNTOOLS_WALLET_REMOVE_HAS_FUNDS}" "Y" "fund warning"
assert_eq "${CNTOOLS_WALLET_REMOVE_STAKE_REGISTERED}" "Y" \
  "stake registration warning"
assert_eq "${CNTOOLS_WALLET_REMOVE_DREP_REGISTERED}" "Y" \
  "DRep registration warning"
assert_eq "${CNTOOLS_WALLET_REMOVE_WARNING_COUNT}" "3" \
  "known-risk warning count"

cntools_wallet_remove_reset
CNTOOLS_WALLET_TOTAL_LOVELACE=""
CNTOOLS_WALLET_REWARD_LOVELACE=""
CNTOOLS_WALLET_ASSET_COUNT=""
CNTOOLS_WALLET_REGISTERED="unknown"
CNTOOLS_WALLET_REMOVE_DREP_STATUS="unknown"
cntools_wallet_remove_evaluate "${wallet}" Y Y Y
assert_eq "${CNTOOLS_WALLET_REMOVE_UNKNOWN}" "Y" \
  "unknown state warning"
assert_eq "${CNTOOLS_WALLET_REMOVE_WARNING_COUNT}" "1" \
  "unknown warning is summarized once"

# Render every safety warning so the forced-removal path cannot silently hide
# funds or active stake/DRep credentials.
cntools_ui_render_status() {
  printf '%s\t%s\n' "$1" "$2" >> "${UI_TRACE}"
}
CNTOOLS_WALLET_REMOVE_HAS_FUNDS="Y"
CNTOOLS_WALLET_REMOVE_STAKE_REGISTERED="Y"
CNTOOLS_WALLET_REMOVE_DREP_REGISTERED="Y"
CNTOOLS_WALLET_REMOVE_UNKNOWN="Y"
cntools_wallet_remove_render_warnings
warning_output="$(< "${UI_TRACE}")"
assert_contains "${warning_output}" "still contains funds" "fund warning UI"
assert_contains "${warning_output}" "stake credential is still registered" \
  "stake warning UI"
assert_contains "${warning_output}" "DRep credential is still registered" \
  "DRep warning UI"
assert_contains "${warning_output}" "could not verify every balance" \
  "unknown warning UI"
assert_contains "${warning_output}" "permanently deletes every file" \
  "permanent deletion UI"

# The deletion primitive accepts only an owned, flat wallet directory. It
# removes read-only files without recursive rm and rejects nested or linked
# content before deleting anything.
wallet="$(make_wallet delete-safe)"
printf 'secret\n' > "${wallet}/payment.skey"
printf 'public\n' > "${wallet}/base.addr"
chmod 0400 "${wallet}/payment.skey" "${wallet}/base.addr"
cntools_wallet_remove_delete "${wallet}" ||
  fail "flat owned wallet could not be removed"
[[ ! -e "${wallet}" ]] || fail "removed wallet directory still exists"
assert_eq "${CNTOOLS_WALLET_REMOVE_FILE_COUNT}" "4" \
  "removed wallet file count"
grep -F $'CMD\twallet/remove\trm -f --' "${LOG_TRACE}" >/dev/null ||
  fail "wallet file removal command was not logged"
if grep -F 'rm -rf' "${LOG_TRACE}" >/dev/null; then
  fail "wallet removal used recursive rm"
fi

wallet="$(make_wallet delete-nested)"
mkdir "${wallet}/unexpected"
if cntools_wallet_remove_delete "${wallet}"; then
  fail "wallet containing a nested directory was removed"
fi
[[ -d "${wallet}/unexpected" ]] ||
  fail "nested wallet rejection changed its contents"

wallet="$(make_wallet delete-link)"
ln -s "${TEST_ROOT}" "${wallet}/unexpected-link"
if cntools_wallet_remove_delete "${wallet}"; then
  fail "wallet containing a symbolic link was removed"
fi
[[ -L "${wallet}/unexpected-link" ]] ||
  fail "symbolic-link wallet rejection changed its contents"

# Action cancellation never removes the wallet; confirmation is default-No in
# the shared UI and a positive response is the only path to deletion.
(
  ACTION_WALLET="$(make_wallet action-decline)"
  CNTOOLS_WALLET_PATHS=("${ACTION_WALLET}")
  CNTOOLS_WALLET_NAMES=("action-decline")
  CNTOOLS_WALLET_TYPES=("CLI")
  CNTOOLS_WALLET_PROTECTIONS=("Open")
  CNTOOLS_WALLET_ADDRESS_STATES=("3 / 3")
  cntools_ui_action_begin() { :; }
  cntools_ui_wait() { :; }
  cntools_gum_clear() { :; }
  cntools_wallet_catalog_build() { :; }
  cntools_wallet_choose() { local -n ref="$1"; ref=0; }
  cntools_wallet_prepare_selected_material() { :; }
  cntools_ui_spin_function() { local title="$1"; shift; : "${title}"; "$@"; }
  cntools_wallet_remove_inspect() {
    cntools_wallet_remove_reset
    CNTOOLS_WALLET_REMOVE_UTXO_STATUS="empty"
    CNTOOLS_WALLET_REMOVE_REWARD_STATUS="empty"
    CNTOOLS_WALLET_REMOVE_STAKE_STATUS="not-registered"
    CNTOOLS_WALLET_REMOVE_DREP_STATUS="not-present"
    CNTOOLS_WALLET_REMOVE_CHAIN_SOURCE="Koios API"
  }
  cntools_wallet_remove_render_review() { :; }
  cntools_wallet_remove_render_warnings() { :; }
  cntools_ui_confirm() { return 1; }
  cntools_wallet_remove_delete() { fail "declined action reached deletion"; }
  cntools_wallet_action_remove || fail "declined removal returned failure"
  [[ -d "${ACTION_WALLET}" ]] || fail "declined removal deleted the wallet"
)

(
  ACTION_WALLET="$(make_wallet action-confirm)"
  CNTOOLS_WALLET_PATHS=("${ACTION_WALLET}")
  CNTOOLS_WALLET_NAMES=("action-confirm")
  CNTOOLS_WALLET_TYPES=("CLI")
  CNTOOLS_WALLET_PROTECTIONS=("Open")
  CNTOOLS_WALLET_ADDRESS_STATES=("3 / 3")
  cntools_ui_action_begin() { :; }
  cntools_ui_wait() { :; }
  cntools_gum_clear() { :; }
  cntools_ui_render_status() { :; }
  cntools_wallet_catalog_build() { :; }
  cntools_wallet_choose() { local -n ref="$1"; ref=0; }
  cntools_wallet_prepare_selected_material() { :; }
  cntools_ui_spin_function() { local title="$1"; shift; : "${title}"; "$@"; }
  cntools_wallet_remove_inspect() {
    cntools_wallet_remove_reset
    CNTOOLS_WALLET_REMOVE_UTXO_STATUS="funded"
    CNTOOLS_WALLET_REMOVE_REWARD_STATUS="empty"
    CNTOOLS_WALLET_REMOVE_STAKE_STATUS="registered"
    CNTOOLS_WALLET_REMOVE_DREP_STATUS="registered"
    CNTOOLS_WALLET_REMOVE_WARNING_COUNT=3
  }
  cntools_wallet_remove_render_review() { :; }
  cntools_wallet_remove_render_warnings() { :; }
  cntools_wallet_remove_render_result() { :; }
  cntools_ui_confirm() { return 0; }
  cntools_wallet_remove_delete() {
    rm -f -- "$1/payment.vkey" "$1/stake.vkey"
    rmdir -- "$1"
  }
  cntools_wallet_action_remove || fail "confirmed forced removal returned failure"
  [[ ! -e "${ACTION_WALLET}" ]] || fail "confirmed removal retained the wallet"
)

grep -F $'CHOICE\twallet/remove\twallet removal declined wallet=action-decline' \
  "${LOG_TRACE}" >/dev/null ||
  fail "declined wallet removal was not logged"
grep -F $'CHOICE\twallet/remove\twallet removal confirmed wallet=action-confirm warnings=3' \
  "${LOG_TRACE}" >/dev/null ||
  fail "forced wallet removal confirmation was not logged"

printf 'CNTools wallet-removal tests passed\n'
