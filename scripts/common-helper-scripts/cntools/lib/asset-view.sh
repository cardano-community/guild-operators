#!/usr/bin/env bash
# Native-asset formatting and tables, independent of wallet action navigation.
# shellcheck disable=SC2034

cntools_wallet_asset_label_into() {
  cntools_asset_label_into "$@"
}


cntools_wallet_asset_label() {
  local label=""

  cntools_wallet_asset_label_into label "${1:-}" "${2:-0}" || return $?
  printf '%s' "${label}"
}


cntools_wallet_format_token_amount_into() {
  cntools_number_format_units_into "${1:-}" "${2:-}" "${3:-0}"
}


cntools_wallet_format_token_amount() {
  local amount=""

  cntools_wallet_format_token_amount_into \
    amount "${1:-}" "${2:-}" || return $?
  printf '%s\n' "${amount}"
}


cntools_wallet_asset_metadata_source_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_asset_id="${2:-}"
  local _cntools_source=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_source="${CNTOOLS_WALLET_ASSET_METADATA_SOURCES[${_cntools_asset_id}]:-}"
  if [[ -n "${_cntools_source}" ]]; then
    _cntools_output_ref="${_cntools_source} · Koios API"
    return 0
  fi
  if [[ -n "${CNTOOLS_WALLET_ASSET_METADATA_QUERIED[${_cntools_asset_id}]+x}" ]]; then
    _cntools_output_ref="None found · Koios API"
    return 0
  fi
  case "${CNTOOLS_WALLET_ASSET_METADATA_STATUS:-not-requested}" in
    available|partial|unavailable)
      _cntools_output_ref="Unavailable · Koios API"
      ;;
    *) _cntools_output_ref="Not requested" ;;
  esac
}


