#!/usr/bin/env bash
# Frozen metadata inputs. Imported numeric literals never pass through jq output.
# shellcheck disable=SC2034
CNTOOLS_METADATA_CUSTOM=""
CNTOOLS_METADATA_MESSAGE=""
CNTOOLS_METADATA_SCHEMA=simple
CNTOOLS_METADATA_MODE=none
CNTOOLS_METADATA_ERROR=""

cntools_metadata_fail() { CNTOOLS_METADATA_ERROR="$1"; return 1; }
cntools_metadata_reset() {
  CNTOOLS_METADATA_CUSTOM=""; CNTOOLS_METADATA_MESSAGE=""
  CNTOOLS_METADATA_SCHEMA=simple; CNTOOLS_METADATA_MODE=none; CNTOOLS_METADATA_ERROR=""
}

# jq validates JSON syntax first. This small lexical walk additionally rejects
# duplicate object keys (including escaped aliases), unsafe numeric spellings and
# excessive nesting, without converting metadata integers to floating point.
# Cursor/text are dynamically scoped to the validation invocation.
cntools_metadata_space() {
  while [[ "${md_text:md_pos:1}" == [$' \t\r\n'] ]]; do md_pos=$((md_pos+1)); done
}
cntools_metadata_string() {
  local start=$md_pos
  md_pos=$((md_pos+1))
  while (( md_pos < ${#md_text} )); do
    case "${md_text:md_pos:1}" in
      '"') md_pos=$((md_pos+1)); md_token="${md_text:start:md_pos-start}"; return 0 ;;
      \\) md_pos=$((md_pos+2)) ;;
      *) md_pos=$((md_pos+1)) ;;
    esac
  done
  return 1
}
cntools_metadata_value() {
  local depth="${1:-0}" key="" token="" start=0 magnitude="" field="" index=0
  local path="${2:-$}"
  local -A keys=()
  md_nodes=$((md_nodes+1))
  (( depth <= 32 && md_nodes <= 4096 )) || return 1
  cntools_metadata_space
  case "${md_text:md_pos:1}" in
    '{')
      md_pos=$((md_pos+1)); cntools_metadata_space
      if [[ "${md_text:md_pos:1}" == '}' ]]; then
        md_pos=$((md_pos+1)); cntools_metadata_leaf "${path}" '{}'; return 0
      fi
      while true; do
        cntools_metadata_string || return 1
        # Base64 gives every decoded key a nonempty, shell-safe identity. No NUL
        # or newline can disappear in command substitution and mask duplicates.
        key="$(printf '%s' "${md_token}" | jq -r '@base64')" || return 1
        [[ -z "${keys[k${key}]+x}" ]] || return 1
        keys["k${key}"]=1
        field="${md_token}"
        if (( depth == 0 )); then
          token="$(printf '%s' "${md_token}" | jq -r '.')"
          [[ "${token}" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
          cntools_uint_greater_equal 18446744073709551615 "${token}" || return 1
          [[ "${token}" != 674 ]] || md_has_message=Y
        fi
        cntools_metadata_space; md_pos=$((md_pos+1)) # colon, checked by jq
        cntools_metadata_value "$((depth+1))" "${path}[${field}]" || return 1
        cntools_metadata_space
        if [[ "${md_text:md_pos:1}" == '}' ]]; then md_pos=$((md_pos+1)); return 0; fi
        md_pos=$((md_pos+1)); cntools_metadata_space
      done ;;
    '[')
      md_pos=$((md_pos+1)); cntools_metadata_space
      if [[ "${md_text:md_pos:1}" == ']' ]]; then
        md_pos=$((md_pos+1)); cntools_metadata_leaf "${path}" '[]'; return 0
      fi
      while true; do
        cntools_metadata_value "$((depth+1))" "${path}[${index}]" || return 1
        index=$((index+1))
        cntools_metadata_space
        if [[ "${md_text:md_pos:1}" == ']' ]]; then md_pos=$((md_pos+1)); return 0; fi
        md_pos=$((md_pos+1))
      done ;;
    '"')
      cntools_metadata_string || return 1
      cntools_metadata_leaf "${path}" "${md_token}"
      ;;
    *)
      start=$md_pos
      while [[ -n "${md_text:md_pos:1}" && "${md_text:md_pos:1}" != [$' \t\r\n,}\]'] ]]; do md_pos=$((md_pos+1)); done
      token="${md_text:start:md_pos-start}"
      [[ "${token}" =~ ^-?(0|[1-9][0-9]*)$ ]] || return 1
      magnitude="${token#-}"
      cntools_uint_greater_equal 18446744073709551615 "${magnitude}" || return 1
      cntools_metadata_leaf "${path}" "${token}"
      ;;
  esac
}

