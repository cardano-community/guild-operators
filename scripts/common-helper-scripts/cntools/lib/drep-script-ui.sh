#!/usr/bin/env bash
# Threshold identity setup only. Lifecycle/signing is a separate action slice.
# shellcheck disable=SC2034
# Wallet directory of each participant ('' for external), parallel to the hashes.
declare -ag CNTOOLS_DREP_SCRIPT_SOURCES=()

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

# Wallets already added as participants, for the picker to skip.
cntools_drep_script_added_dirs_into() {
  local -n ds_added="$1"
  local ds_source=''
  ds_added=()
  for ds_source in "${CNTOOLS_DREP_SCRIPT_SOURCES[@]}"; do [[ -z "${ds_source}" ]] || ds_added+=("${ds_source}"); done
}

# True while a CNTools wallet with DRep keys is not yet a participant.
cntools_drep_script_local_available() {
  local index=0 annotation='' added_directory='' taken=N
  local -a added=()
  cntools_drep_script_added_dirs_into added
  for index in "${!CNTOOLS_WALLET_PATHS[@]}"; do
    # Whole paths only: "My Wallet" being added must not hide "My".
    taken=N
    for added_directory in "${added[@]}"; do
      [[ "${added_directory}" != "${CNTOOLS_WALLET_PATHS[index]}" ]] || { taken=Y; break; }
    done
    [[ "${taken}" == N ]] || continue
    cntools_wallet_selection_candidate_into annotation "${index}" drep-key && return 0
  done
  return 1
}

cntools_drep_script_local_participant() {
  local selected='' directory='' status=0
  cntools_wallet_catalog_build || return 2
  cntools_drep_script_added_dirs_into CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS
  cntools_wallet_choose selected Cancel drep-key || status=$?
  CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS=()
  ((status == 0)) || return "${status}"
  directory="${CNTOOLS_WALLET_PATHS[selected]}"
  cntools_drep_key_inspect "${directory}" || return 2
  [[ "${CNTOOLS_DREP_KEY_KIND}" == key && "${CNTOOLS_DREP_KEY_VERIFIED}" == Y ]] ||
    { cntools_drep_script_fail 'Select a wallet with a verified DRep key identity, not another script DRep.'; return 2; }
  cntools_drep_script_participant_add "${CNTOOLS_DREP_KEY_HASH}" "${directory##*/}" || return 2
  CNTOOLS_DREP_SCRIPT_SOURCES+=("${directory}")
}

cntools_drep_script_external_participant() {
  local choice='' entered='' hash='' id='' kind=''
  cntools_ui_choose choice 'External DRep participant' 'Verification key file' 'DRep ID or key hash' Cancel || return $?
  case "${choice}" in
    'Verification key file')
      cntools_ui_pick_path entered 'DRep verification key file' 'Choose a public verification key, not a signing key.' || return $?
      cntools_drep_script_vkey_hash_into hash "${entered}" || return 2
      ;;
    'DRep ID or key hash')
      cntools_ui_input entered 'Key DRep ID (drep1…) or signing-key credential hash (56 hex)' '' || return $?
      entered="${entered//[[:space:]]/}"
      if [[ "${entered}" == drep* ]]; then
        # A key DRep ID carries the credential hash; a script DRep cannot sign.
        cntools_drep_id_into id kind hash "${entered}" || { cntools_drep_script_fail 'That DRep ID is not valid. Check it and try again.'; return 2; }
        [[ "${kind}" == key ]] || { cntools_drep_script_fail 'That is a script or predefined DRep ID. Add a key-based DRep instead.'; return 2; }
      else
        hash="${entered}"
      fi
      ;;
    *) return 1 ;;
  esac
  cntools_drep_script_participant_add "${hash}" "External $((${#CNTOOLS_DREP_SCRIPT_HASHES[@]}+1))" || return 2
  CNTOOLS_DREP_SCRIPT_SOURCES+=('')
}

