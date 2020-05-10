#!/usr/bin/env bash


. $(dirname $0)/env

case $# in
  4 ) tx="$1";
    outaddr="$2";
    lovelace="$(( $3 * 1000000 ))";
    from_key="$4";
    from_addr=$(${CCLI} signing-key-address --real-pbft --testnet-magic $MAGIC --secret $from_key |head -1);;
  * ) cat >&2 <<EOF
Usage:  $(basename $0) <Tx-File to Create for submission> <Output Address> <Amount in ADA> <Account Key file>
EOF
  exit 1;; esac

#TODO : Update fee and ttl dynamically
args=" shelley transaction build-raw 
  --config              "$CONFIG" 
  --tx-in               ${inaddr}#${idx}
  --tx-out              ${outaddr}
  --ttl                 1000
  --fee                 100000
  --tx-body-file        ${tx}
"

NETARGS=(
  submit-tx
  --tx "$tx"
  --config "$CONFIG"
)

set -x

${CCLI} ${args}
${CCLI} ${NETARGS[*]}

