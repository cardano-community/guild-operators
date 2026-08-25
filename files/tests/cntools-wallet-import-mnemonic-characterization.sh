#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet-import-mnemonic characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
LEGACY_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f"
WALLET_CREATE_SOURCE="${LEGACY_ROOT}/050-wallet-create-registration.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet-import-mnemonic.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
BASE_ADDR='addr_test1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
PAY_ADDR='addr_test1pppppppppppppppppppppppppppppppppppppppp'

cleanup_test() {
  if [[ "${CNTOOLS_WALLET_IMPORT_MNEMONIC_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools wallet-import-mnemonic test root preserved: %s\n' \
      "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools wallet-import-mnemonic characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk cmp find grep jq mktemp readlink sed sort stat wc; do
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

mkdir -p -- "${FAKE_BIN}"
for command_name in curl wget git ssh nc; do
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_WALLET_IMPORT_BLOCKED_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_WALLET_IMPORT_BLOCKED_LOG}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_IMPORT_BLOCKED_LOG}"' \
    'exit 97' \
    > "${FAKE_BIN}/${command_name}"
  chmod 0755 "${FAKE_BIN}/${command_name}"
done

# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
# shellcheck source=/dev/null
. "${WALLET_CREATE_SOURCE}"

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
    '[m] Mnemonic') menu=import ;;
    *) fail "unexpected public menu: ${1:-<empty>}" ;;
  esac
  [[ -n "${choice}" ]] || fail "${menu} menu exhausted choices"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == import:m ]]; then
        CAPTURE_ACTIVE=Y
        printf '__CNTOOLS_WALLET_IMPORT_MNEMONIC_BEGIN__\n'
        printf 'action:begin\n' >> "${EVENT_LOG}"
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was unavailable in ${menu} menu"
}

getAnswerAnyCust() {
  local variable="${1:-}"
  case "${variable}" in
    wallet_name)
      if [[ "${SCENARIO:?}" == cancel-name ]]; then
        printf 'prompt:name:cancel\n' >> "${EVENT_LOG:?}"
        return 1
      fi
      printf -v wallet_name '%s' "${NAME_INPUT-}"
      printf 'prompt:name:return\n' >> "${EVENT_LOG:?}"
      ;;
    mnemonic)
      printf 'prompt:mnemonic:%s\n' "${MNEMONIC_WORD_COUNT:-0}" \
        >> "${EVENT_LOG:?}"
      if [[ "${SCENARIO}" == cancel-mnemonic ||
            "${SCENARIO}" == cancel-stale ]]; then
        return 1
      fi
      printf -v mnemonic '%s' "${MNEMONIC_INPUT:-}"
      ;;
    *) fail "unexpected prompt target: ${variable:-<empty>}" ;;
  esac
}

safeDel() {
  local target="${1:-}"
  printf 'action:safeDel:%s\n' "${target}" >> "${EVENT_LOG:?}"
  [[ "${target}" == "${WALLET_FOLDER}/"* ]] || fail 'safeDel escaped wallet root'
  rm -rf -- "${target}"
}

createMnemonicWallet() {
  local count=0
  IFS=' ' read -r -a _fixture_words <<< "${mnemonic-}"
  count=${#_fixture_words[@]}
  printf 'helper:createMnemonicWallet:%s\n' "${count}" >> "${EVENT_LOG:?}"
  if [[ "${SCENARIO:?}" == helper-failure ]]; then
    printf '%s\n' partial-secret > "${WALLET_FOLDER}/${wallet_name}/partial.skey"
    chmod 0644 "${WALLET_FOLDER}/${wallet_name}/partial.skey"
    waitToProceed
    return 1
  fi
  printf '%s\n' fixture-secret > "${WALLET_FOLDER}/${wallet_name}/payment.skey"
  printf '%s\n' "${BASE_ADDR}" > "${WALLET_FOLDER}/${wallet_name}/base.addr"
  chmod 0600 "${WALLET_FOLDER}/${wallet_name}/payment.skey" \
    "${WALLET_FOLDER}/${wallet_name}/base.addr"
  base_addr="${BASE_ADDR}"
  pay_addr="${PAY_ADDR}"
  return 0
}

printWalletInfo() {
  printf 'Wallet fixture summary\n'
  printf 'action:printWalletInfo\n' >> "${EVENT_LOG:?}"
}

waitToProceed() {
  printf 'action:secret:%s\n' \
    "$([[ -v mnemonic ]] && printf present || printf unset)" \
    >> "${EVENT_LOG:?}"
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    printf '__CNTOOLS_WALLET_IMPORT_MNEMONIC_END__\n'
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
  [[ "$(grep -c '^__CNTOOLS_WALLET_IMPORT_MNEMONIC_BEGIN__$' "${source}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_WALLET_IMPORT_MNEMONIC_END__$' "${source}" || true)" == 1 ]] ||
    fail 'wallet-import-mnemonic output markers changed'
  awk '
    $0 == "__CNTOOLS_WALLET_IMPORT_MNEMONIC_BEGIN__" { capture=1; next }
    $0 == "__CNTOOLS_WALLET_IMPORT_MNEMONIC_END__" { exit }
    capture { print }
  ' "${source}" > "${target}"
}

make_words() {
  local count="$1" output="" index=0
  for ((index=1; index<=count; index++)); do
    printf -v output '%s%sword%02d' "${output}" \
      "$([[ -n "${output}" ]] && printf ' ')" "${index}"
  done
  printf '%s' "${output}"
}

scenario_mode() {
  case "$1" in
    valid15-local) printf 'LOCAL\n' ;;
    valid24-light) printf 'LIGHT\n' ;;
    *) printf 'OFFLINE\n' ;;
  esac
}

