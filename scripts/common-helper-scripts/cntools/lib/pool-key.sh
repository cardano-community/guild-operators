#!/usr/bin/env bash
# Pool-specific artifact validation and missing-only public derivation in staging.
# shellcheck disable=SC2034
cntools_pool_key_validate() {
  local file="$1" role="$2" kind="$3" expected="" pattern=""
  case "${role}:${kind}" in
    cold:signing) expected=StakePoolSigningKey_ed25519; pattern='^5820[0-9a-fA-F]{64}$' ;;
    cold:verification) expected=StakePoolVerificationKey_ed25519; pattern='^5820[0-9a-fA-F]{64}$' ;;
    kes:signing) expected='KesSigningKey_ed25519_kes_2^6'; pattern='^590260[0-9a-fA-F]{1216}$' ;;
    kes:verification) expected='KesVerificationKey_ed25519_kes_2^6'; pattern='^5820[0-9a-fA-F]{64}$' ;;
    vrf:signing) expected=VrfSigningKey_PraosVRF; pattern='^5840[0-9a-fA-F]{128}$' ;;
    vrf:verification) expected=VrfVerificationKey_PraosVRF; pattern='^5820[0-9a-fA-F]{64}$' ;;
    *) return 2 ;;
  esac
  cntools_pool_public_file_safe "${file}" || return 1
  jq -es --arg type "${expected}" --arg pattern "${pattern}" '
    length == 1 and (.[0] | type == "object") and .[0].type == $type and
    (.[0].cborHex | type == "string" and test($pattern))
  ' "${file}" >/dev/null 2>&1
}

cntools_pool_key_pair_prepare() {
  local directory="$1" role="$2" signing="" verification="" derived=""
  cntools_pool_file_name_into signing "${role}-skey" || return 1
  cntools_pool_file_name_into verification "${role}-vkey" || return 1
  if [[ -e "${directory}/${signing}" ]]; then
    cntools_pool_key_validate "${directory}/${signing}" "${role}" signing || return 1
    cntools_pool_temp_into derived "${directory}" || return 1
    cntools_pool_cli key verification-key --signing-key-file "${directory}/${signing}" --verification-key-file "${derived}" || return 1
    cntools_pool_key_validate "${derived}" "${role}" verification || return 1
    if [[ -e "${directory}/${verification}" || -L "${directory}/${verification}" ]]; then
      cntools_pool_key_validate "${directory}/${verification}" "${role}" verification &&
        jq -es 'length == 2 and (.[0].cborHex|ascii_downcase) == (.[1].cborHex|ascii_downcase)' \
          "${directory}/${verification}" "${derived}" >/dev/null || return 1
    else
      ln -- "${derived}" "${directory}/${verification}" || return 1
    fi
  elif [[ -e "${directory}/${verification}" ]]; then
    cntools_pool_key_validate "${directory}/${verification}" "${role}" verification || return 1
  fi
}

cntools_pool_hardware_pair_validate() {
  local directory="$1" hws="" vkey="" hw_public="" public="" path=""
  cntools_pool_file_name_into hws cold-hardware || return 1
  cntools_pool_file_name_into vkey cold-vkey || return 1
  cntools_pool_public_file_safe "${directory}/${hws}" && cntools_pool_key_validate "${directory}/${vkey}" cold verification || return 1
  jq -es 'length == 1 and .[0].type == "StakePoolHWSigningFile_ed25519" and
    (.[0].path | type == "string" and test("^1853H/1815H/0H/[0-9]{1,10}H$")) and
    (.[0].cborXPubKeyHex | type == "string" and test("^5840[0-9a-fA-F]{128}$"))' "${directory}/${hws}" >/dev/null || return 1
  path="$(jq -r '.path' "${directory}/${hws}")"; path="${path##*/}"; path="${path%H}"
  ((10#${path} <= 2147483647)) || return 1
  hw_public="$(jq -r '.cborXPubKeyHex[4:68]|ascii_downcase' "${directory}/${hws}")"
  public="$(jq -r '.cborHex[4:]|ascii_downcase' "${directory}/${vkey}")"
  [[ "${hw_public}" == "${public}" ]]
}

cntools_pool_public_records_prepare() {
  local directory="$1" cold="" kes="" counter="" cert="" idfile="" stdout="" errors=""
  local public="" hot="" pool_id="" pool_hex="" cached="" cached_hex="" file="" cbor=""
  local uint='(0[0-9a-f]|1[0-7]|18[0-9a-f]{2}|19[0-9a-f]{4}|1a[0-9a-f]{8}|1b[0-9a-f]{16})'
  cntools_pool_file_name_into cold cold-vkey; cntools_pool_file_name_into kes kes-vkey
  cntools_pool_file_name_into counter counter; cntools_pool_file_name_into cert opcert
  cntools_pool_file_name_into idfile id
  cntools_pool_key_validate "${directory}/${cold}" cold verification || return 1
  public="$(jq -r '.cborHex[4:]|ascii_downcase' "${directory}/${cold}")" || return 1
  if [[ -e "${directory}/${counter}" ]]; then
    cntools_pool_public_file_safe "${directory}/${counter}" || return 1
    jq -es --arg pattern "^82${uint}5820${public}$" 'length == 1 and .[0].type == "NodeOperationalCertificateIssueCounter" and
      (.[0].cborHex | type == "string" and (ascii_downcase|test($pattern)))' "${directory}/${counter}" >/dev/null || return 1
  fi
  if [[ -e "${directory}/${cert}" ]]; then
    cntools_pool_key_validate "${directory}/${kes}" kes verification && cntools_pool_public_file_safe "${directory}/${cert}" || return 1
    hot="$(jq -r '.cborHex[4:]|ascii_downcase' "${directory}/${kes}")" || return 1
    cbor="$(jq -esr --arg pattern "^82845820${hot}${uint}${uint}5840[0-9a-f]{128}5820${public}$" '
      select(length == 1 and .[0].type == "NodeOperationalCertificate") | .[0].cborHex |
      select(type == "string") | ascii_downcase | select(test($pattern))' "${directory}/${cert}")" || return 1
    # This is structural/key binding, not cryptographic signature verification.
    [[ -n "${cbor}" ]] || return 1
  fi
  cntools_transaction_temp_file stdout pool-id-output || return 1
  cntools_transaction_temp_file errors pool-id-errors || return 1
  if ! cntools_transaction_run_cli "${stdout}" "${errors}" -- "${CNTOOLS_CLI}" latest stake-pool id \
      --cold-verification-key-file "${directory}/${cold}" --output-bech32; then
    cntools_transaction_log_cli_failure 'Could not derive pool ID' 1 "${errors}" "${stdout}"; return 1
  fi
  cntools_pool_id_into pool_id pool_hex "$(< "${stdout}")" || return 1
  for file in "${directory}/${idfile}" "${directory}/${idfile}-bech32"; do
    if [[ -e "${file}" || -L "${file}" ]]; then
      cntools_pool_public_file_safe "${file}" 1024 && cntools_pool_id_into cached cached_hex "$(< "${file}")" &&
        [[ "${cached}" == "${pool_id}" ]] || return 1
    else
      if [[ "${file}" == "${directory}/${idfile}" ]]; then printf '%s\n' "${pool_hex}" > "${file}"; else printf '%s\n' "${pool_id}" > "${file}"; fi
      chmod 0600 "${file}" || return 1
    fi
  done
  CNTOOLS_POOL_WRITTEN_ID="${pool_id}"
}
