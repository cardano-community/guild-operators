#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools asset-show characterization skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
PAYLOAD_MANIFEST="${REPO_ROOT}/scripts/common-helper-scripts/cntools/manifest.json"
ACTION_DIRECTORY="${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/advanced/asset/show"
REGISTRY_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
CONTEXT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/context.sh"
RESULT_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/result.sh"
DISPATCHER_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/dispatcher.sh"
LEGACY_SELECTION_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f/020-terminal-selection-security.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-asset-show.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
FAKE_BIN="${TEST_ROOT}/fake-bin"
BASE_PATH="${PATH}"
REAL_JQ="$(command -v jq 2>/dev/null || true)"

cleanup_test() {
  if [[ "${CNTOOLS_ASSET_SHOW_PRESERVE_TEST_ROOT:-N}" == "Y" ]]; then
    printf 'CNTools asset-show test root preserved: %s\n' "${TEST_ROOT}" >&2
    return 0
  fi
  chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'CNTools asset-show characterization failed: %s\n' "$1" >&2
  exit 1
}

for required_command in awk cmp find grep jq sed sort stat wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done
[[ -n "${REAL_JQ}" ]] || fail 'jq is required'
if command -v sha256sum >/dev/null 2>&1; then
  HASH_COMMAND="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_COMMAND="shasum"
else
  fail 'sha256sum or shasum is required'
fi

write_fake_network_commands() {
  local command_name

  mkdir -p -- "${FAKE_BIN}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'last_argument=""' \
    'for argument in "$@"; do last_argument="${argument}"; done' \
    'case "${last_argument}" in' \
    '  */malformed-policy/policy.script)' \
    '    printf '\''jq: malformed policy fixture\n'\'' >&2' \
    '    exit 4' \
    '    ;;' \
    '  */malformed-policy/broken.asset)' \
    '    printf '\''jq: malformed asset fixture\n'\'' >&2' \
    '    exit 4' \
    '    ;;' \
    'esac' \
    'exec "${CNTOOLS_ASSET_SHOW_REAL_JQ:?}" "$@"' \
    > "${FAKE_BIN}/jq"
  chmod 0755 "${FAKE_BIN}/jq"

  for command_name in curl wget git ssh nc; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf '\''binary:%s'\'' "${0##*/}" >> "${CNTOOLS_ASSET_SHOW_NETWORK_LOG:?}"' \
      'printf '\''\t%s'\'' "$@" >> "${CNTOOLS_ASSET_SHOW_NETWORK_LOG:?}"' \
      'printf '\''\n'\'' >> "${CNTOOLS_ASSET_SHOW_NETWORK_LOG:?}"' \
      'exit 97' \
      > "${FAKE_BIN}/${command_name}"
    chmod 0755 "${FAKE_BIN}/${command_name}"
  done
}

file_mode() {
  local target="$1"
  local mode=""

  if mode="$(stat -f '%Lp' "${target}" 2>/dev/null)"; then
    :
  else
    mode="$(stat -c '%a' -- "${target}" 2>/dev/null)" || return 1
  fi
  [[ -n "${mode}" ]] || return 1
  printf '%s\n' "${mode#0}"
}

file_hash() {
  local target="$1"
  local result=""

  if [[ "${HASH_COMMAND}" == "sha256sum" ]]; then
    result="$(sha256sum -- "${target}")" || return 1
  else
    result="$(shasum -a 256 -- "${target}")" || return 1
  fi
  printf '%s\n' "${result%% *}"
}

tree_snapshot() {
  local root="$1"
  local output_file="$2"
  local target="" relative="" mode="" size="" digest="" link_target=""

  : > "${output_file}"
  mode="$(file_mode "${root}")" || return 1
  printf 'd\t.\t%s\t-\t-\n' "${mode}" >> "${output_file}"
  while IFS= read -r -d '' target; do
    relative="${target#"${root}"/}"
    mode="$(file_mode "${target}")" || return 1
    if [[ -L "${target}" ]]; then
      link_target="$(readlink "${target}")" || return 1
      printf 'l\t%q\t%s\t-\t%q\n' \
        "${relative}" "${mode}" "${link_target}" >> "${output_file}"
    elif [[ -d "${target}" ]]; then
      printf 'd\t%q\t%s\t-\t-\n' \
        "${relative}" "${mode}" >> "${output_file}"
    elif [[ -f "${target}" ]]; then
      size="$(wc -c < "${target}")"
      size="${size//[[:space:]]/}"
      digest="$(file_hash "${target}")" || return 1
      printf 'f\t%q\t%s\t%s\t%s\n' \
        "${relative}" "${mode}" "${size}" "${digest}" \
        >> "${output_file}"
    else
      printf 'o\t%q\t%s\t-\t-\n' \
        "${relative}" "${mode}" >> "${output_file}"
    fi
  done < <(find "${root}" -mindepth 1 -print0 | LC_ALL=C sort -z)
}

assert_files_equal() {
  local actual="$1"
  local expected="$2"
  local context="$3"

  cmp -s -- "${actual}" "${expected}" || {
    printf '%s\n' "--- expected: ${context} ---" >&2
    awk '{ printf "%04d %s\\n", NR, $0 }' "${expected}" >&2
    printf '%s\n' "--- actual: ${context} ---" >&2
    awk '{ printf "%04d %s\\n", NR, $0 }' "${actual}" >&2
    fail "${context} changed"
  }
}

