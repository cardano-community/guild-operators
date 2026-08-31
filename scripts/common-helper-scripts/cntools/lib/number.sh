#!/usr/bin/env bash
# Lossless formatting and normalization for human-readable decimal numbers.
# All operations are string based so values are never constrained by Bash's
# integer range or converted through floating-point arithmetic.

cntools_number_normalize_into() {
  (( $# == 2 )) || return 2
  local _cntools_number_output_name="${1:-}"
  local _cntools_number_input="${2:-}"
  local _cntools_number_sign=""
  local _cntools_number_unsigned=""
  local _cntools_number_integer=""
  local _cntools_number_fraction=""
  local _cntools_number_result_value=""

  [[ "${_cntools_number_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
    return 2
  local -n _cntools_number_output_ref="${_cntools_number_output_name}"
  _cntools_number_output_ref=""
  [[ -n "${_cntools_number_input}" ]] || return 1

  _cntools_number_unsigned="${_cntools_number_input}"
  case "${_cntools_number_unsigned:0:1}" in
    -)
      _cntools_number_sign="-"
      _cntools_number_unsigned="${_cntools_number_unsigned:1}"
      ;;
    +)
      _cntools_number_unsigned="${_cntools_number_unsigned:1}"
      ;;
  esac
  [[ -n "${_cntools_number_unsigned}" ]] || return 1

  if [[ "${_cntools_number_unsigned}" == *,* ]]; then
    [[ "${_cntools_number_unsigned}" =~ ^([1-9][0-9]{0,2}(,[0-9]{3})+)(\.([0-9]+))?$ ]] ||
      return 1
    _cntools_number_integer="${BASH_REMATCH[1]//,/}"
    _cntools_number_fraction="${BASH_REMATCH[4]:-}"
  elif [[ "${_cntools_number_unsigned}" =~ ^([0-9]+)(\.([0-9]+))?$ ]]; then
    _cntools_number_integer="${BASH_REMATCH[1]}"
    _cntools_number_fraction="${BASH_REMATCH[3]:-}"
  elif [[ "${_cntools_number_unsigned}" =~ ^\.([0-9]+)$ ]]; then
    _cntools_number_integer="0"
    _cntools_number_fraction="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  while [[ "${#_cntools_number_integer}" -gt 1 &&
           "${_cntools_number_integer:0:1}" == "0" ]]; do
    _cntools_number_integer="${_cntools_number_integer:1}"
  done
  if [[ "${_cntools_number_integer}${_cntools_number_fraction}" =~ ^0+$ ]]; then
    _cntools_number_sign=""
  fi

  _cntools_number_result_value="${_cntools_number_sign}${_cntools_number_integer}"
  [[ -z "${_cntools_number_fraction}" ]] ||
    _cntools_number_result_value+=".${_cntools_number_fraction}"
  _cntools_number_output_ref="${_cntools_number_result_value}"
}

cntools_number_normalize() {
  (( $# == 1 )) || return 2
  local _cntools_number_result=""

  cntools_number_normalize_into _cntools_number_result "${1:-}" || return $?
  printf '%s\n' "${_cntools_number_result}"
}

cntools_number_format_into() {
  (( $# == 2 )) || return 2
  local _cntools_number_output_name="${1:-}"
  local _cntools_number_input="${2:-}"
  local _cntools_number_normalized=""
  local _cntools_number_sign=""
  local _cntools_number_unsigned=""
  local _cntools_number_integer=""
  local _cntools_number_fraction=""
  local _cntools_number_grouped=""
  local _cntools_number_chunk=""
  local _cntools_number_suffix=""

  [[ "${_cntools_number_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
    return 2
  local -n _cntools_number_output_ref="${_cntools_number_output_name}"
  _cntools_number_output_ref=""
  cntools_number_normalize_into \
    _cntools_number_normalized "${_cntools_number_input}" || return $?

  _cntools_number_unsigned="${_cntools_number_normalized}"
  if [[ "${_cntools_number_unsigned:0:1}" == "-" ]]; then
    _cntools_number_sign="-"
    _cntools_number_unsigned="${_cntools_number_unsigned:1}"
  fi
  if [[ "${_cntools_number_unsigned}" == *.* ]]; then
    _cntools_number_integer="${_cntools_number_unsigned%%.*}"
    _cntools_number_fraction=".${_cntools_number_unsigned#*.}"
  else
    _cntools_number_integer="${_cntools_number_unsigned}"
  fi

  _cntools_number_grouped="${_cntools_number_integer}"
  _cntools_number_suffix="${_cntools_number_fraction}"
  while [[ "${#_cntools_number_grouped}" -gt 3 ]]; do
    _cntools_number_chunk="${_cntools_number_grouped: -3}"
    _cntools_number_grouped="${_cntools_number_grouped:0:${#_cntools_number_grouped}-3}"
    _cntools_number_suffix=",${_cntools_number_chunk}${_cntools_number_suffix}"
  done
  _cntools_number_output_ref="${_cntools_number_sign}${_cntools_number_grouped}${_cntools_number_suffix}"
}

cntools_number_format() {
  (( $# == 1 )) || return 2
  local _cntools_number_result=""

  cntools_number_format_into _cntools_number_result "${1:-}" || return $?
  printf '%s\n' "${_cntools_number_result}"
}

cntools_number_is_valid() {
  (( $# == 1 )) || return 2
  local _cntools_number_result=""

  cntools_number_normalize_into _cntools_number_result "${1:-}"
}
