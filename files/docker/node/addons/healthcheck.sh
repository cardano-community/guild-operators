#!/bin/bash
# shellcheck source=/dev/null
# shellcheck disable=SC2317
######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

ENTRYPOINT_PROCESS="${ENTRYPOINT_PROCESS:-cnode.sh}"            # Get the script from ENTRYPOINT_PROCESS or default to "cnode.sh" if not set
HEALTHCHECK_CPU_THRESHOLD="${HEALTHCHECK_CPU_THRESHOLD:-80}"    # The CPU threshold to warn about if the sidecar process exceeds this for more than 60 seconds, defaults to 80%.
HEALTHCHECK_RETRIES="${HEALTHCHECK_RETRIES:-20}"                # The number of retries if tip is not incrementing, or cpu usage is over the threshold
DB_SYNC_ALLOWED_DRIFT="${DB_SYNC_ALLOWED_DRIFT:-3600}"          # The allowed drift in seconds for the DB to be considered in sync
CNCLI_DB_ALLOWED_DRIFT="${CNCLI_DB_ALLOWED_DRIFT:-300}"         # The allowed drift in slots for the CNCLI DB to be considered in sync

######################################
# Do NOT modify code below           #
######################################

[[ ${0} != '-bash' ]] && PARENT="$(dirname $0)" || PARENT="$(pwd)"
# Check if env file is missing in current folder (no update checks as will mostly run as daemon), source env if present
[[ ! -f "${PARENT}"/env ]] && echo -e "\nCommon env file missing in \"${PARENT}\", please ensure latest guild-deploy.sh was run and this script is being run from ${CNODE_HOME}/scripts folder! \n" && exit 1
. "${PARENT}"/env offline

# Define a mapping of scripts to their corresponding health check functions
declare -A PROCESS_TO_HEALTHCHECK
PROCESS_TO_HEALTHCHECK=(
    ["dbsync.sh"]="check_db_sync"
    ["cnode.sh"]="check_node"
    ["cncli.sh"]="check_cncli"
)

# FUNCTIONS
check_cncli() {
    cncli_pid=$(pgrep -f "${ENTRYPOINT_PROCESS}")
    cncli_subcmd=$(ps -p "${cncli_pid}" -o cmd= | awk '{print $NF}')

    if [[ "${cncli_subcmd}" != "ptsendtip" ]]; then
        if check_cncli_db ; then
            return 0
        else
            return 1
        fi
    else
        # No-op. placeholder for check_cncli_ptsendtip
        :
        # if ! check_cncli_ptsendtip; then
        #     return 1
        # else
        #     return 0
    fi
}


check_cncli_db() {
    CCLI=$(which cardano-cli)
    SQLITE=$(which sqlite3)
    # Check if the DB is in sync
    CNCLI_SLOT=$(${SQLITE} "${CNODE_HOME}/guild-db/cncli/cncli.db" 'select slot_number from chain order by id desc limit 1;')
    NODE_SLOT=$(${CCLI} query tip --testnet-magic "${NWMAGIC}" | jq .slot)
    if check_tip "${NODE_SLOT}" "${CNCLI_SLOT}" "${CNCLI_DB_ALLOWED_DRIFT}"  ; then
        echo "We're healthy - DB is in sync"
        return 0
    else
        echo "Error: DB is not in sync"
        return 1
    fi
}


check_db_sync() {
    # Check if the DB is in sync
    [[ -z "${PGPASSFILE}" ]] && PGPASSFILE="${CNODE_HOME}/priv/.pgpass"
    if [[ ! -f "${PGPASSFILE}" ]]; then
        echo "ERROR: The PGPASSFILE (${PGPASSFILE}) not found, please ensure you've followed the instructions on guild-operators website!" && exit 1
        return 1
    else
        # parse the password from the pgpass file
        IFS=':' read -r PGHOST PGPORT _ PGUSER PGPASSWORD < "${PGPASSFILE}"
        PGDATABASE=cexplorer
        export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD
    fi
    CURRENT_TIME=$(date +%s)
    LATEST_BLOCK_TIME=$(date --date="$(psql -qt -c 'select time from block order by id desc limit 1;')" +%s)
    if check_tip "${CURRENT_TIME}""${LATEST_BLOCK_TIME}" "${DB_SYNC_ALLOWED_DRIFT}"; then
        echo "We're healthy - DB is in sync"
        return 0
    else
        echo "Error: DB is not in sync"
        return 1
    fi
}


