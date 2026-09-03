#!/usr/bin/env bash
# Transactional publication shared by standard CNTools wallet types.
# Loaded after wallet.sh, wallet-material.sh, wallet-key.sh,
# wallet-address.sh, and wallet-id.sh.
# shellcheck disable=SC2034

declare -ag CNTOOLS_WALLET_CREATE_STAGING_DIRECTORIES=()
declare -g CNTOOLS_WALLET_CREATED_NAME=""
declare -g CNTOOLS_WALLET_CREATED_DIRECTORY=""
declare -g CNTOOLS_WALLET_CREATE_ERROR=""
declare -g CNTOOLS_WALLET_CREATE_WARNING=""
declare -g CNTOOLS_WALLET_CREATE_CLEANUP_WARNING=""

cntools_wallet_create_log() {
  cntools_log "${1:-INFO}" "${2:-}" || true
}

cntools_wallet_create_set_error() {
  CNTOOLS_WALLET_CREATE_ERROR="${1:-Wallet creation failed.}"
  cntools_wallet_create_log ERROR "${CNTOOLS_WALLET_CREATE_ERROR}"
}

cntools_wallet_create_name_valid() {
  local name="${1:-}"
  local LC_ALL=C

  (( ${#name} >= 1 && ${#name} <= 64 )) || return 1
  [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

cntools_wallet_create_mode_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_path="${2:-}"
  local _cntools_mode=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if _cntools_mode="$(stat -c '%a' -- "${_cntools_path}" 2>/dev/null)"; then
    :
  elif _cntools_mode="$(stat -f '%Lp' "${_cntools_path}" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  [[ "${_cntools_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  _cntools_output_ref="${_cntools_mode}"
}

cntools_wallet_create_directory_private() {
  local directory="${1:-}"
  local mode=""
  local mode_value=0

  [[ -d "${directory}" && ! -L "${directory}" &&
     -O "${directory}" && -w "${directory}" && -x "${directory}" ]] ||
    return 1
  cntools_wallet_create_mode_into mode "${directory}" || return 1
  mode_value=$((8#${mode}))
  (( (mode_value & 0022) == 0 ))
}

cntools_wallet_create_root_preflight() {
  local root="${CNTOOLS_WALLET_DIR:-}"
  local parent=""
  local basename=""

  [[ -n "${root}" && "${root}" = /* &&
     "${root}" != *$'\n'* && "${root}" != *$'\r'* ]] || {
    cntools_wallet_create_set_error "The wallet directory is unset or unsafe."
    return 1
  }
  if [[ -e "${root}" || -L "${root}" ]]; then
    if ! cntools_wallet_root_safe ||
       ! cntools_wallet_create_directory_private "${root}"; then
      cntools_wallet_create_set_error \
        "The wallet directory must be owned, writable, and protected from group or public writes: ${root}"
      return 1
    fi
    return 0
  fi

  parent="${root%/*}"
  basename="${root##*/}"
  [[ -n "${parent}" && "${parent}" != "${root}" &&
     "${basename}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ &&
     -d "${parent}" && ! -L "${parent}" &&
     -O "${parent}" && -w "${parent}" && -x "${parent}" ]] || {
    cntools_wallet_create_set_error \
      "The parent of the configured wallet directory is unavailable or unsafe: ${parent:-unset}"
    return 1
  }
  if ! cntools_wallet_path_components_safe "${parent}" ||
     ! cntools_wallet_create_directory_private "${parent}"; then
    cntools_wallet_create_set_error \
      "The wallet parent directory must be protected from group or public writes: ${parent}"
    return 1
  fi
}

cntools_wallet_create_root_prepare() {
  local root="${CNTOOLS_WALLET_DIR:-}"
  local previous_umask=""
  local created="N"

  cntools_wallet_create_root_preflight || return 1
  if [[ ! -e "${root}" && ! -L "${root}" ]]; then
    previous_umask="$(umask)"
    umask 077
    if mkdir -- "${root}" 2>/dev/null; then
      created="Y"
    elif [[ ! -d "${root}" || -L "${root}" ]]; then
      umask "${previous_umask}"
      cntools_wallet_create_set_error \
        "The wallet directory could not be created safely: ${root}"
      return 1
    fi
    umask "${previous_umask}"
  fi
  if [[ "${created}" == "Y" ]] && ! chmod 0700 -- "${root}"; then
    cntools_wallet_create_set_error \
      "The wallet directory permissions could not be secured: ${root}"
    return 1
  fi
  if ! cntools_wallet_root_safe ||
     ! cntools_wallet_create_directory_private "${root}"; then
    cntools_wallet_create_set_error \
      "The wallet directory is not safe after creation: ${root}"
    return 1
  fi
}

cntools_wallet_create_publish_supported() {
  local help=""

  help="$(LC_ALL=C mv --help 2>&1)" || return 1
  [[ "${help}" == *"--no-target-directory"* &&
     "${help}" == *"--no-clobber"* ]]
}

cntools_wallet_create_environment_ready() {
  CNTOOLS_WALLET_CREATE_ERROR=""
  [[ -n "${CNTOOLS_CLI:-}" && "${CNTOOLS_CLI}" = /* &&
     -f "${CNTOOLS_CLI}" &&
     -x "${CNTOOLS_CLI}" ]] || {
    cntools_wallet_create_set_error \
      "Cardano CLI is required to create or import this wallet but is not available."
    return 1
  }
  cntools_wallet_address_network_arguments || {
    cntools_wallet_create_set_error \
      "Wallet creation does not support network=${CNTOOLS_NETWORK:-unset}."
    return 1
  }
  cntools_wallet_create_publish_supported || {
    cntools_wallet_create_set_error \
      "Wallet creation requires GNU mv with no-clobber directory publication support."
    return 1
  }
  cntools_wallet_create_root_preflight
}

cntools_wallet_create_target_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_name="${2:-}"
  local _cntools_root="${CNTOOLS_WALLET_DIR:-}"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_create_name_valid "${_cntools_name}" || return 2
  [[ -n "${_cntools_root}" && "${_cntools_root}" = /* ]] || return 2
  _cntools_output_ref="${_cntools_root%/}/${_cntools_name}"
}

cntools_wallet_create_target_available() {
  local target=""

  cntools_wallet_create_target_into target "${1:-}" || return 2
  [[ ! -e "${target}" && ! -L "${target}" ]]
}

cntools_wallet_create_track_stage() {
  CNTOOLS_WALLET_CREATE_STAGING_DIRECTORIES+=("${1:-}")
}

cntools_wallet_create_untrack_stage() {
  local stage="${1:-}"
  local candidate=""
  local -a remaining=()

  for candidate in "${CNTOOLS_WALLET_CREATE_STAGING_DIRECTORIES[@]}"; do
    [[ "${candidate}" == "${stage}" ]] || remaining+=("${candidate}")
  done
  CNTOOLS_WALLET_CREATE_STAGING_DIRECTORIES=("${remaining[@]}")
}

cntools_wallet_create_stage_tracked() {
  local stage="${1:-}"
  local candidate=""

  for candidate in "${CNTOOLS_WALLET_CREATE_STAGING_DIRECTORIES[@]}"; do
    [[ "${candidate}" != "${stage}" ]] || return 0
  done
  return 1
}

cntools_wallet_create_stage_safe() {
  local stage="${1:-}"
  local root="${CNTOOLS_WALLET_DIR:-}"
  local name="${stage##*/}"

  cntools_wallet_create_stage_tracked "${stage}" || return 1
  [[ "${stage}" == "${root%/}/.cntools-wallet-new."* &&
     "${name}" =~ ^[.]cntools-wallet-new[.][A-Za-z0-9]+$ &&
     -d "${stage}" && ! -L "${stage}" && -O "${stage}" ]] || return 1
  cntools_wallet_directory_safe "${stage}" &&
    cntools_wallet_create_directory_private "${stage}"
}

cntools_wallet_create_stage_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_previous_umask=""
  local _cntools_stage=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_root_safe &&
    cntools_wallet_create_directory_private "${CNTOOLS_WALLET_DIR}" || return 1
  _cntools_previous_umask="$(umask)"
  umask 077
  _cntools_stage="$(mktemp -d \
    "${CNTOOLS_WALLET_DIR%/}/.cntools-wallet-new.XXXXXX")" || {
      umask "${_cntools_previous_umask}"
      return 1
    }
  umask "${_cntools_previous_umask}"
  chmod 0700 -- "${_cntools_stage}" || {
    rm -rf -- "${_cntools_stage}" 2>/dev/null || true
    return 1
  }
  cntools_wallet_create_track_stage "${_cntools_stage}"
  cntools_wallet_create_stage_safe "${_cntools_stage}" || {
    cntools_wallet_create_cleanup || true
    return 1
  }
  _cntools_output_ref="${_cntools_stage}"
}

cntools_wallet_create_remove_stage() {
  local stage="${1:-}"

  cntools_wallet_create_stage_tracked "${stage}" || return 2
  if [[ ! -e "${stage}" && ! -L "${stage}" ]]; then
    cntools_wallet_create_untrack_stage "${stage}"
    return 0
  fi
  if ! cntools_wallet_create_stage_safe "${stage}"; then
    CNTOOLS_WALLET_CREATE_CLEANUP_WARNING="Private wallet staging could not be removed safely: ${stage}"
    cntools_wallet_create_log ERROR \
      "${CNTOOLS_WALLET_CREATE_CLEANUP_WARNING}"
    return 1
  fi
  if ! rm -rf -- "${stage}"; then
    CNTOOLS_WALLET_CREATE_CLEANUP_WARNING="Private wallet staging could not be removed: ${stage}"
    cntools_wallet_create_log ERROR \
      "${CNTOOLS_WALLET_CREATE_CLEANUP_WARNING}"
    return 1
  fi
  cntools_wallet_create_untrack_stage "${stage}"
}

cntools_wallet_create_cleanup() {
  local stage=""
  local -a tracked=("${CNTOOLS_WALLET_CREATE_STAGING_DIRECTORIES[@]}")

  for stage in "${tracked[@]}"; do
    cntools_wallet_create_remove_stage "${stage}" || true
  done
}

cntools_wallet_create_key_pair() {
  local stage="${1:-}"
  local role="${2:-}"
  local signing_file=""
  local verification_file=""
  local error_file=""
  local signing_form=""
  local status=0
  local -a command=()

  cntools_wallet_create_stage_safe "${stage}" || return 1
  case "${role}" in
    payment)
      signing_file="${stage}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}"
      verification_file="${stage}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"
      command=("${CNTOOLS_CLI}" address key-gen)
      ;;
    stake)
      signing_file="${stage}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}"
      verification_file="${stage}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"
      command=("${CNTOOLS_CLI}" latest stake-address key-gen)
      ;;
    *) return 2 ;;
  esac
  [[ ! -e "${signing_file}" && ! -L "${signing_file}" &&
     ! -e "${verification_file}" && ! -L "${verification_file}" ]] ||
    return 1
  cntools_wallet_material_temp_file \
    error_file "${stage}" "create-${role}-key-error" || return 1
  if cntools_wallet_material_run_cli "${error_file}" -- \
      "${command[@]}" \
      --verification-key-file "${verification_file}" \
      --signing-key-file "${signing_file}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_wallet_material_log_cli_failure \
      "Could not create ${role} wallet keys" "${status}" "${error_file}"
    CNTOOLS_WALLET_CREATE_ERROR="Cardano CLI could not create the ${role} wallet keys."
    cntools_wallet_material_remove_temp "${error_file}" || true
    return 1
  fi
  cntools_wallet_material_remove_temp "${error_file}" || true
  [[ -f "${signing_file}" && ! -L "${signing_file}" &&
     -O "${signing_file}" &&
     -f "${verification_file}" && ! -L "${verification_file}" &&
     -O "${verification_file}" ]] || return 1
  chmod 0600 -- "${signing_file}" "${verification_file}" || return 1
  if ! cntools_wallet_key_signing_type \
       "${role}" "${signing_file}" signing_form ||
     [[ "${signing_form}" != "normal" ]] ||
     ! cntools_wallet_key_validate \
       "${verification_file}" "${role}" normal ||
     ! cntools_wallet_key_normal_envelope_valid \
       "${signing_file}" "${role}" signing ||
     ! cntools_wallet_key_normal_envelope_valid \
       "${verification_file}" "${role}" verification; then
    cntools_wallet_create_set_error \
      "Cardano CLI returned invalid ${role} wallet keys."
    return 1
  fi
  if ! cntools_wallet_key_normal_pair_matches \
      "${stage}" "${role}" "${signing_file}" "${verification_file}"; then
    cntools_wallet_create_set_error \
      "The generated ${role} signing and verification keys could not be proven to match."
    return 1
  fi
}

cntools_wallet_create_required_entries_valid() {
  local directory="${1:-}"
  local entry=""
  local name=""
  local mode=""
  local wallet_type=""
  local count=0
  local expected_count=9
  local -a entries=()
  local -a required=(
    "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}"
    "${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"
    "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}"
    "${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"
    "${CNTOOLS_WALLET_PAY_ADDR_FILENAME}"
    "${CNTOOLS_WALLET_STAKE_ADDR_FILENAME}"
    "${CNTOOLS_WALLET_BASE_ADDR_FILENAME}"
    "${CNTOOLS_WALLET_PAY_CRED_FILENAME}"
    "${CNTOOLS_WALLET_STAKE_CRED_FILENAME}"
  )

  cntools_wallet_directory_safe "${directory}" || return 1
  chmod 0700 -- "${directory}" || return 1
  for name in "${required[@]}"; do
    entry="${directory}/${name}"
    [[ -f "${entry}" && ! -L "${entry}" && -O "${entry}" ]] || return 1
    chmod 0600 -- "${entry}" || return 1
  done
  entries=(
    "${directory}"/*
    "${directory}"/.[!.]*
    "${directory}"/..?*
  )
  for entry in "${entries[@]}"; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    count=$((count + 1))
    name="${entry##*/}"
    case " ${required[*]} " in
      *" ${name} "*) ;;
      *) return 1 ;;
    esac
    cntools_wallet_create_mode_into mode "${entry}" || return 1
    [[ "${mode}" == "600" || "${mode}" == "0600" ]] || return 1
  done
  (( count == expected_count )) || return 1
  cntools_wallet_create_mode_into mode "${directory}" || return 1
  [[ "${mode}" == "700" || "${mode}" == "0700" ]] || return 1

  cntools_wallet_key_normal_envelope_valid \
    "${directory}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" payment signing &&
    cntools_wallet_key_normal_envelope_valid \
      "${directory}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" stake signing &&
    cntools_wallet_key_normal_envelope_valid \
      "${directory}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" \
      payment verification &&
    cntools_wallet_key_normal_envelope_valid \
      "${directory}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" \
      stake verification &&
    cntools_wallet_address_validate \
      "${directory}/${CNTOOLS_WALLET_PAY_ADDR_FILENAME}" payment &&
    cntools_wallet_address_validate \
      "${directory}/${CNTOOLS_WALLET_STAKE_ADDR_FILENAME}" reward &&
    cntools_wallet_address_validate \
      "${directory}/${CNTOOLS_WALLET_BASE_ADDR_FILENAME}" base &&
    cntools_wallet_id_validate \
      "${directory}/${CNTOOLS_WALLET_PAY_CRED_FILENAME}" &&
    cntools_wallet_id_validate \
      "${directory}/${CNTOOLS_WALLET_STAKE_CRED_FILENAME}" || return 1
  [[ ! -e "${directory}/${CNTOOLS_WALLET_DERIVATION_PATH_FILENAME}" &&
     ! -L "${directory}/${CNTOOLS_WALLET_DERIVATION_PATH_FILENAME}" ]] ||
    return 1
  wallet_type="$(cntools_wallet_type "${directory}")" || return 1
  [[ "${wallet_type}" == "CLI" ]]
}

cntools_wallet_create_publish() {
  local stage="${1:-}"
  local target="${2:-}"
  local validator="${3:-cntools_wallet_create_required_entries_valid}"
  local status=0

  [[ "${validator}" =~ ^cntools_wallet_[A-Za-z0-9_]+_required_entries_valid$ ]] ||
    return 2
  declare -F "${validator}" >/dev/null 2>&1 || return 2
  cntools_wallet_create_stage_safe "${stage}" || return 1
  [[ "${target%/*}" == "${CNTOOLS_WALLET_DIR%/}" &&
     ! -e "${target}" && ! -L "${target}" ]] || return 1
  if cntools_run_command "000000" -- \
      mv -T -n -- "${stage}" "${target}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_wallet_create_set_error \
      "The completed wallet could not be published safely."
    return 1
  fi
  # GNU mv --no-clobber reports success when it skips an existing target.
  # Publication succeeded only when our tracked source directory disappeared.
  if [[ -e "${stage}" || -L "${stage}" ]]; then
    cntools_wallet_create_set_error \
      "A wallet with this name appeared before publication; nothing was overwritten."
    return 1
  fi
  cntools_wallet_create_untrack_stage "${stage}"
  if ! cntools_wallet_directory_safe "${target}" ||
     ! "${validator}" "${target}"; then
    CNTOOLS_WALLET_CREATE_WARNING="The wallet was created at ${target}, but post-publication validation could not be repeated. Inspect and back it up before use."
    cntools_wallet_create_log ERROR "${CNTOOLS_WALLET_CREATE_WARNING}"
  fi
}

cntools_wallet_create_cli() {
  local name="${1:-}"
  local target=""
  local stage=""

  CNTOOLS_WALLET_CREATED_NAME=""
  CNTOOLS_WALLET_CREATED_DIRECTORY=""
  CNTOOLS_WALLET_CREATE_ERROR=""
  CNTOOLS_WALLET_CREATE_WARNING=""
  CNTOOLS_WALLET_CREATE_CLEANUP_WARNING=""
  cntools_wallet_create_name_valid "${name}" || {
    cntools_wallet_create_set_error \
      "Wallet names must use 1–64 ASCII letters, numbers, dots, underscores, or hyphens, and must start with a letter or number."
    return 2
  }
  cntools_wallet_create_environment_ready || return 1
  cntools_wallet_create_root_prepare || return 1
  cntools_wallet_create_target_into target "${name}" || return 2
  if [[ -e "${target}" || -L "${target}" ]]; then
    cntools_wallet_create_set_error \
      "A wallet or filesystem entry named ${name} already exists."
    return 1
  fi
  cntools_wallet_create_stage_into stage || {
    cntools_wallet_create_set_error \
      "A private staging directory could not be created."
    return 1
  }
  cntools_wallet_create_log WALLET \
    "creating wallet=${name} type=CLI network=${CNTOOLS_NETWORK}"
  if ! cntools_wallet_create_key_pair "${stage}" payment ||
     ! cntools_wallet_create_key_pair "${stage}" stake ||
     ! cntools_wallet_materialize_wallet "${stage}" ||
     ! cntools_wallet_create_required_entries_valid "${stage}"; then
    [[ -n "${CNTOOLS_WALLET_CREATE_ERROR}" ]] ||
      cntools_wallet_create_set_error \
        "The generated wallet did not pass complete artifact validation."
    cntools_wallet_material_cleanup
    cntools_wallet_create_remove_stage "${stage}" || true
    if [[ -n "${CNTOOLS_WALLET_CREATE_CLEANUP_WARNING}" ]]; then
      CNTOOLS_WALLET_CREATE_ERROR+=" ${CNTOOLS_WALLET_CREATE_CLEANUP_WARNING}"
    fi
    return 1
  fi
  if ! cntools_wallet_create_publish "${stage}" "${target}"; then
    cntools_wallet_material_cleanup
    cntools_wallet_create_remove_stage "${stage}" || true
    if [[ -n "${CNTOOLS_WALLET_CREATE_CLEANUP_WARNING}" ]]; then
      CNTOOLS_WALLET_CREATE_ERROR+=" ${CNTOOLS_WALLET_CREATE_CLEANUP_WARNING}"
    fi
    return 1
  fi
  CNTOOLS_WALLET_CREATED_NAME="${name}"
  CNTOOLS_WALLET_CREATED_DIRECTORY="${target}"
  cntools_wallet_create_log WALLET \
    "created wallet=${name} type=CLI network=${CNTOOLS_NETWORK}"
}
