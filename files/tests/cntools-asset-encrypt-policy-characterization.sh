#!/usr/bin/env bash
# Freeze the original public contract and the hardened modular
# advanced.asset.encrypt-policy transaction, including failure recovery.
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools asset-encrypt-policy characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
LEGACY_SELECTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f/020-terminal-selection-security.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/advanced/asset/encrypt-policy/action.sh"
ACTION_DIRECTORY="${ACTION_SOURCE%/action.sh}"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-asset-encrypt.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
DIRECT_FAKE_BIN="${TEST_ROOT}/direct-fake-bin"
BASE_PATH="${PATH}"
FIXTURE_PASSWORD='characterization-only-password'

cleanup_test() {
  if [[ "${CNTOOLS_ASSET_ENCRYPT_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools asset-encrypt-policy test root preserved: %s\n' \
      "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools asset-encrypt-policy characterization failed: %s\n' \
    "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk cmp find grep readlink sed sort stat wc; do
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
    'set -u' \
    'scenario="${CNTOOLS_ASSET_ENCRYPT_SCENARIO:?}"' \
    'vector_log="${CNTOOLS_ASSET_ENCRYPT_VECTOR_LOG:?}"' \
    'output="" input="" previous="" supplied=""' \
    'printf '\''gpg'\'' >> "${vector_log}"' \
    'for argument in "$@"; do' \
    '  printf '\''\t%q'\'' "${argument}" >> "${vector_log}"' \
    '  [[ "${previous}" == --output ]] && output="${argument}"' \
    '  input="${argument}"' \
    '  previous="${argument}"' \
    'done' \
    'printf '\''\n'\'' >> "${vector_log}"' \
    'IFS= read -r supplied || true' \
    '[[ "${supplied}" == "${CNTOOLS_ASSET_ENCRYPT_EXPECTED_PASSWORD:?}" ]] || exit 98' \
    '[[ "$*" == "--symmetric --yes --batch --no-tty --pinentry-mode loopback --cipher-algo AES256 --passphrase-fd 0 --output "*" -- "* ]] || exit 96' \
    '[[ -n "${output}" && -n "${input}" ]] || exit 96' \
    'if [[ "${scenario}" == gpg-failure ]]; then' \
    '  printf '\''partial encrypted fixture\n'\'' > "${output}"' \
    '  exit 17' \
    'fi' \
    'printf '\''encrypted fixture\n'\'' > "${output}"' \
    > "${FAKE_BIN}/gpg"
  chmod 0755 "${FAKE_BIN}/gpg"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''lsattr'\'' >> "${CNTOOLS_ASSET_ENCRYPT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_ENCRYPT_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_ASSET_ENCRYPT_VECTOR_LOG:?}"' \
    'if [[ "${CNTOOLS_ASSET_ENCRYPT_SCENARIO:?}" == success-immutable ]] || /usr/bin/grep -Fqx -- "${*: -1}" "${CNTOOLS_ASSET_ENCRYPT_IMMUTABLE_STATE:?}" 2>/dev/null; then' \
    '  printf '\''%s %s\n'\'' '\''----i---------'\'' "${*: -1}"' \
    'else' \
    '  printf '\''%s %s\n'\'' '\''--------------'\'' "${*: -1}"' \
    'fi' \
    > "${FAKE_BIN}/lsattr"
  chmod 0755 "${FAKE_BIN}/lsattr"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''sudo'\'' >> "${CNTOOLS_ASSET_ENCRYPT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_ENCRYPT_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_ASSET_ENCRYPT_VECTOR_LOG:?}"' \
    '[[ "${1##*/}" == chattr ]] || exit 96' \
    'exec "$@"' \
    > "${FAKE_BIN}/sudo"
  chmod 0755 "${FAKE_BIN}/sudo"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''chattr'\'' >> "${CNTOOLS_ASSET_ENCRYPT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_ENCRYPT_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_ASSET_ENCRYPT_VECTOR_LOG:?}"' \
    'scenario="${CNTOOLS_ASSET_ENCRYPT_SCENARIO:?}" operation="${1:-}" target="${*: -1}"' \
    'state="${CNTOOLS_ASSET_ENCRYPT_IMMUTABLE_STATE:?}" temporary="${state}.new"' \
    'if [[ "${scenario}" == chattr-failure && "${operation}" == +i ]]; then exit 17; fi' \
    'case "${operation}" in' \
    '  +i) /usr/bin/grep -Fqx -- "${target}" "${state}" 2>/dev/null || printf '\''%s\n'\'' "${target}" >> "${state}" ;;' \
    '  -i) /usr/bin/awk -v target="${target}" '\''$0 != target { print }'\'' "${state}" > "${temporary}"; /bin/mv -- "${temporary}" "${state}" ;;' \
    '  *) exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/chattr"
  chmod 0755 "${FAKE_BIN}/chattr"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_ASSET_ENCRYPT_NETWORK_LOG:?}"' \
      'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_ENCRYPT_NETWORK_LOG:?}"; done' \
      'printf '\''\n'\'' >> "${CNTOOLS_ASSET_ENCRYPT_NETWORK_LOG:?}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

# Source the controller and the legacy encryption helper used by the arm.
# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
# shellcheck source=/dev/null
. "${LEGACY_SELECTION_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/registry.sh
. "${REGISTRY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/context.sh
. "${CONTEXT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/result.sh
. "${RESULT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/dispatcher.sh
. "${DISPATCHER_SOURCE}"

cntools_compatibility_dispatch_action() {
  local action_id="${1:-}" private_root="" context_file=""
  local result_file="" action_status=0 tmp_mode=""

  [[ "${action_id}" == advanced.asset.encrypt-policy && $# == 1 ]] ||
    return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  tmp_mode="$(file_mode "${TMP_DIR}")" || return 70
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/asset-encrypt-test-dispatch.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  chmod 0700 "${TMP_DIR}" "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  write_direct_context "${context_file}" "${CNTOOLS_MODE}" "${NODE_HOME}" ||
    return 70
  if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"; then
    action_status=0
  else
    action_status=$?
  fi
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || action_status=70
  rm -f -- "${result_file}" "${context_file}" || action_status=70
  rmdir -- "${private_root}" || action_status=70
  chmod "${tmp_mode}" "${TMP_DIR}" || action_status=70
  if [[ "${CAPTURE_ACTIVE:-N}" == Y &&
        ! -e "${CAPTURE_DONE_FILE:-/nonexistent}" ]]; then
    printf '__CNTOOLS_ASSET_ENCRYPT_END__\n'
    : > "${CAPTURE_DONE_FILE:?}"
  fi
  CAPTURE_ACTIVE=N
  return "${action_status}"
}

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
    printf '__CNTOOLS_ASSET_ENCRYPT_END__\n'
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
    : > "${CAPTURE_DONE_FILE:?}"
  fi
  printf 'terminal:clear\n' >> "${EVENT_LOG:?}"
}

tput() {
  if [[ "${DIRECT_ACTIVE:-N}" == Y ]]; then
    printf 'terminal:%s\n' "$*" >> "${EVENT_LOG:?}"
  fi
  return 0
}

getEpoch() { printf '5\n'; }
timeUntilNextEpoch() { printf '0\n'; }
timeLeft() { printf 'delta-%s' "${1:-}"; }
slotInterval() { printf '20\n'; }
getSlotTipRef() { printf '1000\n'; }

getNodeMetrics() {
  printf 'runtime:getNodeMetrics\n' >> "${EVENT_LOG:?}"
  slotnum=1000
}

getPriceInfo() {
  printf 'runtime:getPriceInfo\n' >> "${EVENT_LOG:?}"
  price_now=""
}

updateProtocolParams() {
  printf 'runtime:updateProtocolParams\n' >> "${EVENT_LOG:?}"
}

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}" menu=""
  local option="" index=0

  case "${1:-}" in
    '[w] Wallet') menu=main ;;
    '[m] Metadata') menu=advanced ;;
    '[c] Create Policy') menu=asset ;;
    *) fail "unexpected public menu: ${1:-<empty>}" ;;
  esac
  [[ -n "${choice}" ]] || fail "${menu} menu exhausted choices"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == asset:e ]]; then
        CAPTURE_ACTIVE=Y
        printf '__CNTOOLS_ASSET_ENCRYPT_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was unavailable in ${menu} menu"
}

