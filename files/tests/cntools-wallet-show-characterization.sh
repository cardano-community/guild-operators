#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet-show characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
LEGACY_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f"
GOVERNANCE_QUERY_SOURCE="${LEGACY_ROOT}/030-governance-query.sh"
WALLET_QUERY_SOURCE="${LEGACY_ROOT}/040-address-wallet-query.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/wallet/show/action.sh"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/wallet/show"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet-show.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
KOIOS_API_FIXTURE='https://koios.invalid/api/v1'
ADDR_BASE='addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
ADDR_PAY='addr_test1pppppppppppppppppppppppppppppppppppppppp'
REWARD_ADDR='stake_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
POOL_ID='pool1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
POLICY_ID='11111111111111111111111111111111111111111111111111111111'
GOV_HASH='22222222222222222222222222222222222222222222222222222222'
PAY_CRED='33333333333333333333333333333333333333333333333333333333'
STAKE_CRED='44444444444444444444444444444444444444444444444444444444'
SCRIPT_PAY_CRED='55555555555555555555555555555555555555555555555555555555'
SCRIPT_STAKE_CRED='66666666666666666666666666666666666666666666666666666666'
SIG_A='77777777777777777777777777777777777777777777777777777777'
SIG_Z='88888888888888888888888888888888888888888888888888888888'
ANCHOR_HASH='9999999999999999999999999999999999999999999999999999999999999999'

