#!/bin/bash
#shellcheck disable=SC2086,SC2154
#shellcheck source=/dev/null

. "$(dirname $0)"/env offline # source env in offline mode to get basic variables, sourced in online mode later in cncliInit()

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#POOL_ID=""                               # Automatically detected if POOL_NAME is set in env. Required for leaderlog calculation & pooltool sendtip, lower-case hex pool id
#POOL_VRF_SKEY=""                         # Automatically detected if POOL_NAME is set in env. Required for leaderlog calculation, path to pool's vrf.skey file
#POOL_VRF_VKEY=""                         # Automatically detected if POOL_NAME is set in env. Required for block validation, path to pool's vrf.vkey file
#PT_API_KEY=""                            # POOLTOOL: set API key, e.g "a47811d3-0008-4ecd-9f3e-9c22bdb7c82d"
#POOL_TICKER=""                           # POOLTOOL: set the pools ticker, e.g "TCKR"
#PT_HOST="127.0.0.1"                      # POOLTOOL: connect to a remote node, preferably block producer (default localhost)
#PT_PORT="${CNODE_PORT}"                  # POOLTOOL: port of node to connect to (default CNODE_PORT from env file)
#PT_SENDSLOTS_START=30                    # POOLTOOL sendslots: delay after epoch boundary before sending slots (in minutes)
#PT_SENDSLOTS_STOP=60                     # POOLTOOL sendslots: prohibit sending of slots to pooltool after X number of minutes (in minutes, blocked on pooltool end as well)
#CNCLI_DIR="${CNODE_HOME}/guild-db/cncli" # path to folder for cncli sqlite db
#SLEEP_RATE=60                            # CNCLI leaderlog/validate: time to wait until next check (in seconds)
#CONFIRM_SLOT_CNT=600                     # CNCLI validate: require at least these many slots to have passed before validating
#CONFIRM_BLOCK_CNT=15                     # CNCLI validate: require at least these many blocks on top of minted before validating
#BATCH_AUTO_UPDATE=N                      # Set to Y to automatically update the script if a new version is available without user interaction
#LEDGER_API=true                          # Use API from api.crypto2099.io in cncli call instead of local ledger-state dump to vastly reduce system resources. ONLY for MainNet network (true|false)

######################################
# Do NOT modify code below           #
######################################

