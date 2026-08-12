#!/usr/bin/env bash
# Validate the Stage 3 CNTools module registry and its complete legacy-menu dump.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools module registry tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

LC_ALL=C
export LC_ALL

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
REGISTRY_SOURCE="${CNTOOLS_ROOT}/core/registry.sh"
CONTEXT_SOURCE="${CNTOOLS_ROOT}/core/context.sh"
DISPATCHER_SOURCE="${CNTOOLS_ROOT}/core/dispatcher.sh"
MODULE_SCHEMA="${CNTOOLS_ROOT}/schema/module.schema.json"
MODULES_ROOT="${CNTOOLS_ROOT}/modules"
LIBRARY_MANIFEST="${CNTOOLS_ROOT}/libs/manifest.json"
MENU_ORACLE="${REPO_ROOT}/files/tests/fixtures/cntools-stage3-menu-dump.json"
LEGACY_ORACLE="${REPO_ROOT}/files/tests/fixtures/cntools-menu.json"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-registry.XXXXXX")"
TEST_ROOT="$(cd -P -- "${TEST_ROOT}" && pwd -P)"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'CNTools module registry test failed: %s\n' "$1" >&2
  exit 1
}

for required_command in bash cmp cp diff find grep jq mktemp mv sort; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

[[ -f "${REGISTRY_SOURCE}" && ! -L "${REGISTRY_SOURCE}" ]] ||
  fail 'registry source is missing or unsafe'
[[ -f "${MENU_ORACLE}" && ! -L "${MENU_ORACLE}" ]] ||
  fail 'Stage 3 menu oracle is missing or unsafe'
[[ -f "${LEGACY_ORACLE}" && ! -L "${LEGACY_ORACLE}" ]] ||
  fail 'Stage 0A menu oracle is missing or unsafe'

# shellcheck disable=SC2016 # The nested Bash expands its own saved variables.
source_probe="$({
  "${BASH}" -c '
    set -euo pipefail
    registry=$1
    jq() { return 97; }
    find() { return 96; }
    alias grep="false"
    alias sort="false"
    before_jq="$(declare -f jq)"
    before_find="$(declare -f find)"
    before_grep="$(alias grep)"
    before_sort="$(alias sort)"
    # shellcheck source=/dev/null
    . "${registry}"
    [[ "$(declare -f jq)" == "${before_jq}" ]]
    [[ "$(declare -f find)" == "${before_find}" ]]
    [[ "$(alias grep)" == "${before_grep}" ]]
    [[ "$(alias sort)" == "${before_sort}" ]]
  ' bash "${REGISTRY_SOURCE}"
} 2>&1)" || fail 'sourcing registry invoked or replaced caller utilities'
[[ -z "${source_probe}" ]] ||
  fail "sourcing registry with utility collisions produced output: ${source_probe}"

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

write_dispatcher_context() {
  local target="$1"
  local features="$2"
  local capabilities="$3"

  jq -n --argjson features "${features}" \
    --argjson capabilities "${capabilities}" '
      {
        schemaVersion: 1,
        apiVersion: 1,
        generationVersion: "13.5.7",
        mode: "local",
        advanced: true,
        nodeImplementation: "cnode",
        nodeNetwork: "mainnet",
        nodeHome: "/srv/cardano",
        features: $features,
        capabilities: $capabilities
      }
    ' > "${target}"
}

duplicate_first_json_member() {
  local target="$1"
  local member="$2"
  local staged="${target}.duplicate.$$"
  local document="" duplicated=""

  document="$(jq -c . "${target}")" || return 1
  [[ "${document}" == *"${member}"* ]] || return 1
  duplicated="${document/"${member}"/"${member},${member}"}"
  [[ "${duplicated}" != "${document}" ]] || return 1
  printf '%s\n' "${duplicated}" > "${staged}"
  mv -f -- "${staged}" "${target}"
}

replace_first_json_literal() {
  local target="$1"
  local original="$2"
  local replacement="$3"
  local staged="${target}.literal.$$"
  local document="" mutated=""

  document="$(jq -c . "${target}")" || return 1
  [[ "${document}" == *"${original}"* ]] || return 1
  mutated="${document/"${original}"/"${replacement}"}"
  [[ "${mutated}" != "${document}" ]] || return 1
  printf '%s\n' "${mutated}" > "${staged}"
  mv -f -- "${staged}" "${target}"
}