cleanup_test() {
  if [[ "${CNTOOLS_WALLET_SHOW_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools wallet-show test root preserved: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools wallet-show characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk cmp find grep jq readlink sed sort stat wc; do
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

write_fake_commands() {
  local command_name=""

  mkdir -p -- "${FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'out_file="" previous="" argument="" normalized="" address=""' \
    'for argument in "$@"; do' \
    '  [[ "${previous}" == --out-file ]] && out_file="${argument}"' \
    '  [[ "${previous}" == --address ]] && address="${argument}"' \
    '  previous="${argument}"' \
    'done' \
    'printf '\''cardano-cli'\'' >> "${CNTOOLS_WALLET_SHOW_CLI_LOG:?}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  [[ "${normalized}" == "${CNTOOLS_WALLET_SHOW_WALLET_ROOT}/"* ]] && normalized="<wallet>/${normalized#"${CNTOOLS_WALLET_SHOW_WALLET_ROOT}/"}"' \
    '  [[ "${normalized}" == "<wallet>/"*"/.cntools-wallet-show."* ]] && normalized="${normalized%/.cntools-wallet-show.*}/<cache-temp>"' \
    '  [[ "${previous_normalized:-}" == --file-text ]] && normalized="<anchor-response>"' \
    '  printf '\''\t%s'\'' "${normalized}" >> "${CNTOOLS_WALLET_SHOW_CLI_LOG:?}"' \
    '  previous_normalized="${normalized}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_SHOW_CLI_LOG:?}"' \
    'if [[ "${CNTOOLS_WALLET_SHOW_ROUTE:-public}" == direct || "${CNTOOLS_WALLET_SHOW_ROUTE:-public}" == public ]]; then' \
    '  case "$*" in' \
    '    "address build "*|"latest stake-address build "*)' \
    '      [[ -n "${out_file}" ]] || exit 96' \
    '      case "${out_file##*/}" in' \
    '        *.base.*|base.addr) printf '\''%s\n'\'' "${CNTOOLS_WALLET_SHOW_BASE:?}" > "${out_file}" ;;' \
    '        *.payment.*|payment.addr) printf '\''%s\n'\'' "${CNTOOLS_WALLET_SHOW_PAY:?}" > "${out_file}" ;;' \
    '        *.reward.*|reward.addr) printf '\''%s\n'\'' "${CNTOOLS_WALLET_SHOW_REWARD:?}" > "${out_file}" ;;' \
    '        *) exit 96 ;;' \
    '      esac' \
    '      ;;' \
    '    "address key-hash "*) [[ -n "${out_file}" ]] || exit 96; printf '\''%s\n'\'' "${CNTOOLS_WALLET_SHOW_PAY_CRED:?}" > "${out_file}" ;;' \
    '    "latest stake-address key-hash "*) [[ -n "${out_file}" ]] || exit 96; printf '\''%s\n'\'' "${CNTOOLS_WALLET_SHOW_STAKE_CRED:?}" > "${out_file}" ;;' \
    '    "hash script "*)' \
    '      [[ -n "${out_file}" ]] || exit 96' \
    '      [[ "$*" == *"/payment.script"* ]] && printf '\''%s\n'\'' "${CNTOOLS_WALLET_SHOW_SCRIPT_PAY_CRED:?}" > "${out_file}" || printf '\''%s\n'\'' "${CNTOOLS_WALLET_SHOW_SCRIPT_STAKE_CRED:?}" > "${out_file}"' \
    '      ;;' \
    '    "query utxo "*)' \
    '      case "${address}" in' \
    '        "${CNTOOLS_WALLET_SHOW_BASE}") printf '\''{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#0":{"address":"%s","value":{"lovelace":2500000,"%s.546f6b656e":42}}}\n'\'' "${address}" "${CNTOOLS_WALLET_SHOW_POLICY}" ;;' \
    '        "${CNTOOLS_WALLET_SHOW_PAY}") printf '\''{"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb#1":{"address":"%s","value":{"lovelace":500000}}}\n'\'' "${address}" ;;' \
    '        *) printf '\''unexpected query address: %s\n'\'' "${address}" >&2; exit 96 ;;' \
    '      esac' \
    '      ;;' \
    '    "query stake-address-info "*)' \
    '      if [[ "${CNTOOLS_WALLET_SHOW_SCENARIO}" == direct-local-malformed ]]; then printf '\''[{"address":"unsafe"}]\n'\''; else printf '\''%s\n'\'' "[{\"address\":\"${CNTOOLS_WALLET_SHOW_REWARD}\",\"rewardAccountBalance\":1234567,\"stakeRegistrationDeposit\":2000000,\"stakeDelegation\":{\"stakePoolBech32\":\"${CNTOOLS_WALLET_SHOW_POOL}\"},\"voteDelegation\":{\"keyHashLedger\":\"${CNTOOLS_WALLET_SHOW_GOV_HASH}\"}}]"; fi' \
    '      ;;' \
    '    "latest query drep-state "*)' \
    '      printf '\''[["drep",{"expiry":120,"anchor":{"url":"https://anchor.invalid/drep.json","dataHash":"%s"}}]]\n'\'' "${CNTOOLS_WALLET_SHOW_ANCHOR_HASH:?}"' \
    '      ;;' \
    '    "latest query drep-stake-distribution --all-dreps "*)' \
    '      printf '\''{"drep-keyHash-%s":3000000,"drep-alwaysAbstain":1000000,"other":20000000}\n'\'' "${CNTOOLS_WALLET_SHOW_GOV_HASH:?}"' \
    '      ;;' \
    '    "hash anchor-data "*) printf '\''%s\n'\'' "${CNTOOLS_WALLET_SHOW_ANCHOR_HASH:?}" ;;' \
    '    *) printf '\''unexpected direct cardano-cli vector: %s\n'\'' "$*" >&2; exit 96 ;;' \
    '  esac' \
    '  exit 0' \
    'fi' \
    'case "$*" in' \
    '  "address build "*|"latest stake-address build "*)' \
    '    [[ -n "${out_file}" ]] || exit 96' \
    '    case "${out_file##*/}" in' \
    '      base.addr) printf '\''%s\n'\'' "${CNTOOLS_WALLET_SHOW_BASE:?}" > "${out_file}" ;;' \
    '      payment.addr) printf '\''%s\n'\'' "${CNTOOLS_WALLET_SHOW_PAY:?}" > "${out_file}" ;;' \
    '      reward.addr) printf '\''%s\n'\'' "${CNTOOLS_WALLET_SHOW_REWARD:?}" > "${out_file}" ;;' \
    '      *) exit 96 ;;' \
    '    esac' \
    '    ;;' \
    '  "address key-hash "*) [[ -n "${out_file}" ]] || exit 96; printf '\''pay-credential\n'\'' > "${out_file}" ;;' \
    '  "latest stake-address key-hash "*) [[ -n "${out_file}" ]] || exit 96; printf '\''stake-credential\n'\'' > "${out_file}" ;;' \
    '  "query utxo "*)' \
    '    case "${address}" in' \
    '      "${CNTOOLS_WALLET_SHOW_BASE}") printf '\''%s\n'\'' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0 2500000 lovelace + 42 ${CNTOOLS_WALLET_SHOW_POLICY}.546f6b656e + TxOutDatumNone" ;;' \
    '      "${CNTOOLS_WALLET_SHOW_PAY}") printf '\''%s\n'\'' "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 1 500000 lovelace + TxOutDatumNone" ;;' \
    '      *) printf '\''unexpected query address: %s\n'\'' "${address}" >&2; exit 96 ;;' \
    '    esac' \
    '    ;;' \
    '  "query stake-address-info "*)' \
    '    printf '\''%s\n'\'' "[{\"address\":\"${CNTOOLS_WALLET_SHOW_REWARD}\",\"rewardAccountBalance\":1234567,\"stakeRegistrationDeposit\":2000000,\"govActionDeposits\":{},\"stakeDelegation\":{\"stakePoolBech32\":\"${CNTOOLS_WALLET_SHOW_POOL}\"},\"voteDelegation\":{\"keyHashLedger\":\"${CNTOOLS_WALLET_SHOW_GOV_HASH}\"}}]"' \
    '    ;;' \
    '  *) printf '\''unexpected cardano-cli vector: %s\n'\'' "$*" >&2; exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/cardano-cli"
  chmod 0755 "${FAKE_BIN}/cardano-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'url="${*: -1}" argument="" normalized="" output="" previous="" data="" data_count=0' \
    'for argument in "$@"; do' \
    '  [[ "${previous}" == --output ]] && output="${argument}"' \
    '  if [[ "${previous}" == --data ]]; then data="${argument}"; data_count=$((data_count + 1)); fi' \
    '  previous="${argument}"' \
    'done' \
    'printf '\''curl'\'' >> "${CNTOOLS_WALLET_SHOW_CURL_LOG:?}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  [[ -n "${output}" && "${normalized}" == "${output}" ]] && normalized="<response>"' \
    '  printf '\''\t%s'\'' "${normalized}" >> "${CNTOOLS_WALLET_SHOW_CURL_LOG:?}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_SHOW_CURL_LOG:?}"' \
    'if [[ "${CNTOOLS_WALLET_SHOW_SCENARIO:?}" == light-error || "${CNTOOLS_WALLET_SHOW_SCENARIO}" == direct-light-error ]]; then' \
    '  printf '\''simulated Koios timeout\n'\'' >&2' \
    '  exit 28' \
    'fi' \
    'if [[ "${CNTOOLS_WALLET_SHOW_ROUTE:-public}" == direct || "${CNTOOLS_WALLET_SHOW_ROUTE:-public}" == public ]]; then' \
    '  [[ -n "${output}" ]] || { printf '\''direct curl missing --output\n'\'' >&2; exit 96; }' \
    '  case "${url}" in' \
    '    "${CNTOOLS_WALLET_SHOW_KOIOS:?}/address_utxos?select=address,tx_hash,tx_index,value,asset_list")' \
    '      [[ "${data_count}" == 1 && "${data}" == "{\"_addresses\":[\"${CNTOOLS_WALLET_SHOW_BASE}\",\"${CNTOOLS_WALLET_SHOW_PAY}\"],\"_extended\":true}" ]] || exit 96' \
    '      if [[ "${CNTOOLS_WALLET_SHOW_SCENARIO}" == direct-light-malformed ]]; then printf '\''[{"address":"unsafe"}]\n'\'' > "${output}"; elif [[ "${CNTOOLS_WALLET_SHOW_SCENARIO}" == direct-light-overflow ]]; then printf '\''[{"address":"%s","tx_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tx_index":0,"value":45000000000000001,"asset_list":[]}]\n'\'' "${CNTOOLS_WALLET_SHOW_BASE}" > "${output}"; else printf '\''[{"address":"%s","tx_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","tx_index":0,"value":2500000,"asset_list":[{"policy_id":"%s","asset_name":"546f6b656e","quantity":42}]},{"address":"%s","tx_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","tx_index":1,"value":500000,"asset_list":[]}]\n'\'' "${CNTOOLS_WALLET_SHOW_BASE}" "${CNTOOLS_WALLET_SHOW_POLICY}" "${CNTOOLS_WALLET_SHOW_PAY}" > "${output}"; fi' \
    '      ;;' \
    '    "${CNTOOLS_WALLET_SHOW_KOIOS:?}/account_info?select=stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit")' \
    '      [[ "${data_count}" == 1 && "${data}" == "{\"_stake_addresses\":[\"${CNTOOLS_WALLET_SHOW_REWARD}\"]}" ]] || exit 96' \
    '      printf '\''[{"stake_address":"%s","status":"registered","delegated_pool":"%s","delegated_drep":"drep_always_abstain","rewards_available":1234567,"deposit":2000000}]\n'\'' "${CNTOOLS_WALLET_SHOW_REWARD}" "${CNTOOLS_WALLET_SHOW_POOL}" > "${output}"' \
    '      ;;' \
    '    "${CNTOOLS_WALLET_SHOW_KOIOS:?}/drep_info?select=drep_status,deposit,active,expires_epoch_no,amount,meta_url,meta_hash")' \
    '      [[ "${data_count}" == 1 ]] || exit 96' \
    '      printf '\''[{"drep_status":"registered","deposit":0,"active":true,"expires_epoch_no":120,"amount":1000000,"meta_url":"","meta_hash":""}]\n'\'' > "${output}"' \
    '      ;;' \
    '    "${CNTOOLS_WALLET_SHOW_KOIOS:?}/drep_epoch_summary?_epoch_no=100&select=amount")' \
    '      [[ "${data_count}" == 0 ]] || exit 96' \
    '      printf '\''[{"amount":23000000}]\n'\'' > "${output}"' \
    '      ;;' \
    '    "https://anchor.invalid/drep.json")' \
    '      printf '\''{"name":"fixture anchor"}\n'\'' > "${output}"' \
    '      ;;' \
    '    *) printf '\''unexpected direct curl URL: %s\n'\'' "${url}" >&2; exit 96 ;;' \
    '  esac' \
    '  exit 0' \
    'fi' \
    'case "${url}" in' \
    '  "${CNTOOLS_WALLET_SHOW_KOIOS:?}/address_utxos?select=address,tx_hash,tx_index,value,asset_list")' \
    '    printf '\''%s\n'\'' '\''address,tx_hash,tx_index,value,asset_list'\'' "${CNTOOLS_WALLET_SHOW_BASE},aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,0,2500000,\"[{\"\"policy_id\"\":\"\"${CNTOOLS_WALLET_SHOW_POLICY}\"\",\"\"asset_name\"\":\"\"546f6b656e\"\",\"\"quantity\"\":42}]\"" "${CNTOOLS_WALLET_SHOW_PAY},bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,1,500000,\"[]\""' \
    '    ;;' \
    '  "${CNTOOLS_WALLET_SHOW_KOIOS:?}/account_info?select=stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit")' \
    '    printf '\''%s\n'\'' '\''stake_address,status,delegated_pool,delegated_drep,rewards_available,deposit'\'' "${CNTOOLS_WALLET_SHOW_REWARD},registered,${CNTOOLS_WALLET_SHOW_POOL},drep_always_abstain,1234567,2000000"' \
    '    ;;' \
    '  *) printf '\''unexpected curl URL: %s\n'\'' "${url}" >&2; exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/curl"
  chmod 0755 "${FAKE_BIN}/curl"

  for command_name in wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_WALLET_SHOW_BLOCKED_LOG:?}"' \
      'printf '\''\t%s'\'' "$@" >> "${CNTOOLS_WALLET_SHOW_BLOCKED_LOG:?}"' \
      'printf '\''\n'\'' >> "${CNTOOLS_WALLET_SHOW_BLOCKED_LOG:?}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

