#!/usr/bin/env bash
# CNTools update actions. Loaded only by actions in the Update submenu.

cntools_update_changelog_safe() {
  local changelog_file="${1:-}"

  [[ -f "${changelog_file}" && ! -L "${changelog_file}" ]] || return 1
  LC_ALL=C awk '
    {
      line = $0
      gsub(/\t/, "", line)
      if (line ~ /[[:cntrl:]]/) exit 1
    }
  ' "${changelog_file}"
}

cntools_update_extract_changelog() {
  local source_file="${1:-}"
  local output_file="${2:-}"
  local installed_version="${3:-}"
  local available_version="${4:-}"
  local line=""
  local section_version=""
  local comparison_installed=0
  local comparison_available=0
  local include_section="N"
  local available_seen="N"
  local heading_pattern='^##[[:space:]]+\[([^][]+)\]([[:space:]]+-[[:space:]]+.*)?$'

  [[ -f "${source_file}" && ! -L "${source_file}" &&
     -f "${output_file}" && ! -L "${output_file}" ]] || return 2
  cntools_update_version_valid "${installed_version}" || return 2
  cntools_update_version_valid "${available_version}" || return 2
  cntools_update_changelog_safe "${source_file}" || return 1
  : > "${output_file}" || return 1

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ${heading_pattern} ]]; then
      section_version="${BASH_REMATCH[1]}"
      cntools_update_version_valid "${section_version}" || return 1
      [[ "${section_version}" != "${available_version}" ]] || available_seen="Y"
      cntools_update_version_compare \
        "${section_version}" "${installed_version}" comparison_installed || return 1
      cntools_update_version_compare \
        "${section_version}" "${available_version}" comparison_available || return 1
      if (( comparison_installed > 0 && comparison_available <= 0 )); then
        include_section="Y"
      else
        include_section="N"
      fi
    elif [[ "${line}" == '## ['* || "${line}" == '## '* ]]; then
      include_section="N"
      [[ "${line}" != '## ['* ]] || return 1
    fi
    if [[ "${include_section}" == "Y" ]]; then
      printf '%s\n' "${line}" >> "${output_file}" || return 1
    fi
  done < "${source_file}"

  [[ "${available_seen}" == "Y" && -s "${output_file}" ]]
}

cntools_update_changelog_cleanup() {
  local temporary_file=""

  for temporary_file in \
    "${CNTOOLS_UPDATE_CHANGELOG_RESPONSE_FILE:-}" \
    "${CNTOOLS_UPDATE_RELEASE_NOTES_FILE:-}"; do
    [[ -n "${temporary_file}" &&
       "${temporary_file}" = "${CNTOOLS_UPDATE_STATE_DIR:-/invalid}/.cntools-"* &&
       -f "${temporary_file}" && ! -L "${temporary_file}" &&
       -O "${temporary_file}" ]] || continue
    rm -f -- "${temporary_file}"
  done
  CNTOOLS_UPDATE_CHANGELOG_RESPONSE_FILE=""
  CNTOOLS_UPDATE_RELEASE_NOTES_FILE=""
}

cntools_update_action_check() {
  local status=0

  trap 'cntools_update_remove_version_response; cntools_update_remove_state_staging' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 131' QUIT
  trap 'exit 143' TERM
  cntools_ui_action_begin "Check Again" "/ Update / Check Again"
  printf 'Checking %s/guild-operators @ %s...\n\n' \
    "${CNTOOLS_ACCOUNT}" "${CNTOOLS_BRANCH}"
  if cntools_update_check manual; then
    status=0
  else
    status=$?
  fi
  cntools_update_render_summary
  case "${CNTOOLS_UPDATE_STATUS:-error}" in
    available)
      printf '%sA newer CNTools version is available.%s\n' \
        "${CNTOOLS_UI_GREEN:-}" "${CNTOOLS_UI_RESET:-}"
      ;;
    current)
      printf 'This installation is up to date.\n'
      ;;
    ahead)
      printf 'This installation is newer than the selected branch.\n'
      ;;
    offline)
      printf 'Update checks are unavailable in offline mode.\n'
      ;;
    *)
      printf '%sThe update check could not be completed. See %s for details.%s\n' \
        "${CNTOOLS_UI_YELLOW:-}" "${CNTOOLS_LOG}" "${CNTOOLS_UI_RESET:-}"
      ;;
  esac
  cntools_log UPDATE "manual check action completed status=${status}" || true
  cntools_ui_wait
  return "${status}"
}

