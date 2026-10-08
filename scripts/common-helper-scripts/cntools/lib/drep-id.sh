#!/usr/bin/env bash
# CIP-129 DRep identities, including unambiguous legacy CIP-105 IDs.
# No keys, external converters, or network requests are needed.
# shellcheck disable=SC2034

cntools_drep_bech32_into() {
  local -n di_result="$1"
  local di_hex="${2,,}" di_hrp="${3:-drep}" di_text="" di_charset=qpzry9x8gf2tvdw0s3jn54khce6mua7l
  local di_i=0 di_j=0 di_n=0 di_acc=0 di_bits=0 di_check=1 di_top=0 LC_ALL=C
  local -a di_values=() di_generators=(0x3b6a57b2 0x26508e6d 0x1ea119fa 0x3d4233dd 0x2a1462b3)
  case "${di_hrp}" in
    drep|drep_script)
      [[ "${di_hex}" =~ ^[0-9a-f]{56}$ || ( "${di_hrp}" == drep && "${di_hex}" =~ ^2[23][0-9a-f]{56}$ ) ]] || return 2 ;;
    gov_action) [[ "${di_hex}" =~ ^[0-9a-f]{66}$ ]] || return 2 ;;
    *) return 2 ;;
  esac
  for ((di_i=0; di_i<${#di_hrp}; di_i++)); do
    printf -v di_n '%d' "'${di_hrp:di_i:1}"; di_values+=("$((di_n >> 5))")
  done
  di_values+=(0)
  for ((di_i=0; di_i<${#di_hrp}; di_i++)); do
    printf -v di_n '%d' "'${di_hrp:di_i:1}"; di_values+=("$((di_n & 31))")
  done
  for ((di_i=0; di_i<${#di_hex}; di_i+=2)); do
    di_acc=$(((di_acc << 8 | 16#${di_hex:di_i:2}) & 4095)); di_bits=$((di_bits+8))
    while ((di_bits >= 5)); do
      di_bits=$((di_bits-5)); di_n=$((di_acc >> di_bits & 31))
      di_values+=("${di_n}"); di_text+="${di_charset:di_n:1}"
    done
  done
  if ((di_bits > 0)); then
    di_n=$((di_acc << (5-di_bits) & 31)); di_values+=("${di_n}"); di_text+="${di_charset:di_n:1}"
  fi
  di_values+=(0 0 0 0 0 0)
  for di_n in "${di_values[@]}"; do
    di_top=$((di_check >> 25)); di_check=$(((di_check & 0x1ffffff) << 5 ^ di_n))
    for ((di_j=0; di_j<5; di_j++)); do
      if ((di_top >> di_j & 1)); then di_check=$((di_check ^ di_generators[di_j])); fi
    done
  done
  di_check=$((di_check ^ 1))
  for ((di_i=5; di_i>=0; di_i--)); do
    di_n=$((di_check >> (5*di_i) & 31)); di_text+="${di_charset:di_n:1}"
  done
  di_result="${di_hrp}1${di_text}"
}

cntools_drep_id_into() {
  local -n dd_id="$1" dd_kind="$2" dd_hash="$3"
  local dd_input="${4:-}" dd_hrp="" dd_data="" dd_raw="" dd_encoded="" dd_byte="" dd_suffix="" dd_type=key
  local dd_charset=qpzry9x8gf2tvdw0s3jn54khce6mua7l dd_acc=0 dd_bits=0 dd_i=0 dd_n=0
  dd_input="${dd_input#"${dd_input%%[![:space:]]*}"}"
  dd_input="${dd_input%"${dd_input##*[![:space:]]}"}"
  case "${dd_input}" in
    alwaysAbstain|drep_always_abstain) dd_id=drep_always_abstain; dd_kind=abstain; dd_hash=""; return 0 ;;
    alwaysNoConfidence|drep_always_no_confidence) dd_id=drep_always_no_confidence; dd_kind=no-confidence; dd_hash=""; return 0 ;;
  esac
  [[ "${dd_input}" =~ ^(drep|drep_script)1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{51}([qpzry9x8gf2tvdw0s3jn54khce6mua7l]{2})?$ ]] || return 1
  dd_hrp="${dd_input%%1*}"; dd_data="${dd_input#*1}"; dd_data="${dd_data:0:${#dd_data}-6}"
  for ((dd_i=0; dd_i<${#dd_data}; dd_i++)); do
    dd_suffix="${dd_charset#*"${dd_data:dd_i:1}"}"
    dd_n=$((31-${#dd_suffix})); dd_acc=$(((dd_acc << 5 | dd_n) & 4095)); dd_bits=$((dd_bits+5))
    if ((dd_bits >= 8)); then
      dd_bits=$((dd_bits-8)); printf -v dd_byte '%02x' "$((dd_acc >> dd_bits & 255))"; dd_raw+="${dd_byte}"
    fi
  done
  cntools_drep_bech32_into dd_encoded "${dd_raw}" "${dd_hrp}" || return 1
  [[ "${dd_encoded}" == "${dd_input}" ]] || return 1 # Checksum and zero padding.
  if (( ${#dd_raw} == 58 )); then
    [[ "${dd_hrp}" == drep ]] || return 1
    [[ "${dd_raw:0:2}" != 23 ]] || dd_type=script
    dd_raw="${dd_raw:2}"
  elif [[ "${dd_hrp}" == drep_script ]]; then dd_type=script
  fi
  dd_byte=22; [[ "${dd_type}" != script ]] || dd_byte=23
  cntools_drep_bech32_into dd_encoded "${dd_byte}${dd_raw}" || return 1
  dd_id="${dd_encoded}"; dd_kind="${dd_type}"; dd_hash="${dd_raw}"
}