selectPolicy() {
  [[ "${1:-}" == encrypted && $# == 1 ]] ||
    fail 'encrypt-policy selection contract changed'
  printf 'action:selectPolicy:encrypted\n' >> "${EVENT_LOG:?}"
  case "${CNTOOLS_ASSET_ENCRYPT_SCENARIO:?}" in
    selection-fail|direct-selection-fail) return 1 ;;
    selection-cancel|direct-selection-cancel)
      END_ON_CLEAR=Y
      return 2
      ;;
    direct-invalid-name) policy_name='../escape' ;;
    direct-command-name)
      policy_name='$(touch${IFS}${CNTOOLS_ASSET_ENCRYPT_COMMAND_SENTINEL})'
      ;;
    *) policy_name=alpha ;;
  esac
}

getPasswordCust() {
  [[ "${1:-}" == confirm && $# == 1 ]] ||
    fail 'encrypt-policy password confirmation contract changed'
  printf 'action:password:confirm\n' >> "${EVENT_LOG:?}"
  password="${FIXTURE_PASSWORD}"
  [[ "${CNTOOLS_ASSET_ENCRYPT_SCENARIO:?}" != password-abort &&
     "${CNTOOLS_ASSET_ENCRYPT_SCENARIO:?}" != direct-password-abort ]]
}

safeDel() {
  local target="${1:-}"

  printf 'action:safeDel:%s\n' "${target}" >> "${EVENT_LOG:?}"
  rm -f -- "${target}"
}

waitToProceed() {
  if [[ "${DIRECT_ACTIVE:-N}" == Y ]]; then
    if [[ "${encrypt_policy_lock_acquired:-N}" == Y ]]; then
      printf 'action:lock:present\n' >> "${EVENT_LOG:?}"
    else
      printf 'action:lock:released\n' >> "${EVENT_LOG:?}"
    fi
  fi
  printf 'action:secret:%s\n' \
    "$([[ -n "${password:-}" || -n "${encrypt_policy_secret:-}" ]] &&
      printf present || printf unset)" \
    >> "${EVENT_LOG:?}"
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${CNTOOLS_ASSET_ENCRYPT_SCENARIO:-}" == \
        direct-postcommit-signal ]]; then
    kill -TERM "${BASHPID}"
  fi
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    printf '__CNTOOLS_ASSET_ENCRYPT_END__\n'
    CAPTURE_ACTIVE=N
    : > "${CAPTURE_DONE_FILE:?}"
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
    empty|already-encrypted|success-no-chattr|gpg-failure) printf 'LOCAL\n' ;;
    selection-fail|password-abort|success-chattr|chattr-failure) printf 'LIGHT\n' ;;
    *) printf 'OFFLINE\n' ;;
  esac
}

scenario_chattr() {
  case "$1" in
    success-chattr|success-immutable|chattr-failure) printf 'true\n' ;;
    *) printf 'false\n' ;;
  esac
}

prepare_scenario() {
  local scenario="$1" runtime_root="$2" asset_root="$3"
  local policy_root="${asset_root}/alpha"

  [[ "${scenario}" == empty ]] && return 0
  mkdir -p -- "${policy_root}"
  case "${scenario}" in
    already-encrypted)
      printf 'existing encrypted key\n' > "${policy_root}/policy.skey.gpg"
      ;;
    missing-skey)
      printf 'verification key\n' > "${policy_root}/policy.vkey"
      ;;
    symlink-skey)
      printf 'outside signing secret\n' > "${runtime_root}/outside.skey"
      ln -s -- "${runtime_root}/outside.skey" "${policy_root}/policy.skey"
      ;;
    *) printf 'signing secret fixture\n' > "${policy_root}/policy.skey" ;;
  esac
}

normalize_file() {
  local source="$1" target="$2" runtime_root="$3"

  sed \
    -e "s#${runtime_root}#<runtime>#g" \
    -e "s#${TEST_ROOT}#<test>#g" \
    -e 's/\.cntools-policy-encrypt\.[A-Za-z0-9]*/.cntools-policy-encrypt.<temp>/g' \
    -e 's/\.cntools-policy-source\.[A-Za-z0-9]*/.cntools-policy-source.<temp>/g' \
    "${source}" > "${target}"
}

