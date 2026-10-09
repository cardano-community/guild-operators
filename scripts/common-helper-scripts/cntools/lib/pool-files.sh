#!/usr/bin/env bash
# Owned, private staging for pool writes; read-only pool inventory stays separate.
# shellcheck disable=SC2034,SC2015
declare -a CNTOOLS_POOL_STAGES=() CNTOOLS_POOL_TEMP_FILES=()
CNTOOLS_POOL_WRITE_ERROR=''
CNTOOLS_POOL_WRITE_WARNING=''
CNTOOLS_POOL_WRITTEN_DIRECTORY=''
CNTOOLS_POOL_WRITTEN_ID=''

cntools_pool_write_error() {
  CNTOOLS_POOL_WRITE_ERROR="$1"
  cntools_transaction_log ERROR "${CNTOOLS_POOL_WRITE_ERROR}"
  return 1
}

cntools_pool_directory_writable() {
  local directory="$1" mode=""
  [[ -d "${directory}" && ! -L "${directory}" && -O "${directory}" && -w "${directory}" && -x "${directory}" ]] &&
    cntools_filesystem_path_components_safe "${directory}" && cntools_filesystem_directory_ancestry_safe "${directory}" &&
    cntools_filesystem_mode_into mode "${directory}" || return 1
  (( (8#${mode} & 0022) == 0 ))
}

cntools_pool_write_root_prepare() {
  local root="${CNTOOLS_POOL_DIR:-}" parent="" saved=""
  [[ "${root}" == /* && "${root}" != / && "${root##*/}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] &&
    cntools_filesystem_path_components_safe "${root}" || { cntools_pool_write_error 'The pool root is unset or unsafe.'; return 1; }
  if [[ ! -e "${root}" ]]; then
    parent="${root%/*}"
    cntools_pool_directory_writable "${parent}" || { cntools_pool_write_error 'The pool parent must be owned, writable and protected from group/public writes.'; return 1; }
    saved="$(umask)"; umask 077
    if ! mkdir -- "${root}"; then umask "${saved}"; return 1; fi
    umask "${saved}"
  fi
  cntools_pool_directory_writable "${root}" || { cntools_pool_write_error 'The pool root must be owned, writable and protected from group/public writes.'; return 1; }
}

cntools_pool_target_into() {
  local output="$1" name="$2" root="${CNTOOLS_POOL_DIR:-}" LC_ALL=C
  [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ && "${root}" == /* && "${root}" != / ]] || return 2
  printf -v "${output}" '%s' "${root%/}/${name}"
}

cntools_pool_filenames_validate() {
  local kind="" filename="" reserved=""
  local -A names=()
  # Reject filename collisions before generation or protection touches a key.
  for kind in id cold-vkey cold-skey cold-hardware calidus-skey calidus-vkey calidus-id kes-vkey kes-skey vrf-vkey vrf-skey counter opcert kes-start config metadata; do
    cntools_pool_file_name_into filename "${kind}" || return 1
    for reserved in "${filename}" "${filename}.gpg" "${filename}.previous"; do
      [[ -z "${names[${reserved}]:-}" ]] || { cntools_pool_write_error 'Configured pool filenames or backups overlap.'; return 1; }
      names["${reserved}"]=Y
    done
    if [[ "${kind}" == id ]]; then
      [[ -z "${names[${filename}-bech32]:-}" ]] || return 1
      names["${filename}-bech32"]=Y
    fi
  done
}

cntools_pool_write_environment() {
  local help="" target=""
  CNTOOLS_POOL_WRITE_ERROR=''; CNTOOLS_POOL_WRITE_WARNING=''; CNTOOLS_POOL_WRITTEN_DIRECTORY=''; CNTOOLS_POOL_WRITTEN_ID=''
  [[ -n "${CNTOOLS_CLI:-}" && -x "${CNTOOLS_CLI}" && "${CNTOOLS_CLI}" == /* ]] || { cntools_pool_write_error 'Cardano CLI is required for pool creation/import.'; return 1; }
  help="$(LC_ALL=C mv --help 2>&1)" || { cntools_pool_write_error 'Pool creation/import requires GNU mv for safe no-clobber publication.'; return 1; }
  [[ "${help}" == *--no-target-directory* && "${help}" == *--no-clobber* ]] || return 1
  cntools_pool_filenames_validate || return 1
  cntools_pool_target_into target "$1" || { cntools_pool_write_error 'Use 1–64 letters, numbers, dots, underscores or hyphens, starting with a letter or number.'; return 1; }
  [[ ! -e "${target}" && ! -L "${target}" ]] || { cntools_pool_write_error 'A pool with this name already exists. Nothing was changed.'; return 1; }
  cntools_pool_write_root_prepare
}

cntools_pool_stage_into() {
  local output="$1" temporary="" saved=""
  saved="$(umask)"
  cntools_pool_directory_writable "${CNTOOLS_POOL_DIR}" || return 1
  umask 077
  temporary="$(mktemp -d "${CNTOOLS_POOL_DIR%/}/.cntools-pool-new.XXXXXX")" || { umask "${saved}"; return 1; }
  umask "${saved}"
  CNTOOLS_POOL_STAGES+=("${temporary}")
  printf -v "${output}" '%s' "${temporary}"
}

cntools_pool_temp_into() {
  local output="$1" directory="$2" temporary="" saved=""
  saved="$(umask)"
  cntools_pool_directory_writable "${directory}" || return 1
  umask 077
  temporary="$(mktemp "${directory}/.cntools-pool-work.XXXXXX")" || { umask "${saved}"; return 1; }
  umask "${saved}"
  CNTOOLS_POOL_TEMP_FILES+=("${temporary}")
  printf -v "${output}" '%s' "${temporary}"
}

cntools_pool_files_cleanup() {
  local file="" stage=""
  for file in "${CNTOOLS_POOL_TEMP_FILES[@]}"; do
    [[ -f "${file}" && ! -L "${file}" && -O "${file}" ]] || continue
    rm -f -- "${file}" || cntools_transaction_log ERROR "Could not remove private pool temporary file=${file}"
  done
  CNTOOLS_POOL_TEMP_FILES=()
  for stage in "${CNTOOLS_POOL_STAGES[@]}"; do
    [[ "${stage}" == "${CNTOOLS_POOL_DIR%/}/.cntools-pool-new."* && -d "${stage}" && ! -L "${stage}" && -O "${stage}" ]] || continue
    cntools_filesystem_path_components_safe "${stage}" || continue
    rm -rf -- "${stage}" || cntools_transaction_log ERROR "Could not remove private pool staging directory=${stage}"
  done
  CNTOOLS_POOL_STAGES=()
}

cntools_pool_files_cleanup_temps() {
  # Keep prepared directories tracked until publication; only remove work files.
  local -a CNTOOLS_POOL_STAGES=()
  cntools_pool_files_cleanup
}

cntools_pool_cli() {
  local response="" errors="" status=0
  cntools_transaction_temp_file response pool-command-output || return 1
  cntools_transaction_temp_file errors pool-command-error || return 1
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" "$@" || status=$?
  if ((status != 0)); then
    cntools_transaction_log_cli_failure 'Pool command failed' "${status}" "${errors}" "${response}"
    cntools_pool_write_error "${CNTOOLS_TRANSACTION_ERROR}"; return 1
  fi
}

cntools_pool_stage_publish() {
  local stage="$1" name="$2" target="" entry="" tracked=N
  for entry in "${CNTOOLS_POOL_STAGES[@]}"; do [[ "${entry}" != "${stage}" ]] || tracked=Y; done
  [[ "${tracked}" == Y ]] && cntools_pool_directory_writable "${stage}" || return 1
  cntools_pool_target_into target "${name}" || return 1
  [[ ! -e "${target}" && ! -L "${target}" ]] || { cntools_pool_write_error 'The destination appeared during preparation. It was not overwritten.'; return 1; }
  for entry in "${stage}"/* "${stage}"/.[!.]* "${stage}"/..?*; do
    [[ -e "${entry}" ]] || continue
    [[ -f "${entry}" && ! -L "${entry}" && -O "${entry}" ]] && chmod 0600 "${entry}" || return 1
  done
  cntools_run_command 000000 -- mv -T -n -- "${stage}" "${target}" || return 1
  [[ ! -e "${stage}" && ! -L "${stage}" ]] || { cntools_pool_write_error 'The prepared pool could not be published without overwriting an existing entry.'; return 1; }
  CNTOOLS_POOL_WRITTEN_DIRECTORY="${target}"
  cntools_transaction_log POOL "Published pool=${name} directory=${target} id=${CNTOOLS_POOL_WRITTEN_ID}"
}
