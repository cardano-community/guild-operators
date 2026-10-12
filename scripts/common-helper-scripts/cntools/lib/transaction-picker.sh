#!/usr/bin/env bash
# Read-only transaction discovery. Catalog hints never replace package/witness
# authentication: the existing Sign/Submit loaders validate the selected file.
# shellcheck disable=SC2034
declare -ag CNTOOLS_TRANSACTION_PICKER_FILES=() CNTOOLS_TRANSACTION_PICKER_ROWS=()

cntools_transaction_picker_catalog() {
  local mode="${1:-}" directory="${CNTOOLS_ROOT:-}/.transactions"
  local file="" metadata="" mtime="" sorted="" intent="" network="" progress="" id="" path="" ordinal=0
  local -a records=()
  CNTOOLS_TRANSACTION_PICKER_FILES=(); CNTOOLS_TRANSACTION_PICKER_ROWS=()
  case "${mode}" in sign|submit) ;; *) return 2 ;; esac
  [[ -n "${CNTOOLS_ROOT:-}" && "${CNTOOLS_ROOT}" == /* && "${CNTOOLS_ROOT}" != / ]] || return 0
  [[ -d "${directory}" && ! -L "${directory}" ]] || return 0
  cntools_filesystem_path_components_safe "${directory}" || return 0
  # Generated packages are one directory deep; accept imported JSON files
  # placed directly in .transactions too. Never search wallet/key directories.
  for file in "${directory}/"*.json "${directory}/"*/*.json; do
    cntools_transaction_file_safe "${file}" || continue
    cntools_filesystem_mtime_into mtime "${file}" || continue
    metadata="$(jq -ers --arg schema "${CNTOOLS_TRANSACTION_SCHEMA}" --arg mode "${mode}" '
      def clean: type=="string" and length>0 and length<=80 and (test("[\u0000-\u001f\u007f-\u009f]")|not);
      select(length==1) | .[0] |
      select(type=="object" and .schema==$schema and
        (.intent.kind|clean) and (.network.name|IN("mainnet","preview","preprod","guild")) and
        (.transaction.id|type=="string" and test("^[0-9a-f]{64}$")) and
        (.signing.required|type=="array" and length<=128) and
        (.signing.witnesses|type=="array" and length<=128)) |
      (.signing.required|length) as $required | (.signing.witnesses|length) as $witnesses |
      select(if $mode=="sign" then .signedTransaction==null and $witnesses<$required
             else (.signedTransaction|type=="object") end) |
      [.intent.kind,.network.name,
       (if $mode=="submit" then "Signed package" elif $witnesses==0 then "Unsigned"
        else "Partially signed" end) + " · " + ($witnesses|tostring) + "/" + ($required|tostring),
       .transaction.id[0:12]] | @tsv' "${file}" 2>/dev/null)" || continue
    records+=("${mtime}"$'\t'"${metadata}"$'\t'"${file}")
  done
  (( ${#records[@]} > 0 )) || return 0
  sorted="$(printf '%s\n' "${records[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr -k6,6)" || return 1
  while IFS=$'\t' read -r mtime intent network progress id path; do
    ordinal=$((ordinal+1))
    CNTOOLS_TRANSACTION_PICKER_FILES+=("${path}")
    CNTOOLS_TRANSACTION_PICKER_ROWS+=("${ordinal} · ${intent} · ${network} · ${progress} · ${id} · ${path#"${directory}/"}")
  done <<< "${sorted}"
  cntools_transaction_log CHOICE "Saved transaction discovery mode=${mode} count=${#CNTOOLS_TRANSACTION_PICKER_FILES[@]}"
}

cntools_transaction_picker_begin() {
  case "$1" in
    sign) cntools_transaction_ui_sign_begin ;;
    submit) cntools_transaction_ui_submit_begin ;;
    *) return 2 ;;
  esac
}

cntools_transaction_picker_into() {
  local output_name="${1:-}" mode="${2:-}" feedback="${3:-}" method="" chosen="" status=0 index=0
  local start="${CNTOOLS_ROOT:-}" picker_input="" width=""
  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  case "${mode}" in sign|submit) ;; *) return 2 ;; esac
  local -n picker_result="${output_name}"
  picker_result=""
  [[ ! -d "${start}/.transactions" || -L "${start}/.transactions" ]] || start="${start}/.transactions"
  width="$(cntools_ui_content_width 100 42)" || return 2
  while true; do
    cntools_transaction_picker_begin "${mode}" || return 2
    if [[ "${mode}" == sign ]]; then
      cntools_ui_render_status info 'Choose an unsigned or partially signed CNTools package. Arbitrary transaction bodies are not accepted: the intended signer set must be verifiable. Saved-list names and signing progress are hints; the selected file is fully validated.' "$((width - 4))" || return 2
    else
      cntools_ui_render_status info 'Choose a signed CNTools package or external signed Cardano envelope. Saved-list labels are hints: packages are fully validated, and external envelopes require final ledger validation.' "$((width - 4))" || return 2
    fi
    [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
    cntools_ui_choose method 'Choose a transaction file' 'Saved CNTools packages' \
      'Browse files' 'Enter file path' Cancel || return $?
    cntools_transaction_log CHOICE "Transaction file selection mode=${mode} method=${method}"
    case "${method}" in
      Cancel) return 1 ;;
      'Saved CNTools packages')
        cntools_transaction_picker_begin "${mode}" || return 2
        cntools_ui_spin_function 'Finding saved transaction packages…' \
          cntools_transaction_picker_catalog "${mode}" || return 2
        if (( ${#CNTOOLS_TRANSACTION_PICKER_FILES[@]} == 0 )); then
          feedback='No matching saved packages found. Use Browse files or Enter file path for imported files.'
        else
          status=0
          cntools_ui_choose chosen 'Saved packages · newest first · type to filter' "${CNTOOLS_TRANSACTION_PICKER_ROWS[@]}" Back || status=$?
          (( status == 0 || status == 1 )) || return "${status}"
          if (( status == 0 )) && [[ "${chosen}" != Back ]]; then
            for index in "${!CNTOOLS_TRANSACTION_PICKER_ROWS[@]}"; do
              [[ "${chosen}" == "${CNTOOLS_TRANSACTION_PICKER_ROWS[index]}" ]] || continue
              picker_result="${CNTOOLS_TRANSACTION_PICKER_FILES[index]}"; return 0
            done
            return 2
          fi
        fi
        ;;
      'Browse files')
        status=0
        cntools_ui_file picker_input "${start}" "cntools_transaction_ui_${mode}_begin" file N || status=$?
        (( status == 0 || status == 1 )) || return "${status}"
        if (( status == 0 )); then picker_result="${picker_input}"; return 0; fi
        cntools_transaction_log CHOICE 'Transaction file browser cancelled'
        ;;
      'Enter file path')
        status=0
        cntools_ui_input picker_input 'Transaction file path' "${start}/transaction.json" || status=$?
        (( status == 0 || status == 1 )) || return "${status}"
        if (( status == 0 )) && [[ -n "${picker_input}" ]]; then
          picker_result="${picker_input}"; return 0
        fi
        cntools_transaction_log CHOICE 'Manual transaction file selection cancelled'
        ;;
      *) return 2 ;;
    esac
  done
}
