#!/usr/bin/env bash
# Guarded wallet state inspection and deletion for Wallet -> Remove.
# Loaded after wallet-query.sh only by the removal action.
# shellcheck disable=SC2034

CNTOOLS_WALLET_REMOVE_ERROR=""
CNTOOLS_WALLET_REMOVE_CHAIN_SOURCE="Not checked"
CNTOOLS_WALLET_REMOVE_DREP_SOURCE="Not applicable"
CNTOOLS_WALLET_REMOVE_UTXO_STATUS="unknown"
CNTOOLS_WALLET_REMOVE_REWARD_STATUS="unknown"
CNTOOLS_WALLET_REMOVE_STAKE_STATUS="unknown"
CNTOOLS_WALLET_REMOVE_DREP_STATUS="not-present"
CNTOOLS_WALLET_REMOVE_DREP_ID=""
CNTOOLS_WALLET_REMOVE_HAS_FUNDS="N"
CNTOOLS_WALLET_REMOVE_STAKE_REGISTERED="N"
CNTOOLS_WALLET_REMOVE_DREP_REGISTERED="N"
CNTOOLS_WALLET_REMOVE_UNKNOWN="N"
CNTOOLS_WALLET_REMOVE_WARNING_COUNT=0
CNTOOLS_WALLET_REMOVE_FILE_COUNT=0

cntools_wallet_remove_log() {
  cntools_log "${1:-INFO}" "${2:-}" || true
}

cntools_wallet_remove_set_error() {
  CNTOOLS_WALLET_REMOVE_ERROR="${1:-Wallet removal failed.}"
  cntools_wallet_remove_log ERROR "${CNTOOLS_WALLET_REMOVE_ERROR}"
}

cntools_wallet_remove_reset() {
  CNTOOLS_WALLET_REMOVE_ERROR=""
  CNTOOLS_WALLET_REMOVE_CHAIN_SOURCE="Not checked"
  CNTOOLS_WALLET_REMOVE_DREP_SOURCE="Not applicable"
  CNTOOLS_WALLET_REMOVE_UTXO_STATUS="unknown"
  CNTOOLS_WALLET_REMOVE_REWARD_STATUS="unknown"
  CNTOOLS_WALLET_REMOVE_STAKE_STATUS="unknown"
  CNTOOLS_WALLET_REMOVE_DREP_STATUS="not-present"
  CNTOOLS_WALLET_REMOVE_DREP_ID=""
  CNTOOLS_WALLET_REMOVE_HAS_FUNDS="N"
  CNTOOLS_WALLET_REMOVE_STAKE_REGISTERED="N"
  CNTOOLS_WALLET_REMOVE_DREP_REGISTERED="N"
  CNTOOLS_WALLET_REMOVE_UNKNOWN="N"
  CNTOOLS_WALLET_REMOVE_WARNING_COUNT=0
  CNTOOLS_WALLET_REMOVE_FILE_COUNT=0
}

cntools_wallet_remove_entry_present() {
  local wallet_directory="${1:-}"
  local filename="${2:-}"
  local candidate="${wallet_directory}/${filename}"

  [[ -n "${wallet_directory}" && -n "${filename}" &&
     ( -e "${candidate}" || -L "${candidate}" ) ]]
}

cntools_wallet_remove_payment_material_present() {
  local wallet_directory="${1:-}"
  local filename=""

  for filename in \
    "${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" \
    "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" \
    "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}.gpg" \
    "${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}" \
    "${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}"; do
    cntools_wallet_remove_entry_present \
      "${wallet_directory}" "${filename}" && return 0
  done
  return 1
}

cntools_wallet_remove_stake_material_present() {
  local wallet_directory="${1:-}"
  local filename=""

  for filename in \
    "${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" \
    "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" \
    "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}.gpg" \
    "${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}" \
    "${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}"; do
    cntools_wallet_remove_entry_present \
      "${wallet_directory}" "${filename}" && return 0
  done
  return 1
}

