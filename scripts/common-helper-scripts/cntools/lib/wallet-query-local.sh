#!/usr/bin/env bash
# Local CLI wallet data parsing and collection.
# shellcheck disable=SC2034

cntools_wallet_query_local_utxo_rows() {
  local source_file="${1:-}"

  [[ -f "${source_file}" && ! -L "${source_file}" ]] || return 2
  LC_ALL=C awk '
    BEGIN {
      separator = sprintf("%c", 31)
      depth = 0
      in_string = 0
      escaped = 0
      have_string = 0
      expect_value = 0
      fatal = 0
    }
    function fail(status) {
      fatal = status
      exit status
    }
    {
      input = $0 "\n"
      for (position = 1; position <= length(input); position++) {
        character = substr(input, position, 1)
        if (in_string) {
          if (escaped) {
            token = token character
            escaped = 0
          } else if (character == "\\") {
            token = token character
            escaped = 1
          } else if (character == "\"") {
            in_string = 0
            have_string = 1
            last_string = token
            token = ""
          } else {
            token = token character
          }
          continue
        }
        if (character ~ /[ \t\r\n]/) {
          continue
        }
        if (have_string) {
          if (character == ":") {
            pending_key[depth] = last_string
            expect_value = 1
            have_string = 0
            continue
          }
          have_string = 0
          expect_value = 0
        }
        if (character == "\"") {
          in_string = 1
          token = ""
          continue
        }
        if (character == "{") {
          object_key = expect_value ? pending_key[depth] : ""
          depth++
          path_key[depth] = object_key
          if (depth == 2 && object_key != "") {
            print "U" separator object_key
          }
          expect_value = 0
          continue
        }
        if (character == "}") {
          if (depth < 1) {
            fail(3)
          }
          delete path_key[depth]
          delete pending_key[depth]
          depth--
          expect_value = 0
          continue
        }
        if (character == "[") {
          expect_value = 0
          continue
        }
        if (character ~ /[-0-9]/) {
          number = character
          while (position < length(input) &&
                 substr(input, position + 1, 1) ~ /[0-9eE+.-]/) {
            position++
            number = number substr(input, position, 1)
          }
          key = pending_key[depth]
          if (depth == 3 && path_key[3] == "value" &&
              key == "lovelace") {
            if (number !~ /^[0-9]+$/ || length(number) > 80) {
              fail(2)
            }
            print "L" separator number
          } else if (depth == 4 && path_key[3] == "value") {
            if (number !~ /^[0-9]+$/ || length(number) > 80) {
              fail(2)
            }
            print "A" separator path_key[4] separator key separator number
          }
          expect_value = 0
          continue
        }
        if (character == "," || character == "]") {
          expect_value = 0
          continue
        }
        expect_value = 0
      }
    }
    END {
      if (fatal) {
        exit fatal
      }
      if (in_string || depth != 0) {
        exit 3
      }
    }
  ' "${source_file}"
}


