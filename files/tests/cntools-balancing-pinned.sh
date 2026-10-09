#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_ROOT="$REPO/scripts/common-helper-scripts/cntools"
PROOF_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cntools-balancing-pinned.XXXXXX")"
PROOF_ROOT="$(cd "$PROOF_ROOT" && pwd -P)"
trap 'rm -rf -- "$PROOF_ROOT"' EXIT
for lib in number filesystem utxo coin-selection change-plan transaction transaction-balance transaction-build wallet-payment funds-send; do
  . "$CNTOOLS_ROOT/lib/$lib.sh"
done
cntools_log() { :; }
cntools_run_command_timeout() { shift 3; "$@"; }
chmod() { local -a args=(); for arg in "$@"; do [[ "$arg" == -- ]] || args+=("$arg"); done; /bin/chmod "${args[@]}"; }
CNTOOLS_TMP_DIR="$PROOF_ROOT"
CNTOOLS_CLI="${1:?Pass the verified cnode deployment-pinned CLI}"
version="$("$CNTOOLS_CLI" version | head -1)"; version="${version#cardano-cli }"; version="${version%% *}"
pin="$(jq -er '.companions["cardano-cli"].version' "$REPO/files/node-implementations/cnode/release.json")"
[[ "$version" == "$pin" ]] || { printf "Use the cnode CLI deployment pin\n" >&2; exit 1; }
CNTOOLS_NETWORK=preview
CNTOOLS_TX_SELECTION_STRATEGY=balanced
CNTOOLS_TX_TOKEN_FRAGMENTATION=N
CNTOOLS_TX_TOKEN_MAX_ASSETS=20
CNTOOLS_TX_UTXO_MANAGEMENT=Y
CNTOOLS_TX_COLLATERAL_MANAGEMENT=N
CNTOOLS_TX_COLLATERAL_TARGET_COUNT=1
CNTOOLS_TX_COLLATERAL_LOVELACE=5000000
CNTOOLS_TX_UTXO_TARGET_COUNT=4
CNTOOLS_TX_UTXO_PERCENTAGES=10,20,30
CNTOOLS_TX_UTXO_MAX_NEW_OUTPUTS=3
CNTOOLS_TX_UTXO_MIN_LOVELACE=2000000
"$CNTOOLS_CLI" address key-gen --verification-key-file "$PROOF_ROOT/payment.vkey" --signing-key-file "$PROOF_ROOT/payment.skey"
CNTOOLS_SEND_WALLET=audit
CNTOOLS_SEND_TYPE=CLI
CNTOOLS_SEND_VKEY="$PROOF_ROOT/payment.vkey"
CNTOOLS_SEND_SOURCE="$PROOF_ROOT/payment.skey"
CNTOOLS_SEND_CREDENTIAL="$("$CNTOOLS_CLI" address key-hash --payment-verification-key-file "$CNTOOLS_SEND_VKEY")"
CNTOOLS_SEND_ADDRESS="$("$CNTOOLS_CLI" address build --payment-verification-key-file "$CNTOOLS_SEND_VKEY" --testnet-magic 2)"
CNTOOLS_SEND_CHANGE_ADDRESS="$CNTOOLS_SEND_ADDRESS"
CNTOOLS_SEND_PAYMENT="$CNTOOLS_SEND_ADDRESS"
CNTOOLS_SEND_EXPIRY=10000
CNTOOLS_FUNDING_PROTOCOL="$REPO/files/tests/fixtures/transaction-protocol-conway.json"
CNTOOLS_FUNDING_BACKEND=koios
CNTOOLS_FUNDING_TOTAL=23000100
declare -a CNTOOLS_FUNDING_ASSET_IDS=()
declare -A CNTOOLS_FUNDING_ASSETS=()
CNTOOLS_SEND_ADDRESSES=("$CNTOOLS_SEND_ADDRESS")
CNTOOLS_SEND_AMOUNTS=(3000000)
CNTOOLS_SEND_MODE=exact
# Only bypass packaging: use the production builder, selector, change planner
# and CLI fee calculator. Sign the resulting body with the real pinned CLI.
cntools_transaction_package_create_staged_into() {
  CNTOOLS_TRANSACTION_BODY_FILE="$2"
  CNTOOLS_TRANSACTION_PACKAGE_HARDWARE_PREPARED=N
  printf -v "$1" '%s' "$2"
}
cntools_transaction_package_load() { CNTOOLS_TRANSACTION_BODY_FILE="$1"; }
cntools_utxo_reset
cntools_utxo_add "$(printf 'cc%.0s' {1..32})#0" "$CNTOOLS_SEND_ADDRESS" "$CNTOOLS_FUNDING_TOTAL"
package=''
cntools_send_build_into package
"$CNTOOLS_CLI" latest transaction sign --tx-body-file "$package" --signing-key-file "$CNTOOLS_SEND_SOURCE" --testnet-magic 2 --out-file "$PROOF_ROOT/signed.json"
actual="$("$CNTOOLS_CLI" latest transaction calculate-min-fee --tx-body-file "$PROOF_ROOT/signed.json" --witness-count 0 --protocol-params-file "$CNTOOLS_FUNDING_PROTOCOL" --reference-script-size 0 --output-text)"
actual="${actual%% *}"
signed_bytes="$(jq '.cborHex|length/2' "$PROOF_ROOT/signed.json")"
fixed_fee="$(jq '.txFeeFixed' "$CNTOOLS_FUNDING_PROTOCOL")"
fee_per_byte="$(jq '.txFeePerByte' "$CNTOOLS_FUNDING_PROTOCOL")"
ledger_minimum=$((fixed_fee + fee_per_byte * (signed_bytes - 1)))
[[ "$actual" == "$ledger_minimum" ]]
view="$("$CNTOOLS_CLI" debug transaction view --tx-file "$PROOF_ROOT/signed.json" --output-json)"
printf 'CLI: %s\n' "$("$CNTOOLS_CLI" version | head -1)"
printf 'Chosen fee: %s; actual signed minimum: %s; difference: %s\n' "$CNTOOLS_SEND_FEE" "$actual" "$((CNTOOLS_SEND_FEE - actual))"
printf 'Signed bytes: %s; independent protocol-size fee: %s\n' "$signed_bytes" "$ledger_minimum"
printf 'Final outputs: %s; change policy: %s\n' "$(jq '.outputs|length' <<< "$view")" "$CNTOOLS_CHANGE_UTXO_STATUS"
[[ "$CNTOOLS_SEND_FEE" == "$actual" ]] || { printf "Fee retained excess after optional change shrank\n" >&2; exit 1; }
# Shared-policy values count their policy key once, not once per token.
policy="$(printf 'ab%.0s' {1..28})"
output="$CNTOOLS_SEND_ADDRESS+10000000"
for ((index=0; index<150; index++)); do
  printf -v asset '%04x' "$index"
  output+=" + 1 $policy.$asset"
done
value_size=''
cntools_transaction_value_size_into value_size "$output"
(( value_size < 5000 ))
cntools_transaction_validate_change_output "$output" "$CNTOOLS_FUNDING_PROTOCOL"
# The pinned CLI accepts the same densely packed output.
"$CNTOOLS_CLI" latest transaction build-raw --tx-in "$(printf 'dd%.0s' {1..32})#0" --tx-out "$output" --fee 200000 --out-file "$PROOF_ROOT/many-assets.body"
# More than 5,000 bytes must still fail, even when all names share a policy.
for ((index=150; index<1800; index++)); do
  printf -v asset '%04x' "$index"
  output+=" + 1 $policy.$asset"
done
if cntools_transaction_validate_value_size "$output" "$CNTOOLS_FUNDING_PROTOCOL"; then
  printf 'Oversized value accepted\n' >&2; exit 1
fi
printf 'Pinned exact-fee and shared-policy value regressions passed: CLI=%s\n' "$version"
