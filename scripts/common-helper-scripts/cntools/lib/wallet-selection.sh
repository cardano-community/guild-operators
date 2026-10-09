#!/usr/bin/env bash
# Action-specific candidates. Missing/unknown chain state is never treated as zero.
# shellcheck disable=SC2034
declare -Ag CNTOOLS_SELECTION_REGISTERED=() CNTOOLS_SELECTION_REWARDS=()
CNTOOLS_SELECTION_CHECKED=0 CNTOOLS_SELECTION_SCOPE=''

cntools_wallet_selection_material() {
  local directory="$1" role="$2" name=''
  local -a names=()
  case "${role}" in
    payment) names=("${CNTOOLS_WALLET_PAY_VKEY_FILENAME}" "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}" "${CNTOOLS_WALLET_PAY_SKEY_FILENAME}.gpg" "${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}") ;;
    stake) names=("${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}" "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}.gpg" "${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}") ;;
    drep) names=("${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}" "${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}" "${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}.gpg" "${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}" "${CNTOOLS_WALLET_DREP_SCRIPT_FILENAME:-drep.script}") ;;
    *) return 1 ;;
  esac
  for name in "${names[@]}"; do [[ ! -L "${directory}/${name}" && -f "${directory}/${name}" ]] && return 0; done
  return 1
}

