#!/usr/bin/env bash
# A separate wallet that pays a stake action's fee and deposit, and receives
# the change, withdrawn rewards and any refunded deposit: for a stake-only
# wallet (no payment key or payment script), or one that cannot cover them.
# Loaded after the wallet, payment and stake libraries. Functions only.
#
# What cardano-hw-cli 1.19.1 can sign decides the wallet types that combine:
# in ordinary mode a Ledger must hold the stake key of every certificate and
# withdrawal it signs (MissingSigningFileForCertificateError otherwise), its
# multisig mode refuses payment and stake signing files, and it checks every
# signature against its signing file. So a hardware wallet pays only for a
# hardware stake wallet on the same Ledger, in one device session.
# shellcheck disable=SC2034

CNTOOLS_STAKE_FUNDING_EXTERNAL=N
CNTOOLS_STAKE_FUNDING_WALLET='' CNTOOLS_STAKE_FUNDING_TYPE='' CNTOOLS_STAKE_FUNDING_DIRECTORY=''
CNTOOLS_STAKE_FUNDING_BASE_ADDRESS='' CNTOOLS_STAKE_FUNDING_PAYMENT_ADDRESS=''
CNTOOLS_STAKE_FUNDING_PAYMENT_VKEY='' CNTOOLS_STAKE_FUNDING_PAYMENT_SOURCE='' CNTOOLS_STAKE_FUNDING_PAYMENT_CREDENTIAL=''
CNTOOLS_STAKE_FUNDING_STAKE_VKEY='' CNTOOLS_STAKE_FUNDING_STAKE_SOURCE=''
# The hardware session a hardware stake key and a hardware payer share.
CNTOOLS_STAKE_FUNDING_GROUP=stake-funding

# Back to the stake wallet paying for itself.
cntools_stake_funding_reset() {
  CNTOOLS_STAKE_FUNDING_EXTERNAL=N
  CNTOOLS_STAKE_FUNDING_WALLET='' CNTOOLS_STAKE_FUNDING_TYPE='' CNTOOLS_STAKE_FUNDING_DIRECTORY=''
  CNTOOLS_STAKE_FUNDING_BASE_ADDRESS='' CNTOOLS_STAKE_FUNDING_PAYMENT_ADDRESS=''
  CNTOOLS_STAKE_FUNDING_PAYMENT_VKEY='' CNTOOLS_STAKE_FUNDING_PAYMENT_SOURCE='' CNTOOLS_STAKE_FUNDING_PAYMENT_CREDENTIAL=''
  CNTOOLS_STAKE_FUNDING_STAKE_VKEY='' CNTOOLS_STAKE_FUNDING_STAKE_SOURCE=''
}

cntools_stake_funding_external() {
  [[ "${CNTOOLS_STAKE_FUNDING_EXTERNAL}" == Y ]]
}

# Every funding field, for a review step that may replace the funding wallet.
declare -ag CNTOOLS_STAKE_FUNDING_STATE=(CNTOOLS_STAKE_FUNDING_EXTERNAL CNTOOLS_STAKE_FUNDING_WALLET CNTOOLS_STAKE_FUNDING_TYPE
  CNTOOLS_STAKE_FUNDING_DIRECTORY CNTOOLS_STAKE_FUNDING_BASE_ADDRESS CNTOOLS_STAKE_FUNDING_PAYMENT_ADDRESS
  CNTOOLS_STAKE_FUNDING_PAYMENT_VKEY CNTOOLS_STAKE_FUNDING_PAYMENT_SOURCE CNTOOLS_STAKE_FUNDING_PAYMENT_CREDENTIAL
  CNTOOLS_STAKE_FUNDING_STAKE_VKEY CNTOOLS_STAKE_FUNDING_STAKE_SOURCE)

# Why a FUNDING_TYPE wallet cannot pay for a STAKE_TYPE wallet; empty when it can.
cntools_stake_funding_refusal_into() {
  local -n sfr_reason="$1"
  local sfr_stake="$2" sfr_funding="$3"
  sfr_reason=''
  case "${sfr_funding}" in
    CLI|Mnemonic) ;;
    Hardware)
      case "${sfr_stake}" in
        Hardware) ;;
        MultiSig) sfr_reason='A hardware wallet cannot pay for a MultiSig stake wallet: a Ledger cannot sign with a payment key in a transaction that uses script credentials. Choose a CLI or mnemonic wallet to pay.' ;;
        *) sfr_reason='A hardware wallet can pay only for a hardware stake wallet on the same Ledger: the device must hold the stake key it signs for. Choose a CLI or mnemonic wallet to pay.' ;;
      esac ;;
    MultiSig) sfr_reason='A MultiSig wallet cannot pay for another wallet. Choose a CLI or mnemonic wallet to pay.' ;;
    *) sfr_reason='This wallet has no usable payment key to pay with.' ;;
  esac
}

