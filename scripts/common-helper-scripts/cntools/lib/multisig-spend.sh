#!/usr/bin/env bash
# Native-script spending adapter for Send/Collect. Selected public identities
# are fixed before building; signature collection uses ordinary tx packages.
# shellcheck disable=SC2034
CNTOOLS_MULTISIG_SPEND_SCRIPT='' CNTOOLS_MULTISIG_SPEND_AFTER='' CNTOOLS_MULTISIG_SPEND_BEFORE=''
CNTOOLS_MULTISIG_SPEND_THRESHOLD=0 CNTOOLS_MULTISIG_CAN_SIGN=N
CNTOOLS_MULTISIG_SELECTION_ROLE=payment CNTOOLS_MULTISIG_CANDIDATE_LAST=''
# Y once a signer menu offered a real choice: the review then offers 'Change signers'.
CNTOOLS_MULTISIG_SIGNERS_CHOICE=N
declare -ag CNTOOLS_MULTISIG_CANDIDATE_IDS=() CNTOOLS_MULTISIG_CANDIDATE_HASHES=() CNTOOLS_MULTISIG_CANDIDATE_SOURCES=() CNTOOLS_MULTISIG_CANDIDATE_LABELS=()
declare -ag CNTOOLS_MULTISIG_SIGNER_IDS=() CNTOOLS_MULTISIG_SIGNER_HASHES=() CNTOOLS_MULTISIG_SIGNER_SOURCES=() CNTOOLS_MULTISIG_SIGNER_LABELS=()

