#!/usr/bin/env bash
# Local-node and Koios submission for reviewed transaction artifacts. Functions only.
# shellcheck disable=SC2034

CNTOOLS_TRANSACTION_SUBMIT_BACKEND=""
CNTOOLS_TRANSACTION_SUBMIT_ID=""
CNTOOLS_TRANSACTION_SUBMIT_INPUT_KIND=""
CNTOOLS_TRANSACTION_SUBMIT_COMPLETENESS=""
CNTOOLS_TRANSACTION_SUBMIT_VKEY_WITNESS_COUNT=0
CNTOOLS_TRANSACTION_SUBMIT_SOURCE_FILE=""
CNTOOLS_TRANSACTION_SUBMIT_HTTP_STATUS=""
CNTOOLS_TRANSACTION_SUBMIT_MESSAGE=""
CNTOOLS_TRANSACTION_SUBMIT_XXD=""
CNTOOLS_TRANSACTION_SUBMIT_CBOR_SHA256=""
CNTOOLS_TRANSACTION_SUBMIT_CBOR_BYTES=""

cntools_transaction_submit_reset() {
  CNTOOLS_TRANSACTION_SUBMIT_BACKEND=""
  CNTOOLS_TRANSACTION_SUBMIT_ID=""
  CNTOOLS_TRANSACTION_SUBMIT_INPUT_KIND=""
  CNTOOLS_TRANSACTION_SUBMIT_COMPLETENESS=""
  CNTOOLS_TRANSACTION_SUBMIT_VKEY_WITNESS_COUNT=0
  CNTOOLS_TRANSACTION_SUBMIT_SOURCE_FILE=""
  CNTOOLS_TRANSACTION_SUBMIT_HTTP_STATUS=""
  CNTOOLS_TRANSACTION_SUBMIT_MESSAGE=""
  CNTOOLS_TRANSACTION_SUBMIT_CBOR_SHA256=""
  CNTOOLS_TRANSACTION_SUBMIT_CBOR_BYTES=""
}

