#!/usr/bin/env bash
# Shared, sanitized asset labels for Wallet and Send. Metadata is display-only.
# shellcheck disable=SC2034

cntools_asset_label_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_asset_id="${2:-}"
  local _cntools_ordinal="${3:-0}"
  local _cntools_asset_name="${_cntools_asset_id#*.}"
  local _cntools_label="${CNTOOLS_WALLET_ASSET_TICKERS[${_cntools_asset_id}]:-}"
  local _cntools_byte=""
  local _cntools_character=""
  local _cntools_decoded=""
  local _cntools_index=0
  local _cntools_byte_value=0

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
  elif [[ -z "${_cntools_label}" &&
          "${_cntools_asset_name}" =~ ^([0-9a-f]{2})+$ ]]; then
    for (( _cntools_index = 0;
           _cntools_index < ${#_cntools_asset_name};
           _cntools_index += 2 )); do
      _cntools_byte="${_cntools_asset_name:_cntools_index:2}"
      _cntools_byte_value=$((16#${_cntools_byte}))
      if (( _cntools_byte_value < 32 || _cntools_byte_value > 126 )); then
        _cntools_decoded=""
        break
      fi
      printf -v _cntools_character '%b' "\\x${_cntools_byte}"
      _cntools_decoded+="${_cntools_character}"
    done
    _cntools_label="${_cntools_decoded}"
  fi
  [[ -n "${_cntools_label}" ]] ||
    printf -v _cntools_label 'Asset %02d' "${_cntools_ordinal}"
  if (( ${#_cntools_label} > 28 )); then
    _cntools_label="${_cntools_label:0:27}…"
  fi
  _cntools_output_ref="${_cntools_label}"
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

