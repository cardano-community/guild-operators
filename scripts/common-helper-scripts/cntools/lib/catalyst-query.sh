#!/usr/bin/env bash
# Official Catalyst snapshot status, not Cardano stake registration or inclusion.
# shellcheck disable=SC2034
CNTOOLS_CATALYST_STATUS_FILE='' CNTOOLS_CATALYST_STATUS='Not checked'

cntools_catalyst_lookup() {
  local public="${1,,}" base="${CNTOOLS_CATALYST_API:-https://api.projectcatalyst.io/api/v1}" response='' status=0
  CNTOOLS_CATALYST_STATUS_FILE=''; CNTOOLS_CATALYST_STATUS=Unavailable
  [[ "${CNTOOLS_MODE:-}" != offline && "${CNTOOLS_NETWORK:-}" == mainnet ]] || {
    cntools_catalyst_fail 'Catalyst fund snapshot verification is available on mainnet only. Testnet registration metadata does not grant voting eligibility.'; return 1;
  }
  [[ "${public}" =~ ^[0-9a-f]{64}$ && "${base}" =~ ^https://[^[:space:]?#]+$ ]] || return 1
  cntools_transaction_temp_file response catalyst-status || return 1
  cntools_api_request GET "${base%/}/registration/voter/0x${public}?with_delegators=true" "${response}" \
    --connect-timeout 3 --max-filesize 4194304 --header 'accept: application/json' || status=$?
  ((status == 0)) || { cntools_catalyst_fail 'Catalyst snapshot lookup failed. This does not mean the wallet is unregistered.'; return 1; }
  jq -es 'length==1 and (.[0]|type=="object" and
    (has("error") or (.voter_info|type=="object" and
      (.voting_power|tostring|test("^(0|[1-9][0-9]*)$")) and
      (.delegations_count|type=="number" and floor==. and .>=0) and
      (.delegator_addresses|type=="array" and all(.[];type=="string")))))' "${response}" >/dev/null || {
    cntools_catalyst_fail 'Catalyst returned an unexpected snapshot response.'; return 1;
  }
  CNTOOLS_CATALYST_STATUS_FILE="${response}"
  if jq -e 'has("error")' "${response}" >/dev/null; then CNTOOLS_CATALYST_STATUS='Not reported in snapshot'
  else CNTOOLS_CATALYST_STATUS='Reported in snapshot'; fi
}
