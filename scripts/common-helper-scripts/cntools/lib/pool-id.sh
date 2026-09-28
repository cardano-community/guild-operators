#!/usr/bin/env bash
# Pool IDs are 28-byte hashes, with a fixed pool Bech32 prefix. No key material.
# shellcheck disable=SC2034 # Output namerefs are read by callers.

cntools_pool_id_encode_into() {
  local -n pi_result="$1"
  local pi_hex="${2,,}" pi_text="" pi_hrp=pool
  local pi_i=0 pi_j=0 pi_n=0 pi_acc=0 pi_bits=0 pi_check=1 pi_top=0
  local pi_charset=qpzry9x8gf2tvdw0s3jn54khce6mua7l LC_ALL=C
  local -a pi_values=() pi_generators=(0x3b6a57b2 0x26508e6d 0x1ea119fa 0x3d4233dd 0x2a1462b3)
  [[ "${pi_hex}" =~ ^[0-9a-f]{56}$ ]] || return 1
  for ((pi_i=0; pi_i<4; pi_i++)); do
    printf -v pi_n '%d' "'${pi_hrp:pi_i:1}"
    pi_values+=("$((pi_n >> 5))")
  done
  pi_values+=(0)
  for ((pi_i=0; pi_i<4; pi_i++)); do
    printf -v pi_n '%d' "'${pi_hrp:pi_i:1}"
    pi_values+=("$((pi_n & 31))")
  done
  for ((pi_i=0; pi_i<56; pi_i+=2)); do
    pi_acc=$(((pi_acc << 8 | 16#${pi_hex:pi_i:2}) & 4095)); pi_bits=$((pi_bits+8))
    while ((pi_bits >= 5)); do
      pi_bits=$((pi_bits-5)); pi_n=$((pi_acc >> pi_bits & 31))
      pi_values+=("${pi_n}"); pi_text+="${pi_charset:pi_n:1}"
    done
  done
  pi_n=$((pi_acc << (5-pi_bits) & 31))
  pi_values+=("${pi_n}" 0 0 0 0 0 0); pi_text+="${pi_charset:pi_n:1}"
  for pi_n in "${pi_values[@]}"; do
    pi_top=$((pi_check >> 25)); pi_check=$(((pi_check & 0x1ffffff) << 5 ^ pi_n))
    for ((pi_j=0; pi_j<5; pi_j++)); do
      if ((pi_top >> pi_j & 1)); then pi_check=$((pi_check ^ pi_generators[pi_j])); fi
    done
  done
  pi_check=$((pi_check ^ 1))
  for ((pi_i=5; pi_i>=0; pi_i--)); do
    pi_n=$((pi_check >> (5*pi_i) & 31)); pi_text+="${pi_charset:pi_n:1}"
  done
  pi_result="pool1${pi_text}"
}

cntools_pool_id_into() {
  local -n pd_bech32="$1" pd_hex="$2"
  local pd_input="${3:-}" pd_raw="" pd_encoded="" pd_suffix="" pd_byte=""
  local pd_charset=qpzry9x8gf2tvdw0s3jn54khce6mua7l pd_acc=0 pd_bits=0 pd_i=0 pd_n=0
  pd_input="${pd_input#"${pd_input%%[![:space:]]*}"}"
  pd_input="${pd_input%"${pd_input##*[![:space:]]}"}"
  if [[ "${pd_input}" =~ ^[0-9a-fA-F]{56}$ ]]; then
    pd_raw="${pd_input,,}"
  else
    [[ "${pd_input}" =~ ^pool1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{51}$ ]] || return 1
    for ((pd_i=5; pd_i<50; pd_i++)); do
      pd_suffix="${pd_charset#*"${pd_input:pd_i:1}"}"
      pd_n=$((31-${#pd_suffix})); pd_acc=$(((pd_acc << 5 | pd_n) & 4095)); pd_bits=$((pd_bits+5))
      if ((pd_bits >= 8)); then
        pd_bits=$((pd_bits-8)); printf -v pd_byte '%02x' "$((pd_acc >> pd_bits & 255))"; pd_raw+="${pd_byte}"
      fi
    done
    cntools_pool_id_encode_into pd_encoded "${pd_raw}" || return 1
    # Re-encoding verifies checksum, length and canonical zero padding.
    [[ "${pd_input}" == "${pd_encoded}" ]] || return 1
  fi
  cntools_pool_id_encode_into pd_encoded "${pd_raw}" || return 1
  pd_bech32="${pd_encoded}"; pd_hex="${pd_raw}"
}
