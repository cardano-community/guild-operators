#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2154,SC2329
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
MENU_FIXTURE="${REPO_ROOT}/files/tests/fixtures/cntools-menu.json"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-menu.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"

cleanup_test() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

for required_command in diff grep jq; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

jq -e '
  . as $document |
  ([.menus[].id]) as $menu_ids |
  ([.menus[] | select(.id != "root") | .id]) as $non_root_ids |
  ([.menus[].options[] | select(.kind == "menu") | .id]) as $menu_links |
  .schemaVersion == 1 and
  (.menus | type == "array" and length == 15) and
  ([.menus[] | {id, parent, legacyAnchor}] | sort_by(.id)) ==
    ([
      {id: "root", parent: null, legacyAnchor: "select_opt \"[w] Wallet\" \"[f] Funds\""},
      {id: "wallet", parent: "root", legacyAnchor: "Select Wallet Operation"},
      {id: "wallet.new", parent: "wallet", legacyAnchor: "Select Wallet Creation Type"},
      {id: "wallet.import", parent: "wallet", legacyAnchor: "Select Wallet Import Operation"},
      {id: "funds", parent: "root", legacyAnchor: "Select Funds Operation"},
      {id: "pool", parent: "root", legacyAnchor: "Select Pool Operation"},
      {id: "transaction", parent: "root", legacyAnchor: "Select Transaction Operation"},
      {id: "vote", parent: "root", legacyAnchor: "Select Vote Operation"},
      {id: "vote.governance", parent: "vote", legacyAnchor: "Select Governance Operation"},
      {id: "vote.catalyst", parent: "vote", legacyAnchor: "Select Catalyst Operation"},
      {id: "blocks", parent: "root", legacyAnchor: "select_opt \"[s] Summary\" \"[e] Epoch\" \"[Esc] Cancel\""},
      {id: "backup", parent: "root", legacyAnchor: "Backup or Restore?"},
      {id: "advanced", parent: "root", legacyAnchor: "select_opt \"[m] Metadata\" \"[a] Asset\" \"[s] MultiSig\""},
      {id: "advanced.asset", parent: "advanced", legacyAnchor: "Select Asset Operation"},
      {id: "advanced.multisig", parent: "advanced", legacyAnchor: "Select MultiSig Operation"}
    ] | sort_by(.id)) and
  ([.menus[].options[] |
      select(.kind == "control") |
      {id, navigation}] | sort_by(.id)) ==
    ([
      {id: "root.refresh", navigation: "refresh-root"},
      {id: "root.quit", navigation: "exit"},
      {id: "wallet.home", navigation: "root"},
      {id: "wallet.new.back", navigation: "wallet"},
      {id: "wallet.new.home", navigation: "root"},
      {id: "wallet.import.back", navigation: "wallet"},
      {id: "wallet.import.home", navigation: "root"},
      {id: "funds.home", navigation: "root"},
      {id: "pool.home", navigation: "root"},
      {id: "transaction.home", navigation: "root"},
      {id: "vote.home", navigation: "root"},
      {id: "vote.governance.back", navigation: "vote"},
      {id: "vote.governance.home", navigation: "root"},
      {id: "vote.catalyst.back", navigation: "vote"},
      {id: "vote.catalyst.home", navigation: "root"},
      {id: "blocks.escape", navigation: "root"},
      {id: "backup.escape", navigation: "root"},
      {id: "advanced.home", navigation: "root"},
      {id: "advanced.asset.back", navigation: "advanced"},
      {id: "advanced.asset.home", navigation: "root"},
      {id: "advanced.multisig.back", navigation: "advanced"},
      {id: "advanced.multisig.home", navigation: "root"}
    ] | sort_by(.id)) and
  ([.menus[] as $menu |
      $menu.options[] |
      select(.kind == "action") |
      "\($menu.id)|\(.shortcut)|\(.id)"] | sort) ==
    ([
      "wallet|r|wallet.register",
      "wallet|z|wallet.deregister",
      "wallet|l|wallet.list",
      "wallet|s|wallet.show",
      "wallet|x|wallet.remove",
      "wallet|d|wallet.decrypt",
      "wallet|e|wallet.encrypt",
      "wallet.new|m|wallet.new.mnemonic",
      "wallet.new|c|wallet.new.cli",
      "wallet.import|m|wallet.import.mnemonic",
      "wallet.import|w|wallet.import.hardware",
      "funds|s|funds.send",
      "funds|d|funds.delegate",
      "funds|w|funds.withdraw",
      "pool|n|pool.new",
      "pool|i|pool.import",
      "pool|r|pool.register",
      "pool|m|pool.modify",
      "pool|x|pool.retire",
      "pool|l|pool.list",
      "pool|s|pool.show",
      "pool|o|pool.rotate",
      "pool|d|pool.decrypt",
      "pool|e|pool.encrypt",
      "pool|c|pool.calidus",
      "transaction|s|transaction.sign",
      "transaction|t|transaction.submit",
      "vote.governance|i|vote.governance.info",
      "vote.governance|d|vote.governance.delegate",
      "vote.governance|l|vote.governance.proposals",
      "vote.governance|v|vote.governance.cast",
      "vote.governance|r|vote.governance.drep-register",
      "vote.governance|x|vote.governance.drep-retire",
      "vote.governance|m|vote.governance.multisig-drep",
      "vote.governance|k|vote.governance.derive-keys",
      "vote.catalyst|r|vote.catalyst.register",
      "vote.catalyst|q|vote.catalyst.qr",
      "vote.catalyst|v|vote.catalyst.verify",
      "blocks|s|blocks.summary",
      "blocks|e|blocks.epoch",
      "backup|b|backup.create",
      "backup|r|backup.restore",
      "advanced|m|advanced.metadata",
      "advanced|x|advanced.delete-private-keys",
      "advanced.asset|c|advanced.asset.create-policy",
      "advanced.asset|l|advanced.asset.list",
      "advanced.asset|s|advanced.asset.show",
      "advanced.asset|d|advanced.asset.decrypt-policy",
      "advanced.asset|e|advanced.asset.encrypt-policy",
      "advanced.asset|m|advanced.asset.mint",
      "advanced.asset|x|advanced.asset.burn",
      "advanced.asset|r|advanced.asset.register",
      "advanced.multisig|c|advanced.multisig.create",
      "advanced.multisig|d|advanced.multisig.derive-keys"
    ] | sort) and
  ($menu_ids | length == (unique | length)) and
  ([.menus[].options[].id] | length == (unique | length)) and
  ([.menus[] | select(.id == "root" and .parent == null)] | length == 1) and
  (($menu_links | sort) == ($non_root_ids | sort)) and
  ([.menus[].options[] | select(.kind == "action")] | length == 54) and
  ([.menus[] | .options | map(.shortcut)] |
    all(length == (unique | length))) and
  all(.menus[];
    . as $menu |
    (type == "object") and
    (.id | type == "string" and test("^[a-z][a-z0-9.-]*$")) and
    (.options | type == "array") and
    (.legacyAnchor | type == "string" and length > 0) and
    (if .id == "root" then
       .parent == null
     else
       (.parent | type == "string") and
       ($menu_ids | index($menu.parent) != null)
     end) and
    all(.options[];
      . as $option |
      (type == "object") and
      ($option.id | type == "string" and test("^[a-z][a-z0-9.-]*$")) and
      (($option.kind == "menu") or
       ($option.kind == "action") or
       ($option.kind == "control")) and
      ($option.shortcut | type == "string" and length > 0) and
      ($option.label | type == "string" and length > 0) and
      (if $option.kind == "menu" then
         ($option.navigation == null) and
         ([ $document.menus[] |
            select(.id == $option.id and .parent == $menu.id) ] | length == 1)
       elif $option.kind == "action" then
         ($option.navigation == null) and
         ($menu_ids | index($option.id) == null) and
         ($option.id | startswith($menu.id + ".")) and
         ($option.id | ltrimstr($menu.id + ".") |
           test("^[a-z][a-z0-9-]*$"))
       else
         ($option.id | startswith($menu.id + ".")) and
         ($option.navigation | type == "string") and
         (if $option.navigation == "refresh-root" then
            ($menu.id == "root" and $option.id == "root.refresh")
          elif $option.navigation == "exit" then
            ($menu.id == "root" and $option.id == "root.quit")
          else
            ($option.navigation == "root" or
             $option.navigation == $menu.parent)
          end)
       end) and
      (if $option.visibility == null then
         true
       elif $option.visibility == "advanced" then
         ($menu.id == "root" and $option.id == "advanced")
       elif $option.visibility == "blocklog" then
         ($menu.id == "root" and $option.id == "blocks")
       else
         false
       end)
    )
  )
