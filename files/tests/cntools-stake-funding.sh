#!/usr/bin/env bash
# CNTools stake actions paid by a funding wallet (issue #512): a stake-only
# wallet (no payment key or payment script) is offered for register,
# de-register, delegate, vote-delegate and withdraw; a funding wallet pays the
# fee and any deposit and receives the change, rewards and refunds; a funding
# wallet that cannot cover them is named and another one used; the hardware
# and MultiSig combinations cardano-hw-cli 1.19.1 cannot sign are refused.
# Functions are loaded from the libraries; no CLI, node or device is needed.
set -o pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  printf 'cntools stake funding tests skipped: Bash 5+ required\n'
  exit 0
fi
command -v jq >/dev/null 2>&1 || { printf 'cntools stake funding tests skipped: jq is not installed\n'; exit 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
LIB="${CNTOOLS_SOURCE}/lib"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-stake-funding.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf "${TEST_ROOT}"' EXIT
chmod 700 "${TEST_ROOT}"
failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: '$2' not in '$1'"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: '$2' found in '$1'"; }
# Written by the functions under test through their output arguments.
why='' reason='' context='' fitted='' can_sign='' body=''

cntools_log() { :; }
# shellcheck source=/dev/null
for library in number filesystem bech32 wallet transaction utxo coin-selection change-plan transaction-funding \
    wallet-selection wallet-stake multisig-spend multisig-stake recipient wallet-payment stake-funding stake-funding-ui \
    wallet-register wallet-register-ui funds-delegate governance-delegate funds-withdraw; do
  . "${LIB}/${library}.sh" || { printf 'FAIL: cannot load %s\n' "${library}" >&2; exit 1; }
done
cntools_transaction_log() { :; }
cntools_wallet_log() { :; }
cntools_wallet_register_log() { :; }
cntools_transaction_require_cli() { :; }
cntools_transaction_require_hwcli() { :; }

CNTOOLS_NETWORK=preprod
CNTOOLS_WALLET_PAY_VKEY_FILENAME=payment.vkey CNTOOLS_WALLET_PAY_SKEY_FILENAME=payment.skey CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME=payment.hwsfile
CNTOOLS_WALLET_STAKE_VKEY_FILENAME=stake.vkey CNTOOLS_WALLET_STAKE_SKEY_FILENAME=stake.skey CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME=stake.hwsfile
CNTOOLS_WALLET_PAY_SCRIPT_FILENAME=payment.script CNTOOLS_WALLET_STAKE_SCRIPT_FILENAME=stake.script

# ── test wallets ─────────────────────────────────────────────────────────────
# Key ids are 32-byte hex; credentials are cached so no CLI derives them.
declare -A KEY_ID=() CREDENTIAL=()
key_number=0
new_key() { # NAME ROLE -> key id in KEY_ID[NAME/ROLE]
  key_number=$((key_number + 1))
  KEY_ID["$1/$2"]="$(printf '%064x' "${key_number}")"
  CREDENTIAL["$1/$2"]="$(printf '%056x' "$((key_number + 1000))")"
  CNTOOLS_TRANSACTION_CREDENTIAL_CACHE["${KEY_ID[$1/$2]}"]="${CREDENTIAL[$1/$2]}"
}
vkey() { # DIR ROLE NAME
  local type=PaymentVerificationKeyShelley_ed25519
  [[ "$2" != stake ]] || type=StakeVerificationKeyShelley_ed25519
  printf '{"type":"%s","description":"","cborHex":"5820%s"}\n' "${type}" "${KEY_ID[$3/$2]}" > "$1/$2.vkey"
}
cli_skey() { # The test's CLI signing key carries its key id (read by the stub below).
  local type=PaymentSigningKeyShelley_ed25519
  [[ "$2" != stake ]] || type=StakeSigningKeyShelley_ed25519
  printf '{"type":"%s","description":"","cborHex":"5820%s"}\n' "${type}" "${KEY_ID[$3/$2]}" > "$1/$2.skey"
  chmod 600 "$1/$2.skey"
}
hw_skey() {
  local type=PaymentHWSigningFileShelley_ed25519 path=1852H/1815H/0H/0/0
  [[ "$2" != stake ]] || { type=StakeHWSigningFileShelley_ed25519; path=1852H/1815H/0H/2/0; }
  printf '{"type":"%s","description":"","path":"%s","cborXPubKeyHex":"5840%s%064x"}\n' "${type}" "${path}" "${KEY_ID[$3/$2]}" 7 > "$1/$2.hwsfile"
  chmod 600 "$1/$2.hwsfile"
}
cntools_transaction_source_key_id_into() {
  local -n tsk_output="$1"
  tsk_output="$(jq -r '(.cborXPubKeyHex // .cborHex)[4:68]' "$2")"
}
declare -A WALLET_TYPE=() BASE=() PAYMENT=() REWARD=()
make_wallet() { # NAME TYPE PARTS...: payment-cli payment-hw stake-cli stake-hw payment-script stake-script
  local name="$1" type="$2" directory="${TEST_ROOT}/wallets/$1" part=''
  shift 2
  mkdir -p "${directory}"; chmod 700 "${directory}"
  WALLET_TYPE["${name}"]="${type}"
  for part in "$@"; do
    case "${part}" in
      payment-cli) new_key "${name}" payment; vkey "${directory}" payment "${name}"; cli_skey "${directory}" payment "${name}" ;;
      payment-hw) new_key "${name}" payment; vkey "${directory}" payment "${name}"; hw_skey "${directory}" payment "${name}" ;;
      stake-cli) new_key "${name}" stake; vkey "${directory}" stake "${name}"; cli_skey "${directory}" stake "${name}" ;;
      stake-hw) new_key "${name}" stake; vkey "${directory}" stake "${name}"; hw_skey "${directory}" stake "${name}" ;;
      payment-script) printf '{"type":"all","scripts":[]}\n' > "${directory}/payment.script" ;;
      stake-script) printf '{"type":"all","scripts":[]}\n' > "${directory}/stake.script" ;;
    esac
  done
  REWARD["${name}"]="stake_test1u${name}"
  if [[ -f "${directory}/payment.vkey" || -f "${directory}/payment.script" ]]; then
    PAYMENT["${name}"]="addr_test1v${name}"
    [[ ! -f "${directory}/stake.vkey" && ! -f "${directory}/stake.script" ]] || BASE["${name}"]="addr_test1q${name}"
  fi
}
make_wallet full CLI payment-cli stake-cli
make_wallet stakeonly CLI stake-cli
make_wallet hwstake Hardware stake-hw
make_wallet hwfull Hardware payment-hw stake-hw
make_wallet msstake MultiSig stake-script
make_wallet msfull MultiSig payment-script stake-script
make_wallet nostake CLI payment-cli
make_wallet poor CLI payment-cli stake-cli
make_wallet rich CLI payment-cli stake-cli
make_wallet rich2 CLI payment-cli stake-cli