cntools_wallet_remove_drep_material_present() {
  local wallet_directory="${1:-}"
  local filename=""

  for filename in \
    "${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}" \
    "${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}" \
    "${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}.gpg" \
    "${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}" \
    "${CNTOOLS_WALLET_DREP_ID_FILENAME:-drep.id}" \
    "${CNTOOLS_WALLET_DREP_SCRIPT_FILENAME:-drep.script}" \
    "${CNTOOLS_WALLET_DREP_REGISTER_CERT_FILENAME:-drep-reg.cert}" \
    "${CNTOOLS_WALLET_DREP_RETIRE_CERT_FILENAME:-drep-ret.cert}"; do
    cntools_wallet_remove_entry_present \
      "${wallet_directory}" "${filename}" && return 0
  done
  return 1
}

cntools_wallet_remove_drep_id_valid() {
  [[ "${1:-}" =~ ^drep1[023456789acdefghjklmnpqrstuvwxyz]{51}([023456789acdefghjklmnpqrstuvwxyz]{2})?$ ]]
}

cntools_wallet_remove_read_single_line() {
  local file="${1:-}"
  local output_name="${2:-}"
  local value=""
  local nul_probe=""
  local -a lines=()

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  output_ref=""
  cntools_wallet_safe_regular_file "${file}" 512 || return 1
  if IFS= read -r -d '' nul_probe < "${file}"; then
    return 1
  fi
  mapfile -t lines < "${file}" || return 1
  [[ ${#lines[@]} -eq 1 ]] || return 1
  value="${lines[0]}"
  [[ -n "${value}" && "${value}" != *[[:space:]]* ]] || return 1
  output_ref="${value}"
}

cntools_wallet_remove_read_drep_id() {
  local wallet_directory="${1:-}"
  local output_name="${2:-}"
  local id_file="${wallet_directory}/${CNTOOLS_WALLET_DREP_ID_FILENAME:-drep.id}"
  local cached_id=""

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  output_ref=""
  cntools_wallet_remove_read_single_line "${id_file}" cached_id || return 1
  cntools_wallet_remove_drep_id_valid "${cached_id}" || return 1
  output_ref="${cached_id}"
}

cntools_wallet_remove_derive_drep_id() {
  local wallet_directory="${1:-}"
  local output_name="${2:-}"
  local vkey="${wallet_directory}/${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}"
  local output_file=""
  local error_file=""
  local drep_id=""
  local status=0
  local -a command_args=()

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  output_ref=""
  [[ -n "${CNTOOLS_CLI:-}" && -x "${CNTOOLS_CLI}" ]] || return 1
  cntools_wallet_safe_regular_file "${vkey}" 65536 || return 1
  cntools_wallet_query_temp_file output_file || return 1
  cntools_wallet_query_temp_file error_file || return 1
  command_args=(
    "${CNTOOLS_CLI}" latest governance drep id
    --drep-verification-key-file "${vkey}"
    --out-file "${output_file}"
  )
  if cntools_wallet_query_run_cli \
      "${output_file}" "${error_file}" "${command_args[@]}"; then
    status=0
  else
    status=$?
    cntools_wallet_query_log_failure \
      "DRep ID derivation failed" "${status}" \
      "${error_file}" "${output_file}"
    return "${status}"
  fi
  cntools_wallet_remove_read_single_line "${output_file}" drep_id || return 1
  cntools_wallet_remove_drep_id_valid "${drep_id}" || return 1
  output_ref="${drep_id}"
}

cntools_wallet_remove_resolve_drep_id() {
  local wallet_directory="${1:-}"
  local candidate_id=""

  if cntools_wallet_remove_read_drep_id \
      "${wallet_directory}" candidate_id; then
    CNTOOLS_WALLET_REMOVE_DREP_ID="${candidate_id}"
    return 0
  fi
  if cntools_wallet_remove_entry_present "${wallet_directory}" \
      "${CNTOOLS_WALLET_DREP_ID_FILENAME:-drep.id}"; then
    cntools_wallet_remove_log ERROR \
      "Wallet ${wallet_directory##*/} has an invalid DRep ID file"
  fi
  if cntools_wallet_remove_derive_drep_id \
      "${wallet_directory}" candidate_id; then
    CNTOOLS_WALLET_REMOVE_DREP_ID="${candidate_id}"
    return 0
  fi
  return 1
}

cntools_wallet_remove_query_drep_local() {
  local wallet_directory="${1:-}"
  local vkey="${wallet_directory}/${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}"
  local output_file=""
  local error_file=""
  local status=0
  local -a command_args=()

  [[ "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == "true" &&
     -n "${CNTOOLS_CLI:-}" && -x "${CNTOOLS_CLI}" &&
     -n "${CNTOOLS_SOCKET:-}" ]] || return 1
  cntools_wallet_query_local_socket_ready || return 1
  cntools_wallet_safe_regular_file "${vkey}" 65536 || return 1
  cntools_wallet_query_network_arguments || return 1
  cntools_wallet_query_temp_file output_file || return 1
  cntools_wallet_query_temp_file error_file || return 1
  command_args=(
    "${CNTOOLS_CLI}" latest query drep-state
    --drep-verification-key-file "${vkey}"
    "${CNTOOLS_WALLET_NETWORK_ARGS[@]}"
    --socket-path "${CNTOOLS_SOCKET}"
    --output-json
  )
  if cntools_wallet_query_run_cli \
      "${output_file}" "${error_file}" "${command_args[@]}"; then
    status=0
  else
    status=$?
    cntools_wallet_query_log_failure \
      "Local DRep state query failed" "${status}" \
      "${error_file}" "${output_file}"
    return "${status}"
  fi
  jq -e 'type == "array" and length <= 1' \
    "${output_file}" >/dev/null 2>&1 || {
    cntools_wallet_remove_log ERROR \
      "Local DRep state query returned invalid JSON"
    return 1
  }
  if [[ "$(jq -r 'length' "${output_file}")" == "1" ]]; then
    CNTOOLS_WALLET_REMOVE_DREP_STATUS="registered"
  else
    CNTOOLS_WALLET_REMOVE_DREP_STATUS="not-registered"
  fi
  CNTOOLS_WALLET_REMOVE_DREP_SOURCE="${CNTOOLS_IMPLEMENTATION_NAME:-Local node}"
}

cntools_wallet_remove_query_drep_koios() {
  local drep_id="${1:-}"
  local response_file=""
  local payload=""
  local drep_status=""

  cntools_wallet_remove_drep_id_valid "${drep_id}" || return 2
  [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == "Y" ]] || return 1
  cntools_wallet_query_temp_file response_file || return 1
  payload="$(jq -cn --arg drep_id "${drep_id}" \
    '{_drep_ids: [$drep_id]}')" || return 1
  if ! cntools_wallet_query_http \
      "${CNTOOLS_KOIOS_API%/}/drep_info" \
      "${payload}" "${response_file}"; then
    cntools_wallet_remove_log ERROR "Koios drep_info request failed"
    return 1
  fi
  jq -e '
    type == "array" and length <= 1 and
    all(.[];
      (.drep_id | type == "string" and
        test("^drep1[023456789acdefghjklmnpqrstuvwxyz]{51}([023456789acdefghjklmnpqrstuvwxyz]{2})?$")) and
      (.drep_status == "registered" or
       .drep_status == "deregistered"))
  ' "${response_file}" >/dev/null 2>&1 || {
    cntools_wallet_remove_log ERROR "Koios drep_info returned invalid JSON"
    return 1
  }
  if [[ "$(jq -r 'length' "${response_file}")" == "0" ]]; then
    CNTOOLS_WALLET_REMOVE_DREP_STATUS="not-registered"
  else
    drep_status="$(jq -er '.[0].drep_status' \
      "${response_file}" 2>/dev/null)" || return 1
    if [[ "${drep_status}" == "registered" ]]; then
      CNTOOLS_WALLET_REMOVE_DREP_STATUS="registered"
    else
      CNTOOLS_WALLET_REMOVE_DREP_STATUS="not-registered"
    fi
  fi
  CNTOOLS_WALLET_REMOVE_DREP_SOURCE="Koios API"
}

cntools_wallet_remove_query_drep() {
  local wallet_directory="${1:-}"

  if ! cntools_wallet_remove_drep_material_present "${wallet_directory}"; then
    CNTOOLS_WALLET_REMOVE_DREP_STATUS="not-present"
    CNTOOLS_WALLET_REMOVE_DREP_SOURCE="Not applicable"
    return 0
  fi
  CNTOOLS_WALLET_REMOVE_DREP_STATUS="unknown"
  CNTOOLS_WALLET_REMOVE_DREP_SOURCE="Not checked"
  [[ "${CNTOOLS_MODE:-offline}" != "offline" ]] || return 0

  if [[ "${CNTOOLS_MODE}" == "local" ]] &&
     cntools_wallet_remove_query_drep_local "${wallet_directory}"; then
    return 0
  fi
  if [[ -z "${CNTOOLS_WALLET_REMOVE_DREP_ID}" ]]; then
    cntools_wallet_remove_resolve_drep_id "${wallet_directory}" || return 0
  fi
  cntools_wallet_remove_query_drep_koios \
    "${CNTOOLS_WALLET_REMOVE_DREP_ID}" || return 0
}

cntools_wallet_remove_query_koios_fallback() {
  local base_address="${1:-}"
  local payment_address="${2:-}"
  local reward_address="${3:-}"
  local original_query_status="${CNTOOLS_WALLET_QUERY_STATUS:-unavailable}"
  local original_query_message="${CNTOOLS_WALLET_QUERY_MESSAGE:-}"
  local original_base="${CNTOOLS_WALLET_BASE_LOVELACE:-}"
  local original_payment="${CNTOOLS_WALLET_PAYMENT_LOVELACE:-}"
  local original_total="${CNTOOLS_WALLET_TOTAL_LOVELACE:-}"
  local original_reward="${CNTOOLS_WALLET_REWARD_LOVELACE:-}"
  local original_registered="${CNTOOLS_WALLET_REGISTERED:-unknown}"
  local original_utxos="${CNTOOLS_WALLET_UTXO_COUNT:-}"
  local original_assets="${CNTOOLS_WALLET_ASSET_COUNT:-}"

  [[ "${CNTOOLS_MODE:-}" == "local" &&
     "${CNTOOLS_KOIOS_ENABLED:-N}" == "Y" ]] || return 1
  cntools_wallet_query_reset
  [[ -z "${base_address}" ]] ||
    CNTOOLS_WALLET_FUNDING_EXPECTED=$((CNTOOLS_WALLET_FUNDING_EXPECTED + 1))
  [[ -z "${payment_address}" ]] ||
    CNTOOLS_WALLET_FUNDING_EXPECTED=$((CNTOOLS_WALLET_FUNDING_EXPECTED + 1))
  cntools_wallet_query_koios \
    "${base_address}" "${payment_address}" "${reward_address}"
  cntools_wallet_query_finalize_funding
  if [[ "${CNTOOLS_WALLET_QUERY_STATUS}" == "available" ]]; then
    cntools_wallet_remove_log WALLET \
      "wallet removal safety check used Koios after local query was incomplete"
    return 0
  fi

  CNTOOLS_WALLET_QUERY_STATUS="${original_query_status}"
  CNTOOLS_WALLET_QUERY_MESSAGE="${original_query_message}"
  CNTOOLS_WALLET_BASE_LOVELACE="${original_base}"
  CNTOOLS_WALLET_PAYMENT_LOVELACE="${original_payment}"
  CNTOOLS_WALLET_TOTAL_LOVELACE="${original_total}"
  CNTOOLS_WALLET_REWARD_LOVELACE="${original_reward}"
  CNTOOLS_WALLET_REGISTERED="${original_registered}"
  CNTOOLS_WALLET_UTXO_COUNT="${original_utxos}"
  CNTOOLS_WALLET_ASSET_COUNT="${original_assets}"
  return 1
}

cntools_wallet_remove_evaluate() {
  local wallet_directory="${1:-}"
  local has_funding_address="${2:-N}"
  local has_reward_address="${3:-N}"
  local invalid_address="${4:-N}"
  local payment_material="N"
  local stake_material="N"

  cntools_wallet_remove_payment_material_present "${wallet_directory}" &&
    payment_material="Y"
  cntools_wallet_remove_stake_material_present "${wallet_directory}" &&
    stake_material="Y"

  if [[ "${CNTOOLS_WALLET_TOTAL_LOVELACE:-}" =~ ^[0-9]+$ ]]; then
    if [[ "${CNTOOLS_WALLET_TOTAL_LOVELACE}" =~ ^0+$ ]]; then
      CNTOOLS_WALLET_REMOVE_UTXO_STATUS="empty"
    else
      CNTOOLS_WALLET_REMOVE_UTXO_STATUS="funded"
      CNTOOLS_WALLET_REMOVE_HAS_FUNDS="Y"
    fi
  elif [[ "${has_funding_address}" == "N" &&
          "${payment_material}" == "N" ]]; then
    CNTOOLS_WALLET_REMOVE_UTXO_STATUS="not-present"
  else
    CNTOOLS_WALLET_REMOVE_UTXO_STATUS="unknown"
    CNTOOLS_WALLET_REMOVE_UNKNOWN="Y"
  fi
  if [[ "${CNTOOLS_WALLET_ASSET_COUNT:-}" =~ ^[1-9][0-9]*$ ]]; then
    CNTOOLS_WALLET_REMOVE_HAS_FUNDS="Y"
  fi

  if [[ "${CNTOOLS_WALLET_REWARD_LOVELACE:-}" =~ ^[0-9]+$ ]]; then
    if [[ "${CNTOOLS_WALLET_REWARD_LOVELACE}" =~ ^0+$ ]]; then
      CNTOOLS_WALLET_REMOVE_REWARD_STATUS="empty"
    else
      CNTOOLS_WALLET_REMOVE_REWARD_STATUS="funded"
      CNTOOLS_WALLET_REMOVE_HAS_FUNDS="Y"
    fi
  elif [[ "${has_reward_address}" == "N" && "${stake_material}" == "N" ]]; then
    CNTOOLS_WALLET_REMOVE_REWARD_STATUS="not-present"
  else
    CNTOOLS_WALLET_REMOVE_REWARD_STATUS="unknown"
    CNTOOLS_WALLET_REMOVE_UNKNOWN="Y"
  fi

  case "${CNTOOLS_WALLET_REGISTERED:-unknown}" in
    yes)
      CNTOOLS_WALLET_REMOVE_STAKE_STATUS="registered"
      CNTOOLS_WALLET_REMOVE_STAKE_REGISTERED="Y"
      ;;
    no) CNTOOLS_WALLET_REMOVE_STAKE_STATUS="not-registered" ;;
    *)
      if [[ "${has_reward_address}" == "N" && "${stake_material}" == "N" ]]; then
        CNTOOLS_WALLET_REMOVE_STAKE_STATUS="not-present"
      else
        CNTOOLS_WALLET_REMOVE_STAKE_STATUS="unknown"
        CNTOOLS_WALLET_REMOVE_UNKNOWN="Y"
      fi
      ;;
  esac

  case "${CNTOOLS_WALLET_REMOVE_DREP_STATUS}" in
    registered) CNTOOLS_WALLET_REMOVE_DREP_REGISTERED="Y" ;;
    unknown) CNTOOLS_WALLET_REMOVE_UNKNOWN="Y" ;;
  esac
  [[ "${invalid_address}" == "N" ]] || CNTOOLS_WALLET_REMOVE_UNKNOWN="Y"

  [[ "${CNTOOLS_WALLET_REMOVE_HAS_FUNDS}" == "N" ]] ||
    CNTOOLS_WALLET_REMOVE_WARNING_COUNT=$((CNTOOLS_WALLET_REMOVE_WARNING_COUNT + 1))
  [[ "${CNTOOLS_WALLET_REMOVE_STAKE_REGISTERED}" == "N" ]] ||
    CNTOOLS_WALLET_REMOVE_WARNING_COUNT=$((CNTOOLS_WALLET_REMOVE_WARNING_COUNT + 1))
  [[ "${CNTOOLS_WALLET_REMOVE_DREP_REGISTERED}" == "N" ]] ||
    CNTOOLS_WALLET_REMOVE_WARNING_COUNT=$((CNTOOLS_WALLET_REMOVE_WARNING_COUNT + 1))
  [[ "${CNTOOLS_WALLET_REMOVE_UNKNOWN}" == "N" ]] ||
    CNTOOLS_WALLET_REMOVE_WARNING_COUNT=$((CNTOOLS_WALLET_REMOVE_WARNING_COUNT + 1))
}

