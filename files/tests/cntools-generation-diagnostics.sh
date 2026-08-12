#!/usr/bin/env bash
# Validate Stage 3 diagnostics through a complete content-addressed generation.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools generation diagnostic tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

LC_ALL=C
export LC_ALL

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MANIFEST_RELATIVE="scripts/common-helper-scripts/cntools/manifest.json"
SOURCE_MANIFEST="${REPO_ROOT}/${MANIFEST_RELATIVE}"
MENU_ORACLE="${REPO_ROOT}/files/tests/fixtures/cntools-stage3-menu-dump.json"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-diagnostics.XXXXXX")"
TEST_ROOT="$(cd -P -- "${TEST_ROOT}" && pwd -P)"
EXPECTED_VALIDATE='CNTools module registry is valid (69 modules: 15 menus, 54 actions; 22 controls; 90 options).'
EXPECTED_REGISTRY_ERROR='CNTools module registry validation failed.'
EXPECTED_AUTHORITY_ERROR='CNTools generation is not bound to deployment authority.'
LOCK_HOLDER_PID=""
LOCK_HOLDER_CONTROL=""

cleanup() {
  if [[ -n "${LOCK_HOLDER_PID}" ]]; then
    kill "${LOCK_HOLDER_PID}" >/dev/null 2>&1 || true
    wait "${LOCK_HOLDER_PID}" >/dev/null 2>&1 || true
  fi
  chmod -R u+rwX "${TEST_ROOT}" >/dev/null 2>&1 || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'CNTools generation diagnostic test failed: %s\n' "$1" >&2
  exit 1
}

for required_command in chmod cmp cp diff dirname find jq ln mkdir mkfifo \
  mktemp mv sleep sort tr; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done
if ! command -v sha256sum >/dev/null 2>&1 &&
   ! command -v shasum >/dev/null 2>&1; then
  fail 'a SHA-256 command is unavailable'
fi

