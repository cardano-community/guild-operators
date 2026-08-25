#!/usr/bin/env bash
# Characterize the inline legacy wallet.new.mnemonic implementation without
# enabling or extracting its modular action.
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2129,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet-new-mnemonic characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
LEGACY_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f"
GOVERNANCE_QUERY_SOURCE="${LEGACY_ROOT}/030-governance-query.sh"
WALLET_QUERY_SOURCE="${LEGACY_ROOT}/040-address-wallet-query.sh"
WALLET_CREATE_SOURCE="${LEGACY_ROOT}/050-wallet-create-registration.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/wallet/new/mnemonic/action.sh"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet-new-mnemonic.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
MNEMONIC='alpha bravo cactus delta ember forest galaxy harbor ivory jungle kitten lemon mango nectar ocean panda quartz river solar tiger uncle velvet willow xenon'
BASE_ADDRESS='addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
PAYMENT_ADDRESS='addr_test1vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv'
REWARD_ADDRESS='stake_test1ssssssssssssssssssssssssssssssssssssssssssssssssssssss'

cleanup_test() {
  if [[ "${CNTOOLS_WALLET_NEW_MNEMONIC_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools wallet-new-mnemonic test root preserved: %s\n' \
      "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools wallet-new-mnemonic characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk cmp cut find grep jq readlink sed sort stat wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command unavailable: ${required_command}"
done
if command -v sha256sum >/dev/null 2>&1; then
  HASH_COMMAND=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  HASH_COMMAND=shasum
else
  fail 'sha256sum or shasum is required'
fi

hash_file() {
  local target="$1" digest=""

  case "${HASH_COMMAND}" in
    sha256sum) digest="$(sha256sum "${target}")" ;;
    shasum) digest="$(shasum -a 256 "${target}")" ;;
  esac
  printf '%s\n' "${digest%% *}"
}

write_fake_commands() {
  local command_name=""

  mkdir -p -- "${FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MNEMONIC_SCENARIO:?}" stage="" stdin_value="" argument=""' \
    'printf '\''cardano-address'\'' >> "${CNTOOLS_MNEMONIC_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_MNEMONIC_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_MNEMONIC_VECTOR_LOG:?}"' \
    'case "$*" in' \
    '  "recovery-phrase generate")' \
    '    stage=generate' \
    '    case "${scenario}" in' \
    '      generate-failure) printf '\''simulated generator secret diagnostic\n'\'' >&2; exit 31 ;;' \
    '      malformed-mnemonic) printf '\''alpha bravo cactus\n'\''; exit 0 ;;' \
    '      oversized-mnemonic) printf '\''%010000d alpha bravo cactus delta ember forest galaxy harbor ivory jungle kitten lemon mango nectar ocean panda quartz river solar tiger uncle velvet willow\n'\'' 0; exit 0 ;;' \
    '      *) printf '\''%s\n'\'' "${CNTOOLS_MNEMONIC_WORDS:?}"; exit 0 ;;' \
    '    esac' \
    '    ;;' \
    '  "-v") printf '\''3.2.0\n'\''; exit 0 ;;' \
    '  "key from-recovery-phrase Shelley")' \
    '    IFS= read -r stdin_value || true' \
    '    [[ "${scenario}" != from-recovery-failure ]] || { printf '\''simulated root derivation failure: %s\n'\'' "${stdin_value}" >&2; exit 32; }' \
    '    [[ "${stdin_value}" == "${CNTOOLS_MNEMONIC_WORDS:?}" || "${scenario}" == oversized-mnemonic ]] || exit 96' \
    '    printf '\''root_xprv_fixture\n'\''; exit 0' \
    '    ;;' \
    '  key\ child\ *)' \
    '    stage="child:${3:-}"; IFS= read -r stdin_value || true' \
    '    [[ "${stdin_value}" == root_xprv_fixture ]] || exit 96' \
    '    if [[ "${scenario}" == child-failure && "${3:-}" == *"/3/"* ]]; then printf '\''simulated child failure: %s\n'\'' "${stdin_value}" >&2; exit 33; fi' \
    '    printf '\''xprv_%s\n'\'' "${3//\//_}"; exit 0' \
    '    ;;' \
    '  key\ public*)' \
    '    IFS= read -r stdin_value || true' \
    '    if [[ "${scenario}" == public-failure && "${stdin_value}" == *"_4_"* ]]; then printf '\''simulated public failure: %s\n'\'' "${stdin_value}" >&2; exit 34; fi' \
    '    printf '\''xpub_%s\n'\'' "${stdin_value}"; exit 0' \
    '    ;;' \
    '  address\ payment*) IFS= read -r stdin_value || true; printf '\''%s\n'\'' "${CNTOOLS_MNEMONIC_PAYMENT_ADDRESS:?}"; exit 0 ;;' \
    '  address\ delegation*) IFS= read -r stdin_value || true; printf '\''%s\n'\'' "${CNTOOLS_MNEMONIC_BASE_ADDRESS:?}"; exit 0 ;;' \
    '  "address inspect") IFS= read -r stdin_value || true; printf '\''{"spending_key_hash":"fixture"}\n'\''; exit 0 ;;' \
    'esac' \
    'printf '\''unexpected cardano-address vector: %s\n'\'' "$*" >&2' \
    'exit 96' \
    > "${FAKE_BIN}/cardano-address"
  chmod 0755 "${FAKE_BIN}/cardano-address"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'stdin_value=""; IFS= read -r stdin_value || true' \
    'printf '\''bech32'\'' >> "${CNTOOLS_MNEMONIC_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_MNEMONIC_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_MNEMONIC_VECTOR_LOG:?}"' \
    '[[ "${CNTOOLS_MNEMONIC_SCENARIO:?}" != bech32-failure ]] || exit 35' \
    'if [[ $# -eq 1 && "$1" == addr_test ]]; then printf '\''%s\n'\'' "${stdin_value}"; else printf '\''%0128d'\'' 0; fi' \
    > "${FAKE_BIN}/bech32"
  chmod 0755 "${FAKE_BIN}/bech32"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_MNEMONIC_SCENARIO:?}" out="" previous="" argument="" stage=""' \
    'for argument in "$@"; do [[ "${previous}" == --out-file || "${previous}" == --verification-key-file ]] && out="${argument}"; previous="${argument}"; done' \
    'case "$*" in' \
    '  *"key verification-key"*) stage="evkey:${out##*/}" ;;' \
    '  *"key non-extended-key"*) stage="vkey:${out##*/}" ;;' \
    '  *"stake-address build"*) stage=reward-address ;;' \
    '  *"address build"*"--stake-verification-key-file"*) stage=base-address ;;' \
    '  *"address build"*) stage=payment-address ;;' \
    '  *"stake-address key-hash"*) stage="credential:${out##*/}" ;;' \
    '  *"address key-hash"*) stage="credential:${out##*/}" ;;' \
    '  *) printf '\''unexpected cardano-cli vector: %s\n'\'' "$*" >&2; exit 96 ;;' \
    'esac' \
    'printf '\''cardano-cli'\'' >> "${CNTOOLS_MNEMONIC_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_MNEMONIC_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_MNEMONIC_VECTOR_LOG:?}"' \
    'case "${scenario}:${stage}" in' \
    '  payment-evkey-failure:evkey:payment.evkey|late-vkey-failure:vkey:multisig-drep.vkey|base-build-failure:base-address|payment-build-failure:payment-address|reward-build-failure:reward-address|credential-failure:credential:payment.cred)' \
    '    printf '\''simulated %s failure\n'\'' "${stage}"; exit 36 ;;' \
    'esac' \
    '[[ -n "${out}" ]] || exit 96' \
    'mkdir -p -- "${out%/*}"' \
    'case "${stage}" in' \
    '  base-address) [[ "${scenario}" == base-mismatch ]] && printf '\''addr_test1mismatch\n'\'' > "${out}" || printf '\''%s\n'\'' "${CNTOOLS_MNEMONIC_BASE_ADDRESS:?}" > "${out}" ;;' \
    '  payment-address) printf '\''%s\n'\'' "${CNTOOLS_MNEMONIC_PAYMENT_ADDRESS:?}" > "${out}" ;;' \
    '  reward-address) printf '\''%s\n'\'' "${CNTOOLS_MNEMONIC_REWARD_ADDRESS:?}" > "${out}" ;;' \
    '  credential:*) printf '\''credential_%s\n'\'' "${out##*/}" > "${out}" ;;' \
    '  *) printf '\''{"type":"fixture","description":"fixture","cborHex":"00"}\n'\'' > "${out}" ;;' \
    'esac' \
    > "${FAKE_BIN}/cardano-cli"
  chmod 0755 "${FAKE_BIN}/cardano-cli"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s\n'\'' "${0##*/}" >> "${CNTOOLS_MNEMONIC_NETWORK_LOG:?}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
