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

# Exact unsigned-integer helpers used for ledger quantities. These deliberately
# avoid Bash arithmetic for complete values and keep every amount as a decimal
# string. Small digits, carries, divisors, and percentages remain bounded.
cntools_uint_normalize_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_value="${2:-}"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_value}" =~ ^[0-9]+$ &&
     ${#_cntools_value} -le 80 ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  while [[ ${#_cntools_value} -gt 1 && "${_cntools_value:0:1}" == "0" ]]; do
    _cntools_value="${_cntools_value:1}"
  done
  _cntools_output_ref="${_cntools_value}"
}

cntools_uint_compare_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_left=""
  local _cntools_right=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  cntools_uint_normalize_into _cntools_left "${2:-}" || return 2
  cntools_uint_normalize_into _cntools_right "${3:-}" || return 2
  if (( ${#_cntools_left} < ${#_cntools_right} )); then
    _cntools_output_ref=-1
  elif (( ${#_cntools_left} > ${#_cntools_right} )); then
    _cntools_output_ref=1
  elif [[ "${_cntools_left}" < "${_cntools_right}" ]]; then
    _cntools_output_ref=-1
  elif [[ "${_cntools_left}" > "${_cntools_right}" ]]; then
    _cntools_output_ref=1
  else
    _cntools_output_ref=0
  fi
}

cntools_uint_greater_equal() {
  local _cntools_comparison=0

  cntools_uint_compare_into _cntools_comparison "${1:-}" "${2:-}" || return 2
  (( _cntools_comparison >= 0 ))
}

cntools_uint_greater() {
  local _cntools_comparison=0

  cntools_uint_compare_into _cntools_comparison "${1:-}" "${2:-}" || return 2
  (( _cntools_comparison > 0 ))
}

cntools_uint_add_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_left="${2:-}"
  local _cntools_right="${3:-}"
  local _cntools_left_index=0
  local _cntools_right_index=0
  local _cntools_left_digit=0
  local _cntools_right_digit=0
  local _cntools_carry=0
  local _cntools_sum=0
  local _cntools_result=""
  local _cntools_normalized_result=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  cntools_uint_normalize_into _cntools_left "${_cntools_left}" || return 2
  cntools_uint_normalize_into _cntools_right "${_cntools_right}" || return 2
  _cntools_left_index=$((${#_cntools_left} - 1))
  _cntools_right_index=$((${#_cntools_right} - 1))
  while (( _cntools_left_index >= 0 || _cntools_right_index >= 0 ||
           _cntools_carry > 0 )); do
    _cntools_left_digit=0
    _cntools_right_digit=0
    if (( _cntools_left_index >= 0 )); then
      _cntools_left_digit=$((10#${_cntools_left:_cntools_left_index:1}))
      _cntools_left_index=$((_cntools_left_index - 1))
    fi
    if (( _cntools_right_index >= 0 )); then
      _cntools_right_digit=$((10#${_cntools_right:_cntools_right_index:1}))
      _cntools_right_index=$((_cntools_right_index - 1))
    fi
    _cntools_sum=$((_cntools_left_digit + _cntools_right_digit + _cntools_carry))
    _cntools_result="$((_cntools_sum % 10))${_cntools_result}"
    _cntools_carry=$((_cntools_sum / 10))
  done
  cntools_uint_normalize_into \
    _cntools_normalized_result "${_cntools_result:-0}" || return 1
  _cntools_output_ref="${_cntools_normalized_result}"
}

cntools_uint_subtract_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_left="${2:-}"
  local _cntools_right="${3:-}"
  local _cntools_left_index=0
  local _cntools_right_index=0
  local _cntools_left_digit=0
  local _cntools_right_digit=0
  local _cntools_borrow=0
  local _cntools_digit=0
  local _cntools_result=""
  local _cntools_normalized_result=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  cntools_uint_normalize_into _cntools_left "${_cntools_left}" || return 2
  cntools_uint_normalize_into _cntools_right "${_cntools_right}" || return 2
  cntools_uint_greater_equal "${_cntools_left}" "${_cntools_right}" || return 1
  _cntools_left_index=$((${#_cntools_left} - 1))
  _cntools_right_index=$((${#_cntools_right} - 1))
  while (( _cntools_left_index >= 0 )); do
    _cntools_left_digit=$((10#${_cntools_left:_cntools_left_index:1} - _cntools_borrow))
    _cntools_right_digit=0
    if (( _cntools_right_index >= 0 )); then
      _cntools_right_digit=$((10#${_cntools_right:_cntools_right_index:1}))
      _cntools_right_index=$((_cntools_right_index - 1))
    fi
    _cntools_borrow=0
    if (( _cntools_left_digit < _cntools_right_digit )); then
      _cntools_left_digit=$((_cntools_left_digit + 10))
      _cntools_borrow=1
    fi
    _cntools_digit=$((_cntools_left_digit - _cntools_right_digit))
    _cntools_result="${_cntools_digit}${_cntools_result}"
    _cntools_left_index=$((_cntools_left_index - 1))
  done
  (( _cntools_borrow == 0 )) || return 1
  cntools_uint_normalize_into \
    _cntools_normalized_result "${_cntools_result:-0}" || return 1
  _cntools_output_ref="${_cntools_normalized_result}"
}

cntools_uint_multiply_small_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_value="${2:-}"
  local _cntools_multiplier="${3:-}"
  local _cntools_index=0
  local _cntools_digit=0
  local _cntools_product=0
  local _cntools_carry=0
  local _cntools_result=""
  local _cntools_normalized_result=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_multiplier}" =~ ^[0-9]+$ &&
     ${#_cntools_multiplier} -le 6 ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  cntools_uint_normalize_into _cntools_value "${_cntools_value}" || return 2
  _cntools_multiplier=$((10#${_cntools_multiplier}))
  (( _cntools_multiplier <= 100000 )) || return 2
  if (( _cntools_multiplier == 0 )); then
    _cntools_output_ref=0
    return 0
  fi
  _cntools_index=$((${#_cntools_value} - 1))
  while (( _cntools_index >= 0 || _cntools_carry > 0 )); do
    _cntools_digit=0
    if (( _cntools_index >= 0 )); then
      _cntools_digit=$((10#${_cntools_value:_cntools_index:1}))
      _cntools_index=$((_cntools_index - 1))
    fi
    _cntools_product=$((_cntools_digit * _cntools_multiplier + _cntools_carry))
    _cntools_result="$((_cntools_product % 10))${_cntools_result}"
    _cntools_carry=$((_cntools_product / 10))
  done
  cntools_uint_normalize_into \
    _cntools_normalized_result "${_cntools_result:-0}" || return 1
  _cntools_output_ref="${_cntools_normalized_result}"
}

cntools_uint_divmod_small_into() {
  local _cntools_quotient_name="${1:-}"
  local _cntools_remainder_name="${2:-}"
  local _cntools_value="${3:-}"
  local _cntools_divisor="${4:-}"
  local _cntools_index=0
  local _cntools_current=0
  local _cntools_division_result=""
  local _cntools_normalized_result=""

  [[ "${_cntools_quotient_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_remainder_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_divisor}" =~ ^[1-9][0-9]{0,5}$ ]] || return 2
  local -n _cntools_quotient_ref="${_cntools_quotient_name}"
  local -n _cntools_remainder_ref="${_cntools_remainder_name}"
  cntools_uint_normalize_into _cntools_value "${_cntools_value}" || return 2
  _cntools_divisor=$((10#${_cntools_divisor}))
  for (( _cntools_index = 0;
         _cntools_index < ${#_cntools_value};
         _cntools_index++ )); do
    _cntools_current=$((_cntools_current * 10 + 10#${_cntools_value:_cntools_index:1}))
    _cntools_division_result+="$((_cntools_current / _cntools_divisor))"
    _cntools_current=$((_cntools_current % _cntools_divisor))
  done
  cntools_uint_normalize_into \
    _cntools_normalized_result "${_cntools_division_result:-0}" || return 1
  _cntools_quotient_ref="${_cntools_normalized_result}"
  _cntools_remainder_ref="${_cntools_current}"
}

cntools_uint_percent_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_value="${2:-}"
  local _cntools_percent="${3:-}"
  local _cntools_quotient=""
  local _cntools_remainder=""
  local _cntools_major=""
  local _cntools_minor=0
  local _cntools_final=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_percent}" =~ ^[0-9]+$ &&
     ${#_cntools_percent} -le 3 ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_percent=$((10#${_cntools_percent}))
  (( _cntools_percent <= 100 )) || return 2
  cntools_uint_divmod_small_into \
    _cntools_quotient _cntools_remainder "${_cntools_value}" 100 || return 2
  cntools_uint_multiply_small_into \
    _cntools_major "${_cntools_quotient}" "${_cntools_percent}" || return 2
  _cntools_minor=$((_cntools_remainder * _cntools_percent / 100))
  cntools_uint_add_into _cntools_final \
    "${_cntools_major}" "${_cntools_minor}" || return 1
  _cntools_output_ref="${_cntools_final}"
}