extract_action_output() {
  local source="$1" target="$2"

  [[ "$(grep -c '^__CNTOOLS_ASSET_ENCRYPT_BEGIN__$' "${source}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_ASSET_ENCRYPT_END__$' "${source}" || true)" == 1 ]] ||
    fail 'encrypt-policy output markers changed'
  awk '
    $0 == "__CNTOOLS_ASSET_ENCRYPT_BEGIN__" { capture=1; next }
    $0 == "__CNTOOLS_ASSET_ENCRYPT_END__" { exit }
    capture { print }
  ' "${source}" > "${target}"
}

write_header() {
  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> ADVANCED >> ASSET >> ENCRYPT / LOCK POLICY' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ''
}

write_expected_stdout() {
  local scenario="$1" target="$2" locked=1 encrypted=1

  write_header > "${target}"
  case "${scenario}" in
    empty)
      printf '%s\n' 'No policies available!' >> "${target}"
      return
      ;;
  esac
  printf '%s\n' 'Select policy to encrypt' >> "${target}"
  case "${scenario}" in
    selection-fail|selection-cancel) return ;;
    already-encrypted)
      printf '%s\n' \
        '' \
        'NOTE: found GPG encrypted files in folder, please decrypt/unlock policy files before encrypting' \
        >> "${target}"
      return
      ;;
    password-abort)
      printf '%s\n' \
        '' \
        'Encrypting policy signing key with GPG' \
        '' '' '' \
        'ERROR: password input aborted!' \
        >> "${target}"
      return
      ;;
    missing-skey)
      printf '%s\n' \
        '' \
        'ERROR: policy signing key is missing or unsafe!' \
        >> "${target}"
      return
      ;;
    success-immutable|symlink-skey)
      printf '%s\n' \
        '' \
        'ERROR: selected policy failed security validation!' \
        >> "${target}"
      return
      ;;
  esac
  printf '%s\n' '' 'Encrypting policy signing key with GPG' >> "${target}"
  case "${scenario}" in
    gpg-failure)
      printf '%s\n' \
        '' \
        'ERROR: failed to encrypt policy signing key!' \
        >> "${target}"
      return
      ;;
    chattr-failure)
      printf '%s\n' \
        '' \
        'ERROR: failed to lock policy files; original policy was preserved!' \
        >> "${target}"
      return
      ;;
    *)
      printf '%s\n' \
        '<runtime>/asset/alpha/policy.skey successfully encrypted' \
        >> "${target}"
      ;;
  esac
  printf '%s\n' \
    '' \
    "Write protecting all policy files with 400 permission and if enabled 'chattr +i'" \
    >> "${target}"
  case "${scenario}" in
    *) printf '%s\n' '<runtime>/asset/alpha/policy.skey.gpg' >> "${target}" ;;
  esac
  printf '%s\n' \
    '' \
    'Policy encrypted : alpha' \
    "Files locked     : ${locked}" \
    "Files encrypted  : ${encrypted}" \
    '' \
    'INFO: policy files are now protected' \
    "Use 'ADVANCED >> ASSET >> DECRYPT / UNLOCK POLICY' to unlock" \
    >> "${target}"
}

write_runtime_events() {
  local mode="$1" target="$2"

  case "${mode}" in
    LOCAL)
      printf '%s\n' runtime:getNodeMetrics runtime:getPriceInfo \
        runtime:updateProtocolParams >> "${target}"
      ;;
    LIGHT)
      printf '%s\n' runtime:getPriceInfo runtime:updateProtocolParams \
        >> "${target}"
      ;;
  esac
}

write_expected_events() {
  local scenario="$1" mode="$2" target="$3" secret_state=unset

  : > "${target}"
  printf '%s\n' terminal:clear >> "${target}"
  write_runtime_events "${mode}" "${target}"
  printf '%s\n' \
    menu:main:a terminal:clear menu:advanced:a \
    terminal:clear menu:asset:e action:compatibility-dispatch terminal:clear \
    >> "${target}"
  case "${scenario}" in
    empty) ;;
    *) printf '%s\n' action:selectPolicy:encrypted >> "${target}" ;;
  esac
  case "${scenario}" in
    password-abort)
      printf '%s\n' action:password:confirm >> "${target}"
      secret_state='unset'
      ;;
    success-no-chattr|success-chattr|gpg-failure|chattr-failure)
      printf '%s\n' action:password:confirm >> "${target}"
      ;;
  esac
  if [[ "${scenario}" != selection-cancel ]]; then
    printf 'action:secret:%s\n' "${secret_state}" >> "${target}"
    printf '%s\n' action:waitToProceed >> "${target}"
  fi
  printf '%s\n' terminal:clear menu:asset:h terminal:clear >> "${target}"
  write_runtime_events "${mode}" "${target}"
  printf '%s\n' menu:main:q 'exit:0:CNTools closed!' >> "${target}"
}

write_expected_vectors() {
  local scenario="$1" target="$2" key='<runtime>/asset/alpha/policy.skey'
  local encrypted="${key}.gpg"

  : > "${target}"
  case "${scenario}" in
    success-chattr|success-immutable|chattr-failure)
      printf 'lsattr\t-d\t--\t%s\n' "${key}" >> "${target}"
      ;;
  esac
  case "${scenario}" in
    success-no-chattr|success-chattr|gpg-failure|chattr-failure)
      printf 'gpg\t--symmetric\t--yes\t--batch\t--no-tty\t--pinentry-mode\tloopback\t--cipher-algo\tAES256\t--passphrase-fd\t0\t--output\t%s\t--\t%s\n' \
        '<runtime>/asset/alpha/.cntools-policy-encrypt.<temp>' "${key}" \
        >> "${target}"
      ;;
  esac
  case "${scenario}" in
    success-chattr)
      printf 'sudo\t<test>/fake-bin/chattr\t+i\t--\t%s\n' "${encrypted}" >> "${target}"
      printf 'chattr\t+i\t--\t%s\n' "${encrypted}" >> "${target}"
      printf 'lsattr\t-d\t--\t%s\n' "${encrypted}" >> "${target}"
      ;;
    success-immutable)
      ;;
    chattr-failure)
      printf 'sudo\t<test>/fake-bin/chattr\t+i\t--\t%s\n' "${encrypted}" >> "${target}"
      printf 'chattr\t+i\t--\t%s\n' "${encrypted}" >> "${target}"
      printf 'lsattr\t-d\t--\t%s\n' "${encrypted}" >> "${target}"
      printf 'sudo\t<test>/fake-bin/chattr\t-i\t--\t%s\n' "${encrypted}" >> "${target}"
      printf 'chattr\t-i\t--\t%s\n' "${encrypted}" >> "${target}"
      printf 'lsattr\t-d\t--\t%s\n' "${encrypted}" >> "${target}"
      ;;
  esac
}

assert_zero_mutation() {
  local scenario="$1" before="$2" after="$3"

  assert_files_equal "${after}" "${before}" \
    "${scenario} zero persistent mutation"
}

assert_policy_mutation() {
  local scenario="$1" runtime_root="$2" before="$3" after="$4"
  local policy_root="${runtime_root}/asset/alpha"
  local before_filtered="${before}.filtered" after_filtered="${after}.filtered"

  case "${scenario}" in
    missing-skey)
      [[ -f "${policy_root}/policy.vkey" &&
         "$(file_mode "${policy_root}/policy.vkey")" == 400 ]] ||
        fail 'missing-skey locked-file residue changed'
      ;;
    gpg-failure)
      [[ -f "${policy_root}/policy.skey" &&
         "$(file_mode "${policy_root}/policy.skey")" == 400 &&
         -f "${policy_root}/policy.skey.gpg" &&
         "$(file_mode "${policy_root}/policy.skey.gpg")" == 400 &&
         "$(< "${policy_root}/policy.skey.gpg")" == 'partial encrypted fixture' ]] ||
        fail 'GPG partial-failure residue changed'
      ;;
    symlink-skey)
      [[ ! -e "${policy_root}/policy.skey" &&
         ! -L "${policy_root}/policy.skey" &&
         -f "${policy_root}/policy.skey.gpg" &&
         "$(file_mode "${policy_root}/policy.skey.gpg")" == 400 &&
         -f "${runtime_root}/outside.skey" &&
         "$(file_mode "${runtime_root}/outside.skey")" == 400 ]] ||
        fail 'signing-key symlink escape behavior changed'
      ;;
    *)
      [[ ! -e "${policy_root}/policy.skey" &&
         -f "${policy_root}/policy.skey.gpg" &&
         "$(file_mode "${policy_root}/policy.skey.gpg")" == 400 ]] ||
        fail "${scenario} encrypted artifact state changed"
      ;;
  esac
  grep -Ev '^(d|f|l)[[:space:]]+asset/alpha([[:space:]]|/)' \
    "${before}" > "${before_filtered}"
  grep -Ev '^(d|f|l)[[:space:]]+asset/alpha([[:space:]]|/)' \
    "${after}" > "${after_filtered}"
  if [[ "${scenario}" == symlink-skey ]]; then
    grep -Ev '^f[[:space:]]+outside\.skey[[:space:]]' \
      "${before_filtered}" > "${before_filtered}.outside"
    grep -Ev '^f[[:space:]]+outside\.skey[[:space:]]' \
      "${after_filtered}" > "${after_filtered}.outside"
    assert_files_equal "${after_filtered}.outside" "${before_filtered}.outside" \
      'symlink-skey mutation outside the frozen escape allowlist'
  else
    assert_files_equal "${after_filtered}" "${before_filtered}" \
      "${scenario} exact selected-policy mutation allowlist"
  fi
}

