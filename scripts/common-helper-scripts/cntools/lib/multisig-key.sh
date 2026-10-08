#!/usr/bin/env bash
# Additional participant keys, never replacement keys for an existing wallet.
# shellcheck disable=SC2034,SC2015
CNTOOLS_MULTISIG_ERROR=''
CNTOOLS_MULTISIG_ADDRESS_TOOL=''
declare -ag CNTOOLS_MULTISIG_PUBLICATION_SOURCES=() CNTOOLS_MULTISIG_PUBLICATION_TARGETS=()

cntools_multisig_fail() { CNTOOLS_MULTISIG_ERROR="$1"; cntools_log ERROR "$1" || true; return 1; }

# Publication into an existing wallet cannot be a directory rename. Track
# each prospective link before creating it so action interruption can undo
# only our own inodes, before private staging is removed.
cntools_multisig_key_publication_cleanup() {
  local index=0 source='' target='' status=0
  for index in "${!CNTOOLS_MULTISIG_PUBLICATION_SOURCES[@]}"; do
    source="${CNTOOLS_MULTISIG_PUBLICATION_SOURCES[index]}"
    target="${CNTOOLS_MULTISIG_PUBLICATION_TARGETS[index]:-}"
    [[ -n "${target}" ]] || continue
    cntools_wallet_create_stage_safe "${source%/*}" || { status=1; continue; }
    [[ -f "${target}" && ! -L "${target}" && -O "${target}" && "${target}" -ef "${source}" ]] || continue
    rm -f -- "${target}" || status=1
  done
  CNTOOLS_MULTISIG_PUBLICATION_SOURCES=(); CNTOOLS_MULTISIG_PUBLICATION_TARGETS=()
  return "${status}"
}

