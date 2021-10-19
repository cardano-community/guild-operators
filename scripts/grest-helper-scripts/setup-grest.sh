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
#DBSYNC_PROM_HOST=127.0.0.1                              # Destination DBSync Prometheus Host
#DBSYNC_PROM_PORT=8080                                   # Destination DBSync Prometheus port

######################################
# Do NOT modify code below           #
######################################

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
		-q    Run all DB Queries to update on postgres (includes creating grest schema, and re-creating views/genesis table/functions/triggers and setting up cron jobs)
		-b    Use alternate branch of scripts to download - only recommended for testing/development (Default: master)
		
		EOF
    exit 1
  }
  
  update_check() {
    # Check if env file is missing in current folder, note that some env functions may not be present until env is sourced successfully
    [[ ! -f "./env" ]] && echo -e "\nCommon env file missing, please ensure latest prereqs.sh was run and this script is being run from ${CNODE_HOME}/scripts folder! \n" && exit 1
    . "${PARENT}"/env offline # Just to source checkUpdate, will be re-sourced later
    # Update check
    if [[ ${SKIP_UPDATE} != Y ]]; then
      echo "Checking for script updates..."
      # Check availability of checkUpdate function
      if [[ ! $(command -v checkUpdate) ]]; then
        echo -e "\nCould not find checkUpdate function in env, make sure you're using official guild docos for installation!"
        exit 1
      fi
      checkUpdate env N N N
      case $? in
        1) ENV_UPDATED=Y ;;
        2) exit 1 ;;
      esac
      # check for setup-grest update
      checkUpdate setup-grest.sh ${ENV_UPDATED}
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
    local job_url="${URL_RAW}/files/grest/cron/jobs/${job}.sh"
    if curl -s -f -m "${CURL_TIMEOUT}" -o "${CRON_SCRIPTS_DIR}/${job}.sh" "${job_url}"; then
      echo -e "      Downloaded \e[32m${CRON_SCRIPTS_DIR}/${job}.sh\e[0m"
      chmod +x "${CRON_SCRIPTS_DIR}/${job}.sh"
    else
      err_exit "Could not download ${job_url}"
    fi
  }

  install_cron_job() {
    local job=$1
    local cron_pattern=$2
    local cron_job_path="${CRON_DIR}/${job}"
    if is_file "$CRON_DIR/${job}"; then
      sudo rm "$CRON_DIR/${job}"
    fi
    local cron_job_entry="${cron_pattern} ${USER} /bin/sh ${CRON_SCRIPTS_DIR}/${job}.sh >> ${LOG_DIR}/${job}.log"
    sudo bash -c "{ echo '${cron_job_entry}'; } > ${cron_job_path}"
  }

  setup_cron_jobs() {
    if ! is_dir "${CRON_SCRIPTS_DIR}"; then
      mkdir "${CRON_SCRIPTS_DIR}"
    fi
    get_cron_job_executable "stake-distribution-update"
    install_cron_job "stake-distribution-update" "*/30 * * * *"
  }
  
  setup_defaults() {
    [[ -z "${CRON_SCRIPTS_DIR}" ]] && CRON_SCRIPTS_DIR="${CNODE_HOME}/scripts/cron-scripts"
    [[ -z "${CRON_DIR}" ]] && CRON_DIR="/etc/cron.d"
    [[ -z "${PGDATABASE}" ]] && PGDATABASE="cexplorer"
    [[ -z "${HAPROXY_CFG}" ]] && HAPROXY_CFG="${CNODE_HOME}/files/haproxy.cfg"
    DOCS_URL="https://cardano-community.github.io/guild-operators"
    [[ -z "${PGPASSFILE}" ]] && export PGPASSFILE="${CNODE_HOME}"/priv/.pgpass
  }

  parse_args() {
    if [[ -z "${I_ARGS}" ]]; then
      ! command -v postgrest >/dev/null && INSTALL_POSTGREST="Y"
      ! command -v haproxy >/dev/null && INSTALL_HAPROXY="Y"
      [[ ! -f "${CNODE_HOME}"/scripts/grest-exporter.sh ]] && INSTALL_MONITORING_AGENTS="Y"
      [[ "${FORCE_OVERWRITE}" == "Y" ]] && OVERWRITE_CONFIG="Y" && OVERWRITE_SYSTEMD="Y"
      [[ ! -f "${CNODE_HOME}"/files/haproxy.cfg ]] && FORCE_OVERWRITE="Y" # absence of haproxy.cfg at mentioned path would mean setup is not updated, or has not been run - hence, overwrite all
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

  populate_genesis_table() {
    read -ra genfiles <<<$(jq -r '[ .ByronGenesisFile, .ShelleyGenesisFile, .AlonzoGenesisFile] | @tsv' "${CONFIG}")
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
      ] | @tsv' <"${genfiles[1]}")
    # PS: Given the Plutus schema is far from finalized, we expect changes as SC layer matures and PAB gets into real networks.
    # For now, compressed jq will be inserted as shell escaped json data blob
    ALGENESIS="$(jq -c . <${genfiles[2]})"
    # Data Types are intentionally kept varchar for single ID row to avoid future edge cases
    echo -e "  Adding initial genesis table.."
    psql "${PGDATABASE}" <<-SQL >/dev/null
			SET client_min_messages TO WARNING;
			BEGIN;
			DROP TABLE IF EXISTS grest.genesis;
			CREATE TABLE grest.genesis (
			  NETWORKMAGIC varchar,
			  NETWORKID varchar,
			  ACTIVESLOTCOEFF varchar,
			  UPDATEQUORUM varchar,
			  MAXLOVELACESUPPLY varchar,
			  EPOCHLENGTH varchar,
			  SYSTEMSTART varchar,
			  SLOTSPERKESPERIOD varchar,
			  SLOTLENGTH varchar,
			  MAXKESREVOLUTIONS varchar,
			  SECURITYPARAM varchar,
			  ALONZOGENESIS varchar
			);
			COMMIT;
			SQL
    psql "${PGDATABASE}" -c "INSERT INTO grest.genesis VALUES ( '${SHGENESIS[4]}', '${SHGENESIS[2]}', '${SHGENESIS[0]}', '${SHGENESIS[1]}', '${SHGENESIS[3]}', '${SHGENESIS[5]}', '${SHGENESIS[6]}', '${SHGENESIS[7]}', '${SHGENESIS[8]}', '${SHGENESIS[9]}', '${SHGENESIS[10]}', '${ALGENESIS}' );" > /dev/null
  }

  deploy_postgrest() {
    echo "[Re]Installing PostgREST.."
    pushd ~/tmp >/dev/null || err_exit
    pgrest_asset_url="$(curl -s https://api.github.com/repos/PostgREST/postgrest/releases/latest | jq -r '.assets[].browser_download_url' | grep 'linux-x64-static.tar.xz')"
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
    haproxy_url="http://www.haproxy.org/download/2.4/src/haproxy-2.4.1.tar.gz"
    if curl -sL -f -m ${CURL_TIMEOUT} -o haproxy.tar.gz "${haproxy_url}"; then
      tar xf haproxy.tar.gz &>/dev/null && rm -f haproxy.tar.gz
      if command -v apt-get >/dev/null; then
        sudo apt-get -y install libpcre3-dev >/dev/null || err_exit "'sudo apt-get -y install libpcre3-dev' failed!"
      fi
      if command -v yum >/dev/null; then
        sudo yum -y install pcre-devel >/dev/null || err_exit "'sudo yum -y install prce-devel' failed!"
      fi
      cd haproxy-2.4.1 || return
      make clean >/dev/null
      make -j $(nproc) TARGET=linux-glibc USE_ZLIB=1 USE_LIBCRYPT=1 USE_OPENSSL=1 USE_PCRE=1 USE_SYSTEMD=1 >/dev/null
      sudo make install >/dev/null
      sudo cp -f /usr/local/sbin/haproxy /usr/sbin/
    else
      err_exit "Could not download ${haproxy_url}"
    fi
    curl -s -f -m ${CURL_TIMEOUT} -o "${CNODE_HOME}"/scripts/grest-poll.sh.tmp "${URL_RAW}"/scripts/grest-helper-scripts/grest-poll.sh
    curl -s -f -m ${CURL_TIMEOUT} -o checkstatus.sh.tmp ${URL_RAW}/scripts/grest-helper-scripts/checkstatus.sh
    checkUpdate "${CNODE_HOME}/scripts/grest-poll.sh"
    checkUpdate "checkstatus.sh"
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
    curl -s -f -m ${CURL_TIMEOUT} -o getmetrics.sh.tmp ${URL_RAW}/scripts/grest-helper-scripts/getmetrics.sh
    checkUpdate "getmetrics.sh"
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
			max-rows = 100
			EOF
    # Create HAProxy config template
    [[ -f "${HAPROXY_CFG}" ]] && cp "${HAPROXY_CFG}" "${HAPROXY_CFG}".bkp_$(date +%s)
    bash -c "cat <<-EOF > ${HAPROXY_CFG}
			global
			  daemon
			  nbthread 3
			  maxconn 256
			  stats socket ipv4@127.0.0.1:8055 mode 0600 level admin
			  log 127.0.0.1 local2
			  insecure-fork-wanted
			  external-check
			
			defaults
			  mode http
			  log global
			  option httplog
			  option dontlognull
			  option http-ignore-probes
			  option dontlog-normal
			  timeout client 10s
			  timeout server 10s
			  timeout connect 3s
			  timeout server-fin 2s
			  timeout http-request 5s
			
			frontend app
			  bind 0.0.0.0:8053
			  #http-request replace-value Host (.*):8053 :8453
			  redirect scheme https code 301 if !{ ssl_fc }
			  #
			  #frontend app-secured
			  #bind :8453 ssl crt /etc/ssl/server.pem no-sslv3
			  http-request track-sc0 src table flood_lmt_rate
			  http-request deny deny_status 429 if { sc_http_req_rate(0) gt 100 }
			  default_backend grest_core
			
			backend flood_lmt_rate                                                    
			  stick-table type ip size 1m expire 10m store http_req_rate(10s)
			
			backend grest_core
			  balance first
			  option external-check
			  external-check path \"/usr/bin:/bin:/tmp:/sbin:/usr/sbin\"
			  external-check command ${CNODE_HOME}/scripts/grest-poll.sh
			  server local 127.0.0.1:8050 check inter 10000
			  http-response set-header X-Frame-Options: DENY
			EOF"
    echo "  Done!! Please ensure to set any custom settings/peers/TLS configs/etc back and update configs as necessary!"
  }

  deploy_systemd() {
    echo "[Re]Deploying Services.."
    echo -e "  PostgREST Service"
    command -v postgrest >/dev/null && sudo bash -c "cat <<-EOF > /etc/systemd/system/postgrest.service
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
			ExecReload=/bin/kill -SIGUSR1 \$MAINPID
			StandardOutput=syslog
			StandardError=syslog
			SyslogIdentifier=postgrest
			
			[Install]
			WantedBy=multi-user.target
			EOF"
    echo -e "  HAProxy Service"
    command -v haproxy >/dev/null && sudo bash -c "cat <<-EOF > /etc/systemd/system/haproxy.service
			[Unit]
			Description=HAProxy Load Balancer
			After=network.target
			
			[Service]
			Environment=\"CONFIG=${HAPROXY_CFG}\" \"PIDFILE=${CNODE_HOME}/logs/haproxy.pid\"
			ExecStartPre=/usr/sbin/haproxy -f ${HAPROXY_CFG} -c -q
			ExecStart=/usr/sbin/haproxy -Ws -f ${HAPROXY_CFG} -p ${CNODE_HOME}/logs/haproxy.pid
			ExecReload=/usr/sbin/haproxy -f ${HAPROXY_CFG} -c -q
			SuccessExitStatus=143
			KillMode=mixed
			Type=notify
			
			[Install]
			WantedBy=multi-user.target
			EOF"
    echo -e "  GRest Exporter Service"
    [[ -f "${CNODE_HOME}"/scripts/grest-exporter.sh ]] && sudo bash -c "cat <<-EOF > /etc/systemd/system/grest_exporter.service
			[Unit]
			Description=Guild Rest Services Metrics Exporter
			After=network.target
			
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
    sudo systemctl daemon-reload && sudo systemctl enable postgrest.service haproxy.service grest_exporter.service >/dev/null 2>&1
    echo "  Done!! Please ensure to all [re]start services above!"
  }

  get_db_sync_tip_diff() {
    [[ -z ${DBSYNC_PROM_HOST} ]] && DBSYNC_PROM_HOST=127.0.0.1
    [[ -z ${DBSYNC_PROM_PORT} ]] && DBSYNC_PROM_PORT=8080
    local currslottip
    local db_sync_tip
    currslottip=$(getSlotTipRef)
    db_sync_tip=$(printf %f "$(curl -s http://${DBSYNC_PROM_HOST}:${DBSYNC_PROM_PORT} | grep ^cardano | grep cardano_db_sync_db_slot_height | awk '{print $2}')" | cut -d. -f1)
    if [[ "${db_sync_tip}" -eq 0 ]]; then
      err_exit "Failed to calculate get current db-sync tip, please check whether db-sync is running."
    fi
    db_sync_tip_diff=$(( currslottip - db_sync_tip ))
  }

  deploy_query_updates() {
    echo "[Re]Deploying Postgres RPCs/views/schedule.."
    if ! command -v psql &>/dev/null; then
      err_exit "We could not find 'psql' binary in \$PATH , please ensure you've followed the instructions below:\n ${DOCS_URL}/Appendix/postgres"
    fi
    if [[ -z ${PGPASSFILE} || ! -f "${PGPASSFILE}" ]]; then
      err_exit "PGPASSFILE env variable not set or pointing to a non-existing file: ${PGPASSFILE}\n ${DOCS_URL}/Build/dbsync"
    fi
    get_db_sync_tip_diff
    if [[ "${db_sync_tip_diff}" -gt 180 ]]; then
      err_exit "Cardano DBSync is not up to tip - please wait for it to sync, and then re-run this setup script with the -q flag."
    fi
    echo -e "  Downloading DBSync RPC functions from Guild Operators GitHub store..."
    if ! rpc_file_list=$(curl -s -f -m ${CURL_TIMEOUT} https://api.github.com/repos/cardano-community/guild-operators/contents/files/grest/rpc?ref=${BRANCH} 2>&1); then
      err_exit "${rpc_file_list}"
    fi
    # add grest schema if missing and grant usage for web_anon
    echo -e "  Adding grest schema if missing and granting usage for web_anon..."
    psql "${PGDATABASE}" <<-EOF >/dev/null
			SET client_min_messages TO WARNING;
			
			BEGIN;
			
			DO
			\$\$
			BEGIN
			  CREATE ROLE web_anon nologin;
			  EXCEPTION WHEN DUPLICATE_OBJECT THEN
			    RAISE NOTICE 'web_anon exists, skipping...';
			END
			\$\$;
			
			CREATE SCHEMA IF NOT EXISTS grest;
			GRANT USAGE ON SCHEMA public TO web_anon;
			GRANT USAGE ON SCHEMA grest TO web_anon;
			GRANT SELECT ON ALL TABLES IN SCHEMA public TO web_anon;
			GRANT SELECT ON ALL TABLES IN SCHEMA grest TO web_anon;
			ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO web_anon;
			ALTER DEFAULT PRIVILEGES IN SCHEMA grest GRANT SELECT ON TABLES TO web_anon;
			ALTER ROLE web_anon SET search_path TO grest, public;
			COMMIT;
			EOF
    populate_genesis_table
    echo -e "  [Re]Deploying GRest objects to DBSync.."
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
    echo -e "\n  All RPC functions successfully added to DBSync! For detailed query specs and examples, visit https://api.koios.rest!\n"
    echo -e "Please restart PostgREST before attempting to use the added functions"
    echo -e "  \e[94msudo systemctl restart postgrest.service\e[0m\n"
  }

######## Execution ########
  PARENT=$(pwd)
  # Parse command line options
  while getopts :fi:uqb: opt; do
    case ${opt} in
    f) FORCE_OVERWRITE='Y' ;;
    i) I_ARGS="${OPTARG}" ;;
    u) SKIP_UPDATE='Y' ;;
    q) DB_QRY_UPDATES='Y' ;;
    b) echo "${OPTARG}" > "${PARENT}"/.env_branch ;;
    \?) usage ;;
    esac
  done
  shift $((OPTIND - 1))
  update_check
  common_init
  setup_defaults
  parse_args
  [[ "${INSTALL_POSTGREST}" == "Y" ]] && deploy_postgrest
  [[ "${INSTALL_HAPROXY}" == "Y" ]] && deploy_haproxy
  [[ "${INSTALL_MONITORING_AGENTS}" == "Y" ]] && deploy_monitoring_agents
  [[ "${OVERWRITE_CONFIG}" == "Y" ]] && deploy_configs
  [[ "${OVERWRITE_SYSTEMD}" == "Y" ]] && deploy_systemd
  [[ "${DB_QRY_UPDATES}" == "Y" ]] && deploy_query_updates
  pushd -0 >/dev/null || err_exit
  dirs -c
