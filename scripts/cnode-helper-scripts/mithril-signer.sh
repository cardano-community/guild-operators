#!/usr/bin/env bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

. "$(dirname $0)"/mithril.library

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#MITHRILBIN="${HOME}"/.local/bin/mithril-signer # Path for mithril-signer binary, if not in $PATH
#HOSTADDR=127.0.0.1                             # Default Listen IP/Hostname for Mithril Signer Server

######################################
# Do NOT modify code below           #
######################################

#####################
# Functions         #
#####################

usage() {
  cat <<-EOF
		
		Usage: $(basename "$0") [-d] [-D] [-e] [-k] [-r] [-s] [-u] [-h]
		A script to setup, run and verify Cardano Mithril Signer
		
		-d    Deploy mithril-signer as a systemd service
		-D    Run mithril-signer as a daemon
		-e    Update mithril environment file
		-k    Stop signer using SIGINT
		-r    Verify signer registration
		-s    Verify signer signature
		-u    Skip update check
		-h    Show this help text
		
		EOF
}

mithril_init() {
  [[ ! -f "${CNODE_HOME}"/mithril/mithril.env ]] && generate_environment_file
  for line in $(cat "${CNODE_HOME}"/mithril/mithril.env); do
    export "${line}"
  done
  # Move logs to archive
  [[ -d "${LOG_DIR}"/archive ]] || mkdir -p "${LOG_DIR}"/archive
  [[ -f "${LOG_DIR}"/$(basename "${0::-3}").log ]] && mv "${LOG_DIR}/$(basename "${0::-3}")".log "${LOG_DIR}"/archive/ ; touch "${LOG_DIR}/$(basename "${0::-3}")".log
}

deploy_systemd() {
  echo "Creating ${CNODE_VNAME}-$(basename "${0::-3}") systemd service environment file.."

  echo "Deploying ${CNODE_VNAME}-$(basename "${0::-3}") as systemd service.."
  sudo bash -c "cat <<-'EOF' > /etc/systemd/system/${CNODE_VNAME}-$(basename "${0::-3}").service
	[Unit]
	Description=Cardano Mithril signer service
	StartLimitIntervalSec=0
	Wants=network-online.target
	After=network-online.target
	BindsTo=${CNODE_VNAME}.service
	After=${CNODE_VNAME}.service
	
	[Service]
	Type=simple
	Restart=always
	RestartSec=60
	User=${USER}
	EnvironmentFile=${CNODE_HOME}/mithril/mithril.env
	ExecStart=/bin/bash -l -c \"exec ${HOME}/.local/bin/$(basename "${0::-3}") -vv\"
	KillSignal=SIGINT
	SuccessExitStatus=143
	StandardOutput=syslog
	StandardError=syslog
	SyslogIdentifier=${CNODE_VNAME}-$(basename "${0::-3}")
	TimeoutStopSec=5
	KillMode=mixed
	
	[Install]
	WantedBy=multi-user.target
	EOF" && echo "${CNODE_VNAME}-$(basename "${0::-3}").service deployed successfully!!" && sudo systemctl daemon-reload && sudo systemctl enable ${CNODE_VNAME}-"$(basename "${0::-3}")".service
}

stop_signer() {
  CNODE_PID=$(pgrep -fn "$(basename ${CNODEBIN}).*.--port ${CNODE_PORT}" 2>/dev/null) # env was only called in offline mode
  kill -2 ${CNODE_PID} 2>/dev/null
  # touch clean "${CNODE_HOME}"/db/clean # Disabled as it's a bit hacky, but only runs when SIGINT is passed to node process. Should not be needed if node does it's job
  echo "  Sending SIGINT to $(basename "${0::-3}") process.."
  sleep 5
  exit 0
}


user_interrupt_received() {
  echo "  SIGINT received, stopping $(basename "${0::-3}").." |tee -a "${LOG_DIR}/$(basename "${0::-3}")".log 2>&1
  stop_signer

}

verify_signer_registration() {
  set -e

  if [ -z "$AGGREGATOR_ENDPOINT" ] || [ -z "$PARTY_ID" ]; then
      echo ">> ERROR: Required environment variables AGGREGATOR_ENDPOINT and/or PARTY_ID are not set."
      exit 1
  fi

  CURRENT_EPOCH=$(curl -s "$AGGREGATOR_ENDPOINT/epoch-settings" -H 'accept: application/json' | jq -r '.epoch')
  SIGNERS_REGISTERED_RESPONSE=$(curl -s "$AGGREGATOR_ENDPOINT/signers/registered/$CURRENT_EPOCH" -H 'accept: application/json')

  if echo "$SIGNERS_REGISTERED_RESPONSE" | grep -q "$PARTY_ID"; then
      echo ">> Congrats, your signer node is registered!"
  else
      echo ">> Oops, your signer node is not registered. Party ID not found among the signers registered at epoch ${CURRENT_EPOCH}."
  fi

}

