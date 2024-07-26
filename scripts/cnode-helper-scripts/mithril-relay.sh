#!/bin/bash
# shellcheck disable=SC2086
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

# Function to read IP addresses into an array with a customizable prompt and confirmation message
read_ips_from_input() {
    local -n array_ref=$1     # Use nameref to reference the array passed by name
    local prompt_message=$2   # Prompt message for IP input
    local confirm_message=$3  # Confirmation message to ask if there are more IP addresses

    while true; do
        read -r -p "$prompt_message" ip
        array_ref+=("${ip}")
        read -r -p "$confirm_message" yn
        case ${yn} in
            [Nn]*) break ;;
                *) continue ;;
        esac
    done
}

# Function to read optional IP addresses into an array with customizable messages
read_optional_ips_from_input() {
    local -n array_ref=$1     # Use nameref to reference the array passed by name
    local confirm_message=$2  # Confirmation message to ask if there are IP addresses to add
    local prompt_message=$3   # Prompt message for IP input if the user wants to add more IP addresses

    while true; do
        read -r -p "$confirm_message" yn
        case ${yn} in
            [Nn]*) break ;;
                *) read -r -p "$prompt_message" ip
                   array_ref+=("${ip}")
                   ;;
        esac
    done
}

generate_nginx_conf() {
  sudo bash -c "cat > /etc/nginx/nginx.conf <<'EOF'
worker_processes 1;

events {
    worker_connections 1024;
}

stream {
    upstream mithril_relays {
        $(for ip in "${RELAY_LISTENING_IP[@]}"; do
		echo -e "            server ${ip}:${RELAY_LISTENING_PORT} max_fails=1 fail_timeout=${#RELAY_LISTENING_IP[@]}0;"
	done)
    }

    server {
        listen ${SIDECAR_LISTENING_IP}:${RELAY_LISTENING_PORT};
        proxy_connect_timeout 10;
        proxy_pass mithril_relays;
    }
}
EOF"
}

