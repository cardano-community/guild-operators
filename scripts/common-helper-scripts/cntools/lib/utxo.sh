#!/usr/bin/env bash
# Backend-neutral, lossless UTxO inventory. Functions only.
# Loaded after number.sh and wallet-query.sh.
# shellcheck disable=SC2034

CNTOOLS_UTXO_ERROR=""
declare -ag CNTOOLS_UTXO_REFS=()
declare -ag CNTOOLS_UTXO_ADDRESSES=()
declare -ag CNTOOLS_UTXO_LOVELACE=()
declare -ag CNTOOLS_UTXO_ASSET_LISTS=()
declare -ag CNTOOLS_UTXO_ASSET_COUNTS=()
declare -ag CNTOOLS_UTXO_HAS_DATUM=()
declare -ag CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT=()
declare -Ag CNTOOLS_UTXO_INDEX_BY_REF=()
declare -Ag CNTOOLS_UTXO_ASSET_QUANTITIES=()

cntools_utxo_reset() {
  CNTOOLS_UTXO_ERROR=""
  CNTOOLS_UTXO_REFS=()
  CNTOOLS_UTXO_ADDRESSES=()
  CNTOOLS_UTXO_LOVELACE=()
  CNTOOLS_UTXO_ASSET_LISTS=()
  CNTOOLS_UTXO_ASSET_COUNTS=()
  CNTOOLS_UTXO_HAS_DATUM=()
  CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT=()
  CNTOOLS_UTXO_INDEX_BY_REF=()
  CNTOOLS_UTXO_ASSET_QUANTITIES=()
}

cntools_utxo_fail() {
  CNTOOLS_UTXO_ERROR="${1:-UTxO inventory is invalid.}"
  return 1
}