sha256_file() {
  local target="$1"
  local digest=""

  [[ -f "${target}" && ! -L "${target}" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum -- "${target}")" || return 1
  else
    digest="$(shasum -a 256 -- "${target}")" || return 1
  fi
  printf '%s\n' "${digest%% *}"
}

atomic_jq_update() {
  local target="$1"
  shift
  local staged="${target}.stage.$$"

  jq "$@" "${target}" > "${staged}" || {
    rm -f -- "${staged}"
    return 1
  }
  mv -f -- "${staged}" "${target}"
}

prepare_payload() {
  local variant="$1"
  local payload="${TEST_ROOT}/payload-${variant}"
  local source="" source_file="" target=""

  mkdir -p -- "${payload}/$(dirname -- "${MANIFEST_RELATIVE}")"
  cp -- "${SOURCE_MANIFEST}" "${payload}/${MANIFEST_RELATIVE}"
  while IFS= read -r source; do
    source_file="${REPO_ROOT}/${source}"
    target="${payload}/${source}"
    [[ -f "${source_file}" && ! -L "${source_file}" ]] ||
      fail "payload source is missing or unsafe: ${source}"
    mkdir -p -- "$(dirname -- "${target}")"
    cp -- "${source_file}" "${target}"
  done < <(jq -er '.files[].source' "${SOURCE_MANIFEST}")
  printf '%s\n' "${payload}"
}

update_payload_hash() {
  local payload="$1"
  local source="$2"
  local manifest="${payload}/${MANIFEST_RELATIVE}"
  local digest=""

  digest="$(sha256_file "${payload}/${source}")" || return 1
  # shellcheck disable=SC2016 # jq variables are expanded by jq, not Bash.
  atomic_jq_update "${manifest}" --arg source "${source}" \
    --arg digest "${digest}" '
      (.files[] | select(.source == $source) | .sha256) = $digest
    '
}

instrument_binding_race_payload() {
  local payload="$1"
  local lifecycle_source='scripts/common-helper-scripts/cntools/core/lifecycle.sh'
  local lifecycle="${payload}/${lifecycle_source}"
  local metadata="${TEST_ROOT}/node-binding-race/.deployment.json"
  local marker="${TEST_ROOT}/binding-race.injected"
  local jq_path="" chmod_path="" mv_path=""

  jq_path="$(builtin type -P jq)" || return 1
  chmod_path="$(builtin type -P chmod)" || return 1
  mv_path="$(builtin type -P mv)" || return 1
  [[ "${jq_path}" == /* && "${chmod_path}" == /* && "${mv_path}" == /* ]] ||
    return 1
  {
    printf '\n%s\n' \
      '# Test-only, content-addressed post-lock authority-race instrument.'
    printf '%s\n' \
      '_cntools_diagnostic_lock_definition="$(declare -f _cntools_generation_lock_acquire)"' \
      '_cntools_diagnostic_lock_definition="${_cntools_diagnostic_lock_definition/#_cntools_generation_lock_acquire /_cntools_diagnostic_original_generation_lock_acquire }"' \
      'builtin eval "${_cntools_diagnostic_lock_definition}" || return 2' \
      'unset _cntools_diagnostic_lock_definition' \
      '_cntools_generation_lock_acquire() {'
    printf '  local metadata=%q marker=%q staged=""\n' \
      "${metadata}" "${marker}"
    printf '%s\n' \
      '  _cntools_diagnostic_original_generation_lock_acquire "$@" || return $?' \
      '  staged="${metadata}.race.${BASHPID:-$$}"'
    printf '  if ! %q '\'' .payloadReceiptSha256 = ("0" * 64) '\'' "${metadata}" > "${staged}"; then\n' \
      "${jq_path}"
    printf '%s\n' \
      '    _cntools_generation_lock_release >/dev/null 2>&1 || true' \
      '    return 2' \
      '  fi'
    printf '  %q 0644 "${staged}" || return 2\n' "${chmod_path}"
    printf '  %q -f "${staged}" "${metadata}" || return 2\n' "${mv_path}"
    printf '%s\n' \
      '  : > "${marker}"' \
      '}'
  } >> "${lifecycle}" || return 1
  update_payload_hash "${payload}" "${lifecycle_source}"
}

build_generation() {
  local payload="$1"
  local variant="$2"
  local manifest="${payload}/${MANIFEST_RELATIVE}"
  local inventory="${TEST_ROOT}/${variant}.inventory.ndjson"
  local canonical="${TEST_ROOT}/${variant}.canonical.tsv"
  local node="${TEST_ROOT}/node-${variant}"
  local generations="${node}/scripts/.cntools/generations"
  local manifest_hash="" generation_id="" generation=""
  local path="" source="" mode="" validator="" expected_hash="" extra=""
  local actual_hash="" source_file="" target=""

  jq -e '
    .schemaVersion == 3 and .moduleApiVersion == 1 and
    .moduleSchemaVersion == 2 and
    (.files | length) == 151 and
    ([.files[].path] == ([.files[].path] | sort))
  ' "${manifest}" >/dev/null ||
    fail 'payload manifest is not the frozen Stage 3 schema-3/151-file shape'

  while IFS=$'\t' read -r path source mode validator expected_hash extra; do
    [[ -n "${path}" && -n "${source}" && -n "${mode}" &&
       -n "${validator}" && -n "${expected_hash}" && -z "${extra}" ]] ||
      fail "malformed payload record while building ${variant}"
    actual_hash="$(sha256_file "${payload}/${source}")" ||
      fail "could not hash ${source} while building ${variant}"
    [[ "${actual_hash}" == "${expected_hash}" ]] ||
      fail "payload hash is stale for ${source} while building ${variant}"
  done < <(jq -r '.files[] |
    [.path,.source,.mode,.validator,.sha256] | @tsv' "${manifest}")

  manifest_hash="$(sha256_file "${manifest}")" ||
    fail "could not hash ${variant} manifest"
  jq -cn \
    --arg path 'cntools/manifest.json' \
    --arg source "${MANIFEST_RELATIVE}" \
    --arg mode '0444' \
    --arg validator 'json' \
    --arg sha256 "${manifest_hash}" \
    '{path:$path, source:$source, mode:$mode,
      validator:$validator, sha256:$sha256}' > "${inventory}"
  jq -c '.files[]' "${manifest}" >> "${inventory}"
  jq -r -s 'sort_by(.path)[] | [.path,.mode,.sha256] | @tsv' \
    "${inventory}" > "${canonical}"
  generation_id="$(sha256_file "${canonical}")" ||
    fail "could not calculate ${variant} generation ID"
  mkdir -p -- "${generations}"
  chmod 0755 "${node}" "${node}/scripts"
  chmod 0700 "${node}/scripts/.cntools" "${generations}"
  generation="${generations}/${generation_id}"
  mkdir -p -- "${generation}/cntools"

  cp -- "${manifest}" "${generation}/cntools/manifest.json"
  chmod 0444 "${generation}/cntools/manifest.json"
  while IFS=$'\t' read -r path source mode validator expected_hash extra; do
    source_file="${payload}/${source}"
    target="${generation}/${path}"
    mkdir -p -- "$(dirname -- "${target}")"
    cp -- "${source_file}" "${target}"
    chmod "${mode}" "${target}"
  done < <(jq -r '.files[] |
    [.path,.source,.mode,.validator,.sha256] | @tsv' "${manifest}")

  jq -s \
    --arg id "${generation_id}" \
    --arg manifest_hash "${manifest_hash}" \
    --arg version "$(jq -er '.version' "${manifest}")" '
      {
        schemaVersion: 3,
        id: $id,
        version: $version,
        generationIdAlgorithm: "sha256-path-mode-content-v1",
        payloadManifest: "cntools/manifest.json",
        payloadManifestSha256: $manifest_hash,
        files: sort_by(.path)
      }
    ' "${inventory}" > "${generation}/.generation.json"
  chmod 0444 "${generation}/.generation.json"
  find "${generation}" -depth -type d -exec chmod 0555 {} +
  printf '%s\n' "${generation}"
}

node_for_generation() {
  local generation="$1"
  local suffix="${generation#*/scripts/.cntools/generations/}"

  [[ "${suffix}" != "${generation}" && "${suffix}" != */* ]] || return 1
  printf '%s\n' "${generation%/scripts/.cntools/generations/*}"
}

bind_deployment_authority() {
  local generation="$1"
  local implementation="${2:-cnode}"
  local source_state="${3:-dirty}"
  local node="" id="" relative="" manifest_hash="" receipt_hash=""
  local generation_receipt_hash="" outer_receipt="" metadata=""
  local outer_file_count=0 source_dirty=""

  node="$(node_for_generation "${generation}")" || return 1
  id="${generation##*/}"
  relative="scripts/.cntools/generations/${id}"
  outer_receipt="${node}/.guild-source-receipt.json"
  metadata="${node}/.deployment.json"
  case "${implementation}" in
    cnode) outer_file_count=48 ;;
    dingo) outer_file_count=25 ;;
    *) return 1 ;;
  esac
  case "${source_state}" in
    dirty) source_dirty=true ;;
    clean) source_dirty=false ;;
    *) return 1 ;;
  esac
  manifest_hash="$(sha256_file "${generation}/cntools/manifest.json")" ||
    return 1
  generation_receipt_hash="$(sha256_file "${generation}/.generation.json")" ||
    return 1
  jq -n --arg implementation "${implementation}" --arg id "${id}" \
    --arg relative "${relative}" --arg manifest_hash "${manifest_hash}" \
    --arg generation_receipt_hash "${generation_receipt_hash}" \
    --argjson outer_file_count "${outer_file_count}" \
    --argjson source_dirty "${source_dirty}" '
      {
        schemaVersion: 2,
        implementation: $implementation,
        network: "preview",
        source: ({
          repository: "cardano-community/guild-operators",
          channel: "main",
          ref: "refs/heads/main",
          revision: ("a" * 40),
          mode: "local",
          dirty: $source_dirty
        } + (if $source_dirty then {treeDigest: ("b" * 64)} else {} end)),
        cntoolsGeneration: {
          schemaVersion: 1,
          id: $id,
          version: "13.5.7",
          path: $relative,
          payloadManifest: ($relative + "/cntools/manifest.json"),
          payloadManifestSha256: $manifest_hash,
          generationReceipt: ($relative + "/.generation.json"),
          generationReceiptSha256: $generation_receipt_hash,
          fileCount: 152,
          active: false
        },
        files: [range(0; $outer_file_count) as $index |
          (($index + 1) |
            if . < 10 then "0" + tostring else tostring end) as $suffix | {
          path: ("files/diagnostic-" + $suffix),
          source: ("files/diagnostic-" + $suffix),
          mode: "0444",
          policy: "diagnostic-fixture",
          sourceSha256: ("c" * 64),
          installedSha256: ("d" * 64),
          managed: true
        }]
      }
    ' > "${outer_receipt}" || return 1
  chmod 0644 "${outer_receipt}" || return 1
  receipt_hash="$(sha256_file "${outer_receipt}")" || return 1
  jq -n --arg implementation "${implementation}" \
    --arg receipt_hash "${receipt_hash}" \
    --argjson source_dirty "${source_dirty}" '
      ({
        schemaVersion: 1,
        deploymentStatus: "deployed",
        implementation: $implementation,
        network: "preview",
        branch: "main",
        repository: "cardano-community/guild-operators",
        sourceSchemaVersion: 2,
        sourceMode: "local",
        sourceRef: "refs/heads/main",
        sourceRevision: ("a" * 40),
        sourceDirty: $source_dirty,
        payloadReceipt: ".guild-source-receipt.json",
        payloadReceiptSha256: $receipt_hash,
        transactionId: $receipt_hash[0:24],
        serviceName: "cardano-node",
        nodePort: 6000,
        nodeVersion: "",
        targetNodeVersion: "",
        metricsProvider: "none",
        capabilities: {
          n2c: true, localCli: true, metrics: true, forging: false
        }
      } + (if $source_dirty then {sourceTreeDigest: ("b" * 64)} else {} end))
    ' > "${metadata}" || return 1
  chmod 0644 "${metadata}" || return 1
}

