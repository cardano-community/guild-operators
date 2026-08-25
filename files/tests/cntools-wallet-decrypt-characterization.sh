#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools wallet-decrypt characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/wallet/decrypt/action.sh"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/wallet/decrypt"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
LEGACY_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f"
SECURITY_SOURCE="${LEGACY_ROOT}/020-terminal-selection-security.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-wallet-decrypt.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
REAL_CHMOD="$(command -v chmod)"
REAL_FIND="$(command -v find)"
REAL_RM="$(command -v rm)"
REAL_RMDIR="$(command -v rmdir)"
REAL_MKDIR="$(command -v mkdir)"
REAL_LN="$(command -v ln)"
DIRECT_FAKE_BIN="${TEST_ROOT}/direct-fake-bin"
FIXTURE_PASSWORD='correct horse battery staple'
WRONG_PASSWORD='incorrect secret phrase'
CONTROL_CIPHER_NAME='evil\033[31m.skey.gpg'

cleanup_test() {
  if [[ "${CNTOOLS_WALLET_DECRYPT_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools wallet-decrypt test root preserved: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  "${REAL_CHMOD}" -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools wallet-decrypt characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"
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
    'set -u' \
    'input="" output="" previous="" normalized="" secret="" content=""' \
    'printf '\''gpg'\'' >> "${CNTOOLS_WALLET_DECRYPT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  [[ "${normalized}" == "${CNTOOLS_WALLET_DECRYPT_ROOT}/"* ]] && normalized="<wallet>/${normalized#"${CNTOOLS_WALLET_DECRYPT_ROOT}/"}"' \
    '  printf '\''\t%q'\'' "${normalized}" >> "${CNTOOLS_WALLET_DECRYPT_VECTOR_LOG}"' \
    '  [[ "${previous}" == --output ]] && output="${argument}"' \
    '  previous="${argument}"' \
    '  input="${argument}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_DECRYPT_VECTOR_LOG}"' \
    'IFS= read -r secret || exit 91' \
    'if [[ "${CNTOOLS_WALLET_DECRYPT_SCENARIO:?}" == wrong-password ]]; then' \
    '  [[ "${secret}" == "${CNTOOLS_WALLET_DECRYPT_WRONG_PASSWORD:?}" ]] || exit 92' \
    '  printf partial-plaintext > "${output}"' \
    '  exit 42' \
    'fi' \
    '[[ "${secret}" == "${CNTOOLS_WALLET_DECRYPT_EXPECTED_PASSWORD:?}" ]] || exit 93' \
    'if [[ "${CNTOOLS_WALLET_DECRYPT_SCENARIO}" == race-swap ]]; then' \
    '  rm -f -- "${input}" || exit 94' \
    '  ln -s -- "${CNTOOLS_WALLET_DECRYPT_OUTSIDE}/cipher.gpg" "${input}" || exit 95' \
    '  content="$(< "${input}")" || exit 96' \
    '  printf '\''decrypted:%s'\'' "${content}" > "${output}"' \
    '  exit 0' \
    'fi' \
    'printf partial-plaintext > "${output}"' \
    'case "${CNTOOLS_WALLET_DECRYPT_SCENARIO}:${input##*/}" in' \
    '  multi-first:c.skey.gpg|multi-middle:b.skey.gpg|multi-last:a.skey.gpg|control-filename:*) exit 42 ;;' \
    'esac' \
    'printf complete-plaintext > "${output}"' \
    > "${FAKE_BIN}/gpg"
  chmod 0755 "${FAKE_BIN}/gpg"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'normalized=""' \
    'printf '\''chmod'\'' >> "${CNTOOLS_WALLET_DECRYPT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  [[ "${normalized}" == "${CNTOOLS_WALLET_DECRYPT_ROOT}/"* ]] && normalized="<wallet>/${normalized#"${CNTOOLS_WALLET_DECRYPT_ROOT}/"}"' \
    '  printf '\''\t%q'\'' "${normalized}" >> "${CNTOOLS_WALLET_DECRYPT_VECTOR_LOG}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_DECRYPT_VECTOR_LOG}"' \
    'case "${CNTOOLS_WALLET_DECRYPT_SCENARIO:?}:${*: -1}" in' \
    '  unlock-chmod-failure:*) exit 42 ;;' \
    '  decrypted-chmod-failure:*/payment.skey) exit 42 ;;' \
    'esac' \
    'exec "${CNTOOLS_WALLET_DECRYPT_REAL_CHMOD:?}" "$@"' \
    > "${FAKE_BIN}/chmod"
  chmod 0755 "${FAKE_BIN}/chmod"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'normalized=""' \
    'printf '\''lsattr'\'' >> "${CNTOOLS_WALLET_DECRYPT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  [[ "${normalized}" == "${CNTOOLS_WALLET_DECRYPT_ROOT}/"* ]] && normalized="<wallet>/${normalized#"${CNTOOLS_WALLET_DECRYPT_ROOT}/"}"' \
    '  printf '\''\t%q'\'' "${normalized}" >> "${CNTOOLS_WALLET_DECRYPT_VECTOR_LOG}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_DECRYPT_VECTOR_LOG}"' \
    '[[ "${CNTOOLS_WALLET_DECRYPT_SCENARIO:?}" != lsattr-failure ]] || exit 42' \
    'printf -- '\''----i-------------- %s\n'\'' "${*: -1}"' \
    > "${FAKE_BIN}/lsattr"
  chmod 0755 "${FAKE_BIN}/lsattr"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'normalized=""' \
    'printf '\''sudo'\'' >> "${CNTOOLS_WALLET_DECRYPT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do' \
    '  normalized="${argument}"' \
    '  [[ "${normalized}" == "${CNTOOLS_WALLET_DECRYPT_ROOT}/"* ]] && normalized="<wallet>/${normalized#"${CNTOOLS_WALLET_DECRYPT_ROOT}/"}"' \
    '  printf '\''\t%q'\'' "${normalized}" >> "${CNTOOLS_WALLET_DECRYPT_VECTOR_LOG}"' \
    'done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_DECRYPT_VECTOR_LOG}"' \
    '[[ "${CNTOOLS_WALLET_DECRYPT_SCENARIO:?}" != chattr-failure ]]' \
    > "${FAKE_BIN}/sudo"
  chmod 0755 "${FAKE_BIN}/sudo"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'if [[ "${CNTOOLS_WALLET_DECRYPT_SCENARIO:?}" == race-add && ! -e "${CNTOOLS_WALLET_DECRYPT_RACE_MARKER:?}" && " $* " == *" -name *.gpg "* ]]; then' \
    '  printf late-cipher > "${CNTOOLS_WALLET_DECRYPT_ROOT}/alpha/late.skey.gpg"' \
    '  "${CNTOOLS_WALLET_DECRYPT_REAL_CHMOD:?}" 0400 "${CNTOOLS_WALLET_DECRYPT_ROOT}/alpha/late.skey.gpg"' \
    '  : > "${CNTOOLS_WALLET_DECRYPT_RACE_MARKER}"' \
    'fi' \
    'exec "${CNTOOLS_WALLET_DECRYPT_REAL_FIND:?}" "$@"' \
    > "${FAKE_BIN}/find"
  chmod 0755 "${FAKE_BIN}/find"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s\n'\'' "${0##*/}" >> "${CNTOOLS_WALLET_DECRYPT_BLOCKED_LOG:?}"' \
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
  local result_file="" status=0 capture_vectors="${CNTOOLS_WALLET_DECRYPT_VECTOR_LOG:-}"

  [[ "${action_id}" == wallet.decrypt && $# == 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  CNTOOLS_WALLET_DECRYPT_VECTOR_LOG=/dev/null
  export CNTOOLS_WALLET_DECRYPT_VECTOR_LOG
  umask 077
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/wallet-decrypt-test-dispatch.XXXXXXXX")" || return 70
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
  CNTOOLS_WALLET_DECRYPT_VECTOR_LOG="${capture_vectors}"
  export CNTOOLS_WALLET_DECRYPT_VECTOR_LOG
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
     ! grep -Fqx 'action:end' "${EVENT_LOG}"; then
    printf '__CNTOOLS_WALLET_DECRYPT_END__\n'
    printf 'action:end\n' >> "${EVENT_LOG}"
  fi
  return "${status}"
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
  if [[ "${CAPTURE_ACTIVE:-N}" == Y && "${END_ON_CLEAR:-N}" == Y ]]; then
    printf '__CNTOOLS_WALLET_DECRYPT_END__\n'
    printf 'action:end\n' >> "${EVENT_LOG:?}"
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
  fi
  printf 'terminal:clear\n' >> "${EVENT_LOG:?}"
}

getEpoch() { printf 5; }
timeUntilNextEpoch() { printf 0; }
timeLeft() { printf 0; }
slotInterval() { printf 20; }
getSlotTipRef() { printf 1000; }
getNodeMetrics() { printf 'runtime:getNodeMetrics\n' >> "${EVENT_LOG:?}"; slotnum=1000; }
getPriceInfo() { printf 'runtime:getPriceInfo\n' >> "${EVENT_LOG:?}"; price_now=""; }
updateProtocolParams() { printf 'runtime:updateProtocolParams\n' >> "${EVENT_LOG:?}"; }

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}" menu="" option="" index=0
  case "${1:-}" in
    '[w] Wallet') menu=main ;;
    '[n] New') menu=wallet ;;
    *) fail 'unexpected menu contract' ;;
  esac
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == wallet:d ]]; then
        CAPTURE_ACTIVE=Y
        printf '__CNTOOLS_WALLET_DECRYPT_BEGIN__\n'
        printf 'action:begin\n' >> "${EVENT_LOG}"
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice unavailable: ${menu}:${choice}"
}

