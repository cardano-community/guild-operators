#!/usr/bin/env bash
# Characterize the live inline wallet.register controller and its inherited
# legacy registration/query helpers without extracting or changing production.
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2154,SC2317,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet-register characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
LEGACY_BUNDLE_ID='6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59'
LEGACY_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/${LEGACY_BUNDLE_ID}"
COMMON_DIALOG_SOURCE="${LEGACY_ROOT}/010-common-dialog.sh"
SELECTION_SOURCE="${LEGACY_ROOT}/020-terminal-selection-security.sh"
GOVERNANCE_QUERY_SOURCE="${LEGACY_ROOT}/030-governance-query.sh"
WALLET_QUERY_SOURCE="${LEGACY_ROOT}/040-address-wallet-query.sh"
WALLET_REGISTRATION_SOURCE="${LEGACY_ROOT}/050-wallet-create-registration.sh"
TRANSACTION_SOURCE="${LEGACY_ROOT}/100-transaction-hardware-price.sh"
INERT_ACTION="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/wallet/register/action.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet-register.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
REAL_JQ_PATH="$(command -v jq)"
BASE_ADDR='addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
PAY_ADDR='addr_test1pppppppppppppppppppppppppppppppppppppppp'
REWARD_ADDR='stake_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
TX_HASH='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
RAW_DIAGNOSTIC='RAW_REGISTER_DIAGNOSTIC_DO_NOT_RENDER'
SIGNING_SECRET='REGISTER_SIGNING_CBOR_SECRET_DO_NOT_EXPOSE'
KOIOS_HEADER_SECRET='REGISTER_KOIOS_HEADER_SECRET_DO_NOT_EXPOSE'
INHERITED_LIGHT_SECRET='REGISTER_INHERITED_LIGHT_SECRET_DO_NOT_EXPOSE'
LIGHT_ARGV_SECRET='REGISTER_LIGHT_ARGV_SECRET_DO_NOT_EXPOSE'

cleanup_test() {
  if [[ "${CNTOOLS_WALLET_REGISTER_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools wallet-register test root preserved: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools wallet-register characterization failed: %s\n' "$1" >&2
  exit 1
}

file_links() {
  local target="$1" links=""

  if links="$(stat -f '%l' "${target}" 2>/dev/null)"; then
    :
  else
    links="$(stat -c '%h' -- "${target}" 2>/dev/null)" || return 1
  fi
  [[ "${links}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "${links}"
}

capture_open_fds() {
  local output_name="$1" target="" inventory=""

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  for target in /dev/fd/[0-9]*; do
    [[ -e "${target}" ]] || continue
    inventory+="${target##*/},"
  done
  builtin printf -v "${output_name}" '%s' "${inventory}"
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk basename cmp cp cut find grep jq mktemp readlink \
  sed sort stat tail tr wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done
if command -v sha256sum >/dev/null 2>&1; then
  HASH_COMMAND=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  HASH_COMMAND=shasum
else
  fail 'sha256sum or shasum is required'
fi

for source_file in "${CNTOOLS_SCRIPT}" "${CONTEXT_SOURCE}" "${REGISTRY_SOURCE}" \
  "${RESULT_SOURCE}" "${COMMON_DIALOG_SOURCE}" "${SELECTION_SOURCE}" \
  "${GOVERNANCE_QUERY_SOURCE}" "${WALLET_QUERY_SOURCE}" \
  "${WALLET_REGISTRATION_SOURCE}" "${TRANSACTION_SOURCE}" \
  "${INERT_ACTION}"; do
  [[ -f "${source_file}" && ! -L "${source_file}" ]] ||
    fail "required source is missing or unsafe: ${source_file}"
done

write_fake_commands() {
  local command_name=""

  mkdir -p -- "${FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_REGISTER_SCENARIO:?}"' \
    'log="${CNTOOLS_WALLET_REGISTER_CLI_LOG:?}"' \
    'previous=""; out_file=""; address=""; argument=""; normalized=""' \
    'for argument in "$@"; do' \
    '  [[ "${previous}" == --out-file ]] && out_file="${argument}"' \
    '  [[ "${previous}" == --address ]] && address="${argument}"' \
    '  previous="${argument}"' \
    'done' \
    'printf '\''cardano-cli'\'' >> "${log}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  if [[ "${normalized}" == "${CNTOOLS_WALLET_REGISTER_RUNTIME:?}/"* ]]; then' \
    '    normalized="<runtime>/${normalized#"${CNTOOLS_WALLET_REGISTER_RUNTIME}/"}"' \
    '  fi' \
    '  printf '\''\t%q'\'' "${normalized}" >> "${log}"' \
    'done' \
    'printf '\''\n'\'' >> "${log}"' \
    'case "$*" in' \
    '  "address build "*)' \
    '    [[ "${scenario}" != address-build-fail ]] || { printf '\''address build failed\n'\'' >&2; exit 31; }' \
    '    [[ -n "${out_file}" ]] || exit 96' \
    '    if [[ "$*" == *" --stake-"* ]]; then value="${CNTOOLS_WALLET_REGISTER_BASE:?}"; else value="${CNTOOLS_WALLET_REGISTER_PAY:?}"; fi' \
    '    printf '\''%s\n'\'' "${value}" > "${out_file}"' \
    '    ;;' \
    '  "latest stake-address build "*)' \
    '    [[ "${scenario}" != reward-build-fail ]] || { printf '\''reward build failed\n'\'' >&2; exit 32; }' \
    '    [[ -n "${out_file}" ]] || exit 96' \
    '    printf '\''%s\n'\'' "${CNTOOLS_WALLET_REGISTER_REWARD:?}" > "${out_file}"' \
    '    ;;' \
    '  "query utxo "*)' \
    '    [[ "${scenario}" != local-utxo-fail ]] || { printf '\''utxo query failed\n'\'' >&2; exit 33; }' \
    '    if [[ "${address}" == "${CNTOOLS_WALLET_REGISTER_BASE:?}" ]]; then amount=10000000; else amount=500000; fi' \
    '    printf '\''%s 0 %s lovelace + TxOutDatumNone\n'\'' "${CNTOOLS_WALLET_REGISTER_TX_HASH:?}" "${amount}"' \
    '    ;;' \
    '  "query stake-address-info "*)' \
    '    [[ "${scenario}" != local-stake-query-fail ]] || { printf '\''stake query failed\n'\'' >&2; exit 34; }' \
    '    if [[ "${scenario}" == local-stake-malformed ]]; then printf '\''not-json\n'\''' \
    '    elif [[ "${scenario}" == local-registered ]]; then printf '\''[{"address":"%s","rewardAccountBalance":0,"stakeRegistrationDeposit":2000000,"govActionDeposits":{}}]\n'\'' "${CNTOOLS_WALLET_REGISTER_REWARD:?}"' \
    '    else printf '\''[]\n'\''; fi' \
    '    ;;' \
    '  "latest stake-address registration-certificate "*)' \
    '    if [[ "${scenario}" == cert-fail || "${scenario}" == raw-diagnostic ]]; then' \
    '      printf '\''%s\\033[31m\\n'\'' "${CNTOOLS_WALLET_REGISTER_RAW:?}" >&2; exit 35' \
    '    fi' \
    '    [[ -n "${out_file}" ]] || exit 96' \
    '    [[ ! -p "${out_file}" ]] || exit 36' \
    '    if [[ "${scenario}" == malformed-cert ]]; then printf '\''not-json\\033[31m\n'\'' > "${out_file}"' \
    '    else printf '\''{"type":"StakeAddressRegistrationCertificate","description":"fixture"}\n'\'' > "${out_file}"; fi' \
    '    ;;' \
    '  *) printf '\''unexpected cardano-cli vector: %s\n'\'' "$*" >&2; exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/cardano-cli"
  chmod 0755 "${FAKE_BIN}/cardano-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_REGISTER_SCENARIO:?}"; log="${CNTOOLS_WALLET_REGISTER_CURL_LOG:?}"' \
    'url="${*: -1}"; argument=""; previous=""; data=""' \
    'printf '\''curl'\'' >> "${log}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${log}"; [[ "${previous}" == --data ]] && data="${argument}"; previous="${argument}"; done' \
    'printf '\''\n'\'' >> "${log}"' \
    '[[ "${scenario}" != koios-all-fail ]] || { printf '\''koios request failed\n'\'' >&2; exit 28; }' \
    'case "${url}" in' \
    '  */address_utxos?*)' \
    '    [[ "${scenario}" != koios-balance-fail ]] || { printf '\''balance endpoint failed\n'\'' >&2; exit 28; }' \
    '    [[ "${scenario}" != koios-balance-malformed ]] || { printf '\''bad,csv\n'\''; exit 0; }' \
    '    printf '\''address,tx_hash,tx_index,value,asset_list\n'\''' \
    '    printf '\''%s,%s,0,10000000,"[]"\n'\'' "${CNTOOLS_WALLET_REGISTER_BASE:?}" "${CNTOOLS_WALLET_REGISTER_TX_HASH:?}"' \
    '    printf '\''%s,%s,1,500000,"[]"\n'\'' "${CNTOOLS_WALLET_REGISTER_PAY:?}" "${CNTOOLS_WALLET_REGISTER_TX_HASH:?}"' \
    '    ;;' \
    '  */account_info?*)' \
    '    [[ "${scenario}" != koios-reward-fail ]] || { printf '\''reward endpoint failed\n'\'' >&2; exit 28; }' \
    '    printf '\''stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit\n'\''' \
    '    if [[ "${scenario}" == koios-registered ]]; then status=registered; else status='\''not registered'\''; fi' \
    '    printf '\''%s,%s,,,0,2000000\n'\'' "${CNTOOLS_WALLET_REGISTER_REWARD:?}" "${status}"' \
    '    ;;' \
    '  *) printf '\''unexpected curl URL: %s\n'\'' "${url}" >&2; exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/curl"
  chmod 0755 "${FAKE_BIN}/curl"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'count_file="${CNTOOLS_WALLET_REGISTER_JQ_COUNT:?}"; log="${CNTOOLS_WALLET_REGISTER_JQ_LOG:?}"' \
    'count=0; [[ ! -f "${count_file}" ]] || read -r count < "${count_file}"; count=$((count + 1)); printf '\''%s\n'\'' "${count}" > "${count_file}"' \
    'printf '\''jq:%02d'\'' "${count}" >> "${log}"; for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${log}"; done; printf '\''\n'\'' >> "${log}"' \
    'if [[ "${CNTOOLS_WALLET_REGISTER_JQ_FAIL_CALL:-0}" == "${count}" ]]; then printf '\''%s\\033[31m\\n'\'' "${CNTOOLS_WALLET_REGISTER_RAW:?}" >&2; exit 42; fi' \
    'if [[ "${CNTOOLS_WALLET_REGISTER_JQ_MALICIOUS_ID:-N}" == Y && "$*" == "-r .id" ]]; then printf '\''x/../../outside-id\n'\''; exit 0; fi' \
    'exec "${CNTOOLS_WALLET_REGISTER_REAL_JQ:?}" "$@"' \
    > "${FAKE_BIN}/jq"
  chmod 0755 "${FAKE_BIN}/jq"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  *+%s*) printf '\''1700000000\n'\'' ;;' \
    '  *--iso-8601=s*) printf '\''2023-11-14T22:13:20+00:00\n'\'' ;;' \
    '  *) exec "${CNTOOLS_WALLET_REGISTER_REAL_DATE:?}" "$@" ;;' \
    'esac' \
    > "${FAKE_BIN}/date"
  chmod 0755 "${FAKE_BIN}/date"

  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${FAKE_BIN}/tput"
  chmod 0755 "${FAKE_BIN}/tput"

  for command_name in wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_WALLET_REGISTER_BLOCKED_LOG:?}"' \
      'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_WALLET_REGISTER_BLOCKED_LOG}"; done' \
      'printf '\''\n'\'' >> "${CNTOOLS_WALLET_REGISTER_BLOCKED_LOG}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

CNTOOLS_WALLET_REGISTER_REAL_DATE="$(command -v date)"
export CNTOOLS_WALLET_REGISTER_REAL_DATE
write_fake_commands

# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
# shellcheck source=/dev/null
. "${COMMON_DIALOG_SOURCE}"
# shellcheck source=/dev/null
. "${SELECTION_SOURCE}"
# shellcheck source=/dev/null
. "${GOVERNANCE_QUERY_SOURCE}"
# shellcheck source=/dev/null
. "${WALLET_QUERY_SOURCE}"
# shellcheck source=/dev/null
. "${WALLET_REGISTRATION_SOURCE}"
# shellcheck source=/dev/null
. "${TRANSACTION_SOURCE}"

# Preserve the exact inherited implementations before installing test-only
# controller/dependency adapters below.
eval "$(declare -f selectWallet | sed '1s/^selectWallet/legacy_selectWallet/')"
eval "$(declare -f getWalletBalance | sed '1s/^getWalletBalance/legacy_getWalletBalance/')"
eval "$(declare -f registerStakeWallet | sed '1s/^registerStakeWallet/legacy_registerStakeWallet/')"
eval "$(declare -f selectOpMode | sed '1s/^selectOpMode/legacy_selectOpMode/')"

println() {
  local level="${1:-}" newline=$'\n' message=""
  local messages=()
  shift || true
  if [[ "${1:-}" == false && $# -gt 2 ]]; then
    newline=""
    shift
  elif [[ "${1:-}" == true && $# -gt 2 ]]; then
    shift
  fi
  for message in "$@"; do [[ -z "${message}" ]] || messages+=("${message}"); done
  case "${level}" in
    ACTION|LOG) return 0 ;;
    OFF|DEBUG|INFO|ERROR) printf '%b%s' "${messages[@]}" "${newline}" ;;
    *) println INFO "${level}" "${messages[@]}" ;;
  esac
}

isNumber() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
formatLovelace() {
  local value="${1:-0}" whole=0 fraction=0 rendered=""
  isNumber "${value}" || return 1
  whole=$((value / 1000000)); fraction=$((value % 1000000))
  if ((fraction == 0)); then printf '%s' "${whole}"; return 0; fi
  printf -v rendered '%06d' "${fraction}"
  while [[ "${rendered}" == *0 ]]; do rendered="${rendered%0}"; done
  printf '%s.%s' "${whole}" "${rendered}"
}
formatAsset() { printf '%s\n' "${1:-0}"; }
hexToAscii() { printf '%s' "${1:-}"; }

clear() {
  if [[ "${CAPTURE_ACTIVE:-N}" == Y && "${END_ON_CLEAR:-N}" == Y ]]; then
    printf '__CNTOOLS_WALLET_REGISTER_END__\n'
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
  fi
  printf 'terminal:clear\n' >> "${EVENT_LOG:?}"
}

getEpoch() { printf '5\n'; }
timeUntilNextEpoch() { printf '0\n'; }
timeLeft() { printf 'delta-%s' "${1:-}"; }
slotInterval() { printf '20\n'; }
getSlotTipRef() { printf '1000\n'; }
getNodeMetrics() { printf 'runtime:getNodeMetrics\n' >> "${EVENT_LOG:?}"; slotnum=1000; }
getPriceInfo() { printf 'runtime:getPriceInfo\n' >> "${EVENT_LOG:?}"; price_now=""; }
updateProtocolParams() { printf 'runtime:updateProtocolParams\n' >> "${EVENT_LOG:?}"; }

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}" menu="" option="" index=0
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    printf '__CNTOOLS_WALLET_REGISTER_END__\n'
    CAPTURE_ACTIVE=N
  fi
  case "${1:-}" in
    '[w] Wallet') menu=main ;;
    '[n] New') menu=wallet ;;
    *) fail "unexpected public menu: ${1:-<empty>}" ;;
  esac
  [[ -n "${choice}" ]] || fail "${menu} menu exhausted choices"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      if [[ "${menu}:${choice}" == wallet:r ]]; then
        CAPTURE_ACTIVE=Y
        printf '__CNTOOLS_WALLET_REGISTER_BEGIN__\n'
        printf 'action:begin\n' >> "${EVENT_LOG}"
      fi
      selected_value="${option}"
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was unavailable in ${menu} menu"
}

selectOpMode() {
  printf 'action:selectOpMode\n' >> "${EVENT_LOG:?}"
  case "${SCENARIO:?}" in
    op-cancel) return 1 ;;
    *hybrid*) op_mode=hybrid ;;
    *) op_mode=online ;;
  esac
  return 0
}

selectWallet() {
  [[ $# == 1 && "${1:-}" == non-reg ]] || fail 'public wallet filter changed'
  printf 'action:selectWallet:non-reg\n' >> "${EVENT_LOG:?}"
  case "${SCENARIO:?}" in
    select-fail|already-registered)
      println INFO 'WARN: No wallets available that are unregistered!'
      return 1
      ;;
    select-cancel) return 2 ;;
    word-splitting) wallet_name='word splitting' ;;
    control-name) wallet_name=$'fixture\nRAW-CONTROL' ;;
    *) wallet_name=fixture_wallet ;;
  esac
}

getWalletType() {
  local selected="${1:-}"
  printf 'action:getWalletType:argc=%s:name=%q\n' "$#" "${selected}" >> "${EVENT_LOG:?}"
  payment_vk_file="${WALLET_FOLDER}/${selected}/${WALLET_PAY_VK_FILENAME}"
  payment_sk_file="${WALLET_FOLDER}/${selected}/${WALLET_PAY_SK_FILENAME}"
  payment_script_file="${WALLET_FOLDER}/${selected}/${WALLET_PAY_SCRIPT_FILENAME}"
  stake_vk_file="${WALLET_FOLDER}/${selected}/${WALLET_STAKE_VK_FILENAME}"
  stake_sk_file="${WALLET_FOLDER}/${selected}/${WALLET_STAKE_SK_FILENAME}"
  stake_script_file="${WALLET_FOLDER}/${selected}/${WALLET_STAKE_SCRIPT_FILENAME}"
  case "${SCENARIO:-}" in
    encrypted) return 2 ;;
    missing-signing) return 3 ;;
    missing-verification) return 4 ;;
  esac
  return "${DIRECT_WALLET_TYPE:-1}"
}

getWalletBalance() {
  printf 'action:getWalletBalance:argc=%s:%q\n' "$#" "${1:-}" >> "${EVENT_LOG:?}"
  if [[ "${SCENARIO:-}" == word-splitting || "${SCENARIO:-}" == control-name ]]; then
    [[ $# == 6 &&
       "${3:-}" == true && "${4:-}" == true && "${5:-}" == false &&
       "${6:-}" == true ]] || fail 'public word-split balance contract changed'
  else
    [[ $# == 5 && "${2:-}" == true && "${3:-}" == true &&
       "${4:-}" == false && "${5:-}" == true ]] ||
      fail 'public wallet balance contract changed'
  fi
  case "${SCENARIO:?}" in
    zero-balance) base_lovelace=0 ;;
    *) base_lovelace=10000000 ;;
  esac
}

