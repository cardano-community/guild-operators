#!/usr/bin/env bash
# Script-DRep authorization, independent of the payment wallet's authority.
# shellcheck disable=SC2034
CNTOOLS_MULTISIG_DREP_SCRIPT='' CNTOOLS_MULTISIG_DREP_AFTER='' CNTOOLS_MULTISIG_DREP_BEFORE='' CNTOOLS_MULTISIG_DREP_THRESHOLD=0
declare -ag CNTOOLS_MULTISIG_DREP_IDS=() CNTOOLS_MULTISIG_DREP_HASHES=() CNTOOLS_MULTISIG_DREP_SOURCES=() CNTOOLS_MULTISIG_DREP_LABELS=()

cntools_multisig_drep_prepare() {
  local directory="$1" bounds='' hash=''
  cntools_transaction_snapshot_into CNTOOLS_MULTISIG_DREP_SCRIPT "${directory}/${CNTOOLS_WALLET_DREP_SCRIPT_FILENAME:-drep.script}" 262144 multisig-drep || return 1
  cntools_transaction_native_script_hash_into hash "${CNTOOLS_MULTISIG_DREP_SCRIPT}" || return 1
  [[ "${hash}" == "${CNTOOLS_DREP_LIFECYCLE_HASH}" ]] || {
    cntools_transaction_set_error 'The DRep script changed after identity verification.'; return 1;
  }
  cntools_multisig_script_threshold_into bounds "${CNTOOLS_MULTISIG_DREP_SCRIPT}" || return 1
  IFS=$'\037' read -r CNTOOLS_MULTISIG_DREP_THRESHOLD CNTOOLS_MULTISIG_DREP_AFTER CNTOOLS_MULTISIG_DREP_BEFORE <<< "${bounds}"
  CNTOOLS_MULTISIG_DREP_IDS=(); CNTOOLS_MULTISIG_DREP_HASHES=(); CNTOOLS_MULTISIG_DREP_SOURCES=(); CNTOOLS_MULTISIG_DREP_LABELS=()
}

cntools_multisig_drep_choose_signers() {
  local payment_signable=N drep_signable=N
  if [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE}" == MultiSig ]]; then
    cntools_multisig_spend_choose_signers cntools_wallet_register_begin payment || return $?
    payment_signable="${CNTOOLS_MULTISIG_CAN_SIGN}"
  elif [[ -n "${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE}" ]]; then payment_signable=Y; fi
  if [[ "${CNTOOLS_DREP_LIFECYCLE_KIND}" == script ]]; then
    cntools_multisig_drep_choose_subset || return $?
    drep_signable=Y
    local source=''
    for source in "${CNTOOLS_MULTISIG_DREP_SOURCES[@]}"; do [[ -n "${source}" ]] || drep_signable=N; done
  elif [[ -n "${CNTOOLS_DREP_LIFECYCLE_SOURCE}" ]]; then drep_signable=Y; fi
  CNTOOLS_WALLET_REGISTER_CAN_SIGN=N
  [[ "${payment_signable}:${drep_signable}" != Y:Y ]] || CNTOOLS_WALLET_REGISTER_CAN_SIGN=Y
}

cntools_multisig_drep_choose_subset() {
  # Dynamic locals isolate the shared selector's state, preserving the payment
  # subset even when selection is cancelled. Candidate discovery is role-aware.
  local CNTOOLS_MULTISIG_SPEND_SCRIPT="${CNTOOLS_MULTISIG_DREP_SCRIPT}"
  local CNTOOLS_MULTISIG_SPEND_THRESHOLD="${CNTOOLS_MULTISIG_DREP_THRESHOLD}" CNTOOLS_MULTISIG_CAN_SIGN=N CNTOOLS_MULTISIG_SELECTION_ROLE=drep
  local -a CNTOOLS_MULTISIG_SIGNER_IDS=() CNTOOLS_MULTISIG_SIGNER_HASHES=() CNTOOLS_MULTISIG_SIGNER_SOURCES=() CNTOOLS_MULTISIG_SIGNER_LABELS=()
  cntools_multisig_spend_choose_signers cntools_wallet_register_begin drep || return $?
  CNTOOLS_MULTISIG_DREP_IDS=("${CNTOOLS_MULTISIG_SIGNER_IDS[@]}"); CNTOOLS_MULTISIG_DREP_HASHES=("${CNTOOLS_MULTISIG_SIGNER_HASHES[@]}")
  CNTOOLS_MULTISIG_DREP_SOURCES=("${CNTOOLS_MULTISIG_SIGNER_SOURCES[@]}"); CNTOOLS_MULTISIG_DREP_LABELS=("${CNTOOLS_MULTISIG_SIGNER_LABELS[@]}")
}

cntools_multisig_drep_validity() {
  local -n md_expiry="$1"
  local slot="$2" lower='' upper="${md_expiry}" bound=''
  local -a starts=() ends=()
  if [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE}" == MultiSig ]]; then starts+=("${CNTOOLS_MULTISIG_SPEND_AFTER}"); ends+=("${CNTOOLS_MULTISIG_SPEND_BEFORE}"); fi
  if [[ "${CNTOOLS_DREP_LIFECYCLE_KIND}" == script ]]; then starts+=("${CNTOOLS_MULTISIG_DREP_AFTER}"); ends+=("${CNTOOLS_MULTISIG_DREP_BEFORE}"); fi
  for bound in "${starts[@]}"; do [[ -n "${bound}" ]] || continue; [[ -n "${lower}" ]] && ((lower>=bound)) || lower="${bound}"; done
  for bound in "${ends[@]}"; do [[ -n "${bound}" ]] || continue; [[ -n "${upper}" ]] && ((upper<=bound)) || upper="${bound}"; done
  [[ "${slot}" =~ ^(0|[1-9][0-9]{0,15})$ ]] || return 2
  if [[ -n "${lower}" ]] && ((slot<lower)); then cntools_transaction_set_error 'A payment or DRep script is not valid yet.'; return 1; fi
  if [[ -n "${upper}" ]] && ((slot>=upper)); then cntools_transaction_set_error 'The transaction or a payment/DRep script has expired.'; return 1; fi
  cntools_transaction_plan_set_validity "${lower}" "${upper}" || return 1
  md_expiry="${upper}"
}

cntools_multisig_drep_add_plan() {
  local purpose="$1" script="$2" ids_name="$3" hashes_name="$4" sources_name="$5" labels_name="$6" index=0 source='' kind=''
  local -n md_ids="${ids_name}" md_hashes="${hashes_name}" md_sources="${sources_name}" md_labels="${labels_name}"
  for index in "${!md_ids[@]}"; do
    source="${md_sources[index]}"; kind=either
    if [[ -n "${source}" ]]; then
      cntools_transaction_source_kind_into kind "${source}" || return 1
      CNTOOLS_TRANSACTION_RUNTIME_SOURCES["${md_ids[index]}"]="${source}"; CNTOOLS_TRANSACTION_RUNTIME_SOURCE_KINDS["${md_ids[index]}"]="${kind}"
    fi
    cntools_transaction_plan_add_public_signer "${md_labels[index]}" "$([[ "${purpose}" == spend ]] && printf spending || printf '%s' "${purpose}")" \
      "${md_ids[index]}" "${md_hashes[index]}" "${kind}" || return 1
  done
  # The shared script validator enforces the selected subset and mandatory
  # interval, deduplicates witnesses and binds the embedded script to the body.
  cntools_transaction_plan_add_native_script "${CNTOOLS_WALLET_REGISTER_WALLET} ${purpose} script" "${purpose}" "${script}" "${md_ids[@]}"
}