# The participant menu; returns 0 on Done, 1/130 on Cancel/Esc/Ctrl+C.
cntools_drep_script_participants_edit() {
  local pe_wallet="$1" pe_choice='' pe_status=0
  local -a pe_choices=()
  while true; do
    cntools_drep_script_begin
    # After the begin, which clears the screen; until the first participant.
    ((${#CNTOOLS_DREP_SCRIPT_HASHES[@]} > 0)) ||
      cntools_ui_render_status info "Add a separate public DRep script to ${pe_wallet}. Payment/stake keys stay unchanged; participant private keys are never copied."
    cntools_drep_script_render_participants || return 2
    # Offered while a CNTools wallet with DRep keys is not yet included.
    pe_choices=('Add external participant')
    ! cntools_drep_script_local_available || pe_choices=('Add CNTools DRep keys' "${pe_choices[@]}")
    ((${#CNTOOLS_DREP_SCRIPT_HASHES[@]} == 0)) || pe_choices+=('Remove last participant' Done)
    cntools_ui_choose pe_choice Participants "${pe_choices[@]}" Cancel || return $?
    cntools_log CHOICE "Script DRep participant menu selected=${pe_choice}" || true
    pe_status=0
    case "${pe_choice}" in
      'Add CNTools DRep keys') cntools_drep_script_local_participant || pe_status=$? ;;
      'Add external participant') cntools_drep_script_external_participant || pe_status=$? ;;
      'Remove last participant') unset 'CNTOOLS_DREP_SCRIPT_HASHES[-1]' 'CNTOOLS_DREP_SCRIPT_LABELS[-1]' 'CNTOOLS_DREP_SCRIPT_SOURCES[-1]' ;;
      Done) return 0 ;;
      *) return 1 ;;
    esac
    # Esc and "no suitable wallet" (3, already explained) return to this menu.
    ((pe_status != 130)) || return 130
    if ((pe_status != 0 && pe_status != 1 && pe_status != 3)); then
      # Repeated under the next header until the menu is answered.
      cntools_ui_render_status warn "${CNTOOLS_DREP_KEY_ERROR:-That DRep participant could not be validated.}"
    fi
    CNTOOLS_DREP_KEY_ERROR=''
  done
}

# Required signatures; Enter keeps the default (the current threshold, else
# all participants). Esc returns 1.
cntools_drep_script_threshold_into() {
  local dt_output="$1" dt_default="${2:-}" dt_count="${#CNTOOLS_DREP_SCRIPT_HASHES[@]}" dt_entered='' dt_normalized=''
  [[ "${dt_default}" =~ ^[1-9][0-9]?$ ]] && ((dt_default <= dt_count)) || dt_default="${dt_count}"
  while true; do
    cntools_ui_input dt_entered "Required signatures (1–${dt_count}; Enter uses ${dt_default})" "${dt_default}" || return $?
    dt_entered="${dt_entered:-${dt_default}}"
    if cntools_number_normalize_into dt_normalized "${dt_entered}" && [[ "${dt_normalized}" =~ ^[1-9][0-9]?$ ]] && ((dt_normalized <= dt_count)); then
      printf -v "${dt_output}" '%s' "${dt_normalized}"
      return 0
    fi
    cntools_ui_render_status warn 'Choose at least one signature and no more than the participant count.'
  done
}

cntools_drep_script_workflow() {
  local directory='' wallet='' choice='' threshold='' entered='' note='' status=0
  local -a choices=() saved_hashes=() saved_labels=() saved_sources=()
  CNTOOLS_DREP_SCRIPT_HASHES=(); CNTOOLS_DREP_SCRIPT_LABELS=(); CNTOOLS_DREP_SCRIPT_SOURCES=()
  cntools_governance_wallet_select_into directory 'MultiSig DRep' drep-script-create || return $?
  wallet="${directory##*/}"
  cntools_drep_script_preflight "${directory}" && cntools_transaction_require_cli || return 2
  # Participants, then the threshold (Esc returns to the participants), then
  # (Detailed) a review that can change either; Esc in a review change keeps
  # the reviewed participants and threshold.
  while true; do
    cntools_drep_script_participants_edit "${wallet}" || return $?
    note=''
    if ((${#CNTOOLS_DREP_SCRIPT_HASHES[@]} == 1)); then
      # One participant can only require one signature.
      threshold=1 note='One participant, so one signature is required.'
      cntools_log CHOICE 'Script DRep threshold auto=1 participants=1' || true
    else
      status=0
      cntools_drep_script_threshold_into threshold "${threshold}" || status=$?
      ((status == 1)) && continue
      ((status == 0)) || return "${status}"
    fi
    break
  done
  # Quick creates at once (the result says what to back up).
  if ! cntools_flow_quick; then
    choice=''
    while true; do
      cntools_drep_script_begin
      cntools_drep_script_render_participants || return 2
      { cntools_table_pair Wallet "${wallet}" identifier; cntools_table_pair Threshold "${threshold} of ${#CNTOOLS_DREP_SCRIPT_HASHES[@]}" number; } |
        cntools_table_render 'DRep identity' || return 2
      [[ -z "${note}" ]] || cntools_ui_render_status info "${note}"
      cntools_ui_render_status warn 'The participants and threshold permanently define this DRep ID. This creates the identity only; register it through DRep Registration / Update.'
      choices=('Create this DRep identity')
      ((${#CNTOOLS_DREP_SCRIPT_HASHES[@]} == 1)) || choices+=('Change threshold')
      choices+=('Change participants' Cancel)
      cntools_ui_choose choice 'Review DRep identity' "${choices[@]}" || return $?
      cntools_log CHOICE "Script DRep review choice=${choice}" || true
      case "${choice}" in
        'Change threshold')
          # Esc keeps the reviewed threshold.
          status=0
          cntools_drep_script_threshold_into entered "${threshold}" || status=$?
          ((status <= 1)) || return "${status}"
          ((status != 0)) || threshold="${entered}" ;;
        'Change participants')
          saved_hashes=("${CNTOOLS_DREP_SCRIPT_HASHES[@]}") saved_labels=("${CNTOOLS_DREP_SCRIPT_LABELS[@]}")
          saved_sources=("${CNTOOLS_DREP_SCRIPT_SOURCES[@]}")
          status=0; cntools_drep_script_participants_edit "${wallet}" || status=$?
          # A changed participant list asks the threshold again.
          if ((status == 0)); then
            if ((${#CNTOOLS_DREP_SCRIPT_HASHES[@]} == 1)); then
              threshold=1 note='One participant, so one signature is required.'
            else
              cntools_drep_script_threshold_into entered "${threshold}" || status=$?
              ((status != 0)) || threshold="${entered}" note=''
            fi
          fi
          if ((status == 1)); then
            CNTOOLS_DREP_SCRIPT_HASHES=("${saved_hashes[@]}") CNTOOLS_DREP_SCRIPT_LABELS=("${saved_labels[@]}")
            CNTOOLS_DREP_SCRIPT_SOURCES=("${saved_sources[@]}")
            cntools_log CHOICE 'Script DRep participant change cancelled; reviewed participants kept' || true
          elif ((status != 0)); then
            return "${status}"
          fi ;;
        'Create this DRep identity') break ;;
        *) return 1 ;;
      esac
    done
  fi
  cntools_log CHOICE "Script DRep creation confirmed wallet=${wallet} threshold=${threshold} participants=${#CNTOOLS_DREP_SCRIPT_HASHES[@]}" || true
  cntools_drep_script_create "${directory}" "${threshold}" && cntools_drep_key_inspect "${directory}" || return 2
  cntools_drep_script_begin
  {
    cntools_table_pair Wallet "${wallet}" identifier
    cntools_table_pair 'DRep ID' "${CNTOOLS_DREP_KEY_ID}" identifier
    cntools_table_pair Threshold "${threshold} of ${#CNTOOLS_DREP_SCRIPT_HASHES[@]}" number
    cntools_table_pair 'Saved in' "${directory}" identifier
  } | cntools_table_render 'DRep identity' || return 2
  cntools_ui_render_status success "DRep script and ID saved in ${wallet}. No transaction was made. The participants and threshold permanently define this ID: back up both public files and keep each participant signing key separately protected. Register it through DRep Registration / Update."
}

cntools_drep_script_action_create() {
  local status=0
  CNTOOLS_DREP_KEY_ERROR=''
  cntools_drep_script_workflow || status=$?
  # Cancel returns straight to the menu: nothing is saved before the confirm.
  if ((status == 1 || status == 130)); then cntools_log CHOICE 'Script DRep creation cancelled' || true; return "${status}"; fi
  ((status != 3)) || return 0
  ((status == 0)) || cntools_ui_render_status error "${CNTOOLS_DREP_KEY_ERROR:-DRep script creation failed.} See ${CNTOOLS_LOG} for details."
  cntools_ui_wait
  # A shown and acknowledged failure needs no menu banner.
  ((status == 0)) || return 1
}
