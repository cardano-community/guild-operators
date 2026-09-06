#!/usr/bin/env bash
# Koios-backed ownership/virtual resolution. No Handle API or profile redirects.
# Bootstrap/syntax reviewed against @koralabs/kora-labs-common 6.9.2 and
# api.handle.me c74262fc69e24131e668bf72e88580b8c95b3dba. Registry datum verified
# on preview 2026-09-05. The bootstrap identity is the same on all three networks.
# shellcheck disable=SC2034
CNTOOLS_HANDLE_ERROR=""
CNTOOLS_HANDLE_ROOT_POLICY=f0ff48bbb7bbe9d59a40f1ce90e9e9d0ff5002ec48f232b49ca0fb9a
CNTOOLS_HANDLE_REGISTRY_ASSET=000de14068616e646c655f706f6c6963696573

cntools_handle_fail() { CNTOOLS_HANDLE_ERROR="$1"; return 1; }

cntools_handle_tip_into() {
  local -n hd_tip_ref="$1"
  local hd_tip_file="" hd_now="" hd_time="" hd_tip_slot=""
  cntools_transaction_temp_file hd_tip_file handle-tip || return 1
  cntools_funding_get "${CNTOOLS_KOIOS_API%/}/tip" "${hd_tip_file}" || {
    cntools_handle_fail 'Koios tip query failed; no Handle destination was accepted.'; return 1;
  }
  hd_tip_slot="$(jq -er 'select(length == 1) | .[0].abs_slot | select(type == "number" and . >= 0 and . <= 9007199254740991) | tostring' "${hd_tip_file}")" || return 1
  hd_time="$(jq -er '.[0].block_time | select(type == "number" and . >= 0) | tostring' "${hd_tip_file}")" || return 1
  printf -v hd_now '%(%s)T' -1
  [[ "${hd_tip_slot}" =~ ^[0-9]+$ && "${hd_time}" =~ ^[0-9]{1,12}$ ]] || return 1
  (( hd_now - hd_time <= 300 && hd_time <= hd_now + 30 )) || {
    cntools_handle_fail 'Koios tip is stale or the system clock is incorrect. Handle lookup was not accepted.'; return 1;
  }
  hd_tip_ref="${hd_tip_slot}"
}

cntools_handle_registry_into() {
  local -n hd_policies_ref="$1" hd_registry_ref="$2"
  local hd_registry_file="" hd_registry_payload="" hd_count=""
  cntools_transaction_temp_file hd_registry_file handle-registry || return 1
  hd_registry_payload="$(jq -cn --arg p "${CNTOOLS_HANDLE_ROOT_POLICY}" --arg a "${CNTOOLS_HANDLE_REGISTRY_ASSET}" '{_asset_list:[[$p,$a]],_extended:true}')"
  cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/asset_utxos" "${hd_registry_payload}" "${hd_registry_file}" || {
    cntools_handle_fail 'The Handle policy registry could not be queried.'; return 1;
  }
  hd_count="$(jq -er --arg p "${CNTOOLS_HANDLE_ROOT_POLICY}" --arg a "${CNTOOLS_HANDLE_REGISTRY_ASSET}" '
    select(type == "array" and length == 1) | .[0] |
    select(.is_spent == false and (.tx_hash | test("^[0-9a-f]{64}$")) and
      (.tx_index | type == "number" and . >= 0 and . <= 65535)) |
    [.asset_list[] | select(.policy_id == $p and .asset_name == $a)] |
    select(length == 1 and (.[0].quantity | tostring) == "1") | length' "${hd_registry_file}")" || {
    cntools_handle_fail 'The authenticated Handle registry is missing, ambiguous or malformed on this network.'; return 1;
  }
  [[ "${hd_count}" == 1 ]] || return 1
  hd_policies_ref="$(jq -ce '
    .[0].inline_datum.value | (.list[0] // .) | .map |
    select(type == "array" and length > 0 and length <= 16) |
    map({policy:.k.bytes, first:.v.list[0].int, last:.v.list[1].int, sunset:.v.list[2].int}) |
    select(all(.[]; (.policy | type == "string" and test("^[0-9a-f]{56}$")) and
      ([.first,.last,.sunset] | all(.[]; type == "number" and . >= 0 and . <= 9007199254740991 and floor == .)) and
      (.last == 0 or .last >= .first))) |
    select((map(.policy) | unique | length) == length)' "${hd_registry_file}")" || {
    cntools_handle_fail 'Unsupported or malformed Handle registry datum. No fallback policies were used.'; return 1;
  }
  hd_registry_ref="$(jq -r '.[0] | .tx_hash + "#" + (.tx_index|tostring)' "${hd_registry_file}")"
}

