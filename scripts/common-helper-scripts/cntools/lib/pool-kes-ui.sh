#!/usr/bin/env bash
# KES preparation, offline hand-off and publication share the pool table theme.
# shellcheck disable=SC2034
cntools_kes_choose() {
  cntools_ui_choose "$@" || return $?
  local -n kes_selected_ref="$1"
  cntools_transaction_log CHOICE "KES ${2}: ${kes_selected_ref}"
}

# Every unconfirmed step reports what state it left, so an exit to the menu
# never hides whether anything changed.
cntools_kes_confirm() {
  local prompt="$1" default="$2" stopped="${3:-}" kes_confirmation_status=0
  cntools_ui_confirm "${prompt}" "${default}" || kes_confirmation_status=$?
  cntools_transaction_log CHOICE "KES confirmation=${kes_confirmation_status} prompt=${prompt}"
  if ((kes_confirmation_status != 0)) && [[ -n "${stopped}" ]]; then
    # 1 is No and 130 is Esc/Ctrl+C; anything else means the prompt itself failed.
    ((kes_confirmation_status == 1 || kes_confirmation_status == 130)) ||
      stopped="Confirmation prompt failed (status ${kes_confirmation_status}). ${stopped}"
    cntools_kes_result "${stopped}" warning
  fi
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
    # Normally equal to the health rows' next issue counter; show only a divergence.
    if [[ "${CNTOOLS_KES_NEXT}" != "${CNTOOLS_POOL_CERT_NEXT[CNTOOLS_KES_INDEX]:-}" ]]; then
      cntools_table_pair 'Issue counter to use' "$(cntools_number_format "${CNTOOLS_KES_NEXT}")" number
      [[ -z "${CNTOOLS_KES_COUNTER_SOURCE}" ]] || cntools_table_pair 'Counter source' "${CNTOOLS_KES_COUNTER_SOURCE}" muted
    fi
    [[ -z "${CNTOOLS_KES_PERIOD_SOURCE}" ]] || cntools_table_pair 'Period source' "${CNTOOLS_KES_PERIOD_SOURCE}" muted
    [[ -z "${CNTOOLS_KES_STAGE}" ]] || cntools_table_pair Recovery "${CNTOOLS_KES_STAGE}" identifier
  } | cntools_table_render 'KES rotation'
  cntools_kes_counter_notice
}