assert_outer_fixture() {
  local generation="$1"
  local node="" id="" receipt="" metadata="" receipt_hash=""

  node="$(node_for_generation "${generation}")" || return 1
  id="${generation##*/}"
  receipt="${node}/.guild-source-receipt.json"
  metadata="${node}/.deployment.json"
  receipt_hash="$(sha256_file "${receipt}")" || return 1
  jq -e --arg id "${id}" '
    keys == ["cntoolsGeneration", "files", "implementation", "network",
      "schemaVersion", "source"] and
    .schemaVersion == 2 and
    (.implementation == "cnode" or .implementation == "dingo") and
    .network == "preview" and
    .source.repository == "cardano-community/guild-operators" and
    .source.channel == "main" and
    .source.ref == "refs/heads/main" and
    .source.revision == ("a" * 40) and .source.mode == "local" and
    (.source.dirty | type == "boolean") and
    (if .source.dirty then
       (.source | keys == ["channel", "dirty", "mode", "ref", "repository",
         "revision", "treeDigest"]) and
       (.source.treeDigest | test("^[0-9a-f]{64}$"))
     else
       (.source | keys == ["channel", "dirty", "mode", "ref", "repository",
         "revision"])
     end) and
    (.cntoolsGeneration | keys == ["active", "fileCount",
      "generationReceipt", "generationReceiptSha256", "id", "path",
      "payloadManifest", "payloadManifestSha256", "schemaVersion",
      "version"]) and
    .cntoolsGeneration.id == $id and
    .cntoolsGeneration.schemaVersion == 1 and
    .cntoolsGeneration.version == "13.5.7" and
    .cntoolsGeneration.path ==
      ("scripts/.cntools/generations/" + $id) and
    .cntoolsGeneration.payloadManifest ==
      (.cntoolsGeneration.path + "/cntools/manifest.json") and
    .cntoolsGeneration.generationReceipt ==
      (.cntoolsGeneration.path + "/.generation.json") and
    (.cntoolsGeneration.payloadManifestSha256 |
      test("^[0-9a-f]{64}$")) and
    (.cntoolsGeneration.generationReceiptSha256 |
      test("^[0-9a-f]{64}$")) and
    .cntoolsGeneration.fileCount == 152 and
    .cntoolsGeneration.active == false and
    (.files | length) ==
      (if .implementation == "cnode" then 48 else 25 end) and
    ([.files[].path] == ([.files[].path] | sort)) and
    ([.files[].path] | length) == ([.files[].path] | unique | length) and
    all(.files[]; keys == ["installedSha256", "managed", "mode", "path",
      "policy", "source", "sourceSha256"] and
      (.path | test("^files/diagnostic-[0-9]{2}$")) and
      .source == .path and .mode == "0444" and
      .policy == "diagnostic-fixture" and .managed == true and
      (.sourceSha256 | test("^[0-9a-f]{64}$")) and
      (.installedSha256 | test("^[0-9a-f]{64}$")))
  ' "${receipt}" >/dev/null || return 1
  jq -e --arg receipt_hash "${receipt_hash}" --slurpfile receipt "${receipt}" '
    (if .sourceDirty then
       keys == ["branch", "capabilities", "deploymentStatus", "implementation",
         "metricsProvider", "network", "nodePort", "nodeVersion",
         "payloadReceipt", "payloadReceiptSha256", "repository", "schemaVersion",
         "serviceName", "sourceDirty", "sourceMode", "sourceRef",
         "sourceRevision", "sourceSchemaVersion", "sourceTreeDigest",
         "targetNodeVersion", "transactionId"]
     else
       keys == ["branch", "capabilities", "deploymentStatus", "implementation",
         "metricsProvider", "network", "nodePort", "nodeVersion",
         "payloadReceipt", "payloadReceiptSha256", "repository", "schemaVersion",
         "serviceName", "sourceDirty", "sourceMode", "sourceRef",
         "sourceRevision", "sourceSchemaVersion", "targetNodeVersion",
         "transactionId"]
     end) and
    .schemaVersion == 1 and .deploymentStatus == "deployed" and
    .sourceSchemaVersion == 2 and
    .implementation == $receipt[0].implementation and
    .network == $receipt[0].network and
    .repository == $receipt[0].source.repository and
    .branch == $receipt[0].source.channel and
    .sourceMode == $receipt[0].source.mode and
    .sourceRef == $receipt[0].source.ref and
    .sourceRevision == $receipt[0].source.revision and
    .payloadReceipt == ".guild-source-receipt.json" and
    .payloadReceiptSha256 == $receipt_hash and
    .transactionId == $receipt_hash[0:24] and
    .sourceDirty == $receipt[0].source.dirty and
    (if .sourceDirty then
       .sourceTreeDigest == $receipt[0].source.treeDigest
     else has("sourceTreeDigest") | not end) and
    .capabilities == {
      forging: false, localCli: true, metrics: true, n2c: true
    }
  ' "${metadata}" >/dev/null
}

