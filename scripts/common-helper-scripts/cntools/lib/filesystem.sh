#!/usr/bin/env bash
# Shared filesystem facts and trusted ancestry; domain-specific policies stay
# with their callers. Shared writable ancestors require the sticky bit.
# shellcheck disable=SC2034

cntools_filesystem_path_components_safe() {
  local path="${1:-}"
  local current="/"
  local component=""
  local -a components=()

  [[ "${path}" = /* ]] || return 1
  [[ -n "${path}" && ! "${path}" =~ [[:cntrl:]] ]] || return 1
  IFS='/' read -r -a components <<< "${path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current%/}/${component}"
    [[ ! -L "${current}" ]] || return 1
  done
}


cntools_filesystem_size_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_path="${2:-}"
  local _cntools_size=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if _cntools_size="$(stat -c '%s' -- "${_cntools_path}" 2>/dev/null)"; then
    :
  elif _cntools_size="$(stat -f '%z' "${_cntools_path}" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  [[ "${_cntools_size}" =~ ^[0-9]+$ ]] || return 1
  _cntools_output_ref="${_cntools_size}"
}

cntools_filesystem_mtime_into() {
  local _cntools_output_name="${1:-}" _cntools_path="${2:-}" _cntools_mtime=""
  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if _cntools_mtime="$(stat -c '%Y' -- "${_cntools_path}" 2>/dev/null)"; then :
  elif _cntools_mtime="$(stat -f '%m' "${_cntools_path}" 2>/dev/null)"; then :
  else return 1; fi
  [[ "${_cntools_mtime}" =~ ^[0-9]+$ ]] || return 1
  _cntools_output_ref="${_cntools_mtime}"
}

# A deletion is a single owned regular file, never a directory or symlink.
# The parent must be owned/private so an unrelated user cannot replace targets.
cntools_filesystem_file_delete_safe() {
  local target="${1:-}" parent='' mode=''
  [[ "${target}" == /* && -f "${target}" && ! -L "${target}" && -O "${target}" ]] || return 1
  cntools_filesystem_path_components_safe "${target}" || return 1
  parent="${target%/*}"; [[ -n "${parent}" ]] || parent=/
  [[ -d "${parent}" && -O "${parent}" && -w "${parent}" && -x "${parent}" ]] || return 1
  cntools_filesystem_directory_ancestry_safe "${parent}" || return 1
  cntools_filesystem_mode_into mode "${parent}" || return 1
  (( (8#${mode} & 0022) == 0 ))
}

cntools_filesystem_file_identity_into() {
  local identity_output="${1:-}" identity_path="${2:-}" identity_value=''
  [[ "${identity_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n identity_result="${identity_output}"
  identity_result=''
  if identity_value="$(stat -c '%d:%i:%s:%Y:%Z' -- "${identity_path}" 2>/dev/null)"; then :
  elif identity_value="$(stat -f '%d:%i:%z:%m:%c' "${identity_path}" 2>/dev/null)"; then :
  else return 1; fi
  [[ "${identity_value}" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
  identity_result="${identity_value}"
}

# Only generated one-level transaction folders qualify as managed exports.
cntools_filesystem_managed_transaction_folder_into() {
  local managed_output="$1" managed_file="$2" managed_root="${CNTOOLS_ROOT:-}" managed_folder='' managed_name=''
  [[ "${managed_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n managed_result="${managed_output}"
  managed_result=''
  [[ -n "${managed_root}" && "${managed_root}" == /* && "${managed_root}" != / ]] || return 1
  managed_folder="${managed_file%/*}"; managed_name="${managed_folder##*/}"
  [[ "${managed_folder%/*}" == "${managed_root}/.transactions" &&
     "${managed_name}" =~ ^[a-z][a-z-]{0,30}-[0-9]{8}-[0-9]{6}\.[A-Za-z0-9]{6}$ ]] || return 1
  [[ -d "${managed_folder}" && ! -L "${managed_folder}" && -O "${managed_folder}" &&
     -d "${managed_root}/.transactions" && -O "${managed_root}/.transactions" ]] || return 1
  cntools_filesystem_directory_ancestry_safe "${managed_folder}" || return 1
  managed_result="${managed_folder}"
}

# Bounded snapshot for an explicitly selected managed export folder. Refuse
# symlinks, special files, foreign ownership and shared-writable directories.
cntools_filesystem_owned_tree_identity_into() {
  local tree_output="${1:-}" tree_root="${2:-}" tree_directory='' tree_entry='' tree_name='' tree_identity='' tree_mode=''
  local tree_manifest='' tree_count=0 tree_index=0
  local -a tree_pending=("${tree_root}")
  [[ "${tree_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "${tree_root}" == /* ]] || return 2
  local -n tree_result="${tree_output}"
  tree_result=''
  cntools_filesystem_directory_ancestry_safe "${tree_root}" || return 1
  while ((tree_index < ${#tree_pending[@]})); do
    tree_directory="${tree_pending[tree_index]}"; tree_index=$((tree_index+1))
    [[ -d "${tree_directory}" && ! -L "${tree_directory}" && -O "${tree_directory}" &&
       -w "${tree_directory}" && -r "${tree_directory}" && -x "${tree_directory}" ]] || return 1
    cntools_filesystem_mode_into tree_mode "${tree_directory}" || return 1
    (( (8#${tree_mode} & 0022) == 0 )) || return 1
    cntools_filesystem_file_identity_into tree_identity "${tree_directory}" || return 1
    tree_manifest+="D ${tree_directory} ${tree_identity}"$'\n'
    for tree_entry in "${tree_directory}/"* "${tree_directory}/".*; do
      tree_name="${tree_entry##*/}"; [[ "${tree_name}" != . && "${tree_name}" != .. ]] || continue
      [[ -e "${tree_entry}" || -L "${tree_entry}" ]] || continue
      [[ ! "${tree_entry}" =~ [[:cntrl:]] && ! -L "${tree_entry}" && -O "${tree_entry}" ]] || return 1
      tree_count=$((tree_count+1)); ((tree_count <= 1024)) || return 1
      if [[ -d "${tree_entry}" ]]; then tree_pending+=("${tree_entry}")
      elif [[ -f "${tree_entry}" ]]; then
        cntools_filesystem_file_identity_into tree_identity "${tree_entry}" || return 1
        tree_manifest+="F ${tree_entry} ${tree_identity}"$'\n'
      else return 1; fi
    done
  done
  tree_result="${tree_manifest}"
}


cntools_filesystem_mode_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_path="${2:-}"
  local _cntools_mode=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if _cntools_mode="$(stat -c '%a' -- "${_cntools_path}" 2>/dev/null)"; then
    :
  elif _cntools_mode="$(stat -f '%Op' "${_cntools_path}" 2>/dev/null)"; then
    # BSD's low subfield omits setuid/setgid/sticky bits. Mask the complete
    # mode instead so trusted shared ancestry is checked consistently.
    [[ "${_cntools_mode}" =~ ^[0-7]{5,6}$ ]] || return 1
    printf -v _cntools_mode '%03o' "$((8#${_cntools_mode} & 07777))"
  else
    return 1
  fi
  [[ "${_cntools_mode}" =~ ^[0-7]{3,4}$ ]] || return 1
  _cntools_output_ref="${_cntools_mode}"
}


cntools_filesystem_uid_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_path="${2:-}"
  local _cntools_uid=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if _cntools_uid="$(stat -c '%u' -- "${_cntools_path}" 2>/dev/null)"; then
    :
  elif _cntools_uid="$(stat -f '%u' "${_cntools_path}" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  [[ "${_cntools_uid}" =~ ^[0-9]+$ ]] || return 1
  _cntools_output_ref="${_cntools_uid}"
}


cntools_filesystem_directory_ancestry_safe() {
  local directory="${1:-}"
  local current="/"
  local component=""
  local mode=""
  local uid=""
  local permissions=0
  local -a components=()

  [[ -n "${directory}" && "${directory}" = /* ]] || return 1
  [[ ! "${directory}" =~ [[:cntrl:]] ]] || return 1
  IFS='/' read -r -a components <<< "${directory}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current%/}/${component}"
    [[ -d "${current}" && ! -L "${current}" ]] || return 1
    cntools_filesystem_uid_into uid "${current}" || return 1
    [[ "${uid}" == "${EUID}" || "${uid}" == "0" ]] || return 1
    cntools_filesystem_mode_into mode "${current}" || return 1
    permissions=$((8#${mode}))
    if (( (permissions & 0022) != 0 &&
          (permissions & 01000) == 0 )); then
      return 1
    fi
  done
}

cntools_filesystem_device_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_path="${2:-}"
  local _cntools_device=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_device="$(stat -c '%d' -- "${_cntools_path}" 2>/dev/null)" ||
    _cntools_device="$(stat -f '%d' "${_cntools_path}" 2>/dev/null)" || return 1
  [[ "${_cntools_device}" =~ ^[0-9]+$ ]] || return 1
  _cntools_output_ref="${_cntools_device}"
}

# CNTools keeps its staging, work files, locks and KES/opcert recovery in one
# owner-only folder beside the node's priv data, never inside it.
cntools_state_path_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_kind="${2:-}"
  local _cntools_home="${CNTOOLS_NODE_HOME:-}"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_kind}" =~ ^(work|locks|recovery)$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  [[ "${_cntools_home}" == /* && "${_cntools_home}" != / ]] || return 1
  _cntools_output_ref="${_cntools_home%/}/.cntools/${_cntools_kind}"
}

cntools_state_directory_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_kind="${2:-}"
  local _cntools_state=""
  local _cntools_directory=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_state_path_into _cntools_state "${_cntools_kind}" || return $?
  [[ -d "${CNTOOLS_NODE_HOME%/}" && ! -L "${CNTOOLS_NODE_HOME%/}" ]] &&
    cntools_filesystem_path_components_safe "${CNTOOLS_NODE_HOME%/}" || return 1
  for _cntools_directory in "${_cntools_state%/*}" "${_cntools_state}"; do
    if [[ ! -e "${_cntools_directory}" && ! -L "${_cntools_directory}" ]]; then
      (umask 077; mkdir -- "${_cntools_directory}" 2>/dev/null) ||
        [[ -d "${_cntools_directory}" && ! -L "${_cntools_directory}" ]] || return 1
    fi
    [[ -d "${_cntools_directory}" && ! -L "${_cntools_directory}" &&
       -O "${_cntools_directory}" ]] &&
      chmod 0700 "${_cntools_directory}" || return 1
  done
  _cntools_output_ref="${_cntools_state}"
}

# Staging and scratch files use the state work folder when it shares the
# target's filesystem, so publishing stays one atomic rename or link. Without
# that, they fall back to the target folder for the brief final write.
cntools_state_work_directory_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_target="${2:-}"
  local _cntools_work=""
  local _cntools_target_device=""
  local _cntools_work_device=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref="${_cntools_target%/}"
  [[ -d "${_cntools_target}" && ! -L "${_cntools_target}" ]] || return 1
  if cntools_state_directory_into _cntools_work work &&
     cntools_filesystem_device_into _cntools_target_device "${_cntools_target}" &&
     cntools_filesystem_device_into _cntools_work_device "${_cntools_work}" &&
     [[ "${_cntools_target_device}" == "${_cntools_work_device}" ]]; then
    _cntools_output_ref="${_cntools_work}"
  fi
  return 0
}

# A staging path is CNTools-owned only directly below the target root or the
# state work folder, with the expected reserved name prefix.
cntools_state_staging_path_valid() {
  local path="${1:-}" root="${2:-}" prefix="${3:-}" work=""
  [[ -n "${prefix}" && "${path##*/}" == "${prefix}"* ]] || return 1
  [[ "${path%/*}" == "${root%/}" ]] && return 0
  cntools_state_path_into work work && [[ "${path%/*}" == "${work}" ]]
}
