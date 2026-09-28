#!/usr/bin/env bash
# Read-only, session-scoped Koios inventories. Never query the entire tx history
# with tx_info: fetch only the requested page (or an explicit detail lookup).
# shellcheck disable=SC2034
CNTOOLS_HISTORY_KIND=""
CNTOOLS_HISTORY_LIST=""
CNTOOLS_HISTORY_PAGE_FILE=""
CNTOOLS_HISTORY_DETAIL=""
CNTOOLS_HISTORY_DETAIL_NUMBER=""
CNTOOLS_HISTORY_TOTAL=0
CNTOOLS_HISTORY_SIZE=5
CNTOOLS_HISTORY_PAGE=0
CNTOOLS_HISTORY_WALLET=""
CNTOOLS_HISTORY_LOOKUP="payment"
CNTOOLS_HISTORY_PAYMENT=""
CNTOOLS_HISTORY_STAKE=""
CNTOOLS_HISTORY_ERROR=""
declare -Ag CNTOOLS_HISTORY_PAGES=()

cntools_history_error() {
  CNTOOLS_HISTORY_ERROR="$1"
  cntools_wallet_log ERROR "${CNTOOLS_HISTORY_ERROR}"
  return 1
}

cntools_history_available() {
  [[ "${CNTOOLS_MODE:-offline}" != offline &&
     "${CNTOOLS_KOIOS_ENABLED:-Y}" == Y && "${CNTOOLS_KOIOS_API:-}" == https://* ]]
}

cntools_history_page_size() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [[ -n "${value}" ]] || value=5
  [[ "${value}" =~ ^([1-9]|10)$ ]] || return 2
  CNTOOLS_HISTORY_SIZE="${value}"
}

cntools_history_load() {
  local kind="$1" credential="$2" response="" endpoint="" payload=""
  local lookup="${3:-payment}" method=POST
  cntools_history_available || cntools_history_error "Koios is unavailable. These views require an online Koios connection." || return 1
  case "${lookup}" in
    payment)
      [[ "${credential}" =~ ^[0-9a-fA-F]{56}$ ]] || return 2
      credential="${credential,,}"
      ;;
    stake)
      cntools_wallet_bech32_valid "${credential}" "$(cntools_wallet_address_hrp reward)" reward || return 2
      ;;
    *) return 2 ;;
  esac
  CNTOOLS_HISTORY_LOOKUP="${lookup}"
  CNTOOLS_HISTORY_KIND="${kind}"
  CNTOOLS_HISTORY_LIST="" CNTOOLS_HISTORY_TOTAL=0 CNTOOLS_HISTORY_PAGE=0
  CNTOOLS_HISTORY_PAGES=() CNTOOLS_HISTORY_PAGE_FILE="" CNTOOLS_HISTORY_DETAIL=""
  CNTOOLS_HISTORY_ERROR="Could not prepare the wallet inventory. See the log for details."
  case "${lookup}/${kind}" in
    payment/transactions) endpoint=credential_txs ;;
    payment/utxos) endpoint='credential_utxos?is_spent=eq.false' ;;
    stake/transactions)
      # Validated Bech32 uses only URL-safe characters. Account history is GET,
      # with no block-height filter, limit, or body.
      endpoint="account_txs?_stake_address=${credential}"
      method=GET
      ;;
    stake/utxos) endpoint='account_utxos?is_spent=eq.false' ;;
    *) return 2 ;;
  esac
  if [[ "${method}" == POST ]]; then
    payload="$(jq -nc --arg credential "${credential}" --arg kind "${kind}" --arg lookup "${lookup}" '
      (if $lookup == "stake" then {_stake_addresses:[$credential]} else {_payment_credentials:[$credential]} end) +
      (if $kind == "utxos" then {_extended:true} else {} end)')" || return 1
  fi
  cntools_wallet_query_temp_file response || return 1
  if ! cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/${endpoint}" "${payload}" "${response}" 33554432 "${method}"; then
    cntools_history_error "Koios could not return the wallet inventory. Please retry."
    return 1
  fi
  # Empty arrays are valid; malformed, duplicate, foreign or spent records are
  # not silently turned into an apparently complete empty wallet.
  if ! jq -se --arg kind "${kind}" --arg credential "${credential}" --arg lookup "${lookup}" '
    def hash: type == "string" and test("^[0-9a-f]{64}$");
    def uint: type == "number" and . >= 0 and . == floor;
    def assets: . == null or (type == "array" and all(
      (.policy_id | type == "string" and test("^[0-9a-f]{56}$")) and
      (.asset_name | type == "string" and test("^([0-9a-f]{2}){0,32}$")) and
      (.quantity | type == "string" and test("^[0-9]+$"))));
    length == 1 and (.[0] | type == "array" and length <= 1000 and
    all(type == "object" and (.tx_hash | hash) and
      (.block_height | uint) and (.block_time | uint) and
      (if $kind == "utxos" then
        (.tx_index | uint) and (.address | type == "string" and length > 0) and
        (.value | type == "string" and test("^[0-9]+$")) and
        .is_spent == false and
        (if $lookup == "stake" then .stake_address == $credential else .payment_cred == $credential end) and
        (.asset_list | assets)
      else true end)) and
    (length == (unique_by(if $kind == "utxos" then [.tx_hash,.tx_index] else .tx_hash end) | length)))
  ' "${response}" >/dev/null 2>&1; then
    cntools_history_error "Koios returned an invalid or inconsistent wallet inventory."
    return 1
  fi
  CNTOOLS_HISTORY_TOTAL="$(jq 'length' "${response}")" || return 1
  CNTOOLS_HISTORY_LIST="${response}"
  CNTOOLS_HISTORY_ERROR=""
  cntools_wallet_log WALLET "Koios ${kind} lookup=${lookup} inventory count=${CNTOOLS_HISTORY_TOTAL}"
}

