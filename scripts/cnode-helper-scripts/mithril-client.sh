#!/usr/bin/env bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#MITHRILBIN="${HOME}"/.local/bin/mithril-client # Path for mithril-client binary, if not in $PATH

######################################
# Do NOT modify code below           #
######################################

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
			  download            Download Cardano DB from Mithril snapshot
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
          check_db_dir
          download_snapshot
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