' "${MENU_FIXTURE}" >/dev/null ||
  fail "CNTools semantic menu fixture is invalid"

while IFS= read -r legacy_anchor; do
  grep -F -- "${legacy_anchor}" "${CNTOOLS_SCRIPT}" >/dev/null ||
    fail "CNTools menu legacy anchor is absent: ${legacy_anchor}"
done < <(jq -r '.menus[].legacyAnchor' "${MENU_FIXTURE}")

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools dynamic menu traversal skipped: Bash 4.4+ is required\n'
  exit 0
fi

# Sourcing is definition-only; runtime startup and the legacy library are not
# needed to traverse the existing menu controller with navigation-only choices.
. "${CNTOOLS_SCRIPT}"

expected_menu_options() {
  local menu_id="$1"
  local advanced="$2"
  local blocklog="$3"
  jq -r \
    --arg menu_id "${menu_id}" \
    --arg advanced "${advanced}" \
    --arg blocklog "${blocklog}" '
      .menus[] |
      select(.id == $menu_id) |
      .options[] |
      select(
        (.visibility == null) or
        (.visibility == "advanced" and $advanced == "true") or
        (.visibility == "blocklog" and $blocklog == "true")
      ) |
      "[\(.shortcut)] \(.label)"
    ' "${MENU_FIXTURE}"
}

