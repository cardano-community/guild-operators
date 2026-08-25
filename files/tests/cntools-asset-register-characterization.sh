#!/usr/bin/env bash
# Preserve the frozen inline advanced.asset.register characterization record
# and verify the hardened extracted action through direct and public routing.
# shellcheck disable=SC1090,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools asset-register characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
ACTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/advanced/asset/register/action.sh"
ACTION_DIRECTORY="${ACTION_SOURCE%/action.sh}"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
STAGE4_TEST_LIBRARY="${REPO_ROOT}/files/tests/lib/cntools-stage4-test.library"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-asset-register.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
REAL_SED_PATH="$(command -v sed)"
REAL_MV_PATH="$(command -v mv)"
REAL_LN_PATH="$(command -v ln)"
REAL_RMDIR_PATH="$(command -v rmdir)"
REAL_JQ_PATH="$(command -v jq)"
POLICY_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SECRET_MARKER='REGISTER_POLICY_SIGNING_SECRET_DO_NOT_EXPOSE'

cleanup_test() {
  if [[ "${CNTOOLS_ASSET_REGISTER_PRESERVE_TEST_ROOT:-N}" == Y ]]; then
    printf 'CNTools asset-register test root preserved: %s\n' \
      "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools asset-register characterization failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "${STAGE4_TEST_LIBRARY}" && ! -L "${STAGE4_TEST_LIBRARY}" ]] ||
  fail 'Stage 4 test helper library is missing or unsafe'
# shellcheck source=lib/cntools-stage4-test.library
. "${STAGE4_TEST_LIBRARY}"

for required_command in awk basename cmp cut find grep jq readlink sed sort stat tr wc; do
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
    'scenario="${CNTOOLS_ASSET_REGISTER_SCENARIO:?}"' \
    'log="${CNTOOLS_ASSET_REGISTER_VECTOR_LOG:?}"' \
    'meta_file="${CNTOOLS_ASSET_REGISTER_META_FILE:?}"' \
    'subject="${CNTOOLS_ASSET_REGISTER_SUBJECT:?}"' \
    'sequence=0' \
    'printf '\''cwd\t%q\n'\'' "$(pwd -P)" >> "${log}"' \
    'printf '\''token-metadata-creator'\'' >> "${log}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${log}"; done' \
    'printf '\''\n'\'' >> "${log}"' \
    'phase=""' \
    'if [[ " $* " == *" --init "* ]]; then phase=draft' \
    'elif [[ "${1:-}" == entry && " $* " == *" -a "* ]]; then phase=sign' \
    'elif [[ "${1:-}" == entry && " $* " == *" --finalize "* ]]; then phase=finalize' \
    'elif [[ "${1:-}" == validate ]]; then phase=validate' \
    'else exit 96; fi' \
    'case "${scenario}:${phase}" in' \
    '  draft-failure:draft) printf '\''draft diagnostic\n'\'' >&2; exit 31 ;;' \
    '  raw-diagnostic:draft) printf '\''\\033[31mOWNED\\n'\'' >&2; exit 32 ;;' \
    '  signing-failure:sign) printf '\''sign diagnostic\n'\'' >&2; exit 33 ;;' \
    '  finalize-failure:finalize) printf '\''finalize diagnostic\n'\'' >&2; exit 34 ;;' \
    '  validate-failure:validate) printf '\''validate diagnostic\n'\'' >&2; exit 35 ;;' \
    'esac' \
    'case "${phase}" in' \
    '  draft)' \
    '    printf '\''{\n  "subject": "%s",\n  "sequenceNumber": 0,\n  "phase": "draft"\n}\n'\'' "${subject}" > "${meta_file}"' \
    '    printf '\''%s\n'\'' "${meta_file}"' \
    '    ;;' \
    '  sign)' \
    '    sequence="$("${CNTOOLS_ASSET_REGISTER_REAL_JQ:?}" -r '\''.sequenceNumber // 0'\'' "${meta_file}" 2>/dev/null)" || sequence=0' \
    '    printf '\''{\n  "subject": "%s",\n  "sequenceNumber": %s,\n  "phase": "signed"\n}\n'\'' "${subject}" "${sequence}" > "${meta_file}"' \
    '    printf '\''%s\n'\'' "${meta_file}"' \
    '    ;;' \
    '  finalize)' \
    '    sequence="$("${CNTOOLS_ASSET_REGISTER_REAL_JQ:?}" -r '\''.sequenceNumber // 0'\'' "${meta_file}" 2>/dev/null)" || sequence=0' \
    '    printf '\''{\n  "subject": "%s",\n  "sequenceNumber": %s,\n  "phase": "finalized"\n}\n'\'' "${subject}" "${sequence}" > "${meta_file}"' \
    '    printf '\''%s\n'\'' "${meta_file}"' \
    '    ;;' \
    '  validate)' \
    '    if [[ "${scenario}" == symlink-race ]]; then' \
    '      rm -f -- "${CNTOOLS_ASSET_REGISTER_ASSET_FILE:?}"' \
    '      ln -s -- "${CNTOOLS_ASSET_REGISTER_OUTSIDE_FILE:?}" "${CNTOOLS_ASSET_REGISTER_ASSET_FILE}"' \
    '    fi' \
    '    printf '\''valid\n'\''' \
    '    ;;' \
    'esac' \
    > "${FAKE_BIN}/token-metadata-creator"
  chmod 0755 "${FAKE_BIN}/token-metadata-creator"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'printf '\''sed'\'' >> "${CNTOOLS_ASSET_REGISTER_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_REGISTER_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_ASSET_REGISTER_VECTOR_LOG:?}"' \
    '[[ "${CNTOOLS_ASSET_REGISTER_SCENARIO:?}" != bsd-sed-failure ]] || exit 1' \
    '[[ "${1:-}" == -i && $# == 3 ]] || exec "${CNTOOLS_ASSET_REGISTER_REAL_SED:?}" "$@"' \
    'expression="$2" target="$3" temporary="${target}.fixture-tmp"' \
    '"${CNTOOLS_ASSET_REGISTER_REAL_SED:?}" "${expression}" "${target}" > "${temporary}" || exit $?' \
    '"${CNTOOLS_ASSET_REGISTER_REAL_MV:?}" -- "${temporary}" "${target}"' \
    > "${FAKE_BIN}/sed"
  chmod 0755 "${FAKE_BIN}/sed"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'printf '\''file'\'' >> "${CNTOOLS_ASSET_REGISTER_VECTOR_LOG:?}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_REGISTER_VECTOR_LOG:?}"; done' \
    'printf '\''\n'\'' >> "${CNTOOLS_ASSET_REGISTER_VECTOR_LOG:?}"' \
    'case "${*: -1}" in' \
    '  */logo.png|*/large.png) printf '\''PNG image data\n'\'' ;;' \
    '  *) printf '\''ASCII text\n'\'' ;;' \
    'esac' \
    > "${FAKE_BIN}/file"
  chmod 0755 "${FAKE_BIN}/file"

  for network_command in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''%s'\'' "${0##*/}" >> "${CNTOOLS_ASSET_REGISTER_NETWORK_LOG:?}"' \
      'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${CNTOOLS_ASSET_REGISTER_NETWORK_LOG:?}"; done' \
      'printf '\''\n'\'' >> "${CNTOOLS_ASSET_REGISTER_NETWORK_LOG:?}"' \
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
# shellcheck source=../../scripts/common-helper-scripts/cntools/modules/root/advanced/asset/register/action.sh
. "${ACTION_SOURCE}"

# Public parity cases traverse the exact one-call controller route. This
# test-only adapter supplies a private context/result channel and invokes the
# shipped action through the production dispatcher without installed payload
# authority.
cntools_compatibility_dispatch_action() {
  local action_id="${1:-}" private_root="" context_file=""
  local result_file="" action_status=0 tmp_mode=""

  [[ "${action_id}" == advanced.asset.register && $# == 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  tmp_mode="$(file_mode "${TMP_DIR}")" || return 70
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/asset-register-test-dispatch.XXXXXXXX")" || return 70
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
  if [[ "${PUBLIC_ROUTE_ACTIVE:-N}" == Y &&
        ! -e "${CAPTURE_DONE_FILE:-/nonexistent}" ]]; then
    printf '__CNTOOLS_ASSET_REGISTER_END__\n'
    : > "${CAPTURE_DONE_FILE:?}"
  fi
  CAPTURE_ACTIVE=N
  return "${action_status}"
}

println() {
  local log_level="${1:-}" newline=$'\n' message=""
  local messages=()
  shift || true
  if [[ "${1:-}" == false && $# -gt 2 ]]; then
    newline=""
    shift
  elif [[ "${1:-}" == true && $# -gt 2 ]]; then
    shift
  fi
  for message in "$@"; do
    [[ -z "${message}" ]] || messages+=( "${message}" )
  done
  case "${log_level}" in
    ACTION|LOG) return 0 ;;
    OFF|DEBUG|INFO|ERROR) printf '%b%s' "${messages[@]}" "${newline}" ;;
    *) println INFO "${log_level}" "${messages[@]}" ;;
  esac
}

clear() {
  if [[ "${CAPTURE_ACTIVE:-N}" == Y && "${END_ON_CLEAR:-N}" == Y ]]; then
    printf '__CNTOOLS_ASSET_REGISTER_END__\n'
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

cmdAvailable() {
  [[ "${1:-}" == token-metadata-creator && $# == 1 ]] ||
    fail 'register command-availability probe changed'
  printf 'action:cmdAvailable:token-metadata-creator\n' >> "${EVENT_LOG:?}"
  [[ "${CNTOOLS_ASSET_REGISTER_SCENARIO:?}" != tool-missing ]]
}

selectPolicy() {
  [[ "${1:-}" == all && "${2:-}" == policy.skey &&
     "${3:-}" == policy.script && "${4:-}" == policy.id && $# == 4 ]] ||
    fail 'register policy-selection vector changed'
  printf 'action:selectPolicy:all:policy.skey:policy.script:policy.id\n' \
    >> "${EVENT_LOG:?}"
  case "${CNTOOLS_ASSET_REGISTER_SCENARIO:?}" in
    select-fail) return 1 ;;
    select-cancel) END_ON_CLEAR=Y; return 2 ;;
    *) policy_name=alpha; return 0 ;;
  esac
}

answer_value() {
  local scenario="$1" variable="$2"

  case "${variable}" in
    asset_name)
      case "${scenario}" in
        sorted-sequence) printf 'coin' ;;
        cancel-asset) printf '' ;;
        invalid-asset-char) printf '!' ;;
        invalid-asset-length) printf '123456789012345678901234567890123' ;;
        path-traversal) printf '../escaped' ;;
        *) printf 'Coin' ;;
      esac
      ;;
    meta_name)
      case "${scenario}" in
        invalid-name) printf '' ;;
        metadata-injection) printf 'name\", injected: \"yes' ;;
        success-local-options) printf 'Fancy Coin' ;;
        *) printf 'Coin Name' ;;
      esac
      ;;
    meta_desc)
      case "${scenario}" in
        invalid-description) printf '' ;;
        success-local-options) printf 'A useful token' ;;
        *) printf 'Coin description' ;;
      esac
      ;;
    meta_ticker)
      case "${scenario}" in
        invalid-ticker) printf 'AB' ;;
        success-local-options) printf 'FNC' ;;
        *) printf '' ;;
      esac
      ;;
    meta_url)
      case "${scenario}" in
        invalid-url) printf 'http://invalid.test' ;;
        success-local-options) printf 'https://example.test/token' ;;
        *) printf '' ;;
      esac
      ;;
    meta_decimals)
      case "${scenario}" in
        invalid-decimals) printf 'x' ;;
        success-local-options) printf '6' ;;
        *) printf '' ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

