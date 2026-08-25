#!/usr/bin/env bash
# Characterize the bound wallet.deregister controller route, its authenticated
# modular action, and the frozen inherited legacy query/transaction behavior.
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2154,SC2317,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet-deregister characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
LEGACY_BUNDLE_ID='6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59'
LEGACY_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/${LEGACY_BUNDLE_ID}"
COMMON_DIALOG_SOURCE="${LEGACY_ROOT}/010-common-dialog.sh"
SELECTION_SOURCE="${LEGACY_ROOT}/020-terminal-selection-security.sh"
GOVERNANCE_QUERY_SOURCE="${LEGACY_ROOT}/030-governance-query.sh"
WALLET_QUERY_SOURCE="${LEGACY_ROOT}/040-address-wallet-query.sh"
WALLET_REGISTRATION_SOURCE="${LEGACY_ROOT}/050-wallet-create-registration.sh"
TRANSACTION_SOURCE="${LEGACY_ROOT}/100-transaction-hardware-price.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/wallet/deregister/action.sh"
ACTION_DIRECTORY="${ACTION_SOURCE%/*}"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet-deregister.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
REAL_JQ_PATH="$(command -v jq)"
REAL_MKDIR_PATH="$(command -v mkdir)"
REAL_RM_PATH="$(command -v rm)"
REAL_RMDIR_PATH="$(command -v rmdir)"
REAL_LN_PATH="$(command -v ln)"
BASE_ADDR='addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
PAY_ADDR='addr_test1pppppppppppppppppppppppppppppppppppppppp'
REWARD_ADDR='stake_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
TX_HASH='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
RAW_DIAGNOSTIC='RAW_DEREGISTER_DIAGNOSTIC_DO_NOT_RENDER'
SIGNING_SECRET='DEREGISTER_SIGNING_CBOR_SECRET_DO_NOT_EXPOSE'

cleanup_test() {
  if [[ "${CNTOOLS_WALLET_DEREGISTER_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools wallet-deregister test root preserved: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools wallet-deregister characterization failed: %s\n' "$1" >&2
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

fd_inventory_into() {
  local output_name="$1" descriptor=0 inventory=""

  [[ "${output_name}" =~ ^hardened_fd_(before|after)$ ]] || return 1
  for ((descriptor=0; descriptor<=1023; descriptor++)); do
    [[ -e "/dev/fd/${descriptor}" ]] || continue
    inventory+="${descriptor},"
  done
  printf -v "${output_name}" '%s' "${inventory}"
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk basename cmp cut find grep jq mktemp readlink \
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
  "${REGISTRY_SOURCE}" "${CONTEXT_SOURCE}" "${RESULT_SOURCE}" \
  "${DISPATCHER_SOURCE}" "${ACTION_SOURCE}"; do
  [[ -f "${source_file}" && ! -L "${source_file}" ]] ||
    fail "required source is missing or unsafe: ${source_file}"
done

write_fake_commands() {
  local command_name=""

  mkdir -p -- "${FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_DEREGISTER_SCENARIO:?}"' \
    'log="${CNTOOLS_WALLET_DEREGISTER_CLI_LOG:?}"' \
    'previous=""; out_file=""; address=""; argument=""; normalized=""' \
    'for argument in "$@"; do' \
    '  [[ "${previous}" == --out-file ]] && out_file="${argument}"' \
    '  [[ "${previous}" == --address ]] && address="${argument}"' \
    '  previous="${argument}"' \
    'done' \
    'printf '\''cardano-cli'\'' >> "${log}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  if [[ "${normalized}" == "${CNTOOLS_WALLET_DEREGISTER_RUNTIME:?}/"* ]]; then' \
    '    normalized="<runtime>/${normalized#"${CNTOOLS_WALLET_DEREGISTER_RUNTIME}/"}"' \
    '  fi' \
    '  printf '\''\t%q'\'' "${normalized}" >> "${log}"' \
    'done' \
    'printf '\''\n'\'' >> "${log}"' \
    'case "$*" in' \
    '  "address build "*)' \
    '    [[ "${scenario}" != address-build-fail ]] || { printf '\''address build failed\n'\'' >&2; exit 31; }' \
    '    [[ -n "${out_file}" ]] || exit 96' \
    '    if [[ "$*" == *" --stake-"* ]]; then value="${CNTOOLS_WALLET_DEREGISTER_BASE:?}"; else value="${CNTOOLS_WALLET_DEREGISTER_PAY:?}"; fi' \
    '    printf '\''%s\n'\'' "${value}" > "${out_file}"' \
    '    ;;' \
    '  "latest stake-address build "*)' \
    '    [[ "${scenario}" != reward-build-fail ]] || { printf '\''reward build failed\n'\'' >&2; exit 32; }' \
    '    [[ -n "${out_file}" ]] || exit 96' \
    '    printf '\''%s\n'\'' "${CNTOOLS_WALLET_DEREGISTER_REWARD:?}" > "${out_file}"' \
    '    ;;' \
    '  "query utxo "*)' \
    '    [[ "${scenario}" != local-utxo-fail ]] || { printf '\''utxo query failed\n'\'' >&2; exit 33; }' \
    '    if [[ "${address}" == "${CNTOOLS_WALLET_DEREGISTER_BASE:?}" ]]; then amount=10000000; else amount=500000; fi' \
    '    printf '\''%s 0 %s lovelace + TxOutDatumNone\n'\'' "${CNTOOLS_WALLET_DEREGISTER_TX_HASH:?}" "${amount}"' \
    '    ;;' \
    '  "query stake-address-info "*)' \
    '    [[ "${scenario}" != local-stake-query-fail ]] || { printf '\''stake query failed\n'\'' >&2; exit 34; }' \
    '    if [[ "${scenario}" == local-stake-malformed ]]; then printf '\''not-json\n'\''' \
    '    elif [[ "${scenario}" == local-unregistered ]]; then printf '\''[]\n'\''' \
    '    else' \
    '      if [[ "${scenario}" == local-rewards ]]; then rewards=3000000; else rewards=0; fi' \
    '      printf '\''[{"address":"%s","rewardAccountBalance":%s,"stakeRegistrationDeposit":2000000,"govActionDeposits":{}}]\n'\'' "${CNTOOLS_WALLET_DEREGISTER_REWARD:?}" "${rewards}"' \
    '    fi' \
    '    ;;' \
    '  "latest stake-address deregistration-certificate "*)' \
    '    if [[ "${scenario}" == cert-fail || "${scenario}" == raw-diagnostic ]]; then' \
    '      printf '\''%s\\033[31m\\n'\'' "${CNTOOLS_WALLET_DEREGISTER_RAW:?}" >&2; exit 35' \
    '    fi' \
    '    [[ -n "${out_file}" ]] || exit 96' \
    '    [[ ! -p "${out_file}" ]] || exit 36' \
    '    if [[ "${scenario}" == malformed-cert ]]; then printf '\''not-json\\033[31m\n'\'' > "${out_file}"' \
    '    else printf '\''{"type":"StakeAddressDeregistrationCertificate","description":"fixture"}\n'\'' > "${out_file}"; fi' \
    '    ;;' \
    '  *) printf '\''unexpected cardano-cli vector: %s\n'\'' "$*" >&2; exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/cardano-cli"
  chmod 0755 "${FAKE_BIN}/cardano-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_DEREGISTER_SCENARIO:?}"; log="${CNTOOLS_WALLET_DEREGISTER_CURL_LOG:?}"' \
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
    '    printf '\''%s,%s,0,10000000,"[]"\n'\'' "${CNTOOLS_WALLET_DEREGISTER_BASE:?}" "${CNTOOLS_WALLET_DEREGISTER_TX_HASH:?}"' \
    '    printf '\''%s,%s,1,500000,"[]"\n'\'' "${CNTOOLS_WALLET_DEREGISTER_PAY:?}" "${CNTOOLS_WALLET_DEREGISTER_TX_HASH:?}"' \
    '    ;;' \
    '  */account_info?*)' \
    '    [[ "${scenario}" != koios-reward-fail ]] || { printf '\''reward endpoint failed\n'\'' >&2; exit 28; }' \
    '    printf '\''stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit\n'\''' \
    '    if [[ "${scenario}" == koios-unregistered ]]; then status='\''not registered'\''; else status=registered; fi' \
    '    if [[ "${scenario}" == koios-rewards ]]; then rewards=3000000; else rewards=0; fi' \
    '    printf '\''%s,%s,,,%s,2000000\n'\'' "${CNTOOLS_WALLET_DEREGISTER_REWARD:?}" "${status}" "${rewards}"' \
    '    ;;' \
    '  *) printf '\''unexpected curl URL: %s\n'\'' "${url}" >&2; exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/curl"
  chmod 0755 "${FAKE_BIN}/curl"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'count_file="${CNTOOLS_WALLET_DEREGISTER_JQ_COUNT:?}"; log="${CNTOOLS_WALLET_DEREGISTER_JQ_LOG:?}"' \
    'count=0; [[ ! -f "${count_file}" ]] || read -r count < "${count_file}"; count=$((count + 1)); printf '\''%s\n'\'' "${count}" > "${count_file}"' \
    'printf '\''jq:%02d'\'' "${count}" >> "${log}"; for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${log}"; done; printf '\''\n'\'' >> "${log}"' \
    'if [[ "${CNTOOLS_WALLET_DEREGISTER_JQ_FAIL_CALL:-0}" == "${count}" ]]; then printf '\''%s\\033[31m\\n'\'' "${CNTOOLS_WALLET_DEREGISTER_RAW:?}" >&2; exit 42; fi' \
    'if [[ "${CNTOOLS_WALLET_DEREGISTER_JQ_MALICIOUS_ID:-N}" == Y && "$*" == "-r .id" ]]; then printf '\''x/../../outside-id\n'\''; exit 0; fi' \
    'exec "${CNTOOLS_WALLET_DEREGISTER_REAL_JQ:?}" "$@"' \
    > "${FAKE_BIN}/jq"
  chmod 0755 "${FAKE_BIN}/jq"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  *+%s*) printf '\''1700000000\n'\'' ;;' \
    '  *--iso-8601=s*) printf '\''2023-11-14T22:13:20+00:00\n'\'' ;;' \
    '  *) exec "${CNTOOLS_WALLET_DEREGISTER_REAL_DATE:?}" "$@" ;;' \
    'esac' \
    > "${FAKE_BIN}/date"
  chmod 0755 "${FAKE_BIN}/date"

  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${FAKE_BIN}/tput"
  chmod 0755 "${FAKE_BIN}/tput"

  for command_name in wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_WALLET_DEREGISTER_BLOCKED_LOG:?}"' \
      'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_WALLET_DEREGISTER_BLOCKED_LOG}"; done' \
      'printf '\''\n'\'' >> "${CNTOOLS_WALLET_DEREGISTER_BLOCKED_LOG}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

CNTOOLS_WALLET_DEREGISTER_REAL_DATE="$(command -v date)"
export CNTOOLS_WALLET_DEREGISTER_REAL_DATE
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
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/registry.sh
. "${REGISTRY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/context.sh
. "${CONTEXT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/result.sh
. "${RESULT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/dispatcher.sh
. "${DISPATCHER_SOURCE}"

# Preserve the exact inherited implementations before installing test-only
# controller/dependency adapters below.
eval "$(declare -f selectWallet | sed '1s/^selectWallet/legacy_selectWallet/')"
eval "$(declare -f getWalletBalance | sed '1s/^getWalletBalance/legacy_getWalletBalance/')"
eval "$(declare -f deregisterStakeWallet | sed '1s/^deregisterStakeWallet/legacy_deregisterStakeWallet/')"
eval "$(declare -f selectOpMode | sed '1s/^selectOpMode/legacy_selectOpMode/')"

