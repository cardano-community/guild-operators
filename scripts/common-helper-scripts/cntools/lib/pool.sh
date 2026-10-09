#!/usr/bin/env bash
# Read-only inventory. Never derive public files from private keys or rewrite IDs.
# shellcheck disable=SC2034
declare -a CNTOOLS_POOL_NAMES=() CNTOOLS_POOL_DIRECTORIES=() CNTOOLS_POOL_IDS=() CNTOOLS_POOL_HEX_IDS=()
declare -a CNTOOLS_POOL_IDENTITIES=() CNTOOLS_POOL_PROTECTIONS=() CNTOOLS_POOL_WARNINGS=()

cntools_pool_file_name_into() {
  local output="$1" kind="$2" chosen=""
  case "${kind}" in
    id) chosen="${CNTOOLS_POOL_ID_FILENAME:-pool.id}" ;;
    cold-vkey) chosen="${CNTOOLS_POOL_COLD_VKEY_FILENAME:-cold.vkey}" ;;
    cold-skey) chosen="${CNTOOLS_POOL_COLD_SKEY_FILENAME:-cold.skey}" ;;
    cold-hardware) chosen="${CNTOOLS_POOL_COLD_HW_FILENAME:-cold.hwsfile}" ;;
    calidus-skey) chosen="${CNTOOLS_POOL_CALIDUS_SKEY_FILENAME:-calidus.skey}" ;;
    calidus-vkey) chosen="${CNTOOLS_POOL_CALIDUS_VKEY_FILENAME:-calidus.vkey}" ;;
    calidus-id) chosen="${CNTOOLS_POOL_CALIDUS_ID_FILENAME:-calidus.id}" ;;
    kes-vkey) chosen="${CNTOOLS_POOL_KES_VKEY_FILENAME:-hot.vkey}" ;;
    kes-skey) chosen="${CNTOOLS_POOL_KES_SKEY_FILENAME:-hot.skey}" ;;
    vrf-vkey) chosen="${CNTOOLS_POOL_VRF_VKEY_FILENAME:-vrf.vkey}" ;;
    vrf-skey) chosen="${CNTOOLS_POOL_VRF_SKEY_FILENAME:-vrf.skey}" ;;
    counter) chosen="${CNTOOLS_POOL_COUNTER_FILENAME:-cold.counter}" ;;
    opcert) chosen="${CNTOOLS_POOL_OPCERT_FILENAME:-op.cert}" ;;
    kes-start) chosen="${CNTOOLS_POOL_KES_START_FILENAME:-kes.start}" ;;
    config) chosen="${CNTOOLS_POOL_CONFIG_FILENAME:-pool.config}" ;;
    metadata) chosen=poolmeta.json ;;
    *) return 2 ;;
  esac
  [[ "${chosen}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 2
  printf -v "${output}" '%s' "${chosen}"
}

cntools_pool_public_file_safe() {
  cntools_transaction_path_components_safe "$1" && cntools_wallet_safe_regular_file "$1" "${2:-65536}" && [[ -r "$1" ]]
}

cntools_pool_warning_add() {
  local index="$1" message="$2"
  CNTOOLS_POOL_WARNINGS[index]+="${CNTOOLS_POOL_WARNINGS[index]:+; }${message}"
  cntools_transaction_log WARN "Pool=${CNTOOLS_POOL_NAMES[index]} ${message}"
}

cntools_pool_identity_read() {
  local index="$1" directory="${CNTOOLS_POOL_DIRECTORIES[$1]}" file="" filename=""
  local derived="" derived_hex="" cached="" cached_hex="" response="" errors="" status=0 conflict=N
  local cold_present=N
  cntools_pool_file_name_into filename cold-vkey || return 2
  file="${directory}/${filename}"
  if [[ -e "${file}" || -L "${file}" ]]; then
    cold_present=Y
    if cntools_pool_public_file_safe "${file}" &&
        jq -e '.type == "StakePoolVerificationKey_ed25519" and (.cborHex | type == "string" and test("^5820[0-9a-fA-F]{64}$"))' "${file}" >/dev/null 2>&1; then
      if [[ -n "${CNTOOLS_CLI:-}" && -x "${CNTOOLS_CLI}" ]]; then
        cntools_transaction_temp_file response pool-identity || return 2
        cntools_transaction_temp_file errors pool-identity-errors || return 2
        cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" latest stake-pool id \
          --cold-verification-key-file "${file}" --output-bech32 || status=$?
        if (( status == 0 )) && cntools_pool_id_into derived derived_hex "$(< "${response}")"; then
          CNTOOLS_POOL_IDENTITIES[index]='Verified cold public key'
        else
          if (( status != 0 )); then
            cntools_transaction_log_cli_failure 'Could not read pool cold public identity' "${status}" "${errors}" "${response}"
          else
            cntools_transaction_log ERROR "CLI returned an invalid pool ID for ${file}"
          fi
          cntools_pool_warning_add "${index}" 'Cold public key could not be verified'
        fi
      else
        cntools_pool_warning_add "${index}" 'CLI unavailable; cold public identity not verified'
      fi
    else
      conflict=Y
      cntools_pool_warning_add "${index}" 'Invalid or unsafe cold public key'
    fi
  fi
  cntools_pool_file_name_into filename id || return 2
  for file in "${directory}/${filename}" "${directory}/${filename}-bech32"; do
    [[ -e "${file}" || -L "${file}" ]] || continue
    if ! cntools_pool_public_file_safe "${file}" 1024 || ! cntools_pool_id_into cached cached_hex "$(< "${file}")"; then
      conflict=Y; cntools_pool_warning_add "${index}" "Invalid or unsafe ${file##*/}"; continue
    fi
    if [[ -n "${CNTOOLS_POOL_IDS[index]}" && "${CNTOOLS_POOL_IDS[index]}" != "${cached}" ]] ||
        [[ -n "${derived}" && "${derived}" != "${cached}" ]]; then
      conflict=Y; cntools_pool_warning_add "${index}" 'Stored pool ID does not match the public identity'
    fi
    CNTOOLS_POOL_IDS[index]="${cached}"; CNTOOLS_POOL_HEX_IDS[index]="${cached_hex}"
  done
  if [[ -n "${derived}" ]]; then
    CNTOOLS_POOL_IDS[index]="${derived}"; CNTOOLS_POOL_HEX_IDS[index]="${derived_hex}"
  elif [[ -n "${CNTOOLS_POOL_IDS[index]}" ]]; then
    CNTOOLS_POOL_IDENTITIES[index]='Stored ID only'
    [[ "${cold_present}" != Y ]] || conflict=Y
  else
    CNTOOLS_POOL_IDENTITIES[index]='Missing public identity'
  fi
  [[ "${conflict}" != Y ]] || CNTOOLS_POOL_IDENTITIES[index]='Identity needs attention'
}

cntools_pool_key_state_into() {
  local output="$1" directory="$2" kind="$3" filename="" state='Missing'
  cntools_pool_file_name_into filename "${kind}" || return 2
  # Only inspect file attributes, never read private key contents.
  if [[ -f "${directory}/${filename}" && ! -L "${directory}/${filename}" ]]; then state=Open; fi
  if [[ -f "${directory}/${filename}.gpg" && ! -L "${directory}/${filename}.gpg" ]]; then
    if [[ "${state}" == Open ]]; then state='Open + encrypted copy'; else state=Encrypted; fi
  fi
  if [[ "${kind}" == cold-skey ]]; then
    cntools_pool_file_name_into filename cold-hardware || return 2
    if [[ -f "${directory}/${filename}" && ! -L "${directory}/${filename}" ]]; then
      if [[ "${state}" == Missing ]]; then state=Hardware; else state='Mixed key material'; fi
    fi
  fi
  printf -v "${output}" '%s' "${state}"
}

cntools_pool_catalog_build() {
  local root="${CNTOOLS_POOL_DIR:-}" directory="" name="" index=0 kind="" filename="" key_state=""
  CNTOOLS_POOL_NAMES=(); CNTOOLS_POOL_DIRECTORIES=(); CNTOOLS_POOL_IDS=(); CNTOOLS_POOL_HEX_IDS=()
  CNTOOLS_POOL_IDENTITIES=(); CNTOOLS_POOL_PROTECTIONS=(); CNTOOLS_POOL_WARNINGS=()
  [[ "${root}" == /* && "${root}" != / ]] && cntools_transaction_path_components_safe "${root}" || return 1
  [[ -e "${root}" ]] || return 0
  [[ -d "${root}" && -r "${root}" && -x "${root}" ]] || return 1
  # Globbing provides lexical order without an external sort or hidden staging dirs.
  local LC_ALL=C
  for directory in "${root}"/*; do
    [[ -d "${directory}" ]] || continue
    name="${directory##*/}"
    if [[ -L "${directory}" || ! "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9_.\ -]*$ ]] ||
        ! cntools_transaction_path_components_safe "${directory}" || [[ ! -r "${directory}" || ! -x "${directory}" ]]; then
      cntools_transaction_log WARN "Skipping unsafe pool directory=${directory}"; continue
    fi
    index="${#CNTOOLS_POOL_NAMES[@]}"
    CNTOOLS_POOL_NAMES+=("${name}"); CNTOOLS_POOL_DIRECTORIES+=("${directory}")
    CNTOOLS_POOL_IDS+=(''); CNTOOLS_POOL_HEX_IDS+=(''); CNTOOLS_POOL_IDENTITIES+=(''); CNTOOLS_POOL_WARNINGS+=('')
    cntools_pool_key_state_into key_state "${directory}" cold-skey || return 1
    CNTOOLS_POOL_PROTECTIONS+=("${key_state}")
    for kind in id cold-vkey cold-skey cold-hardware kes-vkey kes-skey vrf-vkey vrf-skey counter opcert config; do
      cntools_pool_file_name_into filename "${kind}" || return 1
      if [[ -L "${directory}/${filename}" || -L "${directory}/${filename}.gpg" ]]; then
        cntools_pool_warning_add "${index}" "Unsafe linked ${filename} ignored"
      fi
    done
    cntools_pool_identity_read "${index}" || return 1
  done
}

cntools_pool_choose_into() {
  local _pool_output="$1" _pool_choice="" _pool_index=0 _pool_row=""
  local -a _pool_rows=()
  for _pool_index in "${!CNTOOLS_POOL_NAMES[@]}"; do
    printf -v _pool_row '%02d  %s · %s' "$((_pool_index + 1))" "${CNTOOLS_POOL_NAMES[_pool_index]}" "${CNTOOLS_POOL_PROTECTIONS[_pool_index]}"
    _pool_rows+=("${_pool_row}")
  done
  cntools_ui_choose _pool_choice 'Filter pools…' "${_pool_rows[@]}" Cancel || return $?
  [[ "${_pool_choice}" != Cancel ]] || return 1
  for _pool_index in "${!_pool_rows[@]}"; do
    if [[ "${_pool_choice}" == "${_pool_rows[_pool_index]}" ]]; then
      printf -v "${_pool_output}" '%s' "${_pool_index}"
      cntools_transaction_log CHOICE "Pool selected=${CNTOOLS_POOL_NAMES[_pool_index]}"
      return 0
    fi
  done
  return 2
}