getAnswerAnyCust() {
  local output_variable="${1:-}" value=""
  shift || true
  case "${output_variable}" in
    asset_name|meta_name|meta_desc|meta_ticker|meta_url|meta_decimals) ;;
    *) fail "unexpected register answer variable: ${output_variable}" ;;
  esac
  value="$(answer_value "${CNTOOLS_ASSET_REGISTER_SCENARIO:?}" \
    "${output_variable}")"
  printf -v "${output_variable}" '%s' "${value}"
  if [[ "${CNTOOLS_ASSET_REGISTER_SCENARIO}" == cancel-asset &&
        "${output_variable}" == asset_name ]]; then
    printf 'action:answer-cancel:%s\n' "${output_variable}" >> "${EVENT_LOG:?}"
    return 1
  fi
  printf 'action:answer:%s:%q\n' "${output_variable}" "${value}" \
    >> "${EVENT_LOG:?}"
}

fileDialog() {
  [[ $# == 2 && "${2}" == "${TMP_DIR}/" ]] ||
    fail 'register logo dialog vector changed'
  printf 'action:fileDialog:%q:%q\n' "$1" "$2" >> "${EVENT_LOG:?}"
  case "${CNTOOLS_ASSET_REGISTER_SCENARIO:?}" in
    logo-missing) file="${REGISTER_LOGO_ROOT:?}/missing.png" ;;
    logo-large) file="${REGISTER_LOGO_ROOT:?}/large.png" ;;
    logo-type) file="${REGISTER_LOGO_ROOT:?}/not-png.txt" ;;
    success-local-options) file="${REGISTER_LOGO_ROOT:?}/logo.png" ;;
    *) file="" ;;
  esac
}

asciiToHex() {
  printf 'action:asciiToHex:%q\n' "${1:-}" >> "${EVENT_LOG:?}"
  case "${1:-}" in
    '') printf '' ;;
    Coin) printf '436f696e' ;;
    coin) printf '636f696e' ;;
    '../escaped') printf '2e2e2f65736361706564' ;;
    *) fail 'unexpected register asset for asciiToHex' ;;
  esac
}

isNumber() {
  [[ -n "${1:-}" && "${1}" =~ ^[0-9]+$ ]]
}

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}" menu="" option="" index=0
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
      if [[ "${menu}:${choice}" == asset:r ]]; then
        CAPTURE_ACTIVE=Y
        printf '__CNTOOLS_ASSET_REGISTER_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was unavailable in ${menu} menu"
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${CAPTURE_ACTIVE:-N}" == Y ]]; then
    printf '__CNTOOLS_ASSET_REGISTER_END__\n'
    CAPTURE_ACTIVE=N
  fi
  return 0
}

myExit() {
  local status="${1:-0}" message="${2:-}"
  printf 'exit:%s:%s\n' "${status}" "${message}" >> "${EVENT_LOG:?}"
  [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
    fail 'register public traversal did not consume every menu choice'
  exit "${status}"
}

scenario_mode() {
  case "$1" in
    tool-missing|success-local-options) printf 'LOCAL\n' ;;
    select-fail|success-light) printf 'LIGHT\n' ;;
    *) printf 'OFFLINE\n' ;;
  esac
}

scenario_subject() {
  local scenario="$1" policy_id="${POLICY_ID}" asset=""
  [[ "${scenario}" != subject-split ]] || policy_id='aaaa bbbb'
  asset="$(answer_value "${scenario}" asset_name)"
  case "${asset}" in
    '') printf '%s' "${policy_id}" ;;
    Coin) printf '%s436f696e' "${policy_id}" ;;
    coin) printf '%s636f696e' "${policy_id}" ;;
    '../escaped') printf '%s2e2e2f65736361706564' "${policy_id}" ;;
    *) printf '%s' "${policy_id}" ;;
  esac
}

scenario_meta_file() {
  printf '%s.json' "$(scenario_subject "$1")"
}

scenario_reaches_tool() {
  case "$1" in
    sorted-sequence|success-local-options|success-light|success-offline|\
    cancel-asset|logo-large|draft-failure|signing-failure|finalize-failure|\
    validate-failure|malformed-json|path-traversal|subject-split|\
    raw-diagnostic|symlink-race|bsd-sed-failure|metadata-injection)
      return 0 ;;
    *) return 1 ;;
  esac
}

scenario_success() {
  case "$1" in
    sorted-sequence|success-local-options|success-light|success-offline|\
    cancel-asset|logo-large|malformed-json|path-traversal|subject-split|\
    symlink-race|metadata-injection) return 0 ;;
    *) return 1 ;;
  esac
}

prepare_scenario() {
  local scenario="$1" runtime_root="$2" asset_root="$3"
  local policy_root="${asset_root}/alpha" asset_name="" asset_file=""
  local fixture_root="${runtime_root%/runtime}/fixtures"

  mkdir -p -- "${runtime_root}/tmp" "${runtime_root}/wallet" \
    "${runtime_root}/pool" "${runtime_root}/home" "${asset_root}" \
    "${fixture_root}"
  printf '\211PNG\r\n\032\nfixture\n' > "${fixture_root}/logo.png"
  printf 'not a png\n' > "${fixture_root}/not-png.txt"
  : > "${fixture_root}/large.png"
  dd if=/dev/zero of="${fixture_root}/large.png" bs=1 count=64001 \
    >/dev/null 2>&1
  [[ "${scenario}" != tool-missing && "${scenario}" != empty ]] || return 0

  mkdir -p -- "${policy_root}"
  printf '%s\n' "${SECRET_MARKER}" > "${policy_root}/policy.skey"
  printf '{"type":"sig"}\n' > "${policy_root}/policy.script"
  if [[ "${scenario}" == subject-split ]]; then
    printf 'aaaa bbbb\n' > "${policy_root}/policy.id"
  else
    printf '%s\n' "${POLICY_ID}" > "${policy_root}/policy.id"
  fi
  [[ "${scenario}" != select-fail && "${scenario}" != select-cancel ]] ||
    return 0

  asset_name="$(answer_value "${scenario}" asset_name)"
  if [[ "${scenario}" == path-traversal ]]; then
    asset_file="${asset_root}/escaped.asset"
  else
    asset_file="${policy_root}/${asset_name}.asset"
  fi
  case "${scenario}" in
    invalid-asset-char|invalid-asset-length) return 0 ;;
    malformed-json) printf '{malformed\n' > "${asset_file}" ;;
    *) printf '{"minted":7}\n' > "${asset_file}" ;;
  esac
  if [[ "${scenario}" == sorted-sequence ||
        "${scenario}" == bsd-sed-failure ]]; then
    printf '{"minted":2}\n' > "${policy_root}/A.asset"
    printf '{"minted":1}\n' > "${policy_root}/z.asset"
    printf '%s\n' \
      '{"minted":10,"metadata":{"name":"old","sequenceNumber":2}}' \
      > "${policy_root}/coin.asset"
  fi
  if [[ "${scenario}" == symlink-race ]]; then
    printf '{"minted":99,"concurrent":"outside"}\n' \
      > "${runtime_root}/outside.json"
  fi
}

normalize_file() {
  local source="$1" target="$2" runtime_root="$3"
  "${REAL_SED_PATH}" \
    -e "s#${runtime_root}#<runtime>#g" \
    -e "s#${TEST_ROOT}#<test>#g" \
    -e 's#^.*cntools\.sh: line [0-9][0-9]*:.*#<bash-diagnostic>#' \
    "${source}" > "${target}"
}

extract_action_output() {
  local source="$1" target="$2"
  [[ "$(grep -c '^__CNTOOLS_ASSET_REGISTER_BEGIN__$' "${source}" || true)" == 1 &&
     "$(grep -c '^__CNTOOLS_ASSET_REGISTER_END__$' "${source}" || true)" == 1 ]] ||
    fail 'register output capture markers changed'
  awk '
    $0 == "__CNTOOLS_ASSET_REGISTER_BEGIN__" { capture=1; next }
    $0 == "__CNTOOLS_ASSET_REGISTER_END__" { exit }
    capture { print }
  ' "${source}" > "${target}"
}