# The production bridge authenticates an installed immutable generation.  The
# bound public-route matrix substitutes only that authority setup, then invokes
# the real dispatcher and frozen action through the generic controller bridge.
cntools_compatibility_dispatch_action() (
  local action_id="${1:-}" private_root="" context_file="" result_file=""
  local case_root="" public_bin="" context_mode="" capabilities='[]'
  local hardened_scenario="" status=0

  [[ "${action_id}" == wallet.deregister && $# == 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  case_root="${EVENT_LOG%/events}"
  context_mode="${CNTOOLS_MODE,,}"
  [[ "${context_mode}" == local || "${context_mode}" == light ]] || return 70
  [[ "${context_mode}" != local ]] || capabilities='["local-cli"]'
  case "${SCENARIO:?}" in
    deregister-fail) hardened_scenario=certificate-fail ;;
    *) hardened_scenario="${SCENARIO}" ;;
  esac

  PATH="${BASE_PATH}"
  export PATH
  umask 077
  private_root="$(mktemp -d \
    "${case_root}/wallet-deregister-test-dispatch.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  chmod 0700 "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  "${REAL_JQ_PATH}" -nS --arg mode "${context_mode}" \
    --arg node_home "${NODE_HOME}" --argjson capabilities "${capabilities}" '{
      advanced:false,apiVersion:1,capabilities:$capabilities,features:[],
      generationVersion:"13.5.7",mode:$mode,nodeHome:$node_home,
      nodeImplementation:"cnode",nodeNetwork:"preview",schemaVersion:1
    }' > "${context_file}" || return 70
  chmod 0400 "${context_file}" || return 70

  : > "${case_root}/bound.cli"
  : > "${case_root}/bound.hw"
  : > "${case_root}/bound.curl"
  CCLI="${HARDENED_CCLI}"
  HWCLI="${HARDENED_HWCLI}"
  DUMMYFEE=0
  PROT_VERSION=9.0
  NETWORK_IDENTIFIER='--testnet-magic 42'
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
  WALLET_STAKE_DEREG_FILENAME=stake.dereg
  if [[ "${context_mode}" == light ]]; then
    public_bin="${case_root}/bound-bin"
    mkdir -p -- "${public_bin}" || return 70
    write_hardened_curl "${public_bin}" || return 70
    PATH="${public_bin}:${BASE_PATH}"
    KOIOS_API='https://fixture.koios.invalid/api/v1'
    KOIOS_API_HEADERS=(-H 'authorization: LIGHT_QUERY_SECRET_DO_NOT_EXPOSE')
  else
    KOIOS_API=
    KOIOS_API_HEADERS=()
  fi
  export PATH
  unset HEADERS CNTOOLS_LOG
  CNTOOLS_WALLET_DEREGISTER_HARDENED_SCENARIO="${hardened_scenario}"
  CNTOOLS_WALLET_DEREGISTER_HARDENED_CLI_LOG="${case_root}/bound.cli"
  CNTOOLS_WALLET_DEREGISTER_HARDENED_HW_LOG="${case_root}/bound.hw"
  CNTOOLS_WALLET_DEREGISTER_HARDENED_CURL_LOG="${case_root}/bound.curl"
  CNTOOLS_WALLET_DEREGISTER_HARDENED_BASE="${BASE_ADDR}"
  CNTOOLS_WALLET_DEREGISTER_HARDENED_REWARD="${REWARD_ADDR}"
  CNTOOLS_WALLET_DEREGISTER_HARDENED_HASH="${TX_HASH}"
  CNTOOLS_WALLET_DEREGISTER_HARDENED_RAW="${RAW_DIAGNOSTIC}"
  CNTOOLS_WALLET_DEREGISTER_BOUND_DISPATCH=Y
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_SCENARIO
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_CLI_LOG
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_HW_LOG
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_CURL_LOG
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_BASE
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_REWARD
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_HASH
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_RAW
  export CNTOOLS_WALLET_DEREGISTER_BOUND_DISPATCH

  if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"; then
    status=0
  else
    status=$?
  fi
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || status=70
  "${REAL_RM_PATH}" -f -- "${result_file}" "${context_file}" \
    >/dev/null 2>&1 || status=70
  "${REAL_RMDIR_PATH}" -- "${private_root}" >/dev/null 2>&1 || status=70
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]] &&
     ! grep -Fqx 'action:end' "${EVENT_LOG}"; then
    printf '__CNTOOLS_WALLET_DEREGISTER_END__\n'
    printf 'action:end\n' >> "${EVENT_LOG}"
  fi
  return "${status}"
)

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
    printf '__CNTOOLS_WALLET_DEREGISTER_END__\n'
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
    if ! grep -Fqx 'action:end' "${EVENT_LOG}"; then
      printf '__CNTOOLS_WALLET_DEREGISTER_END__\n'
      printf 'action:end\n' >> "${EVENT_LOG}"
    fi
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
      if [[ "${menu}:${choice}" == wallet:z ]]; then
        CAPTURE_ACTIVE=Y
        printf '__CNTOOLS_WALLET_DEREGISTER_BEGIN__\n'
        printf 'action:begin\n' >> "${EVENT_LOG}"
      fi
      selected_value="${option}"
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was unavailable in ${menu} menu"
}
eval "$(declare -f select_opt | sed '1s/^select_opt/bound_public_select_opt/')"

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
  [[ $# == 1 && "${1:-}" == reg ]] || fail 'public wallet filter changed'
  printf 'action:selectWallet:reg\n' >> "${EVENT_LOG:?}"
  case "${SCENARIO:?}" in
    empty|select-fail|none-registered)
      println INFO 'WARN: No wallets available that are registered on chain!'
      return 1
      ;;
    select-cancel) return 2 ;;
    word-splitting|word-splitting-fail) wallet_name='word splitting' ;;
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

getWalletRewards() {
  printf 'action:getWalletRewards:argc=%s:name=%q\n' "$#" "${1:-}" \
    >> "${EVENT_LOG:?}"
  case "${SCENARIO:?}" in
    rewards) reward_lovelace=3000000 ;;
    *) reward_lovelace=0 ;;
  esac
}

getWalletBalance() {
  printf 'action:getWalletBalance:argc=%s:%q\n' "$#" "${1:-}" >> "${EVENT_LOG:?}"
  if [[ "${SCENARIO:-}" == word-splitting ||
        "${SCENARIO:-}" == word-splitting-fail ||
        "${SCENARIO:-}" == control-name ]]; then
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
  base_addr="${BASE_ADDR}"
}

deregisterStakeWallet() {
  printf 'action:deregisterStakeWallet:argc=%s' "$#" >> "${EVENT_LOG:?}"
  for _argument in "$@"; do printf ':%q' "${_argument}" >> "${EVENT_LOG}"; done
  printf '\n' >> "${EVENT_LOG}"
  [[ "$#" == 0 ]] || fail 'public de-registration helper ABI changed'
  stake_dereg_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_DEREG_FILENAME}"
  if [[ "${SCENARIO}" != control-name ]]; then
    mkdir -p -- "${stake_dereg_file%/*}"
    printf '%s\n' '{"type":"StakeAddressDeregistrationCertificate"}' \
      > "${stake_dereg_file}"
  fi
  case "${SCENARIO:?}" in
    deregister-fail|word-splitting-fail) return 1 ;;
    hybrid-prepared)
      printf '%s\n' '{"type":"Wallet De-Registration"}' \
        > "${TMP_DIR}/offline_tx_prepared.json"
      printf 'action:offline-prepared:%q\n' "${TMP_DIR}/offline_tx_prepared.json" \
        >> "${EVENT_LOG:?}"
      return 2
      ;;
  esac
  return 0
}

verifyTx() {
  printf 'action:verifyTx:argc=%s:address=%q\n' "$#" "${1:-}" >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != verify-fail ]]
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${CAPTURE_ACTIVE:-N}" == Y &&
        "${CNTOOLS_WALLET_DEREGISTER_BOUND_DISPATCH:-N}" != Y ]]; then
    if ! grep -Fqx 'action:end' "${EVENT_LOG}"; then
      printf '__CNTOOLS_WALLET_DEREGISTER_END__\n'
      printf 'action:end\n' >> "${EVENT_LOG}"
    fi
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
  [[ "$(grep -c '^__CNTOOLS_WALLET_DEREGISTER_BEGIN__$' "${source}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_WALLET_DEREGISTER_END__$' "${source}" || true)" == 1 ]] ||
    fail 'wallet-deregister output markers changed'
  awk '
    $0 == "__CNTOOLS_WALLET_DEREGISTER_BEGIN__" { capture=1; next }
    $0 == "__CNTOOLS_WALLET_DEREGISTER_END__" { exit }
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
  local blocked_log="" cli_log="" hw_log="" curl_log=""
  local before="" after="" outside_canary="" status=0
  local fixture_name=fixture_wallet

  case_root="${TEST_ROOT}/public/${scenario}"
  runtime_root="${case_root}/runtime"
  wallet_root="${runtime_root}/wallet"
  full_stdout="${case_root}/full.stdout"
  action_stdout="${case_root}/action.stdout"
  stderr_file="${case_root}/stderr"
  event_log="${case_root}/events"
  blocked_log="${case_root}/blocked"
  cli_log="${case_root}/bound.cli"
  hw_log="${case_root}/bound.hw"
  curl_log="${case_root}/bound.curl"
  before="${case_root}/before.tree"
  after="${case_root}/after.tree"
  outside_canary="${case_root}/out-of-scope.canary"
  mode="$(public_mode "${scenario}")"
  mkdir -p -- "${wallet_root}" "${runtime_root}/pool" \
    "${runtime_root}/asset" "${runtime_root}/tmp" "${runtime_root}/home"
  chmod 0700 "${wallet_root}" "${runtime_root}/tmp"
  if [[ "${scenario}" != empty ]]; then
    case "${scenario}" in
      word-splitting) fixture_name='word splitting' ;;
    esac
    mkdir -p -- "${wallet_root}/${fixture_name}"
    chmod 0700 "${wallet_root}/${fixture_name}"
    printf '%s\n' "${BASE_ADDR}" > "${wallet_root}/${fixture_name}/base.addr"
    printf '%s\n' "${PAY_ADDR}" > "${wallet_root}/${fixture_name}/payment.addr"
    printf '%s\n' "${REWARD_ADDR}" > "${wallet_root}/${fixture_name}/stake.addr"
    printf '%s\n' '{"type":"PaymentVerificationKeyShelley_ed25519","description":"fixture","cborHex":"aabb"}' \
      > "${wallet_root}/${fixture_name}/payment.vkey"
    printf '%s\n' '{"type":"StakeVerificationKeyShelley_ed25519","description":"fixture","cborHex":"aabb"}' \
      > "${wallet_root}/${fixture_name}/stake.vkey"
    printf '%s\n' "{\"type\":\"PaymentSigningKeyShelley_ed25519\",\"description\":\"fixture\",\"cborHex\":\"${SIGNING_SECRET}\"}" \
      > "${wallet_root}/${fixture_name}/payment.skey"
    printf '%s\n' "{\"type\":\"StakeSigningKeyShelley_ed25519\",\"description\":\"fixture\",\"cborHex\":\"${SIGNING_SECRET}\"}" \
      > "${wallet_root}/${fixture_name}/stake.skey"
    chmod 0600 "${wallet_root}/${fixture_name}/"*
    if [[ "${scenario}" == existing-certificate ]]; then
      printf '%s\n' '{"cborHex":"aabbccdd","description":"existing fixture","type":"StakeAddressDeregistrationCertificate"}' \
        > "${wallet_root}/${fixture_name}/stake.dereg"
      chmod 0600 "${wallet_root}/${fixture_name}/stake.dereg"
    fi
  fi
  printf '%s\n' '{}' > "${runtime_root}/tmp/protparams.json"
  chmod 0600 "${runtime_root}/tmp/protparams.json"
  write_out_of_scope_canary "${outside_canary}"
  tree_snapshot "${runtime_root}" "${before}" || fail "${scenario} pre-snapshot failed"
  : > "${event_log}"; : > "${blocked_log}"
  : > "${cli_log}"; : > "${hw_log}"; : > "${curl_log}"
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
    WALLET_PAY_VK_FILENAME=payment.vkey; WALLET_PAY_SK_FILENAME=payment.skey
    WALLET_STAKE_VK_FILENAME=stake.vkey; WALLET_STAKE_SK_FILENAME=stake.skey
    WALLET_PAY_SCRIPT_FILENAME=payment.script; WALLET_STAKE_SCRIPT_FILENAME=stake.script
    WALLET_BASE_ADDR_FILENAME=base.addr; WALLET_PAY_ADDR_FILENAME=payment.addr
    WALLET_STAKE_ADDR_FILENAME=stake.addr
    WALLET_STAKE_DEREG_FILENAME=stake.dereg
    price_now=""; slotnum=1000
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}" CAPTURE_ACTIVE=N SCENARIO="${scenario}"
    CNTOOLS_WALLET_DEREGISTER_BLOCKED_LOG="${blocked_log}"
    CHOICES=(w z h q); CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  [[ "${status}" == 0 ]] || fail "${scenario} public traversal returned ${status}"
  extract_action_output "${full_stdout}" "${action_stdout}"
  case "${scenario}" in
    word-splitting|control-name)
      [[ "$(< "${stderr_file}")" == \
        'CNTools wallet-deregister action failed validation.' ]] ||
        fail "${scenario} validation diagnostic changed"
      ;;
    *) [[ ! -s "${stderr_file}" ]] || fail "${scenario} emitted unexpected stderr" ;;
  esac
  [[ ! -s "${blocked_log}" ]] || fail "${scenario} attempted blocked network access"
  assert_no_secret "${scenario} public route" "${full_stdout}" "${stderr_file}" \
    "${event_log}" "${blocked_log}" "${cli_log}" "${hw_log}" "${curl_log}"
  [[ "$(grep -c '^action:compatibility-dispatch$' "${event_log}" || true)" == 1 ]] ||
    fail "${scenario} did not traverse the generic compatibility bridge exactly once"
  ! grep -Eq '^action:(deregisterStakeWallet|verifyTx|getWalletRewards|getWalletBalance)' \
    "${event_log}" || fail "${scenario} reached an inherited de-registration helper"
  grep -Fq ' >> WALLET >> DE-REGISTER' "${action_stdout}" ||
    fail "${scenario} public header changed"

  case "${scenario}" in
    empty)
      grep -Fq 'No registered wallets are available.' "${action_stdout}" ||
        fail 'empty-wallet output changed'
      grep -Fq 'action:selectOpMode' "${event_log}" ||
        fail 'empty-wallet route skipped the action operation-mode prompt'
      grep -Fq 'action:waitToProceed' "${event_log}" ||
        fail 'empty-wallet wait changed'
      ;;
    op-cancel)
      grep -Fq 'action:selectOpMode' "${event_log}" ||
        fail 'operation-mode cancellation was not offered'
      ! grep -Fq 'action:selectWallet' "${event_log}" ||
        fail 'operation-mode cancellation reached wallet selection'
      ! grep -Fq 'action:waitToProceed' "${event_log}" ||
        fail 'operation-mode cancellation unexpectedly waited'
      ;;
    select-fail|none-registered)
      grep -Fq 'No registered wallets are available.' \
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
      ;;
    missing-signing)
      grep -Fq 'required payment or stake wallet keys are missing!' \
        "${action_stdout}" || fail 'missing-signing rejection changed'
      ;;
    rewards)
      grep -Fq 'Withdraw all stake rewards before de-registering this wallet.' \
        "${action_stdout}" ||
        fail 'unclaimed-rewards rejection changed'
      ;;
    zero-balance)
      grep -Fq 'No funds are available in the wallet base address for the de-registration fee.' \
        "${action_stdout}" || fail 'zero-balance rejection changed'
      ;;
    unregistered)
      grep -Fq 'The selected wallet is not registered on chain.' \
        "${action_stdout}" || fail 'unregistered-wallet diagnostic changed'
      ;;
    query-fail)
      grep -Fq 'Wallet de-registration query failed; diagnostic output was suppressed.' \
        "${action_stdout}" || fail 'query-failure diagnostic changed'
      ;;
    existing-certificate)
      grep -Fq 'A stake de-registration certificate already exists for this wallet.' \
        "${action_stdout}" || fail 'existing-certificate diagnostic changed'
      ;;
    deregister-fail)
      grep -Fq 'Stake de-registration certificate creation failed; diagnostic output was suppressed.' \
        "${action_stdout}" || fail 'certificate-failure diagnostic changed'
      ! grep -Fq 'successfully de-registered on chain.' "${action_stdout}" ||
        fail 'certificate failure printed success'
      ;;
    verify-fail)
      grep -Fq 'WARN: de-registration was submitted, but confirmation is still pending.' \
        "${action_stdout}" || fail 'verification warning changed'
      grep -Fq 'fixture_wallet successfully de-registered on chain.' \
        "${action_stdout}" || fail 'verification failure lost committed success output'
      ;;
    word-splitting)
      ! grep -Fq 'word splitting' "${action_stdout}" "${stderr_file}" ||
        fail 'word-splitting wallet name was reflected'
      ;;
    control-name)
      ! grep -Fq 'RAW-CONTROL' "${action_stdout}" "${stderr_file}" ||
        fail 'control-character wallet name was reflected'
      ;;
    success|light-success)
      grep -Fq 'fixture_wallet successfully de-registered on chain.' \
        "${action_stdout}" || fail "${scenario} success output changed"
      grep -Fq 'Stake deposit returned: 2000000 lovelace' \
        "${action_stdout}" || fail "${scenario} refund output changed"
      ;;
  esac
  case "${scenario}" in
    rewards|zero-balance|unregistered)
      [[ "$(grep -c $'\tquery\tutxo\t' "${cli_log}" || true)" == 1 &&
         "$(grep -c $'\tquery\tstake-address-info\t' "${cli_log}" || true)" == 1 ]] ||
        fail "${scenario} bound query vectors changed"
      ! grep -Fq $'\ttransaction\tsubmit\t' "${cli_log}" ||
        fail "${scenario} submitted a transaction"
      ;;
    query-fail)
      [[ "$(grep -c $'\tquery\tutxo\t' "${cli_log}" || true)" == 1 ]] ||
        fail 'query-failure public vector changed'
      ! grep -Fq $'\tquery\tstake-address-info\t' "${cli_log}" ||
        fail 'failed UTxO query reached the stake query'
      ;;
    deregister-fail)
      [[ "$(grep -c $'\tstake-address\tderegistration-certificate\t' "${cli_log}" || true)" == 1 ]] ||
        fail 'certificate-failure command count changed'
      ! grep -Fq $'\ttransaction\tsubmit\t' "${cli_log}" ||
        fail 'certificate failure submitted a transaction'
      ;;
    success|verify-fail)
      [[ "$(grep -c $'\ttransaction\tsubmit\t' "${cli_log}" || true)" == 1 ]] ||
        fail "${scenario} local submit count changed"
      [[ "$(grep -c $'\ttransaction\ttxid\t' "${cli_log}" || true)" == 1 ]] ||
        fail "${scenario} transaction-id derivation count changed"
      ;;
    light-success)
      [[ "$(grep -c '/ogmios/$' "${curl_log}" || true)" == 1 &&
         "$(grep -c 'tx_status' "${curl_log}" || true)" == 1 ]] ||
        fail 'light public submit/confirmation vectors changed'
      ! grep -Fq $'\ttransaction\tsubmit\t' "${cli_log}" ||
        fail 'light public route used local submission'
      ;;
    *)
      [[ ! -s "${cli_log}" && ! -s "${curl_log}" ]] ||
        fail "${scenario} invoked transaction/query tools before selection completed"
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
  printf '%s\n' 'menu:main:w' 'menu:wallet:z' 'menu:wallet:h' 'menu:main:q' \
    > "${case_root}/expected-menu"
  grep '^menu:' "${event_log}" > "${case_root}/actual-menu"
  assert_files_equal "${case_root}/actual-menu" "${case_root}/expected-menu" \
    "${scenario} public navigation"
  tree_snapshot "${runtime_root}" "${after}" || fail "${scenario} post-snapshot failed"
  case "${scenario}" in
    success|light-success|verify-fail)
      assert_changed_paths "${before}" "${after}" "${scenario} public route" \
        'wallet/fixture_wallet/stake.dereg'
      assert_mode "${wallet_root}/fixture_wallet/stake.dereg" 600 \
        "${scenario} public certificate"
      ;;
    *) assert_changed_paths "${before}" "${after}" "${scenario} public route" ;;
  esac
  assert_out_of_scope_canary "${outside_canary}" "${scenario} public route"
)

