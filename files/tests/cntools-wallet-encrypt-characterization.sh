#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet-encrypt characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
LEGACY_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f"
SECURITY_SOURCE="${LEGACY_ROOT}/020-terminal-selection-security.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/wallet/encrypt/action.sh"
ACTION_DIRECTORY="${ACTION_SOURCE%/action.sh}"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet-encrypt.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
DIRECT_FAKE_BIN="${TEST_ROOT}/direct-fake-bin"
BASE_PATH="${PATH}"
REAL_CHMOD="$(command -v chmod)"
FIXTURE_PASSWORD='correct horse battery staple'

cleanup_test() {
  if [[ "${CNTOOLS_WALLET_ENCRYPT_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools wallet-encrypt test root preserved: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  "${REAL_CHMOD}" -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() { printf 'CNTools wallet-encrypt characterization failed: %s\n' "$1" >&2; exit 1; }

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"
if command -v sha256sum >/dev/null 2>&1; then HASH_COMMAND=sha256sum;
elif command -v shasum >/dev/null 2>&1; then HASH_COMMAND=shasum;
else fail 'sha256sum or shasum is required'; fi

write_fake_commands() {
  local command_name=""
  mkdir -p -- "${FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'input="" output="" previous=""' \
    'printf '\''gpg'\'' >> "${CNTOOLS_WALLET_ENCRYPT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  [[ "${normalized}" == "${CNTOOLS_WALLET_ENCRYPT_ROOT}/"* ]] && normalized="<wallet>/${normalized#"${CNTOOLS_WALLET_ENCRYPT_ROOT}/"}"' \
    '  printf '\''\t%q'\'' "${normalized}" >> "${CNTOOLS_WALLET_ENCRYPT_VECTOR_LOG}"' \
    '  [[ "${previous}" == --output ]] && output="${argument}"' \
    '  previous="${argument}"' \
    '  input="${argument}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_ENCRYPT_VECTOR_LOG}"' \
    'IFS= read -r secret || exit 91' \
    '[[ "${secret}" == "${CNTOOLS_WALLET_ENCRYPT_EXPECTED_PASSWORD:?}" ]] || exit 92' \
    'printf partial-cipher > "${output}"' \
    'case "${CNTOOLS_WALLET_ENCRYPT_SCENARIO:?}:${input##*/}" in' \
    '  gpg-pay-failure:payment.skey|gpg-stake-failure:stake.skey) exit 42 ;;' \
    'esac' \
    'printf complete-cipher > "${output}"' \
    > "${FAKE_BIN}/gpg"
  chmod 0755 "${FAKE_BIN}/gpg"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''lsattr'\'' >> "${CNTOOLS_WALLET_ENCRYPT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_WALLET_ENCRYPT_VECTOR_LOG}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_ENCRYPT_VECTOR_LOG}"' \
    'printf -- '\''-------------e------- %s\n'\'' "${@: -1}"' \
    > "${FAKE_BIN}/lsattr"
  chmod 0755 "${FAKE_BIN}/lsattr"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''sudo'\'' >> "${CNTOOLS_WALLET_ENCRYPT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_WALLET_ENCRYPT_VECTOR_LOG}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_ENCRYPT_VECTOR_LOG}"' \
    '[[ "${CNTOOLS_WALLET_ENCRYPT_SCENARIO:?}" != chattr-failure ]]' \
    > "${FAKE_BIN}/sudo"
  chmod 0755 "${FAKE_BIN}/sudo"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s\n'\'' "${0##*/}" >> "${CNTOOLS_WALLET_ENCRYPT_BLOCKED_LOG:?}"' \
      'exit 97' > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}
write_fake_commands

# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
# shellcheck source=/dev/null
. "${SECURITY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/registry.sh
. "${REGISTRY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/context.sh
. "${CONTEXT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/result.sh
. "${RESULT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/dispatcher.sh
. "${DISPATCHER_SOURCE}"

# The production bridge authenticates an installed generation. The focused
# public-route matrix substitutes only that authority setup, then invokes the
# real dispatcher and extracted action through the generic public bridge.
cntools_compatibility_dispatch_action() (
  local action_id="${1:-}" private_root="" context_file=""
  local result_file="" status=0

  [[ "${action_id}" == wallet.encrypt && $# == 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  umask 077
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/wallet-encrypt-test-dispatch.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  chmod 0700 "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  jq -nS --arg mode "${CNTOOLS_MODE,,}" --arg node_home "${NODE_HOME}" '
    {
      advanced: true,
      apiVersion: 1,
      capabilities: ["forging", "local-cli", "metrics", "n2c"],
      features: ["advanced"],
      generationVersion: "13.5.7",
      mode: $mode,
      nodeHome: $node_home,
      nodeImplementation: "cnode",
      nodeNetwork: "preview",
      schemaVersion: 1
    }
  ' > "${context_file}" || return 70
  chmod 0400 "${context_file}" || return 70
  if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"; then
    status=0
  else
    status=$?
  fi
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || status=70
  rm -f -- "${result_file}" "${context_file}" >/dev/null 2>&1 || status=70
  rmdir -- "${private_root}" >/dev/null 2>&1 || status=70
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]] &&
     ! grep -Fqx 'action:waitToProceed' "${EVENT_LOG}"; then
    printf '__CNTOOLS_WALLET_ENCRYPT_END__\n'
    CAPTURE_ACTIVE=N
  fi
  return "${status}"
)

println() {
  local level="${1:-}"; shift || true
  case "${level}" in ACTION|LOG) return 0;; OFF|DEBUG|INFO|ERROR) printf '%b\n' "$@";; *) printf '%b\n' "${level}" "$@";; esac
}
clear() {
  if [[ "${CAPTURE_ACTIVE:-N}" == Y && "${END_ON_CLEAR:-N}" == Y ]]; then
    printf '__CNTOOLS_WALLET_ENCRYPT_END__\n'; CAPTURE_ACTIVE=N; END_ON_CLEAR=N
  fi
  printf 'terminal:clear\n' >> "${EVENT_LOG:?}"
}
tput() {
  case "${1:-}" in
    sc) printf 'terminal:sc\n' >> "${EVENT_LOG:?}" ;;
    rc) printf 'terminal:rc\n' >> "${EVENT_LOG:?}" ;;
    ed) printf 'terminal:ed\n' >> "${EVENT_LOG:?}" ;;
    *) return 1 ;;
  esac
}
getEpoch() { printf 5; }; timeUntilNextEpoch() { printf 0; }; timeLeft() { printf 0; }
slotInterval() { printf 20; }; getSlotTipRef() { printf 1000; }
getNodeMetrics() { printf 'runtime:getNodeMetrics\n' >> "${EVENT_LOG:?}"; slotnum=1000; }
getPriceInfo() { printf 'runtime:getPriceInfo\n' >> "${EVENT_LOG:?}"; price_now=""; }
updateProtocolParams() { printf 'runtime:updateProtocolParams\n' >> "${EVENT_LOG:?}"; }

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}" menu="" option="" index=0
  case "${1:-}" in '[w] Wallet') menu=main;; '[n] New') menu=wallet;; *) fail "unexpected menu";; esac
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1)); printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == wallet:e ]]; then
        CAPTURE_ACTIVE=Y; printf '__CNTOOLS_WALLET_ENCRYPT_BEGIN__\n'; printf 'action:begin\n' >> "${EVENT_LOG}"
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice unavailable: ${choice}"
}