expected_fingerprints() {
  case "$1" in
    tool-missing) printf '%s\n' 'tool-missing|816178f2a778c44954c38b7bfe3aa3e4b22864f16a15c19706545df953f19787|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|cda9274cd388cef52ef5c91d8aec1720ebe2b7db02e58c6c630a08d2d8a3847a|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ;;
    empty) printf '%s\n' 'empty|3a9497a168aa07bffb0c40eef1bb5de2c57e9eae36a1c99e24f7af50f701f76f|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|38cb7a650dc9d08690ffc990e76f07a261a8b8a581cae92d18e81ca103642f86|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ;;
    select-fail) printf '%s\n' 'select-fail|7b1341b7d94a867500d0f18541c2d77d506664187f193ae676fa071c248c2646|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|8449ce959cd5565e0ffd8cf43f16a99bae8c18a99f19b94902a4385d427b684e|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ;;
    select-cancel) printf '%s\n' 'select-cancel|7b1341b7d94a867500d0f18541c2d77d506664187f193ae676fa071c248c2646|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|1a92fce734a75390ee2c6211b6dc3fd854f53b1c5254e771084f38fe7c4d2949|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ;;
    sorted-sequence) printf '%s\n' 'sorted-sequence|2a918bf6ad3460e3a1c06182df44dd216582e61927ec0ee7105058c615cef4a6|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|88d79ff8d420bdf151d5ae0b0b01a036c62c7f40690f500ecbcc1ba61ee9c81b|50f0fb5cfad400ae7af0ff8ad1a7ab63ad661b94832e57882f7db995d5624e7d' ;;
    success-local-options) printf '%s\n' 'success-local-options|1e1cccac485c5c04558b0dca0b8b228e31adc80a4d20ea29366cb2bed870bcea|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|e1d5186d84ac4bf3de23b32d2e964ce07269208a39e57ccadf37d05038a7db44|ce52e5f9e8bcaf94cfc6d40491e64455e87aa6b05c1b512034740a4853f2becf' ;;
    success-light) printf '%s\n' 'success-light|1e1cccac485c5c04558b0dca0b8b228e31adc80a4d20ea29366cb2bed870bcea|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|1374195c69f71c104d3b8f377f52c3cd475237411e0c4c29aaa5ed01a538d626|8dbc645f8b09dbf4065206105512bfd523e80d6e7069b52485274ebafe44150d' ;;
    success-offline) printf '%s\n' 'success-offline|1e1cccac485c5c04558b0dca0b8b228e31adc80a4d20ea29366cb2bed870bcea|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|9d78a9f232edc814e728fd71fe3a3a0c2f1eb119c9dc65c7f80b4d9cefc9715c|8dbc645f8b09dbf4065206105512bfd523e80d6e7069b52485274ebafe44150d' ;;
    cancel-asset) printf '%s\n' 'cancel-asset|c683446c88fdc0ca1cea4a5f95ccc0ab403ebe3948350177ddca7c87060cbd72|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|6aab54b555dfe84b8345ec5455a23b1187f8195fe97d046646b1ab756ca978b6|a40d77778058fdd7ebb827b6b1a1cf1e4628ab2d7ed0c7217c81df4fa9ae12fc' ;;
    invalid-asset-char) printf '%s\n' 'invalid-asset-char|3876599dea55f28256bd66770997c4eccc354829e296dfc5451fc46c9e8f8dc4|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|4a468b9bb53270dfc06680bae6d32f20c285b7ae5b0b4f82b4b1b8a3fd9542f8|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ;;
    invalid-asset-length) printf '%s\n' 'invalid-asset-length|4b8644694899cab931e0309aaa2a63774454d3d3305d503f1fc7bbbba3e43dea|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|58e00fa36ea460efa407f9ca4e211edf5c8b8a9550f5ca6e96891d4d9f55b221|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ;;
    invalid-name) printf '%s\n' 'invalid-name|9097aeb47c212555a1ca477d6473b07b2462eeb37589776260e42d5d10f75eb7|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|f821fe4fe145903c5b34df7cd901450059552aec9bb1c6edb9e3777179de4739|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ;;
    invalid-description) printf '%s\n' 'invalid-description|9af8b7fcb9e8c688fa3e4e29dd469e50e5ce9951271d4766f20f77575f232b90|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|0f6f66afe48c4bf60a37362219a8035cef61d8b713ff1b14c180fac543ec1491|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ;;
    invalid-ticker) printf '%s\n' 'invalid-ticker|9e8580e0656f4938e5e1160e8ce8f0553c4bfd456a18e7f8eedad09f2c6632f6|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|230793a45fb4e85530c95835cfba3936acb705a02a319c514ba0b035de9f7017|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ;;
    invalid-url) printf '%s\n' 'invalid-url|a7827d3a5f61b6a5d7e9a4ceb759928935872950f6361a097aa60cda2ed4818f|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|137083b30c0e5e8c208c1da6aa7105374c3fe868656d267bf11428358de2d6a6|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ;;
    invalid-decimals) printf '%s\n' 'invalid-decimals|50cbc8f3daf0691f82bf1f3786a1361e73012eac6db5f2af0b939c43b31223ae|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|f473ef7175606a4cae3d3db33448ee957f2af47ff36165e52361d6173948be77|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ;;
    logo-missing) printf '%s\n' 'logo-missing|83f71de567c71f7afb16004dada0ca9d346985253aa7d79c7aef3f799d7445de|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|b3cc9a63483aca938c58ca5689ef2c75f58fc794030b7832e54f5a7d00eaf6c1|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ;;
    logo-large) printf '%s\n' 'logo-large|1e1cccac485c5c04558b0dca0b8b228e31adc80a4d20ea29366cb2bed870bcea|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|9d78a9f232edc814e728fd71fe3a3a0c2f1eb119c9dc65c7f80b4d9cefc9715c|6616e6fd8d0c940c3f3929b8e68fac4030d1aeac05a406e29d8f20e7d43c5881' ;;
    logo-type) printf '%s\n' 'logo-type|ae631e039d9c9c754bc263092960a90c8e81fef3079badca5a703666bb273b63|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|b3cc9a63483aca938c58ca5689ef2c75f58fc794030b7832e54f5a7d00eaf6c1|5b80389554e7188a4c24507a43221f0f8122dcc96ee26a00ef4715a7b0d7e969' ;;
    draft-failure) printf '%s\n' 'draft-failure|a5c1741df68547462042ab0c82bfa201eefd094ea41310ec4a058f9f85af2022|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|9d78a9f232edc814e728fd71fe3a3a0c2f1eb119c9dc65c7f80b4d9cefc9715c|8ad5526e62da9819cfda23a51e6bc0967a3065e39d30e00e6795ed37d205493b' ;;
    signing-failure) printf '%s\n' 'signing-failure|33516940d4aa5bc299021f8f665f33aa519503faa12df7feff1684f2c0aea672|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|9d78a9f232edc814e728fd71fe3a3a0c2f1eb119c9dc65c7f80b4d9cefc9715c|738eb032dbbf860c63184901013e14f1f4f394b80101e0c3a5997039e748db6c' ;;
    finalize-failure) printf '%s\n' 'finalize-failure|9f51970b686f16d5ec45feaea25d9e49b5374c08ffa4cc14026d31d474746201|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|9d78a9f232edc814e728fd71fe3a3a0c2f1eb119c9dc65c7f80b4d9cefc9715c|8a9319e722eb726aab796d5910250fe6fd519d5bca96cc7ca42e989d1cfa0daa' ;;
    validate-failure) printf '%s\n' 'validate-failure|871040822fbbf90c1330a87b45420f0a48b5dd13f016fee4802a1a4e79862bec|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|9d78a9f232edc814e728fd71fe3a3a0c2f1eb119c9dc65c7f80b4d9cefc9715c|8dbc645f8b09dbf4065206105512bfd523e80d6e7069b52485274ebafe44150d' ;;
    malformed-json) printf '%s\n' 'malformed-json|8a86beeb6f9e813eb0b2f28d0a74cdf5704e677e7c8fcfec47f56c6e7b86e478|2d3027a344cf49f6d3f955ea3bea5d2b70eeb5cdf92cac31cc049568fc012cb0|9d78a9f232edc814e728fd71fe3a3a0c2f1eb119c9dc65c7f80b4d9cefc9715c|8dbc645f8b09dbf4065206105512bfd523e80d6e7069b52485274ebafe44150d' ;;
    path-traversal) printf '%s\n' 'path-traversal|ff2ae22cf1ffc852e2eddcb4cb52c2f8bdd91d443f3e76134a491e6421e76c9f|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|8a672c64ed6a15ed5f4aa1b4124b9e764af7d671ed08fd5f7f880e313c7bbe77|b77cd2ebc0be1cacd95f65d64d255c29bf5cf0c3cc672211d2b570884ecd1b35' ;;
    subject-split) printf '%s\n' 'subject-split|8a35620425e848c8c67576fee78a6846cd82e4f08ca0c7270248230818c41425|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|9d78a9f232edc814e728fd71fe3a3a0c2f1eb119c9dc65c7f80b4d9cefc9715c|823c71ac6e041ba6c2ab3d241e1d901644293451f37c8d06420724bed44c2296' ;;
    raw-diagnostic) printf '%s\n' 'raw-diagnostic|765c48958c51263196a330f96fc9659eabe3bd81fee3b3cc9bb56a91f49bf7a5|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|9d78a9f232edc814e728fd71fe3a3a0c2f1eb119c9dc65c7f80b4d9cefc9715c|8ad5526e62da9819cfda23a51e6bc0967a3065e39d30e00e6795ed37d205493b' ;;
    symlink-race) printf '%s\n' 'symlink-race|1e1cccac485c5c04558b0dca0b8b228e31adc80a4d20ea29366cb2bed870bcea|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|9d78a9f232edc814e728fd71fe3a3a0c2f1eb119c9dc65c7f80b4d9cefc9715c|8dbc645f8b09dbf4065206105512bfd523e80d6e7069b52485274ebafe44150d' ;;
    bsd-sed-failure) printf '%s\n' 'bsd-sed-failure|657d72f6493211e4e0254b439e97d03408d6704f654481d04143fdc28f02fa7e|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|9d78a9f232edc814e728fd71fe3a3a0c2f1eb119c9dc65c7f80b4d9cefc9715c|6322861c781dcf1b197b4e4d1f1649a166a37e05315207386fbf073d26ff625e' ;;
    metadata-injection) printf '%s\n' 'metadata-injection|1e1cccac485c5c04558b0dca0b8b228e31adc80a4d20ea29366cb2bed870bcea|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|d1e6ac44940843f9ec411a055a987169a39359cf374d00c697320d5622aa74b8|33cdc2609f9722a14e24a30c02ca694e61bbba9899d4592f682f10838a8486c2' ;;
    *) return 1 ;;
  esac
}

