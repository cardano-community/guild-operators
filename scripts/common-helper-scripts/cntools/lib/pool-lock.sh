#!/usr/bin/env bash
# Best-effort immutable locks, with owner-only permissions as the baseline.
# shellcheck disable=SC2034
declare -a CNTOOLS_POOL_CHATTR=() CNTOOLS_POOL_UNLOCKED=()
CNTOOLS_POOL_LOCK_METHOD='read-only permissions'

cntools_pool_chattr() {
  (( ${#CNTOOLS_POOL_CHATTR[@]} > 0 )) || return 1
  local mask=""; printf -v mask '%*s' "$((${#CNTOOLS_POOL_CHATTR[@]}+3))" ''; mask="${mask// /0}"
  cntools_run_command "${mask}" -- "${CNTOOLS_POOL_CHATTR[@]}" "$1" -- "$2" >/dev/null 2>&1
}

cntools_pool_chattr_prepare() {
  local directory="$1" binary="" sudo_bin="" probe=""
  CNTOOLS_POOL_CHATTR=()
  binary="$(type -P chattr 2>/dev/null || true)"; [[ -n "${binary}" ]] || return 1
  cntools_pool_temp_into probe "${directory}" || return 1
  CNTOOLS_POOL_CHATTR=("${binary}")
  if cntools_pool_chattr +i "${probe}"; then
    cntools_pool_chattr -i "${probe}" && return 0
    cntools_pool_write_error "The immutable probe could not be unlocked: ${probe}"; return 2
  fi
  sudo_bin="$(type -P sudo 2>/dev/null || true)"; [[ -n "${sudo_bin}" ]] || { CNTOOLS_POOL_CHATTR=(); return 1; }
  CNTOOLS_POOL_CHATTR=("${sudo_bin}" -n "${binary}")
  if cntools_pool_chattr +i "${probe}"; then
    cntools_pool_chattr -i "${probe}" && return 0
    cntools_pool_write_error "The immutable probe could not be unlocked: ${probe}"; return 2
  fi
  CNTOOLS_POOL_CHATTR=(); return 1
}

cntools_pool_locks_restore() {
  local file=""
  for file in "${CNTOOLS_POOL_UNLOCKED[@]}"; do
    [[ -f "${file}" && ! -L "${file}" ]] || continue
    cntools_pool_chattr +i "${file}" || { cntools_pool_write_error "Could not restore an original immutable lock: ${file}"; return 1; }
  done
  CNTOOLS_POOL_UNLOCKED=()
}

cntools_pool_locks_unlock() {
  local directory="$1" file="" attributes="" lsattr=""
  local -a immutable=()
  CNTOOLS_POOL_UNLOCKED=()
  lsattr="$(type -P lsattr 2>/dev/null || true)"; [[ -n "${lsattr}" ]] || return 0
  for file in "${directory}"/* "${directory}"/.[!.]* "${directory}"/..?*; do
    [[ -f "${file}" && ! -L "${file}" && "${file##*/}" != .cntools-* ]] || continue
    attributes="$(cntools_run_command 0000 -- "${lsattr}" -d -- "${file}" 2>/dev/null || true)"; attributes="${attributes%% *}"
    [[ "${attributes}" != *i* ]] || immutable+=("${file}")
  done
  (( ${#immutable[@]} != 0 )) || return 0
  cntools_pool_chattr_prepare "${directory}" || { cntools_pool_write_error 'Immutable pool files could not be unlocked. Nothing was changed.'; return 1; }
  for file in "${immutable[@]}"; do
    if ! cntools_pool_chattr -i "${file}"; then
      cntools_pool_locks_restore || true
      cntools_pool_write_error 'Not all immutable pool files could be unlocked. No keys were changed.'; return 1
    fi
    CNTOOLS_POOL_UNLOCKED+=("${file}")
  done
}

cntools_pool_locks_apply() {
  local directory="$1" operation="$2" file="" applied_file="" status=0 mode=0400
  local -a files=() applied=()
  CNTOOLS_POOL_LOCK_METHOD='read-only permissions'
  [[ "${operation}" != decrypt ]] || mode=0600
  for file in "${directory}"/* "${directory}"/.[!.]* "${directory}"/..?*; do
    [[ -f "${file}" && ! -L "${file}" && "${file##*/}" != .cntools-* ]] || continue
    files+=("${file}")
    cntools_run_command 000 -- chmod "${mode}" "${file}" || CNTOOLS_POOL_WRITE_WARNING='Some pool file permissions could not be changed. Review the pool directory.'
  done
  [[ "${operation}" == encrypt && "${CNTOOLS_ENABLE_CHATTR:-true}" == true ]] || return 0
  cntools_pool_chattr_prepare "${directory}" || status=$?
  if ((status == 2)); then return 1; fi
  if ((status != 0)); then CNTOOLS_POOL_WRITE_WARNING='Immutable locking is unavailable; read-only permissions remain active.'; return 0; fi
  for file in "${files[@]}"; do
    if cntools_pool_chattr +i "${file}"; then applied+=("${file}"); else
      for applied_file in "${applied[@]}"; do cntools_pool_chattr -i "${applied_file}" || cntools_transaction_log ERROR "Could not undo partial immutable lock=${applied_file}"; done
      CNTOOLS_POOL_WRITE_WARNING='Immutable locking was incomplete; read-only permissions remain active.'; return 0
    fi
  done
  CNTOOLS_POOL_LOCK_METHOD='read-only permissions + immutable flag'
}