catalog() { # NAMES... become the wallet catalog
  local name=''
  CNTOOLS_WALLET_NAMES=() CNTOOLS_WALLET_PATHS=() CNTOOLS_WALLET_TYPES=() CNTOOLS_WALLET_PROTECTIONS=()
  for name in "$@"; do
    CNTOOLS_WALLET_NAMES+=("${name}") CNTOOLS_WALLET_PATHS+=("${TEST_ROOT}/wallets/${name}")
    CNTOOLS_WALLET_TYPES+=("${WALLET_TYPE[${name}]}") CNTOOLS_WALLET_PROTECTIONS+=(Open)
  done
}
cntools_wallet_read_address() { # DIR ROLE OUTPUT, from the test tables
  local name="${1##*/}" value=''
  case "$2" in base) value="${BASE[${name}]:-}" ;; payment) value="${PAYMENT[${name}]:-}" ;; reward) value="${REWARD[${name}]:-}" ;; esac
  [[ -n "${value}" ]] || return 1
  printf -v "$3" '%s' "${value}"
}

# ── picker: stake-only wallets and funding wallets ───────────────────────────
catalog full stakeonly hwstake hwfull msstake msfull nostake
candidates() { # CONTEXT -> names, with annotations
  local index=0 note='' out=''
  for index in "${!CNTOOLS_WALLET_PATHS[@]}"; do
    cntools_wallet_selection_candidate_into note "${index}" "$1" || continue
    out+="${CNTOOLS_WALLET_NAMES[index]}[${note}] "
  done
  printf '%s' "${out% }"
}
for context in register deregister delegate vote-delegate withdraw; do
  list="$(candidates "${context}")"
  for name in full stakeonly hwstake hwfull msstake msfull; do assert_contains "${list}" "${name}[" "${context} offers ${name}"; done
  assert_not_contains "${list}" "nostake[" "${context} needs stake keys"
  assert_contains "${list}" "stakeonly[Stake only · " "${context} names a stake-only wallet"
  assert_contains "${list}" "msstake[Native script · Stake only · " "${context} names a stake-only MultiSig wallet"
  assert_not_contains "${list}" "full[Stake only" "${context} a full wallet is not stake-only"
done
for context in send catalyst; do
  assert_not_contains "$(candidates "${context}")" "stakeonly[" "${context} still needs a payment key"
done
assert_eq "$(candidates stake-funding-software)" "full[] nostake[]" "a CLI stake wallet is paid for by CLI or mnemonic wallets only"
assert_eq "$(candidates stake-funding)" "full[] hwfull[] nostake[]" "a hardware stake wallet may be paid for by a hardware wallet"
catalog stakeonly
cntools_wallet_selection_empty_reason_into why register
assert_eq "${why}" "Every wallet with stake keys is already registered." "a stake-only wallet counts as eligible"
catalog nostake
cntools_wallet_selection_empty_reason_into why delegate
assert_eq "${why}" "No wallet has a stake key or stake script." "without stake keys"
cntools_wallet_selection_empty_reason_into why stake-funding-software
assert_contains "${why}" "CLI or mnemonic wallet" "the funding picker's empty reason"

