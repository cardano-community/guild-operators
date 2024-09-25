#!/usr/bin/env bash
#shellcheck disable=SC2086,SC2154
#shellcheck source=/dev/null

. "$(dirname $0)"/env offline # source env in offline mode to get basic variables, sourced in online mode later in cncliInit()

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#POOL_ID=""                               # Automatically detected if POOL_NAME is set in env. Required for leaderlog calculation & pooltool sendtip, lower-case hex pool id
#POOL_ID_BECH32=""                        # Automatically detected if POOL_NAME is set in env. Required for leaderlog calculation with Koios API, lower-case pool id in bech32 format
#POOL_VRF_SKEY=""                         # Automatically detected if POOL_NAME is set in env. Required for leaderlog calculation, path to pool's vrf.skey file
#POOL_VRF_VKEY=""                         # Automatically detected if POOL_NAME is set in env. Required for block validation, path to pool's vrf.vkey file
#PT_API_KEY=""                            # POOLTOOL: set API key, e.g "a47811d3-0008-4ecd-9f3e-9c22bdb7c82d"
#POOL_TICKER=""                           # POOLTOOL: set the pools ticker, e.g "TCKR"
#PT_HOST="127.0.0.1"                      # POOLTOOL: connect to a remote node, preferably block producer (default localhost)
#PT_PORT="${CNODE_PORT}"                  # POOLTOOL: port of node to connect to (default CNODE_PORT from env file)
#PT_SENDSLOTS_START=30                    # POOLTOOL sendslots: delay after epoch boundary before sending slots (in minutes)
#PT_SENDSLOTS_STOP=60                     # POOLTOOL sendslots: prohibit sending of slots to pooltool after X number of minutes (in minutes, blocked on pooltool end as well)
#CNCLI_DIR="${CNODE_HOME}/guild-db/cncli" # path to folder for cncli sqlite db
#CNODE_HOST="127.0.0.1"                   # IP Address to connect to Cardano Node (using remote host can have severe impact on performance, do not modify unless you're absolutely certain)
#SLEEP_RATE=60                            # CNCLI leaderlog/validate: time to wait until next check (in seconds)
#CONFIRM_SLOT_CNT=600                     # CNCLI validate: require at least these many slots to have passed before validating
#CONFIRM_BLOCK_CNT=15                     # CNCLI validate: require at least these many blocks on top of minted before validating
#BATCH_AUTO_UPDATE=N                      # Set to Y to automatically update the script if a new version is available without user interaction
#CNCLI_PROM_PORT=12799                    # Set Prometheus port for cncli block metrics available through metrics operation (default: 12799)

######################################
# Do NOT modify code below           #
######################################

usage() {
  cat <<-EOF >&2
		
		Usage: $(basename "$0") [operation <sub arg>]
		Script to run CNCLI, best launched through systemd deployed by 'deploy-as-systemd.sh'
		
		-u          Skip script update check overriding UPDATE_CHECK value in env (must be first argument to script)

		sync        Start CNCLI chainsync process that connects to cardano-node to sync blocks stored in SQLite DB (deployed as service)
		leaderlog   One-time leader schedule calculation for current epoch, then continously monitors and calculates schedule for coming epochs, 1.5 days before epoch boundary on MainNet (deployed as service)
		  force     Manually force leaderlog calculation and overwrite even if already done, exits after leaderlog is calculated
		validate    Continously monitor and confirm that the blocks made actually was accepted and adopted by chain (deployed as service)
		  all       One-time re-validation of all blocks in blocklog db
		  epoch     One-time re-validation of blocks in blocklog db for the specified epoch
		epochdata   Manually re-calculate leaderlog to load stakepool history into epochdata table of blocklog db. Needs completion of cncli.sh sync and cncli.sh validate processes.
		  all       One-time re-calculation of all epochs (avg execution duration: 1hr / 50 epochs)
		  epoch     One-time re-calculation for the specified epoch
		ptsendtip   Send node tip to PoolTool for network analysis and to show that your node is alive and well with a green badge (deployed as service)
		ptsendslots Securely sends PoolTool the number of slots you have assigned for an epoch and validates the correctness of your past epochs (deployed as service)
		  force     Manually force pooltool sendslots submission ignoring configured time window
		init        One-time initialization adding all minted and confirmed blocks to blocklog
		metrics     Print cncli block metrics in Prometheus format
		  deploy    Install dependencies and deploy cncli monitoring agent service (available through port specified by CNCLI_PROM_PORT)
		  serve     Run Prometheus service (mainly for use by deployed systemd service though deploy argument)
		EOF
  exit 1
}