verify_signer_signature() {
  set -e

  if [ -z "$AGGREGATOR_ENDPOINT" ] || [ -z "$PARTY_ID" ]; then
      echo ">> ERROR: Required environment variables AGGREGATOR_ENDPOINT and/or PARTY_ID are not set."
      exit 1
  fi

  CERTIFICATES_RESPONSE=$(curl -s "$AGGREGATOR_ENDPOINT/certificates" -H 'accept: application/json')
  CERTIFICATES_COUNT=$(echo "$CERTIFICATES_RESPONSE" | jq '. | length')

  echo "$CERTIFICATES_RESPONSE" | jq -r '.[] | .hash' | while read -r HASH; do
      RESPONSE=$(curl -s "$AGGREGATOR_ENDPOINT/certificate/$HASH" -H 'accept: application/json')
      SIGNER_COUNT=$(echo "$RESPONSE" | jq '.metadata.signers | length')
      for (( i=0; i < SIGNER_COUNT; i++ )); do
          PARTY_ID_RESPONSE=$(echo "$RESPONSE" | jq -r ".metadata.signers[$i].party_id")
          if [[ "$PARTY_ID_RESPONSE" == "$PARTY_ID" ]]; then
              echo ">> Congrats, you have signed this certificate: $AGGREGATOR_ENDPOINT/certificate/$HASH !"
              exit 1
          fi
      done
  done

  echo ">> Oops, your party id was not found in the last ${CERTIFICATES_COUNT} certificates. Please try again later."

}


#####################
# Execution / Main  #
#####################

# Parse command line options
while getopts :dDekrsuh opt; do
  case ${opt} in
    d ) 
      DEPLOY_SYSTEMD="Y" ;;
    D )
      SIGNER_DAEMON="Y"
      ;;
    e ) 
      export UPDATE_ENVIRONMENT="Y"
      ;;
    k )
      STOP_SIGNER="Y"
      ;;
    r )
      VERIFY_REGISTRATION="Y"
      ;;
    s )
      VERIFY_SIGNATURE="Y"
      ;;
    u )
      export SKIP_UPDATE="Y"
      ;;
    h)
      usage
      exit 0
      ;;
    \?)
      echo "Invalid $(basename "$0") option: -${OPTARG}" >&2
      usage
      exit 1
      ;;
    :)
      echo "Option -${OPTARG} requires an argument." >&2
      usage
      exit 1
      ;;
  esac
done

[[ "${STOP_SIGNER}" == "Y" ]] && stop_signer

# Check for updates
update_check "$@"

# Set defaults and do basic sanity checks
set_defaults


#Deploy systemd if -d argument was specified
if [[ "${UPDATE_ENVIRONMENT}" == "Y" ]]; then
  generate_environment_file
  exit 0
else
  mithril_init
  if [[ "${DEPLOY_SYSTEMD}" == "Y" ]]; then
    if deploy_systemd ; then
      echo "Mithril signer Systemd service successfully deployed"
      exit 0
    else
      echo "Failed to deploy Mithril signer Systemd service"
      exit 2
    fi
  elif [[ "${VERIFY_REGISTRATION}" == "Y" ]]; then
    # Verify signer registration
    echo "Verifying Mithril Signer registration.."
    verify_signer_registration
    exit 0
  elif [[ "${VERIFY_SIGNATURE}" == "Y" ]]; then
    # Verify signer signature
    echo "Verifying Mithril Signer signature.."
    verify_signer_signature
    exit 0
  elif [[ "${SIGNER_DAEMON}" == "Y" ]]; then
    # Run Mithril Signer Server
    echo "Starting Mithril Signer Server.."
    trap 'user_interrupt_received' INT
    if ! "${MITHRILBIN}" -vv | tee -a "${LOG_DIR}/$(basename "${0::-3}")".log 2>&1 ; then
      echo "Failed to start Mithril Signer Server" | tee -a "${LOG_DIR}/$(basename "${0::-3}")".log 2>&1
      exit 1
    fi
  fi
fi