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



# Token amounts. Koios metadata (asset_info) supplies the total supply and the
# registered decimals; without it an asset's kind and decimals are unknown.

# 0 for an NFT: a Koios total supply of 1, or a CIP-68 (222) user token when
# Koios has not said otherwise.
cntools_asset_is_nft() {
  local _an_id="${1:-}"
  if [[ -n "${CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES[${_an_id}]:-}" ]]; then
    [[ "${CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES[${_an_id}]}" == 1 ]]
    return
  fi
  [[ "${_an_id#*.}" == 000de140* ]]
}

# NFT, FT, or empty when Koios metadata is missing and the name says nothing.
cntools_asset_kind_into() {
  local _ak_output="${1:-}" _ak_id="${2:-}" _ak_kind=''
  if cntools_asset_is_nft "${_ak_id}"; then _ak_kind=NFT
  elif [[ -n "${CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES[${_ak_id}]:-}" || "${_ak_id#*.}" == 0014df10* ]]; then _ak_kind=FT; fi
  printf -v "${_ak_output}" '%s' "${_ak_kind}"
}

# Decimal places of an asset's amounts, or empty while unknown. An NFT has
# none. A Token Registry or CIP-68 entry without a decimals field has none
# either, as those standards define. A token without such metadata, or one
# that was not looked up, is unknown.
cntools_asset_decimals_into() {
  local _ad_output="${1:-}" _ad_id="${2:-}" _ad_value=''
  if cntools_asset_is_nft "${_ad_id}"; then _ad_value=0
  else
    _ad_value="${CNTOOLS_WALLET_ASSET_METADATA_DECIMALS[${_ad_id}]:-${CNTOOLS_WALLET_ASSET_DECIMALS[${_ad_id}]:-}}"
    if [[ ! "${_ad_value}" =~ ^[0-9]+$ ]]; then
      _ad_value=''
      case "${CNTOOLS_WALLET_ASSET_METADATA_SOURCES[${_ad_id}]:-}" in
        'Token Registry'|'CIP-68 (333)'|'CIP-68 (444)') _ad_value=0 ;;
      esac
    fi
  fi
  printf -v "${_ad_output}" '%s' "${_ad_value}"
}

# An asset amount for display: the registered decimals applied, trimmed as
# Settings → Decimals says, or the smallest-unit quantity marked "decimals
# unknown". The optional fourth argument receives the theme role.
cntools_asset_amount_into() {
  local _aa_output="${1:-}" _aa_id="${2:-}" _aa_quantity="${3:-}" _aa_role_output="${4:-}" _aa_decimals='' _aa_value='' _aa_role=number
  cntools_asset_decimals_into _aa_decimals "${_aa_id}"
  if [[ ! "${_aa_quantity}" =~ ^[0-9]+$ ]]; then
    _aa_value=Unavailable; _aa_role=muted
  elif [[ -n "${_aa_decimals}" ]]; then
    cntools_number_format_units_into _aa_value "${_aa_quantity}" "${_aa_decimals}" || return 1
  else
    cntools_number_format_into _aa_value "${_aa_quantity}" || return 1
    _aa_value+=' · decimals unknown'; _aa_role=warning
  fi
  printf -v "${_aa_output}" '%s' "${_aa_value}"
  [[ -z "${_aa_role_output}" ]] || printf -v "${_aa_role_output}" '%s' "${_aa_role}"
}

# The number alone, for narrow columns: decimals applied when known,
# otherwise the smallest-unit quantity (callers say that once elsewhere).
cntools_asset_number_into() {
  local _an_output="${1:-}" _an_id="${2:-}" _an_quantity="${3:-}" _an_decimals='' _an_value=''
  cntools_asset_decimals_into _an_decimals "${_an_id}"
  if [[ -n "${_an_decimals}" ]]; then
    cntools_number_format_units_into _an_value "${_an_quantity}" "${_an_decimals}" || return 1
  else
    cntools_number_format_into _an_value "${_an_quantity}" || return 1
  fi
  printf -v "${_an_output}" '%s' "${_an_value}"
}

# 0 when any of the given assets has unknown decimals.
cntools_asset_any_decimals_unknown() {
  local _au_id='' _au_decimals=''
  for _au_id in "$@"; do
    cntools_asset_decimals_into _au_decimals "${_au_id}"
    [[ -n "${_au_decimals}" ]] || return 0
  done
  return 1
}

# How an amount of this asset is typed: "whole units" for an NFT or a token
# without decimals, "up to N decimals", or smallest units when unknown.
cntools_asset_input_hint_into() {
  local _ai_output="${1:-}" _ai_id="${2:-}" _ai_decimals='' _ai_hint=''
  cntools_asset_decimals_into _ai_decimals "${_ai_id}"
  # More decimals than amounts are typed with: smallest units instead.
  [[ -z "${_ai_decimals}" ]] || (( _ai_decimals <= 20 )) || _ai_decimals=''
  case "${_ai_decimals}" in
    '') _ai_hint='smallest units, decimals unknown' ;;
    0) _ai_hint='whole units' ;;
    1) _ai_hint='up to 1 decimal' ;;
    *) _ai_hint="up to ${_ai_decimals} decimals" ;;
  esac
  printf -v "${_ai_output}" '%s' "${_ai_hint}"
}

# An entered amount in smallest units, read with the asset's decimals ("1.5"
# of a 6-decimal token is 1500000). Unknown decimals take smallest units.
# Returns 1 for an amount with more decimals than the asset has.
cntools_asset_units_into() {
  local _au_output="${1:-}" _au_id="${2:-}" _au_entered="${3:-}" _au_decimals='' _au_units=''
  [[ "${_au_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  cntools_asset_decimals_into _au_decimals "${_au_id}"
  [[ -z "${_au_decimals}" ]] || (( _au_decimals <= 20 )) || _au_decimals=''
  cntools_number_units_into _au_units "${_au_entered}" "${_au_decimals:-0}" || return 1
  printf -v "${_au_output}" '%s' "${_au_units}"
}
