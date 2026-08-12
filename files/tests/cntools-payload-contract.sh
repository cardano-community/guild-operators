#!/usr/bin/env bash
# Validate the Stage 3 CNTools payload as inert, strictly described source data.
# This suite is intentionally independent of the deployment implementation so
# a broken or weakened runtime validator cannot make its own fixture pass.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools payload contract tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

LC_ALL=C
export LC_ALL

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MANIFEST_RELATIVE="scripts/common-helper-scripts/cntools/manifest.json"
MANIFEST="${REPO_ROOT}/${MANIFEST_RELATIVE}"
EXPECTED_INVENTORY="${REPO_ROOT}/files/tests/fixtures/cntools-stage3-payload.tsv"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-payload.XXXXXX")"
TEST_ROOT="$(cd -P -- "${TEST_ROOT}" && pwd -P)"
ACTION_STUB_SHA256='fe54f5f35ace512a21c33038600b6f21039db1a4ce1cd54fc5f8a5c3890e5d1a'

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'CNTools payload contract test failed: %s\n' "$1" >&2
  exit 1
}

for required_command in awk cmp cp diff find grep jq ln mktemp mv sed sort; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done
if ! command -v sha256sum >/dev/null 2>&1 &&
   ! command -v shasum >/dev/null 2>&1; then
  fail "a SHA-256 command is unavailable"
fi

sha256_file() {
  local digest=""

  [[ -f "$1" && ! -L "$1" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum -- "$1")" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 -- "$1")" || return 1
  else
    return 1
  fi
  printf '%s\n' "${digest%% *}"
}

payload_path_valid() {
  local path="${1:-}"
  local component=""
  local -a components=()

  [[ -n "${path}" && "${path}" != /* && "${path}" != */ &&
     "${path}" != *//* && "${path}" != *\\* &&
     ! "${path}" =~ [[:cntrl:]] &&
     "${path}" =~ ^[A-Za-z0-9._/+@:-]+$ ]] || return 1
  IFS='/' read -r -a components <<< "${path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" && "${component}" != "." &&
       "${component}" != ".." ]] || return 1
  done
}

