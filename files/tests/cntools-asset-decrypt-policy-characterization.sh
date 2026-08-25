#!/usr/bin/env bash
# Characterize the legacy advanced.asset.decrypt-policy contract and verify the
# hardened compatibility action through both the public and direct routes.
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools asset-decrypt-policy characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
LEGACY_SELECTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f/020-terminal-selection-security.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/advanced/asset/decrypt-policy/action.sh"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/advanced/asset/decrypt-policy"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-asset-decrypt.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
DIRECT_FAKE_BIN="${TEST_ROOT}/direct-fake-bin"
REAL_CHMOD="$(command -v chmod 2>/dev/null || true)"
REAL_RM="$(command -v rm 2>/dev/null || true)"
REAL_RMDIR="$(command -v rmdir 2>/dev/null || true)"
FIXTURE_PASSWORD='characterization-only-password'

cleanup_test() {
  if [[ "${CNTOOLS_ASSET_DECRYPT_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools asset-decrypt-policy test root preserved: %s\n' \
      "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools asset-decrypt-policy characterization failed: %s\n' \
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
    'scenario="${CNTOOLS_ASSET_DECRYPT_SCENARIO:?}"' \
    'vector_log="${CNTOOLS_ASSET_DECRYPT_VECTOR_LOG:?}"' \
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
    '[[ "${supplied}" == "${CNTOOLS_ASSET_DECRYPT_EXPECTED_PASSWORD:?}" ]] || exit 98' \
    '[[ "$*" == "--decrypt --batch --yes --no-tty --pinentry-mode loopback --passphrase-fd 0 --output "*" -- "* ]] || exit 96' \
    '[[ -n "${output}" && -n "${input}" ]] || exit 96' \
    'case "${scenario}:${input##*/}" in' \
    '  gpg-failure:*|multiple-partial:b-fail.skey.gpg)' \
    '    printf '\''partial decrypted fixture\n'\'' > "${output}"' \
    '    exit 17' \
    '    ;;' \
    'esac' \
    'printf '\''decrypted fixture\n'\'' > "${output}"' \
    > "${FAKE_BIN}/gpg"
  chmod 0755 "${FAKE_BIN}/gpg"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'printf '\''chmod'\'' >> "${CNTOOLS_ASSET_DECRYPT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_DECRYPT_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_ASSET_DECRYPT_VECTOR_LOG:?}"' \
    'scenario="${CNTOOLS_ASSET_DECRYPT_SCENARIO:?}" target="${*: -1}" mode="${1:-}"' \
    'marker="${CNTOOLS_ASSET_DECRYPT_FAULT_MARKER:?}.chmod"' \
    'if [[ "${mode}" =~ ^0?600$ && ! -e "${marker}" ]]; then' \
    '  case "${scenario}:${target##*/}" in' \
    '    chmod-unlock-failure:plain.vkey|chmod-decrypted-failure:policy.skey.gpg) : > "${marker}"; exit 18 ;;' \
    '  esac' \
    'fi' \
    'exec "${CNTOOLS_ASSET_DECRYPT_REAL_CHMOD:?}" "$@"' \
    > "${FAKE_BIN}/chmod"
  chmod 0755 "${FAKE_BIN}/chmod"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''lsattr'\'' >> "${CNTOOLS_ASSET_DECRYPT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_DECRYPT_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_ASSET_DECRYPT_VECTOR_LOG:?}"' \
    'if [[ "${CNTOOLS_ASSET_DECRYPT_SCENARIO:?}" == lsattr-failure ]]; then printf '\''raw lsattr failure\n'\'' >&2; exit 19; fi' \
    'if /usr/bin/grep -Fqx -- "${*: -1}" "${CNTOOLS_ASSET_DECRYPT_IMMUTABLE_STATE:?}" 2>/dev/null; then flags=----i---------; else flags=--------------; fi' \
    'printf '\''%s %s\n'\'' "${flags}" "${*: -1}"' \
    > "${FAKE_BIN}/lsattr"
  chmod 0755 "${FAKE_BIN}/lsattr"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''sudo'\'' >> "${CNTOOLS_ASSET_DECRYPT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_DECRYPT_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_ASSET_DECRYPT_VECTOR_LOG:?}"' \
    '[[ "${1##*/}" == chattr ]] || exit 96' \
    'exec "$@"' \
    > "${FAKE_BIN}/sudo"
  chmod 0755 "${FAKE_BIN}/sudo"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''chattr'\'' >> "${CNTOOLS_ASSET_DECRYPT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_DECRYPT_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_ASSET_DECRYPT_VECTOR_LOG:?}"' \
    'scenario="${CNTOOLS_ASSET_DECRYPT_SCENARIO:?}" operation="${1:-}" target="${*: -1}"' \
    'state="${CNTOOLS_ASSET_DECRYPT_IMMUTABLE_STATE:?}" temporary="${state}.new"' \
    '[[ "${scenario}:${operation}" != chattr-failure:-i ]] || exit 19' \
    'case "${operation}" in' \
    '  -i) /usr/bin/awk -v target="${target}" '\''$0 != target { print }'\'' "${state}" > "${temporary}"; /bin/mv -f -- "${temporary}" "${state}" ;;' \
    '  +i) /usr/bin/grep -Fqx -- "${target}" "${state}" 2>/dev/null || printf '\''%s\n'\'' "${target}" >> "${state}" ;;' \
    '  *) exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/chattr"
  chmod 0755 "${FAKE_BIN}/chattr"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_ASSET_DECRYPT_NETWORK_LOG:?}"' \
      'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_DECRYPT_NETWORK_LOG:?}"; done' \
      'printf '\''\n'\'' >> "${CNTOOLS_ASSET_DECRYPT_NETWORK_LOG:?}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}
# Source the controller and the legacy decryption helper used by the arm.
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

