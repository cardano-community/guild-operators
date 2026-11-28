#!/usr/bin/env bash
# Choosing the wallet that pays for a stake action (lib/stake-funding.sh):
# first when the stake wallet cannot pay, and from the review.
# shellcheck disable=SC2034

CNTOOLS_STAKE_FUNDING_ERROR=''
declare -ag CNTOOLS_STAKE_FUNDING_SAVED=()

# The other wallets the funding picker would offer, not counting the stake
# wallet and SKIPPED: their count and the last one's name.
# Usage: cntools_stake_funding_others_into COUNT NAME CONTEXT STAKE_DIRECTORY [SKIPPED…]
cntools_stake_funding_others_into() {
  local -n sfo_count="$1" sfo_name="$2"
  local sfo_context="$3" sfo_stake="$4" sfo_index=0 sfo_note='' sfo_tried=''
  shift 4
  sfo_count=0 sfo_name=''
  for sfo_index in "${!CNTOOLS_WALLET_PATHS[@]}"; do
    [[ "${CNTOOLS_WALLET_PATHS[sfo_index]}" != "${sfo_stake}" ]] || continue
    for sfo_tried in "$@"; do [[ "${sfo_tried}" != "${CNTOOLS_WALLET_PATHS[sfo_index]}" ]] || continue 2; done
    cntools_wallet_selection_candidate_into sfo_note "${sfo_index}" "${sfo_context}" || continue
    sfo_count=$((sfo_count + 1)) sfo_name="${CNTOOLS_WALLET_NAMES[sfo_index]}"
  done
}

# Why no other wallet can pay, for the stake wallet NAME of STAKE_TYPE.
cntools_stake_funding_none_into() {
  local -n sfn_message="$1"
  sfn_message="No other wallet can pay for $2: a CLI or mnemonic wallet with a payment key and funds is needed"
  [[ "$3" != Hardware ]] || sfn_message+=', or a hardware wallet on the same Ledger'
  sfn_message+='.'
}

# Runs COLLECT (which applies the current funding) under a spinner. Its
# status is returned; CNTOOLS_STAKE_FUNDING_ERROR names why it failed.
cntools_stake_funding_collect() {
  local sfcl_title="$1" sfcl_status=0
  shift
  CNTOOLS_STAKE_FUNDING_ERROR='' CNTOOLS_WALLET_REGISTER_ERROR=''
  cntools_transaction_clear_error
  cntools_ui_spin_function "${sfcl_title}" "$@" || sfcl_status=$?
  CNTOOLS_STAKE_FUNDING_ERROR="${CNTOOLS_WALLET_REGISTER_ERROR:-${CNTOOLS_TRANSACTION_ERROR:-}}"
  return "${sfcl_status}"
}

# Why the wallet NAME cannot pay, from a collect status: 5 no spendable UTxOs,
# 9 not enough for NEED (the fee and any deposit).
cntools_stake_funding_short_into() {
  local -n sfsh_message="$1"
  local sfsh_name="$2" sfsh_status="$3" sfsh_need="$4"
  if (( sfsh_status == 5 )); then
    sfsh_message="${sfsh_name} has no spendable UTxOs to pay ${sfsh_need}."
  else
    sfsh_message="${sfsh_name} cannot cover ${sfsh_need}. ${CNTOOLS_STAKE_FUNDING_ERROR:-}"
    sfsh_message="${sfsh_message% }"
  fi
}

