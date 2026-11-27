#!/usr/bin/env bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#MITHRILBIN="${CNODE_HOME}"/bin/mithril-client # Path for mithril-client binary, if not in $PATH

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

if legacy_layout_guard mithril-client.sh mithril.library; then
  [[ $1 = "-u" || $1 = "--skip-update" ]] && shift
  exec "${LEGACY_LAYOUT_SCRIPT}" -u "$@"
fi

#####################
# Functions         #
#####################

usage() {
  cat <<-EOF
        
		Usage: $(basename "$0") [-h] [-u] <command> <subcommand> [<sub arg>]
		A script to run Cardano Mithril Client
		
		[ -h | --help]         Print this help
		[ -u | --skip-update ] Skip script update check overriding UPDATE_CHECK value in env (must be first argument to script)
		    
			Commands:
			environment           Manage mithril environment file
			  setup               Setup mithril environment file
			  override            Override default variable in the mithril environment file
			  update              Update mithril environment file
			cardano-db            Interact with Cardano DB
			  download            Download Cardano DB from Mithril snapshot (Full)
			    skip-ancillary    Download Cardano DB from Mithril snapshot (Immutable DB only)
			  snapshot            Interact with Mithril snapshots
			    list              List available Mithril snapshots
			      json            List availble Mithril snapshots in JSON format
			    show              Show details of a Mithril snapshot
			      json            Show details of a Mithril snapshot in JSON format
			stake-distribution    Interact with Mithril stake distributions
			  download            Download latest stake distribution
			  list                List available stake distributions
			    json              Output latest Mithril snapshot in JSON format
        
EOF
}

SKIP_UPDATE=N
[[ $1 =~ "-u" ]] || [[ $1 =~ "--skip-update" ]] && export SKIP_UPDATE=Y && shift


#####################
# Execution/Main    #
#####################

function parse_opt_for_help() {
  for value in "$@"; do
    if [[ $value == "-h" ]] || [[ $value == "--help" ]]; then
      usage
      exit 0
    fi
  done
}

function main() {
  parse_opt_for_help "$@"

  . "$(dirname $0)"/mithril.library

  update_check "$@"

  set_defaults

  # Parse command line options
  case $1 in
    environment)
      case $2 in
        setup)
          generate_environment_file
          ;;
        override)
          environment_override $3 $4
          ;;
        update)
          export UPDATE_ENVIRONMENT="Y"
          generate_environment_file
          ;;
        *)
          echo "Invalid environment subcommand: $2" >&2
          usage
          exit 1
          ;;
      esac
      ;;
    cardano-db)
      mithril_init client || exit 1
      case $2 in
        download)
          case $3 in
            skip-ancillary)
              check_db_dir
              download_snapshot_noancillary
              ;;
            *)
              check_db_dir
              download_snapshot
              ;;
          esac
          ;;
        snapshot)
          case $3 in
            list)
              case $4 in
                json)
                  list_snapshots json
                  ;;
                *)
                  list_snapshots
                  ;;
              esac
              ;;
            show)
              show_snapshot $4 $5
              ;;
            *)
              echo "Invalid snapshot subcommand: $3" >&2
              usage
              exit 1
              ;;
          esac
      esac
      ;;
    stake-distribution)
      mithril_init client || exit 1
      case $2 in
        download)
          download_stake_distribution
          ;;
        list)
          case $3 in
            json)
              list_stake_distributions json
              ;;
            *)
              list_stake_distributions
              ;;
          esac
          ;;
        *)
          echo "Invalid mithril-stake-distribution subcommand: $2" >&2
          usage
          exit 1
          ;;
      esac
      ;;
    *)
      usage
      ;;
  esac

  exit 0
}

main "$@"