write_context() {
  local target="$1"
  local mode="$2"
  local node_home="$3"

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

write_policy() {
  local asset_root="$1"
  local policy_name="$2"
  local policy_id="$3"
  local policy_script="$4"
  local policy_root="${asset_root}/${policy_name}"

  mkdir -p -- "${policy_root}"
  printf '%s\n' "${policy_id}" > "${policy_root}/policy.id"
  printf '%s\n' "${policy_script}" > "${policy_root}/policy.script"
}

prepare_populated_fixture() {
  local asset_root="$1"

  # Reverse creation order. Selection must follow policy path and asset path.
  write_policy "${asset_root}" z-unlimited policy-unlimited \
    '{"keyHash":"fixture","type":"sig"}'
  write_policy "${asset_root}" m-future policy-future \
    '{"type":"all","scripts":[{"slot":140,"type":"before"}]}'
  write_policy "${asset_root}" a-expired policy-expired \
    '{"type":"all","scripts":[{"slot":70,"type":"before"}]}'

  printf '%s\n' \
    '{"name":"Omega","minted":1000,"lastUpdate":"expired-update","lastAction":"burn"}' \
    > "${asset_root}/a-expired/20-omega.asset"
  printf '%s\n' \
    '{"name":"Alpha","minted":2000,"lastUpdate":"alpha-update","lastAction":"mint"}' \
    > "${asset_root}/a-expired/10-alpha.asset"
  printf '%s\n' \
    '{"name":"Future","minted":1234567,"lastUpdate":"future-update","lastAction":"mint"}' \
    > "${asset_root}/m-future/10-future.asset"
  printf '%s\n' \
    '{"name":"Unlimited","minted":42,"lastUpdate":"unlimited-update","lastAction":"mint"}' \
    > "${asset_root}/z-unlimited/10-unlimited.asset"
}

prepare_selector_failure_fixture() {
  local asset_root="$1"

  write_policy "${asset_root}" policy-without-assets policy-empty \
    '{"keyHash":"fixture","type":"sig"}'
}

prepare_malformed_fixture() {
  local asset_root="$1"
  local policy_root="${asset_root}/malformed-policy"

  mkdir -p -- "${policy_root}"
  printf 'policy-broken\n' > "${policy_root}/policy.id"
  printf '{ malformed policy json\n' > "${policy_root}/policy.script"
  printf '{ malformed asset json\n' > "${policy_root}/broken.asset"
  if "${REAL_JQ}" -e . "${policy_root}/policy.script" >/dev/null 2>&1 ||
     "${REAL_JQ}" -e . "${policy_root}/broken.asset" >/dev/null 2>&1; then
    fail 'malformed fixture unexpectedly parsed as JSON'
  fi
}

# Source definitions from the public legacy controller, immutable selector/query
# fragment, and compatibility framework. Public cases use a focused authority
# adapter; direct and installed cases invoke the extracted production action.
# shellcheck source=../../scripts/common-helper-scripts/cntools.sh
. "${CNTOOLS_SCRIPT}"
PRODUCTION_COMPATIBILITY_BRIDGE_DEFINITION="$(
  declare -f cntools_compatibility_dispatch_action
)" || fail 'could not preserve the production compatibility bridge'
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

# Substitute only installed-generation authority for the focused public matrix;
# transport still runs through the production dispatcher and extracted action.
cntools_compatibility_dispatch_action() (
  local action_id="${1:-}"
  local private_root="" context_file="" result_file="" status=0
  local snapshot_directory=""
  local tmp_mode=""

  [[ "${action_id}" == "advanced.asset.show" && $# -eq 1 ]] || return 70
  printf 'action:compatibility-dispatch\n' >> "${EVENT_LOG:?}"
  umask 077
  tmp_mode="$(file_mode "${TMP_DIR}")" || return 70
  private_root="$(mktemp -d \
    "${TMP_DIR%/}/asset-show-test-dispatch.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" && pwd -P)" || return 70
  chmod 0700 "${TMP_DIR}" "${private_root}" || return 70
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  snapshot_directory="${private_root}/action"
  mkdir -- "${snapshot_directory}" || return 70
  cp -- "${ACTION_DIRECTORY}/module.json" "${snapshot_directory}/module.json" ||
    return 70
  cp -- "${ACTION_DIRECTORY}/action.sh" "${snapshot_directory}/action.sh" ||
    return 70
  chmod 0700 "${snapshot_directory}"
  chmod 0400 "${snapshot_directory}/module.json" \
    "${snapshot_directory}/action.sh"
  write_context "${context_file}" "${CNTOOLS_MODE}" "${NODE_HOME}"
  if cntools_dispatcher_run_action "${snapshot_directory}" \
      "${context_file}" "${result_file}"; then
    status=0
  else
    status=$?
  fi
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] || status=70
  rm -f -- "${result_file}" "${context_file}" \
    "${snapshot_directory}/module.json" "${snapshot_directory}/action.sh"
  rmdir -- "${snapshot_directory}" || status=70
  rmdir -- "${private_root}" || status=70
  chmod "${tmp_mode}" "${TMP_DIR}" || status=70
  return "${status}"
)

build_installed_generation_fixture() {
  local fixture_root="$1"
  local inventory="${fixture_root}/inventory.ndjson"
  local canonical="${fixture_root}/canonical.tsv"
  local node="${fixture_root}/node"
  local state_root="${node}/scripts/.cntools"
  local generations="${state_root}/generations"
  local manifest_hash="" generation_id="" generation=""
  local generation_receipt_hash="" path="" source="" mode=""
  local validator="" expected_hash="" extra="" target=""

  mkdir -p -- "${fixture_root}" "${node}/tmp" "${node}/assets" \
    "${node}/wallet" "${node}/pool" "${node}/home" "${generations}"
  chmod 0755 "${node}" "${node}/scripts"
  chmod 0700 "${node}/tmp" "${state_root}" "${generations}"
  manifest_hash="$(file_hash "${PAYLOAD_MANIFEST}")" || return 1
  jq -cn --arg path 'cntools/manifest.json' \
    --arg source 'scripts/common-helper-scripts/cntools/manifest.json' \
    --arg mode '0444' --arg validator 'json' \
    --arg sha256 "${manifest_hash}" '
      {path:$path, source:$source, mode:$mode,
       validator:$validator, sha256:$sha256}
    ' > "${inventory}" || return 1
  jq -c '.files[]' "${PAYLOAD_MANIFEST}" >> "${inventory}" || return 1
  jq -r -s 'sort_by(.path)[] | [.path,.mode,.sha256] | @tsv' \
    "${inventory}" > "${canonical}" || return 1
  generation_id="$(file_hash "${canonical}")" || return 1
  generation="${generations}/${generation_id}"
  mkdir -p -- "${generation}/cntools"
  cp -- "${PAYLOAD_MANIFEST}" "${generation}/cntools/manifest.json" ||
    return 1
  chmod 0444 "${generation}/cntools/manifest.json" || return 1
  while IFS=$'\t' read -r path source mode validator expected_hash extra; do
    [[ -n "${path}" && -n "${source}" && -n "${mode}" &&
       -n "${validator}" && -n "${expected_hash}" && -z "${extra}" ]] ||
      return 1
    target="${generation}/${path}"
    mkdir -p -- "$(dirname -- "${target}")" || return 1
    cp -- "${REPO_ROOT}/${source}" "${target}" || return 1
    chmod "${mode}" "${target}" || return 1
    [[ "$(file_hash "${target}")" == "${expected_hash}" ]] || return 1
  done < <(jq -r '.files[] |
    [.path,.source,.mode,.validator,.sha256] | @tsv' "${PAYLOAD_MANIFEST}")
  jq -s --arg id "${generation_id}" \
    --arg manifest_hash "${manifest_hash}" \
    --arg version "$(jq -er '.version' "${PAYLOAD_MANIFEST}")" '
      {
        schemaVersion:3,
        id:$id,
        version:$version,
        generationIdAlgorithm:"sha256-path-mode-content-v1",
        payloadManifest:"cntools/manifest.json",
        payloadManifestSha256:$manifest_hash,
        files:sort_by(.path)
      }
    ' "${inventory}" > "${generation}/.generation.json" || return 1
  chmod 0444 "${generation}/.generation.json" || return 1
  find "${generation}" -depth -type d -exec chmod 0555 {} + || return 1

  generation_receipt_hash="$(file_hash \
    "${generation}/.generation.json")" || return 1
  jq -n --arg id "${generation_id}" \
    --arg manifest_hash "${manifest_hash}" \
    --arg generation_receipt_hash "${generation_receipt_hash}" '
      {
        schemaVersion:2,
        implementation:"cnode",
        network:"preview",
        cntoolsGeneration:{
          schemaVersion:1,
          id:$id,
          version:"13.5.7",
          path:("scripts/.cntools/generations/"+$id),
          payloadManifest:("scripts/.cntools/generations/"+$id+
            "/cntools/manifest.json"),
          payloadManifestSha256:$manifest_hash,
          generationReceipt:("scripts/.cntools/generations/"+$id+
            "/.generation.json"),
          generationReceiptSha256:$generation_receipt_hash,
          fileCount:152,
          active:false
        }
      }
    ' > "${node}/.guild-source-receipt.json" || return 1
  jq -n '
      {
        implementation:"cnode",
        network:"preview",
        capabilities:{forging:true,localCli:true,metrics:true,n2c:true}
      }
    ' > "${node}/.deployment.json" || return 1
  chmod 0644 "${node}/.guild-source-receipt.json" \
    "${node}/.deployment.json" || return 1
  printf '%s\t%s\t%s\n' "${node}" "${generation}" "${generation_id}"
}

# Output-only form of the historical println contract. History logging is not
# part of this focused action characterization.
println() {
  local log_level="${1:-}"
  shift || true
  case "${log_level}" in
    ACTION|LOG) return 0 ;;
    OFF|DEBUG|INFO|ERROR) printf '%b\n' "$@" ;;
    *) printf '%b\n' "${log_level}" "$@" ;;
  esac
}

