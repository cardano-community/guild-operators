#!/usr/bin/env bash
# CIP-83 basic interoperability. Secrets are passed using inherited descriptors.
# shellcheck disable=SC2034

cntools_message_crypto_arguments_into() {
  local -n crypto_args_ref="$1"
  local help=""
  command -v openssl >/dev/null || return 1
  help="$(openssl enc -help 2>&1)"
  [[ "${help}" == *-pbkdf2* ]] || return 1
  crypto_args_ref=(-aes-256-cbc -pbkdf2 -iter 10000 -md sha256 -salt -a -A)
  # OpenSSL 3.2+ defaults to 16 bytes; CIP-83 requires eight.
  [[ "${help}" != *-saltlen* ]] || crypto_args_ref+=(-saltlen 8)
}

# Inputs are variable names, not secret values; output contains ciphertext only.
# Caller must disable xtrace before reading the secrets as well.
cntools_message_encrypt_into() {
  local crypto_output_name="$1" crypto_plain_name="$2" crypto_pass_name="$3"
  local crypto_encoded="" crypto_recovered="" crypto_status=0
  local -n crypto_output_ref="${crypto_output_name}" crypto_plain_ref="${crypto_plain_name}" crypto_pass_ref="${crypto_pass_name}"
  local -a crypto_args=()
  local LC_ALL=C
  [[ "$-" != *x* && -n "${crypto_pass_ref}" && "${crypto_pass_ref}" != *$'\n'* && "${crypto_pass_ref}" != *$'\r'* ]] || return 1
  (( ${#crypto_pass_ref} <= 1023 )) || return 1
  cntools_message_crypto_arguments_into crypto_args || return 1
  cntools_transaction_log CMD 'openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -md sha256 -salt -a -A (CIP-83 salt=8; stdin and pass fd redacted)'
  crypto_encoded="$(printf '%s' "${crypto_plain_ref}" | openssl enc -e "${crypto_args[@]}" -pass fd:3 3<<< "${crypto_pass_ref}" 2>/dev/null)" || crypto_status=$?
  if (( crypto_status == 0 )); then
    crypto_recovered="$(printf '%s' "${crypto_encoded}" | openssl enc -d "${crypto_args[@]}" -pass fd:3 3<<< "${crypto_pass_ref}" 2>/dev/null)" || crypto_status=$?
  fi
  cntools_transaction_log CMD "CIP-83 local encryption and decryption check status=${crypto_status}"
  (( crypto_status == 0 )) && [[ "${crypto_recovered}" == "${crypto_plain_ref}" && "${crypto_encoded}" == U2FsdGVkX1* ]] || return 1
  crypto_output_ref="${crypto_encoded}"
  unset crypto_recovered
}
