#!/usr/bin/env bash
# Only read-only routes. No submission, implicit endpoint or credentials in logs.
# shellcheck disable=SC2034
ck_http() {
  local url="$1" method="$2" payload="$3" output="$4" authenticated="${5:-Y}" status=0 code='' auth=''
  local errors="$CK_WORK/http-errors-$BASHPID" redacted="$CK_WORK/redacted-$BASHPID"
  local -a args=(curl --disable --silent --show-error --connect-timeout "$CK_TIMEOUT" --max-time "$CK_TIMEOUT"
    --max-filesize 33554432 --request "$method" --header 'accept: application/json' --output "$output" --write-out '%{http_code}')
  if [[ -n "$payload" ]]; then
    printf '%s' "$payload" > "$CK_CASE_DIR/request.json"
    args+=(--header 'content-type: application/json' --data-binary "@$CK_CASE_DIR/request.json")
  fi
  if [[ "$authenticated" == Y && -n "$CK_TOKEN" ]]; then
    [[ "$CK_TOKEN" != *$'\n'* && "$CK_TOKEN" != *$'\r'* ]] || { ck_note 'API token contains a line break'; return 1; }
    auth="$CK_WORK/auth-$BASHPID"
    printf 'Authorization: Bearer %s\n' "$CK_TOKEN" > "$auth"
    args+=(--header "@$auth")
  fi
  args+=(--url "$url")
  { printf 'curl --disable --request %q --url %q' "$method" "$url"
    [[ -z "$payload" ]] || printf ' --header %q --data-binary %q' 'content-type: application/json' "$payload"
    [[ -z "$auth" ]] || printf ' --header %q' 'Authorization: Bearer <KOIOS_API_TOKEN>'
    printf '\n'; } > "$CK_CASE_DIR/request.txt"
  sleep "$CK_DELAY"
  "${args[@]}" > "$CK_CASE_DIR/http-status.txt" 2> "$errors" || status=$?
  code="$(< "$CK_CASE_DIR/http-status.txt")"
  # Do not persist authentication material, even if a proxy echoes it on error.
  if [[ -n "$CK_TOKEN" ]]; then
    local line=''
    for auth in "$output" "$errors"; do
      [[ -f "$auth" ]] || continue
      : > "$redacted"
      while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\n' "${line//"$CK_TOKEN"/<REDACTED>}"; done < "$auth" > "$redacted"
      cp "$redacted" "$auth" || return 1
    done
  fi
  cp "$errors" "$CK_CASE_DIR/http-errors.log" || return 1
  printf 'HTTP %s · curl %s · %s %s\n' "$code" "$status" "$method" "$url"
  if (( status != 0 )); then
    sed -n '1,5p' "$CK_CASE_DIR/http-errors.log"
    if (( status == 2 || status == 3 )); then ck_note 'curl argument/URL compatibility failure'; return 1; fi
    ck_block 'Transport/TLS/timeout failure; endpoint compatibility not established'; return 78
  fi
  case "$code" in
    2??) ;;
    401|403|408|429|5??) ck_block "HTTP $code: authentication, rate limit or service availability problem"; return 78 ;;
    *) ck_note "Unexpected HTTP $code; inspect request.txt and response"; return 1 ;;
  esac
}
ck_api() {
  [[ -n "$CK_KOIOS" ]] || { ck_block 'Supply --koios explicitly; no API endpoint is contacted by default'; return 78; }
  ck_http "$CK_KOIOS/$1" "$2" "$3" "$CK_CASE_DIR/response.json" || return
  if [[ "$1" == cli_protocol_params ]]; then ck_protocol "$CK_CASE_DIR/response.json"
  else ck_assert "$CK_CASE_DIR/response.json" 'type=="array"' 'Koios JSON array response'; fi
}
ck_koios_check() {
  local kind="$1" value='' payload='' route="$1" method=POST expression='' out="$CK_CASE_DIR/response.json" hex='' status=0
  local address_select='?select=address%2Cbalance%3A%3Atext%2Cutxo_set'
  local account_select='?select=stake_address%2Cstatus%2Cdelegated_pool%2Cdelegated_drep%2Crewards_available%3A%3Atext%2Cdeposit%3A%3Atext'
  case "$kind" in
    tip) method=GET; expression='length==1 and all(.[]; (.epoch_no|type=="number" and .>=0 and floor==.) and (.abs_slot|type=="number") and (.block_no|type=="number") and (.block_time|type=="number"))' ;;
    cli_protocol_params) method=GET ;;
    committee_info) method=GET; expression='length<=1 and all(.[]; (.quorum_numerator|type=="number" and .>=0 and floor==.) and (.quorum_denominator|type=="number" and .>0 and floor==.) and .quorum_numerator<=.quorum_denominator and (.members|type=="array"))' ;;
    address_info|address_utxos)
      value="$(ck_lookup address '^addr(_test)?1[0-9a-z]+$')" || { ck_note "$value"; return 77; }
      payload="$(jq -nc --arg a "$value" '{_addresses:[$a]}')"
      if [[ "$kind" == address_info ]]; then route+="$address_select"; expression="all(.[]; .address==\"$value\" and (.balance|type==\"string\" and test(\"^[0-9]+$\")) and (.utxo_set|type==\"array\"))"
      else route+='?select=tx_hash%2Ctx_index%2Caddress%2Cvalue%3A%3Atext%2Casset_list%2Cdatum_hash%2Cinline_datum%2Creference_script'; payload="$(jq -c '.+{_extended:true}' <<< "$payload")"; fi ;;
    account_info|account_txs|account_utxos)
      value="$(ck_lookup stake_address '^stake(_test)?1[0-9a-z]+$')" || { ck_note "$value"; return 77; }
      payload="$(jq -nc --arg a "$value" '{_stake_addresses:[$a]}')"
      case "$kind" in
        account_info) route+="$account_select"; expression="length<=1 and all(.[]; .stake_address==\"$value\" and (.status==\"registered\" or .status==\"not registered\") and (.rewards_available|type==\"string\" and test(\"^[0-9]+$\")))" ;;
        account_txs) route="account_txs?_stake_address=$value"; payload=''; method=GET ;;
        account_utxos) route+='?is_spent=eq.false'; payload="$(jq -c '.+{_extended:true}' <<< "$payload")" ;;
      esac ;;
    credential_txs|credential_utxos)
      value="$(ck_lookup payment_credential '^[0-9a-f]{56}$')" || { ck_note "$value"; return 77; }
      payload="$(jq -nc --arg a "$value" '{_payment_credentials:[$a]}')"
      if [[ "$kind" == credential_utxos ]]; then route+='?is_spent=eq.false'; payload="$(jq -c '.+{_extended:true}' <<< "$payload")"; fi ;;
    tx_info|tx_status)
      value="$(ck_lookup tx_hash '^[0-9a-f]{64}$')" || { ck_note "$value"; return 77; }
      payload="$(jq -nc --arg a "$value" '{_tx_hashes:[$a]}')"
      if [[ "$kind" == tx_info ]]; then payload="$(jq -c '.+{_inputs:true,_metadata:true,_assets:true,_withdrawals:true,_certs:true,_scripts:true,_bytecode:true,_governance:true}' <<< "$payload")"
      else expression="length<=1 and all(.[]; .tx_hash==\"$value\" and has(\"num_confirmations\") and (.num_confirmations==null or (.num_confirmations|type==\"number\" and .>=0 and floor==.)))"; fi ;;
    pool_info|pool_calidus_keys)
      value="$(ck_lookup pool_id '^pool1[0-9a-z]+$')" || { ck_note "$value"; return 77; }
      if [[ "$kind" == pool_info ]]; then payload="$(jq -nc --arg a "$value" '{_pool_bech32_ids:[$a]}')"
      else route="pool_calidus_keys?pool_id_bech32=eq.$value&select=pool_id_bech32%2Ccalidus_nonce%3A%3Atext%2Ccalidus_pub_key%2Ccalidus_id_bech32%2Ctx_hash%2Cregistered"; method=GET
        expression="length<=1 and all(.[]; .pool_id_bech32==\"$value\" and (.calidus_nonce|type==\"string\" and test(\"^[0-9]+$\")) and (.calidus_pub_key|test(\"^[0-9a-f]{64}$\")) and (.tx_hash|test(\"^[0-9a-f]{64}$\")) and (.registered|type==\"boolean\"))"; fi ;;
    drep_info)
      value="$(ck_lookup drep_id '^drep1[0-9a-z]+$')" || { ck_note "$value"; return 77; }
      payload="$(jq -nc --arg a "$value" '{_drep_ids:[$a]}')" ;;
    asset_info|asset_utxos|asset_history)
      value="$(ck_lookup asset '^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$')" || { ck_note "$value"; return 77; }
      payload="$(jq -nc --arg p "${value%%.*}" --arg a "${value#*.}" '{_asset_list:[[$p,$a]]}')"
      case "$kind" in
        asset_info) route+='?select=policy_id%2Casset_name%2Casset_name_ascii%2Cfingerprint%2Ctotal_supply%2Cregistry_metadata%3Atoken_registry_metadata%2Cmetadata_20%3Aminting_tx_metadata-%3E%2220%22%2Cmetadata_721%3Aminting_tx_metadata-%3E%22721%22%2Ccip68_metadata'
          expression="length==1 and all(.[]; .policy_id==\"${value%%.*}\" and .asset_name==\"${value#*.}\" and (.fingerprint|type==\"string\") and (.total_supply|type==\"string\" and test(\"^[0-9]+$\")) and all(.registry_metadata,.metadata_20,.metadata_721,.cip68_metadata; .==null or type==\"object\"))" ;;
        asset_utxos) payload="$(jq -c '.+{_extended:true}' <<< "$payload")"; expression='all(.[]; (.tx_hash|type=="string" and test("^[0-9a-f]{64}$")) and (.tx_index|type=="number") and (.address|type=="string") and (.value|type=="string") and (.asset_list|type=="array"))' ;;
        asset_history) route="asset_history?_asset_policy=${value%%.*}&_asset_name=${value#*.}"; method=GET; payload=''; expression='all(.[]; (.minting_txs|type=="array"))' ;;
      esac ;;
    proposal_list)
      local epoch=''
      ck_api tip GET '' || return
      epoch="$(jq -er '.[0].epoch_no|select(type=="number" and .>=0 and floor==.)' "$out")" || return 1
      cp "$out" "$CK_CASE_DIR/tip.json" || return
      route="proposal_list?expiration=gte.$epoch&enacted_epoch=is.null&dropped_epoch=is.null&expired_epoch=is.null&limit=500&offset=0"; method=GET
      ck_api "$route" "$method" '' || return
      cntools_proposals_parse "$out" koios "$epoch" || return 1
      ck_nonempty "$out"; return ;;
    proposal_votes|proposal_voting_summary)
      value="$(ck_lookup proposal_id '^gov_action1[0-9a-z]+$')" || { ck_note "$value"; return 77; }
      if [[ "$kind" == proposal_votes ]]; then
        local drep='' canonical='' identity_kind=''
        drep="$(ck_lookup drep_id '^drep1[0-9a-z]+$')" || { ck_note "$drep"; return 77; }
        cntools_drep_id_into canonical identity_kind hex "$drep" || return 1
        local script=false; [[ "$identity_kind" != script ]] || script=true
        route+="?voter_hex=eq.$hex&voter_role=eq.DRep&voter_has_script=eq.$script"
        payload="$(jq -nc --arg a "$value" '{_proposal_id:$a}')"
        expression="all(.[]; .voter_hex==\"$hex\" and .voter_role==\"DRep\" and .voter_has_script==$script and (.vote|IN(\"Yes\",\"No\",\"Abstain\")))"
      else route+="?_proposal_id=$value"; method=GET
        expression='length<=1 and all(.[]; (.proposal_type|type=="string") and (.epoch_no|type=="number" and .>=0 and floor==.) and (to_entries|all(.[]; if (.key|endswith("_pct")) then (.value==null or (.value|type=="number" and .>=0 and .<=100)) elif (.key|endswith("_power")) then (.value==null or (.value|type=="string" and test("^[0-9]+$"))) elif (.key|endswith("_cast")) then (.value==null or (.value|type=="number" and .>=0 and floor==.)) else true end)))'; fi ;;
    *) return 1 ;;
  esac
  ck_api "$route" "$method" "$payload" || return
  [[ -z "$expression" ]] || ck_assert "$out" "$expression" "$kind consumed fields and identity" || return
  case "$kind" in
    cli_protocol_params) return 0 ;;
    address_info) CK_CAPTURED_RESPONSE="$out"; cntools_wallet_query_reset; cntools_wallet_query_koios_addresses "$value" '' || return 1 ;;
    account_info) CK_CAPTURED_RESPONSE="$out"; cntools_wallet_query_reset; cntools_wallet_query_koios_stake "$value" || return 1 ;;
    asset_info)
      CK_CAPTURED_RESPONSE="$out"; cntools_wallet_query_reset
      cntools_wallet_asset_add "$value" 1 || return 1
      cntools_wallet_query_koios_asset_metadata_batch "$value" || return 1
      printf 'Metadata parsed: source=%s name=%s ticker=%s\n' "${CNTOOLS_WALLET_ASSET_METADATA_SOURCES[$value]:-none}" "${CNTOOLS_WALLET_ASSET_METADATA_NAMES[$value]:-}" "${CNTOOLS_WALLET_ASSET_TICKERS[$value]:-}" ;;
    address_utxos) cntools_utxo_load_koios "$out" "$value" '' || { ck_note "$CNTOOLS_UTXO_ERROR"; return 1; } ;;
    credential_txs|credential_utxos|account_txs|account_utxos)
      local lookup=payment inventory=transactions
      [[ "$kind" != account* ]] || lookup=stake
      [[ "$kind" != *utxos ]] || inventory=utxos
      CK_CAPTURED_RESPONSE="$out"
      cntools_history_load "$inventory" "$value" "$lookup" || return 1 ;;
    tx_info) CK_CAPTURED_RESPONSE="$out"; cntools_history_fetch_transactions "[\"$value\"]" "$CK_CASE_DIR/normalized.json" || return 1 ;;
    pool_info)
      cntools_bech32_decode_into hex "$value" pool || return 1
      cntools_pool_parse_koios "$out" "$value" "$hex" || status=$?
      (( status == 0 || status == 4 )) || return "$status" ;;
    drep_info)
      local canonical='' identity_kind=''
      cntools_drep_id_into canonical identity_kind hex "$value" || return 1
      cntools_drep_parse_koios "$out" "$value" "$identity_kind" "$hex" || status=$?
      (( status == 0 || status == 4 )) || return "$status" ;;
  esac
  ck_nonempty "$out"
}
# Feed the already captured real HTTP response into production parsers. These
# shims replace transport/temp allocation only; no parser or response is mocked.
cntools_wallet_query_temp_file() { local -n ck_temp="$1"; ck_temp="$(mktemp "$CK_WORK/parser.XXXXXX")"; }
cntools_wallet_query_http() { cp "$CK_CAPTURED_RESPONSE" "$3"; }
cntools_asset_details_fetch() { cp "$CK_CAPTURED_RESPONSE" "$1"; }
cntools_wallet_log() { cntools_log "$1" "$2"; }
cntools_transaction_set_error() { ck_note "$1"; return 1; }
cntools_wallet_address_hrp() { [[ "$CK_NETWORK" == mainnet ]] && printf stake || printf stake_test; }
cntools_wallet_bech32_valid() { local decoded=''; cntools_bech32_decode_into decoded "$1" "$2"; }
ck_suite_koios() {
  local CNTOOLS_MODE=light CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API="$CK_KOIOS" kind=''
  for kind in tip cli_protocol_params address_info address_utxos account_info credential_txs account_txs credential_utxos account_utxos tx_info tx_status pool_info drep_info asset_info asset_utxos asset_history proposal_list committee_info proposal_votes proposal_voting_summary pool_calidus_keys; do
    ck_run "koios-$kind" "$kind — request and consumed output" executed ck_koios_check "$kind"
  done
  ck_run koios-submittx 'Koios submission acceptance' integration ck_skip 'Write endpoint is never invoked; requires an isolated funded integration environment.'
  ck_run koios-handle 'Handle/virtual subhandle end-to-end resolution' integration ck_skip 'Endpoint contracts are checked separately; registry, lease and datum resolution still require curated Handle fixtures.'
  ck_run koios-metadata-content 'CIP-25/CIP-68/FT metadata display semantics' integration ck_skip 'asset_info checks the response contract; curated examples for every metadata standard are still required for full display regression coverage.'
}
