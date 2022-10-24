#!/bin/bash
DB_NAME=cexplorer
NWMAGIC=
EPOCH_LENGTH=
PROM_URL=

min_slot=$((EPOCH_LENGTH * 7 / 10))
current_epoch=$(cardano-cli query tip --testnet-magic "${NWMAGIC}" | jq -r .epoch)
current_slot_in_epoch=$(curl -s "${PROM_URL}" | grep slotInEpoch | awk '{print $2}')

[[ ${current_slot_in_epoch} -ge ${min_slot} ]] &&
  next_epoch_nonce=$(echo "$(cardano-cli query protocol-state --testnet-magic "${NWMAGIC}" | jq -r .candidateNonce.contents)$(cardano-cli query protocol-state --testnet-magic "${NWMAGIC}" | jq -r .lastEpochBlockNonce.contents)" | xxd -r -p | b2sum -b -l 256 | awk '{print $1}') &&
  psql ${DB_NAME} -qbt -c "INSERT INTO grest.epoch_info_cache (epoch_no, p_nonce) VALUES ($((current_epoch + 1)), ${next_epoch_nonce}) ON CONFLICT DO NOTHING;"
