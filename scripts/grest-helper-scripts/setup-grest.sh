#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2046,SC1078
# shellcheck source=/dev/null

##########################################
# User Variables - Change as desired     #
# command line flags override set values #
##########################################

#CRON_SCRIPTS_DIR="${CNODE_HOME}/scripts/cron-scripts"   # Folder to hold cron job scripts
#CRON_DIR="/etc/cron.d"                                  # Cron job deployment folders
#PGDATABASE="cexplorer"                                  # Name of Postgres database used for deployment
#HAPROXY_CFG="${CNODE_HOME}/files/haproxy.cfg"           # Location of HAProxy config file

######################################
# Do NOT modify code below           #
######################################

SGVERSION=1.0.5 # Using versions from 1.0.5 for minor commit alignment before we're prepared for wider networks, targetted support for dbsync 13 will be against v1.1.0. Using a gap from 1.0.1 - 1.0.5 allows for scope to have any urgent fixes required before then on alpha branch itself

######## Functions ########
  usage() {
    cat <<-EOF >&2
		
		Usage: $(basename "$0") [-f] [-i [p][r][m][c][d]] [-u] [-b <branch>]
		
		Install and setup haproxy, PostgREST, polling services and create systemd services for haproxy, postgREST and dbsync
		
		-f    Force overwrite of all files including normally saved user config sections
		-i    Set-up Components individually. If this option is not specified, components will only be installed if found missing (eg: -i prcd)
		    p    Install/Update PostgREST binaries by downloading latest release from github.
		    r    (Re-)Install Reverse Proxy Monitoring Layer (haproxy) binaries and config
		    m    Install/Update Monitoring agent scripts
		    c    Overwrite haproxy, postgREST configs
		    d    Overwrite systemd definitions
		-u    Skip update check for setup script itself
		-r    Reset grest schema - drop all cron jobs and triggers, and remove all deployed RPC functions and cached tables
		-q    Run all DB Queries to update on postgres (includes creating grest schema, and re-creating views/genesis table/functions/triggers and setting up cron jobs)
		-b    Use alternate branch of scripts to download - only recommended for testing/development (Default: master)
		
		EOF
    exit 1
  }
  
  update_check() {
    # Check if env file is missing in current folder, note that some env functions may not be present until env is sourced successfully
    [[ ! -f ./env ]] && echo -e "\nCommon env file missing, please ensure latest prereqs.sh was run and this script is being run from ${CNODE_HOME}/scripts folder! \n" && exit 1
    . ./env offline # Just to source checkUpdate, will be re-sourced later
    
    # Update check
    if [[ ${SKIP_UPDATE} != Y ]]; then

      echo "Checking for script updates..."

      # Check availability of checkUpdate function
      if [[ ! $(command -v checkUpdate) ]]; then
        echo -e "\nCould not find checkUpdate function in env, make sure you're using official guild docos for installation!"
        exit 1
      fi

      checkUpdate env N N N
      [[ $? -eq 2 ]] && exit 1

      checkUpdate setup-grest.sh Y N N grest-helper-scripts
      case $? in
        1) echo; $0 "$@"; exit 0 ;; # re-launch script with same args
        2) exit 1 ;;
      esac
    fi

    . "${PARENT}"/env offline &>/dev/null
    case $? in
      1) echo -e "ERROR: Failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" && exit 1;;
      2) clear ;;
    esac
  }

  jqDecode() {
    base64 --decode <<<$2 | jq -r "$1"
  }

  deployRPC() {
    file_name=$(jqDecode '.name' "${1}")
    [[ -z ${file_name} || ${file_name} != *.sql ]] && return
    dl_url=$(jqDecode '.download_url //empty' "${1}")
    [[ -z ${dl_url} ]] && return
    ! rpc_sql=$(curl -s -f -m ${CURL_TIMEOUT} ${dl_url} 2>/dev/null) && echo -e "\e[31mERROR\e[0m: download failed: ${dl_url%.json}.sql" && return 1
    echo -e "      Deploying Function :   \e[32m${file_name%.sql}\e[0m"
    ! output=$(psql "${PGDATABASE}" -v "ON_ERROR_STOP=1" <<<${rpc_sql} 2>&1) && echo -e "        \e[31mERROR\e[0m: ${output}"
  }

  get_cron_job_executable() {
    local job=$1
    local job_path="${CRON_SCRIPTS_DIR}/${job}.sh"
    local job_url="${URL_RAW}/files/grest/cron/jobs/${job}.sh"
    is_file "${job_path}" && rm "${job_path}"
    if curl -s -f -m "${CURL_TIMEOUT}" -o "${job_path}" "${job_url}"; then
      echo -e "    Downloaded \e[32m${job_path}\e[0m"
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

    echo ""
    get_cron_job_executable "stake-distribution-update"
    set_cron_variables "stake-distribution-update"
    # Special condition for guild network (NWMAGIC=141) where activity and entries are minimal, and epoch duration is 1 hour
    ([[ ${NWMAGIC} -eq 141 ]] && install_cron_job "stake-distribution-update" "*/5 * * * *") ||
      install_cron_job "stake-distribution-update" "*/30 * * * *"

    get_cron_job_executable "stake-distribution-new-accounts-update"
    set_cron_variables "stake-distribution-new-accounts-update"
    ([[ ${NWMAGIC} -eq 141 ]] && install_cron_job "stake-distribution-new-accounts-update" "*/30 * * * *") ||
      install_cron_job "stake-distribution-new-accounts-update" "58 */6 * * *"

    get_cron_job_executable "pool-history-cache-update"
    set_cron_variables "pool-history-cache-update"
    ([[ ${NWMAGIC} -eq 141 ]] && install_cron_job "pool-history-cache-update" "*/5 * * * *") ||
      install_cron_job "pool-history-cache-update" "*/10 * * * *"

    get_cron_job_executable "epoch-info-cache-update"
    set_cron_variables "epoch-info-cache-update"
    ([[ ${NWMAGIC} -eq 141 ]] && install_cron_job "epoch-info-cache-update" "*/5 * * * *") ||
      install_cron_job "epoch-info-cache-update" "*/15 * * * *"

    get_cron_job_executable "active-stake-cache-update"
    set_cron_variables "active-stake-cache-update"
    ([[ ${NWMAGIC} -eq 141 ]] && install_cron_job "active-stake-cache-update" "*/5 * * * *") ||
      install_cron_job "active-stake-cache-update" "*/15 * * * *"

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

  # Description : Remove a given grest cron entry.
  remove_cron_job() {
    local job=$1
    local cron_job_path_legacy="${CRON_DIR}/${job}" # legacy name w/o vname part, can be removed in future
    local cron_job_path="${CRON_DIR}/${CNODE_VNAME}-${job}"
    is_file "${cron_job_path_legacy}" && sudo rm "${cron_job_path_legacy}"
    is_file "${cron_job_path}" && sudo rm "${cron_job_path}"
  }

  # Description : Find and kill psql processes based on partial function name.
  #             : $1 = partial name of the cron-related update function in postgres.
  kill_cron_psql_process() {
    local update_function=$1
    output=$(psql "${PGDATABASE}" -v "ON_ERROR_STOP=1" -qt \
      -c "select grest.get_query_pids_partial_match('${update_function}');" |
        awk 'BEGIN {ORS = " "} {print $1}' | xargs echo -n)
    [[ -n "${output}" ]] && echo ${output} | xargs sudo kill -SIGTERM > /dev/null
  }

  # Description : Kill cron-related psql update functions.
  kill_cron_psql_processes() {
    kill_cron_psql_process 'stake_distribution_cache_update'
    kill_cron_psql_process 'pool_history_cache_update'
    kill_cron_psql_process 'asset_registry_cache_update'
  }

  # Description : Kill a running cron script (does not stop psql executions).
  kill_cron_script_processes() {
    sudo pkill -9 -f asset-registry-update.sh
  }

  # Description : Stop running grest-related cron jobs.
  kill_running_cron_jobs() {
    echo "Stopping currently running cron jobs..."
    kill_cron_script_processes &>/dev/null
    kill_cron_psql_processes
  }

  # Description : Remove all grest-related cron entries.
  remove_all_grest_cron_jobs() {
    echo "Removing all installed cron jobs..."
    remove_cron_job "stake-distribution-update"
    remove_cron_job "pool-history-cache-update"
    remove_cron_job "asset-registry-update"
    kill_running_cron_jobs
  }

  # Description : Set default env values if not user-specified.
  set_environment_variables() {
    [[ -z "${CRON_SCRIPTS_DIR}" ]] && CRON_SCRIPTS_DIR="${CNODE_HOME}/scripts/cron-scripts"
    [[ -z "${CRON_DIR}" ]] && CRON_DIR="/etc/cron.d"
    [[ -z "${PGDATABASE}" ]] && PGDATABASE="cexplorer"
    [[ -z "${HAPROXY_CFG}" ]] && HAPROXY_CFG="${CNODE_HOME}/files/haproxy.cfg"
    DOCS_URL="https://cardano-community.github.io/guild-operators"
    API_DOCS_URL="https://api.koios.rest"
    [[ -z "${PGPASSFILE}" ]] && export PGPASSFILE="${CNODE_HOME}"/priv/.pgpass
  }

  parse_args() {
    if [[ -z "${I_ARGS}" ]]; then
      ! command -v postgrest >/dev/null && INSTALL_POSTGREST="Y"
      ! command -v haproxy >/dev/null && INSTALL_HAPROXY="Y"
      [[ ! -f "${CNODE_HOME}"/scripts/grest-exporter.sh ]] && INSTALL_MONITORING_AGENTS="Y"
      [[ "${FORCE_OVERWRITE}" == "Y" ]] && OVERWRITE_CONFIG="Y" && OVERWRITE_SYSTEMD="Y"
      [[ ! -f "${HAPROXY_CFG}" ]] && FORCE_OVERWRITE="Y" # absence of haproxy.cfg at mentioned path would mean setup is not updated, or has not been run - hence, overwrite all
    else
      [[ "${I_ARGS}" =~ "p" ]] && INSTALL_POSTGREST="Y"
      [[ "${I_ARGS}" =~ "r" ]] && INSTALL_HAPROXY="Y"
      [[ "${I_ARGS}" =~ "m" ]] && INSTALL_MONITORING_AGENTS="Y"
      [[ "${I_ARGS}" =~ "c" ]] || [[ "${FORCE_OVERWRITE}" == "Y" ]] && OVERWRITE_CONFIG="Y"
      [[ "${I_ARGS}" =~ "d" ]] || [[ "${FORCE_OVERWRITE}" == "Y" ]] && OVERWRITE_SYSTEMD="Y"
    fi
  }

  common_init() {
    # TODO: Placeholder for future, if we split things to smaller components - we'd want to add those sections here
    # For example, haproxy or PostgREST only setups on fresh machines may not have the corresponding dirs
    # sudo mkdir -p "${CNODE_HOME}"/scripts "${CNODE_HOME}"/files "${CNODE_HOME}"/priv
    # sudo chown -R ${USER} "${CNODE_HOME}"/scripts "${CNODE_HOME}"/files "${CNODE_HOME}"/priv
    dirs -c # clear dir stack
    mkdir -p ~/tmp
  }

  # Description : Populate genesis table with given values.
  insert_genesis_table_data() {
    local alonzo_genesis=$1
    shift
    local shelley_genesis=("$@")
  
    psql "${PGDATABASE}" -c "INSERT INTO grest.genesis VALUES (
      '${shelley_genesis[4]}', '${shelley_genesis[2]}', '${shelley_genesis[0]}',
      '${shelley_genesis[1]}', '${shelley_genesis[3]}', '${shelley_genesis[5]}',
      '${shelley_genesis[6]}', '${shelley_genesis[7]}', '${shelley_genesis[8]}',
      '${shelley_genesis[9]}', '${shelley_genesis[10]}', '${alonzo_genesis}'
    );" > /dev/null
  }

  # Description : Read genesis values from node config files and populate grest.genesis table.
  #             : Note: Given the Plutus schema is far from finalized, we expect changes as SC layer matures and PAB gets into real networks.
  #             :       For now, a compressed jq will be inserted as a shell escaped json data blob.
  populate_genesis_table() {
    read -ra SHGENESIS <<<$(jq -r '[
      .activeSlotsCoeff,
      .updateQuorum,
      .networkId,
      .maxLovelaceSupply,
      .networkMagic,
      .epochLength,
      .systemStart,
      .slotsPerKESPeriod,
      .slotLength,
      .maxKESEvolutions,
      .securityParam
      ] | @tsv' <"${GENESIS_JSON}")
    ALGENESIS="$(jq -c . <"${ALONZO_GENESIS_JSON}")"

    insert_genesis_table_data "${ALGENESIS}" "${SHGENESIS[@]}"
  }

  deploy_postgrest() {
    echo "[Re]Installing PostgREST.."
    pushd ~/tmp >/dev/null || err_exit
    pgrest_asset_url="$(curl -s https://api.github.com/repos/PostgREST/postgrest/releases/latest | jq -r '.assets[].browser_download_url' | grep 'linux-static-x64.tar.xz')"
    if curl -sL -f -m ${CURL_TIMEOUT} -o postgrest.tar.xz "${pgrest_asset_url}"; then
      tar xf postgrest.tar.xz &>/dev/null && rm -f postgrest.tar.xz
      [[ -f postgrest ]] || err_exit "PostgREST archive downloaded but binary not found after attempting to extract package!"
      mv -f ./postgrest ~/.cabal/bin/
    else
      err_exit "Could not download ${pgrest_asset_url}"
    fi
  }

  deploy_haproxy() {
    echo "[Re]Installing HAProxy.."
    pushd ~/tmp >/dev/null || err_exit
    haproxy_url="http://www.haproxy.org/download/2.6/src/haproxy-2.6.0.tar.gz"
    if curl -sL -f -m ${CURL_TIMEOUT} -o haproxy.tar.gz "${haproxy_url}"; then
      tar xf haproxy.tar.gz &>/dev/null && rm -f haproxy.tar.gz
      if command -v apt-get >/dev/null; then
        sudo apt-get -y install libpcre3-dev >/dev/null || err_exit "'sudo apt-get -y install libpcre3-dev' failed!"
      fi
      if command -v yum >/dev/null; then
        sudo yum -y install pcre-devel >/dev/null || err_exit "'sudo yum -y install prce-devel' failed!"
      fi
      cd haproxy-2.6.0 || return
      make clean >/dev/null
      make -j $(nproc) TARGET=linux-glibc USE_ZLIB=1 USE_LIBCRYPT=1 USE_OPENSSL=1 USE_PCRE=1 USE_SYSTEMD=1 USE_PROMEX=1 >/dev/null
      sudo make install-bin >/dev/null
      sudo cp -f /usr/local/sbin/haproxy /usr/sbin/
    else
      err_exit "Could not download ${haproxy_url}"
    fi
    pushd "${CNODE_HOME}"/scripts >/dev/null || err_exit
  }

  deploy_monitoring_agents() {
    # Install socat to allow creating getmetrics script to listen on port
    if ! command -v socat >/dev/null; then
      echo -e "Installing socat .."
      if command -v apt-get >/dev/null; then
        sudo apt-get -y install socat >/dev/null || err_exit "'sudo apt-get -y install socat' failed!"
      elif command -v yum >/dev/null; then
        sudo yum -y install socat >/dev/null || err_exit "'sudo yum -y install socat' failed!"
      else
        err_exit "'socat' not found in \$PATH, needed to for node exporter monitoring!"
      fi
    fi
    pushd "${CNODE_HOME}"/scripts >/dev/null || err_exit
    checkUpdate getmetrics.sh Y N N grest-helper-scripts >/dev/null
    sed -e "s@cexplorer@${PGDATABASE}@g" -i "${CNODE_HOME}"/scripts/getmetrics.sh
    echo -e "[Re]Installing Monitoring Agent.."
    e=!
    sudo bash -c "cat <<-EOF > ${CNODE_HOME}/scripts/grest-exporter.sh
			#${e}/usr/bin/env bash
			socat TCP-LISTEN:8059,reuseaddr,fork     SYSTEM:\"echo HTTP/1.1 200 OK;SERVED=true bash ${CNODE_HOME}/scripts/getmetrics.sh;\"
			EOF"
    sudo chown $USER:$USER "${CNODE_HOME}"/scripts/grest-exporter.sh
    chmod 755 "${CNODE_HOME}"/scripts/grest-exporter.sh
  }

  deploy_configs() {
    # Create PostgREST config template
    echo "[Re]Deploying Configs.."
    [[ -f "${CNODE_HOME}"/priv/grest.conf ]] && cp "${CNODE_HOME}"/priv/grest.conf "${CNODE_HOME}"/priv/grest.conf.bkp_$(date +%s)
    cat <<-EOF > "${CNODE_HOME}"/priv/grest.conf
			db-uri = "postgres://${USER}@/${PGDATABASE}"
			db-schema = "grest"
			db-anon-role = "web_anon"
			server-host = "127.0.0.1"
			server-port = 8050
			#jwt-secret = "secret-token"
			#db-pool = 10
			#db-pool-timeout = 10
			#db-extra-search-path = "public"
			max-rows = 1000
			EOF
    # Create HAProxy config template
    [[ -f "${HAPROXY_CFG}" ]] && cp "${HAPROXY_CFG}" "${HAPROXY_CFG}".bkp_$(date +%s)
    case ${NWMAGIC} in
      1097911063) KOIOS_SRV="testnet.koios.rest" ;;
      764824073)  KOIOS_SRV="api.koios.rest" ;;
      *) KOIOS_SRV="guild.koios.rest" ;;
    esac

    if grep 'koios.rest:8443' ${HAPROXY_CFG}; then
      echo "  Skipping update of ${HAPROXY_CFG} as this instance is a monitoring instance"
    else
      bash -c "cat <<-EOF > ${HAPROXY_CFG}
			global
			  daemon
			  nbthread 4
			  maxconn 256
			  ulimit-n 65536
			  stats socket \"\\\$GRESTTOP\"/sockets/haproxy.socket mode 0600 level admin user \"\\\$HAPROXY_SOCKET_USER\"
			  cpu-map 1/all 1-2
			  log 127.0.0.1 local2 info
			  insecure-fork-wanted
			  external-check
			
			defaults
			  mode http
			  log global
			  option dontlognull
			  option http-ignore-probes
			  option http-server-close
			  option forwardfor
			  log-format \"%ci:%cp a:%f/%b/%s t:%Tq/%Tt %{+Q}r %ST b:%B C:%ac,%fc,%bc,%sc Q:%sq/%bq\"
			  option dontlog-normal
			  timeout client 30s
			  timeout server 30s
			  timeout connect 3s
			  timeout server-fin 2s
			  timeout http-request 5s
			
			frontend app
			  bind 0.0.0.0:8053
			  ## If using SSL, comment line above, replace servername.koios.rest and uncomment lines below as per docs
			  #http-request replace-value Host (.*):8053 servername.koios.rest:8453
			  #redirect scheme https code 301 if !{ ssl_fc }
			  #
			  #frontend app-secured
			  #bind :8453 ssl crt /etc/ssl/server.pem no-sslv3
			  http-request set-log-level silent
			  acl srv_down nbsrv(grest_postgrest) eq 0
			  acl is_wss hdr(Upgrade) -i websocket
			  http-request use-service prometheus-exporter if { path /metrics }
			  http-request track-sc0 src table flood_lmt_rate
			  http-request deny deny_status 429 if { sc_http_req_rate(0) gt 250 }
			  use_backend ogmios if { path_beg /api/v0/ogmios } || { path_beg /dashboard.js } || { path_beg /assets } || { path_beg /health } || is_wss
			  use_backend submitapi if { path_beg /api/v0/submittx }
			  use_backend grest_failover if srv_down
			  default_backend grest_postgrest
			
			backend grest_postgrest
			  balance first
			  option external-check
			  acl grestrpcs path_beg -f \"\\\$GRESTTOP\"/files/grestrpcs
			  http-request set-path \"%[path,regsub(^/api/v0/,/)]\"
			  http-request set-path \"%[path,regsub(^/,/rpc/)]\" if grestrpcs
			  http-request cache-use grestcache
			  external-check path \"/usr/bin:/bin:/tmp:/sbin:/usr/sbin\"
			  external-check command \"\\\$GRESTTOP\"/scripts/grest-poll.sh
			  server local 127.0.0.1:8050 check inter 20000 fall 1 rise 2
			  http-response cache-store grestcache
			
			backend grest_failover
			  server koios-ssl ${KOIOS_SRV}:443 ssl verify none
			  http-response set-header X-Failover true
			
			backend ogmios
			  balance first
			  http-request set-path \"%[path,regsub(^/api/v0/ogmios/,/)]\"
			  option httpchk GET /health
			  http-check expect status 200
			  default-server inter 20s fall 1 rise 2
			  server local 127.0.0.1:1337 check
			
			backend submitapi
			  balance first
			  option httpchk POST /api/submit/tx
			  http-request set-path \"%[path,regsub(^/api/v0/submittx,/api/submit/tx)]\"
			  http-check expect status 415
			  default-server inter 20s fall 1 rise 2
			  server local 127.0.0.1:8090 check
			  server koios-ssl ${KOIOS_SRV}:443 backup ssl verify none
			
			backend flood_lmt_rate
			  stick-table type ip size 1m expire 10m store http_req_rate(10s)
			
			backend unauthorized
			  ## Used by monitoring instances only
			  http-request deny deny_status 401
			
			cache grestcache
			  total-max-size 1024
			  max-object-size 51200
			  process-vary on
			  max-secondary-entries 500
			  max-age 300
			EOF"
      echo "  Done!! Please ensure to set any custom settings/peers/TLS configs/etc back and update configs as necessary!"
    fi
  }

  common_update() {
    # Create skeleton whitelist URL file if one does not already exist using most common option
    if [[ ! -f "${CNODE_HOME}"/files/grestrpcs ]]; then
      # Not network dependent, as the URL patterns followed will default to monitoring instance from koios - it will anyways be overwritten as per user preference based on variables in grest-poll.sh
      curl -sfkL "https://api.koios.rest/koiosapi.yaml" -o "${CNODE_HOME}"/files/koiosapi.yaml 2>/dev/null
      grep " #RPC" "${CNODE_HOME}"/files/koiosapi.yaml | sed -e 's#^  /#/#' | cut -d: -f1 | sort > "${CNODE_HOME}"/files/grestrpcs 2>/dev/null
    fi
    [[ "${SKIP_UPDATE}" == "Y" ]] && return 0
    checkUpdate grest-poll.sh Y N N grest-helper-scripts >/dev/null
    checkUpdate checkstatus.sh Y N N grest-helper-scripts >/dev/null
    checkUpdate getmetrics.sh Y N N grest-helper-scripts >/dev/null
  }

  deploy_systemd() {
    echo "[Re]Deploying Services.."
    echo -e "  PostgREST Service"
    command -v postgrest >/dev/null && sudo bash -c "cat <<-EOF > /etc/systemd/system/${CNODE_VNAME}-postgrest.service
			[Unit]
			Description=REST Overlay for Postgres database
			After=postgresql.service
			Requires=postgresql.service
			
			[Service]
			Restart=always
			RestartSec=5
			User=${USER}
			LimitNOFILE=1048576
			ExecStart=${HOME}/.cabal/bin/postgrest ${CNODE_HOME}/priv/grest.conf
			ExecReload=/bin/kill -SIGUSR1 \\\$MAINPID
			StandardOutput=syslog
			StandardError=syslog
			SyslogIdentifier=postgrest
			
			[Install]
			WantedBy=multi-user.target
			EOF"
    echo -e "  HAProxy Service"
    command -v haproxy >/dev/null && sudo bash -c "cat <<-EOF > /etc/systemd/system/${CNODE_VNAME}-haproxy.service
			[Unit]
			Description=HAProxy Load Balancer
			After=network-online.target
			Wants=network-online.target
			
			[Service]
			Environment=\"GRESTTOP=${CNODE_HOME}\" \"CONFIG=${HAPROXY_CFG}\" \"PIDFILE=${CNODE_HOME}/logs/haproxy.pid\" \"HAPROXY_SOCKET_USER=${USER}\"
			ExecStartPre=/usr/sbin/haproxy -f \"\\\$CONFIG\" -c -q
			ExecStart=/usr/sbin/haproxy -Ws -f \"\\\$CONFIG\" -p \"\\\$PIDFILE\"
			ExecReload=/bin/kill -USR2 $MAINPID
			Restart=on-failure
			SuccessExitStatus=143
			KillMode=mixed
			Type=notify
			
			[Install]
			WantedBy=multi-user.target
			EOF"
    echo -e "  GRest Exporter Service"
    [[ -f "${CNODE_HOME}"/scripts/grest-exporter.sh ]] && sudo bash -c "cat <<-EOF > /etc/systemd/system/${CNODE_VNAME}-grest_exporter.service
			[Unit]
			Description=Guild Rest Services Metrics Exporter
			After=network-online.target
			Wants=network-online.target
			
			[Service]
			Type=simple
			Restart=always
			RestartSec=5
			User=${USER}
			WorkingDirectory=${CNODE_HOME}/scripts
			ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/grest-exporter.sh\"
			KillSignal=SIGINT
			SuccessExitStatus=143
			StandardOutput=syslog
			StandardError=syslog
			SyslogIdentifier=grest_exporter
			TimeoutStopSec=5
			KillMode=mixed
			
			[Install]
			WantedBy=multi-user.target
			EOF"
    sudo systemctl daemon-reload && sudo systemctl enable ${CNODE_VNAME}-postgrest.service ${CNODE_VNAME}-haproxy.service ${CNODE_VNAME}-grest_exporter.service >/dev/null 2>&1
    echo "  Done!! Please ensure to all [re]start services above!"
  }
  
  # Description : Setup grest schema, web_anon user, and genesis and control tables.
  #             : SQL sourced from grest-helper-scrips/db-scripts/basics.sql.
  setup_db_basics() {
    local basics_sql_url="${DB_SCRIPTS_URL}/basics.sql"
    
    if ! basics_sql=$(curl -s -f -m "${CURL_TIMEOUT}" "${basics_sql_url}" 2>&1); then
      err_exit "Failed to get basic db setup SQL from ${basics_sql_url}"
    fi
    echo -e "Adding grest schema if missing and granting usage for web_anon..."
    ! output=$(psql "${PGDATABASE}" -v "ON_ERROR_STOP=1" -q <<<${basics_sql} 2>&1) && err_exit "${output}"
    return 0
  }

  # Description : Check sync until Alonzo hard-fork.
  check_db_status() {
    if ! command -v psql &>/dev/null; then
      err_exit "We could not find 'psql' binary in \$PATH , please ensure you've followed the instructions below:\n ${DOCS_URL}/Appendix/postgres"
    fi
    if [[ -z ${PGPASSFILE} || ! -f "${PGPASSFILE}" ]]; then
      err_exit "PGPASSFILE env variable not set or pointing to a non-existing file: ${PGPASSFILE}\n ${DOCS_URL}/Build/dbsync"
    fi
    if [[ "$(psql -qtAX -d ${PGDATABASE} -c "SELECT protocol_major FROM public.param_proposal WHERE protocol_major > 4 ORDER BY protocol_major DESC LIMIT 1" 2>/dev/null)" == "" ]]; then
      return 1
    fi

    return 0
  }

  # Description : Drop all triggers and recreate grest schema.
  #             : SQL sourced from grest-helper-scrips/db-scripts/reset_grest.sql.
  recreate_grest_schema() {
    local reset_sql_url="${DB_SCRIPTS_URL}/reset_grest.sql"
    
    if ! reset_sql=$(curl -s -f -m "${CURL_TIMEOUT}" "${reset_sql_url}" 2>&1); then
      err_exit "Failed to get reset grest SQL from ${reset_sql_url}."
    fi
    echo -e "Resetting grest schema..."
    ! output=$(psql "${PGDATABASE}" -v "ON_ERROR_STOP=1" -q <<<${reset_sql} 2>&1) && err_exit "${output}"
  }

  # Description : Fully reset the grest node from the database POV.
  reset_grest() {
    local tr_dir="${HOME}/git/${CNODE_VNAME}-token-registry"
    [[ -d "${tr_dir}" ]] && rm -rf "${tr_dir}"
    remove_all_grest_cron_jobs
    recreate_grest_schema
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
      err_exit "Please wait for Cardano DBSync to populate PostgreSQL DB at least until Alonzo fork, and then re-run this setup script with the -q flag."
    fi

    echo -e "  Downloading DBSync RPC functions from Guild Operators GitHub store..."
    if ! rpc_file_list=$(curl -s -f -m ${CURL_TIMEOUT} https://api.github.com/repos/cardano-community/guild-operators/contents/files/grest/rpc?ref=${BRANCH} 2>&1); then
      err_exit "${rpc_file_list}"
    fi
    echo -e "  (Re)Deploying GRest objects to DBSync..."
    populate_genesis_table
    for row in $(jq -r '.[] | @base64' <<<${rpc_file_list}); do
      if [[ $(jqDecode '.type' "${row}") = 'dir' ]]; then
        echo -e "\n    Downloading pSQL executions from subdir $(jqDecode '.name' "${row}")"
        if ! rpc_file_list_subdir=$(curl -s -m ${CURL_TIMEOUT} "https://api.github.com/repos/cardano-community/guild-operators/contents/files/grest/rpc/$(jqDecode '.name' "${row}")?ref=${BRANCH}"); then
          echo -e "      \e[31mERROR\e[0m: ${rpc_file_list_subdir}" && continue
        fi
        for row2 in $(jq -r '.[] | @base64' <<<${rpc_file_list_subdir}); do
          deployRPC ${row2}
        done
      else
        deployRPC ${row}
      fi
    done
    setup_cron_jobs
    echo -e "\n  All RPC functions successfully added to DBSync! For detailed query specs and examples, visit ${API_DOCS_URL}!\n"
    echo -e "Please restart PostgREST before attempting to use the added functions"
    echo -e "  \e[94msudo systemctl restart ${CNODE_VNAME}-postgrest.service\e[0m\n"
  }

  # Description : Update the setup-grest.sh version used in the database.
  update_grest_version() {
    [[ "${RESET_GREST}" == "Y" ]] && artifacts=['reset'] || artifacts=''

    ! output=$(psql ${PGDATABASE} -qbt -c "SELECT GREST.update_control_table(
        'version',
        '${SGVERSION}',
        '${artifacts}'
      );" 2>&1 1>/dev/null) && err_exit "${output}"
  }

######## Execution ########
  # Parse command line options
  while getopts :fi:urqb: opt; do
    case ${opt} in
    f) FORCE_OVERWRITE='Y' ;;
    i) I_ARGS="${OPTARG}" ;;
    u) SKIP_UPDATE='Y' ;;
    r) RESET_GREST='Y' ;;
    q) DB_QRY_UPDATES='Y' ;;
    b) echo "${OPTARG}" > ./.env_branch ;;
    \?) usage ;;
    esac
  done
  update_check "$@"
  common_init
  set_environment_variables
  parse_args
  [[ "${INSTALL_POSTGREST}" == "Y" ]] && deploy_postgrest
  [[ "${INSTALL_HAPROXY}" == "Y" ]] && deploy_haproxy
  [[ "${INSTALL_MONITORING_AGENTS}" == "Y" ]] && deploy_monitoring_agents
  [[ "${OVERWRITE_CONFIG}" == "Y" ]] && deploy_configs
  [[ "${OVERWRITE_SYSTEMD}" == "Y" ]] && deploy_systemd
  common_update
  [[ "${RESET_GREST}" == "Y" ]] && setup_db_basics && reset_grest
  [[ "${DB_QRY_UPDATES}" == "Y" ]] && setup_db_basics && deploy_query_updates && update_grest_version
  pushd -0 >/dev/null || err_exit
  dirs -c
