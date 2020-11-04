#!/bin/bash
echo "~~ cnode.sh ~~"
[[ -f /etc/systemd/system/cnode.service ]] && echo "systemd service already exist, overwrite? [y|n]" || echo "deploy as systemd service? [y|n]"
read -rsn1 yn
if [[ ${yn} = [Yy]* ]]; then
  sudo bash -c "cat << 'EOF' > /etc/systemd/system/cnode.service
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
SyslogIdentifier=cnode
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF"
fi

echo "~~ logMonitor.sh ~~"
[[ -f /etc/systemd/system/cnode_logmonitor.service ]] && echo "systemd service already exist, overwrite? [y|n]" || echo "deploy as systemd service? [y|n]"
read -rsn1 yn
if [[ ${yn} = [Yy]* ]]; then
  sudo bash -c "cat << 'EOF' > /etc/systemd/system/cnode_logmonitor.service
[Unit]
Description=Cardano Node - Log Monitor
Requires=cnode.service
After=cnode.service

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
SyslogIdentifier=cnode_logmonitor
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF"
fi

sudo systemctl daemon-reload
[[ -f /etc/systemd/system/cnode.service ]] && sudo systemctl enable cnode.service
[[ -f /etc/systemd/system/cnode_logmonitor.service ]] && sudo systemctl enable cnode_logmonitor.service
