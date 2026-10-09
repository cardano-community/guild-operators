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

assert_eq "$(wc -l < "${MENU_FIXTURE}" | trim_count)" "75" \
  "module inventory count"
assert_eq "$(grep -c $'\tmenu\t' "${MENU_FIXTURE}" | trim_count)" "16" \
  "menu inventory count"
assert_eq "$(grep -c $'\taction\t' "${MENU_FIXTURE}" | trim_count)" "59" \
  "action inventory count"
assert_eq "$(find "${MODULE_ROOT}" -type d -print | wc -l | trim_count)" "79" \
  "Phase 5 module directory count"
assert_eq "$(find "${MODULE_ROOT}" -type f -name module.json -print | wc -l | trim_count)" "79" \
  "Phase 5 module metadata count"
assert_eq "$(find "${MODULE_ROOT}" -type f -name action.sh -print | wc -l | trim_count)" "62" \
  "Phase 5 action entrypoint count"
assert_eq "$(find "${MODULE_ROOT}" -type f -print | wc -l | trim_count)" "141" \
  "Phase 7 module payload file count"
[[ ! -e "${MODULE_ROOT}/advanced/metadata" &&
   ! -L "${MODULE_ROOT}/advanced/metadata" ]] ||
  fail 'Standalone Advanced Metadata must remain removed; use Funds Send metadata'
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
      wallet/new/cli)
        jq -e '.libs == [
          "wallet.sh",
          "wallet-material.sh",
          "wallet-key.sh",
          "wallet-address.sh",
          "wallet-id.sh",
          "wallet-create.sh",
          "wallet-create-ui.sh"
        ]' \
          "${metadata}" >/dev/null ||
          fail "Wallet New CLI has unexpected library declarations"
        grep -F 'cntools_wallet_create_cleanup' "${action_file}" >/dev/null ||
          fail "Wallet New CLI does not clean private staging directories"
        grep -F 'cntools_wallet_cleanup_material' "${action_file}" >/dev/null ||
          fail "Wallet New CLI does not clean artifact staging files"
        grep -F 'cntools_wallet_action_new_cli' "${action_file}" >/dev/null ||
          fail "Wallet New CLI does not call its functional entrypoint"
        ;;
      wallet/new/mnemonic|wallet/import/mnemonic)
        jq -e '.libs == [
          "wallet.sh",
          "wallet-material.sh",
          "wallet-key.sh",
          "wallet-address.sh",
          "wallet-id.sh",
          "wallet-create.sh",
          "wallet-create-ui.sh",
          "wallet-mnemonic.sh",
          "wallet-mnemonic-ui.sh"
        ]' \
          "${metadata}" >/dev/null ||
          fail "Wallet Mnemonic has unexpected library declarations: ${module_id}"
        grep -F 'cntools_wallet_create_cleanup' "${action_file}" >/dev/null ||
          fail "Wallet Mnemonic does not clean private staging directories: ${module_id}"
        grep -F 'cntools_wallet_mnemonic_cleanup' "${action_file}" >/dev/null ||
          fail "Wallet Mnemonic does not clean mnemonic temporary files: ${module_id}"
        grep -F 'cntools_wallet_cleanup_material' "${action_file}" >/dev/null ||
          fail "Wallet Mnemonic does not clean artifact staging files: ${module_id}"
        if [[ "${module_id}" == "wallet/new/mnemonic" ]]; then
          grep -F 'cntools_wallet_action_new_mnemonic' "${action_file}" >/dev/null ||
            fail "Wallet New Mnemonic does not call its functional entrypoint"
        else
          grep -F 'cntools_wallet_action_import_mnemonic' "${action_file}" >/dev/null ||
            fail "Wallet Import Mnemonic does not call its functional entrypoint"
        fi
        ;;
      wallet/import/hardware)
        jq -e '.libs == [
          "wallet.sh",
          "wallet-material.sh",
          "wallet-key.sh",
          "wallet-address.sh",
          "wallet-id.sh",
          "wallet-create.sh",
          "wallet-create-ui.sh",
          "wallet-hardware.sh",
          "wallet-hardware-ui.sh"
        ]' \
          "${metadata}" >/dev/null ||
          fail "HW Wallet has unexpected library declarations"
        grep -F 'cntools_wallet_create_cleanup' "${action_file}" >/dev/null ||
          fail "HW Wallet does not clean private staging directories"
        grep -F 'cntools_wallet_cleanup_material' "${action_file}" >/dev/null ||
          fail "HW Wallet does not clean artifact staging files"
        grep -F 'cntools_wallet_action_import_hardware' "${action_file}" >/dev/null ||
          fail "HW Wallet does not call its functional entrypoint"
        ;;
      wallet/list)
        jq -e '.libs == [
          "number.sh",
          "wallet.sh",
          "wallet-material.sh",
          "wallet-key.sh",
          "wallet-address.sh",
          "wallet-id.sh",
          "asset.sh",
          "asset-cache.sh",
          "wallet-query.sh"
        ]' \
          "${metadata}" >/dev/null ||
          fail "Wallet List has unexpected library declarations"
        grep -F 'cntools_wallet_cleanup_material' "${action_file}" >/dev/null ||
          fail "Wallet List does not clean artifact staging files"
        grep -F 'cntools_wallet_action_list' "${action_file}" >/dev/null ||
          fail "Wallet List does not call its functional entrypoint"
        ;;
      wallet/show)
        jq -e '(.libs - ["pool-id.sh", "drep-id.sh", "table.sh", "public-metadata.sh", "wallet-delegation-info.sh"]) == [
          "number.sh",
          "wallet.sh",
          "wallet-material.sh",
          "wallet-key.sh",
          "wallet-address.sh",
          "wallet-id.sh",
          "asset.sh",
          "asset-cache.sh",
          "wallet-query.sh"
        ]' \
          "${metadata}" >/dev/null ||
          fail "Wallet Show has unexpected library declarations"
        grep -F 'cntools_wallet_cleanup_material' "${action_file}" >/dev/null ||
          fail "Wallet Show does not clean artifact staging files"
        grep -F 'cntools_wallet_action_show' "${action_file}" >/dev/null ||
          fail "Wallet Show does not call its functional entrypoint"
        ;;
      wallet/transactions|wallet/utxos)
        jq -e --arg id "${module_id}" '(.requiresKoios == true or ($id == "wallet/utxos" and .requiresKoios != true and (.libs | index("wallet-utxo-local.sh") != null))) and
          (.libs | index("wallet-history-ui.sh") != null)' "${metadata}" >/dev/null ||
          fail "Wallet browser is missing its source requirement or shared UI"
        grep -F 'cntools_history_action' "${action_file}" >/dev/null || fail "Wallet browser entrypoint missing"
        ;;
      wallet/remove)
        jq -e '.libs == [
          "number.sh",
          "wallet.sh",
          "wallet-material.sh",
          "wallet-key.sh",
          "wallet-address.sh",
          "wallet-id.sh",
          "asset.sh",
          "asset-cache.sh",
          "wallet-query.sh",
          "wallet-remove.sh",
          "wallet-remove-ui.sh"
        ]' \
          "${metadata}" >/dev/null ||
          fail "Wallet Remove has unexpected library declarations"
        grep -F 'cntools_wallet_query_cleanup' "${action_file}" >/dev/null ||
          fail "Wallet Remove does not clean query temporary files"
        grep -F 'cntools_wallet_cleanup_material' "${action_file}" >/dev/null ||
          fail "Wallet Remove does not clean artifact staging files"
        grep -F 'cntools_wallet_action_remove' "${action_file}" >/dev/null ||
          fail "Wallet Remove does not call its functional entrypoint"
        ;;
      wallet/encrypt|wallet/decrypt)
        jq -e '.libs == [
          "wallet.sh",
          "wallet-material.sh",
          "wallet-key.sh",
          "key-crypto.sh",
          "wallet-protection.sh",
          "wallet-protection-ui.sh"
        ]' \
          "${metadata}" >/dev/null ||
          fail "Wallet protection has unexpected library declarations: ${module_id}"
        grep -F 'cntools_wallet_protection_cleanup' "${action_file}" >/dev/null ||
          fail "Wallet protection does not clean private staging files: ${module_id}"
        if [[ "${module_id}" == "wallet/encrypt" ]]; then
          grep -F 'cntools_wallet_action_encrypt' "${action_file}" >/dev/null ||
            fail "Wallet Encrypt does not call its functional entrypoint"
        else
          grep -F 'cntools_wallet_action_decrypt' "${action_file}" >/dev/null ||
            fail "Wallet Decrypt does not call its functional entrypoint"
        fi
        ;;
      wallet/register|wallet/deregister)
        jq -e '(.libs - ["wallet-selection.sh"]) == [
          "number.sh",
          "wallet.sh",
          "table.sh",
          "wallet-material.sh",
          "wallet-key.sh",
          "wallet-address.sh",
          "wallet-id.sh",
          "asset.sh",
          "asset-cache.sh",
          "wallet-query.sh",
          "utxo.sh",
          "transaction.sh",
          "transaction-build.sh",
          "transaction-sign.sh",
          "transaction-submit.sh",
          "transaction-monitor.sh",
          "transaction-ui.sh",
          "transaction-files.sh",
          "transaction-funding.sh",
          "coin-selection.sh",
          "change-plan.sh",
          "wallet-stake.sh",
          "multisig-spend.sh",
          "multisig-stake.sh",
          "wallet-register.sh",
          "wallet-register-ui.sh"
        ]' \
          "${metadata}" >/dev/null ||
          fail "Wallet stake lifecycle action has unexpected library declarations: ${module_id}"
        grep -F 'cntools_wallet_query_cleanup' "${action_file}" >/dev/null ||
          fail "Wallet stake lifecycle action does not clean query temporary files: ${module_id}"
        grep -F 'cntools_transaction_cleanup' "${action_file}" >/dev/null ||
          fail "Wallet stake lifecycle action does not clean transaction staging files: ${module_id}"
        if [[ "${module_id}" == "wallet/register" ]]; then
          grep -F 'cntools_wallet_action_register' "${action_file}" >/dev/null ||
            fail "Wallet Register does not call its functional entrypoint"
        else
          grep -F 'cntools_wallet_action_deregister' "${action_file}" >/dev/null ||
            fail "Wallet De-Register does not call its functional entrypoint"
        fi
        ;;
      funds/collect)
        jq -e '.libs | index("funds-collect.sh") != null and index("funds-collect-ui.sh") != null and index("funds-send.sh") != null and index("placeholder.sh") == null' \
          "${metadata}" >/dev/null || fail "collection libraries missing"
        grep -F 'cntools_funds_action_collect' "${action_file}" >/dev/null || fail "collection entrypoint missing"
        grep -F 'cntools_transaction_cleanup' "${action_file}" >/dev/null || fail "collection cleanup missing"
        ;;
      advanced/multisig/create|advanced/multisig/derive-keys)
        jq -e '.libs | index("multisig-key.sh") != null and index("multisig-wallet.sh") != null and index("multisig-ui.sh") != null and index("placeholder.sh") == null' "${metadata}" >/dev/null || fail 'Multisig action dependencies missing'
        grep -F 'cntools_multisig_action_' "${action_file}" >/dev/null || fail 'Multisig action entrypoint missing'
        grep -F 'cntools_wallet_create_cleanup' "${action_file}" >/dev/null || fail 'Multisig cleanup missing'
        ;;
      advanced/asset/list|advanced/asset/show|advanced/asset/encrypt-policy|advanced/asset/decrypt-policy|advanced/asset/mint|advanced/asset/burn|advanced/asset/register)
        jq -e '.libs | index("policy-catalog.sh") != null and index("placeholder.sh") == null' "${metadata}" >/dev/null || fail 'Asset action dependencies missing'
        grep -F 'cntools_policy_files_cleanup' "${action_file}" >/dev/null || fail 'Asset action cleanup missing'
        ;;
      advanced/asset/create-policy)
        jq -e '.libs | index("policy-files.sh") != null and index("policy.sh") != null and index("policy-ui.sh") != null and index("placeholder.sh") == null' "${metadata}" >/dev/null || fail 'Policy creation dependencies missing'
        grep -F 'cntools_policy_action_create' "${action_file}" >/dev/null || fail 'Policy creation entrypoint missing'
        grep -F 'cntools_policy_files_cleanup' "${action_file}" >/dev/null || fail 'Policy creation cleanup missing'
        ;;
      pool/calidus)
        jq -e '.libs | index("pool-calidus.sh") != null and index("pool-calidus-ui.sh") != null and index("calidus-id.sh") != null and index("calidus-registration.sh") != null and index("metadata-transaction.sh") != null and index("transaction-sign.sh") != null and index("placeholder.sh") == null' "${metadata}" >/dev/null || fail 'Calidus dependencies missing'
        grep -F 'cntools_pool_action_calidus' "${action_file}" >/dev/null || fail 'Calidus entrypoint missing'
        grep -F 'cntools_calidus_publication_cleanup' "${action_file}" >/dev/null || fail 'Calidus publication cleanup missing'
        ;;
      pool/new|pool/import|pool/encrypt|pool/decrypt)
        jq -e '.libs | index("pool-files.sh") != null and index("pool-key.sh") != null and index("pool-manage-ui.sh") != null and index("placeholder.sh") == null' \
          "${metadata}" >/dev/null || fail "Pool management dependencies missing: ${module_id}"
        grep -F 'cntools_pool_action_' "${action_file}" >/dev/null || fail "Pool management entrypoint missing"
        grep -F 'cntools_transaction_cleanup' "${action_file}" >/dev/null || fail "Pool management cleanup missing"
        ;;
      pool/rotate)
        jq -e '.libs | index("pool-kes.sh") != null and index("pool-kes-ui.sh") != null and index("pool-opcert-validation.sh") != null and index("placeholder.sh") == null' "${metadata}" >/dev/null || fail "KES rotation dependencies missing"
        grep -F 'cntools_pool_action_rotate' "${action_file}" >/dev/null || fail "KES rotation entrypoint missing"
        grep -F 'cntools_kes_cleanup' "${action_file}" >/dev/null || fail "KES rotation cleanup missing"
        ;;
      pool/retire)
        jq -e '.libs | index("pool-retirement.sh") != null and index("pool-retirement-ui.sh") != null and index("pool-registration-ui.sh") != null and index("placeholder.sh") == null' "${metadata}" >/dev/null || fail 'Pool retirement dependencies missing'
        grep -F 'cntools_pool_action_retire' "${action_file}" >/dev/null || fail 'Pool retirement not wired'
        ;;
      pool/register|pool/modify)
        jq -e '.libs | index("pool-registration.sh") != null and index("pool-registration-ui.sh") != null and index("wallet-register.sh") != null and index("placeholder.sh") == null' "${metadata}" >/dev/null || fail "Pool registration dependencies missing"
        grep -F 'cntools_pool_action_registration' "${action_file}" >/dev/null || fail "Pool registration handler missing"
        grep -F 'cntools_transaction_cleanup' "${action_file}" >/dev/null || fail "Pool registration cleanup missing"
        ;;
      pool/list|pool/show)
        jq -e '(.libs - ["pool-health.sh", "public-metadata.sh"]) == ["number.sh", "wallet.sh", "wallet-query.sh", "transaction.sh", "pool-id.sh", "table.sh", "pool.sh", "pool-inspect.sh", "pool-ui.sh"]' \
          "${metadata}" >/dev/null || fail "Pool browser dependencies missing: ${module_id}"
        grep -F "cntools_pool_action_${module_id##*/}" "${action_file}" >/dev/null || fail "Pool browser entrypoint missing"
        grep -F 'cntools_transaction_cleanup' "${action_file}" >/dev/null || fail "Pool browser cleanup missing"
        ;;
      funds/delegate)
        jq -e '.libs | index("funds-delegate.sh") != null and index("funds-delegate-ui.sh") != null and index("pool-query.sh") != null and index("placeholder.sh") == null' \
          "${metadata}" >/dev/null || fail "delegation libraries missing"
        grep -F 'cntools_funds_action_delegate' "${action_file}" >/dev/null || fail "delegation entrypoint missing"
        ;;
      vote/governance/proposals|vote/governance/cast)
        if [[ "${module_id}" == vote/governance/cast ]]; then
          jq -e '.libs | index("multisig-spend.sh") != null and index("multisig-drep.sh") != null and index("drep-script.sh") != null' "${metadata}" >/dev/null || fail 'DRep voting multisig dependencies missing'
        fi
        jq -e '.libs | index("governance-proposal.sh") != null and index("governance-proposal-ui.sh") != null and index("placeholder.sh") == null' "${metadata}" >/dev/null || fail "governance proposal dependencies missing"
        grep -F 'cntools_governance_action_' "${action_file}" >/dev/null || fail "governance entrypoint missing"
        grep -F 'cntools_transaction_cleanup' "${action_file}" >/dev/null || fail "governance cleanup missing"
        ;;
      vote/governance/drep-register|vote/governance/drep-retire)
        jq -e '.libs | index("multisig-spend.sh") != null and index("multisig-drep.sh") != null and index("drep-script.sh") != null' "${metadata}" >/dev/null || fail 'DRep multisig transaction dependencies missing'
        jq -e '.libs | index("governance-drep.sh") != null and index("governance-drep-ui.sh") != null and index("wallet-payment.sh") != null and index("placeholder.sh") == null' "${metadata}" >/dev/null || fail "DRep lifecycle dependencies missing"
        grep -F 'cntools_governance_action_drep_' "${action_file}" >/dev/null || fail "DRep lifecycle entrypoint missing"
        grep -F 'cntools_transaction_cleanup' "${action_file}" >/dev/null || fail "DRep lifecycle cleanup missing"
        ;;
      vote/governance/multisig-drep)
        jq -e '.libs | index("drep-script.sh") != null and index("drep-script-ui.sh") != null and index("placeholder.sh") == null' "${metadata}" >/dev/null || fail 'Script DRep dependencies missing'
        grep -F 'cntools_drep_script_action_create' "${action_file}" >/dev/null || fail 'Script DRep entrypoint missing'
        grep -F 'cntools_drep_script_publication_cleanup' "${action_file}" >/dev/null || fail 'Script DRep publication cleanup missing'
        ;;
      vote/governance/derive-keys|vote/governance/info)
        jq -e '.libs | index("drep-key.sh") != null and index("governance-wallet-ui.sh") != null and index("placeholder.sh") == null' "${metadata}" >/dev/null || fail "governance wallet dependencies missing"
        grep -F 'cntools_governance_action_' "${action_file}" >/dev/null || fail "governance wallet entrypoint missing"
        ;;
      vote/governance/delegate)
        jq -e '.libs | index("governance-delegate.sh") != null and index("governance-delegate-ui.sh") != null and index("drep-query.sh") != null and index("placeholder.sh") == null' \
          "${metadata}" >/dev/null || fail "voting delegation libraries missing"
        grep -F 'cntools_governance_action_delegate' "${action_file}" >/dev/null || fail "voting delegation entrypoint missing"
        grep -F 'cntools_transaction_cleanup' "${action_file}" >/dev/null || fail "voting delegation cleanup missing"
        ;;
      funds/withdraw)
        jq -e '.libs | index("funds-withdraw.sh") != null and index("funds-withdraw-ui.sh") != null and index("wallet-stake.sh") != null and index("placeholder.sh") == null' \
          "${metadata}" >/dev/null || fail "withdrawal libraries missing"
        ;;
      funds/send)
        jq -e '.libs | index("funds-send.sh") != null and index("funds-send-ui.sh") != null and index("recipient.sh") != null and index("placeholder.sh") == null' \
          "${metadata}" >/dev/null || fail "Send has incorrect libraries"
        grep -F 'cntools_funds_action_send' "${action_file}" >/dev/null || fail "Send entrypoint missing"
        grep -F 'cntools_transaction_cleanup' "${action_file}" >/dev/null || fail "Send cleanup missing"
        ;;
      transaction/sign)
        jq -e '.libs == [
          "number.sh",
          "transaction.sh",
          "transaction-sign.sh",
          "transaction-ui.sh",
          "transaction-files.sh"
        ]' \
          "${metadata}" >/dev/null ||
          fail "Transaction Sign has unexpected library declarations"
        grep -F 'cntools_transaction_cleanup' "${action_file}" >/dev/null ||
          fail "Transaction Sign does not clean transaction staging files"
        grep -F 'cntools_transaction_action_sign' "${action_file}" >/dev/null ||
          fail "Transaction Sign does not call its functional entrypoint"
        ;;
      transaction/submit)
        jq -e '.libs == [
          "number.sh",
          "transaction.sh",
          "transaction-submit.sh",
          "transaction-monitor.sh",
          "transaction-ui.sh"
        ]' \
          "${metadata}" >/dev/null ||
          fail "Transaction Submit has unexpected library declarations"
        grep -F 'cntools_transaction_cleanup' "${action_file}" >/dev/null ||
          fail "Transaction Submit does not clean transaction staging files"
        grep -F 'cntools_transaction_action_submit' "${action_file}" >/dev/null ||
          fail "Transaction Submit does not call its functional entrypoint"
        ;;
      backup/create|backup/restore)
        jq -e '.libs == ["number.sh", "wallet.sh", "wallet-query.sh", "transaction.sh", "table.sh", "key-crypto.sh", "backup-files.sh", "backup.sh", "backup-ui.sh"] and .modes == ["local", "light", "offline"]' "${metadata}" >/dev/null || fail 'Backup dependencies/modes missing'
        grep -F 'cntools_backup_action_' "${action_file}" >/dev/null || fail 'Backup entrypoint missing'
        grep -F 'cntools_backup_cleanup' "${action_file}" >/dev/null || fail 'Backup cleanup missing'
        ;;
      blocks/summary|blocks/epoch)
        jq -e '.libs == ["number.sh", "wallet.sh", "wallet-query.sh", "table.sh", "blocklog.sh", "blocklog-ui.sh"] and .modes == ["local", "light", "offline"]' "${metadata}" >/dev/null || fail 'Blocks dependencies/modes missing'
        grep -F 'cntools_blocks_action' "${action_file}" >/dev/null || fail 'Blocks entrypoint missing'
        grep -F 'cntools_blocklog_cleanup' "${action_file}" >/dev/null || fail 'Blocks cleanup missing'
        ;;
      advanced/clear-asset-cache)
        jq -e '.libs == ["asset-cache.sh"]' "${metadata}" >/dev/null ||
          fail "Asset cache has unexpected library declarations"
        grep -F 'cntools_asset_cache_clear' "${action_file}" >/dev/null ||
          fail "Cache action does not clear metadata"
        ;;
      settings/theme)
        jq -e '((has("libs") | not) or .libs == [])' \
          "${metadata}" >/dev/null ||
          fail "Theme has unexpected library declarations"
        grep -F 'cntools_theme_save' "${action_file}" >/dev/null ||
          fail "Theme does not persist the selected theme"
        ;;
      settings/transaction-defaults)
        jq -e '.libs == ["number.sh"]' \
          "${metadata}" >/dev/null ||
          fail "Transaction Defaults has unexpected library declarations"
        grep -F 'cntools_settings_save' "${action_file}" >/dev/null ||
          fail "Transaction Defaults does not persist the selected policy"
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