selectWallet() {
  [[ "${1:-}" == encrypted ]] || fail 'wallet-encrypt selector contract changed'
  printf 'action:selectWallet:encrypted\n' >> "${EVENT_LOG:?}"
  case "${SCENARIO:?}" in
    select-fail|direct-select-fail) return 1;;
    select-cancel|direct-select-cancel) END_ON_CLEAR=Y; return 2;;
    direct-invalid-name) wallet_name='../outside';;
    *) wallet_name=alpha;;
  esac
}
getPasswordCust() {
  [[ "${1:-}" == confirm ]] || fail 'wallet-encrypt confirmation contract changed'
  printf 'action:password\n' >> "${EVENT_LOG:?}"
  password="${FIXTURE_PASSWORD}"
  [[ "${SCENARIO:?}" != password-abort &&
     "${SCENARIO:?}" != direct-password-abort ]]
}
safeDel() {
  local target="${1:-}"
  printf 'action:safeDel:%s\n' "${target}" >> "${EVENT_LOG:?}"
  rm -f -- "${target}"
}
waitToProceed() {
  printf 'action:secret:%s\n' "$([[ -v password ]] && printf present || printf unset)" >> "${EVENT_LOG:?}"
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then printf '__CNTOOLS_WALLET_ENCRYPT_END__\n'; CAPTURE_ACTIVE=N; fi
}
myExit() { printf 'exit:%s:%s\n' "${1:-0}" "${2:-}" >> "${EVENT_LOG:?}"; exit "${1:-0}"; }

