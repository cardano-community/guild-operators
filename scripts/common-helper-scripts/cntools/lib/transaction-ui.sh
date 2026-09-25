#!/usr/bin/env bash
# Gum interaction and presentation for shared transaction signing/submission.
# Loaded after transaction.sh and the action-specific transaction library.
# shellcheck disable=SC2034

CNTOOLS_TRANSACTION_UI_VIEW=""
CNTOOLS_TRANSACTION_UI_SOURCE_FILE=""

cntools_transaction_ui_log() {
  cntools_transaction_log "${1:-INFO}" "${2:-}" || true
}

# Shared transaction UX. Actions keep their own validation/building, but use
# these workflow, review and result components (see README's transaction contract).
cntools_transaction_ui_workflow_into() {
  local output_name="$1" can_sign="$2" workflow_selection="" status=0
  local -a options=('Create unsigned package')
  [[ "${can_sign}" != Y ]] || options=('Create, sign and submit' 'Create and sign' 'Create unsigned package')
  cntools_ui_choose workflow_selection Workflow "${options[@]}" Cancel || status=$?
  (( status == 0 )) || return "${status}"
  [[ "${workflow_selection}" != Cancel ]] || return 1
  printf -v "${output_name}" '%s' "${workflow_selection}"
  cntools_transaction_log CHOICE "Transaction workflow selected=${workflow_selection}"
}

cntools_transaction_ui_proceed_into() {
  case "$2" in
    'Create, sign and submit') printf -v "$1" '%s' 'Continue to sign & submit' ;;
    'Create and sign') printf -v "$1" '%s' 'Continue to sign' ;;
    'Create unsigned package') printf -v "$1" '%s' 'Save unsigned package' ;;
    *) return 2 ;;
  esac
}

cntools_transaction_ui_expiry_into() {
  local expiry_choice="" expiry_seconds="" status=0
  cntools_ui_choose expiry_choice 'Transaction expiry' '30 minutes' '2 hours' \
    '24 hours (offline signing)' 'No expiry' Cancel || status=$?
  (( status == 0 )) || return "${status}"
  case "${expiry_choice}" in
    '30 minutes') expiry_seconds=1800 ;;
    '2 hours') expiry_seconds=7200 ;;
    '24 hours (offline signing)') expiry_seconds=86400 ;;
    'No expiry') expiry_seconds=0 ;;
    Cancel) return 1 ;;
    *) return 2 ;;
  esac
  printf -v "$1" '%s' "${expiry_seconds}"
  cntools_transaction_log CHOICE "Transaction expiry selected=${expiry_choice}"
}

cntools_transaction_ui_expiry_label_into() {
  if [[ -z "${2:-}" ]]; then
    printf -v "$1" '%s' 'No expiry'
  else
    cntools_slot_datetime_into "$1" "$2" || printf -v "$1" '%s' 'Date unavailable'
  fi
}

cntools_transaction_ui_fee_into() {
  local fee_value=""
  fee_value="$(jq -er '.fee | tostring | split(" ")[0] | select(test("^[0-9]+$"))' <<< "${CNTOOLS_TRANSACTION_UI_VIEW}")" || return 1
  printf -v "$1" '%s' "${fee_value}"
}

# Rendering callbacks take no arguments. No signing occurs here. Returning a
# change option lets the action rebuild and validate before another review.
cntools_transaction_ui_review_into() {
  local output_name="$1" package="$2" proceed="$3" begin="$4" render="$5"
  local review_selection="" status=0 summary="" allowed=""
  shift 5
  if [[ -n "${package}" ]]; then
    cntools_transaction_package_load "${package}" || return 2
    package="${CNTOOLS_TRANSACTION_PACKAGE_FILE}"
    cntools_transaction_view_into CNTOOLS_TRANSACTION_UI_VIEW "${CNTOOLS_TRANSACTION_BODY_FILE}" || return 2
    summary="$(jq -c '.intent.summary' "${package}")" || return 2
    cntools_transaction_log REVIEW "Transaction intent summary=${summary}"
    cntools_transaction_log REVIEW "Transaction package details=$(jq -c '{network, intent, validity, signing: {assurance: .signing.assurance, nativeScripts: .signing.nativeScripts}}' "${package}")"
  fi
  cntools_transaction_log REVIEW "Decoded transaction=${CNTOOLS_TRANSACTION_UI_VIEW}"
  while true; do
    "${begin}" || return 2
    "${render}" || return 2
    local -a options=("${proceed}" 'Show decoded transaction')
    [[ -z "${package}" ]] || options+=('Show required signers')
    cntools_ui_choose review_selection 'Review transaction' "${options[@]}" "$@" Cancel || { status=$?; return "${status}"; }
    cntools_transaction_log CHOICE "Transaction review selected=${review_selection}"
    case "${review_selection}" in
      'Show decoded transaction')
        "${begin}" || return 2
        cntools_transaction_ui_render_json 'Decoded transaction · authoritative' "${CNTOOLS_TRANSACTION_UI_VIEW}" || return 2
        cntools_ui_wait ;;
      'Show required signers')
        "${begin}" || return 2
        cntools_transaction_ui_render_signer_progress "${package}" || return 2
        cntools_ui_wait ;;
      Cancel) return 1 ;;
      *)
        for allowed in "${proceed}" "$@"; do
          if [[ "${review_selection}" == "${allowed}" ]]; then
            printf -v "${output_name}" '%s' "${review_selection}"
            return 0
          fi
        done
        return 2 ;;
    esac
  done
}

cntools_transaction_ui_render_policy_rows() {
  cntools_transaction_ui_styled_row 'Input selection' "$1 · $(cntools_number_format "$2") inputs" value
  cntools_transaction_ui_styled_row 'Token fragmentation' "${CNTOOLS_CHANGE_TOKEN_STATUS}" value
  cntools_transaction_ui_styled_row 'ADA-only management' "${CNTOOLS_CHANGE_UTXO_STATUS}" value
  cntools_transaction_ui_styled_row 'Collateral candidate' "${CNTOOLS_CHANGE_COLLATERAL_STATUS}" value
}

cntools_transaction_ui_render_result() {
  local state="$1" message="$2" txid="${3:-}" saved="${4:-}" widths=""
  message="${message//[[:cntrl:]]/ }"
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  cntools_ui_render_detail 'Transaction result' || return 1
  {
    printf 'Result\tValue\n'
    cntools_transaction_ui_styled_row Status "${message}" "${state}"
    [[ -z "${txid}" ]] || cntools_transaction_ui_styled_row 'Transaction ID' "${txid}" identifier
    [[ -z "${saved}" ]] || cntools_transaction_ui_styled_row 'Saved package' "${saved}" identifier
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
}

cntools_transaction_ui_confirm_submit() {
  local label="" status=0
  case "$1" in local) label='local node' ;; koios) label=Koios ;; *) return 2 ;; esac
  cntools_ui_confirm "Submit this signed transaction using ${label}?" true || status=$?
  cntools_transaction_log CHOICE "Transaction submission confirmation backend=$1 status=${status}"
  return "${status}"
}

