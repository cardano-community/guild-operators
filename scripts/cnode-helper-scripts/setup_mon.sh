#!/bin/bash
# shellcheck disable=SC2209,SC2164

######################################################################
#### Environment Variables
######################################################################
CNODE_IP=127.0.0.1
CNODE_PORT=12798
GRAFANA_HOST=0.0.0.0
GRAFANA_PORT=5000
PROJ_PATH=/opt/cardano/monitoring
PROM_HOST=127.0.0.1
PROM_PORT=9090
NEXP_PORT=$(( PROM_PORT + 1 ))

######################################################################
#### Static Variables
######################################################################
ARCHS=("darwin-amd64" "linux-amd64"  "linux-armv6")
TMP_DIR=$(mktemp -d "/tmp/cnode_monitoring.XXXXXXXX")
PROM_VER=2.20.0
GRAF_VER=7.1.2
NEXP_VER=1.0.1
NEXP="node_exporter"
SKY_DB_URL="https://raw.githubusercontent.com/Oqulent/SkyLight-Pool/master/Haskel_Node_SKY_Relay1_Dash.json"
IOHK_DB="cardano-application-dashboard-v2.json"
IOHK_DB_URL="https://raw.githubusercontent.com/input-output-hk/cardano-ops/master/modules/grafana/cardano/$IOHK_DB"
export CNODE_IP CNODE_PORT PROJ_PATH TMP_DIR
DEBUG="N"

######################################################################
#### Functions
######################################################################
clean_up () {
    echo "Cleaning up..." >&2
    $DBG rm -rf "$TMP_DIR"
    RES=$1
    exit "${RES:=127}"
}

message() {
    echo -e "$*" >&2
    exit 127
}

get_idx () {
    case $OSTYPE in
        "darwin"*)
            IDX=0
        ;;
        "linux-gnu"*)
            if [[ $HOSTTYPE == *"x86_64"* ]]; then
                IDX=1
            elif [[ $HOSTTYPE == *"arm"* ]]; then
                IDX=2
            else
                message "The $HOSTTYPE  is not supported"
            fi
        ;;
        *)
            message "The \"$OSTYPE\" OS is not supported"
        ;;
    esac
    echo $IDX
}

dl() {
    DL_URL="${1}"
    OUTPUT="${TMP_DIR}/$(basename "$DL_URL")"
    shift

    case ${DL} in
        *"wget"*)
            wget --no-check-certificate --output-document="${OUTPUT}" "${DL_URL}";;
        *)
            ( cd "$TMP_DIR" && curl -JOL "$DL_URL" --silent );;
    esac
}

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") [-d directory] [-i hostname] [-p port]
Setup monitoring using Prometheus and Grafana for Cardano Node
-d directory      Directory where you'd like to deploy the packages for prometheus , node exporter and grafana
-i IP/hostname    IPv4 address or a FQDN/DNS name where your cardano-node (relay) is running (check for hasPrometheus in config.json; eg: 127.0.0.1 if same machine as cardano-node)
-p port           Port at which your cardano-node is exporting stats (check for hasPrometheus in config.json; eg: 12798)
EOF
  exit 1
}

######################################################################
#### MAIN
######################################################################

if [[ "${DEBUG}" == "Y" ]]; then
  DBG=echo
else
  unset DBG
fi

CURL=$(command -v curl)
WGET=$(command -v wget)

DL=${CURL:=$WGET}

if  [ -z "$DL" ]; then
    message 'You need to have "wget" or "curl" to be installed\nand accessable by PATH environment to continue...\nExiting.'
fi

# if using CNODE_HOME
if [[ -f "$CNODE_HOME/sripts/env" ]]; then
  CNODE_IP=$(jq -r .hasPrometheus[0] "$CONFIG" 2>/dev/null)
  CNODE_PORT=$(jq -r .hasPrometheus[1] "$CONFIG" 2>/dev/null)
  PROJ_PATH="$(cd "$CNODE_HOME/../monitoring 2>/dev/null";pwd)"
fi