PUBLIC_CASES=(
  empty op-cancel select-fail select-cancel none-registered encrypted
  missing-signing rewards zero-balance unregistered query-fail
  existing-certificate deregister-fail verify-fail success light-success
  word-splitting control-name
)

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
    address-build) printf 'local-registered\n' ;;
    query-select-*) printf 'local-registered\n' ;;
    symlink-wallet) printf 'local-registered\n' ;;
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
    CNTOOLS_WALLET_DEREGISTER_SCENARIO="${fake_scenario}"
    CNTOOLS_WALLET_DEREGISTER_RUNTIME="${runtime_root}"
    CNTOOLS_WALLET_DEREGISTER_CLI_LOG="${cli_log}"
    CNTOOLS_WALLET_DEREGISTER_CURL_LOG="${curl_log}"
    CNTOOLS_WALLET_DEREGISTER_JQ_LOG="${jq_log}"
    CNTOOLS_WALLET_DEREGISTER_JQ_COUNT="${jq_count}"
    CNTOOLS_WALLET_DEREGISTER_JQ_FAIL_CALL=0
    CNTOOLS_WALLET_DEREGISTER_JQ_MALICIOUS_ID=N
    CNTOOLS_WALLET_DEREGISTER_REAL_JQ="${REAL_JQ_PATH}"
    CNTOOLS_WALLET_DEREGISTER_RAW="${RAW_DIAGNOSTIC}"
    CNTOOLS_WALLET_DEREGISTER_BASE="${BASE_ADDR}"
    CNTOOLS_WALLET_DEREGISTER_PAY="${PAY_ADDR}"
    CNTOOLS_WALLET_DEREGISTER_REWARD="${REWARD_ADDR}"
    CNTOOLS_WALLET_DEREGISTER_TX_HASH="${TX_HASH}"
    CNTOOLS_WALLET_DEREGISTER_BLOCKED_LOG="${blocked_log}"
    export CNTOOLS_WALLET_DEREGISTER_SCENARIO CNTOOLS_WALLET_DEREGISTER_RUNTIME
    export CNTOOLS_WALLET_DEREGISTER_CLI_LOG CNTOOLS_WALLET_DEREGISTER_CURL_LOG
    export CNTOOLS_WALLET_DEREGISTER_JQ_LOG CNTOOLS_WALLET_DEREGISTER_JQ_COUNT
    export CNTOOLS_WALLET_DEREGISTER_JQ_FAIL_CALL CNTOOLS_WALLET_DEREGISTER_JQ_MALICIOUS_ID
    export CNTOOLS_WALLET_DEREGISTER_REAL_JQ CNTOOLS_WALLET_DEREGISTER_RAW
    export CNTOOLS_WALLET_DEREGISTER_BASE CNTOOLS_WALLET_DEREGISTER_PAY
    export CNTOOLS_WALLET_DEREGISTER_REWARD CNTOOLS_WALLET_DEREGISTER_TX_HASH
    export CNTOOLS_WALLET_DEREGISTER_BLOCKED_LOG
    legacy_selectWallet reg
  ) > "${stdout_file}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  case "${scenario}" in
    query-empty|local-unregistered|local-stake-query-fail|local-stake-malformed|\
      koios-unregistered|koios-reward-fail|koios-all-fail|symlink-wallet|\
      query-select-fail)
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
    query-empty|local-unregistered|local-stake-query-fail|local-stake-malformed|\
      koios-unregistered|koios-reward-fail|koios-all-fail|symlink-wallet)
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
        fail "${scenario} local de-registration query vector changed"
      ;;
  esac
  case "${scenario}" in
    local-stake-query-fail|local-stake-malformed|koios-reward-fail|koios-all-fail)
      [[ "${status}" == 1 ]] || fail "${scenario} legacy fail-closed selection changed"
      ;;
    local-utxo-fail|koios-balance-fail|koios-balance-malformed)
      [[ "${status}" == 0 ]] || fail "${scenario} registered-status fail-open changed"
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
  local-stake-malformed local-utxo-fail local-rewards light-registered
  koios-unregistered koios-rewards koios-balance-fail koios-balance-malformed
  koios-reward-fail koios-all-fail query-select-fail query-select-cancel
  address-build symlink-wallet
)
for scenario in "${QUERY_CASES[@]}"; do run_query_case "${scenario}"; done

versionCheck() {
  printf 'deregister:versionCheck:%s:%s\n' "${1:-}" "${2:-}" >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != protocol-8 ]]
}

validateMultiSigScript() {
  DEREGISTER_SCRIPT_CALL=$((DEREGISTER_SCRIPT_CALL + 1))
  printf 'deregister:validateMultiSigScript:%s:%s\n' \
    "${DEREGISTER_SCRIPT_CALL}" "${1:-}" >> "${EVENT_LOG:?}"
  if [[ "${DEREGISTER_SCRIPT_CALL}" == 1 ]]; then required_total=2; else required_total=3; fi
}

getTTL() {
  printf 'deregister:getTTL:%s\n' "${1:-}" >> "${EVENT_LOG:?}"
  ttl=200
  case "${SCENARIO:?}" in
    ttl-fail|cert-symlink|cert-hardlink|traversal-name|word-splitting-direct)
      return 1 ;;
  esac
  return 0
}

getAssetsTxOut() {
  printf 'deregister:getAssetsTxOut\n' >> "${EVENT_LOG:?}"
  assets_tx_out='+7 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.746f6b656e'
}

buildTx() {
  local explicit_output="${1:-}" output="" previous="" argument=""
  DEREGISTER_BUILD_CALL=$((DEREGISTER_BUILD_CALL + 1))
  printf 'deregister:buildTx:%s:%q\n' "${DEREGISTER_BUILD_CALL}" "${explicit_output}" \
    >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != build-draft-fail || "${DEREGISTER_BUILD_CALL}" != 1 ]] ||
    return 1
  [[ "${SCENARIO:-}" != build-final-fail || "${DEREGISTER_BUILD_CALL}" != 2 ]] ||
    return 1
  if [[ -n "${explicit_output}" ]]; then
    output="${explicit_output}"
  else
    for argument in "${build_args[@]}"; do
      [[ "${previous}" == --out-file ]] && output="${argument}"
      previous="${argument}"
    done
  fi
  [[ -n "${output}" ]] || fail 'de-registration build output was not supplied'
  printf '%s\n' '{"type":"TxBodyShelley","description":"fixture transaction body","cborHex":"84a40081825820aa"}' \
    > "${output}"
}

calcMinFee() {
  printf 'deregister:calcMinFee:%q:%s:%s:%s\n' \
    "${1:-}" "${2:-}" "${3:-}" "${4:-}" >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != fee-fail ]] || return 1
  if [[ "${SCENARIO:-}" == insufficient-fee ]]; then
    min_fee=3000000
  else
    min_fee=200000
  fi
}

getMinUTxO() {
  printf 'deregister:getMinUTxO:%q\n' "${1:-}" >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != min-utxo-fail ]] || return 1
  if [[ "${SCENARIO:-}" == insufficient-min-utxo ]]; then
    min_utxo_out=13000000
  else
    min_utxo_out=1000000
  fi
}

witnessTx() {
  printf 'deregister:witnessTx:%q:%q:%q\n' "${1:-}" "${2:-}" "${3:-}" \
    >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != witness-fail ]] || return 1
  printf '%s\n' '{"type":"TxWitnessShelley","description":"fixture witness"}' \
    > "${TMP_DIR}/tx.witness"
}

assembleTx() {
  printf 'deregister:assembleTx:%q\n' "${1:-}" >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != assemble-fail ]] || return 1
  tx_signed="${TMP_DIR}/tx.signed"
  printf '%s\n' '{"type":"Tx ConwayEra","description":"fixture signed transaction"}' \
    > "${tx_signed}"
}

submitTx() {
  printf 'deregister:submitTx:%q\n' "${1:-}" >> "${EVENT_LOG:?}"
  [[ "${SCENARIO:-}" != submit-fail ]]
}

verifyTx() {
  printf 'deregister:verifyTx:%q\n' "${1:-}" >> "${EVENT_LOG:?}"
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
    *) printf 'deregister-default\n' ;;
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
      ln -s -- "${runtime_root}/outside-cert" "${wallet_dir}/stake.dereg"
      ;;
    cert-hardlink)
      printf '%s\n' outside-original > "${runtime_root}/outside-cert"
      chmod 0640 "${runtime_root}/outside-cert"
      ln -- "${runtime_root}/outside-cert" "${wallet_dir}/stake.dereg"
      ;;
    cert-fifo)
      mkfifo "${wallet_dir}/stake.dereg"
      chmod 0640 "${wallet_dir}/stake.dereg"
      ;;
    malicious-offline-id)
      mkdir -p -- "${runtime_root}/tmp/offline_tx_x"
      ;;
  esac
}

