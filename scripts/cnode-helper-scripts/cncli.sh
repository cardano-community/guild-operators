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
PT_API_KEY=""                             # POOLTOOL sendtip: set API key, e.g "a47811d3-0008-4ecd-9f3e-9c22bdb7c82d"
POOL_TICKER=""                            # POOLTOOL sendtip: set the pools ticker, e.g "TCKR"
#PT_HOST="127.0.0.1"                      # POOLTOOL sendtip: connect to a remote node, preferably block producer (default localhost)
#PT_PORT="${CNODE_PORT}"                  # POOLTOOL sendtip: port of node to connect to (default CNODE_PORT from env file)
#CNCLI_DB="${CNODE_HOME}/guild-db/cncli"  # path to folder for cncli sqlite db 
#LIBSODIUM_FORK=/usr/local/lib            # path to folder for IOG fork of libsodium
#SLEEP_RATE=20                            # CNCLI leaderlog/validate: time to wait until next check (in seconds)
#CONFIRM_SLOT_CNT=300                     # CNCLI validate: require at least these many slots to have passed before validating
#CONFIRM_BLOCK_CNT=10                     # CNCLI validate: require at least these many blocks on top of minted before validating
#TIMEOUT_LEDGER_STATE=300                 # CNCLI leaderlog: timeout in seconds for ledger-state query

######################################
# Do NOT modify code below           #
######################################

usage() {
  cat <<EOF >&2

Usage: $(basename "$0") [sync] [leaderlog] [validate] [ptsendtip] [migrate]
Script to run CNCLI, best launched through systemd deployed by 'deploy-as-systemd.sh'

sync        Start CNCLI chainsync process that connects to cardano-node to sync blocks stored in SQLite DB
leaderlog   Loops through all slots in current epoch to calculate leader schedule
validate    Confirms that the block made actually was accepted and adopted by chain
ptsendtip   Send node tip to PoolTool for network analysis and to show that your node is alive and well with a green badge
migrate     command to migrate old blocklog(cntoolsBlockCollector) to new format (post cncli)

EOF
  exit 1
}

