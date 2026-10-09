#!/usr/bin/env bash
# Logged wallet query transport and temporary-file lifetime.
# shellcheck disable=SC2034

declare -ag CNTOOLS_WALLET_QUERY_TEMP_FILES=()

cntools_wallet_query_cleanup() {
  local file=""

  for file in "${CNTOOLS_WALLET_QUERY_TEMP_FILES[@]}"; do
    [[ -n "${file}" &&
       "${file}" = "${CNTOOLS_TMP_DIR:-/invalid}/.cntools-wallet."* &&
       -f "${file}" && ! -L "${file}" && -O "${file}" ]] || continue
    rm -f -- "${file}"
  done
  CNTOOLS_WALLET_QUERY_TEMP_FILES=()
  if declare -F cntools_http_temp_files_cleanup >/dev/null 2>&1; then
    cntools_http_temp_files_cleanup
  fi
  if declare -F cntools_http_secret_files_cleanup >/dev/null 2>&1; then
    cntools_http_secret_files_cleanup
  fi
}


cntools_wallet_query_temp_file() {
  local _cntools_output_name="${1:-}"
  local _cntools_temp_file=""
  local _cntools_previous_umask=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  [[ -d "${CNTOOLS_TMP_DIR:-}" && ! -L "${CNTOOLS_TMP_DIR}" &&
     -O "${CNTOOLS_TMP_DIR}" && -w "${CNTOOLS_TMP_DIR}" ]] || return 1
  _cntools_previous_umask="$(umask)"
  umask 077
  _cntools_temp_file="$(mktemp "${CNTOOLS_TMP_DIR}/.cntools-wallet.XXXXXX")" || {
    umask "${_cntools_previous_umask}"
    return 1
  }
  umask "${_cntools_previous_umask}"
  chmod 0600 "${_cntools_temp_file}" || {
    rm -f -- "${_cntools_temp_file}"
    return 1
  }
  CNTOOLS_WALLET_QUERY_TEMP_FILES+=("${_cntools_temp_file}")
  _cntools_output_ref="${_cntools_temp_file}"
}


cntools_wallet_query_first_diagnostic() {
  local file="${1:-}"
  local fallback=""
  local line=""
  local joined=""

  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="$(cntools_log_sanitize_line "${line:0:400}")"
    [[ "${line}" == *[![:space:]]* ]] || continue
    case "${line}" in
      Error:*|cardano-cli:*|*': Error:'*)
        printf '%s' "${line:0:400}"
        return 0
        ;;
    esac
    if [[ -z "${fallback}" ]]; then
      fallback="${line}"
    else
      joined="${fallback} | ${line}"
      fallback="${joined:0:400}"
    fi
  done < "${file}"
  [[ -n "${fallback}" ]] || return 1
  printf '%s' "${fallback:0:400}"
}


cntools_wallet_query_log_failure() {
  local context="${1:-query failed}"
  local status="${2:-1}"
  local error_file="${3:-}"
  local output_file="${4:-}"
  local detail=""

  if [[ "${status}" == "124" ]]; then
    detail="timed out after ${CNTOOLS_CLI_TIMEOUT:-10} seconds"
    CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE="timeout"
  else
    detail="$(cntools_wallet_query_first_diagnostic \
      "${error_file}" 2>/dev/null || true)"
    [[ -n "${detail}" ]] || detail="$(cntools_wallet_query_first_diagnostic \
      "${output_file}" 2>/dev/null || true)"
  fi
  cntools_wallet_log ERROR \
    "${context} status=${status}${detail:+: ${detail}}"
}


cntools_wallet_query_local_socket_ready() {
  local socket_path="${CNTOOLS_SOCKET:-}"

  [[ -n "${socket_path}" && "${socket_path}" = /* &&
     -S "${socket_path}" ]]
}


cntools_wallet_query_network_arguments() {
  case "${CNTOOLS_NETWORK:-}" in
    mainnet) CNTOOLS_WALLET_NETWORK_ARGS=(--mainnet) ;;
    guild) CNTOOLS_WALLET_NETWORK_ARGS=(--testnet-magic 141) ;;
    preprod) CNTOOLS_WALLET_NETWORK_ARGS=(--testnet-magic 1) ;;
    preview) CNTOOLS_WALLET_NETWORK_ARGS=(--testnet-magic 2) ;;
    *) return 1 ;;
  esac
}


cntools_wallet_query_run_cli() {
  local output_file="${1:-}"
  local error_file="${2:-}"
  local mask=""
  shift 2 || return 2
  (( $# > 0 )) || return 2
  printf -v mask '%*s' "$#" ''
  mask="${mask// /0}"
  cntools_run_command_timeout "${CNTOOLS_CLI_TIMEOUT:-10}" \
    "${mask}" -- "$@" > "${output_file}" 2> "${error_file}"
}


cntools_wallet_query_http() {
  local endpoint="${1:-}"
  local payload="${2:-}"
  local output_file="${3:-}"
  local maximum_bytes="${4:-2097152}"
  local method="${5:-POST}"
  local auth_header_file=""
  local request_status=0
  [[ "${maximum_bytes}" =~ ^[1-9][0-9]{0,7}$ ]] &&
    (( maximum_bytes <= 33554432 )) || return 2
  [[ "${method}" == POST || ( "${method}" == GET && -z "${payload}" ) ]] || return 2
  local -a arguments=(
    --connect-timeout 3
    --max-filesize "${maximum_bytes}"
    --header "accept: application/json"
    --header "content-type: application/json"
  )
  [[ "${method}" != POST ]] || arguments+=(--data "${payload}")

  if [[ -n "${CNTOOLS_KOIOS_TOKEN:-}" ]]; then
    if ! cntools_http_secret_file_create auth_header_file; then
      cntools_wallet_log ERROR \
        "Could not prepare the protected Koios authorization header"
      return 1
    fi
    arguments+=(--header "@${auth_header_file}")
  fi
  if cntools_api_request "${method}" "${endpoint}" "${output_file}" \
      "${arguments[@]}"; then
    request_status=0
  else
    request_status=$?
  fi
  [[ -z "${auth_header_file}" ]] ||
    cntools_http_secret_file_remove "${auth_header_file}" || true
  return "${request_status}"
}
