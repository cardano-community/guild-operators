#!/usr/bin/env bash
# Read-only local and Koios wallet queries for Wallet > List and Show.
# Loaded after lib/wallet.sh only by those two actions.
# shellcheck disable=SC2034

declare -ag CNTOOLS_WALLET_QUERY_TEMP_FILES=()
declare -Ag CNTOOLS_WALLET_LOCAL_ASSETS=()
declare -ag CNTOOLS_WALLET_LIST_BASE_ADDRESSES=()
declare -ag CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES=()
declare -ag CNTOOLS_WALLET_LIST_REWARD_ADDRESSES=()
declare -ag CNTOOLS_WALLET_LIST_UTXO_LOVELACE=()
declare -ag CNTOOLS_WALLET_LIST_REWARD_LOVELACE=()
declare -ag CNTOOLS_WALLET_LIST_TOTAL_LOVELACE=()
declare -ag CNTOOLS_WALLET_LIST_TOKEN_COUNTS=()
declare -ag CNTOOLS_WALLET_LIST_QUERY_STATUSES=()
declare -Ag CNTOOLS_WALLET_LIST_ADDRESS_BALANCES=()
declare -Ag CNTOOLS_WALLET_LIST_ADDRESS_ASSETS=()
declare -Ag CNTOOLS_WALLET_LIST_STAKE_REWARDS=()

CNTOOLS_WALLET_KOIOS_PAYLOAD_MAX_BYTES=1024
CNTOOLS_WALLET_LIST_QUERY_LEVEL=""
CNTOOLS_WALLET_LIST_QUERY_SUMMARY=""
CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE=""

cntools_wallet_query_reset() {
  CNTOOLS_WALLET_QUERY_STATUS="unavailable"
  CNTOOLS_WALLET_QUERY_MESSAGE="Live chain data is unavailable."
  CNTOOLS_WALLET_BASE_LOVELACE=""
  CNTOOLS_WALLET_PAYMENT_LOVELACE=""
  CNTOOLS_WALLET_TOTAL_LOVELACE=""
  CNTOOLS_WALLET_REWARD_LOVELACE=""
  CNTOOLS_WALLET_REGISTERED="unknown"
  CNTOOLS_WALLET_POOL_DELEGATION=""
  CNTOOLS_WALLET_DREP_DELEGATION=""
  CNTOOLS_WALLET_UTXO_COUNT=""
  CNTOOLS_WALLET_ASSET_COUNT=""
  CNTOOLS_WALLET_FUNDING_EXPECTED=0
  CNTOOLS_WALLET_FUNDING_SUCCEEDED=0
  CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE=""
}

cntools_wallet_query_cleanup() {
  local file=""

  for file in "${CNTOOLS_WALLET_QUERY_TEMP_FILES[@]}"; do
    [[ -n "${file}" &&
       "${file}" = "${CNTOOLS_TMP_DIR:-/invalid}/.cntools-wallet."* &&
       -f "${file}" && ! -L "${file}" && -O "${file}" ]] || continue
    rm -f -- "${file}"
  done
  CNTOOLS_WALLET_QUERY_TEMP_FILES=()
  if declare -F cntools_http_secret_files_cleanup >/dev/null 2>&1; then
    cntools_http_secret_files_cleanup
  fi
}

cntools_wallet_query_temp_file() {
  local _cntools_output_name="${1:-}"
  local _cntools_temp_file=""
  local _cntools_previous_umask=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  [[ -d "${CNTOOLS_TMP_DIR:-}" && ! -L "${CNTOOLS_TMP_DIR}" &&
     -O "${CNTOOLS_TMP_DIR}" && -w "${CNTOOLS_TMP_DIR}" ]] || return 1
  _cntools_previous_umask="$(umask)"
  umask 077
  _cntools_temp_file="$(mktemp "${CNTOOLS_TMP_DIR}/.cntools-wallet.XXXXXX")" || {
    umask "${_cntools_previous_umask}"
    return 1
  }
  umask "${_cntools_previous_umask}"
  chmod 0600 "${_cntools_temp_file}" || {
    rm -f -- "${_cntools_temp_file}"
    return 1
  }
  CNTOOLS_WALLET_QUERY_TEMP_FILES+=("${_cntools_temp_file}")
  _cntools_output_ref="${_cntools_temp_file}"
}

cntools_wallet_query_first_diagnostic() {
  local file="${1:-}"
  local fallback=""
  local line=""
  local joined=""

  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="$(cntools_log_sanitize_line "${line:0:400}")"
    [[ "${line}" == *[![:space:]]* ]] || continue
    case "${line}" in
      Error:*|cardano-cli:*|*': Error:'*)
        printf '%s' "${line:0:400}"
        return 0
        ;;
    esac
    if [[ -z "${fallback}" ]]; then
      fallback="${line}"
    else
      joined="${fallback} | ${line}"
      fallback="${joined:0:400}"
    fi
  done < "${file}"
  [[ -n "${fallback}" ]] || return 1
  printf '%s' "${fallback:0:400}"
}

cntools_wallet_query_log_failure() {
  local context="${1:-query failed}"
  local status="${2:-1}"
  local error_file="${3:-}"
  local output_file="${4:-}"
  local detail=""

  if [[ "${status}" == "124" ]]; then
    detail="timed out after ${CNTOOLS_CLI_TIMEOUT:-10} seconds"
    CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE="timeout"
  else
    detail="$(cntools_wallet_query_first_diagnostic \
      "${error_file}" 2>/dev/null || true)"
    [[ -n "${detail}" ]] || detail="$(cntools_wallet_query_first_diagnostic \
      "${output_file}" 2>/dev/null || true)"
  fi
  cntools_wallet_log ERROR \
    "${context} status=${status}${detail:+: ${detail}}"
}

