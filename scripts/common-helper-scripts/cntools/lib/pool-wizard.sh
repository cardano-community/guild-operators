#!/usr/bin/env bash
# Legacy wizard guidance, with the same compact transaction review as other actions.
# shellcheck disable=SC2034
cntools_pool_registration_choose_eligible_into() {
  local output="$1" index=0 row='' selected_choice='' status=''
  local -a rows=() indices=()
  cntools_ui_spin_function 'Checking pool eligibility…' cntools_pool_inspect_catalog || return 2
  for index in "${!CNTOOLS_POOL_NAMES[@]}"; do
    [[ "${CNTOOLS_POOL_IDENTITIES[index]}" == 'Verified cold public key' ]] || continue
    status="${CNTOOLS_POOL_CHAIN_STATUS[index]}"
    case "${CNTOOLS_WALLET_REGISTER_OPERATION}:${status}" in
      pool-register:'Not registered'|pool-register:'Not indexed'|pool-register:Retired|pool-modify:Registered|pool-modify:Retiring|pool-retire:Registered|pool-retire:Retiring) ;;
      *) continue ;;
    esac
    row="${CNTOOLS_POOL_NAMES[index]} · ${status}"; rows+=("${row}"); indices+=("${index}")
  done
  if (( ${#rows[@]} == 0 )); then
    cntools_wallet_register_set_error 'No eligible pools with verified public keys and reachable registration state. Register needs an unregistered pool; Modify and Retire need a registered pool.'; return 2
  fi
  cntools_pool_registration_choose selected_choice 'Select pool' "${rows[@]}" Cancel || return $?
  [[ "${selected_choice}" != Cancel ]] || return 1
  for index in "${!rows[@]}"; do
    [[ "${rows[index]}" != "${selected_choice}" ]] || { printf -v "${output}" '%s' "${indices[index]}"; return 0; }
  done
  return 2
}

cntools_pool_wizard_saved_offer() {
  local choice='' filename=''
  cntools_pool_file_name_into filename config || return 2
  [[ -e "${CNTOOLS_POOL_DIRECTORIES[CNTOOLS_POOL_REG_INDEX]}/${filename}" ]] || return 0
  cntools_ui_render_status info 'Saved settings are local drafts, not proof of on-chain state. Modify starts with current/pending chain settings unless you explicitly reuse the draft.'
  cntools_pool_registration_choose choice 'Starting settings' 'Keep current defaults' 'Reuse saved pool settings' || return $?
  [[ "${choice}" == 'Reuse saved pool settings' ]] || return 0
  if ! cntools_pool_config_load; then
    cntools_transaction_log WARN "Saved pool draft rejected pool=${CNTOOLS_POOL_REG_NAME}; current defaults retained"
    cntools_ui_render_status warn 'Saved settings could not be fully validated or resolved. Current defaults were retained; edit the settings manually.'
    cntools_ui_wait
  fi
}

cntools_pool_wizard_prepare_stake() {
  cntools_ui_spin_function 'Checking owner/reward registration and pledge…' cntools_pool_stake_collect || return 2
  cntools_pool_stake_guidance || return $?
  cntools_pool_stake_setup_choose || return $?
  CNTOOLS_POOL_CONFIG_SAVED=N
  if cntools_pool_config_save; then CNTOOLS_POOL_CONFIG_SAVED=Y
  else
    cntools_transaction_log WARN "Pool draft save failed pool=${CNTOOLS_POOL_REG_NAME}; transaction retained"
    cntools_ui_render_status warn 'The local draft could not be saved. The transaction can continue; check pool directory/configuration permissions.'
    cntools_ui_wait
  fi
}

cntools_pool_wizard_followups() {
  local record='' label='' setup='' filename=''
  { if [[ "${CNTOOLS_CONFIGURED_POOL_NAME:-}" != "${CNTOOLS_POOL_REG_NAME}" ]]; then
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
    cntools_table_pair 'Pledge maintenance' 'All owner accounts must be registered, delegated to this pool and funded to fulfill the declared pledge. Recheck after deposits/fees and at rewards snapshots.' warning
    cntools_table_pair 'Reward withdrawals' 'DRep delegation is required before withdrawing rewards.' muted
  } | cntools_table_render 'Next steps'
}