run_menu_case() (
  local case_name="$1"
  local menu_id="$2"
  local mode="$3"
  local advanced="$4"
  local blocklog="$5"
  local target_call="$6"
  local expected_menu_calls="$7"
  local expected_root_cycles="$8"
  shift 8
  local -a choices=("$@")
  local choice_cursor=0
  local menu_call=0
  local cleanup_calls=0
  local metric_calls=0
  local price_calls=0
  local protocol_calls=0
  local expected_current_menu="root"
  local actual_file="${TEST_ROOT}/${case_name}.actual"
  local expected_file="${TEST_ROOT}/${case_name}.expected"
  local runtime_dir="${TEST_ROOT}/${case_name}.runtime"
  local blocklog_file="${runtime_dir}/blocklog.db"

  # The production script does not enable errexit or nounset. Menu choices use
  # non-zero statuses as indexes, so the traversal must preserve that contract.
  set +e
  set +u
  set +o pipefail
  mkdir -p "${runtime_dir}"
  : > "${actual_file}"
  if [[ "${blocklog}" == "true" ]]; then
    : > "${blocklog_file}"
  fi

  TMP_DIR="${runtime_dir}"
  BLOCKLOG_DB="${blocklog_file}"
  ADVANCED_MODE="${advanced}"
  CNTOOLS_MODE="${mode}"
  CNTOOLS_MODE_COLOR=""
  CNTOOLS_VERSION="characterized"
  NETWORK_NAME="Preview"
  price_now=""
  CURRENCY="off"
  slotnum=0
  FG_BLUE=""
  FG_GREEN=""
  FG_RED=""
  FG_YELLOW=""
  FG_LBLUE=""
  FG_LGRAY=""
  NC=""

  clear() { :; }
  println() { :; }
  sqlite3() { :; }
  find() {
    cleanup_calls=$((cleanup_calls + 1))
  }
  getNodeMetrics() {
    metric_calls=$((metric_calls + 1))
  }
  getPriceInfo() {
    price_calls=$((price_calls + 1))
  }
  updateProtocolParams() {
    protocol_calls=$((protocol_calls + 1))
  }
  getEpoch() { printf '0\n'; }
  timeUntilNextEpoch() { printf '0\n'; }
  timeLeft() { printf '00:00:00\n'; }
  getSlotTipRef() { printf '0\n'; }
  slotInterval() { printf '1\n'; }

  select_opt() {
    local call_actual
    local call_expected
    local choice
    local navigation
    local option
    local option_id
    local option_index=0
    local option_kind
    local semantics
    local selected_index=-1
    local -a options=()

    for option in "$@"; do
      [[ -n "${option}" ]] && options+=("${option}")
    done
    menu_call=$((menu_call + 1))
    call_actual="${TEST_ROOT}/${case_name}.call-${menu_call}.actual"
    call_expected="${TEST_ROOT}/${case_name}.call-${menu_call}.expected"
    printf '%s\n' "${options[@]}" > "${call_actual}"
    expected_menu_options \
      "${expected_current_menu}" "${advanced}" "${blocklog}" \
      > "${call_expected}"
    diff -u "${call_expected}" "${call_actual}" ||
      fail "${case_name}: expected ${expected_current_menu} at menu call ${menu_call}"
    if (( menu_call == target_call )); then
      printf '%s\n' "${options[@]}" > "${actual_file}"
    fi

    (( choice_cursor < ${#choices[@]} )) ||
      fail "${case_name}: no scripted choice for menu call ${menu_call}"
    choice="${choices[choice_cursor]}"
    choice_cursor=$((choice_cursor + 1))
    for option in "${options[@]}"; do
      if [[ "${option}" == "[${choice}]"* ]]; then
        selected_value="${option}"
        selected_index=${option_index}
        break
      fi
      option_index=$((option_index + 1))
    done
    (( selected_index >= 0 )) ||
      fail "${case_name}: choice '${choice}' is absent at call ${menu_call}"

    semantics="$(
      jq -er \
        --arg menu_id "${expected_current_menu}" \
        --arg shortcut "${choice}" '
          .menus[] |
          select(.id == $menu_id) |
          .options[] |
          select(.shortcut == $shortcut) |
          [.kind, .id, (.navigation // "")] |
          @tsv
        ' "${MENU_FIXTURE}"
    )" || fail "${case_name}: fixture has no semantics for ${expected_current_menu}/${choice}"
    IFS=$'\t' read -r option_kind option_id navigation <<< "${semantics}"
    case "${option_kind}" in
      menu)
        expected_current_menu="${option_id}"
        ;;
      control)
        case "${navigation}" in
          exit) expected_current_menu="__exit__" ;;
          refresh-root) expected_current_menu="root" ;;
          *) expected_current_menu="${navigation}" ;;
        esac
        ;;
      action)
        fail "${case_name}: navigation harness selected action ${option_id}"
        ;;
      *)
        fail "${case_name}: unsupported fixture kind '${option_kind}'"
        ;;
    esac
    return "${selected_index}"
  }

  myExit() {
    local status="${1:-0}"
    [[ "${expected_current_menu}" == "__exit__" ]] ||
      fail "${case_name}: exited while expecting menu ${expected_current_menu}"
    (( choice_cursor == ${#choices[@]} )) ||
      fail "${case_name}: not all scripted choices were consumed"
    (( menu_call == expected_menu_calls )) ||
      fail "${case_name}: expected ${expected_menu_calls} menu calls, got ${menu_call}"
    (( cleanup_calls == expected_root_cycles )) ||
      fail "${case_name}: expected ${expected_root_cycles} root cleanups, got ${cleanup_calls}"
    case "${mode}" in
      LOCAL)
        (( metric_calls == expected_root_cycles &&
           price_calls == expected_root_cycles &&
           protocol_calls == expected_root_cycles )) ||
          fail "${case_name}: local refresh lifecycle changed"
        ;;
      LIGHT)
        (( metric_calls == 0 &&
           price_calls == expected_root_cycles &&
           protocol_calls == expected_root_cycles )) ||
          fail "${case_name}: light refresh lifecycle changed"
        ;;
      OFFLINE)
        (( metric_calls == 0 && price_calls == 0 && protocol_calls == 0 )) ||
          fail "${case_name}: offline mode unexpectedly refreshed external state"
        ;;
    esac
    exit "${status}"
  }

  main >/dev/null

  # main exits through the scripted Quit option, so this is intentionally
  # unreachable inside the traversal subshell.
  exit 99
)