extract_action_output() {
  local source="$1" target="$2"
  [[ "$(grep -c '^__CNTOOLS_WALLET_ENCRYPT_BEGIN__$' "${source}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_WALLET_ENCRYPT_END__$' "${source}" || true)" == 1 ]] || fail 'output markers changed'
  awk '$0=="__CNTOOLS_WALLET_ENCRYPT_BEGIN__"{p=1;next}$0=="__CNTOOLS_WALLET_ENCRYPT_END__"{exit}p' "${source}" > "${target}"
}

setup_wallet() {
  local scenario="$1" wallet_root="$2" outside="$3"
  [[ "${scenario}" != empty ]] || return 0
  mkdir -p -- "${wallet_root}/alpha"
  case "${scenario}" in
    already-encrypted) printf cipher > "${wallet_root}/alpha/payment.skey.gpg";;
    missing-keys) printf public > "${wallet_root}/alpha/public.vkey";;
    symlink-key)
      printf outside-secret > "${outside}/payment.skey"
      ln -s -- "${outside}/payment.skey" "${wallet_root}/alpha/payment.skey"
      printf stake-secret > "${wallet_root}/alpha/stake.skey"
      ;;
    hardlink-key)
      printf outside-secret > "${outside}/payment.skey"
      ln -- "${outside}/payment.skey" "${wallet_root}/alpha/payment.skey"
      printf stake-secret > "${wallet_root}/alpha/stake.skey"
      ;;
    *)
      printf payment-secret > "${wallet_root}/alpha/payment.skey"
      printf stake-secret > "${wallet_root}/alpha/stake.skey"
      printf public > "${wallet_root}/alpha/public.vkey"
      printf address > "${wallet_root}/alpha/base.addr"
      ;;
  esac
  "${REAL_CHMOD}" 0600 "${wallet_root}/alpha"/* 2>/dev/null || true
}

assert_mutation() {
  local scenario="$1" wallet_root="$2" outside="$3" before="$4" after="$5"
  case "${scenario}" in
    empty|select-fail|select-cancel|already-encrypted|password-abort)
      assert_files_equal "${after}" "${before}" "${scenario} zero mutation";;
    success-*|chattr-failure)
      [[ ! -e "${wallet_root}/alpha/payment.skey" && ! -e "${wallet_root}/alpha/stake.skey" ]] || fail "${scenario} plaintext remained"
      [[ "$(file_mode "${wallet_root}/alpha/payment.skey.gpg")" == 400 &&
         "$(file_mode "${wallet_root}/alpha/stake.skey.gpg")" == 400 &&
         "$(file_mode "${wallet_root}/alpha/public.vkey")" == 400 &&
         "$(file_mode "${wallet_root}/alpha/base.addr")" == 600 ]] || fail "${scenario} final modes changed";;
    missing-keys) [[ "$(file_mode "${wallet_root}/alpha/public.vkey")" == 400 ]] || fail 'missing-key lock changed';;
    gpg-pay-failure)
      [[ -f "${wallet_root}/alpha/payment.skey" && -f "${wallet_root}/alpha/payment.skey.gpg" &&
         ! -e "${wallet_root}/alpha/stake.skey" && -f "${wallet_root}/alpha/stake.skey.gpg" ]] || fail 'payment failure partial mutation changed';;
    gpg-stake-failure)
      [[ ! -e "${wallet_root}/alpha/payment.skey" && -f "${wallet_root}/alpha/payment.skey.gpg" &&
         -f "${wallet_root}/alpha/stake.skey" && -f "${wallet_root}/alpha/stake.skey.gpg" ]] || fail 'stake failure partial mutation changed';;
    symlink-key)
      [[ "$(file_mode "${outside}/payment.skey")" == 400 && ! -L "${wallet_root}/alpha/payment.skey" ]] || fail 'symlink escape mutation changed';;
    hardlink-key)
      [[ "$(file_mode "${outside}/payment.skey")" == 400 && ! -e "${wallet_root}/alpha/payment.skey" ]] || fail 'hardlink escape mutation changed';;
  esac
}

run_case() (
  local scenario="$1" mode="$2" case_root="" runtime="" wallet="" outside=""
  local stdout="" action="" stderr="" events="" vectors="" blocked=""
  local before="" after="" status=0
  case_root="${TEST_ROOT}/cases/${scenario}"
  runtime="${case_root}/runtime"
  wallet="${runtime}/wallet"
  outside="${runtime}/outside"
  stdout="${case_root}/full.stdout"
  action="${case_root}/action.stdout"
  stderr="${case_root}/stderr"
  events="${case_root}/events"
  vectors="${case_root}/vectors"
  blocked="${case_root}/blocked"
  before="${case_root}/before.tree"
  after="${case_root}/after.tree"
  mkdir -p -- "${wallet}" "${outside}" "${runtime}/home" "${runtime}/tmp" "${runtime}/pool" "${runtime}/asset"
  setup_wallet "${scenario}" "${wallet}" "${outside}"
  tree_snapshot "${runtime}" "${before}" || fail "${scenario} pre-snapshot failed"
  : > "${events}"; : > "${vectors}"; : > "${blocked}"
  if (
    set +e; set +u; set +o pipefail; export LC_ALL=C TZ=UTC
    PATH="${FAKE_BIN}:${BASE_PATH}"; export PATH
    HOME="${runtime}/home"; NODE_HOME="${runtime}/home"; TMP_DIR="${runtime}/tmp"
    WALLET_FOLDER="${wallet}"; POOL_FOLDER="${runtime}/pool"; ASSET_FOLDER="${runtime}/asset"
    BLOCKLOG_DB="${runtime}/absent.db"; ADVANCED_MODE=true; CNTOOLS_MODE="${mode}"; CNTOOLS_MODE_COLOR=""
    WALLET_PAY_SK_FILENAME=payment.skey; WALLET_STAKE_SK_FILENAME=stake.skey; ENABLE_CHATTR="$([[ "${scenario}" == chattr-failure ]] && printf true || printf false)"
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE="" FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE="" FG_WHITE="" NC=""
    EVENT_LOG="${events}"; SCENARIO="${scenario}"; CAPTURE_ACTIVE=N; END_ON_CLEAR=N
    export CNTOOLS_WALLET_ENCRYPT_VECTOR_LOG="${vectors}"
    export CNTOOLS_WALLET_ENCRYPT_BLOCKED_LOG="${blocked}"
    export CNTOOLS_WALLET_ENCRYPT_ROOT="${wallet}"
    export CNTOOLS_WALLET_ENCRYPT_EXPECTED_PASSWORD="${FIXTURE_PASSWORD}"
    export CNTOOLS_WALLET_ENCRYPT_SCENARIO="${scenario}"
    unset password
    CHOICES=(w e h q); CHOICE_CURSOR=0
    main; exit 99
  ) > "${stdout}" 2> "${stderr}"; then status=0; else status=$?; fi
  [[ "${status}" == 0 ]] || fail "${scenario} traversal returned ${status}"
  extract_action_output "${stdout}" "${action}"
  [[ ! -s "${stderr}" ]] || fail "${scenario} unexpected stderr"
  [[ ! -s "${blocked}" ]] || fail "${scenario} external access"
  ! grep -Fq "${FIXTURE_PASSWORD}" "${stdout}" "${stderr}" "${events}" "${vectors}" || fail "${scenario} password leaked"
  grep -Fq ' >> WALLET >> ENCRYPT' "${action}" || fail "${scenario} header changed"
  case "${scenario}" in
    empty) grep -Fq 'No wallets available!' "${action}" || fail 'empty message changed';;
    already-encrypted) grep -Fq 'found GPG encrypted files' "${action}" || fail 'already-encrypted message changed';;
    password-abort) grep -Fq 'password input aborted!' "${action}" || fail 'password abort changed';;
    success-*|missing-keys|gpg-*-failure|chattr-failure|symlink-key|hardlink-key)
      grep -Fq 'Wallet protected : alpha' "${action}" || fail "${scenario} completion output changed";;
  esac
  tree_snapshot "${runtime}" "${after}" || fail "${scenario} post-snapshot failed"
  assert_mutation "${scenario}" "${wallet}" "${outside}" "${before}" "${after}"
)

write_direct_context() {
  local target="$1" mode="$2" node_home="$3"

  jq -nS \
    --arg generationVersion '4.0.0' \
    --arg mode "${mode,,}" \
    --arg nodeHome "${node_home}" \
    '{
      advanced: true,
      apiVersion: 1,
      capabilities: [],
      features: [],
      generationVersion: $generationVersion,
      mode: $mode,
      nodeHome: $nodeHome,
      nodeImplementation: "cnode",
      nodeNetwork: "preview",
      schemaVersion: 1
    }' > "${target}"
  chmod 0600 "${target}"
}

write_direct_fake_commands() {
  local command_name=""

  mkdir -p -- "${DIRECT_FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_ENCRYPT_SCENARIO:?}"' \
    'log="${CNTOOLS_WALLET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
    'output="" input="" previous="" after_separator=N supplied=""' \
    'printf '\''gpg'\'' >> "${log}"' \
    'for argument in "$@"; do' \
    '  printf '\''\t%q'\'' "${argument}" >> "${log}"' \
    '  [[ "${previous}" == --output ]] && output="${argument}"' \
    '  [[ "${after_separator}" == Y ]] && input="${argument}"' \
    '  [[ "${argument}" == -- ]] && after_separator=Y' \
    '  previous="${argument}"' \
    'done' \
    'printf '\''\n'\'' >> "${log}"' \
    'IFS= read -r supplied || true' \
    '[[ "${supplied}" == "${CNTOOLS_WALLET_ENCRYPT_EXPECTED_PASSWORD:?}" ]] || exit 98' \
    '[[ -n "${output}" && -n "${input}" ]] || exit 96' \
    'case "${scenario}:${input##*/}" in' \
    '  direct-gpg-pay-failure:payment.skey|direct-gpg-stake-failure:stake.skey)' \
    '    printf '\''partial cipher\n'\'' > "${output}"; exit 17 ;;' \
    '  direct-signal-during-cleanup:payment.skey)' \
    '    printf '\''partial cipher\n'\'' > "${output}"; exit 17 ;;' \
    '  direct-signal-gpg:payment.skey)' \
    '    printf '\''encrypted payment.skey\n'\'' > "${output}"; kill -TERM "${PPID}"; exit 0 ;;' \
    'esac' \
    'case "${scenario}" in' \
    '  direct-gpg-empty) : > "${output}"; exit 0 ;;' \
    '  direct-inventory-race)' \
    '    [[ -e "${input%/*}/injected.race" ]] || printf '\''race\n'\'' > "${input%/*}/injected.race" ;;' \
    '  direct-source-race)' \
    '    [[ "${input##*/}" != payment.skey ]] || printf '\''tamper\n'\'' >> "${input}" ;;' \
    'esac' \
    'printf '\''encrypted %s\n'\'' "${input##*/}" > "${output}"' \
    > "${DIRECT_FAKE_BIN}/gpg"
  chmod 0755 "${DIRECT_FAKE_BIN}/gpg"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_ENCRYPT_SCENARIO:?}" target="${*: -1}"' \
    'printf '\''ln'\'' >> "${CNTOOLS_WALLET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_WALLET_ENCRYPT_DIRECT_VECTOR_LOG}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_ENCRYPT_DIRECT_VECTOR_LOG}"' \
    'case "${scenario}:${target##*/}" in' \
    '  direct-signal-cipher-link:payment.skey.gpg|direct-signal-backup-link:source.0.backup)' \
    '    "${CNTOOLS_WALLET_ENCRYPT_REAL_LN:?}" "$@" || exit $?; kill -TERM "${PPID}"; exit 0 ;;' \
    '  direct-cipher-link-pay-nonzero:payment.skey.gpg|direct-cipher-link-stake-nonzero:stake.skey.gpg|direct-backup-link-pay-nonzero:source.0.backup|direct-backup-link-stake-nonzero:source.1.backup|direct-rollback-link-pay-nonzero:payment.skey|direct-rollback-link-stake-nonzero:stake.skey)' \
    '    "${CNTOOLS_WALLET_ENCRYPT_REAL_LN:?}" "$@" || exit $?; exit 41 ;;' \
    'esac' \
    'exec "${CNTOOLS_WALLET_ENCRYPT_REAL_LN:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/ln"
  chmod 0755 "${DIRECT_FAKE_BIN}/ln"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_ENCRYPT_SCENARIO:?}" target="${*: -1}"' \
    'printf '\''rm'\'' >> "${CNTOOLS_WALLET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_WALLET_ENCRYPT_DIRECT_VECTOR_LOG}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_ENCRYPT_DIRECT_VECTOR_LOG}"' \
    'case "${scenario}:${target##*/}" in' \
    '  direct-signal-temp-unlink:cipher.0.*|direct-signal-source-unlink:payment.skey)' \
    '    "${CNTOOLS_WALLET_ENCRYPT_REAL_RM:?}" "$@" || exit $?; kill -TERM "${PPID}"; exit 0 ;;' \
    '  direct-temp-rm-failure:cipher.0.*)' \
    '    [[ -e "${CNTOOLS_WALLET_ENCRYPT_FAULT_MARKER:?}.temp" ]] || { : > "${CNTOOLS_WALLET_ENCRYPT_FAULT_MARKER}.temp"; exit 42; } ;;' \
    '  direct-source-rm-pay-nonzero:payment.skey|direct-source-rm-stake-nonzero:stake.skey|direct-rollback-link-pay-nonzero:stake.skey|direct-rollback-link-stake-nonzero:stake.skey)' \
    '    marker="${CNTOOLS_WALLET_ENCRYPT_FAULT_MARKER:?}.${target##*/}"' \
    '    [[ -e "${marker}" ]] || { : > "${marker}"; "${CNTOOLS_WALLET_ENCRYPT_REAL_RM:?}" "$@" || exit $?; exit 43; } ;;' \
    '  direct-postcommit-backup-cleanup:source.0.backup) exit 44 ;;' \
    'esac' \
    'exec "${CNTOOLS_WALLET_ENCRYPT_REAL_RM:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/rm"
  chmod 0755 "${DIRECT_FAKE_BIN}/rm"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_ENCRYPT_SCENARIO:?}" mode="${1:-}" target="${*: -1}"' \
    'printf '\''chmod\t%q\t%q\n'\'' "${mode}" "${target}" >> "${CNTOOLS_WALLET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
    'if [[ "${target}" == */public.vkey && "${mode}" =~ ^0?400$ ]]; then' \
    '  if [[ "${scenario}" == direct-signal-chmod ]]; then "${CNTOOLS_WALLET_ENCRYPT_REAL_CHMOD:?}" "$@" || exit $?; kill -TERM "${PPID}"; exit 0; fi' \
    '  case "${scenario}" in' \
    '    direct-chmod-failure) exit 45 ;;' \
    '    direct-chmod-nonzero)' \
    '      marker="${CNTOOLS_WALLET_ENCRYPT_FAULT_MARKER:?}.chmod"' \
    '      [[ -e "${marker}" ]] || { : > "${marker}"; "${CNTOOLS_WALLET_ENCRYPT_REAL_CHMOD:?}" "$@" || exit $?; exit 46; } ;;' \
    '  esac' \
    '  if [[ "${scenario}" == direct-lock-swap && ! -e "${CNTOOLS_WALLET_ENCRYPT_FAULT_MARKER:?}.lock-swap" ]]; then' \
    '    : > "${CNTOOLS_WALLET_ENCRYPT_FAULT_MARKER}.lock-swap"' \
    '    lock="${target%/alpha/*}/.alpha.cntools-encrypt.lock"' \
    '    "${CNTOOLS_WALLET_ENCRYPT_REAL_MV:?}" -- "${lock}" "${lock}.captured" || exit $?' \
    '    "${CNTOOLS_WALLET_ENCRYPT_REAL_MKDIR:?}" -m 0700 -- "${lock}" || exit $?' \
    '  fi' \
    'fi' \
    'exec "${CNTOOLS_WALLET_ENCRYPT_REAL_CHMOD:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/chmod"
  chmod 0755 "${DIRECT_FAKE_BIN}/chmod"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_ENCRYPT_SCENARIO:?}" target="${*: -1}"' \
    'if [[ "${target}" == */.alpha.cntools-encrypt.lock ]]; then' \
    '  case "${scenario}" in' \
    '    direct-lock-mkdir-nonzero) "${CNTOOLS_WALLET_ENCRYPT_REAL_MKDIR:?}" "$@" || exit $?; exit 47 ;;' \
    '    direct-signal-after-lock) "${CNTOOLS_WALLET_ENCRYPT_REAL_MKDIR:?}" "$@" || exit $?; kill -TERM "${PPID}"; exit 0 ;;' \
    '  esac' \
    'fi' \
    'exec "${CNTOOLS_WALLET_ENCRYPT_REAL_MKDIR:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/mkdir"
  chmod 0755 "${DIRECT_FAKE_BIN}/mkdir"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_ENCRYPT_SCENARIO:?}" target="${*: -1}"' \
    'if [[ "${target}" == */.alpha.cntools-encrypt.lock ]]; then' \
    '  case "${scenario}" in' \
    '    direct-postcommit-lock-release) exit 48 ;;' \
    '    direct-postcommit-signal) "${CNTOOLS_WALLET_ENCRYPT_REAL_RMDIR:?}" "$@" || exit $?; kill -TERM "${PPID}"; exit 0 ;;' \
    '    direct-signal-during-cleanup) kill -TERM "${PPID}"; "${CNTOOLS_WALLET_ENCRYPT_REAL_RMDIR:?}" "$@"; exit $? ;;' \
    '  esac' \
    'fi' \
    'exec "${CNTOOLS_WALLET_ENCRYPT_REAL_RMDIR:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/rmdir"
  chmod 0755 "${DIRECT_FAKE_BIN}/rmdir"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'target="${*: -1}" state="${CNTOOLS_WALLET_ENCRYPT_IMMUTABLE_STATE:?}"' \
    'if /usr/bin/grep -Fqx -- "${target}" "${state}" 2>/dev/null; then flags=----i---------; else flags=--------------; fi' \
    'printf '\''%s %s\n'\'' "${flags}" "${target}"' \
    > "${DIRECT_FAKE_BIN}/lsattr"
  chmod 0755 "${DIRECT_FAKE_BIN}/lsattr"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_ENCRYPT_SCENARIO:?}" operation="${1:-}" target="${*: -1}"' \
    'state="${CNTOOLS_WALLET_ENCRYPT_IMMUTABLE_STATE:?}" temporary="${state}.new"' \
    'if [[ "${operation}" == +i && "${target}" == */public.vkey ]]; then' \
    '  case "${scenario}" in direct-chattr-failure) exit 49;; esac' \
    'fi' \
    'if [[ "${operation}" == +i && "${target}" == *.gpg && ( "${scenario}" == direct-chattr-late-failure || "${scenario}" == direct-chattr-rollback-failure ) ]]; then exit 50; fi' \
    'if [[ "${operation}" == -i && "${target}" == */public.vkey && "${scenario}" == direct-chattr-rollback-failure ]]; then exit 51; fi' \
    'case "${operation}" in' \
    '  +i) /usr/bin/grep -Fqx -- "${target}" "${state}" 2>/dev/null || printf '\''%s\n'\'' "${target}" >> "${state}" ;;' \
    '  -i) /usr/bin/awk -v target="${target}" '\''$0 != target { print }'\'' "${state}" > "${temporary}"; "${CNTOOLS_WALLET_ENCRYPT_REAL_MV:?}" -- "${temporary}" "${state}" ;;' \
    '  *) exit 96 ;;' \
    'esac' \
    'if [[ "${scenario}" == direct-signal-chattr && "${operation}" == +i && "${target}" == */public.vkey ]]; then kill -TERM "${PPID}"; fi' \
    > "${DIRECT_FAKE_BIN}/chattr"
  chmod 0755 "${DIRECT_FAKE_BIN}/chattr"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'exec "$@"' \
    > "${DIRECT_FAKE_BIN}/sudo"
  chmod 0755 "${DIRECT_FAKE_BIN}/sudo"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s\n'\'' "${0##*/}" >> "${CNTOOLS_WALLET_ENCRYPT_NETWORK_LOG:?}"' \
      'exit 97' > "${DIRECT_FAKE_BIN}/${command_name}"
    chmod 0755 "${DIRECT_FAKE_BIN}/${command_name}"
  done
}