selectWallet() {
  [[ "${1:-}" == encrypted ]] || fail 'wallet-decrypt selector contract changed'
  printf 'action:selectWallet:encrypted\n' >> "${EVENT_LOG:?}"
  case "${SCENARIO:?}" in
    select-fail) return 1 ;;
    select-cancel) return 2 ;;
    selector-empty) builtin unset wallet_name 2>/dev/null || true; return 0 ;;
    traversal) wallet_name='../outside-wallet' ;;
    *) wallet_name=alpha ;;
  esac
}

getPasswordCust() {
  [[ "$#" == 0 ]] || fail 'wallet-decrypt password prompt arguments changed'
  printf 'action:password\n' >> "${EVENT_LOG:?}"
  if [[ "${SCENARIO:?}" == wrong-password ]]; then
    password="${WRONG_PASSWORD}"
  else
    password="${FIXTURE_PASSWORD}"
  fi
  [[ "${SCENARIO}" != password-abort ]]
}

waitToProceed() {
  printf 'action:secret:%s\n' "$([[ -v password ]] && printf present || printf unset)" >> "${EVENT_LOG:?}"
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${DIRECT_ACTIVE:-N}" == Y ]]; then
    if [[ -d "${WALLET_FOLDER:-}/.alpha.cntools-decrypt.lock" ]]; then
      printf 'action:lock:present\n' >> "${EVENT_LOG}"
    else
      printf 'action:lock:absent\n' >> "${EVENT_LOG}"
    fi
    if [[ "${CNTOOLS_WALLET_DECRYPT_DIRECT_SCENARIO:-}" == \
          direct-postcommit-signal ]]; then
      kill -TERM "${BASHPID}"
    fi
  fi
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    printf '__CNTOOLS_WALLET_DECRYPT_END__\n'
    printf 'action:end\n' >> "${EVENT_LOG}"
    CAPTURE_ACTIVE=N
  fi
}

myExit() {
  printf 'exit:%s:%s\n' "${1:-0}" "${2:-}" >> "${EVENT_LOG:?}"
  exit "${1:-0}"
}

extract_between() {
  local source="$1" target="$2" begin="$3" end="$4"
  [[ "$(grep -c -F -x -- "${begin}" "${source}" || true)" == 1 &&
     "$(grep -c -F -x -- "${end}" "${source}" || true)" == 1 ]] ||
    fail "markers changed in ${source##*/}"
  awk -v begin="${begin}" -v end="${end}" '
    $0 == begin { capture=1; next }
    $0 == end { exit }
    capture { print }
  ' "${source}" > "${target}"
}

extract_action_events() {
  local source="$1" target="$2"
  awk '
    $0 == "action:begin" { capture=1 }
    capture { print }
    $0 == "action:end" { exit }
  ' "${source}" > "${target}"
}

normalize_action_output() {
  local source="$1" target="$2" wallet_root="$3" line=""
  : > "${target}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '%s\n' "${line//${wallet_root}/<wallet>}" >> "${target}"
  done < "${source}"
}

fixture_file() {
  local target="$1" content="$2" mode="$3"
  mkdir -p -- "${target%/*}"
  printf '%s' "${content}" > "${target}"
  "${REAL_CHMOD}" "${mode}" "${target}"
}

setup_wallet() {
  local scenario="$1" wallet_root="$2" runtime="$3" outside="$4"
  [[ "${scenario}" != empty ]] || return 0
  mkdir -p -- "${wallet_root}/alpha"
  case "${scenario}" in
    select-fail|select-cancel)
      fixture_file "${wallet_root}/alpha/public.vkey" public 0400
      ;;
    already-unlocked)
      fixture_file "${wallet_root}/alpha/public.vkey" public 0600
      ;;
    password-abort)
      fixture_file "${wallet_root}/alpha/public.vkey" public 0400
      fixture_file "${wallet_root}/alpha/payment.skey.gpg" cipher 0400
      ;;
    wrong-password|decrypted-chmod-failure|success-local|success-light|success-offline)
      fixture_file "${wallet_root}/alpha/payment.skey.gpg" cipher 0400
      fixture_file "${wallet_root}/alpha/public.vkey" public 0400
      ;;
    multi-first|multi-middle|multi-last)
      fixture_file "${wallet_root}/alpha/a.skey.gpg" cipher-a 0400
      fixture_file "${wallet_root}/alpha/b.skey.gpg" cipher-b 0400
      fixture_file "${wallet_root}/alpha/c.skey.gpg" cipher-c 0400
      ;;
    unlock-chmod-failure|lsattr-failure|chattr-success|chattr-failure)
      fixture_file "${wallet_root}/alpha/public.vkey" public 0400
      ;;
    symlink-file)
      fixture_file "${outside}/plain.key" outside-secret 0400
      ln -s -- "${outside}/plain.key" "${wallet_root}/alpha/plain.key"
      ;;
    hardlink-file)
      fixture_file "${outside}/plain.key" outside-secret 0400
      ln -- "${outside}/plain.key" "${wallet_root}/alpha/plain.key"
      ;;
    hardlink-cipher)
      fixture_file "${outside}/payment.skey.gpg" outside-cipher 0400
      ln -- "${outside}/payment.skey.gpg" "${wallet_root}/alpha/payment.skey.gpg"
      ;;
    traversal)
      mkdir -p -- "${runtime}/outside-wallet"
      fixture_file "${runtime}/outside-wallet/plain.key" outside-wallet-secret 0400
      ;;
    race-add)
      fixture_file "${wallet_root}/alpha/trigger.key" trigger 0400
      ;;
    race-swap)
      fixture_file "${wallet_root}/alpha/payment.skey.gpg" inside-cipher 0400
      fixture_file "${outside}/cipher.gpg" outside-cipher 0400
      ;;
    control-filename)
      fixture_file "${wallet_root}/alpha/${CONTROL_CIPHER_NAME}" cipher 0400
      ;;
    *) fail "unknown fixture scenario: ${scenario}" ;;
  esac
}

CONTRACT_WALLET_NAME=alpha
CONTRACT_ENABLE_CHATTR=false
CONTRACT_PASSWORD=false
CONTRACT_PASSWORD_ABORT=false
CONTRACT_UNLOCK_FILES=()
CONTRACT_GPG_FILES=()

load_contract() {
  local scenario="$1"
  CONTRACT_WALLET_NAME=alpha
  CONTRACT_ENABLE_CHATTR=false
  CONTRACT_PASSWORD=false
  CONTRACT_PASSWORD_ABORT=false
  CONTRACT_UNLOCK_FILES=()
  CONTRACT_GPG_FILES=()
  case "${scenario}" in
    empty|select-fail|select-cancel) ;;
    already-unlocked|unlock-chmod-failure|lsattr-failure|chattr-success|chattr-failure)
      CONTRACT_UNLOCK_FILES=(public.vkey)
      ;;
    password-abort)
      CONTRACT_UNLOCK_FILES=(public.vkey payment.skey.gpg)
      CONTRACT_GPG_FILES=(payment.skey.gpg)
      CONTRACT_PASSWORD=true
      CONTRACT_PASSWORD_ABORT=true
      ;;
    wrong-password|decrypted-chmod-failure|success-local|success-light|success-offline)
      CONTRACT_UNLOCK_FILES=(public.vkey payment.skey.gpg)
      CONTRACT_GPG_FILES=(payment.skey.gpg)
      CONTRACT_PASSWORD=true
      ;;
    multi-first|multi-middle|multi-last)
      CONTRACT_UNLOCK_FILES=(c.skey.gpg b.skey.gpg a.skey.gpg)
      CONTRACT_GPG_FILES=(c.skey.gpg b.skey.gpg a.skey.gpg)
      CONTRACT_PASSWORD=true
      ;;
    symlink-file) ;;
    hardlink-file)
      CONTRACT_UNLOCK_FILES=(plain.key)
      ;;
    hardlink-cipher)
      CONTRACT_UNLOCK_FILES=(payment.skey.gpg)
      CONTRACT_GPG_FILES=(payment.skey.gpg)
      CONTRACT_PASSWORD=true
      ;;
    traversal)
      CONTRACT_WALLET_NAME='../outside-wallet'
      CONTRACT_UNLOCK_FILES=(plain.key)
      ;;
    race-add)
      CONTRACT_UNLOCK_FILES=(trigger.key)
      CONTRACT_GPG_FILES=(late.skey.gpg)
      CONTRACT_PASSWORD=true
      ;;
    race-swap)
      CONTRACT_UNLOCK_FILES=(payment.skey.gpg)
      CONTRACT_GPG_FILES=(payment.skey.gpg)
      CONTRACT_PASSWORD=true
      ;;
    control-filename)
      CONTRACT_UNLOCK_FILES=("${CONTROL_CIPHER_NAME}")
      CONTRACT_GPG_FILES=("${CONTROL_CIPHER_NAME}")
      CONTRACT_PASSWORD=true
      ;;
    *) fail "unknown contract scenario: ${scenario}" ;;
  esac
  case "${scenario}" in
    lsattr-failure|chattr-success|chattr-failure) CONTRACT_ENABLE_CHATTR=true ;;
  esac
}