rebind_outer_receipt_hash() {
  local generation="$1"
  local node="" receipt="" metadata="" receipt_hash=""

  node="$(node_for_generation "${generation}")" || return 1
  receipt="${node}/.guild-source-receipt.json"
  metadata="${node}/.deployment.json"
  receipt_hash="$(sha256_file "${receipt}")" || return 1
  atomic_jq_update "${metadata}" --arg hash "${receipt_hash}" '
    .payloadReceiptSha256 = $hash |
    .transactionId = $hash[0:24]
  ' || return 1
  chmod 0644 "${metadata}"
}

clone_bound_node() {
  local source_generation="$1"
  local variant="$2"
  local source_node="" destination="" id=""

  source_node="$(node_for_generation "${source_generation}")" || return 1
  destination="${TEST_ROOT}/clone-${variant}"
  id="${source_generation##*/}"
  cp -R -- "${source_node}" "${destination}" || return 1
  printf '%s\n' \
    "${destination}/scripts/.cntools/generations/${id}"
}

run_cli() {
  local generation="$1"
  local command="$2"
  local output="$3"
  local error="$4"
  local status_name="$5"
  local command_status=0

  "${BASH}" "${generation}/cntools.sh" "${command}" \
    > "${output}" 2> "${error}" || command_status=$?
  printf -v "${status_name}" '%s' "${command_status}"
}

expect_authority_failure() {
  local context="$1"
  local generation="$2"
  local output="${TEST_ROOT}/authority-${context}.stdout"
  local error="${TEST_ROOT}/authority-${context}.stderr"
  local failure_status=0

  run_cli "${generation}" --dump-menu "${output}" "${error}" failure_status
  [[ "${failure_status}" == 70 ]] ||
    fail "${context} returned ${failure_status}, expected authority status 70"
  [[ ! -s "${output}" ]] ||
    fail "${context} emitted stdout before authority refusal"
  [[ "$(< "${error}")" == "${EXPECTED_AUTHORITY_ERROR}" ]] ||
    fail "${context} authority error text changed"
}

assert_launcher_utility_collisions() {
  local generation="$1"
  local launcher="${generation}/cntools.sh"
  local sha_tool="" collision_kind="" tool="" sentinel="" probe=""
  local -a tools=(
    jq find stat sort dirname basename tr
    true sleep kill wait rm rmdir mkdir flock lockf
    cksum awk id ps uname chmod mktemp grep wc sed
  )
  local -a function_only_tools=(local return cntools_hostile_probe)
  local -a collision_tools=()

  if builtin type -P sha256sum >/dev/null 2>&1; then
    sha_tool=sha256sum
  else
    sha_tool=shasum
  fi
  tools+=("${sha_tool}")
  for collision_kind in function alias; do
    collision_tools=("${tools[@]}")
    if [[ "${collision_kind}" == function ]]; then
      collision_tools+=("${function_only_tools[@]}")
    fi
    for tool in "${collision_tools[@]}"; do
      sentinel="${TEST_ROOT}/launcher-${collision_kind}-${tool}.executed"
      probe="$({
        "${BASH}" -c '
          set -euo pipefail
          launcher=$1
          tool=$2
          kind=$3
          sentinel=$4
          expected_error=$5
          output=$6
          error=$7
          if [[ "${kind}" == function ]]; then
            builtin eval "${tool}() {
              builtin printf executed > \"\${sentinel}\"
              builtin return 97
            }"
            export -f "${tool}"
          else
            shopt -s expand_aliases
            builtin printf -v quoted_sentinel %q "${sentinel}"
            alias "${tool}=builtin printf executed > ${quoted_sentinel}; builtin false"
          fi
          # Parse the sourced launcher only after the alias/function exists.
          builtin eval '\''builtin source "${launcher}"'\''
          status=0
          cntools_launcher_main --dump-menu > "${output}" 2> "${error}" ||
            status=$?
          [[ "${status}" == 70 && ! -s "${output}" &&
             "$(< "${error}")" == "${expected_error}" &&
             ! -e "${sentinel}" && ! -L "${sentinel}" ]]
        ' bash "${launcher}" "${tool}" "${collision_kind}" "${sentinel}" \
          "${EXPECTED_AUTHORITY_ERROR}" \
          "${TEST_ROOT}/launcher-collision.stdout" \
          "${TEST_ROOT}/launcher-collision.stderr"
      } 2>&1)" ||
        fail "installed launcher did not fail closed for ${collision_kind} ${tool}"
      [[ -z "${probe}" ]] ||
        fail "${collision_kind} ${tool} launcher collision produced output: ${probe}"
    done
  done
}

assert_lifecycle_holder_clean_environment() {
  local generation="$1"
  local node="" root="" lifecycle="" sentinel="" probe=""

  node="$(node_for_generation "${generation}")" || return 1
  root="${node}/scripts/.cntools"
  lifecycle="${generation}/cntools/core/lifecycle.sh"
  sentinel="${TEST_ROOT}/lifecycle-holder-backend.executed"
  probe="$({
    "${BASH}" --noprofile --norc -c '
      set -euo pipefail
      lifecycle=$1
      root=$2
      sentinel=$3
      bash_path=$4
      lock_acquired=N
      cleanup_direct_holder_probe() {
        if [[ "${lock_acquired}" == Y ]]; then
          cntools_generation_lock_release "${root}" >/dev/null 2>&1 || true
        fi
      }
      trap cleanup_direct_holder_probe EXIT
      # shellcheck source=/dev/null
      . "${lifecycle}"
      case "$(command -p uname -s 2>/dev/null)" in
        Linux) backend=flock ;;
        Darwin|FreeBSD|OpenBSD|NetBSD) backend=lockf ;;
        *) exit 2 ;;
      esac
      builtin printf -v quoted_sentinel %q "${sentinel}"
      builtin eval "${backend}() {
        builtin printf executed > ${quoted_sentinel}
        builtin return 97
      }"
      export -f "${backend}"

      cntools_generation_lock_acquire "${root}"
      lock_acquired=Y
      [[ ! -e "${sentinel}" && ! -L "${sentinel}" ]]
      contender_status=0
      "${bash_path}" --noprofile --norc -c '\''
        set -euo pipefail
        # shellcheck source=/dev/null
        . "$1"
        cntools_generation_lock_acquire "$2"
      '\'' _ "${lifecycle}" "${root}" >/dev/null 2>&1 ||
        contender_status=$?
      [[ ${contender_status} -eq 1 ]]
      [[ ! -e "${sentinel}" && ! -L "${sentinel}" ]]

      cntools_generation_lock_release "${root}"
      lock_acquired=N
      unset -f "${backend}"
      cntools_generation_lock_acquire "${root}"
      lock_acquired=Y
      cntools_generation_lock_release "${root}"
      lock_acquired=N
      [[ ! -e "${sentinel}" && ! -L "${sentinel}" ]]
      trap - EXIT
    ' _ "${lifecycle}" "${root}" "${sentinel}" "${BASH}"
  } 2>&1)" ||
    fail 'direct lifecycle holder did not sanitize its backend environment'
  [[ -z "${probe}" ]] ||
    fail "direct lifecycle holder probe produced output: ${probe}"
}