payload_expected_source() {
  case "$1" in
    cntools.sh)
      printf '%s\n' scripts/common-helper-scripts/cntools/launcher.sh
      ;;
    cntools.library|cntools.conf.example)
      printf 'scripts/common-helper-scripts/%s\n' "$1"
      ;;
    cntools/*)
      printf 'scripts/common-helper-scripts/%s\n' "$1"
      ;;
    *)
      return 1
      ;;
  esac
}

validate_config_source() {
  local config="$1"
  local line=""

  [[ -s "${config}" && ! -L "${config}" ]] || return 1
  grep -Fqx 'CNTOOLS_CONFIG_VERSION=1' "${config}" || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" != *$'\r'* ]] || return 1
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" =~ ^[A-Z][A-Z0-9_]*=[^[:space:]]+$ ]] || return 1
    [[ "${line#*=}" != *'$'* && "${line#*=}" != *'`'* &&
       "${line#*=}" != *';'* && "${line#*=}" != *'&'* &&
       "${line#*=}" != *'|'* && "${line#*=}" != *'('* &&
       "${line#*=}" != *')'* && "${line#*=}" != *'{'* &&
       "${line#*=}" != *'}'* && "${line#*=}" != *'<'* &&
       "${line#*=}" != *'>'* && "${line#*=}" != *'\\'* ]] || return 1
  done < "${config}"
}

validate_stage1_library_manifest() {
  jq -e '
    type == "object" and
    .schemaVersion == 1 and
    .runtimeApiVersion == 1 and
    (.libraries | type == "array" and length == 0)
  ' "$1" >/dev/null 2>&1
}

validate_stage3_root_module() {
  jq -e '
    type == "object" and
    .schemaVersion == 2 and
    .id == "root" and
    .kind == "menu" and
    .controlPolicy == "root" and
    (has("runtime") | not) and
    (has("executionRequirements") | not)
  ' "$1" >/dev/null 2>&1
}

validate_stage3_module_schema() {
  jq -e '
    .["$id"] ==
      "https://cardano-community.github.io/guild-operators/cntools/module.schema.v2.json" and
    (.["$defs"].runtime.properties.libraries.description |
      type == "string" and test("canonical lexical order"; "i"))
  ' "$1" >/dev/null 2>&1
}

assert_definition_only_shell_member() {
  local source_file="$1"
  local member_id="$2"
  local sandbox="${TEST_ROOT}/definition-only-${member_id//\//_}"
  local output="${sandbox}.output"

  mkdir -p -- "${sandbox}"
  if ! HOME="${sandbox}" TMPDIR="${sandbox}" \
    "${BASH}" -c '
      member_source=$1
      set -f
      shopt -s nullglob
      IFS=$'"'"' \t\n:'"'"'
      set -- alpha "two words" ""
      trap : USR1
      before_pwd="${PWD}"
      before_ifs="$(printf %q "${IFS}")"
      before_options="$(set +o)"
      before_shopt="$(shopt -p)"
      before_traps="$(trap -p)"
      before_args="$(printf "%q " "$@")"
      before_umask="$(umask)"
      # shellcheck source=/dev/null
      . "${member_source}"
      [[ "${PWD}" == "${before_pwd}" ]]
      [[ "$(printf %q "${IFS}")" == "${before_ifs}" ]]
      [[ "$(set +o)" == "${before_options}" ]]
      [[ "$(shopt -p)" == "${before_shopt}" ]]
      [[ "$(trap -p)" == "${before_traps}" ]]
      [[ "$(printf "%q " "$@")" == "${before_args}" ]]
      [[ "$(umask)" == "${before_umask}" ]]
      [[ -z "$(find "${HOME}" -mindepth 1 -print -quit)" ]]
    ' bash "${source_file}" > "${output}" 2>&1; then
    [[ ! -s "${output}" ]] || sed -n '1,40p' "${output}" >&2
    fail "sourcing ${member_id} changed process state or created a file"
  fi
  [[ ! -s "${output}" ]] || {
    sed -n '1,40p' "${output}" >&2
    fail "sourcing ${member_id} produced output"
  }
}

validate_payload_contract() {
  local manifest="$1"
  local repository_root="$2"
  local payload_source_root="${repository_root}/scripts/common-helper-scripts/cntools"
  local actual_sources="${TEST_ROOT}/actual-sources.$$.txt"
  local declared_sources="${TEST_ROOT}/declared-sources.$$.txt"
  local declared_inventory="${TEST_ROOT}/declared-inventory.$$.tsv"
  local expected_inventory="${TEST_ROOT}/expected-inventory.$$.tsv"
  local path="" source="" mode="" validator="" expected_hash=""
  local expected_source="" source_file="" actual_hash="" extra=""
  local version_file="${repository_root}/scripts/common-helper-scripts/cntools/VERSION"
  local record_count=0 action_stub_count=0 function_count=0
  local -A seen_paths=()
  local -A seen_sources=()

  [[ -f "${manifest}" && ! -L "${manifest}" && -s "${manifest}" ]] ||
    return 1
  jq -e '
    . as $manifest |
    type == "object" and
    keys == [
      "compatibilityLibrary", "contextApiVersion", "entrypoint", "files",
      "generationIdAlgorithm", "legacyBundle", "libraryManifest", "moduleApiVersion",
      "moduleSchema", "moduleSchemaVersion", "releaseStage", "rootModule",
      "runtimeApiVersion", "schemaVersion", "version"
    ] and
    .schemaVersion == 3 and
    .version == "13.5.7" and
    .releaseStage == "shadow" and
    .runtimeApiVersion == 1 and
    .contextApiVersion == 1 and
    .moduleApiVersion == 1 and
    .moduleSchemaVersion == 2 and
    .generationIdAlgorithm == "sha256-path-mode-content-v1" and
    .entrypoint == "cntools.sh" and
    .compatibilityLibrary == "cntools.library" and
    .moduleSchema == "cntools/schema/module.schema.json" and
    .libraryManifest == "cntools/libs/manifest.json" and
    .rootModule == "cntools/modules/root/module.json" and
    (.legacyBundle | type == "object" and
      keys == [
        "facade", "id", "idAlgorithm", "logicalBodySha256",
        "logicalBodySize", "members", "path", "schemaVersion"
      ] and
      .schemaVersion == 1 and
      .facade == "cntools.library" and
      .idAlgorithm == "sha256-cntools-legacy-bundle-v1" and
      .id == "15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f" and
      .path == "cntools/libs/legacy/15b90fa18f302a89b7e3d0562c9909aacd06d684080fa28ef1a6a98112a5b47f" and
      .logicalBodySize == 278034 and
      .logicalBodySha256 == "c9c900b9f14399d024dea9b5b10184ebbdebdaed7d8cba1c246d69ca37971408" and
      .members == [
        {"mode":"0444","path":"010-common-dialog.sh","sha256":"5408355794fa187dbac5af7b66b956ab84216fd91ee4b6ec8bbe420b05fea8a7","size":14532},
        {"mode":"0444","path":"020-terminal-selection-security.sh","sha256":"bb6f10e533f45cb90577e32d0d7a57ca86fe0c97d950938911be8eecec4a1460","size":31976},
        {"mode":"0444","path":"030-governance-query.sh","sha256":"9e9179c73ccdd945c6ed6b7921038b7f6bc7679c4609af86565f7ad99ff8d519","size":46236},
        {"mode":"0444","path":"040-address-wallet-query.sh","sha256":"b23fdfec65fd7e991a3e46d2bef1d5c9ed09102e345cac7f3f5b75c761957df0","size":38284},
        {"mode":"0444","path":"050-wallet-create-registration.sh","sha256":"a1fba108e3e9d3e8c388c54bd3a95332ee4444e61519330dd65347f4cfbe9b53","size":34499},
        {"mode":"0444","path":"060-wallet-actions.sh","sha256":"73f150b684713b6c64211ff8c900a6deedb90a4aa15afde85dae44b8af220db5","size":18393},
        {"mode":"0444","path":"070-pool-actions.sh","sha256":"689a52e0e8f18a30984cebda6ef29dd929b66fb4cdba7ff03f673debb6e25257","size":27577},
        {"mode":"0444","path":"080-metadata-assets.sh","sha256":"1444e366a79483bdcd538b59e01f8a623e3c6b4bf4fe58f5deaedc53ec247c80","size":17503},
        {"mode":"0444","path":"090-governance-actions.sh","sha256":"91fd56011304f4528851f8cd3b241ca63393440a51faa5c5380a22081a146ec8","size":22753},
        {"mode":"0444","path":"100-transaction-hardware-price.sh","sha256":"237b3847db52432ff523c36c5ca7bcb08b437f8b8978389259789a70fee5071f","size":22300}
      ] and
      all(.members[];
        type == "object" and keys == ["mode", "path", "sha256", "size"])
    ) and
    (.files | type == "array" and length == 151) and
    ([.files[].path] == ([.files[].path] | sort)) and
    ([.files[].path] | length) == ([.files[].path] | unique | length) and
    ([.files[].source] | length) == ([.files[].source] | unique | length) and
    all(.files[];
      type == "object" and
      keys == ["mode", "path", "sha256", "source", "validator"] and
      (.path | type == "string" and length > 0) and
      (.source | type == "string" and length > 0) and
      (.mode == "0444" or .mode == "0555") and
      (.validator == "shell" or .validator == "json" or
       .validator == "text" or .validator == "config") and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
    ([.legacyBundle.members[] as $member |
      .files[] |
      select(
        .path == ($manifest.legacyBundle.path + "/" + $member.path) and
        .source == ("scripts/common-helper-scripts/" +
          $manifest.legacyBundle.path + "/" + $member.path) and
        .mode == $member.mode and .validator == "shell" and
        .sha256 == $member.sha256
      )] | length == 10) and
    ([.files[] |
      select(.path | startswith($manifest.legacyBundle.path + "/"))] |
      length == 10)
  ' "${manifest}" >/dev/null 2>&1 || return 1

  [[ -f "${EXPECTED_INVENTORY}" && ! -L "${EXPECTED_INVENTORY}" ]] ||
    return 1
  awk '!/^#/ && NF' "${EXPECTED_INVENTORY}" > "${expected_inventory}" ||
    return 1
  jq -r '.files[] | [.path, .source, .mode, .validator] | @tsv' \
    "${manifest}" > "${declared_inventory}" || return 1
  cmp -s "${expected_inventory}" "${declared_inventory}" || return 1

  [[ -f "${version_file}" && ! -L "${version_file}" &&
     "$(awk 'END { print NR }' "${version_file}")" == "1" &&
     "$(< "${version_file}")" == "13.5.7" ]] || return 1
  [[ -d "${payload_source_root}" && ! -L "${payload_source_root}" ]] || return 1
  [[ -z "$(find "${payload_source_root}" -type l -print -quit)" ]] || return 1
  for source_file in \
    "${repository_root}/scripts/common-helper-scripts/cntools.library" \
    "${repository_root}/scripts/common-helper-scripts/cntools.conf.example"; do
    [[ -f "${source_file}" && ! -L "${source_file}" ]] || return 1
  done

  : > "${declared_sources}"
  while IFS=$'\t' read -r path source mode validator expected_hash extra; do
    [[ -n "${path}" && -n "${source}" && -n "${mode}" &&
       -n "${validator}" && -n "${expected_hash}" && -z "${extra}" ]] || return 1
    payload_path_valid "${path}" && payload_path_valid "${source}" || return 1
    expected_source="$(payload_expected_source "${path}")" || return 1
    [[ "${source}" == "${expected_source}" ]] || return 1
    [[ -z "${seen_paths[${path}]+set}" &&
       -z "${seen_sources[${source}]+set}" ]] || return 1
    seen_paths["${path}"]="Y"
    seen_sources["${source}"]="Y"
    source_file="${repository_root}/${source}"
    [[ -f "${source_file}" && ! -L "${source_file}" && -s "${source_file}" ]] ||
      return 1
    actual_hash="$(sha256_file "${source_file}")" || return 1
    [[ "${actual_hash}" == "${expected_hash}" ]] || return 1
    if [[ "${path}" == cntools/modules/root/*/action.sh ]]; then
      [[ "${actual_hash}" == "${ACTION_STUB_SHA256}" ]] || return 1
      function_count="$(grep -Ec \
        '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{' \
        "${source_file}")" || return 1
      [[ "${function_count}" == 1 ]] || return 1
      grep -Eq \
        '^[[:space:]]*cntools_action_main[[:space:]]*\(\)[[:space:]]*\{' \
        "${source_file}" || return 1
      action_stub_count=$((action_stub_count + 1))
    fi
    case "${validator}" in
      shell) "${BASH}" -n "${source_file}" >/dev/null 2>&1 || return 1 ;;
      json) jq -e . "${source_file}" >/dev/null 2>&1 || return 1 ;;
      text) : ;;
      config) validate_config_source "${source_file}" || return 1 ;;
      *) return 1 ;;
    esac
    printf '%s\n' "${source}" >> "${declared_sources}"
    record_count=$((record_count + 1))
  done < <(jq -r '.files[] | [.path, .source, .mode, .validator, .sha256] | @tsv' "${manifest}")
  (( record_count == 151 )) || return 1
  (( action_stub_count == 54 )) || return 1

  {
    printf '%s\n' \
      scripts/common-helper-scripts/cntools.library \
      scripts/common-helper-scripts/cntools.conf.example
    find "${payload_source_root}" -type f \
      ! -path "${repository_root}/${MANIFEST_RELATIVE}" -print |
      sed "s#^${repository_root}/##"
  } | sort > "${actual_sources}"
  sort -o "${declared_sources}" "${declared_sources}"
  cmp -s "${actual_sources}" "${declared_sources}" || return 1

  validate_stage1_library_manifest \
    "${repository_root}/scripts/common-helper-scripts/cntools/libs/manifest.json" ||
    return 1
  validate_stage3_root_module \
    "${repository_root}/scripts/common-helper-scripts/cntools/modules/root/module.json" ||
    return 1
  validate_stage3_module_schema \
    "${repository_root}/scripts/common-helper-scripts/cntools/schema/module.schema.json" ||
    return 1
  grep -Eq '(^|[[:space:]])cntools_action_main[[:space:]]*\(\)' \
    "${repository_root}/scripts/common-helper-scripts/cntools/templates/action/action.sh" ||
    return 1
}