# Test-only public bridge: preserve the public caller/outcome mapping while
# dispatching the shipped action in a private context without requiring an
# installed generation fixture.
cntools_compatibility_dispatch_action() {
  local action_id="${1:-}" private_root="" context_file=""
  local result_file="" action_status=0 tmp_mode=""

  [[ "${action_id}" == advanced.asset.decrypt-policy && $# == 1 ]] ||
    return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  tmp_mode="$(file_mode "${TMP_DIR}")" || return 70
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/asset-decrypt-test-dispatch.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  "${REAL_CHMOD}" 0700 "${TMP_DIR}" "${private_root}" || return 70
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
  "${REAL_CHMOD}" 0400 "${context_file}" || return 70
  if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"; then
    action_status=0
  else
    action_status=$?
  fi
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || action_status=70
  "${REAL_RM}" -f -- "${result_file}" "${context_file}" || action_status=70
  "${REAL_RMDIR}" -- "${private_root}" || action_status=70
  "${REAL_CHMOD}" "${tmp_mode}" "${TMP_DIR}" || action_status=70
  if [[ "${CAPTURE_ACTIVE:-N}" == Y &&
        ! -e "${CAPTURE_DONE_FILE:-/nonexistent}" ]]; then
    printf '__CNTOOLS_ASSET_DECRYPT_END__\n'
    : > "${CAPTURE_DONE_FILE:?}"
    CAPTURE_ACTIVE=N
  fi
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
    printf '__CNTOOLS_ASSET_DECRYPT_END__\n'
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
      if [[ "${menu}:${choice}" == asset:d ]]; then
        CAPTURE_ACTIVE=Y
        printf '__CNTOOLS_ASSET_DECRYPT_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was unavailable in ${menu} menu"
}

selectPolicy() {
  [[ "${1:-}" == encrypted && $# == 1 ]] ||
    fail 'decrypt-policy selection contract changed'
  printf 'action:selectPolicy:encrypted\n' >> "${EVENT_LOG:?}"
  case "${CNTOOLS_ASSET_DECRYPT_SCENARIO:?}" in
    selection-fail) return 1 ;;
    selection-cancel)
      END_ON_CLEAR=Y
      return 2
      ;;
    traversal-outside) policy_name='../outside-policy' ;;
    *) policy_name=alpha ;;
  esac
}

getPasswordCust() {
  [[ $# == 0 ]] || fail 'decrypt-policy password prompt contract changed'
  printf 'action:password\n' >> "${EVENT_LOG:?}"
  password="${FIXTURE_PASSWORD}"
  [[ "${CNTOOLS_ASSET_DECRYPT_SCENARIO:?}" != password-abort ]]
}

safeDel() {
  local target="${1:-}"

  printf 'action:safeDel:%s\n' "${target}" >> "${EVENT_LOG:?}"
  rm -f -- "${target}"
}

waitToProceed() {
  printf 'action:secret:%s\n' \
    "$([[ -v password ]] && printf present || printf unset)" \
    >> "${EVENT_LOG:?}"
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${DIRECT_ACTIVE:-N}" == Y ]]; then
    if [[ -d "${ASSET_FOLDER:-}/.alpha.cntools-decrypt.lock" ]]; then
      printf 'action:lock:present\n' >> "${EVENT_LOG}"
    else
      printf 'action:lock:absent\n' >> "${EVENT_LOG}"
    fi
  fi
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    printf '__CNTOOLS_ASSET_DECRYPT_END__\n'
    : > "${CAPTURE_DONE_FILE:?}"
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
    empty|unlock-only|multiple-success|chmod-unlock-failure|file-symlink|traversal-outside)
      printf 'LOCAL\n'
      ;;
    selection-fail|password-abort|gpg-failure|already-immutable|chmod-decrypted-failure|hardlink-outside)
      printf 'LIGHT\n'
      ;;
    *) printf 'OFFLINE\n' ;;
  esac
}

scenario_chattr() {
  case "$1" in
    chattr-nonimmutable|already-immutable|chattr-failure|lsattr-failure)
      printf 'true\n'
      ;;
    *) printf 'false\n' ;;
  esac
}

prepare_scenario() {
  local scenario="$1" runtime_root="$2" asset_root="$3"
  local policy_root="${asset_root}/alpha"

  [[ "${scenario}" == empty ]] && return 0
  if [[ "${scenario}" == traversal-outside ]]; then
    policy_root="${runtime_root}/outside-policy"
    mkdir -p -- "${asset_root}/visible-policy"
  fi
  mkdir -p -- "${policy_root}"
  case "${scenario}" in
    selection-fail|selection-cancel|unlock-only|chattr-nonimmutable|\
      already-immutable|chattr-failure|lsattr-failure|chmod-unlock-failure|\
      traversal-outside)
      printf 'verification key fixture\n' > "${policy_root}/plain.vkey"
      ;;
    password-abort|one-success|gpg-failure|chmod-decrypted-failure)
      printf 'encrypted key fixture\n' > "${policy_root}/policy.skey.gpg"
      ;;
    multiple-success)
      printf 'encrypted A\n' > "${policy_root}/a.skey.gpg"
      printf 'encrypted B\n' > "${policy_root}/b.skey.gpg"
      ;;
    multiple-partial)
      printf 'encrypted A\n' > "${policy_root}/a-ok.skey.gpg"
      printf 'encrypted B\n' > "${policy_root}/b-fail.skey.gpg"
      ;;
    file-symlink)
      printf 'outside verification key\n' > "${runtime_root}/outside.vkey"
      ln -s -- "${runtime_root}/outside.vkey" "${policy_root}/plain.vkey"
      ;;
    hardlink-outside)
      printf 'shared verification key\n' > "${runtime_root}/outside.vkey"
      ln "${runtime_root}/outside.vkey" "${policy_root}/plain.vkey"
      ;;
    output-symlink)
      printf 'outside signing secret\n' > "${runtime_root}/outside.skey"
      ln -s -- "${runtime_root}/outside.skey" "${policy_root}/policy.skey"
      printf 'encrypted key fixture\n' > "${policy_root}/policy.skey.gpg"
      ;;
    *) fail "unknown decrypt fixture scenario: ${scenario}" ;;
  esac
  find "${policy_root}" -mindepth 1 -maxdepth 1 -type f \
    -exec "${REAL_CHMOD}" 0400 {} \;
  case "${scenario}" in
    file-symlink|hardlink-outside) "${REAL_CHMOD}" 0400 "${runtime_root}/outside.vkey" ;;
    output-symlink) "${REAL_CHMOD}" 0600 "${runtime_root}/outside.skey" ;;
  esac
}