assert_legacy_projection() {
  local dump="$1"
  local expected="${TEST_ROOT}/legacy.expected.json"
  local actual="${TEST_ROOT}/legacy.actual.json"

  jq -S '
    {
      schemaVersion,
      menus: [.menus[] | {
        id, parent,
        options: [.options[] |
          {id, kind, shortcut, label}
          + (if .kind == "control" then {navigation}
             elif (.visibility.features | length) == 1 then
               {visibility: .visibility.features[0]}
             else {} end)
        ]
      }]
    }
  ' "${dump}" > "${actual}"
  jq -S '{schemaVersion, menus: [.menus[] | {id, parent, options}]}' \
    "${LEGACY_ORACLE}" > "${expected}"
  cmp -s "${expected}" "${actual}" || {
    diff -u "${expected}" "${actual}" >&2 || true
    fail 'Stage 3 menu dump differs from the frozen Stage 0A menu tree'
  }
}

assert_dump_contract() {
  local dump="$1"

  jq -e '
    type == "object" and
    keys == ["counts", "menus", "moduleSchemaVersion", "schemaVersion"] and
    .schemaVersion == 1 and .moduleSchemaVersion == 2 and
    .counts == {
      actions: 54, controls: 22, menus: 15, modules: 69, options: 90
    } and
    (.menus | length) == 15 and
    ([.menus[].options[] | select(.kind == "action")] | length) == 54 and
    ([.menus[].options[] | select(.kind == "menu")] | length) == 14 and
    ([.menus[].options[] | select(.kind == "control")] | length) == 22 and
    ([.menus[].options[]] | length) == 90 and
    ([.menus[].id] | length) == ([.menus[].id] | unique | length) and
    ([.menus[].options[].id] | length) ==
      ([.menus[].options[].id] | unique | length) and
    all(.menus[];
      type == "object" and
      keys == ["controlPolicy", "description", "id", "label", "options",
        "parent", "visibility"] and
      (.controlPolicy == "root" or .controlPolicy == "home" or
       .controlPolicy == "back-home" or .controlPolicy == "escape-root") and
      (.visibility == {
        features:
          (if .id == "blocks" then ["blocklog"]
           elif .id == "advanced" then ["advanced"] else [] end),
        modes: ["local", "light", "offline"], nodeCapabilities: []
      }) and
      ([.options[] | select(.kind != "control") | .order] ==
       ([.options[] | select(.kind != "control") | .order] | sort)) and
      ([.options[] | select(.kind == "control") | has("order")] |
        all(. == false))) and
    all(.menus[].options[] | select(.kind == "action");
      keys == ["description", "executionRequirements", "id", "kind",
        "label", "order", "runtime", "shortcut", "visibility"] and
      .runtime == {apiVersion: 1, libraries: []}) and
    all(.menus[].options[] | select(.kind == "menu");
      keys == ["description", "id", "kind", "label", "order", "shortcut",
        "visibility"]) and
    all(.menus[].options[] | select(.kind == "control");
      keys == ["id", "kind", "label", "navigation", "shortcut"])
  ' "${dump}" >/dev/null || fail 'menu dump violates the frozen JSON contract'
}

prepare_mutation() {
  local name="$1"
  local fixture="${TEST_ROOT}/mutation-${name}"

  rm -rf -- "${fixture}"
  mkdir -p -- "${fixture}/libs"
  cp -R -- "${MODULES_ROOT}" "${fixture}/modules"
  cp -- "${LIBRARY_MANIFEST}" "${fixture}/libs/manifest.json"
  printf '%s\n' "${fixture}"
}

