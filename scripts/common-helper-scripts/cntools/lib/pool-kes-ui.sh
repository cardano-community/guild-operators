#!/usr/bin/env bash
# KES preparation, offline hand-off and publication share the pool table theme.
# shellcheck disable=SC2034
cntools_kes_choose() {
  cntools_ui_choose "$@" || return $?
  local -n kes_selected_ref="$1"
  cntools_transaction_log CHOICE "KES ${2}: ${kes_selected_ref}"
}

cntools_kes_confirm() {
  local kes_confirmation_status=0
  cntools_ui_confirm "$@" || kes_confirmation_status=$?
  cntools_transaction_log CHOICE "KES confirmation=${kes_confirmation_status} prompt=$1"
  return "${kes_confirmation_status}"
}

cntools_kes_input() {
  cntools_ui_input "$@" || return $?
  local -n kes_input_ref="$1"
  cntools_transaction_log CHOICE "KES ${2}: ${kes_input_ref}"
}
cntools_kes_review() {
  cntools_ui_action_begin Rotate '/ Pool / Rotate'
  {
    cntools_table_pair Pool "${CNTOOLS_POOL_NAMES[CNTOOLS_KES_INDEX]}" identifier
    cntools_table_pair 'Pool ID' "${CNTOOLS_POOL_IDS[CNTOOLS_KES_INDEX]}" identifier
    cntools_pool_health_rows "${CNTOOLS_KES_INDEX}" Y
    [[ -z "${CNTOOLS_KES_START}" ]] || cntools_table_pair 'Replacement start period' "$(cntools_number_format "${CNTOOLS_KES_START}")" number
    cntools_table_pair 'Issue counter to use' "$(cntools_number_format "${CNTOOLS_KES_NEXT}")" number
    [[ -z "${CNTOOLS_KES_PERIOD_SOURCE}" ]] || cntools_table_pair 'Period source' "${CNTOOLS_KES_PERIOD_SOURCE}" muted
    [[ -z "${CNTOOLS_KES_STAGE}" ]] || cntools_table_pair Recovery "${CNTOOLS_KES_STAGE}" identifier
  } | cntools_table_render 'KES rotation'
}

cntools_kes_result() {
  local message="$1" role="${2:-success}"
  {
    cntools_table_pair Pool "${CNTOOLS_POOL_NAMES[CNTOOLS_KES_INDEX]}" identifier
    cntools_table_pair Result "${message}" "${role}"
    [[ -z "${CNTOOLS_KES_STAGE}" ]] || cntools_table_pair Recovery "${CNTOOLS_KES_STAGE}" identifier
  } | cntools_table_render 'KES rotation'
  [[ -z "${CNTOOLS_POOL_WRITE_WARNING}" ]] || cntools_ui_render_status warn "${CNTOOLS_POOL_WRITE_WARNING}"
  cntools_ui_wait
}

cntools_kes_counter_approve() {
  CNTOOLS_KES_COUNTER_APPROVED=N
  if [[ -z "${CNTOOLS_POOL_CERT_CHAIN[CNTOOLS_KES_INDEX]:-}" ]]; then
    cntools_ui_render_status warn 'The ledger certificate counter is unavailable. Verify the real issue counter against a connected node before continuing. A reset or stale counter can stop block production.'
    cntools_kes_confirm 'Have you independently verified this issue counter for the pool?' no || return 1
    CNTOOLS_KES_COUNTER_APPROVED=Y
    cntools_transaction_log CHOICE 'KES counter approved after independent verification (ledger unavailable)'
  fi
  cntools_kes_counter_guard
}

cntools_kes_choose_period() {
  local entered='' normalized=''
  cntools_ui_spin_function 'Checking the current KES period…' cntools_kes_period_collect || return 1
  if [[ -n "${CNTOOLS_KES_CURRENT}" ]]; then CNTOOLS_KES_START="${CNTOOLS_KES_CURRENT}"; return 0; fi
  cntools_ui_render_status warn 'The current KES period is unavailable. On an offline system, enter the period recently verified on the block producer for this network.'
  while true; do
    cntools_kes_input entered 'Verified current KES period' 'Unsigned integer; cancel to return' || return $?
    if cntools_number_normalize_into normalized "${entered}" && [[ "${normalized}" =~ ^(0|[1-9][0-9]{0,9})$ ]] &&
        ((normalized < 2147483647)); then
      cntools_kes_confirm "Use independently verified KES period ${normalized}?" no || return 1
      CNTOOLS_KES_START="${normalized}" CNTOOLS_KES_PERIOD_SOURCE='Operator verified · offline/unavailable tip'
      cntools_transaction_log CHOICE "KES start independently verified period=${normalized}"
      return 0
    fi
    cntools_ui_render_status warn 'Enter a non-negative integer below 2,147,483,647.'
  done
}