assert_menu_case() {
  local case_name="$1"
  local menu_id="$2"
  local mode="$3"
  local advanced="$4"
  local blocklog="$5"
  local target_call="$6"
  local expected_menu_calls="$7"
  local expected_root_cycles="$8"
  shift 8
  local actual_file="${TEST_ROOT}/${case_name}.actual"
  local expected_file="${TEST_ROOT}/${case_name}.expected"

  run_menu_case \
    "${case_name}" "${menu_id}" "${mode}" "${advanced}" "${blocklog}" \
    "${target_call}" "${expected_menu_calls}" "${expected_root_cycles}" "$@" ||
    fail "${case_name}: legacy menu traversal failed"
  expected_menu_options "${menu_id}" "${advanced}" "${blocklog}" \
    > "${expected_file}"
  diff -u "${expected_file}" "${actual_file}" ||
    fail "${case_name}: menu options changed"
}

assert_navigation_case() {
  local case_name="$1"
  local mode="$2"
  local advanced="$3"
  local blocklog="$4"
  local expected_menu_calls="$5"
  local expected_root_cycles="$6"
  shift 6

  run_menu_case \
    "${case_name}" root "${mode}" "${advanced}" "${blocklog}" \
    0 "${expected_menu_calls}" "${expected_root_cycles}" "$@" ||
    fail "${case_name}: legacy navigation changed"
}