run_case() {
  local scenario="$1" mode="" enable_chattr=""
  local case_root="${TEST_ROOT}/cases/${scenario}"
  local runtime_root="${case_root}/runtime"
  local asset_root="${runtime_root}/asset"
  local capture_root="${case_root}/capture"
  local full_stdout="${capture_root}/full.stdout"
  local action_stdout_raw="${capture_root}/action.raw.stdout"
  local action_stdout="${capture_root}/action.stdout"
  local stderr_raw="${capture_root}/raw.stderr"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_raw="${capture_root}/raw.events"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local vector_raw="${capture_root}/raw.vectors"
  local vector_log="${capture_root}/vectors"
  local expected_vectors="${capture_root}/expected.vectors"
  local network_log="${capture_root}/network"
  local immutable_state="${capture_root}/immutable"
  local capture_done_file="${capture_root}/capture.done"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local status=0

  mode="$(scenario_mode "${scenario}")"
  enable_chattr="$(scenario_chattr "${scenario}")"
  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/wallet" \
    "${runtime_root}/pool" "${runtime_root}/home" "${asset_root}" \
    "${capture_root}"
  prepare_scenario "${scenario}" "${runtime_root}" "${asset_root}"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "${scenario} pre-snapshot failed"
  : > "${event_raw}"; : > "${vector_raw}"; : > "${network_log}"
  : > "${immutable_state}"

  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    export CNTOOLS_ASSET_ENCRYPT_SCENARIO="${scenario}"
    export CNTOOLS_ASSET_ENCRYPT_VECTOR_LOG="${vector_raw}"
    export CNTOOLS_ASSET_ENCRYPT_NETWORK_LOG="${network_log}"
    export CNTOOLS_ASSET_ENCRYPT_EXPECTED_PASSWORD="${FIXTURE_PASSWORD}"
    export CNTOOLS_ASSET_ENCRYPT_IMMUTABLE_STATE="${immutable_state}"
    PATH="${FAKE_BIN}:${BASE_PATH}"
    export PATH
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    ASSET_FOLDER="${asset_root}"
    ASSET_POLICY_SK_FILENAME=policy.skey
    ENABLE_CHATTR="${enable_chattr}"
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=characterized
    NETWORK_NAME=Preview
    ADVANCED_MODE=true
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    price_now=""
    slotnum=1000
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_raw}"
    CAPTURE_DONE_FILE="${capture_done_file}"
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
    unset password
    CHOICES=(a a e h q)
    CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_raw}"; then status=0; else status=$?; fi
  [[ "${status}" == 0 ]] || fail "${scenario} traversal returned ${status}"

  extract_action_output "${full_stdout}" "${action_stdout_raw}"
  normalize_file "${action_stdout_raw}" "${action_stdout}" "${runtime_root}"
  normalize_file "${stderr_raw}" "${stderr_file}" "${runtime_root}"
  normalize_file "${event_raw}" "${event_log}" "${runtime_root}"
  normalize_file "${vector_raw}" "${vector_log}" "${runtime_root}"
  write_expected_stdout "${scenario}" "${expected_stdout}"
  : > "${expected_stderr}"
  write_expected_events "${scenario}" "${mode}" "${expected_events}"
  write_expected_vectors "${scenario}" "${expected_vectors}"
  assert_files_equal "${action_stdout}" "${expected_stdout}" \
    "${scenario} exact normalized stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "${scenario} exact normalized stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "${scenario} exact wait, secret-state, and navigation events"
  assert_files_equal "${vector_log}" "${expected_vectors}" \
    "${scenario} exact redacted GPG/chattr vectors"
  [[ ! -s "${network_log}" ]] ||
    fail "${scenario} attempted network access: $(< "${network_log}")"
  for checked_file in "${full_stdout}" "${stderr_raw}" "${event_raw}" \
      "${vector_raw}" "${network_log}"; do
    ! grep -Fq -- "${FIXTURE_PASSWORD}" "${checked_file}" ||
      fail "${scenario} exposed the password in captured output"
  done

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "${scenario} post-snapshot failed"
  case "${scenario}" in
    success-no-chattr|success-chattr)
      assert_policy_mutation "${scenario}" "${runtime_root}" \
        "${before_snapshot}" "${after_snapshot}"
      ;;
    *) assert_zero_mutation "${scenario}" "${before_snapshot}" "${after_snapshot}" ;;
  esac
}

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
      features: ["advanced"],
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
    'scenario="${CNTOOLS_ASSET_ENCRYPT_SCENARIO:?}"' \
    'log="${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
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
    '[[ "${supplied}" == "${CNTOOLS_ASSET_ENCRYPT_EXPECTED_PASSWORD:?}" ]] || exit 98' \
    '[[ -n "${output}" && -n "${input}" ]] || exit 96' \
    'case "${scenario}" in' \
    '  direct-gpg-failure)' \
    '    printf '\''partial encrypted fixture\n'\'' > "${output}"' \
    '    exit 17' \
    '    ;;' \
    '  direct-inventory-race)' \
    '    printf '\''injected concurrent leaf\n'\'' > "${input%/*}/injected.race"' \
    '    ;;' \
    '  direct-source-race)' \
    '    printf '\''external mutation\n'\'' >> "${input}"' \
    '    ;;' \
    'esac' \
    'printf '\''encrypted fixture\n'\'' > "${output}"' \
    > "${DIRECT_FAKE_BIN}/gpg"
  chmod 0755 "${DIRECT_FAKE_BIN}/gpg"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_ENCRYPT_SCENARIO:?}"' \
    'target="${*: -1}" mode="${1:-}"' \
    'if [[ "${target}" == */asset/alpha/* ]]; then' \
    '  printf '\''chmod\t%q\t%q\n'\'' "${mode}" "${target}" >> "${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
    'fi' \
    'if [[ "${scenario}" == direct-chmod-failure &&' \
    '      "${mode}" =~ ^0?400$ && "${target}" == */policy.vkey &&' \
    '      ! -e "${CNTOOLS_ASSET_ENCRYPT_FAULT_MARKER:?}.chmod" ]]; then' \
    '  : > "${CNTOOLS_ASSET_ENCRYPT_FAULT_MARKER}.chmod"' \
    '  exit 42' \
    'fi' \
    'exec "${CNTOOLS_ASSET_ENCRYPT_REAL_CHMOD:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/chmod"
  chmod 0755 "${DIRECT_FAKE_BIN}/chmod"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_ENCRYPT_SCENARIO:?}" target="${*: -1}"' \
    'if [[ "${target}" == */asset/alpha/* ]]; then' \
    '  printf '\''rm'\'' >> "${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
    '  for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"; done' \
    '  printf '\''\n'\'' >> "${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
    'fi' \
    'if [[ "${scenario}" == direct-source-remove-failure &&' \
    '      "${target}" == */.cntools-policy-source.* && -s "${target}" &&' \
    '      ! -e "${CNTOOLS_ASSET_ENCRYPT_FAULT_MARKER:?}.rm" ]]; then' \
    '  : > "${CNTOOLS_ASSET_ENCRYPT_FAULT_MARKER}.rm"' \
    '  exit 43' \
    'fi' \
    'if [[ "${scenario}" == direct-temp-unlink-failure &&' \
    '      "${target}" == */.cntools-policy-encrypt.* &&' \
    '      ! -e "${CNTOOLS_ASSET_ENCRYPT_FAULT_MARKER:?}.temp-rm" ]]; then' \
    '  : > "${CNTOOLS_ASSET_ENCRYPT_FAULT_MARKER}.temp-rm"' \
    '  exit 46' \
    'fi' \
    'exec "${CNTOOLS_ASSET_ENCRYPT_REAL_RM:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/rm"
  chmod 0755 "${DIRECT_FAKE_BIN}/rm"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_ENCRYPT_SCENARIO:?}" target="${*: -1}"' \
    'if [[ "${scenario}" == direct-postcommit-lock-release && "${target}" == */.alpha.cntools-encrypt.lock ]]; then' \
    '  printf '\''rmdir\t%q\n'\'' "${target}" >> "${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
    '  exit 48' \
    'fi' \
    'exec "${CNTOOLS_ASSET_ENCRYPT_REAL_RMDIR:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/rmdir"
  chmod 0755 "${DIRECT_FAKE_BIN}/rmdir"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_ENCRYPT_SCENARIO:?}" target="${*: -1}"' \
    'if [[ "${scenario}" == direct-source-move-failure && "${target}" == */.cntools-policy-source.* && ! -e "${CNTOOLS_ASSET_ENCRYPT_FAULT_MARKER:?}.mv" ]]; then' \
    '  : > "${CNTOOLS_ASSET_ENCRYPT_FAULT_MARKER}.mv"' \
    '  "${CNTOOLS_ASSET_ENCRYPT_REAL_MV:?}" "$@" || exit $?' \
    '  exit 49' \
    'fi' \
    'exec "${CNTOOLS_ASSET_ENCRYPT_REAL_MV:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/mv"
  chmod 0755 "${DIRECT_FAKE_BIN}/mv"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'target="${*: -1}" state="${CNTOOLS_ASSET_ENCRYPT_IMMUTABLE_STATE:?}"' \
    'printf '\''lsattr'\'' >> "${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
    'if /usr/bin/grep -Fqx -- "${target}" "${state}" 2>/dev/null; then flags=----i---------; else flags=--------------; fi' \
    'printf '\''%s %s\n'\'' "${flags}" "${target}"' \
    > "${DIRECT_FAKE_BIN}/lsattr"
  chmod 0755 "${DIRECT_FAKE_BIN}/lsattr"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_ENCRYPT_SCENARIO:?}" operation="${1:-}" target="${*: -1}"' \
    'state="${CNTOOLS_ASSET_ENCRYPT_IMMUTABLE_STATE:?}" temporary="${state}.new"' \
    'printf '\''chattr'\'' >> "${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
    'if [[ "${operation}" == +i && "${scenario}" == direct-chattr-failure && "${target}" == */policy.vkey ]]; then exit 44; fi' \
    'if [[ "${operation}" == +i && ( "${scenario}" == direct-chattr-late-failure || "${scenario}" == direct-chattr-rollback-failure ) && "${target}" == *.gpg ]]; then exit 45; fi' \
    'if [[ "${operation}" == -i && "${scenario}" == direct-chattr-rollback-failure && "${target}" == */policy.vkey ]]; then exit 47; fi' \
    'if [[ "${operation}" == +i && "${scenario}" == direct-chattr-verify-failure && "${target}" == */policy.vkey ]]; then exit 0; fi' \
    'case "${operation}" in' \
    '  +i) /usr/bin/grep -Fqx -- "${target}" "${state}" 2>/dev/null || printf '\''%s\n'\'' "${target}" >> "${state}" ;;' \
    '  -i) /usr/bin/awk -v target="${target}" '\''$0 != target { print }'\'' "${state}" > "${temporary}"; "${CNTOOLS_ASSET_ENCRYPT_REAL_MV:?}" -- "${temporary}" "${state}" ;;' \
    '  *) exit 96 ;;' \
    'esac' \
    > "${DIRECT_FAKE_BIN}/chattr"
  chmod 0755 "${DIRECT_FAKE_BIN}/chattr"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'printf '\''sudo'\'' >> "${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG:?}"' \
    'exec "$@"' \
    > "${DIRECT_FAKE_BIN}/sudo"
  chmod 0755 "${DIRECT_FAKE_BIN}/sudo"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_ASSET_ENCRYPT_NETWORK_LOG:?}"' \
      'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_ENCRYPT_NETWORK_LOG:?}"; done' \
      'printf '\''\n'\'' >> "${CNTOOLS_ASSET_ENCRYPT_NETWORK_LOG:?}"' \
      'exit 97' \
      > "${DIRECT_FAKE_BIN}/${command_name}"
    chmod 0755 "${DIRECT_FAKE_BIN}/${command_name}"
  done
}

