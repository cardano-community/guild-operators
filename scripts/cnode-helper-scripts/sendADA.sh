#!/usr/bin/env bash


. $(dirname $0)/env

case $# in
  4 ) tx="$1";
    addr="$2";
    lovelace="$(( $3 * 1000000 ))";
    from_key="$4";
    from_addr=$(${CCLI} signing-key-address --real-pbft --testnet-magic $MAGIC --secret $from_key |head -1);;
  * ) cat >&2 <<EOF
Usage:  $(basename $0) <Tx-File to Create for submission> <Output Address> <Amount in ADA> <Account Key file>
EOF
  exit 1;; esac

args=" issue-genesis-utxo-expenditure
  --config              "$CONFIG"
  --tx                  ${tx}
  --wallet-key          ${from_key}
  --rich-addr-from    \"${from_addr}\"
  --txout            (\"${addr}\",${lovelace})
"

NETARGS=)
  submit-tx
  --tx "$tx"
  --config "$CONFIG"
  --socket-path "$SOCKET"

set -x

${CCLI} ${args}
${CCLI} ${NETARGS[*]}

