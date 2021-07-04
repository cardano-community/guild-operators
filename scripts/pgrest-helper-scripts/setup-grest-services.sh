#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2046,SC1078
# shellcheck source=/dev/null

unset CNODE_HOME

##########################################
# User Variables - Change as desired     #
# command line flags override set values #
##########################################

CURL_TIMEOUT=60         # Maximum time in seconds that you allow the file download operation to take before aborting (Default: 60s)
UPDATE_CHECK='Y'        # Check if there is an updated version of setup-grest-services.sh script to download
DEF_BRANCH="pgrest-dnd" # TODO: Remove and use .env_branch when ready to merge to alpha

######################################
# Do NOT modify code below           #
######################################

err_exit() {
  printf "%s\nExiting...\n" "$*" >&2
  pushd -0 >/dev/null && dirs -c
  exit 1
}

usage() {
  cat <<EOF >&2

Usage: $(basename "$0") [-f] [-b <branch>] [-t <name>]

Install and setup haproxy, and create systemd services for haproxy, postgREST and dbsync

-f    Force overwrite of all files including normally saved user config sections 
-t    Alternate name for top level folder, non alpha-numeric chars will be replaced with underscore (Default: cnode)
-b    Use alternate branch of scripts to download - only recommended for testing/development (Default: ${DEF_BRANCH})

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

[[ -z "${BRANCH}" ]] && BRANCH="${DEF_BRANCH}"

REPO_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators"
URL_RAW="${REPO_RAW}/${BRANCH}"
PARENT="$(dirname $0)"
[[ -z ${UPDATE_CHECK} ]] && UPDATE_CHECK='Y'
[[ ! -d "${HOME}"/.cabal/bin ]] && mkdir -p "${HOME}"/.cabal/bin

if [[ "${UPDATE_CHECK}" = 'Y' ]] && curl -s -f -m ${CURL_TIMEOUT} -o "${PARENT}"/setup-grest-services.sh.tmp ${URL_RAW}/scripts/pgrest-helper-scripts/setup-grest-services.sh 2>/dev/null; then
  TEMPL_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/setup-grest-services.sh)
  TEMPL2_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/setup-grest-services.sh.tmp)
  if [[ "$(echo ${TEMPL_CMD} | sha256sum)" != "$(echo ${TEMPL2_CMD} | sha256sum)" ]]; then
    cp "${PARENT}"/setup-grest-services.sh "${PARENT}/setup-grest-services.sh_bkp$(date +%s)"
    STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/setup-grest-services.sh)
    printf '%s\n%s\n' "$STATIC_CMD" "$TEMPL2_CMD" > "${PARENT}"/setup-grest-services.sh.tmp
    {
      mv -f "${PARENT}"/setup-grest-services.sh.tmp "${PARENT}"/setup-grest-services.sh && \
      chmod 755 "${PARENT}"/setup-grest-services.sh && \
      echo -e "\nUpdate applied successfully, please run setup-grest-services again!\n" && \
      exit 0;
    } || {
      echo -e "Update failed!\n\nPlease manually download latest version of setup-grest-services.sh script from GitHub" && \
      exit 1;
    }
  fi
fi
rm -f "${PARENT}"/setup-grest-services.sh.tmp

mkdir -p ~/tmp

if ! command -v postgrest >/dev/null; then
  echo "PostgREST not available in \$PATH, installing.."
  pushd ~/tmp >/dev/null || err_exit
  pgrest_asset_url="$(curl -s https://api.github.com/repos/PostgREST/postgrest/releases/latest | jq -r '.assets[].browser_download_url' | grep 'linux-x64-static.tar.xz')"
  if curl -sL -f -m ${CURL_TIMEOUT} -o postgrest.tar.xz "${pgrest_asset_url}"; then
    tar xf postgrest-linux-x64.tar.xz &>/dev/null && rm -f postgrest.tar.xz
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
    if command -v apt >/dev/null; then
     sudo apt -y install libpcre3-dev || err_exit "ERROR!! 'sudo apt -y install libpcre3-dev' failed!"
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
  maxconn 512
  stats socket ipv4@127.0.0.1:8055 mode 0600 level admin
  log 127.0.0.1 local2
  insecure-fork-wanted
  external-check

defaults
  mode tcp
  log global
  option tcplog
  timeout client 5s
  timeout server 5s
  timeout connect 3s

frontend app
  bind 0.0.0.0:8053
  default_backend pgrest_core

backend pgrest_core
  balance first
  option external-check
  external-check path \"/usr/bin:/bin:/tmp:/sbin:/usr/sbin\"
  external-check command ${CNODE_HOME}/scripts/pgrest-poll.sh
  server local 127.0.0.1:8050 check inter 5000
  server rdlrt 209.145.50.190:8053 check inter 5000 backup
  server homer 95.216.188.94:8053 check inter 5000 backup
  server ola pgrest-guild.ahlnet.nu:8053 check inter 5000 backup
  server damjan 195.201.129.190:8053 check inter 5000 backup
  server gufmar 185.161.193.105:6029 check inter 5000 backup
EOF"
fi

pushd "${CNODE_HOME}"/scripts >/dev/null || err_exit
if [ ! -f "$CNODE_HOME"/scripts/env ]; then
  err_exit "ERROR!! Folder '${CNODE_HOME}/scripts' does not exist, please ensure you're running instance as per https://cardano-community.github.io/guild-operators/#/basics?id=pre-requisites"
else
  pushd "${CNODE_HOME}"/scripts >/dev/null || err_exit
  curl -s -f -m ${CURL_TIMEOUT} -o pgrest-poll.sh.tmp ${URL_RAW}/scripts/pgrest-helper-scripts/pgrest-poll.sh
  curl -s -f -m ${CURL_TIMEOUT} -o dbsync.sh.tmp ${URL_RAW}/scripts/pgrest-helper-scripts/dbsync.sh
  curl -s -f -m ${CURL_TIMEOUT} -o checkstatus.sh ${URL_RAW}/scripts/pgrest-helper-scripts/checkstatus.sh
fi

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

updateWithCustomConfig "pgrest-poll.sh"
updateWithCustomConfig "dbsync.sh"

sed -e "s@/opt/cardano/cnode@${CNODE_HOME}@g" -e "s@CNODE_HOME@${CNODE_VNAME}_HOME@g" -i ./dbsync.sh

echo "Deploying systemd services.."
. "${PARENT}"/env offline
echo -e "\e[32m~~ Cardano DB Sync ~~\e[0m"
sudo bash -c "cat << 'EOF' > /etc/systemd/system/${CNODE_NAME}-dbsync.service
[Unit]
Description=Cardano DB Sync
After=${CNODE_NAME}.service postgresql.service
Requires=${CNODE_NAME}.service postgresql.service
PartOf=${CNODE_NAME}.service

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
ExecStart=${HOME}/.cabal/bin/postgrest ${CNODE_HOME}/priv/pgrest.conf
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

sudo systemctl daemon-reload

if ! command -v cardano-db-sync-extended >/dev/null ; then
  echo "NOTE: We could not find 'cardano-db-sync-extended' binary in \$PATH , please ensure you've followed the instructions below:"
  echo "  https://cardano-community.github.io/guild-operators/#/Build/dbsync"
fi

pushd -0 >/dev/null || err_exit; dirs -c
