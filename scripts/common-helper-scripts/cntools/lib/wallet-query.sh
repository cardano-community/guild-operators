#!/usr/bin/env bash
# Read-only local and Koios wallet queries for Wallet > List and Show.
# Loaded after lib/wallet.sh only by those two actions.
# shellcheck disable=SC2034

declare -ag CNTOOLS_WALLET_QUERY_TEMP_FILES=()
declare -ag CNTOOLS_WALLET_ASSET_IDS=()
declare -Ag CNTOOLS_WALLET_ASSET_QUANTITIES=()
declare -Ag CNTOOLS_WALLET_ASSET_FINGERPRINTS=()
declare -Ag CNTOOLS_WALLET_ASSET_DECIMALS=()
declare -Ag CNTOOLS_WALLET_ASSET_ASCII_NAMES=()
declare -Ag CNTOOLS_WALLET_ASSET_REGISTRY_NAMES=()
declare -Ag CNTOOLS_WALLET_ASSET_TICKERS=()
declare -Ag CNTOOLS_WALLET_ASSET_DESCRIPTIONS=()
declare -Ag CNTOOLS_WALLET_ASSET_URLS=()
declare -Ag CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES=()
declare -Ag CNTOOLS_WALLET_ASSET_METADATA_AVAILABLE=()
declare -Ag CNTOOLS_WALLET_ASSET_METADATA_DECIMALS=()
declare -ag CNTOOLS_WALLET_LIST_BASE_ADDRESSES=()
declare -ag CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES=()
declare -ag CNTOOLS_WALLET_LIST_REWARD_ADDRESSES=()
declare -ag CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE=()
declare -ag CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE=()
declare -ag CNTOOLS_WALLET_LIST_UTXO_LOVELACE=()
declare -ag CNTOOLS_WALLET_LIST_REWARD_LOVELACE=()
declare -ag CNTOOLS_WALLET_LIST_TOTAL_LOVELACE=()
declare -ag CNTOOLS_WALLET_LIST_TOKEN_COUNTS=()
declare -ag CNTOOLS_WALLET_LIST_QUERY_STATUSES=()
declare -Ag CNTOOLS_WALLET_LIST_ADDRESS_BALANCES=()
declare -Ag CNTOOLS_WALLET_LIST_ADDRESS_ASSETS=()
declare -Ag CNTOOLS_WALLET_LIST_STAKE_REWARDS=()

CNTOOLS_WALLET_KOIOS_PAYLOAD_MAX_BYTES=1024
CNTOOLS_WALLET_KOIOS_AUTH_PAYLOAD_MAX_BYTES=5120
CNTOOLS_WALLET_KOIOS_RATE_BATCHES=90
CNTOOLS_WALLET_KOIOS_RATE_PAUSE_SECONDS=10
CNTOOLS_WALLET_KOIOS_ADDRESS_SELECT='?select=address%2Cbalance%3A%3Atext%2Cutxo_set'
CNTOOLS_WALLET_KOIOS_ACCOUNT_SELECT='?select=stake_address%2Cstatus%2Cdelegated_pool%2Cdelegated_drep%2Crewards_available%3A%3Atext'
CNTOOLS_WALLET_KOIOS_ASSET_SELECT='?select=policy_id%2Casset_name%2Casset_name_ascii%2Cfingerprint%2Ctotal_supply%2Cmetadata_name%3Atoken_registry_metadata-%3E%3Ename%2Cmetadata_ticker%3Atoken_registry_metadata-%3E%3Eticker%2Cmetadata_decimals%3Atoken_registry_metadata-%3E%3Edecimals%2Cmetadata_description%3Atoken_registry_metadata-%3E%3Edescription%2Cmetadata_url%3Atoken_registry_metadata-%3E%3Eurl'
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
  CNTOOLS_WALLET_ASSET_METADATA_STATUS="not-requested"
  CNTOOLS_WALLET_ASSET_IDS=()
  CNTOOLS_WALLET_ASSET_QUANTITIES=()
  CNTOOLS_WALLET_ASSET_FINGERPRINTS=()
  CNTOOLS_WALLET_ASSET_DECIMALS=()
  CNTOOLS_WALLET_ASSET_ASCII_NAMES=()
  CNTOOLS_WALLET_ASSET_REGISTRY_NAMES=()
  CNTOOLS_WALLET_ASSET_TICKERS=()
  CNTOOLS_WALLET_ASSET_DESCRIPTIONS=()
  CNTOOLS_WALLET_ASSET_URLS=()
  CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES=()
  CNTOOLS_WALLET_ASSET_METADATA_AVAILABLE=()
  CNTOOLS_WALLET_ASSET_METADATA_DECIMALS=()
  CNTOOLS_WALLET_FUNDING_EXPECTED=0
  CNTOOLS_WALLET_FUNDING_SUCCEEDED=0
  CNTOOLS_WALLET_QUERY_SYSTEMIC_FAILURE=""
}