prepare_direct_scenario() {
  local scenario="$1" runtime_root="$2" asset_root="$3"
  local policy_root="${asset_root}/alpha"

  chmod 0755 "${asset_root}"
  [[ "${scenario}" == direct-empty ]] && return 0
  if [[ "${scenario}" == direct-policy-symlink ]]; then
    mkdir -p -- "${runtime_root}/outside-policy"
    chmod 0755 "${runtime_root}/outside-policy"
    printf 'signing secret fixture\n' > "${runtime_root}/outside-policy/policy.skey"
    printf 'verification key fixture\n' > "${runtime_root}/outside-policy/policy.vkey"
    ln -s -- "${runtime_root}/outside-policy" "${policy_root}"
    return 0
  fi
  mkdir -p -- "${policy_root}"
  chmod 0755 "${policy_root}"
  case "${scenario}" in
    direct-already-encrypted)
      printf 'existing encrypted key\n' > "${policy_root}/policy.skey.gpg"
      ;;
    direct-missing-skey)
      printf 'verification key fixture\n' > "${policy_root}/policy.vkey"
      ;;
    *)
      printf 'signing secret fixture\n' > "${policy_root}/policy.skey"
      printf 'verification key fixture\n' > "${policy_root}/policy.vkey"
      ;;
  esac
  case "${scenario}" in
    direct-symlink-source)
      rm -f -- "${policy_root}/policy.skey"
      printf '%s\n' \
        '$(touch${IFS}${CNTOOLS_ASSET_ENCRYPT_COMMAND_SENTINEL})' \
        > "${runtime_root}/outside.skey"
      ln -s -- "${runtime_root}/outside.skey" \
        "${policy_root}/policy.skey"
      ;;
    direct-hardlink-source)
      ln -- "${policy_root}/policy.skey" "${runtime_root}/outside.link"
      ;;
    direct-special-leaf)
      mkfifo "${policy_root}/unsafe.pipe"
      ;;
    direct-root-mode) chmod 0777 "${asset_root}" ;;
    direct-policy-mode) chmod 0777 "${policy_root}" ;;
    direct-file-mode) chmod 0666 "${policy_root}/policy.skey" ;;
    direct-lock-contention)
      mkdir -- "${asset_root}/.alpha.cntools-encrypt.lock"
      chmod 0700 "${asset_root}/.alpha.cntools-encrypt.lock"
      ;;
    direct-preexisting-gpg)
      printf 'ambiguous encrypted key\n' > \
        "${policy_root}/unrelated.gpg"
      ;;
    direct-reserved-temp)
      printf 'ambiguous transaction residue\n' > \
        "${policy_root}/.cntools-policy-source.stale"
      ;;
  esac
}

