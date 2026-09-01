#!/usr/bin/env bash
# CNTools logging plus operational command and HTTP wrappers. Functions only.

declare -ag CNTOOLS_HTTP_SECRET_FILES=()
declare -ag CNTOOLS_HTTP_TEMP_FILES=()

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
  cntools_http_temp_files_cleanup
  cntools_http_secret_files_cleanup
  if [[ "${CNTOOLS_LOG_FD:-}" =~ ^[0-9]+$ ]]; then
    exec {CNTOOLS_LOG_FD}>&-
  fi
  CNTOOLS_LOG_FD=""
  CNTOOLS_LOG_READY="N"
}

cntools_http_secret_file_create() {
  local _cntools_output_name="${1:-}"
  local _cntools_token="${CNTOOLS_KOIOS_TOKEN:-}"
  local _cntools_temporary_directory="${CNTOOLS_TMP_DIR:-}"
  local _cntools_secret_file=""
  local _cntools_previous_umask=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  [[ -n "${_cntools_token}" ]] || return 2
  export -n CNTOOLS_KOIOS_TOKEN KOIOS_API_TOKEN 2>/dev/null || return 1
  unset KOIOS_API_TOKEN 2>/dev/null || return 1
  [[ -n "${_cntools_temporary_directory}" &&
     "${_cntools_temporary_directory}" = /* &&
     -d "${_cntools_temporary_directory}" &&
     ! -L "${_cntools_temporary_directory}" &&
     -O "${_cntools_temporary_directory}" &&
     -w "${_cntools_temporary_directory}" ]] || return 1

  _cntools_previous_umask="$(umask)"
  umask 077
  _cntools_secret_file="$(mktemp \
    "${_cntools_temporary_directory}/.cntools-http-auth.XXXXXX")" || {
    umask "${_cntools_previous_umask}"
    return 1
  }
  umask "${_cntools_previous_umask}"
  chmod 0600 "${_cntools_secret_file}" || {
    rm -f -- "${_cntools_secret_file}"
    return 1
  }
  if [[ ! -f "${_cntools_secret_file}" || -L "${_cntools_secret_file}" ||
        ! -O "${_cntools_secret_file}" ]]; then
    rm -f -- "${_cntools_secret_file}" 2>/dev/null || true
    return 1
  fi
  CNTOOLS_HTTP_SECRET_FILES+=("${_cntools_secret_file}")
  if ! printf 'Authorization: Bearer %s\n' \
      "${_cntools_token}" > "${_cntools_secret_file}"; then
    cntools_http_secret_file_remove "${_cntools_secret_file}" || true
    return 1
  fi
  _cntools_output_ref="${_cntools_secret_file}"
}

cntools_http_secret_file_remove() {
  local secret_file="${1:-}"
  local candidate=""
  local -a remaining=()

  [[ -n "${secret_file}" &&
     "${secret_file}" = "${CNTOOLS_TMP_DIR:-/invalid}/.cntools-http-auth."* ]] ||
    return 2
  if [[ -f "${secret_file}" && ! -L "${secret_file}" &&
        -O "${secret_file}" ]]; then
    : > "${secret_file}" 2>/dev/null || true
    rm -f -- "${secret_file}" 2>/dev/null || true
  fi
  for candidate in "${CNTOOLS_HTTP_SECRET_FILES[@]}"; do
    [[ "${candidate}" == "${secret_file}" ]] || remaining+=("${candidate}")
  done
  CNTOOLS_HTTP_SECRET_FILES=("${remaining[@]}")
}

cntools_http_secret_files_cleanup() {
  local secret_file=""

  for secret_file in "${CNTOOLS_HTTP_SECRET_FILES[@]}"; do
    cntools_http_secret_file_remove "${secret_file}" || true
  done
  CNTOOLS_HTTP_SECRET_FILES=()
}

cntools_http_temp_file_remove() {
  local temporary_file="${1:-}"
  local candidate=""
  local tracked="N"
  local -a remaining=()

  [[ -n "${temporary_file}" ]] || return 2
  for candidate in "${CNTOOLS_HTTP_TEMP_FILES[@]}"; do
    if [[ "${candidate}" == "${temporary_file}" ]]; then
      tracked="Y"
    else
      remaining+=("${candidate}")
    fi
  done
  [[ "${tracked}" == "Y" ]] || return 2
  if [[ -f "${temporary_file}" && ! -L "${temporary_file}" &&
        -O "${temporary_file}" ]]; then
    rm -f -- "${temporary_file}" 2>/dev/null || true
  fi
  CNTOOLS_HTTP_TEMP_FILES=("${remaining[@]}")
}

cntools_http_temp_files_cleanup() {
  local temporary_file=""

  for temporary_file in "${CNTOOLS_HTTP_TEMP_FILES[@]}"; do
    cntools_http_temp_file_remove "${temporary_file}" || true
  done
  CNTOOLS_HTTP_TEMP_FILES=()
}

cntools_log_render_argument() {
  local rendered=""
  printf -v rendered '%q' "${1:-}"
  printf '%s' "${rendered}"
}

cntools_http_secret_file_tracked() {
  local requested_file="${1:-}"
  local secret_file=""

  [[ -n "${requested_file}" ]] || return 2
  for secret_file in "${CNTOOLS_HTTP_SECRET_FILES[@]}"; do
    [[ "${secret_file}" == "${requested_file}" ]] && return 0
  done
  return 1
}

cntools_api_log_replay() {
  local method="${1:-}"
  local url="${2:-}"
  local argument=""
  local rendered=""
  local replay=""
  local replay_auth_header=""
  local secret_file=""
  local index=0
  local -a arguments=()
  shift 2 2>/dev/null || return 2
  arguments=("$@")

  [[ "${method}" =~ ^(GET|POST|PUT|PATCH|DELETE|HEAD)$ ]] || return 2
  [[ "${url}" =~ ^https://[^[:space:]]+$ ]] || return 2

  # Preserve this expansion for the operator's replay shell; do not resolve it
  # inside CNTools or put the real token in the session log.
  # shellcheck disable=SC2016
  replay_auth_header='"Authorization: Bearer ${KOIOS_API_TOKEN:?set KOIOS_API_TOKEN before replaying this request}"'
  replay="curl --silent --show-error"
  replay+=" --max-time $(cntools_log_render_argument \
    "${CNTOOLS_CURL_TIMEOUT:-10}")"
  replay+=" --request $(cntools_log_render_argument "${method}")"
  while (( index < ${#arguments[@]} )); do
    argument="${arguments[index]}"
    if [[ "${argument}" == "--header" ]] &&
       (( index + 1 < ${#arguments[@]} )); then
      secret_file="${arguments[index + 1]#@}"
      if [[ "${arguments[index + 1]}" == @* ]] &&
         cntools_http_secret_file_tracked "${secret_file}"; then
        replay+=" --header"
        replay+=" ${replay_auth_header}"
        index=$((index + 2))
        continue
      fi
    elif [[ "${argument}" == --header=@* ]]; then
      secret_file="${argument#--header=@}"
      if cntools_http_secret_file_tracked "${secret_file}"; then
        replay+=" --header"
        replay+=" ${replay_auth_header}"
        index=$((index + 1))
        continue
      fi
    fi
    rendered="$(cntools_log_render_argument "${argument}")"
    replay+=" ${rendered}"
    index=$((index + 1))
  done
  replay+=" $(cntools_log_render_argument "${url}")"
  cntools_log API "Replay: ${replay}" || true
}

cntools_api_request() {
  local method="${1:-}"
  local url="${2:-}"
  local output_file="${3:-}"
  shift 3 2>/dev/null || return 2

  if [[ "${CNTOOLS_MODE:-}" == "offline" ]]; then
    cntools_http_request "${method}" "${url}" "${output_file}" "$@"
    return $?
  fi
  cntools_api_log_replay "${method}" "${url}" "$@" || true
  cntools_http_request "${method}" "${url}" "${output_file}" "$@"
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

cntools_run_command_timeout() {
  local timeout_seconds="${1:-}"
  local mask="${2:-}"
  local rendered=""
  local piece=""
  local index=0
  local status=0
  local command_pid=0
  local deadline=0
  local kill_deadline=0
  local timed_out="N"
  shift 2 2>/dev/null || return 2
  [[ "${1:-}" == "--" ]] || return 2
  shift
  (( $# > 0 )) || return 2
  [[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || return 2
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

  if [[ -n "${CNTOOLS_TIMEOUT_BIN:-}" &&
        "${CNTOOLS_TIMEOUT_BIN}" = /* &&
        -x "${CNTOOLS_TIMEOUT_BIN}" &&
        ! -d "${CNTOOLS_TIMEOUT_BIN}" ]]; then
    if "${CNTOOLS_TIMEOUT_BIN}" --signal=TERM --kill-after=2 \
        "${timeout_seconds}" "$@"; then
      status=0
    else
      status=$?
    fi
  else
    "$@" &
    command_pid=$!
    deadline=$((SECONDS + timeout_seconds))
    while (( SECONDS < deadline )) && kill -0 "${command_pid}" 2>/dev/null; do
      command sleep 0.1
    done
    if kill -0 "${command_pid}" 2>/dev/null; then
      timed_out="Y"
      kill -TERM "${command_pid}" 2>/dev/null || true
      kill_deadline=$((SECONDS + 2))
      while (( SECONDS < kill_deadline )) &&
            kill -0 "${command_pid}" 2>/dev/null; do
        command sleep 0.1
      done
      kill -KILL "${command_pid}" 2>/dev/null || true
    fi
    if wait "${command_pid}"; then
      status=0
    else
      status=$?
    fi
    [[ "${timed_out}" != "Y" ]] || status=124
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

cntools_http_curl_error_detail() {
  local error_file="${1:-}"
  local request_url="${2:-}"
  local detail=""
  local token="${CNTOOLS_KOIOS_TOKEN:-}"

  [[ -f "${error_file}" && ! -L "${error_file}" ]] || return 1
  IFS= read -r detail < "${error_file}" || true
  detail="$(cntools_log_sanitize_line "${detail:0:400}")"
  [[ -n "${detail}" ]] || return 1

  # Curl normally reports only transport details. If it ever echoes the full
  # request or an authorization value, discard that detail rather than trying
  # to partially redact an unknown credential format.
  if [[ ( -n "${token}" && "${detail}" == *"${token}"* ) ||
        "${detail}" == *"${request_url}"* ||
        "${detail}" == *Authorization:* ||
        "${detail}" == *"Bearer "* ]]; then
    printf 'sensitive curl error detail redacted'
  else
    printf '%s' "${detail}"
  fi
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
  local error_file=""
  local error_detail=""
  local previous_umask=""
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

  previous_umask="$(umask)"
  umask 077
  error_file="$(mktemp "${output_file}.curl-error.XXXXXX")" || {
    umask "${previous_umask}"
    return 1
  }
  umask "${previous_umask}"
  chmod 0600 "${error_file}" || {
    rm -f -- "${error_file}"
    return 1
  }
  if [[ ! -f "${error_file}" || -L "${error_file}" ||
        ! -O "${error_file}" ]]; then
    rm -f -- "${error_file}" 2>/dev/null || true
    return 1
  fi
  CNTOOLS_HTTP_TEMP_FILES+=("${error_file}")

  endpoint="$(cntools_http_sanitized_endpoint "${url}")"
  start_time="$(command date '+%s')" || start_time=0
  if http_status="$(
      command curl --silent --show-error \
        --max-time "${CNTOOLS_CURL_TIMEOUT:-10}" \
        --request "${method}" --output "${output_file}" \
        --write-out '%{http_code}' "$@" "${url}" 2> "${error_file}"
    )"; then
    curl_status=0
  else
    curl_status=$?
  fi
  end_time="$(command date '+%s')" || end_time="${start_time}"
  error_detail="$(cntools_http_curl_error_detail \
    "${error_file}" "${url}" 2>/dev/null || true)"
  cntools_http_temp_file_remove "${error_file}" || true

  if [[ ${curl_status} -ne 0 ]]; then
    cntools_log API \
      "${method} ${endpoint} -> curl:${curl_status} ($((end_time - start_time))s)${error_detail:+: ${error_detail}}" || true
    return "${curl_status}"
  fi
  [[ "${http_status}" =~ ^[0-9]{3}$ ]] || http_status="000"
  cntools_log API \
    "${method} ${endpoint} -> ${http_status} ($((end_time - start_time))s)" || true
  if (( 10#${http_status} < 200 || 10#${http_status} >= 400 )); then
    return 22
  fi
}