# shellcheck source=/dev/null
. "${GOVERNANCE_QUERY_SOURCE}"
# shellcheck source=/dev/null
. "${WALLET_QUERY_SOURCE}"
# shellcheck source=/dev/null
. "${WALLET_CREATE_SOURCE}"

println() {
  local level="${1:-}"
  shift || true
  case "${level}" in
    ACTION) printf 'action-log:%s\n' "$*" >> "${EVENT_LOG:?}" ;;
    LOG) printf 'runtime-log:%s\n' "$*" >> "${EVENT_LOG:?}" ;;
    OFF|DEBUG|INFO|ERROR) printf '%b\n' "$@" ;;
    *) printf '%b\n' "${level}" "$@" ;;
  esac
}

clear() {
  if [[ "${CAPTURE_ACTIVE:-N}" == Y && "${END_ON_CLEAR:-N}" == Y ]]; then
    printf '__CNTOOLS_WALLET_NEW_MNEMONIC_END__\n'
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

  case "${1:-}" in
    '[w] Wallet') menu=main ;;
    '[n] New') menu=wallet ;;
    '[m] Mnemonic') menu=wallet-new ;;
    *) fail "unexpected menu: ${1:-<empty>}" ;;
  esac
  [[ -n "${choice}" ]] || fail "${menu} menu exhausted choices"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == wallet-new:m ]]; then
        CAPTURE_ACTIVE=Y
        printf '__CNTOOLS_WALLET_NEW_MNEMONIC_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} unavailable in ${menu} menu"
}

getAnswerAnyCust() {
  local variable="${1:-}" prompt="${*: -1}" value=""

  printf 'prompt:%s:%s\n' "${variable}" "${prompt}" >> "${EVENT_LOG:?}"
  case "${variable}" in
    wallet_name)
      case "${CNTOOLS_MNEMONIC_SCENARIO:?}" in
        empty-name|prompt-cancel) value="" ;;
        existing-wallet) value=existing ;;
        *) value='My Wallet' ;;
      esac
      ;;
    acct_idx)
      case "${CNTOOLS_MNEMONIC_SCENARIO:?}" in
        invalid-account) value='1 + 1' ;;
        custom-success) value=7 ;;
        *) value="" ;;
      esac
      ;;
    key_idx)
      case "${CNTOOLS_MNEMONIC_SCENARIO:?}" in
        invalid-key) value=08x ;;
        custom-success) value=9 ;;
        *) value="" ;;
      esac
      ;;
    *) fail "unexpected prompt variable: ${variable}" ;;
  esac
  printf -v "${variable}" '%s' "${value}"
  [[ "${CNTOOLS_MNEMONIC_SCENARIO}" != prompt-cancel ]]
}

isNumber() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
cmdAvailable() { command -v -- "${1:-}" >/dev/null 2>&1; }

safeDel() {
  local target="${1:-}"
  printf 'action:safeDel:%s\n' "${target}" >> "${EVENT_LOG:?}"
  rm -rf -- "${target}"
}

waitToProceed() {
  printf 'action:mnemonic:%s\n' \
    "$([[ -n "${mnemonic:-}" ]] && printf present || printf unset)" \
    >> "${EVENT_LOG:?}"
  printf 'action:root-key:%s\n' \
    "$([[ -n "${root_prv:-}" ]] && printf present || printf unset)" \
    >> "${EVENT_LOG:?}"
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    printf '__CNTOOLS_WALLET_NEW_MNEMONIC_END__\n'
    CAPTURE_ACTIVE=N
  fi
  return 0
}

myExit() {
  local status="${1:-0}" message="${2:-}"
  printf 'exit:%s:%s\n' "${status}" "${message}" >> "${EVENT_LOG:?}"
  [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
    fail 'public traversal did not consume all menu choices'
  exit "${status}"
}

scenario_mode() {
  case "$1" in
    success-local|empty-name|generate-failure|payment-evkey-failure|base-build-failure)
      printf 'LOCAL\n' ;;
    custom-success|missing-tools|invalid-account|late-vkey-failure|payment-build-failure)
      printf 'LIGHT\n' ;;
    *) printf 'OFFLINE\n' ;;
  esac
}

normalize_file() {
  local source="$1" target="$2" runtime_root="$3"
  sed \
    -e "s#${runtime_root}#<runtime>#g" \
    -e "s#${TEST_ROOT}#<test>#g" \
    -e 's/[[:space:]]\+$//' \
    "${source}" > "${target}"
}

extract_action_output() {
  local source="$1" target="$2"
  [[ "$(grep -c '^__CNTOOLS_WALLET_NEW_MNEMONIC_BEGIN__$' "${source}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_WALLET_NEW_MNEMONIC_END__$' "${source}" || true)" == 1 ]] ||
    fail 'wallet-new-mnemonic output markers changed'
  awk '
    $0 == "__CNTOOLS_WALLET_NEW_MNEMONIC_BEGIN__" { capture=1; next }
    $0 == "__CNTOOLS_WALLET_NEW_MNEMONIC_END__" { exit }
    capture { print }
  ' "${source}" > "${target}"
}

scenario_failure_stage() {
  case "$1" in
    missing-tools) printf 'missing-tools\n' ;;
    generate-failure|malformed-mnemonic|oversized-mnemonic|invalid-account|invalid-key|from-recovery-failure|child-failure|public-failure|bech32-failure|payment-evkey-failure|late-vkey-failure|base-build-failure|payment-build-failure|reward-build-failure|credential-failure|base-mismatch)
      printf '%s\n' "$1" ;;
    *) printf 'none\n' ;;
  esac
}

