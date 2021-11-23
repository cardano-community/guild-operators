#!/bin/bash

usage() {
  cat <<-EOF >&2
		
		Usage: $(basename "$0") [-f] [-i [p][r][m][c][d]] [-u] [-b <branch>]
		
		Install and setup haproxy, PostgREST, polling services and create systemd services for haproxy, postgREST and dbsync
		
		-u    Skip update check for setup script itself
		-r    Reset grest schema - drop all cron jobs and triggers, and remove all deployed RPC functions and cached tables
		-q    Run all DB Queries to update on postgres (includes creating grest schema, and re-creating views/genesis table/functions/triggers and setting up cron jobs)
		-b    Use alternate branch of scripts to download - only recommended for testing/development (Default: master)
		
		EOF
  exit 1
}

# Description : Set default env variables.
set_environment_variables() {
  CURL_TIMEOUT=60
  [[ -z "${BRANCH}" ]] && BRANCH=alpha
  REPO_URL_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators/${BRANCH}"
  GREST_DOCKER_SCRIPTS_URL="${REPO_URL_RAW}/files/docker/grest/scripts"
  GREST_DB_SCRIPTS_URL="${REPO_URL_RAW}/scripts/grest-helper-scripts/db-scripts"
  DOCS_URL="https://cardano-community.github.io/guild-operators"
  API_DOCS_URL="https://api.koios.rest"
  CRON_SCRIPTS_DIR="${CNODE_HOME}/scripts/cron-scripts"
  CRON_DIR="/etc/cron.d"
  PGDATABASE="cexplorer"
  [[ -z "${PGPASSFILE}" ]] && export PGPASSFILE="${CNODE_HOME}"/priv/.pgpass
}

# Description : Exit with error message
#             : $1 = Error message we'd like to display before exiting (function will pre-fix 'ERROR: ' to the argument)
err_exit() {
  printf "ERROR: %s\n". "${1}" >&2
  echo -e "Exiting...\n" >&2
  pushd -0 >/dev/null && dirs -c
  exit 1
}

jqDecode() {
  base64 --decode <<<$2 | jq -r "$1"
}

# Description : Check and apply updates to this docker-setup-grest.sh script.
#             : $1 = name of script to update
# return code : 0 = no update
#             : 1 = update applied
#             : 2 = update failed
checkUpdate() {
  [[ "${UPDATE_CHECK}" != "Y" ]] && return 0

  if [[ ${BRANCH} != master && ${BRANCH} != alpha ]]; then
    if ! curl -s -f -m "${CURL_TIMEOUT}" "https://api.github.com/repos/cardano-community/guild-operators/branches" | jq -e ".[] | select(.name == \"${BRANCH}\")" &>/dev/null; then
      err_exit "The selected branch - ${BRANCH} - does not exist anymore."
    fi
  fi

  # Get the script
  if curl -s -f -m "${CURL_TIMEOUT}" -o "${PARENT}/${1}".tmp "${GREST_DOCKER_SCRIPTS_URL}/${1}" 2>/dev/null; then

    # Make sure the script exist locally, else just rename
    [[ ! -f "${PARENT}/${1}" ]] && mv -f "${PARENT}/${1}".tmp "${PARENT}/${1}" && chmod +x "${PARENT}/${1}" && return 0

    # Full file comparison
    if [[ ("$(sha256sum "${PARENT}/${1}" | cut -d' ' -f1)" != "$(sha256sum "${PARENT}/${1}.tmp" | cut -d' ' -f1)") ]]; then
      cp "${PARENT}/${1}" "${PARENT}/${1}_bkp$(date +%s)"
      mv "${PARENT}/${1}".tmp "${PARENT}/${1}"
      chmod +x "${PARENT}/${1}"
      echo -e "\n${1} update successfully applied! Old script backed up in this directory."
      return 1
    fi
  fi
  rm -f "${PARENT}/${1}".tmp
  return 0
}

update_check() {
  [[ ${SKIP_UPDATE} == Y ]] && return 0
  echo "Checking for script updates..."

  checkUpdate docker-setup-grest.sh
  case $? in
  1)
    echo
    $0 "$@" "-u"
    exit 0
    ;; # re-launch script with same args skipping update check
  2) exit 1 ;;
  esac
}

