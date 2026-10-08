#!/usr/bin/env bash
# Owner-only permissions with optional immutable protection; no interactive sudo.
# shellcheck disable=SC2034
declare -a CNTOOLS_POLICY_CHATTR=() CNTOOLS_POLICY_UNLOCKED=()
CNTOOLS_POLICY_LOCK_METHOD='read-only permissions'
CNTOOLS_POLICY_WARNING=''

cntools_policy_chattr() {
  local mask=''
  (( ${#CNTOOLS_POLICY_CHATTR[@]} > 0 )) || return 1
  printf -v mask '%*s' "$((${#CNTOOLS_POLICY_CHATTR[@]}+3))" ''; mask="${mask// /0}"
  cntools_run_command "${mask}" -- "${CNTOOLS_POLICY_CHATTR[@]}" "$1" -- "$2" >/dev/null 2>&1
}

cntools_policy_chattr_prepare() {
  local directory="$1" binary='' sudo_bin='' probe=''
  CNTOOLS_POLICY_CHATTR=()
  binary="$(type -P chattr 2>/dev/null || true)"; [[ -n "${binary}" ]] || return 1
  cntools_policy_work_into probe "${directory}" || return 1
  CNTOOLS_POLICY_CHATTR=("${binary}")
  if cntools_policy_chattr +i "${probe}"; then
    cntools_policy_chattr -i "${probe}" && return 0
    cntools_policy_error "The immutable probe could not be unlocked: ${probe}"; return 2
  fi
  sudo_bin="$(type -P sudo 2>/dev/null || true)"; [[ -n "${sudo_bin}" ]] || { CNTOOLS_POLICY_CHATTR=(); return 1; }
  CNTOOLS_POLICY_CHATTR=("${sudo_bin}" -n "${binary}")
  if cntools_policy_chattr +i "${probe}"; then
    cntools_policy_chattr -i "${probe}" && return 0
    cntools_policy_error "The immutable probe could not be unlocked: ${probe}"; return 2
  fi
  CNTOOLS_POLICY_CHATTR=(); return 1
}

cntools_policy_locks_restore() {
  local file='' status=0
  for file in "${CNTOOLS_POLICY_UNLOCKED[@]}"; do
    [[ -f "${file}" && ! -L "${file}" ]] || continue
    cntools_policy_chattr +i "${file}" || { cntools_policy_error "Could not restore an original immutable lock: ${file}" || true; status=1; }
  done
  CNTOOLS_POLICY_UNLOCKED=()
  return "${status}"
}

cntools_policy_locks_unlock() {
  local directory="$1" file='' attributes='' lsattr=''
  local -a immutable=()
  lsattr="$(type -P lsattr 2>/dev/null || true)"; [[ -n "${lsattr}" ]] || return 0
  for file in "${directory}"/* "${directory}"/.[!.]* "${directory}"/..?*; do
    [[ -f "${file}" && ! -L "${file}" ]] || continue
    [[ "${file##*/}" != .cntools-* ]] || continue
    attributes="$(cntools_run_command 0000 -- "${lsattr}" -d -- "${file}" 2>/dev/null || true)"; attributes="${attributes%% *}"
    [[ "${attributes}" != *i* ]] || immutable+=("${file}")
  done
  (( ${#immutable[@]} != 0 )) || return 0
  cntools_policy_chattr_prepare "${directory}" || { cntools_policy_error 'Immutable policy files could not be unlocked. No keys were changed.'; return 1; }
  for file in "${immutable[@]}"; do
    if ! cntools_policy_chattr -i "${file}"; then
      cntools_policy_locks_restore || true
      cntools_policy_error 'Not all immutable policy files could be unlocked. No keys were changed.'; return 1
    fi
    CNTOOLS_POLICY_UNLOCKED+=("${file}")
  done
}

cntools_policy_locks_apply() {
  local directory="$1" operation="$2" file='' mode=0400 status=0 applied_file=''
  local -a files=() applied=()
  CNTOOLS_POLICY_LOCK_METHOD='read-only permissions'
  [[ "${operation}" != decrypt ]] || { mode=0600; CNTOOLS_POLICY_LOCK_METHOD='owner-only writable permissions'; }
  for file in "${directory}"/* "${directory}"/.[!.]* "${directory}"/..?*; do
    [[ -f "${file}" && ! -L "${file}" ]] || continue
    [[ "${file##*/}" != .cntools-* ]] || continue
    cntools_run_command 000 -- chmod "${mode}" "${file}" || { cntools_policy_error 'Policy protection changed, but some file permissions could not be updated. Review this folder.'; return 1; }
    files+=("${file}")
  done
  [[ "${operation}" == encrypt && "${CNTOOLS_ENABLE_CHATTR:-true}" == true ]] || return 0
  cntools_policy_chattr_prepare "${directory}" || status=$?
  ((status != 2)) || return 1
  if ((status != 0)); then CNTOOLS_POLICY_WARNING='Immutable locking is unavailable; read-only permissions remain active.'; return 0; fi
  for file in "${files[@]}"; do
    if cntools_policy_chattr +i "${file}"; then applied+=("${file}"); else
      for applied_file in "${applied[@]}"; do cntools_policy_chattr -i "${applied_file}" || cntools_transaction_log ERROR "Could not undo partial immutable lock=${applied_file}"; done
      CNTOOLS_POLICY_WARNING='Immutable locking was incomplete; read-only permissions remain active.'; return 0
    fi
  done
  CNTOOLS_POLICY_LOCK_METHOD='read-only permissions + immutable flag'
}
