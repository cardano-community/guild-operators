#!/usr/bin/env bash
# Metadata-only adapter: reuse Send's balanced payment/change/fee engine.
# shellcheck disable=SC2034
cntools_metadata_transaction_build_into() {
  local result="$1" intent="$2" description="$3" context="$4" metadata="$5" view='' expected='' skipped=0
  cntools_utxo_keep_simple_into skipped || return 1
  cntools_transaction_log TRANSACTION "Metadata-only inventory excluded=${skipped} datum/reference-script UTxOs"
  (( ${#CNTOOLS_UTXO_REFS[@]} > 0 )) || {
    cntools_transaction_set_error 'No ordinary funding UTxOs are available. Datum/reference-script outputs are not consumed.'; return 1;
  }
  cntools_metadata_reset
  cntools_metadata_import "${metadata}" simple || return 1
  CNTOOLS_SEND_MODE=metadata
  CNTOOLS_SEND_ADDRESSES=(); CNTOOLS_SEND_LABELS=(); CNTOOLS_SEND_AMOUNTS=(); CNTOOLS_SEND_ASSETS=()
  CNTOOLS_SEND_HANDLES=(); CNTOOLS_SEND_RESOLUTIONS=()
  cntools_send_build_into "${result}" "${intent}" "${description}" "${context}" || return 1
  cntools_transaction_view_into view "${CNTOOLS_TRANSACTION_BODY_FILE}" || return 1
  # CLI debug view represents metadata maps as key/value pairs and bytes as a
  # byte list. Compare the complete authorization, not just the nonce/key fields.
  expected="$(jq -c '
    def ledger:
      if type=="object" then [to_entries[]|[(.key|if test("^-?[0-9]+$") then tonumber else ledger end),(.value|ledger)]]
      elif type=="array" then map(ledger)
      elif type=="string" and test("^0x([0-9a-f]{2})+$") then
        "["+([.[2:]|scan("..")|"0x"+.]|join(", "))+"]"
      else . end;
    with_entries(.value |= ledger)' "${CNTOOLS_METADATA_CUSTOM}")" || return 1
  jq -e --argjson expected "${expected}" --arg address "${CNTOOLS_SEND_CHANGE_ADDRESS:-${CNTOOLS_SEND_ADDRESS}}" \
    --arg fee "${CNTOOLS_SEND_FEE} Lovelace" '
    .metadata==$expected and .fee==$fee and (.certificates==null or .certificates==[]) and
    (.withdrawals==null or .withdrawals==[]) and (.mint==null) and (."governance actions"==[]) and (.voters=={}) and
    (.treasuryDonation==0) and (."collateral inputs"==[]) and (."reference inputs"==[]) and
    (.outputs|length>0 and all(.[];.address==$address and .datum==null and ."reference script"==null))
  ' <<< "${view}" >/dev/null || {
    cntools_transaction_set_error 'The metadata transaction does not match its reviewed authorization and change outputs.'; return 1;
  }
  cntools_transaction_log REVIEW "Metadata-only transaction verified view=${view}"
}
