#!/usr/bin/env bash
# Intermediate packages stay in the tracked private workspace. Final exports
# survive action cleanup. Managed signing updates the selected package in place;
# imported/custom files are never overwritten.
# shellcheck disable=SC2034

cntools_transaction_signed_path_into() {
  local -n sp_result="$1"
  local sp_marker=""
  cntools_transaction_temp_file sp_marker transaction-signed || return 1
  sp_result="${sp_marker}.json"
  CNTOOLS_TRANSACTION_TEMP_FILES+=("${sp_result}")
}

cntools_transaction_save_into() {
  local -n sf_result="$1"
  local sf_source="$2" sf_kind="$3" sf_action="$4" sf_base="${CNTOOLS_ROOT:-}/.transactions"
  local sf_directory="" sf_path="" sf_time="" sf_umask="" sf_log=""
  sf_result=""
  [[ "${sf_action}" =~ ^[a-z][a-z-]{0,30}$ ]] || return 2
  [[ "${sf_kind}" == signed || "${sf_kind}" == unsigned || "${sf_kind}" == metadata ]] || return 2
  cntools_transaction_directory_safe "${CNTOOLS_ROOT:-}" || return 1
  sf_umask="$(umask)"; umask 077
  if [[ ! -e "${sf_base}" && ! -L "${sf_base}" ]]; then
    mkdir -- "${sf_base}" || { umask "${sf_umask}"; return 1; }
  fi
  cntools_transaction_directory_safe "${sf_base}" || { umask "${sf_umask}"; return 1; }
  printf -v sf_time '%(%Y%m%d-%H%M%S)T' -1
  sf_directory="$(mktemp -d "${sf_base}/${sf_action}-${sf_time}.XXXXXX")" || { umask "${sf_umask}"; return 1; }
  umask "${sf_umask}"
  sf_path="${sf_directory}/${sf_kind}.json"
  if ! cntools_transaction_publish "${sf_source}" "${sf_path}"; then
    rmdir -- "${sf_directory}" 2>/dev/null || true
    return 1
  fi
  sf_result="${sf_path}"
  printf -v sf_log '%q' "${sf_path}"
  cntools_transaction_log TRANSACTION "${sf_action} package saved file=${sf_log}"
}

# The caller has authenticated the old snapshot and new signed package. Commit
# only if the selected managed file still matches that snapshot. A private,
# short-lived lock serializes CNTools commits; atomic rename never exposes a
# partly written package. The subshell's trap cannot alter application traps.
cntools_transaction_replace_managed() (
  local replace_target="$1" replace_snapshot="$2" replace_signed="$3"
  local replace_folder='' replace_lock='' replace_stage='' replace_identity='' replace_current=''
  cntools_filesystem_managed_transaction_folder_into replace_folder "${replace_target}" || return 1
  cntools_filesystem_file_delete_safe "${replace_target}" || return 1
  cntools_transaction_file_safe "${replace_signed}" "${CNTOOLS_TRANSACTION_MAX_PACKAGE_BYTES}" || return 1
  cntools_transaction_file_safe "${replace_snapshot}" "${CNTOOLS_TRANSACTION_MAX_PACKAGE_BYTES}" || return 1
  replace_lock="${replace_folder}/.cntools-package-update.lock"
  if ! mkdir -m 700 -- "${replace_lock}" 2>/dev/null; then
    # A lock whose recorded process has ended was left by a killed session.
    local replace_holder=''
    replace_holder="$(head -c 16 -- "${replace_lock}/pid" 2>/dev/null)" || replace_holder=''
    if [[ "${replace_holder}" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "${replace_holder}" 2>/dev/null &&
       rm -f -- "${replace_lock}/pid" && rmdir -- "${replace_lock}" 2>/dev/null &&
       mkdir -m 700 -- "${replace_lock}" 2>/dev/null; then
      cntools_transaction_log FILE "Removed a stale package update lock from process ${replace_holder}"
    else
      cntools_transaction_set_error "The saved package is being updated by another session. Nothing was overwritten. If no other CNTools session is running, remove ${replace_lock} and try again."
      return 1
    fi
  fi
  printf '%s\n' "${BASHPID:-$$}" > "${replace_lock}/pid" 2>/dev/null || true
  trap '[[ -z "${replace_stage}" ]] || cntools_transaction_temp_remove "${replace_stage}" || true; rm -f -- "${replace_lock}/pid" 2>/dev/null; rmdir -- "${replace_lock}" 2>/dev/null || true' EXIT
  if ! cntools_filesystem_file_identity_into replace_identity "${replace_target}" ||
     ! cmp -s -- "${replace_target}" "${replace_snapshot}"; then
    cntools_transaction_log ERROR 'Saved package changed after selection; refusing to overwrite it'
    return 1
  fi
  cntools_transaction_temp_file replace_stage package-update "${replace_folder}" || return 1
  cntools_run_command 0000 -- cp -- "${replace_signed}" "${replace_stage}" || return 1
  chmod 0600 -- "${replace_stage}" || return 1
  cmp -s -- "${replace_stage}" "${replace_signed}" || return 1
  if ! cntools_filesystem_managed_transaction_folder_into replace_folder "${replace_target}" ||
     ! cntools_filesystem_file_delete_safe "${replace_target}" ||
     ! cntools_filesystem_file_identity_into replace_current "${replace_target}" ||
     [[ "${replace_current}" != "${replace_identity}" ]] ||
     ! cmp -s -- "${replace_target}" "${replace_snapshot}"; then
    cntools_transaction_log ERROR 'Saved package changed during publication; refusing to overwrite it'
    return 1
  fi
  cntools_run_command 00000 -- mv -T -- "${replace_stage}" "${replace_target}" || return 1
  cntools_transaction_log TRANSACTION "Managed transaction package updated file=${replace_target}" || true
)

cntools_transaction_save_signed_into() {
  local -n ss_result="$1"
  local ss_signed="$2" ss_original="$3" ss_snapshot="$4" ss_folder=''
  ss_result=''
  if cntools_filesystem_managed_transaction_folder_into ss_folder "${ss_original}"; then
    if ! cntools_transaction_replace_managed "${ss_original}" "${ss_snapshot}" "${ss_signed}"; then
      cntools_transaction_set_error 'The managed package could not be updated safely. The existing file was left untouched.'
      return 1
    fi
    ss_result="${ss_original}"
  else
    cntools_transaction_save_into "$1" "${ss_signed}" signed transaction || return 1
  fi
}