usage() {
  cat <<-EOF >&2
		
		Usage: $(basename "$0") [operation <sub arg>]
		Script to run CNCLI, best launched through systemd deployed by 'deploy-as-systemd.sh'
		
		sync        Start CNCLI chainsync process that connects to cardano-node to sync blocks stored in SQLite DB (deployed as service)
		leaderlog   One-time leader schedule calculation for current epoch, then continously monitors and calculates schedule for coming epochs, 1.5 days before epoch boundary on MainNet (deployed as service)
		  force     Manually force leaderlog calculation and overwrite even if already done, exits after leaderlog is calculated
		validate    Continously monitor and confirm that the blocks made actually was accepted and adopted by chain (deployed as service)
		  all       One-time re-validation of all blocks in blocklog db
		  epoch     One-time re-validation of blocks in blocklog db for the specified epoch 
		ptsendtip   Send node tip to PoolTool for network analysis and to show that your node is alive and well with a green badge (deployed as service)
		ptsendslots Securely sends PoolTool the number of slots you have assigned for an epoch and validates the correctness of your past epochs (deployed as service)
		  force     Manually force pooltool sendslots submission ignoring configured time window 
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

######################################

createBlocklogDB() {
  if ! mkdir -p "${BLOCKLOG_DIR}" 2>/dev/null; then echo "ERROR: failed to create directory to store blocklog: ${BLOCKLOG_DIR}" && return 1; fi
  if [[ ! -f ${BLOCKLOG_DB} ]]; then # create a fresh DB with latest schema
    sqlite3 ${BLOCKLOG_DB} <<-EOF
			CREATE TABLE blocklog (id INTEGER PRIMARY KEY AUTOINCREMENT, slot INTEGER NOT NULL UNIQUE, at TEXT NOT NULL UNIQUE, epoch INTEGER NOT NULL, block INTEGER NOT NULL DEFAULT 0, slot_in_epoch INTEGER NOT NULL DEFAULT 0, hash TEXT NOT NULL DEFAULT '', size INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL);
			CREATE UNIQUE INDEX idx_blocklog_slot ON blocklog (slot);
			CREATE INDEX idx_blocklog_epoch ON blocklog (epoch);
			CREATE INDEX idx_blocklog_status ON blocklog (status);
			CREATE TABLE epochdata (id INTEGER PRIMARY KEY AUTOINCREMENT, epoch INTEGER NOT NULL, epoch_nonce TEXT NOT NULL, pool_id TEXT NOT NULL, sigma TEXT NOT NULL, d REAL NOT NULL, epoch_slots_ideal INTEGER NOT NULL, max_performance REAL NOT NULL, active_stake TEXT NOT NULL, total_active_stake TEXT NOT NULL, UNIQUE(epoch,pool_id));
			CREATE INDEX idx_epochdata_epoch ON epochdata (epoch);
			CREATE INDEX idx_epochdata_pool_id ON epochdata (pool_id);
			PRAGMA user_version = 1;
			EOF
    echo "SQLite blocklog DB created: ${BLOCKLOG_DB}"
  else
    if [[ $(sqlite3 ${BLOCKLOG_DB} "PRAGMA user_version;") -eq 0 ]]; then # Upgrade from schema version 0 to 1
      sqlite3 ${BLOCKLOG_DB} <<-EOF
				ALTER TABLE epochdata ADD active_stake TEXT NOT NULL DEFAULT '0';
				ALTER TABLE epochdata ADD total_active_stake TEXT NOT NULL DEFAULT '0';
				PRAGMA user_version = 1;
				EOF
    fi
  fi
}

cncliDBinSync() { # getNodeMetrics expected to have been already run
  cncli_tip=$(sqlite3 "${CNCLI_DB}" "SELECT slot_number FROM chain ORDER BY slot_number DESC LIMIT 1;")
  cncli_sync_prog=$(echo "( ${cncli_tip} / ${slotnum} ) * 100" | bc -l)
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

dumpLedgerState() { # getNodeMetrics expected to have been already run
  ledger_state_file="${TMP_DIR}/ledger-state_${NWMAGIC}_${epochnum}.json"
  [[ -n $(find "${ledger_state_file}" -mmin -60 2>/dev/null) ]] && return 0 # no need to continue, we have a fresh(<1h) ledger-state already
  rm -f "${TMP_DIR}/ledger-state_"* # remove old ledger dumps before creating a new
  if ! timeout -k 5 "${TIMEOUT_LEDGER_STATE}" ${CCLI} query ledger-state ${NETWORK_IDENTIFIER} --out-file "${ledger_state_file}"; then
    echo "ERROR: ledger dump failed/timed out, increase timeout value"
    [[ -f "${ledger_state_file}" ]] && rm -f "${ledger_state_file}"
    return 1
  fi
  return 0
}

#################################

cncliInit() {

  if renice_cmd="$(command -v renice)"; then ${renice_cmd} -n 19 $$ >/dev/null; fi

  [[ -z "${BATCH_AUTO_UPDATE}" ]] && BATCH_AUTO_UPDATE=N
  
  if ! command -v sqlite3 >/dev/null; then echo "ERROR: sqlite3 not found, please install before activating blocklog function" && exit 1; fi

  PARENT="$(dirname $0)"

  # Check if update is available
  [[ -f "${PARENT}"/.env_branch ]] && BRANCH="$(cat ${PARENT}/.env_branch)" || BRANCH="master"
  URL="https://raw.githubusercontent.com/cardano-community/guild-operators/${BRANCH}/scripts/cnode-helper-scripts"
  if curl -s -m 10 -o "${PARENT}"/cncli.sh.tmp ${URL}/cncli.sh && curl -s -m 10 -o "${PARENT}"/env.tmp ${URL}/env && [[ -f "${PARENT}"/cncli.sh.tmp && -f "${PARENT}"/env.tmp ]]; then
    if [[ -f "${PARENT}"/env ]]; then
      if [[ $(grep "_HOME=" "${PARENT}"/env) =~ ^#?([^[:space:]]+)_HOME ]]; then
        vname=$(tr '[:upper:]' '[:lower:]' <<< "${BASH_REMATCH[1]}")
      else
        echo -e "\nFailed to get cnode instance name from env file, aborting!\n"
        rm -f "${PARENT}"/cncli.sh.tmp
        rm -f "${PARENT}"/env.tmp
        exit 1
      fi
      sed -e "s@/opt/cardano/[c]node@/opt/cardano/${vname}@g" -e "s@[C]NODE_HOME@${BASH_REMATCH[1]}_HOME@g" -i "${PARENT}"/cncli.sh.tmp -i "${PARENT}"/env.tmp
      CNCLI_TEMPL=$(awk '/^# Do NOT modify/,0' "${PARENT}"/cncli.sh)
      CNCLI_TEMPL2=$(awk '/^# Do NOT modify/,0' "${PARENT}"/cncli.sh.tmp)
      ENV_TEMPL=$(awk '/^# Do NOT modify/,0' "${PARENT}"/env)
      ENV_TEMPL2=$(awk '/^# Do NOT modify/,0' "${PARENT}"/env.tmp)
      if [[ "$(echo ${CNCLI_TEMPL} | sha256sum)" != "$(echo ${CNCLI_TEMPL2} | sha256sum)" || "$(echo ${ENV_TEMPL} | sha256sum)" != "$(echo ${ENV_TEMPL2} | sha256sum)" ]]; then
        . "${PARENT}"/env offline &>/dev/null # source in offline mode and ignore errors to get some common functions, sourced at a later point again
        if [[ ${BATCH_AUTO_UPDATE} = 'Y' ]] || { [[ -t 1 ]] && getAnswer "\nA new version is available, do you want to upgrade?"; }; then
          cp "${PARENT}"/cncli.sh "${PARENT}/cncli.sh_bkp$(date +%s)"
          cp "${PARENT}"/env "${PARENT}/env_bkp$(date +%s)"
          CNCLI_STATIC=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/cncli.sh)
          ENV_STATIC=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/env)
          printf '%s\n%s\n' "$CNCLI_STATIC" "$CNCLI_TEMPL2" > "${PARENT}"/cncli.sh.tmp
          printf '%s\n%s\n' "$ENV_STATIC" "$ENV_TEMPL2" > "${PARENT}"/env.tmp
          {
            mv -f "${PARENT}"/cncli.sh.tmp "${PARENT}"/cncli.sh && \
            mv -f "${PARENT}"/env.tmp "${PARENT}"/env && \
            chmod 755 "${PARENT}"/cncli.sh "${PARENT}"/env && \
            echo -e "\nUpdate applied successfully, please run cncli again!\n" && \
            exit 0; 
          } || {
            echo -e "\n${FG_RED}Update failed!${NC}\n\nplease install cncli.sh & env with prereqs.sh or manually download from GitHub" && \
            rm -f "${PARENT}"/cncli.sh.tmp && \
            rm -f "${PARENT}"/env.tmp && \
            exit 1;
          }
        fi
      fi
    else
      mv "${PARENT}"/env.tmp "${PARENT}"/env
      rm -f "${PARENT}"/cncli.sh.tmp
      echo -e "\nCommon env file downloaded: ${PARENT}/env"
      echo -e "This is a mandatory prerequisite, please set variables accordingly in User Variables section in the env file and restart cncli.sh\n"
      exit 0
    fi
  fi
  rm -f "${PARENT}"/cncli.sh.tmp
  rm -f "${PARENT}"/env.tmp

  if [[ ! -f "${PARENT}"/env ]]; then
    echo -e "\nCommon env file missing: ${PARENT}/env"
    echo -e "This is a mandatory prerequisite, please install with prereqs.sh or manually download from GitHub\n"
    exit 1
  fi
  
  until . "${PARENT}"/env; do
    echo "sleeping for 10s and testing again..."
    sleep 10
  done
  
  TMP_DIR="${TMP_DIR}/cncli"
  if ! mkdir -p "${TMP_DIR}" 2>/dev/null; then echo "ERROR: Failed to create directory for temporary files: ${TMP_DIR}"; exit 1; fi
  
  [[ ! -f "${CNCLI}" ]] && echo -e "\nERROR: failed to locate cncli executable, please install with 'prereqs.sh'\n" && exit 1
  CNCLI_VERSION="v$(cncli -V | cut -d' ' -f2)"
  if ! versionCheck "1.5.0" "${CNCLI_VERSION}"; then echo "ERROR: cncli ${CNCLI_VERSION} installed, please upgrade to latest version!"; exit 1; fi
  
  [[ -z "${CNCLI_DIR}" ]] && CNCLI_DIR="${CNODE_HOME}/guild-db/cncli"
  if ! mkdir -p "${CNCLI_DIR}" 2>/dev/null; then echo "ERROR: Failed to create CNCLI DB directory: ${CNCLI_DIR}"; exit 1; fi
  CNCLI_DB="${CNCLI_DIR}/cncli.db"
  [[ -z "${LEDGER_API}" ]] && LEDGER_API="true"
  [[ -z "${SLEEP_RATE}" ]] && SLEEP_RATE=60
  [[ -z "${CONFIRM_SLOT_CNT}" ]] && CONFIRM_SLOT_CNT=600
  [[ -z "${CONFIRM_BLOCK_CNT}" ]] && CONFIRM_BLOCK_CNT=15
  [[ -z "${PT_HOST}" ]] && PT_HOST="127.0.0.1"
  [[ -z "${PT_PORT}" ]] && PT_PORT="${CNODE_PORT}"
  [[ -z "${PT_SENDSLOTS_START}" ]] && PT_SENDSLOTS_START=30
  PT_SENDSLOTS_START=$((PT_SENDSLOTS_START*60))
  [[ -z "${PT_SENDSLOTS_STOP}" ]] && PT_SENDSLOTS_STOP=60
  PT_SENDSLOTS_STOP=$((PT_SENDSLOTS_STOP*60))
  if [[ -d "${POOL_DIR}" ]]; then
    [[ -z "${POOL_ID}" && -f "${POOL_DIR}/${POOL_ID_FILENAME}" ]] && POOL_ID=$(cat "${POOL_DIR}/${POOL_ID_FILENAME}")
    [[ -z "${POOL_VRF_SKEY}" ]] && POOL_VRF_SKEY="${POOL_DIR}/${POOL_VRF_SK_FILENAME}"
    [[ -z "${POOL_VRF_VKEY}" ]] && POOL_VRF_VKEY="${POOL_DIR}/${POOL_VRF_VK_FILENAME}"
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
  createBlocklogDB || exit 1 # create db if needed
  [[ -z ${POOL_ID} || -z ${POOL_VRF_SKEY} ]] && echo "'POOL_ID' and/or 'POOL_VRF_SKEY' not set in $(basename "$0"), exiting!" && exit 1
  
  while true; do
    if [[ ${SHELLEY_TRANS_EPOCH} -eq -1 ]]; then
      getNodeMetrics
      if ! getShelleyTransitionEpoch; then 
        echo "Failed to calculate shelley transition epoch, checking again in ${SLEEP_RATE}s"
        sleep ${SLEEP_RATE}
      else
        echo "Shelley transition epoch found: ${SHELLEY_TRANS_EPOCH}"
      fi
    else
      getNodeMetrics
      tip_diff=$(( $(getSlotTipRef) - slotnum ))
      if [[ ${tip_diff} -gt 300 ]]; then # Node considered in sync if less than 300 slots from theoretical tip
        echo "Node still syncing, ${tip_diff} slots from theoretical tip, checking again in ${SLEEP_RATE}s"
      elif ! cncliDBinSync; then
        echo "CNCLI still syncing [$(printf "%2.4f %%" ${cncli_sync_prog})], checking again in ${SLEEP_RATE}s"
      else
        break
      fi
      sleep ${SLEEP_RATE}
    fi
  done
  
  [[ ${subarg} != "force" ]] && echo "Node in sync, sleeping for ${SLEEP_RATE}s before running leaderlogs for current epoch" && sleep ${SLEEP_RATE}
  getNodeMetrics
  curr_epoch=${epochnum}
  if [[ $(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM epochdata WHERE epoch=${curr_epoch};" 2>/dev/null) -eq 1 && ${subarg} != "force" ]]; then
    echo "Leaderlogs already calculated for epoch ${curr_epoch}, skipping!"
  else
    echo "Running leaderlogs for epoch ${curr_epoch} and adding leader slots not already in DB"
    ledger_state_param=""
    if [[ ${LEDGER_API} = "false" || ${NWMAGIC} -ne 764824073 ]]; then 
      if ! dumpLedgerState; then exit 1; else ledger_state_param="--ledger-state ${ledger_state_file}"; fi
    fi
    cncli_leaderlog=$(${CNCLI} leaderlog --db "${CNCLI_DB}" --byron-genesis "${BYRON_GENESIS_JSON}" --shelley-genesis "${GENESIS_JSON}" --ledger-set current ${ledger_state_param} --pool-id "${POOL_ID}" --pool-vrf-skey "${POOL_VRF_SKEY}" --tz UTC)
    if [[ $(jq -r .status <<< "${cncli_leaderlog}") != ok ]]; then
      error_msg=$(jq -r .errorMessage <<< "${cncli_leaderlog}")
      if [[ "${error_msg}" = "Query returned no rows" ]]; then
        echo "No leader slots found for epoch ${curr_epoch} :("
      else
        echo "ERROR: failure in leaderlog while running:"
        echo "${CNCLI} leaderlog --db ${CNCLI_DB} --byron-genesis ${BYRON_GENESIS_JSON} --shelley-genesis ${GENESIS_JSON} --ledger-set current ${ledger_state_param} --pool-id ${POOL_ID} --pool-vrf-skey ${POOL_VRF_SKEY} --tz UTC"
        echo "Error message: ${error_msg}"
        exit 1
      fi
    else
      epoch_nonce=$(jq -r '.epochNonce' <<< "${cncli_leaderlog}")
      pool_id=$(jq -r '.poolId' <<< "${cncli_leaderlog}")
      sigma=$(jq -r '.sigma' <<< "${cncli_leaderlog}")
      d=$(jq -r '.d' <<< "${cncli_leaderlog}")
      epoch_slots_ideal=$(jq -r '.epochSlotsIdeal //0' <<< "${cncli_leaderlog}")
      max_performance=$(jq -r '.maxPerformance //0' <<< "${cncli_leaderlog}")
      active_stake=$(jq -r '.activeStake //0' <<< "${cncli_leaderlog}")
      total_active_stake=$(jq -r '.totalActiveStake //0' <<< "${cncli_leaderlog}")
      sqlite3 ${BLOCKLOG_DB} <<-EOF
				UPDATE OR IGNORE epochdata SET epoch_nonce = '${epoch_nonce}', sigma = '${sigma}', d = ${d}, epoch_slots_ideal = ${epoch_slots_ideal}, max_performance = ${max_performance}, active_stake = '${active_stake}', total_active_stake = '${total_active_stake}'
				WHERE epoch = ${curr_epoch} AND pool_id = '${pool_id}';
				INSERT OR IGNORE INTO epochdata (epoch, epoch_nonce, pool_id, sigma, d, epoch_slots_ideal, max_performance, active_stake, total_active_stake)
				VALUES (${curr_epoch}, '${epoch_nonce}', '${pool_id}', '${sigma}', ${d}, ${epoch_slots_ideal}, ${max_performance}, '${active_stake}', '${total_active_stake}');
				EOF
      block_cnt=0
      while read -r assigned_slot; do
        block_slot=$(jq -r '.slot' <<< "${assigned_slot}")
        block_at=$(jq -r '.at' <<< "${assigned_slot}")
        block_slot_in_epoch=$(jq -r '.slotInEpoch' <<< "${assigned_slot}")
        sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO blocklog (slot,at,slot_in_epoch,epoch,status) values (${block_slot},'${block_at}',${block_slot_in_epoch},${curr_epoch},'leader');"
        echo "LEADER: slot[${block_slot}] slotInEpoch[${block_slot_in_epoch}] at[${block_at}]"
        ((block_cnt++))
      done < <(jq -c '.assignedSlots[]' <<< "${cncli_leaderlog}" 2>/dev/null)
      echo "Leaderlog calculation for epoch[${curr_epoch}] completed and saved to blocklog DB"
      echo "Leaderslots: ${block_cnt} - Ideal slots for epoch based on active stake: ${epoch_slots_ideal} - Luck factor ${max_performance}%"
    fi
  fi
  
  while true; do
    [[ ${subarg} != "force" ]] && sleep ${SLEEP_RATE}
    getNodeMetrics
    if ! cncliDBinSync; then # verify that cncli DB is still in sync
      echo "CNCLI DB out of sync :( [$(printf "%2.4f %%" ${cncli_sync_prog})] ... checking again in ${SLEEP_RATE}s"
      [[ ${subarg} = "force" ]] && sleep ${SLEEP_RATE}
      continue
    fi
    slot_for_next_nonce=$(echo "(${slotnum} - ${slot_in_epoch} + ${EPOCH_LENGTH}) - (3 * ${BYRON_K} / ${ACTIVE_SLOTS_COEFF})" | bc) # firstSlotOfNextEpoch - stabilityWindow(3 * k / f)
    curr_epoch=${epochnum}
    next_epoch=$((curr_epoch+1))
    if [[ ${slotnum} -gt ${slot_for_next_nonce} ]]; then # Run leaderlogs for next epoch
      if [[ $(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM epochdata WHERE epoch=${next_epoch};" 2>/dev/null) -eq 1 ]]; then # Leaderlogs already calculated for next epoch, skipping!
        if [[ -t 1 ]]; then # manual execution
          [[ ${subarg} != "force" ]] && echo "Leaderlogs already calculated for epoch ${next_epoch}, skipping!" && break
        else continue; fi
      fi
      echo "Running leaderlogs for next epoch[${next_epoch}]"
      ledger_state_param=""
      if [[ ${LEDGER_API} = "false" || ${NWMAGIC} -ne 764824073 ]]; then 
        if ! dumpLedgerState; then sleep 600; continue; else ledger_state_param="--ledger-state ${ledger_state_file}"; fi # Sleep for 10 min before trying to dump ledger-state in case of error
      fi
      cncli_leaderlog=$(${CNCLI} leaderlog --db "${CNCLI_DB}" --byron-genesis "${BYRON_GENESIS_JSON}" --shelley-genesis "${GENESIS_JSON}" --ledger-set next ${ledger_state_param} --pool-id "${POOL_ID}" --pool-vrf-skey "${POOL_VRF_SKEY}" --tz UTC)
      if [[ $(jq -r .status <<< "${cncli_leaderlog}") != ok ]]; then
        error_msg=$(jq -r .errorMessage <<< "${cncli_leaderlog}")
        if [[ "${error_msg}" = "Query returned no rows" ]]; then
          echo "No leader slots found for epoch ${curr_epoch} :("
        else
          echo "ERROR: failure in leaderlog while running:"
          echo "${CNCLI} leaderlog --db ${CNCLI_DB} --byron-genesis ${BYRON_GENESIS_JSON} --shelley-genesis ${GENESIS_JSON} --ledger-set next ${ledger_state_param} --pool-id ${POOL_ID} --pool-vrf-skey ${POOL_VRF_SKEY} --tz UTC"
          echo "Error message: ${error_msg}"
        fi
      else
        epoch_nonce=$(jq -r '.epochNonce' <<< "${cncli_leaderlog}")
        pool_id=$(jq -r '.poolId' <<< "${cncli_leaderlog}")
        sigma=$(jq -r '.sigma' <<< "${cncli_leaderlog}")
        d=$(jq -r '.d' <<< "${cncli_leaderlog}")
        epoch_slots_ideal=$(jq -r '.epochSlotsIdeal //0' <<< "${cncli_leaderlog}")
        max_performance=$(jq -r '.maxPerformance //0' <<< "${cncli_leaderlog}")
        active_stake=$(jq -r '.activeStake //0' <<< "${cncli_leaderlog}")
        total_active_stake=$(jq -r '.totalActiveStake //0' <<< "${cncli_leaderlog}")
        sqlite3 ${BLOCKLOG_DB} <<-EOF
					UPDATE OR IGNORE epochdata SET epoch_nonce = '${epoch_nonce}', sigma = '${sigma}', d = ${d}, epoch_slots_ideal = ${epoch_slots_ideal}, max_performance = ${max_performance}, active_stake = '${active_stake}', total_active_stake = '${total_active_stake}'
					WHERE epoch = ${next_epoch} AND pool_id = '${pool_id}';
					INSERT OR IGNORE INTO epochdata (epoch, epoch_nonce, pool_id, sigma, d, epoch_slots_ideal, max_performance, active_stake, total_active_stake)
					VALUES (${next_epoch}, '${epoch_nonce}', '${pool_id}', '${sigma}', ${d}, ${epoch_slots_ideal}, ${max_performance}, '${active_stake}', '${total_active_stake}');
					EOF
        block_cnt=0
        while read -r assigned_slot; do
          block_slot=$(jq -r '.slot' <<< "${assigned_slot}")
          block_at=$(jq -r '.at' <<< "${assigned_slot}")
          block_slot_in_epoch=$(jq -r '.slotInEpoch' <<< "${assigned_slot}")
          sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO blocklog (slot,at,slot_in_epoch,epoch,status) values (${block_slot},'${block_at}',${block_slot_in_epoch},${next_epoch},'leader');"
          echo "LEADER: slot[${block_slot}] slotInEpoch[${block_slot_in_epoch}] at[${block_at}]"
          ((block_cnt++))
        done < <(jq -c '.assignedSlots[]' <<< "${cncli_leaderlog}" 2>/dev/null)
        echo "Leaderlog calculation for next epoch[${next_epoch}] completed and saved to blocklog DB"
        echo "Leaderslots: ${block_cnt} - Ideal slots for epoch based on active stake: ${epoch_slots_ideal} - Luck factor ${max_performance}%"
      fi
    fi
    [[ -t 1 ]] && break # manual execution of script in tty mode, exit after first run
  done
}

#################################

cncliValidate() {
  echo "~ CNCLI Block Validation started ~"
  if ! getPoolVrfVkeyCborHex; then exit 1; fi # We need this to properly validate block
  createBlocklogDB || exit 1 # create db if needed
  getNodeMetrics
  if ! getShelleyTransitionEpoch; then echo "ERROR: failed to calculate shelley transition epoch" && exit 1; fi
  if [[ -n ${subarg} ]]; then
    if ! cncliDBinSync; then # verify that cncli DB is still in sync
      echo "CNCLI DB out of sync :( [$(printf "%2.4f %%" ${cncli_sync_prog})] ... check cncli sync service!"
      exit 1
    fi
    tip_diff=$(( $(getSlotTipRef) - slotnum ))
    [[ ${tip_diff} -gt 300 ]] && echo "ERROR: node still syncing, ${tip_diff} slots from theoretical tip" && exit 1
    epoch=0
    epoch_selection=""
    if [[ ${subarg} =~ ^[0-9]+$ ]]; then
      epoch_selection="WHERE epoch = ${subarg}"
    elif [[ ${subarg} != "all" ]]; then
      echo "ERROR: unknown argument passed to validate command, valid options incl the string 'all' or the epoch number to validate"
      exit 1
    fi
    epoch_blocks=$(sqlite3 "${BLOCKLOG_DB}" "SELECT epoch, slot, status, hash FROM blocklog ${epoch_selection} ORDER BY slot;")
    if [[ -n ${epoch_blocks} ]]; then
      while IFS='|' read -r block_epoch block_slot block_status block_hash; do
        [[ ${epoch} -ne ${block_epoch} ]] && echo -e "> Validating epoch ${FG_GREEN}${block_epoch}${NC}" && epoch=${block_epoch}
        [[ ${block_status} != invalid ]] && block_status="leader" # reset status to leader to re-validate all non invalid blocks
        validateBlock
      done < <(printf '%s\n' "${epoch_blocks}")
    fi
  elif [[ -n ${subarg} ]]; then
    echo "ERROR: unknown argument passed to validate subcommand" && usage
  else
    while true; do
      sleep ${SLEEP_RATE}
      getNodeMetrics
      if ! cncliDBinSync; then # verify that cncli DB is still in sync
        echo "CNCLI DB out of sync :( [$(printf "%2.4f %%" ${cncli_sync_prog})] ... checking again in ${SLEEP_RATE}s"
        continue
      fi
      curr_epoch=${epochnum}
      # Check previous epoch as well at start of current epoch
      [[ ${slot_in_epoch} -lt $(( CONFIRM_SLOT_CNT * 6 )) ]] && prev_epoch=$((curr_epoch-1)) || prev_epoch=${curr_epoch}
      epoch_blocks=$(sqlite3 "${BLOCKLOG_DB}" "SELECT epoch, slot, status, hash FROM blocklog WHERE epoch BETWEEN ${prev_epoch} and ${curr_epoch} ORDER BY slot;")
      if [[ -n ${epoch_blocks} ]]; then
        while IFS='|' read -r block_epoch block_slot block_status block_hash; do
          validateBlock
        done < <(printf '%s\n' "${epoch_blocks}")
      fi
    done
  fi
}

validateBlock() {
  [[ ${block_status} = invalid ]] && return
  if [[ ${block_status} = leader || ${block_status} = adopted ]]; then
    [[ ${block_slot} -gt ${slotnum} ]] && return # block in the future, skip
    block_data_raw="$(sqlite3 "${CNCLI_DB}" "SELECT block_number, hash, block_size, orphaned, node_vrf_vkey FROM chain WHERE slot_number = ${block_slot};")"
    slot_cnt=0; slot_ok_cnt=0; slot_stolen_cnt=0; block_data=()
    for block in ${block_data_raw}; do
      IFS='|' read -ra block_data_tmp <<< ${block}
      if [[ ${block_data_tmp[4]} = "${pool_vrf_vkey_cbox_hex}" ]]; then
        ((slot_cnt++))
        [[ ${block_data_tmp[3]} -eq 0 ]] && ((slot_ok_cnt++)) && block_data=( "${block_data_tmp[@]}" ) # non orphaned block found for our pool, set as block_data
        [[ ${#block_data[@]} -eq 0 ]] && block_data=( "${block_data_tmp[@]}" ) # block found but orphaned and block_data empty, set block_data to this block for now
      else
        [[ ${block_data_tmp[3]} -eq 0 ]] && ((slot_stolen_cnt++))
      fi
    done
    if [[ $((block_slot + CONFIRM_SLOT_CNT)) -lt ${slotnum} ]]; then # block old enough to validate
      if [[ ${slot_cnt} -eq 0 ]]; then # no block found in db for this slot with our vrf vkey
        if [[ ${slot_stolen_cnt} -eq 0 ]]; then # no other pool has a valid block for this slot either
          echo "MISSED: Leader for slot '${block_slot}' but not found in cncli db and no other pool has made a valid block for this slot"
          new_status="missed"
        else # another pool has a valid block for this slot in cncli db
          echo "STOLEN: Leader for slot '${block_slot}' but \"stolen\" by another pool due to bad luck (lower VRF output) :("
          new_status="stolen"
        fi
        sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = '${new_status}' WHERE slot = ${block_slot};"
      else # block found for this slot with a match for our vrf vkey
        [[ $((blocknum-block_data[0])) -lt ${CONFIRM_BLOCK_CNT} ]] && return # To make sure enough blocks has been built on top before validating
        if [[ ${slot_ok_cnt} -gt 0 ]]; then # our block not marked as orphaned :)
          echo "CONFIRMED: Leader for slot '${block_slot}' and match found in CNCLI DB for this slot with pool's VRF public key"
          [[ ${slot_cnt} -gt 1 ]] && echo "           WARNING!! Adversarial fork created, multiple blocks created for the same slot by the same pool :("
          new_status="confirmed"
        else # our block marked as orphaned :(
          if [[ ${slot_stolen_cnt} -eq 0 ]]; then # no other pool has a valid block for this slot either
            echo "GHOSTED: Leader for slot '${block_slot}' and block adopted but later orphaned. No other pool with a confirmed block for this slot, height battle or block propagation issue!"
            new_status="ghosted"
          else # another pool has a valid block for this slot in cncli db
            echo "STOLEN: Leader for slot '${block_slot}' but \"stolen\" by another pool due to bad luck (lower VRF output) :("
            new_status="stolen"
          fi
        fi
        sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = '${new_status}', slot_in_epoch = $(getSlotInEpochFromSlot ${block_slot} ${block_epoch}), block = ${block_data[0]}, at = '$(getDateFromSlot ${block_slot})', hash = '${block_data[1]}', size = ${block_data[2]} WHERE slot = ${block_slot};"
      fi
    else # Not old enough to confirm but slot time has passed
      if [[ ${block_status} = leader && ${slot_cnt} -gt 0 ]]; then # Leader status and block found in cncli db, update block data and set status adopted
        echo "ADOPTED: Leader for slot '${block_slot}' and adopted by chain, waiting for confirmation"
        sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'adopted', slot_in_epoch = $(getSlotInEpochFromSlot ${block_slot} ${block_epoch}), block = ${block_data[0]}, at = '$(getDateFromSlot ${block_slot})', hash = '${block_data[1]}', size = ${block_data[2]} WHERE slot = ${block_slot};"
        return
      fi
    fi
  fi
}

#################################

cncliInitBlocklogDB() {
  [[ "${PROTOCOL}" != "Cardano" ]] && echo "ERROR: protocol not Cardano mode, not a valid network" && exit 1
  if ! getPoolVrfVkeyCborHex; then exit 1; fi
  getNodeMetrics
  if ! getShelleyTransitionEpoch; then echo "ERROR: failed to calculate shelley transition epoch" && exit 1; fi
  if ! cncliDBinSync; then # verify that cncli DB is still in sync
    echo "CNCLI DB out of sync :( [$(printf "%2.4f %%" ${cncli_sync_prog})] ... check cncli sync service!"
    exit 1
  fi
  tip_diff=$(( $(getSlotTipRef) - slotnum ))
  [[ ${tip_diff} -gt 300 ]] && echo "ERROR: node still syncing, ${tip_diff} slots from theoretical tip" && exit 1
  createBlocklogDB || exit 1 # create db if needed
  echo "Looking for blocks made by pool..."
  block_cnt=0
  cncli_blocks=$(sqlite3 "${CNCLI_DB}" "SELECT block_number, slot_number, hash, block_size FROM chain WHERE node_vrf_vkey = '${pool_vrf_vkey_cbox_hex}' ORDER BY slot_number;")
  if [[ -n ${cncli_blocks} ]]; then
    while IFS='|' read -r block_number slot_number block_hash block_size; do
      # Calculate epoch, at and slot_in_epoch
      epoch=$(getEpochFromSlot ${slot_number})
      at=$(getDateFromSlot ${slot_number})
      slot_in_epoch=$(getSlotInEpochFromSlot ${slot_number} ${epoch})
      sqlite3 ${BLOCKLOG_DB} <<-EOF
				UPDATE OR IGNORE blocklog SET at = '${at}', epoch = ${epoch}, block = ${block_number}, slot_in_epoch = ${slot_in_epoch}, hash = '${block_hash}', size = ${block_size}, status = 'adopted'
				WHERE slot = ${slot_number};
				INSERT OR IGNORE INTO blocklog (slot, at, epoch, block, slot_in_epoch, hash, size, status)
				VALUES (${slot_number}, '${at}', ${epoch}, ${block_number}, ${slot_in_epoch}, '${block_hash}', ${block_size}, 'adopted');
				EOF
      ((block_cnt++))
    done < <(printf '%s\n' "${cncli_blocks}")
  fi
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
  getNodeMetrics
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
      else
        block_status="leader"
      fi
      sqlite3 ${BLOCKLOG_DB} <<-EOF
				UPDATE OR IGNORE blocklog SET at = '${block_at}', epoch = ${epoch}, slot_in_epoch = ${slot_in_epoch}, hash = '${block_hash}', size = ${block_size}, status = '${block_status}'
				WHERE slot = ${block_slot};
				INSERT OR IGNORE INTO blocklog (slot, at, epoch, slot_in_epoch, hash, size, status)
				VALUES (${block_slot}, '${block_at}', ${epoch}, ${slot_in_epoch}, '${block_hash}', ${block_size}, '${block_status}');
				EOF
      echo "Block at slot ${block_slot} added/updated, status '${block_status}'"
    done < <(jq -c '.[]' <<< "${blocks_data}" 2>/dev/null)
  done < <(find "${subarg}" -mindepth 1 -maxdepth 1 -type f -name "blocks_*.json" -print0 | sort -z)
}

#################################

cncliPTsendtip() {
  [[ ${NWMAGIC} -ne 764824073 ]] && echo "PoolTool sendtip only available on MainNet, exiting!" && exit 1
  [[ -z ${POOL_ID} || -z ${POOL_TICKER} || -z ${PT_API_KEY} ]] && echo "'POOL_ID' and/or 'POOL_TICKER' and/or 'PT_API_KEY' not set in $(basename "$0"), exiting!" && exit 1
  
  # Generate a temporary pooltool config
  if ! cnode_path=$(command -v cardano-node 2>/dev/null); then
    echo "ERROR: cardano-node not in PATH, please manually set CCLI in env file"
    exit 1
  fi
  pt_config="${TMP_DIR}/$(basename ${CNODE_HOME})-pooltool.json"
  bash -c "cat <<-'EOF' > ${pt_config}
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

cncliPTsendslots() {
  [[ ${NWMAGIC} -ne 764824073 ]] && echo "PoolTool sendslots only available on MainNet, exiting!" && exit 1
  [[ -z ${POOL_ID} || -z ${POOL_TICKER} || -z ${PT_API_KEY} ]] && echo "'POOL_ID' and/or 'POOL_TICKER' and/or 'PT_API_KEY' not set in $(basename "$0"), exiting!" && exit 1
  
  # Generate a temporary pooltool config
  pt_config="${TMP_DIR}/$(basename ${CNODE_HOME})-pooltool.json"
  bash -c "cat <<-'EOF' > ${pt_config}
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
  sendslots_epoch=-1
  while true; do
    [[ ${subarg} != "force" ]] && sleep ${SLEEP_RATE}
    getNodeMetrics
    [[ ${slotnum} -eq 0 ]] && continue # failed to grab node metrics
    [[ ${sendslots_epoch} -eq ${epochnum} ]] && continue # this epoch is already sent
    if [[ ( ${slot_in_epoch} -lt ${PT_SENDSLOTS_START} || ${slot_in_epoch} -gt ${PT_SENDSLOTS_STOP} ) && ${subarg} != "force" ]]; then # only allow slots to be sent in the interval defined (default 30-60 min after epoch boundary)
      [[ -t 1 ]] && echo "${FG_YELLOW}WARN${NC}: Configured window to send slots is ${FG_LBLUE}${PT_SENDSLOTS_START} - ${PT_SENDSLOTS_STOP}${NC} min after epoch boundary" && break
      continue 
    fi
    leaderlog_cnt=$(sqlite3 "${CNCLI_DB}" "SELECT COUNT(*) FROM slots WHERE epoch=${epochnum} and pool_id='${POOL_ID}';")
    [[ ${leaderlog_cnt} -eq 0 ]] && echo "ERROR: no leaderlogs for epoch ${epochnum} and pool id '${POOL_ID}' found in cncli DB" && continue
    cncli_ptsendslots=$(${CNCLI} sendslots --config "${pt_config}" --db "${CNCLI_DB}" --byron-genesis "${BYRON_GENESIS_JSON}" --shelley-genesis "${GENESIS_JSON}")
    echo -e "${cncli_ptsendslots}"
    if [[ $(jq -r '.status //empty' <<< "${cncli_ptsendslots}" 2>/dev/null) = "error" ]]; then continue; fi
    echo "Slots for epoch ${epochnum} successfully sent to PoolTool for pool id '${POOL_ID}' !"
    sendslots_epoch=${epochnum}
    [[ -t 1 ]] && break # manual execution of script in tty mode, exit after first run
  done
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
  ptsendslots )
    cncliInit && cncliPTsendslots ;;
  init )
    cncliInit && cncliInitBlocklogDB ;;
  migrate )
    cncliInit && cncliMigrateBlocklog ;;
  * ) usage ;;
esac