normalize_file() {
  local source="$1" target="$2" runtime_root="$3"

  sed \
    -e "s#${runtime_root}#<runtime>#g" \
    -e "s#${TEST_ROOT}#<test>#g" \
    -e 's#\.alpha\.cntools-decrypt\.lock/plain\.[0-9][0-9]*\.[A-Za-z0-9]*#.alpha.cntools-decrypt.lock/plain.<temp>#g' \
    "${source}" > "${target}"
}

extract_action_output() {
  local source="$1" target="$2"

  [[ "$(grep -c '^__CNTOOLS_ASSET_DECRYPT_BEGIN__$' "${source}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_ASSET_DECRYPT_END__$' "${source}" || true)" == 1 ]] ||
    fail 'decrypt-policy output markers changed'
  awk '
    $0 == "__CNTOOLS_ASSET_DECRYPT_BEGIN__" { capture=1; next }
    $0 == "__CNTOOLS_ASSET_DECRYPT_END__" { exit }
    capture { print }
  ' "${source}" > "${target}"
}

write_header() {
  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> ADVANCED >> ASSET >> DECRYPT / UNLOCK POLICY' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ''
}

write_expected_stdout() {
  local scenario="$1" target="$2" initial_files="$3"
  local unlocked=0 decrypted=0 policy_name=alpha path="" basename=""

  [[ "${scenario}" == traversal-outside ]] && policy_name='../outside-policy'
  write_header > "${target}"
  if [[ "${scenario}" == empty ]]; then
    printf '%s\n' 'No policies available!' >> "${target}"
    return
  fi
  printf '%s\n' 'Select policy to decrypt' >> "${target}"
  case "${scenario}" in
    selection-fail|selection-cancel) return ;;
    file-symlink|hardlink-outside|output-symlink|traversal-outside|lsattr-failure)
      printf '%s\n' '' \
        'ERROR: selected policy failed security validation!' >> "${target}"
      return
      ;;
  esac

  printf '%s\n' '' 'Removing write protection from all policy files' \
    >> "${target}"
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    printf '%s\n' "${path}" >> "${target}"
    unlocked=$((unlocked + 1))
  done < "${initial_files}"

  if grep -q '\.gpg$' "${initial_files}"; then
    printf '%s\n' '' 'Decrypting GPG encrypted policy key' >> "${target}"
    if [[ "${scenario}" == password-abort ]]; then
      printf '%s\n' '' '' '' 'ERROR: password input aborted!' >> "${target}"
      return
    fi
    if [[ "${scenario}" == gpg-failure ||
          "${scenario}" == multiple-partial ]]; then
      printf '%s\n' '' \
        'ERROR: failed to decrypt policy files; original encrypted policy was preserved!' \
        >> "${target}"
      return
    fi
    while IFS= read -r path; do
      [[ "${path}" == *.gpg ]] || continue
      basename="${path##*/}"
      case "${scenario}:${basename}" in
        *)
          printf '%s successfully decrypted\n' "${path}" >> "${target}"
          [[ "${scenario}" != chmod-decrypted-failure ]] &&
            decrypted=$((decrypted + 1))
          ;;
      esac
    done < "${initial_files}"
  fi

  case "${scenario}" in
    chattr-failure|chmod-unlock-failure|chmod-decrypted-failure)
      printf '%s\n' '' \
        'ERROR: failed to unlock/decrypt policy files; original encrypted policy was preserved!' \
        >> "${target}"
      return
      ;;
  esac

  printf '%s\n' '' \
    "Policy decrypted : ${policy_name}" \
    "Files unlocked   : ${unlocked}" \
    "Files decrypted  : ${decrypted}" >> "${target}"
  if (( unlocked != 0 || decrypted != 0 )); then
    printf '%s\n' '' \
      'Policy files are now unprotected' \
      "Use 'ADVANCED >> ASSET >> ENCRYPT / LOCK POLICY' to re-lock" \
      >> "${target}"
  fi
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
    terminal:clear menu:asset:d action:compatibility-dispatch terminal:clear \
    >> "${target}"
  [[ "${scenario}" == empty ]] ||
    printf '%s\n' action:selectPolicy:encrypted >> "${target}"
  case "${scenario}" in
    password-abort|one-success|multiple-success|gpg-failure|multiple-partial|\
      chmod-decrypted-failure)
      printf '%s\n' action:password >> "${target}"
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

append_chmod_vector() {
  printf 'chmod\t0600\t%s\n' "$1" >> "$2"
}

append_gpg_vector() {
  local input="$1" target="$2"
  printf 'chmod\t0600\t%s\n' \
    '<runtime>/asset/.alpha.cntools-decrypt.lock/plain.<temp>' >> "${target}"
  printf 'gpg\t--decrypt\t--batch\t--yes\t--no-tty\t--pinentry-mode\tloopback\t--passphrase-fd\t0\t--output\t%s\t--\t%s\n' \
    '<runtime>/asset/.alpha.cntools-decrypt.lock/plain.<temp>' \
    "${input}" >> "${target}"
}