registerStakeWallet() {
  printf 'action:registerStakeWallet:argc=%s' "$#" >> "${EVENT_LOG:?}"
  for _argument in "$@"; do printf ':%q' "${_argument}" >> "${EVENT_LOG}"; done
  printf '\n' >> "${EVENT_LOG}"
  case "${SCENARIO:?}" in
    register-fail|hybrid-register-fail|raw-helper-failure) return 1 ;;
    hybrid-prepared) return 2 ;;
  esac
  return 0
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    printf '__CNTOOLS_WALLET_REGISTER_END__\n'
    CAPTURE_ACTIVE=N
  fi
  return 0
}

myExit() {
  local status="${1:-0}" message="${2:-}"
  printf 'exit:%s:%s\n' "${status}" "${message}" >> "${EVENT_LOG:?}"
  [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
    fail 'public menu did not consume every scripted choice'
  exit "${status}"
}

extract_action_output() {
  local source="$1" target="$2"
  [[ "$(grep -c '^__CNTOOLS_WALLET_REGISTER_BEGIN__$' "${source}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_WALLET_REGISTER_END__$' "${source}" || true)" == 1 ]] ||
    fail 'wallet-register output markers changed'
  awk '
    $0 == "__CNTOOLS_WALLET_REGISTER_BEGIN__" { capture=1; next }
    $0 == "__CNTOOLS_WALLET_REGISTER_END__" { exit }
    capture { print }
  ' "${source}" > "${target}"
}

assert_no_secret() {
  local context="$1"
  shift
  ! grep -Fq -- "${SIGNING_SECRET}" "$@" ||
    fail "${context} exposed signing-key material"
}

assert_changed_paths() {
  local before="$1" after="$2" context="$3" expected_file="" actual_file=""
  shift 3
  expected_file="${TEST_ROOT}/expected-paths.$$"
  actual_file="${TEST_ROOT}/actual-paths.$$"
  : > "${expected_file}"
  while (($#)); do printf '%s\n' "$1" >> "${expected_file}"; shift; done
  LC_ALL=C sort -u "${expected_file}" -o "${expected_file}"
  awk -F '\t' '
    NR == FNR { before[$2]=$0; next }
    { after[$2]=$0; if (!($2 in before) || before[$2] != $0) changed[$2]=1 }
    END {
      for (path in before) if (!(path in after)) changed[path]=1
      for (path in changed) print path
    }
  ' "${before}" "${after}" | LC_ALL=C sort > "${actual_file}"
  assert_files_equal "${actual_file}" "${expected_file}" "${context} mutation allowlist"
  rm -f -- "${expected_file}" "${actual_file}"
}

assert_mode() {
  local target="$1" expected="$2" context="$3" actual=""
  actual="$(file_mode "${target}")" || fail "${context} mode unavailable"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${context} mode changed (${actual}, expected ${expected})"
}

write_out_of_scope_canary() {
  local target="$1"
  printf '%s\n' 'OUT_OF_SCOPE_CANARY_MUST_NOT_CHANGE' > "${target}"
  chmod 0640 "${target}"
}

assert_out_of_scope_canary() {
  local target="$1" context="$2"
  [[ -f "${target}" && ! -L "${target}" ]] ||
    fail "${context} out-of-scope canary type changed"
  [[ "$(< "${target}")" == 'OUT_OF_SCOPE_CANARY_MUST_NOT_CHANGE' ]] ||
    fail "${context} out-of-scope canary content changed"
  assert_mode "${target}" 640 "${context} out-of-scope canary"
}

public_mode() {
  case "$1" in
    offline) printf 'OFFLINE\n' ;;
    *light*) printf 'LIGHT\n' ;;
    *) printf 'LOCAL\n' ;;
  esac
}

run_public_case() (
  local scenario="$1" mode="" case_root="" runtime_root="" wallet_root=""
  local full_stdout="" action_stdout="" stderr_file="" event_log=""
  local blocked_log="" before="" after="" outside_canary="" status=0

  case_root="${TEST_ROOT}/public/${scenario}"
  runtime_root="${case_root}/runtime"
  wallet_root="${runtime_root}/wallet"
  full_stdout="${case_root}/full.stdout"
  action_stdout="${case_root}/action.stdout"
  stderr_file="${case_root}/stderr"
  event_log="${case_root}/events"
  blocked_log="${case_root}/blocked"
  before="${case_root}/before.tree"
  after="${case_root}/after.tree"
  outside_canary="${case_root}/out-of-scope.canary"
  mode="$(public_mode "${scenario}")"
  mkdir -p -- "${wallet_root}" "${runtime_root}/pool" \
    "${runtime_root}/asset" "${runtime_root}/tmp" "${runtime_root}/home"
  if [[ "${scenario}" != empty ]]; then
    mkdir -p -- "${wallet_root}/fixture_wallet"
    printf '%s\n' '{"description":"CLI Payment Verification Key"}' \
      > "${wallet_root}/fixture_wallet/payment.vkey"
    printf '%s\n' '{"description":"CLI Stake Verification Key"}' \
      > "${wallet_root}/fixture_wallet/stake.vkey"
    printf '%s\n' "${SIGNING_SECRET}" \
      > "${wallet_root}/fixture_wallet/payment.skey"
    printf '%s\n' "${SIGNING_SECRET}" \
      > "${wallet_root}/fixture_wallet/stake.skey"
    chmod 0600 "${wallet_root}/fixture_wallet/"*.skey
  fi
  write_out_of_scope_canary "${outside_canary}"
  tree_snapshot "${runtime_root}" "${before}" || fail "${scenario} pre-snapshot failed"
  : > "${event_log}"; : > "${blocked_log}"
  if (
    set +e; set +u; set +o pipefail
    export LC_ALL=C TZ=UTC
    PATH="${FAKE_BIN}:${BASE_PATH}"; export PATH
    HOME="${runtime_root}/home"; NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"; WALLET_FOLDER="${wallet_root}"
    POOL_FOLDER="${runtime_root}/pool"; ASSET_FOLDER="${runtime_root}/asset"
    BLOCKLOG_DB="${runtime_root}/absent.db"; NETWORK_NAME=Preview
    NETWORK_IDENTIFIER='--testnet-magic 42'; ADVANCED_MODE=true
    CNTOOLS_MODE="${mode}"; CNTOOLS_MODE_COLOR=""; KOIOS_API=""
    WALLET_SELECTION_FILTER_LIMIT=100; KEY_DEPOSIT=2000000
    price_now=""; slotnum=1000
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}" CAPTURE_ACTIVE=N SCENARIO="${scenario}"
    CNTOOLS_WALLET_REGISTER_BLOCKED_LOG="${blocked_log}"
    CHOICES=(w r h q); CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  [[ "${status}" == 0 ]] || fail "${scenario} public traversal returned ${status}"
  extract_action_output "${full_stdout}" "${action_stdout}"
  [[ ! -s "${stderr_file}" ]] || fail "${scenario} emitted unexpected stderr"
  [[ ! -s "${blocked_log}" ]] || fail "${scenario} attempted blocked network access"
  assert_no_secret "${scenario} public route" "${full_stdout}" "${stderr_file}" \
    "${event_log}" "${blocked_log}"
  grep -Fq ' >> WALLET >> REGISTER' "${action_stdout}" ||
    fail "${scenario} public header changed"

  case "${scenario}" in
    empty)
      grep -Fq 'No wallets available!' "${action_stdout}" ||
        fail 'empty-wallet output changed'
      ! grep -Fq 'action:selectOpMode' "${event_log}" ||
        fail 'empty-wallet route reached operation-mode prompt'
      grep -Fq 'action:waitToProceed' "${event_log}" ||
        fail 'empty-wallet wait changed'
      ;;
    offline)
      grep -Fq 'CNTools started in offline mode, option not available!' \
        "${action_stdout}" || fail 'offline rejection changed'
      ! grep -Fq 'action:selectOpMode' "${event_log}" ||
        fail 'offline route prompted for operation mode'
      ;;
    op-cancel)
      grep -Fq 'action:selectOpMode' "${event_log}" ||
        fail 'operation-mode cancellation was not offered'
      ! grep -Fq 'action:selectWallet' "${event_log}" ||
        fail 'operation-mode cancellation reached wallet selection'
      ! grep -Fq 'action:waitToProceed' "${event_log}" ||
        fail 'operation-mode cancellation unexpectedly waited'
      ;;
    select-fail|already-registered)
      grep -Fq 'WARN: No wallets available that are unregistered!' \
        "${action_stdout}" || fail "${scenario} selection warning changed"
      grep -Fq 'action:waitToProceed' "${event_log}" ||
        fail "${scenario} selection failure wait changed"
      ! grep -Fq 'action:getWalletType' "${event_log}" ||
        fail "${scenario} selection failure reached type validation"
      ;;
    select-cancel)
      ! grep -Fq 'action:waitToProceed' "${event_log}" ||
        fail 'wallet-selection cancellation unexpectedly waited'
      ! grep -Fq 'action:getWalletType' "${event_log}" ||
        fail 'wallet-selection cancellation reached type validation'
      ;;
    encrypted)
      grep -Fq 'signing keys encrypted, please decrypt before use!' \
        "${action_stdout}" || fail 'encrypted-wallet rejection changed'
      ! grep -Fq 'action:getWalletBalance' "${event_log}" ||
        fail 'encrypted-wallet rejection reached balance query'
      ;;
    missing-signing)
      grep -Fq 'payment and/or stake signing keys missing from wallet!' \
        "${action_stdout}" || fail 'missing-signing rejection changed'
      ! grep -Fq 'action:getWalletBalance' "${event_log}" ||
        fail 'missing-signing rejection reached balance query'
      ;;
    zero-balance)
      grep -Fq 'no funds available in base address for wallet fixture_wallet' \
        "${action_stdout}" || fail 'zero-balance rejection changed'
      grep -Fq 'Funds for key deposit(2 ADA) + transaction fee needed' \
        "${action_stdout}" || fail 'zero-balance deposit guidance changed'
      ! grep -Fq 'action:registerStakeWallet' "${event_log}" ||
        fail 'zero-balance route reached registration helper'
      ;;
    register-fail|hybrid-register-fail|hybrid-prepared)
      grep -Fq 'action:registerStakeWallet:argc=2:fixture_wallet:true' \
        "${event_log}" || fail "${scenario} helper ABI changed"
      ! grep -Fq 'successfully registered on chain!' "${action_stdout}" ||
        fail "${scenario} helper failure printed success"
      ;;
    word-splitting)
      grep -Fq 'action:getWalletType:argc=2:name=word' "${event_log}" ||
        fail 'public word-splitting defect changed at type validation'
      grep -Fq 'action:registerStakeWallet:argc=3:word:splitting:true' \
        "${event_log}" || fail 'public word-splitting defect changed at helper call'
      ;;
    control-name)
      grep -Fq 'RAW-CONTROL successfully registered on chain!' \
        "${action_stdout}" || fail 'public control-character reflection changed'
      ;;
    success|light-success|hybrid-success)
      grep -Fq 'fixture_wallet successfully registered on chain!' \
        "${action_stdout}" || fail "${scenario} success output changed"
      grep -Fq 'action:registerStakeWallet:argc=2:fixture_wallet:true' \
        "${event_log}" || fail "${scenario} helper ABI changed"
      ;;
  esac
  case "${scenario}" in
    op-cancel|select-cancel)
      [[ "$(grep -c '^action:waitToProceed$' "${event_log}" || true)" == 0 ]] ||
        fail "${scenario} public wait count changed"
      ;;
    *)
      [[ "$(grep -c '^action:waitToProceed$' "${event_log}" || true)" == 1 ]] ||
        fail "${scenario} public wait count changed"
      ;;
  esac
  printf '%s\n' 'menu:main:w' 'menu:wallet:r' 'menu:wallet:h' 'menu:main:q' \
    > "${case_root}/expected-menu"
  grep '^menu:' "${event_log}" > "${case_root}/actual-menu"
  assert_files_equal "${case_root}/actual-menu" "${case_root}/expected-menu" \
    "${scenario} public navigation"
  tree_snapshot "${runtime_root}" "${after}" || fail "${scenario} post-snapshot failed"
  assert_changed_paths "${before}" "${after}" "${scenario} public route"
  assert_out_of_scope_canary "${outside_canary}" "${scenario} public route"
)

PUBLIC_CASES=(
  empty offline op-cancel select-fail select-cancel already-registered
  encrypted missing-signing zero-balance register-fail success light-success
  hybrid-register-fail hybrid-prepared hybrid-success word-splitting control-name
)
for scenario in "${PUBLIC_CASES[@]}"; do run_public_case "${scenario}"; done

selectDir() {
  local type="${1:-}" first=""
  shift || true
  printf 'query:selectDir:%s' "${type}" >> "${EVENT_LOG:?}"
  for _entry in "$@"; do printf ':%q' "${_entry}" >> "${EVENT_LOG}"; done
  printf '\n' >> "${EVENT_LOG}"
  case "${SCENARIO:?}" in
    query-select-fail) return 1 ;;
    query-select-cancel) return 2 ;;
  esac
  first="${1:-}"
  [[ -n "${first}" ]] || return 1
  dir_name="${first}"
  return 0
}

write_wallet_fixture() {
  local wallet_dir="$1"
  mkdir -p -- "${wallet_dir}"
  printf '%s\n' '{"description":"CLI Payment Verification Key"}' \
    > "${wallet_dir}/payment.vkey"
  printf '%s\n' '{"description":"CLI Stake Verification Key"}' \
    > "${wallet_dir}/stake.vkey"
  printf '%s\n' "${SIGNING_SECRET}" > "${wallet_dir}/payment.skey"
  printf '%s\n' "${SIGNING_SECRET}" > "${wallet_dir}/stake.skey"
  chmod 0600 "${wallet_dir}/"*.skey
}

write_address_fixture() {
  local wallet_dir="$1"
  printf '%s\n' "${BASE_ADDR}" > "${wallet_dir}/base.addr"
  printf '%s\n' "${PAY_ADDR}" > "${wallet_dir}/payment.addr"
  printf '%s\n' "${REWARD_ADDR}" > "${wallet_dir}/reward.addr"
}

query_mode() {
  case "$1" in
    light-*|koios-*) printf 'LIGHT\n' ;;
    *) printf 'LOCAL\n' ;;
  esac
}

query_fake_scenario() {
  case "$1" in
    address-build) printf 'local-unregistered\n' ;;
    query-select-*) printf 'local-unregistered\n' ;;
    symlink-wallet) printf 'local-unregistered\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

