#!/usr/bin/env bash
# Guided direct-address Send workflow. All amounts are reviewed before signing.
# shellcheck disable=SC2034

cntools_send_begin() { cntools_ui_action_begin "Send" "/ Funds / Send"; }

cntools_send_confirm() {
  local status=0
  cntools_ui_confirm "$1" || status=$?
  cntools_transaction_log CHOICE "Send confirmation=${1} status=${status}"
  return "${status}"
}

cntools_send_choose() {
  local output_name="${1:-}" prompt="${2:-}" status=0
  shift 2
  cntools_ui_choose "${output_name}" "${prompt}" "$@" || status=$?
  if (( status == 0 )); then
    local -n chosen_ref="${output_name}"
    cntools_transaction_log CHOICE "Send ${prompt} selected=${chosen_ref}"
  fi
  return "${status}"
}

cntools_send_review_virtual() {
  local resolution="$1" lease="" expires="" expires_label="" public="" TZ=UTC
  [[ "$(jq -r '.type' <<< "${resolution}")" == virtual-subhandle ]] || return 0
  lease="$(jq -r '.virtual.leaseStatus' <<< "${resolution}")"
  expires="$(jq -r '.virtual.expiresTimeMs' <<< "${resolution}")"
  public="$(jq -r '.virtual.publicMint' <<< "${resolution}")"
  printf -v expires_label '%(%Y-%m-%d %H:%M:%S UTC)T' "$((expires/1000))"
  if [[ "${public}" == true ]]; then
    cntools_ui_render_field 'Virtual lease' "Public · ${lease}"
  else
    cntools_ui_render_field 'Virtual lease' "Private · ${lease}"
    cntools_ui_render_status warn 'The parent Handle owner can revoke or reassign this private subhandle at any time.'
  fi
  cntools_ui_render_field 'Lease expiry' "${expires_label}"
  if [[ "${lease}" == expired ]]; then
    cntools_ui_render_status warn 'The lease has expired. The current datum still resolves, but the subhandle may be revoked or reassigned. Expiry does not redirect to its parent.'
  fi
  cntools_ui_render_status info 'Koios supplies the current datum destination. Confirm it with the recipient; an alias can change after our last check.'
  cntools_send_confirm 'Use this current virtual-subhandle destination?'
}

cntools_send_prompt_recipient() {
  local index="${1:-}" choice="" address="" label="" note="" selected="" allow_script=N
  local directory="" entered="" handle_name="" resolution=""
  cntools_send_choose choice "Recipient type" "CNTools wallet" "External address" "ADA Handle" || return $?
  if [[ "${choice}" == "CNTools wallet" ]]; then
    cntools_wallet_choose selected || return $?
    directory="${CNTOOLS_WALLET_PATHS[selected]}"
    cntools_wallet_prepare_selected_material "${directory}" || {
      cntools_ui_render_status warn "The recipient's public artifacts could not be prepared safely. Check the log."; return 2;
    }
    cntools_wallet_address_primary_into "${directory}" address label note || {
      cntools_ui_render_status warn "This wallet has no usable receiving address."; return 2;
    }
    if [[ "${address}" == stake* ]]; then
      cntools_ui_render_status warn "A stake-only wallet cannot receive a funds transfer. A payment key or payment script is needed."
      return 2
    fi
    if [[ "$(cntools_wallet_type "${directory}")" == MultiSig ]]; then
      cntools_recipient_native_wallet_matches "${directory}" "${address}" || {
        cntools_ui_render_status warn "The cached recipient address does not match a valid local native script."; return 2;
      }
      allow_script=Y
    fi
    label="${CNTOOLS_WALLET_NAMES[selected]} · ${label}"
  elif [[ "${choice}" == "ADA Handle" ]]; then
    cntools_ui_input entered 'ADA Handle' '$name or $child@parent' || return $?
    if ! cntools_ui_spin_function 'Resolving Handle through Koios…' cntools_handle_resolve_into address resolution "${entered}"; then
      cntools_ui_render_status warn "${CNTOOLS_HANDLE_ERROR:-Handle resolution failed; no destination was selected.}"
      return 2
    fi
    handle_name="$(jq -r '.handle' <<< "${resolution}")"
    label="${handle_name} · $(jq -r '.type' <<< "${resolution}") · Koios"
  else
    cntools_ui_input entered "Receiving address" "addr…" || return $?
    cntools_recipient_trim_into address "${entered}" || return 2
    label="External address"
  fi
  cntools_recipient_validate "${address}" "${allow_script}" || {
    cntools_ui_render_status warn "Use a valid payment address for this network. Reward addresses and external script destinations requiring datum handling are not supported."
    return 2
  }
  if [[ "${address}" == "${CNTOOLS_SEND_ADDRESS}" || "${address}" == "${CNTOOLS_SEND_PAYMENT}" ]]; then
    cntools_send_confirm "This is the source wallet. Send back to this wallet?" || return $?
  fi
  cntools_ui_render_field "Recipient" "${label}"
  cntools_ui_render_field "Address" "${address}"
  [[ -z "${resolution}" ]] || cntools_send_review_virtual "${resolution}" || return $?
  if [[ "${CNTOOLS_NETWORK}" != mainnet ]]; then
    cntools_ui_render_status info "Testnet addresses do not distinguish preview, preprod and guild. Confirm the recipient uses ${CNTOOLS_NETWORK}."
  fi
  CNTOOLS_SEND_ADDRESSES[index]="${address}"
  CNTOOLS_SEND_LABELS[index]="${label}"
  CNTOOLS_SEND_HANDLES[index]="${handle_name}"
  CNTOOLS_SEND_RESOLUTIONS[index]="${resolution}"
  cntools_transaction_log CHOICE "Send recipient=$((index+1)) type=${choice} address=${address}"
}