cntools_wallet_query_local_socket_ready() {
  local socket_path="${CNTOOLS_SOCKET:-}"

  [[ -n "${socket_path}" && "${socket_path}" = /* &&
     -S "${socket_path}" ]]
}

cntools_wallet_query_network_arguments() {
  case "${CNTOOLS_NETWORK:-}" in
    mainnet) CNTOOLS_WALLET_NETWORK_ARGS=(--mainnet) ;;
    guild) CNTOOLS_WALLET_NETWORK_ARGS=(--testnet-magic 141) ;;
    preprod) CNTOOLS_WALLET_NETWORK_ARGS=(--testnet-magic 1) ;;
    preview) CNTOOLS_WALLET_NETWORK_ARGS=(--testnet-magic 2) ;;
    *) return 1 ;;
  esac
}

cntools_wallet_query_run_cli() {
  local output_file="${1:-}"
  local error_file="${2:-}"
  local mask=""
  shift 2 || return 2
  (( $# > 0 )) || return 2
  printf -v mask '%*s' "$#" ''
  mask="${mask// /0}"
  cntools_run_command_timeout "${CNTOOLS_CLI_TIMEOUT:-10}" \
    "${mask}" -- "$@" > "${output_file}" 2> "${error_file}"
}

cntools_wallet_query_local_address() {
  local address="${1:-}"
  local kind="${2:-}"
  local output_file=""
  local error_file=""
  local balance=""
  local utxo_count=""
  local asset_output=""
  local asset_id=""
  local query_status=0
  local -a command_args=()

  [[ -n "${address}" && ( "${kind}" == "base" || "${kind}" == "payment" ) ]] ||
    return 2
  cntools_wallet_query_temp_file output_file || return 1
  cntools_wallet_query_temp_file error_file || return 1
  command_args=(
    "${CNTOOLS_CLI}" query utxo --address "${address}"
    "${CNTOOLS_WALLET_NETWORK_ARGS[@]}"
    --socket-path "${CNTOOLS_SOCKET}"
    --output-json
  )
  if cntools_wallet_query_run_cli \
      "${output_file}" "${error_file}" "${command_args[@]}"; then
    query_status=0
  else
    query_status=$?
    cntools_wallet_query_log_failure \
      "Local ${kind} address query failed" "${query_status}" \
      "${error_file}" "${output_file}"
    return "${query_status}"
  fi
  jq -e '
    type == "object" and
    all(.[]; type == "object" and (.value | type == "object"))
  ' "${output_file}" >/dev/null 2>&1 || {
    cntools_wallet_log ERROR "Local ${kind} address query returned invalid JSON"
    return 1
  }
  balance="$(jq -er '
    [.[] | (.value.lovelace // 0)] | add // 0 | tostring
  ' "${output_file}" 2>/dev/null)" || return 1
  utxo_count="$(jq -er 'length | tostring' "${output_file}" 2>/dev/null)" ||
    return 1
  [[ "${balance}" =~ ^[0-9]+$ && "${utxo_count}" =~ ^[0-9]+$ ]] ||
    return 1
  asset_output="$(jq -r '
    [
      .[] | .value | to_entries[]
      | select(.key != "lovelace")
      | .key as $policy
      | .value | keys[]
      | $policy + "." + .
    ] | unique[]
  ' "${output_file}" 2>/dev/null)" || return 1
  while IFS= read -r asset_id; do
    [[ -n "${asset_id}" ]] || continue
    CNTOOLS_WALLET_LOCAL_ASSETS["${asset_id}"]=1
  done <<< "${asset_output}"
  if [[ "${kind}" == "base" ]]; then
    CNTOOLS_WALLET_BASE_LOVELACE="${balance}"
  else
    CNTOOLS_WALLET_PAYMENT_LOVELACE="${balance}"
  fi
  CNTOOLS_WALLET_UTXO_COUNT=$(( ${CNTOOLS_WALLET_UTXO_COUNT:-0} + utxo_count ))
  CNTOOLS_WALLET_ASSET_COUNT="${#CNTOOLS_WALLET_LOCAL_ASSETS[@]}"
}

cntools_wallet_query_local_stake() {
  local reward_address="${1:-}"
  local output_file=""
  local error_file=""
  local record=""
  local vote_status=""
  local query_status=0
  local -a command_args=()

  [[ -n "${reward_address}" ]] || return 2
  cntools_wallet_query_temp_file output_file || return 1
  cntools_wallet_query_temp_file error_file || return 1
  command_args=(
    "${CNTOOLS_CLI}" query stake-address-info --address "${reward_address}"
    "${CNTOOLS_WALLET_NETWORK_ARGS[@]}"
    --socket-path "${CNTOOLS_SOCKET}"
    --output-json
  )
  if cntools_wallet_query_run_cli \
      "${output_file}" "${error_file}" "${command_args[@]}"; then
    query_status=0
  else
    query_status=$?
    cntools_wallet_query_log_failure \
      "Local stake address query failed" "${query_status}" \
      "${error_file}" "${output_file}"
    return "${query_status}"
  fi
  jq -e --arg reward_address "${reward_address}" '
    def null_or_string:
      type == "null" or type == "string";
    def valid_stake_delegation:
      type == "null" or
      type == "string" or
      (type == "object" and
        (.stakePoolBech32 | null_or_string) and
        (.keyHash | null_or_string));
    def valid_vote_delegation:
      type == "null" or
      type == "string" or
      (type == "object" and
        (.cip129Bech32 | null_or_string) and
        (.cip129 | null_or_string));
    type == "array" and
    length <= 1 and
    (length == 0 or
      (.[0] | type == "object" and
        .address == $reward_address and
        (.rewardAccountBalance |
          type == "number" and . >= 0 and floor == .) and
        (.stakeDelegation | valid_stake_delegation) and
        (.voteDelegation | valid_vote_delegation)))
  ' "${output_file}" >/dev/null 2>&1 || {
    cntools_wallet_log ERROR "Local stake address query returned invalid JSON"
    return 1
  }
  if [[ "$(jq -r 'length' "${output_file}")" == "0" ]]; then
    CNTOOLS_WALLET_REGISTERED="no"
    CNTOOLS_WALLET_REWARD_LOVELACE="0"
    return 0
  fi
  record="$(jq -er '
    def pool_delegation:
      (.[0].stakeDelegation // null) as $delegation
      | if ($delegation | type) == "object" then
          ($delegation.stakePoolBech32 // $delegation.keyHash // "")
        elif ($delegation | type) == "string" then $delegation
        else "" end;
    def valid_cip129:
      type == "string" and
      test("^drep1[023456789acdefghjklmnpqrstuvwxyz]+$");
    def vote_delegation:
      (.[0].voteDelegation // null) as $delegation
      | if ($delegation | type) == "string" then
          if ($delegation == "alwaysAbstain" or
              $delegation == "alwaysNoConfidence") then
            [$delegation, ""]
          elif ($delegation | valid_cip129) then
            [$delegation, ""]
          else
            ["", "unrecognized"]
          end
        elif ($delegation | type) == "object" then
          ($delegation.cip129Bech32 // $delegation.cip129 // "") as $cip129
          | if ($cip129 | valid_cip129) then
              [$cip129, ""]
            else
              ["", "ambiguous"]
            end
        else ["", ""] end;
    vote_delegation as $vote_delegation
    |
    [
      (.[0].rewardAccountBalance // 0 | tostring),
      pool_delegation,
      $vote_delegation[0],
      $vote_delegation[1]
    ] | map(tostring) | join("\u001f")
  ' "${output_file}" 2>/dev/null)" || return 1
  IFS=$'\037' read -r \
    CNTOOLS_WALLET_REWARD_LOVELACE \
    CNTOOLS_WALLET_POOL_DELEGATION \
    CNTOOLS_WALLET_DREP_DELEGATION \
    vote_status <<< "${record}"
  [[ "${CNTOOLS_WALLET_REWARD_LOVELACE}" =~ ^[0-9]+$ ]] || return 1
  if [[ -n "${vote_status}" ]]; then
    cntools_wallet_log WALLET \
      "Local vote delegation omitted representation=${vote_status}"
  fi
  CNTOOLS_WALLET_REGISTERED="yes"
}

cntools_wallet_query_local() {
  local base_address="${1:-}"
  local payment_address="${2:-}"
  local reward_address="${3:-}"
  local attempted=0
  local succeeded=0

  if [[ "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" != "true" ]]; then
    CNTOOLS_WALLET_QUERY_STATUS="unsupported"
    CNTOOLS_WALLET_QUERY_MESSAGE="${CNTOOLS_IMPLEMENTATION_NAME} does not provide local wallet queries."
    cntools_wallet_log WALLET \
      "local wallet query unavailable capability=localCli:false implementation=${CNTOOLS_IMPLEMENTATION}"
    return 0
  fi
  if [[ -z "${CNTOOLS_CLI:-}" || ! -x "${CNTOOLS_CLI}" ]]; then
    CNTOOLS_WALLET_QUERY_STATUS="unavailable"
    CNTOOLS_WALLET_QUERY_MESSAGE="The deployment's Cardano CLI is unavailable."
    cntools_wallet_log ERROR "Local wallet query has no executable Cardano CLI"
    CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE="cli"
    return 0
  fi
  [[ -n "${CNTOOLS_SOCKET:-}" ]] || {
    CNTOOLS_WALLET_QUERY_STATUS="unavailable"
    CNTOOLS_WALLET_QUERY_MESSAGE="The deployment's node socket is not configured."
    cntools_wallet_log ERROR "Local wallet query has no node socket path"
    return 0
  }
  if ! cntools_wallet_query_local_socket_ready; then
    CNTOOLS_WALLET_QUERY_STATUS="unavailable"
    CNTOOLS_WALLET_QUERY_MESSAGE="The local node socket is unavailable: ${CNTOOLS_SOCKET}."
    cntools_wallet_log ERROR \
      "Local wallet query socket is missing or unsafe: ${CNTOOLS_SOCKET}"
    CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE="socket"
    return 0
  fi
  cntools_wallet_query_network_arguments || {
    CNTOOLS_WALLET_QUERY_STATUS="unavailable"
    CNTOOLS_WALLET_QUERY_MESSAGE="The selected network has no local CLI mapping."
    cntools_wallet_log ERROR \
      "Local wallet query has unsupported network=${CNTOOLS_NETWORK}"
    CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE="network"
    return 0
  }
  CNTOOLS_WALLET_LOCAL_ASSETS=()
  if [[ -n "${base_address}" ]]; then
    attempted=$((attempted + 1))
    if cntools_wallet_query_local_address "${base_address}" base; then
      succeeded=$((succeeded + 1))
      CNTOOLS_WALLET_FUNDING_SUCCEEDED=$((
        CNTOOLS_WALLET_FUNDING_SUCCEEDED + 1
      ))
    fi
  fi
  if [[ -z "${CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE}" &&
        -n "${payment_address}" ]]; then
    attempted=$((attempted + 1))
    if cntools_wallet_query_local_address "${payment_address}" payment; then
      succeeded=$((succeeded + 1))
      CNTOOLS_WALLET_FUNDING_SUCCEEDED=$((
        CNTOOLS_WALLET_FUNDING_SUCCEEDED + 1
      ))
    fi
  fi
  if [[ -z "${CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE}" &&
        -n "${reward_address}" ]]; then
    attempted=$((attempted + 1))
    cntools_wallet_query_local_stake "${reward_address}" &&
      succeeded=$((succeeded + 1))
  fi
  if (( attempted == 0 )); then
    CNTOOLS_WALLET_QUERY_STATUS="unavailable"
    CNTOOLS_WALLET_QUERY_MESSAGE="This wallet has no valid address files to query."
  elif (( succeeded == attempted )); then
    CNTOOLS_WALLET_QUERY_STATUS="available"
    CNTOOLS_WALLET_QUERY_MESSAGE="Live data from ${CNTOOLS_IMPLEMENTATION_NAME}."
  elif (( succeeded > 0 )); then
    CNTOOLS_WALLET_QUERY_STATUS="partial"
    CNTOOLS_WALLET_QUERY_MESSAGE="Some local wallet queries failed; available results are shown."
  else
    CNTOOLS_WALLET_QUERY_STATUS="unavailable"
    CNTOOLS_WALLET_QUERY_MESSAGE="The local backend could not return wallet data."
  fi
}

cntools_wallet_query_http() {
  local endpoint="${1:-}"
  local payload="${2:-}"
  local output_file="${3:-}"
  local auth_header_file=""
  local request_status=0
  local -a arguments=(
    --connect-timeout 3
    --max-filesize 2097152
    --header "accept: application/json"
    --header "content-type: application/json"
    --data "${payload}"
  )

  if [[ -n "${CNTOOLS_KOIOS_TOKEN:-}" ]]; then
    if ! cntools_http_secret_file_create auth_header_file; then
      cntools_wallet_log ERROR \
        "Could not prepare the protected Koios authorization header"
      return 1
    fi
    arguments+=(--header "@${auth_header_file}")
  fi
  if cntools_http_request POST "${endpoint}" "${output_file}" \
      "${arguments[@]}"; then
    request_status=0
  else
    request_status=$?
  fi
  [[ -z "${auth_header_file}" ]] ||
    cntools_http_secret_file_remove "${auth_header_file}" || true
  return "${request_status}"
}

cntools_wallet_query_koios_addresses() {
  local base_address="${1:-}"
  local payment_address="${2:-}"
  local response_file=""
  local payload=""
  local balance=""
  local expected_count=0
  local matched_count=0
  local -a addresses=()

  [[ -z "${base_address}" ]] || addresses+=("${base_address}")
  [[ -z "${payment_address}" ]] || addresses+=("${payment_address}")
  (( ${#addresses[@]} > 0 )) || return 2
  expected_count="${#addresses[@]}"
  cntools_wallet_query_temp_file response_file || return 1
  payload="$(printf '%s\n' "${addresses[@]}" | jq -Rsc '
    split("\n") | map(select(length > 0)) | {_addresses: .}
  ')" || return 1
  if ! cntools_wallet_query_http \
      "${CNTOOLS_KOIOS_API%/}/address_info" \
      "${payload}" "${response_file}"; then
    cntools_wallet_log ERROR "Koios address_info request failed"
    return 1
  fi
  jq -e --arg base "${base_address}" --arg payment "${payment_address}" '
    type == "array" and
    all(.[];
      (.address | type == "string") and
      (.balance | type == "string" and test("^[0-9]+$")) and
      (.utxo_set | type == "array") and
      (.address == $base or .address == $payment)
    ) and
    ([.[].address] | unique | length) == length
  ' "${response_file}" >/dev/null 2>&1 || {
    cntools_wallet_log ERROR "Koios address_info returned invalid JSON"
    return 1
  }
  if [[ -n "${base_address}" ]]; then
    if balance="$(jq -er --arg address "${base_address}" '
        ([.[] | select(.address == $address)][0].balance // empty) | tostring
      ' "${response_file}" 2>/dev/null)" &&
       [[ "${balance}" =~ ^[0-9]+$ ]]; then
      CNTOOLS_WALLET_BASE_LOVELACE="${balance}"
      matched_count=$((matched_count + 1))
    fi
  fi
  if [[ -n "${payment_address}" ]]; then
    if balance="$(jq -er --arg address "${payment_address}" '
        ([.[] | select(.address == $address)][0].balance // empty) | tostring
      ' "${response_file}" 2>/dev/null)" &&
       [[ "${balance}" =~ ^[0-9]+$ ]]; then
      CNTOOLS_WALLET_PAYMENT_LOVELACE="${balance}"
      matched_count=$((matched_count + 1))
    fi
  fi
  CNTOOLS_WALLET_FUNDING_SUCCEEDED="${matched_count}"
  if (( matched_count != expected_count )); then
    cntools_wallet_log ERROR \
      "Koios address_info omitted a requested funding address"
    return 1
  fi
  CNTOOLS_WALLET_UTXO_COUNT="$(jq -er '
    [.[].utxo_set[]?] | length | tostring
  ' "${response_file}" 2>/dev/null)" || return 1
  CNTOOLS_WALLET_ASSET_COUNT="$(jq -er '
    [
      .[].utxo_set[]?.asset_list[]?
      | (.policy_id // "") + "." + (.asset_name // "")
      | select(. != ".")
    ] | unique | length | tostring
  ' "${response_file}" 2>/dev/null)" || return 1
}

cntools_wallet_query_koios_stake() {
  local reward_address="${1:-}"
  local response_file=""
  local payload=""
  local record=""

  [[ -n "${reward_address}" ]] || return 2
  cntools_wallet_query_temp_file response_file || return 1
  payload="$(jq -cn --arg address "${reward_address}" \
    '{_stake_addresses: [$address]}')" || return 1
  if ! cntools_wallet_query_http \
      "${CNTOOLS_KOIOS_API%/}/account_info" \
      "${payload}" "${response_file}"; then
    cntools_wallet_log ERROR "Koios account_info request failed"
    return 1
  fi
  jq -e --arg reward "${reward_address}" '
    type == "array" and length <= 1 and
    all(.[];
      (.stake_address == $reward) and
      (.stake_address | type == "string") and
      (.status == "registered" or .status == "not registered") and
      (.rewards_available | type == "string" and test("^[0-9]+$")) and
      ((.delegated_pool == null) or (.delegated_pool | type == "string")) and
      ((.delegated_drep == null) or (.delegated_drep | type == "string"))
    )
  ' "${response_file}" >/dev/null 2>&1 || {
    cntools_wallet_log ERROR "Koios account_info returned invalid JSON"
    return 1
  }
  if [[ "$(jq -r 'length' "${response_file}")" == "0" ]]; then
    CNTOOLS_WALLET_REGISTERED="no"
    CNTOOLS_WALLET_REWARD_LOVELACE="0"
    return 0
  fi
  record="$(jq -er '
    [
      (if .[0].status == "registered" then "yes" else "no" end),
      (.[0].rewards_available // "0"),
      (.[0].delegated_pool // ""),
      (.[0].delegated_drep // "")
    ] | map(tostring) | join("\u001f")
  ' "${response_file}" 2>/dev/null)" || return 1
  IFS=$'\037' read -r \
    CNTOOLS_WALLET_REGISTERED \
    CNTOOLS_WALLET_REWARD_LOVELACE \
    CNTOOLS_WALLET_POOL_DELEGATION \
    CNTOOLS_WALLET_DREP_DELEGATION <<< "${record}"
  [[ "${CNTOOLS_WALLET_REWARD_LOVELACE}" =~ ^[0-9]+$ ]] || return 1
}

cntools_wallet_query_koios() {
  local base_address="${1:-}"
  local payment_address="${2:-}"
  local reward_address="${3:-}"
  local attempted=0
  local succeeded=0
  local partial=0

  if [[ -n "${base_address}" || -n "${payment_address}" ]]; then
    attempted=$((attempted + 1))
    if cntools_wallet_query_koios_addresses \
        "${base_address}" "${payment_address}"; then
      succeeded=$((succeeded + 1))
    elif (( CNTOOLS_WALLET_FUNDING_SUCCEEDED > 0 )); then
      partial=1
    fi
  fi
  if [[ -n "${reward_address}" ]]; then
    attempted=$((attempted + 1))
    cntools_wallet_query_koios_stake "${reward_address}" &&
      succeeded=$((succeeded + 1))
  fi
  if (( attempted == 0 )); then
    CNTOOLS_WALLET_QUERY_STATUS="unavailable"
    CNTOOLS_WALLET_QUERY_MESSAGE="This wallet has no valid address files to query."
  elif (( succeeded == attempted )); then
    CNTOOLS_WALLET_QUERY_STATUS="available"
    CNTOOLS_WALLET_QUERY_MESSAGE="Live data from Koios."
  elif (( succeeded > 0 || partial > 0 )); then
    CNTOOLS_WALLET_QUERY_STATUS="partial"
    CNTOOLS_WALLET_QUERY_MESSAGE="Some Koios wallet queries failed; available results are shown."
  else
    CNTOOLS_WALLET_QUERY_STATUS="unavailable"
    CNTOOLS_WALLET_QUERY_MESSAGE="Koios could not return wallet data."
  fi
}

cntools_wallet_query_finalize_funding() {
  local expected="${CNTOOLS_WALLET_FUNDING_EXPECTED:-0}"
  local succeeded="${CNTOOLS_WALLET_FUNDING_SUCCEEDED:-0}"
  local balance_count=0
  local total=0

  [[ "${expected}" =~ ^[0-9]+$ ]] || expected=0
  [[ "${succeeded}" =~ ^[0-9]+$ ]] || succeeded=0
  if (( expected > 0 && succeeded == expected )); then
    if [[ "${CNTOOLS_WALLET_BASE_LOVELACE}" =~ ^[0-9]+$ ]]; then
      total=$((total + 10#${CNTOOLS_WALLET_BASE_LOVELACE}))
      balance_count=$((balance_count + 1))
    fi
    if [[ "${CNTOOLS_WALLET_PAYMENT_LOVELACE}" =~ ^[0-9]+$ ]]; then
      total=$((total + 10#${CNTOOLS_WALLET_PAYMENT_LOVELACE}))
      balance_count=$((balance_count + 1))
    fi
    if (( balance_count == expected )) &&
       [[ "${CNTOOLS_WALLET_UTXO_COUNT}" =~ ^[0-9]+$ &&
          "${CNTOOLS_WALLET_ASSET_COUNT}" =~ ^[0-9]+$ ]]; then
      CNTOOLS_WALLET_TOTAL_LOVELACE="${total}"
      return 0
    fi
    cntools_wallet_log ERROR \
      "Funding query completed without a complete aggregate result"
  fi

  CNTOOLS_WALLET_TOTAL_LOVELACE=""
  CNTOOLS_WALLET_UTXO_COUNT=""
  CNTOOLS_WALLET_ASSET_COUNT=""
}

cntools_wallet_query() {
  local base_address="${1:-}"
  local payment_address="${2:-}"
  local reward_address="${3:-}"

  cntools_wallet_query_reset
  if [[ -n "${base_address}" && "${base_address}" == "${payment_address}" ]]; then
    payment_address=""
    cntools_wallet_log WALLET \
      "Identical base and payment address detected; querying it once"
  fi
  [[ -z "${base_address}" ]] ||
    CNTOOLS_WALLET_FUNDING_EXPECTED=$((CNTOOLS_WALLET_FUNDING_EXPECTED + 1))
  [[ -z "${payment_address}" ]] ||
    CNTOOLS_WALLET_FUNDING_EXPECTED=$((CNTOOLS_WALLET_FUNDING_EXPECTED + 1))
  case "${CNTOOLS_MODE:-offline}" in
    offline)
      CNTOOLS_WALLET_QUERY_STATUS="offline"
      CNTOOLS_WALLET_QUERY_MESSAGE="Offline mode — live balances and delegation are not queried."
      cntools_wallet_log WALLET "wallet query skipped in offline mode"
      ;;
    local)
      cntools_wallet_query_local \
        "${base_address}" "${payment_address}" "${reward_address}"
      ;;
    light)
      cntools_wallet_query_koios \
        "${base_address}" "${payment_address}" "${reward_address}"
      ;;
    *) return 2 ;;
  esac
  cntools_wallet_query_finalize_funding
  cntools_wallet_log WALLET \
    "wallet query status=${CNTOOLS_WALLET_QUERY_STATUS} backend=${CNTOOLS_BACKEND}"
}

cntools_wallet_list_query_reset() {
  local index=0

  CNTOOLS_WALLET_LIST_BASE_ADDRESSES=()
  CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES=()
  CNTOOLS_WALLET_LIST_REWARD_ADDRESSES=()
  CNTOOLS_WALLET_LIST_UTXO_LOVELACE=()
  CNTOOLS_WALLET_LIST_REWARD_LOVELACE=()
  CNTOOLS_WALLET_LIST_TOTAL_LOVELACE=()
  CNTOOLS_WALLET_LIST_TOKEN_COUNTS=()
  CNTOOLS_WALLET_LIST_QUERY_STATUSES=()
  CNTOOLS_WALLET_LIST_ADDRESS_BALANCES=()
  CNTOOLS_WALLET_LIST_ADDRESS_ASSETS=()
  CNTOOLS_WALLET_LIST_STAKE_REWARDS=()
  CNTOOLS_WALLET_LIST_QUERY_LEVEL=""
  CNTOOLS_WALLET_LIST_QUERY_SUMMARY=""
  for (( index = 0; index < ${#CNTOOLS_WALLET_NAMES[@]}; index++ )); do
    CNTOOLS_WALLET_LIST_BASE_ADDRESSES[index]=""
    CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES[index]=""
    CNTOOLS_WALLET_LIST_REWARD_ADDRESSES[index]=""
    CNTOOLS_WALLET_LIST_UTXO_LOVELACE[index]=""
    CNTOOLS_WALLET_LIST_REWARD_LOVELACE[index]=""
    CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[index]=""
    CNTOOLS_WALLET_LIST_TOKEN_COUNTS[index]=""
    CNTOOLS_WALLET_LIST_QUERY_STATUSES[index]="unavailable"
  done
}

cntools_wallet_list_collect_addresses() {
  local index=0
  local kind=""
  local value=""
  local status=0

  for (( index = 0; index < ${#CNTOOLS_WALLET_PATHS[@]}; index++ )); do
    for kind in base payment reward; do
      value=""
      if cntools_wallet_read_address \
          "${CNTOOLS_WALLET_PATHS[index]}" "${kind}" value; then
        status=0
      else
        status=$?
      fi
      case "${status}" in
        0)
          case "${kind}" in
            base) CNTOOLS_WALLET_LIST_BASE_ADDRESSES[index]="${value}" ;;
            payment) CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES[index]="${value}" ;;
            reward) CNTOOLS_WALLET_LIST_REWARD_ADDRESSES[index]="${value}" ;;
          esac
          ;;
        1) ;;
        2) ;;
        *) return "${status}" ;;
      esac
    done
  done
}

cntools_wallet_list_koios_payload() {
  local _cntools_field="${1:-}"
  local _cntools_output_name="${2:-}"
  local _cntools_payload=""
  shift 2 || return 2

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && $# -gt 0 ]] ||
    return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  case "${_cntools_field}" in
    _addresses)
      _cntools_payload="$(printf '%s\n' "$@" | jq -Rsc '
        split("\n") | map(select(length > 0)) | {_addresses: .}
      ')" || return 1
      ;;
    _stake_addresses)
      _cntools_payload="$(printf '%s\n' "$@" | jq -Rsc '
        split("\n") | map(select(length > 0)) | {_stake_addresses: .}
      ')" || return 1
      ;;
    *) return 2 ;;
  esac
  _cntools_output_ref="${_cntools_payload}"
}

cntools_wallet_list_query_koios_address_batch() {
  local response_file=""
  local payload=""
  local requested=""
  local address=""
  local balance=""
  local asset_id=""
  local balance_rows=""
  local asset_rows=""
  local -A batch_balances=()
  local -A batch_assets=()

  (( $# > 0 )) || return 2
  cntools_wallet_query_temp_file response_file || return 1
  cntools_wallet_list_koios_payload _addresses payload "$@" || return 1
  requested="$(jq -c '._addresses' <<< "${payload}")" || return 1
  if ! cntools_wallet_query_http \
      "${CNTOOLS_KOIOS_API%/}/address_info" \
      "${payload}" "${response_file}"; then
    cntools_wallet_log ERROR "Koios address_info batch request failed"
    return 1
  fi
  jq -e --argjson requested "${requested}" '
    def uint:
      type == "string" and test("^[0-9]+$");
    def policy_id:
      type == "string" and test("^[0-9a-fA-F]{56}$");
    def asset_name:
      type == "null" or
      (type == "string" and test("^([0-9a-fA-F]{2}){0,32}$"));
    type == "array" and
    all(.[];
      (.address | type == "string") and
      (.address as $address | ($requested | index($address)) != null) and
      (.balance | uint) and
      (.utxo_set | type == "array") and
      all(.utxo_set[];
        (.asset_list | type == "array") and
        all(.asset_list[];
          (.policy_id | policy_id) and
          (.asset_name | asset_name)))) and
    ([.[].address] | unique | length) == length
  ' "${response_file}" >/dev/null 2>&1 || {
    cntools_wallet_log ERROR "Koios address_info batch returned invalid JSON"
    return 1
  }
  balance_rows="$(jq -r \
    '.[] | [.address, .balance] | @tsv' "${response_file}")" || return 1
  while IFS=$'\t' read -r address balance; do
    [[ -n "${address}" || -n "${balance}" ]] || continue
    [[ -n "${address}" && "${balance}" =~ ^[0-9]+$ ]] || return 1
    batch_balances["${address}"]="${balance}"
  done <<< "${balance_rows}"
  asset_rows="$(jq -r '
    .[] as $row
    | $row.utxo_set[].asset_list[]?
    | [$row.address, (.policy_id + "." + (.asset_name // ""))]
    | @tsv
  ' "${response_file}")" || return 1
  while IFS=$'\t' read -r address asset_id; do
    [[ -n "${address}" && -n "${asset_id}" ]] || continue
    batch_assets["${address}"]+="${asset_id}"$'\037'
  done <<< "${asset_rows}"
  for address in "${!batch_balances[@]}"; do
    CNTOOLS_WALLET_LIST_ADDRESS_BALANCES["${address}"]="${batch_balances[${address}]}"
    CNTOOLS_WALLET_LIST_ADDRESS_ASSETS["${address}"]="${batch_assets[${address}]:-}"
  done
}

cntools_wallet_list_query_koios_stake_batch() {
  local response_file=""
  local payload=""
  local requested=""
  local reward_address=""
  local reward_lovelace=""
  local reward_rows=""
  local -A batch_rewards=()

  (( $# > 0 )) || return 2
  cntools_wallet_query_temp_file response_file || return 1
  cntools_wallet_list_koios_payload _stake_addresses payload "$@" || return 1
  requested="$(jq -c '._stake_addresses' <<< "${payload}")" || return 1
  if ! cntools_wallet_query_http \
      "${CNTOOLS_KOIOS_API%/}/account_info" \
      "${payload}" "${response_file}"; then
    cntools_wallet_log ERROR "Koios account_info batch request failed"
    return 1
  fi
  jq -e --argjson requested "${requested}" '
    def uint:
      type == "string" and test("^[0-9]+$");
    type == "array" and
    all(.[];
      (.stake_address | type == "string") and
      (.stake_address as $address | ($requested | index($address)) != null) and
      (.status == "registered" or .status == "not registered") and
      (.rewards_available | uint)) and
    ([.[].stake_address] | unique | length) == length
  ' "${response_file}" >/dev/null 2>&1 || {
    cntools_wallet_log ERROR "Koios account_info batch returned invalid JSON"
    return 1
  }
  # Build a complete batch locally before committing it. A successful Koios
  # response omits valid reward addresses that have never been registered;
  # those are known zero-reward accounts, not missing data.
  for reward_address in "$@"; do
    batch_rewards["${reward_address}"]=0
  done
  reward_rows="$(jq -r '
    .[] | [.stake_address, .rewards_available] | @tsv
  ' "${response_file}")" || return 1
  while IFS=$'\t' read -r reward_address reward_lovelace; do
    [[ -n "${reward_address}" || -n "${reward_lovelace}" ]] || continue
    [[ -n "${reward_address}" && "${reward_lovelace}" =~ ^[0-9]+$ ]] ||
      return 1
    batch_rewards["${reward_address}"]="${reward_lovelace}"
  done <<< "${reward_rows}"
  for reward_address in "${!batch_rewards[@]}"; do
    CNTOOLS_WALLET_LIST_STAKE_REWARDS["${reward_address}"]="${batch_rewards[${reward_address}]}"
  done
}

cntools_wallet_list_query_koios_funding() {
  local address=""
  local payload=""
  local status=0
  local -a addresses=()
  local -a batch=()
  local -a candidate=()
  local -A seen=()

  for address in \
    "${CNTOOLS_WALLET_LIST_BASE_ADDRESSES[@]}" \
    "${CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES[@]}"; do
    [[ -n "${address}" && -z "${seen[${address}]+x}" ]] || continue
    seen["${address}"]=1
    addresses+=("${address}")
  done
  for address in "${addresses[@]}"; do
    candidate=("${batch[@]}" "${address}")
    cntools_wallet_list_koios_payload _addresses payload \
      "${candidate[@]}" || return 1
    if (( ${#payload} > CNTOOLS_WALLET_KOIOS_PAYLOAD_MAX_BYTES &&
          ${#batch[@]} > 0 )); then
      cntools_wallet_list_query_koios_address_batch "${batch[@]}" || status=1
      batch=("${address}")
    else
      batch=("${candidate[@]}")
    fi
  done
  (( ${#batch[@]} == 0 )) ||
    cntools_wallet_list_query_koios_address_batch "${batch[@]}" || status=1
  return "${status}"
}

cntools_wallet_list_query_koios_stakes() {
  local address=""
  local payload=""
  local status=0
  local -a addresses=()
  local -a batch=()
  local -a candidate=()
  local -A seen=()

  for address in "${CNTOOLS_WALLET_LIST_REWARD_ADDRESSES[@]}"; do
    [[ -n "${address}" && -z "${seen[${address}]+x}" ]] || continue
    seen["${address}"]=1
    addresses+=("${address}")
  done
  for address in "${addresses[@]}"; do
    candidate=("${batch[@]}" "${address}")
    cntools_wallet_list_koios_payload _stake_addresses payload \
      "${candidate[@]}" || return 1
    if (( ${#payload} > CNTOOLS_WALLET_KOIOS_PAYLOAD_MAX_BYTES &&
          ${#batch[@]} > 0 )); then
      cntools_wallet_list_query_koios_stake_batch "${batch[@]}" || status=1
      batch=("${address}")
    else
      batch=("${candidate[@]}")
    fi
  done
  (( ${#batch[@]} == 0 )) ||
    cntools_wallet_list_query_koios_stake_batch "${batch[@]}" || status=1
  return "${status}"
}

cntools_wallet_list_project_koios_results() {
  local index=0
  local address=""
  local reward_address=""
  local asset_list=""
  local asset_id=""
  local expected=0
  local matched=0
  local utxo_lovelace=0
  local -a address_assets=()
  local -A wallet_addresses=()
  local -A wallet_assets=()

  for (( index = 0; index < ${#CNTOOLS_WALLET_NAMES[@]}; index++ )); do
    expected=0
    matched=0
    utxo_lovelace=0
    wallet_addresses=()
    wallet_assets=()
    for address in \
      "${CNTOOLS_WALLET_LIST_BASE_ADDRESSES[index]}" \
      "${CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES[index]}"; do
      [[ -n "${address}" && -z "${wallet_addresses[${address}]+x}" ]] ||
        continue
      wallet_addresses["${address}"]=1
      expected=$((expected + 1))
      if [[ -n "${CNTOOLS_WALLET_LIST_ADDRESS_BALANCES[${address}]+x}" ]]; then
        matched=$((matched + 1))
        utxo_lovelace=$((
          utxo_lovelace +
          10#${CNTOOLS_WALLET_LIST_ADDRESS_BALANCES[${address}]}
        ))
        asset_list="${CNTOOLS_WALLET_LIST_ADDRESS_ASSETS[${address}]:-}"
        address_assets=()
        IFS=$'\037' read -r -a address_assets <<< "${asset_list}"
        for asset_id in "${address_assets[@]}"; do
          [[ -n "${asset_id}" ]] || continue
          wallet_assets["${asset_id}"]=1
        done
      fi
    done
    if (( expected > 0 && matched == expected )); then
      CNTOOLS_WALLET_LIST_UTXO_LOVELACE[index]="${utxo_lovelace}"
      CNTOOLS_WALLET_LIST_TOKEN_COUNTS[index]="${#wallet_assets[@]}"
    fi
    reward_address="${CNTOOLS_WALLET_LIST_REWARD_ADDRESSES[index]}"
    if [[ -n "${reward_address}" &&
          -n "${CNTOOLS_WALLET_LIST_STAKE_REWARDS[${reward_address}]+x}" ]]; then
      CNTOOLS_WALLET_LIST_REWARD_LOVELACE[index]="${CNTOOLS_WALLET_LIST_STAKE_REWARDS[${reward_address}]}"
    fi
  done
}

cntools_wallet_list_query_local() {
  local index=0

  for (( index = 0; index < ${#CNTOOLS_WALLET_NAMES[@]}; index++ )); do
    cntools_wallet_query \
      "${CNTOOLS_WALLET_LIST_BASE_ADDRESSES[index]}" \
      "${CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES[index]}" \
      "${CNTOOLS_WALLET_LIST_REWARD_ADDRESSES[index]}"
    [[ ! "${CNTOOLS_WALLET_TOTAL_LOVELACE}" =~ ^[0-9]+$ ]] ||
      CNTOOLS_WALLET_LIST_UTXO_LOVELACE[index]="${CNTOOLS_WALLET_TOTAL_LOVELACE}"
    [[ ! "${CNTOOLS_WALLET_REWARD_LOVELACE}" =~ ^[0-9]+$ ]] ||
      CNTOOLS_WALLET_LIST_REWARD_LOVELACE[index]="${CNTOOLS_WALLET_REWARD_LOVELACE}"
    [[ ! "${CNTOOLS_WALLET_ASSET_COUNT}" =~ ^[0-9]+$ ]] ||
      CNTOOLS_WALLET_LIST_TOKEN_COUNTS[index]="${CNTOOLS_WALLET_ASSET_COUNT}"
    cntools_wallet_query_cleanup
    if [[ -n "${CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE}" ]]; then
      CNTOOLS_WALLET_LIST_QUERY_LEVEL="warn"
      CNTOOLS_WALLET_LIST_QUERY_SUMMARY="Local wallet queries stopped after a backend failure; remaining values are shown as —."
      cntools_wallet_log ERROR \
        "Local wallet catalog query stopped systemic=${CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE}"
      break
    fi
  done
}

cntools_wallet_list_local_preflight() {
  if [[ -z "${CNTOOLS_CLI:-}" || ! -x "${CNTOOLS_CLI}" ]]; then
    CNTOOLS_WALLET_LIST_QUERY_LEVEL="error"
    CNTOOLS_WALLET_LIST_QUERY_SUMMARY="The deployment's Cardano CLI is unavailable."
    cntools_wallet_log ERROR "Local wallet catalog query has no executable Cardano CLI"
    return 1
  fi
  if ! cntools_wallet_query_local_socket_ready; then
    CNTOOLS_WALLET_LIST_QUERY_LEVEL="error"
    CNTOOLS_WALLET_LIST_QUERY_SUMMARY="The local node socket is unavailable: ${CNTOOLS_SOCKET}."
    cntools_wallet_log ERROR \
      "Local wallet catalog query socket is unavailable: ${CNTOOLS_SOCKET}"
    return 1
  fi
  if ! cntools_wallet_query_network_arguments; then
    CNTOOLS_WALLET_LIST_QUERY_LEVEL="error"
    CNTOOLS_WALLET_LIST_QUERY_SUMMARY="The selected network has no local CLI mapping."
    cntools_wallet_log ERROR \
      "Local wallet catalog query has unsupported network=${CNTOOLS_NETWORK}"
    return 1
  fi
}

cntools_wallet_list_finalize_results() {
  local index=0
  local available=0
  local partial=0
  local unavailable=0
  local utxo=""
  local rewards=""

  for (( index = 0; index < ${#CNTOOLS_WALLET_NAMES[@]}; index++ )); do
    utxo="${CNTOOLS_WALLET_LIST_UTXO_LOVELACE[index]}"
    rewards="${CNTOOLS_WALLET_LIST_REWARD_LOVELACE[index]}"
    if [[ "${utxo}" =~ ^[0-9]+$ && "${rewards}" =~ ^[0-9]+$ ]]; then
      CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[index]=$((10#${utxo} + 10#${rewards}))
      CNTOOLS_WALLET_LIST_QUERY_STATUSES[index]="available"
      available=$((available + 1))
    elif [[ "${utxo}" =~ ^[0-9]+$ || "${rewards}" =~ ^[0-9]+$ ]]; then
      CNTOOLS_WALLET_LIST_QUERY_STATUSES[index]="partial"
      partial=$((partial + 1))
    else
      CNTOOLS_WALLET_LIST_QUERY_STATUSES[index]="unavailable"
      unavailable=$((unavailable + 1))
    fi
  done

  case "${CNTOOLS_MODE:-offline}" in
    offline)
      CNTOOLS_WALLET_LIST_QUERY_LEVEL="warn"
      CNTOOLS_WALLET_LIST_QUERY_SUMMARY="Offline mode — live wallet balances are not queried."
      ;;
    local) if [[ "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" != "true" ]]; then
      CNTOOLS_WALLET_LIST_QUERY_LEVEL="warn"
      CNTOOLS_WALLET_LIST_QUERY_SUMMARY="${CNTOOLS_IMPLEMENTATION_NAME} does not provide local wallet queries."
    fi ;;
  esac
  [[ -n "${CNTOOLS_WALLET_LIST_QUERY_SUMMARY}" ]] && return 0
  if (( unavailable > 0 && available == 0 && partial == 0 )); then
    CNTOOLS_WALLET_LIST_QUERY_LEVEL="error"
    CNTOOLS_WALLET_LIST_QUERY_SUMMARY="Live wallet balances are unavailable. See ${CNTOOLS_LOG}."
  elif (( unavailable > 0 || partial > 0 )); then
    CNTOOLS_WALLET_LIST_QUERY_LEVEL="warn"
    CNTOOLS_WALLET_LIST_QUERY_SUMMARY="Some wallet balances are unavailable; incomplete totals are shown as —."
  fi
}

cntools_wallet_list_query_catalog() {
  cntools_wallet_list_query_reset
  cntools_wallet_list_collect_addresses || return 1
  case "${CNTOOLS_MODE:-offline}" in
    offline) ;;
    local)
      if [[ "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == "true" ]]; then
        cntools_wallet_list_local_preflight &&
          cntools_wallet_list_query_local
      fi
      ;;
    light)
      cntools_wallet_list_query_koios_funding || true
      cntools_wallet_list_query_koios_stakes || true
      cntools_wallet_list_project_koios_results
      cntools_wallet_query_cleanup
      ;;
    *) return 2 ;;
  esac
  cntools_wallet_list_finalize_results
  cntools_wallet_log WALLET \
    "wallet catalog query completed backend=${CNTOOLS_BACKEND} wallets=${#CNTOOLS_WALLET_NAMES[@]}"
}

cntools_wallet_format_lovelace_compact() {
  local amount="${1:-}"
  local whole=0
  local fraction=0
  local scaled_whole=0
  local scaled_fraction=0
  local divisor=0
  local suffix=""

  [[ "${amount}" =~ ^[0-9]+$ ]] || {
    printf '—\n'
    return 0
  }
  whole=$((10#${amount} / 1000000))
  fraction=$((10#${amount} % 1000000))
  if (( whole < 100000000 )); then
    printf '%d.%06d\n' "${whole}" "${fraction}"
    return 0
  fi
  if (( whole >= 1000000000 )); then
    divisor=1000000000
    suffix="B"
  else
    divisor=1000000
    suffix="M"
  fi
  scaled_whole=$((whole / divisor))
  scaled_fraction=$((((whole % divisor) * 1000) / divisor))
  printf '%d.%03d%s\n' "${scaled_whole}" "${scaled_fraction}" "${suffix}"
}

cntools_wallet_format_lovelace() {
  local amount="${1:-}"
  local whole=0
  local fraction=0

  [[ "${amount}" =~ ^[0-9]+$ ]] || {
    printf 'Unavailable\n'
    return 0
  }
  whole=$((amount / 1000000))
  fraction=$((amount % 1000000))
  printf '%d.%06d ADA\n' "${whole}" "${fraction}"
}

cntools_wallet_display_address() {
  local _cntools_wallet_directory="${1:-}"
  local _cntools_kind="${2:-}"
  local _cntools_output_name="${3:-}"
  local _cntools_display_address_value=""
  local _cntools_status=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if cntools_wallet_read_address \
      "${_cntools_wallet_directory}" "${_cntools_kind}" \
      _cntools_display_address_value; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  case "${_cntools_status}" in
    0) _cntools_output_ref="${_cntools_display_address_value}" ;;
    1) _cntools_output_ref="Not available" ;;
    2)
      _cntools_output_ref="Invalid address file"
      cntools_wallet_log ERROR \
        "Invalid ${_cntools_kind} address file in wallet=${CNTOOLS_WALLET_SELECTED_NAME}"
      ;;
    *) return "${_cntools_status}" ;;
  esac
}

cntools_wallet_render_query() {
  local level="info"

  case "${CNTOOLS_WALLET_QUERY_STATUS}" in
    available) level="success" ;;
    partial) level="warn" ;;
    unavailable) level="error" ;;
    offline|unsupported) level="warn" ;;
  esac
  cntools_ui_render_status "${level}" "${CNTOOLS_WALLET_QUERY_MESSAGE}"
  if [[ "${CNTOOLS_WALLET_TOTAL_LOVELACE}" =~ ^[0-9]+$ ]]; then
    cntools_ui_render_field "Total" \
      "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_TOTAL_LOVELACE}")"
  fi
  if [[ "${CNTOOLS_WALLET_BASE_LOVELACE}" =~ ^[0-9]+$ ]]; then
    cntools_ui_render_field "Base funds" \
      "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_BASE_LOVELACE}")"
  fi
  if [[ "${CNTOOLS_WALLET_PAYMENT_LOVELACE}" =~ ^[0-9]+$ ]]; then
    cntools_ui_render_field "Payment funds" \
      "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_PAYMENT_LOVELACE}")"
  fi
  [[ ! "${CNTOOLS_WALLET_REWARD_LOVELACE}" =~ ^[0-9]+$ ]] ||
    cntools_ui_render_field "Rewards" \
      "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_REWARD_LOVELACE}")"
  [[ "${CNTOOLS_WALLET_REGISTERED}" == "unknown" ]] ||
    cntools_ui_render_field "Registered" "${CNTOOLS_WALLET_REGISTERED}"
  [[ -z "${CNTOOLS_WALLET_POOL_DELEGATION}" ]] ||
    cntools_ui_render_field "Stake pool" "${CNTOOLS_WALLET_POOL_DELEGATION}"
  [[ -z "${CNTOOLS_WALLET_DREP_DELEGATION}" ]] ||
    cntools_ui_render_field "DRep" "${CNTOOLS_WALLET_DREP_DELEGATION}"
  [[ ! "${CNTOOLS_WALLET_UTXO_COUNT}" =~ ^[0-9]+$ ]] ||
    cntools_ui_render_field "UTxOs" "${CNTOOLS_WALLET_UTXO_COUNT}"
  [[ ! "${CNTOOLS_WALLET_ASSET_COUNT}" =~ ^[0-9]+$ ]] ||
    cntools_ui_render_field "Native assets" "${CNTOOLS_WALLET_ASSET_COUNT}"
}

cntools_wallet_action_show() {
  local selected_index=""
  local selector_status=0
  local wallet_directory=""
  local base_address=""
  local payment_address=""
  local reward_address=""
  local query_base=""
  local query_payment=""
  local query_reward=""

  trap 'cntools_wallet_query_cleanup' EXIT
  cntools_ui_action_begin "Show" "/ Wallet / Show"
  if ! cntools_wallet_catalog_build; then
    cntools_ui_render_status error \
      "The wallet directory could not be read safely. See ${CNTOOLS_LOG}."
    cntools_ui_wait
    return 1
  fi
  if (( ${#CNTOOLS_WALLET_NAMES[@]} == 0 )); then
    cntools_ui_render_status warn "No wallets are available."
    cntools_ui_wait
    return 0
  fi
  if cntools_wallet_choose selected_index; then
    selector_status=0
  else
    selector_status=$?
  fi
  if (( selector_status == 1 )); then
    cntools_wallet_log CHOICE "wallet selection cancelled"
    cntools_gum_clear
    return 0
  elif (( selector_status != 0 )); then
    cntools_wallet_log ERROR \
      "wallet selection failed status=${selector_status}"
    return "${selector_status}"
  fi

  wallet_directory="${CNTOOLS_WALLET_PATHS[selected_index]}"
  CNTOOLS_WALLET_SELECTED_NAME="${CNTOOLS_WALLET_NAMES[selected_index]}"
  cntools_wallet_display_address "${wallet_directory}" base base_address || return 1
  cntools_wallet_display_address "${wallet_directory}" payment payment_address || return 1
  cntools_wallet_display_address "${wallet_directory}" reward reward_address || return 1
  [[ "${base_address}" == addr* ]] && query_base="${base_address}"
  [[ "${payment_address}" == addr* ]] && query_payment="${payment_address}"
  [[ "${reward_address}" == stake* ]] && query_reward="${reward_address}"

  cntools_ui_action_begin "Show" "/ Wallet / Show"
  cntools_ui_render_field "Wallet" "${CNTOOLS_WALLET_SELECTED_NAME}"
  cntools_ui_render_field "Type" "${CNTOOLS_WALLET_TYPES[selected_index]}"
  cntools_ui_render_field "Keys" "${CNTOOLS_WALLET_PROTECTIONS[selected_index]}"
  printf '\n'
  cntools_ui_render_detail "Addresses"
  cntools_ui_render_field "Base" "${base_address}"
  cntools_ui_render_field "Payment" "${payment_address}"
  cntools_ui_render_field "Reward" "${reward_address}"
  printf '\n'
  cntools_wallet_query "${query_base}" "${query_payment}" "${query_reward}"
  cntools_wallet_render_query
  cntools_ui_wait
}
