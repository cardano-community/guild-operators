#!/usr/bin/env bash
# DRep keys belong to the selected wallet, never to its payment/stake key chain.
# Creation is staged and no-clobber; inspection only fills missing public files.
# shellcheck disable=SC2034
CNTOOLS_DREP_KEY_ERROR=""
CNTOOLS_DREP_KEY_ID=""
CNTOOLS_DREP_KEY_HASH=""
CNTOOLS_DREP_KEY_KIND=""
CNTOOLS_DREP_KEY_PATH=""
CNTOOLS_DREP_KEY_VERIFIED=N

cntools_drep_key_error() {
  CNTOOLS_DREP_KEY_ERROR="$1"
  cntools_log ERROR "$1" || true
}

cntools_drep_key_filenames_into() {
  local -n dk_names="$1"
  local name="" reserved=""
  local -A seen=()
  dk_names=("${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}"
    "${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}"
    "${CNTOOLS_WALLET_DREP_ID_FILENAME:-drep.id}" drep.derivation.path)
  for name in "${dk_names[@]}"; do
    [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "${name}" != *.gpg && -z "${seen[${name}]+x}" ]] || return 1
    seen["${name}"]=1
    for reserved in "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" "${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" \
      "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" "${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" \
      "${CNTOOLS_WALLET_DERIVATION_PATH_FILENAME}" "${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}" \
      "${CNTOOLS_WALLET_DREP_SCRIPT_FILENAME:-drep.script}" \
      "${CNTOOLS_WALLET_PAY_ADDR_FILENAME}" "${CNTOOLS_WALLET_BASE_ADDR_FILENAME}" "${CNTOOLS_WALLET_STAKE_ADDR_FILENAME}" \
      "${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}" "${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}" \
      "${CNTOOLS_WALLET_PAY_CRED_FILENAME:-payment.cred}" "${CNTOOLS_WALLET_STAKE_CRED_FILENAME:-stake.cred}" \
      "${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}" "${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}"; do
      [[ "${name}" != "${reserved}" ]] || return 1
    done
  done
}

cntools_wallet_drep_id_validate() {
  local id="" canonical="" kind="" hash=""
  cntools_wallet_safe_regular_file "$1" 256 || return 1
  id="$(jq -Rers 'select(test("^drep1[023456789acdefghjklmnpqrstuvwxyz]+\\n?$")) | sub("\\n$"; "")' "$1")" || return 1
  [[ "${id}" != *[[:space:]]* ]] || return 1
  cntools_drep_id_into canonical kind hash "${id}" && [[ "${kind}" == key ]]
}

cntools_drep_key_id_into() {
  local output_name="$1" directory="$2" vkey="$3" output="" errors="" raw="" canonical="" kind="" hash="" status=0
  cntools_wallet_key_normal_envelope_valid "${vkey}" drep verification || return 1
  cntools_wallet_material_temp_file output "${directory}" drep-id || return 1
  cntools_wallet_material_temp_file errors "${directory}" drep-id-errors || return 1
  cntools_wallet_material_run_cli "${errors}" -- "${CNTOOLS_CLI}" latest governance drep id \
    --drep-verification-key-file "${vkey}" --output-cip129 --out-file "${output}" || status=$?
  if ((status != 0)); then
    cntools_wallet_material_log_cli_failure 'DRep ID generation failed' "${status}" "${errors}"; return 1
  fi
  cntools_wallet_drep_id_validate "${output}" || return 1
  raw="$(< "${output}")"
  cntools_drep_id_into canonical kind hash "${raw}" || return 1
  printf -v "${output_name}" '%s' "${canonical}"
}

cntools_drep_key_preflight() {
  local directory="$1" type="" name=""
  local -a names=()
  cntools_drep_key_filenames_into names || { cntools_drep_key_error 'Conflicting or unsafe DRep filenames.'; return 1; }
  cntools_wallet_protection_entries_safe "${directory}" || {
    cntools_drep_key_error "${CNTOOLS_WALLET_PROTECTION_ERROR:-Unsafe wallet directory.}"; return 1;
  }
  type="$(cntools_wallet_type "${directory}")" || return 1
  [[ "${type}" == CLI || "${type}" == Mnemonic ]] || {
    cntools_drep_key_error 'Select a CLI or mnemonic wallet. Hardware and multisig DRep key creation are not supported yet.'; return 1;
  }
  [[ "$(cntools_wallet_protection "${directory}")" == Open ]] || {
    cntools_drep_key_error 'Decrypt this wallet before adding a DRep key, then encrypt it again afterwards.'; return 1;
  }
  for name in "${names[@]}" "${names[0]}.gpg" "${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}" \
    "${CNTOOLS_WALLET_DREP_SCRIPT_FILENAME:-drep.script}" "${CNTOOLS_WALLET_DREP_REGISTER_CERT_FILENAME:-drep-reg.cert}" \
    "${CNTOOLS_WALLET_DREP_RETIRE_CERT_FILENAME:-drep-ret.cert}"; do
    if cntools_wallet_material_entry_exists "${directory}/${name}"; then
      cntools_drep_key_error "Existing DRep material was retained (${name}). Use Info & Status to inspect it; keys are never replaced."
      return 1
    fi
  done
}