cntools_wallet_remove_inspect() {
  local wallet_directory="${1:-}"
  local base_address=""
  local payment_address=""
  local reward_address=""
  local has_funding_address="N"
  local has_reward_address="N"
  local invalid_address="N"
  local status=0

  cntools_wallet_remove_reset
  cntools_wallet_directory_safe "${wallet_directory}" || {
    cntools_wallet_remove_set_error \
      "The selected wallet directory is unavailable or unsafe."
    return 1
  }
  if cntools_wallet_read_address "${wallet_directory}" base base_address; then
    has_funding_address="Y"
  else
    status=$?
    (( status == 1 )) || invalid_address="Y"
  fi
  if cntools_wallet_read_address \
      "${wallet_directory}" payment payment_address; then
    has_funding_address="Y"
  else
    status=$?
    (( status == 1 )) || invalid_address="Y"
  fi
  if cntools_wallet_read_address "${wallet_directory}" reward reward_address; then
    has_reward_address="Y"
  else
    status=$?
    (( status == 1 )) || invalid_address="Y"
  fi

  cntools_wallet_query \
    "${base_address}" "${payment_address}" "${reward_address}"
  if [[ "${CNTOOLS_MODE:-offline}" == "local" &&
        "${CNTOOLS_WALLET_QUERY_STATUS:-unavailable}" != "available" ]]; then
    cntools_wallet_remove_query_koios_fallback \
      "${base_address}" "${payment_address}" "${reward_address}" || true
  fi
  case "${CNTOOLS_MODE:-offline}:${CNTOOLS_WALLET_QUERY_STATUS:-unavailable}" in
    offline:*) CNTOOLS_WALLET_REMOVE_CHAIN_SOURCE="Not checked · offline mode" ;;
    light:available) CNTOOLS_WALLET_REMOVE_CHAIN_SOURCE="Koios API" ;;
    local:available)
      if [[ "${CNTOOLS_WALLET_QUERY_MESSAGE:-}" == "Live data from Koios." ]]; then
        CNTOOLS_WALLET_REMOVE_CHAIN_SOURCE="Koios API · local fallback"
      else
        CNTOOLS_WALLET_REMOVE_CHAIN_SOURCE="${CNTOOLS_IMPLEMENTATION_NAME:-Local node}"
      fi
      ;;
    *) CNTOOLS_WALLET_REMOVE_CHAIN_SOURCE="Incomplete" ;;
  esac

  cntools_wallet_remove_query_drep "${wallet_directory}"
  cntools_wallet_remove_evaluate \
    "${wallet_directory}" "${has_funding_address}" \
    "${has_reward_address}" "${invalid_address}"
  cntools_wallet_remove_log WALLET \
    "removal check wallet=${wallet_directory##*/} utxo=${CNTOOLS_WALLET_REMOVE_UTXO_STATUS} rewards=${CNTOOLS_WALLET_REMOVE_REWARD_STATUS} stake=${CNTOOLS_WALLET_REMOVE_STAKE_STATUS} drep=${CNTOOLS_WALLET_REMOVE_DREP_STATUS} warnings=${CNTOOLS_WALLET_REMOVE_WARNING_COUNT}"
}