# ── which wallet types combine (cardano-hw-cli 1.19.1) ───────────────────────
for case in "CLI|CLI|" "Mnemonic|CLI|" "Hardware|CLI|" "MultiSig|CLI|" "Hardware|Mnemonic|" "Hardware|Hardware|" \
            "CLI|Hardware|same Ledger" "Mnemonic|Hardware|same Ledger" "MultiSig|Hardware|script credentials" \
            "CLI|MultiSig|MultiSig wallet cannot pay" "Hardware|MultiSig|MultiSig wallet cannot pay"; do
  IFS='|' read -r stake_type funding_type expected <<< "${case}"
  cntools_stake_funding_refusal_into reason "${stake_type}" "${funding_type}"
  if [[ -z "${expected}" ]]; then assert_eq "${reason}" "" "${funding_type} pays for ${stake_type}"
  else assert_contains "${reason}" "${expected}" "${funding_type} cannot pay for ${stake_type}"; fi
done
cntools_stake_funding_context_into context CLI; assert_eq "${context}" stake-funding-software "CLI stake wallet context"
cntools_stake_funding_context_into context Hardware; assert_eq "${context}" stake-funding "hardware stake wallet context"

# ── a stake-only wallet is prepared without payment keys ─────────────────────
cntools_wallet_directory_safe() { :; }
cntools_wallet_prepare_selected_material() { :; }
cntools_wallet_type() { printf '%s\n' "${WALLET_TYPE[${1##*/}]}"; }
cntools_wallet_key_validate() { [[ -f "$1" ]]; }
cntools_wallet_id_read_credential() { local name="${1##*/}"; [[ -n "${CREDENTIAL[${name}/$2]:-}" ]] || return 1; printf -v "$3" '%s' "${CREDENTIAL[${name}/$2]}"; }
CLI_CALLS=()
cntools_transaction_run_cli() { # Address checks print what the test tables say.
  local output="$1" argument='' kind=''
  shift 3
  CLI_CALLS+=("$*")
  for argument in "$@"; do [[ "${argument}" != stake-address ]] || kind=reward; done
  if [[ "${kind}" == reward ]]; then printf '%s' "${CNTOOLS_STAKE_REWARD_ADDRESS}" > "${output}"
  elif [[ "$*" == *--stake-verification-key-file* ]]; then printf '%s' "${CNTOOLS_STAKE_BASE_ADDRESS}" > "${output}"
  else printf '%s' "${CNTOOLS_STAKE_PAYMENT_ADDRESS}" > "${output}"; fi
}
cntools_transaction_network_arguments_into() { local -n tna_output="$1"; tna_output=(--testnet-magic 1); }
cntools_transaction_temp_file() { local file=''; file="$(mktemp "${TEST_ROOT}/temp.XXXXXX")"; printf -v "$1" '%s' "${file}"; }

CLI_CALLS=()
cntools_stake_prepare_wallet "${TEST_ROOT}/wallets/stakeonly" stakeonly || fail "a CLI stake-only wallet is prepared: ${CNTOOLS_TRANSACTION_ERROR:-}"
assert_eq "${CNTOOLS_STAKE_HAS_PAYMENT}|${CNTOOLS_STAKE_BASE_ADDRESS}|${CNTOOLS_STAKE_PAYMENT_VKEY}" "N||" "stake-only wallet has no payment identity"
assert_eq "${CNTOOLS_STAKE_STAKE_SOURCE##*/}|${CNTOOLS_STAKE_CAN_SIGN}" "stake.skey|Y" "its stake key signs"
assert_eq "${#CLI_CALLS[@]}" 1 "only the stake address is checked"
cntools_stake_prepare_wallet "${TEST_ROOT}/wallets/hwstake" hwstake || fail "a hardware stake-only wallet is prepared: ${CNTOOLS_TRANSACTION_ERROR:-}"
assert_eq "${CNTOOLS_STAKE_HAS_PAYMENT}|${CNTOOLS_STAKE_STAKE_SOURCE##*/}" "N|stake.hwsfile" "hardware stake-only wallet"
CLI_CALLS=()
cntools_stake_prepare_wallet "${TEST_ROOT}/wallets/full" full || fail "a full wallet is prepared"
assert_eq "${CNTOOLS_STAKE_HAS_PAYMENT}|${CNTOOLS_STAKE_BASE_ADDRESS}|${#CLI_CALLS[@]}" "Y|addr_test1qfull|3" "a full wallet keeps all three address checks"