assert_expected_inventory() {
  local manifest="$1"
  local actual="${TEST_ROOT}/payload-inventory.actual.tsv"
  local expected="${TEST_ROOT}/payload-inventory.expected.tsv"

  [[ -f "${EXPECTED_INVENTORY}" && ! -L "${EXPECTED_INVENTORY}" ]] ||
    fail "expected payload inventory fixture is missing or unsafe"
  awk '!/^#/ && NF' "${EXPECTED_INVENTORY}" > "${expected}"
  jq -r '.files[] | [.path, .source, .mode, .validator] | @tsv' \
    "${manifest}" > "${actual}"
  cmp -s "${expected}" "${actual}" || {
    diff -u "${expected}" "${actual}" >&2 || true
    fail "checked-in payload inventory differs from the Stage 3 contract"
  }
}

generation_id_for_manifest() {
  local manifest="$1"
  local records="${TEST_ROOT}/generation-id.$$.tsv"
  local manifest_hash=""

  manifest_hash="$(sha256_file "${manifest}")" || return 1
  {
    printf 'cntools/manifest.json\t0444\t%s\n' "${manifest_hash}"
    jq -r '.files | sort_by(.path)[] | [.path, .mode, .sha256] | @tsv' \
      "${manifest}"
  } | sort > "${records}" || return 1
  sha256_file "${records}"
}

