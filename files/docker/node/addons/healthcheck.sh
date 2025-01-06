#!/bin/bash
# shellcheck source=/dev/null
#
######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

ENTRYPOINT_PROCESS="${ENTRYPOINT_PROCESS:-cnode.sh}"        # Get the script from ENTRYPOINT_PROCESS or default to "cnode.sh" if not set
CPU_THRESHOLD="${CPU_THRESHOLD:-80}"                        # The CPU threshold to warn about if the sidecar process exceeds this for more than 60 seconds, defaults to 80%
RETRIES="${RETRIES:-20}"                                    # The number of retries if tip is not incrementing, or cpu usage is over the threshold

######################################
# Do NOT modify code below           #
######################################

if [[ "${ENTRYPOINT_PROCESS}" == "cnode.sh" ]]; then
    source /opt/cardano/cnode/scripts/env
else
    # Source in offline mode for sidecar helper scripts
    source /opt/cardano/cnode/scripts/env offline
fi

# Define a mapping of scripts to their corresponding binaries, when defined check the binary is running and its CPU usage instead of the wrapper script.
declare -A SCRIPT_TO_BINARY_MAP
SCRIPT_TO_BINARY_MAP=(
    ["cncli.sh"]="cncli"
    ["mithril-signer.sh"]="mithril-signer"
)

# Define scripts which may sleep between executions of the binary.
SLEEPING_SCRIPTS=("cncli.sh")

# Function to check if a process is running and its CPU usage
check_process() {
    local process_name="$1"
    local cpu_threshold="$2"

    for (( CHECK=1; CHECK<=RETRIES; CHECK++ )); do
        # Check CPU usage of the process
        CPU_USAGE=$(ps -C "$process_name" -o %cpu= | awk '{s+=$1} END {print s}')

        # Check if CPU usage exceeds threshold
        if (( CPU_USAGE > cpu_threshold )); then
            echo "Warning: High CPU usage detected for '$process_name' ($CPU_USAGE%)"
            sleep 3  # Retry after a pause
            continue
        fi

        # Check if ENTRYPOINT_PROCESS is in the SLEEPING_SCRIPTS array
        if [[ " ${SLEEPING_SCRIPTS[@]} " =~ " ${ENTRYPOINT_PROCESS} " ]]; then
            # If the process is in SLEEPING_SCRIPTS, check if either the process or 'sleep' is running
            if ! pgrep -x "$process_name" > /dev/null && ! pgrep -x "sleep" > /dev/null; then
                echo "Error: '$process_name' is not running, and no 'sleep' process found"
                return 3  # Return 3 if the process is not running and sleep is not found
            fi
        else
            # If the process is not in SLEEPING_SCRIPTS, only check for the specific process
            if ! pgrep -x "$process_name" > /dev/null; then
                echo "Error: '$process_name' is not running"
                return 3  # Return 3 if the process is not running
            fi
        fi

        echo "We're healthy - $process_name"
        return 0  # Return 0 if the process is healthy
    done

    echo "Max retries reached for $process_name"
    return 1  # Return 1 if retries are exhausted
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
            exit 1
        else
            echo "We're healthy - node: $FIRST -> node: $SECOND"
        fi
    else
        CURL=$(which curl)
        JQ=$(which jq)
        URL="${KOIOS_API}/tip"
        SECOND=$($CURL -s "${URL}" | $JQ '.[0].block_no')

        for (( CHECK=1; CHECK<=RETRIES; CHECK++ )); do
            if [[ "$FIRST" -eq "$SECOND" ]]; then
                echo "We're healthy - node: $FIRST == koios: $SECOND"
                exit 0
            elif [[ "$FIRST" -lt "$SECOND" ]]; then
                sleep 3
                FIRST=$($CCLI query tip --testnet-magic "${NWMAGIC}" | jq .block)
            elif [[ "$FIRST" -gt "$SECOND" ]]; then
                sleep 3
                SECOND=$($CURL "${KOIOS_URL}" | $JQ '.[0].block_no')
            fi
        done
        echo "There is a problem"
        exit 1
    fi
}

# MAIN
if [[ "$ENTRYPOINT_PROCESS" == "cnode.sh" ]]; then
    # The original health check logic for "cnode.sh"
    check_node
else
    # Determine the process name or script to check health
    if [[ -n "${SCRIPT_TO_BINARY_MAP[$ENTRYPOINT_PROCESS]}" ]]; then
        process="${SCRIPT_TO_BINARY_MAP[$ENTRYPOINT_PROCESS]}"
    fi
    echo "Checking health for process: $process"
    check_process "$process" "$CPU_THRESHOLD"
    exit $?
fi

# If all checks pass, return healthy status
echo "Container is healthy"
exit 0

