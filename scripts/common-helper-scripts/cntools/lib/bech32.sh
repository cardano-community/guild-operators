#!/usr/bin/env bash
# Cardano Bech32 byte-string codec. Domain wrappers enforce HRP, length,
# credential kind and network. Canonical padding/checksum are verified here.
# shellcheck disable=SC2034

cntools_bech32_encode_into() {
  local _bc_target="$1" _bc_hex="${2,,}" _bc_hrp="$3" _bc_text='' _bc_charset=qpzry9x8gf2tvdw0s3jn54khce6mua7l
  local _bc_i=0 _bc_j=0 _bc_n=0 _bc_acc=0 _bc_bits=0 _bc_check=1 _bc_top=0 LC_ALL=C
  local -a _bc_values=() _bc_generators=(0x3b6a57b2 0x26508e6d 0x1ea119fa 0x3d4233dd 0x2a1462b3)
  [[ "${_bc_target}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "${_bc_hex}" =~ ^([0-9a-f]{2})+$ &&
     ${#_bc_hex} -le 256 && "${_bc_hrp}" =~ ^[a-z][a-z0-9_]{0,30}$ ]] || return 2
  local -n _bc_result="${_bc_target}"
  for ((_bc_i=0; _bc_i<${#_bc_hrp}; _bc_i++)); do
    printf -v _bc_n '%d' "'${_bc_hrp:_bc_i:1}"; _bc_values+=("$((_bc_n >> 5))")
  done
  _bc_values+=(0)
  for ((_bc_i=0; _bc_i<${#_bc_hrp}; _bc_i++)); do
    printf -v _bc_n '%d' "'${_bc_hrp:_bc_i:1}"; _bc_values+=("$((_bc_n & 31))")
  done
  for ((_bc_i=0; _bc_i<${#_bc_hex}; _bc_i+=2)); do
    _bc_acc=$(((_bc_acc << 8 | 16#${_bc_hex:_bc_i:2}) & 4095)); _bc_bits=$((_bc_bits+8))
    while ((_bc_bits >= 5)); do
      _bc_bits=$((_bc_bits-5)); _bc_n=$((_bc_acc >> _bc_bits & 31))
      _bc_values+=("${_bc_n}"); _bc_text+="${_bc_charset:_bc_n:1}"
    done
  done
  if ((_bc_bits > 0)); then
    _bc_n=$((_bc_acc << (5-_bc_bits) & 31)); _bc_values+=("${_bc_n}"); _bc_text+="${_bc_charset:_bc_n:1}"
  fi
  _bc_values+=(0 0 0 0 0 0)
  for _bc_n in "${_bc_values[@]}"; do
    _bc_top=$((_bc_check >> 25)); _bc_check=$(((_bc_check & 0x1ffffff) << 5 ^ _bc_n))
    for ((_bc_j=0; _bc_j<5; _bc_j++)); do
      if ((_bc_top >> _bc_j & 1)); then _bc_check=$((_bc_check ^ _bc_generators[_bc_j])); fi
    done
  done
  _bc_check=$((_bc_check ^ 1))
  for ((_bc_i=5; _bc_i>=0; _bc_i--)); do
    _bc_n=$((_bc_check >> (5*_bc_i) & 31)); _bc_text+="${_bc_charset:_bc_n:1}"
  done
  _bc_result="${_bc_hrp}1${_bc_text}"
}

cntools_bech32_decode_into() {
  local _bd_target="$1" _bd_input="$2" _bd_hrp="$3" _bd_data='' _bd_raw='' _bd_encoded='' _bd_byte='' _bd_suffix=''
  local _bd_charset=qpzry9x8gf2tvdw0s3jn54khce6mua7l _bd_acc=0 _bd_bits=0 _bd_i=0 _bd_n=0 LC_ALL=C
  [[ "${_bd_target}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "${_bd_input}" == "${_bd_hrp}1"* &&
     ${#_bd_input} -le 256 ]] || return 1
  local -n _bd_result="${_bd_target}"
  _bd_data="${_bd_input#"${_bd_hrp}1"}"
  [[ "${_bd_data}" =~ ^[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{8,}$ ]] || return 1
  _bd_data="${_bd_data:0:${#_bd_data}-6}"
  for ((_bd_i=0; _bd_i<${#_bd_data}; _bd_i++)); do
    _bd_suffix="${_bd_charset#*"${_bd_data:_bd_i:1}"}"
    _bd_n=$((31-${#_bd_suffix})); _bd_acc=$(((_bd_acc << 5 | _bd_n) & 4095)); _bd_bits=$((_bd_bits+5))
    if ((_bd_bits >= 8)); then
      _bd_bits=$((_bd_bits-8)); printf -v _bd_byte '%02x' "$((_bd_acc >> _bd_bits & 255))"; _bd_raw+="${_bd_byte}"
    fi
  done
  ((_bd_bits <= 4)) || return 1
  cntools_bech32_encode_into _bd_encoded "${_bd_raw}" "${_bd_hrp}" || return 1
  [[ "${_bd_encoded}" == "${_bd_input}" ]] || return 1
  _bd_result="${_bd_raw}"
}
