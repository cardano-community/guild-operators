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
HEALTHCHECK_RETRY_WAIT="${HEALTHCHECK_RETRY_WAIT:-3}"           # The time (in seconds) to wait between retries
NODE_ALLOWED_DRIFT="${NODE_ALLOWED_DRIFT:-6}"                   # The allowed drift in blocks for the node to be considered in sync
DB_SYNC_ALLOWED_DRIFT="${DB_SYNC_ALLOWED_DRIFT:-3600}"          # The allowed drift in seconds for the DB to be considered in sync
CNCLI_DB_ALLOWED_DRIFT="${CNCLI_DB_ALLOWED_DRIFT:-300}"         # The allowed drift in slots for the CNCLI DB to be considered in sync
CNCLI_SENDTIP_LOG_TIMEOUT="${CNCLI_SENDTIP_LOG_TIMEOUT:-119}"   # log capturing timeout (should one second be lower than container healthcheck '--timeout', which defaults to 120)
CNCLI_SENDTIP_ALLOWED_DRIFT="${CNCLI_SENDTIP_ALLOWED_DRIFT:-3}" # The allowable difference of the tip moving before it's sent to Pooltool. (Not every tip progression is sent to Pooltool)

######################################
# Do NOT modify code below           #
######################################

[[ ${0} != '-bash' ]] && PARENT="$(dirname $0)" || PARENT="$(pwd)"
# Check if env file is missing in current folder (no update checks as will mostly run as daemon), source env if present
[[ ! -f "${PARENT}"/env ]] && echo -e "\nCommon env file missing in \"${PARENT}\", please ensure latest guild-deploy.sh was run and this script is being run from ${CNODE_HOME}/scripts folder! \n" && exit 1
. "${PARENT}"/env offline

if [[ -z "${KOIOS_API_HEADERS[*]}" ]] ; then
    if [[ -n "${KOIOS_API_TOKEN}" ]] ; then
        KOIOS_API_HEADERS=(-H "'Authorization: Bearer ${KOIOS_API_TOKEN}'")
    else
        KOIOS_API_HEADERS=()
    fi
fi


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
        if check_cncli_sendtip; then
            return 0
        else
            return 1
        fi
    fi
}


check_cncli_db() {
    CCLI=$(which cardano-cli)
    SQLITE=$(which sqlite3)
    # Check if the DB is in sync
    CNCLI_SLOT=$(${SQLITE} "${CNODE_HOME}/guild-db/cncli/cncli.db" 'select slot_number from chain order by id desc limit 1;')
    NODE_SLOT=$(${CCLI} query tip --testnet-magic "${NWMAGIC}" | jq .slot)
    if check_tip "${CNCLI_SLOT}" "${NODE_SLOT}" "${CNCLI_DB_ALLOWED_DRIFT}"  ; then
        echo "We're healthy - DB is in sync"
        return 0
    else
        echo "Error: DB is not in sync"
        return 1
    fi
}