normalized_wallet_file() {
  local relative="$1"
  printf '<wallet>/%s/%s' "${CONTRACT_WALLET_NAME}" "${relative}"
}

gpg_succeeds() {
  local scenario="$1" relative="$2"
  case "${scenario}:${relative}" in
    wrong-password:*|multi-first:c.skey.gpg|multi-middle:b.skey.gpg|multi-last:a.skey.gpg|control-filename:*) return 1 ;;
    *) return 0 ;;
  esac
}

expected_action_output() {
  local scenario="$1" target="$2" relative="" path="" unlocked=0 decrypted=0
  load_contract "${scenario}"
  : > "${target}"
  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> WALLET >> DECRYPT' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    '' >> "${target}"
  if [[ "${scenario}" == empty ]]; then
    printf '%s\n' 'No wallets available!' >> "${target}"
    return 0
  fi
  printf '%s\n' 'Select wallet to decrypt' >> "${target}"
  case "${scenario}" in select-fail|select-cancel) return 0 ;; esac
  printf '%s\n' '' 'Removing write protection from all wallet files' >> "${target}"
  for relative in "${CONTRACT_UNLOCK_FILES[@]}"; do
    path="$(normalized_wallet_file "${relative}")"
    printf '%b\n' "${path}" >> "${target}"
    unlocked=$((unlocked + 1))
  done
  if [[ "${CONTRACT_PASSWORD}" == true ]]; then
    printf '%s\n' '' 'Decrypting GPG encrypted wallet files' '' >> "${target}"
    if [[ "${CONTRACT_PASSWORD_ABORT}" == true ]]; then
      printf '\n\n\n' >> "${target}"
      printf '%s\n' 'ERROR: password input aborted!' >> "${target}"
      return 0
    fi
    for relative in "${CONTRACT_GPG_FILES[@]}"; do
      path="$(normalized_wallet_file "${relative}")"
      if gpg_succeeds "${scenario}" "${relative}"; then
        printf '%b\n' "${path} successfully decrypted" >> "${target}"
        [[ "${scenario}" == decrypted-chmod-failure ]] || decrypted=$((decrypted + 1))
      else
        printf '%b\n' "ERROR: failed to decrypt ${path}" >> "${target}"
      fi
    done
  fi
  printf '%s\n' \
    '' \
    "Wallet unprotected : ${CONTRACT_WALLET_NAME}" \
    "Files unlocked     : ${unlocked}" \
    "Files decrypted    : ${decrypted}" >> "${target}"
  if (( unlocked != 0 || decrypted != 0 )); then
    printf '%s\n' \
      '' \
      'Wallet files are now unprotected' \
      "Use 'WALLET >> ENCRYPT' to re-lock" >> "${target}"
  fi
}

expected_bound_action_output() {
  local scenario="$1" target="$2"
  : > "${target}"
  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> WALLET >> DECRYPT' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    '' >> "${target}"
  if [[ "${scenario}" == empty ]]; then
    printf '%s\n' 'No wallets available!' >> "${target}"
    return 0
  fi
  printf '%s\n' 'Select wallet to decrypt' >> "${target}"
  case "${scenario}" in select-fail|select-cancel) return 0 ;; esac
  printf '%s\n' \
    '' \
    'Removing write protection from all wallet files' \
    '<wallet>/alpha/payment.skey.gpg' \
    '<wallet>/alpha/public.vkey' \
    '' \
    'Decrypting GPG encrypted wallet files' \
    '<wallet>/alpha/payment.skey.gpg successfully decrypted' \
    '' \
    'Wallet unprotected : alpha' \
    'Files unlocked     : 2' \
    'Files decrypted    : 1' \
    '' \
    'Wallet files are now unprotected' \
    "Use 'WALLET >> ENCRYPT' to re-lock" >> "${target}"
}

expected_action_events() {
  local scenario="$1" target="$2"
  load_contract "${scenario}"
  printf '%s\n' 'action:begin' 'action:compatibility-dispatch' \
    'terminal:clear' > "${target}"
  if [[ "${scenario}" == empty ]]; then
    printf '%s\n' 'action:secret:unset' 'action:waitToProceed' 'action:end' >> "${target}"
    return 0
  fi
  printf '%s\n' 'action:selectWallet:encrypted' >> "${target}"
  case "${scenario}" in
    select-fail)
      printf '%s\n' 'action:secret:unset' 'action:waitToProceed' 'action:end' >> "${target}"
      return 0
      ;;
    select-cancel)
      printf '%s\n' 'action:end' >> "${target}"
      return 0
      ;;
  esac
  [[ "${CONTRACT_PASSWORD}" == true ]] && printf '%s\n' 'action:password' >> "${target}"
  if [[ "${CONTRACT_PASSWORD_ABORT}" == true ]]; then
    printf '%s\n' 'action:secret:present' 'action:waitToProceed' 'action:end' >> "${target}"
  else
    printf '%s\n' 'action:secret:unset' 'action:waitToProceed' 'action:end' >> "${target}"
  fi
}

vector_line() {
  local target="$1" command_name="$2" argument=""
  shift 2
  printf '%s' "${command_name}" >> "${target}"
  for argument in "$@"; do printf '\t%q' "${argument}" >> "${target}"; done
  printf '\n' >> "${target}"
}

expected_vectors() {
  local scenario="$1" target="$2" relative="" path="" output=""
  load_contract "${scenario}"
  : > "${target}"
  for relative in "${CONTRACT_UNLOCK_FILES[@]}"; do
    path="$(normalized_wallet_file "${relative}")"
    if [[ "${CONTRACT_ENABLE_CHATTR}" == true ]]; then
      vector_line "${target}" lsattr -R "${path}"
      case "${scenario}" in chattr-success|chattr-failure) vector_line "${target}" sudo chattr -i "${path}" ;; esac
    fi
    vector_line "${target}" chmod 600 "${path}"
  done
  [[ "${CONTRACT_PASSWORD_ABORT}" == false ]] || return 0
  for relative in "${CONTRACT_GPG_FILES[@]}"; do
    path="$(normalized_wallet_file "${relative}")"
    output="${path%.gpg}"
    vector_line "${target}" gpg --decrypt --batch --yes --passphrase-fd 0 --output "${output}" "${path}"
    if gpg_succeeds "${scenario}" "${relative}"; then
      vector_line "${target}" chmod 600 "${output}"
    fi
  done
}

expected_bound_vectors() {
  local scenario="$1" target="$2"
  : > "${target}"
  case "${scenario}" in
    success-local|success-light|success-offline)
      vector_line "${target}" chmod 0600 \
        '<wallet>/.alpha.cntools-decrypt.lock/plain.0.TEMP'
      vector_line "${target}" gpg --decrypt --batch --yes --no-tty \
        --pinentry-mode loopback --passphrase-fd 0 --output \
        '<wallet>/.alpha.cntools-decrypt.lock/plain.0.TEMP' -- \
        '<wallet>/alpha/payment.skey.gpg'
      vector_line "${target}" chmod 0600 '<wallet>/alpha/payment.skey.gpg'
      vector_line "${target}" chmod 0600 '<wallet>/alpha/public.vkey'
      ;;
  esac
}

normalize_bound_vectors() {
  local source="$1" target="$2"
  sed -E 's#(plain\.[0-9]+\.)[A-Za-z0-9]+#\1TEMP#g' \
    "${source}" > "${target}"
}