cntools_wallet_selection_collect() {
  local context="$1" directory='' address='' payload='' response='' now=0 registered='' rewards='' status='' offset=0 snapshot=''
  local -a addresses=() batch=()
  case "${context}" in register|deregister|delegate|vote-delegate|withdraw) ;; *) return 0 ;; esac
  printf -v now '%(%s)T' -1
  local scope="${CNTOOLS_NETWORK}|${CNTOOLS_MODE:-offline}|${CNTOOLS_KOIOS_ENABLED:-N}|${CNTOOLS_KOIOS_API:-}|${CNTOOLS_SOCKET:-}|${CNTOOLS_WALLET_PATHS[*]}"
  [[ "${scope}" != "${CNTOOLS_SELECTION_SCOPE}" || $((now-CNTOOLS_SELECTION_CHECKED)) -ge 60 ]] || return 0
  CNTOOLS_SELECTION_REGISTERED=() CNTOOLS_SELECTION_REWARDS=()
  CNTOOLS_SELECTION_SCOPE="${scope}" CNTOOLS_SELECTION_CHECKED="${now}"
  [[ "${CNTOOLS_MODE:-offline}" != offline ]] || return 0
  for directory in "${CNTOOLS_WALLET_PATHS[@]}"; do
    cntools_wallet_read_address "${directory}" reward address || continue
    addresses+=("${address}")
  done
  (( ${#addresses[@]} > 0 )) || return 0
  if [[ "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && "${CNTOOLS_KOIOS_API:-}" == https://* ]]; then
    cntools_wallet_query_temp_file response || return 0
    for ((offset=0; offset<${#addresses[@]}; offset+=100)); do
      batch=("${addresses[@]:offset:100}")
      payload="$(printf '%s\n' "${batch[@]}" | jq -Rsc '{_stake_addresses:(split("\n")[:-1]|unique)}')" || return 0
      if ! cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/account_info" "${payload}" "${response}" ||
        ! jq -se --argjson requested "$(jq -c ._stake_addresses <<< "${payload}")" 'length == 1 and (.[0] | type == "array" and
          length == (map(.stake_address)|unique|length) and all(.[];
            (.stake_address as $a | $requested | index($a) != null) and
            (.status == "registered" or .status == "not registered" or .status == "not_registered" or .status == "deregistered") and
            (.rewards_available | type == "string" and test("^[0-9]+$"))))' "${response}" >/dev/null; then
        cntools_wallet_log WARN 'Wallet suitability batch unavailable; unknown wallets remain selectable'
        continue
      fi
      while IFS=$'\037' read -r address status rewards; do
        [[ "${status}" != registered ]] && registered=no || registered=yes
        CNTOOLS_SELECTION_REGISTERED["${address}"]="${registered}" CNTOOLS_SELECTION_REWARDS["${address}"]="${rewards}"
      done < <(jq -r '.[] | [.stake_address,.status,.rewards_available] | join("\u001f")' "${response}")
      # Absence means never used only after a successful validated batch.
      for address in "${batch[@]}"; do
        [[ -n "${CNTOOLS_SELECTION_REGISTERED[${address}]+x}" ]] || { CNTOOLS_SELECTION_REGISTERED["${address}"]=no; CNTOOLS_SELECTION_REWARDS["${address}"]=0; }
      done
    done
  fi
  # Bound single-address local calls; stop at the first unavailable node. The
  # selected wallet always receives a fresh authoritative check before building.
  if [[ "${CNTOOLS_LOCAL_CLI_CAPABLE:-false}" == true && -x "${CNTOOLS_CLI:-}" ]] && cntools_wallet_query_local_socket_ready; then
    cntools_wallet_query_network_arguments || return 0
    offset=0
    for address in "${addresses[@]}"; do
      [[ -z "${CNTOOLS_SELECTION_REGISTERED[${address}]+x}" ]] || continue
      ((offset < 10)) || break
      offset=$((offset+1))
      snapshot="$(cntools_wallet_query_local_stake "${address}" && printf '%s %s' "${CNTOOLS_WALLET_REGISTERED}" "${CNTOOLS_WALLET_REWARD_LOVELACE}")" || break
      read -r registered rewards <<< "${snapshot}"
      [[ "${registered}" =~ ^(yes|no)$ && "${rewards}" =~ ^[0-9]+$ ]] || continue
      CNTOOLS_SELECTION_REGISTERED["${address}"]="${registered}" CNTOOLS_SELECTION_REWARDS["${address}"]="${rewards}"
    done
  fi
}

cntools_wallet_selection_candidate_into() {
  local destination="$1" index="$2" context="$3" directory="${CNTOOLS_WALLET_PATHS[$2]}" address='' candidate_annotation='' registration=''
  [[ -n "${context}" ]] || { printf -v "${destination}" ''; return 0; }
  if [[ "${CNTOOLS_WALLET_TYPES[index]}" == MultiSig ]]; then
    case "${context}" in
      send|collect) ;;
      drep-register|drep-update|drep-retire|gov-vote) cntools_wallet_selection_material "${directory}" drep || return 1 ;;
      register|deregister|delegate|vote-delegate|withdraw)
        cntools_wallet_file_present "${directory}" "${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}" || return 1 ;;
      *) return 1 ;;
    esac
    cntools_wallet_file_present "${directory}" "${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}" || return 1
    candidate_annotation='Native script · participants selected after wallet'
  else
    [[ "${CNTOOLS_WALLET_TYPES[index]}" != Unknown ]] || return 1
    cntools_wallet_selection_material "${directory}" payment || return 1
    case "${context}" in
      register|deregister|delegate|vote-delegate|withdraw|catalyst) cntools_wallet_selection_material "${directory}" stake || return 1 ;;
      drep-register|drep-update|drep-retire|gov-vote) cntools_wallet_selection_material "${directory}" drep || return 1 ;;
    esac
  fi
  if [[ "${context}" =~ ^(register|deregister|delegate|vote-delegate|withdraw)$ ]]; then
    candidate_annotation='Stake status checked after selection'
    if cntools_wallet_read_address "${directory}" reward address; then
      registration="${CNTOOLS_SELECTION_REGISTERED[${address}]:-}"
      [[ "${context}:${registration}" != register:yes && "${context}:${registration}" != deregister:no ]] || return 1
      [[ "${context}" != withdraw || "${CNTOOLS_SELECTION_REWARDS[${address}]:-unknown}" != 0 ]] || return 1
      if [[ "${context}" == withdraw && -n "${CNTOOLS_SELECTION_REWARDS[${address}]:-}" ]]; then
        candidate_annotation="Rewards $(cntools_wallet_format_lovelace "${CNTOOLS_SELECTION_REWARDS[${address}]}")"
      elif [[ -n "${registration}" ]]; then
        [[ "${registration}" == yes ]] && candidate_annotation=Registered || candidate_annotation='Not registered · registration needed'
      fi
    fi
    [[ "${CNTOOLS_WALLET_TYPES[index]}" != MultiSig ]] || candidate_annotation="Native script · ${candidate_annotation}"
  fi
  printf -v "${destination}" '%s' "${candidate_annotation}"
}