run_case() {
  local scenario="$1" mode="" case_root=""
  case_root="${TEST_ROOT}/cases/${scenario}"
  local runtime_root="${case_root}/runtime" capture_root="${case_root}/capture"
  local wallet_root="${runtime_root}/wallet" temp_root="${runtime_root}/tmp"
  local full_stdout="${capture_root}/full.stdout" stderr_raw="${capture_root}/raw.stderr"
  local action_raw="${capture_root}/action.raw" action_output="${capture_root}/action.stdout"
  local stderr_output="${capture_root}/stderr" event_raw="${capture_root}/raw.events"
  local events="${capture_root}/events" vector_raw="${capture_root}/raw.vectors"
  local vectors="${capture_root}/vectors" network_log="${capture_root}/network"
  local before="${capture_root}/before.tree" after="${capture_root}/after.tree"
  local status=0 wallet_path="${wallet_root}/My_Wallet" index=0 word=""
  local -a expected_words=()

  mode="$(scenario_mode "${scenario}")"
  mkdir -p -- "${runtime_root}/home" "${wallet_root}" "${temp_root}" \
    "${runtime_root}/pool" "${runtime_root}/asset" "${capture_root}"
  if [[ "${scenario}" == existing-wallet ]]; then
    mkdir -p -- "${wallet_root}/existing"
    printf 'existing sentinel\n' > "${wallet_root}/existing/sentinel"
  fi
  tree_snapshot "${runtime_root}" "${before}" || fail "${scenario} pre-snapshot"
  : > "${event_raw}"; : > "${vector_raw}"; : > "${network_log}"

  if (
    set +e; set +u; set +o pipefail; umask 022
    export LC_ALL=C TZ=UTC
    export CNTOOLS_MNEMONIC_SCENARIO="${scenario}"
    export CNTOOLS_MNEMONIC_WORDS="${MNEMONIC}"
    export CNTOOLS_MNEMONIC_BASE_ADDRESS="${BASE_ADDRESS}"
    export CNTOOLS_MNEMONIC_PAYMENT_ADDRESS="${PAYMENT_ADDRESS}"
    export CNTOOLS_MNEMONIC_REWARD_ADDRESS="${REWARD_ADDRESS}"
    export CNTOOLS_MNEMONIC_VECTOR_LOG="${vector_raw}"
    export CNTOOLS_MNEMONIC_NETWORK_LOG="${network_log}"
    if [[ "${scenario}" == missing-tools ]]; then
      PATH="${BASE_PATH}"
      cardano_address_saved="${FAKE_BIN}/cardano-address"
      mv -- "${cardano_address_saved}" "${cardano_address_saved}.held"
      trap 'mv -- "${cardano_address_saved}.held" "${cardano_address_saved}"' EXIT
    else
      PATH="${FAKE_BIN}:${BASE_PATH}"
    fi
    export PATH
    HOME="${runtime_root}/home"; NODE_HOME="${runtime_root}/home"
    TMP_DIR="${temp_root}"; WALLET_FOLDER="${wallet_root}"
    POOL_FOLDER="${runtime_root}/pool"; ASSET_FOLDER="${runtime_root}/asset"
    CCLI="${FAKE_BIN}/cardano-cli"; NETWORK_IDENTIFIER='--testnet-magic 42'
    NWMAGIC=42; CNTOOLS_MODE="${mode}"; CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=characterized; NETWORK_NAME=Preview; ADVANCED_MODE=true
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"; price_now=""; slotnum=1000
    WALLET_DERIVATION_PATH_FILENAME=derivation.path
    WALLET_PAY_SK_FILENAME=payment.skey; WALLET_PAY_VK_FILENAME=payment.vkey
    WALLET_STAKE_SK_FILENAME=stake.skey; WALLET_STAKE_VK_FILENAME=stake.vkey
    WALLET_GOV_DREP_SK_FILENAME=drep.skey; WALLET_GOV_DREP_VK_FILENAME=drep.vkey
    WALLET_GOV_CC_COLD_SK_FILENAME=cc-cold.skey; WALLET_GOV_CC_COLD_VK_FILENAME=cc-cold.vkey
    WALLET_GOV_CC_HOT_SK_FILENAME=cc-hot.skey; WALLET_GOV_CC_HOT_VK_FILENAME=cc-hot.vkey
    WALLET_MULTISIG_PREFIX=multisig-
    WALLET_BASE_ADDR_FILENAME=base.addr; WALLET_PAY_ADDR_FILENAME=payment.addr
    WALLET_STAKE_ADDR_FILENAME=reward.addr
    WALLET_PAY_CRED_FILENAME=payment.cred; WALLET_STAKE_CRED_FILENAME=stake.cred
    WALLET_PAY_SCRIPT_FILENAME=payment.script; WALLET_STAKE_SCRIPT_FILENAME=stake.script
    WALLET_PAY_SCRIPT_CRED_FILENAME=payment-script.cred
    WALLET_STAKE_SCRIPT_CRED_FILENAME=stake-script.cred
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" FG_FG_LBLUE="" NC=""
    EVENT_LOG="${event_raw}"; CAPTURE_ACTIVE=N; END_ON_CLEAR=N
    unset mnemonic words root_prv payment_xprv stake_xprv base_addr pay_addr
    CHOICES=(w n m b h q); CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_raw}"; then status=0; else status=$?; fi
  [[ "${status}" == 0 ]] || fail "${scenario} traversal returned ${status}"

  extract_action_output "${full_stdout}" "${action_raw}"
  normalize_file "${action_raw}" "${action_output}" "${runtime_root}"
  normalize_file "${stderr_raw}" "${stderr_output}" "${runtime_root}"
  normalize_file "${event_raw}" "${events}" "${runtime_root}"
  normalize_file "${vector_raw}" "${vectors}" "${runtime_root}"
  tree_snapshot "${runtime_root}" "${after}" || fail "${scenario} post-snapshot"

  grep -Fq ' >> WALLET >> NEW >> MNEMONIC' "${action_output}" ||
    fail "${scenario} lost mnemonic header"
  [[ ! -s "${network_log}" ]] || fail "${scenario} attempted network access"
  for checked in "${events}" "${vectors}" "${network_log}"; do
    ! grep -Fq -- "${MNEMONIC}" "${checked}" ||
      fail "${scenario} leaked mnemonic outside intended stdout"
    ! grep -Fq -- root_xprv_fixture "${checked}" ||
      fail "${scenario} leaked root private key"
  done
  case "${scenario}" in
    from-recovery-failure)
      grep -Fq -- "${MNEMONIC}" "${stderr_output}" ||
        fail 'from-recovery failure no longer exposes tool-echoed mnemonic'
      ;;
    child-failure)
      grep -Fq -- root_xprv_fixture "${stderr_output}" ||
        fail 'child failure no longer exposes tool-echoed root private key'
      ;;
    public-failure)
      grep -Fq -- xprv_ "${stderr_output}" ||
        fail 'public-key failure no longer exposes tool-echoed child private key'
      ;;
    *)
      ! grep -Fq -- "${MNEMONIC}" "${stderr_output}" ||
        fail "${scenario} unexpectedly leaked mnemonic to stderr"
      ! grep -Eq 'root_xprv_fixture|xprv_' "${stderr_output}" ||
        fail "${scenario} unexpectedly leaked private key to stderr"
      ;;
  esac
  if [[ "${scenario}" == success-local || "${scenario}" == custom-success ||
        "${scenario}" == success-offline ]]; then
    IFS=' ' read -r -a expected_words <<< "${MNEMONIC}"
    for (( index=0; index<${#expected_words[@]}; index++ )); do
      word="${expected_words[index]}"
      grep -Eq "(^|[[:space:]])$((index + 1)): ${word}([[:space:]]|$)" \
        "${action_output}" ||
        fail "${scenario} lost or reordered mnemonic word $((index + 1))"
    done
    [[ -f "${wallet_path}/derivation.path" ]] || fail "${scenario} missing derivation path"
    if [[ "${scenario}" == custom-success ]]; then
      [[ "$(< "${wallet_path}/derivation.path")" == '1852H/1815H/7H/x/9' ]] ||
        fail 'custom derivation path changed'
    else
      [[ "$(< "${wallet_path}/derivation.path")" == '1852H/1815H/0H/x/0' ]] ||
        fail "${scenario} default derivation path changed"
    fi
    [[ -f "${wallet_path}/base.addr" && "$(< "${wallet_path}/base.addr")" == "${BASE_ADDRESS}" &&
       -f "${wallet_path}/payment.addr" && "$(< "${wallet_path}/payment.addr")" == "${PAYMENT_ADDRESS}" &&
       -f "${wallet_path}/reward.addr" && "$(< "${wallet_path}/reward.addr")" == "${REWARD_ADDRESS}" ]] ||
      fail "${scenario} address cache state changed"
  fi
  case "${scenario}" in
    empty-name|prompt-cancel) [[ ! -e "${wallet_path}" ]] || fail "${scenario} created wallet" ;;
    existing-wallet) grep -Fxq 'existing sentinel' "${wallet_root}/existing/sentinel" || fail 'existing wallet mutated' ;;
    missing-tools|invalid-key)
      [[ -d "${wallet_path}" && -z "$(find "${wallet_path}" -mindepth 1 -print -quit)" ]] ||
        fail "${scenario} empty-wallet residue changed"
      ;;
    generate-failure|malformed-mnemonic|from-recovery-failure|payment-evkey-failure|late-vkey-failure|base-build-failure|base-mismatch)
      [[ ! -e "${wallet_path}" ]] || fail "${scenario} wallet cleanup changed"
      ;;
  esac

  if [[ "${scenario}" == oversized-mnemonic ]]; then
    [[ -f "${wallet_path}/derivation.path" &&
       "$(wc -c < "${action_output}" | tr -d ' ')" -gt 10000 ]] ||
      fail 'oversized 24-word generator output is no longer accepted/displayed'
  fi
  if [[ "${scenario}" == invalid-account ]]; then
    [[ -f "${wallet_path}/derivation.path" &&
       "$(< "${wallet_path}/derivation.path")" == '1852H/1815H/1 + 1H/x/0' ]] ||
      fail 'word-split account-index acceptance changed'
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${scenario}" \
    "$(hash_file "${action_output}")" "$(hash_file "${stderr_output}")" \
    "$(hash_file "${events}")" "$(hash_file "${vectors}")" \
    "$(hash_file "${after}")"
}