filter_snapshot() {
  local source="$1" target="$2" line="" relative="" allowed="" encoded="" skip=false
  shift 2
  : > "${target}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    relative="${line#*$'\t'}"
    relative="${relative%%$'\t'*}"
    skip=false
    for allowed in "$@"; do
      printf -v encoded '%q' "${allowed}"
      if [[ "${relative}" == "${encoded}" ]]; then skip=true; break; fi
    done
    [[ "${skip}" == true ]] || printf '%s\n' "${line}" >> "${target}"
  done < "${source}"
}

assert_only_mutations() {
  local before="$1" after="$2" context="$3"
  shift 3
  local filtered_before="${before}.filtered" filtered_after="${after}.filtered"
  filter_snapshot "${before}" "${filtered_before}" "$@"
  filter_snapshot "${after}" "${filtered_after}" "$@"
  assert_files_equal "${filtered_after}" "${filtered_before}" "${context} mutation allowlist"
}

file_link_count() {
  local target="$1" count=""
  if count="$(stat -f '%l' "${target}" 2>/dev/null)"; then :
  else count="$(stat -c '%h' -- "${target}" 2>/dev/null)" || return 1; fi
  printf '%s\n' "${count}"
}

assert_file() {
  local target="$1" mode="$2" content="$3" actual=""
  [[ -f "${target}" && ! -L "${target}" ]] || fail "expected regular file missing: ${target}"
  [[ "$(file_mode "${target}")" == "${mode}" ]] || fail "mode changed for ${target}"
  actual="$(< "${target}")"
  [[ "${actual}" == "${content}" ]] || fail "content changed for ${target}"
}

assert_mutation() {
  local scenario="$1" wallet_root="$2" runtime="$3" outside="$4" before="$5" after="$6"
  local control_plain="${CONTROL_CIPHER_NAME%.gpg}"
  case "${scenario}" in
    empty|select-fail|select-cancel|already-unlocked|unlock-chmod-failure|symlink-file)
      assert_files_equal "${after}" "${before}" "${scenario} zero mutation"
      ;;
    password-abort)
      assert_only_mutations "${before}" "${after}" "${scenario}" \
        wallet/alpha/public.vkey wallet/alpha/payment.skey.gpg
      assert_file "${wallet_root}/alpha/public.vkey" 600 public
      assert_file "${wallet_root}/alpha/payment.skey.gpg" 600 cipher
      [[ ! -e "${wallet_root}/alpha/payment.skey" ]] || fail 'password abort created plaintext'
      ;;
    wrong-password)
      assert_only_mutations "${before}" "${after}" "${scenario}" \
        wallet/alpha/payment.skey.gpg wallet/alpha/payment.skey wallet/alpha/public.vkey
      assert_file "${wallet_root}/alpha/payment.skey.gpg" 600 cipher
      assert_file "${wallet_root}/alpha/payment.skey" 644 partial-plaintext
      assert_file "${wallet_root}/alpha/public.vkey" 600 public
      ;;
    success-local|success-light|success-offline)
      assert_only_mutations "${before}" "${after}" "${scenario}" \
        wallet/alpha/payment.skey.gpg wallet/alpha/payment.skey wallet/alpha/public.vkey
      [[ ! -e "${wallet_root}/alpha/payment.skey.gpg" ]] || fail "${scenario} ciphertext remained"
      assert_file "${wallet_root}/alpha/payment.skey" 600 complete-plaintext
      assert_file "${wallet_root}/alpha/public.vkey" 600 public
      ;;
    multi-first|multi-middle|multi-last)
      assert_only_mutations "${before}" "${after}" "${scenario}" \
        wallet/alpha/a.skey.gpg wallet/alpha/a.skey \
        wallet/alpha/b.skey.gpg wallet/alpha/b.skey \
        wallet/alpha/c.skey.gpg wallet/alpha/c.skey
      local item="" failed=""
      case "${scenario}" in multi-first) failed=c ;; multi-middle) failed=b ;; multi-last) failed=a ;; esac
      for item in a b c; do
        if [[ "${item}" == "${failed}" ]]; then
          assert_file "${wallet_root}/alpha/${item}.skey.gpg" 600 "cipher-${item}"
          assert_file "${wallet_root}/alpha/${item}.skey" 644 partial-plaintext
        else
          [[ ! -e "${wallet_root}/alpha/${item}.skey.gpg" ]] || fail "${scenario} successful ciphertext remained"
          assert_file "${wallet_root}/alpha/${item}.skey" 600 complete-plaintext
        fi
      done
      ;;
    decrypted-chmod-failure)
      assert_only_mutations "${before}" "${after}" "${scenario}" \
        wallet/alpha/payment.skey.gpg wallet/alpha/payment.skey wallet/alpha/public.vkey
      [[ ! -e "${wallet_root}/alpha/payment.skey.gpg" ]] || fail 'post-decrypt chmod failure restored ciphertext'
      assert_file "${wallet_root}/alpha/payment.skey" 644 complete-plaintext
      assert_file "${wallet_root}/alpha/public.vkey" 600 public
      ;;
    lsattr-failure|chattr-success|chattr-failure)
      assert_only_mutations "${before}" "${after}" "${scenario}" wallet/alpha/public.vkey
      assert_file "${wallet_root}/alpha/public.vkey" 600 public
      ;;
    hardlink-file)
      assert_only_mutations "${before}" "${after}" "${scenario}" wallet/alpha/plain.key outside/plain.key
      assert_file "${wallet_root}/alpha/plain.key" 600 outside-secret
      assert_file "${outside}/plain.key" 600 outside-secret
      [[ "$(file_link_count "${wallet_root}/alpha/plain.key")" == 2 ]] || fail 'plaintext hardlink topology changed'
      ;;
    hardlink-cipher)
      assert_only_mutations "${before}" "${after}" "${scenario}" \
        wallet/alpha/payment.skey.gpg wallet/alpha/payment.skey outside/payment.skey.gpg
      [[ ! -e "${wallet_root}/alpha/payment.skey.gpg" ]] || fail 'wallet ciphertext hardlink remained'
      assert_file "${wallet_root}/alpha/payment.skey" 600 complete-plaintext
      assert_file "${outside}/payment.skey.gpg" 600 outside-cipher
      [[ "$(file_link_count "${outside}/payment.skey.gpg")" == 1 ]] || fail 'outside cipher hardlink count changed'
      ;;
    traversal)
      assert_only_mutations "${before}" "${after}" "${scenario}" outside-wallet/plain.key
      assert_file "${runtime}/outside-wallet/plain.key" 600 outside-wallet-secret
      ;;
    race-add)
      assert_only_mutations "${before}" "${after}" "${scenario}" \
        wallet/alpha/trigger.key wallet/alpha/late.skey.gpg wallet/alpha/late.skey
      assert_file "${wallet_root}/alpha/trigger.key" 600 trigger
      [[ ! -e "${wallet_root}/alpha/late.skey.gpg" ]] || fail 'late ciphertext remained'
      assert_file "${wallet_root}/alpha/late.skey" 600 complete-plaintext
      ;;
    race-swap)
      assert_only_mutations "${before}" "${after}" "${scenario}" \
        wallet/alpha/payment.skey.gpg wallet/alpha/payment.skey
      [[ ! -e "${wallet_root}/alpha/payment.skey.gpg" ]] || fail 'swapped cipher path remained'
      assert_file "${wallet_root}/alpha/payment.skey" 600 decrypted:outside-cipher
      assert_file "${outside}/cipher.gpg" 400 outside-cipher
      ;;
    control-filename)
      assert_only_mutations "${before}" "${after}" "${scenario}" \
        "wallet/alpha/${CONTROL_CIPHER_NAME}" "wallet/alpha/${control_plain}"
      assert_file "${wallet_root}/alpha/${CONTROL_CIPHER_NAME}" 600 cipher
      assert_file "${wallet_root}/alpha/${control_plain}" 644 partial-plaintext
      ;;
    *) fail "unknown mutation scenario: ${scenario}" ;;
  esac
}

