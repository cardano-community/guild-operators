#!/usr/bin/env bash
# Threshold-script payment + stake identities for the ordinary stake workflows.
# Own the two selected subsets; reuse the shared public signer/package contract.
# shellcheck disable=SC2034
CNTOOLS_MULTISIG_STAKE_SCRIPT='' CNTOOLS_MULTISIG_STAKE_AFTER='' CNTOOLS_MULTISIG_STAKE_BEFORE=''
CNTOOLS_MULTISIG_STAKE_THRESHOLD=0 CNTOOLS_MULTISIG_STAKE_SLOT=''
declare -ag CNTOOLS_MULTISIG_STAKE_SIGNER_IDS=() CNTOOLS_MULTISIG_STAKE_SIGNER_HASHES=() CNTOOLS_MULTISIG_STAKE_SIGNER_SOURCES=() CNTOOLS_MULTISIG_STAKE_SIGNER_LABELS=()

cntools_multisig_stake_prepare() {
  local directory="$1" name="$2" bounds='' output='' errors='' actual=''
  local -a network=()
  # A stake-only multisig wallet (a stake script without a payment script) has
  # no script address to spend from: a funding wallet pays for it.
  CNTOOLS_STAKE_HAS_PAYMENT=Y CNTOOLS_STAKE_BASE_ADDRESS='' CNTOOLS_PAYMENT_PAYMENT='' CNTOOLS_PAYMENT_CREDENTIAL=''
  [[ -e "${directory}/${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}" || -L "${directory}/${CNTOOLS_WALLET_PAY_SCRIPT_FILENAME}" ]] || CNTOOLS_STAKE_HAS_PAYMENT=N
  if [[ "${CNTOOLS_STAKE_HAS_PAYMENT}" == Y ]]; then
    cntools_multisig_spend_prepare "${directory}" || return 1
    cntools_wallet_read_address "${directory}" base CNTOOLS_STAKE_BASE_ADDRESS || {
      cntools_transaction_set_error 'This action needs a complete multisig payment and stake-script wallet.'; return 1;
    }
  else
    CNTOOLS_MULTISIG_SPEND_SCRIPT='' CNTOOLS_MULTISIG_SPEND_THRESHOLD=0 CNTOOLS_MULTISIG_SPEND_AFTER='' CNTOOLS_MULTISIG_SPEND_BEFORE=''
    CNTOOLS_MULTISIG_SIGNER_IDS=(); CNTOOLS_MULTISIG_SIGNER_HASHES=(); CNTOOLS_MULTISIG_SIGNER_SOURCES=(); CNTOOLS_MULTISIG_SIGNER_LABELS=()
    CNTOOLS_MULTISIG_CAN_SIGN=N CNTOOLS_MULTISIG_SIGNERS_CHOICE=N
  fi
  cntools_wallet_read_address "${directory}" reward CNTOOLS_STAKE_REWARD_ADDRESS || {
    cntools_transaction_set_error 'This action needs a multisig wallet with a stake script and its stake address.'; return 1;
  }
  cntools_transaction_snapshot_into CNTOOLS_MULTISIG_STAKE_SCRIPT "${directory}/${CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME}" 65536 multisig-stake-script || return 1
  cntools_transaction_native_script_valid "${CNTOOLS_MULTISIG_STAKE_SCRIPT}" &&
    cntools_multisig_script_threshold_into bounds "${CNTOOLS_MULTISIG_STAKE_SCRIPT}" || return 1
  IFS=$'\037' read -r CNTOOLS_MULTISIG_STAKE_THRESHOLD CNTOOLS_MULTISIG_STAKE_AFTER CNTOOLS_MULTISIG_STAKE_BEFORE <<< "${bounds}"
  CNTOOLS_MULTISIG_STAKE_SIGNER_IDS=(); CNTOOLS_MULTISIG_STAKE_SIGNER_HASHES=(); CNTOOLS_MULTISIG_STAKE_SIGNER_SOURCES=(); CNTOOLS_MULTISIG_STAKE_SIGNER_LABELS=()
  cntools_transaction_temp_file output multisig-stake-address && cntools_transaction_temp_file errors multisig-stake-errors &&
    cntools_transaction_network_arguments_into network "${CNTOOLS_NETWORK}" || return 1
  cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" latest stake-address build \
    --stake-script-file "${CNTOOLS_MULTISIG_STAKE_SCRIPT}" "${network[@]}" || return 1
  actual="$(< "${output}")"
  [[ "${actual}" == "${CNTOOLS_STAKE_REWARD_ADDRESS}" ]] || {
    cntools_transaction_set_error 'The reward address does not match the frozen stake script.'; return 1;
  }
  if [[ "${CNTOOLS_STAKE_HAS_PAYMENT}" == Y ]]; then
    cntools_transaction_run_cli "${output}" "${errors}" -- "${CNTOOLS_CLI}" address build \
      --payment-script-file "${CNTOOLS_MULTISIG_SPEND_SCRIPT}" --stake-script-file "${CNTOOLS_MULTISIG_STAKE_SCRIPT}" "${network[@]}" || return 1
    [[ "$(< "${output}")" == "${CNTOOLS_STAKE_BASE_ADDRESS}" ]] || {
      cntools_transaction_set_error 'The base address does not match the frozen payment/stake scripts.'; return 1;
    }
  fi
  cntools_transaction_native_script_hash_into CNTOOLS_STAKE_STAKE_CREDENTIAL "${CNTOOLS_MULTISIG_STAKE_SCRIPT}" || return 1
  CNTOOLS_STAKE_PAYMENT_CREDENTIAL="${CNTOOLS_PAYMENT_CREDENTIAL}"
  CNTOOLS_STAKE_PAYMENT_ADDRESS="${CNTOOLS_PAYMENT_PAYMENT}"
  CNTOOLS_STAKE_WALLET="${name}" CNTOOLS_STAKE_WALLET_TYPE=MultiSig CNTOOLS_STAKE_DIRECTORY="${directory}"
  CNTOOLS_STAKE_PAYMENT_VKEY='' CNTOOLS_STAKE_STAKE_VKEY='' CNTOOLS_STAKE_PAYMENT_SOURCE='' CNTOOLS_STAKE_STAKE_SOURCE='' CNTOOLS_STAKE_CAN_SIGN=N
  cntools_transaction_log WALLET "Multisig stake wallet prepared wallet=${name} payment_script=${CNTOOLS_STAKE_HAS_PAYMENT}; participants must be selected"
}