generate_squid_conf() {
  # Write the squid config file
  sudo bash -c "cat <<-'EOF' > /etc/squid/squid.conf
	# Listening port (port 3132 is recommended)
	http_port ${RELAY_LISTENING_PORT}
	
	# ACL for aggregator endpoint
	acl aggregator_domain dstdomain .mithril.network
	
	# ACL for SSL port only
	acl SSL_port port 443
	
	EOF"

  # Write the ACLs for block producer IP addresses
  sudo bash -c 'echo "# ACL alias for IP of the block producers" >> /etc/squid/squid.conf'
  int=0
  for ip in "${BLOCK_PRODUCER_IP[@]}"; do
    ((int++))
    sudo bash -c "echo \"acl block_producer_ip${int} src ${ip}\" >> /etc/squid/squid.conf"
  done
  sudo bash -c 'echo "" >> /etc/squid/squid.conf'
  unset int

  # Write the ACLs for any additional allowed IP addresses
  if [ ${#ADDITIONAL_ALLOWED_IP[@]} -gt 0 ]; then
    sudo bash -c 'echo "# ACL alias for any additional IPs" >> /etc/squid/squid.conf'
    int=0
    for ip in "${ADDITIONAL_ALLOWED_IP[@]}"; do
      ((int++))
      sudo bash -c "echo \"acl additional_allowed_ip${int} src ${ip}\" >> /etc/squid/squid.conf"
    done
    sudo bash -c 'echo "" >> /etc/squid/squid.conf'
    unset int
  fi
  
  # Write the allow rules
  sudo bash -c 'echo "# Allowed traffic" >> /etc/squid/squid.conf'
  int=0
  for ip in "${BLOCK_PRODUCER_IP[@]}"; do
    ((int++))
    sudo bash -c "echo \"http_access allow block_producer_ip${int} aggregator_domain SSL_port\" >> /etc/squid/squid.conf"
  done
  int=0
  for ip in "${ADDITIONAL_ALLOWED_IP[@]}"; do
    ((int++))
    sudo bash -c "echo \"http_access allow additional_allowed_ip${int} aggregator_domain SSL_port\" >> /etc/squid/squid.conf"
  done
  unset int

  # Write the fix chunk of the squid config file
  sudo bash -c "cat <<-'EOF' >> /etc/squid/squid.conf
	
	# Do not disclose relay internal IP
	forwarded_for delete
	
	# Turn off via header
	via off
	
	# Deny request for original source of a request
	follow_x_forwarded_for deny all
	
	# Anonymize request headers
	request_header_access Authorization allow all
	request_header_access Proxy-Authorization allow all
	request_header_access Cache-Control allow all
	request_header_access Content-Length allow all
	request_header_access Content-Type allow all
	request_header_access Date allow all
	request_header_access Host allow all
	request_header_access If-Modified-Since allow all
	request_header_access Pragma allow all
	request_header_access Accept allow all
	request_header_access Accept-Charset allow all
	request_header_access Accept-Encoding allow all
	request_header_access Accept-Language allow all
	request_header_access Connection allow all
	request_header_access All deny all

	# Disable cache
	cache deny all

	# Deny everything else
	http_access deny all
	EOF"
}

deploy_nginx_load_balancer() {
  # Install nginx and configure load balancing
  echo -e "\nInstalling nginx load balancer"
  sudo apt-get update
  sudo apt-get install -y nginx

  # Read the listening IP addresses from user input
  read_ips_from_input RELAY_LISTENING_IP \
    "Enter the IP address of a relay: " \
    "Are there more relays? (y/n) "

  # Read the listening IP for the load balancer
  read -r -p "Enter the IP address of the load balancer (press Enter to use default 127.0.0.1): " SIDECAR_LISTENING_IP
  SIDECAR_LISTENING_IP=${SIDECAR_LISTENING_IP:-127.0.0.1}
  echo "Using IP address ${SIDECAR_LISTENING_IP} for the load balancer configuration."

  # Read the listening port from user input
  read -r -p "Enter the relay's listening port (press Enter to use default 3132): " RELAY_LISTENING_PORT
  RELAY_LISTENING_PORT=${RELAY_LISTENING_PORT:-3132}
  echo "Using port ${RELAY_LISTENING_PORT} for relay's listening port."

  # Generate the nginx configuration file
  generate_nginx_conf
  # Restart nginx and check status
  echo -e "\nStarting Mithril relay sidecar (nginx load balancer)"
  sudo systemctl restart nginx
  sudo systemctl status nginx

}

deploy_squid_proxy() {
  # Install squid and make a backup of the config file
  echo -e "\nInstalling squid proxy"
  sudo apt-get update
  sudo apt-get install -y squid
  sudo cp /etc/squid/squid.conf /etc/squid/squid.conf.bak

  # Read the block producer IP addresses from user input
  read_ips_from_input BLOCK_PRODUCER_IP \
    "Enter the IP address of your Block Producer: " \
    "Are there more block producers? (y/n) "

  # Read any additional IP addresses from user input
  read_optional_ips_from_input ADDITIONAL_ALLOWED_IP \
    "Are there more IP addresses you would like to allow like the local relay IP (to be used for testing, etc.)? (y/n) " \
    "Enter the IP address you would like to allow: "

  # Read the listening port from user input
  read -r -p "Enter the relay's listening port (press Enter to use default 3132): " RELAY_LISTENING_PORT
  RELAY_LISTENING_PORT=${RELAY_LISTENING_PORT:-3132}
  echo "Using port ${RELAY_LISTENING_PORT} for relay's listening port."
  generate_squid_conf

  # Restart squid and check status
  echo -e "\nStarting Mithril relay (squid proxy)"
  sudo systemctl restart squid
  sudo systemctl status squid

  # Inform the user to create the appropriate firewall rule
  for ip in "${RELAY_LISTENING_IP[@]}"; do
    echo "Create the appropriate firewall rule: sudo ufw allow from ${ip} to any port ${RELAY_LISTENING_PORT} proto tcp"
  done
}

stop_relays() {
  echo "  Stopping squid proxy and nginx load balancers.."
  sudo systemctl stop squid 2>/dev/null
  sudo systemctl stop nginx 2>/dev/null
  sleep 5
  exit 0
}

#####################
# Execution/Main    #
#####################

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