expect_invalid_tree() {
  local name="$1"
  local fixture="$2"
  local output="${TEST_ROOT}/${name}.stdout"
  local error="${TEST_ROOT}/${name}.stderr"
  local status=0

  if cntools_registry_validate_tree \
      "${fixture}/modules" "${fixture}/libs/manifest.json" \
      > "${output}" 2> "${error}"; then
    fail "registry accepted ${name}"
  fi
  [[ ! -s "${output}" ]] || fail "validation of ${name} wrote to stdout"
  [[ ! -s "${error}" ]] || fail "validation of ${name} wrote to stderr"

  status=0
  cntools_registry_dump_menu \
    "${fixture}/modules" "${fixture}/libs/manifest.json" \
    > "${output}" 2> "${error}" || status=$?
  (( status != 0 )) || fail "menu dumper accepted ${name}"
  [[ ! -s "${output}" ]] || fail "menu dumper partially emitted ${name}"
  [[ ! -s "${error}" ]] || fail "menu dumper wrote stderr for ${name}"
}

# shellcheck source=/dev/null
. "${REGISTRY_SOURCE}"
# shellcheck source=/dev/null
. "${CONTEXT_SOURCE}"
# shellcheck source=/dev/null
. "${DISPATCHER_SOURCE}"
declare -F cntools_registry_validate_tree >/dev/null ||
  fail 'registry does not define cntools_registry_validate_tree'
declare -F cntools_registry_dump_menu >/dev/null ||
  fail 'registry does not define cntools_registry_dump_menu'
declare -F cntools_dispatcher_preflight >/dev/null ||
  fail 'dispatcher does not define cntools_dispatcher_preflight'

# Direct callers must fail closed if an ordinary external utility name resolves
# to a caller function or alias. A colliding function body must never execute.
for collision_kind in function alias; do
  collision_sentinel="${TEST_ROOT}/${collision_kind}.utility-executed"
  collision_output="$({
    "${BASH}" -c '
      set -euo pipefail
      registry=$1
      modules=$2
      libraries=$3
      sentinel=$4
      kind=$5
      # shellcheck source=/dev/null
      . "${registry}"
      if [[ "${kind}" == function ]]; then
        jq() { printf executed > "${sentinel}"; return 97; }
      else
        shopt -s expand_aliases
        alias jq=false
      fi
      status=0
      cntools_registry_validate_tree "${modules}" "${libraries}" || status=$?
      [[ "${status}" == 2 && ! -e "${sentinel}" && ! -L "${sentinel}" ]]
    ' bash "${REGISTRY_SOURCE}" "${MODULES_ROOT}" "${LIBRARY_MANIFEST}" \
      "${collision_sentinel}" "${collision_kind}"
  } 2>&1)" || fail "registry did not reject a ${collision_kind} utility collision"
  [[ -z "${collision_output}" ]] ||
    fail "${collision_kind} utility collision produced output: ${collision_output}"
done

feature_metadata="${TEST_ROOT}/dispatcher-feature.module.json"
capability_metadata="${TEST_ROOT}/dispatcher-capability.module.json"
exact_feature_context="${TEST_ROOT}/context-feature-exact.json"
wrong_feature_context="${TEST_ROOT}/context-feature-wrong.json"
exact_capability_context="${TEST_ROOT}/context-capability-exact.json"
wrong_capability_context="${TEST_ROOT}/context-capability-wrong.json"
cp -- "${MODULES_ROOT}/root/wallet/list/module.json" "${feature_metadata}"
cp -- "${MODULES_ROOT}/root/wallet/list/module.json" "${capability_metadata}"
atomic_jq_update "${feature_metadata}" '
  .visibility.features = ["advanced"] |
  .executionRequirements.features = ["advanced"]
'
atomic_jq_update "${capability_metadata}" '
  .visibility.nodeCapabilities = ["n2c"] |
  .executionRequirements.nodeCapabilities = ["n2c"]
'
write_dispatcher_context "${exact_feature_context}" '["advanced"]' '[]'
write_dispatcher_context "${wrong_feature_context}" '["other"]' '[]'
write_dispatcher_context "${exact_capability_context}" '[]' '["n2c"]'
write_dispatcher_context "${wrong_capability_context}" '[]' '["metrics"]'
cntools_dispatcher_preflight "${feature_metadata}" "${exact_feature_context}" ||
  fail 'dispatcher rejected an exact feature requirement match'
