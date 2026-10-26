#!/usr/bin/env bash
# Pool owner/reward checks and explicitly approved, atomic CLI stake setup.
# shellcheck disable=SC2034
declare -Ag CNTOOLS_POOL_STAKE_STATUS=() CNTOOLS_POOL_STAKE_DELEGATION=() CNTOOLS_POOL_STAKE_BALANCE=()
declare -ag CNTOOLS_POOL_EXTRA_CERTIFICATES=()
CNTOOLS_POOL_EXTRA_EXPECTED='[]'
CNTOOLS_POOL_EXTRA_RECORDS='[]'
CNTOOLS_POOL_STAKE_PLAN='[]'
CNTOOLS_POOL_STAKE_SETUP_ASKABLE=N
CNTOOLS_POOL_REG_POOL_DEPOSIT=0

# Local queries may report the pool as hex; Koios reports Bech32.
cntools_pool_stake_delegated_here() {
  local delegated="${CNTOOLS_POOL_STAKE_DELEGATION[$1]:-}"
  [[ -n "${delegated}" ]] && [[ "${delegated}" == "${CNTOOLS_POOL_REG_ID}" || "${delegated,,}" == "${CNTOOLS_POOL_REG_HEX,,}" ]]
}

cntools_pool_stake_records() {
  jq -cn --argjson owners "${CNTOOLS_POOL_REG_OWNERS}" --arg reward_label "${CNTOOLS_POOL_REG_REWARD_LABEL}" \
    --arg hash "${CNTOOLS_POOL_REG_REWARD_HASH}" --arg vkey "${CNTOOLS_POOL_REG_REWARD_VKEY}" \
    --arg address "${CNTOOLS_POOL_REG_REWARD_ADDRESS}" --arg source "${CNTOOLS_POOL_REG_REWARD_SOURCE:-}" \
    '$owners + [{label:$reward_label,hash:$hash,vkey:$vkey,address:$address,source:$source}] | unique_by(.hash)'
}

