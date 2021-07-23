#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2046,SC1078
# shellcheck source=/dev/null

unset CNODE_HOME

##########################################
# User Variables - Change as desired     #
# command line flags override set values #
##########################################

CURL_TIMEOUT=60         # Maximum time in seconds that you allow the file download operation to take before aborting (Default: 60s)
UPDATE_CHECK='Y'        # Check if there is an updated version of setup-grest.sh script to download

######################################
# Do NOT modify code below           #
######################################

err_exit() {
  echo -e "$*" >&2
  echo -e "Exiting...\n" >&2
  pushd -0 >/dev/null && dirs -c
  exit 1
}

usage() {
  cat <<EOF >&2

Usage: $(basename "$0") [-f] [-b <branch>] [-t <name>]

Install and setup haproxy, and create systemd services for haproxy, postgREST and dbsync

-f    Force overwrite of all files including normally saved user config sections 
-t    Alternate name for top level folder, non alpha-numeric chars will be replaced with underscore (Default: cnode)
-b    Use alternate branch of scripts to download - only recommended for testing/development (Default: master)

EOF
  exit 1
}

while getopts :ft:b: opt; do
  case ${opt} in
    f ) FORCE_OVERWRITE='Y' ;;
    t ) CNODE_NAME=${OPTARG//[^[:alnum:]]/_} ;;
    b ) BRANCH=${OPTARG} ;;
    \? ) usage ;;
    esac
done
shift $((OPTIND -1))

dirs -c # clear dir stack
[[ -z ${FORCE_OVERWRITE} ]] && FORCE_OVERWRITE='N'
[[ -z ${CNODE_NAME} ]] && CNODE_NAME='cnode'
CNODE_PATH="/opt/cardano"
CNODE_HOME=${CNODE_PATH}/${CNODE_NAME}
CNODE_VNAME=$(echo "$CNODE_NAME" | awk '{print toupper($0)}')

[[ -f "${CNODE_HOME}"/scripts/.env_branch ]] && BRANCH=$(cat "${CNODE_HOME}"/scripts/.env_branch) || BRANCH=master

if ! curl -s -f -m ${CURL_TIMEOUT} "https://api.github.com/repos/cardano-community/guild-operators/branches" | jq -e ".[] | select(.name == \"${BRANCH}\")" &>/dev/null ; then
  echo -e "\nWARN!! ${BRANCH} branch does not exist, falling back to alpha branch\n"
  BRANCH=alpha
  echo "${BRANCH}" > "${CNODE_HOME}"/scripts/.env_branch
else
  echo "${BRANCH}" > "${CNODE_HOME}"/scripts/.env_branch
fi

REPO_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators"
URL_RAW="${REPO_RAW}/${BRANCH}"
PARENT="$(dirname $0)"
[[ -z ${UPDATE_CHECK} ]] && UPDATE_CHECK='Y'
[[ ! -d "${HOME}"/.cabal/bin ]] && mkdir -p "${HOME}"/.cabal/bin

if [[ "${UPDATE_CHECK}" = 'Y' ]] && curl -s -f -m ${CURL_TIMEOUT} -o "${PARENT}"/setup-grest.sh.tmp ${URL_RAW}/scripts/grest-helper-scripts/setup-grest.sh 2>/dev/null; then
  TEMPL_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/setup-grest.sh)
  TEMPL2_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/setup-grest.sh.tmp)
  if [[ "$(echo ${TEMPL_CMD} | sha256sum)" != "$(echo ${TEMPL2_CMD} | sha256sum)" ]]; then
    cp "${PARENT}"/setup-grest.sh "${PARENT}/setup-grest.sh_bkp$(date +%s)"
    STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/setup-grest.sh)
    printf '%s\n%s\n' "$STATIC_CMD" "$TEMPL2_CMD" > "${PARENT}"/setup-grest.sh.tmp
    {
      mv -f "${PARENT}"/setup-grest.sh.tmp "${PARENT}"/setup-grest.sh && \
      chmod 755 "${PARENT}"/setup-grest.sh && \
      echo -e "\nUpdate applied successfully, please run setup-grest again!\n" && \
      exit 0;
    } || {
      err_exit "Update failed!\n\nPlease manually download latest version of setup-grest.sh script from GitHub"
    }
  fi
fi
rm -f "${PARENT}"/setup-grest.sh.tmp

mkdir -p ~/tmp

