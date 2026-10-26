#!/usr/bin/env bash
# Double-confirmed exact-file deletion with explicit backup acknowledgement.
# shellcheck disable=SC2034
cntools_private_keys_workflow() {
  local scope='' encrypted=N object='' choice='' root='' index=0 acknowledgement='' folder='' feedback=''
  local -a objects=() folders=()
  local -A seen=()
  cntools_ui_choose choice 'Private keys to remove' Wallets Pools 'Asset policies' 'All categories' Cancel || return $?
  case "${choice}" in Wallets) scope=wallets; root="${CNTOOLS_WALLET_DIR}" ;; Pools) scope=pools; root="${CNTOOLS_POOL_DIR}" ;;
    'Asset policies') scope=assets; root="${CNTOOLS_ASSET_DIR}" ;; 'All categories') scope=all ;; Cancel) return 1 ;; *) return 2 ;; esac
  # Ask for an object only when there is more than one to choose from.
  if [[ "${scope}" != all ]]; then
    cntools_private_keys_objects_into objects "${root}"
    if (( ${#objects[@]} > 1 )); then
      cntools_ui_choose object 'Object scope' 'All objects' "${objects[@]}" Cancel || return $?
      [[ "${object}" != Cancel ]] || return 1
      [[ "${object}" != 'All objects' ]] || object=''
    fi
  fi
  # Ask about encrypted keys only when some exist in this scope.
  if cntools_private_keys_encrypted_present "${scope}" "${object}"; then
    cntools_ui_choose choice 'Include encrypted private keys?' 'Plaintext keys only' 'Plaintext and encrypted keys' Cancel || return $?
    [[ "${choice}" != Cancel ]] || return 1
    [[ "${choice}" != 'Plaintext and encrypted keys' ]] || encrypted=Y
  fi
  cntools_log CHOICE "Private-key deletion scope=${scope} object=${object:-all} encrypted=${encrypted}" || true
  cntools_ui_spin_function 'Validating the exact key deletion preview…' cntools_private_keys_inventory "${scope}" "${encrypted}" "${object}" || return 2
  if (( ${#CNTOOLS_PRIVATE_KEY_FILES[@]} == 0 )); then cntools_ui_render_status info 'No matching private keys were found.'; return 0; fi
  for index in "${!CNTOOLS_PRIVATE_KEY_FILES[@]}"; do
    folder="${CNTOOLS_PRIVATE_KEY_FILES[index]%/*}"; folder="${folder%/*}"
    [[ -n "${seen[${folder}]+x}" ]] || { seen["${folder}"]=Y; folders+=("${folder}"); }
  done
  while true; do
    cntools_ui_action_begin 'Delete Private Keys' '/ Advanced / Delete Private Keys'
    {
      for folder in "${folders[@]}"; do cntools_table_pair Folder "${folder}" identifier; done
      for index in "${!CNTOOLS_PRIVATE_KEY_FILES[@]}"; do
        cntools_table_pair "${CNTOOLS_PRIVATE_KEY_LABELS[index]}" "${CNTOOLS_PRIVATE_KEY_FILES[index]##*/}" warning
      done
    } | cntools_table_render 'Files to delete'
    cntools_ui_render_status warn 'This permanently unlinks only the listed keys. It does not unregister wallets, DReps or pools, move funds, or delete public keys, scripts, addresses, hardware references, KES or VRF keys. Unknown seed/private files and existing QR images are not included.'
    cntools_ui_render_status warn 'Filesystem deletion is not guaranteed secure erasure on SSDs, snapshots or backups. Signing can be recovered only from a separate valid backup or hardware device.'
    if [[ -z "${feedback}" ]]; then
      cntools_ui_confirm 'I have a separate, verified full backup of every listed key. Continue?' false || return $?
    else cntools_ui_render_status warn "${feedback}"; fi
    cntools_ui_input acknowledgement 'Type DELETE PRIVATE KEYS to confirm' 'Exact uppercase phrase · Esc cancels' || return $?
    [[ "${acknowledgement}" != 'DELETE PRIVATE KEYS' ]] || break
    feedback='Confirmation did not match; nothing was deleted. Type the exact phrase, or press Esc to cancel.'
  done
  cntools_log CHOICE "Private-key deletion confirmed scope=${scope} object=${object:-all} encrypted=${encrypted} count=${#CNTOOLS_PRIVATE_KEY_FILES[@]}" || true
  cntools_private_keys_delete "${acknowledgement}" || return 2
  {
    cntools_table_pair Status 'Listed private keys deleted · recoverable only from your separate backup' warning
    cntools_table_pair 'Keys removed' "$(cntools_number_format "${CNTOOLS_PRIVATE_KEY_REMOVED}")" number
    cntools_table_pair Retained 'Public artifacts, operational node keys and hardware references' value
  } | cntools_table_render Result
}

cntools_private_keys_action() {
  local status=0
  CNTOOLS_PRIVATE_KEY_ERROR=''
  cntools_ui_action_begin 'Delete Private Keys' '/ Advanced / Delete Private Keys'
  cntools_private_keys_workflow || status=$?
  case "${status}" in
    0) cntools_ui_wait; return 0 ;;
    1|130) cntools_log CHOICE 'Private-key deletion cancelled; nothing further was deleted' || true; return "${status}" ;;
  esac
  cntools_ui_render_status error "${CNTOOLS_PRIVATE_KEY_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-Key deletion failed.}} See ${CNTOOLS_LOG} for details."
  cntools_ui_wait
  return 1 # Shown and acknowledged above; no second failure banner.
}