expected_direct_status() {
  case "$1" in
    hybrid-success|multisig-hybrid|malicious-offline-id) printf '2\n' ;;
    online-success|online-hardware|light-online|protocol-8|malformed-cert) printf '0\n' ;;
    jq-fail-19|jq-fail-20) printf '2\n' ;;
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
    cert-hardlink) expected=('outside-cert' "${wallet_prefix}/stake.dereg") ;;
    traversal-name) expected=('outside-wallet/stake.dereg') ;;
    word-splitting-direct) expected=('wallet/word\ splitting/stake.dereg') ;;
    ttl-fail|build-draft-fail) expected=("${wallet_prefix}/stake.dereg") ;;
    fee-fail|insufficient-fee|min-utxo-fail|insufficient-min-utxo|build-final-fail)
      expected=("${wallet_prefix}/stake.dereg" 'tmp/tx0.tmp')
      ;;
    witness-fail)
      expected=("${wallet_prefix}/stake.dereg" 'tmp/tx0.tmp' 'tmp/tx.raw')
      ;;
    assemble-fail)
      expected=("${wallet_prefix}/stake.dereg" 'tmp/tx0.tmp' 'tmp/tx.raw' 'tmp/tx.witness')
      ;;
    submit-fail|online-success|online-hardware|light-online|protocol-8|malformed-cert)
      expected=("${wallet_prefix}/stake.dereg" 'tmp/tx0.tmp' 'tmp/tx.raw' \
        'tmp/tx.witness' 'tmp/tx.signed')
      ;;
    hybrid-success|multisig-hybrid)
      expected=("${wallet_prefix}/stake.dereg" 'tmp/tx0.tmp' 'tmp/tx.raw' "${offline_name}")
      ;;
    malicious-offline-id)
      expected=("${wallet_prefix}/stake.dereg" 'tmp/tx0.tmp' 'tmp/tx.raw' 'outside-id.json')
      ;;
    jq-fail-19)
      expected=("${wallet_prefix}/stake.dereg" 'tmp/tx0.tmp' 'tmp/tx.raw' 'tmp/offline_tx_.json')
      ;;
    jq-fail-20)
      expected=("${wallet_prefix}/stake.dereg" 'tmp/tx0.tmp' 'tmp/tx.raw' "${offline_name}")
      ;;
    jq-fail-*)
      expected=("${wallet_prefix}/stake.dereg" 'tmp/tx0.tmp' 'tmp/tx.raw')
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
    KEY_DEPOSIT=2000000; stake_deposit=2000000; DUMMYFEE=0; ttl=200; ttl_enter=300
    base_addr="${BASE_ADDR}"; pay_addr="${PAY_ADDR}"; reward_addr="${REWARD_ADDR}"
    if [[ "${scenario}" == insufficient-fee ]]; then base_lovelace=500000; else base_lovelace=10000000; fi
    min_fee=200000; min_utxo_out=1000000
    tx_in=' --tx-in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#0'
    utxo_cnt=1; reward_lovelace=123
    op_mode="${mode}"; DIRECT_WALLET_TYPE="${wallet_type}"
    DEREGISTER_BUILD_CALL=0; DEREGISTER_SCRIPT_CALL=0
    declare -A utxos_cnt=() tx_in_arr=() assets=()
    utxos_cnt["${BASE_ADDR}"]=1
    tx_in_arr["${BASE_ADDR}"]=' --tx-in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#0'
    assets[lovelace]=10000000
    WALLET_PAY_VK_FILENAME=payment.vkey; WALLET_PAY_SK_FILENAME=payment.skey
    WALLET_STAKE_VK_FILENAME=stake.vkey; WALLET_STAKE_SK_FILENAME=stake.skey
    WALLET_PAY_SCRIPT_FILENAME=payment.script; WALLET_STAKE_SCRIPT_FILENAME=stake.script
    WALLET_STAKE_DEREG_FILENAME=stake.dereg
    FG_RED="" FG_GREEN="" FG_YELLOW="" FG_LBLUE="" FG_LGRAY="" NC=""
    EVENT_LOG="${event_log}" SCENARIO="${scenario}"
    CNTOOLS_WALLET_DEREGISTER_SCENARIO="${fake_scenario}"
    CNTOOLS_WALLET_DEREGISTER_RUNTIME="${runtime_root}"
    CNTOOLS_WALLET_DEREGISTER_CLI_LOG="${cli_log}"
    CNTOOLS_WALLET_DEREGISTER_CURL_LOG="${curl_log}"
    CNTOOLS_WALLET_DEREGISTER_JQ_LOG="${jq_log}"
    CNTOOLS_WALLET_DEREGISTER_JQ_COUNT="${jq_count}"
    CNTOOLS_WALLET_DEREGISTER_JQ_FAIL_CALL="${jq_failure#0}"
    [[ -n "${CNTOOLS_WALLET_DEREGISTER_JQ_FAIL_CALL}" ]] || CNTOOLS_WALLET_DEREGISTER_JQ_FAIL_CALL=0
    if [[ "${scenario}" == malicious-offline-id ]]; then CNTOOLS_WALLET_DEREGISTER_JQ_MALICIOUS_ID=Y; else CNTOOLS_WALLET_DEREGISTER_JQ_MALICIOUS_ID=N; fi
    CNTOOLS_WALLET_DEREGISTER_REAL_JQ="${REAL_JQ_PATH}"
    CNTOOLS_WALLET_DEREGISTER_RAW="${RAW_DIAGNOSTIC}"
    CNTOOLS_WALLET_DEREGISTER_BASE="${BASE_ADDR}"
    CNTOOLS_WALLET_DEREGISTER_PAY="${PAY_ADDR}"
    CNTOOLS_WALLET_DEREGISTER_REWARD="${REWARD_ADDR}"
    CNTOOLS_WALLET_DEREGISTER_TX_HASH="${TX_HASH}"
    CNTOOLS_WALLET_DEREGISTER_BLOCKED_LOG="${blocked_log}"
    export CNTOOLS_WALLET_DEREGISTER_SCENARIO CNTOOLS_WALLET_DEREGISTER_RUNTIME
    export CNTOOLS_WALLET_DEREGISTER_CLI_LOG CNTOOLS_WALLET_DEREGISTER_CURL_LOG
    export CNTOOLS_WALLET_DEREGISTER_JQ_LOG CNTOOLS_WALLET_DEREGISTER_JQ_COUNT
    export CNTOOLS_WALLET_DEREGISTER_JQ_FAIL_CALL CNTOOLS_WALLET_DEREGISTER_JQ_MALICIOUS_ID
    export CNTOOLS_WALLET_DEREGISTER_REAL_JQ CNTOOLS_WALLET_DEREGISTER_RAW
    export CNTOOLS_WALLET_DEREGISTER_BASE CNTOOLS_WALLET_DEREGISTER_PAY
    export CNTOOLS_WALLET_DEREGISTER_REWARD CNTOOLS_WALLET_DEREGISTER_TX_HASH
    export CNTOOLS_WALLET_DEREGISTER_BLOCKED_LOG
    legacy_deregisterStakeWallet
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
    fail "${scenario} deregistration-certificate CLI count changed"
  grep -Fq $'cardano-cli\tlatest\tstake-address\tderegistration-certificate' \
    "${cli_log}" || fail "${scenario} certificate CLI vector changed"
  case "${scenario}" in
    protocol-8)
      ! grep -Fq -- '--key-reg-deposit-amt' "${cli_log}" ||
        fail 'protocol-8 certificate unexpectedly included deposit amount'
      ;;
    *)
      grep -Fq -- $'--key-reg-deposit-amt\t2000000' "${cli_log}" ||
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
        12|13) _expected_jq_count=13 ;;
        14|15) _expected_jq_count=15 ;;
        16|17) _expected_jq_count=17 ;;
        19|20) _expected_jq_count=20 ;;
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
      [[ "$(grep -c '^deregister:validateMultiSigScript:' "${event_log}" || true)" == 2 ]] ||
        fail 'multisig script-validation order changed'
      grep -Fq 'deregister:getTTL:true' "${event_log}" ||
        fail 'multisig TTL contract changed'
      ;;
  esac
  case "${scenario}" in
    online-success|hybrid-success)
      sed "s#${runtime_root}#<runtime>#g" "${event_log}" > "${case_root}/events.normalized"
      printf '%s\n' \
        'action:getWalletType:argc=1:name=fixture_wallet' \
        'deregister:versionCheck:9.0:9.0' \
        'deregister:getTTL:' \
        'deregister:getAssetsTxOut' \
        "deregister:buildTx:1:''" \
        'deregister:calcMinFee:<runtime>/tmp/tx0.tmp:1:1:2' \
        'deregister:getMinUTxO:addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq+11800000+7\ aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.746f6b656e' \
        "deregister:buildTx:2:''" \
        > "${case_root}/events.expected"
      if [[ "${scenario}" == online-success ]]; then
        printf '%s\n' \
          'deregister:witnessTx:<runtime>/tmp/tx.raw:<runtime>/wallet/fixture_wallet/stake.skey:<runtime>/wallet/fixture_wallet/payment.skey' \
          'deregister:assembleTx:<runtime>/tmp/tx.raw' \
          'deregister:submitTx:<runtime>/tmp/tx.signed' \
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
      assert_mode "${runtime_root}/outside-wallet/stake.dereg" 644 'traversal certificate'
      ;;
    word-splitting-direct)
      assert_mode "${wallet_root}/word splitting/stake.dereg" 644 'word-split certificate'
      ;;
    *)
      wallet_dir="${wallet_root}/${wallet_name}"
      assert_mode "${wallet_dir}/stake.dereg" 644 "${scenario} certificate"
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
      "${REAL_JQ_PATH}" -e '.type == "Wallet De-Registration" and
        ."wallet-name" == "fixture_wallet" and
        ."amount-returned" == "2000000" and .txFee == "200000" and
        (.txBody.type == "TxBodyShelley")' \
        "${runtime_root}/tmp/offline_tx_1700000000.json" >/dev/null ||
        fail "${scenario} offline transaction schema changed"
      ;;
    jq-fail-19)
      "${REAL_JQ_PATH}" -e '.type == "Wallet De-Registration" and
        ."wallet-name" == "fixture_wallet"' \
        "${runtime_root}/tmp/offline_tx_.json" >/dev/null ||
        fail 'jq id failure residue schema changed'
      ;;
    jq-fail-20)
      [[ ! -s "${runtime_root}/tmp/offline_tx_1700000000.json" ]] ||
        fail 'jq final-write failure no longer leaves an empty offline file'
      ;;
    malformed-cert)
      ! "${REAL_JQ_PATH}" -e . "${wallet_root}/fixture_wallet/stake.dereg" \
        >/dev/null 2>&1 || fail 'malformed certificate is no longer accepted unchecked'
      ;;
    cert-symlink)
      [[ -L "${wallet_root}/fixture_wallet/stake.dereg" ]] ||
        fail 'certificate symlink was replaced instead of followed'
      grep -Fq 'StakeAddressDeregistrationCertificate' "${runtime_root}/outside-cert" ||
        fail 'certificate symlink no longer mutated its outside target'
      ;;
    cert-hardlink)
      [[ "${wallet_root}/fixture_wallet/stake.dereg" -ef "${runtime_root}/outside-cert" ]] ||
        fail 'certificate hardlink identity changed'
      ;;
    cert-fifo)
      [[ -p "${wallet_root}/fixture_wallet/stake.dereg" ]] ||
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
  online-success online-hardware light-online protocol-8 hybrid-success
  multisig-hybrid cert-fail raw-diagnostic ttl-fail build-draft-fail fee-fail
  insufficient-fee min-utxo-fail insufficient-min-utxo build-final-fail
  witness-fail assemble-fail submit-fail malformed-cert
  cert-symlink cert-hardlink cert-fifo traversal-name word-splitting-direct
  malicious-offline-id
)
for scenario in "${DIRECT_CASES[@]}"; do run_direct_case "${scenario}"; done

JQ_FAILURE_CASES=()
for ((jq_index=1; jq_index<=20; jq_index++)); do
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

