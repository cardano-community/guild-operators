#!/usr/bin/env bash
# Shared transaction/UTxO detail tables. Callers provide authoritative data and
# an honest source label; this renderer never queries chain data or signs.
# Public components: cntools_detail_transaction_render(file, source heading),
# cntools_detail_utxo_render(record JSON, heading), cntools_detail_io_render(file,
# field, heading), cntools_detail_list_render(file, field, heading),
# cntools_detail_assets_render(record JSON), and cntools_detail_metadata_render(file).
# Use CNTOOLS_DETAIL_METADATA
# to opt into already-fetched metadata; rendering must never fetch it implicitly.
# shellcheck disable=SC2034

cntools_detail_pair() {
  cntools_table_pair "$1" "$2" "${3:-value}"
}

cntools_detail_address_type_rows() {
  local address="$1" prefix="${2:-}" facts='' label='' value=''
  declare -F cntools_address_credentials_into >/dev/null || return 0
  cntools_address_credentials_into facts "${address}" || return 0
  while IFS=$'\037' read -r label value; do
    cntools_detail_pair "${prefix:+${prefix} / }${label}" "${value}" value || return 1
  done < <(jq -r '
    (if .payment then ["Payment credential type",.payment.type] else empty end),
    (if .stake then ["Stake credential type",.stake.type] else empty end),
    (if .credential then ["Credential type",.credential.type] else empty end),
    (if .stakeReference then ["Stake reference type",.stakeReference] else empty end) |
    join("\u001f")' <<< "${facts}")
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

cntools_detail_coin_field() {
  local section="$1" context="$2" field="$3"
  case "${section}" in
    Overview) [[ "${field}" =~ ^(value|fee|deposit|treasury_donation|treasuryDonation|treasury\ donation|currentTreasuryValue|current_treasury_value|totalCollateral|total_collateral|total\ collateral|total_output)$ ]] ;;
    Record|inputs|outputs|collateral_inputs|collateral_output|reference_inputs) [[ "${field}" == value ]] ;;
    ListRecord)
      if [[ "${context}" == withdrawals ]]; then [[ "${field}" =~ ^(amount|value|lovelace)$ ]]
      elif [[ "${context}" =~ ^(certificates|proposal_procedures|governance\ actions)$ ]]; then
        [[ "${field##* / }" =~ ^(deposit|refund|cost|pledge)$ ]]
      else return 1; fi ;;
    *) return 1 ;;
  esac
}

