#!/usr/bin/env bash
# Cardano CLI transaction builders backed by the shared signer plan. Functions only.
# shellcheck disable=SC2034

CNTOOLS_TRANSACTION_BUILD_MESSAGE=""
CNTOOLS_TRANSACTION_MIN_FEE=""
CNTOOLS_TRANSACTION_MAX_ARGUMENT_BYTES=65536
CNTOOLS_TRANSACTION_MAX_COMMAND_BYTES=524288

cntools_transaction_build_arguments_safe() {
  local builder="${1:-}"
  local argument=""
  local aggregate_bytes=0
  local LC_ALL=C
  shift || return 2

  case "${builder}" in build|build-estimate|build-raw) ;; *) return 2 ;; esac
  (( $# > 0 )) || return 1
  for argument in "$@"; do
    [[ ! "${argument}" =~ [[:cntrl:]] ]] || return 1
    (( ${#argument} <= CNTOOLS_TRANSACTION_MAX_ARGUMENT_BYTES )) || return 1
    aggregate_bytes=$((aggregate_bytes + ${#argument} + 1))
    (( aggregate_bytes <= CNTOOLS_TRANSACTION_MAX_COMMAND_BYTES )) || return 1
    case "${argument}" in
      --out-file|--out-file=*|--out-canonical-cbor|--socket-path|--socket-path=*|\
      --mainnet|--testnet-magic|--testnet-magic=*|--witness-override|\
      --witness-override=*|--shelley-key-witnesses|\
      --shelley-key-witnesses=*|--byron-key-witnesses|\
      --byron-key-witnesses=*|--invalid-before|--invalid-before=*|\
      --lower-bound|--lower-bound=*|\
      --invalid-hereafter|--invalid-hereafter=*|--required-signer|\
      --upper-bound|--upper-bound=*|--ttl|--ttl=*|\
      --tx-body-file|--tx-body-file=*|\
      --calculate-plutus-script-cost|--calculate-plutus-script-cost=*|\
      --required-signer=*|--required-signer-hash|--required-signer-hash=*)
        return 1
        ;;
    esac
  done
}

cntools_transaction_local_backend_ready() {
  [[ "${CNTOOLS_MODE:-}" == "local" &&
     "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == "true" &&
     -n "${CNTOOLS_SOCKET:-}" && "${CNTOOLS_SOCKET}" = /* &&
     -S "${CNTOOLS_SOCKET}" ]]
}

cntools_transaction_build_body() {
  local builder="${1:-}"
  local output_file="${2:-}"
  local witness_count=""
  local staged_file=""
  local command_output=""
  local error_file=""
  local kind=""
  local required_credential=""
  local status=0
  local mask=""
  local -a caller_arguments=()
  local -a network_arguments=()
  local -a command=()
  shift 2 2>/dev/null || return 2
  [[ "${1:-}" == "--" ]] || return 2
  shift
  caller_arguments=("$@")

  CNTOOLS_TRANSACTION_BUILD_MESSAGE=""
  cntools_transaction_clear_error
  [[ "${CNTOOLS_TRANSACTION_PLAN_READY:-N}" == "Y" ]] || {
    cntools_transaction_set_error \
      "A signer plan must be finalized before building a transaction."
    return 1
  }
  witness_count="$(cntools_transaction_plan_witness_count)" || return 1
  [[ "${witness_count}" =~ ^[0-9]+$ ]] || {
    cntools_transaction_set_error \
      "The transaction signer plan returned an invalid witness count."
    return 1
  }
  cntools_transaction_build_arguments_safe \
    "${builder}" "${caller_arguments[@]}" || {
    cntools_transaction_set_error \
      "Transaction builder arguments are empty, unsafe, too large for one Cardano CLI invocation, or override foundation-owned options."
    return 1
  }
  cntools_transaction_require_cli || return 1
  cntools_transaction_output_path_safe "${output_file}" || {
    cntools_transaction_set_error \
      "The transaction body output must be a new file in an owned writable directory."
    return 1
  }
  cntools_transaction_temp_file \
    staged_file build-body "${output_file%/*}" || return 1
  cntools_transaction_temp_file command_output build-output || return 1
  cntools_transaction_temp_file error_file build-error || return 1

  command=("${CNTOOLS_CLI}" latest transaction "${builder}")
  command+=("${caller_arguments[@]}")
  # Bind the complete witness plan into the transaction body. These signers
  # already have to witness the transaction; recording every credential as an
  # explicit required signer also prevents a portable package from silently
  # dropping or relabelling a spending/certificate/withdrawal signer.
  while IFS= read -r required_credential; do
    [[ "${required_credential}" =~ ^[0-9a-f]{56}$ ]] || continue
    command+=(--required-signer-hash "${required_credential}")
  done < <(jq -r '
    [.[].credential] | unique | sort[]
  ' <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}")
  if [[ -n "${CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE}" ]]; then
    command+=(--invalid-before "${CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE}")
  fi
  if [[ -n "${CNTOOLS_TRANSACTION_PLAN_INVALID_HEREAFTER}" ]]; then
    command+=(--invalid-hereafter \
      "${CNTOOLS_TRANSACTION_PLAN_INVALID_HEREAFTER}")
  fi
  case "${builder}" in
    build)
      if ! cntools_transaction_local_backend_ready; then
        cntools_transaction_set_error \
          "The auto-balanced live builder requires a reachable local Cardano CLI node socket. Use build-estimate with exported or Koios data when no local node is available."
        return 1
      fi
      cntools_transaction_network_arguments_into \
        network_arguments "${CNTOOLS_NETWORK}" || return 1
      command+=(
        --witness-override "${witness_count}"
        --out-canonical-cbor
        --socket-path "${CNTOOLS_SOCKET}"
        "${network_arguments[@]}"
        --out-file "${staged_file}"
      )
      ;;
    build-estimate)
      command+=(
        --shelley-key-witnesses "${witness_count}"
        --byron-key-witnesses 0
        --out-canonical-cbor
        --out-file "${staged_file}"
      )
      ;;
    build-raw)
      command+=(--out-canonical-cbor --out-file "${staged_file}")
      ;;
    *) return 2 ;;
  esac

  printf -v mask '%*s' "${#command[@]}" ''
  mask="${mask// /0}"
  if cntools_run_command_timeout "${CNTOOLS_TRANSACTION_TIMEOUT}" \
      "${mask}" -- "${command[@]}" \
      > "${command_output}" 2> "${error_file}"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Transaction ${builder} failed" "${status}" \
      "${error_file}" "${command_output}"
    return 1
  fi
  if ! cntools_transaction_envelope_kind_into kind "${staged_file}" ||
     [[ "${kind}" != "body" && "${kind}" != "transaction" ]]; then
    cntools_transaction_set_error \
      "Cardano CLI did not produce a valid transaction body."
    return 1
  fi
  CNTOOLS_TRANSACTION_BUILD_MESSAGE="$(< "${command_output}")"
  cntools_transaction_publish "${staged_file}" "${output_file}" || return 1
  cntools_transaction_log TRANSACTION \
    "body built builder=${builder} witnesses=${witness_count} file=${output_file}"
}

cntools_transaction_calculate_min_fee_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_body_file="${2:-}"
  local _cntools_input_count="${3:-}"
  local _cntools_output_count="${4:-}"
  local _cntools_protocol_file="${5:-}"
  local _cntools_reference_script_size="${6:-0}"
  local _cntools_witness_count=""
  local _cntools_output_file=""
  local _cntools_error_file=""
  local _cntools_result=""
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  [[ "${CNTOOLS_TRANSACTION_PLAN_READY:-N}" == "Y" &&
     "${_cntools_input_count}" =~ ^[0-9]+$ &&
     "${_cntools_output_count}" =~ ^[0-9]+$ &&
     "${_cntools_reference_script_size}" =~ ^[0-9]+$ ]] || return 2
  cntools_transaction_require_cli || return 1
  cntools_transaction_envelope_compact_into \
    _cntools_result "${_cntools_body_file}" body || return 1
  : "${_cntools_result}"
  cntools_transaction_file_safe "${_cntools_protocol_file}" 4194304 || {
    cntools_transaction_set_error "The protocol-parameters file is missing or unsafe."
    return 1
  }
  jq -e 'type == "object"' "${_cntools_protocol_file}" >/dev/null 2>&1 || {
    cntools_transaction_set_error "The protocol-parameters file is not a JSON object."
    return 1
  }
  _cntools_witness_count="$(cntools_transaction_plan_witness_count)" || return 1
  cntools_transaction_temp_file _cntools_output_file fee-output || return 1
  cntools_transaction_temp_file _cntools_error_file fee-error || return 1
  if cntools_transaction_run_cli \
      "${_cntools_output_file}" "${_cntools_error_file}" -- \
      "${CNTOOLS_CLI}" latest transaction calculate-min-fee \
      --tx-body-file "${_cntools_body_file}" \
      --tx-in-count "${_cntools_input_count}" \
      --tx-out-count "${_cntools_output_count}" \
      --witness-count "${_cntools_witness_count}" \
      --byron-witness-count 0 \
      --protocol-params-file "${_cntools_protocol_file}" \
      --reference-script-size "${_cntools_reference_script_size}" \
      --output-text; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  if (( _cntools_status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Minimum-fee calculation failed" "${_cntools_status}" \
      "${_cntools_error_file}" "${_cntools_output_file}"
    return 1
  fi
  _cntools_result="$(< "${_cntools_output_file}")"
  if [[ "${_cntools_result}" =~ ^[[:space:]]*([0-9]+)[[:space:]]+Lovelace[[:space:]]*$ ]]; then
    CNTOOLS_TRANSACTION_MIN_FEE="${BASH_REMATCH[1]}"
    _cntools_output_ref="${BASH_REMATCH[1]}"
  else
    cntools_transaction_set_error \
      "Cardano CLI returned an invalid minimum-fee result."
    return 1
  fi
  cntools_transaction_log TRANSACTION \
    "minimum fee=${CNTOOLS_TRANSACTION_MIN_FEE} witnesses=${_cntools_witness_count}"
}

cntools_transaction_calculate_min_utxo_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_protocol_file="${2:-}"
  local _cntools_tx_out="${3:-}"
  local _cntools_output_file=""
  local _cntools_error_file=""
  local _cntools_result=""
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     -n "${_cntools_tx_out}" && ${#_cntools_tx_out} -le 65536 &&
     "${_cntools_tx_out}" != *$'\n'* &&
     "${_cntools_tx_out}" != *$'\r'* ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_require_cli || return 1
  cntools_transaction_file_safe "${_cntools_protocol_file}" 4194304 || {
    cntools_transaction_set_error \
      "The protocol-parameters file is missing or unsafe."
    return 1
  }
  jq -e 'type == "object"' "${_cntools_protocol_file}" >/dev/null 2>&1 || {
    cntools_transaction_set_error \
      "The protocol-parameters file is not a JSON object."
    return 1
  }
  cntools_transaction_temp_file _cntools_output_file min-utxo-output || return 1
  cntools_transaction_temp_file _cntools_error_file min-utxo-error || return 1
  if cntools_transaction_run_cli \
      "${_cntools_output_file}" "${_cntools_error_file}" -- \
      "${CNTOOLS_CLI}" latest transaction calculate-min-required-utxo \
      --protocol-params-file "${_cntools_protocol_file}" \
      --tx-out "${_cntools_tx_out}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  if (( _cntools_status != 0 )); then
    cntools_transaction_log_cli_failure \
      "Minimum-UTxO calculation failed" "${_cntools_status}" \
      "${_cntools_error_file}" "${_cntools_output_file}"
    return 1
  fi
  _cntools_result="$(< "${_cntools_output_file}")"
  if [[ "${_cntools_result}" =~ ^[[:space:]]*(Lovelace|Coin)[[:space:]]+([0-9]+)[[:space:]]*$ ]]; then
    _cntools_output_ref="${BASH_REMATCH[2]}"
  elif [[ "${_cntools_result}" =~ ^[[:space:]]*([0-9]+)[[:space:]]+(Lovelace|Coin)[[:space:]]*$ ]]; then
    _cntools_output_ref="${BASH_REMATCH[1]}"
  else
    cntools_transaction_set_error \
      "Cardano CLI returned an invalid minimum-UTxO result."
    return 1
  fi
  cntools_transaction_log TRANSACTION \
    "minimum utxo=${_cntools_output_ref} output_bytes=${#_cntools_tx_out}"
}