hold_generation_lock() {
  local generation="$1"
  local node="" cntools_root="" lifecycle="" ready="" control=""
  local attempt=0

  node="$(node_for_generation "${generation}")" || return 1
  cntools_root="${node}/scripts/.cntools"
  lifecycle="${generation}/cntools/core/lifecycle.sh"
  ready="${TEST_ROOT}/lock-holder.ready"
  control="${TEST_ROOT}/lock-holder.control"
  rm -f -- "${ready}" "${control}"
  mkfifo "${control}" || return 1
  "${BASH}" -c '
    set -euo pipefail
    lifecycle=$1
    root=$2
    ready=$3
    control=$4
    # shellcheck source=/dev/null
    . "${lifecycle}"
    cntools_generation_lock_acquire "${root}"
    : > "${ready}"
    IFS= read -r release < "${control}"
    [[ "${release}" == release ]]
    cntools_generation_lock_release "${root}"
  ' bash "${lifecycle}" "${cntools_root}" "${ready}" "${control}" \
    > "${TEST_ROOT}/lock-holder.stdout" \
    2> "${TEST_ROOT}/lock-holder.stderr" &
  LOCK_HOLDER_PID=$!
  LOCK_HOLDER_CONTROL="${control}"
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ ! -e "${ready}" ]] || return 0
    kill -0 "${LOCK_HOLDER_PID}" >/dev/null 2>&1 || break
    sleep 0.05
  done
  return 1
}

release_generation_lock() {
  local holder_status=0

  [[ -n "${LOCK_HOLDER_PID}" && -p "${LOCK_HOLDER_CONTROL}" ]] || return 1
  printf 'release\n' > "${LOCK_HOLDER_CONTROL}"
  wait "${LOCK_HOLDER_PID}" || holder_status=$?
  LOCK_HOLDER_PID=""
  LOCK_HOLDER_CONTROL=""
  (( holder_status == 0 )) || return "${holder_status}"
  [[ ! -s "${TEST_ROOT}/lock-holder.stdout" &&
     ! -s "${TEST_ROOT}/lock-holder.stderr" ]]
}

[[ -f "${SOURCE_MANIFEST}" && ! -L "${SOURCE_MANIFEST}" ]] ||
  fail 'source payload manifest is missing or unsafe'
[[ -f "${MENU_ORACLE}" && ! -L "${MENU_ORACLE}" ]] ||
  fail 'Stage 3 menu dump oracle is missing or unsafe'

canonical_payload="$(prepare_payload canonical)"
canonical_generation="$(build_generation "${canonical_payload}" canonical)"
canonical_node="$(node_for_generation "${canonical_generation}")"
stdout_file="${TEST_ROOT}/canonical.stdout"
stderr_file="${TEST_ROOT}/canonical.stderr"
status=0

# A self-consistent generation is not a provenance anchor by itself.
expect_authority_failure unbound-generation "${canonical_generation}"
bind_deployment_authority "${canonical_generation}" cnode ||
  fail 'could not bind the canonical generation to deployment authority'
assert_outer_fixture "${canonical_generation}" ||
  fail 'canonical outer authority fixture violates the frozen contract'
jq -e -s '
  .[0].cntoolsGeneration.version == "13.5.7" and
  .[1].version == "13.5.7" and .[2].version == "13.5.7" and
  .[0].cntoolsGeneration.version == .[1].version and
  .[1].version == .[2].version
' "${canonical_node}/.guild-source-receipt.json" \
  "${canonical_generation}/cntools/manifest.json" \
  "${canonical_generation}/.generation.json" >/dev/null ||
  fail 'canonical outer/manifest/receipt version handshake is not exact'
assert_lifecycle_holder_clean_environment "${canonical_generation}"
assert_launcher_utility_collisions "${canonical_generation}"

run_cli "${canonical_generation}" --validate-modules \
  "${stdout_file}" "${stderr_file}" status
[[ "${status}" == 0 ]] || fail "--validate-modules returned ${status}"
[[ ! -s "${stderr_file}" ]] || fail '--validate-modules wrote to stderr'
[[ "$(< "${stdout_file}")" == "${EXPECTED_VALIDATE}" ]] ||
  fail '--validate-modules success text or counts changed'

run_cli "${canonical_generation}" --dump-menu \
  "${stdout_file}" "${stderr_file}" status
[[ "${status}" == 0 ]] || fail "--dump-menu returned ${status}"
[[ ! -s "${stderr_file}" ]] || fail '--dump-menu wrote to stderr'
cmp -s "${MENU_ORACLE}" "${stdout_file}" || {
  diff -u "${MENU_ORACLE}" "${stdout_file}" >&2 || true
  fail '--dump-menu differs byte-for-byte from the Stage 3 oracle'
}

dingo_generation="$(clone_bound_node "${canonical_generation}" dingo-bound)"
bind_deployment_authority "${dingo_generation}" dingo ||
  fail 'could not bind the Dingo diagnostic fixture'
assert_outer_fixture "${dingo_generation}" ||
  fail 'Dingo outer authority fixture violates the frozen contract'
run_cli "${dingo_generation}" --validate-modules \
  "${TEST_ROOT}/dingo.stdout" "${TEST_ROOT}/dingo.stderr" status
[[ "${status}" == 0 && ! -s "${TEST_ROOT}/dingo.stderr" &&
   "$(< "${TEST_ROOT}/dingo.stdout")" == "${EXPECTED_VALIDATE}" ]] ||
  fail 'Dingo-bound --validate-modules diagnostic failed'