direct_expected_status() {
  case "$1" in
    direct-root-mode|direct-inventory-race|direct-source-race|direct-temp-unlink-failure|direct-chattr-rollback-failure)
      printf '70\n'
      ;;
    *) printf '0\n' ;;
  esac
}

direct_expected_waits() {
  case "$1" in
    direct-selection-cancel|direct-root-mode|direct-inventory-race|direct-source-race|direct-temp-unlink-failure|direct-chattr-rollback-failure)
      printf '0\n'
      ;;
    *) printf '1\n' ;;
  esac
}

write_expected_direct_success_stdout() {
  local target="$1"

  write_header > "${target}"
  printf '%s\n' \
    'Select policy to encrypt' \
    '' \
    'Encrypting policy signing key with GPG' \
    '<runtime>/asset/alpha/policy.skey successfully encrypted' \
    '' \
    "Write protecting all policy files with 400 permission and if enabled 'chattr +i'" \
    '<runtime>/asset/alpha/policy.vkey' \
    '<runtime>/asset/alpha/policy.skey.gpg' \
    '' \
    'Policy encrypted : alpha' \
    'Files locked     : 2' \
    'Files encrypted  : 1' \
    '' \
    'INFO: policy files are now protected' \
    "Use 'ADVANCED >> ASSET >> DECRYPT / UNLOCK POLICY' to unlock" \
    >> "${target}"
}

assert_direct_parity_stdout() {
  local scenario="$1" runtime_root="$2" stdout_file="$3" capture_root="$4"
  local normalized="${capture_root}/stdout.normalized"
  local expected="${capture_root}/stdout.expected"

  normalize_file "${stdout_file}" "${normalized}" "${runtime_root}"
  case "${scenario}" in
    direct-empty) write_expected_stdout empty "${expected}" ;;
    direct-selection-fail)
      write_expected_stdout selection-fail "${expected}"
      ;;
    direct-selection-cancel)
      write_expected_stdout selection-cancel "${expected}"
      ;;
    direct-already-encrypted)
      write_expected_stdout already-encrypted "${expected}"
      ;;
    direct-password-abort)
      write_expected_stdout password-abort "${expected}"
      ;;
    direct-success-local|direct-success-light|direct-success-offline|direct-success-chattr|direct-postcommit-signal)
      write_expected_direct_success_stdout "${expected}"
      ;;
    *) return 0 ;;
  esac
  assert_files_equal "${normalized}" "${expected}" \
    "${scenario} direct exact normalized stdout parity"
}

assert_direct_success_state() {
  local scenario="$1" runtime_root="$2" policy_root=""

  policy_root="${runtime_root}/asset/alpha"

  [[ ! -e "${policy_root}/policy.skey" &&
     ! -L "${policy_root}/policy.skey" &&
     -f "${policy_root}/policy.skey.gpg" &&
     "$(file_mode "${policy_root}/policy.skey.gpg")" == 400 &&
     -f "${policy_root}/policy.vkey" &&
     "$(file_mode "${policy_root}/policy.vkey")" == 400 &&
     "$(< "${policy_root}/policy.skey.gpg")" == 'encrypted fixture' ]] ||
    fail "${scenario} hardened success state changed"
}

assert_direct_failure_state() {
  local scenario="$1" runtime_root="$2" before="$3" after="$4"
  local filtered_before="${before}.filtered" filtered_after="${after}.filtered"

  case "${scenario}" in
    direct-inventory-race)
      [[ -f "${runtime_root}/asset/alpha/injected.race" ]] ||
        fail 'inventory race was not injected'
      grep -Fv $'f\tasset/alpha/injected.race\t' "${before}" > "${filtered_before}"
      grep -Fv $'f\tasset/alpha/injected.race\t' "${after}" > "${filtered_after}"
      assert_files_equal "${filtered_after}" "${filtered_before}" \
        'inventory-race action-owned rollback state'
      ;;
    direct-source-race)
      [[ "$(< "${runtime_root}/asset/alpha/policy.skey")" == \
         $'signing secret fixture\nexternal mutation' ]] ||
        fail 'source race was not injected'
      sed '/asset\/alpha\/policy\.skey/d' "${before}" > "${filtered_before}"
      sed '/asset\/alpha\/policy\.skey/d' "${after}" > "${filtered_after}"
      assert_files_equal "${filtered_after}" "${filtered_before}" \
        'source-race action-owned rollback state'
      ;;
    *)
      assert_files_equal "${after}" "${before}" \
        "${scenario} recoverable zero-mutation state"
      ;;
  esac
}