write_normal_keys() {
  local wallet="$1"

  printf '%s\n' '{"description":"CLI Payment Verification Key"}' \
    > "${wallet}/payment.vkey"
  printf '%s\n' '{"description":"CLI Stake Verification Key"}' \
    > "${wallet}/stake.vkey"
  printf '%s\n' '{}' > "${wallet}/payment.skey"
  printf '%s\n' '{}' > "${wallet}/stake.skey"
}

write_addresses() {
  local wallet="$1"

  printf '%s\n' "${ADDR_BASE}" > "${wallet}/base.addr"
  printf '%s\n' "${ADDR_PAY}" > "${wallet}/payment.addr"
  printf '%s\n' "${REWARD_ADDR}" > "${wallet}/reward.addr"
}

write_credentials() {
  local wallet="$1"

  printf '%s\n' "${PAY_CRED}" > "${wallet}/payment.cred"
  printf '%s\n' "${STAKE_CRED}" > "${wallet}/stake.cred"
}

prepare_fixture() {
  local scenario="$1"
  local wallet_root="$2"
  local pool_root="$3"
  local runtime_tmp="$4"
  local selected=""

  case "${scenario}" in
    empty) return 0 ;;
    selection-fail|selection-cancel)
      mkdir -p -- "${wallet_root}/selected"
      write_normal_keys "${wallet_root}/selected"
      write_addresses "${wallet_root}/selected"
      write_credentials "${wallet_root}/selected"
      ;;
    missing-address)
      mkdir -p -- "${wallet_root}/broken"
      ;;
    offline-cache)
      mkdir -p -- "${wallet_root}/cache-wallet"
      write_normal_keys "${wallet_root}/cache-wallet"
      printf '%s\n' "1852H/1815H/0H/2/9" \
        > "${wallet_root}/cache-wallet/derivation.path"
      ;;
    offline-encrypted)
      mkdir -p -- "${wallet_root}/encrypted-wallet"
      write_normal_keys "${wallet_root}/encrypted-wallet"
      write_addresses "${wallet_root}/encrypted-wallet"
      write_credentials "${wallet_root}/encrypted-wallet"
      printf '%s\n' encrypted > "${wallet_root}/encrypted-wallet/payment.skey.gpg"
      ;;
    local-rich)
      mkdir -p -- "${wallet_root}/drep-wallet" \
        "${wallet_root}/rich-ms" "${wallet_root}/signer-a" \
        "${wallet_root}/signer-z" "${pool_root}/pool-a" \
        "${pool_root}/pool-z"
      selected="${wallet_root}/rich-ms"
      printf '%s\n' \
        '{"type":"all","scripts":[{"type":"after","slot":100},{"type":"atLeast","required":2,"scripts":[{"type":"sig","keyHash":"'"${SIG_A}"'"},{"type":"sig","keyHash":"'"${SIG_Z}"'"}]}]}' \
        > "${selected}/payment.script"
      printf '%s\n' '{"type":"sig","keyHash":"'"${STAKE_CRED}"'"}' \
        > "${selected}/stake.script"
      write_addresses "${selected}"
      printf '%s\n' "${PAY_CRED}" > "${selected}/multisig-payment.cred"
      printf '%s\n' "${STAKE_CRED}" > "${selected}/multisig-stake.cred"
      printf '%s\n' "${SCRIPT_PAY_CRED}" > "${selected}/payment_script.cred"
      printf '%s\n' "${SCRIPT_STAKE_CRED}" > "${selected}/stake_script.cred"
      printf '%s\n' "${SIG_A}" > "${wallet_root}/signer-a/multisig-payment.cred"
      printf '%s\n' "${SIG_Z}" > "${wallet_root}/signer-z/multisig-payment.cred"
      printf '%s\n' "${POOL_ID}" > "${pool_root}/pool-z/pool.id"
      printf '%s\n' '{"name":"fixture anchor"}' \
        > "${runtime_tmp}/metadata_anchor.json"
      ;;
    light-success|light-error)
      mkdir -p -- "${wallet_root}/light-wallet" "${pool_root}/pool-z"
      write_normal_keys "${wallet_root}/light-wallet"
      write_addresses "${wallet_root}/light-wallet"
      write_credentials "${wallet_root}/light-wallet"
      printf '%s\n' "${POOL_ID}" > "${pool_root}/pool-z/pool.id"
      ;;
    *) fail "unknown fixture scenario: ${scenario}" ;;
  esac
}

selected_wallet_for() {
  case "$1" in
    selection-fail|selection-cancel) printf selected ;;
    missing-address) printf broken ;;
    offline-cache) printf cache-wallet ;;
    offline-encrypted) printf encrypted-wallet ;;
    local-rich) printf rich-ms ;;
    light-success|light-error) printf light-wallet ;;
    *) return 1 ;;
  esac
}

write_direct_credentials() {
  local wallet="$1"

  printf '%s\n' "${PAY_CRED}" > "${wallet}/payment.cred"
  printf '%s\n' "${STAKE_CRED}" > "${wallet}/stake.cred"
}

prepare_direct_fixture() {
  local scenario="$1" wallet_root="$2" pool_root="$3" selected=""

  case "${scenario}" in
    direct-offline-cache)
      selected="${wallet_root}/direct-cache"
      mkdir -p -- "${selected}"
      write_normal_keys "${selected}"
      printf '%s\n' encrypted > "${selected}/payment.skey.gpg"
      ;;
    direct-selection-fail|direct-selection-cancel|direct-light-success|direct-light-error|direct-light-malformed|direct-light-overflow|direct-terminal-data|direct-local-malformed)
      selected="${wallet_root}/direct-light"
      mkdir -p -- "${selected}" "${pool_root}/pool-z"
      write_normal_keys "${selected}"
      write_addresses "${selected}"
      write_direct_credentials "${selected}"
      printf '%s\n' "${POOL_ID}" > "${pool_root}/pool-z/pool.id"
      ;;
    direct-local-rich)
      selected="${wallet_root}/direct-rich"
      mkdir -p -- "${selected}" "${wallet_root}/signer-a" \
        "${wallet_root}/signer-z" "${pool_root}/pool-z"
      printf '%s\n' \
        '{"type":"all","scripts":[{"type":"after","slot":100},{"type":"atLeast","required":2,"scripts":[{"type":"sig","keyHash":"'"${SIG_A}"'"},{"type":"sig","keyHash":"'"${SIG_Z}"'"}]}]}' \
        > "${selected}/payment.script"
      printf '%s\n' '{"type":"sig","keyHash":"'"${STAKE_CRED}"'"}' \
        > "${selected}/stake.script"
      write_addresses "${selected}"
      printf '%s\n' "${SCRIPT_PAY_CRED}" > "${selected}/payment_script.cred"
      printf '%s\n' "${SCRIPT_STAKE_CRED}" > "${selected}/stake_script.cred"
      printf '%s\n' "${SIG_A}" > "${wallet_root}/signer-a/multisig-payment.cred"
      printf '%s\n' "${SIG_Z}" > "${wallet_root}/signer-z/multisig-payment.cred"
      printf '%s\n' "${POOL_ID}" > "${pool_root}/pool-z/pool.id"
      ;;
    direct-unsafe-cache)
      selected="${wallet_root}/unsafe"
      mkdir -p -- "${selected}"
      write_normal_keys "${selected}"
      write_addresses "${selected}"
      write_direct_credentials "${selected}"
      chmod 0666 "${selected}/base.addr"
      ;;
    *) fail "unknown direct fixture scenario: ${scenario}" ;;
  esac
}