# Input/output records are already isolated, so paths never repeat the I/O
# ordinal or payment address. Optional nulls and empty structures stay hidden.
cntools_detail_tree_rows() {
  local file="$1" section="$2" path="" type="" value="" role="value" formatted=""
  local decimals="${3:-}" context="${4:-}" credential_path=''
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
    elif cntools_detail_coin_field "${section}" "${context}" "${path}" &&
         { [[ "${value}" =~ ^-?[0-9]+$ ]] || [[ "${value}" =~ ^-?[0-9]+[[:space:]]+[Ll]ovelace$ ]]; }; then
      value="${value%% *}"
      if [[ "${value}" == -* ]]; then
        value="-$(cntools_number_format_lovelace "${value#-}")"
      else
        value="$(cntools_number_format_lovelace "${value}")"
      fi
      role=number
    elif [[ "${type}" == number || ( "${section}" != metadata &&
            ( "${path}" == *quantity || ( "${context}" == mint && "${path}" == 'asset '* ) ||
              "${path##* / }" =~ ^(deposit|refund|cost|pledge|tx_index|cert_index|index|epoch|port)$ ) &&
            "${value}" =~ ^-?[0-9]+$ ) ]]; then
      cntools_number_format_into formatted "${value}" && value="${formatted}"
      role=number
    elif [[ "${path}" =~ (hash|fingerprint|address|bech32|cred|policy_id|asset_name)$ ]]; then
      role=identifier
    elif [[ "${path}" == Credential || "${path}" == *' / Credential' ]]; then
      role=credential
    fi
    if [[ "${section}" == Overview ]]; then
      case "${path}" in
        invalid_before) path='Valid from' ;;
        invalid_after) path='Expires' ;;
        treasuryDonation|treasury_donation|'treasury donation') path='Treasury donation' ;;
        currentTreasuryValue|current_treasury_value) path='Current treasury value' ;;
        totalCollateral|total_collateral|'total collateral') path='Total collateral' ;;
      esac
    elif [[ "${section}" == ListRecord && "${context}" == withdrawals ]]; then
      case "${path}" in
        amount|value|lovelace) path=Amount ;;
        credential) path=Credential; role=credential ;;
        credential_type) path=Type ;;
      esac
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
    credential_path="${path,,}"
    if [[ "${section}" == ListRecord && "${context}" != withdrawals &&
          "${type}" == string && ! "${credential_path}" =~ (^|\ /\ )(metadata|datum|inline[_\ ]datum|data|script[_\ ]data|reference\ script)(\ /|\[|$) &&
          "${credential_path}" =~ (address|bech32|stake_addr|stake_address|reward_addr|reward[_\ ]account|reward_account_bech32|drep_id|voter|voter_id|pool_id|pool_id_bech32)$ ]]; then
      cntools_detail_address_type_rows "${value}" "${path}" || return 1
    fi
  done < <(jq -r --arg section "${section}" --arg decimals "${decimals}" '
    def clean: tostring | gsub("[\u0000-\u001f\u007f]";" ");
    def network_field: ascii_downcase | gsub("[ _-]";"") |
      IN("network","networkid","networkname","networktype","networkmagic");
    def opaque_path: test("(^| / )(metadata|datum|inline[_ ]datum|data|script[_ ]data|reference script)( /|\\[|$)";"i");
    def leaves($path):
      if . == null or . == [] or . == {} then empty
      elif type == "object" and length > 0 then
        (if $section != "Asset" and (.policy_id? | type == "string") and (.asset_name? | type == "string")
          then [$path,"asset",tojson] else empty end),
        (if $section!="Asset" and $section!="metadata" and ($path|opaque_path|not) and
            (keys==["keyHash"] or keys==["scriptHash"]) and
            (.[keys[0]] | type=="string" and test("^[0-9a-fA-F]{56}$")) then
           {Credential:.[keys[0]],Type:(if has("keyHash") then "Key" else "Script" end)}
         else . end | to_entries[] | .key as $key |
         select($section=="Asset" or $section=="metadata" or ($path|opaque_path) or ($key|network_field|not)) |
         .value | leaves(if $path == "" then $key else $path + " / " + $key end))
      elif type == "array" and length > 0 then
        to_entries[] | .key as $key | .value | leaves($path + "[" + (($key+1)|tostring) + "]")
      else [$path,type,(if type == "string" then (if . == "" then "(empty string)" else . end) else tojson end)] end;
    def absent_optional_zero:
      (.key | IN("treasuryDonation","treasury_donation","treasury donation",
        "currentTreasuryValue","current_treasury_value","totalCollateral","total_collateral","total collateral")) and
      (.value == 0 or .value == "0" or .value == "0 Lovelace");
    (if $section == "Overview" then with_entries(select((.value | type != "array" and type != "object") and (absent_optional_zero|not)))
     elif $section == "Record" then del(.payment_addr,.payment_cred,.address,.asset_list,.is_spent)
     elif $section == "ListRecord" then del(.asset_list)
     elif $section == "Asset" then
       if $decimals != "" then .decimals=($decimals|tonumber) else . end
     else .[$section] end) |
    leaves("") | map(clean) | join("\u001f")
  ' "${file}")
}

# Koios supplies reward addresses; the CLI also supplies explicit key/script
# hashes. Decode locally with the shared checksum-validating codec, never infer
# a script credential from its name or issue a chain query while rendering.
cntools_detail_withdrawal_rows() {
  local withdrawal_record="$1" withdrawal_address="$2" withdrawal_key='' withdrawal_script=''
  local withdrawal_credential=Unavailable withdrawal_type=Unknown withdrawal_facts=''
  IFS=$'\037' read -r withdrawal_key withdrawal_script < <(jq -r '
    [.["stake credential key hash"] // "", .["stake credential script hash"] // ""] |
    join("\u001f")' <<< "${withdrawal_record}")
  if [[ "${withdrawal_key}" =~ ^[0-9a-fA-F]{56}$ && -z "${withdrawal_script}" ]]; then
    withdrawal_credential="${withdrawal_key,,}"; withdrawal_type=Key
  elif [[ "${withdrawal_script}" =~ ^[0-9a-fA-F]{56}$ && -z "${withdrawal_key}" ]]; then
    withdrawal_credential="${withdrawal_script,,}"; withdrawal_type=Script
  fi
  if declare -F cntools_address_credentials_into >/dev/null &&
     cntools_address_credentials_into withdrawal_facts "${withdrawal_address}" &&
     jq -e '.stake != null' <<< "${withdrawal_facts}" >/dev/null; then
    IFS=$'\037' read -r withdrawal_credential withdrawal_type < <(jq -r '
      [.stake.hash // "Unavailable", .stake.type // "Unknown"] | join("\u001f")' <<< "${withdrawal_facts}")
  fi
  cntools_detail_tree_rows <(jq --arg credential "${withdrawal_credential}" --arg type "${withdrawal_type}" '
    {amount:(.amount // .value // .lovelace // .Value // "Unavailable"), credential:$credential, credential_type:$type}
  ' <<< "${withdrawal_record}") ListRecord '' withdrawals
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
  local record="$1" title="$2" address=''
  address="$(jq -r '((try .payment_addr.bech32 catch null) // .address // "") | select(type=="string")' <<< "${record}")" || return 1
  {
    cntools_detail_tree_rows <(printf '%s\n' "${record}") Record || return 1
    cntools_detail_address_type_rows "${address}" || return 1
  } | cntools_table_render "${title}" || return 1
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

# Every list/map collection uses separate records, not a single table whose
# labels repeat [1]/[2]. Address/type/ID fields identify a record in its heading.
# Scalar entries retain their value; arbitrary future fields stay inspectable.
cntools_detail_list_render() {
  local file="$1" section="$2" title="$3" entry='' record='' label='' heading='' formatted='' index=0
  local last_heading_only=N voter_kind='' label_facts='{}'
  local CNTOOLS_TABLE_TITLE_ROLE=identifier
  if [[ "${section}" == required_signers || "${section}" == 'required signers (payment key hashes needed for scripts)' ]] &&
     jq -e --arg section "${section}" '.[$section] | type=="array" and length>0 and all(.[]; type=="string" and test("^[0-9a-fA-F]{56}$"))' "${file}" >/dev/null; then
    title+=' · Key credentials'
  fi
  cntools_table_heading "━━ ${title} ━━" accent || return 1
  while IFS= read -r entry; do
    index=$((index+1))
    label="$(jq -r '.label' <<< "${entry}")" || return 1
    record="$(jq -c '.record' <<< "${entry}")" || return 1
    cntools_text_sanitize_into label "${label}" || return 1
    cntools_number_format_into formatted "${index}" || return 1
    heading="${formatted}${label:+ · ${label}}"
    label_facts='{}'
    if declare -F cntools_address_credentials_into >/dev/null; then
      cntools_address_credentials_into label_facts "${label}" || label_facts='{}'
    fi
    if [[ "${section}" == withdrawals ]]; then
      last_heading_only=N
      cntools_detail_withdrawal_rows "${record}" "${label}" | cntools_table_render "${heading}" || return 1
    elif [[ "${label_facts}" != '{}' ]] || jq -e 'any(..; type!="object" and type!="array" and .!=null)' <<< "${record}" >/dev/null; then
      last_heading_only=N
      {
        cntools_detail_tree_rows <(printf '%s\n' "${record}") ListRecord '' "${section}" || return 1
        cntools_detail_address_type_rows "${label}" || return 1
        if [[ "${section}" =~ ^(voters|voting_procedures|votes)$ &&
              "${label}" =~ ^(drep|committee-hot|stakepool)-(key|script)Hash-([0-9a-fA-F]{56})$ ]]; then
          voter_kind="${BASH_REMATCH[2]}"
          cntools_detail_pair Credential "${BASH_REMATCH[3]}" credential || return 1
          case "${voter_kind}" in key) cntools_detail_pair 'Credential type' Key ;; script) cntools_detail_pair 'Credential type' Script ;; esac
        fi
      } |
        cntools_table_render "${heading}" || return 1
    else
      last_heading_only=Y
      cntools_table_heading "${heading}" identifier || return 1
    fi
    cntools_detail_assets_render "${record}" || return 1
  done < <(jq -c --arg section "${section}" '
    def populated: . != null and . != [] and . != {};
    def record($key):
      if $key=="" and type=="string" and test("^[0-9a-fA-F]{56,64}$|^(addr|stake|pool|drep|asset)[a-z0-9_]*1[a-z0-9]+$") then
        {label:.,record:{}}
      elif type != "object" then {label:$key,record:{Value:.}}
      elif $key != "" then {label:$key,record:.}
      else
        . as $item |
        (["address","stake_addr","stake_address","reward_addr","pool_id","poolId",
          "drep_id","voter_id","voter","voter_hex","gov_action_id","proposal_id","action_id",
          "tx_hash","hash","type","cert_type","certificate_type","name"] |
          map(. as $field | select($item[$field] | type=="string" and length>0)) | .[0]) as $field |
        if $field != null then {label:$item[$field],record:($item|del(.[$field]))}
        elif length==1 and ((to_entries[0].value|type)=="object" or to_entries[0].value==null) then
          to_entries[0] | {label:.key,record:.value}
        else {label:"",record:.} end
      end;
    .[$section] |
    if type=="array" then .[] | select(populated) | record("")
    elif type=="object" then to_entries[] | select(.value|populated) | .key as $key | .value | record($key)
    else empty end
  ' "${file}")
  # Tables already end with a blank line. Match their section gap when the
  # final record is only a heading, without adding gaps between scalar IDs.
  if [[ "${last_heading_only}" == Y ]]; then printf '\n'; fi
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
        case "${section}" in
          withdrawals) title=Withdrawals ;;
          certificates) title=Certificates ;;
          voting_procedures|voters|votes) title=Votes ;;
          proposal_procedures|'governance actions') title='Governance proposals' ;;
          required_signers|'required signers (payment key hashes needed for scripts)') title='Required signers' ;;
          mint) title='Mint / burn' ;;
          scripts|'auxiliary scripts') title=Scripts ;;
          witnesses) title=Witnesses ;;
        esac
        cntools_detail_list_render "${file}" "${section}" "${title}"
        ;;
    esac || return 1
  done < <(jq -c '
    . as $tx |
    (["inputs","outputs"] + [keys_unsorted[] | select(. != "inputs" and . != "outputs")])[] as $key |
    select($key | ascii_downcase | gsub("[ _-]";"") |
      IN("network","networkid","networkname","networktype","networkmagic") | not) |
    select($tx[$key] | (type == "array" or type == "object") and length > 0) |
    select($key=="metadata" or ($tx[$key] | if type=="array" then . else [.[]] end |
      any(. != null and . != [] and . != {}))) | $key
  ' "${file}")
}


