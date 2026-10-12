#!/usr/bin/env bash
# Shared transaction/UTxO detail tables. Callers provide authoritative data and
# an honest source label; this renderer never queries chain data or signs.
# Public components: cntools_detail_transaction_render(file, source heading),
# cntools_detail_utxo_render(record JSON, heading), cntools_detail_io_render(file,
# field, heading), cntools_detail_assets_render(record JSON), and
# cntools_detail_metadata_render(file). Use CNTOOLS_DETAIL_METADATA
# to opt into already-fetched metadata; rendering must never fetch it implicitly.
# shellcheck disable=SC2034

cntools_detail_pair() {
  cntools_table_pair "$1" "$2" "${3:-value}"
}

cntools_detail_asset_display() {
  local asset="$1" prefix="${2:-Asset}" identity="" quantity="" label="" formatted="" decimals=""
  identity="$(jq -r '.policy_id + "." + .asset_name' <<< "${asset}")" || return 1
  quantity="$(jq -r '.quantity // "" | tostring' <<< "${asset}")" || return 1
  [[ "${identity}" =~ ^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$ ]] || return 0
  if [[ "${CNTOOLS_DETAIL_METADATA:-${CNTOOLS_HISTORY_METADATA:-N}}" == Y ]]; then
    cntools_asset_label_into label "${identity}" 1 || return 1
    cntools_detail_pair "${prefix} name" "${label}" || return 1
    decimals="${CNTOOLS_WALLET_ASSET_METADATA_DECIMALS[${identity}]:-}"
    if [[ "${quantity}" =~ ^[0-9]+$ && "${decimals}" =~ ^[0-9]+$ ]]; then
      cntools_number_format_units_into formatted "${quantity}" "${decimals}" || return 1
      cntools_detail_pair "${prefix} amount" "${formatted}" number || return 1
    fi
  fi
}

# Input/output records are already isolated, so paths never repeat the I/O
# ordinal or payment address. Optional nulls and empty structures stay hidden.
cntools_detail_tree_rows() {
  local file="$1" section="$2" path="" type="" value="" role="value" formatted=""
  local decimals="${3:-}"
  cntools_table_row Field Value
  while IFS=$'\037' read -r path type value; do
    role=value
    if [[ "${type}" == asset ]]; then
      cntools_detail_asset_display "${value}" "${path}" || return 1
      continue
    fi
    if [[ "${section}" =~ ^(Overview|Record)$ && "${path}" =~ ^(tx_timestamp|block_time)$ ]]; then
      cntools_timestamp_datetime_into formatted "${value}" && value="${formatted}"
    elif [[ "${section}" == Overview && "${path}" =~ ^(invalid_before|invalid_after)$ && "${type}" != null ]]; then
      cntools_slot_datetime_into formatted "${value}" && value="${formatted}"
    elif [[ "${type}" == string && "${value}" =~ ^-?[0-9]+$ ]] &&
         { [[ "${section}" == Overview &&
              "${path}" =~ ^(value|fee|deposit|treasury_donation|total_output)$ ]] ||
           [[ "${section}" =~ ^(Record|inputs|outputs|collateral_inputs|collateral_output|reference_inputs)$ &&
              "${path}" =~ ^(\[[0-9]+\]\ /\ )?value$ ]]; }; then
      if [[ "${value}" == -* ]]; then
        value="-$(cntools_number_format_lovelace "${value#-}")"
      else
        value="$(cntools_number_format_lovelace "${value}")"
      fi
      role=number
    elif [[ "${type}" == number || ( "${section}" != metadata &&
            "${path}" == *quantity && "${value}" =~ ^-?[0-9]+$ ) ]]; then
      cntools_number_format_into formatted "${value}" && value="${formatted}"
      role=number
    elif [[ "${path}" =~ (hash|fingerprint|address|bech32|cred|policy_id|asset_name)$ ]]; then
      role=identifier
    fi
    if [[ "${section}" == Asset ]]; then
      case "${path}" in
        quantity) path="Raw quantity" ;;
        policy_id) path="Policy ID" ;;
        asset_name) path="Asset name (hex)" ;;
        fingerprint) path=Fingerprint ;;
        decimals) path=Decimals ;;
      esac
    fi
    cntools_detail_pair "${path}" "${value}" "${role}" || return 1
  done < <(jq -r --arg section "${section}" --arg decimals "${decimals}" '
    def clean: tostring | gsub("[\u0000-\u001f\u007f]";" ");
    def leaves($path):
      if . == null or . == [] or . == {} then empty
      elif type == "object" and length > 0 then
        (if $section != "Asset" and (.policy_id? | type == "string") and (.asset_name? | type == "string")
          then [$path,"asset",tojson] else empty end),
        (to_entries[] | .key as $key | .value | leaves(if $path == "" then $key else $path + " / " + $key end))
      elif type == "array" and length > 0 then
        to_entries[] | .key as $key | .value | leaves($path + "[" + (($key+1)|tostring) + "]")
      else [$path,type,(if type == "string" then (if . == "" then "(empty string)" else . end) else tojson end)] end;
    (if $section == "Overview" then with_entries(select(.value | type != "array" and type != "object"))
     elif $section == "Record" then del(.payment_addr,.payment_cred,.address,.asset_list,.is_spent)
     elif $section == "Asset" then
       if $decimals != "" then .decimals=($decimals|tonumber) else . end
     else .[$section] end) |
    leaves("") | map(clean) | join("\u001f")
  ' "${file}")
}