if cntools_dispatcher_preflight \
    "${feature_metadata}" "${wrong_feature_context}"; then
  fail 'dispatcher accepted advanced against context feature other'
fi
cntools_dispatcher_preflight \
  "${capability_metadata}" "${exact_capability_context}" ||
  fail 'dispatcher rejected an exact capability requirement match'
if cntools_dispatcher_preflight \
    "${capability_metadata}" "${wrong_capability_context}"; then
  fail 'dispatcher accepted n2c against context capability metrics'
fi

# The runtime predicate must implement the same fixed, ordered requirement
# vocabulary as module schema v2.
jq -e '
  .["$id"] ==
    "https://cardano-community.github.io/guild-operators/cntools/module.schema.v2.json" and
  .["$defs"].requirements.properties == {
    features: {"$ref":"#/$defs/orderedFeatures"},
    modes: {"$ref":"#/$defs/orderedModes"},
    nodeCapabilities: {"$ref":"#/$defs/orderedNodeCapabilities"}
  } and
  .["$defs"].orderedModes.enum == [
    ["local"], ["light"], ["offline"], ["local","light"],
    ["local","offline"], ["light","offline"],
    ["local","light","offline"]
  ] and
  .["$defs"].orderedFeatures.enum == [
    [], ["advanced"], ["blocklog"], ["advanced","blocklog"]
  ] and
  .["$defs"].orderedNodeCapabilities.enum == [
    [], ["forging"], ["local-cli"], ["metrics"], ["n2c"],
    ["forging","local-cli"], ["forging","metrics"], ["forging","n2c"],
    ["local-cli","metrics"], ["local-cli","n2c"], ["metrics","n2c"],
    ["forging","local-cli","metrics"],
    ["forging","local-cli","n2c"], ["forging","metrics","n2c"],
    ["local-cli","metrics","n2c"],
    ["forging","local-cli","metrics","n2c"]
  ] and
  (.["$defs"].action.allOf | length) == 9 and
  ([.["$defs"].action.allOf[0:3][] |
    [.if.properties.executionRequirements.properties.modes.contains.const,
     .then.properties.visibility.properties.modes.contains.const]]) ==
    [["local","local"],["light","light"],["offline","offline"]] and
  ([.["$defs"].action.allOf[3:5][] |
    [.if.properties.visibility.properties.features.contains.const,
     .then.properties.executionRequirements.properties.features.contains.const]]) ==
    [["advanced","advanced"],["blocklog","blocklog"]] and
  ([.["$defs"].action.allOf[5:9][] |
    [.if.properties.visibility.properties.nodeCapabilities.contains.const,
     .then.properties.executionRequirements.properties.nodeCapabilities.contains.const]]) ==
    [["forging","forging"],["local-cli","local-cli"],
     ["metrics","metrics"],["n2c","n2c"]]
' "${MODULE_SCHEMA}" >/dev/null ||
  fail 'module schema v2 requirement vocabulary/subset parity changed'

requirements_metadata="${TEST_ROOT}/requirements-matrix.module.json"
cp -- "${MODULES_ROOT}/root/wallet/list/module.json" \
  "${requirements_metadata}"
for values in \
  '["local"]' \
  '["light"]' \
  '["offline"]' \
  '["local","light"]' \
  '["local","offline"]' \
  '["light","offline"]' \
  '["local","light","offline"]'; do
  atomic_jq_update "${requirements_metadata}" --argjson values "${values}" '
    .visibility.modes = $values |
    .executionRequirements.modes = $values
  '
  cntools_registry_validate_metadata "${requirements_metadata}" ||
    fail "registry rejected allowed ordered mode set ${values}"
done
for values in \
  '[]' '["advanced"]' '["blocklog"]' '["advanced","blocklog"]'; do
  atomic_jq_update "${requirements_metadata}" --argjson values "${values}" '
    .visibility.features = $values |
    .executionRequirements.features = $values
  '
  cntools_registry_validate_metadata "${requirements_metadata}" ||
    fail "registry rejected allowed ordered feature set ${values}"