cntools_handle_mint_window() {
  local hd_policy="$1" hd_asset="$2" hd_first="$3" hd_last="$4"
  local hd_history="" hd_times="" hd_time="" hd_mint_slot=""
  (( hd_first != 0 || hd_last != 0 )) || return 0
  cntools_transaction_temp_file hd_history handle-history || return 1
  cntools_funding_get "${CNTOOLS_KOIOS_API%/}/asset_history?_asset_policy=${hd_policy}&_asset_name=${hd_asset}" "${hd_history}" || return 1
  hd_times="$(jq -er --arg p "${hd_policy}" --arg a "${hd_asset}" '
    select(length == 1) | .[0] | select(.policy_id == $p and .asset_name == $a) |
    .minting_txs | select(type == "array" and length > 0) |
    select(all(.[]; (.quantity | tostring | test("^-?[0-9]+$")) and
      (.block_time | type == "number" and . >= 0 and floor == . and . <= 9007199254740991))) |
    map(select((.quantity | tostring | startswith("-")) | not)) | select(length > 0) |
    .[].block_time | select(type == "number" and . >= 0) | tostring' "${hd_history}")" || return 1
  while IFS= read -r hd_time; do
    [[ "${hd_time}" =~ ^[0-9]{1,12}$ ]] || return 1
    hd_mint_slot="$(cntools_health_reference_slot "${CNTOOLS_NETWORK}" "${hd_time}")" || return 1
    (( hd_mint_slot >= hd_first && (hd_last == 0 || hd_mint_slot <= hd_last) )) || return 1
  done <<< "${hd_times}"
}

