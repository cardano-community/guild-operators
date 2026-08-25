#!/usr/bin/env bash
# Freeze the legacy advanced.asset.create-policy contract and verify the one-call
# public route plus the hardened extracted action. Conditional legacy oracles
# below retain the intentionally changed defect contract for review.
# shellcheck disable=SC1090,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools asset-create-policy characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/advanced/asset/create-policy/action.sh"
ACTION_DIRECTORY="${ACTION_SOURCE%/*}"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-asset-create.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
REAL_MV_PATH="$(command -v mv)"
REAL_RMDIR_PATH="$(command -v rmdir)"
REAL_MKDIR_PATH="$(command -v mkdir)"
POLICY_KEY_HASH=11111111111111111111111111111111111111111111111111111111
POLICY_ID=22222222222222222222222222222222222222222222222222222222

cleanup_test() {
  if [[ "${CNTOOLS_ASSET_CREATE_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools asset-create-policy test root preserved: %s\n' \
      "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools asset-create-policy characterization failed: %s\n' \
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
  local network_command=""

  mkdir -p -- "${FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_CREATE_SCENARIO:?}"' \
    'vector_log="${CNTOOLS_ASSET_CREATE_VECTOR_LOG:?}"' \
    'security_log="${CNTOOLS_ASSET_CREATE_SECURITY_LOG:-/dev/null}"' \
    'file_mode() {' \
    '  local target="$1" mode=""' \
    '  if mode="$(stat -f %Lp "${target}" 2>/dev/null)"; then :' \
    '  else mode="$(stat -c %a -- "${target}" 2>/dev/null)" || return 1; fi' \
    '  printf '''%s''' "${mode#0}"' \
    '}' \
    'printf '\''cardano-cli'\'' >> "${vector_log}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${vector_log}"; done' \
    'printf '\''\n'\'' >> "${vector_log}"' \
    'case "$*" in' \
    '  "address key-gen --verification-key-file "*)' \
    '    verification=""; signing=""' \
    '    while (( $# > 0 )); do' \
    '      case "$1" in' \
    '        --verification-key-file) verification="$2"; shift 2 ;;' \
    '        --signing-key-file) signing="$2"; shift 2 ;;' \
    '        *) shift ;;' \
    '      esac' \
    '    done' \
    '    printf '\''%s\n'\'' '\''{"cborHex":"0000000000000000000000000000000000000000000000000000000000000000","description":"Payment Verification Key","type":"PaymentVerificationKeyShelley_ed25519"}'\'' > "${verification}"' \
    '    printf '\''%s\n'\'' '\''{"cborHex":"1111111111111111111111111111111111111111111111111111111111111111","description":"Payment Signing Key","type":"PaymentSigningKeyShelley_ed25519"}'\'' > "${signing}"' \
    '    if [[ "${scenario}" == direct-malformed-vkey ]]; then printf '\''%s\n'\'' '\''{"type":"wrong"}'\'' > "${verification}"; fi' \
    '    if [[ "${scenario}" == direct-signal-keygen ]]; then kill -TERM "${PPID}"; sleep 1; fi' \
    '    if [[ "${scenario}" == direct-* ]]; then' \
    '      printf '\''keygen\t%s\t%s\t%s\n'\'' "$(file_mode "${verification%/*}")" "$(file_mode "${verification}")" "$(file_mode "${signing}")" >> "${security_log}"' \
    '    fi' \
    '    if [[ "${scenario}" == keygen-failure || "${scenario}" == direct-keygen-failure || "${scenario}" == direct-escaped-diagnostic ]]; then' \
    '      if [[ "${scenario}" == direct-escaped-diagnostic ]]; then printf '\''\\033[31mOWNED\n'\'' >&2; printf '\''%s\n'\'' '\''\033[31mOWNED'\'' >&2; fi' \
    '      printf '\''fixture key-gen failure\n'\'' >&2; exit 42' \
    '    fi' \
    '    ;;' \
    '  "address key-hash --payment-verification-key-file "*)' \
    '    key_file="${@: -1}"' \
    '    if [[ "${scenario}" == direct-* ]]; then printf '\''keyhash\t%s\t%s\n'\'' "$(file_mode "${key_file%/*}")" "$(file_mode "${key_file}")" >> "${security_log}"; fi' \
    '    if [[ "${scenario}" == keyhash-failure || "${scenario}" == direct-keyhash-failure ]]; then' \
    '      printf '\''fixture key-hash failure\n'\'' >&2; exit 43' \
    '    fi' \
    '    if [[ "${scenario}" == direct-malformed-keyhash ]]; then printf '\''%s\n'\'' BAD; exit 0; fi' \
    '    printf '\''%s\n'\'' "${CNTOOLS_ASSET_CREATE_KEY_HASH:?}"' \
    '    ;;' \
    '  "hash script --script-file "*)' \
    '    output=""' \
    '    while (( $# > 0 )); do' \
    '      if [[ "$1" == --out-file ]]; then output="$2"; shift 2; else shift; fi' \
    '    done' \
    '    printf '\''partial-policy-id\n'\'' > "${output}"' \
    '    if [[ "${scenario}" == direct-* ]]; then printf '\''scripthash\t%s\t%s\n'\'' "$(file_mode "${output%/*}")" "$(file_mode "${output}")" >> "${security_log}"; fi' \
    '    if [[ "${scenario}" == script-hash-failure || "${scenario}" == direct-scripthash-failure ]]; then' \
    '      printf '\''fixture script-hash failure\n'\'' >&2; exit 44' \
    '    fi' \
    '    if [[ "${scenario}" == direct-malformed-policy-id ]]; then printf '\''%s\n'\'' BAD > "${output}"' \
    '    else printf '\''%s\n'\'' "${CNTOOLS_ASSET_CREATE_POLICY_ID:?}" > "${output}"; fi' \
    '    ;;' \
    '  *) printf '\''unexpected cardano-cli argv: %s\n'\'' "$*" >&2; exit 96 ;;' \
    'esac' \
    > "${FAKE_BIN}/cardano-cli"
  chmod 0755 "${FAKE_BIN}/cardano-cli"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_CREATE_SCENARIO:?}"' \
    'printf '\''mv'\'' >> "${CNTOOLS_ASSET_CREATE_PUBLISH_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_CREATE_PUBLISH_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_ASSET_CREATE_PUBLISH_LOG:?}"' \
    'if [[ "${scenario}" == direct-mv-failure ]]; then exit 45; fi' \
    'if [[ "${scenario}" == direct-publish-collision ]]; then' \
    '  destination="${@: -1}"' \
    '  "${CNTOOLS_ASSET_CREATE_REAL_MKDIR:?}" -m 0700 -- "${destination}" || exit 46' \
    '  printf '\''competitor\n'\'' > "${destination}/competitor.txt"' \
    '  exec "${CNTOOLS_ASSET_CREATE_REAL_MV:?}" "$@"' \
    'fi' \
    'exec "${CNTOOLS_ASSET_CREATE_REAL_MV:?}" "$@"' \
    > "${FAKE_BIN}/mv"
  chmod 0755 "${FAKE_BIN}/mv"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_CREATE_SCENARIO:?}"' \
    'if [[ "${scenario}" == direct-release-failure && "${*: -1}" == *.create.lock && ! -e "${CNTOOLS_ASSET_CREATE_RMDIR_STATE:?}" ]]; then' \
    '  : > "${CNTOOLS_ASSET_CREATE_RMDIR_STATE}"' \
    '  exit 45' \
    'fi' \
    'exec "${CNTOOLS_ASSET_CREATE_REAL_RMDIR:?}" "$@"' \
    > "${FAKE_BIN}/rmdir"
  chmod 0755 "${FAKE_BIN}/rmdir"

  for network_command in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_ASSET_CREATE_NETWORK_LOG:?}"' \
      'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_CREATE_NETWORK_LOG:?}"; done' \
      'printf '\''\n'\'' >> "${CNTOOLS_ASSET_CREATE_NETWORK_LOG:?}"' \
      'exit 97' \
      > "${FAKE_BIN}/${network_command}"
    chmod 0755 "${FAKE_BIN}/${network_command}"
  done
}

# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/registry.sh
. "${REGISTRY_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/context.sh
. "${CONTEXT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/result.sh
. "${RESULT_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/core/dispatcher.sh
. "${DISPATCHER_SOURCE}"
# shellcheck source=../../scripts/common-helper-scripts/cntools/modules/root/advanced/asset/create-policy/action.sh
. "${ACTION_SOURCE}"

# Public cases traverse the exact one-call controller route. This test-only
# adapter supplies a private context/result channel and invokes the shipped
# action through the production dispatcher without installed authority.
cntools_compatibility_dispatch_action() {
  local action_id="${1:-}" private_root="" context_file=""
  local result_file="" action_status=0 tmp_mode=""

  [[ "${action_id}" == advanced.asset.create-policy && $# == 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  tmp_mode="$(file_mode "${TMP_DIR}")" || return 70
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/asset-create-test-dispatch.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  chmod 0700 "${TMP_DIR}" "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  write_context "${context_file}" "${CNTOOLS_MODE}" "${NODE_HOME}" || return 70
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
  # The action-owned wait runs in the production dispatch subshell. Mirror its
  # capture-boundary state in this test-only public-route adapter.
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

clear() { printf 'terminal:clear\n' >> "${EVENT_LOG:?}"; }
getEpoch() { printf '5\n'; }
timeUntilNextEpoch() { printf '0\n'; }
slotInterval() { printf '20\n'; }

timeLeft() {
  printf 'delta-%s' "${1:-}"
}

getDateFromSlot() {
  printf 'slot-%s\n' "${1:-}"
}

getSlotTipRef() {
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    printf 'action:getSlotTipRef\n' >> "${EVENT_LOG:?}"
  fi
  printf '1000\n'
}

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

isNumber() {
  [[ -z ${1:-} ]] && return 1
  [[ $1 =~ ^[0-9]+$ ]]
}

safeDel() {
  local target="${1:-}"

  printf 'action:safeDel:%s\n' "${target}" >> "${EVENT_LOG:?}"
  if rm -rf -- "${target}"; then
    println "Deleted: ${target}"
  else
    println ERROR "ERROR: delete failed for ${target}"
    return 1
  fi
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
      if [[ "${menu}:${choice}" == asset:c ]]; then
        CAPTURE_ACTIVE=Y
        printf '__CNTOOLS_ASSET_CREATE_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was unavailable in ${menu} menu"
}

getAnswerAnyCust() {
  local output_variable="${1:-}" value=""
  shift || true

  case "${output_variable}:$*" in
    'policy_name:Internal name to give the generated policy'|\
    'asset_create_policy_input:Internal name to give the generated policy')
      if [[ "${CNTOOLS_ASSET_CREATE_SCENARIO:-}" == direct-cancel-name ]]; then
        printf 'action:answer-cancel:%s\n' "${output_variable}" \
          >> "${EVENT_LOG:?}"
        return 1
      fi
      value="${POLICY_NAME_INPUT}"
      ;;
    'ttl_enter:TTL (in seconds)'|\
    'asset_create_ttl_input:TTL (in seconds)')
      if [[ "${CNTOOLS_ASSET_CREATE_SCENARIO:-}" == direct-cancel-ttl ]]; then
        printf 'action:answer-cancel:%s\n' "${output_variable}" \
          >> "${EVENT_LOG:?}"
        return 1
      fi
      value="${TTL_INPUT}"
      ;;
    *) fail "unexpected policy input prompt: ${output_variable}:$*" ;;
  esac
  printf -v "${output_variable}" '%s' "${value}"
  printf 'action:answer:%s:%q\n' "${output_variable}" "${value}" \
    >> "${EVENT_LOG:?}"
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    printf '__CNTOOLS_ASSET_CREATE_END__\n'
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

scenario_policy_input() {
  case "$1" in
    empty-name) printf '' ;;
    sanitized-name) printf '../Alpha Policy\n42' ;;
    duplicate-name) printf 'duplicate name' ;;
    duplicate-empty) printf 'duplicate-empty' ;;
    punctuation-only) printf '!!!' ;;
    mode-offline|mode-local|mode-light) printf 'mode policy' ;;
    finite-ttl) printf 'finite policy' ;;
    invalid-ttl) printf 'invalid ttl' ;;
    whitespace-ttl) printf 'whitespace ttl' ;;
    overflow-ttl) printf 'overflow ttl' ;;
    keygen-failure) printf 'keygen failure' ;;
    keyhash-failure) printf 'keyhash failure' ;;
    script-hash-failure) printf 'script hash failure' ;;
    *) return 1 ;;
  esac
}

scenario_policy_name() {
  local input=""
  input="$(scenario_policy_input "$1")" || return 1
  printf '%s' "${input//[^[:alnum:]]/_}"
}

scenario_ttl_input() {
  case "$1" in
    finite-ttl) printf '120' ;;
    invalid-ttl) printf '12x' ;;
    whitespace-ttl) printf '1 2' ;;
    overflow-ttl) printf '18446744073709551616' ;;
    *) printf '' ;;
  esac
}

scenario_mode() {
  case "$1" in
    mode-local) printf 'LOCAL\n' ;;
    mode-light) printf 'LIGHT\n' ;;
    *) printf 'OFFLINE\n' ;;
  esac
}

scenario_success() {
  case "$1" in
    sanitized-name|duplicate-empty|punctuation-only|mode-offline|mode-local|\
    mode-light|finite-ttl|overflow-ttl) return 0 ;;
    *) return 1 ;;
  esac
}

scenario_public_success() {
  if [[ "${PUBLIC_ROUTE_HARDENED:-N}" == Y ]]; then
    case "$1" in
      sanitized-name|mode-offline|mode-local|mode-light|finite-ttl) return 0 ;;
      *) return 1 ;;
    esac
  fi
  scenario_success "$1"
}

scenario_cli_count() {
  case "$1" in
    empty-name|duplicate-name) printf '0\n' ;;
    keygen-failure) printf '1\n' ;;
    keyhash-failure|invalid-ttl|whitespace-ttl) printf '2\n' ;;
    *) printf '3\n' ;;
  esac
}

prepare_scenario() {
  local scenario="$1" asset_root="$2" policy_name=""

  policy_name="$(scenario_policy_name "${scenario}")" || return 1
  case "${scenario}" in
    duplicate-name)
      mkdir -p -- "${asset_root}/${policy_name}"
      printf 'existing policy marker\n' \
        > "${asset_root}/${policy_name}/existing.txt"
      ;;
    duplicate-empty) mkdir -p -- "${asset_root}/${policy_name}" ;;
  esac
  return 0
}

normalize_file() {
  local source="$1" target="$2" runtime_root="$3"

  sed -E \
    -e "s#${runtime_root}#<runtime>#g" \
    -e 's#^.*cntools\.sh: line [0-9]+: \[\[: 1 2: syntax error in expression.*#bash: invalid numeric conditional: 1 2#' \
    -e 's#^.*cntools\.sh: line [0-9]+: 1 2: syntax error in expression.*#bash: invalid arithmetic expression: 1 2#' \
    -e 's#^.*bash: (line [0-9]+: )?1 2: syntax error in expression.*#bash: invalid arithmetic expression: 1 2#' \
    "${source}" > "${target}"
}

normalize_public_vectors() {
  local source="$1" target="$2" runtime_root="$3"

  sed -E \
    -e "s#${runtime_root}/asset/\\.([^/[:space:]]+)\\.staging\\.[^/[:space:]]+#${runtime_root}/asset/\\1#g" \
    "${source}" > "${target}"
}

extract_action_output() {
  local source="$1" target="$2" allow_eof="$3"
  local begin_count=0 end_count=0

  begin_count="$(grep -c '^__CNTOOLS_ASSET_CREATE_BEGIN__$' \
    "${source}" || true)"
  end_count="$(grep -c '^__CNTOOLS_ASSET_CREATE_END__$' \
    "${source}" || true)"
  [[ "${begin_count}" == 1 ]] || fail 'create-policy begin marker changed'
  if [[ "${allow_eof}" == Y ]]; then
    [[ "${end_count}" == 0 ]] || fail 'arithmetic failure unexpectedly waited'
  else
    [[ "${end_count}" == 1 ]] || fail 'create-policy end marker changed'
  fi
  awk '
    $0 == "__CNTOOLS_ASSET_CREATE_BEGIN__" { capture=1; next }
    $0 == "__CNTOOLS_ASSET_CREATE_END__" { exit }
    capture { print }
  ' "${source}" > "${target}"
}

write_expected_stdout() {
  local scenario="$1" target="$2" policy_name=""
  local expire="unlimited"

  policy_name="$(scenario_policy_name "${scenario}")"
  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> ADVANCED >> ASSET >> CREATE POLICY' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    '' \
    > "${target}"
  case "${scenario}" in
    empty-name)
      printf '%s\n' 'ERROR: Empty policy name, please retry!' >> "${target}"
      return
      ;;
    punctuation-only)
      if [[ "${PUBLIC_ROUTE_HARDENED:-N}" == Y ]]; then
        printf '%s\n' \
          'ERROR: Policy name must contain an ASCII letter or digit and be at most 128 characters.' \
          >> "${target}"
        return
      fi
      ;;
  esac
  printf '\n' >> "${target}"
  case "${scenario}" in
    duplicate-name)
      printf '%s\n' \
        "WARN: A policy ${policy_name} already exist!" \
        '      Choose another name or delete the existing one' \
        >> "${target}"
      return
      ;;
    duplicate-empty)
      if [[ "${PUBLIC_ROUTE_HARDENED:-N}" == Y ]]; then
        printf '%s\n' \
          "WARN: A policy ${policy_name} already exist!" \
          '      Choose another name or delete the existing one' \
          >> "${target}"
        return
      fi
      ;;
    keygen-failure)
      if [[ "${PUBLIC_ROUTE_HARDENED:-N}" == Y ]]; then
        printf '%s\n' \
          'ERROR: failure during policy key creation!' \
          'cardano-cli command failed; diagnostic output was suppressed.' \
          >> "${target}"
      else
        printf '%s\n' \
          'ERROR: failure during policy key creation!' \
          'fixture key-gen failure' \
          "Deleted: <runtime>/asset/${policy_name}" \
          >> "${target}"
      fi
      return
      ;;
    keyhash-failure)
      if [[ "${PUBLIC_ROUTE_HARDENED:-N}" == Y ]]; then
        printf '%s\n' \
          'ERROR: failure during policy verification key hashing!' \
          'cardano-cli command failed; diagnostic output was suppressed.' \
          >> "${target}"
      else
        printf '%s\n' \
          'ERROR: failure during policy verification key hashing!' \
          'fixture key-hash failure' \
          "Deleted: <runtime>/asset/${policy_name}" \
          >> "${target}"
      fi
      return
      ;;
  esac
  printf '%s\n' \
    'How long do you want the policy to be valid? (0/blank=unlimited)' \
    'Setting a limit will prevent you from minting/burning assets after the policy expire !!' \
    'Leave blank/unlimited if unsure and just press enter' \
    >> "${target}"
  case "${scenario}" in
    invalid-ttl|whitespace-ttl|overflow-ttl)
      if [[ "${PUBLIC_ROUTE_HARDENED:-N}" == Y ]]; then
        printf '%s\n' \
          '' \
          'ERROR: TTL must be 0/blank or a canonical integer between 1 and 3155760000.' \
          >> "${target}"
      elif [[ "${scenario}" == invalid-ttl ]]; then
        printf '%s\n' \
          '' \
          'ERROR: invalid TTL number, non digit characters found: 12x' \
          "Deleted: <runtime>/asset/${policy_name}" \
          >> "${target}"
      elif [[ "${scenario}" == whitespace-ttl ]]; then
        return
      else
        printf '%s\n' \
          '' \
          "Policy Name   : ${policy_name}" \
          "Policy ID     : ${POLICY_ID}" \
          'Policy Expire : unlimited' \
          '' \
          'You can now start minting your custom assets using this Policy!' \
          >> "${target}"
      fi
      return
      ;;
    script-hash-failure)
      if [[ "${PUBLIC_ROUTE_HARDENED:-N}" == Y ]]; then
        printf '%s\n' \
          'ERROR: failure during policy ID generation!' \
          'cardano-cli command failed; diagnostic output was suppressed.' \
          >> "${target}"
      else
        printf '%s\n' \
          'ERROR: failure during policy ID generation!' \
          'fixture script-hash failure' \
          "Deleted: <runtime>/asset/${policy_name}" \
          >> "${target}"
      fi
      return
      ;;
  esac
  case "${scenario}" in
    finite-ttl) expire='slot-1060, delta-60 remaining' ;;
  esac
  printf '%s\n' \
    '' \
    "Policy Name   : ${policy_name}" \
    "Policy ID     : ${POLICY_ID}" \
    "Policy Expire : ${expire}" \
    '' \
    'You can now start minting your custom assets using this Policy!' \
    >> "${target}"
}

write_expected_stderr() {
  local scenario="$1" target="$2"

  : > "${target}"
  if [[ "${scenario}" == whitespace-ttl &&
        "${PUBLIC_ROUTE_HARDENED:-N}" != Y ]]; then
    printf '%s\n' \
      'bash: invalid numeric conditional: 1 2' \
      'bash: invalid arithmetic expression: 1 2' \
      > "${target}"
  fi
}

write_expected_vectors() {
  local scenario="$1" target="$2" policy_name="" root=""
  local call_count=0

  : > "${target}"
  policy_name="$(scenario_policy_name "${scenario}")"
  root="<runtime>/asset/${policy_name}"
  if [[ "${PUBLIC_ROUTE_HARDENED:-N}" == Y ]]; then
    case "${scenario}" in
      empty-name|duplicate-name|duplicate-empty|punctuation-only)
        call_count=0
        ;;
      keygen-failure) call_count=1 ;;
      keyhash-failure|invalid-ttl|whitespace-ttl|overflow-ttl)
        call_count=2
        ;;
      *) call_count=3 ;;
    esac
  else
    call_count="$(scenario_cli_count "${scenario}")"
  fi
  if (( call_count >= 1 )); then
    printf 'cardano-cli\taddress\tkey-gen\t--verification-key-file\t%s/policy.vkey\t--signing-key-file\t%s/policy.skey\n' \
      "${root}" "${root}" >> "${target}"
  fi
  if (( call_count >= 2 )); then
    printf 'cardano-cli\taddress\tkey-hash\t--payment-verification-key-file\t%s/policy.vkey\n' \
      "${root}" >> "${target}"
  fi
  if (( call_count >= 3 )); then
    printf 'cardano-cli\thash\tscript\t--script-file\t%s/policy.script\t--out-file\t%s/policy.id\n' \
      "${root}" "${root}" >> "${target}"
  fi
  return 0
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
  local scenario="$1" mode="$2" target="$3" policy_name=""
  local slot_calls=0 index=0

  : > "${target}"
  printf '%s\n' terminal:clear >> "${target}"
  write_runtime_events "${mode}" "${target}"
  printf '%s\n' \
    menu:main:a terminal:clear menu:advanced:a \
    terminal:clear menu:asset:c action:compatibility-dispatch terminal:clear \
    >> "${target}"
  printf 'action:answer:asset_create_policy_input:%q\n' \
    "$(scenario_policy_input "${scenario}")" >> "${target}"
  case "${scenario}" in
    empty-name|duplicate-name|duplicate-empty|punctuation-only|keygen-failure|keyhash-failure) ;;
    *)
      printf 'action:answer:asset_create_ttl_input:%q\n' \
        "$(scenario_ttl_input "${scenario}")" >> "${target}"
      ;;
  esac
  if [[ "${PUBLIC_ROUTE_HARDENED:-N}" == Y ]]; then
    [[ "${scenario}" != finite-ttl ]] || slot_calls=1
  else
    case "${scenario}" in
      finite-ttl) slot_calls=2 ;;
      whitespace-ttl) slot_calls=1 ;;
    esac
  fi
  for ((index=0; index<slot_calls; index++)); do
    printf '%s\n' action:getSlotTipRef >> "${target}"
  done
  case "${scenario}" in
    invalid-ttl|keygen-failure|keyhash-failure|script-hash-failure)
      if [[ "${PUBLIC_ROUTE_HARDENED:-N}" != Y ]]; then
        policy_name="$(scenario_policy_name "${scenario}")"
        printf 'action:safeDel:<runtime>/asset/%s\n' "${policy_name}" \
          >> "${target}"
      fi
      ;;
  esac
  if [[ "${scenario}" == whitespace-ttl &&
        "${PUBLIC_ROUTE_HARDENED:-N}" != Y ]]; then
    return
  fi
  printf '%s\n' action:waitToProceed terminal:clear menu:asset:h \
    terminal:clear >> "${target}"
  write_runtime_events "${mode}" "${target}"
  printf '%s\n' menu:main:q 'exit:0:CNTools closed!' >> "${target}"
}

expected_script() {
  case "$1" in
    finite-ttl)
      printf '{ "type": "all", "scripts": [ { "slot": 1060, "type": "before" }, { "keyHash": "%s", "type": "sig" } ] }\n' \
        "${POLICY_KEY_HASH}"
      ;;
    *)
      printf '{ "keyHash": "%s", "type": "sig" }\n' \
        "${POLICY_KEY_HASH}"
      ;;
  esac
}

assert_success_mutation() {
  local scenario="$1" runtime_root="$2" before="$3" after="$4"
  local policy_name="" policy_root="" filtered="${after}.filtered"
  local target="" mode="" expected=""

  policy_name="$(scenario_policy_name "${scenario}")"
  policy_root="${runtime_root}/asset/${policy_name}"
  [[ -d "${policy_root}" && ! -L "${policy_root}" ]] ||
    fail "${scenario} policy directory is missing or unsafe"
  [[ "$(file_mode "${policy_root}")" == 755 ]] ||
    fail "${scenario} policy directory mode changed"
  for target in policy.vkey policy.skey policy.script policy.id; do
    [[ -f "${policy_root}/${target}" && ! -L "${policy_root}/${target}" ]] ||
      fail "${scenario} artifact is missing or unsafe: ${target}"
    mode="$(file_mode "${policy_root}/${target}")"
    [[ "${mode}" == 600 ]] ||
      fail "${scenario} artifact mode changed for ${target}: ${mode}"
  done
  [[ "$(< "${policy_root}/policy.id")" == "${POLICY_ID}" ]] ||
    fail "${scenario} policy ID content changed"
  expected="$(expected_script "${scenario}")"
  [[ "$(< "${policy_root}/policy.script")" == "${expected%$'\n'}" ]] ||
    fail "${scenario} policy script content changed"
  if [[ "${scenario}" == duplicate-empty ||
        "${scenario}" == punctuation-only ]]; then
    grep -Ev "^f[[:space:]]+asset/${policy_name}/" \
      "${after}" > "${filtered}"
    assert_files_equal "${filtered}" "${before}" \
      "${scenario} exact persistent mutation allowlist"
  else
    grep -Ev "^(d|f)[[:space:]]+asset/${policy_name}([[:space:]]|/)" \
      "${after}" > "${filtered}"
    assert_files_equal "${filtered}" "${before}" \
      "${scenario} exact persistent mutation allowlist"
  fi
}

assert_whitespace_defect_mutation() {
  local runtime_root="$1" before="$2" after="$3" policy_name=""
  local policy_root="" filtered="${after}.filtered" target=""

  policy_name="$(scenario_policy_name whitespace-ttl)"
  policy_root="${runtime_root}/asset/${policy_name}"
  [[ "$(file_mode "${policy_root}")" == 755 ]] ||
    fail 'whitespace TTL residual directory mode changed'
  for target in policy.vkey policy.skey; do
    [[ -f "${policy_root}/${target}" &&
       "$(file_mode "${policy_root}/${target}")" == 644 ]] ||
      fail "whitespace TTL residual ${target} contract changed"
  done
  [[ ! -e "${policy_root}/policy.script" &&
     ! -e "${policy_root}/policy.id" ]] ||
    fail 'whitespace TTL advanced past the arithmetic failure'
  grep -Ev "^(d|f)[[:space:]]+asset/${policy_name}([[:space:]]|/)" \
    "${after}" > "${filtered}"
  assert_files_equal "${filtered}" "${before}" \
    'whitespace TTL residual-mutation allowlist'
}

run_case() {
  local scenario="$1" mode="" policy_input="" ttl_input=""
  local case_root="${TEST_ROOT}/cases/${scenario}"
  local runtime_root="${case_root}/runtime"
  local asset_root="${runtime_root}/asset"
  local capture_root="${case_root}/capture"
  local full_stdout="${capture_root}/full.stdout"
  local action_stdout_raw="${capture_root}/action.raw.stdout"
  local action_stdout="${capture_root}/action.stdout"
  local stderr_raw="${capture_root}/raw.stderr"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout_file="${capture_root}/expected.stdout"
  local expected_stderr_file="${capture_root}/expected.stderr"
  local event_log_raw="${capture_root}/raw.events"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local vector_log_raw="${capture_root}/raw.vectors"
  local vector_log="${capture_root}/vectors"
  local expected_vectors="${capture_root}/expected.vectors"
  local network_log="${capture_root}/network"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local status=0 expected_status=0 allow_eof=N

  mode="$(scenario_mode "${scenario}")"
  policy_input="$(scenario_policy_input "${scenario}")"
  ttl_input="$(scenario_ttl_input "${scenario}")"
  [[ "${scenario}" != whitespace-ttl ||
     "${PUBLIC_ROUTE_HARDENED:-N}" == Y ]] || {
    expected_status=1
    allow_eof=Y
  }
  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/wallet" \
    "${runtime_root}/pool" "${runtime_root}/home" "${asset_root}" \
    "${capture_root}"
  prepare_scenario "${scenario}" "${asset_root}"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "${scenario} pre-snapshot failed"
  : > "${event_log_raw}"
  : > "${vector_log_raw}"
  : > "${network_log}"

  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    export CNTOOLS_ASSET_CREATE_SCENARIO="${scenario}"
    export CNTOOLS_ASSET_CREATE_VECTOR_LOG="${vector_log_raw}"
    export CNTOOLS_ASSET_CREATE_NETWORK_LOG="${network_log}"
    export CNTOOLS_ASSET_CREATE_KEY_HASH="${POLICY_KEY_HASH}"
    export CNTOOLS_ASSET_CREATE_POLICY_ID="${POLICY_ID}"
    export CNTOOLS_ASSET_CREATE_SECURITY_LOG=/dev/null
    export CNTOOLS_ASSET_CREATE_PUBLISH_LOG=/dev/null
    export CNTOOLS_ASSET_CREATE_REAL_MV="${REAL_MV_PATH}"
    export CNTOOLS_ASSET_CREATE_REAL_RMDIR="${REAL_RMDIR_PATH}"
    export CNTOOLS_ASSET_CREATE_REAL_MKDIR="${REAL_MKDIR_PATH}"
    export CNTOOLS_ASSET_CREATE_RMDIR_STATE="${capture_root}/rmdir.state"
    PATH="${FAKE_BIN}:${BASE_PATH}"
    export PATH
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    ASSET_FOLDER="${asset_root}"
    ASSET_POLICY_VK_FILENAME=policy.vkey
    ASSET_POLICY_SK_FILENAME=policy.skey
    ASSET_POLICY_SCRIPT_FILENAME=policy.script
    ASSET_POLICY_ID_FILENAME=policy.id
    CCLI=cardano-cli
    SLOT_LENGTH=2
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
    EVENT_LOG="${event_log_raw}"
    CAPTURE_ACTIVE=N
    POLICY_NAME_INPUT="${policy_input}"
    TTL_INPUT="${ttl_input}"
    CHOICES=(a a c h q)
    CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_raw}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "${expected_status}" ]] ||
    fail "${scenario} returned ${status}, expected ${expected_status}"

  extract_action_output "${full_stdout}" "${action_stdout_raw}" "${allow_eof}"
  normalize_file "${action_stdout_raw}" "${action_stdout}" "${runtime_root}"
  normalize_file "${stderr_raw}" "${stderr_file}" "${runtime_root}"
  normalize_file "${event_log_raw}" "${event_log}" "${runtime_root}"
  normalize_public_vectors "${vector_log_raw}" "${vector_log}.published" \
    "${runtime_root}"
  normalize_file "${vector_log}.published" "${vector_log}" "${runtime_root}"
  write_expected_stdout "${scenario}" "${expected_stdout_file}"
  write_expected_stderr "${scenario}" "${expected_stderr_file}"
  write_expected_events "${scenario}" "${mode}" "${expected_events}"
  write_expected_vectors "${scenario}" "${expected_vectors}"
  assert_files_equal "${action_stdout}" "${expected_stdout_file}" \
    "${scenario} exact normalized stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr_file}" \
    "${scenario} exact normalized stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "${scenario} exact waits/menu/runtime events"
  assert_files_equal "${vector_log}" "${expected_vectors}" \
    "${scenario} exact cardano-cli argv"
  [[ ! -s "${network_log}" ]] ||
    fail "${scenario} attempted network access: $(< "${network_log}")"

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "${scenario} post-snapshot failed"
  if [[ "${PUBLIC_ROUTE_HARDENED:-N}" == Y &&
        ( "${scenario}" == duplicate-empty ||
          "${scenario}" == punctuation-only ) ]]; then
    assert_files_equal "${after_snapshot}" "${before_snapshot}" \
      "${scenario} hardened public zero mutation"
  elif scenario_public_success "${scenario}"; then
    assert_success_mutation "${scenario}" "${runtime_root}" \
      "${before_snapshot}" "${after_snapshot}"
  elif [[ "${scenario}" == whitespace-ttl &&
          "${PUBLIC_ROUTE_HARDENED:-N}" != Y ]]; then
    assert_whitespace_defect_mutation "${runtime_root}" \
      "${before_snapshot}" "${after_snapshot}"
  else
    assert_files_equal "${after_snapshot}" "${before_snapshot}" \
      "${scenario} zero persistent mutation"
  fi
}

write_fake_commands
PUBLIC_ROUTE_HARDENED=Y

run_case empty-name
run_case sanitized-name
run_case duplicate-name
run_case duplicate-empty
run_case punctuation-only
run_case mode-offline
run_case mode-local
run_case mode-light
run_case finite-ttl
run_case invalid-ttl
run_case whitespace-ttl
run_case overflow-ttl
run_case keygen-failure
run_case keyhash-failure
run_case script-hash-failure

direct_policy_input() {
  case "$1" in
    direct-unlimited-offline|direct-unlimited-local|direct-unlimited-light)
      printf 'mode policy' ;;
    direct-finite) printf 'finite policy' ;;
    direct-empty) printf '' ;;
    direct-punctuation) printf '!!!' ;;
    direct-duplicate-empty) printf 'duplicate-empty' ;;
    direct-whitespace-ttl) printf 'whitespace ttl' ;;
    direct-overflow-ttl) printf 'overflow ttl' ;;
    direct-over-limit-ttl) printf 'over limit ttl' ;;
    direct-cancel-name) printf 'unused' ;;
    direct-cancel-ttl) printf 'cancel ttl' ;;
    direct-keygen-failure|direct-escaped-diagnostic)
      printf 'keygen failure' ;;
    direct-keyhash-failure|direct-malformed-keyhash)
      printf 'keyhash failure' ;;
    direct-scripthash-failure|direct-malformed-policy-id)
      printf 'script hash failure' ;;
    direct-malformed-vkey) printf 'malformed vkey' ;;
    direct-release-failure) printf 'release failure' ;;
    direct-mv-failure) printf 'move failure' ;;
    direct-publish-collision) printf 'publish collision' ;;
    direct-signal-keygen) printf 'signal keygen' ;;
    direct-context-mismatch) printf 'context mismatch' ;;
    direct-unsafe-filename) printf 'unsafe filename' ;;
    direct-tool-shadow) printf 'tool shadow' ;;
    *) return 1 ;;
  esac
}

direct_policy_name() {
  local value=""
  value="$(direct_policy_input "$1")" || return 1
  printf '%s' "${value//[^A-Za-z0-9]/_}"
}

direct_ttl_input() {
  case "$1" in
    direct-finite) printf '120' ;;
    direct-whitespace-ttl) printf '1 2' ;;
    direct-overflow-ttl) printf '18446744073709551616' ;;
    direct-over-limit-ttl) printf '3155760001' ;;
    *) printf '' ;;
  esac
}

direct_mode() {
  case "$1" in
    direct-unlimited-local) printf 'LOCAL\n' ;;
    direct-unlimited-light) printf 'LIGHT\n' ;;
    *) printf 'OFFLINE\n' ;;
  esac
}

direct_expected_status() {
  case "$1" in
    direct-malformed-vkey|direct-malformed-keyhash|\
    direct-malformed-policy-id|direct-release-failure|direct-mv-failure|\
    direct-publish-collision|direct-signal-keygen|direct-context-mismatch|\
    direct-unsafe-filename|direct-tool-shadow) printf '70\n' ;;
    *) printf '0\n' ;;
  esac
}

direct_expected_cli_count() {
  case "$1" in
    direct-empty|direct-punctuation|direct-duplicate-empty|\
    direct-cancel-name|direct-context-mismatch|direct-unsafe-filename|\
    direct-tool-shadow) printf '0\n' ;;
    direct-keygen-failure|direct-escaped-diagnostic|direct-malformed-vkey|\
    direct-signal-keygen) printf '1\n' ;;
    direct-keyhash-failure|direct-malformed-keyhash|direct-whitespace-ttl|\
    direct-overflow-ttl|direct-over-limit-ttl|direct-cancel-ttl) printf '2\n' ;;
    *) printf '3\n' ;;
  esac
}

write_direct_expected_vectors() {
  local scenario="$1" target="$2" calls=0

  : > "${target}"
  calls="$(direct_expected_cli_count "${scenario}")"
  if (( calls >= 1 )); then
    printf 'cardano-cli\taddress\tkey-gen\t--verification-key-file\t<staging>/policy.vkey\t--signing-key-file\t<staging>/policy.skey\n' \
      >> "${target}"
  fi
  if (( calls >= 2 )); then
    printf 'cardano-cli\taddress\tkey-hash\t--payment-verification-key-file\t<staging>/policy.vkey\n' \
      >> "${target}"
  fi
  if (( calls >= 3 )); then
    printf 'cardano-cli\thash\tscript\t--script-file\t<staging>/policy.script\t--out-file\t<staging>/policy.id\n' \
      >> "${target}"
  fi
}

normalize_direct_vectors() {
  local source="$1" target="$2" asset_root="$3"

  sed -E \
    -e "s#${FAKE_BIN}/cardano-cli#cardano-cli#g" \
    -e "s#${asset_root}/\\.[^/[:space:]]+\\.staging\\.[^/[:space:]]+#<staging>#g" \
    "${source}" > "${target}"
}

write_direct_expected_stderr() {
  local scenario="$1" target="$2"

  : > "${target}"
  case "${scenario}" in
    direct-malformed-vkey|direct-malformed-keyhash|\
    direct-malformed-policy-id|direct-release-failure|direct-mv-failure|\
    direct-publish-collision|direct-context-mismatch|\
    direct-unsafe-filename|direct-tool-shadow)
      printf '%s\n' \
        'CNTools asset-create-policy action failed validation.' \
        > "${target}"
      ;;
  esac
}

write_direct_expected_stdout() {
  local scenario="$1" target="$2" policy_name="" expire=unlimited

  : > "${target}"
  case "${scenario}" in
    direct-context-mismatch|direct-unsafe-filename|direct-tool-shadow) return ;;
  esac
  policy_name="$(direct_policy_name "${scenario}")"
  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> ADVANCED >> ASSET >> CREATE POLICY' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    '' >> "${target}"
  [[ "${scenario}" != direct-cancel-name ]] || return 0
  if [[ "${scenario}" == direct-empty ]]; then
    printf '%s\n' 'ERROR: Empty policy name, please retry!' >> "${target}"
    return
  fi
  case "${scenario}" in
    direct-punctuation)
      printf '%s\n' \
        'ERROR: Policy name must contain an ASCII letter or digit and be at most 128 characters.' \
        >> "${target}"
      return
      ;;
  esac
  printf '\n' >> "${target}"
  case "${scenario}" in
    direct-duplicate-empty)
      printf '%s\n' \
        "WARN: A policy ${policy_name} already exist!" \
        '      Choose another name or delete the existing one' >> "${target}"
      return
      ;;
    direct-keygen-failure|direct-escaped-diagnostic)
      printf '%s\n' \
        'ERROR: failure during policy key creation!' \
        'cardano-cli command failed; diagnostic output was suppressed.' \
        >> "${target}"
      return
      ;;
    direct-malformed-vkey|direct-signal-keygen) return ;;
    direct-keyhash-failure)
      printf '%s\n' \
        'ERROR: failure during policy verification key hashing!' \
        'cardano-cli command failed; diagnostic output was suppressed.' \
        >> "${target}"
      return
      ;;
    direct-malformed-keyhash) return ;;
  esac
  printf '%s\n' \
    'How long do you want the policy to be valid? (0/blank=unlimited)' \
    'Setting a limit will prevent you from minting/burning assets after the policy expire !!' \
    'Leave blank/unlimited if unsure and just press enter' \
    >> "${target}"
  [[ "${scenario}" != direct-cancel-ttl ]] || return 0
  case "${scenario}" in
    direct-whitespace-ttl|direct-overflow-ttl|direct-over-limit-ttl)
      printf '%s\n' \
        '' \
        'ERROR: TTL must be 0/blank or a canonical integer between 1 and 3155760000.' \
        >> "${target}"
      return
      ;;
    direct-scripthash-failure)
      printf '%s\n' \
        'ERROR: failure during policy ID generation!' \
        'cardano-cli command failed; diagnostic output was suppressed.' \
        >> "${target}"
      return
      ;;
    direct-malformed-policy-id|direct-release-failure|direct-mv-failure|\
    direct-publish-collision) return ;;
  esac
  [[ "${scenario}" != direct-finite ]] || expire='slot-1060, delta-60 remaining'
  printf '%s\n' \
    '' \
    "Policy Name   : ${policy_name}" \
    "Policy ID     : ${POLICY_ID}" \
    "Policy Expire : ${expire}" \
    '' \
    'You can now start minting your custom assets using this Policy!' \
    >> "${target}"
}

assert_direct_security_log() {
  local scenario="$1" target="$2" line="" phase="" stage_mode=""
  local first_mode="" second_mode="" expected_calls=0 observed_calls=0

  expected_calls="$(direct_expected_cli_count "${scenario}")"
  while IFS=$'\t' read -r phase stage_mode first_mode second_mode; do
    [[ -n "${phase}" ]] || continue
    observed_calls=$((observed_calls + 1))
    [[ "${stage_mode}" == 700 && "${first_mode}" == 600 ]] ||
      fail "${scenario} exposed staging/key material above 0600"
    if [[ "${phase}" == keygen ]]; then
      [[ "${second_mode}" == 600 ]] ||
        fail "${scenario} exposed the signing key above 0600"
    else
      [[ -z "${second_mode}" ]] ||
        fail "${scenario} security probe shape changed"
    fi
  done < "${target}"
  if [[ "${scenario}" == direct-signal-keygen ]]; then
    (( observed_calls <= expected_calls )) ||
      fail 'signal case ran unexpected cardano-cli phases'
  else
    [[ "${observed_calls}" == "${expected_calls}" ]] ||
      fail "${scenario} security phase count changed"
  fi
}

assert_direct_mutation() {
  local scenario="$1" asset_root="$2" before="$3" after="$4"
  local policy_name="" policy_root="" target="" expected=""

  policy_name="$(direct_policy_name "${scenario}")"
  policy_root="${asset_root}/${policy_name}"
  case "${scenario}" in
    direct-unlimited-offline|direct-unlimited-local|direct-unlimited-light|\
    direct-finite)
      [[ -d "${policy_root}" && ! -L "${policy_root}" &&
         "$(file_mode "${policy_root}")" == 755 ]] ||
        fail "${scenario} published directory contract changed"
      for target in policy.vkey policy.skey policy.script policy.id; do
        [[ -f "${policy_root}/${target}" &&
           ! -L "${policy_root}/${target}" &&
           "$(file_mode "${policy_root}/${target}")" == 600 ]] ||
          fail "${scenario} published artifact contract changed: ${target}"
      done
      [[ "$(< "${policy_root}/policy.id")" == "${POLICY_ID}" ]] ||
        fail "${scenario} published policy ID changed"
      if [[ "${scenario}" == direct-finite ]]; then
        expected="$(expected_script finite-ttl)"
      else
        expected="$(expected_script mode-offline)"
      fi
      [[ "$(< "${policy_root}/policy.script")" == "${expected%$'\n'}" ]] ||
        fail "${scenario} canonical policy script changed"
      [[ -z "$(find "${asset_root}" -mindepth 1 -maxdepth 1 \
        -type d -name '.*.staging.*' -print -quit)" ]] ||
        fail "${scenario} left staging state"
      [[ -z "$(find "${asset_root}" -mindepth 1 -maxdepth 1 \
        -type d -name '.*.create.lock' -print -quit)" ]] ||
        fail "${scenario} left lock state"
      ;;
    direct-duplicate-empty)
      assert_files_equal "${after}" "${before}" \
        'direct duplicate empty directory remains untouched'
      ;;
    direct-publish-collision)
      [[ -f "${policy_root}/competitor.txt" &&
         "$(< "${policy_root}/competitor.txt")" == competitor ]] ||
        fail 'publish collision did not preserve competitor state'
      [[ ! -e "${policy_root}/policy.skey" ]] ||
        fail 'publish collision clobbered competitor state'
      ;;
    *)
      assert_files_equal "${after}" "${before}" \
        "${scenario} exact zero persistent mutation"
      ;;
  esac
}

run_direct_case() {
  local scenario="$1" mode="" expected_status=0 status=0
  local case_root="${TEST_ROOT}/direct/${scenario}"
  local runtime_root="${case_root}/runtime" asset_root=""
  local private_root="${case_root}/private" context_file=""
  local result_file="" capture_root="${case_root}/capture"
  local stdout_file="${capture_root}/stdout" stderr_file="${capture_root}/stderr"
  local expected_stdout_file="${capture_root}/expected.stdout"
  local expected_stderr_file="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events" vector_raw="${capture_root}/vectors.raw"
  local vector_log="${capture_root}/vectors" expected_vectors="${capture_root}/expected.vectors"
  local security_log="${capture_root}/security" publish_log="${capture_root}/publish"
  local network_log="${capture_root}/network" rmdir_state="${capture_root}/rmdir.state"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local policy_input="" ttl_input="" policy_name=""

  asset_root="${runtime_root}/asset"
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  mode="$(direct_mode "${scenario}")"
  expected_status="$(direct_expected_status "${scenario}")"
  policy_input="$(direct_policy_input "${scenario}")"
  ttl_input="$(direct_ttl_input "${scenario}")"
  policy_name="$(direct_policy_name "${scenario}")"
  mkdir -p -- "${asset_root}" "${runtime_root}/home" "${private_root}" \
    "${capture_root}"
  chmod 0700 "${private_root}"
  if [[ "${scenario}" == direct-duplicate-empty ]]; then
    mkdir -p -- "${asset_root}/${policy_name}"
  fi
  write_context "${context_file}" "${mode}" "${runtime_root}/home"
  tree_snapshot "${asset_root}" "${before_snapshot}" ||
    fail "${scenario} direct pre-snapshot failed"
  : > "${event_log}"
  : > "${vector_raw}"
  : > "${security_log}"
  : > "${publish_log}"
  : > "${network_log}"

  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    export CNTOOLS_ASSET_CREATE_SCENARIO="${scenario}"
    export CNTOOLS_ASSET_CREATE_VECTOR_LOG="${vector_raw}"
    export CNTOOLS_ASSET_CREATE_SECURITY_LOG="${security_log}"
    export CNTOOLS_ASSET_CREATE_PUBLISH_LOG="${publish_log}"
    export CNTOOLS_ASSET_CREATE_NETWORK_LOG="${network_log}"
    export CNTOOLS_ASSET_CREATE_KEY_HASH="${POLICY_KEY_HASH}"
    export CNTOOLS_ASSET_CREATE_POLICY_ID="${POLICY_ID}"
    export CNTOOLS_ASSET_CREATE_REAL_MV="${REAL_MV_PATH}"
    export CNTOOLS_ASSET_CREATE_REAL_RMDIR="${REAL_RMDIR_PATH}"
    export CNTOOLS_ASSET_CREATE_REAL_MKDIR="${REAL_MKDIR_PATH}"
    export CNTOOLS_ASSET_CREATE_RMDIR_STATE="${rmdir_state}"
    PATH="${FAKE_BIN}:${BASE_PATH}"
    export PATH
    HOME="${runtime_root}/home"
    ASSET_FOLDER="${asset_root}"
    ASSET_POLICY_VK_FILENAME=policy.vkey
    ASSET_POLICY_SK_FILENAME=policy.skey
    ASSET_POLICY_SCRIPT_FILENAME=policy.script
    ASSET_POLICY_ID_FILENAME=policy.id
    [[ "${scenario}" != direct-unsafe-filename ]] ||
      ASSET_POLICY_SK_FILENAME='../policy.skey'
    CCLI=cardano-cli
    SLOT_LENGTH=2
    CNTOOLS_MODE="${mode}"
    [[ "${scenario}" != direct-context-mismatch ]] || CNTOOLS_MODE=LOCAL
    CNTOOLS_MODE_COLOR=""
    FG_RED="" FG_GREEN="" FG_YELLOW="" FG_LGRAY="" NC=""
    EVENT_LOG="${event_log}"
    POLICY_NAME_INPUT="${policy_input}"
    TTL_INPUT="${ttl_input}"
    if [[ "${scenario}" == direct-tool-shadow ]]; then
      function cardano-cli { return 99; }
    fi
    cntools_action_main "${context_file}" "${result_file}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "${expected_status}" ]] ||
    fail "${scenario} returned ${status}, expected ${expected_status}"
  write_direct_expected_stdout "${scenario}" "${expected_stdout_file}"
  write_direct_expected_stderr "${scenario}" "${expected_stderr_file}"
  assert_files_equal "${stdout_file}" "${expected_stdout_file}" \
    "${scenario} exact direct stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr_file}" \
    "${scenario} exact direct stderr"
  normalize_direct_vectors "${vector_raw}" "${vector_log}" "${asset_root}"
  write_direct_expected_vectors "${scenario}" "${expected_vectors}"
  assert_files_equal "${vector_log}" "${expected_vectors}" \
    "${scenario} exact direct cardano-cli argv"
  assert_direct_security_log "${scenario}" "${security_log}"
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] ||
    fail "${scenario} unexpectedly produced a result"
  [[ ! -s "${network_log}" ]] ||
    fail "${scenario} attempted network access"
  if [[ "${scenario}" == direct-escaped-diagnostic ]]; then
    ! grep -aEq 'OWNED|\\033|\x1b' "${stdout_file}" "${stderr_file}" ||
      fail 'escaped tool diagnostic reached a terminal stream'
  fi
  tree_snapshot "${asset_root}" "${after_snapshot}" ||
    fail "${scenario} direct post-snapshot failed"
  assert_direct_mutation "${scenario}" "${asset_root}" \
    "${before_snapshot}" "${after_snapshot}"
}

run_direct_case direct-unlimited-offline
run_direct_case direct-unlimited-local
run_direct_case direct-unlimited-light
run_direct_case direct-finite
run_direct_case direct-empty
run_direct_case direct-punctuation
run_direct_case direct-duplicate-empty
run_direct_case direct-whitespace-ttl
run_direct_case direct-overflow-ttl
run_direct_case direct-over-limit-ttl
run_direct_case direct-cancel-name
run_direct_case direct-cancel-ttl
run_direct_case direct-keygen-failure
run_direct_case direct-escaped-diagnostic
run_direct_case direct-keyhash-failure
run_direct_case direct-scripthash-failure
run_direct_case direct-malformed-vkey
run_direct_case direct-malformed-keyhash
run_direct_case direct-malformed-policy-id
run_direct_case direct-release-failure
run_direct_case direct-mv-failure
run_direct_case direct-publish-collision
run_direct_case direct-signal-keygen
run_direct_case direct-context-mismatch
run_direct_case direct-unsafe-filename
run_direct_case direct-tool-shadow

if cntools_action_main only-one-argument >/dev/null 2>&1; then
  fail 'direct create-policy accepted an invalid argument count'
else
  [[ "$?" == 64 ]] || fail 'direct create-policy invocation misuse status changed'
fi

# Freeze the exact one-call public route and absence of the former unsafe body.
create_policy_arm="${TEST_ROOT}/create-policy-arm"
awk '
  /^[[:space:]]+create-policy\)/ { capture = 1 }
  capture { print }
  capture && /^[[:space:]]+;;/ { exit }
' "${CNTOOLS_SCRIPT}" > "${create_policy_arm}"
[[ "$(grep -c 'cntools_compatibility_dispatch_action advanced.asset.create-policy' \
      "${create_policy_arm}" || true)" == 1 ]] ||
  fail 'public create-policy arm does not contain exactly one dispatch call'
if grep -Eq 'policy_name=|policy_key_hash|ttl_enter|safeDel|address key-gen|hash script|chmod 600' \
    "${create_policy_arm}"; then
  fail 'former inline create-policy implementation remains in the public arm'
fi
grep -Fq '_cntools_action_advanced_asset_create_policy_validation_failure' \
  "${ACTION_SOURCE}" || fail 'hardened create-policy action is unavailable'
grep -Fq 'cntools_action_main() {' "${ACTION_SOURCE}" ||
  fail 'hardened create-policy entrypoint is unavailable'

printf 'CNTools asset-create-policy characterization passed (15 public + 26 direct cases)\n'
