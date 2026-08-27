#!/usr/bin/env bash
# CNTools logging plus operational command and HTTP wrappers. Functions only.

cntools_log_path_components_safe() {
  local path="${1:-}"
  local current="/"
  local component=""
  local -a components=()

  [[ "${path}" = /* && "${path}" != *$'\n'* && "${path}" != *$'\r'* ]] ||
    return 1
  IFS='/' read -r -a components <<< "${path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current%/}/${component}"
    [[ ! -L "${current}" ]] || return 1
  done
}

cntools_log_init() {
  local log_file="${CNTOOLS_LOG:-}"
  local log_parent=""
  local created_parent="N"
  local previous_umask=""

  [[ -n "${log_file}" && "${log_file}" = /* ]] || {
    printf 'CNTools: log path must be absolute.\n' >&2
    return 1
  }
  log_parent="$(dirname "${log_file}")" || return 1
  cntools_log_path_components_safe "${log_parent}" || {
    printf 'CNTools: log directory contains an unsafe symbolic link: %s\n' \
      "${log_parent}" >&2
    return 1
  }
  if [[ ! -e "${log_parent}" ]]; then
    created_parent="Y"
    previous_umask="$(umask)"
    umask 077
    mkdir -p -- "${log_parent}" || {
      umask "${previous_umask}"
      printf 'CNTools: could not create log directory: %s\n' "${log_parent}" >&2
      return 1
    }
    umask "${previous_umask}"
  fi
  [[ -d "${log_parent}" && ! -L "${log_parent}" && -O "${log_parent}" ]] || {
    printf 'CNTools: log directory is unsafe or not owned by this user: %s\n' \
      "${log_parent}" >&2
    return 1
  }
  [[ "${created_parent}" != "Y" ]] || chmod 0700 "${log_parent}" || return 1
  log_parent="$(cd -- "${log_parent}" && pwd -P)" || return 1
  log_file="${log_parent}/$(basename "${log_file}")"
  CNTOOLS_LOG_PARENT="${log_parent}"
  CNTOOLS_LOG="${log_file}"
  export CNTOOLS_LOG_PARENT CNTOOLS_LOG

  if [[ -e "${log_file}" || -L "${log_file}" ]]; then
    [[ -f "${log_file}" && ! -L "${log_file}" && -O "${log_file}" ]] || {
      printf 'CNTools: log target is unsafe or not owned by this user: %s\n' \
        "${log_file}" >&2
      return 1
    }
  else
    previous_umask="$(umask)"
    umask 077
    : > "${log_file}" || {
      umask "${previous_umask}"
      printf 'CNTools: could not create log file: %s\n' "${log_file}" >&2
      return 1
    }
    umask "${previous_umask}"
  fi
  chmod 0600 "${log_file}" || return 1
  [[ -f "${log_file}" && ! -L "${log_file}" && -O "${log_file}" ]] || return 1
  exec {CNTOOLS_LOG_FD}>>"${log_file}" || {
    printf 'CNTools: could not open log file: %s\n' "${log_file}" >&2
    return 1
  }
  CNTOOLS_LOG_READY="Y"
}

cntools_log_sanitize_line() {
  local value="${1:-}"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//$'\t'/ }"
  value="${value//$'\033'/}"
  printf '%s' "${value}"
}

cntools_log() {
  local record_type="${1:-INFO}"
  local message="${2:-}"
  local scope="${CNTOOLS_ACTION_ID:-${CNTOOLS_MENU_ID:-session}}"
  local timestamp=""

  [[ "${CNTOOLS_LOG_READY:-N}" == "Y" &&
     "${CNTOOLS_LOG_FD:-}" =~ ^[0-9]+$ ]] || return 1
  [[ "${record_type}" =~ ^[A-Z]+$ ]] || record_type="INFO"
  scope="$(cntools_log_sanitize_line "${scope}")"
  message="$(cntools_log_sanitize_line "${message}")"
  timestamp="$(command date '+%Y-%m-%dT%H:%M:%S%z')" || return 1
  printf '%s [%s] [%s] %s\n' \
    "${timestamp}" "${record_type}" "${scope}" "${message}" \
    >&"${CNTOOLS_LOG_FD}"
}

cntools_log_close() {
  if [[ "${CNTOOLS_LOG_FD:-}" =~ ^[0-9]+$ ]]; then
    exec {CNTOOLS_LOG_FD}>&-
  fi
  CNTOOLS_LOG_FD=""
  CNTOOLS_LOG_READY="N"
}

cntools_log_render_argument() {
  local rendered=""
  printf -v rendered '%q' "${1:-}"
  printf '%s' "${rendered}"
}

cntools_run_command() {
  local mask="${1:-}"
  local rendered=""
  local piece=""
  local index=0
  local status=0
  shift || return 2
  [[ "${1:-}" == "--" ]] || return 2
  shift
  (( $# > 0 )) || return 2
  [[ "${mask}" =~ ^[01]+$ && ${#mask} -eq $# ]] || return 2

  for piece in "$@"; do
    [[ -z "${rendered}" ]] || rendered+=" "
    if [[ "${mask:index:1}" == "1" ]]; then
      rendered+="<redacted>"
    else
      rendered+="$(cntools_log_render_argument "${piece}")"
    fi
    index=$((index + 1))
  done
  cntools_log CMD "${rendered}" || return 1
  if "$@"; then
    status=0
  else
    status=$?
  fi
  cntools_log CMD "${rendered} -> ${status}" || true
  return "${status}"
}

cntools_http_sanitized_endpoint() {
  local url="${1:-}"
  local remainder=""
  local endpoint="/"

  remainder="${url#*://}"
  remainder="${remainder#*@}"
  if [[ "${remainder}" == */* ]]; then
    endpoint="/${remainder#*/}"
  fi
  endpoint="${endpoint%%\?*}"
  endpoint="${endpoint%%#*}"
  [[ -n "${endpoint}" ]] || endpoint="/"
  printf '%s' "${endpoint}"
}