if [[ $# -eq 1 ]]; then subcommand=$1; else usage; fi

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
  [[ -z "${CNCLI_DB}" ]] && CNCLI_DB="${CNODE_HOME}/guild-db/cncli"
  if ! mkdir -p "${CNCLI_DB}"; then echo "ERROR: failed to create CNCLI DB folder: ${CNCLI_DB}" && exit 1; fi
  CNCLI_DB="${CNCLI_DB}/cncli.db"
  [[ -z "${LIBSODIUM_FORK}" ]] && LIBSODIUM_FORK=/usr/local/lib
  export LD_LIBRARY_PATH="${LIBSODIUM_FORK}:${LD_LIBRARY_PATH}"
  [[ -z "${SLEEP_RATE}" ]] && SLEEP_RATE=20
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
  ${CNCLI} sync --host 127.0.0.1 --network-magic "${NWMAGIC}" --port "${CNODE_PORT}" --db "${CNCLI_DB}"
}

#################################

cncliLeaderlog() {
  echo "~ CNCLI Leaderlog started ~"
  [[ -z ${POOL_ID} || -z ${POOL_VRF_SKEY} ]] && echo "'POOL_ID' and/or 'POOL_VRF_SKEY' not set in $(basename "$0"), exiting!" && exit 1
  while true; do
    getShelleyTransitionEpoch
    if [[ ${shelley_transition_epoch} -lt 0 ]]; then
      echo "Failed to calculate shelley transition epoch, checking again in ${SLEEP_RATE}s"
    else
      echo "Shelley transition epoch found: ${shelley_transition_epoch}"
      node_metrics=$(getNodeMetrics)
      slot_tip=$(getSlotTip)
      tip_diff=$(( $(getSlotTipRef) - $(getSlotTip) ))
      [[ ${tip_diff} -lt 300 ]] && break # Node considered in sync if less than 300 slots from theoretical tip
      echo "Node still in sync, ${tip_diff} slots from theoretical tip, checking again in ${SLEEP_RATE}s"
    fi
    sleep ${SLEEP_RATE}
  done
  echo "Node in sync, running leaderlogs for current epoch and merging with existing data if available"
  first_run="true"
  slot_in_epoch=$(getSlotInEpoch)
  # firstSlotOfNextEpoch - stabilityWindow(3 * k / f)
  slot_for_next_nonce=$(echo "(${slot_tip} - ${slot_in_epoch} + ${EPOCH_LENGTH}) - (3 * ${BYRON_K} / ${ACTIVE_SLOTS_COEFF})" | bc)
  while true; do
    sleep ${SLEEP_RATE}
    node_metrics=$(getNodeMetrics)
    curr_epoch=$(getEpoch)
    next_epoch=$((curr_epoch+1))
    slot_tip=$(getSlotTip)
    slot_in_epoch=$(getSlotInEpoch)
    if [[ ${first_run} = "true" ]]; then # First startup, run leaderlogs for current epoch and merge with current data if it exist
      blocks_file="${BLOCKLOG_DIR}/blocks_${curr_epoch}.json"
      if ! dumpLedgerState; then sleep 300; continue; fi
      cncli_leaderlog=$(${CNCLI} leaderlog --db "${CNCLI_DB}" --byron-genesis "${BYRON_GENESIS_JSON}" --shelley-genesis "${GENESIS_JSON}" --ledger-set current --ledger-state "${ledger_state_file}" --pool-id "${POOL_ID}" --pool-vrf-skey "${POOL_VRF_SKEY}")
      [[ ! -f "${blocks_file}" ]] && echo "[]" > "${blocks_file}"
      if [[ $(jq -r .status <<< "${cncli_leaderlog}") != ok ]]; then
        echo "ERROR: failure in leaderlog while running:"
        echo "${CNCLI} leaderlog --db ${CNCLI_DB} --byron-genesis ${BYRON_GENESIS_JSON} --shelley-genesis ${GENESIS_JSON} --ledger-set current --ledger-state ${ledger_state_file} --pool-id ${POOL_ID} --pool-vrf-skey ${POOL_VRF_SKEY}"
        echo "Error message: $(jq -r '.errorMessage //empty' <<< "${cncli_leaderlog}")"
        continue
      fi
      blocks_data="$(cat "${blocks_file}")"
      blocks_data_new="${blocks_data}"
      while read -r assigned_slot; do
        slot=$(jq -r '.slot' <<< "${assigned_slot}")
        slot_search=$(jq --arg _slot "${slot}" '.[] | select(.slot == $_slot)' "${blocks_file}")
        if [[ -z ${slot_search} ]]; then
          at=$(jq -r '.at' <<< "${assigned_slot}")
          slotInEpoch=$(jq -r '.slotInEpoch' <<< "${assigned_slot}")
          blocks_data_new="$(jq --arg _at "${at}" --arg _slot "${slot}" --arg _slotInEpoch "${slotInEpoch}" '. += [{"at": $_at,"slot": $_slot,"slotInEpoch": $_slotInEpoch,"status": "leader"}]' <<< "${blocks_data}")"
          echo "LEADER: slot[${slot}] slotInEpoch[${slotInEpoch}] at[${at}]"
        fi
      done < <(jq -c '.assignedSlots[]' <<< "${cncli_leaderlog}" 2>/dev/null)
      jq -r . <<< "${blocks_data_new}" > "${blocks_file}"
      first_run="false"
    fi
    blocks_file="${BLOCKLOG_DIR}/blocks_${next_epoch}.json"
    
    if [[ ! -f "${blocks_file}" && ${slot_tip} -gt ${slot_for_next_nonce} ]]; then # Run leaderlogs for next epoch
      if ! dumpLedgerState; then sleep 300; continue; fi
      cncli_leaderlog=$(${CNCLI} leaderlog --db "${CNCLI_DB}" --byron-genesis "${BYRON_GENESIS_JSON}" --shelley-genesis "${GENESIS_JSON}" --ledger-set next --ledger-state "${ledger_state_file}" --pool-id "${POOL_ID}" --pool-vrf-skey "${POOL_VRF_SKEY}")
      if [[ $(jq -r .status <<< "${cncli_leaderlog}") != ok ]]; then
        echo "ERROR: failure in leaderlog while running:"
        echo "${CNCLI} leaderlog --db ${CNCLI_DB} --byron-genesis ${BYRON_GENESIS_JSON} --shelley-genesis ${GENESIS_JSON} --ledger-set next --ledger-state ${ledger_state_file} --pool-id ${POOL_ID} --pool-vrf-skey ${POOL_VRF_SKEY}"
        echo "Error message: $(jq -r '.errorMessage //empty' <<< "${cncli_leaderlog}")"
        continue
      fi
      jq -r '.assignedSlots | .[] += {"status": "leader"}' <<< "${cncli_leaderlog}" > "${blocks_file}"
      echo "Leaderlogs for next epoch[${next_epoch}] calculated and saved to ${blocks_file}"
    fi
  done
}

#################################

cncliValidate() {
  echo "~ CNCLI Block Validation started ~"
  while true; do
    sleep ${SLEEP_RATE}
    node_metrics=$(getNodeMetrics)
    block_tip=$(getBlockTip)
    slot_tip=$(getSlotTip)
    curr_epoch=$(getEpoch)
    prev_epoch=$((curr_epoch-1))
    # Start with previous epoch to catch epoch boundary cases
    blocks_file="${BLOCKLOG_DIR}/blocks_${prev_epoch}.json"
    if [[ -f "${blocks_file}" ]]; then
      blocks_data="$(cat "${blocks_file}")"
      blocks_data_new="${blocks_data}"
      while read -r block; do
        validateBlock
      done < <(jq -c '.[]' "${blocks_file}" 2>/dev/null)
      jq -r . <<< "${blocks_data_new}" > "${blocks_file}"
    fi
    # continue with current epoch
    blocks_file="${BLOCKLOG_DIR}/blocks_${curr_epoch}.json"
    if [[ -f "${blocks_file}" ]]; then
      blocks_data="$(cat "${blocks_file}")"
      blocks_data_new="${blocks_data}"
      while read -r block; do
        validateBlock
      done < <(jq -c '.[]' "${blocks_file}" 2>/dev/null)
      jq -r . <<< "${blocks_data_new}" > "${blocks_file}"
    fi
  done
}

validateBlock() {
  block_status=$(jq -r '.status //empty' <<< "${block}")
  [[ ${block_status} = invalid ]] && return
  if [[ ${block_status} = leader ]]; then
    block_slot=$(jq -r '.slot' <<< "${block}")
    [[ $((block_slot + CONFIRM_SLOT_CNT)) -ge ${slot_tip} ]] && return
    # assume lost for now, TODO: use cncli/sqlite to check if slot was made by another pool
    blocks_data_new="$(jq --arg _slot "${block_slot}" '[.[] | select(.slot == $_slot) += {"status": "missed"}]' <<< "${blocks_data}")"
    echo "MISSED: Leader for slot '${block_slot}' but not adopted. Verify that logMonitor companion script is running and working!"
  elif [[ ${block_status} = adopted ]]; then
    block_slot=$(jq -r '.slot' <<< "${block}")
    [[ $((slot_tip - block_slot)) -lt ${CONFIRM_SLOT_CNT} ]] && return # To make sure enough slots has passed before validating
    block_hash=$(jq -r '.hash //empty' <<< "${block}")
    if [[ -n ${block_hash} ]]; then # Can't validate without a hash
      cncli_block_data=$(${CNCLI} validate --hash "${block_hash}" --db "${CNCLI_DB}")
      if [[ $(jq -r .status <<< "${cncli_block_data}") = ok ]]; then
        cncli_slot_nbr=$(jq -r .slot_number <<< "${cncli_block_data}")
        if [[ ${cncli_slot_nbr} -ne ${block_slot} ]]; then
          echo "ERROR: CNCLI slot nbr[${cncli_slot_nbr}] doesn't match adopted block slot nbr[${block_slot}] for hash '${block_hash}'"
        else
          cncli_block_nbr=$(jq -r .block_number <<< "${cncli_block_data}")
          [[ $((block_tip-cncli_block_nbr)) -lt ${CONFIRM_BLOCK_CNT} ]] && return # To make sure enough blocks has been built on top before validating
          # Block confimed
          cncli_block_hash=$(jq -r .hash <<< "${cncli_block_data}")
          blocks_data_new="$(jq --arg _slot "${block_slot}" --arg _block "${cncli_block_nbr}" --arg _hash "${cncli_block_hash}" '[.[] | select(.slot == $_slot) += {"block": $_block,"hash": $_hash,"status": "confirmed"}]' <<< "${blocks_data}")"
          echo "CONFIRMED: Block[${cncli_block_nbr}] / Slot[${block_slot}] at $(date '+%F %T Z' --date="$(jq -r '.at' <<< "${block}")"), hash: ${cncli_block_hash}"
        fi
      else
        blocks_data_new="$(jq --arg _slot "${block_slot}" '[.[] | select(.slot == $_slot) += {"status": "ghosted"}]' <<< "${blocks_data}")"
        echo "GHOSTED: Leader for slot '${block_slot}' but block hash '${block_hash}' not found, stolen in slot/height battle or block propagation issue!"
      fi
    else
      echo "ERROR: Block adopted for slot '${block_slot}' but no hash logged?"
    fi
  fi
}

#################################

cncliMigrateBlocklog() {
  while IFS= read -r -d '' blocks_file; do
    echo "migrating: $(basename "${blocks_file}")"
    blocks_data="$(cat "${blocks_file}")"
    blocks_data_new="${blocks_data}"
    while read -r block; do
      block_status=$(jq -r '.status //empty' <<< "${block}")
      if [[ -z ${block_status} ]]; then # migration from old blocklog pre cncli
        block_slot=$(jq -r '.slot' <<< "${block}")
        block_hash=$(jq -r '.hash //empty' <<< "${block}")
        if [[ -n ${block_hash} ]]; then
          [[ ${block_hash} =~ ^Invalid ]] && block_status="invalid" || block_status="adopted"
        else
          block_status="leader"
        fi
        blocks_data_new="$(jq --arg _slot "${block_slot}" --arg _status "${block_status}" '[.[] | select(.slot == $_slot) += {"status": $_status}]' <<< "${blocks_data}")"
        echo "Block at slot ${block_slot} updated with status '${block_status}'"
      fi
    done < <(jq -c '.[]' <<< "${blocks_data}" 2>/dev/null)
    jq -r . <<< "${blocks_data_new}" > "${blocks_file}"
  done < <(find "${BLOCKLOG_DIR}" -mindepth 1 -maxdepth 1 -type f -name "blocks_*" -print0 | sort -z)
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
  migrate )
    cncliInit && cncliMigrateBlocklog ;;
  * ) usage ;;
esac