#!/bin/bash
# shellcheck disable=SC1090

vname=%vname%

. "$(dirname "$0")"/env &>/dev/null # ignore any error

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
Restart=on-failure
RestartSec=5
User=$USER
LimitNOFILE=1048576
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cnode.sh\"
ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep [c]ardano-node.*.${CNODE_HOME}/ | tr -s ' ' | cut -d ' ' -f2)\"
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
echo -e "\e[32m~~ Blocklog ~~\e[0m"
echo "A collection of services that together creates a blocklog of current and upcoming blocks"
echo "Dependant on ${vname}.service and when started|stopped|restarted all these companion services will apply the same action"
echo "logmonitor      : parses JSON log of cardano-node for traces of interest"
echo "cncli-sync      : Start CNCLI chainsync process that connects to cardano-node to sync blocks stored in SQLite DB"
echo "cncli-leaderlog : Loops through all slots in current epoch to calculate leader schedule"
echo "cncli-validate  : Confirms that the block made actually was accepted and adopted by chain"
echo
if command -v "${CNCLI}" >/dev/null; then
  echo "deploy as systemd services? [y|n]"
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
RestartSec=5
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/logMonitor.sh\"
ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep -m1 ${CNODE_HOME}/scripts/logMonitor.sh | tr -s ' ' | cut -d ' ' -f2)\"
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
    sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-cncli-sync.service
[Unit]
Description=Cardano Node - CNCLI Sync
BindsTo=${vname}.service
After=${vname}.service

[Service]
Type=simple
Restart=on-failure
RestartSec=5
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cncli.sh sync\"
ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep [c]ncli.sync.*.${CNODE_HOME}/ | tr -s ' ' | cut -d ' ' -f2)\"
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
RestartSec=5
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
RestartSec=5
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
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
  else
    if [[ -f /etc/systemd/system/${vname}-logmonitor.service ]]; then
      sudo systemctl disable ${vname}-logmonitor.service
      sudo rm -f /etc/systemd/system/${vname}-logmonitor.service
    fi
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
  fi
else
  echo "cncli executable not found... skipping!"
fi

echo
echo -e "\e[32m~~ PoolTool SendTip ~~\e[0m"
echo "Send node tip to PoolTool for network analysis and to show that your node is alive and well with a green badge"
echo "Dependant on ${vname}.service and when started|stopped|restarted ptsendtip services will apply the same action"
echo
if command -v "${CNCLI}" >/dev/null; then
  echo "deploy as systemd services? [y|n]"
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
RestartSec=5
User=$USER
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cncli.sh sendtip\"
ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep [c]ncli.sendtip.*.${vname}-ptsendtip.json | tr -s ' ' | cut -d ' ' -f2)\"
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

sudo systemctl daemon-reload
echo
[[ -f /etc/systemd/system/${vname}.service ]] && sudo systemctl enable ${vname}.service
[[ -f /etc/systemd/system/${vname}-logmonitor.service ]] && sudo systemctl enable ${vname}-logmonitor.service
[[ -f /etc/systemd/system/${vname}-cncli-sync.service ]] && sudo systemctl enable ${vname}-cncli-sync.service
[[ -f /etc/systemd/system/${vname}-cncli-leaderlog.service ]] && sudo systemctl enable ${vname}-cncli-leaderlog.service
[[ -f /etc/systemd/system/${vname}-cncli-validate.service ]] && sudo systemctl enable ${vname}-cncli-validate.service
[[ -f /etc/systemd/system/${vname}-cncli-ptsendtip.service ]] && sudo systemctl enable ${vname}-cncli-ptsendtip.service

echo
echo "If not done already, update 'User Variables' section in each script (env, cnode.sh, cncli.sh, logMonitor.sh)"
echo -e "You can then start/restart the node with \e[32msudo systemctl restart ${vname}\e[0m"
echo "This will automatically start all installed companion services due to service dependency"
echo
