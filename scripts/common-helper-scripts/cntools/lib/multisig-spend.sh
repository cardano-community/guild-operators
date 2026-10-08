#!/usr/bin/env bash
# Native-script spending adapter for Send/Collect. Selected public identities
# are fixed before building; signature collection uses ordinary tx packages.
# shellcheck disable=SC2034
CNTOOLS_MULTISIG_SPEND_SCRIPT='' CNTOOLS_MULTISIG_SPEND_AFTER='' CNTOOLS_MULTISIG_SPEND_BEFORE=''
CNTOOLS_MULTISIG_SPEND_THRESHOLD=0 CNTOOLS_MULTISIG_CAN_SIGN=N
CNTOOLS_MULTISIG_SELECTION_ROLE=payment
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
  CNTOOLS_MULTISIG_CAN_SIGN=N
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
  for known in "${CNTOOLS_MULTISIG_CANDIDATE_IDS[@]}"; do [[ "${known}" != "${id}" ]] || return 0; done
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
  local directory='' prefix='' source='' verification='' role="${CNTOOLS_MULTISIG_SELECTION_ROLE:-payment}"
  local vkey="${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" skey="${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" hws="${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}"
  if [[ "${role}" == stake ]]; then
    vkey="${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"; skey="${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}"; hws="${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}"
  fi
  if [[ "${role}" == drep ]]; then
    vkey="${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}"; skey="${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}"; hws="${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}"
  fi
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
      cntools_multisig_candidate_add "${verification}" "${source}" "${directory##*/} · ${prefix:-regular}${role}" || true
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
  local -a options=()
  CNTOOLS_MULTISIG_SELECTION_ROLE="${2:-payment}"
  [[ "${CNTOOLS_MULTISIG_SELECTION_ROLE}" =~ ^(payment|stake|drep)$ ]] || return 2
  role_title="${CNTOOLS_MULTISIG_SELECTION_ROLE}"
  [[ "${role_title}" != drep ]] || role_title=DRep
  cntools_multisig_candidates_load || return 2
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
        if (( ${#CNTOOLS_MULTISIG_SIGNER_IDS[@]} >= CNTOOLS_MULTISIG_SPEND_THRESHOLD )); then break; fi ;;
      'Clear selected signers') CNTOOLS_MULTISIG_SIGNER_IDS=(); CNTOOLS_MULTISIG_SIGNER_HASHES=(); CNTOOLS_MULTISIG_SIGNER_SOURCES=(); CNTOOLS_MULTISIG_SIGNER_LABELS=() ;;
      'Add external verification key')
        cntools_ui_input path "Participant ${CNTOOLS_MULTISIG_SELECTION_ROLE} verification-key file" '' || continue
        if ! cntools_multisig_candidate_add "${path}" '' "External participant $((${#CNTOOLS_MULTISIG_CANDIDATE_IDS[@]}+1))"; then
          cntools_ui_render_status warn "Use a safe ${CNTOOLS_MULTISIG_SELECTION_ROLE} verification key belonging to this script. Private keys are not requested here."
        fi ;;
      Cancel) return 1 ;;
      *) index="${choice%% ·*}"; [[ "${index}" =~ ^[1-9][0-9]*$ ]] || return 2
         cntools_multisig_signer_select "$((index-1))" || return 2 ;;
    esac
  done
  CNTOOLS_MULTISIG_CAN_SIGN=Y
  for source in "${CNTOOLS_MULTISIG_SIGNER_SOURCES[@]}"; do [[ -n "${source}" ]] || CNTOOLS_MULTISIG_CAN_SIGN=N; done
  cntools_transaction_log CHOICE "Multisig signing subset role=${CNTOOLS_MULTISIG_SELECTION_ROLE} selected participants=${#CNTOOLS_MULTISIG_SIGNER_IDS[@]} can_sign=${CNTOOLS_MULTISIG_CAN_SIGN}"
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