prepare_direct_scenario() {
  local scenario="$1" runtime_root="$2" wallet_root="$3"
  local selected="${wallet_root}/alpha" outside="${runtime_root}/outside"

  chmod 0755 "${wallet_root}"
  [[ "${scenario}" == direct-empty ]] && return 0
  mkdir -p -- "${selected}" "${outside}"
  chmod 0755 "${selected}"
  printf 'payment signing secret\n' > "${selected}/payment.skey"
  printf 'stake signing secret\n' > "${selected}/stake.skey"
  printf 'verification key\n' > "${selected}/public.vkey"
  printf 'addr_test1safe\n' > "${selected}/base.addr"
  chmod 0600 "${selected}/payment.skey" "${selected}/stake.skey"
  chmod 0644 "${selected}/public.vkey" "${selected}/base.addr"
  case "${scenario}" in
    direct-already-encrypted) printf 'existing cipher\n' > "${selected}/unrelated.gpg"; chmod 0600 "${selected}/unrelated.gpg" ;;
    direct-missing-pay) rm -f -- "${selected}/payment.skey" ;;
    direct-missing-stake) rm -f -- "${selected}/stake.skey" ;;
    direct-wallet-symlink)
      mv -- "${selected}" "${outside}/alpha"; ln -s -- "${outside}/alpha" "${selected}" ;;
    direct-symlink-key)
      mv -- "${selected}/payment.skey" "${outside}/payment.skey"; ln -s -- "${outside}/payment.skey" "${selected}/payment.skey" ;;
    direct-hardlink-key) ln -- "${selected}/payment.skey" "${outside}/payment.link" ;;
    direct-special-leaf) mkfifo "${selected}/unsafe.pipe" ;;
    direct-root-mode) chmod 0777 "${wallet_root}" ;;
    direct-wallet-mode) chmod 0777 "${selected}" ;;
    direct-file-mode) chmod 0666 "${selected}/payment.skey" ;;
    direct-lock-contention) mkdir -m 0700 -- "${wallet_root}/.alpha.cntools-encrypt.lock" ;;
  esac
}