cntools_transaction_ui_log_path() {
  local event="${1:-path selected}"
  local path="${2:-}"
  local rendered=""

  if declare -F cntools_log_render_argument >/dev/null 2>&1; then
    rendered="$(cntools_log_render_argument "${path}")" || rendered="<unavailable>"
  else
    printf -v rendered '%q' "${path}"
  fi
  cntools_transaction_ui_log CHOICE "${event} path=${rendered}"
}

cntools_transaction_ui_cancel() {
  cntools_transaction_ui_log CHOICE "${1:-transaction action cancelled}"
  cntools_gum_clear
}

cntools_transaction_ui_table_widths_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_label_width="${2:-22}"
  local _cntools_table_width=""
  local _cntools_value_width=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_label_width}" =~ ^[1-9][0-9]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_table_width="$(cntools_ui_content_width 220 54)" || return 1
  _cntools_value_width=$((_cntools_table_width - _cntools_label_width - 7))
  (( _cntools_value_width >= 18 )) || return 1
  _cntools_output_ref="${_cntools_label_width},${_cntools_value_width}"
}

cntools_transaction_ui_signer_widths_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_table_width=""
  local _cntools_value_width=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_table_width="$(cntools_ui_content_width 220 66)" || return 1
  _cntools_value_width=$((_cntools_table_width - 43))
  (( _cntools_value_width >= 23 )) || return 1
  _cntools_output_ref="18,18,${_cntools_value_width}"
}

cntools_transaction_ui_styled_row() {
  local label="${1:-}"
  local value="${2:-}"
  local role="${3:-value}"
  local styled=""

  label="${label//[[:cntrl:]]/ }"
  value="${value//[[:cntrl:]]/ }"
  cntools_theme_style_value_into styled "${role}" "${value}" || return 1
  printf '%s\t%s\n' "${label}" "${styled}"
}

cntools_transaction_ui_styled_signer_row() {
  local signer="${1:-}"
  local property="${2:-}"
  local value="${3:-}"
  local role="${4:-value}"
  local styled=""

  cntools_theme_style_value_into styled "${role}" "${value}" || return 1
  printf '%s\t%s\t%s\n' "${signer}" "${property}" "${styled}"
}

cntools_transaction_ui_render_json() {
  local heading="${1:-Decoded transaction}"
  local value="${2:-}"
  local formatted=""
  local width=""

  # The CLI already formats its authoritative view. Re-encoding it with jq can
  # round metadata integers beyond 2^53 on deployed jq versions.
  jq -e 'type == "object" or type == "array"' <<< "${value}" >/dev/null 2>&1 || return 1
  formatted="${value}"
  [[ -n "${formatted}" ]] || return 1
  width="$(cntools_ui_content_width 220 54)" || return 1
  cntools_ui_render_detail "${heading}" || return 1
  printf '%s\n' "${formatted}" | cntools_gum style \
    --margin "0 2 1 2" --padding "0 1" --border normal \
    --width "${width}" \
    --border-foreground "${CNTOOLS_GUM_COLOR_DIVIDER}" \
    --foreground "${CNTOOLS_GUM_COLOR_TEXT}"
}