cntools_send_prompt_amounts() {
  local index="${1:-}" choice="" entered="" units="" asset="" option="" i=0
  local -a options=()
  if (( index == 0 && ${#CNTOOLS_SEND_ADDRESSES[@]} == 1 )); then
    cntools_send_choose choice "Amount mode" "Exact amounts" "Max ADA" "Send everything" || return $?
    case "${choice}" in
      "Exact amounts") CNTOOLS_SEND_MODE=exact ;;
      "Max ADA") CNTOOLS_SEND_MODE=max ;;
      "Send everything") CNTOOLS_SEND_MODE=sweep ;;
    esac
  fi
  if [[ "${CNTOOLS_SEND_MODE}" == exact ]]; then
    while true; do
      cntools_ui_input entered "ADA amount (0 = minimum ADA for this output)" "0" || return $?
      [[ -n "${entered}" ]] || entered=0
      if cntools_number_units_into units "${entered}" 6 &&
         cntools_uint_greater_equal "${CNTOOLS_FUNDING_TOTAL}" "${units}"; then break; fi
      cntools_transaction_log CHOICE "Send invalid ADA amount rejected"
      cntools_ui_render_status warn "Enter an available non-negative ADA amount, with at most six decimal places."
    done
    CNTOOLS_SEND_AMOUNTS[index]="${units}"
    cntools_transaction_log CHOICE "Send recipient=$((index+1)) lovelace=${units}"
  else
    CNTOOLS_SEND_AMOUNTS[index]=0
  fi
  for asset in "${CNTOOLS_FUNDING_ASSET_IDS[@]}"; do unset 'CNTOOLS_SEND_ASSETS['"${index}|${asset}"']'; done
  [[ "${CNTOOLS_SEND_MODE}" != sweep ]] || return 0
  while (( ${#CNTOOLS_FUNDING_ASSET_IDS[@]} > 0 )); do
    options=("Done selecting assets")
    for asset in "${CNTOOLS_FUNDING_ASSET_IDS[@]}"; do
      options+=("${asset} · available $(cntools_number_format "${CNTOOLS_FUNDING_ASSETS[${asset}]}") · selected $(cntools_number_format "${CNTOOLS_SEND_ASSETS[${index}|${asset}]:-0}")")
    done
    cntools_send_choose option "Native assets (quantities in smallest units)" "${options[@]}" || return $?
    [[ "${option}" != "${options[0]}" ]] || break
    asset=""
    for i in "${!CNTOOLS_FUNDING_ASSET_IDS[@]}"; do
      [[ "${option}" != "${options[i+1]}" ]] || asset="${CNTOOLS_FUNDING_ASSET_IDS[i]}"
    done
    [[ -n "${asset}" ]] || return 2
    while true; do
      cntools_ui_input entered "Smallest-unit quantity (All or 0 to remove)" "All" || return $?
      if [[ "${entered,,}" == all ]]; then units="${CNTOOLS_FUNDING_ASSETS[${asset}]}"
      elif ! cntools_number_units_into units "${entered}" 0; then
        cntools_ui_render_status warn "Enter a whole smallest-unit quantity, optionally with commas, or All."; continue
      fi
      if cntools_uint_greater_equal "${CNTOOLS_FUNDING_ASSETS[${asset}]}" "${units}"; then break; fi
      cntools_ui_render_status warn "That exceeds the wallet's available quantity."
    done
    CNTOOLS_SEND_ASSETS["${index}|${asset}"]="${units}"
    cntools_transaction_log CHOICE "Send recipient=$((index+1)) asset=${asset} quantity=${units}"
  done
}

cntools_send_render_recipients() {
  local widths="" index=0 asset="" amount=""
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  {
    printf 'Recipient / property\tValue\n'
    for index in "${!CNTOOLS_SEND_ADDRESSES[@]}"; do
      cntools_transaction_ui_styled_row "$((index+1)) · Recipient" "${CNTOOLS_SEND_LABELS[index]}" identifier
      cntools_transaction_ui_styled_row "Address" "${CNTOOLS_SEND_ADDRESSES[index]}" address
      amount="$(cntools_wallet_format_lovelace "${CNTOOLS_SEND_AMOUNTS[index]}")"
      cntools_transaction_ui_styled_row "ADA" "${amount}" number
      for asset in "${CNTOOLS_FUNDING_ASSET_IDS[@]}"; do
        [[ "${CNTOOLS_SEND_ASSETS[${index}|${asset}]:-0}" != 0 ]] || continue
        cntools_transaction_ui_styled_row "Asset policy.name (hex)" "${asset}" identifier
        cntools_transaction_ui_styled_row "Smallest-unit quantity" \
          "$(cntools_number_format "${CNTOOLS_SEND_ASSETS[${index}|${asset}]}")" number
      done
    done
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
}

cntools_send_remove_recipient() {
  local removed="${1:-}" index=0 asset="" target=0
  local -a addresses=() labels=() amounts=() handles=() resolutions=()
  local -A quantities=()
  for index in "${!CNTOOLS_SEND_ADDRESSES[@]}"; do
    (( index != removed )) || continue
    addresses+=("${CNTOOLS_SEND_ADDRESSES[index]}"); labels+=("${CNTOOLS_SEND_LABELS[index]}")
    amounts+=("${CNTOOLS_SEND_AMOUNTS[index]}")
    handles+=("${CNTOOLS_SEND_HANDLES[index]:-}"); resolutions+=("${CNTOOLS_SEND_RESOLUTIONS[index]:-}")
    for asset in "${CNTOOLS_FUNDING_ASSET_IDS[@]}"; do
      quantities["${target}|${asset}"]="${CNTOOLS_SEND_ASSETS[${index}|${asset}]:-0}"
    done
    target=$((target+1))
  done
  CNTOOLS_SEND_ADDRESSES=("${addresses[@]}"); CNTOOLS_SEND_LABELS=("${labels[@]}"); CNTOOLS_SEND_AMOUNTS=("${amounts[@]}")
  CNTOOLS_SEND_HANDLES=("${handles[@]}"); CNTOOLS_SEND_RESOLUTIONS=("${resolutions[@]}")
  CNTOOLS_SEND_ASSETS=()
  for asset in "${!quantities[@]}"; do CNTOOLS_SEND_ASSETS["${asset}"]="${quantities[${asset}]}"; done
}

cntools_send_edit_recipients() {
  local command="Review" index=0 selected="" status=0
  local -a options=()
  (( ${#CNTOOLS_SEND_ADDRESSES[@]} > 0 )) || command=Add
  while true; do
    if [[ "${command}" == Add || "${command}" == Edit ]]; then
      if [[ "${command}" == Add ]]; then index="${#CNTOOLS_SEND_ADDRESSES[@]}"; fi
      (( index < 20 )) || { cntools_ui_render_status warn "At most 20 recipients per transfer."; command=Review; continue; }
      status=0
      cntools_send_prompt_recipient "${index}" || status=$?
      (( status != 1 )) || return 1
      if (( status != 0 )); then command=Review; continue; fi
      cntools_send_prompt_amounts "${index}" || return $?
    elif [[ "${command}" == Remove ]]; then
      cntools_send_remove_recipient "${index}" || return 2
    fi
    cntools_send_begin
    cntools_send_render_recipients || return 2
    cntools_ui_render_status info "Amounts use exact smallest units; minimum ADA adjustments and the final fee will be shown after building. Rewards and deposits are not included."
    cntools_send_metadata_render || return 2
    options=("Continue" "Edit" "Remove" "Message / metadata" "Cancel")
    [[ "${CNTOOLS_SEND_MODE}" != exact ]] || options=("Continue" "Add" "Edit" "Remove" "Message / metadata" "Cancel")
    if (( ${#CNTOOLS_SEND_ADDRESSES[@]} == 0 )); then options=("Add" "Cancel"); CNTOOLS_SEND_MODE=exact; fi
    cntools_send_choose command "Recipients" "${options[@]}" || return $?
    case "${command}" in
      Continue) return 0 ;;
      Cancel) return 1 ;;
      'Message / metadata')
        status=0
        cntools_send_metadata_edit || status=$?
        (( status <= 1 )) || return "${status}"
        ;;
      Edit|Remove)
        options=()
        for index in "${!CNTOOLS_SEND_ADDRESSES[@]}"; do options+=("$((index+1)) · ${CNTOOLS_SEND_LABELS[index]}"); done
        cntools_send_choose selected "Select recipient" "${options[@]}" || return $?
        for index in "${!options[@]}"; do [[ "${selected}" != "${options[index]}" ]] || break; done
        ;;
    esac
  done
}

cntools_send_prompt_output() {
  local output_name="${1:-}" default="${2:-}" entered="" normalized=""
  local -n path_ref="${output_name}"
  while true; do
    cntools_ui_input entered "New transaction package path" "${default}" || return $?
    [[ -n "${entered}" ]] || entered="${default}"
    if cntools_transaction_ui_normalize_path_into normalized "${entered}" &&
       cntools_transaction_output_path_safe "${normalized}"; then
      path_ref="${normalized}"
      cntools_transaction_ui_log_path "Send output selected" "${normalized}"
      return 0
    fi
    cntools_ui_render_status warn "Choose a new file in an owned writable directory protected from group/public writes. Existing files are never overwritten."
  done
}

cntools_send_recheck() {
  local reference=""
  local -a selected_refs=("${CNTOOLS_COIN_SELECTED_REFS[@]}")
  cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" || return 1
  (( CNTOOLS_FUNDING_SLOT < CNTOOLS_SEND_EXPIRY )) || { cntools_send_fail "The transfer expired. Build and review a new transaction."; return 1; }
  for reference in "${selected_refs[@]}"; do
    [[ -n "${CNTOOLS_UTXO_INDEX_BY_REF[${reference}]+x}" ]] || {
      cntools_send_fail "A selected input is no longer available. Build and review a new transaction."; return 1;
    }
  done
  cntools_send_recheck_handles
}

cntools_send_recheck_handles() {
  local index=0 resolved="" evidence="" old_state="" new_state="" previous=""
  for index in "${!CNTOOLS_SEND_HANDLES[@]}"; do
    [[ -n "${CNTOOLS_SEND_HANDLES[index]}" ]] || continue
    cntools_handle_resolve_into resolved evidence "${CNTOOLS_SEND_HANDLES[index]}" || {
      cntools_send_fail "${CNTOOLS_HANDLE_ERROR:-Could not recheck the Handle destination.}"; return 1;
    }
    [[ "${resolved}" == "${CNTOOLS_SEND_ADDRESSES[index]}" ]] || {
      cntools_send_fail 'A Handle destination changed. Nothing was redirected. Edit the recipient and rebuild/review the transaction.'; return 1;
    }
    previous="${CNTOOLS_SEND_RESOLUTIONS[index]:-}"
    [[ -n "${previous}" ]] || previous='{}'
    if jq -e -s 'any(.[]; .type == "virtual-subhandle" or .virtual != null)' <<< "${previous} ${evidence}" >/dev/null; then
      old_state="$(cntools_handle_review_state "${previous}")" || return 1
      new_state="$(cntools_handle_review_state "${evidence}")" || return 1
      [[ "${old_state}" == "${new_state}" ]] || {
        cntools_send_fail 'A virtual Handle type, identity or lease changed. Edit the recipient and review it again before rebuilding; no destination was changed.'; return 1;
      }
    fi
    CNTOOLS_SEND_RESOLUTIONS[index]="${evidence}"
  done
}

cntools_send_refresh_build_into() {
  local result_name="${1:-}" lifetime="${2:-1800}"
  cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" || return 1
  CNTOOLS_SEND_EXPIRY=$((CNTOOLS_FUNDING_SLOT+lifetime))
  cntools_send_recheck_handles || return 1
  cntools_send_build_into "${result_name}"
}

cntools_send_workflow() {
  local selected="" choice="" staged="" unsigned="" signed="" default="" expiry=""
  local backend="" signed_body="" txid="" status=0 lifetime=1800
  cntools_send_begin
  cntools_metadata_reset
  cntools_transaction_require_cli || return 2
  cntools_wallet_catalog_build || return 2
  (( ${#CNTOOLS_WALLET_NAMES[@]} > 0 )) || { cntools_send_fail "No wallets are available."; return 2; }
  cntools_ui_render_detail "Source wallet"
  cntools_wallet_choose selected || return $?
  cntools_send_prepare_wallet "${CNTOOLS_WALLET_PATHS[selected]}" || return 2
  cntools_ui_spin_function "Fetching spendable funds and protocol parameters…" \
    cntools_funding_collect "${CNTOOLS_SEND_ADDRESS}" "${CNTOOLS_SEND_PAYMENT}" || return 2
  cntools_ui_render_field "Spendable ADA" "$(cntools_wallet_format_lovelace "${CNTOOLS_FUNDING_TOTAL}")"
  cntools_ui_render_field "Chain data" "${CNTOOLS_FUNDING_BACKEND}"
  cntools_send_edit_recipients || return $?
  local -a workflows=("Create unsigned package")
  [[ -z "${CNTOOLS_SEND_SOURCE}" ]] || workflows+=("Create and sign" "Create, sign and submit")
  cntools_send_choose choice "Workflow" "${workflows[@]}" || return $?
  cntools_send_choose expiry "Transaction expiry" "30 minutes" "2 hours" "24 hours (offline signing)" || return $?
  case "${expiry}" in
    "30 minutes") lifetime=1800 ;;
    "2 hours") lifetime=7200 ;;
    *) lifetime=86400 ;;
  esac
  while true; do
    if ! cntools_ui_spin_function "Refreshing funds and balancing the transfer…" cntools_send_refresh_build_into staged "${lifetime}"; then return 2; fi
    cntools_send_begin
    cntools_send_render_recipients || return 2
    cntools_send_metadata_render || return 2
    cntools_ui_render_field "Fee" "$(cntools_wallet_format_lovelace "${CNTOOLS_SEND_FEE}")"
    if [[ "${CNTOOLS_SEND_MODE}" == exact ]]; then
      cntools_ui_render_field "Selection" "${CNTOOLS_TX_SELECTION_STRATEGY} · ${#CNTOOLS_COIN_SELECTED_REFS[@]} inputs"
    else
      cntools_ui_render_field "Selection" "All spendable inputs for ${CNTOOLS_SEND_MODE} · configured ${CNTOOLS_TX_SELECTION_STRATEGY} selection bypassed"
    fi
    cntools_ui_render_field "Token fragmentation" "${CNTOOLS_CHANGE_TOKEN_STATUS}"
    cntools_ui_render_field "ADA-only management" "${CNTOOLS_CHANGE_UTXO_STATUS}"
    cntools_ui_render_field "Collateral candidate" "${CNTOOLS_CHANGE_COLLATERAL_STATUS}"
    cntools_transaction_ui_render_package_review "${staged}" || return 2
    cntools_send_choose selected "Review transfer (including minimum ADA adjustments)" "Keep reviewed transaction" "Edit recipients" "Cancel" || return $?
    [[ "${selected}" != Cancel ]] || return 1
    [[ "${selected}" != "Keep reviewed transaction" ]] || break
    cntools_send_edit_recipients || return $?
  done
  default="${PWD%/}/${CNTOOLS_SEND_WALLET}.send.json"
  cntools_send_prompt_output unsigned "${default}" || return $?
  cntools_transaction_publish "${staged}" "${unsigned}" || return 2
  cntools_ui_render_field "Unsigned package saved" "${unsigned}"
  if [[ "${choice}" == "Create unsigned package" ]]; then
    cntools_ui_render_status success "Ready for Transaction → Sign, then Transaction → Submit. The package contains no private keys."
    return 0
  fi
  cntools_transaction_default_output_into default "${unsigned}" signed || return 2
  cntools_send_prompt_output signed "${default}" || return $?
  cntools_send_confirm "Sign the reviewed transfer with this wallet's payment key?" || return $?
  cntools_ui_spin_function "Rechecking selected inputs…" cntools_send_recheck || return 2
  cntools_ui_spin_function "Signing transfer…" cntools_transaction_sign_registered "${unsigned}" "${signed}" || return 2
  cntools_transaction_package_load "${signed}" || return 2
  [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || { cntools_send_fail "The saved package still needs witnesses."; return 2; }
  cntools_ui_render_field "Signed package saved" "${signed}"
  [[ "${choice}" == "Create, sign and submit" ]] || return 0
  cntools_transaction_submit_input_prepare "${signed}" || return 2
  signed_body="${CNTOOLS_TRANSACTION_SIGNED_FILE}"; txid="${CNTOOLS_TRANSACTION_SUBMIT_ID}"
  cntools_transaction_ui_submission_backend_into backend || return 2
  cntools_transaction_ui_render_submit_review "${backend}" "package" "${txid}" "${signed_body}" || return 2
  cntools_send_confirm "Submit this signed transfer using ${backend}?" || return $?
  cntools_ui_spin_function "Rechecking selected inputs…" cntools_send_recheck || return 2
  cntools_ui_spin_function "Submitting transfer…" cntools_transaction_ui_submit_selected "${backend}" "${signed_body}" "${txid}" || status=$?
  (( status == 0 )) || return 2
  cntools_ui_render_status success "${CNTOOLS_TRANSACTION_SUBMIT_MESSAGE} Submission is not confirmation of inclusion."
  cntools_ui_render_field "Transaction ID" "${txid}"
}

cntools_funds_action_send() {
  local status=0
  cntools_transaction_clear_error
  cntools_send_workflow || status=$?
  if (( status == 1 )); then
    cntools_transaction_log CHOICE "Send cancelled; any already saved packages were retained"
    cntools_ui_render_status info "Cancelled. Any packages already saved remain available."
  elif (( status != 0 )); then
    cntools_send_fail "${CNTOOLS_TRANSACTION_ERROR:-Send failed. See ${CNTOOLS_LOG} for details.}" || true
    cntools_ui_render_status error "${CNTOOLS_TRANSACTION_ERROR}"
  fi
  cntools_ui_wait
  (( status <= 1 ))
}