direct_wallet_for() {
  case "$1" in
    direct-offline-cache) printf direct-cache ;;
    direct-selection-fail|direct-selection-cancel|direct-light-success|direct-light-error|direct-light-malformed|direct-light-overflow|direct-terminal-data|direct-local-malformed) printf direct-light ;;
    direct-local-rich) printf direct-rich ;;
    direct-unsafe-cache) printf unsafe ;;
    *) return 1 ;;
  esac
}

expected_stdout_hash() {
  case "$1" in
    empty) printf '%s' 7f88d7a27ab4e3866d9b635786ac57002a75adbabd0c7bde46ebca14322c72d4 ;;
    selection-fail|selection-cancel) printf '%s' 6ee893369d192897b268a5fa92610f77829de3889cf83af63739139dc05eb031 ;;
    missing-address) printf '%s' 5877a67de157b82ac97949d35aa2260e663c15812087b6249fe8320af7acafa4 ;;
    offline-cache) printf '%s' 48ace4aa56b2c52c4ae5c71a0900304e53ed00eaf7e449892a43a189db926994 ;;
    offline-encrypted) printf '%s' 290b91082ff1d8949392a9ef04fa7925703695f5473d149ec596bcf27804f2d7 ;;
    local-rich) printf '%s' dde2c51b2f4ab582b2f41b6809e9e5526031a4be2031c3fcfe19f61785904ea3 ;;
    light-success) printf '%s' 3b82709b9a5c3a5a00e54a32e66bb1f5f8bf59ea86497ef517b80f85ff264395 ;;
    light-error) printf '%s' 2e32fe4c88aca56b693dcecfbc8c9046b68d9bfdf6c113273951ff3ef80ad9e5 ;;
    *) return 1 ;;
  esac
}

expected_event_hash() {
  case "$1" in
    empty) printf '%s' 829a7f8f66e7d049df312606866ba4c0f772e727a4538c4be072f9ce1dcaa36a ;;
    selection-fail) printf '%s' 33d96474e09a100f1f7f5fee5f094ed6035f08fb5a14babd1bd6a1afb9606ad8 ;;
    selection-cancel) printf '%s' 0f44aef795f40347bb13a0954952717fb0db957bcc350c28e26a4c27b2b774e2 ;;
    missing-address|offline-cache|offline-encrypted) printf '%s' 33d96474e09a100f1f7f5fee5f094ed6035f08fb5a14babd1bd6a1afb9606ad8 ;;
    local-rich) printf '%s' 4e8a4312370048887517dd3d1f02cf09960dbaf06f8d6c57945e44039e883c6e ;;
    light-success) printf '%s' 1d7687fc3403f5c7349c9b433b4bde89a2582de92c56283d4d575d088a6af9c3 ;;
    light-error) printf '%s' f2e2de81d3953495c74b5ee71aafeb8fe58f06bb9a6438fb2e5c581df9922b8c ;;
    *) return 1 ;;
  esac
}

expected_cli_hash() {
  case "$1" in
    offline-cache) printf '%s' 6817342506d070aacb1d59421f58258dfbf1d15e922a919bbc3726cff5f2f976 ;;
    local-rich) printf '%s' a0589bc74430fa9145edad0d0765b9a620ed3d6de808f5316efb2de5a02485be ;;
    *) printf '%s' e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ;;
  esac
}

expected_curl_hash() {
  case "$1" in
    local-rich) printf '%s' 0163ce6698393b5b87c3ae557cc6592f6100052e22574d4973e1e539f0a2af04 ;;
    light-success) printf '%s' 3824de7fe1854c89f2b16ee63e3089793bd5bea7763498c4c17570616feb4ea6 ;;
    light-error) printf '%s' 6ab0ab43534ae530c52950ae8ec569bfee147fc440458fa8ff21558d7a308fc4 ;;
    *) printf '%s' e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ;;
  esac
}

assert_semantics() {
  local scenario="$1"
  local output="$2"

  grep -Fq ' >> WALLET >> SHOW' "${output}" ||
    fail "${scenario} lost the wallet-show header"
  case "${scenario}" in
    empty) grep -Fxq 'No wallets available!' "${output}" ;;
    selection-fail|selection-cancel) : ;;
    missing-address)
      grep -Fxq 'ERROR: wallet missing pay/base addr files or vkey/script files to generate them!' "${output}"
      ;;
    offline-cache)
      grep -Fxq 'Type                 : CLI' "${output}" &&
        grep -Fxq 'Derivation Path      : 1852H/1815H/0H/2/9' "${output}"
      ;;
    offline-encrypted)
      grep -Fxq 'Wallet: encrypted-wallet (encrypted)' "${output}" &&
        grep -Fxq 'Type                 : CLI' "${output}"
      ;;
    local-rich)
      grep -Fq 'ASSET SUMMARY: 2 Asset-Type(s)' "${output}" &&
        grep -Fxq 'Type                 : MultiSig' "${output}" &&
        grep -Fxq 'Time Locked Until    : 1970-01-01 00:01:40 UTC' "${output}" &&
        grep -Fxq 'Required signers     : 2' "${output}" &&
        grep -Fxq 'Delegated to pool-z ('"${POOL_ID}"')' "${output}" &&
        grep -Fxq 'DRep Type            : Key' "${output}" &&
        grep -Fq 'DRep anchor data' "${output}"
      ;;
    light-success)
      grep -Fq 'ASSET SUMMARY: 2 Asset-Type(s)' "${output}" &&
        grep -Fxq 'Delegation           : Always abstain' "${output}"
      ;;
    light-error)
      [[ "$(grep -Fc 'ERROR: wallet information query failed; no wallet balances were displayed.' "${output}" || true)" == 1 ]] &&
        ! grep -Fq 'ASSET SUMMARY:' "${output}" &&
        ! grep -Fq 'Registered           :' "${output}"
      ;;
  esac || fail "${scenario} semantic display contract changed"
}