# Keep the historical 84-case matrix above frozen.  The cases below source
# only the extracted action and exercise its hardened transaction boundary.
write_hardened_ccli() {
  local target="${TEST_ROOT}/hardened-cardano-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_DEREGISTER_HARDENED_SCENARIO:?}"' \
    'log="${CNTOOLS_WALLET_DEREGISTER_HARDENED_CLI_LOG:?}"' \
    'base="${CNTOOLS_WALLET_DEREGISTER_HARDENED_BASE:?}"' \
    'reward="${CNTOOLS_WALLET_DEREGISTER_HARDENED_REWARD:?}"' \
    'hash="${CNTOOLS_WALLET_DEREGISTER_HARDENED_HASH:?}"' \
    'previous=""; out_file=""; argument=""' \
    'emit() { local target="$1" fd=""; shift; if [[ "${target}" == /dev/fd/[0-9]* ]]; then fd="${target##*/}"; printf "$@" 1>&"${fd}"; else printf "$@" > "${target}"; fi; }' \
    'printf '\''cardano-cli'\'' >> "${log}"' \
    'for argument in "$@"; do' \
    '  printf '\''\t%q'\'' "${argument}" >> "${log}"' \
    '  [[ "${previous}" == --out-file ]] && out_file="${argument}"' \
    '  previous="${argument}"' \
    'done' \
    'printf '\''\n'\'' >> "${log}"' \
    'case "$*" in' \
    '  *"query utxo"*)' \
    '    [[ "${scenario}" != query-fail ]] || { printf '\''%s\n'\'' "${CNTOOLS_WALLET_DEREGISTER_HARDENED_RAW:?}" >&2; exit 31; }' \
    '    if [[ "$*" == *"--tx-in"* && "${scenario}" == verify-fail ]]; then emit "${out_file}" '\''{}\n'\''' \
    '    elif [[ "${scenario}" == malformed-query ]]; then emit "${out_file}" '\''not-json\n'\''' \
    '    elif [[ "${scenario}" == zero-balance ]]; then emit "${out_file}" '\''{}\n'\''' \
    '    else emit "${out_file}" '\''{"%s#0":{"address":"%s","value":{"lovelace":10000000}}}\n'\'' "${hash}" "${base}"; fi' \
    '    [[ "${scenario}" != tool-replaced ]] || printf '\''# replaced after invocation\n'\'' >> "$0"' \
    '    ;;' \
    '  *"query stake-address-info"*)' \
    '    if [[ "${scenario}" == unregistered ]]; then emit "${out_file}" '\''[]\n'\''' \
    '    elif [[ "${scenario}" == rewards ]]; then emit "${out_file}" '\''[{"address":"%s","rewardAccountBalance":1,"stakeRegistrationDeposit":2000000}]\n'\'' "${reward}"' \
    '    else emit "${out_file}" '\''[{"address":"%s","rewardAccountBalance":0,"stakeRegistrationDeposit":2000000}]\n'\'' "${reward}"; fi' \
    '    ;;' \
    '  *"stake-address deregistration-certificate"*)' \
    '    case "${scenario}" in certificate-fail|rm-created-error|rm-persistent|signal-wait-precommit) printf '\''%s\n'\'' "${CNTOOLS_WALLET_DEREGISTER_HARDENED_RAW:?}" >&2; exit 32 ;; esac' \
    '    [[ "${scenario}" != signal-precommit ]] || kill -TERM "${PPID}"' \
    '    emit "${out_file}" '\''{"cborHex":"aabbccdd","description":"fixture","type":"StakeAddressDeregistrationCertificate"}\n'\''' \
    '    ;;' \
    '  *"transaction build-raw"*) emit "${out_file}" '\''{"cborHex":"aabbccdd","description":"fixture","type":"TxBody ConwayEra"}\n'\'' ;;' \
    '  *"transaction calculate-min-fee"*) printf '\''200000 Lovelace\n'\'' ;;' \
    '  *"transaction calculate-min-required-utxo"*) printf '\''1000000 Lovelace\n'\'' ;;' \
    '  *"transaction witness"*) emit "${out_file}" '\''{"cborHex":"aabb","description":"fixture","type":"TxWitness ConwayEra"}\n'\'' ;;' \
    '  *"transaction assemble"*) emit "${out_file}" '\''{"cborHex":"aabb","description":"fixture","type":"Signed Tx"}\n'\'' ;;' \
    '  *"transaction txid"*)' \
    '    [[ "${scenario}" != txid-fail ]] || { printf '\''%s\n'\'' "${CNTOOLS_WALLET_DEREGISTER_HARDENED_RAW:?}" >&2; exit 34; }' \
    '    if [[ "${scenario}" == txid-malformed ]]; then printf '\''not-a-transaction-id\n'\''' \
    '    else printf '\''%s\n'\'' "${hash}"; fi' \
    '    ;;' \
    '  *"transaction submit"*)' \
    '    [[ "${scenario}" != signal-submit ]] || kill -TERM "${PPID}"' \
    '    [[ "${scenario}" != submit-fail ]]' \
    '    ;;' \
    '  *) printf '\''unexpected hardened cardano-cli vector: %s\n'\'' "$*" >&2; exit 96 ;;' \
    'esac' \
    > "${target}"
  chmod 0755 "${target}"
  printf '%s\n' "${target}"
}

HARDENED_CCLI="$(write_hardened_ccli)"

write_hardened_hwcli() {
  local target="${TEST_ROOT}/hardened-cardano-hw-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_DEREGISTER_HARDENED_SCENARIO:?}"' \
    'log="${CNTOOLS_WALLET_DEREGISTER_HARDENED_HW_LOG:?}"' \
    'previous=""; argument=""; fd=""; out_files=()' \
    'emit() { local target="$1" descriptor=""; shift; if [[ "${target}" == /dev/fd/[0-9]* ]]; then descriptor="${target##*/}"; printf "$@" 1>&"${descriptor}"; else printf "$@" > "${target}"; fi; }' \
    'printf '\''cardano-hw-cli'\'' >> "${log}"' \
    'for argument in "$@"; do' \
    '  printf '\''\t%q'\'' "${argument}" >> "${log}"' \
    '  [[ "${previous}" != --out-file ]] || out_files+=("${argument}")' \
    '  previous="${argument}"' \
    'done' \
    'printf '\''\n'\'' >> "${log}"' \
    'case "$*" in' \
    '  "transaction transform "*)' \
    '    [[ "${scenario}" != hardware-transform-fail ]] || { printf '\''%s\n'\'' "${CNTOOLS_WALLET_DEREGISTER_HARDENED_RAW:?}" >&2; exit 41; }' \
    '    [[ "${#out_files[@]}" == 1 ]] || exit 96' \
    '    emit "${out_files[0]}" '\''{"cborHex":"aabbccdd","description":"hardware fixture","type":"TxBody ConwayEra"}\n'\''' \
    '    ;;' \
    '  "transaction witness "*)' \
    '    [[ "${scenario}" != hardware-witness-fail ]] || { printf '\''%s\n'\'' "${CNTOOLS_WALLET_DEREGISTER_HARDENED_RAW:?}" >&2; exit 42; }' \
    '    [[ "${#out_files[@]}" == 2 ]] || exit 96' \
    '    emit "${out_files[0]}" '\''{"cborHex":"aabb","description":"hardware fixture","type":"TxWitness ConwayEra"}\n'\''' \
    '    emit "${out_files[1]}" '\''{"cborHex":"ccdd","description":"hardware fixture","type":"TxWitness ConwayEra"}\n'\''' \
    '    ;;' \
    '  *) exit 96 ;;' \
    'esac' > "${target}"
  chmod 0755 "${target}"
  printf '%s\n' "${target}"
}

HARDENED_HWCLI="$(write_hardened_hwcli)"

write_hardened_curl() {
  local target="$1"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_DEREGISTER_HARDENED_SCENARIO:?}"' \
    'log="${CNTOOLS_WALLET_DEREGISTER_HARDENED_CURL_LOG:?}"' \
    'base="${CNTOOLS_WALLET_DEREGISTER_HARDENED_BASE:?}"' \
    'reward="${CNTOOLS_WALLET_DEREGISTER_HARDENED_REWARD:?}"' \
    'hash="${CNTOOLS_WALLET_DEREGISTER_HARDENED_HASH:?}"' \
    'previous=""; argument=""; output=""; url=""; descriptor="" config="" data="" payload="" config_value="" metadata=""' \
    'for argument in "$@"; do' \
    '  [[ "${previous}" != --config ]] || config="${argument}"' \
    '  [[ "${previous}" != --data-binary ]] || data="${argument}"' \
    '  [[ "${previous}" != --output ]] || output="${argument}"' \
    '  [[ "${previous}" != --url ]] || url="${argument}"' \
    '  previous="${argument}"' \
    'done' \
    'printf '\''curl\t%s\n'\'' "${url}" >> "${log}"' \
    '[[ "${scenario}" != light-query-fail ]] || { printf '\''%s\n'\'' "${CNTOOLS_WALLET_DEREGISTER_HARDENED_RAW:?}" >&2; exit 51; }' \
    '[[ "${config}" == /dev/fd/[0-9]* && "${data}" == @/dev/fd/[0-9]* && "${output}" == /dev/fd/[0-9]* ]] || exit 96' \
    'config_value="$(< "${config}")"' \
    '[[ "${config_value}" == '\''header = "authorization: LIGHT_QUERY_SECRET_DO_NOT_EXPOSE"'\'' ]] || exit 96' \
    'metadata="$(stat -f '\''%Lp:%l'\'' "${config}" 2>/dev/null || stat -c '\''%a:%h'\'' -- "${config}" 2>/dev/null)"' \
    '[[ "${metadata}" == 600:1 ]] || exit 96' \
    'payload="$(< "${data#@}")"' \
    'descriptor="${output##*/}"' \
    'case "${url}" in' \
    '  *address_utxos*)' \
    '    [[ "${payload}" == "{\"_addresses\":[\"${base}\"]}" ]] || exit 96' \
    '    if [[ "${scenario}" == light-malformed ]]; then printf '\''not-json\n'\'' 1>&"${descriptor}"' \
    '    else printf '\''[{"address":"%s","tx_hash":"%s","tx_index":0,"value":10000000,"asset_list":[]}]\n'\'' "${base}" "${hash}" 1>&"${descriptor}"; fi' \
    '    ;;' \
    '  *account_info*)' \
    '    [[ "${payload}" == "{\"_stake_addresses\":[\"${reward}\"]}" ]] || exit 96' \
    '    printf '\''[{"stake_address":"%s","status":"registered","delegated_pool":null,"delegated_drep":null,"rewards_available":0,"deposit":2000000}]\n'\'' "${reward}" 1>&"${descriptor}"' \
    '    ;;' \
    '  */ogmios/)' \
    '    [[ "${payload}" == '\''{"jsonrpc":"2.0","method":"submitTransaction","params":{"transaction":{"cbor":"aabb"}}}'\'' ]] || exit 96' \
    '    case "${scenario}" in' \
    '      light-submit-fail) printf '\''%s\n'\'' "${CNTOOLS_WALLET_DEREGISTER_HARDENED_RAW:?}" >&2; exit 52 ;;' \
    '      light-submit-lost) exit 0 ;;' \
    '      light-signal-submit) kill -TERM "${PPID}" ;;' \
    '    esac' \
    '    printf '\''{"jsonrpc":"2.0","result":{"transaction":{"id":"%s"}}}\n'\'' "${hash}" 1>&"${descriptor}"' \
    '    ;;' \
    '  *tx_status*)' \
    '    [[ "${payload}" == "{\"_tx_hashes\":[\"${hash}\"]}" ]] || exit 96' \
    '    if [[ "${scenario}" == light-verify-fail ]]; then printf '\''[]\n'\'' 1>&"${descriptor}"' \
    '    else printf '\''[{"tx_hash":"%s","num_confirmations":1}]\n'\'' "${hash}" 1>&"${descriptor}"; fi' \
    '    ;;' \
    '  *) exit 96 ;;' \
    'esac' > "${target}/curl"
  chmod 0755 "${target}/curl"
}

write_hardened_fault_command() {
  local target="$1" command_kind="$2" behavior="$3"

  case "${behavior}" in
    created-error)
      printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -u' \
        'case "${0##*/}" in' \
        '  mkdir) "${CNTOOLS_WALLET_DEREGISTER_REAL_MKDIR:?}" "$@" ;;' \
        '  rm) "${CNTOOLS_WALLET_DEREGISTER_REAL_RM:?}" "$@" ;;' \
        '  rmdir) "${CNTOOLS_WALLET_DEREGISTER_REAL_RMDIR:?}" "$@" ;;' \
        '  ln) "${CNTOOLS_WALLET_DEREGISTER_REAL_LN:?}" "$@" ;;' \
        '  *) exit 96 ;;' \
        'esac' \
        'exit 1' > "${target}/${command_kind}"
      ;;
    persistent)
      printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "${target}/${command_kind}"
      ;;
    foreign-symlink)
      printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -u' \
        'destination="${@: -1}"' \
        '"${CNTOOLS_WALLET_DEREGISTER_REAL_LN:?}" -s -- "${CNTOOLS_WALLET_DEREGISTER_FOREIGN_TARGET:?}" "${destination}"' \
        'exit 1' > "${target}/${command_kind}"
      ;;
    first-success)
      printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -u' \
        'state="${CNTOOLS_WALLET_DEREGISTER_FAULT_STATE:?}"' \
        '[[ ! -e "${state}" ]] || exit 1' \
        'printf '\''seen\n'\'' > "${state}"' \
        '"${CNTOOLS_WALLET_DEREGISTER_REAL_LN:?}" "$@"' > "${target}/${command_kind}"
      ;;
    *) fail "unknown hardened fault-command behavior: ${behavior}" ;;
  esac
  chmod 0755 "${target}/${command_kind}"
}

# Reinstall the controller menu adapter after the inherited operation-mode
# oracle above replaced select_opt, then exercise the now-bound public route.
select_opt() { bound_public_select_opt "$@"; }
for scenario in "${PUBLIC_CASES[@]}"; do run_public_case "${scenario}"; done

