#!/usr/bin/env bash
# Discovery and presentation for existing CNTools wallet folders.
# Loaded only by wallet actions.
# shellcheck disable=SC2034

declare -ag CNTOOLS_WALLET_PATHS=()
declare -ag CNTOOLS_WALLET_NAMES=()
declare -ag CNTOOLS_WALLET_TYPES=()
declare -ag CNTOOLS_WALLET_PROTECTIONS=()
declare -ag CNTOOLS_WALLET_ADDRESS_STATES=()

cntools_wallet_log() {
  cntools_log "${1:-INFO}" "${2:-}" || true
}

cntools_wallet_path_components_safe() {
  local path="${1:-}"
  local current="/"
  local component=""
  local -a components=()

  [[ "${path}" = /* &&
     "${path}" != *$'\n'* &&
     "${path}" != *$'\r'* ]] || return 1
  IFS='/' read -r -a components <<< "${path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current%/}/${component}"
    [[ ! -L "${current}" ]] || return 1
  done
}

cntools_wallet_root_safe() {
  local root="${CNTOOLS_WALLET_DIR:-}"
  local physical_root=""

  [[ -n "${root}" && "${root}" = /* &&
     -d "${root}" && ! -L "${root}" &&
     -r "${root}" && -x "${root}" ]] || return 1
  cntools_wallet_path_components_safe "${root}" || return 1
  physical_root="$(cd -- "${root}" 2>/dev/null && pwd -P)" || return 1
  [[ -n "${physical_root}" && "${physical_root}" != "/" ]]
}

cntools_wallet_directory_safe() {
  local wallet_directory="${1:-}"
  local root="${CNTOOLS_WALLET_DIR:-}"
  local physical_root=""
  local physical_wallet=""
  local relative_wallet=""

  cntools_wallet_root_safe || return 1
  [[ -n "${wallet_directory}" && "${wallet_directory}" = /* &&
     -d "${wallet_directory}" && ! -L "${wallet_directory}" &&
     -r "${wallet_directory}" && -x "${wallet_directory}" ]] || return 1
  cntools_wallet_path_components_safe "${wallet_directory}" || return 1
  physical_root="$(cd -- "${root}" 2>/dev/null && pwd -P)" || return 1
  physical_wallet="$(cd -- "${wallet_directory}" 2>/dev/null && pwd -P)" ||
    return 1
  [[ "${physical_wallet}" == "${physical_root}/"* ]] || return 1
  relative_wallet="${physical_wallet#"${physical_root}/"}"
  [[ -n "${relative_wallet}" && "${relative_wallet}" != */* ]]
}

cntools_wallet_safe_regular_file() {
  local file="${1:-}"
  local maximum_bytes="${2:-65536}"
  local size=""

  [[ -n "${file}" && "${maximum_bytes}" =~ ^[1-9][0-9]*$ &&
     -f "${file}" && ! -L "${file}" ]] || return 1
  size="$(wc -c < "${file}" 2>/dev/null || true)"
  size="${size//[[:space:]]/}"
  [[ "${size}" =~ ^[0-9]+$ && ${size} -le ${maximum_bytes} ]]
}

cntools_wallet_file_present() {
  cntools_wallet_safe_regular_file "${1:-}/${2:-}" 65536
}