clean_generation="$(clone_bound_node "${canonical_generation}" clean-bound)"
bind_deployment_authority "${clean_generation}" cnode clean ||
  fail 'could not bind the clean-source diagnostic fixture'
assert_outer_fixture "${clean_generation}" ||
  fail 'clean-source outer authority fixture violates its 6/20-key contract'
run_cli "${clean_generation}" --dump-menu \
  "${TEST_ROOT}/clean.stdout" "${TEST_ROOT}/clean.stderr" status
[[ "${status}" == 0 && ! -s "${TEST_ROOT}/clean.stderr" ]] ||
  fail 'clean-source bound --dump-menu diagnostic failed'
cmp -s "${MENU_ORACLE}" "${TEST_ROOT}/clean.stdout" ||
  fail 'clean-source bound menu dump differs from the frozen oracle'

# Outer file records remain untrusted path data even after the receipt hash is
# rebound into deployment metadata. Start from an exactly ordered valid
# emitter and use an authenticated lifecycle canary to prove each malformed
# path/source is rejected before any generation source occurs.
outer_path_payload="$(prepare_payload outer-path-canary)"
outer_path_lifecycle_source='scripts/common-helper-scripts/cntools/core/lifecycle.sh'
outer_path_sentinel="${TEST_ROOT}/outer-path-lifecycle.executed"
printf '\nbuiltin printf executed > %q\n' "${outer_path_sentinel}" >> \
  "${outer_path_payload}/${outer_path_lifecycle_source}"
update_payload_hash "${outer_path_payload}" "${outer_path_lifecycle_source}" ||
  fail 'could not hash the outer-path lifecycle canary'
outer_path_generation="$(build_generation \
  "${outer_path_payload}" outer-path-canary)"
bind_deployment_authority "${outer_path_generation}" cnode ||
  fail 'could not bind the valid outer-path canary generation'
assert_outer_fixture "${outer_path_generation}" ||
  fail 'valid outer-path emitter lost its frozen ordering or record shape'
for outer_path_case in \
  path-dot-component path-traversal-component \
  source-dot-component source-traversal source-absolute; do
  outer_path_mutation="$(clone_bound_node \
    "${outer_path_generation}" "${outer_path_case}")"
  outer_path_node="$(node_for_generation "${outer_path_mutation}")"
  case "${outer_path_case}" in
    path-dot-component)
      outer_path_filter='.files[0].path = "files/./diagnostic-01"'
      ;;
    path-traversal-component)
      outer_path_filter='.files[0].path = "files/../diagnostic-01"'
      ;;
    source-dot-component)
      outer_path_filter='.files[0].source = "files/./diagnostic-01"'
      ;;
    source-traversal)
      outer_path_filter='.files[0].source = "../diagnostic-01"'
      ;;
    source-absolute)
      outer_path_filter='.files[0].source = "/tmp/diagnostic-01"'
      ;;
  esac
  atomic_jq_update "${outer_path_node}/.guild-source-receipt.json" \
    "${outer_path_filter}" ||
    fail "could not create ${outer_path_case} outer record mutation"
  chmod 0644 "${outer_path_node}/.guild-source-receipt.json"
  rebind_outer_receipt_hash "${outer_path_mutation}" ||
    fail "could not rebind ${outer_path_case} outer receipt mutation"
  expect_authority_failure "${outer_path_case}" "${outer_path_mutation}"
  [[ ! -e "${outer_path_sentinel}" && ! -L "${outer_path_sentinel}" ]] ||
    fail "${outer_path_case} was rejected only after lifecycle source"
done

# The deployment receipt is the version authority. A fully rehashed and
# re-ID'd generation whose inner manifest and receipt agree with each other,
# but not with the outer 13.5.7 binding, must be refused before lifecycle
# source. The authenticated top-level canary makes that ordering observable.
version_payload="$(prepare_payload version-mismatch)"
version_lifecycle_source='scripts/common-helper-scripts/cntools/core/lifecycle.sh'
version_sentinel="${TEST_ROOT}/version-mismatch-lifecycle.executed"
printf '\nbuiltin printf executed > %q\n' "${version_sentinel}" >> \
  "${version_payload}/${version_lifecycle_source}"
update_payload_hash "${version_payload}" "${version_lifecycle_source}" ||
  fail 'could not hash the version-mismatch lifecycle canary'
atomic_jq_update "${version_payload}/${MANIFEST_RELATIVE}" \
  '.version = "13.5.8"' ||
  fail 'could not create the inner version-mismatch manifest'
version_generation="$(build_generation \
  "${version_payload}" version-mismatch)"
bind_deployment_authority "${version_generation}" cnode ||
  fail 'could not outer-bind the inner version-mismatch generation'
assert_outer_fixture "${version_generation}" ||
  fail 'version-mismatch outer authority fixture violates the frozen contract'
jq -e '.version == "13.5.8"' \
  "${version_generation}/cntools/manifest.json" >/dev/null &&
  jq -e '.version == "13.5.8"' \
    "${version_generation}/.generation.json" >/dev/null &&
  jq -e '.cntoolsGeneration.version == "13.5.7"' \
    "$(node_for_generation "${version_generation}")/.guild-source-receipt.json" \
    >/dev/null ||
  fail 'version-mismatch fixture did not preserve exact inner/outer versions'
expect_authority_failure inner-version-mismatch "${version_generation}"
[[ ! -e "${version_sentinel}" && ! -L "${version_sentinel}" ]] ||
  fail 'inner version mismatch was detected only after lifecycle source'

CNTOOLS_MODE=offline CNTOOLS_FEATURES=none CNTOOLS_NODE_CAPABILITIES=none \
  run_cli "${canonical_generation}" --dump-menu \
    "${TEST_ROOT}/context.stdout" "${TEST_ROOT}/context.stderr" status
[[ "${status}" == 0 && ! -s "${TEST_ROOT}/context.stderr" ]] ||
  fail '--dump-menu depends on ambient runtime context'
cmp -s "${MENU_ORACLE}" "${TEST_ROOT}/context.stdout" ||
  fail '--dump-menu filters its static output using ambient context'