if ! command -v postgrest >/dev/null; then
  echo "PostgREST not available in \$PATH, installing.."
  pushd ~/tmp >/dev/null || err_exit
  pgrest_asset_url="$(curl -s https://api.github.com/repos/PostgREST/postgrest/releases/latest | jq -r '.assets[].browser_download_url' | grep 'linux-x64-static.tar.xz')"
  if curl -sL -f -m ${CURL_TIMEOUT} -o postgrest.tar.xz "${pgrest_asset_url}"; then
    tar xf postgrest.tar.xz &>/dev/null && rm -f postgrest.tar.xz
    [[ -f postgrest ]] || err_exit "ERROR!! postgrest archive downloaded but binary not found after attempting to extract package!"
    mv ./postgrest ~/.cabal/bin/
  else
    err_exit "ERROR!! Could not download ${pgrest_asset_url}"
  fi
  echo "PostgREST Installed! Please make sure you have a Postgres DB setup as per https://cardano-community.github.io/guild-operators/#/Build/pgrest"
fi

if [ ! -f /usr/local/sbin/haproxy ]; then
  echo "HAProxy not built on this system, (re)building for consistency of build parameters and versions.."
  pushd ~/tmp >/dev/null || err_exit
  haproxy_url="http://www.haproxy.org/download/2.4/src/haproxy-2.4.1.tar.gz"
  if curl -sL -f -m ${CURL_TIMEOUT} -o haproxy.tar.gz "${haproxy_url}"; then
    tar xf haproxy.tar.gz &>/dev/null && rm -f haproxy.tar.gz
    if command -v apt-get >/dev/null; then
     sudo apt-get -y install libpcre3-dev || err_exit "ERROR!! 'sudo apt-get -y install libpcre3-dev' failed!"
    fi
    if command -v yum >/dev/null; then
      sudo yum -y install pcre-devel || err_exit "ERROR!! 'sudo yum -y install prce-devel' failed!"
    fi
    mv haproxy-2.4.1 haproxy
    cd haproxy || return
    make clean >/dev/null
    make -j $(nproc) TARGET=linux-glibc USE_ZLIB=1 USE_LIBCRYPT=1 USE_OPENSSL=1 USE_PCRE=1 USE_SYSTEMD=1 >/dev/null
    sudo make install >/dev/null
    sudo cp /usr/local/sbin/haproxy /usr/sbin/
  else
    err_exit "ERROR!! Could not download ${haproxy_url}"
  fi
fi

if [[ "${FORCE_OVERWRITE}" != 'N' ]]; then
  echo "[Re]Creating /etc/haproxy/haproxy.cfg file.."
  sudo mkdir -p /etc/haproxy
  sudo bash -c "cat << 'EOF' > /etc/haproxy/haproxy.cfg
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
  #bind :8453 ssl crt /etc/ssl/server.pem no-sslv3
  #redirect scheme https code 301 if !{ ssl_fc }
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
fi

if ! command -v socat >/dev/null; then
  echo -e "Installing socat .."
  if command -v apt-get >/dev/null; then
     sudo apt-get -y install socat >/dev/null || err_exit "ERROR!! 'sudo apt-get -y install socat' failed!"
  elif command -v yum >/dev/null; then
    sudo yum -y install socat >/dev/null || err_exit "ERROR!! 'sudo yum -y install socat' failed!"
  else
    err_exit "ERROR!! 'socat' not found in \$PATH, needed to for node exporter monitoring!"
  fi
fi

pushd "${CNODE_HOME}"/scripts >/dev/null || err_exit

curl -s -f -m ${CURL_TIMEOUT} -o grest-poll.sh.tmp ${URL_RAW}/scripts/grest-helper-scripts/grest-poll.sh
curl -s -f -m ${CURL_TIMEOUT} -o dbsync.sh.tmp ${URL_RAW}/scripts/grest-helper-scripts/dbsync.sh
curl -s -f -m ${CURL_TIMEOUT} -o checkstatus.sh.tmp ${URL_RAW}/scripts/grest-helper-scripts/checkstatus.sh
curl -s -f -m ${CURL_TIMEOUT} -o getmetrics.sh.tmp ${URL_RAW}/scripts/grest-helper-scripts/getmetrics.sh

### Update file retaining existing custom configs
updateWithCustomConfig() {
  file=$1
  if [[ ! -f ${file}.tmp ]]; then
    echo "ERROR!! Failed to download '${file}' from GitHub"
    return
  fi
  if [[ -f ${file} && ${FORCE_OVERWRITE} = 'N' ]]; then
    if grep '^# Do NOT modify' ${file} >/dev/null 2>&1; then
      TEMPL_CMD=$(awk '/^# Do NOT modify/,0' ${file}.tmp)
      if [[ -z ${TEMPL_CMD} ]]; then
        echo "ERROR!! Script downloaded from GitHub corrupt, ignoring update for '${file}'"
        rm -f ${file}.tmp
        return
      fi
      STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' ${file})
      printf '%s\n%s\n' "${STATIC_CMD}" "${TEMPL_CMD}" > ${file}.tmp
    else
      rm -f ${file}.tmp
      return
    fi
  fi
  [[ -f ${file} ]] && cp -f ${file} "${file}_bkp$(date +%s)"
  mv -f ${file}.tmp ${file}
  chmod 755 ${file}
}