cntools_wallet_asset_metadata_detail_rows() {
  local asset_id="${1:-}"
  local table_width="${2:-}"
  local metadata_json="${CNTOOLS_WALLET_ASSET_METADATA_JSON[${asset_id}]:-[]}"
  local rows=""
  local property=""
  local value=""
  local value_role="value"

  [[ "${table_width}" =~ ^[1-9][0-9]*$ ]] || return 2
  jq -e '
    type == "array" and length <= 96 and
    all(.[];
      type == "object" and
      (.property | type == "string" and length <= 96) and
      (.value | type == "string" and length <= 384))
  ' <<< "${metadata_json}" >/dev/null 2>&1 || return 1
  rows="$(jq -r '
    .[] | [.property, .value] | join("\u001f")
  ' <<< "${metadata_json}" 2>/dev/null)" || return 1
  while IFS=$'\037' read -r property value; do
    [[ -n "${property}" ]] || continue
    if [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      value_role="number"
    elif [[ "${value}" =~ ^(https|ipfs|ar):// ]]; then
      value_role="identifier"
    else
      value_role="value"
    fi
    cntools_table_wrapped_triple \
      "" "${property}" "${value}" 22 20 "${table_width}" \
      value "${value_role}" || return 1
  done <<< "${rows}"
}


cntools_wallet_asset_details_rows() {
  local view="${1:-detailed}"
  local asset_id=""
  local label=""
  local display_label=""
  local policy_id=""
  local asset_name=""
  local quantity=""
  local display_quantity=""
  local fingerprint=""
  local display_amount=""
  local display_decimals=""
  local asset_class=""
  local total_supply=""
  local display_total_supply=""
  local metadata_source=""
  local table_width=""
  local index=0

  [[ "${view}" == "simple" || "${view}" == "detailed" ]] || return 2
  [[ "${CNTOOLS_WALLET_ASSET_COUNT:-}" =~ ^[1-9][0-9]*$ ]] || return 0
  table_width="$(cntools_table_width)" || return 1
  cntools_table_row "Asset" "Property" "Value" || return 1
  for asset_id in "${CNTOOLS_WALLET_ASSET_IDS[@]}"; do
    index=$((index + 1))
    cntools_wallet_asset_label_into label "${asset_id}" "${index}" || return 1
    printf -v display_label '%02d · %s' "${index}" "${label}"
    policy_id="${asset_id%%.*}"
    asset_name="${asset_id#*.}"
    quantity="${CNTOOLS_WALLET_ASSET_QUANTITIES[${asset_id}]:-Unavailable}"
    cntools_text_format_number_into display_quantity "${quantity}" || return 1
    fingerprint="${CNTOOLS_WALLET_ASSET_FINGERPRINTS[${asset_id}]:-Unavailable}"
    asset_class="${CNTOOLS_WALLET_ASSET_CLASSES[${asset_id}]:-FT}"
    if [[ "${asset_class}" == "NFT" ]]; then
      display_decimals=""
    else
      display_decimals="${CNTOOLS_WALLET_ASSET_METADATA_DECIMALS[${asset_id}]:-${CNTOOLS_WALLET_ASSET_DECIMALS[${asset_id}]:-}}"
    fi
    display_amount="${display_quantity}"
    if [[ "${quantity}" =~ ^[0-9]+$ &&
          "${display_decimals}" =~ ^[0-9]+$ ]]; then
      cntools_wallet_format_token_amount_into \
        display_amount "${quantity}" "${display_decimals}" || return 1
    fi
    cntools_table_wrapped_triple \
      "${display_label}" "Type" "${asset_class}" \
      22 20 "${table_width}" identifier value || return 1
    if [[ "${asset_class}" != "NFT" ]]; then
      cntools_table_wrapped_triple \
        "" "Amount" "${display_amount}" \
        22 20 "${table_width}" value number || return 1
      total_supply="${CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES[${asset_id}]:-}"
      if [[ "${total_supply}" =~ ^[0-9]+$ ]]; then
        display_total_supply=""
        cntools_wallet_format_token_amount_into \
          display_total_supply "${total_supply}" "${display_decimals}" || return 1
        cntools_table_wrapped_triple \
          "" "Total supply" "${display_total_supply}" \
          22 20 "${table_width}" value number || return 1
      else
        cntools_table_wrapped_triple \
          "" "Total supply" "Unavailable" \
          22 20 "${table_width}" value muted || return 1
      fi
    fi
    cntools_table_wrapped_triple \
      "" "Policy ID" "${policy_id}" 22 20 "${table_width}" \
      value identifier || return 1
    cntools_table_wrapped_triple \
      "" "Asset name (hex)" "${asset_name:-(empty)}" \
      22 20 "${table_width}" value identifier ||
      return 1
    cntools_table_wrapped_triple \
      "" "Fingerprint" "${fingerprint}" 22 20 "${table_width}" \
      value identifier || return 1
    cntools_wallet_asset_metadata_source_into \
      metadata_source "${asset_id}" || return 1
    cntools_table_wrapped_triple \
      "" "Metadata source" "${metadata_source}" 22 20 "${table_width}" \
      value muted || return 1
    if [[ "${view}" == "detailed" &&
          -n "${CNTOOLS_WALLET_ASSET_METADATA_SOURCES[${asset_id}]:-}" ]]; then
      cntools_wallet_asset_metadata_detail_rows \
        "${asset_id}" "${table_width}" || return 1
    fi
  done
}


cntools_wallet_render_asset_details_content() {
  local rows_file="${1:-}"
  local view="${2:-detailed}"
  local title="Native assets"
  local display_count=""

  [[ "${view}" == "simple" || "${view}" == "detailed" ]] || return 2

  if [[ "${CNTOOLS_WALLET_ASSET_COUNT:-}" =~ ^[0-9]+$ ]]; then
    cntools_text_format_number_into \
      display_count "${CNTOOLS_WALLET_ASSET_COUNT}" || return 1
    if [[ "${view}" == "simple" ]]; then
      title="Native assets (${display_count}) · Simple"
    else
      title="Native assets (${display_count}) · Detailed"
    fi
  fi
  cntools_wallet_render_table_file "${title}" "${rows_file}"
}


cntools_wallet_file_row_count_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_source_file="${2:-}"
  local _cntools_rows=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     -f "${_cntools_source_file}" && ! -L "${_cntools_source_file}" ]] ||
    return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_rows="$(wc -l < "${_cntools_source_file}")" || return 1
  _cntools_rows="${_cntools_rows//[[:space:]]/}"
  [[ "${_cntools_rows}" =~ ^[0-9]+$ ]] || return 1
  _cntools_output_ref="${_cntools_rows}"
}


cntools_wallet_render_asset_metadata_status() {
  case "${CNTOOLS_WALLET_ASSET_METADATA_STATUS:-not-requested}" in
    partial)
      cntools_ui_render_status warn \
        "Some Koios token metadata is unavailable; holdings remain complete."
      ;;
    unavailable)
      cntools_ui_render_status warn \
        "Koios token metadata is unavailable; holdings remain complete."
      ;;
  esac
}


cntools_wallet_render_asset_details_table() {
  local view="${1:-detailed}"
  local rows_file=""

  [[ "${view}" == "simple" || "${view}" == "detailed" ]] || return 2
  [[ "${CNTOOLS_WALLET_ASSET_COUNT:-}" =~ ^[1-9][0-9]*$ ]] || return 0
  cntools_wallet_render_asset_metadata_status || return 1
  cntools_wallet_write_rows_file \
    rows_file cntools_wallet_asset_details_rows "${view}" || return 1
  cntools_wallet_render_asset_details_content "${rows_file}" "${view}"
}
