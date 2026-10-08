#!/usr/bin/env bash
# Offline single-signer native policies. Never logs signing-key contents.
# shellcheck disable=SC2034,SC2015
cntools_policy_expiry_into() {
  local output="$1" duration="$2" normalized='' reference=''
  cntools_number_normalize_into normalized "${duration:-0}" &&
    [[ "${normalized}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 2
  if [[ "${normalized}" == 0 ]]; then printf -v "${output}" '%s' 0; return 0; fi
  reference="$(cntools_health_reference_slot "${CNTOOLS_NETWORK:-}")" || return 1
  [[ "${reference}" =~ ^[0-9]{1,12}$ ]] || return 1
  # Supported network slots are one second; bound both dates and exact jq ints.
  (( reference + normalized <= 9999999999999 )) || return 1
  printf -v "${output}" '%s' "$((reference + normalized))"
}

cntools_policy_expiry_valid() {
  local expiry="$1" reference=''
  [[ "${expiry}" =~ ^(0|[1-9][0-9]{0,12})$ ]] || return 2
  [[ "${expiry}" != 0 ]] || return 0
  reference="$(cntools_health_reference_slot "${CNTOOLS_NETWORK:-}")" || return 1
  [[ "${reference}" =~ ^[0-9]{1,12}$ ]] && ((expiry > reference))
}

cntools_policy_cli() {
  local output="$1" response='' errors='' status=0 content=''
  shift
  cntools_transaction_temp_file response policy-command-output &&
    cntools_transaction_temp_file errors policy-command-error || return 1
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" "$@" || status=$?
  if ((status != 0)); then
    cntools_transaction_log_cli_failure 'Policy command failed' "${status}" "${errors}" "${response}"
    cntools_policy_error "${CNTOOLS_TRANSACTION_ERROR}"; return 1
  fi
  # Only hashing commands use stdout; key generation/derivation writes files.
  if [[ -n "${output}" ]]; then
    [[ $(wc -c < "${response}") -le 128 ]] || return 1
    content="$(< "${response}")"
    [[ "${content}" =~ ^[0-9a-f]{56}$ ]] || return 1
    printf -v "${output}" '%s' "${content}"
  fi
}

cntools_policy_create() {
  local name="$1" expiry="$2" stage='' skey='' vkey='' script='' id_file='' derived='' key_hash='' policy_id='' checked_id='' saved=''
  CNTOOLS_POLICY_ERROR=''; CNTOOLS_POLICY_DIRECTORY=''; CNTOOLS_POLICY_ID=''
  cntools_policy_preflight "${name}" || return 1
  cntools_policy_expiry_valid "${expiry}" || { cntools_policy_error 'The reviewed policy expiry is invalid or has already passed. Start again to choose a new expiry.'; return 1; }
  cntools_policy_stage_into stage || { cntools_policy_error 'Could not create private policy staging.'; return 1; }
  skey="${stage}/${CNTOOLS_POLICY_SKEY_FILENAME:-policy.skey}"
  vkey="${stage}/${CNTOOLS_POLICY_VKEY_FILENAME:-policy.vkey}"
  script="${stage}/${CNTOOLS_POLICY_SCRIPT_FILENAME:-policy.script}"
  id_file="${stage}/${CNTOOLS_POLICY_ID_FILENAME:-policy.id}"
  derived="${stage}/.cntools-policy-pair.vkey"
  # Isolate the private umask without losing the action's tracked temporary list.
  saved="$(umask)"; umask 077
  local status=0
  cntools_policy_cli '' address key-gen --verification-key-file "${vkey}" --signing-key-file "${skey}" || status=$?
  umask "${saved}"
  ((status == 0)) || return 1
  cntools_wallet_key_normal_envelope_valid "${skey}" payment signing &&
    cntools_wallet_key_normal_envelope_valid "${vkey}" payment verification || {
      cntools_policy_error 'The generated policy key envelopes are invalid.'; return 1;
    }
  cntools_policy_cli '' key verification-key --signing-key-file "${skey}" --verification-key-file "${derived}" || return 1
  cntools_wallet_key_normal_envelope_valid "${derived}" payment verification &&
    jq -es 'length == 2 and (.[0].cborHex | ascii_downcase) == (.[1].cborHex | ascii_downcase)' "${vkey}" "${derived}" >/dev/null || {
      cntools_policy_error 'The generated policy signing and verification keys do not match.'; return 1;
    }
  rm -f -- "${derived}" || return 1
  cntools_policy_cli key_hash address key-hash --payment-verification-key-file "${vkey}" || {
    [[ -n "${CNTOOLS_POLICY_ERROR}" ]] || cntools_policy_error 'Cardano CLI returned an invalid policy signer hash.'; return 1;
  }
  # Files live in the private stage; final permissions are normalized on publication.
  jq -n --arg hash "${key_hash}" --argjson expiry "${expiry}" '
    {type:"sig",keyHash:$hash} as $sig |
    if $expiry == 0 then $sig else {type:"all",scripts:[{type:"before",slot:$expiry},$sig]} end
  ' > "${script}" || return 1
  cntools_policy_cli policy_id latest transaction policyid --script-file "${script}" &&
    cntools_policy_cli checked_id hash script --script-file "${script}" || {
      [[ -n "${CNTOOLS_POLICY_ERROR}" ]] || cntools_policy_error 'Cardano CLI returned an invalid native policy ID.'; return 1;
    }
  [[ "${policy_id}" == "${checked_id}" ]] || { cntools_policy_error 'Native policy ID validation failed.'; return 1; }
  printf '%s\n' "${policy_id}" > "${id_file}" || return 1
  cntools_policy_expiry_valid "${expiry}" || { cntools_policy_error 'The policy expired during preparation. Nothing was published; choose a longer duration.'; return 1; }
  CNTOOLS_POLICY_ID="${policy_id}"
  cntools_policy_publish "${stage}" "${name}" || return 1
  cntools_transaction_log POLICY "Policy expiry slot=${expiry}"
}