cntools_update_action_view_changes() {
  local changelog_url=""
  local response_file=""
  local notes_file=""
  local response_size=""
  local request_status=0

  CNTOOLS_UPDATE_CHANGELOG_RESPONSE_FILE=""
  CNTOOLS_UPDATE_RELEASE_NOTES_FILE=""
  trap 'cntools_update_changelog_cleanup' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 131' QUIT
  trap 'exit 143' TERM

  cntools_ui_action_begin "View Changes" "/ Update / View Changes"
  if ! cntools_update_state_load; then
    CNTOOLS_UPDATE_STATUS="error"
    CNTOOLS_UPDATE_REMOTE_VERSION=""
    printf 'Update state is unavailable. Run Check Again.\n'
    cntools_log ERROR "changelog view blocked: update state unavailable" || true
    cntools_ui_wait
    return 1
  fi
  if [[ "${CNTOOLS_UPDATE_STATUS:-}" != "available" ]]; then
    printf 'No newer version is currently known. Run Check Again first.\n'
    cntools_log UPDATE "changelog view skipped: no available version" || true
    cntools_ui_wait
    return 0
  fi
  if [[ "${CNTOOLS_MODE:-}" == "offline" ]]; then
    printf 'Release notes are unavailable in offline mode.\n'
    cntools_log UPDATE "changelog view blocked in offline mode" || true
    cntools_ui_wait
    return 0
  fi
  changelog_url="$(cntools_update_url changelog)" || {
    printf 'Could not determine the changelog source.\n'
    cntools_log ERROR "Could not construct CNTools changelog URL" || true
    cntools_ui_wait
    return 1
  }
  response_file="$(mktemp "${CNTOOLS_UPDATE_STATE_DIR}/.cntools-changelog.XXXXXX")" || {
    printf 'Could not create a private changelog response file.\n'
    cntools_log ERROR "Could not stage CNTools changelog response" || true
    cntools_ui_wait
    return 1
  }
  CNTOOLS_UPDATE_CHANGELOG_RESPONSE_FILE="${response_file}"
  notes_file="$(mktemp "${CNTOOLS_UPDATE_STATE_DIR}/.cntools-release-notes.XXXXXX")" || {
    cntools_update_changelog_cleanup
    printf 'Could not create a private release-notes file.\n'
    cntools_log ERROR "Could not stage CNTools release notes" || true
    cntools_ui_wait
    return 1
  }
  CNTOOLS_UPDATE_RELEASE_NOTES_FILE="${notes_file}"
  if ! chmod 0600 "${response_file}" "${notes_file}"; then
    cntools_update_changelog_cleanup
    printf 'Could not secure the temporary release-notes files.\n'
    cntools_log ERROR "Could not secure CNTools changelog temporary files" || true
    cntools_ui_wait
    return 1
  fi

  printf 'Loading changes from %s/guild-operators @ %s...\n\n' \
    "${CNTOOLS_ACCOUNT}" "${CNTOOLS_BRANCH}"
  if cntools_api_request GET "${changelog_url}" "${response_file}" \
    --connect-timeout 3 --max-filesize 262144 --no-show-error; then
    request_status=0
  else
    request_status=$?
  fi
  response_size="$(wc -c < "${response_file}" 2>/dev/null || true)"
  response_size="${response_size//[[:space:]]/}"
  if (( request_status != 0 )) ||
     [[ ! "${response_size}" =~ ^[0-9]+$ ]] ||
     (( response_size > 262144 )) ||
     ! cntools_update_extract_changelog \
       "${response_file}" "${notes_file}" \
       "${CNTOOLS_VERSION}" "${CNTOOLS_UPDATE_REMOTE_VERSION}"; then
    cntools_update_changelog_cleanup
    printf '%sRelease notes are unavailable. The update itself can still be installed.%s\n' \
      "${CNTOOLS_UI_YELLOW:-}" "${CNTOOLS_UI_RESET:-}"
    cntools_log UPDATE \
      "changelog unavailable installed=${CNTOOLS_VERSION} remote=${CNTOOLS_UPDATE_REMOTE_VERSION} request_status=${request_status}" || true
    cntools_ui_wait
    return 0
  fi
  rm -f -- "${response_file}"
  CNTOOLS_UPDATE_CHANGELOG_RESPONSE_FILE=""

  printf '%sChanges in v%s since v%s%s\n\n' \
    "${CNTOOLS_UI_BOLD:-}" "${CNTOOLS_UPDATE_REMOTE_VERSION}" \
    "${CNTOOLS_VERSION}" "${CNTOOLS_UI_RESET:-}"
  cntools_ui_page_file "${notes_file}" || true
  rm -f -- "${notes_file}"
  CNTOOLS_UPDATE_RELEASE_NOTES_FILE=""
  cntools_log UPDATE \
    "changelog viewed installed=${CNTOOLS_VERSION} remote=${CNTOOLS_UPDATE_REMOTE_VERSION}" || true
}