direct_expected_status() {
  case "$1" in
    direct-invalid-name|direct-wallet-symlink|direct-symlink-key|direct-hardlink-key|direct-special-leaf|direct-root-mode|direct-wallet-mode|direct-file-mode|direct-root-backslash|direct-gpg-function-shadow|direct-gpg-empty|direct-inventory-race|direct-source-race|direct-lock-swap|direct-signal-after-lock|direct-signal-gpg|direct-signal-cipher-link|direct-signal-temp-unlink|direct-signal-chmod|direct-signal-chattr|direct-signal-backup-link|direct-signal-source-unlink|direct-chattr-rollback-failure)
      printf '70\n' ;;
    *) printf '0\n' ;;
  esac
}

direct_expected_waits() {
  case "$1" in
    direct-select-cancel|direct-invalid-name|direct-wallet-symlink|direct-symlink-key|direct-hardlink-key|direct-special-leaf|direct-root-mode|direct-wallet-mode|direct-file-mode|direct-root-backslash|direct-gpg-function-shadow|direct-gpg-empty|direct-inventory-race|direct-source-race|direct-lock-swap|direct-signal-after-lock|direct-signal-gpg|direct-signal-cipher-link|direct-signal-temp-unlink|direct-signal-chmod|direct-signal-chattr|direct-signal-backup-link|direct-signal-source-unlink|direct-postcommit-signal|direct-chattr-rollback-failure)
      printf '0\n' ;;
    *) printf '1\n' ;;
  esac
}