cntools_multisig_script_threshold_into() {
  local -n ms_threshold_result="$1"
  ms_threshold_result="$(jq -er '
    def peel:
      if .type=="atLeast" and .required>=1 and (.scripts|length<=20 and all(.[];.type=="sig"))
        and ([.scripts[].keyHash|ascii_downcase]|length==(unique|length)) then .
      elif .type=="all" and ([.scripts[]|select(.type!="before" and .type!="after")]|length)==1
        then [.scripts[]|select(.type!="before" and .type!="after")][0]|peel
      else error("unsupported script branch") end;
    peel as $t | [..|objects|select(.type=="after")|.slot] as $after |
    [..|objects|select(.type=="before")|.slot] as $before |
    [$t.required,($after|max//""),($before|min//"")]|map(tostring)|join("\u001f")
  ' "$2")" || {
    cntools_transaction_set_error 'This native script needs an unsupported branch-selection workflow. Use distinct signature-threshold participants with optional mandatory timelocks.'; return 1;
  }
}

cntools_multisig_spend_prepare() {
  local directory="$1" script='' stake_script='' errors='' output='' address='' credential='' bounds=''
  local -a network=() arguments=()
  cntools_transaction_snapshot_into script "${directory}/${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}" 65536 multisig-payment-script || return 1
  cntools_transaction_native_script_valid "${script}" || return 1
  # Keep branch selection explicit: only signature thresholds optionally
  # wrapped in mandatory timelocks are handled by this first wallet slice.
  cntools_multisig_script_threshold_into bounds "${script}" || return 1
  IFS=$'\037' read -r CNTOOLS_MULTISIG_SPEND_THRESHOLD CNTOOLS_MULTISIG_SPEND_AFTER CNTOOLS_MULTISIG_SPEND_BEFORE <<< "${bounds}"
  CNTOOLS_MULTISIG_SPEND_SCRIPT="${script}"
  CNTOOLS_MULTISIG_SIGNER_IDS=(); CNTOOLS_MULTISIG_SIGNER_HASHES=(); CNTOOLS_MULTISIG_SIGNER_SOURCES=(); CNTOOLS_MULTISIG_SIGNER_LABELS=()
  CNTOOLS_MULTISIG_CAN_SIGN=N CNTOOLS_MULTISIG_SIGNERS_CHOICE=N
  cntools_wallet_read_address "${directory}" payment CNTOOLS_PAYMENT_PAYMENT || return 1
  CNTOOLS_PAYMENT_ADDRESS="${CNTOOLS_PAYMENT_PAYMENT}"
  if cntools_wallet_read_address "${directory}" base address; then
    CNTOOLS_PAYMENT_ADDRESS="${address}"
  elif [[ -e "${directory}/${CNTOOLS_WALLET_BASE_ADDR_FILENAME}" || -L "${directory}/${CNTOOLS_WALLET_BASE_ADDR_FILENAME}" ]]; then
    cntools_transaction_set_error 'The cached multisig base address is invalid.'; return 1
  fi
  cntools_transaction_temp_file errors multisig-address-errors && cntools_transaction_temp_file output multisig-address || return 1
  cntools_transaction_network_arguments_into network "${CNTOOLS_NETWORK}" || return 1
  arguments=(--payment-script-file "${script}")
  cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" address build "${arguments[@]}" "${network[@]}" || return 1
  address="$(< "${output}")"
  [[ "${address}" == "${CNTOOLS_PAYMENT_PAYMENT}" ]] || {
    cntools_transaction_set_error 'The cached payment address does not match the frozen multisig script.'; return 1;
  }
  if [[ "${CNTOOLS_PAYMENT_ADDRESS}" != "${CNTOOLS_PAYMENT_PAYMENT}" ]]; then
    cntools_transaction_snapshot_into stake_script "${directory}/${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}" 65536 multisig-stake-script &&
      cntools_transaction_native_script_valid "${stake_script}" || return 1
    arguments+=(--stake-script-file "${stake_script}")
    cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" address build "${arguments[@]}" "${network[@]}" || return 1
    address="$(< "${output}")"
    [[ "${address}" == "${CNTOOLS_PAYMENT_ADDRESS}" ]] || {
      cntools_transaction_set_error 'The cached base address does not match the frozen multisig scripts.'; return 1;
    }
  fi
  cntools_transaction_native_script_hash_into credential "${script}" || return 1
  CNTOOLS_PAYMENT_CREDENTIAL="${credential}" CNTOOLS_PAYMENT_VKEY='' CNTOOLS_PAYMENT_SOURCE=''
  CNTOOLS_PAYMENT_DIRECTORY="${directory}" CNTOOLS_PAYMENT_WALLET="${directory##*/}"
}

cntools_multisig_candidate_add() {
  local verification="$1" source="$2" label="$3" id='' hash='' kind='' known=''
  cntools_wallet_key_validate "${verification}" "${CNTOOLS_MULTISIG_SELECTION_ROLE:-payment}" any || return 1
  cntools_transaction_key_id_from_verification_file_into id "${verification}" &&
    cntools_transaction_credential_from_key_id_into hash "${id}" || return 1
  jq -e --arg h "${hash}" 'any(..|objects; .type=="sig" and (.keyHash|ascii_downcase)==$h)' "${CNTOOLS_MULTISIG_SPEND_SCRIPT}" >/dev/null || return 1
  # CANDIDATE_LAST is the index of this key, whether new or already listed.
  for CNTOOLS_MULTISIG_CANDIDATE_LAST in "${!CNTOOLS_MULTISIG_CANDIDATE_IDS[@]}"; do
    [[ "${CNTOOLS_MULTISIG_CANDIDATE_IDS[CNTOOLS_MULTISIG_CANDIDATE_LAST]}" != "${id}" ]] || return 0
  done
  CNTOOLS_MULTISIG_CANDIDATE_LAST="${#CNTOOLS_MULTISIG_CANDIDATE_IDS[@]}"
  if [[ -n "${source}" ]]; then
    cntools_transaction_source_kind_into kind "${source}" || source=''
    if [[ -n "${source}" ]]; then
      cntools_transaction_source_key_id_into known "${source}" "${kind}" || return 1
      [[ "${known}" == "${id}" ]] || { cntools_transaction_set_error 'A participant signing source does not match its public key.'; return 1; }
    fi
  fi
  CNTOOLS_MULTISIG_CANDIDATE_IDS+=("${id}"); CNTOOLS_MULTISIG_CANDIDATE_HASHES+=("${hash}")
  CNTOOLS_MULTISIG_CANDIDATE_SOURCES+=("${source}"); CNTOOLS_MULTISIG_CANDIDATE_LABELS+=("${label}")
}

cntools_multisig_candidates_load() {
  local directory='' prefix='' source='' verification='' role="${CNTOOLS_MULTISIG_SELECTION_ROLE:-payment}" label=''
  local vkey="${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" skey="${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" hws="${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}"
  if [[ "${role}" == stake ]]; then
    vkey="${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"; skey="${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}"; hws="${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}"
  fi
  if [[ "${role}" == drep ]]; then
    vkey="${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}"; skey="${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}"; hws="${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}"
  fi
  label="${role}"; [[ "${role}" != drep ]] || label=DRep
  CNTOOLS_MULTISIG_CANDIDATE_IDS=(); CNTOOLS_MULTISIG_CANDIDATE_HASHES=(); CNTOOLS_MULTISIG_CANDIDATE_SOURCES=(); CNTOOLS_MULTISIG_CANDIDATE_LABELS=()
  cntools_wallet_catalog_build || return 1
  for directory in "${CNTOOLS_WALLET_PATHS[@]}"; do
    for prefix in "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}" ''; do
      [[ "${role}" != drep || -z "${prefix}" ]] || continue
      verification="${directory}/${prefix}${vkey}"
      [[ -f "${verification}" && ! -L "${verification}" ]] || continue
      source="${directory}/${prefix}${skey}"
      if [[ ! -f "${source}" ]]; then source="${directory}/${prefix}${hws}"; fi
      [[ -f "${source}" ]] || source=''
      cntools_multisig_candidate_add "${verification}" "${source}" "${directory##*/} · ${prefix:+multisig }${label} key" || true
    done
  done
}

cntools_multisig_signer_select() {
  local index="$1" id='' known=''
  [[ "${index}" =~ ^[0-9]+$ && -n "${CNTOOLS_MULTISIG_CANDIDATE_IDS[index]:-}" ]] || return 2
  id="${CNTOOLS_MULTISIG_CANDIDATE_IDS[index]}"
  for known in "${CNTOOLS_MULTISIG_SIGNER_IDS[@]}"; do [[ "${known}" != "${id}" ]] || return 0; done
  CNTOOLS_MULTISIG_SIGNER_IDS+=("${id}"); CNTOOLS_MULTISIG_SIGNER_HASHES+=("${CNTOOLS_MULTISIG_CANDIDATE_HASHES[index]}")
  CNTOOLS_MULTISIG_SIGNER_SOURCES+=("${CNTOOLS_MULTISIG_CANDIDATE_SOURCES[index]}"); CNTOOLS_MULTISIG_SIGNER_LABELS+=("${CNTOOLS_MULTISIG_CANDIDATE_LABELS[index]}")
}

cntools_multisig_spend_choose_signers() {
  local choice='' index=0 id='' selected=N path='' source='' begin="${1:-cntools_send_begin}" role_title=''
  local script_keys=0 feedback='' status=0 before=0
  local -a options=() local_signers=()
  CNTOOLS_MULTISIG_SELECTION_ROLE="${2:-payment}"
  [[ "${CNTOOLS_MULTISIG_SELECTION_ROLE}" =~ ^(payment|stake|drep)$ ]] || return 2
  role_title="${CNTOOLS_MULTISIG_SELECTION_ROLE}"
  [[ "${role_title}" != drep ]] || role_title=DRep
  cntools_multisig_candidates_load || return 2
  # When the script needs every key and all of them are known, there is
  # nothing to choose, also when asked again from a review.
  script_keys="$(jq '[..|objects|select(.type=="sig")|.keyHash|ascii_downcase]|unique|length' "${CNTOOLS_MULTISIG_SPEND_SCRIPT}")" || script_keys=0
  if (( script_keys > 0 &&
        CNTOOLS_MULTISIG_SPEND_THRESHOLD == script_keys &&
        ${#CNTOOLS_MULTISIG_CANDIDATE_IDS[@]} == script_keys )); then
    CNTOOLS_MULTISIG_SIGNER_IDS=(); CNTOOLS_MULTISIG_SIGNER_HASHES=(); CNTOOLS_MULTISIG_SIGNER_SOURCES=(); CNTOOLS_MULTISIG_SIGNER_LABELS=()
    for index in "${!CNTOOLS_MULTISIG_CANDIDATE_IDS[@]}"; do
      cntools_multisig_signer_select "${index}" || return 2
    done
    cntools_transaction_log CHOICE "Multisig signers auto-selected role=${CNTOOLS_MULTISIG_SELECTION_ROLE} reason=all-keys-required"
  else
    CNTOOLS_MULTISIG_SIGNERS_CHOICE=Y
    # Quick preselects the local signers when they exactly meet the threshold;
    # the menu still opens, so Enter on 'Done' accepts them.
    if (( ${#CNTOOLS_MULTISIG_SIGNER_IDS[@]} == 0 )) && cntools_flow_quick; then
      for index in "${!CNTOOLS_MULTISIG_CANDIDATE_IDS[@]}"; do
        [[ -z "${CNTOOLS_MULTISIG_CANDIDATE_SOURCES[index]}" ]] || local_signers+=("${index}")
      done
      if (( ${#local_signers[@]} == CNTOOLS_MULTISIG_SPEND_THRESHOLD )); then
        for index in "${local_signers[@]}"; do cntools_multisig_signer_select "${index}" || return 2; done
        cntools_transaction_log CHOICE "Multisig signers preselected role=${CNTOOLS_MULTISIG_SELECTION_ROLE} count=${#local_signers[@]} reason=local-signers-meet-threshold flow=quick"
      fi
    fi
    while true; do
      if declare -F "${begin}" >/dev/null; then cntools_gum_clear; "${begin}" || return 2; fi
      if (( ${#CNTOOLS_MULTISIG_SIGNER_IDS[@]} > 0 )); then
        {
          for index in "${!CNTOOLS_MULTISIG_SIGNER_IDS[@]}"; do
            cntools_table_pair "${CNTOOLS_MULTISIG_SIGNER_LABELS[index]}" "${CNTOOLS_MULTISIG_SIGNER_HASHES[index]}" identifier
          done
        } | cntools_table_render 'Selected signing participants' || return 2
      fi
      cntools_ui_render_status info "Choose the participants who will sign: at least ${CNTOOLS_MULTISIG_SPEND_THRESHOLD} required. ${#CNTOOLS_MULTISIG_SIGNER_IDS[@]} selected. Public-only participants can sign the exported package elsewhere."
      [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
      feedback=''
      options=('Done selecting signers' 'Add external verification key' 'Clear selected signers' Cancel)
      for index in "${!CNTOOLS_MULTISIG_CANDIDATE_IDS[@]}"; do
        id="${CNTOOLS_MULTISIG_CANDIDATE_IDS[index]}"; selected=N
        for path in "${CNTOOLS_MULTISIG_SIGNER_IDS[@]}"; do [[ "${path}" != "${id}" ]] || selected=Y; done
        [[ "${selected}" == N ]] || continue
        options+=("$((index+1)) · ${CNTOOLS_MULTISIG_CANDIDATE_LABELS[index]} · $([[ -n "${CNTOOLS_MULTISIG_CANDIDATE_SOURCES[index]}" ]] && printf 'Local signer' || printf 'Offline signer')")
      done
      cntools_ui_choose choice "Multisig ${role_title} signing participants" "${options[@]}" || return $?
      cntools_transaction_log CHOICE "Multisig participant menu role=${CNTOOLS_MULTISIG_SELECTION_ROLE} selected=${choice}"
      case "${choice}" in
        'Done selecting signers')
          if (( ${#CNTOOLS_MULTISIG_SIGNER_IDS[@]} >= CNTOOLS_MULTISIG_SPEND_THRESHOLD )); then break; fi
          feedback="Select at least ${CNTOOLS_MULTISIG_SPEND_THRESHOLD} signing participants first; ${#CNTOOLS_MULTISIG_SIGNER_IDS[@]} selected." ;;
        'Clear selected signers') CNTOOLS_MULTISIG_SIGNER_IDS=(); CNTOOLS_MULTISIG_SIGNER_HASHES=(); CNTOOLS_MULTISIG_SIGNER_SOURCES=(); CNTOOLS_MULTISIG_SIGNER_LABELS=() ;;
        'Add external verification key')
          status=0
          cntools_ui_pick_path path "Participant ${CNTOOLS_MULTISIG_SELECTION_ROLE} verification-key file" 'Choose a public verification key belonging to this script. Private keys are not requested here.' || status=$?
          (( status != 1 )) || continue
          (( status == 0 )) || return "${status}"
          # Feedback is drawn after the redraw; an accepted key is selected at once.
          before="${#CNTOOLS_MULTISIG_SIGNER_IDS[@]}"
          if ! cntools_multisig_candidate_add "${path}" '' "External participant $((${#CNTOOLS_MULTISIG_CANDIDATE_IDS[@]}+1))"; then
            feedback="Use a safe ${CNTOOLS_MULTISIG_SELECTION_ROLE} verification key belonging to this script. Private keys are not requested here."
          else
            cntools_multisig_signer_select "${CNTOOLS_MULTISIG_CANDIDATE_LAST}" || return 2
            (( ${#CNTOOLS_MULTISIG_SIGNER_IDS[@]} > before )) ||
              feedback="That ${CNTOOLS_MULTISIG_SELECTION_ROLE} key is already selected."
          fi ;;
        Cancel) return 1 ;;
        *) index="${choice%% ·*}"; [[ "${index}" =~ ^[1-9][0-9]*$ ]] || return 2
           cntools_multisig_signer_select "$((index-1))" || return 2 ;;
      esac
    done
  fi
  CNTOOLS_MULTISIG_CAN_SIGN=Y
  for source in "${CNTOOLS_MULTISIG_SIGNER_SOURCES[@]}"; do [[ -n "${source}" ]] || CNTOOLS_MULTISIG_CAN_SIGN=N; done
  cntools_transaction_log CHOICE "Multisig signing subset role=${CNTOOLS_MULTISIG_SELECTION_ROLE} selected participants=${#CNTOOLS_MULTISIG_SIGNER_IDS[@]} can_sign=${CNTOOLS_MULTISIG_CAN_SIGN}"
}

# Before any further input: the payment script's time locks must allow
# spending at SLOT (the build checks again).
cntools_multisig_spend_window_check() {
  cntools_multisig_window_check "$1" "${CNTOOLS_MULTISIG_SPEND_AFTER}" "${CNTOOLS_MULTISIG_SPEND_BEFORE}"
}

# Usage: cntools_multisig_window_check SLOT AFTER BEFORE (empty bounds are open).
cntools_multisig_window_check() {
  local mwc_slot="$1" mwc_after="${2:-}" mwc_before="${3:-}" mwc_label=''
  local mwc_wallet="${CNTOOLS_SEND_WALLET:-${CNTOOLS_STAKE_WALLET:-${CNTOOLS_WALLET_REGISTER_WALLET:-This wallet}}}"
  [[ "${mwc_slot}" =~ ^[0-9]+$ ]] || return 0
  if [[ "${mwc_after}" =~ ^[0-9]+$ ]] && (( mwc_slot < mwc_after )); then
    cntools_slot_datetime_into mwc_label "${mwc_after}" 2>/dev/null || mwc_label="slot ${mwc_after}"
    cntools_transaction_set_error "${mwc_wallet} cannot be spent yet: its multisig script is valid from ${mwc_label}."
    return 1
  fi
  if [[ "${mwc_before}" =~ ^[0-9]+$ ]] && (( mwc_slot >= mwc_before )); then
    cntools_slot_datetime_into mwc_label "${mwc_before}" 2>/dev/null || mwc_label="slot ${mwc_before}"
    cntools_transaction_set_error "${mwc_wallet} can no longer be spent: its multisig script expired at ${mwc_label}."
    return 1
  fi
}

# 0 when a signer menu offered a real choice, so a review can change it.
cntools_multisig_signers_changeable() {
  [[ "${CNTOOLS_MULTISIG_SIGNERS_CHOICE:-N}" == Y ]]
}

declare -ag CNTOOLS_MULTISIG_SAVED_PAYMENT=() CNTOOLS_MULTISIG_SAVED_STAKE=() CNTOOLS_MULTISIG_SAVED_STATE=()

# Saves both signer selections (payment and, for stake actions, stake) and
# the workflow, can-sign and lifetime values a signer change may alter.
cntools_multisig_signers_save() {
  local mss_index=0
  CNTOOLS_MULTISIG_SAVED_PAYMENT=(); CNTOOLS_MULTISIG_SAVED_STAKE=()
  for mss_index in "${!CNTOOLS_MULTISIG_SIGNER_IDS[@]}"; do
    CNTOOLS_MULTISIG_SAVED_PAYMENT+=("${CNTOOLS_MULTISIG_SIGNER_IDS[mss_index]}" "${CNTOOLS_MULTISIG_SIGNER_HASHES[mss_index]}"
      "${CNTOOLS_MULTISIG_SIGNER_SOURCES[mss_index]}" "${CNTOOLS_MULTISIG_SIGNER_LABELS[mss_index]}")
  done
  for mss_index in "${!CNTOOLS_MULTISIG_STAKE_SIGNER_IDS[@]}"; do
    CNTOOLS_MULTISIG_SAVED_STAKE+=("${CNTOOLS_MULTISIG_STAKE_SIGNER_IDS[mss_index]}" "${CNTOOLS_MULTISIG_STAKE_SIGNER_HASHES[mss_index]}"
      "${CNTOOLS_MULTISIG_STAKE_SIGNER_SOURCES[mss_index]}" "${CNTOOLS_MULTISIG_STAKE_SIGNER_LABELS[mss_index]}")
  done
  CNTOOLS_MULTISIG_SAVED_STATE=("${CNTOOLS_MULTISIG_CAN_SIGN}" "${CNTOOLS_STAKE_CAN_SIGN:-N}" "${CNTOOLS_TRANSACTION_UI_WORKFLOW_FIXED:-N}" "$@")
}

# Restores the signer selections cntools_multisig_signers_save kept.
cntools_multisig_signers_restore() {
  local msr_index=0
  CNTOOLS_MULTISIG_SIGNER_IDS=(); CNTOOLS_MULTISIG_SIGNER_HASHES=(); CNTOOLS_MULTISIG_SIGNER_SOURCES=(); CNTOOLS_MULTISIG_SIGNER_LABELS=()
  for (( msr_index = 0; msr_index + 3 < ${#CNTOOLS_MULTISIG_SAVED_PAYMENT[@]}; msr_index += 4 )); do
    CNTOOLS_MULTISIG_SIGNER_IDS+=("${CNTOOLS_MULTISIG_SAVED_PAYMENT[msr_index]}"); CNTOOLS_MULTISIG_SIGNER_HASHES+=("${CNTOOLS_MULTISIG_SAVED_PAYMENT[msr_index+1]}")
    CNTOOLS_MULTISIG_SIGNER_SOURCES+=("${CNTOOLS_MULTISIG_SAVED_PAYMENT[msr_index+2]}"); CNTOOLS_MULTISIG_SIGNER_LABELS+=("${CNTOOLS_MULTISIG_SAVED_PAYMENT[msr_index+3]}")
  done
  CNTOOLS_MULTISIG_STAKE_SIGNER_IDS=(); CNTOOLS_MULTISIG_STAKE_SIGNER_HASHES=(); CNTOOLS_MULTISIG_STAKE_SIGNER_SOURCES=(); CNTOOLS_MULTISIG_STAKE_SIGNER_LABELS=()
  for (( msr_index = 0; msr_index + 3 < ${#CNTOOLS_MULTISIG_SAVED_STAKE[@]}; msr_index += 4 )); do
    CNTOOLS_MULTISIG_STAKE_SIGNER_IDS+=("${CNTOOLS_MULTISIG_SAVED_STAKE[msr_index]}"); CNTOOLS_MULTISIG_STAKE_SIGNER_HASHES+=("${CNTOOLS_MULTISIG_SAVED_STAKE[msr_index+1]}")
    CNTOOLS_MULTISIG_STAKE_SIGNER_SOURCES+=("${CNTOOLS_MULTISIG_SAVED_STAKE[msr_index+2]}"); CNTOOLS_MULTISIG_STAKE_SIGNER_LABELS+=("${CNTOOLS_MULTISIG_SAVED_STAKE[msr_index+3]}")
  done
  CNTOOLS_MULTISIG_CAN_SIGN="${CNTOOLS_MULTISIG_SAVED_STATE[0]:-N}" CNTOOLS_STAKE_CAN_SIGN="${CNTOOLS_MULTISIG_SAVED_STATE[1]:-N}"
  CNTOOLS_TRANSACTION_UI_WORKFLOW_FIXED="${CNTOOLS_MULTISIG_SAVED_STATE[2]:-N}"
}

# Restores the signers and the WORKFLOW, CAN_SIGN and LIFETIME variables
# (by name) after a failed rebuild. A raised expiry is undone with the rest,
# so its one-shot notice goes too.
cntools_multisig_signers_restore_into() {
  cntools_multisig_signers_restore
  CNTOOLS_TRANSACTION_UI_NOTICE=''
  printf -v "$1" '%s' "${CNTOOLS_MULTISIG_SAVED_STATE[3]:-}"
  printf -v "$2" '%s' "${CNTOOLS_MULTISIG_SAVED_STATE[4]:-N}"
  printf -v "$3" '%s' "${CNTOOLS_MULTISIG_SAVED_STATE[5]:-}"
}

# Review 'Change signers'. KIND is payment (Send, Collect) or stake (payment
# and stake participants). Esc keeps the reviewed signers. When the change
# decides whether this system can sign, the workflow follows: unsigned only,
# or (Quick) the default signing workflow. Returns 0 when the signers changed
# and the caller rebuilds, 1 when they did not.
# Usage: cntools_multisig_signers_change_into WORKFLOW CAN_SIGN LIFETIME KIND BEGIN
cntools_multisig_signers_change_into() {
  local msc_workflow="$1" msc_can_sign="$2" msc_lifetime="$3" msc_kind="$4" msc_begin="$5"
  local msc_status=0 msc_before='' msc_was="${!2:-N}" msc_now=N
  cntools_multisig_signers_save "${!msc_workflow}" "${!msc_can_sign}" "${!msc_lifetime}"
  msc_before="${CNTOOLS_MULTISIG_SIGNER_IDS[*]}|${CNTOOLS_MULTISIG_STAKE_SIGNER_IDS[*]}"
  if [[ "${msc_kind}" == stake ]]; then
    cntools_multisig_stake_choose_signers "${msc_begin}" || msc_status=$?
    msc_now="${CNTOOLS_STAKE_CAN_SIGN}"
  else
    cntools_multisig_spend_choose_signers "${msc_begin}" || msc_status=$?
    msc_now="${CNTOOLS_MULTISIG_CAN_SIGN}"
  fi
  if (( msc_status != 0 )); then
    cntools_multisig_signers_restore
    cntools_transaction_log CHOICE "Multisig signers unchanged status=${msc_status}"
    return "${msc_status}"
  fi
  [[ "${CNTOOLS_MULTISIG_SIGNER_IDS[*]}|${CNTOOLS_MULTISIG_STAKE_SIGNER_IDS[*]}" != "${msc_before}" ]] || return 1
  printf -v "${msc_can_sign}" '%s' "${msc_now}"
  if [[ "${msc_now}" != "${msc_was}" && "${msc_now}" != Y ]]; then
    cntools_transaction_ui_workflow_into "${msc_workflow}" N || return 2
    cntools_transaction_ui_unsigned_lifetime_into "${msc_lifetime}" "${!msc_workflow}" || true
  elif [[ "${msc_now}" != "${msc_was}" ]]; then
    CNTOOLS_TRANSACTION_UI_WORKFLOW_FIXED=N
    if cntools_flow_quick; then cntools_transaction_ui_initial_workflow_into "${msc_workflow}" Y || return 2; fi
  fi
  cntools_transaction_log CHOICE "Multisig signers changed can_sign=${msc_now} workflow=${!msc_workflow}"
}

cntools_multisig_spend_plan() {
  local index=0 source='' kind=either
  (( ${#CNTOOLS_MULTISIG_SIGNER_IDS[@]} >= CNTOOLS_MULTISIG_SPEND_THRESHOLD )) || {
    cntools_transaction_set_error 'Choose enough multisig signing participants before building.'; return 1;
  }
  if [[ -n "${CNTOOLS_MULTISIG_SPEND_AFTER}" && -n "${CNTOOLS_FUNDING_SLOT:-}" ]]; then
    ((CNTOOLS_FUNDING_SLOT>=CNTOOLS_MULTISIG_SPEND_AFTER)) || { cntools_transaction_set_error 'This multisig wallet is not spendable yet.'; return 1; }
  fi
  if [[ -n "${CNTOOLS_MULTISIG_SPEND_BEFORE}" ]]; then
    [[ -z "${CNTOOLS_FUNDING_SLOT:-}" ]] || ((CNTOOLS_FUNDING_SLOT<CNTOOLS_MULTISIG_SPEND_BEFORE)) || { cntools_transaction_set_error 'This multisig spending script has expired.'; return 1; }
    if [[ -z "${CNTOOLS_SEND_EXPIRY}" ]] || ((CNTOOLS_SEND_EXPIRY>CNTOOLS_MULTISIG_SPEND_BEFORE)); then CNTOOLS_SEND_EXPIRY="${CNTOOLS_MULTISIG_SPEND_BEFORE}"; fi
  fi
  cntools_transaction_plan_set_validity "${CNTOOLS_MULTISIG_SPEND_AFTER}" "${CNTOOLS_SEND_EXPIRY}" || return 1
  for index in "${!CNTOOLS_MULTISIG_SIGNER_IDS[@]}"; do
    source="${CNTOOLS_MULTISIG_SIGNER_SOURCES[index]}"; kind=either
    if [[ -n "${source}" ]]; then
      cntools_transaction_source_kind_into kind "${source}" || return 1
      CNTOOLS_TRANSACTION_RUNTIME_SOURCES["${CNTOOLS_MULTISIG_SIGNER_IDS[index]}"]="${source}"
      CNTOOLS_TRANSACTION_RUNTIME_SOURCE_KINDS["${CNTOOLS_MULTISIG_SIGNER_IDS[index]}"]="${kind}"
    fi
    cntools_transaction_plan_add_public_signer "${CNTOOLS_MULTISIG_SIGNER_LABELS[index]}" spending \
      "${CNTOOLS_MULTISIG_SIGNER_IDS[index]}" "${CNTOOLS_MULTISIG_SIGNER_HASHES[index]}" "${kind}" || return 1
  done
  cntools_transaction_plan_add_native_script "${CNTOOLS_SEND_WALLET} payment script" spend "${CNTOOLS_MULTISIG_SPEND_SCRIPT}" "${CNTOOLS_MULTISIG_SIGNER_IDS[@]}"
}

cntools_multisig_input_arguments() {
  local -n ms_arguments="$1"
  [[ "${CNTOOLS_SEND_TYPE:-}" != MultiSig ]] || ms_arguments+=(--tx-in-script-file "${CNTOOLS_MULTISIG_SPEND_SCRIPT}")
  return 0
}