# Canonicalise each component before passing a path to an external program.
cntools_multisig_path_into() {
  local -n ms_path_result="$1"
  local entered="$2" component='' number='' canonical='' suffix=''
  local -a components=()
  ms_path_result=''
  entered="${entered#m/}"
  [[ -n "${entered}" && "${entered}" != */ && "${entered}" != *//* ]] || return 2
  IFS=/ read -r -a components <<< "${entered}"
  (( ${#components[@]} >= 3 && ${#components[@]} <= 10 )) || return 2
  for component in "${components[@]}"; do
    suffix=''
    case "${component}" in *H|*h|*\') suffix=H; component="${component%?}" ;; esac
    cntools_wallet_mnemonic_index_into number "${component}" || return 2
    [[ -n "${component}" ]] || return 2
    canonical+="${canonical:+/}${number}${suffix}"
  done
  ms_path_result="${canonical}"
}

cntools_multisig_key_preflight() {
  local directory="$1" name='' mode='' prefix="${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}"
  CNTOOLS_MULTISIG_ERROR=''
  cntools_wallet_create_environment_ready && cntools_wallet_directory_safe "${directory}" &&
    cntools_wallet_create_directory_private "${directory}" || {
    cntools_multisig_fail "${CNTOOLS_WALLET_CREATE_ERROR:-The selected wallet directory is unsafe or not writable.}"; return 1;
  }
  for name in "${directory}"/*.gpg "${directory}"/*.skey "${directory}"/*.hwsfile; do
    [[ -e "${name}" || -L "${name}" ]] || continue
    if [[ "${name}" == *.gpg || -L "${name}" ]] ||
      ! cntools_wallet_create_mode_into mode "${name}" || (( (8#${mode} & 0200) == 0 )); then
      cntools_multisig_fail 'Decrypt/unlock this wallet before adding participant keys. Clear and encrypted key material must not be mixed.'; return 1
    fi
  done
  for name in "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" \
    "${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" "${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" \
    "${CNTOOLS_WALLET_PAY_CRED_FILENAME}" "${CNTOOLS_WALLET_STAKE_CRED_FILENAME}" \
    "${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}" "${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}" derivation.json; do
    [[ ! -e "${directory}/${prefix}${name}" && ! -L "${directory}/${prefix}${name}" &&
       ! -e "${directory}/${prefix}${name}.gpg" && ! -L "${directory}/${prefix}${name}.gpg" ]] || {
      cntools_multisig_fail 'Multisig participant artifacts already exist. Nothing will be overwritten.'; return 1;
    }
  done
}

cntools_multisig_address_tool_ready() {
  local resolved=''
  resolved="$(type -P "${CNTOOLS_MULTISIG_ADDRESS_TOOL:-cardano-address}" 2>/dev/null)" || {
    cntools_multisig_fail 'Mnemonic custom-path derivation requires cardano-address. Install the deployment companion before continuing.'; return 1;
  }
  [[ "${resolved}" == /* && -f "${resolved}" && -x "${resolved}" ]] || return 1
  CNTOOLS_MULTISIG_ADDRESS_TOOL="${resolved}"
}

# Secret input is stdin; secret-bearing stdout/stderr stays in private tracked
# files. Never copy derivation stderr into the log (it may echo seed words).
cntools_multisig_secret_command() {
  local output="$1" errors="$2" mask='' status=0
  shift 2
  printf -v mask '%*s' "$#" ''; mask="${mask// /0}"
  cntools_run_command_timeout "${CNTOOLS_CLI_TIMEOUT:-10}" "${mask}" -- "$@" \
    > "${output}" 2> "${errors}" || status=$?
  ((status == 0)) || {
    cntools_multisig_fail "Participant key derivation failed (status ${status}); secret-bearing output was suppressed."; return 1;
  }
}

cntools_multisig_key_stage_valid() {
  local directory="$1" role='' signing='' verification='' credential='' kind=''
  for role in payment stake; do
    if [[ "${role}" == payment ]]; then signing="${CNTOOLS_WALLET_PAY_SKEY_FILENAME}"; verification="${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"; credential="${CNTOOLS_WALLET_PAY_CRED_FILENAME}"
    else signing="${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}"; verification="${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"; credential="${CNTOOLS_WALLET_STAKE_CRED_FILENAME}"; fi
    cntools_wallet_key_normal_envelope_valid "${directory}/${verification}" "${role}" verification &&
      cntools_wallet_id_validate "${directory}/${credential}" || return 1
    if [[ -f "${directory}/${signing}" ]]; then
      cntools_wallet_key_signing_type "${role}" "${directory}/${signing}" kind || return 1
      if [[ "${kind}" == extended ]]; then
        cntools_wallet_key_extended_envelope_valid "${directory}/${signing}" "${role}" signing &&
          cntools_wallet_key_extended_pair_matches "${directory}" "${role}" "${directory}/${signing}" "${directory}/${verification}" || return 1
      else
        cntools_wallet_key_normal_pair_matches "${directory}" "${role}" "${directory}/${signing}" "${directory}/${verification}" || return 1
      fi
    fi
  done
}

cntools_multisig_key_generate_internal() {
  local directory="$1" mode="$2" pay_path="$3" stake_path="$4" phrase="${5:-}"
  local stage='' root='' child='' output='' errors='' role='' signing='' selector='' name='' target='' published_source=''
  local prefix="${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}" form='' canonical=''
  local -a words=() entries=() published=() paths=() hw_command=()
  CNTOOLS_MULTISIG_PUBLICATION_SOURCES=(); CNTOOLS_MULTISIG_PUBLICATION_TARGETS=()
  cntools_multisig_key_preflight "${directory}" || return 1
  case "${mode}" in cli|mnemonic|hardware) ;; *) return 2 ;; esac
  if [[ "${mode}" != cli ]]; then
    cntools_multisig_path_into canonical "${pay_path}" || return 2; pay_path="${canonical}"
    cntools_multisig_path_into canonical "${stake_path}" || return 2; stake_path="${canonical}"
    [[ "${pay_path}" != "${stake_path}" ]] || { cntools_multisig_fail 'Payment and stake paths must be different.'; return 1; }
  fi
  if [[ "${mode}" == mnemonic ]]; then
    cntools_wallet_mnemonic_words_into words "${phrase}" && cntools_wallet_mnemonic_phrase_into phrase words || return 2
    cntools_multisig_address_tool_ready || return 1
  fi
  cntools_wallet_create_root_prepare && cntools_wallet_create_stage_into stage || return 1
  cntools_wallet_material_temp_file errors "${stage}" multisig-key-errors || return 1
  cntools_wallet_material_temp_file output "${stage}" multisig-key-output || return 1
  if [[ "${mode}" == mnemonic ]]; then
    cntools_wallet_material_temp_file root "${stage}" multisig-root &&
      cntools_multisig_secret_command "${root}" "${errors}" "${CNTOOLS_MULTISIG_ADDRESS_TOOL}" key from-recovery-phrase Shelley <<< "${phrase}" || return 1
    unset phrase words
  elif [[ "${mode}" == hardware ]]; then
    [[ "${pay_path}" =~ ^[0-9]+H/ && "${stake_path}" =~ ^[0-9]+H/ && "${pay_path}" != 44H/* && "${stake_path}" != 44H/* ]] &&
      cntools_wallet_hardware_path_valid "${pay_path}" && cntools_wallet_hardware_path_valid "${stake_path}" &&
      cntools_wallet_hardware_require && cntools_wallet_hardware_device_check || return 1
    hw_command=("${CNTOOLS_WALLET_HARDWARE_BIN}" address key-gen --path "${pay_path}" --path "${stake_path}"
      --verification-key-file "${stage}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" --verification-key-file "${stage}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"
      --hw-signing-file "${stage}/${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}" --hw-signing-file "${stage}/${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}")
    local CNTOOLS_CLI_TIMEOUT="${CNTOOLS_WALLET_HARDWARE_TIMEOUT}"
    cntools_multisig_secret_command "${output}" "${errors}" "${hw_command[@]}" || return 1
    cntools_wallet_hardware_pair_matches "${stage}/${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}" "${stage}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" payment "${pay_path}" &&
      cntools_wallet_hardware_pair_matches "${stage}/${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}" "${stage}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" stake "${stake_path}" || return 1
  fi
  paths=("${pay_path}" "${stake_path}")
  for role in payment stake; do
    if [[ "${role}" == payment ]]; then signing="${CNTOOLS_WALLET_PAY_SKEY_FILENAME}"; selector=--shelley-payment-key; canonical="${paths[0]}"
    else signing="${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}"; selector=--shelley-stake-key; canonical="${paths[1]}"; fi
    case "${mode}" in
      cli) cntools_wallet_create_key_pair "${stage}" "${role}" || return 1 ;;
      mnemonic)
        cntools_wallet_material_temp_file child "${stage}" multisig-child &&
          cntools_multisig_secret_command "${child}" "${errors}" "${CNTOOLS_MULTISIG_ADDRESS_TOOL}" key child "${canonical}" < "${root}" &&
          cntools_multisig_secret_command "${output}" "${errors}" "${CNTOOLS_CLI}" key convert-cardano-address-key "${selector}" \
            --signing-key-file "${child}" --out-file "${stage}/${signing}" || return 1
        chmod 0600 "${stage}/${signing}" || return 1
        cntools_wallet_key_signing_type "${role}" "${stage}/${signing}" form && [[ "${form}" == extended ]] || return 1
        cntools_wallet_material_remove_temp "${child}" || true
        ;;
    esac
  done
  cntools_wallet_key_materialize "${stage}" && cntools_wallet_id_materialize_credentials "${stage}" &&
    cntools_multisig_key_stage_valid "${stage}" || { cntools_multisig_fail 'Generated participant keys failed pair validation.'; return 1; }
  if [[ "${mode}" == cli ]]; then pay_path=''; stake_path=''; fi
  jq -n --arg source "${mode}" --arg p "${pay_path}" --arg s "${stake_path}" \
    '{source:$source,paymentPath:(if $p=="" then null else $p end),stakePath:(if $s=="" then null else $s end)}' > "${stage}/derivation.json" || return 1
  cntools_wallet_material_cleanup
  # Recheck after adding the path record, including configured filename
  # collisions; no later write may silently replace a validated key.
  cntools_multisig_key_stage_valid "${stage}" || {
    cntools_multisig_fail 'Participant artifacts changed before publication.'; return 1;
  }
  entries=("${stage}"/*)
  # Each destination is created with a no-overwrite hard link. If publication
  # fails, roll back only destinations still sharing our staged inode.
  for published_source in "${entries[@]}"; do
    name="${published_source##*/}"; target="${directory}/${prefix}${name}"
    chmod 0600 "${published_source}" || break
    CNTOOLS_MULTISIG_PUBLICATION_SOURCES+=("${published_source}")
    CNTOOLS_MULTISIG_PUBLICATION_TARGETS+=("${target}")
    if ! ln -T -- "${published_source}" "${target}" 2>/dev/null; then break; fi
    published+=("${target}")
  done
  if (( ${#published[@]} != ${#entries[@]} )); then
    cntools_multisig_key_publication_cleanup || true
    cntools_multisig_fail 'Participant publication failed; existing artifacts were not replaced.'; return 1
  fi
  CNTOOLS_MULTISIG_PUBLICATION_SOURCES=(); CNTOOLS_MULTISIG_PUBLICATION_TARGETS=()
  cntools_wallet_create_remove_stage "${stage}" || return 1
  cntools_log WALLET "Multisig participant keys added wallet=${directory##*/} source=${mode} payment_path=${pay_path:-none} stake_path=${stake_path:-none}" || true
}

cntools_multisig_key_generate() {
  local traced=N status=0
  case "$-" in *x*) traced=Y; set +x ;; esac
  cntools_multisig_key_generate_internal "$@" || status=$?
  cntools_multisig_key_publication_cleanup || true
  cntools_wallet_material_cleanup
  cntools_wallet_create_cleanup
  [[ "${traced}" != Y ]] || set -x
  return "${status}"
}