# Root visibility and mode invariance.
assert_menu_case root-offline root OFFLINE false false 1 1 1 q
assert_menu_case root-local root LOCAL false false 1 1 1 q
assert_menu_case root-light root LIGHT false false 1 1 1 q
assert_menu_case root-advanced root OFFLINE true false 1 1 1 q
assert_menu_case root-blocklog root OFFLINE false true 1 1 1 q
assert_menu_case root-all root OFFLINE true true 1 1 1 q

# Every structural choice point, selecting navigation controls only.
assert_menu_case wallet wallet OFFLINE false false 2 3 2 w h q
assert_menu_case wallet-new wallet.new OFFLINE false false 3 5 2 w n b h q
assert_menu_case wallet-import wallet.import OFFLINE false false 3 5 2 w i b h q
assert_menu_case funds funds OFFLINE false false 2 3 2 f h q
assert_menu_case pool pool OFFLINE false false 2 3 2 p h q
assert_menu_case transaction transaction OFFLINE false false 2 3 2 t h q
assert_menu_case vote vote OFFLINE false false 2 3 2 v h q
assert_menu_case vote-governance vote.governance OFFLINE false false 3 5 2 v g b h q
assert_menu_case vote-catalyst vote.catalyst OFFLINE false false 3 5 2 v c b h q
assert_menu_case blocks blocks OFFLINE false true 2 3 2 b Esc q
assert_menu_case backup backup OFFLINE false false 2 3 2 z Esc q
assert_menu_case advanced advanced OFFLINE true false 2 3 2 a h q
assert_menu_case advanced-asset advanced.asset OFFLINE true false 3 5 2 a a b h q
assert_menu_case advanced-multisig advanced.multisig OFFLINE true false 3 5 2 a s b h q

# Dispatcher-owned navigation semantics and Home refresh boundaries.
assert_navigation_case root-refresh-offline OFFLINE false false 2 2 r q
assert_navigation_case root-refresh-local LOCAL false false 2 2 r q
assert_navigation_case wallet-new-home OFFLINE false false 4 2 w n h q
assert_navigation_case wallet-import-home OFFLINE false false 4 2 w i h q
assert_navigation_case governance-home OFFLINE false false 4 2 v g h q
assert_navigation_case catalyst-home OFFLINE false false 4 2 v c h q
assert_navigation_case asset-home OFFLINE true false 4 2 a a h q
assert_navigation_case multisig-home OFFLINE true false 4 2 a s h q

printf 'CNTools menu characterization tests passed\n'