run_query_case() (
  local scenario="$1" mode="" fake_scenario="" case_root="" runtime_root=""
  local wallet_root="" wallet_dir="" stdout_file="" stderr_file=""
  local event_log="" cli_log="" curl_log="" jq_log="" jq_count=""
  local blocked_log="" before="" after="" outside_canary="" status=0 expected_status=0

  case_root="${TEST_ROOT}/query/${scenario}"
  runtime_root="${case_root}/runtime"
  wallet_root="${runtime_root}/wallet"
  wallet_dir="${wallet_root}/fixture_wallet"
  stdout_file="${case_root}/stdout"
  stderr_file="${case_root}/stderr"
  event_log="${case_root}/events"
  cli_log="${case_root}/cli"
  curl_log="${case_root}/curl"
  jq_log="${case_root}/jq"
  jq_count="${case_root}/jq.count"
  blocked_log="${case_root}/blocked"
  before="${case_root}/before.tree"
  after="${case_root}/after.tree"
  outside_canary="${case_root}/out-of-scope.canary"
  mode="$(query_mode "${scenario}")"
  fake_scenario="$(query_fake_scenario "${scenario}")"
  mkdir -p -- "${wallet_root}" "${runtime_root}/tmp" "${runtime_root}/home"
  case "${scenario}" in
    query-empty) ;;
    symlink-wallet)
      mkdir -p -- "${runtime_root}/outside-wallet"
      write_wallet_fixture "${runtime_root}/outside-wallet"
      write_address_fixture "${runtime_root}/outside-wallet"
      ln -s -- "${runtime_root}/outside-wallet" "${wallet_dir}"
      ;;
    *)
      write_wallet_fixture "${wallet_dir}"
      [[ "${scenario}" == address-build ]] || write_address_fixture "${wallet_dir}"
      ;;
  esac
  write_out_of_scope_canary "${outside_canary}"
  tree_snapshot "${runtime_root}" "${before}" || fail "${scenario} query pre-snapshot failed"
  : > "${event_log}"; : > "${cli_log}"; : > "${curl_log}"
  : > "${jq_log}"; : > "${blocked_log}"
  if (
    set +e; set +u; set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    PATH="${FAKE_BIN}:${BASE_PATH}"; export PATH
    HOME="${runtime_root}/home"; NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"; WALLET_FOLDER="${wallet_root}"
    NETWORK_IDENTIFIER='--testnet-magic 42'; CNTOOLS_MODE="${mode}"
    CCLI=cardano-cli; WALLET_SELECTION_FILTER_LIMIT=100
    WALLET_PAY_VK_FILENAME=payment.vkey; WALLET_PAY_SK_FILENAME=payment.skey
    WALLET_STAKE_VK_FILENAME=stake.vkey; WALLET_STAKE_SK_FILENAME=stake.skey
    WALLET_PAY_SCRIPT_FILENAME=payment.script; WALLET_STAKE_SCRIPT_FILENAME=stake.script
    WALLET_BASE_ADDR_FILENAME=base.addr; WALLET_PAY_ADDR_FILENAME=payment.addr
    WALLET_STAKE_ADDR_FILENAME=reward.addr; WALLET_MULTISIG_PREFIX=multisig-
    WALLET_GOV_DREP_VK_FILENAME=drep.vkey; WALLET_GOV_CC_COLD_VK_FILENAME=cc-cold.vkey
    WALLET_GOV_CC_HOT_VK_FILENAME=cc-hot.vkey
    if [[ "${mode}" == LIGHT ]]; then KOIOS_API='https://koios.invalid/api/v1'; else KOIOS_API=""; fi
    KOIOS_API_HEADERS=()
    FG_RED="" FG_GREEN="" FG_YELLOW="" FG_LBLUE="" FG_LGRAY="" NC=""
    EVENT_LOG="${event_log}" SCENARIO="${scenario}"
    CNTOOLS_WALLET_REGISTER_SCENARIO="${fake_scenario}"
    CNTOOLS_WALLET_REGISTER_RUNTIME="${runtime_root}"
    CNTOOLS_WALLET_REGISTER_CLI_LOG="${cli_log}"
    CNTOOLS_WALLET_REGISTER_CURL_LOG="${curl_log}"
    CNTOOLS_WALLET_REGISTER_JQ_LOG="${jq_log}"
    CNTOOLS_WALLET_REGISTER_JQ_COUNT="${jq_count}"
    CNTOOLS_WALLET_REGISTER_JQ_FAIL_CALL=0
    CNTOOLS_WALLET_REGISTER_JQ_MALICIOUS_ID=N
    CNTOOLS_WALLET_REGISTER_REAL_JQ="${REAL_JQ_PATH}"
    CNTOOLS_WALLET_REGISTER_RAW="${RAW_DIAGNOSTIC}"
    CNTOOLS_WALLET_REGISTER_BASE="${BASE_ADDR}"
    CNTOOLS_WALLET_REGISTER_PAY="${PAY_ADDR}"
    CNTOOLS_WALLET_REGISTER_REWARD="${REWARD_ADDR}"
    CNTOOLS_WALLET_REGISTER_TX_HASH="${TX_HASH}"
    CNTOOLS_WALLET_REGISTER_BLOCKED_LOG="${blocked_log}"
    export CNTOOLS_WALLET_REGISTER_SCENARIO CNTOOLS_WALLET_REGISTER_RUNTIME
    export CNTOOLS_WALLET_REGISTER_CLI_LOG CNTOOLS_WALLET_REGISTER_CURL_LOG
    export CNTOOLS_WALLET_REGISTER_JQ_LOG CNTOOLS_WALLET_REGISTER_JQ_COUNT
    export CNTOOLS_WALLET_REGISTER_JQ_FAIL_CALL CNTOOLS_WALLET_REGISTER_JQ_MALICIOUS_ID
    export CNTOOLS_WALLET_REGISTER_REAL_JQ CNTOOLS_WALLET_REGISTER_RAW
    export CNTOOLS_WALLET_REGISTER_BASE CNTOOLS_WALLET_REGISTER_PAY
    export CNTOOLS_WALLET_REGISTER_REWARD CNTOOLS_WALLET_REGISTER_TX_HASH
    export CNTOOLS_WALLET_REGISTER_BLOCKED_LOG
    legacy_selectWallet non-reg
  ) > "${stdout_file}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  case "${scenario}" in
    query-empty|local-registered|koios-registered|symlink-wallet|query-select-fail)
      expected_status=1 ;;
    query-select-cancel) expected_status=2 ;;
    *) expected_status=0 ;;
  esac
  [[ "${status}" == "${expected_status}" ]] ||
    fail "${scenario} query status ${status}, expected ${expected_status}"
  [[ ! -s "${blocked_log}" ]] || fail "${scenario} used a blocked network tool"
  assert_no_secret "${scenario} query route" "${stdout_file}" "${stderr_file}" \
    "${event_log}" "${cli_log}" "${curl_log}" "${jq_log}" "${blocked_log}"
  case "${scenario}" in
    local-stake-malformed|local-stake-query-fail|local-utxo-fail)
      [[ -s "${stderr_file}" ]] || fail 'malformed local query no longer emits raw jq diagnostics'
      ;;
    *)
      [[ ! -s "${stderr_file}" ]] || fail "${scenario} query emitted unexpected stderr"
      ;;
  esac
  case "${scenario}" in
    query-empty|local-registered|koios-registered|symlink-wallet)
      ! grep -Fq 'query:selectDir:' "${event_log}" ||
        fail "${scenario} unexpectedly offered a wallet"
      ;;
    query-select-fail|query-select-cancel)
      grep -Fq 'query:selectDir:wallet:fixture_wallet' "${event_log}" ||
        fail "${scenario} selectable-wallet list changed"
      ;;
    *)
      grep -Fq 'query:selectDir:wallet:fixture_wallet' "${event_log}" ||
        fail "${scenario} selectable-wallet list changed"
      ;;
  esac
  case "${scenario}" in
    light-*|koios-*)
      [[ "$(grep -c '^curl' "${curl_log}" || true)" == 2 ]] ||
        fail "${scenario} Koios query count changed"
      [[ ! -s "${cli_log}" ]] || fail "${scenario} unexpectedly queried the local CLI"
      ;;
    query-empty|symlink-wallet)
      [[ ! -s "${curl_log}" && ! -s "${cli_log}" ]] ||
        fail "${scenario} unexpectedly queried external state"
      ;;
    *)
      [[ ! -s "${curl_log}" ]] || fail "${scenario} unexpectedly queried Koios"
      grep -Fq $'cardano-cli\tquery\tstake-address-info' "${cli_log}" ||
        fail "${scenario} local registration query vector changed"
      ;;
  esac
  case "${scenario}" in
    local-stake-query-fail|local-stake-malformed|local-utxo-fail|koios-balance-fail|\
      koios-balance-malformed|koios-reward-fail|koios-all-fail)
      [[ "${status}" == 0 ]] || fail "${scenario} legacy fail-open selection changed"
      ;;
  esac
  tree_snapshot "${runtime_root}" "${after}" || fail "${scenario} query post-snapshot failed"
  if [[ "${scenario}" == address-build ]]; then
    assert_changed_paths "${before}" "${after}" "${scenario} query" \
      'wallet/fixture_wallet/base.addr' 'wallet/fixture_wallet/payment.addr' \
      'wallet/fixture_wallet/reward.addr'
    assert_mode "${wallet_dir}/base.addr" 644 'legacy base-address cache'
    assert_mode "${wallet_dir}/payment.addr" 644 'legacy payment-address cache'
    assert_mode "${wallet_dir}/reward.addr" 644 'legacy reward-address cache'
  else
    assert_changed_paths "${before}" "${after}" "${scenario} query"
  fi
  assert_out_of_scope_canary "${outside_canary}" "${scenario} query"
)

QUERY_CASES=(
  query-empty local-unregistered local-registered local-stake-query-fail
  local-stake-malformed local-utxo-fail light-unregistered koios-registered
  koios-balance-fail koios-balance-malformed koios-reward-fail koios-all-fail
  query-select-fail query-select-cancel address-build symlink-wallet
)
for scenario in "${QUERY_CASES[@]}"; do run_query_case "${scenario}"; done

versionCheck() {
  printf 'register:versionCheck:%s:%s\n' "${1:-}" "${2:-}" >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != protocol-8 ]]
}

validateMultiSigScript() {
  REGISTER_SCRIPT_CALL=$((REGISTER_SCRIPT_CALL + 1))
  printf 'register:validateMultiSigScript:%s:%s\n' \
    "${REGISTER_SCRIPT_CALL}" "${1:-}" >> "${EVENT_LOG:?}"
  if [[ "${REGISTER_SCRIPT_CALL}" == 1 ]]; then required_total=2; else required_total=3; fi
}

getTTL() {
  printf 'register:getTTL:%s\n' "${1:-}" >> "${EVENT_LOG:?}"
  ttl=200
  case "${SCENARIO:?}" in
    ttl-fail|cert-symlink|cert-hardlink|traversal-name|word-splitting-direct)
      return 1 ;;
  esac
  return 0
}

getAssetsTxOut() {
  printf 'register:getAssetsTxOut\n' >> "${EVENT_LOG:?}"
  assets_tx_out='+7 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.746f6b656e'
}

buildTx() {
  local explicit_output="${1:-}" output="" previous="" argument=""
  REGISTER_BUILD_CALL=$((REGISTER_BUILD_CALL + 1))
  printf 'register:buildTx:%s:%q\n' "${REGISTER_BUILD_CALL}" "${explicit_output}" \
    >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != build-draft-fail || "${REGISTER_BUILD_CALL}" != 1 ]] ||
    return 1
  [[ "${SCENARIO:-}" != build-final-fail || "${REGISTER_BUILD_CALL}" != 2 ]] ||
    return 1
  if [[ -n "${explicit_output}" ]]; then
    output="${explicit_output}"
  else
    for argument in "${build_args[@]}"; do
      [[ "${previous}" == --out-file ]] && output="${argument}"
      previous="${argument}"
    done
  fi
  [[ -n "${output}" ]] || fail 'registration build output was not supplied'
  printf '%s\n' '{"type":"TxBodyShelley","description":"fixture transaction body","cborHex":"84a40081825820aa"}' \
    > "${output}"
}

calcMinFee() {
  printf 'register:calcMinFee:%q:%s:%s:%s\n' \
    "${1:-}" "${2:-}" "${3:-}" "${4:-}" >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != fee-fail ]] || return 1
  min_fee=200000
}

getMinUTxO() {
  printf 'register:getMinUTxO:%q\n' "${1:-}" >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != min-utxo-fail ]] || return 1
  if [[ "${SCENARIO:-}" == insufficient-min-utxo ]]; then
    min_utxo_out=9000000
  else
    min_utxo_out=1000000
  fi
}

witnessTx() {
  printf 'register:witnessTx:%q:%q:%q\n' "${1:-}" "${2:-}" "${3:-}" \
    >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != witness-fail ]] || return 1
  printf '%s\n' '{"type":"TxWitnessShelley","description":"fixture witness"}' \
    > "${TMP_DIR}/tx.witness"
}

assembleTx() {
  printf 'register:assembleTx:%q\n' "${1:-}" >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != assemble-fail ]] || return 1
  tx_signed="${TMP_DIR}/tx.signed"
  printf '%s\n' '{"type":"Tx ConwayEra","description":"fixture signed transaction"}' \
    > "${tx_signed}"
}

submitTx() {
  printf 'register:submitTx:%q\n' "${1:-}" >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != submit-fail ]]
}

verifyTx() {
  printf 'register:verifyTx:%q\n' "${1:-}" >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != verify-fail ]]
}

direct_mode() {
  case "$1" in
    hybrid-*|multisig-hybrid|malicious-offline-id|jq-fail-*) printf 'hybrid\n' ;;
    *) printf 'online\n' ;;
  esac
}

direct_cntools_mode() {
  case "$1" in
    light-online) printf 'LIGHT\n' ;;
    *) printf 'LOCAL\n' ;;
  esac
}

direct_wallet_type() {
  case "$1" in
    online-hardware) printf '0\n' ;;
    multisig-hybrid) printf '5\n' ;;
    *) printf '1\n' ;;
  esac
}

direct_fake_scenario() {
  case "$1" in
    cert-fail|raw-diagnostic|malformed-cert) printf '%s\n' "$1" ;;
    *) printf 'register-default\n' ;;
  esac
}

direct_wallet_name() {
  case "$1" in
    traversal-name) printf '../outside-wallet\n' ;;
    word-splitting-direct) printf 'word splitting\n' ;;
    *) printf 'fixture_wallet\n' ;;
  esac
}

jq_fail_call() {
  case "$1" in
    jq-fail-*) printf '%s\n' "${1##jq-fail-}" ;;
    *) printf '0\n' ;;
  esac
}

prepare_direct_fixture() {
  local scenario="$1" runtime_root="$2" wallet_root="$3" wallet_name="$4"
  local wallet_dir="${wallet_root}/${wallet_name}"

  case "${scenario}" in
    traversal-name) wallet_dir="${runtime_root}/outside-wallet" ;;
    word-splitting-direct)
      write_wallet_fixture "${wallet_root}/word"
      write_address_fixture "${wallet_root}/word"
      ;;
  esac
  write_wallet_fixture "${wallet_dir}"
  write_address_fixture "${wallet_dir}"
  printf '%s\n' '{"type":"SimpleScript","scripts":[]}' > "${wallet_dir}/payment.script"
  printf '%s\n' '{"type":"SimpleScript","scripts":[]}' > "${wallet_dir}/stake.script"
  case "${scenario}" in
    cert-symlink)
      printf '%s\n' outside-original > "${runtime_root}/outside-cert"
      chmod 0640 "${runtime_root}/outside-cert"
      ln -s -- "${runtime_root}/outside-cert" "${wallet_dir}/stake.cert"
      ;;
    cert-hardlink)
      printf '%s\n' outside-original > "${runtime_root}/outside-cert"
      chmod 0640 "${runtime_root}/outside-cert"
      ln -- "${runtime_root}/outside-cert" "${wallet_dir}/stake.cert"
      ;;
    cert-fifo)
      mkfifo "${wallet_dir}/stake.cert"
      chmod 0640 "${wallet_dir}/stake.cert"
      ;;
    malicious-offline-id)
      mkdir -p -- "${runtime_root}/tmp/offline_tx_x"
      ;;
  esac
}

expected_direct_status() {
  case "$1" in
    hybrid-success|multisig-hybrid|malicious-offline-id) printf '2\n' ;;
    online-success|online-hardware|light-online|protocol-8|malformed-cert|confirm-registration) printf '0\n' ;;
    jq-fail-18|jq-fail-19) printf '2\n' ;;
    jq-fail-*) printf '1\n' ;;
    *) printf '1\n' ;;
  esac
}

assert_direct_mutation() {
  local scenario="$1" before="$2" after="$3" wallet_name="$4"
  local wallet_prefix="wallet/${wallet_name}" offline_name='tmp/offline_tx_1700000000.json'
  local expected=()

  case "${scenario}" in
    cert-fail|raw-diagnostic|cert-fifo) ;;
    cert-symlink) expected=('outside-cert') ;;
    cert-hardlink) expected=('outside-cert' "${wallet_prefix}/stake.cert") ;;
    traversal-name) expected=('outside-wallet/stake.cert') ;;
    word-splitting-direct) expected=('wallet/word\ splitting/stake.cert') ;;
    ttl-fail|build-draft-fail) expected=("${wallet_prefix}/stake.cert") ;;
    fee-fail|insufficient-deposit|min-utxo-fail|insufficient-min-utxo|build-final-fail)
      expected=("${wallet_prefix}/stake.cert" 'tmp/tx0.tmp')
      ;;
    witness-fail)
      expected=("${wallet_prefix}/stake.cert" 'tmp/tx0.tmp' 'tmp/tx.raw')
      ;;
    assemble-fail)
      expected=("${wallet_prefix}/stake.cert" 'tmp/tx0.tmp' 'tmp/tx.raw' 'tmp/tx.witness')
      ;;
    submit-fail|verify-fail|online-success|online-hardware|light-online|protocol-8|malformed-cert|confirm-registration)
      expected=("${wallet_prefix}/stake.cert" 'tmp/tx0.tmp' 'tmp/tx.raw' \
        'tmp/tx.witness' 'tmp/tx.signed')
      ;;
    hybrid-success|multisig-hybrid)
      expected=("${wallet_prefix}/stake.cert" 'tmp/tx0.tmp' 'tmp/tx.raw' "${offline_name}")
      ;;
    malicious-offline-id)
      expected=("${wallet_prefix}/stake.cert" 'tmp/tx0.tmp' 'tmp/tx.raw' 'outside-id.json')
      ;;
    jq-fail-18)
      expected=("${wallet_prefix}/stake.cert" 'tmp/tx0.tmp' 'tmp/tx.raw' 'tmp/offline_tx_.json')
      ;;
    jq-fail-19)
      expected=("${wallet_prefix}/stake.cert" 'tmp/tx0.tmp' 'tmp/tx.raw' "${offline_name}")
      ;;
    jq-fail-*)
      expected=("${wallet_prefix}/stake.cert" 'tmp/tx0.tmp' 'tmp/tx.raw')
      ;;
    *) fail "unknown direct mutation scenario: ${scenario}" ;;
  esac
  assert_changed_paths "${before}" "${after}" "${scenario} direct" "${expected[@]}"
}