SKIP_UPDATE=N
[[ $1 = "-u" ]] && SKIP_UPDATE=Y && shift

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
      CREATE TABLE validationlog (id INTEGER PRIMARY KEY AUTOINCREMENT, event TEXT NOT NULL, at TEXT NOT NULL UNIQUE, env TEXT NOT NULL, final_chunk INTEGER, initial_chunk INTEGER);
			CREATE TABLE replaylog (id INTEGER PRIMARY KEY AUTOINCREMENT, event TEXT NOT NULL, at TEXT NOT NULL UNIQUE, env TEXT NOT NULL, slot INTEGER, tip INTEGER);
      CREATE TABLE statistics (id INTEGER PRIMARY KEY AUTOINCREMENT, event TEXT NOT NULL, start INTEGER, end INTEGER, env TEXT NOT NULL);
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

getLedgerData() { # getNodeMetrics expected to have been already run
  if ! stake_snapshot=$(${CCLI} ${NETWORK_ERA} query stake-snapshot --stake-pool-id ${POOL_ID} ${NETWORK_IDENTIFIER} 2>&1); then
    echo "ERROR: stake-snapshot query failed: ${stake_snapshot}"
    return 1
  fi
  pool_stake_mark=$(jq -r ".pools[\"${POOL_ID}\"].stakeMark" <<< ${stake_snapshot})
  active_stake_mark=$(jq -r .total.stakeMark <<< ${stake_snapshot})
  pool_stake_set=$(jq -r ".pools[\"${POOL_ID}\"].stakeSet" <<< ${stake_snapshot})
  active_stake_set=$(jq -r .total.stakeSet <<< ${stake_snapshot})
  return 0
}

getConsensus() {
  if isNumber "$1"; then
     getProtocolParamsHist "$(( $1 - 1 ))" || return 1
  else
     getProtocolParams || return 1
  fi
  if versionCheck "9.0" "${PROT_VERSION}"; then
    consensus="cpraos"
    stability_window_factor=3
  elif versionCheck "7.0" "${PROT_VERSION}"; then
    consensus="praos"
    stability_window_factor=2
  else
    consensus="tpraos"
    stability_window_factor=2
  fi
}

getKoiosData() {
  if ! stake_snapshot=$(curl -sSL -f "${KOIOS_API_HEADERS[@]}" -d _pool_bech32=${POOL_ID_BECH32} "${KOIOS_API}/pool_stake_snapshot" 2>&1); then
    echo "ERROR: Koios pool_stake_snapshot query failed: curl -sSL -f ${KOIOS_API_HEADERS[*]} -d _pool_bech32=${POOL_ID_BECH32} ${KOIOS_API}/pool_stake_snapshot"
    return 1
  fi
  read -ra stake_mark <<<"$(jq -r '.[] | select(.snapshot=="Mark") | [.pool_stake, .active_stake, .nonce] | @tsv' <<< ${stake_snapshot})"
  read -ra stake_set <<<"$(jq -r '.[] | select(.snapshot=="Set") | [.pool_stake, .active_stake, .nonce] | @tsv' <<< ${stake_snapshot})"
  pool_stake_mark=${stake_mark[0]}
  active_stake_mark=${stake_mark[1]}
  nonce_mark=${stake_mark[2]}
  pool_stake_set=${stake_set[0]}
  active_stake_set=${stake_set[1]}
  nonce_set=${stake_set[2]}
  return 0
}

#################################

