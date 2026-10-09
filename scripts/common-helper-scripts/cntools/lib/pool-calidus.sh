#!/usr/bin/env bash
# Separate Calidus identity, staged and validated before missing-only publication.
# Never reads/replaces cold, KES or VRF signing keys, nor submits transactions.
# shellcheck disable=SC2034,SC2015
declare -ag CNTOOLS_CALIDUS_LINK_SOURCES=() CNTOOLS_CALIDUS_LINK_TARGETS=()
CNTOOLS_CALIDUS_ID='' CNTOOLS_CALIDUS_PUBLIC='' CNTOOLS_CALIDUS_STATE='Missing'

cntools_calidus_names_into() {
  local -n cn_names="$1"
  local cn_name='' cn_kind=''
  cn_names=()
  cntools_pool_filenames_validate || return 1
  for cn_kind in calidus-skey calidus-vkey calidus-id; do
    cntools_pool_file_name_into cn_name "${cn_kind}" || return 1
    [[ "${cn_name}" != *.gpg && "${cn_name}" != *.previous ]] || return 1
    cn_names+=("${cn_name}")
  done
}

cntools_calidus_signing_valid() {
  cntools_transaction_private_file_safe "$1" &&
    { cntools_wallet_key_normal_envelope_valid "$1" payment signing ||
      cntools_wallet_key_extended_envelope_valid "$1" payment signing; }
}

# Normalize only a private staging copy. Existing extended verification keys
# stay intact, and comparisons use their normal 32-byte public identity.
cntools_calidus_public_normalize() {
  local source="$1" destination="$2"
  if cntools_wallet_key_normal_envelope_valid "${source}" payment verification; then
    cp -- "${source}" "${destination}" || return 1
  elif cntools_wallet_key_extended_envelope_valid "${source}" payment verification; then
    cntools_pool_cli key non-extended-key --extended-verification-key-file "${source}" --verification-key-file "${destination}" || return 1
  else return 1
  fi
  chmod 0600 "${destination}" && cntools_wallet_key_normal_envelope_valid "${destination}" payment verification
}

cntools_calidus_public_from_signing() {
  local source="$1" destination="$2" derived=''
  cntools_calidus_signing_valid "${source}" && cntools_transaction_temp_file derived calidus-derived || return 1
  cntools_pool_cli key verification-key --signing-key-file "${source}" --verification-key-file "${derived}" &&
    cntools_calidus_public_normalize "${derived}" "${destination}"
}

# Validate staged plaintext against optional cached public artifacts. GPG
# protection never needs to publish the clear key just to check its identity.
cntools_calidus_signing_matches() {
  local signing="$1" directory="$2" public='' normalized='' expected='' frozen=''
  local -a names=()
  cntools_calidus_names_into names && cntools_transaction_temp_file public calidus-protection-public &&
    cntools_calidus_public_from_signing "${signing}" "${public}" || return 1
  if [[ -e "${directory}/${names[1]}" || -L "${directory}/${names[1]}" ]]; then
    cntools_transaction_snapshot_into frozen "${directory}/${names[1]}" 65536 calidus-protection-verification &&
      cntools_transaction_temp_file normalized calidus-protection-normal &&
      cntools_calidus_public_normalize "${frozen}" "${normalized}" &&
      jq -es 'length==2 and (.[0].cborHex|ascii_downcase)==(.[1].cborHex|ascii_downcase)' "${public}" "${normalized}" >/dev/null || return 1
  fi
  if [[ -e "${directory}/${names[2]}" || -L "${directory}/${names[2]}" ]]; then
    cntools_pool_public_file_safe "${directory}/${names[2]}" 256 && cntools_calidus_id_into expected "${public}" &&
      [[ "$(< "${directory}/${names[2]}")" == "${expected}" ]] || return 1
  fi
}