cntools_http_request() {
  local method="${1:-}"
  local url="${2:-}"
  local output_file="${3:-}"
  local endpoint=""
  local http_status=""
  local curl_status=0
  local start_time=0
  local end_time=0
  shift 3 2>/dev/null || return 2

  [[ "${CNTOOLS_MODE:-}" != "offline" ]] || {
    cntools_log ERROR "HTTP request blocked in offline mode" || true
    return 2
  }
  [[ "${method}" =~ ^(GET|POST|PUT|PATCH|DELETE|HEAD)$ ]] || return 2
  [[ "${url}" =~ ^https://[^[:space:]]+$ ]] || return 2
  [[ -n "${output_file}" && ! -L "${output_file}" &&
     ( ! -e "${output_file}" || -f "${output_file}" ) ]] || return 2
  command -v curl >/dev/null 2>&1 || return 127

  endpoint="$(cntools_http_sanitized_endpoint "${url}")"
  start_time="$(command date '+%s')" || start_time=0
  if http_status="$(
      command curl --silent --show-error \
        --max-time "${CNTOOLS_CURL_TIMEOUT:-10}" \
        --request "${method}" --output "${output_file}" \
        --write-out '%{http_code}' "$@" "${url}"
    )"; then
    curl_status=0
  else
    curl_status=$?
  fi
  end_time="$(command date '+%s')" || end_time="${start_time}"

  if [[ ${curl_status} -ne 0 ]]; then
    cntools_log API \
      "${method} ${endpoint} -> curl:${curl_status} ($((end_time - start_time))s)" || true
    return "${curl_status}"
  fi
  [[ "${http_status}" =~ ^[0-9]{3}$ ]] || http_status="000"
  cntools_log API \
    "${method} ${endpoint} -> ${http_status} ($((end_time - start_time))s)" || true
  if (( 10#${http_status} < 200 || 10#${http_status} >= 400 )); then
    return 22
  fi
}