(
  cd "${TEST_ROOT}"
  LC_ALL=POSIX "${BASH}" "${canonical_generation}/cntools.sh" --dump-menu
) > "${TEST_ROOT}/cwd.stdout" 2> "${TEST_ROOT}/cwd.stderr" ||
  fail '--dump-menu depends on caller working directory or locale'
[[ ! -s "${TEST_ROOT}/cwd.stderr" ]] ||
  fail 'arbitrary-cwd/locale --dump-menu wrote to stderr'
cmp -s "${MENU_ORACLE}" "${TEST_ROOT}/cwd.stdout" ||
  fail '--dump-menu changed with caller working directory or locale'

invalid_payload="$(prepare_payload invalid-registry)"
invalid_metadata_source='scripts/common-helper-scripts/cntools/modules/root/wallet/module.json'
atomic_jq_update "${invalid_payload}/${invalid_metadata_source}" \
  '.controlPolicy = "custom"'
update_payload_hash "${invalid_payload}" "${invalid_metadata_source}"
invalid_generation="$(build_generation "${invalid_payload}" invalid-registry)"
bind_deployment_authority "${invalid_generation}" cnode ||
  fail 'could not bind the invalid-registry diagnostic fixture'

for diagnostic in --validate-modules --dump-menu; do
  run_cli "${invalid_generation}" "${diagnostic}" \
    "${TEST_ROOT}/invalid.stdout" "${TEST_ROOT}/invalid.stderr" status
  [[ "${status}" == 2 ]] ||
    fail "${diagnostic} returned ${status}, expected registry status 2"
  [[ ! -s "${TEST_ROOT}/invalid.stdout" ]] ||
    fail "${diagnostic} emitted partial stdout for an invalid registry"
  [[ "$(< "${TEST_ROOT}/invalid.stderr")" == "${EXPECTED_REGISTRY_ERROR}" ]] ||
    fail "${diagnostic} registry error text changed"
done

nonexecution_payload="$(prepare_payload nonexecution)"
probe_source='scripts/common-helper-scripts/cntools/modules/root/wallet/register/action.sh'
sentinel="${TEST_ROOT}/action.executed"
printf '\nprintf executed > %q\n' "${sentinel}" >> \
  "${nonexecution_payload}/${probe_source}"
update_payload_hash "${nonexecution_payload}" "${probe_source}"
nonexecution_generation="$(build_generation "${nonexecution_payload}" nonexecution)"
bind_deployment_authority "${nonexecution_generation}" cnode ||
  fail 'could not bind the nonexecution diagnostic fixture'
run_cli "${nonexecution_generation}" --dump-menu \
  "${TEST_ROOT}/nonexecution.stdout" "${TEST_ROOT}/nonexecution.stderr" status
[[ "${status}" == 0 && ! -s "${TEST_ROOT}/nonexecution.stderr" ]] ||
  fail '--dump-menu rejected the nonexecution probe generation'
[[ ! -e "${sentinel}" && ! -L "${sentinel}" ]] ||
  fail '--dump-menu executed an action entrypoint'

# A different fully rehashed generation under the same node is still
# unauthorized until the outer receipt and metadata bind that exact ID.
forged_payload="$(prepare_payload forged-unbound)"
printf '\nRehashed but not deployment-authorized.\n' >> \
  "${forged_payload}/scripts/common-helper-scripts/cntools/docs/TESTING.md"
update_payload_hash "${forged_payload}" \
  scripts/common-helper-scripts/cntools/docs/TESTING.md
forged_generation="$(build_generation "${forged_payload}" forged-unbound)"
forged_id="${forged_generation##*/}"
cp -R -- "${forged_generation}" \
  "${canonical_node}/scripts/.cntools/generations/${forged_id}"
unbound_forged="${canonical_node}/scripts/.cntools/generations/${forged_id}"
expect_authority_failure rehashed-unbound-generation "${unbound_forged}"

# A caller-writable PATH shadow is not a trusted diagnostic dependency. It
# must be rejected without executing the shadowed utility.
shadow_bin="${TEST_ROOT}/path-shadow-bin"
shadow_sentinel="${TEST_ROOT}/path-shadow.executed"
mkdir -- "${shadow_bin}"
{
  printf '%s\n' '#!/bin/sh'
  printf 'printf executed > %q\n' "${shadow_sentinel}"
  printf '%s\n' 'exit 97'
} > "${shadow_bin}/jq"
chmod 0755 "${shadow_bin}/jq"
PATH="${shadow_bin}:${PATH}" \
  expect_authority_failure path-shadowed-jq "${canonical_generation}"
[[ ! -e "${shadow_sentinel}" && ! -L "${shadow_sentinel}" ]] ||
  fail 'installed diagnostics executed a caller PATH-shadowed utility'

metadata_mismatch_generation="$(clone_bound_node \
  "${canonical_generation}" metadata-mismatch)"
metadata_mismatch_node="$(node_for_generation "${metadata_mismatch_generation}")"
chmod u+w "${metadata_mismatch_node}/.deployment.json"
atomic_jq_update "${metadata_mismatch_node}/.deployment.json" \
  '.payloadReceiptSha256 = ("0" * 64)'
chmod 0644 "${metadata_mismatch_node}/.deployment.json"
expect_authority_failure receipt-metadata-mismatch \
  "${metadata_mismatch_generation}"

receipt_mismatch_generation="$(clone_bound_node \
  "${canonical_generation}" receipt-mismatch)"
receipt_mismatch_node="$(node_for_generation "${receipt_mismatch_generation}")"
chmod u+w "${receipt_mismatch_node}/.guild-source-receipt.json"
atomic_jq_update "${receipt_mismatch_node}/.guild-source-receipt.json" \
  '.network = "mainnet"'
chmod 0644 "${receipt_mismatch_node}/.guild-source-receipt.json"
expect_authority_failure changed-outer-receipt "${receipt_mismatch_generation}"

clean_receipt_tree_generation="$(clone_bound_node \
  "${clean_generation}" clean-receipt-unexpected-tree)"
clean_receipt_tree_node="$(node_for_generation \
  "${clean_receipt_tree_generation}")"
atomic_jq_update \
  "${clean_receipt_tree_node}/.guild-source-receipt.json" \
  '.source.treeDigest = ("e" * 64)'
chmod 0644 "${clean_receipt_tree_node}/.guild-source-receipt.json"
rebind_outer_receipt_hash "${clean_receipt_tree_generation}" ||
  fail 'could not rebind the clean receipt tree-presence mutation'
