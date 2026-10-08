#!/usr/bin/env bash
# Threshold identity setup only. Lifecycle/signing is a separate action slice.
# shellcheck disable=SC2034
cntools_drep_script_begin() {
  cntools_gum_clear
  cntools_ui_action_begin 'MultiSig DRep' '/ Vote / Governance / MultiSig DRep'
}

cntools_drep_script_render_participants() {
  local index=0
  {
    for index in "${!CNTOOLS_DREP_SCRIPT_HASHES[@]}"; do
      cntools_table_pair "$((index+1)) · Participant" "${CNTOOLS_DREP_SCRIPT_LABELS[index]}" identifier
      cntools_table_pair 'Signing key hash' "${CNTOOLS_DREP_SCRIPT_HASHES[index]}" identifier
    done
  } | cntools_table_render Participants
}

cntools_drep_script_local_participant() {
  local selected='' directory=''
  cntools_wallet_catalog_build && cntools_wallet_choose selected Cancel || return $?
  directory="${CNTOOLS_WALLET_PATHS[selected]}"
  cntools_drep_key_inspect "${directory}" || return 2
  [[ "${CNTOOLS_DREP_KEY_KIND}" == key && "${CNTOOLS_DREP_KEY_VERIFIED}" == Y ]] ||
    { cntools_drep_script_fail 'Select a wallet with a verified DRep key identity, not another script DRep.'; return 2; }
  cntools_drep_script_participant_add "${CNTOOLS_DREP_KEY_HASH}" "${directory##*/}"
}

cntools_drep_script_external_participant() {
  local choice='' entered='' hash=''
  cntools_ui_choose choice 'External DRep participant' 'Verification key file' 'Signing key hash' Cancel || return $?
  case "${choice}" in
    'Verification key file')
      cntools_ui_input entered 'DRep verification key file (not a signing key)' '' || return $?
      cntools_drep_script_vkey_hash_into hash "${entered}" || return 2
      ;;
    'Signing key hash') cntools_ui_input hash 'DRep signing-key credential hash (56 hex characters, not a script hash)' '' || return $? ;;
    *) return 1 ;;
  esac
  cntools_drep_script_participant_add "${hash}" "External $((${#CNTOOLS_DREP_SCRIPT_HASHES[@]}+1))"
}

cntools_drep_script_workflow() {
  local directory='' choice='' threshold='' normalized='' status=0
  CNTOOLS_DREP_SCRIPT_HASHES=(); CNTOOLS_DREP_SCRIPT_LABELS=()
  cntools_governance_wallet_select_into directory 'MultiSig DRep' || return $?
  cntools_drep_script_preflight "${directory}" && cntools_transaction_require_cli || return 2
  cntools_ui_render_status info 'Add a separate public DRep script to this wallet. Payment/stake keys stay unchanged; participant private keys are never copied.'
  while true; do
    cntools_drep_script_begin
    cntools_drep_script_render_participants || return 2
    cntools_ui_choose choice Participants 'Add CNTools DRep keys' 'Add external participant' 'Remove last participant' Done Cancel || return $?
    cntools_log CHOICE "Script DRep participant menu selected=${choice}" || true
    status=0
    case "${choice}" in
      'Add CNTools DRep keys') cntools_drep_script_local_participant || status=$? ;;
      'Add external participant') cntools_drep_script_external_participant || status=$? ;;
      'Remove last participant')
        if ((${#CNTOOLS_DREP_SCRIPT_HASHES[@]} > 0)); then unset 'CNTOOLS_DREP_SCRIPT_HASHES[-1]' 'CNTOOLS_DREP_SCRIPT_LABELS[-1]'; fi ;;
      Done)
        ((${#CNTOOLS_DREP_SCRIPT_HASHES[@]} > 0)) && break
        cntools_ui_render_status warn 'Add at least one participant first.'; cntools_ui_wait ;;
      *) return 1 ;;
    esac
    if ((status != 0 && status != 1 && status != 130)); then
      cntools_ui_render_status warn "${CNTOOLS_DREP_KEY_ERROR:-That DRep participant could not be validated.}"; cntools_ui_wait
    fi
  done
  while true; do
    cntools_ui_input threshold "Required signatures (default: ${#CNTOOLS_DREP_SCRIPT_HASHES[@]})" "${#CNTOOLS_DREP_SCRIPT_HASHES[@]}" || return $?
    [[ -n "${threshold}" ]] || threshold="${#CNTOOLS_DREP_SCRIPT_HASHES[@]}"
    if cntools_number_normalize_into normalized "${threshold}" && [[ "${normalized}" =~ ^[1-9][0-9]?$ ]] && ((normalized<=${#CNTOOLS_DREP_SCRIPT_HASHES[@]})); then threshold="${normalized}"; break; fi
    cntools_ui_render_status warn 'Choose at least one signature and no more than the participant count.'
  done
  cntools_drep_script_begin
  cntools_drep_script_render_participants || return 2
  { cntools_table_pair Wallet "${directory##*/}" identifier; cntools_table_pair Threshold "${threshold} of ${#CNTOOLS_DREP_SCRIPT_HASHES[@]}" number; } |
    cntools_table_render 'DRep identity' || return 2
  cntools_ui_render_status warn 'The participants and threshold permanently define this DRep ID. Keep their signing keys backed up. This creates an identity only; registration and voting with a script DRep are not enabled yet.'
  cntools_ui_confirm 'Create this public DRep identity without replacing existing files?' false || return $?
  cntools_log CHOICE "Script DRep creation confirmed wallet=${directory##*/} threshold=${threshold} participants=${#CNTOOLS_DREP_SCRIPT_HASHES[@]}" || true
  cntools_drep_script_create "${directory}" "${threshold}" && cntools_drep_key_inspect "${directory}" || return 2
  cntools_drep_script_begin
  {
    cntools_table_pair Wallet "${directory##*/}" identifier
    cntools_table_pair 'DRep ID' "${CNTOOLS_DREP_KEY_ID}" identifier
    cntools_table_pair Threshold "${threshold} of ${#CNTOOLS_DREP_SCRIPT_HASHES[@]}" number
    cntools_table_pair 'Saved in' "${directory}" identifier
  } | cntools_table_render 'DRep identity' || return 2
  cntools_ui_render_status success 'DRep script and ID saved. No transaction was made. Back up both public files and keep each participant signing key separately protected.'
}

cntools_drep_script_action_create() {
  local status=0
  CNTOOLS_DREP_KEY_ERROR=''
  cntools_drep_script_workflow || status=$?
  if ((status == 1 || status == 130)); then cntools_log CHOICE 'Script DRep creation cancelled' || true
  elif ((status != 0)); then cntools_ui_render_status error "${CNTOOLS_DREP_KEY_ERROR:-DRep script creation failed.} See ${CNTOOLS_LOG} for details."; fi
  cntools_ui_wait
  ((status == 0 || status == 1 || status == 130))
}
