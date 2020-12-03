#!/bin/bash
# shellcheck disable=SC1090,SC2086

PARENT="$(dirname "$0")" 

if [[ $(grep "_HOME=" "${PARENT}"/env) =~ ^#?([^[:space:]]+)_HOME ]]; then
  vname=$(tr '[:upper:]' '[:lower:]' <<< "${BASH_REMATCH[1]}")
else
  echo "failed to get cnode instance name from env file, aborting!"
  exit 1
fi

. "${PARENT}"/env offline

echo -e "\e[32m~~ Cardano Node ~~\e[0m"
echo "launches the main cnode.sh script to start cardano-node"
echo
echo "automatically deployed!"
sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}.service
[Unit]
Description=Cardano Node
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
User=$USER
LimitNOFILE=1048576
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cnode.sh\"
ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep [c]ardano-node.*.${CNODE_HOME}/ | tr -s ' ' | cut -d ' ' -f2) &>/dev/null\"
KillSignal=SIGINT
SuccessExitStatus=143
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=${vname}
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF"

echo
echo -e "\e[32m~~ Topology Updater ~~\e[0m"
echo "An intermediate centralized solution for relay nodes to handle the static topology files until P2P network module is implemented on protocol level."
echo "A service file is deployed that once every 60 min send a message to API. After 4 consecutive successful requests (3 hours) the relay is accepted and available for others to fetch. If the node is turned off, it’s automatically delisted after 3 hours."
echo "For more info, visit https://cardano-community.github.io/guild-operators/#/Scripts/topologyupdater"
echo
echo "Deploy Topology Updater as systemd services? (only for relay nodes) [y|n]"
read -rsn1 yn
if [[ ${yn} = [Yy]* ]]; then
  sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-tu-push.service
[Unit]
Description=Cardano Node - Topology Updater - node alive push

[Service]
Type=oneshot
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/topologyUpdater.sh -f\"
StandardOutput=syslog
StandardError=syslog
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
StandardOutput=syslog
StandardError=syslog
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
StandardOutput=syslog
StandardError=syslog
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
  if [[ -f /etc/systemd/system/${vname}-tu-fetch.service ]]; then
    sudo systemctl disable ${vname}-tu-fetch.service
    sudo rm -f /etc/systemd/system/${vname}-tu-fetch.service
  fi
  if [[ -f /etc/systemd/system/${vname}-tu-push.timer ]]; then
    sudo systemctl disable ${vname}-tu-push.timer
    sudo rm -f /etc/systemd/system/${vname}-tu-push.timer
  fi
  if [[ -f /etc/systemd/system/${vname}-tu-push.service ]]; then
    sudo rm -f /etc/systemd/system/${vname}-tu-push.service
  fi
  if [[ -f /etc/systemd/system/${vname}-tu-restart.timer ]]; then
    sudo systemctl disable ${vname}-tu-restart.timer
    sudo rm -f /etc/systemd/system/${vname}-tu-restart.timer
  fi
  if [[ -f /etc/systemd/system/${vname}-tu-restart.service ]]; then
    sudo rm -f /etc/systemd/system/${vname}-tu-restart.service
  fi
fi

echo
echo -e "\e[32m~~ Blocklog / PoolTool SendSlots ~~\e[0m"
echo "A collection of services that together creates a blocklog of current and upcoming blocks"
echo "Dependant on ${vname}.service and when started|stopped|restarted all these companion services will apply the same action"
echo "${vname}-cncli-sync        : Start CNCLI chainsync process that connects to cardano-node to sync blocks stored in SQLite DB"
echo "${vname}-cncli-leaderlog   : Loops through all slots in current epoch to calculate leader schedule"
echo "${vname}-cncli-validate    : Confirms that the block made actually was accepted and adopted by chain"
echo -e "${vname}-cncli-ptsendslots : Securely sends PoolTool the number of slots you have assigned for an epoch and validates the correctness of your past epochs (\e[36moptional\e[0m)"
echo -e "${vname}-logmonitor        : Parses JSON log of cardano-node for traces of interest to give instant adopted status and invalid status (\e[36moptional\e[0m)"
echo
if command -v "${CNCLI}" >/dev/null; then
  echo "Deploy Blocklog as systemd services? [y|n]"
  read -rsn1 yn
  if [[ ${yn} = [Yy]* ]]; then
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
StandardOutput=syslog
StandardError=syslog
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
StandardOutput=syslog
StandardError=syslog
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
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=${vname}-cncli-validate
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=${vname}-cncli-sync.service
EOF"
    echo
    echo -e "\e[32m~~ PoolTool SendSlots ~~\e[0m"
    echo "Securely sends pooltool the number of slots you have assigned for an epoch and validates the correctness of your past epochs"
    echo
    if command -v "${CNCLI}" >/dev/null; then
      echo "Deploy PoolTool SendSlots as systemd services? [y|n]"
      read -rsn1 yn
      if [[ ${yn} = [Yy]* ]]; then
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
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=${vname}-cncli-ptsendslots
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=${vname}-cncli-sync.service
EOF"
      else
        if [[ -f /etc/systemd/system/${vname}-cncli-ptsendslots.service ]]; then
          sudo systemctl disable ${vname}-cncli-ptsendslots.service
          sudo rm -f /etc/systemd/system/${vname}-cncli-ptsendslots.service
        fi
      fi
    else
      echo "cncli executable not found... skipping!"
    fi
    echo
    echo -e "\e[32m~~ Log Monitor ~~\e[0m"
    echo "Parses JSON log of cardano-node for traces of interest to give instant adopted status and invalid status"
    echo "Optional to use, blocklog will function but without above mentioned features"
    echo
    echo "Deploy Log Monitor as systemd services? [y|n]"
    read -rsn1 yn
    if [[ ${yn} = [Yy]* ]]; then
      sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-logmonitor.service