cntools_wallet_remove_entries_into() {
  local output_name="${1:-}"
  local wallet_directory="${2:-}"
  local entry=""
  local -a candidates=()

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  output_ref=()
  candidates=(
    "${wallet_directory}"/*
    "${wallet_directory}"/.[!.]*
    "${wallet_directory}"/..?*
  )
  for entry in "${candidates[@]}"; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    output_ref+=("${entry}")
  done
}

cntools_wallet_remove_target_ready() {
  local wallet_directory="${1:-}"
  local entry=""
  local -a entries=()

  cntools_wallet_directory_safe "${wallet_directory}" || {
    cntools_wallet_remove_set_error \
      "The selected wallet directory is no longer safe or accessible."
    return 1
  }
  [[ -O "${CNTOOLS_WALLET_DIR}" && -w "${CNTOOLS_WALLET_DIR}" &&
     -x "${CNTOOLS_WALLET_DIR}" && -O "${wallet_directory}" ]] || {
    cntools_wallet_remove_set_error \
      "The wallet root and selected wallet must be owned and writable by the current user."
    return 1
  }
  cntools_wallet_remove_entries_into entries "${wallet_directory}" || return 1
  for entry in "${entries[@]}"; do
    if [[ -L "${entry}" || ! -f "${entry}" || ! -O "${entry}" ]]; then
      cntools_wallet_remove_set_error \
        "The wallet contains a symbolic link, nested directory, special file, or entry owned by another user: ${entry##*/}."
      return 1
    fi
  done
  CNTOOLS_WALLET_REMOVE_FILE_COUNT="${#entries[@]}"
}

