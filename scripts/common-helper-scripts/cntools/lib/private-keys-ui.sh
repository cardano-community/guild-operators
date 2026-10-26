#!/usr/bin/env bash
# Double-confirmed exact-file deletion with explicit backup acknowledgement.
# shellcheck disable=SC2034

# "1 key file" / "N key files".
cntools_private_keys_count_label() {
  printf '%s key file' "$(cntools_number_format "$1")"; (( $1 == 1 )) || printf s
}

cntools_private_keys_workflow() {
  local scope='' encrypted=N object='' choice='' role='' index=0 acknowledgement='' folder='' feedback='' total=0 count=0 label='' plain_count=0 encrypted_count=0
  local -a objects=() counts=() folders=() scopes=() rows=()
  local -A seen=()
  # Offer only categories and objects that hold deletable key files.
  for role in wallets pools assets; do
    cntools_private_keys_objects_into objects counts "${role}" ||
      { cntools_private_keys_fail 'The configured private-key file names are unsafe. No keys were deleted.'; return 2; }
    count=0; for index in "${!counts[@]}"; do count=$((count + counts[index])); done
    (( count > 0 )) || continue
    case "${role}" in wallets) label=Wallets ;; pools) label=Pools ;; *) label='Asset policies' ;; esac
    scopes+=("${role}"); rows+=("${label} · $(cntools_private_keys_count_label "${count}")"); total=$((total + count))
  done
  if (( ${#scopes[@]} == 0 )); then
    cntools_ui_render_status info 'No wallet, pool or asset policy has a private key file to delete.'
    cntools_ui_wait
    return 3
  fi
  if (( ${#scopes[@]} == 1 )); then
    scope="${scopes[0]}"
    cntools_log CHOICE "Private-key deletion category auto-selected=${scope}" || true
  else
    scopes+=(all); rows+=("All categories · $(cntools_private_keys_count_label "${total}")")
    cntools_ui_choose choice 'Private keys to remove' "${rows[@]}" Cancel || return $?
    [[ "${choice}" != Cancel ]] || return 1
    for index in "${!rows[@]}"; do [[ "${rows[index]}" != "${choice}" ]] || scope="${scopes[index]}"; done
    [[ -n "${scope}" ]] || return 2
  fi
  # Ask for an object only when there is more than one to choose from.
  if [[ "${scope}" != all ]]; then
    cntools_private_keys_objects_into objects counts "${scope}" || return 2
    if (( ${#objects[@]} > 1 )); then
      rows=('All objects')
      for index in "${!objects[@]}"; do rows+=("${objects[index]} · $(cntools_private_keys_count_label "${counts[index]}")"); done
      cntools_ui_choose choice 'Object scope' "${rows[@]}" Cancel || return $?
      [[ "${choice}" != Cancel ]] || return 1
      [[ "${choice}" == 'All objects' ]] || object="${choice%% · *}"
    fi
  fi
  # Ask about encrypted keys only when both forms exist in this scope; with
  # encrypted keys only, those are the keys to delete.
  cntools_private_keys_form_counts_into plain_count encrypted_count "${scope}" "${object}" || {
    cntools_private_keys_fail 'The configured private-key file names are unsafe. No keys were deleted.'; return 2; }
  if (( encrypted_count > 0 && plain_count == 0 )); then
    encrypted=Y
  elif (( encrypted_count > 0 )); then
    cntools_ui_choose choice 'Include encrypted private keys?' \
      "Plaintext keys only · $(cntools_private_keys_count_label "${plain_count}")" \
      "Plaintext and encrypted keys · $(cntools_private_keys_count_label "$((plain_count + encrypted_count))")" Cancel || return $?
    [[ "${choice}" != Cancel ]] || return 1
    [[ "${choice}" != 'Plaintext and encrypted keys · '* ]] || encrypted=Y
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
  cntools_ui_action_begin 'Delete Private Keys' '/ Advanced / Delete Private Keys'
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
    3) return 0 ;; # Nothing to delete; the reason was shown and acknowledged.
    1|130) cntools_log CHOICE 'Private-key deletion cancelled; nothing further was deleted' || true; return "${status}" ;;
  esac
  cntools_ui_render_status error "${CNTOOLS_PRIVATE_KEY_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-Key deletion failed.}} See ${CNTOOLS_LOG} for details."
  cntools_ui_wait
  return 1 # Shown and acknowledged above; no second failure banner.
}
