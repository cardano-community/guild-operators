#!/usr/bin/env bash
# Shared GPG transport. Secrets travel over a descriptor, never argv or logs.
cntools_key_crypto_run() {
  local binary="$1" operation="$2" source="$3" output="$4" password="$5" errors="$6" mask=""
  local -a command=("${binary}" --no-options --quiet --batch --yes --no-tty
    --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3 --output "${output}")
  [[ -x "${binary}" && -f "${source}" && ! -L "${source}" &&
     -f "${output}" && ! -L "${output}" && -O "${output}" &&
     -f "${errors}" && ! -L "${errors}" && -O "${errors}" &&
     -n "${password}" && "${password}" != *$'\n'* && "${password}" != *$'\r'* ]] || return 2
  case "${operation}" in
    encrypt) command+=(--symmetric --cipher-algo AES256 "${source}") ;;
    decrypt) command+=(--decrypt "${source}") ;;
    *) return 2 ;;
  esac
  printf -v mask '%*s' "${#command[@]}" ''; mask="${mask// /0}"
  cntools_run_command_timeout 60 "${mask}" -- "${command[@]}" 3<<< "${password}" >/dev/null 2> "${errors}"
}
