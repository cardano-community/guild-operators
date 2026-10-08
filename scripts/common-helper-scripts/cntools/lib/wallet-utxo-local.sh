#!/usr/bin/env bash
# Read-only fallback: known wallet addresses, not stake-credential discovery.
# shellcheck disable=SC2034
cntools_history_local_available() {
  [[ "${CNTOOLS_MODE:-offline}" != offline && "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == true &&
     -x "${CNTOOLS_CLI:-}" ]] && cntools_wallet_query_local_socket_ready
}

cntools_history_load_local() {
  local directory="$1" base='' payment='' raw='' errors='' records='' normalized='' ref='' assets='' identity='' index=0
  cntools_history_local_available || { cntools_history_error 'Neither Koios nor a configured local node is available.'; return 1; }
  cntools_wallet_read_address "${directory}" base base || base=''
  cntools_wallet_read_address "${directory}" payment payment || payment=''
  [[ -n "${base}" || -n "${payment}" ]] || {
    cntools_history_error 'Local lookup needs a saved payment or script address; a stake address alone cannot discover UTxOs.'; return 1;
  }
  [[ -n "${base}" ]] || base="${payment}"
  [[ -n "${payment}" ]] || payment="${base}"
  cntools_wallet_query_network_arguments || return 1
  cntools_wallet_query_temp_file raw && cntools_wallet_query_temp_file errors &&
    cntools_wallet_query_temp_file records && cntools_wallet_query_temp_file normalized || return 1
  local -a arguments=("${CNTOOLS_CLI}" query utxo --address "${base}")
  [[ "${base}" == "${payment}" ]] || arguments+=(--address "${payment}")
  arguments+=("${CNTOOLS_WALLET_NETWORK_ARGS[@]}" --socket-path "${CNTOOLS_SOCKET}" --output-json)
  if ! cntools_wallet_query_run_cli "${raw}" "${errors}" "${arguments[@]}"; then
    cntools_wallet_query_log_failure 'Local UTxO inspection failed' 1 "${errors}" "${raw}"
    cntools_history_error 'The local node could not return the wallet UTxOs.'; return 1
  fi
  # Reuse the transaction inventory parser to preserve exact decimal quantities.
  cntools_utxo_load_local "${raw}" "${base}" "${payment}" || {
    cntools_history_error "${CNTOOLS_UTXO_ERROR}"; return 1;
  }
  : > "${records}"
  for index in "${!CNTOOLS_UTXO_REFS[@]}"; do
    ref="${CNTOOLS_UTXO_REFS[index]}"; assets='[]'
    while IFS= read -r identity; do
      [[ -n "${identity}" ]] || continue
      assets="$(jq -c --arg policy "${identity%%.*}" --arg name "${identity#*.}" \
        --arg quantity "${CNTOOLS_UTXO_ASSET_QUANTITIES[${index}|${identity}]}" \
        '. + [{policy_id:$policy,asset_name:$name,quantity:$quantity}]' <<< "${assets}")" || return 1
    done <<< "${CNTOOLS_UTXO_ASSET_LISTS[index]}"
    jq -c --arg ref "${ref}" --arg value "${CNTOOLS_UTXO_LOVELACE[index]}" --argjson assets "${assets}" '
      .[$ref] | {tx_hash:($ref|split("#")[0]),tx_index:($ref|split("#")[1]|tonumber),
        address, value:$value,asset_list:$assets,is_spent:false,
        datum_hash:(.datumhash // .inlineDatumhash),inline_datum:.inlineDatum,reference_script:.referenceScript}
    ' "${raw}" >> "${records}" || return 1
  done
  jq -s 'sort_by(.tx_hash,.tx_index)' "${records}" > "${normalized}" || return 1
  CNTOOLS_HISTORY_LIST="${normalized}" CNTOOLS_HISTORY_TOTAL="${#CNTOOLS_UTXO_REFS[@]}"
  CNTOOLS_HISTORY_BACKEND=local CNTOOLS_HISTORY_LOOKUP=addresses CNTOOLS_HISTORY_KIND=utxos
  CNTOOLS_HISTORY_PAGE=0 CNTOOLS_HISTORY_PAGES=() CNTOOLS_HISTORY_ERROR=''
  cntools_wallet_log WALLET "Local UTxO inspection scope=known-addresses count=${CNTOOLS_HISTORY_TOTAL}"
}