run_direct_case() {
  local scenario="$1" mode="$2" chattr_enabled="${3:-false}"
  local case_root="${TEST_ROOT}/direct-cases/${scenario}"
  local runtime_root="${case_root}/runtime" asset_root=""
  local capture_root="${case_root}/capture"
  local stdout_file="${capture_root}/stdout" stderr_file="${capture_root}/stderr"
  local event_log="${capture_root}/events" vector_log="${capture_root}/vectors"
  local network_log="${capture_root}/network" immutable_state="${capture_root}/immutable"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local private_root="${runtime_root}/tmp/private"
  local context_file="${private_root}/context.json"
  local result_file="${private_root}/result.json"
  local command_sentinel="${capture_root}/command-executed"
  local expected_status="" expected_waits="" status=0 wait_count=0

  asset_root="${runtime_root}/asset"

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${runtime_root}/wallet" "${runtime_root}/pool" "${asset_root}" \
    "${capture_root}"
  prepare_direct_scenario "${scenario}" "${runtime_root}" "${asset_root}"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "${scenario} direct pre-snapshot failed"
  : > "${event_log}"; : > "${vector_log}"; : > "${network_log}"
  : > "${immutable_state}"
  expected_status="$(direct_expected_status "${scenario}")"
  expected_waits="$(direct_expected_waits "${scenario}")"

  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    export CNTOOLS_ASSET_ENCRYPT_SCENARIO="${scenario}"
    export CNTOOLS_ASSET_ENCRYPT_DIRECT_VECTOR_LOG="${vector_log}"
    export CNTOOLS_ASSET_ENCRYPT_NETWORK_LOG="${network_log}"
    export CNTOOLS_ASSET_ENCRYPT_EXPECTED_PASSWORD="${FIXTURE_PASSWORD}"
    export CNTOOLS_ASSET_ENCRYPT_FAULT_MARKER="${capture_root}/fault"
    export CNTOOLS_ASSET_ENCRYPT_IMMUTABLE_STATE="${immutable_state}"
    export CNTOOLS_ASSET_ENCRYPT_COMMAND_SENTINEL="${command_sentinel}"
    CNTOOLS_ASSET_ENCRYPT_REAL_CHMOD="$(type -P chmod)"
    CNTOOLS_ASSET_ENCRYPT_REAL_RM="$(type -P rm)"
    CNTOOLS_ASSET_ENCRYPT_REAL_MV="$(type -P mv)"
    CNTOOLS_ASSET_ENCRYPT_REAL_RMDIR="$(type -P rmdir)"
    export CNTOOLS_ASSET_ENCRYPT_REAL_CHMOD
    export CNTOOLS_ASSET_ENCRYPT_REAL_RM
    export CNTOOLS_ASSET_ENCRYPT_REAL_MV
    export CNTOOLS_ASSET_ENCRYPT_REAL_RMDIR
    PATH="${DIRECT_FAKE_BIN}:${BASE_PATH}"
    export PATH
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    ASSET_FOLDER="${asset_root}"
    ASSET_POLICY_SK_FILENAME=policy.skey
    ENABLE_CHATTR="${chattr_enabled}"
    CNTOOLS_MODE="${mode}"
    FG_RED="" FG_GREEN="" FG_YELLOW="" FG_LBLUE="" NC=""
    EVENT_LOG="${event_log}"
    CAPTURE_ACTIVE=N
    END_ON_CLEAR=N
    DIRECT_ACTIVE=Y
    unset password policy_name encrypt_policy_secret
    mkdir -p -- "${private_root}"
    chmod 0700 "${private_root}"
    write_direct_context "${context_file}" "${mode}" "${runtime_root}/home"
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"
    direct_status=$?
    [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || exit 98
    rm -f -- "${context_file}"
    rmdir -- "${private_root}"
    exit "${direct_status}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  [[ "${status}" == "${expected_status}" ]] ||
    fail "${scenario} direct dispatch returned ${status}, expected ${expected_status}"
  [[ ! -e "${command_sentinel}" && ! -L "${command_sentinel}" ]] ||
    fail "${scenario} evaluated untrusted policy data as shell code"

  wait_count="$(grep -c '^action:waitToProceed$' "${event_log}" || true)"
  [[ "${wait_count}" == "${expected_waits}" ]] ||
    fail "${scenario} direct wait count ${wait_count}, expected ${expected_waits}"
  ! grep -Fq 'action:secret:present' "${event_log}" ||
    fail "${scenario} retained a password at wait"
  ! grep -Fq 'action:lock:present' "${event_log}" ||
    [[ "${scenario}" == direct-postcommit-lock-release ]] ||
    fail "${scenario} waited while holding its operation lock"
  if [[ "${expected_waits}" == 1 && "${scenario}" != direct-empty ]]; then
    awk '
      /^terminal:ed$/ { restored=NR }
      /^action:waitToProceed$/ { waited=NR }
      END { exit !(restored > 0 && restored < waited) }
    ' "${event_log}" || fail "${scenario} waited before terminal restoration"
  fi
  [[ ! -s "${network_log}" ]] ||
    fail "${scenario} attempted network access"
  for checked_file in "${stdout_file}" "${stderr_file}" "${event_log}" \
      "${vector_log}" "${network_log}"; do
    ! grep -Fq -- "${FIXTURE_PASSWORD}" "${checked_file}" ||
      fail "${scenario} exposed the password"
  done
  case "${scenario}" in
    direct-success-*|direct-gpg-failure|direct-chmod-failure|direct-chattr-*|direct-source-*-failure|direct-temp-unlink-failure|direct-postcommit-*|direct-inventory-race|direct-source-race)
      [[ "$(grep -c '^gpg' "${vector_log}" || true)" == 1 ]] ||
        fail "${scenario} GPG invocation count changed"
      grep -Eq $'^gpg\t--symmetric\t--yes\t--batch\t--no-tty\t--pinentry-mode\tloopback\t--cipher-algo\tAES256\t--passphrase-fd\t0\t--output\t/.*/\\.cntools-policy-encrypt\\.[A-Za-z0-9]+\t--\t/.*/policy\\.skey$' \
        "${vector_log}" || fail "${scenario} hardened GPG argv changed"
      ;;
  esac
  if [[ "${expected_status}" == 70 ]]; then
    grep -Fxq 'CNTools asset encrypt-policy action failed validation.' \
      "${stderr_file}" || fail "${scenario} fixed status-70 diagnostic changed"
  else
    [[ ! -s "${stderr_file}" ]] ||
      fail "${scenario} emitted unexpected stderr"
  fi
  assert_direct_parity_stdout "${scenario}" "${runtime_root}" \
    "${stdout_file}" "${capture_root}"
  [[ ! -e "${asset_root}/.alpha.cntools-encrypt.lock" ||
     "${scenario}" == direct-lock-contention ||
     "${scenario}" == direct-postcommit-lock-release ]] ||
    fail "${scenario} left its operation lock"
  if [[ "${scenario}" == direct-reserved-temp ]]; then
    [[ -f "${asset_root}/alpha/.cntools-policy-source.stale" ]] ||
      fail 'reserved transaction residue fixture changed'
  else
    [[ -z "$(find "${asset_root}" -name '.cntools-policy-*' -print -quit)" ]] ||
      fail "${scenario} left a transaction temporary"
  fi

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "${scenario} direct post-snapshot failed"
  case "${scenario}" in
    direct-success-local|direct-success-light|direct-success-offline|direct-success-chattr|direct-postcommit-lock-release|direct-postcommit-signal)
      assert_direct_success_state "${scenario}" "${runtime_root}"
      if [[ "${scenario}" == direct-success-chattr ]]; then
        grep -Fqx -- "${runtime_root}/asset/alpha/policy.vkey" \
          "${immutable_state}" || fail 'success-chattr did not lock policy.vkey'
        grep -Fqx -- "${runtime_root}/asset/alpha/policy.skey.gpg" \
          "${immutable_state}" || fail 'success-chattr did not lock ciphertext'
        [[ "$(wc -l < "${immutable_state}" | tr -d '[:space:]')" == 2 ]] ||
          fail 'success-chattr immutable state included unexpected files'
      fi
      ;;
    *)
      assert_direct_failure_state "${scenario}" "${runtime_root}" \
        "${before_snapshot}" "${after_snapshot}"
      ;;
  esac
  case "${scenario}" in
    direct-gpg-failure)
      grep -Fq 'ERROR: failed to encrypt policy signing key!' \
        "${stdout_file}" || fail 'GPG failure diagnostic changed'
      ;;
    direct-chmod-failure|direct-chattr-failure|direct-chattr-late-failure|direct-chattr-verify-failure)
      grep -Fq 'ERROR: failed to lock policy files; original policy was preserved!' \
        "${stdout_file}" || fail "${scenario} rollback diagnostic changed"
      [[ ! -s "${immutable_state}" ]] ||
        fail "${scenario} did not prove immutable rollback"
      ;;
    direct-chattr-rollback-failure)
      ! grep -Fq 'original policy was preserved' "${stdout_file}" ||
        fail 'unproven immutable rollback claimed preservation'
      [[ -s "${immutable_state}" ]] ||
        fail 'immutable rollback failure was not injected'
      ;;
    direct-source-remove-failure|direct-source-move-failure)
      grep -Fq 'ERROR: failed to commit encrypted policy; original policy was preserved!' \
        "${stdout_file}" || fail 'commit rollback diagnostic changed'
      ;;
    direct-postcommit-lock-release)
      grep -Fq 'WARNING: policy encryption committed, but the policy operation lock could not be removed; administrative cleanup is required!' \
        "${stdout_file}" || fail 'postcommit cleanup warning changed'
      [[ -d "${asset_root}/.alpha.cntools-encrypt.lock" &&
         "$(file_mode "${asset_root}/.alpha.cntools-encrypt.lock")" == 700 ]] ||
        fail 'postcommit lock residue did not remain bounded'
      ;;
  esac
}