# shellcheck disable=SC2120
cncliInit() {
  if renice_cmd="$(command -v renice)"; then ${renice_cmd} -n 19 $$ >/dev/null; fi
  [[ -z "${BATCH_AUTO_UPDATE}" ]] && BATCH_AUTO_UPDATE=N
  if ! command -v sqlite3 >/dev/null; then echo "ERROR: sqlite3 not found, please install before activating blocklog function" && exit 1; fi
  PARENT="$(dirname $0)"
  
  #######################################################
  # Version Check                                       #
  #######################################################
  clear
  
  if [[ ! -f "${PARENT}"/env ]]; then
    echo -e "\nCommon env file missing: ${PARENT}/env"
    echo -e "This is a mandatory prerequisite, please install with guild-deploy.sh or manually download from GitHub\n"
    exit 1
  fi
  
  . "${PARENT}"/env offline &>/dev/null # ignore any errors, re-sourced later
  
  if [[ ${UPDATE_CHECK} = Y && ${SKIP_UPDATE} != Y ]]; then

    echo "Checking for script updates..."

    # Check availability of checkUpdate function
    if [[ ! $(command -v checkUpdate) ]]; then
      echo -e "\nCould not find checkUpdate function in env, make sure you're using official guild docos for installation!"
      exit 1
    fi

    # check for env update
    ENV_UPDATED=${BATCH_AUTO_UPDATE}
    checkUpdate "${PARENT}"/env N N N
    case $? in
      1) ENV_UPDATED=Y ;;
      2) exit 1 ;;
    esac

    # check for cncli.sh update
    checkUpdate "${PARENT}"/cncli.sh ${ENV_UPDATED}
    case $? in
      1) $0 "-u" "$@"; exit 0 ;; # re-launch script with same args skipping update check
      2) exit 1 ;;
    esac
  fi

  # source common env variables in case it was updated
  until . "${PARENT}"/env; do
    echo "sleeping for 10s and testing again..."
    sleep 10
  done

  test_koios

  TMP_DIR="${TMP_DIR}/cncli"
  if ! mkdir -p "${TMP_DIR}" 2>/dev/null; then echo "ERROR: Failed to create directory for temporary files: ${TMP_DIR}"; exit 1; fi
  
  [[ ! -f "${CNCLI}" ]] && echo -e "\nERROR: failed to locate cncli executable, please install with 'guild-deploy.sh'\n" && exit 1
  CNCLI_VERSION="v$(cncli -V | cut -d' ' -f2)"
  if ! versionCheck "6.0.0" "${CNCLI_VERSION}"; then echo "ERROR: cncli ${CNCLI_VERSION} installed, minimum required version is 6.0.0, please upgrade to latest version!"; exit 1; fi
  
  [[ -z "${CNCLI_DIR}" ]] && CNCLI_DIR="${CNODE_HOME}/guild-db/cncli"
  if ! mkdir -p "${CNCLI_DIR}" 2>/dev/null; then echo "ERROR: Failed to create CNCLI DB directory: ${CNCLI_DIR}"; exit 1; fi
  CNCLI_DB="${CNCLI_DIR}/cncli.db"
  [[ -z "${CNODE_HOST}" ]] && CNODE_HOST="127.0.0.1"
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
    [[ -z "${POOL_ID_BECH32}" && -f "${POOL_DIR}/${POOL_ID_FILENAME}-bech32" ]] && POOL_ID_BECH32=$(cat "${POOL_DIR}/${POOL_ID_FILENAME}-bech32")
    [[ -z "${POOL_VRF_SKEY}" ]] && POOL_VRF_SKEY="${POOL_DIR}/${POOL_VRF_SK_FILENAME}"
    [[ -z "${POOL_VRF_VKEY}" ]] && POOL_VRF_VKEY="${POOL_DIR}/${POOL_VRF_VK_FILENAME}"
  fi

  # export SHELLEY_TRANS_EPOCH to be seen by cncli
  export SHELLEY_TRANS_EPOCH

  return 0
}

#################################

cncliSync() {
  ${CNCLI} sync --host "${CNODE_HOST}" --network-magic "${NWMAGIC}" --port "${CNODE_PORT}" --db "${CNCLI_DB}" --shelley-genesis-hash "${GENESIS_HASH}"
}

#################################

