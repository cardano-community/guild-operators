#!/usr/bin/env bash
# Shared GPG transport. Secrets travel over a descriptor, never argv or logs.
cntools_key_crypto_run() {
  local binary="$1" operation="$2" source="$3" output="$4" password="$5" errors="$6" mask=""
  local timeout_seconds="${7:-60}" maximum_output="${8:-0}"
  local -a command=("${binary}" --no-options --quiet --batch --yes --no-tty
    --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3 --output "${output}")
  [[ -x "${binary}" && -f "${source}" && ! -L "${source}" &&
     -f "${output}" && ! -L "${output}" && -O "${output}" &&
     -f "${errors}" && ! -L "${errors}" && -O "${errors}" &&
     -n "${password}" && "${password}" != *$'\n'* && "${password}" != *$'\r'* &&
     "${timeout_seconds}" =~ ^[1-9][0-9]*$ && "${maximum_output}" =~ ^(0|[1-9][0-9]*)$ ]] || return 2
  case "${operation}" in
    encrypt) command+=(--symmetric --cipher-algo AES256 "${source}") ;;
    decrypt)
      [[ "${maximum_output}" == 0 ]] || command+=(--max-output "${maximum_output}")
      command+=(--decrypt "${source}") ;;
    *) return 2 ;;
  esac
  printf -v mask '%*s' "${#command[@]}" ''; mask="${mask// /0}"
  cntools_run_command_timeout "${timeout_seconds}" "${mask}" -- "${command[@]}" 3<<< "${password}" >/dev/null 2> "${errors}"
}