# ── funding wallets ──────────────────────────────────────────────────────────
cntools_payment_prepare_wallet() {
  local name="${1##*/}" type="${WALLET_TYPE[${1##*/}]}"
  CNTOOLS_PAYMENT_TYPE="${type}" CNTOOLS_PAYMENT_ADDRESS="${BASE[${name}]:-${PAYMENT[${name}]:-}}" CNTOOLS_PAYMENT_PAYMENT="${PAYMENT[${name}]:-}"
  CNTOOLS_PAYMENT_VKEY="$1/payment.vkey" CNTOOLS_PAYMENT_CREDENTIAL="${CREDENTIAL[${name}/payment]:-}" CNTOOLS_PAYMENT_SOURCE=''
  [[ "${type}" != MultiSig ]] || return 0
  if [[ -f "$1/payment.hwsfile" ]]; then CNTOOLS_PAYMENT_SOURCE="$1/payment.hwsfile"
  elif [[ -f "$1/payment.skey" ]]; then CNTOOLS_PAYMENT_SOURCE="$1/payment.skey"; fi
}
fund() { cntools_stake_funding_reset; cntools_stake_funding_prepare "${TEST_ROOT}/wallets/$1" "$1" "$2"; }
fund full CLI || fail "a CLI wallet pays for a CLI stake wallet"
assert_eq "${CNTOOLS_STAKE_FUNDING_EXTERNAL}|${CNTOOLS_STAKE_FUNDING_BASE_ADDRESS}|${CNTOOLS_STAKE_FUNDING_STAKE_SOURCE}" "Y|addr_test1qfull|" "CLI funding wallet"
fund hwfull CLI && fail "a hardware wallet must not pay for a CLI stake wallet"
assert_contains "${CNTOOLS_TRANSACTION_ERROR}" "same Ledger" "refusal names the Ledger rule"
fund hwfull MultiSig && fail "a hardware wallet must not pay for a MultiSig stake wallet"
fund msfull CLI && fail "a MultiSig wallet must not pay for another wallet"
fund hwfull Hardware || fail "a hardware wallet pays for a hardware stake wallet"
assert_eq "${CNTOOLS_STAKE_FUNDING_STAKE_SOURCE##*/}" "stake.hwsfile" "its stake key marks the change as its own"

# ── stake engine: a stake-only wallet needs a payer (10), in every flow ──────
cntools_wallet_query_network_arguments() { :; }
cntools_wallet_register_protocol_local() { CNTOOLS_WALLET_REGISTER_DEPOSIT=2000000 CNTOOLS_WALLET_REGISTER_PROTOCOL_FILE="${TEST_ROOT}/protocol.json"; }
UTXO_QUERIED=N
cntools_wallet_register_utxos_local() { UTXO_QUERIED=Y; return 1; }
for case in "register|no" "deregister|yes" "delegate|yes" "vote-delegate|yes"; do
  IFS='|' read -r operation registered <<< "${case}"
  cntools_wallet_register_operation_set "${operation}"
  cntools_wallet_query_local_stake() { CNTOOLS_WALLET_REGISTERED="${STAKE_REGISTERED}" CNTOOLS_WALLET_REWARD_LOVELACE=0 CNTOOLS_WALLET_STAKE_DEPOSIT=2000000 CNTOOLS_WALLET_POOL_DELEGATION='' CNTOOLS_WALLET_DREP_DELEGATION=''; }
  STAKE_REGISTERED="${registered}"
  cntools_stake_prepare_wallet "${TEST_ROOT}/wallets/stakeonly" stakeonly >/dev/null
  cntools_wallet_register_prepare_wallet "${TEST_ROOT}/wallets/stakeonly" stakeonly
  cntools_wallet_register_funding_apply
  UTXO_QUERIED=N status=0
  cntools_wallet_register_collect_local || status=$?
  assert_eq "${status}|${UTXO_QUERIED}" "10|N" "${operation}: a stake-only wallet asks for a funding wallet before any UTxO query"
  fund rich CLI
  cntools_wallet_register_funding_apply
  assert_eq "${CNTOOLS_WALLET_REGISTER_BASE_ADDRESS}|${CNTOOLS_WALLET_REGISTER_PAYMENT_SOURCE##*/}|${CNTOOLS_WALLET_REGISTER_CAN_SIGN}" \
    "addr_test1qrich|payment.skey|Y" "${operation}: the funding wallet pays and the build can sign"
  UTXO_QUERIED=N
  cntools_wallet_register_collect_local
  assert_eq "${UTXO_QUERIED}" Y "${operation}: the funding wallet's UTxOs are queried"
done

# ── stake engine: signers and description per funding combination ───────────
plan_for() { # OPERATION STAKE FUNDER(or -) : builds the plan
  cntools_wallet_register_operation_set "$1"
  cntools_stake_prepare_wallet "${TEST_ROOT}/wallets/$2" "$2" >/dev/null || fail "prepare $2"
  cntools_wallet_register_prepare_wallet "${TEST_ROOT}/wallets/$2" "$2"
  if [[ "$3" != - ]]; then fund "$3" "${WALLET_TYPE[$2]}" || fail "fund $2 with $3"; fi
  cntools_wallet_register_funding_apply
  CNTOOLS_WALLET_REGISTER_BACKEND=local CNTOOLS_WALLET_REGISTER_INPUTS=('aa#0') CNTOOLS_CHANGE_OUTPUTS=() CNTOOLS_WALLET_REGISTER_EXPIRY=1000
  CNTOOLS_DELEGATE_POOL_ID=pool1test CNTOOLS_VOTE_TARGET=drep_always_abstain CNTOOLS_VOTE_REGISTER=N
  cntools_wallet_register_plan_create || fail "plan $1 $2 $3: ${CNTOOLS_TRANSACTION_ERROR:-}"
}
signers() { jq -c 'map({l:(.labels|join(",")),r:(.roles|join(",")),k:.preferredKind,g:(.hardwareGroup // "")}) | sort_by(.l)' <<< "${CNTOOLS_TRANSACTION_PLAN_REQUIRED}"; }
change_keys() { jq -r 'map(.labels[]) | sort | join(",")' <<< "${CNTOOLS_TRANSACTION_PLAN_CHANGE_KEYS}"; }