cncliLeaderlog() {
  echo "~ CNCLI Leaderlog started ~"
  createBlocklogDB || exit 1 # create db if needed
  [[ -z ${POOL_ID} || -z ${POOL_ID_BECH32} || -z ${POOL_VRF_SKEY} ]] && echo "'POOL_ID'/'POOL_ID_BECH32' and/or 'POOL_VRF_SKEY' not set in $(basename "$0"), exiting!" && exit 1
  
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
  getConsensus
  curr_epoch=${epochnum}
  if [[ $(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM epochdata WHERE epoch=${curr_epoch};" 2>/dev/null) -eq 1 && ${subarg} != "force" ]]; then
    echo "Leaderlogs already calculated for epoch ${curr_epoch}, skipping!"
  else
    echo "Running leaderlogs for epoch ${curr_epoch}"
    if [[ -n ${KOIOS_API} ]]; then 
      getKoiosData || exit 1
    else
      getLedgerData || exit 1
    fi
    stake_param_current="--active-stake ${active_stake_set} --pool-stake ${pool_stake_set}"
    [[ -n "${nonce_set}" ]] && stake_param_current="${stake_param_current} --nonce ${nonce_set}"
    cncli_leaderlog=$(${CNCLI} leaderlog --consensus "${consensus}" --db "${CNCLI_DB}" --byron-genesis "${BYRON_GENESIS_JSON}" --shelley-genesis "${GENESIS_JSON}" --ledger-set current ${stake_param_current} --pool-id "${POOL_ID}" --pool-vrf-skey "${POOL_VRF_SKEY}" --tz UTC)
    if [[ $(jq -r .status <<< "${cncli_leaderlog}") != ok ]]; then
      error_msg=$(jq -r .errorMessage <<< "${cncli_leaderlog}")
      if [[ "${error_msg}" = "Query returned no rows" ]]; then
        echo "No leader slots found for epoch ${curr_epoch} :("
      else
        echo "ERROR: failure in leaderlog while running:"
        echo "${CNCLI} leaderlog --consensus ${consensus} --db ${CNCLI_DB} --byron-genesis ${BYRON_GENESIS_JSON} --shelley-genesis ${GENESIS_JSON} --ledger-set current ${stake_param_current} --pool-id ${POOL_ID} --pool-vrf-skey ${POOL_VRF_SKEY} --tz UTC"
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
      if block_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${curr_epoch};" 2>/dev/null) && [[ ${block_cnt} -gt 0 ]]; then
        echo -e "\nPruning ${block_cnt} entries from blocklog db for epoch ${curr_epoch}\n"
        sqlite3 "${BLOCKLOG_DB}" "DELETE FROM blocklog WHERE epoch=${curr_epoch};" 2>/dev/null
      fi
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
    getConsensus
    if ! cncliDBinSync; then # verify that cncli DB is still in sync
      echo "CNCLI DB out of sync :( [$(printf "%2.4f %%" ${cncli_sync_prog})] ... checking again in ${SLEEP_RATE}s"
      [[ ${subarg} = force ]] && sleep ${SLEEP_RATE}
      continue
    fi
    # firstSlotOfNextEpoch - stabilityWindow((3|4) * k / f)
    # due to issues with timing, calculation is moved one tick to 8/10 of epoch for pre conway, and 7/10 post conway.
    slot_for_next_nonce=$(echo "(${slotnum} - ${slot_in_epoch} + ${EPOCH_LENGTH}) - (${stability_window_factor} * ${BYRON_K} / ${ACTIVE_SLOTS_COEFF})" | bc)
    curr_epoch=${epochnum}
    next_epoch=$((curr_epoch+1))
    if [[ ${slotnum} -gt ${slot_for_next_nonce} ]]; then # Time to run leaderlogs for next epoch?
      if [[ $(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM epochdata WHERE epoch=${next_epoch};" 2>/dev/null) -eq 1 ]]; then # Leaderlogs already calculated for next epoch, skipping!
        if [[ -t 1 ]]; then # manual execution
          [[ ${subarg} != "force" ]] && echo "Leaderlogs already calculated for epoch ${next_epoch}, skipping!" && break
        else continue; fi
      fi
      echo "Running leaderlogs for next epoch[${next_epoch}]"
      if [[ -n ${KOIOS_API} ]]; then
        if ! getKoiosData; then sleep 60; continue; fi # Sleep for 1 min before retrying to query koios again in case of error
      else
        if ! getLedgerData; then sleep 300; continue; fi # Sleep for 5 min before retrying to query stake snapshot in case of error
      fi
      stake_param_next="--active-stake ${active_stake_mark} --pool-stake ${pool_stake_mark}"
      [[ -n "${nonce_mark}" ]] && stake_param_next="${stake_param_next} --nonce ${nonce_mark}"
      cncli_leaderlog=$(${CNCLI} leaderlog --consensus "${consensus}" --db "${CNCLI_DB}" --byron-genesis "${BYRON_GENESIS_JSON}" --shelley-genesis "${GENESIS_JSON}" --ledger-set next ${stake_param_next} --pool-id "${POOL_ID}" --pool-vrf-skey "${POOL_VRF_SKEY}" --tz UTC)
      if [[ $(jq -r .status <<< "${cncli_leaderlog}") != ok ]]; then
        error_msg=$(jq -r .errorMessage <<< "${cncli_leaderlog}")
        if [[ "${error_msg}" = "Query returned no rows" ]]; then
          echo "No leader slots found for epoch ${curr_epoch} :("
        else
          echo "ERROR: failure in leaderlog while running:"
          echo "${CNCLI} leaderlog --consensus ${consensus} --db ${CNCLI_DB} --byron-genesis ${BYRON_GENESIS_JSON} --shelley-genesis ${GENESIS_JSON} --ledger-set next ${stake_param_next} --pool-id ${POOL_ID} --pool-vrf-skey ${POOL_VRF_SKEY} --tz UTC"
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
        if block_cnt=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch=${next_epoch};" 2>/dev/null) && [[ ${block_cnt} -gt 0 ]]; then
          echo -e "\nPruning ${block_cnt} entries from blocklog db for epoch ${next_epoch}\n"
          sqlite3 "${BLOCKLOG_DB}" "DELETE FROM blocklog WHERE epoch=${next_epoch};" 2>/dev/null
        fi
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

cncliMetrics() {
  if [[ ${subarg} = "deploy" ]]; then
    deployMonitoringAgent
    return
  elif [[ ${subarg} = "serve" ]]; then
    if ! command -v socat >/dev/null; then
      echo "ERROR: socat not installed, please first run cncli.sh metrics deploy to install socat and deploy service, or manually install socat."
      return
    fi
    socat TCP-LISTEN:${CNCLI_PROM_PORT:-12799},reuseaddr,fork SYSTEM:"echo HTTP/1.1 200 OK;SERVED=true bash ${CNODE_HOME}/scripts/cncli.sh metrics;"
    return
  fi
  getNodeMetrics
  getBlocklogMetrics ${epochnum}
}

deployMonitoringAgent() {
  # Install socat if needed to allow metrics operation to listen on port
  if ! command -v socat >/dev/null; then
    echo -e "Installing socat .."
    if command -v apt-get >/dev/null; then
      sudo apt-get -y install socat >/dev/null || err_exit "'sudo apt-get -y install socat' failed!"
    elif command -v dnf >/dev/null; then
      sudo dnf -y install socat >/dev/null || err_exit "'sudo dnf -y install socat' failed!"
    else
      err_exit "'socat' not found in \$PATH, needed to for node exporter monitoring!"
    fi
  fi
  echo -e "[Re]Installing CNCLI Monitoring Agent service.."
  sudo bash -c "cat <<-EOF > /etc/systemd/system/${CNODE_VNAME}-cncli-exporter.service
[Unit]
Description=CNCLI Metrics Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
User=${USER}
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cncli.sh metrics serve\"
KillSignal=SIGINT
SuccessExitStatus=143
SyslogIdentifier=${CNODE_VNAME}_cncli_exporter
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF"
  sudo systemctl daemon-reload && sudo systemctl enable ${CNODE_VNAME}-cncli-exporter.service &>/dev/null && sudo systemctl restart ${CNODE_VNAME}-cncli-exporter.service &>/dev/null
  echo -e "Done!!"
}

getBlocklogMetrics() {
  shopt -s expand_aliases
  if [[ ${SERVED} = true ]]; then
    echo "Content-type: text/plain" # Tells the browser what kind of content to expect
    echo "" # request body starts from this empty line
  fi

  cncli_error_code=0
  next_leader_time_utc=0
  next_next_leader_time_utc=0
  leader=0
  ideal=0
  luck=0
  adopted_total=0
  confirmed_total=0
  missed_total=0
  ghosted_total=0
  stolen_total=0
  invalid_total=0
  adopted_max_consec=0
  confirmed_max_consec=0
  missed_max_consec=0
  ghosted_max_consec=0
  stolen_max_consec=0
  invalid_max_consec=0

  [[ -z "${CNCLI_DIR}" ]] && CNCLI_DIR="${CNODE_HOME}/guild-db/cncli"
  CNCLI_DB="${CNCLI_DIR}/cncli.db"
  
  unset cncli_error
  if [[ ! -f "${BLOCKLOG_DB}" ]]; then
    cncli_error="ERROR: blocklog database not found: ${BLOCKLOG_DB}" && cncli_error_code=1
  elif ! cncliDBinSync; then
    cncli_error="CNCLI DB out of sync :( [$(printf "%2.4f %%" ${cncli_sync_prog})]" && cncli_error_code=1
  else
    for status_type in $(sqlite3 "${BLOCKLOG_DB}" "SELECT status, COUNT(status) FROM blocklog WHERE epoch=${epochnum} GROUP BY status;" 2>/dev/null); do
      IFS='|' read -ra status <<< ${status_type}; unset IFS
      case ${status[0]} in
        invalid) invalid_total=${status[1]} ;;
        missed) missed_total=${status[1]} ;;
        ghosted) ghosted_total=${status[1]} ;;
        stolen) stolen_total=${status[1]} ;;
        confirmed) confirmed_total=${status[1]} ;;
        adopted) adopted_total=${status[1]} ;;
        leader) leader=${status[1]} ;;
      esac
    done
    adopted_total=$(( adopted_total + confirmed_total ))
    leader=$(( leader + adopted_total + invalid_total + missed_total + ghosted_total + stolen_total ))
    next_leader_time_utc=$(sqlite3 "${BLOCKLOG_DB}" "SELECT STRFTIME('%s', at) FROM blocklog WHERE datetime(at) > datetime('now') ORDER BY slot ASC LIMIT 1;" 2>/dev/null)
    if [[ -z ${next_leader_time_utc} ]]; then
      next_leader_time_utc=0
    else
      next_next_leader_time_utc=$(sqlite3 "${BLOCKLOG_DB}" "SELECT STRFTIME('%s', at) FROM blocklog WHERE CAST(STRFTIME('%s', at) AS INTEGER) > ${next_leader_time_utc} ORDER BY slot ASC LIMIT 1;" 2>/dev/null)
      [[ -z ${next_next_leader_time_utc} ]] && next_next_leader_time_utc=0
    fi
    IFS='|' read -ra epoch_stats <<< "$(sqlite3 "${BLOCKLOG_DB}" "SELECT epoch_slots_ideal, max_performance FROM epochdata WHERE epoch=${epochnum};" 2>/dev/null)"; unset IFS
    if [[ ${#epoch_stats[@]} -eq 2 ]]; then
      ideal=${epoch_stats[0]}
      luck=${epoch_stats[1]}
    fi
    for max_consecutive in $(sqlite3 "${BLOCKLOG_DB}" "SELECT status, MAX(seqnum) FROM (SELECT status, COUNT(*) AS seqnum FROM (SELECT blocklog.*, (ROW_NUMBER() OVER (ORDER BY id) - ROW_NUMBER() OVER (PARTITION BY status ORDER BY id)) AS seqnum FROM blocklog WHERE epoch=${epochnum}) tmp GROUP BY seqnum, status) GROUP BY status;"); do
      IFS='|' read -ra consecutive <<< ${max_consecutive}; unset IFS
      case ${consecutive[0]} in
        invalid) invalid_max_consec=${consecutive[1]} ;;
        missed) missed_max_consec=${consecutive[1]} ;;
        ghosted) ghosted_max_consec=${consecutive[1]} ;;
        stolen) stolen_max_consec=${consecutive[1]} ;;
        confirmed) confirmed_max_consec=${consecutive[1]} ;;
        adopted) adopted_max_consec=${consecutive[1]} ;;
      esac
    done
    adopted_max_consec=$(( adopted_max_consec + confirmed_max_consec ))
  fi

  if [[ ${SERVED} != true && -n ${cncli_error} ]]; then
    echo ${cncli_error} && return
  fi

  # Metrics
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_next_leader_time_utc=${next_leader_time_utc}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_next_next_leader_time_utc=${next_next_leader_time_utc}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_leader=${leader}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_ideal=${ideal}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_luck=${luck}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_adopted_total=${adopted_total}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_confirmed_total=${confirmed_total}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_missed_total=${missed_total}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_ghosted_total=${ghosted_total}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_stolen_total=${stolen_total}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_invalid_total=${invalid_total}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_adopted_max_consec=${adopted_max_consec}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_confirmed_max_consec=${confirmed_max_consec}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_missed_max_consec=${missed_max_consec}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_ghosted_max_consec=${ghosted_max_consec}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_stolen_max_consec=${stolen_max_consec}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_invalid_max_consec=${invalid_max_consec}
  export CNCLI_METRIC_cntools_cncli_blocks_metrics_error=${cncli_error_code}

  for metric_var_name in $(env | grep ^CNCLI_METRIC_ | sort | awk -F= '{print $1}'); do
    METRIC_NAME=${metric_var_name//CNCLI_METRIC_/}
    # default NULL values to empty string
    if [[ -z "${!metric_var_name}" ]]; then
      METRIC_VALUE="\"\""
    else
      METRIC_VALUE="${!metric_var_name}"
    fi
    echo "${METRIC_NAME} ${METRIC_VALUE}"
  done
}

