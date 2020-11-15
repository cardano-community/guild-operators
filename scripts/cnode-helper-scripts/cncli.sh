#!/bin/bash
#shellcheck disable=SC2086
#shellcheck source=/dev/null

[[ -z "${CNODE_HOME}" ]] && CNODE_HOME="/opt/cardano/cnode"

. "${CNODE_HOME}"/scripts/env

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

POOL_ID=""                                # Required for leaderlog calculation & pooltool sendtip, lower-case hex pool id
POOL_VRF_SKEY=""                          # Required for leaderlog calculation, path to pool's vrf.skey file
POOL_VRF_VKEY=""                          # Required for block validation, path to pool's vrf.vkey file
PT_API_KEY=""                             # POOLTOOL sendtip: set API key, e.g "a47811d3-0008-4ecd-9f3e-9c22bdb7c82d"
POOL_TICKER=""                            # POOLTOOL sendtip: set the pools ticker, e.g "TCKR"
#PT_HOST="127.0.0.1"                      # POOLTOOL sendtip: connect to a remote node, preferably block producer (default localhost)
#PT_PORT="${CNODE_PORT}"                  # POOLTOOL sendtip: port of node to connect to (default CNODE_PORT from env file)
#CNCLI_DIR="${CNODE_HOME}/guild-db/cncli" # path to folder for cncli sqlite db
#LIBSODIUM_FORK=/usr/local/lib            # path to folder for IOG fork of libsodium
#SLEEP_RATE=60                            # CNCLI leaderlog/validate: time to wait until next check (in seconds)
#CONFIRM_SLOT_CNT=300                     # CNCLI validate: require at least these many slots to have passed before validating
#CONFIRM_BLOCK_CNT=10                     # CNCLI validate: require at least these many blocks on top of minted before validating
#TIMEOUT_LEDGER_STATE=300                 # CNCLI leaderlog: timeout in seconds for ledger-state query

######################################
# Do NOT modify code below           #
######################################

usage() {
  cat <<EOF >&2

Usage: $(basename "$0") [sync] [leaderlog] [validate [all] [epoch]] [ptsendtip] [migrate <path>]
Script to run CNCLI, best launched through systemd deployed by 'deploy-as-systemd.sh'

sync        Start CNCLI chainsync process that connects to cardano-node to sync blocks stored in SQLite DB (deployed as service)
leaderlog   One-time leader schedule calculation for current epoch, 
            then continously monitors and calculates schedule for coming epochs, 1.5 days before epoch boundary on MainNet (deployed as service)
validate    Continously monitor and confirm that the blocks made actually was accepted and adopted by chain (deployed as service)
  all       One-time re-validation of all blocks in blocklog db
  epoch     One-time re-validation of blocks in blocklog db for the specified epoch 
ptsendtip   Send node tip to PoolTool for network analysis and to show that your node is alive and well with a green badge (deployed as service)
init        One-time initialization adding all minted and confirmed blocks to blocklog
migrate     One-time migration from old blocklog(cntoolsBlockCollector) to new format (post cncli)
  path      Path to the old cntoolsBlockCollector blocklog folder holding json files with blocks created

EOF
  exit 1
}

