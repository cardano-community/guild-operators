#!/usr/bin/env bash
# Safe missing-only materialization of public wallet artifacts. Loaded after
# lib/wallet.sh and before the focused key, address, and identifier helpers.
# shellcheck disable=SC2034

declare -ag CNTOOLS_WALLET_MATERIAL_TEMP_FILES=()

cntools_wallet_material_log() {
  cntools_log "${1:-INFO}" "${2:-}" || true
}

cntools_wallet_material_entry_exists() {
  [[ -e "${1:-}" || -L "${1:-}" ]]
}

cntools_wallet_material_existing_valid() {
  local target_file="${1:-}"
  local validator="${2:-}"
  local target_name="${target_file##*/}"

  shift 2 2>/dev/null || return 2
  cntools_wallet_material_entry_exists "${target_file}" || return 1
  [[ "${validator}" =~ ^cntools_wallet_[A-Za-z0-9_]+_validate$ ]] ||
    return 2
  declare -F "${validator}" >/dev/null 2>&1 || return 2
  if "${validator}" "${target_file}" "$@"; then
    return 0
  fi
  cntools_wallet_material_log ERROR \
    "Existing wallet artifact is unsafe or invalid; retained ${target_name}"
  return 2
}

cntools_wallet_material_untrack() {
  local tracked_file="${1:-}"
  local candidate=""
  local -a remaining=()

  for candidate in "${CNTOOLS_WALLET_MATERIAL_TEMP_FILES[@]}"; do
    [[ "${candidate}" == "${tracked_file}" ]] || remaining+=("${candidate}")
  done
  CNTOOLS_WALLET_MATERIAL_TEMP_FILES=("${remaining[@]}")
}

cntools_wallet_material_remove_temp() {
  local temporary_file="${1:-}"
  local tracked="N"
  local candidate=""

  for candidate in "${CNTOOLS_WALLET_MATERIAL_TEMP_FILES[@]}"; do
    if [[ "${candidate}" == "${temporary_file}" ]]; then
      tracked="Y"
      break
    fi
  done
  [[ "${tracked}" == "Y" ]] || return 2
  if [[ -f "${temporary_file}" && ! -L "${temporary_file}" &&
        -O "${temporary_file}" ]]; then
    rm -f -- "${temporary_file}" 2>/dev/null || true
  fi
  cntools_wallet_material_untrack "${temporary_file}"
}

cntools_wallet_material_cleanup() {
  local temporary_file=""

  for temporary_file in "${CNTOOLS_WALLET_MATERIAL_TEMP_FILES[@]}"; do
    cntools_wallet_material_remove_temp "${temporary_file}" || true
  done
  CNTOOLS_WALLET_MATERIAL_TEMP_FILES=()
}

cntools_wallet_material_temp_file() {
  local _cntools_output_name="${1:-}"
  local _cntools_wallet_directory="${2:-}"
  local _cntools_label="${3:-artifact}"
  local _cntools_previous_umask=""
  local _cntools_temporary_file=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_label}" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_directory_safe "${_cntools_wallet_directory}" || return 1
  [[ -O "${_cntools_wallet_directory}" &&
     -w "${_cntools_wallet_directory}" ]] || return 1

  _cntools_previous_umask="$(umask)"
  umask 077
  _cntools_temporary_file="$(
    mktemp "${_cntools_wallet_directory}/.cntools-${_cntools_label}.XXXXXX"
  )" || {
    umask "${_cntools_previous_umask}"
    return 1
  }
  umask "${_cntools_previous_umask}"
  [[ -f "${_cntools_temporary_file}" &&
     ! -L "${_cntools_temporary_file}" &&
     -O "${_cntools_temporary_file}" ]] || {
    rm -f -- "${_cntools_temporary_file}" 2>/dev/null || true
    return 1
  }
  chmod 0600 "${_cntools_temporary_file}" || {
    rm -f -- "${_cntools_temporary_file}" 2>/dev/null || true
    return 1
  }
  CNTOOLS_WALLET_MATERIAL_TEMP_FILES+=("${_cntools_temporary_file}")
  _cntools_output_ref="${_cntools_temporary_file}"
}