run_direct_case() (
  local scenario="$1" mode="" cntools_mode="" wallet_type="" fake_scenario=""
  local wallet_name="" jq_failure="" case_root="" runtime_root="" wallet_root=""
  local stdout_file="" stderr_file="" event_log="" cli_log="" curl_log=""
  local jq_log="" jq_count="" blocked_log="" before="" after=""
  local status=0 expected_status=0 wallet_dir="" outside_canary=""

  case_root="${TEST_ROOT}/direct/${scenario}"
  runtime_root="${case_root}/runtime"
  wallet_root="${runtime_root}/wallet"
  stdout_file="${case_root}/stdout"
  stderr_file="${case_root}/stderr"
  event_log="${case_root}/events"
  cli_log="${case_root}/cli"
  curl_log="${case_root}/curl"
  jq_log="${case_root}/jq"
  jq_count="${case_root}/jq.count"
  blocked_log="${case_root}/blocked"
  before="${case_root}/before.tree"
  after="${case_root}/after.tree"
  outside_canary="${case_root}/out-of-scope.canary"
  mode="$(direct_mode "${scenario}")"
  cntools_mode="$(direct_cntools_mode "${scenario}")"
  wallet_type="$(direct_wallet_type "${scenario}")"
  fake_scenario="$(direct_fake_scenario "${scenario}")"
  wallet_name="$(direct_wallet_name "${scenario}")"
  jq_failure="$(jq_fail_call "${scenario}")"
  mkdir -p -- "${wallet_root}" "${runtime_root}/tmp" "${runtime_root}/home"
  prepare_direct_fixture "${scenario}" "${runtime_root}" "${wallet_root}" "${wallet_name}"
  write_out_of_scope_canary "${outside_canary}"
  tree_snapshot "${runtime_root}" "${before}" || fail "${scenario} direct pre-snapshot failed"
  : > "${event_log}"; : > "${cli_log}"; : > "${curl_log}"
  : > "${jq_log}"; : > "${blocked_log}"
  if (
    set +e; set +u; set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    PATH="${FAKE_BIN}:${BASE_PATH}"; export PATH
    HOME="${runtime_root}/home"; NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"; WALLET_FOLDER="${wallet_root}"
    NETWORK_IDENTIFIER='--testnet-magic 42'; CNTOOLS_MODE="${cntools_mode}"
    CCLI=cardano-cli; KOIOS_API=""; PROT_VERSION=9.0
    KEY_DEPOSIT=2000000; DUMMYFEE=0; ttl=200; ttl_enter=300
    base_addr="${BASE_ADDR}"; pay_addr="${PAY_ADDR}"; reward_addr="${REWARD_ADDR}"
    if [[ "${scenario}" == insufficient-deposit ]]; then base_lovelace=2100000; else base_lovelace=10000000; fi
    min_fee=200000; min_utxo_out=1000000
    tx_in=' --tx-in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#0'
    utxo_cnt=1; reward_lovelace=123
    op_mode="${mode}"; DIRECT_WALLET_TYPE="${wallet_type}"
    REGISTER_BUILD_CALL=0; REGISTER_SCRIPT_CALL=0
    declare -A utxos_cnt=() tx_in_arr=() assets=()
    utxos_cnt["${BASE_ADDR}"]=1
    tx_in_arr["${BASE_ADDR}"]=' --tx-in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#0'
    assets[lovelace]=10000000
    WALLET_PAY_VK_FILENAME=payment.vkey; WALLET_PAY_SK_FILENAME=payment.skey
    WALLET_STAKE_VK_FILENAME=stake.vkey; WALLET_STAKE_SK_FILENAME=stake.skey
    WALLET_PAY_SCRIPT_FILENAME=payment.script; WALLET_STAKE_SCRIPT_FILENAME=stake.script
    WALLET_STAKE_CERT_FILENAME=stake.cert
    FG_RED="" FG_GREEN="" FG_YELLOW="" FG_LBLUE="" FG_LGRAY="" NC=""
    EVENT_LOG="${event_log}" SCENARIO="${scenario}"
    CNTOOLS_WALLET_REGISTER_SCENARIO="${fake_scenario}"
    CNTOOLS_WALLET_REGISTER_RUNTIME="${runtime_root}"
    CNTOOLS_WALLET_REGISTER_CLI_LOG="${cli_log}"
    CNTOOLS_WALLET_REGISTER_CURL_LOG="${curl_log}"
    CNTOOLS_WALLET_REGISTER_JQ_LOG="${jq_log}"
    CNTOOLS_WALLET_REGISTER_JQ_COUNT="${jq_count}"
    CNTOOLS_WALLET_REGISTER_JQ_FAIL_CALL="${jq_failure#0}"
    [[ -n "${CNTOOLS_WALLET_REGISTER_JQ_FAIL_CALL}" ]] || CNTOOLS_WALLET_REGISTER_JQ_FAIL_CALL=0
    if [[ "${scenario}" == malicious-offline-id ]]; then CNTOOLS_WALLET_REGISTER_JQ_MALICIOUS_ID=Y; else CNTOOLS_WALLET_REGISTER_JQ_MALICIOUS_ID=N; fi
    CNTOOLS_WALLET_REGISTER_REAL_JQ="${REAL_JQ_PATH}"
    CNTOOLS_WALLET_REGISTER_RAW="${RAW_DIAGNOSTIC}"
    CNTOOLS_WALLET_REGISTER_BASE="${BASE_ADDR}"
    CNTOOLS_WALLET_REGISTER_PAY="${PAY_ADDR}"
    CNTOOLS_WALLET_REGISTER_REWARD="${REWARD_ADDR}"
    CNTOOLS_WALLET_REGISTER_TX_HASH="${TX_HASH}"
    CNTOOLS_WALLET_REGISTER_BLOCKED_LOG="${blocked_log}"
    export CNTOOLS_WALLET_REGISTER_SCENARIO CNTOOLS_WALLET_REGISTER_RUNTIME
    export CNTOOLS_WALLET_REGISTER_CLI_LOG CNTOOLS_WALLET_REGISTER_CURL_LOG
    export CNTOOLS_WALLET_REGISTER_JQ_LOG CNTOOLS_WALLET_REGISTER_JQ_COUNT
    export CNTOOLS_WALLET_REGISTER_JQ_FAIL_CALL CNTOOLS_WALLET_REGISTER_JQ_MALICIOUS_ID
    export CNTOOLS_WALLET_REGISTER_REAL_JQ CNTOOLS_WALLET_REGISTER_RAW
    export CNTOOLS_WALLET_REGISTER_BASE CNTOOLS_WALLET_REGISTER_PAY
    export CNTOOLS_WALLET_REGISTER_REWARD CNTOOLS_WALLET_REGISTER_TX_HASH
    export CNTOOLS_WALLET_REGISTER_BLOCKED_LOG
    if [[ "${scenario}" == confirm-registration ]]; then
      legacy_registerStakeWallet "${wallet_name}"
    else
      legacy_registerStakeWallet "${wallet_name}" true
    fi
  ) > "${stdout_file}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  expected_status="$(expected_direct_status "${scenario}")"
  if [[ "${status}" != "${expected_status}" ]]; then
    fail "${scenario} direct status ${status}, expected ${expected_status}"
  fi
  printf '%s\n' "${status}" > "${case_root}/status"
  [[ ! -s "${blocked_log}" ]] || fail "${scenario} used a blocked network tool"
  [[ ! -s "${curl_log}" ]] || fail "${scenario} unexpectedly queried the network"
  assert_no_secret "${scenario} direct route" "${stdout_file}" "${stderr_file}" \
    "${event_log}" "${cli_log}" "${curl_log}" "${jq_log}" "${blocked_log}"
  [[ "$(grep -c '^cardano-cli' "${cli_log}" || true)" == 1 ]] ||
    fail "${scenario} registration-certificate CLI count changed"
  grep -Fq $'cardano-cli\tlatest\tstake-address\tregistration-certificate' \
    "${cli_log}" || fail "${scenario} certificate CLI vector changed"
  case "${scenario}" in
    protocol-8)
      ! grep -Fq -- '--key-reg-deposit-amt' "${cli_log}" ||
        fail 'protocol-8 certificate unexpectedly included deposit amount'
      ;;
    *)
      grep -Fq -- '--key-reg-deposit-amt' "${cli_log}" ||
        fail "${scenario} certificate deposit vector changed"
      ;;
  esac
  case "${scenario}" in
    raw-diagnostic)
      grep -Fq -- "${RAW_DIAGNOSTIC}" "${stdout_file}" ||
        fail 'legacy raw CLI diagnostic reflection changed'
      [[ ! -s "${stderr_file}" ]] || fail 'raw CLI diagnostic escaped the println channel'
      ;;
    jq-fail-*)
      grep -Fq -- "${RAW_DIAGNOSTIC}" "${stderr_file}" ||
        fail "${scenario} raw jq diagnostic behavior changed"
      _jq_failure_index=$((10#${scenario##jq-fail-}))
      case "${_jq_failure_index}" in
        11|12) _expected_jq_count=12 ;;
        13|14) _expected_jq_count=14 ;;
        15|16) _expected_jq_count=16 ;;
        18|19) _expected_jq_count=19 ;;
        *) _expected_jq_count=${_jq_failure_index} ;;
      esac
      [[ "$(wc -l < "${jq_log}" | tr -d '[:space:]')" == "${_expected_jq_count}" ]] ||
        fail "${scenario} jq stop/continue order changed"
      ;;
    *)
      [[ ! -s "${stderr_file}" ]] || fail "${scenario} direct emitted unexpected stderr"
      ;;
  esac
  case "${scenario}" in
    word-splitting-direct)
      grep -Fq 'action:getWalletType:argc=2:name=word' "${event_log}" ||
        fail 'direct word-splitting defect changed'
      ;;
    multisig-hybrid)
      [[ "$(grep -c '^register:validateMultiSigScript:' "${event_log}" || true)" == 2 ]] ||
        fail 'multisig script-validation order changed'
      grep -Fq 'register:getTTL:true' "${event_log}" ||
        fail 'multisig TTL contract changed'
      ;;
    confirm-registration)
      grep -Fq 'action:waitToProceed' "${event_log}" ||
        fail 'legacy registration confirmation wait changed'
      ;;
  esac
  case "${scenario}" in
    online-success|hybrid-success)
      sed "s#${runtime_root}#<runtime>#g" "${event_log}" > "${case_root}/events.normalized"
      printf '%s\n' \
        'action:getWalletType:argc=1:name=fixture_wallet' \
        'register:versionCheck:9.0:9.0' \
        'register:getTTL:' \
        'register:getAssetsTxOut' \
        "register:buildTx:1:''" \
        'register:calcMinFee:<runtime>/tmp/tx0.tmp:1:1:2' \
        'register:getMinUTxO:addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq+7800000+7\ aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.746f6b656e' \
        "register:buildTx:2:''" \
        > "${case_root}/events.expected"
      if [[ "${scenario}" == online-success ]]; then
        printf '%s\n' \
          'register:witnessTx:<runtime>/tmp/tx.raw:<runtime>/wallet/fixture_wallet/stake.skey:<runtime>/wallet/fixture_wallet/payment.skey' \
          'register:assembleTx:<runtime>/tmp/tx.raw' \
          'register:submitTx:<runtime>/tmp/tx.signed' \
          'register:verifyTx:addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq' \
          >> "${case_root}/events.expected"
      fi
      assert_files_equal "${case_root}/events.normalized" "${case_root}/events.expected" \
        "${scenario} deterministic transaction order"
      ;;
  esac
  tree_snapshot "${runtime_root}" "${after}" || fail "${scenario} direct post-snapshot failed"
  assert_direct_mutation "${scenario}" "${before}" "${after}" "${wallet_name}"
  case "${scenario}" in
    cert-fail|raw-diagnostic|cert-fifo) ;;
    cert-symlink|cert-hardlink)
      assert_mode "${runtime_root}/outside-cert" 640 "${scenario} outside certificate"
      ;;
    traversal-name)
      assert_mode "${runtime_root}/outside-wallet/stake.cert" 644 'traversal certificate'
      ;;
    word-splitting-direct)
      assert_mode "${wallet_root}/word splitting/stake.cert" 644 'word-split certificate'
      ;;
    *)
      wallet_dir="${wallet_root}/${wallet_name}"
      assert_mode "${wallet_dir}/stake.cert" 644 "${scenario} certificate"
      ;;
  esac
  for _artifact in tx0.tmp tx.raw tx.witness tx.signed \
    offline_tx_1700000000.json offline_tx_.json; do
    [[ ! -e "${runtime_root}/tmp/${_artifact}" ]] ||
      assert_mode "${runtime_root}/tmp/${_artifact}" 644 "${scenario} ${_artifact}"
  done
  if [[ -f "${runtime_root}/tmp/tx.raw" ]]; then
    "${REAL_JQ_PATH}" -e '.type == "TxBodyShelley" and (.cborHex | type == "string")' \
      "${runtime_root}/tmp/tx.raw" >/dev/null ||
      fail "${scenario} transaction-body fixture changed"
  fi
  case "${scenario}" in
    hybrid-success|multisig-hybrid)
      "${REAL_JQ_PATH}" -e '.type == "Wallet Registration" and
        ."wallet-name" == "fixture_wallet" and .txFee == "2200000" and
        (.txBody.type == "TxBodyShelley")' \
        "${runtime_root}/tmp/offline_tx_1700000000.json" >/dev/null ||
        fail "${scenario} offline transaction schema changed"
      ;;
    jq-fail-18)
      "${REAL_JQ_PATH}" -e '.type == "Wallet Registration" and
        ."wallet-name" == "fixture_wallet"' \
        "${runtime_root}/tmp/offline_tx_.json" >/dev/null ||
        fail 'jq id failure residue schema changed'
      ;;
    jq-fail-19)
      [[ ! -s "${runtime_root}/tmp/offline_tx_1700000000.json" ]] ||
        fail 'jq final-write failure no longer leaves an empty offline file'
      ;;
    malformed-cert)
      ! "${REAL_JQ_PATH}" -e . "${wallet_root}/fixture_wallet/stake.cert" \
        >/dev/null 2>&1 || fail 'malformed certificate is no longer accepted unchecked'
      ;;
    cert-symlink)
      [[ -L "${wallet_root}/fixture_wallet/stake.cert" ]] ||
        fail 'certificate symlink was replaced instead of followed'
      grep -Fq 'StakeAddressRegistrationCertificate' "${runtime_root}/outside-cert" ||
        fail 'certificate symlink no longer mutated its outside target'
      ;;
    cert-hardlink)
      [[ "${wallet_root}/fixture_wallet/stake.cert" -ef "${runtime_root}/outside-cert" ]] ||
        fail 'certificate hardlink identity changed'
      ;;
    cert-fifo)
      [[ -p "${wallet_root}/fixture_wallet/stake.cert" ]] ||
        fail 'certificate FIFO residue changed'
      ;;
  esac
  if [[ "${scenario}" == malicious-offline-id ]]; then
    [[ -f "${runtime_root}/outside-id.json" ]] ||
      fail 'legacy jq-controlled offline path no longer escaped TMP_DIR'
  fi
  assert_out_of_scope_canary "${outside_canary}" "${scenario} direct route"
)

DIRECT_CASES=(
  online-success online-hardware light-online protocol-8 confirm-registration hybrid-success
  multisig-hybrid cert-fail raw-diagnostic ttl-fail build-draft-fail fee-fail
  insufficient-deposit min-utxo-fail insufficient-min-utxo build-final-fail
  witness-fail assemble-fail submit-fail verify-fail malformed-cert
  cert-symlink cert-hardlink cert-fifo traversal-name word-splitting-direct
  malicious-offline-id
)
for scenario in "${DIRECT_CASES[@]}"; do run_direct_case "${scenario}"; done

JQ_FAILURE_CASES=()
for ((jq_index=1; jq_index<=19; jq_index++)); do
  printf -v scenario 'jq-fail-%02d' "${jq_index}"
  JQ_FAILURE_CASES+=("${scenario}")
  run_direct_case "${scenario}"
done

# Exercise the inherited operation-mode prompt itself after the public lane has
# completed; the public lane uses a deterministic adapter so it can traverse
# the whole controller without an interactive terminal.
select_opt() {
  printf 'prompt' >> "${OP_MODE_LOG:?}"
  for _option in "$@"; do printf '\t%s' "${_option}" >> "${OP_MODE_LOG}"; done
  printf '\n' >> "${OP_MODE_LOG}"
  return "${OP_MODE_CHOICE:?}"
}

run_op_mode_case() (
  local scenario="$1" choice=0 expected_status=0 expected_mode="" case_root=""
  local stdout_file="" stderr_file="" status=0
  case_root="${TEST_ROOT}/op-mode/${scenario}"
  stdout_file="${case_root}/stdout"
  stderr_file="${case_root}/stderr"
  mkdir -p -- "${case_root}"
  case "${scenario}" in
    online) choice=0; expected_mode=online ;;
    hybrid) choice=1; expected_mode=hybrid ;;
    cancel) choice=2; expected_status=1; expected_mode=unchanged ;;
    *) fail "unknown operation-mode case: ${scenario}" ;;
  esac
  : > "${case_root}/prompt"
  if (
    set +e; set +u
    OP_MODE_LOG="${case_root}/prompt" OP_MODE_CHOICE="${choice}"
    EVENT_LOG="${case_root}/events" op_mode=unchanged
    FG_YELLOW="" NC=""
    legacy_selectOpMode
    _status=$?
    printf '%s\n' "${op_mode}" > "${case_root}/mode"
    exit "${_status}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  [[ "${status}" == "${expected_status}" ]] ||
    fail "${scenario} operation-mode status changed"
  [[ "$(< "${case_root}/mode")" == "${expected_mode}" ]] ||
    fail "${scenario} operation-mode selection changed"
  printf '%s\n' $'prompt\t[o] Online\t[h] Hybrid\t[Esc] Cancel' \
    > "${case_root}/expected-prompt"
  assert_files_equal "${case_root}/prompt" "${case_root}/expected-prompt" \
    "${scenario} operation-mode options"
  [[ ! -s "${stderr_file}" ]] || fail "${scenario} operation-mode emitted stderr"
  grep -Fq 'Online mode  -  The default mode to use if all keys are available' \
    "${stdout_file}" || fail "${scenario} operation-mode guidance changed"
)

for scenario in online hybrid cancel; do run_op_mode_case "${scenario}"; done

# The historical matrix above remains frozen.  The cases below source only the
# extracted action and exercise its hardened transaction boundary directly.
write_hardened_ccli() {
  local target="${TEST_ROOT}/hardened-cardano-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_REGISTER_HARDENED_SCENARIO:?}"' \
    'log="${CNTOOLS_WALLET_REGISTER_HARDENED_CLI_LOG:?}"' \
    'base="${CNTOOLS_WALLET_REGISTER_HARDENED_BASE:?}"' \
    'hash="${CNTOOLS_WALLET_REGISTER_HARDENED_HASH:?}"' \
    'previous=""; out_file=""; tx_body_file=""; tx_in=""; argument=""' \
    'emit() { local target="$1" fd=""; shift; if [[ "${target}" == /dev/fd/[0-9]* ]]; then fd="${target##*/}"; printf "$@" 1>&"${fd}"; else printf "$@" > "${target}"; fi; }' \
    'printf '\''cardano-cli'\'' >> "${log}"' \
    'for argument in "$@"; do' \
    '  printf '\''\t%q'\'' "${argument}" >> "${log}"' \
    '  [[ "${previous}" == --out-file ]] && out_file="${argument}"' \
    '  [[ "${previous}" == --tx-body-file ]] && tx_body_file="${argument}"' \
    '  [[ "${previous}" == --tx-in ]] && tx_in="${argument}"' \
    '  previous="${argument}"' \
    'done' \
    'printf '\''\n'\'' >> "${log}"' \
    'case "$*" in' \
    '  *"query utxo"*)' \
    '    if [[ -n "${tx_in}" ]]; then' \
    '      case "${scenario}" in local-ambiguous-seen) emit "${out_file}" '\''{"%s#0":{}}\n'\'' "${hash}" ;; *) emit "${out_file}" '\''{}\n'\'' ;; esac' \
    '      exit 0' \
    '    fi' \
    '    [[ "${scenario}" != query-fail ]] || { printf '\''%s\n'\'' "${CNTOOLS_WALLET_REGISTER_HARDENED_RAW:?}" >&2; exit 31; }' \
    '    [[ "${scenario}" != malformed-query ]] || { emit "${out_file}" '\''[]\n'\''; exit 0; }' \
    '    [[ "${scenario}" != empty-query ]] || { emit "${out_file}" '\''{}\n'\''; exit 0; }' \
    '    emit "${out_file}" '\''{"%s#0":{"address":"%s","value":{"lovelace":10000000}}}\n'\'' "${hash}" "${base}"' \
    '    ;;' \
    '  *"query stake-address-info"*) emit "${out_file}" '\''[]\n'\'' ;;' \
    '  *"stake-address registration-certificate"*)' \
    '    if [[ "${scenario}" == cleanup-foreign ]]; then : > "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE:?}/foreign"; printf '\''%s\n'\'' "${CNTOOLS_WALLET_REGISTER_HARDENED_RAW:?}" >&2; exit 32; fi' \
    '    [[ "${scenario}" != certificate-fail ]] || { printf '\''%s\n'\'' "${CNTOOLS_WALLET_REGISTER_HARDENED_RAW:?}" >&2; exit 32; }' \
    '    [[ "${scenario}" != malformed-certificate ]] || { emit "${out_file}" '\''{}\n'\''; exit 0; }' \
    '    emit "${out_file}" '\''{"cborHex":"aabbccdd","description":"fixture","type":"StakeAddressRegistrationCertificate"}\n'\''' \
    '    case "${scenario}" in' \
    '      late-cert-symlink) rm -f -- "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE:?}/certificate.json"; ln -s -- "${CNTOOLS_WALLET_REGISTER_HARDENED_OUTSIDE:?}" "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE}/certificate.json" ;;' \
    '      late-cert-hardlink) rm -f -- "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE:?}/certificate.json"; ln -- "${CNTOOLS_WALLET_REGISTER_HARDENED_OUTSIDE:?}" "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE}/certificate.json" ;;' \
    '      late-cert-fifo) rm -f -- "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE:?}/certificate.json"; mkfifo "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE}/certificate.json"; chmod 0600 "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE}/certificate.json" ;;' \
    '      signal-precommit) kill -TERM "${PPID}" ;;' \
    '      late-ccli-replace) replacement="${0}.replacement.$$"; printf '\''%s\n'\'' '\''#!/usr/bin/env bash'\'' '\''exit 0'\'' > "${replacement}"; chmod 0755 "${replacement}"; mv -f -- "${replacement}" "$0" ;;' \
    '    esac' \
    '    ;;' \
    '  *"transaction build-raw"*) emit "${out_file}" '\''{"cborHex":"aabbccdd","description":"fixture","type":"TxBody ConwayEra"}\n'\'' ;;' \
    '  *"transaction calculate-min-fee"*) printf '\''200000 Lovelace\n'\'' ;;' \
    '  *"transaction calculate-min-required-utxo"*) printf '\''1000000 Lovelace\n'\'' ;;' \
    '  *"transaction witness"*) tx_body="$(< "${tx_body_file}")"; [[ "${tx_body}" == *'\''"type":"TxBody'\''* ]] || exit 97; emit "${out_file}" '\''{"cborHex":"aabb","description":"fixture","type":"TxWitness ConwayEra"}\n'\'' ;;' \
    '  *"transaction assemble"*) emit "${out_file}" '\''{"cborHex":"aabb","description":"fixture","type":"Signed Tx"}\n'\'' ;;' \
    '  *"transaction txid"*) printf '\''%s\n'\'' "${hash}" ;;' \
    '  *"transaction submit"*)' \
    '    printf '\''accepted:%s\n'\'' "${scenario}" >> "${CNTOOLS_WALLET_REGISTER_HARDENED_ACCEPTANCE_LOG:?}"' \
    '    case "${scenario}" in' \
    '      submit-fail|local-ambiguous-seen|local-ambiguous-unseen) exit 33 ;;' \
    '      signal-postcommit) kill -TERM "${PPID}" ;;' \
    '      postsubmit-tool-replace) replacement="${0}.replacement.$$"; printf '\''%s\n'\'' '\''#!/usr/bin/env bash'\'' '\''exit 0'\'' > "${replacement}"; chmod 0755 "${replacement}"; mv -f -- "${replacement}" "$0" ;;' \
    '      postsubmit-fd-rebind) chmod 0644 /dev/fd/1 ;;' \
    '      postsubmit-cleanup) : > "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE:?}/foreign" ;;' \
    '      postsubmit-final-link) ln -- "${CNTOOLS_WALLET_REGISTER_HARDENED_CERTIFICATE:?}" "${CNTOOLS_WALLET_REGISTER_HARDENED_POSTCOMMIT_LINK:?}" ;;' \
    '    esac' \
    '    exit 0' \
    '    ;;' \
    '  *) printf '\''unexpected hardened cardano-cli vector: %s\n'\'' "$*" >&2; exit 96 ;;' \
    'esac' \
    > "${target}"
  chmod 0755 "${target}"
  printf '%s\n' "${target}"
}