extract_action_output() {
  local full_output="$1"
  local action_output="$2"

  [[ "$(grep -c '^__CNTOOLS_WALLET_SHOW_BEGIN__$' "${full_output}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_WALLET_SHOW_END__$' "${full_output}" || true)" == 1 ]] ||
    fail 'wallet-show output markers were missing or duplicated'
  awk '
    $0 == "__CNTOOLS_WALLET_SHOW_BEGIN__" { capture = 1; next }
    $0 == "__CNTOOLS_WALLET_SHOW_END__" { capture = 0; exit }
    capture { print }
  ' "${full_output}" > "${action_output}"
}

# Source the public controller and the two definition-only legacy query modules
# used by the inline wallet-show branch.
# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
# shellcheck source=/dev/null
. "${GOVERNANCE_QUERY_SOURCE}"
# shellcheck source=/dev/null
. "${WALLET_QUERY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/registry.sh
. "${REGISTRY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/context.sh
. "${CONTEXT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/result.sh
. "${RESULT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/dispatcher.sh
. "${DISPATCHER_SOURCE}"

cntools_compatibility_dispatch_action() (
  local private_root="" context_file="" result_file="" action_status=0

  [[ "${1:-}" == wallet.show && $# == 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/wallet-show-test-dispatch.XXXXXXXX")" || return 70
  chmod 0700 "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  write_context "${context_file}" "${CNTOOLS_MODE}" "${NODE_HOME}" || return 70
  if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"; then
    action_status=0
  else
    action_status=$?
  fi
  if [[ -f "${CAPTURE_FLAG:-/nonexistent}" ]]; then
    printf '__CNTOOLS_WALLET_SHOW_END__\n'
    rm -f -- "${CAPTURE_FLAG}"
  fi
  rm -f -- "${result_file}" "${context_file}" >/dev/null 2>&1 ||
    action_status=70
  rmdir -- "${private_root}" >/dev/null 2>&1 || action_status=70
  return "${action_status}"
)

println() {
  local level="${1:-}"
  shift || true
  case "${level}" in
    ACTION|LOG) return 0 ;;
    OFF|DEBUG|INFO|ERROR) printf '%b\n' "$@" ;;
    *) printf '%b\n' "${level}" "$@" ;;
  esac
}

clear() {
  if [[ -f "${CAPTURE_FLAG:-/nonexistent}" &&
        "${CNTOOLS_WALLET_SHOW_SCENARIO:-}" == selection-cancel &&
        "${CAPTURE_CLEAR_COUNT:-0}" == 1 ]]; then
    printf '__CNTOOLS_WALLET_SHOW_END__\n'
    rm -f -- "${CAPTURE_FLAG}"
    return 0
  fi
  [[ -f "${CAPTURE_FLAG:-/nonexistent}" ]] &&
    printf 'terminal:clear\n' >> "${EVENT_LOG:?}"
  [[ -f "${CAPTURE_FLAG:-/nonexistent}" ]] &&
    CAPTURE_CLEAR_COUNT=$((CAPTURE_CLEAR_COUNT + 1))
}

tput() {
  [[ -f "${CAPTURE_FLAG:-/nonexistent}" ]] &&
    printf 'terminal:%s\n' "$*" >> "${EVENT_LOG:?}"
}

getEpoch() { printf '100\n'; }
timeUntilNextEpoch() { printf '0\n'; }
timeLeft() { printf '00:00:00'; }
getSlotTipRef() { printf '101\n'; }
slotInterval() { printf '20\n'; }
getNodeMetrics() { :; }
updateProtocolParams() { :; }
getDecimalPlaces() { return 2; }

getPriceInfo() {
  if [[ -f "${CAPTURE_FLAG:-/nonexistent}" ]]; then
    printf 'runtime:getPriceInfo\n' >> "${EVENT_LOG:?}"
    price_now=2
  else
    price_now=""
  fi
}

getPriceString() {
  local value="${1:-0}"
  printf 'price:%s\n' "${value}" >> "${EVENT_LOG:?}"
  if [[ "${CNTOOLS_WALLET_SHOW_SCENARIO:-}" == direct-terminal-data ]]; then
    price_str=$'\033[31munsafe'
    return 0
  fi
  case "${value}" in
    0) price_str="" ;;
    500000) price_str=' (1 USD)' ;;
    1234567) price_str=' (2.47 USD)' ;;
    2500000) price_str=' (5 USD)' ;;
    3000000) price_str=' (6 USD)' ;;
    4234567) price_str=' (8.47 USD)' ;;
    *) fail "unexpected wallet-show price input: ${value}" ;;
  esac
}

formatLovelace() {
  case "${1:-}" in
    0) printf 0 ;;
    500000) printf 0.5 ;;
    1000000) printf 1 ;;
    1234567) printf 1.234567 ;;
    2500000) printf 2.5 ;;
    3000000) printf 3 ;;
    4234567) printf 4.234567 ;;
    *) fail "unexpected wallet-show lovelace input: ${1:-<empty>}" ;;
  esac
}

formatAsset() { printf '%s' "${1:-}"; }
hexToAscii() { printf Token; }
isNumber() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
getAssetIDBech32() {
  printf 'asset-vector:%s:%s\n' "${1:-}" "${2:-}" >> "${EVENT_LOG:?}"
  printf asset1fixture
}
getDateFromSlot() { printf '1970-01-01 00:01:40 UTC'; }

getPoolID() {
  local pool_name="${1:-}"

  printf 'pool-id:%s\n' "${pool_name}" >> "${EVENT_LOG:?}"
  pool_id_bech32=""
  [[ "${pool_name}" == pool-z ]] || return 1
  pool_id_bech32="${POOL_ID}"
}

getGovKeyInfo() {
  local wallet="${1:-}"

  printf 'governance:key-info:%s\n' "${wallet}" >> "${EVENT_LOG:?}"
  drep_hash=""
  [[ "${wallet}" == drep-wallet ]] && drep_hash="${GOV_HASH}"
}

getDRepIds() {
  printf 'governance:drep-ids:%s:%s\n' "${1:-}" "${2:-}" >> "${EVENT_LOG:?}"
  drep_id=drep1fixture
  drep_id_cip129=drep1291fixture
}

getDRepStatus() {
  printf 'governance:drep-status:%s:%s\n' "${1:-}" "${2:-}" >> "${EVENT_LOG:?}"
  drep_expiry=120
  drep_anchor_url='https://anchor.invalid/drep.json'
  drep_anchor_hash=registered-anchor-hash
  return 0
}

getDRepAnchor() {
  printf 'governance:drep-anchor:%s:%s\n' "${1:-}" "${2:-}" >> "${EVENT_LOG:?}"
  drep_anchor_file="${TMP_DIR}/metadata_anchor.json"
  drep_anchor_real_hash=registered-anchor-hash
  return 0
}

getDRepVotePower() {
  printf 'governance:vote-power:%s:%s\n' "${1:-}" "${2:-}" >> "${EVENT_LOG:?}"
  vote_power=3000000
  vote_power_pct=12.5
}

versionCheck() { return 0; }
bech32() { printf 22fixture; }

selectWallet() {
  printf 'action:selectWallet:%s\n' "${1:-}" >> "${EVENT_LOG:?}"
  case "${CNTOOLS_WALLET_SHOW_SCENARIO:?}" in
    selection-fail|direct-selection-fail) return 1 ;;
    selection-cancel|direct-selection-cancel) return 2 ;;
    direct-*) wallet_name="$(direct_wallet_for "${CNTOOLS_WALLET_SHOW_SCENARIO}")" ;;
    *) wallet_name="$(selected_wallet_for "${CNTOOLS_WALLET_SHOW_SCENARIO}")" ;;
  esac
}

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}"
  local menu="" option="" index=0

  case "${1:-}" in
    '[w] Wallet') menu=main ;;
    '[n] New') menu=wallet ;;
    *) fail "unexpected legacy menu: ${1:-<empty>}" ;;
  esac
  if [[ "${menu}" == wallet && -f "${CAPTURE_FLAG:-/nonexistent}" &&
        "${choice}" != s ]]; then
    printf '__CNTOOLS_WALLET_SHOW_END__\n'
    rm -f -- "${CAPTURE_FLAG}"
  fi
  [[ -n "${choice}" ]] || fail "legacy menu ${menu} exhausted choices"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == wallet:s ]]; then
        : > "${CAPTURE_FLAG:?}"
        printf '__CNTOOLS_WALLET_SHOW_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was absent from legacy menu ${menu}"
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  [[ "${CNTOOLS_WALLET_SHOW_ROUTE:-public}" != direct ]] || return 0
  if [[ -f "${CAPTURE_FLAG:-/nonexistent}" ]]; then
    printf '__CNTOOLS_WALLET_SHOW_END__\n'
    rm -f -- "${CAPTURE_FLAG}"
  fi
  return 0
}