run_hardened_action_case() (
  local scenario="$1" expected_status="$2" case_root="" runtime_root=""
  local wallet_root="" wallet_dir="" tmp_root="" private_root=""
  local context_file="" result_file="" stdout_file="" stderr_file=""
  local cli_log="" hw_log="" event_log="" status=0 lock_path="" argument=""
  local fault_bin="" expected_wait=1 expected_lock=N expected_certificate=N
  local expected_links=1 outside_file="" outside_before="" retry_status=""
  local selected_mode=online context_mode_value=local
  local context_capabilities='["local-cli"]' curl_log=""
  local case_ccli="${HARDENED_CCLI}" retry_before="" retry_after=""
  local retry_stdout="" retry_stderr="" retry_event_log="" expected_retry_status=""
  local ambient_log="" ambient_before="" artifact="" artifact_hash=""
  local txid_line="" submit_line=""
  local hardened_fd_before="" hardened_fd_after="" repeat_index=0
  local repeat_status=0 repeat_expected_status=0 repeat_stdout="" repeat_stderr=""

  case_root="${TEST_ROOT}/hardened/${scenario}"
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
  hw_log="${case_root}/hw.log"
  curl_log="${case_root}/curl.log"
  event_log="${case_root}/events"
  ambient_log="${case_root}/ambient-cntools.log"
  fault_bin="${case_root}/fault-bin"
  mkdir -p "${wallet_dir}" "${tmp_root}" "${private_root}"
  chmod 0700 "${wallet_root}" "${wallet_dir}" "${tmp_root}" "${private_root}"
  : > "${cli_log}"
  : > "${hw_log}"
  : > "${curl_log}"
  : > "${event_log}"
  printf '%s\n' 'AMBIENT_CNTOOLS_LOG_CANARY_DO_NOT_MUTATE' > "${ambient_log}"
  ambient_before="$(file_hash "${ambient_log}")"
  printf '%s\n' "${BASE_ADDR}" > "${wallet_dir}/base.addr"
  printf '%s\n' "${PAY_ADDR}" > "${wallet_dir}/payment.addr"
  printf '%s\n' "${REWARD_ADDR}" > "${wallet_dir}/stake.addr"
  printf '%s\n' '{"type":"PaymentVerificationKeyShelley_ed25519","description":"fixture","cborHex":"aabb"}' > "${wallet_dir}/payment.vkey"
  printf '%s\n' '{"type":"StakeVerificationKeyShelley_ed25519","description":"fixture","cborHex":"aabb"}' > "${wallet_dir}/stake.vkey"
  printf '%s\n' "{\"type\":\"PaymentSigningKeyShelley_ed25519\",\"description\":\"fixture\",\"cborHex\":\"${SIGNING_SECRET}\"}" > "${wallet_dir}/payment.skey"
  printf '%s\n' "{\"type\":\"StakeSigningKeyShelley_ed25519\",\"description\":\"fixture\",\"cborHex\":\"${SIGNING_SECRET}\"}" > "${wallet_dir}/stake.skey"
  printf '%s\n' "{\"type\":\"HardwarePaymentSigningFile\",\"description\":\"fixture\",\"path\":\"${SIGNING_SECRET}\"}" > "${wallet_dir}/payment.hw.skey"
  printf '%s\n' "{\"type\":\"HardwareStakeSigningFile\",\"description\":\"fixture\",\"path\":\"${SIGNING_SECRET}\"}" > "${wallet_dir}/stake.hw.skey"
  printf '%s\n' '{"type":"all","scripts":[{"type":"sig","keyHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}' > "${wallet_dir}/payment.script"
  printf '%s\n' '{"type":"all","scripts":[{"type":"sig","keyHash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}' > "${wallet_dir}/stake.script"
  printf '%s\n' '{}' > "${tmp_root}/protparams.json"
  chmod 0600 "${wallet_dir}"/* "${tmp_root}/protparams.json"
  case "${scenario}" in
    cert-symlink|cert-hardlink)
      outside_file="${runtime_root}/outside-cert"
      printf '%s\n' 'outside-certificate-sentinel' > "${outside_file}"
      chmod 0640 "${outside_file}"
      if [[ "${scenario}" == cert-symlink ]]; then
        ln -s -- "${outside_file}" "${wallet_dir}/stake.dereg"
      else
        ln -- "${outside_file}" "${wallet_dir}/stake.dereg"
      fi
      outside_before="$(stat -f '%u:%Lp:%l:%z:%d:%i' "${outside_file}" 2>/dev/null ||
        stat -c '%u:%a:%h:%s:%d:%i' -- "${outside_file}")|$(< "${outside_file}")"
      ;;
    cert-fifo)
      mkfifo "${wallet_dir}/stake.dereg"
      chmod 0640 "${wallet_dir}/stake.dereg"
      ;;
    base-symlink|base-hardlink)
      outside_file="${runtime_root}/outside-base"
      printf '%s\n' "${BASE_ADDR}" > "${outside_file}"
      chmod 0640 "${outside_file}"
      rm -- "${wallet_dir}/base.addr"
      if [[ "${scenario}" == base-symlink ]]; then
        ln -s -- "${outside_file}" "${wallet_dir}/base.addr"
      else
        ln -- "${outside_file}" "${wallet_dir}/base.addr"
      fi
      outside_before="$(stat -f '%u:%Lp:%l:%z:%d:%i' "${outside_file}" 2>/dev/null ||
        stat -c '%u:%a:%h:%s:%d:%i' -- "${outside_file}")|$(< "${outside_file}")"
      ;;
    base-fifo)
      rm -- "${wallet_dir}/base.addr"
      mkfifo "${wallet_dir}/base.addr"
      chmod 0640 "${wallet_dir}/base.addr"
      ;;
    result-symlink|result-hardlink)
      outside_file="${runtime_root}/outside-result"
      printf '%s\n' 'outside-result-sentinel' > "${outside_file}"
      chmod 0440 "${outside_file}"
      if [[ "${scenario}" == result-symlink ]]; then
        ln -s -- "${outside_file}" "${result_file}"
      else
        ln -- "${outside_file}" "${result_file}"
      fi
      outside_before="$(stat -f '%u:%Lp:%l:%z:%d:%i' "${outside_file}" 2>/dev/null ||
        stat -c '%u:%a:%h:%s:%d:%i' -- "${outside_file}")|$(< "${outside_file}")"
      ;;
    result-fifo)
      mkfifo "${result_file}"
      chmod 0440 "${result_file}"
      ;;
    signing-mode)
      chmod 0640 "${wallet_dir}/payment.skey"
      ;;
    ln-foreign-symlink)
      outside_file="${runtime_root}/outside-publication"
      printf '%s\n' 'outside-publication-sentinel' > "${outside_file}"
      chmod 0440 "${outside_file}"
      outside_before="$(stat -f '%u:%Lp:%l:%z:%d:%i' "${outside_file}" 2>/dev/null ||
        stat -c '%u:%a:%h:%s:%d:%i' -- "${outside_file}")|$(< "${outside_file}")"
      ;;
    existing-certificate)
      printf '%s\n' '{"cborHex":"aabbccdd","description":"existing fixture","type":"StakeAddressDeregistrationCertificate"}' > "${wallet_dir}/stake.dereg"
      chmod 0600 "${wallet_dir}/stake.dereg"
      ;;
  esac
  case "${scenario}" in
    light-*) context_mode_value=light; context_capabilities='[]' ;;
  esac
  "${REAL_JQ_PATH}" -nS --arg mode "${context_mode_value}" \
    --argjson capabilities "${context_capabilities}" '{
    advanced:false,apiVersion:1,capabilities:$capabilities,features:[],
    generationVersion:"1.0.0",mode:$mode,nodeHome:"/node",
    nodeImplementation:"cnode",nodeNetwork:"preview",schemaVersion:1
  }' > "${context_file}"
  chmod 0600 "${context_file}"

  mkdir -p "${fault_bin}"
  case "${scenario}" in
    mkdir-created-error) write_hardened_fault_command "${fault_bin}" mkdir created-error ;;
    rm-created-error) write_hardened_fault_command "${fault_bin}" rm created-error ;;
    rm-persistent) write_hardened_fault_command "${fault_bin}" rm persistent ;;
    rmdir-created-error) write_hardened_fault_command "${fault_bin}" rmdir created-error ;;
    rmdir-persistent) write_hardened_fault_command "${fault_bin}" rmdir persistent ;;
    ln-created-error) write_hardened_fault_command "${fault_bin}" ln created-error ;;
    ln-persistent) write_hardened_fault_command "${fault_bin}" ln persistent ;;
    ln-foreign-symlink) write_hardened_fault_command "${fault_bin}" ln foreign-symlink ;;
    publication-rm-persistent)
      write_hardened_fault_command "${fault_bin}" ln first-success
      write_hardened_fault_command "${fault_bin}" rm persistent
      ;;
  esac
  [[ "${context_mode_value}" != light ]] || write_hardened_curl "${fault_bin}"
  if [[ "${scenario}" == tool-replaced ]]; then
    case_ccli="${case_root}/hardened-cardano-cli"
    cp -- "${HARDENED_CCLI}" "${case_ccli}"
    chmod 0755 "${case_ccli}"
  fi
  PATH="${fault_bin}:${BASE_PATH}"; export PATH
  CNTOOLS_WALLET_DEREGISTER_REAL_RM="${REAL_RM_PATH}"
  CNTOOLS_WALLET_DEREGISTER_REAL_MKDIR="${REAL_MKDIR_PATH}"
  CNTOOLS_WALLET_DEREGISTER_REAL_RMDIR="${REAL_RMDIR_PATH}"
  CNTOOLS_WALLET_DEREGISTER_REAL_LN="${REAL_LN_PATH}"
  CNTOOLS_WALLET_DEREGISTER_FOREIGN_TARGET="${outside_file:-}"
  CNTOOLS_WALLET_DEREGISTER_FAULT_STATE="${fault_bin}/ln.state"
  export CNTOOLS_WALLET_DEREGISTER_REAL_RM
  export CNTOOLS_WALLET_DEREGISTER_REAL_MKDIR
  export CNTOOLS_WALLET_DEREGISTER_REAL_RMDIR
  export CNTOOLS_WALLET_DEREGISTER_REAL_LN
  export CNTOOLS_WALLET_DEREGISTER_FOREIGN_TARGET
  export CNTOOLS_WALLET_DEREGISTER_FAULT_STATE
  CNTOOLS_MODE="${context_mode_value^^}"
  NETWORK_IDENTIFIER='--testnet-magic 42'
  WALLET_FOLDER="${wallet_root}"
  TMP_DIR="${tmp_root}"
  CCLI="${case_ccli}"
  HWCLI="${HARDENED_HWCLI}"
  DUMMYFEE=0
  PROT_VERSION=9.0
  if [[ "${context_mode_value}" == light ]]; then
    KOIOS_API='https://fixture.koios.invalid/api/v1'
    KOIOS_API_HEADERS=(-H 'authorization: LIGHT_QUERY_SECRET_DO_NOT_EXPOSE')
  else
    KOIOS_API=
    KOIOS_API_HEADERS=()
  fi
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
  WALLET_STAKE_DEREG_FILENAME=stake.dereg
  CNTOOLS_WALLET_DEREGISTER_HARDENED_SCENARIO="${scenario}"
  CNTOOLS_WALLET_DEREGISTER_HARDENED_CLI_LOG="${cli_log}"
  CNTOOLS_WALLET_DEREGISTER_HARDENED_HW_LOG="${hw_log}"
  CNTOOLS_WALLET_DEREGISTER_HARDENED_CURL_LOG="${curl_log}"
  CNTOOLS_WALLET_DEREGISTER_HARDENED_BASE="${BASE_ADDR}"
  CNTOOLS_WALLET_DEREGISTER_HARDENED_REWARD="${REWARD_ADDR}"
  CNTOOLS_WALLET_DEREGISTER_HARDENED_HASH="${TX_HASH}"
  CNTOOLS_WALLET_DEREGISTER_HARDENED_RAW="${RAW_DIAGNOSTIC}"
  CNTOOLS_LOG="${ambient_log}"
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_SCENARIO
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_CLI_LOG
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_HW_LOG
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_CURL_LOG
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_BASE
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_REWARD
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_HASH
  export CNTOOLS_WALLET_DEREGISTER_HARDENED_RAW
  export CNTOOLS_LOG

  clear() { :; }
  println() {
    printf 'println:%s\n' "$*" >> "${event_log}"
    case "${scenario}" in
      signal-local-presubmit)
        [[ "$*" != *'wallet-deregister transaction submission'* ]] ||
          kill -TERM "${BASHPID}"
        ;;
      light-signal-presubmit)
        [[ "$*" != *'wallet-deregister submit attempt'* ]] ||
          kill -TERM "${BASHPID}"
        ;;
    esac
  }
  waitToProceed() {
    printf 'wait\n' >> "${event_log}"
    [[ "${scenario}" != signal-wait &&
       "${scenario}" != signal-wait-precommit ]] || kill -TERM "${BASHPID}"
  }
  case "${scenario}" in
    hybrid-success|publication-rm-persistent) selected_mode=hybrid ;;
  esac
  selectOpMode() {
    [[ "${scenario}" != operation-cancel ]] || return 1
    op_mode="${selected_mode}"
    return 0
  }
  selectWallet() {
    [[ "${1:-}" == reg ]] || return 70
    case "${scenario}" in
      wallet-none) return 1 ;;
      wallet-cancel) return 2 ;;
    esac
    wallet_name=fixture_wallet
  }
  getWalletType() {
    payment_vk_file="${wallet_dir}/payment.vkey"
    stake_vk_file="${wallet_dir}/stake.vkey"
    payment_script_file="${wallet_dir}/payment.script"
    stake_script_file="${wallet_dir}/stake.script"
    case "${scenario}" in
      hardware-*)
        payment_sk_file="${wallet_dir}/payment.hw.skey"
        stake_sk_file="${wallet_dir}/stake.hw.skey"
        return 0
        ;;
      multisig-*)
        payment_sk_file="${wallet_dir}/payment.skey"
        stake_sk_file="${wallet_dir}/stake.skey"
        return 5
        ;;
      wallet-encrypted) return 2 ;;
      wallet-missing) return 3 ;;
      *)
        payment_sk_file="${wallet_dir}/payment.skey"
        stake_sk_file="${wallet_dir}/stake.skey"
        return 1
        ;;
    esac
  }
  unlockHWDevice() {
    printf 'unlock:%s\n' "$1" >> "${event_log}"
    [[ "${scenario}" != hardware-unlock-fail ]]
  }
  validateMultiSigScript() {
    [[ "${scenario}" != multisig-invalid ]] || return 1
    required_total=1
    return 0
  }
  getTTL() { ttl=1000000; return 0; }
  versionCheck() { return 0; }
  submitTx() { printf 'submitTx:%s\n' "$1" >> "${event_log}"; return 0; }
  verifyTx() { printf 'verifyTx:%s\n' "$1" >> "${event_log}"; return 0; }

  # shellcheck source=/dev/null
  . "${REGISTRY_SOURCE}"
  # shellcheck source=/dev/null
  . "${CONTEXT_SOURCE}"
  # shellcheck source=/dev/null
  . "${RESULT_SOURCE}"
  # shellcheck source=/dev/null
  . "${ACTION_SOURCE}"
  fd_inventory_into hardened_fd_before ||
    fail "${scenario} pre-action descriptor inventory failed"
  set +e
  tx_id='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  if [[ "${scenario}" == xtrace-success ]]; then
    {
      set -x
      cntools_action_main "${context_file}" "${result_file}"
      status=$?
      set +x
    } > "${stdout_file}" 2> "${stderr_file}"
  else
    cntools_action_main "${context_file}" "${result_file}" \
      > "${stdout_file}" 2> "${stderr_file}"
    status=$?
  fi
  set -e
  fd_inventory_into hardened_fd_after ||
    fail "${scenario} post-action descriptor inventory failed"
  [[ "${hardened_fd_after}" == "${hardened_fd_before}" ]] ||
    fail "${scenario} leaked authenticated descriptors (${hardened_fd_before} -> ${hardened_fd_after})"
  [[ "${status}" == "${expected_status}" ]] ||
    fail "${scenario} hardened status ${status}, expected ${expected_status}"
  [[ "$(file_hash "${ambient_log}")" == "${ambient_before}" ]] ||
    fail "${scenario} mutated the hostile ambient CNTOOLS_LOG target"
  ! grep -Fq 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    "${stdout_file}" "${stderr_file}" "${event_log}" "${cli_log}" "${curl_log}" ||
    fail "${scenario} consumed a hostile ambient transaction identifier"
  ! grep -Eq '(^|:)submitTx:|(^|:)verifyTx:' "${event_log}" ||
    fail "${scenario} invoked an inherited submit or verification helper"
  lock_path="${wallet_root}/.fixture_wallet.cntools-wallet-deregister.lock"
  case "${scenario}" in
    submit-fail|signal-submit|light-submit-fail|light-submit-lost|light-signal-submit|rm-persistent|rmdir-persistent|ln-foreign-symlink|publication-rm-persistent|tool-replaced)
      expected_lock=Y
      ;;
  esac
  if [[ "${expected_lock}" == Y ]]; then
    [[ -d "${lock_path}" && ! -L "${lock_path}" &&
       -d "${lock_path}/stage" && ! -L "${lock_path}/stage" ]] ||
      fail "${scenario} did not retain exact lock/stage authority"
    assert_mode "${lock_path}" 700 "${scenario} retained lock"
    assert_mode "${lock_path}/stage" 700 "${scenario} retained stage"
  else
    [[ ! -e "${lock_path}" && ! -L "${lock_path}" ]] ||
      fail "${scenario} left its private lock/stage tree"
  fi
  case "${scenario}" in
    result-symlink)
      [[ -L "${result_file}" ]] || fail 'result symlink identity changed'
      ;;
    result-hardlink)
      [[ "${result_file}" -ef "${outside_file}" ]] ||
        fail 'result hardlink identity changed'
      ;;
    result-fifo)
      [[ -p "${result_file}" ]] || fail 'result FIFO identity changed'
      assert_mode "${result_file}" 440 'result FIFO destination'
      ;;
    *)
      [[ ! -e "${result_file}" && ! -L "${result_file}" ]] ||
        fail "${scenario} unexpectedly mutated the dispatcher result path"
      ;;
  esac
  case "${scenario}" in
    operation-cancel|wallet-cancel|malformed-query|light-malformed|signal-precommit|signal-local-presubmit|light-signal-presubmit|rm-persistent|ln-persistent|ln-foreign-symlink|publication-rm-persistent|multisig-invalid|tool-replaced|\
      cert-symlink|cert-hardlink|cert-fifo|base-symlink|base-hardlink|base-fifo|\
      result-symlink|result-hardlink|result-fifo|signing-mode)
      expected_wait=0
      ;;
  esac
  [[ "$(grep -c '^wait$' "${event_log}" || true)" == "${expected_wait}" ]] ||
    fail "${scenario} action-owned wait count changed"
  ! grep -Fq "${RAW_DIAGNOSTIC}" "${stdout_file}" "${stderr_file}" "${event_log}" ||
    fail "${scenario} reflected a raw external diagnostic"
  ! grep -Fq "${SIGNING_SECRET}" "${stdout_file}" "${stderr_file}" \
    "${event_log}" "${cli_log}" "${hw_log}" ||
    fail "${scenario} exposed signing material"
  ! grep -Fq 'LIGHT_QUERY_SECRET_DO_NOT_EXPOSE' \
    "${stdout_file}" "${stderr_file}" "${event_log}" "${cli_log}" "${hw_log}" "${curl_log}" ||
    fail "${scenario} exposed a configured query credential"
  while IFS= builtin read -r argument; do
    case "${argument}" in
      *payment.skey*|*stake.skey*|*payment.vkey*|*stake.vkey*|*protparams.json*|*certificate.json*)
        fail "${scenario} passed an authenticated input pathname to cardano-cli"
        ;;
    esac
  done < "${cli_log}"
  if [[ -n "${outside_file}" ]]; then
    [[ "$(stat -f '%u:%Lp:%l:%z:%d:%i' "${outside_file}" 2>/dev/null ||
          stat -c '%u:%a:%h:%s:%d:%i' -- "${outside_file}")|$(< "${outside_file}")" == \
       "${outside_before}" ]] || fail "${scenario} mutated its outside sentinel"
  fi
  case "${scenario}" in
    success|verify-fail|signal-submit|signal-wait|mkdir-created-error|rmdir-created-error|ln-created-error|hardware-success|light-success|light-verify-fail|xtrace-success|existing-certificate)
      expected_certificate=Y
      ;;
    hybrid-success|multisig-success)
      expected_certificate=Y
      ;;
    submit-fail|light-submit-fail|light-submit-lost|light-signal-submit|rmdir-persistent|publication-rm-persistent)
      expected_certificate=Y
      ;;
  esac
  if [[ "${expected_certificate}" == Y ]]; then
      [[ -f "${wallet_dir}/stake.dereg" && ! -L "${wallet_dir}/stake.dereg" ]] ||
        fail "${scenario} did not preserve its published certificate"
      assert_mode "${wallet_dir}/stake.dereg" 600 "${scenario} certificate"
      case "${scenario}" in
        submit-fail|signal-submit|light-submit-fail|light-submit-lost|light-signal-submit|publication-rm-persistent) expected_links=2 ;;
      esac
      [[ "$(file_links "${wallet_dir}/stake.dereg")" == "${expected_links}" ]] ||
        fail "${scenario} certificate link count changed"
      "${REAL_JQ_PATH}" -e '.type == "StakeAddressDeregistrationCertificate"' \
        "${wallet_dir}/stake.dereg" >/dev/null ||
        fail "${scenario} certificate schema changed"
      artifact_hash="$(file_hash "${wallet_dir}/stake.dereg")"
      [[ "$(file_hash "${wallet_dir}/stake.dereg")" == "${artifact_hash}" ]] ||
        fail "${scenario} certificate changed during authenticated inspection"
      ! grep -Fq "${SIGNING_SECRET}" "${wallet_dir}/stake.dereg" ||
        fail "${scenario} certificate embedded signing material"
  elif [[ "${scenario}" == cert-symlink ]]; then
      [[ -L "${wallet_dir}/stake.dereg" ]] ||
        fail 'certificate symlink destination identity changed'
  elif [[ "${scenario}" == cert-hardlink ]]; then
      [[ "${wallet_dir}/stake.dereg" -ef "${outside_file}" ]] ||
        fail 'certificate hardlink destination identity changed'
  elif [[ "${scenario}" == cert-fifo ]]; then
      [[ -p "${wallet_dir}/stake.dereg" ]] ||
        fail 'certificate FIFO destination identity changed'
      assert_mode "${wallet_dir}/stake.dereg" 640 'certificate FIFO destination'
  elif [[ "${scenario}" == ln-foreign-symlink ]]; then
      [[ -L "${wallet_dir}/stake.dereg" &&
         "$(readlink "${wallet_dir}/stake.dereg")" == "${outside_file}" ]] ||
        fail 'ambiguous foreign publication identity changed'
  else
      [[ ! -e "${wallet_dir}/stake.dereg" && ! -L "${wallet_dir}/stake.dereg" ]] ||
        fail "${scenario} unexpectedly committed a certificate"
  fi
  case "${scenario}" in
    hybrid-success|multisig-success)
      local offline_file=""
      offline_file="$(find "${tmp_root}" -mindepth 1 -maxdepth 1 -type f \
        -name 'offline_tx_*.json' -print)"
      [[ -n "${offline_file}" ]] || fail 'hybrid success did not publish an offline package'
      assert_mode "${offline_file}" 600 'hybrid offline package'
      [[ "$(file_links "${offline_file}")" == 1 ]] ||
        fail 'hybrid offline package link count changed'
      "${REAL_JQ_PATH}" -e '.type == "Wallet De-Registration" and
        ."wallet-name" == "fixture_wallet" and ."amount-returned" == 2000000 and
        .txFee == 200000 and (.txBody.type == "TxBody ConwayEra")' \
        "${offline_file}" >/dev/null || fail 'hybrid offline package schema changed'
      artifact_hash="$(file_hash "${offline_file}")"
      [[ "$(file_hash "${offline_file}")" == "${artifact_hash}" ]] ||
        fail "${scenario} offline package changed during authenticated inspection"
      ! grep -Fq "${SIGNING_SECRET}" "${offline_file}" ||
        fail "${scenario} offline package embedded signing material"
      if [[ "${scenario}" == multisig-success ]]; then
        "${REAL_JQ_PATH}" -e '."script-file" | length == 2' \
          "${offline_file}" >/dev/null ||
          fail 'multisig offline package lost its authenticated scripts'
        "${REAL_JQ_PATH}" -e '."signing-file" | length == 0' \
          "${offline_file}" >/dev/null ||
          fail 'multisig offline package unexpectedly embedded key records'
      fi
      ;;
    verify-fail)
      [[ "$(grep -c $'query\tutxo\t--tx-in' "${cli_log}" || true)" == 3 ]] ||
        fail 'local pending confirmation was not bounded to three attempts'
      grep -Fq 'confirmation is still pending' "${event_log}" ||
        fail 'verify failure lost its fixed postcommit warning'
      ;;
    signal-wait)
      grep -Fq 'committed while an interrupt was pending' "${event_log}" ||
        fail "${scenario} lost its fixed committed-interrupt warning"
      ;;
    hardware-success)
      grep -Fq $'transaction\ttransform' "${hw_log}" ||
        fail 'hardware success skipped authenticated transaction transform'
      grep -Fq $'transaction\twitness' "${hw_log}" ||
        fail 'hardware success skipped authenticated hardware witnesses'
      grep -Fq 'unlock:witness the wallet de-registration transaction' "${event_log}" ||
        fail 'hardware success skipped the inherited device-unlock gate'
      ! grep -Fq $'transaction\twitness' "${cli_log}" ||
        fail 'hardware success unexpectedly used software witnesses'
      ;;
    light-success)
      grep -Fq 'address_utxos' "${curl_log}" ||
        fail 'light success skipped the authenticated UTxO query'
      grep -Fq 'account_info' "${curl_log}" ||
        fail 'light success skipped the authenticated stake query'
      [[ "$(grep -c '/ogmios/$' "${curl_log}" || true)" == 1 ]] ||
        fail 'light success did not make exactly one action-owned submit attempt'
      [[ "$(grep -c 'tx_status' "${curl_log}" || true)" == 1 ]] ||
        fail 'light success skipped its bounded action-owned confirmation query'
      ! grep -Fq $'query\tutxo' "${cli_log}" ||
        fail 'light success unexpectedly used a local-node query'
      ;;
    light-verify-fail)
      [[ "$(grep -c 'tx_status' "${curl_log}" || true)" == 3 ]] ||
        fail 'LIGHT pending confirmation was not bounded to three attempts'
      grep -Fq 'confirmation is still pending' "${event_log}" ||
        fail 'LIGHT pending confirmation lost its fixed warning'
      ;;
    signal-local-presubmit)
      ! grep -Fq $'latest\ttransaction\tsubmit' "${cli_log}" ||
        fail 'LOCAL pre-submit signal crossed the final submission gate'
      ;;
    light-signal-presubmit)
      [[ "$(grep -c '/ogmios/$' "${curl_log}" || true)" == 0 ]] ||
        fail 'LIGHT pre-submit signal crossed the final submission gate'
      ;;
    submit-fail|signal-submit|light-submit-fail|light-submit-lost|light-signal-submit)
      [[ "${lock_path}/stage/certificate.json" -ef "${wallet_dir}/stake.dereg" ]] ||
        fail 'submit ambiguity lost its authenticated publication authority'
      grep -Fq 'submission outcome is ambiguous' "${event_log}" ||
        fail 'submit ambiguity lost its fixed diagnostic'
      if [[ "${scenario}" == light-* ]]; then
        [[ "$(grep -c '/ogmios/$' "${curl_log}" || true)" == 1 ]] ||
          fail "${scenario} retried or skipped its single LIGHT submit attempt"
        [[ "$(grep -c 'tx_status' "${curl_log}" || true)" == 0 ]] ||
          fail "${scenario} attempted confirmation after an ambiguous submit"
      fi
      ;;
    rm-persistent)
      [[ -n "$(find "${lock_path}/stage" -mindepth 1 -maxdepth 1 -print)" ]] ||
        fail 'persistent rm failure discarded private recovery payloads'
      ;;
    rmdir-persistent)
      [[ -z "$(find "${lock_path}/stage" -mindepth 1 -maxdepth 1 -print)" ]] ||
        fail 'persistent rmdir failure retained unexpected stage payloads'
      ;;
    publication-rm-persistent)
      [[ "${lock_path}/stage/certificate.json" -ef "${wallet_dir}/stake.dereg" ]] ||
        fail 'persistent publication rollback lost exact certificate authority'
      [[ -z "$(find "${tmp_root}" -mindepth 1 -maxdepth 1 \
        -name 'offline_tx_*.json' -print)" ]] ||
        fail 'failed second publication unexpectedly committed an offline package'
      grep -Fq 'cleanup is incomplete' "${event_log}" ||
        fail 'persistent publication rollback lost its fixed recovery diagnostic'
      ;;
  esac
  if grep -Fq $'latest\ttransaction\tsubmit' "${cli_log}"; then
    [[ "$(grep -c $'latest\ttransaction\tsubmit' "${cli_log}" || true)" == 1 ]] ||
      fail "${scenario} made more than one local submit attempt"
    grep -Eq $'cardano-cli\tlatest\ttransaction\ttxid\t--output-text\t--tx-file\t/dev/fd/[0-9]+$' \
      "${cli_log}" || fail "${scenario} did not derive its canonical transaction ID from the signed descriptor"
    txid_line="$(grep -n $'latest\ttransaction\ttxid' "${cli_log}" | head -1 | cut -d: -f1)"
    submit_line="$(grep -n $'latest\ttransaction\tsubmit' "${cli_log}" | head -1 | cut -d: -f1)"
    (( txid_line < submit_line )) ||
      fail "${scenario} derived its transaction ID after submission"
  fi
  if [[ "${expected_lock}" == Y ]]; then
    while IFS= read -r artifact; do
      [[ -f "${artifact}" && ! -L "${artifact}" ]] ||
        fail "${scenario} retained an unsafe recovery artifact"
      assert_mode "${artifact}" 600 "${scenario} retained recovery artifact"
      if [[ "${artifact}" == "${lock_path}/stage/certificate.json" &&
            -f "${wallet_dir}/stake.dereg" && ! -L "${wallet_dir}/stake.dereg" &&
            "${artifact}" -ef "${wallet_dir}/stake.dereg" ]]; then
        [[ "$(file_links "${artifact}")" == 2 ]] ||
          fail "${scenario} retained certificate authority link count changed"
      else
        [[ "$(file_links "${artifact}")" == 1 ]] ||
          fail "${scenario} retained recovery artifact link count changed"
      fi
      artifact_hash="$(file_hash "${artifact}")"
      [[ "$(file_hash "${artifact}")" == "${artifact_hash}" ]] ||
        fail "${scenario} recovery artifact changed during authenticated inspection"
      ! grep -Fq "${SIGNING_SECRET}" "${artifact}" ||
        fail "${scenario} recovery artifact embedded signing material"
      if [[ "${artifact}" == */curl.config ]]; then
        if [[ "${context_mode_value}" == light ]]; then
          [[ "$(< "${artifact}")" == 'header = "authorization: LIGHT_QUERY_SECRET_DO_NOT_EXPOSE"' ]] ||
            fail "${scenario} retained curl credential configuration changed"
        else
          [[ ! -s "${artifact}" ]] ||
            fail "${scenario} populated a local-mode curl credential configuration"
        fi
      else
        ! grep -Fq 'LIGHT_QUERY_SECRET_DO_NOT_EXPOSE' "${artifact}" ||
          fail "${scenario} recovery artifact embedded a query credential"
      fi
    done < <(find "${lock_path}/stage" -mindepth 1 -maxdepth 1 -type f -print | sort)
  fi
  if [[ "${expected_lock}" == Y ]]; then
    retry_before="${case_root}/retry.before"
    retry_after="${case_root}/retry.after"
    retry_stdout="${case_root}/retry.stdout"
    retry_stderr="${case_root}/retry.stderr"
    retry_event_log="${case_root}/retry.events"
    tree_snapshot "${runtime_root}" "${retry_before}" ||
      fail "${scenario} retry pre-snapshot failed"
    : > "${retry_event_log}"
    event_log="${retry_event_log}"
    fd_inventory_into hardened_fd_before ||
      fail "${scenario} retry pre-action descriptor inventory failed"
    set +e
    cntools_action_main "${context_file}" "${result_file}" \
      > "${retry_stdout}" 2> "${retry_stderr}"
    retry_status=$?
    set -e
    fd_inventory_into hardened_fd_after ||
      fail "${scenario} retry post-action descriptor inventory failed"
    [[ "${hardened_fd_after}" == "${hardened_fd_before}" ]] ||
      fail "${scenario} retained-authority retry leaked descriptors (${hardened_fd_before} -> ${hardened_fd_after})"
    case "${scenario}" in
      submit-fail|signal-submit|light-submit-fail|light-submit-lost|light-signal-submit|ln-foreign-symlink|publication-rm-persistent)
        expected_retry_status=70
        ;;
      rm-persistent|rmdir-persistent|tool-replaced) expected_retry_status=0 ;;
    esac
    [[ "${retry_status}" == "${expected_retry_status}" ]] ||
      fail "${scenario} safe retry status ${retry_status}, expected ${expected_retry_status}"
    tree_snapshot "${runtime_root}" "${retry_after}" ||
      fail "${scenario} retry post-snapshot failed"
    assert_files_equal "${retry_before}" "${retry_after}" \
      "${scenario} retained-authority retry mutation"
    ! grep -Fq "${RAW_DIAGNOSTIC}" "${retry_stdout}" "${retry_stderr}" \
      "${retry_event_log}" || fail "${scenario} retry reflected raw diagnostics"
  fi
  case "${scenario}" in
    success|verify-fail|certificate-fail)
      case "${scenario}" in
        success|verify-fail) repeat_expected_status=21 ;;
        certificate-fail) repeat_expected_status=0 ;;
      esac
      for repeat_index in 1 2; do
        if [[ "${scenario}" == success || "${scenario}" == verify-fail ]]; then
          rm -f -- "${wallet_dir}/stake.dereg"
        fi
        repeat_stdout="${case_root}/repeat.${repeat_index}.stdout"
        repeat_stderr="${case_root}/repeat.${repeat_index}.stderr"
        fd_inventory_into hardened_fd_before ||
          fail "${scenario} repeated run ${repeat_index} pre-action descriptor inventory failed"
        set +e
        cntools_action_main "${context_file}" "${result_file}" \
          > "${repeat_stdout}" 2> "${repeat_stderr}"
        repeat_status=$?
        set -e
        fd_inventory_into hardened_fd_after ||
          fail "${scenario} repeated run ${repeat_index} post-action descriptor inventory failed"
        [[ "${hardened_fd_after}" == "${hardened_fd_before}" ]] ||
          fail "${scenario} repeated run ${repeat_index} leaked descriptors (${hardened_fd_before} -> ${hardened_fd_after})"
        [[ "${repeat_status}" == "${repeat_expected_status}" ]] ||
          fail "${scenario} repeated run ${repeat_index} status ${repeat_status}, expected ${repeat_expected_status}"
        ! grep -Fq "${RAW_DIAGNOSTIC}" "${repeat_stdout}" "${repeat_stderr}" ||
          fail "${scenario} repeated run ${repeat_index} reflected raw diagnostics"
      done
      ;;
  esac
)