write_fake_commands

case_output="${TEST_ROOT}/case-hashes.tsv"
: > "${case_output}"
for scenario in \
  empty-name prompt-cancel existing-wallet missing-tools generate-failure \
  malformed-mnemonic oversized-mnemonic invalid-account invalid-key \
  from-recovery-failure child-failure public-failure bech32-failure \
  payment-evkey-failure late-vkey-failure base-build-failure \
  payment-build-failure reward-build-failure credential-failure base-mismatch \
  success-local custom-success success-offline; do
  run_case "${scenario}" >> "${case_output}"
done

# Exact normalized stdout, stderr, navigation/event, command-vector, and final
# tree hashes. Semantic assertions above keep this from becoming a blind hash
# oracle while the table freezes every byte of the characterized contract.
expected_case_output="${TEST_ROOT}/expected-case-hashes.tsv"
cat > "${expected_case_output}" <<'EOF_EXPECTED_CASES'
empty-name	6900c8047e135fd7fd96e8986b471b4ddfed90f506198628429120ad80894542	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	0d53bbd00d258cf491e3a79b8319695e317927e64b13c073250f715d173a04e5	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	7eff0ea8e195ce653cf2266cdd96550b237c9704bac53fb15f0b9ba885d06fe1
prompt-cancel	6900c8047e135fd7fd96e8986b471b4ddfed90f506198628429120ad80894542	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	aefa8a792d10cd3a572e98e408a7e00a8308df51a88d93931264fab5d3cc5fa7	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	7eff0ea8e195ce653cf2266cdd96550b237c9704bac53fb15f0b9ba885d06fe1
existing-wallet	8312c92779c3f56255086ea7c9a500a63cd4a6513451d5f6b8a093c5c73bbc54	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	aefa8a792d10cd3a572e98e408a7e00a8308df51a88d93931264fab5d3cc5fa7	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	abb325314d854975ae347ca2435d6f33a6ff6ac18dbdc7accd127c68df5664e3
missing-tools	e1993cbacf8a86dd976562dffc3b2e37d8ba5ec80077fb418d987d12f5c80fba	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	2aca6be209afdaeb6890a61534a4685b5feaacf4d9a9fc3e7e9a3f97bc61066f	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	83a0eaddb6f1048100b85f291b4448cd999355f070435bfba6bd19a7de480d56
generate-failure	a1a44e2b2ae8347b186305ae3b54b8c2c1023b014c078c74de474126819c1c94	e1c7b3ff8a9d4f54f5ef0dbc033efff4d27d7073517de2e842df895e9f51401b	dd2557aedf9a2388f5ab519c1829226ddaded7166a94edb0fe97b482ad502d3e	1a4f0595628935c7fb396780e23def9efe56b4aae7dee64d2ec3659bfd3e5d44	7eff0ea8e195ce653cf2266cdd96550b237c9704bac53fb15f0b9ba885d06fe1
malformed-mnemonic	bd8ed61ded8a3252d34a525eba9ec89378f8d81f3dbb2d3c7a9ebc59f3b3c219	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	05e73cdfefa61b0583786d6fcb9e4f0d00385ce2c397a5207520c87846e03aea	1a4f0595628935c7fb396780e23def9efe56b4aae7dee64d2ec3659bfd3e5d44	7eff0ea8e195ce653cf2266cdd96550b237c9704bac53fb15f0b9ba885d06fe1
oversized-mnemonic	d76f5eca0b5c3ee4413598c9c0adf4583d640d17b594bb995710f7225e87a324	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	db835f8bf25ac359b565e945c0d78c9bbbb2df49e370122ed1bd66298df99de5	350a87dc83a8b4236e34114e558e14365cd11a8d1eae62794cac8ab34c08b973	e9a7c1fed558545914b394adaec83e244bf0c9edd2304387171442a30c052847
invalid-account	48c0abbec4b8fbb43643a6aaef7699f4c126ba3888e1f5fffa992cc931038748	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	d7f9138d977ee8ed1732b518a6066be827b8630ee6d4b1fb00c40c43bcad78fe	b35ca1d88a821672049247e1abadef5405c5872c28baa92176c3acedb8114b5c	43e973e850f1254aaf0383b8e10b8a4c7c029396175ae4e62f0fb9d84d076aec
invalid-key	fbca94d91dff371283d81be1bccb8cc1344ab2c9f1c151602daaeaee0c7a1323	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	555ae7469621338679a4fda46a2948d394cf37d3a0e0b3ad6434cb6cea17e5e1	1a4f0595628935c7fb396780e23def9efe56b4aae7dee64d2ec3659bfd3e5d44	83a0eaddb6f1048100b85f291b4448cd999355f070435bfba6bd19a7de480d56
from-recovery-failure	818f8a4bf01600900ee0d7bbd7b56732945e601c28ed8b930aeea12631dddb6c	396ee2a229f8b6bc436e840ee408127245505248d0b4bfc896a4efed8e3b9567	bb96d661c654b67849bbe36255ce8fe33f317ef4e89e0804c57efe0332828f9e	bb0b2cd9c8f6fe5a129970b667fcfe5f6e4ba035dddf9995dbae0dce97342d84	7eff0ea8e195ce653cf2266cdd96550b237c9704bac53fb15f0b9ba885d06fe1
child-failure	48c0abbec4b8fbb43643a6aaef7699f4c126ba3888e1f5fffa992cc931038748	6ee521cf3bd6fe47a85bc8e9958e782b4a61a1ba21a9d4569c57a5a16c72fab4	addd580e95e8c4e57bf0e064eeb39030f7685b521b7b0c6ba9295480cc4968e4	350a87dc83a8b4236e34114e558e14365cd11a8d1eae62794cac8ab34c08b973	e9a7c1fed558545914b394adaec83e244bf0c9edd2304387171442a30c052847
public-failure	48c0abbec4b8fbb43643a6aaef7699f4c126ba3888e1f5fffa992cc931038748	cf70bf117a2c709220fce91448b07bf5c58b1f7102683bbecba0ebb3cba87185	c99b4fcb40ac925f289c3be0989d3af3f2b606e3b7f2438c067742dc8638bf32	350a87dc83a8b4236e34114e558e14365cd11a8d1eae62794cac8ab34c08b973	e9a7c1fed558545914b394adaec83e244bf0c9edd2304387171442a30c052847
bech32-failure	48c0abbec4b8fbb43643a6aaef7699f4c126ba3888e1f5fffa992cc931038748	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	db835f8bf25ac359b565e945c0d78c9bbbb2df49e370122ed1bd66298df99de5	350a87dc83a8b4236e34114e558e14365cd11a8d1eae62794cac8ab34c08b973	3c2590c00d460c66306f071546bcbba04b8919098a9c3bc1810f20a3502bcb86
payment-evkey-failure	8b0112b79d7fc889bd449d72074a5ef0a76ddd0c890da6cf2cc8695829863939	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	f32b6bd5c5d71bd7f0e54391093faf7f41d4d9f1c2dd2b2de4de910589db8204	1bd1f637b77f226d183b491e4e7a4e0de399692b076cd53a5bf1b4316fcbc088	7eff0ea8e195ce653cf2266cdd96550b237c9704bac53fb15f0b9ba885d06fe1
late-vkey-failure	25b6cd432e64d312ff75ed4e3996cf755ed120e0438143f13584a460be3bb99b	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	521fe5c5e1a312615a67e70249c45e7808a2e0a3f9f44b01745e408722e7b847	5a2b4988229f38e9faf9a044f23227ff519a7bd3c216f3dbedf6acb0402b783a	7eff0ea8e195ce653cf2266cdd96550b237c9704bac53fb15f0b9ba885d06fe1
base-build-failure	c897cee922388e167fe83fbf17ac57346aa826087bcd335e028d8623e619a70f	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	2d13b70a7c12a3d3d752b955c5408d3957fce291e94cb9563ed7a9776bdb4ae4	350a87dc83a8b4236e34114e558e14365cd11a8d1eae62794cac8ab34c08b973	7eff0ea8e195ce653cf2266cdd96550b237c9704bac53fb15f0b9ba885d06fe1
payment-build-failure	7bb9b565d4ac25aa5d5474437e2400f9a6c6b859c62fa9ec8c0ea7bd1317099f	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	a49614aa409d175d0afcb730992f6f22de2bcf110124b9fd9c8277dca8496d9c	350a87dc83a8b4236e34114e558e14365cd11a8d1eae62794cac8ab34c08b973	56d936dbc8ddb43798d60255b1c4a0bb694d3fc9aa2694ff76f4fe2b4d4bf121
reward-build-failure	48c0abbec4b8fbb43643a6aaef7699f4c126ba3888e1f5fffa992cc931038748	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	1c0d764f4b1f1df287ade5a840c93f1867b8935f1e3b295fc2f83d9dd3567ce9	350a87dc83a8b4236e34114e558e14365cd11a8d1eae62794cac8ab34c08b973	b769807306b292a0d8ad8b473235b051c4cafff91aea57e91ec92b1e0855e8d7
credential-failure	48c0abbec4b8fbb43643a6aaef7699f4c126ba3888e1f5fffa992cc931038748	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	0b95f45baeb89b54ce1e3b8829fe46ffe80087b1de585a7b9153606937e6ee0f	a9aa1270e2d2c3ca5a9728024fd2e8306b58aae93d822666610a2d1c3d16a9f3	62754392c8fefc910bbabf95020d7fd8dd9318707ebf9ae1d1374050b76fdd71
base-mismatch	9c67bd96766610da31d17fc2b73c4c77d4c83493bcd7ed856aece48979b0731b	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	25dad1be3c766fb4f58dcd661f09043888c9e509f28566c3a03acaf329d2bb4a	350a87dc83a8b4236e34114e558e14365cd11a8d1eae62794cac8ab34c08b973	7eff0ea8e195ce653cf2266cdd96550b237c9704bac53fb15f0b9ba885d06fe1
success-local	48c0abbec4b8fbb43643a6aaef7699f4c126ba3888e1f5fffa992cc931038748	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	92fdc5dd7ef221e82c102b557e2e0fa8ff8bc6fc63400c7257ff96520aa277ea	350a87dc83a8b4236e34114e558e14365cd11a8d1eae62794cac8ab34c08b973	e9a7c1fed558545914b394adaec83e244bf0c9edd2304387171442a30c052847
custom-success	48c0abbec4b8fbb43643a6aaef7699f4c126ba3888e1f5fffa992cc931038748	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	b0573016cbcff09d157e66766d90ab6c5bfa2794306d04433c9f75371f1ac414	12f1fcb4f363e502b2daa14bd565e78bdf522b913d049bf02ddc57032a8b10b2	223f5211ec59c3a2fd2de4f1da146214d63b2e8df811c68bff73d85df435ed85
success-offline	48c0abbec4b8fbb43643a6aaef7699f4c126ba3888e1f5fffa992cc931038748	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	db835f8bf25ac359b565e945c0d78c9bbbb2df49e370122ed1bd66298df99de5	350a87dc83a8b4236e34114e558e14365cd11a8d1eae62794cac8ab34c08b973	e9a7c1fed558545914b394adaec83e244bf0c9edd2304387171442a30c052847
EOF_EXPECTED_CASES
assert_files_equal "${case_output}" "${expected_case_output}" \
  'exact normalized wallet-new-mnemonic case contract'

