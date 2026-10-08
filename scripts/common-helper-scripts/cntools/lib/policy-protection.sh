#!/usr/bin/env bash
# GPG-compatible, verified counterpart publication before retiring an old key.
# shellcheck disable=SC2034,SC2015
CNTOOLS_POLICY_PROTECTION_SOURCE='' CNTOOLS_POLICY_PROTECTION_TARGET='' CNTOOLS_POLICY_PROTECTION_STAGED=''

cntools_policy_protection_preflight() {
  local directory="$1" operation="$2" file='' skey="${CNTOOLS_POLICY_SKEY_FILENAME:-policy.skey}"
  cntools_policy_filenames_validate && cntools_policy_directory_safe "${directory}" &&
    cntools_transaction_directory_safe "${directory}" || return 1
  [[ "${operation}" == encrypt || "${operation}" == decrypt ]] || return 2
  for file in "${directory}"/* "${directory}"/.[!.]* "${directory}"/..?*; do
    [[ -e "${file}" || -L "${file}" ]] || continue
    [[ -f "${file}" && ! -L "${file}" && -O "${file}" && -r "${file}" && "${file##*/}" != .cntools-* ]] || {
      cntools_policy_error 'Linked, nested, unowned or unfinished policy files must be resolved before protection.'; return 1;
    }
    case "${file}" in
      *.skey|*.gpg)
        [[ "${file}" == "${directory}/${skey}" || "${file}" == "${directory}/${skey}.gpg" ]] || {
          cntools_policy_error 'An unknown signing/encrypted file was found. It was not left silently unprotected.'; return 1;
        } ;;
    esac
  done
  [[ ! ( -e "${directory}/${skey}" && -e "${directory}/${skey}.gpg" ) ]] || { cntools_policy_error 'Mixed plaintext/encrypted policy keys must be resolved first.'; return 1; }
  # An already encrypted/public-only policy can still have its file locks
  # restored. Never encrypt ciphertext a second time.
}

cntools_policy_key_matches() {
  local key="$1" directory="$2" derived='' hash=''
  local public="${directory}/${CNTOOLS_POLICY_VKEY_FILENAME:-policy.vkey}" script="${directory}/${CNTOOLS_POLICY_SCRIPT_FILENAME:-policy.script}"
  cntools_wallet_key_normal_envelope_valid "${key}" payment signing || return 1
  cntools_transaction_temp_file derived policy-open-public || return 1
  cntools_policy_cli '' key verification-key --signing-key-file "${key}" --verification-key-file "${derived}" || return 1
  cntools_wallet_key_normal_envelope_valid "${derived}" payment verification || return 1
  if [[ -e "${public}" || -L "${public}" ]]; then
    cntools_wallet_key_normal_envelope_valid "${public}" payment verification &&
      jq -es 'length==2 and (.[0].cborHex|ascii_downcase)==(.[1].cborHex|ascii_downcase)' "${derived}" "${public}" >/dev/null || return 1
  fi
  if [[ -e "${script}" || -L "${script}" ]]; then
    cntools_transaction_native_script_valid "${script}" &&
      cntools_policy_cli hash address key-hash --payment-verification-key-file "${derived}" || return 1
    jq -e --arg hash "${hash}" '[..|objects|select(.type=="sig")|.keyHash|ascii_downcase]|index($hash)!=null' "${script}" >/dev/null || return 1
  fi
}

cntools_policy_protection_cleanup() {
  # Interruption can never remove the last key copy after source retirement.
  if [[ -n "${CNTOOLS_POLICY_PROTECTION_SOURCE}" && -f "${CNTOOLS_POLICY_PROTECTION_SOURCE}" && ! -L "${CNTOOLS_POLICY_PROTECTION_SOURCE}" &&
        -n "${CNTOOLS_POLICY_PROTECTION_TARGET}" && -f "${CNTOOLS_POLICY_PROTECTION_TARGET}" && ! -L "${CNTOOLS_POLICY_PROTECTION_TARGET}" &&
        -O "${CNTOOLS_POLICY_PROTECTION_TARGET}" && -n "${CNTOOLS_POLICY_PROTECTION_STAGED}" &&
        "${CNTOOLS_POLICY_PROTECTION_TARGET}" -ef "${CNTOOLS_POLICY_PROTECTION_STAGED}" ]]; then
    rm -f -- "${CNTOOLS_POLICY_PROTECTION_TARGET}" || true
  fi
  cntools_policy_locks_restore || true
  CNTOOLS_POLICY_PROTECTION_SOURCE=''; CNTOOLS_POLICY_PROTECTION_TARGET=''; CNTOOLS_POLICY_PROTECTION_STAGED=''
  cntools_policy_files_cleanup
}