done
for values in \
  '[]' '["forging"]' '["local-cli"]' '["metrics"]' '["n2c"]' \
  '["forging","local-cli"]' '["forging","metrics"]' \
  '["forging","n2c"]' '["local-cli","metrics"]' \
  '["local-cli","n2c"]' '["metrics","n2c"]' \
  '["forging","local-cli","metrics"]' \
  '["forging","local-cli","n2c"]' \
  '["forging","metrics","n2c"]' \
  '["local-cli","metrics","n2c"]' \
  '["forging","local-cli","metrics","n2c"]'; do
  atomic_jq_update "${requirements_metadata}" --argjson values "${values}" '
    .visibility.nodeCapabilities = $values |
    .executionRequirements.nodeCapabilities = $values
  '
  cntools_registry_validate_metadata "${requirements_metadata}" ||
    fail "registry rejected allowed ordered capability set ${values}"
done

for invalid_filter in \
  '.visibility.modes = ["light","local"] | .executionRequirements.modes = ["light","local"]' \
  '.visibility.features = ["blocklog","advanced"] | .executionRequirements.features = ["blocklog","advanced"]' \
  '.visibility.features = ["other"] | .executionRequirements.features = ["other"]' \
  '.visibility.nodeCapabilities = ["n2c","metrics"] | .executionRequirements.nodeCapabilities = ["n2c","metrics"]' \
  '.visibility.nodeCapabilities = ["other"] | .executionRequirements.nodeCapabilities = ["other"]'; do
  cp -- "${MODULES_ROOT}/root/wallet/list/module.json" \
    "${requirements_metadata}"
  atomic_jq_update "${requirements_metadata}" "${invalid_filter}"
  if cntools_registry_validate_metadata "${requirements_metadata}"; then
    fail "registry accepted invalid requirement vocabulary: ${invalid_filter}"
  fi
done

cp -- "${MODULES_ROOT}/root/wallet/list/module.json" \
  "${requirements_metadata}"
atomic_jq_update "${requirements_metadata}" '
  .visibility.features = [] |
  .executionRequirements.features = ["advanced"] |
  .visibility.nodeCapabilities = [] |
  .executionRequirements.nodeCapabilities = ["n2c"]
'
cntools_registry_validate_metadata "${requirements_metadata}" ||
  fail 'registry rejected intentionally stricter execution requirements'

validation_stdout="${TEST_ROOT}/valid.stdout"
validation_stderr="${TEST_ROOT}/valid.stderr"
cntools_registry_validate_tree "${MODULES_ROOT}" "${LIBRARY_MANIFEST}" \
  > "${validation_stdout}" 2> "${validation_stderr}" ||
  fail 'registry rejected the checked-in Stage 3 module tree'
[[ ! -s "${validation_stdout}" && ! -s "${validation_stderr}" ]] ||
  fail 'successful tree validation produced output'

dump_one="${TEST_ROOT}/menu.one.json"
dump_two="${TEST_ROOT}/menu.two.json"
dump_stderr="${TEST_ROOT}/menu.stderr"
cntools_registry_dump_menu "${MODULES_ROOT}" "${LIBRARY_MANIFEST}" \
  > "${dump_one}" 2> "${dump_stderr}" ||
  fail 'registry could not dump the checked-in Stage 3 module tree'
[[ ! -s "${dump_stderr}" ]] || fail 'successful menu dump wrote to stderr'
CNTOOLS_MODE=offline CNTOOLS_FEATURES=unrelated CNTOOLS_NODE_CAPABILITIES=none \
  cntools_registry_dump_menu "${MODULES_ROOT}" "${LIBRARY_MANIFEST}" \
  > "${dump_two}" 2> "${dump_stderr}" ||
  fail 'registry dump depended on ambient runtime context'
[[ ! -s "${dump_stderr}" ]] || fail 'context-independent dump wrote to stderr'
cmp -s "${dump_one}" "${dump_two}" ||
  fail 'menu dump is not deterministic and context independent'
(
  cd "${TEST_ROOT}"
  LC_ALL=POSIX cntools_registry_dump_menu \
    "${MODULES_ROOT}" "${LIBRARY_MANIFEST}"
) > "${dump_two}" 2> "${dump_stderr}" ||
  fail 'registry dump depended on caller working directory or locale'
