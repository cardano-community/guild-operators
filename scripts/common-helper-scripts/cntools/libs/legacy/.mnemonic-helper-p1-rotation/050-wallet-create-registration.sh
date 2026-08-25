# shellcheck shell=bash disable=SC2026,SC2034,SC2154,SC2163,SC2206
# Command     : createNewWallet
# Description : creates a new empty wallet folder
createNewWallet() {
  getAnswerAnyCust wallet_name "Name of wallet (non-alphanumeric characters will be replaced with a space)"
  # Remove unwanted characters from wallet name
  wallet_name=${wallet_name//[^[:alnum:]]/_}
  if [[ -z "${wallet_name}" ]]; then
    println ERROR "${FG_RED}ERROR${NC}: Empty wallet name, please retry!"
    waitToProceed && return 1
  fi
  echo
  if ! mkdir -p "${WALLET_FOLDER}/${wallet_name}"; then
    println ERROR "${FG_RED}ERROR${NC}: Failed to create directory for wallet:\n${WALLET_FOLDER}/${wallet_name}"
    waitToProceed && return 1
  fi
  if [[ $(find "${WALLET_FOLDER}/${wallet_name}" -type f -print0 | wc -c) -gt 0 ]]; then
    println "${FG_RED}WARN${NC}: A wallet ${FG_GREEN}$wallet_name${NC} already exists"
    println "      Choose another name or delete the existing one"
    waitToProceed && return 1
  fi
  return 0
}

# Compatibility contract:
#   _cntools_compatibility_wallet_mnemonic_run
#     <prepare|acknowledge|publish|abort|legacy>
#     <phrase-variable> <state-variable>
#     [<base-address-variable> <payment-address-variable>
#      <reward-address-variable>]
#
# The phase interface deliberately passes variable names, never secret values.
# All derivation happens below, in this one maintained implementation.
_cntools_compatibility_wallet_mnemonic_run() {
  local _wmh_phase="${1:-}" _wmh_phrase_name="${2:-}"
  local _wmh_state_name="${3:-}" _wmh_base_name="${4:-}"
  local _wmh_pay_name="${5:-}" _wmh_reward_name="${6:-}"
  local _wmh_name="" _wmh_value="" _wmh_path="" _wmh_tool_name=""
  local _wmh_tool_path="" _wmh_metadata=""
  local _wmh_path_remaining="" _wmh_path_entry="" _wmh_candidate=""
  local _wmh_path_more=N
  local _wmh_owner="" _wmh_mode="" _wmh_links="" _wmh_size=""
  local _wmh_device="" _wmh_inode="" _wmh_identity=""
  local _wmh_root="" _wmh_root_identity="" _wmh_destination=""
  local _wmh_phase_lock="" _wmh_phase_lock_identity=""
  local _wmh_phase_lock_token="" _wmh_phase_lock_seen_token=""
  local _wmh_phase_lock_extra="" _wmh_phase_lock_snapshot=""
  local _wmh_phase_lock_first_snapshot="" _wmh_phase_lock_pid=""
  local _wmh_phase_lock_root_device="" _wmh_phase_lock_saved_umask=""
  local _wmh_phase_lock_deadline=0 _wmh_phase_lock_invalid_since=0
  local _wmh_phase_lock_create_status=0 _wmh_phase_lock_iteration=0
  local _wmh_phase_lock_read_status=0 _wmh_phase_lock_extra_status=0
  local _wmh_phase_lock_open_status=0
  local _wmh_phase_lock_acquired=N _wmh_phase_lock_noclobber_was_on=N
  local _wmh_phase_lock_release_in_progress=N _wmh_phase_lock_bad=N
  local _wmh_destination_kind="" _wmh_destination_identity=""
  local _wmh_lock="" _wmh_lock_identity="" _wmh_stage=""
  local _wmh_stage_identity="" _wmh_state="" _wmh_inventory=""
  local _wmh_ack="" _wmh_cleanup_marker="" _wmh_phrase="" _wmh_phrase_sha=""
  local _wmh_cleanup_marker_value="" _wmh_cleanup_marker_valid=N
  local _wmh_ack_source_identity=""
  local _wmh_inventory_sha="" _wmh_network_kind="" _wmh_network_magic=""
  local _wmh_saved_root="" _wmh_saved_root_identity=""
  local _wmh_saved_destination="" _wmh_saved_destination_kind=""
  local _wmh_saved_destination_identity="" _wmh_saved_lock_identity=""
  local _wmh_saved_stage_identity="" _wmh_saved_wallet_name=""
  local _wmh_saved_account="" _wmh_saved_key="" _wmh_saved_network_kind=""
  local _wmh_saved_network_magic="" _wmh_saved_phrase_sha=""
  local _wmh_saved_inventory_sha="" _wmh_key="" _wmh_extra=""
  local _wmh_publish_base="" _wmh_publish_pay="" _wmh_publish_reward=""
  local _wmh_publish_destination_identity="" _wmh_cleanup_authorized=Y
  local _wmh_expected_key="" _wmh_leaf="" _wmh_digest=""
  local _wmh_expected_identity="" _wmh_input_identity=""
  local _wmh_output_identity="" _wmh_auth_defined=N
  local _wmh_fixed_probe_token=""
  local _wmh_live_identity="" _wmh_live_digest="" _wmh_captured=""
  local _wmh_publish_active_leaf="" _wmh_publish_active_seen=N
  local _wmh_read_value="" _wmh_capture_outer_value=""
  local _wmh_capture_value="" _wmh_capture_chunk=""
  local _wmh_auth_helper_program="" _wmh_capture_worker_program=""
  local _wmh_rest="" _wmh_word="" _wmh_count=0
  local _wmh_caddr_version="" _wmh_caddr_arg="" _wmh_root_prv=""
  local _wmh_role="" _wmh_role_path="" _wmh_hex="" _wmh_es_key=""
  local _wmh_command_status=0 _wmh_status=0 _wmh_cleanup_status=0
  local _wmh_original_status=0 _wmh_abort_status=0
  local _wmh_signal_pending=N _wmh_committed=N _wmh_trace_was_on=N
  local _wmh_publish_rollback_active=N _wmh_publish_retry_state=N
  local _wmh_phrase_was_exported=N
  local _wmh_fixed_cleanup_bad=N
  local _wmh_abort_public_reconciled=N
  local _wmh_stage_missing=N
  local _wmh_created_lock=N _wmh_created_stage=N _wmh_created_destination=N
  local _wmh_ack_created=N _wmh_found="" _wmh_index=0
  local _wmh_saved_hup="" _wmh_saved_int="" _wmh_saved_term=""
  local LC_ALL=C
  local -a _wmh_names=() _wmh_expected_leaves=() _wmh_network_args=()
  local -a _wmh_roles=(payment stake drep cc_cold cc_hot ms_payment ms_stake ms_drep)
  local -a _wmh_role_paths=() _wmh_publish_attempts=() _wmh_cleanup_files=()
  local -a _wmh_public_leaves=()
  local -a _wmh_fixed_probe_tokens=()
  local -A _wmh_seen_names=() _wmh_seen_leaves=() _wmh_tools=()
  local -A _wmh_fixed_fd_owned=()
  local _wmh_fixed_fd_serial=0
  local -A _wmh_xprv=() _wmh_xpub=() _wmh_sk_file=() _wmh_vk_file=()
  local -A _wmh_sk_type=() _wmh_vk_type=() _wmh_vk_description=()
  local -A _wmh_leaf_digests=()
  local -A _wmh_leaf_identities=() _wmh_leaf_links=()


  # Bash locals inherit an ambient variable's export attribute. Remove that
  # attribute explicitly from every private slot that can hold mnemonic,
  # extended-key, key-byte, captured tool material, or an authenticated
  # phase/transaction capability before any child can inherit it. The
  # caller's independently named phrase slot is handled after its name has
  # been validated below.
  builtin export -n _wmh_value _wmh_cleanup_marker_value _wmh_phrase \
    _wmh_phrase_sha _wmh_saved_phrase_sha _wmh_inventory_sha \
    _wmh_saved_inventory_sha _wmh_key _wmh_expected_key _wmh_digest \
    _wmh_live_digest _wmh_captured _wmh_read_value \
    _wmh_capture_outer_value _wmh_capture_value _wmh_capture_chunk \
    _wmh_auth_helper_program _wmh_capture_worker_program \
    _wmh_rest _wmh_word _wmh_root_prv _wmh_hex _wmh_es_key \
    _wmh_xprv _wmh_xpub \
    _wmh_root _wmh_root_identity _wmh_destination \
    _wmh_phase_lock _wmh_phase_lock_identity _wmh_phase_lock_token \
    _wmh_phase_lock_seen_token _wmh_phase_lock_extra \
    _wmh_phase_lock_snapshot _wmh_phase_lock_first_snapshot \
    _wmh_phase_lock_pid _wmh_phase_lock_root_device \
    _wmh_phase_lock_saved_umask \
    _wmh_lock _wmh_lock_identity _wmh_stage _wmh_stage_identity \
    _wmh_state _wmh_inventory _wmh_ack _wmh_cleanup_marker \
    _wmh_saved_root _wmh_saved_root_identity _wmh_saved_destination \
    _wmh_saved_destination_identity _wmh_saved_lock_identity \
    _wmh_saved_stage_identity _wmh_publish_active_leaf \
    _wmh_phrase_was_exported || return 70

  case "${_wmh_phase}" in
    prepare|publish|legacy)
      (( $# == 6 )) || return 64
      _wmh_names=("${_wmh_phrase_name}" "${_wmh_state_name}"
        "${_wmh_base_name}" "${_wmh_pay_name}" "${_wmh_reward_name}")
      ;;
    acknowledge|abort)
      (( $# == 3 )) || return 64
      _wmh_names=("${_wmh_phrase_name}" "${_wmh_state_name}")
      ;;
    *) return 64 ;;
  esac
  for _wmh_name in "${_wmh_names[@]}"; do
    case "${_wmh_name}" in
      _wmh_*|LC_ALL) return 64 ;;
    esac
    [[ "${_wmh_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
       -z "${_wmh_seen_names[${_wmh_name}]+set}" &&
       -v "${_wmh_name}" ]] || return 64
    [[ ! -R "${_wmh_name}" ]] || return 64
    _wmh_value="${!_wmh_name@a}"
    [[ -z "${_wmh_value}" || "${_wmh_value}" == x ]] || return 64
    _wmh_seen_names["${_wmh_name}"]=Y
  done

  # Exported mnemonic slots would expose imported or generated phrases to
  # every administrative/tool child. Preserve the attribute only while the
  # slot is empty; a secret-bearing result deliberately remains unexported.
  [[ -v "${_wmh_phrase_name}" ]] || return 64
  [[ "${!_wmh_phrase_name@a}" != *x* ]] ||
    _wmh_phrase_was_exported=Y
  builtin export -n "${_wmh_phrase_name}" || return 70

  # Descriptor opens and closes below depend on exec's special-builtin
  # redirection semantics.  Fail closed before any filesystem mutation when
  # an ambient function or alias shadows either dispatch builtin.  The split,
  # quoted exec token also prevents alias expansion while this member is
  # sourced.
  if builtin declare -F command >/dev/null 2>&1 ||
     builtin declare -F exec >/dev/null 2>&1 ||
     builtin alias command >/dev/null 2>&1 ||
     builtin alias exec >/dev/null 2>&1 ||
     ! builtin command true ||
     ! builtin exec; then
    if [[ "${_wmh_phrase_was_exported}" == Y &&
          -z "${!_wmh_phrase_name}" ]]; then
      builtin export "${_wmh_phrase_name}" || true
    fi
    return 70
  fi

  # Empty-state abort is intentionally idempotent and independent of ambient
  # configuration/tool availability. It only clears the caller's phrase slot.
  if [[ "${_wmh_phase}" == abort && -z "${!_wmh_state_name}" ]]; then
    builtin printf -v "${_wmh_phrase_name}" '%s' ''
    builtin printf -v "${_wmh_state_name}" '%s' ''
    [[ "${_wmh_phrase_was_exported}" != Y ]] ||
      builtin export "${_wmh_phrase_name}" || return 70
    return 0
  fi

  # Legacy is only the compatibility adapter: the same phase engine remains
  # the sole implementation.
  if [[ "${_wmh_phase}" == legacy ]]; then
    _cntools_compatibility_wallet_mnemonic_run prepare \
      "${_wmh_phrase_name}" "${_wmh_state_name}" \
      "${_wmh_base_name}" "${_wmh_pay_name}" "${_wmh_reward_name}" ||
      {
        _wmh_original_status=$?
        if [[ "${_wmh_phrase_was_exported}" == Y &&
              -z "${!_wmh_phrase_name}" ]]; then
          builtin export "${_wmh_phrase_name}" || return 70
        fi
        return "${_wmh_original_status}"
      }
    _cntools_compatibility_wallet_mnemonic_run acknowledge \
      "${_wmh_phrase_name}" "${_wmh_state_name}" || {
        _wmh_original_status=$?
        _cntools_compatibility_wallet_mnemonic_run abort \
          "${_wmh_phrase_name}" "${_wmh_state_name}" || _wmh_abort_status=$?
        if [[ "${_wmh_phrase_was_exported}" == Y &&
              -z "${!_wmh_phrase_name}" ]]; then
          builtin export "${_wmh_phrase_name}" || return 70
        fi
        (( _wmh_abort_status == 0 )) || return 70
        return "${_wmh_original_status}"
      }
    _cntools_compatibility_wallet_mnemonic_run publish \
      "${_wmh_phrase_name}" "${_wmh_state_name}" \
      "${_wmh_base_name}" "${_wmh_pay_name}" "${_wmh_reward_name}" ||
      {
        _wmh_original_status=$?
        if [[ "${_wmh_phrase_was_exported}" == Y &&
              -z "${!_wmh_phrase_name}" ]]; then
          builtin export "${_wmh_phrase_name}" || return 70
        fi
        return "${_wmh_original_status}"
      }
    if [[ "${_wmh_phrase_was_exported}" == Y &&
          -z "${!_wmh_phrase_name}" ]]; then
      builtin export "${_wmh_phrase_name}" || return 70
    fi
    return 0
  fi

  _wmh_saved_hup="$(builtin trap -p HUP || true)"
  _wmh_saved_int="$(builtin trap -p INT || true)"
  _wmh_saved_term="$(builtin trap -p TERM || true)"
  [[ "$-" != *x* ]] || {
    _wmh_trace_was_on=Y
    set +x
  }
  builtin trap '_wmh_signal_pending=Y' HUP INT TERM

  if [[ "${_wmh_phase}" == prepare || "${_wmh_phase}" == publish ]]; then
    [[ -z "${!_wmh_base_name}" && -z "${!_wmh_pay_name}" &&
       -z "${!_wmh_reward_name}" ]] || _wmh_status=70
  fi
  [[ "${wallet_name:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ &&
     "${wallet_name}" != . && "${wallet_name}" != .. ]] || _wmh_status=70
  [[ "${acct_idx:-}" =~ ^(0|[1-9][0-9]{0,9})$ &&
     "${key_idx:-}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || _wmh_status=70
  if (( _wmh_status == 0 )); then
    (( 10#${acct_idx} <= 2147483647 &&
       10#${key_idx} <= 2147483647 )) || _wmh_status=70
  fi
  case "${NETWORK_IDENTIFIER:-}" in
    --mainnet)
      _wmh_network_kind=mainnet
      _wmh_network_magic=764824073
      _wmh_network_args=(--mainnet)
      [[ "${NWMAGIC:-}" == 764824073 ]] || _wmh_status=70
      ;;
    --testnet-magic\ *)
      _wmh_network_kind=testnet
      _wmh_network_magic="${NETWORK_IDENTIFIER#--testnet-magic }"
      [[ "${_wmh_network_magic}" =~ ^(0|[1-9][0-9]{0,9})$ ]] ||
        _wmh_status=70
      if (( _wmh_status == 0 )); then
        (( 10#${_wmh_network_magic} <= 4294967295 )) || _wmh_status=70
      fi
      [[ "${NWMAGIC:-}" == "${_wmh_network_magic}" ]] || _wmh_status=70
      _wmh_network_args=(--testnet-magic "${_wmh_network_magic}")
      ;;
    *) _wmh_status=70 ;;
  esac

  _wmh_expected_leaves=(
    "${WALLET_DERIVATION_PATH_FILENAME:-}"
    "${WALLET_PAY_SK_FILENAME:-}" "${WALLET_PAY_VK_FILENAME:-}"
    "${WALLET_STAKE_SK_FILENAME:-}" "${WALLET_STAKE_VK_FILENAME:-}"
    "${WALLET_GOV_DREP_SK_FILENAME:-}" "${WALLET_GOV_DREP_VK_FILENAME:-}"
    "${WALLET_GOV_CC_COLD_SK_FILENAME:-}" "${WALLET_GOV_CC_COLD_VK_FILENAME:-}"
    "${WALLET_GOV_CC_HOT_SK_FILENAME:-}" "${WALLET_GOV_CC_HOT_VK_FILENAME:-}"
    "${WALLET_MULTISIG_PREFIX:-}${WALLET_PAY_SK_FILENAME:-}"
    "${WALLET_MULTISIG_PREFIX:-}${WALLET_PAY_VK_FILENAME:-}"
    "${WALLET_MULTISIG_PREFIX:-}${WALLET_STAKE_SK_FILENAME:-}"
    "${WALLET_MULTISIG_PREFIX:-}${WALLET_STAKE_VK_FILENAME:-}"
    "${WALLET_MULTISIG_PREFIX:-}${WALLET_GOV_DREP_SK_FILENAME:-}"
    "${WALLET_MULTISIG_PREFIX:-}${WALLET_GOV_DREP_VK_FILENAME:-}"
    "${WALLET_BASE_ADDR_FILENAME:-}" "${WALLET_PAY_ADDR_FILENAME:-}"
    "${WALLET_STAKE_ADDR_FILENAME:-}" "${WALLET_PAY_CRED_FILENAME:-}"
    "${WALLET_STAKE_CRED_FILENAME:-}"
    "${WALLET_MULTISIG_PREFIX:-}${WALLET_PAY_CRED_FILENAME:-}"
    "${WALLET_MULTISIG_PREFIX:-}${WALLET_STAKE_CRED_FILENAME:-}"
  )
  (( ${#_wmh_expected_leaves[@]} == 24 )) || _wmh_status=70
  for _wmh_leaf in "${_wmh_expected_leaves[@]}"; do
    [[ "${_wmh_leaf}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ &&
       -z "${_wmh_seen_leaves[${_wmh_leaf}]+set}" ]] || _wmh_status=70
    _wmh_seen_leaves["${_wmh_leaf}"]=Y
  done

  # Resolve only ordinary executable files. The authenticated registry resolver
  # is preferred in compatibility actions; legacy callers get the same strict
  # PATH-shadow rejection.
  for _wmh_tool_name in mkdir chmod rm rmdir ln find stat jq mkfifo; do
    _wmh_tool_path=
    if builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1; then
      _cntools_registry_tool_path "${_wmh_tool_name}" _wmh_tool_path ||
        _wmh_status=70
    else
      if builtin declare -F "${_wmh_tool_name}" >/dev/null 2>&1 ||
         builtin alias "${_wmh_tool_name}" >/dev/null 2>&1; then
        _wmh_status=70
      else
        _wmh_path_remaining="${PATH-}"
        while :; do
          _wmh_path_more=N
          if [[ "${_wmh_path_remaining}" == *:* ]]; then
            _wmh_path_entry="${_wmh_path_remaining%%:*}"
            _wmh_path_remaining="${_wmh_path_remaining#*:}"
            _wmh_path_more=Y
          else
            _wmh_path_entry="${_wmh_path_remaining}"
            _wmh_path_remaining=
          fi
          if [[ -z "${_wmh_path_entry}" ]]; then
            _wmh_candidate="${_wmh_tool_name}"
          elif [[ "${_wmh_path_entry}" == / ]]; then
            _wmh_candidate="/${_wmh_tool_name}"
          else
            _wmh_candidate="${_wmh_path_entry%/}/${_wmh_tool_name}"
          fi
          if [[ -f "${_wmh_candidate}" && -x "${_wmh_candidate}" &&
                ! -L "${_wmh_candidate}" ]]; then
            _wmh_tool_path="${_wmh_candidate}"
            break
          fi
          [[ "${_wmh_path_more}" == Y ]] || break
        done
      fi
    fi
    [[ "${_wmh_tool_path}" == /* && -f "${_wmh_tool_path}" &&
       -x "${_wmh_tool_path}" && ! -L "${_wmh_tool_path}" ]] ||
      _wmh_status=70
    _wmh_tools["${_wmh_tool_name}"]="${_wmh_tool_path}"
  done
  _wmh_tool_path=
  if builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 &&
     _cntools_registry_tool_path sha256sum _wmh_tool_path; then
    _wmh_tools[hash]="${_wmh_tool_path}"
    _wmh_tools[hash_kind]=sha256sum
  elif builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1 &&
       _cntools_registry_tool_path shasum _wmh_tool_path; then
    _wmh_tools[hash]="${_wmh_tool_path}"
    _wmh_tools[hash_kind]=shasum
  else
    for _wmh_tool_name in sha256sum shasum; do
      _wmh_tool_path=
      if builtin declare -F "${_wmh_tool_name}" >/dev/null 2>&1 ||
         builtin alias "${_wmh_tool_name}" >/dev/null 2>&1; then
        _wmh_status=70
        break
      fi
      _wmh_path_remaining="${PATH-}"
      while :; do
        _wmh_path_more=N
        if [[ "${_wmh_path_remaining}" == *:* ]]; then
          _wmh_path_entry="${_wmh_path_remaining%%:*}"
          _wmh_path_remaining="${_wmh_path_remaining#*:}"
          _wmh_path_more=Y
        else
          _wmh_path_entry="${_wmh_path_remaining}"
          _wmh_path_remaining=
        fi
        if [[ -z "${_wmh_path_entry}" ]]; then
          _wmh_candidate="${_wmh_tool_name}"
        elif [[ "${_wmh_path_entry}" == / ]]; then
          _wmh_candidate="/${_wmh_tool_name}"
        else
          _wmh_candidate="${_wmh_path_entry%/}/${_wmh_tool_name}"
        fi
        if [[ -f "${_wmh_candidate}" && -x "${_wmh_candidate}" &&
              ! -L "${_wmh_candidate}" ]]; then
          _wmh_tool_path="${_wmh_candidate}"
          break
        fi
        [[ "${_wmh_path_more}" == Y ]] || break
      done
      if [[ -n "${_wmh_tool_path}" ]]; then
        if [[ "${_wmh_tool_path}" == /* ]]; then
          _wmh_tools[hash]="${_wmh_tool_path}"
          _wmh_tools[hash_kind]="${_wmh_tool_name}"
        else
          _wmh_status=70
        fi
        break
      fi
    done
    [[ -n "${_wmh_tools[hash]:-}" ]] || _wmh_status=70
  fi

  # Bind every administrative executable to a safe physical file. Root-owned
  # platform tools may legitimately be hard-linked; operator-owned tools may
  # not be. Group/world-writable or oversized executables are rejected.
  for _wmh_tool_name in mkdir chmod rm rmdir ln find stat jq mkfifo hash; do
    (( _wmh_status == 0 )) || break
    _wmh_tool_path="${_wmh_tools[${_wmh_tool_name}]}"
    if builtin declare -F _cntools_registry_path_has_no_symlinks \
         >/dev/null 2>&1; then
      _cntools_registry_path_has_no_symlinks "${_wmh_tool_path}" ||
        _wmh_status=70
    else
      _wmh_path="${_wmh_tool_path}"
      while [[ "${_wmh_path}" != / && -n "${_wmh_path}" ]]; do
        [[ ! -L "${_wmh_path}" ]] || {
          _wmh_status=70
          break
        }
        _wmh_path="${_wmh_path%/*}"
        [[ -n "${_wmh_path}" ]] || _wmh_path=/
      done
    fi
    (( _wmh_status == 0 )) || break
    if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%l\t%z' \
        "${_wmh_tool_path}" 2>/dev/null)"; then
      :
    else
      _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%h\t%s' -- \
        "${_wmh_tool_path}" 2>/dev/null)" || {
          _wmh_status=70
          break
        }
    fi
    IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
      _wmh_extra <<< "${_wmh_metadata}"
    _wmh_mode="${_wmh_mode#0}"
    [[ -z "${_wmh_extra}" && "${_wmh_mode}" =~ ^[0-7]{3,4}$ &&
       "${_wmh_mode: -2:1}" != [2367] &&
       "${_wmh_mode: -1}" != [2367] &&
       "${_wmh_links}" =~ ^[1-9][0-9]*$ &&
       "${_wmh_size}" =~ ^[1-9][0-9]*$ && "${_wmh_size}" -le 67108864 &&
       ( ( "${_wmh_owner}" == 0 && "${_wmh_links}" -le 16 ) ||
         ( "${_wmh_owner}" == "${EUID}" && "${_wmh_links}" == 1 ) ) ]] ||
      _wmh_status=70
  done

  if (( _wmh_status == 0 )); then
    [[ "${WALLET_FOLDER:-}" == /* && "${WALLET_FOLDER}" != / &&
       "${WALLET_FOLDER}" != */ && "${WALLET_FOLDER}" != *//* &&
       "${WALLET_FOLDER}" != *\\* &&
       ! "${WALLET_FOLDER}" =~ [[:cntrl:]] &&
       -d "${WALLET_FOLDER}" && ! -L "${WALLET_FOLDER}" ]] ||
      _wmh_status=70
  fi
  if (( _wmh_status == 0 )); then
    if builtin declare -F _cntools_registry_path_has_no_symlinks \
         >/dev/null 2>&1; then
      _cntools_registry_path_has_no_symlinks "${WALLET_FOLDER}" ||
        _wmh_status=70
    else
      _wmh_path="${WALLET_FOLDER}"
      while [[ "${_wmh_path}" != / && -n "${_wmh_path}" ]]; do
        [[ ! -L "${_wmh_path}" ]] || {
          _wmh_status=70
          break
        }
        _wmh_path="${_wmh_path%/*}"
        [[ -n "${_wmh_path}" ]] || _wmh_path=/
      done
    fi
  fi
  if (( _wmh_status == 0 )); then
    _wmh_root="$(cd -P -- "${WALLET_FOLDER}" && builtin pwd -P)" ||
      _wmh_status=70
    [[ "${_wmh_root}" == "${WALLET_FOLDER}" ]] || _wmh_status=70
  fi

  if (( _wmh_status == 0 )); then
    if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%l\t%z\t%d\t%i' \
        "${_wmh_root}" 2>/dev/null)"; then
      :
    else
      _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%h\t%s\t%d\t%i' -- \
        "${_wmh_root}" 2>/dev/null)" || _wmh_status=70
    fi
    if (( _wmh_status == 0 )); then
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
        _wmh_device _wmh_inode _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
         ( "${_wmh_mode}" == 700 || "${_wmh_mode}" == 750 ||
           "${_wmh_mode}" == 755 ) &&
         "${_wmh_device}" =~ ^[0-9]+$ && "${_wmh_inode}" =~ ^[0-9]+$ ]] ||
        _wmh_status=70
      _wmh_root_identity="${_wmh_device}:${_wmh_inode}"
    fi
  fi

  # Bash 4.4 can lose an inherited descriptor when independent mnemonic
  # phases reap external children concurrently. Serialize the complete
  # descriptor/tool-bearing portion of every nontrivial phase under one
  # wallet-root lock. Existing holders are observed with builtins only: a
  # waiter never launches another child while the lock is held.
  _wmh_phase_lock="${_wmh_root}/.cntools-wallet-mnemonic.phase.lock"
  if (( _wmh_status == 0 )); then
    _wmh_phase_lock_deadline=$((SECONDS + 30))
    while (( _wmh_status == 0 )) &&
          [[ "${_wmh_phase_lock_acquired}" != Y ]]; do
      if [[ -e "${_wmh_phase_lock}" || -L "${_wmh_phase_lock}" ]]; then
        if [[ ! -f "${_wmh_phase_lock}" || -L "${_wmh_phase_lock}" ||
              ! -O "${_wmh_phase_lock}" ]]; then
          # The holder can remove a valid lock after the outer existence
          # check but before these structural tests.  Treat the composite
          # result as an observation, never as cleanup authority: retain the
          # bounded invalid-state grace and reauthenticate whatever pathname
          # exists on the next iteration.  Persistent unsafe evidence still
          # fails closed when the grace expires.
          (( _wmh_phase_lock_invalid_since != 0 )) ||
            _wmh_phase_lock_invalid_since=${SECONDS}
          if (( SECONDS - _wmh_phase_lock_invalid_since >= 2 )); then
            _wmh_status=70
            break
          fi
          if [[ "${_wmh_signal_pending}" == Y ]] ||
             (( SECONDS >= _wmh_phase_lock_deadline )); then
            _wmh_status=70
            break
          fi
          for _wmh_index in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
            :
          done
          continue
        fi
        _wmh_phase_lock_seen_token=
        _wmh_phase_lock_extra=
        _wmh_phase_lock_read_status=0
        _wmh_phase_lock_extra_status=0
        _wmh_phase_lock_open_status=0
        {
          IFS= builtin read -r _wmh_phase_lock_seen_token ||
            _wmh_phase_lock_read_status=$?
          IFS= builtin read -r _wmh_phase_lock_extra ||
            _wmh_phase_lock_extra_status=$?
        } 2>/dev/null < "${_wmh_phase_lock}" ||
          _wmh_phase_lock_open_status=$?
        if (( _wmh_phase_lock_open_status != 0 )); then
          if [[ "${_wmh_signal_pending}" == Y ]] ||
             (( SECONDS >= _wmh_phase_lock_deadline )); then
            _wmh_status=70
            break
          fi
          continue
        fi
        if (( _wmh_phase_lock_read_status == 0 &&
              _wmh_phase_lock_extra_status != 0 )) &&
           [[ "${_wmh_phase_lock_seen_token}" =~ \
             ^wmhphase\|([1-9][0-9]*)\|([0-9]+)\|([0-9]+)\|([0-9]+)\|([0-9]+)\|([0-9]+)$ &&
              -z "${_wmh_phase_lock_extra}" ]]; then
          _wmh_phase_lock_pid="${BASH_REMATCH[1]}"
          if ! builtin kill -0 "${_wmh_phase_lock_pid}" 2>/dev/null; then
            # The holder can unlink its authenticated lock, exit, and be
            # reaped after this waiter reads the token but before kill -0.
            # Retain the same bounded invalid-token grace and reauthenticate
            # whatever pathname exists on the next iteration.  This never
            # grants cleanup authority over an observed lock: a dead token
            # that remains present still fails closed when the grace expires.
            (( _wmh_phase_lock_invalid_since != 0 )) ||
              _wmh_phase_lock_invalid_since=${SECONDS}
            if (( SECONDS - _wmh_phase_lock_invalid_since >= 2 )); then
              _wmh_status=70
              break
            fi
          else
            _wmh_phase_lock_invalid_since=0
          fi
        else
          (( _wmh_phase_lock_invalid_since != 0 )) ||
            _wmh_phase_lock_invalid_since=${SECONDS}
          if (( SECONDS - _wmh_phase_lock_invalid_since >= 2 )); then
            _wmh_status=70
            break
          fi
        fi
        if [[ "${_wmh_signal_pending}" == Y ]] ||
           (( SECONDS >= _wmh_phase_lock_deadline )); then
          _wmh_status=70
          break
        fi
        # A short builtin-only spin avoids external sleep/wait children and
        # intentionally does not inspect descriptors or the shell job table.
        for _wmh_index in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
          :
        done
        continue
      fi

      _wmh_phase_lock_token="wmhphase|${BASHPID}|${_wmh_root_identity/:/|}|${SECONDS}|${RANDOM}|${RANDOM}"
      _wmh_phase_lock_saved_umask="$(builtin umask)" || {
        _wmh_status=70
        break
      }
      [[ -o noclobber ]] && _wmh_phase_lock_noclobber_was_on=Y
      builtin umask 077
      builtin set -C
      _wmh_phase_lock_create_status=0
      builtin printf '%s\n' "${_wmh_phase_lock_token}" \
        2>/dev/null > "${_wmh_phase_lock}" ||
        _wmh_phase_lock_create_status=$?
      [[ "${_wmh_phase_lock_noclobber_was_on}" == Y ]] || builtin set +C
      builtin umask "${_wmh_phase_lock_saved_umask}" || _wmh_status=70
      if (( _wmh_phase_lock_create_status != 0 )); then
        # Another waiter can win after our absence check, then authenticate,
        # finish, and release before this recheck. A failed noclobber create is
        # not evidence of an invalid lock or of lost cleanup authority. Retry
        # that successor handoff inside the original bound; the next iteration
        # still rejects any extant stale, linked, or otherwise unsafe path.
        if [[ "${_wmh_signal_pending}" == Y ]] ||
           (( SECONDS >= _wmh_phase_lock_deadline )); then
          _wmh_status=70
          break
        fi
        continue
      fi
      _wmh_phase_lock_acquired=Y

      # Authenticate the just-created lock twice around a builtin token read.
      # A hard link injected during the creation window makes link-count two
      # and fails closed; no unsafe pathname is removed on that path.
      _wmh_phase_lock_first_snapshot=
      for _wmh_phase_lock_iteration in 1 2; do
        if _wmh_metadata="$("${_wmh_tools[stat]}" -f \
            $'%u\t%Lp\t%l\t%z\t%d\t%i' "${_wmh_phase_lock}" \
            2>/dev/null)"; then
          :
        else
          _wmh_metadata="$("${_wmh_tools[stat]}" -c \
            $'%u\t%a\t%h\t%s\t%d\t%i' -- "${_wmh_phase_lock}" \
            2>/dev/null)" || {
              _wmh_status=70
              break
            }
        fi
        IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links \
          _wmh_size _wmh_device _wmh_inode _wmh_extra <<< "${_wmh_metadata}"
        _wmh_mode="${_wmh_mode#0}"
        _wmh_phase_lock_snapshot="${_wmh_owner}:${_wmh_mode}:${_wmh_links}:${_wmh_size}:${_wmh_device}:${_wmh_inode}"
        _wmh_phase_lock_root_device="${_wmh_root_identity%%:*}"
        [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
           "${_wmh_mode}" == 600 && "${_wmh_links}" == 1 &&
           "${_wmh_size}" == "$((${#_wmh_phase_lock_token} + 1))" &&
           "${_wmh_device}" == "${_wmh_phase_lock_root_device}" &&
           "${_wmh_inode}" =~ ^[0-9]+$ && -f "${_wmh_phase_lock}" &&
           ! -L "${_wmh_phase_lock}" ]] || {
          _wmh_status=70
          break
        }
        if (( _wmh_phase_lock_iteration == 1 )); then
          _wmh_phase_lock_first_snapshot="${_wmh_phase_lock_snapshot}"
          _wmh_phase_lock_identity="${_wmh_device}:${_wmh_inode}"
          _wmh_phase_lock_seen_token=
          _wmh_phase_lock_extra=
          _wmh_phase_lock_read_status=0
          _wmh_phase_lock_extra_status=0
          _wmh_phase_lock_open_status=0
          {
            IFS= builtin read -r _wmh_phase_lock_seen_token ||
              _wmh_phase_lock_read_status=$?
            IFS= builtin read -r _wmh_phase_lock_extra ||
              _wmh_phase_lock_extra_status=$?
          } 2>/dev/null < "${_wmh_phase_lock}" ||
            _wmh_phase_lock_open_status=$?
          (( _wmh_phase_lock_read_status == 0 &&
             _wmh_phase_lock_extra_status != 0 &&
             _wmh_phase_lock_open_status == 0 )) &&
          [[ "${_wmh_phase_lock_seen_token}" == \
               "${_wmh_phase_lock_token}" &&
             -z "${_wmh_phase_lock_extra}" ]] || {
            _wmh_status=70
            break
          }
        else
          [[ "${_wmh_phase_lock_snapshot}" == \
               "${_wmh_phase_lock_first_snapshot}" ]] || _wmh_status=70
        fi
      done
    done
  fi

  # Do not copy caller secrets until this phase is the only descriptor/tool
  # bearing mnemonic phase under the authenticated wallet root.
  if (( _wmh_status == 0 )) && [[ "${_wmh_phase_lock_acquired}" == Y ]]; then
    _wmh_phrase="${!_wmh_phrase_name}"
    _wmh_state="${!_wmh_state_name}"
  fi
  _wmh_destination="${_wmh_root}/${wallet_name:-}"
  _wmh_lock="${_wmh_root}/.${wallet_name:-}.cntools-wallet-mnemonic.lock"
  _wmh_stage="${_wmh_lock}/stage"
  _wmh_inventory="${_wmh_lock}/inventory"
  _wmh_ack="${_wmh_lock}/acknowledged"
  _wmh_cleanup_marker="${_wmh_lock}/cleanup-authority"
    # These invocation-scoped helpers bind every tool-controlled leaf to an
    # authenticated descriptor. Defining them for all non-legacy phases keeps
    # prepare validation and later publication on the same inode-safe path.
    if (( _wmh_status == 0 )); then
      if builtin declare -F __guild_cntools_wallet_output_authenticate \
           >/dev/null 2>&1 ||
         builtin declare -F __guild_cntools_wallet_fixed_fd_acquire \
           >/dev/null 2>&1 ||
         builtin declare -F __guild_cntools_wallet_fixed_fd_resolve \
           >/dev/null 2>&1 ||
         builtin declare -F __guild_cntools_wallet_fixed_fd_close \
           >/dev/null 2>&1 ||
         builtin declare -F __guild_cntools_wallet_descriptor_authenticate \
          >/dev/null 2>&1 ||
         builtin declare -F __guild_cntools_wallet_output_open_bound \
          >/dev/null 2>&1 ||
         builtin declare -F __guild_cntools_wallet_output_hash_bound \
          >/dev/null 2>&1 ||
         builtin declare -F __guild_cntools_wallet_output_hash_stable \
           >/dev/null 2>&1 ||
         builtin declare -F __guild_cntools_wallet_output_json_bound \
           >/dev/null 2>&1 ||
         builtin declare -F __guild_cntools_wallet_output_read_bound \
           >/dev/null 2>&1 ||
         builtin declare -F __guild_cntools_wallet_output_write_bound \
           >/dev/null 2>&1 ||
         builtin declare -F __guild_cntools_wallet_input_open_bound \
           >/dev/null 2>&1 ||
         builtin declare -F __guild_cntools_wallet_input_close_bound \
           >/dev/null 2>&1 ||
         builtin declare -F __guild_cntools_wallet_capture_bound \
           >/dev/null 2>&1 ||
         builtin declare -F __guild_cntools_wallet_ccli_capture_bound \
           >/dev/null 2>&1; then
        _wmh_status=70
      else
        # Bash 4.4 can corrupt persistent function AST ownership when a caller
        # repeatedly defines and unsets nested helpers. Keep the source in one
        # quoted constant and parse fresh, invocation-owned definitions. No
        # caller or tool-controlled data is interpolated into this program.
        _wmh_auth_helper_program=
        IFS= builtin read -r -d '' _wmh_auth_helper_program <<'GUILD_CNTOOLS_AUTH_HELPERS' || true
        __guild_cntools_wallet_output_authenticate() {
          local _wmh_auth_path="${1:-}" _wmh_auth_expected="${2:-}"
          local _wmh_auth_min="${3:-}" _wmh_auth_max="${4:-}"
          local _wmh_auth_result_name="${5:-}" _wmh_auth_metadata=""
          local _wmh_auth_owner="" _wmh_auth_mode="" _wmh_auth_links=""
          local _wmh_auth_size="" _wmh_auth_device="" _wmh_auth_inode=""
          local _wmh_auth_extra="" _wmh_auth_identity=""
          local _wmh_auth_snapshot="" _wmh_auth_iteration=0

          [[ "${_wmh_auth_path}" == "${_wmh_stage}/"* &&
             "${_wmh_auth_path#"${_wmh_stage}/"}" != */* &&
             "${_wmh_auth_min}" =~ ^(0|[1-9][0-9]*)$ &&
             "${_wmh_auth_max}" =~ ^(0|[1-9][0-9]*)$ &&
             "${_wmh_auth_result_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
             "${_wmh_auth_min}" -le "${_wmh_auth_max}" ]] || return 1
          for _wmh_auth_iteration in 1 2; do
            [[ -f "${_wmh_auth_path}" && ! -L "${_wmh_auth_path}" ]] ||
              return 1
            if _wmh_auth_metadata="$("${_wmh_tools[stat]}" -f \
                $'%u\t%Lp\t%l\t%z\t%d\t%i' "${_wmh_auth_path}" \
                2>/dev/null)"; then
              :
            else
              _wmh_auth_metadata="$("${_wmh_tools[stat]}" -c \
                $'%u\t%a\t%h\t%s\t%d\t%i' -- "${_wmh_auth_path}" \
                2>/dev/null)" || return 1
            fi
            IFS=$'\t' builtin read -r _wmh_auth_owner _wmh_auth_mode \
              _wmh_auth_links _wmh_auth_size _wmh_auth_device \
              _wmh_auth_inode _wmh_auth_extra <<< "${_wmh_auth_metadata}"
            _wmh_auth_mode="${_wmh_auth_mode#0}"
            _wmh_auth_identity="${_wmh_auth_device}:${_wmh_auth_inode}"
            [[ -z "${_wmh_auth_extra}" &&
               "${_wmh_auth_owner}" == "${EUID}" &&
               "${_wmh_auth_mode}" == 600 &&
               "${_wmh_auth_links}" == 1 &&
               "${_wmh_auth_size}" =~ ^(0|[1-9][0-9]*)$ &&
               "${_wmh_auth_size}" -ge "${_wmh_auth_min}" &&
               "${_wmh_auth_size}" -le "${_wmh_auth_max}" &&
               "${_wmh_auth_device}" =~ ^[0-9]+$ &&
               "${_wmh_auth_inode}" =~ ^[0-9]+$ &&
               ( -z "${_wmh_auth_expected}" ||
                 "${_wmh_auth_identity}" == "${_wmh_auth_expected}" ) &&
               -f "${_wmh_auth_path}" && ! -L "${_wmh_auth_path}" ]] ||
              return 1
            if (( _wmh_auth_iteration == 1 )); then
              _wmh_auth_snapshot="${_wmh_auth_metadata}"
            else
              [[ "${_wmh_auth_metadata}" == "${_wmh_auth_snapshot}" ]] ||
                return 1
            fi
          done
          builtin printf -v "${_wmh_auth_result_name}" '%s' \
            "${_wmh_auth_identity}"
        }
        # Bash 4.4 can lose descriptors allocated with {var} while unrelated
        # external children are reaped concurrently. Use only literal FDs from
        # a bounded bank above Bash's ordinary saved-redirection range and
        # process-substitution FD 63. Occupied caller FDs are never replaced.
        __guild_cntools_wallet_fixed_fd_acquire() {
          local _wmh_fixed_mode="${1:-}" _wmh_fixed_path="${2:-}"
          local _wmh_fixed_result_name="${3:-}" _wmh_fixed_fd=0
          local _wmh_fixed_token=""


          [[ "${_wmh_fixed_mode}" =~ ^(ro|wo|rw)$ &&
             "${_wmh_fixed_path}" == /* &&
             "${_wmh_fixed_result_name}" =~ \
               ^[A-Za-z_][A-Za-z0-9_]*$ &&
             ( "${_wmh_signal_pending:-Y}" == N ||
               "${_wmh_publish_rollback_active:-N}" == Y ) ]] || return 1
          for ((_wmh_fixed_fd=64; _wmh_fixed_fd<=79; _wmh_fixed_fd++)); do
            [[ ! -e "/dev/fd/${_wmh_fixed_fd}" &&
               -z "${_wmh_fixed_fd_owned[${_wmh_fixed_fd}]+set}" ]] ||
              continue
            case "${_wmh_fixed_mode}:${_wmh_fixed_fd}" in
              ro:64) ex''ec 64< "${_wmh_fixed_path}" ;;
              ro:65) ex''ec 65< "${_wmh_fixed_path}" ;;
              ro:66) ex''ec 66< "${_wmh_fixed_path}" ;;
              ro:67) ex''ec 67< "${_wmh_fixed_path}" ;;
              ro:68) ex''ec 68< "${_wmh_fixed_path}" ;;
              ro:69) ex''ec 69< "${_wmh_fixed_path}" ;;
              ro:70) ex''ec 70< "${_wmh_fixed_path}" ;;
              ro:71) ex''ec 71< "${_wmh_fixed_path}" ;;
              ro:72) ex''ec 72< "${_wmh_fixed_path}" ;;
              ro:73) ex''ec 73< "${_wmh_fixed_path}" ;;
              ro:74) ex''ec 74< "${_wmh_fixed_path}" ;;
              ro:75) ex''ec 75< "${_wmh_fixed_path}" ;;
              ro:76) ex''ec 76< "${_wmh_fixed_path}" ;;
              ro:77) ex''ec 77< "${_wmh_fixed_path}" ;;
              ro:78) ex''ec 78< "${_wmh_fixed_path}" ;;
              ro:79) ex''ec 79< "${_wmh_fixed_path}" ;;
              wo:64) ex''ec 64> "${_wmh_fixed_path}" ;;
              wo:65) ex''ec 65> "${_wmh_fixed_path}" ;;
              wo:66) ex''ec 66> "${_wmh_fixed_path}" ;;
              wo:67) ex''ec 67> "${_wmh_fixed_path}" ;;
              wo:68) ex''ec 68> "${_wmh_fixed_path}" ;;
              wo:69) ex''ec 69> "${_wmh_fixed_path}" ;;
              wo:70) ex''ec 70> "${_wmh_fixed_path}" ;;
              wo:71) ex''ec 71> "${_wmh_fixed_path}" ;;
              wo:72) ex''ec 72> "${_wmh_fixed_path}" ;;
              wo:73) ex''ec 73> "${_wmh_fixed_path}" ;;
              wo:74) ex''ec 74> "${_wmh_fixed_path}" ;;
              wo:75) ex''ec 75> "${_wmh_fixed_path}" ;;
              wo:76) ex''ec 76> "${_wmh_fixed_path}" ;;
              wo:77) ex''ec 77> "${_wmh_fixed_path}" ;;
              wo:78) ex''ec 78> "${_wmh_fixed_path}" ;;
              wo:79) ex''ec 79> "${_wmh_fixed_path}" ;;
              rw:64) ex''ec 64<> "${_wmh_fixed_path}" ;;
              rw:65) ex''ec 65<> "${_wmh_fixed_path}" ;;
              rw:66) ex''ec 66<> "${_wmh_fixed_path}" ;;
              rw:67) ex''ec 67<> "${_wmh_fixed_path}" ;;
              rw:68) ex''ec 68<> "${_wmh_fixed_path}" ;;
              rw:69) ex''ec 69<> "${_wmh_fixed_path}" ;;
              rw:70) ex''ec 70<> "${_wmh_fixed_path}" ;;
              rw:71) ex''ec 71<> "${_wmh_fixed_path}" ;;
              rw:72) ex''ec 72<> "${_wmh_fixed_path}" ;;
              rw:73) ex''ec 73<> "${_wmh_fixed_path}" ;;
              rw:74) ex''ec 74<> "${_wmh_fixed_path}" ;;
              rw:75) ex''ec 75<> "${_wmh_fixed_path}" ;;
              rw:76) ex''ec 76<> "${_wmh_fixed_path}" ;;
              rw:77) ex''ec 77<> "${_wmh_fixed_path}" ;;
              rw:78) ex''ec 78<> "${_wmh_fixed_path}" ;;
              rw:79) ex''ec 79<> "${_wmh_fixed_path}" ;;
              *) return 1 ;;
            esac || return 1
            _wmh_fixed_fd_serial=$((_wmh_fixed_fd_serial + 1))
            _wmh_fixed_token="wmhfd:${BASHPID}:${_wmh_fixed_fd_serial}:${_wmh_fixed_fd}"
            _wmh_fixed_fd_owned["${_wmh_fixed_fd}"]="${_wmh_fixed_token}"
            if [[ ! -e "/dev/fd/${_wmh_fixed_fd}" ]]; then
              __guild_cntools_wallet_fixed_fd_close \
                "${_wmh_fixed_token}" >/dev/null 2>&1 || true
              return 1
            fi
            builtin printf -v "${_wmh_fixed_result_name}" '%s' \
              "${_wmh_fixed_token}"
            return 0
          done
          return 1
        }
        __guild_cntools_wallet_fixed_fd_resolve() {
          local _wmh_fixed_token="${1:-}" _wmh_fixed_result_name="${2:-}"
          local _wmh_fixed_pid="" _wmh_fixed_serial="" _wmh_fixed_fd=""


          [[ "${_wmh_fixed_result_name}" =~ \
               ^[A-Za-z_][A-Za-z0-9_]*$ &&
             "${_wmh_fixed_token}" =~ \
               ^wmhfd:([1-9][0-9]*):([1-9][0-9]*):(6[4-9]|7[0-9])$ ]] ||
            return 1
          _wmh_fixed_pid="${BASH_REMATCH[1]}"
          _wmh_fixed_serial="${BASH_REMATCH[2]}"
          _wmh_fixed_fd="${BASH_REMATCH[3]}"
          [[ "${_wmh_fixed_pid}" == "${BASHPID}" &&
             "${_wmh_fixed_fd_owned[${_wmh_fixed_fd}]:-}" == \
               "wmhfd:${_wmh_fixed_pid}:${_wmh_fixed_serial}:${_wmh_fixed_fd}" &&
             -e "/dev/fd/${_wmh_fixed_fd}" ]] || return 1
          builtin printf -v "${_wmh_fixed_result_name}" '%s' \
            "${_wmh_fixed_fd}"
        }
        __guild_cntools_wallet_fixed_fd_close() {
          local _wmh_fixed_token="${1:-}" _wmh_fixed_pid=""
          local _wmh_fixed_serial="" _wmh_fixed_fd=""


          [[ "${_wmh_fixed_token}" =~ \
               ^wmhfd:([1-9][0-9]*):([1-9][0-9]*):(6[4-9]|7[0-9])$ ]] ||
            return 1
          _wmh_fixed_pid="${BASH_REMATCH[1]}"
          _wmh_fixed_serial="${BASH_REMATCH[2]}"
          _wmh_fixed_fd="${BASH_REMATCH[3]}"
          [[ "${_wmh_fixed_pid}" == "${BASHPID}" &&
             "${_wmh_fixed_fd_owned[${_wmh_fixed_fd}]:-}" == \
               "wmhfd:${_wmh_fixed_pid}:${_wmh_fixed_serial}:${_wmh_fixed_fd}" ]] ||
            return 1
          case "${_wmh_fixed_fd}" in
            64) ex''ec 64>&- ;; 65) ex''ec 65>&- ;;
            66) ex''ec 66>&- ;; 67) ex''ec 67>&- ;;
            68) ex''ec 68>&- ;; 69) ex''ec 69>&- ;;
            70) ex''ec 70>&- ;; 71) ex''ec 71>&- ;;
            72) ex''ec 72>&- ;; 73) ex''ec 73>&- ;;
            74) ex''ec 74>&- ;; 75) ex''ec 75>&- ;;
            76) ex''ec 76>&- ;; 77) ex''ec 77>&- ;;
            78) ex''ec 78>&- ;; 79) ex''ec 79>&- ;;
            *) return 1 ;;
          esac || return 1
          [[ ! -e "/dev/fd/${_wmh_fixed_fd}" ]] || return 1
          builtin unset "_wmh_fixed_fd_owned[${_wmh_fixed_fd}]"
        }
        __guild_cntools_wallet_descriptor_authenticate() {
          local _wmh_fd_token="${1:-}" _wmh_fd_expected="${2:-}"
          local _wmh_fd_min="${3:-}" _wmh_fd_max="${4:-}"
          local _wmh_fd_expected_links="${5:-1}"
          local _wmh_fd="" _wmh_fd_path="" _wmh_fd_metadata=""
          local _wmh_fd_owner=""
          local _wmh_fd_mode="" _wmh_fd_links="" _wmh_fd_size=""
          local _wmh_fd_device="" _wmh_fd_inode="" _wmh_fd_extra=""

          [[ "${_wmh_fd_expected}" =~ ^[0-9]+:[0-9]+$ &&
             "${_wmh_fd_min}" =~ ^(0|[1-9][0-9]*)$ &&
             "${_wmh_fd_max}" =~ ^(0|[1-9][0-9]*)$ &&
             "${_wmh_fd_expected_links}" =~ ^[12]$ &&
             "${_wmh_fd_min}" -le "${_wmh_fd_max}" ]] || return 1
          __guild_cntools_wallet_fixed_fd_resolve \
            "${_wmh_fd_token}" _wmh_fd || return 1
          _wmh_fd_path="/dev/fd/${_wmh_fd}"
          [[ -f "${_wmh_fd_path}" ]] || return 1
          # BSD stat with no pathname fstats standard input, preserving the
          # real device identity (macOS /dev/fd reports its devfs device).
          # GNU stat lacks that form, but its /dev/fd target reports the real
          # opened object, so use it only as the portable fallback.
          if _wmh_fd_metadata="$("${_wmh_tools[stat]}" -f \
              $'%u\t%Lp\t%l\t%z\t%d\t%i' <&"${_wmh_fd}" 2>/dev/null)"; then
            :
          else
            _wmh_fd_metadata="$("${_wmh_tools[stat]}" -c \
              $'%u\t%a\t%h\t%s\t%d\t%i' -- "${_wmh_fd_path}" \
              2>/dev/null)" || return 1
          fi
          IFS=$'\t' builtin read -r _wmh_fd_owner _wmh_fd_mode \
            _wmh_fd_links _wmh_fd_size _wmh_fd_device _wmh_fd_inode \
            _wmh_fd_extra <<< "${_wmh_fd_metadata}"
          _wmh_fd_mode="${_wmh_fd_mode#0}"
          [[ -z "${_wmh_fd_extra}" && "${_wmh_fd_owner}" == "${EUID}" &&
             "${_wmh_fd_mode}" == 600 &&
             "${_wmh_fd_links}" == "${_wmh_fd_expected_links}" &&
             "${_wmh_fd_size}" =~ ^(0|[1-9][0-9]*)$ &&
             "${_wmh_fd_size}" -ge "${_wmh_fd_min}" &&
             "${_wmh_fd_size}" -le "${_wmh_fd_max}" &&
             "${_wmh_fd_device}:${_wmh_fd_inode}" == \
               "${_wmh_fd_expected}" && -f "${_wmh_fd_path}" ]]
        }
        __guild_cntools_wallet_output_open_bound() {
          local _wmh_open_path="${1:-}" _wmh_open_expected="${2:-}"
          local _wmh_open_min="${3:-}" _wmh_open_max="${4:-}"
          local _wmh_open_result_name="${5:-}" _wmh_open_fd_token=""
          local _wmh_open_expected_links="${6:-1}"

          [[ ( ( "${_wmh_open_path}" == "${_wmh_stage}/"* &&
                 "${_wmh_open_path#"${_wmh_stage}/"}" != */* ) ||
               ( "${_wmh_open_path}" == "${_wmh_destination}/"* &&
                 "${_wmh_open_path#"${_wmh_destination}/"}" != */* ) ) &&
             "${_wmh_open_result_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
            return 1
          if ! __guild_cntools_wallet_fixed_fd_acquire rw \
              "${_wmh_open_path}" _wmh_open_fd_token; then
            return 1
          fi
          if ! __guild_cntools_wallet_descriptor_authenticate \
              "${_wmh_open_fd_token}" "${_wmh_open_expected}" \
              "${_wmh_open_min}" "${_wmh_open_max}" \
              "${_wmh_open_expected_links}"; then
            __guild_cntools_wallet_fixed_fd_close \
              "${_wmh_open_fd_token}" >/dev/null 2>&1 || true
            return 1
          fi
          builtin printf -v "${_wmh_open_result_name}" '%s' \
            "${_wmh_open_fd_token}"
        }
        __guild_cntools_wallet_output_hash_bound() {
          local _wmh_hash_path="${1:-}" _wmh_hash_expected="${2:-}"
          local _wmh_hash_min="${3:-}" _wmh_hash_max="${4:-}"
          local _wmh_hash_result_name="${5:-}" _wmh_hash_fd_token=""
          local _wmh_hash_fd=""
          local _wmh_hash_expected_links="${6:-1}" _wmh_hash_digest=""


          [[ "${_wmh_hash_result_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
            return 1
          __guild_cntools_wallet_output_open_bound \
            "${_wmh_hash_path}" "${_wmh_hash_expected}" \
            "${_wmh_hash_min}" "${_wmh_hash_max}" _wmh_hash_fd_token \
            "${_wmh_hash_expected_links}" || return 1
          __guild_cntools_wallet_fixed_fd_resolve \
            "${_wmh_hash_fd_token}" _wmh_hash_fd || {
              __guild_cntools_wallet_fixed_fd_close \
                "${_wmh_hash_fd_token}" >/dev/null 2>&1 || true
              return 1
            }
          if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
            _wmh_hash_digest="$("${_wmh_tools[hash]}" \
              "/dev/fd/${_wmh_hash_fd}" 2>/dev/null)" || {
                __guild_cntools_wallet_fixed_fd_close \
                  "${_wmh_hash_fd_token}" >/dev/null 2>&1 || true
                return 1
              }
          else
            _wmh_hash_digest="$("${_wmh_tools[hash]}" -a 256 \
              "/dev/fd/${_wmh_hash_fd}" 2>/dev/null)" || {
                __guild_cntools_wallet_fixed_fd_close \
                  "${_wmh_hash_fd_token}" >/dev/null 2>&1 || true
                return 1
              }
          fi
          __guild_cntools_wallet_descriptor_authenticate \
              "${_wmh_hash_fd_token}" "${_wmh_hash_expected}" \
            "${_wmh_hash_min}" "${_wmh_hash_max}" \
            "${_wmh_hash_expected_links}" || {
              __guild_cntools_wallet_fixed_fd_close \
                "${_wmh_hash_fd_token}" >/dev/null 2>&1 || true
              return 1
            }
          __guild_cntools_wallet_fixed_fd_close \
            "${_wmh_hash_fd_token}" || return 1
          _wmh_hash_digest="${_wmh_hash_digest%% *}"
          [[ "${_wmh_hash_digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
          builtin printf -v "${_wmh_hash_result_name}" '%s' \
            "${_wmh_hash_digest}"
        }
        __guild_cntools_wallet_output_hash_stable() {
          local _wmh_stable_path="${1:-}" _wmh_stable_expected="${2:-}"
          local _wmh_stable_min="${3:-}" _wmh_stable_max="${4:-}"
          local _wmh_stable_result_name="${5:-}"
          local _wmh_stable_expected_links="${6:-1}"
          local _wmh_stable_first="" _wmh_stable_second=""

          [[ "${_wmh_stable_result_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
            return 1
          __guild_cntools_wallet_output_hash_bound \
            "${_wmh_stable_path}" "${_wmh_stable_expected}" \
            "${_wmh_stable_min}" "${_wmh_stable_max}" \
            _wmh_stable_first "${_wmh_stable_expected_links}" || return 1
          __guild_cntools_wallet_output_hash_bound \
            "${_wmh_stable_path}" "${_wmh_stable_expected}" \
            "${_wmh_stable_min}" "${_wmh_stable_max}" \
            _wmh_stable_second "${_wmh_stable_expected_links}" || return 1
          [[ "${_wmh_stable_second}" == "${_wmh_stable_first}" ]] || return 1
          builtin printf -v "${_wmh_stable_result_name}" '%s' \
            "${_wmh_stable_first}"
        }
        __guild_cntools_wallet_output_json_bound() {
          local _wmh_json_path="${1:-}" _wmh_json_expected="${2:-}"
          local _wmh_json_min="${3:-}" _wmh_json_max="${4:-}"
          local _wmh_json_kind="${5:-}" _wmh_json_type="${6:-}"
          local _wmh_json_before="" _wmh_json_after=""
          local _wmh_json_fd_token="" _wmh_json_fd=""


          __guild_cntools_wallet_output_hash_bound \
            "${_wmh_json_path}" "${_wmh_json_expected}" \
            "${_wmh_json_min}" "${_wmh_json_max}" _wmh_json_before || return 1
          __guild_cntools_wallet_output_open_bound \
            "${_wmh_json_path}" "${_wmh_json_expected}" \
            "${_wmh_json_min}" "${_wmh_json_max}" \
            _wmh_json_fd_token || return 1
          __guild_cntools_wallet_fixed_fd_resolve \
            "${_wmh_json_fd_token}" _wmh_json_fd || {
              __guild_cntools_wallet_fixed_fd_close \
                "${_wmh_json_fd_token}" >/dev/null 2>&1 || true
              return 1
            }
          case "${_wmh_json_kind}" in
            sk)
              "${_wmh_tools[jq]}" -e --arg t "${_wmh_json_type}" '
                type == "object" and
                keys == ["cborHex","description","type"] and .type == $t and
                (.description | type == "string" and length <= 128) and
                (.cborHex | type == "string" and
                  test("^5880[0-9a-f]{256}$"))
              ' "/dev/fd/${_wmh_json_fd}" >/dev/null 2>/dev/null
              ;;
            evk)
              "${_wmh_tools[jq]}" -e --arg t "${_wmh_json_type}" '
                type == "object" and
                keys == ["cborHex","description","type"] and .type == $t and
                (.description | type == "string" and length <= 128) and
                (.cborHex | type == "string" and
                  test("^[0-9a-fA-F]{128}$"))
              ' "/dev/fd/${_wmh_json_fd}" >/dev/null 2>/dev/null
              ;;
            vk)
              "${_wmh_tools[jq]}" -e --arg t "${_wmh_json_type}" '
                type == "object" and
                keys == ["cborHex","description","type"] and .type == $t and
                (.description | type == "string" and length <= 128) and
                (.cborHex | type == "string" and
                  test("^5820[0-9a-fA-F]{64}$"))
              ' "/dev/fd/${_wmh_json_fd}" >/dev/null 2>/dev/null
              ;;
            *)
              __guild_cntools_wallet_fixed_fd_close \
                "${_wmh_json_fd_token}" >/dev/null 2>&1 || true
              return 1
              ;;
          esac || {
            __guild_cntools_wallet_fixed_fd_close \
              "${_wmh_json_fd_token}" >/dev/null 2>&1 || true
            return 1
          }
          __guild_cntools_wallet_descriptor_authenticate \
              "${_wmh_json_fd_token}" "${_wmh_json_expected}" \
            "${_wmh_json_min}" "${_wmh_json_max}" || {
              __guild_cntools_wallet_fixed_fd_close \
                "${_wmh_json_fd_token}" >/dev/null 2>&1 || true
              return 1
            }
          __guild_cntools_wallet_fixed_fd_close \
            "${_wmh_json_fd_token}" || return 1
          __guild_cntools_wallet_output_hash_bound \
            "${_wmh_json_path}" "${_wmh_json_expected}" \
            "${_wmh_json_min}" "${_wmh_json_max}" _wmh_json_after || return 1
          [[ "${_wmh_json_after}" == "${_wmh_json_before}" ]] || return 1
        }
        __guild_cntools_wallet_output_read_bound() {
          local _wmh_read_path="${1:-}" _wmh_read_expected="${2:-}"
          local _wmh_read_min="${3:-}" _wmh_read_max="${4:-}"
          local _wmh_read_result_name="${5:-}" _wmh_read_before=""
          local _wmh_read_after="" _wmh_read_value=""
          local _wmh_read_fd_token="" _wmh_read_fd=""

          builtin export -n _wmh_read_value || return 1

          [[ "${_wmh_read_result_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
            return 1
          __guild_cntools_wallet_output_hash_bound \
            "${_wmh_read_path}" "${_wmh_read_expected}" \
            "${_wmh_read_min}" "${_wmh_read_max}" _wmh_read_before || return 1
          __guild_cntools_wallet_output_open_bound \
            "${_wmh_read_path}" "${_wmh_read_expected}" \
            "${_wmh_read_min}" "${_wmh_read_max}" \
            _wmh_read_fd_token || return 1
          __guild_cntools_wallet_fixed_fd_resolve \
            "${_wmh_read_fd_token}" _wmh_read_fd || {
              __guild_cntools_wallet_fixed_fd_close \
                "${_wmh_read_fd_token}" >/dev/null 2>&1 || true
              return 1
            }
          _wmh_read_value="$(< "/dev/fd/${_wmh_read_fd}")"
          __guild_cntools_wallet_descriptor_authenticate \
            "${_wmh_read_fd_token}" "${_wmh_read_expected}" \
            "${_wmh_read_min}" "${_wmh_read_max}" || {
              __guild_cntools_wallet_fixed_fd_close \
                "${_wmh_read_fd_token}" >/dev/null 2>&1 || true
              return 1
            }
          __guild_cntools_wallet_fixed_fd_close \
            "${_wmh_read_fd_token}" || return 1
          __guild_cntools_wallet_output_hash_bound \
            "${_wmh_read_path}" "${_wmh_read_expected}" \
            "${_wmh_read_min}" "${_wmh_read_max}" _wmh_read_after || return 1
          [[ "${_wmh_read_after}" == "${_wmh_read_before}" ]] || return 1
          builtin printf -v "${_wmh_read_result_name}" '%s' \
            "${_wmh_read_value}"
        }
        __guild_cntools_wallet_output_write_bound() {
          local _wmh_write_path="${1:-}" _wmh_write_expected="${2:-}"
          local _wmh_write_min="${3:-}" _wmh_write_max="${4:-}"
          local _wmh_write_value_name="${5:-}" _wmh_write_style="${6:-raw}"
          local _wmh_write_fd_token="" _wmh_write_fd=""
          local _wmh_write_digest=""


          [[ "${_wmh_write_value_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
             ( "${_wmh_write_style}" == raw ||
               "${_wmh_write_style}" == line ) ]] || return 1
          __guild_cntools_wallet_output_open_bound \
            "${_wmh_write_path}" "${_wmh_write_expected}" 0 0 \
            _wmh_write_fd_token || return 1
          __guild_cntools_wallet_fixed_fd_resolve \
            "${_wmh_write_fd_token}" _wmh_write_fd || {
              __guild_cntools_wallet_fixed_fd_close \
                "${_wmh_write_fd_token}" >/dev/null 2>&1 || true
              return 1
            }
          if [[ "${_wmh_write_style}" == line ]]; then
            builtin printf '%s\n' "${!_wmh_write_value_name}" \
              >&"${_wmh_write_fd}" || {
                __guild_cntools_wallet_fixed_fd_close \
                  "${_wmh_write_fd_token}" >/dev/null 2>&1 || true
                return 1
              }
          else
            builtin printf '%s' "${!_wmh_write_value_name}" \
              >&"${_wmh_write_fd}" || {
                __guild_cntools_wallet_fixed_fd_close \
                  "${_wmh_write_fd_token}" >/dev/null 2>&1 || true
                return 1
              }
          fi
          __guild_cntools_wallet_descriptor_authenticate \
            "${_wmh_write_fd_token}" "${_wmh_write_expected}" \
            "${_wmh_write_min}" "${_wmh_write_max}" || {
              __guild_cntools_wallet_fixed_fd_close \
                "${_wmh_write_fd_token}" >/dev/null 2>&1 || true
              return 1
            }
          __guild_cntools_wallet_fixed_fd_close \
            "${_wmh_write_fd_token}" || return 1
          __guild_cntools_wallet_output_hash_stable \
            "${_wmh_write_path}" "${_wmh_write_expected}" \
            "${_wmh_write_min}" "${_wmh_write_max}" \
            _wmh_write_digest || return 1
        }
        __guild_cntools_wallet_input_open_bound() {
          local _wmh_input_path="${1:-}" _wmh_input_expected="${2:-}"
          local _wmh_input_min="${3:-}" _wmh_input_max="${4:-}"
          local _wmh_input_fd_name="${5:-}" _wmh_input_digest_name="${6:-}"
          local _wmh_input_fd_token="" _wmh_input_digest=""

          [[ "${_wmh_input_fd_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
             "${_wmh_input_digest_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
            return 1
          __guild_cntools_wallet_output_hash_stable \
            "${_wmh_input_path}" "${_wmh_input_expected}" \
            "${_wmh_input_min}" "${_wmh_input_max}" \
            _wmh_input_digest || return 1
          __guild_cntools_wallet_output_open_bound \
            "${_wmh_input_path}" "${_wmh_input_expected}" \
            "${_wmh_input_min}" "${_wmh_input_max}" \
            _wmh_input_fd_token ||
            return 1
          builtin printf -v "${_wmh_input_fd_name}" '%s' \
            "${_wmh_input_fd_token}"
          builtin printf -v "${_wmh_input_digest_name}" '%s' \
            "${_wmh_input_digest}"
        }
        __guild_cntools_wallet_input_close_bound() {
          local _wmh_input_fd_token="${1:-}" _wmh_input_path="${2:-}"
          local _wmh_input_expected="${3:-}" _wmh_input_min="${4:-}"
          local _wmh_input_max="${5:-}" _wmh_input_before="${6:-}"
          local _wmh_input_after="" _wmh_input_valid=Y

          __guild_cntools_wallet_descriptor_authenticate \
            "${_wmh_input_fd_token}" "${_wmh_input_expected}" \
            "${_wmh_input_min}" "${_wmh_input_max}" || _wmh_input_valid=N
          __guild_cntools_wallet_fixed_fd_close \
            "${_wmh_input_fd_token}" || _wmh_input_valid=N
          __guild_cntools_wallet_output_hash_stable \
            "${_wmh_input_path}" "${_wmh_input_expected}" \
            "${_wmh_input_min}" "${_wmh_input_max}" \
            _wmh_input_after || _wmh_input_valid=N
          [[ "${_wmh_input_after}" == "${_wmh_input_before}" ]] ||
            _wmh_input_valid=N
          [[ "${_wmh_input_valid}" == Y ]]
        }
        # macOS fdescfs rejects writable O_TRUNC reopens of /dev/fd/N. Tool
        # output therefore never receives a pathname: private FIFOs are opened
        # through authenticated tools and unlinked before the exec'd child can
        # consume input or write output, leaving only anonymous pipe FDs. The
        # parent drains at most max+1 bytes and deterministically kills/reaps
        # on a signal, NUL delimiter, or overflow. Secret input never appears
        # in argv.
        _wmh_capture_worker_program=
        IFS= builtin read -r -d '' _wmh_capture_worker_program <<'GUILD_CNTOOLS_CAPTURE_WORKER' || true
          local _wmh_capture_value="" _wmh_capture_chunk=""
          local _wmh_capture_read_fd="" _wmh_capture_output_write_fd=""
          local _wmh_capture_input_read_fd="" _wmh_capture_input_write_fd=""
          local _wmh_capture_input_keeper_fd=""
          local _wmh_capture_output_keeper_fd=""
          local _wmh_capture_read_fd_number=""
          local _wmh_capture_output_write_fd_number=""
          local _wmh_capture_input_read_fd_number=""
          local _wmh_capture_input_write_fd_number=""
          local _wmh_capture_input_keeper_fd_number=""
          local _wmh_capture_output_keeper_fd_number=""
          local _wmh_capture_fixed_fd_serial=0
          local -A _wmh_capture_fixed_fd_owned=()
          local _wmh_capture_input_pipe="${_wmh_lock}/.capture-input.pipe"
          local _wmh_capture_output_pipe="${_wmh_lock}/.capture-output.pipe"
          local _wmh_capture_pid="" _wmh_capture_bad=N
          local _wmh_capture_read_status=0 _wmh_capture_wait_status=0
          local _wmh_capture_remaining=0 _wmh_capture_timeout_ticks=0
          local _wmh_capture_monitor_was_on=N
          builtin export -n _wmh_capture_value _wmh_capture_chunk ||
            return 70
          if [[ -n "${_wmh_capture_input_name}" ]]; then
            builtin export -n "${_wmh_capture_input_name}" || return 70
          fi
          __guild_cntools_wallet_capture_fixed_fd_acquire() {
            local _wmh_cfd_mode="${1:-}" _wmh_cfd_path="${2:-}"
            local _wmh_cfd_token_name="${3:-}" _wmh_cfd_number_name="${4:-}"
            local _wmh_cfd_fd=0 _wmh_cfd_token=""


            [[ "${_wmh_cfd_mode}" =~ ^(ro|wo|rw)$ &&
               "${_wmh_cfd_path}" == /* &&
               "${_wmh_cfd_token_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
               "${_wmh_cfd_number_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
               "${_wmh_signal_pending}" == N ]] || return 1
            for ((_wmh_cfd_fd=64; _wmh_cfd_fd<=79; _wmh_cfd_fd++)); do
              [[ ! -e "/dev/fd/${_wmh_cfd_fd}" &&
                 -z "${_wmh_capture_fixed_fd_owned[${_wmh_cfd_fd}]+set}" ]] ||
                continue
              case "${_wmh_cfd_mode}:${_wmh_cfd_fd}" in
                ro:64) ex''ec 64< "${_wmh_cfd_path}" ;;
                ro:65) ex''ec 65< "${_wmh_cfd_path}" ;;
                ro:66) ex''ec 66< "${_wmh_cfd_path}" ;;
                ro:67) ex''ec 67< "${_wmh_cfd_path}" ;;
                ro:68) ex''ec 68< "${_wmh_cfd_path}" ;;
                ro:69) ex''ec 69< "${_wmh_cfd_path}" ;;
                ro:70) ex''ec 70< "${_wmh_cfd_path}" ;;
                ro:71) ex''ec 71< "${_wmh_cfd_path}" ;;
                ro:72) ex''ec 72< "${_wmh_cfd_path}" ;;
                ro:73) ex''ec 73< "${_wmh_cfd_path}" ;;
                ro:74) ex''ec 74< "${_wmh_cfd_path}" ;;
                ro:75) ex''ec 75< "${_wmh_cfd_path}" ;;
                ro:76) ex''ec 76< "${_wmh_cfd_path}" ;;
                ro:77) ex''ec 77< "${_wmh_cfd_path}" ;;
                ro:78) ex''ec 78< "${_wmh_cfd_path}" ;;
                ro:79) ex''ec 79< "${_wmh_cfd_path}" ;;
                wo:64) ex''ec 64> "${_wmh_cfd_path}" ;;
                wo:65) ex''ec 65> "${_wmh_cfd_path}" ;;
                wo:66) ex''ec 66> "${_wmh_cfd_path}" ;;
                wo:67) ex''ec 67> "${_wmh_cfd_path}" ;;
                wo:68) ex''ec 68> "${_wmh_cfd_path}" ;;
                wo:69) ex''ec 69> "${_wmh_cfd_path}" ;;
                wo:70) ex''ec 70> "${_wmh_cfd_path}" ;;
                wo:71) ex''ec 71> "${_wmh_cfd_path}" ;;
                wo:72) ex''ec 72> "${_wmh_cfd_path}" ;;
                wo:73) ex''ec 73> "${_wmh_cfd_path}" ;;
                wo:74) ex''ec 74> "${_wmh_cfd_path}" ;;
                wo:75) ex''ec 75> "${_wmh_cfd_path}" ;;
                wo:76) ex''ec 76> "${_wmh_cfd_path}" ;;
                wo:77) ex''ec 77> "${_wmh_cfd_path}" ;;
                wo:78) ex''ec 78> "${_wmh_cfd_path}" ;;
                wo:79) ex''ec 79> "${_wmh_cfd_path}" ;;
                rw:64) ex''ec 64<> "${_wmh_cfd_path}" ;;
                rw:65) ex''ec 65<> "${_wmh_cfd_path}" ;;
                rw:66) ex''ec 66<> "${_wmh_cfd_path}" ;;
                rw:67) ex''ec 67<> "${_wmh_cfd_path}" ;;
                rw:68) ex''ec 68<> "${_wmh_cfd_path}" ;;
                rw:69) ex''ec 69<> "${_wmh_cfd_path}" ;;
                rw:70) ex''ec 70<> "${_wmh_cfd_path}" ;;
                rw:71) ex''ec 71<> "${_wmh_cfd_path}" ;;
                rw:72) ex''ec 72<> "${_wmh_cfd_path}" ;;
                rw:73) ex''ec 73<> "${_wmh_cfd_path}" ;;
                rw:74) ex''ec 74<> "${_wmh_cfd_path}" ;;
                rw:75) ex''ec 75<> "${_wmh_cfd_path}" ;;
                rw:76) ex''ec 76<> "${_wmh_cfd_path}" ;;
                rw:77) ex''ec 77<> "${_wmh_cfd_path}" ;;
                rw:78) ex''ec 78<> "${_wmh_cfd_path}" ;;
                rw:79) ex''ec 79<> "${_wmh_cfd_path}" ;;
                *) return 1 ;;
              esac || return 1
              _wmh_capture_fixed_fd_serial=$((_wmh_capture_fixed_fd_serial + 1))
              _wmh_cfd_token="wmhcfd:${BASHPID}:${_wmh_capture_fixed_fd_serial}:${_wmh_cfd_fd}"
              _wmh_capture_fixed_fd_owned["${_wmh_cfd_fd}"]="${_wmh_cfd_token}"
              if [[ ! -e "/dev/fd/${_wmh_cfd_fd}" ]]; then
                __guild_cntools_wallet_capture_fixed_fd_close \
                  "${_wmh_cfd_token}" >/dev/null 2>&1 || true
                return 1
              fi
              builtin printf -v "${_wmh_cfd_token_name}" '%s' \
                "${_wmh_cfd_token}"
              builtin printf -v "${_wmh_cfd_number_name}" '%s' \
                "${_wmh_cfd_fd}"
              return 0
            done
            return 1
          }
          __guild_cntools_wallet_capture_fixed_fd_close() {
            local _wmh_cfd_token="${1:-}" _wmh_cfd_pid=""
            local _wmh_cfd_serial="" _wmh_cfd_fd=""


            [[ "${_wmh_cfd_token}" =~ \
                 ^wmhcfd:([1-9][0-9]*):([1-9][0-9]*):(6[4-9]|7[0-9])$ ]] ||
              return 1
            _wmh_cfd_pid="${BASH_REMATCH[1]}"
            _wmh_cfd_serial="${BASH_REMATCH[2]}"
            _wmh_cfd_fd="${BASH_REMATCH[3]}"
            [[ "${_wmh_capture_fixed_fd_owned[${_wmh_cfd_fd}]:-}" == \
                 "wmhcfd:${_wmh_cfd_pid}:${_wmh_cfd_serial}:${_wmh_cfd_fd}" ]] ||
              return 1
            case "${_wmh_cfd_fd}" in
              64) ex''ec 64>&- ;; 65) ex''ec 65>&- ;;
              66) ex''ec 66>&- ;; 67) ex''ec 67>&- ;;
              68) ex''ec 68>&- ;; 69) ex''ec 69>&- ;;
              70) ex''ec 70>&- ;; 71) ex''ec 71>&- ;;
              72) ex''ec 72>&- ;; 73) ex''ec 73>&- ;;
              74) ex''ec 74>&- ;; 75) ex''ec 75>&- ;;
              76) ex''ec 76>&- ;; 77) ex''ec 77>&- ;;
              78) ex''ec 78>&- ;; 79) ex''ec 79>&- ;;
              *) return 1 ;;
            esac || return 1
            [[ ! -e "/dev/fd/${_wmh_cfd_fd}" ]] || return 1
            builtin unset \
              "_wmh_capture_fixed_fd_owned[${_wmh_cfd_fd}]"
          }
          __guild_cntools_wallet_capture_interrupt() {
            _wmh_signal_pending=Y
            [[ ! -p "${_wmh_capture_input_pipe}" ||
               -L "${_wmh_capture_input_pipe}" ]] ||
              "${_wmh_tools[rm]}" -f -- "${_wmh_capture_input_pipe}" || true
            [[ ! -p "${_wmh_capture_output_pipe}" ||
               -L "${_wmh_capture_output_pipe}" ]] ||
              "${_wmh_tools[rm]}" -f -- "${_wmh_capture_output_pipe}" || true
            if [[ "${_wmh_capture_pid}" =~ ^[1-9][0-9]*$ ]]; then
              builtin kill -TERM -- "-${_wmh_capture_pid}" \
                2>/dev/null || true
              builtin kill -TERM "${_wmh_capture_pid}" 2>/dev/null || true
              builtin kill -KILL -- "-${_wmh_capture_pid}" \
                2>/dev/null || true
              builtin kill -KILL "${_wmh_capture_pid}" 2>/dev/null || true
            fi
          }
          builtin trap '__guild_cntools_wallet_capture_interrupt' HUP INT TERM


          [[ "${_wmh_capture_max}" =~ ^[1-9][0-9]*$ &&
             "${_wmh_capture_max}" -le 65536 &&
             ( -z "${_wmh_capture_input_name}" ||
               "${_wmh_capture_input_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ) &&
             $# -gt 0 ]] || return 1
          [[ ! -e "${_wmh_capture_input_pipe}" &&
             ! -L "${_wmh_capture_input_pipe}" &&
             ! -e "${_wmh_capture_output_pipe}" &&
             ! -L "${_wmh_capture_output_pipe}" ]] || return 70
          if ! "${_wmh_tools[mkfifo]}" -m 0600 -- \
              "${_wmh_capture_input_pipe}" ||
             ! "${_wmh_tools[mkfifo]}" -m 0600 -- \
              "${_wmh_capture_output_pipe}" ||
             [[ ! -p "${_wmh_capture_input_pipe}" ||
                -L "${_wmh_capture_input_pipe}" ||
                ! -p "${_wmh_capture_output_pipe}" ||
                -L "${_wmh_capture_output_pipe}" ]] ||
             ! __guild_cntools_wallet_capture_fixed_fd_acquire rw \
                "${_wmh_capture_input_pipe}" \
                _wmh_capture_input_keeper_fd \
                _wmh_capture_input_keeper_fd_number ||
             ! __guild_cntools_wallet_capture_fixed_fd_acquire rw \
                "${_wmh_capture_output_pipe}" \
                _wmh_capture_output_keeper_fd \
                _wmh_capture_output_keeper_fd_number ||
             ! __guild_cntools_wallet_capture_fixed_fd_acquire ro \
                "${_wmh_capture_input_pipe}" \
                _wmh_capture_input_read_fd \
                _wmh_capture_input_read_fd_number ||
             ! __guild_cntools_wallet_capture_fixed_fd_acquire wo \
                "${_wmh_capture_input_pipe}" \
                _wmh_capture_input_write_fd \
                _wmh_capture_input_write_fd_number ||
             ! __guild_cntools_wallet_capture_fixed_fd_acquire ro \
                "${_wmh_capture_output_pipe}" _wmh_capture_read_fd \
                _wmh_capture_read_fd_number ||
             ! __guild_cntools_wallet_capture_fixed_fd_acquire wo \
                "${_wmh_capture_output_pipe}" \
                _wmh_capture_output_write_fd \
                _wmh_capture_output_write_fd_number; then
            [[ -z "${_wmh_capture_input_read_fd}" ]] ||
              __guild_cntools_wallet_capture_fixed_fd_close \
                "${_wmh_capture_input_read_fd}" >/dev/null 2>&1 || true
            [[ -z "${_wmh_capture_input_write_fd}" ]] ||
              __guild_cntools_wallet_capture_fixed_fd_close \
                "${_wmh_capture_input_write_fd}" >/dev/null 2>&1 || true
            [[ -z "${_wmh_capture_read_fd}" ]] ||
              __guild_cntools_wallet_capture_fixed_fd_close \
                "${_wmh_capture_read_fd}" >/dev/null 2>&1 || true
            [[ -z "${_wmh_capture_output_write_fd}" ]] ||
              __guild_cntools_wallet_capture_fixed_fd_close \
                "${_wmh_capture_output_write_fd}" >/dev/null 2>&1 || true
            [[ -z "${_wmh_capture_input_keeper_fd}" ]] ||
              __guild_cntools_wallet_capture_fixed_fd_close \
                "${_wmh_capture_input_keeper_fd}" >/dev/null 2>&1 || true
            [[ -z "${_wmh_capture_output_keeper_fd}" ]] ||
              __guild_cntools_wallet_capture_fixed_fd_close \
                "${_wmh_capture_output_keeper_fd}" >/dev/null 2>&1 || true
            [[ ! -p "${_wmh_capture_input_pipe}" ||
               -L "${_wmh_capture_input_pipe}" ]] ||
              "${_wmh_tools[rm]}" -f -- "${_wmh_capture_input_pipe}" || true
            [[ ! -p "${_wmh_capture_output_pipe}" ||
               -L "${_wmh_capture_output_pipe}" ]] ||
              "${_wmh_tools[rm]}" -f -- "${_wmh_capture_output_pipe}" || true
            return 70
          fi
          if ! "${_wmh_tools[rm]}" -f -- "${_wmh_capture_input_pipe}" \
              "${_wmh_capture_output_pipe}" ||
             [[ -e "${_wmh_capture_input_pipe}" ||
                -L "${_wmh_capture_input_pipe}" ||
                -e "${_wmh_capture_output_pipe}" ||
                -L "${_wmh_capture_output_pipe}" ]]; then
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_input_read_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_input_write_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_read_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_output_write_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_input_keeper_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_output_keeper_fd}" >/dev/null 2>&1 || true
            [[ ! -p "${_wmh_capture_input_pipe}" ||
               -L "${_wmh_capture_input_pipe}" ]] ||
              "${_wmh_tools[rm]}" -f -- "${_wmh_capture_input_pipe}" || true
            [[ ! -p "${_wmh_capture_output_pipe}" ||
               -L "${_wmh_capture_output_pipe}" ]] ||
              "${_wmh_tools[rm]}" -f -- "${_wmh_capture_output_pipe}" || true
            return 70
          fi
          __guild_cntools_wallet_capture_fixed_fd_close \
            "${_wmh_capture_input_keeper_fd}" || return 70
          __guild_cntools_wallet_capture_fixed_fd_close \
            "${_wmh_capture_output_keeper_fd}" || return 70
          [[ $- != *m* ]] || _wmh_capture_monitor_was_on=Y
          # A temporary monitor-mode launch gives the exec'd tool a private
          # process group. The background subshell execs into the tool, so
          # a faulty tool and any pipe-holding descendants can be terminated
          # and the direct child reaped without touching the caller's group.
          if ! builtin set -m; then
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_input_read_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_input_write_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_read_fd}" >/dev/null 2>&1 || true
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_output_write_fd}" >/dev/null 2>&1 || true
            return 70
          fi
          (
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_input_write_fd}" || builtin exit 70
            __guild_cntools_wallet_capture_fixed_fd_close \
              "${_wmh_capture_read_fd}" || builtin exit 70
            builtin exec -- "$@" \
              <&"${_wmh_capture_input_read_fd_number}" \
              >&"${_wmh_capture_output_write_fd_number}" 2>&1
          ) &
          _wmh_capture_pid=$!
          __guild_cntools_wallet_capture_fixed_fd_close \
            "${_wmh_capture_input_read_fd}" || _wmh_capture_bad=Y
          __guild_cntools_wallet_capture_fixed_fd_close \
            "${_wmh_capture_output_write_fd}" || _wmh_capture_bad=Y
          if [[ -n "${_wmh_capture_input_name}" ]]; then
            builtin printf '%s\n' "${!_wmh_capture_input_name}" \
              >&"${_wmh_capture_input_write_fd_number}" ||
              _wmh_capture_bad=Y
          fi
          __guild_cntools_wallet_capture_fixed_fd_close \
            "${_wmh_capture_input_write_fd}" || _wmh_capture_bad=Y
          while [[ "${_wmh_capture_bad}" == N &&
                   "${_wmh_signal_pending}" == N ]]; do
            _wmh_capture_remaining=$((_wmh_capture_max + 1 -
              ${#_wmh_capture_value}))
            (( _wmh_capture_remaining > 0 )) || {
              _wmh_capture_bad=Y
              break
            }
            _wmh_capture_chunk=
            _wmh_capture_read_status=0
            IFS= builtin read -r -d '' -n "${_wmh_capture_remaining}" \
              -t 1 _wmh_capture_chunk \
              <&"${_wmh_capture_read_fd_number}" ||
              _wmh_capture_read_status=$?
            _wmh_capture_value+="${_wmh_capture_chunk}"
            if (( _wmh_capture_read_status == 0 )); then
              _wmh_capture_bad=Y
              break
            fi
            (( ${#_wmh_capture_value} <= _wmh_capture_max )) || {
              _wmh_capture_bad=Y
              break
            }
            if (( _wmh_capture_read_status == 1 )); then
              break
            elif (( _wmh_capture_read_status > 128 )); then
              _wmh_capture_timeout_ticks=$((_wmh_capture_timeout_ticks + 1))
              (( _wmh_capture_timeout_ticks < 10 )) || {
                _wmh_capture_bad=Y
                break
              }
            else
              _wmh_capture_bad=Y
              break
            fi
          done
          __guild_cntools_wallet_capture_fixed_fd_close \
            "${_wmh_capture_read_fd}" || _wmh_capture_bad=Y
          if [[ "${_wmh_signal_pending}" == Y ||
                "${_wmh_capture_bad}" == Y ]]; then
            _wmh_capture_bad=Y
            builtin kill -TERM -- "-${_wmh_capture_pid}" \
              2>/dev/null || true
            builtin kill -TERM "${_wmh_capture_pid}" 2>/dev/null || true
            builtin kill -KILL -- "-${_wmh_capture_pid}" \
              2>/dev/null || true
            builtin kill -KILL "${_wmh_capture_pid}" 2>/dev/null || true
          fi
          while :; do
            builtin wait "${_wmh_capture_pid}" 2>/dev/null
            _wmh_capture_wait_status=$?
            builtin kill -0 "${_wmh_capture_pid}" 2>/dev/null || break
            builtin kill -KILL -- "-${_wmh_capture_pid}" \
              2>/dev/null || true
            builtin kill -KILL "${_wmh_capture_pid}" 2>/dev/null || true
          done
          [[ "${_wmh_capture_monitor_was_on}" == Y ]] || builtin set +m
          [[ "${_wmh_capture_bad}" == N &&
             "${_wmh_signal_pending}" == N ]] || return 70
          (( _wmh_capture_wait_status == 0 )) || return 1
          while [[ "${_wmh_capture_value}" == *$'\n' ]]; do
            _wmh_capture_value="${_wmh_capture_value%$'\n'}"
          done
          (( ${#_wmh_capture_fixed_fd_owned[@]} == 0 )) || return 70
          builtin trap - HUP INT TERM
          builtin unset -f __guild_cntools_wallet_capture_interrupt \
            __guild_cntools_wallet_capture_fixed_fd_acquire \
            __guild_cntools_wallet_capture_fixed_fd_close
          builtin printf '%s' "${_wmh_capture_value}"
GUILD_CNTOOLS_CAPTURE_WORKER
        __guild_cntools_wallet_capture_bound() {
          local _wmh_capture_max="${1:-}" _wmh_capture_result_name="${2:-}"
          local _wmh_capture_input_name="${3:-}"
          shift 3 || return 1
          local _wmh_capture_outer_value="" _wmh_capture_outer_status=0


          builtin export -n _wmh_capture_outer_value || return 70

          [[ "${_wmh_capture_max}" =~ ^[1-9][0-9]*$ &&
             "${_wmh_capture_max}" -le 65536 &&
             "${_wmh_capture_result_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
             ( -z "${_wmh_capture_input_name}" ||
               "${_wmh_capture_input_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ) &&
             $# -gt 0 ]] || return 1
          if _wmh_capture_outer_value="$(
          (
            builtin eval "${_wmh_capture_worker_program}"
          ) 2>/dev/null
          )"; then
            _wmh_capture_outer_status=0
          else
            _wmh_capture_outer_status=$?
          fi
          [[ "${_wmh_signal_pending}" == N ]] || return 70
          (( _wmh_capture_outer_status == 0 )) || {
            (( _wmh_capture_outer_status == 70 )) && return 70
            return 1
          }
          builtin printf -v "${_wmh_capture_result_name}" '%s' \
            "${_wmh_capture_outer_value}"
        }
        __guild_cntools_wallet_ccli_capture_bound() {
          local _wmh_ccli_max="${1:-}" _wmh_ccli_result_name="${2:-}"
          local _wmh_ccli_path_one="${3:-}" _wmh_ccli_id_one="${4:-}"
          local _wmh_ccli_path_two="${5:-}" _wmh_ccli_id_two="${6:-}"
          shift 6 || return 70
          local _wmh_ccli_fd_one="" _wmh_ccli_fd_two=""
          local _wmh_ccli_fd_one_number="" _wmh_ccli_fd_two_number=""
          local _wmh_ccli_digest_one="" _wmh_ccli_digest_two=""
          local _wmh_ccli_status=0 _wmh_ccli_post_status=0
          local _wmh_ccli_index=0 _wmh_ccli_one_count=0
          local _wmh_ccli_two_count=0
          local -a _wmh_ccli_args=("$@")

          [[ "${_wmh_ccli_result_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
             -n "${_wmh_ccli_path_one}" &&
             "${_wmh_ccli_id_one}" =~ ^[0-9]+:[0-9]+$ &&
             ( ( -z "${_wmh_ccli_path_two}" && -z "${_wmh_ccli_id_two}" ) ||
               ( -n "${_wmh_ccli_path_two}" &&
                 "${_wmh_ccli_id_two}" =~ ^[0-9]+:[0-9]+$ ) ) ]] ||
            return 70
          __guild_cntools_wallet_input_open_bound \
            "${_wmh_ccli_path_one}" "${_wmh_ccli_id_one}" 1 16384 \
            _wmh_ccli_fd_one _wmh_ccli_digest_one || return 70
          if [[ -n "${_wmh_ccli_path_two}" ]]; then
            __guild_cntools_wallet_input_open_bound \
              "${_wmh_ccli_path_two}" "${_wmh_ccli_id_two}" 1 16384 \
              _wmh_ccli_fd_two _wmh_ccli_digest_two || {
                __guild_cntools_wallet_input_close_bound \
                  "${_wmh_ccli_fd_one}" "${_wmh_ccli_path_one}" \
                  "${_wmh_ccli_id_one}" 1 16384 \
                  "${_wmh_ccli_digest_one}" >/dev/null 2>&1 || true
                return 70
              }
          fi
          __guild_cntools_wallet_fixed_fd_resolve \
            "${_wmh_ccli_fd_one}" _wmh_ccli_fd_one_number || {
              __guild_cntools_wallet_input_close_bound \
                "${_wmh_ccli_fd_one}" "${_wmh_ccli_path_one}" \
                "${_wmh_ccli_id_one}" 1 16384 \
                "${_wmh_ccli_digest_one}" >/dev/null 2>&1 || true
              [[ -z "${_wmh_ccli_fd_two}" ]] ||
                __guild_cntools_wallet_input_close_bound \
                  "${_wmh_ccli_fd_two}" "${_wmh_ccli_path_two}" \
                  "${_wmh_ccli_id_two}" 1 16384 \
                  "${_wmh_ccli_digest_two}" >/dev/null 2>&1 || true
              return 70
            }
          if [[ -n "${_wmh_ccli_fd_two}" ]]; then
            __guild_cntools_wallet_fixed_fd_resolve \
              "${_wmh_ccli_fd_two}" _wmh_ccli_fd_two_number || {
                __guild_cntools_wallet_input_close_bound \
                  "${_wmh_ccli_fd_one}" "${_wmh_ccli_path_one}" \
                  "${_wmh_ccli_id_one}" 1 16384 \
                  "${_wmh_ccli_digest_one}" >/dev/null 2>&1 || true
                __guild_cntools_wallet_input_close_bound \
                  "${_wmh_ccli_fd_two}" "${_wmh_ccli_path_two}" \
                  "${_wmh_ccli_id_two}" 1 16384 \
                  "${_wmh_ccli_digest_two}" >/dev/null 2>&1 || true
                return 70
              }
          fi
          for _wmh_ccli_index in "${!_wmh_ccli_args[@]}"; do
            case "${_wmh_ccli_args[_wmh_ccli_index]}" in
              @GUILD_WMH_FD_ONE@)
                _wmh_ccli_args[_wmh_ccli_index]="/dev/fd/${_wmh_ccli_fd_one_number}"
                _wmh_ccli_one_count=$((_wmh_ccli_one_count + 1))
                ;;
              @GUILD_WMH_FD_TWO@)
                _wmh_ccli_args[_wmh_ccli_index]="/dev/fd/${_wmh_ccli_fd_two_number}"
                _wmh_ccli_two_count=$((_wmh_ccli_two_count + 1))
                ;;
            esac
          done
          if (( _wmh_ccli_one_count != 1 )) ||
             { [[ -n "${_wmh_ccli_path_two}" ]] &&
               (( _wmh_ccli_two_count != 1 )); } ||
             { [[ -z "${_wmh_ccli_path_two}" ]] &&
               (( _wmh_ccli_two_count != 0 )); }; then
            _wmh_ccli_status=70
          else
            __guild_cntools_wallet_capture_bound "${_wmh_ccli_max}" \
              "${_wmh_ccli_result_name}" '' "${_wmh_tools[ccli]}" \
              "${_wmh_ccli_args[@]}" || _wmh_ccli_status=$?
          fi
          __guild_cntools_wallet_input_close_bound \
            "${_wmh_ccli_fd_one}" "${_wmh_ccli_path_one}" \
            "${_wmh_ccli_id_one}" 1 16384 "${_wmh_ccli_digest_one}" ||
            _wmh_ccli_post_status=70
          if [[ -n "${_wmh_ccli_path_two}" ]]; then
            __guild_cntools_wallet_input_close_bound \
              "${_wmh_ccli_fd_two}" "${_wmh_ccli_path_two}" \
              "${_wmh_ccli_id_two}" 1 16384 \
              "${_wmh_ccli_digest_two}" || _wmh_ccli_post_status=70
          fi
          (( _wmh_ccli_post_status == 0 )) || return 70
          return "${_wmh_ccli_status}"
        }
GUILD_CNTOOLS_AUTH_HELPERS
        _wmh_auth_defined=Y
        if ! builtin eval "${_wmh_auth_helper_program}"; then
          _wmh_status=70
        else
          # Two authenticated CCLI inputs and six anonymous capture-pipe ends
          # are the maximum simultaneous ownership set. Prove that capacity
          # before any derivation tool can receive secret stdin.
          _wmh_count=0
          for ((_wmh_index=64; _wmh_index<=79; _wmh_index++)); do
            [[ -e "/dev/fd/${_wmh_index}" ]] ||
              _wmh_count=$((_wmh_count + 1))
          done
          (( _wmh_count >= 8 )) || _wmh_status=70
          if (( _wmh_status == 0 )); then
            for ((_wmh_count=0; _wmh_count<8; _wmh_count++)); do
              _wmh_fixed_probe_token=
              __guild_cntools_wallet_fixed_fd_acquire rw /dev/null \
                _wmh_fixed_probe_token || {
                  _wmh_status=70
                  break
                }
              _wmh_fixed_probe_tokens+=("${_wmh_fixed_probe_token}")
            done
            for _wmh_fixed_probe_token in \
                "${_wmh_fixed_probe_tokens[@]}"; do
              __guild_cntools_wallet_fixed_fd_close \
                "${_wmh_fixed_probe_token}" || _wmh_status=70
            done
            _wmh_fixed_probe_tokens=()
            _wmh_fixed_probe_token=
            (( ${#_wmh_fixed_fd_owned[@]} == 0 )) || _wmh_status=70
          fi
        fi
      fi
    fi

  # Every non-prepare phase first authenticates the fixed private state.
  if (( _wmh_status == 0 )) && [[ "${_wmh_phase}" != prepare ]]; then
    [[ "${_wmh_state}" == "${_wmh_lock}/state" &&
       -f "${_wmh_state}" && ! -L "${_wmh_state}" ]] ||
      _wmh_status=70
  fi
  if (( _wmh_status == 0 )) && [[ "${_wmh_phase}" != prepare ]]; then
    if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%l\t%z' \
        "${_wmh_state}" 2>/dev/null)"; then
      :
    else
      _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%h\t%s' -- \
        "${_wmh_state}" 2>/dev/null)" || _wmh_status=70
    fi
    if (( _wmh_status == 0 )); then
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
        _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
         "${_wmh_mode}" == 600 && "${_wmh_links}" == 1 &&
         "${_wmh_size}" =~ ^[1-9][0-9]*$ && "${_wmh_size}" -le 8192 ]] ||
        _wmh_status=70
    fi
  fi
  if (( _wmh_status == 0 )) && [[ "${_wmh_phase}" != prepare ]]; then
    ex''ec 9< "${_wmh_state}" || _wmh_status=70
    for _wmh_expected_key in version root root_identity destination \
        destination_kind destination_identity lock_identity stage_identity \
        wallet account key network_kind network_magic phrase_sha inventory_sha; do
      (( _wmh_status == 0 )) || break
      IFS=$'\t' builtin read -r _wmh_key _wmh_value _wmh_extra <&9 ||
        _wmh_status=70
      [[ "${_wmh_key}" == "${_wmh_expected_key}" &&
         -z "${_wmh_extra}" && -n "${_wmh_value}" ]] || _wmh_status=70
      case "${_wmh_key}" in
        version) [[ "${_wmh_value}" == 1 ]] || _wmh_status=70 ;;
        root) _wmh_saved_root="${_wmh_value}" ;;
        root_identity) _wmh_saved_root_identity="${_wmh_value}" ;;
        destination) _wmh_saved_destination="${_wmh_value}" ;;
        destination_kind) _wmh_saved_destination_kind="${_wmh_value}" ;;
        destination_identity) _wmh_saved_destination_identity="${_wmh_value}" ;;
        lock_identity) _wmh_saved_lock_identity="${_wmh_value}" ;;
        stage_identity) _wmh_saved_stage_identity="${_wmh_value}" ;;
        wallet) _wmh_saved_wallet_name="${_wmh_value}" ;;
        account) _wmh_saved_account="${_wmh_value}" ;;
        key) _wmh_saved_key="${_wmh_value}" ;;
        network_kind) _wmh_saved_network_kind="${_wmh_value}" ;;
        network_magic) _wmh_saved_network_magic="${_wmh_value}" ;;
        phrase_sha) _wmh_saved_phrase_sha="${_wmh_value}" ;;
        inventory_sha) _wmh_saved_inventory_sha="${_wmh_value}" ;;
      esac
    done
    if (( _wmh_status == 0 )); then
      if IFS= builtin read -r _wmh_extra <&9; then
        _wmh_status=70
      fi
    fi
    ex''ec 9<&-
    [[ "${_wmh_saved_root}" == "${_wmh_root}" &&
       "${_wmh_saved_root_identity}" == "${_wmh_root_identity}" &&
       "${_wmh_saved_destination}" == "${_wmh_destination}" &&
       ( ( "${_wmh_saved_destination_kind}" == absent &&
           "${_wmh_saved_destination_identity}" == none ) ||
         ( "${_wmh_saved_destination_kind}" == existing &&
           "${_wmh_saved_destination_identity}" =~ ^[0-9]+:[0-9]+$ ) ) &&
       "${_wmh_saved_wallet_name}" == "${wallet_name}" &&
       "${_wmh_saved_account}" == "${acct_idx}" &&
       "${_wmh_saved_key}" == "${key_idx}" &&
       "${_wmh_saved_network_kind}" == "${_wmh_network_kind}" &&
       "${_wmh_saved_network_magic}" == "${_wmh_network_magic}" &&
       "${_wmh_saved_phrase_sha}" =~ ^[0-9a-f]{64}$ &&
       "${_wmh_saved_inventory_sha}" =~ ^[0-9a-f]{64}$ &&
       "${_wmh_saved_lock_identity}" =~ ^[0-9]+:[0-9]+$ &&
       "${_wmh_saved_stage_identity}" =~ ^[0-9]+:[0-9]+$ ]] ||
      _wmh_status=70
  fi

  # The cleanup marker binds the private stage to the authenticated state. It
  # remains after the stage is removed so an interrupted abort can resume
  # without trusting a missing pathname as evidence of prior cleanup.
  if (( _wmh_status == 0 )) && [[ "${_wmh_phase}" != prepare ]]; then
    _wmh_cleanup_marker_value=$'cleanup\t'"${_wmh_saved_root_identity}"$'\t'\
"${_wmh_saved_lock_identity}"$'\t'"${_wmh_saved_stage_identity}"$'\t'\
"${_wmh_saved_phrase_sha}"$'\t'"${_wmh_saved_inventory_sha}"
    [[ -f "${_wmh_cleanup_marker}" &&
       ! -L "${_wmh_cleanup_marker}" ]] || _wmh_status=70
    if (( _wmh_status == 0 )); then
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%l\t%z' \
          "${_wmh_cleanup_marker}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%h\t%s' -- \
          "${_wmh_cleanup_marker}" 2>/dev/null)" || _wmh_status=70
      fi
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
        _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      _wmh_value="$(< "${_wmh_cleanup_marker}")"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
         "${_wmh_mode}" == 600 && "${_wmh_links}" == 1 &&
         "${_wmh_size}" -gt 0 && "${_wmh_size}" -le 512 &&
         "${_wmh_value}" == "${_wmh_cleanup_marker_value}" ]] ||
        _wmh_status=70
      (( _wmh_status != 0 )) || _wmh_cleanup_marker_valid=Y
    fi
  fi

  # Authenticate lock and stage, the phrase digest, and the exact staged
  # inventory before acknowledge/publish/abort can do anything destructive.
  if (( _wmh_status == 0 )) && [[ "${_wmh_phase}" != prepare ]]; then
    for _wmh_path in "${_wmh_lock}" "${_wmh_stage}"; do
      if [[ "${_wmh_path}" == "${_wmh_stage}" &&
            ! -e "${_wmh_stage}" && ! -L "${_wmh_stage}" &&
            "${_wmh_phase}" == abort &&
            "${_wmh_cleanup_marker_valid}" == Y ]]; then
        _wmh_stage_missing=Y
        continue
      fi
      [[ -d "${_wmh_path}" && ! -L "${_wmh_path}" ]] || {
        _wmh_status=70
        break
      }
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%d\t%i' \
          "${_wmh_path}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%d\t%i' -- \
          "${_wmh_path}" 2>/dev/null)" || {
            _wmh_status=70
            break
          }
      fi
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_device _wmh_inode \
        _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      _wmh_identity="${_wmh_device}:${_wmh_inode}"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
         "${_wmh_mode}" == 700 &&
         ( ( "${_wmh_path}" == "${_wmh_lock}" &&
             "${_wmh_identity}" == "${_wmh_saved_lock_identity}" ) ||
           ( "${_wmh_path}" == "${_wmh_stage}" &&
             "${_wmh_identity}" == "${_wmh_saved_stage_identity}" ) ) ]] || {
        _wmh_status=70
        break
      }
    done
  fi
  if (( _wmh_status == 0 )) && [[ "${_wmh_phase}" != prepare ]]; then
    if [[ "${_wmh_phase}" == abort && -z "${_wmh_phrase}" ]]; then
      :
    else
      if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
        _wmh_phrase_sha="$(builtin printf '%s' "${_wmh_phrase}" |
          "${_wmh_tools[hash]}" 2>/dev/null)"
      else
        _wmh_phrase_sha="$(builtin printf '%s' "${_wmh_phrase}" |
          "${_wmh_tools[hash]}" -a 256 2>/dev/null)"
      fi
      _wmh_phrase_sha="${_wmh_phrase_sha%% *}"
      [[ "${_wmh_phrase_sha}" == "${_wmh_saved_phrase_sha}" ]] ||
        _wmh_status=70
    fi
  fi
  if (( _wmh_status == 0 )) && [[ "${_wmh_phase}" != prepare ]]; then
    [[ -f "${_wmh_inventory}" && ! -L "${_wmh_inventory}" ]] ||
      _wmh_status=70
    if (( _wmh_status == 0 )); then
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%l\t%z' \
          "${_wmh_inventory}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%h\t%s' -- \
          "${_wmh_inventory}" 2>/dev/null)" || _wmh_status=70
      fi
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
        _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
         "${_wmh_mode}" == 600 && "${_wmh_links}" == 1 &&
         "${_wmh_size}" -gt 0 && "${_wmh_size}" -le 16384 ]] ||
        _wmh_status=70
    fi
    if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
      _wmh_inventory_sha="$("${_wmh_tools[hash]}" "${_wmh_inventory}" \
        2>/dev/null)"
    else
      _wmh_inventory_sha="$("${_wmh_tools[hash]}" -a 256 \
        "${_wmh_inventory}" 2>/dev/null)"
    fi
    _wmh_inventory_sha="${_wmh_inventory_sha%% *}"
    [[ "${_wmh_inventory_sha}" == "${_wmh_saved_inventory_sha}" ]] ||
      _wmh_status=70
  fi
  if (( _wmh_status == 0 )) && [[ "${_wmh_phase}" != prepare ]]; then
    ex''ec 9< "${_wmh_inventory}" || _wmh_status=70
    for _wmh_leaf in "${_wmh_expected_leaves[@]}"; do
      (( _wmh_status == 0 )) || break
      IFS=$'\t' builtin read -r _wmh_value _wmh_digest _wmh_extra <&9 ||
        _wmh_status=70
      [[ "${_wmh_value}" == "${_wmh_leaf}" &&
         "${_wmh_digest}" =~ ^[0-9a-f]{64}$ && -z "${_wmh_extra}" ]] ||
        _wmh_status=70
      _wmh_leaf_digests["${_wmh_leaf}"]="${_wmh_digest}"
    done
    if (( _wmh_status == 0 )) && IFS= builtin read -r _wmh_extra <&9; then
      _wmh_status=70
    fi
    ex''ec 9<&-
    if [[ "${_wmh_stage_missing}" != Y ]]; then
      for _wmh_leaf in "${_wmh_expected_leaves[@]}"; do
        (( _wmh_status == 0 )) || break
        _wmh_path="${_wmh_stage}/${_wmh_leaf}"
        if [[ ! -e "${_wmh_path}" && ! -L "${_wmh_path}" &&
              "${_wmh_phase}" == abort ]]; then
          continue
        fi
        [[ -f "${_wmh_path}" && ! -L "${_wmh_path}" ]] || {
          _wmh_status=70
          break
        }
        if _wmh_metadata="$("${_wmh_tools[stat]}" -f \
            $'%u\t%Lp\t%l\t%z\t%d\t%i' \
            "${_wmh_path}" 2>/dev/null)"; then
          :
        else
          _wmh_metadata="$("${_wmh_tools[stat]}" -c \
            $'%u\t%a\t%h\t%s\t%d\t%i' -- \
            "${_wmh_path}" 2>/dev/null)" || {
              _wmh_status=70
              break
            }
        fi
        IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
          _wmh_device _wmh_inode _wmh_extra <<< "${_wmh_metadata}"
        _wmh_mode="${_wmh_mode#0}"
        [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
           "${_wmh_mode}" == 600 &&
           ( "${_wmh_links}" == 1 ||
             ( "${_wmh_phase}" == abort && "${_wmh_links}" == 2 ) ) &&
           "${_wmh_size}" =~ ^[1-9][0-9]*$ && "${_wmh_size}" -le 16384 ]] || {
          _wmh_status=70
          break
        }
        __guild_cntools_wallet_output_hash_stable "${_wmh_path}" \
          "${_wmh_device}:${_wmh_inode}" 1 16384 _wmh_live_digest \
          "${_wmh_links}" || {
            _wmh_status=70
            break
          }
        [[ "${_wmh_live_digest}" == "${_wmh_leaf_digests[${_wmh_leaf}]}" ]] || {
          _wmh_status=70
          break
        }
        _wmh_leaf_identities["${_wmh_leaf}"]="${_wmh_device}:${_wmh_inode}"
        _wmh_leaf_links["${_wmh_leaf}"]="${_wmh_links}"
      done
      if (( _wmh_status == 0 )); then
        _wmh_found="$("${_wmh_tools[find]}" "${_wmh_stage}" -mindepth 1 \
          -maxdepth 1 -print 2>/dev/null)" || _wmh_status=70
        _wmh_seen_names=()
        _wmh_count=0
        while IFS= builtin read -r _wmh_path; do
          [[ -n "${_wmh_path}" ]] || continue
          _wmh_leaf="${_wmh_path#"${_wmh_stage}/"}"
          [[ "${_wmh_leaf}" != */* &&
             -n "${_wmh_seen_leaves[${_wmh_leaf}]+set}" &&
             -z "${_wmh_seen_names[${_wmh_leaf}]+set}" ]] || _wmh_status=70
          _wmh_seen_names["${_wmh_leaf}"]=Y
          _wmh_count=$((_wmh_count + 1))
        done <<< "${_wmh_found}"
        if [[ "${_wmh_phase}" == abort ]]; then
          (( _wmh_count <= 24 )) || _wmh_status=70
        else
          (( _wmh_count == 24 )) || _wmh_status=70
        fi
      fi
    fi
  fi

  # Abort reconstructs any interrupted publication from the authenticated
  # stage inode/digest inventory. No private authority is removed until every
  # public entry is either absent or proven to be the exact staged hard link
  # and unlinked. A transient failure can therefore be retried with the same
  # state token without orphaning signing material in the destination.
  if (( _wmh_status == 0 )) && [[ "${_wmh_phase}" == abort ]]; then
    _wmh_cleanup_authorized=Y
    _wmh_public_leaves=()
    _wmh_seen_names=()
    _wmh_publish_destination_identity=
    if [[ ! -e "${_wmh_destination}" && ! -L "${_wmh_destination}" ]]; then
      for _wmh_leaf in "${_wmh_expected_leaves[@]}"; do
        [[ -z "${_wmh_leaf_identities[${_wmh_leaf}]+set}" ||
           "${_wmh_leaf_links[${_wmh_leaf}]}" == 1 ]] || {
          _wmh_cleanup_authorized=N
          break
        }
      done
    elif [[ -d "${_wmh_destination}" && ! -L "${_wmh_destination}" ]]; then
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%d\t%i' \
          "${_wmh_destination}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%d\t%i' -- \
          "${_wmh_destination}" 2>/dev/null)" ||
          _wmh_cleanup_authorized=N
      fi
      if [[ "${_wmh_cleanup_authorized}" == Y ]]; then
        IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_device _wmh_inode \
          _wmh_extra <<< "${_wmh_metadata}"
        _wmh_mode="${_wmh_mode#0}"
        _wmh_publish_destination_identity="${_wmh_device}:${_wmh_inode}"
        [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" ]] ||
          _wmh_cleanup_authorized=N
        case "${_wmh_saved_destination_kind}" in
          existing)
            [[ "${_wmh_publish_destination_identity}" == \
                 "${_wmh_saved_destination_identity}" &&
               ( "${_wmh_mode}" == 700 || "${_wmh_mode}" == 750 ||
                 "${_wmh_mode}" == 755 ) ]] ||
              _wmh_cleanup_authorized=N
            ;;
          absent)
            [[ "${_wmh_mode}" == 700 ]] || _wmh_cleanup_authorized=N
            ;;
          *) _wmh_cleanup_authorized=N ;;
        esac
      fi
      if [[ "${_wmh_cleanup_authorized}" == Y ]]; then
        _wmh_found="$("${_wmh_tools[find]}" "${_wmh_destination}" \
          -mindepth 1 -maxdepth 1 -print 2>/dev/null)" ||
          _wmh_cleanup_authorized=N
      fi
      while [[ "${_wmh_cleanup_authorized}" == Y ]] &&
          IFS= builtin read -r _wmh_path; do
        [[ -n "${_wmh_path}" ]] || continue
        _wmh_leaf="${_wmh_path#"${_wmh_destination}/"}"
        [[ "${_wmh_leaf}" != */* &&
           -n "${_wmh_seen_leaves[${_wmh_leaf}]+set}" &&
           -z "${_wmh_seen_names[${_wmh_leaf}]+set}" &&
           -n "${_wmh_leaf_identities[${_wmh_leaf}]+set}" &&
           -f "${_wmh_path}" && ! -L "${_wmh_path}" ]] || {
          _wmh_cleanup_authorized=N
          break
        }
        if _wmh_metadata="$("${_wmh_tools[stat]}" -f \
            $'%u\t%Lp\t%l\t%z\t%d\t%i' "${_wmh_path}" 2>/dev/null)"; then
          :
        else
          _wmh_metadata="$("${_wmh_tools[stat]}" -c \
            $'%u\t%a\t%h\t%s\t%d\t%i' -- "${_wmh_path}" 2>/dev/null)" || {
              _wmh_cleanup_authorized=N
              break
            }
        fi
        IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
          _wmh_device _wmh_inode _wmh_extra <<< "${_wmh_metadata}"
        _wmh_mode="${_wmh_mode#0}"
        [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
           "${_wmh_mode}" == 600 && "${_wmh_links}" == 2 &&
           "${_wmh_size}" =~ ^[1-9][0-9]*$ && "${_wmh_size}" -le 16384 &&
           "${_wmh_device}:${_wmh_inode}" == \
             "${_wmh_leaf_identities[${_wmh_leaf}]}" ]] || {
          _wmh_cleanup_authorized=N
          break
        }
        __guild_cntools_wallet_output_hash_stable "${_wmh_path}" \
          "${_wmh_leaf_identities[${_wmh_leaf}]}" 1 16384 \
          _wmh_live_digest 2 || {
            _wmh_cleanup_authorized=N
            break
          }
        [[ "${_wmh_live_digest}" == "${_wmh_leaf_digests[${_wmh_leaf}]}" ]] || {
          _wmh_cleanup_authorized=N
          break
        }
        _wmh_seen_names["${_wmh_leaf}"]=Y
        _wmh_public_leaves+=("${_wmh_leaf}")
      done <<< "${_wmh_found}"
      if [[ "${_wmh_cleanup_authorized}" == Y ]]; then
        for _wmh_leaf in "${_wmh_expected_leaves[@]}"; do
          [[ -n "${_wmh_leaf_identities[${_wmh_leaf}]+set}" ]] || {
            [[ -z "${_wmh_seen_names[${_wmh_leaf}]+set}" ]] ||
              _wmh_cleanup_authorized=N
            continue
          }
          if [[ -n "${_wmh_seen_names[${_wmh_leaf}]+set}" ]]; then
            [[ "${_wmh_leaf_links[${_wmh_leaf}]}" == 2 ]] ||
              _wmh_cleanup_authorized=N
          else
            [[ "${_wmh_leaf_links[${_wmh_leaf}]}" == 1 ]] ||
              _wmh_cleanup_authorized=N
          fi
          [[ "${_wmh_cleanup_authorized}" == Y ]] || break
        done
      fi
      if [[ "${_wmh_cleanup_authorized}" == Y ]]; then
        for _wmh_leaf in "${_wmh_public_leaves[@]}"; do
          if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%d\t%i' \
              "${_wmh_destination}" 2>/dev/null)"; then
            :
          else
            _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%d\t%i' -- \
              "${_wmh_destination}" 2>/dev/null)" || {
                _wmh_cleanup_authorized=N
                break
              }
          fi
          IFS=$'\t' builtin read -r _wmh_device _wmh_inode _wmh_extra \
            <<< "${_wmh_metadata}"
          [[ -z "${_wmh_extra}" && "${_wmh_device}:${_wmh_inode}" == \
               "${_wmh_publish_destination_identity}" ]] || {
            _wmh_cleanup_authorized=N
            break
          }
          _wmh_path="${_wmh_destination}/${_wmh_leaf}"
          if _wmh_metadata="$("${_wmh_tools[stat]}" -f \
              $'%u\t%Lp\t%l\t%z\t%d\t%i' "${_wmh_path}" 2>/dev/null)"; then
            :
          else
            _wmh_metadata="$("${_wmh_tools[stat]}" -c \
              $'%u\t%a\t%h\t%s\t%d\t%i' -- "${_wmh_path}" 2>/dev/null)" || {
                _wmh_cleanup_authorized=N
                break
              }
          fi
          IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
            _wmh_device _wmh_inode _wmh_extra <<< "${_wmh_metadata}"
          _wmh_mode="${_wmh_mode#0}"
          [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
             "${_wmh_mode}" == 600 && "${_wmh_links}" == 2 &&
             "${_wmh_size}" =~ ^[1-9][0-9]*$ && "${_wmh_size}" -le 16384 &&
             "${_wmh_device}:${_wmh_inode}" == \
               "${_wmh_leaf_identities[${_wmh_leaf}]}" ]] || {
            _wmh_cleanup_authorized=N
            break
          }
          __guild_cntools_wallet_output_hash_stable "${_wmh_path}" \
            "${_wmh_leaf_identities[${_wmh_leaf}]}" 1 16384 \
            _wmh_live_digest 2 || {
              _wmh_cleanup_authorized=N
              break
            }
          [[ "${_wmh_live_digest}" == \
               "${_wmh_leaf_digests[${_wmh_leaf}]}" ]] || {
            _wmh_cleanup_authorized=N
            break
          }
          _wmh_command_status=0
          "${_wmh_tools[rm]}" -f -- "${_wmh_path}" >/dev/null 2>&1 ||
            _wmh_command_status=$?
          if [[ -e "${_wmh_path}" || -L "${_wmh_path}" ]]; then
            _wmh_cleanup_authorized=N
            break
          fi
        done
      fi
      if [[ "${_wmh_cleanup_authorized}" == Y ]]; then
        for _wmh_leaf in "${_wmh_expected_leaves[@]}"; do
          [[ -n "${_wmh_leaf_identities[${_wmh_leaf}]+set}" ]] || continue
          _wmh_path="${_wmh_stage}/${_wmh_leaf}"
          if _wmh_metadata="$("${_wmh_tools[stat]}" -f \
              $'%u\t%Lp\t%l\t%z\t%d\t%i' "${_wmh_path}" 2>/dev/null)"; then
            :
          else
            _wmh_metadata="$("${_wmh_tools[stat]}" -c \
              $'%u\t%a\t%h\t%s\t%d\t%i' -- "${_wmh_path}" 2>/dev/null)" || {
                _wmh_cleanup_authorized=N
                break
              }
          fi
          IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
            _wmh_device _wmh_inode _wmh_extra <<< "${_wmh_metadata}"
          _wmh_mode="${_wmh_mode#0}"
          [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
             "${_wmh_mode}" == 600 && "${_wmh_links}" == 1 &&
             "${_wmh_size}" =~ ^[1-9][0-9]*$ && "${_wmh_size}" -le 16384 &&
             "${_wmh_device}:${_wmh_inode}" == \
               "${_wmh_leaf_identities[${_wmh_leaf}]}" ]] || {
            _wmh_cleanup_authorized=N
            break
          }
          __guild_cntools_wallet_output_hash_stable "${_wmh_path}" \
            "${_wmh_leaf_identities[${_wmh_leaf}]}" 1 16384 \
            _wmh_live_digest 1 || {
              _wmh_cleanup_authorized=N
              break
            }
          [[ "${_wmh_live_digest}" == \
               "${_wmh_leaf_digests[${_wmh_leaf}]}" ]] || {
            _wmh_cleanup_authorized=N
            break
          }
        done
      fi
      if [[ "${_wmh_cleanup_authorized}" == Y ]]; then
        _wmh_found="$("${_wmh_tools[find]}" "${_wmh_destination}" \
          -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ||
          _wmh_cleanup_authorized=N
        [[ -z "${_wmh_found}" ]] || _wmh_cleanup_authorized=N
      fi
      if [[ "${_wmh_cleanup_authorized}" == Y &&
            "${_wmh_saved_destination_kind}" == absent ]]; then
        if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%d\t%i' \
            "${_wmh_destination}" 2>/dev/null)"; then
          :
        else
          _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%d\t%i' -- \
            "${_wmh_destination}" 2>/dev/null)" ||
            _wmh_cleanup_authorized=N
        fi
        if [[ "${_wmh_cleanup_authorized}" == Y ]]; then
          IFS=$'\t' builtin read -r _wmh_device _wmh_inode _wmh_extra \
            <<< "${_wmh_metadata}"
          [[ -z "${_wmh_extra}" && "${_wmh_device}:${_wmh_inode}" == \
               "${_wmh_publish_destination_identity}" ]] ||
            _wmh_cleanup_authorized=N
        fi
        if [[ "${_wmh_cleanup_authorized}" == Y ]]; then
          _wmh_command_status=0
          "${_wmh_tools[rmdir]}" -- "${_wmh_destination}" \
            >/dev/null 2>&1 || _wmh_command_status=$?
          [[ ! -e "${_wmh_destination}" && ! -L "${_wmh_destination}" ]] ||
            _wmh_cleanup_authorized=N
        fi
      fi
    else
      _wmh_cleanup_authorized=N
    fi
    if [[ "${_wmh_cleanup_authorized}" == Y ]]; then
      _wmh_abort_public_reconciled=Y
    else
      _wmh_cleanup_status=1
      _wmh_status=70
    fi
  fi

  if (( _wmh_status == 0 )); then
    if [[ "${_wmh_phase}" == prepare ]]; then
      [[ -z "${_wmh_state}" ]] || _wmh_status=70
    builtin printf -v "${_wmh_base_name}" '%s' ''
    builtin printf -v "${_wmh_pay_name}" '%s' ''
    builtin printf -v "${_wmh_reward_name}" '%s' ''
    if [[ -e "${_wmh_lock}" || -L "${_wmh_lock}" ]]; then
      _wmh_status=1
    elif ! "${_wmh_tools[mkdir]}" -m 0700 -- "${_wmh_lock}" \
        >/dev/null 2>&1; then
      # A nonzero creator may have raced or created the path before failing.
      # Without a pre-call inode there is no authority to claim or delete it.
      _wmh_status=70
    else
      _wmh_created_lock=Y
    fi
    if (( _wmh_status == 0 )); then
      "${_wmh_tools[chmod]}" 0700 "${_wmh_lock}" >/dev/null 2>&1 ||
        _wmh_status=70
    fi
    if (( _wmh_status == 0 )); then
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%d\t%i' \
          "${_wmh_lock}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%d\t%i' -- \
          "${_wmh_lock}" 2>/dev/null)" || _wmh_status=70
      fi
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_device _wmh_inode \
        _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
         "${_wmh_mode}" == 700 ]] || _wmh_status=70
      _wmh_lock_identity="${_wmh_device}:${_wmh_inode}"
    fi
    if (( _wmh_status == 0 )); then
      if [[ -e "${_wmh_destination}" || -L "${_wmh_destination}" ]]; then
        [[ -d "${_wmh_destination}" && ! -L "${_wmh_destination}" ]] ||
          _wmh_status=70
        if (( _wmh_status == 0 )); then
          if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%d\t%i' \
              "${_wmh_destination}" 2>/dev/null)"; then
            :
          else
            _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%d\t%i' -- \
              "${_wmh_destination}" 2>/dev/null)" || _wmh_status=70
          fi
          IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_device _wmh_inode \
            _wmh_extra <<< "${_wmh_metadata}"
          _wmh_mode="${_wmh_mode#0}"
          [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
             ( "${_wmh_mode}" == 700 || "${_wmh_mode}" == 750 ||
               "${_wmh_mode}" == 755 ) ]] || _wmh_status=70
          _wmh_destination_kind=existing
          _wmh_destination_identity="${_wmh_device}:${_wmh_inode}"
          _wmh_found="$("${_wmh_tools[find]}" "${_wmh_destination}" \
            -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ||
            _wmh_status=70
          [[ -z "${_wmh_found}" ]] || _wmh_status=1
        fi
      else
        _wmh_destination_kind=absent
        _wmh_destination_identity=none
      fi
    fi
    if (( _wmh_status == 0 )); then
      "${_wmh_tools[mkdir]}" -m 0700 -- "${_wmh_stage}" >/dev/null 2>&1 ||
        _wmh_status=70
      _wmh_created_stage=Y
      "${_wmh_tools[chmod]}" 0700 "${_wmh_stage}" >/dev/null 2>&1 ||
        _wmh_status=70
    fi
    if (( _wmh_status == 0 )); then
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%d\t%i' \
          "${_wmh_stage}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%d\t%i' -- \
          "${_wmh_stage}" 2>/dev/null)" || _wmh_status=70
      fi
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_device _wmh_inode \
        _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
         "${_wmh_mode}" == 700 ]] || _wmh_status=70
      _wmh_stage_identity="${_wmh_device}:${_wmh_inode}"
    fi

    fi

    if [[ "${_wmh_phase}" == prepare ]]; then
      # The private stage is empty and no stage-aware external command has run
      # yet. Create every eventual public leaf exactly once with the final mode,
      # then bind its inode. CCLI may write only through these pre-authenticated
      # paths; it must never cause a pathname chmod or replace a bound inode.
    if (( _wmh_status == 0 )); then
      for _wmh_leaf in "${_wmh_expected_leaves[@]}"; do
        _wmh_path="${_wmh_stage}/${_wmh_leaf}"
        [[ ! -e "${_wmh_path}" && ! -L "${_wmh_path}" ]] || {
          _wmh_status=70
          break
        }
        (builtin umask 077
          builtin set -o noclobber
          : > "${_wmh_path}") 2>/dev/null || {
            _wmh_status=70
            break
          }
        __guild_cntools_wallet_output_authenticate \
          "${_wmh_path}" '' 0 0 _wmh_identity || {
            _wmh_status=70
            break
          }
        _wmh_leaf_identities["${_wmh_leaf}"]="${_wmh_identity}"
      done
    fi

    for _wmh_tool_name in cardano-address bech32; do
      (( _wmh_status == 0 )) || break
      _wmh_tool_path=
      if builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1; then
        _cntools_registry_tool_path "${_wmh_tool_name}" _wmh_tool_path ||
          _wmh_status=70
      else
        if builtin declare -F "${_wmh_tool_name}" >/dev/null 2>&1 ||
           builtin alias "${_wmh_tool_name}" >/dev/null 2>&1; then
          _wmh_status=70
        else
          _wmh_path_remaining="${PATH-}"
          while :; do
            _wmh_path_more=N
            if [[ "${_wmh_path_remaining}" == *:* ]]; then
              _wmh_path_entry="${_wmh_path_remaining%%:*}"
              _wmh_path_remaining="${_wmh_path_remaining#*:}"
              _wmh_path_more=Y
            else
              _wmh_path_entry="${_wmh_path_remaining}"
              _wmh_path_remaining=
            fi
            if [[ -z "${_wmh_path_entry}" ]]; then
              _wmh_candidate="${_wmh_tool_name}"
            elif [[ "${_wmh_path_entry}" == / ]]; then
              _wmh_candidate="/${_wmh_tool_name}"
            else
              _wmh_candidate="${_wmh_path_entry%/}/${_wmh_tool_name}"
            fi
            if [[ -f "${_wmh_candidate}" && -x "${_wmh_candidate}" &&
                  ! -L "${_wmh_candidate}" ]]; then
              _wmh_tool_path="${_wmh_candidate}"
              break
            fi
            [[ "${_wmh_path_more}" == Y ]] || break
          done
        fi
      fi
      [[ "${_wmh_tool_path}" == /* && -f "${_wmh_tool_path}" &&
         -x "${_wmh_tool_path}" && ! -L "${_wmh_tool_path}" ]] ||
        _wmh_status=70
      _wmh_tools["${_wmh_tool_name}"]="${_wmh_tool_path}"
    done
    if (( _wmh_status == 0 )); then
      if [[ "${CCLI:-}" == /* ]]; then
        _wmh_tool_path="${CCLI}"
      elif [[ "${CCLI:-}" =~ ^[a-z][a-z0-9-]*$ ]]; then
        if builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1; then
          _cntools_registry_tool_path "${CCLI}" _wmh_tool_path ||
            _wmh_status=70
        else
          if builtin declare -F "${CCLI}" >/dev/null 2>&1 ||
             builtin alias "${CCLI}" >/dev/null 2>&1; then
            _wmh_status=70
          else
            _wmh_path_remaining="${PATH-}"
            while :; do
              _wmh_path_more=N
              if [[ "${_wmh_path_remaining}" == *:* ]]; then
                _wmh_path_entry="${_wmh_path_remaining%%:*}"
                _wmh_path_remaining="${_wmh_path_remaining#*:}"
                _wmh_path_more=Y
              else
                _wmh_path_entry="${_wmh_path_remaining}"
                _wmh_path_remaining=
              fi
              if [[ -z "${_wmh_path_entry}" ]]; then
                _wmh_candidate="${CCLI}"
              elif [[ "${_wmh_path_entry}" == / ]]; then
                _wmh_candidate="/${CCLI}"
              else
                _wmh_candidate="${_wmh_path_entry%/}/${CCLI}"
              fi
              if [[ -f "${_wmh_candidate}" && -x "${_wmh_candidate}" &&
                    ! -L "${_wmh_candidate}" ]]; then
                _wmh_tool_path="${_wmh_candidate}"
                break
              fi
              [[ "${_wmh_path_more}" == Y ]] || break
            done
          fi
        fi
      else
        _wmh_status=70
      fi
      [[ "${_wmh_tool_path}" == /* && -f "${_wmh_tool_path}" &&
         -x "${_wmh_tool_path}" && ! -L "${_wmh_tool_path}" ]] ||
        _wmh_status=70
      _wmh_tools[ccli]="${_wmh_tool_path}"
    fi

    for _wmh_tool_name in cardano-address bech32 ccli; do
      (( _wmh_status == 0 )) || break
      _wmh_tool_path="${_wmh_tools[${_wmh_tool_name}]}"
      if builtin declare -F _cntools_registry_path_has_no_symlinks \
           >/dev/null 2>&1; then
        _cntools_registry_path_has_no_symlinks "${_wmh_tool_path}" ||
          _wmh_status=70
      else
        _wmh_path="${_wmh_tool_path}"
        while [[ "${_wmh_path}" != / && -n "${_wmh_path}" ]]; do
          [[ ! -L "${_wmh_path}" ]] || {
            _wmh_status=70
            break
          }
          _wmh_path="${_wmh_path%/*}"
          [[ -n "${_wmh_path}" ]] || _wmh_path=/
        done
      fi
      (( _wmh_status == 0 )) || break
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%l\t%z' \
          "${_wmh_tool_path}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%h\t%s' -- \
          "${_wmh_tool_path}" 2>/dev/null)" || {
            _wmh_status=70
            break
          }
      fi
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
        _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      [[ -z "${_wmh_extra}" && "${_wmh_mode}" =~ ^[0-7]{3,4}$ &&
         "${_wmh_mode: -2:1}" != [2367] &&
         "${_wmh_mode: -1}" != [2367] &&
         "${_wmh_links}" == 1 &&
         "${_wmh_size}" =~ ^[1-9][0-9]*$ && "${_wmh_size}" -le 67108864 &&
         ( "${_wmh_owner}" == 0 || "${_wmh_owner}" == "${EUID}" ) ]] ||
        _wmh_status=70
    done

    if (( _wmh_status == 0 )) && [[ -z "${_wmh_phrase}" ]]; then
      _wmh_command_status=0
      __guild_cntools_wallet_capture_bound 2048 _wmh_phrase '' \
        "${_wmh_tools[cardano-address]}" recovery-phrase generate ||
        _wmh_command_status=$?
      if (( _wmh_command_status == 70 )); then
        _wmh_status=70
      elif (( _wmh_command_status != 0 )); then
        _wmh_status=1
      fi
    fi
    if (( _wmh_status == 0 )); then
      [[ -n "${_wmh_phrase}" && "${#_wmh_phrase}" -le 2048 &&
         "${_wmh_phrase}" != ' '* && "${_wmh_phrase}" != *' ' &&
         "${_wmh_phrase}" != *'  '* &&
         ! "${_wmh_phrase}" =~ [[:cntrl:]] ]] || _wmh_status=70
      _wmh_rest="${_wmh_phrase}"
      _wmh_count=0
      while (( _wmh_status == 0 )); do
        if [[ "${_wmh_rest}" == *' '* ]]; then
          _wmh_word="${_wmh_rest%% *}"
          _wmh_rest="${_wmh_rest#* }"
        else
          _wmh_word="${_wmh_rest}"
          _wmh_rest=
        fi
        [[ "${_wmh_word}" =~ ^[a-z]{1,32}$ ]] || _wmh_status=70
        _wmh_count=$((_wmh_count + 1))
        [[ -n "${_wmh_rest}" ]] || break
      done
      (( _wmh_count == 15 || _wmh_count == 24 )) || _wmh_status=70
    fi
    if (( _wmh_status == 0 )); then
      if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
        _wmh_phrase_sha="$(builtin printf '%s' "${_wmh_phrase}" |
          "${_wmh_tools[hash]}" 2>/dev/null)"
      else
        _wmh_phrase_sha="$(builtin printf '%s' "${_wmh_phrase}" |
          "${_wmh_tools[hash]}" -a 256 2>/dev/null)"
      fi
      _wmh_phrase_sha="${_wmh_phrase_sha%% *}"
      [[ "${_wmh_phrase_sha}" =~ ^[0-9a-f]{64}$ ]] || _wmh_status=70
    fi
    if (( _wmh_status == 0 )); then
      _wmh_command_status=0
      __guild_cntools_wallet_capture_bound 2048 _wmh_root_prv \
        _wmh_phrase "${_wmh_tools[cardano-address]}" \
        key from-recovery-phrase Shelley || _wmh_command_status=$?
      if (( _wmh_command_status == 70 )); then
        _wmh_status=70
      elif (( _wmh_command_status != 0 )); then
        _wmh_status=1
      fi
      (( _wmh_status != 0 )) ||
        [[ "${#_wmh_root_prv}" -ge 20 && "${#_wmh_root_prv}" -le 2048 &&
           "${_wmh_root_prv}" =~ ^[A-Za-z0-9_]+$ ]] || _wmh_status=70
    fi
    if (( _wmh_status == 0 )); then
      _wmh_command_status=0
      __guild_cntools_wallet_capture_bound 512 _wmh_caddr_version '' \
        "${_wmh_tools[cardano-address]}" -v || _wmh_command_status=$?
      if (( _wmh_command_status == 70 )); then
        _wmh_status=70
      elif (( _wmh_command_status != 0 )); then
        _wmh_status=1
      else
        _wmh_caddr_version="${_wmh_caddr_version%% *}"
        case "${_wmh_caddr_version}" in
          2.*) _wmh_caddr_arg= ;;
          3.*) _wmh_caddr_arg=--with-chain-code ;;
          *) _wmh_status=70 ;;
        esac
      fi
    fi
    _wmh_role_paths=(
      "1852H/1815H/${acct_idx:-}H/0/${key_idx:-}"
      "1852H/1815H/${acct_idx:-}H/2/${key_idx:-}"
      "1852H/1815H/${acct_idx:-}H/3/${key_idx:-}"
      "1852H/1815H/${acct_idx:-}H/4/${key_idx:-}"
      "1852H/1815H/${acct_idx:-}H/5/${key_idx:-}"
      "1854H/1815H/${acct_idx:-}H/0/${key_idx:-}"
      "1854H/1815H/${acct_idx:-}H/2/${key_idx:-}"
      "1854H/1815H/${acct_idx:-}H/3/${key_idx:-}"
    )
    for _wmh_index in "${!_wmh_roles[@]}"; do
      (( _wmh_status == 0 )) || break
      _wmh_role="${_wmh_roles[_wmh_index]}"
      _wmh_role_path="${_wmh_role_paths[_wmh_index]}"
      _wmh_command_status=0
      __guild_cntools_wallet_capture_bound 2048 _wmh_captured \
        _wmh_root_prv "${_wmh_tools[cardano-address]}" \
        key child "${_wmh_role_path}" || _wmh_command_status=$?
      if (( _wmh_command_status == 70 )); then
        _wmh_status=70
      elif (( _wmh_command_status != 0 )); then
        _wmh_status=1
      fi
      (( _wmh_status == 0 )) || break
      _wmh_xprv["${_wmh_role}"]="${_wmh_captured}"
      _wmh_captured=
      [[ "${#_wmh_xprv[${_wmh_role}]}" -ge 20 &&
         "${#_wmh_xprv[${_wmh_role}]}" -le 2048 &&
         "${_wmh_xprv[${_wmh_role}]}" =~ ^[A-Za-z0-9_]+$ ]] ||
        _wmh_status=70
      (( _wmh_status == 0 )) || break
      _wmh_command_status=0
      _wmh_value="${_wmh_xprv[${_wmh_role}]}"
      if [[ -n "${_wmh_caddr_arg}" ]]; then
        __guild_cntools_wallet_capture_bound 2048 _wmh_captured \
          _wmh_value \
          "${_wmh_tools[cardano-address]}" key public \
          "${_wmh_caddr_arg}" || _wmh_command_status=$?
      else
        __guild_cntools_wallet_capture_bound 2048 _wmh_captured \
          _wmh_value \
          "${_wmh_tools[cardano-address]}" key public ||
          _wmh_command_status=$?
      fi
      _wmh_value=
      if (( _wmh_command_status == 70 )); then
        _wmh_status=70
      elif (( _wmh_command_status != 0 )); then
        _wmh_status=1
      fi
      (( _wmh_status == 0 )) || break
      _wmh_xpub["${_wmh_role}"]="${_wmh_captured}"
      _wmh_captured=
      [[ "${#_wmh_xpub[${_wmh_role}]}" -ge 20 &&
         "${#_wmh_xpub[${_wmh_role}]}" -le 2048 &&
         "${_wmh_xpub[${_wmh_role}]}" =~ ^[A-Za-z0-9_]+$ ]] ||
        _wmh_status=70
    done
    _wmh_root_prv=

    _wmh_sk_file[payment]="${_wmh_stage}/${WALLET_PAY_SK_FILENAME:-}"
    _wmh_vk_file[payment]="${_wmh_stage}/${WALLET_PAY_VK_FILENAME:-}"
    _wmh_sk_file[stake]="${_wmh_stage}/${WALLET_STAKE_SK_FILENAME:-}"
    _wmh_vk_file[stake]="${_wmh_stage}/${WALLET_STAKE_VK_FILENAME:-}"
    _wmh_sk_file[drep]="${_wmh_stage}/${WALLET_GOV_DREP_SK_FILENAME:-}"
    _wmh_vk_file[drep]="${_wmh_stage}/${WALLET_GOV_DREP_VK_FILENAME:-}"
    _wmh_sk_file[cc_cold]="${_wmh_stage}/${WALLET_GOV_CC_COLD_SK_FILENAME:-}"
    _wmh_vk_file[cc_cold]="${_wmh_stage}/${WALLET_GOV_CC_COLD_VK_FILENAME:-}"
    _wmh_sk_file[cc_hot]="${_wmh_stage}/${WALLET_GOV_CC_HOT_SK_FILENAME:-}"
    _wmh_vk_file[cc_hot]="${_wmh_stage}/${WALLET_GOV_CC_HOT_VK_FILENAME:-}"
    _wmh_sk_file[ms_payment]="${_wmh_stage}/${WALLET_MULTISIG_PREFIX:-}${WALLET_PAY_SK_FILENAME:-}"
    _wmh_vk_file[ms_payment]="${_wmh_stage}/${WALLET_MULTISIG_PREFIX:-}${WALLET_PAY_VK_FILENAME:-}"
    _wmh_sk_file[ms_stake]="${_wmh_stage}/${WALLET_MULTISIG_PREFIX:-}${WALLET_STAKE_SK_FILENAME:-}"
    _wmh_vk_file[ms_stake]="${_wmh_stage}/${WALLET_MULTISIG_PREFIX:-}${WALLET_STAKE_VK_FILENAME:-}"
    _wmh_sk_file[ms_drep]="${_wmh_stage}/${WALLET_MULTISIG_PREFIX:-}${WALLET_GOV_DREP_SK_FILENAME:-}"
    _wmh_vk_file[ms_drep]="${_wmh_stage}/${WALLET_MULTISIG_PREFIX:-}${WALLET_GOV_DREP_VK_FILENAME:-}"
    _wmh_sk_type[payment]=PaymentExtendedSigningKeyShelley_ed25519_bip32
    _wmh_vk_type[payment]=PaymentVerificationKeyShelley_ed25519
    _wmh_sk_type[stake]=StakeExtendedSigningKeyShelley_ed25519_bip32
    _wmh_vk_type[stake]=StakeVerificationKeyShelley_ed25519
    _wmh_sk_type[drep]=DRepExtendedSigningKey_ed25519_bip32
    _wmh_vk_type[drep]=DRepVerificationKey_ed25519
    _wmh_sk_type[cc_cold]=ConstitutionalCommitteeColdExtendedSigningKey_ed25519_bip32
    _wmh_vk_type[cc_cold]=ConstitutionalCommitteeColdVerificationKey_ed25519
    _wmh_sk_type[cc_hot]=ConstitutionalCommitteeHotExtendedSigningKey_ed25519_bip32
    _wmh_vk_type[cc_hot]=ConstitutionalCommitteeHotVerificationKey_ed25519
    _wmh_sk_type[ms_payment]=PaymentExtendedSigningKeyShelley_ed25519_bip32
    _wmh_vk_type[ms_payment]=PaymentVerificationKeyShelley_ed25519
    _wmh_sk_type[ms_stake]=StakeExtendedSigningKeyShelley_ed25519_bip32
    _wmh_vk_type[ms_stake]=StakeVerificationKeyShelley_ed25519
    _wmh_sk_type[ms_drep]=DRepExtendedSigningKey_ed25519_bip32
    _wmh_vk_type[ms_drep]=DRepVerificationKey_ed25519
    _wmh_vk_description[payment]='Payment Verification Key'
    _wmh_vk_description[stake]='Stake Verification Key'
    _wmh_vk_description[drep]='Delegated Representative Verification Key'
    _wmh_vk_description[cc_cold]='Constitutional Committee Cold Verification Key'
    _wmh_vk_description[cc_hot]='Constitutional Committee Hot Verification Key'
    _wmh_vk_description[ms_payment]='Payment Verification Key'
    _wmh_vk_description[ms_stake]='Stake Verification Key'
    _wmh_vk_description[ms_drep]='Delegated Representative Verification Key'

    for _wmh_role in "${_wmh_roles[@]}"; do
      (( _wmh_status == 0 )) || break
      _wmh_command_status=0
      _wmh_value="${_wmh_xprv[${_wmh_role}]}"
      __guild_cntools_wallet_capture_bound 4096 _wmh_hex \
        _wmh_value "${_wmh_tools[bech32]}" ||
        _wmh_command_status=$?
      _wmh_value=
      if (( _wmh_command_status == 70 )); then
        _wmh_status=70
      elif (( _wmh_command_status != 0 )); then
        _wmh_status=1
      fi
      (( _wmh_status == 0 )) || break
      [[ "${_wmh_hex}" =~ ^[0-9A-Fa-f]+$ &&
         ${#_wmh_hex} -ge 128 && ${#_wmh_hex} -le 4096 ]] || {
        _wmh_status=70
        break
      }
      _wmh_es_key="${_wmh_hex:0:128}"
      _wmh_hex=
      _wmh_command_status=0
      _wmh_value="${_wmh_xpub[${_wmh_role}]}"
      __guild_cntools_wallet_capture_bound 512 _wmh_hex \
        _wmh_value "${_wmh_tools[bech32]}" ||
        _wmh_command_status=$?
      _wmh_value=
      if (( _wmh_command_status == 70 )); then
        _wmh_status=70
      elif (( _wmh_command_status != 0 )); then
        _wmh_status=1
      fi
      (( _wmh_status == 0 )) || break
      [[ "${_wmh_hex}" =~ ^[0-9A-Fa-f]{128}$ ]] || {
        _wmh_status=70
        break
      }
      _wmh_es_key="${_wmh_es_key}${_wmh_hex}"
      _wmh_path="${_wmh_sk_file[${_wmh_role}]}"
      _wmh_leaf="${_wmh_path##*/}"
      _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      builtin printf -v _wmh_value \
        '{\n  "type": "%s",\n  "description": "CNTools mnemonic signing key",\n  "cborHex": "5880%s"\n}\n' \
        "${_wmh_sk_type[${_wmh_role}]}" "${_wmh_es_key,,}"
      __guild_cntools_wallet_output_write_bound "${_wmh_path}" \
        "${_wmh_expected_identity}" 1 16384 _wmh_value raw || {
          _wmh_status=70
          break
        }
      __guild_cntools_wallet_output_json_bound "${_wmh_path}" \
        "${_wmh_expected_identity}" 1 16384 sk \
        "${_wmh_sk_type[${_wmh_role}]}" || _wmh_status=70
      (( _wmh_status == 0 )) || break
      _wmh_path="${_wmh_vk_file[${_wmh_role}]}"
      _wmh_leaf="${_wmh_path##*/}"
      _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      builtin printf -v _wmh_value \
        '{\n    "type": "%s",\n    "description": "%s",\n    "cborHex": "5820%s"\n}\n' \
        "${_wmh_vk_type[${_wmh_role}]}" \
        "${_wmh_vk_description[${_wmh_role}]}" "${_wmh_hex:0:64}"
      __guild_cntools_wallet_output_write_bound "${_wmh_path}" \
        "${_wmh_expected_identity}" 1 16384 _wmh_value raw || {
          _wmh_status=70
          break
        }
      __guild_cntools_wallet_output_json_bound "${_wmh_path}" \
        "${_wmh_expected_identity}" 1 16384 vk \
        "${_wmh_vk_type[${_wmh_role}]}" || _wmh_status=70
      (( _wmh_status == 0 )) || break
      _wmh_xprv["${_wmh_role}"]=
      _wmh_xpub["${_wmh_role}"]=
      _wmh_value=
      _wmh_es_key=
      _wmh_hex=
    done

    # Derivation marker, addresses, and credentials complete the exact wallet
    # inventory. All untrusted command output is private and bounded.
    if (( _wmh_status == 0 )); then
      _wmh_path="${_wmh_stage}/${WALLET_DERIVATION_PATH_FILENAME:-}"
      _wmh_leaf="${_wmh_path##*/}"
      _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      __guild_cntools_wallet_output_authenticate "${_wmh_path}" \
        "${_wmh_expected_identity}" 0 0 _wmh_live_identity ||
        _wmh_status=70
    fi
    if (( _wmh_status == 0 )); then
      builtin printf -v _wmh_value '1852H/1815H/%sH/x/%s' \
        "${acct_idx}" "${key_idx}"
      __guild_cntools_wallet_output_write_bound "${_wmh_path}" \
        "${_wmh_expected_identity}" 1 512 _wmh_value line ||
        _wmh_status=70
      _wmh_value=
    fi
    if (( _wmh_status == 0 )); then
      _wmh_path="${_wmh_stage}/${WALLET_BASE_ADDR_FILENAME:-}"
      _wmh_leaf="${_wmh_path##*/}"
      _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      _wmh_leaf="${_wmh_vk_file[payment]##*/}"
      _wmh_input_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      _wmh_leaf="${_wmh_vk_file[stake]##*/}"
      _wmh_output_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      _wmh_command_status=0
      __guild_cntools_wallet_ccli_capture_bound 512 _wmh_captured \
        "${_wmh_vk_file[payment]}" "${_wmh_input_identity}" \
        "${_wmh_vk_file[stake]}" "${_wmh_output_identity}" \
        address build --payment-verification-key-file \
        '@GUILD_WMH_FD_ONE@' --stake-verification-key-file \
        '@GUILD_WMH_FD_TWO@' "${_wmh_network_args[@]}" ||
        _wmh_command_status=$?
      if (( _wmh_command_status == 70 )); then
        _wmh_status=70
      elif (( _wmh_command_status != 0 )); then
        _wmh_status=1
      elif [[ "${_wmh_network_kind}" == mainnet ]]; then
        [[ "${_wmh_captured}" =~ ^addr1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      else
        [[ "${_wmh_captured}" =~ ^addr_test1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      fi
      (( _wmh_status != 0 )) ||
        __guild_cntools_wallet_output_write_bound "${_wmh_path}" \
          "${_wmh_expected_identity}" 1 512 _wmh_captured line ||
        _wmh_status=70
      _wmh_captured=
    fi
    if (( _wmh_status == 0 )); then
      _wmh_path="${_wmh_stage}/${WALLET_PAY_ADDR_FILENAME:-}"
      _wmh_leaf="${_wmh_path##*/}"
      _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      _wmh_leaf="${_wmh_vk_file[payment]##*/}"
      _wmh_input_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      _wmh_command_status=0
      __guild_cntools_wallet_ccli_capture_bound 512 _wmh_captured \
        "${_wmh_vk_file[payment]}" "${_wmh_input_identity}" '' '' \
        address build --payment-verification-key-file \
        '@GUILD_WMH_FD_ONE@' "${_wmh_network_args[@]}" ||
        _wmh_command_status=$?
      if (( _wmh_command_status == 70 )); then
        _wmh_status=70
      elif (( _wmh_command_status != 0 )); then
        _wmh_status=1
      elif [[ "${_wmh_network_kind}" == mainnet ]]; then
        [[ "${_wmh_captured}" =~ ^addr1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      else
        [[ "${_wmh_captured}" =~ ^addr_test1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      fi
      (( _wmh_status != 0 )) ||
        __guild_cntools_wallet_output_write_bound "${_wmh_path}" \
          "${_wmh_expected_identity}" 1 512 _wmh_captured line ||
        _wmh_status=70
      _wmh_captured=
    fi
    if (( _wmh_status == 0 )); then
      _wmh_path="${_wmh_stage}/${WALLET_STAKE_ADDR_FILENAME:-}"
      _wmh_leaf="${_wmh_path##*/}"
      _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      _wmh_leaf="${_wmh_vk_file[stake]##*/}"
      _wmh_input_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      _wmh_command_status=0
      __guild_cntools_wallet_ccli_capture_bound 512 _wmh_captured \
        "${_wmh_vk_file[stake]}" "${_wmh_input_identity}" '' '' \
        stake-address build --stake-verification-key-file \
        '@GUILD_WMH_FD_ONE@' "${_wmh_network_args[@]}" ||
        _wmh_command_status=$?
      if (( _wmh_command_status == 70 )); then
        _wmh_status=70
      elif (( _wmh_command_status != 0 )); then
        _wmh_status=1
      elif [[ "${_wmh_network_kind}" == mainnet ]]; then
        [[ "${_wmh_captured}" =~ ^stake1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      else
        [[ "${_wmh_captured}" =~ ^stake_test1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      fi
      (( _wmh_status != 0 )) ||
        __guild_cntools_wallet_output_write_bound "${_wmh_path}" \
          "${_wmh_expected_identity}" 1 512 _wmh_captured line ||
        _wmh_status=70
      _wmh_captured=
    fi
    if (( _wmh_status == 0 )); then
      for _wmh_role in payment stake ms_payment ms_stake; do
        case "${_wmh_role}" in
          payment)
            _wmh_path="${_wmh_stage}/${WALLET_PAY_CRED_FILENAME:-}"
            _wmh_tool_name=address
            _wmh_value=--payment-verification-key-file
            ;;
          stake)
            _wmh_path="${_wmh_stage}/${WALLET_STAKE_CRED_FILENAME:-}"
            _wmh_tool_name=stake-address
            _wmh_value=--stake-verification-key-file
            ;;
          ms_payment)
            _wmh_path="${_wmh_stage}/${WALLET_MULTISIG_PREFIX:-}${WALLET_PAY_CRED_FILENAME:-}"
            _wmh_tool_name=address
            _wmh_value=--payment-verification-key-file
            ;;
          ms_stake)
            _wmh_path="${_wmh_stage}/${WALLET_MULTISIG_PREFIX:-}${WALLET_STAKE_CRED_FILENAME:-}"
            _wmh_tool_name=stake-address
            _wmh_value=--stake-verification-key-file
            ;;
        esac
        _wmh_leaf="${_wmh_path##*/}"
        _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
        _wmh_leaf="${_wmh_vk_file[${_wmh_role}]##*/}"
        _wmh_input_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
        _wmh_command_status=0
        __guild_cntools_wallet_ccli_capture_bound 512 _wmh_captured \
          "${_wmh_vk_file[${_wmh_role}]}" "${_wmh_input_identity}" '' '' \
          "${_wmh_tool_name}" key-hash "${_wmh_value}" \
          '@GUILD_WMH_FD_ONE@' || _wmh_command_status=$?
        if (( _wmh_command_status == 70 )); then
          _wmh_status=70
        elif (( _wmh_command_status != 0 )); then
          _wmh_status=1
        elif [[ ! "${_wmh_captured}" =~ ^[0-9A-Fa-f]{56}$ ]]; then
          _wmh_status=70
        else
          __guild_cntools_wallet_output_write_bound "${_wmh_path}" \
            "${_wmh_expected_identity}" 1 512 _wmh_captured line ||
            _wmh_status=70
        fi
        _wmh_captured=
        (( _wmh_status == 0 )) || break
      done
    fi

    # Validate schema, terminal-safe addresses and exact file inventory.
    for _wmh_role in "${_wmh_roles[@]}"; do
      (( _wmh_status == 0 )) || break
      _wmh_leaf="${_wmh_sk_file[${_wmh_role}]##*/}"
      _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      __guild_cntools_wallet_output_authenticate \
        "${_wmh_sk_file[${_wmh_role}]}" "${_wmh_expected_identity}" \
        1 16384 _wmh_live_identity || _wmh_status=70
      (( _wmh_status == 0 )) || break
      __guild_cntools_wallet_output_json_bound \
        "${_wmh_sk_file[${_wmh_role}]}" "${_wmh_expected_identity}" \
        1 16384 sk "${_wmh_sk_type[${_wmh_role}]}" || _wmh_status=70
      (( _wmh_status == 0 )) || break
      __guild_cntools_wallet_output_authenticate \
        "${_wmh_sk_file[${_wmh_role}]}" "${_wmh_expected_identity}" \
        1 16384 _wmh_live_identity || _wmh_status=70
      (( _wmh_status == 0 )) || break
      _wmh_leaf="${_wmh_vk_file[${_wmh_role}]##*/}"
      _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      __guild_cntools_wallet_output_authenticate \
        "${_wmh_vk_file[${_wmh_role}]}" "${_wmh_expected_identity}" \
        1 16384 _wmh_live_identity || _wmh_status=70
      (( _wmh_status == 0 )) || break
      __guild_cntools_wallet_output_json_bound \
        "${_wmh_vk_file[${_wmh_role}]}" "${_wmh_expected_identity}" \
        1 16384 vk "${_wmh_vk_type[${_wmh_role}]}" || _wmh_status=70
      (( _wmh_status == 0 )) || break
      __guild_cntools_wallet_output_authenticate \
        "${_wmh_vk_file[${_wmh_role}]}" "${_wmh_expected_identity}" \
        1 16384 _wmh_live_identity || _wmh_status=70
    done
    if (( _wmh_status == 0 )); then
      _wmh_path="${_wmh_stage}/${WALLET_BASE_ADDR_FILENAME}"
      _wmh_leaf="${_wmh_path##*/}"
      _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      __guild_cntools_wallet_output_read_bound "${_wmh_path}" \
        "${_wmh_expected_identity}" 1 512 _wmh_value || _wmh_status=70
      if [[ "${_wmh_network_kind}" == mainnet ]]; then
        [[ "${_wmh_value}" =~ ^addr1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      else
        [[ "${_wmh_value}" =~ ^addr_test1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      fi
      _wmh_path="${_wmh_stage}/${WALLET_PAY_ADDR_FILENAME}"
      _wmh_leaf="${_wmh_path##*/}"
      _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      (( _wmh_status != 0 )) ||
        __guild_cntools_wallet_output_read_bound "${_wmh_path}" \
          "${_wmh_expected_identity}" 1 512 _wmh_value || _wmh_status=70
      if [[ "${_wmh_network_kind}" == mainnet ]]; then
        [[ "${_wmh_value}" =~ ^addr1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      else
        [[ "${_wmh_value}" =~ ^addr_test1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      fi
      _wmh_path="${_wmh_stage}/${WALLET_STAKE_ADDR_FILENAME}"
      _wmh_leaf="${_wmh_path##*/}"
      _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      (( _wmh_status != 0 )) ||
        __guild_cntools_wallet_output_read_bound "${_wmh_path}" \
          "${_wmh_expected_identity}" 1 512 _wmh_value || _wmh_status=70
      if [[ "${_wmh_network_kind}" == mainnet ]]; then
        [[ "${_wmh_value}" =~ ^stake1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      else
        [[ "${_wmh_value}" =~ ^stake_test1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      fi
      for _wmh_leaf in "${WALLET_PAY_CRED_FILENAME}" \
          "${WALLET_STAKE_CRED_FILENAME}" \
          "${WALLET_MULTISIG_PREFIX}${WALLET_PAY_CRED_FILENAME}" \
          "${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_CRED_FILENAME}"; do
        _wmh_path="${_wmh_stage}/${_wmh_leaf}"
        _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
        __guild_cntools_wallet_output_read_bound "${_wmh_path}" \
          "${_wmh_expected_identity}" 1 512 _wmh_value || _wmh_status=70
        (( _wmh_status == 0 )) || break
        [[ "${_wmh_value}" =~ ^[0-9A-Fa-f]{56}$ ]] || _wmh_status=70
      done
    fi
    if (( _wmh_status == 0 )); then
      _wmh_found="$("${_wmh_tools[find]}" "${_wmh_stage}" -mindepth 1 \
        -maxdepth 1 -print 2>/dev/null)" || _wmh_status=70
      _wmh_count=0
      while IFS= builtin read -r _wmh_path; do
        [[ -n "${_wmh_path}" ]] || continue
        _wmh_leaf="${_wmh_path#"${_wmh_stage}/"}"
        [[ "${_wmh_leaf}" != */* &&
           -n "${_wmh_seen_leaves[${_wmh_leaf}]+set}" ]] || _wmh_status=70
        _wmh_count=$((_wmh_count + 1))
      done <<< "${_wmh_found}"
      (( _wmh_count == 24 )) || _wmh_status=70
    fi
    if (( _wmh_status == 0 )); then
      : > "${_wmh_inventory}"
      "${_wmh_tools[chmod]}" 0600 "${_wmh_inventory}" || _wmh_status=70
      for _wmh_leaf in "${_wmh_expected_leaves[@]}"; do
        _wmh_path="${_wmh_stage}/${_wmh_leaf}"
        _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
        __guild_cntools_wallet_output_hash_stable "${_wmh_path}" \
          "${_wmh_expected_identity}" 1 16384 _wmh_digest || {
            _wmh_status=70
            break
          }
        builtin printf '%s\t%s\n' "${_wmh_leaf}" "${_wmh_digest}" \
          >> "${_wmh_inventory}"
      done
    fi
    if (( _wmh_status == 0 )); then
      if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
        _wmh_inventory_sha="$("${_wmh_tools[hash]}" "${_wmh_inventory}" \
          2>/dev/null)"
      else
        _wmh_inventory_sha="$("${_wmh_tools[hash]}" -a 256 \
          "${_wmh_inventory}" 2>/dev/null)"
      fi
      _wmh_inventory_sha="${_wmh_inventory_sha%% *}"
      [[ "${_wmh_inventory_sha}" =~ ^[0-9a-f]{64}$ ]] || _wmh_status=70
    fi
    if (( _wmh_status == 0 )); then
      _wmh_state="${_wmh_lock}/state"
      : > "${_wmh_state}"
      "${_wmh_tools[chmod]}" 0600 "${_wmh_state}" || _wmh_status=70
      builtin printf '%s\n' \
        $'version\t1' \
        "root	${_wmh_root}" \
        "root_identity	${_wmh_root_identity}" \
        "destination	${_wmh_destination}" \
        "destination_kind	${_wmh_destination_kind}" \
        "destination_identity	${_wmh_destination_identity}" \
        "lock_identity	${_wmh_lock_identity}" \
        "stage_identity	${_wmh_stage_identity}" \
        "wallet	${wallet_name}" \
        "account	${acct_idx}" \
        "key	${key_idx}" \
        "network_kind	${_wmh_network_kind}" \
        "network_magic	${_wmh_network_magic}" \
        "phrase_sha	${_wmh_phrase_sha}" \
        "inventory_sha	${_wmh_inventory_sha}" > "${_wmh_state}"
      _wmh_cleanup_marker_value=$'cleanup\t'"${_wmh_root_identity}"$'\t'\
"${_wmh_lock_identity}"$'\t'"${_wmh_stage_identity}"$'\t'\
"${_wmh_phrase_sha}"$'\t'"${_wmh_inventory_sha}"
      [[ ! -e "${_wmh_cleanup_marker}" &&
         ! -L "${_wmh_cleanup_marker}" ]] || _wmh_status=70
      if (( _wmh_status == 0 )); then
        : > "${_wmh_cleanup_marker}"
        "${_wmh_tools[chmod]}" 0600 "${_wmh_cleanup_marker}" ||
          _wmh_status=70
        builtin printf '%s\n' "${_wmh_cleanup_marker_value}" \
          > "${_wmh_cleanup_marker}"
      fi
      if (( _wmh_status == 0 )); then
        if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%l\t%z' \
            "${_wmh_cleanup_marker}" 2>/dev/null)"; then
          :
        else
          _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%h\t%s' -- \
            "${_wmh_cleanup_marker}" 2>/dev/null)" || _wmh_status=70
        fi
        IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
          _wmh_extra <<< "${_wmh_metadata}"
        _wmh_mode="${_wmh_mode#0}"
        _wmh_value="$(< "${_wmh_cleanup_marker}")"
        [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
           "${_wmh_mode}" == 600 && "${_wmh_links}" == 1 &&
           "${_wmh_size}" -gt 0 && "${_wmh_size}" -le 512 &&
           "${_wmh_value}" == "${_wmh_cleanup_marker_value}" ]] ||
          _wmh_status=70
      fi
    fi
    if (( _wmh_status == 0 )); then
      builtin printf -v "${_wmh_phrase_name}" '%s' "${_wmh_phrase}"
      builtin printf -v "${_wmh_state_name}" '%s' "${_wmh_state}"
    fi
    fi
  fi

  if (( _wmh_status == 0 )) && [[ "${_wmh_phase}" == acknowledge ]]; then
    [[ -n "${_wmh_phrase}" ]] || _wmh_status=70
    if [[ -e "${_wmh_ack}" || -L "${_wmh_ack}" ]]; then
      [[ -f "${_wmh_ack}" && ! -L "${_wmh_ack}" ]] || _wmh_status=70
    else
      _wmh_path="${_wmh_lock}/acknowledged.new"
      : > "${_wmh_path}"
      "${_wmh_tools[chmod]}" 0600 "${_wmh_path}" || _wmh_status=70
      builtin printf 'ack\t%s\t%s\n' "${_wmh_saved_phrase_sha}" \
        "${_wmh_saved_inventory_sha}" > "${_wmh_path}"
      if (( _wmh_status == 0 )); then
        if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%l\t%z\t%d\t%i' \
            "${_wmh_path}" 2>/dev/null)"; then
          :
        else
          _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%h\t%s\t%d\t%i' -- \
            "${_wmh_path}" 2>/dev/null)" || _wmh_status=70
        fi
        IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
          _wmh_device _wmh_inode _wmh_extra <<< "${_wmh_metadata}"
        _wmh_mode="${_wmh_mode#0}"
        [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
           "${_wmh_mode}" == 600 && "${_wmh_links}" == 1 &&
           "${_wmh_size}" -gt 0 && "${_wmh_size}" -le 512 ]] ||
          _wmh_status=70
        _wmh_ack_source_identity="${_wmh_device}:${_wmh_inode}"
      fi
      if (( _wmh_status == 0 )); then
        "${_wmh_tools[ln]}" -- "${_wmh_path}" "${_wmh_ack}" \
          >/dev/null 2>&1 || _wmh_command_status=$?
        if [[ -f "${_wmh_ack}" && ! -L "${_wmh_ack}" ]]; then
          if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%l\t%z\t%d\t%i' \
              "${_wmh_ack}" 2>/dev/null)"; then
            :
          else
            _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%h\t%s\t%d\t%i' -- \
              "${_wmh_ack}" 2>/dev/null)" || _wmh_status=70
          fi
          IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
            _wmh_device _wmh_inode _wmh_extra <<< "${_wmh_metadata}"
          _wmh_mode="${_wmh_mode#0}"
          [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
             "${_wmh_mode}" == 600 && "${_wmh_links}" == 2 &&
             "${_wmh_size}" -gt 0 && "${_wmh_size}" -le 512 &&
             "${_wmh_device}:${_wmh_inode}" == "${_wmh_ack_source_identity}" ]] ||
            _wmh_status=70
        else
          (( _wmh_command_status == 0 )) && _wmh_status=70 || _wmh_status=1
        fi
      fi
      "${_wmh_tools[rm]}" -f -- "${_wmh_path}" >/dev/null 2>&1 ||
        _wmh_status=70
      _wmh_ack_created=Y
    fi
    if (( _wmh_status == 0 )); then
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%l\t%z' \
          "${_wmh_ack}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%h\t%s' -- \
          "${_wmh_ack}" 2>/dev/null)" || _wmh_status=70
      fi
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
        _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      _wmh_value="$(< "${_wmh_ack}")"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
         "${_wmh_mode}" == 600 && "${_wmh_links}" == 1 &&
         "${_wmh_size}" -gt 0 && "${_wmh_size}" -le 512 &&
         "${_wmh_value}" == $'ack\t'"${_wmh_saved_phrase_sha}"$'\t'"${_wmh_saved_inventory_sha}" ]] ||
        _wmh_status=70
    fi
  fi

  if (( _wmh_status == 0 )) && [[ "${_wmh_phase}" == publish ]]; then
    [[ -f "${_wmh_ack}" && ! -L "${_wmh_ack}" ]] || _wmh_status=70
    if (( _wmh_status == 0 )); then
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%l\t%z' \
          "${_wmh_ack}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%h\t%s' -- \
          "${_wmh_ack}" 2>/dev/null)" || _wmh_status=70
      fi
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
        _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      _wmh_value="$(< "${_wmh_ack}")"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
         "${_wmh_mode}" == 600 && "${_wmh_links}" == 1 &&
         "${_wmh_size}" -gt 0 && "${_wmh_size}" -le 512 &&
         "${_wmh_value}" == $'ack\t'"${_wmh_saved_phrase_sha}"$'\t'"${_wmh_saved_inventory_sha}" ]] ||
        _wmh_status=70
    fi
    # Close the validation-to-publication gap: rebind every authority and
    # private leaf immediately before the first destination mutation.
    for _wmh_path in "${_wmh_root}" "${_wmh_lock}" "${_wmh_stage}"; do
      (( _wmh_status == 0 )) || break
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%d\t%i' \
          "${_wmh_path}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%d\t%i' -- \
          "${_wmh_path}" 2>/dev/null)" || {
            _wmh_status=70
            break
          }
      fi
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_device _wmh_inode \
        _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      _wmh_identity="${_wmh_device}:${_wmh_inode}"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" ]] ||
        _wmh_status=70
      if [[ "${_wmh_path}" == "${_wmh_root}" ]]; then
        [[ "${_wmh_identity}" == "${_wmh_saved_root_identity}" &&
           ( "${_wmh_mode}" == 700 || "${_wmh_mode}" == 750 ||
             "${_wmh_mode}" == 755 ) ]] || _wmh_status=70
      elif [[ "${_wmh_path}" == "${_wmh_lock}" ]]; then
        [[ "${_wmh_identity}" == "${_wmh_saved_lock_identity}" &&
           "${_wmh_mode}" == 700 ]] || _wmh_status=70
      else
        [[ "${_wmh_identity}" == "${_wmh_saved_stage_identity}" &&
           "${_wmh_mode}" == 700 ]] || _wmh_status=70
      fi
    done
    for _wmh_leaf in "${_wmh_expected_leaves[@]}"; do
      (( _wmh_status == 0 )) || break
      _wmh_path="${_wmh_stage}/${_wmh_leaf}"
      _wmh_expected_identity="${_wmh_leaf_identities[${_wmh_leaf}]:-}"
      __guild_cntools_wallet_output_hash_stable "${_wmh_path}" \
        "${_wmh_expected_identity}" 1 16384 _wmh_live_digest ||
        _wmh_status=70
      [[ "${_wmh_live_digest}" == "${_wmh_leaf_digests[${_wmh_leaf}]}" ]] ||
        _wmh_status=70
    done
    if (( _wmh_status == 0 )); then
      _wmh_leaf="${WALLET_BASE_ADDR_FILENAME}"
      __guild_cntools_wallet_output_read_bound "${_wmh_stage}/${_wmh_leaf}" \
        "${_wmh_leaf_identities[${_wmh_leaf}]:-}" 1 512 \
        _wmh_publish_base || _wmh_status=70
      _wmh_leaf="${WALLET_PAY_ADDR_FILENAME}"
      (( _wmh_status != 0 )) ||
        __guild_cntools_wallet_output_read_bound "${_wmh_stage}/${_wmh_leaf}" \
          "${_wmh_leaf_identities[${_wmh_leaf}]:-}" 1 512 \
          _wmh_publish_pay || _wmh_status=70
      _wmh_leaf="${WALLET_STAKE_ADDR_FILENAME}"
      (( _wmh_status != 0 )) ||
        __guild_cntools_wallet_output_read_bound "${_wmh_stage}/${_wmh_leaf}" \
          "${_wmh_leaf_identities[${_wmh_leaf}]:-}" 1 512 \
          _wmh_publish_reward || _wmh_status=70
      for _wmh_value in "${_wmh_publish_base}" "${_wmh_publish_pay}" \
          "${_wmh_publish_reward}"; do
        [[ -n "${_wmh_value}" && ${#_wmh_value} -le 512 &&
           ! "${_wmh_value}" =~ [[:cntrl:]] && "${_wmh_value}" != *\\* ]] ||
          _wmh_status=70
      done
    fi
    if (( _wmh_status == 0 )); then
      if [[ "${_wmh_saved_destination_kind}" == absent ]]; then
        [[ ! -e "${_wmh_destination}" && ! -L "${_wmh_destination}" ]] ||
          _wmh_status=70
        if (( _wmh_status == 0 )); then
          "${_wmh_tools[mkdir]}" -m 0700 -- "${_wmh_destination}" \
            >/dev/null 2>&1 || _wmh_command_status=$?
          if (( _wmh_command_status == 0 )) &&
             [[ -d "${_wmh_destination}" && ! -L "${_wmh_destination}" ]]; then
            _wmh_created_destination=Y
            "${_wmh_tools[chmod]}" 0700 "${_wmh_destination}" ||
              _wmh_status=70
          else
            _wmh_status=70
          fi
        fi
      elif [[ "${_wmh_saved_destination_kind}" == existing ]]; then
        [[ -d "${_wmh_destination}" && ! -L "${_wmh_destination}" ]] ||
          _wmh_status=70
        if (( _wmh_status == 0 )); then
          if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%d\t%i' \
              "${_wmh_destination}" 2>/dev/null)"; then
            :
          else
            _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%d\t%i' -- \
              "${_wmh_destination}" 2>/dev/null)" || _wmh_status=70
          fi
          IFS=$'\t' builtin read -r _wmh_device _wmh_inode _wmh_extra \
            <<< "${_wmh_metadata}"
          [[ -z "${_wmh_extra}" &&
             "${_wmh_device}:${_wmh_inode}" == "${_wmh_saved_destination_identity}" ]] ||
            _wmh_status=70
        fi
      else
        _wmh_status=70
      fi
    fi
    if (( _wmh_status == 0 )); then
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%d\t%i' \
          "${_wmh_destination}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%d\t%i' -- \
          "${_wmh_destination}" 2>/dev/null)" || _wmh_status=70
      fi
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_device _wmh_inode \
        _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
         ( "${_wmh_mode}" == 700 || "${_wmh_mode}" == 750 ||
           "${_wmh_mode}" == 755 ) ]] || _wmh_status=70
      _wmh_publish_destination_identity="${_wmh_device}:${_wmh_inode}"
    fi
    if (( _wmh_status == 0 )); then
      _wmh_found="$("${_wmh_tools[find]}" "${_wmh_destination}" \
        -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ||
        _wmh_status=70
      [[ -z "${_wmh_found}" ]] || _wmh_status=70
    fi
    for _wmh_leaf in "${_wmh_expected_leaves[@]}"; do
      (( _wmh_status == 0 )) || break
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%d\t%i' \
          "${_wmh_destination}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%d\t%i' -- \
          "${_wmh_destination}" 2>/dev/null)" || _wmh_status=70
      fi
      IFS=$'\t' builtin read -r _wmh_device _wmh_inode _wmh_extra \
        <<< "${_wmh_metadata}"
      [[ -z "${_wmh_extra}" &&
         "${_wmh_device}:${_wmh_inode}" == "${_wmh_publish_destination_identity}" ]] ||
        _wmh_status=70
      (( _wmh_status == 0 )) || break
      _wmh_path="${_wmh_destination}/${_wmh_leaf}"
      _wmh_command_status=0
      # Record both the active candidate and the ordered journal entry before
      # invoking ln. The command may create the hard link and then deliver a
      # deferred signal before returning, may return nonzero after creation,
      # or a later verification may fail. The scalar remains rollback authority
      # until the exact link is verified and the no-signal boundary is crossed.
      _wmh_publish_active_leaf="${_wmh_leaf}"
      _wmh_publish_attempts+=("${_wmh_leaf}")
      "${_wmh_tools[ln]}" -- "${_wmh_stage}/${_wmh_leaf}" "${_wmh_path}" \
        >/dev/null 2>&1 || _wmh_command_status=$?
      if [[ -f "${_wmh_path}" && ! -L "${_wmh_path}" ]]; then
        if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%l\t%z\t%d\t%i' \
            "${_wmh_path}" 2>/dev/null)"; then
          :
        else
          _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%h\t%s\t%d\t%i' -- \
            "${_wmh_path}" 2>/dev/null)" || _wmh_status=70
        fi
        IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
          _wmh_device _wmh_inode _wmh_extra <<< "${_wmh_metadata}"
        _wmh_mode="${_wmh_mode#0}"
        _wmh_live_identity="${_wmh_device}:${_wmh_inode}"
        [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
           "${_wmh_mode}" == 600 && "${_wmh_links}" == 2 &&
           "${_wmh_live_identity}" == "${_wmh_leaf_identities[${_wmh_leaf}]}" ]] ||
          _wmh_status=70
        __guild_cntools_wallet_output_hash_stable "${_wmh_path}" \
          "${_wmh_leaf_identities[${_wmh_leaf}]}" 1 16384 \
          _wmh_live_digest 2 || _wmh_status=70
        [[ "${_wmh_live_digest}" == "${_wmh_leaf_digests[${_wmh_leaf}]}" ]] ||
          _wmh_status=70
      else
        (( _wmh_command_status == 0 )) && _wmh_status=70 || _wmh_status=1
      fi
      (( _wmh_status == 0 )) || break
      [[ "${_wmh_signal_pending}" == N ]] || _wmh_status=70
      (( _wmh_status != 0 )) || _wmh_publish_active_leaf=
    done
    # Final public inventory authentication closes races on earlier links and
    # rejects injected leaves before the irreversible commit boundary.
    if (( _wmh_status == 0 )); then
      _wmh_found="$("${_wmh_tools[find]}" "${_wmh_destination}" \
        -mindepth 1 -maxdepth 1 -print 2>/dev/null)" || _wmh_status=70
      _wmh_count=0
      _wmh_seen_names=()
      while IFS= builtin read -r _wmh_path; do
        [[ -n "${_wmh_path}" ]] || continue
        _wmh_leaf="${_wmh_path#"${_wmh_destination}/"}"
        [[ "${_wmh_leaf}" != */* &&
           -n "${_wmh_seen_leaves[${_wmh_leaf}]+set}" &&
           -z "${_wmh_seen_names[${_wmh_leaf}]+set}" ]] || _wmh_status=70
        _wmh_seen_names["${_wmh_leaf}"]=Y
        _wmh_count=$((_wmh_count + 1))
      done <<< "${_wmh_found}"
      (( _wmh_count == 24 )) || _wmh_status=70
    fi
    for _wmh_leaf in "${_wmh_expected_leaves[@]}"; do
      (( _wmh_status == 0 )) || break
      _wmh_path="${_wmh_destination}/${_wmh_leaf}"
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%l\t%d\t%i' \
          "${_wmh_path}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%h\t%d\t%i' -- \
          "${_wmh_path}" 2>/dev/null)" || _wmh_status=70
      fi
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_device \
        _wmh_inode _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
         "${_wmh_mode}" == 600 && "${_wmh_links}" == 2 &&
         "${_wmh_device}:${_wmh_inode}" == "${_wmh_leaf_identities[${_wmh_leaf}]}" ]] ||
        _wmh_status=70
      __guild_cntools_wallet_output_hash_stable "${_wmh_path}" \
        "${_wmh_leaf_identities[${_wmh_leaf}]}" 1 16384 \
        _wmh_live_digest 2 || _wmh_status=70
      [[ "${_wmh_live_digest}" == "${_wmh_leaf_digests[${_wmh_leaf}]}" ]] ||
        _wmh_status=70
    done
    if (( _wmh_status == 0 )); then
      builtin printf -v "${_wmh_base_name}" '%s' "${_wmh_publish_base}"
      builtin printf -v "${_wmh_pay_name}" '%s' "${_wmh_publish_pay}"
      builtin printf -v "${_wmh_reward_name}" '%s' "${_wmh_publish_reward}"
      builtin printf -v "${_wmh_phrase_name}" '%s' ''
      builtin printf -v "${_wmh_state_name}" '%s' ''
      _wmh_phrase=
      _wmh_state=
      _wmh_committed=Y
    fi
  fi

  # A deferred precommit signal becomes a validation failure before any
  # rollback/cleanup decision. The caller's traps are restored only afterward.
  if [[ "${_wmh_signal_pending}" == Y && "${_wmh_committed}" != Y ]]; then
    _wmh_status=70
    [[ "${_wmh_phase}" != publish ]] || _wmh_publish_retry_state=Y
  fi

  # Reconcile and roll back every precommit publication by inode. A raw ln
  # failure is never treated as proof that no destination link was created.
  if [[ "${_wmh_phase}" == publish && "${_wmh_committed}" != Y &&
        ( ${#_wmh_publish_attempts[@]} -gt 0 ||
          -n "${_wmh_publish_active_leaf}" ||
          "${_wmh_created_destination}" == Y ) ]]; then
    # Keep the scalar action record independent of Bash's array bookkeeping,
    # then reconcile it into the ordered journal without adding duplicates.
    if [[ -n "${_wmh_publish_active_leaf}" ]]; then
      _wmh_publish_active_seen=N
      for _wmh_leaf in "${_wmh_publish_attempts[@]}"; do
        [[ "${_wmh_leaf}" != "${_wmh_publish_active_leaf}" ]] ||
          _wmh_publish_active_seen=Y
      done
      [[ "${_wmh_publish_active_seen}" == Y ]] ||
        _wmh_publish_attempts+=("${_wmh_publish_active_leaf}")
    fi
    _wmh_cleanup_authorized=Y
    for _wmh_path in "${_wmh_root}" "${_wmh_lock}" "${_wmh_stage}" \
        "${_wmh_destination}"; do
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%d\t%i' \
          "${_wmh_path}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%d\t%i' -- \
          "${_wmh_path}" 2>/dev/null)" || {
            _wmh_cleanup_authorized=N
            break
          }
      fi
      IFS=$'\t' builtin read -r _wmh_device _wmh_inode _wmh_extra \
        <<< "${_wmh_metadata}"
      _wmh_live_identity="${_wmh_device}:${_wmh_inode}"
      case "${_wmh_path}" in
        "${_wmh_root}") _wmh_identity="${_wmh_saved_root_identity}" ;;
        "${_wmh_lock}") _wmh_identity="${_wmh_saved_lock_identity}" ;;
        "${_wmh_stage}") _wmh_identity="${_wmh_saved_stage_identity}" ;;
        *) _wmh_identity="${_wmh_publish_destination_identity}" ;;
      esac
      [[ -z "${_wmh_extra}" && "${_wmh_live_identity}" == "${_wmh_identity}" ]] || {
        _wmh_cleanup_authorized=N
        break
      }
    done
    [[ "${_wmh_cleanup_authorized}" == Y ]] || _wmh_cleanup_status=1
    if [[ "${_wmh_cleanup_authorized}" == Y ]]; then
      # All normal post-signal work remains forbidden. Only this already
      # authorized rollback may open descriptors to reauthenticate an exact,
      # action-journaled hard link immediately before removing it.
      _wmh_publish_rollback_active=Y
      for (( _wmh_index=${#_wmh_publish_attempts[@]}-1;
             _wmh_index>=0; _wmh_index-- )); do
        _wmh_leaf="${_wmh_publish_attempts[_wmh_index]}"
        _wmh_path="${_wmh_destination}/${_wmh_leaf}"
        if [[ -f "${_wmh_path}" && ! -L "${_wmh_path}" ]]; then
          if _wmh_metadata="$("${_wmh_tools[stat]}" -f \
              $'%u\t%Lp\t%l\t%z\t%d\t%i' "${_wmh_path}" 2>/dev/null)"; then
            :
          else
            _wmh_metadata="$("${_wmh_tools[stat]}" -c \
              $'%u\t%a\t%h\t%s\t%d\t%i' -- "${_wmh_path}" 2>/dev/null)" ||
              _wmh_cleanup_status=1
          fi
          IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
            _wmh_device _wmh_inode _wmh_extra \
            <<< "${_wmh_metadata}"
          _wmh_mode="${_wmh_mode#0}"
          __guild_cntools_wallet_output_hash_stable "${_wmh_path}" \
            "${_wmh_leaf_identities[${_wmh_leaf}]}" 1 16384 \
            _wmh_live_digest 2 || _wmh_cleanup_status=1
          [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
             "${_wmh_mode}" == 600 && "${_wmh_links}" == 2 &&
             "${_wmh_device}:${_wmh_inode}" == \
               "${_wmh_leaf_identities[${_wmh_leaf}]}" &&
             "${_wmh_live_digest}" == "${_wmh_leaf_digests[${_wmh_leaf}]}" ]] &&
            "${_wmh_tools[rm]}" -f -- "${_wmh_path}" >/dev/null 2>&1 ||
            _wmh_cleanup_status=1
        elif [[ -e "${_wmh_path}" || -L "${_wmh_path}" ]]; then
          _wmh_cleanup_status=1
        fi
      done

      # A successful unlink status is not evidence that rollback completed.
      # Rebind the destination after every attempted removal and require its
      # exact pre-prepare inventory (empty), then prove that every authenticated
      # staged inode is private again. This detects no-op unlink wrappers,
      # path swaps, and a published hard link renamed or moved out of view.
      if (( _wmh_cleanup_status == 0 )); then
        if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%d\t%i' \
            "${_wmh_destination}" 2>/dev/null)"; then
          :
        else
          _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%d\t%i' -- \
            "${_wmh_destination}" 2>/dev/null)" || _wmh_cleanup_status=1
        fi
        if (( _wmh_cleanup_status == 0 )); then
          IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_device \
            _wmh_inode _wmh_extra <<< "${_wmh_metadata}"
          _wmh_mode="${_wmh_mode#0}"
          [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
             "${_wmh_device}:${_wmh_inode}" == \
               "${_wmh_publish_destination_identity}" &&
             ( "${_wmh_mode}" == 700 || "${_wmh_mode}" == 750 ||
               "${_wmh_mode}" == 755 ) ]] || _wmh_cleanup_status=1
        fi
      fi
      if (( _wmh_cleanup_status == 0 )); then
        _wmh_found="$("${_wmh_tools[find]}" "${_wmh_destination}" \
          -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ||
          _wmh_cleanup_status=1
        [[ -z "${_wmh_found}" ]] || _wmh_cleanup_status=1
      fi
      if (( _wmh_cleanup_status == 0 )); then
        for _wmh_leaf in "${_wmh_expected_leaves[@]}"; do
          _wmh_path="${_wmh_stage}/${_wmh_leaf}"
          if _wmh_metadata="$("${_wmh_tools[stat]}" -f \
              $'%u\t%Lp\t%l\t%z\t%d\t%i' "${_wmh_path}" 2>/dev/null)"; then
            :
          else
            _wmh_metadata="$("${_wmh_tools[stat]}" -c \
              $'%u\t%a\t%h\t%s\t%d\t%i' -- "${_wmh_path}" 2>/dev/null)" || {
                _wmh_cleanup_status=1
                break
              }
          fi
          IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links \
            _wmh_size _wmh_device _wmh_inode _wmh_extra \
            <<< "${_wmh_metadata}"
          _wmh_mode="${_wmh_mode#0}"
          [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
             "${_wmh_mode}" == 600 && "${_wmh_links}" == 1 &&
             "${_wmh_size}" =~ ^[1-9][0-9]*$ &&
             "${_wmh_size}" -le 16384 &&
             "${_wmh_device}:${_wmh_inode}" == \
               "${_wmh_leaf_identities[${_wmh_leaf}]}" ]] || {
            _wmh_cleanup_status=1
            break
          }
          __guild_cntools_wallet_output_hash_stable "${_wmh_path}" \
            "${_wmh_leaf_identities[${_wmh_leaf}]}" 1 16384 \
            _wmh_live_digest 1 || {
              _wmh_cleanup_status=1
              break
            }
          [[ "${_wmh_live_digest}" == \
               "${_wmh_leaf_digests[${_wmh_leaf}]}" ]] || {
            _wmh_cleanup_status=1
            break
          }
        done
      fi
      if [[ "${_wmh_created_destination}" == Y &&
            _wmh_cleanup_status -eq 0 ]]; then
        "${_wmh_tools[rmdir]}" -- "${_wmh_destination}" >/dev/null 2>&1 ||
          _wmh_cleanup_status=1
        [[ ! -e "${_wmh_destination}" && ! -L "${_wmh_destination}" ]] ||
          _wmh_cleanup_status=1
      fi
    fi
    _wmh_publish_rollback_active=N
    (( _wmh_cleanup_status == 0 )) || _wmh_status=70
  fi

  # Successful publish and abort both remove only the authenticated, fixed
  # inventory. Prepare/acknowledge failures clean when authority is still exact.
  if [[ ( "${_wmh_phase}" == abort && _wmh_status -eq 0 &&
          "${_wmh_abort_public_reconciled}" == Y ) ||
        ( "${_wmh_phase}" == prepare && _wmh_status -ne 0 ) ||
        ( "${_wmh_phase}" == acknowledge && _wmh_status -ne 0 ) ||
        ( "${_wmh_phase}" == publish &&
          ( "${_wmh_committed}" == Y ||
            ( _wmh_status -ne 0 && _wmh_cleanup_status -eq 0 &&
              "${_wmh_publish_retry_state}" != Y ) ) ) ]]; then
    if [[ "${_wmh_phase}" == abort && -z "${_wmh_state}" ]]; then
      _wmh_status=0
    elif [[ "${_wmh_phase}" == prepare &&
            "${_wmh_created_lock}" != Y ]]; then
      :
    elif [[ ( -d "${_wmh_stage}" && ! -L "${_wmh_stage}" ) ||
            ( "${_wmh_phase}" == abort &&
              "${_wmh_stage_missing}" == Y ) ]]; then
      _wmh_cleanup_authorized=Y
      for _wmh_path in "${_wmh_root}" "${_wmh_lock}" "${_wmh_stage}"; do
        if [[ "${_wmh_path}" == "${_wmh_stage}" &&
              "${_wmh_stage_missing}" == Y ]]; then
          continue
        fi
        if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%d\t%i' \
            "${_wmh_path}" 2>/dev/null)"; then
          :
        else
          _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%d\t%i' -- \
            "${_wmh_path}" 2>/dev/null)" || {
              _wmh_cleanup_authorized=N
              break
            }
        fi
        IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_device _wmh_inode \
          _wmh_extra <<< "${_wmh_metadata}"
        _wmh_mode="${_wmh_mode#0}"
        _wmh_live_identity="${_wmh_device}:${_wmh_inode}"
        case "${_wmh_path}" in
          "${_wmh_root}")
            _wmh_identity="${_wmh_saved_root_identity:-${_wmh_root_identity}}"
            [[ "${_wmh_mode}" == 700 || "${_wmh_mode}" == 750 ||
               "${_wmh_mode}" == 755 ]] || _wmh_cleanup_authorized=N
            ;;
          "${_wmh_lock}")
            _wmh_identity="${_wmh_saved_lock_identity:-${_wmh_lock_identity}}"
            [[ "${_wmh_mode}" == 700 ]] || _wmh_cleanup_authorized=N
            ;;
          *)
            _wmh_identity="${_wmh_saved_stage_identity:-${_wmh_stage_identity}}"
            [[ "${_wmh_mode}" == 700 ]] || _wmh_cleanup_authorized=N
            ;;
        esac
        [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
           "${_wmh_live_identity}" == "${_wmh_identity}" ]] ||
          _wmh_cleanup_authorized=N
        [[ "${_wmh_cleanup_authorized}" == Y ]] || break
      done
      if [[ "${_wmh_cleanup_authorized}" == Y ]]; then
        if [[ "${_wmh_stage_missing}" != Y ]]; then
          for _wmh_leaf in "${_wmh_expected_leaves[@]}"; do
            _wmh_path="${_wmh_stage}/${_wmh_leaf}"
            if [[ -d "${_wmh_path}" && ! -L "${_wmh_path}" ]]; then
              "${_wmh_tools[rmdir]}" -- "${_wmh_path}" \
                >/dev/null 2>&1 || _wmh_cleanup_status=1
            elif [[ -e "${_wmh_path}" || -L "${_wmh_path}" ]]; then
              "${_wmh_tools[rm]}" -f -- "${_wmh_path}" \
                >/dev/null 2>&1 || _wmh_cleanup_status=1
            fi
          done
          if (( _wmh_cleanup_status == 0 )); then
            for _wmh_path in "${_wmh_stage}"/.*.evkey; do
              [[ -e "${_wmh_path}" || -L "${_wmh_path}" ]] || continue
              if [[ -d "${_wmh_path}" && ! -L "${_wmh_path}" ]]; then
                "${_wmh_tools[rmdir]}" -- "${_wmh_path}" \
                  >/dev/null 2>&1 || _wmh_cleanup_status=1
              else
                "${_wmh_tools[rm]}" -f -- "${_wmh_path}" \
                  >/dev/null 2>&1 || _wmh_cleanup_status=1
              fi
            done
          fi
          if (( _wmh_cleanup_status == 0 )); then
            "${_wmh_tools[rmdir]}" -- "${_wmh_stage}" >/dev/null 2>&1 ||
              _wmh_cleanup_status=1
            (( _wmh_cleanup_status != 0 )) || _wmh_stage_missing=Y
          fi
        fi
        # State and inventory remain until every secret-bearing stage leaf and
        # the stage directory are gone, so an abort retry can reauthenticate a
        # partially completed cleanup.
        if (( _wmh_cleanup_status == 0 )); then
          for _wmh_path in "${_wmh_lock}/acknowledged.new" \
              "${_wmh_ack}"; do
            [[ -e "${_wmh_path}" || -L "${_wmh_path}" ]] || continue
            "${_wmh_tools[rm]}" -f -- "${_wmh_path}" >/dev/null 2>&1 ||
              _wmh_cleanup_status=1
          done
        fi
        if (( _wmh_cleanup_status == 0 )); then
          "${_wmh_tools[rm]}" -f -- "${_wmh_lock}/state" \
            "${_wmh_inventory}" "${_wmh_cleanup_marker}" \
            >/dev/null 2>&1 || _wmh_cleanup_status=1
        fi
        if (( _wmh_cleanup_status == 0 )); then
          "${_wmh_tools[rmdir]}" -- "${_wmh_lock}" >/dev/null 2>&1 ||
            _wmh_cleanup_status=1
        fi
      else
        _wmh_cleanup_status=1
      fi
    elif [[ "${_wmh_phase}" == prepare &&
            "${_wmh_created_lock}" == Y && -d "${_wmh_lock}" &&
            ! -L "${_wmh_lock}" ]]; then
      _wmh_cleanup_authorized=Y
      for _wmh_path in "${_wmh_root}" "${_wmh_lock}"; do
        if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%d\t%i' \
            "${_wmh_path}" 2>/dev/null)"; then
          :
        else
          _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%d\t%i' -- \
            "${_wmh_path}" 2>/dev/null)" || {
              _wmh_cleanup_authorized=N
              break
            }
        fi
        IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_device _wmh_inode \
          _wmh_extra <<< "${_wmh_metadata}"
        _wmh_mode="${_wmh_mode#0}"
        _wmh_live_identity="${_wmh_device}:${_wmh_inode}"
        if [[ "${_wmh_path}" == "${_wmh_root}" ]]; then
          _wmh_identity="${_wmh_root_identity}"
          [[ "${_wmh_mode}" == 700 || "${_wmh_mode}" == 750 ||
             "${_wmh_mode}" == 755 ]] || _wmh_cleanup_authorized=N
        else
          _wmh_identity="${_wmh_lock_identity}"
          [[ "${_wmh_mode}" == 700 ]] || _wmh_cleanup_authorized=N
        fi
        [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
           "${_wmh_live_identity}" == "${_wmh_identity}" ]] ||
          _wmh_cleanup_authorized=N
        [[ "${_wmh_cleanup_authorized}" == Y ]] || break
      done
      if [[ "${_wmh_cleanup_authorized}" == Y ]]; then
        for _wmh_path in "${_wmh_inventory}" "${_wmh_ack}" \
            "${_wmh_cleanup_marker}" \
            "${_wmh_lock}/state"; do
          [[ -e "${_wmh_path}" || -L "${_wmh_path}" ]] || continue
          "${_wmh_tools[rm]}" -f -- "${_wmh_path}" >/dev/null 2>&1 ||
            _wmh_cleanup_status=1
        done
        "${_wmh_tools[rmdir]}" -- "${_wmh_lock}" >/dev/null 2>&1 ||
          _wmh_cleanup_status=1
      else
        _wmh_cleanup_status=1
      fi
    elif [[ -e "${_wmh_lock}" || -L "${_wmh_lock}" ]]; then
      _wmh_cleanup_status=1
    fi
    if [[ "${_wmh_committed}" != Y && _wmh_cleanup_status -eq 0 ]]; then
      builtin printf -v "${_wmh_phrase_name}" '%s' ''
      builtin printf -v "${_wmh_state_name}" '%s' ''
    fi
    if (( _wmh_cleanup_status != 0 )); then
      if [[ "${_wmh_committed}" == Y ]]; then
        builtin printf '%s\n' \
          'WARNING: mnemonic wallet committed; private cleanup needs attention.' >&2
      else
        _wmh_status=70
      fi
    fi
  fi

  _wmh_phrase=
  _wmh_root_prv=
  _wmh_hex=
  _wmh_es_key=
  _wmh_auth_helper_program=
  _wmh_capture_worker_program=
  _wmh_xprv=()
  _wmh_xpub=()
  if [[ "${_wmh_auth_defined}" == Y ]]; then
    for _wmh_index in "${!_wmh_fixed_fd_owned[@]}"; do
      __guild_cntools_wallet_fixed_fd_close \
        "${_wmh_fixed_fd_owned[${_wmh_index}]}" ||
        _wmh_fixed_cleanup_bad=Y
    done
    (( ${#_wmh_fixed_fd_owned[@]} == 0 )) || _wmh_fixed_cleanup_bad=Y
    if [[ "${_wmh_fixed_cleanup_bad}" == Y ]]; then
      if [[ "${_wmh_committed}" == Y ]]; then
        builtin printf '%s\n' \
          'WARNING: mnemonic wallet committed; descriptor cleanup needs attention.' >&2
      else
        _wmh_status=70
      fi
    fi
    builtin unset -f __guild_cntools_wallet_output_authenticate \
      __guild_cntools_wallet_fixed_fd_acquire \
      __guild_cntools_wallet_fixed_fd_resolve \
      __guild_cntools_wallet_fixed_fd_close \
      __guild_cntools_wallet_descriptor_authenticate \
      __guild_cntools_wallet_output_open_bound \
      __guild_cntools_wallet_output_hash_bound \
      __guild_cntools_wallet_output_hash_stable \
      __guild_cntools_wallet_output_json_bound \
      __guild_cntools_wallet_output_read_bound \
      __guild_cntools_wallet_output_write_bound \
      __guild_cntools_wallet_input_open_bound \
      __guild_cntools_wallet_input_close_bound \
      __guild_cntools_wallet_capture_bound \
      __guild_cntools_wallet_ccli_capture_bound
  fi

  # Release only the exact lock inode and token created by this invocation.
  # Once authenticated rm succeeds, clear ownership immediately and never
  # inspect the pathname again: a legitimate successor may already own a new
  # lock at the same name.
  if [[ "${_wmh_phase_lock_acquired}" == Y ]]; then
    _wmh_phase_lock_bad=N
    if [[ ! -d "${_wmh_root}" || -L "${_wmh_root}" ]]; then
      _wmh_phase_lock_bad=Y
    elif _wmh_metadata="$("${_wmh_tools[stat]}" -f \
        $'%u\t%Lp\t%d\t%i' "${_wmh_root}" 2>/dev/null)"; then
      :
    else
      _wmh_metadata="$("${_wmh_tools[stat]}" -c \
        $'%u\t%a\t%d\t%i' -- "${_wmh_root}" 2>/dev/null)" ||
        _wmh_phase_lock_bad=Y
    fi
    if [[ "${_wmh_phase_lock_bad}" == N ]]; then
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_device \
        _wmh_inode _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
         ( "${_wmh_mode}" == 700 || "${_wmh_mode}" == 750 ||
           "${_wmh_mode}" == 755 ) &&
         "${_wmh_device}:${_wmh_inode}" == "${_wmh_root_identity}" ]] ||
        _wmh_phase_lock_bad=Y
    fi
    _wmh_phase_lock_first_snapshot=
    for _wmh_phase_lock_iteration in 1 2; do
      [[ "${_wmh_phase_lock_bad}" == N ]] || break
      if [[ ! -f "${_wmh_phase_lock}" || -L "${_wmh_phase_lock}" ]]; then
        _wmh_phase_lock_bad=Y
        break
      elif _wmh_metadata="$("${_wmh_tools[stat]}" -f \
          $'%u\t%Lp\t%l\t%z\t%d\t%i' "${_wmh_phase_lock}" \
          2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c \
          $'%u\t%a\t%h\t%s\t%d\t%i' -- "${_wmh_phase_lock}" \
          2>/dev/null)" || {
            _wmh_phase_lock_bad=Y
            break
          }
      fi
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links \
        _wmh_size _wmh_device _wmh_inode _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      _wmh_phase_lock_snapshot="${_wmh_owner}:${_wmh_mode}:${_wmh_links}:${_wmh_size}:${_wmh_device}:${_wmh_inode}"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
         "${_wmh_mode}" == 600 && "${_wmh_links}" == 1 &&
         "${_wmh_size}" == "$((${#_wmh_phase_lock_token} + 1))" &&
         "${_wmh_device}:${_wmh_inode}" == \
           "${_wmh_phase_lock_identity}" &&
         "${_wmh_device}" == "${_wmh_root_identity%%:*}" ]] || {
        _wmh_phase_lock_bad=Y
        break
      }
      if (( _wmh_phase_lock_iteration == 1 )); then
        _wmh_phase_lock_first_snapshot="${_wmh_phase_lock_snapshot}"
        _wmh_phase_lock_seen_token=
        _wmh_phase_lock_extra=
        _wmh_phase_lock_read_status=0
        _wmh_phase_lock_extra_status=0
        _wmh_phase_lock_open_status=0
        {
          IFS= builtin read -r _wmh_phase_lock_seen_token ||
            _wmh_phase_lock_read_status=$?
          IFS= builtin read -r _wmh_phase_lock_extra ||
            _wmh_phase_lock_extra_status=$?
        } 2>/dev/null < "${_wmh_phase_lock}" ||
          _wmh_phase_lock_open_status=$?
        (( _wmh_phase_lock_read_status == 0 &&
           _wmh_phase_lock_extra_status != 0 &&
           _wmh_phase_lock_open_status == 0 )) &&
        [[ "${_wmh_phase_lock_seen_token}" == \
             "${_wmh_phase_lock_token}" &&
           -z "${_wmh_phase_lock_extra}" ]] || _wmh_phase_lock_bad=Y
      elif [[ "${_wmh_phase_lock_snapshot}" != \
                 "${_wmh_phase_lock_first_snapshot}" ]]; then
        _wmh_phase_lock_bad=Y
      fi
    done
    if [[ "${_wmh_phase_lock_bad}" == N ]]; then
      _wmh_phase_lock_release_in_progress=Y
      if "${_wmh_tools[rm]}" -- "${_wmh_phase_lock}" >/dev/null 2>&1; then
        _wmh_phase_lock_acquired=N
      else
        _wmh_phase_lock_bad=Y
      fi
      _wmh_phase_lock_release_in_progress=N
    fi
    if [[ "${_wmh_phase_lock_bad}" == Y ]]; then
      if [[ "${_wmh_committed}" == Y ]]; then
        builtin printf '%s\n' \
          'WARNING: mnemonic wallet committed; phase lock needs attention.' >&2
      else
        _wmh_status=70
      fi
    fi
  fi

  if [[ "${_wmh_committed}" == Y && "${_wmh_signal_pending}" == Y ]]; then
    builtin printf '%s\n' \
      'WARNING: mnemonic wallet committed after an interrupt.' >&2
  elif [[ "${_wmh_committed}" != Y && "${_wmh_signal_pending}" == Y ]]; then
    _wmh_status=70
  fi
  builtin trap - HUP INT TERM
  [[ -z "${_wmh_saved_hup}" ]] || builtin eval "${_wmh_saved_hup}"
  [[ -z "${_wmh_saved_int}" ]] || builtin eval "${_wmh_saved_int}"
  [[ -z "${_wmh_saved_term}" ]] || builtin eval "${_wmh_saved_term}"
  [[ "${_wmh_trace_was_on}" != Y ]] || set -x
  if [[ "${_wmh_phrase_was_exported}" == Y &&
        -z "${!_wmh_phrase_name}" ]]; then
    builtin export "${_wmh_phrase_name}" || _wmh_status=70
  fi
  if [[ "${_wmh_committed}" == Y ]]; then
    return 0
  fi
  return "${_wmh_status}"
}

# Command     : createMnemonicWallet
# Description : legacy prompt/wait adapter for the shared phase engine
# Return      : populates: ${acct_idx} ${key_idx}
createMnemonicWallet() {
  local mnemonic_compatibility_state="" _wmh_legacy_status=0
  local _wmh_legacy_import=N _wmh_legacy_trace_was_on=N

  # The legacy caller may have xtrace enabled. Disable it before the first
  # mnemonic expansion and restore it only after every secret slot that is not
  # intentionally returned for the generated-phrase display has been cleared.
  if [[ "$-" == *x* ]]; then
    _wmh_legacy_trace_was_on=Y
    set +x
  fi

  [[ -n "${mnemonic:-}" ]] && _wmh_legacy_import=Y
  if ! getCustomDerivationPath; then
    unset mnemonic
    unset words
    [[ "${_wmh_legacy_trace_was_on}" != Y ]] || set -x
    return 1
  fi
  base_addr=
  pay_addr=
  reward_addr=
  _cntools_compatibility_wallet_mnemonic_run prepare \
    mnemonic mnemonic_compatibility_state base_addr pay_addr reward_addr ||
    _wmh_legacy_status=$?
  if (( _wmh_legacy_status == 0 )); then
    IFS=' ' builtin read -r -a words <<< "${mnemonic}"
    _cntools_compatibility_wallet_mnemonic_run acknowledge \
      mnemonic mnemonic_compatibility_state || _wmh_legacy_status=$?
  fi
  if (( _wmh_legacy_status == 0 )); then
    _cntools_compatibility_wallet_mnemonic_run publish \
      mnemonic mnemonic_compatibility_state base_addr pay_addr reward_addr ||
      _wmh_legacy_status=$?
  fi
  if (( _wmh_legacy_status != 0 )); then
    _cntools_compatibility_wallet_mnemonic_run abort \
      mnemonic mnemonic_compatibility_state >/dev/null 2>&1 ||
      _wmh_legacy_status=70
    builtin printf '%s\n' \
      'CNTools mnemonic wallet derivation failed; no wallet was published.' >&2
    unset mnemonic
    unset words
    rmdir -- "${WALLET_FOLDER}/${wallet_name}" >/dev/null 2>&1 || true
    waitToProceed
    [[ "${_wmh_legacy_trace_was_on}" != Y ]] || set -x
    return 1
  fi
  unset mnemonic
  [[ "${_wmh_legacy_import}" != Y ]] || unset words
  [[ "${_wmh_legacy_trace_was_on}" != Y ]] || set -x
  return 0
}
printWalletInfo() {
  println DEBUG "You can now send and receive ADA using the above addresses. Note that Payment Address will not take part in staking"
  println DEBUG "Wallet will be automatically registered on chain if you choose to delegate or pledge wallet when registering a stake pool"
  echo
  println DEBUG "${FG_FG_LBLUE}INFO!${NC} Using a mnemonic or hardware wallet in CNTools comes with a few limitations"
  echo
  println DEBUG "Only the specified address in the HD wallet is extracted and because of this the following apply if used elsewhere:"
  println DEBUG " ${FG_LGRAY}>${NC} If restored wallet balance doesn't match, send all ADA to address shown in CNTools"
  println DEBUG " ${FG_LGRAY}>${NC} Only use receive address shown in CNTools (enable 'Single Address Mode' in wallet if available)"
  echo
  println DEBUG "Some of the advantages of using a mnemonic imported wallet instead of CLI are:"
  println DEBUG " ${FG_LGRAY}>${NC} Wallet can be restored from saved mnemonic/hardware device if keys are lost/deleted"
  println DEBUG " ${FG_LGRAY}>${NC} Wallet can be shared and used in multiple wallets concurrently, including CNTools"
  echo
  println DEBUG "Please read more about HD wallets at:"
  println DEBUG "https://cardano-community.github.io/support-faq/Wallets/wallets/#heirarchical-deterministic-hd-wallets"
}

# Command     : buildOfflineJSON [type]
# Description : construct a json containing all data for offline signing
# Parameters  : type  >  type of transaction, e.g 'payment'
buildOfflineJSON() {
  offlineJSON="{}"
  if ! offlineJSON=$(jq ". += { id: \"$(date +%s)\" }" <<< ${offlineJSON}); then return 1; fi
  if ! offlineJSON=$(jq ". += { type: \"${1}\" }" <<< ${offlineJSON}); then return 1; fi
  if ! offlineJSON=$(jq ". += { \"date-created\": \"$(date --iso-8601=s)\" }" <<< ${offlineJSON}); then return 1; fi
  if ! offlineJSON=$(jq ". += { \"date-expire\": \"$(date --iso-8601=s --date="@$(($(date +%s)+ttl_enter))")\" }" <<< ${offlineJSON}); then return 1; fi
  if ! offlineJSON=$(jq ". += { ttl: \"${ttl}\" }" <<< ${offlineJSON}); then return 1; fi
  if ! offlineJSON=$(jq ". += { \"signing-file\": [] }" <<< ${offlineJSON}); then return 1; fi
  if ! offlineJSON=$(jq ". += { \"script-file\": [] }" <<< ${offlineJSON}); then return 1; fi
  if ! offlineJSON=$(jq ". += { witness: [] }" <<< ${offlineJSON}); then return 1; fi
}

# Command     : registerStakeWallet [wallet name] [optional: skip validation]
# Description : Register stake keys on chain and move funds from payment address to payment base address
# Parameters  : wallet name      >  the name of the wallet
# Parameters  : skip validation  >  [optional] [true|false] if true, skip wallet registration check
registerStakeWallet() {

  wallet_name=$1
  wallet_source="base"

  getWalletType ${wallet_name}
  wallet_type=$?

  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    utxo_cnt=${utxos_cnt[${base_addr}]}
    tx_in=${tx_in_arr[${base_addr}]}
  fi

  if [[ -z $2 || $2 = "false" ]]; then
    println DEBUG "Wallet ${FG_GREEN}${wallet_name}${NC} not registered on chain"
    waitToProceed "press any key to continue with registration"
  fi

  stake_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_CERT_FILENAME}"

  if [[ ${wallet_type} -eq 5 ]]; then
    op_mode=hybrid
    unset required_total
    validateMultiSigScript false "$(cat "${payment_script_file}")"
    witness_cnt=${required_total}
    unset required_totalMore actions
    validateMultiSigScript false "$(cat "${stake_script_file}")"
    witness_cnt=$(( witness_cnt + required_total ))
    stake_param=("--stake-script-file" "${stake_script_file}")
  else
    witness_cnt=2
    stake_param=("--stake-verification-key-file" "${stake_vk_file}")
  fi

  if versionCheck "9.0" "${PROT_VERSION}"; then
    stake_param+=("--key-reg-deposit-amt" ${KEY_DEPOSIT})
  fi

  println ACTION "${CCLI} latest stake-address registration-certificate ${stake_param[*]} --out-file ${stake_cert_file}"
  if ! stdout=$(${CCLI} latest stake-address registration-certificate "${stake_param[@]}" --out-file "${stake_cert_file}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during stake registration certificate creation!\n${stdout}"; return 1
  fi

  if ! getTTL "$([[ ${wallet_type} -eq 5 ]] && echo true)"; then return 1; fi

  println LOG "Key Deposit is ${KEY_DEPOSIT}"

  getAssetsTxOut

  unset script_args
  if [[ ${wallet_type} -eq 5 ]]; then
    script_args=(More actions
      --tx-in-script-file "${payment_script_file}"
      --certificate-script-file "${stake_script_file}"
    )
  fi

  tmpNewBalance=$(( base_lovelace - KEY_DEPOSIT ))
  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${base_addr}+${tmpNewBalance}${assets_tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    --certificate-file "${stake_cert_file}"
    --out-file "${TMP_DIR}"/tx0.tmp
  )

  buildTx || return 1

  calcMinFee "${TMP_DIR}"/tx0.tmp ${utxo_cnt} 1 ${witness_cnt} || return 1

  newBalance=$(( base_lovelace - min_fee - KEY_DEPOSIT ))
  println LOG "New balance after tx fee and key deposit is $(formatLovelace ${newBalance}) ADA ($(formatLovelace ${base_lovelace}) - $(formatLovelace ${min_fee}) - $(formatLovelace ${KEY_DEPOSIT}))"

  if [[ ${base_lovelace} -lt $(( min_fee + KEY_DEPOSIT )) ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA in base address for tx fee and key deposit!"\
			"Funds in address: ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"\
			"Minimum required: ${FG_LBLUE}$(formatLovelace $(( min_fee + KEY_DEPOSIT )))${NC} ADA"
    return 1
  fi

  tx_out="${base_addr}+${newBalance}${assets_tx_out}"
  getMinUTxO "${tx_out}" || return 1
  if [[ ${newBalance} -lt ${min_utxo_out} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: minimum UTxO value not fulfilled, only ${FG_LBLUE}$(formatLovelace ${newBalance})${NC} ADA left in address after tx fee and key deposit, at least ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA required!"
    return 1
  fi

  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${min_fee}
    --certificate-file "${stake_cert_file}"
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${wallet_type} -eq 0 ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Wallet Registration"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txFee: \"$(( min_fee + KEY_DEPOSIT ))\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txBody: $(jq -c . "${TMP_DIR}"/tx.raw) }" <<< ${offlineJSON}); then return 1; fi
    if [[ ${wallet_type} -eq 5 ]]; then
      if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Wallet '${wallet_name}' payment script\", script: $(jq -c . "${payment_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
      if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Wallet '${wallet_name}' stake script\", script: $(jq -c . "${stake_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
    else
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${wallet_name}' payment signing key\", vkey: $(jq -c . "${payment_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${wallet_name}' stake signing key\", vkey: $(jq -c . "${stake_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ". += { \"signed-txBody\": {} }" <<< ${offlineJSON}); then return 1; fi
    offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"
    jq -r . <<< "${offlineJSON}" > "${offline_tx}"
    echo
    if [[ ${wallet_type} -eq 5 ]]; then
      println "MultiSig wallet registration transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "Use CNTools [Transaction >> Sign] to witness the transaction with MultiSig wallet participants."
    else
      println "Offline transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "move file to offline computer and sign it using CNTools in offline mode '-o' [Transaction >> Sign] with:"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${payment_sk_file})${NC}"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${stake_sk_file})${NC}"
    fi
    return 2 # return as failed to stop main processing and return to home menu
  fi

  if ! witnessTx "${TMP_DIR}/tx.raw" "${stake_sk_file}" "${payment_sk_file}"; then return 1; fi
  if ! assembleTx "${TMP_DIR}/tx.raw"; then return 1; fi
  if ! submitTx "${tx_signed}"; then return 1; fi
  echo
  if ! verifyTx ${base_addr}; then return 1; fi
  echo

  reward_lovelace=0
}

# Command     : deregisterStakeWallet
# Description : Deregister stake keys/wallet from chain, key deposit fee returned to wallets base address
deregisterStakeWallet() {

  wallet_source="base"

  getWalletType ${wallet_name}
  wallet_type=$?

  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    utxo_cnt=${utxos_cnt[${base_addr}]}
    tx_in=${tx_in_arr[${base_addr}]}
  fi

  if [[ ${wallet_type} -eq 5 ]]; then
    op_mode=hybrid
    unset required_total
    validateMultiSigScript false "$(cat "${payment_script_file}")"
    witness_cnt=${required_total}
    unset required_total
    validateMultiSigScript false "$(cat "${stake_script_file}")"
    witness_cnt=$(( witness_cnt + required_total ))
    stake_param=("--stake-script-file" "${stake_script_file}")
  else
    witness_cnt=2
    stake_param=("--stake-verification-key-file" "${stake_vk_file}")
  fi

  if versionCheck "9.0" "${PROT_VERSION}"; then
    stake_param+=("--key-reg-deposit-amt" ${stake_deposit})
  fi

  stake_dereg_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_DEREG_FILENAME}"
  println ACTION "${CCLI} latest stake-address deregistration-certificate ${stake_param[*]} --out-file ${stake_dereg_file}"
  if ! stdout=$(${CCLI} latest stake-address deregistration-certificate "${stake_param[@]}" --out-file "${stake_dereg_file}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during stake deregistration certificate creation!\n${stdout}"; return 1
  fi

  if ! getTTL "$([[ ${wallet_type} -eq 5 ]] && echo true)"; then return 1; fi

  println LOG "Key Deposit is ${KEY_DEPOSIT}"

  getAssetsTxOut

  unset script_args
  if [[ ${wallet_type} -eq 5 ]]; then
    script_args=(
      --tx-in-script-file "${payment_script_file}"
      --certificate-script-file "${stake_script_file}"
    )
  fi

  tmpNewBalance=$(( base_lovelace + KEY_DEPOSIT ))
  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${base_addr}+${tmpNewBalance}${assets_tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    --certificate-file "${stake_dereg_file}"
    --out-file "${TMP_DIR}"/tx0.tmp
  )

  buildTx || return 1

  calcMinFee "${TMP_DIR}"/tx0.tmp ${utxo_cnt} 1 ${witness_cnt} || return 1

  newBalance=$(( base_lovelace + KEY_DEPOSIT - min_fee ))
  println LOG "New balance after returned key deposit and subtracted tx fee is $(formatLovelace ${newBalance}) ADA ($(formatLovelace ${base_lovelace}) + $(formatLovelace ${KEY_DEPOSIT}) - $(formatLovelace ${min_fee}))"

  if [[ $(( ${base_lovelace} + KEY_DEPOSIT )) -lt ${min_fee} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA in base address for tx fee!"\
			"Funds in address: ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"\
			"Minimum required: ${FG_LBLUE}$(formatLovelace $(( min_fee - KEY_DEPOSIT )))${NC} ADA"
    return 1
  fi

  tx_out="${base_addr}+${newBalance}${assets_tx_out}"
  getMinUTxO "${tx_out}" || return 1
  if [[ ${newBalance} -lt ${min_utxo_out} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: minimum UTxO value not fulfilled, only ${FG_LBLUE}$(formatLovelace ${newBalance})${NC} ADA left in address after tx fee and returned key deposit, at least ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA required!"
    return 1
  fi

  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${min_fee}
    --certificate-file "${stake_dereg_file}"
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${wallet_type} -eq 0 ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Wallet De-Registration"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"amount-returned\": \"${KEY_DEPOSIT}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txFee: \"${min_fee}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txBody: $(jq -c . "${TMP_DIR}"/tx.raw) }" <<< ${offlineJSON}); then return 1; fi
    if [[ ${wallet_type} -eq 5 ]]; then
      if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Wallet '${wallet_name}' payment script\", script: $(jq -c . "${payment_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
      if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Wallet '${wallet_name}' stake script\", script: $(jq -c . "${stake_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
    else
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${wallet_name}' payment signing key\", vkey: $(jq -c . "${payment_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${wallet_name}' stake signing key\", vkey: $(jq -c . "${stake_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ". += { \"signed-txBody\": {} }" <<< ${offlineJSON}); then return 1; fi
    offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"
    jq -r . <<< "${offlineJSON}" > "${offline_tx}"
    echo
    if [[ ${wallet_type} -eq 5 ]]; then
      println "MultiSig wallet de-registration transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "Use CNTools [Transaction >> Sign] to witness the transaction with MultiSig wallet participants."
    else
      println "Offline transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "move file to offline computer and sign it using CNTools in offline mode '-o' [Transaction >> Sign] with:"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${payment_sk_file})${NC}"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${stake_sk_file})${NC}"
    fi
    return 2 # return as failed to stop main processing and return to home menu
  fi

  if ! witnessTx "${TMP_DIR}/tx.raw" "${stake_sk_file}" "${payment_sk_file}"; then return 1; fi
  if ! assembleTx "${TMP_DIR}/tx.raw"; then return 1; fi
  if ! submitTx "${tx_signed}"; then return 1; fi
}
