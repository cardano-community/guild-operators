#!/usr/bin/env bash
# Pool IDs are 28-byte hashes, with a fixed pool Bech32 prefix. No key material.
# shellcheck disable=SC2034 # Output namerefs are read by callers.

cntools_pool_id_encode_into() {
  [[ "${2,,}" =~ ^[0-9a-f]{56}$ ]] || return 1
  cntools_bech32_encode_into "$1" "$2" pool
}
cntools_pool_id_into() {
  local -n pd_bech32="$1" pd_hex="$2"
  local pd_input="${3:-}" pd_raw='' pd_encoded=''
  pd_input="${pd_input#"${pd_input%%[![:space:]]*}"}"
  pd_input="${pd_input%"${pd_input##*[![:space:]]}"}"
  if [[ "${pd_input}" =~ ^[0-9a-fA-F]{56}$ ]]; then pd_raw="${pd_input,,}"
  else
    [[ "${pd_input}" =~ ^pool1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{51}$ ]] || return 1
    cntools_bech32_decode_into pd_raw "${pd_input}" pool || return 1
  fi
  cntools_pool_id_encode_into pd_encoded "${pd_raw}" || return 1
  pd_bech32="${pd_encoded}"; pd_hex="${pd_raw}"
}