[[ ! -s "${dump_stderr}" ]] ||
  fail 'arbitrary-cwd/locale menu dump wrote to stderr'
cmp -s "${dump_one}" "${dump_two}" ||
  fail 'menu dump changed with caller working directory or locale'
cmp -s "${MENU_ORACLE}" "${dump_one}" || {
  diff -u "${MENU_ORACLE}" "${dump_one}" >&2 || true
  fail 'menu dump differs byte-for-byte from the Stage 3 oracle'
}
assert_dump_contract "${dump_one}"
assert_legacy_projection "${dump_one}"

module_count="$(find "${MODULES_ROOT}" -type f -name module.json | wc -l | tr -d ' ')"
action_count="$(find "${MODULES_ROOT}" -type f -name action.sh | wc -l | tr -d ' ')"
[[ "${module_count}" == 69 && "${action_count}" == 54 ]] ||
  fail "source module/action counts are ${module_count}/${action_count}, expected 69/54"

fixture="$(prepare_mutation malformed-json)"
printf '{\n' > "${fixture}/modules/root/wallet/module.json"
expect_invalid_tree malformed-json "${fixture}"

fixture="$(prepare_mutation unsupported-schema)"
atomic_jq_update "${fixture}/modules/root/wallet/module.json" \
  '.schemaVersion = 1'
expect_invalid_tree unsupported-schema "${fixture}"

fixture="$(prepare_mutation unknown-metadata)"
atomic_jq_update "${fixture}/modules/root/wallet/module.json" \
  '.unexpected = true'
expect_invalid_tree unknown-metadata "${fixture}"

fixture="$(prepare_mutation duplicate-root-json-key)"
duplicate_first_json_member \
  "${fixture}/modules/root/wallet/module.json" '"label":"Wallet"'
expect_invalid_tree duplicate-root-json-key "${fixture}"

fixture="$(prepare_mutation duplicate-nested-json-key)"
duplicate_first_json_member \
  "${fixture}/modules/root/wallet/module.json" \
  '"modes":["local","light","offline"]'
expect_invalid_tree duplicate-nested-json-key "${fixture}"

fixture="$(prepare_mutation missing-control-policy)"
atomic_jq_update "${fixture}/modules/root/wallet/module.json" \
  'del(.controlPolicy)'
expect_invalid_tree missing-control-policy "${fixture}"

fixture="$(prepare_mutation invalid-control-policy)"
atomic_jq_update "${fixture}/modules/root/wallet/module.json" \
  '.controlPolicy = "custom"'
expect_invalid_tree invalid-control-policy "${fixture}"

fixture="$(prepare_mutation invalid-visibility)"
atomic_jq_update "${fixture}/modules/root/wallet/module.json" \
  '.visibility.modes = ["local", "local"]'
expect_invalid_tree invalid-visibility "${fixture}"

fixture="$(prepare_mutation execution-mode-not-visible)"
atomic_jq_update "${fixture}/modules/root/wallet/list/module.json" '
  .visibility.modes = ["local"] |
  .executionRequirements.modes = ["local", "light"]
'
expect_invalid_tree execution-mode-not-visible "${fixture}"

fixture="$(prepare_mutation execution-feature-not-visible)"
atomic_jq_update "${fixture}/modules/root/wallet/list/module.json" '
  .visibility.features = ["advanced"] |
  .executionRequirements.features = []
'
expect_invalid_tree execution-feature-not-visible "${fixture}"

fixture="$(prepare_mutation execution-capability-not-visible)"
atomic_jq_update "${fixture}/modules/root/wallet/list/module.json" '
  .visibility.nodeCapabilities = ["metrics"] |
  .executionRequirements.nodeCapabilities = ["n2c"]
'
expect_invalid_tree execution-capability-not-visible "${fixture}"

fixture="$(prepare_mutation label-c0-newline)"
atomic_jq_update "${fixture}/modules/root/wallet/module.json" \
  '.label = "Unsafe\nLabel"'
expect_invalid_tree label-c0-newline "${fixture}"

fixture="$(prepare_mutation description-c0-escape)"
atomic_jq_update "${fixture}/modules/root/wallet/module.json" \
  '.description = "Unsafe\u001bDescription"'