# Explain a new rotation's counter when cold.counter disagrees with the ledger.
cntools_kes_counter_notice() {
  local ledger="${CNTOOLS_POOL_CERT_CHAIN[CNTOOLS_KES_INDEX]:-}" disk="${CNTOOLS_KES_DISK_NEXT}" next="${CNTOOLS_KES_NEXT}" range=''
  [[ -z "${CNTOOLS_KES_STAGE}" && "${CNTOOLS_KES_COUNTER_SOURCE}" == 'Ledger counter + 1' && -n "${ledger}" &&
     "${disk}" =~ ^[0-9]+$ && "${next}" =~ ^[0-9]+$ && "${disk}" != "${next}" ]] || return 0
  if ((disk > next)); then
    range="${next}"; ((disk-1 == next)) || range="${next}–$((disk-1))"
    cntools_ui_render_status warn "cold.counter (${disk}) is ahead of the ledger counter (${ledger}): certificate ${range} was issued but never used on chain. This rotation issues ${next} instead, so never deploy the earlier certificate."
  else
    cntools_ui_render_status info "cold.counter (${disk}) is behind the ledger counter (${ledger}). This rotation issues ${next} and moves cold.counter forward."
  fi
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

# A new rotation uses the ledger counter + 1 when local node or Koios data has
# it. Otherwise the operator enters the counter, starting from cold.counter.
cntools_kes_counter_choose() {
  local entered='' normalized=''
  CNTOOLS_KES_COUNTER_APPROVED=N
  if cntools_kes_counter_from_ledger; then cntools_kes_counter_guard; return; fi
  cntools_ui_render_status warn "No ledger counter is available. Enter the pool's latest on-chain certificate counter + 1; a wrong counter stops block production."
  while true; do
    cntools_kes_input entered 'Issue counter to use' "Enter for ${CNTOOLS_KES_DISK_NEXT} (cold.counter)" || return $?
    [[ -n "${entered}" ]] || entered="${CNTOOLS_KES_DISK_NEXT}"
    if cntools_number_normalize_into normalized "${entered}" && [[ "${normalized}" =~ ^(0|[1-9][0-9]{0,9})$ ]] &&
        ((normalized < 2147483647)); then
      CNTOOLS_KES_NEXT="${normalized}" CNTOOLS_KES_COUNTER_APPROVED=Y CNTOOLS_KES_COUNTER_SOURCE='Operator entered'
      cntools_transaction_log CHOICE "KES issue counter entered=${normalized} cold.counter=${CNTOOLS_KES_DISK_NEXT}"
      cntools_kes_counter_guard; return
    fi
    cntools_ui_render_status warn 'Enter a non-negative integer below 2,147,483,647.'
  done
}

# A pending rotation keeps the counter recorded in its request; only verify it.
cntools_kes_counter_verify() {
  CNTOOLS_KES_COUNTER_APPROVED=N
  if [[ -z "${CNTOOLS_POOL_CERT_CHAIN[CNTOOLS_KES_INDEX]:-}" ]]; then
    cntools_ui_render_status warn "The ledger counter is unavailable. Continue only if ${CNTOOLS_KES_NEXT} is the pool's latest on-chain certificate counter + 1; a wrong counter stops block production."
    cntools_kes_confirm "Is ${CNTOOLS_KES_NEXT} the right issue counter for this pool?" false \
      'Rotation stopped at counter verification. No certificate was issued and the issue counter is unchanged.' || return 1
    CNTOOLS_KES_COUNTER_APPROVED=Y
    cntools_transaction_log CHOICE "KES pending counter=${CNTOOLS_KES_NEXT} approved (ledger unavailable)"
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
      cntools_kes_confirm "Use independently verified KES period ${normalized}?" false \
        'Rotation stopped before preparing keys. Nothing was changed.' || return 1
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

# The running node keeps its loaded KES key until it reloads or restarts, so
# installation does not require stopping it. Load the new set afterwards.
cntools_kes_install() {
  cntools_ui_render_status info 'The node keeps signing with its current KES key until it reloads or restarts, so it can stay running. Do not restart it while the files are being replaced. CNTools keeps the current files and the new set privately for recovery.'
  cntools_kes_confirm 'Install the new KES key and certificate now?' false \
    'Not installed. Active node files are unchanged and the issued set stays staged; reopen Pool → Rotate to install it.' || return 0
  CNTOOLS_KES_INSTALL_APPROVED=Y
  cntools_transaction_log CHOICE 'KES operational file publication approved'
  cntools_ui_spin_function 'Installing the validated KES key and certificate set…' cntools_kes_publish || return 1
  cntools_kes_reload_offer
}

# PID of the cnode block producer's active systemd unit, if it runs that way.
cntools_kes_systemd_pid_into() {
  # Locals avoid "pid": callers pass that name to be assigned by printf -v.
  local output="$1" unit="$2" main_pid=''
  [[ "${CNTOOLS_IMPLEMENTATION:-}" == cnode && "${unit}" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] &&
    command -v systemctl >/dev/null 2>&1 || return 1
  [[ "$(systemctl show --property LoadState --value -- "${unit}" 2>/dev/null)" == loaded &&
     "$(systemctl show --property ActiveState --value -- "${unit}" 2>/dev/null)" == active ]] || return 1
  main_pid="$(systemctl show --property MainPID --value -- "${unit}" 2>/dev/null)" || return 1
  [[ "${main_pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf -v "${output}" '%s' "${main_pid}"
}

# Wait briefly for node metrics to report the new certificate's start period.
cntools_kes_reload_confirmed() {
  local url='' metrics='' seen='' attempt=0
  url="$(cntools_health_local_metrics_url)" || return 2
  for ((attempt = 0; attempt < 15; attempt++)); do
    metrics="$(cntools_health_fetch_local "${url}" 2>/dev/null)" &&
      seen="$(sed -nE 's/^cardano_node_metrics_operationalCertificateStartKESPeriod_int[[:space:]]+([0-9]+).*/\1/p' <<< "${metrics}" | head -n 1)"
    [[ "${seen}" != "${CNTOOLS_KES_START}" ]] || return 0
    sleep 1
  done
  return 1
}

# cardano-node re-reads its KES key and operational certificate on SIGHUP.
cntools_kes_reload_offer() {
  local unit="${CNTOOLS_SERVICE%.service}.service" pid='' choice='' status=0
  local manual="sudo kill -SIGHUP \$(systemctl show --property MainPID --value ${unit})"
  local closing='VRF and cold keys were not changed; never roll the issue counter back. If another system runs this pool, deploy its matching KES signing key and certificate there.'
  if cntools_kes_systemd_pid_into pid "${unit}"; then
    cntools_kes_choose choice 'Load the new KES key' 'Reload the node now (SIGHUP)' 'I will reload or restart it myself' || choice=''
    if [[ "${choice}" == 'Reload the node now (SIGHUP)' ]]; then
      if kill -HUP "${pid}" 2>/dev/null || { command -v sudo >/dev/null 2>&1 && sudo -n kill -HUP "${pid}" 2>/dev/null; }; then
        cntools_transaction_log POOL "KES reload signal sent unit=${unit} pid=${pid}"
        cntools_ui_spin_function 'Waiting for the node to load the new certificate…' cntools_kes_reload_confirmed || status=$?
        if ((status == 0)); then
          cntools_ui_render_status info "${closing}"
          cntools_kes_result 'KES keys and certificate installed and loaded by the node'; return 0
        fi
        cntools_ui_render_status warn "The reload signal was sent, but node metrics did not show the new certificate (start period ${CNTOOLS_KES_START}). Check gLiveView or the node log; restart the node if it did not reload. ${closing}"
        cntools_kes_result 'KES keys and certificate installed; reload signal sent' warning; return 0
      fi
      cntools_ui_render_status warn "CNTools could not signal ${unit} (PID ${pid}). Run: ${manual}"
      cntools_kes_result 'KES keys and certificate installed; the node has not loaded them yet' warning; return 0
    fi
    cntools_ui_render_status info "Load the new set by reloading the node (${manual}) or restarting it. ${closing}"
  else
    cntools_ui_render_status info "No active systemd unit ${unit} was found for this node. Load the new set by sending SIGHUP to the cardano-node process or restarting it. ${closing}"
  fi
  cntools_kes_result 'KES keys and certificate installed; reload or restart the node to use them' warning
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
            cntools_kes_confirm 'Issue this replacement certificate?' false \
              'Certificate not issued. The prepared KES keys stay in recovery; reopen Pool → Rotate to continue.' || return 0
            if [[ "${CNTOOLS_KES_KIND}" == hardware ]]; then cntools_ui_render_status info 'Connect and unlock the hardware device, open Cardano and approve certificate issuance.'; fi
            cntools_ui_spin_function 'Issuing and validating the KES certificate…' cntools_kes_issue || return 1 ;;
          'Prepare offline hand-off') cntools_kes_offline_instructions; return $? ;;
          'Import signed response')
            cntools_ui_pick_path directory 'Signed response directory' 'Choose the folder containing op.cert and cold.counter.' "${CNTOOLS_KES_DIRECTORY}" directory || return $?
            cntools_ui_spin_function 'Validating the returned certificate and counter…' cntools_kes_import_response "${directory}" || return 1 ;;
          *) return 0 ;;
        esac ;;
      awaiting)
        cntools_kes_choose choice 'Offline rotation' 'Import signed response' 'Show hand-off instructions' 'Return without changing active keys' || return $?
        case "${choice}" in
          'Import signed response')
            cntools_ui_pick_path directory 'Signed response directory' 'Choose the folder containing op.cert and cold.counter.' "${CNTOOLS_KES_DIRECTORY}" directory || return $?
            cntools_ui_spin_function 'Validating the returned certificate and counter…' cntools_kes_import_response "${directory}" || return 1 ;;
          'Show hand-off instructions') cntools_kes_offline_instructions; return $? ;;
          *) return 0 ;;
        esac ;;
      issuing)
        cntools_ui_render_status warn 'Issuance was interrupted. CNTools will only validate existing recovery output and preserve its advanced counter; it will not issue again.'
        cntools_kes_confirm 'Validate and recover the already issued certificate?' false \
          'Recovery not started. The interrupted issuance stays locked; reopen Pool → Rotate to recover it.' || return 0
        cntools_ui_spin_function 'Checking existing certificate recovery files…' cntools_kes_consume_counter || {
          cntools_kes_error 'Recovery is incomplete or invalid. Inspect it manually; keep the lock and never restore an older counter.'; return 1;
        } ;;
      issued|publishing) cntools_kes_install; return $? ;;
      complete) cntools_kes_lock_release; return $? ;;
      *) cntools_kes_error 'The pending rotation phase is incomplete. Inspect its recovery directory; no new issuance was attempted.'; return 1 ;;
    esac
  done
  return "${status}"
}

