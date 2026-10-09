#!/usr/bin/env bash
# Shared filesystem facts and trusted ancestry; domain-specific policies stay
# with their callers. Shared writable ancestors require the sticky bit.
# shellcheck disable=SC2034

cntools_filesystem_path_components_safe() {
  local path="${1:-}"
  local current="/"
  local component=""
  local -a components=()

  [[ "${path}" = /* ]] || return 1
  [[ -n "${path}" && ! "${path}" =~ [[:cntrl:]] ]] || return 1
  IFS='/' read -r -a components <<< "${path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current%/}/${component}"
    [[ ! -L "${current}" ]] || return 1
  done
}


cntools_filesystem_size_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_path="${2:-}"
  local _cntools_size=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if _cntools_size="$(stat -c '%s' -- "${_cntools_path}" 2>/dev/null)"; then
    :
  elif _cntools_size="$(stat -f '%z' "${_cntools_path}" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  [[ "${_cntools_size}" =~ ^[0-9]+$ ]] || return 1
  _cntools_output_ref="${_cntools_size}"
}


cntools_filesystem_mode_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_path="${2:-}"
  local _cntools_mode=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if _cntools_mode="$(stat -c '%a' -- "${_cntools_path}" 2>/dev/null)"; then
    :
  elif _cntools_mode="$(stat -f '%Op' "${_cntools_path}" 2>/dev/null)"; then
    # BSD's low subfield omits setuid/setgid/sticky bits. Mask the complete
    # mode instead so trusted shared ancestry is checked consistently.
    [[ "${_cntools_mode}" =~ ^[0-7]{5,6}$ ]] || return 1
    printf -v _cntools_mode '%03o' "$((8#${_cntools_mode} & 07777))"
  else
    return 1
  fi
  [[ "${_cntools_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  _cntools_output_ref="${_cntools_mode}"
}


cntools_filesystem_uid_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_path="${2:-}"
  local _cntools_uid=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if _cntools_uid="$(stat -c '%u' -- "${_cntools_path}" 2>/dev/null)"; then
    :
  elif _cntools_uid="$(stat -f '%u' "${_cntools_path}" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  [[ "${_cntools_uid}" =~ ^[0-9]+$ ]] || return 1
  _cntools_output_ref="${_cntools_uid}"
}


cntools_filesystem_directory_ancestry_safe() {
  local directory="${1:-}"
  local current="/"
  local component=""
  local mode=""
  local uid=""
  local permissions=0
  local -a components=()

  [[ -n "${directory}" && "${directory}" = /* ]] || return 1
  [[ ! "${directory}" =~ [[:cntrl:]] ]] || return 1
  IFS='/' read -r -a components <<< "${directory}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current%/}/${component}"
    [[ -d "${current}" && ! -L "${current}" ]] || return 1
    cntools_filesystem_uid_into uid "${current}" || return 1
    [[ "${uid}" == "${EUID}" || "${uid}" == "0" ]] || return 1
    cntools_filesystem_mode_into mode "${current}" || return 1
    permissions=$((8#${mode}))
    if (( (permissions & 0022) != 0 &&
          (permissions & 01000) == 0 )); then
      return 1
    fi
  done
}