# Description : Setup grest schema, web_anon user, and genesis and control tables.
#             : SQL sourced from grest-helper-scrips/db-scripts/basics.sql.
setup_db_basics() {
  local basics_sql_url="${GREST_DB_SCRIPTS_URL}/basics.sql"

  if ! basics_sql=$(curl -s -f -m "${CURL_TIMEOUT}" "${basics_sql_url}" 2>&1); then
    err_exit "Failed to get basic db setup SQL from ${basics_sql_url}"
  fi
  echo -e "Adding grest schema if missing and granting usage for web_anon..."
  ! output=$(psql "${PGDATABASE}" -v "ON_ERROR_STOP=1" -q <<<"${basics_sql}" 2>&1) && err_exit "${output}"
  return 0
}

# Description : Deployment list (will only proceed if sync status check passes):
#             : 1) grest DB basics - schema, web_anon user, basic grest-specific tables
#             : 2) RPC endpoints - with SQL sourced from files/grest/rpc/**.sql
#             : 3) Cached tables setup - with SQL sourced from files/grest/rpc/cached_tables/*.sql
#             :    This includes table structure setup and caching existing data (for most tables).
#             :    Some heavy cache tables are intentionally populated post-setup (point 4) to avoid long setup runtimes.
#             : 4) Cron jobs - deploy cron entries to /etc/cron.d/ from files/grest/cron/jobs/*.sh
#             :    Used for updating cached tables data.
deploy_query_updates() {
  echo "(Re)Deploying Postgres RPCs/views/schedule..."
  check_db_status
  if [[ $? -eq 1 ]]; then
    err_exit "Please wait for Cardano DBSync to populate PostgreSQL DB at least until Mary fork, and then re-run this setup script with the -q flag."
  fi

  echo -e "  Downloading DBSync RPC functions from Guild Operators GitHub store..."
  if ! rpc_file_list=$(curl -s -f -m "${CURL_TIMEOUT}" https://api.github.com/repos/cardano-community/guild-operators/contents/files/grest/rpc?ref=${BRANCH} 2>&1); then
    err_exit "${rpc_file_list}"
  fi
  echo -e "  (Re)Deploying GRest objects to DBSync..."

  # populate_genesis_table

  for row in $(jq -r '.[] | @base64' <<<"${rpc_file_list}"); do
    if [[ $(jqDecode '.type' "${row}") = 'dir' ]]; then
      echo -e "\n    Downloading pSQL executions from subdir $(jqDecode '.name' "${row}")"
      if ! rpc_file_list_subdir=$(curl -s -m "${CURL_TIMEOUT}" "https://api.github.com/repos/cardano-community/guild-operators/contents/files/grest/rpc/$(jqDecode '.name' "${row}")?ref=${BRANCH}"); then
        echo -e "      \e[31mERROR\e[0m: ${rpc_file_list_subdir}" && continue
      fi
      for row2 in $(jq -r '.[] | @base64' <<<"${rpc_file_list_subdir}"); do
        deployRPC "${row2}"
      done
    else
      deployRPC "${row}"
    fi
  done

  # setup_cron_jobs

  echo -e "\n  All RPC functions successfully added to DBSync! For detailed query specs and examples, visit ${API_DOCS_URL}!\n"
  echo -e "Please restart PostgREST before attempting to use the added functions"
  echo -e "  \e[94msudo systemctl restart postgrest.service\e[0m\n"
  return 0
}

# Description : Check sync until Mary hard-fork.
check_db_status() {
  if ! command -v psql &>/dev/null; then
    err_exit "We could not find 'psql' binary in \$PATH , please ensure you've followed the instructions below:\n ${DOCS_URL}/Appendix/postgres"
  fi
  
  if [[ "$(psql -qtAX -d ${PGDATABASE} -c "SELECT protocol_major FROM public.param_proposal WHERE protocol_major >= 4 ORDER BY protocol_major DESC LIMIT 1" 2>/dev/null)" == "" ]]; then
    return 1
  fi

  return 0
}

deployRPC() {
  file_name=$(jqDecode '.name' "${1}")
  [[ -z ${file_name} || ${file_name} != *.sql ]] && return
  dl_url=$(jqDecode '.download_url //empty' "${1}")
  [[ -z ${dl_url} ]] && return
  ! rpc_sql=$(curl -s -f -m "${CURL_TIMEOUT}" "${dl_url}" 2>/dev/null) && echo -e "\e[31mERROR\e[0m: download failed: ${dl_url%.json}.sql" && return 1
  echo -e "      Deploying Function :   \e[32m${file_name%.sql}\e[0m"
  ! output=$(psql "${PGDATABASE}" -v "ON_ERROR_STOP=1" <<<"${rpc_sql}" 2>&1) && echo -e "        \e[31mERROR\e[0m: ${output}"
}

########################Cron########################
#####

get_cron_job_executable() {
  local job=$1
  local job_path="${CRON_SCRIPTS_DIR}/${job}.sh"
  local job_url="${REPO_URL_RAW}/files/grest/cron/jobs/${job}.sh"
  is_file "${job_path}" && rm "${job_path}"
  if curl -s -f -m "${CURL_TIMEOUT}" -o "${job_path}" "${job_url}"; then
    echo -e "      Downloaded \e[32m${job_path}\e[0m"
    chmod +x "${job_path}"
  else
    err_exit "Could not download ${job_url}"
  fi
}

install_cron_job() {
  local job=$1
  local cron_pattern=$2
  local cron_job_path="${CRON_DIR}/${CNODE_VNAME}-${job}"
  local cron_scripts_path="${CRON_SCRIPTS_DIR}/${job}.sh"
  local cron_log_path="${LOG_DIR}/${job}.log"
  local cron_job_entry="${cron_pattern} ${USER} /bin/bash ${cron_scripts_path} >> ${cron_log_path}"
  remove_cron_job "${job}"
  sudo bash -c "{ echo '${cron_job_entry}'; } > ${cron_job_path}"
}

set_cron_variables() {
  local job=$1
  [[ ${PGDATABASE} != cexplorer ]] && sed -e "s@DB_NAME=.*@DB_NAME=${PGDATABASE}@" -i "${CRON_SCRIPTS_DIR}/${job}.sh"
  # update last modified date of all json files to trigger cron job to process all
  [[ -d "${HOME}/git/${CNODE_VNAME}-token-registry" ]] && find "${HOME}/git/${CNODE_VNAME}-token-registry" -mindepth 2 -maxdepth 2 -type f -name "*.json" -exec touch {} +
}

# Description : Alters the asset-registry-update.sh script to point to the testnet registry.
set_cron_asset_registry_testnet_variables() {
  sed -e "s@CNODE_VNAME=.*@CNODE_VNAME=${CNODE_VNAME}@" \
    -e "s@TR_URL=.*@TR_URL=https://github.com/input-output-hk/metadata-registry-testnet@" \
    -e "s@TR_SUBDIR=.*@TR_SUBDIR=registry@" \
    -i "${CRON_SCRIPTS_DIR}/asset-registry-update.sh"
}

# Description : Setup grest-related cron jobs.
setup_cron_jobs() {
  ! is_dir "${CRON_SCRIPTS_DIR}" && mkdir -p "${CRON_SCRIPTS_DIR}"

  get_cron_job_executable "stake-distribution-update"
  set_cron_variables "stake-distribution-update"
  install_cron_job "stake-distribution-update" "*/30 * * * *"

  get_cron_job_executable "pool-history-cache-update"
  set_cron_variables "pool-history-cache-update"
  install_cron_job "pool-history-cache-update" "*/10 * * * *"

  # Only testnet and mainnet asset registries supported
  # Possible future addition for the Guild network once there is a guild registry
  if [[ ${NWMAGIC} -eq 764824073 || ${NWMAGIC} -eq 1097911063 ]]; then
    get_cron_job_executable "asset-registry-update"
    set_cron_variables "asset-registry-update"
    # Point the update script to testnet regisry repo structure (default: mainnet)
    [[ ${NWMAGIC} -eq 1097911063 ]] && set_cron_asset_registry_testnet_variables
    install_cron_job "asset-registry-update" "*/10 * * * *"
  fi
}

######## Execution ########
# Parse command line options
while getopts :urqb: opt; do
  case ${opt} in
  u) SKIP_UPDATE='Y' ;;
  r) RESET_GREST='Y' ;;
  q) DB_QRY_UPDATES='Y' ;;
  b) BRANCH="${OPTARG}" ;;
  \?) usage ;;
  esac
done
update_check "$@"
set_environment_variables
setup_db_basics
[[ "${RESET_GREST}" == "Y" ]] && reset_grest
[[ "${DB_QRY_UPDATES}" == "Y" ]] && deploy_query_updates
pushd -0 >/dev/null || err_exit
dirs -c