HARDENED_CCLI="$(write_hardened_ccli)"

write_hardened_curl() {
  local target="$1"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_REGISTER_HARDENED_SCENARIO:?}"' \
    'log="${CNTOOLS_WALLET_REGISTER_HARDENED_CURL_LOG:?}"' \
    'base="${CNTOOLS_WALLET_REGISTER_HARDENED_BASE:?}"' \
    'reward="${CNTOOLS_WALLET_REGISTER_HARDENED_REWARD:?}"' \
    'hash="${CNTOOLS_WALLET_REGISTER_HARDENED_HASH:?}"' \
    'secret="${CNTOOLS_WALLET_REGISTER_HARDENED_HEADER_SECRET:?}"' \
    'argv_secret="${CNTOOLS_WALLET_REGISTER_HARDENED_ARGV_SECRET:?}"' \
    'previous=""; out_file=""; url=""; header_file=""; data_file=""; argument=""' \
    'emit() { local target_path="$1" fd=""; shift; if [[ "${target_path}" == /dev/fd/[0-9]* ]]; then fd="${target_path##*/}"; printf "$@" 1>&"${fd}"; else printf "$@" > "${target_path}"; fi; }' \
    'printf '\''curl'\'' >> "${log}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${log}"; [[ "${previous}" == --output ]] && out_file="${argument}"; [[ "${previous}" == --url ]] && url="${argument}"; [[ "${previous}" == --header ]] && header_file="${argument}"; [[ "${previous}" == --data-binary ]] && data_file="${argument}"; previous="${argument}"; done' \
    'printf '\''\n'\'' >> "${log}"' \
    '[[ "$*" != *"${secret}"* && "$*" != *"${argv_secret}"* ]] || exit 101' \
    '[[ "${header_file}" == @/dev/fd/[0-9]* ]] || exit 97' \
    'header_value="$(< "${header_file#@}")"' \
    '[[ "${header_value}" == *"authorization: Bearer ${secret}"* && "${header_value}" == *"content-type: application/json"* ]] || exit 98' \
    'printf '\''%s:%s\n'\'' "${secret}" "${argv_secret}" >&2' \
    'case "${url}" in' \
    '  */address_utxos?*) if [[ "${scenario}" == light-reflect-utxo-cleanup ]]; then emit "${out_file}" '\''[{"address":"%s","tx_hash":"%s","tx_index":0,"value":10000000,"asset_list":[],"reflection":"%s"}]\n'\'' "${base}" "${hash}" "${secret}"; else emit "${out_file}" '\''[{"address":"%s","tx_hash":"%s","tx_index":0,"value":10000000,"asset_list":[]}]\n'\'' "${base}" "${hash}"; fi; if [[ "${scenario}" == late-curl-replace ]]; then replacement="${0}.replacement.$$"; printf '\''%s\n'\'' '\''#!/usr/bin/env bash'\'' '\''exit 0'\'' > "${replacement}"; chmod 0755 "${replacement}"; mv -f -- "${replacement}" "$0"; fi ;;' \
    '  */account_info?*) case "${scenario}" in light-reflect-utxo-cleanup) emit "${out_file}" '\''[{"stake_address":"%s","status":"registered","delegated_pool":null,"delegated_drep":null,"rewards_available":0,"deposit":0}]\n'\'' "${reward}"; : > "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE:?}/foreign" ;; light-reflect-stake-cleanup) emit "${out_file}" '\''[{"stake_address":"%s","status":"registered","delegated_pool":null,"delegated_drep":null,"rewards_available":0,"deposit":0,"reflection":"%s"}]\n'\'' "${reward}" "${secret}"; : > "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE:?}/foreign" ;; *) emit "${out_file}" '\''[{"stake_address":"%s","status":"not registered","delegated_pool":null,"delegated_drep":null,"rewards_available":0,"deposit":0}]\n'\'' "${reward}" ;; esac ;;' \
    '  */ogmios/)' \
    '    printf '\''accepted:%s\n'\'' "${scenario}" >> "${CNTOOLS_WALLET_REGISTER_HARDENED_ACCEPTANCE_LOG:?}"' \
    '    case "${scenario}" in light-postsubmit-cleanup|light-reflect-submit-cleanup) : > "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE:?}/foreign" ;; esac' \
    '    [[ "${data_file}" == @/dev/fd/[0-9]* ]] || exit 99' \
    '    request="$(< "${data_file#@}")"' \
    '    [[ "${request}" == *'\''"method": "submitTransaction"'\''* && "${request}" == *'\''"cbor": "aabb"'\''* ]] || exit 100' \
    '    case "${scenario}" in' \
    '      light-rejected) emit "${out_file}" '\''{"jsonrpc":"2.0","error":{"code":-32000,"message":"rejected"}}\n'\'' ;;' \
    '      light-ambiguous-seen|light-ambiguous-unseen) exit 28 ;;' \
    '      light-accepted-nonzero) emit "${out_file}" '\''{"jsonrpc":"2.0","result":{"transaction":{"id":"%s"}}}\n'\'' "${hash}"; exit 28 ;;' \
    '      light-reflect-submit-cleanup) emit "${out_file}" '\''{"jsonrpc":"2.0","result":{"transaction":{"id":"%s"}},"reflection":"%s"}\n'\'' "${hash}" "${secret}" ;;' \
    '      light-reflect-verify-cleanup) exit 28 ;;' \
    '      *) emit "${out_file}" '\''{"jsonrpc":"2.0","result":{"transaction":{"id":"%s"}}}\n'\'' "${hash}" ;;' \
    '    esac' \
    '    ;;' \
    '  */tx_status?*)' \
    '    case "${scenario}" in light-ambiguous-unseen) emit "${out_file}" '\''[]\n'\'' ;; light-reflect-verify-cleanup) emit "${out_file}" '\''[{"tx_hash":"%s","num_confirmations":0,"reflection":"%s"}]\n'\'' "${hash}" "${secret}"; : > "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE:?}/foreign" ;; *) emit "${out_file}" '\''[{"tx_hash":"%s","num_confirmations":0}]\n'\'' "${hash}" ;; esac' \
    '    ;;' \
    '  *) printf '\''unexpected hardened curl URL: %s\n'\'' "${url}" >&2; exit 96 ;;' \
    'esac' \
    > "${target}"
  chmod 0755 "${target}"
}

HARDENED_BIN="${TEST_ROOT}/hardened-bin"
mkdir -p "${HARDENED_BIN}"
write_hardened_curl "${HARDENED_BIN}/curl"

write_hardened_jq() {
  local target="$1"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'real_jq="${CNTOOLS_WALLET_REGISTER_HARDENED_REAL_JQ:?}"' \
    'scenario="${CNTOOLS_WALLET_REGISTER_HARDENED_SCENARIO:?}"' \
    'trigger=N; for argument in "$@"; do [[ "${argument}" != -cn ]] || trigger=Y; done' \
    '"${real_jq}" "$@"' \
    'status=$?' \
    'if [[ "${scenario}" == late-jq-replace && "${trigger}" == Y ]]; then replacement="${0}.replacement.$$"; printf '\''%s\n'\'' '\''#!/usr/bin/env bash'\'' '\''exit 0'\'' > "${replacement}"; chmod 0755 "${replacement}"; mv -f -- "${replacement}" "$0"; fi' \
    'exit "${status}"' \
    > "${target}"
  chmod 0755 "${target}"
}

write_hardened_jq "${HARDENED_BIN}/jq"

write_hardened_date() {
  local target="$1"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'real_date="${CNTOOLS_WALLET_REGISTER_HARDENED_REAL_DATE:?}"' \
    'now="${CNTOOLS_WALLET_REGISTER_HARDENED_NOW:?}"' \
    'if [[ "$*" == "+%s" ]]; then printf '\''%s\n'\'' "${now}"; exit 0; fi' \
    'if [[ "${1:-}" == +%s && "${2:-}" == --date=* ]]; then' \
    '  value="${2#--date=}"' \
    '  exec "${real_date}" -j -u -f '\''%Y-%m-%dT%H:%M:%SZ'\'' "${value}" '\''+%s'\''' \
    'fi' \
    'exec "${real_date}" "$@"' \
    > "${target}"
  chmod 0755 "${target}"
}

write_hardened_date "${HARDENED_BIN}/date"

write_hardened_hwcli() {
  local target="$1"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'log="${CNTOOLS_WALLET_REGISTER_HARDENED_HWCLI_LOG:?}"' \
    'previous=""; argument=""; out_files=()' \
    'emit() { local target_path="$1" target_fd=""; shift; if [[ "${target_path}" == /dev/fd/[0-9]* ]]; then target_fd="${target_path##*/}"; printf "$@" 1>&"${target_fd}"; else printf "$@" > "${target_path}"; fi; }' \
    'printf '\''cardano-hw-cli'\'' >> "${log}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${log}"; [[ "${previous}" == --out-file ]] && out_files+=("${argument}"); previous="${argument}"; done' \
    'printf '\''\n'\'' >> "${log}"' \
    'case "$*" in' \
    '  "transaction transform "*) [[ "${#out_files[@]}" == 1 ]] || exit 96; emit "${out_files[0]}" '\''{"cborHex":"aabbccdd","description":"fixture","type":"TxBody ConwayEra"}\n'\'' ;;' \
    '  "transaction witness "*) [[ "${#out_files[@]}" == 2 ]] || exit 96; for argument in "${out_files[@]}"; do emit "${argument}" '\''{"cborHex":"aabb","description":"fixture","type":"TxWitness ConwayEra"}\n'\''; done ;;' \
    '  *) printf '\''unexpected hardened cardano-hw-cli vector: %s\n'\'' "$*" >&2; exit 96 ;;' \
    'esac' \
    > "${target}"
  chmod 0755 "${target}"
}

write_hardened_hwcli "${HARDENED_BIN}/cardano-hw-cli"

assert_real_offline_signer_temporal_oracle() {
  local package="$1" date_path="$2" cli_log="$3"
  local created="" expires="" identifier="" ttl_value=""
  local created_epoch="" expiry_epoch="" check_epoch=1700001800

  created="$("${REAL_JQ_PATH}" -er '."date-created"' "${package}")" ||
    fail 'offline temporal oracle could not read creation time'
  expires="$("${REAL_JQ_PATH}" -er '."date-expire"' "${package}")" ||
    fail 'offline temporal oracle could not read expiry time'
  identifier="$("${REAL_JQ_PATH}" -er '.id' "${package}")" ||
    fail 'offline temporal oracle could not read identifier'
  ttl_value="$("${REAL_JQ_PATH}" -er '.ttl | tostring' "${package}")" ||
    fail 'offline temporal oracle could not read transaction TTL'
  created_epoch="$(CNTOOLS_WALLET_REGISTER_HARDENED_NOW="${check_epoch}" \
    "${date_path}" '+%s' --date="${created}")" ||
    fail 'real offline signer could not parse creation time'
  expiry_epoch="$(CNTOOLS_WALLET_REGISTER_HARDENED_NOW="${check_epoch}" \
    "${date_path}" '+%s' --date="${expires}")" ||
    fail 'real offline signer could not parse expiry time'
  [[ "${identifier}" == 1700000000 && "${created_epoch}" == 1700000000 &&
     "${expiry_epoch}" == 1700003600 &&
     "$((10#${created_epoch} + 3600))" == "${expiry_epoch}" &&
     "${created_epoch}" -lt "${check_epoch}" &&
     "${check_epoch}" -lt "${expiry_epoch}" ]] ||
    fail 'offline package lost its exact future-expiry arithmetic'
  [[ "${ttl_value}" == 1003600 ]] ||
    fail 'offline package TTL lost exact JSON integer representation'
  grep -Fq -- $'--invalid-hereafter\t1003600' "${cli_log}" ||
    fail 'offline package expiry diverged from transaction validity'
  grep -Fq -- $'--testnet-magic\t42' "${cli_log}" ||
    fail 'offline package validity lost its authenticated network vector'
  grep -Fq '[[ $(date '\''+%s'\'' --date="${otx_date_expire}") -lt $(date '\''+%s'\'') ]]' \
    "${CNTOOLS_SCRIPT}" || fail 'real offline signer expiry predicate changed'
  if CNTOOLS_WALLET_REGISTER_HARDENED_NOW="${check_epoch}" \
      "${date_path}" '+%s' --date="${expires}" | {
        IFS= read -r _expiry
        [[ "${_expiry}" -lt "${check_epoch}" ]]
      }; then
    fail 'real offline signer rejected the fresh hybrid package as expired'
  fi
}