cntools_detail_asset_title_into() {
  # Declining enrichment still permits a locally decoded name, but never uses
  # cached metadata from another view or triggers an API request.
  if [[ "${CNTOOLS_DETAIL_METADATA:-${CNTOOLS_HISTORY_METADATA:-N}}" != Y ]]; then
    local -A CNTOOLS_WALLET_ASSET_TICKERS=() CNTOOLS_WALLET_ASSET_CLASSES=()
    local -A CNTOOLS_WALLET_ASSET_METADATA_NAMES=() CNTOOLS_WALLET_ASSET_ASCII_NAMES=()
  fi
  cntools_asset_label_into "$1" "$2" "$3"
}

cntools_detail_asset_rows() {
  local asset="$1" identity="$2" decimals="" quantity="" formatted=""
  if [[ "${CNTOOLS_DETAIL_METADATA:-${CNTOOLS_HISTORY_METADATA:-N}}" == Y ]]; then
    decimals="${CNTOOLS_WALLET_ASSET_METADATA_DECIMALS[${identity}]:-}"
    quantity="$(jq -r '.quantity | tostring' <<< "${asset}")" || return 1
    if [[ "${quantity}" =~ ^[0-9]+$ && "${decimals}" =~ ^[0-9]+$ ]]; then
      cntools_number_format_units_into formatted "${quantity}" "${decimals}" || return 1
      cntools_detail_pair Amount "${formatted}" number || return 1
    else
      decimals=""
    fi
  fi
  cntools_detail_tree_rows <(printf '%s\n' "${asset}") Asset "${decimals}"
}

cntools_detail_assets_render() {
  local record="$1" asset="" identity="" title="" rendered="" line="" index=0
  local CNTOOLS_TABLE_MARGIN=$(( ${CNTOOLS_TABLE_MARGIN:-0} + 2 ))
  local CNTOOLS_TABLE_TITLE_ROLE=accent
  while IFS= read -r asset; do
    index=$((index + 1))
    identity="$(jq -r '.policy_id + "." + .asset_name' <<< "${asset}")" || return 1
    cntools_detail_asset_title_into title "${identity}" "${index}" || return 1
    rendered="$(cntools_detail_asset_rows "${asset}" "${identity}" |
      cntools_table_render "${title}")" || return 1
    while IFS= read -r line; do
      printf '  %s\n' "${line}"
    done <<< "${rendered}"
    printf '\n'
  done < <(jq -c '.asset_list | if type == "array" then .[] else empty end' <<< "${record}")
}

cntools_detail_utxo_render() {
  local record="$1" title="$2"
  cntools_detail_tree_rows <(printf '%s\n' "${record}") Record | cntools_table_render "${title}" || return 1
  cntools_detail_assets_render "${record}"
}

cntools_detail_utxo_title() {
  local record="$1" number="$2" address="" formatted=""
  address="$(jq -r '((try .payment_addr.bech32 catch null) // .address) |
    if type == "string" and length > 0 then . else "Address unavailable" end' <<< "${record}")" || return 1
  cntools_text_sanitize_into address "${address}" || return 1
  cntools_number_format_into formatted "${number}" || return 1
  printf '%s · %s\n' "${formatted}" "${address}"
}

