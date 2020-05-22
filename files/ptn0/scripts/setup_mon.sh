#!/bin/bash
#---------------------------------------------------------------------
# File:    setup_shelley_monitoring.sh
# Created: 2019/10/17
# Creator: ilap
#=====================================================================
# UPDATES:
# - 21/05/2020: Updated to the `cardano-node` i.e. Haskell Shelley
#
# DESCRIPTION:
#
# This script downloads and configures the required files 
# for monitoring a Shelley node by using grafana/prometheus.
#

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

######################################################################
#### MAIN
######################################################################

# shellcheck disable=SC2209
DBG=echo
unset DBG # For debug only

PROM_VER=2.18.1
GRAF_VER=7.0.0
NEXP_VER=0.18.1

CURL=$(command -v curl)
WGET=$(command -v wget)

DL=${CURL:=$WGET}

if [ -z "$1" ] ; then
    message "usage: $(basename "$0") <full path>\nExample: $(basename "$0") /opt/cardano/monitoring"
fi

if  [ -z "$DL" ]; then
    message 'You need to have "wget" or "curl" to be installed\nand accessable by PATH environment to continue...\nExiting.'
fi

PROJ_DIR=$(dirname "$1")
PROJ_NAME=$(basename "$1")
PROJ_PATH="$PROJ_DIR/$PROJ_NAME"

if [ -e "$PROJ_PATH" ]; then
    message "The \"$PROJ_PATH\" directory exist pls move or delete it.\nExiting."
fi

TMP_DIR=$(mktemp -d "/tmp/$PROJ_NAME.XXXXXXXX")

# Default parameters
IP=127.0.0.1
PORT=9001
export IP PORT TMP_DIR

while :
do
    echo "Please use hasPrometeus's IP:PORT from node's config file."
    echo "The files will be installed in the \"$PROJ_PATH\" directory."
    read -rp "What is the ip of the node (default:${IP})? " ip
    read -rp "What port is used for prometheus metrics of the node running on ${IP:="${ip}"}'s (Default is ${PORT})?" port
    echo "Is this correct? http://${ip:-"${IP}"}:${port:-"${PORT}"}/metrics"
    read -rp "Do you want to continue? [Y/n/q] " answer
    
    case ${answer:="Y"} in
        [yY]*)
            IP=${ip:-"${IP}"}
            PORT=${port:-"${PORT}"}
            break;;
        [nN]* )
            continue;;
        [qQ]* )
            exit;;
        * )
            echo "Please enter [yY](es), [nN](o) or [qQ](quit).";;
    esac
done

ARCHS=("darwin-amd64" "linux-amd64"  "linux-armv6")
IDX=$(get_idx)

PROM_URL="https://github.com/prometheus/prometheus/releases/download/v$PROM_VER/prometheus-$PROM_VER.${ARCHS[IDX]}.tar.gz"

GRAF_URL="https://dl.grafana.com/oss/release/grafana-$GRAF_VER.${ARCHS[IDX]}.tar.gz"

NEXP="node_exporter"
NEXP_URL="https://github.com/prometheus/$NEXP/releases/download/v$NEXP_VER/$NEXP-$NEXP_VER.${ARCHS[IDX]}.tar.gz"

UMED_DB="Haskel_Node_SKY_Relay1_Dash.json"
UMED_DB_URL="https://raw.githubusercontent.com/Oqulent/SkyLight-Pool/master/$UMED_DB"

IOHK_DB="cardano-application-dashboard-v2.json"
IOHK_DB_URL="https://raw.githubusercontent.com/input-output-hk/cardano-ops/master/modules/grafana/cardano/$IOHK_DB"

trap clean_up  SIGHUP SIGINT SIGQUIT SIGTRAP SIGABRT SIGTERM

echo ""
echo -e "Downloading prometheus v$PROM_VER..." >&2
$DBG dl "$PROM_URL"

echo -e "Downloading grafana v$GRAF_VER..." >&2
$DBG dl "$GRAF_URL"

echo -e "Downloading exporter v$NEXP_VER..." >&2
$DBG dl "$NEXP_URL"

echo -e "Downloading grafana dashboard(s)..." >&2

echo -e "  - $UMED_DB" >&2
$DBG dl "$UMED_DB_URL"

echo -e "  - $IOHK_DB" >&2
$DBG dl "$IOHK_DB_URL"

echo ""

PROM_DIR="$PROJ_DIR/prometheus"
GRAF_DIR="$PROJ_DIR/grafana"
NEXP_DIR="$PROJ_DIR/exporters"
DASH_DIR="$PROJ_DIR/dashboards"

mkdir -p "$PROM_DIR" "$GRAF_DIR" "$NEXP_DIR" "$DASH_DIR"

tar zxC "$PROM_DIR" -f "$TMP_DIR"/*prome*gz --strip-components 1
tar zxC "$GRAF_DIR" -f "$TMP_DIR"/*graf*gz --strip-components 1
tar zxC "$NEXP_DIR" -f "$TMP_DIR"/*node_exporter*gz "$NEXP-$NEXP_VER.${ARCHS[IDX]}/$NEXP" --strip-components 1

echo -e "Configuring components" >&2

chmod +x "$NEXP_DIR"/*
cp -pr "$TMP_DIR/$UMED_DB" "$DASH_DIR/"
cp -pr "$TMP_DIR/$IOHK_DB" "$DASH_DIR/"

NEXP_PORT=$(( PORT + 1 ))
HOSTNAME=$(hostname)

sed -i -e "s#\(^scrape_configs:.*\)#\1\n\
  - job_name: '${HOSTNAME}_node'\n\
    static_configs:\n\
    - targets: ['$IP:$PORT']\n\
  - job_name: '${HOSTNAME}_node_exp'\n\
    static_configs:\n\
    - targets: ['$IP:$NEXP_PORT']#g"  "$PROM_DIR"/prometheus.yml

cat > start_all.sh <<EOF
#!/bin/bash

	#1. exporter
	"$PROJ_PATH/exporters/node_exporter" --web.listen-address="$IP:$NEXP_PORT" &
	sleep 3

	#2. Prometheus
	"$PROM_DIR/prometheus" --config.file="$PROM_DIR/prometheus.yml" &
	sleep 3

	#3. Grafana
	#vi "$GRAF_DIR/conf/defaults.ini"
	cd "$GRAF_DIR"
	./bin/grafana-server web
EOF

chmod a+rx start_all.sh

echo -e "

=====================================================
Installation is completed
=====================================================

- Prometheus (default): http://localhost:9090/metrics
    Node metrics:       http://$IP:$PORT
    Node exp metrics:   http://$IP:$NEXP_PORT
- Grafana (default):    http://localhost:3000


You need to do the following to configure grafana:
0. Start the required services in a new terminal by \"$PROJ_DIR/start_all.sh\"
  - check the prometheus and its exporters by opening URLs above after start.
1. Login to grafana as admin/admin (http://localhost:3000)
2. Add \"prometheus\" (all lowercase) datasource (http://localhost:9090)
3. Create a new dashboard by importing dashboards (left plus sign).
  - Sometimes, the individual panel's \"prometheus\" datasource needs to be refreshed.

Enjoy...
" >&2

clean_up 0

