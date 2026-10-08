#!/usr/bin/env bash
# Read-only operational diagnostics; never issue a certificate or alter counters.
# shellcheck disable=SC2034
declare -ag CNTOOLS_POOL_KES_STATUS=() CNTOOLS_POOL_KES_EXPIRY=() CNTOOLS_POOL_KES_REMAINING=()
declare -ag CNTOOLS_POOL_CERT_DISK=() CNTOOLS_POOL_CERT_CHAIN=() CNTOOLS_POOL_CERT_NEXT=() CNTOOLS_POOL_KES_SOURCE=()
declare -ag CNTOOLS_POOL_KES_TIME=()

# Minimal bounded CBOR uint reader for public certificate period/counter fields.
cntools_pool_health_uint_into() {
  local target="$1" remainder="$2" encoded="$3" head="${3:0:2}" digits=0 value=0
  [[ "${head}" =~ ^[0-9a-f]{2}$ ]] || return 1
  value=$((16#${head}))
  if ((value <= 23)); then
    printf -v "${target}" '%s' "${value}"; printf -v "${remainder}" '%s' "${encoded:2}"; return 0
  fi
  case "${head}" in 18) digits=2 ;; 19) digits=4 ;; 1a) digits=8 ;; 1b) digits=16 ;; *) return 1 ;; esac
  [[ "${encoded:2:digits}" =~ ^[0-9a-f]+$ && ${#encoded} -ge $((2+digits)) ]] || return 1
  # Values above the operationally meaningful signed range are not guessed.
  [[ "${digits}" != 16 || "${encoded:2:8}" == 00000000 ]] || return 1
  value=$((16#${encoded:2:digits}))
  ((value <= 2147483647)) || return 1
  printf -v "${target}" '%s' "${value}"; printf -v "${remainder}" '%s' "${encoded:2+digits}"
}

cntools_pool_health_collect() {
  local index="$1" query_node="${2:-Y}" directory="${CNTOOLS_POOL_DIRECTORIES[$1]}" filename='' cert='' counter='' start='' period='' rest='' saved_start=''
  local slots="${CNTOOLS_SLOTS_PER_KES_PERIOD:-}" evolutions='' genesis="${CNTOOLS_SHELLEY_GENESIS:-}" now='' current='' end=0 remaining=0 expires='' response='' errors='' chain=''
  CNTOOLS_POOL_KES_STATUS[index]='Unavailable' CNTOOLS_POOL_KES_EXPIRY[index]='' CNTOOLS_POOL_KES_REMAINING[index]=''
  CNTOOLS_POOL_CERT_DISK[index]='' CNTOOLS_POOL_CERT_CHAIN[index]='' CNTOOLS_POOL_CERT_NEXT[index]='' CNTOOLS_POOL_KES_SOURCE[index]=''
  CNTOOLS_POOL_KES_TIME[index]=''
  cntools_pool_file_name_into filename opcert
  if ! cntools_pool_public_file_safe "${directory}/${filename}"; then CNTOOLS_POOL_KES_STATUS[index]='No operational certificate'; return 0; fi
  cert="${directory}/${filename}"
  # Bind to the pool and KES public keys using the existing structural validator.
  local cold='' hot='' cold_hex='' hot_hex='' cbor='' uint='(0[0-9a-f]|1[0-7]|18[0-9a-f]{2}|19[0-9a-f]{4}|1a[0-9a-f]{8}|1b[0-9a-f]{16})'
  cntools_pool_file_name_into cold cold-vkey; cntools_pool_file_name_into hot kes-vkey
  if ! cntools_pool_public_file_safe "${directory}/${cold}" || ! cntools_pool_public_file_safe "${directory}/${hot}"; then return 0; fi
  cold_hex="$(jq -er '.cborHex | ascii_downcase | select(test("^5820[0-9a-f]{64}$")) | .[4:]' "${directory}/${cold}")" || return 0
  hot_hex="$(jq -er '.cborHex | ascii_downcase | select(test("^5820[0-9a-f]{64}$")) | .[4:]' "${directory}/${hot}")" || return 0
  cbor="$(jq -esr --arg pattern "^82845820${hot_hex}${uint}${uint}5840[0-9a-f]{128}5820${cold_hex}$" '
    select(length == 1 and .[0].type == "NodeOperationalCertificate") | .[0].cborHex | ascii_downcase | select(test($pattern))' "${cert}")" || return 0
  [[ -n "${cbor}" ]] || return 0
  cntools_pool_health_uint_into counter rest "${cbor:72}" && cntools_pool_health_uint_into start rest "${rest}" || return 0
  CNTOOLS_POOL_CERT_DISK[index]="${counter}"
  cntools_pool_file_name_into filename kes-start
  if cntools_pool_public_file_safe "${directory}/${filename}" 64; then
    saved_start="$(< "${directory}/${filename}")"
    [[ "${saved_start}" == "${start}" ]] || cntools_pool_warning_add "${index}" 'kes.start differs from the operational certificate'
  fi
  cntools_pool_file_name_into filename counter
  if cntools_pool_public_file_safe "${directory}/${filename}"; then
    rest="$(jq -esr 'select(length == 1 and .[0].type == "NodeOperationalCertificateIssueCounter") | .[0].cborHex|ascii_downcase|select(test("^82[0-9a-f]+$"))|.[2:]' "${directory}/${filename}")" || rest=''
    if cntools_pool_health_uint_into period rest "${rest}" && [[ "${rest}" == "5820${cold_hex}" ]]; then
      CNTOOLS_POOL_CERT_NEXT[index]="${period}"
      ((period > counter)) || cntools_pool_warning_add "${index}" 'Issue counter is not ahead of the current certificate; do not reset it'
    fi
  fi
  # Local node data is authoritative for the on-chain counter and current tip.
  if [[ "${query_node}" == Y && "${CNTOOLS_MODE:-offline}" != offline && "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == true && -x "${CNTOOLS_CLI:-}" ]] && cntools_wallet_query_local_socket_ready; then
    cntools_transaction_temp_file response kes-health && cntools_transaction_temp_file errors kes-health-errors || return 1
    cntools_wallet_query_network_arguments || return 1
    if cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" latest query kes-period-info \
        "${CNTOOLS_WALLET_NETWORK_ARGS[@]}" --socket-path "${CNTOOLS_SOCKET}" --op-cert-file "${cert}" --output-json &&
        jq -se --argjson start "${start}" 'length == 1 and (.[0] | type == "object" and
          all(.qKesCurrentKesPeriod,.qKesStartKesInterval,.qKesEndKesInterval,.qKesSlotsPerKesPeriod,.qKesMaxKESEvolutions;
            type == "number" and . >= 0 and . <= 2147483647 and floor == .) and
          .qKesSlotsPerKesPeriod > 0 and .qKesMaxKESEvolutions > 0 and
          .qKesStartKesInterval == $start and .qKesEndKesInterval == ($start+.qKesMaxKESEvolutions) and
          (.qKesNodeStateOperationalCertificateNumber | . == null or (type == "number" and . >= 0 and floor == . and . <= 2147483647)))' "${response}" >/dev/null; then
      current="$(jq -r .qKesCurrentKesPeriod "${response}")"
      slots="$(jq -r .qKesSlotsPerKesPeriod "${response}")"; evolutions="$(jq -r .qKesMaxKESEvolutions "${response}")"
      chain="$(jq -r '.qKesNodeStateOperationalCertificateNumber // ""' "${response}")"
      CNTOOLS_POOL_KES_SOURCE[index]='Local node'
    else
      cntools_transaction_log WARN "KES node query unavailable pool=${CNTOOLS_POOL_NAMES[index]}; using certificate and wall clock"
    fi
  fi
  if [[ -z "${chain}" ]]; then
    chain="$(jq -r '.op_cert_counter // ""' <<< "${CNTOOLS_POOL_CURRENT[index]}")"
  fi
  if [[ "${chain}" =~ ^(0|[1-9][0-9]{0,9})$ ]]; then
    CNTOOLS_POOL_CERT_CHAIN[index]="${chain}"
    # Ledger permits the same counter or its immediate successor.
    if ((counter < chain || counter > chain+1)); then cntools_pool_warning_add "${index}" 'Operational certificate counter does not match the ledger or its next counter'; fi
  fi
  if [[ -z "${evolutions}" ]] && cntools_pool_public_file_safe "${genesis}" 1048576; then
    evolutions="$(jq -r '.maxKESEvolutions // ""' "${genesis}")"
    [[ -n "${slots}" ]] || slots="$(jq -r '.slotsPerKESPeriod // ""' "${genesis}")"
  fi
  [[ "${slots}" =~ ^[1-9][0-9]{0,9}$ && "${evolutions}" =~ ^[1-9][0-9]{0,3}$ ]] || return 0
  if [[ -z "${current}" ]]; then
    now="$(cntools_health_now)"; period="$(cntools_health_reference_slot "${CNTOOLS_NETWORK}" "${now}")" || return 0
    current=$((period / slots)); CNTOOLS_POOL_KES_SOURCE[index]='Certificate + wall-clock estimate'
  fi
  end=$((start+evolutions)); remaining=$((end-current))
  cntools_slot_datetime_into expires "$((end*slots))" || expires='Unavailable'
  CNTOOLS_POOL_KES_EXPIRY[index]="${expires}" CNTOOLS_POOL_KES_REMAINING[index]="${remaining}"
  now="$(cntools_health_now)"
  if period="$(cntools_health_reference_slot "${CNTOOLS_NETWORK}" "${now}")"; then
    local seconds=$((end*slots-period))
    if ((seconds <= 0)); then CNTOOLS_POOL_KES_TIME[index]=Expired
    else CNTOOLS_POOL_KES_TIME[index]="$((seconds/86400)) days $((seconds%86400/3600)) hours"; fi
  fi
  CNTOOLS_POOL_KES_STATUS[index]=Healthy
  if ((current < start)); then CNTOOLS_POOL_KES_STATUS[index]='Not yet valid'
  elif ((remaining <= 0)); then CNTOOLS_POOL_KES_STATUS[index]=Expired
  elif ((remaining <= 7)); then CNTOOLS_POOL_KES_STATUS[index]='Expiring soon'; fi
  cntools_transaction_log POOL "KES pool=${CNTOOLS_POOL_NAMES[index]} status=${CNTOOLS_POOL_KES_STATUS[index]} remaining=${remaining} source=${CNTOOLS_POOL_KES_SOURCE[index]}"
}

cntools_pool_health_rows() {
  local index="$1" detailed="${2:-N}" role=warning
  [[ "${CNTOOLS_POOL_KES_STATUS[index]:-}" != Healthy ]] || role=success
  cntools_table_pair 'KES health' "${CNTOOLS_POOL_KES_STATUS[index]:-Not checked}" "${role}"
  [[ -z "${CNTOOLS_POOL_KES_REMAINING[index]:-}" ]] || cntools_table_pair 'KES periods remaining' "$(cntools_number_format "${CNTOOLS_POOL_KES_REMAINING[index]}")" "${role}"
  [[ "${detailed}" == Y ]] || return 0
  [[ -z "${CNTOOLS_POOL_KES_EXPIRY[index]:-}" ]] || cntools_table_pair 'KES expires' "${CNTOOLS_POOL_KES_EXPIRY[index]}" "${role}"
  [[ -z "${CNTOOLS_POOL_KES_TIME[index]:-}" ]] || cntools_table_pair 'Time until expiry · clock' "${CNTOOLS_POOL_KES_TIME[index]}" "${role}"
  [[ -z "${CNTOOLS_POOL_KES_SOURCE[index]:-}" ]] || cntools_table_pair 'KES source' "${CNTOOLS_POOL_KES_SOURCE[index]}" muted
  [[ -z "${CNTOOLS_POOL_CERT_DISK[index]:-}" ]] || cntools_table_pair 'Certificate counter · disk' "${CNTOOLS_POOL_CERT_DISK[index]}" number
  cntools_table_pair 'Certificate counter · ledger' "${CNTOOLS_POOL_CERT_CHAIN[index]:-Unavailable}" muted
  [[ -z "${CNTOOLS_POOL_CERT_NEXT[index]:-}" ]] || cntools_table_pair 'Next issue counter' "${CNTOOLS_POOL_CERT_NEXT[index]}" number
}