myExit() {
  local status="${1:-0}"
  local message="${2:-}"

  printf 'exit:%s:%s\n' "${status}" "${message}" >> "${EVENT_LOG:?}"
  [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
    fail 'wallet-show traversal did not consume all choices'
  exit "${status}"
}

assert_cache_mutation() {
  local scenario="$1"
  local wallet_root="$2"
  local before="$3"
  local after="$4"
  local filtered="$5"
  local relative=""

  if [[ "${scenario}" != offline-cache ]]; then
    assert_files_equal "${after}" "${before}" "${scenario} persistent runtime tree"
    return
  fi
  for relative in base.addr payment.addr reward.addr payment.cred stake.cred; do
    [[ -f "${wallet_root}/cache-wallet/${relative}" &&
       ! -L "${wallet_root}/cache-wallet/${relative}" ]] ||
      fail "offline-cache did not create ${relative}"
    [[ "$(file_mode "${wallet_root}/cache-wallet/${relative}")" == 600 ]] ||
      fail "offline-cache did not create ${relative} with mode 0600"
  done
  [[ "$(< "${wallet_root}/cache-wallet/base.addr")" == "${ADDR_BASE}" &&
     "$(< "${wallet_root}/cache-wallet/payment.addr")" == "${ADDR_PAY}" &&
     "$(< "${wallet_root}/cache-wallet/reward.addr")" == "${REWARD_ADDR}" &&
     "$(< "${wallet_root}/cache-wallet/payment.cred")" == "${PAY_CRED}" &&
     "$(< "${wallet_root}/cache-wallet/stake.cred")" == "${STAKE_CRED}" ]] ||
    fail 'offline-cache content contract changed'
  awk -F '\t' '
    $2 !~ /^wallet\/cache-wallet\/(base[.]addr|payment[.]addr|reward[.]addr|payment[.]cred|stake[.]cred)$/
  ' "${after}" > "${filtered}"
  assert_files_equal "${filtered}" "${before}" \
    'offline-cache mutation outside the five legacy cache files'
}

run_case() {
  local scenario="$1"
  local mode="$2"
  local case_root="${TEST_ROOT}/cases/${scenario}"
  local runtime_root="${case_root}/runtime"
  local wallet_root="${runtime_root}/wallet"
  local pool_root="${runtime_root}/pool"
  local capture_root="${case_root}/capture"
  local full_stdout="${capture_root}/full.stdout"
  local action_stdout="${capture_root}/action.stdout"
  local stderr_file="${capture_root}/stderr"
  local event_log="${capture_root}/events"
  local cli_log="${capture_root}/cli"
  local curl_log="${capture_root}/curl"
  local blocked_log="${capture_root}/blocked"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local filtered_after="${capture_root}/after.filtered.tree"
  local expected_hash="" actual_hash="" status=0

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${wallet_root}" "${pool_root}" "${capture_root}"
  prepare_fixture "${scenario}" "${wallet_root}" "${pool_root}" \
    "${runtime_root}/tmp"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot ${scenario} before traversal"
  : > "${event_log}"
  : > "${cli_log}"
  : > "${curl_log}"
  : > "${blocked_log}"

  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    export CNTOOLS_WALLET_SHOW_SCENARIO="${scenario}"
    export CNTOOLS_WALLET_SHOW_CLI_LOG="${cli_log}"
    export CNTOOLS_WALLET_SHOW_CURL_LOG="${curl_log}"
    export CNTOOLS_WALLET_SHOW_BLOCKED_LOG="${blocked_log}"
    export CNTOOLS_WALLET_SHOW_WALLET_ROOT="${wallet_root}"
    export CNTOOLS_WALLET_SHOW_KOIOS="${KOIOS_API_FIXTURE}"
    export CNTOOLS_WALLET_SHOW_BASE="${ADDR_BASE}"
    export CNTOOLS_WALLET_SHOW_PAY="${ADDR_PAY}"
    export CNTOOLS_WALLET_SHOW_REWARD="${REWARD_ADDR}"
    export CNTOOLS_WALLET_SHOW_POOL="${POOL_ID}"
    export CNTOOLS_WALLET_SHOW_POLICY="${POLICY_ID}"
    export CNTOOLS_WALLET_SHOW_GOV_HASH="${GOV_HASH}"
    export CNTOOLS_WALLET_SHOW_PAY_CRED="${PAY_CRED}"
    export CNTOOLS_WALLET_SHOW_STAKE_CRED="${STAKE_CRED}"
    export CNTOOLS_WALLET_SHOW_SCRIPT_PAY_CRED="${SCRIPT_PAY_CRED}"
    export CNTOOLS_WALLET_SHOW_SCRIPT_STAKE_CRED="${SCRIPT_STAKE_CRED}"
    export CNTOOLS_WALLET_SHOW_ANCHOR_HASH="${ANCHOR_HASH}"
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${wallet_root}"
    POOL_FOLDER="${pool_root}"
    CCLI=cardano-cli
    NETWORK_IDENTIFIER='--testnet-magic 42'
    KOIOS_API=$([[ "${mode}" == LIGHT ]] && printf '%s' "${KOIOS_API_FIXTURE}" || printf '')
    KOIOS_API_HEADERS=()
    CURL_TIMEOUT=10
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=characterized
    NETWORK_NAME=Preview
    CURRENCY=usd
    PROT_VERSION=10.0
    ADVANCED_MODE=false
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    WALLET_SELECTION_FILTER_LIMIT=10
    WALLET_PAY_VK_FILENAME=payment.vkey
    WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_PAY_SK_FILENAME=payment.skey
    WALLET_STAKE_SK_FILENAME=stake.skey
    WALLET_PAY_SCRIPT_FILENAME=payment.script
    WALLET_STAKE_SCRIPT_FILENAME=stake.script
    WALLET_PAY_ADDR_FILENAME=payment.addr
    WALLET_BASE_ADDR_FILENAME=base.addr
    WALLET_STAKE_ADDR_FILENAME=reward.addr
    WALLET_PAY_CRED_FILENAME=payment.cred
    WALLET_STAKE_CRED_FILENAME=stake.cred
    WALLET_PAY_SCRIPT_CRED_FILENAME=payment_script.cred
    WALLET_STAKE_SCRIPT_CRED_FILENAME=stake_script.cred
    WALLET_MULTISIG_PREFIX=multisig-
    WALLET_HW_PAY_SK_FILENAME=payment.hw.skey
    WALLET_HW_STAKE_SK_FILENAME=stake.hw.skey
    WALLET_HW_PAY_VK_FILENAME=payment.hw.vkey
    WALLET_HW_STAKE_VK_FILENAME=stake.hw.vkey
    WALLET_DERIVATION_PATH_FILENAME=derivation.path
    WALLET_GOV_DREP_SCRIPT_FILENAME=drep.script
    WALLET_GOV_DREP_VK_FILENAME=drep.vkey
    WALLET_GOV_DREP_SK_FILENAME=drep.skey
    WALLET_GOV_DREP_ID_FILENAME=drep.id
    WALLET_GOV_CC_COLD_VK_FILENAME=cc-cold.vkey
    WALLET_GOV_CC_COLD_SK_FILENAME=cc-cold.skey
    WALLET_GOV_CC_COLD_ID_FILENAME=cc-cold.id
    WALLET_GOV_CC_HOT_VK_FILENAME=cc-hot.vkey
    WALLET_GOV_CC_HOT_SK_FILENAME=cc-hot.skey
    WALLET_GOV_CC_HOT_ID_FILENAME=cc-hot.id
    WALLET_GOV_HW_DREP_SK_FILENAME=drep.hw.skey
    WALLET_GOV_HW_CC_COLD_SK_FILENAME=cc-cold.hw.skey
    WALLET_GOV_HW_CC_HOT_SK_FILENAME=cc-hot.hw.skey
    POOL_ID_FILENAME=pool.id
    op_mode=offline
    price_now="" price_24h=0 slotnum=100
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CAPTURE_FLAG="${capture_root}/active"
    CAPTURE_CLEAR_COUNT=0
    CHOICES=(w s h q)
    CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == 0 ]] || fail "${scenario} traversal returned ${status}"
  extract_action_output "${full_stdout}" "${action_stdout}"
  [[ ! -s "${stderr_file}" ]] ||
    fail "${scenario} emitted stderr: $(< "${stderr_file}")"
  [[ ! -s "${blocked_log}" ]] ||
    fail "${scenario} attempted an unsafe external command"
  assert_semantics "${scenario}" "${action_stdout}"

  expected_hash="$(expected_stdout_hash "${scenario}")"
  actual_hash="$(file_hash "${action_stdout}")"
  if [[ "${actual_hash}" != "${expected_hash}" ]]; then
    awk '{ printf "%04d %s\\n", NR, $0 }' "${action_stdout}" >&2
    fail "${scenario} exact normalized stdout changed (${actual_hash})"
  fi
  [[ "$(file_hash "${event_log}")" == "$(expected_event_hash "${scenario}")" ]] ||
    fail "${scenario} exact wait, terminal, query, or navigation events changed"
  [[ "$(file_hash "${cli_log}")" == "$(expected_cli_hash "${scenario}")" ]] ||
    fail "${scenario} exact cardano-cli command vectors changed"
  [[ "$(file_hash "${curl_log}")" == "$(expected_curl_hash "${scenario}")" ]] ||
    fail "${scenario} exact Koios command vectors changed"

  case "${scenario}" in
    empty)
      grep -Fxq 'action:waitToProceed' "${event_log}" ||
        fail 'empty did not wait'
      ;;
    selection-fail)
      grep -Fxq 'action:waitToProceed' "${event_log}" ||
        fail 'selection failure did not wait'
      ;;
    selection-cancel)
      ! grep -Fq 'action:waitToProceed' "${event_log}" ||
        fail 'selection cancel unexpectedly waited'
      ;;
    missing-address)
      grep -Fxq 'action:waitToProceed' "${event_log}" ||
        fail 'missing-address did not wait'
      ;;
    *)
      [[ "$(grep -Fc 'action:waitToProceed' "${event_log}" || true)" == 1 ]] ||
        fail "${scenario} did not wait exactly once"
      ;;
  esac
  [[ "$(grep -Fc 'menu:wallet:s' "${event_log}" || true)" == 1 &&
     "$(grep -Fc 'menu:wallet:h' "${event_log}" || true)" == 1 &&
     "$(grep -Fc 'menu:main:q' "${event_log}" || true)" == 1 ]] ||
    fail "${scenario} navigation contract changed"

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot ${scenario} after traversal"
  assert_cache_mutation "${scenario}" "${wallet_root}" \
    "${before_snapshot}" "${after_snapshot}" "${filtered_after}"
}

