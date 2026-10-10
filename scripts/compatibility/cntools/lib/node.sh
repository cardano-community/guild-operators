#!/usr/bin/env bash
# Read-only queries against an explicitly supplied socket.
# shellcheck disable=SC2034
ck_node_exec() {
  [[ -n "$CK_SOCKET" && -S "$CK_SOCKET" ]] || { ck_block 'Supply --socket with a reachable node socket'; return 78; }
  local status=0
  ck_cli "$1" "${@:2}" "${CK_NET[@]}" --socket-path "$CK_SOCKET" || status=$?
  if (( status != 0 )); then
    if (( status == 124 )) || grep -Eqi 'Network.Socket|connect:|connection refused|does not exist|MuxError|HandshakeError' "$CK_WORK/stderr-$BASHPID"; then
      ck_block 'Node connection/handshake unavailable; command compatibility was not established'; return 78
    fi
  fi
  return "$status"
}
ck_node_version() {
  [[ -n "$CK_NODE" && -x "$CK_NODE" ]] || { ck_skip 'Optional: supply --node to record its version'; return 77; }
  ck_exec "$CK_WORK/node-version" N "$CK_NODE" --version || return
  grep -F cardano-node "$CK_WORK/node-version" >/dev/null || { ck_note 'Unrecognized node version output'; return 1; }
  sed -n '1,3p' "$CK_WORK/node-version"
}
ck_node_query() {
  local kind="$1" value='' hex='' status=0 out="$CK_CASE_DIR/response.json"
  case "$kind" in
    tip)
      ck_node_exec "$out" latest query tip || return
      ck_assert "$out" 'type=="object" and (.epoch|type=="number" and .>=0 and floor==.) and (.slot|type=="number" and .>=0 and floor==.) and (.block|type=="number" and .>=0 and floor==.)' 'Tip epoch, slot and block' ;;
    protocol)
      ck_node_exec "$out" latest query protocol-parameters --output-json || return
      ck_protocol "$out" ;;
    utxo|legacy-utxo)
      value="$(ck_lookup address '^addr(_test)?1[0-9a-z]+$')" || { ck_note "$value"; return 77; }
      if [[ "$kind" == utxo ]]; then ck_node_exec "$out" latest query utxo --address "$value" --output-json || return
      else ck_node_exec "$out" query utxo --address "$value" --output-json || return; fi
      cntools_utxo_load_local "$out" "$value" '' || { ck_note "CNTools UTxO parser rejected node output: $CNTOOLS_UTXO_ERROR"; return 1; }
      (( ${#CNTOOLS_UTXO_REFS[@]} > 0 )) || { ck_skip 'Empty inventory is valid, but non-empty UTxO output compatibility remains unexercised. Use a funded public address.'; return 77; } ;;
    stake)
      value="$(ck_lookup stake_address '^stake(_test)?1[0-9a-z]+$')" || { ck_note "$value"; return 77; }
      ck_node_exec "$out" query stake-address-info --address "$value" || return
      ck_assert "$out" 'type=="array" and all(.[]; (.address|type=="string") and (.rewardAccountBalance|type=="number" and .>=0 and floor==.))' 'Stake reward and registration records' || return
      ck_assert "$out" "all(.[]; .address==\"$value\")" 'Exact requested stake identity' || return
      ck_nonempty "$out" ;;
    pool)
      value="$(ck_lookup pool_id '^pool1[0-9a-z]+$')" || { ck_note "$value"; return 77; }
      cntools_bech32_decode_into hex "$value" pool || return 1
      ck_node_exec "$out" latest query pool-state --stake-pool-id "$value" --output-json || return
      cntools_pool_parse_local "$out" "$value" "$hex" || status=$?
      (( status != 4 )) || { ck_skip 'Pool absent; registered pool response not exercised'; return 77; }
      return "$status" ;;
    drep)
      value="$(ck_lookup drep_id '^drep1[0-9a-z]+$')" || { ck_note "$value"; return 77; }
      local canonical='' identity_kind='' flag=--drep-key-hash
      cntools_drep_id_into canonical identity_kind hex "$value" || return 1
      [[ "$identity_kind" != script ]] || flag=--drep-script-hash
      ck_node_exec "$out" latest query drep-state "$flag" "$hex" --output-json || return
      cntools_drep_parse_local "$out" "$identity_kind" "$hex" || status=$?
      (( status != 4 )) || { ck_skip 'DRep absent; registered DRep response not exercised'; return 77; }
      return "$status" ;;
    governance)
      ck_node_exec "$CK_CASE_DIR/tip.json" latest query tip || return
      ck_node_exec "$out" latest query gov-state --output-json || return
      value="$(jq -er '.epoch|select(type=="number" and .>=0 and floor==.)' "$CK_CASE_DIR/tip.json")" || return 1
      cntools_proposals_parse "$out" local "$value" || return 1
      [[ "$CNTOOLS_PROPOSALS" != '[]' ]] || { ck_skip 'Valid empty proposal catalog; proposal record shape not exercised'; return 77; } ;;
  esac
}
ck_protocol() {
  ck_assert "$1" 'type=="object" and all(.txFeeFixed,.txFeePerByte,.utxoCostPerByte,.stakeAddressDeposit,.stakePoolDeposit,.dRepDeposit,.maxTxSize,.maxValueSize; type=="number" and .>=0 and floor==.) and (.protocolVersion|type=="object")' 'Conway fee, size, minimum-ADA and deposit parameters'
}
ck_nonempty() {
  [[ "$(jq length "$1")" != 0 ]] || { ck_skip 'Successful empty response. Non-empty record compatibility is not exercised; choose an existing public fixture.'; return 77; }
}
ck_metrics() {
  [[ -n "$CK_METRICS" ]] || { ck_skip 'Supply --metrics with the explicit node Prometheus URL'; return 77; }
  ck_http "$CK_METRICS" GET '' "$CK_CASE_DIR/metrics.txt" N || return
  local metric='' value='' content=''; content="$(< "$CK_CASE_DIR/metrics.txt")"
  for metric in epoch blockNum slotNum; do
    value="$(cntools_health_prometheus_value "$content" "cardano_node_metrics_${metric}_int")"
    cntools_health_nonnegative_integer "$value" >/dev/null || { printf 'Missing/incompatible node metric: cardano_node_metrics_%s_int\n' "$metric"; return 1; }
  done
}
ck_suite_node() {
  ck_run node-version 'Optional node version' executed ck_node_version
  local kind=''
  for kind in tip protocol utxo legacy-utxo stake pool drep governance; do
    ck_run "node-$kind" "$kind — query and output contract" executed ck_node_query "$kind"
  done
  ck_run node-metrics 'Node health metrics consumed by CNTools' executed ck_metrics
  ck_run node-kes 'KES-period query with real operational certificate' integration ck_skip 'Requires the operator opcert; real deployment/key files are deliberately not loaded.'
}