assert_navigation_semantics() {
  local scenario="$1" mode="$2" events="$3" waits=1
  [[ "$(grep -c '^menu:main:a$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:advanced:a$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:asset:r$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:asset:h$' "${events}" || true)" == 1 &&
     "$(grep -c '^menu:main:q$' "${events}" || true)" == 1 ]] ||
    fail "${scenario} menu navigation changed"
  [[ "${scenario}" != select-cancel ]] || waits=0
  [[ "$(grep -c '^action:waitToProceed$' "${events}" || true)" == "${waits}" ]] ||
    fail "${scenario} wait behavior changed"
  case "${mode}" in
    LOCAL)
      [[ "$(grep -c '^runtime:getNodeMetrics$' "${events}" || true)" == 2 &&
         "$(grep -c '^runtime:getPriceInfo$' "${events}" || true)" == 2 &&
         "$(grep -c '^runtime:updateProtocolParams$' "${events}" || true)" == 2 ]] ||
        fail "${scenario} LOCAL runtime behavior changed"
      ;;
    LIGHT)
      [[ "$(grep -c '^runtime:getNodeMetrics$' "${events}" || true)" == 0 &&
         "$(grep -c '^runtime:getPriceInfo$' "${events}" || true)" == 2 &&
         "$(grep -c '^runtime:updateProtocolParams$' "${events}" || true)" == 2 ]] ||
        fail "${scenario} LIGHT runtime behavior changed"
      ;;
    OFFLINE)
      ! grep -Eq '^runtime:(getNodeMetrics|getPriceInfo|updateProtocolParams)$' \
        "${events}" || fail "${scenario} OFFLINE runtime behavior changed"
      ;;
  esac
}

filter_allowed_mutations() {
  local scenario="$1" source="$2" target="$3" subject=""
  subject="$(scenario_subject "${scenario}")"
  case "${scenario}" in
    subject-split)
      grep -Ev '^(f|l)[[:space:]]+asset/alpha/(aaaa\\ bbbb436f696e\.json|Coin\.asset)([[:space:]]|$)' \
        "${source}" > "${target}"
      ;;
    signing-failure|finalize-failure|validate-failure|sorted-sequence|\
    success-local-options|success-light|success-offline|cancel-asset|logo-large|\
    malformed-json|metadata-injection|bsd-sed-failure)
      grep -Ev "^(f|l)[[:space:]]+asset/alpha/(${subject// /\\ }\\.json|Coin\\.asset|coin\\.asset|\\.asset)([[:space:]]|$)" \
        "${source}" > "${target}"
      ;;
    path-traversal)
      grep -Ev "^(f|l)[[:space:]]+(asset/alpha/${subject}\\.json|asset/escaped\\.asset)([[:space:]]|$)" \
        "${source}" > "${target}"
      ;;
    symlink-race)
      grep -Ev "^(f|l)[[:space:]]+(asset/alpha/${subject}\\.json|asset/alpha/Coin\\.asset|outside\\.json)([[:space:]]|$)" \
        "${source}" > "${target}"
      ;;
    *) cp -- "${source}" "${target}" ;;
  esac
}

assert_mutation_contract() {
  local scenario="$1" runtime_root="$2" before="$3" after="$4"
  local before_filtered="${before}.filtered" after_filtered="${after}.filtered"
  local policy_root="${runtime_root}/asset/alpha" subject="" meta_file=""
  local asset_file="${policy_root}/Coin.asset" expected_phase=""

  subject="$(scenario_subject "${scenario}")"
  meta_file="${policy_root}/$(scenario_meta_file "${scenario}")"
  [[ "${scenario}" != path-traversal ]] || asset_file="${runtime_root}/asset/escaped.asset"
  [[ "${scenario}" != sorted-sequence && "${scenario}" != bsd-sed-failure ]] ||
    asset_file="${policy_root}/coin.asset"
  [[ "${scenario}" != cancel-asset ]] || asset_file="${policy_root}/.asset"

  case "${scenario}" in
    signing-failure|bsd-sed-failure) expected_phase=draft ;;
    finalize-failure) expected_phase=signed ;;
    validate-failure|sorted-sequence|success-local-options|success-light|\
    success-offline|cancel-asset|logo-large|malformed-json|path-traversal|\
    subject-split|symlink-race|metadata-injection)
      expected_phase=finalized
      ;;
  esac
  if [[ -n "${expected_phase}" ]]; then
    [[ -f "${meta_file}" && ! -L "${meta_file}" &&
       "$(file_mode "${meta_file}")" == 644 &&
       "$(jq -r '.phase' "${meta_file}")" == "${expected_phase}" ]] ||
      fail "${scenario} registry artifact residue changed"
    if [[ "${scenario}" == sorted-sequence ]]; then
      [[ "$(jq -r '.sequenceNumber' "${meta_file}")" == 3 ]] ||
        fail 'registry sequence-number increment changed'
    fi
  fi
  if scenario_success "${scenario}"; then
    if [[ "${scenario}" == malformed-json ]]; then
      [[ -f "${asset_file}" && "$(wc -c < "${asset_file}" | tr -d '[:space:]')" == 1 &&
         -z "$(< "${asset_file}")" ]] ||
        fail 'malformed JSON newline-only truncation defect changed'
    elif [[ "${scenario}" == symlink-race ]]; then
      [[ -L "${asset_file}" && "$(readlink "${asset_file}")" == \
         "${runtime_root}/outside.json" &&
         "$(jq -r '.metadata.name' "${runtime_root}/outside.json")" == \
         'Coin Name' ]] || fail 'asset-file symlink race defect changed'
    else
      [[ -f "${asset_file}" &&
         "$(file_mode "${asset_file}")" == 644 &&
         "$(jq -r '.metadata.name' "${asset_file}")" != null ]] ||
        fail "${scenario} .asset metadata update changed"
      if [[ "${scenario}" == sorted-sequence ]]; then
        [[ "$(jq -r '.metadata.sequenceNumber' "${asset_file}")" == 3 ]] ||
          fail 'sorted asset .asset sequence increment changed'
      fi
      if [[ "${scenario}" == success-local-options ]]; then
        [[ "$(jq -r '.metadata.ticker' "${asset_file}")" == FNC &&
           "$(jq -r '.metadata.url' "${asset_file}")" == \
           'https://example.test/token' &&
           "$(jq -r '.metadata.logo' "${asset_file}")" == */logo.png &&
           "$(jq -r '.metadata | has("decimals")' "${asset_file}")" == false ]] ||
          fail 'valid optional metadata/.asset omission contract changed'
      fi
    fi
  fi
  filter_allowed_mutations "${scenario}" "${before}" "${before_filtered}"
  filter_allowed_mutations "${scenario}" "${after}" "${after_filtered}"
  assert_files_equal "${after_filtered}" "${before_filtered}" \
    "${scenario} exact persistent mutation allowlist"
}

assert_semantic_contract() {
  local scenario="$1" stdout_file="$2" stderr_file="$3" events="$4" vectors="$5"

  [[ ! -s "${stderr_file}" ]] || {
    [[ "${scenario}" == malformed-json ]] ||
      fail "${scenario} unexpectedly wrote stderr"
  }
  case "${scenario}" in
    tool-missing) grep -Fq 'offchain-metadata-tools' "${stdout_file}" || fail 'tool guidance changed' ;;
    empty) grep -Fq 'No policies found!' "${stdout_file}" || fail 'empty policy message changed' ;;
    sorted-sequence)
      grep -Fq 'Previous metadata registration found:' "${stdout_file}" || fail 'previous metadata display changed'
      grep -Fq 'Updating sequence number to 3' "${stdout_file}" || fail 'sequence increment changed'
      awk -v policy="${POLICY_ID}" '
        index($0, policy ".A") { a=NR }
        index($0, policy ".coin") { coin=NR }
        index($0, policy ".z") { z=NR }
        END { exit !(a && coin && z && a < coin && coin < z) }
      ' "${stdout_file}" || fail 'existing asset display ordering changed'
      ;;
    cancel-asset)
      grep -Fq 'action:answer-cancel:asset_name' "${events}" || fail 'ignored asset prompt cancellation changed'
      grep -Fq 'token-metadata-creator' "${vectors}" || fail 'cancel no longer falls through to tool execution'
      ;;
    raw-diagnostic)
      LC_ALL=C grep -q $'\033\[31mOWNED' "${stdout_file}" ||
        fail 'raw terminal-escape diagnostic defect changed'
      ;;
    subject-split)
      grep -Fq $'token-metadata-creator\tentry\taaaa\tbbbb436f696e\t-a' "${vectors}" ||
        fail 'unquoted subject argv splitting defect changed'
      ;;
    metadata-injection)
      [[ "$(jq -r '.metadata.injected' "${TEST_CASE_ASSET_FILE}")" == yes ]] ||
        fail 'metadata jq-filter injection defect changed'
      ;;
  esac
  for checked in "${stdout_file}" "${stderr_file}" "${events}" "${vectors}"; do
    ! grep -Fq "${SECRET_MARKER}" "${checked}" ||
      fail "${scenario} exposed signing-key content"
  done
}

