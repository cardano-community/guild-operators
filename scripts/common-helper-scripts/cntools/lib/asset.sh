#!/usr/bin/env bash
# Shared, sanitized asset labels for Wallet and Send. Metadata is display-only.
# shellcheck disable=SC2034

# Printable UTF-8 text of a hex asset name, or nothing. Control, bidi
# override and invalid or overlong sequences are rejected.
cntools_asset_name_text_into() {
  local _ant_output="$1" _ant_hex="$2" _ant_index=0 _ant_length=0 _ant_byte=0 _ant_count=0 _ant_point=0 _ant_next=0 _ant_escaped='' _ant_text=''
  local -a _ant_bytes=()
  printf -v "${_ant_output}" ''
  [[ -n "${_ant_hex}" && "${_ant_hex}" =~ ^([0-9a-fA-F]{2})+$ ]] || return 1
  for (( _ant_index = 0; _ant_index < ${#_ant_hex}; _ant_index += 2 )); do
    _ant_bytes+=("$((16#${_ant_hex:_ant_index:2}))")
    _ant_escaped+="\\x${_ant_hex:_ant_index:2}"
  done
  _ant_length="${#_ant_bytes[@]}"; _ant_index=0
  while (( _ant_index < _ant_length )); do
    _ant_byte="${_ant_bytes[_ant_index]}"
    if (( _ant_byte < 0x80 )); then
      (( _ant_byte >= 0x20 && _ant_byte != 0x7f )) || return 1
      _ant_index=$((_ant_index + 1)); continue
    fi
    # Multi-byte text needs a UTF-8 terminal locale to display.
    [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" =~ [Uu][Tt][Ff]-?8 ]] || return 1
    if (( _ant_byte >= 0xc2 && _ant_byte <= 0xdf )); then _ant_count=1; _ant_point=$((_ant_byte & 0x1f))
    elif (( _ant_byte >= 0xe0 && _ant_byte <= 0xef )); then _ant_count=2; _ant_point=$((_ant_byte & 0x0f))
    elif (( _ant_byte >= 0xf0 && _ant_byte <= 0xf4 )); then _ant_count=3; _ant_point=$((_ant_byte & 0x07))
    else return 1; fi
    (( _ant_index + _ant_count < _ant_length )) || return 1
    while (( _ant_count > 0 )); do
      _ant_index=$((_ant_index + 1)); _ant_next="${_ant_bytes[_ant_index]}"
      (( _ant_next >= 0x80 && _ant_next <= 0xbf )) || return 1
      _ant_point=$(( (_ant_point << 6) | (_ant_next & 0x3f) )); _ant_count=$((_ant_count - 1))
    done
    _ant_index=$((_ant_index + 1))
    # C1 controls, overlong forms, surrogates, out of range, bidi controls
    # and line/paragraph separators.
    (( _ant_point >= 0xa0 && ( _ant_point < 0xd800 || _ant_point > 0xdfff ) && _ant_point <= 0x10ffff &&
       _ant_point != 0x61c && _ant_point != 0x200e && _ant_point != 0x200f &&
       ( _ant_point < 0x2028 || _ant_point > 0x202e ) && ( _ant_point < 0x2066 || _ant_point > 0x2069 ) )) || return 1
  done
  printf -v _ant_text '%b' "${_ant_escaped}"
  printf -v "${_ant_output}" '%s' "${_ant_text}"
}

cntools_asset_label_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_asset_id="${2:-}"
  local _cntools_ordinal="${3:-0}"
  local _cntools_asset_name="${_cntools_asset_id#*.}"
  local _cntools_label="${CNTOOLS_WALLET_ASSET_TICKERS[${_cntools_asset_id}]:-}"
  local _cntools_decoded=""
  local _cntools_suffix=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"

  if [[ "${CNTOOLS_WALLET_ASSET_CLASSES[${_cntools_asset_id}]:-}" == "NFT" ]]; then
    _cntools_label=""
  fi
  [[ -n "${_cntools_label}" ]] ||
    _cntools_label="${CNTOOLS_WALLET_ASSET_METADATA_NAMES[${_cntools_asset_id}]:-}"
  [[ -n "${_cntools_label}" ]] ||
    _cntools_label="${CNTOOLS_WALLET_ASSET_ASCII_NAMES[${_cntools_asset_id}]:-}"
  if [[ -z "${_cntools_label}" && -z "${_cntools_asset_name}" ]]; then
    _cntools_label="(unnamed)"
  elif [[ -z "${_cntools_label}" ]]; then
    # CIP-67 label prefixes (CIP-68 tokens) are named, not decoded as text.
    case "${_cntools_asset_name,,}" in
      000643b0*) _cntools_suffix=' · reference' ;;
      000de140*) _cntools_suffix=' · NFT' ;;
      0014df10*) _cntools_suffix=' · FT' ;;
      001bc280*) _cntools_suffix=' · RFT' ;;
    esac
    [[ -z "${_cntools_suffix}" ]] || _cntools_asset_name="${_cntools_asset_name:8}"
    if cntools_asset_name_text_into _cntools_decoded "${_cntools_asset_name}"; then
      _cntools_label="${_cntools_decoded}"
    fi
  fi
  [[ -n "${_cntools_label}" ]] ||
    printf -v _cntools_label 'Asset %02d' "${_cntools_ordinal}"
  if (( ${#_cntools_label} > 28 - ${#_cntools_suffix} )); then
    _cntools_label="${_cntools_label:0:$((27 - ${#_cntools_suffix}))}…"
  fi
  _cntools_output_ref="${_cntools_label}${_cntools_suffix}"
}


# Reuse the wallet metadata normalizer without replacing its balance arrays.
# Dynamic local scope supplies only the identities required by the parser.
cntools_asset_details_for_ids() {
  local -a CNTOOLS_WALLET_ASSET_IDS=("$@")
  local -A CNTOOLS_WALLET_ASSET_QUANTITIES=()
  local -A CNTOOLS_WALLET_ASSET_FINGERPRINTS=()
  local identity=""
  for identity in "$@"; do
    CNTOOLS_WALLET_ASSET_QUANTITIES["${identity}"]=0
  done
  cntools_wallet_query_koios_asset_metadata
}

