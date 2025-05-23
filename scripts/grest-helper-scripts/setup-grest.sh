#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2046,SC1078,SC2059,SC2143
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

SGVERSION=v1.3.2

######## Functions ########
  usage() {
    cat <<-EOF >&2
		
		Usage: $(basename "$0") [-i [p][r][m][c][d]] [-u] [-b <branch>]
		
		Install and setup haproxy, PostgREST, polling services and create systemd services for haproxy, postgREST and monitoring
		
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
    [[ ! -f ./env ]] && printf "Common env file missing, please ensure latest guild-deploy.sh was run and this script is being run from ${CNODE_HOME}/scripts folder! \n" && exit 1
    . ./env offline # Just to source checkUpdate, will be re-sourced later
    
    # Update check
    if [[ ${SKIP_UPDATE} != Y ]]; then

      printf "Checking for script updates...\n"

      # Check availability of checkUpdate function
      if [[ ! $(command -v checkUpdate) ]]; then
        printf "Could not find checkUpdate function in env, make sure you're using official guild docos for installation!\n"
        exit 1
      fi

      checkUpdate env N N N
      [[ $? -eq 2 ]] && printf "ERROR: Failed to check updates from github against specified branch\n" && exit 1

      checkUpdate setup-grest.sh Y N N grest-helper-scripts
      case $? in
        1) echo; $0 "$@"; exit 0 ;; # re-launch script with same args
        2) exit 1 ;;
      esac
    fi

    . "${PARENT}"/env offline &>/dev/null
    case $? in
      1) printf "ERROR: Failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub\n" && exit 1;;
      2) clear ;;
    esac
  }

  jqDecode() {
    base64 --decode <<<$2 | jq -r "$1"
  }

  get_cron_job_executable() {
    local job=$1
    local job_path="${CRON_SCRIPTS_DIR}/${job}.sh"
    local job_url="https://raw.githubusercontent.com/${G_ACCOUNT}/koios-artifacts/${SGVERSION}/files/grest/cron/jobs/${job}.sh"
    if curl -s -f -m "${CURL_TIMEOUT}" -o "${job_path}" "${job_url}"; then
      printf "    Downloaded \e[32m${job_path}\e[0m\n"
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
    local cron_log_path="${LOG_DIR}/${job}_\`date +\\%d\\%m\\%y\`.log"
    local cron_job_entry="${cron_pattern} ${USER} /bin/bash ${cron_scripts_path} >> ${cron_log_path} 2>&1"
    sudo bash -c "{ echo '${cron_job_entry}'; } > ${cron_job_path}"
  }

  set_cron_variables() {
    local job=$1
    [[ ${PGDATABASE} != cexplorer ]] && sed -e "s@DB_NAME=.*@DB_NAME=${PGDATABASE}@" -i "${CRON_SCRIPTS_DIR}/${job}.sh"
    sed -e "s@NWMAGIC=.*@NWMAGIC=${NWMAGIC}@" \
      -e "s@EPOCH_LENGTH=.*@EPOCH_LENGTH=${EPOCH_LENGTH}@" \
      -e "s@PROM_URL=.*@PROM_URL=http://${PROM_HOST}:${PROM_PORT}/metrics@" \
      -e "s@CCLI=.*@CCLI=${CCLI}@" \
      -e "s@CARDANO_NODE_SOCKET_PATH=.*@CARDANO_NODE_SOCKET_PATH=${CARDANO_NODE_SOCKET_PATH}@" \
      -i "${CRON_SCRIPTS_DIR}/${job}.sh"
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
    ([[ ${NWMAGIC} -eq 141 ]] && install_cron_job "stake-distribution-update" "*/10 * * * *") ||
      install_cron_job "stake-distribution-update" "15 */2 * * *"

    get_cron_job_executable "pool-history-cache-update"
    set_cron_variables "pool-history-cache-update"
    ([[ ${NWMAGIC} -eq 141 ]] && install_cron_job "pool-history-cache-update" "*/5 * * * *") ||
      install_cron_job "pool-history-cache-update" "*/10 * * * *"

    get_cron_job_executable "epoch-info-cache-update"
    set_cron_variables "epoch-info-cache-update"
    ([[ ${NWMAGIC} -eq 141 ]] && install_cron_job "epoch-info-cache-update" "*/5 * * * *") ||
      install_cron_job "epoch-info-cache-update" "*/5 * * * *"

    get_cron_job_executable "active-stake-cache-update"
    set_cron_variables "active-stake-cache-update"
    ([[ ${NWMAGIC} -eq 141 ]] && install_cron_job "active-stake-cache-update" "*/5 * * * *") ||
      install_cron_job "active-stake-cache-update" "*/15 * * * *"

    get_cron_job_executable "populate-next-epoch-nonce"
    set_cron_variables "populate-next-epoch-nonce"
    install_cron_job "populate-next-epoch-nonce" "*/10 * * * *"

    get_cron_job_executable "asset-info-cache-update"
    set_cron_variables "asset-info-cache-update"
    install_cron_job "asset-info-cache-update" "*/2 * * * *"

    get_cron_job_executable "cli-protocol-params-update"
    set_cron_variables "cli-protocol-params-update"
    install_cron_job "cli-protocol-params-update" "*/5 * * * *"

    get_cron_job_executable "pool-info-cache-update"
    set_cron_variables "pool-info-cache-update"
    install_cron_job "pool-info-cache-update" "*/10 * * * *"

    # Preprod/Preview networks use same registry as testnet.
    if [[ ${NWMAGIC} -eq 764824073 || ${NWMAGIC} -eq 1 || ${NWMAGIC} -eq 2 || ${NWMAGIC} -eq 141 ]]; then
      get_cron_job_executable "asset-registry-update"
      set_cron_variables "asset-registry-update"
      # Point the update script to testnet regisry repo structure (default: mainnet)
      [[ ${NWMAGIC} -eq 1 || ${NWMAGIC} -eq 2 || ${NWMAGIC} -eq 141 ]] && set_cron_asset_registry_testnet_variables
      install_cron_job "asset-registry-update" "*/10 * * * *"
    fi

    # Pool group entries are only relevant for mainnet
    if [[ ${NWMAGIC} -eq 764824073 ]]; then
      get_cron_job_executable "pool-groups-update"
      set_cron_variables "pool-groups-update"
      install_cron_job "pool-groups-update" "45 */6 * * *"
    fi

  }

  # Description : Remove all grest-related cron entries.
  remove_all_grest_cron_jobs() {
    printf "Removing all installed cron jobs...\n"
    grep -rl ${CRON_SCRIPTS_DIR} ${CRON_DIR} | xargs sudo rm -f
    rm -f ${CRON_SCRIPTS_DIR}/*.sh
    psql "${PGDATABASE}" -qt -c "SELECT PG_CANCEL_BACKEND(pid) FROM pg_stat_activity WHERE usename='${USER}' AND application_name = 'psql' AND query NOT LIKE '%pg_stat_activity%';"
    psql "${PGDATABASE}" -qt -c "SELECT PG_TERMINATE_BACKEND(pid) FROM pg_stat_activity WHERE usename='${USER}' AND application_name = 'psql' AND query NOT LIKE '%pg_stat_activity%';"
  }

  # Description : Set default env values if not user-specified.
  set_environment_variables() {
    [[ -z "${CRON_SCRIPTS_DIR}" ]] && CRON_SCRIPTS_DIR="${CNODE_HOME}/scripts/cron-scripts"
    [[ -z "${CRON_DIR}" ]] && CRON_DIR="/etc/cron.d"
    [[ -z "${PGDATABASE}" ]] && PGDATABASE="cexplorer"
    [[ -z "${HAPROXY_CFG}" ]] && HAPROXY_CFG="${CNODE_HOME}/files/haproxy.cfg"
    [[ -z "${DB_SCRIPTS_URL}" ]] && DB_SCRIPTS_URL="https://raw.githubusercontent.com/${G_ACCOUNT}/koios-artifacts/${SGVERSION}/files/grest/rpc/db-scripts"
    DOCS_URL="https://cardano-community.github.io/guild-operators"
    [[ -z "${PGPASSFILE}" ]] && export PGPASSFILE="${CNODE_HOME}"/priv/.pgpass
    case ${NWMAGIC} in
      764824073)  KOIOS_SRV="api.koios.rest" ;;
      1) KOIOS_SRV="preprod.koios.rest" ;;
      2) KOIOS_SRV="preview.koios.rest" ;;
      *) KOIOS_SRV="guild.koios.rest" ;;
    esac
    API_DOCS_URL="https://${KOIOS_SRV}"
  }

  parse_args() {
    if [[ -z "${I_ARGS}" ]]; then
      [[ ! -f /usr/sbin/haproxy ]] && INSTALL_HAPROXY="Y"
      [[ ! -f "${CNODE_HOME}"/scripts/grest-exporter.sh ]] && INSTALL_MONITORING_AGENTS="Y"
      # absence of haproxy.cfg or grest.conf at mentioned path would mean setup is not updated, or has not been run - hence, overwrite all
      [[ ! -f "${HAPROXY_CFG}" ]] || [[ ! -f "${CNODE_HOME}"/priv/grest.conf ]] && OVERWRITE_CONFIG="Y"
    else
      [[ "${I_ARGS}" =~ "p" ]] && INSTALL_POSTGREST="Y"
      [[ "${I_ARGS}" =~ "r" ]] && INSTALL_HAPROXY="Y"
      [[ "${I_ARGS}" =~ "m" ]] && INSTALL_MONITORING_AGENTS="Y"
      [[ "${I_ARGS}" =~ "c" ]] && OVERWRITE_CONFIG="Y"
      [[ "${I_ARGS}" =~ "d" ]] && OVERWRITE_SYSTEMD="Y"
    fi
  }

  common_init() {
    # TODO: Placeholder for future, if we split things to smaller components - we'd want to add those sections here
    # For example, haproxy or PostgREST only setups on fresh machines may not have the corresponding dirs
    # sudo mkdir -p "${CNODE_HOME}"/scripts "${CNODE_HOME}"/files "${CNODE_HOME}"/priv
    # sudo chown -R ${USER} "${CNODE_HOME}"/scripts "${CNODE_HOME}"/files "${CNODE_HOME}"/priv
    dirs -c # clear dir stack
    mkdir -p ~/tmp
    [[ ! $(id -u authenticator 2>/dev/null) ]] && sudo useradd authenticator -d /home/authenticator -m
    [[ ! $(id -nG authenticator 2>/dev/null | grep -q "${USER}") ]] && sudo usermod -a -G "${USER}" authenticator
    [[ ! -d /home/authenticator/.local/bin ]] && sudo mkdir -p /home/authenticator/.local/bin
    [[ -d /opt/cardano/cnode/priv ]] && [[ "$(stat -c '%a' /opt/cardano/cnode/priv | tr -d \ )" -lt 750 ]] && sudo chmod 750 "${CNODE_HOME}"/priv
    [[ -f /opt/cardano/cnode/priv/grest.conf ]] && [[ "$(stat -c '%a' /opt/cardano/cnode/priv/grest.conf | tr -d \ )" -lt 640 ]] && sudo chmod 640 "${CNODE_HOME}"/priv/grest.conf
  }

  common_update() {
    # Create skeleton whitelist URL file if one does not already exist using most common option
    curl -sfkL "https://${KOIOS_SRV}/koiosapi.yaml" -o "${CNODE_HOME}"/files/koiosapi.yaml 2>/dev/null
    grep "^  /" "${CNODE_HOME}"/files/koiosapi.yaml | grep -v -e submittx -e "#RPC" | sed -e 's#^  /#/#' | cut -d: -f1 | sort > "${CNODE_HOME}"/files/grestrpcs 2>/dev/null
    echo "/control_table" >> "${CNODE_HOME}"/files/grestrpcs 2>/dev/null
    checkUpdate grest-poll.sh Y N N grest-helper-scripts >/dev/null
    sed -i "s|^#API_STRUCT_DEFINITION=\"https://api.koios.rest/koiosapi.yaml\"|API_STRUCT_DEFINITION=\"https://${KOIOS_SRV}/koiosapi.yaml\"|g" grest-poll.sh
    checkUpdate checkstatus.sh Y N N grest-helper-scripts >/dev/null
    checkUpdate getmetrics.sh Y N N grest-helper-scripts >/dev/null
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
    printf "[Re]Installing PostgREST..\n"
    pushd ~/tmp >/dev/null || err_exit
    ARCH=$(uname -m)
    if [ -z "${ARCH##*aarch64*}" ]; then
      pgrest_binary=ubuntu-aarch64.tar.xz
    else 
      pgrest_binary=linux-static-x86-64.tar.xz
    fi
    #pgrest_asset_url="$(curl -s https://api.github.com/repos/PostgREST/postgrest/releases/latest | jq -r '.assets[].browser_download_url' | grep ${pgrest_binary})"
    pgrest_asset_url="https://github.com/PostgREST/postgrest/releases/download/v12.2.8/postgrest-v12.2.8-${pgrest_binary}"
    if curl -sL -f -m ${CURL_TIMEOUT} -o postgrest.tar.xz "${pgrest_asset_url}"; then
      tar xf postgrest.tar.xz &>/dev/null && rm -f postgrest.tar.xz
      [[ -f postgrest ]] || err_exit "PostgREST archive downloaded but binary not found after attempting to extract package!"
      sudo mv -f ./postgrest /home/authenticator/.local/bin/
      sudo chown -R authenticator:authenticator /home/authenticator
    else
      err_exit "Could not download ${pgrest_asset_url}"
    fi
  }

  deploy_pgcardano_ext() {
    printf "[Re]Installing pg_cardano extension..\n"
    pushd ~/tmp >/dev/null || err_exit
    ARCH=$(uname -m)
    pgcardano_asset_url="https://share.koios.rest/api/public/dl/xFdZDfM4/bin/pg_cardano_linux_${ARCH}_v1.0.5-p2.tar.gz"
    if curl -sL -f -m ${CURL_TIMEOUT} -o pg_cardano.tar.gz "${pgcardano_asset_url}"; then
      tar xf pg_cardano.tar.gz &>/dev/null && rm -f pg_cardano.tar.gz
      pushd pg_cardano >/dev/null || err_exit
      [[ -f install.sh ]] || err_exit "pg_cardano tar downloaded but install.sh script not found after attempting to extract package!"
      ./install.sh >/dev/null 2>&1 || err_exit "pg_cardano: Execution of install.sh script failed!"
    fi
    psql -qtAX -d ${PGDATABASE} -c "DROP EXTENSION IF EXISTS pg_cardano;CREATE EXTENSION pg_cardano;" >/dev/null
  }

  deploy_haproxy() {
    printf "[Re]Installing HAProxy..\n"
    pushd ~/tmp >/dev/null || err_exit
    major_v="3.1"
    minor_v="5"
    haproxy_url="http://www.haproxy.org/download/${major_v}/src/haproxy-${major_v}.${minor_v}.tar.gz"
    if curl -sL -f -m ${CURL_TIMEOUT} -o haproxy.tar.gz "${haproxy_url}"; then
      tar xf haproxy.tar.gz &>/dev/null && rm -f haproxy.tar.gz
      if command -v apt-get >/dev/null; then
        pkg_installer="env NEEDRESTART_MODE=a env DEBIAN_FRONTEND=noninteractive env DEBIAN_PRIORITY=critical apt-get"
        pkg_list="build-essential make g++ autoconf automake libpcre2-dev libssl-dev libsystemd-dev zlib1g-dev"
      fi
      if command -v dnf >/dev/null; then
        pkg_installer="dnf"
        pkg_list="make gcc gcc-c++ autoconf automake pcre-devel openssl-devel systemd-devel zlib-devel"
      fi
      sudo ${pkg_installer} -y install ${pkg_list} >/dev/null || err_exit "'sudo ${pkg_installer} -y install ${pkg_list}' failed!"
      cd haproxy-${major_v}.${minor_v} || return
      make clean >/dev/null
      make -j $(nproc) TARGET=linux-glibc USE_ZLIB=1 USE_LIBCRYPT=1 USE_OPENSSL=1 USE_STATIC_PCRE2=1 USE_PROMEX=1 >/dev/null
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
      printf "Installing socat ..\n"
      if command -v apt-get >/dev/null; then
        sudo apt-get -y install socat >/dev/null || err_exit "'sudo apt-get -y install socat' failed!"
      elif command -v dnf >/dev/null; then
        sudo dnf -y install socat >/dev/null || err_exit "'sudo dnf -y install socat' failed!"
      else
        err_exit "'socat' not found in \$PATH, needed to for node exporter monitoring!"
      fi
    fi
    pushd "${CNODE_HOME}"/scripts >/dev/null || err_exit
    # script not available at first load
    sed -e "s@cexplorer@${PGDATABASE}@g" -i "${CNODE_HOME}"/scripts/getmetrics.sh
    printf "[Re]Installing Monitoring Agent..\n"
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
    printf "[Re]Deploying Configs..\n"
    sudo chmod 755 "${CNODE_HOME}" "${CNODE_HOME}"/priv
    [[ -f "${CNODE_HOME}"/priv/grest.conf ]] && sudo mv "${CNODE_HOME}"/priv/grest.conf "${CNODE_HOME}"/priv/grest.conf_bkp$(date +%s)
    cat <<-EOF > "${CNODE_HOME}"/priv/grest.conf
			db-uri = "postgres://authenticator@/${PGDATABASE}"
			db-schema = "grest"
			db-anon-role = "web_anon"
			server-host = "127.0.0.1"
			server-port = 8050
			admin-server-port = 8060
			db-hoisted-tx-settings = ""
			db-aggregates-enabled = true
			db-plan-enabled = true
			#server-timing-enabled = true
			#jwt-secret = "secret-token"
			#db-pool = 10
			#db-extra-search-path = "public"
			max-rows = 1000
			EOF
    sudo chmod 640 "${CNODE_HOME}"/priv/grest.conf
    sudo chown authenticator:${USER} "${CNODE_HOME}"/priv/grest.conf
    # Create HAProxy config template
    [[ -f "${HAPROXY_CFG}" ]] && cp "${HAPROXY_CFG}" "${HAPROXY_CFG}"_bkp$(date +%s)

    bash -c "cat <<-EOF > ${HAPROXY_CFG}
			global
			  daemon
			  maxconn 256
			  ulimit-n 65536
			  stats socket \"\\\$GRESTTOP\"/sockets/haproxy.socket mode 0600 level admin user \"\\\$HAPROXY_SOCKET_USER\"
			  log 127.0.0.1 local0 notice
			  tune.disable-zero-copy-forwarding
			  insecure-fork-wanted
			  external-check
			
			defaults
			  mode http
			  log global
			  option dontlognull
			  option http-ignore-probes
			  option http-server-close
			  option forwardfor
			  #log-format \"%ci:%cp a:%f/%b/%s t:%Tq/%Tt %{+Q}r %ST b:%B C:%ac,%fc,%bc,%sc Q:%sq/%bq\"
			  option dontlog-normal
			  timeout client 120s
			  timeout server 120s
			  timeout connect 3s
			  timeout server-fin 2s
			  timeout http-request 5s
			
			frontend app
			  bind 0.0.0.0:8053
			  ## If using SSL, comment line above and uncomment line below
			  #bind :8453 ssl crt /etc/ssl/server.pem no-sslv3
			  compression direction response
			  compression algo-res gzip
			  compression type-res application/json
			  option http-buffer-request
			  http-request set-log-level silent
			  acl srv_down nbsrv(grest_postgrest) eq 0
			  acl is_wss hdr(Upgrade) -i websocket
			  http-request use-service prometheus-exporter if { path /metrics }
			  http-request track-sc0 src table flood_lmt_rate
			  http-request deny deny_status 429 if { sc_http_req_rate(0) gt 500 }
			  use_backend ogmios if { path_beg /api/v1/ogmios } || { path_beg /dashboard.js } || { path_beg /assets } || { path_beg /health } || is_wss
			  use_backend submitapi if { path_beg /api/v1/submittx }
			  use_backend grest_failover if srv_down
			  default_backend grest_postgrest
			
			backend grest_postgrest
			  balance first
			  #option external-check
			  acl grestviews path_beg -f \"\\\$GRESTTOP\"/files/grestrpcs
			  http-request set-path \"%[path,regsub(^/api/v1/,/)]\"
			  http-request set-path \"%[path,regsub(^/,/rpc/)]\" if !grestviews !{ path_beg /rpc } !{ path -i / }
			  #external-check path \"/usr/bin:/bin:/tmp:/sbin:/usr/sbin\"
			  #external-check command \"\\\$GRESTTOP\"/scripts/grest-poll.sh
			  server local 127.0.0.1:8050 check inter 20000 fall 1 rise 2
			
			backend grest_failover
			  server koios-ssl ${KOIOS_SRV}:443 ssl verify none
			  http-request set-header X-HAProxy-Hostname \"${KOIOS_SRV}\"
			  http-response set-header X-Failover true
			
			backend ogmios
			  balance first
			  http-request set-path \"%[path,regsub(^/api/v1/ogmios.*,/)]\"
			  option httpchk GET /health
			  http-check expect status 200
			  default-server inter 20s fall 1 rise 2
			  server local 127.0.0.1:1337 check
			
			backend submitapi
			  balance first
			  option httpchk POST /api/submit/tx
			  http-request set-path \"%[path,regsub(^/api/v1/submittx,/api/submit/tx)]\"
			  http-check expect status 415
			  default-server inter 20s fall 1 rise 2
			  server local 127.0.0.1:8090 check
			  #server koios-ssl ${KOIOS_SRV}:443 backup ssl verify none
			  http-after-response set-header Access-Control-Allow-Origin *
			  http-after-response set-header Access-Control-Allow-Headers \"Origin, X-Requested-With, Content-Type, Accept\"
			  http-after-response set-header Access-Control-Allow-Methods \"GET, HEAD, OPTIONS, POST\"
			  http-response return status 200 if METH_OPTIONS
			
			backend flood_lmt_rate
			  stick-table type ip size 1m expire 10m store http_req_rate(10s)
			EOF"
    printf "  Done!! Please ensure to set any custom settings/peers/TLS configs/etc back and update configs as necessary!\n"
  }

  deploy_systemd() {
    printf "[Re]Deploying Services..\n"
    printf "  PostgREST Service\n"
    sudo bash -c "cat <<-EOF > /etc/systemd/system/${CNODE_VNAME}-postgrest.service
			[Unit]
			Description=REST Overlay for Postgres database
			After=postgresql.service
			Requires=postgresql.service
			
			[Service]
			Restart=always
			RestartSec=5
			User=authenticator
			LimitNOFILE=1048576
			ExecStart=/home/authenticator/.local/bin/postgrest ${CNODE_HOME}/priv/grest.conf
			ExecReload=/bin/kill -SIGUSR1 \\\$MAINPID
			SyslogIdentifier=postgrest
			
			[Install]
			WantedBy=multi-user.target
			EOF"
    printf "  HAProxy Service\n"
    [[ -f /usr/sbin/haproxy ]] && sudo bash -c "cat <<-EOF > /etc/systemd/system/${CNODE_VNAME}-haproxy.service
			[Unit]
			Description=HAProxy Load Balancer
			After=network-online.target
			Wants=network-online.target
			
			[Service]
			Environment=\"GRESTTOP=${CNODE_HOME}\" \"CONFIG=${HAPROXY_CFG}\" \"PIDFILE=${CNODE_HOME}/logs/haproxy.pid\" \"HAPROXY_SOCKET_USER=${USER}\"
			ExecStartPre=/usr/sbin/haproxy -f \"\\\$CONFIG\" -c
			ExecStart=/usr/sbin/haproxy -Ws -f \"\\\$CONFIG\" -p \"\\\$PIDFILE\"
			ExecReload=/usr/sbin/haproxy -f \"\\\$CONFIG\" -c
			ExecReload=/bin/kill -USR2 \\\$MAINPID
			Restart=on-failure
			SuccessExitStatus=143
			KillMode=mixed
			Type=notify
			
			[Install]
			WantedBy=multi-user.target
			EOF"
    printf "  GRest Exporter Service\n"
    [[ -f "${CNODE_HOME}"/scripts/grest-exporter.sh ]] && sudo bash -c "cat <<-EOF > /etc/systemd/system/${CNODE_VNAME}-grest_exporter.service
			[Unit]
			Description=gRest Services Metrics Exporter
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
			SyslogIdentifier=grest_exporter
			TimeoutStopSec=5
			KillMode=mixed
			
			[Install]
			WantedBy=multi-user.target
			EOF"
    sudo systemctl daemon-reload && sudo systemctl enable ${CNODE_VNAME}-postgrest.service ${CNODE_VNAME}-haproxy.service ${CNODE_VNAME}-grest_exporter.service >/dev/null 2>&1
    printf "  Done!! Please ensure to all [re]start services above!\n"
  }
  
  # Description : Setup grest schema, web_anon user, and genesis and control tables.
  #             : SQL sourced from grest-helper-scrips/db-scripts/basics.sql.
  setup_db_basics() {
    local basics_sql_url="${DB_SCRIPTS_URL}/basics.sql"
    
    if ! basics_sql=$(curl -s -f -m "${CURL_TIMEOUT}" "${basics_sql_url}" 2>&1); then
      err_exit "Failed to get basic db setup SQL from ${basics_sql_url}"
    fi
    printf "Adding grest schema if missing and granting usage for web_anon...\n"
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
    printf "Resetting grest schema...\n"
    ! output=$(psql "${PGDATABASE}" -v "ON_ERROR_STOP=1" -q <<<${reset_sql} 2>&1) && err_exit "${output}"
  }

  # Description : Fully reset the grest node from the database POV.
  reset_grest() {
    local tr_dir="${HOME}/git/${CNODE_VNAME}-token-registry"
    sudo systemctl stop ${CNODE_VNAME}-postgrest.service
    [[ -d "${tr_dir}" ]] && rm -rf "${tr_dir}"
    recreate_grest_schema
  }

  deploy_rpc() {
    file_name=$(basename "${1}")
    dir_name=$(basename $(dirname "${1}"))
    [[ -z ${file_name} || ${file_name} != *.sql ]] && return
    dl_url="${1}"
    [[ -z ${dl_url} ]] && return
    ! rpc_sql=$(curl -s -f -m ${CURL_TIMEOUT} ${dl_url} 2>/dev/null) && printf "     \e[31mERROR\e[0m: download failed: ${dl_url}\n" && return 1
    printf "    Deploying Function :   \e[32m${dir_name}/${file_name}\e[0m\n"
    ! output=$(psql "${PGDATABASE}" -v "ON_ERROR_STOP=1" <<<${rpc_sql} 2>&1) && printf "        \e[31mERROR\e[0m: ${output}\n"
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
    printf "(Re)Deploying Postgres RPCs/views/schedule...\n"
    check_db_status
    if [[ $? -eq 1 ]]; then
      err_exit "Please wait for Cardano DBSync to populate PostgreSQL DB at least until Alonzo fork, and then re-run this setup script with the -q flag."
    fi

    printf "  Downloading DBSync RPC functions from Guild Operators GitHub store...\n"
    if ! rpc_file_list=$(curl -s -f -m ${CURL_TIMEOUT} "https://api.github.com/repos/${G_ACCOUNT}/koios-artifacts/git/trees/${SGVERSION}?recursive=1" | grep "files/grest/rpc.*.sql" | grep -v db-scripts | sed -e 's#^.*.files/grest#https://raw.githubusercontent.com/'"${G_ACCOUNT}"'/koios-artifacts/'"${SGVERSION}"'/files/grest#g' -e 's#",$##g' 2>&1); then
      err_exit "${rpc_file_list}"
    fi
    printf "  (Re)Deploying GRest objects to DBSync...\n"
    populate_genesis_table
    for row in ${rpc_file_list}; do
      deploy_rpc ${row}
    done
    setup_cron_jobs
    printf "  All RPC functions successfully added to DBSync! For detailed query specs and examples, visit ${API_DOCS_URL}!\n"
    printf "Restarting PostgREST to clear schema cache..\n"
    sudo systemctl restart ${CNODE_VNAME}-postgrest.service && sudo systemctl reload ${CNODE_VNAME}-haproxy.service && printf "Done!!\n"
  }

  # Description : Update the setup-grest.sh version used in the database.
  update_grest_version() {
    koios_release_commit="$(curl -s https://api.github.com/repos/${G_ACCOUNT}/koios-artifacts/commits/${SGVERSION} | jq -r '.sha')"
    [[ -z ${koios_release_commit} ]] && koios_release_commit="null"
    [[ "${RESET_GREST}" == "Y" ]] && artifacts=['reset',"${koios_release_commit}"] || artifacts=["${koios_release_commit}"]

    ! output=$(psql ${PGDATABASE} -qbt -c "SELECT GREST.update_control_table(
        'version',
        '${SGVERSION}',
        '${artifacts}'
      );" 2>&1 1>/dev/null) && err_exit "${output}"
  }

######## Execution ########
  # Parse command line options
  while getopts :i:urqb: opt; do
    case ${opt} in
    i) I_ARGS="${OPTARG}" ;;
    u) SKIP_UPDATE='Y' ;;
    r) RESET_GREST='Y' && DB_QRY_UPDATES='Y' ;;
    q) DB_QRY_UPDATES='Y' ;;
    b) echo "${OPTARG}" > ./.env_branch ;;
    \?) usage ;;
    esac
  done
  update_check "$@"
  common_init
  set_environment_variables
  parse_args
  common_update
  if [[ "${INSTALL_POSTGREST}" == "Y" ]]; then setup_db_basics; deploy_postgrest; fi
  if [[ "${INSTALL_HAPROXY}" == "Y" ]]; then deploy_haproxy; fi
  if [[ "${INSTALL_MONITORING_AGENTS}" == "Y" ]]; then deploy_monitoring_agents; fi
  if [[ "${OVERWRITE_CONFIG}" == "Y" ]]; then deploy_configs; fi
  if [[ "${OVERWRITE_SYSTEMD}" == "Y" ]]; then deploy_systemd; fi
  if [[ "${RESET_GREST}" == "Y" ]]; then remove_all_grest_cron_jobs; reset_grest; deploy_pgcardano_ext; fi
  if [[ "${DB_QRY_UPDATES}" == "Y" ]]; then remove_all_grest_cron_jobs; setup_db_basics; deploy_query_updates; update_grest_version; fi
  pushd -0 >/dev/null || err_exit
  dirs -c
