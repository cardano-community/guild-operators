#!/usr/bin/env bash
# Guided direct-address Send workflow. All amounts are reviewed before signing.
# shellcheck disable=SC2034

cntools_send_begin() { cntools_ui_action_begin "Send" "/ Funds / Send"; }

CNTOOLS_SEND_RECIPIENT_ESC=N
declare -ag CNTOOLS_SEND_SNAPSHOT_ADDRESSES=() CNTOOLS_SEND_SNAPSHOT_LABELS=() CNTOOLS_SEND_SNAPSHOT_AMOUNTS=() CNTOOLS_SEND_SNAPSHOT_PAID=()
declare -ag CNTOOLS_SEND_SNAPSHOT_HANDLES=() CNTOOLS_SEND_SNAPSHOT_RESOLUTIONS=() CNTOOLS_SEND_SNAPSHOT_STATE=()
declare -Ag CNTOOLS_SEND_SNAPSHOT_ASSETS=()

cntools_send_choose_change() {
  local choice=''
  CNTOOLS_SEND_CHANGE_ADDRESS="${CNTOOLS_SEND_ADDRESS}"
  [[ "${CNTOOLS_SEND_CHOOSE_CHANGE:-N}" == Y && "${CNTOOLS_SEND_ADDRESS}" != "${CNTOOLS_SEND_PAYMENT}" ]] || return 0
  cntools_ui_render_status info 'Inputs are selected automatically from both addresses. This choice affects only returned change. Payment-only change does not participate in staking.'
  cntools_ui_choose choice 'Return change to' 'Primary / base address (default)' 'Payment-only address' Cancel || return $?
  case "${choice}" in
    'Primary / base address (default)') ;;
    'Payment-only address') CNTOOLS_SEND_CHANGE_ADDRESS="${CNTOOLS_SEND_PAYMENT}" ;;
    Cancel) return 1 ;;
    *) return 2 ;;
  esac
  cntools_transaction_log CHOICE "Send change address=${CNTOOLS_SEND_CHANGE_ADDRESS}"
}

cntools_send_confirm() {
  local status=0
  cntools_ui_confirm "$1" "${2:-false}" || status=$?
  cntools_transaction_log CHOICE "Send confirmation=${1} status=${status}"
  return "${status}"
}

cntools_send_choose() {
  local output_name="${1:-}" prompt="${2:-}" status=0
  shift 2
  [[ -z "${CNTOOLS_SEND_EDIT_CANCEL:-}" ]] || set -- "$@" "${CNTOOLS_SEND_EDIT_CANCEL}"
  cntools_ui_choose "${output_name}" "${prompt}" "$@" || status=$?
  if (( status == 0 )); then
    local -n chosen_ref="${output_name}"
    cntools_transaction_log CHOICE "Send ${prompt} selected=${chosen_ref}"
    [[ -z "${CNTOOLS_SEND_EDIT_CANCEL:-}" || "${chosen_ref}" != "${CNTOOLS_SEND_EDIT_CANCEL}" ]] || return 1
  fi
  return "${status}"
}

cntools_send_review_virtual() {
  local resolution="$1" lease="" expires="" expires_label="" public=""
  [[ "$(jq -r '.type' <<< "${resolution}")" == virtual-subhandle ]] || return 0
  lease="$(jq -r '.virtual.leaseStatus' <<< "${resolution}")"
  expires="$(jq -r '.virtual.expiresTimeMs' <<< "${resolution}")"
  public="$(jq -r '.virtual.publicMint' <<< "${resolution}")"
  cntools_timestamp_datetime_into expires_label "$((expires/1000))" || return 1
  {
    printf 'Handle detail\tValue\n'
    cntools_transaction_ui_styled_row 'Virtual lease' "$([[ "${public}" == true ]] && printf Public || printf Private) · ${lease}" value
    cntools_transaction_ui_styled_row 'Lease expiry' "${expires_label}" number
  } | cntools_ui_table --separator $'\t' || return 1
  if [[ "${public}" != true ]]; then
    cntools_ui_render_status warn 'The parent Handle owner can revoke or reassign this private subhandle at any time.'
  fi
  if [[ "${lease}" == expired ]]; then
    cntools_ui_render_status warn 'The lease has expired. The current datum still resolves, but the subhandle may be revoked or reassigned. Expiry does not redirect to its parent.'
  fi
  cntools_ui_render_status info 'Koios supplies the current datum destination. Confirm it with the recipient; an alias can change after our last check.'
  cntools_send_confirm 'Use this current virtual-subhandle destination?'
}