# The immutable 23-case table above remains the legacy fingerprint. Exercise
# the prepared modular action separately against an exact phase-contract shim;
# the controller and payload manifest intentionally remain unbound here.
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/registry.sh
. "${REGISTRY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/context.sh
. "${CONTEXT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/result.sh
. "${RESULT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/modules/root/wallet/new/mnemonic/action.sh
. "${ACTION_SOURCE}"

println() {
  local level="${1:-}"
  shift || true
  case "${level}" in
    ERROR) builtin printf '%s\n' "$@" >&2 ;;
    OFF|DEBUG|INFO) builtin printf '%s\n' "$@" ;;
    ACTION|LOG) return 0 ;;
    *) builtin printf '%s\n' "${level}" "$@" ;;
  esac
}

clear() {
  builtin printf 'ui:clear\n' >> "${DIRECT_EVENT_LOG:?}"
}

getAnswerAnyCust() {
  local output_variable="${1:-}" prompt="${*: -1}" kind="" value=""

  case "${prompt}" in
    Name\ of\ wallet*) kind=name; value=fixture_wallet ;;
    'Account (default: 0)') kind=account; value=7 ;;
    'Key index (default: 0)') kind=key; value=9 ;;
    *) fail "unexpected direct mnemonic prompt: ${prompt}" ;;
  esac
  builtin printf 'ui:prompt:%s\n' "${kind}" >> "${DIRECT_EVENT_LOG:?}"
  case "${DIRECT_SCENARIO:?}:${kind}" in
    cancel-name:name|cancel-account:account|cancel-key:key) return 1 ;;
  esac
  builtin printf -v "${output_variable}" '%s' "${value}"
}

select_opt() {
  [[ $# == 3 && "${1:-}" == '[n] Not yet' &&
     "${2:-}" == '[y] I have safely recorded the recovery phrase' &&
     "${3:-}" == '[Esc] Cancel' ]] || return 70
  case "${DIRECT_SCENARIO:?}" in
    ack-cancel|cancel-abort-failure|signal-abort)
      builtin printf 'ui:ack:cancel\n' >> "${DIRECT_EVENT_LOG:?}"
      return 0
      ;;
    signal-precommit)
      builtin printf 'ui:ack:signal\n' >> "${DIRECT_EVENT_LOG:?}"
      kill -TERM "${BASHPID}"
      return 2
      ;;
    *)
      builtin printf 'ui:ack:yes\n' >> "${DIRECT_EVENT_LOG:?}"
      return 1
      ;;
  esac
}