# The wallet picker context for funding wallets: hardware wallets are offered
# only for a hardware stake wallet.
cntools_stake_funding_context_into() {
  local -n sfc_context="$1"
  sfc_context=stake-funding-software
  [[ "$2" != Hardware ]] || sfc_context=stake-funding
}

# Prepares DIRECTORY (named NAME) to pay for a STAKE_TYPE stake wallet. The
# stake wallet's own fields are left alone; callers apply these.
cntools_stake_funding_prepare() {
  local sfp_directory="$1" sfp_name="${2:-${1##*/}}" sfp_stake_type="$3" sfp_reason='' sfp_kind=''
  cntools_payment_prepare_wallet "${sfp_directory}" || return 1
  cntools_stake_funding_refusal_into sfp_reason "${sfp_stake_type}" "${CNTOOLS_PAYMENT_TYPE}"
  [[ -z "${sfp_reason}" ]] || { cntools_transaction_set_error "${sfp_reason}"; return 1; }
  [[ "${CNTOOLS_PAYMENT_TYPE}" != Hardware || -n "${CNTOOLS_PAYMENT_SOURCE}" ]] || {
    cntools_transaction_set_error "${sfp_name} needs its payment hardware signing file to pay from a Ledger."; return 1;
  }
  CNTOOLS_STAKE_FUNDING_WALLET="${sfp_name}" CNTOOLS_STAKE_FUNDING_TYPE="${CNTOOLS_PAYMENT_TYPE}" CNTOOLS_STAKE_FUNDING_DIRECTORY="${sfp_directory}"
  CNTOOLS_STAKE_FUNDING_BASE_ADDRESS="${CNTOOLS_PAYMENT_ADDRESS}" CNTOOLS_STAKE_FUNDING_PAYMENT_ADDRESS="${CNTOOLS_PAYMENT_PAYMENT}"
  CNTOOLS_STAKE_FUNDING_PAYMENT_VKEY="${CNTOOLS_PAYMENT_VKEY}" CNTOOLS_STAKE_FUNDING_PAYMENT_SOURCE="${CNTOOLS_PAYMENT_SOURCE}"
  CNTOOLS_STAKE_FUNDING_PAYMENT_CREDENTIAL="${CNTOOLS_PAYMENT_CREDENTIAL}"
  CNTOOLS_STAKE_FUNDING_STAKE_VKEY='' CNTOOLS_STAKE_FUNDING_STAKE_SOURCE=''
  # A Ledger treats change to its own base address as its own only with both
  # keys; without the stake one it shows the change as a third-party output.
  if [[ "${CNTOOLS_PAYMENT_TYPE}" == Hardware && "${CNTOOLS_PAYMENT_ADDRESS}" != "${CNTOOLS_PAYMENT_PAYMENT}" ]] &&
     cntools_transaction_source_kind_into sfp_kind "${sfp_directory}/${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}" && [[ "${sfp_kind}" == hardware ]]; then
    CNTOOLS_STAKE_FUNDING_STAKE_VKEY="${sfp_directory}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"
    CNTOOLS_STAKE_FUNDING_STAKE_SOURCE="${sfp_directory}/${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}"
  fi
  CNTOOLS_STAKE_FUNDING_EXTERNAL=Y
  cntools_transaction_log WALLET "stake funding wallet prepared wallet=${sfp_name} type=${CNTOOLS_PAYMENT_TYPE} stake_type=${sfp_stake_type} signing=$([[ -n "${CNTOOLS_PAYMENT_SOURCE}" ]] && printf Y || printf N)"
}

# Y when this system holds the stake wallet's key (KEY_SIGNABLE, from
# cntools_stake_prepare_wallet) and the key that pays: the stake wallet's own,
# or the funding wallet's.
cntools_stake_funding_can_sign_into() {
  local -n sfs_output="$1"
  local sfs_stake_source="$2" sfs_payment_source="$3"
  sfs_output=N
  [[ -n "${sfs_stake_source}" ]] || return 0
  if cntools_stake_funding_external; then
    [[ -z "${CNTOOLS_STAKE_FUNDING_PAYMENT_SOURCE}" ]] || sfs_output=Y
  else
    [[ -z "${sfs_payment_source}" ]] || sfs_output=Y
  fi
}

