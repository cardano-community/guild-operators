#!/usr/bin/env bash
# KES preparation, offline hand-off and publication share the pool table theme.
# shellcheck disable=SC2034
cntools_kes_choose() {
  cntools_ui_choose "$@" || return $?
  local -n kes_selected_ref="$1"
  cntools_transaction_log CHOICE "KES ${2}: ${kes_selected_ref}"
}

# A declined step that leaves saved state (keys, a lock or recovery files)
# reports it; one that changed nothing passes no message and returns straight
# to the menu. Pass "flow" as $4 for a step that changes nothing active, which
# Quick then treats as confirmed.
cntools_kes_confirm() {
  local prompt="$1" default="$2" stopped="${3:-}" kes_confirmation_status=0
  if [[ "${4:-}" == flow ]]; then cntools_ui_flow_confirm "${prompt}" "${default}" || kes_confirmation_status=$?
  else cntools_ui_confirm "${prompt}" "${default}" || kes_confirmation_status=$?; fi
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
    [[ -z "${CNTOOLS_POOL_WARNINGS[CNTOOLS_KES_INDEX]:-}" ]] || cntools_table_pair Attention "${CNTOOLS_POOL_WARNINGS[CNTOOLS_KES_INDEX]}" warning
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

# ROLE is a theme role (success, warning, danger…): an unknown one would drop
# the Result row from the table.
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

# Issuing or importing needs the request's counter verified, asked once and
# not before Discard. 1: declined (result shown); 2: stale, still discardable.
CNTOOLS_KES_COUNTER_VERIFIED=N
cntools_kes_counter_ready() {
  [[ "${CNTOOLS_KES_COUNTER_VERIFIED}" != Y ]] || return 0
  if cntools_kes_counter_verify; then CNTOOLS_KES_COUNTER_VERIFIED=Y; return 0; fi
  [[ -n "${CNTOOLS_POOL_WRITE_ERROR}" ]] || return 1
  # The redraw repeats this warning.
  cntools_ui_render_status warn "${CNTOOLS_POOL_WRITE_ERROR} Discard this request to start a new rotation."
  CNTOOLS_POOL_WRITE_ERROR=''
  return 2
}

# A first-certificate or offline-signing lock left by an interrupted or
# failed operation, or this node's rotation lock left while preparing.
# Release is offered only when nothing was issued or the live cold.counter
# already moved past the recovered certificate's counter, so no new
# certificate can reuse it; the recovery folder is kept.
cntools_kes_lock_offer() {
  local choice='' counter='' certificate='None' reason=''
  cntools_ui_spin_function 'Inspecting the certificate lock…' cntools_kes_lock_inspect ||
    { cntools_kes_result 'The certificate lock could not be inspected. Check the CNTools state folder.' danger; return 0; }
  cntools_pool_file_name_into counter counter
  if [[ "${CNTOOLS_KES_LOCK_CERT}" == Y ]]; then
    certificate="Issued · counter ${CNTOOLS_KES_LOCK_CERT_COUNTER:-unreadable}"
  fi
  {
    cntools_table_pair Pool "${CNTOOLS_POOL_NAMES[CNTOOLS_KES_INDEX]}" identifier
    cntools_table_pair 'Pending operation' "${CNTOOLS_KES_LOCK_KIND}" warning
    cntools_table_pair Lock "${CNTOOLS_KES_LOCK_PATH}" identifier
    if [[ -n "${CNTOOLS_KES_STAGE}" ]]; then cntools_table_pair Recovery "${CNTOOLS_KES_STAGE}" identifier
    else cntools_table_pair Recovery 'Not found' warning; fi
    cntools_table_pair 'Certificate in recovery' "${certificate}" value
    cntools_table_pair "Live counter · ${counter}" "$(cntools_number_format "${CNTOOLS_KES_DISK_NEXT}")" number
  } | cntools_table_render 'Certificate lock'
  if [[ "${CNTOOLS_KES_LOCK_RELEASABLE}" != Y ]]; then
    if [[ "${CNTOOLS_KES_LOCK_KIND}" == 'KES rotation in progress' ]]; then
      reason='This rotation now has a recorded state. Reopen Pool → Rotate to continue it.'
    elif [[ -z "${CNTOOLS_KES_STAGE}" ]]; then
      reason='CNTools cannot tell what this lock protects. Inspect it and the recovery folder; remove the lock by hand only when no certificate is pending.'
    elif [[ -z "${CNTOOLS_KES_LOCK_CERT_COUNTER}" ]]; then
      reason="A certificate is in the recovery folder, but its counter could not be read. Inspect it and never reset ${counter}; remove the lock by hand only after resolving it."
    else
      reason="The certificate in recovery uses issue counter ${CNTOOLS_KES_LOCK_CERT_COUNTER}, but ${counter} (${CNTOOLS_KES_DISK_NEXT}) has not moved past it, so a new certificate could reuse that counter with another KES key. Inspect the recovery folder; remove the lock by hand only once ${counter} is above ${CNTOOLS_KES_LOCK_CERT_COUNTER}. Never reset the counter."
    fi
    cntools_ui_render_status warn "${reason}"
    cntools_ui_wait; return 0
  fi
  if [[ "${CNTOOLS_KES_LOCK_CERT}" == Y ]]; then
    reason="The recovered certificate's counter (${CNTOOLS_KES_LOCK_CERT_COUNTER}) is already behind ${counter} (${CNTOOLS_KES_DISK_NEXT}), so no new certificate can reuse it"
  elif [[ "${CNTOOLS_KES_LOCK_KIND}" == 'Interrupted KES rotation' ]]; then
    reason='Preparation stopped before any certificate was issued'
  else
    reason='No certificate was issued'
  fi
  cntools_ui_render_status info "${reason}. The lock can be released and a new certificate prepared; the recovery folder is kept."
  [[ "${CNTOOLS_KES_LOCK_BUSY}" != Y ]] ||
    cntools_ui_render_status warn 'The lock is marked busy: another CNTools session may still be working on this pool. Release it only if none is running.'
  local choice_status=0
  cntools_kes_choose choice 'Certificate lock' 'Release lock' 'Keep lock' || choice_status=$?
  ((choice_status != 130)) || return 130
  ((choice_status == 0)) && [[ "${choice}" == 'Release lock' ]] || return 0
  if ! cntools_ui_spin_function 'Releasing the certificate lock…' cntools_kes_lock_force_release; then
    cntools_kes_result "${CNTOOLS_POOL_WRITE_ERROR:-The lock could not be released.}" danger; return 0
  fi
  cntools_ui_render_status success 'Lock released · recovery folder kept. Open Pool → Rotate again to issue a certificate.'
  cntools_ui_wait
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
      cntools_kes_confirm "Use independently verified KES period ${normalized}?" false || return 1
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

# What an installed rotation changed, and whether the node runs it yet.
cntools_kes_installed_summary() {
  local node_state="$1" role="$2" counter=''
  cntools_pool_file_name_into counter counter
  {
    cntools_table_pair Pool "${CNTOOLS_POOL_NAMES[CNTOOLS_KES_INDEX]}" identifier
    cntools_table_pair 'KES key' 'Replaced (hot.skey, hot.vkey)' success
    cntools_table_pair 'Operational certificate' "Replaced · counter ${CNTOOLS_KES_NEXT}, start period $(cntools_number_format "${CNTOOLS_KES_START}")" success
    cntools_table_pair "Next issue counter · ${counter}" "$((CNTOOLS_KES_NEXT+1))" number
    cntools_table_pair 'Running node' "${node_state}" "${role}"
    cntools_table_pair Unchanged 'Cold and VRF keys' muted
    [[ -z "${CNTOOLS_KES_STAGE}" ]] || cntools_table_pair 'Recovery copy' "${CNTOOLS_KES_STAGE}" identifier
  } | cntools_table_render 'KES rotation installed'
  cntools_ui_render_status info 'If another system runs this pool as block producer, copy the new hot.skey and op.cert there and reload it. Never roll the issue counter back.'
  cntools_ui_wait
}

# cardano-node re-reads its KES key and operational certificate on SIGHUP.
cntools_kes_reload_offer() {
  local unit="${CNTOOLS_SERVICE%.service}.service" pid='' choice='' status=0
  local manual="sudo kill -SIGHUP \$(systemctl show --property MainPID --value ${unit})"
  if cntools_kes_systemd_pid_into pid "${unit}"; then
    cntools_kes_choose choice 'Load the new KES key' 'Reload the node now (SIGHUP)' 'I will reload or restart it myself' || choice=''
    if [[ "${choice}" == 'Reload the node now (SIGHUP)' ]]; then
      # The node may have restarted while the question was open: signal the
      # unit's current main process, never a PID read before the prompt.
      pid=''
      if ! cntools_kes_systemd_pid_into pid "${unit}"; then
        cntools_ui_render_status warn "${unit} is no longer active, so no reload signal was sent. Start the node; it loads the new key and certificate on startup."
        cntools_kes_installed_summary 'Not running · loads the new key when started' warning; return 0
      fi
      if kill -HUP "${pid}" 2>/dev/null || { command -v sudo >/dev/null 2>&1 && sudo -n kill -HUP "${pid}" 2>/dev/null; }; then
        cntools_transaction_log POOL "KES reload signal sent unit=${unit} pid=${pid}"
        cntools_ui_spin_function 'Waiting for the node to load the new certificate…' cntools_kes_reload_confirmed || status=$?
        if ((status == 0)); then
          cntools_kes_installed_summary "Reloaded · now using the new key (confirmed by node metrics)" success; return 0
        fi
        cntools_ui_render_status warn "The reload signal was sent, but node metrics did not show start period ${CNTOOLS_KES_START}. Check gLiveView or the node log, and restart the node if it did not reload."
        cntools_kes_installed_summary 'Reload signal sent · not confirmed' warning; return 0
      fi
      cntools_ui_render_status warn "CNTools could not signal ${unit} (PID ${pid}). Run: ${manual}"
      cntools_kes_installed_summary 'Still using the previous key · reload or restart it' warning; return 0
    fi
    cntools_ui_render_status info "Load the new set by reloading the node (${manual}) or restarting it."
  else
    cntools_ui_render_status info "No active systemd unit ${unit} was found for this node. Load the new set by sending SIGHUP to the cardano-node process or restarting it."
  fi
  cntools_kes_installed_summary 'Still using the previous key · reload or restart it' warning
}

# Nothing was issued for a prepared or awaiting request, so it can be
# abandoned: the lock is released and its recovery folder kept.
cntools_kes_discard_offer() {
  cntools_ui_render_status warn 'Discarding releases the rotation lock so a new rotation can start. Active node files and the issue counter stay unchanged, and the prepared KES keys stay in the recovery folder. Never install a certificate signed for this request.'
  cntools_kes_confirm 'Discard this KES request?' false || return 0
  cntools_transaction_log CHOICE "KES request discard approved recovery=${CNTOOLS_KES_STAGE}"
  if ! cntools_ui_spin_function 'Releasing the rotation lock…' cntools_kes_discard; then
    cntools_kes_result "${CNTOOLS_POOL_WRITE_ERROR:-The request could not be discarded. Inspect the lock and recovery folder.}" danger; return 0
  fi
  cntools_kes_result 'Request discarded · active keys and counter unchanged; recovery folder kept' success
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
        choices+=('Prepare offline hand-off' 'Import signed response' 'Discard this request' 'Return without changing active keys')
        # Esc leaves the pending rotation as the review shows it.
        cntools_kes_choose choice 'Continue rotation' "${choices[@]}" || { status=$?; ((status == 130)) || status=0; return "${status}"; }
        case "${choice}" in
          'Issue certificate now')
            status=0; cntools_kes_counter_ready || status=$?
            ((status != 1)) || return 0; ((status == 0)) || { status=0; continue; }
            cntools_ui_render_status warn 'Issuing a certificate advances the real counter, even if you postpone installation. Keep its recovery copy; never restore an older counter.'
            cntools_kes_confirm 'Issue this replacement certificate?' false \
              'Certificate not issued. The prepared KES keys stay in recovery; reopen Pool → Rotate to continue.' || return 0
            if [[ "${CNTOOLS_KES_KIND}" == hardware ]]; then cntools_ui_render_status info 'Connect and unlock the hardware device, open Cardano and approve certificate issuance.'; fi
            cntools_ui_spin_function 'Issuing and validating the KES certificate…' cntools_kes_issue || return 1 ;;
          'Prepare offline hand-off') cntools_kes_offline_instructions; return $? ;;
          'Import signed response')
            status=0; cntools_kes_counter_ready || status=$?
            ((status != 1)) || return 0; ((status == 0)) || { status=0; continue; }
            cntools_ui_pick_path directory 'Signed response directory' 'Choose the folder containing op.cert and cold.counter.' "${CNTOOLS_KES_DIRECTORY}" directory || {
              status=$?; ((status != 1)) || { status=0; continue; }; return 0; }
            cntools_ui_spin_function 'Validating the returned certificate and counter…' cntools_kes_import_response "${directory}" || return 1 ;;
          'Discard this request') cntools_kes_discard_offer; return $? ;;
          *) return 0 ;;
        esac ;;
      awaiting)
        cntools_kes_choose choice 'Offline rotation' 'Import signed response' 'Show hand-off instructions' 'Discard this request' 'Return without changing active keys' ||
          { status=$?; ((status == 130)) || status=0; return "${status}"; }
        case "${choice}" in
          'Import signed response')
            status=0; cntools_kes_counter_ready || status=$?
            ((status != 1)) || return 0; ((status == 0)) || { status=0; continue; }
            cntools_ui_pick_path directory 'Signed response directory' 'Choose the folder containing op.cert and cold.counter.' "${CNTOOLS_KES_DIRECTORY}" directory || {
              status=$?; ((status != 1)) || { status=0; continue; }; return 0; }
            cntools_ui_spin_function 'Validating the returned certificate and counter…' cntools_kes_import_response "${directory}" || return 1 ;;
          'Show hand-off instructions') cntools_kes_offline_instructions; return $? ;;
          'Discard this request') cntools_kes_discard_offer; return $? ;;
          *) return 0 ;;
        esac ;;
      issuing)
        if cntools_kes_issuing_reset; then
          # The redraw shows this warning above the prepared request's menu.
          cntools_ui_render_status warn 'Issuance was interrupted before a certificate was written, so nothing was issued and the counter is unchanged. Issue the certificate again or discard the request.'
          continue
        fi
        cntools_ui_render_status warn 'Issuance was interrupted. CNTools will only validate existing recovery output and preserve its advanced counter; it will not issue again.'
        cntools_kes_confirm 'Validate and recover the already issued certificate?' false \
          'Recovery not started. The interrupted issuance stays locked; reopen Pool → Rotate to recover it.' || return 0
        cntools_ui_spin_function 'Checking existing certificate recovery files…' cntools_kes_consume_counter || {
          cntools_kes_error 'Recovery is incomplete or invalid. Inspect it manually; keep the lock and never restore an older counter.'; return 1;
        } ;;
      issued|publishing) cntools_kes_install; return $? ;;
      complete|discarded)
        # Only the lock was left; the request needs nothing more.
        cntools_kes_lock_release || return 1
        cntools_ui_render_status success "$([[ "${phase}" == complete ]] && printf 'The finished rotation' || printf 'The discarded request') released its lock · recovery folder kept. Open Pool → Rotate again for a new rotation."
        cntools_ui_wait; return 0 ;;
      *) cntools_kes_error 'The pending rotation phase is incomplete. Inspect its recovery directory; no new issuance was attempted.'; return 1 ;;
    esac
  done
  return "${status}"
}