waitToProceed() {
  builtin printf 'ui:wait\n' >> "${DIRECT_EVENT_LOG:?}"
  return 0
}

printWalletInfo() {
  if [[ "${DIRECT_SCENARIO:?}" == signal-postcommit ]]; then
    builtin printf 'ui:info:signal\n' >> "${DIRECT_EVENT_LOG:?}"
    kill -TERM "${BASHPID}"
    return 0
  fi
  builtin printf 'ui:info\n' >> "${DIRECT_EVENT_LOG:?}"
}

_cntools_compatibility_wallet_mnemonic_run() {
  local phase="${1:-}" phrase_name="${2:-}" state_name="${3:-}"
  local base_name="${4:-}" pay_name="${5:-}" reward_name="${6:-}"
  local state_path="" destination="" variable_name=""
  local -A seen_names=()

  for variable_name in "${phrase_name}" "${state_name}"; do
    [[ "${variable_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
       -z "${seen_names[${variable_name}]+set}" ]] || return 64
    seen_names["${variable_name}"]=Y
  done
  [[ "${phrase_name}" == wallet_new_mnemonic_phrase &&
     "${state_name}" == wallet_new_mnemonic_state ]] || return 64
  case "${phase}" in
    prepare|publish)
      [[ $# == 6 && "${base_name}" == base_addr &&
         "${pay_name}" == pay_addr && "${reward_name}" == reward_addr ]] ||
        return 64
      for variable_name in "${base_name}" "${pay_name}" "${reward_name}"; do
        [[ "${variable_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
           -z "${seen_names[${variable_name}]+set}" ]] || return 64
        seen_names["${variable_name}"]=Y
      done
      ;;
    acknowledge|abort) [[ $# == 3 ]] || return 64 ;;
    *) return 64 ;;
  esac
  builtin printf 'helper:%s:%s\n' "${phase}" "$#" \
    >> "${DIRECT_EVENT_LOG:?}"

  case "${phase}" in
    prepare)
      [[ -z "${!phrase_name}" && -z "${!state_name}" &&
         -z "${!base_name}" && -z "${!pay_name}" &&
         -z "${!reward_name}" && "${wallet_name}" == fixture_wallet &&
         "${acct_idx}" == 7 && "${key_idx}" == 9 &&
         "${NETWORK_IDENTIFIER}" == '--testnet-magic 42' ]] || return 70
      state_path="${DIRECT_PRIVATE_ROOT:?}/mnemonic-state-token"
      mkdir -- "${state_path}" || return 70
      chmod 0700 "${state_path}" || return 70
      builtin printf 'prepared\n' > "${state_path}/prepared"
      chmod 0600 "${state_path}/prepared" || return 70
      builtin printf -v "${phrase_name}" '%s' "${MNEMONIC}"
      builtin printf -v "${state_name}" '%s' "${state_path}"
      if [[ "${DIRECT_SCENARIO:?}" == signal-prepare ]]; then
        kill -TERM "${BASHPID}"
      fi
      case "${DIRECT_SCENARIO:?}" in
        prepare-operational|prepare-invariant)
          rm -rf -- "${state_path}"
          builtin printf -v "${phrase_name}" '%s' ''
          builtin printf -v "${state_name}" '%s' ''
          [[ "${DIRECT_SCENARIO}" == prepare-operational ]] && return 1
          return 70
          ;;
        malformed-phrase)
          builtin printf -v "${phrase_name}" '%s' 'alpha bravo cactus'
          ;;
      esac
      ;;
    acknowledge)
      state_path="${!state_name}"
      [[ "${!phrase_name}" == "${MNEMONIC}" &&
         -d "${state_path}" && -f "${state_path}/prepared" ]] || return 70
      case "${DIRECT_SCENARIO:?}" in
        acknowledge-operational) return 1 ;;
        acknowledge-invariant) return 70 ;;
        signal-phase-failure-abort) return 1 ;;
      esac
      builtin printf 'acknowledged\n' > "${state_path}/acknowledged"
      chmod 0600 "${state_path}/acknowledged" || return 70
      if [[ "${DIRECT_SCENARIO}" == signal-acknowledge ]]; then
        kill -TERM "${BASHPID}"
      fi
      ;;
    publish)
      state_path="${!state_name}"
      [[ "${!phrase_name}" == "${MNEMONIC}" &&
         -d "${state_path}" && -f "${state_path}/acknowledged" ]] || return 70
      case "${DIRECT_SCENARIO:?}" in
        publish-operational|publish-invariant)
          rm -rf -- "${state_path}"
          builtin printf -v "${phrase_name}" '%s' ''
          builtin printf -v "${state_name}" '%s' ''
          [[ "${DIRECT_SCENARIO}" == publish-operational ]] && return 1
          return 70
          ;;
      esac
      destination="${WALLET_FOLDER:?}/${wallet_name}"
      mkdir -- "${destination}" || return 70
      chmod 0700 "${destination}" || return 70
      builtin printf 'published\n' > "${destination}/wallet.marker"
      chmod 0600 "${destination}/wallet.marker" || return 70
      if [[ "${DIRECT_SCENARIO}" == signal-publish-midstate ]]; then
        builtin printf -v "${base_name}" '%s' "${BASE_ADDRESS}"
        builtin printf -v "${pay_name}" '%s' "${PAYMENT_ADDRESS}"
        builtin printf -v "${reward_name}" '%s' "${REWARD_ADDRESS}"
        kill -TERM "${BASHPID}"
        return 70
      fi
      rm -rf -- "${state_path}"
      if [[ "${DIRECT_SCENARIO}" == address-network-mismatch ]]; then
        builtin printf -v "${base_name}" '%s' 'addr1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
        builtin printf -v "${pay_name}" '%s' 'addr1vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv'
        builtin printf -v "${reward_name}" '%s' 'stake1ssssssssssssssssssssssssssssssssssssss'
      else
        builtin printf -v "${base_name}" '%s' "${BASE_ADDRESS}"
        builtin printf -v "${pay_name}" '%s' "${PAYMENT_ADDRESS}"
        builtin printf -v "${reward_name}" '%s' "${REWARD_ADDRESS}"
      fi
      builtin printf -v "${phrase_name}" '%s' ''
      builtin printf -v "${state_name}" '%s' ''
      case "${DIRECT_SCENARIO}" in
        signal-publish-cleared-partial)
          builtin printf -v "${pay_name}" '%s' ''
          builtin printf -v "${reward_name}" '%s' ''
          kill -TERM "${BASHPID}"
          return 70
          ;;
        signal-publish-return) kill -TERM "${BASHPID}" ;;
        publish-favorable-nonzero) return 70 ;;
      esac
      ;;
    abort)
      state_path="${!state_name}"
      DIRECT_ABORT_ATTEMPTS=$(( ${DIRECT_ABORT_ATTEMPTS:-0} + 1 ))
      if [[ "${DIRECT_SCENARIO:?}" == cancel-abort-failure &&
            "${DIRECT_ABORT_ATTEMPTS}" == 1 ]]; then
        [[ "${!phrase_name}" == "${MNEMONIC}" &&
           -n "${state_path}" && -d "${state_path}" ]] || return 70
        return 70
      fi
      if [[ "${DIRECT_SCENARIO}" == cancel-abort-failure &&
            "${DIRECT_ABORT_ATTEMPTS}" == 2 ]]; then
        [[ -z "${!phrase_name}" &&
           -n "${state_path}" && -d "${state_path}" ]] || return 70
      fi
      if [[ ( "${DIRECT_SCENARIO}" == signal-abort ||
              "${DIRECT_SCENARIO}" == signal-phase-failure-abort ) &&
            "${DIRECT_ABORT_ATTEMPTS}" == 1 ]]; then
        kill -TERM "${BASHPID}"
      fi
      if [[ -n "${state_path}" ]]; then
        rm -rf -- "${state_path}"
        rm -rf -- "${WALLET_FOLDER:?}/${wallet_name}"
      fi
      builtin printf -v "${phrase_name}" '%s' ''
      builtin printf -v "${state_name}" '%s' ''
      ;;
  esac
}