clear() {
  if [[ "${CAPTURE_ACTIVE:-N}" == "Y" ]]; then
    if [[ "${ACTION_CLEAR_PENDING:-N}" == "Y" ]]; then
      ACTION_CLEAR_PENDING="N"
    else
      printf '__CNTOOLS_ASSET_SHOW_END__\n'
      CAPTURE_ACTIVE="N"
    fi
  fi
}
getEpoch() { printf '0\n'; }
timeUntilNextEpoch() { printf '0\n'; }
slotInterval() { printf '20\n'; }
getDateFromSlot() { printf 'slot-%s\n' "${1:-}"; }
timeLeft() { printf 'delta-%s' "${1:-}"; }

getSlotTipRef() {
  if [[ "${CAPTURE_ACTIVE:-N}" == "Y" ||
        "${DIRECT_ACTION_ACTIVE:-N}" == "Y" ]]; then
    printf 'action:getSlotTipRef\n' >> "${EVENT_LOG:?}"
  fi
  printf '100\n'
}

asciiToHex() {
  local value="${1:-}"
  local index=0

  for ((index=0; index<${#value}; index++)); do
    printf '%02x' "'${value:index:1}"
  done
}

formatAsset() {
  local value="${1:-}"

  case "${value}" in
    42) printf '42\n' ;;
    1000) printf '1,000\n' ;;
    2000) printf '2,000\n' ;;
    1234567) printf '1,234,567\n' ;;
    7654321) printf '7,654,321\n' ;;
    *)
      printf 'ERROR: must be a valid integer number' >&2
      return 1
      ;;
  esac
}

getNodeMetrics() {
  printf 'runtime:getNodeMetrics\n' >> "${EVENT_LOG:?}"
  slotnum=100
}

getPriceInfo() {
  printf 'runtime:getPriceInfo\n' >> "${EVENT_LOG:?}"
  price_now=""
}

updateProtocolParams() {
  printf 'runtime:updateProtocolParams\n' >> "${EVENT_LOG:?}"
}

select_opt() {
  local choice="${CHOICES[CHOICE_CURSOR]:-}"
  local menu="" option="" index=0

  case "${1:-}" in
    '[w] Wallet') menu="main" ;;
    '[m] Metadata') menu="advanced" ;;
    '[c] Create Policy') menu="asset" ;;
    *) fail "unexpected legacy menu: ${1:-<empty>}" ;;
  esac
  [[ -n "${choice}" ]] || fail "legacy menu ${menu} exhausted choices"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  printf 'menu:%s:%s\n' "${menu}" "${choice}" >> "${EVENT_LOG:?}"
  for option in "$@"; do
    if [[ "${option}" == "[${choice}]"* ]]; then
      selected_value="${option}"
      if [[ "${menu}:${choice}" == "asset:s" ]]; then
        CAPTURE_ACTIVE="Y"
        ACTION_CLEAR_PENDING="Y"
        printf '__CNTOOLS_ASSET_SHOW_BEGIN__\n'
      fi
      return "${index}"
    fi
    index=$((index + 1))
  done
  fail "choice ${choice} was absent from legacy menu ${menu}"
}

assert_installed_lock_released() {
  local boundary="$1"

  [[ "${INSTALLED_ROUTE_ACTIVE:-N}" == "Y" ]] || return 0
  if [[ "${CNTOOLS_ASSET_SHOW_LOCK_PROBE:-real}" == "event" ]]; then
    [[ -f "${INSTALLED_LOCK_RELEASED_FILE:?}" ]] ||
      fail "installed compatibility action reached ${boundary} before unlock"
    printf 'action:generation-lock-released:%s\n' "${boundary}" \
      >> "${EVENT_LOG:?}"
    return 0
  fi
  (
    # shellcheck source=/dev/null
    builtin source "${INSTALLED_LIFECYCLE:?}" >/dev/null 2>&1
    cntools_generation_lock_acquire "${INSTALLED_STATE_ROOT:?}"
    cntools_generation_lock_release "${INSTALLED_STATE_ROOT}"
  ) >/dev/null 2>&1 ||
    fail "installed compatibility action retained its generation lock at ${boundary}"
  printf 'action:generation-lock-released:%s\n' "${boundary}" \
    >> "${EVENT_LOG:?}"
}

