#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2086,SC2154
# Leader schedule and block validation for an Amaru block producer, kept in the
# blocklog database.

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#POOL_ID=""                               # Pool id in hex (default: pool.id in the pool folder, else derived from the operational certificate)
#POOL_VRF_SKEY=""                         # VRF signing key (default: ${POOL_FOLDER}/${POOL_NAME}/${POOL_VRF_SK_FILENAME})
#SLEEP_RATE=60                            # Seconds between checks while running as a service
#CONFIRM_SLOT_CNT=600                     # validate: wait at least this many slots after a leader slot before deciding a missed or lost slot
#CONFIRM_BLOCK_CNT=15                     # validate: wait for at least this many blocks on top of ours before deciding its result

######################################
# Do NOT modify code below           #
######################################

PARENT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  cat <<EOF >&2

Usage: $(basename "$0") [operation <sub arg>]
       $(basename "$0") -d
       $(basename "$0") systemd <install|remove|status>
Leader schedule and block validation for an Amaru block producer. The systemd units are owned by this script.

-d          Install the leaderlog and validate systemd units.
systemd     Install, remove, or show the status of the leaderlog and validate units.

leaderlog   Calculate the leader schedule for the current epoch, then keep running and calculate the schedule for the next epoch
            once its nonce is final, about 2 days before the epoch boundary on MainNet (deployed as service)
  force     Calculate now and overwrite what is stored, exits after the leaderlog is calculated
validate    Check each passed leader slot against the chain and record the result: adopted, confirmed, missed, stolen
            (slot battle), heightbattle, ghosted or invalid, with the competing block and the blocks before and after
            it. Reads the node's journal and its chain database (deployed as service)
  all       One-time re-validation of all slots in the blocklog db
  epoch     One-time re-validation of the slots of the given epoch number

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
elif [[ ${1:-} == "validate" && $# -eq 1 ]]; then
  subcommand="validate"
elif [[ ${1:-} == "validate" && $# -eq 2 && ${2} =~ ^(all|[0-9]+)$ ]]; then
  subcommand="validate"
  subarg="${2}"
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
VALIDATE_UNIT="${NODE_SERVICE}-validate.service"

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

# $1 = leaderlog or validate
leaderlog_unit_content() {
  local component="$1" service_user service_group description exec_start groups=''
  service_user="$(id -un)"
  service_group="$(id -gn)"
  if [[ ${component} == validate ]]; then
    description="Guild Operators Amaru block validation (${NODE_NETWORK})"
    exec_start="${LEADERLOG_SCRIPT} validate"
    # Validation reads the node's journal.
    groups=$'\n'"SupplementaryGroups=systemd-journal"
  else
    description="Guild Operators Amaru leader schedule (${NODE_NETWORK})"
    exec_start="${LEADERLOG_SCRIPT} leaderlog"
  fi
  cat <<EOF
[Unit]
Description=${description}
BindsTo=${NODE_SERVICE}.service
After=${NODE_SERVICE}.service

[Service]
Type=simple
User=${service_user}
Group=${service_group}${groups}
WorkingDirectory=${NODE_HOME}/scripts
ExecStart=${exec_start}
Restart=on-failure
RestartSec=120
SuccessExitStatus=143
SyslogIdentifier=${NODE_SERVICE}-${component}
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
}

leaderlog_manage_systemd() {
  local action="${1:-install}"

  load_systemd_library || return 1
  case "${action}" in
    install)
      loadPoolSettings || return 1
      systemd_install_unit "${LEADERLOG_UNIT}" "$(leaderlog_unit_content leaderlog)" "${LEADERLOG_SCRIPT}" || return 1
      systemd_install_unit "${VALIDATE_UNIT}" "$(leaderlog_unit_content validate)" "${LEADERLOG_SCRIPT}" || return 1
      systemd_daemon_reload &&
        systemd_enable_units "${LEADERLOG_UNIT}" "${VALIDATE_UNIT}" &&
        echo "Installed ${LEADERLOG_UNIT} and ${VALIDATE_UNIT}. They start and stop together with ${NODE_SERVICE}.service; start them now with: sudo systemctl start ${LEADERLOG_UNIT} ${VALIDATE_UNIT}"
      ;;
    remove)
      systemd_remove_units --owner-token "${LEADERLOG_SCRIPT}" "${LEADERLOG_UNIT}" "${VALIDATE_UNIT}" &&
        echo "Removed ${LEADERLOG_UNIT} and ${VALIDATE_UNIT}; the blocklog database was left intact."
      ;;
    status)
      systemd_status_units "${LEADERLOG_UNIT}" "${VALIDATE_UNIT}"
      ;;
    *) usage ;;
  esac
}