cntools_kes_offline_instructions() {
  cntools_kes_phase_set awaiting || return 1
  {
    cntools_table_pair 'Copy to signing system' "${CNTOOLS_KES_STAGE}/request" identifier
    cntools_table_pair 'Keep on node · private' "${CNTOOLS_KES_STAGE}/replacement/hot.skey" warning
    cntools_table_pair 'Signing action' 'Pool → Rotate → Sign an offline request' value
    cntools_table_pair 'Return files' 'op.cert and cold.counter from the signing result directory' value
  } | cntools_table_render 'Offline certificate issuance'
  cntools_ui_render_status info 'Copy only the request directory. The signing system must already hold the pool cold key and real counter. Return the signed response, then reopen Rotate on this node to finish. Do not issue another certificate while this request is outstanding.'
  cntools_ui_wait
}

cntools_kes_continue() {
  local phase='' choice='' directory='' status=0
  while true; do
    phase="$(< "${CNTOOLS_KES_STAGE}/phase")"
    cntools_kes_review || return 1
    case "${phase}" in
      prepared)
        local -a choices=()
        [[ -z "${CNTOOLS_KES_SOURCE}" ]] || choices+=('Issue certificate now')
        choices+=('Prepare offline hand-off' 'Import signed response' 'Return without changing active keys')
        cntools_kes_choose choice 'Continue rotation' "${choices[@]}" || return $?
        case "${choice}" in
          'Issue certificate now')
            cntools_ui_render_status warn 'Issuing a certificate advances the real counter, even if you postpone installation. Keep its recovery copy; never restore an older counter.'
            cntools_kes_confirm 'Issue this replacement certificate?' no || return 0
            if [[ "${CNTOOLS_KES_KIND}" == hardware ]]; then cntools_ui_render_status info 'Connect and unlock the hardware device, open Cardano and approve certificate issuance.'; fi
            cntools_ui_spin_function 'Issuing and validating the KES certificate…' cntools_kes_issue || return 1 ;;
          'Prepare offline hand-off') cntools_kes_offline_instructions; return $? ;;
          'Import signed response')
            cntools_kes_input directory 'Signed response directory' 'Absolute path containing op.cert and cold.counter' || return $?
            cntools_ui_spin_function 'Validating the returned certificate and counter…' cntools_kes_import_response "${directory}" || return 1 ;;
          *) return 0 ;;
        esac ;;
      awaiting)
        cntools_kes_choose choice 'Offline rotation' 'Import signed response' 'Show hand-off instructions' 'Return without changing active keys' || return $?
        case "${choice}" in
          'Import signed response')
            cntools_kes_input directory 'Signed response directory' 'Absolute path containing op.cert and cold.counter' || return $?
            cntools_ui_spin_function 'Validating the returned certificate and counter…' cntools_kes_import_response "${directory}" || return 1 ;;
          'Show hand-off instructions') cntools_kes_offline_instructions; return $? ;;
          *) return 0 ;;
        esac ;;
      issuing)
        cntools_ui_render_status warn 'Issuance was interrupted. CNTools will only validate existing recovery output and preserve its advanced counter; it will not issue again.'
        cntools_kes_confirm 'Validate and recover the already issued certificate?' no || return 0
        cntools_ui_spin_function 'Checking existing certificate recovery files…' cntools_kes_consume_counter || {
          cntools_kes_error 'Recovery is incomplete or invalid. Inspect it manually; keep the lock and never restore an older counter.'; return 1;
        } ;;
      issued|publishing)
        cntools_ui_render_status warn 'Stop the block producer before installing the matching KES key/certificate set. CNTools will not stop or restart your node. Original files and the new set are retained privately for recovery.'
        cntools_kes_choose choice 'Install replacement files' 'Install on this node' 'Return and install later' || return $?
        [[ "${choice}" == 'Install on this node' ]] || return 0
        cntools_kes_confirm 'Is the block producer stopped, and should CNTools install this replacement?' no || return 0
        CNTOOLS_KES_NODE_STOPPED=Y
        cntools_transaction_log CHOICE 'KES operational file publication approved; operator confirmed node stopped'
        cntools_ui_spin_function 'Installing the validated KES key and certificate set…' cntools_kes_publish || return 1
        cntools_ui_render_status info 'Restart the block producer with the new operational files, then check Pool → Show or gLiveView. If another deployment runs the node, securely deploy its matching KES signing key and certificate first. VRF and cold keys were not changed; never roll the issue counter back.'
        cntools_kes_result 'KES keys and certificate installed'; return 0 ;;
      complete) cntools_kes_lock_release; return $? ;;
      *) cntools_kes_error 'The pending rotation phase is incomplete. Inspect its recovery directory; no new issuance was attempted.'; return 1 ;;
    esac
  done
  return "${status}"
}

