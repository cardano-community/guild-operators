#!/usr/bin/env bash
# Mixed CLI/hardware and incremental offline transaction signing. Functions only.
# shellcheck disable=SC2034

CNTOOLS_TRANSACTION_HWCLI_REQUIRED_VERSION="1.19.1"
CNTOOLS_TRANSACTION_HARDWARE_TIMEOUT="${CNTOOLS_TRANSACTION_HARDWARE_TIMEOUT:-300}"
[[ "${CNTOOLS_TRANSACTION_HARDWARE_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] ||
  CNTOOLS_TRANSACTION_HARDWARE_TIMEOUT=300
CNTOOLS_TRANSACTION_HWCLI=""
CNTOOLS_TRANSACTION_HWCLI_VERSION=""
CNTOOLS_TRANSACTION_SIGN_OUTPUT=""
CNTOOLS_TRANSACTION_SIGN_ADDED=0
CNTOOLS_TRANSACTION_SIGN_COMPLETE="N"

declare -ag CNTOOLS_TRANSACTION_SELECTED_KEY_IDS=()
declare -ag CNTOOLS_TRANSACTION_SELECTED_SOURCES=()
declare -ag CNTOOLS_TRANSACTION_SELECTED_KINDS=()
declare -ag CNTOOLS_TRANSACTION_SELECTED_HARDWARE_GROUPS=()
declare -ag CNTOOLS_TRANSACTION_SELECTED_CHANGE_KEY_IDS=()
declare -ag CNTOOLS_TRANSACTION_SELECTED_CHANGE_SOURCES=()
declare -ag CNTOOLS_TRANSACTION_SELECTED_CHANGE_HARDWARE_GROUPS=()

cntools_transaction_require_hwcli() {
  local candidate="${CNTOOLS_HWCLI:-cardano-hw-cli}"
  local resolved=""
  local output_file=""
  local error_file=""
  local output=""
  local version=""
  local status=0

  if [[ -n "${CNTOOLS_TRANSACTION_HWCLI}" &&
        "${CNTOOLS_TRANSACTION_HWCLI}" = /* &&
        -x "${CNTOOLS_TRANSACTION_HWCLI}" &&
        ! -d "${CNTOOLS_TRANSACTION_HWCLI}" &&
        "${CNTOOLS_TRANSACTION_HWCLI_VERSION}" == \
          "${CNTOOLS_TRANSACTION_HWCLI_REQUIRED_VERSION}" ]]; then
    return 0
  fi
  CNTOOLS_TRANSACTION_HWCLI=""
  CNTOOLS_TRANSACTION_HWCLI_VERSION=""
  resolved="$(cntools_startup_resolve_command "${candidate}" 2>/dev/null || true)"
  if [[ -z "${resolved}" ]]; then
    cntools_transaction_set_error \
      "cardano-hw-cli ${CNTOOLS_TRANSACTION_HWCLI_REQUIRED_VERSION} is required for hardware signing."
    return 1
  fi
  cntools_transaction_temp_file output_file hw-version-output || return 1
  cntools_transaction_temp_file error_file hw-version-error || return 1
  if cntools_transaction_run_cli "${output_file}" "${error_file}" -- \
      "${resolved}" version; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_transaction_log_cli_failure \
      "cardano-hw-cli could not be started" "${status}" \
      "${error_file}" "${output_file}"
    return 1
  fi
  output="$(< "${output_file}")"
  if [[ "${output}" =~ Cardano[[:space:]]+HW[[:space:]]+CLI[[:space:]]+Tool[[:space:]]+version[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?) ]]; then
    version="${BASH_REMATCH[1]}"
  fi
  if [[ "${version}" != "${CNTOOLS_TRANSACTION_HWCLI_REQUIRED_VERSION}" ]]; then
    cntools_transaction_set_error \
      "cardano-hw-cli ${version:-unknown} is unsupported; exactly ${CNTOOLS_TRANSACTION_HWCLI_REQUIRED_VERSION} is required."
    return 1
  fi
  CNTOOLS_TRANSACTION_HWCLI="${resolved}"
  CNTOOLS_TRANSACTION_HWCLI_VERSION="${version}"
  cntools_transaction_log HARDWARE \
    "cardano-hw-cli ready version=${version} path=${resolved}"
}

cntools_transaction_hardware_device_check() {
  local output_file=""
  local error_file=""
  local status=0

  cntools_transaction_require_hwcli || return 1
  cntools_transaction_temp_file output_file hw-device-output || return 1
  cntools_transaction_temp_file error_file hw-device-error || return 1
  if cntools_transaction_run_cli "${output_file}" "${error_file}" -- \
      "${CNTOOLS_TRANSACTION_HWCLI}" device version; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_transaction_log_cli_failure \
      "The hardware wallet could not be reached" "${status}" \
      "${error_file}" "${output_file}"
    return 1
  fi
  cntools_transaction_log HARDWARE \
    "device ready $(cntools_log_sanitize_line "$(< "${output_file}")")"
}

cntools_transaction_hardware_validate_status() {
  local body_file="${1:-}"
  local output_file=""
  local error_file=""
  local kind=""
  local status=0
  local mask=""
  local -a command=()

  cntools_transaction_require_hwcli || return 1
  cntools_transaction_envelope_kind_into kind "${body_file}" || return 1
  [[ "${kind}" == "body" || "${kind}" == "transaction" ]] || return 2
  cntools_transaction_temp_file output_file hw-validate-output || return 1
  cntools_transaction_temp_file error_file hw-validate-error || return 1
  command=("${CNTOOLS_TRANSACTION_HWCLI}" transaction validate
    --tx-file "${body_file}")
  printf -v mask '%*s' "${#command[@]}" ''
  mask="${mask// /0}"
  if cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" \
      "${mask}" -- "${command[@]}" \
      > "${output_file}" 2> "${error_file}"; then
    status=0
  else
    status=$?
  fi
  case "${status}" in
    0|3) return "${status}" ;;
    1|2)
      cntools_transaction_log_cli_failure \
        "The transaction is not compatible with hardware signing" \
        "${status}" "${error_file}" "${output_file}"
      return "${status}"
      ;;
    *)
      cntools_transaction_log_cli_failure \
        "Hardware transaction validation failed" \
        "${status}" "${error_file}" "${output_file}"
      return "${status}"
      ;;
  esac
}

cntools_transaction_prepare_hardware_body_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_body_file="${2:-}"
  local _cntools_existing_witnesses="${3:-0}"
  local _cntools_transformed_file=""
  local _cntools_output_file=""
  local _cntools_error_file=""
  local _cntools_original_id=""
  local _cntools_normalized_id=""
  local _cntools_kind=""
  local _cntools_envelope_type=""
  local _cntools_normalized_file=""
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_existing_witnesses}" =~ ^[0-9]+$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_envelope_kind_into \
    _cntools_kind "${_cntools_body_file}" || return 1
  _cntools_envelope_type="$(jq -er '.type' "${_cntools_body_file}")" || return 1
  if [[ "${_cntools_kind}" == "body" &&
        "${_cntools_envelope_type}" == TxBody\ * ]]; then
    # The pinned cardano-hw-cli 1.19.1 accepts full transaction envelopes.
    # Normalize an older/external TxBody envelope without adding witnesses;
    # the body hash and any detached witnesses remain unchanged.
    cntools_transaction_id_into \
      _cntools_original_id "${_cntools_body_file}" || return 1
    cntools_transaction_temp_file \
      _cntools_normalized_file hw-normalized-body || return 1
    cntools_transaction_assemble_witness_files \
      "${_cntools_normalized_file}" "${_cntools_body_file}" || return 1
    cntools_transaction_id_into \
      _cntools_normalized_id "${_cntools_normalized_file}" || return 1
    if (( _cntools_existing_witnesses > 0 )) &&
       [[ "${_cntools_normalized_id}" != "${_cntools_original_id}" ]]; then
      cntools_transaction_set_error \
        "Hardware normalization would change a transaction that already has witnesses. Rebuild the package with canonical CBOR before collecting any signature."
      return 1
    fi
    _cntools_body_file="${_cntools_normalized_file}"
  fi
  if cntools_transaction_hardware_validate_status "${_cntools_body_file}"; then
    _cntools_output_ref="${_cntools_body_file}"
    return 0
  else
    _cntools_status=$?
  fi
  (( _cntools_status == 3 )) || return "${_cntools_status}"
  if (( _cntools_existing_witnesses > 0 )); then
    cntools_transaction_set_error \
      "Hardware preparation would change a transaction that already has witnesses. Rebuild the package with canonical CBOR before collecting any signature."
    return 1
  fi
  cntools_transaction_temp_file \
    _cntools_transformed_file hw-transformed-body || return 1
  cntools_transaction_temp_file _cntools_output_file hw-transform-output || return 1
  cntools_transaction_temp_file _cntools_error_file hw-transform-error || return 1
  if cntools_transaction_run_cli \
      "${_cntools_output_file}" "${_cntools_error_file}" -- \
      "${CNTOOLS_TRANSACTION_HWCLI}" transaction transform \
      --tx-file "${_cntools_body_file}" \
      --out-file "${_cntools_transformed_file}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  if (( _cntools_status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Hardware transaction transformation failed" "${_cntools_status}" \
      "${_cntools_error_file}" "${_cntools_output_file}"
    return 1
  fi
  cntools_transaction_envelope_kind_into \
    _cntools_kind "${_cntools_transformed_file}" || return 1
  [[ "${_cntools_kind}" == "body" ||
     "${_cntools_kind}" == "transaction" ]] || {
    cntools_transaction_set_error \
      "cardano-hw-cli produced an invalid transformed transaction body."
    return 1
  }
  if cntools_transaction_hardware_validate_status \
      "${_cntools_transformed_file}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  (( _cntools_status == 0 )) || {
    cntools_transaction_set_error \
      "The transformed transaction still failed hardware validation."
    return 1
  }
  _cntools_output_ref="${_cntools_transformed_file}"
  cntools_transaction_log HARDWARE \
    "transaction body transformed before witnessing"
}

cntools_transaction_hardware_body_signable() {
  local body_file="${1:-}"
  local status=0

  if cntools_transaction_hardware_validate_status "${body_file}"; then
    return 0
  else
    status=$?
  fi
  if (( status == 3 )); then
    cntools_transaction_set_error \
      "Hardware signing now requires a transaction transformation after the final review. Nothing was signed; prepare and review the package again."
  fi
  return 1
}

cntools_transaction_package_prepare_hardware_into() {
  local _cntools_output_name="${1:-}"
  local package_file="${2:-}"
  local prepared_body_file=""
  local body_kind=""
  local transaction_id=""
  local staged_file=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_package_load "${package_file}" || return 1
  package_file="${CNTOOLS_TRANSACTION_PACKAGE_FILE}"
  # The marker records provenance; it is never trusted as a substitute for
  # validating the actual body with the currently deployed hardware CLI.
  cntools_transaction_prepare_hardware_body_into \
    prepared_body_file "${CNTOOLS_TRANSACTION_BODY_FILE}" \
    "${CNTOOLS_TRANSACTION_WITNESS_COUNT}" || return 1
  cntools_transaction_envelope_kind_into \
    body_kind "${prepared_body_file}" || return 1
  [[ "${body_kind}" == "body" || "${body_kind}" == "transaction" ]] ||
    return 1
  cntools_transaction_id_into transaction_id "${prepared_body_file}" || return 1
  cntools_transaction_temp_file staged_file hardware-package || return 1
  jq --slurpfile body "${prepared_body_file}" \
    --arg id "${transaction_id}" '
    .transaction.body = $body[0] |
    .transaction.id = $id |
    .transaction.hardwarePrepared = true
  ' "${package_file}" > "${staged_file}" || return 1
  cntools_transaction_package_structure_valid "${staged_file}" || {
    cntools_transaction_set_error \
      "The hardware-prepared transaction package failed validation."
    return 1
  }
  cntools_transaction_package_load "${staged_file}" || {
    cntools_transaction_set_error \
      "The hardware-prepared transaction package failed semantic validation."
    return 1
  }
  _cntools_output_ref="${staged_file}"
}

cntools_transaction_witness_cli() {
  local body_file="${1:-}"
  local source_file="${2:-}"
  local witness_file="${3:-}"
  local output_file=""
  local error_file=""
  local kind=""
  local status=0
  local -a network_arguments=()

  cntools_transaction_require_cli || return 1
  cntools_transaction_source_kind_into kind "${source_file}" || return 1
  [[ "${kind}" == "cli" && -f "${witness_file}" &&
     ! -L "${witness_file}" && -O "${witness_file}" ]] || return 2
  cntools_transaction_network_arguments_into \
    network_arguments "${CNTOOLS_TRANSACTION_PACKAGE_NETWORK:-${CNTOOLS_NETWORK}}" ||
    return 1
  cntools_transaction_temp_file output_file witness-output || return 1
  cntools_transaction_temp_file error_file witness-error || return 1
  if cntools_transaction_run_cli "${output_file}" "${error_file}" -- \
      "${CNTOOLS_CLI}" latest transaction witness \
      --tx-body-file "${body_file}" \
      --signing-key-file "${source_file}" \
      "${network_arguments[@]}" \
      --out-file "${witness_file}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_transaction_log_cli_failure \
      "CLI transaction witnessing failed" "${status}" \
      "${error_file}" "${output_file}"
    return 1
  fi
  cntools_transaction_envelope_kind_into kind "${witness_file}" || return 1
  [[ "${kind}" == "witness" ]] || {
    cntools_transaction_set_error \
      "Cardano CLI did not produce a valid transaction witness."
    return 1
  }
}

cntools_transaction_witness_hardware_batch() {
  local body_file="${1:-}"
  local sources_name="${2:-}"
  local outputs_name="${3:-}"
  local change_sources_name="${4:-}"
  local source=""
  local output=""
  local output_file=""
  local error_file=""
  local kind=""
  local status=0
  local mask=""
  local -a network_arguments=()
  local -a command=()

  [[ "${sources_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${outputs_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${change_sources_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n sources_ref="${sources_name}"
  local -n outputs_ref="${outputs_name}"
  local -n change_sources_ref="${change_sources_name}"
  (( ${#sources_ref[@]} > 0 &&
     ${#sources_ref[@]} == ${#outputs_ref[@]} )) || return 2
  cntools_transaction_require_hwcli || return 1
  cntools_transaction_hardware_device_check || return 1
  cntools_transaction_network_arguments_into \
    network_arguments "${CNTOOLS_TRANSACTION_PACKAGE_NETWORK:-${CNTOOLS_NETWORK}}" ||
    return 1
  command=("${CNTOOLS_TRANSACTION_HWCLI}" transaction witness
    --tx-file "${body_file}")
  for source in "${sources_ref[@]}"; do
    cntools_transaction_source_kind_into kind "${source}" || return 1
    [[ "${kind}" == "hardware" ]] || return 2
    command+=(--hw-signing-file "${source}")
  done
  for source in "${change_sources_ref[@]}"; do
    cntools_transaction_source_kind_into kind "${source}" || return 1
    [[ "${kind}" == "hardware" ]] || return 2
    cntools_transaction_hardware_change_source_valid "${source}" || return 2
    command+=(--change-output-key-file "${source}")
  done
  command+=("${network_arguments[@]}")
  for output in "${outputs_ref[@]}"; do
    [[ -f "${output}" && ! -L "${output}" && -O "${output}" ]] || return 2
    command+=(--out-file "${output}")
  done
  cntools_transaction_temp_file output_file hw-witness-output || return 1
  cntools_transaction_temp_file error_file hw-witness-error || return 1
  printf -v mask '%*s' "${#command[@]}" ''
  mask="${mask// /0}"
  if cntools_run_command_timeout "${CNTOOLS_TRANSACTION_HARDWARE_TIMEOUT}" \
      "${mask}" -- "${command[@]}" \
      > "${output_file}" 2> "${error_file}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    if (( status == 124 )); then
      cntools_transaction_set_error \
        "Hardware transaction witnessing timed out after ${CNTOOLS_TRANSACTION_HARDWARE_TIMEOUT} seconds."
    else
      cntools_transaction_log_cli_failure \
        "Hardware transaction witnessing failed" "${status}" \
        "${error_file}" "${output_file}"
    fi
    return 1
  fi
  for output in "${outputs_ref[@]}"; do
    cntools_transaction_envelope_kind_into kind "${output}" || return 1
    [[ "${kind}" == "witness" ]] || {
      cntools_transaction_set_error \
        "cardano-hw-cli did not produce every requested witness."
      return 1
    }
  done
}

cntools_transaction_package_append_witness() {
  local package_file="${1:-}"
  local key_id="${2:-}"
  local kind="${3:-}"
  local witness_file="${4:-}"
  local output_file="${5:-}"
  local witness_kind=""
  local body_file=""
  local created_at=""

  [[ "${key_id}" =~ ^[0-9a-f]{64}$ ]] || return 2
  case "${kind}" in cli|hardware) ;; *) return 2 ;; esac
  cntools_transaction_package_structure_valid "${package_file}" || return 1
  jq -e --arg id "${key_id}" '
    any(.signing.required[]; .keyId == $id) and
    (any(.signing.witnesses[]; .keyId == $id) | not)
  ' "${package_file}" >/dev/null || return 1
  cntools_transaction_temp_file body_file witness-body || return 1
  jq '.transaction.body' "${package_file}" > "${body_file}" || return 1
  if ! cntools_transaction_witness_matches_key \
      "${body_file}" "${witness_file}" "${key_id}"; then
    if [[ -z "${CNTOOLS_TRANSACTION_ERROR}" ]]; then
      cntools_transaction_set_error \
        "The generated transaction witness does not match its planned signing key."
    fi
    return 1
  fi
  cntools_transaction_envelope_kind_into \
    witness_kind "${witness_file}" || return 1
  [[ "${witness_kind}" == "witness" ]] || return 1
  created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
  jq --arg id "${key_id}" --arg kind "${kind}" \
    --arg created_at "${created_at}" \
    --slurpfile witness "${witness_file}" '
      .signing.witnesses += [{
        keyId: $id,
        kind: $kind,
        createdAt: $created_at,
        witness: $witness[0]
      }] |
      .signedTransaction = null
    ' "${package_file}" > "${output_file}" || return 1
  cntools_transaction_package_structure_valid "${output_file}" Y
}

cntools_transaction_package_assemble() {
  local package_file="${1:-}"
  local output_file="${2:-}"
  local body_file=""
  local signed_file=""
  local witness_file=""
  local witness_count=0
  local index=0
  local kind=""
  local expected_id=""
  local signed_id=""
  local -a witness_files=()

  cntools_transaction_package_load "${package_file}" Y || return 1
  package_file="${CNTOOLS_TRANSACTION_PACKAGE_FILE}"
  (( CNTOOLS_TRANSACTION_WITNESS_COUNT == CNTOOLS_TRANSACTION_REQUIRED_COUNT )) || {
    cntools_transaction_set_error \
      "The transaction cannot be assembled until every planned signer has witnessed it."
    return 1
  }
  body_file="${CNTOOLS_TRANSACTION_BODY_FILE}"
  expected_id="${CNTOOLS_TRANSACTION_ID}"
  witness_count="${CNTOOLS_TRANSACTION_WITNESS_COUNT}"
  for (( index = 0; index < witness_count; index++ )); do
    cntools_transaction_temp_file witness_file assembled-witness || return 1
    jq --argjson index "${index}" '.signing.witnesses[$index].witness' \
      "${package_file}" > "${witness_file}" || return 1
    cntools_transaction_envelope_kind_into kind "${witness_file}" || return 1
    [[ "${kind}" == "witness" ]] || return 1
    witness_files+=("${witness_file}")
  done
  cntools_transaction_temp_file signed_file signed || return 1
  cntools_transaction_assemble_witness_files \
    "${signed_file}" "${body_file}" "${witness_files[@]}" || return 1
  cntools_transaction_envelope_kind_into kind "${signed_file}" || return 1
  [[ "${kind}" == "transaction" ]] || {
    cntools_transaction_set_error \
      "Cardano CLI did not produce a valid signed transaction."
    return 1
  }
  cntools_transaction_id_into signed_id "${signed_file}" || return 1
  [[ "${signed_id}" == "${expected_id}" ]] || {
    cntools_transaction_set_error \
      "The assembled transaction ID differs from the unsigned body ID."
    return 1
  }
  jq --slurpfile signed "${signed_file}" \
    '.signedTransaction = $signed[0]' \
    "${package_file}" > "${output_file}" ||
    return 1
  cntools_transaction_package_structure_valid "${output_file}" || return 1
  cntools_transaction_package_load "${output_file}" || return 1
  [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == "Y" ]] || {
    cntools_transaction_set_error \
      "The assembled transaction package did not pass final completion validation."
    return 1
  }
  cntools_transaction_log TRANSACTION \
    "assembled id=${expected_id} witnesses=${witness_count}"
}

cntools_transaction_sign_selection_reset() {
  CNTOOLS_TRANSACTION_SELECTED_KEY_IDS=()
  CNTOOLS_TRANSACTION_SELECTED_SOURCES=()
  CNTOOLS_TRANSACTION_SELECTED_KINDS=()
  CNTOOLS_TRANSACTION_SELECTED_HARDWARE_GROUPS=()
  CNTOOLS_TRANSACTION_SELECTED_CHANGE_KEY_IDS=()
  CNTOOLS_TRANSACTION_SELECTED_CHANGE_SOURCES=()
  CNTOOLS_TRANSACTION_SELECTED_CHANGE_HARDWARE_GROUPS=()
}

cntools_transaction_sign_selection_add() {
  local package_file="${1:-}"
  local source_file="${2:-}"
  local key_id=""
  local kind=""
  local hardware_group=""
  local preferred_kind=""
  local existing=""

  cntools_transaction_source_kind_into kind "${source_file}" || {
    cntools_transaction_set_error \
      "The selected signing source is unsafe, too permissive, or unsupported: ${source_file}"
    return 1
  }
  cntools_transaction_source_key_id_into key_id "${source_file}" || return 1
  IFS=$'\037' read -r hardware_group preferred_kind < <(jq -r \
    --arg id "${key_id}" '
      .signing.required[] | select(.keyId == $id) |
      [(.hardwareGroup // ""), .preferredKind] | join("\u001f")
    ' "${package_file}") || return 1
  jq -e --arg id "${key_id}" '
    any(.signing.required[]; .keyId == $id) and
    (any(.signing.witnesses[]; .keyId == $id) | not)
  ' "${package_file}" >/dev/null || {
    cntools_transaction_set_error \
      "The selected key is not a missing signer in this transaction package."
    return 1
  }
  if [[ "${preferred_kind}" != "either" &&
        "${preferred_kind}" != "${kind}" ]]; then
    cntools_transaction_set_error \
      "The selected ${kind} key does not match the planned ${preferred_kind} signing method."
    return 1
  fi
  for existing in "${CNTOOLS_TRANSACTION_SELECTED_KEY_IDS[@]}"; do
    [[ "${existing}" != "${key_id}" ]] || return 0
  done
  CNTOOLS_TRANSACTION_SELECTED_KEY_IDS+=("${key_id}")
  CNTOOLS_TRANSACTION_SELECTED_SOURCES+=("${source_file}")
  CNTOOLS_TRANSACTION_SELECTED_KINDS+=("${kind}")
  CNTOOLS_TRANSACTION_SELECTED_HARDWARE_GROUPS+=("${hardware_group}")
}

cntools_transaction_change_selection_add() {
  local package_file="${1:-}"
  local source_file="${2:-}"
  local key_id=""
  local kind=""
  local hardware_group=""
  local existing=""

  cntools_transaction_source_kind_into kind "${source_file}" || {
    cntools_transaction_set_error \
      "The selected hardware change reference is unsafe, too permissive, or unsupported: ${source_file}"
    return 1
  }
  [[ "${kind}" == "hardware" ]] || {
    cntools_transaction_set_error \
      "A transaction change reference must be a hardware signing file."
    return 1
  }
  cntools_transaction_hardware_change_source_valid "${source_file}" || {
    cntools_transaction_set_error \
      "A hardware change reference must be a standard CIP-1852 payment or stake hardware key."
    return 1
  }
  cntools_transaction_source_key_id_into key_id "${source_file}" || return 1
  hardware_group="$(jq -r --arg id "${key_id}" '
    .signing.changeKeys[] | select(.keyId == $id) | .hardwareGroup
  ' "${package_file}")" || return 1
  [[ -n "${hardware_group}" ]] || {
    cntools_transaction_set_error \
      "The selected hardware key is not a planned change-address reference."
    return 1
  }
  for existing in "${CNTOOLS_TRANSACTION_SELECTED_CHANGE_KEY_IDS[@]}"; do
    [[ "${existing}" != "${key_id}" ]] || return 0
  done
  CNTOOLS_TRANSACTION_SELECTED_CHANGE_KEY_IDS+=("${key_id}")
  CNTOOLS_TRANSACTION_SELECTED_CHANGE_SOURCES+=("${source_file}")
  CNTOOLS_TRANSACTION_SELECTED_CHANGE_HARDWARE_GROUPS+=("${hardware_group}")
}

cntools_transaction_hardware_group_selection_complete() {
  local package_file="${1:-}"
  local hardware_group="${2:-}"
  local selected_json='[]'
  local expected_json=""
  local index=0

  [[ -n "${hardware_group}" ]] || return 0
  expected_json="$(jq -c --arg group "${hardware_group}" '
    [.signing.required[] |
      select((.hardwareGroup // "") == $group) | .keyId] | unique | sort
  ' "${package_file}")" || return 1
  for (( index = 0;
         index < ${#CNTOOLS_TRANSACTION_SELECTED_KEY_IDS[@]};
         index++ )); do
    [[ "${CNTOOLS_TRANSACTION_SELECTED_KINDS[index]}" == "hardware" &&
       "${CNTOOLS_TRANSACTION_SELECTED_HARDWARE_GROUPS[index]}" == "${hardware_group}" ]] ||
      continue
    selected_json="$(jq -c \
      --arg id "${CNTOOLS_TRANSACTION_SELECTED_KEY_IDS[index]}" \
      '. + [$id] | unique' <<< "${selected_json}")" || return 1
  done
  jq -e --argjson expected "${expected_json}" \
    --argjson selected "${selected_json}" \
    '$expected == ($selected | sort)' >/dev/null 2>&1 <<< '{}'
}

cntools_transaction_hardware_group_change_selection_complete() {
  local package_file="${1:-}"
  local hardware_group="${2:-}"
  local expected_json=""
  local selected_json='[]'
  local index=0

  [[ -n "${hardware_group}" ]] || return 0
  expected_json="$(jq -c --arg group "${hardware_group}" '
    [.signing.changeKeys[] |
      select(.hardwareGroup == $group) | .keyId] | unique | sort
  ' "${package_file}")" || return 1
  for (( index = 0;
         index < ${#CNTOOLS_TRANSACTION_SELECTED_CHANGE_KEY_IDS[@]};
         index++ )); do
    [[ "${CNTOOLS_TRANSACTION_SELECTED_CHANGE_HARDWARE_GROUPS[index]}" == "${hardware_group}" ]] ||
      continue
    selected_json="$(jq -c \
      --arg id "${CNTOOLS_TRANSACTION_SELECTED_CHANGE_KEY_IDS[index]}" \
      '. + [$id] | unique' <<< "${selected_json}")" || return 1
  done
  jq -e --argjson expected "${expected_json}" \
    --argjson selected "${selected_json}" \
    '$expected == ($selected | sort)' >/dev/null 2>&1 <<< '{}'
}

cntools_transaction_sign_package() {
  local input_file="${1:-}"
  local output_file="${2:-}"
  local signer_sources_name="${3:-}"
  local change_sources_name="${4:-}"
  local source_file=""
  local working_file=""
  local next_file=""
  local body_file=""
  local witness_file=""
  local key_id=""
  local kind=""
  local hardware_group=""
  local known_group=""
  local index=0
  local group_index=0
  local added=0
  local has_hardware="N"
  local group_seen="N"
  local missing=0
  local -a group_sources=()
  local -a group_outputs=()
  local -a group_change_sources=()
  local -a hardware_groups=()
  local -a no_change_sources=()

  [[ "${signer_sources_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  if [[ -z "${change_sources_name}" ]]; then
    change_sources_name="no_change_sources"
  fi
  [[ "${change_sources_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n signer_sources_ref="${signer_sources_name}"
  local -n change_sources_ref="${change_sources_name}"

  CNTOOLS_TRANSACTION_SIGN_OUTPUT=""
  CNTOOLS_TRANSACTION_SIGN_ADDED=0
  CNTOOLS_TRANSACTION_SIGN_COMPLETE="N"
  cntools_transaction_clear_error
  cntools_transaction_package_load "${input_file}" || return 1
  input_file="${CNTOOLS_TRANSACTION_PACKAGE_FILE}"
  cntools_transaction_output_path_safe "${output_file}" || {
    cntools_transaction_set_error \
      "The signed package output must be a new file in an owned writable directory."
    return 1
  }
  if [[ "${CNTOOLS_TRANSACTION_PACKAGE_NETWORK}" != "${CNTOOLS_NETWORK:-}" ]]; then
    cntools_transaction_set_error \
      "This package targets ${CNTOOLS_TRANSACTION_PACKAGE_NETWORK}, but CNTools is configured for ${CNTOOLS_NETWORK:-unknown}."
    return 1
  fi
  if [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == "Y" ]]; then
    cntools_transaction_set_error "This transaction package is already fully signed."
    return 1
  fi
  cntools_transaction_sign_selection_reset
  for source_file in "${signer_sources_ref[@]}"; do
    cntools_transaction_sign_selection_add "${input_file}" "${source_file}" ||
      return 1
  done
  for source_file in "${change_sources_ref[@]}"; do
    cntools_transaction_change_selection_add \
      "${input_file}" "${source_file}" || return 1
  done
  (( ${#CNTOOLS_TRANSACTION_SELECTED_SOURCES[@]} > 0 )) || {
    cntools_transaction_set_error "No missing transaction signer was selected."
    return 1
  }
  for kind in "${CNTOOLS_TRANSACTION_SELECTED_KINDS[@]}"; do
    [[ "${kind}" != "hardware" ]] || has_hardware="Y"
  done

  cntools_transaction_temp_file working_file sign-package || return 1
  jq . "${input_file}" > "${working_file}" || return 1
  if [[ "${has_hardware}" == "Y" ]]; then
    [[ "${CNTOOLS_TRANSACTION_PACKAGE_HARDWARE_PREPARED}" == "Y" ]] || {
      cntools_transaction_set_error \
        "The transaction must be prepared and reviewed for hardware signing before witnesses are collected."
      return 1
    }
    # This boundary is intentionally validate-only. Generic Sign and every
    # originating action must perform any transform before showing the final
    # decoded review; a post-confirmation transform could change value flow.
    cntools_transaction_hardware_body_signable \
      "${CNTOOLS_TRANSACTION_BODY_FILE}" || return 1
  fi
  body_file="${CNTOOLS_TRANSACTION_BODY_FILE}"

  for (( index = 0;
         index < ${#CNTOOLS_TRANSACTION_SELECTED_SOURCES[@]};
         index++ )); do
    [[ "${CNTOOLS_TRANSACTION_SELECTED_KINDS[index]}" == "cli" ]] || continue
    source_file="${CNTOOLS_TRANSACTION_SELECTED_SOURCES[index]}"
    key_id="${CNTOOLS_TRANSACTION_SELECTED_KEY_IDS[index]}"
    cntools_transaction_temp_file witness_file cli-witness || return 1
    cntools_transaction_witness_cli \
      "${body_file}" "${source_file}" "${witness_file}" || return 1
    cntools_transaction_temp_file next_file sign-package || return 1
    cntools_transaction_package_append_witness \
      "${working_file}" "${key_id}" cli "${witness_file}" "${next_file}" ||
      return 1
    working_file="${next_file}"
    added=$((added + 1))
  done

  # Batch only an explicit hardware session declared by the originating
  # action. A directory is storage, not device identity; pool registration in
  # particular may need wallet and pool keys in one hardware call.
  for (( index = 0;
         index < ${#CNTOOLS_TRANSACTION_SELECTED_SOURCES[@]};
         index++ )); do
    [[ "${CNTOOLS_TRANSACTION_SELECTED_KINDS[index]}" == "hardware" ]] ||
      continue
    hardware_group="${CNTOOLS_TRANSACTION_SELECTED_HARDWARE_GROUPS[index]}"
    [[ -n "${hardware_group}" ]] ||
      hardware_group="@ungrouped:${CNTOOLS_TRANSACTION_SELECTED_KEY_IDS[index]}"
    group_seen="N"
    for known_group in "${hardware_groups[@]}"; do
      [[ "${known_group}" != "${hardware_group}" ]] || group_seen="Y"
    done
    [[ "${group_seen}" == "N" ]] || continue
    hardware_groups+=("${hardware_group}")
  done
  for hardware_group in "${hardware_groups[@]}"; do
    if [[ "${hardware_group}" != @ungrouped:* ]] &&
       ! cntools_transaction_hardware_group_selection_complete \
         "${working_file}" "${hardware_group}"; then
      cntools_transaction_set_error \
        "Hardware session ${hardware_group} requires all of its still-missing keys to be selected together."
      return 1
    fi
    if [[ "${hardware_group}" != @ungrouped:* ]] &&
       ! cntools_transaction_hardware_group_change_selection_complete \
         "${working_file}" "${hardware_group}"; then
      cntools_transaction_set_error \
        "Hardware session ${hardware_group} requires all of its planned change-address references to be selected together."
      return 1
    fi
    group_sources=()
    group_outputs=()
    group_change_sources=()
    for (( index = 0;
           index < ${#CNTOOLS_TRANSACTION_SELECTED_SOURCES[@]};
           index++ )); do
      [[ "${CNTOOLS_TRANSACTION_SELECTED_KINDS[index]}" == "hardware" &&
         ( "${CNTOOLS_TRANSACTION_SELECTED_HARDWARE_GROUPS[index]}" == "${hardware_group}" ||
           ( -z "${CNTOOLS_TRANSACTION_SELECTED_HARDWARE_GROUPS[index]}" &&
             "@ungrouped:${CNTOOLS_TRANSACTION_SELECTED_KEY_IDS[index]}" == "${hardware_group}" ) ) ]] ||
        continue
      group_sources+=("${CNTOOLS_TRANSACTION_SELECTED_SOURCES[index]}")
      cntools_transaction_temp_file witness_file hw-witness || return 1
      group_outputs+=("${witness_file}")
    done
    if [[ "${hardware_group}" != @ungrouped:* ]]; then
      for (( index = 0;
             index < ${#CNTOOLS_TRANSACTION_SELECTED_CHANGE_SOURCES[@]};
             index++ )); do
        [[ "${CNTOOLS_TRANSACTION_SELECTED_CHANGE_HARDWARE_GROUPS[index]}" == "${hardware_group}" ]] ||
          continue
        group_change_sources+=(
          "${CNTOOLS_TRANSACTION_SELECTED_CHANGE_SOURCES[index]}")
      done
    fi
    cntools_transaction_witness_hardware_batch \
      "${body_file}" group_sources group_outputs group_change_sources || return 1
    for (( group_index = 0;
           group_index < ${#group_sources[@]};
           group_index++ )); do
      source_file="${group_sources[group_index]}"
      witness_file="${group_outputs[group_index]}"
      cntools_transaction_source_key_id_into key_id "${source_file}" || return 1
      cntools_transaction_temp_file next_file sign-package || return 1
      cntools_transaction_package_append_witness \
        "${working_file}" "${key_id}" hardware \
        "${witness_file}" "${next_file}" || return 1
      working_file="${next_file}"
      added=$((added + 1))
    done
  done

  for hardware_group in \
      "${CNTOOLS_TRANSACTION_SELECTED_CHANGE_HARDWARE_GROUPS[@]}"; do
    group_seen="N"
    for known_group in "${hardware_groups[@]}"; do
      [[ "${known_group}" != "${hardware_group}" ]] || group_seen="Y"
    done
    if [[ "${group_seen}" != "Y" ]]; then
      cntools_transaction_set_error \
        "A hardware change reference was selected without its signing session."
      return 1
    fi
  done

  missing="$(jq -r '
    ([.signing.required[].keyId] - [.signing.witnesses[].keyId]) | length
  ' "${working_file}")" || return 1
  if (( missing == 0 )); then
    cntools_transaction_temp_file next_file assembled-package || return 1
    cntools_transaction_package_assemble "${working_file}" "${next_file}" ||
      return 1
    working_file="${next_file}"
    CNTOOLS_TRANSACTION_SIGN_COMPLETE="Y"
  fi
  cntools_transaction_package_structure_valid "${working_file}" || return 1
  cntools_transaction_package_hardware_groups_valid \
    "${working_file}" || return 1
  cntools_transaction_publish "${working_file}" "${output_file}" || return 1
  CNTOOLS_TRANSACTION_SIGN_OUTPUT="${output_file}"
  CNTOOLS_TRANSACTION_SIGN_ADDED="${added}"
  cntools_transaction_log TRANSACTION \
    "signing complete file=${output_file} added=${added} complete=${CNTOOLS_TRANSACTION_SIGN_COMPLETE}"
}

cntools_transaction_sign_registered() {
  local input_file="${1:-}"
  local output_file="${2:-}"
  local key_id=""
  local source=""
  local kind=""
  local hardware_group=""
  local existing_group=""
  local group_seen="N"
  local -a sources=()
  local -a change_sources=()
  local -a active_hardware_groups=()

  cntools_transaction_package_load "${input_file}" || return 1
  input_file="${CNTOOLS_TRANSACTION_PACKAGE_FILE}"
  while IFS= read -r key_id; do
    source="${CNTOOLS_TRANSACTION_RUNTIME_SOURCES[${key_id}]:-}"
    [[ -n "${source}" ]] || continue
    sources+=("${source}")
    cntools_transaction_source_kind_into kind "${source}" || return 1
    if [[ "${kind}" == "hardware" ]]; then
      hardware_group="$(jq -r --arg id "${key_id}" '
        .signing.required[] | select(.keyId == $id) | .hardwareGroup // ""
      ' "${input_file}")" || return 1
      if [[ -n "${hardware_group}" ]]; then
        group_seen="N"
        for existing_group in "${active_hardware_groups[@]}"; do
          [[ "${existing_group}" != "${hardware_group}" ]] || group_seen="Y"
        done
        [[ "${group_seen}" == "Y" ]] ||
          active_hardware_groups+=("${hardware_group}")
      fi
    fi
  done < <(jq -r '
    [.signing.required[].keyId] - [.signing.witnesses[].keyId] | .[]
  ' "${input_file}")
  while IFS= read -r key_id; do
    hardware_group="$(jq -r --arg id "${key_id}" '
      .signing.changeKeys[] | select(.keyId == $id) | .hardwareGroup
    ' "${input_file}")" || return 1
    group_seen="N"
    for existing_group in "${active_hardware_groups[@]}"; do
      [[ "${existing_group}" != "${hardware_group}" ]] || group_seen="Y"
    done
    [[ "${group_seen}" == "Y" ]] || continue
    source="${CNTOOLS_TRANSACTION_RUNTIME_CHANGE_SOURCES[${key_id}]:-}"
    [[ -n "${source}" ]] || continue
    change_sources+=("${source}")
  done < <(jq -r '.signing.changeKeys[].keyId' "${input_file}")
  (( ${#sources[@]} > 0 )) || {
    cntools_transaction_set_error \
      "No runtime signing sources were registered for this transaction."
    return 1
  }
  cntools_transaction_sign_package \
    "${input_file}" "${output_file}" sources change_sources
}
