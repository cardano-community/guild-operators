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

# >>> legacy-layout-guard
# Deployments made before CNTools 14 still fetch this file from
# scripts/cnode-helper-scripts/ when their update check runs. When it lands in
# such a deployment, put back the copies that update check archived, so the
# caller can run them again. Every copy of this block is the same; keep it so
# (files/tests/legacy-update-bridge.sh checks it).
legacy_layout_notice() {
  printf '%s\n' "" \
    "NOTICE: Guild Operators moved to a new deployment layout (CNTools 14, gLiveView 2.0)." \
    "This deployment still uses the earlier layout. Its scripts keep working, but no longer get updates." \
    "Upgrade guide: https://cardano-community.github.io/guild-operators/upgrade/#from-master" "" >&2
  if [[ -t 0 && -t 1 ]]; then
    read -rsn1 -p "Press any key to continue .." </dev/tty
    echo >&2
  fi
  return 0
}

# Returns 0 after putting the archived copies back (LEGACY_LAYOUT_SCRIPT is then
# the script to run again), and 1 on the current layout.
legacy_layout_guard() {
  local dir file candidate suffix backup restored=N
  dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || return 1
  [[ -f "${dir}/lib/env.library" || -f "${dir}/../common-helper-scripts/lib/env.library" ]] && return 1
  # The env of the earlier layout defines checkUpdate itself; the current one loads it from lib/.
  grep -q '^checkUpdate()' "${dir}/env" 2>/dev/null || return 1
  for file in "$@"; do
    grep -q '^# >>> legacy-layout-guard' "${dir}/${file}" 2>/dev/null || continue
    backup=""
    for candidate in "${dir}/archive/${file}_bkp"*; do
      suffix="${candidate##*_bkp}"
      [[ -f ${candidate} && ${suffix} =~ ^[0-9]+$ ]] || continue
      grep -q '^# >>> legacy-layout-guard' "${candidate}" && continue
      [[ -z ${backup} || ${suffix} -gt ${backup##*_bkp} ]] && backup="${candidate}"
    done
    if [[ -z ${backup} ]] || ! cp -f "${backup}" "${dir}/${file}"; then
      printf '\nERROR: %s needs the new deployment layout, and %s has no earlier copy of it to put back.\n' "${file}" "${dir}/archive" >&2
      legacy_layout_notice
      exit 1
    fi
    [[ ${file} = *.sh ]] && chmod +x "${dir}/${file}"
    printf '\nPut back the earlier %s from %s.\n' "${file}" "${backup}" >&2
    restored=Y
  done
  [[ ${restored} = Y ]] || return 1
  LEGACY_LAYOUT_SCRIPT="${dir}/$(basename "$0")"
  legacy_layout_notice
}
# <<< legacy-layout-guard

if legacy_layout_guard mithril-relay.sh mithril.library; then
  [[ $1 = "-u" || $1 = "--skip-update" ]] && shift
  exec "${LEGACY_LAYOUT_SCRIPT}" -u "$@"
fi

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
		-s  Stop relays
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