cntools_drep_key_publish() {
  local directory="$1" stage="$2" name="" published=""
  local -a names=() linked=()
  cntools_wallet_create_stage_safe "${stage}" && cntools_drep_key_preflight "${directory}" || return 1
  cntools_drep_key_filenames_into names || return 1
  [[ -f "${stage}/${names[3]}" ]] || unset 'names[3]'
  for name in "${names[@]}"; do
    if ! chmod 0600 "${stage}/${name}" || ! ln -T -- "${stage}/${name}" "${directory}/${name}" 2>/dev/null; then
      # Roll back only links made by this invocation, never a racing replacement.
      for published in "${linked[@]}"; do
        if [[ ! -L "${directory}/${published}" && "${directory}/${published}" -ef "${stage}/${published}" ]]; then
          rm -f -- "${directory}/${published}" || true
        fi
      done
      cntools_drep_key_error 'DRep publication failed; existing files were not overwritten. Inspect Info & Status before retrying.'
      return 1
    fi
    linked+=("${name}")
  done
}

cntools_drep_key_create() {
  local directory="$1" method="$2" account="${3:-0}" phrase="${4:-}" stage="" errors="" id="" status=0
  local -a names=()
  CNTOOLS_DREP_KEY_ERROR=""
  [[ "${CNTOOLS_CLI:-}" == /* && -x "${CNTOOLS_CLI}" && ! -d "${CNTOOLS_CLI}" ]] || {
    cntools_drep_key_error 'Cardano CLI is required to create or derive DRep keys.'; return 1;
  }
  cntools_drep_key_preflight "${directory}" || return 1
  cntools_drep_key_filenames_into names || return 1
  [[ "${method}" == cli || "${method}" == mnemonic ]] || return 2
  cntools_wallet_mnemonic_index_into account "${account}" || return 2
  cntools_wallet_create_stage_into stage || { cntools_drep_key_error 'Could not create private key staging.'; return 1; }
  if [[ "${method}" == mnemonic ]]; then
    cntools_wallet_mnemonic_derive_role "${stage}" drep "${account}" 0 "${phrase}" || status=$?
    unset phrase
    if ((status == 0)); then
      printf '1852H/1815H/%sH/3/0\n' "${account}" > "${stage}/${names[3]}" || status=1
    fi
  else
    cntools_wallet_material_temp_file errors "${stage}" drep-key-errors || return 1
    cntools_wallet_material_run_cli "${errors}" -- "${CNTOOLS_CLI}" latest governance drep key-gen \
      --signing-key-file "${stage}/${names[0]}" --verification-key-file "${stage}/${names[1]}" || status=$?
    ((status == 0)) || cntools_wallet_material_log_cli_failure 'DRep key generation failed' "${status}" "${errors}"
  fi
  if ((status == 0)); then
    cntools_wallet_key_materialize_role "${stage}" drep "${names[0]}" "${names[1]}" \
      "${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}" || status=1
  fi
  if ((status == 0)); then
    if [[ "${method}" == mnemonic ]]; then
      cntools_wallet_key_extended_pair_matches "${stage}" drep "${stage}/${names[0]}" "${stage}/${names[1]}" || status=1
    else
      cntools_wallet_key_normal_pair_matches "${stage}" drep "${stage}/${names[0]}" "${stage}/${names[1]}" || status=1
    fi
  fi
  if ((status == 0)); then
    cntools_drep_key_id_into id "${stage}" "${stage}/${names[1]}" &&
      printf '%s\n' "${id}" > "${stage}/${names[2]}" || status=1
  fi
  if ((status == 0)); then cntools_drep_key_publish "${directory}" "${stage}" || status=1; fi
  cntools_wallet_material_cleanup
  cntools_wallet_create_remove_stage "${stage}" || status=1
  if ((status != 0)); then
    [[ -n "${CNTOOLS_DREP_KEY_ERROR}" ]] || cntools_drep_key_error 'DRep key creation failed validation. No existing keys were replaced; see the log.'
    return 1
  fi
  cntools_log WALLET "DRep keys created wallet=${directory##*/} method=${method} account=${account} id=${id}" || true
}

cntools_drep_key_inspect() {
  local directory="$1" cached="" derived="" kind="" hash="" temporary="" path="" form="" entry="" cli_available=N
  local -a names=()
  CNTOOLS_DREP_KEY_ERROR="" CNTOOLS_DREP_KEY_ID="" CNTOOLS_DREP_KEY_HASH="" CNTOOLS_DREP_KEY_KIND="" CNTOOLS_DREP_KEY_PATH=""
  CNTOOLS_DREP_KEY_VERIFIED=N
  cntools_wallet_directory_safe "${directory}" && cntools_drep_key_filenames_into names || return 1
  [[ -z "${CNTOOLS_CLI:-}" || ! -x "${CNTOOLS_CLI}" ]] || cli_available=Y
  for entry in "${names[@]}" "${names[0]}.gpg" "${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}"; do
    if cntools_wallet_material_entry_exists "${directory}/${entry}"; then
      cntools_wallet_safe_regular_file "${directory}/${entry}" 1048576 || {
        cntools_drep_key_error "Unsafe DRep artifact retained: ${entry}"; return 1;
      }
    fi
  done
  if [[ -e "${directory}/${names[0]}" && ( -e "${directory}/${names[0]}.gpg" ||
        -e "${directory}/${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}" ) ]]; then
    cntools_drep_key_error 'Conflicting DRep signing material. Existing files were retained.'; return 1
  fi
  if cntools_wallet_material_entry_exists "${directory}/${CNTOOLS_WALLET_DREP_SCRIPT_FILENAME:-drep.script}"; then
    if declare -F cntools_drep_script_inspect >/dev/null; then
      cntools_drep_script_inspect "${directory}"; return $?
    fi
    cntools_drep_key_error 'Script DRep inspection requires the DRep script library.'; return 1
  fi
  if [[ "${cli_available}" == Y ]]; then
    cntools_wallet_key_materialize_role "${directory}" drep "${names[0]}" "${names[1]}" \
      "${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}" || return 1
  fi
  if cntools_wallet_material_entry_exists "${directory}/${names[1]}"; then
    cntools_wallet_key_normal_envelope_valid "${directory}/${names[1]}" drep verification || {
      cntools_drep_key_error "Invalid DRep verification key: ${names[1]}. Existing files were retained."; return 1;
    }
    if [[ "${cli_available}" == Y ]]; then
      cntools_drep_key_id_into derived "${directory}" "${directory}/${names[1]}" || return 1
    fi
  fi
  if cntools_wallet_material_entry_exists "${directory}/${names[2]}"; then
    cntools_wallet_drep_id_validate "${directory}/${names[2]}" || {
      cntools_drep_key_error 'Invalid DRep ID file; existing material was retained.'; return 1;
    }
    cached="$(< "${directory}/${names[2]}")"
    cntools_drep_id_into cached kind hash "${cached}" || return 1
    [[ -z "${derived}" || "${cached}" == "${derived}" ]] || {
      cntools_drep_key_error 'The DRep ID does not match the verification key. Neither was changed.'; return 1;
    }
  elif [[ -n "${derived}" ]]; then
    cntools_wallet_material_temp_file temporary "${directory}" drep-id-cache || return 1
    printf '%s\n' "${derived}" > "${temporary}" || return 1
    cntools_wallet_material_publish "${temporary}" "${directory}/${names[2]}" cntools_wallet_drep_id_validate || return 1
    cached="$(< "${directory}/${names[2]}")"
    cntools_drep_id_into cached kind hash "${cached}" || return 1
    [[ "${cached}" == "${derived}" ]] || { cntools_drep_key_error 'DRep ID changed while inspecting the wallet.'; return 1; }
  fi
  [[ -n "${cached}" ]] || return 4
  if [[ -f "${directory}/${names[0]}" ]]; then
    cntools_wallet_key_signing_type drep "${directory}/${names[0]}" form || {
      cntools_drep_key_error "Invalid DRep signing key: ${names[0]}. Existing files were retained."; return 1;
    }
    if [[ "${cli_available}" != Y ]]; then
      : # Cached inspection only; no cryptographic pair verification is claimed.
    elif [[ "${form}" == extended ]]; then
      cntools_wallet_key_extended_pair_matches "${directory}" drep "${directory}/${names[0]}" "${directory}/${names[1]}" || {
        cntools_drep_key_error 'The extended DRep signing and verification keys could not be verified as a pair.'; return 1;
      }
    else
      cntools_wallet_key_normal_pair_matches "${directory}" drep "${directory}/${names[0]}" "${directory}/${names[1]}" || {
        cntools_drep_key_error 'The DRep signing and verification keys could not be verified as a pair.'; return 1;
      }
    fi
  fi
  if cntools_wallet_material_entry_exists "${directory}/${names[3]}"; then
    cntools_wallet_safe_regular_file "${directory}/${names[3]}" 128 || return 1
    path="$(jq -Rers 'select(test("^1852H/1815H/[0-9]+H/3/0\\n?$")) | sub("\\n$"; "")' "${directory}/${names[3]}")" || {
      cntools_drep_key_error 'Invalid recorded DRep derivation path. Existing files were retained.'; return 1;
    }
    [[ "${path}" =~ ^1852H/1815H/([0-9]+)H/3/0$ ]] || return 1
    cntools_wallet_mnemonic_index_into form "${BASH_REMATCH[1]}" || return 1
    CNTOOLS_DREP_KEY_PATH="${path}"
  fi
  [[ -z "${derived}" ]] || CNTOOLS_DREP_KEY_VERIFIED=Y
  cntools_drep_id_into CNTOOLS_DREP_KEY_ID CNTOOLS_DREP_KEY_KIND CNTOOLS_DREP_KEY_HASH "${cached}"
}