# Called only by the real selectAsset -> selectDir path.
selectOption() {
  local option="" index=0 selected_index=-1

  assert_installed_lock_released selector
  printf 'selector:mode:%s\n' "${SELECTOR_MODE:?}" >> "${EVENT_LOG:?}"
  for option in "$@"; do
    printf 'selector:option:%s\n' "${option}" >> "${EVENT_LOG:?}"
    if [[ "${SELECTOR_MODE}" == "choose" &&
          "${option}" == "${SELECT_TARGET}" ]]; then
      selected_index=${index}
    elif [[ "${SELECTOR_MODE}" == "cancel" &&
            "${option}" == "[Esc] Cancel" ]]; then
      selected_index=${index}
    fi
    index=$((index + 1))
  done
  [[ ${selected_index} -ge 0 ]] || fail 'scripted selector target was absent'
  if [[ "${SELECTOR_MODE}" == "cancel" &&
        "${CAPTURE_ACTIVE:-N}" == "Y" ]]; then
    printf '__CNTOOLS_ASSET_SHOW_END__\n'
    CAPTURE_ACTIVE="N"
  fi
  return "${selected_index}"
}

waitToProceed() {
  assert_installed_lock_released wait
  printf 'action:waitToProceed\n' >> "${EVENT_LOG:?}"
  if [[ "${CAPTURE_ACTIVE:-N}" == "Y" ]]; then
    printf '__CNTOOLS_ASSET_SHOW_END__\n'
    CAPTURE_ACTIVE="N"
  fi
  return 0
}

myExit() {
  local status="${1:-0}"
  local message="${2:-}"

  printf 'exit:%s:%s\n' "${status}" "${message}" >> "${EVENT_LOG:?}"
  [[ "${CHOICE_CURSOR}" == "${#CHOICES[@]}" ]] ||
    fail 'legacy traversal did not consume every scripted menu choice'
  exit "${status}"
}

# The only authorized action network call is the exact Koios asset_info query.
curl() {
  local -a expected=(
    -sSL -f -H 'Authorization: fixture'
    -d "_asset_policy=${EXPECTED_CURL_POLICY:-}"
    -d "_asset_name=${EXPECTED_CURL_NAME:-}"
    'https://koios.invalid/api/v1/asset_info'
  )
  local -a actual=( "$@" )
  local index=0

  if (( $# != ${#expected[@]} )); then
    printf 'unauthorized:curl-argc:%s\n' "$#" \
      >> "${CNTOOLS_ASSET_SHOW_NETWORK_LOG:?}"
    return 97
  fi
  for ((index=0; index<${#expected[@]}; index++)); do
    if [[ "${actual[index]}" != "${expected[index]}" ]]; then
      printf 'unauthorized:curl-argv:%s\n' "$*" \
        >> "${CNTOOLS_ASSET_SHOW_NETWORK_LOG:?}"
      return 97
    fi
  done
  printf 'asset-info:%s:%s:%s\n' \
    "${ASSET_REMOTE_RESPONSE:?}" "${EXPECTED_CURL_POLICY}" \
    "${EXPECTED_CURL_NAME}" >> "${CNTOOLS_ASSET_SHOW_NETWORK_LOG:?}"
  case "${ASSET_REMOTE_RESPONSE}" in
    success)
      printf '%s\n' '[{"asset_name_ascii":"Future","fingerprint":"asset1fixture","minting_tx_hash":"tx-fixture","total_supply":7654321,"mint_cnt":3,"burn_cnt":1,"creation_time":1700000000,"minting_tx_metadata":{"721":{"fixture":"mint"}},"token_registry_metadata":{"name":"Registry Fixture"}}]'
      ;;
    empty) printf '[]\n' ;;
    error)
      printf 'simulated asset transport failure\n' >&2
      return 28
      ;;
    *) return 97 ;;
  esac
}

extract_action_output() {
  local full_output="$1"
  local action_output="$2"
  local begin_count=0 end_count=0

  begin_count="$(grep -c '^__CNTOOLS_ASSET_SHOW_BEGIN__$' \
    "${full_output}" || true)"
  end_count="$(awk '
    $0 == "__CNTOOLS_ASSET_SHOW_BEGIN__" { capture = 1; next }
    capture && $0 == "__CNTOOLS_ASSET_SHOW_END__" { print; exit }
  ' "${full_output}" | wc -l)"
  end_count="${end_count//[[:space:]]/}"
  [[ "${begin_count}" == "1" && "${end_count}" == "1" ]] ||
    fail 'action output markers were missing or malformed'
  awk '
    $0 == "__CNTOOLS_ASSET_SHOW_BEGIN__" { capture = 1; next }
    $0 == "__CNTOOLS_ASSET_SHOW_END__" { capture = 0; exit }
    capture { print }
  ' "${full_output}" > "${action_output}"
}

write_common_success_prefix() {
  local target="$1"
  local output_file="$2"
  local policy_name="" policy_id="" ttl_line="" asset_name=""

  case "${target}" in
    z-unlimited/10-unlimited)
      policy_name="z-unlimited"; policy_id="policy-unlimited"
      ttl_line="unlimited"; asset_name="Unlimited (556e6c696d69746564)"
      ;;
    m-future/10-future)
      policy_name="m-future"; policy_id="policy-future"
      ttl_line="slot-140, delta-40 remaining"
      asset_name="Future (467574757265)"
      ;;
    a-expired/20-omega)
      policy_name="a-expired"; policy_id="policy-expired"
      ttl_line="slot-70, expired delta-30 ago !!"
      asset_name="Omega (4f6d656761)"
      ;;
    malformed-policy/broken)
      policy_name="malformed-policy"; policy_id="policy-broken"
      ttl_line="unlimited"; asset_name=" ()"
      ;;
    *) fail "unknown selected target: ${target}" ;;
  esac
  printf '%s\n' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    ' >> ADVANCED >> ASSET >> SHOW ASSET' \
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
    'Select minted asset to show information for' \
    "Selected asset: ${target}" \
    '' \
    "Policy Name    : ${policy_name}" \
    "Policy ID      : ${policy_id}" \
    "Policy Expire  : ${ttl_line}" \
    "Asset Name     : ${asset_name}" \
    > "${output_file}"
}