run_case() {
  local scenario="$1" mode="" case_root=""
  local runtime_root="" asset_root=""
  local policy_root="${asset_root}/alpha" capture_root="${case_root}/capture"
  local full_stdout="${capture_root}/full.stdout" action_raw="${capture_root}/action.raw"
  local stdout_file="${capture_root}/stdout" stderr_raw="${capture_root}/stderr.raw"
  local stderr_file="${capture_root}/stderr" events_raw="${capture_root}/events.raw"
  local events="${capture_root}/events" vectors_raw="${capture_root}/vectors.raw"
  local vectors="${capture_root}/vectors" network="${capture_root}/network"
  local before="${capture_root}/before.tree" after="${capture_root}/after.tree"
  local expected="" observed="" subject="" meta_file="" asset_name="" asset_file=""
  local status=0

  case_root="${TEST_ROOT}/cases/${scenario}"
  runtime_root="${case_root}/runtime"
  asset_root="${runtime_root}/asset"
  policy_root="${asset_root}/alpha"
  capture_root="${case_root}/capture"
  full_stdout="${capture_root}/full.stdout"
  action_raw="${capture_root}/action.raw"
  stdout_file="${capture_root}/stdout"
  stderr_raw="${capture_root}/stderr.raw"
  stderr_file="${capture_root}/stderr"
  events_raw="${capture_root}/events.raw"
  events="${capture_root}/events"
  vectors_raw="${capture_root}/vectors.raw"
  vectors="${capture_root}/vectors"
  network="${capture_root}/network"
  before="${capture_root}/before.tree"
  after="${capture_root}/after.tree"
  mode="$(scenario_mode "${scenario}")"
  mkdir -p -- "${capture_root}"
  prepare_scenario "${scenario}" "${runtime_root}" "${asset_root}"
  subject="$(scenario_subject "${scenario}")"
  meta_file="$(scenario_meta_file "${scenario}")"
  asset_name="$(answer_value "${scenario}" asset_name)"
  if [[ "${scenario}" == path-traversal ]]; then
    asset_file="${asset_root}/escaped.asset"
  else
    asset_file="${policy_root}/${asset_name}.asset"
  fi
  tree_snapshot "${runtime_root}" "${before}" || fail "${scenario} pre-snapshot failed"
  : > "${events_raw}"; : > "${vectors_raw}"; : > "${network}"

  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    export CNTOOLS_ASSET_REGISTER_SCENARIO="${scenario}"
    export CNTOOLS_ASSET_REGISTER_VECTOR_LOG="${vectors_raw}"
    export CNTOOLS_ASSET_REGISTER_NETWORK_LOG="${network}"
    export CNTOOLS_ASSET_REGISTER_REAL_SED="${REAL_SED_PATH}"
    export CNTOOLS_ASSET_REGISTER_REAL_MV="${REAL_MV_PATH}"
    export CNTOOLS_ASSET_REGISTER_REAL_JQ="${REAL_JQ_PATH}"
    export CNTOOLS_ASSET_REGISTER_META_FILE="${meta_file}"
    export CNTOOLS_ASSET_REGISTER_SUBJECT="${subject}"
    export CNTOOLS_ASSET_REGISTER_ASSET_FILE="${asset_file}"
    export CNTOOLS_ASSET_REGISTER_OUTSIDE_FILE="${runtime_root}/outside.json"
    PATH="${FAKE_BIN}:${BASE_PATH}"
    export PATH
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    ASSET_FOLDER="${asset_root}"
    ASSET_POLICY_SK_FILENAME=policy.skey
    ASSET_POLICY_SCRIPT_FILENAME=policy.script
    ASSET_POLICY_ID_FILENAME=policy.id
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=characterized
    NETWORK_NAME=Preview
    NWMAGIC=42
    ADVANCED_MODE=true
    ENABLE_DIALOG=false
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    price_now="" slotnum=1000
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${events_raw}"
    REGISTER_LOGO_ROOT="${case_root}/fixtures"
    CAPTURE_ACTIVE=N END_ON_CLEAR=N
    unset asset_name meta_name meta_desc meta_ticker meta_url meta_decimals file
    CHOICES=(a a r h q)
    CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_raw}"; then status=0; else status=$?; fi
  [[ "${status}" == 0 ]] || fail "${scenario} traversal returned ${status}"

  extract_action_output "${full_stdout}" "${action_raw}"
  normalize_file "${action_raw}" "${stdout_file}" "${runtime_root}"
  normalize_file "${stderr_raw}" "${stderr_file}" "${runtime_root}"
  normalize_file "${events_raw}" "${events}" "${runtime_root}"
  normalize_file "${vectors_raw}" "${vectors}" "${runtime_root}"
  assert_navigation_semantics "${scenario}" "${mode}" "${events}"
  TEST_CASE_ASSET_FILE="${asset_file}"
  assert_semantic_contract "${scenario}" "${stdout_file}" "${stderr_file}" \
    "${events}" "${vectors}"
  [[ ! -s "${network}" ]] || fail "${scenario} attempted network access"

  expected="$(expected_fingerprints "${scenario}")" ||
    fail "missing frozen fingerprints for ${scenario}"
  IFS='|' read -r _ expected_stdout expected_stderr expected_events expected_vectors \
    <<< "${expected}"
  for observed_pair in \
    "stdout:${stdout_file}:${expected_stdout}" \
    "stderr:${stderr_file}:${expected_stderr}" \
    "events:${events}:${expected_events}" \
    "vectors:${vectors}:${expected_vectors}"; do
    IFS=: read -r label observed expected_hash <<< "${observed_pair}"
    [[ "$(file_hash "${observed}")" == "${expected_hash}" ]] ||
      fail "${scenario} exact normalized ${label} changed"
  done

  tree_snapshot "${runtime_root}" "${after}" || fail "${scenario} post-snapshot failed"
  assert_mutation_contract "${scenario}" "${runtime_root}" "${before}" "${after}"
}

write_fake_commands

legacy_fingerprint_record="${TEST_ROOT}/asset-register-legacy-fingerprints"
: > "${legacy_fingerprint_record}"
for scenario in \
  tool-missing empty select-fail select-cancel sorted-sequence \
  success-local-options success-light success-offline cancel-asset \
  invalid-asset-char invalid-asset-length invalid-name invalid-description \
  invalid-ticker invalid-url invalid-decimals logo-missing logo-large logo-type \
  draft-failure signing-failure finalize-failure validate-failure malformed-json \
  path-traversal subject-split raw-diagnostic symlink-race bsd-sed-failure \
  metadata-injection; do
  expected_fingerprints "${scenario}" >> "${legacy_fingerprint_record}" ||
    fail "missing frozen legacy fingerprint record for ${scenario}"
done
[[ "$(wc -l < "${legacy_fingerprint_record}" | tr -d '[:space:]')" == 30 ]] ||
  fail 'legacy fingerprint record count changed'
[[ "$(file_hash "${legacy_fingerprint_record}")" == \
   d75e33273bcb7125656b2fc706dcf59179e42aa592f9cda95ca70f9a9894975b ]] ||
  fail 'legacy fingerprint record changed'

# Freeze the exact one-call public route and removal of the unsafe inline body.
register_arm="${TEST_ROOT}/register-arm"
expected_register_arm="${TEST_ROOT}/expected-register-arm"
awk '
  /^[[:space:]]+register-asset\)/ { capture = 1 }
  capture { print }
  capture && /^[[:space:]]+;;/ { exit }
' "${CNTOOLS_SCRIPT}" > "${register_arm}"
printf '%s\n' \
  '                  register-asset)' \
  '                    cntools_compatibility_dispatch_action advanced.asset.register' \
  '                    action_status=$?' \
  '                    case "${action_status}" in' \
  '                      0) continue ;;' \
  '                      20|21) break 2 ;;' \
  '                      22) myExit 0 "CNTools closed!" ;;' \
  '                      *) waitToProceed; continue ;;' \
  '                    esac' \
  '                    ;; ###################################################################' \
  > "${expected_register_arm}"
assert_files_equal "${register_arm}" "${expected_register_arm}" \
  'public register arm exact one-call/outcome map'
[[ "$(grep -c 'cntools_compatibility_dispatch_action advanced.asset.register' \
      "${CNTOOLS_SCRIPT}" || true)" == 1 ]] ||
  fail 'public register dispatch call is missing or duplicated'
if grep -Eq 'token-metadata-creator|assetFileJSON|selectPolicy|policy_sk_file|meta_name' \
    "${register_arm}"; then
  fail 'former inline register implementation remains in the public arm'
fi
grep -Fq 'Stage 4 hardened compatibility action' "${ACTION_SOURCE}" ||
  fail 'hardened register action marker is unavailable'
if grep -Fq 'Stage 3 shadow mode' "${ACTION_SOURCE}"; then
  fail 'register action retained the inert Stage 3 marker'
fi

direct_scenario_to_legacy() {
  case "$1" in
    direct-success-local-options) printf 'success-local-options' ;;
    direct-success-light) printf 'success-light' ;;
    direct-success-offline|direct-new-asset) printf 'success-offline' ;;
    direct-cancel-asset) printf 'cancel-asset' ;;
    direct-invalid-asset|direct-traversal) printf 'invalid-asset-char' ;;
    direct-malformed-json) printf 'malformed-json' ;;
    direct-preexisting-registry) printf 'success-offline' ;;
    direct-draft-failure|direct-raw-diagnostic) printf 'draft-failure' ;;
    direct-signing-failure) printf 'signing-failure' ;;
    direct-finalize-failure) printf 'finalize-failure' ;;
    direct-validate-failure) printf 'validate-failure' ;;
    *) printf 'success-offline' ;;
  esac
}

direct_expected_status() {
  case "$1" in
    direct-malformed-json|direct-extra-output|direct-arbitrary-output|direct-malformed-output|\
    direct-backup-tamper|direct-cancel-meta-release|\
    direct-policy-race|direct-asset-race|direct-publish-first-failure|\
    direct-publish-second-failure|direct-signal-between|\
    direct-context-mismatch)
      printf '70\n'
      ;;
    *) printf '0\n' ;;
  esac
}

direct_expected_success() {
  case "$1" in
    direct-success-local-options|direct-success-light|direct-success-offline|\
    direct-new-asset|direct-release-failure|\
    direct-boundary-signal) return 0 ;;
    *) return 1 ;;
  esac
}

direct_answer_value() {
  local scenario="$1" variable="$2"

  case "${variable}" in
    asset_register_asset_name)
      case "${scenario}" in
        direct-cancel-asset) printf '' ;;
        direct-invalid-asset) printf 'bad/name' ;;
        direct-traversal) printf '../escape' ;;
        direct-new-asset) printf 'NewCoin' ;;
        *) printf 'Coin' ;;
      esac
      ;;
    asset_register_meta_name)
      case "${scenario}" in
        direct-success-local-options) printf 'Fancy Coin' ;;
        *) printf 'Coin Name' ;;
      esac
      ;;
    asset_register_meta_desc)
      case "${scenario}" in
        direct-success-local-options) printf 'A useful token' ;;
        *) printf 'Coin description' ;;
      esac
      ;;
    asset_register_meta_ticker)
      [[ "${scenario}" != direct-success-local-options ]] || printf FNC
      ;;
    asset_register_meta_url)
      [[ "${scenario}" != direct-success-local-options ]] ||
        printf 'https://example.test/token'
      ;;
    asset_register_meta_decimals)
      [[ "${scenario}" != direct-success-local-options ]] || printf 6
      ;;
    *) return 1 ;;
  esac
}

prepare_direct_scenario() {
  local scenario="$1" runtime_root="$2" asset_root="$3"
  local policy_root="${asset_root}/alpha"

  mkdir -p -- "${runtime_root}/home" "${runtime_root}/tmp" \
    "${asset_root}" "${policy_root}"
  chmod 0755 "${asset_root}" "${policy_root}"
  printf '%s\n' "${SECRET_MARKER}" > "${policy_root}/policy.skey"
  printf '{"type":"sig"}\n' > "${policy_root}/policy.script"
  printf '%s\n' "${POLICY_ID}" > "${policy_root}/policy.id"
  chmod 0600 "${policy_root}/policy.skey"
  chmod 0644 "${policy_root}/policy.script" "${policy_root}/policy.id"
  if [[ "${scenario}" != direct-new-asset ]]; then
    if [[ "${scenario}" == direct-malformed-json ]]; then
      printf '{malformed\n' > "${policy_root}/Coin.asset"
    else
      printf '%s\n' \
        '{"minted":7,"metadata":{"name":"old","sequenceNumber":2}}' \
        > "${policy_root}/Coin.asset"
    fi
  fi
  if [[ "${scenario}" == direct-preexisting-registry ]]; then
    printf '{"competitor":true}\n' > \
      "${policy_root}/${POLICY_ID}436f696e.json"
  fi
  printf '\211PNG\r\n\032\nfixture\n' > "${runtime_root}/logo.png"
}