cntools_detail_io_render() {
  local file="$1" section="$2" title="$3" record="" heading="" index=0
  local CNTOOLS_TABLE_TITLE_ROLE=identifier
  cntools_table_heading "━━ ${title} ━━" accent || return 1
  while IFS= read -r record; do
    index=$((index + 1))
    heading="$(cntools_detail_utxo_title "${record}" "${index}")" || return 1
    cntools_detail_utxo_render "${record}" "${heading}" || return 1
  done < <(jq -c --arg section "${section}" '.[$section] | if type == "array" then .[] else . end' "${file}")
}

cntools_detail_metadata_render() {
  local file="$1" entry="" label="" type="" line="" number=0 extra=""
  if ! jq -e '.metadata | type == "object"' "${file}" >/dev/null; then
    cntools_table_heading "Metadata" || return 1
    while IFS= read -r line; do cntools_table_heading "${line}" value || return 1; done < <(jq '.metadata' "${file}")
    printf '\n'
    return 0
  fi
  while IFS= read -r entry; do
    label="$(jq -r '.key' <<< "${entry}")" || return 1
    type="Custom metadata"
    case "${label}" in
      674)
        if jq -e '.value | type == "object" and .enc == "basic"' <<< "${entry}" >/dev/null; then
          type="CIP-83 encrypted message"
        elif jq -e '.value | type == "object" and (has("enc")|not) and
            (.msg | type == "array" and length > 0 and all(type == "string"))' <<< "${entry}" >/dev/null; then
          type="CIP-20 message"
        fi ;;
      721) type="CIP-25 asset metadata" ;;
      20) type="Fungible token metadata" ;;
    esac
    cntools_table_heading "${label} · ${type}" accent || return 1
    if [[ "${type}" == "CIP-20 message" ]]; then
      number=0
      while IFS= read -r line; do
        number=$((number + 1))
        # Each msg array item stays one numbered message line; controls are
        # replaced, never interpreted as terminal escape sequences.
        cntools_table_heading "${number} · ${line}" value || return 1
      done < <(jq -r '.value.msg[] | gsub("[\u0000-\u001f\u007f]";" ")' <<< "${entry}")
      extra="$(jq '.value | del(.msg) | select(length > 0)' <<< "${entry}")" || return 1
      if [[ -n "${extra}" ]]; then
        while IFS= read -r line; do cntools_table_heading "${line}" value || return 1; done <<< "${extra}"
      fi
    else
      while IFS= read -r line; do cntools_table_heading "${line}" value || return 1; done < <(jq '.value' <<< "${entry}")
    fi
    printf '\n'
  done < <(jq -c '.metadata | to_entries[]' "${file}")
}

cntools_detail_transaction_render() {
  local file="$1" section="" title="" encoded="" record=""
  if jq -e 'has("is_spent") and has("address")' "${file}" >/dev/null; then
    record="$(jq -c . "${file}")" || return 1
    title="$(cntools_detail_utxo_title "${record}" "${CNTOOLS_DETAIL_NUMBER:-${CNTOOLS_HISTORY_DETAIL_NUMBER:-1}}")" || return 1
    cntools_table_heading '━━ Unspent output ━━' accent || return 1
    local CNTOOLS_TABLE_TITLE_ROLE=identifier
    cntools_detail_utxo_render "${record}" "${title}"
    return $?
  fi
  cntools_detail_tree_rows "${file}" Overview | cntools_table_render "${2:-Overview}" || return 1
  # Put ordinary inputs/outputs first; optional sections retain source order.
  while IFS= read -r encoded; do
    section="$(jq -r . <<< "${encoded}")" || return 1
    case "${section}" in
      inputs) cntools_detail_io_render "${file}" "${section}" Inputs ;;
      outputs) cntools_detail_io_render "${file}" "${section}" Outputs ;;
      collateral_inputs) cntools_detail_io_render "${file}" "${section}" 'Collateral inputs' ;;
      collateral_output) cntools_detail_io_render "${file}" "${section}" 'Collateral output' ;;
      reference_inputs) cntools_detail_io_render "${file}" "${section}" 'Reference inputs' ;;
      metadata) cntools_detail_metadata_render "${file}" ;;
      *)
        cntools_text_sanitize_into title "${section//_/ }" || return 1
        cntools_detail_tree_rows "${file}" "${section}" | cntools_table_render "${title}"
        ;;
    esac || return 1
  done < <(jq -c '
    . as $tx |
    (["inputs","outputs"] + [keys_unsorted[] | select(. != "inputs" and . != "outputs")])[] as $key |
    select($tx[$key] | (type == "array" or type == "object") and length > 0) | $key
  ' "${file}")
}


