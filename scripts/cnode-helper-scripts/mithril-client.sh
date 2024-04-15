#!/usr/bin/env bash
# shellcheck disable=SC2086
#shellcheck source=/dev/null

. "$(dirname $0)"/mithril.library

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
        
		Usage: $(basename "$0") [-u] <command> <subcommand> [<sub arg>]
		A script to run Cardano Mithril Client
		
		-u          Skip script update check overriding UPDATE_CHECK value in env (must be first argument to script)
		    
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
[[ $1 = "-u" ]] && export SKIP_UPDATE=Y && shift

## mithril environment subcommands

environment_override() {
  local var_to_override="$1"
  local new_value="$2"
  local env_file="${CNODE_HOME}/mithril/mithril.env"

  # Check if the variable exists in the environment file
  if ! grep -q "^${var_to_override}=" "$env_file"; then
    echo "Error: Variable $var_to_override does not exist in $env_file" >&2
    return 1
  fi

  # Use sed to replace the variable's value in the environment file
  sed -i "s|^${var_to_override}=.*|${var_to_override}=${new_value}|" "$env_file"
}

mithril_init() {
  [[ ! -f "${CNODE_HOME}"/mithril/mithril.env ]] && generate_environment_file
  . "${CNODE_HOME}"/mithril/mithril.env
}


check_db_dir() {
  # If the DB directory does not exist then set DOWNLOAD_SNAPSHOT to Y
  if [[ ! -d "${DB_DIRECTORY}" ]]; then
    echo "INFO: The db directory does not exist.."
    DOWNLOAD_SNAPSHOT="Y"
  # If the DB directory is empty then set DOWNLOAD_SNAPSHOT to Y
  elif [[ -d "${DB_DIRECTORY}" ]] && [[ -z "$(ls -A "${DB_DIRECTORY}")" ]] && [[ $(du -cs "${DB_DIRECTORY}"/* 2>/dev/null | awk '/total$/ {print $1}') -eq 0 ]]; then
    echo "INFO: The db directory is empty.."
    DOWNLOAD_SNAPSHOT="Y"
  else
    echo "INFO: The db directory is not empty, skipping Cardano DB download.."
  fi
}

cleanup_db_directory() {
  echo "WARNING: Download failure, cleaning up DB directory.."
  # Safety check to prevent accidental deletion of system files
  if [[ -z "${DB_DIRECTORY}" ]]; then
    echo "ERROR: DB_DIRECTORY is unset or null."
  elif [[ -n "${DB_DIRECTORY}" && "${DB_DIRECTORY}" != "/" && "${DB_DIRECTORY}" != "${CNODE_HOME}" ]]; then
    # :? Safety check to prevent accidental deletion of system files, even though initial if block should already prevent this
    rm -rf "${DB_DIRECTORY:?}/"*
  else
    echo "INFO: Skipping cleanup of DB directory: ${DB_DIRECTORY}."
  fi
}

## mithril snapshot subcommands

download_snapshot() {
  if [[ "${DOWNLOAD_SNAPSHOT}" == "Y" ]]; then
    echo "INFO: Downloading latest mithril snapshot.."
    trap 'cleanup_db_directory' INT
    if ! "${MITHRILBIN}" -v --aggregator-endpoint ${AGGREGATOR_ENDPOINT} cardano-db download --download-dir ${CNODE_HOME} --genesis-verification-key ${GENESIS_VERIFICATION_KEY} ${SNAPSHOT_DIGEST} ; then
      cleanup_db_directory
      exit 1
    fi
  else
    echo "INFO: Skipping Cardano DB download.."
  fi
}

list_snapshots() {
  local json_flag=""

  for arg in "$@"; do
    if [[ $arg == "json" ]]; then
      json_flag="--json"
    fi
  done

  "${MITHRILBIN}" -v --aggregator-endpoint ${AGGREGATOR_ENDPOINT} cardano-db snapshot list $json_flag
}

show_snapshot() {
  local digest=""
  local json_flag=""

  for arg in "$@"; do
    if [[ $arg == "json" ]]; then
      json_flag="--json"
    else
      digest="$arg"
    fi
  done

  if [[ -z $digest ]]; then
    echo "ERROR: Snapshot digest is required for the 'show' subcommand" >&2
    exit 1
  fi

  "${MITHRILBIN}" -v --aggregator-endpoint ${AGGREGATOR_ENDPOINT} cardano-db snapshot show $digest $json_flag
}

## mithril-stake-distribution subcommands

download_stake_distribution() {
  if [[ "${DOWNLOAD_STAKE_DISTRIBUTION}" == "Y" ]]; then
    echo "INFO: Downloading latest mithril stake distribution.."
    "${MITHRILBIN}" -v --aggregator-endpoint ${AGGREGATOR_ENDPOINT} mithril-stake-distribution download --download-dir "${CNODE_HOME}/mithril/" ${STAKE_DISTRIBUTION_DIGEST}
  else
    echo "INFO: Skipping stake distribution download.."
  fi
}

list_stake_distributions() {
  local json_flag=""

  for arg in "$@"; do
    if [[ $arg == "json" ]]; then
      json_flag="--json"
    fi
  done
  
  "${MITHRILBIN}" -v --aggregator-endpoint ${AGGREGATOR_ENDPOINT} mithril-stake-distribution list $json_flag

}

#####################
# Execution/Main    #
#####################

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
    mithril_init
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
    mithril_init
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
    echo "Invalid $(basename "$0") command: $1" >&2
    usage
    exit 1
    ;;
esac

exit 0