run_case() (
  local scenario="$1" mode="$2" case_root="" runtime="" wallet="" outside=""
  local stdout="" raw_action="" action="" stderr="" events="" action_events=""
  local vectors="" expected_output="" expected_events="" expected_vector_file=""
  local navigation="" expected_navigation="" blocked="" before="" after="" status=0
  case_root="${TEST_ROOT}/cases/${scenario}"
  runtime="${case_root}/runtime"
  wallet="${runtime}/wallet"
  outside="${runtime}/outside"
  stdout="${case_root}/full.stdout"
  raw_action="${case_root}/raw-action.stdout"
  action="${case_root}/action.stdout"
  stderr="${case_root}/stderr"
  events="${case_root}/events"
  action_events="${case_root}/action.events"
  vectors="${case_root}/vectors"
  expected_output="${case_root}/expected.stdout"
  expected_events="${case_root}/expected.events"
  expected_vector_file="${case_root}/expected.vectors"
  navigation="${case_root}/navigation"
  expected_navigation="${case_root}/expected.navigation"
  blocked="${case_root}/blocked"
  before="${case_root}/before.tree"
  after="${case_root}/after.tree"
  mkdir -p -- "${wallet}" "${outside}" "${runtime}/home" "${runtime}/tmp" "${runtime}/pool" "${runtime}/asset"
  setup_wallet "${scenario}" "${wallet}" "${runtime}" "${outside}"
  tree_snapshot "${runtime}" "${before}" || fail "${scenario} pre-snapshot failed"
  : > "${events}"
  : > "${vectors}"
  : > "${blocked}"
  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    PATH="${FAKE_BIN}:${BASE_PATH}"
    export PATH
    HOME="${runtime}/home"
    NODE_HOME="${runtime}/home"
    TMP_DIR="${runtime}/tmp"
    WALLET_FOLDER="${wallet}"
    POOL_FOLDER="${runtime}/pool"
    ASSET_FOLDER="${runtime}/asset"
    BLOCKLOG_DB="${runtime}/absent.db"
    ADVANCED_MODE=true
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    ENABLE_CHATTR=false
    case "${scenario}" in lsattr-failure|chattr-success|chattr-failure) ENABLE_CHATTR=true ;; esac
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE="" FG_MAGENTA="" FG_CYAN=""
    FG_LGRAY="" FG_DGRAY="" FG_LBLUE="" FG_WHITE="" NC=""
    EVENT_LOG="${events}"
    SCENARIO="${scenario}"
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
    export CNTOOLS_WALLET_DECRYPT_VECTOR_LOG="${vectors}"
    export CNTOOLS_WALLET_DECRYPT_BLOCKED_LOG="${blocked}"
    export CNTOOLS_WALLET_DECRYPT_ROOT="${wallet}"
    export CNTOOLS_WALLET_DECRYPT_OUTSIDE="${outside}"
    export CNTOOLS_WALLET_DECRYPT_EXPECTED_PASSWORD="${FIXTURE_PASSWORD}"
    export CNTOOLS_WALLET_DECRYPT_WRONG_PASSWORD="${WRONG_PASSWORD}"
    export CNTOOLS_WALLET_DECRYPT_SCENARIO="${scenario}"
    export CNTOOLS_WALLET_DECRYPT_REAL_CHMOD="${REAL_CHMOD}"
    export CNTOOLS_WALLET_DECRYPT_REAL_FIND="${REAL_FIND}"
    export CNTOOLS_WALLET_DECRYPT_RACE_MARKER="${case_root}/race.marker"
    unset password SUBCOMMAND OPERATION
    CHOICES=(w d h q)
    CHOICE_CURSOR=0
    main
    exit 99
  ) > "${stdout}" 2> "${stderr}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == 0 ]] || fail "${scenario} traversal returned ${status}"
  extract_between "${stdout}" "${raw_action}" '__CNTOOLS_WALLET_DECRYPT_BEGIN__' '__CNTOOLS_WALLET_DECRYPT_END__'
  normalize_action_output "${raw_action}" "${action}" "${wallet}"
  expected_bound_action_output "${scenario}" "${expected_output}"
  assert_files_equal "${action}" "${expected_output}" "${scenario} stdout"
  [[ ! -s "${stderr}" ]] || fail "${scenario} unexpected stderr"

  extract_action_events "${events}" "${action_events}"
  expected_action_events "${scenario}" "${expected_events}"
  assert_files_equal "${action_events}" "${expected_events}" "${scenario} events"
  grep -E '^(menu:|exit:)' "${events}" > "${navigation}"
  printf '%s\n' \
    'menu:main:w' \
    'menu:wallet:d' \
    'menu:wallet:h' \
    'menu:main:q' \
    'exit:0:CNTools closed!' > "${expected_navigation}"
  assert_files_equal "${navigation}" "${expected_navigation}" "${scenario} navigation"

  expected_bound_vectors "${scenario}" "${expected_vector_file}"
  normalize_bound_vectors "${vectors}" "${vectors}.normalized"
  assert_files_equal "${vectors}.normalized" "${expected_vector_file}" \
    "${scenario} tool vectors"
  [[ ! -s "${blocked}" ]] || fail "${scenario} attempted external access"
  ! grep -Fq "${FIXTURE_PASSWORD}" "${stdout}" "${stderr}" "${events}" "${vectors}" || fail "${scenario} password leaked"
  ! grep -Fq "${WRONG_PASSWORD}" "${stdout}" "${stderr}" "${events}" "${vectors}" || fail "${scenario} wrong password leaked"
  if [[ "${scenario}" == control-filename ]]; then
    LC_ALL=C grep -q "$(printf '\033')" "${action}" || fail 'control filename was no longer interpreted by terminal output'
  fi

  tree_snapshot "${runtime}" "${after}" || fail "${scenario} post-snapshot failed"
  assert_mutation "${scenario}" "${wallet}" "${runtime}" "${outside}" "${before}" "${after}"
)

run_case empty OFFLINE
run_case select-fail LOCAL
run_case select-cancel LIGHT
run_case success-local LOCAL
run_case success-light LIGHT
run_case success-offline OFFLINE

write_direct_context() {
  local target="$1" mode="$2" node_home="$3"

  jq -nS --arg mode "${mode,,}" --arg node_home "${node_home}" '
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
  ' > "${target}"
  chmod 0400 "${target}"
}

