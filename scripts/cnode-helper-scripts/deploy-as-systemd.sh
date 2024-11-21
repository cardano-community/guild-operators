#!/usr/bin/env bash

# shellcheck disable=SC1090,SC2086

######################################
# Do NOT modify code below           #
######################################

PARENT="$(dirname "$0")" 

. "${PARENT}"/env offline

vname="${CNODE_VNAME}"

removeService() {
  [[ -z $1 || ! -f "/etc/systemd/system/$1" ]] && return
  sudo systemctl disable "$1" >/dev/null
  sudo rm -f "/etc/systemd/system/$1" >/dev/null
}

echo -e "\n${FG_GREEN}~~ Cardano Node ~~${NC}\n"
getAnswer "Deploy service?" && ./cnode.sh -d

if grep -q "^PGPASSFILE=" "${CNODE_HOME}/scripts/dbsync.sh" 2> /dev/null || [[ -f "${CNODE_HOME}/priv/.pgpass" ]]; then
  echo -e "\n${FG_GREEN}~~ Cardano DB Sync ~~${NC}\n"
  getAnswer "Deploy service?" && ./dbsync.sh -d || removeService "${vname}-dbsync.service"
fi

echo -e "\n${FG_GREEN}~~ Cardano Submit API ~~${NC}\n"
getAnswer "Deploy service?" && ./submitapi.sh -d || removeService "${vname}-submitapi.service"

if command -v mithril-signer >/dev/null 2>&1; then
  echo -e "\n${FG_GREEN}~~ Mithril Signer ~~${NC}\n"
  getAnswer "Deploy service?" && ./mithril-signer.sh -d || removeService "${vname}-mithril-signer.service"
fi

if command -v ogmios >/dev/null 2>&1; then
  echo -e "\n${FG_GREEN}~~ Cardano Ogmios Server ~~${NC}\n"
  getAnswer "Deploy service?" && ./ogmios.sh -d || removeService "${vname}-ogmios.service"
fi

echo -e "\n${FG_GREEN}~~ Topology Updater ~~${NC}"
echo "An intermediate centralized solution for relay nodes to handle the static topology files until P2P network module is implemented on protocol level."
echo "A service file is deployed that once every 60 min send a message to API. After 4 consecutive successful requests (3 hours) the relay is accepted and available for others to fetch. If the node is turned off, it’s automatically delisted after 3 hours."
echo "For more info, visit https://cardano-community.github.io/guild-operators/Scripts/topologyupdater"
echo
if getAnswer "Deploy services? (only for relay nodes)"; then
  sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-tu-push.service
[Unit]
Description=Cardano Node - Topology Updater - node alive push

[Service]
Type=oneshot
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/topologyUpdater.sh -f\"
SyslogIdentifier=${vname}-tu-push
EOF"
  sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-tu-push.timer
[Unit]
Description=Cardano Node - Wake Topology Updater node aline push service once an hour
BindsTo=${vname}.service

[Timer]
OnActiveSec=1h
OnUnitInactiveSec=1h
AccuracySec=1s

[Install]
WantedBy=timers.target ${vname}.service
EOF"
  echo "At what interval do you want to restart the relay node to fetch and load a fresh topology file?"
  read -r -p "Enter interval in seconds, blank for default: 1 day (86400s): " interval
  : "${interval:=86400}"
  sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-tu-fetch.service
[Unit]
Description=Cardano Node - Topology Updater - fetches a fresh topology before ${vname}.service start
BindsTo=${vname}.service
Before=${vname}.service

[Service]
Type=oneshot
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/topologyUpdater.sh -p\"
ExecStartPost=/bin/sleep 5
SyslogIdentifier=${vname}-tu-fetch

[Install]
WantedBy=${vname}.service
EOF"
  sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-tu-restart.service
[Unit]
Description=Cardano Node - Topology Updater - restart ${vname}.service for topology update

[Service]
Type=oneshot
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -c \"/bin/systemctl try-restart ${vname}.service 2>/dev/null || /usr/bin/systemctl try-restart ${vname}.service 2>/dev/null\"
SyslogIdentifier=${vname}-tu-restart
EOF"
  sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-tu-restart.timer
[Unit]
Description=Cardano Node - Wake Topology Updater restart service at set interval
BindsTo=${vname}.service