write_expected_stdout() {
  local scenario="$1"
  local target="$2"
  local output_file="$3"

  case "${scenario}" in
    empty)
      printf '%s\n' \
        '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
        ' >> ADVANCED >> ASSET >> SHOW ASSET' \
        '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
        '' \
        'No policies or assets found!' \
        > "${output_file}"
      ;;
    selector-failure)
      printf '%s\n' \
        '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
        ' >> ADVANCED >> ASSET >> SHOW ASSET' \
        '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
        'Select minted asset to show information for' \
        'WARN: No assets found on disk!' \
        > "${output_file}"
      ;;
    selector-cancel)
      printf '%s\n' \
        '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
        ' >> ADVANCED >> ASSET >> SHOW ASSET' \
        '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~' \
        'Select minted asset to show information for' \
        > "${output_file}"
      ;;
    local-unlimited)
      write_common_success_prefix "${target}" "${output_file}"
      printf '%s\n' \
        'In Circulation : 42 (local tracking)' \
        'Last Updated   : unlimited-update' \
        'Last Action    : mint' >> "${output_file}"
      ;;
    local-future|light-empty)
      write_common_success_prefix "${target}" "${output_file}"
      printf '%s\n' \
        'In Circulation : 1,234,567 (local tracking)' \
        'Last Updated   : future-update' \
        'Last Action    : mint' >> "${output_file}"
      ;;
    offline-expired)
      write_common_success_prefix "${target}" "${output_file}"
      printf '%s\n' \
        'In Circulation : 1,000 (local tracking)' \
        'Last Updated   : expired-update' \
        'Last Action    : burn' >> "${output_file}"
      ;;
    light-success)
      write_common_success_prefix "${target}" "${output_file}"
      printf '%s\n' \
        'Fingerprint    : asset1fixture' \
        'In Circulation : 7,654,321' \
        'Mint Count     : 3' \
        'Burn Count     : 1' \
        'Mint Tx Meta   :' \
        '{' \
        '  "721": {' \
        '    "fixture": "mint"' \
        '  }' \
        '}' \
        'Token Reg Meta :' \
        '{' \
        '  "name": "Registry Fixture"' \
        '}' \
        'Last Updated   : future-update' \
        'Last Action    : mint' >> "${output_file}"
      ;;
    light-error)
      write_common_success_prefix "${target}" "${output_file}"
      printf '%s\n' \
        'KOIOS_API ERROR: simulated asset transport failure' \
        'Last Updated   : future-update' \
        'Last Action    : mint' >> "${output_file}"
      ;;
    malformed)
      write_common_success_prefix "${target}" "${output_file}"
      printf '%s\n' \
        'In Circulation :  (local tracking)' \
        'Last Updated   : ' \
        'Last Action    : ' >> "${output_file}"
      ;;
    *) fail "unknown expected stdout scenario: ${scenario}" ;;
  esac
}

write_expected_stderr() {
  local scenario="$1"
  local output_file="$2"

  : > "${output_file}"
  if [[ "${scenario}" == "malformed" ]]; then
    printf '%s\n' \
      'jq: malformed policy fixture' \
      'jq: malformed asset fixture' \
      'jq: malformed asset fixture' \
      'jq: malformed asset fixture' \
      'ERROR: must be a valid integer numberjq: malformed asset fixture' \
      'jq: malformed asset fixture' \
      > "${output_file}"
  fi
}

append_runtime_events() {
  local mode="$1"
  local output_file="$2"

  case "${mode}" in
    LOCAL)
      printf '%s\n' \
        'runtime:getNodeMetrics' \
        'runtime:getPriceInfo' \
        'runtime:updateProtocolParams' >> "${output_file}"
      ;;
    LIGHT)
      printf '%s\n' \
        'runtime:getPriceInfo' \
        'runtime:updateProtocolParams' >> "${output_file}"
      ;;
    OFFLINE) ;;
    *) fail "unknown mode: ${mode}" ;;
  esac
}

append_populated_selector_events() {
  local selector_mode="$1"
  local output_file="$2"

  printf '%s\n' \
    "selector:mode:${selector_mode}" \
    'selector:option:a-expired/10-alpha' \
    'selector:option:a-expired/20-omega' \
    'selector:option:m-future/10-future' \
    'selector:option:z-unlimited/10-unlimited' \
    'selector:option:[Esc] Cancel' >> "${output_file}"
}

write_expected_events() {
  local scenario="$1"
  local mode="$2"
  local selector_mode="$3"
  local output_file="$4"

  : > "${output_file}"
  append_runtime_events "${mode}" "${output_file}"
  printf '%s\n' \
    'menu:main:a' \
    'menu:advanced:a' \
    'menu:asset:s' \
    'action:compatibility-dispatch' >> "${output_file}"
  case "${scenario}" in
    selector-cancel)
      append_populated_selector_events "${selector_mode}" "${output_file}"
      ;;
    local-unlimited|local-future|offline-expired|light-success|light-error|light-empty)
      append_populated_selector_events "${selector_mode}" "${output_file}"
      printf 'action:getSlotTipRef\n' >> "${output_file}"
      ;;
    malformed)
      printf '%s\n' \
        'selector:mode:choose' \
        'selector:option:malformed-policy/broken' \
        'selector:option:[Esc] Cancel' \
        'action:getSlotTipRef' >> "${output_file}"
      ;;
    empty|selector-failure) ;;
    *) fail "unknown event scenario: ${scenario}" ;;
  esac
  [[ "${scenario}" == "selector-cancel" ]] ||
    printf 'action:waitToProceed\n' >> "${output_file}"
  printf 'menu:asset:h\n' >> "${output_file}"
  append_runtime_events "${mode}" "${output_file}"
  printf '%s\n' \
    'menu:main:q' \
    'exit:0:CNTools closed!' >> "${output_file}"
}

write_expected_network() {
  local remote_response="$1"
  local output_file="$2"

  : > "${output_file}"
  case "${remote_response}" in
    success|error|empty)
      printf 'asset-info:%s:policy-future:467574757265\n' \
        "${remote_response}" > "${output_file}"
      ;;
    none) ;;
    *) fail "unknown remote response: ${remote_response}" ;;
  esac
}