assert_eq "${connected_only}" "21" "local/light-only action count"
assert_eq "${offline_capable}" "38" "offline-capable action count"
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
. "${CNTOOLS_ROOT}/core/theme.sh"
# shellcheck source=/dev/null
. "${CNTOOLS_ROOT}/core/gum.sh"

CNTOOLS_MODULE_ROOT="${MODULE_ROOT}"
CNTOOLS_LIB_DIR="${CNTOOLS_ROOT}/lib"
CNTOOLS_VALIDATION_BASH="bash"
CNTOOLS_MODE="local"
CNTOOLS_BACKEND="cnode"
CNTOOLS_NETWORK="preview"
CNTOOLS_KOIOS_ENABLED="Y"
CNTOOLS_KOIOS_API="https://preview.koios.rest/api/v1"
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
  "wallet funds pool transaction vote blocks backup settings update" \
  "root menu without advanced features"
cntools_menu_open "${MODULE_ROOT}/settings" ||
  fail "settings menu could not be opened without advanced mode"
assert_eq "${CNTOOLS_MENU_IDS[*]}" \
  "settings/transaction-defaults" \
  "settings menu without advanced features"

CNTOOLS_ADVANCED="Y"
cntools_menu_open "${MODULE_ROOT}" ||
  fail "root menu could not be opened with advanced mode"