normalize_direct_output() {
  local source="$1" target="$2" runtime_root="$3"
  sed "s#${runtime_root}#<runtime>#g" "${source}" > "${target}"
}

write_direct_success_stdout() {
  local target="$1"

  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> WALLET >> ENCRYPT' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    '' \
    'Select wallet to encrypt' \
    '' \
    'Encrypting sensitive wallet keys with GPG' \
    '' \
    '<runtime>/wallet/alpha/payment.skey successfully encrypted' \
    '<runtime>/wallet/alpha/stake.skey successfully encrypted' \
    '' \
    "Write protecting all wallet keys with 400 permission and if enabled 'chattr +i'" \
    '<runtime>/wallet/alpha/public.vkey' \
    '<runtime>/wallet/alpha/payment.skey.gpg' \
    '<runtime>/wallet/alpha/stake.skey.gpg' \
    '' \
    'Wallet protected : alpha' \
    'Files locked     : 3' \
    'Files encrypted  : 2' \
    '' \
    'INFO: wallet files are now protected' \
    "Use 'WALLET >> DECRYPT' to unlock" > "${target}"
}

assert_direct_success_state() {
  local scenario="$1" runtime_root="$2" selected=""

  selected="${runtime_root}/wallet/alpha"

  [[ ! -e "${selected}/payment.skey" && ! -L "${selected}/payment.skey" &&
     ! -e "${selected}/stake.skey" && ! -L "${selected}/stake.skey" &&
     -f "${selected}/payment.skey.gpg" &&
     -f "${selected}/stake.skey.gpg" &&
     "$(file_mode "${selected}/payment.skey.gpg")" == 400 &&
     "$(file_mode "${selected}/stake.skey.gpg")" == 400 &&
     "$(file_mode "${selected}/public.vkey")" == 400 &&
     "$(file_mode "${selected}/base.addr")" == 644 &&
     "$(< "${selected}/payment.skey.gpg")" == 'encrypted payment.skey' &&
     "$(< "${selected}/stake.skey.gpg")" == 'encrypted stake.skey' ]] ||
    fail "${scenario} hardened success state changed"
}