run_hardened_action_case() (
  local scenario="$1" expected_status="$2" case_root="" runtime_root=""
  local run_label="${3:-}" fd_before="" fd_after=""
  local wallet_root="" wallet_dir="" tmp_root="" private_root="" case_bin=""
  local context_file="" result_file="" stdout_file="" stderr_file=""
  local cli_log="" curl_log="" hwcli_log="" event_log="" acceptance_log=""
  local cntools_log="" case_ccli="" case_curl="" status=0
  local lock_path="" argument=""
  local action_mode=local selected_mode=online expected_wait=0
  local expect_commit=N expect_cleanup=Y expect_offline=N
  local outside="" outside_hash="" outside_mode="" outside_links=""
  local postcommit_link=""
  local offline_file=""

  if [[ -n "${CNTOOLS_WALLET_REGISTER_HARDENED_FILTER:-}" &&
        ",${CNTOOLS_WALLET_REGISTER_HARDENED_FILTER}," != \
          *",${scenario},"* ]]; then
    return 0
  fi

  case "${scenario}" in
    success|hardware-success) expect_commit=Y ;;
    hybrid-success) selected_mode=hybrid; expect_commit=Y; expect_offline=Y ;;
    multisig-success) expect_commit=Y; expect_offline=Y ;;
    light-success|light-exported-headers-success)
      action_mode=light; expect_commit=Y
      ;;
    light-accepted-nonzero|light-ambiguous-seen|light-ambiguous-unseen)
      action_mode=light; expect_commit=Y ;;
    light-rejected) action_mode=light ;;
    local-ambiguous-seen|local-ambiguous-unseen|submit-fail|signal-postcommit|\
      postsubmit-tool-replace|postsubmit-fd-rebind|postsubmit-final-link)
      expect_commit=Y ;;
    postsubmit-cleanup) expect_commit=Y; expect_cleanup=N ;;
    light-postsubmit-cleanup)
      action_mode=light; expect_commit=Y; expect_cleanup=N
      ;;
    light-reflect-submit-cleanup|light-reflect-verify-cleanup)
      action_mode=light; expect_commit=Y; expect_cleanup=N
      ;;
    light-reflect-utxo-cleanup|light-reflect-stake-cleanup)
      action_mode=light; expect_cleanup=N
      ;;
    late-curl-replace|late-jq-replace|light-preinvoke-tool-drift|\
      light-preinvoke-fd-drift|\
      light-callback-marker-forgery-preinvoke-drift|\
      light-state-token-global-exfil|light-present-token-global-exfil|\
      light-present-credential-exfil|light-readonly-headers|\
      light-readonly-exported-headers)
      action_mode=light
      ;;
    cleanup-foreign) expect_cleanup=N ;;
    context-mismatch) ;;
    certificate-fail|query-fail|empty-query|malformed-query|malformed-certificate|\
      cert-symlink|cert-hardlink|cert-fifo|late-cert-symlink|late-cert-hardlink|\
      late-cert-fifo|signal-precommit|late-ccli-replace|signing-key-mode|\
      ttl-jq-overflow|initial-ccli-hardlink|preinvoke-tool-drift|\
      preinvoke-fd-drift|local-callback-marker-forgery-preinvoke-drift|\
      online-callback-tool-corruption|hybrid-callback-tool-corruption|\
      hardware-callback-tool-corruption|online-state-input-fd-exfil|\
      online-present-signing-fd-exfil|hardware-state-secret-exfil|\
      hardware-present-signing-fd-exfil|hybrid-state-secret-exfil|\
      state-result-forgery|present-result-forgery|\
      state-context-mutation-exfil|present-private-parent-mutation-exfil)
      ;;
    duration-zero|duration-noncanonical|duration-overflow|duration-boundary)
      selected_mode=hybrid
      ;;
    *) fail "unknown hardened scenario: ${scenario}" ;;
  esac
  if [[ "${expected_status}" == 0 || "${expected_status}" == 21 ]]; then
    expected_wait=1
  fi

  case_root="${TEST_ROOT}/hardened/${scenario}${run_label:+-${run_label}}"
  runtime_root="${case_root}/runtime"
  wallet_root="${runtime_root}/wallet"
  wallet_dir="${wallet_root}/fixture_wallet"
  tmp_root="${runtime_root}/tmp"
  private_root="${runtime_root}/private"
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  stdout_file="${case_root}/stdout"
  stderr_file="${case_root}/stderr"
  cli_log="${case_root}/cli.log"
  curl_log="${case_root}/curl.log"
  hwcli_log="${case_root}/hwcli.log"
  event_log="${case_root}/events"
  acceptance_log="${case_root}/acceptance.log"
  cntools_log="${case_root}/cntools.log"
  outside="${runtime_root}/outside-cert"
  postcommit_link="${runtime_root}/postcommit-link"
  case_bin="${case_root}/bin"
  case_ccli="${case_root}/cardano-cli"
  case_curl="${case_bin}/curl"
  mkdir -p "${wallet_dir}" "${tmp_root}" "${private_root}" "${case_bin}"
  cp "${HARDENED_CCLI}" "${case_ccli}"
  cp "${HARDENED_BIN}/curl" "${HARDENED_BIN}/jq" \
    "${HARDENED_BIN}/date" "${HARDENED_BIN}/cardano-hw-cli" "${case_bin}/"
  chmod 0755 "${case_ccli}" "${case_bin}/"*
  [[ "${scenario}" != initial-ccli-hardlink ]] ||
    ln -- "${case_ccli}" "${case_root}/cardano-cli-hardlink"
  chmod 0700 "${wallet_root}" "${wallet_dir}" "${tmp_root}" "${private_root}"
  : > "${cli_log}"
  : > "${curl_log}"
  : > "${hwcli_log}"
  : > "${event_log}"
  : > "${acceptance_log}"
  : > "${cntools_log}"
  printf '%s\n' outside-original > "${outside}"
  chmod 0640 "${outside}"
  printf '%s\n' "${BASE_ADDR}" > "${wallet_dir}/base.addr"
  printf '%s\n' "${PAY_ADDR}" > "${wallet_dir}/payment.addr"
  printf '%s\n' "${REWARD_ADDR}" > "${wallet_dir}/stake.addr"
  printf '%s\n' '{"type":"PaymentVerificationKeyShelley_ed25519","description":"fixture","cborHex":"aabb"}' > "${wallet_dir}/payment.vkey"
  printf '%s\n' '{"type":"StakeVerificationKeyShelley_ed25519","description":"fixture","cborHex":"aabb"}' > "${wallet_dir}/stake.vkey"
  printf '%s\n' "{\"type\":\"PaymentSigningKeyShelley_ed25519\",\"description\":\"fixture\",\"cborHex\":\"${SIGNING_SECRET}\"}" > "${wallet_dir}/payment.skey"
  printf '%s\n' "{\"type\":\"StakeSigningKeyShelley_ed25519\",\"description\":\"fixture\",\"cborHex\":\"${SIGNING_SECRET}\"}" > "${wallet_dir}/stake.skey"
  printf '%s\n' "{\"type\":\"PaymentHWSigningFileShelley_ed25519\",\"description\":\"Hardware fixture\",\"cborHex\":\"${SIGNING_SECRET}\"}" > "${wallet_dir}/payment.hw.skey"
  printf '%s\n' "{\"type\":\"StakeHWSigningFileShelley_ed25519\",\"description\":\"Hardware fixture\",\"cborHex\":\"${SIGNING_SECRET}\"}" > "${wallet_dir}/stake.hw.skey"
  printf '%s\n' '{"type":"all","scripts":[{"type":"sig","keyHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}' > "${wallet_dir}/payment.script"
  printf '%s\n' '{"type":"all","scripts":[{"type":"sig","keyHash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}' > "${wallet_dir}/stake.script"
  printf '%s\n' '{}' > "${tmp_root}/protparams.json"
  chmod 0600 "${wallet_dir}"/* "${tmp_root}/protparams.json"
  [[ "${scenario}" != signing-key-mode ]] ||
    chmod 0644 "${wallet_dir}/payment.skey"
  case "${scenario}" in
    cert-symlink) ln -s -- "${outside}" "${wallet_dir}/stake.cert" ;;
    cert-hardlink) ln -- "${outside}" "${wallet_dir}/stake.cert" ;;
    cert-fifo) mkfifo "${wallet_dir}/stake.cert"; chmod 0640 "${wallet_dir}/stake.cert" ;;
  esac
  outside_hash="$(file_hash "${outside}")"
  outside_mode="$(file_mode "${outside}")"
  outside_links="$(file_links "${outside}")"
  "${REAL_JQ_PATH}" -nS --arg mode "${action_mode}" '
    {advanced:false,apiVersion:1,
    capabilities:(if $mode == "local" then ["local-cli"] else [] end),features:[],
    generationVersion:"1.0.0",mode:$mode,nodeHome:"/node",
    nodeImplementation:"cnode",nodeNetwork:"preview",schemaVersion:1
  }' > "${context_file}"
  chmod 0600 "${context_file}"

  PATH="${case_bin}:${BASE_PATH}"; export PATH
  CNTOOLS_LOG="${cntools_log}"
  CNTOOLS_MODE="${action_mode^^}"
  [[ "${scenario}" != context-mismatch ]] || CNTOOLS_MODE=LIGHT
  NETWORK_IDENTIFIER='--testnet-magic 42'
  WALLET_FOLDER="${wallet_root}"
  TMP_DIR="${tmp_root}"
  CCLI="${case_ccli}"
  HWCLI="${case_bin}/cardano-hw-cli"
  KEY_DEPOSIT=2000000
  DUMMYFEE=0
  TX_TTL=3600
  WALLET_SELECTION_FILTER_LIMIT=100
  PROT_VERSION=9.0
  if [[ "${action_mode}" == light ]]; then
    KOIOS_API='https://koios.invalid/api/v1'
    KOIOS_API_HEADERS=(-H "authorization: Bearer ${KOIOS_HEADER_SECRET}")
  else
    KOIOS_API=
    KOIOS_API_HEADERS=()
  fi
  case "${scenario}" in
    light-exported-headers-success)
      export KOIOS_API_HEADERS
      ;;
    light-readonly-headers)
      readonly -a KOIOS_API_HEADERS
      ;;
    light-readonly-exported-headers)
      export KOIOS_API_HEADERS
      readonly -a KOIOS_API_HEADERS
      ;;
  esac
  WALLET_PAY_VK_FILENAME=payment.vkey
  WALLET_PAY_SK_FILENAME=payment.skey
  WALLET_STAKE_VK_FILENAME=stake.vkey
  WALLET_STAKE_SK_FILENAME=stake.skey
  WALLET_HW_PAY_SK_FILENAME=payment.hw.skey
  WALLET_HW_STAKE_SK_FILENAME=stake.hw.skey
  WALLET_PAY_SCRIPT_FILENAME=payment.script
  WALLET_STAKE_SCRIPT_FILENAME=stake.script
  WALLET_BASE_ADDR_FILENAME=base.addr
  WALLET_PAY_ADDR_FILENAME=payment.addr
  WALLET_STAKE_ADDR_FILENAME=stake.addr
  WALLET_STAKE_CERT_FILENAME=stake.cert
  CNTOOLS_WALLET_REGISTER_HARDENED_SCENARIO="${scenario}"
  CNTOOLS_WALLET_REGISTER_HARDENED_CLI_LOG="${cli_log}"
  CNTOOLS_WALLET_REGISTER_HARDENED_CURL_LOG="${curl_log}"
  CNTOOLS_WALLET_REGISTER_HARDENED_HWCLI_LOG="${hwcli_log}"
  CNTOOLS_WALLET_REGISTER_HARDENED_BASE="${BASE_ADDR}"
  CNTOOLS_WALLET_REGISTER_HARDENED_REWARD="${REWARD_ADDR}"
  CNTOOLS_WALLET_REGISTER_HARDENED_HASH="${TX_HASH}"
  CNTOOLS_WALLET_REGISTER_HARDENED_RAW="${RAW_DIAGNOSTIC}"
  CNTOOLS_WALLET_REGISTER_HARDENED_HEADER_SECRET="${KOIOS_HEADER_SECRET}"
  CNTOOLS_WALLET_REGISTER_HARDENED_ARGV_SECRET="${LIGHT_ARGV_SECRET}"
  CNTOOLS_WALLET_REGISTER_HARDENED_REAL_JQ="${REAL_JQ_PATH}"
  CNTOOLS_WALLET_REGISTER_HARDENED_REAL_DATE="${CNTOOLS_WALLET_REGISTER_REAL_DATE}"
  CNTOOLS_WALLET_REGISTER_HARDENED_NOW=1700000000
  [[ "${scenario}" != duration-boundary ]] || \
    CNTOOLS_WALLET_REGISTER_HARDENED_NOW=253402300000
  CNTOOLS_WALLET_REGISTER_HARDENED_STAGE="${wallet_root}/.fixture_wallet.cntools-wallet-register.lock/stage"
  CNTOOLS_WALLET_REGISTER_HARDENED_OUTSIDE="${outside}"
  CNTOOLS_WALLET_REGISTER_HARDENED_CERTIFICATE="${wallet_dir}/stake.cert"
  CNTOOLS_WALLET_REGISTER_HARDENED_POSTCOMMIT_LINK="${postcommit_link}"
  CNTOOLS_WALLET_REGISTER_HARDENED_ACCEPTANCE_LOG="${acceptance_log}"
  CNTOOLS_WALLET_REGISTER_HARDENED_RESULT="${result_file}"
  CNTOOLS_WALLET_REGISTER_HARDENED_CONTEXT="${context_file}"
  CNTOOLS_WALLET_REGISTER_HARDENED_PRIVATE_PARENT="${private_root}"
  export CNTOOLS_WALLET_REGISTER_HARDENED_SCENARIO
  export CNTOOLS_WALLET_REGISTER_HARDENED_CLI_LOG
  export CNTOOLS_WALLET_REGISTER_HARDENED_CURL_LOG
  export CNTOOLS_WALLET_REGISTER_HARDENED_HWCLI_LOG
  export CNTOOLS_WALLET_REGISTER_HARDENED_BASE
  export CNTOOLS_WALLET_REGISTER_HARDENED_REWARD
  export CNTOOLS_WALLET_REGISTER_HARDENED_HASH
  export CNTOOLS_WALLET_REGISTER_HARDENED_RAW
  export CNTOOLS_WALLET_REGISTER_HARDENED_HEADER_SECRET
  export CNTOOLS_WALLET_REGISTER_HARDENED_ARGV_SECRET
  export CNTOOLS_WALLET_REGISTER_HARDENED_REAL_JQ
  export CNTOOLS_WALLET_REGISTER_HARDENED_REAL_DATE
  export CNTOOLS_WALLET_REGISTER_HARDENED_NOW
  export CNTOOLS_WALLET_REGISTER_HARDENED_STAGE
  export CNTOOLS_WALLET_REGISTER_HARDENED_OUTSIDE
  export CNTOOLS_WALLET_REGISTER_HARDENED_CERTIFICATE
  export CNTOOLS_WALLET_REGISTER_HARDENED_POSTCOMMIT_LINK
  export CNTOOLS_WALLET_REGISTER_HARDENED_ACCEPTANCE_LOG
  export CNTOOLS_WALLET_REGISTER_HARDENED_RESULT
  export CNTOOLS_WALLET_REGISTER_HARDENED_CONTEXT
  export CNTOOLS_WALLET_REGISTER_HARDENED_PRIVATE_PARENT

  callback_private_probe() {
    local callback_probe_arg=""

    printf 'callback-private:result=%s:context=%s:parent=%s:action=%s:module=%s:payload=%s\n' \
      "${result_file-}" "${context_file-}" "${private_parent-}" \
      "${action_directory-}" "${module_file-}" "${payload_file-}" >> "${event_log}"
    for callback_probe_arg in "${BASH_ARGV[@]}"; do
      case "${callback_probe_arg}" in
        "${CNTOOLS_WALLET_REGISTER_HARDENED_RESULT}"|\
          "${CNTOOLS_WALLET_REGISTER_HARDENED_CONTEXT}"|\
          "${CNTOOLS_WALLET_REGISTER_HARDENED_PRIVATE_PARENT}")
          printf 'callback-private-bash-argv:%s\n' \
            "${callback_probe_arg}" >> "${event_log}"
          ;;
      esac
    done
  }
  write_canonical_forged_result() {
    printf '%s\n' '{' '  "data": {' \
      '    "forged": "FORGED-DISPATCH-PAYLOAD"' '  },' \
      '  "schemaVersion": 1' '}' > \
      "${CNTOOLS_WALLET_REGISTER_HARDENED_RESULT}"
  }
  clear() {
    if [[ "${scenario}" == present-result-forgery ]]; then
      callback_private_probe
      write_canonical_forged_result
    fi
  }
  callback_secret_probe() {
    local callback_probe_name="" callback_probe_fd="" callback_probe_line=""
    local callback_probe_path=""

    printf 'callback-header:%s\n' "${KOIOS_API_HEADERS[1]-}" >> "${event_log}"
    printf 'callback-action-header:%s\n' \
      "${wallet_register_koios_headers[1]-}" >> "${event_log}"
    for callback_probe_name in wallet_register_headers_fd \
        wallet_register_curl_headers_fd wallet_register_response_writer_fd \
        wallet_register_response_reader_fd wallet_register_response_hash_fd \
        wallet_register_payment_fd wallet_register_stake_fd \
        wallet_register_hardware_fd wallet_register_tool_output_fd \
        wallet_register_tool_log_fd headers_fd output_fd payment_fd stake_fd \
        body_fd raw_fd log_fd; do
      callback_probe_fd="${!callback_probe_name-}"
      [[ "${callback_probe_fd}" =~ ^([3-9]|[1-9][0-9]+)$ ]] || continue
      if IFS= builtin read -r callback_probe_line <&"${callback_probe_fd}"; then
        printf 'callback-read:%s:%s\n' "${callback_probe_name}" \
          "${callback_probe_line}" >> "${event_log}"
      fi
    done
    for callback_probe_path in /dev/fd/[3-9] /dev/fd/[1-9][0-9]*; do
      [[ -e "${callback_probe_path}" ]] || continue
      printf 'callback-visible-fd:%s\n' "${callback_probe_path##*/}" >> "${event_log}"
    done
  }
  println() {
    if [[ "${scenario}" == present-private-parent-mutation-exfil &&
          "$*" == *'~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'* ]]; then
      callback_private_probe
      chmod 0755 "${CNTOOLS_WALLET_REGISTER_HARDENED_PRIVATE_PARENT}"
    fi
    case "${scenario}:$*" in
      light-present-token-global-exfil:*'~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'*)
        callback_secret_probe
        wallet_register_committed=Y
        ;;
      light-present-credential-exfil:*'curl [configured headers redacted] CNTools wallet-register query'*)
        callback_secret_probe
        wallet_register_committed=Y
        ;;
      online-present-signing-fd-exfil:*'cardano-cli wallet-register payment witness'*)
        callback_secret_probe
        wallet_register_committed=Y
        ;;
      hardware-present-signing-fd-exfil:*'cardano-hw-cli wallet-register transaction witness'*)
        callback_secret_probe
        wallet_register_committed=Y
        ;;
    esac
    if [[ "$*" == *'cardano-cli wallet-register transaction submission'* ]]; then
      case "${scenario}" in
        preinvoke-tool-drift)
          _replacement="${case_ccli}.preinvoke.$$"
          printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${_replacement}"
          chmod 0755 "${_replacement}"
          mv -f -- "${_replacement}" "${case_ccli}"
          ;;
        preinvoke-fd-drift)
          chmod 0644 \
            "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE:?}/submit.out"
          ;;
        local-callback-marker-forgery-preinvoke-drift)
          wallet_register_committed=Y
          wallet_register_submit_started=Y
          wallet_register_submit_rejected=Y
          wallet_register_submit_ambiguous=Y
          wallet_register_submission_ambiguous=Y
          wallet_register_postcommit_warning=Y
          wallet_register_acceptance_reconciled=Y
          wallet_register_reconciliation_attempted=Y
          _replacement="${case_ccli}.preinvoke.$$"
          printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${_replacement}"
          chmod 0755 "${_replacement}"
          mv -f -- "${_replacement}" "${case_ccli}"
          ;;
      esac
    fi
    if [[ "$*" == *'curl [configured headers and transaction body redacted] CNTools wallet-register submission'* ]]; then
      case "${scenario}" in
        light-preinvoke-tool-drift)
          _replacement="${case_curl}.preinvoke.$$"
          printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${_replacement}"
          chmod 0755 "${_replacement}"
          mv -f -- "${_replacement}" "${case_curl}"
          ;;
        light-preinvoke-fd-drift)
          chmod 0644 \
            "${CNTOOLS_WALLET_REGISTER_HARDENED_STAGE:?}/submit.request"
          ;;
        light-callback-marker-forgery-preinvoke-drift)
          wallet_register_committed=Y
          wallet_register_submit_started=Y
          wallet_register_submit_rejected=Y
          wallet_register_submit_ambiguous=Y
          wallet_register_submission_ambiguous=Y
          wallet_register_postcommit_warning=Y
          wallet_register_acceptance_reconciled=Y
          wallet_register_reconciliation_attempted=Y
          _replacement="${case_curl}.preinvoke.$$"
          printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${_replacement}"
          chmod 0755 "${_replacement}"
          mv -f -- "${_replacement}" "${case_curl}"
          ;;
      esac
    fi
    printf 'println:%s\n' "$*" >> "${event_log}"
  }
  waitToProceed() { printf 'wait\n' >> "${event_log}"; }
  selectOpMode() {
    op_mode="${selected_mode}"
    case "${scenario}" in
      state-result-forgery)
        callback_private_probe
        write_canonical_forged_result
        ;;
      state-context-mutation-exfil)
        callback_private_probe
        printf ' ' >> "${CNTOOLS_WALLET_REGISTER_HARDENED_CONTEXT}"
        ;;
    esac
    if [[ "${scenario}" == light-state-token-global-exfil ]]; then
      callback_secret_probe
      wallet_register_committed=Y
    fi
    return 0
  }
  selectWallet() {
    if [[ "${action_mode}" == light ]]; then
      printf 'inherited-selectWallet:%s\n' "${INHERITED_LIGHT_SECRET}" >> "${event_log}"
      return 70
    fi
    [[ "${1:-}" == non-reg ]] || return 70
    wallet_name=fixture_wallet
  }
  select_opt() {
    printf 'owned-light-inventory:%s\n' "$*" >> "${event_log}"
    selected_value="${1:-}"
    return 0
  }
  getWalletType() {
    payment_vk_file="${wallet_dir}/payment.vkey"
    stake_vk_file="${wallet_dir}/stake.vkey"
    if [[ "${scenario}" == hardware-success ||
          "${scenario}" == hardware-callback-tool-corruption ||
          "${scenario}" == hardware-state-secret-exfil ||
          "${scenario}" == hardware-present-signing-fd-exfil ]]; then
      payment_sk_file="${wallet_dir}/payment.hw.skey"
      stake_sk_file="${wallet_dir}/stake.hw.skey"
    else
      payment_sk_file="${wallet_dir}/payment.skey"
      stake_sk_file="${wallet_dir}/stake.skey"
    fi
    payment_script_file="${wallet_dir}/payment.script"
    stake_script_file="${wallet_dir}/stake.script"
    [[ "${scenario}" == hardware-success ||
       "${scenario}" == hardware-callback-tool-corruption ||
       "${scenario}" == hardware-state-secret-exfil ||
       "${scenario}" == hardware-present-signing-fd-exfil ]] && return 0
    [[ "${scenario}" == multisig-success ||
       "${scenario}" == hybrid-callback-tool-corruption ||
       "${scenario}" == hybrid-state-secret-exfil ]] && return 5
    return 1
  }
  validateMultiSigScript() {
    [[ "${1:-}" == false && -n "${2:-}" ]] || return 1
    required_total=1
    if [[ "${scenario}" == hybrid-callback-tool-corruption ]]; then
      wallet_register_ccli_path="${case_bin}/cardano-hw-cli"
      wallet_register_tool_paths[ccli]="${case_bin}/cardano-hw-cli"
      wallet_register_tool_metadata[ccli]='0:755:1:1:1:1'
      wallet_register_tool_digests[ccli]="${TX_HASH}"
      wallet_register_tool_output_fd=999
      _cntools_action_wallet_register_runtime_tools_same() { return 0; }
    fi
    if [[ "${scenario}" == hybrid-state-secret-exfil ]]; then
      callback_secret_probe
      wallet_register_committed=Y
    fi
    return 0
  }
  unlockHWDevice() {
    printf 'unlock:%s\n' "${1:-}" >> "${event_log}"
    if [[ "${scenario}" == hardware-callback-tool-corruption ]]; then
      wallet_register_hwcli_path="${case_ccli}"
      wallet_register_tool_paths[hwcli]="${case_ccli}"
      wallet_register_tool_metadata[hwcli]='0:755:1:1:1:1'
      wallet_register_tool_digests[hwcli]="${TX_HASH}"
      wallet_register_hardware_fd=999
      _cntools_action_wallet_register_run_hardware_witness() { return 0; }
    fi
    if [[ "${scenario}" == hardware-state-secret-exfil ]]; then
      callback_secret_probe
      wallet_register_committed=Y
    fi
    return 0
  }
  getTTL() {
    ttl=1003600
    case "${scenario}" in
      duration-zero) ttl_enter=0 ;;
      duration-noncanonical) ttl_enter=03600 ;;
      duration-overflow) ttl_enter=2147483648 ;;
      duration-boundary) ttl_enter=1000 ;;
      ttl-jq-overflow) ttl=9007199254740992; ttl_enter="${TX_TTL}" ;;
      *) ttl_enter="${TX_TTL}" ;;
    esac
    if [[ "${scenario}" == online-callback-tool-corruption ]]; then
      callback_secret_probe
      wallet_register_ccli_path="${case_bin}/cardano-hw-cli"
      wallet_register_network_args[0]=--mainnet
      wallet_register_tool_paths[ccli]="${case_bin}/cardano-hw-cli"
      wallet_register_tool_metadata[ccli]='0:755:1:1:1:1'
      wallet_register_tool_digests[ccli]="${TX_HASH}"
      wallet_register_stake_fd=999
      _cntools_action_wallet_register_run_output() { return 0; }
    fi
    return 0
  }
  versionCheck() {
    if [[ "${scenario}" == online-state-input-fd-exfil ]]; then
      callback_secret_probe
      wallet_register_committed=Y
    fi
    return 0
  }
  submitTx() {
    printf 'inherited-submitTx:%s\n' "${INHERITED_LIGHT_SECRET}" >> "${event_log}"
    return 70
  }
  verifyTx() {
    printf 'inherited-verifyTx:%s\n' "${INHERITED_LIGHT_SECRET}" >> "${event_log}"
    return 70
  }

  # shellcheck source=/dev/null
  . "${REGISTRY_SOURCE}"
  # shellcheck source=/dev/null
  . "${CONTEXT_SOURCE}"
  # shellcheck source=/dev/null
  . "${RESULT_SOURCE}"
  # shellcheck source=/dev/null
  . "${INERT_ACTION}"
  capture_open_fds fd_before || fail "${scenario} could not capture initial FDs"
  set +e
  _cntools_action_wallet_register_prefixed_main "${context_file}" "${result_file}" \
    > "${stdout_file}" 2> "${stderr_file}"
  status=$?
  set -e
  capture_open_fds fd_after || fail "${scenario} could not capture final FDs"
  [[ "${fd_after}" == "${fd_before}" ]] ||
    fail "${scenario}${run_label:+/${run_label}} leaked descriptors (${fd_before} -> ${fd_after})"
  [[ "${status}" == "${expected_status}" ]] ||
    fail "${scenario} hardened status ${status}, expected ${expected_status}"
  case "${scenario}" in
    light-preinvoke-tool-drift|light-preinvoke-fd-drift)
      [[ "$(wc -l < "${curl_log}" | tr -d '[:space:]')" == 2 ]] ||
        fail "${scenario} crossed an unexpected LIGHT transport boundary"
      ! grep -Fq '/ogmios/' "${curl_log}" ||
        fail "${scenario} invoked the LIGHT submission transport"
      ;;
    local-callback-marker-forgery-preinvoke-drift)
      [[ ! -s "${stdout_file}" &&
         "$(< "${stderr_file}")" == \
           'CNTools wallet-register action failed validation.' ]] ||
        fail "${scenario} diagnostic boundary changed"
      ! grep -Fq $'cardano-cli\tlatest\ttransaction\tsubmit' "${cli_log}" ||
        fail "${scenario} invoked LOCAL submission"
      ! grep -Fq $'cardano-cli\tquery\tutxo\t--tx-in' "${cli_log}" ||
        fail "${scenario} entered LOCAL reconciliation"
      ! grep -Fq 'submission outcome is ambiguous' "${event_log}" ||
        fail "${scenario} retained forged ambiguity authority"
      ;;
    online-callback-tool-corruption|hybrid-callback-tool-corruption)
      [[ ! -s "${stdout_file}" &&
         "$(< "${stderr_file}")" == \
           'CNTools wallet-register action failed validation.' ]] ||
        fail "${scenario} diagnostic boundary changed"
      [[ ! -s "${hwcli_log}" ]] ||
        fail "${scenario} executed the substituted hardware tool"
      ;;
    hardware-callback-tool-corruption)
      [[ ! -s "${stdout_file}" &&
         "$(< "${stderr_file}")" == \
           'CNTools wallet-register action failed validation.' ]] ||
        fail "${scenario} diagnostic boundary changed"
      ! grep -Fq -- '--hw-signing-file' "${cli_log}" ||
        fail "${scenario} exposed signing FDs to cardano-cli"
      ;;
    light-callback-marker-forgery-preinvoke-drift)
      [[ ! -s "${stdout_file}" &&
         "$(< "${stderr_file}")" == \
           'CNTools wallet-register action failed validation.' ]] ||
        fail "${scenario} diagnostic boundary changed"
      [[ "$(wc -l < "${curl_log}" | tr -d '[:space:]')" == 2 ]] ||
        fail "${scenario} crossed an unexpected LIGHT transport boundary"
      ! grep -Eq '/(ogmios/|tx_status\?)' "${curl_log}" ||
        fail "${scenario} invoked LIGHT submit or reconciliation"
      ! grep -Fq 'submission outcome is ambiguous' "${event_log}" ||
        fail "${scenario} retained forged ambiguity authority"
      ;;
    light-state-token-global-exfil|light-present-token-global-exfil|\
      light-present-credential-exfil|online-state-input-fd-exfil|\
      online-present-signing-fd-exfil|hardware-state-secret-exfil|\
      hardware-present-signing-fd-exfil|hybrid-state-secret-exfil)
      [[ ! -s "${stdout_file}" &&
         "$(< "${stderr_file}")" == \
           'CNTools wallet-register action failed validation.' ]] ||
        fail "${scenario} callback secrecy diagnostic boundary changed"
      ! grep -Fq 'callback-read:' "${event_log}" ||
        fail "${scenario} callback read an action-owned descriptor"
      ! grep -Eq '^callback-(header|action-header):.+$' "${event_log}" ||
        fail "${scenario} callback observed credential state"
      ! grep -Fq $'cardano-cli\tlatest\ttransaction\tsubmit' "${cli_log}" ||
        fail "${scenario} invoked LOCAL submission"
      ! grep -Eq '/(ogmios/|tx_status\?)' "${curl_log}" ||
        fail "${scenario} invoked LIGHT submit or reconciliation"
      ! grep -Fq 'submission outcome is ambiguous' "${event_log}" ||
        fail "${scenario} retained callback-forged ambiguity authority"
      ;;
    state-result-forgery|present-result-forgery|\
      state-context-mutation-exfil|present-private-parent-mutation-exfil)
      [[ ! -s "${stdout_file}" &&
         "$(< "${stderr_file}")" == \
           'CNTools wallet-register action failed validation.' ]] ||
        fail "${scenario} callback private-state diagnostic boundary changed"
      grep -Fq \
        'callback-private:result=:context=:parent=:action=:module=:payload=' \
        "${event_log}" ||
        fail "${scenario} observed an action/dispatcher private alias"
      ! grep -Fq 'callback-private-bash-argv:' "${event_log}" ||
        fail "${scenario} recovered a private path through Bash arguments"
      [[ ! -e "${result_file}" && ! -L "${result_file}" ]] ||
        fail "${scenario} retained a forged canonical dispatcher result"
      ! grep -R -Fq 'FORGED-DISPATCH-PAYLOAD' "${case_root}" ||
        fail "${scenario} retained forged dispatcher payload bytes"
      [[ ! -s "${cli_log}" && ! -s "${curl_log}" &&
         ! -s "${hwcli_log}" && ! -s "${acceptance_log}" ]] ||
        fail "${scenario} crossed a transaction or acceptance boundary"
      ;;
    light-readonly-headers|light-readonly-exported-headers)
      [[ ! -s "${stdout_file}" &&
         "$(< "${stderr_file}")" == \
           'CNTools wallet-register action failed validation.' ]] ||
        fail "${scenario} readonly-header diagnostic boundary changed"
      [[ ! -s "${event_log}" && ! -s "${cli_log}" &&
         ! -s "${curl_log}" && ! -s "${hwcli_log}" &&
         ! -s "${cntools_log}" && ! -s "${acceptance_log}" ]] ||
        fail "${scenario} crossed the earliest readonly-header boundary"
      ;;
  esac
  lock_path="${wallet_root}/.fixture_wallet.cntools-wallet-register.lock"
  if [[ "${expect_cleanup}" == Y ]]; then
    [[ ! -e "${lock_path}" && ! -L "${lock_path}" ]] ||
      fail "${scenario} left its private lock/stage tree"
  else
    [[ -d "${lock_path}/stage" && -f "${lock_path}/stage/foreign" ]] ||
      fail "${scenario} cleanup-uncertainty seam changed"
  fi
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] ||
    fail "${scenario} unexpectedly mutated the dispatcher result path"
  [[ "$(grep -c '^wait$' "${event_log}" || true)" == "${expected_wait}" ]] ||
    fail "${scenario} action-owned wait count changed"
  ! grep -Fq "${RAW_DIAGNOSTIC}" "${stdout_file}" "${stderr_file}" "${event_log}" ||
    fail "${scenario} reflected a raw external diagnostic"
  ! grep -Fq "${SIGNING_SECRET}" "${stdout_file}" "${stderr_file}" \
    "${event_log}" "${cli_log}" "${curl_log}" "${hwcli_log}" ||
    fail "${scenario} exposed signing material"
  ! grep -Fq "${KOIOS_HEADER_SECRET}" "${stdout_file}" "${stderr_file}" \
    "${event_log}" "${cli_log}" "${curl_log}" "${hwcli_log}" \
    "${cntools_log}" ||
    fail "${scenario} exposed a configured Koios header"
  ! grep -Fq "${LIGHT_ARGV_SECRET}" "${stdout_file}" "${stderr_file}" \
    "${event_log}" "${cli_log}" "${curl_log}" "${hwcli_log}" \
    "${cntools_log}" || fail "${scenario} exposed the LIGHT argv/log canary"
  ! grep -Fq "${INHERITED_LIGHT_SECRET}" "${stdout_file}" "${stderr_file}" \
    "${event_log}" "${cli_log}" "${curl_log}" "${hwcli_log}" \
    "${cntools_log}" ||
    fail "${scenario} crossed an inherited LIGHT helper boundary"
  while IFS= builtin read -r argument; do
    case "${argument}" in
      *payment.skey*|*stake.skey*|*payment.hw.skey*|*stake.hw.skey*|\
        *payment.vkey*|*stake.vkey*|*protparams.json*|*certificate.json*)
        fail "${scenario} passed an authenticated input pathname to cardano-cli"
        ;;
    esac
  done < "${cli_log}"
  [[ "$(file_hash "${outside}")" == "${outside_hash}" &&
     "$(file_mode "${outside}")" == "${outside_mode}" &&
     "$(file_links "${outside}")" == "${outside_links}" ]] ||
    fail "${scenario} changed the outside certificate canary"
  case "${scenario}" in
    success|hardware-success|hybrid-success|multisig-success|light-success|\
      light-exported-headers-success|\
      light-postsubmit-cleanup|light-reflect-submit-cleanup|\
      light-reflect-verify-cleanup|\
      submit-fail|local-ambiguous-seen|local-ambiguous-unseen|\
      light-accepted-nonzero|light-ambiguous-seen|light-ambiguous-unseen|\
      signal-postcommit|postsubmit-tool-replace|postsubmit-fd-rebind|\
      postsubmit-cleanup|postsubmit-final-link)
      [[ -f "${wallet_dir}/stake.cert" && ! -L "${wallet_dir}/stake.cert" ]] ||
        fail "${scenario} did not publish its certificate"
      assert_mode "${wallet_dir}/stake.cert" 600 "${scenario} certificate"
      _expected_certificate_links=1
      case "${scenario}" in
        postsubmit-cleanup|light-postsubmit-cleanup|\
          light-reflect-submit-cleanup|light-reflect-verify-cleanup|\
          postsubmit-final-link)
          _expected_certificate_links=2
          ;;
      esac
      [[ "$(file_links "${wallet_dir}/stake.cert")" == \
         "${_expected_certificate_links}" ]] ||
        fail "${scenario} certificate link count changed"
      "${REAL_JQ_PATH}" -e '.type == "StakeAddressRegistrationCertificate"' \
        "${wallet_dir}/stake.cert" >/dev/null ||
        fail "${scenario} certificate schema changed"
      ;;
    cert-symlink)
      [[ -L "${wallet_dir}/stake.cert" &&
         "$(readlink "${wallet_dir}/stake.cert")" == "${outside}" ]] ||
        fail 'hardened immediate certificate symlink changed'
      ;;
    cert-hardlink)
      [[ "${wallet_dir}/stake.cert" -ef "${outside}" ]] ||
        fail 'hardened immediate certificate hardlink changed'
      ;;
    cert-fifo)
      [[ -p "${wallet_dir}/stake.cert" ]] ||
        fail 'hardened immediate certificate FIFO changed'
      ;;
    *)
      [[ ! -e "${wallet_dir}/stake.cert" && ! -L "${wallet_dir}/stake.cert" ]] ||
        fail "${scenario} committed a certificate"
      ;;
  esac
  if [[ "${expect_offline}" == Y ]]; then
    offline_file="$(find "${tmp_root}" -mindepth 1 -maxdepth 1 \
      -type f -name 'offline_tx_*.json' -print)"
    [[ -n "${offline_file}" && "${offline_file}" != *$'\n'* ]] ||
      fail "${scenario} offline package inventory changed"
    assert_mode "${offline_file}" 600 "${scenario} offline package"
    [[ "$(file_links "${offline_file}")" == 1 ]] ||
      fail "${scenario} offline package link count changed"
    "${REAL_JQ_PATH}" -e '.type == "Wallet Registration" and
      ."wallet-name" == "fixture_wallet"' "${offline_file}" >/dev/null ||
      fail "${scenario} offline package schema changed"
    assert_real_offline_signer_temporal_oracle "${offline_file}" \
      "${case_bin}/date" "${cli_log}"
  else
    [[ -z "$(find "${tmp_root}" -mindepth 1 -maxdepth 1 \
      -type f -name 'offline_tx_*.json' -print)" ]] ||
      fail "${scenario} unexpectedly published an offline package"
  fi
  if [[ "${scenario}" == signal-postcommit ]]; then
    grep -Fq 'WARN: wallet registration committed while an interrupt was pending.' \
      "${event_log}" || fail 'postcommit signal warning changed'
  fi
  case "${scenario}" in
    submit-fail|local-ambiguous-unseen|light-ambiguous-unseen)
      grep -Fq 'submission outcome is ambiguous' "${event_log}" ||
        fail "${scenario} lost its retained-certificate ambiguity warning"
      ;;
    postsubmit-tool-replace|postsubmit-fd-rebind|postsubmit-cleanup|\
      light-postsubmit-cleanup|light-reflect-submit-cleanup|\
      light-reflect-verify-cleanup|\
      postsubmit-final-link)
      grep -Fq 'post-commit cleanup or verification requires attention' \
        "${event_log}" ||
        fail "${scenario} lost its postcommit integrity warning"
      ;;
  esac
  case "${scenario}" in
    submit-fail|local-ambiguous-seen|local-ambiguous-unseen)
      [[ "$(grep -Fc -- $'cardano-cli\tquery\tutxo\t--tx-in\t'"${TX_HASH}"'#0' \
          "${cli_log}" || true)" == 1 ]] ||
        fail "${scenario} local reconciliation was not exactly bounded"
      ;;
    light-ambiguous-seen|light-ambiguous-unseen|light-reflect-verify-cleanup)
      [[ "$(grep -c 'tx_status' "${curl_log}" || true)" == 1 ]] ||
        fail "${scenario} LIGHT reconciliation was not exactly bounded"
      ;;
  esac
  if [[ "${action_mode}" == light ]]; then
    ! grep -R -Fq -- "${KOIOS_HEADER_SECRET}" "${case_root}" ||
      fail "${scenario} real LIGHT canary leaked its token into a retained artifact"
    ! grep -R -Fq -- "${LIGHT_ARGV_SECRET}" "${case_root}" ||
      fail "${scenario} real LIGHT argv canary leaked into a retained artifact"
  fi
  case "${scenario}" in
    success|hardware-success|light-success|light-exported-headers-success|\
      submit-fail|local-ambiguous-seen|local-ambiguous-unseen|\
      light-accepted-nonzero|light-ambiguous-seen|light-ambiguous-unseen|\
      signal-postcommit|postsubmit-tool-replace|postsubmit-fd-rebind|\
      postsubmit-cleanup|light-postsubmit-cleanup|\
      light-reflect-submit-cleanup|light-reflect-verify-cleanup|\
      postsubmit-final-link)
      [[ "$(wc -l < "${acceptance_log}" | tr -d '[:space:]')" == 1 ]] ||
        fail "${scenario} acceptance canary count changed"
      ;;
    light-rejected)
      [[ "$(wc -l < "${acceptance_log}" | tr -d '[:space:]')" == 1 ]] ||
        fail 'explicit LIGHT rejection did not cross the submit boundary once'
      ;;
    *) [[ ! -s "${acceptance_log}" ]] ||
      fail "${scenario} unexpectedly crossed the submit boundary" ;;
  esac
)