run_direct_case() {
  local scenario="$1" mode="$2"
  local case_root="${TEST_ROOT}/direct/${scenario}"
  local runtime_root="${case_root}/runtime"
  local wallet_root="${runtime_root}/wallet"
  local pool_root="${runtime_root}/pool"
  local capture_root="${case_root}/capture"
  local private_root="${capture_root}/private"
  local stdout_file="${capture_root}/stdout"
  local stderr_file="${capture_root}/stderr"
  local event_log="${capture_root}/events"
  local cli_log="${capture_root}/cli"
  local curl_log="${capture_root}/curl"
  local blocked_log="${capture_root}/blocked"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local filtered_after="${capture_root}/after.filtered.tree"
  local payment_section="${capture_root}/payment.section"
  local expected_status=0 status=0 cache_file=""

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${wallet_root}" "${pool_root}" "${capture_root}" "${private_root}"
  chmod 0700 "${private_root}"
  prepare_direct_fixture "${scenario}" "${wallet_root}" "${pool_root}"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot ${scenario} before direct dispatch"
  : > "${event_log}"
  : > "${cli_log}"
  : > "${curl_log}"
  : > "${blocked_log}"
  : > "${capture_root}/active"
  case "${scenario}" in
    direct-unsafe-cache|direct-terminal-data) expected_status=70 ;;
  esac

  if (
    set +e
    export LC_ALL=C TZ=UTC
    export CNTOOLS_WALLET_SHOW_ROUTE=direct
    export CNTOOLS_WALLET_SHOW_SCENARIO="${scenario}"
    export CNTOOLS_WALLET_SHOW_CLI_LOG="${cli_log}"
    export CNTOOLS_WALLET_SHOW_CURL_LOG="${curl_log}"
    export CNTOOLS_WALLET_SHOW_BLOCKED_LOG="${blocked_log}"
    export CNTOOLS_WALLET_SHOW_WALLET_ROOT="${wallet_root}"
    export CNTOOLS_WALLET_SHOW_KOIOS="${KOIOS_API_FIXTURE}"
    export CNTOOLS_WALLET_SHOW_BASE="${ADDR_BASE}"
    export CNTOOLS_WALLET_SHOW_PAY="${ADDR_PAY}"
    export CNTOOLS_WALLET_SHOW_REWARD="${REWARD_ADDR}"
    export CNTOOLS_WALLET_SHOW_POOL="${POOL_ID}"
    export CNTOOLS_WALLET_SHOW_POLICY="${POLICY_ID}"
    export CNTOOLS_WALLET_SHOW_GOV_HASH="${GOV_HASH}"
    export CNTOOLS_WALLET_SHOW_PAY_CRED="${PAY_CRED}"
    export CNTOOLS_WALLET_SHOW_STAKE_CRED="${STAKE_CRED}"
    export CNTOOLS_WALLET_SHOW_SCRIPT_PAY_CRED="${SCRIPT_PAY_CRED}"
    export CNTOOLS_WALLET_SHOW_SCRIPT_STAKE_CRED="${SCRIPT_STAKE_CRED}"
    export CNTOOLS_WALLET_SHOW_ANCHOR_HASH="${ANCHOR_HASH}"
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${wallet_root}"
    POOL_FOLDER="${pool_root}"
    CCLI=cardano-cli
    NETWORK_IDENTIFIER='--testnet-magic 42'
    KOIOS_API=$([[ "${mode}" == LIGHT ]] && printf '%s' "${KOIOS_API_FIXTURE}" || printf '')
    KOIOS_API_HEADERS=()
    CURL_TIMEOUT=10
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=characterized
    NETWORK_NAME=Preview
    CURRENCY=usd
    PROT_VERSION=10.0
    ADVANCED_MODE=false
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    WALLET_SELECTION_FILTER_LIMIT=10
    WALLET_PAY_VK_FILENAME=payment.vkey
    WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_PAY_SK_FILENAME=payment.skey
    WALLET_STAKE_SK_FILENAME=stake.skey
    WALLET_PAY_SCRIPT_FILENAME=payment.script
    WALLET_STAKE_SCRIPT_FILENAME=stake.script
    WALLET_PAY_ADDR_FILENAME=payment.addr
    WALLET_BASE_ADDR_FILENAME=base.addr
    WALLET_STAKE_ADDR_FILENAME=reward.addr
    WALLET_PAY_CRED_FILENAME=payment.cred
    WALLET_STAKE_CRED_FILENAME=stake.cred
    WALLET_PAY_SCRIPT_CRED_FILENAME=payment_script.cred
    WALLET_STAKE_SCRIPT_CRED_FILENAME=stake_script.cred
    WALLET_MULTISIG_PREFIX=multisig-
    WALLET_DERIVATION_PATH_FILENAME=derivation.path
    WALLET_GOV_DREP_SCRIPT_FILENAME=drep.script
    WALLET_GOV_DREP_ID_FILENAME=drep.id
    POOL_ID_FILENAME=pool.id
    price_now="" price_24h=0 slotnum=100
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CAPTURE_FLAG="${capture_root}/active"
    CAPTURE_CLEAR_COUNT=0
    write_context "${private_root}/context.json" "${mode}" \
      "${runtime_root}/home"
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${private_root}/context.json" "${private_root}/result.json"
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "${expected_status}" ]] || {
    awk '{ printf "%04d %s\\n", NR, $0 }' "${stdout_file}" >&2
    awk '{ printf "%04d %s\\n", NR, $0 }' "${stderr_file}" >&2
    fail "${scenario} direct status ${status}, expected ${expected_status}"
  }
  if [[ "${expected_status}" == 70 ]]; then
    [[ "$(< "${stderr_file}")" == \
      'CNTools wallet-show action failed validation.' ]] ||
      fail "${scenario} validation diagnostic changed"
  else
    [[ ! -s "${stderr_file}" ]] ||
      fail "${scenario} emitted stderr: $(< "${stderr_file}")"
  fi
  [[ ! -e "${private_root}/result.json" &&
     "$(find "${private_root}" -mindepth 1 -maxdepth 1 ! -name context.json -print -quit)" == "" ]] ||
    fail "${scenario} left a private query/result artifact"
  rm -f -- "${private_root}/context.json"
  rmdir -- "${private_root}"
  [[ ! -s "${blocked_log}" ]] ||
    fail "${scenario} attempted an unsafe external command"
  grep -Fq ' >> WALLET >> SHOW' "${stdout_file}" ||
    fail "${scenario} lost the direct wallet-show header"

  case "${scenario}" in
    direct-selection-fail)
      [[ "$(grep -Fc 'action:waitToProceed' "${event_log}" || true)" == 1 ]]
      ;;
    direct-selection-cancel)
      [[ "$(grep -Fc 'action:waitToProceed' "${event_log}" || true)" == 0 ]]
      ;;
    direct-offline-cache)
      grep -Fxq 'Wallet: direct-cache (encrypted)' "${stdout_file}" &&
        grep -Fxq 'Type                 : CLI' "${stdout_file}" &&
        grep -Fxq 'Registered           : Unknown' "${stdout_file}"
      ;;
    direct-local-rich)
      grep -Fq 'ASSET SUMMARY: 2 Asset-Type(s)' "${stdout_file}" &&
        grep -Fq 'ASSET SUMMARY: 1 Asset-Type(s)' "${stdout_file}" &&
        grep -Fxq 'Type                 : MultiSig' "${stdout_file}" &&
        grep -Fxq 'Required signers     : 2' "${stdout_file}" &&
        grep -Fq 'DRep anchor data' "${stdout_file}" &&
        grep -Fxq 'Active Vote power    : 3 ADA (12.5 %)' "${stdout_file}"
      awk '
        /found for Payment Address/ { capture=1 }
        capture { print }
        capture && /^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~/ { exit }
      ' "${stdout_file}" > "${payment_section}"
      ! grep -Fq Token "${payment_section}"
      ;;
    direct-light-success)
      grep -Fq 'ASSET SUMMARY: 2 Asset-Type(s)' "${stdout_file}" &&
        grep -Fq 'ASSET SUMMARY: 1 Asset-Type(s)' "${stdout_file}" &&
        grep -Fxq 'Delegation           : Always abstain' "${stdout_file}" &&
        grep -Fxq 'Active Vote power    : 1 ADA (4.3478 %)' "${stdout_file}"
      ;;
    direct-light-error|direct-light-malformed|direct-light-overflow|direct-local-malformed)
      [[ "$(grep -Fc 'ERROR: wallet information query failed; no wallet balances were displayed.' "${stdout_file}" || true)" == 1 ]] &&
        ! grep -Fq 'ASSET SUMMARY:' "${stdout_file}" &&
        ! grep -Fq 'Registered           :' "${stdout_file}" &&
        ! grep -Fq '# Funds' "${stdout_file}"
      ;;
    direct-unsafe-cache)
      ! grep -Fq 'Registered           :' "${stdout_file}"
      ;;
    direct-terminal-data)
      ! grep -q $'\033' "${stdout_file}"
      ;;
  esac || fail "${scenario} hardened direct display contract changed"

  [[ "$(grep -Fc 'terminal:sc' "${event_log}" || true)" == \
     "$(grep -Fc 'terminal:rc' "${event_log}" || true)" &&
     "$(grep -Fc 'terminal:sc' "${event_log}" || true)" == \
     "$(grep -Fc 'terminal:ed' "${event_log}" || true)" ]] ||
    fail "${scenario} did not restore each saved terminal state"

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot ${scenario} after direct dispatch"
  if [[ "${scenario}" == direct-offline-cache ]]; then
    for cache_file in base.addr payment.addr reward.addr payment.cred stake.cred; do
      [[ -f "${wallet_root}/direct-cache/${cache_file}" &&
         ! -L "${wallet_root}/direct-cache/${cache_file}" &&
         "$(file_mode "${wallet_root}/direct-cache/${cache_file}")" == 600 ]] ||
        fail "${scenario} did not atomically create ${cache_file} mode 0600"
    done
    grep -Ev $'^f\twallet/direct-cache/((base|payment|reward)\\.addr|(payment|stake)\\.cred)\t' \
      "${after_snapshot}" > "${filtered_after}"
    assert_files_equal "${filtered_after}" "${before_snapshot}" \
      "${scenario} mutation outside five new caches"
  else
    assert_files_equal "${after_snapshot}" "${before_snapshot}" \
      "${scenario} persistent runtime tree"
  fi
}