write_direct_expected_events() {
  local scenario="$1" target="$2"

  : > "${target}"
  case "${scenario}" in
    missing-helper|network-mismatch|magic-mismatch) return 0 ;;
  esac
  builtin printf 'ui:clear\nui:prompt:name\n' >> "${target}"
  [[ "${scenario}" != cancel-name ]] || return 0
  builtin printf 'ui:prompt:account\n' >> "${target}"
  [[ "${scenario}" != cancel-account ]] || return 0
  builtin printf 'ui:prompt:key\n' >> "${target}"
  [[ "${scenario}" != cancel-key ]] || return 0
  builtin printf 'helper:prepare:6\n' >> "${target}"
  case "${scenario}" in
    signal-prepare)
      builtin printf 'helper:abort:3\n' >> "${target}"
      return 0
      ;;
    prepare-operational)
      builtin printf 'helper:abort:3\nui:wait\n' >> "${target}"
      return 0
      ;;
    prepare-invariant|malformed-phrase)
      builtin printf 'helper:abort:3\n' >> "${target}"
      return 0
      ;;
    ack-cancel)
      builtin printf 'ui:ack:cancel\nhelper:abort:3\n' >> "${target}"
      return 0
      ;;
    cancel-abort-failure|signal-abort)
      builtin printf \
        'ui:ack:cancel\nhelper:abort:3\nhelper:abort:3\n' >> "${target}"
      return 0
      ;;
    signal-precommit)
      builtin printf 'ui:ack:signal\nhelper:abort:3\n' >> "${target}"
      return 0
      ;;
    *) builtin printf 'ui:ack:yes\nhelper:acknowledge:3\n' >> "${target}" ;;
  esac
  case "${scenario}" in
    signal-acknowledge)
      builtin printf 'helper:abort:3\n' >> "${target}"
      return 0
      ;;
    signal-phase-failure-abort)
      builtin printf 'helper:abort:3\nhelper:abort:3\n' >> "${target}"
      return 0
      ;;
    acknowledge-operational)
      builtin printf 'helper:abort:3\nui:wait\n' >> "${target}"
      return 0
      ;;
    acknowledge-invariant)
      builtin printf 'helper:abort:3\n' >> "${target}"
      return 0
      ;;
  esac
  builtin printf 'helper:publish:6\n' >> "${target}"
  case "${scenario}" in
    publish-operational)
      builtin printf 'helper:abort:3\nui:wait\n' >> "${target}"
      ;;
    publish-invariant)
      builtin printf 'helper:abort:3\n' >> "${target}"
      ;;
    address-network-mismatch)
      builtin printf 'helper:abort:3\n' >> "${target}"
      ;;
    signal-publish-midstate|signal-publish-cleared-partial)
      builtin printf 'helper:abort:3\n' >> "${target}"
      ;;
    signal-publish-return) ;;
    signal-postcommit) builtin printf 'ui:info:signal\n' >> "${target}" ;;
    *) builtin printf 'ui:info\nui:wait\n' >> "${target}" ;;
  esac
}

run_direct_case() {
  local scenario="$1" mode="$2" expected_status="$3"
  local case_root="${TEST_ROOT}/direct/${scenario}"
  local runtime_root="${case_root}/runtime"
  local wallet_root="${runtime_root}/wallet"
  local private_root="${runtime_root}/private"
  local capture_root="${case_root}/capture"
  local context_file="${private_root}/context.json"
  local result_file="${private_root}/result.json"
  local stdout_file="${capture_root}/stdout"
  local stderr_file="${capture_root}/stderr"
  local event_file="${capture_root}/events"
  local network_file="${capture_root}/network"
  local expected_events="${capture_root}/expected.events"
  local direct_status=0 index=0 word="" display_expected=N
  local destination="${wallet_root}/fixture_wallet"
  local -a expected_words=()

  mkdir -p -- "${wallet_root}" "${private_root}" "${runtime_root}/home" \
    "${capture_root}"
  chmod 0700 "${wallet_root}" "${private_root}"
  write_context "${context_file}" "${mode}" "${runtime_root}/home"
  : > "${event_file}"
  : > "${network_file}"
  if (
    set +e; set +u; set +o pipefail
    export LC_ALL=C TZ=UTC
    DIRECT_SCENARIO="${scenario}"
    DIRECT_EVENT_LOG="${event_file}"
    DIRECT_PRIVATE_ROOT="${private_root}"
    DIRECT_ABORT_ATTEMPTS=0
    export CNTOOLS_MNEMONIC_NETWORK_LOG="${network_file}"
    PATH="${FAKE_BIN}:${BASE_PATH}"
    export PATH
    WALLET_FOLDER="${wallet_root}"
    CNTOOLS_MODE="${mode}"
    NETWORK_IDENTIFIER='--testnet-magic 42'
    NWMAGIC=42
    CCLI=cardano-cli
    FG_GREEN="" FG_YELLOW="" FG_LGRAY="" NC=""
    case "${scenario}" in
      network-mismatch)
        NETWORK_IDENTIFIER=--mainnet
        NWMAGIC=764824073
        ;;
      magic-mismatch) NWMAGIC=43 ;;
    esac
    if [[ "${scenario}" == missing-helper ]]; then
      unset -f _cntools_compatibility_wallet_mnemonic_run
    fi
    direct_status=0
    cntools_action_main "${context_file}" "${result_file}" || direct_status=$?
    exit "${direct_status}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    direct_status=0
  else
    direct_status=$?
  fi
  [[ "${direct_status}" == "${expected_status}" ]] ||
    fail "${scenario} direct status ${direct_status}, expected ${expected_status}"
  [[ ! -s "${network_file}" ]] ||
    fail "${scenario} attempted network access"
  write_direct_expected_events "${scenario}" "${expected_events}"
  assert_files_equal "${event_file}" "${expected_events}" \
    "${scenario} direct phase/UI sequence"

  case "${scenario}" in
    ack-cancel|cancel-abort-failure|signal-abort|signal-precommit|\
      signal-acknowledge|signal-phase-failure-abort|acknowledge-*|publish-*|\
      address-network-mismatch|signal-publish-midstate|\
      signal-publish-cleared-partial|success-*|signal-postcommit|\
      signal-publish-return) display_expected=Y ;;
  esac
  if [[ "${display_expected}" == Y ]]; then
    IFS=' ' read -r -a expected_words <<< "${MNEMONIC}"
    for ((index=0; index<${#expected_words[@]}; index++)); do
      word="${expected_words[index]}"
      grep -Eq "(^|[[:space:]])$((index + 1)): ${word}([[:space:]]|$)" \
        "${stdout_file}" || fail "${scenario} lost mnemonic word $((index + 1))"
    done
  else
    ! grep -Fq 'alpha' "${stdout_file}" ||
      fail "${scenario} displayed a phrase before successful preparation"
  fi
  for checked in "${stderr_file}" "${event_file}" "${context_file}"; do
    ! grep -Fq 'alpha' "${checked}" ||
      fail "${scenario} leaked mnemonic outside intended stdout"
    ! grep -Fq 'mnemonic-state-token' "${checked}" ||
      fail "${scenario} leaked the private state token"
  done
  ! grep -Fq 'mnemonic-state-token' "${stdout_file}" ||
    fail "${scenario} printed the private state token"
  [[ ! -e "${result_file}" &&
     ! -e "${private_root}/mnemonic-state-token" ]] ||
    fail "${scenario} left result or private transaction state"

  case "${scenario}" in
    success-*|signal-postcommit|signal-publish-return|\
      publish-favorable-nonzero)
      [[ -f "${destination}/wallet.marker" &&
         "$(< "${destination}/wallet.marker")" == published ]] ||
        fail "${scenario} did not preserve the published wallet"
      ;;
    address-network-mismatch|signal-publish-cleared-partial)
      [[ -f "${destination}/wallet.marker" &&
         "$(< "${destination}/wallet.marker")" == published ]] ||
        fail "${scenario} lost the bounded ambiguous publication"
      ;;
    *)
      [[ ! -e "${destination}" ]] ||
        fail "${scenario} published before acknowledgement/commit"
      ;;
  esac
  if [[ "${expected_status}" == 70 ]]; then
    grep -Fxq \
      'CNTools mnemonic wallet creation action failed validation.' \
      "${stderr_file}" || fail "${scenario} lost fixed validation diagnostic"
  fi
  case "${scenario}" in
    publish-favorable-nonzero)
      grep -Fxq \
        'WARNING: the mnemonic wallet was created despite an ambiguous helper return.' \
        "${stderr_file}" || fail 'favorable publish warning changed'
      ;;
    signal-publish-return|signal-postcommit)
      grep -Fxq \
        'WARNING: the mnemonic wallet was created, but final display was interrupted.' \
        "${stderr_file}" || fail "${scenario} committed signal warning changed"
      ;;
  esac
}