cntools_send_prompt_recipient() {
  local index="${1:-}" operation="${2:-Add}" choice="" address="" label="" note="" selected="" allow_script=N
  local directory="" entered="" handle_name="" resolution="" status=0
  local -a edit_options=()
  CNTOOLS_SEND_RECIPIENT_ESC=N
  if [[ "${operation}" == Edit ]]; then
    # Edits usually change amounts: keeping the recipient is one Enter.
    edit_options=('Keep current recipient' "CNTools wallet" "External address" "ADA Handle")
    if cntools_flow_quick; then edit_options=('Keep current recipient' 'Change recipient'); fi
    cntools_send_choose choice "Recipient" "${edit_options[@]}" || return $?
    if [[ "${choice}" == 'Keep current recipient' ]]; then
      cntools_transaction_log CHOICE "Send recipient=$((index+1)) kept"
      return 0
    fi
    [[ "${choice}" != 'Change recipient' ]] || choice=""
  fi
  if [[ -z "${choice}" ]] && cntools_flow_quick; then
    # One field: the prefix tells an address from a Handle; empty picks a wallet.
    # shellcheck disable=SC2016 # literal Handle syntax in the placeholder
    cntools_ui_input entered 'Recipient' 'addr…, $handle, or Enter to pick a CNTools wallet' || {
      status=$?; CNTOOLS_SEND_RECIPIENT_ESC=Y; return "${status}";
    }
    cntools_recipient_trim_into entered "${entered}" || return 2
    case "${entered}" in
      '') choice="CNTools wallet" ;;
      '$'*) choice="ADA Handle" ;;
      *) choice="External address" ;;
    esac
    cntools_transaction_log CHOICE "Send Recipient type detected=${choice}"
  elif [[ -z "${choice}" ]]; then
    cntools_send_choose choice "Recipient type" "CNTools wallet" "External address" "ADA Handle" || {
      status=$?; CNTOOLS_SEND_RECIPIENT_ESC=Y; return "${status}";
    }
  fi
  if [[ "${choice}" == "CNTools wallet" ]]; then
    # Never auto-pick the recipient: a lone wallet would be the source itself.
    cntools_wallet_choose selected "${CNTOOLS_SEND_EDIT_CANCEL:-Cancel}" "" N || {
      status=$?; (( status != 3 )) || status=1; return "${status}";
    }
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
    [[ -n "${entered}" ]] || cntools_ui_input entered 'ADA Handle' '$name or $child@parent' || return $?
    if ! cntools_ui_spin_function 'Resolving Handle through Koios…' cntools_handle_resolve_into address resolution "${entered}"; then
      cntools_ui_render_status warn "${CNTOOLS_HANDLE_ERROR:-Handle resolution failed; no destination was selected.}"
      return 2
    fi
    handle_name="$(jq -r '.handle' <<< "${resolution}")"
    label="${handle_name} · $(jq -r '.type' <<< "${resolution}") · Koios"
  else
    [[ -n "${entered}" ]] || cntools_ui_input entered "Receiving address" "addr…" || return $?
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
  cntools_send_render_recipient "${label}" "${address}" || return 2
  [[ -z "${resolution}" ]] || cntools_send_review_virtual "${resolution}" || return $?
  if [[ "${choice}" == 'External address' && "${CNTOOLS_NETWORK}" != mainnet ]]; then
    cntools_ui_render_status info 'Testnet addresses do not distinguish testnet networks. Confirm the recipient uses the network shown in the header.'
  fi
  CNTOOLS_SEND_ADDRESSES[index]="${address}"
  CNTOOLS_SEND_LABELS[index]="${label}"
  CNTOOLS_SEND_HANDLES[index]="${handle_name}"
  CNTOOLS_SEND_RESOLUTIONS[index]="${resolution}"
  cntools_transaction_log CHOICE "Send recipient=$((index+1)) type=${choice} address=${address}"
}