write_fake_commands
PATH="${FAKE_BIN}:${BASE_PATH}"
export PATH
export http_proxy=http://127.0.0.1:9
export https_proxy=http://127.0.0.1:9
export HTTP_PROXY=http://127.0.0.1:9
export HTTPS_PROXY=http://127.0.0.1:9
run_case empty LOCAL
run_case selection-fail OFFLINE
run_case selection-cancel OFFLINE
run_case missing-address OFFLINE
run_case offline-cache OFFLINE
run_case offline-encrypted OFFLINE
run_case local-rich LOCAL
run_case light-success LIGHT
run_case light-error LIGHT
run_direct_case direct-selection-fail OFFLINE
run_direct_case direct-selection-cancel OFFLINE
run_direct_case direct-offline-cache OFFLINE
run_direct_case direct-local-rich LOCAL
run_direct_case direct-local-malformed LOCAL
run_direct_case direct-light-success LIGHT
run_direct_case direct-light-error LIGHT
run_direct_case direct-light-malformed LIGHT
run_direct_case direct-light-overflow LIGHT
run_direct_case direct-unsafe-cache OFFLINE
run_direct_case direct-terminal-data LIGHT

grep -Fq '            show)' "${CNTOOLS_SCRIPT}" ||
  fail 'inline legacy wallet-show branch is missing'
grep -Fq 'Stage 4 compatibility action' "${ACTION_SOURCE}" ||
  fail 'wallet-show modular action is not active'

printf 'CNTools wallet-show characterization and dedicated-action parity passed (9 public + 11 direct cases)\n'