copy_payload_source() {
  local destination="$1"
  local common="${destination}/scripts/common-helper-scripts"

  mkdir -p -- "${common}"
  cp -- "${REPO_ROOT}/scripts/common-helper-scripts/cntools.library" "${common}/"
  cp -- "${REPO_ROOT}/scripts/common-helper-scripts/cntools.conf.example" "${common}/"
  cp -R -- "${REPO_ROOT}/scripts/common-helper-scripts/cntools" "${common}/cntools"
}

atomic_jq_update() {
  local manifest="$1"
  shift
  local staged="${manifest}.stage.$$"

  jq -S "$@" "${manifest}" > "${staged}" || {
    rm -f -- "${staged}"
    return 1
  }
  mv -f -- "${staged}" "${manifest}"
}

update_source_hash() {
  local repository_root="$1"
  local source="$2"
  local manifest="${repository_root}/${MANIFEST_RELATIVE}"
  local hash=""

  hash="$(sha256_file "${repository_root}/${source}")" || return 1
  atomic_jq_update "${manifest}" --arg source "${source}" --arg hash "${hash}" '
    (.files[] | select(.source == $source) | .sha256) = $hash
  '
}

run_registry_contract_tests() (
  local registry_source="${REPO_ROOT}/scripts/common-helper-scripts/cntools/core/registry.sh"
  local fixture="${TEST_ROOT}/registry-contract"
  local modules="${fixture}/modules"
  local libraries="${fixture}/libs/manifest.json"
  local action_sentinel="${TEST_ROOT}/registry-action.executed"
  local collected_path="${TEST_ROOT}/registry-collected.actual"
  local expected_path="${TEST_ROOT}/registry-collected.expected"
  local -a collected=()

  write_menu() {
    local directory="$1" id="$2" order="$3" shortcut="$4"
    mkdir -p -- "${directory}"
    jq -S -n --arg id "${id}" --argjson order "${order}" \
      --arg shortcut "${shortcut}" '{
        schemaVersion: 2, id: $id, kind: "menu", order: $order,
        shortcut: $shortcut, label: ("Menu " + $id),
        description: ("Menu fixture " + $id),
        controlPolicy: "home",
        visibility: {
          modes: ["local", "offline"], features: [], nodeCapabilities: []
        }
      }' > "${directory}/module.json"
  }

  write_action() {
    local directory="$1" id="$2" order="$3" shortcut="$4"
    mkdir -p -- "${directory}"
    jq -S -n --arg id "${id}" --argjson order "${order}" \
      --arg shortcut "${shortcut}" '{
        schemaVersion: 2, id: $id, kind: "action", order: $order,
        shortcut: $shortcut, label: ("Action " + $id),
        description: ("Action fixture " + $id),
        visibility: {
          modes: ["local", "light"], features: [], nodeCapabilities: []
        },
        executionRequirements: {
          modes: ["local"], features: [], nodeCapabilities: []
        },
        runtime: {apiVersion: 1, libraries: ["wallet"]}
      }' > "${directory}/module.json"
    printf '#!/usr/bin/env bash\ncntools_action_main() { :; }\n' > \
      "${directory}/action.sh"
  }

  reset_registry_fixture() {
    rm -rf -- "${fixture}"
    mkdir -p -- "${modules}/root" "$(dirname -- "${libraries}")"
    cp -- \
      "${REPO_ROOT}/scripts/common-helper-scripts/cntools/modules/root/module.json" \
      "${modules}/root/module.json"
    write_action "${modules}/root/status" status 10 s
    write_menu "${modules}/root/operations" operations 20 o
    write_action "${modules}/root/operations/rotate" operations.rotate 10 r
    jq -S -n '{
      schemaVersion: 1, runtimeApiVersion: 1,
      libraries: [
        {id:"base", path:"libs/base.sh", apiVersion:1, dependencies:[]},
        {id:"wallet", path:"libs/wallet.sh", apiVersion:1,
          dependencies:["base"]}
      ]
    }' > "${libraries}"
  }

  expect_registry_rejection() {
    local context="$1"
    if cntools_registry_validate_tree "${modules}" "${libraries}" \
      >/dev/null 2>&1; then
      fail "registry accepted ${context}"
    fi
  }

  # shellcheck source=/dev/null
  . "${registry_source}"
  reset_registry_fixture
  printf 'printf executed > %q\n' "${action_sentinel}" >> \
    "${modules}/root/status/action.sh"
  cntools_registry_validate_tree "${modules}" "${libraries}" ||
    fail "registry rejected a valid menu/action/library fixture"
  [[ ! -e "${action_sentinel}" && ! -L "${action_sentinel}" ]] ||
    fail "registry validation executed an action entrypoint"
  cntools_registry_collect "${modules}" collected ||
    fail "registry collection rejected a valid module tree"
  printf '%s\n' "${collected[@]}" > "${collected_path}"
  printf '%s\n' \
    "${modules}/root" \
    "${modules}/root/operations" \
    "${modules}/root/operations/rotate" \
    "${modules}/root/status" | LC_ALL=C sort > "${expected_path}"
  cmp -s "${expected_path}" "${collected_path}" || {
    diff -u "${expected_path}" "${collected_path}" >&2 || true
    fail "registry collection was not complete and deterministic"
  }

  reset_registry_fixture
  printf 'unknown\n' > "${modules}/root/unknown.file"
  expect_registry_rejection "an unknown module-tree file"

  reset_registry_fixture
  ln -s root "${modules}/unexpected"
  expect_registry_rejection "a symbolic-link module entry"

  reset_registry_fixture
  mkdir -- "${modules}/unexpected"
  expect_registry_rejection "a second top-level module root"

  reset_registry_fixture
  atomic_jq_update "${modules}/root/status/module.json" '.unexpected = true'
  expect_registry_rejection "unknown action metadata"

  reset_registry_fixture
  atomic_jq_update "${modules}/root/operations/module.json" 'del(.order)'
  expect_registry_rejection "incomplete menu metadata"

  reset_registry_fixture
  atomic_jq_update "${modules}/root/operations/rotate/module.json" \
    '.id = "status"'
  expect_registry_rejection "duplicate module IDs"

  reset_registry_fixture
  atomic_jq_update "${modules}/root/operations/module.json" '.shortcut = "s"'
  expect_registry_rejection "duplicate sibling shortcuts"

  reset_registry_fixture
  atomic_jq_update "${modules}/root/operations/module.json" '.order = 10'
  expect_registry_rejection "duplicate sibling order values"

  reset_registry_fixture
  atomic_jq_update "${modules}/root/status/module.json" \
    '.runtime.libraries = ["unknown-library"]'
  expect_registry_rejection "an unknown action library"

  reset_registry_fixture
  atomic_jq_update "${libraries}" \
    '(.libraries[] | select(.id == "base") | .dependencies) = ["wallet"]'
  expect_registry_rejection "a library dependency cycle"

  reset_registry_fixture
  rm -- "${modules}/root/status/action.sh"
  expect_registry_rejection "an action missing its entrypoint"

  reset_registry_fixture
  printf '#!/usr/bin/env bash\n' > "${modules}/root/status/other.sh"
  expect_registry_rejection "an action with an extra entrypoint"

  reset_registry_fixture
  printf 'cntools_action_main() { :; }\n' > \
    "${modules}/root/operations/action.sh"
  expect_registry_rejection "a menu containing an action entrypoint"
)

