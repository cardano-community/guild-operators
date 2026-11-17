#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2086,SC2154
# Leader schedule for an Amaru block producer, kept in the blocklog database.

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#POOL_ID=""                               # Pool id in hex (default: pool.id in the pool folder, else derived from the operational certificate)
#POOL_VRF_SKEY=""                         # VRF signing key (default: ${POOL_FOLDER}/${POOL_NAME}/${POOL_VRF_SK_FILENAME})
#SLEEP_RATE=60                            # Seconds between checks while running as a service

######################################
# Do NOT modify code below           #
######################################

PARENT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  cat <<EOF >&2

Usage: $(basename "$0") [operation <sub arg>]
       $(basename "$0") -d
       $(basename "$0") systemd <install|remove|status>
Leader schedule for an Amaru block producer. The systemd unit is owned by this script.

-d          Install the leaderlog systemd unit.
systemd     Install, remove, or show the status of the leaderlog unit.

leaderlog   Calculate the leader schedule for the current epoch, then keep running and calculate the schedule for the next epoch
            once its nonce is final, about 2 days before the epoch boundary on MainNet (deployed as service)
  force     Calculate now and overwrite what is stored, exits after the leaderlog is calculated

EOF
  exit 1
}

subarg=""
if [[ ${1:-} == "-d" ]]; then
  [[ $# -eq 1 ]] || usage
  subcommand="systemd"
  SYSTEMD_ACTION="install"
elif [[ ${1:-} == "systemd" ]]; then
  [[ $# -eq 2 ]] || usage
  subcommand="systemd"
  SYSTEMD_ACTION="${2}"
elif [[ ${1:-} == "leaderlog" && $# -eq 1 ]]; then
  subcommand="leaderlog"
elif [[ ${1:-} == "leaderlog" && $# -eq 2 && ${2} == "force" ]]; then
  subcommand="leaderlog"
  subarg="force"
else usage; fi

######################################

if [[ ! -f "${PARENT}/env" ]]; then
  echo "ERROR: Common env file is missing: ${PARENT}/env" >&2
  exit 1
fi
if [[ "${subcommand}" == "systemd" ]]; then
  . "${PARENT}/env" definitions || exit 1
else
  . "${PARENT}/env" monitor || exit 1
fi
if [[ "${NODE_IMPLEMENTATION}" != "amaru" ]]; then
  echo "ERROR: $(basename "$0") is for an Amaru deployment, ${NODE_HOME} runs ${NODE_IMPLEMENTATION}." >&2
  exit 1
fi

LEADERLOG_SCRIPT="${NODE_HOME}/scripts/amaru-leaderlog.sh"
LEADERLOG_UNIT="${NODE_SERVICE}-leaderlog.service"

load_systemd_library() {
  local systemd_library="${PARENT}/lib/systemd.library"
  if [[ ! -f "${systemd_library}" ]]; then
    echo "ERROR: systemd.library is missing. Re-run the deployment script to install shared helpers." >&2
    return 1
  fi
  . "${systemd_library}"
}

# The node launcher sources amaru.env before it starts Amaru. Read the same
# file in a child shell, so the schedule is calculated from the databases and
# with the binary the node uses, and none of the node settings leak into this
# process.
loadAmaruSettings() {
  local amaru_env="${PARENT}/amaru.env"
  local output="" i
  local -a variables=(AMARU_BIN AMARU_STATE_ROOT AMARU_DB_CHAIN AMARU_DB_LEDGER)
  local -a values=()

  if [[ ! -r "${amaru_env}" ]]; then
    echo "ERROR: Amaru environment file is missing: ${amaru_env}" >&2
    return 1
  fi
  # shellcheck disable=SC2016  # expanded by the child shell
  if ! output="$(
    "${BASH}" -c '
      set +eu
      . "$1" >/dev/null || exit 1
      shift
      for var in "$@"; do printf "%s\n" "${!var}"; done
      printf "end\n"
    ' amaru-env "${amaru_env}" "${variables[@]}"
  )"; then
    echo "ERROR: failed to load the Amaru settings from ${amaru_env}" >&2
    return 1
  fi
  mapfile -t values <<< "${output}"
  if (( ${#values[@]} != ${#variables[@]} + 1 )) ||
     [[ "${values[${#variables[@]}]}" != "end" ]]; then
    echo "ERROR: unexpected Amaru settings from ${amaru_env}" >&2
    return 1
  fi
  for i in "${!variables[@]}"; do
    printf -v "LEADERLOG_${variables[i]}" '%s' "${values[i]}"
  done
  if [[ -n "${LEADERLOG_AMARU_STATE_ROOT}" ]]; then
    LEADERLOG_AMARU_DB_CHAIN="${LEADERLOG_AMARU_STATE_ROOT%/}/chain"
    LEADERLOG_AMARU_DB_LEDGER="${LEADERLOG_AMARU_STATE_ROOT%/}/ledger"
  fi
  : "${LEADERLOG_AMARU_BIN:=${NODE_HOME}/bin/amaru}"
  : "${LEADERLOG_AMARU_DB_CHAIN:=${NODE_HOME}/chain}"
  : "${LEADERLOG_AMARU_DB_LEDGER:=${NODE_HOME}/ledger}"
}

# The operational certificate ends with the cold verification key. The pool id
# is the blake2b-224 hash of that key.
getPoolIdFromOpCert() {
  local opcert_file="$1" cbor_hex
  cbor_hex=$(jq -er '.cborHex' "${opcert_file}" 2>/dev/null) || return 1
  cbor_hex="${cbor_hex,,}"
  [[ "${cbor_hex}" =~ ^82845820[0-9a-f]+5820([0-9a-f]{64})$ ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}" | xxd -r -p | b2sum -l 224 | cut -d' ' -f1
}

loadPoolSettings() {
  local pool_dir="${POOL_FOLDER}/${POOL_NAME}"

  [[ -z "${POOL_VRF_SKEY}" ]] && POOL_VRF_SKEY="${pool_dir}/${POOL_VRF_SK_FILENAME}"
  if [[ ! -f "${POOL_VRF_SKEY}" || ! -r "${POOL_VRF_SKEY}" ]]; then
    echo "ERROR: VRF signing key is missing or not readable: ${POOL_VRF_SKEY}" >&2
    echo "The leader schedule is calculated on the block producer. Set POOL_NAME in ${PARENT}/env to the pool folder that holds the key." >&2
    return 1
  fi
  if [[ -z "${POOL_ID}" ]]; then
    if [[ -f "${pool_dir}/${POOL_ID_FILENAME}" ]]; then
      POOL_ID=$(tr -d '[:space:]' < "${pool_dir}/${POOL_ID_FILENAME}")
    elif [[ -f "${pool_dir}/${POOL_OPCERT_FILENAME}" ]]; then
      POOL_ID=$(getPoolIdFromOpCert "${pool_dir}/${POOL_OPCERT_FILENAME}")
    fi
  fi
  if [[ ! "${POOL_ID}" =~ ^[0-9a-f]{56}$ ]]; then
    echo "ERROR: no pool id in hex from POOL_ID, ${pool_dir}/${POOL_ID_FILENAME} or ${pool_dir}/${POOL_OPCERT_FILENAME}" >&2
    return 1
  fi
}

leaderlog_manage_systemd() {
  local action="${1:-install}"
  local service_user service_group unit_content

  load_systemd_library || return 1
  case "${action}" in
    install)
      loadPoolSettings || return 1
      service_user="$(id -un)"
      service_group="$(id -gn)"
      read -r -d '' unit_content <<EOF || true
[Unit]
Description=Guild Operators Amaru leader schedule (${NODE_NETWORK})
BindsTo=${NODE_SERVICE}.service
After=${NODE_SERVICE}.service

[Service]
Type=simple
User=${service_user}
Group=${service_group}
WorkingDirectory=${NODE_HOME}/scripts
ExecStart=${LEADERLOG_SCRIPT} leaderlog
Restart=on-failure
RestartSec=120
SuccessExitStatus=143
SyslogIdentifier=${NODE_SERVICE}-leaderlog
TimeoutStopSec=30
KillMode=control-group
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${NODE_HOME}
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=${NODE_SERVICE}.service
EOF
      systemd_install_unit "${LEADERLOG_UNIT}" "${unit_content}" "${LEADERLOG_SCRIPT}" || return 1
      systemd_daemon_reload &&
        systemd_enable_units "${LEADERLOG_UNIT}" &&
        echo "Installed ${LEADERLOG_UNIT}. It starts and stops together with ${NODE_SERVICE}.service; start it now with: sudo systemctl start ${LEADERLOG_UNIT}"
      ;;
    remove)
      systemd_remove_units --owner-token "${LEADERLOG_SCRIPT}" "${LEADERLOG_UNIT}" &&
        echo "Removed ${LEADERLOG_UNIT}; the blocklog database was left intact."
      ;;
    status)
      systemd_status_units "${LEADERLOG_UNIT}"
      ;;
    *) usage ;;
  esac
}

######################################

# Same schema as cncli.sh on a cardano-node deployment, so gLiveView, CNTools
# and a later block validation read one format for every node.
createBlocklogDB() {
  if ! mkdir -p "${BLOCKLOG_DIR}" 2>/dev/null; then echo "ERROR: failed to create directory to store blocklog: ${BLOCKLOG_DIR}" >&2 && return 1; fi
  if [[ ! -f ${BLOCKLOG_DB} ]]; then # create a fresh DB with latest schema
    sqlite3 "${BLOCKLOG_DB}" <<EOF || return 1
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
  elif [[ $(sqlite3 "${BLOCKLOG_DB}" "PRAGMA user_version;") -eq 0 ]]; then # Upgrade from schema version 0 to 1
    sqlite3 "${BLOCKLOG_DB}" <<EOF || return 1
ALTER TABLE epochdata ADD active_stake TEXT NOT NULL DEFAULT '0';
ALTER TABLE epochdata ADD total_active_stake TEXT NOT NULL DEFAULT '0';
PRAGMA user_version = 1;
EOF
  fi
}

leaderlogInit() {
  local required_command
  renice -n 19 $$ >/dev/null # the calculation must not compete with the node
  for required_command in b2sum bc jq sqlite3 xxd; do
    if ! command -v "${required_command}" >/dev/null; then
      echo "ERROR: ${required_command} not found, please install before activating the leaderlog" >&2
      return 1
    fi
  done
  loadAmaruSettings || return 1
  if [[ ! -x "${LEADERLOG_AMARU_BIN}" ]]; then
    echo "ERROR: failed to locate the amaru executable: ${LEADERLOG_AMARU_BIN}" >&2
    return 1
  fi
  if ! "${LEADERLOG_AMARU_BIN}" pool schedule inspect --help >/dev/null 2>&1; then
    echo "ERROR: $("${LEADERLOG_AMARU_BIN}" --version 2>/dev/null) has no 'pool schedule inspect' command, please upgrade Amaru" >&2
    return 1
  fi
  loadPoolSettings || return 1
  [[ -z "${SLEEP_RATE}" ]] && SLEEP_RATE=60
  RETRY_SLEEP=$(( SLEEP_RATE * 5 )) # extra wait before a failed calculation is tried again
  [[ -z "${BLOCKLOG_DIR}" ]] && BLOCKLOG_DIR="${NODE_HOME}/guild-db/blocklog"
  BLOCKLOG_DB="${BLOCKLOG_DIR}/blocklog.db"
  [[ -z "${BLOCKLOG_TZ}" ]] && BLOCKLOG_TZ="UTC"
  # The nonce of the next epoch is final 4k/f slots before the epoch boundary.
  # A margin of 600 slots keeps a short chain rollback around that point from
  # changing it afterwards.
  NEXT_NONCE_SLOT_IN_EPOCH=$(echo "${EPOCH_LENGTH} - (4 * ${BYRON_K} / ${ACTIVE_SLOTS_COEFF}) + 600" | bc)
  createBlocklogDB
}

# Refresh the node tip and tell whether the node follows the chain.
# Sets: curr_epoch, slot_in_epoch, and sync_state when not in sync
nodeInSync() {
  local tip_ref tip_diff
  slotnum=""
  epochnum=""
  slot_in_epoch=""
  if ! getNodeMetrics || ! isNumber "${slotnum}" || ! isNumber "${epochnum}" || ! isNumber "${slot_in_epoch}"; then
    sync_state="Node metrics not available"
    return 1
  fi
  tip_ref=$(getSlotTipRef)
  tip_diff=$(( tip_ref - slotnum ))
  if [[ ${tip_diff} -gt 300 ]]; then # Node considered in sync if less than 300 slots from theoretical tip
    sync_state="Node still syncing, ${tip_diff} slots from theoretical tip"
    return 1
  fi
  curr_epoch=${epochnum}
  # Until the first block of a new epoch arrives, the node still treats that
  # epoch as the next one.
  if [[ $(getEpochFromSlot "${tip_ref}") -ne ${curr_epoch} ]]; then
    sync_state="Waiting for the first block of epoch $((curr_epoch+1))"
    return 1
  fi
}

# $1 = epoch
storedEpochCount() {
  sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM epochdata WHERE epoch=${1} AND pool_id='${POOL_ID}';" 2>/dev/null
}

# Calculate the leader schedule of one epoch and save it to the blocklog DB.
# An epoch that is already stored is only rewritten when its slots differ.
# $1 = epoch, $2 = "force" to overwrite in any case
runLeaderlog() {
  local epoch="$1" overwrite="${2:-}"
  local leaderlog_json leaderlog_err error_msg
  local pool_stake total_active_stake sigma epoch_slots_ideal max_performance
  local slot_cnt new_slots stored_slots sql i
  local -a slots=() slots_in_epoch=() times=() ats=()

  leaderlog_err=$(mktemp) || return 1
  if ! leaderlog_json=$("${LEADERLOG_AMARU_BIN}" pool schedule inspect \
      --network "${NODE_NETWORK}" \
      --db-chain "${LEADERLOG_AMARU_DB_CHAIN}" \
      --db-ledger "${LEADERLOG_AMARU_DB_LEDGER}" \
      --operator-vrf "${POOL_VRF_SKEY}" \
      --epoch "${epoch}" --time-utc 2>"${leaderlog_err}"); then
    error_msg=$(tail -n 5 "${leaderlog_err}")
    rm -f "${leaderlog_err}"
    echo "ERROR: failure in leaderlog while running:"
    echo "${LEADERLOG_AMARU_BIN} pool schedule inspect --network ${NODE_NETWORK} --db-chain ${LEADERLOG_AMARU_DB_CHAIN} --db-ledger ${LEADERLOG_AMARU_DB_LEDGER} --operator-vrf ${POOL_VRF_SKEY} --epoch ${epoch} --time-utc"
    echo "Error message: ${error_msg}"
    return 1
  fi
  rm -f "${leaderlog_err}"

  if ! jq -e --argjson epoch "${epoch}" '
      .epoch == $epoch and
      (.pool_stake | type == "number") and
      (.active_stake | type == "number" and . > 0) and
      (.schedule | type == "array") and
      all(.schedule[];
        (.slot | type == "number") and
        (.relative_slot | type == "number") and
        (.time | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
    ' <<< "${leaderlog_json}" >/dev/null 2>&1; then
    echo "ERROR: unexpected leader schedule report from ${LEADERLOG_AMARU_BIN} for epoch ${epoch}"
    return 1
  fi
  pool_stake=$(jq -r '.pool_stake' <<< "${leaderlog_json}")
  total_active_stake=$(jq -r '.active_stake' <<< "${leaderlog_json}")
  mapfile -t slots < <(jq -r '.schedule | sort_by(.slot)[] | .slot' <<< "${leaderlog_json}")
  mapfile -t slots_in_epoch < <(jq -r '.schedule | sort_by(.slot)[] | .relative_slot' <<< "${leaderlog_json}")
  mapfile -t times < <(jq -r '.schedule | sort_by(.slot)[] | .time' <<< "${leaderlog_json}")
  slot_cnt=${#slots[@]}
  if ! isNumber "${pool_stake}" || ! isNumber "${total_active_stake}"; then
    echo "ERROR: unexpected stake amounts in the leader schedule report for epoch ${epoch}"
    return 1
  fi
  for i in "${!slots[@]}"; do
    if ! isNumber "${slots[i]}" || ! isNumber "${slots_in_epoch[i]}"; then
      echo "ERROR: unexpected slot numbers in the leader schedule report for epoch ${epoch}"
      return 1
    fi
  done

  if [[ ${overwrite} != "force" && $(storedEpochCount "${epoch}") -eq 1 ]]; then
    new_slots=$(printf '%s\n' "${slots[@]}")
    stored_slots=$(sqlite3 "${BLOCKLOG_DB}" "SELECT slot FROM blocklog WHERE epoch=${epoch} ORDER BY slot;" 2>/dev/null)
    if [[ "${new_slots}" == "${stored_slots}" ]]; then
      echo "Leaderlogs already calculated for epoch ${epoch} and still valid, ${slot_cnt} leader slots"
      return 0
    fi
    echo "Stored leaderlog for epoch ${epoch} is no longer valid, replacing it"
  fi

  if [[ ${slot_cnt} -gt 0 ]]; then
    mapfile -t ats < <(printf '%s\n' "${times[@]}" | TZ="${BLOCKLOG_TZ}" date -f - '+%FT%T%:z')
    if [[ ${#ats[@]} -ne ${slot_cnt} ]]; then
      echo "ERROR: failed to convert the leader slot times to timezone ${BLOCKLOG_TZ}"
      return 1
    fi
  fi
  sigma=$(echo "scale=18; ${pool_stake} / ${total_active_stake}" | bc)
  [[ ${sigma} == .* ]] && sigma="0${sigma}"
  epoch_slots_ideal=$(LC_ALL=C printf '%.2f' "$(echo "${sigma} * ${EPOCH_LENGTH} * ${ACTIVE_SLOTS_COEFF}" | bc -l)")
  if [[ $(echo "${epoch_slots_ideal} > 0" | bc) -eq 1 ]]; then
    max_performance=$(LC_ALL=C printf '%.2f' "$(echo "${slot_cnt} / ${epoch_slots_ideal} * 100" | bc -l)")
  else
    max_performance="0.00"
  fi

  # Amaru does not report the epoch nonce, and the protocol has no
  # decentralisation parameter any more.
  sql=".timeout 10000
BEGIN IMMEDIATE;
UPDATE OR IGNORE epochdata SET epoch_nonce = '', sigma = '${sigma}', d = 0.0, epoch_slots_ideal = ${epoch_slots_ideal}, max_performance = ${max_performance}, active_stake = '${pool_stake}', total_active_stake = '${total_active_stake}'
WHERE epoch = ${epoch} AND pool_id = '${POOL_ID}';
INSERT OR IGNORE INTO epochdata (epoch, epoch_nonce, pool_id, sigma, d, epoch_slots_ideal, max_performance, active_stake, total_active_stake)
VALUES (${epoch}, '', '${POOL_ID}', '${sigma}', 0.0, ${epoch_slots_ideal}, ${max_performance}, '${pool_stake}', '${total_active_stake}');
DELETE FROM blocklog WHERE epoch = ${epoch};"
  for i in "${!slots[@]}"; do
    sql+=$'\n'"INSERT OR IGNORE INTO blocklog (slot,at,slot_in_epoch,epoch,status) values (${slots[i]},'${ats[i]}',${slots_in_epoch[i]},${epoch},'leader');"
  done
  sql+=$'\n'"COMMIT;"
  if ! sqlite3 -bail "${BLOCKLOG_DB}" <<< "${sql}"; then
    echo "ERROR: failed to save the leaderlog for epoch ${epoch} to ${BLOCKLOG_DB}"
    return 1
  fi
  for i in "${!slots[@]}"; do
    echo "LEADER: slot[${slots[i]}] slotInEpoch[${slots_in_epoch[i]}] at[${ats[i]}]"
  done
  [[ ${slot_cnt} -eq 0 ]] && echo "No leader slots found for epoch ${epoch} :("
  echo "Leaderlog calculation for epoch[${epoch}] completed and saved to blocklog DB"
  echo "Leaderslots: ${slot_cnt} - Ideal slots for epoch based on active stake: ${epoch_slots_ideal} - Luck factor ${max_performance}%"
}

leaderlog() {
  local checked_epoch=-1 settled_epoch=-1 next_epoch

  echo "~ Amaru Leaderlog started ~"
  leaderlogInit || exit 1

  if [[ ${subarg} == "force" ]]; then
    if ! nodeInSync; then
      echo "ERROR: ${sync_state}" >&2
      exit 1
    fi
    echo "Running leaderlogs for epoch ${curr_epoch}"
    runLeaderlog "${curr_epoch}" force || exit 1
    if [[ ${slot_in_epoch} -ge ${NEXT_NONCE_SLOT_IN_EPOCH} ]]; then
      next_epoch=$((curr_epoch+1))
      echo "Running leaderlogs for next epoch[${next_epoch}]"
      runLeaderlog "${next_epoch}" force || exit 1
    fi
    return 0
  fi

  while true; do
    if ! nodeInSync; then
      echo "${sync_state}, checking again in ${SLEEP_RATE}s"
      sleep ${SLEEP_RATE}
      continue
    fi
    if [[ ${curr_epoch} -ne ${checked_epoch} ]]; then
      # The schedule of a new epoch was calculated ahead of time. Run it once
      # more now that the epoch has started, after the node had time to settle.
      if [[ ${curr_epoch} -ne ${settled_epoch} ]]; then
        settled_epoch=${curr_epoch}
        echo "Node in sync, sleeping for ${SLEEP_RATE}s before running leaderlogs for current epoch"
      else
        echo "Running leaderlogs for epoch ${curr_epoch}"
        if runLeaderlog "${curr_epoch}"; then
          checked_epoch=${curr_epoch}
        else
          sleep ${RETRY_SLEEP}
        fi
      fi
    elif [[ ${slot_in_epoch} -ge ${NEXT_NONCE_SLOT_IN_EPOCH} ]]; then # Time to run leaderlogs for next epoch?
      next_epoch=$((curr_epoch+1))
      if [[ $(storedEpochCount "${next_epoch}") -ne 1 ]]; then
        echo "Running leaderlogs for next epoch[${next_epoch}]"
        runLeaderlog "${next_epoch}" || sleep ${RETRY_SLEEP}
      fi
    fi
    sleep ${SLEEP_RATE}
  done
}

#################################

case ${subcommand} in
  systemd )
    leaderlog_manage_systemd "${SYSTEMD_ACTION}" ;;
  leaderlog )
    leaderlog ;;
  * )
    usage ;;
esac