[Unit]
Description=Cardano Node - Log Monitor
BindsTo=${vname}.service
After=${vname}.service

[Service]
Type=simple
Restart=on-failure
RestartSec=20
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/logMonitor.sh\"
ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep -m1 ${CNODE_HOME}/scripts/logMonitor.sh | tr -s ' ' | cut -d ' ' -f2) &>/dev/null\"
KillSignal=SIGINT
SuccessExitStatus=143
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=${vname}-logmonitor
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=${vname}.service
EOF"
    else
      if [[ -f /etc/systemd/system/${vname}-logmonitor.service ]]; then
        sudo systemctl disable ${vname}-logmonitor.service
        sudo rm -f /etc/systemd/system/${vname}-logmonitor.service
      fi
    fi
  else
    if [[ -f /etc/systemd/system/${vname}-cncli-sync.service ]]; then
      sudo systemctl disable ${vname}-cncli-sync.service
      sudo rm -f /etc/systemd/system/${vname}-cncli-sync.service
    fi
    if [[ -f /etc/systemd/system/${vname}-cncli-leaderlog.service ]]; then
      sudo systemctl disable ${vname}-cncli-leaderlog.service
      sudo rm -f /etc/systemd/system/${vname}-cncli-leaderlog.service
    fi
    if [[ -f /etc/systemd/system/${vname}-cncli-validate.service ]]; then
      sudo systemctl disable ${vname}-cncli-validate.service
      sudo rm -f /etc/systemd/system/${vname}-cncli-validate.service
    fi
    if [[ -f /etc/systemd/system/${vname}-cncli-ptsendslots.service ]]; then
      sudo systemctl disable ${vname}-cncli-ptsendslots.service
      sudo rm -f /etc/systemd/system/${vname}-cncli-ptsendslots.service
    fi
    if [[ -f /etc/systemd/system/${vname}-logmonitor.service ]]; then
      sudo systemctl disable ${vname}-logmonitor.service
      sudo rm -f /etc/systemd/system/${vname}-logmonitor.service
    fi
  fi
else
  echo "cncli executable not found... skipping!"
fi


echo
echo -e "\e[32m~~ PoolTool SendTip ~~\e[0m"
echo "Countinously sends node tip to PoolTool for network analysis and to show that your node is alive and well with a green badge"
echo "Dependant on ${vname}.service and when started|stopped|restarted ptsendtip services will apply the same action"
echo
if command -v "${CNCLI}" >/dev/null; then
  echo "Deploy PoolTool SendTip as systemd services? [y|n]"
  read -rsn1 yn
  if [[ ${yn} = [Yy]* ]]; then
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
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=${vname}-cncli-ptsendtip
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=${vname}.service
EOF"
  else
    if [[ -f /etc/systemd/system/${vname}-cncli-ptsendtip.service ]]; then
      sudo systemctl disable ${vname}-cncli-ptsendtip.service
      sudo rm -f /etc/systemd/system/${vname}-cncli-ptsendtip.service
    fi
  fi
else
  echo "cncli executable not found... skipping!"
fi


echo
sudo systemctl daemon-reload
[[ -f /etc/systemd/system/${vname}.service ]] && sudo systemctl enable ${vname}.service
[[ -f /etc/systemd/system/${vname}-logmonitor.service ]] && sudo systemctl enable ${vname}-logmonitor.service
[[ -f /etc/systemd/system/${vname}-tu-fetch.service ]] && sudo systemctl enable ${vname}-tu-fetch.service
[[ -f /etc/systemd/system/${vname}-tu-restart.timer ]] && sudo systemctl enable ${vname}-tu-restart.timer
[[ -f /etc/systemd/system/${vname}-tu-push.timer ]] && sudo systemctl enable ${vname}-tu-push.timer
[[ -f /etc/systemd/system/${vname}-cncli-sync.service ]] && sudo systemctl enable ${vname}-cncli-sync.service
[[ -f /etc/systemd/system/${vname}-cncli-leaderlog.service ]] && sudo systemctl enable ${vname}-cncli-leaderlog.service
[[ -f /etc/systemd/system/${vname}-cncli-validate.service ]] && sudo systemctl enable ${vname}-cncli-validate.service
[[ -f /etc/systemd/system/${vname}-cncli-ptsendtip.service ]] && sudo systemctl enable ${vname}-cncli-ptsendtip.service
[[ -f /etc/systemd/system/${vname}-cncli-ptsendslots.service ]] && sudo systemctl enable ${vname}-cncli-ptsendslots.service


echo
echo "If not done already, update 'User Variables' section in relevant script in ${CNODE_HOME}/scripts/ folder"
echo -e "E.g \e[36menv\e[0m, \e[36mcnode.sh\e[0m, \e[36mcncli.sh\e[0m, \e[36mgLiveView.sh\e[0m, \e[36mtopologyUpdater.sh\e[0m"
echo -e "You can then start/restart the node with \e[32msudo systemctl restart ${vname}\e[0m"
echo "This will automatically start all installed companion services due to service dependency"
echo