if [[ $# -eq 1 ]]; then
  subcommand=$1
  subarg=""
elif [[ $# -eq 2 ]]; then
  subcommand=$1
  subarg=$2
else usage; fi

#################################
# helper functions

getNodeMetrics() {
  curl -s -m "${EKG_TIMEOUT}" -H 'Accept: application/json' "http://${EKG_HOST}:${EKG_PORT}/" 2>/dev/null
}

getEpoch() {
  jq -r '.cardano.node.ChainDB.metrics.epoch.int.val //0' <<< "${node_metrics}"
}

getBlockTip() {
  jq -r '.cardano.node.ChainDB.metrics.blockNum.int.val //0' <<< "${node_metrics}"
}

getSlotTip() {
  jq -r '.cardano.node.ChainDB.metrics.slotNum.int.val //0' <<< "${node_metrics}"
}

getSlotInEpoch() {
  jq -r '.cardano.node.ChainDB.metrics.slotInEpoch.int.val //0' <<< "${node_metrics}"
}

getEpochFromSlot() {
  slotnum=$1
  echo $(( shelley_transition_epoch + ((slotnum - (shelley_transition_epoch * BYRON_EPOCH_LENGTH)) / EPOCH_LENGTH) ))
}

getSlotInEpochFromSlot() {
  slotnum=$1
  epoch=$2
  echo $(( slotnum - ((shelley_transition_epoch * BYRON_EPOCH_LENGTH) + ((epoch - shelley_transition_epoch) * EPOCH_LENGTH )) ))
}

getDateFromSlot() {
  slotnum=$1
  byron_slots=$(( shelley_transition_epoch * BYRON_EPOCH_LENGTH ))
  printf -v date_from_slot '%(%FT%T%z)T' $(( (byron_slots * BYRON_SLOT_LENGTH) + ((slotnum-byron_slots) * SLOT_LENGTH) + SHELLEY_GENESIS_START_SEC ))
  echo "${date_from_slot%??}:${date_from_slot: -2}"
}

cncliDBinSync() { # node_metrics=$(getNodeMetrics) && slot_tip=$(getSlotTip) expected to have been already run
  cncli_tip=$(sqlite3 "${CNCLI_DB}" "SELECT slot_number FROM chain ORDER BY slot_number DESC LIMIT 1;")
  cncli_sync_prog=$(echo "( ${cncli_tip} / ${slot_tip} ) * 100" | bc -l)
  (( $(echo "${cncli_sync_prog} > 99.999" |bc -l) ))
}

getPoolVrfVkeyCborHex() {
  pool_vrf_vkey_cbox_hex=''
  if [[ -f ${POOL_VRF_VKEY} ]] && pool_vrf_vkey_cbox_hex=$(jq -er .cborHex "${POOL_VRF_VKEY}"); then
    pool_vrf_vkey_cbox_hex=${pool_vrf_vkey_cbox_hex:4} # strip 5820 from beginning
  else
    echo "ERROR: unable to locate the pools VRF vkey file or extract cbox hex string from: ${POOL_VRF_VKEY}"
    return 1
  fi
}

dumpLedgerState() {
  ledger_state_file="/tmp/ledger-state_$(getEpoch).json"
  [[ -f ${ledger_state_file} ]] && return 0 # no need to continue, we have a current ledger-state already
  rm -f /tmp/ledger-state* # remove old ledger dumps before creating a new
  if ! timeout -k 5 "${TIMEOUT_LEDGER_STATE}" ${CCLI} shelley query ledger-state ${PROTOCOL_IDENTIFIER} ${NETWORK_IDENTIFIER} --out-file "${ledger_state_file}"; then
    echo "ERROR: ledger dump failed/timed out, increase timeout value"
    [[ -f "${ledger_state_file}" ]] && rm -f "${ledger_state_file}"
    return 1
  fi
  return 0
}

# Command    : getShelleyTransitionEpoch
# Description: Calculate shelley transition epoch
getShelleyTransitionEpoch() {
  calc_slot=0
  node_metrics=$(getNodeMetrics)
  slotnum=$(getSlotTip)
  slot_in_epoch=$(getSlotInEpoch)
  byron_epochs=$(getEpoch)
  shelley_epochs=0
  while [[ ${byron_epochs} -ge 0 ]]; do
    calc_slot=$(( (byron_epochs * BYRON_EPOCH_LENGTH) + (shelley_epochs * EPOCH_LENGTH) + slot_in_epoch ))
    [[ ${calc_slot} -eq ${slotnum} ]] && break
    ((byron_epochs--))
    ((shelley_epochs++))
  done
  if [[ "${NWMAGIC}" = "764824073" ]]; then
    shelley_transition_epoch=208
  elif [[ ${calc_slot} -ne ${slotnum} || ${shelley_epochs} -eq 0 ]]; then
    shelley_transition_epoch=-1
    return 1
  else
    shelley_transition_epoch=${byron_epochs}
  fi
}

# Command    : getSlotTipRef
# Description: Get calculated slot number tip
getSlotTipRef() {
  current_time_sec=$(date -u +%s)
  if [[ "${PROTOCOL}" = "Cardano" ]]; then
    # Combinator network
    byron_slots=$(( shelley_transition_epoch * BYRON_EPOCH_LENGTH )) # since this point will only be reached once we're in Shelley phase
    byron_end_time=$(( BYRON_GENESIS_START_SEC + ( shelley_transition_epoch * BYRON_EPOCH_LENGTH * BYRON_SLOT_LENGTH ) ))
    if [[ "${current_time_sec}" -lt "${byron_end_time}" ]]; then
      # In Byron phase
      echo $(( ( current_time_sec - BYRON_GENESIS_START_SEC ) / BYRON_SLOT_LENGTH ))
    else
      # In Shelley phase
      echo $(( byron_slots + (( current_time_sec - byron_end_time ) / SLOT_LENGTH ) ))
    fi
  else
    # Shelley Mode only, no Byron slots
    echo $(( ( current_time_sec - SHELLEY_GENESIS_START_SEC ) / SLOT_LENGTH ))
  fi
}

#################################

cncliInit() {
  [[ -z "${CNCLI_DIR}" ]] && CNCLI_DIR="${CNODE_HOME}/guild-db/cncli"
  CNCLI_DB="${CNCLI_DIR}/cncli.db"
  [[ -z "${LIBSODIUM_FORK}" ]] && LIBSODIUM_FORK=/usr/local/lib
  export LD_LIBRARY_PATH="${LIBSODIUM_FORK}:${LD_LIBRARY_PATH}"
  [[ -z "${SLEEP_RATE}" ]] && SLEEP_RATE=60
  [[ -z "${CONFIRM_SLOT_CNT}" ]] && CONFIRM_SLOT_CNT=300
  [[ -z "${CONFIRM_BLOCK_CNT}" ]] && CONFIRM_BLOCK_CNT=10
  [[ -z "${TIMEOUT_LEDGER_STATE}" ]] && TIMEOUT_LEDGER_STATE=300
  [[ -z "${PT_HOST}" ]] && PT_HOST="127.0.0.1"
  [[ -z "${PT_PORT}" ]] && PT_PORT="${CNODE_PORT}"

  PARENT="$(dirname $0)"
  if [[ ! -f "${PARENT}"/env ]]; then
    echo "ERROR: could not find common env file, please update and run 'prereqs.sh -h' to show options"
    exit 1
  fi
  if ! . "${PARENT}"/env; then exit 1; fi
  
  [[ ! -f "${CNCLI}" ]] && echo "ERROR: failed to locate cncli executable, please update and run 'prereqs.sh -h' to show options" && exit 1
  
  if [[ $(grep "_HOME=" "${PARENT}"/env) =~ ^#?([^[:space:]]+)_HOME ]]; then
    vname=$(tr '[:upper:]' '[:lower:]' <<< "${BASH_REMATCH[1]}")
  else
    echo "failed to get cnode instance name from env file, aborting!"
    exit 1
  fi
  
  return 0
}

#################################

cncliSync() {
  if ! mkdir -p "${CNCLI_DIR}"; then echo "ERROR: failed to create CNCLI DB folder: ${CNCLI_DIR}" && exit 1; fi
  ${CNCLI} sync --host 127.0.0.1 --network-magic "${NWMAGIC}" --port "${CNODE_PORT}" --db "${CNCLI_DB}"
}

#################################

cncliLeaderlog() {
  echo "~ CNCLI Leaderlog started ~"
  createBlocklogDB || exit 1 # create db if needed
  [[ -z ${POOL_ID} || -z ${POOL_VRF_SKEY} ]] && echo "'POOL_ID' and/or 'POOL_VRF_SKEY' not set in $(basename "$0"), exiting!" && exit 1
  
  shelley_transition_epoch=-1
  while true; do
    if [[ ${shelley_transition_epoch} -lt 0 ]]; then
      if ! getShelleyTransitionEpoch; then 
        echo "Failed to calculate shelley transition epoch, checking again in ${SLEEP_RATE}s"
      else
        echo "Shelley transition epoch found: ${shelley_transition_epoch}"
      fi
    else
      node_metrics=$(getNodeMetrics)
      slot_tip=$(getSlotTip)
      tip_diff=$(( $(getSlotTipRef) - slot_tip ))
      if [[ ${tip_diff} -gt 300 ]]; then # Node considered in sync if less than 300 slots from theoretical tip
        echo "Node still syncing, ${tip_diff} slots from theoretical tip, checking again in ${SLEEP_RATE}s"
      elif ! cncliDBinSync; then
        echo "CNCLI still syncing [$(printf "%2.4f %%" ${cncli_sync_prog})], checking again in ${SLEEP_RATE}s"
      else
        break
      fi
    fi
    sleep ${SLEEP_RATE}
  done
  
  echo "Node in sync, sleeping for ${SLEEP_RATE}s before running leaderlogs for current epoch"
  sleep ${SLEEP_RATE}
  node_metrics=$(getNodeMetrics)
  slot_tip=$(getSlotTip)
  curr_epoch=$(getEpoch)
  echo "Running leaderlogs for epoch ${curr_epoch} and adding leader slots not already in DB"
  if ! dumpLedgerState; then exit 1; fi
  cncli_leaderlog=$(${CNCLI} leaderlog --db "${CNCLI_DB}" --byron-genesis "${BYRON_GENESIS_JSON}" --shelley-genesis "${GENESIS_JSON}" --ledger-set current --ledger-state "${ledger_state_file}" --pool-id "${POOL_ID}" --pool-vrf-skey "${POOL_VRF_SKEY}" --tz UTC)
  if [[ $(jq -r .status <<< "${cncli_leaderlog}") != ok ]]; then
    error_msg=
    if [[ "${error_msg}" = "Query returned no rows" ]]; then
      echo "No leader slots found for epoch ${curr_epoch} :("
    else
      echo "ERROR: failure in leaderlog while running:"
      echo "${CNCLI} leaderlog --db ${CNCLI_DB} --byron-genesis ${BYRON_GENESIS_JSON} --shelley-genesis ${GENESIS_JSON} --ledger-set current --ledger-state ${ledger_state_file} --pool-id ${POOL_ID} --pool-vrf-skey ${POOL_VRF_SKEY} --tz UTC"
      echo "Error message: $(jq -r '.errorMessage //empty' <<< "${cncli_leaderlog}")"
      exit 1
    fi
  fi
  while read -r assigned_slot; do
    block_slot=$(jq -r '.slot' <<< "${assigned_slot}")
    block_at=$(jq -r '.at' <<< "${assigned_slot}")
    block_slot_in_epoch=$(jq -r '.slotInEpoch' <<< "${assigned_slot}")
    sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO blocklog (slot,at,slot_in_epoch,epoch,status) values (${block_slot},'${block_at}',${block_slot_in_epoch},${curr_epoch},'leader');"
    echo "LEADER: slot[${block_slot}] slotInEpoch[${block_slot_in_epoch}] at[${block_at}]"
  done < <(jq -c '.assignedSlots[]' <<< "${cncli_leaderlog}" 2>/dev/null)
  
  has_run_leader=false
  while true; do
    sleep ${SLEEP_RATE}
    node_metrics=$(getNodeMetrics)
    slot_tip=$(getSlotTip)
    if ! cncliDBinSync; then # verify that cncli DB is still in sync
      echo "CNCLI DB out of sync :( [$(printf "%2.4f %%" ${cncli_sync_prog})] ... checking again in ${SLEEP_RATE}s"
      continue
    fi
    if [[ ${has_run_leader} = true ]]; then
      [[ $(getSlotInEpoch) -ge ${slot_in_epoch} ]] && continue # leaderlog already run and still same epoch
      has_run_leader=false # new epoch, reset flag
    fi
    slot_in_epoch=$(getSlotInEpoch)
    slot_for_next_nonce=$(echo "(${slot_tip} - ${slot_in_epoch} + ${EPOCH_LENGTH}) - (3 * ${BYRON_K} / ${ACTIVE_SLOTS_COEFF})" | bc) # firstSlotOfNextEpoch - stabilityWindow(3 * k / f)
    curr_epoch=$(getEpoch)
    next_epoch=$((curr_epoch+1))
    if [[ ${slot_tip} -gt ${slot_for_next_nonce} ]]; then # Run leaderlogs for next epoch
      echo "Running leaderlogs for next epoch[${next_epoch}]"
      if ! dumpLedgerState; then sleep 600; continue; fi # Sleep for 10 min before trying to dump ledger-state in case of error
      cncli_leaderlog=$(${CNCLI} leaderlog --db "${CNCLI_DB}" --byron-genesis "${BYRON_GENESIS_JSON}" --shelley-genesis "${GENESIS_JSON}" --ledger-set next --ledger-state "${ledger_state_file}" --pool-id "${POOL_ID}" --pool-vrf-skey "${POOL_VRF_SKEY}" --tz UTC)
      if [[ $(jq -r .status <<< "${cncli_leaderlog}") != ok ]]; then
        if [[ "${error_msg}" = "Query returned no rows" ]]; then
          echo "No leader slots found for epoch ${curr_epoch} :("
        else
          echo "ERROR: failure in leaderlog while running:"
          echo "${CNCLI} leaderlog --db ${CNCLI_DB} --byron-genesis ${BYRON_GENESIS_JSON} --shelley-genesis ${GENESIS_JSON} --ledger-set next --ledger-state ${ledger_state_file} --pool-id ${POOL_ID} --pool-vrf-skey ${POOL_VRF_SKEY} --tz UTC"
          echo "Error message: $(jq -r '.errorMessage //empty' <<< "${cncli_leaderlog}")"
        fi
      else
        while read -r assigned_slot; do
          block_slot=$(jq -r '.slot' <<< "${assigned_slot}")
          block_at=$(jq -r '.at' <<< "${assigned_slot}")
          block_slot_in_epoch=$(jq -r '.slotInEpoch' <<< "${assigned_slot}")
          sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO blocklog (slot,at,slot_in_epoch,epoch,status) values (${block_slot},'${block_at}',${block_slot_in_epoch},${next_epoch},'leader');"
          echo "LEADER: slot[${block_slot}] slotInEpoch[${block_slot_in_epoch}] at[${block_at}]"
        done < <(jq -c '.assignedSlots[]' <<< "${cncli_leaderlog}" 2>/dev/null)
        echo "Leaderlogs calculation for next epoch[${next_epoch}] completed and saved to blocklog DB"
      fi
      has_run_leader=true
    fi
  done
}

#################################

cncliValidate() {
  echo "~ CNCLI Block Validation started ~"
  if ! getPoolVrfVkeyCborHex; then exit 1; fi # We need this to properly validate block
  createBlocklogDB || exit 1 # create db if needed
  if ! getShelleyTransitionEpoch; then echo "ERROR: failed to calculate shelley transition epoch" && exit 1; fi
  if [[ -n ${subarg} ]]; then
    node_metrics=$(getNodeMetrics)
    slot_tip=$(getSlotTip)
    if ! cncliDBinSync; then # verify that cncli DB is still in sync
      echo "CNCLI DB out of sync :( [$(printf "%2.4f %%" ${cncli_sync_prog})] ... check cncli sync service!"
      exit 1
    fi
    tip_diff=$(( $(getSlotTipRef) - slot_tip ))
    [[ ${tip_diff} -gt 300 ]] && echo "ERROR: node still syncing, ${tip_diff} slots from theoretical tip" && exit 1
    block_tip=$(getBlockTip)
    epoch=0
    epoch_selection=""
    if [[ ${subarg} =~ ^[0-9]+$ ]]; then
      epoch_selection="WHERE epoch = ${subarg}"
    elif [[ ${subarg} != "all" ]]; then
      echo "ERROR: unknown argument passed to validate command, valid options incl the string 'all' or the epoch number to validate"
      exit 1
    fi
    while read -r block_epoch block_slot block_status block_hash; do
      [[ ${epoch} -ne ${block_epoch} ]] && echo -e "> Validating epoch ${FG_GREEN}${block_epoch}${NC}" && epoch=${block_epoch}
      [[ ${block_status} != invalid ]] && block_status="leader" # reset status to leader to re-validate all non invalid blocks
      validateBlock
    done < <(sqlite3 -column "${BLOCKLOG_DB}" "SELECT epoch, slot, status, hash FROM blocklog ${epoch_selection} ORDER BY slot;")
  elif [[ -n ${subarg} ]]; then
    echo "ERROR: unknown argument passed to validate subcommand" && usage
  else
    while true; do
      sleep ${SLEEP_RATE}
      node_metrics=$(getNodeMetrics)
      slot_tip=$(getSlotTip)
      if ! cncliDBinSync; then # verify that cncli DB is still in sync
        echo "CNCLI DB out of sync :( [$(printf "%2.4f %%" ${cncli_sync_prog})] ... checking again in ${SLEEP_RATE}s"
        continue
      fi
      block_tip=$(getBlockTip)
      curr_epoch=$(getEpoch)
      prev_epoch=$((curr_epoch-1))
      # Check both previous epoch and current to catch epoch boundary cases
      while read -r block_epoch block_slot block_status block_hash; do
        validateBlock
      done < <(sqlite3 -column "${BLOCKLOG_DB}" "SELECT epoch, slot, status, hash FROM blocklog WHERE epoch BETWEEN ${prev_epoch} and ${curr_epoch} ORDER BY slot;")
    done
  fi
}

validateBlock() {
  [[ ${block_status} = invalid ]] && return
  if [[ ${block_status} = leader || ${block_status} = adopted ]]; then
    [[ ${block_slot} -gt ${slot_tip} ]] && return # block in the future, wait
    slot_ok_cnt=$(sqlite3 "${CNCLI_DB}" "SELECT COUNT(*) FROM chain WHERE slot_number=${block_slot} AND orphaned=0;")
    IFS='|' && read -ra block_data <<< "$(sqlite3 "${CNCLI_DB}" "SELECT block_number, hash, block_size, orphaned FROM chain WHERE slot_number = ${block_slot} AND node_vrf_vkey;")" && IFS=' '
    if [[ ${block_status} = leader && $((block_slot + CONFIRM_SLOT_CNT)) -le ${slot_tip} ]]; then # just check if block was adopted
      if [[ ${#block_data[@]} -eq 1 ]]; then
        echo "ADOPTED: Leader for slot '${block_slot}' and adopted by chain, waiting for confirmation"
        sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'adopted', slot_in_epoch = $(getSlotInEpochFromSlot ${block_slot} ${block_epoch}), block = ${block_data[0]}, at = '$(getDateFromSlot ${block_slot})', hash = '${block_data[1]}', size = ${block_data[2]} WHERE slot = ${block_slot};"
      fi
    fi
    [[ $((block_tip-${block_data[0]})) -lt ${CONFIRM_BLOCK_CNT} ]] && return # To make sure enough blocks has been built on top before validating
    if [[ ${#block_data[@]} -eq 0 ]]; then
      if [[ ${slot_ok_cnt} -eq 0 ]]; then
        echo "MISSED: Leader for slot '${block_slot}' but not adopted and no other pool has made a block for this slot"
        sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'missed' WHERE slot = ${block_slot};"
      else
        echo "STOLEN: Leader for slot '${block_slot}' but \"stolen\" by another pool due to bad luck (lower VRF output) :("
        sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'stolen' WHERE slot = ${block_slot};"
      fi
    else
      if [[ ${block_data[3]} -eq 0 ]]; then
        echo "CONFIRMED: Leader for slot '${block_slot}' and match found in CNCLI DB for this slot with pool's VRF public key"
        sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'confirmed', slot_in_epoch = $(getSlotInEpochFromSlot ${block_slot} ${block_epoch}), block = ${block_data[0]}, at = '$(getDateFromSlot ${block_slot})', hash = '${block_data[1]}', size = ${block_data[2]} WHERE slot = ${block_slot};"
      else
        if [[ ${slot_ok_cnt} -eq 0 ]]; then
          echo "GHOSTED: Leader for slot '${block_slot}' and block adopted but later orphaned. No other pool with a confirmed block for this slot, height battle or block propagation issue!"
          sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'ghosted' WHERE slot = ${block_slot};"
        else
          echo "STOLEN: Leader for slot '${block_slot}' but \"stolen\" by another pool due to bad luck (lower VRF output) :("
          sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'stolen' WHERE slot = ${block_slot};"
        fi
      fi
    fi
  fi
}

#################################

cncliInitBlocklogDB() {
  [[ "${PROTOCOL}" != "Cardano" ]] && echo "ERROR: protocol not Cardano mode, not a valid network" && exit 1
  if ! getPoolVrfVkeyCborHex; then exit 1; fi
  if ! getShelleyTransitionEpoch; then echo "ERROR: failed to calculate shelley transition epoch" && exit 1; fi
  node_metrics=$(getNodeMetrics)
  slot_tip=$(getSlotTip)
  if ! cncliDBinSync; then # verify that cncli DB is still in sync
    echo "CNCLI DB out of sync :( [$(printf "%2.4f %%" ${cncli_sync_prog})] ... check cncli sync service!"
    exit 1
  fi
  tip_diff=$(( $(getSlotTipRef) - slot_tip ))
  [[ ${tip_diff} -gt 300 ]] && echo "ERROR: node still syncing, ${tip_diff} slots from theoretical tip" && exit 1
  createBlocklogDB || exit 1 # create db if needed
  echo "Looking for blocks made by pool..."
  block_cnt=0
  while read -r block_number slot_number hash block_size orphaned; do
    # Calculate epoch, at and slot_in_epoch
    epoch=$(getEpochFromSlot ${slot_number})
    at=$(getDateFromSlot ${slot_number})
    slot_in_epoch=$(getSlotInEpochFromSlot ${slot_number} ${epoch})
    sqlite3 "${BLOCKLOG_DB}" "INSERT OR REPLACE INTO blocklog (slot,at,epoch,block,slot_in_epoch,hash,size,status) values (${slot_number},'${at}',${epoch},${block_number},${slot_in_epoch},'${hash}',${block_size},'adopted');"
    ((block_cnt++))
  done < <(sqlite3 -column "${CNCLI_DB}" "SELECT block_number, slot_number, hash, block_size, orphaned FROM chain WHERE node_vrf_vkey = '${pool_vrf_vkey_cbox_hex}' ORDER BY slot_number;")
  if [[ ${block_cnt} -eq 0 ]]; then
    echo "No blocks found :("
  else
    echo "Successfully added/updated ${block_cnt} blocks in blocklog DB!"
    echo "Validating all blocks..."
    subarg="all"
    cncliValidate
  fi
}

#################################

cncliMigrateBlocklog() {
  [[ ! -d ${subarg} ]] && echo -e "\nERROR: unable to locate directory holding cntoolsBlockCollector blocklog json files:\n${subarg}" && usage
  if ! getShelleyTransitionEpoch; then echo "ERROR: failed to calculate shelley transition epoch" && exit 1; fi
  createBlocklogDB || exit 1 # create db if needed
  while IFS= read -r -d '' blocks_file; do
    echo "> Migrating: $(basename "${blocks_file}")"
    [[ ${blocks_file} =~ blocks_([0-9]+) ]] && epoch=${BASH_REMATCH[1]} || epoch=0
    blocks_data="$(cat "${blocks_file}")"
    while read -r block; do
      block_slot=$(jq -r '.slot' <<< "${block}")
      block_at=$(jq -r '.at' <<< "${block}" | sed 's/\.[0-9]\{2\}Z/+00:00/')
      block_hash=$(jq -r '.hash //empty' <<< "${block}")
      block_size=$(jq -r '.size //0' <<< "${block}")
      slot_in_epoch=$(getSlotInEpochFromSlot ${block_slot} ${epoch})
      if [[ -n ${block_hash} ]]; then
        [[ ${block_hash} =~ ^Invalid ]] && block_status="invalid" || block_status="adopted"
        sqlite3 "${BLOCKLOG_DB}" "INSERT OR REPLACE INTO blocklog (slot,slot_in_epoch,at,epoch,size,hash,status) values (${block_slot},${slot_in_epoch},'${block_at}',${epoch},${block_size},'${block_hash}','${block_status}');"
      else
        block_status="leader"
        sqlite3 "${BLOCKLOG_DB}" "INSERT OR REPLACE INTO blocklog (slot,slot_in_epoch,at,epoch,status) values (${block_slot},${slot_in_epoch},'${block_at}',${epoch},'leader');"
      fi
      echo "Block at slot ${block_slot} added/updated, status '${block_status}'"
    done < <(jq -c '.[]' <<< "${blocks_data}" 2>/dev/null)
  done < <(find "${subarg}" -mindepth 1 -maxdepth 1 -type f -name "blocks_*.json" -print0 | sort -z)
}

#################################

cncliPTsendtip() {
  [[ -z ${POOL_ID} || -z ${POOL_TICKER} || -z ${PT_API_KEY} ]] && echo "'POOL_ID' and/or 'POOL_TICKER' and/or 'PT_API_KEY' not set in $(basename "$0"), exiting!" && exit 1
  # Generate a temporary pooltool config
  if ! cnode_path=$(command -v cardano-node 2>/dev/null); then
    echo "ERROR: cardano-node not in PATH, please manually set CCLI in env file"
    exit 1
  fi
  pt_config="/tmp/${vname}-ptsendtip.json"
  bash -c "cat << 'EOF' > ${pt_config}
{
  \"api_key\": \"${PT_API_KEY}\",
  \"pools\": [
    {
      \"name\": \"${POOL_TICKER}\",
      \"pool_id\": \"${POOL_ID}\",
      \"host\" : \"${PT_HOST}\",
      \"port\": ${PT_PORT}
    }
  ]
}
EOF"
  ${CNCLI} sendtip --config "${pt_config}" --cardano-node "${cnode_path}"
}

#################################

case ${subcommand} in
  sync ) 
    cncliInit && cncliSync ;;
  leaderlog )
    cncliInit && cncliLeaderlog ;;
  validate )
    cncliInit && cncliValidate ;;
  ptsendtip )
    cncliInit && cncliPTsendtip ;;
  init )
    cncliInit && cncliInitBlocklogDB ;;
  migrate )
    cncliInit && cncliMigrateBlocklog ;;
  * ) usage ;;
esac