write_direct_fake_token_tool() {
  local target="$1"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_REGISTER_DIRECT_SCENARIO:?}"' \
    'log="${CNTOOLS_ASSET_REGISTER_DIRECT_VECTOR_LOG:?}"' \
    'subject="${CNTOOLS_ASSET_REGISTER_DIRECT_SUBJECT:?}" expected="${subject}.json"' \
    'printf '\''token-metadata-creator'\'' >> "${log}"' \
    'for argument in "$@"; do printf '\''\t%q'\'' "${argument}" >> "${log}"; done' \
    'printf '\''\n'\'' >> "${log}"' \
    'phase=""' \
    'if [[ " $* " == *" --init "* ]]; then phase=draft' \
    'elif [[ "${1:-}" == entry && " $* " == *" -a "* ]]; then phase=sign' \
    'elif [[ "${1:-}" == entry && " $* " == *" --finalize "* ]]; then phase=finalize' \
    'elif [[ "${1:-}" == validate ]]; then phase=validate' \
    'else exit 96; fi' \
    'case "${scenario}:${phase}" in' \
    '  direct-draft-failure:draft|direct-raw-diagnostic:draft)' \
    '    printf '\''\\033[31mOWNED diagnostic\n'\'' >&2; exit 31 ;;' \
    '  direct-signing-failure:sign) exit 32 ;;' \
    '  direct-finalize-failure:finalize) exit 33 ;;' \
    '  direct-validate-failure:validate) exit 34 ;;' \
    'esac' \
    'sequence=0' \
    '[[ ! -f "${expected}" ]] || sequence="$(jq -r '\''.sequenceNumber // 0'\'' "${expected}")"' \
    'case "${phase}" in' \
    '  draft|sign|finalize)' \
    '    printf '\''{"subject":"%s","sequenceNumber":%s,"phase":"%s"}\n'\'' "${subject}" "${sequence}" "${phase}" > "${expected}"' \
    '    if [[ "${scenario}" == direct-extra-output && "${phase}" == draft ]]; then printf extra > unexpected.txt; fi' \
    '    if [[ "${scenario}" == direct-policy-race && "${phase}" == finalize ]]; then printf '\''{"changed":true}\n'\'' > "${CNTOOLS_ASSET_REGISTER_DIRECT_POLICY_SCRIPT:?}"; fi' \
    '    if [[ "${scenario}" == direct-asset-race && "${phase}" == finalize ]]; then printf '\''{"concurrent":true}\n'\'' > "${CNTOOLS_ASSET_REGISTER_DIRECT_ASSET_FILE:?}"; fi' \
    '    if [[ "${scenario}" == direct-backup-tamper && "${phase}" == finalize ]]; then printf '\''tampered backup\n'\'' > original.asset; fi' \
    '    if [[ "${scenario}" == direct-malformed-output && "${phase}" == draft ]]; then printf '\''{bad\n'\'' > "${expected}"; fi' \
    '    if [[ "${scenario}" == direct-arbitrary-output && "${phase}" == draft ]]; then printf '\''../outside.json\n'\''; else printf '\''%s\n'\'' "${expected}"; fi' \
    '    ;;' \
    '  validate) printf '\''%s\n'\'' "${expected}" ;;' \
    'esac' \
    > "${target}"
  chmod 0755 "${target}"
}

write_direct_fault_tools() {
  local directory="$1"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_REGISTER_DIRECT_SCENARIO:?}"' \
    'source_path="${@: -2:1}" destination="${@: -1}"' \
    'case "${scenario}" in' \
    '  direct-publish-first-failure)' \
    '    [[ "${source_path}" != */.cntools-register.*/*.json || "${destination}" != */asset/alpha/*.json ]] || exit 41' \
    '    ;;' \
    '  direct-publish-second-failure)' \
    '    [[ "${source_path}" != */.cntools-register.*/asset.next || "${destination}" != */asset/alpha/Coin.asset ]] || exit 42' \
    '    ;;' \
    'esac' \
    '"${CNTOOLS_ASSET_REGISTER_REAL_MV:?}" "$@" || exit $?' \
    'if [[ "${scenario}" == direct-signal-between && "${source_path}" == */.cntools-register.*/*.json && "${destination}" == */asset/alpha/*.json ]]; then' \
    '  kill -TERM "${PPID}"' \
    'fi' \
    > "${directory}/mv"
  chmod 0755 "${directory}/mv"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'scenario="${CNTOOLS_ASSET_REGISTER_DIRECT_SCENARIO:?}"' \
    'source_path="${@: -2:1}" destination="${@: -1}"' \
    'if [[ "${scenario}" == direct-publish-first-failure && "${source_path}" == */.cntools-register.*/*.json && "${destination}" == */asset/alpha/*.json ]]; then exit 41; fi' \
    '"${CNTOOLS_ASSET_REGISTER_REAL_LN:?}" "$@" || exit $?' \
    'if [[ "${scenario}" == direct-signal-between && "${source_path}" == */.cntools-register.*/*.json && "${destination}" == */asset/alpha/*.json ]]; then kill -TERM "${PPID}"; fi' \
    > "${directory}/ln"
  chmod 0755 "${directory}/ln"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'target="${@: -1}" marker="${CNTOOLS_ASSET_REGISTER_RELEASE_MARKER:?}"' \
    'if [[ ( "${CNTOOLS_ASSET_REGISTER_DIRECT_SCENARIO:?}" == direct-release-failure || "${CNTOOLS_ASSET_REGISTER_DIRECT_SCENARIO}" == direct-cancel-meta-release ) && "${target}" == */.cntools-register.lock && ! -e "${marker}" ]]; then' \
    '  : > "${marker}"' \
    '  exit 43' \
    'fi' \
    'exec "${CNTOOLS_ASSET_REGISTER_REAL_RMDIR:?}" "$@"' \
    > "${directory}/rmdir"
  chmod 0755 "${directory}/rmdir"

}

