#!/usr/bin/env bash
# Legacy wizard guidance, with the same compact transaction review as other actions.
# shellcheck disable=SC2034
# 3: no pool fits; the reason was shown as one info line and acknowledged.
cntools_pool_registration_choose_eligible_into() {
  local output="$1" index=0 row='' selected_choice='' status='' unchecked=0 reason=''
  local -a rows=() indices=()
  cntools_ui_spin_function 'Checking pool eligibility…' cntools_pool_inspect_catalog || return 2
  for index in "${!CNTOOLS_POOL_NAMES[@]}"; do
    [[ "${CNTOOLS_POOL_IDENTITIES[index]}" == 'Verified cold public key' ]] || continue
    status="${CNTOOLS_POOL_CHAIN_STATUS[index]}"
    [[ "${status}" != Unavailable ]] || unchecked=$((unchecked + 1))
    case "${CNTOOLS_WALLET_REGISTER_OPERATION}:${status}" in
      pool-register:'Not registered'|pool-register:'Not indexed'|pool-register:Retired|pool-modify:Registered|pool-modify:Retiring|pool-retire:Registered|pool-retire:Retiring) ;;
      *) continue ;;
    esac
    row="${CNTOOLS_POOL_NAMES[index]} · ${status}"; rows+=("${row}"); indices+=("${index}")
  done
  if (( ${#rows[@]} == 0 )); then
    case "${CNTOOLS_WALLET_REGISTER_OPERATION}" in
      pool-register) reason='No pool is ready to register. Register needs a pool with a verified cold public key that is not registered on chain.' ;;
      pool-modify) reason='No registered pool to modify. Modify needs a registered pool with a verified cold public key.' ;;
      *) reason='No registered pool to retire. Retire needs a registered pool with a verified cold public key.' ;;
    esac
    if ((unchecked > 0)); then
      reason+=" The registration of $(cntools_number_format "${unchecked}") pool$( ((unchecked == 1)) || printf s) could not be checked; see ${CNTOOLS_LOG}."
    fi
    cntools_transaction_log POOL "No eligible pool operation=${CNTOOLS_WALLET_REGISTER_OPERATION} unchecked=${unchecked}"
    cntools_ui_render_status info "${reason}"
    cntools_ui_wait; return 3
  fi
  # A lone eligible pool needs no picker; the settings and review name it.
  if (( ${#rows[@]} == 1 )); then
    printf -v "${output}" '%s' "${indices[0]}"
    cntools_transaction_log CHOICE "Pool auto-selected=${CNTOOLS_POOL_NAMES[indices[0]]}"
    return 0
  fi
  cntools_pool_registration_choose selected_choice 'Select pool' "${rows[@]}" Cancel || return $?
  [[ "${selected_choice}" != Cancel ]] || return 1
  for index in "${!rows[@]}"; do
    [[ "${rows[index]}" != "${selected_choice}" ]] || { printf -v "${output}" '%s' "${indices[index]}"; return 0; }
  done
  return 2
}

cntools_pool_wizard_saved_present() {
  local filename=''
  cntools_pool_file_name_into filename config || return 1
  [[ -e "${CNTOOLS_POOL_DIRECTORIES[CNTOOLS_POOL_REG_INDEX]}/${filename}" ]]
}

# The settings menu's 'Reuse saved settings' loads the local draft; actions
# start from the current defaults (chain settings for Modify).
cntools_pool_wizard_saved_apply() {
  local before=''
  before="$(cntools_pool_registration_signature)"
  if ! cntools_pool_config_load; then
    cntools_transaction_log WARN "Saved pool draft rejected pool=${CNTOOLS_POOL_REG_NAME}; current defaults retained"
    # The settings screen follows and repeats this warning.
    cntools_ui_render_status warn 'Saved settings could not be fully validated or resolved. Current defaults were retained; edit the settings manually.'
    return 0
  fi
  if [[ "$(cntools_pool_registration_signature)" == "${before}" ]]; then
    cntools_transaction_log CHOICE "Pool saved settings match the current settings pool=${CNTOOLS_POOL_REG_NAME}"
    # The settings screen follows and repeats this warning.
    cntools_ui_render_status warn 'The saved settings are the same as the current ones; nothing changed.'
    return 0
  fi
  cntools_transaction_log CHOICE "Pool saved settings applied pool=${CNTOOLS_POOL_REG_NAME}"
}

# Owner/reward lookups, the pledge check and the stake setup questions rerun
# only when their inputs changed, so an unrelated edit does not re-ask them.
# "refresh" (changed chain state) checks again and keeps the earlier answers
# in both styles while registration and delegation are unchanged.
CNTOOLS_POOL_WIZARD_STAKE_INPUTS='' CNTOOLS_POOL_WIZARD_PLEDGE_INPUTS=''
cntools_pool_wizard_prepare_stake() {
  local mode="${1:-}" stake_inputs='' pledge_inputs='' before='' reuse='' status=0 back=''
  stake_inputs="${CNTOOLS_POOL_REG_OWNERS}|$(cntools_pool_stake_records)" || return 2
  pledge_inputs="${stake_inputs}|${CNTOOLS_POOL_REG_PLEDGE}"
  # From the review, leaving the pledge question goes back to the settings.
  [[ "${mode}" != review ]] || back=back
  if [[ "${mode}" == refresh || "${stake_inputs}" != "${CNTOOLS_POOL_WIZARD_STAKE_INPUTS}" ]]; then
    before="$(cntools_pool_stake_snapshot)"
    cntools_ui_spin_function 'Checking owner/reward registration and pledge…' cntools_pool_stake_collect || return 2
    if [[ "${mode}" == refresh && "${before}" == "$(cntools_pool_stake_snapshot)" ]]; then
      reuse=reuse
      cntools_transaction_log POOL 'Owner/reward registration and delegation unchanged; earlier stake answers kept'
    fi
    cntools_pool_stake_guidance "${reuse}" "${back}" && cntools_pool_stake_setup_choose "${reuse}" || status=$?
    if ((status != 0)); then
      # The answers were not completed for these inputs: ask again next time,
      # even when the settings return to what they were.
      CNTOOLS_POOL_WIZARD_STAKE_INPUTS='' CNTOOLS_POOL_WIZARD_PLEDGE_INPUTS=''
      return "${status}"
    fi
  elif [[ "${pledge_inputs}" != "${CNTOOLS_POOL_WIZARD_PLEDGE_INPUTS}" ]]; then
    cntools_pool_stake_guidance '' "${back}" || { status=$?; CNTOOLS_POOL_WIZARD_PLEDGE_INPUTS=''; return "${status}"; }
  else
    cntools_transaction_log POOL 'Owners, reward account and pledge unchanged; previous checks and stake setup kept'
  fi
  CNTOOLS_POOL_WIZARD_STAKE_INPUTS="${stake_inputs}"; CNTOOLS_POOL_WIZARD_PLEDGE_INPUTS="${pledge_inputs}"
  CNTOOLS_POOL_CONFIG_SAVED=N
  if cntools_pool_config_save; then CNTOOLS_POOL_CONFIG_SAVED=Y
  else
    cntools_transaction_log WARN "Pool draft save failed pool=${CNTOOLS_POOL_REG_NAME}; transaction retained"
    # The review follows and repeats this warning.
    cntools_ui_render_status warn 'The local draft could not be saved. The transaction can continue; check pool directory/configuration permissions.'
  fi
}

# Register only: Modify's draft path and generic notes add nothing to its result.
cntools_pool_wizard_followups() {
  local record='' label='' setup='' filename='' cert='' counter=''
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-register ]] || return 0
  { if [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-register && "${CNTOOLS_CONFIGURED_POOL_NAME:-}" != "${CNTOOLS_POOL_REG_NAME}" ]]; then
      cntools_table_pair 'Node configuration' "After successful pool registration, set POOL_NAME=\"${CNTOOLS_POOL_REG_NAME}\" in the common env and configure the node with the pool operational certificate/KES/VRF files. CNTools does not edit env." muted
    fi
    cntools_pool_file_name_into filename config
    if [[ "${CNTOOLS_POOL_CONFIG_SAVED:-N}" == Y ]]; then
      cntools_table_pair 'Saved settings' "${CNTOOLS_POOL_DIRECTORIES[CNTOOLS_POOL_REG_INDEX]}/${filename} · local draft, not chain status" muted
    else cntools_table_pair 'Saved settings' 'Not saved · review pool directory permissions' warning; fi
    while IFS= read -r record; do
      label="$(jq -r .label <<< "${record}")"; setup="$(jq -r .setup <<< "${record}")"
      cntools_table_pair "${label} stake setup" "$([[ "${setup}" == delegate ]] && printf 'Registration if needed + pool delegation' || printf 'Reward registration') included in this transaction; effective only after inclusion" success
    done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_STAKE_PLAN}")
    if [[ "${CNTOOLS_POOL_OPCERT_OFFLINE:-N}" == Y ]]; then
      cntools_pool_file_name_into cert opcert; cntools_pool_file_name_into counter counter
      if cntools_pool_registration_cold_encrypted; then
        cntools_table_pair 'Operational certificate' "The cold signing key is encrypted. Use Pool → Decrypt, then Pool → Rotate to issue ${cert}; or issue it on the signing system with the real ${counter}." warning
      elif [[ -n "${CNTOOLS_POOL_REG_COLD_SOURCE}" ]]; then
        # Unsigned package, cold key on this system: Rotate issues it here.
        cntools_table_pair 'Operational certificate' "Issue ${cert} with Pool → Rotate on this system; it uses the cold key here and the real ${counter}." warning
      else
        cntools_table_pair 'Operational certificate' "Use Pool → Rotate → Prepare offline request here, sign it with Pool → Rotate → Sign an offline request on the system that holds the cold key, then reopen Pool → Rotate here to install ${cert}. Never copy the cold signing key to the node." warning
      fi
    elif [[ -n "${CNTOOLS_POOL_OPCERT_NOTE:-}" ]]; then
      cntools_table_pair 'Operational certificate' "${CNTOOLS_POOL_OPCERT_NOTE}" warning
    fi
    cntools_table_pair 'Reward withdrawals' 'DRep delegation is required before withdrawing rewards.' muted
  } | cntools_table_render 'Next steps'
}
