#!/usr/bin/env bash
# Standard CIP-1852 hardware-wallet import through cardano-hw-cli.
# Multisig (CIP-1854) and governance keys intentionally belong to their
# dedicated actions; the path builder below remains reusable by those slices.
# Loaded after wallet-create.sh.
# shellcheck disable=SC2034

CNTOOLS_WALLET_HARDWARE_REQUIRED_VERSION="1.19.1"
CNTOOLS_WALLET_HARDWARE_TIMEOUT="${CNTOOLS_WALLET_HARDWARE_TIMEOUT:-300}"
[[ "${CNTOOLS_WALLET_HARDWARE_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] ||
  CNTOOLS_WALLET_HARDWARE_TIMEOUT="300"
declare -g CNTOOLS_WALLET_HARDWARE_BIN=""
declare -g CNTOOLS_WALLET_HARDWARE_VERSION=""
declare -g CNTOOLS_WALLET_HARDWARE_DEVICE=""
declare -g CNTOOLS_WALLET_HARDWARE_ERROR=""
declare -g CNTOOLS_WALLET_HARDWARE_ACCOUNT=""
declare -g CNTOOLS_WALLET_HARDWARE_KEY_INDEX=""

cntools_wallet_hardware_log() {
  cntools_log "${1:-INFO}" "${2:-}" || true
}

cntools_wallet_hardware_set_error() {
  CNTOOLS_WALLET_HARDWARE_ERROR="${1:-Hardware wallet import failed.}"
  CNTOOLS_WALLET_CREATE_ERROR="${CNTOOLS_WALLET_HARDWARE_ERROR}"
  cntools_wallet_hardware_log ERROR "${CNTOOLS_WALLET_HARDWARE_ERROR}"
}

cntools_wallet_hardware_reset_result() {
  CNTOOLS_WALLET_HARDWARE_ERROR=""
  CNTOOLS_WALLET_HARDWARE_DEVICE=""
  CNTOOLS_WALLET_HARDWARE_ACCOUNT=""
  CNTOOLS_WALLET_HARDWARE_KEY_INDEX=""
  CNTOOLS_WALLET_CREATED_NAME=""
  CNTOOLS_WALLET_CREATED_DIRECTORY=""
  CNTOOLS_WALLET_CREATE_ERROR=""
  CNTOOLS_WALLET_CREATE_WARNING=""
  CNTOOLS_WALLET_CREATE_CLEANUP_WARNING=""
}

cntools_wallet_hardware_index_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_input="${2:-}"
  local _cntools_index=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_input="${_cntools_input#"${_cntools_input%%[![:space:]]*}"}"
  _cntools_input="${_cntools_input%"${_cntools_input##*[![:space:]]}"}"
  [[ -n "${_cntools_input}" ]] || _cntools_input="0"
  [[ "${_cntools_input}" =~ ^[0-9]{1,10}$ ]] || return 1
  _cntools_index=$((10#${_cntools_input}))
  (( _cntools_index <= 2147483647 )) || return 1
  _cntools_output_ref="${_cntools_index}"
}

cntools_wallet_hardware_path_valid() {
  local path="${1:-}"
  local component=""
  local number=""
  local -a components=()

  [[ -n "${path}" && "${path}" != *$'\n'* &&
     "${path}" != *$'\r'* ]] || return 1
  IFS='/' read -r -a components <<< "${path}"
  (( ${#components[@]} == 5 )) || return 1
  for component in "${components[@]}"; do
    [[ "${component}" =~ ^[0-9]{1,10}H?$ ]] || return 1
    number="${component%H}"
    (( 10#${number} <= 2147483647 )) || return 1
  done
}

cntools_wallet_hardware_path_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_purpose="${2:-}"
  local _cntools_account="${3:-}"
  local _cntools_role="${4:-}"
  local _cntools_key_index="${5:-}"
  local _cntools_path=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_hardware_index_into _cntools_purpose "${_cntools_purpose}" ||
    return 2
  cntools_wallet_hardware_index_into _cntools_account "${_cntools_account}" ||
    return 2
  cntools_wallet_hardware_index_into _cntools_role "${_cntools_role}" ||
    return 2
  cntools_wallet_hardware_index_into _cntools_key_index \
    "${_cntools_key_index}" || return 2
  _cntools_path="${_cntools_purpose}H/1815H/${_cntools_account}H/${_cntools_role}/${_cntools_key_index}"
  cntools_wallet_hardware_path_valid "${_cntools_path}" || return 1
  _cntools_output_ref="${_cntools_path}"
}

cntools_wallet_hardware_output_detail_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_text="${2:-}"
  local _cntools_detail=""
  local _cntools_character=""
  local _cntools_clean=""
  local _cntools_position=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  while IFS= read -r _cntools_detail; do
    [[ -n "${_cntools_detail//[[:space:]]/}" ]] || continue
    break
  done <<< "${_cntools_text}"
  _cntools_detail="${_cntools_detail:0:400}"
  for (( _cntools_position = 0;
         _cntools_position < ${#_cntools_detail};
         _cntools_position++ )); do
    _cntools_character="${_cntools_detail:_cntools_position:1}"
    if [[ "${_cntools_character}" == [[:cntrl:]] ]]; then
      _cntools_clean+=" "
    else
      _cntools_clean+="${_cntools_character}"
    fi
  done
  _cntools_detail="${_cntools_clean}"
  if declare -F cntools_log_sanitize_line >/dev/null 2>&1; then
    _cntools_detail="$(cntools_log_sanitize_line "${_cntools_detail}")"
  fi
  _cntools_output_ref="${_cntools_detail}"
}

cntools_wallet_hardware_require() {
  local candidate="${CNTOOLS_HWCLI:-cardano-hw-cli}"
  local resolved=""
  local output=""
  local detail=""
  local version=""
  local status=0

  if [[ -n "${CNTOOLS_WALLET_HARDWARE_BIN}" &&
        "${CNTOOLS_WALLET_HARDWARE_BIN}" = /* &&
        -x "${CNTOOLS_WALLET_HARDWARE_BIN}" &&
        ! -d "${CNTOOLS_WALLET_HARDWARE_BIN}" &&
        "${CNTOOLS_WALLET_HARDWARE_VERSION}" == \
          "${CNTOOLS_WALLET_HARDWARE_REQUIRED_VERSION}" ]]; then
    return 0
  fi
  CNTOOLS_WALLET_HARDWARE_BIN=""
  CNTOOLS_WALLET_HARDWARE_VERSION=""
  resolved="$(cntools_startup_resolve_command "${candidate}" 2>/dev/null || true)"
  if [[ -z "${resolved}" ]]; then
    cntools_wallet_hardware_set_error \
      "cardano-hw-cli ${CNTOOLS_WALLET_HARDWARE_REQUIRED_VERSION} is required. Install that exact version first; Guild Deploy can install it with the hardware-wallet option (-s w)."
    return 1
  fi
  if output="$(cntools_run_command_timeout 15 00 -- \
      "${resolved}" version 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_wallet_hardware_output_detail_into detail "${output}" || true
    cntools_wallet_hardware_log ERROR \
      "cardano-hw-cli version check failed status=${status}${detail:+: ${detail}}"
    cntools_wallet_hardware_set_error \
      "cardano-hw-cli could not be started. Reinstall it first; Guild Deploy can install it with the hardware-wallet option (-s w)."
    return 1
  fi
  if [[ "${output}" =~ Cardano[[:space:]]+HW[[:space:]]+CLI[[:space:]]+Tool[[:space:]]+version[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?) ]]; then
    version="${BASH_REMATCH[1]}"
  fi
  if [[ "${version}" != "${CNTOOLS_WALLET_HARDWARE_REQUIRED_VERSION}" ]]; then
    cntools_wallet_hardware_set_error \
      "cardano-hw-cli ${version:-unknown} is unsupported; exactly ${CNTOOLS_WALLET_HARDWARE_REQUIRED_VERSION} is required."
    return 1
  fi
  CNTOOLS_WALLET_HARDWARE_BIN="${resolved}"
  CNTOOLS_WALLET_HARDWARE_VERSION="${version}"
  cntools_wallet_hardware_log HARDWARE \
    "cardano-hw-cli ready version=${version} path=${resolved}"
}

cntools_wallet_hardware_device_check() {
  local output=""
  local detail=""
  local status=0

  CNTOOLS_WALLET_HARDWARE_DEVICE=""
  cntools_wallet_hardware_require || return 1
  if output="$(cntools_run_command_timeout \
      "${CNTOOLS_WALLET_HARDWARE_TIMEOUT}" 000 -- \
      "${CNTOOLS_WALLET_HARDWARE_BIN}" device version 2>&1)"; then
    status=0
  else
    status=$?
  fi
  cntools_wallet_hardware_output_detail_into detail "${output}" || true
  if (( status != 0 )); then
    cntools_wallet_hardware_log ERROR \
      "hardware device check failed status=${status}${detail:+: ${detail}}"
    cntools_wallet_hardware_set_error \
      "The hardware wallet could not be reached. Check its connection, unlock it, and open the Cardano app when required."
    return 1
  fi
  [[ -n "${detail}" ]] || detail="Connected hardware wallet"
  CNTOOLS_WALLET_HARDWARE_DEVICE="${detail}"
  cntools_wallet_hardware_log HARDWARE "device=${detail}"
}

cntools_wallet_hardware_file_validate() {
  local file="${1:-}"
  local role="${2:-}"
  local expected_path="${3:-}"
  local expected_type=""

  case "${role}" in
    payment) expected_type="PaymentHWSigningFileShelley_ed25519" ;;
    stake) expected_type="StakeHWSigningFileShelley_ed25519" ;;
    *) return 2 ;;
  esac
  cntools_wallet_hardware_path_valid "${expected_path}" || return 2
  cntools_wallet_safe_regular_file "${file}" 65536 || return 1
  jq -ers --arg expected_type "${expected_type}" \
    --arg expected_path "${expected_path}" '
      length == 1 and
      (.[0] | type == "object") and
      (.[0].type == $expected_type) and
      ((.[0].description | type) == "string") and
      ((.[0].description | test("[\u0000-\u001f\u007f]")) | not) and
      (.[0].path == $expected_path) and
      (.[0].cborXPubKeyHex | type == "string" and
        test("^5840[0-9a-fA-F]{128}$"))
    ' "${file}" >/dev/null 2>&1
}

cntools_wallet_hardware_pair_matches() {
  local hardware_file="${1:-}"
  local verification_file="${2:-}"
  local role="${3:-}"
  local expected_path="${4:-}"
  local hardware_cbor=""
  local verification_cbor=""

  cntools_wallet_hardware_file_validate \
    "${hardware_file}" "${role}" "${expected_path}" || return 1
  cntools_wallet_key_normal_envelope_valid \
    "${verification_file}" "${role}" verification || return 1
  hardware_cbor="$(jq -er '.cborXPubKeyHex | ascii_downcase' \
    "${hardware_file}" 2>/dev/null)" || return 1
  verification_cbor="$(jq -er '.cborHex | ascii_downcase' \
    "${verification_file}" 2>/dev/null)" || return 1
  [[ "${hardware_cbor:4:64}" == "${verification_cbor:4:64}" ]]
}

cntools_wallet_hardware_path_write() {
  local stage="${1:-}"
  local account="${2:-}"
  local key_index="${3:-}"
  local path_file=""

  cntools_wallet_create_stage_safe "${stage}" || return 1
  cntools_wallet_hardware_index_into account "${account}" || return 2
  cntools_wallet_hardware_index_into key_index "${key_index}" || return 2
  path_file="${stage}/${CNTOOLS_WALLET_DERIVATION_PATH_FILENAME}"
  [[ ! -e "${path_file}" && ! -L "${path_file}" ]] || return 1
  printf '1852H/1815H/%sH/x/%s\n' \
    "${account}" "${key_index}" > "${path_file}" || return 1
  chmod 0600 -- "${path_file}"
}

cntools_wallet_hardware_export() {
  local stage="${1:-}"
  local account="${2:-}"
  local key_index="${3:-}"
  local payment_path=""
  local stake_path=""
  local output=""
  local detail=""
  local status=0
  local payment_hws=""
  local stake_hws=""
  local payment_vkey=""
  local stake_vkey=""
  local mask=""
  local -a command=()

  cntools_wallet_create_stage_safe "${stage}" || return 1
  cntools_wallet_hardware_require || return 1
  cntools_wallet_hardware_path_into \
    payment_path 1852 "${account}" 0 "${key_index}" || return 2
  cntools_wallet_hardware_path_into \
    stake_path 1852 "${account}" 2 "${key_index}" || return 2
  payment_hws="${stage}/${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}"
  stake_hws="${stage}/${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}"
  payment_vkey="${stage}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"
  stake_vkey="${stage}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"
  for output in "${payment_hws}" "${stake_hws}" \
      "${payment_vkey}" "${stake_vkey}"; do
    [[ ! -e "${output}" && ! -L "${output}" ]] || return 1
  done
  command=(
    "${CNTOOLS_WALLET_HARDWARE_BIN}" address key-gen
    --path "${payment_path}"
    --path "${stake_path}"
    --verification-key-file "${payment_vkey}"
    --verification-key-file "${stake_vkey}"
    --hw-signing-file "${payment_hws}"
    --hw-signing-file "${stake_hws}"
  )
  printf -v mask '%*s' "${#command[@]}" ''
  mask="${mask// /0}"
  if output="$(cntools_run_command_timeout \
      "${CNTOOLS_WALLET_HARDWARE_TIMEOUT}" "${mask}" -- \
      "${command[@]}" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_wallet_hardware_output_detail_into detail "${output}" || true
    cntools_wallet_hardware_log ERROR \
      "hardware public-key export failed status=${status}${detail:+: ${detail}}"
    cntools_wallet_hardware_set_error \
      "cardano-hw-cli could not export the payment and stake keys from the device."
    return 1
  fi
  for output in "${payment_hws}" "${stake_hws}" \
      "${payment_vkey}" "${stake_vkey}"; do
    [[ -f "${output}" && ! -L "${output}" && -O "${output}" ]] || {
      cntools_wallet_hardware_set_error \
        "cardano-hw-cli did not create every required hardware-wallet file."
      return 1
    }
  done
  chmod 0600 -- "${payment_hws}" "${stake_hws}" \
    "${payment_vkey}" "${stake_vkey}" || {
      cntools_wallet_hardware_set_error \
        "The hardware-wallet files could not be protected with owner-only permissions."
      return 1
    }
  if ! cntools_wallet_hardware_pair_matches \
       "${payment_hws}" "${payment_vkey}" payment "${payment_path}" ||
     ! cntools_wallet_hardware_pair_matches \
       "${stake_hws}" "${stake_vkey}" stake "${stake_path}"; then
    cntools_wallet_hardware_set_error \
      "The hardware signing files and exported verification keys do not match."
    return 1
  fi
}

cntools_wallet_hardware_required_entries_valid() {
  local directory="${1:-}"
  local derivation=""
  local account=""
  local key_index=""
  local payment_path=""
  local stake_path=""
  local entry=""
  local name=""
  local mode=""
  local wallet_type=""
  local count=0
  local expected_count=10
  local -a entries=()
  local -a required=(
    "${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}"
    "${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"
    "${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}"
    "${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"
    "${CNTOOLS_WALLET_PAY_ADDR_FILENAME}"
    "${CNTOOLS_WALLET_STAKE_ADDR_FILENAME}"
    "${CNTOOLS_WALLET_BASE_ADDR_FILENAME}"
    "${CNTOOLS_WALLET_PAY_CRED_FILENAME}"
    "${CNTOOLS_WALLET_STAKE_CRED_FILENAME}"
    "${CNTOOLS_WALLET_DERIVATION_PATH_FILENAME}"
  )

  cntools_wallet_directory_safe "${directory}" || return 1
  chmod 0700 -- "${directory}" || return 1
  for name in "${required[@]}"; do
    entry="${directory}/${name}"
    [[ -f "${entry}" && ! -L "${entry}" && -O "${entry}" ]] || return 1
    chmod 0600 -- "${entry}" || return 1
  done
  entries=("${directory}"/* "${directory}"/.[!.]* "${directory}"/..?*)
  for entry in "${entries[@]}"; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    count=$((count + 1))
    name="${entry##*/}"
    case " ${required[*]} " in *" ${name} "*) ;; *) return 1 ;; esac
    cntools_wallet_create_mode_into mode "${entry}" || return 1
    [[ "${mode}" == "600" || "${mode}" == "0600" ]] || return 1
  done
  (( count == expected_count )) || return 1
  cntools_wallet_create_mode_into mode "${directory}" || return 1
  [[ "${mode}" == "700" || "${mode}" == "0700" ]] || return 1

  cntools_wallet_read_derivation_path "${directory}" derivation || return 1
  if [[ "${derivation}" =~ ^1852H/1815H/([0-9]+)H/x/([0-9]+)$ ]]; then
    account="${BASH_REMATCH[1]}"
    key_index="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  cntools_wallet_hardware_path_into payment_path 1852 "${account}" 0 \
    "${key_index}" || return 1
  cntools_wallet_hardware_path_into stake_path 1852 "${account}" 2 \
    "${key_index}" || return 1
  cntools_wallet_hardware_pair_matches \
      "${directory}/${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}" \
      "${directory}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" \
      payment "${payment_path}" &&
    cntools_wallet_hardware_pair_matches \
      "${directory}/${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}" \
      "${directory}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" \
      stake "${stake_path}" &&
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
  [[ ! -e "${directory}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" &&
     ! -L "${directory}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" &&
     ! -e "${directory}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" &&
     ! -L "${directory}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" ]] || return 1
  wallet_type="$(cntools_wallet_type "${directory}")" || return 1
  [[ "${wallet_type}" == "Hardware" ]]
}

cntools_wallet_hardware_create() {
  local name="${1:-}"
  local account_input="${2:-}"
  local key_index_input="${3:-}"
  local account=""
  local key_index=""
  local target=""
  local stage=""
  local complete="N"

  cntools_wallet_hardware_reset_result
  cntools_wallet_create_name_valid "${name}" || {
    cntools_wallet_hardware_set_error \
      "Wallet names must use 1–64 ASCII letters, numbers, dots, underscores, or hyphens, and must start with a letter or number."
    return 2
  }
  cntools_wallet_hardware_index_into account "${account_input}" || {
    cntools_wallet_hardware_set_error \
      "The account number must be between 0 and 2,147,483,647."
    return 2
  }
  cntools_wallet_hardware_index_into key_index "${key_index_input}" || {
    cntools_wallet_hardware_set_error \
      "The key index must be between 0 and 2,147,483,647."
    return 2
  }
  if ! cntools_wallet_create_environment_ready; then
    CNTOOLS_WALLET_HARDWARE_ERROR="${CNTOOLS_WALLET_CREATE_ERROR}"
    return 1
  fi
  cntools_wallet_hardware_require || return 1
  if ! cntools_wallet_create_root_prepare; then
    CNTOOLS_WALLET_HARDWARE_ERROR="${CNTOOLS_WALLET_CREATE_ERROR}"
    return 1
  fi
  cntools_wallet_create_target_into target "${name}" || {
    cntools_wallet_hardware_set_error \
      "The hardware wallet target could not be resolved safely."
    return 2
  }
  if [[ -e "${target}" || -L "${target}" ]]; then
    cntools_wallet_hardware_set_error \
      "A wallet or filesystem entry named ${name} already exists."
    return 1
  fi
  cntools_wallet_create_stage_into stage || {
    cntools_wallet_hardware_set_error \
      "A private staging directory could not be created."
    return 1
  }
  cntools_wallet_hardware_log WALLET \
    "creating wallet=${name} type=Hardware network=${CNTOOLS_NETWORK} account=${account} key_index=${key_index}"
  if ! cntools_wallet_hardware_export \
      "${stage}" "${account}" "${key_index}"; then
    : # The export helper recorded a focused error.
  elif ! cntools_wallet_hardware_path_write \
      "${stage}" "${account}" "${key_index}"; then
    cntools_wallet_hardware_set_error \
      "The hardware-wallet derivation path could not be recorded safely."
  elif ! cntools_wallet_materialize_wallet "${stage}"; then
    cntools_wallet_hardware_set_error \
      "The addresses or credentials could not be derived from the hardware wallet keys."
  elif ! cntools_wallet_hardware_required_entries_valid "${stage}"; then
    cntools_wallet_hardware_set_error \
      "The imported hardware wallet did not pass complete artifact validation."
  else
    complete="Y"
  fi
  if [[ "${complete}" != "Y" ]]; then
    [[ -n "${CNTOOLS_WALLET_HARDWARE_ERROR}" ]] ||
      cntools_wallet_hardware_set_error "Hardware wallet import failed."
    cntools_wallet_material_cleanup
    cntools_wallet_create_remove_stage "${stage}" || true
    [[ -z "${CNTOOLS_WALLET_CREATE_CLEANUP_WARNING}" ]] ||
      CNTOOLS_WALLET_HARDWARE_ERROR+=" ${CNTOOLS_WALLET_CREATE_CLEANUP_WARNING}"
    CNTOOLS_WALLET_CREATE_ERROR="${CNTOOLS_WALLET_HARDWARE_ERROR}"
    return 1
  fi
  if ! cntools_wallet_create_publish \
      "${stage}" "${target}" \
      cntools_wallet_hardware_required_entries_valid; then
    cntools_wallet_material_cleanup
    cntools_wallet_create_remove_stage "${stage}" || true
    [[ -n "${CNTOOLS_WALLET_CREATE_ERROR}" ]] &&
      CNTOOLS_WALLET_HARDWARE_ERROR="${CNTOOLS_WALLET_CREATE_ERROR}"
    return 1
  fi
  CNTOOLS_WALLET_CREATED_NAME="${name}"
  CNTOOLS_WALLET_CREATED_DIRECTORY="${target}"
  CNTOOLS_WALLET_HARDWARE_ACCOUNT="${account}"
  CNTOOLS_WALLET_HARDWARE_KEY_INDEX="${key_index}"
  cntools_wallet_hardware_log WALLET \
    "created wallet=${name} type=Hardware network=${CNTOOLS_NETWORK} account=${account} key_index=${key_index}"
}