write_expected_vectors() {
  local scenario="$1" target="$2" initial_files="$3"
  local path="" basename=""

  : > "${target}"
  case "${scenario}" in
    empty|selection-fail|selection-cancel|password-abort|file-symlink|\
      hardlink-outside|output-symlink|traversal-outside) return ;;
  esac
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if [[ "$(scenario_chattr "${scenario}")" == true ]]; then
      printf 'lsattr\t-d\t--\t%s\n' "${path}" >> "${target}"
      case "${scenario}" in
        already-immutable)
          printf 'sudo\t<test>/fake-bin/chattr\t-i\t--\t%s\n' "${path}" >> "${target}"
          printf 'chattr\t-i\t--\t%s\n' "${path}" >> "${target}"
          printf 'lsattr\t-d\t--\t%s\n' "${path}" >> "${target}"
          ;;
        chattr-failure)
          printf 'sudo\t<test>/fake-bin/chattr\t-i\t--\t%s\n' "${path}" >> "${target}"
          printf 'chattr\t-i\t--\t%s\n' "${path}" >> "${target}"
          printf 'sudo\t<test>/fake-bin/chattr\t+i\t--\t%s\n' "${path}" >> "${target}"
          printf 'chattr\t+i\t--\t%s\n' "${path}" >> "${target}"
          printf 'lsattr\t-d\t--\t%s\n' "${path}" >> "${target}"
          ;;
      esac
    fi
    [[ "${path}" != *.gpg && "${scenario}" != chattr-failure &&
       "${scenario}" != lsattr-failure ]] &&
      append_chmod_vector "${path}" "${target}"
  done < "${initial_files}"
  while IFS= read -r path; do
    [[ "${path}" == *.gpg ]] || continue
    append_gpg_vector "${path}" "${target}"
  done < "${initial_files}"
  case "${scenario}" in
    gpg-failure|multiple-partial) ;;
    *)
      while IFS= read -r path; do
        [[ "${path}" == *.gpg ]] || continue
        append_chmod_vector "${path}" "${target}"
      done < "${initial_files}"
      ;;
  esac
  case "${scenario}" in
    chmod-unlock-failure)
      printf 'chmod\t400\t%s\n' '<runtime>/asset/alpha/plain.vkey' >> "${target}"
      ;;
    chmod-decrypted-failure)
      printf 'chmod\t400\t%s\n' '<runtime>/asset/alpha/policy.skey.gpg' >> "${target}"
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
  local root="${runtime_root}/asset/alpha"
  local before_filtered="${before}.filtered" after_filtered="${after}.filtered"
  local allow_pattern='^(d|f|l)[[:space:]]+asset/alpha([[:space:]]|/)'

  case "${scenario}" in
    traversal-outside)
      root="${runtime_root}/outside-policy"
      allow_pattern='^(d|f|l)[[:space:]]+outside-policy([[:space:]]|/)'
      ;;
    hardlink-outside) allow_pattern='^(d|f|l)[[:space:]]+(asset/alpha([[:space:]]|/)|outside\.vkey[[:space:]])' ;;
    output-symlink) allow_pattern='^(d|f|l)[[:space:]]+(asset/alpha([[:space:]]|/)|outside\.skey[[:space:]])' ;;
  esac
  case "${scenario}" in
    unlock-only|chattr-nonimmutable|already-immutable|chattr-failure|\
      lsattr-failure|traversal-outside)
      [[ -f "${root}/plain.vkey" &&
         "$(file_mode "${root}/plain.vkey")" == 600 ]] ||
        fail "${scenario} unlocked-file state changed"
      ;;
    chmod-unlock-failure)
      [[ -f "${root}/plain.vkey" &&
         "$(file_mode "${root}/plain.vkey")" == 400 ]] ||
        fail 'unlock chmod failure residue changed'
      ;;
    password-abort)
      [[ -f "${root}/policy.skey.gpg" &&
         "$(file_mode "${root}/policy.skey.gpg")" == 400 ]] ||
        fail 'password-abort rollback state changed'
      ;;
    one-success)
      [[ ! -e "${root}/policy.skey.gpg" &&
         -f "${root}/policy.skey" &&
         "$(file_mode "${root}/policy.skey")" == 600 &&
         "$(< "${root}/policy.skey")" == 'decrypted fixture' ]] ||
        fail 'single successful decrypt state changed'
      ;;
    multiple-success)
      for path in a b; do
        [[ ! -e "${root}/${path}.skey.gpg" &&
           -f "${root}/${path}.skey" &&
           "$(file_mode "${root}/${path}.skey")" == 600 &&
           "$(< "${root}/${path}.skey")" == 'decrypted fixture' ]] ||
          fail 'multiple successful decrypt state changed'
      done
      ;;
    gpg-failure)
      [[ -f "${root}/policy.skey.gpg" &&
         "$(file_mode "${root}/policy.skey.gpg")" == 400 &&
         ! -e "${root}/policy.skey" ]] ||
        fail 'GPG failure rollback state changed'
      ;;
    multiple-partial)
      [[ -f "${root}/a-ok.skey.gpg" &&
         ! -e "${root}/a-ok.skey" &&
         -f "${root}/b-fail.skey.gpg" &&
         ! -e "${root}/b-fail.skey" ]] ||
        fail 'multiple decrypt rollback state changed'
      ;;
    chmod-decrypted-failure)
      [[ ! -e "${root}/policy.skey.gpg" &&
         -f "${root}/policy.skey" &&
         "$(file_mode "${root}/policy.skey")" == 644 &&
         "$(< "${root}/policy.skey")" == 'decrypted fixture' ]] ||
        fail 'post-decrypt chmod failure residue changed'
      ;;
    hardlink-outside)
      [[ -f "${root}/plain.vkey" &&
         -f "${runtime_root}/outside.vkey" &&
         "$(file_mode "${root}/plain.vkey")" == 600 &&
         "$(file_mode "${runtime_root}/outside.vkey")" == 600 ]] ||
        fail 'hardlink outside-mode propagation changed'
      ;;
    output-symlink)
      [[ ! -e "${root}/policy.skey.gpg" &&
         -L "${root}/policy.skey" &&
         -f "${runtime_root}/outside.skey" &&
         "$(file_mode "${runtime_root}/outside.skey")" == 600 &&
         "$(< "${runtime_root}/outside.skey")" == 'decrypted fixture' ]] ||
        fail 'decrypt output symlink escape changed'
      ;;
    *) fail "unknown mutation scenario: ${scenario}" ;;
  esac
  grep -Ev "${allow_pattern}" "${before}" > "${before_filtered}"
  grep -Ev "${allow_pattern}" "${after}" > "${after_filtered}"
  assert_files_equal "${after_filtered}" "${before_filtered}" \
    "${scenario} mutation outside its frozen legacy allowlist"
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
  local initial_files_raw="${capture_root}/initial-files.raw"
  local initial_files="${capture_root}/initial-files"
  local selected_policy_root="${asset_root}/alpha"
  local status=0

  mode="$(scenario_mode "${scenario}")"
  enable_chattr="$(scenario_chattr "${scenario}")"
  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/wallet" \
    "${runtime_root}/pool" "${runtime_root}/home" "${asset_root}" \
    "${capture_root}"
  prepare_scenario "${scenario}" "${runtime_root}" "${asset_root}"
  [[ "${scenario}" == traversal-outside ]] &&
    selected_policy_root="${asset_root}/../outside-policy"
  : > "${initial_files_raw}"
  if [[ -d "${selected_policy_root}" ]]; then
    find "${selected_policy_root}" -mindepth 1 -maxdepth 1 -type f -print \
      | LC_ALL=C sort > "${initial_files_raw}"
  fi
  normalize_file "${initial_files_raw}" "${initial_files}" "${runtime_root}"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "${scenario} pre-snapshot failed"
  : > "${event_raw}"; : > "${vector_raw}"; : > "${network_log}"
  : > "${immutable_state}"
  case "${scenario}" in
    already-immutable|chattr-failure)
      printf '%s\n' "${asset_root}/alpha/plain.vkey" > "${immutable_state}"
      ;;
  esac

  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    export CNTOOLS_ASSET_DECRYPT_SCENARIO="${scenario}"
    export CNTOOLS_ASSET_DECRYPT_VECTOR_LOG="${vector_raw}"
    export CNTOOLS_ASSET_DECRYPT_NETWORK_LOG="${network_log}"
    export CNTOOLS_ASSET_DECRYPT_EXPECTED_PASSWORD="${FIXTURE_PASSWORD}"
    export CNTOOLS_ASSET_DECRYPT_FAULT_MARKER="${capture_root}/fault"
    export CNTOOLS_ASSET_DECRYPT_IMMUTABLE_STATE="${immutable_state}"
    export CNTOOLS_ASSET_DECRYPT_REAL_CHMOD="${REAL_CHMOD}"
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
    CHOICES=(a a d h q)
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
  write_expected_stdout "${scenario}" "${expected_stdout}" "${initial_files}"
  : > "${expected_stderr}"
  write_expected_events "${scenario}" "${mode}" "${expected_events}"
  write_expected_vectors "${scenario}" "${expected_vectors}" "${initial_files}"
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
    unlock-only|one-success|multiple-success|chattr-nonimmutable|already-immutable)
      assert_policy_mutation "${scenario}" "${runtime_root}" \
        "${before_snapshot}" "${after_snapshot}"
      ;;
    *) assert_zero_mutation "${scenario}" "${before_snapshot}" "${after_snapshot}" ;;
  esac
}