cntools_metadata_leaf() {
  [[ "${md_render:-N}" == Y ]] || return 0
  # Values remain JSON-escaped strings or exact integer lexemes. No terminal
  # controls or floating-point reserialization are introduced in the preview.
  local md_display_path="${1:-}" md_display_value="${2:-}"
  cntools_wallet_sanitize_display_into md_display_path "${md_display_path}" || return 1
  cntools_wallet_sanitize_display_into md_display_value "${md_display_value}" || return 1
  cntools_transaction_ui_styled_row "${md_display_path}" "${md_display_value}" text
}

cntools_metadata_validate_json() {
  local file="${1:-}" md_render="${2:-N}" md_text="" md_pos=0 md_nodes=0 md_token="" md_has_message=N LC_ALL=C
  jq -e -s 'length == 1 and (.[0] | type == "object")' "${file}" >/dev/null 2>&1 ||
    { cntools_metadata_fail 'Metadata must be one JSON object.'; return 1; }
  md_text="$(< "${file}")"
  cntools_metadata_value 0 || {
    cntools_metadata_fail 'Use unique JSON keys, canonical decimal labels, integer literals within the metadata range, at most 32 nested levels and 4096 values (no booleans/null).'; return 1;
  }
  [[ "${md_render}" == Y || "${md_has_message}" != Y || -z "${CNTOOLS_METADATA_MESSAGE}" ]] || {
    cntools_metadata_fail 'The imported file already contains label 674. Remove the current message or that imported label first.'; return 1;
  }
}

cntools_metadata_import() {
  local selected="${1:-}" schema="${2:-simple}" frozen=""
  [[ "${schema}" == simple || "${schema}" == detailed ]] || return 2
  cntools_transaction_snapshot_into frozen "${selected}" 65536 metadata-import || {
    cntools_metadata_fail "${CNTOOLS_TRANSACTION_ERROR:-Could not read a safe metadata file (maximum 64 KiB).}"; return 1;
  }
  cntools_metadata_validate_json "${frozen}" || return 1
  CNTOOLS_METADATA_CUSTOM="${frozen}"; CNTOOLS_METADATA_SCHEMA="${schema}"
  cntools_transaction_log METADATA "Imported frozen ${schema} metadata file=${frozen}; ledger validation occurs when building"
}

# Plaintext arrives on stdin, never through an external command argument.
cntools_metadata_message_json() {
  jq -Rsc '
    def chunks:
      reduce (explode[]) as $cp ({lines:[], text:"", bytes:0};
        ([$cp] | implode) as $char | ($char | utf8bytelength) as $size |
        if .bytes + $size > 64 then .lines += [.text] | .text=$char | .bytes=$size
        else .text += $char | .bytes += $size end) | .lines + [.text];
    split("\n") | map(chunks) | add'
}

cntools_metadata_arguments_into() {
  local -n md_args_ref="$1"
  local wrapper=""
  md_args_ref=()
  [[ -n "${CNTOOLS_METADATA_CUSTOM}" || -n "${CNTOOLS_METADATA_MESSAGE}" ]] || return 0
  if [[ "${CNTOOLS_METADATA_SCHEMA}" == detailed ]]; then
    md_args_ref+=(--json-metadata-detailed-schema)
  else md_args_ref+=(--json-metadata-no-schema); fi
  [[ -z "${CNTOOLS_METADATA_CUSTOM}" ]] || md_args_ref+=(--metadata-json-file "${CNTOOLS_METADATA_CUSTOM}")
  if [[ -n "${CNTOOLS_METADATA_MESSAGE}" ]]; then
    cntools_transaction_temp_file wrapper message-wrapper || return 1
    if [[ "${CNTOOLS_METADATA_SCHEMA}" == detailed ]]; then
      jq '{"674": {map: ([{k:{string:"msg"},v:{list:(.msg | map({string:.}))}}] +
        (if .enc then [{k:{string:"enc"},v:{string:.enc}}] else [] end))}}' "${CNTOOLS_METADATA_MESSAGE}" > "${wrapper}" || return 1
    else
      # No-schema CLI interprets lowercase hex-prefixed strings as bytes.
      jq -e 'all(.msg[]; test("^0x([0-9a-f]{2})*$") | not)' "${CNTOOLS_METADATA_MESSAGE}" >/dev/null || {
        cntools_metadata_fail 'This message needs Detailed JSON to preserve a 0x-prefixed text value. Remove the Simple JSON import or use Detailed JSON.'; return 1;
      }
      jq '{"674":.}' "${CNTOOLS_METADATA_MESSAGE}" > "${wrapper}" || return 1
    fi
    md_args_ref+=(--metadata-json-file "${wrapper}")
  fi
}