run_hardened_action_case success 21
run_hardened_action_case certificate-fail 0
run_hardened_action_case query-fail 0
run_hardened_action_case malformed-query 70
run_hardened_action_case zero-balance 0
run_hardened_action_case unregistered 0
run_hardened_action_case rewards 0
run_hardened_action_case verify-fail 21
run_hardened_action_case hybrid-success 0
run_hardened_action_case submit-fail 70
run_hardened_action_case signal-precommit 70
run_hardened_action_case signal-local-presubmit 70
run_hardened_action_case signal-submit 70
run_hardened_action_case signal-wait 21
run_hardened_action_case signal-wait-precommit 70
run_hardened_action_case cert-symlink 70
run_hardened_action_case cert-hardlink 70
run_hardened_action_case cert-fifo 70
run_hardened_action_case base-symlink 70
run_hardened_action_case base-hardlink 70
run_hardened_action_case base-fifo 70
run_hardened_action_case mkdir-created-error 21
run_hardened_action_case rm-created-error 0
run_hardened_action_case rmdir-created-error 21
run_hardened_action_case rm-persistent 70
run_hardened_action_case rmdir-persistent 70
run_hardened_action_case ln-created-error 21
run_hardened_action_case ln-persistent 70
run_hardened_action_case hardware-success 21
run_hardened_action_case hardware-transform-fail 0
run_hardened_action_case hardware-unlock-fail 0
run_hardened_action_case hardware-witness-fail 0
run_hardened_action_case light-success 21
run_hardened_action_case light-submit-fail 70
run_hardened_action_case light-submit-lost 70
run_hardened_action_case light-signal-presubmit 70
run_hardened_action_case light-signal-submit 70
run_hardened_action_case light-verify-fail 21
run_hardened_action_case light-query-fail 0
run_hardened_action_case light-malformed 70
run_hardened_action_case xtrace-success 21
run_hardened_action_case tool-replaced 70
run_hardened_action_case result-symlink 70
run_hardened_action_case result-hardlink 70
run_hardened_action_case result-fifo 70
run_hardened_action_case signing-mode 70
run_hardened_action_case ln-foreign-symlink 70
run_hardened_action_case publication-rm-persistent 70
run_hardened_action_case multisig-success 0
run_hardened_action_case multisig-invalid 70
run_hardened_action_case operation-cancel 0
run_hardened_action_case wallet-none 0
run_hardened_action_case wallet-cancel 0
run_hardened_action_case wallet-encrypted 0
run_hardened_action_case wallet-missing 0
run_hardened_action_case existing-certificate 0

