#!/usr/bin/env bash
# Optional public delegation context. Never replace authoritative wallet balances.
# shellcheck disable=SC2034
CNTOOLS_WALLET_DELEGATED_POOL='{}' CNTOOLS_WALLET_DELEGATED_DREP='{}'

cntools_wallet_delegation_info_collect() {
  local pool='' pool_hex='' id='' kind='' hash='' response='' payload=''
  CNTOOLS_WALLET_DELEGATED_POOL='{}' CNTOOLS_WALLET_DELEGATED_DREP='{}'
  [[ "${CNTOOLS_MODE:-offline}" != offline && "${CNTOOLS_KOIOS_ENABLED:-N}" == Y &&
     "${CNTOOLS_KOIOS_API:-}" == https://* ]] || return 0
  cntools_wallet_query_temp_file response || return 1
  if [[ -n "${CNTOOLS_WALLET_POOL_DELEGATION:-}" ]] && cntools_pool_id_into pool pool_hex "${CNTOOLS_WALLET_POOL_DELEGATION}"; then
    payload="$(jq -nc --arg id "${pool}" '{_pool_bech32_ids:[$id]}')" || return 1
    if cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/pool_info" "${payload}" "${response}" &&
        jq -se --arg id "${pool}" --arg hash "${pool_hex}" 'length == 1 and (.[0] | type == "array" and length <= 1 and
          all(.[]; .pool_id_bech32 == $id and .pool_id_hex == $hash))' "${response}" >/dev/null; then
      CNTOOLS_WALLET_DELEGATED_POOL="$(jq -c '.[0] // {}' "${response}")"
    else cntools_wallet_log WARN 'Optional delegated pool context unavailable'; fi
  fi
  if [[ -n "${CNTOOLS_WALLET_DREP_DELEGATION:-}" ]] &&
      cntools_drep_id_into id kind hash "${CNTOOLS_WALLET_DREP_DELEGATION}" && [[ "${kind}" == key || "${kind}" == script ]]; then
    payload="$(jq -nc --arg id "${id}" '{_drep_ids:[$id]}')" || return 1
    if cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/drep_info" "${payload}" "${response}" &&
        jq -se --arg id "${id}" --arg hash "${hash}" --arg kind "${kind}" 'length == 1 and
          (.[0] | type == "array" and length <= 1 and all(.[]; .drep_id == $id and .hex == $hash and
            .has_script == ($kind == "script") and (.active | type == "boolean") and
            (.drep_status == "registered" or .drep_status == "deregistered" or .drep_status == "not_registered")))' "${response}" >/dev/null; then
      CNTOOLS_WALLET_DELEGATED_DREP="$(jq -c '.[0] // {}' "${response}")"
    else cntools_wallet_log WARN 'Optional delegated DRep context unavailable'; fi
  fi
}

cntools_wallet_delegation_info_render() {
  local record='' key='' value='' role=''
  record="${CNTOOLS_WALLET_DELEGATED_POOL}"
  if [[ "${record}" != '{}' ]]; then
    {
      value="$(jq -r '[.meta_json.ticker,.meta_json.name] | map(select(type == "string" and length > 0)) | join(" · ")' <<< "${record}")"
      [[ -z "${value}" ]] || cntools_table_pair Name "${value}" accent
      cntools_table_pair Status "$(jq -r '.pool_status // "Unavailable"' <<< "${record}")" value
      cntools_table_pair Source 'Koios API' muted
    } | cntools_table_render 'Delegated stake pool'
  fi
  record="${CNTOOLS_WALLET_DELEGATED_DREP}"
  if [[ "${record}" != '{}' ]]; then
    {
      cntools_table_pair Registration "$(jq -r '.drep_status // "Unavailable"' <<< "${record}")" value
      cntools_table_pair Activity "$(jq -r 'if .active then "Active" else "Inactive" end' <<< "${record}")" "$([[ "$(jq -r .active <<< "${record}")" == true ]] && printf success || printf warning)"
      for key in expires_epoch_no amount live_delegator_count meta_url meta_hash; do
        value="$(jq -r --arg key "${key}" '.[$key] | select(type == "number" or type == "string")' <<< "${record}")" || return 1
        [[ -n "${value}" ]] || continue
        role=number
        case "${key}" in
          expires_epoch_no) key='Expiry epoch'; [[ "${value}" =~ ^[0-9]+$ ]] || continue; value="$(cntools_number_format "${value}")" ;;
          amount) key='Voting power (snapshot)'; [[ "${value}" =~ ^[0-9]+$ ]] || continue; value="$(cntools_number_format_lovelace "${value}")" ;;
          live_delegator_count) key=Delegators; [[ "${value}" =~ ^[0-9]+$ ]] || continue; value="$(cntools_number_format "${value}")" ;;
          meta_url) key='Metadata URL'; role=identifier ;;
          meta_hash) key='Metadata hash'; role=identifier ;;
        esac
        cntools_table_pair "${key}" "${value}" "${role}"
      done
      cntools_table_pair Source 'Koios API' muted
    } | cntools_table_render 'Delegated DRep'
    cntools_public_metadata_offer "$(jq -r '.meta_url // ""' <<< "${record}")" "$(jq -r '.meta_hash // ""' <<< "${record}")"
  fi
}