cntools_pool_stake_collect() {
  local record='' address='' hash='' payload='' response='' entry='' balance='' offset=0 index=0
  local -a records=() addresses=()
  CNTOOLS_POOL_STAKE_STATUS=(); CNTOOLS_POOL_STAKE_DELEGATION=(); CNTOOLS_POOL_STAKE_BALANCE=()
  mapfile -t records < <(cntools_pool_stake_records | jq -c '.[]')
  for record in "${records[@]}"; do
    hash="$(jq -r .hash <<< "${record}")"; CNTOOLS_POOL_STAKE_STATUS["${hash}"]=unknown
  done
  if [[ "${CNTOOLS_WALLET_REGISTER_BACKEND}" == local ]]; then
    cntools_wallet_query_network_arguments || return 1
    for record in "${records[@]}"; do
      hash="$(jq -r .hash <<< "${record}")"; address="$(jq -r .address <<< "${record}")"
      cntools_wallet_query_reset
      if [[ -z "${address}" ]] || ! cntools_wallet_query_local_stake "${address}"; then continue; fi
      CNTOOLS_POOL_STAKE_STATUS["${hash}"]="${CNTOOLS_WALLET_REGISTERED}"
      CNTOOLS_POOL_STAKE_DELEGATION["${hash}"]="${CNTOOLS_WALLET_POOL_DELEGATION:-}"
      balance="${CNTOOLS_WALLET_REWARD_LOVELACE}"
      address="$(jq -r '.baseAddress // empty' <<< "${record}")"
      if [[ -n "${address}" ]] && cntools_wallet_query_local_address "${address}" base; then
        cntools_uint_add_into balance "${balance}" "${CNTOOLS_WALLET_BASE_LOVELACE}" || return 1
        CNTOOLS_POOL_STAKE_BALANCE["${hash}"]="${balance}"
      fi
    done
  else
    # Batch by stake address, preserving exact lovelace strings. Reward + owner
    # duplicates are queried and counted once; arbitrary response IDs are rejected.
    for ((offset=0; offset<${#records[@]}; offset+=100)); do
      addresses=()
      for record in "${records[@]:offset:100}"; do addresses+=("$(jq -r .address <<< "${record}")"); done
      payload="$(printf '%s\n' "${addresses[@]}" | jq -Rsc '{_stake_addresses:(split("\n")[:-1]|unique)}')" || return 1
      cntools_transaction_temp_file response pool-stake-accounts || return 1
      if ! cntools_wallet_query_http "${CNTOOLS_KOIOS_API%/}/account_info?select=stake_address,status,delegated_pool,utxo::text,rewards_available::text" \
          "${payload}" "${response}" 4194304; then
        cntools_transaction_log WARN 'Pool stake account lookup failed; registration/balance remain unknown'; continue
      fi
      if ! jq -e --argjson request "${payload}" '
        type == "array" and ((map(.stake_address)|unique|length) == length) and
        all(.[]; .stake_address as $a | ($request._stake_addresses|index($a)) != null and
          (.status == "registered" or .status == "not registered") and
          (.utxo|type == "string" and length <= 80 and test("^[0-9]+$")) and
          (.rewards_available|type == "string" and length <= 80 and test("^[0-9]+$")) and
          (.delegated_pool == null or (.delegated_pool|type == "string" and test("^pool1[023456789acdefghjklmnpqrstuvwxyz]{51}$"))))
        ' "${response}" >/dev/null 2>&1; then
        cntools_transaction_log ERROR 'Malformed pool stake account response; registration/balance remain unknown'; continue
      fi
      for ((index=offset; index<${#records[@]} && index<offset+100; index++)); do
        record="${records[index]}"; hash="$(jq -r .hash <<< "${record}")"; address="$(jq -r .address <<< "${record}")"
        entry="$(jq -c --arg address "${address}" 'map(select(.stake_address == $address)) | .[0] // null' "${response}")"
        CNTOOLS_POOL_STAKE_STATUS["${hash}"]=no; balance=0
        if [[ "${entry}" != null ]]; then
          [[ "$(jq -r .status <<< "${entry}")" != registered ]] || CNTOOLS_POOL_STAKE_STATUS["${hash}"]=yes
          CNTOOLS_POOL_STAKE_DELEGATION["${hash}"]="$(jq -r '.delegated_pool // empty' <<< "${entry}")"
          cntools_uint_add_into balance "$(jq -r .utxo <<< "${entry}")" "$(jq -r .rewards_available <<< "${entry}")" || return 1
        fi
        CNTOOLS_POOL_STAKE_BALANCE["${hash}"]="${balance}"
      done
    done
  fi
  for record in "${records[@]}"; do
    hash="$(jq -r .hash <<< "${record}")"
    cntools_transaction_log POOL "Stake credential=${hash} registration=${CNTOOLS_POOL_STAKE_STATUS[${hash}]:-unknown} delegation=${CNTOOLS_POOL_STAKE_DELEGATION[${hash}]:-none} pledgeBalance=${CNTOOLS_POOL_STAKE_BALANCE[${hash}]:-unavailable} backend=${CNTOOLS_WALLET_REGISTER_BACKEND}"
  done
}

# Owner balances for the review's pledge row; asks only when they do not
# cover the declared pledge. Registration and delegation show per owner in the review.
CNTOOLS_POOL_PLEDGE_TOTAL='' CNTOOLS_POOL_PLEDGE_UNKNOWN=N
cntools_pool_stake_guidance() {
  local record='' hash='' total=0 unknown=N choice=''
  while IFS= read -r record; do
    hash="$(jq -r .hash <<< "${record}")"
    if [[ -n "${CNTOOLS_POOL_STAKE_BALANCE[${hash}]:-}" ]]; then
      cntools_uint_add_into total "${total}" "${CNTOOLS_POOL_STAKE_BALANCE[${hash}]}" || return 2
    else unknown=Y; fi
  done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_REG_OWNERS}")
  CNTOOLS_POOL_PLEDGE_TOTAL="${total}" CNTOOLS_POOL_PLEDGE_UNKNOWN="${unknown}"
  cntools_transaction_log POOL "Pledge check knownOwnerBalance=${total} declared=${CNTOOLS_POOL_REG_PLEDGE} missingBalances=${unknown} backend=${CNTOOLS_WALLET_REGISTER_BACKEND}"
  [[ "${unknown}" == Y ]] || ! cntools_uint_greater_equal "${total}" "${CNTOOLS_POOL_REG_PLEDGE}" || return 0
  { cntools_table_pair 'Owner balances + rewards' "$(cntools_number_format_lovelace "${total}")" number
    cntools_table_pair 'Declared pledge' "$(cntools_number_format_lovelace "${CNTOOLS_POOL_REG_PLEDGE}")" number
    [[ "${CNTOOLS_WALLET_REGISTER_BACKEND}" != local ]] || cntools_table_pair Coverage 'Known base addresses + rewards only; other stake-linked addresses are not counted' muted
    [[ "${unknown}" != Y ]] || cntools_table_pair Coverage 'Partial · some owner balances unavailable' warning
  } | cntools_table_render 'Pledge check' || return 2
  cntools_ui_render_status warn 'Pledge is below the declared amount or could not be fully verified. This may prevent pool rewards.'
  cntools_pool_registration_choose choice 'Continue with this pledge commitment?' 'Yes, continue' 'Cancel transaction' || return $?
  [[ "${choice}" == 'Yes, continue' ]] || return 1
}

# The review's pledge row: owner balances against the declared pledge.
cntools_pool_stake_pledge_row() {
  local value='' role=success
  [[ -n "${CNTOOLS_POOL_PLEDGE_TOTAL}" ]] || return 0
  value="$(cntools_number_format_lovelace "${CNTOOLS_POOL_PLEDGE_TOTAL}")"
  if [[ "${CNTOOLS_POOL_PLEDGE_UNKNOWN}" == Y ]]; then value+=' known · some balances unavailable'; role=warning
  elif cntools_uint_greater_equal "${CNTOOLS_POOL_PLEDGE_TOTAL}" "${CNTOOLS_POOL_REG_PLEDGE}"; then value+=' · covers the pledge'
  else value+=' · below the pledge'; role=warning; fi
  [[ "${CNTOOLS_WALLET_REGISTER_BACKEND}" != local ]] || value+=' · base addresses + rewards'
  cntools_table_pair 'Owner balances' "${value}" "${role}"
}

# Registration and delegation of one owner or reward account, after this
# transaction's stake setup. Sets the row's text and role.
cntools_pool_stake_state_into() {
  local text_output="$1" role_output="$2" hash="$3" kind="$4" stake_label='' setup='' registered='' state_text='' state_role=warning
  registered="${CNTOOLS_POOL_STAKE_STATUS[${hash}]:-unknown}"
  setup="$(jq -r --arg hash "${hash}" 'map(select(.hash == $hash)) | .[0].setup // empty' <<< "${CNTOOLS_POOL_STAKE_PLAN:-[]}")" || return 1
  # Not checked yet (settings before the first check): no state to show.
  if [[ -z "${CNTOOLS_POOL_STAKE_STATUS[${hash}]+x}" && -z "${setup}" ]]; then
    printf -v "${text_output}" '%s' ''; printf -v "${role_output}" '%s' identifier; return 0
  fi
  case "${registered}" in yes) stake_label=Registered ;; no) stake_label='Not registered' ;; *) stake_label='Registration unknown' ;; esac
  if [[ "${setup}" == delegate ]]; then
    state_role=success
    if [[ "${registered}" == no ]]; then state_text='Not registered · registered and delegated here by this transaction'
    else state_text="${stake_label} · delegated here by this transaction"; fi
  elif [[ "${setup}" == register ]]; then
    state_text='Not registered · registered by this transaction'; state_role=success
  elif [[ "${registered}" != yes ]]; then
    state_text="${stake_label}"; [[ "${registered}" == no ]] || state_role=muted
  elif [[ "${kind}" == reward ]]; then
    state_text=Registered; state_role=success
  elif cntools_pool_stake_delegated_here "${hash}"; then
    state_text='Registered · delegated here'; state_role=success
  elif [[ -n "${CNTOOLS_POOL_STAKE_DELEGATION[${hash}]:-}" ]]; then
    state_text='Registered · delegated to another pool'
  else
    state_text='Registered · not delegated'
  fi
  printf -v "${text_output}" '%s' "${state_text}"
  printf -v "${role_output}" '%s' "${state_role}"
}

# Explicit answers to the stake setup questions, by question and stake
# credential. Quick reuses them after owner/reward edits instead of
# re-applying its default; "ask" (review → Change stake setup) asks again.
declare -Ag CNTOOLS_POOL_STAKE_SETUP_CHOSEN=()
CNTOOLS_POOL_STAKE_SETUP_NOTE=''

# Quick includes the main-owner delegation and reward registration; "ask"
# (review → Change stake setup) asks in both styles.
cntools_pool_stake_setup_choose() {
  local mode="${1:-}" record='' source='' kind='' hash='' status='' choice='' deposit='' plan='[]' primary='' title='' remembered=''
  CNTOOLS_POOL_STAKE_PLAN='[]'; CNTOOLS_POOL_EXTRA_RECORDS='[]'; CNTOOLS_POOL_EXTRA_EXPECTED='[]'; CNTOOLS_POOL_EXTRA_CERTIFICATES=()
  CNTOOLS_POOL_STAKE_SETUP_ASKABLE=N; CNTOOLS_POOL_STAKE_SETUP_NOTE=''
  CNTOOLS_WALLET_REGISTER_DEPOSIT="${CNTOOLS_POOL_REG_POOL_DEPOSIT}"
  [[ "${CNTOOLS_WALLET_REGISTER_OPERATION}" == pool-register ]] || return 0
  # Hardware pool modes do not support mixed registration/delegation certificates.
  # Public-only packages cannot predict which hardware signer will be chosen later.
  # The review shows why stake setup stays separate.
  for source in "${CNTOOLS_POOL_REG_COLD_SOURCE}" "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}"; do
    [[ -n "${source}" ]] || { CNTOOLS_POOL_STAKE_SETUP_NOTE='Separate · offline/public-only pool: use Wallet → Register and Funds → Delegate'; return 0; }
  done
  while IFS= read -r record; do
    source="$(jq -r .source <<< "${record}")"
    if ! cntools_transaction_source_kind_into kind "${source}" || [[ "${kind}" == hardware ]]; then
      CNTOOLS_POOL_STAKE_SETUP_NOTE='Separate · hardware/public-only stake keys: use Wallet → Register and Funds → Delegate'; return 0
    fi
  done < <(cntools_pool_stake_records | jq -c '.[]')
  for source in "${CNTOOLS_POOL_REG_COLD_SOURCE}" "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}"; do
    cntools_transaction_source_kind_into kind "${source}" && [[ "${kind}" == cli ]] || {
      CNTOOLS_POOL_STAKE_SETUP_NOTE='Separate · hardware pool: use Wallet → Register and Funds → Delegate'; return 0;
    }
  done
  cntools_wallet_query_json_uint_field deposit "${CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE}" stakeAddressDeposit || return 2
  primary="$(jq -r '.[0].hash' <<< "${CNTOOLS_POOL_REG_OWNERS}")"
  while IFS= read -r record; do
    hash="$(jq -r .hash <<< "${record}")"; status="${CNTOOLS_POOL_STAKE_STATUS[${hash}]:-unknown}"
    [[ "${hash}" == "${primary}" || "${hash}" == "${CNTOOLS_POOL_REG_REWARD_HASH}" ]] || continue
    [[ "${status}" != unknown ]] || continue
    choice=''
    if [[ "${hash}" == "${primary}" ]]; then
      if cntools_pool_stake_delegated_here "${hash}"; then
        cntools_transaction_log POOL "Main owner=${hash} already delegated to this pool; no stake setup included"
        continue
      fi
      CNTOOLS_POOL_STAKE_SETUP_ASKABLE=Y; title='Include main-owner stake setup?'
      remembered="${CNTOOLS_POOL_STAKE_SETUP_CHOSEN[delegate:${hash}]:-}"
      if [[ "${mode}" != ask ]] && cntools_flow_quick; then
        choice="${remembered:-Register if needed and delegate to this pool}"
        cntools_transaction_log CHOICE "Pool menu=${title} default=${choice} flow=quick$([[ -z "${remembered}" ]] || printf ' remembered')"
      else
        cntools_ui_render_status info "Main owner: $(jq -r .label <<< "${record}"). Stake registration (if needed) and delegation can be included atomically with pool registration."
        cntools_pool_registration_choose choice "${title}" 'Register if needed and delegate to this pool' 'Keep stake setup separate' || return $?
        CNTOOLS_POOL_STAKE_SETUP_CHOSEN["delegate:${hash}"]="${choice}"
      fi
      [[ "${choice}" == 'Register if needed and delegate to this pool' ]] || continue
      kind=delegate
    elif [[ "${status}" == no ]]; then
      CNTOOLS_POOL_STAKE_SETUP_ASKABLE=Y; title="Register reward account? Deposit $(cntools_number_format_lovelace "${deposit}")"
      remembered="${CNTOOLS_POOL_STAKE_SETUP_CHOSEN[register:${hash}]:-}"
      if [[ "${mode}" != ask ]] && cntools_flow_quick; then
        choice="${remembered:-Include reward registration}"
        cntools_transaction_log CHOICE "Pool menu=${title} default=${choice} flow=quick$([[ -z "${remembered}" ]] || printf ' remembered')"
      else
        cntools_pool_registration_choose choice "${title}" 'Include reward registration' 'Keep reward registration separate' || return $?
        CNTOOLS_POOL_STAKE_SETUP_CHOSEN["register:${hash}"]="${choice}"
      fi
      [[ "${choice}" == 'Include reward registration' ]] || continue
      kind=register
    else continue; fi
    record="$(jq -c --arg kind "${kind}" --arg state "${status}" --arg delegated "${CNTOOLS_POOL_STAKE_DELEGATION[${hash}]:-}" \
      --arg deposit "$([[ "${status}" == no ]] && printf '%s' "${deposit}" || printf 0)" \
      '.+{setup:$kind,previousRegistered:$state,previousDelegation:$delegated,deposit:$deposit}' <<< "${record}")" || return 2
    plan="$(jq -c --argjson record "${record}" '.+[$record]' <<< "${plan}")" || return 2
    [[ "${status}" != no ]] || cntools_uint_add_into CNTOOLS_WALLET_REGISTER_DEPOSIT "${CNTOOLS_WALLET_REGISTER_DEPOSIT}" "${deposit}" || return 2
  done < <(cntools_pool_stake_records | jq -c --arg primary "${primary}" 'sort_by(if .hash == $primary then 0 else 1 end) | .[]')
  CNTOOLS_POOL_STAKE_PLAN="${plan}"
}

# Review → Change stake setup: Esc keeps the plan the review showed.
cntools_pool_stake_setup_change() {
  local status=0 plan="${CNTOOLS_POOL_STAKE_PLAN}" saved_records="${CNTOOLS_POOL_EXTRA_RECORDS}" expected="${CNTOOLS_POOL_EXTRA_EXPECTED}"
  local askable="${CNTOOLS_POOL_STAKE_SETUP_ASKABLE}" note="${CNTOOLS_POOL_STAKE_SETUP_NOTE}" deposit="${CNTOOLS_WALLET_REGISTER_DEPOSIT}"
  local -a certificates=("${CNTOOLS_POOL_EXTRA_CERTIFICATES[@]}")
  local -A chosen=()
  local key=''
  for key in "${!CNTOOLS_POOL_STAKE_SETUP_CHOSEN[@]}"; do chosen["${key}"]="${CNTOOLS_POOL_STAKE_SETUP_CHOSEN[${key}]}"; done
  cntools_pool_stake_setup_choose ask || status=$?
  ((status == 1)) || return "${status}"
  CNTOOLS_POOL_STAKE_SETUP_CHOSEN=()
  for key in "${!chosen[@]}"; do CNTOOLS_POOL_STAKE_SETUP_CHOSEN["${key}"]="${chosen[${key}]}"; done
  CNTOOLS_POOL_STAKE_PLAN="${plan}" CNTOOLS_POOL_EXTRA_RECORDS="${saved_records}" CNTOOLS_POOL_EXTRA_EXPECTED="${expected}"
  CNTOOLS_POOL_STAKE_SETUP_ASKABLE="${askable}" CNTOOLS_POOL_STAKE_SETUP_NOTE="${note}" CNTOOLS_WALLET_REGISTER_DEPOSIT="${deposit}"
  CNTOOLS_POOL_EXTRA_CERTIFICATES=("${certificates[@]}")
  cntools_transaction_log CHOICE 'Pool stake setup change cancelled; previous plan kept'
}

cntools_pool_stake_certificates_create() {
  local record='' certificate='' command='' deposit='' hash='' expected='' kind=''
  local -a args=()
  CNTOOLS_POOL_EXTRA_CERTIFICATES=(); CNTOOLS_POOL_EXTRA_EXPECTED='[]'; CNTOOLS_POOL_EXTRA_RECORDS="${CNTOOLS_POOL_STAKE_PLAN}"
  while IFS= read -r record; do
    hash="$(jq -r .hash <<< "${record}")"; deposit="$(jq -r .deposit <<< "${record}")"; args=()
    if [[ "$(jq -r .setup <<< "${record}")" == delegate ]]; then
      command=stake-delegation-certificate; kind='Stake address delegation'
      args+=(--stake-pool-id "${CNTOOLS_POOL_REG_ID}")
      if [[ "$(jq -r .previousRegistered <<< "${record}")" == no ]]; then
        command=registration-and-delegation-certificate; kind='Stake address registration and delegation'; args+=(--key-reg-deposit-amt "${deposit}")
      fi
      expected="$(jq -cn --arg hash "${hash}" --arg pool "${CNTOOLS_POOL_REG_HEX}" '{"stake credential":{keyHash:$hash},delegatee:{"delegatee type":"stake","key hash":$pool}}')"
    else
      command=registration-certificate; kind='Stake address registration'; args+=(--key-reg-deposit-amt "${deposit}")
      expected="$(jq -cn --arg hash "${hash}" '{"stake credential":{keyHash:$hash}}')"
    fi
    if [[ "$(jq -r .previousRegistered <<< "${record}")" == no ]]; then expected="$(jq -c --argjson deposit "${deposit}" '.+{deposit:$deposit}' <<< "${expected}")"; fi
    expected="$(jq -cn --arg kind "${kind}" --argjson expected "${expected}" '{($kind):$expected}')"
    cntools_transaction_temp_file certificate pool-stake-setup || return 1
    cntools_pool_cli latest stake-address "${command}" --stake-verification-key-file "$(jq -r .vkey <<< "${record}")" \
      "${args[@]}" --out-file "${certificate}" || return 1
    CNTOOLS_POOL_EXTRA_CERTIFICATES+=("${certificate}")
    CNTOOLS_POOL_EXTRA_EXPECTED="$(jq -c --argjson expected "${expected}" '.+[$expected]' <<< "${CNTOOLS_POOL_EXTRA_EXPECTED}")" || return 1
  done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_STAKE_PLAN}")
}

cntools_pool_stake_recheck() {
  local record='' hash=''
  [[ "${CNTOOLS_POOL_STAKE_PLAN}" != '[]' ]] || return 0
  cntools_pool_stake_collect || return 1
  while IFS= read -r record; do
    hash="$(jq -r .hash <<< "${record}")"
    [[ "${CNTOOLS_POOL_STAKE_STATUS[${hash}]:-unknown}" == "$(jq -r .previousRegistered <<< "${record}")" &&
      "${CNTOOLS_POOL_STAKE_DELEGATION[${hash}]:-}" == "$(jq -r .previousDelegation <<< "${record}")" ]] || {
      CNTOOLS_POOL_REG_RECHECK_CHANGED=Y
      cntools_wallet_register_set_error 'Owner/reward registration or delegation changed. Rebuild and review the pool transaction.'; return 1;
    }
  done < <(jq -c '.[]' <<< "${CNTOOLS_POOL_STAKE_PLAN}")
}