run_direct_case() {
  local scenario="$1" mode="$2" case_root="" runtime_root="" asset_root=""
  local policy_root="" private_root="" context_file="" result_file=""
  local capture_root="" stdout_file="" stderr_file="" event_log=""
  local vector_log="" before="" after="" direct_bin=""
  local expected_status=0 status=0 asset_name="" asset_file="" subject=""
  local original_asset_hash="" original_policy_hash=""
  local wait_count=0 expected_waits=1 expected_tool_calls=4

  case_root="${TEST_ROOT}/direct/${scenario}"
  runtime_root="${case_root}/runtime"
  asset_root="${runtime_root}/asset"
  policy_root="${asset_root}/alpha"
  private_root="${case_root}/private"
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  capture_root="${case_root}/capture"
  stdout_file="${capture_root}/stdout"
  stderr_file="${capture_root}/stderr"
  event_log="${capture_root}/events"
  vector_log="${capture_root}/vectors"
  before="${capture_root}/before.tree"
  after="${capture_root}/after.tree"
  direct_bin="${case_root}/bin"
  mkdir -p -- "${capture_root}" "${private_root}" "${direct_bin}"
  chmod 0700 "${private_root}"
  prepare_direct_scenario "${scenario}" "${runtime_root}" "${asset_root}"
  write_direct_fake_token_tool "${direct_bin}/token-metadata-creator"
  write_direct_fault_tools "${direct_bin}"
  write_context "${context_file}" "${mode}" "${runtime_root}/home"
  expected_status="$(direct_expected_status "${scenario}")"
  asset_name="$(direct_answer_value "${scenario}" asset_register_asset_name)"
  [[ "${scenario}" != direct-new-asset ]] || asset_name=NewCoin
  subject="${POLICY_ID}"
  [[ -z "${asset_name}" ]] || case "${asset_name}" in
    Coin) subject+='436f696e' ;;
    NewCoin) subject+='4e6577436f696e' ;;
  esac
  asset_file="${policy_root}/${asset_name}.asset"
  original_policy_hash="$(file_hash "${policy_root}/policy.script")"
  [[ ! -f "${asset_file}" ]] || original_asset_hash="$(file_hash "${asset_file}")"
  tree_snapshot "${runtime_root}" "${before}" || fail "${scenario} direct pre-snapshot failed"
  : > "${event_log}"; : > "${vector_log}"

  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    export CNTOOLS_ASSET_REGISTER_DIRECT_SCENARIO="${scenario}"
    export CNTOOLS_ASSET_REGISTER_DIRECT_VECTOR_LOG="${vector_log}"
    export CNTOOLS_ASSET_REGISTER_DIRECT_SUBJECT="${subject}"
    export CNTOOLS_ASSET_REGISTER_DIRECT_POLICY_SCRIPT="${policy_root}/policy.script"
    export CNTOOLS_ASSET_REGISTER_DIRECT_ASSET_FILE="${asset_file}"
    export CNTOOLS_ASSET_REGISTER_REAL_MV="${REAL_MV_PATH}"
    export CNTOOLS_ASSET_REGISTER_REAL_LN="${REAL_LN_PATH}"
    export CNTOOLS_ASSET_REGISTER_REAL_RMDIR="${REAL_RMDIR_PATH}"
    export CNTOOLS_ASSET_REGISTER_RELEASE_MARKER="${capture_root}/release.marker"
    PATH="${direct_bin}:${FAKE_BIN}:${BASE_PATH}"
    export PATH
    HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    ASSET_FOLDER="${asset_root}"
    ASSET_POLICY_SK_FILENAME=policy.skey
    ASSET_POLICY_SCRIPT_FILENAME=policy.script
    ASSET_POLICY_ID_FILENAME=policy.id
    CNTOOLS_MODE="${mode}"
    [[ "${scenario}" != direct-context-mismatch ]] || CNTOOLS_MODE=local
    NWMAGIC=42
    FG_RED="" FG_YELLOW="" FG_GREEN="" FG_LBLUE="" FG_LGRAY="" NC=""
    EVENT_LOG="${event_log}"
    DIRECT_SCENARIO="${scenario}"
    DIRECT_ACTIVE=Y
    if [[ "${scenario}" == direct-tool-shadow ]]; then
      function token-metadata-creator { return 99; }
    fi
    if [[ "${scenario}" == direct-boundary-signal ]]; then
      trap 'if [[ "${BASH_COMMAND}" == "_cntools_action_advanced_asset_register_postcommit_cleanup" ]]; then trap - DEBUG; kill -TERM "${BASHPID}"; fi' DEBUG
      set -T
    fi
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  [[ "${status}" == "${expected_status}" ]] ||
    fail "${scenario} returned ${status}, expected ${expected_status}"
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] ||
    fail "${scenario} unexpectedly produced a result"
  ! grep -Fq "${SECRET_MARKER}" "${stdout_file}" "${stderr_file}" \
    "${event_log}" "${vector_log}" || fail "${scenario} exposed signing-key content"
  if [[ "${scenario}" == direct-raw-diagnostic ]]; then
    ! grep -aEq 'OWNED|\\033|\x1b' "${stdout_file}" "${stderr_file}" ||
      fail 'raw tool diagnostic reached a terminal stream'
  fi
  wait_count="$(grep -c '^action:waitToProceed$' "${event_log}" || true)"
  case "${scenario}" in
    direct-cancel-asset|direct-malformed-json|direct-extra-output|\
    direct-arbitrary-output|direct-malformed-output|direct-policy-race|\
    direct-asset-race|direct-publish-first-failure|direct-publish-second-failure|\
    direct-signal-between|direct-backup-tamper|direct-boundary-signal|\
    direct-cancel-meta|direct-cancel-meta-release|direct-context-mismatch)
      expected_waits=0
      ;;
  esac
  [[ "${wait_count}" == "${expected_waits}" ]] ||
    fail "${scenario} direct wait behavior changed"
  case "${scenario}" in
    direct-cancel-asset|direct-invalid-asset|direct-traversal|\
    direct-malformed-json|direct-preexisting-registry|direct-context-mismatch|\
    direct-tool-shadow|direct-cancel-meta|direct-cancel-meta-release)
      expected_tool_calls=0 ;;
    direct-draft-failure|direct-raw-diagnostic|direct-extra-output|\
    direct-arbitrary-output|direct-malformed-output) expected_tool_calls=1 ;;
    direct-signing-failure) expected_tool_calls=2 ;;
    direct-finalize-failure) expected_tool_calls=3 ;;
  esac
  [[ "$(grep -c '^token-metadata-creator' "${vector_log}" || true)" == \
     "${expected_tool_calls}" ]] || fail "${scenario} direct tool phase count changed"
  if (( expected_tool_calls > 0 )); then
    grep -Fq $'token-metadata-creator\tentry\t'"${subject}" "${vector_log}" ||
      fail "${scenario} direct subject argv changed"
    ! grep -Fq $'token-metadata-creator\tentry\t'"${POLICY_ID}"$'\t436f696e' \
      "${vector_log}" || fail "${scenario} split the subject argv"
  fi
  case "${scenario}" in
    direct-draft-failure|direct-raw-diagnostic)
      grep -Fq 'tool diagnostic output was suppressed.' "${stdout_file}" ||
        fail "${scenario} fixed diagnostic changed"
      ;;
    direct-preexisting-registry)
      grep -Fq 'Registry destination already exists; refusing to overwrite it.' \
        "${stdout_file}" || fail 'preexisting registry diagnostic changed'
      ;;
    direct-release-failure)
      grep -Fq 'registration committed, but postcommit cleanup was incomplete.' \
        "${stdout_file}" || fail 'release-failure postcommit warning changed'
      ;;
    direct-cancel-meta-release)
      grep -Fq 'CNTools asset-register action failed validation.' \
        "${stderr_file}" || fail 'cancel cleanup invariant diagnostic changed'
      ;;
    direct-invalid-asset|direct-traversal)
      grep -Fq 'Asset name should only contain alphanumeric chars' \
        "${stdout_file}" || fail "${scenario} validation diagnostic changed"
      ;;
  esac
  tree_snapshot "${runtime_root}" "${after}" || fail "${scenario} direct post-snapshot failed"

  if direct_expected_success "${scenario}"; then
    [[ -f "${policy_root}/${subject}.json" && ! -L "${policy_root}/${subject}.json" &&
       "$(file_mode "${policy_root}/${subject}.json")" == 644 &&
       -f "${asset_file}" && ! -L "${asset_file}" &&
       "$(file_mode "${asset_file}")" == 644 ]] ||
      fail "${scenario} committed output contract changed"
    [[ "$(jq -r '.metadata.name' "${asset_file}")" != null ]] ||
      fail "${scenario} committed metadata changed"
    if [[ "${scenario}" == direct-success-local-options ]]; then
      [[ "$(jq -r '.metadata.decimals' "${asset_file}")" == 6 ]] ||
        fail 'direct decimals persistence changed'
    fi
  else
    case "${scenario}" in
      direct-policy-race)
        [[ "$(file_hash "${policy_root}/policy.script")" != "${original_policy_hash}" ]] ||
          fail 'policy race was not injected'
        ;;
      direct-asset-race)
        [[ "$(file_hash "${asset_file}")" != "${original_asset_hash}" ]] ||
          fail 'asset race was not injected'
        ;;
      direct-preexisting-registry)
        [[ "$(jq -r '.competitor' "${policy_root}/${subject}.json")" == true ]] ||
          fail 'preexisting registry destination was altered'
        ;;
      *)
        if [[ -n "${original_asset_hash}" && -f "${asset_file}" ]]; then
          [[ "$(file_hash "${asset_file}")" == "${original_asset_hash}" ]] ||
            fail "${scenario} changed the original asset"
        fi
        [[ ! -e "${policy_root}/${subject}.json" ||
           "${scenario}" == direct-preexisting-registry ]] ||
          fail "${scenario} left registry commit residue"
        ;;
    esac
  fi
  [[ -z "$(find "${policy_root}" -mindepth 1 -maxdepth 1 \
    -type d -name '.cntools-register*' -print -quit)" ]] ||
    fail "${scenario} left transaction/lock residue"
}

# Direct helpers replace only the legacy UI surfaces used by the dormant action.
selectPolicy() {
  [[ "$*" == 'all policy.skey policy.script policy.id' ]] ||
    fail 'direct register selection vector changed'
  printf 'action:selectPolicy\n' >> "${EVENT_LOG:?}"
  policy_name=alpha
}

getAnswerAnyCust() {
  local variable="${1:-}" value=""
  value="$(direct_answer_value "${DIRECT_SCENARIO:?}" "${variable}")" ||
    fail "unexpected direct answer variable: ${variable}"
  printf -v "${variable}" '%s' "${value}"
  if [[ "${DIRECT_SCENARIO}" == direct-cancel-asset &&
        "${variable}" == asset_register_asset_name ]]; then
    printf 'action:answer-cancel:%s\n' "${variable}" >> "${EVENT_LOG:?}"
    return 1
  fi
  if [[ ( "${DIRECT_SCENARIO}" == direct-cancel-meta ||
          "${DIRECT_SCENARIO}" == direct-cancel-meta-release ) &&
        "${variable}" == asset_register_meta_name ]]; then
    printf 'action:answer-cancel:%s\n' "${variable}" >> "${EVENT_LOG:?}"
    return 1
  fi
  printf 'action:answer:%s:%q\n' "${variable}" "${value}" >> "${EVENT_LOG:?}"
}

fileDialog() {
  printf 'action:fileDialog\n' >> "${EVENT_LOG:?}"
  if [[ "${DIRECT_SCENARIO:?}" == direct-success-local-options ]]; then
    file="${DIRECT_LOGO_FILE:-${TEST_ROOT}/direct/${DIRECT_SCENARIO}/runtime/logo.png}"
  else
    file=""
  fi
}

waitToProceed() {
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${PUBLIC_ROUTE_ACTIVE:-N}" == Y &&
        ! -e "${CAPTURE_DONE_FILE:-/nonexistent}" ]]; then
    printf '__CNTOOLS_ASSET_REGISTER_END__\n'
    : > "${CAPTURE_DONE_FILE:?}"
    CAPTURE_ACTIVE=N
  fi
}
clear() { printf 'terminal:clear\n' >> "${EVENT_LOG:?}"; }

normalize_public_parity_file() {
  local source="$1" target="$2" runtime_root="$3" normalized=""

  normalized="${target}.normalized"

  normalize_file "${source}" "${normalized}" "${runtime_root}"
  "${REAL_SED_PATH}" -E \
    's/\.cntools-register\.[A-Za-z0-9]+/.cntools-register.<random>/g' \
    "${normalized}" > "${target}"
}