#################################

cncliPTsendtip() {
  [[ ${NWMAGIC} -ne 764824073 ]] && echo "PoolTool sendtip only available on MainNet, exiting!" && exit 1
  [[ -z ${POOL_ID} || -z ${POOL_TICKER} || -z ${PT_API_KEY} ]] && echo "'POOL_ID' and/or 'POOL_TICKER' and/or 'PT_API_KEY' not set in $(basename "$0"), exiting!" && exit 1
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
  ${CNCLI} sendtip --config "${pt_config}" --cardano-node "${CNODEBIN}"
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
# epochdata table load process  #
#################################

getCurrNextEpoch() {
  getNodeMetrics
  curr_epoch=${epochnum}
  next_epoch=$((curr_epoch+1))
}

runCurrentEpoch() {
  getKoiosData
  echo "Processing current epoch: ${1}"
  stake_param_curr="--active-stake ${active_stake_set} --pool-stake ${pool_stake_set}"

  ${CNCLI} leaderlog ${cncliParams} --consensus "${consensus}" --epoch="${1}" ${stake_param_curr} |
  jq -r '[.epoch, .epochNonce, .poolId, .sigma, .d, .epochSlotsIdeal, .maxPerformance, .activeStake, .totalActiveStake] | @csv' |
  tr -d '"' >> "$tmpcsv"
}

runNextEpoch() {
  getKoiosData
  getNodeMetrics
  getConsensus
  slot_for_next_nonce=$(echo "(${slotnum} - ${slot_in_epoch} + ${EPOCH_LENGTH}) - (${stability_window_factor} * ${BYRON_K} / ${ACTIVE_SLOTS_COEFF})" | bc)
  curr_epoch=${epochnum}
  next_epoch=$((curr_epoch+1))

  if [[ ${slotnum} -gt ${slot_for_next_nonce} ]]; then
      if [[ $(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM epochdata WHERE epoch=${next_epoch};" 2>/dev/null) -eq 1 ]]; then
        echo "Leaderlogs already calculated for epoch ${next_epoch}, skipping!" && return 1
      else
        echo "Processing next epoch: ${1}"
        stake_param_next="--active-stake ${active_stake_mark} --pool-stake ${pool_stake_mark}"
        ${CNCLI} leaderlog ${cncliParams} --consensus "${consensus}" --epoch="${1}" ${stake_param_next} |
        jq -r '[.epoch, .epochNonce, .poolId, .sigma, .d, .epochSlotsIdeal, .maxPerformance, .activeStake, .totalActiveStake] | @csv' |
        tr -d '"' >> "$tmpcsv"
      fi
  fi
}

runPreviousEpochs() {
  [[ -z ${KOIOS_API} ]] && return 1
  if ! pool_hist=$(curl -sSL -f "${KOIOS_API}/pool_history?_pool_bech32=${POOL_ID_BECH32}&_epoch_no=${1}" 2>&1); then
    echo "ERROR: Koios pool_stake_snapshot history query failed."
    return 1
  fi

  if ! epoch_hist=$(curl -sSL -f "${KOIOS_API}/epoch_info?_epoch_no=${1}" 2>&1); then
    echo "ERROR: Koios epoch_stake_snapshot history query failed."
    return 1
  fi

  pool_stake_hist=$(jq -r '.[].active_stake' <<< "${pool_hist}")
  active_stake_hist=$(jq -r '.[].active_stake' <<< "${epoch_hist}")

  echo "Processing previous epoch: ${1}"
  stake_param_prev="--active-stake ${active_stake_hist} --pool-stake ${pool_stake_hist}"

  ${CNCLI} leaderlog ${cncliParams} --consensus "${consensus}" --epoch="${1}" ${stake_param_prev} |
  jq -r '[.epoch, .epochNonce, .poolId, .sigma, .d, .epochSlotsIdeal, .maxPerformance, .activeStake, .totalActiveStake] | @csv' |
  tr -d '"' >> "$tmpcsv"

  return 0
}

processAllEpochs() {
  getCurrNextEpoch
  IFS=' ' read -r -a epochs_array <<< "$EPOCHS"

  for epoch in "${epochs_array[@]}"; do
    if ! getConsensus "${epoch}"; then echo "ERROR: Failed to fetch protocol parameters for epoch ${epoch}."; return 1; fi
    if [[ "$epoch" == "$curr_epoch" ]]; then
      runCurrentEpoch ${epoch}
    elif [[ "$epoch" == "$next_epoch" ]]; then
      runNextEpoch ${epoch}
    else
      runPreviousEpochs ${epoch}
    fi
  done

  id=1
  while IFS= read -r row; do
    echo "$id,$row" >> "$csvfile"
    ((id++))
  done < "$tmpcsv"

  sqlite3 "$BLOCKLOG_DB" <<EOF
DELETE FROM epochdata;
VACUUM;
.mode csv
.import '$csvfile' epochdata
REINDEX epochdata;
EOF

  row_count=$(sqlite3 "$BLOCKLOG_DB" "SELECT COUNT(*) FROM epochdata;")
  echo "$row_count rows have been loaded into epochdata table in blocklog db"
  echo "~ CNCLI epochdata table load completed ~"

  rm $csvfile $tmpcsv
}

processSingleEpoch() {
  getCurrNextEpoch
  IFS=' ' read -r -a epochs_array <<< "$EPOCHS"

  unset matched
  for epoch in "${epochs_array[@]}"; do
    [[ ${epoch} = "$1" ]] && matched=true && break
  done
  if [[ -z ${matched} ]]; then
    echo -e "No slots found in blocklog table for epoch ${1}.\n"
    echo -e "choose from epochs in list:\n $EPOCHS"; return 1
  fi
  if ! getConsensus "${1}"; then echo "ERROR: Failed to fetch protocol parameters for epoch ${1}."; return 1; fi
  if [[ "$1" == "$curr_epoch" ]]; then
     runCurrentEpoch ${1}
  elif [[ "$1" == "$next_epoch" ]]; then
     runNextEpoch ${1}
  else
     runPreviousEpochs ${1}
  fi

  ID=$(sqlite3 "$BLOCKLOG_DB" "SELECT max(id) + 1 FROM epochdata;")
  csv_row=$(cat "$tmpcsv")
  modified_csv_row="${ID},${csv_row}"
  echo "$modified_csv_row" > "$onerow_csv"

  sqlite3 "$BLOCKLOG_DB" "DELETE FROM epochdata WHERE epoch = ${1};"
  sqlite3 "$BLOCKLOG_DB" <<EOF
.mode csv
.import "$onerow_csv" epochdata
REINDEX epochdata;
EOF
   row_count=$(sqlite3 "$BLOCKLOG_DB" "SELECT COUNT(*) FROM epochdata WHERE epoch = ${1};")
   echo "$row_count row has been loaded into epochdata table in blocklog db for epoch ${1}"
   echo "~ CNCLI epochdata table load completed ~"
   echo

   rm $onerow_csv $tmpcsv
}

cncliEpochData() {
  getNodeMetrics
  cncliParams="--db ${CNCLI_DB} --byron-genesis ${BYRON_GENESIS_JSON} --shelley-genesis ${GENESIS_JSON} --pool-id ${POOL_ID} --pool-vrf-skey ${POOL_VRF_SKEY} --tz UTC"
  EPOCHS=$(sqlite3 "$BLOCKLOG_DB" "SELECT group_concat(epoch,' ') FROM (SELECT DISTINCT epoch FROM blocklog ORDER BY epoch);")
  csvdir=/tmp ; tmpcsv="${csvdir}/epochdata_tmp.csv" ; csvfile="${csvdir}/epochdata.csv" ; onerow_csv="${csvdir}/one_epochdata.csv"
  true > "$tmpcsv" ; true > "$csvfile" ; true > "$onerow_csv"

  proc_msg="~ CNCLI epochdata table load started ~"

  if ! cncliDBinSync; then
    echo ${proc_msg}
    echo "CNCLI DB out of sync :( [$(printf "%2.4f %%" ${cncli_sync_prog})] ... check cncli sync service!"
    exit 1
  else
    echo ${proc_msg}
    getLedgerData

    if [[ "${subcommand}" == "epochdata" ]]; then
        if [[ ${subarg} == "all" ]]; then
           processAllEpochs
      elif isNumber "${subarg}"; then
           processSingleEpoch "${subarg}"
    else
        echo
        echo "ERROR: unknown argument passed to validate command, valid options incl the string 'all' or the epoch number to recalculate"
        echo
        exit 1
      fi
    fi
  fi
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
  metrics )
    cncliMetrics ;; # no cncliInit needed
  epochdata )
    cncliInit && cncliEpochData ;;
  * )
    usage ;;
esac