while getopts :d:i:p: opt; do
  case ${opt} in
    i)
      CNODE_IP="$OPTARG"
      ;;
    p)
      CNODE_PORT="$OPTARG"
      ;;
    d)
      PROJ_PATH="$OPTARG"
      ;;
    \?)
      usage
      exit
      ;;
  esac
done
shift "$((OPTIND -1))"

if [ -e "$PROJ_PATH" ]; then
    message "The \"$PROJ_PATH\" directory exist pls move or delete it.\nExiting."
fi

IDX=$(get_idx)

trap clean_up  SIGHUP SIGINT SIGQUIT SIGTRAP SIGABRT SIGTERM

PROM_URL="https://github.com/prometheus/prometheus/releases/download/v$PROM_VER/prometheus-$PROM_VER.${ARCHS[IDX]}.tar.gz"
GRAF_URL="https://dl.grafana.com/oss/release/grafana-$GRAF_VER.${ARCHS[IDX]}.tar.gz"
NEXP_URL="https://github.com/prometheus/$NEXP/releases/download/v$NEXP_VER/$NEXP-$NEXP_VER.${ARCHS[IDX]}.tar.gz"

echo ""
echo -e "Downloading prometheus v$PROM_VER..." >&2
$DBG dl "$PROM_URL"

echo -e "Downloading grafana v$GRAF_VER..." >&2
$DBG dl "$GRAF_URL"

echo -e "Downloading exporter v$NEXP_VER..." >&2
$DBG dl "$NEXP_URL"

echo -e "Downloading grafana dashboard(s)..." >&2

echo -e "  - SKYLight Monitoring Dashboard" >&2
$DBG dl "$SKY_DB_URL"

echo -e "  - IOHK Monitoring Dashboard" >&2
$DBG dl "$IOHK_DB_URL"

echo ""

PROM_DIR="$PROJ_PATH/prometheus"
GRAF_DIR="$PROJ_PATH/grafana"
NEXP_DIR="$PROJ_PATH/exporters"
DASH_DIR="$PROJ_PATH/dashboards"
SYSD_DIR="$PROJ_PATH/systemd"

mkdir -p "$PROJ_PATH" 2>/dev/null
rc=$?
if [[ "$rc" != 0 ]]; then
  echo "NOTE: Could not create directory as $(whoami), attempting sudo .."
  sudo mkdir -p "$PROJ_PATH" || message "WARN:Could not create folder $PROJ_PATH , please ensure that you have access to create it"
  sudo chown "$(whoami)":"$(id -g)" "$PROJ_PATH"
  chmod 750 "$PROJ_PATH"
  echo "NOTE: No worries, sudo worked !! Moving on .."
fi
mkdir -p "$PROM_DIR" "$GRAF_DIR" "$NEXP_DIR" "$DASH_DIR" "$SYSD_DIR"

tar zxC "$PROM_DIR" -f "$TMP_DIR"/*prome*gz --strip-components 1
tar zxC "$GRAF_DIR" -f "$TMP_DIR"/*graf*gz --strip-components 1
tar zxC "$TMP_DIR" -f "$TMP_DIR"/*node_exporter*gz --strip-components 1

echo -e "Configuring components" >&2

mv "$TMP_DIR/node_exporter" "$NEXP_DIR/"
chmod +x "$NEXP_DIR"/*

# Fix grafana's datasource.
sed -e "s#Prometheus#prometheus#g" "$TMP_DIR"/*.json -i
cp -pr "$TMP_DIR"/*.json "$DASH_DIR/"

HOSTNAME=$(hostname)

sed -e "s/http_addr.*/http_addr = $GRAFANA_HOST/g" -e "s/http_port = 3000/http_port = $GRAFANA_PORT/g" "$GRAF_DIR"/conf/defaults.ini -i
sed -e "s#\(^scrape_configs:.*\)#\1\n\
  - job_name: '${HOSTNAME}_cardano_node'\n\
    static_configs:\n\
    - targets: ['$CNODE_IP:$CNODE_PORT']\n\
  - job_name: '${HOSTNAME}_node_exporter'\n\
    static_configs:\n\
    - targets: ['$CNODE_IP:$NEXP_PORT']#g" -e "s#localhost:9090#$PROM_HOST:$PROM_PORT#g" "$PROM_DIR"/prometheus.yml -i