expect_invalid_tree description-c0-escape "${fixture}"

fixture="$(prepare_mutation label-c1-control)"
atomic_jq_update "${fixture}/modules/root/wallet/module.json" \
  '.label = "Unsafe\u009bLabel"'
expect_invalid_tree label-c1-control "${fixture}"

fixture="$(prepare_mutation description-bidi-override)"
atomic_jq_update "${fixture}/modules/root/wallet/module.json" \
  '.description = "Unsafe\u202eDescription"'
expect_invalid_tree description-bidi-override "${fixture}"

fixture="$(prepare_mutation label-bidi-isolate)"
atomic_jq_update "${fixture}/modules/root/wallet/module.json" \
  '.label = "Unsafe\u2066Label"'
expect_invalid_tree label-bidi-isolate "${fixture}"

fixture="$(prepare_mutation duplicate-id)"
atomic_jq_update "${fixture}/modules/root/wallet/register/module.json" \
  '.id = "wallet.list"'
expect_invalid_tree duplicate-id "${fixture}"

fixture="$(prepare_mutation path-id-mismatch)"
atomic_jq_update "${fixture}/modules/root/wallet/register/module.json" \
  '.id = "wallet.renamed"'
expect_invalid_tree path-id-mismatch "${fixture}"

fixture="$(prepare_mutation sibling-shortcut-collision)"
atomic_jq_update "${fixture}/modules/root/wallet/register/module.json" \
  '.shortcut = "l"'
expect_invalid_tree sibling-shortcut-collision "${fixture}"

fixture="$(prepare_mutation sibling-order-collision)"
atomic_jq_update "${fixture}/modules/root/wallet/register/module.json" \
  '.order = 50'
expect_invalid_tree sibling-order-collision "${fixture}"

fixture="$(prepare_mutation canonical-integer-order)"
atomic_jq_update "${fixture}/modules/root/wallet/list/module.json" \
  '.order = 100'
cntools_registry_validate_tree \
  "${fixture}/modules" "${fixture}/libs/manifest.json" \
  > "${TEST_ROOT}/canonical-order.stdout" \
  2> "${TEST_ROOT}/canonical-order.stderr" ||
  fail 'registry rejected a unique canonical integer order'
[[ ! -s "${TEST_ROOT}/canonical-order.stdout" &&
   ! -s "${TEST_ROOT}/canonical-order.stderr" ]] ||
  fail 'canonical integer order validation produced output'

for equivalent_order in '10.0' '1e1' '1E+1'; do
  fixture="$(prepare_mutation "equivalent-order-${equivalent_order}")"
  replace_first_json_literal \
    "${fixture}/modules/root/wallet/list/module.json" \
    '"order":50' "\"order\":${equivalent_order}"
  expect_invalid_tree "equivalent sibling orders 10 and ${equivalent_order}" \
    "${fixture}"
done

fixture="$(prepare_mutation equivalent-negative-zero-order)"
atomic_jq_update "${fixture}/modules/root/wallet/list/module.json" \
  '.order = 0'
replace_first_json_literal \
  "${fixture}/modules/root/wallet/show/module.json" \
  '"order":60' '"order":-0'
expect_invalid_tree 'equivalent sibling orders 0 and -0' "${fixture}"

fixture="$(prepare_mutation control-shortcut-collision)"
atomic_jq_update "${fixture}/modules/root/wallet/register/module.json" \
  '.shortcut = "h"'
expect_invalid_tree control-shortcut-collision "${fixture}"

fixture="$(prepare_mutation synthesized-home-id-collision)"
cp -R -- "${fixture}/modules/root/wallet/list" \
  "${fixture}/modules/root/wallet/home"
atomic_jq_update "${fixture}/modules/root/wallet/home/module.json" \
  '.id = "wallet.home" | .order = 100 | .shortcut = "o"'
expect_invalid_tree synthesized-home-id-collision "${fixture}"

fixture="$(prepare_mutation synthesized-back-id-collision)"
cp -R -- "${fixture}/modules/root/wallet/new/cli" \
  "${fixture}/modules/root/wallet/new/back"