DEREGISTER_ARM="${TEST_ROOT}/wallet-deregister.arm"
DEREGISTER_HELPER="${TEST_ROOT}/deregisterStakeWallet.function"
awk '
  /^[[:space:]]+deregister\)/ { capture=1 }
  /^[[:space:]]+list\)/ { capture=0 }
  capture { print }
' "${CNTOOLS_SCRIPT}" > "${DEREGISTER_ARM}"
awk '
  /^deregisterStakeWallet\(\)/ { capture=1 }
  capture { print }
' "${WALLET_REGISTRATION_SOURCE}" > "${DEREGISTER_HELPER}"

[[ "$(wc -l < "${DEREGISTER_ARM}" | tr -d '[:space:]')" == 10 ]] ||
  fail 'bound wallet.deregister arm length changed'
[[ "$(file_hash "${DEREGISTER_ARM}")" == 7c797c70216933cd24dcbf082debd04f48d8a33247d1818d0d28719fbd33b97a ]] ||
  fail 'bound wallet.deregister arm exact fingerprint changed'
[[ "$(wc -l < "${DEREGISTER_HELPER}" | tr -d '[:space:]')" == 132 ]] ||
  fail 'inherited deregisterStakeWallet length changed'
[[ "$(file_hash "${DEREGISTER_HELPER}")" == 0942f158feaaab7afd53019ed734f1398e9f41d4b4e6871634d89dc2cdcb5ea6 ]] ||
  fail 'inherited deregisterStakeWallet exact fingerprint changed'
[[ "$(file_hash "${WALLET_REGISTRATION_SOURCE}")" == 2ff4b5f29674fb1cf65e5cda736c9e4f41af51adbe76b29fa5a41bb369f63fdc ]] ||
  fail 'authenticated inherited wallet helper member changed'
[[ "$(file_hash "${ACTION_SOURCE}")" == \
  743da15f4a220ba30dc8968be7ba04e1d2256bda0abd3c77af9cdf8bf5434be7 ]] ||
  fail 'wallet.deregister frozen action hash changed'

[[ "$(grep -Fc 'cntools_compatibility_dispatch_action wallet.deregister' \
  "${DEREGISTER_ARM}")" == 1 ]] || fail 'wallet.deregister generic call count changed'
grep -Fq '0|21) continue ;;' "${DEREGISTER_ARM}" ||
  fail 'wallet.deregister continue mapping changed'
grep -Fq '20) break ;;' "${DEREGISTER_ARM}" ||
  fail 'wallet.deregister parent mapping changed'
grep -Fq '22) myExit 0 "CNTools closed!" ;;' "${DEREGISTER_ARM}" ||
  fail 'wallet.deregister exit mapping changed'
grep -Fq '*) waitToProceed; continue ;;' "${DEREGISTER_ARM}" ||
  fail 'wallet.deregister failure mapping changed'
if grep -Eq 'selectWallet|getWalletRewards|getWalletBalance|deregisterStakeWallet|verifyTx|stake_dereg_file' \
    "${DEREGISTER_ARM}"; then
  fail 'wallet.deregister inline implementation remains after binding'
fi
grep -Fq 'cntools_action_main() {' "${ACTION_SOURCE}" ||
  fail 'wallet.deregister modular entrypoint is missing'
grep -Fq 'CNTools actions are launched by the dispatcher, not directly.' \
  "${ACTION_SOURCE}" || fail 'wallet.deregister direct guard changed'
grep -Fq 'stdout=$(${CCLI} latest stake-address deregistration-certificate' \
  "${DEREGISTER_HELPER}" || fail 'certificate command boundary changed'
grep -Fq 'offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"' \
  "${DEREGISTER_HELPER}" || fail 'legacy jq-controlled offline path behavior changed'
grep -Fq 'println ERROR "\n${FG_RED}ERROR${NC}: failure during stake deregistration certificate creation!\n${stdout}"' \
  "${DEREGISTER_HELPER}" || fail 'legacy raw certificate diagnostic behavior changed'

printf 'CNTools wallet-deregister characterization passed (%s public + %s query + %s transaction/JQ + 3 operation-mode + 56 hardened cases)\n' \
  "${#PUBLIC_CASES[@]}" "${#QUERY_CASES[@]}" \
  "$(( ${#DIRECT_CASES[@]} + ${#JQ_FAILURE_CASES[@]} ))"