cntools_pool_action_rotate() {
  local selected='' choice='' request='' status=0
  CNTOOLS_KES_STAGE='' CNTOOLS_KES_BUSY='' CNTOOLS_KES_START='' CNTOOLS_KES_CURRENT=''
  CNTOOLS_KES_COUNTER_APPROVED=N CNTOOLS_KES_INSTALL_APPROVED=N CNTOOLS_KES_PERIOD_SOURCE=''
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
  if cntools_pool_legacy_opcert_lock "${CNTOOLS_KES_DIRECTORY}"; then
    cntools_kes_result "An earlier CNTools build left an operational-certificate lock in ${CNTOOLS_KES_DIRECTORY}/.cntools-opcert-lock. Finish or inspect that operation manually; no new certificate will be issued." error
    return 0
  fi
  local lock=''
  cntools_pool_opcert_lock_into lock "${CNTOOLS_KES_DIRECTORY}" || {
    cntools_kes_result 'The owner-only CNTools state folder (.cntools in the node home) is unavailable.' error; return 0;
  }
  if [[ -e "${lock}" || -L "${lock}" ]]; then
    if cntools_kes_pending_load; then
      case "$(< "${CNTOOLS_KES_STAGE}/phase")" in
        prepared|awaiting)
          if ! cntools_kes_counter_verify; then
            [[ -z "${CNTOOLS_POOL_WRITE_ERROR}" ]] || cntools_kes_result "${CNTOOLS_POOL_WRITE_ERROR}" error
            return 0
          fi ;;
      esac
      cntools_kes_continue || status=$?
    else status=2; fi
  else
    cntools_kes_counter_from_ledger || true
    cntools_kes_review || return 1
    # Signing needs the cold key (file or hardware wallet) on this system.
    local -a workflows=()
    [[ -z "${CNTOOLS_KES_SOURCE}" ]] || workflows+=('Rotate now')
    workflows+=('Prepare offline request')
    [[ -z "${CNTOOLS_KES_SOURCE}" ]] || workflows+=('Sign an offline request')
    [[ -n "${CNTOOLS_KES_SOURCE}" ]] ||
      cntools_ui_render_status info 'No cold signing key or hardware wallet file for this pool is on this system, so only an offline request can be prepared here.'
    cntools_kes_choose choice 'KES workflow' "${workflows[@]}" Cancel || return $?
    [[ "${choice}" != Cancel ]] || return 0
    if [[ "${choice}" != 'Sign an offline request' ]] && ! cntools_kes_counter_choose; then
      [[ -z "${CNTOOLS_POOL_WRITE_ERROR}" ]] || cntools_kes_result "${CNTOOLS_POOL_WRITE_ERROR}" error
      return 0
    fi
    case "${choice}" in
      'Rotate now')
        cntools_kes_choose_period || return 0
        cntools_kes_review || return 1
        cntools_ui_render_status warn "Rotation generates new KES keys and issues certificate ${CNTOOLS_KES_NEXT}, which permanently advances the cold counter. Active node files change only when you install the new set."
        cntools_kes_confirm "Rotate KES now, starting at period ${CNTOOLS_KES_START}?" false \
          'No KES keys were generated and the issue counter is unchanged.' || return 0
        cntools_ui_spin_function 'Preparing and validating replacement KES keys…' cntools_kes_prepare "${CNTOOLS_KES_START}" || status=$?
        if ((status == 0)); then
          [[ "${CNTOOLS_KES_KIND}" != hardware ]] || cntools_ui_render_status info 'Connect and unlock the hardware device, open Cardano and approve certificate issuance.'
          cntools_ui_spin_function 'Issuing and validating the KES certificate…' cntools_kes_issue || status=$?
        fi
        ((status != 0)) || cntools_kes_continue || status=$? ;;
      'Prepare offline request')
        cntools_kes_choose_period || return 0
        cntools_kes_review || return 1
        cntools_kes_confirm "Prepare an offline request starting at KES period ${CNTOOLS_KES_START}? The counter advances only when the cold key signs it." false \
          'No offline request was prepared. Nothing was changed.' || return 0
        cntools_ui_spin_function 'Preparing and validating replacement KES keys…' cntools_kes_prepare "${CNTOOLS_KES_START}" || status=$?
        ((status != 0)) || cntools_kes_offline_instructions || status=$? ;;
      'Sign an offline request')
        cntools_ui_pick_path request 'Offline request directory' 'Choose the public request folder copied from the node.' "${CNTOOLS_KES_DIRECTORY}" directory || return $?
        cntools_kes_request_validate "${request}" || { cntools_kes_result 'The request does not match this pool, network or counter.' error; return 0; }
        CNTOOLS_KES_START="$(jq -r '.startPeriod' "${request}/request.json")"
        CNTOOLS_KES_NEXT="$(jq -r '.issueCounter' "${request}/request.json")" CNTOOLS_KES_COUNTER_SOURCE='Offline request'
        cntools_kes_review || return 1
        cntools_ui_render_status warn "Check the requested KES period against the node. The node chose issue counter ${CNTOOLS_KES_NEXT}; signing sets this system's cold.counter (now ${CNTOOLS_KES_DISK_NEXT}) to $((CNTOOLS_KES_NEXT+1)). Only return the public certificate and advanced counter, never cold or KES private keys."
        cntools_kes_confirm 'Sign this offline certificate request and advance the real counter?' false \
          'Request not signed. The issue counter was not advanced.' || return 0
        CNTOOLS_KES_COUNTER_APPROVED=Y
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
