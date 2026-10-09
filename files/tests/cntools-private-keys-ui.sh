#!/usr/bin/env bash
# Cancellation, preview and explicit backup acknowledgement before key deletion.
# shellcheck disable=SC1090,SC2034,SC2030,SC2031,SC2329,SC2154
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/scripts/common-helper-scripts/cntools/lib/private-keys-ui.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cntools_ui_action_begin() { :; }
cntools_ui_render_status() { :; }
cntools_ui_wait() { :; }
cntools_log() { :; }
cntools_table_pair() { :; }
cntools_table_render() { while IFS= read -r _line; do :; done; }
cntools_number_format() { printf '%s' "$1"; }
cntools_ui_spin_function() { shift; "$@"; }
CNTOOLS_LOG=/logs/cntools.log CNTOOLS_TRANSACTION_ERROR=''
for scenario in cancel-scope cancel-encrypted decline wrong-phrase confirm failed empty; do
  (
    choices=0 inventories=0 deleted=0 confirmations=0
    cntools_ui_choose() {
      choices=$((choices+1))
      if ((choices == 1)); then
        [[ "${scenario}" != cancel-scope ]] || { printf -v "$1" Cancel; return; }
        printf -v "$1" 'All categories'
      else
        [[ "${scenario}" != cancel-encrypted ]] || { printf -v "$1" Cancel; return; }
        printf -v "$1" 'Plaintext and encrypted keys'
      fi
    }
    cntools_private_keys_inventory() {
      [[ "$1" == all && "$2" == Y ]] || fail 'wrong scope/encrypted choice'
      inventories=$((inventories+1)); CNTOOLS_PRIVATE_KEY_FILES=(/wallets/Example/payment.skey); CNTOOLS_PRIVATE_KEY_LABELS=(Payment)
      [[ "${scenario}" != empty ]] || CNTOOLS_PRIVATE_KEY_FILES=()
    }
    cntools_ui_confirm() { [[ "$1" == *'verified full backup'* && "$2" == false ]] || fail 'unsafe backup confirmation'; confirmations=$((confirmations+1)); [[ "${scenario}" != decline ]]; }
    cntools_ui_input() { if [[ "${scenario}" == wrong-phrase ]]; then printf -v "$1" wrong; else printf -v "$1" 'DELETE PRIVATE KEYS'; fi; }
    cntools_private_keys_delete() { [[ "$1" == 'DELETE PRIVATE KEYS' ]] || fail 'missing typed confirmation'; deleted=$((deleted+1)); CNTOOLS_PRIVATE_KEY_REMOVED=1; [[ "${scenario}" != failed ]]; }
    status=0; cntools_private_keys_action || status=$?
    case "${scenario}" in
      confirm) [[ "${deleted}" == 1 && "${confirmations}" == 1 && "${status}" == 0 ]] || fail 'confirmed deletion flow' ;;
      failed) [[ "${deleted}" == 1 && "${status}" != 0 ]] || fail 'failure swallowed' ;;
      *) [[ "${deleted}" == 0 && "${status}" == 0 ]] || fail "writes during ${scenario}" ;;
    esac
  )
done
printf 'CNTools private-key deletion interaction tests passed\n'