[Timer]
OnActiveSec=${interval}
OnUnitInactiveSec=${interval}
AccuracySec=1s

[Install]
WantedBy=timers.target ${vname}.service
EOF"
else
  removeService ${vname}-tu-fetch.service
  removeService ${vname}-tu-push.timer
  removeService ${vname}-tu-push.service
  removeService ${vname}-tu-restart.timer
  removeService ${vname}-tu-restart.service
fi

if command -v cncli >/dev/null 2>&1; then
  echo -e "${FG_GREEN}~~ CNCLI ~~${NC}"
  echo "A collection of services that together creates a blocklog of current and upcoming blocks"
  echo "Dependant on ${vname}.service and when started|stopped|restarted all these companion services will apply the same action"
  echo "${vname}-cncli-sync        : Start CNCLI chainsync process that connects to cardano-node to sync blocks stored in SQLite DB"
  echo "${vname}-cncli-leaderlog   : Loops through all slots in current epoch to calculate leader schedule"
  echo "${vname}-cncli-validate    : Confirms that the block made actually was accepted and adopted by chain"
  echo
  if getAnswer "Deploy services?"; then
    sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-cncli-sync.service
[Unit]
Description=Cardano Node - CNCLI Sync
BindsTo=${vname}.service
After=${vname}.service
[Service]
Type=simple
Restart=on-failure
RestartSec=20
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cncli.sh sync\"
ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep [c]ncli.sync.*.${CNODE_HOME}/ | tr -s ' ' | cut -d ' ' -f2) &>/dev/null\"
KillSignal=SIGINT
SuccessExitStatus=143
SyslogIdentifier=${vname}-cncli-sync
TimeoutStopSec=5
KillMode=mixed
[Install]
WantedBy=${vname}.service
EOF"
    sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-cncli-leaderlog.service
[Unit]
Description=Cardano Node - CNCLI Leaderlog
BindsTo=${vname}-cncli-sync.service
After=${vname}-cncli-sync.service

[Service]
Type=simple
Restart=on-failure
RestartSec=20
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cncli.sh leaderlog\"
SuccessExitStatus=143
SyslogIdentifier=${vname}-cncli-leaderlog
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=${vname}-cncli-sync.service
EOF"
    sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-cncli-validate.service
[Unit]
Description=Cardano Node - CNCLI Validate
BindsTo=${vname}-cncli-sync.service
After=${vname}-cncli-sync.service

[Service]
Type=simple
Restart=on-failure
RestartSec=20
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStartPre=/bin/sleep 5
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cncli.sh validate\"
SuccessExitStatus=143
SyslogIdentifier=${vname}-cncli-validate
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=${vname}-cncli-sync.service
EOF"
    echo -e "\n${FG_GREEN}~~ PoolTool SendSlots ~~${NC}"
    echo "Securely sends pooltool the number of slots you have assigned for an epoch and validates the correctness of your past epochs"
    echo
    if getAnswer "Deploy service?"; then
      sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-cncli-ptsendslots.service
[Unit]
Description=Cardano Node - CNCLI PoolTool SendSlots
BindsTo=${vname}-cncli-sync.service
After=${vname}-cncli-sync.service

[Service]
Type=simple
Restart=on-failure
RestartSec=20
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cncli.sh ptsendslots\"
ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep [c]ncli.sendslots.*.${vname}-pooltool.json | tr -s ' ' | cut -d ' ' -f2) &>/dev/null\"
KillSignal=SIGINT
SuccessExitStatus=143
SyslogIdentifier=${vname}-cncli-ptsendslots
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=${vname}-cncli-sync.service
EOF"
    else
      removeService ${vname}-cncli-ptsendslots.service
    fi
  else
    removeService ${vname}-cncli-sync.service
    removeService ${vname}-cncli-leaderlog.service
    removeService ${vname}-cncli-validate.service
    removeService ${vname}-cncli-ptsendslots.service
  fi
  echo -e "\n${FG_GREEN}~~ PoolTool SendTip ~~${NC}"
  echo "Countinously sends node tip to PoolTool for network analysis and to show that your node is alive and well with a green badge"
  echo "Dependant on ${vname}.service and when started|stopped|restarted ptsendtip services will apply the same action"
  echo
  if getAnswer "Deploy service?"; then
    sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-cncli-ptsendtip.service