expect_manifest_rejection() {
  local name="$1"
  local filter="$2"
  local candidate_root="${TEST_ROOT}/mutation-${name}"
  local candidate_manifest="${candidate_root}/${MANIFEST_RELATIVE}"

  copy_payload_source "${candidate_root}"
  atomic_jq_update "${candidate_manifest}" "${filter}" ||
    fail "could not create ${name} manifest mutation"
  if validate_payload_contract "${candidate_manifest}" "${candidate_root}"; then
    fail "payload validator accepted ${name} mutation"
  fi
}

validate_payload_contract "${MANIFEST}" "${REPO_ROOT}" ||
  fail "checked-in CNTools payload failed validation"
assert_expected_inventory "${MANIFEST}"
while IFS=$'\t' read -r member_path member_source; do
  assert_definition_only_shell_member \
    "${REPO_ROOT}/${member_source}" "${member_path}"
done < <(jq -r '.files[] |
  select(.validator == "shell" and .path != "cntools.library") |
  [.path,.source] | @tsv' "${MANIFEST}")
run_registry_contract_tests
generation_id="$(generation_id_for_manifest "${MANIFEST}")" ||
  fail "could not compute the checked-in CNTools generation ID"
[[ "${generation_id}" =~ ^[0-9a-f]{64}$ ]] ||
  fail "computed CNTools generation ID is malformed"

expect_manifest_rejection unknown-key '.unexpected = true'
expect_manifest_rejection unsupported-schema '.schemaVersion = 2'
expect_manifest_rejection changed-module-api '.moduleApiVersion = 2'
expect_manifest_rejection missing-module-schema-version \
  'del(.moduleSchemaVersion)'
expect_manifest_rejection unsupported-module-schema-version \
  '.moduleSchemaVersion = 1'
expect_manifest_rejection legacy-bundle-unknown-key \
  '.legacyBundle.unexpected = true'
expect_manifest_rejection legacy-bundle-wrong-id \
  '.legacyBundle.id = "0000000000000000000000000000000000000000000000000000000000000000"'
expect_manifest_rejection legacy-bundle-missing-member \
  '.legacyBundle.members = .legacyBundle.members[1:]'
expect_manifest_rejection legacy-bundle-member-hash-mismatch \
  '.legacyBundle.members[0].sha256 = "0000000000000000000000000000000000000000000000000000000000000000"'
expect_manifest_rejection legacy-bundle-file-decoupled \
  '(.files[] | select(.path | endswith("/010-common-dialog.sh")) | .mode) = "0555"'
expect_manifest_rejection duplicate-path '.files += [.files[0]]'
expect_manifest_rejection traversal-path '.files[0].path = "../cntools.sh"'
expect_manifest_rejection out-of-scope-source \
  '.files[0].source = "scripts/cnode-helper-scripts/cnode.sh"'
expect_manifest_rejection unsupported-mode '.files[0].mode = "0644"'
expect_manifest_rejection unsupported-validator '.files[0].validator = "eval"'
expect_manifest_rejection hash-mismatch \
  '.files[0].sha256 = "0000000000000000000000000000000000000000000000000000000000000000"'
expect_manifest_rejection missing-record '.files = .files[1:]'

changed_stub_root="${TEST_ROOT}/mutation-changed-action-stub"
changed_stub_source='scripts/common-helper-scripts/cntools/modules/root/wallet/list/action.sh'
copy_payload_source "${changed_stub_root}"
printf '\n# changed but still inert\n' >> \
  "${changed_stub_root}/${changed_stub_source}"
changed_stub_hash="$(sha256_file \
  "${changed_stub_root}/${changed_stub_source}")" ||
  fail 'could not hash the changed action-stub mutation'
atomic_jq_update "${changed_stub_root}/${MANIFEST_RELATIVE}" \
  --arg source "${changed_stub_source}" --arg hash "${changed_stub_hash}" '
    (.files[] | select(.source == $source) | .sha256) = $hash
  ' || fail 'could not refresh the changed action-stub manifest hash'
if validate_payload_contract \
    "${changed_stub_root}/${MANIFEST_RELATIVE}" "${changed_stub_root}"; then
  fail 'payload validator accepted a changed action stub with refreshed hash'
fi

base_substitution_root="${TEST_ROOT}/mutation-base-to-fake-module"
base_removed_path='cntools/docs/TESTING.md'
base_removed_source="scripts/common-helper-scripts/${base_removed_path}"
base_added_path='cntools/modules/root/fake/module.json'
base_added_source="scripts/common-helper-scripts/${base_added_path}"
copy_payload_source "${base_substitution_root}"
mkdir -p -- "${base_substitution_root}/$(dirname -- "${base_added_source}")"
cp -- \
  "${base_substitution_root}/scripts/common-helper-scripts/cntools/modules/root/blocks/module.json" \
  "${base_substitution_root}/${base_added_source}"
atomic_jq_update "${base_substitution_root}/${base_added_source}" '
  .id = "fake" | .order = 110 | .shortcut = "y" |
  .label = "Fake" | .description = "Legacy CNTools menu: Fake"
'
rm -- "${base_substitution_root}/${base_removed_source}"
base_added_hash="$(sha256_file \
  "${base_substitution_root}/${base_added_source}")" ||
  fail 'could not hash the base-to-fake-module payload mutation'
atomic_jq_update "${base_substitution_root}/${MANIFEST_RELATIVE}" \
  --arg removed "${base_removed_path}" \
  --arg path "${base_added_path}" --arg source "${base_added_source}" \
  --arg hash "${base_added_hash}" '
    .files = ([.files[] | select(.path != $removed)] + [{
      path: $path, source: $source, mode: "0444",
      validator: "json", sha256: $hash
    }] | sort_by(.path))
  ' || fail 'could not build the base-to-fake-module manifest mutation'
[[ "$(jq -er '.files | length' \
  "${base_substitution_root}/${MANIFEST_RELATIVE}")" == 151 ]] ||
  fail 'base-to-fake-module payload mutation did not preserve count 151'
if validate_payload_contract \
    "${base_substitution_root}/${MANIFEST_RELATIVE}" \
    "${base_substitution_root}"; then
  fail 'payload validator accepted a count-preserving fake module substitution'
fi

relocation_root="${TEST_ROOT}/mutation-module-action-relocation"
relocation_old='scripts/common-helper-scripts/cntools/modules/root/wallet/list'
relocation_new='scripts/common-helper-scripts/cntools/modules/root/wallet/phantom'
copy_payload_source "${relocation_root}"
cp -R -- "${relocation_root}/${relocation_old}" \
  "${relocation_root}/${relocation_new}"
rm -rf -- "${relocation_root:?}/${relocation_old}"
atomic_jq_update "${relocation_root}/${relocation_new}/module.json" '
  .id = "wallet.phantom" | .label = "Phantom" |
  .description = "Legacy CNTools workflow: Phantom"
'
relocation_module_hash="$(sha256_file \
  "${relocation_root}/${relocation_new}/module.json")" ||
  fail 'could not hash the relocated module metadata'
relocation_action_hash="$(sha256_file \
  "${relocation_root}/${relocation_new}/action.sh")" ||
  fail 'could not hash the relocated action stub'
atomic_jq_update "${relocation_root}/${MANIFEST_RELATIVE}" \
  --arg old_module 'cntools/modules/root/wallet/list/module.json' \
  --arg old_action 'cntools/modules/root/wallet/list/action.sh' \
  --arg new_module 'cntools/modules/root/wallet/phantom/module.json' \
  --arg new_action 'cntools/modules/root/wallet/phantom/action.sh' \
  --arg new_module_source "${relocation_new}/module.json" \
  --arg new_action_source "${relocation_new}/action.sh" \
  --arg module_hash "${relocation_module_hash}" \
  --arg action_hash "${relocation_action_hash}" '
    .files = ([.files[] |
      select(.path != $old_module and .path != $old_action)] + [{
        path: $new_module, source: $new_module_source, mode: "0444",
        validator: "json", sha256: $module_hash
      }, {
        path: $new_action, source: $new_action_source, mode: "0444",
        validator: "shell", sha256: $action_hash
      }] | sort_by(.path))
  ' || fail 'could not build the module/action relocation manifest mutation'
[[ "$(jq -er '.files | length' \
  "${relocation_root}/${MANIFEST_RELATIVE}")" == 151 ]] ||
  fail 'module/action relocation payload mutation did not preserve count 151'
if validate_payload_contract \
    "${relocation_root}/${MANIFEST_RELATIVE}" "${relocation_root}"; then
  fail 'payload validator accepted a count-preserving module/action relocation'
fi

malformed_root="${TEST_ROOT}/mutation-malformed-json"
copy_payload_source "${malformed_root}"
printf '{\n' > "${malformed_root}/${MANIFEST_RELATIVE}"
if validate_payload_contract \
  "${malformed_root}/${MANIFEST_RELATIVE}" "${malformed_root}"; then
  fail "payload validator accepted malformed manifest JSON"
fi

extra_root="${TEST_ROOT}/mutation-unlisted-source"
copy_payload_source "${extra_root}"
printf 'unlisted\n' > \
  "${extra_root}/scripts/common-helper-scripts/cntools/unlisted.txt"
if validate_payload_contract "${extra_root}/${MANIFEST_RELATIVE}" "${extra_root}"; then
  fail "payload validator accepted an unlisted source file"
fi

missing_root="${TEST_ROOT}/mutation-missing-source"
copy_payload_source "${missing_root}"
mv -- "${missing_root}/scripts/common-helper-scripts/cntools/VERSION" \
  "${missing_root}/VERSION.missing"
if validate_payload_contract "${missing_root}/${MANIFEST_RELATIVE}" "${missing_root}"; then
  fail "payload validator accepted a missing listed source file"
fi

shell_root="${TEST_ROOT}/mutation-shell-syntax"
copy_payload_source "${shell_root}"
printf '\nif (\n' >> \
  "${shell_root}/scripts/common-helper-scripts/cntools/launcher.sh"
update_source_hash "${shell_root}" \
  scripts/common-helper-scripts/cntools/launcher.sh ||
  fail "could not update invalid-shell fixture hash"
if validate_payload_contract "${shell_root}/${MANIFEST_RELATIVE}" "${shell_root}"; then
  fail "payload validator accepted invalid shell with a matching hash"
fi

json_root="${TEST_ROOT}/mutation-member-json"
copy_payload_source "${json_root}"
printf '{\n' > \
  "${json_root}/scripts/common-helper-scripts/cntools/modules/root/module.json"
update_source_hash "${json_root}" \
  scripts/common-helper-scripts/cntools/modules/root/module.json ||
  fail "could not update invalid-JSON fixture hash"
if validate_payload_contract "${json_root}/${MANIFEST_RELATIVE}" "${json_root}"; then
  fail "payload validator accepted invalid member JSON with a matching hash"
fi

symlink_root="${TEST_ROOT}/mutation-source-symlink"
copy_payload_source "${symlink_root}"
mv -- "${symlink_root}/scripts/common-helper-scripts/cntools/docs/TESTING.md" \
  "${symlink_root}/TESTING.real"
ln -s "${symlink_root}/TESTING.real" \
  "${symlink_root}/scripts/common-helper-scripts/cntools/docs/TESTING.md"
if validate_payload_contract \
  "${symlink_root}/${MANIFEST_RELATIVE}" "${symlink_root}"; then
  fail "payload validator accepted a symbolic-link source member"
fi

printf 'CNTools Stage 3 payload contract tests passed (151 members, %s)\n' \
  "${generation_id}"