######################################

# Same schema as cncli.sh on a cardano-node deployment, from the common env
# library, so gLiveView and CNTools read one format for every node.
createBlocklogDB() {
  if ! declare -F blocklogCreateDB >/dev/null; then
    echo "ERROR: the common env library is older than $(basename "$0"), re-run the deployment script to update the scripts" >&2
    return 1
  fi
  blocklogCreateDB
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
  local slot_cnt new_slots stored_slots sql i slot_list
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

  # Slots that stay in the schedule keep their validation result.
  slot_list=0
  (( slot_cnt == 0 )) || slot_list=$(IFS=,; echo "${slots[*]}")
  # Amaru does not report the epoch nonce, and the protocol has no
  # decentralisation parameter any more.
  sql=".timeout 10000
BEGIN IMMEDIATE;
UPDATE OR IGNORE epochdata SET epoch_nonce = '', sigma = '${sigma}', d = 0.0, epoch_slots_ideal = ${epoch_slots_ideal}, max_performance = ${max_performance}, active_stake = '${pool_stake}', total_active_stake = '${total_active_stake}'
WHERE epoch = ${epoch} AND pool_id = '${POOL_ID}';
INSERT OR IGNORE INTO epochdata (epoch, epoch_nonce, pool_id, sigma, d, epoch_slots_ideal, max_performance, active_stake, total_active_stake)
VALUES (${epoch}, '', '${POOL_ID}', '${sigma}', 0.0, ${epoch_slots_ideal}, ${max_performance}, '${pool_stake}', '${total_active_stake}');
DELETE FROM blocklog WHERE epoch = ${epoch} AND slot NOT IN (${slot_list});"
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

######################################
# Block validation                   #
######################################

# What Amaru logs about a led slot, and the blocks it receives, come from the
# node's journal (amaru::consensus::forge and amaru::blockperf traces). Which
# block is on the best chain comes from Amaru's chain database, opened
# read-only beside the running node; it holds the last k blocks, and Koios
# answers for older ones and names the pool of each block.

# amaruField <variable> <field> <trace line>: the value of field=value,
# field="value" (text traces) or "field":value (JSON traces).
amaruField() {
  local re="(^|[[:space:],{])\"?${2}\"?[=:]\"?([^\"[:space:],}]*)"
  printf -v "$1" '%s' ''
  [[ $3 =~ ${re} ]] && printf -v "$1" '%s' "${BASH_REMATCH[2]}"
  return 0
}

# Amaru's chain database: dev chain <command> [arguments]
amaruChain() {
  "${LEADERLOG_AMARU_BIN}" dev chain "$1" --network "${NODE_NETWORK}" --db-chain "${LEADERLOG_AMARU_DB_CHAIN}" "${@:2}" 2>/dev/null
}

# The best chain in Amaru's chain database, from the tip back to the anchor.
# Sets CHAIN_TIP_HEIGHT and CHAIN_LOW_HEIGHT, and CHAIN_HASH[height],
# CHAIN_SLOT[height], CHAIN_HEIGHT[hash] and CHAIN_AT_SLOT[slot].
amaruLoadBestChain() {
  local tip line
  declare -gA CHAIN_HASH=() CHAIN_SLOT=() CHAIN_HEIGHT=() CHAIN_AT_SLOT=()
  CHAIN_TIP_HEIGHT=''
  CHAIN_LOW_HEIGHT=''
  tip=$(amaruChain best-chain | sed -n 's/^Best tip (stored): *[0-9]*\.\([0-9a-f]\{64\}\).*/\1/p')
  [[ ${tip} =~ ^[0-9a-f]{64}$ ]] || return 1
  while IFS= read -r line; do
    [[ ${line} =~ ^([0-9]+)\.([0-9a-f]{64})\(([0-9]+)\)[[:space:]].*best-chain=yes ]] || continue
    CHAIN_HASH[${BASH_REMATCH[3]}]="${BASH_REMATCH[2]}"
    CHAIN_SLOT[${BASH_REMATCH[3]}]="${BASH_REMATCH[1]}"
    CHAIN_HEIGHT[${BASH_REMATCH[2]}]="${BASH_REMATCH[3]}"
    CHAIN_AT_SLOT[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
    [[ -n ${CHAIN_TIP_HEIGHT} ]] || CHAIN_TIP_HEIGHT="${BASH_REMATCH[3]}"
    CHAIN_LOW_HEIGHT="${BASH_REMATCH[3]}"
  done < <(amaruChain ancestors "${tip}")
  [[ -n ${CHAIN_TIP_HEIGHT} ]]
}

# Height of one stored block and whether it is on the best chain.
# Sets BLOCK_HEIGHT and BLOCK_BEST (Y or N), returns 1 when it is not stored.
amaruBlockState() {
  local line
  BLOCK_HEIGHT=''
  BLOCK_BEST=''
  line=$(amaruChain ancestors "$1" | head -n 1)
  [[ ${line} =~ ^[0-9]+\.${1}\(([0-9]+)\)[[:space:]].*best-chain=(yes|no) ]] || return 1
  BLOCK_HEIGHT="${BASH_REMATCH[1]}"
  [[ ${BASH_REMATCH[2]} == yes ]] && BLOCK_BEST=Y || BLOCK_BEST=N
}

# Koios blocks as "block|slot|hash|pool|parent", from block_info by hash or
# from blocks by a PostgREST filter such as block_height=in.(1,2).
amaruKoiosBlocks() {
  local answer
  [[ -n ${KOIOS_API} ]] || return 0
  if [[ $1 == --filter ]]; then
    answer=$(curl -sSL -f -m 15 "${KOIOS_API_HEADERS[@]}" \
      "${KOIOS_API}/blocks?${2}&select=hash,abs_slot,block_height,pool" 2>/dev/null) || return 0
  else
    answer=$(curl -sSL -f -m 15 "${KOIOS_API_HEADERS[@]}" -H 'Content-Type: application/json' \
      -d "$(jq -nc '{_block_hashes: $ARGS.positional}' --args "$@")" \
      "${KOIOS_API}/block_info?select=hash,abs_slot,block_height,pool,parent_hash" 2>/dev/null) || return 0
  fi
  jq -r '.[]? | select(.hash | type == "string")
    | [.block_height, .abs_slot, .hash, (.pool // ""), (.parent_hash // "")] | map(tostring) | join("|")' <<< "${answer}" 2>/dev/null
}

# What the node logged when it led one slot.
# Sets forge_kind (forged, missed_slot or forge_failed, empty when nothing was
# logged), forge_hash, forge_parent, forge_reason and forge_ms (milliseconds
# after the slot started).
amaruForgeRecord() {
  local slot="$1" start ts message value at frac line
  forge_kind=''; forge_hash=''; forge_parent=''; forge_reason=''; forge_ms=''
  start=$(blocklogSlotStartMs "${slot}") || return 0
  while IFS= read -r line; do
    ts="${line%% *}"
    message="${line#*: }"
    [[ ${message} == *consensus::forge* ]] || continue
    amaruField value slot "${message}"
    [[ ${value} == "${slot}" ]] || continue
    if [[ ${message} == *forge_failed* ]]; then
      forge_kind=forge_failed
      amaruField forge_reason step "${message}"
    elif [[ ${message} == *missed_slot* ]]; then
      [[ ${forge_kind} == forged ]] && continue
      forge_kind=missed_slot
      amaruField forge_reason reason "${message}"
    elif [[ ${message} == *forged* ]]; then
      amaruField forge_hash header_hash "${message}"
      amaruField forge_parent parent "${message}"
      [[ ${forge_hash} =~ ^[0-9a-f]{64}$ ]] || { forge_hash=''; continue; }
      [[ ${forge_parent} =~ ^[0-9a-f]{64}$ ]] || forge_parent=''
      forge_kind=forged
      # Amaru's own timestamp starts a text trace; else the journal's.
      if [[ ${message} =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.([0-9]+))?Z ]] &&
         at=$(date -u -d "${BASH_REMATCH[1]}Z" +%s 2>/dev/null); then
        frac="${BASH_REMATCH[3]}000"
      else
        at="${ts%.*}"; frac="${ts#*.}000"
      fi
      [[ ${at} =~ ^[0-9]+$ ]] && forge_ms=$(( at * 1000 + 10#${frac:0:3} - start ))
    fi
  done < <(blocklogJournalWindow "${AMARU_NODE_UNIT}" $(( start / 1000 - 5 )) $(( start / 1000 + 60 )) | grep -F "${slot}")
}

# When each block's header first reached our node, in milliseconds after the
# block's own slot started (amaru::blockperf header.announced), or else when
# its body arrived (block.received). The header is what propagates: Amaru
# fetches the body of a fork only once it wants that chain, which can be many
# seconds later. A block our node forged is neither.
# $1 = from (unix seconds), $2 = until (unix seconds), $3.. = block hashes
# Sets BLOCK_ARRIVAL[hash]
amaruArrivals() {
  local from="$1" to="$2" hash ms line
  local -a patterns=()
  local -A wanted=() header=() body=()
  shift 2
  declare -gA BLOCK_ARRIVAL=()
  for hash in "$@"; do
    [[ ${hash} =~ ^[0-9a-f]{64}$ ]] || continue
    wanted[${hash}]=1
    patterns+=(-e "${hash}")
  done
  (( ${#patterns[@]} > 0 )) || return 0
  while IFS= read -r line; do
    [[ ${line} == *header.announced* || ${line} == *block.received* ]] || continue
    amaruField hash header_hash "${line}"
    amaruField ms slot_latency_ms "${line}"
    [[ -n ${wanted[${hash}]+set} && ${ms} =~ ^[0-9]+$ ]] || continue
    if [[ ${line} == *header.announced* ]]; then
      [[ -n ${header[${hash}]+set} ]] && (( ${header[${hash}]} <= ms )) && continue
      header[${hash}]="${ms}"
    else
      [[ -n ${body[${hash}]+set} ]] && (( ${body[${hash}]} <= ms )) && continue
      body[${hash}]="${ms}"
    fi
  done < <(blocklogJournalWindow "${AMARU_NODE_UNIT}" "${from}" "${to}" | grep -F "${patterns[@]}")
  for hash in "${!wanted[@]}"; do
    if [[ -n ${header[${hash}]+set} ]]; then BLOCK_ARRIVAL[${hash}]="${header[${hash}]}"
    elif [[ -n ${body[${hash}]+set} ]]; then BLOCK_ARRIVAL[${hash}]="${body[${hash}]}"; fi
  done
}

# A block of the best chain as "block|slot|hash||", by height.
amaruChainAt() {
  [[ -n ${CHAIN_HASH[$1]+set} ]] && printf '%s|%s|%s||' "$1" "${CHAIN_SLOT[$1]}" "${CHAIN_HASH[$1]}"
}

# The best chain's blocks just before and after a slot, by slot, when we have
# no height of our own. $1 = slot, sets around_prev and around_next.
amaruChainAround() {
  local height best_prev='' best_next=''
  around_prev=''; around_next=''
  for height in "${!CHAIN_SLOT[@]}"; do
    if (( ${CHAIN_SLOT[${height}]} < $1 )); then
      [[ -n ${best_prev} ]] && (( ${CHAIN_SLOT[${best_prev}]} >= ${CHAIN_SLOT[${height}]} )) || best_prev="${height}"
    elif (( ${CHAIN_SLOT[${height}]} > $1 )); then
      [[ -n ${best_next} ]] && (( ${CHAIN_SLOT[${best_next}]} <= ${CHAIN_SLOT[${height}]} )) || best_next="${height}"
    fi
  done
  # The newest block of the window is not "after" a slot older than the window.
  [[ -z ${best_prev} ]] || around_prev=$(amaruChainAt "${best_prev}")
  [[ -z ${best_next} || -z ${best_prev} ]] || around_next=$(amaruChainAt "${best_next}")
}

# Record the blockdetail row of block_slot from our_*, winner, prev and next,
# adding the pool of each block (Koios) and when our node received it.
# $1 = reason
amaruSaveDetail() {
  local reason="$1" role row block slot hash pool from to first last slot_ms
  local -a hashes=() pools=()
  local -A stored=() rows=([winner]="${winner}" [prev]="${prev}" [next]="${next}") by_hash=()
  local -A detail=([slot]="${block_slot}" [reason]="${reason}" [source]=amaru)
  declare -gA BLOCK_ARRIVAL=()
  blocklogLoadDetail stored "${block_slot}"
  if [[ -n ${our_hash} ]]; then
    detail[hash]="${our_hash}"
    detail[parent]="${our_parent}"
    detail[block]="${our_height}"
  fi
  [[ -z ${forge_ms} ]] || detail[forge_ms]="${forge_ms}"
  first="${block_slot}"; last="${block_slot}"
  for role in winner prev next; do
    IFS='|' read -r block slot hash pool _ <<< "${rows[${role}]}"
    [[ ${hash} =~ ^[0-9a-f]{64}$ ]] || continue
    hashes+=("${hash}")
    (( slot < first )) && first="${slot}"
    (( slot > last )) && last="${slot}"
  done
  # Koios names the pool that made each block.
  if (( ${#hashes[@]} > 0 )); then
    while IFS='|' read -r block slot hash pool _; do
      [[ ${hash} =~ ^[0-9a-f]{64}$ ]] && by_hash[${hash}]="${pool}"
    done < <(amaruKoiosBlocks "${hashes[@]}")
  fi
  for role in winner prev next; do
    IFS='|' read -r block slot hash pool _ <<< "${rows[${role}]}"
    [[ -n ${hash} ]] || continue
    [[ -n ${pool} || -z ${by_hash[${hash}]+set} ]] || pool="${by_hash[${hash}]}"
    rows[${role}]="${block}|${slot}|${hash}|${pool}|"
    [[ -z ${pool} ]] || pools+=("${pool}")
  done
  if (( ${#hashes[@]} > 0 )) && slot_ms=$(blocklogSlotStartMs "${first}"); then
    from=$(( slot_ms / 1000 - 5 ))
    slot_ms=$(blocklogSlotStartMs "${last}")
    to=$(( slot_ms / 1000 + 120 ))
    (( to - from <= 3600 )) || to=$(( from + 3600 ))
    amaruArrivals "${from}" "${to}" "${hashes[@]}"
  fi
  blocklogPoolTickers "${pools[@]}"
  for role in winner prev next; do
    blocklogFillRole detail stored "${role}" "${rows[${role}]}"
  done
  blocklogSaveDetail detail || echo "WARN: failed to save the block details of slot ${block_slot}"
}

# $1 = status, $2 = block height (0 when there is none), $3 = block hash
amaruSetStatus() {
  local block="${2:-0}" hash="${3:-}"
  [[ ${block} =~ ^[0-9]+$ ]] || block=0
  [[ ${hash} =~ ^[0-9a-f]{64}$ ]] || hash=''
  sqlite3 -cmd ".timeout 10000" "${BLOCKLOG_DB}" \
    "UPDATE blocklog SET status = '$1', block = ${block}, hash = '${hash}' WHERE slot = ${block_slot};"
}

# Decide one leader slot. Uses block_epoch, block_slot, block_status, the
# node tip (slotnum) and the best chain from amaruLoadBestChain.
amaruValidateSlot() {
  local our_hash='' our_parent='' our_height='' our_best='' parent_on_chain='' taken=N
  local winner='' prev='' next='' canon_parent='' around_prev='' around_next='' line tip_height
  local -A stored=()
  [[ ${block_status} == leader || ${block_status} == adopted ]] || return 0
  (( block_slot <= slotnum )) || return 0 # still to come

  # The journal is read once per slot; what it said is kept in blockdetail.
  blocklogLoadDetail stored "${block_slot}"
  if [[ ${stored[hash]:-} =~ ^[0-9a-f]{64}$ ]]; then
    forge_kind=forged; forge_hash="${stored[hash]}"; forge_parent="${stored[parent]:-}"
    forge_reason=''; forge_ms="${stored[forge_ms]:-}"
  else
    amaruForgeRecord "${block_slot}"
    if [[ -z ${forge_kind} && -n ${stored[reason]:-} && ${stored[source]:-} == amaru ]]; then
      forge_kind=missed_slot; forge_reason="${stored[reason]}" # an older run read it from the journal
      [[ ${forge_reason} != slot_battle ]] || forge_reason=''
    fi
  fi
  if [[ ${forge_kind} == forged ]]; then
    our_hash="${forge_hash}"; our_parent="${forge_parent}"
    if [[ -n ${CHAIN_HEIGHT[${our_hash}]+set} ]]; then
      our_height="${CHAIN_HEIGHT[${our_hash}]}"; our_best=Y
    elif amaruBlockState "${our_hash}"; then
      our_height="${BLOCK_HEIGHT}"; our_best="${BLOCK_BEST}"
    else # older than the chain database holds, or never stored
      IFS='|' read -r our_height _ _ _ _ < <(amaruKoiosBlocks "${our_hash}")
      if [[ ${our_height} =~ ^[0-9]+$ ]]; then
        our_best=Y
      elif [[ -n ${our_parent} ]]; then
        our_best=N
        if [[ -n ${CHAIN_HEIGHT[${our_parent}]+set} ]]; then
          our_height=$(( CHAIN_HEIGHT[${our_parent}] + 1 ))
        else
          IFS='|' read -r our_height _ _ _ _ < <(amaruKoiosBlocks "${our_parent}")
          [[ ${our_height} =~ ^[0-9]+$ ]] && our_height=$(( our_height + 1 ))
        fi
      fi
    fi
    [[ ${our_height} =~ ^[0-9]+$ ]] || our_height=''
  fi

  if (( block_slot + CONFIRM_SLOT_CNT >= slotnum )); then # passed, too recent to decide
    [[ ${forge_kind} == forged ]] || return 0
    if [[ ${block_status} == leader ]]; then
      echo "ADOPTED: Leader for slot '${block_slot}' and block forged, waiting for confirmation"
      amaruSetStatus adopted "${our_height}" "${our_hash}"
    fi
    if [[ -z ${stored[hash]:-} ]]; then # keep what the journal said while it still has it
      local -A early=([slot]="${block_slot}" [source]=amaru [hash]="${our_hash}" [parent]="${our_parent}" [block]="${our_height}" [forge_ms]="${forge_ms}")
      blocklogSaveDetail early || true
    fi
    return 0
  fi

  if [[ ${forge_kind} == forge_failed ]]; then
    echo "INVALID: Leader for slot '${block_slot}' but forging failed at step '${forge_reason}', see the node's journal around $(getDateFromSlot "${block_slot}")"
    amaruSetStatus invalid
    amaruSaveDetail "${forge_reason}"
    return 0
  fi

  # Another pool's block in our slot on the best chain: a slot battle.
  if [[ -n ${CHAIN_AT_SLOT[${block_slot}]+set} && ${CHAIN_AT_SLOT[${block_slot}]} != "${our_hash}" ]]; then
    taken=Y
    winner="${CHAIN_HEIGHT[${CHAIN_AT_SLOT[${block_slot}]}]}|${block_slot}|${CHAIN_AT_SLOT[${block_slot}]}||"
  elif [[ -z ${CHAIN_LOW_HEIGHT} || ${block_slot} -lt ${CHAIN_SLOT[${CHAIN_LOW_HEIGHT}]:-0} ]]; then
    IFS= read -r line < <(amaruKoiosBlocks --filter "abs_slot=eq.${block_slot}")
    if [[ -n ${line} && ${line} != *"|${our_hash}|"* ]]; then taken=Y; winner="${line%|*}|"; fi
  fi

  if [[ ${forge_kind} != forged ]]; then
    if [[ ${taken} == Y ]]; then
      echo "STOLEN: Leader for slot '${block_slot}' but another pool's block for the same slot is on the chain"
      amaruSetStatus stolen
      amaruChainAround "${block_slot}"; prev="${around_prev}"; next="${around_next}"
      amaruSaveDetail slot_battle
    else
      echo "MISSED: Leader for slot '${block_slot}' but no block was forged${forge_reason:+ (${forge_reason})}"
      amaruSetStatus missed
      amaruChainAround "${block_slot}"; prev="${around_prev}"; next="${around_next}"
      amaruSaveDetail "${forge_reason}"
    fi
    return 0
  fi

  # We forged: wait until enough blocks are built on top before deciding.
  tip_height="${CHAIN_TIP_HEIGHT:-${blocknum:-0}}"
  [[ ${our_height} =~ ^[0-9]+$ ]] && (( tip_height - our_height < CONFIRM_BLOCK_CNT )) && return 0

  if [[ ${our_height} =~ ^[0-9]+$ ]]; then
    prev=$(amaruChainAt $(( our_height - 1 )))
    next=$(amaruChainAt $(( our_height + 1 )))
    [[ ${our_best} == Y ]] || winner="${winner:-$(amaruChainAt "${our_height}")}"
    if [[ -z ${prev} || -z ${next} || ( ${our_best} != Y && -z ${winner} ) ]]; then # older than the chain database
      while IFS='|' read -r block slot hash pool _; do
        (( block == our_height - 1 )) && [[ -z ${prev} ]] && prev="${block}|${slot}|${hash}|${pool}|"
        (( block == our_height + 1 )) && [[ -z ${next} ]] && next="${block}|${slot}|${hash}|${pool}|"
        (( block == our_height )) && [[ ${our_best} != Y && -z ${winner} ]] && winner="${block}|${slot}|${hash}|${pool}|"
      done < <(amaruKoiosBlocks --filter "block_height=in.($(( our_height - 1 )),${our_height},$(( our_height + 1 )))")
    fi
  fi

  if [[ ${our_best} == Y ]]; then
    echo "CONFIRMED: Leader for slot '${block_slot}' and our block is on the chain at height ${our_height}"
    winner=''
    amaruSetStatus confirmed "${our_height}" "${our_hash}"
    amaruSaveDetail ''
    return 0
  fi

  IFS='|' read -r _ _ canon_parent _ _ <<< "${prev}"
  if [[ -n ${our_parent} ]]; then
    if [[ -n ${CHAIN_HEIGHT[${our_parent}]+set} ]]; then
      parent_on_chain=Y
    elif [[ -n ${canon_parent} ]]; then
      parent_on_chain=N
    fi
  fi
  blocklogClassifyLost "${taken}" "${our_parent}" "${canon_parent}" "${parent_on_chain}"
  case ${BLOCKLOG_STATUS} in
    stolen) echo "STOLEN: Leader for slot '${block_slot}' but another pool's block for the same slot won :(" ;;
    heightbattle) echo "HEIGHT BATTLE: Leader for slot '${block_slot}' but another pool's block on the same parent won height ${our_height} :(" ;;
    *) echo "GHOSTED: Leader for slot '${block_slot}' and block forged but it is not on the chain${BLOCKLOG_REASON:+, it was built on a block that lost a fork}" ;;
  esac
  amaruSetStatus "${BLOCKLOG_STATUS}" "${our_height}" "${our_hash}"
  amaruSaveDetail "${BLOCKLOG_REASON}"
}

amaruValidateInit() {
  local required_command
  renice -n 19 $$ >/dev/null
  for required_command in curl jq journalctl sqlite3; do
    if ! command -v "${required_command}" >/dev/null; then
      echo "ERROR: ${required_command} not found, please install before activating block validation" >&2
      return 1
    fi
  done
  loadAmaruSettings || return 1
  if [[ ! -x "${LEADERLOG_AMARU_BIN}" ]]; then
    echo "ERROR: failed to locate the amaru executable: ${LEADERLOG_AMARU_BIN}" >&2
    return 1
  fi
  if ! "${LEADERLOG_AMARU_BIN}" dev chain ancestors --help >/dev/null 2>&1; then
    echo "ERROR: $("${LEADERLOG_AMARU_BIN}" --version 2>/dev/null) has no 'dev chain ancestors' command, please upgrade Amaru" >&2
    return 1
  fi
  AMARU_NODE_UNIT="${NODE_SERVICE}"
  if ! blocklogJournalReadable "${AMARU_NODE_UNIT}"; then
    echo "ERROR: the journal of ${AMARU_NODE_UNIT} is empty or not readable by $(id -un). Block validation reads what Amaru logs." >&2
    echo "Add $(id -un) to the systemd-journal group, or run the validate service installed with '$(basename "$0") -d', which has that group." >&2
    return 1
  fi
  [[ -z "${SLEEP_RATE}" ]] && SLEEP_RATE=60
  [[ -z "${CONFIRM_SLOT_CNT}" ]] && CONFIRM_SLOT_CNT=600
  [[ -z "${CONFIRM_BLOCK_CNT}" ]] && CONFIRM_BLOCK_CNT=15
  [[ -z "${BLOCKLOG_DIR}" ]] && BLOCKLOG_DIR="${NODE_HOME}/guild-db/blocklog"
  BLOCKLOG_DB="${BLOCKLOG_DIR}/blocklog.db"
  if ! nodeInSync && [[ ${sync_state} == "Node metrics not available" ]]; then
    echo "ERROR: ${sync_state}" >&2
    return 1
  fi
  if ! getShelleyTransitionEpoch; then
    echo "ERROR: failed to calculate the Shelley transition epoch" >&2
    return 1
  fi
  test_koios
  [[ -n ${KOIOS_API} ]] || echo "WARN: Koios is not available: pools of competing blocks are not named, and slots older than Amaru's chain database (k blocks) can't be decided."
  createBlocklogDB
}

# $1 = SQL condition on blocklog
amaruValidateRows() {
  local block_epoch block_slot block_status epoch_blocks
  epoch_blocks=$(sqlite3 -cmd ".timeout 10000" "${BLOCKLOG_DB}" "SELECT epoch, slot, status FROM blocklog WHERE $1 ORDER BY slot;" 2>/dev/null)
  [[ -n ${epoch_blocks} ]] || return 0
  if ! amaruLoadBestChain; then
    echo "WARN: could not read the best chain from ${LEADERLOG_AMARU_DB_CHAIN}"
    return 1
  fi
  while IFS='|' read -r block_epoch block_slot block_status; do
    [[ ${block_slot} =~ ^[0-9]+$ ]] || continue
    [[ ${2:-} != reset || ${block_status} == invalid ]] || block_status=leader # re-validate everything except invalid
    amaruValidateSlot
  done <<< "${epoch_blocks}"
}

amaruValidate() {
  local prev_epoch selection
  echo "~ Amaru Block Validation started ~"
  amaruValidateInit || exit 1
  if [[ -n ${subarg} ]]; then
    if ! nodeInSync; then
      echo "ERROR: ${sync_state}" >&2
      exit 1
    fi
    selection="1"
    [[ ${subarg} == all ]] || selection="epoch = ${subarg}"
    amaruValidateRows "${selection}" reset || exit 1
    return 0
  fi
  while true; do
    sleep ${SLEEP_RATE}
    if ! nodeInSync; then
      echo "${sync_state}, checking again in ${SLEEP_RATE}s"
      continue
    fi
    # Check the previous epoch as well at the start of an epoch.
    prev_epoch=${curr_epoch}
    [[ ${slot_in_epoch} -ge $(( CONFIRM_SLOT_CNT * 6 )) ]] || prev_epoch=$(( curr_epoch - 1 ))
    amaruValidateRows "epoch BETWEEN ${prev_epoch} AND ${curr_epoch} AND status IN ('leader','adopted') AND slot <= ${slotnum}" || true
  done
}

#################################

case ${subcommand} in
  systemd )
    leaderlog_manage_systemd "${SYSTEMD_ACTION}" ;;
  leaderlog )
    leaderlog ;;
  validate )
    amaruValidate ;;
  * )
    usage ;;
esac