[[ ${FORCE_OVERWRITE} = 'Y' ]] && echo "Forced full upgrade!! Please re-apply customisations to scripts as required!"

updateWithCustomConfig "grest-poll.sh"
updateWithCustomConfig "dbsync.sh"
updateWithCustomConfig "checkstatus.sh"
updateWithCustomConfig "getmetrics.sh"

sed -e "s@/opt/cardano/cnode@${CNODE_HOME}@g" -e "s@CNODE_HOME@${CNODE_VNAME}_HOME@g" -i ./dbsync.sh

echo "Deploying systemd services.."
echo -e "\e[32m~~ Cardano DB Sync ~~\e[0m"
sudo bash -c "cat << 'EOF' > /etc/systemd/system/${CNODE_NAME}-dbsync.service
[Unit]
Description=Cardano DB Sync
After=${CNODE_NAME}.service postgresql.service
Requires=postgresql.service

[Service]
Type=simple
Restart=always
RestartSec=5
User=$USER
LimitNOFILE=1048576
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/dbsync.sh\"
KillSignal=SIGINT
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=${CNODE_NAME}-dbsync
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF"

echo -e "\e[32m~~ PostgREST Service ~~\e[0m"
sudo bash -c "cat << 'EOF' > /etc/systemd/system/postgrest.service
[Unit]
Description=REST API for Postgres database
After=postgresql.service
Requires=postgresql.service

[Service]
Restart=always
RestartSec=5
User=$USER
LimitNOFILE=1048576
ExecStart=${HOME}/.cabal/bin/postgrest ${CNODE_HOME}/priv/grest.conf
ExecReload=/bin/kill -SIGUSR1 \$MAINPID
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=postgrest

[Install]
WantedBy=multi-user.target
EOF"

echo -e "\e[32m~~ HAProxy Service ~~\e[0m"
sudo bash -c "cat << 'EOF' > /etc/systemd/system/haproxy.service
[Unit]
Description=HAProxy Load Balancer
After=network.target

[Service]
Environment=\"CONFIG=/etc/haproxy/haproxy.cfg\" \"PIDFILE=/run/haproxy.pid\"
ExecStartPre=/usr/sbin/haproxy -f \$CONFIG -c -q
ExecStart=/usr/sbin/haproxy -Ws -f \$CONFIG -p \$PIDFILE
ExecReload=/usr/sbin/haproxy -f \$CONFIG -c -q
SuccessExitStatus=143
KillMode=mixed
Type=notify

[Install]
WantedBy=multi-user.target
EOF"

echo -e "\e[32m~~ GRest Exporter Service ~~\e[0m"
e=!
sudo bash -c "cat << 'EOF' > ${CNODE_HOME}/scripts/grest-exporter.sh
#${e}/usr/bin/env bash
socat TCP-LISTEN:8059,reuseaddr,fork     SYSTEM:\"echo HTTP/1.1 200 OK;SERVED=true bash ${CNODE_HOME}/scripts/getmetrics.sh;\"
EOF"
sudo chown $USER:$USER "${CNODE_HOME}"/scripts/grest-exporter.sh
chmod 755 "${CNODE_HOME}"/scripts/grest-exporter.sh
sudo bash -c "cat << 'EOF' > /etc/systemd/system/grest_exporter.service
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

sudo systemctl daemon-reload
sudo systemctl enable ${CNODE_NAME}-dbsync.service
sudo systemctl enable postgrest.service
sudo systemctl enable haproxy.service
sudo systemctl enable grest_exporter.service

if ! command -v cardano-db-sync-extended >/dev/null; then
  err_exit "\n\e[31mERROR\e[0m: We could not find 'cardano-db-sync-extended' binary in \$PATH , please ensure you've followed the instructions below:\n" \
    "  https://cardano-community.github.io/guild-operators/#/Build/dbsync\n"
fi

if ! command -v psql &>/dev/null; then 
  err_exit "\n\e[31mERROR\e[0m: We could not find 'psql' binary in \$PATH , please ensure you've followed the instructions below:\n" \
    "  https://cardano-community.github.io/guild-operators/Appendix/postgres\n"
fi