run_case() {
  local case_name="$1"
  local scenario="$2"
  local mode="$3"
  local fixture="$4"
  local selector_mode="$5"
  local select_target="$6"
  local remote_response="$7"
  local expected_curl_policy="$8"
  local expected_curl_name="$9"
  local case_root="${TEST_ROOT}/cases/${case_name}"
  local runtime_root="${case_root}/runtime"
  local asset_root="${runtime_root}/asset"
  local capture_root="${case_root}/capture"
  local full_stdout="${capture_root}/full.stdout"
  local action_stdout="${capture_root}/action.stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local network_log="${capture_root}/network"
  local expected_network="${capture_root}/expected.network"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local status=0

  mkdir -p -- \
    "${runtime_root}/tmp" \
    "${runtime_root}/wallet" \
    "${runtime_root}/pool" \
    "${asset_root}" \
    "${runtime_root}/home" \
    "${capture_root}"
  case "${fixture}" in
    empty) ;;
    no-assets) prepare_selector_failure_fixture "${asset_root}" ;;
    populated) prepare_populated_fixture "${asset_root}" ;;
    malformed) prepare_malformed_fixture "${asset_root}" ;;
    *) fail "unknown fixture: ${fixture}" ;;
  esac

  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot ${case_name} before traversal"
  : > "${event_log}"
  : > "${network_log}"
  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    ASSET_FOLDER="${asset_root}"
    ASSET_POLICY_ID_FILENAME="policy.id"
    ASSET_POLICY_SCRIPT_FILENAME="policy.script"
    CNTOOLS_MODE="${mode}"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION="characterized"
    NETWORK_NAME="Preview"
    ADVANCED_MODE="true"
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    KOIOS_API="https://koios.invalid/api/v1"
    KOIOS_API_HEADERS=(-H 'Authorization: fixture')
    price_now=""
    slotnum=100
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CNTOOLS_ASSET_SHOW_NETWORK_LOG="${network_log}"
    CAPTURE_ACTIVE="N"
    ACTION_CLEAR_PENDING="N"
    SELECTOR_MODE="${selector_mode}"
    SELECT_TARGET="${select_target}"
    ASSET_REMOTE_RESPONSE="${remote_response}"
    EXPECTED_CURL_POLICY="${expected_curl_policy}"
    EXPECTED_CURL_NAME="${expected_curl_name}"
    CHOICES=(a a s h q)
    CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "0" ]] || fail "${case_name} traversal returned ${status}"

  extract_action_output "${full_stdout}" "${action_stdout}"
  write_expected_stdout "${scenario}" "${select_target}" "${expected_stdout}"
  write_expected_stderr "${scenario}" "${expected_stderr}"
  write_expected_events "${scenario}" "${mode}" "${selector_mode}" \
    "${expected_events}"
  write_expected_network "${remote_response}" "${expected_network}"
  assert_files_equal "${action_stdout}" "${expected_stdout}" \
    "${case_name} action stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "${case_name} action stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "${case_name} wait and navigation events"
  assert_files_equal "${network_log}" "${expected_network}" \
    "${case_name} authorized network vector"

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot ${case_name} after traversal"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    "${case_name} persistent tree"
}

write_expected_direct_events() {
  local scenario="$1"
  local selector_mode="$2"
  local output_file="$3"

  : > "${output_file}"
  case "${scenario}" in
    selector-cancel)
      append_populated_selector_events "${selector_mode}" "${output_file}"
      ;;
    local-unlimited|local-future|offline-expired|light-success|light-error|light-empty)
      append_populated_selector_events "${selector_mode}" "${output_file}"
      printf 'action:getSlotTipRef\n' >> "${output_file}"
      ;;
    malformed)
      printf '%s\n' \
        'selector:mode:choose' \
        'selector:option:malformed-policy/broken' \
        'selector:option:[Esc] Cancel' \
        'action:getSlotTipRef' >> "${output_file}"
      ;;
    empty|selector-failure) ;;
    *) fail "unknown direct-event scenario: ${scenario}" ;;
  esac
  [[ "${scenario}" == "selector-cancel" ]] ||
    printf 'action:waitToProceed\n' >> "${output_file}"
}

run_direct_case() {
  local case_name="$1"
  local scenario="$2"
  local mode="$3"
  local fixture="$4"
  local selector_mode="$5"
  local select_target="$6"
  local remote_response="$7"
  local expected_curl_policy="$8"
  local expected_curl_name="$9"
  local case_root="${TEST_ROOT}/direct/${case_name}"
  local runtime_root="${case_root}/runtime"
  local asset_root="${runtime_root}/asset"
  local capture_root="${case_root}/capture"
  local private_root="${case_root}/private"
  local context_file="${private_root}/context.json"
  local result_file="${private_root}/result.json"
  local stdout_file="${capture_root}/stdout"
  local stderr_file="${capture_root}/stderr"
  local expected_stdout="${capture_root}/expected.stdout"
  local expected_stderr="${capture_root}/expected.stderr"
  local event_log="${capture_root}/events"
  local expected_events="${capture_root}/expected.events"
  local network_log="${capture_root}/network"
  local expected_network="${capture_root}/expected.network"
  local before_snapshot="${capture_root}/before.tree"
  local after_snapshot="${capture_root}/after.tree"
  local status=0

  mkdir -p -- \
    "${runtime_root}/tmp" \
    "${runtime_root}/wallet" \
    "${runtime_root}/pool" \
    "${asset_root}" \
    "${runtime_root}/home" \
    "${capture_root}" \
    "${private_root}"
  chmod 0700 "${private_root}"
  case "${fixture}" in
    empty) ;;
    no-assets) prepare_selector_failure_fixture "${asset_root}" ;;
    populated) prepare_populated_fixture "${asset_root}" ;;
    malformed) prepare_malformed_fixture "${asset_root}" ;;
    *) fail "unknown direct fixture: ${fixture}" ;;
  esac
  write_context "${context_file}" "${mode}" "${runtime_root}/home"
  tree_snapshot "${runtime_root}" "${before_snapshot}" ||
    fail "could not snapshot direct ${case_name} before dispatch"
  : > "${event_log}"
  : > "${network_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C
    HOME="${runtime_root}/home"
    NODE_HOME="${runtime_root}/home"
    TMP_DIR="${runtime_root}/tmp"
    WALLET_FOLDER="${runtime_root}/wallet"
    POOL_FOLDER="${runtime_root}/pool"
    ASSET_FOLDER="${asset_root}"
    ASSET_POLICY_ID_FILENAME="policy.id"
    ASSET_POLICY_SCRIPT_FILENAME="policy.script"
    CNTOOLS_MODE="${mode}"
    ADVANCED_MODE="true"
    BLOCKLOG_DB="${runtime_root}/absent-blocklog.db"
    KOIOS_API="https://koios.invalid/api/v1"
    KOIOS_API_HEADERS=(-H 'Authorization: fixture')
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CNTOOLS_ASSET_SHOW_NETWORK_LOG="${network_log}"
    CAPTURE_ACTIVE="N"
    DIRECT_ACTION_ACTIVE="Y"
    INSTALLED_ROUTE_ACTIVE="N"
    SELECTOR_MODE="${selector_mode}"
    SELECT_TARGET="${select_target}"
    ASSET_REMOTE_RESPONSE="${remote_response}"
    EXPECTED_CURL_POLICY="${expected_curl_policy}"
    EXPECTED_CURL_NAME="${expected_curl_name}"
    cntools_dispatcher_run_action "${ACTION_DIRECTORY}" \
      "${context_file}" "${result_file}"
  ) > "${stdout_file}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "0" ]] ||
    fail "direct ${case_name} dispatch returned ${status}"
  [[ ! -e "${result_file}" && ! -L "${result_file}" ]] ||
    fail "direct ${case_name} unexpectedly produced a result"

  write_expected_stdout "${scenario}" "${select_target}" "${expected_stdout}"
  write_expected_stderr "${scenario}" "${expected_stderr}"
  write_expected_direct_events "${scenario}" "${selector_mode}" \
    "${expected_events}"
  write_expected_network "${remote_response}" "${expected_network}"
  assert_files_equal "${stdout_file}" "${expected_stdout}" \
    "direct ${case_name} stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "direct ${case_name} stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "direct ${case_name} wait and selector events"
  assert_files_equal "${network_log}" "${expected_network}" \
    "direct ${case_name} authorized network vector"

  tree_snapshot "${runtime_root}" "${after_snapshot}" ||
    fail "could not snapshot direct ${case_name} after dispatch"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    "direct ${case_name} persistent tree"
}

