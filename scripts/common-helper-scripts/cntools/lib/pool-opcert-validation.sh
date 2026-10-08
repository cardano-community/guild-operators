#!/usr/bin/env bash
# Bounded public opcert parsing and cold-key signature verification.
# shellcheck disable=SC2034
cntools_pool_counter_into() {
  local output="$1" file="$2" public="$3" encoded='' tail='' parsed=''
  cntools_pool_public_file_safe "${file}" && cntools_pool_key_validate "${public}" cold verification || return 1
  encoded="$(jq -esr 'select(length == 1 and .[0].type == "NodeOperationalCertificateIssueCounter") |
    .[0].cborHex | ascii_downcase | select(test("^82[0-9a-f]+$")) | .[2:]' "${file}")" || return 1
  cntools_pool_health_uint_into parsed tail "${encoded}" &&
    [[ "${tail}" == "$(jq -r '.cborHex|ascii_downcase' "${public}")" ]] || return 1
  printf -v "${output}" '%s' "${parsed}"
}

cntools_pool_opcert_fields_into() {
  local counter_output="$1" period_output="$2" signature_output="$3" file="$4" cold="$5" hot="$6"
  local encoded='' cold_hex='' hot_hex='' tail='' field_counter='' field_period=''
  cntools_pool_key_validate "${cold}" cold verification && cntools_pool_key_validate "${hot}" kes verification &&
    cntools_pool_public_file_safe "${file}" || return 1
  cold_hex="$(jq -r '.cborHex[4:]|ascii_downcase' "${cold}")"; hot_hex="$(jq -r '.cborHex[4:]|ascii_downcase' "${hot}")"
  encoded="$(jq -esr 'select(length == 1 and .[0].type == "NodeOperationalCertificate") |
    .[0].cborHex | ascii_downcase | select(test("^[0-9a-f]+$"))' "${file}")" || return 1
  [[ "${encoded:0:72}" == "82845820${hot_hex}" ]] || return 1
  cntools_pool_health_uint_into field_counter tail "${encoded:72}" &&
    cntools_pool_health_uint_into field_period tail "${tail}" || return 1
  [[ ${#tail} == 200 && "${tail:0:4}" == 5840 && "${tail:132}" == "5820${cold_hex}" ]] || return 1
  printf -v "${counter_output}" '%s' "${field_counter}"
  printf -v "${period_output}" '%s' "${field_period}"
  printf -v "${signature_output}" '%s' "${tail:4:128}"
}

cntools_pool_opcert_verify() {
  local file="$1" cold="$2" hot="$3" expected_counter="$4" expected_period="$5"
  local parsed_counter='' parsed_period='' signature='' message='' public='' sig='' response='' errors='' payload='' cold_hex='' hot_hex=''
  cntools_pool_opcert_fields_into parsed_counter parsed_period signature "${file}" "${cold}" "${hot}" &&
    [[ "${parsed_counter}" == "${expected_counter}" && "${parsed_period}" == "${expected_period}" ]] || return 1
  cntools_transaction_require_signature_tools || return 1
  cold_hex="$(jq -r '.cborHex[4:]|ascii_downcase' "${cold}")"; hot_hex="$(jq -r '.cborHex[4:]|ascii_downcase' "${hot}")"
  # Ledger OCertSignable: raw KES public key, issue counter and KES period;
  # each integer is an unsigned 64-bit big-endian word (not CBOR or a hash).
  printf -v payload '%s%016x%016x' "${hot_hex}" "${parsed_counter}" "${parsed_period}"
  cntools_transaction_temp_file message opcert-message && cntools_transaction_temp_file public opcert-public &&
    cntools_transaction_temp_file sig opcert-signature && cntools_transaction_temp_file response opcert-verification &&
    cntools_transaction_temp_file errors opcert-verification-errors || return 1
  cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" 000 -- "${CNTOOLS_TRANSACTION_XXD}" -r -p <<< "${payload}" > "${message}" &&
    cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" 000 -- "${CNTOOLS_TRANSACTION_XXD}" -r -p <<< "${signature}" > "${sig}" &&
    cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" 000 -- "${CNTOOLS_TRANSACTION_XXD}" -r -p \
      <<< "${CNTOOLS_TRANSACTION_ED25519_SPKI_PREFIX}${cold_hex}" > "${public}" || return 1
  if ! cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_TRANSACTION_OPENSSL}" pkeyutl -verify -pubin \
      -inkey "${public}" -keyform DER -rawin -in "${message}" -sigfile "${sig}"; then
    cntools_transaction_log ERROR 'Operational certificate cold-key signature validation failed'; return 1
  fi
}
