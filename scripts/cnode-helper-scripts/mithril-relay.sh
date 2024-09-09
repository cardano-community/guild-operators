#!/bin/bash
# shellcheck disable=SC2086,SC2034
#shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

RELAY_LISTENING_PORT=3132

######################################
# Do NOT modify code below           #
######################################

#####################
# Constants         #
#####################

ADDITIONAL_ALLOWED_IP=()
BLOCK_PRODUCER_IP=()
RELAY_LISTENING_IP=()

#####################
# Functions         #
#####################

# Usage menu
usage() {
  cat <<-EOF
		
		$(basename "$0") [-d] [-l] [-u] [-h]
		A script to setup Cardano Mithril relays
		
		-d  Install squid and configure as a relay
		-l  Install nginx and configure as a load balancer
		-u  Skip update check
		-h  Show this help text
		
		EOF
}


#####################
# Execution/Main    #
#####################

function main() {
  # Parse command line arguments
  while getopts :dlsuh opt; do
    case ${opt} in
      d)
        INSTALL_SQUID_PROXY=Y
        ;;
      l)
        INSTALL_NGINX_LOAD_BALANCER=Y
        ;;
      u)
        export SKIP_UPDATE='Y'
        ;;
      s)
        STOP_RELAYS=Y
        ;;
      h)
        usage
        exit 0
        ;;
      \?)
        echo "Invalid option: -${OPTARG}" >&2
        usage
        exit 1
        ;;
      :)
        echo "Option -${OPTARG} requires an argument." >&2
        usage
        exit 1
        ;;
      *)
        usage
        exit 1
        ;;
      esac
  done

  # Display usage menu if no flags are provided
  if [[ ${OPTIND} -eq 1 ]]; then
    usage
    exit 1
  fi

  . "$(dirname $0)"/mithril.library

  [[ "${STOP_RELAYS}" == "Y" ]] && stop_relays

  update_check "$@"

  if [[ ${INSTALL_SQUID_PROXY} = Y ]]; then
    deploy_squid_proxy
  fi

  if [[ ${INSTALL_NGINX_LOAD_BALANCER} = Y ]]; then
    deploy_nginx_load_balancer
  fi
}

main "$@"