cntools_wallet_remove_unlock_immutable() {
  local wallet_directory="${1:-}"
  local lsattr_command=""
  local chattr_command=""
  local sudo_command=""
  local entry=""
  local attributes=""
  local -a entries=()

  lsattr_command="$(type -P lsattr 2>/dev/null || true)"
  [[ -n "${lsattr_command}" && -x "${lsattr_command}" ]] || return 0
  chattr_command="$(type -P chattr 2>/dev/null || true)"
  sudo_command="$(type -P sudo 2>/dev/null || true)"
  cntools_wallet_remove_entries_into entries "${wallet_directory}" || return 1
  for entry in "${entries[@]}"; do
    [[ -f "${entry}" && ! -L "${entry}" ]] || return 1
    attributes="$(cntools_run_command 0000 -- \
      "${lsattr_command}" -d -- "${entry}" 2>/dev/null || true)"
    attributes="${attributes%% *}"
    [[ "${attributes}" == *i* ]] || continue
    if [[ -n "${chattr_command}" && -x "${chattr_command}" ]] &&
       cntools_run_command 0000 -- \
         "${chattr_command}" -i -- "${entry}" >/dev/null 2>&1; then
      continue
    fi
    if [[ -n "${sudo_command}" && -x "${sudo_command}" &&
          -n "${chattr_command}" && -x "${chattr_command}" ]] &&
       cntools_run_command 000000 -- \
         "${sudo_command}" -n "${chattr_command}" -i -- \
         "${entry}" >/dev/null 2>&1; then
      continue
    fi
    cntools_wallet_remove_set_error \
      "Immutable protection could not be removed from ${entry##*/}."
    return 1
  done
}