write_expected_installed_events() {
  local scenario="$1"
  local selector_mode="$2"
  local output_file="$3"

  printf '%s\n' \
    'menu:main:a' \
    'menu:advanced:a' \
    'menu:asset:s' \
    'authority:current' \
    'authority:current' > "${output_file}"
  case "${scenario}" in
    empty)
      printf '%s\n' \
        'action:generation-lock-released:wait' \
        'action:waitToProceed' >> "${output_file}"
      ;;
    selector-cancel)
      printf 'action:generation-lock-released:selector\n' >> "${output_file}"
      append_populated_selector_events "${selector_mode}" "${output_file}"
      ;;
    offline-expired)
      printf 'action:generation-lock-released:selector\n' >> "${output_file}"
      append_populated_selector_events "${selector_mode}" "${output_file}"
      printf '%s\n' \
        'action:getSlotTipRef' \
        'action:generation-lock-released:wait' \
        'action:waitToProceed' >> "${output_file}"
      ;;
    *) fail "unknown installed-event scenario: ${scenario}" ;;
  esac
  printf '%s\n' \
    'menu:asset:h' \
    'menu:main:q' \
    'exit:0:CNTools closed!' >> "${output_file}"
}

run_installed_public_case() {
  local case_name="$1"
  local scenario="$2"
  local fixture="$3"
  local selector_mode="$4"
  local select_target="$5"
  local case_root="${TEST_ROOT}/installed/${case_name}"
  local fixture_root="${case_root}/fixture"
  local capture_root="${case_root}/capture"
  local node="" generation="" generation_id="" state_root=""
  local lifecycle="" asset_root="" full_stdout="" action_stdout=""
  local stderr_file="" expected_stdout="" expected_stderr=""
  local event_log="" expected_events="" before_snapshot=""
  local after_snapshot="" network_log="" expected_network="" status=0

  mkdir -p -- "${capture_root}"
  IFS=$'\t' read -r node generation generation_id < <(
    build_installed_generation_fixture "${fixture_root}"
  ) || fail "could not build installed show fixture for ${case_name}"
  [[ "${generation_id}" =~ ^[0-9a-f]{64}$ &&
     "${generation}" == \
       "${node}/scripts/.cntools/generations/${generation_id}" ]] ||
    fail "installed show fixture has an invalid identity for ${case_name}"
  state_root="${node}/scripts/.cntools"
  lifecycle="${generation}/cntools/core/lifecycle.sh"
  asset_root="${node}/assets"
  case "${fixture}" in
    empty) ;;
    populated) prepare_populated_fixture "${asset_root}" ;;
    *) fail "unknown installed fixture: ${fixture}" ;;
  esac
  full_stdout="${capture_root}/full.stdout"
  action_stdout="${capture_root}/action.stdout"
  stderr_file="${capture_root}/stderr"
  expected_stdout="${capture_root}/expected.stdout"
  expected_stderr="${capture_root}/expected.stderr"
  event_log="${capture_root}/events"
  expected_events="${capture_root}/expected.events"
  network_log="${capture_root}/network"
  expected_network="${capture_root}/expected.network"
  before_snapshot="${capture_root}/before.tree"
  after_snapshot="${capture_root}/after.tree"
  tree_snapshot "${asset_root}" "${before_snapshot}" ||
    fail "could not snapshot installed ${case_name} before traversal"
  : > "${event_log}"
  : > "${network_log}"

  if (
    set +e
    set +u
    set +o pipefail
    export LC_ALL=C
    eval "${PRODUCTION_COMPATIBILITY_BRIDGE_DEFINITION}"
    AUTHORITY_CALL_COUNT=0
    deployment_payload_is_current() {
      printf 'authority:current\n' >> "${EVENT_LOG:?}"
      AUTHORITY_CALL_COUNT=$((AUTHORITY_CALL_COUNT + 1))
      if [[ "${AUTHORITY_CALL_COUNT}" == "2" ]]; then
        # The bridge has just loaded and verified the immutable lifecycle. Swap
        # only its lock calls for an observable probe: the sandboxed macOS test
        # host denies ps(1), which the real lock identity check requires.
        cntools_generation_lock_acquire() {
          rm -f -- "${INSTALLED_LOCK_RELEASED_FILE:?}"
          return 0
        }
        cntools_generation_lock_release() {
          : > "${INSTALLED_LOCK_RELEASED_FILE:?}"
          return 0
        }
        cntools_generation_pointers_validate() {
          _cntools_generation_root_validate "$1" &&
            _cntools_generation_state_is_settled "$1" &&
            _cntools_generation_pointers_validate_unlocked "$1"
        }
      fi
      return 0
    }
    deployment_payload_sha256() { file_hash "$1"; }
    HOME="${node}/home"
    NODE_HOME="${node}"
    TMP_DIR="${node}/tmp"
    WALLET_FOLDER="${node}/wallet"
    POOL_FOLDER="${node}/pool"
    ASSET_FOLDER="${asset_root}"
    ASSET_POLICY_ID_FILENAME="policy.id"
    ASSET_POLICY_SCRIPT_FILENAME="policy.script"
    CNTOOLS_MODE="OFFLINE"
    CNTOOLS_MODE_COLOR=""
    CNTOOLS_VERSION="characterized"
    NETWORK_NAME="Preview"
    ADVANCED_MODE="true"
    BLOCKLOG_DB="${node}/absent-blocklog.db"
    price_now=""
    slotnum=100
    FG_BLACK="" FG_RED="" FG_GREEN="" FG_YELLOW="" FG_BLUE=""
    FG_MAGENTA="" FG_CYAN="" FG_LGRAY="" FG_DGRAY="" FG_LBLUE=""
    FG_WHITE="" NC=""
    EVENT_LOG="${event_log}"
    CNTOOLS_ASSET_SHOW_NETWORK_LOG="${network_log}"
    CAPTURE_ACTIVE="N"
    ACTION_CLEAR_PENDING="N"
    DIRECT_ACTION_ACTIVE="N"
    INSTALLED_ROUTE_ACTIVE="Y"
    INSTALLED_LIFECYCLE="${lifecycle}"
    INSTALLED_STATE_ROOT="${state_root}"
    INSTALLED_LOCK_RELEASED_FILE="${node}/lock-released"
    CNTOOLS_ASSET_SHOW_LOCK_PROBE="event"
    SELECTOR_MODE="${selector_mode}"
    SELECT_TARGET="${select_target}"
    ASSET_REMOTE_RESPONSE="none"
    EXPECTED_CURL_POLICY=""
    EXPECTED_CURL_NAME=""
    CHOICES=(a a s h q)
    CHOICE_CURSOR=0
    main
    exit 99
  ) > "${full_stdout}" 2> "${stderr_file}"; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" == "0" ]] ||
    fail "installed ${case_name} traversal returned ${status}"

  extract_action_output "${full_stdout}" "${action_stdout}"
  write_expected_stdout "${scenario}" "${select_target}" "${expected_stdout}"
  write_expected_stderr "${scenario}" "${expected_stderr}"
  write_expected_installed_events "${scenario}" "${selector_mode}" \
    "${expected_events}"
  write_expected_network none "${expected_network}"
  assert_files_equal "${action_stdout}" "${expected_stdout}" \
    "installed ${case_name} stdout"
  assert_files_equal "${stderr_file}" "${expected_stderr}" \
    "installed ${case_name} stderr"
  assert_files_equal "${event_log}" "${expected_events}" \
    "installed ${case_name} authority, lock, wait, and return events"
  assert_files_equal "${network_log}" "${expected_network}" \
    "installed ${case_name} network vector"

  tree_snapshot "${asset_root}" "${after_snapshot}" ||
    fail "could not snapshot installed ${case_name} after traversal"
  assert_files_equal "${after_snapshot}" "${before_snapshot}" \
    "installed ${case_name} persistent asset tree"
  [[ -z "$(find "${node}/tmp" -mindepth 1 -print -quit)" ]] ||
    fail "installed ${case_name} retained private context or result state"
  [[ ! -e "${node}/.guild-deploy-transaction" &&
     ! -L "${node}/.guild-deploy-transaction" ]] ||
    fail "installed ${case_name} created a deployment transaction journal"
  rm -f -- "${node}/lock-released"
}

