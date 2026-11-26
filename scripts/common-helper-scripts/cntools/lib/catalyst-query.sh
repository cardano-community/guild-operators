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
      (.delegator_addresses|type=="array" and length<=1000 and all(.[];type=="string")))))' "${response}" >/dev/null || {
    cntools_catalyst_fail 'Catalyst returned an unexpected snapshot response.'; return 1;
  }
  CNTOOLS_CATALYST_STATUS_FILE="${response}"
  if jq -e 'has("error")' "${response}" >/dev/null; then CNTOOLS_CATALYST_STATUS='Not reported in snapshot'
  else CNTOOLS_CATALYST_STATUS='Reported in snapshot'; fi
}

# Optional per-delegator snapshot details. A failed lookup never changes the
# voter registration result or implies that rewards are not payable.
cntools_catalyst_delegator_lookup_into() {
  local -n delegator_file_output="$1"
  local public="${2,,}" base="${CNTOOLS_CATALYST_API:-https://api.projectcatalyst.io/api/v1}" response=''
  delegator_file_output=''; public="${public#0x}"
  [[ "${CNTOOLS_MODE:-}" != offline && "${CNTOOLS_NETWORK:-}" == mainnet &&
     "${public}" =~ ^[0-9a-f]{64}$ && "${base}" =~ ^https://[^[:space:]?#]+$ ]] || return 1
  cntools_transaction_temp_file response catalyst-delegator || return 1
  if ! cntools_api_request GET "${base%/}/registration/delegations/0x${public}" "${response}" \
      --connect-timeout 3 --max-filesize 4194304 --header 'accept: application/json'; then
    cntools_log ERROR "Catalyst delegator snapshot lookup unavailable public=${public}" || true
    return 1
  fi
  jq -es 'length==1 and (.[0]|type=="object" and (has("error")|not) and
    (.reward_address|type=="string") and (.reward_payable|type=="boolean") and
    (.raw_power|tostring|test("^(0|[1-9][0-9]*)$")))' "${response}" >/dev/null || {
    cntools_log ERROR "Catalyst delegator snapshot response unavailable or invalid public=${public}" || true; return 1;
  }
  delegator_file_output="${response}"
}

# Per-delegator rows, collected once per snapshot: stake key, local wallet,
# stake address and (after the optional lookup) the details file.
declare -ag CNTOOLS_CATALYST_DELEGATOR_KEYS=() CNTOOLS_CATALYST_DELEGATOR_WALLETS=()
declare -ag CNTOOLS_CATALYST_DELEGATOR_ADDRESSES=() CNTOOLS_CATALYST_DELEGATOR_FILES=()

# Match public stake artifacts only. Never search signing keys or seed files.
# Each wallet's stake keys are read once, not once per delegator.
cntools_catalyst_delegators_collect() {
  local cd_directory='' cd_filename='' cd_key='' cd_address='' cd_stake=''
  local -A cd_wallets=()
  CNTOOLS_CATALYST_DELEGATOR_KEYS=() CNTOOLS_CATALYST_DELEGATOR_WALLETS=()
  CNTOOLS_CATALYST_DELEGATOR_ADDRESSES=() CNTOOLS_CATALYST_DELEGATOR_FILES=()
  for cd_directory in "${CNTOOLS_WALLET_PATHS[@]-}"; do
    [[ -n "${cd_directory}" ]] || continue
    for cd_filename in "${CNTOOLS_WALLET_STAKE_VKEY_FILENAME:-stake.vkey}" \
        "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}${CNTOOLS_WALLET_STAKE_VKEY_FILENAME:-stake.vkey}"; do
      cntools_transaction_file_safe "${cd_directory}/${cd_filename}" 65536 || continue
      cd_key="$(jq -er '.cborHex|ascii_downcase|select(test("^(5820[0-9a-f]{64}|5840[0-9a-f]{128})$"))|.[4:68]' "${cd_directory}/${cd_filename}")" || continue
      [[ -n "${cd_wallets[${cd_key}]+x}" ]] || cd_wallets["${cd_key}"]="${cd_directory##*/}"
    done
  done
  while IFS= read -r cd_address; do
    [[ -n "${cd_address}" ]] || continue
    cd_key="${cd_address#0x}"; cd_key="${cd_key,,}" cd_stake=''
    cntools_catalyst_delegator_address_into cd_stake "${cd_key}" || cd_stake=''
    CNTOOLS_CATALYST_DELEGATOR_KEYS+=("${cd_address}")
    CNTOOLS_CATALYST_DELEGATOR_WALLETS+=("${cd_wallets[${cd_key}]:-}")
    CNTOOLS_CATALYST_DELEGATOR_ADDRESSES+=("${cd_stake}")
    CNTOOLS_CATALYST_DELEGATOR_FILES+=('')
  done < <(jq -r '.voter_info.delegator_addresses // [] | .[]' "${CNTOOLS_CATALYST_STATUS_FILE}")
}

# Optional per-delegator snapshot details, fetched once for all delegators.
cntools_catalyst_delegators_lookup() {
  local cl_index=0 cl_file=''
  for cl_index in "${!CNTOOLS_CATALYST_DELEGATOR_KEYS[@]}"; do
    cl_file=''
    cntools_catalyst_delegator_lookup_into cl_file "${CNTOOLS_CATALYST_DELEGATOR_KEYS[cl_index]}" || cl_file=''
    CNTOOLS_CATALYST_DELEGATOR_FILES[cl_index]="${cl_file}"
  done
}

cntools_catalyst_delegator_address_into() {
  local -n delegator_address_output="$1"
  local public="${2#0x}" address_output=''
  delegator_address_output=''
  [[ "${public}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  cntools_transaction_require_cli || return 1
  address_output="$(cntools_run_command_timeout 10 0000000 -- "${CNTOOLS_CLI}" latest stake-address build \
    --stake-verification-key "${public}" --mainnet)" || return 1
  [[ "${address_output}" =~ ^stake1[0-9a-z]+$ ]] || return 1
  delegator_address_output="${address_output}"
}
