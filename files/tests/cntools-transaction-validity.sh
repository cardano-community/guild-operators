#!/usr/bin/env bash
# Shared expiry choices, unbounded validity, and action rechecks. No network.
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { printf 'SKIP: Bash 4.4+ required\n'; exit 0; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
for lib in number transaction transaction-ui funds-send funds-send-ui funds-withdraw; do . "${CNTOOLS_ROOT}/lib/${lib}.sh"; done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$3: $1 != $2"; }
cntools_transaction_log() { :; }
cntools_ui_choose() {
  eq "$2" 'Transaction expiry' 'shared choice'
  eq "$*" "$1 Transaction expiry 30 minutes 2 hours 24 hours (offline signing) No expiry Cancel" 'expiry menu options'
  printf -v "$1" '%s' "${CHOICE}"
}
for CHOICE in '30 minutes' '2 hours' '24 hours (offline signing)' 'No expiry'; do
  cntools_transaction_ui_expiry_into lifetime
  case "${CHOICE}" in
    '30 minutes') expected=2800 ;; '2 hours') expected=8200 ;;
    '24 hours (offline signing)') expected=87400 ;; *) expected='' ;;
  esac
  cntools_transaction_expiry_into expiry 1000 "${lifetime}"
  eq "${expiry}" "${expected}" 'expiry slot'
  cntools_transaction_plan_reset Test '' exact
  cntools_transaction_plan_set_validity '' "${expiry}"
  eq "${CNTOOLS_TRANSACTION_PLAN_INVALID_HEREAFTER}" "${expected}" 'plan validity'
done
CHOICE=Cancel
if cntools_transaction_ui_expiry_into lifetime; then fail 'cancel accepted'; fi
for bad in -1 01 abc 60; do
  if cntools_transaction_expiry_into expiry 1000 "${bad}"; then fail 'invalid lifetime accepted'; fi
done
cntools_transaction_expiry_into expiry '' 0 || fail 'unbounded validity requires tip'
eq "${expiry}" '' 'unbounded is not slot zero'
cntools_transaction_ui_expiry_label_into label ''
eq "${label}" 'No expiry' 'unbounded display'

CNTOOLS_SEND_ADDRESS=base CNTOOLS_SEND_PAYMENT=payment
CNTOOLS_STAKE_BASE_ADDRESS=base CNTOOLS_STAKE_PAYMENT_ADDRESS=payment
CNTOOLS_WITHDRAW_REWARDS=10
CNTOOLS_COIN_SELECTED_REFS=(input) CNTOOLS_WITHDRAW_INPUTS=(input)
declare -A CNTOOLS_UTXO_INDEX_BY_REF=([input]=0)
cntools_funding_collect() { CNTOOLS_FUNDING_SLOT=1000; CNTOOLS_FUNDING_BACKEND=local; }
cntools_send_recheck_handles() { :; }
cntools_send_build_into() { printf -v "$1" '%s' send; }
cntools_withdraw_collect() { CNTOOLS_FUNDING_SLOT=1000; }
cntools_withdraw_query_stake() { CNTOOLS_WALLET_REWARD_LOVELACE=10; }
cntools_withdraw_build_into() { printf -v "$1" '%s' withdraw; }
for lifetime in 0 1800 7200 86400; do
  expected=''; (( lifetime == 0 )) || expected=$((1000+lifetime))
  cntools_send_refresh_build_into package "${lifetime}"
  eq "${CNTOOLS_SEND_EXPIRY}" "${expected}" 'Send bound'
  cntools_send_recheck || fail 'Send expired unexpectedly'
  cntools_withdraw_refresh_build_into package "${lifetime}"
  eq "${CNTOOLS_WITHDRAW_EXPIRY}" "${expected}" 'withdrawal bound'
  cntools_withdraw_recheck || fail 'withdrawal expired unexpectedly'
done
CNTOOLS_SEND_EXPIRY=999 CNTOOLS_WITHDRAW_EXPIRY=999
if cntools_send_recheck; then fail 'expired Send accepted'; fi
if cntools_withdraw_recheck; then fail 'expired withdrawal accepted'; fi
CNTOOLS_SEND_EXPIRY='' CNTOOLS_WITHDRAW_EXPIRY=''
CNTOOLS_UTXO_INDEX_BY_REF=()
if cntools_send_recheck; then fail 'unbounded Send skipped input check'; fi
if cntools_withdraw_recheck; then fail 'unbounded withdrawal skipped input check'; fi
printf 'CNTools transaction validity tests passed.\n'