cntools_send_prompt_amounts() {
  local index="${1:-}" operation="${2:-Add}" choice="" entered="" units="" asset="" option="" asset_label="" i=0 status=0
  local amount_prompt="ADA amount (0 = minimum ADA for this output)" choose_mode=N previous_mode="${CNTOOLS_SEND_MODE}"
  local keep="" placeholder="0" asset_back=N
  local -a options=()
  (( index != 0 || ${#CNTOOLS_SEND_ADDRESSES[@]} != 1 )) || choose_mode=Y
  # Without native assets, Max ADA already sends everything: offer one.
  if [[ "${choose_mode}" == Y ]] && cntools_flow_quick; then
    # Quick folds the amount mode into the amount: max or all instead of a number.
    CNTOOLS_SEND_MODE=exact
    amount_prompt="ADA amount (max = all ADA, all = everything incl. assets, 0 = minimum ADA)"
    (( ${#CNTOOLS_FUNDING_ASSET_IDS[@]} > 0 )) || amount_prompt="ADA amount (max = all ADA, 0 = minimum ADA)"
  elif [[ "${choose_mode}" == Y ]]; then
    options=("Exact amounts" "Max ADA")
    (( ${#CNTOOLS_FUNDING_ASSET_IDS[@]} == 0 )) || options+=("Send everything")
    cntools_send_choose choice "Amount mode" "${options[@]}" || return $?
    case "${choice}" in
      "Exact amounts") CNTOOLS_SEND_MODE=exact ;;
      "Max ADA") CNTOOLS_SEND_MODE=max ;;
      "Send everything") CNTOOLS_SEND_MODE=sweep ;;
    esac
  fi
  # An edit keeps the entered amount (or Quick's max / all) on Enter.
  if [[ "${operation}" == Edit && "${CNTOOLS_SEND_MODE}" == exact ]]; then
    case "${previous_mode}" in
      exact) keep="${CNTOOLS_SEND_AMOUNTS[index]:-}"
             [[ -z "${keep}" ]] || placeholder="Enter keeps $(cntools_number_format_lovelace "${keep}")" ;;
      max) [[ "${choose_mode}" != Y ]] || ! cntools_flow_quick || { keep=max; placeholder='Enter keeps max'; } ;;
      sweep) [[ "${choose_mode}" != Y ]] || ! cntools_flow_quick || { keep=all; placeholder='Enter keeps all'; } ;;
    esac
  fi
  if [[ "${CNTOOLS_SEND_MODE}" == exact ]]; then
    while true; do
      cntools_ui_input entered "${amount_prompt}" "${placeholder}" || return $?
      if [[ -z "${entered}" && -n "${keep}" ]]; then
        case "${keep}" in
          max) CNTOOLS_SEND_MODE=max ;;
          all) CNTOOLS_SEND_MODE=sweep ;;
          *) units="${keep}" ;;
        esac
        cntools_transaction_log CHOICE "Send recipient=$((index+1)) amount kept=${keep}"
        break
      fi
      [[ -n "${entered}" ]] || entered=0
      if [[ "${choose_mode}" == Y ]] && cntools_flow_quick; then
        case "${entered,,}" in
          max) CNTOOLS_SEND_MODE=max ;;
          all) CNTOOLS_SEND_MODE=sweep
               (( ${#CNTOOLS_FUNDING_ASSET_IDS[@]} > 0 )) || CNTOOLS_SEND_MODE=max ;;
        esac
        if [[ "${CNTOOLS_SEND_MODE}" != exact ]]; then
          cntools_transaction_log CHOICE "Send Amount mode selected=${CNTOOLS_SEND_MODE} flow=quick"
          break
        fi
      fi
      if cntools_number_units_into units "${entered}" 6 &&
         cntools_uint_greater_equal "${CNTOOLS_FUNDING_TOTAL}" "${units}"; then break; fi
      cntools_transaction_log CHOICE "Send invalid ADA amount rejected"
      if [[ "${choose_mode}" == Y ]] && cntools_flow_quick && (( ${#CNTOOLS_FUNDING_ASSET_IDS[@]} > 0 )); then
        cntools_ui_render_status warn "Enter an available ADA amount with at most six decimal places, max or all."
      elif [[ "${choose_mode}" == Y ]] && cntools_flow_quick; then
        cntools_ui_render_status warn "Enter an available ADA amount with at most six decimal places, or max."
      else
        cntools_ui_render_status warn "Enter an available non-negative ADA amount, with at most six decimal places."
      fi
    done
    if [[ "${CNTOOLS_SEND_MODE}" == exact ]]; then
      CNTOOLS_SEND_AMOUNTS[index]="${units}"
      cntools_transaction_log CHOICE "Send recipient=$((index+1)) lovelace=${units}"
    else
      CNTOOLS_SEND_AMOUNTS[index]=0
    fi
  else
    CNTOOLS_SEND_AMOUNTS[index]=0
  fi
  if [[ "${CNTOOLS_SEND_MODE}" == sweep ]]; then
    for asset in "${CNTOOLS_FUNDING_ASSET_IDS[@]}"; do unset 'CNTOOLS_SEND_ASSETS['"${index}|${asset}"']'; done
    return 0
  fi
  while (( ${#CNTOOLS_FUNDING_ASSET_IDS[@]} > 0 )); do
    cntools_send_begin
    cntools_send_render_recipient "${CNTOOLS_SEND_LABELS[index]}" "${CNTOOLS_SEND_ADDRESSES[index]}" || return 2
    cntools_send_render_assets "${index}" || return 2
    options=("Done selecting assets")
    i=0
    for asset in "${CNTOOLS_FUNDING_ASSET_IDS[@]}"; do
      i=$((i+1))
      cntools_asset_label_into asset_label "${asset}" "${i}" || return 2
      options+=("${i} · ${asset_label} · ${asset}")
    done
    cntools_send_choose option "Native assets (quantities in smallest units)" "${options[@]}" || return $?
    [[ "${option}" != "${options[0]}" ]] || break
    asset=""
    for i in "${!CNTOOLS_FUNDING_ASSET_IDS[@]}"; do
      [[ "${option}" != "${options[i+1]}" ]] || asset="${CNTOOLS_FUNDING_ASSET_IDS[i]}"
    done
    [[ -n "${asset}" ]] || return 2
    asset_back=N
    while true; do
      status=0
      cntools_ui_input entered "Smallest-unit quantity (All or 0 to remove)" "All" || status=$?
      # Esc returns to the asset list; the rest of the draft stays.
      if (( status == 1 )); then asset_back=Y; break; fi
      (( status == 0 )) || return "${status}"
      if [[ -z "${entered}" || "${entered,,}" == all ]]; then units="${CNTOOLS_FUNDING_ASSETS[${asset}]}"
      elif ! cntools_number_units_into units "${entered}" 0; then
        cntools_ui_render_status warn "Enter a whole smallest-unit quantity, optionally with commas, or All."; continue
      fi
      if cntools_uint_greater_equal "${CNTOOLS_FUNDING_ASSETS[${asset}]}" "${units}"; then break; fi
      cntools_ui_render_status warn "That exceeds the wallet's available quantity."
    done
    [[ "${asset_back}" == N ]] || continue
    CNTOOLS_SEND_ASSETS["${index}|${asset}"]="${units}"
    cntools_transaction_log CHOICE "Send recipient=$((index+1)) asset=${asset} quantity=${units}"
  done
}

# One row per asset: friendly label and quantity, with the ID muted below.
cntools_send_render_asset_rows() {
  local index="$1" asset="" quantity="" asset_label="" n=0
  for asset in "${CNTOOLS_FUNDING_ASSET_IDS[@]}"; do
    n=$((n+1))
    cntools_send_asset_quantity_into quantity "${index}" "${asset}"
    [[ "${quantity}" != 0 ]] || continue
    cntools_asset_label_into asset_label "${asset}" "${n}" || return 1
    cntools_transaction_ui_styled_row Asset "${asset_label} · $(cntools_number_format "${quantity}")" number
    cntools_transaction_ui_styled_row '' "${asset}" muted
  done
}

# ADA for one recipient: the entered amount before a build, the output after.
cntools_send_amount_label_into() {
  local -n send_amount_ref="$1"
  local index="$2" entered="${CNTOOLS_SEND_AMOUNTS[$2]:-0}" paid="${CNTOOLS_SEND_PAID[$2]:-}"
  if [[ -z "${paid}" ]]; then
    case "${CNTOOLS_SEND_MODE}" in
      max|sweep) send_amount_ref='All spendable ADA after the fee' ;;
      *) send_amount_ref="$(cntools_number_format_lovelace "${entered}")"
         [[ "${entered}" != 0 ]] || send_amount_ref='Minimum ADA · set when building' ;;
    esac
    return 0
  fi
  send_amount_ref="$(cntools_number_format_lovelace "${paid}")"
  if [[ "${CNTOOLS_SEND_MODE}" == max || "${CNTOOLS_SEND_MODE}" == sweep ]]; then
    send_amount_ref+=' · all after the fee'
  elif [[ "${paid}" != "${entered}" && "${entered}" == 0 ]]; then
    send_amount_ref+=' · minimum ADA'
  elif [[ "${paid}" != "${entered}" ]]; then
    send_amount_ref+=" · raised to the minimum (entered $(cntools_number_format_lovelace "${entered}"))"
  fi
}

cntools_send_render_recipients() {
  local widths="" index=0 amount=""
  if (( ${#CNTOOLS_SEND_ADDRESSES[@]} == 0 )); then
    cntools_ui_render_status info 'No recipients yet. Choose Add to start a transfer.'
    return 0
  fi
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  {
    printf 'Recipient / property\tValue\n'
    for index in "${!CNTOOLS_SEND_ADDRESSES[@]}"; do
      cntools_transaction_ui_styled_row "$((index+1)) · Recipient" "${CNTOOLS_SEND_LABELS[index]}" identifier
      cntools_transaction_ui_styled_row "Address" "${CNTOOLS_SEND_ADDRESSES[index]}" address
      cntools_send_amount_label_into amount "${index}"
      cntools_transaction_ui_styled_row "ADA" "${amount}" number
      if [[ "${CNTOOLS_SEND_MODE}" == sweep && -z "${CNTOOLS_SEND_PAID[index]:-}" ]]; then
        (( ${#CNTOOLS_FUNDING_ASSET_IDS[@]} == 0 )) ||
          cntools_transaction_ui_styled_row 'Native assets' "All · $(cntools_number_format "${#CNTOOLS_FUNDING_ASSET_IDS[@]}") assets" number
      else
        cntools_send_render_asset_rows "${index}" || return 1
      fi
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

# 'Back to review' restores the reviewed recipients and metadata unchanged.
cntools_send_review_snapshot() {
  local key=""
  CNTOOLS_SEND_SNAPSHOT_ADDRESSES=("${CNTOOLS_SEND_ADDRESSES[@]}"); CNTOOLS_SEND_SNAPSHOT_LABELS=("${CNTOOLS_SEND_LABELS[@]}")
  CNTOOLS_SEND_SNAPSHOT_AMOUNTS=("${CNTOOLS_SEND_AMOUNTS[@]}"); CNTOOLS_SEND_SNAPSHOT_PAID=("${CNTOOLS_SEND_PAID[@]}")
  CNTOOLS_SEND_SNAPSHOT_HANDLES=("${CNTOOLS_SEND_HANDLES[@]}"); CNTOOLS_SEND_SNAPSHOT_RESOLUTIONS=("${CNTOOLS_SEND_RESOLUTIONS[@]}")
  CNTOOLS_SEND_SNAPSHOT_STATE=("${CNTOOLS_SEND_MODE}" "${CNTOOLS_METADATA_MESSAGE:-}" "${CNTOOLS_METADATA_CUSTOM:-}" "${CNTOOLS_METADATA_MODE:-none}" "${CNTOOLS_METADATA_SCHEMA:-simple}")
  CNTOOLS_SEND_SNAPSHOT_ASSETS=()
  for key in "${!CNTOOLS_SEND_ASSETS[@]}"; do CNTOOLS_SEND_SNAPSHOT_ASSETS["${key}"]="${CNTOOLS_SEND_ASSETS[${key}]}"; done
}

cntools_send_review_restore() {
  local key=""
  CNTOOLS_SEND_ADDRESSES=("${CNTOOLS_SEND_SNAPSHOT_ADDRESSES[@]}"); CNTOOLS_SEND_LABELS=("${CNTOOLS_SEND_SNAPSHOT_LABELS[@]}")
  CNTOOLS_SEND_AMOUNTS=("${CNTOOLS_SEND_SNAPSHOT_AMOUNTS[@]}"); CNTOOLS_SEND_PAID=("${CNTOOLS_SEND_SNAPSHOT_PAID[@]}")
  CNTOOLS_SEND_HANDLES=("${CNTOOLS_SEND_SNAPSHOT_HANDLES[@]}"); CNTOOLS_SEND_RESOLUTIONS=("${CNTOOLS_SEND_SNAPSHOT_RESOLUTIONS[@]}")
  CNTOOLS_SEND_MODE="${CNTOOLS_SEND_SNAPSHOT_STATE[0]}" CNTOOLS_METADATA_MESSAGE="${CNTOOLS_SEND_SNAPSHOT_STATE[1]}"
  CNTOOLS_METADATA_CUSTOM="${CNTOOLS_SEND_SNAPSHOT_STATE[2]}" CNTOOLS_METADATA_MODE="${CNTOOLS_SEND_SNAPSHOT_STATE[3]}"
  CNTOOLS_METADATA_SCHEMA="${CNTOOLS_SEND_SNAPSHOT_STATE[4]}"
  CNTOOLS_SEND_ASSETS=()
  for key in "${!CNTOOLS_SEND_SNAPSHOT_ASSETS[@]}"; do CNTOOLS_SEND_ASSETS["${key}"]="${CNTOOLS_SEND_SNAPSHOT_ASSETS[${key}]}"; done
}

# initial=Y: the first recipients screen of a transfer. back=Y: a reviewed
# build exists; 'Back to review' or Esc restores it and returns 4.
cntools_send_edit_recipients() {
  local command="Review" index=0 selected="" status=0 initial="${1:-N}" back="${2:-N}"
  local -a options=()
  [[ "${back}" != Y ]] || cntools_send_review_snapshot
  # The editor shows entered amounts; built outputs return with the next review.
  CNTOOLS_SEND_PAID=()
  (( ${#CNTOOLS_SEND_ADDRESSES[@]} > 0 )) || command=Add
  while true; do
    if [[ "${command}" == Add || "${command}" == Edit ]]; then
      if [[ "${command}" == Add ]]; then index="${#CNTOOLS_SEND_ADDRESSES[@]}"; fi
      (( index < 20 )) || { cntools_ui_render_status warn "At most 20 recipients per transfer."; command=Review; continue; }
      status=0
      cntools_send_edit_one "${index}" "${command}" || status=$?
      (( status != 130 )) || return 130
      # Specific warnings carry to the next screen; name an unexplained failure.
      if (( status != 0 && status != 1 && ${#CNTOOLS_UI_UNSEEN_WARNINGS[@]} == 0 )); then
        cntools_ui_render_status warn 'Recipient changes were not saved.'
      fi
      # Quick goes from the first recipient straight to the review, where
      # 'Edit recipients' adds more recipients or a message. Until there is
      # one, only Esc on the Recipient field ends the transfer; any other
      # cancel or failure asks again.
      if [[ "${initial}" == Y ]] && cntools_flow_quick; then
        (( ${#CNTOOLS_SEND_ADDRESSES[@]} == 0 )) || return 0
        (( status != 1 )) || [[ "${CNTOOLS_SEND_RECIPIENT_ESC:-N}" != Y ]] || return 1
        continue
      fi
      # Detailed: leaving the first recipient type ends the transfer too,
      # rather than opening an empty recipients screen.
      if [[ "${initial}" == Y && "${CNTOOLS_SEND_RECIPIENT_ESC:-N}" == Y ]] && (( status == 1 && ${#CNTOOLS_SEND_ADDRESSES[@]} == 0 )); then
        return 1
      fi
    elif [[ "${command}" == Remove ]]; then
      cntools_send_remove_recipient "${index}" || return 2
    fi
    cntools_send_begin
    cntools_send_render_source || return 2
    cntools_send_render_recipients || return 2
    if (( ${#CNTOOLS_FUNDING_ASSET_IDS[@]} > 0 && ${#CNTOOLS_SEND_ADDRESSES[@]} > 0 )); then
      cntools_ui_render_status info 'Asset quantities are in smallest units, without decimals. The review shows the fee and any minimum-ADA raise.'
    fi
    cntools_send_metadata_render || return 2
    options=("Continue" "Edit" "Remove" "Message / metadata")
    [[ "${CNTOOLS_SEND_MODE}" != exact ]] || options=("Continue" "Add" "Edit" "Remove" "Message / metadata")
    if (( ${#CNTOOLS_SEND_ADDRESSES[@]} == 0 )); then options=("Add"); CNTOOLS_SEND_MODE=exact; fi
    [[ "${back}" != Y ]] || options+=('Back to review')
    options+=('Cancel transfer')
    status=0
    cntools_send_choose command "Recipients" "${options[@]}" || status=$?
    if (( status == 1 )) && [[ "${back}" == Y ]]; then command='Back to review'
    elif (( status != 0 )); then return "${status}"; fi
    case "${command}" in
      Continue) return 0 ;;
      'Back to review')
        cntools_send_review_restore
        cntools_transaction_log CHOICE 'Send recipients unchanged; back to review'
        return 4 ;;
      'Cancel transfer') return 1 ;;
      'Message / metadata')
        status=0
        cntools_send_metadata_edit || status=$?
        (( status <= 1 )) || return "${status}"
        ;;
      Edit|Remove)
        index=0
        (( ${#CNTOOLS_SEND_ADDRESSES[@]} > 1 )) || continue
        options=()
        for index in "${!CNTOOLS_SEND_ADDRESSES[@]}"; do options+=("$((index+1)) · ${CNTOOLS_SEND_LABELS[index]}"); done
        status=0
        cntools_send_choose selected "Select recipient" "${options[@]}" 'Back to recipients' || status=$?
        (( status != 130 )) || return 130
        if (( status != 0 )) || [[ "${selected}" == 'Back to recipients' ]]; then command=Review; continue; fi
        for index in "${!options[@]}"; do [[ "${selected}" != "${options[index]}" ]] || break; done
        ;;
    esac
  done
}

# Treat a recipient edit as a draft: every cancellation/error restores all state,
# including amount mode and Handle evidence, not merely the receiving address.
cntools_send_edit_one() {
  local index="$1" operation="$2" status=0 key="" previous_mode="${CNTOOLS_SEND_MODE}"
  local CNTOOLS_SEND_EDIT_CANCEL='Cancel edit'
  local -a saved_addresses=("${CNTOOLS_SEND_ADDRESSES[@]}") saved_labels=("${CNTOOLS_SEND_LABELS[@]}")
  local -a saved_amounts=("${CNTOOLS_SEND_AMOUNTS[@]}") saved_handles=("${CNTOOLS_SEND_HANDLES[@]}") saved_resolutions=("${CNTOOLS_SEND_RESOLUTIONS[@]}")
  local -A saved_assets=()
  for key in "${!CNTOOLS_SEND_ASSETS[@]}"; do saved_assets["${key}"]="${CNTOOLS_SEND_ASSETS[${key}]}"; done
  [[ "${operation}" != Add ]] || CNTOOLS_SEND_EDIT_CANCEL='Cancel adding recipient'
  cntools_send_begin
  cntools_send_render_source || return 2
  if [[ "${operation}" == Edit ]]; then
    cntools_send_render_recipient "${CNTOOLS_SEND_LABELS[index]}" "${CNTOOLS_SEND_ADDRESSES[index]}" || return 2
  fi
  cntools_send_prompt_recipient "${index}" "${operation}" || status=$?
  if (( status == 0 )); then cntools_send_prompt_amounts "${index}" "${operation}" || status=$?; fi
  if (( status != 0 )); then
    CNTOOLS_SEND_ADDRESSES=("${saved_addresses[@]}"); CNTOOLS_SEND_LABELS=("${saved_labels[@]}")
    CNTOOLS_SEND_AMOUNTS=("${saved_amounts[@]}"); CNTOOLS_SEND_HANDLES=("${saved_handles[@]}")
    CNTOOLS_SEND_RESOLUTIONS=("${saved_resolutions[@]}"); CNTOOLS_SEND_MODE="${previous_mode}"
    CNTOOLS_SEND_ASSETS=()
    for key in "${!saved_assets[@]}"; do CNTOOLS_SEND_ASSETS["${key}"]="${saved_assets[${key}]}"; done
    cntools_transaction_log CHOICE "Send recipient draft discarded operation=${operation} status=${status}"
  fi
  return "${status}"
}

cntools_send_recheck() {
  local reference=""
  local -a selected_refs=("${CNTOOLS_COIN_SELECTED_REFS[@]}")
  cntools_send_funding_collect || return 1
  [[ -z "${CNTOOLS_SEND_EXPIRY}" ]] || (( CNTOOLS_FUNDING_SLOT < CNTOOLS_SEND_EXPIRY )) || { cntools_send_fail "The transfer expired. Build and review a new transaction."; return 1; }
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
  cntools_send_funding_collect || return 1
  cntools_transaction_expiry_into CNTOOLS_SEND_EXPIRY "${CNTOOLS_FUNDING_SLOT}" "${lifetime}" || return 1
  cntools_send_recheck_handles || return 1
  cntools_send_build_into "${result_name}"
}

cntools_send_workflow() {
  local selected="" choice="" staged="" signed="" saved="" proceed=""
  local backend="" signed_body="" txid="" status=0 lifetime=1800 previous=""
  CNTOOLS_SEND_RESULT_SHOWN=N
  CNTOOLS_SEND_SAVED_PACKAGE=""
  cntools_send_begin
  cntools_metadata_reset
  cntools_transaction_require_cli || return 2
  cntools_wallet_catalog_build || return 2
  cntools_ui_render_detail "Source wallet"
  cntools_wallet_choose selected Cancel send || return $?
  cntools_send_prepare_wallet "${CNTOOLS_WALLET_PATHS[selected]}" multisig || return 2
  [[ "${CNTOOLS_SEND_TYPE}" != MultiSig ]] || cntools_multisig_spend_choose_signers || return $?
  cntools_send_choose_change || return $?
  cntools_ui_spin_function "Fetching spendable funds and protocol parameters…" cntools_send_funding_collect || return 2
  if (( ${#CNTOOLS_FUNDING_ASSET_IDS[@]} > 0 )); then
    cntools_ui_spin_function 'Loading asset names from Koios / one-day cache…' \
      cntools_asset_details_for_ids "${CNTOOLS_FUNDING_ASSET_IDS[@]}" ||
      cntools_transaction_log WARN 'Some asset metadata is unavailable; using on-chain name / identity fallback'
  fi
  cntools_send_edit_recipients Y || return $?
  local can_sign=N
  [[ -z "${CNTOOLS_SEND_SOURCE}" ]] || can_sign=Y
  [[ "${CNTOOLS_SEND_TYPE}" != MultiSig ]] || can_sign="${CNTOOLS_MULTISIG_CAN_SIGN}"
  cntools_transaction_ui_initial_workflow_into choice "${can_sign}" || return $?
  cntools_transaction_ui_initial_expiry_into lifetime || return $?
  cntools_transaction_ui_proceed_into proceed "${choice}" || return 2
  while true; do
    status=0
    cntools_transaction_clear_error
    cntools_ui_spin_function "Refreshing funds and balancing the transfer…" cntools_send_refresh_build_into staged "${lifetime}" || status=$?
    if (( status != 0 )) && [[ -n "${previous}" ]]; then
      # A new expiry that cannot be built keeps the previous one.
      cntools_transaction_log CHOICE "Send rebuild failed; previous expiry kept lifetime=${previous}"
      cntools_ui_render_status warn "The new expiry could not be built, so the previous one is kept. ${CNTOOLS_TRANSACTION_ERROR:-}"
      lifetime="${previous}"; previous=""
      continue
    elif (( status != 0 )); then
      # Keep the recipients: show why the build failed and reopen them.
      cntools_ui_render_status warn "${CNTOOLS_TRANSACTION_ERROR:-The transfer could not be built. See ${CNTOOLS_LOG} for details.}"
      cntools_send_edit_recipients || return $?
      continue
    fi
    previous=""
    while true; do
      cntools_transaction_ui_proceed_into proceed "${choice}" || return 2
      cntools_transaction_ui_review_into selected "${staged}" "${proceed}" \
        cntools_send_begin cntools_send_render_review 'Edit recipients' 'Change expiry' 'Change workflow' || return $?
      status=0
      case "${selected}" in
        "${proceed}") break ;;
        'Edit recipients')
          cntools_send_edit_recipients N Y || status=$?
          (( status != 4 )) || continue # unchanged: same package
          (( status == 0 )) || return "${status}"
          break ;;
        'Change workflow')
          # Esc keeps the current value and returns to the review. Quick gives
          # an unsigned package a day to be signed, so that rebuilds.
          cntools_transaction_ui_workflow_into choice "${can_sign}" || status=$?
          (( status <= 1 )) || return "${status}"
          (( status == 0 )) || continue
          previous="${lifetime}"
          cntools_transaction_ui_unsigned_lifetime_into lifetime "${choice}" && break
          previous="" ;;
        'Change expiry')
          previous="${lifetime}"
          cntools_transaction_ui_expiry_into lifetime || status=$?
          (( status != 1 )) || { previous=""; continue; }
          (( status == 0 )) || return "${status}"
          break ;;
        *) return 2 ;;
      esac
    done
    [[ "${selected}" != "${proceed}" ]] || break
  done
  if [[ "${choice}" == 'Create unsigned package' ]]; then
    cntools_send_save_into saved "${staged}" unsigned || return 2
    cntools_send_begin
    cntools_send_render_result success 'Ready for offline signing · Transaction → Sign, then Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
  cntools_send_signed_path_into signed || return 2
  cntools_ui_spin_function "Rechecking selected inputs…" cntools_send_recheck || return 2
  cntools_ui_spin_function "Signing transfer…" cntools_transaction_sign_registered "${staged}" "${signed}" || return 2
  cntools_transaction_package_load "${signed}" || return 2
  [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]] || { cntools_send_fail 'The package still needs witnesses.'; return 2; }
  # Retain the final signed package before submission, including ambiguous
  # network failures/cancellation. Intermediate work remains cleanup-tracked.
  cntools_send_save_into saved "${signed}" signed || return 2
  if [[ "${choice}" == 'Create and sign' ]]; then
    cntools_send_begin
    cntools_send_render_result success 'Signed · ready for Transaction → Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved}"
    return $?
  fi
  cntools_transaction_submit_input_prepare "${saved}" || return 2
  signed_body="${CNTOOLS_TRANSACTION_SIGNED_FILE}"; txid="${CNTOOLS_TRANSACTION_SUBMIT_ID}"
  cntools_transaction_ui_submission_backend_into backend || return 2
  if ! cntools_transaction_ui_confirm_submit "${backend}"; then
    cntools_send_begin
    cntools_send_render_result warning 'Not submitted · signed package retained' "${txid}" "${saved}"
    return $?
  fi
  status=0
  cntools_ui_spin_function "Rechecking selected inputs…" cntools_send_recheck || status=$?
  if (( status == 0 )); then
    cntools_ui_spin_function "Submitting transfer…" cntools_transaction_ui_submit_selected "${backend}" "${signed_body}" "${txid}" || status=$?
  fi
  cntools_send_begin
  if (( status != 0 )); then
    cntools_send_render_result danger "${CNTOOLS_TRANSACTION_ERROR:-Submission could not be confirmed. Check the log and chain before retrying.}" "${txid}" "${saved}" || return 2
    return 2
  fi
  cntools_send_render_result success "${CNTOOLS_TRANSACTION_SUBMIT_MESSAGE} Submission is not confirmation of inclusion." "${txid}" || return 2
  cntools_transaction_ui_offer_monitor "${txid}"
}

# 1/130 cancel straight back to the menu (naming a saved package, if any);
# 3 means the reason was already shown and acknowledged.
cntools_funds_action_send() {
  local status=0
  cntools_transaction_clear_error
  cntools_send_workflow || status=$?
  case "${status}" in
    0) cntools_ui_wait ;;
    1|130)
      cntools_transaction_log CHOICE "Send cancelled status=${status} saved=${CNTOOLS_SEND_SAVED_PACKAGE:-none}"
      [[ -n "${CNTOOLS_SEND_SAVED_PACKAGE:-}" ]] || return 0
      cntools_ui_render_status info "Cancelled. The saved package remains available: ${CNTOOLS_SEND_SAVED_PACKAGE}"
      cntools_ui_wait ;;
    3) ;;
    *)
      cntools_send_fail "${CNTOOLS_TRANSACTION_ERROR:-Send failed. See ${CNTOOLS_LOG} for details.}" || true
      if [[ "${CNTOOLS_SEND_RESULT_SHOWN:-N}" != Y ]]; then
        cntools_send_render_result danger "${CNTOOLS_TRANSACTION_ERROR}" "" "${CNTOOLS_SEND_SAVED_PACKAGE:-}"
      fi
      cntools_ui_wait
      return 1 ;;
  esac
}