# 0 when a funding wallet pays, so the payment script and its participants
# take no part.
cntools_multisig_stake_external() {
  [[ "${CNTOOLS_STAKE_FUNDING_EXTERNAL:-N}" == Y ]]
}

# Y when every chosen stake participant can sign here, and so can the payer:
# every chosen payment participant, or the funding wallet's key.
cntools_multisig_stake_can_sign_into() {
  local -n mscs_output="$1"
  local mscs_source=''
  mscs_output=N
  (( ${#CNTOOLS_MULTISIG_STAKE_SIGNER_IDS[@]} > 0 )) || return 0
  for mscs_source in "${CNTOOLS_MULTISIG_STAKE_SIGNER_SOURCES[@]}"; do [[ -n "${mscs_source}" ]] || return 0; done
  if cntools_multisig_stake_external; then
    [[ -n "${CNTOOLS_STAKE_FUNDING_PAYMENT_SOURCE:-}" ]] || return 0
  else
    (( ${#CNTOOLS_MULTISIG_SIGNER_IDS[@]} > 0 )) || return 0
    for mscs_source in "${CNTOOLS_MULTISIG_SIGNER_SOURCES[@]}"; do [[ -n "${mscs_source}" ]] || return 0; done
  fi
  mscs_output=Y
}

cntools_multisig_stake_choose_signers() {
  local begin="$1" status=0 payment_signable=N script="${CNTOOLS_MULTISIG_SPEND_SCRIPT}" threshold="${CNTOOLS_MULTISIG_SPEND_THRESHOLD}"
  local -a payment_ids=() payment_hashes=() payment_sources=() payment_labels=()
  if cntools_multisig_stake_external; then
    # The funding wallet's own key pays: no payment participants are asked.
    [[ -z "${CNTOOLS_STAKE_FUNDING_PAYMENT_SOURCE:-}" ]] || payment_signable=Y
  else
    cntools_multisig_spend_choose_signers "${begin}" payment || return $?
    payment_signable="${CNTOOLS_MULTISIG_CAN_SIGN}"
  fi
  payment_ids=("${CNTOOLS_MULTISIG_SIGNER_IDS[@]}"); payment_hashes=("${CNTOOLS_MULTISIG_SIGNER_HASHES[@]}")
  payment_sources=("${CNTOOLS_MULTISIG_SIGNER_SOURCES[@]}"); payment_labels=("${CNTOOLS_MULTISIG_SIGNER_LABELS[@]}")
  CNTOOLS_MULTISIG_SPEND_SCRIPT="${CNTOOLS_MULTISIG_STAKE_SCRIPT}" CNTOOLS_MULTISIG_SPEND_THRESHOLD="${CNTOOLS_MULTISIG_STAKE_THRESHOLD}"
  # The stake menu starts from the current stake selection (none at first).
  CNTOOLS_MULTISIG_SIGNER_IDS=("${CNTOOLS_MULTISIG_STAKE_SIGNER_IDS[@]}"); CNTOOLS_MULTISIG_SIGNER_HASHES=("${CNTOOLS_MULTISIG_STAKE_SIGNER_HASHES[@]}")
  CNTOOLS_MULTISIG_SIGNER_SOURCES=("${CNTOOLS_MULTISIG_STAKE_SIGNER_SOURCES[@]}"); CNTOOLS_MULTISIG_SIGNER_LABELS=("${CNTOOLS_MULTISIG_STAKE_SIGNER_LABELS[@]}")
  cntools_multisig_spend_choose_signers "${begin}" stake || status=$?
  CNTOOLS_MULTISIG_STAKE_SIGNER_IDS=("${CNTOOLS_MULTISIG_SIGNER_IDS[@]}"); CNTOOLS_MULTISIG_STAKE_SIGNER_HASHES=("${CNTOOLS_MULTISIG_SIGNER_HASHES[@]}")
  CNTOOLS_MULTISIG_STAKE_SIGNER_SOURCES=("${CNTOOLS_MULTISIG_SIGNER_SOURCES[@]}"); CNTOOLS_MULTISIG_STAKE_SIGNER_LABELS=("${CNTOOLS_MULTISIG_SIGNER_LABELS[@]}")
  CNTOOLS_STAKE_CAN_SIGN=N
  [[ "${payment_signable}" != Y || "${CNTOOLS_MULTISIG_CAN_SIGN}" != Y ]] || CNTOOLS_STAKE_CAN_SIGN=Y
  CNTOOLS_MULTISIG_CAN_SIGN="${payment_signable}"
  CNTOOLS_MULTISIG_SPEND_SCRIPT="${script}" CNTOOLS_MULTISIG_SPEND_THRESHOLD="${threshold}" CNTOOLS_MULTISIG_SELECTION_ROLE=payment
  CNTOOLS_MULTISIG_SIGNER_IDS=("${payment_ids[@]}"); CNTOOLS_MULTISIG_SIGNER_HASHES=("${payment_hashes[@]}")
  CNTOOLS_MULTISIG_SIGNER_SOURCES=("${payment_sources[@]}"); CNTOOLS_MULTISIG_SIGNER_LABELS=("${payment_labels[@]}")
  return "${status}"
}

# Before any further input: both scripts' time locks must allow SLOT (only
# the stake script's when a funding wallet pays).
cntools_multisig_stake_window_check() {
  local mswc_after="${CNTOOLS_MULTISIG_SPEND_AFTER}" mswc_before="${CNTOOLS_MULTISIG_SPEND_BEFORE}"
  ! cntools_multisig_stake_external || mswc_after='' mswc_before=''
  if [[ -n "${CNTOOLS_MULTISIG_STAKE_AFTER}" ]] && { [[ -z "${mswc_after}" ]] || (( CNTOOLS_MULTISIG_STAKE_AFTER > mswc_after )); }; then
    mswc_after="${CNTOOLS_MULTISIG_STAKE_AFTER}"
  fi
  if [[ -n "${CNTOOLS_MULTISIG_STAKE_BEFORE}" ]] && { [[ -z "${mswc_before}" ]] || (( CNTOOLS_MULTISIG_STAKE_BEFORE < mswc_before )); }; then
    mswc_before="${CNTOOLS_MULTISIG_STAKE_BEFORE}"
  fi
  cntools_multisig_window_check "$1" "${mswc_after}" "${mswc_before}"
}

# Intersect both mandatory script intervals with the requested TTL. No expiry
# removes only the user's upper bound; it never disables a script's time lock.
cntools_multisig_stake_plan() {
  local -n ms_stake_expiry="$1"
  local slot="$2" purpose="$3" lower='' upper="${ms_stake_expiry}" bound='' role='' index=0 source='' kind='' ids_name='' hashes_name='' sources_name='' labels_name='' script='' use=''
  local -a roles=(payment stake) afters=("${CNTOOLS_MULTISIG_SPEND_AFTER}" "${CNTOOLS_MULTISIG_STAKE_AFTER}") befores=("${CNTOOLS_MULTISIG_SPEND_BEFORE}" "${CNTOOLS_MULTISIG_STAKE_BEFORE}")
  [[ "${slot}" =~ ^(0|[1-9][0-9]{0,15})$ ]] || return 2
  # A funding wallet pays: the payment script is not spent, so neither its
  # participants nor its time locks take part (the caller adds the payer).
  if cntools_multisig_stake_external; then
    roles=(stake) afters=("${CNTOOLS_MULTISIG_STAKE_AFTER}") befores=("${CNTOOLS_MULTISIG_STAKE_BEFORE}")
  fi
  { cntools_multisig_stake_external || (( ${#CNTOOLS_MULTISIG_SIGNER_IDS[@]} >= CNTOOLS_MULTISIG_SPEND_THRESHOLD )); } &&
    (( ${#CNTOOLS_MULTISIG_STAKE_SIGNER_IDS[@]} >= CNTOOLS_MULTISIG_STAKE_THRESHOLD )) || {
    cntools_transaction_set_error 'Choose sufficient payment and stake participants before building.'; return 1;
  }
  for bound in "${afters[@]}"; do
    [[ -n "${bound}" ]] || continue
    [[ -n "${lower}" ]] && ((lower>=bound)) || lower="${bound}"
  done
  for bound in "${befores[@]}"; do
    [[ -n "${bound}" ]] || continue
    [[ -n "${upper}" ]] && ((upper<=bound)) || upper="${bound}"
  done
  [[ -z "${lower}" ]] || ((slot>=lower)) || { cntools_transaction_set_error 'A multisig payment/stake script is not valid yet.'; return 1; }
  [[ -z "${upper}" ]] || ((slot<upper)) || { cntools_transaction_set_error 'The multisig transaction or payment/stake script has expired.'; return 1; }
  cntools_transaction_plan_set_validity "${lower}" "${upper}" || return 1
  ms_stake_expiry="${upper}"
  for role in "${roles[@]}"; do
    if [[ "${role}" == payment ]]; then
      ids_name=CNTOOLS_MULTISIG_SIGNER_IDS; hashes_name=CNTOOLS_MULTISIG_SIGNER_HASHES; sources_name=CNTOOLS_MULTISIG_SIGNER_SOURCES; labels_name=CNTOOLS_MULTISIG_SIGNER_LABELS
      script="${CNTOOLS_MULTISIG_SPEND_SCRIPT}"; use=spend
    else
      ids_name=CNTOOLS_MULTISIG_STAKE_SIGNER_IDS; hashes_name=CNTOOLS_MULTISIG_STAKE_SIGNER_HASHES; sources_name=CNTOOLS_MULTISIG_STAKE_SIGNER_SOURCES; labels_name=CNTOOLS_MULTISIG_STAKE_SIGNER_LABELS
      script="${CNTOOLS_MULTISIG_STAKE_SCRIPT}"; use="${purpose}"
    fi
    local -n ms_ids="${ids_name}" ms_hashes="${hashes_name}" ms_sources="${sources_name}" ms_labels="${labels_name}"
    for index in "${!ms_ids[@]}"; do
      source="${ms_sources[index]}"; kind=either
      if [[ -n "${source}" ]]; then
        cntools_transaction_source_kind_into kind "${source}" || return 1
        CNTOOLS_TRANSACTION_RUNTIME_SOURCES["${ms_ids[index]}"]="${source}"
        CNTOOLS_TRANSACTION_RUNTIME_SOURCE_KINDS["${ms_ids[index]}"]="${kind}"
      fi
      cntools_transaction_plan_add_public_signer "${ms_labels[index]}" "$([[ "${role}" == payment ]] && printf spending || printf '%s' "${purpose}")" \
        "${ms_ids[index]}" "${ms_hashes[index]}" "${kind}" || return 1
    done
    cntools_transaction_plan_add_native_script "${CNTOOLS_STAKE_WALLET} ${role} script" "${use}" "${script}" "${ms_ids[@]}" || return 1
  done
}

cntools_stake_credential_arguments_into() {
  local -n ms_credential_arguments="$1"
  if [[ "${CNTOOLS_WALLET_REGISTER_WALLET_TYPE:-}" == MultiSig ]]; then
    ms_credential_arguments=(--stake-script-file "${CNTOOLS_MULTISIG_STAKE_SCRIPT}")
  else ms_credential_arguments=(--stake-verification-key-file "${CNTOOLS_WALLET_REGISTER_STAKE_VKEY}"); fi
}
