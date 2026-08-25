# shellcheck shell=bash disable=SC2034,SC2154,SC2206
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
  local _wmh_tool_path="" _wmh_tool_kind="" _wmh_metadata=""
  local _wmh_owner="" _wmh_mode="" _wmh_links="" _wmh_size=""
  local _wmh_device="" _wmh_inode="" _wmh_identity=""
  local _wmh_root="" _wmh_root_identity="" _wmh_destination=""
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
  local _wmh_live_identity="" _wmh_live_digest="" _wmh_output=""
  local _wmh_error="" _wmh_rest="" _wmh_word="" _wmh_count=0
  local _wmh_caddr_version="" _wmh_caddr_arg="" _wmh_root_prv=""
  local _wmh_role="" _wmh_role_path="" _wmh_hex="" _wmh_es_key=""
  local _wmh_command_status=0 _wmh_status=0 _wmh_cleanup_status=0
  local _wmh_original_status=0 _wmh_abort_status=0
  local _wmh_signal_pending=N _wmh_committed=N _wmh_trace_was_on=N
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
  local -A _wmh_seen_names=() _wmh_seen_leaves=() _wmh_tools=()
  local -A _wmh_xprv=() _wmh_xpub=() _wmh_sk_file=() _wmh_vk_file=()
  local -A _wmh_sk_type=() _wmh_vk_type=() _wmh_leaf_digests=()
  local -A _wmh_leaf_identities=() _wmh_leaf_links=()

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
    [[ "${_wmh_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
       -z "${_wmh_seen_names[${_wmh_name}]+set}" ]] || return 64
    _wmh_seen_names["${_wmh_name}"]=Y
  done

  # Empty-state abort is intentionally idempotent and independent of ambient
  # configuration/tool availability. It only clears the caller's phrase slot.
  if [[ "${_wmh_phase}" == abort && -z "${!_wmh_state_name}" ]]; then
    builtin printf -v "${_wmh_phrase_name}" '%s' ''
    builtin printf -v "${_wmh_state_name}" '%s' ''
    return 0
  fi

  # Legacy is only the compatibility adapter: the same phase engine remains
  # the sole implementation.
  if [[ "${_wmh_phase}" == legacy ]]; then
    _cntools_compatibility_wallet_mnemonic_run prepare \
      "${_wmh_phrase_name}" "${_wmh_state_name}" \
      "${_wmh_base_name}" "${_wmh_pay_name}" "${_wmh_reward_name}" ||
      return $?
    _cntools_compatibility_wallet_mnemonic_run acknowledge \
      "${_wmh_phrase_name}" "${_wmh_state_name}" || {
        _wmh_original_status=$?
        _cntools_compatibility_wallet_mnemonic_run abort \
          "${_wmh_phrase_name}" "${_wmh_state_name}" || _wmh_abort_status=$?
        (( _wmh_abort_status == 0 )) || return 70
        return "${_wmh_original_status}"
      }
    _cntools_compatibility_wallet_mnemonic_run publish \
      "${_wmh_phrase_name}" "${_wmh_state_name}" \
      "${_wmh_base_name}" "${_wmh_pay_name}" "${_wmh_reward_name}" ||
      return $?
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

  _wmh_phrase="${!_wmh_phrase_name}"
  _wmh_state="${!_wmh_state_name}"
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
  for _wmh_tool_name in mkdir chmod rm rmdir ln find stat jq; do
    _wmh_tool_path=
    if builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1; then
      _cntools_registry_tool_path "${_wmh_tool_name}" _wmh_tool_path ||
        _wmh_status=70
    else
      _wmh_tool_kind="$(builtin type -t "${_wmh_tool_name}" 2>/dev/null || true)"
      [[ "${_wmh_tool_kind}" != alias && "${_wmh_tool_kind}" != function ]] ||
        _wmh_status=70
      _wmh_tool_path="$(builtin type -P "${_wmh_tool_name}" 2>/dev/null || true)"
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
  elif _wmh_tool_path="$(builtin type -P sha256sum 2>/dev/null)" &&
       [[ "${_wmh_tool_path}" == /* && -f "${_wmh_tool_path}" &&
          -x "${_wmh_tool_path}" && ! -L "${_wmh_tool_path}" ]]; then
    _wmh_tools[hash]="${_wmh_tool_path}"
    _wmh_tools[hash_kind]=sha256sum
  elif _wmh_tool_path="$(builtin type -P shasum 2>/dev/null)" &&
       [[ "${_wmh_tool_path}" == /* && -f "${_wmh_tool_path}" &&
          -x "${_wmh_tool_path}" && ! -L "${_wmh_tool_path}" ]]; then
    _wmh_tools[hash]="${_wmh_tool_path}"
    _wmh_tools[hash_kind]=shasum
  else
    _wmh_status=70
  fi

  # Bind every administrative executable to a safe physical file. Root-owned
  # platform tools may legitimately be hard-linked; operator-owned tools may
  # not be. Group/world-writable or oversized executables are rejected.
  for _wmh_tool_name in mkdir chmod rm rmdir ln find stat jq hash; do
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
  _wmh_destination="${_wmh_root}/${wallet_name:-}"
  _wmh_lock="${_wmh_root}/.${wallet_name:-}.cntools-wallet-mnemonic.lock"
  _wmh_stage="${_wmh_lock}/stage"
  _wmh_inventory="${_wmh_lock}/inventory"
  _wmh_ack="${_wmh_lock}/acknowledged"
  _wmh_cleanup_marker="${_wmh_lock}/cleanup-authority"
  _wmh_output="${_wmh_lock}/command.out"
  _wmh_error="${_wmh_lock}/command.err"

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
    exec 9< "${_wmh_state}" || _wmh_status=70
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
    exec 9<&-
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
    exec 9< "${_wmh_inventory}" || _wmh_status=70
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
    exec 9<&-
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
        if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
          _wmh_live_digest="$("${_wmh_tools[hash]}" "${_wmh_path}" 2>/dev/null)"
        else
          _wmh_live_digest="$("${_wmh_tools[hash]}" -a 256 \
            "${_wmh_path}" 2>/dev/null)"
        fi
        _wmh_live_digest="${_wmh_live_digest%% *}"
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
        if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
          _wmh_live_digest="$("${_wmh_tools[hash]}" "${_wmh_path}" 2>/dev/null)"
        else
          _wmh_live_digest="$("${_wmh_tools[hash]}" -a 256 \
            "${_wmh_path}" 2>/dev/null)"
        fi
        _wmh_live_digest="${_wmh_live_digest%% *}"
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
          if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
            _wmh_live_digest="$("${_wmh_tools[hash]}" "${_wmh_path}" \
              2>/dev/null)"
          else
            _wmh_live_digest="$("${_wmh_tools[hash]}" -a 256 \
              "${_wmh_path}" 2>/dev/null)"
          fi
          _wmh_live_digest="${_wmh_live_digest%% *}"
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
          if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
            _wmh_live_digest="$("${_wmh_tools[hash]}" "${_wmh_path}" \
              2>/dev/null)"
          else
            _wmh_live_digest="$("${_wmh_tools[hash]}" -a 256 \
              "${_wmh_path}" 2>/dev/null)"
          fi
          _wmh_live_digest="${_wmh_live_digest%% *}"
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

  if (( _wmh_status == 0 )) && [[ "${_wmh_phase}" == prepare ]]; then
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

    for _wmh_tool_name in cardano-address bech32; do
      (( _wmh_status == 0 )) || break
      _wmh_tool_path=
      if builtin declare -F _cntools_registry_tool_path >/dev/null 2>&1; then
        _cntools_registry_tool_path "${_wmh_tool_name}" _wmh_tool_path ||
          _wmh_status=70
      else
        _wmh_tool_kind="$(builtin type -t "${_wmh_tool_name}" 2>/dev/null || true)"
        [[ "${_wmh_tool_kind}" != alias && "${_wmh_tool_kind}" != function ]] ||
          _wmh_status=70
        _wmh_tool_path="$(builtin type -P "${_wmh_tool_name}" 2>/dev/null || true)"
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
          _wmh_tool_kind="$(builtin type -t "${CCLI}" 2>/dev/null || true)"
          [[ "${_wmh_tool_kind}" != alias && "${_wmh_tool_kind}" != function ]] ||
            _wmh_status=70
          _wmh_tool_path="$(builtin type -P "${CCLI}" 2>/dev/null || true)"
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

    _wmh_cleanup_files=("${_wmh_output}" "${_wmh_error}")
    if (( _wmh_status == 0 )); then
      : > "${_wmh_output}"
      : > "${_wmh_error}"
      "${_wmh_tools[chmod]}" 0600 "${_wmh_output}" "${_wmh_error}" ||
        _wmh_status=70
    fi
    if (( _wmh_status == 0 )) && [[ -z "${_wmh_phrase}" ]]; then
      if ! (builtin ulimit -f 8 >/dev/null 2>&1 || exit 70
        "${_wmh_tools[cardano-address]}" recovery-phrase generate \
          > "${_wmh_output}" 2> "${_wmh_error}"); then
        _wmh_status=1
      else
        _wmh_phrase="$(< "${_wmh_output}")"
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
      : > "${_wmh_output}"
      if ! (builtin ulimit -f 8 >/dev/null 2>&1 || exit 70
        builtin printf '%s\n' "${_wmh_phrase}" |
          "${_wmh_tools[cardano-address]}" key from-recovery-phrase Shelley \
            > "${_wmh_output}" 2> "${_wmh_error}"); then
        _wmh_status=1
      else
        _wmh_root_prv="$(< "${_wmh_output}")"
        [[ "${#_wmh_root_prv}" -ge 20 && "${#_wmh_root_prv}" -le 2048 &&
           "${_wmh_root_prv}" =~ ^[A-Za-z0-9_]+$ ]] || _wmh_status=70
      fi
    fi
    if (( _wmh_status == 0 )); then
      : > "${_wmh_output}"
      if ! (builtin ulimit -f 8 >/dev/null 2>&1 || exit 70
        "${_wmh_tools[cardano-address]}" -v \
          > "${_wmh_output}" 2> "${_wmh_error}"); then
        _wmh_status=1
      else
        _wmh_caddr_version="$(< "${_wmh_output}")"
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
      : > "${_wmh_output}"
      if ! (builtin ulimit -f 8 >/dev/null 2>&1 || exit 70
        builtin printf '%s\n' "${_wmh_root_prv}" |
          "${_wmh_tools[cardano-address]}" key child "${_wmh_role_path}" \
            > "${_wmh_output}" 2> "${_wmh_error}"); then
        _wmh_status=1
        break
      fi
      _wmh_xprv["${_wmh_role}"]="$(< "${_wmh_output}")"
      [[ "${#_wmh_xprv[${_wmh_role}]}" -ge 20 &&
         "${#_wmh_xprv[${_wmh_role}]}" -le 2048 &&
         "${_wmh_xprv[${_wmh_role}]}" =~ ^[A-Za-z0-9_]+$ ]] ||
        _wmh_status=70
      (( _wmh_status == 0 )) || break
      : > "${_wmh_output}"
      if [[ -n "${_wmh_caddr_arg}" ]]; then
        (builtin ulimit -f 8 >/dev/null 2>&1 || exit 70
          builtin printf '%s\n' "${_wmh_xprv[${_wmh_role}]}" |
            "${_wmh_tools[cardano-address]}" key public "${_wmh_caddr_arg}" \
              > "${_wmh_output}" 2> "${_wmh_error}") ||
          _wmh_status=1
      else
        (builtin ulimit -f 8 >/dev/null 2>&1 || exit 70
          builtin printf '%s\n' "${_wmh_xprv[${_wmh_role}]}" |
            "${_wmh_tools[cardano-address]}" key public \
              > "${_wmh_output}" 2> "${_wmh_error}") ||
          _wmh_status=1
      fi
      (( _wmh_status == 0 )) || break
      _wmh_xpub["${_wmh_role}"]="$(< "${_wmh_output}")"
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

    for _wmh_role in "${_wmh_roles[@]}"; do
      (( _wmh_status == 0 )) || break
      : > "${_wmh_output}"
      if ! (builtin ulimit -f 8 >/dev/null 2>&1 || exit 70
        builtin printf '%s\n' "${_wmh_xprv[${_wmh_role}]}" |
          "${_wmh_tools[bech32]}" > "${_wmh_output}" 2> "${_wmh_error}"); then
        _wmh_status=1
        break
      fi
      _wmh_hex="$(< "${_wmh_output}")"
      [[ "${_wmh_hex}" =~ ^[0-9A-Fa-f]+$ &&
         ${#_wmh_hex} -ge 128 && ${#_wmh_hex} -le 4096 ]] || {
        _wmh_status=70
        break
      }
      _wmh_es_key="${_wmh_hex:0:128}"
      _wmh_hex=
      : > "${_wmh_output}"
      if ! (builtin ulimit -f 8 >/dev/null 2>&1 || exit 70
        builtin printf '%s\n' "${_wmh_xpub[${_wmh_role}]}" |
          "${_wmh_tools[bech32]}" > "${_wmh_output}" 2> "${_wmh_error}"); then
        _wmh_status=1
        break
      fi
      _wmh_hex="$(< "${_wmh_output}")"
      [[ "${_wmh_hex}" =~ ^[0-9A-Fa-f]{128}$ ]] || {
        _wmh_status=70
        break
      }
      _wmh_es_key="${_wmh_es_key}${_wmh_hex}"
      _wmh_path="${_wmh_sk_file[${_wmh_role}]}"
      : > "${_wmh_path}"
      "${_wmh_tools[chmod]}" 0600 "${_wmh_path}" || {
        _wmh_status=70
        break
      }
      builtin printf '{\n  "type": "%s",\n  "description": "CNTools mnemonic signing key",\n  "cborHex": "5880%s"\n}\n' \
        "${_wmh_sk_type[${_wmh_role}]}" "${_wmh_es_key,,}" > "${_wmh_path}"
      _wmh_xprv["${_wmh_role}"]=
      _wmh_xpub["${_wmh_role}"]=
      _wmh_es_key=
      _wmh_hex=
    done

    for _wmh_role in "${_wmh_roles[@]}"; do
      (( _wmh_status == 0 )) || break
      _wmh_path="${_wmh_stage}/.${_wmh_role}.evkey"
      : > "${_wmh_path}"
      "${_wmh_tools[chmod]}" 0600 "${_wmh_path}" || {
        _wmh_status=70
        break
      }
      _wmh_cleanup_files+=("${_wmh_path}")
      case "${_wmh_role}" in
        payment|stake|ms_payment|ms_stake)
          (builtin ulimit -f 32 >/dev/null 2>&1 || exit 70
            "${_wmh_tools[ccli]}" key verification-key \
              --signing-key-file "${_wmh_sk_file[${_wmh_role}]}" \
              --verification-key-file "${_wmh_path}" \
              2> "${_wmh_error}") || _wmh_status=1
          ;;
        *)
          (builtin ulimit -f 32 >/dev/null 2>&1 || exit 70
            "${_wmh_tools[ccli]}" latest key verification-key \
              --signing-key-file "${_wmh_sk_file[${_wmh_role}]}" \
              --verification-key-file "${_wmh_path}" \
              2> "${_wmh_error}") || _wmh_status=1
          ;;
      esac
      (( _wmh_status == 0 )) || break
      : > "${_wmh_vk_file[${_wmh_role}]}"
      "${_wmh_tools[chmod]}" 0600 "${_wmh_vk_file[${_wmh_role}]}" || {
        _wmh_status=70
        break
      }
      case "${_wmh_role}" in
        payment|stake|ms_payment|ms_stake)
          (builtin ulimit -f 32 >/dev/null 2>&1 || exit 70
            "${_wmh_tools[ccli]}" key non-extended-key \
              --extended-verification-key-file "${_wmh_path}" \
              --verification-key-file "${_wmh_vk_file[${_wmh_role}]}" \
              2> "${_wmh_error}") || _wmh_status=1
          ;;
        *)
          (builtin ulimit -f 32 >/dev/null 2>&1 || exit 70
            "${_wmh_tools[ccli]}" latest key non-extended-key \
              --extended-verification-key-file "${_wmh_path}" \
              --verification-key-file "${_wmh_vk_file[${_wmh_role}]}" \
              2> "${_wmh_error}") || _wmh_status=1
          ;;
      esac
      (( _wmh_status == 0 )) || break
      "${_wmh_tools[rm]}" -f -- "${_wmh_path}" >/dev/null 2>&1 ||
        _wmh_status=70
    done

    # Derivation marker, addresses, and credentials complete the exact wallet
    # inventory. All untrusted command output is private and bounded.
    if (( _wmh_status == 0 )); then
      _wmh_path="${_wmh_stage}/${WALLET_DERIVATION_PATH_FILENAME:-}"
      builtin printf '1852H/1815H/%sH/x/%s\n' "${acct_idx}" "${key_idx}" \
        > "${_wmh_path}"
      "${_wmh_tools[chmod]}" 0600 "${_wmh_path}" || _wmh_status=70
    fi
    if (( _wmh_status == 0 )); then
      _wmh_path="${_wmh_stage}/${WALLET_BASE_ADDR_FILENAME:-}"
      : > "${_wmh_path}"; "${_wmh_tools[chmod]}" 0600 "${_wmh_path}" ||
        _wmh_status=70
      (builtin ulimit -f 8 >/dev/null 2>&1 || exit 70
        "${_wmh_tools[ccli]}" address build \
          --payment-verification-key-file "${_wmh_vk_file[payment]}" \
          --stake-verification-key-file "${_wmh_vk_file[stake]}" \
          "${_wmh_network_args[@]}" > "${_wmh_path}" 2> "${_wmh_error}") ||
        _wmh_status=1
    fi
    if (( _wmh_status == 0 )); then
      _wmh_path="${_wmh_stage}/${WALLET_PAY_ADDR_FILENAME:-}"
      : > "${_wmh_path}"; "${_wmh_tools[chmod]}" 0600 "${_wmh_path}" ||
        _wmh_status=70
      (builtin ulimit -f 8 >/dev/null 2>&1 || exit 70
        "${_wmh_tools[ccli]}" address build \
          --payment-verification-key-file "${_wmh_vk_file[payment]}" \
          "${_wmh_network_args[@]}" > "${_wmh_path}" 2> "${_wmh_error}") ||
        _wmh_status=1
    fi
    if (( _wmh_status == 0 )); then
      _wmh_path="${_wmh_stage}/${WALLET_STAKE_ADDR_FILENAME:-}"
      : > "${_wmh_path}"; "${_wmh_tools[chmod]}" 0600 "${_wmh_path}" ||
        _wmh_status=70
      (builtin ulimit -f 8 >/dev/null 2>&1 || exit 70
        "${_wmh_tools[ccli]}" stake-address build \
          --stake-verification-key-file "${_wmh_vk_file[stake]}" \
          "${_wmh_network_args[@]}" > "${_wmh_path}" 2> "${_wmh_error}") ||
        _wmh_status=1
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
        : > "${_wmh_path}"; "${_wmh_tools[chmod]}" 0600 "${_wmh_path}" ||
          _wmh_status=70
        (( _wmh_status == 0 )) || break
        (builtin ulimit -f 8 >/dev/null 2>&1 || exit 70
          "${_wmh_tools[ccli]}" "${_wmh_tool_name}" key-hash \
            "${_wmh_value}" "${_wmh_vk_file[${_wmh_role}]}" \
            > "${_wmh_path}" 2> "${_wmh_error}") || _wmh_status=1
        (( _wmh_status == 0 )) || break
      done
    fi

    # Validate schema, terminal-safe addresses and exact file inventory.
    for _wmh_role in "${_wmh_roles[@]}"; do
      (( _wmh_status == 0 )) || break
      "${_wmh_tools[jq]}" -e --arg t "${_wmh_sk_type[${_wmh_role}]}" '
        type == "object" and
        keys == ["cborHex","description","type"] and .type == $t and
        (.description | type == "string" and length <= 128) and
        (.cborHex | type == "string" and
          test("^5880[0-9a-f]{256}$"))
      ' "${_wmh_sk_file[${_wmh_role}]}" >/dev/null 2> "${_wmh_error}" ||
        _wmh_status=70
      (( _wmh_status == 0 )) || break
      "${_wmh_tools[jq]}" -e --arg t "${_wmh_vk_type[${_wmh_role}]}" '
        type == "object" and
        keys == ["cborHex","description","type"] and .type == $t and
        (.description | type == "string" and length <= 128) and
        (.cborHex | type == "string" and
          test("^[0-9a-fA-F]{64,1024}$"))
      ' "${_wmh_vk_file[${_wmh_role}]}" >/dev/null 2> "${_wmh_error}" ||
        _wmh_status=70
    done
    if (( _wmh_status == 0 )); then
      _wmh_value="$(< "${_wmh_stage}/${WALLET_BASE_ADDR_FILENAME}")"
      if [[ "${_wmh_network_kind}" == mainnet ]]; then
        [[ "${_wmh_value}" =~ ^addr1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      else
        [[ "${_wmh_value}" =~ ^addr_test1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      fi
      _wmh_value="$(< "${_wmh_stage}/${WALLET_PAY_ADDR_FILENAME}")"
      if [[ "${_wmh_network_kind}" == mainnet ]]; then
        [[ "${_wmh_value}" =~ ^addr1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      else
        [[ "${_wmh_value}" =~ ^addr_test1[023456789ac-hj-np-z]{20,200}$ ]] ||
          _wmh_status=70
      fi
      _wmh_value="$(< "${_wmh_stage}/${WALLET_STAKE_ADDR_FILENAME}")"
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
        _wmh_value="$(< "${_wmh_stage}/${_wmh_leaf}")"
        [[ "${_wmh_value}" =~ ^[0-9A-Fa-f]{56}$ ]] || _wmh_status=70
      done
    fi
    if (( _wmh_status == 0 )); then
      _wmh_found="$("${_wmh_tools[find]}" "${_wmh_stage}" -mindepth 1 \
        -maxdepth 1 -print 2> "${_wmh_error}")" || _wmh_status=70
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
        "${_wmh_tools[chmod]}" 0600 "${_wmh_path}" || {
          _wmh_status=70
          break
        }
        if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
          _wmh_digest="$("${_wmh_tools[hash]}" "${_wmh_path}" 2>/dev/null)"
        else
          _wmh_digest="$("${_wmh_tools[hash]}" -a 256 "${_wmh_path}" 2>/dev/null)"
        fi
        _wmh_digest="${_wmh_digest%% *}"
        [[ "${_wmh_digest}" =~ ^[0-9a-f]{64}$ ]] || {
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
      "${_wmh_tools[rm]}" -f -- "${_wmh_output}" "${_wmh_error}" \
        >/dev/null 2>&1 || _wmh_status=70
    fi
    if (( _wmh_status == 0 )); then
      builtin printf -v "${_wmh_phrase_name}" '%s' "${_wmh_phrase}"
      builtin printf -v "${_wmh_state_name}" '%s' "${_wmh_state}"
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
      if _wmh_metadata="$("${_wmh_tools[stat]}" -f $'%u\t%Lp\t%l\t%z\t%d\t%i' \
          "${_wmh_path}" 2>/dev/null)"; then
        :
      else
        _wmh_metadata="$("${_wmh_tools[stat]}" -c $'%u\t%a\t%h\t%s\t%d\t%i' -- \
          "${_wmh_path}" 2>/dev/null)" || {
            _wmh_status=70
            break
          }
      fi
      IFS=$'\t' builtin read -r _wmh_owner _wmh_mode _wmh_links _wmh_size \
        _wmh_device _wmh_inode _wmh_extra <<< "${_wmh_metadata}"
      _wmh_mode="${_wmh_mode#0}"
      [[ -z "${_wmh_extra}" && "${_wmh_owner}" == "${EUID}" &&
         "${_wmh_mode}" == 600 && "${_wmh_links}" == 1 &&
         "${_wmh_size}" =~ ^[1-9][0-9]*$ && "${_wmh_size}" -le 16384 ]] ||
        _wmh_status=70
      if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
        _wmh_live_digest="$("${_wmh_tools[hash]}" "${_wmh_path}" 2>/dev/null)"
      else
        _wmh_live_digest="$("${_wmh_tools[hash]}" -a 256 \
          "${_wmh_path}" 2>/dev/null)"
      fi
      _wmh_live_digest="${_wmh_live_digest%% *}"
      [[ "${_wmh_live_digest}" == "${_wmh_leaf_digests[${_wmh_leaf}]}" ]] ||
        _wmh_status=70
      _wmh_leaf_identities["${_wmh_leaf}"]="${_wmh_device}:${_wmh_inode}"
    done
    if (( _wmh_status == 0 )); then
      _wmh_publish_base="$(< "${_wmh_stage}/${WALLET_BASE_ADDR_FILENAME}")"
      _wmh_publish_pay="$(< "${_wmh_stage}/${WALLET_PAY_ADDR_FILENAME}")"
      _wmh_publish_reward="$(< "${_wmh_stage}/${WALLET_STAKE_ADDR_FILENAME}")"
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
      # Record the candidate before invoking ln. The command may create the
      # hard link and still return nonzero, or a later verification may fail.
      # Every candidate is therefore reconciled during precommit rollback.
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
        if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
          _wmh_live_digest="$("${_wmh_tools[hash]}" "${_wmh_path}" 2>/dev/null)"
        else
          _wmh_live_digest="$("${_wmh_tools[hash]}" -a 256 \
            "${_wmh_path}" 2>/dev/null)"
        fi
        _wmh_live_digest="${_wmh_live_digest%% *}"
        [[ "${_wmh_live_digest}" == "${_wmh_leaf_digests[${_wmh_leaf}]}" ]] ||
          _wmh_status=70
      else
        (( _wmh_command_status == 0 )) && _wmh_status=70 || _wmh_status=1
      fi
      (( _wmh_status == 0 )) || break
      [[ "${_wmh_signal_pending}" == N ]] || _wmh_status=70
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
      if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
        _wmh_live_digest="$("${_wmh_tools[hash]}" "${_wmh_path}" 2>/dev/null)"
      else
        _wmh_live_digest="$("${_wmh_tools[hash]}" -a 256 \
          "${_wmh_path}" 2>/dev/null)"
      fi
      _wmh_live_digest="${_wmh_live_digest%% *}"
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
  fi

  # Reconcile and roll back every precommit publication by inode. A raw ln
  # failure is never treated as proof that no destination link was created.
  if [[ "${_wmh_phase}" == publish && "${_wmh_committed}" != Y &&
        ( ${#_wmh_publish_attempts[@]} -gt 0 ||
          "${_wmh_created_destination}" == Y ) ]]; then
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
          if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
            _wmh_live_digest="$("${_wmh_tools[hash]}" "${_wmh_path}" 2>/dev/null)"
          else
            _wmh_live_digest="$("${_wmh_tools[hash]}" -a 256 \
              "${_wmh_path}" 2>/dev/null)"
          fi
          _wmh_live_digest="${_wmh_live_digest%% *}"
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
          if [[ "${_wmh_tools[hash_kind]}" == sha256sum ]]; then
            _wmh_live_digest="$("${_wmh_tools[hash]}" "${_wmh_path}" \
              2>/dev/null)"
          else
            _wmh_live_digest="$("${_wmh_tools[hash]}" -a 256 \
              "${_wmh_path}" 2>/dev/null)"
          fi
          _wmh_live_digest="${_wmh_live_digest%% *}"
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
            ( _wmh_status -ne 0 && _wmh_cleanup_status -eq 0 ) ) ) ]]; then
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
            if [[ -e "${_wmh_stage}/${_wmh_leaf}" ||
                  -L "${_wmh_stage}/${_wmh_leaf}" ]]; then
              "${_wmh_tools[rm]}" -f -- "${_wmh_stage}/${_wmh_leaf}" \
                >/dev/null 2>&1 || _wmh_cleanup_status=1
            fi
          done
          if (( _wmh_cleanup_status == 0 )); then
            for _wmh_path in "${_wmh_stage}"/.*.evkey; do
              [[ -e "${_wmh_path}" || -L "${_wmh_path}" ]] || continue
              "${_wmh_tools[rm]}" -f -- "${_wmh_path}" >/dev/null 2>&1 ||
                _wmh_cleanup_status=1
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
          for _wmh_path in "${_wmh_output}" "${_wmh_error}" \
              "${_wmh_lock}/acknowledged.new" "${_wmh_ack}"; do
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
        for _wmh_path in "${_wmh_output}" "${_wmh_error}" \
            "${_wmh_inventory}" "${_wmh_ack}" "${_wmh_cleanup_marker}" \
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

  if [[ "${_wmh_committed}" == Y && "${_wmh_signal_pending}" == Y ]]; then
    builtin printf '%s\n' \
      'WARNING: mnemonic wallet committed after an interrupt.' >&2
  elif [[ "${_wmh_committed}" != Y && "${_wmh_signal_pending}" == Y ]]; then
    _wmh_status=70
  fi

  _wmh_phrase=
  _wmh_root_prv=
  _wmh_hex=
  _wmh_es_key=
  _wmh_xprv=()
  _wmh_xpub=()
  builtin trap - HUP INT TERM
  [[ -z "${_wmh_saved_hup}" ]] || builtin eval "${_wmh_saved_hup}"
  [[ -z "${_wmh_saved_int}" ]] || builtin eval "${_wmh_saved_int}"
  [[ -z "${_wmh_saved_term}" ]] || builtin eval "${_wmh_saved_term}"
  [[ "${_wmh_trace_was_on}" != Y ]] || set -x
  if [[ "${_wmh_committed}" == Y ]]; then
    return 0
  fi
  return "${_wmh_status}"
}

# Command     : createMnemonicWallet
# Description : legacy prompt/wait adapter for the shared phase engine
# Return      : populates: ${acct_idx} ${key_idx}
createMnemonicWallet() {
  local _wmh_legacy_state="" _wmh_legacy_status=0
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
    mnemonic _wmh_legacy_state base_addr pay_addr reward_addr ||
    _wmh_legacy_status=$?
  if (( _wmh_legacy_status == 0 )); then
    IFS=' ' builtin read -r -a words <<< "${mnemonic}"
    _cntools_compatibility_wallet_mnemonic_run acknowledge \
      mnemonic _wmh_legacy_state || _wmh_legacy_status=$?
  fi
  if (( _wmh_legacy_status == 0 )); then
    _cntools_compatibility_wallet_mnemonic_run publish \
      mnemonic _wmh_legacy_state base_addr pay_addr reward_addr ||
      _wmh_legacy_status=$?
  fi
  if (( _wmh_legacy_status != 0 )); then
    _cntools_compatibility_wallet_mnemonic_run abort \
      mnemonic _wmh_legacy_state >/dev/null 2>&1 || _wmh_legacy_status=70
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