# Function to check if the node is running and is on tip
check_node() {
    CCLI=$(which cardano-cli)

    # Adjust NETWORK variable if needed
    if [[ "$NETWORK" == "guild-mainnet" ]]; then NETWORK=mainnet; fi

    FIRST=$($CCLI query tip --testnet-magic "${NWMAGIC}" | jq .block)

    if [[ "${ENABLE_KOIOS}" == "N" ]] || [[ -z "${KOIOS_API}" ]]; then
        sleep 60
        SECOND=$($CCLI query tip --testnet-magic "${NWMAGIC}" | jq .block)
        if [[ "$FIRST" -ge "$SECOND" ]]; then
            echo "There is a problem"
            return 1
        else
            echo "We're healthy - node: $FIRST -> node: $SECOND"
            return 0
        fi
    else
        CURL=$(which curl)
        JQ=$(which jq)
        URL="${KOIOS_API}/tip"
        SECOND=$($CURL -s "${URL}" | $JQ '.[0].block_no')

        for (( CHECK=1; CHECK<=HEALTHCHECK_RETRIES; CHECK++ )); do
            if [[ "$FIRST" -eq "$SECOND" ]]; then
                echo "We're healthy - node: $FIRST == koios: $SECOND"
                return 0
            elif [[ "$FIRST" -lt "$SECOND" ]]; then
                sleep 3
                FIRST=$($CCLI query tip --testnet-magic "${NWMAGIC}" | jq .block)
            elif [[ "$FIRST" -gt "$SECOND" ]]; then
                sleep 3
                SECOND=$($CURL "${KOIOS_URL}" | $JQ '.[0].block_no')
            fi
        done
        echo "There is a problem"
        return 1
    fi
}

# Function to check if a process is running and its CPU usage
check_process() {
    local process_name="$1"
    local cpu_threshold="$2"

    for (( CHECK=0; CHECK<=HEALTHCHECK_RETRIES; CHECK++ )); do
        # Check CPU usage of the process
        CPU_USAGE=$(ps -C "$process_name" -o %cpu= | awk '{s+=$1} END {print s}')

        # Check if CPU usage exceeds threshold
        if (( CPU_USAGE > cpu_threshold )); then
            echo "Warning: High CPU usage detected for '$process_name' ($CPU_USAGE%)"
            sleep 3  # Retry after a pause
            continue
        fi

        # Check if ENTRYPOINT_PROCESS is in the SLEEPING_SCRIPTS array
        if ! pgrep -x "$process_name" > /dev/null && ! pgrep -x "sleep" > /dev/null; then
            echo "Error: '$process_name' is not running, and no 'sleep' process found"
            return 3  # Return 3 if the process is not running and sleep is not found
        fi

        echo "We're healthy - $process_name"
        return 0  # Return 0 if the process is healthy
    done

    echo "Max retries reached for $process_name"
    return 1  # Return 1 if retries are exhausted
}


check_tip() {
    TIP=$1
    DB_TIP=$2
    ALLOWED_DRIFT=$3

    if [[ $(( TIP - DB_TIP )) -lt ${ALLOWED_DRIFT} ]]; then
        return 0
    else
        return 1
    fi
}


# MAIN
if [[ -n "${PROCESS_TO_HEALTHCHECK[$ENTRYPOINT_PROCESS]}" ]]; then
    echo "Checking health for $ENTRYPOINT_PROCESS"
    eval "${PROCESS_TO_HEALTHCHECK[$ENTRYPOINT_PROCESS]}"
    exit $?
else
    # When 
    # Determine the process name or script to check health
    if [[ -n "${SCRIPT_TO_BINARY_MAP[$ENTRYPOINT_PROCESS]}" ]]; then
        process="${SCRIPT_TO_BINARY_MAP[$ENTRYPOINT_PROCESS]}"
    fi
    echo "Checking health for process: $process"
    check_process "$process" "$HEALTHCHECK_CPU_THRESHOLD"
    exit $?
fi