cntools_pool_action_rotate() {
  local selected='' choice='' request='' status=0
  CNTOOLS_KES_STAGE='' CNTOOLS_KES_BUSY='' CNTOOLS_KES_START='' CNTOOLS_KES_CURRENT=''
  CNTOOLS_KES_COUNTER_APPROVED=N CNTOOLS_KES_NODE_STOPPED=N CNTOOLS_KES_PERIOD_SOURCE=''
  cntools_ui_action_begin Rotate '/ Pool / Rotate'
  cntools_kes_environment || { cntools_kes_result "${CNTOOLS_POOL_WRITE_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-KES prerequisites unavailable}}" error; return 0; }
  cntools_ui_spin_function 'Reading pool identities…' cntools_pool_catalog_build || return 1
  (( ${#CNTOOLS_POOL_NAMES[@]} != 0 )) || { cntools_ui_render_status info 'No pools found.'; cntools_ui_wait; return 0; }
  cntools_pool_choose_into selected || status=$?
  ((status != 1)) || return 0; ((status == 0)) || return "${status}"
  if ! cntools_ui_spin_function 'Validating pool cold identity and counter…' cntools_kes_identity "${selected}"; then
    cntools_kes_result "${CNTOOLS_POOL_WRITE_ERROR:-Invalid pool signing material or counter}" error; return 0
  fi
  cntools_ui_spin_function 'Checking current KES health and counter…' cntools_pool_inspect_catalog "${selected}" || return 1
  cntools_ui_spin_function 'Checking operational certificate…' cntools_pool_health_collect "${selected}" || return 1
  if [[ -e "${CNTOOLS_KES_DIRECTORY}/.cntools-opcert-lock" || -L "${CNTOOLS_KES_DIRECTORY}/.cntools-opcert-lock" ]]; then
    if cntools_kes_pending_load; then
      case "$(< "${CNTOOLS_KES_STAGE}/phase")" in
        prepared|awaiting) cntools_kes_counter_approve || return 0 ;;
      esac
      cntools_kes_continue || status=$?
    else status=2; fi
  else
    cntools_kes_review || return 1
    cntools_kes_choose choice 'KES workflow' 'Prepare replacement KES keys' 'Sign an offline request' Cancel || return $?
    [[ "${choice}" != Cancel ]] || return 0
    if ! cntools_kes_counter_approve; then
      [[ -z "${CNTOOLS_POOL_WRITE_ERROR}" ]] || cntools_kes_result "${CNTOOLS_POOL_WRITE_ERROR}" error
      return 0
    fi
    case "${choice}" in
      'Prepare replacement KES keys')
        cntools_kes_choose_period || return 0
        cntools_kes_review || return 1
        cntools_kes_confirm 'Generate replacement KES keys? Existing keys remain active until installation.' no || return 0
        cntools_ui_spin_function 'Preparing and validating replacement KES keys…' cntools_kes_prepare "${CNTOOLS_KES_START}" || status=$?
        ((status != 0)) || cntools_kes_continue || status=$? ;;
      'Sign an offline request')
        [[ -n "${CNTOOLS_KES_SOURCE}" ]] || { cntools_kes_result 'Open the cold key or connect its hardware device on the signing system first.' warning; return 0; }
        cntools_kes_input request 'Offline request directory' 'Absolute path to the public request folder' || return $?
        cntools_kes_request_validate "${request}" || { cntools_kes_result 'The request does not match this pool, network or counter.' error; return 0; }
        CNTOOLS_KES_START="$(jq -r '.startPeriod' "${request}/request.json")"
        cntools_kes_review || return 1
        cntools_ui_render_status warn 'Check the requested KES period against the node. Issuance advances your real cold counter. Only return the public certificate and advanced counter, never cold or KES private keys.'
        cntools_kes_confirm 'Sign this offline certificate request and advance the real counter?' no || return 0
        [[ "${CNTOOLS_KES_KIND}" != hardware ]] || cntools_ui_render_status info 'Connect and unlock the hardware device, open Cardano and approve certificate issuance.'
        cntools_ui_spin_function 'Issuing the offline operational certificate…' cntools_kes_sign_request "${request}" || status=$?
        if ((status == 0)); then
          { cntools_table_pair 'Signed response directory' "${CNTOOLS_KES_STAGE}/replacement" identifier; cntools_table_pair 'Return files' 'op.cert and cold.counter' value; } | cntools_table_render 'Offline result'
          cntools_ui_wait
        fi ;;
    esac
  fi
  if ((status != 0)); then cntools_kes_result "${CNTOOLS_POOL_WRITE_ERROR:-KES operation failed; retain recovery files and inspect the log before retrying.}" error; fi
  return 0
}