# The stake wallet cannot pay: REASON 10 (no payment key), 5 (no spendable
# UTxOs) or 9 (too little for NEED). Chooses the wallet that pays and checks
# its funds at once with COLLECT; GETS is what it receives (the change, and
# any rewards or refund). A wallet that cannot pay is named and another
# offered while one is left (a lone one is used at once). 0: a wallet pays and
# COLLECT succeeded; 3: none can pay (shown and acknowledged); 1/130 cancel;
# other: COLLECT's status (its error in CNTOOLS_STAKE_FUNDING_ERROR).
# Usage: cntools_stake_funding_choose REASON STAKE_DIRECTORY STAKE_NAME STAKE_TYPE PURPOSE NEED GETS BEGIN COLLECT…
cntools_stake_funding_choose() {
  local sfch_reason="$1" sfch_directory="$2" sfch_name="$3" sfch_type="$4" sfch_purpose="$5" sfch_need="$6" sfch_gets="$7" sfch_begin="$8"
  local sfch_context='' sfch_selected='' sfch_status=0 sfch_others=0 sfch_next='' sfch_problem='' sfch_message='' sfch_funder=''
  local -a sfch_skipped=()
  shift 8
  cntools_stake_funding_context_into sfch_context "${sfch_type}"
  # PROBLEM is why the last wallet cannot pay; MESSAGE adds what happens next.
  if [[ "${sfch_reason}" == 10 ]]; then
    sfch_problem="${sfch_name} has no payment key."
    sfch_message="${sfch_name} has no payment key, so another wallet pays ${sfch_need} and receives ${sfch_gets}."
  else
    cntools_stake_funding_short_into sfch_problem "${sfch_name}" "${sfch_reason}" "${sfch_need}"
    sfch_message="${sfch_problem} Another wallet can pay for it."
  fi
  cntools_transaction_log CHOICE "Stake funding needed wallet=${sfch_name} reason=${sfch_reason}"
  while true; do
    cntools_stake_funding_others_into sfch_others sfch_next "${sfch_context}" "${sfch_directory}" "${sfch_skipped[@]}"
    "${sfch_begin}" || return 2
    if (( sfch_others == 0 )); then
      cntools_ui_render_status warn "${sfch_problem}"
      cntools_stake_funding_none_into sfch_message "${sfch_name}" "${sfch_type}"
      cntools_ui_render_status info "${sfch_message}"
      cntools_ui_wait; return 3
    fi
    if [[ "${sfch_reason}" == 10 && ${#sfch_skipped[@]} -eq 0 ]]; then cntools_ui_render_status info "${sfch_message}"
    else cntools_ui_render_status warn "${sfch_message}"; fi
    CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS=("${sfch_directory}" "${sfch_skipped[@]}")
    sfch_status=0
    cntools_wallet_choose sfch_selected "${sfch_purpose}" Cancel "${sfch_context}" || sfch_status=$?
    CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS=()
    (( sfch_status == 0 )) || return "${sfch_status}"
    sfch_funder="${CNTOOLS_WALLET_NAMES[sfch_selected]}"
    if ! cntools_stake_funding_prepare "${CNTOOLS_WALLET_PATHS[sfch_selected]}" "${sfch_funder}" "${sfch_type}"; then
      cntools_stake_funding_reset
      sfch_skipped+=("${CNTOOLS_WALLET_PATHS[sfch_selected]}")
      sfch_problem="${CNTOOLS_TRANSACTION_ERROR:-${sfch_funder} cannot pay for this action.}" sfch_message="${sfch_problem}"
      continue
    fi
    if [[ "${CNTOOLS_STAKE_FUNDING_TYPE}" == Hardware ]]; then
      cntools_transaction_require_hwcli || { CNTOOLS_STAKE_FUNDING_ERROR="${CNTOOLS_TRANSACTION_ERROR}"; return 2; }
    fi
    sfch_status=0
    cntools_stake_funding_collect "Checking the funds of ${sfch_funder}…" "$@" || sfch_status=$?
    (( sfch_status != 0 )) || {
      cntools_transaction_log CHOICE "Stake funding wallet=${sfch_funder} pays for wallet=${sfch_name}"; return 0;
    }
    (( sfch_status == 5 || sfch_status == 9 )) || return "${sfch_status}"
    cntools_transaction_log CHOICE "Stake funding wallet=${sfch_funder} cannot pay status=${sfch_status}"
    cntools_stake_funding_reset
    sfch_skipped+=("${CNTOOLS_WALLET_PATHS[sfch_selected]}")
    cntools_stake_funding_short_into sfch_problem "${sfch_funder}" "${sfch_status}" "${sfch_need}"
    sfch_message="${sfch_problem}"
    cntools_stake_funding_others_into sfch_others sfch_next "${sfch_context}" "${sfch_directory}" "${sfch_skipped[@]}"
    if (( sfch_others == 1 )); then sfch_message+=" Using ${sfch_next} instead."
    elif (( sfch_others > 1 )); then sfch_message+=' Choose another wallet.'; fi
  done
}

cntools_stake_funding_save() {
  local sfsv_name=''
  CNTOOLS_STAKE_FUNDING_SAVED=()
  for sfsv_name in "${CNTOOLS_STAKE_FUNDING_STATE[@]}"; do CNTOOLS_STAKE_FUNDING_SAVED+=("${sfsv_name}" "${!sfsv_name-}"); done
}

cntools_stake_funding_restore() {
  local sfrs_index=0
  for (( sfrs_index = 0; sfrs_index + 1 < ${#CNTOOLS_STAKE_FUNDING_SAVED[@]}; sfrs_index += 2 )); do
    printf -v "${CNTOOLS_STAKE_FUNDING_SAVED[sfrs_index]}" '%s' "${CNTOOLS_STAKE_FUNDING_SAVED[sfrs_index+1]}"
  done
}

# Review 'Change funding wallet'. While another wallet pays, the stake wallet
# itself is offered again when it is a CLI, mnemonic or hardware wallet with
# a payment key. The new wallet's funds are checked at once with COLLECT; one that
# cannot pay is named and the reviewed one kept. 0: changed and collected
# (the caller rebuilds); 1: unchanged; 2: the reviewed funding could not be
# restored. Why the funding is kept is the review's one-shot notice, since
# the review redraws at once.
# Usage: cntools_stake_funding_change STAKE_DIRECTORY STAKE_NAME STAKE_TYPE PURPOSE NEED BEGIN COLLECT…
cntools_stake_funding_change() {
  local sfcg_directory="$1" sfcg_name="$2" sfcg_type="$3" sfcg_purpose="$4" sfcg_need="$5" sfcg_begin="$6"
  local sfcg_context='' sfcg_selected='' sfcg_status=0 sfcg_others=0 sfcg_next='' sfcg_message='' sfcg_payer=''
  local -a sfcg_exclude=()
  shift 6
  cntools_stake_funding_context_into sfcg_context "${sfcg_type}"
  # The stake wallet pays for itself only with its own payment key.
  [[ "${CNTOOLS_STAKE_HAS_PAYMENT:-Y}" == Y && "${sfcg_type}" != MultiSig ]] && cntools_stake_funding_external ||
    sfcg_exclude+=("${sfcg_directory}")
  ! cntools_stake_funding_external || sfcg_exclude+=("${CNTOOLS_STAKE_FUNDING_DIRECTORY}")
  sfcg_others=0
  for sfcg_selected in "${!CNTOOLS_WALLET_PATHS[@]}"; do
    for sfcg_next in "${sfcg_exclude[@]}"; do [[ "${sfcg_next}" != "${CNTOOLS_WALLET_PATHS[sfcg_selected]}" ]] || continue 2; done
    cntools_wallet_selection_candidate_into sfcg_message "${sfcg_selected}" "${sfcg_context}" || continue
    sfcg_others=$((sfcg_others + 1))
  done
  if (( sfcg_others == 0 )); then
    cntools_stake_funding_none_into sfcg_message "${sfcg_name}" "${sfcg_type}"
    CNTOOLS_TRANSACTION_UI_NOTICE="${sfcg_message} The reviewed funding is kept."
    return 1
  fi
  CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS=("${sfcg_exclude[@]}")
  sfcg_status=0
  cntools_wallet_choose sfcg_selected "${sfcg_purpose}" Cancel "${sfcg_context}" N || sfcg_status=$?
  CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS=()
  (( sfcg_status != 3 )) || return 1
  (( sfcg_status == 0 )) || return "${sfcg_status}"
  cntools_stake_funding_save
  sfcg_payer="${CNTOOLS_WALLET_NAMES[sfcg_selected]}"
  if [[ "${CNTOOLS_WALLET_PATHS[sfcg_selected]}" == "${sfcg_directory}" ]]; then
    cntools_stake_funding_reset
  elif ! cntools_stake_funding_prepare "${CNTOOLS_WALLET_PATHS[sfcg_selected]}" "${sfcg_payer}" "${sfcg_type}"; then
    cntools_stake_funding_restore
    CNTOOLS_TRANSACTION_UI_NOTICE="${CNTOOLS_TRANSACTION_ERROR:-${sfcg_payer} cannot pay for this action.} The reviewed funding is kept."
    return 1
  elif [[ "${CNTOOLS_STAKE_FUNDING_TYPE}" == Hardware ]] && ! cntools_transaction_require_hwcli; then
    cntools_stake_funding_restore
    CNTOOLS_TRANSACTION_UI_NOTICE="${CNTOOLS_TRANSACTION_ERROR} The reviewed funding is kept."
    return 1
  fi
  sfcg_status=0
  cntools_stake_funding_collect "Checking the funds of ${sfcg_payer}…" "$@" || sfcg_status=$?
  if (( sfcg_status == 0 )); then
    cntools_transaction_log CHOICE "Stake funding changed wallet=${sfcg_payer} external=${CNTOOLS_STAKE_FUNDING_EXTERNAL}"
    return 0
  fi
  if (( sfcg_status == 5 || sfcg_status == 9 )); then
    cntools_stake_funding_short_into sfcg_message "${sfcg_payer}" "${sfcg_status}" "${sfcg_need}"
  else
    sfcg_message="${CNTOOLS_STAKE_FUNDING_ERROR:-The funds of ${sfcg_payer} could not be checked.}"
  fi
  cntools_stake_funding_restore
  cntools_stake_funding_collect 'Restoring the reviewed funding…' "$@" || return 2
  cntools_transaction_log CHOICE "Stake funding unchanged: wallet=${sfcg_payer} status=${sfcg_status}"
  CNTOOLS_TRANSACTION_UI_NOTICE="${sfcg_message} The reviewed funding is kept."
  return 1
}

# After the funding changed: CAN_SIGN may differ, and the workflow follows,
# as after a signer change: unsigned only, or (Quick) the default workflow.
# Usage: cntools_stake_funding_workflow_into WORKFLOW WAS_SIGNABLE NOW_SIGNABLE LIFETIME
cntools_stake_funding_workflow_into() {
  local -n sfw_workflow="$1"
  local sfw_was="$2" sfw_now="$3"
  [[ "${sfw_now}" != "${sfw_was}" ]] || return 0
  if [[ "${sfw_now}" != Y ]]; then
    cntools_transaction_ui_workflow_into "$1" N || return 2
    cntools_transaction_ui_unsigned_lifetime_into "$4" "${sfw_workflow}" || true
  else
    CNTOOLS_TRANSACTION_UI_WORKFLOW_FIXED=N
    if cntools_flow_quick; then cntools_transaction_ui_initial_workflow_into "$1" Y || return 2; fi
  fi
  cntools_transaction_log CHOICE "Stake funding changed can_sign=${sfw_now} workflow=${sfw_workflow}"
}

# Review rows naming who signs for and who pays for the stake wallet.
cntools_stake_funding_render_rows() {
  if cntools_stake_funding_external; then
    cntools_transaction_ui_styled_row 'Stake wallet' "$1" identifier
    cntools_transaction_ui_styled_row 'Funding wallet' "${CNTOOLS_STAKE_FUNDING_WALLET}" identifier
  else
    cntools_transaction_ui_styled_row Wallet "$1" identifier
  fi
}

# Two hardware wallets sign in one Ledger session, so both must be on it.
cntools_stake_funding_hardware_notice() {
  [[ "$1" == Hardware && "${CNTOOLS_STAKE_FUNDING_TYPE}" == Hardware ]] && cntools_stake_funding_external || return 0
  cntools_ui_render_status info "${CNTOOLS_STAKE_FUNDING_WALLET} and $2 sign in one Ledger session, so both must be on the same device. A different device stops at signing with a public key mismatch."
}
