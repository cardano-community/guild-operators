#!/usr/bin/env bash
# Private, no-overwrite publication of native policy artifacts.
# shellcheck disable=SC2034,SC2015
declare -a CNTOOLS_POLICY_STAGES=()
declare -a CNTOOLS_POLICY_WORK_FILES=()
CNTOOLS_POLICY_ERROR=''
CNTOOLS_POLICY_DIRECTORY=''
CNTOOLS_POLICY_ID=''

cntools_policy_error() {
  CNTOOLS_POLICY_ERROR="$1"
  cntools_transaction_log ERROR "${CNTOOLS_POLICY_ERROR}"
  return 1
}

cntools_policy_target_into() {
  local _policy_target_name="$1" _policy_name="$2" LC_ALL=C
  [[ "${_policy_name}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ &&
     "${CNTOOLS_ASSET_DIR:-}" == /* && "${CNTOOLS_ASSET_DIR}" != / ]] || return 2
  printf -v "${_policy_target_name}" '%s' "${CNTOOLS_ASSET_DIR%/}/${_policy_name}"
}

cntools_policy_filenames_validate() {
  local filename='' reserved='' LC_ALL=C
  local -A names=()
  for filename in "${CNTOOLS_POLICY_VKEY_FILENAME:-policy.vkey}" "${CNTOOLS_POLICY_SKEY_FILENAME:-policy.skey}" \
    "${CNTOOLS_POLICY_SCRIPT_FILENAME:-policy.script}" "${CNTOOLS_POLICY_ID_FILENAME:-policy.id}"; do
    [[ "${filename}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || {
      cntools_policy_error 'Configured policy filenames must be simple, distinct filenames.'; return 1;
    }
    for reserved in "${filename}" "${filename}.gpg" "${filename}.previous"; do
      [[ -z "${names[${reserved}]:-}" ]] || { cntools_policy_error 'Configured policy filenames or backups overlap.'; return 1; }
      names["${reserved}"]=Y
    done
  done
  [[ "${CNTOOLS_POLICY_SCRIPT_FILENAME:-policy.script}" == *.script ]] || {
    cntools_policy_error 'The configured native policy script filename must end in .script.'; return 1;
  }
}

# Read-only preflight: declining the review does not create even the asset root.
cntools_policy_preflight() {
  local target='' root="${CNTOOLS_ASSET_DIR:-}" help=''
  CNTOOLS_POLICY_ERROR=''
  [[ -n "${CNTOOLS_CLI:-}" && "${CNTOOLS_CLI}" == /* && -x "${CNTOOLS_CLI}" && ! -d "${CNTOOLS_CLI}" ]] &&
    cntools_transaction_text_control_free "${CNTOOLS_CLI}" || {
    cntools_policy_error 'Cardano CLI is required to create a policy.'; return 1;
  }
  help="$(LC_ALL=C mv --help 2>&1)" || { cntools_policy_error 'Policy creation requires GNU mv for safe no-overwrite publication.'; return 1; }
  [[ "${help}" == *--no-target-directory* && "${help}" == *--no-clobber* ]] || {
    cntools_policy_error 'Policy creation requires GNU mv for safe no-overwrite publication.'; return 1;
  }
  cntools_policy_filenames_validate || return 1
  cntools_policy_target_into target "$1" || { cntools_policy_error 'Use a valid policy name (1–64 letters, numbers, dots, underscores or hyphens, starting with a letter or number).'; return 1; }
  [[ ! -e "${target}" && ! -L "${target}" ]] || { cntools_policy_error 'A policy folder with this name already exists. Nothing was changed.'; return 1; }
  [[ "${root}" != */ && "${root##*/}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] &&
    cntools_filesystem_path_components_safe "${root}" || { cntools_policy_error 'The asset root is unset or unsafe.'; return 1; }
  if [[ -e "${root}" ]]; then
    cntools_transaction_directory_safe "${root}" || { cntools_policy_error 'The asset root must be owned, writable and protected from group/public writes.'; return 1; }
  else
    cntools_transaction_directory_safe "${root%/*}" || { cntools_policy_error 'The asset parent must be owned, writable and protected from group/public writes.'; return 1; }
  fi
}

cntools_policy_stage_into() {
  local output="$1" temporary='' saved=''
  saved="$(umask)"; umask 077
  if [[ ! -e "${CNTOOLS_ASSET_DIR}" ]]; then
    if ! mkdir -- "${CNTOOLS_ASSET_DIR}"; then umask "${saved}"; return 1; fi
  fi
  if ! cntools_transaction_directory_safe "${CNTOOLS_ASSET_DIR}"; then umask "${saved}"; return 1; fi
  temporary="$(mktemp -d "${CNTOOLS_ASSET_DIR}/.cntools-policy-new.XXXXXX")" || { umask "${saved}"; return 1; }
  umask "${saved}"
  CNTOOLS_POLICY_STAGES+=("${temporary}")
  printf -v "${output}" '%s' "${temporary}"
}

cntools_policy_files_cleanup() {
  local stage='' work=''
  for work in "${CNTOOLS_POLICY_WORK_FILES[@]}"; do
    [[ "${work##*/}" == .cntools-policy-work.* && -f "${work}" && ! -L "${work}" && -O "${work}" ]] || continue
    cntools_filesystem_path_components_safe "${work}" || continue
    rm -f -- "${work}" || cntools_transaction_log ERROR "Could not remove private policy work file=${work}"
  done
  CNTOOLS_POLICY_WORK_FILES=()
  for stage in "${CNTOOLS_POLICY_STAGES[@]}"; do
    [[ "${stage}" == "${CNTOOLS_ASSET_DIR%/}/.cntools-policy-new."* &&
       -d "${stage}" && ! -L "${stage}" && -O "${stage}" ]] || continue
    cntools_filesystem_path_components_safe "${stage}" || continue
    rm -rf -- "${stage}" || cntools_transaction_log ERROR "Could not remove private policy staging directory=${stage}"
  done
  CNTOOLS_POLICY_STAGES=()
}

cntools_policy_work_into() {
  local output="$1" directory="$2" temporary='' saved=''
  cntools_transaction_directory_safe "${directory}" || return 1
  saved="$(umask)"; umask 077
  temporary="$(mktemp "${directory}/.cntools-policy-work.XXXXXX")" || { umask "${saved}"; return 1; }
  umask "${saved}"
  CNTOOLS_POLICY_WORK_FILES+=("${temporary}")
  printf -v "${output}" '%s' "${temporary}"
}

cntools_policy_publish() {
  local stage="$1" name="$2" target='' entry='' tracked=N
  for entry in "${CNTOOLS_POLICY_STAGES[@]}"; do [[ "${entry}" != "${stage}" ]] || tracked=Y; done
  [[ "${tracked}" == Y ]] && cntools_transaction_directory_safe "${stage}" &&
    cntools_policy_target_into target "${name}" || return 1
  [[ ! -e "${target}" && ! -L "${target}" ]] || { cntools_policy_error 'The destination appeared during preparation. It was not overwritten.'; return 1; }
  cntools_transaction_directory_safe "${CNTOOLS_ASSET_DIR}" || return 1
  for entry in "${stage}"/*; do
    [[ -f "${entry}" && ! -L "${entry}" && -O "${entry}" ]] && chmod 0600 "${entry}" || return 1
  done
  cntools_run_command 000000 -- mv -T -n -- "${stage}" "${target}" || return 1
  [[ ! -e "${stage}" && ! -L "${stage}" ]] && cntools_transaction_directory_safe "${target}" || {
    cntools_policy_error 'The policy could not be published without overwriting an existing entry.'; return 1;
  }
  CNTOOLS_POLICY_DIRECTORY="${target}"
  cntools_transaction_log POLICY "Created policy=${name} id=${CNTOOLS_POLICY_ID} directory=${target}"
}