scenario_name() {
  case "$1" in
    cancel-name|empty-name) printf '' ;;
    sanitized-name) printf 'Alpha Beta' ;;
    *) printf 'fixture_wallet' ;;
  esac
}

scenario_mnemonic() {
  case "$1" in
    cancel-mnemonic) printf '' ;;
    invalid14) make_words 14 ;;
    invalid16) make_words 16 ;;
    valid15-local|sanitized-name|duplicate-empty|symlink-destination|helper-failure)
      make_words 15 ;;
    multiline-bypass) printf '%s\n%s' "$(make_words 15)" 'hidden extra words' ;;
    *) make_words 24 ;;
  esac
}

expected_mutation() {
  local scenario="$1" wallet_root="$2" before="$3" after="$4"
  local wallet_name=fixture_wallet expected="${TEST_ROOT}/expected.tree"
  case "${scenario}" in
    sanitized-name) wallet_name=Alpha_Beta ;;
  esac
  case "${scenario}" in
    cancel-name|empty-name|cancel-mnemonic|invalid14|invalid16)
      assert_files_equal "${before}" "${after}" "${scenario} zero mutation"
      ;;
    duplicate)
      assert_files_equal "${before}" "${after}" "${scenario} duplicate mutation"
      ;;
    helper-failure)
      grep -Fq $'f\twallet/fixture_wallet/partial.skey\t644\t15\t' \
        "${after}" ||
        fail 'helper failure partial-residue contract changed'
      ;;
    symlink-destination)
      [[ -f "${wallet_root}/../outside-wallet/payment.skey" ]] ||
        fail 'legacy symlink destination no longer escaped the wallet root'
      ;;
    *)
      grep -Fq $'f\twallet/'"${wallet_name}"$'/payment.skey\t600\t15\t' \
        "${after}" ||
        fail "${scenario} signing-key mutation changed"
      grep -Fq $'f\twallet/'"${wallet_name}"$'/base.addr\t600\t51\t' \
        "${after}" ||
        fail "${scenario} base-address mutation changed"
      ;;
  esac
  : > "${expected}"
}

