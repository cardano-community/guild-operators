#!/bin/bash
#shellcheck source=/dev/null

dirs -c

echo "~ Installing CNCLI with dependencies ~"
# install rust if not available
if ! command -v "rustup" &>/dev/null; then
  echo "installing RUST..."
  if ! output=$(curl https://sh.rustup.rs -sSf | sh -s -- -y 2>&1); then echo -e "${output}" && exit 1; fi
else
  echo "updating rustup if needed..."
  rustup update &>/dev/null #ignore any errors, not crucial that update succeed
fi

[[ -d "${HOME}"/git ]] || mkdir -p "${HOME}"/git
pushd "${HOME}"/git >/dev/null || exit 1

if [[ -d ./cncli ]]; then
  echo "previous cncli installation found, updating and building latest..."
  pushd ./cncli >/dev/null || exit 1
  if ! output=$(git pull 2>&1); then echo -e "${output}" && exit 1; fi
else
  echo "downloading and building cncli..."
  if ! output=$(git clone https://github.com/AndrewWestberg/cncli.git 2>&1); then echo -e "${output}" && exit 1; fi
  pushd ./cncli >/dev/null || exit 1
fi
if ! output=$(cargo install --path . --force 2>&1); then echo -e "${output}" && exit 1; fi

. "${HOME}"/.profile # source profile to load ${HOME}/.cargo/bin into PATH

pushd -0 >/dev/null && dirs -c

PARENT="$(dirname "$0")"
if [[ $(grep "_HOME=" "${PARENT}"/env) =~ ^#?([^[:space:]]+)_HOME ]]; then
  vname=$(tr '[:upper:]' '[:lower:]' <<< "${BASH_REMATCH[1]}")
else
  echo "failed to get cnode instance name from env file, aborting!"
  exit 1
fi

if [[ ! -f "/etc/systemd/system/${vname}-cncli.service" ]]; then
  echo "deploying systemd ${vname}-cncli.service file"
  sudo bash -c "cat << 'EOF' > /etc/systemd/system/${vname}-cncli.service
[Unit]
Description=Cardano Node - CNCLI
Requires=${vname}.service
After=${vname}.service

[Service]
Type=simple
Restart=on-failure
RestartSec=5
User=$USER
LimitNOFILE=1048576
WorkingDirectory=${CNODE_HOME}/scripts
ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/cncli.sh\"
ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep [c]ncli.*.${CNODE_HOME}/ | tr -s ' ' | cut -d ' ' -f2)\"
KillSignal=SIGINT
SuccessExitStatus=143
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=${vname}-cncli
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF"
else
  echo "${vname}-cncli.service already deployed, skipping!"
fi

sudo systemctl daemon-reload
sudo systemctl enable "${vname}"-cncli.service &>/dev/null

echo -e "\n$(cncli -V) installed!"