cntools_policy_protect() {
  local directory="$1" operation="$2" password="${3:-}" source='' target='' snapshot='' staged='' errors='' roundtrip='' binary='' status=0
  CNTOOLS_POLICY_ERROR=''; CNTOOLS_POLICY_WARNING=''; CNTOOLS_POLICY_UNLOCKED=()
  cntools_policy_protection_preflight "${directory}" "${operation}" || {
    [[ -n "${CNTOOLS_POLICY_ERROR}" ]] || cntools_policy_error 'The policy directory must be owned, writable and protected from group/public writes.'; return 1;
  }
  source="${directory}/${CNTOOLS_POLICY_SKEY_FILENAME:-policy.skey}"; target="${source}.gpg"
  [[ "${operation}" != decrypt ]] || { source="${target}"; target="${directory}/${CNTOOLS_POLICY_SKEY_FILENAME:-policy.skey}"; }
  if [[ -e "${source}" ]]; then
    [[ -n "${password}" && "${password}" != *$'\n'* && "${password}" != *$'\r'* ]] &&
      { [[ "${operation}" != encrypt ]] || (( ${#password} >= 12 )); } || { cntools_policy_error 'New encryption requires at least 12 characters; decryption accepts any nonempty single-line password.'; return 1; }
    binary="$(type -P gpg || type -P gpg2 || true)"; [[ -n "${binary}" ]] || { cntools_policy_error 'GnuPG is required for policy key encryption/decryption.'; return 1; }
    cntools_policy_public_file "${source}" 1048576 || return 1
    cntools_policy_work_into snapshot "${directory}" && cntools_policy_work_into staged "${directory}" &&
      cntools_policy_work_into errors "${directory}" || return 1
    cntools_run_command 0000 -- cp -- "${source}" "${snapshot}" || return 1
    cntools_key_crypto_run "${binary}" "${operation}" "${snapshot}" "${staged}" "${password}" "${errors}" 60 65536 || status=$?
    if ((status != 0)); then
      cntools_transaction_log_cli_failure 'Policy GPG operation failed; original key retained' "${status}" "${errors}" ''
      cntools_policy_error 'The policy key could not be opened/protected. Check the password and GPG installation.'; return 1
    fi
    if [[ "${operation}" == encrypt ]]; then
      cntools_policy_work_into roundtrip "${directory}" || return 1
      cntools_key_crypto_run "${binary}" decrypt "${staged}" "${roundtrip}" "${password}" "${errors}" 60 65536 &&
        cmp -s "${snapshot}" "${roundtrip}" && cntools_policy_key_matches "${roundtrip}" "${directory}" || { cntools_policy_error 'Policy encryption could not be round-trip verified.'; return 1; }
    else
      cntools_policy_key_matches "${staged}" "${directory}" || { cntools_policy_error 'The decrypted policy key is invalid or does not match the policy.'; return 1; }
    fi
    cntools_policy_locks_unlock "${directory}" || return 1
    cntools_policy_public_file "${source}" 1048576 && cmp -s "${source}" "${snapshot}" &&
      [[ ! -e "${target}" && ! -L "${target}" ]] || { cntools_policy_error 'The policy key changed during preparation. Nothing was replaced.'; return 1; }
    cntools_run_command 00000 -- ln -T -- "${staged}" "${target}" || return 1
    CNTOOLS_POLICY_PROTECTION_SOURCE="${source}"; CNTOOLS_POLICY_PROTECTION_TARGET="${target}"; CNTOOLS_POLICY_PROTECTION_STAGED="${staged}"
    if ! cntools_run_command 0000 -- rm -f -- "${source}"; then
      cntools_policy_protection_cleanup
      cntools_policy_error 'The original policy key could not be retired. Original protection was retained.'; return 1
    fi
    CNTOOLS_POLICY_PROTECTION_SOURCE=''; CNTOOLS_POLICY_PROTECTION_TARGET=''; CNTOOLS_POLICY_PROTECTION_STAGED=''
  else
    cntools_policy_locks_unlock "${directory}" || return 1
  fi
  CNTOOLS_POLICY_UNLOCKED=()
  # Remove work files before applying immutable flags to published artifacts.
  local -a CNTOOLS_POLICY_STAGES=()
  cntools_policy_files_cleanup
  cntools_policy_locks_apply "${directory}" "${operation}" || status=$?
  cntools_policy_files_cleanup
  cntools_transaction_log POLICY "Protection policy=${directory##*/} operation=${operation} lock=${CNTOOLS_POLICY_LOCK_METHOD} warning=${CNTOOLS_POLICY_WARNING:-none}"
  return "${status}"
}