# The funding wallet's payment signer. A hardware payer joins GROUP, the
# device session of a hardware stake key (both must be on one Ledger).
cntools_stake_funding_plan_payer() {
  local sfpp_group=''
  cntools_stake_funding_external || return 2
  [[ "${CNTOOLS_STAKE_FUNDING_TYPE}" != Hardware ]] || sfpp_group="${CNTOOLS_STAKE_FUNDING_GROUP}"
  cntools_transaction_plan_add_signer "${CNTOOLS_STAKE_FUNDING_WALLET} payment key" spending \
    "${CNTOOLS_STAKE_FUNDING_PAYMENT_VKEY}" "${CNTOOLS_STAKE_FUNDING_PAYMENT_SOURCE}" \
    "${CNTOOLS_STAKE_FUNDING_PAYMENT_CREDENTIAL}" "${sfpp_group}"
}

# A hardware payer's change keys, after every signer of its session is added.
cntools_stake_funding_plan_change_keys() {
  cntools_stake_funding_external || return 2
  [[ "${CNTOOLS_STAKE_FUNDING_TYPE}" == Hardware ]] || return 0
  cntools_transaction_plan_add_change_key "${CNTOOLS_STAKE_FUNDING_WALLET} base-address payment key" \
    "${CNTOOLS_STAKE_FUNDING_PAYMENT_VKEY}" "${CNTOOLS_STAKE_FUNDING_PAYMENT_SOURCE}" "${CNTOOLS_STAKE_FUNDING_GROUP}" || return 1
  [[ -n "${CNTOOLS_STAKE_FUNDING_STAKE_SOURCE}" ]] || return 0
  cntools_transaction_plan_add_change_key "${CNTOOLS_STAKE_FUNDING_WALLET} base-address stake key" \
    "${CNTOOLS_STAKE_FUNDING_STAKE_VKEY}" "${CNTOOLS_STAKE_FUNDING_STAKE_SOURCE}" "${CNTOOLS_STAKE_FUNDING_GROUP}"
}

# Signers of a key-based stake wallet that a funding wallet pays for: the
# payer, the stake key for PURPOSE (certificate or withdrawal) and a hardware
# payer's change keys. A hardware stake key joins the shared device session.
# Usage: cntools_stake_funding_plan_key_signers PURPOSE LABEL VKEY SOURCE CREDENTIAL STAKE_TYPE
cntools_stake_funding_plan_key_signers() {
  local sfk_group=''
  [[ "$6" != Hardware ]] || sfk_group="${CNTOOLS_STAKE_FUNDING_GROUP}"
  cntools_stake_funding_plan_payer || return 1
  cntools_transaction_plan_add_signer "$2" "$1" "$3" "$4" "$5" "${sfk_group}" || return 1
  cntools_stake_funding_plan_change_keys
}

# Encrypted keys that keep this system from signing: the payer's payment key
# and the stake wallet's STAKE_KEY.
cntools_stake_funding_encrypted_keys_into() {
  local -n sfe_keys="$1"
  local sfe_stake_directory="$2" sfe_stake_key="$3"
  sfe_keys=()
  if cntools_stake_funding_external; then
    sfe_keys+=("${CNTOOLS_STAKE_FUNDING_DIRECTORY}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}")
  elif [[ "${CNTOOLS_STAKE_HAS_PAYMENT:-Y}" == Y ]]; then
    sfe_keys+=("${sfe_stake_directory}/${CNTOOLS_WALLET_PAY_SKEY_FILENAME}")
  fi
  sfe_keys+=("${sfe_stake_directory}/${sfe_stake_key}")
}

# A plan description fits its 240-character limit, however long the wallet
# names and identifiers in it are (wallet names alone take up to 64 each).
cntools_stake_funding_fit_into() {
  local -n sff_output="$1"
  sff_output="$2"
  (( ${#sff_output} <= 240 )) || sff_output="${sff_output:0:237}..."
}

# Summary fields every stake plan carries when a funding wallet pays.
cntools_stake_funding_summary_into() {
  local -n sfsum_output="$1"
  local sfsum_summary="$2"
  if cntools_stake_funding_external; then
    sfsum_output="$(jq -c --arg wallet "${CNTOOLS_STAKE_FUNDING_WALLET}" --arg type "${CNTOOLS_STAKE_FUNDING_TYPE}" \
      --arg address "${CNTOOLS_STAKE_FUNDING_BASE_ADDRESS}" \
      '. + {fundingWallet:$wallet, fundingWalletType:$type, fundingAddress:$address}' <<< "${sfsum_summary}")" || return 1
  else
    sfsum_output="${sfsum_summary}"
  fi
}