expect_authority_failure clean-receipt-unexpected-tree \
  "${clean_receipt_tree_generation}"

clean_metadata_tree_generation="$(clone_bound_node \
  "${clean_generation}" clean-metadata-unexpected-tree)"
clean_metadata_tree_node="$(node_for_generation \
  "${clean_metadata_tree_generation}")"
atomic_jq_update "${clean_metadata_tree_node}/.deployment.json" \
  '.sourceTreeDigest = ("e" * 64)'
chmod 0644 "${clean_metadata_tree_node}/.deployment.json"
expect_authority_failure clean-metadata-unexpected-tree \
  "${clean_metadata_tree_generation}"

dirty_missing_tree_generation="$(clone_bound_node \
  "${canonical_generation}" dirty-missing-tree)"
dirty_missing_tree_node="$(node_for_generation \
  "${dirty_missing_tree_generation}")"
atomic_jq_update \
  "${dirty_missing_tree_node}/.guild-source-receipt.json" \
  'del(.source.treeDigest)'
atomic_jq_update "${dirty_missing_tree_node}/.deployment.json" \
  'del(.sourceTreeDigest)'
chmod 0644 "${dirty_missing_tree_node}/.guild-source-receipt.json" \
  "${dirty_missing_tree_node}/.deployment.json"
rebind_outer_receipt_hash "${dirty_missing_tree_generation}" ||
  fail 'could not rebind the dirty missing-tree mutation'
expect_authority_failure dirty-missing-tree "${dirty_missing_tree_generation}"

dirty_tree_mismatch_generation="$(clone_bound_node \
  "${canonical_generation}" dirty-tree-value-mismatch)"
dirty_tree_mismatch_node="$(node_for_generation \
  "${dirty_tree_mismatch_generation}")"
atomic_jq_update \
  "${dirty_tree_mismatch_node}/.guild-source-receipt.json" \
  '.source.treeDigest = ("e" * 64)'
chmod 0644 "${dirty_tree_mismatch_node}/.guild-source-receipt.json"
rebind_outer_receipt_hash "${dirty_tree_mismatch_generation}" ||
  fail 'could not rebind the dirty tree-value mismatch'
expect_authority_failure dirty-tree-value-mismatch \
  "${dirty_tree_mismatch_generation}"

for mode_case in receipt metadata cntools-root generation-root; do
  mode_generation="$(clone_bound_node \
    "${canonical_generation}" "wrong-mode-${mode_case}")"
  mode_node="$(node_for_generation "${mode_generation}")"
  case "${mode_case}" in
    receipt) chmod 0600 "${mode_node}/.guild-source-receipt.json" ;;
    metadata) chmod 0600 "${mode_node}/.deployment.json" ;;
    cntools-root) chmod 0755 "${mode_node}/scripts/.cntools" ;;
    generation-root) chmod 0755 "${mode_generation}" ;;
  esac
  expect_authority_failure "wrong-mode-${mode_case}" "${mode_generation}"
done

symlink_generation="$(clone_bound_node "${canonical_generation}" symlink-root)"
symlink_node="$(node_for_generation "${symlink_generation}")"
symlink_id="${symlink_generation##*/}"
mv -- "${symlink_node}/scripts/.cntools" \
  "${symlink_node}/scripts/.cntools-real"
ln -s .cntools-real "${symlink_node}/scripts/.cntools"
expect_authority_failure symlinked-cntools-root \
  "${symlink_node}/scripts/.cntools/generations/${symlink_id}"

for journal_kind in file directory symlink; do
  journal_generation="$(clone_bound_node \
    "${canonical_generation}" "journal-${journal_kind}")"
  journal_node="$(node_for_generation "${journal_generation}")"
  case "${journal_kind}" in
    file) printf 'unsettled\n' > "${journal_node}/.guild-deploy-transaction" ;;
    directory) mkdir -- "${journal_node}/.guild-deploy-transaction" ;;
    symlink)
      ln -s .guild-source-receipt.json \
        "${journal_node}/.guild-deploy-transaction"
      ;;
  esac
  expect_authority_failure "outer-journal-${journal_kind}" \
    "${journal_generation}"
done

tampered_generation="$(clone_bound_node "${canonical_generation}" tampered)"
chmod u+w "${tampered_generation}/cntools/modules/root/wallet/module.json"
printf '\n' >> "${tampered_generation}/cntools/modules/root/wallet/module.json"
chmod 0444 "${tampered_generation}/cntools/modules/root/wallet/module.json"
expect_authority_failure tampered-generation "${tampered_generation}"

hold_generation_lock "${canonical_generation}" || {
  [[ ! -s "${TEST_ROOT}/lock-holder.stderr" ]] ||
    sed -n '1,80p' "${TEST_ROOT}/lock-holder.stderr" >&2
  fail 'could not acquire the live generation lock fixture'
}
expect_authority_failure live-generation-lock "${canonical_generation}"
release_generation_lock || fail 'could not release the live generation lock'

# A fully hashed and outer-bound test lifecycle mutates metadata immediately
# after acquiring the real advisory lock. The post-lock authority check must
# observe the changed binding before bootstrap or registry execution.
race_payload="$(prepare_payload binding-race)"
instrument_binding_race_payload "${race_payload}" ||
  fail 'could not instrument the post-lock authority-race fixture'
race_generation="$(build_generation "${race_payload}" binding-race)"
bind_deployment_authority "${race_generation}" cnode ||
  fail 'could not bind the post-lock authority-race fixture'
assert_outer_fixture "${race_generation}" ||
  fail 'post-lock authority-race fixture violates the outer contract'
race_marker="${TEST_ROOT}/binding-race.injected"
race_stdout="${TEST_ROOT}/authority-binding-race.stdout"
race_stderr="${TEST_ROOT}/authority-binding-race.stderr"
race_status=0
run_cli "${race_generation}" --dump-menu \
  "${race_stdout}" "${race_stderr}" race_status
[[ -e "${race_marker}" && "${race_status}" == 70 && ! -s "${race_stdout}" ]] ||
  fail 'outer-binding race was not injected and refused atomically'
[[ "$(< "${race_stderr}")" == "${EXPECTED_AUTHORITY_ERROR}" ]] ||
  fail 'outer-binding race authority error text changed'

printf 'CNTools Stage 3 generation diagnostic tests passed\n'