cntools_wallet_uint_add_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_left="${2:-}"
  local _cntools_right="${3:-}"
  local _cntools_left_index=0
  local _cntools_right_index=0
  local _cntools_left_digit=0
  local _cntools_right_digit=0
  local _cntools_carry=0
  local _cntools_sum=0
  local _cntools_result=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_left}" =~ ^[0-9]+$ &&
     "${_cntools_right}" =~ ^[0-9]+$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_left_index=$((${#_cntools_left} - 1))
  _cntools_right_index=$((${#_cntools_right} - 1))
  while (( _cntools_left_index >= 0 || _cntools_right_index >= 0 ||
           _cntools_carry > 0 )); do
    _cntools_left_digit=0
    _cntools_right_digit=0
    if (( _cntools_left_index >= 0 )); then
      _cntools_left_digit=$((
        10#${_cntools_left:_cntools_left_index:1}
      ))
      _cntools_left_index=$((_cntools_left_index - 1))
    fi
    if (( _cntools_right_index >= 0 )); then
      _cntools_right_digit=$((
        10#${_cntools_right:_cntools_right_index:1}
      ))
      _cntools_right_index=$((_cntools_right_index - 1))
    fi
    _cntools_sum=$((
      _cntools_left_digit + _cntools_right_digit + _cntools_carry
    ))
    _cntools_result="$((_cntools_sum % 10))${_cntools_result}"
    _cntools_carry=$((_cntools_sum / 10))
  done
  [[ "${_cntools_result}" =~ ^0*([1-9][0-9]*|0)$ ]] || return 1
  _cntools_result="${BASH_REMATCH[1]}"
  _cntools_output_ref="${_cntools_result:-0}"
}

cntools_wallet_uint_add() {
  local result=""

  cntools_wallet_uint_add_into result "${1:-}" "${2:-}" || return $?
  printf '%s\n' "${result}"
}

cntools_wallet_asset_sort_ids() {
  local sorted_output=""
  local -a sorted_ids=()

  (( ${#CNTOOLS_WALLET_ASSET_IDS[@]} > 1 )) || return 0
  sorted_output="$(
    printf '%s\n' "${CNTOOLS_WALLET_ASSET_IDS[@]}" | LC_ALL=C sort
  )" || return 1
  mapfile -t sorted_ids <<< "${sorted_output}"
  (( ${#sorted_ids[@]} == ${#CNTOOLS_WALLET_ASSET_IDS[@]} )) || return 1
  CNTOOLS_WALLET_ASSET_IDS=("${sorted_ids[@]}")
}

cntools_wallet_asset_add() {
  local asset_id="${1:-}"
  local quantity="${2:-}"
  local fingerprint="${3:-}"
  local decimals="${4:-}"
  local current=""
  local normalized_quantity=""

  asset_id="${asset_id,,}"
  [[ "${asset_id}" =~ ^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$ &&
     "${quantity}" =~ ^[0-9]+$ && ${#quantity} -le 80 ]] || return 2
  if [[ -z "${CNTOOLS_WALLET_ASSET_QUANTITIES[${asset_id}]+x}" ]]; then
    CNTOOLS_WALLET_ASSET_IDS+=("${asset_id}")
    [[ "${quantity}" =~ ^0*([1-9][0-9]*|0)$ ]] || return 1
    normalized_quantity="${BASH_REMATCH[1]}"
    CNTOOLS_WALLET_ASSET_QUANTITIES["${asset_id}"]="${normalized_quantity}"
  else
    current="${CNTOOLS_WALLET_ASSET_QUANTITIES[${asset_id}]}"
    cntools_wallet_uint_add_into \
      normalized_quantity "${current}" "${quantity}" || return 1
    CNTOOLS_WALLET_ASSET_QUANTITIES["${asset_id}"]="${normalized_quantity}"
  fi
  if [[ -n "${fingerprint}" &&
        "${fingerprint}" =~ ^asset1[023456789acdefghjklmnpqrstuvwxyz]{38}$ ]]; then
    CNTOOLS_WALLET_ASSET_FINGERPRINTS["${asset_id}"]="${fingerprint}"
  fi
  if [[ "${decimals}" =~ ^[0-9]+$ ]]; then
    if (( 10#${decimals} <= 255 )); then
      CNTOOLS_WALLET_ASSET_DECIMALS["${asset_id}"]="$((10#${decimals}))"
    fi
  fi
  CNTOOLS_WALLET_ASSET_COUNT="${#CNTOOLS_WALLET_ASSET_IDS[@]}"
}

cntools_wallet_asset_fill_fingerprints() {
  local asset_id=""
  local policy_id=""
  local asset_name=""
  local fingerprint=""
  local failures=0
  local status=0

  for asset_id in "${CNTOOLS_WALLET_ASSET_IDS[@]}"; do
    [[ -z "${CNTOOLS_WALLET_ASSET_FINGERPRINTS[${asset_id}]:-}" ]] ||
      continue
    policy_id="${asset_id%%.*}"
    asset_name="${asset_id#*.}"
    fingerprint=""
    status=0
    if declare -F cntools_wallet_asset_fingerprint_into >/dev/null 2>&1; then
      cntools_wallet_asset_fingerprint_into \
        fingerprint "${policy_id}" "${asset_name}" || status=$?
    elif declare -F cntools_wallet_asset_fingerprint >/dev/null 2>&1; then
      fingerprint="$(cntools_wallet_asset_fingerprint \
        "${policy_id}" "${asset_name}" 2>/dev/null || true)"
      [[ -n "${fingerprint}" ]] || status=1
    else
      # Koios normally supplies fingerprints itself. Missing local helper
      # support must not turn an otherwise valid balance query into a failure.
      return 0
    fi
    if (( status == 0 )) &&
       [[ "${fingerprint}" =~ ^asset1[023456789acdefghjklmnpqrstuvwxyz]{38}$ ]]; then
      CNTOOLS_WALLET_ASSET_FINGERPRINTS["${asset_id}"]="${fingerprint}"
    else
      failures=$((failures + 1))
    fi
  done
  if (( failures > 0 )); then
    cntools_wallet_log WARN \
      "Could not derive ${failures} native-asset fingerprint(s)"
  fi
  return 0
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
  if declare -F cntools_http_temp_files_cleanup >/dev/null 2>&1; then
    cntools_http_temp_files_cleanup
  fi
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
            print "U"
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
        cntools_wallet_uint_add_into \
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
  IFS=$'\037' read -r \
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
  local asset_output=""
  local asset_policy=""
  local asset_name=""
  local asset_quantity=""
  local asset_fingerprint=""
  local asset_decimals=""
  local asset_id=""
  local asset_parse_failed=0
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
      "${CNTOOLS_KOIOS_API%/}/address_info${CNTOOLS_WALLET_KOIOS_ADDRESS_SELECT}" \
      "${payload}" "${response_file}"; then
    cntools_wallet_log ERROR "Koios address_info request failed"
    return 1
  fi
  jq -e --arg base "${base_address}" --arg payment "${payment_address}" '
    def uint:
      type == "string" and length <= 80 and test("^[0-9]+$");
    def policy_id:
      type == "string" and test("^[0-9a-fA-F]{56}$");
    def asset_name:
      type == "null" or
      (type == "string" and test("^([0-9a-fA-F]{2}){0,32}$"));
    def fingerprint:
      type == "null" or
      (type == "string" and
        test("^asset1[023456789acdefghjklmnpqrstuvwxyz]{38}$"));
    def decimals:
      type == "null" or
      (type == "number" and . >= 0 and . <= 255 and floor == .);
    type == "array" and
    all(.[];
      (.address | type == "string") and
      (.balance | uint) and
      (.utxo_set | type == "array") and
      all(.utxo_set[];
        ((.asset_list == null) or (.asset_list | type == "array")) and
        all((.asset_list // [])[];
          (.policy_id | policy_id) and
          (.asset_name | asset_name) and
          (.quantity | uint) and
          ((.fingerprint // null) | fingerprint) and
          ((.decimals // null) | decimals))) and
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
  asset_output="$(jq -r '
    .[].utxo_set[]? | (.asset_list // [])[]
    | [
        .policy_id,
        (.asset_name // ""),
        .quantity,
        (.fingerprint // ""),
        (if .decimals == null then "" else (.decimals | tostring) end)
      ] | join("\u001f")
  ' "${response_file}" 2>/dev/null)" || return 1
  while IFS=$'\037' read -r \
      asset_policy asset_name asset_quantity \
      asset_fingerprint asset_decimals; do
    [[ -n "${asset_policy}" || -n "${asset_name}" ||
       -n "${asset_quantity}" || -n "${asset_fingerprint}" ||
       -n "${asset_decimals}" ]] || continue
    asset_id="${asset_policy}.${asset_name}"
    if ! cntools_wallet_asset_add \
        "${asset_id}" "${asset_quantity}" \
        "${asset_fingerprint}" "${asset_decimals}"; then
      asset_parse_failed=1
      break
    fi
  done <<< "${asset_output}"
  if (( asset_parse_failed != 0 )); then
    cntools_wallet_log ERROR "Koios address_info returned an invalid asset row"
    return 1
  fi
  cntools_wallet_asset_sort_ids || return 1
  CNTOOLS_WALLET_ASSET_COUNT="${#CNTOOLS_WALLET_ASSET_IDS[@]}"
}

cntools_wallet_query_koios_asset_payload() {
  local _cntools_output_name="${1:-}"
  local _cntools_payload=""
  local _cntools_asset_id=""

  shift || return 2
  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && $# -gt 0 ]] ||
    return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  for _cntools_asset_id in "$@"; do
    [[ "${_cntools_asset_id}" =~ ^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$ ]] ||
      return 2
  done
  _cntools_payload="$(
    for _cntools_asset_id in "$@"; do
      printf '%s\t%s\n' \
        "${_cntools_asset_id%%.*}" "${_cntools_asset_id#*.}"
    done | jq -Rsc '
      split("\n")
      | map(select(length > 0) | split("\t"))
      | {_asset_list: .}
    '
  )" || return 1
  _cntools_output_ref="${_cntools_payload}"
}

cntools_wallet_query_koios_asset_payload_limit() {
  if [[ -n "${CNTOOLS_KOIOS_TOKEN:-}" ]]; then
    printf '%s\n' "${CNTOOLS_WALLET_KOIOS_AUTH_PAYLOAD_MAX_BYTES}"
  else
    printf '%s\n' "${CNTOOLS_WALLET_KOIOS_PAYLOAD_MAX_BYTES}"
  fi
}

cntools_wallet_query_koios_asset_pace() {
  local completed_batches="${1:-0}"

  [[ "${completed_batches}" =~ ^[0-9]+$ ]] || return 2
  (( completed_batches > 0 &&
     completed_batches % CNTOOLS_WALLET_KOIOS_RATE_BATCHES == 0 )) || return 0
  cntools_wallet_log API \
    "Koios asset_info rate window reached; pausing metadata batches"
  sleep "${CNTOOLS_WALLET_KOIOS_RATE_PAUSE_SECONDS}"
}

cntools_wallet_query_koios_asset_metadata_batch() {
  local response_file=""
  local payload=""
  local requested=""
  local records=""
  local policy_id=""
  local asset_name=""
  local asset_id=""
  local ascii_name=""
  local fingerprint=""
  local total_supply=""
  local registry_name=""
  local ticker=""
  local decimals=""
  local description=""
  local url=""

  (( $# > 0 )) || return 2
  cntools_wallet_query_temp_file response_file || return 1
  cntools_wallet_query_koios_asset_payload payload "$@" || return 1
  requested="$(jq -c '
    [._asset_list[] | ((.[0] + "." + .[1]) | ascii_downcase)]
  ' <<< "${payload}")" || return 1
  if ! cntools_wallet_query_http \
      "${CNTOOLS_KOIOS_API%/}/asset_info${CNTOOLS_WALLET_KOIOS_ASSET_SELECT}" \
      "${payload}" "${response_file}"; then
    cntools_wallet_log ERROR "Koios asset_info request failed"
    return 1
  fi
  jq -e --argjson requested "${requested}" '
    def uint:
      type == "string" and length <= 80 and test("^[0-9]+$");
    def optional_text:
      type == "null" or type == "string";
    def identity:
      ((.policy_id | ascii_downcase) + "." +
        ((.asset_name // "") | ascii_downcase));
    type == "array" and
    length == ($requested | length) and
    all(.[];
      (.policy_id | type == "string" and
        test("^[0-9a-fA-F]{56}$")) and
      ((.asset_name == null) or
        (.asset_name | type == "string" and
          test("^([0-9a-fA-F]{2}){0,32}$"))) and
      (identity as $id | ($requested | index($id)) != null) and
      (.asset_name_ascii | optional_text) and
      (.fingerprint | type == "string" and
        test("^asset1[023456789acdefghjklmnpqrstuvwxyz]{38}$")) and
      (.total_supply | uint) and
      (.metadata_name | optional_text) and
      (.metadata_ticker | optional_text) and
      (.metadata_description | optional_text) and
      (.metadata_url | optional_text) and
      ((.metadata_decimals == null) or
        (.metadata_decimals | type == "string" and
          test("^[0-9]{1,3}$") and
          (tonumber >= 0 and tonumber <= 255)))) and
    ([.[] | identity] | unique | length) == length
  ' "${response_file}" >/dev/null 2>&1 || {
    cntools_wallet_log ERROR "Koios asset_info returned invalid JSON"
    return 1
  }
  records="$(jq -r '
    def clean($maximum):
      if . == null then ""
      else tostring
        | gsub("[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]"; " ")
        | if length > $maximum
          then .[0:($maximum - 1)] + "…"
          else .
          end
      end;
    .[] | [
      .policy_id,
      (.asset_name // ""),
      (.asset_name_ascii | clean(80)),
      .fingerprint,
      .total_supply,
      (.metadata_name | clean(80)),
      (.metadata_ticker | clean(32)),
      (.metadata_decimals // ""),
      (.metadata_description | clean(160)),
      (.metadata_url | clean(160))
    ] | join("\u001f")
  ' "${response_file}" 2>/dev/null)" || return 1
  while IFS=$'\037' read -r \
      policy_id asset_name ascii_name fingerprint total_supply \
      registry_name ticker decimals description url; do
    [[ -n "${policy_id}" ]] || continue
    asset_id="${policy_id,,}.${asset_name,,}"
    [[ -n "${CNTOOLS_WALLET_ASSET_QUANTITIES[${asset_id}]+x}" ]] ||
      return 1
    CNTOOLS_WALLET_ASSET_ASCII_NAMES["${asset_id}"]="${ascii_name}"
    CNTOOLS_WALLET_ASSET_FINGERPRINTS["${asset_id}"]="${fingerprint}"
    CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES["${asset_id}"]="${total_supply}"
    CNTOOLS_WALLET_ASSET_REGISTRY_NAMES["${asset_id}"]="${registry_name}"
    CNTOOLS_WALLET_ASSET_TICKERS["${asset_id}"]="${ticker}"
    CNTOOLS_WALLET_ASSET_DESCRIPTIONS["${asset_id}"]="${description}"
    CNTOOLS_WALLET_ASSET_URLS["${asset_id}"]="${url}"
    CNTOOLS_WALLET_ASSET_METADATA_AVAILABLE["${asset_id}"]=1
    if [[ "${decimals}" =~ ^[0-9]+$ ]]; then
      if (( 10#${decimals} <= 255 )); then
        CNTOOLS_WALLET_ASSET_METADATA_DECIMALS["${asset_id}"]="$((10#${decimals}))"
      fi
    fi
  done <<< "${records}"
}

cntools_wallet_query_koios_asset_metadata() {
  local asset_id=""
  local payload=""
  local total_batches=0
  local successful_batches=0
  local payload_limit=0
  local -a batch=()
  local -a candidate=()

  if (( ${#CNTOOLS_WALLET_ASSET_IDS[@]} == 0 )); then
    CNTOOLS_WALLET_ASSET_METADATA_STATUS="empty"
    return 0
  fi
  CNTOOLS_WALLET_ASSET_METADATA_STATUS="unavailable"
  CNTOOLS_WALLET_ASSET_ASCII_NAMES=()
  CNTOOLS_WALLET_ASSET_REGISTRY_NAMES=()
  CNTOOLS_WALLET_ASSET_TICKERS=()
  CNTOOLS_WALLET_ASSET_DESCRIPTIONS=()
  CNTOOLS_WALLET_ASSET_URLS=()
  CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES=()
  CNTOOLS_WALLET_ASSET_METADATA_AVAILABLE=()
  CNTOOLS_WALLET_ASSET_METADATA_DECIMALS=()
  payload_limit="$(cntools_wallet_query_koios_asset_payload_limit)" || return 1
  [[ "${payload_limit}" =~ ^[1-9][0-9]*$ ]] || return 1
  for asset_id in "${CNTOOLS_WALLET_ASSET_IDS[@]}"; do
    candidate=("${batch[@]}" "${asset_id}")
    cntools_wallet_query_koios_asset_payload payload \
      "${candidate[@]}" || return 1
    if (( ${#payload} > payload_limit &&
          ${#batch[@]} > 0 )); then
      cntools_wallet_query_koios_asset_pace "${total_batches}" || return 1
      total_batches=$((total_batches + 1))
      if cntools_wallet_query_koios_asset_metadata_batch "${batch[@]}"; then
        successful_batches=$((successful_batches + 1))
      fi
      batch=("${asset_id}")
    else
      batch=("${candidate[@]}")
    fi
  done
  if (( ${#batch[@]} > 0 )); then
    cntools_wallet_query_koios_asset_pace "${total_batches}" || return 1
    total_batches=$((total_batches + 1))
    if cntools_wallet_query_koios_asset_metadata_batch "${batch[@]}"; then
      successful_batches=$((successful_batches + 1))
    fi
  fi
  if (( successful_batches == total_batches )); then
    CNTOOLS_WALLET_ASSET_METADATA_STATUS="available"
    return 0
  elif (( successful_batches > 0 )); then
    CNTOOLS_WALLET_ASSET_METADATA_STATUS="partial"
  else
    CNTOOLS_WALLET_ASSET_METADATA_STATUS="unavailable"
  fi
  return 1
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
      "${CNTOOLS_KOIOS_API%/}/account_info${CNTOOLS_WALLET_KOIOS_ACCOUNT_SELECT}" \
      "${payload}" "${response_file}"; then
    cntools_wallet_log ERROR "Koios account_info request failed"
    return 1
  fi
  jq -e --arg reward "${reward_address}" '
    def pool_id:
      type == "string" and
      test("^pool1[023456789acdefghjklmnpqrstuvwxyz]{51}$");
    def drep_id:
      type == "string" and
      ((. == "drep_always_abstain") or
       (. == "drep_always_no_confidence") or
       (. == "alwaysAbstain") or
       (. == "alwaysNoConfidence") or
       test("^drep1[023456789acdefghjklmnpqrstuvwxyz]{51}([023456789acdefghjklmnpqrstuvwxyz]{2})?$"));
    type == "array" and length <= 1 and
    all(.[];
      (.stake_address == $reward) and
      (.stake_address | type == "string") and
      (.status == "registered" or .status == "not registered") and
      (.rewards_available | type == "string" and length <= 80 and
        test("^[0-9]+$")) and
      ((.delegated_pool == null) or (.delegated_pool | pool_id)) and
      ((.delegated_drep == null) or (.delegated_drep | drep_id))
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
      if ! cntools_wallet_query_koios_asset_metadata; then
        cntools_wallet_log WALLET \
          "Koios token metadata is incomplete; preserving on-chain holdings"
      fi
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
  local total="0"

  [[ "${expected}" =~ ^[0-9]+$ ]] || expected=0
  [[ "${succeeded}" =~ ^[0-9]+$ ]] || succeeded=0
  if (( expected > 0 && succeeded == expected )); then
    if [[ "${CNTOOLS_WALLET_BASE_LOVELACE}" =~ ^[0-9]+$ ]]; then
      cntools_wallet_uint_add_into \
        total "${total}" "${CNTOOLS_WALLET_BASE_LOVELACE}" || return 1
      balance_count=$((balance_count + 1))
    fi
    if [[ "${CNTOOLS_WALLET_PAYMENT_LOVELACE}" =~ ^[0-9]+$ ]]; then
      cntools_wallet_uint_add_into \
        total "${total}" "${CNTOOLS_WALLET_PAYMENT_LOVELACE}" || return 1
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

cntools_wallet_query_details() {
  cntools_wallet_query "$@" || return $?
  cntools_wallet_asset_fill_fingerprints
}

cntools_wallet_list_query_reset() {
  local index=0

  CNTOOLS_WALLET_LIST_BASE_ADDRESSES=()
  CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES=()
  CNTOOLS_WALLET_LIST_REWARD_ADDRESSES=()
  CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE=()
  CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE=()
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
    CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE[index]=""
    CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[index]=""
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
      "${CNTOOLS_KOIOS_API%/}/address_info${CNTOOLS_WALLET_KOIOS_ADDRESS_SELECT}" \
      "${payload}" "${response_file}"; then
    cntools_wallet_log ERROR "Koios address_info batch request failed"
    return 1
  fi
  jq -e --argjson requested "${requested}" '
    def uint:
      type == "string" and length <= 80 and test("^[0-9]+$");
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
      "${CNTOOLS_KOIOS_API%/}/account_info${CNTOOLS_WALLET_KOIOS_ACCOUNT_SELECT}" \
      "${payload}" "${response_file}"; then
    cntools_wallet_log ERROR "Koios account_info batch request failed"
    return 1
  fi
  jq -e --argjson requested "${requested}" '
    def uint:
      type == "string" and length <= 80 and test("^[0-9]+$");
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
  local base_address=""
  local payment_address=""
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
    base_address="${CNTOOLS_WALLET_LIST_BASE_ADDRESSES[index]}"
    payment_address="${CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES[index]}"
    for address in "${base_address}" "${payment_address}"; do
      [[ -n "${address}" && -z "${wallet_addresses[${address}]+x}" ]] ||
        continue
      wallet_addresses["${address}"]=1
      expected=$((expected + 1))
      if [[ -n "${CNTOOLS_WALLET_LIST_ADDRESS_BALANCES[${address}]+x}" ]]; then
        matched=$((matched + 1))
        cntools_wallet_uint_add_into utxo_lovelace \
          "${utxo_lovelace}" \
          "${CNTOOLS_WALLET_LIST_ADDRESS_BALANCES[${address}]}" || return 1
        asset_list="${CNTOOLS_WALLET_LIST_ADDRESS_ASSETS[${address}]:-}"
        address_assets=()
        IFS=$'\037' read -r -a address_assets <<< "${asset_list}"
        for asset_id in "${address_assets[@]}"; do
          [[ -n "${asset_id}" ]] || continue
          wallet_assets["${asset_id}"]=1
        done
      fi
    done
    if [[ -n "${base_address}" &&
          -n "${CNTOOLS_WALLET_LIST_ADDRESS_BALANCES[${base_address}]+x}" ]]; then
      CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE[index]="${CNTOOLS_WALLET_LIST_ADDRESS_BALANCES[${base_address}]}"
    fi
    if [[ -n "${payment_address}" &&
          -n "${CNTOOLS_WALLET_LIST_ADDRESS_BALANCES[${payment_address}]+x}" ]]; then
      CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[index]="${CNTOOLS_WALLET_LIST_ADDRESS_BALANCES[${payment_address}]}"
    fi
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
    [[ ! "${CNTOOLS_WALLET_BASE_LOVELACE}" =~ ^[0-9]+$ ]] ||
      CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE[index]="${CNTOOLS_WALLET_BASE_LOVELACE}"
    [[ ! "${CNTOOLS_WALLET_PAYMENT_LOVELACE}" =~ ^[0-9]+$ ]] ||
      CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[index]="${CNTOOLS_WALLET_PAYMENT_LOVELACE}"
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
  local base_address=""
  local payment_address=""
  local reward_address=""
  local base_utxo=""
  local payment_utxo=""
  local rewards=""
  local total="0"
  local funding_total="0"
  local expected=0
  local matched=0
  local funding_expected=0
  local funding_matched=0

  for (( index = 0; index < ${#CNTOOLS_WALLET_NAMES[@]}; index++ )); do
    base_address="${CNTOOLS_WALLET_LIST_BASE_ADDRESSES[index]}"
    payment_address="${CNTOOLS_WALLET_LIST_PAYMENT_ADDRESSES[index]}"
    reward_address="${CNTOOLS_WALLET_LIST_REWARD_ADDRESSES[index]}"
    base_utxo="${CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE[index]}"
    payment_utxo="${CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[index]}"
    rewards="${CNTOOLS_WALLET_LIST_REWARD_LOVELACE[index]}"
    total=0
    funding_total=0
    expected=0
    matched=0
    funding_expected=0
    funding_matched=0

    if [[ -n "${base_address}" ]]; then
      expected=$((expected + 1))
      funding_expected=$((funding_expected + 1))
      if [[ "${base_utxo}" =~ ^[0-9]+$ ]]; then
        cntools_wallet_uint_add_into total "${total}" "${base_utxo}" || return 1
        cntools_wallet_uint_add_into \
          funding_total "${funding_total}" "${base_utxo}" || return 1
        matched=$((matched + 1))
        funding_matched=$((funding_matched + 1))
      fi
    fi
    if [[ -n "${payment_address}" ]]; then
      expected=$((expected + 1))
      funding_expected=$((funding_expected + 1))
      if [[ "${payment_utxo}" =~ ^[0-9]+$ ]]; then
        cntools_wallet_uint_add_into \
          total "${total}" "${payment_utxo}" || return 1
        cntools_wallet_uint_add_into \
          funding_total "${funding_total}" "${payment_utxo}" || return 1
        matched=$((matched + 1))
        funding_matched=$((funding_matched + 1))
      fi
    fi
    if [[ -n "${reward_address}" ]]; then
      expected=$((expected + 1))
      if [[ "${rewards}" =~ ^[0-9]+$ ]]; then
        cntools_wallet_uint_add_into total "${total}" "${rewards}" || return 1
        matched=$((matched + 1))
      fi
    fi
    if (( funding_expected > 0 && funding_matched == funding_expected )); then
      CNTOOLS_WALLET_LIST_UTXO_LOVELACE[index]="${funding_total}"
    else
      CNTOOLS_WALLET_LIST_UTXO_LOVELACE[index]=""
    fi

    if (( expected > 0 && matched == expected )); then
      CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[index]="${total}"
      CNTOOLS_WALLET_LIST_QUERY_STATUSES[index]="available"
      available=$((available + 1))
    elif (( matched > 0 )); then
      CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[index]=""
      CNTOOLS_WALLET_LIST_QUERY_STATUSES[index]="partial"
      partial=$((partial + 1))
    else
      CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[index]=""
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
  local whole=""
  local fraction=""
  local formatted=""
  local scaled_whole=""
  local scaled_fraction=""
  local divisor_digits=0
  local split_at=0
  local suffix=""

  [[ "${amount}" =~ ^[0-9]+$ ]] || {
    printf '—\n'
    return 0
  }
  [[ "${amount}" =~ ^0*([1-9][0-9]*|0)$ ]] || return 1
  amount="${BASH_REMATCH[1]}"
  while (( ${#amount} <= 6 )); do
    amount="0${amount}"
  done
  split_at=$((${#amount} - 6))
  whole="${amount:0:split_at}"
  fraction="${amount:split_at}"
  if (( ${#whole} < 9 )); then
    formatted="${whole}.${fraction}"
    if declare -F cntools_number_format_into >/dev/null 2>&1; then
      cntools_number_format_into formatted "${formatted}" || return 1
    fi
    printf '%s\n' "${formatted}"
    return 0
  fi
  if (( ${#whole} >= 10 )); then
    divisor_digits=9
    suffix="B"
  else
    divisor_digits=6
    suffix="M"
  fi
  split_at=$((${#whole} - divisor_digits))
  scaled_whole="${whole:0:split_at}"
  scaled_fraction="${whole:split_at:3}"
  formatted="${scaled_whole}.${scaled_fraction}"
  if declare -F cntools_number_format_into >/dev/null 2>&1; then
    cntools_number_format_into formatted "${formatted}" || return 1
  fi
  printf '%s%s\n' "${formatted}" "${suffix}"
}

cntools_wallet_format_lovelace() {
  local amount="${1:-}"
  local whole=""
  local fraction=""
  local formatted=""
  local split_at=0

  [[ "${amount}" =~ ^[0-9]+$ ]] || {
    printf 'Unavailable\n'
    return 0
  }
  [[ "${amount}" =~ ^0*([1-9][0-9]*|0)$ ]] || return 1
  amount="${BASH_REMATCH[1]}"
  while (( ${#amount} <= 6 )); do
    amount="0${amount}"
  done
  split_at=$((${#amount} - 6))
  whole="${amount:0:split_at}"
  fraction="${amount:split_at}"
  formatted="${whole}.${fraction}"
  if declare -F cntools_number_format_into >/dev/null 2>&1; then
    cntools_number_format_into formatted "${formatted}" || return 1
  fi
  printf '%s ADA\n' "${formatted}"
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

cntools_wallet_sanitize_display_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_value="${2:-}"
  local _cntools_character=""
  local _cntools_sanitized=""
  local _cntools_index=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_value="${_cntools_value//$'\r'/ }"
  _cntools_value="${_cntools_value//$'\n'/ }"
  _cntools_value="${_cntools_value//$'\t'/ }"
  _cntools_value="${_cntools_value//$'\033'/}"
  case "${_cntools_value}" in
    *[[:cntrl:]]*|*$'\u061c'*|*$'\u200e'*|*$'\u200f'*|\
    *$'\u202a'*|*$'\u202b'*|*$'\u202c'*|*$'\u202d'*|*$'\u202e'*|\
    *$'\u2066'*|*$'\u2067'*|*$'\u2068'*|*$'\u2069'*) ;;
    *)
      _cntools_output_ref="${_cntools_value}"
      return 0
      ;;
  esac
  for (( _cntools_index = 0;
         _cntools_index < ${#_cntools_value};
         _cntools_index++ )); do
    _cntools_character="${_cntools_value:_cntools_index:1}"
    if [[ "${_cntools_character}" == [[:cntrl:]] ]]; then
      _cntools_sanitized+=" "
      continue
    fi
    case "${_cntools_character}" in
      $'\u061c'|$'\u200e'|$'\u200f'|\
      $'\u202a'|$'\u202b'|$'\u202c'|$'\u202d'|$'\u202e'|\
      $'\u2066'|$'\u2067'|$'\u2068'|$'\u2069')
        _cntools_sanitized+=" "
        ;;
      *) _cntools_sanitized+="${_cntools_character}" ;;
    esac
  done
  _cntools_output_ref="${_cntools_sanitized}"
}

cntools_wallet_sanitize_display() {
  local sanitized=""

  cntools_wallet_sanitize_display_into sanitized "${1:-}" || return $?
  printf '%s' "${sanitized}"
}

cntools_wallet_table_row() {
  local cell=""
  local separator=""

  (( $# > 0 )) || return 2
  for cell in "$@"; do
    cntools_wallet_sanitize_display_into cell "${cell}" || return 1
    if [[ "${cell}" == *'"'* ]]; then
      cell="${cell//\"/\"\"}"
      cell="\"${cell}\""
    fi
    printf '%s%s' "${separator}" "${cell}"
    separator=$'\t'
  done
  printf '\n'
}

cntools_wallet_table_row_prepared() {
  local cell=""
  local separator=""

  (( $# > 0 )) || return 2
  for cell in "$@"; do
    if [[ "${cell}" == *'"'* ]]; then
      cell="${cell//\"/\"\"}"
      cell="\"${cell}\""
    fi
    printf '%s%s' "${separator}" "${cell}"
    separator=$'\t'
  done
  printf '\n'
}

cntools_wallet_render_table() {
  local title="${1:-Details}"

  cntools_ui_render_detail "${title}" || return 1
  cntools_ui_table --separator $'\t' || return 1
  printf '\n'
}

cntools_wallet_render_table_file() {
  local title="${1:-Details}"
  local source_file="${2:-}"

  [[ -f "${source_file}" && ! -L "${source_file}" ]] || return 2
  cntools_ui_render_detail "${title}" || return 1
  cntools_ui_table --separator $'\t' < "${source_file}" || return 1
  printf '\n'
}

cntools_wallet_write_rows_file() {
  local _cntools_output_name="${1:-}"
  local _cntools_producer="${2:-}"
  local _cntools_rows_file=""
  local _cntools_status=0
  local CNTOOLS_WALLET_RENDER_WIDTH=""

  shift 2 || return 2
  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_producer}" =~ ^cntools_wallet_[A-Za-z0-9_]+_rows$ ]] ||
    return 2
  declare -F "${_cntools_producer}" >/dev/null 2>&1 || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_query_temp_file _cntools_rows_file || return 1
  CNTOOLS_WALLET_RENDER_WIDTH="$(cntools_wallet_table_width)" || return 1
  if "${_cntools_producer}" "$@" > "${_cntools_rows_file}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  (( _cntools_status == 0 )) || return "${_cntools_status}"
  _cntools_output_ref="${_cntools_rows_file}"
}

cntools_wallet_render_rows_table() {
  local title="${1:-Details}"
  local producer="${2:-}"
  local rows_file=""

  shift 2 || return 2
  cntools_wallet_write_rows_file rows_file "${producer}" "$@" || return $?
  cntools_wallet_render_table_file "${title}" "${rows_file}"
}

cntools_wallet_table_width() {
  local width=""
  local terminal_columns=""

  if [[ "${CNTOOLS_WALLET_RENDER_WIDTH:-}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${CNTOOLS_WALLET_RENDER_WIDTH}"
    return 0
  fi

  if declare -F cntools_ui_content_width >/dev/null 2>&1; then
    cntools_ui_content_width 180 42
    return $?
  fi

  # The general menu frame intentionally stays compact, but Wallet List and
  # Show often contain full Cardano addresses and credential hashes. Read the
  # live terminal width for these tables so a wider terminal is actually used
  # after a resize. Keep two columns clear to avoid right-edge autowrapping and
  # cap exceptionally wide tables at a readable size.
  if [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == "Y" || -t 1 ]]; then
    terminal_columns="$(tput cols 2>/dev/null || true)"
    if [[ "${terminal_columns}" =~ ^[0-9]+$ &&
          ${terminal_columns} -gt 2 ]]; then
      width="$((terminal_columns - 2))"
    fi
  fi
  if [[ -z "${width}" ]] &&
     declare -F cntools_gum_width >/dev/null 2>&1; then
    width="$(COLUMNS='' cntools_gum_width 2>/dev/null || true)"
  fi
  [[ -n "${width}" ]] || width="${CNTOOLS_UI_COLUMNS:-${COLUMNS:-98}}"
  [[ "${width}" =~ ^[0-9]+$ ]] || width=98
  (( width >= 42 )) || width=42
  (( width <= 180 )) || width=180
  printf '%s\n' "${width}"
}

cntools_wallet_style_value_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_role="${2:-value}"
  local _cntools_value="${3:-}"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref="${_cntools_value}"
  [[ -n "${_cntools_value}" ]] || return 0
  if declare -F cntools_theme_style_value_into >/dev/null 2>&1; then
    cntools_theme_style_value_into \
      "${_cntools_output_name}" "${_cntools_role}" "${_cntools_value}"
  fi
}

cntools_wallet_format_number_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_value="${2:-}"
  local _cntools_formatted=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref="${_cntools_value}"
  [[ "${_cntools_value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  if declare -F cntools_number_format_into >/dev/null 2>&1; then
    cntools_number_format_into \
      _cntools_formatted "${_cntools_value}" || return 1
    _cntools_output_ref="${_cntools_formatted}"
  fi
}

cntools_wallet_status_role() {
  local value="${1:-}"

  case "${value,,}" in
    *invalid*|*failed*|*error*) printf 'danger\n' ;;
    registered|delegated|protected|encrypted|yes|ready|available)
      printf 'success\n'
      ;;
    open|unprotected|*not\ registered*|*not\ delegated*|*missing*)
      printf 'warning\n'
      ;;
    unavailable|unknown|none|no|offline|—) printf 'muted\n' ;;
    *) printf 'value\n' ;;
  esac
}

cntools_wallet_number_role() {
  if [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf 'number\n'
  else
    printf 'muted\n'
  fi
}

cntools_wallet_text_width() {
  local value="${1:-}"
  local character=""
  local index=0
  local width=0

  for (( index = 0; index < ${#value}; index++ )); do
    character="${value:index:1}"
    if [[ "${character}" == [[:ascii:]] ]]; then
      width=$((width + 1))
    else
      width=$((width + 2))
    fi
  done
  printf '%s\n' "${width}"
}

cntools_wallet_display_chunk() {
  local _cntools_value="${1:-}"
  local _cntools_maximum="${2:-}"
  local _cntools_chunk_name="${3:-}"
  local _cntools_rest_name="${4:-}"
  local _cntools_character=""
  local _cntools_character_width=0
  local _cntools_display_width=0
  local _cntools_index=0
  local _cntools_chunk=""

  [[ "${_cntools_maximum}" =~ ^[1-9][0-9]*$ &&
     "${_cntools_chunk_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_rest_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_chunk_ref="${_cntools_chunk_name}"
  local -n _cntools_rest_ref="${_cntools_rest_name}"
  for (( _cntools_index = 0;
         _cntools_index < ${#_cntools_value};
         _cntools_index++ )); do
    _cntools_character="${_cntools_value:_cntools_index:1}"
    _cntools_character_width=2
    [[ "${_cntools_character}" != [[:ascii:]] ]] ||
      _cntools_character_width=1
    if (( _cntools_display_width + _cntools_character_width >
          _cntools_maximum )); then
      break
    fi
    _cntools_chunk+="${_cntools_character}"
    _cntools_display_width=$((
      _cntools_display_width + _cntools_character_width
    ))
  done
  _cntools_chunk_ref="${_cntools_chunk}"
  _cntools_rest_ref="${_cntools_value:_cntools_index}"
}

cntools_wallet_table_wrapped_pair() {
  local label="${1:-}"
  local value="${2:-—}"
  local label_width="${3:-20}"
  local value_role="${4:-value}"
  local table_width=""
  local value_width=0
  local label_chunk=""
  local value_chunk=""
  local styled_value_chunk=""

  [[ "${label_width}" =~ ^[1-9][0-9]*$ ]] || return 2
  table_width="$(cntools_wallet_table_width)" || return 1
  value_width=$((table_width - label_width - 7))
  while (( value_width < 8 && label_width > 10 )); do
    label_width=$((label_width - 1))
    value_width=$((value_width + 1))
  done
  (( value_width >= 8 )) || return 1
  cntools_wallet_sanitize_display_into label "${label}" || return 1
  cntools_wallet_sanitize_display_into value "${value}" || return 1
  [[ -n "${value}" ]] || value="—"
  while [[ -n "${label}" || -n "${value}" ]]; do
    cntools_wallet_display_chunk \
      "${label}" "${label_width}" label_chunk label || return 1
    cntools_wallet_display_chunk \
      "${value}" "${value_width}" value_chunk value || return 1
    cntools_wallet_style_value_into \
      styled_value_chunk "${value_role}" "${value_chunk}" || return 1
    cntools_wallet_table_row_prepared \
      "${label_chunk}" "${styled_value_chunk}" || return 1
  done
}

cntools_wallet_table_wrapped_triple() {
  local first="${1:-}"
  local second="${2:-}"
  local third="${3:-—}"
  local first_width="${4:-22}"
  local second_width="${5:-20}"
  local table_width="${6:-}"
  local first_role="${7:-value}"
  local third_role="${8:-value}"
  local third_width=0
  local first_chunk=""
  local second_chunk=""
  local third_chunk=""
  local styled_first_chunk=""
  local styled_third_chunk=""

  [[ "${first_width}" =~ ^[1-9][0-9]*$ &&
     "${second_width}" =~ ^[1-9][0-9]*$ ]] || return 2
  if [[ -z "${table_width}" ]]; then
    table_width="$(cntools_wallet_table_width)" || return 1
  fi
  [[ "${table_width}" =~ ^[1-9][0-9]*$ ]] || return 2
  third_width=$((table_width - first_width - second_width - 10))
  while (( third_width < 8 && first_width > 10 )); do
    first_width=$((first_width - 1))
    third_width=$((third_width + 1))
  done
  while (( third_width < 8 && second_width > 10 )); do
    second_width=$((second_width - 1))
    third_width=$((third_width + 1))
  done
  (( third_width >= 8 )) || return 1
  cntools_wallet_sanitize_display_into first "${first}" || return 1
  cntools_wallet_sanitize_display_into second "${second}" || return 1
  cntools_wallet_sanitize_display_into third "${third}" || return 1
  [[ -n "${third}" ]] || third="—"
  while [[ -n "${first}" || -n "${second}" || -n "${third}" ]]; do
    cntools_wallet_display_chunk \
      "${first}" "${first_width}" first_chunk first || return 1
    cntools_wallet_display_chunk \
      "${second}" "${second_width}" second_chunk second || return 1
    cntools_wallet_display_chunk \
      "${third}" "${third_width}" third_chunk third || return 1
    cntools_wallet_style_value_into \
      styled_first_chunk "${first_role}" "${first_chunk}" || return 1
    cntools_wallet_style_value_into \
      styled_third_chunk "${third_role}" "${third_chunk}" || return 1
    cntools_wallet_table_row_prepared \
      "${styled_first_chunk}" "${second_chunk}" \
      "${styled_third_chunk}" || return 1
  done
}

cntools_wallet_identity_rows() {
  local wallet_name="${1:-Unavailable}"
  local wallet_type="${2:-Unavailable}"
  local key_protection="${3:-Unavailable}"
  local stake_registration="${4:-}"
  local derivation_path="${5:-}"
  local protection_role=""
  local registration_role=""

  protection_role="$(cntools_wallet_status_role "${key_protection}")" || return 1

  cntools_wallet_table_row "Wallet detail" "Value" || return 1
  cntools_wallet_table_wrapped_pair \
    "Name" "${wallet_name}" 16 identifier || return 1
  cntools_wallet_table_wrapped_pair \
    "Type" "${wallet_type}" 16 accent || return 1
  cntools_wallet_table_wrapped_pair \
    "Key protection" "${key_protection}" 16 "${protection_role}" || return 1
  if [[ -n "${stake_registration}" ]]; then
    registration_role="$(cntools_wallet_status_role \
      "${stake_registration}")" || return 1
    cntools_wallet_table_wrapped_pair \
      "Stake registration" "${stake_registration}" 20 \
      "${registration_role}" || return 1
  fi
  if [[ -n "${derivation_path}" ]]; then
    cntools_wallet_table_wrapped_pair \
      "Derivation path" "${derivation_path}" 20 identifier || return 1
  fi
}

cntools_wallet_render_identity_table() {
  cntools_wallet_render_rows_table \
    "Wallet" cntools_wallet_identity_rows "$@"
}

cntools_wallet_address_rows() {
  local base_address="${1:-Not available}"
  local payment_address="${2:-Not available}"
  local reward_address="${3:-Not available}"

  cntools_wallet_table_row "Address type" "Address" || return 1
  if [[ "${base_address}" != "Not available" ]]; then
    cntools_wallet_table_wrapped_pair \
      "Base" "${base_address}" 15 address || return 1
  fi
  if [[ "${payment_address}" != "Not available" ]]; then
    cntools_wallet_table_wrapped_pair \
      "Payment" "${payment_address}" 15 address || return 1
  fi
  if [[ "${reward_address}" != "Not available" ]]; then
    cntools_wallet_table_wrapped_pair \
      "Stake / reward" "${reward_address}" 15 address || return 1
  fi
  if [[ "${base_address}" == "Not available" &&
        "${payment_address}" == "Not available" &&
        "${reward_address}" == "Not available" ]]; then
    cntools_wallet_table_wrapped_pair \
      "Available" "None" 15 muted || return 1
  fi
}

cntools_wallet_render_address_table() {
  cntools_wallet_render_rows_table \
    "Addresses" cntools_wallet_address_rows "$@"
}

cntools_wallet_credential_rows() {
  local wallet_directory="${1:-}"
  local kind=""
  local label=""
  local value=""
  local status=0
  local count=0
  local -a labels=()
  local -a values=()

  declare -F cntools_wallet_id_read_credential >/dev/null 2>&1 || return 0
  for kind in \
    payment stake ms-payment ms-stake script-payment script-stake; do
    value=""
    if cntools_wallet_id_read_credential \
        "${wallet_directory}" "${kind}" value; then
      status=0
    else
      status=$?
    fi
    case "${kind}" in
      payment) label="Payment" ;;
      stake) label="Stake" ;;
      ms-payment) label="MultiSig payment" ;;
      ms-stake) label="MultiSig stake" ;;
      script-payment) label="Payment script" ;;
      script-stake) label="Stake script" ;;
    esac
    case "${status}" in
      0)
        [[ "${value}" =~ ^[0-9a-fA-F]{56}$ ]] || return 1
        labels+=("${label}")
        values+=("${value,,}")
        ;;
      1) ;;
      2)
        labels+=("${label}")
        values+=("Invalid credential file")
        ;;
      *) return "${status}" ;;
    esac
  done
  (( ${#labels[@]} > 0 )) || return 0
  cntools_wallet_table_row "Credential" "Hash (hex)" || return 1
  for (( count = 0; count < ${#labels[@]}; count++ )); do
    local credential_role="credential"
    [[ "${values[count]}" != "Invalid credential file" ]] ||
      credential_role="danger"
    cntools_wallet_table_wrapped_pair \
      "${labels[count]}" "${values[count]}" 20 \
      "${credential_role}" || return 1
  done
}

cntools_wallet_render_credential_table() {
  local wallet_directory="${1:-}"
  local rows_file=""
  local row_count=0

  cntools_wallet_write_rows_file \
    rows_file cntools_wallet_credential_rows "${wallet_directory}" || return $?
  cntools_wallet_file_row_count_into row_count "${rows_file}" || return 1
  (( row_count > 0 )) || return 0
  cntools_wallet_render_table_file "Credentials" "${rows_file}"
}

cntools_wallet_balance_rows() {
  local has_base="${1:-Y}"
  local has_payment="${2:-Y}"
  local has_reward="${3:-Y}"
  local inclusive_total=""
  local utxo_count="Unavailable"
  local formatted_count="Unavailable"

  if [[ "${CNTOOLS_WALLET_TOTAL_LOVELACE}" =~ ^[0-9]+$ &&
        "${CNTOOLS_WALLET_REWARD_LOVELACE}" =~ ^[0-9]+$ ]]; then
    inclusive_total="$(cntools_wallet_uint_add \
      "${CNTOOLS_WALLET_TOTAL_LOVELACE}" \
      "${CNTOOLS_WALLET_REWARD_LOVELACE}")" || return 1
  fi
  [[ ! "${CNTOOLS_WALLET_UTXO_COUNT}" =~ ^[0-9]+$ ]] ||
    utxo_count="${CNTOOLS_WALLET_UTXO_COUNT}"
  if [[ "${utxo_count}" =~ ^[0-9]+$ ]] &&
     declare -F cntools_number_format_into >/dev/null 2>&1; then
    cntools_number_format_into formatted_count "${utxo_count}" || return 1
  else
    formatted_count="${utxo_count}"
  fi
  cntools_wallet_table_row "Balance" "Value" || return 1
  if [[ "${has_base}" == "Y" ]]; then
    cntools_wallet_table_wrapped_pair "Base UTxO" \
      "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_BASE_LOVELACE}")" \
      22 "$(cntools_wallet_number_role \
        "${CNTOOLS_WALLET_BASE_LOVELACE}")" ||
      return 1
  fi
  if [[ "${has_payment}" == "Y" ]]; then
    cntools_wallet_table_wrapped_pair "Payment UTxO" \
      "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_PAYMENT_LOVELACE}")" \
      22 "$(cntools_wallet_number_role \
        "${CNTOOLS_WALLET_PAYMENT_LOVELACE}")" ||
      return 1
  fi
  if [[ "${has_base}" == "Y" || "${has_payment}" == "Y" ]]; then
    cntools_wallet_table_wrapped_pair "Total UTxO" \
      "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_TOTAL_LOVELACE}")" \
      22 "$(cntools_wallet_number_role \
        "${CNTOOLS_WALLET_TOTAL_LOVELACE}")" ||
      return 1
  fi
  if [[ "${has_reward}" == "Y" ]]; then
    cntools_wallet_table_wrapped_pair "Rewards" \
      "$(cntools_wallet_format_lovelace "${CNTOOLS_WALLET_REWARD_LOVELACE}")" \
      22 "$(cntools_wallet_number_role \
        "${CNTOOLS_WALLET_REWARD_LOVELACE}")" ||
      return 1
  fi
  if [[ "${has_reward}" == "Y" &&
        ( "${has_base}" == "Y" || "${has_payment}" == "Y" ) ]]; then
    cntools_wallet_table_wrapped_pair "Total incl. rewards" \
      "$(cntools_wallet_format_lovelace "${inclusive_total}")" \
      22 "$(cntools_wallet_number_role "${inclusive_total}")" || return 1
  fi
  if [[ "${has_base}" == "Y" || "${has_payment}" == "Y" ]]; then
    cntools_wallet_table_wrapped_pair \
      "UTxO count" "${formatted_count}" 22 \
      "$(cntools_wallet_number_role "${utxo_count}")" ||
      return 1
  fi
}

cntools_wallet_render_balance_table() {
  cntools_wallet_render_rows_table \
    "Balances" cntools_wallet_balance_rows "$@"
}

cntools_wallet_drep_target() {
  case "${1:-}" in
    alwaysAbstain|drep_always_abstain) printf 'Always abstain\n' ;;
    alwaysNoConfidence|drep_always_no_confidence)
      printf 'Always no confidence\n'
      ;;
    *) printf '%s\n' "${1:-—}" ;;
  esac
}

cntools_wallet_delegation_rows() {
  local pool_status="Unavailable"
  local pool_target="—"
  local drep_status="Unavailable"
  local drep_target="—"
  local pool_role="muted"
  local drep_role="muted"

  if [[ "${CNTOOLS_WALLET_REGISTERED:-unknown}" != "unknown" ]]; then
    if [[ -n "${CNTOOLS_WALLET_POOL_DELEGATION:-}" ]]; then
      pool_status="Delegated"
      pool_target="${CNTOOLS_WALLET_POOL_DELEGATION}"
    else
      pool_status="Not delegated"
    fi
    if [[ -n "${CNTOOLS_WALLET_DREP_DELEGATION:-}" ]]; then
      drep_status="Delegated"
      drep_target="$(cntools_wallet_drep_target \
        "${CNTOOLS_WALLET_DREP_DELEGATION}")"
    else
      drep_status="Not delegated"
    fi
  fi
  cntools_wallet_table_row "Delegation" "Status / target" || return 1
  if [[ "${pool_status}" == "Delegated" ]]; then
    pool_role="success"
    cntools_wallet_table_wrapped_pair \
      "Stake pool delegation" "Delegated · ${pool_target}" 24 \
      "${pool_role}" || return 1
  else
    pool_role="$(cntools_wallet_status_role "${pool_status}")" || return 1
    cntools_wallet_table_wrapped_pair \
      "Stake pool delegation" "${pool_status}" 24 "${pool_role}" || return 1
  fi
  if [[ "${drep_status}" == "Delegated" ]]; then
    drep_role="success"
    cntools_wallet_table_wrapped_pair \
      "DRep delegation" "Delegated · ${drep_target}" 24 "${drep_role}"
  else
    drep_role="$(cntools_wallet_status_role "${drep_status}")" || return 1
    cntools_wallet_table_wrapped_pair \
      "DRep delegation" "${drep_status}" 24 "${drep_role}"
  fi
}

cntools_wallet_render_delegation_table() {
  cntools_wallet_render_rows_table \
    "Delegation" cntools_wallet_delegation_rows
}

cntools_wallet_asset_label_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_asset_id="${2:-}"
  local _cntools_ordinal="${3:-0}"
  local _cntools_asset_name="${_cntools_asset_id#*.}"
  local _cntools_label="${CNTOOLS_WALLET_ASSET_REGISTRY_NAMES[${_cntools_asset_id}]:-}"
  local _cntools_byte=""
  local _cntools_character=""
  local _cntools_decoded=""
  local _cntools_index=0
  local _cntools_byte_value=0

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"

  [[ -n "${_cntools_label}" ]] ||
    _cntools_label="${CNTOOLS_WALLET_ASSET_ASCII_NAMES[${_cntools_asset_id}]:-}"
  if [[ -z "${_cntools_label}" && -z "${_cntools_asset_name}" ]]; then
    _cntools_label="(unnamed)"
  elif [[ -z "${_cntools_label}" &&
          "${_cntools_asset_name}" =~ ^([0-9a-f]{2})+$ ]]; then
    for (( _cntools_index = 0;
           _cntools_index < ${#_cntools_asset_name};
           _cntools_index += 2 )); do
      _cntools_byte="${_cntools_asset_name:_cntools_index:2}"
      _cntools_byte_value=$((16#${_cntools_byte}))
      if (( _cntools_byte_value < 32 || _cntools_byte_value > 126 )); then
        _cntools_decoded=""
        break
      fi
      printf -v _cntools_character '%b' "\\x${_cntools_byte}"
      _cntools_decoded+="${_cntools_character}"
    done
    _cntools_label="${_cntools_decoded}"
  fi
  [[ -n "${_cntools_label}" ]] ||
    printf -v _cntools_label 'Asset %02d' "${_cntools_ordinal}"
  if (( ${#_cntools_label} > 28 )); then
    _cntools_label="${_cntools_label:0:27}…"
  fi
  _cntools_output_ref="${_cntools_label}"
}

cntools_wallet_asset_label() {
  local label=""

  cntools_wallet_asset_label_into label "${1:-}" "${2:-0}" || return $?
  printf '%s' "${label}"
}

cntools_wallet_format_token_amount_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_quantity="${2:-}"
  local _cntools_decimals="${3:-}"
  local _cntools_integer_part=""
  local _cntools_fractional_part=""
  local _cntools_split_at=0
  local _cntools_formatted=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_quantity}" =~ ^[0-9]+$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  [[ "${_cntools_quantity}" =~ ^0*([1-9][0-9]*|0)$ ]] || return 2
  _cntools_quantity="${BASH_REMATCH[1]}"
  if [[ -z "${_cntools_decimals}" ]]; then
    if declare -F cntools_number_format_into >/dev/null 2>&1; then
      cntools_number_format_into \
        _cntools_formatted "${_cntools_quantity}" || return 1
      _cntools_output_ref="${_cntools_formatted}"
    else
      _cntools_output_ref="${_cntools_quantity}"
    fi
    return 0
  fi
  [[ "${_cntools_decimals}" =~ ^[0-9]+$ ]] || return 2
  (( 10#${_cntools_decimals} <= 255 )) || return 2
  _cntools_decimals="$((10#${_cntools_decimals}))"
  if (( _cntools_decimals == 0 )); then
    if declare -F cntools_number_format_into >/dev/null 2>&1; then
      cntools_number_format_into \
        _cntools_formatted "${_cntools_quantity}" || return 1
      _cntools_output_ref="${_cntools_formatted}"
    else
      _cntools_output_ref="${_cntools_quantity}"
    fi
    return 0
  fi
  while (( ${#_cntools_quantity} <= _cntools_decimals )); do
    _cntools_quantity="0${_cntools_quantity}"
  done
  _cntools_split_at=$((${#_cntools_quantity} - _cntools_decimals))
  _cntools_integer_part="${_cntools_quantity:0:_cntools_split_at}"
  _cntools_fractional_part="${_cntools_quantity:_cntools_split_at}"
  _cntools_formatted="${_cntools_integer_part}.${_cntools_fractional_part}"
  if declare -F cntools_number_format_into >/dev/null 2>&1; then
    cntools_number_format_into \
      _cntools_formatted "${_cntools_formatted}" || return 1
  fi
  _cntools_output_ref="${_cntools_formatted}"
}

cntools_wallet_format_token_amount() {
  local amount=""

  cntools_wallet_format_token_amount_into \
    amount "${1:-}" "${2:-}" || return $?
  printf '%s\n' "${amount}"
}

cntools_wallet_asset_details_should_page() {
  local table_rows="${1:-}"
  local terminal_lines=""

  [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == "Y" &&
     "${table_rows}" =~ ^[1-9][0-9]*$ ]] || return 1
  declare -F cntools_ui_pager >/dev/null 2>&1 || return 1
  declare -F cntools_gum_terminal_lines >/dev/null 2>&1 || return 1
  terminal_lines="$(cntools_gum_terminal_lines 2>/dev/null || true)"
  [[ "${terminal_lines}" =~ ^[0-9]+$ ]] || return 1
  (( terminal_lines >= 12 )) || terminal_lines=12
  (( table_rows + 5 > terminal_lines - 4 ))
}

cntools_wallet_asset_details_rows() {
  local asset_id=""
  local label=""
  local display_label=""
  local policy_id=""
  local asset_name=""
  local quantity=""
  local display_quantity=""
  local fingerprint=""
  local display_amount=""
  local display_decimals=""
  local formatted_decimals=""
  local display_ticker=""
  local registry_name=""
  local ticker=""
  local decimals=""
  local total_supply=""
  local display_total_supply=""
  local description=""
  local url=""
  local table_width=""
  local index=0

  [[ "${CNTOOLS_WALLET_ASSET_COUNT:-}" =~ ^[1-9][0-9]*$ ]] || return 0
  table_width="$(cntools_wallet_table_width)" || return 1
  cntools_wallet_table_row "Asset" "Property" "Value" || return 1
  for asset_id in "${CNTOOLS_WALLET_ASSET_IDS[@]}"; do
    index=$((index + 1))
    cntools_wallet_asset_label_into label "${asset_id}" "${index}" || return 1
    printf -v display_label '%02d · %s' "${index}" "${label}"
    policy_id="${asset_id%%.*}"
    asset_name="${asset_id#*.}"
    quantity="${CNTOOLS_WALLET_ASSET_QUANTITIES[${asset_id}]:-Unavailable}"
    cntools_wallet_format_number_into display_quantity "${quantity}" || return 1
    fingerprint="${CNTOOLS_WALLET_ASSET_FINGERPRINTS[${asset_id}]:-Unavailable}"
    display_decimals="${CNTOOLS_WALLET_ASSET_METADATA_DECIMALS[${asset_id}]:-${CNTOOLS_WALLET_ASSET_DECIMALS[${asset_id}]:-}}"
    display_ticker="${CNTOOLS_WALLET_ASSET_TICKERS[${asset_id}]:-}"
    (( ${#display_ticker} <= 32 )) ||
      display_ticker="${display_ticker:0:31}…"
    display_amount="${display_quantity}"
    if [[ "${quantity}" =~ ^[0-9]+$ &&
          "${display_decimals}" =~ ^[0-9]+$ ]]; then
      cntools_wallet_format_token_amount_into \
        display_amount "${quantity}" "${display_decimals}" || return 1
    fi
    if [[ -n "${display_ticker}" ]]; then
      display_amount+=" ${display_ticker}"
    fi
    if [[ -n "${display_decimals}" || -n "${display_ticker}" ]]; then
      cntools_wallet_table_wrapped_triple \
        "${display_label}" "Amount" "${display_amount}" \
        22 20 "${table_width}" identifier number || return 1
      display_label=""
    fi
    cntools_wallet_table_wrapped_triple \
      "${display_label}" "Raw quantity" "${display_quantity}" \
      22 20 "${table_width}" identifier number ||
      return 1
    cntools_wallet_table_wrapped_triple \
      "" "Policy ID" "${policy_id}" 22 20 "${table_width}" \
      value identifier || return 1
    cntools_wallet_table_wrapped_triple \
      "" "Asset name (hex)" "${asset_name:-(empty)}" \
      22 20 "${table_width}" value identifier ||
      return 1
    cntools_wallet_table_wrapped_triple \
      "" "Fingerprint" "${fingerprint}" 22 20 "${table_width}" \
      value identifier || return 1
    if [[ "${CNTOOLS_MODE:-}" != "light" ]]; then
      continue
    fi
    if [[ -z "${CNTOOLS_WALLET_ASSET_METADATA_AVAILABLE[${asset_id}]+x}" ]]; then
      cntools_wallet_table_wrapped_triple \
        "" "Token metadata" "Unavailable" 22 20 "${table_width}" \
        value muted || return 1
      continue
    fi
    registry_name="${CNTOOLS_WALLET_ASSET_REGISTRY_NAMES[${asset_id}]:-Not provided}"
    ticker="${CNTOOLS_WALLET_ASSET_TICKERS[${asset_id}]:-Not provided}"
    decimals="${CNTOOLS_WALLET_ASSET_METADATA_DECIMALS[${asset_id}]:-Not provided}"
    total_supply="${CNTOOLS_WALLET_ASSET_TOTAL_SUPPLIES[${asset_id}]:-Unavailable}"
    cntools_wallet_format_number_into \
      formatted_decimals "${decimals}" || return 1
    cntools_wallet_format_number_into \
      display_total_supply "${total_supply}" || return 1
    description="${CNTOOLS_WALLET_ASSET_DESCRIPTIONS[${asset_id}]:-}"
    url="${CNTOOLS_WALLET_ASSET_URLS[${asset_id}]:-}"
    (( ${#registry_name} <= 80 )) ||
      registry_name="${registry_name:0:79}…"
    (( ${#ticker} <= 32 )) || ticker="${ticker:0:31}…"
    (( ${#description} <= 160 )) ||
      description="${description:0:159}…"
    (( ${#url} <= 160 )) || url="${url:0:159}…"
    cntools_wallet_table_wrapped_triple \
      "" "Registered name" "${registry_name}" 22 20 "${table_width}" ||
      return 1
    cntools_wallet_table_wrapped_triple \
      "" "Ticker" "${ticker}" 22 20 "${table_width}" || return 1
    cntools_wallet_table_wrapped_triple \
      "" "Decimals" "${formatted_decimals}" 22 20 "${table_width}" \
      value "$(cntools_wallet_number_role "${decimals}")" || return 1
    cntools_wallet_table_wrapped_triple \
      "" "Raw total supply" "${display_total_supply}" \
      22 20 "${table_width}" value \
      "$(cntools_wallet_number_role "${total_supply}")" ||
      return 1
    if [[ -n "${description}" ]]; then
      cntools_wallet_table_wrapped_triple \
        "" "Description" "${description}" 22 20 "${table_width}" || return 1
    fi
    if [[ -n "${url}" ]]; then
      cntools_wallet_table_wrapped_triple \
        "" "URL" "${url}" 22 20 "${table_width}" \
        value identifier || return 1
    fi
  done
}

cntools_wallet_render_asset_details_content() {
  local rows_file="${1:-}"
  local title="Native assets"
  local display_count=""

  if [[ "${CNTOOLS_WALLET_ASSET_COUNT:-}" =~ ^[0-9]+$ ]]; then
    cntools_wallet_format_number_into \
      display_count "${CNTOOLS_WALLET_ASSET_COUNT}" || return 1
    title="Native assets (${display_count})"
  fi
  cntools_wallet_render_table_file "${title}" "${rows_file}"
}

cntools_wallet_file_row_count_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_source_file="${2:-}"
  local _cntools_rows=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     -f "${_cntools_source_file}" && ! -L "${_cntools_source_file}" ]] ||
    return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_rows="$(wc -l < "${_cntools_source_file}")" || return 1
  _cntools_rows="${_cntools_rows//[[:space:]]/}"
  [[ "${_cntools_rows}" =~ ^[0-9]+$ ]] || return 1
  _cntools_output_ref="${_cntools_rows}"
}

cntools_wallet_render_asset_metadata_warning() {
  [[ "${CNTOOLS_MODE:-}" == "light" ]] || return 0
  case "${CNTOOLS_WALLET_ASSET_METADATA_STATUS:-not-requested}" in
    partial)
      cntools_ui_render_status warn \
        "Some Koios token metadata is unavailable; holdings remain complete."
      ;;
    unavailable)
      cntools_ui_render_status warn \
        "Koios token metadata is unavailable; holdings remain complete."
      ;;
  esac
}

cntools_wallet_render_asset_details_table() {
  local rows_file=""
  local table_rows=""
  local -a pipeline_status=()

  [[ "${CNTOOLS_WALLET_ASSET_COUNT:-}" =~ ^[1-9][0-9]*$ ]] || return 0
  cntools_wallet_render_asset_metadata_warning || return 1
  cntools_wallet_write_rows_file \
    rows_file cntools_wallet_asset_details_rows || return 1
  cntools_wallet_file_row_count_into table_rows "${rows_file}" || return 1
  [[ "${table_rows}" =~ ^[1-9][0-9]*$ ]] || return 1
  if ! cntools_wallet_asset_details_should_page "${table_rows}"; then
    cntools_wallet_render_asset_details_content "${rows_file}"
    return $?
  fi

  if [[ -n "${NO_COLOR:-}" ]]; then
    cntools_wallet_render_asset_details_content "${rows_file}" |
      cntools_ui_pager --soft-wrap
  else
    (
      export CLICOLOR_FORCE=1
      cntools_wallet_render_asset_details_content "${rows_file}"
    ) | cntools_ui_pager --soft-wrap
  fi
  pipeline_status=("${PIPESTATUS[@]}")
  (( pipeline_status[0] == 0 && pipeline_status[1] == 0 ))
}

cntools_wallet_render_query() {
  local has_base="${1:-Y}"
  local has_payment="${2:-Y}"
  local has_reward="${3:-Y}"
  local level="info"

  case "${CNTOOLS_WALLET_QUERY_STATUS}" in
    available) level="success" ;;
    partial) level="warn" ;;
    unavailable) level="error" ;;
    offline|unsupported) level="warn" ;;
  esac
  cntools_ui_render_status "${level}" "${CNTOOLS_WALLET_QUERY_MESSAGE}"
  if [[ "${has_base}" == "Y" || "${has_payment}" == "Y" ||
        "${has_reward}" == "Y" ]]; then
    cntools_wallet_render_balance_table \
      "${has_base}" "${has_payment}" "${has_reward}" || return 1
  fi
  if [[ "${has_reward}" == "Y" ]]; then
    cntools_wallet_render_delegation_table || return 1
  fi
  if [[ "${has_base}" == "Y" || "${has_payment}" == "Y" ]]; then
    cntools_wallet_render_asset_details_table || return 1
  fi
}

cntools_wallet_action_show_impl() {
  local selected_index=""
  local selector_status=0
  local wallet_directory=""
  local wallet_type=""
  local wallet_protection=""
  local base_address=""
  local payment_address=""
  local reward_address=""
  local query_base=""
  local query_payment=""
  local query_reward=""
  local spinner_title=""
  local derivation_path=""
  local registration=""
  local has_base="N"
  local has_payment="N"
  local has_reward="N"

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
  if ! cntools_wallet_prepare_selected_material "${wallet_directory}"; then
    cntools_wallet_log WARN \
      "Some public wallet material could not be prepared wallet=${CNTOOLS_WALLET_SELECTED_NAME}"
  fi
  wallet_type="$(cntools_wallet_type "${wallet_directory}")" || return 1
  wallet_protection="$(cntools_wallet_protection "${wallet_directory}")" ||
    return 1
  CNTOOLS_WALLET_TYPES[selected_index]="${wallet_type}"
  CNTOOLS_WALLET_PROTECTIONS[selected_index]="${wallet_protection}"
  if [[ "${wallet_type}" == "Mnemonic" ]]; then
    cntools_wallet_read_derivation_path \
      "${wallet_directory}" derivation_path || derivation_path=""
  fi
  cntools_wallet_display_address "${wallet_directory}" base base_address || return 1
  cntools_wallet_display_address "${wallet_directory}" payment payment_address || return 1
  cntools_wallet_display_address "${wallet_directory}" reward reward_address || return 1
  [[ "${base_address}" == addr* ]] && query_base="${base_address}"
  [[ "${payment_address}" == addr* ]] && query_payment="${payment_address}"
  [[ "${reward_address}" == stake* ]] && query_reward="${reward_address}"
  [[ -z "${query_base}" ]] || has_base="Y"
  [[ -z "${query_payment}" ]] || has_payment="Y"
  [[ -z "${query_reward}" ]] || has_reward="Y"

  case "${CNTOOLS_MODE:-offline}" in
    light) spinner_title="Fetching wallet details from Koios…" ;;
    local)
      if [[ "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == "true" ]]; then
        spinner_title="Fetching wallet details from ${CNTOOLS_IMPLEMENTATION_NAME:-the local node}…"
      fi
      ;;
  esac
  cntools_ui_action_begin "Show" "/ Wallet / Show"
  if [[ -n "${spinner_title}" ]]; then
    if ! cntools_ui_spin_function "${spinner_title}" cntools_wallet_query_details \
        "${query_base}" "${query_payment}" "${query_reward}"; then
      cntools_ui_render_status error \
        "Wallet details could not be prepared safely. See ${CNTOOLS_LOG}."
      cntools_ui_wait
      return 1
    fi
  else
    cntools_wallet_query_details \
      "${query_base}" "${query_payment}" "${query_reward}"
  fi

  if [[ "${has_reward}" == "Y" ]]; then
    case "${CNTOOLS_WALLET_REGISTERED:-unknown}" in
      yes) registration="Registered" ;;
      no) registration="Not registered" ;;
      *) registration="Unavailable" ;;
    esac
  fi

  cntools_ui_action_begin "Show" "/ Wallet / Show"
  cntools_wallet_render_identity_table \
    "${CNTOOLS_WALLET_SELECTED_NAME}" \
    "${wallet_type}" "${wallet_protection}" \
    "${registration}" "${derivation_path}" || return 1
  cntools_wallet_render_address_table \
    "${base_address}" "${payment_address}" "${reward_address}" || return 1
  cntools_wallet_render_credential_table "${wallet_directory}" || return 1
  cntools_wallet_render_query \
    "${has_base}" "${has_payment}" "${has_reward}" || return 1
  cntools_ui_wait
}

cntools_wallet_action_show() {
  local status=0

  if cntools_wallet_action_show_impl; then
    status=0
  else
    status=$?
  fi
  cntools_wallet_query_cleanup || true
  cntools_wallet_cleanup_material || true
  return "${status}"
}