run_case() (
  local scenario="$1" mode="" case_root="" runtime_root="" wallet_root=""
  local full_stdout="" action_stdout="" stderr_file="" event_log=""
  local blocked_log="" before="" after="" name_input="" mnemonic_input=""
  local mnemonic_word_count=0 status=0

  case_root="${TEST_ROOT}/cases/${scenario}"
  runtime_root="${case_root}/runtime"
  wallet_root="${runtime_root}/wallet"
  full_stdout="${case_root}/full.stdout"
  action_stdout="${case_root}/action.stdout"
  stderr_file="${case_root}/stderr"
  event_log="${case_root}/events"
  blocked_log="${case_root}/blocked"
  before="${case_root}/before.tree"
  after="${case_root}/after.tree"
  mode="$(scenario_mode "${scenario}")"
  name_input="$(scenario_name "${scenario}")"
  mnemonic_input="$(scenario_mnemonic "${scenario}")"
  IFS=' ' read -r -a _count_words <<< "${mnemonic_input}"
  mnemonic_word_count=${#_count_words[@]}
  mkdir -p -- "${wallet_root}" "${runtime_root}/pool" \
    "${runtime_root}/asset" "${runtime_root}/tmp" "${runtime_root}/home"
  case "${scenario}" in
    duplicate)
      mkdir -p -- "${wallet_root}/fixture_wallet"
      printf original > "${wallet_root}/fixture_wallet/existing"
      ;;
    duplicate-empty) mkdir -p -- "${wallet_root}/fixture_wallet" ;;
    symlink-destination)
      mkdir -p -- "${runtime_root}/outside-wallet"
      ln -s -- "${runtime_root}/outside-wallet" "${wallet_root}/fixture_wallet"
      ;;
  esac
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
    ADVANCED_MODE=true; CNTOOLS_MODE="${mode}"; CNTOOLS_MODE_COLOR=""
    price_now=""; slotnum=1000
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"; CAPTURE_ACTIVE=N
    SCENARIO="${scenario}"; NAME_INPUT="${name_input}"
    MNEMONIC_INPUT="${mnemonic_input}"; MNEMONIC_WORD_COUNT="${mnemonic_word_count}"
    CNTOOLS_WALLET_IMPORT_BLOCKED_LOG="${blocked_log}"
    if [[ "${scenario}" == cancel-stale ]]; then mnemonic="$(make_words 15)"; fi
    CHOICES=(w i m h q); CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  [[ "${status}" == 0 ]] || fail "${scenario} traversal returned ${status}"
  extract_action_output "${full_stdout}" "${action_stdout}"
  [[ ! -s "${stderr_file}" ]] || fail "${scenario} emitted unexpected stderr"
  [[ ! -s "${blocked_log}" ]] || fail "${scenario} attempted external access"
  if [[ -n "${mnemonic_input}" ]]; then
    ! grep -Fq -- "${mnemonic_input}" "${full_stdout}" "${stderr_file}" \
      "${event_log}" "${blocked_log}" || fail "${scenario} leaked mnemonic input"
  fi
  grep -Fq ' >> WALLET >> IMPORT >> MNEMONIC' "${action_stdout}" ||
    fail "${scenario} action header changed"
  grep -Fq 'action:waitToProceed' "${event_log}" ||
    fail "${scenario} wait behavior changed"
  case "${scenario}" in
    valid15-local|valid24-light|valid24-offline|sanitized-name|duplicate-empty|\
      multiline-bypass|cancel-stale)
      grep -Fq 'Wallet Imported :' "${action_stdout}" ||
        fail "${scenario} success output changed"
      grep -Fq 'action:printWalletInfo' "${event_log}" ||
        fail "${scenario} wallet-info call changed"
      ;;
    invalid14)
      grep -Fq '24 or 15 words expected, found 14' "${action_stdout}" ||
        fail '14-word rejection changed'
      ;;
    invalid16)
      grep -Fq '24 or 15 words expected, found 16' "${action_stdout}" ||
        fail '16-word rejection changed'
      ;;
  esac
  tree_snapshot "${runtime_root}" "${after}" || fail "${scenario} post-snapshot failed"
  expected_mutation "${scenario}" "${wallet_root}" "${before}" "${after}"
)

for scenario in \
  cancel-name empty-name cancel-mnemonic cancel-stale invalid14 invalid16 \
  valid15-local valid24-light valid24-offline sanitized-name duplicate \
  duplicate-empty helper-failure multiline-bypass symlink-destination; do
  run_case "${scenario}"
done

import_arm="${TEST_ROOT}/import-mnemonic-arm"
awk '
  /^[[:space:]]+mnemonic\)/ { seen++; if (seen == 2) capture=1 }
  capture { print }
  capture && /^[[:space:]]+;;/ { exit }
' "${CNTOOLS_SCRIPT}" > "${import_arm}"
grep -Fq 'IFS=" " read -r -a words <<< "${mnemonic}"' "${import_arm}" ||
  fail 'inline mnemonic word-count implementation changed'
grep -Fq 'createMnemonicWallet || continue' "${import_arm}" ||
  fail 'inline mnemonic helper boundary changed'
if grep -Fq 'cntools_compatibility_dispatch_action wallet.import.mnemonic' \
    "${import_arm}"; then
  fail 'wallet.import.mnemonic was extracted during characterization'
fi

printf 'CNTools wallet-import-mnemonic characterization passed (15 legacy cases)\n'
