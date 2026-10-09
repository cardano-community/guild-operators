#!/usr/bin/env bash
# CIP-129 DRep identities, including unambiguous legacy CIP-105 IDs.
# No keys, external converters, or network requests are needed.
# shellcheck disable=SC2034

cntools_drep_bech32_into() {
  local di_hex="${2,,}" di_hrp="${3:-drep}"
  case "${di_hrp}" in
    drep|drep_script)
      [[ "${di_hex}" =~ ^[0-9a-f]{56}$ || ( "${di_hrp}" == drep && "${di_hex}" =~ ^2[23][0-9a-f]{56}$ ) ]] || return 2 ;;
    gov_action) [[ "${di_hex}" =~ ^[0-9a-f]{66}$ ]] || return 2 ;;
    calidus) [[ "${di_hex}" =~ ^a1[0-9a-f]{56}$ ]] || return 2 ;;
    ed25519e_sk) [[ "${di_hex}" =~ ^[0-9a-f]{128}$ ]] || return 2 ;;
    *) return 2 ;;
  esac
  cntools_bech32_encode_into "$1" "${di_hex}" "${di_hrp}"
}
cntools_drep_id_into() {
  local -n dd_id="$1" dd_kind="$2" dd_hash="$3"
  local dd_input="${4:-}" dd_hrp="" dd_raw="" dd_encoded="" dd_byte="" dd_type=key
  dd_input="${dd_input#"${dd_input%%[![:space:]]*}"}"
  dd_input="${dd_input%"${dd_input##*[![:space:]]}"}"
  case "${dd_input}" in
    alwaysAbstain|drep_always_abstain) dd_id=drep_always_abstain; dd_kind=abstain; dd_hash=""; return 0 ;;
    alwaysNoConfidence|drep_always_no_confidence) dd_id=drep_always_no_confidence; dd_kind=no-confidence; dd_hash=""; return 0 ;;
  esac
  [[ "${dd_input}" =~ ^(drep|drep_script)1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{51}([qpzry9x8gf2tvdw0s3jn54khce6mua7l]{2})?$ ]] || return 1
  dd_hrp="${dd_input%%1*}"
  cntools_bech32_decode_into dd_raw "${dd_input}" "${dd_hrp}" || return 1
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