cntools_wallet_material_run_cli() {
  local error_file="${1:-}"
  local mask=""

  shift || return 2
  [[ "${1:-}" == "--" ]] || return 2
  shift
  (( $# > 0 )) || return 2
  [[ -n "${CNTOOLS_CLI:-}" && "${CNTOOLS_CLI}" = /* &&
     -x "${CNTOOLS_CLI}" && ! -d "${CNTOOLS_CLI}" &&
     -f "${error_file}" && ! -L "${error_file}" &&
     -O "${error_file}" ]] || return 2
  printf -v mask '%*s' "$#" ''
  mask="${mask// /0}"
  cntools_run_command_timeout "${CNTOOLS_CLI_TIMEOUT:-10}" \
    "${mask}" -- "$@" >/dev/null 2> "${error_file}"
}

cntools_wallet_material_log_cli_failure() {
  local context="${1:-Wallet artifact generation failed}"
  local status="${2:-1}"
  local error_file="${3:-}"
  local detail=""

  if [[ "${status}" == "124" ]]; then
    detail="timed out after ${CNTOOLS_CLI_TIMEOUT:-10} seconds"
  elif [[ -f "${error_file}" && ! -L "${error_file}" ]]; then
    IFS= read -r detail < "${error_file}" || true
    detail="${detail:0:400}"
    if declare -F cntools_log_sanitize_line >/dev/null 2>&1; then
      detail="$(cntools_log_sanitize_line "${detail}")"
    fi
  fi
  cntools_wallet_material_log ERROR \
    "${context} status=${status}${detail:+: ${detail}}"
}

cntools_wallet_material_publish() {
  local staged_file="${1:-}"
  local target_file="${2:-}"
  local validator="${3:-}"
  local wallet_directory=""
  local target_name=""

  shift 3 2>/dev/null || return 2
  wallet_directory="${target_file%/*}"
  target_name="${target_file##*/}"
  [[ -n "${target_name}" && "${wallet_directory}" != "${target_file}" &&
     "${staged_file}" == "${wallet_directory}/.cntools-"* &&
     "${validator}" =~ ^cntools_wallet_[A-Za-z0-9_]+_validate$ ]] || return 2
  declare -F "${validator}" >/dev/null 2>&1 || return 2
  cntools_wallet_directory_safe "${wallet_directory}" || return 1
  [[ -f "${staged_file}" && ! -L "${staged_file}" &&
     -O "${staged_file}" ]] || return 1

  if cntools_wallet_material_entry_exists "${target_file}"; then
    cntools_wallet_material_remove_temp "${staged_file}" || true
    cntools_wallet_material_existing_valid \
      "${target_file}" "${validator}" "$@"
    return $?
  fi
  chmod 0600 "${staged_file}" || return 1
  "${validator}" "${staged_file}" "$@" || {
    cntools_wallet_material_log ERROR \
      "Generated wallet artifact failed validation: ${target_name}"
    cntools_wallet_material_remove_temp "${staged_file}" || true
    return 1
  }

  if ln -- "${staged_file}" "${target_file}" 2>/dev/null; then
    cntools_wallet_material_remove_temp "${staged_file}" || true
    cntools_wallet_material_log WALLET \
      "generated cached wallet artifact=${target_name} wallet=${wallet_directory##*/}"
    return 0
  fi
  cntools_wallet_material_remove_temp "${staged_file}" || true
  if cntools_wallet_material_entry_exists "${target_file}"; then
    if cntools_wallet_material_existing_valid \
        "${target_file}" "${validator}" "$@"; then
      cntools_wallet_material_log WALLET \
        "wallet artifact appeared before publish; retained existing ${target_name}"
      return 0
    fi
    return 1
  fi
  cntools_wallet_material_log ERROR \
    "Could not publish generated wallet artifact: ${target_name}"
  return 1
}

cntools_wallet_materialize_wallet() {
  local wallet_directory="${1:-}"
  local failures=0

  cntools_wallet_directory_safe "${wallet_directory}" || return 1
  if [[ -z "${CNTOOLS_CLI:-}" || "${CNTOOLS_CLI}" != /* ||
        ! -x "${CNTOOLS_CLI}" || -d "${CNTOOLS_CLI}" ]]; then
    cntools_wallet_material_log WALLET \
      "wallet artifact generation skipped; Cardano CLI unavailable wallet=${wallet_directory##*/}"
    return 0
  fi
  cntools_wallet_key_materialize "${wallet_directory}" || failures=$((failures + 1))
  cntools_wallet_address_materialize "${wallet_directory}" || failures=$((failures + 1))
  cntools_wallet_id_materialize_credentials "${wallet_directory}" ||
    failures=$((failures + 1))
  (( failures == 0 ))
}

cntools_wallet_materialize_all() {
  local root="${CNTOOLS_WALLET_DIR:-}"
  local candidate=""
  local failures=0
  local -a candidates=()

  cntools_wallet_root_safe || return 1
  candidates=(
    "${root}"/*
    "${root}"/.[!.]*
    "${root}"/..?*
  )
  for candidate in "${candidates[@]}"; do
    [[ -e "${candidate}" || -L "${candidate}" ]] || continue
    [[ -d "${candidate}" && ! -L "${candidate}" ]] || continue
    if ! cntools_wallet_directory_safe "${candidate}"; then
      failures=$((failures + 1))
      cntools_wallet_material_log ERROR \
        "Skipped unsafe wallet during artifact generation: ${candidate##*/}"
      continue
    fi
    cntools_wallet_materialize_wallet "${candidate}" || failures=$((failures + 1))
  done
  if (( failures > 0 )); then
    cntools_wallet_material_log WARN \
      "wallet artifact generation completed with ${failures} incomplete wallet(s)"
  fi
  # Cached inspection must remain usable when optional artifacts cannot be made.
  return 0
}
