#!/usr/bin/env bash
# Exact-target DRep registration queries. Never infer identity from metadata.
# shellcheck disable=SC2034
CNTOOLS_DREP_STATUS=""
CNTOOLS_DREP_ACTIVE=""
CNTOOLS_DREP_SOURCE=""

cntools_drep_parse_local() {
  local file="$1" kind="$2" hash="$3" field=keyHash
  [[ "${kind}" != script ]] || field=scriptHash
  jq -se 'length == 1 and (.[0] | type == "array" and length <= 1)' "${file}" >/dev/null || return 1
  [[ "$(jq length "${file}")" != 0 ]] || return 4
  jq -e --arg field "${field}" --arg hash "${hash}" '
    .[0] | type == "array" and length == 2 and
    .[0] == {($field):$hash} and (.[1] | type == "object" and
      (.expiry | type == "number" and . >= 0 and floor == .) and
      (.deposit | type == "number" and . >= 0 and floor == .))' "${file}" >/dev/null || return 1
  CNTOOLS_DREP_STATUS=registered
  # Raw ledger expiry alone does not account for dormant governance epochs.
  CNTOOLS_DREP_ACTIVE=unknown
}

cntools_drep_parse_koios() {
  local file="$1" id="$2" kind="$3" hash="$4"
  jq -se 'length == 1 and (.[0] | type == "array" and length <= 1)' "${file}" >/dev/null || return 1
  [[ "$(jq length "${file}")" != 0 ]] || return 4
  jq -e --arg id "${id}" --arg kind "${kind}" --arg hash "${hash}" '
    .[0] | .drep_id == $id and .hex == $hash and .has_script == ($kind == "script") and
    (.drep_status == "registered" or .drep_status == "deregistered" or .drep_status == "not_registered") and
    (.active | type == "boolean")' "${file}" >/dev/null || return 1
  [[ "$(jq -r '.[0].drep_status' "${file}")" == registered ]] || return 4
  CNTOOLS_DREP_STATUS=registered
  CNTOOLS_DREP_ACTIVE="$(jq -r '.[0].active' "${file}")"
}

cntools_drep_query() {
  local id="$1" kind="$2" hash="$3" backend="$4" output="" errors="" payload="" status=0 flag=--drep-key-hash
  local verified="" verified_kind="" verified_hash=""
  local -a network=()
  CNTOOLS_DREP_STATUS="" CNTOOLS_DREP_ACTIVE="" CNTOOLS_DREP_SOURCE=""
  cntools_drep_id_into verified verified_kind verified_hash "${id}" || return 2
  [[ "${verified}" == "${id}" && "${verified_kind}" == "${kind}" && "${verified_hash}" == "${hash}" ]] || return 2
  [[ "${backend}" == local || "${backend}" == koios ]] || return 2
  if [[ "${kind}" == abstain || "${kind}" == no-confidence ]]; then
    CNTOOLS_DREP_STATUS=predefined CNTOOLS_DREP_ACTIVE=true CNTOOLS_DREP_SOURCE='Predefined ledger option'
    return 0
  fi
  cntools_transaction_temp_file output drep-state || return 1
  if [[ "${backend}" == local ]]; then
    cntools_transaction_temp_file errors drep-errors || return 1
    cntools_transaction_network_arguments_into network || return 1
    [[ "${kind}" != script ]] || flag=--drep-script-hash
    cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" latest query drep-state \
      "${flag}" "${hash}" "${network[@]}" --socket-path "${CNTOOLS_SOCKET}" --output-json || status=$?
    if ((status != 0)); then
      cntools_transaction_log_cli_failure 'DRep state query failed' "${status}" "${errors}" "${output}"; return 1
    fi
    cntools_drep_parse_local "${output}" "${kind}" "${hash}" || return $?
    CNTOOLS_DREP_SOURCE='Local node'
  else
    [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && "${CNTOOLS_KOIOS_API:-}" =~ ^https://[^[:space:]]+$ ]] || return 1
    payload="$(jq -nc --arg id "${id}" '{_drep_ids:[$id]}')" || return 1
    cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/drep_info" "${payload}" "${output}" || return 1
    cntools_drep_parse_koios "${output}" "${id}" "${kind}" "${hash}" || return $?
    CNTOOLS_DREP_SOURCE='Koios API'
  fi
  cntools_transaction_log QUERY "DRep=${id} status=${CNTOOLS_DREP_STATUS} active=${CNTOOLS_DREP_ACTIVE} source=${CNTOOLS_DREP_SOURCE}"
}