write_direct_fake_commands() {
  local command_name=""

  mkdir -p -- "${DIRECT_FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_DECRYPT_DIRECT_SCENARIO:?}" input="${*: -1}" output="" previous="" secret=""' \
    'printf '\''gpg'\'' >> "${CNTOOLS_WALLET_DECRYPT_DIRECT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_WALLET_DECRYPT_DIRECT_VECTOR_LOG}"; [[ "${previous}" == --output ]] && output="${argument}"; previous="${argument}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_WALLET_DECRYPT_DIRECT_VECTOR_LOG}"' \
    'IFS= read -r secret || true' \
    '[[ "${secret}" == "${CNTOOLS_WALLET_DECRYPT_EXPECTED_PASSWORD:?}" ]] || exit 98' \
    '[[ "$*" == "--decrypt --batch --yes --no-tty --pinentry-mode loopback --passphrase-fd 0 --output "*" -- "* ]] || exit 96' \
    '[[ "${scenario}" != direct-gpg-failure ]] || { printf partial > "${output}"; exit 41; }' \
    '[[ "${scenario}" != direct-multi-middle-failure || "${input}" != */b.skey.gpg ]] || { printf partial > "${output}"; exit 41; }' \
    'if [[ "${scenario}" == direct-gpg-output-symlink ]]; then /bin/rm -f -- "${output}"; /bin/ln -s -- "${CNTOOLS_WALLET_DECRYPT_DIRECT_OUTSIDE:?}/outside.plain" "${output}"; exit 0; fi' \
    'if [[ "${scenario}" == direct-gpg-empty ]]; then : > "${output}"; exit 0; fi' \
    'printf '\''decrypted fixture\n'\'' > "${output}"' \
    'if [[ "${scenario}" == direct-gpg-output-hardlink ]]; then /bin/ln -- "${output}" "${CNTOOLS_WALLET_DECRYPT_DIRECT_OUTSIDE:?}/escaped.plain"; fi' \
    'if [[ "${scenario}" == direct-inventory-race ]]; then printf '\''race\n'\'' > "${input%/*}/injected.race"; fi' \
    > "${DIRECT_FAKE_BIN}/gpg"
  chmod 0755 "${DIRECT_FAKE_BIN}/gpg"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_DECRYPT_DIRECT_SCENARIO:?}" target="${*: -1}" mode="${1:-}" marker="${CNTOOLS_WALLET_DECRYPT_DIRECT_FAULT:?}.chmod"' \
    'if [[ "${scenario}" == direct-chmod-failure && "${mode}" =~ ^0?600$ && "${target}" == */public.vkey && ! -e "${marker}" ]]; then : > "${marker}"; exit 42; fi' \
    'if [[ "${scenario}" == direct-chmod-success-error && "${mode}" =~ ^0?600$ && "${target}" == */public.vkey && ! -e "${marker}" ]]; then : > "${marker}"; "${CNTOOLS_WALLET_DECRYPT_REAL_CHMOD:?}" "$@"; exit 42; fi' \
    'exec "${CNTOOLS_WALLET_DECRYPT_REAL_CHMOD:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/chmod"
  chmod 0755 "${DIRECT_FAKE_BIN}/chmod"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_DECRYPT_DIRECT_SCENARIO:?}" marker="${CNTOOLS_WALLET_DECRYPT_DIRECT_FAULT:?}.ln"' \
    'arguments=("$@")' \
    'count=${#arguments[@]}' \
    '(( count >= 2 )) || exit 96' \
    'source_path="${arguments[count-2]}" target_path="${arguments[count-1]}"' \
    'if [[ ! -e "${marker}" ]]; then' \
    '  case "${scenario}:${target_path}" in' \
    '    direct-plaintext-link-success-error:*/alpha/payment.skey|direct-backup-link-success-error:*/.alpha.cntools-decrypt.lock/cipher.0.backup)' \
    '      "${CNTOOLS_WALLET_DECRYPT_REAL_LN:?}" "$@" || exit $?' \
    '      : > "${marker}"' \
    '      exit 43' \
    '      ;;' \
    '  esac' \
    'fi' \
    'exec "${CNTOOLS_WALLET_DECRYPT_REAL_LN:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/ln"
  chmod 0755 "${DIRECT_FAKE_BIN}/ln"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_DECRYPT_DIRECT_SCENARIO:?}" target="${*: -1}"' \
    'marker="${CNTOOLS_WALLET_DECRYPT_DIRECT_FAULT:?}.rm"' \
    'if [[ "${target}" == */alpha/payment.skey.gpg && ! -e "${marker}" ]]; then' \
    '  case "${scenario}" in' \
    '    direct-rm-success-error) : > "${marker}"; "${CNTOOLS_WALLET_DECRYPT_REAL_RM:?}" "$@"; exit 43 ;;' \
    '    direct-signal-cipher-remove) : > "${marker}"; "${CNTOOLS_WALLET_DECRYPT_REAL_RM:?}" "$@"; kill -TERM "${PPID}"; exit 45 ;;' \
    '  esac' \
    'fi' \
    'if [[ "${scenario}" == direct-postcommit-cleanup-warning && "${target}" == */cipher.0.backup ]]; then exit 43; fi' \
    'exec "${CNTOOLS_WALLET_DECRYPT_REAL_RM:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/rm"
  chmod 0755 "${DIRECT_FAKE_BIN}/rm"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_DECRYPT_DIRECT_SCENARIO:?}" target="${*: -1}"' \
    'if [[ "${scenario}" == direct-postcommit-cleanup-warning && "${target}" == */.alpha.cntools-decrypt.lock ]]; then exit 44; fi' \
    'exec "${CNTOOLS_WALLET_DECRYPT_REAL_RMDIR:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/rmdir"
  chmod 0755 "${DIRECT_FAKE_BIN}/rmdir"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'target="${*: -1}" state="${CNTOOLS_WALLET_DECRYPT_DIRECT_IMMUTABLE:?}"' \
    'if /usr/bin/grep -Fqx -- "${target}" "${state}" 2>/dev/null; then flags=----i---------; else flags=--------------; fi' \
    'printf '\''%s %s\n'\'' "${flags}" "${target}"' \
    > "${DIRECT_FAKE_BIN}/lsattr"
  chmod 0755 "${DIRECT_FAKE_BIN}/lsattr"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_DECRYPT_DIRECT_SCENARIO:?}" operation="${1:-}" target="${*: -1}" state="${CNTOOLS_WALLET_DECRYPT_DIRECT_IMMUTABLE:?}" temporary="${state}.new"' \
    '[[ "${scenario}:${operation}" != direct-chattr-failure:-i ]] || exit 45' \
    'case "${operation}" in' \
    '  -i) /usr/bin/awk -v target="${target}" '\''$0 != target { print }'\'' "${state}" > "${temporary}"; /bin/mv -f -- "${temporary}" "${state}"; [[ "${scenario}" != direct-chattr-success-error ]] || exit 45 ;;' \
    '  +i) /usr/bin/grep -Fqx -- "${target}" "${state}" 2>/dev/null || printf '\''%s\n'\'' "${target}" >> "${state}" ;;' \
    '  *) exit 96 ;;' \
    'esac' \
    > "${DIRECT_FAKE_BIN}/chattr"
  chmod 0755 "${DIRECT_FAKE_BIN}/chattr"

  printf '%s\n' '#!/usr/bin/env bash' 'exec "$@"' > "${DIRECT_FAKE_BIN}/sudo"
  chmod 0755 "${DIRECT_FAKE_BIN}/sudo"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_WALLET_DECRYPT_DIRECT_SCENARIO:?}" target="${*: -1}"' \
    '"${CNTOOLS_WALLET_DECRYPT_REAL_MKDIR:?}" "$@"' \
    'status=$?' \
    'if [[ "${status}" == 0 && "${scenario}" == direct-signal-lock-mkdir && "${target}" == */.alpha.cntools-decrypt.lock ]]; then kill -TERM "${PPID}"; fi' \
    'exit "${status}"' \
    > "${DIRECT_FAKE_BIN}/mkdir"
  chmod 0755 "${DIRECT_FAKE_BIN}/mkdir"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''network\n'\'' >> "${CNTOOLS_WALLET_DECRYPT_DIRECT_NETWORK:?}"' \
      'exit 97' > "${DIRECT_FAKE_BIN}/${command_name}"
    chmod 0755 "${DIRECT_FAKE_BIN}/${command_name}"
  done
}

prepare_direct_scenario() {
  local scenario="$1" runtime="$2" wallet_root="$3" wallet=""

  wallet="${wallet_root}/alpha"

  chmod 0755 "${wallet_root}"
  [[ "${scenario}" == direct-empty ]] && return 0
  if [[ "${scenario}" == direct-wallet-symlink ]]; then
    mkdir -p -- "${runtime}/outside-wallet"
    chmod 0755 "${runtime}/outside-wallet"
    fixture_file "${runtime}/outside-wallet/payment.skey.gpg" cipher 0400
    ln -s -- "${runtime}/outside-wallet" "${wallet}"
    return 0
  fi
  mkdir -p -- "${wallet}"
  chmod 0755 "${wallet}"
  fixture_file "${wallet}/payment.skey.gpg" cipher 0400
  fixture_file "${wallet}/public.vkey" public 0400
  case "${scenario}" in
    direct-multi-success|direct-multi-middle-failure)
      rm -f -- "${wallet}/payment.skey.gpg"
      fixture_file "${wallet}/a.skey.gpg" cipher-a 0400
      fixture_file "${wallet}/b.skey.gpg" cipher-b 0400
      fixture_file "${wallet}/c.skey.gpg" cipher-c 0400
      ;;
    direct-unlock-only) rm -f -- "${wallet}/payment.skey.gpg" ;;
    direct-plaintext-conflict) fixture_file "${wallet}/payment.skey" existing 0600 ;;
    direct-file-symlink)
      rm -f -- "${wallet}/public.vkey"
      fixture_file "${runtime}/outside.vkey" outside 0400
      ln -s -- "${runtime}/outside.vkey" "${wallet}/public.vkey"
      ;;
    direct-hardlink)
      ln -- "${wallet}/public.vkey" "${runtime}/outside.link"
      ;;
    direct-root-mode) chmod 0777 "${wallet_root}" ;;
    direct-file-mode) chmod 0666 "${wallet}/public.vkey" ;;
    direct-lock-contention)
      mkdir -- "${wallet_root}/.alpha.cntools-decrypt.lock"
      chmod 0700 "${wallet_root}/.alpha.cntools-decrypt.lock"
      ;;
    direct-gpg-output-symlink)
      fixture_file "${runtime}/outside/outside.plain" outside-secret 0600
      ;;
  esac
}

direct_expected_status() {
  case "$1" in
    direct-plaintext-conflict|direct-file-symlink|direct-hardlink|\
      direct-wallet-symlink|direct-invalid-name|direct-root-mode|\
    direct-file-mode|direct-inventory-race|direct-selector-empty|\
      direct-gpg-output-symlink|direct-gpg-output-hardlink|\
      direct-gpg-empty|direct-context-mismatch|direct-missing-helper|\
      direct-gpg-shadow|direct-root-escape|direct-signal-lock-mkdir|\
      direct-signal-cipher-remove)
      printf '70\n'
      ;;
    *) printf '0\n' ;;
  esac
}

direct_expected_waits() {
  case "$1" in
    direct-selection-cancel|direct-plaintext-conflict|direct-file-symlink|\
      direct-hardlink|direct-wallet-symlink|direct-invalid-name|\
      direct-root-mode|direct-file-mode|direct-inventory-race|\
      direct-selector-empty|direct-gpg-output-symlink|\
      direct-gpg-output-hardlink|direct-gpg-empty|\
      direct-context-mismatch|direct-missing-helper|direct-gpg-shadow|direct-root-escape|\
      direct-signal-lock-mkdir|direct-signal-cipher-remove)
      printf '0\n'
      ;;
    *) printf '1\n' ;;
  esac
}