cntools_transaction_submit_local_ready() {
  [[ "${CNTOOLS_MODE:-}" == "local" &&
     "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == "true" &&
     -n "${CNTOOLS_CLI:-}" && "${CNTOOLS_CLI}" = /* &&
     -x "${CNTOOLS_CLI}" && ! -d "${CNTOOLS_CLI}" &&
     -n "${CNTOOLS_SOCKET:-}" && "${CNTOOLS_SOCKET}" = /* &&
     -S "${CNTOOLS_SOCKET}" ]]
}

cntools_transaction_submit_require_xxd() {
  local candidate=""

  if [[ -n "${CNTOOLS_TRANSACTION_SUBMIT_XXD}" &&
        "${CNTOOLS_TRANSACTION_SUBMIT_XXD}" = /* &&
        -x "${CNTOOLS_TRANSACTION_SUBMIT_XXD}" &&
        ! -d "${CNTOOLS_TRANSACTION_SUBMIT_XXD}" ]]; then
    return 0
  fi
  candidate="$(type -P xxd 2>/dev/null || true)"
  if [[ -z "${candidate}" || "${candidate}" != /* ||
        ! -x "${candidate}" || -d "${candidate}" ]]; then
    cntools_transaction_set_error \
      "xxd is required to serialize a transaction envelope for Koios submission. Re-run guild-deploy.sh with -s p."
    return 1
  fi
  CNTOOLS_TRANSACTION_SUBMIT_XXD="${candidate}"
}

cntools_transaction_submit_input_prepare() {
  local input_file="${1:-}"
  local normalized_file=""
  local snapshot_file=""
  local signed_file=""
  local envelope_kind=""
  local transaction_id=""
  local witnesses=""

  cntools_transaction_input_path_into normalized_file "${input_file}" || {
    cntools_transaction_set_error \
      "The transaction input path is missing or unsafe."
    return 1
  }
  cntools_transaction_file_safe \
    "${normalized_file}" "${CNTOOLS_TRANSACTION_MAX_PACKAGE_BYTES}" || {
    cntools_transaction_set_error \
      "The transaction input is missing, unreadable, oversized, or unsafe."
    return 1
  }

  # Work from one private snapshot. This prevents a mutable input from changing
  # between validation, transaction-ID calculation, and submission.
  cntools_transaction_snapshot_into \
    snapshot_file "${normalized_file}" \
    "${CNTOOLS_TRANSACTION_MAX_PACKAGE_BYTES}" submit-input || return 1
  if ! jq -e . "${snapshot_file}" >/dev/null 2>&1; then
    cntools_transaction_set_error \
      "The selected file is not a valid JSON transaction artifact."
    return 1
  fi

  if jq -e --arg schema "${CNTOOLS_TRANSACTION_SCHEMA}" \
      'type == "object" and .schema == $schema' \
      "${snapshot_file}" >/dev/null 2>&1; then
    cntools_transaction_package_load "${snapshot_file}" || return 1
    if [[ "${CNTOOLS_TRANSACTION_COMPLETE}" != "Y" ||
          -z "${CNTOOLS_TRANSACTION_SIGNED_FILE}" ]]; then
      cntools_transaction_set_error \
        "The CNTools transaction package is not fully signed and cannot be submitted."
      return 1
    fi
    if [[ "${CNTOOLS_TRANSACTION_PACKAGE_NETWORK}" != \
          "${CNTOOLS_NETWORK:-}" ]]; then
      cntools_transaction_set_error \
        "This package targets ${CNTOOLS_TRANSACTION_PACKAGE_NETWORK}, but CNTools is configured for ${CNTOOLS_NETWORK:-unknown}."
      return 1
    fi
    signed_file="${CNTOOLS_TRANSACTION_SIGNED_FILE}"
    transaction_id="${CNTOOLS_TRANSACTION_ID}"
    CNTOOLS_TRANSACTION_SUBMIT_INPUT_KIND="package"
    CNTOOLS_TRANSACTION_SUBMIT_COMPLETENESS="verified"
    CNTOOLS_TRANSACTION_SUBMIT_VKEY_WITNESS_COUNT="${CNTOOLS_TRANSACTION_WITNESS_COUNT}"
  else
    cntools_transaction_envelope_kind_into \
      envelope_kind "${snapshot_file}" || {
      cntools_transaction_set_error \
        "The selected file is neither a complete CNTools package nor an external Cardano transaction envelope."
      return 1
    }
    [[ "${envelope_kind}" == "transaction" ]] || {
      cntools_transaction_set_error \
        "The selected file is neither a complete CNTools package nor an external Cardano transaction envelope."
      return 1
    }
    signed_file="${snapshot_file}"
    cntools_transaction_id_into transaction_id "${signed_file}" || return 1
    if ! cntools_transaction_file_witnesses_into \
        witnesses "${signed_file}"; then
      cntools_transaction_set_error \
        "The external transaction contains a Byron/bootstrap, duplicate, or unsupported witness set. CNTools currently validates Shelley VKey witnesses only."
      return 1
    fi
    cntools_transaction_witness_signatures_valid \
      "${transaction_id}" "${witnesses}" || return 1
    CNTOOLS_TRANSACTION_SUBMIT_INPUT_KIND="external-envelope"
    CNTOOLS_TRANSACTION_SUBMIT_COMPLETENESS="unverified"
    CNTOOLS_TRANSACTION_SUBMIT_VKEY_WITNESS_COUNT="$(
      jq -r 'length' <<< "${witnesses}"
    )" || return 1
    cntools_transaction_log TRANSACTION \
      "external transaction prepared id=${transaction_id} completeness=unverified vkey_witnesses=${CNTOOLS_TRANSACTION_SUBMIT_VKEY_WITNESS_COUNT}"
  fi

  [[ -n "${signed_file}" && "${transaction_id}" =~ ^[0-9a-f]{64}$ ]] || {
    cntools_transaction_set_error \
      "The transaction envelope could not be prepared for submission."
    return 1
  }
  CNTOOLS_TRANSACTION_SIGNED_FILE="${signed_file}"
  CNTOOLS_TRANSACTION_SUBMIT_ID="${transaction_id}"
  CNTOOLS_TRANSACTION_SUBMIT_SOURCE_FILE="${normalized_file}"
}

cntools_transaction_submit_local() {
  local signed_file="${1:-}"
  local transaction_id="${2:-}"
  local envelope_kind=""
  local output_file=""
  local error_file=""
  local detail=""
  local status=0
  local -a network_arguments=()

  cntools_transaction_require_cli || return 1
  cntools_transaction_submit_local_ready || {
    cntools_transaction_set_error \
      "The local transaction submission backend became unavailable before submission."
    return 1
  }
  [[ "${transaction_id}" =~ ^[0-9a-f]{64}$ ]] || return 2
  cntools_transaction_envelope_kind_into envelope_kind "${signed_file}" ||
    return 1
  [[ "${envelope_kind}" == "transaction" ]] || return 1
  cntools_transaction_network_arguments_into \
    network_arguments "${CNTOOLS_NETWORK:-}" || {
    cntools_transaction_set_error \
      "The current Cardano network is unsupported for local submission."
    return 1
  }
  cntools_transaction_temp_file output_file submit-local-output || return 1
  cntools_transaction_temp_file error_file submit-local-error || return 1
  if cntools_transaction_run_cli "${output_file}" "${error_file}" -- \
      "${CNTOOLS_CLI}" latest transaction submit \
      "${network_arguments[@]}" \
      --socket-path "${CNTOOLS_SOCKET}" \
      --tx-file "${signed_file}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    if (( status == 124 )); then
      cntools_transaction_set_error \
        "Local submission timed out. The outcome is unknown; check transaction ${transaction_id} before retrying."
    else
      cntools_transaction_first_diagnostic_into detail "${error_file}" ||
        cntools_transaction_first_diagnostic_into detail "${output_file}" || true
      cntools_transaction_set_error \
        "Local transaction submission failed (status ${status})${detail:+: ${detail}}. The outcome may be unknown; check transaction ${transaction_id} before retrying."
    fi
    return 1
  fi

  CNTOOLS_TRANSACTION_SUBMIT_BACKEND="local"
  CNTOOLS_TRANSACTION_SUBMIT_MESSAGE="Transaction accepted by the local node."
  cntools_transaction_log TRANSACTION \
    "submitted id=${transaction_id} backend=local network=${CNTOOLS_NETWORK}"
}

cntools_transaction_submit_http_status_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_header_file="${2:-}"
  local _cntools_status=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_file_safe "${_cntools_header_file}" 262144 || return 1
  _cntools_status="$(LC_ALL=C awk '
    /^HTTP\/[0-9.]+ [0-9][0-9][0-9]([[:space:]]|$)/ { status = $2 }
    END { if (status != "") print status }
  ' "${_cntools_header_file}")" || return 1
  [[ "${_cntools_status}" =~ ^[0-9]{3}$ ]] || return 1
  _cntools_output_ref="${_cntools_status}"
}

cntools_transaction_submit_response_id_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_response_file="${2:-}"
  local _cntools_id=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_file_safe "${_cntools_response_file}" 65536 || return 1
  _cntools_id="$(jq -er '
    if type == "string" then ascii_downcase else error("not a string") end
  ' "${_cntools_response_file}" 2>/dev/null)" || return 1
  [[ "${_cntools_id}" =~ ^[0-9a-f]{64}$ ]] || return 1
  _cntools_output_ref="${_cntools_id}"
}

cntools_transaction_submit_response_detail_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_file="${2:-}"
  local _cntools_detail=""
  local _cntools_lower=""
  local _cntools_token="${CNTOOLS_KOIOS_TOKEN:-}"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_first_diagnostic_into \
    _cntools_detail "${_cntools_file}" || return 1
  _cntools_lower="${_cntools_detail,,}"
  # The response is controlled by the configured endpoint. Never persist a
  # reflected bearer credential, even when a hostile endpoint includes it in
  # an otherwise useful error message.
  if [[ ( -n "${_cntools_token}" &&
          "${_cntools_detail}" == *"${_cntools_token}"* ) ||
        "${_cntools_lower}" == *authorization:* ||
        "${_cntools_lower}" == *"bearer "* ]]; then
    _cntools_output_ref="sensitive HTTP response detail redacted"
  else
    _cntools_output_ref="${_cntools_detail}"
  fi
}

cntools_transaction_submit_signed_cbor_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_signed_file="${2:-}"
  local _cntools_envelope_kind=""
  local _cntools_hex_file=""
  local _cntools_raw_file=""
  local _cntools_output_file=""
  local _cntools_error_file=""
  local _cntools_hex_size=""
  local _cntools_raw_size=""
  local _cntools_status=0
  local _cntools_mask=""
  local -a _cntools_command=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_envelope_kind_into \
    _cntools_envelope_kind "${_cntools_signed_file}" || return 1
  [[ "${_cntools_envelope_kind}" == "transaction" ]] || return 1
  cntools_transaction_submit_require_xxd || return 1
  cntools_transaction_temp_file _cntools_hex_file submit-cbor-hex || return 1
  cntools_transaction_temp_file _cntools_raw_file submit-cbor || return 1
  cntools_transaction_temp_file _cntools_output_file submit-cbor-output || return 1
  cntools_transaction_temp_file _cntools_error_file submit-cbor-error || return 1
  jq -er '.cborHex' "${_cntools_signed_file}" \
    > "${_cntools_hex_file}" || return 1
  _cntools_command=("${CNTOOLS_TRANSACTION_SUBMIT_XXD}" -r -p
    "${_cntools_hex_file}" "${_cntools_raw_file}")
  printf -v _cntools_mask '%*s' "${#_cntools_command[@]}" ''
  _cntools_mask="${_cntools_mask// /0}"
  if cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" \
      "${_cntools_mask}" -- "${_cntools_command[@]}" \
      > "${_cntools_output_file}" 2> "${_cntools_error_file}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  if (( _cntools_status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Transaction-envelope CBOR serialization failed" "${_cntools_status}" \
      "${_cntools_error_file}" "${_cntools_output_file}"
    return 1
  fi
  _cntools_hex_size="$(wc -c < "${_cntools_hex_file}" 2>/dev/null || true)"
  _cntools_raw_size="$(wc -c < "${_cntools_raw_file}" 2>/dev/null || true)"
  _cntools_hex_size="${_cntools_hex_size//[[:space:]]/}"
  _cntools_raw_size="${_cntools_raw_size//[[:space:]]/}"
  [[ "${_cntools_hex_size}" =~ ^[1-9][0-9]*$ &&
     "${_cntools_raw_size}" =~ ^[1-9][0-9]*$ &&
     $(((_cntools_hex_size - 1) / 2)) -eq _cntools_raw_size ]] || {
    cntools_transaction_set_error \
      "The transaction envelope could not be serialized to exact CBOR bytes."
    return 1
  }
  _cntools_output_ref="${_cntools_raw_file}"
}

cntools_transaction_submit_sha256_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_file="${2:-}"
  local _cntools_tool=""
  local _cntools_output_file=""
  local _cntools_error_file=""
  local _cntools_line=""
  local _cntools_digest=""
  local _cntools_status=0
  local _cntools_mask=""
  local -a _cntools_command=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_file_safe \
    "${_cntools_file}" "${CNTOOLS_TRANSACTION_MAX_PACKAGE_BYTES}" || return 1

  if _cntools_tool="$(type -P sha256sum 2>/dev/null)" &&
     [[ -n "${_cntools_tool}" ]]; then
    _cntools_command=("${_cntools_tool}" "${_cntools_file}")
  elif _cntools_tool="$(type -P shasum 2>/dev/null)" &&
       [[ -n "${_cntools_tool}" ]]; then
    _cntools_command=("${_cntools_tool}" -a 256 "${_cntools_file}")
  elif _cntools_tool="$(type -P openssl 2>/dev/null)" &&
       [[ -n "${_cntools_tool}" ]]; then
    _cntools_command=("${_cntools_tool}" dgst -sha256 -r "${_cntools_file}")
  else
    cntools_transaction_set_error \
      "A SHA-256 tool is required to record exact Koios submission provenance."
    return 1
  fi
  [[ "${_cntools_tool}" = /* && -x "${_cntools_tool}" &&
     ! -d "${_cntools_tool}" ]] || return 1
  cntools_transaction_temp_file \
    _cntools_output_file submit-sha256-output || return 1
  cntools_transaction_temp_file \
    _cntools_error_file submit-sha256-error || return 1
  printf -v _cntools_mask '%*s' "${#_cntools_command[@]}" ''
  _cntools_mask="${_cntools_mask// /0}"
  if cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" \
      "${_cntools_mask}" -- "${_cntools_command[@]}" \
      > "${_cntools_output_file}" 2> "${_cntools_error_file}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  if (( _cntools_status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Signed-transaction SHA-256 calculation failed" "${_cntools_status}" \
      "${_cntools_error_file}" "${_cntools_output_file}"
    return 1
  fi
  IFS= read -r _cntools_line < "${_cntools_output_file}" || true
  if [[ "${_cntools_line}" =~ ^([0-9A-Fa-f]{64})([[:space:]]|$) ]]; then
    _cntools_digest="${BASH_REMATCH[1],,}"
  fi
  [[ "${_cntools_digest}" =~ ^[0-9a-f]{64}$ ]] || {
    cntools_transaction_set_error \
      "The SHA-256 tool returned an unsupported digest format."
    return 1
  }
  _cntools_output_ref="${_cntools_digest}"
}

cntools_transaction_submit_log_koios_replay() {
  local endpoint="${1:-}"
  local raw_file="${2:-}"
  local transaction_id="${3:-}"
  local source_file="${CNTOOLS_TRANSACTION_SUBMIT_SOURCE_FILE:-}"
  local jq_filter=""
  local digest=""
  local byte_count=""
  local replay=""

  [[ "${endpoint}" =~ ^https://[^[:space:]]+$ &&
     "${transaction_id}" =~ ^[0-9a-f]{64}$ &&
     -n "${raw_file}" && "${raw_file}" = /* &&
     -f "${raw_file}" && ! -L "${raw_file}" &&
     -n "${source_file}" && "${source_file}" = /* ]] || return 1
  cntools_transaction_submit_sha256_into digest "${raw_file}" || return 1
  cntools_transaction_size_into byte_count "${raw_file}" || return 1
  [[ "${byte_count}" =~ ^[1-9][0-9]*$ ]] || return 1
  case "${CNTOOLS_TRANSACTION_SUBMIT_INPUT_KIND:-}" in
    package) jq_filter='.signedTransaction.cborHex' ;;
    external-envelope) jq_filter='.cborHex' ;;
    *) return 1 ;;
  esac

  CNTOOLS_TRANSACTION_SUBMIT_CBOR_SHA256="${digest}"
  CNTOOLS_TRANSACTION_SUBMIT_CBOR_BYTES="${byte_count}"
  cntools_transaction_log API \
    "Submission provenance: transaction_id=${transaction_id} signed_cbor_sha256=${digest} bytes=${byte_count}"

  if ! cntools_transaction_file_safe \
      "${source_file}" "${CNTOOLS_TRANSACTION_MAX_PACKAGE_BYTES}"; then
    cntools_transaction_log API \
      "Mutable artifact replay source is no longer available; provenance remains authoritative: $(cntools_log_render_argument "${source_file}")"
    return 0
  fi

  # The request uses the private raw-CBOR snapshot identified above. The
  # operator path is mutable (and may be removable media), so label this only
  # as a replay source and require its bytes to be checked against the durable
  # provenance digest before treating a later replay as equivalent.
  replay="jq -er $(cntools_log_render_argument "${jq_filter}")"
  replay+=" $(cntools_log_render_argument "${source_file}")"
  replay+=" | $(cntools_log_render_argument "${CNTOOLS_TRANSACTION_SUBMIT_XXD}") -r -p"
  replay+=" | curl --silent --show-error"
  replay+=" --max-time $(cntools_log_render_argument "${CNTOOLS_CURL_TIMEOUT:-10}")"
  replay+=" --request POST --max-filesize 65536"
  replay+=" --header $(cntools_log_render_argument 'accept: application/json')"
  replay+=" --header $(cntools_log_render_argument 'content-type: application/cbor')"
  if [[ -n "${CNTOOLS_KOIOS_TOKEN:-}" ]]; then
    # Preserve this expression for the replay shell without exposing the
    # token in CNTools' environment, process arguments, or log.
    # shellcheck disable=SC2016
    replay+=' --header "Authorization: Bearer ${KOIOS_API_TOKEN:?set KOIOS_API_TOKEN before replaying this request}"'
  fi
  replay+=" --data-binary @- $(cntools_log_render_argument "${endpoint}")"
  cntools_transaction_log API \
    "Mutable artifact replay source; verify signed_cbor_sha256=${digest}: ${replay}"
}

cntools_transaction_submit_koios() {
  local signed_file="${1:-}"
  local transaction_id="${2:-}"
  local endpoint=""
  local raw_file=""
  local response_file=""
  local header_file=""
  local auth_header_file=""
  local response_id=""
  local http_status=""
  local detail=""
  local request_status=0
  local -a arguments=()

  [[ "${transaction_id}" =~ ^[0-9a-f]{64}$ ]] || return 2
  if [[ "${CNTOOLS_KOIOS_ENABLED:-N}" != "Y" ]]; then
    cntools_transaction_set_error \
      "Koios transaction submission was disabled before the request started."
    return 1
  fi
  [[ -n "${CNTOOLS_KOIOS_API:-}" &&
     "${CNTOOLS_KOIOS_API}" =~ ^https://[^[:space:]]+$ ]] || {
    cntools_transaction_set_error \
      "The configured Koios API endpoint is missing or unsafe."
    return 1
  }
  cntools_transaction_network_magic "${CNTOOLS_NETWORK:-}" >/dev/null || {
    cntools_transaction_set_error \
      "The current Cardano network is unsupported for Koios submission."
    return 1
  }
  cntools_transaction_submit_signed_cbor_into raw_file "${signed_file}" ||
    return 1
  cntools_transaction_temp_file response_file submit-koios-response || return 1
  cntools_transaction_temp_file header_file submit-koios-headers || return 1
  endpoint="${CNTOOLS_KOIOS_API%/}/submittx"
  arguments=(
    --connect-timeout 3
    --max-filesize 65536
    --header "accept: application/json"
    --header "content-type: application/cbor"
    --dump-header "${header_file}"
    --data-binary "@${raw_file}"
  )
  if [[ -n "${CNTOOLS_KOIOS_TOKEN:-}" ]]; then
    if ! cntools_http_secret_file_create auth_header_file; then
      cntools_transaction_set_error \
        "The protected Koios authorization header could not be prepared."
      return 1
    fi
    arguments+=(--header "@${auth_header_file}")
  fi

  cntools_transaction_submit_log_koios_replay \
    "${endpoint}" "${raw_file}" "${transaction_id}" || return 1

  if cntools_api_request POST "${endpoint}" "${response_file}" \
      "${arguments[@]}"; then
    request_status=0
  else
    request_status=$?
  fi
  [[ -z "${auth_header_file}" ]] ||
    cntools_http_secret_file_remove "${auth_header_file}" || true
  cntools_transaction_submit_http_status_into \
    http_status "${header_file}" || http_status=""
  CNTOOLS_TRANSACTION_SUBMIT_HTTP_STATUS="${http_status}"

  if (( request_status != 0 )); then
    cntools_transaction_submit_response_detail_into \
      detail "${response_file}" 2>/dev/null || true
    if [[ "${http_status}" == "202" ]]; then
      cntools_transaction_set_error \
        "Koios returned HTTP 202 but its response transfer failed. The outcome is unknown; check transaction ${transaction_id} before retrying."
    else
      cntools_transaction_set_error \
        "Koios transaction submission failed${http_status:+ (HTTP ${http_status})} (status ${request_status})${detail:+: ${detail}}. The outcome may be unknown; check transaction ${transaction_id} before retrying."
    fi
    return 1
  fi
  if [[ "${http_status}" != "202" ]]; then
    cntools_transaction_set_error \
      "Koios returned HTTP ${http_status:-unknown}; HTTP 202 was required to accept the transaction. Check transaction ${transaction_id} before retrying."
    return 1
  fi
  if ! cntools_transaction_submit_response_id_into \
      response_id "${response_file}"; then
    cntools_transaction_set_error \
      "Koios accepted the transaction but returned an invalid transaction ID. Check ${transaction_id} before retrying."
    return 1
  fi
  if [[ "${response_id}" != "${transaction_id}" ]]; then
    cntools_transaction_set_error \
      "Koios accepted the request but returned transaction ID ${response_id}; expected ${transaction_id}. Verify both IDs before retrying."
    return 1
  fi

  CNTOOLS_TRANSACTION_SUBMIT_BACKEND="koios"
  CNTOOLS_TRANSACTION_SUBMIT_MESSAGE="Transaction accepted by Koios."
  cntools_transaction_log TRANSACTION \
    "submitted id=${transaction_id} backend=koios network=${CNTOOLS_NETWORK} http=202"
}

cntools_transaction_submit_impl() {
  local input_file="${1:-}"
  local backend=""

  if [[ "${CNTOOLS_MODE:-}" == "offline" ]]; then
    cntools_transaction_set_error \
      "Transaction submission is unavailable in offline mode. Move the transaction envelope or complete CNTools package to an online CNTools session."
    return 1
  fi
  if cntools_transaction_submit_local_ready; then
    backend="local"
  elif [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == "Y" ]]; then
    backend="koios"
  else
    cntools_transaction_set_error \
      "No transaction submission backend is available. Start a reachable local node or enable Koios."
    return 1
  fi

  cntools_transaction_submit_input_prepare "${input_file}" || return 1
  case "${backend}" in
    local)
      cntools_transaction_submit_local \
        "${CNTOOLS_TRANSACTION_SIGNED_FILE}" \
        "${CNTOOLS_TRANSACTION_SUBMIT_ID}"
      ;;
    koios)
      cntools_transaction_submit_koios \
        "${CNTOOLS_TRANSACTION_SIGNED_FILE}" \
        "${CNTOOLS_TRANSACTION_SUBMIT_ID}"
      ;;
    *) return 2 ;;
  esac
}

cntools_transaction_submit() {
  local input_file="${1:-}"
  local temporary_start=${#CNTOOLS_TRANSACTION_TEMP_FILES[@]}
  local status=0
  local candidate=""
  local -a temporary_files=()

  cntools_transaction_submit_reset
  cntools_transaction_clear_error
  cntools_transaction_package_reset_loaded
  if cntools_transaction_submit_impl "${input_file}"; then
    status=0
  else
    status=$?
  fi

  # Submission consumes private snapshots only. Remove every transaction temp
  # allocated by this call while leaving the caller's input untouched.
  temporary_files=("${CNTOOLS_TRANSACTION_TEMP_FILES[@]:temporary_start}")
  for candidate in "${temporary_files[@]}"; do
    cntools_transaction_temp_remove "${candidate}" || true
  done
  cntools_transaction_package_reset_loaded
  return "${status}"
}
