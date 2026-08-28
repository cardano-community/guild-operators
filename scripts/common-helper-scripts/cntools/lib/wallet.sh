#!/usr/bin/env bash
# Read-only discovery and presentation for existing CNTools wallet folders.
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

cntools_wallet_type() {
  local wallet_directory="${1:-}"
  local payment_vkey="${wallet_directory}/${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"
  local stake_vkey="${wallet_directory}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"
  local payment_script="${wallet_directory}/${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}"
  local stake_script="${wallet_directory}/${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}"
  local hardware_description=""

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
  elif cntools_wallet_safe_regular_file "${payment_vkey}" 65536 &&
       cntools_wallet_safe_regular_file "${stake_vkey}" 65536; then
    printf 'CLI\n'
  elif cntools_wallet_safe_regular_file "${payment_vkey}" 65536 ||
       cntools_wallet_safe_regular_file "${stake_vkey}" 65536 ||
       cntools_wallet_file_present "${wallet_directory}" \
         "${CNTOOLS_WALLET_BASE_ADDR_FILENAME}" ||
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
    "${_cntools_address_value}" "${_cntools_expected_hrp}" || return 2
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
        2) invalid=$((invalid + 1)) ;;
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
    if [[ -L "${candidate}" ]]; then
      cntools_wallet_log ERROR \
        "Skipped symbolic-link wallet entry: $(basename "${candidate}")"
      continue
    fi
    [[ -d "${candidate}" ]] || continue
    name="$(basename "${candidate}")"
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

cntools_wallet_render_catalog() {
  local width=""
  local index=0
  local name=""
  local content=""
  local -a rows=()

  width="$(cntools_gum_width)" || width=78
  if (( width >= 72 )); then
    for (( index = 0; index < ${#CNTOOLS_WALLET_NAMES[@]}; index++ )); do
      name="$(cntools_wallet_truncate "${CNTOOLS_WALLET_NAMES[index]}" 26)"
      printf -v content '%-26s  %-10s  %-10s  %s' \
        "${name}" "${CNTOOLS_WALLET_TYPES[index]}" \
        "${CNTOOLS_WALLET_PROTECTIONS[index]}" \
        "${CNTOOLS_WALLET_ADDRESS_STATES[index]}"
      rows+=("${content}")
    done
    cntools_ui_static_table \
      "Wallet                      Type        Keys        Address files" \
      "${rows[@]}"
  else
    for (( index = 0; index < ${#CNTOOLS_WALLET_NAMES[@]}; index++ )); do
      printf -v content '%s\nType: %s  ·  Keys: %s\nAddress files: %s' \
        "${CNTOOLS_WALLET_NAMES[index]}" "${CNTOOLS_WALLET_TYPES[index]}" \
        "${CNTOOLS_WALLET_PROTECTIONS[index]}" \
        "${CNTOOLS_WALLET_ADDRESS_STATES[index]}"
      cntools_gum style --margin "0 2 1 2" --padding "0 1" \
        --border rounded --border-foreground "${CNTOOLS_GUM_COLOR_DIVIDER}" \
        --foreground "${CNTOOLS_GUM_COLOR_TEXT}" "${content}" || return 1
    done
  fi
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

cntools_wallet_action_list() {
  cntools_ui_action_begin "List" "/ Wallet / List"
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
  cntools_wallet_render_catalog || return 1
  cntools_ui_wait
}