cntools_wallet_derivation_path_valid() {
  local wallet_directory="${1:-}"
  local derivation_file="${wallet_directory}/${CNTOOLS_WALLET_DERIVATION_PATH_FILENAME}"
  local derivation_path=""
  local nul_probe=""
  local -a derivation_lines=()

  cntools_wallet_safe_regular_file "${derivation_file}" 128 || return 1
  if IFS= read -r -d '' nul_probe < "${derivation_file}"; then
    return 1
  fi
  mapfile -t derivation_lines < "${derivation_file}" || return 1
  [[ ${#derivation_lines[@]} -eq 1 ]] || return 1
  derivation_path="${derivation_lines[0]}"
  [[ "${derivation_path}" =~ ^1852H/1815H/[0-9]+H/x/[0-9]+$ ]]
}

cntools_wallet_read_derivation_path() {
  local _cntools_wallet_directory="${1:-}"
  local _cntools_output_name="${2:-}"
  local _cntools_derivation_file=""
  local _cntools_derivation_value=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  cntools_wallet_derivation_path_valid "${_cntools_wallet_directory}" || return 1
  _cntools_derivation_file="${_cntools_wallet_directory}/${CNTOOLS_WALLET_DERIVATION_PATH_FILENAME}"
  IFS= read -r _cntools_derivation_value < "${_cntools_derivation_file}" ||
    return 1
  _cntools_output_ref="${_cntools_derivation_value}"
}

cntools_wallet_type() {
  local wallet_directory="${1:-}"
  local payment_vkey="${wallet_directory}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"
  local stake_vkey="${wallet_directory}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"
  local hardware_description=""
  local ordinary_key_material=0

  cntools_wallet_directory_safe "${wallet_directory}" || return 3

  if cntools_wallet_file_present "${wallet_directory}" \
       "${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}" ||
     cntools_wallet_file_present "${wallet_directory}" \
       "${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}"; then
    printf 'MultiSig\n'
    return 0
  fi
  if cntools_wallet_file_present "${wallet_directory}" \
       "${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}" ||
     cntools_wallet_file_present "${wallet_directory}" \
       "${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}"; then
    printf 'Hardware\n'
    return 0
  fi
  if cntools_wallet_safe_regular_file "${payment_vkey}" 65536; then
    hardware_description="$(jq -er '.description | strings' \
      "${payment_vkey}" 2>/dev/null || true)"
  fi
  if [[ "${hardware_description}" == *Hardware* ]]; then
    printf 'Hardware\n'
    return 0
  fi
  if cntools_wallet_safe_regular_file "${payment_vkey}" 65536 ||
     cntools_wallet_safe_regular_file "${stake_vkey}" 65536 ||
     cntools_wallet_file_present "${wallet_directory}" \
       "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" ||
     cntools_wallet_file_present "${wallet_directory}" \
       "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" ||
     cntools_wallet_file_present "${wallet_directory}" \
       "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}.gpg" ||
     cntools_wallet_file_present "${wallet_directory}" \
       "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}.gpg"; then
    ordinary_key_material=1
  fi
  if (( ordinary_key_material == 1 )); then
    if cntools_wallet_derivation_path_valid "${wallet_directory}"; then
      printf 'Mnemonic\n'
    else
      printf 'CLI\n'
    fi
  elif cntools_wallet_file_present "${wallet_directory}" \
         "${CNTOOLS_WALLET_BASE_ADDR_FILENAME}" ||
       cntools_wallet_file_present "${wallet_directory}" \
         "${CNTOOLS_WALLET_STAKE_ADDR_FILENAME}" ||
       cntools_wallet_file_present "${wallet_directory}" \
         "${CNTOOLS_WALLET_PAY_ADDR_FILENAME}"; then
    printf 'Incomplete\n'
  else
    printf 'Unknown\n'
  fi
}

cntools_wallet_protection() {
  local wallet_directory="${1:-}"
  local candidate=""

  cntools_wallet_directory_safe "${wallet_directory}" || return 3

  for candidate in "${wallet_directory}"/*.gpg; do
    [[ -e "${candidate}" || -L "${candidate}" ]] || continue
    if [[ -f "${candidate}" && ! -L "${candidate}" ]]; then
      printf 'Protected\n'
      return 0
    fi
  done
  printf 'Open\n'
}

cntools_wallet_address_filename() {
  case "${1:-}" in
    base) printf '%s\n' "${CNTOOLS_WALLET_BASE_ADDR_FILENAME}" ;;
    payment) printf '%s\n' "${CNTOOLS_WALLET_PAY_ADDR_FILENAME}" ;;
    reward) printf '%s\n' "${CNTOOLS_WALLET_STAKE_ADDR_FILENAME}" ;;
    *) return 2 ;;
  esac
}

cntools_wallet_address_hrp() {
  local address_kind="${1:-}"

  case "${CNTOOLS_NETWORK:-}" in
    mainnet)
      case "${address_kind}" in
        base|payment) printf 'addr\n' ;;
        reward) printf 'stake\n' ;;
        *) return 2 ;;
      esac
      ;;
    guild|preprod|preview)
      case "${address_kind}" in
        base|payment) printf 'addr_test\n' ;;
        reward) printf 'stake_test\n' ;;
        *) return 2 ;;
      esac
      ;;
    *) return 2 ;;
  esac
}

cntools_wallet_bech32_valid() {
  local address="${1:-}"
  local expected_hrp="${2:-}"
  local address_kind="${3:-}"
  local charset="qpzry9x8gf2tvdw0s3jn54khce6mua7l"
  local character=""
  local suffix=""
  local character_code=0
  local value=0
  local checksum=1
  local top=0
  local bit=0
  local index=0
  local data_index=0
  local payload_group_count=0
  local first_payload_value=-1
  local second_payload_value=-1
  local last_payload_value=-1
  local padding_bits=0
  local byte_count=0
  local header_byte=0
  local address_type=0
  local network_id=0
  local LC_ALL=C
  local -a generators=(
    0x3b6a57b2 0x26508e6d 0x1ea119fa 0x3d4233dd 0x2a1462b3
  )
  local -a values=()

  [[ -n "${address}" && -n "${expected_hrp}" &&
     "${address}" == "${expected_hrp}1"* &&
     "${address}" != *$'\n'* &&
     "${address}" != *$'\r'* ]] || return 1
  (( ${#address} >= ${#expected_hrp} + 8 && ${#address} <= 256 )) ||
    return 1
  payload_group_count=$((${#address} - ${#expected_hrp} - 7))
  (( payload_group_count >= 2 )) || return 1

  for (( index = 0; index < ${#expected_hrp}; index++ )); do
    character="${expected_hrp:index:1}"
    printf -v character_code '%d' "'${character}"
    values+=("$((character_code >> 5))")
  done
  values+=(0)
  for (( index = 0; index < ${#expected_hrp}; index++ )); do
    character="${expected_hrp:index:1}"
    printf -v character_code '%d' "'${character}"
    values+=("$((character_code & 31))")
  done
  for (( index = ${#expected_hrp} + 1; index < ${#address}; index++ )); do
    character="${address:index:1}"
    suffix="${charset#*"${character}"}"
    [[ "${suffix}" != "${charset}" ]] || return 1
    value=$((${#charset} - ${#suffix} - 1))
    (( value >= 0 && value < 32 )) || return 1
    if (( data_index < payload_group_count )); then
      (( data_index != 0 )) || first_payload_value="${value}"
      (( data_index != 1 )) || second_payload_value="${value}"
      last_payload_value="${value}"
    fi
    values+=("${value}")
    data_index=$((data_index + 1))
  done

  for value in "${values[@]}"; do
    top=$((checksum >> 25))
    checksum=$((((checksum & 0x1ffffff) << 5) ^ value))
    for (( bit = 0; bit < 5; bit++ )); do
      if (( (top >> bit) & 1 )); then
        checksum=$((checksum ^ generators[bit]))
      fi
    done
  done
  (( checksum == 1 )) || return 1

  # Cardano addresses are byte strings converted to five-bit Bech32 groups.
  # Reject non-canonical padding before interpreting the one-byte address
  # header, then verify both its credential type and network tag.
  padding_bits=$(((payload_group_count * 5) % 8))
  (( padding_bits <= 4 )) || return 1
  if (( padding_bits > 0 )); then
    (( (last_payload_value & ((1 << padding_bits) - 1)) == 0 )) || return 1
  fi
  byte_count=$(((payload_group_count * 5 - padding_bits) / 8))
  header_byte=$(((first_payload_value << 3) | (second_payload_value >> 2)))
  address_type=$((header_byte >> 4))
  network_id=$((header_byte & 15))

  case "${expected_hrp}" in
    addr)
      (( network_id == 1 && address_type >= 0 && address_type <= 7 )) ||
        return 1
      ;;
    addr_test)
      (( network_id == 0 && address_type >= 0 && address_type <= 7 )) ||
        return 1
      ;;
    stake)
      (( network_id == 1 &&
         (address_type == 14 || address_type == 15) )) || return 1
      ;;
    stake_test)
      (( network_id == 0 &&
         (address_type == 14 || address_type == 15) )) || return 1
      ;;
    *) return 1 ;;
  esac
  case "${address_type}" in
    0|1|2|3) (( byte_count == 57 )) ;;
    4|5) (( byte_count >= 32 )) ;;
    6|7|14|15) (( byte_count == 29 )) ;;
    *) return 1 ;;
  esac || return 1

  # addr/addr_test is shared by base, pointer and enterprise addresses.  The
  # cached file name declares a narrower role, so also validate the Cardano
  # header type instead of accepting any address with the expected HRP.
  case "${address_kind}" in
    "") ;;
    base) (( address_type >= 0 && address_type <= 3 )) || return 1 ;;
    payment) (( address_type == 6 || address_type == 7 )) || return 1 ;;
    reward) (( address_type == 14 || address_type == 15 )) || return 1 ;;
    *) return 2 ;;
  esac
}

cntools_wallet_read_address() {
  local _cntools_wallet_directory="${1:-}"
  local _cntools_address_kind="${2:-}"
  local _cntools_output_name="${3:-}"
  local _cntools_address_filename=""
  local _cntools_address_file=""
  local _cntools_address_value=""
  local _cntools_expected_hrp=""
  local _cntools_nul_probe=""
  local -a _cntools_address_lines=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  if ! cntools_wallet_directory_safe "${_cntools_wallet_directory}"; then
    cntools_wallet_log ERROR \
      "Wallet directory is no longer safe or accessible: ${_cntools_wallet_directory}"
    return 3
  fi
  _cntools_address_filename="$(
    cntools_wallet_address_filename "${_cntools_address_kind}"
  )" || return 2
  _cntools_expected_hrp="$(
    cntools_wallet_address_hrp "${_cntools_address_kind}"
  )" || return 2
  _cntools_address_file="${_cntools_wallet_directory}/${_cntools_address_filename}"
  [[ -e "${_cntools_address_file}" || -L "${_cntools_address_file}" ]] ||
    return 1
  cntools_wallet_safe_regular_file "${_cntools_address_file}" 256 || return 2
  if IFS= read -r -d '' _cntools_nul_probe < "${_cntools_address_file}"; then
    return 2
  fi
  mapfile -t _cntools_address_lines < "${_cntools_address_file}" || return 2
  [[ ${#_cntools_address_lines[@]} -eq 1 ]] || return 2
  _cntools_address_value="${_cntools_address_lines[0]}"
  cntools_wallet_bech32_valid \
    "${_cntools_address_value}" "${_cntools_expected_hrp}" \
    "${_cntools_address_kind}" || return 2
  _cntools_output_ref="${_cntools_address_value}"
}

cntools_wallet_address_state() {
  local wallet_directory="${1:-}"
  local kind=""
  local address_value=""
  local status=0
  local present=0
  local invalid=0

  for kind in base payment reward; do
    if cntools_wallet_read_address \
        "${wallet_directory}" "${kind}" address_value; then
      present=$((present + 1))
    else
      status=$?
      case "${status}" in
        1) ;;
        2)
          invalid=$((invalid + 1))
          cntools_wallet_log ERROR \
            "Wallet ${wallet_directory##*/} has an invalid ${kind} address file"
          ;;
        *) return "${status}" ;;
      esac
    fi
  done
  if (( invalid > 0 )); then
    printf '%s valid, %s invalid\n' "${present}" "${invalid}"
  else
    printf '%s / 3\n' "${present}"
  fi
}

cntools_wallet_insert_catalog_entry() {
  local path="${1:-}"
  local name="${2:-}"
  local wallet_type="${3:-Unknown}"
  local protection="${4:-Open}"
  local addresses="${5:-0 / 3}"
  local count="${#CNTOOLS_WALLET_NAMES[@]}"
  local insert_at="${count}"
  local index=0

  for (( index = 0; index < count; index++ )); do
    if [[ "${name}" < "${CNTOOLS_WALLET_NAMES[index]}" ]]; then
      insert_at="${index}"
      break
    fi
  done
  for (( index = count; index > insert_at; index-- )); do
    CNTOOLS_WALLET_PATHS[index]="${CNTOOLS_WALLET_PATHS[index-1]}"
    CNTOOLS_WALLET_NAMES[index]="${CNTOOLS_WALLET_NAMES[index-1]}"
    CNTOOLS_WALLET_TYPES[index]="${CNTOOLS_WALLET_TYPES[index-1]}"
    CNTOOLS_WALLET_PROTECTIONS[index]="${CNTOOLS_WALLET_PROTECTIONS[index-1]}"
    CNTOOLS_WALLET_ADDRESS_STATES[index]="${CNTOOLS_WALLET_ADDRESS_STATES[index-1]}"
  done
  CNTOOLS_WALLET_PATHS[insert_at]="${path}"
  CNTOOLS_WALLET_NAMES[insert_at]="${name}"
  CNTOOLS_WALLET_TYPES[insert_at]="${wallet_type}"
  CNTOOLS_WALLET_PROTECTIONS[insert_at]="${protection}"
  CNTOOLS_WALLET_ADDRESS_STATES[insert_at]="${addresses}"
}

cntools_wallet_catalog_build() {
  local root="${CNTOOLS_WALLET_DIR:-}"
  local candidate=""
  local name=""
  local wallet_type=""
  local protection=""
  local addresses=""
  local -a candidates=()

  CNTOOLS_WALLET_PATHS=()
  CNTOOLS_WALLET_NAMES=()
  CNTOOLS_WALLET_TYPES=()
  CNTOOLS_WALLET_PROTECTIONS=()
  CNTOOLS_WALLET_ADDRESS_STATES=()

  [[ -n "${root}" && "${root}" = /* ]] || {
    cntools_wallet_log ERROR "Wallet root is unset or unsafe"
    return 1
  }
  [[ -e "${root}" || -L "${root}" ]] || {
    cntools_wallet_log ERROR "Wallet root does not exist: ${root}"
    return 1
  }
  [[ -d "${root}" && ! -L "${root}" ]] || {
    cntools_wallet_log ERROR "Wallet root is not a safe directory: ${root}"
    return 1
  }
  [[ -r "${root}" && -x "${root}" ]] || {
    cntools_wallet_log ERROR "Wallet root is not accessible: ${root}"
    return 1
  }
  if ! cntools_wallet_path_components_safe "${root}"; then
    cntools_wallet_log ERROR "Wallet root contains a symbolic link: ${root}"
    return 1
  fi
  cntools_wallet_root_safe || {
    cntools_wallet_log ERROR "Wallet root is unsafe: ${root}"
    return 1
  }

  candidates=(
    "${root}"/*
    "${root}"/.[!.]*
    "${root}"/..?*
  )
  for candidate in "${candidates[@]}"; do
    [[ -e "${candidate}" || -L "${candidate}" ]] || continue
    name="$(basename "${candidate}")"
    if [[ "${name}" == .cntools-wallet-new.* ]]; then
      if [[ -d "${candidate}" && ! -L "${candidate}" &&
            -O "${candidate}" ]]; then
        cntools_wallet_log WARN \
          "Skipped internal wallet staging directory (active or interrupted; may contain private key material): ${name}"
      else
        cntools_wallet_log ERROR \
          "Skipped unsafe reserved wallet staging entry: ${name}"
      fi
      continue
    fi
    if [[ -L "${candidate}" ]]; then
      cntools_wallet_log ERROR \
        "Skipped symbolic-link wallet entry: $(basename "${candidate}")"
      continue
    fi
    [[ -d "${candidate}" ]] || continue
    if [[ -z "${name}" || "${name}" == "." || "${name}" == ".." ||
          "${name}" == *[[:cntrl:]]* ]]; then
      cntools_wallet_log ERROR "Skipped wallet with an unsafe directory name"
      continue
    fi
    if ! cntools_wallet_directory_safe "${candidate}"; then
      cntools_wallet_log ERROR \
        "Wallet directory is unsafe or inaccessible: ${name}"
      return 1
    fi
    wallet_type="$(cntools_wallet_type "${candidate}")" || {
      cntools_wallet_log ERROR "Wallet became inaccessible while reading: ${name}"
      return 1
    }
    protection="$(cntools_wallet_protection "${candidate}")" || {
      cntools_wallet_log ERROR "Wallet became inaccessible while reading: ${name}"
      return 1
    }
    addresses="$(cntools_wallet_address_state "${candidate}")" || {
      cntools_wallet_log ERROR "Wallet became inaccessible while reading: ${name}"
      return 1
    }
    cntools_wallet_insert_catalog_entry \
      "${candidate}" "${name}" "${wallet_type}" "${protection}" "${addresses}"
  done
  cntools_wallet_log WALLET "discovered ${#CNTOOLS_WALLET_NAMES[@]} wallet(s)"
}

cntools_wallet_truncate() {
  local value="${1:-}"
  local maximum="${2:-20}"

  [[ "${maximum}" =~ ^[1-9][0-9]*$ ]] || return 2
  if (( ${#value} > maximum )); then
    printf '%s…' "${value:0:maximum-1}"
  else
    printf '%s' "${value}"
  fi
}

cntools_wallet_catalog_primary_into() {
  local wallet_directory="${1:-}"
  local index="${2:-}"
  local address_name="${3:-}"
  local label_name="${4:-}"
  local note_name="${5:-}"
  local address=""
  local label=""
  local note=""

  [[ "${index}" =~ ^[0-9]+$ &&
     "${address_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${label_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${note_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n address_ref="${address_name}"
  local -n label_ref="${label_name}"
  local -n note_ref="${note_name}"
  address_ref=""
  label_ref="Primary address"
  note_ref=""

  if declare -F cntools_wallet_address_primary_into >/dev/null 2>&1; then
    if cntools_wallet_address_primary_into \
        "${wallet_directory}" address label note; then
      address_ref="${address}"
      label_ref="${label:-Primary address}"
      note_ref="${note}"
      return 0
    fi
  fi

  # Cached-address fallback keeps List useful when the focused primary-address
  # helper is unavailable or an older module set is loaded.
  address=""
  if cntools_wallet_read_address "${wallet_directory}" base address; then
    address_ref="${address}"
    label_ref="Base address"
  elif cntools_wallet_read_address \
      "${wallet_directory}" payment address; then
    address_ref="${address}"
    if [[ "${CNTOOLS_WALLET_TYPES[index]:-}" == "MultiSig" ]]; then
      label_ref="Script address"
    else
      label_ref="Payment address"
    fi
  elif cntools_wallet_read_address "${wallet_directory}" reward address; then
    address_ref="${address}"
    label_ref="Stake / reward address"
    note_ref="Payment key missing"
  else
    address_ref="Unavailable"
  fi
}

cntools_wallet_catalog_rows() {
  local index=0
  local wallet_name=""
  local primary_address=""
  local primary_label=""
  local primary_note=""
  local primary_value=""
  local base_balance=""
  local payment_balance=""
  local tokens=""
  local display_tokens=""
  local rewards=""
  local total=""
  local protection_role=""

  cntools_wallet_table_row "Wallet" "Property" "Value" || return 1
  for (( index = 0; index < ${#CNTOOLS_WALLET_NAMES[@]}; index++ )); do
    wallet_name="${CNTOOLS_WALLET_NAMES[index]}"
    cntools_wallet_catalog_primary_into \
      "${CNTOOLS_WALLET_PATHS[index]}" "${index}" \
      primary_address primary_label primary_note || return 1
    primary_value="${primary_address}"
    [[ -z "${primary_note}" ]] ||
      primary_value+=" · ${primary_note}"

    cntools_wallet_table_wrapped_triple \
      "${wallet_name}" "Type" "${CNTOOLS_WALLET_TYPES[index]}" \
      20 22 "" identifier accent ||
      return 1
    protection_role="$(cntools_wallet_status_role \
      "${CNTOOLS_WALLET_PROTECTIONS[index]}")" || return 1
    cntools_wallet_table_wrapped_triple \
      "" "Key protection" "${CNTOOLS_WALLET_PROTECTIONS[index]}" \
      20 22 "" value "${protection_role}" ||
      return 1
    cntools_wallet_table_wrapped_triple \
      "" "${primary_label}" "${primary_value}" \
      20 22 "" value address || return 1

    base_balance="${CNTOOLS_WALLET_LIST_BASE_UTXO_LOVELACE[index]:-}"
    payment_balance="${CNTOOLS_WALLET_LIST_PAYMENT_UTXO_LOVELACE[index]:-}"
    rewards="${CNTOOLS_WALLET_LIST_REWARD_LOVELACE[index]:-}"
    tokens="${CNTOOLS_WALLET_LIST_TOKEN_COUNTS[index]:-}"
    total="${CNTOOLS_WALLET_LIST_TOTAL_LOVELACE[index]:-}"
    if [[ "${base_balance}" =~ ^[1-9][0-9]*$ ]]; then
      cntools_wallet_table_wrapped_triple \
        "" "Base UTxO" \
        "$(cntools_wallet_format_lovelace "${base_balance}")" \
        20 22 "" value number ||
        return 1
    fi
    if [[ "${payment_balance}" =~ ^[1-9][0-9]*$ ]]; then
      cntools_wallet_table_wrapped_triple \
        "" "Payment UTxO" \
        "$(cntools_wallet_format_lovelace "${payment_balance}")" \
        20 22 "" value number ||
        return 1
    fi
    if [[ "${rewards}" =~ ^[1-9][0-9]*$ ]]; then
      cntools_wallet_table_wrapped_triple \
        "" "Rewards" \
        "$(cntools_wallet_format_lovelace "${rewards}")" \
        20 22 "" value number || return 1
    fi
    if [[ "${tokens}" =~ ^[1-9][0-9]*$ ]]; then
      cntools_wallet_format_number_into display_tokens "${tokens}" || return 1
      cntools_wallet_table_wrapped_triple \
        "" "Native assets" "${display_tokens}" \
        20 22 "" value number || return 1
    fi
    if [[ "${total}" =~ ^[1-9][0-9]*$ ]]; then
      cntools_wallet_table_wrapped_triple \
        "" "Total" "$(cntools_wallet_format_lovelace "${total}")" \
        20 22 "" value number ||
        return 1
    fi
  done
}

cntools_wallet_render_catalog() {
  cntools_wallet_render_rows_table \
    "Wallets" cntools_wallet_catalog_rows
}

cntools_wallet_choose() {
  local _cntools_output_name="${1:-}"
  local _cntools_index=0
  local _cntools_selected=""
  local _cntools_row=""
  local _cntools_status=0
  local -a _cntools_rows=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  (( ${#CNTOOLS_WALLET_NAMES[@]} > 0 )) || return 1
  for (( _cntools_index = 0;
         _cntools_index < ${#CNTOOLS_WALLET_NAMES[@]};
         _cntools_index++ )); do
    printf -v _cntools_row '%02d  %-24s  %s · %s' \
      "$((_cntools_index + 1))" \
      "$(cntools_wallet_truncate \
        "${CNTOOLS_WALLET_NAMES[_cntools_index]}" 24)" \
      "${CNTOOLS_WALLET_TYPES[_cntools_index]}" \
      "${CNTOOLS_WALLET_PROTECTIONS[_cntools_index]}"
    _cntools_rows+=("${_cntools_row}")
  done
  if cntools_ui_choose \
      _cntools_selected "Filter wallets…" "${_cntools_rows[@]}"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  if (( _cntools_status != 0 )); then
    return "${_cntools_status}"
  fi
  for (( _cntools_index = 0;
         _cntools_index < ${#_cntools_rows[@]};
         _cntools_index++ )); do
    if [[ "${_cntools_selected}" == "${_cntools_rows[_cntools_index]}" ]]; then
      _cntools_output_ref="${_cntools_index}"
      cntools_wallet_log CHOICE \
        "selected wallet=${CNTOOLS_WALLET_NAMES[_cntools_index]}"
      return 0
    fi
  done
  cntools_wallet_log ERROR "Wallet selector returned an unknown row"
  return 2
}

cntools_wallet_prepare_catalog_material() {
  if declare -F cntools_wallet_materialize_all >/dev/null 2>&1; then
    cntools_wallet_materialize_all
  elif declare -F cntools_wallet_material_prepare >/dev/null 2>&1; then
    cntools_wallet_material_prepare
  else
    cntools_wallet_log WARN \
      "Wallet material helper is unavailable; using cached public files"
    return 0
  fi
}

cntools_wallet_prepare_selected_material() {
  local wallet_directory="${1:-}"

  if declare -F cntools_wallet_materialize_wallet >/dev/null 2>&1; then
    cntools_wallet_materialize_wallet "${wallet_directory}"
  elif declare -F cntools_wallet_material_prepare >/dev/null 2>&1; then
    cntools_wallet_material_prepare "${wallet_directory}"
  else
    cntools_wallet_log WARN \
      "Wallet material helper is unavailable; using cached public files"
    return 0
  fi
}

cntools_wallet_cleanup_material() {
  if declare -F cntools_wallet_material_cleanup >/dev/null 2>&1; then
    cntools_wallet_material_cleanup
  fi
}

cntools_wallet_action_list_impl() {
  local fetch_live="N"
  local spinner_title="Fetching wallet balances and rewards…"
  local confirmation_status=0

  cntools_ui_action_begin "List" "/ Wallet / List"
  if ! cntools_wallet_prepare_catalog_material; then
    cntools_wallet_log WARN \
      "Some wallet public material could not be prepared for List"
  fi
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

  case "${CNTOOLS_MODE:-offline}" in
    light)
      fetch_live="Y"
      spinner_title="Fetching wallet balances and rewards from Koios…"
      ;;
    local)
      if [[ "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == "true" ]]; then
        fetch_live="Y"
        spinner_title="Fetching wallet balances and rewards from ${CNTOOLS_IMPLEMENTATION_NAME:-the local node}…"
      fi
      ;;
  esac

  if [[ "${fetch_live}" == "Y" ]]; then
    if cntools_ui_confirm "Fetch balances and rewards for all wallets now?"; then
      cntools_wallet_log CHOICE "wallet catalog live balances requested"
      if ! cntools_ui_spin_function \
          "${spinner_title}" cntools_wallet_list_query_catalog; then
        cntools_ui_render_status error \
          "Wallet balances could not be prepared safely. See ${CNTOOLS_LOG}."
        cntools_ui_wait
        return 1
      fi
    else
      confirmation_status=$?
      if (( confirmation_status == 1 )); then
        cntools_wallet_log CHOICE "wallet catalog live balances skipped"
        cntools_wallet_list_query_reset
        CNTOOLS_WALLET_LIST_QUERY_LEVEL="info"
        CNTOOLS_WALLET_LIST_QUERY_SUMMARY="Live wallet balances were not requested."
      else
        cntools_wallet_log ERROR \
          "wallet catalog confirmation failed status=${confirmation_status}"
        return "${confirmation_status}"
      fi
    fi
  elif ! cntools_wallet_list_query_catalog; then
    cntools_ui_render_status error \
      "Wallet balances could not be prepared safely. See ${CNTOOLS_LOG}."
    cntools_ui_wait
    return 1
  fi
  [[ -z "${CNTOOLS_WALLET_LIST_QUERY_SUMMARY}" ]] ||
    cntools_ui_render_status \
      "${CNTOOLS_WALLET_LIST_QUERY_LEVEL}" \
      "${CNTOOLS_WALLET_LIST_QUERY_SUMMARY}"
  cntools_wallet_render_catalog || return 1
  cntools_ui_wait
}

cntools_wallet_action_list() {
  local status=0

  if cntools_wallet_action_list_impl; then
    status=0
  else
    status=$?
  fi
  cntools_wallet_query_cleanup || true
  cntools_wallet_cleanup_material || true
  return "${status}"
}