# Function to check if the tip is successfully being sent to Pooltool
check_cncli_sendtip() {
    # Get the process ID of cncli
    process_id=$(pgrep -of cncli) || {
        echo "Error: cncli process not found."
        return 1  # Return 1 if the process is not found
    }

    # Get the current tip from the node
    first_tip=$($CCLI query tip --testnet-magic ${NWMAGIC} | jq .block)
    # Capture the next output from cncli that is related to Pooltool
    pt_log_entry=$(timeout $CNCLI_SENDTIP_LOG_TIMEOUT cat /proc/$process_id/fd/1 | grep --line-buffered "Pooltool" | head -n 1)
    # Get the current tip again
    second_tip=$($CCLI query tip --testnet-magic ${NWMAGIC} | jq .block)
    # If no output was captured...
    if [ -z "$pt_log_entry" ]; then
        if check_tip "$first_tip" "$second_tip" "$CNCLI_SENDTIP_ALLOWED_DRIFT"; then
            echo "Node tip didn't move before the healthcheck timeout was reached. (Current tip = $second_tip)."
            return 0  # Return 0 if the tip didn't move
        else
            echo "Unable to capture cncli output before the healthcheck timeout was reached. (Current tip = $second_tip)."
            return 1  # Return 1 if the tip did move
        fi
    fi

    # Define the json success message to check for
    json_success_status='.*"success":true.*'
    json_failure_status='.*"success":false.*'

    # Check if the json success message exists in the captured log
    if echo "$pt_log_entry" | grep -q $json_success_status; then
        echo "Healthy: Tip sent to Pooltool. (Current tip = $second_tip)."
        return 0  # Return 0 if the success message is found
    # Check if the json failure message exists in the captured log
    elif echo "$pt_log_entry" | grep -q $json_failure_status; then
        failure_message=$(echo "$pt_log_entry" | grep -oP '"message":"\K[^"]+')
        echo "Failed to send tip. (Current tip = $second_tip). $failure_message"
        return 1  # Return 1 if the failure message is found
    # If the log entry does not contain a json success or failure message
    else
        # Log the raw output if no json message is found
        echo "Failed to send tip. (Current tip = $second_tip). $pt_log_entry"
        return 1  # Return 1 if it fails for any other reason
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
    LATEST_BLOCK_TIME=$(date --date="$(psql -qt -c 'select time from block order by id desc limit 1;')" +%s)
    CURRENT_TIME=$(date +%s)
    if check_tip "${LATEST_BLOCK_TIME}" "${CURRENT_TIME}" "${DB_SYNC_ALLOWED_DRIFT}"; then
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
    CURL=$(which curl)
    JQ=$(which jq)
    URL="${KOIOS_API}/tip"

    # Adjust NETWORK variable if needed
    if [[ "$NETWORK" == "guild-mainnet" ]]; then NETWORK=mainnet; fi

    FIRST=$($CCLI query tip --testnet-magic "${NWMAGIC}" | jq .block)

    if [[ "${ENABLE_KOIOS}" == "N" ]] || [[ -z "${KOIOS_API}" ]]; then
        sleep 60
        SECOND=$($CCLI query tip --testnet-magic "${NWMAGIC}" | jq .block)
        # Subtract 1 from the second tip when using check_tip and drift of 0
        if check_tip "$FIRST" $(( SECOND - 1)) 0; then
            echo "We're healthy - node: $FIRST == node: $SECOND"
            return 0
        else
            echo "There is a problem"
            return 1
        fi
    else
        SECOND=$($CURL -s "${KOIOS_API_HEADERS[@]}" "${URL}" | $JQ '.[0].block_no')

        for (( CHECK=0; CHECK<=HEALTHCHECK_RETRIES; CHECK++ )); do
            # Set BIDIRECTIONAL_DRIFT to 1 since using an API call
            if check_tip "$FIRST" "$SECOND" "$NODE_ALLOWED_DRIFT" 1; then
                echo "We're healthy - node: $FIRST == koios: $SECOND"
                return 0
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
            sleep "$HEALTHCHECK_RETRY_WAIT"  # Retry after a pause
            continue
        fi

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


# Function to check if the tip is progressing or within the allowed drift.
# FIRST_TIP: The first tip to compare
# SECOND_TIP: The second tip to compare
# ALLOWED_DRIFT: The allowed drift between the two tips
# BIDIRECTIONAL_DRIFT: If set to 1, the function will calculate the absolute diff between the
#                      tips. This is useful when the tip can move backwards, like with API calls.
# Returns 0 if the diff of the second tip minus the first tip is between 0 and the allowed drift.
# Returns 1 if the diff is outside the allowed drift.

check_tip() {
    FIRST_TIP=$1
    SECOND_TIP=$2
    ALLOWED_DRIFT=${3:-0}
    BIDIRECTIONAL_DRIFT=${4:-0}

    diff=$(( SECOND_TIP - FIRST_TIP ))

    if [[ ${BIDIRECTIONAL_DRIFT} -eq 1 ]]; then
        diff=$(( diff < 0 ? -diff : diff ))
    fi

    if [[ ${ALLOWED_DRIFT} -eq 0 ]]; then
        if [[ ${diff} -eq 0 ]] ; then
            return 0
        else
            return 1
        fi
    else
        if [[ ${diff} -ge 0 && ${diff} -le ${ALLOWED_DRIFT} ]]; then
            return 0
        else
            return 1
        fi
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