write_fake_commands

run_case empty
run_case selection-fail
run_case selection-cancel
run_case unlock-only
run_case password-abort
run_case one-success
run_case multiple-success
run_case gpg-failure
run_case multiple-partial
run_case chattr-nonimmutable
run_case already-immutable
run_case chattr-failure
run_case lsattr-failure
run_case chmod-unlock-failure
run_case chmod-decrypted-failure
run_case file-symlink
run_case hardlink-outside
run_case output-symlink
run_case traversal-outside

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
    'scenario="${CNTOOLS_ASSET_DECRYPT_SCENARIO:?}" input="${*: -1}" output="" previous="" secret=""' \
    'printf '\''gpg'\'' >> "${CNTOOLS_ASSET_DECRYPT_DIRECT_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_DECRYPT_DIRECT_VECTOR_LOG:?}"; [[ "${previous}" == --output ]] && output="${argument}"; previous="${argument}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_ASSET_DECRYPT_DIRECT_VECTOR_LOG:?}"' \
    'IFS= read -r secret || true' \
    '[[ "${secret}" == "${CNTOOLS_ASSET_DECRYPT_EXPECTED_PASSWORD:?}" ]] || exit 98' \
    '[[ "$*" == "--decrypt --batch --yes --no-tty --pinentry-mode loopback --passphrase-fd 0 --output "*" -- "* ]] || exit 96' \
    '[[ "${scenario}" != direct-gpg-failure ]] || exit 41' \
    'printf '\''decrypted fixture\n'\'' > "${output}"' \
    'if [[ "${scenario}" == direct-inventory-race ]]; then printf '\''race\n'\'' > "${input%/*}/injected.race"; fi' \
    > "${DIRECT_FAKE_BIN}/gpg"
  chmod 0755 "${DIRECT_FAKE_BIN}/gpg"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_DECRYPT_SCENARIO:?}" target="${*: -1}" mode="${1:-}"' \
    'if [[ "${scenario}" == direct-chmod-failure && "${mode}" =~ ^0?600$ && "${target}" == */policy.vkey && ! -e "${CNTOOLS_ASSET_DECRYPT_FAULT_MARKER:?}.chmod" ]]; then : > "${CNTOOLS_ASSET_DECRYPT_FAULT_MARKER}.chmod"; exit 42; fi' \
    'exec "${CNTOOLS_ASSET_DECRYPT_REAL_CHMOD:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/chmod"
  chmod 0755 "${DIRECT_FAKE_BIN}/chmod"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_DECRYPT_SCENARIO:?}" target="${*: -1}"' \
    'if [[ "${scenario}" == direct-postcommit-signal-backup && "${target}" == */cipher.0.backup && ! -e "${CNTOOLS_ASSET_DECRYPT_FAULT_MARKER:?}.signal-backup" ]]; then : > "${CNTOOLS_ASSET_DECRYPT_FAULT_MARKER}.signal-backup"; kill -TERM "${PPID}"; exit 45; fi' \
    'if [[ "${scenario}" == direct-postcommit-cleanup-warning && "${target}" == */cipher.0.backup ]]; then exit 43; fi' \
    'exec "${CNTOOLS_ASSET_DECRYPT_REAL_RM:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/rm"
  chmod 0755 "${DIRECT_FAKE_BIN}/rm"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_DECRYPT_SCENARIO:?}" target="${*: -1}"' \
    'if [[ "${scenario}" == direct-postcommit-signal-lock && "${target}" == */.alpha.cntools-decrypt.lock && ! -e "${CNTOOLS_ASSET_DECRYPT_FAULT_MARKER:?}.signal-lock" ]]; then : > "${CNTOOLS_ASSET_DECRYPT_FAULT_MARKER}.signal-lock"; kill -TERM "${PPID}"; exit 45; fi' \
    'if [[ "${scenario}" == direct-postcommit-cleanup-warning && "${target}" == */.alpha.cntools-decrypt.lock ]]; then exit 44; fi' \
    'exec "${CNTOOLS_ASSET_DECRYPT_REAL_RMDIR:?}" "$@"' \
    > "${DIRECT_FAKE_BIN}/rmdir"
  chmod 0755 "${DIRECT_FAKE_BIN}/rmdir"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'target="${*: -1}" state="${CNTOOLS_ASSET_DECRYPT_IMMUTABLE_STATE:?}"' \
    'if /usr/bin/grep -Fqx -- "${target}" "${state}" 2>/dev/null; then flags=----i---------; else flags=--------------; fi' \
    'printf '\''%s %s\n'\'' "${flags}" "${target}"' \
    > "${DIRECT_FAKE_BIN}/lsattr"
  chmod 0755 "${DIRECT_FAKE_BIN}/lsattr"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_DECRYPT_SCENARIO:?}" operation="${1:-}" target="${*: -1}" state="${CNTOOLS_ASSET_DECRYPT_IMMUTABLE_STATE:?}" temporary="${state}.new"' \
    'if [[ "${operation}" == -i && "${scenario}" == direct-chattr-failure && "${target}" == */policy.vkey ]]; then exit 45; fi' \
    'case "${operation}" in' \
    '  -i) /usr/bin/awk -v target="${target}" '\''$0 != target { print }'\'' "${state}" > "${temporary}"; /bin/mv -f -- "${temporary}" "${state}" ;;' \
    '  +i) /usr/bin/grep -Fqx -- "${target}" "${state}" 2>/dev/null || printf '\''%s\n'\'' "${target}" >> "${state}" ;;' \
    '  *) exit 96 ;;' \
    'esac' \
    > "${DIRECT_FAKE_BIN}/chattr"
  chmod 0755 "${DIRECT_FAKE_BIN}/chattr"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exec "$@"' \
    > "${DIRECT_FAKE_BIN}/sudo"
  chmod 0755 "${DIRECT_FAKE_BIN}/sudo"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''network\n'\'' >> "${CNTOOLS_ASSET_DECRYPT_NETWORK_LOG:?}"' \
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
    printf 'encrypted fixture\n' > "${runtime_root}/outside-policy/policy.skey.gpg"
    chmod 0400 "${runtime_root}/outside-policy/policy.skey.gpg"
    ln -s -- "${runtime_root}/outside-policy" "${policy_root}"
    return 0
  fi
  mkdir -p -- "${policy_root}"
  chmod 0755 "${policy_root}"
  printf 'encrypted fixture\n' > "${policy_root}/policy.skey.gpg"
  printf 'verification fixture\n' > "${policy_root}/policy.vkey"
  chmod 0400 "${policy_root}/policy.skey.gpg" "${policy_root}/policy.vkey"
  case "${scenario}" in
    direct-unlock-only)
      rm -f -- "${policy_root}/policy.skey.gpg"
      ;;
    direct-plaintext-conflict)
      printf 'existing plaintext\n' > "${policy_root}/policy.skey"
      chmod 0600 "${policy_root}/policy.skey"
      ;;
    direct-hardlink)
      ln -- "${policy_root}/policy.vkey" "${runtime_root}/outside.link"
      ;;
    direct-symlink)
      rm -f -- "${policy_root}/policy.vkey"
      printf 'outside\n' > "${runtime_root}/outside.vkey"
      ln -s -- "${runtime_root}/outside.vkey" "${policy_root}/policy.vkey"
      ;;
    direct-lock-contention)
      mkdir -- "${asset_root}/.alpha.cntools-decrypt.lock"
      chmod 0700 "${asset_root}/.alpha.cntools-decrypt.lock"
      ;;
    direct-invalid-name) ;;
    direct-root-mode) chmod 0777 "${asset_root}" ;;
    direct-file-mode) chmod 0666 "${policy_root}/policy.vkey" ;;
  esac
}