cntools_wallet_remove_delete() {
  local wallet_directory="${1:-}"
  local wallet_name="${wallet_directory##*/}"
  local mask=""
  local -a entries=()

  CNTOOLS_WALLET_REMOVE_ERROR=""
  cntools_wallet_remove_target_ready "${wallet_directory}" || return 1
  cntools_wallet_remove_unlock_immutable "${wallet_directory}" || return 1
  cntools_run_command 000 -- chmod u+rwx "${wallet_directory}" \
    >/dev/null 2>&1 || {
    cntools_wallet_remove_set_error \
      "The selected wallet directory could not be made removable."
    return 1
  }
  cntools_wallet_remove_entries_into entries "${wallet_directory}" || return 1
  if (( ${#entries[@]} > 0 )); then
    printf -v mask '%*s' "$((${#entries[@]} + 3))" ''
    mask="${mask// /0}"
    cntools_run_command "${mask}" -- rm -f -- "${entries[@]}" \
      >/dev/null 2>&1 || {
      cntools_wallet_remove_set_error \
        "One or more wallet files could not be removed."
      return 1
    }
  fi
  cntools_run_command 000 -- rmdir -- "${wallet_directory}" \
    >/dev/null 2>&1 || {
    cntools_wallet_remove_set_error \
      "The wallet directory could not be removed safely. An unexpected entry may remain."
    return 1
  }
  [[ ! -e "${wallet_directory}" && ! -L "${wallet_directory}" ]] || {
    cntools_wallet_remove_set_error \
      "The wallet directory still exists after removal."
    return 1
  }
  cntools_wallet_remove_log WALLET \
    "removed wallet=${wallet_name} files=${CNTOOLS_WALLET_REMOVE_FILE_COUNT}"
}