cntools_wallet_query_json_uint_field() {
  local _cntools_output_name="${1:-}"
  local _cntools_source_file="${2:-}"
  local _cntools_field_name="${3:-}"
  local _cntools_value=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_field_name}" =~ ^[A-Za-z][A-Za-z0-9]*$ &&
     -f "${_cntools_source_file}" &&
     ! -L "${_cntools_source_file}" ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_value="$(LC_ALL=C awk -v target="${_cntools_field_name}" '
    BEGIN {
      in_string = 0
      escaped = 0
      have_string = 0
      expect_value = 0
      matches = 0
      fatal = 0
    }
    function fail(status) {
      fatal = status
      exit status
    }
    {
      input = $0 "\n"
      for (position = 1; position <= length(input); position++) {
        character = substr(input, position, 1)
        if (in_string) {
          if (escaped) {
            token = token character
            escaped = 0
          } else if (character == "\\") {
            token = token character
            escaped = 1
          } else if (character == "\"") {
            in_string = 0
            have_string = 1
            last_string = token
            token = ""
          } else {
            token = token character
          }
          continue
        }
        if (character ~ /[ \t\r\n]/) {
          continue
        }
        if (have_string) {
          if (character == ":") {
            pending_key = last_string
            expect_value = 1
            have_string = 0
            continue
          }
          have_string = 0
          expect_value = 0
        }
        if (character == "\"") {
          in_string = 1
          token = ""
          continue
        }
        if (character ~ /[-0-9]/) {
          number = character
          while (position < length(input) &&
                 substr(input, position + 1, 1) ~ /[0-9eE+.-]/) {
            position++
            number = number substr(input, position, 1)
          }
          if (expect_value && pending_key == target) {
            if (number !~ /^[0-9]+$/ || length(number) > 80) {
              fail(2)
            }
            print number
            matches++
          }
          expect_value = 0
          continue
        }
        expect_value = 0
      }
    }
    END {
      if (fatal) {
        exit fatal
      }
      if (in_string || matches != 1) {
        exit 3
      }
    }
  ' "${_cntools_source_file}")" || return 1
  [[ "${_cntools_value}" =~ ^[0-9]+$ &&
     ${#_cntools_value} -le 80 ]] || return 1
  _cntools_output_ref="${_cntools_value}"
}


cntools_wallet_query_local_address() {
  local address="${1:-}"
  local kind="${2:-}"
  local output_file=""
  local error_file=""
  local balance="0"
  local utxo_count="0"
  local lovelace_rows=0
  local parsed_output=""
  local row_kind=""
  local asset_policy=""
  local asset_name=""
  local asset_quantity=""
  local asset_id=""
  local asset_parse_failed=0
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
    all(.[];
      type == "object" and
      (.value | type == "object") and
      (.value | has("lovelace")) and
      (.value.lovelace |
        type == "number" and . >= 0 and floor == .) and
      all(.value | to_entries[];
        if .key == "lovelace" then
          (.value | type == "number" and . >= 0 and floor == .)
        else
          (.key | test("^[0-9a-fA-F]{56}$")) and
          (.value | type == "object") and
          all(.value | to_entries[];
            (.key | test("^([0-9a-fA-F]{2}){0,32}$")) and
            (.value | type == "number" and . >= 0 and floor == .))
        end))
  ' "${output_file}" >/dev/null 2>&1 || {
    cntools_wallet_log ERROR "Local ${kind} address query returned invalid JSON"
    return 1
  }
  parsed_output="$(
    cntools_wallet_query_local_utxo_rows "${output_file}"
  )" || {
    cntools_wallet_log ERROR \
      "Local ${kind} address query could not preserve exact JSON quantities"
    return 1
  }
  while IFS=$'\037' read -r \
      row_kind asset_policy asset_name asset_quantity; do
    case "${row_kind}" in
      "") continue ;;
      U) utxo_count=$((utxo_count + 1)) ;;
      L)
        [[ "${asset_policy}" =~ ^[0-9]+$ ]] || {
          asset_parse_failed=1
          break
        }
        cntools_uint_add_into \
          balance "${balance}" "${asset_policy}" || {
            asset_parse_failed=1
            break
          }
        lovelace_rows=$((lovelace_rows + 1))
        ;;
      A)
        asset_id="${asset_policy}.${asset_name}"
        if ! cntools_wallet_asset_add "${asset_id}" "${asset_quantity}"; then
          asset_parse_failed=1
          break
        fi
        ;;
      *)
        asset_parse_failed=1
        break
        ;;
    esac
  done <<< "${parsed_output}"
  (( lovelace_rows == utxo_count )) || asset_parse_failed=1
  if (( asset_parse_failed != 0 )); then
    cntools_wallet_log ERROR \
      "Local ${kind} address query returned an invalid UTxO quantity"
    return 1
  fi
  cntools_wallet_asset_sort_ids || return 1
  CNTOOLS_WALLET_ASSET_COUNT="${#CNTOOLS_WALLET_ASSET_IDS[@]}"
  if [[ "${kind}" == "base" ]]; then
    CNTOOLS_WALLET_BASE_LOVELACE="${balance}"
  else
    CNTOOLS_WALLET_PAYMENT_LOVELACE="${balance}"
  fi
  CNTOOLS_WALLET_UTXO_COUNT=$(( ${CNTOOLS_WALLET_UTXO_COUNT:-0} + utxo_count ))
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
    CNTOOLS_WALLET_STAKE_DEPOSIT=""
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
      pool_delegation,
      $vote_delegation[0],
      $vote_delegation[1]
    ] | map(tostring) | join("\u001f")
  ' "${output_file}" 2>/dev/null)" || return 1
  cntools_wallet_query_json_uint_field \
    CNTOOLS_WALLET_REWARD_LOVELACE "${output_file}" \
    rewardAccountBalance || {
      cntools_wallet_log ERROR \
        "Local stake address query could not preserve the exact reward balance"
      return 1
    }
  if jq -e '.[0].stakeRegistrationDeposit | type == "number"' \
      "${output_file}" >/dev/null 2>&1; then
    cntools_wallet_query_json_uint_field \
      CNTOOLS_WALLET_STAKE_DEPOSIT "${output_file}" \
      stakeRegistrationDeposit || {
        cntools_wallet_log ERROR \
          "Local stake address query could not preserve the exact registration deposit"
        return 1
      }
  else
    CNTOOLS_WALLET_STAKE_DEPOSIT=""
  fi
  IFS=$'\037' read -r \
    CNTOOLS_WALLET_POOL_DELEGATION \
    CNTOOLS_WALLET_DREP_DELEGATION \
    vote_status <<< "${record}"
  [[ "${CNTOOLS_WALLET_REWARD_LOVELACE}" =~ ^[0-9]+$ ]] || return 1
  if [[ -n "${vote_status}" ]]; then
    CNTOOLS_WALLET_DREP_DELEGATION_VALID=N
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