direct_expected_status() {
  case "$1" in
    direct-root-mode|direct-inventory-race) printf '70\n' ;;
    *) printf '0\n' ;;
  esac
}

direct_expected_waits() {
  case "$1" in
    direct-selection-cancel|direct-root-mode|direct-inventory-race|\
      direct-postcommit-signal-backup|direct-postcommit-signal-lock)
      printf '0\n'
      ;;
    *) printf '1\n' ;;
  esac
}

run_direct_case() {
  local scenario="$1" mode="$2" chattr_enabled="${3:-false}"
  local case_root="${TEST_ROOT}/direct-cases/${scenario}"
  local runtime_root="${case_root}/runtime" asset_root=""
  local capture_root="${case_root}/capture" private_root=""
  local context_file="" result_file="" stdout_file="" stderr_file=""
  local event_log="" vector_log="" network_log="" immutable_state=""
  local before_snapshot="" after_snapshot="" expected_status=""
  local expected_waits="" wait_count=0 status=0

  asset_root="${runtime_root}/asset"
  capture_root="${case_root}/capture"
  private_root="${runtime_root}/tmp/private"
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  stdout_file="${capture_root}/stdout"
  stderr_file="${capture_root}/stderr"
  event_log="${capture_root}/events"
  vector_log="${capture_root}/vectors"
  network_log="${capture_root}/network"
  immutable_state="${capture_root}/immutable"
  before_snapshot="${capture_root}/before.tree"
  after_snapshot="${capture_root}/after.tree"
  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/home" \
    "${runtime_root}/wallet" "${runtime_root}/pool" "${asset_root}" \
    "${capture_root}"
  prepare_direct_scenario "${scenario}" "${runtime_root}" "${asset_root}"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "${scenario} direct pre-snapshot failed"
  : > "${event_log}"; : > "${vector_log}"; : > "${network_log}"
  : > "${immutable_state}"
  if [[ "${chattr_enabled}" == true ]]; then
    printf '%s\n' "${asset_root}/alpha/policy.skey.gpg" \
      "${asset_root}/alpha/policy.vkey" > "${immutable_state}"
  fi
  expected_status="$(direct_expected_status "${scenario}")"
  expected_waits="$(direct_expected_waits "${scenario}")"

  if (
    set +e; set +u; set +o pipefail; umask 022
    export LC_ALL=C TZ=UTC
    export CNTOOLS_ASSET_DECRYPT_SCENARIO="${scenario}"
    export CNTOOLS_ASSET_DECRYPT_DIRECT_VECTOR_LOG="${vector_log}"
    export CNTOOLS_ASSET_DECRYPT_NETWORK_LOG="${network_log}"
    export CNTOOLS_ASSET_DECRYPT_EXPECTED_PASSWORD="${FIXTURE_PASSWORD}"
    export CNTOOLS_ASSET_DECRYPT_FAULT_MARKER="${capture_root}/fault"
    export CNTOOLS_ASSET_DECRYPT_IMMUTABLE_STATE="${immutable_state}"
    export CNTOOLS_ASSET_DECRYPT_REAL_CHMOD="${REAL_CHMOD}"
    export CNTOOLS_ASSET_DECRYPT_REAL_RM="${REAL_RM}"
    export CNTOOLS_ASSET_DECRYPT_REAL_RMDIR="${REAL_RMDIR}"
    PATH="${DIRECT_FAKE_BIN}:${BASE_PATH}"; export PATH
    HOME="${runtime_root}/home"; NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"; WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"; ASSET_FOLDER="${asset_root}"
    ASSET_POLICY_SK_FILENAME=policy.skey
    ENABLE_CHATTR="${chattr_enabled}"; CNTOOLS_MODE="${mode}"
    FG_RED="" FG_GREEN="" FG_YELLOW="" FG_LBLUE="" NC=""
    EVENT_LOG="${event_log}"; CAPTURE_ACTIVE=N; END_ON_CLEAR=N
    DIRECT_ACTIVE=Y
    unset password policy_name decrypt_policy_secret
    mkdir -p -- "${private_root}"; chmod 0700 "${private_root}"
    write_direct_context "${context_file}" "${mode}" "${runtime_root}/home"
    if [[ "${scenario}" == direct-selection-fail ]]; then
      CNTOOLS_ASSET_DECRYPT_SCENARIO=selection-fail
    elif [[ "${scenario}" == direct-selection-cancel ]]; then
      CNTOOLS_ASSET_DECRYPT_SCENARIO=selection-cancel
    elif [[ "${scenario}" == direct-password-abort ]]; then
      CNTOOLS_ASSET_DECRYPT_SCENARIO='password-abort'
    elif [[ "${scenario}" == direct-invalid-name ]]; then
      CNTOOLS_ASSET_DECRYPT_SCENARIO=traversal-outside
    fi
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"
    direct_status=$?
    [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || exit 98
    rm -f -- "${context_file}"; rmdir -- "${private_root}"
    exit "${direct_status}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  [[ "${status}" == "${expected_status}" ]] ||
    fail "${scenario} direct status ${status}, expected ${expected_status}"
  wait_count="$(grep -c '^action:waitToProceed$' "${event_log}" || true)"
  [[ "${wait_count}" == "${expected_waits}" ]] ||
    fail "${scenario} wait count ${wait_count}, expected ${expected_waits}"
  ! grep -Fq 'action:secret:present' "${event_log}" ||
    fail "${scenario} retained password at wait"
  ! grep -Fq 'action:lock:present' "${event_log}" ||
    [[ "${scenario}" == direct-postcommit-cleanup-warning ||
       "${scenario}" == direct-lock-contention ]] ||
    fail "${scenario} waited while holding operation lock"
  [[ ! -s "${network_log}" ]] || fail "${scenario} attempted network access"
  for checked_file in "${stdout_file}" "${stderr_file}" "${event_log}" \
      "${vector_log}" "${network_log}"; do
    ! grep -Fq -- "${FIXTURE_PASSWORD}" "${checked_file}" ||
      fail "${scenario} exposed password"
  done
  if [[ "${expected_status}" == 70 ]]; then
    grep -Fxq 'CNTools asset decrypt-policy action failed validation.' \
      "${stderr_file}" || fail "${scenario} status-70 diagnostic changed"
  elif [[ "${scenario}" == direct-postcommit-signal-backup ||
          "${scenario}" == direct-postcommit-signal-lock ]]; then
    grep -Fxq 'CNTools asset decrypt-policy action committed; interrupted during post-commit cleanup.' \
      "${stderr_file}" || fail "${scenario} committed-signal diagnostic changed"
  else
    [[ ! -s "${stderr_file}" ]] || fail "${scenario} unexpected stderr"
  fi
  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "${scenario} direct post-snapshot failed"
  case "${scenario}" in
    direct-success-*|direct-postcommit-cleanup-warning|\
      direct-postcommit-signal-backup|direct-postcommit-signal-lock|\
      direct-unlock-only)
      [[ -f "${asset_root}/alpha/policy.vkey" &&
         "$(file_mode "${asset_root}/alpha/policy.vkey")" == 600 ]] ||
        fail "${scenario} hardened unlocked-file state changed"
      if [[ "${scenario}" != direct-unlock-only ]]; then
        [[ ! -e "${asset_root}/alpha/policy.skey.gpg" &&
           -f "${asset_root}/alpha/policy.skey" &&
           "$(file_mode "${asset_root}/alpha/policy.skey")" == 600 &&
           "$(< "${asset_root}/alpha/policy.skey")" == 'decrypted fixture' ]] ||
          fail "${scenario} hardened success state changed"
      fi
      ;;
    *)
      if [[ "${scenario}" == direct-inventory-race ]]; then
        sed '/asset\/alpha\/injected\.race/d' "${after_snapshot}" \
          > "${after_snapshot}.filtered"
        assert_files_equal "${after_snapshot}.filtered" "${before_snapshot}" \
          "${scenario} action-owned rollback state"
      else
        assert_files_equal "${after_snapshot}" "${before_snapshot}" \
          "${scenario} hardened rollback state"
      fi
      ;;
  esac
  if [[ "${scenario}" == direct-postcommit-cleanup-warning ]]; then
    grep -Fq 'policy decryption committed, but private cleanup was incomplete' \
      "${stdout_file}" || fail 'postcommit cleanup warning changed'
    [[ -d "${asset_root}/.alpha.cntools-decrypt.lock" ]] ||
      fail 'postcommit warning did not retain operation lock'
  else
    [[ ! -e "${asset_root}/.alpha.cntools-decrypt.lock" ||
       "${scenario}" == direct-lock-contention ]] ||
      fail "${scenario} retained operation lock"
  fi
}