run_public_parity_case() {
  local scenario="$1" mode="$2" case_root="" runtime_root="" asset_root=""
  local policy_root="" capture_root=""
  local full_stdout="" action_stdout_raw="" action_stdout=""
  local stderr_file="" event_log="" vector_log="" network_log=""
  local before_snapshot="" after_snapshot="" capture_done_file=""
  local direct_root="" direct_bin="" asset_file=""
  local subject="${POLICY_ID}436f696e" status=0 expected_waits=1
  local public_action_events="" direct_action_events=""

  case_root="${TEST_ROOT}/public/${scenario}"
  runtime_root="${case_root}/runtime"
  asset_root="${runtime_root}/asset"
  policy_root="${asset_root}/alpha"
  capture_root="${case_root}/capture"
  full_stdout="${capture_root}/full.stdout"
  action_stdout_raw="${capture_root}/action.raw.stdout"
  action_stdout="${capture_root}/action.stdout"
  stderr_file="${capture_root}/stderr"
  event_log="${capture_root}/events"
  vector_log="${capture_root}/vectors"
  network_log="${capture_root}/network"
  before_snapshot="${capture_root}/before.tree"
  after_snapshot="${capture_root}/after.tree"
  capture_done_file="${capture_root}/capture.done"
  direct_root="${TEST_ROOT}/direct/${scenario}"
  direct_bin="${case_root}/bin"
  asset_file="${policy_root}/Coin.asset"
  public_action_events="${capture_root}/action.events"
  direct_action_events="${capture_root}/direct.action.events"

  mkdir -p -- "${capture_root}" "${runtime_root}/wallet" \
    "${runtime_root}/pool" "${direct_bin}"
  prepare_direct_scenario "${scenario}" "${runtime_root}" "${asset_root}"
  write_direct_fake_token_tool "${direct_bin}/token-metadata-creator"
  write_direct_fault_tools "${direct_bin}"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "${scenario} public pre-snapshot failed"
  : > "${event_log}"; : > "${vector_log}"; : > "${network_log}"

  if (
    set +e
    set +u
    set +o pipefail
    umask 022
    export LC_ALL=C TZ=UTC
    export CNTOOLS_ASSET_REGISTER_DIRECT_SCENARIO="${scenario}"
    export CNTOOLS_ASSET_REGISTER_DIRECT_VECTOR_LOG="${vector_log}"
    export CNTOOLS_ASSET_REGISTER_DIRECT_SUBJECT="${subject}"
    export CNTOOLS_ASSET_REGISTER_DIRECT_POLICY_SCRIPT="${policy_root}/policy.script"
    export CNTOOLS_ASSET_REGISTER_DIRECT_ASSET_FILE="${asset_file}"
    export CNTOOLS_ASSET_REGISTER_REAL_MV="${REAL_MV_PATH}"
    export CNTOOLS_ASSET_REGISTER_REAL_LN="${REAL_LN_PATH}"
    export CNTOOLS_ASSET_REGISTER_REAL_RMDIR="${REAL_RMDIR_PATH}"
    export CNTOOLS_ASSET_REGISTER_RELEASE_MARKER="${capture_root}/release.marker"
    export CNTOOLS_ASSET_REGISTER_NETWORK_LOG="${network_log}"
    PATH="${direct_bin}:${FAKE_BIN}:${BASE_PATH}"
    export PATH
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    ASSET_FOLDER="${asset_root}"
    ASSET_POLICY_SK_FILENAME=policy.skey
    ASSET_POLICY_SCRIPT_FILENAME=policy.script
    ASSET_POLICY_ID_FILENAME=policy.id
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION=characterized
    NETWORK_NAME=Preview
    NWMAGIC=42
    ADVANCED_MODE=true
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    price_now="" slotnum=1000
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    DIRECT_SCENARIO="${scenario}"
    DIRECT_LOGO_FILE="${runtime_root}/logo.png"
    DIRECT_ACTIVE=Y
    PUBLIC_ROUTE_ACTIVE=Y
    CAPTURE_DONE_FILE="${capture_done_file}"
    CAPTURE_ACTIVE=N END_ON_CLEAR=N
    unset asset_name meta_name meta_desc meta_ticker meta_url meta_decimals file
    CHOICES=(a a r h q)
    CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then status=0; else status=$?; fi
  [[ "${status}" == 0 && ! -s "${stderr_file}" ]] ||
    fail "${scenario} public traversal failed with ${status}"
  extract_action_output "${full_stdout}" "${action_stdout_raw}"
  normalize_public_parity_file "${action_stdout_raw}" "${action_stdout}" \
    "${runtime_root}"
  normalize_public_parity_file "${direct_root}/capture/stdout" \
    "${capture_root}/direct.stdout" "${direct_root}/runtime"
  assert_files_equal "${action_stdout}" "${capture_root}/direct.stdout" \
    "${scenario} public/direct stdout parity"
  normalize_public_parity_file "${vector_log}" "${capture_root}/public.vectors" \
    "${runtime_root}"
  normalize_public_parity_file "${direct_root}/capture/vectors" \
    "${capture_root}/direct.vectors" "${direct_root}/runtime"
  assert_files_equal "${capture_root}/public.vectors" \
    "${capture_root}/direct.vectors" "${scenario} public/direct tool argv parity"
  awk '
    $0 == "action:compatibility-dispatch" { capture=1; next }
    capture && /^(terminal:clear|action:(selectPolicy|answer:|answer-cancel:|fileDialog|waitToProceed))/ {
      print
      if ($0 == "action:waitToProceed" ||
          $0 == "action:answer-cancel:asset_register_asset_name") exit
    }
  ' "${event_log}" > "${public_action_events}"
  cp -- "${direct_root}/capture/events" "${direct_action_events}"
  assert_files_equal "${public_action_events}" "${direct_action_events}" \
    "${scenario} public/direct action event parity"
  [[ "$(grep -c '^action:compatibility-dispatch$' "${event_log}" || true)" == 1 &&
     "$(grep -c '^menu:main:a$' "${event_log}" || true)" == 1 &&
     "$(grep -c '^menu:advanced:a$' "${event_log}" || true)" == 1 &&
     "$(grep -c '^menu:asset:r$' "${event_log}" || true)" == 1 &&
     "$(grep -c '^menu:asset:h$' "${event_log}" || true)" == 1 &&
     "$(grep -c '^menu:main:q$' "${event_log}" || true)" == 1 ]] ||
    fail "${scenario} public compatibility navigation changed"
  [[ "${scenario}" != direct-cancel-asset ]] || expected_waits=0
  [[ "$(grep -c '^action:waitToProceed$' "${event_log}" || true)" == \
     "${expected_waits}" ]] || fail "${scenario} public wait behavior changed"
  case "${mode}" in
    LOCAL)
      [[ "$(grep -c '^runtime:getNodeMetrics$' "${event_log}" || true)" == 2 &&
         "$(grep -c '^runtime:getPriceInfo$' "${event_log}" || true)" == 2 &&
         "$(grep -c '^runtime:updateProtocolParams$' "${event_log}" || true)" == 2 ]] ||
        fail "${scenario} public LOCAL runtime behavior changed"
      ;;
    LIGHT)
      [[ "$(grep -c '^runtime:getNodeMetrics$' "${event_log}" || true)" == 0 &&
         "$(grep -c '^runtime:getPriceInfo$' "${event_log}" || true)" == 2 &&
         "$(grep -c '^runtime:updateProtocolParams$' "${event_log}" || true)" == 2 ]] ||
        fail "${scenario} public LIGHT runtime behavior changed"
      ;;
    OFFLINE)
      ! grep -Eq '^runtime:(getNodeMetrics|getPriceInfo|updateProtocolParams)$' \
        "${event_log}" || fail "${scenario} public OFFLINE runtime behavior changed"
      ;;
  esac
  [[ ! -s "${network_log}" ]] || fail "${scenario} public attempted network access"
  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "${scenario} public post-snapshot failed"
  if [[ "${scenario}" == direct-cancel-asset ]]; then
    assert_files_equal "${after_snapshot}" "${before_snapshot}" \
      'public cancel zero persistent mutation'
  else
    [[ -f "${policy_root}/${subject}.json" && ! -L "${policy_root}/${subject}.json" &&
       "$(file_mode "${policy_root}/${subject}.json")" == 644 &&
       -f "${asset_file}" && ! -L "${asset_file}" &&
       "$(file_mode "${asset_file}")" == 644 ]] ||
      fail "${scenario} public committed output contract changed"
  fi
  [[ -z "$(find "${policy_root}" -mindepth 1 -maxdepth 1 \
    -type d -name '.cntools-register*' -print -quit)" ]] ||
    fail "${scenario} public left transaction/lock residue"
}

run_direct_case direct-success-local-options local
run_direct_case direct-success-light light
run_direct_case direct-success-offline offline
run_direct_case direct-new-asset offline
run_direct_case direct-cancel-asset offline
run_direct_case direct-invalid-asset offline
run_direct_case direct-traversal offline
run_direct_case direct-malformed-json offline
run_direct_case direct-preexisting-registry offline
run_direct_case direct-draft-failure offline
run_direct_case direct-raw-diagnostic offline
run_direct_case direct-signing-failure offline
run_direct_case direct-finalize-failure offline
run_direct_case direct-validate-failure offline
run_direct_case direct-extra-output offline
run_direct_case direct-arbitrary-output offline
run_direct_case direct-malformed-output offline
run_direct_case direct-policy-race offline
run_direct_case direct-asset-race offline
run_direct_case direct-publish-first-failure offline
run_direct_case direct-publish-second-failure offline
run_direct_case direct-signal-between offline
run_direct_case direct-release-failure offline
run_direct_case direct-backup-tamper offline
run_direct_case direct-boundary-signal offline
run_direct_case direct-cancel-meta offline
run_direct_case direct-cancel-meta-release offline
run_direct_case direct-context-mismatch offline
run_direct_case direct-tool-shadow offline

run_public_parity_case direct-success-local-options LOCAL
run_public_parity_case direct-success-light LIGHT
run_public_parity_case direct-success-offline OFFLINE
run_public_parity_case direct-cancel-asset OFFLINE

arity_root="${TEST_ROOT}/direct/wrong-arity"
mkdir -p -- "${arity_root}/private" "${arity_root}/home"
chmod 0700 "${arity_root}/private"
write_context "${arity_root}/private/context.json" OFFLINE \
  "${arity_root}/home"
if cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
    "${arity_root}/private/context.json" \
    "${arity_root}/private/result.json" unexpected >/dev/null 2>&1; then
  fail 'direct register accepted an invalid argument count'
else
  [[ "$?" == 64 ]] || fail 'direct register misuse status changed'
fi
[[ ! -e "${arity_root}/private/result.json" &&
   ! -L "${arity_root}/private/result.json" ]] ||
  fail 'wrong-arity dispatch unexpectedly produced a result'

boundary_block="${TEST_ROOT}/register-boundary.block"
awk '
  /Cross the irreversible boundary/ { capture=1 }
  capture { print }
  capture && /_cntools_action_advanced_asset_register_postcommit_cleanup$/ { exit }
' "${ACTION_SOURCE}" > "${boundary_block}"
boundary_trap_line="$(grep -n "trap '_cntools_action_advanced_asset_register_postcommit_cleanup; exit 0'" \
  "${boundary_block}" | cut -d: -f1)"
boundary_clear_line="$(grep -n 'asset_register_registry_published=N' \
  "${boundary_block}" | cut -d: -f1)"
[[ "${boundary_trap_line}" =~ ^[0-9]+$ &&
   "${boundary_clear_line}" =~ ^[0-9]+$ &&
   "${boundary_trap_line}" -lt "${boundary_clear_line}" ]] ||
  fail 'postcommit traps are not installed atomically before rollback authority clears'

printf 'CNTools asset-register characterization/parity passed (30 frozen legacy + 4 public + 29 direct cases)\n'
