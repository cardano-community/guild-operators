#!/bin/bash
DB_NAME=cexplorer
NWMAGIC=
EPOCH_LENGTH=
PROM_URL=
CCLI=
export CARDANO_NODE_SOCKET_PATH=

echo "$(date +%F_%H:%M:%S) Running next epoch nonce calculation..."

min_slot=$((EPOCH_LENGTH * 7 / 10))
current_epoch=$(curl -s "${PROM_URL}" | grep epoch | awk '{print $2}')
current_slot_in_epoch=$(curl -s "${PROM_URL}" | grep slotInEpoch | awk '{print $2}')
next_epoch=$((current_epoch + 1))

[[ ${current_slot_in_epoch} -ge ${min_slot} ]] &&
  next_epoch_nonce=$(echo "$(${CCLI} query protocol-state --testnet-magic "${NWMAGIC}" | jq -r .candidateNonce.contents)$(${CCLI} query protocol-state --testnet-magic "${NWMAGIC}" | jq -r .lastEpochBlockNonce.contents)" | xxd -r -p | b2sum -b -l 256 | awk '{print $1}') &&
  psql ${DB_NAME} -c "INSERT INTO grest.epoch_info_cache (epoch_no, p_nonce) VALUES (${next_epoch}, '${next_epoch_nonce}') ON CONFLICT DO NOTHING;"

echo "$(date +%F_%H:%M:%S) Job done!"