run_direct_case() {
  local scenario="$1" mode="$2" chattr_enabled="${3:-false}"
  local case_root="${TEST_ROOT}/direct-cases/${scenario}"
  local runtime_root="" wallet_root=""
  local capture_root="${case_root}/capture" private_root=""
  local context_file="" result_file=""
  local stdout_file="${capture_root}/stdout" stderr_file="${capture_root}/stderr"
  local events="${capture_root}/events" vectors="${capture_root}/vectors"
  local network="${capture_root}/network" immutable="${capture_root}/immutable"
  local before="${capture_root}/before.tree" after="${capture_root}/after.tree"
  local normalized="${capture_root}/stdout.normalized" expected="${capture_root}/stdout.expected"
  local expected_status="" expected_waits="" status=0 wait_count=0

  runtime_root="${case_root}/runtime"
  wallet_root="${runtime_root}/wallet"
  if [[ "${scenario}" == direct-root-backslash ]]; then
    wallet_root="${runtime_root}/wallet\\033[31mOWNED"
  fi
  private_root="${runtime_root}/tmp/private"
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${runtime_root}/pool" "${runtime_root}/asset" "${wallet_root}" "${capture_root}"
  prepare_direct_scenario "${scenario}" "${runtime_root}" "${wallet_root}"
  tree_snapshot "${runtime_root}" "${before}" || fail "${scenario} pre-snapshot failed"
  : > "${events}"; : > "${vectors}"; : > "${network}"; : > "${immutable}"
  expected_status="$(direct_expected_status "${scenario}")"
  expected_waits="$(direct_expected_waits "${scenario}")"
  if (
    set +e; set +u; set +o pipefail; umask 022; export LC_ALL=C TZ=UTC
    export CNTOOLS_WALLET_ENCRYPT_SCENARIO="${scenario}"
    export CNTOOLS_WALLET_ENCRYPT_DIRECT_VECTOR_LOG="${vectors}"
    export CNTOOLS_WALLET_ENCRYPT_NETWORK_LOG="${network}"
    export CNTOOLS_WALLET_ENCRYPT_EXPECTED_PASSWORD="${FIXTURE_PASSWORD}"
    export CNTOOLS_WALLET_ENCRYPT_FAULT_MARKER="${capture_root}/fault"
    export CNTOOLS_WALLET_ENCRYPT_IMMUTABLE_STATE="${immutable}"
    CNTOOLS_WALLET_ENCRYPT_REAL_LN="$(type -P ln)"
    CNTOOLS_WALLET_ENCRYPT_REAL_RM="$(type -P rm)"
    CNTOOLS_WALLET_ENCRYPT_REAL_CHMOD="$(type -P chmod)"
    CNTOOLS_WALLET_ENCRYPT_REAL_MKDIR="$(type -P mkdir)"
    CNTOOLS_WALLET_ENCRYPT_REAL_RMDIR="$(type -P rmdir)"
    CNTOOLS_WALLET_ENCRYPT_REAL_MV="$(type -P mv)"
    export CNTOOLS_WALLET_ENCRYPT_REAL_LN CNTOOLS_WALLET_ENCRYPT_REAL_RM
    export CNTOOLS_WALLET_ENCRYPT_REAL_CHMOD CNTOOLS_WALLET_ENCRYPT_REAL_MKDIR
    export CNTOOLS_WALLET_ENCRYPT_REAL_RMDIR CNTOOLS_WALLET_ENCRYPT_REAL_MV
    PATH="${DIRECT_FAKE_BIN}:${BASE_PATH}"; export PATH
    if [[ "${scenario}" == direct-gpg-function-shadow ]]; then
      gpg() { : > "${capture_root}/function-shadow-ran"; return 0; }
    fi
    HOME="${runtime_root}/home"; NODE_HOME="${runtime_root}/home"; TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${wallet_root}"; POOL_FOLDER="${runtime_root}/pool"; ASSET_FOLDER="${runtime_root}/asset"
    WALLET_PAY_SK_FILENAME=payment.skey; WALLET_STAKE_SK_FILENAME=stake.skey
    ENABLE_CHATTR="${chattr_enabled}"; CNTOOLS_MODE="${mode}"; CNTOOLS_MODE_COLOR=""
    FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE="" FG_LBLUE="" NC=""
    EVENT_LOG="${events}"; SCENARIO="${scenario}"; CAPTURE_ACTIVE=N; END_ON_CLEAR=N
    unset password wallet_name
    mkdir -p -- "${private_root}"; chmod 0700 "${private_root}"
    write_direct_context "${context_file}" "${mode}" "${runtime_root}/home"
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" "${context_file}" "${result_file}"
    direct_status=$?
    [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || exit 98
    rm -f -- "${context_file}"; rmdir -- "${private_root}"
    exit "${direct_status}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  [[ "${status}" == "${expected_status}" ]] ||
    fail "${scenario} returned ${status}, expected ${expected_status}"
  wait_count="$(grep -c '^action:waitToProceed$' "${events}" || true)"
  [[ "${wait_count}" == "${expected_waits}" ]] ||
    fail "${scenario} wait count ${wait_count}, expected ${expected_waits}"
  ! grep -Fq 'action:secret:present' "${events}" || fail "${scenario} retained password at wait"
  [[ ! -s "${network}" ]] || fail "${scenario} attempted network access"
  for entry in "${stdout_file}" "${stderr_file}" "${events}" "${vectors}"; do
    ! grep -Fq "${FIXTURE_PASSWORD}" "${entry}" || fail "${scenario} exposed password"
  done
  [[ ! -e "${capture_root}/function-shadow-ran" ]] ||
    fail "${scenario} executed a shadowed GPG function"
  if [[ "${scenario}" == direct-root-backslash ]]; then
    ! grep -Fq '\\033[31mOWNED' "${stdout_file}" "${stderr_file}" ||
      fail 'unsafe root path was reflected'
    ! LC_ALL=C grep -q $'\033' "${stdout_file}" "${stderr_file}" ||
      fail 'unsafe root path emitted a terminal escape'
  fi
  if [[ "${expected_status}" == 70 ]]; then
    grep -Fxq 'CNTools wallet encryption action failed validation.' "${stderr_file}" ||
      fail "${scenario} fixed validation diagnostic changed"
  elif [[ "${scenario}" == direct-postcommit-signal ]]; then
    grep -Fxq 'CNTools wallet encryption committed; interrupted after commit.' \
      "${stderr_file}" || fail 'postcommit signal diagnostic changed'
  else
    [[ ! -s "${stderr_file}" ]] || fail "${scenario} unexpected stderr"
  fi
  case "${scenario}" in
    direct-success-local|direct-success-light|direct-success-offline|direct-success-chattr|direct-postcommit-lock-release|direct-postcommit-backup-cleanup)
      [[ "$(grep -c '^gpg' "${vectors}" || true)" == 2 ]] || fail "${scenario} GPG count changed"
      normalize_direct_output "${stdout_file}" "${normalized}" "${runtime_root}"
      write_direct_success_stdout "${expected}"
      if [[ "${scenario}" == direct-postcommit-lock-release ||
            "${scenario}" == direct-postcommit-backup-cleanup ]]; then
        grep -Fq 'WARNING: wallet encryption committed' "${normalized}" ||
          fail "${scenario} committed warning changed"
      else
        assert_files_equal "${normalized}" "${expected}" "${scenario} exact stdout"
      fi
      assert_direct_success_state "${scenario}" "${runtime_root}"
      ;;
  esac
  [[ ! -e "${wallet_root}/.alpha.cntools-encrypt.lock" ||
     "${scenario}" == direct-lock-contention ||
     "${scenario}" == direct-lock-mkdir-nonzero ||
     "${scenario}" == direct-lock-swap ||
     "${scenario}" == direct-postcommit-lock-release ||
     "${scenario}" == direct-postcommit-backup-cleanup ]] ||
    fail "${scenario} left operation lock"
  tree_snapshot "${runtime_root}" "${after}" || fail "${scenario} post-snapshot failed"
  case "${scenario}" in
    direct-success-*|direct-postcommit-lock-release|direct-postcommit-backup-cleanup|direct-postcommit-signal)
      assert_direct_success_state "${scenario}" "${runtime_root}" ;;
    direct-inventory-race)
      grep -Fv $'f\twallet/alpha/injected.race\t' "${after}" > "${after}.filtered"
      assert_files_equal "${after}.filtered" "${before}" "${scenario} bounded residue" ;;
    direct-source-race)
      sed '/wallet\/alpha\/payment\.skey/d' "${after}" > "${after}.filtered"
      sed '/wallet\/alpha\/payment\.skey/d' "${before}" > "${before}.filtered"
      assert_files_equal "${after}.filtered" "${before}.filtered" "${scenario} bounded residue" ;;
    direct-lock-contention) assert_files_equal "${after}" "${before}" "${scenario} zero mutation" ;;
    direct-lock-mkdir-nonzero)
      grep -v $'^d\twallet/\.alpha\.cntools-encrypt\.lock\t' "${after}" > "${after}.filtered"
      assert_files_equal "${after}.filtered" "${before}" "${scenario} bounded contention residue" ;;
    direct-lock-swap)
      awk -F '\t' '$2 != "wallet/.alpha.cntools-encrypt.lock" &&
        $2 != "wallet/.alpha.cntools-encrypt.lock.captured"' \
        "${after}" > "${after}.filtered"
      assert_files_equal "${after}.filtered" "${before}" "${scenario} preserved replacement authority" ;;
    *) assert_files_equal "${after}" "${before}" "${scenario} zero mutation" ;;
  esac
}

run_case empty OFFLINE
run_case select-fail LOCAL
run_case select-cancel LIGHT
run_case success-local LOCAL
run_case success-light LIGHT
run_case success-offline OFFLINE