run_direct_case() {
  local scenario="$1" mode="$2" chattr_enabled="${3:-false}"
  local case_root="${TEST_ROOT}/direct-cases/${scenario}" runtime="" wallet_root=""
  local capture="" private="" context="" result="" stdout="" stderr=""
  local events="" vectors="" network="" immutable="" before="" after=""
  local expected_status="" expected_waits="" wait_count=0 status=0
  runtime="${case_root}/runtime"
  wallet_root="${runtime}/wallet"
  if [[ "${scenario}" == direct-root-escape ]]; then
    wallet_root="${runtime}/wallet\\033[31mOWNED"
  fi
  capture="${case_root}/capture"
  private="${runtime}/tmp/private"
  context="${private}/context.json"
  result="${private}/result.json"
  stdout="${capture}/stdout"
  stderr="${capture}/stderr"
  events="${capture}/events"
  vectors="${capture}/vectors"
  network="${capture}/network"
  immutable="${capture}/immutable"
  before="${capture}/before.tree"
  after="${capture}/after.tree"
  mkdir -p -- "${runtime}/tmp" "${runtime}/home" "${runtime}/pool" \
    "${runtime}/asset" "${runtime}/outside" "${wallet_root}" "${capture}"
  prepare_direct_scenario "${scenario}" "${runtime}" "${wallet_root}"
  tree_snapshot "${runtime}" "${before}" || fail "${scenario} direct pre-snapshot failed"
  : > "${events}"; : > "${vectors}"; : > "${network}"; : > "${immutable}"
  if [[ "${chattr_enabled}" == true ]]; then
    printf '%s\n' "${wallet_root}/alpha/payment.skey.gpg" \
      "${wallet_root}/alpha/public.vkey" > "${immutable}"
  fi
  expected_status="$(direct_expected_status "${scenario}")"
  expected_waits="$(direct_expected_waits "${scenario}")"

  if (
    set +e; set +u; set +o pipefail; umask 022
    export LC_ALL=C TZ=UTC
    export CNTOOLS_WALLET_DECRYPT_DIRECT_SCENARIO="${scenario}"
    export CNTOOLS_WALLET_DECRYPT_DIRECT_VECTOR_LOG="${vectors}"
    export CNTOOLS_WALLET_DECRYPT_DIRECT_NETWORK="${network}"
    export CNTOOLS_WALLET_DECRYPT_DIRECT_FAULT="${capture}/fault"
    export CNTOOLS_WALLET_DECRYPT_DIRECT_IMMUTABLE="${immutable}"
    export CNTOOLS_WALLET_DECRYPT_EXPECTED_PASSWORD="${FIXTURE_PASSWORD}"
    export CNTOOLS_WALLET_DECRYPT_REAL_CHMOD="${REAL_CHMOD}"
    export CNTOOLS_WALLET_DECRYPT_REAL_RM="${REAL_RM}"
    export CNTOOLS_WALLET_DECRYPT_REAL_RMDIR="${REAL_RMDIR}"
    export CNTOOLS_WALLET_DECRYPT_REAL_MKDIR="${REAL_MKDIR}"
    export CNTOOLS_WALLET_DECRYPT_REAL_LN="${REAL_LN}"
    export CNTOOLS_WALLET_DECRYPT_DIRECT_OUTSIDE="${runtime}/outside"
    PATH="${DIRECT_FAKE_BIN}:${BASE_PATH}"; export PATH
    HOME="${runtime}/home"; NODE_HOME="${runtime}/home"; TMP_DIR="${runtime}/tmp"
    WALLET_FOLDER="${wallet_root}"; POOL_FOLDER="${runtime}/pool"; ASSET_FOLDER="${runtime}/asset"
    ENABLE_CHATTR="${chattr_enabled}"; CNTOOLS_MODE="${mode}"
    FG_RED="" FG_GREEN="" FG_YELLOW="" FG_LBLUE="" NC=""
    EVENT_LOG="${events}"; DIRECT_ACTIVE=Y; SCENARIO="${scenario}"
    unset password wallet_name wallet_decrypt_secret
    mkdir -p -- "${private}"; chmod 0700 "${private}"
    write_direct_context "${context}" "${mode}" "${runtime}/home"
    case "${scenario}" in
      direct-selection-fail) SCENARIO=select-fail ;;
      direct-selection-cancel) SCENARIO=select-cancel ;;
      direct-selector-empty) SCENARIO=selector-empty ;;
      direct-password-abort) SCENARIO='password-abort' ;;
      direct-invalid-name) SCENARIO=traversal ;;
    esac
    if [[ "${scenario}" == direct-context-mismatch ]]; then CNTOOLS_MODE=LOCAL; fi
    if [[ "${scenario}" == direct-missing-helper ]]; then builtin unset -f selectWallet; fi
    if [[ "${scenario}" == direct-gpg-shadow ]]; then gpg() { :; }; fi
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" "${context}" "${result}"
    direct_status=$?
    [[ ! -e "${result}" && ! -L "${result}" ]] || exit 98
    "${REAL_RM}" -f -- "${context}"; "${REAL_RMDIR}" -- "${private}"
    exit "${direct_status}"
  ) > "${stdout}" 2> "${stderr}"; then status=0; else status=$?; fi
  [[ "${status}" == "${expected_status}" ]] || fail "${scenario} direct status ${status}, expected ${expected_status}"
  wait_count="$(grep -c '^action:waitToProceed$' "${events}" || true)"
  [[ "${wait_count}" == "${expected_waits}" ]] || fail "${scenario} waits ${wait_count}, expected ${expected_waits}"
  ! grep -Fq 'action:secret:present' "${events}" || fail "${scenario} retained password at wait"
  if [[ "${scenario}" != direct-lock-contention && "${scenario}" != direct-postcommit-cleanup-warning ]]; then
    ! grep -Fq 'action:lock:present' "${events}" || fail "${scenario} waited while locked"
  fi
  [[ ! -s "${network}" ]] || fail "${scenario} attempted network access"
  case "${scenario}" in
    direct-multi-success)
      [[ "$(grep -c '^gpg' "${vectors}" || true)" == 3 ]] ||
        fail 'multi-cipher success GPG vector count changed'
      ;;
    direct-multi-middle-failure)
      [[ "$(grep -c '^gpg' "${vectors}" || true)" == 2 ]] ||
        fail 'multi-cipher failure did not stop at the failed input'
      ;;
  esac
  for checked_file in "${stdout}" "${stderr}" "${events}" "${vectors}" "${network}"; do
    ! grep -Fq "${FIXTURE_PASSWORD}" "${checked_file}" || fail "${scenario} exposed password"
  done
  if [[ "${expected_status}" == 70 ]]; then
    grep -Fxq 'CNTools wallet decryption action failed validation.' "${stderr}" || fail "${scenario} status70 diagnostic changed"
  elif [[ "${scenario}" == direct-postcommit-signal ]]; then
    grep -Fxq 'CNTools wallet decryption action committed; interrupted after commit.' \
      "${stderr}" || fail "${scenario} committed signal diagnostic changed"
  else
    [[ ! -s "${stderr}" ]] || fail "${scenario} unexpected stderr"
  fi
  case "${scenario}" in
    direct-success-*|direct-postcommit-cleanup-warning|direct-postcommit-signal)
      grep -Fxq 'Wallet unprotected : alpha' "${stdout}" || fail "${scenario} success heading changed"
      grep -Fxq 'Files unlocked     : 2' "${stdout}" || fail "${scenario} unlock count changed"
      grep -Fxq 'Files decrypted    : 1' "${stdout}" || fail "${scenario} decrypt count changed"
      ;;
    direct-multi-success)
      grep -Fxq 'Wallet unprotected : alpha' "${stdout}" || fail 'multi-cipher success heading changed'
      grep -Fxq 'Files unlocked     : 4' "${stdout}" || fail 'multi-cipher unlock count changed'
      grep -Fxq 'Files decrypted    : 3' "${stdout}" || fail 'multi-cipher decrypt count changed'
      ;;
    direct-unlock-only)
      grep -Fxq 'Wallet unprotected : alpha' "${stdout}" || fail 'unlock-only heading changed'
      grep -Fxq 'Files unlocked     : 1' "${stdout}" || fail 'unlock-only count changed'
      grep -Fxq 'Files decrypted    : 0' "${stdout}" || fail 'unlock-only decrypt count changed'
      ;;
    direct-password-abort)
      grep -Fxq 'ERROR: password input aborted!' "${stdout}" || fail 'password abort diagnostic changed'
      ;;
    direct-gpg-failure|direct-multi-middle-failure)
      grep -Fq 'failed to decrypt wallet files; original encrypted wallet was preserved!' \
        "${stdout}" || fail "${scenario} GPG failure diagnostic changed"
      ;;
    direct-plaintext-link-success-error|direct-backup-link-success-error)
      grep -Fq 'failed to unlock/decrypt wallet files; original encrypted wallet was preserved!' \
        "${stdout}" || fail "${scenario} handled link diagnostic changed"
      ;;
  esac
  ! grep -Fq '../outside-wallet' "${stdout}" "${stderr}" || fail "${scenario} reflected unsafe selector bytes"
  if [[ "${scenario}" == direct-root-escape ]]; then
    ! grep -Fq '\033[31mOWNED' "${stdout}" "${stderr}" ||
      fail 'unsafe wallet root bytes reached a terminal stream'
    ! grep -q $'\033' "${stdout}" "${stderr}" ||
      fail 'unsafe wallet root produced a terminal escape'
  fi
  tree_snapshot "${runtime}" "${after}" || fail "${scenario} direct post-snapshot failed"
  case "${scenario}" in
    direct-success-*|direct-multi-success|direct-unlock-only|direct-postcommit-cleanup-warning|\
      direct-postcommit-signal)
      assert_file "${wallet_root}/alpha/public.vkey" 600 public
      if [[ "${scenario}" == direct-multi-success ]]; then
        for entry in a b c; do
          [[ ! -e "${wallet_root}/alpha/${entry}.skey.gpg" ]] ||
            fail "multi-cipher success retained ${entry} ciphertext"
          assert_file "${wallet_root}/alpha/${entry}.skey" 600 'decrypted fixture'
        done
      elif [[ "${scenario}" != direct-unlock-only ]]; then
        [[ ! -e "${wallet_root}/alpha/payment.skey.gpg" ]] || fail "${scenario} ciphertext remained"
        assert_file "${wallet_root}/alpha/payment.skey" 600 'decrypted fixture'
      fi
      ;;
    direct-gpg-output-hardlink)
      [[ -f "${runtime}/outside/escaped.plain" &&
         "$(wc -c < "${runtime}/outside/escaped.plain" | tr -d ' ')" == 0 ]] ||
        fail 'escaped hardlink plaintext was not scrubbed'
      sed '/outside\/escaped\.plain/d' "${after}" > "${after}.filtered"
      assert_files_equal "${after}.filtered" "${before}" "${scenario} scrubbed rollback"
      ;;
    *)
      if [[ "${scenario}" == direct-inventory-race ]]; then
        sed '/wallet\/alpha\/injected\.race/d' "${after}" > "${after}.filtered"
        assert_files_equal "${after}.filtered" "${before}" "${scenario} rollback"
      else
        assert_files_equal "${after}" "${before}" "${scenario} hardened rollback"
      fi
      ;;
  esac
  if [[ "${scenario}" == direct-postcommit-cleanup-warning ]]; then
    grep -Fq 'wallet decryption committed, but private cleanup was incomplete' "${stdout}" || fail 'postcommit warning changed'
  else
    [[ ! -e "${wallet_root}/.alpha.cntools-decrypt.lock" || "${scenario}" == direct-lock-contention ]] || fail "${scenario} retained lock"
  fi
  case "${scenario}" in
    direct-success-chattr)
      [[ ! -s "${immutable}" ]] || fail 'successful immutable unlock retained immutable state'
      ;;
    direct-chattr-failure|direct-chattr-success-error)
      [[ "$(wc -l < "${immutable}" | tr -d ' ')" == 2 ]] ||
        fail "${scenario} immutable rollback count changed"
      grep -Fqx -- "${wallet_root}/alpha/payment.skey.gpg" "${immutable}" ||
        fail "${scenario} did not restore ciphertext immutable state"
      grep -Fqx -- "${wallet_root}/alpha/public.vkey" "${immutable}" ||
        fail "${scenario} did not restore public-key immutable state"
      ;;
  esac
}