# Receives exact handle text; results are an ordinary validated address and
# provenance JSON for the offline package. Never trusts display metadata.
cntools_handle_resolve_into() {
  local -n hd_address_ref="$1" hd_evidence_ref="$2"
  local hd_name="${3:-}" hd_hex="" hd_policies="" hd_registry="" hd_slot=""
  local hd_payload="" hd_response="" hd_info="" hd_candidates="" hd_matches="" hd_selected=""
  local hd_policy="" hd_asset="" hd_first="" hd_last="" hd_address="" hd_ref="" hd_type="" hd_now="" hd_virtual=null
  hd_address_ref=""; hd_evidence_ref=""; CNTOOLS_HANDLE_ERROR=""
  [[ "${CNTOOLS_MODE:-}" != offline && "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && "${CNTOOLS_KOIOS_API:-}" == https://* ]] || {
    cntools_handle_fail 'Handle resolution needs Koios access; direct addresses remain available.'; return 1;
  }
  case "${CNTOOLS_NETWORK:-}" in mainnet|preview|preprod) ;; *) cntools_handle_fail 'Handle resolution is not configured for this network.'; return 1 ;; esac
  cntools_recipient_trim_into hd_name "${hd_name}"
  hd_name="${hd_name#\$}"
  [[ ${#hd_name} -le 28 && "${hd_name}" =~ ^[a-z0-9_.-]+(@[a-z0-9_.-]+)?$ ]] || {
    cntools_handle_fail 'Use an exact lowercase Handle (up to 28 characters), optionally child@parent. No URLs or automatic case conversion.'; return 1;
  }
  cntools_handle_tip_into hd_slot || { [[ -n "${CNTOOLS_HANDLE_ERROR}" ]] || cntools_handle_fail 'Invalid Koios tip response.'; return 1; }
  cntools_handle_registry_into hd_policies hd_registry || return 1
  hd_hex="$(printf '%s' "${hd_name}" | od -An -v -tx1 | tr -d ' \n')" || return 1
  hd_candidates="$(jq -cn --argjson policies "${hd_policies}" --argjson slot "${hd_slot}" --arg name "${hd_hex}" --arg handle "${hd_name}" --arg root "${CNTOOLS_HANDLE_ROOT_POLICY}" '
    [$policies[] | select(.first <= $slot and (.sunset == 0 or .sunset > $slot)) |
      . as $p | ["000de140","00000000", ""][] as $prefix |
      select($prefix != "" or ($p.policy == $root and ($handle | contains("@") | not))) |
      {policy:$p.policy,asset:($prefix+$name),prefix:$prefix,first:$p.first,last:$p.last}]')" || return 1
  [[ "${hd_candidates}" != '[]' ]] || { cntools_handle_fail 'No active Handle policies.'; return 1; }
  hd_payload="$(jq -cn --argjson candidates "${hd_candidates}" '{_asset_list:[$candidates[]|[.policy,.asset]],_extended:true}')"
  cntools_transaction_temp_file hd_response handle-utxos || return 1
  cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/asset_utxos" "${hd_payload}" "${hd_response}" || {
    cntools_handle_fail 'Handle ownership query failed (not a not-found result).'; return 1;
  }
  hd_matches="$(jq -ce --argjson candidates "${hd_candidates}" '
    select(type == "array" and all(.[]; (.is_spent | type == "boolean") and
      (.asset_list | type == "array"))) |
    [.[] | . as $u | select(.is_spent == false) | .asset_list[] | . as $a |
      $candidates[] | select(.policy == $a.policy_id and .asset == $a.asset_name) |
      . + {quantity:($a.quantity|tostring), address:$u.address, tx:$u.tx_hash, index:$u.tx_index,
        datum:$u.inline_datum.value,datumHash:$u.datum_hash}] |
    select(all(.[]; .quantity == "1" and (.address|type == "string") and
      (.tx|type == "string" and test("^[0-9a-f]{64}$")) and
      (.index|type == "number" and floor == . and . >= 0 and . <= 65535)))' "${hd_response}")" || {
    cntools_handle_fail 'Malformed or ambiguous Handle ownership data.'; return 1;
  }
  if [[ "${hd_matches}" == '[]' ]]; then cntools_handle_fail 'Handle not found in the active policy set.'; return 1; fi
  # Official precedence: label 222, virtual, classic. A virtual candidate must
  # never fall through to a classic/parent holding address.
  hd_selected="$(jq -ce '
    if any(.[]; .prefix == "000de140") then map(select(.prefix == "000de140"))
    elif any(.[]; .prefix == "00000000") then map(select(.prefix == "00000000"))
    else map(select(.prefix == "")) end | select(length == 1) | .[0]' <<< "${hd_matches}")" || {
    cntools_handle_fail 'Multiple candidate Handle owners exist. No destination was chosen.'; return 1;
  }
  hd_policy="$(jq -r '.policy' <<< "${hd_selected}")"; hd_asset="$(jq -r '.asset' <<< "${hd_selected}")"
  cntools_transaction_temp_file hd_info handle-supply || return 1
  # Include the registry itself: neither the identity anchor nor the user token
  # may have a duplicated circulating supply.
  hd_payload="$(jq -cn --argjson candidates "${hd_candidates}" --arg rp "${CNTOOLS_HANDLE_ROOT_POLICY}" --arg ra "${CNTOOLS_HANDLE_REGISTRY_ASSET}" '{_asset_list:([($candidates[]|[.policy,.asset]),[$rp,$ra]]|unique)}')"
  cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/asset_info" "${hd_payload}" "${hd_info}" || {
    cntools_handle_fail 'Could not verify Handle supply.'; return 1;
  }
  jq -e --argjson matched "${hd_matches}" --arg rp "${CNTOOLS_HANDLE_ROOT_POLICY}" --arg ra "${CNTOOLS_HANDLE_REGISTRY_ASSET}" '
    . as $rows | (type == "array") and
    all(.[]; (.total_supply|tostring|test("^[0-9]+$"))) and
    all(.[]; . as $row | (.total_supply|tostring) == "0" or
      (.policy_id == $rp and .asset_name == $ra) or
      any($matched[]; .policy == $row.policy_id and .asset == $row.asset_name)) and
    all(([($matched[]|[.policy,.asset]),[$rp,$ra]]|unique)[]; . as $key |
      [$rows[] | select(.policy_id == $key[0] and .asset_name == $key[1])] |
      length == 1 and (.[0].total_supply|tostring) == "1")' "${hd_info}" >/dev/null || {
    cntools_handle_fail 'Handle ownership and supply are incomplete, inconsistent, or not exactly one. No fallback destination was accepted.'; return 1;
  }
  hd_first="$(jq -r '.first' <<< "${hd_selected}")"; hd_last="$(jq -r '.last' <<< "${hd_selected}")"
  cntools_handle_mint_window "${hd_policy}" "${hd_asset}" "${hd_first}" "${hd_last}" || {
    cntools_handle_fail 'Handle mint history could not be verified against its policy window.'; return 1;
  }
  if [[ "$(jq -r '.prefix' <<< "${hd_selected}")" == 00000000 ]]; then
    [[ "${hd_name}" == *@* ]] || { cntools_handle_fail 'A virtual Handle must be a subhandle.'; return 1; }
    cntools_handle_virtual_into hd_address hd_virtual "${hd_selected}" || return 1
  else
    hd_address="$(jq -r '.address' <<< "${hd_selected}")"
  fi
  cntools_recipient_validate "${hd_address}" || {
    cntools_handle_fail 'The Handle points to an unsupported script or wrong-network destination.'; return 1;
  }
  hd_ref="$(jq -r '.tx+"#"+(.index|tostring)' <<< "${hd_selected}")"
  hd_type=classic
  if [[ "${hd_asset}" == 000de140* ]]; then
    hd_type=cip68-root
    [[ "${hd_name}" != *@* ]] || hd_type=nft-subhandle
  fi
  [[ "${hd_virtual}" == null ]] || hd_type=virtual-subhandle
  printf -v hd_now '%(%s)T' -1
  hd_evidence_ref="$(jq -cn --arg name "\$${hd_name}" --arg address "${hd_address}" --arg type "${hd_type}" \
    --arg policy "${hd_policy}" --arg asset "${hd_asset}" --arg utxo "${hd_ref}" --arg registry "${hd_registry}" \
    --arg network "${CNTOOLS_NETWORK}" --arg source "${CNTOOLS_KOIOS_API}" --arg time "${hd_now}" --arg slot "${hd_slot}" \
    --argjson virtual "${hd_virtual}" \
    '{handle:$name,address:$address,type:$type,policy:$policy,asset:$asset,utxo:$utxo,registry:$registry,network:$network,source:$source,queriedAt:$time,tipSlot:$slot} +
      (if $virtual == null then {} else {virtual:$virtual} end)')" || return 1
  hd_address_ref="${hd_address}"
  cntools_transaction_log HANDLE "Resolved ${hd_evidence_ref}"
}