write_direct_fake_commands
run_direct_case direct-empty OFFLINE
run_direct_case direct-select-fail LOCAL
run_direct_case direct-select-cancel LIGHT
run_direct_case direct-already-encrypted OFFLINE
run_direct_case direct-password-abort LOCAL
run_direct_case direct-success-local LOCAL
run_direct_case direct-success-light LIGHT
run_direct_case direct-success-offline OFFLINE
run_direct_case direct-success-chattr OFFLINE true
run_direct_case direct-missing-pay OFFLINE
run_direct_case direct-missing-stake OFFLINE
run_direct_case direct-invalid-name OFFLINE
run_direct_case direct-wallet-symlink OFFLINE
run_direct_case direct-symlink-key OFFLINE
run_direct_case direct-hardlink-key OFFLINE
run_direct_case direct-special-leaf OFFLINE
run_direct_case direct-root-mode OFFLINE
run_direct_case direct-wallet-mode OFFLINE
run_direct_case direct-file-mode OFFLINE
run_direct_case direct-root-backslash OFFLINE
run_direct_case direct-lock-contention OFFLINE
run_direct_case direct-gpg-function-shadow OFFLINE
run_direct_case direct-gpg-pay-failure OFFLINE
run_direct_case direct-gpg-stake-failure OFFLINE
run_direct_case direct-gpg-empty OFFLINE
run_direct_case direct-inventory-race OFFLINE
run_direct_case direct-source-race OFFLINE
run_direct_case direct-cipher-link-pay-nonzero OFFLINE
run_direct_case direct-cipher-link-stake-nonzero OFFLINE
run_direct_case direct-backup-link-pay-nonzero OFFLINE
run_direct_case direct-backup-link-stake-nonzero OFFLINE
run_direct_case direct-temp-rm-failure OFFLINE
run_direct_case direct-source-rm-pay-nonzero OFFLINE
run_direct_case direct-source-rm-stake-nonzero OFFLINE
run_direct_case direct-rollback-link-pay-nonzero OFFLINE
run_direct_case direct-rollback-link-stake-nonzero OFFLINE
run_direct_case direct-chmod-failure OFFLINE
run_direct_case direct-chmod-nonzero OFFLINE
run_direct_case direct-chattr-failure OFFLINE true
run_direct_case direct-chattr-late-failure OFFLINE true
run_direct_case direct-chattr-rollback-failure OFFLINE true
run_direct_case direct-lock-mkdir-nonzero OFFLINE
run_direct_case direct-lock-swap OFFLINE
run_direct_case direct-signal-after-lock OFFLINE
run_direct_case direct-signal-gpg OFFLINE
run_direct_case direct-signal-cipher-link OFFLINE
run_direct_case direct-signal-temp-unlink OFFLINE
run_direct_case direct-signal-chmod OFFLINE
run_direct_case direct-signal-chattr OFFLINE true
run_direct_case direct-signal-backup-link OFFLINE
run_direct_case direct-signal-source-unlink OFFLINE
run_direct_case direct-signal-during-cleanup OFFLINE
run_direct_case direct-postcommit-lock-release OFFLINE
run_direct_case direct-postcommit-backup-cleanup OFFLINE
run_direct_case direct-postcommit-signal OFFLINE

arity_root="${TEST_ROOT}/wrong-arity"
mkdir -p -- "${arity_root}/private" "${arity_root}/node"
chmod 0700 "${arity_root}/private"
write_direct_context "${arity_root}/private/context.json" OFFLINE \
  "${arity_root}/node"
if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
    "${arity_root}/private/context.json" \
    "${arity_root}/private/result.json" unexpected \
    > "${arity_root}/stdout" 2> "${arity_root}/stderr"; then
  arity_status=0
else
  arity_status=$?
fi
[[ "${arity_status}" == 64 ]] ||
  fail "wrong-arity dispatch returned ${arity_status}, expected 64"
[[ ! -s "${arity_root}/stdout" && ! -s "${arity_root}/stderr" ]] ||
  fail 'wrong-arity dispatch was not stream-silent'
[[ ! -e "${arity_root}/private/result.json" &&
   ! -L "${arity_root}/private/result.json" ]] ||
  fail 'wrong-arity dispatch unexpectedly produced a result'

encrypt_arm="${TEST_ROOT}/wallet-encrypt-arm"
awk '/^[[:space:]]+encrypt\)/{capture=1}capture{print}capture&&/^[[:space:]]+;;/{exit}' "${CNTOOLS_SCRIPT}" > "${encrypt_arm}"
[[ "$(grep -Fc 'cntools_compatibility_dispatch_action wallet.encrypt' \
  "${encrypt_arm}")" == 1 ]] || fail 'wallet.encrypt generic call count changed'
grep -Fq '0|21) continue ;;' "${encrypt_arm}" || fail 'wallet.encrypt continue mapping changed'
grep -Fq '20) break ;;' "${encrypt_arm}" || fail 'wallet.encrypt parent mapping changed'
grep -Fq '22) myExit 0 "CNTools closed!" ;;' "${encrypt_arm}" || fail 'wallet.encrypt exit mapping changed'
grep -Fq '*) waitToProceed; continue ;;' "${encrypt_arm}" || fail 'wallet.encrypt failure mapping changed'
if grep -Eq 'selectWallet|keyFiles=|encryptFile|lockFile|find .*\.gpg|unset password' \
    "${encrypt_arm}"; then
  fail 'wallet.encrypt inline implementation remains after binding'
fi

grep -Fq 'cntools_action_main() {' "${ACTION_SOURCE}" ||
  fail 'wallet.encrypt modular entrypoint is missing'
grep -Fq '_cntools_action_wallet_encrypt_rollback() {' "${ACTION_SOURCE}" ||
  fail 'wallet.encrypt rollback boundary is missing'
grep -Fq '.cntools-encrypt.lock' "${ACTION_SOURCE}" ||
  fail 'wallet.encrypt operation lock is missing'
grep -Fq -- '--passphrase-fd 0' "${ACTION_SOURCE}" ||
  fail 'wallet.encrypt private password transport changed'
if grep -Eq 'encryptFile|safeDel|rm[[:space:]]+-rf|--passphrase([ =]|$)' \
    "${ACTION_SOURCE}"; then
  fail 'wallet.encrypt action contains a forbidden legacy/destructive primitive'
fi
grep -Fq 'CNTools actions are launched by the dispatcher, not directly.' \
  "${ACTION_SOURCE}" || fail 'wallet.encrypt direct-execution guard changed'

printf 'CNTools wallet-encrypt characterization/parity passed (6 public + 55 direct cases; 14 legacy branches retained)\n'