write_direct_fake_commands
run_direct_case direct-empty OFFLINE
run_direct_case direct-selection-fail LIGHT
run_direct_case direct-selection-cancel LOCAL
run_direct_case direct-password-abort LIGHT
run_direct_case direct-success-local LOCAL
run_direct_case direct-success-light LIGHT
run_direct_case direct-success-offline OFFLINE
run_direct_case direct-success-chattr OFFLINE true
run_direct_case direct-unlock-only OFFLINE
run_direct_case direct-gpg-failure OFFLINE
run_direct_case direct-plaintext-conflict OFFLINE
run_direct_case direct-symlink OFFLINE
run_direct_case direct-hardlink OFFLINE
run_direct_case direct-policy-symlink OFFLINE
run_direct_case direct-invalid-name OFFLINE
run_direct_case direct-root-mode OFFLINE
run_direct_case direct-file-mode OFFLINE
run_direct_case direct-lock-contention OFFLINE
run_direct_case direct-chmod-failure OFFLINE
run_direct_case direct-chattr-failure OFFLINE true
run_direct_case direct-inventory-race OFFLINE
run_direct_case direct-postcommit-signal-backup OFFLINE
run_direct_case direct-postcommit-signal-lock OFFLINE
run_direct_case direct-postcommit-cleanup-warning OFFLINE

