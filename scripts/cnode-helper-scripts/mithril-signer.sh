#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2034
#shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#MITHRILBIN="${CNODE_HOME}"/bin/mithril-signer # Path for mithril-signer binary, if not in $PATH
#HOSTADDR=127.0.0.1                             # Default Listen IP/Hostname for Mithril Signer Server

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

if legacy_layout_guard mithril-signer.sh mithril.library; then
  [[ $1 = "-u" || $1 = "--skip-update" ]] && shift
  exec "${LEGACY_LAYOUT_SCRIPT}" -u "$@"
fi

#####################
# Functions         #
#####################

usage() {
  cat <<-EOF
		
		Usage: $(basename "$0") [-d] [-D] [-e] [-k] [-r] [-s] [-u] [-h]
		       $(basename "$0") systemd <install|remove|status>
		A script to setup, run and verify Cardano Mithril Signer
		
		-d    Deploy mithril-signer as a systemd service
		-D    Run mithril-signer as a daemon
		-e    Update mithril environment file
		-k    Stop signer using SIGINT
		-r    Verify signer registration
		-s    Verify signer signature
		-u    Skip update check
		-h    Show this help text
		systemd
		      Install, remove, or show the status of the mithril-signer service
		
		EOF
}


#####################
# Execution / Main  #
#####################

function main() {
  SYSTEMD_ACTION=""
  if [[ ${1:-} == "systemd" ]]; then
    [[ $# -eq 2 ]] || {
      usage
      exit 1
    }
    SYSTEMD_ACTION="${2}"
    case "${SYSTEMD_ACTION}" in
      install) DEPLOY_SYSTEMD="Y" ;;
      remove|status) : ;;
      *)
        usage
        exit 1
        ;;
    esac
    shift 2
  fi

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

  if [[ "${SYSTEMD_ACTION}" == "remove" || "${SYSTEMD_ACTION}" == "status" ]]; then
    MITHRIL_ENV_PROFILE="definitions"
  fi
  . "$(dirname $0)"/mithril.library

  if [[ "${SYSTEMD_ACTION}" == "remove" || "${SYSTEMD_ACTION}" == "status" ]]; then
    manage_mithril_systemd "${SYSTEMD_ACTION}"
    exit $?
  fi

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
    mithril_init signer || exit 1
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

      if grep -q "ENABLE_METRICS_SERVER=true" ${MITHRIL_HOME}/mithril.env; then
        METRICS_SERVER_PARAMS="--enable-metrics-server --metrics-server-ip ${METRICS_SERVER_IP} --metrics-server-port ${METRICS_SERVER_PORT}"
        # If ENABLE_METRICS_SERVER is true, then an environment update will enable gLiveView automatically.
        # shellcheck disable=SC2154
        sudo sed -i 's/#MITHRIL_SIGNER_ENABLED="[YN]"/MITHRIL_SIGNER_ENABLED="Y"/' ${CNODE_HOME}/scripts/env
        if ! "${MITHRILBIN}" ${METRICS_SERVER_PARAMS} -vv | tee -a "${LOG_DIR}/$(basename "${0::-3}")".log 2>&1 ; then
          echo "Failed to start Mithril Signer Server with metrics enabled" | tee -a "${LOG_DIR}/$(basename "${0::-3}")".log 2>&1
          exit 1
        fi
      else
        if ! "${MITHRILBIN}" -vv | tee -a "${LOG_DIR}/$(basename "${0::-3}")".log 2>&1 ; then
          echo "Failed to start Mithril Signer Server" | tee -a "${LOG_DIR}/$(basename "${0::-3}")".log 2>&1
          exit 1
        fi
      fi
    fi
  fi
}

main "$@"