cntools_pool_action_rotate() {
  local selected='' choice='' request='' status=0
  CNTOOLS_KES_STAGE='' CNTOOLS_KES_BUSY='' CNTOOLS_KES_START='' CNTOOLS_KES_CURRENT=''
  CNTOOLS_KES_COUNTER_APPROVED=N CNTOOLS_KES_INSTALL_APPROVED=N CNTOOLS_KES_PERIOD_SOURCE='' CNTOOLS_KES_COUNTER_VERIFIED=N
  cntools_ui_action_begin Rotate '/ Pool / Rotate'
  cntools_kes_environment || { cntools_kes_result "${CNTOOLS_POOL_WRITE_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-KES prerequisites unavailable}}" danger; return 0; }
  cntools_ui_spin_function 'Reading pool identities…' cntools_pool_catalog_build || return 1
  (( ${#CNTOOLS_POOL_NAMES[@]} != 0 )) || { cntools_pool_empty_notice; return 0; }
  cntools_pool_choose_into selected || status=$?
  ((status != 1)) || return 0; ((status == 0)) || return "${status}"
  if ! cntools_ui_spin_function 'Validating pool cold identity and counter…' cntools_kes_identity "${selected}"; then
    cntools_kes_result "${CNTOOLS_POOL_WRITE_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-Invalid pool signing material or counter.}}" danger; return 0
  fi
  cntools_ui_spin_function 'Checking current KES health and counter…' cntools_pool_inspect_catalog "${selected}" || return 1
  cntools_ui_spin_function 'Checking operational certificate…' cntools_pool_health_collect "${selected}" || return 1
  if cntools_pool_legacy_opcert_lock "${CNTOOLS_KES_DIRECTORY}"; then
    cntools_kes_result "An earlier CNTools build left an operational-certificate lock in ${CNTOOLS_KES_DIRECTORY}/.cntools-opcert-lock. Finish or inspect that operation manually; no new certificate will be issued." danger
    return 0
  fi
  local lock=''
  cntools_pool_folder_name_supported "${CNTOOLS_KES_DIRECTORY}" || {
    cntools_kes_result "$(cntools_pool_folder_unsupported_message "${CNTOOLS_KES_DIRECTORY}")" danger; return 0;
  }
  cntools_pool_opcert_lock_into lock "${CNTOOLS_KES_DIRECTORY}" || {
    cntools_kes_result 'The owner-only CNTools state folder (.cntools in the node home) is unavailable.' danger; return 0;
  }
  if [[ -e "${lock}" || -L "${lock}" ]]; then
    # Another operation's lock, or this node's rotation interrupted while
    # preparing (no recorded phase): inspect it and offer a safe release.
    if cntools_kes_lock_foreign || cntools_kes_lock_interrupted; then cntools_kes_lock_offer; return $?
    elif cntools_kes_pending_load; then cntools_kes_continue || status=$?
    else status=2; fi
  else
    cntools_kes_counter_from_ledger || true
    cntools_kes_review || return 1
    # Signing needs the cold key (file or hardware wallet) on this system.
    local -a workflows=()
    [[ -z "${CNTOOLS_KES_SOURCE}" ]] || workflows+=('Rotate now')
    workflows+=('Prepare offline request')
    [[ -z "${CNTOOLS_KES_SOURCE}" ]] || workflows+=('Sign an offline request')
    local only_workflow=N
    if (( ${#workflows[@]} == 1 )); then
      choice="${workflows[0]}" only_workflow=Y
      cntools_transaction_log CHOICE "KES workflow: ${choice} (only option)"
    else
      cntools_kes_choose choice 'KES workflow' "${workflows[@]}" Cancel || return $?
      [[ "${choice}" != Cancel ]] || return 0
    fi
    # Said before the counter and period questions, not after them.
    [[ "${only_workflow}" != Y || "${CNTOOLS_KES_ENCRYPTED}" != Y ]] ||
      cntools_ui_render_status info 'The cold signing key is encrypted, so only an offline request can be prepared here. To rotate or sign on this system, press Esc and use Pool → Decrypt first.'
    # The hardware cold key signs through cardano-hw-cli: check it before any input.
    if [[ "${choice}" != 'Prepare offline request' && "${CNTOOLS_KES_KIND}" == hardware ]] && ! cntools_transaction_require_hwcli; then
      cntools_kes_result "${CNTOOLS_TRANSACTION_ERROR:-cardano-hw-cli is required to sign with the hardware cold key.} Prepare an offline request instead, or install it and try again." danger
      return 0
    fi
    if [[ "${choice}" != 'Sign an offline request' ]] && ! cntools_kes_counter_choose; then
      [[ -z "${CNTOOLS_POOL_WRITE_ERROR}" ]] || cntools_kes_result "${CNTOOLS_POOL_WRITE_ERROR}" danger
      return 0
    fi
    case "${choice}" in
      'Rotate now')
        cntools_kes_choose_period || return 0
        cntools_kes_review || return 1
        cntools_ui_render_status warn "Rotation generates new KES keys and issues certificate ${CNTOOLS_KES_NEXT}, which permanently advances the cold counter. Active node files change only when you install the new set."
        cntools_kes_confirm "Rotate KES now, starting at period ${CNTOOLS_KES_START}?" false || return 0
        cntools_ui_spin_function 'Preparing and validating replacement KES keys…' cntools_kes_prepare "${CNTOOLS_KES_START}" || status=$?
        if ((status == 0)); then
          [[ "${CNTOOLS_KES_KIND}" != hardware ]] || cntools_ui_render_status info 'Connect and unlock the hardware device, open Cardano and approve certificate issuance.'
          cntools_ui_spin_function 'Issuing and validating the KES certificate…' cntools_kes_issue || status=$?
        fi
        ((status != 0)) || cntools_kes_continue || status=$? ;;
      'Prepare offline request')
        cntools_kes_choose_period || return 0
        cntools_kes_review || return 1
        if [[ "${only_workflow}" == Y && "${CNTOOLS_KES_ENCRYPTED}" == Y ]]; then
          cntools_ui_render_status info 'The cold signing key is encrypted, so this prepares an offline request for the signing system. To rotate on this system instead, answer No and use Pool → Decrypt first.'
        elif [[ "${only_workflow}" == Y ]]; then
          cntools_ui_render_status info 'No cold signing key or hardware wallet file for this pool is on this system, so this prepares an offline request for the signing system.'
        fi
        # This generates keys and takes the certificate lock. Quick skips the
        # question only when the operator picked this workflow from the menu.
        cntools_kes_confirm "Prepare an offline request starting at KES period ${CNTOOLS_KES_START}? The counter advances only when the cold key signs it." false \
          '' "$([[ "${only_workflow}" == Y ]] || printf flow)" || return 0
        cntools_ui_spin_function 'Preparing and validating replacement KES keys…' cntools_kes_prepare "${CNTOOLS_KES_START}" || status=$?
        ((status != 0)) || cntools_kes_offline_instructions || status=$? ;;
      'Sign an offline request')
        cntools_ui_pick_path request 'Offline request directory' 'Choose the public request folder copied from the node.' "${CNTOOLS_KES_DIRECTORY}" directory || return $?
        cntools_kes_request_validate "${request}" || { cntools_kes_result 'The request does not match this pool, network or counter.' danger; return 0; }
        CNTOOLS_KES_START="$(jq -r '.startPeriod' "${request}/request.json")"
        CNTOOLS_KES_NEXT="$(jq -r '.issueCounter' "${request}/request.json")" CNTOOLS_KES_COUNTER_SOURCE='Offline request'
        cntools_kes_review || return 1
        cntools_ui_render_status warn "Check the requested KES period against the node. The node chose issue counter ${CNTOOLS_KES_NEXT}; signing sets this system's cold.counter (now ${CNTOOLS_KES_DISK_NEXT}) to $((CNTOOLS_KES_NEXT+1)). Only return the public certificate and advanced counter, never cold or KES private keys."
        cntools_kes_confirm 'Sign this offline certificate request and advance the real counter?' false || return 0
        CNTOOLS_KES_COUNTER_APPROVED=Y
        [[ "${CNTOOLS_KES_KIND}" != hardware ]] || cntools_ui_render_status info 'Connect and unlock the hardware device, open Cardano and approve certificate issuance.'
        cntools_ui_spin_function 'Issuing the offline operational certificate…' cntools_kes_sign_request "${request}" || status=$?
        if ((status == 0)); then
          { cntools_table_pair 'Signed response directory' "${CNTOOLS_KES_STAGE}/replacement" identifier; cntools_table_pair 'Return files' 'op.cert and cold.counter' value; } | cntools_table_render 'Offline result'
          cntools_ui_wait
        fi ;;
    esac
  fi
  ((status != 130)) || return 130
  if ((status != 0)); then
    cntools_kes_result "${CNTOOLS_POOL_WRITE_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-KES operation failed.} Recovery files were kept; reopen Pool → Rotate to continue, or inspect ${CNTOOLS_LOG}.}" danger
  fi
  return 0
}