cntools_calidus_inspect() {
  local directory="$1" frozen='' public='' derived='' expected='' cached='' name='' present=N
  local signing_snapshot='' verification_snapshot=''
  local -a names=()
  CNTOOLS_CALIDUS_ID='' CNTOOLS_CALIDUS_PUBLIC='' CNTOOLS_CALIDUS_STATE=Missing
  CNTOOLS_POOL_WRITE_ERROR=''
  cntools_calidus_names_into names && [[ -d "${directory}" && ! -L "${directory}" && -O "${directory}" ]] &&
    cntools_transaction_path_components_safe "${directory}" && cntools_transaction_directory_ancestry_safe "${directory}" ||
    { cntools_pool_write_error 'Unsafe pool directory or conflicting Calidus filenames.'; return 1; }
  if [[ -e "${directory}/${names[0]}.gpg" || -L "${directory}/${names[0]}.gpg" ]]; then
    [[ ! -e "${directory}/${names[0]}" && ! -L "${directory}/${names[0]}" ]] ||
      { cntools_pool_write_error 'Both clear and encrypted Calidus signing keys exist. Neither was changed.'; return 1; }
    cntools_pool_public_file_safe "${directory}/${names[0]}.gpg" ||
      { cntools_pool_write_error 'Unsafe encrypted Calidus key.'; return 1; }
    CNTOOLS_CALIDUS_STATE=Encrypted
  elif [[ -e "${directory}/${names[0]}" || -L "${directory}/${names[0]}" ]]; then
    CNTOOLS_CALIDUS_STATE=Open
  fi
  for name in "${names[@]}"; do
    [[ ! -e "${directory}/${name}" && ! -L "${directory}/${name}" ]] || present=Y
  done
  [[ "${present}" == Y || "${CNTOOLS_CALIDUS_STATE}" != Missing ]] || return 0
  cntools_transaction_require_cli || { cntools_pool_write_error 'Cardano CLI is required to validate Calidus identity; no node connection is needed.'; return 1; }
  cntools_transaction_temp_file public calidus-public || return 1
  if [[ "${CNTOOLS_CALIDUS_STATE}" == Open ]]; then
    cntools_calidus_signing_valid "${directory}/${names[0]}" &&
      cntools_transaction_snapshot_into frozen "${directory}/${names[0]}" 65536 calidus-signing &&
      cntools_calidus_public_from_signing "${frozen}" "${public}" ||
      { cntools_pool_write_error 'Invalid Calidus signing key or public derivation failed.'; return 1; }
    signing_snapshot="${frozen}"
  fi
  if [[ -e "${directory}/${names[1]}" || -L "${directory}/${names[1]}" ]]; then
    cntools_transaction_snapshot_into frozen "${directory}/${names[1]}" 65536 calidus-verification &&
      cntools_transaction_temp_file derived calidus-normal && cntools_calidus_public_normalize "${frozen}" "${derived}" ||
      { cntools_pool_write_error 'Invalid Calidus verification key.'; return 1; }
    verification_snapshot="${frozen}"
    if [[ "${CNTOOLS_CALIDUS_STATE}" == Open ]]; then
      jq -es 'length == 2 and (.[0].cborHex|ascii_downcase) == (.[1].cborHex|ascii_downcase)' "${public}" "${derived}" >/dev/null ||
        { cntools_pool_write_error 'Calidus signing and verification keys do not match. Existing files were retained.'; return 1; }
    else
      cp -- "${derived}" "${public}" || return 1
      [[ "${CNTOOLS_CALIDUS_STATE}" != Missing ]] || CNTOOLS_CALIDUS_STATE='Public only'
    fi
  elif [[ "${CNTOOLS_CALIDUS_STATE}" != Open ]]; then
    cntools_pool_write_error 'A Calidus verification key is needed to inspect this identity.'; return 1
  fi
  cntools_calidus_id_into expected "${public}" &&
    cntools_transaction_key_id_from_verification_file_into CNTOOLS_CALIDUS_PUBLIC "${public}" ||
    { cntools_pool_write_error 'Calidus public identity derivation failed; see the command log.'; return 1; }
  if [[ -e "${directory}/${names[2]}" || -L "${directory}/${names[2]}" ]]; then
    cntools_pool_public_file_safe "${directory}/${names[2]}" 256 ||
      { cntools_pool_write_error 'Unsafe or unreadable cached Calidus ID.'; return 1; }
    cached="$(< "${directory}/${names[2]}")"
    [[ "${cached}" == "${expected}" ]] ||
      { cntools_pool_write_error 'The cached Calidus ID does not match the verification key. Neither was changed.'; return 1; }
  fi
  # Do not report the frozen identity as the current one after a path swap.
  if [[ -n "${signing_snapshot}" ]] &&
    { ! cntools_calidus_signing_valid "${directory}/${names[0]}" || ! cmp -s -- "${signing_snapshot}" "${directory}/${names[0]}"; }; then
    cntools_pool_write_error 'The Calidus signing key changed during inspection.'; return 1
  fi
  if [[ -n "${verification_snapshot}" ]] &&
    { ! cntools_pool_public_file_safe "${directory}/${names[1]}" || ! cmp -s -- "${verification_snapshot}" "${directory}/${names[1]}"; }; then
    cntools_pool_write_error 'The Calidus verification key changed during inspection.'; return 1
  fi
  CNTOOLS_CALIDUS_ID="${expected}"
}