cntools_transaction_ui_render_package_overview() {
  local widths="" expiry_label="No expiry" fee=""
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  if [[ -n "${CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER:-}" ]]; then
    cntools_slot_datetime_into expiry_label "${CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER}" || expiry_label='Date unavailable'
  fi
  cntools_ui_render_detail 'Transaction information' || return 1
  {
    printf 'Property\tValue\n'
    cntools_transaction_ui_styled_row 'Transaction ID' "${CNTOOLS_TRANSACTION_ID}" identifier
    if cntools_transaction_ui_fee_into fee; then
      cntools_transaction_ui_styled_row Fee "$(cntools_number_format_units "${fee}" 6) ADA" number
    fi
    cntools_transaction_ui_styled_row Signatures "${CNTOOLS_TRANSACTION_WITNESS_COUNT}/${CNTOOLS_TRANSACTION_REQUIRED_COUNT} collected" number
    cntools_transaction_ui_styled_row Expires "${expiry_label}" number
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  if [[ "${CNTOOLS_TRANSACTION_PACKAGE_ASSURANCE}" == manual ]]; then
    cntools_ui_render_status warn 'Reference script contents need independent verification against the original script and reference input before signing.'
  fi
}

cntools_transaction_ui_render_signer_progress() {
  local package_file="${1:-}"
  local record=""
  local labels=""
  local roles=""
  local preferred=""
  local hardware_group=""
  local key_id=""
  local state=""
  local signer=""
  local state_role="warning"
  local widths=""
  local index=0

  cntools_transaction_ui_signer_widths_into widths || return 1
  cntools_ui_render_detail "Required signers" || return 1
  {
    printf 'Signer\tProperty\tValue\n'
    while IFS= read -r record; do
      IFS=$'\037' read -r labels roles preferred hardware_group key_id state \
        <<< "${record}"
      index=$((index + 1))
      printf -v signer '%02d · %s' "${index}" "${labels}"
      state_role="warning"
      [[ "${state}" != "Signed" ]] || state_role="success"
      cntools_transaction_ui_styled_signer_row \
        "${signer}" "Status" "${state}" "${state_role}"
      cntools_transaction_ui_styled_signer_row "" "Roles" "${roles}" value
      cntools_transaction_ui_styled_signer_row \
        "" "Signing method" "${preferred}" accent
      if [[ -n "${hardware_group}" ]]; then
        cntools_transaction_ui_styled_signer_row \
          "" "Hardware session" "${hardware_group}" identifier
      fi
      cntools_transaction_ui_styled_signer_row \
        "" "Public key ID" "${key_id}" credential
    done < <(jq -r '
      . as $package |
      $package.signing.required[] |
      . as $signer |
      [(.labels | join(", ")), (.roles | join(", ")),
       .preferredKind, (.hardwareGroup // ""), .keyId,
       (if any($package.signing.witnesses[]; .keyId == $signer.keyId)
        then "Signed" else "Missing" end)] | join("\u001f")
    ' "${package_file}")
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
}

cntools_transaction_ui_render_change_plan() {
  local package_file="${1:-}"
  local count=""
  local record=""
  local labels=""
  local hardware_group=""
  local key_id=""
  local reference=""
  local widths=""
  local index=0

  count="$(jq -r '.signing.changeKeys | length' "${package_file}")" || return 1
  (( count > 0 )) || return 0
  cntools_transaction_ui_signer_widths_into widths || return 1
  cntools_ui_render_detail "Hardware change references" || return 1
  {
    printf 'Reference\tProperty\tValue\n'
    while IFS= read -r record; do
      IFS=$'\037' read -r labels hardware_group key_id <<< "${record}"
      index=$((index + 1))
      printf -v reference '%02d · %s' "${index}" "${labels}"
      cntools_transaction_ui_styled_signer_row \
        "${reference}" "Hardware session" "${hardware_group}" identifier
      cntools_transaction_ui_styled_signer_row \
        "" "Public key ID" "${key_id}" credential
    done < <(jq -r '.signing.changeKeys[] |
      [(.labels | join(", ")), .hardwareGroup, .keyId] | join("\u001f")' \
      "${package_file}")
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
}

cntools_transaction_ui_render_native_scripts() {
  local package_file="${1:-}"
  local count=""
  local record=""
  local label=""
  local purpose=""
  local source=""
  local script_hash=""
  local reference_input=""
  local signer_record=""
  local signer_labels=""
  local signer_key_id=""
  local declared_script=""
  local script=""
  local widths=""
  local index=0

  count="$(jq -r '.signing.nativeScripts | length' "${package_file}")" ||
    return 1
  (( count > 0 )) || return 0
  cntools_transaction_ui_signer_widths_into widths || return 1
  cntools_ui_render_detail "Native scripts" || return 1
  {
    printf 'Script\tProperty\tValue\n'
    while IFS= read -r record; do
      IFS=$'\037' read -r label purpose source script_hash reference_input \
        <<< "${record}"
      index=$((index + 1))
      printf -v script '%02d · %s' "${index}" "${label}"
      cntools_transaction_ui_styled_signer_row \
        "${script}" "Purpose" "${purpose}" accent
      cntools_transaction_ui_styled_signer_row \
        "" "Source" "${source}" value
      cntools_transaction_ui_styled_signer_row \
        "" "Script hash" "${script_hash}" credential
      if [[ -n "${reference_input}" ]]; then
        cntools_transaction_ui_styled_signer_row \
          "" "Reference input" "${reference_input}" identifier
      fi
      while IFS= read -r signer_record; do
        IFS=$'\037' read -r signer_labels signer_key_id <<< "${signer_record}"
        cntools_transaction_ui_styled_signer_row \
          "" "Selected signer" "${signer_labels}" value
        cntools_transaction_ui_styled_signer_row \
          "" "Signer key ID" "${signer_key_id}" credential
      done < <(jq -r --argjson script_index "$((index - 1))" '
        . as $package |
        $package.signing.nativeScripts[$script_index].selectedKeyIds[] as $id |
        $package.signing.required[] |
        select(.keyId == $id) |
        [(.labels | join(", ")), .keyId] | join("\u001f")
      ' "${package_file}")
    done < <(jq -r '.signing.nativeScripts[] |
      [.label, .purpose, .source, .scriptHash, (.referenceInput // "")] |
      join("\u001f")' "${package_file}")
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1

  while IFS=$'\037' read -r label declared_script; do
    cntools_transaction_ui_render_json \
      "Declared reference script · ${label}" "${declared_script}" || return 1
  done < <(jq -r '.signing.nativeScripts[] |
    select(.source == "reference") | [.label, (.script | tojson)] |
    join("\u001f")' "${package_file}")
}

cntools_transaction_ui_render_package_review() {
  cntools_transaction_ui_render_package_overview "${CNTOOLS_TRANSACTION_PACKAGE_FILE}" || return 1
  cntools_transaction_ui_render_effects
}

# Imported transactions have no trusted action-local summary. Show ledger
# effects from the authoritative decode, never from the package's intent JSON.
cntools_transaction_ui_render_effects() {
  local rows="" label="" value="" role="" widths=""
  cntools_transaction_ui_table_widths_into widths 28 || return 1
  rows="$(jq -r '
    {Outputs:(.outputs // [] | map({Address:.address, Amount:.amount} +
       (if .datum != null or .["datum hash"] != null then {Datum:"Attached · see decoded transaction"} else {} end) +
       (if .["reference script"] != null then {Script:"Attached · see decoded transaction"} else {} end))),
     Withdrawals:.withdrawals, Certificates:.certificates,
     Mint:.mint, Governance:.["governance actions"], Votes:.votes,
     Donation:.["treasury donation"],
     Metadata:(if .metadata != null then "Attached · see decoded transaction" else null end)}
    | with_entries(select(.value != null and .value != [] and .value != {}))
    | paths(scalars) as $p | getpath($p) as $v
    | [($p | map(if type == "number" then (. + 1 | tostring) else . end) | join(" / ")),
       (if ($v|type) == "number" and ($v > 9007199254740991 or $v < -9007199254740991)
        then "Large integer · see exact decoded transaction" else ($v|tostring) end)]
    | @tsv' <<< "${CNTOOLS_TRANSACTION_UI_VIEW}")" || return 1
  [[ -n "${rows}" ]] || return 0
  cntools_ui_render_detail 'Transaction effects' || return 1
  {
    printf 'Effect\tValue\n'
    while IFS=$'\t' read -r label value; do
      role=value
      case "${value}" in addr*|stake*) role=address ;; esac
      if [[ "${value}" =~ ^[0-9]+$ ]]; then
        if [[ "${label}" == *' / lovelace' ]]; then
          label="${label% / lovelace} / ADA"
          value="$(cntools_number_format_units "${value}" 6) ADA" || return 1
        else
          value="$(cntools_number_format "${value}")" || return 1
        fi
        role=number
      fi
      cntools_transaction_ui_styled_row "${label}" "${value}" "${role}"
    done <<< "${rows}"
  } | cntools_ui_table --separator $'\t' --widths "${widths}"
}

cntools_transaction_ui_sign_begin() { cntools_ui_action_begin Sign '/ Transaction / Sign'; }
cntools_transaction_ui_submit_begin() { cntools_ui_action_begin Submit '/ Transaction / Submit'; }


cntools_transaction_ui_normalize_path_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_input="${2:-}"
  local _cntools_normalized=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_transaction_input_path_into \
    _cntools_normalized "${_cntools_input}" || return 1
  _cntools_output_ref="${_cntools_normalized}"
}

cntools_transaction_ui_prompt_package_into() {
  local _cntools_output_name="${1:-}"
  local feedback=""
  local entered=""
  local normalized=""
  local status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  while true; do
    cntools_ui_action_begin "Sign" "/ Transaction / Sign"
    cntools_ui_render_status info \
      "Select a CNTools transaction package. Arbitrary unsigned transaction bodies are not accepted because their intended signer set cannot be verified safely."
    [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
    if cntools_ui_input entered "Transaction package" "${PWD}/transaction.json"; then
      status=0
    else
      status=$?
    fi
    (( status == 0 )) || return "${status}"
    if ! cntools_transaction_ui_normalize_path_into normalized "${entered}"; then
      cntools_transaction_ui_log CHOICE \
        "invalid transaction package path rejected"
      feedback="Enter an existing package path whose parent directory can be resolved safely."
      continue
    fi
    if cntools_ui_spin_function \
        "Validating transaction package…" \
        cntools_transaction_package_load "${normalized}"; then
      status=0
    else
      status=$?
    fi
    if (( status == 1 )); then
      cntools_transaction_ui_log_path \
        "invalid transaction package rejected" "${normalized}"
      feedback="${CNTOOLS_TRANSACTION_ERROR:-The selected file is not a valid CNTools transaction package.}"
      continue
    elif (( status != 0 )); then
      return "${status}"
    fi
    CNTOOLS_TRANSACTION_UI_SOURCE_FILE="${normalized}"
    _cntools_output_ref="${CNTOOLS_TRANSACTION_PACKAGE_FILE}"
    cntools_transaction_ui_log_path \
      "transaction package selected id=${CNTOOLS_TRANSACTION_ID}" "${normalized}"
    return 0
  done
}

cntools_transaction_ui_prompt_signer_into() {
  local _cntools_output_name="${1:-}"
  local expected_key_id="${2:-}"
  local labels="${3:-Signer}"
  local preferred="${4:-either}"
  local hardware_group="${5:-}"
  local allow_defer="${6:-Y}"
  local feedback=""
  local entered=""
  local normalized=""
  local actual_key_id=""
  local kind=""
  local status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${expected_key_id}" =~ ^[0-9a-f]{64}$ ]] || return 2
  case "${allow_defer}" in Y|N) ;; *) return 2 ;; esac
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  while true; do
    cntools_ui_action_begin "Sign" "/ Transaction / Sign"
    if [[ -n "${hardware_group}" && "${allow_defer}" == "Y" ]]; then
      cntools_ui_render_status info \
        "Hardware session ${hardware_group} must collect every missing group witness together. Select the HWS file for ${labels} to begin, or leave it blank to defer the entire session."
    elif [[ -n "${hardware_group}" ]]; then
      cntools_ui_render_status info \
        "Hardware session ${hardware_group} is selected and must be completed now. Provide the HWS file for ${labels}; every missing group witness is collected in the same device session."
    else
      cntools_ui_render_status info \
        "Provide the private signing key or hardware signing file for ${labels}. Leave it blank to collect this signature on another CNTools system."
    fi
    {
      printf 'Signing source\tValue\n'
      cntools_transaction_ui_styled_row Signer "${labels}" identifier
      cntools_transaction_ui_styled_row Method "${preferred}" accent
    } | cntools_ui_table --separator $'\t' || return 1
    [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
    if cntools_ui_input entered "Signing key / HWS path"; then
      status=0
    else
      status=$?
    fi
    (( status == 0 )) || return "${status}"
    if [[ -z "${entered}" ]]; then
      if [[ -n "${hardware_group}" && "${allow_defer}" == "N" ]]; then
        cntools_transaction_ui_log CHOICE \
          "required hardware group signer omitted id=${expected_key_id} group=${hardware_group}"
        feedback="Hardware session ${hardware_group} is already selected. Choose this HWS file, or press Esc to cancel signing."
        continue
      fi
      cntools_transaction_ui_log CHOICE \
        "signer deferred id=${expected_key_id}"
      return 0
    fi
    if ! cntools_transaction_ui_normalize_path_into normalized "${entered}" ||
       ! cntools_transaction_source_kind_into kind "${normalized}"; then
      cntools_transaction_ui_log CHOICE \
        "invalid signing source rejected id=${expected_key_id}"
      feedback="Select an owned private signing key or HWS file with private permissions."
      continue
    fi
    if [[ "${preferred}" != "either" && "${preferred}" != "${kind}" ]]; then
      cntools_transaction_ui_log CHOICE \
        "signing source kind rejected id=${expected_key_id} required=${preferred} actual=${kind}"
      feedback="This signer requires ${preferred}; the selected file is ${kind}."
      continue
    fi
    if ! cntools_transaction_source_key_id_into actual_key_id "${normalized}"; then
      cntools_transaction_ui_log_path \
        "unidentified signing source rejected id=${expected_key_id}" \
        "${normalized}"
      feedback="${CNTOOLS_TRANSACTION_ERROR:-The selected signing source could not be identified.}"
      continue
    fi
    if [[ "${actual_key_id}" != "${expected_key_id}" ]]; then
      cntools_transaction_ui_log CHOICE \
        "signing source identity rejected expected=${expected_key_id} actual=${actual_key_id}"
      feedback="The selected file belongs to a different public signing key."
      continue
    fi
    _cntools_output_ref="${normalized}"
    cntools_transaction_ui_log_path \
      "signing source selected id=${expected_key_id} kind=${kind}" \
      "${normalized}"
    return 0
  done
}

cntools_transaction_ui_prompt_change_into() {
  local _cntools_output_name="${1:-}"
  local expected_key_id="${2:-}"
  local labels="${3:-Change address}"
  local hardware_group="${4:-}"
  local feedback=""
  local entered=""
  local normalized=""
  local actual_key_id=""
  local kind=""
  local status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${expected_key_id}" =~ ^[0-9a-f]{64}$ &&
     -n "${hardware_group}" ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  while true; do
    cntools_ui_action_begin "Sign" "/ Transaction / Sign"
    cntools_ui_render_status info \
      "Hardware session ${hardware_group} needs its planned change-address reference (${labels}). This HWS file identifies change and does not add another witness."
    {
      printf 'Change reference\tValue\n'
      cntools_transaction_ui_styled_row 'Change address key' "${labels}" identifier
    } | cntools_ui_table --separator $'\t' || return 1
    [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
    if cntools_ui_input entered "Change HWS path"; then
      status=0
    else
      status=$?
    fi
    (( status == 0 )) || return "${status}"
    if [[ -z "${entered}" ]]; then
      cntools_transaction_ui_log CHOICE \
        "required hardware change source omitted id=${expected_key_id} group=${hardware_group}"
      feedback="A change HWS reference is required for this selected hardware session."
      continue
    fi
    if ! cntools_transaction_ui_normalize_path_into normalized "${entered}" ||
       ! cntools_transaction_source_kind_into kind "${normalized}" ||
       [[ "${kind}" != "hardware" ]]; then
      cntools_transaction_ui_log CHOICE \
        "invalid hardware change source rejected id=${expected_key_id} group=${hardware_group}"
      feedback="Select an owned hardware signing file with private permissions."
      continue
    fi
    if ! cntools_transaction_source_key_id_into actual_key_id "${normalized}"; then
      cntools_transaction_ui_log_path \
        "unidentified hardware change source rejected id=${expected_key_id} group=${hardware_group}" \
        "${normalized}"
      feedback="${CNTOOLS_TRANSACTION_ERROR:-The change HWS file could not be identified.}"
      continue
    fi
    if [[ "${actual_key_id}" != "${expected_key_id}" ]]; then
      cntools_transaction_ui_log CHOICE \
        "hardware change source identity rejected expected=${expected_key_id} actual=${actual_key_id} group=${hardware_group}"
      feedback="The selected file belongs to a different hardware change key."
      continue
    fi
    _cntools_output_ref="${normalized}"
    cntools_transaction_ui_log_path \
      "hardware change source selected id=${expected_key_id} group=${hardware_group}" \
      "${normalized}"
    return 0
  done
}

cntools_transaction_ui_selection_preflight() {
  local package_file="${1:-}"
  local signer_sources_name="${2:-}"
  local change_sources_name="${3:-}"
  local source=""
  local hardware_group=""
  local known_group=""
  local group_seen="N"
  local index=0
  local -a hardware_groups=()

  [[ "${signer_sources_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${change_sources_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n signer_sources_ref="${signer_sources_name}"
  local -n change_sources_ref="${change_sources_name}"
  cntools_transaction_sign_selection_reset
  for source in "${signer_sources_ref[@]}"; do
    cntools_transaction_sign_selection_add "${package_file}" "${source}" ||
      return 1
  done
  for source in "${change_sources_ref[@]}"; do
    cntools_transaction_change_selection_add "${package_file}" "${source}" ||
      return 1
  done
  for (( index = 0;
         index < ${#CNTOOLS_TRANSACTION_SELECTED_KEY_IDS[@]};
         index++ )); do
    [[ "${CNTOOLS_TRANSACTION_SELECTED_KINDS[index]}" == "hardware" ]] ||
      continue
    hardware_group="${CNTOOLS_TRANSACTION_SELECTED_HARDWARE_GROUPS[index]}"
    [[ -n "${hardware_group}" ]] || continue
    group_seen="N"
    for known_group in "${hardware_groups[@]}"; do
      [[ "${known_group}" != "${hardware_group}" ]] || group_seen="Y"
    done
    [[ "${group_seen}" == "Y" ]] || hardware_groups+=("${hardware_group}")
  done
  for hardware_group in "${hardware_groups[@]}"; do
    cntools_transaction_hardware_group_selection_complete \
      "${package_file}" "${hardware_group}" || {
        cntools_transaction_set_error \
          "Hardware session ${hardware_group} requires all of its still-missing signing keys to be selected together."
        return 1
      }
    cntools_transaction_hardware_group_change_selection_complete \
      "${package_file}" "${hardware_group}" || {
        cntools_transaction_set_error \
          "Hardware session ${hardware_group} requires every planned change HWS reference."
        return 1
      }
  done
}

cntools_transaction_ui_render_selected_sources() {
  local package_file="${1:-}"
  local signer_sources_name="${2:-}"
  local change_sources_name="${3:-}"
  local source=""
  local key_id=""
  local kind=""
  local labels=""
  local widths=""
  local index=0

  [[ "${signer_sources_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${change_sources_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n signer_sources_ref="${signer_sources_name}"
  local -n change_sources_ref="${change_sources_name}"
  cntools_transaction_ui_signer_widths_into widths || return 1
  cntools_ui_render_detail "Selected private sources" || return 1
  {
    printf 'Source\tKind\tPath\n'
    for source in "${signer_sources_ref[@]}"; do
      index=$((index + 1))
      cntools_transaction_source_kind_into kind "${source}" || return 1
      cntools_transaction_source_key_id_into key_id "${source}" || return 1
      labels="$(jq -r --arg id "${key_id}" \
        '.signing.required[] | select(.keyId == $id) | .labels | join(", ")' \
        "${package_file}")" || return 1
      cntools_transaction_ui_styled_signer_row \
        "$(printf '%02d · %s' "${index}" "${labels}")" "${kind}" \
        "${source}" identifier
    done
    for source in "${change_sources_ref[@]}"; do
      index=$((index + 1))
      cntools_transaction_source_key_id_into key_id "${source}" || return 1
      labels="$(jq -r --arg id "${key_id}" \
        '.signing.changeKeys[] | select(.keyId == $id) | .labels | join(", ")' \
        "${package_file}")" || return 1
      cntools_transaction_ui_styled_signer_row \
        "$(printf '%02d · %s' "${index}" "${labels}")" "change HWS" \
        "${source}" identifier
    done
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
}

cntools_transaction_action_sign() {
  local input_file=""
  local working_file=""
  local prepared_file=""
  local output_file="" saved_file="" review_choice=""
  local original_id=""
  local record=""
  local key_id=""
  local labels=""
  local preferred=""
  local hardware_group=""
  local source=""
  local selected_kind=""
  local change_source=""
  local signer_allow_defer="Y"
  local status=0
  local has_hardware="N"
  local group_active="N"
  local index=0
  local -a signer_sources=()
  local -a change_sources=()
  local -a active_hardware_groups=()
  local -a deferred_hardware_groups=()

  if cntools_transaction_ui_prompt_package_into input_file; then
    status=0
  else
    status=$?
  fi
  if (( status == 1 )); then
    cntools_transaction_ui_cancel "transaction signing cancelled at package selection"
    return 0
  elif (( status != 0 )); then
    return "${status}"
  fi
  if [[ "${CNTOOLS_TRANSACTION_PACKAGE_NETWORK}" != "${CNTOOLS_NETWORK:-}" ]]; then
    cntools_ui_action_begin "Sign" "/ Transaction / Sign"
    cntools_ui_render_status error \
      "This package targets ${CNTOOLS_TRANSACTION_PACKAGE_NETWORK}, but CNTools is configured for ${CNTOOLS_NETWORK:-unknown}."
    cntools_ui_wait
    return 1
  fi
  if [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == "Y" ]]; then
    cntools_ui_action_begin "Sign" "/ Transaction / Sign"
    cntools_ui_render_status warn \
      "This package is already fully signed and ready for submission."
    cntools_ui_wait
    return 0
  fi

  original_id="${CNTOOLS_TRANSACTION_ID}"
  cntools_ui_action_begin "Sign" "/ Transaction / Sign"
  status=0
  cntools_transaction_ui_review_into review_choice "${input_file}" 'Continue to select signing sources' \
    cntools_transaction_ui_sign_begin cntools_transaction_ui_render_package_review || status=$?
  if (( status == 1 )); then
    cntools_transaction_ui_cancel \
      "transaction signing cancelled after initial review id=${original_id}"
    return 0
  elif (( status != 0 )); then
    cntools_transaction_ui_render_result danger "${CNTOOLS_TRANSACTION_ERROR:-The transaction could not be reviewed safely. See ${CNTOOLS_LOG}.}" "${original_id}" "${input_file}"
    cntools_ui_wait
    return "${status}"
  fi
  cntools_transaction_ui_log CHOICE \
    "transaction signing review accepted id=${original_id}"

  while IFS= read -r record; do
    IFS=$'\037' read -r key_id labels preferred hardware_group <<< "${record}"
    signer_allow_defer="Y"
    if [[ -n "${hardware_group}" ]]; then
      group_active="N"
      for source in "${deferred_hardware_groups[@]}"; do
        [[ "${source}" != "${hardware_group}" ]] || group_active="Y"
      done
      if [[ "${group_active}" == "Y" ]]; then
        cntools_transaction_ui_log CHOICE \
          "hardware group signer deferred with session id=${key_id} group=${hardware_group}"
        continue
      fi
      group_active="N"
      for source in "${active_hardware_groups[@]}"; do
        [[ "${source}" != "${hardware_group}" ]] || group_active="Y"
      done
      [[ "${group_active}" == "N" ]] || signer_allow_defer="N"
    fi
    if cntools_transaction_ui_prompt_signer_into \
        source "${key_id}" "${labels}" "${preferred}" "${hardware_group}" \
        "${signer_allow_defer}"; then
      status=0
    else
      status=$?
    fi
    if (( status == 1 )); then
      cntools_transaction_ui_cancel \
        "transaction signing cancelled while selecting signer key=${key_id}"
      return 0
    elif (( status != 0 )); then
      return "${status}"
    fi
    if [[ -z "${source}" ]]; then
      if [[ -n "${hardware_group}" ]]; then
        deferred_hardware_groups+=("${hardware_group}")
        cntools_transaction_ui_log CHOICE \
          "hardware session deferred group=${hardware_group}"
      fi
      continue
    fi
    signer_sources+=("${source}")
    if [[ -n "${hardware_group}" && "${signer_allow_defer}" == "Y" ]]; then
      active_hardware_groups+=("${hardware_group}")
      cntools_transaction_ui_log CHOICE \
        "hardware session selected group=${hardware_group}"
    fi
  done < <(jq -r '
    . as $package |
    $package.signing.required[] |
    . as $signer |
    select(any($package.signing.witnesses[]; .keyId == $signer.keyId) | not) |
    [.keyId, (.labels | join(", ")), .preferredKind,
     (.hardwareGroup // "")] | join("\u001f")
  ' "${input_file}")

  if (( ${#signer_sources[@]} == 0 )); then
    cntools_transaction_ui_log CHOICE \
      "transaction signing deferred id=${original_id} selected_signers=0"
    cntools_ui_action_begin "Sign" "/ Transaction / Sign"
    cntools_ui_render_status warn \
      "No signing source was selected. The input package was left unchanged."
    cntools_ui_wait
    return 0
  fi

  # Resolve selected hardware sessions before requesting their separate
  # change-address references.
  cntools_transaction_sign_selection_reset
  for source in "${signer_sources[@]}"; do
    cntools_transaction_sign_selection_add "${input_file}" "${source}" || {
      cntools_ui_action_begin "Sign" "/ Transaction / Sign"
      cntools_ui_render_status error "${CNTOOLS_TRANSACTION_ERROR}"
      cntools_ui_wait
      return 1
    }
  done
  for (( index = 0;
         index < ${#CNTOOLS_TRANSACTION_SELECTED_KEY_IDS[@]};
         index++ )); do
    selected_kind="${CNTOOLS_TRANSACTION_SELECTED_KINDS[index]}"
    [[ "${selected_kind}" == "hardware" ]] || continue
    has_hardware="Y"
    hardware_group="${CNTOOLS_TRANSACTION_SELECTED_HARDWARE_GROUPS[index]}"
    [[ -n "${hardware_group}" ]] || continue
    group_active="N"
    for record in "${active_hardware_groups[@]}"; do
      [[ "${record}" != "${hardware_group}" ]] || group_active="Y"
    done
    [[ "${group_active}" == "Y" ]] ||
      active_hardware_groups+=("${hardware_group}")
  done

  while IFS= read -r record; do
    IFS=$'\037' read -r key_id labels hardware_group <<< "${record}"
    group_active="N"
    for source in "${active_hardware_groups[@]}"; do
      [[ "${source}" != "${hardware_group}" ]] || group_active="Y"
    done
    [[ "${group_active}" == "Y" ]] || continue
    if cntools_transaction_ui_prompt_change_into \
        change_source "${key_id}" "${labels}" "${hardware_group}"; then
      status=0
    else
      status=$?
    fi
    if (( status == 1 )); then
      cntools_transaction_ui_cancel \
        "transaction signing cancelled while selecting hardware change key=${key_id}"
      return 0
    elif (( status != 0 )); then
      return "${status}"
    fi
    change_sources+=("${change_source}")
  done < <(jq -r '.signing.changeKeys[] |
    [.keyId, (.labels | join(", ")), .hardwareGroup] | join("\u001f")' \
    "${input_file}")

  if ! cntools_transaction_ui_selection_preflight \
      "${input_file}" signer_sources change_sources; then
    cntools_ui_action_begin "Sign" "/ Transaction / Sign"
    cntools_ui_render_status error \
      "${CNTOOLS_TRANSACTION_ERROR:-The selected signing sources do not satisfy their planned hardware sessions.}"
    cntools_ui_wait
    return 1
  fi

  working_file="${input_file}"
  if [[ "${has_hardware}" == "Y" ]]; then
    cntools_ui_action_begin "Sign" "/ Transaction / Sign"
    if cntools_ui_spin_function \
        "Preparing the package for hardware review…" \
        cntools_transaction_package_prepare_hardware_into \
        prepared_file "${input_file}"; then
      status=0
    else
      status=$?
    fi
    if (( status != 0 )); then
      cntools_ui_action_begin "Sign" "/ Transaction / Sign"
      cntools_ui_render_status error \
        "${CNTOOLS_TRANSACTION_ERROR:-Hardware transaction preparation failed. See ${CNTOOLS_LOG}.}"
      cntools_ui_wait
      return "${status}"
    fi
    working_file="${prepared_file}"
    cntools_transaction_package_load "${working_file}" || return 1
    if [[ "${CNTOOLS_TRANSACTION_ID}" != "${original_id}" ]]; then
      cntools_transaction_ui_log HARDWARE \
        "pre-confirmation transform changed transaction id old=${original_id} new=${CNTOOLS_TRANSACTION_ID}"
    fi
  fi

  cntools_transaction_signed_path_into output_file || return 1
  status=0
  while true; do
    cntools_transaction_ui_review_into review_choice "${working_file}" 'Sign with selected sources' \
      cntools_transaction_ui_sign_begin cntools_transaction_ui_render_package_review 'Show selected sources' || { status=$?; break; }
    [[ "${review_choice}" == 'Show selected sources' ]] || break
    cntools_transaction_ui_sign_begin
    cntools_transaction_ui_render_selected_sources "${working_file}" signer_sources change_sources || return 1
    cntools_ui_wait
  done
  if (( status == 1 )); then
    cntools_transaction_ui_cancel \
      "transaction signing declined id=${CNTOOLS_TRANSACTION_ID}"
    return 0
  elif (( status != 0 )); then
    cntools_transaction_ui_render_result danger "${CNTOOLS_TRANSACTION_ERROR:-The transaction could not be reviewed safely. See ${CNTOOLS_LOG}.}" "${original_id}" "${input_file}"
    cntools_ui_wait
    return "${status}"
  fi
  cntools_transaction_ui_log CHOICE \
    "transaction signing confirmed id=${CNTOOLS_TRANSACTION_ID} signers=${#signer_sources[@]} change_refs=${#change_sources[@]}"

  cntools_ui_action_begin "Sign" "/ Transaction / Sign"
  if cntools_ui_spin_function "Collecting transaction signatures…" \
      cntools_transaction_sign_package \
      "${working_file}" "${output_file}" signer_sources change_sources; then
    status=0
  else
    status=$?
  fi
  cntools_ui_action_begin "Sign" "/ Transaction / Sign"
  if (( status != 0 )); then
    cntools_transaction_ui_render_result danger \
      "${CNTOOLS_TRANSACTION_ERROR:-Transaction signing failed. See ${CNTOOLS_LOG}.}" "${original_id}" "${input_file}"
    cntools_ui_wait
    return "${status}"
  fi

  cntools_transaction_package_load "${output_file}" || {
    cntools_ui_render_status error \
      "The output was written but could not be reopened as a valid transaction package. See ${CNTOOLS_LOG}."
    cntools_ui_wait
    return 1
  }
  if ! cntools_transaction_save_into saved_file "${output_file}" signed transaction; then
    cntools_transaction_ui_render_result danger "${CNTOOLS_TRANSACTION_ERROR:-Could not save the signed package.}" "${CNTOOLS_TRANSACTION_ID}"
    cntools_ui_wait
    return 1
  fi
  if [[ "${CNTOOLS_TRANSACTION_COMPLETE}" == Y ]]; then
    cntools_transaction_ui_render_result success 'Signed · ready for Transaction → Submit' "${CNTOOLS_TRANSACTION_ID}" "${saved_file}"
  else
    cntools_transaction_ui_render_result success 'Partially signed · move this package to the next signer' "${CNTOOLS_TRANSACTION_ID}" "${saved_file}"
  fi
  cntools_ui_wait
}

cntools_transaction_ui_submission_backend_into() {
  local _cntools_output_name="${1:-}"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if [[ "${CNTOOLS_MODE:-}" == "offline" ]]; then
    cntools_transaction_set_error \
      "Transaction submission is unavailable in offline mode. Move the signed artifact to an online CNTools session."
    return 1
  fi
  if cntools_transaction_submit_local_ready; then
    _cntools_output_ref="local"
  elif [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == "Y" ]]; then
    [[ -n "${CNTOOLS_KOIOS_API:-}" &&
       "${CNTOOLS_KOIOS_API}" =~ ^https://[^[:space:]]+$ ]] || {
      cntools_transaction_set_error \
        "The configured Koios API endpoint is missing or unsafe."
      return 1
    }
    cntools_transaction_submit_require_xxd || return 1
    _cntools_output_ref="koios"
  else
    cntools_transaction_set_error \
      "No transaction submission backend is available. Start a reachable local node or enable Koios."
    return 1
  fi
  cntools_transaction_ui_log TRANSACTION \
    "submission backend selected backend=${_cntools_output_ref}"
}

cntools_transaction_ui_prompt_submit_input_into() {
  local _cntools_output_name="${1:-}"
  local feedback=""
  local entered=""
  local normalized=""
  local status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  while true; do
    cntools_ui_action_begin "Submit" "/ Transaction / Submit"
    cntools_ui_render_status info \
      "Select a complete CNTools transaction package or an external Cardano transaction envelope. CNTools can prove package completeness; an external envelope receives final ledger validation from the submission backend."
    [[ -z "${feedback}" ]] || cntools_ui_render_status warn "${feedback}"
    if cntools_ui_input entered "Transaction artifact" "${PWD}/transaction.signed.json"; then
      status=0
    else
      status=$?
    fi
    (( status == 0 )) || return "${status}"
    if ! cntools_transaction_ui_normalize_path_into normalized "${entered}"; then
      cntools_transaction_ui_log CHOICE \
        "invalid signed transaction path rejected"
      feedback="Enter an existing transaction path whose parent directory can be resolved safely."
      continue
    fi
    cntools_transaction_submit_reset
    cntools_transaction_package_reset_loaded
    cntools_transaction_clear_error
    if cntools_ui_spin_function \
        "Validating signed transaction…" \
        cntools_transaction_submit_input_prepare "${normalized}"; then
      status=0
    else
      status=$?
    fi
    if (( status == 1 )); then
      cntools_transaction_ui_log_path \
        "invalid signed transaction rejected" "${normalized}"
      feedback="${CNTOOLS_TRANSACTION_ERROR:-The selected transaction could not be validated.}"
      continue
    elif (( status != 0 )); then
      return "${status}"
    fi
    _cntools_output_ref="${normalized}"
    cntools_transaction_ui_log_path \
      "transaction artifact selected id=${CNTOOLS_TRANSACTION_SUBMIT_ID} kind=${CNTOOLS_TRANSACTION_SUBMIT_INPUT_KIND}" \
      "${normalized}"
    return 0
  done
}

cntools_transaction_ui_render_submit_review() {
  local widths="" fee="" expiry_label="" expiry_slot=""
  if [[ "${CNTOOLS_TRANSACTION_SUBMIT_INPUT_KIND}" == package ]]; then
    expiry_slot="${CNTOOLS_TRANSACTION_PACKAGE_INVALID_HEREAFTER:-}"
  else
    expiry_slot="$(jq -r '.["validity range"]["upper bound"] // empty' <<< "${CNTOOLS_TRANSACTION_UI_VIEW}")" || return 1
  fi
  cntools_transaction_ui_expiry_label_into expiry_label "${expiry_slot}"
  cntools_transaction_ui_table_widths_into widths 22 || return 1
  cntools_ui_render_detail 'Transaction information' || return 1
  {
    printf 'Property\tValue\n'
    cntools_transaction_ui_styled_row 'Transaction ID' "${CNTOOLS_TRANSACTION_SUBMIT_ID}" identifier
    cntools_transaction_ui_styled_row Status 'Signed · ready to submit' success
    if cntools_transaction_ui_fee_into fee; then
      cntools_transaction_ui_styled_row Fee "$(cntools_number_format_units "${fee}" 6) ADA" number
    fi
    cntools_transaction_ui_styled_row Expires "${expiry_label}" number
  } | cntools_ui_table --separator $'\t' --widths "${widths}" || return 1
  if [[ "${CNTOOLS_TRANSACTION_SUBMIT_INPUT_KIND}" != package ]]; then
    cntools_ui_render_status warn 'External-envelope completeness cannot be inferred. The submission backend must perform final ledger validation.'
  fi
  cntools_transaction_ui_render_effects
}

cntools_transaction_ui_submit_selected() {
  local backend="${1:-}"
  local signed_file="${2:-}"
  local transaction_id="${3:-}"

  case "${backend}" in
    local)
      cntools_transaction_submit_local_ready || {
        cntools_transaction_set_error \
          "The confirmed local submission backend is no longer available. Nothing was submitted; review the backend before trying again."
        return 1
      }
      cntools_transaction_submit_local "${signed_file}" "${transaction_id}"
      ;;
    koios)
      cntools_transaction_submit_koios "${signed_file}" "${transaction_id}"
      ;;
    *) return 2 ;;
  esac
}

# Monitoring is a separate, optional observation after successful submission.
# All outcomes return success: cancellation/indexer failure cannot undo a submit.
cntools_transaction_ui_offer_monitor() {
  local transaction_id="${1:-}" widths="" message="" role=warning elapsed_label="Unavailable"
  [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == Y ]] || return 0
  cntools_transaction_monitor_available || return 0
  [[ "${transaction_id}" =~ ^[0-9a-f]{64}$ ]] || return 0
  if ! cntools_ui_confirm 'Monitor block inclusion through Koios?' true; then
    cntools_transaction_log CHOICE "Koios transaction monitoring declined id=${transaction_id}"
    return 0
  fi
  cntools_transaction_log CHOICE "Koios transaction monitoring accepted id=${transaction_id}"
  cntools_ui_render_status info 'Checking Koios every 5 seconds for up to 3 minutes. Press q between requests to stop. Time is measured from submission acceptance and includes polling/indexing delays; inclusion is not finality.' || true
  cntools_transaction_monitor_run "${transaction_id}"
  case "${CNTOOLS_TRANSACTION_MONITOR_STATE}" in
    included) message='Included in a block · observed by Koios'; role=success ;;
    cancelled) message='Monitoring stopped · submission remains accepted' ;;
    timeout) message='Not yet observed by Koios · submission remains accepted' ;;
    *) message='Koios monitoring unavailable · submission remains accepted' ;;
  esac
  cntools_transaction_log TX "Monitoring finished id=${transaction_id} state=${CNTOOLS_TRANSACTION_MONITOR_STATE}"
  if cntools_transaction_ui_table_widths_into widths 22; then
    {
      printf 'Confirmation detail\tValue\n'
      cntools_transaction_ui_styled_row Status "${message}" "${role}"
      cntools_transaction_ui_styled_row 'Transaction ID' "${transaction_id}" identifier
      if [[ "${CNTOOLS_TRANSACTION_MONITOR_STATE}" == included ]]; then
        if [[ "${CNTOOLS_TRANSACTION_MONITOR_ELAPSED}" =~ ^[0-9]+$ ]]; then
          elapsed_label="$(cntools_number_format "${CNTOOLS_TRANSACTION_MONITOR_ELAPSED}") seconds"
        fi
        cntools_transaction_ui_styled_row 'Time to inclusion' "${elapsed_label}" number
      fi
    } | cntools_ui_table --separator $'\t' --widths "${widths}" || true
  fi
  return 0
}

cntools_transaction_action_submit() {
  local input_file=""
  local backend=""
  local input_kind=""
  local transaction_id=""
  local signed_file=""
  local status=0 review_choice="" review_package=""

  if cntools_transaction_ui_prompt_submit_input_into input_file; then
    status=0
  else
    status=$?
  fi
  if (( status == 1 )); then
    cntools_transaction_ui_cancel "transaction submission cancelled at input selection"
    return 0
  elif (( status != 0 )); then
    return "${status}"
  fi
  input_kind="${CNTOOLS_TRANSACTION_SUBMIT_INPUT_KIND}"
  transaction_id="${CNTOOLS_TRANSACTION_SUBMIT_ID}"
  signed_file="${CNTOOLS_TRANSACTION_SIGNED_FILE}"
  if ! cntools_transaction_ui_submission_backend_into backend; then
    cntools_ui_action_begin "Submit" "/ Transaction / Submit"
    cntools_ui_render_status error "${CNTOOLS_TRANSACTION_ERROR}"
    cntools_ui_wait
    return 1
  fi

  cntools_transaction_view_into CNTOOLS_TRANSACTION_UI_VIEW "${signed_file}" || return 1
  [[ "${input_kind}" != package ]] || review_package="${CNTOOLS_TRANSACTION_PACKAGE_FILE}"
  cntools_transaction_ui_review_into review_choice "${review_package}" 'Continue to submit' \
    cntools_transaction_ui_submit_begin cntools_transaction_ui_render_submit_review || status=$?
  if (( status == 0 )); then
    cntools_transaction_ui_confirm_submit "${backend}" || status=$?
  fi
  if (( status == 1 )); then
    cntools_transaction_ui_cancel \
      "transaction submission declined id=${transaction_id} backend=${backend}"
    return 0
  elif (( status != 0 )); then
    cntools_transaction_ui_render_result danger "${CNTOOLS_TRANSACTION_ERROR:-The transaction could not be reviewed safely. See ${CNTOOLS_LOG}.}" "${transaction_id}" "${input_file}"
    cntools_ui_wait
    return "${status}"
  fi
  cntools_transaction_ui_log CHOICE \
    "transaction submission confirmed id=${transaction_id} backend=${backend}"

  cntools_ui_action_begin "Submit" "/ Transaction / Submit"
  if cntools_ui_spin_function "Submitting transaction…" \
      cntools_transaction_ui_submit_selected \
      "${backend}" "${signed_file}" "${transaction_id}"; then
    status=0
  else
    status=$?
  fi
  cntools_ui_action_begin "Submit" "/ Transaction / Submit"
  if (( status != 0 )); then
    cntools_transaction_ui_render_result danger \
      "${CNTOOLS_TRANSACTION_ERROR:-Transaction submission failed. See ${CNTOOLS_LOG}.}" "${transaction_id}" "${input_file}"
    cntools_ui_wait
    return "${status}"
  fi
  cntools_transaction_ui_render_result success "${CNTOOLS_TRANSACTION_SUBMIT_MESSAGE:-Transaction accepted.} Submission is not confirmation of inclusion." "${transaction_id}"
  cntools_transaction_ui_offer_monitor "${transaction_id}"
  cntools_ui_wait
}