write_fake_commands

run_case empty
run_case selection-fail
run_case selection-cancel
run_case already-encrypted
run_case password-abort
run_case missing-skey
run_case success-no-chattr
run_case success-chattr
run_case success-immutable
run_case gpg-failure
run_case chattr-failure
run_case symlink-skey

write_direct_fake_commands
run_direct_case direct-empty OFFLINE
run_direct_case direct-selection-fail LIGHT
run_direct_case direct-selection-cancel LOCAL
run_direct_case direct-already-encrypted OFFLINE
run_direct_case direct-password-abort LIGHT
run_direct_case direct-success-local LOCAL
run_direct_case direct-success-light LIGHT
run_direct_case direct-success-offline OFFLINE
run_direct_case direct-success-chattr OFFLINE true
run_direct_case direct-missing-skey OFFLINE
run_direct_case direct-invalid-name OFFLINE
run_direct_case direct-command-name OFFLINE
run_direct_case direct-policy-symlink OFFLINE
run_direct_case direct-symlink-source OFFLINE
run_direct_case direct-hardlink-source OFFLINE
run_direct_case direct-special-leaf OFFLINE
run_direct_case direct-root-mode OFFLINE
run_direct_case direct-policy-mode OFFLINE
run_direct_case direct-file-mode OFFLINE
run_direct_case direct-lock-contention OFFLINE
run_direct_case direct-preexisting-gpg OFFLINE
run_direct_case direct-reserved-temp OFFLINE
run_direct_case direct-gpg-failure OFFLINE
run_direct_case direct-chmod-failure OFFLINE
run_direct_case direct-chattr-failure OFFLINE true
run_direct_case direct-chattr-late-failure OFFLINE true
run_direct_case direct-chattr-verify-failure OFFLINE true
run_direct_case direct-chattr-rollback-failure OFFLINE true
run_direct_case direct-source-remove-failure OFFLINE
run_direct_case direct-source-move-failure OFFLINE
run_direct_case direct-temp-unlink-failure OFFLINE
run_direct_case direct-postcommit-lock-release OFFLINE
run_direct_case direct-postcommit-signal OFFLINE
run_direct_case direct-inventory-race OFFLINE
run_direct_case direct-source-race OFFLINE

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

# Freeze the exact one-call public route and removal of the unsafe inline body.
encrypt_policy_arm="${TEST_ROOT}/encrypt-policy-arm"
awk '
  /^[[:space:]]+encrypt-policy\)/ { capture = 1 }
  capture { print }
  capture && /^[[:space:]]+;;/ { exit }
' "${CNTOOLS_SCRIPT}" > "${encrypt_policy_arm}"
[[ "$(grep -c 'cntools_compatibility_dispatch_action advanced.asset.encrypt-policy' \
      "${encrypt_policy_arm}" || true)" == 1 ]] ||
  fail 'public encrypt-policy arm does not contain exactly one dispatch call'
if grep -Eq 'encryptFile|keyFiles|filesLocked|keysEncrypted|chmod 400|sudo chattr|selectPolicy' \
    "${encrypt_policy_arm}"; then
  fail 'former inline encrypt-policy implementation remains in the public arm'
fi
grep -Fq 'echo "${2}" | gpg --symmetric --yes --batch --cipher-algo AES256 --passphrase-fd 0' \
  "${LEGACY_SELECTION_SOURCE}" ||
  fail 'legacy password pipe to GPG changed'
grep -Fq 'safeDel "${1}" >/dev/null || {' "${LEGACY_SELECTION_SOURCE}" ||
  fail 'legacy post-GPG source deletion changed'
grep -Fq 'cntools_action_main() {' "${ACTION_SOURCE}" ||
  fail 'encrypt-policy modular entrypoint is missing'
grep -Fq '_cntools_action_advanced_asset_encrypt_policy_rollback() {' \
  "${ACTION_SOURCE}" || fail 'encrypt-policy rollback boundary is missing'
grep -Fq '.cntools-encrypt.lock' "${ACTION_SOURCE}" ||
  fail 'encrypt-policy operation lock is missing'
grep -Fq -- '--passphrase-fd 0' "${ACTION_SOURCE}" ||
  fail 'encrypt-policy private password transport changed'
if grep -Eq 'encryptFile|safeDel|rm[[:space:]]+-rf|--passphrase([ =]|$)' \
    "${ACTION_SOURCE}"; then
  fail 'encrypt-policy action contains a forbidden legacy/destructive primitive'
fi
grep -Fq 'CNTools actions are launched by the dispatcher, not directly.' \
  "${ACTION_SOURCE}" || fail 'encrypt-policy direct-execution guard changed'

printf 'CNTools asset-encrypt-policy characterization/parity passed (12 public + 35 direct cases)\n'