cntools_utxo_add() {
  local reference="${1:-}"
  local address="${2:-}"
  local lovelace="${3:-0}"
  local datum="${4:-N}"
  local reference_script="${5:-N}"
  local index=0

  [[ "${reference}" =~ ^[0-9a-f]{64}#(0|[1-9][0-9]{0,9})$ &&
     "${address}" =~ ^[A-Za-z0-9_]+$ && ${#address} -le 256 &&
     "${datum}" =~ ^[YN]$ && "${reference_script}" =~ ^[YN]$ ]] ||
    return 2
  cntools_uint_normalize_into lovelace "${lovelace}" || return 2
  [[ -z "${CNTOOLS_UTXO_INDEX_BY_REF[${reference}]+x}" ]] || return 1
  index="${#CNTOOLS_UTXO_REFS[@]}"
  CNTOOLS_UTXO_REFS[index]="${reference}"
  CNTOOLS_UTXO_ADDRESSES[index]="${address}"
  CNTOOLS_UTXO_LOVELACE[index]="${lovelace}"
  CNTOOLS_UTXO_ASSET_LISTS[index]=""
  CNTOOLS_UTXO_ASSET_COUNTS[index]=0
  CNTOOLS_UTXO_HAS_DATUM[index]="${datum}"
  CNTOOLS_UTXO_HAS_REFERENCE_SCRIPT[index]="${reference_script}"
  CNTOOLS_UTXO_INDEX_BY_REF["${reference}"]="${index}"
}

cntools_utxo_set_lovelace() {
  local index="${1:-}"
  local lovelace="${2:-}"

  [[ "${index}" =~ ^[0-9]+$ &&
     -n "${CNTOOLS_UTXO_REFS[index]+x}" ]] || return 2
  cntools_uint_normalize_into lovelace "${lovelace}" || return 2
  CNTOOLS_UTXO_LOVELACE[index]="${lovelace}"
}

cntools_utxo_add_asset() {
  local index="${1:-}"
  local asset_id="${2:-}"
  local quantity="${3:-}"
  local key=""
  local current=""
  local total=""

  asset_id="${asset_id,,}"
  [[ "${index}" =~ ^[0-9]+$ &&
     -n "${CNTOOLS_UTXO_REFS[index]+x}" &&
     "${asset_id}" =~ ^[0-9a-f]{56}\.([0-9a-f]{2}){0,32}$ ]] || return 2
  cntools_uint_normalize_into quantity "${quantity}" || return 2
  key="${index}|${asset_id}"
  if [[ -n "${CNTOOLS_UTXO_ASSET_QUANTITIES[${key}]+x}" ]]; then
    current="${CNTOOLS_UTXO_ASSET_QUANTITIES[${key}]}"
    cntools_uint_add_into total "${current}" "${quantity}" || return 1
    CNTOOLS_UTXO_ASSET_QUANTITIES["${key}"]="${total}"
    return 0
  fi
  CNTOOLS_UTXO_ASSET_QUANTITIES["${key}"]="${quantity}"
  if [[ -n "${CNTOOLS_UTXO_ASSET_LISTS[index]}" ]]; then
    CNTOOLS_UTXO_ASSET_LISTS[index]+=" ${asset_id}"
  else
    CNTOOLS_UTXO_ASSET_LISTS[index]="${asset_id}"
  fi
  CNTOOLS_UTXO_ASSET_COUNTS[index]=$((CNTOOLS_UTXO_ASSET_COUNTS[index] + 1))
}

cntools_utxo_load_local() {
  local source_file="${1:-}"
  local base_address="${2:-}"
  local payment_address="${3:-${base_address}}"
  local parsed=""
  local kind=""
  local first=""
  local second=""
  local quantity=""
  local reference=""
  local current_index=""
  local address=""
  local datum=""
  local reference_script=""
  local lovelace_rows=0
  local -Ag addresses=()
  local -Ag datums=()
  local -Ag scripts=()

  cntools_utxo_reset
  [[ -f "${source_file}" && ! -L "${source_file}" ]] || return 2
  jq -e --arg base "${base_address}" --arg payment "${payment_address}" '
    type == "object" and length <= 1000 and
    all(to_entries[];
      (.key | test("^[0-9a-f]{64}#(0|[1-9][0-9]{0,9})$")) and
      (.value | type == "object") and
      (.value.address == $base or .value.address == $payment) and
      (.value.value | type == "object" and has("lovelace")))
  ' "${source_file}" >/dev/null 2>&1 ||
    cntools_utxo_fail "The local node returned an invalid or oversized UTxO response." ||
    return 1
  while IFS=$'\037' read -r reference address datum reference_script; do
    [[ -n "${reference}" ]] || continue
    addresses["${reference}"]="${address}"
    datums["${reference}"]="${datum}"
    scripts["${reference}"]="${reference_script}"
  done < <(jq -r 'to_entries[] | [
      .key,
      .value.address,
      (if ((.value.datum // null) != null or
           (.value.datumhash // null) != null or
           (.value.inlineDatum // null) != null or
           (.value.inlineDatumhash // null) != null)
       then "Y" else "N" end),
      (if ((.value.referenceScript // null) != null)
       then "Y" else "N" end)
    ] | join("\u001f")' "${source_file}")
  parsed="$(cntools_wallet_query_local_utxo_rows "${source_file}")" ||
    cntools_utxo_fail "The local UTxO quantities could not be parsed without precision loss." ||
    return 1
  while IFS=$'\037' read -r kind first second quantity; do
    case "${kind}" in
      "") continue ;;
      U)
        reference="${first}"
        [[ -n "${addresses[${reference}]+x}" ]] || return 1
        cntools_utxo_add "${reference}" "${addresses[${reference}]}" 0 \
          "${datums[${reference}]}" "${scripts[${reference}]}" || return 1
        current_index="${CNTOOLS_UTXO_INDEX_BY_REF[${reference}]}"
        ;;
      L)
        [[ -n "${current_index}" ]] || return 1
        cntools_utxo_set_lovelace "${current_index}" "${first}" || return 1
        lovelace_rows=$((lovelace_rows + 1))
        ;;
      A)
        [[ -n "${current_index}" ]] || return 1
        cntools_utxo_add_asset \
          "${current_index}" "${first}.${second}" "${quantity}" || return 1
        ;;
      *) return 1 ;;
    esac
  done <<< "${parsed}"
  (( ${#CNTOOLS_UTXO_REFS[@]} == ${#addresses[@]} &&
     lovelace_rows == ${#CNTOOLS_UTXO_REFS[@]} )) ||
    cntools_utxo_fail "The local node returned an incomplete UTxO value." ||
    return 1
}

cntools_utxo_load_koios() {
  local source_file="${1:-}"
  local base_address="${2:-}"
  local payment_address="${3:-${base_address}}"
  local kind=""
  local first=""
  local second=""
  local third=""
  local fourth=""
  local fifth=""
  local current_index=""

  cntools_utxo_reset
  [[ -f "${source_file}" && ! -L "${source_file}" ]] || return 2
  jq -e --arg base "${base_address}" --arg payment "${payment_address}" '
    def uint: type == "string" and length <= 80 and test("^(0|[1-9][0-9]*)$");
    def policy: type == "string" and test("^[0-9a-fA-F]{56}$");
    def asset_name:
      type == "null" or
      (type == "string" and test("^([0-9a-fA-F]{2}){0,32}$"));
    type == "array" and length <= 1000 and
    all(.[].tx_hash; type == "string" and test("^[0-9a-f]{64}$")) and
    all(.[].tx_index;
      type == "number" and . >= 0 and . <= 4294967295 and floor == .) and
    all(.[].address; . == $base or . == $payment) and
    all(.[].value; uint) and
    all(.[].asset_list;
      . == null or (type == "array" and all(.[].policy_id; policy) and
        all(.[].asset_name; asset_name) and all(.[].quantity; uint))) and
    ([.[] | (.tx_hash + "#" + (.tx_index | tostring))] | unique | length)
      == length
  ' "${source_file}" >/dev/null 2>&1 ||
    cntools_utxo_fail "Koios returned an invalid or oversized UTxO response." ||
    return 1
  while IFS=$'\037' read -r kind first second third fourth fifth; do
    case "${kind}" in
      U)
        cntools_utxo_add "${first}" "${second}" "${third}" \
          "${fourth}" "${fifth}" || return 1
        current_index="${CNTOOLS_UTXO_INDEX_BY_REF[${first}]}"
        ;;
      A)
        [[ -n "${current_index}" ]] || return 1
        cntools_utxo_add_asset \
          "${current_index}" "${first}.${second}" "${third}" || return 1
        ;;
      *) return 1 ;;
    esac
  done < <(jq -r '.[] as $utxo |
      (["U", ($utxo.tx_hash + "#" + ($utxo.tx_index | tostring)),
       $utxo.address, $utxo.value,
       (if (($utxo.datum_hash // null) != null or
            ($utxo.inline_datum // null) != null)
        then "Y" else "N" end),
       (if (($utxo.reference_script // null) != null)
        then "Y" else "N" end)] | join("\u001f")),
      (($utxo.asset_list // [])[] |
       ["A", .policy_id, (.asset_name // ""), .quantity] |
       join("\u001f"))' "${source_file}")
}

cntools_utxo_value_add_index() {
  local index="${1:-}"
  local lovelace_name="${2:-}"
  local ids_name="${3:-}"
  local quantities_name="${4:-}"
  local asset_id=""
  local key=""
  local total=""
  local -a asset_ids=()

  [[ "${index}" =~ ^[0-9]+$ &&
     -n "${CNTOOLS_UTXO_REFS[index]+x}" &&
     "${lovelace_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${ids_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${quantities_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n lovelace_ref="${lovelace_name}"
  local -n ids_ref="${ids_name}"
  local -n quantities_ref="${quantities_name}"
  cntools_uint_add_into total \
    "${lovelace_ref:-0}" "${CNTOOLS_UTXO_LOVELACE[index]}" || return 1
  lovelace_ref="${total}"
  if [[ -n "${CNTOOLS_UTXO_ASSET_LISTS[index]}" ]]; then
    read -r -a asset_ids <<< "${CNTOOLS_UTXO_ASSET_LISTS[index]}" || return 1
  fi
  for asset_id in "${asset_ids[@]}"; do
    key="${index}|${asset_id}"
    if [[ -z "${quantities_ref[${asset_id}]+x}" ]]; then
      ids_ref+=("${asset_id}")
      quantities_ref["${asset_id}"]="${CNTOOLS_UTXO_ASSET_QUANTITIES[${key}]}"
    else
      cntools_uint_add_into total "${quantities_ref[${asset_id}]}" \
        "${CNTOOLS_UTXO_ASSET_QUANTITIES[${key}]}" || return 1
      quantities_ref["${asset_id}"]="${total}"
    fi
  done
}
