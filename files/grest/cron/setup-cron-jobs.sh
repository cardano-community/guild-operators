#!/bin/bash

err_exit() {
    echo -e "$*" >&2
    echo -e "Exiting...\n" >&2
    pushd -0 >/dev/null && dirs -c
    exit 1
}

is_empty() {
    local var=$1

    [[ -z $var ]]
}

is_file() {
    local file=$1

    [[ -f $file ]]
}

is_dir() {
    local dir=$1

    [[ -d $dir ]]
}

get_env_branch() {
    is_file "${CNODE_HOME}/scripts/.env_branch" &&
        BRANCH=$(cat "${CNODE_HOME}"/scripts/.env_branch) || BRANCH=master
}

check_branch() {
    if ! curl -s -f -m "${CURL_TIMEOUT}" "https://api.github.com/repos/cardano-community/guild-operators/branches" |
        jq -e ".[] | select(.name == \"${BRANCH}\")" &>/dev/null; then
        echo -e "\nWARN!! ${BRANCH} branch does not exist, falling back to alpha branch\n"
        BRANCH=alpha
        echo "${BRANCH}" >"${CNODE_HOME}"/scripts/.env_branch
    else
        echo "${BRANCH}" >"${CNODE_HOME}"/scripts/.env_branch
    fi
}

setup_repo_url() {
    REPO_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators"
    URL_RAW="${REPO_RAW}/${BRANCH}"
}

setup_cron_scripts_dir() {
    if ! is_dir "$CRON_SCRIPTS_DIR"; then
        mkdir "$CRON_SCRIPTS_DIR"
    fi
}

get_cron_job_executable() {
    local job=$1
    local job_url="${URL_RAW}/files/grest/cron/jobs/${job}.sh"
    if curl -s -f -m "${CURL_TIMEOUT}" -o "${CRON_SCRIPTS_DIR}/${job}.sh" "${job_url}"; then
        echo "Downloaded ${CRON_SCRIPTS_DIR}/$job.sh"
        chmod +x "${CRON_SCRIPTS_DIR}/$job.sh"
    else
        err_exit "ERROR!! Could not download ${job_url}"
    fi
}

clean_up_existing_cron_job() {
    local job=$1
    if is_file "$CRON_DIR/$job"; then
        sudo rm "$CRON_DIR/$job"
    fi
}

install_cron_job() {
    local job=$1
    local cron_pattern=$2
    local cron_job_path="${CRON_DIR}/$job"
    local cron_job_entry="$cron_pattern $USER /bin/sh ${CRON_SCRIPTS_DIR}/$job.sh >> ${LOG_DIR}/$job.log"
    sudo bash -c "{ echo '$cron_job_entry'; } > $cron_job_path"
}

setup_cron_job() {
    local job=$1
    local cron_pattern=$2
    get_cron_job_executable "$job"
    clean_up_existing_cron_job "$job"
    install_cron_job "$job" "$cron_pattern"
}

CRON_DIR="/etc/cron.d"
CNODE_PATH="/opt/cardano"
USER="$(whoami)"
CURL_TIMEOUT=60

is_empty "$CNODE_NAME" && CNODE_NAME='cnode'
CNODE_HOME=${CNODE_PATH}/${CNODE_NAME}
LOG_DIR="${CNODE_HOME}/logs"
CRON_SCRIPTS_DIR="${CNODE_HOME}/scripts/cron-scripts"

main() {
    echo "Setting up stake distribution update job to run every 30 minutes..."
    get_env_branch
    check_branch
    setup_repo_url
    setup_cron_scripts_dir
    setup_cron_job "stake-distribution-update" "*/30 * * * *"
}

main