atomic_jq_update "${fixture}/modules/root/wallet/new/back/module.json" \
  '.id = "wallet.new.back" | .order = 30 | .shortcut = "a"'
expect_invalid_tree synthesized-back-id-collision "${fixture}"

fixture="$(prepare_mutation synthesized-escape-id-collision)"
cp -R -- "${fixture}/modules/root/blocks/epoch" \
  "${fixture}/modules/root/blocks/escape"
atomic_jq_update "${fixture}/modules/root/blocks/escape/module.json" \
  '.id = "blocks.escape" | .order = 30 | .shortcut = "x"'
expect_invalid_tree synthesized-escape-id-collision "${fixture}"

fixture="$(prepare_mutation unknown-library)"
atomic_jq_update "${fixture}/modules/root/wallet/register/module.json" \
  '.runtime.libraries = ["missing"]'
expect_invalid_tree unknown-library "${fixture}"

fixture="$(prepare_mutation dependency-cycle)"
atomic_jq_update "${fixture}/libs/manifest.json" '
  .libraries = [
    {id:"first", path:"libs/first.sh", apiVersion:1, dependencies:["second"]},
    {id:"second", path:"libs/second.sh", apiVersion:1, dependencies:["first"]}
  ]
'
expect_invalid_tree dependency-cycle "${fixture}"

fixture="$(prepare_mutation missing-action)"
rm -- "${fixture}/modules/root/wallet/register/action.sh"
expect_invalid_tree missing-action "${fixture}"

fixture="$(prepare_mutation extra-action-file)"
printf 'undeclared\n' > "${fixture}/modules/root/wallet/register/private.txt"
expect_invalid_tree extra-action-file "${fixture}"

fixture="$(prepare_mutation nested-action)"
mkdir -- "${fixture}/modules/root/wallet/register/child"
expect_invalid_tree nested-action "${fixture}"

fixture="$(prepare_mutation menu-entrypoint)"
printf 'cntools_action_main() { :; }\n' > \
  "${fixture}/modules/root/wallet/action.sh"
expect_invalid_tree menu-entrypoint "${fixture}"

fixture="$(prepare_mutation missing-entrypoint)"
printf '#!/usr/bin/env bash\ntrue\n' > \
  "${fixture}/modules/root/wallet/register/action.sh"
expect_invalid_tree missing-entrypoint "${fixture}"

fixture="$(prepare_mutation symlink-entry)"
ln -s module.json "${fixture}/modules/root/wallet/link.json"
expect_invalid_tree symlink-entry "${fixture}"

fixture="$(prepare_mutation extra-root)"
mkdir -- "${fixture}/modules/other"
expect_invalid_tree extra-root "${fixture}"

fixture="$(prepare_mutation nonexecution)"
sentinel="${TEST_ROOT}/action.executed"
library_sentinel="${TEST_ROOT}/library.executed"
printf '\nprintf executed > %q\n' "${sentinel}" >> \
  "${fixture}/modules/root/wallet/register/action.sh"
printf '#!/usr/bin/env bash\nprintf executed > %q\n' \
  "${library_sentinel}" > "${fixture}/libs/probe.sh"
atomic_jq_update "${fixture}/libs/manifest.json" '
  .libraries = [
    {id:"probe", path:"libs/probe.sh", apiVersion:1, dependencies:[]}
  ]
'
atomic_jq_update "${fixture}/modules/root/wallet/register/module.json" \
  '.runtime.libraries = ["probe"]'
cntools_registry_validate_tree \
  "${fixture}/modules" "${fixture}/libs/manifest.json" >/dev/null ||
  fail 'registry rejected the nonexecution probe fixture'
cntools_registry_dump_menu \
  "${fixture}/modules" "${fixture}/libs/manifest.json" >/dev/null ||
  fail 'menu dumper rejected the nonexecution probe fixture'
[[ ! -e "${sentinel}" && ! -L "${sentinel}" ]] ||
  fail 'registry validation or dumping executed an action'
[[ ! -e "${library_sentinel}" && ! -L "${library_sentinel}" ]] ||
  fail 'registry validation or dumping executed a runtime library'

printf 'CNTools Stage 3 module registry tests passed\n'