if [[ -z ${PGPASSFILE} || ! -f "${PGPASSFILE}" ]]; then
  err_exit "\n\e[31mERROR\e[0m: PGPASSFILE env variable not set or pointing to a non-existing file: ${PGPASSFILE}\n" \
    "  https://cardano-community.github.io/guild-operators/Build/dbsync\n"
fi

if ! dbsync_network=$(psql -qtAX -d cexplorer -c "select network_name from meta;" 2>&1); then
  err_exit "\n\e[31mERROR\e[0m: querying Cardano DBSync PostgreSQL DB, please re-run script after DBSync has started/finished its syncronization.\n" \
    "  https://cardano-community.github.io/guild-operators/Build/dbsync\n"
fi
echo -e "Successfully connected to \e[94m${dbsync_network}\e[0m Cardano DBSync PostgreSQL DB!"

echo -e "Downloading DBSync RPC functions from Guild Operators GitHub store .."
if ! rpc_file_list=$(curl -s -f -m ${CURL_TIMEOUT} https://api.github.com/repos/cardano-community/guild-operators/contents/files/grest/rpc?ref=${BRANCH} 2>&1); then
  err_exit "\e[31mERROR\e[0m: ${rpc_file_list}"
fi

jqDecode() {
  base64 --decode <<< $2 | jq -r "$1"
}

deployRPC() {
  file_name=$(jqDecode '.name' "${1}")
  [[ -z ${file_name} || ${file_name} != *.sql ]] && return
  dl_url=$(jqDecode '.download_url //empty' "${1}")
  [[ -z ${dl_url} ]] && return
  ! rpc_desc=$(curl -s -f -m ${CURL_TIMEOUT} ${dl_url} 2>/dev/null | grep 'COMMENT ON FUNCTION' | cut -d\' -f2) && echo -e "\e[31mERROR\e[0m: download failed: ${dl_url}" && return 1
  ! rpc_sql=$(curl -s -f -m ${CURL_TIMEOUT} ${dl_url} 2>/dev/null) && echo -e "\e[31mERROR\e[0m: download failed: ${dl_url%.json}.sql" && return 1
  echo -e "\nFunction:    \e[32m${file_name%.sql}\e[0m"
  echo -e "  Description: \e[37m${rpc_desc}\e[0m"
  ! output=$(psql cexplorer -v "ON_ERROR_STOP=1" <<< ${rpc_sql} 2>&1) && echo -e "  \e[31mERROR\e[0m: ${output}"
}

# add grest schema if missing and grant usage for web_anon
echo -e "\e[32mAdd grest schema if missing and grant usage for web_anon\e[0m"
psql cexplorer >/dev/null << 'SQL'
BEGIN;

DO
$$
BEGIN
	CREATE ROLE web_anon nologin;
	EXCEPTION WHEN DUPLICATE_OBJECT THEN
		RAISE NOTICE 'web_anon exists, skipping...';
END
$$;

CREATE SCHEMA IF NOT EXISTS grest;
GRANT USAGE ON SCHEMA public TO web_anon;
GRANT USAGE ON SCHEMA grest TO web_anon;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO web_anon;
GRANT SELECT ON ALL TABLES IN SCHEMA grest TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA grest GRANT SELECT ON TABLES TO web_anon;
ALTER ROLE web_anon SET search_path TO grest, public;
COMMIT;
SQL

echo -e "\e[32mDeploying RPCs to DBSync ..\e[0m"

for row in $(jq -r '.[] | @base64' <<< ${rpc_file_list}); do
  if [[ $(jqDecode '.type' "${row}") = 'dir' ]]; then
    echo -e "\nDownloading RPC functions from subdir $(jqDecode '.name' "${row}")"
    if ! rpc_file_list_subdir=$(curl -s -m ${CURL_TIMEOUT} "https://api.github.com/repos/cardano-community/guild-operators/contents/files/grest/rpc/$(jqDecode '.name' "${row}")?ref=${BRANCH}"); then
      echo -e "  \e[31mERROR\e[0m: ${rpc_file_list_subdir}" && continue
    fi
    for row2 in $(jq -r '.[] | @base64' <<< ${rpc_file_list_subdir}); do
      deployRPC ${row2}
    done
  else
    deployRPC ${row}
  fi
done

echo -e "\n\e[32mAll RPC functions successfully added to DBSync! For detailed query specs and examples, visit https://git.io/J8s95!\e[0m\n"
echo -e "\e[33mPlease restart PostgREST before attempting to use the added functions\e[0m"
echo -e "  \e[94msudo systemctl restart postgrest.service\e[0m\n"

pushd -0 >/dev/null || err_exit; dirs -c