write_direct_fake_commands
run_direct_case direct-empty OFFLINE
run_direct_case direct-selection-fail LIGHT
run_direct_case direct-selection-cancel LOCAL
run_direct_case direct-selector-empty LOCAL
run_direct_case direct-password-abort LIGHT
run_direct_case direct-success-local LOCAL
run_direct_case direct-success-light LIGHT
run_direct_case direct-success-offline OFFLINE
run_direct_case direct-success-chattr OFFLINE true
run_direct_case direct-multi-success OFFLINE
run_direct_case direct-multi-middle-failure OFFLINE
run_direct_case direct-unlock-only OFFLINE
run_direct_case direct-gpg-failure OFFLINE
run_direct_case direct-gpg-empty OFFLINE
run_direct_case direct-gpg-output-symlink OFFLINE
run_direct_case direct-gpg-output-hardlink OFFLINE
run_direct_case direct-plaintext-conflict OFFLINE
run_direct_case direct-file-symlink OFFLINE
run_direct_case direct-hardlink OFFLINE
run_direct_case direct-wallet-symlink OFFLINE
run_direct_case direct-invalid-name OFFLINE
run_direct_case direct-root-mode OFFLINE
run_direct_case direct-file-mode OFFLINE
run_direct_case direct-lock-contention OFFLINE
run_direct_case direct-chmod-failure OFFLINE
run_direct_case direct-chmod-success-error OFFLINE
run_direct_case direct-chattr-failure OFFLINE true
run_direct_case direct-chattr-success-error OFFLINE true
run_direct_case direct-inventory-race OFFLINE
run_direct_case direct-rm-success-error OFFLINE
run_direct_case direct-plaintext-link-success-error OFFLINE
run_direct_case direct-backup-link-success-error OFFLINE
run_direct_case direct-signal-lock-mkdir OFFLINE
run_direct_case direct-signal-cipher-remove OFFLINE
run_direct_case direct-context-mismatch OFFLINE
run_direct_case direct-missing-helper OFFLINE
run_direct_case direct-gpg-shadow OFFLINE
run_direct_case direct-root-escape OFFLINE
run_direct_case direct-postcommit-cleanup-warning OFFLINE
run_direct_case direct-postcommit-signal OFFLINE

run_direct_arity_case() {
  local name="$1"
  local status=0 stdout="${TEST_ROOT}/${name}.stdout"
  local stderr="${TEST_ROOT}/${name}.stderr"
  shift
  if (
    # shellcheck source=/dev/null
    builtin source "${ACTION_SOURCE}"
    cntools_action_main "$@"
  ) > "${stdout}" 2> "${stderr}"; then status=0; else status=$?; fi
  [[ "${status}" == 64 ]] || fail "${name} status ${status}, expected 64"
  [[ ! -s "${stdout}" && ! -s "${stderr}" ]] || fail "${name} arity emitted streams"
}

run_direct_arity_case direct-arity-zero
run_direct_arity_case direct-arity-one /private/context.json

wallet_decrypt_arm="${TEST_ROOT}/wallet-decrypt-arm"
awk '/^[[:space:]]+decrypt\)/ { capture=1 } capture { print } capture && /^[[:space:]]+;;/ { exit }' \
  "${CNTOOLS_SCRIPT}" > "${wallet_decrypt_arm}"
[[ "$(grep -Fc 'cntools_compatibility_dispatch_action wallet.decrypt' \
  "${wallet_decrypt_arm}")" == 1 ]] || fail 'wallet.decrypt generic call count changed'
grep -Fq '0|21) continue ;;' "${wallet_decrypt_arm}" || fail 'wallet.decrypt continue mapping changed'
grep -Fq '20) break ;;' "${wallet_decrypt_arm}" || fail 'wallet.decrypt parent mapping changed'
grep -Fq '22) myExit 0 "CNTools closed!" ;;' "${wallet_decrypt_arm}" || fail 'wallet.decrypt exit mapping changed'
grep -Fq '*) waitToProceed; continue ;;' "${wallet_decrypt_arm}" || fail 'wallet.decrypt failure mapping changed'
if grep -Eq 'selectWallet|unlockFile|decryptFile|find .*\.gpg|unset password' \
    "${wallet_decrypt_arm}"; then
  fail 'wallet.decrypt inline implementation remains after binding'
fi
grep -Fq 'cntools_action_main() {' "${ACTION_SOURCE}" || fail 'wallet.decrypt modular entrypoint is missing'
grep -Fq '_cntools_action_wallet_decrypt_rollback() {' "${ACTION_SOURCE}" || fail 'wallet.decrypt rollback boundary is missing'
grep -Fq '.cntools-decrypt.lock' "${ACTION_SOURCE}" || fail 'wallet.decrypt operation lock is missing'
grep -Fq 'wallet decryption committed, but private cleanup was incomplete' "${ACTION_SOURCE}" || fail 'wallet.decrypt postcommit warning is missing'
grep -Fq 'CNTools actions are launched by the dispatcher, not directly.' "${ACTION_SOURCE}" || fail 'wallet.decrypt direct guard changed'

printf 'CNTools wallet-decrypt characterization passed (6 public + 42 direct cases; 24 legacy records retained)\n'