echo "Registering Prometheus as datasource in Grafana.."

cat > "$GRAF_DIR"/conf/provisioning/datasources/prometheus.yaml <<EOF
# # config file version
apiVersion: 1

deleteDatasources:
  - name: prometheus
    orgId: 1

datasources:
#   # <string, required> name of the datasource. Required
  - name: prometheus
    type: prometheus
    access: proxy
    orgId: 1
    url: http://$PROM_HOST:$PROM_PORT
    password:
    user:
    database:
    basicAuth:
    basicAuthUser:
    basicAuthPassword:
    withCredentials:
    isDefault: 1
    jsonData:
      graphiteVersion: "1.1"
      tlsAuth: false
      tlsAuthWithCACert: false
    #  httpHeaderName1: "Authorization"
    #secureJsonData:
    #  tlsCACert: "..."
    #  tlsClientCert: "..."
    #  tlsClientKey: "..."
    #  # <openshift\kubernetes token example>
    #  httpHeaderValue1: "Bearer xf5yhfkpsnmgo"
    version: 1
    # <bool> allow users to edit datasources from the UI.
    editable: true
EOF

cat > "$GRAF_DIR"/conf/provisioning/dashboards/cardano.yaml <<EOF
# # config file version
apiVersion: 1

providers:
 - name: 'Cardano Node'
   orgId: 1
   folder: ''
   folderUid: ''
   type: file
   options:
     path: $DASH_DIR
EOF


cat > "$SYSD_DIR"/prometheus.service <<EOF
[Unit]
Description=Prometheus Server
Documentation=https://prometheus.io/docs/introduction/overview/
After=network-online.target

[Service]
User=$(whoami)
Restart=on-failure
ExecStart=$PROM_DIR/prometheus \
  --config.file=$PROM_DIR/prometheus.yml \
  --storage.tsdb.path=$PROM_DIR/data --web.listen-address=$PROM_HOST:$PROM_PORT
WorkingDirectory=$PROM_DIR
LimitNOFILE=10000

[Install]
WantedBy=multi-user.target
EOF

cat > "$SYSD_DIR"/node_exporter.service <<EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=$(whoami)
Restart=on-failure
ExecStart=$NEXP_DIR/node_exporter --web.listen-address="$CNODE_IP:$NEXP_PORT"
WorkingDirectory=$NEXP_DIR
LimitNOFILE=3500

[Install]
WantedBy=default.target
EOF

cat > "$SYSD_DIR"/grafana-server.service <<EOF
[Unit]                                                                                          
Description=Grafana instance                                                                    
Documentation=http://docs.grafana.org                                                           
Wants=network-online.target                                                                     
After=network-online.target

[Service]
User=$(whoami)
Restart=on-failure
ExecStart=$GRAF_DIR/bin/grafana-server web
WorkingDirectory=$GRAF_DIR
LimitNOFILE=10000

[Install]
WantedBy=default.target
EOF

echo "Creating service files as root.."
sudo cp "$SYSD_DIR"/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start node_exporter prometheus grafana-server
sudo systemctl enable node_exporter prometheus grafana-server

echo -e "
=====================================================
Installation is completed
=====================================================

- Prometheus (default): http://$PROM_HOST:$PROM_PORT/metrics
    Node metrics:       http://$CNODE_IP:$CNODE_PORT
    Node exp metrics:   http://$CNODE_IP:$NEXP_PORT
- Grafana (default):    http://$GRAFANA_HOST:$GRAFANA_PORT


You need to do the following to configure grafana:
0. The services should already be started, verify if you can login to grafana, and prometheus. If using 127.0.0.1 as IP, you can check via curl
1. Login to grafana as admin/admin (http://$GRAFANA_HOST:$GRAFANA_PORT)
2. Add \"prometheus\" (all lowercase) datasource (http://$PROM_HOST:$PROM_PORT)
3. Create a new dashboard by importing dashboards (left plus sign).
  - Sometimes, the individual panel's \"prometheus\" datasource needs to be refreshed.

Enjoy...
" >&2

clean_up 0