# Freeze the exact one-call public route and removal of the unsafe inline body.
decrypt_policy_arm="${TEST_ROOT}/decrypt-policy-arm"
expected_decrypt_policy_arm="${TEST_ROOT}/expected-decrypt-policy-arm"
awk '
  /^[[:space:]]+decrypt-policy\)/ { capture = 1 }
  capture { print }
  capture && /^[[:space:]]+;;/ { exit }
' "${CNTOOLS_SCRIPT}" > "${decrypt_policy_arm}"
printf '%s\n' \
  '                  decrypt-policy)' \
  '                    cntools_compatibility_dispatch_action advanced.asset.decrypt-policy' \
  '                    action_status=$?' \
  '                    case "${action_status}" in' \
  '                      0) continue ;;' \
  '                      20|21) break 2 ;;' \
  '                      22) myExit 0 "CNTools closed!" ;;' \
  '                      *) waitToProceed; continue ;;' \
  '                    esac' \
  '                    ;; ###################################################################' \
  > "${expected_decrypt_policy_arm}"
assert_files_equal "${decrypt_policy_arm}" "${expected_decrypt_policy_arm}" \
  'exact public decrypt-policy dispatch arm'
[[ "$(grep -c 'cntools_compatibility_dispatch_action advanced.asset.decrypt-policy' \
      "${decrypt_policy_arm}" || true)" == 1 ]] ||
  fail 'public decrypt-policy arm does not contain exactly one dispatch call'
if grep -Eq 'decryptFile|filesUnlocked|keysDecrypted|chmod 600|sudo chattr|selectPolicy' \
    "${decrypt_policy_arm}"; then
  fail 'former inline decrypt-policy implementation remains in the public arm'
fi
grep -Fq 'echo "${2}" | gpg --decrypt --batch --yes --passphrase-fd 0' \
  "${LEGACY_SELECTION_SOURCE}" ||
  fail 'legacy decrypt helper defect evidence changed'
grep -Fq 'rm -f "${1}" || {' "${LEGACY_SELECTION_SOURCE}" ||
  fail 'legacy decrypt helper removal evidence changed'
grep -Fq 'cntools_action_main() {' "${ACTION_SOURCE}" ||
  fail 'decrypt-policy modular entrypoint is missing'
grep -Fq '_cntools_action_advanced_asset_decrypt_policy_rollback() {' \
  "${ACTION_SOURCE}" || fail 'decrypt-policy rollback boundary is missing'
grep -Fq '.cntools-decrypt.lock' "${ACTION_SOURCE}" ||
  fail 'decrypt-policy operation lock is missing'
grep -Fq 'policy decryption committed, but private cleanup was incomplete' \
  "${ACTION_SOURCE}" || fail 'decrypt-policy postcommit warning is missing'
grep -Fq 'CNTools actions are launched by the dispatcher, not directly.' \
  "${ACTION_SOURCE}" || fail 'decrypt-policy direct-execution guard changed'

printf 'CNTools asset-decrypt-policy characterization/parity passed (19 public + 24 direct cases)\n'