[Unit]
Description=Cardano Node - CNCLI PoolTool SendTip
BindsTo=${vname}.service
After=${vname}.service

[Service]
Type=simple
Restart=on-failure
RestartSec=20
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cncli.sh ptsendtip\"
ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep [c]ncli.sendtip.*.${vname}-pooltool.json | tr -s ' ' | cut -d ' ' -f2) &>/dev/null\"
KillSignal=SIGINT
SuccessExitStatus=143
SyslogIdentifier=${vname}-cncli-ptsendtip
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=${vname}.service
EOF"
  else
    removeService ${vname}-cncli-ptsendtip.service
  fi
fi

echo -e "\n${FG_GREEN}~~ Log Monitor ~~${NC}"
echo "Parses JSON log of cardano-node for traces of interest to give instant adopted status and invalid status"
echo "Optional to use, often used as a complement to CNCLI services but functions on its own"
echo
if getAnswer "Deploy service?"; then
  sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-logmonitor.service
[Unit]
Description=Cardano Node - Log Monitor
BindsTo=${vname}.service
After=${vname}.service

[Service]
Type=simple
Restart=on-failure
RestartSec=1
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/logMonitor.sh\"
ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep -m1 ${CNODE_HOME}/scripts/logMonitor.sh | tr -s ' ' | cut -d ' ' -f2) &>/dev/null\"
KillSignal=SIGINT
SuccessExitStatus=143
SyslogIdentifier=${vname}-logmonitor
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=${vname}.service
EOF"
else
  removeService ${vname}-logmonitor.service
fi

echo -e "\n${FG_GREEN}~~ BlockPerf / Propagation performance ~~${NC}"
echo "A service parsing the node block propagation times from announced header to adopted block"
echo "sends block propagation time data to TopologyUpdater for common network analysis and performance comparison"
echo "${vname}-tu-blockperf          : Parses JSON log of cardano-node for block network propagation times"
echo
getAnswer "Deploy service?" && ./blockPerf.sh -d || removeService "${vname}-tu-blockperf.service"

sudo systemctl daemon-reload
[[ -f /etc/systemd/system/${vname}-logmonitor.service ]] && sudo systemctl enable ${vname}-logmonitor.service
[[ -f /etc/systemd/system/${vname}-tu-fetch.service ]] && sudo systemctl enable ${vname}-tu-fetch.service
[[ -f /etc/systemd/system/${vname}-tu-restart.timer ]] && sudo systemctl enable ${vname}-tu-restart.timer
[[ -f /etc/systemd/system/${vname}-tu-push.timer ]] && sudo systemctl enable ${vname}-tu-push.timer
[[ -f /etc/systemd/system/${vname}-tu-blockperf.service ]] && sudo systemctl enable ${vname}-tu-blockperf.service
[[ -f /etc/systemd/system/${vname}-cncli-sync.service ]] && sudo systemctl enable ${vname}-cncli-sync.service
[[ -f /etc/systemd/system/${vname}-cncli-leaderlog.service ]] && sudo systemctl enable ${vname}-cncli-leaderlog.service
[[ -f /etc/systemd/system/${vname}-cncli-validate.service ]] && sudo systemctl enable ${vname}-cncli-validate.service
[[ -f /etc/systemd/system/${vname}-cncli-ptsendtip.service ]] && sudo systemctl enable ${vname}-cncli-ptsendtip.service
[[ -f /etc/systemd/system/${vname}-cncli-ptsendslots.service ]] && sudo systemctl enable ${vname}-cncli-ptsendslots.service
[[ -f /etc/systemd/system/${vname}-mithril-signer.service ]] && sudo systemctl enable ${vname}-mithril-signer.service

echo
echo "If not done already, update 'User Variables' section in relevant script in ${CNODE_HOME}/scripts/ folder"
echo -e "E.g ${FG_CYAN}env${NC}, ${FG_CYAN}cnode.sh${NC}, ${FG_CYAN}cncli.sh${NC}, ${FG_CYAN}gLiveView.sh${NC}, ${FG_CYAN}topologyUpdater.sh${NC}"
echo -e "You can then start/restart the node with ${FG_GREEN}sudo systemctl restart ${vname}${NC}"
echo "This will automatically start all installed companion services due to service dependency"
echo