assert_eq "${CNTOOLS_MENU_IDS[*]}" \
  "wallet funds pool transaction vote blocks backup settings advanced update" \
  "root menu with advanced features"
cntools_menu_open "${MODULE_ROOT}/settings" ||
  fail "settings menu could not be opened with advanced mode"
assert_eq "${CNTOOLS_MENU_IDS[*]}" \
  "settings/transaction-defaults settings/theme" \
  "settings menu with advanced features"

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

# Every operational action outside the implemented wallet slices remains a
# runnable placeholder. Settings actions are framework functionality covered
# separately.
CNTOOLS_MODE="local"
while IFS=$'\t' read -r \
  module_id kind shortcut order modes advanced label; do
  [[ "${kind}" == "action" ]] || continue
  case "${module_id}" in
    advanced/asset/*) continue ;;
    advanced/multisig/create|advanced/multisig/derive-keys) continue ;;
    vote/governance/multisig-drep) continue ;;
    backup/create|backup/restore) continue ;;
    blocks/summary|blocks/epoch) continue ;;
    pool/list|pool/show|pool/new|pool/import|pool/encrypt|pool/decrypt|pool/register|pool/modify|pool/rotate|pool/retire|pool/calidus) continue ;;
    wallet/new/cli|wallet/new/mnemonic|wallet/import/mnemonic|wallet/import/hardware|wallet/list|wallet/show|wallet/transactions|wallet/utxos|wallet/remove|wallet/encrypt|wallet/decrypt|wallet/register|wallet/deregister|funds/send|funds/withdraw|funds/delegate|funds/collect|vote/governance/delegate|vote/governance/derive-keys|vote/governance/info|vote/governance/drep-register|vote/governance/drep-retire|vote/governance/proposals|vote/governance/cast|transaction/sign|transaction/submit|settings/theme|settings/transaction-defaults|advanced/clear-asset-cache) continue ;;
  esac
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

printf 'CNTools menu skeleton tests passed\n'
