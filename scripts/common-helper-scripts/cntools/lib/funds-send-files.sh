#!/usr/bin/env bash
# Intermediate packages stay in the tracked private workspace. Final exports
# are published without overwrite and deliberately survive action cleanup.
# shellcheck disable=SC2034

cntools_send_signed_path_into() {
  local -n sp_result="$1"
  local sp_marker=""
  cntools_transaction_temp_file sp_marker send-signed || return 1
  sp_result="${sp_marker}.json"
  CNTOOLS_TRANSACTION_TEMP_FILES+=("${sp_result}")
}

cntools_send_save_into() {
  local -n sf_result="$1"
  local sf_source="$2" sf_kind="$3" sf_base="${CNTOOLS_NODE_HOME}/transactions"
  local sf_directory="" sf_path="" sf_time="" sf_umask=""
  sf_result=""
  [[ "${sf_kind}" == signed || "${sf_kind}" == unsigned ]] || return 2
  cntools_transaction_directory_safe "${CNTOOLS_NODE_HOME}" || return 1
  sf_umask="$(umask)"; umask 077
  if [[ ! -e "${sf_base}" && ! -L "${sf_base}" ]]; then
    mkdir -- "${sf_base}" || { umask "${sf_umask}"; return 1; }
  fi
  cntools_transaction_directory_safe "${sf_base}" || { umask "${sf_umask}"; return 1; }
  printf -v sf_time '%(%Y%m%d-%H%M%S)T' -1
  sf_directory="$(mktemp -d "${sf_base}/send-${sf_time}.XXXXXX")" || { umask "${sf_umask}"; return 1; }
  umask "${sf_umask}"
  sf_path="${sf_directory}/${sf_kind}.json"
  if ! cntools_transaction_publish "${sf_source}" "${sf_path}"; then
    rmdir -- "${sf_directory}" 2>/dev/null || true
    return 1
  fi
  sf_result="${sf_path}"
  CNTOOLS_SEND_SAVED_PACKAGE="${sf_path}"
  cntools_transaction_ui_log_path 'Send package saved' "${sf_path}"
}