run_hardened_response_nul_case() (
  local leaf="$1" case_root="${TEST_ROOT}/hardened/response-nul-${1%%.*}"
  local stdout_file="${case_root}/stdout" stderr_file="${case_root}/stderr"
  local status=0 fd_before="" fd_after=""
  local wallet_register_stage="${case_root}/stage"
  local wallet_register_stat_path="" wallet_register_jq_path=""
  local wallet_register_hash_path="" wallet_register_hash_kind=""
  local wallet_register_rm_path="" wallet_register_metadata=""
  local wallet_register_tool_digest="" wallet_register_digest_fd=""
  local wallet_register_response_writer_fd=""
  local wallet_register_response_reader_fd=""
  local wallet_register_response_hash_fd=""
  local wallet_register_response_identity=""
  local wallet_register_response_unlinked=N
  local wallet_register_response_leaf="" wallet_register_response_value=""
  local wallet_register_response_digest=""
  local wallet_register_response_raw_digest=""
  local wallet_register_response_check_digest=""
  local wallet_register_signal_pending=N wallet_register_committed=N
  local -a wallet_register_stage_leaves=()
  local -A wallet_register_stage_identities=() wallet_register_stage_digests=()
  local -A wallet_register_tool_paths=() wallet_register_tool_metadata=()
  local -A wallet_register_tool_digests=()

  mkdir -p -- "${wallet_register_stage}"
  : > "${stdout_file}"
  : > "${stderr_file}"
  # shellcheck source=/dev/null
  . "${REGISTRY_SOURCE}"
  # shellcheck source=/dev/null
  . "${INERT_ACTION}"

  _cntools_registry_tool_path stat wallet_register_stat_path ||
    fail "${leaf} NUL probe could not resolve stat"
  _cntools_registry_tool_path jq wallet_register_jq_path ||
    fail "${leaf} NUL probe could not resolve jq"
  _cntools_registry_tool_path rm wallet_register_rm_path ||
    fail "${leaf} NUL probe could not resolve rm"
  if _cntools_registry_tool_path sha256sum wallet_register_hash_path; then
    wallet_register_hash_kind=sha256sum
  elif _cntools_registry_tool_path shasum wallet_register_hash_path; then
    wallet_register_hash_kind=shasum
  else
    fail "${leaf} NUL probe could not resolve a hash tool"
  fi
  _cntools_action_wallet_register_executable_capture \
    "${wallet_register_stat_path}" stat || fail "${leaf} NUL stat capture failed"
  _cntools_action_wallet_register_executable_capture \
    "${wallet_register_hash_path}" hash || fail "${leaf} NUL hash capture failed"
  _cntools_action_wallet_register_executable_capture \
    "${wallet_register_jq_path}" jq || fail "${leaf} NUL jq capture failed"
  _cntools_action_wallet_register_executable_capture \
    "${wallet_register_rm_path}" rm || fail "${leaf} NUL rm capture failed"

  capture_open_fds fd_before || fail "${leaf} NUL initial FD capture failed"
  _cntools_action_wallet_register_response_open "${leaf}" ||
    fail "${leaf} NUL anonymous response open failed"
  case "${leaf}" in
    utxo.json)
      builtin printf \
        '[{"add\000ress":"%s","tx_hash":"%s","tx_index":0,"value":10000000,"asset_list":[],"reflection":"%s"}]' \
        "${BASE_ADDR}" "${TX_HASH}" "${KOIOS_HEADER_SECRET}" \
        >&"${wallet_register_response_writer_fd}"
      ;;
    stake.json)
      builtin printf \
        '[{"stake_address":"%s","sta\000tus":"registered","delegated_pool":null,"delegated_drep":null,"rewards_available":0,"deposit":0,"reflection":"%s"}]' \
        "${REWARD_ADDR}" "${KOIOS_HEADER_SECRET}" \
        >&"${wallet_register_response_writer_fd}"
      ;;
    submit.out)
      builtin printf \
        '{"jsonr\000pc":"2.0","result":{"transaction":{"id":"%s"}},"reflection":"%s"}' \
        "${TX_HASH}" "${KOIOS_HEADER_SECRET}" \
        >&"${wallet_register_response_writer_fd}"
      ;;
    verify.out)
      builtin printf \
        '[{"tx_hash":"%s","num_confirma\000tions":0,"reflection":"%s"}]' \
        "${TX_HASH}" "${KOIOS_HEADER_SECRET}" \
        >&"${wallet_register_response_writer_fd}"
      ;;
    *) fail "unknown NUL response leaf: ${leaf}" ;;
  esac
  set +e
  _cntools_action_wallet_register_response_capture 1 1048576 \
    > "${stdout_file}" 2> "${stderr_file}"
  status=$?
  set -e
  capture_open_fds fd_after || fail "${leaf} NUL final FD capture failed"

  [[ "${status}" == 70 ]] ||
    fail "${leaf} NUL response status ${status}, expected 70"
  [[ "${wallet_register_committed}" == N ]] ||
    fail "${leaf} NUL response crossed a commit boundary"
  [[ "${fd_after}" == "${fd_before}" ]] ||
    fail "${leaf} NUL response leaked descriptors (${fd_before} -> ${fd_after})"
  [[ ! -s "${stdout_file}" && ! -s "${stderr_file}" ]] ||
    fail "${leaf} NUL response rendered a diagnostic"
  [[ ! -e "${wallet_register_stage}/${leaf}" &&
     ! -L "${wallet_register_stage}/${leaf}" ]] ||
    fail "${leaf} NUL response retained its raw carrier"
  ! grep -R -Fq -- "${KOIOS_HEADER_SECRET}" "${case_root}" ||
    fail "${leaf} NUL response retained a reflected credential"
)

