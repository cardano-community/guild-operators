#!/usr/bin/env bash
# Direct receiving addresses. Handle resolution is deliberately not implicit.
# shellcheck disable=SC2034

cntools_recipient_validate() {
  local address="${1:-}" allow_script="${2:-N}" hrp="addr_test"
  local charset="qpzry9x8gf2tvdw0s3jn54khce6mua7l" first="" suffix=""
  local type=0
  [[ "${CNTOOLS_NETWORK:-}" != mainnet ]] || hrp="addr"
  cntools_wallet_bech32_valid "${address}" "${hrp}" || return 1
  first="${address#*1}"; first="${first:0:1}"
  suffix="${charset#*"${first}"}"
  type=$(( (31 - ${#suffix}) >> 1 ))
  # Script credentials do not reveal native-vs-Plutus or required datum data.
  # Only a locally validated native-script recipient may bypass this check.
  [[ "${allow_script}" == Y ]] || (( type % 2 == 0 )) || return 1
}

cntools_recipient_trim_into() {
  local output_name="${1:-}" raw="${2:-}"
  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n trimmed_ref="${output_name}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  trimmed_ref="${raw%"${raw##*[![:space:]]}"}"
}

# Encode ledger address bytes (not text containing an address). Kept in Bash so
# datum resolution does not add a binary dependency. The existing independent
# Bech32/header/network validator checks the result before it leaves this helper.
cntools_recipient_from_hex_into() {
  local -n rh_result="$1"
  local rh_hex="${2:-}" rh_hrp=addr_test rh_text="" rh_char=""
  local rh_i=0 rh_j=0 rh_n=0 rh_acc=0 rh_bits=0 rh_check=1 rh_top=0
  local rh_charset=qpzry9x8gf2tvdw0s3jn54khce6mua7l LC_ALL=C
  local -a rh_values=() rh_generators=(0x3b6a57b2 0x26508e6d 0x1ea119fa 0x3d4233dd 0x2a1462b3)
  rh_result=""
  [[ "${rh_hex}" =~ ^([0-9a-f]{2})+$ && ${#rh_hex} -le 256 ]] || return 1
  [[ "${CNTOOLS_NETWORK:-}" != mainnet ]] || rh_hrp=addr
  for ((rh_i=0; rh_i<${#rh_hrp}; rh_i++)); do
    printf -v rh_n '%d' "'${rh_hrp:rh_i:1}"
    rh_values+=("$((rh_n >> 5))")
  done
  rh_values+=(0)
  for ((rh_i=0; rh_i<${#rh_hrp}; rh_i++)); do
    printf -v rh_n '%d' "'${rh_hrp:rh_i:1}"
    rh_values+=("$((rh_n & 31))")
  done
  for ((rh_i=0; rh_i<${#rh_hex}; rh_i+=2)); do
    rh_acc=$(((rh_acc << 8 | 16#${rh_hex:rh_i:2}) & 4095))
    rh_bits=$((rh_bits+8))
    while ((rh_bits >= 5)); do
      rh_bits=$((rh_bits-5)); rh_n=$((rh_acc >> rh_bits & 31))
      rh_values+=("${rh_n}"); rh_text+="${rh_charset:rh_n:1}"
    done
  done
  if ((rh_bits > 0)); then
    rh_n=$((rh_acc << (5-rh_bits) & 31))
    rh_values+=("${rh_n}"); rh_text+="${rh_charset:rh_n:1}"
  fi
  rh_values+=(0 0 0 0 0 0)
  for rh_n in "${rh_values[@]}"; do
    rh_top=$((rh_check >> 25)); rh_check=$(((rh_check & 0x1ffffff) << 5 ^ rh_n))
    for ((rh_j=0; rh_j<5; rh_j++)); do
      if ((rh_top >> rh_j & 1)); then rh_check=$((rh_check ^ rh_generators[rh_j])); fi
    done
  done
  rh_check=$((rh_check ^ 1))
  for ((rh_i=5; rh_i>=0; rh_i--)); do
    rh_n=$((rh_check >> (5*rh_i) & 31)); rh_char="${rh_charset:rh_n:1}"
    rh_text+="${rh_char}"
  done
  rh_text="${rh_hrp}1${rh_text}"
  cntools_recipient_validate "${rh_text}" || return 1
  rh_result="${rh_text}"
}

# Prove that a cached script recipient is the address of the validated local
# native script, rather than trusting the wallet type or file name alone.
cntools_recipient_native_wallet_matches() {
  local directory="${1:-}" address="${2:-}" primary="" response="" errors="" status=0
  local -a args=() stake_args=() network=()
  cntools_transaction_native_script_valid "${directory}/${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}" || return 1
  cntools_wallet_address_source_arguments "${directory}" payment args || return 1
  if cntools_wallet_read_address "${directory}" base primary && [[ "${primary}" == "${address}" ]]; then
    cntools_wallet_address_source_arguments "${directory}" stake stake_args || return 1
    args+=("${stake_args[@]}")
  fi
  cntools_transaction_network_arguments_into network "${CNTOOLS_NETWORK}" || return 1
  cntools_transaction_temp_file response send-native-recipient || return 1
  cntools_transaction_temp_file errors send-native-recipient-error || return 1
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" address build \
    "${args[@]}" "${network[@]}" || status=$?
  if (( status != 0 )); then
    cntools_transaction_log_cli_failure "Native recipient validation failed" "${status}" "${errors}" "${response}"
    return 1
  fi
  [[ "$(< "${response}")" == "${address}" ]]
}