cntools_history_fetch_transactions() {
  local hashes="$1" destination="$2" response="" payload=""
  CNTOOLS_HISTORY_ERROR="Could not prepare transaction details. See the log for details."
  payload="$(jq -nc --argjson hashes "${hashes}" '{_tx_hashes:$hashes,
    _inputs:true,_metadata:true,_assets:true,_withdrawals:true,_certs:true,
    _scripts:true,_bytecode:true,_governance:true}')" || return 1
  cntools_wallet_query_temp_file response || return 1
  if ! cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/tx_info" "${payload}" "${response}" 33554432; then
    cntools_history_error "Koios could not return transaction details. Please retry."
    return 1
  fi
  # tx_info can reorder responses. Require exactly the requested set, then
  # restore credential_txs order so numbering stays stable throughout the visit.
  if ! jq -se --argjson hashes "${hashes}" '
    def uint: type == "number" and . >= 0 and . == floor;
    def amount: type == "string" and test("^[0-9]+$");
    def assets: . == null or (type == "array" and all(
      (.policy_id | type == "string" and test("^[0-9a-f]{56}$")) and
      (.asset_name | type == "string" and test("^([0-9a-f]{2}){0,32}$")) and
      (.quantity | amount)));
    length == 1 and (.[0] | type == "array" and length == ($hashes | length) and
    ([.[].tx_hash] | sort) == ($hashes | sort) and
    all(type == "object" and (.tx_timestamp | uint) and (.block_height | uint) and
      (.fee | amount) and (.total_output | amount) and
      (.inputs | type == "array") and
      (.outputs | type == "array" and all(type == "object" and
        (.value | amount) and (.asset_list | assets)))))
  ' "${response}" >/dev/null 2>&1; then
    cntools_history_error "Koios did not return all requested transactions, or returned invalid data."
    return 1
  fi
  jq --argjson hashes "${hashes}" 'INDEX(.tx_hash) as $by_hash | [$hashes[] | $by_hash[.]]' \
    "${response}" > "${destination}" || return 1
  CNTOOLS_HISTORY_ERROR=""
}

cntools_history_page_load() {
  local page="$1" output="" hashes="" start=0
  [[ "${page}" =~ ^(0|[1-9][0-9]{0,3})$ ]] || return 2
  start=$((page * CNTOOLS_HISTORY_SIZE))
  (( start < CNTOOLS_HISTORY_TOTAL || (page == 0 && CNTOOLS_HISTORY_TOTAL == 0) )) || return 2
  if [[ -n "${CNTOOLS_HISTORY_PAGES[${page}]:-}" ]]; then
    CNTOOLS_HISTORY_PAGE_FILE="${CNTOOLS_HISTORY_PAGES[${page}]}"
    CNTOOLS_HISTORY_PAGE="${page}"
    return 0
  fi
  cntools_wallet_query_temp_file output || return 1
  if [[ "${CNTOOLS_HISTORY_KIND}" == transactions && "${CNTOOLS_HISTORY_TOTAL}" != 0 ]]; then
    hashes="$(jq -c --argjson start "${start}" --argjson size "${CNTOOLS_HISTORY_SIZE}" \
      '[.[$start:$start+$size][].tx_hash]' "${CNTOOLS_HISTORY_LIST}")" || return 1
    cntools_history_fetch_transactions "${hashes}" "${output}" || return 1
  else
    jq --argjson start "${start}" --argjson size "${CNTOOLS_HISTORY_SIZE}" \
      '.[$start:$start+$size]' "${CNTOOLS_HISTORY_LIST}" > "${output}" || return 1
  fi
  CNTOOLS_HISTORY_PAGES["${page}"]="${output}"
  CNTOOLS_HISTORY_PAGE_FILE="${output}" CNTOOLS_HISTORY_PAGE="${page}"
}