plan_for register stakeonly rich
assert_eq "$(signers)" '[{"l":"rich payment key","r":"spending","k":"cli","g":""},{"l":"stakeonly stake key","r":"certificate","k":"cli","g":""}]' "CLI stake-only wallet, CLI funding wallet"
assert_contains "${CNTOOLS_TRANSACTION_PLAN_DESCRIPTION}" "rich pays the deposit and fee and gets all change" "register description names the payer"
assert_eq "$(jq -r '[.fundingWallet,.changeAddress,.wallet,.stakeAddress]|join("|")' <<< "${CNTOOLS_TRANSACTION_PLAN_SUMMARY}")" \
  "rich|addr_test1qrich|stakeonly|stake_test1ustakeonly" "the plan summary keeps both wallets apart"
plan_for deregister stakeonly rich
assert_contains "${CNTOOLS_TRANSACTION_PLAN_DESCRIPTION}" "rich pays the fee and gets the deposit refund" "de-registration refund goes to the funding wallet"
plan_for delegate stakeonly rich
assert_contains "${CNTOOLS_TRANSACTION_PLAN_DESCRIPTION}" "to pool1test; voting delegation is unchanged. rich pays" "delegation description"
plan_for vote-delegate stakeonly rich
assert_contains "${CNTOOLS_TRANSACTION_PLAN_DESCRIPTION}" "voting power to drep_always_abstain; pool delegation is unchanged. rich pays" "voting delegation description"
long_name="$(printf 'w%.0s' {1..64})"
cntools_stake_funding_fit_into fitted "Delegate ${long_name}'s voting power to drep1$(printf 'x%.0s' {1..54}); pool delegation is unchanged. ${long_name} pays and gets all change. Includes approved first stake registration and its deposit."
(( ${#fitted} <= 240 )) || fail "a long description fits the plan limit (${#fitted})"

plan_for register hwstake rich
assert_eq "$(signers)" '[{"l":"hwstake stake key","r":"certificate","k":"hardware","g":"stake-funding"},{"l":"rich payment key","r":"spending","k":"cli","g":""}]' "hardware stake key, CLI payer: only the stake key is on the device"
assert_eq "$(change_keys)" "" "change to a CLI payer is no device change"
plan_for delegate hwstake hwfull
assert_eq "$(signers)" '[{"l":"hwfull payment key","r":"spending","k":"hardware","g":"stake-funding"},{"l":"hwstake stake key","r":"certificate","k":"hardware","g":"stake-funding"}]' "two hardware wallets share one device session"
assert_eq "$(change_keys)" "hwfull base-address payment key,hwfull base-address stake key" "the hardware payer's change is its own"
plan_for register full -
assert_eq "$(signers)" '[{"l":"full payment key","r":"spending","k":"cli","g":""},{"l":"full stake key","r":"certificate","k":"cli","g":""}]' "a wallet that pays for itself is unchanged"
assert_eq "$(jq -r 'has("fundingWallet")' <<< "${CNTOOLS_TRANSACTION_PLAN_SUMMARY}")" false "no funding fields when the wallet pays itself"

# MultiSig stake-only wallet: only the stake participants and the payer sign;
# the payment script's time lock no longer applies.
NATIVE_SCRIPTS=()
cntools_transaction_plan_add_native_script() { NATIVE_SCRIPTS+=("$1:$2"); }
cntools_wallet_register_operation_set register
CNTOOLS_WALLET_REGISTER_WALLET=msstake CNTOOLS_WALLET_REGISTER_WALLET_TYPE=MultiSig CNTOOLS_STAKE_WALLET=msstake CNTOOLS_STAKE_WALLET_TYPE=MultiSig CNTOOLS_STAKE_HAS_PAYMENT=N
CNTOOLS_WALLET_REGISTER_REWARD_ADDRESS=stake_test1umsstake
fund rich MultiSig || fail "a CLI wallet pays for a MultiSig stake wallet"
cntools_wallet_register_funding_apply
new_key participant stake
CNTOOLS_MULTISIG_STAKE_SIGNER_IDS=("${KEY_ID[participant/stake]}") CNTOOLS_MULTISIG_STAKE_SIGNER_HASHES=("${CREDENTIAL[participant/stake]}")
CNTOOLS_MULTISIG_STAKE_SIGNER_SOURCES=('') CNTOOLS_MULTISIG_STAKE_SIGNER_LABELS=('participant · stake key') CNTOOLS_MULTISIG_STAKE_THRESHOLD=1
CNTOOLS_MULTISIG_SIGNER_IDS=() CNTOOLS_MULTISIG_SPEND_THRESHOLD=1 CNTOOLS_MULTISIG_SPEND_AFTER=999999 CNTOOLS_MULTISIG_SPEND_BEFORE=''
CNTOOLS_MULTISIG_STAKE_AFTER=10 CNTOOLS_MULTISIG_STAKE_BEFORE='' CNTOOLS_MULTISIG_STAKE_SLOT=500 CNTOOLS_MULTISIG_STAKE_SCRIPT="${TEST_ROOT}/wallets/msstake/stake.script"
CNTOOLS_WALLET_REGISTER_BACKEND=local CNTOOLS_WALLET_REGISTER_INPUTS=('aa#0') CNTOOLS_CHANGE_OUTPUTS=() CNTOOLS_WALLET_REGISTER_EXPIRY=1000
cntools_wallet_register_plan_create || fail "MultiSig stake-only plan: ${CNTOOLS_TRANSACTION_ERROR:-}"
assert_eq "$(signers)" '[{"l":"participant · stake key","r":"certificate","k":"either","g":""},{"l":"rich payment key","r":"spending","k":"cli","g":""}]' "MultiSig stake participants and the payer"
assert_eq "${NATIVE_SCRIPTS[*]}" "msstake stake script:certificate" "only the stake script is witnessed"
assert_eq "${CNTOOLS_TRANSACTION_PLAN_INVALID_BEFORE}" 10 "the payment script's time lock does not apply"
cntools_multisig_stake_can_sign_into can_sign; assert_eq "${can_sign}" N "a public-only participant cannot sign here"
CNTOOLS_MULTISIG_STAKE_SIGNER_SOURCES=("${TEST_ROOT}/wallets/rich/stake.skey")
cntools_multisig_stake_can_sign_into can_sign; assert_eq "${can_sign}" Y "a local participant and a local payer sign"
cntools_multisig_stake_window_check 5 && fail "the stake script's own time lock still applies"
cntools_multisig_stake_window_check 20 || fail "the payment script's time lock is ignored when a funding wallet pays"

# ── withdraw: rewards and change go to the funding wallet ────────────────────
FUNDING_ADDRESSES=''
cntools_funding_collect() {
  FUNDING_ADDRESSES="$1|$2" CNTOOLS_FUNDING_BACKEND=local CNTOOLS_FUNDING_EMPTY=N CNTOOLS_FUNDING_SLOT=500
  if [[ -z "$1" || "${FUNDS_EMPTY:-N}" == Y ]]; then CNTOOLS_FUNDING_EMPTY=Y; return 1; fi
}
cntools_funding_exclude_reference_scripts() { :; }
cntools_withdraw_query_stake() { CNTOOLS_WALLET_REWARD_LOVELACE=5000000; }
cntools_withdraw_select() { [[ "${FUNDS_SHORT:-N}" != Y ]] || { CNTOOLS_TRANSACTION_ERROR='Not enough spendable ADA'; return 1; }; }
cntools_stake_prepare_wallet "${TEST_ROOT}/wallets/stakeonly" stakeonly >/dev/null
cntools_stake_funding_reset
status=0; cntools_withdraw_collect || status=$?
assert_eq "${status}|${FUNDING_ADDRESSES}" "10||" "withdraw: a stake-only wallet reads rewards first, then needs a payer"
fund rich CLI
status=0; FUNDS_EMPTY=Y cntools_withdraw_collect || status=$?
assert_eq "${status}|${FUNDING_ADDRESSES}" "5|addr_test1qrich|addr_test1vrich" "withdraw: an empty funding wallet"
status=0; FUNDS_SHORT=Y cntools_withdraw_collect || status=$?
assert_eq "${status}" 9 "withdraw: a funding wallet that cannot cover the fee"
status=0; cntools_withdraw_collect || status=$?
assert_eq "${status}|${CNTOOLS_WITHDRAW_FUND_BASE}|${CNTOOLS_STAKE_CAN_SIGN}" "0|addr_test1qrich|Y" "withdraw: the funding wallet pays"
CNTOOLS_WITHDRAW_EXPIRY=1000 CNTOOLS_WITHDRAW_REWARDS=5000000 CNTOOLS_WITHDRAW_BACKEND=local
cntools_change_policy_json() { printf '{}'; }
cntools_withdraw_plan || fail "withdraw plan: ${CNTOOLS_TRANSACTION_ERROR:-}"
assert_eq "$(signers)" '[{"l":"rich payment key","r":"spending","k":"cli","g":""},{"l":"stakeonly stake","r":"withdrawal","k":"cli","g":""}]' "withdraw signers"
assert_contains "${CNTOOLS_TRANSACTION_PLAN_DESCRIPTION}" "to rich's base address; rich pays the fee" "withdraw description"
assert_eq "$(jq -r '[.returnAddress,.fundingWallet]|join("|")' <<< "${CNTOOLS_TRANSACTION_PLAN_SUMMARY}")" "addr_test1qrich|rich" "rewards go to the funding wallet"
cntools_transaction_view_into() { printf -v "$1" '%s' "${VIEW}"; }
CNTOOLS_WITHDRAW_FEE=200000
VIEW='{"fee":"200000 Lovelace","withdrawals":[{"address":"stake_test1ustakeonly","amount":"5000000 Lovelace"}],"outputs":[{"address":"addr_test1qrich"}]}'
cntools_withdraw_validate_balanced_body body || fail "a withdrawal to the funding wallet validates"
VIEW='{"fee":"200000 Lovelace","withdrawals":[{"address":"stake_test1ustakeonly","amount":"5000000 Lovelace"}],"outputs":[{"address":"addr_test1qfull"}]}'
cntools_withdraw_validate_balanced_body body 2>/dev/null && fail "a withdrawal to another address is refused"

# ── choosing the funding wallet: the one that cannot pay is named ────────────
MESSAGES=() PURPOSES=()
cntools_ui_render_status() { MESSAGES+=("$1: $2"); }
cntools_ui_wait() { :; }
cntools_ui_spin_function() { shift; "$@"; }
test_begin() { :; }
cntools_wallet_choose() { # The first offered wallet, or PICK.
  local -n twc_output="$1"
  local index='' note='' excluded='' first=''
  PURPOSES+=("$2")
  for index in "${!CNTOOLS_WALLET_PATHS[@]}"; do
    for excluded in "${CNTOOLS_WALLET_SELECTION_EXCLUDE_DIRS[@]}"; do [[ "${excluded}" != "${CNTOOLS_WALLET_PATHS[index]}" ]] || continue 2; done
    cntools_wallet_selection_candidate_into note "${index}" "$4" || continue
    [[ -n "${first}" ]] || first="${index}"
    [[ "${CNTOOLS_WALLET_NAMES[index]}" != "${PICK:-}" ]] || { twc_output="${index}"; return 0; }
  done
  [[ -n "${first}" ]] || return 3
  twc_output="${first}"
}
fake_collect() { # poor cannot cover the deposit; everyone else can
  if [[ "${CNTOOLS_STAKE_FUNDING_WALLET}" == poor ]]; then
    CNTOOLS_WALLET_REGISTER_ERROR='Not enough spendable ADA: this needs at least 2.2 ADA, and the usable UTxOs hold 1 ADA.'; return 9
  fi
}
catalog stakeonly poor rich hwfull
cntools_stake_funding_reset
status=0; cntools_stake_funding_choose 10 "${TEST_ROOT}/wallets/stakeonly" stakeonly CLI 'Wallet that pays' 'the stake deposit and the fee' 'the change' test_begin fake_collect || status=$?
assert_eq "${status}|${CNTOOLS_STAKE_FUNDING_WALLET}|${CNTOOLS_STAKE_FUNDING_EXTERNAL}" "0|rich|Y" "a short funding wallet is passed over"
assert_contains "${MESSAGES[0]}" "info: stakeonly has no payment key, so another wallet pays the stake deposit and the fee" "why a funding wallet is asked for"
assert_contains "${MESSAGES[1]}" "poor cannot cover the stake deposit and the fee. Not enough spendable ADA" "the short wallet is named with the amounts"
assert_contains "${MESSAGES[1]}" "Using rich instead." "the last other wallet is used"
assert_eq "${#PURPOSES[@]}" 2 "the picker asked twice"

MESSAGES=()
catalog stakeonly poor hwfull
status=0; cntools_stake_funding_choose 10 "${TEST_ROOT}/wallets/stakeonly" stakeonly CLI 'Wallet that pays' 'the stake deposit and the fee' 'the change' test_begin fake_collect || status=$?
assert_eq "${status}|${CNTOOLS_STAKE_FUNDING_EXTERNAL}" "3|N" "no wallet can cover the deposit"
assert_contains "${MESSAGES[*]}" "No other wallet can pay for stakeonly: a CLI or mnemonic wallet with a payment key and funds is needed." "the outcome when none can pay"
assert_not_contains "${MESSAGES[*]}" "Another wallet can pay" "no contradiction when none can"

MESSAGES=() PURPOSES=()
catalog stakeonly hwfull
status=0; cntools_stake_funding_choose 10 "${TEST_ROOT}/wallets/stakeonly" stakeonly CLI 'Wallet that pays' 'the fee' 'the change' test_begin fake_collect || status=$?
assert_eq "${status}|${#PURPOSES[@]}" "3|0" "a hardware wallet is never offered for a CLI stake wallet"
assert_contains "${MESSAGES[*]}" "stakeonly has no payment key." "the reason is shown"

catalog hwstake hwfull rich
MESSAGES=()
status=0; cntools_stake_funding_choose 10 "${TEST_ROOT}/wallets/hwstake" hwstake Hardware 'Wallet that pays' 'the fee' 'the rewards and the change' test_begin fake_collect || status=$?
assert_eq "${status}|${CNTOOLS_STAKE_FUNDING_WALLET}" "0|hwfull" "a hardware wallet may pay for a hardware stake wallet"
assert_contains "${MESSAGES[0]}" "pays the fee and receives the rewards and the change." "a withdrawal names the rewards the funding wallet receives"
MESSAGES=()
cntools_stake_funding_hardware_notice Hardware hwstake
assert_contains "${MESSAGES[*]}" "same device" "two hardware wallets: the same-Ledger notice"

MESSAGES=()
catalog full poor rich
status=0; cntools_stake_funding_choose 9 "${TEST_ROOT}/wallets/full" full CLI 'Wallet that pays' 'the fee' 'the change' test_begin fake_collect || status=$?
assert_eq "${status}|${CNTOOLS_STAKE_FUNDING_WALLET}" "0|rich" "a wallet with too few funds is paid for by another"
assert_contains "${MESSAGES[0]}" "full cannot cover the fee. " "the stake wallet's own shortfall is named"

# What the funding wallet pays and receives, per stake action.
need='' gets='' purpose=''
for case in "register|N|the stake deposit and the fee|the change" "deregister|N|the fee|the change and the refunded stake deposit" \
            "delegate|N|the fee|the change" "delegate|Y|the stake deposit and the fee|the change" \
            "vote-delegate|Y|the stake deposit and the fee|the change"; do
  IFS='|' read -r operation registers expected_need expected_gets <<< "${case}"
  cntools_wallet_register_operation_set "${operation}"
  CNTOOLS_WALLET_REGISTER_WALLET=stakeonly CNTOOLS_DELEGATE_REGISTER="${registers}" CNTOOLS_VOTE_REGISTER="${registers}"
  cntools_wallet_register_funding_text_into need gets purpose
  assert_eq "${need}|${gets}" "${expected_need}|${expected_gets}" "${operation} (registers ${registers}): what the funding wallet pays and receives"
  assert_contains "${purpose}" "for stakeonly's ${CNTOOLS_WALLET_REGISTER_NOUN} · it receives ${expected_gets}" "${operation} funding picker purpose"
done

# ── review: Change funding wallet ────────────────────────────────────────────
catalog stakeonly poor rich rich2
fund rich CLI; CNTOOLS_TRANSACTION_UI_NOTICE=''
status=0; cntools_stake_funding_change "${TEST_ROOT}/wallets/stakeonly" stakeonly CLI 'Wallet that pays' 'the fee' test_begin fake_collect || status=$?
assert_eq "${status}|${CNTOOLS_STAKE_FUNDING_WALLET}" "1|rich" "a short new funding wallet keeps the reviewed one"
assert_contains "${CNTOOLS_TRANSACTION_UI_NOTICE}" "poor cannot cover the fee" "the short wallet is named in the review's notice"
assert_contains "${CNTOOLS_TRANSACTION_UI_NOTICE}" "The reviewed funding is kept." "the review says the funding is kept"
catalog stakeonly rich; CNTOOLS_TRANSACTION_UI_NOTICE=''
status=0; cntools_stake_funding_change "${TEST_ROOT}/wallets/stakeonly" stakeonly CLI 'Wallet that pays' 'the fee' test_begin fake_collect || status=$?
assert_eq "${status}" 1 "no other wallet to change to"
assert_contains "${CNTOOLS_TRANSACTION_UI_NOTICE}" "No other wallet can pay for stakeonly" "the review says why nothing changed"
catalog stakeonly poor rich rich2
status=0; PICK=rich2 cntools_stake_funding_change "${TEST_ROOT}/wallets/stakeonly" stakeonly CLI 'Wallet that pays' 'the fee' test_begin fake_collect || status=$?
assert_eq "${status}|${CNTOOLS_STAKE_FUNDING_WALLET}" "0|rich2" "another funding wallet"
catalog full rich
CNTOOLS_STAKE_HAS_PAYMENT=Y
fund rich CLI
status=0; PICK=full cntools_stake_funding_change "${TEST_ROOT}/wallets/full" full CLI 'Wallet that pays' 'the fee' test_begin fake_collect || status=$?
assert_eq "${status}|${CNTOOLS_STAKE_FUNDING_EXTERNAL}" "0|N" "a wallet with a payment key can pay for itself again"

# ── funding collect without an address reads only the protocol and tip ──────
(
  unset -f cntools_funding_collect
  # shellcheck source=/dev/null
  . "${LIB}/transaction-funding.sh"
  CNTOOLS_MODE=light CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_KOIOS_API=https://koios.invalid/api/v1
  cntools_transaction_local_backend_ready() { return 1; }
  cntools_funding_get() { printf '{}' > "$2"; }
  cntools_funding_koios_utxos() { printf 'queried\n' > "${TEST_ROOT}/utxo-queried"; }
  cntools_funding_tip_into() { printf -v "$1" '%s' 500; }
  cntools_coin_initial_fee_into() { printf -v "$1" '%s' 200000; }
  status=0; cntools_funding_collect '' '' || status=$?
  [[ "${status}|${CNTOOLS_FUNDING_EMPTY}|${CNTOOLS_FUNDING_BACKEND}|${CNTOOLS_FUNDING_SLOT}" == "1|Y|koios|500" ]] ||
    { printf 'FAIL: collect without an address: %s\n' "${status}|${CNTOOLS_FUNDING_EMPTY}|${CNTOOLS_FUNDING_BACKEND}|${CNTOOLS_FUNDING_SLOT}" >&2; exit 1; }
  [[ ! -e "${TEST_ROOT}/utxo-queried" ]] || { printf 'FAIL: no UTxO query without an address\n' >&2; exit 1; }
) || failures=$((failures + 1))

# ── the five actions load the funding libraries ──────────────────────────────
for module in wallet/register wallet/deregister funds/delegate funds/withdraw vote/governance/delegate; do
  libs="$(jq -r '.libs | join(" ")' "${CNTOOLS_SOURCE}/modules/root/${module}/module.json")"
  for library in recipient.sh wallet-payment.sh stake-funding.sh stake-funding-ui.sh; do
    assert_contains " ${libs} " " ${library} " "${module} loads ${library}"
    [[ -f "${LIB}/${library}" ]] || fail "${library} exists"
  done
done

if (( failures > 0 )); then
  printf '%s cntools stake funding check(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'cntools stake funding tests passed\n'
