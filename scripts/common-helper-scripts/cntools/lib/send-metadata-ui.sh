#!/usr/bin/env bash
# Optional Send metadata controls. Only ciphertext survives encrypted entry.

cntools_send_metadata_render() {
  local line="" widths=""
  [[ -n "${CNTOOLS_METADATA_MESSAGE}" || -n "${CNTOOLS_METADATA_CUSTOM}" ]] || return 0
  cntools_transaction_ui_table_widths_into widths 20 || return 1
  {
    printf 'Metadata\tContent\n'
    if [[ "${CNTOOLS_METADATA_MODE}" == basic* ]]; then
      cntools_transaction_ui_styled_row Message "Encrypted (CIP-83) · ${CNTOOLS_METADATA_MODE#basic-}" identifier
    elif [[ -n "${CNTOOLS_METADATA_MESSAGE}" ]]; then
      while IFS= read -r line; do
        cntools_wallet_sanitize_display_into line "${line}" || return 1
        cntools_transaction_ui_styled_row Message "${line}" text
      done < <(jq -r '.msg[]' "${CNTOOLS_METADATA_MESSAGE}")
    fi
    if [[ -n "${CNTOOLS_METADATA_CUSTOM}" ]]; then
      cntools_transaction_ui_styled_row Import "${CNTOOLS_METADATA_SCHEMA} JSON · exact values" identifier
      cntools_metadata_validate_json "${CNTOOLS_METADATA_CUSTOM}" Y || return 1
    fi
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
}

cntools_send_metadata_message() {
  local entered="" plain_json="" passphrase="" confirmation="" encrypted="" frozen=""
  local protection="" password_kind="" status=0
  if [[ -n "${CNTOOLS_METADATA_CUSTOM}" ]] && jq -e 'has("674")' "${CNTOOLS_METADATA_CUSTOM}" >/dev/null; then
    cntools_metadata_fail 'The custom import owns label 674. Remove that import before adding a message.'; return 2
  fi
  cntools_send_choose protection 'Message protection' 'Plain (CIP-20)' 'Encrypted (CIP-83)' || return $?
  cntools_ui_render_status warn 'Metadata is permanent. Encryption hides only the message, not addresses, amounts or other metadata.'
  entered="$(cntools_gum write --char-limit 4096 --height 5 --width "$(cntools_gum_width)" \
    --prompt.foreground "${CNTOOLS_GUM_COLOR_BRAND}" --cursor.foreground "${CNTOOLS_GUM_COLOR_BRAND}" \
    --placeholder.foreground "${CNTOOLS_GUM_COLOR_MUTED}" --placeholder 'Transaction message (Ctrl+D to finish)')" || return $?
  [[ -n "${entered}" ]] || return 0
  plain_json="$(printf '%s' "${entered}" | cntools_metadata_message_json)" || return 2
  if [[ "${protection}" == 'Encrypted (CIP-83)' ]]; then
    cntools_send_choose password_kind 'Encryption passphrase' 'Custom shared passphrase' 'Public passphrase (anyone can decrypt)' || return $?
    if [[ "${password_kind}" == 'Custom shared passphrase' ]]; then
      cntools_ui_render_status info 'Use a strong unique passphrase and share it separately with the recipient. This is not your wallet password.'
      cntools_ui_password passphrase 'Message passphrase' || return $?
      [[ -n "${passphrase}" ]] || { cntools_metadata_fail 'A custom passphrase cannot be empty.'; return 2; }
      if ! (LC_ALL=C; (( ${#passphrase} <= 1023 )) && [[ "${passphrase}" != *$'\n'* && "${passphrase}" != *$'\r'* ]]); then
        cntools_metadata_fail 'Use a single-line passphrase of at most 1023 UTF-8 bytes.'; return 2
      fi
      cntools_ui_password confirmation 'Confirm message passphrase' || return $?
      [[ "${passphrase}" == "${confirmation}" ]] || { cntools_metadata_fail 'Message passphrases do not match.'; return 2; }
    else
      cntools_send_confirm 'The public passphrase cardano provides no confidentiality. Continue?' || return $?
      passphrase=cardano
    fi
    cntools_message_encrypt_into encrypted plain_json passphrase || {
      cntools_metadata_fail 'CIP-83 encryption failed. OpenSSL with PBKDF2 and the compatible salt format is required.'; return 2;
    }
    unset passphrase confirmation
    # Clear the transient editor before the persistent ciphertext-only review.
    cntools_send_begin
  fi
  cntools_transaction_temp_file frozen message || return 2
  if [[ "${protection}" == 'Encrypted (CIP-83)' ]]; then
    printf '%s' "${encrypted}" | jq -Rsc '{enc:"basic",msg:[scan(".{1,64}")]}' > "${frozen}" || status=2
  else
    printf '%s' "${plain_json}" | jq '{msg:.}' > "${frozen}" || status=2
  fi
  unset entered plain_json encrypted
  (( status == 0 )) || return "${status}"
  CNTOOLS_METADATA_MESSAGE="${frozen}"
  CNTOOLS_METADATA_MODE=plain
  if [[ "${protection}" == 'Encrypted (CIP-83)' ]]; then
    CNTOOLS_METADATA_MODE=basic-custom
    [[ "${password_kind}" != 'Public passphrase (anyone can decrypt)' ]] || CNTOOLS_METADATA_MODE=basic-public
  fi
  [[ -n "${CNTOOLS_METADATA_CUSTOM}" ]] || CNTOOLS_METADATA_SCHEMA=detailed
  cntools_transaction_log METADATA "Message prepared mode=${CNTOOLS_METADATA_MODE}; content redacted"
}

cntools_send_metadata_edit_inner() {
  local choice="" path="" format="" status=0
  local -a options=()
  while true; do
    CNTOOLS_METADATA_ERROR=""
    cntools_send_metadata_render || return 2
    options=('Done' 'Add / replace message' 'Remove message')
    [[ "${CNTOOLS_ADVANCED:-N}" != Y ]] || options+=('Import custom metadata')
    [[ -z "${CNTOOLS_METADATA_CUSTOM}" ]] || options+=('Remove custom metadata')
    cntools_send_choose choice 'Message / metadata' "${options[@]}" || return $?
    status=0
    case "${choice}" in
      Done) return 0 ;;
      'Add / replace message') cntools_send_metadata_message || status=$? ;;
      'Remove message') CNTOOLS_METADATA_MESSAGE=""; CNTOOLS_METADATA_MODE=none ;;
      'Remove custom metadata') CNTOOLS_METADATA_CUSTOM=""; CNTOOLS_METADATA_SCHEMA=detailed ;;
      'Import custom metadata')
        cntools_ui_input path 'Metadata JSON file' '' || return $?
        cntools_send_choose format 'Metadata JSON format' 'Simple JSON' 'Detailed JSON' || return $?
        format="${format%% *}"
        cntools_metadata_import "${path}" "${format,,}" || status=2
        ;;
    esac
    # Failed edits leave the previous frozen draft in place.
    if (( status != 0 )); then
      cntools_ui_render_status warn "${CNTOOLS_METADATA_ERROR:-Metadata edit cancelled; previous draft retained.}"
    fi
  done
}

cntools_send_metadata_edit() {
  local traced=N result=0
  case "$-" in *x*) traced=Y; set +x ;; esac
  cntools_send_metadata_edit_inner || result=$?
  [[ "${traced}" != Y ]] || set -x
  return "${result}"
}
