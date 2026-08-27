#!/usr/bin/env bash
# CNTools update availability state. Functions only; source from cntools.sh.
# Operational update actions live in lib/update.sh and are loaded on demand.

cntools_update_version_valid() {
  [[ "${1:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

cntools_update_version_compare() {
  local left="${1:-}"
  local right="${2:-}"
  local output_variable="${3:-}"
  local left_part=""
  local right_part=""
  local _cntools_version_comparison=0
  local index=0
  local LC_ALL=C
  local -a left_parts=()
  local -a right_parts=()

  cntools_update_version_valid "${left}" || return 2
  cntools_update_version_valid "${right}" || return 2
  [[ "${output_variable}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2

  IFS='.' read -r -a left_parts <<< "${left}"
  IFS='.' read -r -a right_parts <<< "${right}"
  for (( index = 0; index < 3; index++ )); do
    left_part="${left_parts[index]}"
    right_part="${right_parts[index]}"
    if (( ${#left_part} > ${#right_part} )); then
      _cntools_version_comparison=1
      break
    elif (( ${#left_part} < ${#right_part} )); then
      _cntools_version_comparison=-1
      break
    elif [[ "${left_part}" > "${right_part}" ]]; then
      _cntools_version_comparison=1
      break
    elif [[ "${left_part}" < "${right_part}" ]]; then
      _cntools_version_comparison=-1
      break
    fi
  done
  printf -v "${output_variable}" '%s' "${_cntools_version_comparison}"
}

cntools_update_url() {
  local resource="${1:-}"
  local relative_path=""

  case "${resource}" in
    version) relative_path='scripts/common-helper-scripts/cntools/VERSION' ;;
    changelog) relative_path='docs/Scripts/cntools-changelog.md' ;;
    *) return 2 ;;
  esac
  [[ "${CNTOOLS_ACCOUNT:-}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 2
  cntools_startup_branch_valid "${CNTOOLS_BRANCH:-}" || return 2
  printf 'https://raw.githubusercontent.com/%s/guild-operators/%s/%s\n' \
    "${CNTOOLS_ACCOUNT}" "${CNTOOLS_BRANCH}" "${relative_path}"
}

cntools_update_state_valid() {
  local status="${1:-}"
  local remote_version="${2:-}"

  case "${status}" in
    unchecked|skipped|error|offline)
      [[ -z "${remote_version}" ]]
      ;;
    current|available|ahead)
      cntools_update_version_valid "${remote_version}"
      ;;
    *) return 1 ;;
  esac
}

cntools_update_directory_protected() {
  local directory="${1:-}"
  local mode=""
  local group_mode=""
  local other_mode=""

  [[ -d "${directory}" && ! -L "${directory}" && -O "${directory}" ]] || return 1
  if mode="$(stat -c '%a' -- "${directory}" 2>/dev/null)"; then
    :
  elif mode="$(stat -f '%Lp' "${directory}" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  group_mode="${mode: -2:1}"
  other_mode="${mode: -1}"
  case "${group_mode}${other_mode}" in
    *[2367]*) return 1 ;;
    *) return 0 ;;
  esac
}

cntools_update_state_save() {
  local state_file="${CNTOOLS_UPDATE_STATE_FILE:-}"
  local state_dir="${CNTOOLS_UPDATE_STATE_DIR:-}"
  local staged_file=""

  cntools_update_state_valid \
    "${CNTOOLS_UPDATE_STATUS:-}" "${CNTOOLS_UPDATE_REMOTE_VERSION:-}" || return 2
  [[ -n "${state_dir}" && -n "${state_file}" &&
     "${state_file}" = "${state_dir}/"* &&
     -f "${state_file}" && ! -L "${state_file}" && -O "${state_file}" ]] || return 1
  staged_file="$(mktemp "${state_dir}/.cntools-update-state.XXXXXX")" || return 1
  CNTOOLS_UPDATE_STATE_STAGING_FILE="${staged_file}"
  if [[ ! -f "${staged_file}" || -L "${staged_file}" || ! -O "${staged_file}" ]] ||
     ! chmod 0600 "${staged_file}" ||
     ! printf '%s\n%s\n' \
       "${CNTOOLS_UPDATE_STATUS}" "${CNTOOLS_UPDATE_REMOTE_VERSION}" > "${staged_file}" ||
     ! mv -f -- "${staged_file}" "${state_file}"; then
    cntools_update_remove_state_staging
    return 1
  fi
  CNTOOLS_UPDATE_STATE_STAGING_FILE=""
}

cntools_update_state_load() {
  local state_file="${CNTOOLS_UPDATE_STATE_FILE:-}"
  local state_dir="${CNTOOLS_UPDATE_STATE_DIR:-}"
  local -a state_lines=()

  [[ -n "${state_dir}" && -n "${state_file}" &&
     "${state_file}" = "${state_dir}/"* &&
     -f "${state_file}" && ! -L "${state_file}" && -O "${state_file}" ]] || return 1
  mapfile -t state_lines < "${state_file}" || return 1
  [[ ${#state_lines[@]} -eq 2 ]] || return 1
  cntools_update_state_valid "${state_lines[0]}" "${state_lines[1]}" || return 1
  CNTOOLS_UPDATE_STATUS="${state_lines[0]}"
  CNTOOLS_UPDATE_REMOTE_VERSION="${state_lines[1]}"
}

cntools_update_set_state() {
  local status="${1:-}"
  local remote_version="${2:-}"

  cntools_update_state_valid "${status}" "${remote_version}" || return 2
  CNTOOLS_UPDATE_STATUS="${status}"
  CNTOOLS_UPDATE_REMOTE_VERSION="${remote_version}"
  cntools_update_state_save || {
    cntools_log ERROR "Could not persist update availability state" || true
    return 1
  }
}

cntools_update_remove_state_staging() {
  local staged_file="${CNTOOLS_UPDATE_STATE_STAGING_FILE:-}"

  if [[ -n "${staged_file}" &&
        "${staged_file}" = "${CNTOOLS_UPDATE_STATE_DIR:-/invalid}/.cntools-update-state."* &&
        -f "${staged_file}" && ! -L "${staged_file}" &&
        -O "${staged_file}" ]]; then
    rm -f -- "${staged_file}"
  fi
  CNTOOLS_UPDATE_STATE_STAGING_FILE=""
}

cntools_update_remove_version_response() {
  local response_file="${CNTOOLS_UPDATE_VERSION_RESPONSE_FILE:-}"

  if [[ -n "${response_file}" &&
        "${response_file}" = "${CNTOOLS_UPDATE_STATE_DIR:-/invalid}/.cntools-update-version."* &&
        -f "${response_file}" && ! -L "${response_file}" &&
        -O "${response_file}" ]]; then
    rm -f -- "${response_file}"
  fi
  CNTOOLS_UPDATE_VERSION_RESPONSE_FILE=""
}

cntools_update_init() {
  local state_file=""

  CNTOOLS_UPDATE_STATUS="unchecked"
  CNTOOLS_UPDATE_REMOTE_VERSION=""
  CNTOOLS_UPDATE_STATE_FILE=""
  CNTOOLS_UPDATE_STATE_DIR=""
  CNTOOLS_DEPLOY_STARTED_FILE=""
  CNTOOLS_UPDATE_VERSION_RESPONSE_FILE=""
  CNTOOLS_UPDATE_STATE_STAGING_FILE=""

  CNTOOLS_UPDATE_STATE_DIR="${CNTOOLS_LOG_PARENT:-}"
  [[ -n "${CNTOOLS_UPDATE_STATE_DIR}" ]] || {
    CNTOOLS_UPDATE_STATUS="error"
    cntools_log ERROR "Could not resolve the update availability state directory" || true
    return 0
  }
  if ! cntools_update_directory_protected "${CNTOOLS_UPDATE_STATE_DIR}" ||
     [[ "${CNTOOLS_UPDATE_STATE_DIR}" == "${CNTOOLS_ROOT}" ||
        "${CNTOOLS_UPDATE_STATE_DIR}" == "${CNTOOLS_ROOT}/"* ]]; then
    CNTOOLS_UPDATE_STATUS="error"
    cntools_log ERROR "Update availability state directory is unsafe" || true
    CNTOOLS_UPDATE_STATE_DIR=""
    return 0
  fi
  state_file="$(mktemp "${CNTOOLS_UPDATE_STATE_DIR}/.cntools-update-state.XXXXXX")" || {
    CNTOOLS_UPDATE_STATUS="error"
    cntools_log ERROR "Could not create update availability state" || true
    return 0
  }
  if [[ ! -f "${state_file}" || -L "${state_file}" || ! -O "${state_file}" ]] ||
     ! chmod 0600 "${state_file}"; then
    rm -f -- "${state_file}"
    CNTOOLS_UPDATE_STATUS="error"
    cntools_log ERROR "Update availability state is unsafe" || true
    return 0
  fi
  CNTOOLS_UPDATE_STATE_FILE="${state_file}"
  CNTOOLS_DEPLOY_STARTED_FILE="${state_file}.deploy-started"
  cntools_update_state_save || {
    CNTOOLS_UPDATE_STATUS="error"
    cntools_log ERROR "Could not initialize update availability state" || true
    return 0
  }

  if [[ "${CNTOOLS_MODE:-}" == "offline" ]]; then
    cntools_update_set_state offline "" || true
    cntools_log UPDATE "availability check skipped in offline mode" || true
  elif [[ "${CNTOOLS_UPDATE_CHECK:-Y}" != "Y" ]]; then
    cntools_update_set_state skipped "" || true
    cntools_log UPDATE "automatic availability check skipped" || true
  else
    cntools_update_check auto || true
  fi
}

cntools_update_check() {
  local check_kind="${1:-auto}"
  local response_file=""
  local version_url=""
  local remote_version=""
  local comparison=0
  local response_size=""
  local request_status=0
  local -a version_lines=()

  case "${check_kind}" in auto|manual) ;; *) return 2 ;; esac
  cntools_update_state_load || {
    CNTOOLS_UPDATE_STATUS="unchecked"
    CNTOOLS_UPDATE_REMOTE_VERSION=""
    if [[ "${check_kind}" != "manual" ]] || ! cntools_update_state_save; then
      CNTOOLS_UPDATE_STATUS="error"
      cntools_log ERROR "Update availability state is unavailable" || true
      return 1
    fi
    cntools_log UPDATE "reinitialized invalid update availability state" || true
  }
  if [[ "${CNTOOLS_MODE:-}" == "offline" ]]; then
    cntools_update_set_state offline "" || true
    cntools_log UPDATE "${check_kind} availability check blocked in offline mode" || true
    return 2
  fi
  cntools_update_version_valid "${CNTOOLS_VERSION:-}" || {
    cntools_update_set_state error "" || true
    cntools_log ERROR "Installed CNTools version is invalid during update check" || true
    return 1
  }
  version_url="$(cntools_update_url version)" || {
    cntools_update_set_state error "" || true
    cntools_log ERROR "Could not construct update VERSION URL" || true
    return 1
  }
  response_file="$(mktemp "${CNTOOLS_UPDATE_STATE_DIR}/.cntools-update-version.XXXXXX")" || {
    cntools_update_set_state error "" || true
    cntools_log ERROR "Could not stage update VERSION response" || true
    return 1
  }
  CNTOOLS_UPDATE_VERSION_RESPONSE_FILE="${response_file}"
  chmod 0600 "${response_file}" || {
    cntools_update_remove_version_response
    cntools_update_set_state error "" || true
    cntools_log ERROR "Could not secure update VERSION response" || true
    return 1
  }

  if ( cntools_http_request GET "${version_url}" "${response_file}" \
    --connect-timeout 2 --max-time 3 --max-filesize 64 --no-show-error ); then
    request_status=0
  else
    request_status=$?
  fi
  if (( request_status != 0 )); then
    cntools_update_remove_version_response
    cntools_update_set_state error "" || true
    cntools_log UPDATE "${check_kind} availability check failed status=${request_status}" || true
    return 1
  fi
  response_size="$(wc -c < "${response_file}")" || response_size=""
  response_size="${response_size//[[:space:]]/}"
  if [[ ! "${response_size}" =~ ^[0-9]+$ ]] || (( response_size > 64 )); then
    cntools_update_remove_version_response
    cntools_update_set_state error "" || true
    cntools_log UPDATE "${check_kind} availability response exceeded 64 bytes" || true
    return 1
  fi
  mapfile -t version_lines < "${response_file}" || true
  cntools_update_remove_version_response
  if [[ ${#version_lines[@]} -ne 1 ]] ||
     ! cntools_update_version_valid "${version_lines[0]:-}"; then
    cntools_update_set_state error "" || true
    cntools_log UPDATE "${check_kind} availability response was invalid" || true
    return 1
  fi
  remote_version="${version_lines[0]}"
  cntools_update_version_compare "${remote_version}" "${CNTOOLS_VERSION}" comparison || {
    cntools_update_set_state error "" || true
    return 1
  }
  if (( comparison > 0 )); then
    cntools_update_set_state available "${remote_version}" || return 1
  elif (( comparison < 0 )); then
    cntools_update_set_state ahead "${remote_version}" || return 1
  else
    cntools_update_set_state current "${remote_version}" || return 1
  fi
  cntools_log UPDATE \
    "${check_kind} availability check status=${CNTOOLS_UPDATE_STATUS} installed=${CNTOOLS_VERSION} remote=${remote_version} source=${CNTOOLS_ACCOUNT}/guild-operators@${CNTOOLS_BRANCH}" || true
}

cntools_update_render_banner() {
  local banner=""

  [[ "${CNTOOLS_UPDATE_STATUS:-}" == "available" ]] || return 0
  banner="Update available: v${CNTOOLS_UPDATE_REMOTE_VERSION}  [u]"
  printf '\n%s%s%s\n' \
    "${CNTOOLS_UI_YELLOW:-}" \
    "$(cntools_ui_fit "${banner}" "${CNTOOLS_UI_DRAW_WIDTH:-79}")" \
    "${CNTOOLS_UI_RESET:-}"
}

cntools_update_render_summary() {
  local available=""
  local status_text=""

  case "${CNTOOLS_UPDATE_STATUS:-unchecked}" in
    available)
      available="${CNTOOLS_UPDATE_REMOTE_VERSION}"
      status_text="Update available"
      ;;
    current)
      available="${CNTOOLS_UPDATE_REMOTE_VERSION}"
      status_text="Installed version is current"
      ;;
    ahead)
      available="${CNTOOLS_UPDATE_REMOTE_VERSION}"
      status_text="Installed version is newer than this branch"
      ;;
    skipped) status_text="Automatic check skipped" ;;
    offline) status_text="Unavailable in offline mode" ;;
    error) status_text="Check unavailable; use Check Again" ;;
    *) status_text="Not checked" ;;
  esac
  [[ -n "${available}" ]] || available="Not known"
  cntools_ui_render_field Installed "${CNTOOLS_VERSION:-unknown}"
  cntools_ui_render_field Available "${available}"
  cntools_ui_render_field Source \
    "${CNTOOLS_ACCOUNT:-unknown}/guild-operators @ ${CNTOOLS_BRANCH:-unknown}"
  cntools_ui_render_field Status "${status_text}"
  printf '\n'
}

cntools_update_cleanup() {
  local state_file="${CNTOOLS_UPDATE_STATE_FILE:-}"
  local started_file="${CNTOOLS_DEPLOY_STARTED_FILE:-}"

  cntools_update_remove_version_response
  cntools_update_remove_state_staging
  if [[ -n "${started_file}" && -n "${state_file}" &&
        "${started_file}" == "${state_file}.deploy-started" &&
        "${started_file}" = "${CNTOOLS_UPDATE_STATE_DIR:-/invalid}/"* ]]; then
    rm -f -- "${started_file}"
  fi
  if [[ -n "${state_file}" &&
        "${state_file}" = "${CNTOOLS_UPDATE_STATE_DIR:-/invalid}/"* ]]; then
    rm -f -- "${state_file}"
  fi
  CNTOOLS_UPDATE_STATE_FILE=""
  CNTOOLS_UPDATE_STATE_DIR=""
  CNTOOLS_DEPLOY_STARTED_FILE=""
  CNTOOLS_UPDATE_VERSION_RESPONSE_FILE=""
  CNTOOLS_UPDATE_STATE_STAGING_FILE=""
}
