#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
MODULE_ROOT="${CNTOOLS_ROOT}/modules/root"
MENU_FIXTURE="${REPO_ROOT}/files/tests/fixtures/cntools-menu-skeleton.tsv"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-menu-skeleton.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"

cleanup_test() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local description="$3"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${description}: expected '${expected}', got '${actual}'"
}

trim_count() {
  tr -d '[:space:]'
}

fixture_directory() {
  local module_id="$1"
  if [[ "${module_id}" == "root" ]]; then
    printf '%s\n' "${MODULE_ROOT}"
  else
    printf '%s\n' "${MODULE_ROOT}/${module_id}"
  fi
}

fixture_parent() {
  local module_id="$1"
  if [[ "${module_id}" != */* ]]; then
    printf 'root\n'
  else
    printf '%s\n' "${module_id%/*}"
  fi
}

write_actual_inventory() {
  local metadata=""
  local directory=""
  local module_id=""

  while IFS= read -r metadata; do
    directory="${metadata%/module.json}"
    if [[ "${directory}" == "${MODULE_ROOT}" ]]; then
      module_id="root"
    else
      module_id="${directory#"${MODULE_ROOT}/"}"
    fi
    jq -er --arg module_id "${module_id}" '
      [
        $module_id,
        .kind,
        (.shortcut // "-"),
        ((.order // "-") | tostring),
        (if has("modes") then (.modes | join(",")) else "-" end),
        (if has("advanced") then (.advanced | tostring) else "-" end),
        .label
      ] | @tsv
    ' "${metadata}"
  done < <(find "${MODULE_ROOT}" -type f -name module.json -print | LC_ALL=C sort)
}

write_legacy_inventory() {
  write_actual_inventory | awk -F '\t' \
    '$1 != "update" && index($1, "update/") != 1'
}

fixture_children() {
  local wanted_parent="$1"
  local module_id=""
  local kind=""
  local shortcut=""
  local order=""
  local modes=""
  local advanced=""
  local label=""
  local parent=""

  while IFS=$'\t' read -r \
    module_id kind shortcut order modes advanced label; do
    [[ "${module_id}" != "root" ]] || continue
    parent="$(fixture_parent "${module_id}")"
    [[ "${parent}" == "${wanted_parent}" ]] || continue
    printf '%s\n' "${module_id}"
  done < "${MENU_FIXTURE}"
}

fixture_action_modes() {
  local wanted_id="$1"
  local module_id=""
  local kind=""
  local shortcut=""
  local order=""
  local modes=""
  local advanced=""
  local label=""

  while IFS=$'\t' read -r \
    module_id kind shortcut order modes advanced label; do
    if [[ "${module_id}" == "${wanted_id}" && "${kind}" == "action" ]]; then
      printf '%s\n' "${modes}"
      return 0
    fi
  done < "${MENU_FIXTURE}"
  return 1
}

for required_command in awk bash cmp diff find grep jq sort tr wc; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

[[ -d "${MODULE_ROOT}" && ! -L "${MODULE_ROOT}" ]] ||
  fail "CNTools module root is missing or unsafe"
[[ -f "${MENU_FIXTURE}" && ! -L "${MENU_FIXTURE}" ]] ||
  fail "CNTools menu fixture is missing or unsafe"

expected_inventory="${TEST_ROOT}/expected.tsv"
actual_inventory="${TEST_ROOT}/actual.tsv"
LC_ALL=C sort "${MENU_FIXTURE}" > "${expected_inventory}"
write_legacy_inventory | LC_ALL=C sort > "${actual_inventory}"
diff -u "${expected_inventory}" "${actual_inventory}" ||
  fail "CNTools legacy menu hierarchy differs from the Phase 4 inventory"

assert_eq "$(wc -l < "${MENU_FIXTURE}" | trim_count)" "69" \
  "module inventory count"
assert_eq "$(grep -c $'\tmenu\t' "${MENU_FIXTURE}" | trim_count)" "15" \
  "menu inventory count"
assert_eq "$(grep -c $'\taction\t' "${MENU_FIXTURE}" | trim_count)" "54" \
  "action inventory count"
assert_eq "$(find "${MODULE_ROOT}" -type d -print | wc -l | trim_count)" "73" \
  "Phase 5 module directory count"
assert_eq "$(find "${MODULE_ROOT}" -type f -name module.json -print | wc -l | trim_count)" "73" \
  "Phase 5 module metadata count"
assert_eq "$(find "${MODULE_ROOT}" -type f -name action.sh -print | wc -l | trim_count)" "57" \
  "Phase 5 action entrypoint count"
assert_eq "$(find "${MODULE_ROOT}" -type f -print | wc -l | trim_count)" "130" \
  "Phase 7 module payload file count"
[[ -z "$(find "${MODULE_ROOT}" -type l -print)" ]] ||
  fail "CNTools menu skeleton contains a symbolic link"

actual_update_ids="$({
  find "${MODULE_ROOT}/update" -type f -name module.json -print |
    while IFS= read -r metadata; do
      update_relative="${metadata#"${MODULE_ROOT}/"}"
      printf '%s\n' "${update_relative%/module.json}"
    done
} | LC_ALL=C sort)"
assert_eq "${actual_update_ids}" \
  $'update\nupdate/check\nupdate/install\nupdate/view-changes' \
  "Phase 5 update module inventory"
jq -e '
  .kind == "menu" and .label == "Update" and .shortcut == "u" and
  (.order | type == "number") and ((has("advanced") | not))
' "${MODULE_ROOT}/update/module.json" >/dev/null ||
  fail "Update menu metadata is invalid"
for update_specification in \
  'check|c|Check Again' \
  'view-changes|v|View Changes' \
  'install|i|Install Update'; do
  update_id="${update_specification%%|*}"
  update_remainder="${update_specification#*|}"
  update_shortcut="${update_remainder%%|*}"
  update_label="${update_remainder#*|}"
  jq -e \
    --arg shortcut "${update_shortcut}" \
    --arg label "${update_label}" '
      .kind == "action" and .label == $label and .shortcut == $shortcut and
      .modes == ["local", "light"] and .libs == ["update.sh"]
    ' "${MODULE_ROOT}/update/${update_id}/module.json" >/dev/null ||
    fail "Update action metadata is invalid: ${update_id}"
done

connected_only=0
offline_capable=0
canonical_action=""
while IFS=$'\t' read -r \
  module_id kind shortcut order modes advanced label; do
  module_directory="$(fixture_directory "${module_id}")"
  metadata="${module_directory}/module.json"
  [[ -d "${module_directory}" && ! -L "${module_directory}" ]] ||
    fail "module directory is missing or unsafe: ${module_id}"
  [[ -f "${metadata}" && ! -L "${metadata}" && -s "${metadata}" ]] ||
    fail "module metadata is missing or unsafe: ${module_id}"
  jq -e '
    type == "object" and
    (.description | type == "string" and length > 0 and
      (test("[[:cntrl:]]") | not))
  ' "${metadata}" >/dev/null ||
    fail "module has no valid one-line description: ${module_id}"

  if [[ "${kind}" == "action" ]]; then
    action_file="${module_directory}/action.sh"
    [[ -f "${action_file}" && ! -L "${action_file}" && -s "${action_file}" ]] ||
      fail "action entrypoint is missing or unsafe: ${module_id}"
    bash -n "${action_file}" ||
      fail "action entrypoint has invalid Bash syntax: ${module_id}"
    case "${module_id}" in
      wallet/list)
        jq -e '.libs == ["wallet.sh", "wallet-query.sh"]' \
          "${metadata}" >/dev/null ||
          fail "Wallet List has unexpected library declarations"
        grep -F 'cntools_wallet_action_list' "${action_file}" >/dev/null ||
          fail "Wallet List does not call its functional entrypoint"
        ;;
      wallet/show)
        jq -e '.libs == ["wallet.sh", "wallet-query.sh"]' \
          "${metadata}" >/dev/null ||
          fail "Wallet Show has unexpected library declarations"
        grep -F 'cntools_wallet_action_show' "${action_file}" >/dev/null ||
          fail "Wallet Show does not call its functional entrypoint"
        ;;
      *)
        jq -e '.libs == ["placeholder.sh"]' "${metadata}" >/dev/null ||
          fail "placeholder action has unexpected library declarations: ${module_id}"
        grep -F 'cntools_action_placeholder' "${action_file}" >/dev/null ||
          fail "action does not call the shared placeholder: ${module_id}"
        if [[ -z "${canonical_action}" ]]; then
          canonical_action="${action_file}"
        else
          cmp -s "${canonical_action}" "${action_file}" ||
            fail "Phase 4 placeholder entrypoints are not identical: ${module_id}"
        fi
        ;;
    esac
    [[ -z "$(find "${module_directory}" -mindepth 1 -type d -print)" ]] ||
      fail "action module contains a child directory: ${module_id}"
    case "${modes}" in
      local,light) connected_only=$((connected_only + 1)) ;;
      local,light,offline) offline_capable=$((offline_capable + 1)) ;;
      *) fail "unexpected action mode declaration for ${module_id}: ${modes}" ;;
    esac
  else
    [[ ! -e "${module_directory}/action.sh" &&
       ! -L "${module_directory}/action.sh" ]] ||
      fail "menu unexpectedly contains an action entrypoint: ${module_id}"
  fi
done < "${MENU_FIXTURE}"

assert_eq "${connected_only}" "20" "local/light-only action count"
assert_eq "${offline_capable}" "34" "offline-capable action count"
[[ -f "${CNTOOLS_ROOT}/lib/placeholder.sh" &&
   ! -L "${CNTOOLS_ROOT}/lib/placeholder.sh" &&
   -s "${CNTOOLS_ROOT}/lib/placeholder.sh" ]] ||
  fail "shared placeholder library is missing or unsafe"
bash -n "${CNTOOLS_ROOT}/lib/placeholder.sh" ||
  fail "shared placeholder library has invalid Bash syntax"

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools live menu skeleton tests skipped: Bash 4.4+ is required\n'
  printf 'CNTools menu skeleton static tests passed\n'
  exit 0
fi

# The live tests use only the new framework. They do not source env, the
# legacy CNTools entrypoint, or cntools.library. Gum presentation boundaries
# are replaced below so catalog and action-loader checks need no terminal.
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/startup.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/menu.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/action.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/update.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/gum.sh"

CNTOOLS_MODULE_ROOT="${MODULE_ROOT}"
CNTOOLS_LIB_DIR="${CNTOOLS_ROOT}/lib"
CNTOOLS_VALIDATION_BASH="bash"
CNTOOLS_MODE="local"
CNTOOLS_BACKEND="cnode"
CNTOOLS_NETWORK="preview"
CNTOOLS_ADVANCED="Y"
CNTOOLS_VERSION="$(< "${CNTOOLS_ROOT}/VERSION")"
CNTOOLS_UI_INTERACTIVE="N"
CNTOOLS_UI_CAPABLE="N"
CNTOOLS_TEST_LOG_TRACE="${TEST_ROOT}/actions.log"
CNTOOLS_TEST_UI_TRACE="${TEST_ROOT}/ui.log"

cntools_log() {
  local category="${1:-INFO}"
  shift || true
  printf '%s\t%s\t%s\n' \
    "${category}" "${CNTOOLS_ACTION_ID:-}" "$*" >> "${CNTOOLS_TEST_LOG_TRACE}"
}

cntools_ui_render_begin() {
  local label="${1:-CNTools}"
  local breadcrumb="${2:-/}"

  printf 'BEGIN\t%s\t%s\n' "${label}" "${breadcrumb}" >> "${CNTOOLS_TEST_UI_TRACE}"
  printf '%s\n%s\n' "${label}" "${breadcrumb}"
}

cntools_ui_render_status() {
  local level="${1:-info}"
  local message="${2:-}"

  printf 'STATUS\t%s\t%s\n' "${level}" "${message}" >> "${CNTOOLS_TEST_UI_TRACE}"
  printf '%s\n' "${message}"
}

cntools_ui_read_key() {
  local output_variable="${1:-}"

  printf 'WAIT\n' >> "${CNTOOLS_TEST_UI_TRACE}"
  printf -v "${output_variable}" '%s' enter
}

ui_trace_count() {
  local record_type="${1:-}"

  awk -F '\t' -v record_type="${record_type}" '
    $1 == record_type { count++ }
    END { print count + 0 }
  ' "${CNTOOLS_TEST_UI_TRACE}"
}

cntools_menu_validate_tree ||
  fail "production menu failed full-tree framework validation: ${CNTOOLS_MENU_ERROR:-unknown error}"

CNTOOLS_ADVANCED="N"
cntools_menu_open "${MODULE_ROOT}" ||
  fail "root menu could not be opened without advanced mode"
assert_eq "${CNTOOLS_MENU_IDS[*]}" \
  "wallet funds pool transaction vote blocks backup update" \
  "root menu without advanced features"

CNTOOLS_ADVANCED="Y"
cntools_menu_open "${MODULE_ROOT}" ||
  fail "root menu could not be opened with advanced mode"
assert_eq "${CNTOOLS_MENU_IDS[*]}" \
  "wallet funds pool transaction vote blocks backup advanced update" \
  "root menu with advanced features"

while IFS=$'\t' read -r \
  module_id kind shortcut order modes advanced label; do
  [[ "${kind}" == "menu" ]] || continue
  module_directory="$(fixture_directory "${module_id}")"
  CNTOOLS_ADVANCED="Y"
  cntools_menu_open "${module_directory}" ||
    fail "production menu could not be opened: ${module_id}"
  expected_children=""
  while IFS= read -r child_id; do
    if [[ -n "${expected_children}" ]]; then
      expected_children+=" "
    fi
    expected_children+="${child_id}"
  done < <(fixture_children "${module_id}")
  if [[ "${module_id}" == "root" ]]; then
    expected_children+=" update"
  fi
  assert_eq "${CNTOOLS_MENU_IDS[*]}" "${expected_children}" \
    "ordered children of ${module_id}"
done < "${MENU_FIXTURE}"

for mode in local light offline; do
  CNTOOLS_MODE="${mode}"
  while IFS=$'\t' read -r \
    module_id kind shortcut order modes advanced label; do
    [[ "${kind}" == "menu" ]] || continue
    module_directory="$(fixture_directory "${module_id}")"
    CNTOOLS_ADVANCED="Y"
    cntools_menu_open "${module_directory}" ||
      fail "menu could not be opened for ${module_id} in ${mode} mode"
    for (( index = 0; index < ${#CNTOOLS_MENU_IDS[@]}; index++ )); do
      [[ "${CNTOOLS_MENU_KINDS[index]}" == "action" ]] || continue
      child_id="${CNTOOLS_MENU_IDS[index]}"
      child_modes="$(fixture_action_modes "${child_id}")" ||
        fail "fixture modes are missing for ${child_id}"
      expected_enabled="N"
      case ",${child_modes}," in
        *,"${mode}",*) expected_enabled="Y" ;;
      esac
      assert_eq "${CNTOOLS_MENU_ENABLED[index]}" "${expected_enabled}" \
        "${child_id} enabled state in ${mode} mode"
    done
  done < "${MENU_FIXTURE}"
done

# Every action not implemented by Phase 7 remains a runnable placeholder.
CNTOOLS_MODE="local"
while IFS=$'\t' read -r \
  module_id kind shortcut order modes advanced label; do
  [[ "${kind}" == "action" ]] || continue
  case "${module_id}" in wallet/list|wallet/show) continue ;; esac
  module_directory="$(fixture_directory "${module_id}")"
  if output="$(cntools_action_run "${module_directory}" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "0" "placeholder status for ${module_id}"
  [[ "${output}" == *"${label}"* &&
     "${output}" == *"Not implemented yet"* ]] ||
    fail "placeholder notice is incomplete for ${module_id}"
  if [[ "${module_id}" == "wallet/new/mnemonic" ]]; then
    [[ "${output}" == *"/ Wallet / New / Mnemonic"* ]] ||
      fail "placeholder breadcrumb does not preserve the full action path"
  fi
  grep -F $'ACTION\t'"${module_id}"$'\tnot implemented yet' \
    "${CNTOOLS_TEST_LOG_TRACE}" >/dev/null ||
    fail "placeholder selection was not logged for ${module_id}"
done < "${MENU_FIXTURE}"

# Direct loading must enforce every production offline restriction as well as
# the menu's disabled-row presentation above.
CNTOOLS_MODE="offline"
while IFS=$'\t' read -r \
  module_id kind shortcut order modes advanced label; do
  [[ "${kind}" == "action" && "${modes}" == "local,light" ]] || continue
  module_directory="$(fixture_directory "${module_id}")"
  if cntools_action_run "${module_directory}" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "3" \
    "unsupported offline action status for ${module_id}"
done < "${MENU_FIXTURE}"

grep -F $'ACTION\twallet/remove\tselected' \
  "${CNTOOLS_TEST_LOG_TRACE}" >/dev/null ||
  fail "action selection was not logged with the action identity"

# A non-interactive placeholder must not consume redirected input.
CNTOOLS_MODE="local"
CNTOOLS_UI_INTERACTIVE="N"
exec 9<<< 'noninteractive-input'
cntools_action_run "${MODULE_ROOT}/wallet/remove" <&9 >/dev/null ||
  fail "non-interactive placeholder invocation failed"
IFS= read -r remaining_input <&9 ||
  fail "non-interactive placeholder consumed its input"
exec 9<&-
assert_eq "${remaining_input}" "noninteractive-input" \
  "non-interactive placeholder input preservation"

# An interactive placeholder invokes the Gum wait boundary exactly once. The
# boundary is stubbed above because Gum input behavior has its own UI tests.
waits_before="$(ui_trace_count WAIT)"
CNTOOLS_UI_INTERACTIVE="Y"
cntools_action_run "${MODULE_ROOT}/wallet/remove" </dev/null >/dev/null ||
  fail "interactive placeholder invocation failed"
waits_after="$(ui_trace_count WAIT)"
assert_eq "$((waits_after - waits_before))" "1" \
  "interactive placeholder wait boundary"
CNTOOLS_UI_INTERACTIVE="N"

printf 'CNTools menu skeleton tests passed\n'
