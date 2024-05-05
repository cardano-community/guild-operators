#!/bin/bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

. "$(dirname $0)"/mithril.library

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


generate_nginx_conf() {
  sudo bash -c "cat > /etc/nginx/nginx.conf <<'EOF'
worker_processes 1;

events {
    worker_connections 1024;
}

http {
    upstream mithril_relays {
        $(for ip in "${RELAY_LISTENING_IP[@]}"; do
		echo -e "            server ${ip}:${RELAY_LISTENING_PORT};"
	done)
    }

    server {
        listen ${SIDECAR_LISTENING_IP}:${RELAY_LISTENING_PORT};
        location / {
            proxy_pass http://mithril_relays;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }
    }
}
EOF"
}

generate_squid_conf() {
  # Write the squid config file
  sudo bash -c "cat <<-'EOF' > /etc/squid/squid.conf
		# Listening port (port 3132 is recommended)
		http_port ${RELAY_LISTENING_PORT}
		
		EOF"

  # Write the ACLs for each relay IP address
  sudo bash -c 'echo "# ACLs for IP of the block producers" >> /etc/squid/squid.conf'
  for ip in "${BLOCK_PRODUCER_IP[@]}"; do
    sudo bash -c "echo \"acl block_producer_ip src ${ip}\" >> /etc/squid/squid.conf"
  done

  # Write the rest of the squid config file
  sudo bash -c "cat <<-'EOF' >> /etc/squid/squid.conf
	# ACL for aggregator endpoint
	acl aggregator_domain dstdomain .mithril.network
	
	# ACL for SSL port only
	acl SSL_port port 443
	
	# Allowed traffic
	http_access allow block_producer_ip aggregator_domain SSL_port
	
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
  while true; do
    read -r -p "Enter the IP address of a relay: " ip
    RELAY_LISTENING_IP+=("${ip}")
    read -r -p "Are there more relays? (y/n) " yn
    case ${yn} in
      [Nn]*) break ;;
          *) continue ;;
    esac
  done

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

  # Read the listening IP addresses from user input
  while true; do
    read -r -p "Enter the IP address of your Block Producer: " ip
    BLOCK_PRODUCER_IP+=("${ip}")
    read -r -p "Are there more block producers? (y/n) " yn
    case ${yn} in
      [Nn]*) break ;;
          *) continue ;;
    esac
  done

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

[[ "${STOP_RELAYS}" == "Y" ]] && stop_relays

update_check "$@"

if [[ ${INSTALL_SQUID_PROXY} = Y ]]; then
  deploy_squid_proxy
fi

if [[ ${INSTALL_NGINX_LOAD_BALANCER} = Y ]]; then
  deploy_nginx_load_balancer
fi