write_fake_network_commands
PATH="${FAKE_BIN}:${BASE_PATH}"
export PATH
export CNTOOLS_ASSET_SHOW_REAL_JQ="${REAL_JQ}"
export CNTOOLS_ASSET_SHOW_NETWORK_LOG="${TEST_ROOT}/unexpected-network.log"
: > "${CNTOOLS_ASSET_SHOW_NETWORK_LOG}"

run_case empty-offline empty OFFLINE empty choose '' none '' ''
run_case selector-failure selector-failure OFFLINE no-assets choose '' none '' ''
run_case selector-cancel selector-cancel OFFLINE populated cancel '' none '' ''
run_case local-unlimited local-unlimited LOCAL populated choose \
  z-unlimited/10-unlimited none '' ''
run_case local-future local-future LOCAL populated choose \
  m-future/10-future none '' ''
run_case offline-expired offline-expired OFFLINE populated choose \
  a-expired/20-omega none '' ''
run_case light-success light-success LIGHT populated choose \
  m-future/10-future success policy-future 467574757265
run_case light-error light-error LIGHT populated choose \
  m-future/10-future error policy-future 467574757265
run_case light-empty-fallback light-empty LIGHT populated choose \
  m-future/10-future empty policy-future 467574757265
run_case malformed-offline malformed OFFLINE malformed choose \
  malformed-policy/broken none '' ''

run_direct_case empty-offline empty OFFLINE empty choose '' none '' ''
run_direct_case selector-failure selector-failure OFFLINE no-assets \
  choose '' none '' ''
run_direct_case selector-cancel selector-cancel OFFLINE populated \
  cancel '' none '' ''
run_direct_case local-unlimited local-unlimited LOCAL populated choose \
  z-unlimited/10-unlimited none '' ''
run_direct_case local-future local-future LOCAL populated choose \
  m-future/10-future none '' ''
run_direct_case offline-expired offline-expired OFFLINE populated choose \
  a-expired/20-omega none '' ''
run_direct_case light-success light-success LIGHT populated choose \
  m-future/10-future success policy-future 467574757265
run_direct_case light-error light-error LIGHT populated choose \
  m-future/10-future error policy-future 467574757265
run_direct_case light-empty-fallback light-empty LIGHT populated choose \
  m-future/10-future empty policy-future 467574757265
run_direct_case malformed-offline malformed OFFLINE malformed choose \
  malformed-policy/broken none '' ''

run_installed_public_case empty-offline empty empty choose ''
run_installed_public_case selector-cancel selector-cancel populated cancel ''
run_installed_public_case offline-expired offline-expired populated choose \
  a-expired/20-omega

[[ ! -s "${CNTOOLS_ASSET_SHOW_NETWORK_LOG}" ]] ||
  fail 'an external network command bypassed the per-case deny fixture'

# The general modular bootstrap remains shadow-only. Exactly this legacy leaf
# routes to the second active compatibility action, with no duplicated body.
if grep -Fq 'cntools_dispatcher_run_action' \
    "${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/bootstrap.sh"; then
  fail 'public modular bootstrap can reach compatibility action execution'
fi
legacy_show_arm="${TEST_ROOT}/legacy-show-arm"
awk '
  /^[[:space:]]+show-asset\)/ { capture = 1 }
  capture { print }
  capture && /^[[:space:]]+;;/ { exit }
' "${CNTOOLS_SCRIPT}" > "${legacy_show_arm}"
[[ "$(grep -c 'cntools_compatibility_dispatch_action advanced.asset.show' \
      "${legacy_show_arm}" || true)" == "1" ]] ||
  fail 'legacy show-asset route does not contain exactly one generic call'
if grep -Eq 'selectAsset|getAssetInfo|Policy Name|Policy Expire|\.scripts\[0\]\.slot' \
    "${legacy_show_arm}"; then
  fail 'legacy show-asset implementation body was not fully extracted'
fi
[[ "$(grep -c 'cntools_compatibility_dispatch_action advanced.asset.show' \
      "${CNTOOLS_SCRIPT}" || true)" == "1" ]] ||
  fail 'advanced.asset.show generic bridge call count changed'
[[ "$(grep -Ec 'cntools_compatibility_dispatch_action advanced\.asset\.(list|show)' \
      "${CNTOOLS_SCRIPT}" || true)" == "2" ]] ||
  fail 'active public compatibility call count changed'
if grep -Fq 'CNTools action execution is inactive in Stage 3 shadow mode.' \
    "${ACTION_DIRECTORY}/action.sh"; then
  fail 'advanced.asset.show still contains the inert Stage 3 implementation'
fi

printf 'CNTools asset-show characterization passed\n'