run_hardened_action_case success 0
run_hardened_action_case hardware-success 0
run_hardened_action_case certificate-fail 21
run_hardened_action_case hybrid-success 0
run_hardened_action_case multisig-success 0
run_hardened_action_case light-success 0
run_hardened_action_case light-exported-headers-success 0
run_hardened_action_case light-readonly-headers 70
run_hardened_action_case light-readonly-exported-headers 70
run_hardened_action_case state-result-forgery 70
run_hardened_action_case present-result-forgery 70
run_hardened_action_case state-context-mutation-exfil 70
run_hardened_action_case present-private-parent-mutation-exfil 70
run_hardened_action_case light-postsubmit-cleanup 0
run_hardened_action_case light-reflect-utxo-cleanup 70
run_hardened_action_case light-reflect-stake-cleanup 70
run_hardened_action_case light-reflect-submit-cleanup 0
run_hardened_action_case light-reflect-verify-cleanup 0
run_hardened_action_case query-fail 21
run_hardened_action_case empty-query 21
run_hardened_action_case submit-fail 0
run_hardened_action_case local-ambiguous-seen 0
run_hardened_action_case local-ambiguous-unseen 0
run_hardened_action_case light-accepted-nonzero 0
run_hardened_action_case light-rejected 21
run_hardened_action_case light-ambiguous-seen 0
run_hardened_action_case light-ambiguous-unseen 0
run_hardened_action_case malformed-query 70
run_hardened_action_case malformed-certificate 70
run_hardened_action_case cert-symlink 70
run_hardened_action_case cert-hardlink 70
run_hardened_action_case cert-fifo 70
run_hardened_action_case late-cert-symlink 70
run_hardened_action_case late-cert-hardlink 70
run_hardened_action_case late-cert-fifo 70
run_hardened_action_case signal-precommit 70
run_hardened_action_case signal-postcommit 0
run_hardened_action_case postsubmit-fd-rebind 0
run_hardened_action_case postsubmit-cleanup 0
run_hardened_action_case postsubmit-final-link 0
run_hardened_action_case postsubmit-tool-replace 0
run_hardened_action_case cleanup-foreign 70
run_hardened_action_case context-mismatch 64
run_hardened_action_case signing-key-mode 70
run_hardened_action_case duration-zero 70
run_hardened_action_case duration-noncanonical 70
run_hardened_action_case duration-overflow 70
run_hardened_action_case duration-boundary 70
run_hardened_action_case ttl-jq-overflow 70
run_hardened_action_case late-curl-replace 70
run_hardened_action_case late-ccli-replace 70
run_hardened_action_case late-jq-replace 70
run_hardened_action_case initial-ccli-hardlink 70
run_hardened_action_case preinvoke-tool-drift 70
run_hardened_action_case preinvoke-fd-drift 70
run_hardened_action_case light-preinvoke-tool-drift 70
run_hardened_action_case light-preinvoke-fd-drift 70
run_hardened_action_case local-callback-marker-forgery-preinvoke-drift 70
run_hardened_action_case light-callback-marker-forgery-preinvoke-drift 70
run_hardened_action_case online-callback-tool-corruption 70
run_hardened_action_case hybrid-callback-tool-corruption 70
run_hardened_action_case hardware-callback-tool-corruption 70
run_hardened_action_case light-state-token-global-exfil 70
run_hardened_action_case light-present-token-global-exfil 70
run_hardened_action_case light-present-credential-exfil 70
run_hardened_action_case online-state-input-fd-exfil 70
run_hardened_action_case online-present-signing-fd-exfil 70
run_hardened_action_case hybrid-state-secret-exfil 70
run_hardened_action_case hardware-state-secret-exfil 70
run_hardened_action_case hardware-present-signing-fd-exfil 70
run_hardened_action_case success 0 repeat
run_hardened_action_case certificate-fail 21 repeat
run_hardened_action_case local-ambiguous-unseen 0 repeat
run_hardened_action_case postsubmit-cleanup 0 repeat
run_hardened_response_nul_case utxo.json
run_hardened_response_nul_case stake.json
run_hardened_response_nul_case submit.out
run_hardened_response_nul_case verify.out

run_hardened_abi_case() (
  local label="$1" status=0 stdout_file="" stderr_file=""
  shift
  stdout_file="${TEST_ROOT}/hardened/abi-${label}.stdout"
  stderr_file="${TEST_ROOT}/hardened/abi-${label}.stderr"
  # shellcheck source=/dev/null
  . "${INERT_ACTION}"
  set +e
  cntools_action_main "$@" > "${stdout_file}" 2> "${stderr_file}"
  status=$?
  set -e
  [[ "${status}" == 64 ]] || fail "${label} hardened ABI status changed"
  [[ ! -s "${stdout_file}" && ! -s "${stderr_file}" ]] ||
    fail "${label} hardened ABI emitted output"
)

run_hardened_abi_case zero-args
run_hardened_abi_case one-arg only
run_hardened_abi_case three-args one two three

direct_stdout="${TEST_ROOT}/hardened/direct-launch.stdout"
direct_stderr="${TEST_ROOT}/hardened/direct-launch.stderr"
set +e
"${BASH}" "${INERT_ACTION}" > "${direct_stdout}" 2> "${direct_stderr}"
direct_status=$?
set -e
[[ "${direct_status}" == 64 && ! -s "${direct_stdout}" ]] ||
  fail 'hardened direct-launch status/output changed'
[[ "$(< "${direct_stderr}")" == \
   'CNTools actions are launched by the dispatcher, not directly.' ]] ||
  fail 'hardened direct-launch diagnostic changed'

REGISTER_ARM="${TEST_ROOT}/wallet-register.arm"
REGISTER_HELPER="${TEST_ROOT}/registerStakeWallet.function"
awk '
  /^[[:space:]]+register\)/ { capture=1 }
  /^[[:space:]]+deregister\)/ { capture=0 }
  capture { print }
' "${CNTOOLS_SCRIPT}" > "${REGISTER_ARM}"
awk '
  /^registerStakeWallet\(\)/ { capture=1 }
  /^# Command[[:space:]]+: deregisterStakeWallet/ { capture=0 }
  capture { print }
' "${WALLET_REGISTRATION_SOURCE}" > "${REGISTER_HELPER}"

[[ "$(wc -l < "${REGISTER_ARM}" | tr -d '[:space:]')" == 49 ]] ||
  fail 'inline wallet.register arm length changed'
[[ "$(file_hash "${REGISTER_ARM}")" == b386fbc8f3058587f4a6faeb882864ec5c8043c01eccb188ae0ed95cfdd65335 ]] ||
  fail 'inline wallet.register arm exact fingerprint changed'
[[ "$(wc -l < "${REGISTER_HELPER}" | tr -d '[:space:]')" == 144 ]] ||
  fail 'inherited registerStakeWallet length changed'
[[ "$(file_hash "${REGISTER_HELPER}")" == 2808345eba5332776fb3485a03fd322291b958400ad3329afc922b3eca526932 ]] ||
  fail 'inherited registerStakeWallet exact fingerprint changed'
[[ "$(file_hash "${WALLET_REGISTRATION_SOURCE}")" == 2ff4b5f29674fb1cf65e5cda736c9e4f41af51adbe76b29fa5a41bb369f63fdc ]] ||
  fail 'authenticated inherited wallet helper member changed'
[[ "$(file_hash "${INERT_ACTION}")" == 80dbbb06a71d009b7776989b0d92eecd14cbe81bc9594b920866021cdbd37796 ]] ||
  fail 'hardened wallet.register action exact fingerprint changed'
[[ "$(file_mode "${INERT_ACTION}")" == 644 ]] ||
  fail 'hardened wallet.register action mode changed'

awk '
  /KOIOS_API_HEADERS\[4096\]=/ { readonly_probe=NR }
  /_cntools_registry_tool_path stat wallet_register_stat_path/ { first_tool=NR }
  /_cntools_action_wallet_register_present clear/ { first_callback=NR }
  END {
    exit !(readonly_probe && first_tool && first_callback &&
      readonly_probe < first_tool && readonly_probe < first_callback)
  }
' "${INERT_ACTION}" ||
  fail 'readonly LIGHT header rejection is no longer pre-tool/pre-callback'
if grep -Fq "'declare -ar" "${INERT_ACTION}"; then
  fail 'readonly LIGHT header declarations remain accepted at carrier open'
fi

awk '
  /^_cntools_action_wallet_register_callback_dispatch\(\)/ { inside=1 }
  inside && /secret_names=\(/ { inventory=NR }
  inside && /^[[:space:]]+result_file result_path private_parent private_root/ {
    result_hidden=NR
  }
  inside && /^[[:space:]]+source_module source_action snapshot_directory/ {
    snapshot_hidden=NR
  }
  inside && /^[[:space:]]+payload payload_file payload_path/ {
    payload_hidden=NR
  }
  inside && /for candidate_fd in "\$\{authority_fds\[@\]\}"/ { authority=NR }
  inside && /exec \{candidate_fd\}>&-/ { closed=NR }
  inside && /"\$\{callback\}" "\$@" 1>&"\$\{keep_ui_fd\}"/ { invoked=NR }
  inside && /^}/ {
    if (inventory && result_hidden && snapshot_hidden && payload_hidden &&
        authority && closed && invoked && inventory < result_hidden &&
        result_hidden < authority && authority < closed && closed < invoked) ok=1
    exit !ok
  }
' "${INERT_ACTION}" ||
  fail 'callback private-state/descriptor sanitization ordering changed'
awk '
  /wallet_register_callback_result_path="\$\{result_file\}"/ { snapshot=NR }
  /wallet_register_callback_boundary_active=Y/ { active=NR }
  /_cntools_action_wallet_register_present clear/ { first_callback=NR }
  END {
    exit !(snapshot && active && first_callback &&
      snapshot < active && active < first_callback)
  }
' "${INERT_ACTION}" ||
  fail 'callback filesystem authority is not active before first callback'
[[ "$(grep -Fc '_cntools_action_wallet_register_callback_boundary_verify' \
    "${INERT_ACTION}")" == 3 ]] ||
  fail 'state/presentation callback filesystem verification coverage changed'
awk '
  /^_cntools_action_wallet_register_prefixed_main\(\)/ { inside=1 }
  inside && /builtin set --/ { cleared=NR }
  inside && /_cntools_action_wallet_register_present clear/ { callback=NR }
  inside && callback { exit !(cleared && cleared < callback) }
' "${INERT_ACTION}" ||
  fail 'callback boundary exposes action positional path arguments'
awk '
  /^_cntools_action_wallet_register_headers_open\(\)/ { inside=1 }
  inside && /_cntools_action_wallet_register_prepare_curl_headers/ { imported=NR }
  inside && /wallet_register_koios_headers=\(\)/ { cleared=NR }
  inside && /_cntools_action_wallet_register_present/ { callback=NR }
  inside && /^}/ {
    exit !(imported && cleared && imported < cleared && !callback)
  }
' "${INERT_ACTION}" ||
  fail 'LIGHT credential variable lifetime ordering changed'
awk '
  /^_cntools_action_wallet_register_light_query\(\)/ { inside=1 }
  inside && /_cntools_action_wallet_register_response_clear/ { cleared=1 }
  inside && /^}/ { exit !cleared }
' "${INERT_ACTION}" ||
  fail 'LIGHT authenticated response was retained across later callbacks'
[[ "$(grep -Fc '_cntools_action_wallet_register_callback_dispatch' \
    "${INERT_ACTION}")" == 3 ]] ||
  fail 'inherited callback dispatch boundary changed'

grep -Fq 'selectWallet "non-reg"' "${REGISTER_ARM}" ||
  fail 'inline non-registered selection boundary changed'
grep -Fq 'getWalletBalance ${wallet_name} true true false true' "${REGISTER_ARM}" ||
  fail 'inline forced balance-query vector changed'
grep -Fq 'registerStakeWallet ${wallet_name} "true"' "${REGISTER_ARM}" ||
  fail 'inline registration-helper ABI changed'
if grep -Fq 'cntools_compatibility_dispatch_action wallet.register' "${REGISTER_ARM}"; then
  fail 'wallet.register was extracted during characterization-only checkpoint'
fi
grep -Fq 'stdout=$(${CCLI} latest stake-address registration-certificate' \
  "${REGISTER_HELPER}" || fail 'certificate command boundary changed'
grep -Fq 'offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"' \
  "${REGISTER_HELPER}" || fail 'legacy jq-controlled offline path behavior changed'
grep -Fq 'println ERROR "\n${FG_RED}ERROR${NC}: failure during stake registration certificate creation!\n${stdout}"' \
  "${REGISTER_HELPER}" || fail 'legacy raw certificate diagnostic behavior changed'

printf 'CNTools wallet-register characterization passed (%s public + %s query + %s transaction/JQ + 3 operation-mode + 78 hardened cases)\n' \
  "${#PUBLIC_CASES[@]}" "${#QUERY_CASES[@]}" \
  "$(( ${#DIRECT_CASES[@]} + ${#JQ_FAILURE_CASES[@]} ))"
