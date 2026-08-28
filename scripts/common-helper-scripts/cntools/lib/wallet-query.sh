#!/usr/bin/env bash
# Read-only local and Koios wallet queries plus the Wallet > Show workflow.
# Loaded after lib/wallet.sh only by the Show action.
# shellcheck disable=SC2034

declare -ag CNTOOLS_WALLET_QUERY_TEMP_FILES=()
declare -Ag CNTOOLS_WALLET_LOCAL_ASSETS=()

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

cntools_wallet_query_log_stderr() {
  local context="${1:-query failed}"
  local error_file="${2:-}"
  local detail=""

  if [[ -f "${error_file}" && ! -L "${error_file}" ]]; then
    IFS= read -r detail < "${error_file}" || true
    detail="${detail:0:400}"
  fi
  cntools_wallet_log ERROR "${context}${detail:+: ${detail}}"
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
  local -a command_args=()

  [[ -n "${address}" && ( "${kind}" == "base" || "${kind}" == "payment" ) ]] ||
    return 2
  cntools_wallet_query_temp_file output_file || return 1
  cntools_wallet_query_temp_file error_file || return 1
  command_args=(
    env "CARDANO_NODE_SOCKET_PATH=${CNTOOLS_SOCKET}"
    "${CNTOOLS_CLI}" query utxo --address "${address}"
    "${CNTOOLS_WALLET_NETWORK_ARGS[@]}"
    --output-json
  )
  if ! cntools_wallet_query_run_cli \
      "${output_file}" "${error_file}" "${command_args[@]}"; then
    cntools_wallet_query_log_stderr \
      "Local ${kind} address query failed" "${error_file}"
    return 1
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
  local -a command_args=()

  [[ -n "${reward_address}" ]] || return 2
  cntools_wallet_query_temp_file output_file || return 1
  cntools_wallet_query_temp_file error_file || return 1
  command_args=(
    env "CARDANO_NODE_SOCKET_PATH=${CNTOOLS_SOCKET}"
    "${CNTOOLS_CLI}" query stake-address-info --address "${reward_address}"
    "${CNTOOLS_WALLET_NETWORK_ARGS[@]}"
  )
  if ! cntools_wallet_query_run_cli \
      "${output_file}" "${error_file}" "${command_args[@]}"; then
    cntools_wallet_query_log_stderr \
      "Local stake address query failed" "${error_file}"
    return 1
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
    return 0
  fi
  [[ -n "${CNTOOLS_SOCKET:-}" ]] || {
    CNTOOLS_WALLET_QUERY_STATUS="unavailable"
    CNTOOLS_WALLET_QUERY_MESSAGE="The deployment's node socket is not configured."
    cntools_wallet_log ERROR "Local wallet query has no node socket path"
    return 0
  }
  cntools_wallet_query_network_arguments || {
    CNTOOLS_WALLET_QUERY_STATUS="unavailable"
    CNTOOLS_WALLET_QUERY_MESSAGE="The selected network has no local CLI mapping."
    cntools_wallet_log ERROR \
      "Local wallet query has unsupported network=${CNTOOLS_NETWORK}"
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
  if [[ -n "${payment_address}" ]]; then
    attempted=$((attempted + 1))
    if cntools_wallet_query_local_address "${payment_address}" payment; then
      succeeded=$((succeeded + 1))
      CNTOOLS_WALLET_FUNDING_SUCCEEDED=$((
        CNTOOLS_WALLET_FUNDING_SUCCEEDED + 1
      ))
    fi
  fi
  if [[ -n "${reward_address}" ]]; then
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