cntools_history_detail_load() {
  local selection="${1:-}" hash="" output="" page=0 item=0 source="" hashes=""
  CNTOOLS_HISTORY_DETAIL=""
  CNTOOLS_HISTORY_DETAIL_NUMBER=""
  CNTOOLS_HISTORY_ERROR="Enter a valid item number or transaction ID."
  selection="${selection#"${selection%%[![:space:]]*}"}"
  selection="${selection%"${selection##*[![:space:]]}"}"
  if [[ "${selection}" == *,* ]]; then
    cntools_number_normalize_into selection "${selection}" || return 2
  fi
  if [[ "${selection}" =~ ^[1-9][0-9]{0,3}$ ]] && (( selection <= CNTOOLS_HISTORY_TOTAL )); then
    CNTOOLS_HISTORY_DETAIL_NUMBER="${selection}"
    item=$((selection - 1))
    if [[ "${CNTOOLS_HISTORY_KIND}" == utxos ]]; then
      cntools_wallet_query_temp_file output || return 1
      jq --argjson item "${item}" '.[$item]' "${CNTOOLS_HISTORY_LIST}" > "${output}" || return 1
      CNTOOLS_HISTORY_DETAIL="${output}"
      return 0
    fi
    hash="$(jq -r --argjson item "${item}" '.[$item].tx_hash' "${CNTOOLS_HISTORY_LIST}")" || return 1
  elif [[ "${CNTOOLS_HISTORY_KIND}" == transactions && "${selection}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    hash="${selection,,}"
  else
    cntools_history_error "Enter a transaction hash or an item number from the inventory (UTxOs accept numbers only)."
    return 1
  fi
  cntools_wallet_query_temp_file output || return 1
  for page in "${!CNTOOLS_HISTORY_PAGES[@]}"; do
    source="${CNTOOLS_HISTORY_PAGES[${page}]}"
    if jq -e --arg hash "${hash}" '.[] | select(.tx_hash == $hash)' "${source}" > "${output}"; then
      CNTOOLS_HISTORY_DETAIL="${output}"
      return 0
    fi
  done
  hashes="$(jq -nc --arg hash "${hash}" '[$hash]')" || return 1
  cntools_wallet_query_temp_file source || return 1
  cntools_history_fetch_transactions "${hashes}" "${source}" || return 1
  jq '.[0]' "${source}" > "${output}" || return 1
  CNTOOLS_HISTORY_DETAIL="${output}"
}

# Only identities from structurally recognizable asset objects; metadata
# enrichment is optional, display-only, and never changes the raw API data.
cntools_history_asset_ids() {
  jq -r '[.. | objects | select(
    (.policy_id? | type == "string") and (.asset_name? | type == "string")) |
    select((.policy_id | test("^[0-9a-f]{56}$")) and
      (.asset_name | test("^([0-9a-f]{2}){0,32}$"))) |
    .policy_id + "." + .asset_name] | unique[]' "$1"
}

# Tags describe observable ledger operations, never claims in user metadata.
# Do not guess DApp brands or ownership from a change-output heuristic.
cntools_history_transaction_tags() {
  jq -r --arg payment "${CNTOOLS_HISTORY_PAYMENT}" --arg stake "${CNTOOLS_HISTORY_STAKE}" '
    def nonempty: type == "string" and length > 0;
    def text: if type == "string" then . else "" end;
    def owner: ((try .payment_addr.cred catch null) // .payment_cred // "") | text;
    def address: ((try .payment_addr.bech32 catch null) // .address // "") | text;
    def ours: (($payment != "") and owner == $payment) or
      (($stake != "") and (.stake_addr // .stake_address // "") == $stake);
    def internal:
      (.inputs | length > 0) and (.outputs | length > 0) and
      ([.inputs[],.outputs[]] as $io |
        ($io | all(ours)) or
        ([$io[] | owner] | all(test("^[0-9a-f]{56}$")) and (unique|length) == 1) or
        ([$io[] | address] | all(nonempty) and (unique|length) == 1));
    {stake_registration:"Stake registration",stake_deregistration:"Stake de-registration",
     stake_deregistraion:"Stake de-registration",delegation:"Stake delegation",
     pool_delegation:"Stake delegation",vote_delegation:"DRep delegation",
     drep_registration:"DRep registration",drep_update:"DRep update",drep_retire:"DRep retirement",
     pool_update:"Pool registration/update",pool_retire:"Pool retirement",
     committee_hot_auth:"Committee authorization",committee_resign:"Committee resignation",
     param_proposal:"Protocol proposal",reserve_MIR:"Reserve MIR",treasury_MIR:"Treasury MIR",
     pot_transfer:"Treasury/reserve transfer"} as $names |
    ([if (.withdrawals // [] | length) > 0 then "Withdrawal" else empty end,
      (.certificates[]? | $names[.type // ""] // "Certificate"),
      if (.voting_procedures // [] | length) > 0 then "Governance vote" else empty end,
      if (.proposal_procedures // [] | length) > 0 then "Governance proposal" else empty end,
      if any(.assets_minted[]?; (.quantity|tostring|test("^[1-9][0-9]*$"))) then "Mint" else empty end,
      if any(.assets_minted[]?; (.quantity|tostring|test("^-[1-9][0-9]*$"))) then "Burn" else empty end,
      if (.plutus_contracts // [] | length) > 0 then "Script execution" else empty end] | unique) as $tags |
    if ($tags|length) > 0 then $tags | join(" · ")
    elif internal then "Internal transfer" else "Transfer" end
  ' <<< "$1"
}