cntools_update_action_install() {
  local deploy_status=0
  local force_deploy="N"
  local confirmation_prompt="Install this update now?"

  cntools_ui_action_begin "Install Update" "/ Update / Install"
  if ! cntools_update_state_load; then
    CNTOOLS_UPDATE_STATUS="error"
    CNTOOLS_UPDATE_REMOTE_VERSION=""
    printf 'Update state is unavailable. Run Check Again.\n'
    cntools_log ERROR "installation blocked: update state unavailable" || true
    cntools_ui_wait
    return 1
  fi
  if [[ "${CNTOOLS_MODE:-}" == "offline" ]]; then
    printf 'Updates cannot be installed in offline mode.\n'
    cntools_log UPDATE "installation blocked in offline mode" || true
    cntools_ui_wait
    return 0
  fi
  case "${CNTOOLS_UPDATE_STATUS:-}" in
    available) ;;
    current)
      if [[ "${CNTOOLS_UPDATE_REMOTE_VERSION}" != "${CNTOOLS_VERSION}" ]]; then
        printf 'Update state is inconsistent. Run Check Again.\n'
        cntools_log ERROR \
          "force deployment blocked: installed=${CNTOOLS_VERSION} remote=${CNTOOLS_UPDATE_REMOTE_VERSION}" || true
        cntools_ui_wait
        return 1
      fi
      force_deploy="Y"
      confirmation_prompt="Force deploy this version anyway?"
      ;;
    *)
      printf 'No deployable version is currently known. Run Check Again first.\n'
      cntools_log UPDATE "installation skipped: no deployable version" || true
      cntools_ui_wait
      return 0
      ;;
  esac

  printf 'CNTools          : v%s -> v%s\n' \
    "${CNTOOLS_VERSION}" "${CNTOOLS_UPDATE_REMOTE_VERSION}"
  printf 'Repository       : %s/guild-operators\n' "${CNTOOLS_ACCOUNT}"
  printf 'Branch           : %s\n' "${CNTOOLS_BRANCH}"
  printf 'Deployment       : %s (%s)\n\n' \
    "${CNTOOLS_IMPLEMENTATION_NAME}" "${CNTOOLS_NETWORK}"
  if [[ "${force_deploy}" == "Y" ]]; then
    printf '%sThe installed and selected versions are both v%s.%s\n\n' \
      "${CNTOOLS_UI_YELLOW:-}" "${CNTOOLS_UPDATE_REMOTE_VERSION}" \
      "${CNTOOLS_UI_RESET:-}"
  fi
  printf '%sGuild Deploy refreshes the complete managed script and configuration snapshot,%s\n' \
    "${CNTOOLS_UI_YELLOW:-}" "${CNTOOLS_UI_RESET:-}"
  printf 'not only CNTools. No node binaries or OS packages will be installed.\n\n'
  if ! cntools_ui_confirm "${confirmation_prompt}"; then
    if [[ "${force_deploy}" == "Y" ]]; then
      printf '\nForce deployment cancelled.\n'
      cntools_log UPDATE \
        "force deployment cancelled version=${CNTOOLS_UPDATE_REMOTE_VERSION}" || true
    else
      printf '\nUpdate cancelled.\n'
      cntools_log UPDATE \
        "installation cancelled remote=${CNTOOLS_UPDATE_REMOTE_VERSION}" || true
    fi
    cntools_ui_wait
    return 0
  fi
  if [[ "${force_deploy}" == "Y" ]]; then
    cntools_log UPDATE \
      "force deployment confirmed version=${CNTOOLS_UPDATE_REMOTE_VERSION} source=${CNTOOLS_ACCOUNT}/guild-operators@${CNTOOLS_BRANCH}" || true
  else
    cntools_log UPDATE \
      "installation confirmed remote=${CNTOOLS_UPDATE_REMOTE_VERSION} source=${CNTOOLS_ACCOUNT}/guild-operators@${CNTOOLS_BRANCH}" || true
  fi
  printf '\nStarting Guild Deploy. CNTools will close when it finishes.\n\n'
  if cntools_startup_deploy_branch "${CNTOOLS_BRANCH}"; then
    deploy_status=0
  else
    deploy_status=$?
  fi
  return "${deploy_status}"
}