wrong_arity_stdout="${TEST_ROOT}/direct-wrong-arity.stdout"
wrong_arity_stderr="${TEST_ROOT}/direct-wrong-arity.stderr"
for arity in 0 1 3; do
  direct_status=0
  case "${arity}" in
    0) cntools_action_main > "${wrong_arity_stdout}" \
         2> "${wrong_arity_stderr}" || direct_status=$? ;;
    1) cntools_action_main one > "${wrong_arity_stdout}" \
         2> "${wrong_arity_stderr}" || direct_status=$? ;;
    3) cntools_action_main one two three > "${wrong_arity_stdout}" \
         2> "${wrong_arity_stderr}" || direct_status=$? ;;
  esac
  [[ "${direct_status}" == 64 && ! -s "${wrong_arity_stdout}" &&
     ! -s "${wrong_arity_stderr}" ]] ||
    fail "wrong-arity ${arity} contract changed"
done

run_direct_case cancel-name OFFLINE 0
run_direct_case cancel-account OFFLINE 0
run_direct_case cancel-key OFFLINE 0
run_direct_case network-mismatch OFFLINE 70
run_direct_case magic-mismatch OFFLINE 70
run_direct_case prepare-operational LOCAL 0
run_direct_case prepare-invariant LIGHT 70
run_direct_case signal-prepare OFFLINE 70
run_direct_case malformed-phrase OFFLINE 70
run_direct_case ack-cancel OFFLINE 0
run_direct_case cancel-abort-failure OFFLINE 70
run_direct_case signal-abort OFFLINE 70
run_direct_case signal-precommit OFFLINE 70
run_direct_case acknowledge-operational LOCAL 0
run_direct_case acknowledge-invariant LIGHT 70
run_direct_case signal-acknowledge OFFLINE 70
run_direct_case signal-phase-failure-abort OFFLINE 70
run_direct_case publish-operational LOCAL 0
run_direct_case publish-invariant LIGHT 70
run_direct_case address-network-mismatch OFFLINE 70
run_direct_case signal-publish-midstate OFFLINE 70
run_direct_case signal-publish-cleared-partial OFFLINE 70
run_direct_case publish-favorable-nonzero OFFLINE 0
run_direct_case success-local LOCAL 0
run_direct_case success-light LIGHT 0
run_direct_case success-offline OFFLINE 0
run_direct_case signal-publish-return OFFLINE 0
run_direct_case signal-postcommit OFFLINE 0
run_direct_case missing-helper OFFLINE 70

source_stdout="${TEST_ROOT}/action-source.stdout"
source_stderr="${TEST_ROOT}/action-source.stderr"
"${BASH}" -c '. "$1"; builtin declare -F cntools_action_main >/dev/null' \
  wallet-new-mnemonic-source "${ACTION_SOURCE}" > "${source_stdout}" \
  2> "${source_stderr}" || fail 'action source-only probe failed'
[[ ! -s "${source_stdout}" && ! -s "${source_stderr}" ]] ||
  fail 'sourcing the mnemonic action produced output'
direct_stdout="${TEST_ROOT}/action-direct.stdout"
direct_stderr="${TEST_ROOT}/action-direct.stderr"
direct_status=0
"${BASH}" "${ACTION_SOURCE}" > "${direct_stdout}" 2> "${direct_stderr}" ||
  direct_status=$?
[[ "${direct_status}" == 64 && ! -s "${direct_stdout}" ]] ||
  fail 'direct action execution guard changed'
grep -Fxq 'CNTools actions are launched by the dispatcher, not directly.' \
  "${direct_stderr}" || fail 'direct action execution diagnostic changed'

if grep -Eq 'cardano-address|bech32|recovery-phrase[[:space:]]+generate|key[[:space:]]+child|key[[:space:]]+public|address[[:space:]]+build' \
    "${ACTION_SOURCE}"; then
  fail 'modular mnemonic action duplicated derivation/tool implementation'
fi
[[ "$(wc -l < "${expected_case_output}" | tr -d '[:space:]')" == 23 ]] ||
  fail 'frozen legacy fingerprint no longer contains exactly 23 records'

# Structural boundary: the legacy controller remains authoritative while the
# dedicated phase-orchestrating action is prepared but intentionally unbound.
grep -Fq 'createMnemonicWallet || continue' "${CNTOOLS_SCRIPT}" ||
  fail 'inline wallet-new-mnemonic call changed'
if grep -Eq 'cntools_compatibility_dispatch_action[[:space:]]+wallet\.new\.mnemonic' \
    "${CNTOOLS_SCRIPT}"; then
  fail 'wallet-new-mnemonic unexpectedly routes to compatibility execution'
fi
grep -Fq 'mnemonic=$(cardano-address recovery-phrase generate)' \
  "${WALLET_CREATE_SOURCE}" || fail 'legacy mnemonic generation vector changed'
grep -Fq 'payment_xprv=$(cardano-address key child' \
  "${WALLET_CREATE_SOURCE}" || fail 'legacy unchecked child derivation changed'
grep -Fq 'getBaseAddress ${wallet_name}' "${WALLET_CREATE_SOURCE}" ||
  fail 'legacy unchecked address/cache sequence changed'
grep -Fq '_cntools_action_wallet_new_mnemonic_phase_run prepare' \
  "${ACTION_SOURCE}" || fail 'modular mnemonic prepare phase is missing'
grep -Fq '_cntools_action_wallet_new_mnemonic_phase_run acknowledge' \
  "${ACTION_SOURCE}" || fail 'modular mnemonic acknowledge phase is missing'
grep -Fq '_cntools_action_wallet_new_mnemonic_phase_run publish' \
  "${ACTION_SOURCE}" || fail 'modular mnemonic publish phase is missing'
grep -Fq '_cntools_compatibility_wallet_mnemonic_run abort' \
  "${ACTION_SOURCE}" || fail 'modular mnemonic abort phase is missing'

printf 'CNTools wallet-new-mnemonic characterization passed (23 legacy cases + hardened modular phase contract)\n'