cntools_calidus_preflight() {
  local directory="$1" operation="$2" cold='' name=''
  local -a names=()
  CNTOOLS_POOL_WRITE_ERROR=''
  cntools_calidus_names_into names && cntools_pool_directory_writable "${CNTOOLS_POOL_DIR:-}" &&
    [[ "${directory%/*}" == "${CNTOOLS_POOL_DIR%/}" && "${directory##*/}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] &&
    cntools_pool_directory_writable "${directory}" ||
    { cntools_pool_write_error 'The pool must be owned, writable, directly inside the pool root and protected from group/public writes.'; return 1; }
  if [[ "${operation}" != repair ]]; then
    for name in "${names[@]}" "${names[0]}.gpg"; do
      [[ ! -e "${directory}/${name}" && ! -L "${directory}/${name}" ]] ||
        { cntools_pool_write_error 'Existing Calidus material was retained. Use Info & Status or repair missing public files.'; return 1; }
    done
  fi
  if [[ "${operation}" == create || "${operation}" == signing ]]; then
    cntools_pool_file_name_into cold cold-skey || return 1
    [[ ! -e "${directory}/${cold}.gpg" && ! -L "${directory}/${cold}.gpg" ]] ||
      { cntools_pool_write_error 'Unlock the pool before adding an unencrypted Calidus signing key.'; return 1; }
  fi
  cntools_transaction_require_cli
}

cntools_calidus_publication_cleanup() {
  local index=0 source='' target='' status=0
  for index in "${!CNTOOLS_CALIDUS_LINK_SOURCES[@]}"; do
    source="${CNTOOLS_CALIDUS_LINK_SOURCES[index]}"; target="${CNTOOLS_CALIDUS_LINK_TARGETS[index]}"
    cntools_transaction_path_components_safe "${source}" && cntools_transaction_path_components_safe "${target}" || { status=1; continue; }
    [[ -f "${source}" && ! -L "${source}" && -O "${source}" ]] || continue
    [[ -f "${target}" && ! -L "${target}" && -O "${target}" && "${target}" -ef "${source}" ]] || continue
    rm -f -- "${target}" || status=1
  done
  CNTOOLS_CALIDUS_LINK_SOURCES=(); CNTOOLS_CALIDUS_LINK_TARGETS=()
  return "${status}"
}

cntools_calidus_publish() {
  local directory="$1" stage="$2" name=''
  shift 2
  for name in "$@"; do
    if ! cntools_pool_directory_writable "${directory}" || ! cntools_pool_directory_writable "${stage}"; then
      cntools_calidus_publication_cleanup || true
      cntools_pool_write_error 'A Calidus directory became unsafe during publication.'; return 1
    fi
    CNTOOLS_CALIDUS_LINK_SOURCES+=("${stage}/${name}"); CNTOOLS_CALIDUS_LINK_TARGETS+=("${directory}/${name}")
    if ! chmod 0600 "${stage}/${name}" || ! ln -T -- "${stage}/${name}" "${directory}/${name}" 2>/dev/null; then
      cntools_calidus_publication_cleanup || true
      cntools_pool_write_error 'Calidus publication failed. No existing files were overwritten; partial new files were removed.'; return 1
    fi
  done
  CNTOOLS_CALIDUS_LINK_SOURCES=(); CNTOOLS_CALIDUS_LINK_TARGETS=()
  cntools_transaction_log POOL "Calidus public files ready pool=${directory##*/} id=${CNTOOLS_CALIDUS_ID}"
}

cntools_calidus_prepare_files() {
  local directory="$1" operation="$2" source="${3:-}" stage='' frozen='' name='' saved='' status=0
  local -a names=() publish=()
  [[ "${operation}" == create || "${operation}" == signing || "${operation}" == verification || "${operation}" == repair ]] || return 2
  cntools_calidus_preflight "${directory}" "${operation}" && cntools_calidus_names_into names && cntools_pool_stage_into stage || return 1
  case "${operation}" in
    create)
      saved="$(umask)"; umask 077
      cntools_pool_cli address key-gen --signing-key-file "${stage}/${names[0]}" --verification-key-file "${stage}/${names[1]}" || status=$?
      umask "${saved}"; ((status == 0)) || return 1 ;;
    signing|verification)
      if [[ "${operation}" == signing ]] && ! cntools_calidus_signing_valid "${source}"; then
        cntools_pool_write_error 'Use an owned, private normal or extended payment signing key envelope.'; return 1
      fi
      [[ "${source}" == /* ]] && cntools_transaction_snapshot_into frozen "${source}" 65536 calidus-import ||
        { cntools_pool_write_error 'Use an absolute path to a safe, regular Cardano key envelope.'; return 1; }
      if [[ "${operation}" == signing ]]; then
        cntools_calidus_signing_valid "${source}" && cntools_calidus_signing_valid "${frozen}" &&
          cp -- "${frozen}" "${stage}/${names[0]}" || { cntools_pool_write_error 'Use a normal or extended payment signing key envelope.'; return 1; }
      else
        cntools_calidus_public_normalize "${frozen}" "${stage}/${names[1]}" || { cntools_pool_write_error 'Use a normal or extended payment verification key envelope.'; return 1; }
      fi ;;
    repair)
      cntools_calidus_inspect "${directory}" || return 1
      [[ "${CNTOOLS_CALIDUS_STATE}" != Missing ]] || { cntools_pool_write_error 'No Calidus key exists to repair.'; return 1; }
      for name in "${names[@]}"; do
        [[ -e "${directory}/${name}" || -L "${directory}/${name}" ]] || continue
        cntools_transaction_snapshot_into frozen "${directory}/${name}" 65536 calidus-repair &&
          cp -- "${frozen}" "${stage}/${name}" || return 1
      done ;;
  esac
  if [[ ! -e "${stage}/${names[1]}" ]]; then
    cntools_calidus_public_from_signing "${stage}/${names[0]}" "${stage}/${names[1]}" || return 1
  fi
  cntools_calidus_inspect "${stage}" || return 1
  if [[ ! -e "${stage}/${names[2]}" ]]; then
    printf '%s\n' "${CNTOOLS_CALIDUS_ID}" > "${stage}/${names[2]}" || return 1
  fi
  cntools_calidus_preflight "${directory}" "${operation}" || return 1
  for name in "${names[@]}"; do
    [[ -e "${stage}/${name}" ]] || continue
    if [[ -e "${directory}/${name}" || -L "${directory}/${name}" ]]; then
      [[ "${operation}" == repair ]] && cntools_pool_public_file_safe "${directory}/${name}" && cmp -s -- "${stage}/${name}" "${directory}/${name}" ||
        { cntools_pool_write_error 'Calidus files changed during preparation. Nothing was replaced.'; return 1; }
    else publish+=("${name}")
    fi
  done
  cntools_calidus_publish "${directory}" "${stage}" "${publish[@]}"
}

cntools_calidus_prepare() {
  local status=0
  CNTOOLS_POOL_WRITE_ERROR='' CNTOOLS_TRANSACTION_ERROR=''
  cntools_calidus_prepare_files "$@" || status=$?
  if ((status != 0)) && [[ -z "${CNTOOLS_POOL_WRITE_ERROR}" ]]; then
    cntools_pool_write_error "${CNTOOLS_TRANSACTION_ERROR:-Calidus key setup failed; existing files were retained.}" || true
  fi
  return "${status}"
}
