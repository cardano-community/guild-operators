#!/usr/bin/env bash
# Canonical implementation-neutral CNTools entrypoint.
# shellcheck disable=SC1090,SC2086,SC2154,SC2034,SC2012,SC2140,SC2028,SC1091,SC2206

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#TIMEOUT_NO_OF_SLOTS=600 # used when waiting for a new block to be created

# Log CNTools activities
# LOG_DIR set in env file
#CNTOOLS_LOG="${LOG_DIR}/cntools-history.log"

# kes rotation warning (in seconds)
# if disabled KES check will be skipped on startup
#CHECK_KES=false
#KES_ALERT_PERIOD=172800 # default 2 days
#KES_WARNING_PERIOD=604800 # default 7 days

# Default Transaction TTL (slots after which transaction will expire from queue) to use
#TX_TTL=3600

# Limit for extended wallet selection menu filtering (balance check and delegation status)
# If more wallets exist than limit set these checks will be disabled to improve performance
#WALLET_SELECTION_FILTER_LIMIT=10

# Enable or disable chattr used to protect keys from being overwritten [true|false] (not supported on all systems)
# If disabled standard read-only permission is set instead
#ENABLE_CHATTR=true

# Enable or disable dialog used to help in file/dir selection by providing a gui to see available files and folders. [true|false] (not supported on all systems)
# If disabled standard tty input is used
#ENABLE_DIALOG=false

# Enable advanced/developer features like metadata transactions, asset management etc. [true|false] (not needed for SPO usage)
#ENABLE_ADVANCED=false

# Price fetching currency. Disable by setting value 'off' [off|usd|eur|...] (default: off) (https://api.coingecko.com/api/v3/simple/supported_vs_currencies)
#CURRENCY=usd

# Runtime mode, offline | local | light (default local)
# CNTOOLS_MODE=local

# Project Catalyst API (only for mainnet)
#CATALYST_API=https://api.projectcatalyst.io/api/v1

# Url for transaction lookup on submit, __tx_id__ replaced by transaction hash
#EXPLORER_TX="https://adastat.net/transactions/__tx_id__"

######################################
# Do NOT modify code below           #
######################################

########## Global tasks ###########################################

# General exit handler
cleanup() {
  sleep 0.1
  [[ -n $1 ]] && err=$1 || err=$?
  [[ $err -eq 0 ]] && clear
  [[ -n ${exit_msg} ]] && echo -e "\n${exit_msg}\n" || echo -e "\nCNTools terminated, cleaning up...\n"
  tput cnorm # restore cursor
  tput sgr0  # turn off all attributes
  pkill -TERM -P ${$} &>/dev/null # kill all child processes of CNTools script
  exit $err
}
# Keep function definitions safe to source for characterization and unit tests.
# Direct execution retains the existing terminal lifecycle.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap cleanup HUP INT TERM
  if STTY_SETTINGS="$(stty -g 2>/dev/null < /dev/tty)"; then
    trap 'stty "$STTY_SETTINGS" < /dev/tty' EXIT
  else
    STTY_SETTINGS=""
  fi
fi

# Command     : myExit [exit code] [message]
# Description : gracefully handle an exit and restore terminal to original state
myExit() {
  exit_msg="$2"
  cleanup "$1"
}

usage() {
  cat <<-EOF
		Usage: $(basename "$0") [-o] [-a] [-b <branch name>] [-v]
		Koios CNTools - The Cardano SPOs best friend

		-n    Local mode   - run CNTools in local node mode (default)
		-l    Light mode   - run CNTools using Koios query layer for full functionallity without a local node
		-o    Offline mode - run CNTools with a limited set of functionallity without external communication useful for air-gapped mode
		-a    Enable advanced/developer features like metadata transactions, asset management etc (not needed for SPO usage)
		-u    Skip script update check overriding UPDATE_CHECK value in env
		-b    Persist an alternate Guild Operators branch for this deployment
		-v    Print CNTools version

		EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then

# Existing startup remains at script scope so getopts, shift, and re-exec keep
# their established semantics. This whole block is direct-execution only.
ADVANCED_MODE="false"
SKIP_UPDATE=N
PRINT_VERSION="false"
BRANCH_EXPLICIT=N
REQUESTED_BRANCH=""
PARENT="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

# save launch params
arg_copy=("$@")

while getopts :nolaub:v opt; do
  case ${opt} in
    n ) CNTOOLS_MODE="LOCAL" ;;
    o ) CNTOOLS_MODE="OFFLINE" ;;
    l ) CNTOOLS_MODE="LIGHT" ;;
    a ) ADVANCED_MODE="true" ;;
    u ) SKIP_UPDATE=Y ;;
    b ) REQUESTED_BRANCH="${OPTARG}"; GUILD_BRANCH_OVERRIDE="${OPTARG}"; BRANCH_EXPLICIT=Y ;;
    v ) PRINT_VERSION="true" ;;
    \? ) myExit 1 "$(usage)" ;;
    esac
done
shift $((OPTIND -1))
[[ -z ${CNTOOLS_MODE} ]] && CNTOOLS_MODE="LOCAL"

#######################################################
# Version Check                                       #
#######################################################
clear

if [[ ! -f "${PARENT}"/env ]]; then
  echo -e "\nCommon env file missing: ${PARENT}/env"
  echo -e "This is a mandatory prerequisite, please install with guild-deploy.sh or manually download from GitHub\n"
  myExit 1
fi

. "${PARENT}"/env definitions || myExit 1 "ERROR: CNTools failed to load common env definitions"

if [[ "${BRANCH_EXPLICIT}" == "Y" ]]; then
  deployment_set_branch "${REQUESTED_BRANCH}" ||
    myExit 1 "ERROR: Invalid branch '${REQUESTED_BRANCH}' or unable to update ${NODE_HOME}/.deployment.json"
  unset GUILD_BRANCH_OVERRIDE
fi

# Update code before loading cntools.library. This avoids retaining derived
# library state from a previous env after a partial in-process update.
if [[ ${CNTOOLS_MODE} != "OFFLINE" && ${UPDATE_CHECK} = Y && ${SKIP_UPDATE} != Y ]]; then
  clear
  echo "Checking for script updates..."
  if ! declare -F checkCommonRuntimeUpdates >/dev/null; then
    myExit 1 "Common runtime bundle updater is unavailable; re-run guild-deploy.sh"
  fi

  BUNDLE_UPDATED=N
  if checkCommonRuntimeUpdates N; then
    common_update_status=0
  else
    common_update_status=$?
  fi
  case "${common_update_status}" in
    0) ;;
    1) BUNDLE_UPDATED=Y ;;
    2) myExit 1 "Failed to update the common runtime bundle" ;;
  esac

  checkUpdate "${PARENT}/cntools.library" "${BUNDLE_UPDATED}" N N "common-helper-scripts" exact
  case $? in
    1) BUNDLE_UPDATED=Y ;;
    2) myExit 1 "Failed to update cntools.library" ;;
  esac
  checkUpdate "${PARENT}/cntools.sh" "${BUNDLE_UPDATED}" N N "common-helper-scripts" N
  case $? in
    1) BUNDLE_UPDATED=Y ;;
    2) myExit 1 "Failed to update cntools.sh" ;;
  esac

  if [[ "${BUNDLE_UPDATED}" == "Y" ]]; then
    exec "$0" -u "${arg_copy[@]}"
  fi
fi

case "${CNTOOLS_MODE}" in
  LOCAL) ENV_PROFILE="local" ;;
  LIGHT) ENV_PROFILE="light" ;;
  OFFLINE) ENV_PROFILE="offline" ;;
  *) myExit 1 "Unsupported CNTools mode: ${CNTOOLS_MODE}" ;;
esac

. "${PARENT}"/env "${ENV_PROFILE}"
case $? in
  1) myExit 1 "ERROR: CNTools failed to initialize the selected node adapter\nPlease verify .deployment.json and values in env" ;;
  2) myExit 1 "ERROR: The selected node is not ready for CNTools ${CNTOOLS_MODE} mode" ;;
  3) myExit 1 "ERROR: ${NODE_IMPLEMENTATION} does not provide the capabilities required by CNTools ${CNTOOLS_MODE} mode" ;;
esac

# Source cntools.library only after the final env profile is initialized.
. "${PARENT}"/cntools.library || myExit 1

if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
  test_koios
  [[ -z ${KOIOS_API} ]] && myExit 1 "ERROR: Koios query test failed, unable to launch CNTools in light mode utilizing Koios query layer\n\n${launch_modes_info}"
fi

[[ ${CNTOOLS_MODE} != "LIGHT" ]] && unset KOIOS_API
[[ ${PRINT_VERSION} = "true" ]] && myExit 0 "CNTools v${CNTOOLS_VERSION} (branch: ${BRANCH})"

# Do some checks when run in connected(local|light) mode
if [[ ${CNTOOLS_MODE} != "OFFLINE" ]]; then

  # check if CNTools was recently updated, if so show whats new
  if cp -f "${NODE_HOME}/files/cntools-changelog.md" "${TMP_DIR}/cntools-changelog.md" 2>/dev/null; then
    if ! cmp -s "${TMP_DIR}"/cntools-changelog.md "${PARENT}/cntools-changelog.md"; then
      # Latest changes not shown, show whats new and copy changelog
      clear
      if [[ ! -f "${PARENT}/cntools-changelog.md" ]]; then
        # special case for first installation or 5.0.0 upgrade, print release notes until previous major version
        echo -e "~ CNTools - What's New ~\n\n" "$(sed -n "/\[${CNTOOLS_MAJOR_VERSION}\.${CNTOOLS_MINOR_VERSION}\.${CNTOOLS_PATCH_VERSION}\]/,/\[$((CNTOOLS_MAJOR_VERSION-1))\.[0-9]\.[0-9]\]/p" "${TMP_DIR}"/cntools-changelog.md | head -n -2)" "\n [Press 'q' to quit and proceed to CNTools main menu]\n" | less -X
      else
        # print release notes from current until previously installed version
        [[ $(cat "${PARENT}/cntools-changelog.md") =~ \[([[:digit:]]+)\.([[:digit:]]+)\.([[:digit:]]+)\] ]]
        cat <(echo -e "~ CNTools - What's New ~\n") <(awk "1;/\[${BASH_REMATCH[1]}\.${BASH_REMATCH[2]}\.${BASH_REMATCH[3]}\]/{exit}" "${TMP_DIR}"/cntools-changelog.md | head -n -2 | tail -n +7) <(echo -e "\n [Press 'q' to quit and proceed to CNTools main menu]\n") | less -X
      fi
      cp "${TMP_DIR}"/cntools-changelog.md "${PARENT}/cntools-changelog.md"
    fi
  else
    echo -e "\n${FG_RED}ERROR${NC}: managed CNTools changelog is missing; re-run guild-deploy.sh to restore the complete payload."
    waitToProceed
  fi
fi

archiveLog # archive current log and cleanup log archive folder

# check for required command line tools
if ! cmdAvailable "curl" || \
   ! cmdAvailable "jq" || \
   ! cmdAvailable "bc" || \
   ! cmdAvailable "sed" || \
   ! cmdAvailable "awk" || \
   ! cmdAvailable "column" || \
   ! protectionPreRequisites; then myExit 1 "Missing one or more of the required command line tools, press any key to exit"
fi

# check that bash version is > 4.4.0
[[ $(bash --version | head -n 1) =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] || myExit 1 "Unable to get BASH version"
if ! versionCheck "4.4.0" "${BASH_REMATCH[1]}"; then
  myExit 1 "BASH does not meet the minimum required version of ${FG_LBLUE}4.4.0${NC}, found ${FG_LBLUE}${BASH_REMATCH[1]}${NC}\n\nPlease upgrade to a newer Linux distribution or compile latest BASH following official docs.\n\nINSTALL:  https://www.gnu.org/software/bash/manual/html_node/Installing-Bash.html\nDOWNLOAD: http://git.savannah.gnu.org/cgit/bash.git/ (latest stable TAG)"
fi

# check if there are pools in need of KES key rotation
clear
kes_rotation_needed="no"
if [[ ${CHECK_KES} = true ]]; then

  while IFS= read -r -d '' pool; do
    if [[ ! -f "${pool}/${POOL_CURRENT_KES_START}" ]]; then
      continue
    fi

    unset remaining_kes_periods
    pool_kes_start="$(cat "${pool}/${POOL_CURRENT_KES_START}")"

    if ! kesExpiration ${pool_kes_start}; then println ERROR "${FG_RED}ERROR${NC}: failure during KES calculation for ${FG_GREEN}$(basename ${pool})${NC}" && waitToProceed && continue; fi

    if [[ ${expiration_time_sec_diff} -lt ${KES_ALERT_PERIOD} ]]; then
      kes_rotation_needed="yes"
      println "\n** WARNING **\nPool ${FG_GREEN}$(basename ${pool})${NC} in need of KES key rotation"
      if [[ ${expiration_time_sec_diff} -lt 0 ]]; then
        println DEBUG "${FG_RED}Keys expired!${NC} : ${FG_RED}$(timeLeft ${expiration_time_sec_diff:1})${NC} ago"
      else
        println DEBUG "Remaining KES periods : ${FG_RED}${remaining_kes_periods}${NC}"
        println DEBUG "Time left             : ${FG_RED}$(timeLeft ${expiration_time_sec_diff})${NC}"
      fi
    elif [[ ${expiration_time_sec_diff} -lt ${KES_WARNING_PERIOD} ]]; then
      kes_rotation_needed="yes"
      println DEBUG "\nPool ${FG_GREEN}$(basename ${pool})${NC} soon in need of KES key rotation"
      println DEBUG "Remaining KES periods : ${FG_YELLOW}${remaining_kes_periods}${NC}"
      println DEBUG "Time left             : ${FG_YELLOW}$(timeLeft ${expiration_time_sec_diff})${NC}"
    fi
  done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
  [[ ${kes_rotation_needed} = "yes" ]] && waitToProceed

fi

# Verify that shelley transition epoch was properly identified by env
if [[ ${SHELLEY_TRANS_EPOCH} -lt 0 ]]; then # unknown network
  clear
  myExit 1 "${FG_YELLOW}WARN${NC}: This is an unknown network, please manually set SHELLEY_TRANS_EPOCH variable in env file"
fi

fi # direct-execution startup

###################################################################

# Run one literal compatibility action from a private snapshot of the
# receipt-bound immutable generation. Public reachability remains controlled by
# the legacy call sites; accepting an action ID here does not expose a menu.
cntools_compatibility_dispatch_action() (
  local action_id="${1:-}" action_relative=""
  local receipt="${NODE_HOME}/.guild-source-receipt.json"
  local metadata="${NODE_HOME}/.deployment.json"
  local state_root="${NODE_HOME}/scripts/.cntools"
  local generation_id="" generation="" generation_manifest=""
  local generation_receipt="" lifecycle="" expected_lifecycle_hash=""
  local receipt_hash="" metadata_hash="" current_receipt_hash=""
  local current_metadata_hash="" current_generation_id="" context_mode=""
  local node_home_physical=""
  local module_relative="" action_file_relative=""
  local module_source_relative="" action_source_relative=""
  local source_module="" source_action=""
  local expected_module_hash="" expected_action_hash=""
  local mnemonic_sidecar_required="N" legacy_bundle_id=""
  local legacy_bundle_relative="" mnemonic_member_relative=""
  local mnemonic_member_source_relative="" source_mnemonic_sidecar=""
  local expected_mnemonic_hash="" expected_mnemonic_size=""
  local mnemonic_metadata="" receipt_mnemonic_hash=""
    local expected_context_hash=""
  local private_root="" snapshot_directory="" snapshot_module=""
  local snapshot_action="" snapshot_mnemonic_sidecar=""
  local context_file="" result_file=""
  local jq_path="" mktemp_path="" mkdir_path="" cp_path="" chmod_path=""
  local rm_path="" rmdir_path="" bash_path=""
    local action_status=70 cleanup_status=0 lock_acquired="N"
    local -A mnemonic_before_functions=()
    local -A mnemonic_before_variables=()

  case "${action_id}" in
    advanced.asset.burn) ;;
    advanced.asset.create-policy) ;;
    advanced.asset.decrypt-policy) ;;
    advanced.asset.encrypt-policy) ;;
    advanced.asset.list) ;;
    advanced.asset.mint) ;;
    advanced.asset.register) ;;
    advanced.asset.show) ;;
    advanced.delete-private-keys) ;;
    advanced.metadata) ;;
    advanced.multisig.create) ;;
    advanced.multisig.derive-keys) ;;
    backup.create) ;;
    backup.restore) ;;
    blocks.epoch) ;;
    blocks.summary) ;;
    funds.delegate) ;;
    funds.send) ;;
    funds.withdraw) ;;
    pool.calidus) ;;
    pool.decrypt) ;;
    pool.encrypt) ;;
    pool.import) ;;
    pool.list) ;;
    pool.modify) ;;
    pool.new) ;;
    pool.register) ;;
    pool.retire) ;;
    pool.rotate) ;;
    pool.show) ;;
    transaction.sign) ;;
    transaction.submit) ;;
    vote.catalyst.qr) ;;
    vote.catalyst.register) ;;
    vote.catalyst.verify) ;;
    vote.governance.cast) ;;
    vote.governance.delegate) ;;
    vote.governance.derive-keys) ;;
    vote.governance.drep-register) ;;
    vote.governance.drep-retire) ;;
    vote.governance.info) ;;
    vote.governance.multisig-drep) ;;
    vote.governance.proposals) ;;
    wallet.decrypt) ;;
    wallet.deregister) ;;
    wallet.encrypt) ;;
    wallet.import.hardware) ;;
    wallet.import.mnemonic) mnemonic_sidecar_required="Y" ;;
    wallet.list) ;;
    wallet.new.cli) ;;
    wallet.new.mnemonic) mnemonic_sidecar_required="Y" ;;
    wallet.register) ;;
    wallet.remove) ;;
    wallet.show) ;;
    *) return 70 ;;
  esac
  shift
  action_relative="${action_id//.//}"
  module_relative="cntools/modules/root/${action_relative}/module.json"
  action_file_relative="cntools/modules/root/${action_relative}/action.sh"
  module_source_relative="scripts/common-helper-scripts/cntools/modules/root/${action_relative}/module.json"
  action_source_relative="scripts/common-helper-scripts/cntools/modules/root/${action_relative}/action.sh"

  _cntools_compatibility_cleanup() {
    local cleanup_target=""

    if [[ -n "${private_root}" ]]; then
      for cleanup_target in \
        "${result_file}" \
        "${context_file}" \
        "${snapshot_mnemonic_sidecar}" \
        "${snapshot_action}" \
        "${snapshot_module}"; do
        [[ -n "${cleanup_target}" ]] || continue
        if [[ -d "${cleanup_target}" && ! -L "${cleanup_target}" ]]; then
          "${rmdir_path}" -- "${cleanup_target}" >/dev/null 2>&1 ||
            cleanup_status=1
        elif [[ -e "${cleanup_target}" || -L "${cleanup_target}" ]]; then
          "${rm_path}" -f -- "${cleanup_target}" >/dev/null 2>&1 ||
            cleanup_status=1
        fi
      done
      if [[ -n "${snapshot_directory}" ]]; then
        if [[ -d "${snapshot_directory}" &&
              ! -L "${snapshot_directory}" ]]; then
          "${rmdir_path}" -- "${snapshot_directory}" >/dev/null 2>&1 ||
            cleanup_status=1
        elif [[ -e "${snapshot_directory}" ||
                -L "${snapshot_directory}" ]]; then
          "${rm_path}" -f -- "${snapshot_directory}" >/dev/null 2>&1 ||
            cleanup_status=1
        fi
      fi
      "${rmdir_path}" -- "${private_root}" >/dev/null 2>&1 ||
        cleanup_status=1
      private_root=""
    fi
    if [[ "${lock_acquired}" == "Y" ]]; then
      cntools_generation_lock_release "${state_root}" >/dev/null 2>&1 ||
        cleanup_status=1
      lock_acquired="N"
    fi
  }

  _cntools_compatibility_private_file_validate() {
    local target="${1:-}" expected_mode="${2:-}"
    local expected_hash="${3:-}" expected_size="${4:-}" file_metadata=""
    local owner="" mode="" links="" size="" parent="" actual_hash=""

    [[ -f "${target}" && ! -L "${target}" ]] || return 1
    _cntools_result_path_valid "${target}" || return 1
    _cntools_registry_path_has_no_symlinks "${target}" || return 1
    parent="${target%/*}"
    [[ -n "${parent}" ]] || parent="/"
    _cntools_result_private_parent_validate "${parent}" || return 1
    file_metadata="$(_cntools_result_stat "${target}")" || return 1
    IFS=$'\t' read -r owner mode links size <<< "${file_metadata}" ||
      return 1
    [[ "${owner}" == "${EUID}" &&
       ( "${mode}" == "${expected_mode}" ||
         "${mode}" == "0${expected_mode}" ) &&
       "${links}" == "1" && "${size}" =~ ^[0-9]+$ &&
       "${size}" -ge 1 ]] || return 1
    [[ -z "${expected_size}" || "${size}" == "${expected_size}" ]] ||
      return 1
    if [[ -n "${expected_hash}" ]]; then
      actual_hash="$(deployment_payload_sha256 "${target}")" || return 1
      [[ "${actual_hash}" == "${expected_hash}" ]] || return 1
    fi
  }

  _cntools_compatibility_generation_file_validate() {
    local target="${1:-}" expected_mode="${2:-}"
    local expected_hash="${3:-}" expected_size="${4:-}"
    local file_metadata="" owner="" mode="" links="" size=""
    local actual_hash=""

    [[ -f "${target}" && ! -L "${target}" && -O "${target}" ]] || return 1
    _cntools_result_path_valid "${target}" || return 1
    _cntools_registry_path_has_no_symlinks "${target}" || return 1
    file_metadata="$(_cntools_result_stat "${target}")" || return 1
    IFS=$'\t' read -r owner mode links size <<< "${file_metadata}" ||
      return 1
    [[ "${owner}" == "${EUID}" &&
       ( "${mode}" == "${expected_mode}" ||
         "${mode}" == "0${expected_mode}" ) &&
       "${links}" == "1" && "${size}" == "${expected_size}" ]] || return 1
    actual_hash="$(deployment_payload_sha256 "${target}")" || return 1
    [[ "${actual_hash}" == "${expected_hash}" ]]
  }

  _cntools_compatibility_mnemonic_sidecar_contract_validate() {
    local target="${1:-}" baseline_output="" validation_output=""
    local baseline_status=0 validation_status=0 contract_script=""

    contract_script='
          _cntools_contract_mode=${1:-}
          _cntools_contract_target=${2:-}
          _cntools_contract_name=""
          _cntools_contract_source_status=0
          while IFS= read -r _cntools_contract_name; do
            builtin unset -f "${_cntools_contract_name}" 2>/dev/null || exit 1
          done < <(builtin compgen -A function)
          _cntools_contract_expected=(
            _cntools_compatibility_wallet_mnemonic_run
            buildOfflineJSON
            createMnemonicWallet
            createNewWallet
            deregisterStakeWallet
            printWalletInfo
            registerStakeWallet
          )
          declare -A _cntools_contract_expected_names=()
          _cntools_contract_count=0
          for _cntools_contract_name in "${_cntools_contract_expected[@]}"; do
            _cntools_contract_expected_names["${_cntools_contract_name}"]=Y
          done
          _cntools_contract_before_pwd=${PWD}
          _cntools_contract_before_ifs=$(builtin printf %q "${IFS}")
          _cntools_contract_before_options=$(builtin set +o)
          _cntools_contract_before_shopt=$(builtin shopt -p)
          _cntools_contract_before_aliases=$(builtin alias -p)
          _cntools_contract_before_traps=$(builtin trap -p)
          _cntools_contract_before_args=$(builtin printf "%q " "$@")
          _cntools_contract_before_umask=$(builtin umask)
          builtin readonly _cntools_contract_mode _cntools_contract_target \
            _cntools_contract_before_pwd _cntools_contract_before_ifs \
            _cntools_contract_before_options _cntools_contract_before_shopt \
            _cntools_contract_before_aliases _cntools_contract_before_traps \
            _cntools_contract_before_args _cntools_contract_before_umask
          builtin readonly -a _cntools_contract_expected
          builtin readonly -A _cntools_contract_expected_names
          if [[ "${_cntools_contract_mode}" == source ]]; then
            if builtin source "${_cntools_contract_target}"; then
              _cntools_contract_source_status=0
            else
              _cntools_contract_source_status=$?
            fi
            (( _cntools_contract_source_status == 0 )) || exit 1
            [[ "${PWD}" == "${_cntools_contract_before_pwd}" &&
               "$(builtin printf %q "${IFS}")" == \
                 "${_cntools_contract_before_ifs}" &&
               "$(builtin set +o)" == "${_cntools_contract_before_options}" &&
               "$(builtin shopt -p)" == "${_cntools_contract_before_shopt}" &&
               "$(builtin alias -p)" == \
                 "${_cntools_contract_before_aliases}" &&
               "$(builtin trap -p)" == "${_cntools_contract_before_traps}" &&
               "$(builtin printf "%q " "$@")" == \
                 "${_cntools_contract_before_args}" &&
               "$(builtin umask)" == "${_cntools_contract_before_umask}" ]] ||
              exit 1
            _cntools_contract_count=0
            while IFS= read -r _cntools_contract_name; do
              [[ -n "${_cntools_contract_name}" &&
                 -n "${_cntools_contract_expected_names[${_cntools_contract_name}]+set}" &&
                 "$(builtin declare -p -F "${_cntools_contract_name}")" == \
                   "declare -f ${_cntools_contract_name}" ]] ||
                exit 1
              _cntools_contract_count=$((_cntools_contract_count + 1))
            done < <(builtin compgen -A function)
            (( _cntools_contract_count == ${#_cntools_contract_expected[@]} )) ||
              exit 1
          elif [[ "${_cntools_contract_mode}" != baseline ]]; then
            exit 1
          fi
          while IFS= read -r _cntools_contract_name; do
            case "${_cntools_contract_name}" in
              _cntools_contract_*|_|BASHPID|BASH_ARGC|BASH_ARGV|BASH_COMMAND|\
              BASH_LINENO|BASH_SOURCE|EPOCHREALTIME|EPOCHSECONDS|FUNCNAME|\
              LINENO|PIPESTATUS|PPID|RANDOM|SECONDS|SRANDOM) continue ;;
            esac
            builtin declare -p "${_cntools_contract_name}" || exit 1
          done < <(builtin compgen -A variable)
        '
    baseline_output="$(
      BASH_ENV=/dev/null ENV=/dev/null HOME="${private_root}" \
        TMPDIR="${private_root}" \
        CNTOOLS_COMPATIBILITY_SIDECAR_CONTRACT=Y \
        "${bash_path}" --noprofile --norc -c "${contract_script}" \
        bridge-sidecar baseline "${target}" 2>&1
    )" || baseline_status=$?
    validation_output="$(
      BASH_ENV=/dev/null ENV=/dev/null HOME="${private_root}" \
        TMPDIR="${private_root}" \
        CNTOOLS_COMPATIBILITY_SIDECAR_CONTRACT=Y \
        "${bash_path}" --noprofile --norc -c "${contract_script}" \
        bridge-sidecar source "${target}" 2>&1
    )" || validation_status=$?
    [[ ${baseline_status} -eq 0 && ${validation_status} -eq 0 &&
       "${validation_output}" == "${baseline_output}" ]]
  }

  _cntools_compatibility_mnemonic_sidecar_source() {
    local function_name="" function_declaration="" variable_name=""
    local variable_declaration="" variable_declaration_after=""
    local source_status=0
    local before_pwd="" before_ifs="" before_options="" before_shopt=""
    local before_aliases="" before_traps="" before_args="" before_umask=""
    local -a expected_functions=(
      _cntools_compatibility_wallet_mnemonic_run
      buildOfflineJSON
      createMnemonicWallet
      createNewWallet
      deregisterStakeWallet
      printWalletInfo
      registerStakeWallet
    )
    local -A expected_names=()

    mnemonic_before_functions=()
    mnemonic_before_variables=()
    for function_name in "${expected_functions[@]}"; do
      expected_names["${function_name}"]="Y"
    done
    while IFS= read -r function_name; do
      [[ -n "${function_name}" ]] || return 1
      case "${function_name}" in
        _cntools_compatibility_wallet_mnemonic_*|buildOfflineJSON|\
        createMnemonicWallet|createNewWallet|deregisterStakeWallet|\
        printWalletInfo|registerStakeWallet) continue ;;
      esac
      function_declaration="$(builtin declare -f "${function_name}")" ||
        return 1
      mnemonic_before_functions["${function_name}"]="${function_declaration}"
    done < <(builtin compgen -A function)
    while IFS= read -r function_name; do
      case "${function_name}" in
        _cntools_compatibility_wallet_mnemonic_*|buildOfflineJSON|\
        createMnemonicWallet|createNewWallet|deregisterStakeWallet|\
        printWalletInfo|registerStakeWallet)
          builtin unset -f "${function_name}" 2>/dev/null || return 1
          ;;
      esac
    done < <(builtin compgen -A function)
    builtin unset CNTOOLS_COMPATIBILITY_SIDECAR_CONTRACT 2>/dev/null ||
      builtin true
    before_pwd="${PWD}"
    before_ifs="$(builtin printf %q "${IFS}")"
    before_options="$(builtin set +o)"
    before_shopt="$(builtin shopt -p)"
    before_aliases="$(builtin alias -p)"
    before_traps="$(builtin trap -p)"
    before_args="$(builtin printf '%q ' "$@")"
    before_umask="$(builtin umask)"
    builtin readonly -a expected_functions
    builtin readonly -A expected_names mnemonic_before_functions
    builtin readonly before_pwd before_ifs before_options before_shopt \
      before_aliases before_traps before_args before_umask
    while IFS= read -r variable_name; do
      case "${variable_name}" in
        mnemonic_before_variables|variable_name|variable_declaration|\
        variable_declaration_after|\
        source_status|BASHPID|BASH_ARGC|BASH_ARGV|BASH_COMMAND|BASH_LINENO|\
        BASH_SOURCE|EPOCHREALTIME|EPOCHSECONDS|FUNCNAME|LINENO|PIPESTATUS|\
        PPID|RANDOM|SECONDS|SRANDOM|_) continue ;;
      esac
      variable_declaration="$(builtin declare -p "${variable_name}")" ||
        return 1
      mnemonic_before_variables["${variable_name}"]="${variable_declaration}"
    done < <(builtin compgen -A variable)
    if builtin source "${snapshot_mnemonic_sidecar}" >/dev/null 2>&1; then
      source_status=0
    else
      source_status=$?
    fi
    [[ ${source_status} -eq 0 && "${PWD}" == "${before_pwd}" &&
       "$(builtin printf %q "${IFS}")" == "${before_ifs}" &&
       "$(builtin set +o)" == "${before_options}" &&
       "$(builtin shopt -p)" == "${before_shopt}" &&
       "$(builtin alias -p)" == "${before_aliases}" &&
       "$(builtin trap -p)" == "${before_traps}" &&
       "$(builtin printf '%q ' "$@")" == "${before_args}" &&
       "$(builtin umask)" == "${before_umask}" ]] || return 1
    for variable_name in "${!mnemonic_before_variables[@]}"; do
      variable_declaration_after="$(builtin declare -p "${variable_name}")" ||
        return 1
      [[ "${variable_declaration_after}" == \
         "${mnemonic_before_variables[${variable_name}]}" ]] || return 1
    done
    while IFS= read -r variable_name; do
      case "${variable_name}" in
        mnemonic_before_variables|variable_name|variable_declaration|\
        variable_declaration_after|\
        source_status|BASHPID|BASH_ARGC|BASH_ARGV|BASH_COMMAND|BASH_LINENO|\
        BASH_SOURCE|EPOCHREALTIME|EPOCHSECONDS|FUNCNAME|LINENO|PIPESTATUS|\
        PPID|RANDOM|SECONDS|SRANDOM|_) continue ;;
      esac
      [[ -n "${mnemonic_before_variables[${variable_name}]+set}" ]] ||
        return 1
    done < <(builtin compgen -A variable)
    for function_name in "${expected_functions[@]}"; do
      [[ "$(builtin declare -p -F "${function_name}" 2>/dev/null)" == \
         "declare -f ${function_name}" ]] || return 1
    done
    for function_name in "${!mnemonic_before_functions[@]}"; do
      function_declaration="$(builtin declare -f "${function_name}")" ||
        return 1
      [[ "${function_declaration}" == \
         "${mnemonic_before_functions[${function_name}]}" ]] || return 1
    done
    while IFS= read -r function_name; do
      [[ -n "${expected_names[${function_name}]+set}" ||
         -n "${mnemonic_before_functions[${function_name}]+set}" ]] || return 1
    done < <(builtin compgen -A function)
  }

  declare -F deployment_payload_is_current >/dev/null 2>&1 &&
    declare -F deployment_payload_sha256 >/dev/null 2>&1 || return 70
  jq_path="$(builtin type -P jq 2>/dev/null)" || return 70
  mktemp_path="$(builtin type -P mktemp 2>/dev/null)" || return 70
  mkdir_path="$(builtin type -P mkdir 2>/dev/null)" || return 70
  cp_path="$(builtin type -P cp 2>/dev/null)" || return 70
  chmod_path="$(builtin type -P chmod 2>/dev/null)" || return 70
  rm_path="$(builtin type -P rm 2>/dev/null)" || return 70
  rmdir_path="$(builtin type -P rmdir 2>/dev/null)" || return 70
  bash_path="${BASH:-}"
  [[ "${jq_path}" == /* && -x "${jq_path}" &&
     "${mktemp_path}" == /* && -x "${mktemp_path}" &&
     "${mkdir_path}" == /* && -x "${mkdir_path}" &&
     "${cp_path}" == /* && -x "${cp_path}" &&
     "${chmod_path}" == /* && -x "${chmod_path}" &&
     "${rm_path}" == /* && -x "${rm_path}" &&
     "${rmdir_path}" == /* && -x "${rmdir_path}" &&
     "${bash_path}" == /* && -f "${bash_path}" && -x "${bash_path}" ]] ||
    return 70

  trap '_cntools_compatibility_cleanup' EXIT
  trap 'exit 70' HUP INT TERM

  deployment_payload_is_current >/dev/null 2>&1 || return 70
  receipt_hash="$(deployment_payload_sha256 "${receipt}")" || return 70
  metadata_hash="$(deployment_payload_sha256 "${metadata}")" || return 70
  generation_id="$("${jq_path}" -er '
    select(
      .schemaVersion == 2 and
      (.implementation == "cnode" or .implementation == "dingo") and
      (.cntoolsGeneration as $generation |
        $generation.fileCount == 152 and
        ($generation.id | type == "string" and test("^[0-9a-f]{64}$")) and
        $generation.path ==
          ("scripts/.cntools/generations/" + $generation.id))) |
    .cntoolsGeneration.id
  ' "${receipt}" 2>/dev/null)" || return 70
  generation="${state_root}/generations/${generation_id}"
  generation_manifest="${generation}/cntools/manifest.json"
  generation_receipt="${generation}/.generation.json"
  lifecycle="${generation}/cntools/core/lifecycle.sh"
  expected_lifecycle_hash="$("${jq_path}" -er '
    [.files[] | select(
      .path == "cntools/core/lifecycle.sh" and
      .source == "scripts/common-helper-scripts/cntools/core/lifecycle.sh" and
      .mode == "0444" and .validator == "shell")] |
    if length == 1 then .[0].sha256 else error("lifecycle") end
  ' "${generation_receipt}" 2>/dev/null)" || return 70
  [[ "$(deployment_payload_sha256 "${lifecycle}")" == \
       "${expected_lifecycle_hash}" ]] || return 70

  # shellcheck source=/dev/null
  builtin source "${lifecycle}" >/dev/null 2>&1 || return 70
  declare -F cntools_generation_validate >/dev/null 2>&1 &&
  declare -F cntools_generation_pointers_validate >/dev/null 2>&1 &&
    declare -F cntools_generation_lock_acquire >/dev/null 2>&1 &&
    declare -F cntools_generation_lock_release >/dev/null 2>&1 || return 70
  # Revalidate the full outer authority immediately before lock acquisition.
  # The currentness helper owns its own short lifecycle lock, so it must finish
  # before this longer action lock is acquired.
  deployment_payload_is_current >/dev/null 2>&1 || return 70
  current_receipt_hash="$(deployment_payload_sha256 "${receipt}")" || return 70
  current_metadata_hash="$(deployment_payload_sha256 "${metadata}")" || return 70
  current_generation_id="$("${jq_path}" -er '.cntoolsGeneration.id' \
    "${receipt}" 2>/dev/null)" || return 70
  [[ "${current_receipt_hash}" == "${receipt_hash}" &&
     "${current_metadata_hash}" == "${metadata_hash}" &&
     "${current_generation_id}" == "${generation_id}" ]] || return 70

  cntools_generation_lock_acquire "${state_root}" || return 70
  lock_acquired="Y"
  current_receipt_hash="$(deployment_payload_sha256 "${receipt}")" || return 70
  current_metadata_hash="$(deployment_payload_sha256 "${metadata}")" || return 70
  current_generation_id="$("${jq_path}" -er '.cntoolsGeneration.id' \
    "${receipt}" 2>/dev/null)" || return 70
  [[ "${current_receipt_hash}" == "${receipt_hash}" &&
     "${current_metadata_hash}" == "${metadata_hash}" &&
     "${current_generation_id}" == "${generation_id}" &&
     ! -e "${NODE_HOME}/.guild-deploy-transaction" &&
     ! -L "${NODE_HOME}/.guild-deploy-transaction" ]] || return 70
  cntools_generation_validate "${generation}" "${generation_id}" || return 70
  cntools_generation_pointers_validate "${state_root}" || return 70

  # The complete generation is now authenticated and locked. Load the fixed
  # compatibility toolchain, then snapshot only the allowlisted action bytes.
  # shellcheck source=/dev/null
  builtin source "${generation}/cntools/core/registry.sh" >/dev/null 2>&1 &&
    builtin source "${generation}/cntools/core/context.sh" >/dev/null 2>&1 &&
    builtin source "${generation}/cntools/core/result.sh" >/dev/null 2>&1 &&
    builtin source "${generation}/cntools/core/dispatcher.sh" >/dev/null 2>&1 ||
    return 70
  declare -F cntools_context_validate >/dev/null 2>&1 &&
    declare -F cntools_dispatcher_validate_action >/dev/null 2>&1 &&
    declare -F cntools_dispatcher_run_action >/dev/null 2>&1 &&
    declare -F cntools_result_validate >/dev/null 2>&1 &&
    declare -F _cntools_result_path_valid >/dev/null 2>&1 &&
    declare -F _cntools_result_stat >/dev/null 2>&1 &&
    declare -F _cntools_result_private_parent_validate >/dev/null 2>&1 &&
    declare -F _cntools_registry_path_has_no_symlinks >/dev/null 2>&1 ||
    return 70

  expected_module_hash="$("${jq_path}" -er \
    --arg path "${module_relative}" \
    --arg source "${module_source_relative}" '
      [.files[] | select(
        .path == $path and .source == $source and .mode == "0444" and
        .validator == "json" and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))] |
      if length == 1 then .[0].sha256 else error("module") end
    ' "${generation_receipt}" 2>/dev/null)" || return 70
  expected_action_hash="$("${jq_path}" -er \
    --arg path "${action_file_relative}" \
    --arg source "${action_source_relative}" '
      [.files[] | select(
        .path == $path and .source == $source and .mode == "0444" and
        .validator == "shell" and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))] |
      if length == 1 then .[0].sha256 else error("action") end
    ' "${generation_receipt}" 2>/dev/null)" || return 70
  source_module="${generation}/${module_relative}"
  source_action="${generation}/${action_file_relative}"

  if [[ "${mnemonic_sidecar_required}" == "Y" ]]; then
    mnemonic_metadata="$("${jq_path}" -er '
      .legacyBundle as $bundle |
      select(
        ($bundle | type == "object") and
        ($bundle | keys == ["facade","id","idAlgorithm",
          "logicalBodySha256","logicalBodySize","members","path",
          "schemaVersion"]) and
        $bundle.schemaVersion == 1 and
        $bundle.facade == "cntools.library" and
        $bundle.idAlgorithm == "sha256-cntools-legacy-bundle-v1" and
        ($bundle.id | type == "string" and test("^[0-9a-f]{64}$")) and
        $bundle.path == ("cntools/libs/legacy/" + $bundle.id) and
        ($bundle.logicalBodySha256 | type == "string" and
          test("^[0-9a-f]{64}$")) and
        ($bundle.logicalBodySize | type == "number" and . == floor and
          . > 0 and . <= 16777216) and
        ($bundle.members | type == "array")
      ) |
      [$bundle.members[] |
        select(.path == "050-wallet-create-registration.sh")] as $members |
      if ($members | length) == 1 and
         ($members[0] | keys == ["mode","path","sha256","size"]) and
         $members[0].mode == "0444" and
         ($members[0].sha256 | type == "string" and
           test("^[0-9a-f]{64}$")) and
         ($members[0].size | type == "number" and . == floor and
           . > 0 and . <= 16777216)
      then [$bundle.id,$bundle.path,$members[0].sha256,
        ($members[0].size | tostring)] | @tsv
      else error("mnemonic-sidecar") end
    ' "${generation_manifest}" 2>/dev/null)" || return 70
    IFS=$'\t' read -r legacy_bundle_id legacy_bundle_relative \
      expected_mnemonic_hash expected_mnemonic_size \
      <<< "${mnemonic_metadata}" || return 70
    [[ -n "${legacy_bundle_id}" && -n "${legacy_bundle_relative}" &&
       "${expected_mnemonic_hash}" =~ ^[0-9a-f]{64}$ &&
       "${expected_mnemonic_size}" =~ ^[0-9]+$ ]] || return 70
    mnemonic_member_relative="${legacy_bundle_relative}/050-wallet-create-registration.sh"
    mnemonic_member_source_relative="scripts/common-helper-scripts/${mnemonic_member_relative}"
    receipt_mnemonic_hash="$("${jq_path}" -er \
      --arg path "${mnemonic_member_relative}" \
      --arg source "${mnemonic_member_source_relative}" '
        [.files[] | select(.path == $path)] as $records |
        if ($records | length) == 1 and $records[0].source == $source and
           $records[0].mode == "0444" and
           $records[0].validator == "shell" and
           ($records[0].sha256 | type == "string" and
             test("^[0-9a-f]{64}$"))
        then $records[0].sha256 else error("mnemonic-sidecar") end
      ' "${generation_receipt}" 2>/dev/null)" || return 70
    [[ "${receipt_mnemonic_hash}" == "${expected_mnemonic_hash}" ]] ||
      return 70
    source_mnemonic_sidecar="${generation}/${mnemonic_member_relative}"
    _cntools_compatibility_generation_file_validate \
      "${source_mnemonic_sidecar}" 444 "${expected_mnemonic_hash}" \
      "${expected_mnemonic_size}" || return 70
    BASH_ENV=/dev/null ENV=/dev/null \
      "${bash_path}" --noprofile --norc -n \
      "${source_mnemonic_sidecar}" >/dev/null 2>&1 || return 70
  fi

  umask 077
  private_root="$("${mktemp_path}" -d \
    "${TMP_DIR%/}/cntools-compatibility.XXXXXXXX")" || return 70
  private_root="$(cd -P -- "${private_root}" >/dev/null 2>&1 && pwd -P)" ||
    return 70
  "${chmod_path}" 0700 "${private_root}" || return 70
  snapshot_directory="${private_root}/action"
  "${mkdir_path}" -- "${snapshot_directory}" >/dev/null 2>&1 || return 70
  "${chmod_path}" 0700 "${snapshot_directory}" || return 70
  snapshot_module="${snapshot_directory}/module.json"
  snapshot_action="${snapshot_directory}/action.sh"
  if [[ "${mnemonic_sidecar_required}" == "Y" ]]; then
    snapshot_mnemonic_sidecar="${private_root}/compatibility-wallet-mnemonic.sh"
  fi
  context_file="${private_root}/context.json"
  result_file="${private_root}/result.json"
  "${cp_path}" -- "${source_module}" "${snapshot_module}" \
    >/dev/null 2>&1 || return 70
  "${cp_path}" -- "${source_action}" "${snapshot_action}" \
    >/dev/null 2>&1 || return 70
  if [[ "${mnemonic_sidecar_required}" == "Y" ]]; then
    "${cp_path}" -- "${source_mnemonic_sidecar}" \
      "${snapshot_mnemonic_sidecar}" >/dev/null 2>&1 || return 70
  fi
  "${chmod_path}" 0400 "${snapshot_module}" "${snapshot_action}" || return 70
  if [[ "${mnemonic_sidecar_required}" == "Y" ]]; then
    "${chmod_path}" 0400 "${snapshot_mnemonic_sidecar}" || return 70
  fi
  node_home_physical="$(cd -P -- "${NODE_HOME}" >/dev/null 2>&1 && pwd -P)" ||
    return 70
  context_mode="${CNTOOLS_MODE,,}"
  "${jq_path}" -S \
    --arg mode "${context_mode}" \
    --arg node_home "${node_home_physical}" \
    --arg generation_version "$("${jq_path}" -er '.version' \
      "${generation_manifest}")" \
    --argjson advanced "$([[ "${ADVANCED_MODE}" == "true" ]] &&
      printf true || printf false)" \
    --argjson blocklog "$([[ -f "${BLOCKLOG_DB}" ]] &&
      printf true || printf false)" '
      {
        advanced: $advanced,
        apiVersion: 1,
        capabilities: ([
          if .capabilities.forging then "forging" else empty end,
          if .capabilities.localCli then "local-cli" else empty end,
          if .capabilities.metrics then "metrics" else empty end,
          if .capabilities.n2c then "n2c" else empty end
        ] | sort),
        features: (["advanced"] +
          (if $blocklog then ["blocklog"] else [] end) | sort),
        generationVersion: $generation_version,
        mode: $mode,
        nodeHome: $node_home,
        nodeImplementation: .implementation,
        nodeNetwork: .network,
        schemaVersion: 1
      }
    ' "${metadata}" > "${context_file}" || return 70
  "${chmod_path}" 0400 "${context_file}" || return 70
  expected_context_hash="$(deployment_payload_sha256 "${context_file}")" ||
    return 70

  _cntools_result_private_parent_validate "${private_root}" || return 70
  _cntools_result_private_parent_validate "${snapshot_directory}" || return 70
  _cntools_compatibility_private_file_validate \
    "${snapshot_module}" 400 "${expected_module_hash}" || return 70
  _cntools_compatibility_private_file_validate \
    "${snapshot_action}" 400 "${expected_action_hash}" || return 70
  if [[ "${mnemonic_sidecar_required}" == "Y" ]]; then
    _cntools_compatibility_private_file_validate \
      "${snapshot_mnemonic_sidecar}" 400 "${expected_mnemonic_hash}" \
      "${expected_mnemonic_size}" || return 70
    _cntools_compatibility_mnemonic_sidecar_contract_validate \
      "${snapshot_mnemonic_sidecar}" || return 70
    _cntools_compatibility_mnemonic_sidecar_source || return 70
  fi
  _cntools_compatibility_private_file_validate \
    "${context_file}" 400 "${expected_context_hash}" || return 70
  "${jq_path}" -e --arg id "${action_id}" '
    type == "object" and .kind == "action" and .id == $id
  ' "${snapshot_module}" >/dev/null 2>&1 || return 70
  cntools_context_validate "${context_file}" >/dev/null 2>&1 || return 70
  cntools_dispatcher_validate_action "${snapshot_directory}" \
    >/dev/null 2>&1 || return 70

  current_receipt_hash="$(deployment_payload_sha256 "${receipt}")" || return 70
  current_metadata_hash="$(deployment_payload_sha256 "${metadata}")" || return 70
  current_generation_id="$("${jq_path}" -er '.cntoolsGeneration.id' \
    "${receipt}" 2>/dev/null)" || return 70
  [[ "${current_receipt_hash}" == "${receipt_hash}" &&
     "${current_metadata_hash}" == "${metadata_hash}" &&
     "${current_generation_id}" == "${generation_id}" &&
     ! -e "${NODE_HOME}/.guild-deploy-transaction" &&
     ! -L "${NODE_HOME}/.guild-deploy-transaction" ]] || return 70

  # The action and its context are now an authenticated private snapshot. The
  # generation lock must be gone before any action-owned prompt or wait runs.
  cntools_generation_lock_release "${state_root}" >/dev/null 2>&1 || return 70
  lock_acquired="N"
  _cntools_compatibility_private_file_validate \
    "${snapshot_module}" 400 "${expected_module_hash}" || return 70
  _cntools_compatibility_private_file_validate \
    "${snapshot_action}" 400 "${expected_action_hash}" || return 70
  if [[ "${mnemonic_sidecar_required}" == "Y" ]]; then
    _cntools_compatibility_private_file_validate \
      "${snapshot_mnemonic_sidecar}" 400 "${expected_mnemonic_hash}" \
      "${expected_mnemonic_size}" || return 70
  fi
  _cntools_compatibility_private_file_validate \
    "${context_file}" 400 "${expected_context_hash}" || return 70

  if cntools_dispatcher_run_action "${snapshot_directory}" \
      "${context_file}" "${result_file}" "$@"; then
    action_status=0
  else
    action_status=$?
  fi
  if [[ -e "${result_file}" || -L "${result_file}" ]]; then
    cntools_result_validate "${result_file}" >/dev/null 2>&1 ||
      action_status=70
  fi

  _cntools_compatibility_cleanup
  trap - EXIT HUP INT TERM
  [[ ${cleanup_status} -eq 0 ]] || action_status=70
  return "${action_status}"
)

###################################################################

function main {
  while true; do # Main loop
    # Start with a clean slate after each completed or canceled command excluding .dialogrc from purge
    find "${TMP_DIR:?}" -type f -not \( -name 'protparams.json' -o -name '.dialogrc' -o -name "offline_tx*" -o -name "*_cntools_backup*" -o -name "metadata_*" -o -name "asset*" \) -delete
    unset IFS
    clear
    if [[ ${CNTOOLS_MODE} != "OFFLINE" ]]; then
      [[ ${CNTOOLS_MODE} = "LOCAL" ]] && getNodeMetrics
      getPriceInfo
      updateProtocolParams
    fi
    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println "$(printf " >> Koios CNTools v%s - %s - ${CNTOOLS_MODE_COLOR}%s${NC} <<" "${CNTOOLS_VERSION}" "${NETWORK_NAME}" "${CNTOOLS_MODE}")"
    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println OFF " Main Menu    Telegram Announcement / Support channel: ${FG_YELLOW}t.me/CardanoKoios/9759${NC}\n"\
			" ) Wallet      - create, show, remove and protect wallets"\
			" ) Funds       - send, withdraw and delegate"\
			" ) Pool        - pool creation and management"\
			" ) Transaction - Sign and Submit a cold transaction (hybrid/offline mode)"\
			" ) Vote        - project funding (Catalyst) and blockchain governance"\
			"$([[ -f "${BLOCKLOG_DB}" ]] && echo " ) Blocks      - show core node leader schedule & block production statistics")"\
			" ) Backup      - backup & restore of wallet/pool/config"\
			"$([[ ${ADVANCED_MODE} = true ]] && echo " ) Advanced    - Developer and advanced features: metadata, assets, ...")"\
			" ) Refresh     - reload home screen content"\
			"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    println DEBUG "$(printf "%84s" "Epoch $(getEpoch) - $(timeLeft "$(timeUntilNextEpoch)") until next")"
    if [[ ${CNTOOLS_MODE} != "LOCAL" ]]; then
      println DEBUG " What would you like to do?"
    else
      tip_diff=$(( $(getSlotTipRef) - slotnum ))
      slot_interval=$(slotInterval)
      if [[ ${tip_diff} -le ${slot_interval} ]]; then
        println DEBUG "$(printf " What would you like to do? %$((84-29-${#tip_diff}-3))s ${FG_GREEN}%s${NC}" "Node Sync:" "${tip_diff} :)")"
      elif [[ ${tip_diff} -le $(( slot_interval * 2 )) ]]; then
        println DEBUG "$(printf " What would you like to do? %$((84-29-${#tip_diff}-3))s ${FG_YELLOW}%s${NC}" "Node Sync:" "${tip_diff} :|")"
      else
        println DEBUG "$(printf " What would you like to do? %$((84-29-${#tip_diff}-3))s ${FG_RED}%s${NC}" "Node Sync:" "${tip_diff} :(")"
      fi
    fi
    if [[ -n ${price_now} ]]; then
      getDecimalPlaces ${price_now}
      decimals=$?
      price_str="1 ADA = $(LC_NUMERIC=C printf "%.${decimals}f" "${price_now}") ${CURRENCY^^}"
      if [[ ${price_24h:0:1} = '-' ]]; then
        println DEBUG "$(printf "%$((84-${#price_24h}-9))s (24h: ${FG_RED}%s${NC}%%)" "${price_str}" "${price_24h}")"
      else
        println DEBUG "$(printf "%$((84-${#price_24h}-9))s (24h: ${FG_GREEN}%s${NC}%%)" "${price_str}" "${price_24h}")"
      fi
    else
      echo
    fi
    select_opt "[w] Wallet" "[f] Funds" "[p] Pool" "[t] Transaction" "[v] Vote" "$([[ -f "${BLOCKLOG_DB}" ]] && echo "[b] Blocks")" "[z] Backup & Restore" "$([[ ${ADVANCED_MODE} = true ]] && echo "[a] Advanced")" "[r] Refresh" "[q] Quit"
    case ${selected_value} in
      "[w]"*) OPERATION="wallet" ;;
      "[f]"*) OPERATION="funds" ;;
      "[p]"*) OPERATION="pool" ;;
      "[t]"*) OPERATION="transaction" ;;
      "[v]"*) OPERATION="vote" ;;
      "[b]"*) OPERATION="blocks" ;;
      "[z]"*) OPERATION="backup" ;;
      "[a]"*) OPERATION="advanced" ;;
      "[r]"*) continue ;;
      "[q]"*) myExit 0 "CNTools closed!" ;;
    esac
    case $OPERATION in
      wallet)
        while true; do # Wallet loop
          clear
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println " >> WALLET"
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println OFF " Wallet Management\n\n ) New         - create a new wallet"\
						" ) Import      - import a 24/15 mnemonic or Ledger/Trezor HW wallet"\
						" ) Register    - register a wallet on chain"\
						" ) De-Register - De-Register (retire) a registered wallet"\
						" ) List        - list all available wallets in a compact view"\
						" ) Show        - show detailed view of a specific wallet"\
						" ) Remove      - remove a wallet"\
						" ) Decrypt     - remove write protection and decrypt wallet"\
						" ) Encrypt     - encrypt wallet keys and make all files immutable"\
						"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println DEBUG " Select Wallet Operation\n"
          select_opt "[n] New" "[i] Import" "[r] Register" "[z] De-Register" "[l] List" "[s] Show" "[x] Remove" "[d] Decrypt" "[e] Encrypt" "[h] Home"
          case $? in
            0) SUBCOMMAND="new" ;;
            1) SUBCOMMAND="import" ;;
            2) SUBCOMMAND="register" ;;
            3) SUBCOMMAND="deregister" ;;
            4) SUBCOMMAND="list" ;;
            5) SUBCOMMAND="show" ;;
            6) SUBCOMMAND="remove" ;;
            7) SUBCOMMAND="decrypt" ;;
            8) SUBCOMMAND="encrypt" ;;
            9) break ;;
          esac
          case $SUBCOMMAND in
            new)
              while true; do # Wallet >> New loop
                clear
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println " >> WALLET >> NEW"
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println OFF " Wallet New\n"\
                  " ) Mnemonic - based on 24 word generated passphrase (recommended)"\
                  " ) CLI      - one-time generated keys"\
                  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println DEBUG " Select Wallet Creation Type\n"
                select_opt "[m] Mnemonic" "[c] CLI" "[b] Back" "[h] Home"
                case $? in
                  0) SUBCOMMAND="mnemonic" ;;
                  1) SUBCOMMAND="cli" ;;
                  2) break ;;
                  3) break 2 ;;
                esac
                case $SUBCOMMAND in
                  mnemonic)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> WALLET >> NEW >> MNEMONIC"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    createNewWallet || continue
                    unset mnemonic
                    createMnemonicWallet || continue
                    echo
                    println "Wallet Imported : ${FG_GREEN}${wallet_name}${NC}"
                    println "Address         : ${FG_LGRAY}${base_addr}${NC}"
                    println "Payment Address : ${FG_LGRAY}${pay_addr}${NC}"
                    echo
                    word_len=0
                    for word in "${words[@]}"; do
                      [[ ${#word} -gt ${word_len} ]] && word_len=${#word}
                    done
                    println DEBUG "${FG_YELLOW}IMPORTANT!${NC} Please write down and store below words in a secure place to be able to restore wallet at a later time."
                    for i in "${!words[@]}"; do
                      idx=$(( i + 1 ))
                      printf "%2s: ${FG_GREEN}%-${word_len}s${NC}  " "$idx" "${words[$i]}"
                      [[ $(( idx % 4 )) -eq 0 ]] && echo
                    done
                    unset words
                    echo
                    printWalletInfo
                    waitToProceed && continue
                    ;; ###################################################################
                  cli)
                    cntools_compatibility_dispatch_action wallet.new.cli
                    action_status=$?
                    case "${action_status}" in
                      0|21) continue ;;
                      20) break 2 ;;
                      22) myExit 0 "CNTools closed!" ;;
                      *) waitToProceed; continue ;;
                    esac
                    ;; ###################################################################
                esac # wallet >> new sub OPERATION
              done # Wallet >> new loop
              ;; ###################################################################
            import)
              while true; do # Wallet >> Import loop
                clear
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println " >> WALLET >> IMPORT"
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println OFF " Wallet Import\n"\
									" ) Mnemonic  - 24 or 15 word mnemonic"\
									" ) HW Wallet - Ledger/Trezor hardware wallet"\
									"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println DEBUG " Select Wallet Import Operation\n"
                select_opt "[m] Mnemonic" "[w] HW Wallet" "[b] Back" "[h] Home"
                case $? in
                  0) SUBCOMMAND="mnemonic" ;;
                  1) SUBCOMMAND="hardware" ;;
                  2) break ;;
                  3) break 2 ;;
                esac
                case $SUBCOMMAND in
                  mnemonic)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> WALLET >> IMPORT >> MNEMONIC"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    createNewWallet || continue
                    getAnswerAnyCust mnemonic false "24 or 15 word mnemonic(space separated)"
                    echo
                    IFS=" " read -r -a words <<< "${mnemonic}"
                    if [[ ${#words[@]} -ne 24 ]] && [[ ${#words[@]} -ne 15 ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: 24 or 15 words expected, found ${FG_RED}${#words[@]}${NC}"
                      echo && safeDel "${WALLET_FOLDER}/${wallet_name}"
                      unset mnemonic; unset words
                      waitToProceed && continue
                    fi
                    createMnemonicWallet || continue
                    echo
                    println "Wallet Imported : ${FG_GREEN}${wallet_name}${NC}"
                    println "Address         : ${FG_LGRAY}${base_addr}${NC}"
                    println "Payment Address : ${FG_LGRAY}${pay_addr}${NC}"
                    echo
                    printWalletInfo
                    waitToProceed && continue
                    ;; ###################################################################
                  hardware)
                    cntools_compatibility_dispatch_action wallet.import.hardware
                    case $? in
                      0|21) continue ;;
                      20) break 2 ;;
                      22) myExit 0 "CNTools closed!" ;;
                      *) waitToProceed; continue ;;
                    esac
                    ;; ###################################################################
                esac # wallet >> import sub OPERATION
              done # Wallet >> Import loop
              ;; ###################################################################
            register)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> REGISTER"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "Select wallet to register (only non-registered wallets shown)"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "non-reg"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                esac
              else
                selectWallet "non-reg"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              getWalletBalance ${wallet_name} true true false true
              if [[ ${base_lovelace} -gt 0 ]]; then
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Funds in wallet:"  "$(formatLovelace ${base_lovelace})")"
                fi
              else
                println ERROR "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                println DEBUG "Funds for key deposit($(formatLovelace ${KEY_DEPOSIT}) ADA) + transaction fee needed to register the wallet"
                waitToProceed && continue
              fi
              if ! registerStakeWallet ${wallet_name} "true"; then
                waitToProceed && continue
              fi
              println "${FG_GREEN}${wallet_name}${NC} successfully registered on chain!"
              waitToProceed && continue
              ;; ###################################################################
            deregister)
              cntools_compatibility_dispatch_action wallet.deregister
              action_status=$?
              case "${action_status}" in
                0|21) continue ;;
                20) break ;;
                22) myExit 0 "CNTools closed!" ;;
                *) waitToProceed; continue ;;
              esac
              ;; ###################################################################
            list)
              cntools_compatibility_dispatch_action wallet.list
              action_status=$?
              case "${action_status}" in
                0|21) continue ;;
                20) break ;;
                22) myExit 0 "CNTools closed!" ;;
                *) waitToProceed; continue ;;
              esac
              ;; ###################################################################
            show)
              cntools_compatibility_dispatch_action wallet.show
              action_status=$?
              case "${action_status}" in
                0|21) continue ;;
                20) break ;;
                22) myExit 0 "CNTools closed!" ;;
                *) waitToProceed; continue ;;
              esac
              ;; ###################################################################
            remove)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> WALLET >> REMOVE"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "${FG_LGRAY}OFFLINE MODE${NC}: CNTools started in offline mode, unable to verify wallet balance"
              fi
              echo
              println DEBUG "Select wallet to remove"
              selectWallet "balance"
              case $? in
                1) waitToProceed; continue ;;
                2) continue ;;
              esac
              echo
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "Are you sure to delete wallet ${FG_GREEN}${wallet_name}${NC}?"
                select_opt "[y] Yes" "[n] No"
                case $? in
                  0) echo && safeDel "${WALLET_FOLDER:?}/${wallet_name}"
                    ;;
                  1) echo && println "skipped removal process for ${FG_GREEN}$wallet_name${NC}"
                    ;;
                esac
                waitToProceed && continue
              fi
              if ! getBaseAddress ${wallet_name} && ! getPayAddress ${wallet_name}; then
                println DEBUG "${FG_RED}WARN${NC}: unable to get address for wallet and do a balance check"
                println DEBUG "\nAre you sure to delete wallet ${FG_GREEN}${wallet_name}${NC} anyway?"
                select_opt "[y] Yes" "[n] No"
                case $? in
                  0) echo && safeDel "${WALLET_FOLDER:?}/${wallet_name}"
                    ;;
                  1) echo && println "skipped removal process for ${FG_GREEN}$wallet_name${NC}"
                    ;;
                esac
                waitToProceed && continue
              fi
              getWalletBalance ${wallet_name}
              getWalletRewards ${wallet_name}
              if [[ ${base_lovelace} -eq 0 && ${pay_lovelace} -eq 0 && ${reward_lovelace} -le 0 ]]; then
                println DEBUG "INFO: This wallet appears to be empty"
                println DEBUG "${FG_RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup\n"
                println DEBUG "Are you sure to delete wallet ${FG_GREEN}${wallet_name}${NC}?"
                select_opt "[y] Yes" "[n] No"
                case $? in
                  0) echo && safeDel "${WALLET_FOLDER:?}/${wallet_name}"
                    ;;
                  1) echo && println "skipped removal process for ${FG_GREEN}$wallet_name${NC}"
                    ;;
                esac
              else
                println "${FG_RED}WARN${NC}: wallet ${FG_GREEN}${wallet_name}${NC} not empty!"
                [[ ${base_lovelace} -gt 0 ]] && println "Base Funds : ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"
                [[ ${pay_lovelace} -gt 0 ]] && println "Payment Funds : ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"
                [[ ${reward_lovelace} -gt 0 ]] && println "Rewards : ${FG_LBLUE}$(formatLovelace ${reward_lovelace})${NC} ADA"
                echo
                println DEBUG "${FG_RED}WARN${NC}: Deleting this wallet is final and you can not recover it unless you have a backup\n"
                println DEBUG "Are you sure to delete wallet ${FG_GREEN}${wallet_name}${NC}?"
                select_opt "[y] Yes" "[n] No"
                case $? in
                  0) echo && safeDel "${WALLET_FOLDER:?}/${wallet_name}"
                    ;;
                  1) echo && println "skipped removal process for ${FG_GREEN}$wallet_name${NC}"
                    ;;
                esac
              fi
              waitToProceed && continue
              ;; ###################################################################
            decrypt)
              cntools_compatibility_dispatch_action wallet.decrypt
              action_status=$?
              case "${action_status}" in
                0|21) continue ;;
                20) break ;;
                22) myExit 0 "CNTools closed!" ;;
                *) waitToProceed; continue ;;
              esac
              ;; ###################################################################
            encrypt)
              cntools_compatibility_dispatch_action wallet.encrypt
              action_status=$?
              case "${action_status}" in
                0|21) continue ;;
                20) break ;;
                22) myExit 0 "CNTools closed!" ;;
                *) waitToProceed; continue ;;
              esac
              ;; ###################################################################
          esac # wallet sub OPERATION
        done # Wallet loop
        ;; ###################################################################
      funds)
        while true; do # Funds loop
          clear
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println " >> FUNDS"
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println OFF " Handle Funds\n"\
						" ) Send     - send ADA and/or custom Assets from a local wallet"\
						" ) Delegate - delegate wallet to a pool"\
						" ) Withdraw - withdraw earned rewards to base address"\
						"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println DEBUG " Select Funds Operation\n"
          select_opt "[s] Send" "[d] Delegate" "[w] Withdraw Rewards" "[h] Home"
          case $? in
            0) SUBCOMMAND="send" ;;
            1) SUBCOMMAND="delegate" ;;
            2) SUBCOMMAND="withdrawrewards" ;;
            3) break ;;
          esac
          case $SUBCOMMAND in
            send)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> FUNDS >> SEND"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo

              # source wallet
              println DEBUG "Select ${FG_YELLOW}source${NC} wallet"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "balance"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                esac
              else
                selectWallet "balance"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              s_wallet="${wallet_name}"
              s_payment_vk_file="${payment_vk_file}"
              s_payment_sk_file="${payment_sk_file}"
              getWalletBalance ${s_wallet} true true true true
              if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
                # Both payment and base address available with funds, let user choose what to use
                println DEBUG "Select source wallet address"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
                select_opt "[b] Base (default)" "[e] Payment" "[Esc] Cancel"
                case $? in
                  0) s_addr="${base_addr}" ;;
                  1) s_addr="${pay_addr}" ;;
                  2) continue ;;
                esac
                echo
              elif [[ ${pay_lovelace} -gt 0 ]]; then
                s_addr="${pay_addr}"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA\n" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
              elif [[ ${base_lovelace} -gt 0 ]]; then
                s_addr="${base_addr}"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA\n" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                fi
              else
                println ERROR "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${s_wallet}${NC}"
                waitToProceed && continue
              fi

              # Destination
              d_wallet=""
              println DEBUG "Select ${FG_YELLOW}destination${NC} type"
              select_opt "[w] Wallet" "[a] Address" "[Esc] Cancel"
              case $? in
                0) selectWallet "cache"
                  case $? in
                    1) waitToProceed; continue ;;
                    2) continue ;;
                  esac
                  d_wallet="${wallet_name}"
                  getBaseAddress ${d_wallet}
                  getPayAddress ${d_wallet}
                  if [[ -n "${base_addr}" && "${base_addr}" != "${s_addr}" && -n "${pay_addr}" && "${pay_addr}" != "${s_addr}" ]]; then
                    # Both base and payment address available, let user choose what to use
                    select_opt "[b] Base (default)" "[e] Payment" "[Esc] Cancel"
                    case $? in
                      0) d_addr="${base_addr}" ;;
                      1) d_addr="${pay_addr}" ;;
                      2) continue ;;
                    esac
                  elif [[ -n "${base_addr}" && "${base_addr}" != "${s_addr}" ]]; then
                    d_addr="${base_addr}"
                  elif [[ -n "${pay_addr}" && "${pay_addr}" != "${s_addr}" ]]; then
                    d_addr="${pay_addr}"
                  elif [[ "${base_addr}" = "${s_addr}" || "${pay_addr}" = "${s_addr}" ]]; then
                    println ERROR "\n${FG_RED}ERROR${NC}: sending to same address as source not supported"
                    waitToProceed && continue
                  else
                    println ERROR "\n${FG_RED}ERROR${NC}: no address found for wallet ${FG_GREEN}${d_wallet}${NC} :("
                    waitToProceed && continue
                  fi
                  ;;
                1) getAnswerAnyCust d_addr "Address" ;;
                2) continue ;;
              esac
              # Destination could be empty, if so without getting a valid address
              if [[ -z ${d_addr} ]]; then
                println ERROR "${FG_RED}ERROR${NC}: destination address field empty"
                waitToProceed && continue
              fi

              if [[ ${CNTOOLS_MODE} = "LOCAL" ]]; then
                getBalance ${s_addr} # need to re-fetch balance if CLI due to possibly being overwritten by payment balance lookup
                unset index_prefix
              else
                index_prefix="${s_addr},"
              fi
              declare -gA assets_left=()
              declare -gA assets_to_send=()
              for asset in "${!assets[@]}"; do
                [[ -n ${index_prefix} && ${asset} != ${index_prefix}* ]] && continue
                assets_left[${asset#*,}]=${assets[${asset}]}
              done

              # Add additional assets to transaction?
              if [[ ${#assets_left[@]} -gt 1 ]]; then
                println DEBUG "Additional assets found on address, include in transaction?"
                select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                case $? in
                  0) : ;;
                  1) declare -A assets_on_addr=()
                    for asset in "${!assets_left[@]}"; do
                      [[ ${asset} = "lovelace" ]] && continue
                      IFS='.' read -ra asset_arr <<< "${asset}"
                      assets_on_addr["${asset} ($(hexToAscii ${asset_arr[1]}))"]=0 # only interested in the key
                    done
                    while true; do
                      select_opt "${!assets_on_addr[@]}" "[Esc] Cancel"
                      selection=$?
                      [[ ${selected_value} = "[Esc] Cancel" ]] && continue 2
                      IFS=' ' read -ra selection_arr <<< "${selected_value}"
                      println DEBUG "Available to send: ${FG_LBLUE}$(formatAsset ${assets_left[${selection_arr[0]}]})${NC}"
                      getAnswerAnyCust asset_amount "Amount (commas allowed as thousand separator)"
                      asset_amount="${asset_amount//,}"
                      [[ ${asset_amount} = "all" ]] && asset_amount=${assets_left[${selection_arr[0]}]}
                      if ! isNumber ${asset_amount}; then println ERROR "${FG_RED}ERROR${NC}: invalid number, non digit characters found!" && continue; fi
                      if [[ ${asset_amount} -gt ${assets_left[${selection_arr[0]}]} ]]; then
                        println ERROR "${FG_RED}ERROR${NC}: you cant send more assets than available on address!" && continue
                      elif [[ ${asset_amount} -eq ${assets_left[${selection_arr[0]}]} ]]; then
                        unset "assets_left[${selection_arr[0]}]"
                      else
                        assets_left[${selection_arr[0]}]=$(( assets_left[${selection_arr[0]}] - asset_amount ))
                      fi
                      assets_to_send[${selection_arr[0]}]=${asset_amount}
                      unset "assets_on_addr[${selected_value}]"
                      [[ ${#assets_on_addr[@]} -eq 0 ]] && break
                      println DEBUG "Add more assets?"
                      select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                      case $? in
                        0) break ;;
                        1) : ;;
                        2) continue 2 ;;
                      esac
                    done
                    ;;
                  2) continue ;;
                esac
              fi

              # Amount
              assets_tx_out_d=""
              for idx in "${!assets_to_send[@]}"; do
                [[ ${idx} = "lovelace" ]] && continue
                [[ ${assets_to_send[${idx}]} -gt 0 ]] && assets_tx_out_d+="+${assets_to_send[${idx}]} ${idx}"
              done
              getMinUTxO "${d_addr}+1${assets_tx_out_d}"
              println DEBUG "\nAmount to Send (in ADA)"
              println DEBUG " Valid entry:"
              println DEBUG "   ${FG_LGRAY}>${NC} Integer (e.g. 15) or Decimal (e.g. 956.1235), commas allowed as thousand separator"
              println DEBUG "   ${FG_LGRAY}>${NC} The string '${FG_YELLOW}all${NC}' sends all available funds in source wallet"
              println DEBUG " Asset Info:"
              println DEBUG "   ${FG_LGRAY}>${NC} If '${FG_YELLOW}all${NC}' is used and the wallet contain multiple assets,"
              println DEBUG "   ${FG_LGRAY}>${NC} you will be asked to transfer all assets (incl ADA) to the destination address"
              println DEBUG " Minimum Amount: ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA"
              getAnswerAnyCust amountADA "Amount (ADA)"
              amountADA="${amountADA//,}"
              echo
              if  [[ ${amountADA} != "all" ]]; then
                if ! amount_lovelace=$(ADAToLovelace "${amountADA}"); then waitToProceed && continue; fi
                [[ ${amount_lovelace} -gt ${assets[${index_prefix}lovelace]} ]] && println ERROR "${FG_RED}ERROR${NC}: not enough funds on address, ${FG_LBLUE}$(formatLovelace ${assets[${index_prefix}lovelace]})${NC} ADA available but trying to send ${FG_LBLUE}$(formatLovelace ${amount_lovelace})${NC} ADA" && waitToProceed && continue
                if [[ ${amount_lovelace} -lt ${assets[${index_prefix}lovelace]} ]]; then
                  println DEBUG "Fee payed by sender? [else amount sent is reduced]"
                  select_opt "[y] Yes" "[n] No" "[Esc] Cancel"
                  case $? in
                    0) include_fee="no" ;;
                    1) include_fee="yes" ;;
                    2) continue ;;
                  esac
                else
                  include_fee="yes"
                fi
              else
                amount_lovelace=${assets[${index_prefix}lovelace]}
                println DEBUG "ADA to send set to total supply: ${FG_LBLUE}$(formatLovelace ${amount_lovelace})${NC}"
                include_fee="yes"
              fi

              if [[ ${amount_lovelace} -eq ${assets[${index_prefix}lovelace]} ]]; then
                if [[ ${#assets_left[@]} -gt 1 ]]; then
                  println DEBUG "\nAll ADA selected to be sent, automatically add all tokens?"
                  select_opt "[y] Yes" "[n] No" "[Esc] Cancel"
                  case $? in
                    0) declare -gA assets_left=()
                       declare -gA assets_to_send=()
                       for asset in "${!assets[@]}"; do
                         [[ -n ${index_prefix} && ${asset} != ${index_prefix}* ]] && continue
                         assets_to_send[${asset#*,}]=${assets[${asset}]} # add all assets, e.g clone assets array to assets_to_send
                       done
                       ;;
                    1) println ERROR "${FG_RED}ERROR${NC}: Unable to send all ADA as there are additional assets left on address not selected to be sent" && waitToProceed && continue ;;
                    2) continue ;;
                  esac
                else
                  unset assets_left
                  assets_to_send[lovelace]=${amount_lovelace}
                fi
              else
                assets_left[lovelace]=$(( assets_left[lovelace] - amount_lovelace ))
                assets_to_send[lovelace]=${amount_lovelace}
              fi

              # Optional metadata/message
              println "\nAdd a message to the transaction?"
              select_opt "[n] No" "[y] Yes"
              case $? in
                0)  unset metafile ;;
                1)  metafile="${TMP_DIR}/metadata_$(date '+%Y%m%d%H%M%S').json"
                    DEFAULTEDITOR="$(command -v nano &>/dev/null && echo 'nano' || echo 'vi')"
                    println OFF "\nA maximum of 64 characters(bytes) is allowed per line."
                    println OFF "${FG_YELLOW}Please don't change default file path when saving.${NC}"
                    waitToProceed "press any key to open '${FG_LGRAY}${DEFAULTEDITOR}${NC}' text editor"
                    ${DEFAULTEDITOR} "${metafile}"
                    if [[ ! -f "${metafile}" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: file not found"
                      println ERROR "File: ${FG_LGRAY}${metafile}${NC}"
                      waitToProceed && continue
                    fi
                    tput cuu 4 && tput ed
                    if [[ ! -s ${metafile} ]]; then
                      println "Message empty, skip and continue with transaction without message? No to abort!"
                      select_opt "[y] Yes" "[n] No"
                      case $? in
                        0) unset metafile ;;
                        1) continue ;;
                      esac
                    else
                      tx_msg='{"674":{"msg":[]}}'
                      error=""
                      while IFS="" read -r line || [[ -n "${line}" ]]; do
                        line_bytes=$(echo -n "${line}" | wc -c)
                        if [[ ${line_bytes} -gt 64 ]]; then
                          error="${FG_RED}ERROR${NC}: line contains more that 64 bytes(characters) [${line_bytes}]\nLine: ${FG_LGRAY}${line}${NC}" && break
                        fi
                        if ! tx_msg=$(jq -er ".\"674\".msg += [\"${line}\"]" <<< "${tx_msg}" 2>&1); then
                          error="${FG_RED}ERROR${NC}: ${tx_msg}" && break
                        fi
                      done < "${metafile}"
                      [[ -n ${error} ]] && println ERROR "${error}" && waitToProceed && continue
                      jq -c . <<< "${tx_msg}" > "${metafile}"
                      jq -r . "${metafile}" && echo
                      println LOG "Transaction message: ${tx_msg}"
                    fi
                    ;;
              esac

              if ! sendAssets; then
                waitToProceed && continue
              fi
              echo
              if ! verifyTx ${s_addr}; then waitToProceed && continue; fi
              getAddressBalance ${s_addr} true
              s_balance=${lovelace}
              getAddressBalance ${d_addr} true
              d_balance=${lovelace}
              getPayAddress ${s_wallet}
              [[ "${pay_addr}" = "${s_addr}" ]] && s_wallet_type=" (payment)" || s_wallet_type=""
              echo
              println "Transaction"
              println "  From          : ${FG_GREEN}${s_wallet}${NC}${s_wallet_type}"
              println "  Amount        : ${FG_LBLUE}$(formatLovelace ${amount_lovelace})${NC} ADA"
              for idx in "${!assets_to_send[@]}"; do
                [[ ${idx} = "lovelace" ]] && continue
                println "                  ${FG_LBLUE}$(formatAsset ${assets_to_send[${idx}]})${NC} ${FG_LGRAY}${idx}${NC}"
              done
              if [[ -n "${d_wallet}" ]]; then
                getPayAddress ${d_wallet}
                [[ "${pay_addr}" = "${d_addr}" ]] && d_wallet_type=" (payment)" || d_wallet_type=""
                println "  To            : ${FG_GREEN}${d_wallet}${NC}${d_wallet_type}"
              else
                println "  To            : ${FG_LGRAY}${d_addr}${NC}"
              fi
              println "  Fees          : ${FG_LBLUE}$(formatLovelace ${min_fee})${NC} ADA"
              println "  Balance"
              println "  - Source      : ${FG_LBLUE}$(formatLovelace ${s_balance})${NC} ADA"
              println "  - Destination : ${FG_LBLUE}$(formatLovelace ${d_balance})${NC} ADA"
              waitToProceed && continue
              ;; ###################################################################
            delegate)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> FUNDS >> DELEGATE"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "Select wallet to delegate"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "delegate"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                esac
              else
                selectWallet "delegate"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              getWalletBalance ${wallet_name} true true false true
              if [[ ${base_lovelace} -gt 0 ]]; then
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Funds on address:"  "$(formatLovelace ${base_lovelace})")"
                fi
              else
                println ERROR "\n${FG_RED}ERROR${NC}: no base funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                waitToProceed && continue
              fi
              if ! isWalletRegistered ${wallet_name}; then
                if [[ ${op_mode} = "online" ]]; then
                  if ! registerStakeWallet ${wallet_name}; then waitToProceed && continue; fi
                  # re-fetch balance to get a fresh set of utxos
                  getWalletBalance ${wallet_name} true true false true
                else
                  println ERROR "\n${FG_YELLOW}The wallet is not a registered wallet on chain and CNTools run in hybrid mode${NC}"
                  println ERROR "Please first register the wallet using 'Wallet >> Register'"
                  waitToProceed && continue
                fi
              fi
              echo
              println DEBUG "Do you want to delegate to a local CNTools pool or specify the pool ID?"
              select_opt "[p] CNTools Pool" "[i] Pool ID" "[Esc] Cancel"
              case $? in
                0) selectPool "reg" "${POOL_COLDKEY_VK_FILENAME}"
                  case $? in
                    1) waitToProceed; continue ;;
                    2) continue ;;
                  esac
                  getPoolID "${pool_name}"
                  ;;
                1) getAnswerAnyCust pool_id "Pool ID (blank to cancel)"
                  [[ -z "${pool_id}" ]] && continue
                  pool_name="${pool_id}"
                  ;;
                2) continue ;;
              esac
              if ! delegate; then
                if [[ ${op_mode} = "online" ]]; then
                  echo && println ERROR "${FG_RED}ERROR${NC}: failure during delegation, removing newly created delegation certificate file"
                  rm -f "${pool_delegcert_file}"
                fi
                waitToProceed && continue
              fi
              echo
              if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
              getWalletBalance ${wallet_name} true true false
              echo
              println "Delegation successfully registered"
              println "Wallet : ${FG_GREEN}${wallet_name}${NC}"
              println "Pool   : ${FG_GREEN}${pool_name}${NC}"
              println "Amount : ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"
              waitToProceed && continue
              ;; ###################################################################
            withdrawrewards)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> FUNDS >> WITHDRAW REWARDS"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "Select wallet to withdraw funds from"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "reward"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                esac
              else
                selectWallet "reward"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              echo
              getWalletBalance ${wallet_name} true true false true
              getWalletRewards ${wallet_name}
              if [[ ${reward_lovelace} -le 0 ]]; then
                println ERROR "Failed to locate any rewards associated with the chosen wallet, please try another one"
                waitToProceed && continue
              elif [[ ${base_lovelace} -eq 0 ]]; then
                println ERROR "${FG_YELLOW}WARN${NC}: No funds on base address, please send funds to base address of wallet to cover withdraw transaction fee"
                waitToProceed && continue
              fi
              println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Base Funds" "$(formatLovelace ${base_lovelace})")"
              println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Rewards" "$(formatLovelace ${reward_lovelace})")"
              if versionCheck "10.0" "${PROT_VERSION}" && ! getWalletVoteDelegation ${wallet_name}; then
                println ERROR "Reward withdrawal is blocked until wallet is vote delegated to a DRep or one of the predefined roles."
                waitToProceed && continue
              fi
              if ! withdrawRewards; then
                waitToProceed && continue
              fi
              echo
              if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
              getWalletBalance ${wallet_name} true true false
              echo
              println "Rewards successfully withdrawn"
              println "Base Funds (new balance) : ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"
              waitToProceed && continue
              ;; ###################################################################
          esac # funds sub OPERATION
        done # Funds loop
        ;; ###################################################################
      pool)
        while true; do # Pool loop
          clear
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println " >> POOL"
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println OFF " Pool Management\n"\
						" ) New      - create a new pool"\
						" ) Import   - import node cold keys from Ledger HW device (only Ledger)"\
						" ) Register - register a newly created pool on chain using a stake wallet (pledge wallet)"\
						" ) Modify   - re-register pool modifying pool definition and/or parameters"\
						" ) Retire   - de-register stake pool from chain in specified epoch"\
						" ) List     - a compact list view of available local pools"\
						" ) Show     - detailed view of specified pool"\
						" ) Rotate   - rotate pool KES keys"\
						" ) Decrypt  - remove write protection and decrypt pool"\
						" ) Encrypt  - encrypt pool cold keys and make all files immutable"\
						" ) Calidus  - register / rotate pool calidus keys (CIP-88 v2 hot pool keys)"\
						"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println DEBUG " Select Pool Operation\n"
          select_opt "[n] New" "[i] Import" "[r] Register" "[m] Modify" "[x] Retire" "[l] List" "[s] Show" "[o] Rotate" "[d] Decrypt" "[e] Encrypt" "[c] Calidus" "[h] Home"
          case $? in
            0) SUBCOMMAND="new" ;;
            1) SUBCOMMAND="import" ;;
            2) SUBCOMMAND="register" ;;
            3) SUBCOMMAND="modify" ;;
            4) SUBCOMMAND="retire" ;;
            5) SUBCOMMAND="list" ;;
            6) SUBCOMMAND="show" ;;
            7) SUBCOMMAND="rotate" ;;
            8) SUBCOMMAND="decrypt" ;;
            9) SUBCOMMAND="encrypt" ;;
            10) SUBCOMMAND="calidus" ;;
            11) break ;;
          esac
          case $SUBCOMMAND in
            new)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> NEW"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              getAnswerAnyCust pool_name "Pool Name"
              # Remove unwanted characters from pool name
              pool_name=${pool_name//[^[:alnum:]]/_}
              if [[ -z "${pool_name}" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: Empty pool name, please retry!"
                waitToProceed && continue
              fi
              mkdir -p "${POOL_FOLDER}/${pool_name}"
              pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
              pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
              pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
              pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
              pool_opcert_counter_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_COUNTER_FILENAME}"
              pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"
              pool_vrf_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_SK_FILENAME}"
              if [[ -f "${pool_hotkey_vk_file}" ]]; then
                println ERROR "${FG_RED}WARN${NC}: A pool ${FG_GREEN}$pool_name${NC} already exists"
                println ERROR "      Choose another name or delete the existing one"
                waitToProceed && continue
              fi
              println ACTION "${CCLI} node key-gen-KES --verification-key-file ${pool_hotkey_vk_file} --signing-key-file ${pool_hotkey_sk_file}"
              if ! stdout=$(${CCLI} node key-gen-KES --verification-key-file "${pool_hotkey_vk_file}" --signing-key-file "${pool_hotkey_sk_file}" 2>&1); then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during KES key creation!\n${stdout}"; waitToProceed && continue
              fi
              if [ -f "${POOL_FOLDER}-pregen/${pool_name}/${POOL_ID_FILENAME}" ]; then
                mv ${POOL_FOLDER}'-pregen/'${pool_name}/* ${POOL_FOLDER}/${pool_name}/
                rm -r ${POOL_FOLDER}'-pregen/'${pool_name}
              else
                println ACTION "${CCLI} node key-gen --cold-verification-key-file ${pool_coldkey_vk_file} --cold-signing-key-file ${pool_coldkey_sk_file} --operational-certificate-issue-counter-file ${pool_opcert_counter_file}"
                if ! stdout=$(${CCLI} node key-gen --cold-verification-key-file "${pool_coldkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" 2>&1); then
                  println ERROR "\n${FG_RED}ERROR${NC}: failure during operational certificate counter file creation!\n${stdout}"; waitToProceed && continue
                fi
              fi
              println ACTION "${CCLI} node key-gen-VRF --verification-key-file ${pool_vrf_vk_file} --signing-key-file ${pool_vrf_sk_file}"
              if ! stdout=$(${CCLI} node key-gen-VRF --verification-key-file "${pool_vrf_vk_file}" --signing-key-file "${pool_vrf_sk_file}" 2>&1); then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during VRF key creation!\n${stdout}"; waitToProceed && continue
              fi
              chmod 600 "${POOL_FOLDER}/${pool_name}/"*
              getPoolID ${pool_name}
              echo
              println "Pool: ${FG_GREEN}${pool_name}${NC}"
              [[ -n ${pool_id} ]] && println "ID (hex)    : ${pool_id}"
              [[ -n ${pool_id_bech32} ]] && println "ID (bech32) : ${pool_id_bech32}"
              waitToProceed && continue
              ;; ###################################################################
           import)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> IMPORT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              getAnswerAnyCust pool_name "Pool Name"
              # Remove unwanted characters from pool name
              pool_name=${pool_name//[^[:alnum:]]/_}
              if [[ -z "${pool_name}" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: Empty pool name, please retry!"
                waitToProceed && continue
              fi
              mkdir -p "${POOL_FOLDER}/${pool_name}"
              pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
              pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
              pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
              pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HW_COLDKEY_SK_FILENAME}"
              pool_opcert_counter_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_COUNTER_FILENAME}"
              pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"
              pool_vrf_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_SK_FILENAME}"
              if [[ -f "${pool_hotkey_vk_file}" ]]; then
                println ERROR "${FG_RED}WARN${NC}: A pool ${FG_GREEN}$pool_name${NC} already exists"
                println ERROR "      Choose another name or delete the existing one"
                waitToProceed && continue
              fi

              println ACTION "${CCLI} node key-gen-KES --verification-key-file ${pool_hotkey_vk_file} --signing-key-file ${pool_hotkey_sk_file}"
              if ! stdout=$(${CCLI} node key-gen-KES --verification-key-file "${pool_hotkey_vk_file}" --signing-key-file "${pool_hotkey_sk_file}" 2>&1); then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during KES key creation!\n${stdout}"; waitToProceed && continue
              fi

              println ACTION "${CCLI} node key-gen-VRF --verification-key-file ${pool_vrf_vk_file} --signing-key-file ${pool_vrf_sk_file}"
              if ! stdout=$(${CCLI} node key-gen-VRF --verification-key-file "${pool_vrf_vk_file}" --signing-key-file "${pool_vrf_sk_file}" 2>&1); then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during VRF key creation!\n${stdout}"; waitToProceed && continue
              fi

              if ! unlockHWDevice "export cold pub keys"; then safeDel "${POOL_FOLDER}/${pool_name}"; continue; fi
              println ACTION "cardano-hw-cli node key-gen --path 1853H/1815H/0H/0H --hw-signing-file ${pool_coldkey_sk_file} --cold-verification-key-file ${pool_coldkey_kk_file} --operational-certificate-issue-counter-file ${pool_opcert_counter_file}"
              if ! stdout=$(cardano-hw-cli node key-gen --path "1853H/1815H/0H/0H" --hw-signing-file "${pool_coldkey_sk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" 2>&1); then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during HW key extraction!\n${stdout}"; waitToProceed && continue
              fi

              jq '.description = "Stake Pool Operator Hardware Verification Key"' "${pool_coldkey_vk_file}" > "${TMP_DIR}/$(basename "${pool_coldkey_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${pool_coldkey_vk_file}").tmp" "${pool_coldkey_vk_file}"

              chmod 600 "${POOL_FOLDER}/${pool_name}/"*
              sed -i 's/Shelley//g' "${pool_coldkey_vk_file}" # TEMP FIX FOR https://github.com/vacuumlabs/cardano-hw-cli/issues/139
              getPoolID ${pool_name} && touch "${POOL_FOLDER}/${pool_name}/.hwtype"
              echo
              println "Pool: ${FG_GREEN}${pool_name}${NC}"
              [[ -n ${pool_id} ]] && println "ID (hex)    : ${pool_id}"
              [[ -n ${pool_id_bech32} ]] && println "ID (bech32) : ${pool_id_bech32}"
              waitToProceed && continue
              ;; ##################################################################
            register|modify)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> ${SUBCOMMAND^^}"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitToProceed && continue
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo

              unset isHWpool
              println DEBUG "Select pool to register|modify"
              [[ ${SUBCOMMAND} = "register" ]] && pool_filter="non-reg" || pool_filter="reg"
              if [[ ${op_mode} = "online" ]]; then
                selectPool "${pool_filter}" "${POOL_COLDKEY_VK_FILENAME}" "${POOL_VRF_VK_FILENAME}"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getPoolType ${pool_name}
                case $? in
                  0) isHWpool=Y ;;
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: signing keys missing from pool!" && waitToProceed && continue ;;
                esac
              else
                selectPool "${pool_filter}" "${POOL_COLDKEY_VK_FILENAME}" "${POOL_VRF_VK_FILENAME}"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getPoolType ${pool_name}
                [[ $? -eq 0 ]] && isHWpool=Y
              fi
              echo
              pool_config="${POOL_FOLDER}/${pool_name}/${POOL_CONFIG_FILENAME}"
              println DEBUG "Pool Parameters"
              if [[ ${SUBCOMMAND} = "modify" ]]; then
                if [[ ! -f ${pool_config} ]]; then
                  println "${FG_YELLOW}WARN${NC}: Missing pool config file: ${pool_config}"
                  println "Unable to show old values, please re-enter all values to generate a new pool config file"
                else
                  println DEBUG "Old registration values shown as default, press enter to use default value"
                fi
              else
                println DEBUG "press enter to use default value"
              fi
              echo
              pledge_ada=50000 # default pledge
              [[ -f "${pool_config}" ]] && pledge_ada=$(jq -r '.pledgeADA //0' "${pool_config}")
              getAnswerAnyCust pledge_enter "Pledge (in ADA, default: $(formatLovelace "$(ADAToLovelace ${pledge_ada})"))"
              pledge_enter="${pledge_enter//,}"
              if [[ -n "${pledge_enter}" ]]; then
                if ! ADAToLovelace "${pledge_enter}" >/dev/null; then
                  waitToProceed && continue
                fi
                pledge_lovelace=$(ADAToLovelace "${pledge_enter}")
                pledge_ada="${pledge_enter}"
              else
                pledge_lovelace=$(ADAToLovelace "${pledge_ada}")
              fi
              margin=7.5 # default margin in %
              [[ -f "${pool_config}" ]] && margin=$(jq -r '.margin //0' "${pool_config}")
              getAnswerAnyCust margin_enter "Margin (in %, default: ${margin})"
              if [[ -n "${margin_enter}" ]]; then
                if ! pctToFraction "${margin_enter}" >/dev/null; then
                  waitToProceed && continue
                fi
                margin_fraction=$(pctToFraction "${margin_enter}")
                margin="${margin_enter}"
              else
                margin_fraction=$(pctToFraction "${margin}")
              fi
              minPoolCost=$(formatLovelace ${MIN_POOL_COST} normal) # convert to ADA
              [[ -f ${pool_config} ]] && cost_ada=$(jq -r '.costADA //0' "${pool_config}") || cost_ada=${minPoolCost} # default cost
              [[ $(bc -l <<< "${cost_ada} < ${minPoolCost}") -eq 1 ]] && cost_ada=${minPoolCost} # raise old value to new minimum cost
              getAnswerAnyCust cost_enter "Cost (in ADA, minimum: ${minPoolCost}, default: ${cost_ada})"
              cost_enter="${cost_enter//,}"
              if [[ -n "${cost_enter}" ]]; then
                if ! ADAToLovelace "${cost_enter}" >/dev/null; then
                  waitToProceed && continue
                fi
                cost_lovelace=$(ADAToLovelace "${cost_enter}")
                cost_ada="${cost_enter}"
              else
                cost_lovelace=$(ADAToLovelace "${cost_ada}")
              fi
              if [[ $(bc -l <<< "${cost_ada} < ${minPoolCost}") -eq 1 ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: cost set lower than allowed"
                waitToProceed && continue
              fi
              println DEBUG "\nPool Metadata\n"
              pool_meta_file="${POOL_FOLDER}/${pool_name}/poolmeta.json"
              if [[ ! -f "${pool_config}" ]] || ! meta_json_url=$(jq -er .json_url "${pool_config}"); then meta_json_url="https://foo.bat/poolmeta.json"; fi
              getAnswerAnyCust json_url_enter "Enter Pool's JSON URL to host metadata file - URL length should be less than 128 chars (default: ${meta_json_url})"
              [[ -n "${json_url_enter}" ]] && meta_json_url="${json_url_enter}"
              if [[ ! "${meta_json_url}" =~ https?://.* || ${#meta_json_url} -gt 128 ]]; then
                println ERROR "${FG_RED}ERROR${NC}: invalid URL format or more than 128 chars in length"
                waitToProceed && continue
              fi
              metadata_done=false
              meta_tmp="${TMP_DIR}/url_poolmeta.json"
              if curl -sL -f -m ${CURL_TIMEOUT} -o "${meta_tmp}" ${meta_json_url} && jq -er . "${meta_tmp}" &>/dev/null; then
                meta_max_size=512
                jq -er '.extended // .extDataUrl // .extSigUrl // .extVkey' "${meta_tmp}" &>/dev/null && meta_max_size=1024
                [[ $(wc -c <"${meta_tmp}") -gt ${meta_max_size} ]] && println ERROR "${FG_RED}ERROR${NC}: file at specified URL contains $(wc -c <"${meta_tmp}") bytes, exceeding the ${meta_max_size}-byte limit!" && waitToProceed && continue
                echo && jq -r . "${meta_tmp}" && echo
                if ! jq -er .name "${meta_tmp}" &>/dev/null; then println ERROR "${FG_RED}ERROR${NC}: unable to get 'name' field from downloaded metadata file!" && waitToProceed && continue; fi
                if ! jq -er .ticker "${meta_tmp}" &>/dev/null; then println ERROR "${FG_RED}ERROR${NC}: unable to get 'ticker' field from downloaded metadata file!" && waitToProceed && continue; fi
                if ! jq -er .homepage "${meta_tmp}" &>/dev/null; then println ERROR "${FG_RED}ERROR${NC}: unable to get 'homepage' field from downloaded metadata file!" && waitToProceed && continue; fi
                if ! jq -er .description "${meta_tmp}" &>/dev/null; then println ERROR "${FG_RED}ERROR${NC}: unable to get 'description' field from downloaded metadata file!" && waitToProceed && continue; fi
                println DEBUG "Metadata exists at URL.  Use existing data?"
                select_opt "[y] Yes" "[n] No"
                case $? in
                  0) mv "${meta_tmp}" "${pool_meta_file}"
                    metadata_done=true
                    ;;
                  1) rm -f "${meta_tmp}" ;; # clean up temp file
                esac
              fi
              if [[ ${metadata_done} = false ]]; then
                echo
                if [[ ! -f "${pool_meta_file}" ]] || ! meta_name=$(jq -er .name "${pool_meta_file}"); then meta_name="${pool_name}"; fi
                if [[ ! -f "${pool_meta_file}" ]] || ! meta_ticker=$(jq -er .ticker "${pool_meta_file}"); then meta_ticker="$(echo ${pool_name//[^[:alnum:]]/} | tr '[:lower:]' '[:upper:]' | cut -c-5)"; fi
                if [[ ! -f "${pool_meta_file}" ]] || ! meta_description=$(jq -er .description "${pool_meta_file}"); then meta_description="No Description"; fi
                if [[ ! -f "${pool_meta_file}" ]] || ! meta_homepage=$(jq -er .homepage "${pool_meta_file}"); then meta_homepage="https://foo.com"; fi
                if [[ ! -f "${pool_meta_file}" ]] || ! meta_extended=$(jq -er .extended "${pool_meta_file}"); then meta_extended="https://foo.com/metadata/extended.json"; fi
                getAnswerAnyCust name_enter "Enter Pool's Name (default: ${meta_name})"
                [[ -n "${name_enter}" ]] && meta_name="${name_enter}"
                if [[ ${#meta_name} -gt 50 ]]; then
                  println ERROR "${FG_RED}ERROR${NC}: Name cannot exceed 50 characters"
                  waitToProceed && continue
                fi
                getAnswerAnyCust ticker_enter "Enter Pool's Ticker , should be between 3-5 characters (default: ${meta_ticker})"
                ticker_enter=${ticker_enter//[^[:alnum:]]/}
                [[ -n "${ticker_enter}" ]] && meta_ticker="${ticker_enter^^}"
                if [[ ${#meta_ticker} -lt 3 || ${#meta_ticker} -gt 5 ]]; then
                  println ERROR "${FG_RED}ERROR${NC}: ticker must be between 3-5 characters"
                  waitToProceed && continue
                fi
                getAnswerAnyCust desc_enter "Enter Pool's Description (default: ${meta_description})"
                [[ -n "${desc_enter}" ]] && meta_description="${desc_enter}"
                if [[ ${#meta_description} -gt 255 ]]; then
                  println ERROR "${FG_RED}ERROR${NC}: Description cannot exceed 255 characters"
                  waitToProceed && continue
                fi
                getAnswerAnyCust homepage_enter "Enter Pool's Homepage (default: ${meta_homepage})"
                [[ -n "${homepage_enter}" ]] && meta_homepage="${homepage_enter}"
                if [[ ! "${meta_homepage}" =~ https?://.* || ${#meta_homepage} -gt 64 ]]; then
                  println ERROR "${FG_RED}ERROR${NC}: invalid URL format or more than 64 chars in length"
                  waitToProceed && continue
                fi
                println DEBUG "\nOptionally set an extended metadata URL?"
                select_opt "[n] No" "[y] Yes"
                case $? in
                  0) meta_extended_option=""
                    ;;
                  1) getAnswerAnyCust extended_enter "Enter URL to extended metadata (default: ${meta_extended})"
                    [[ -n "${extended_enter}" ]] && meta_extended="${extended_enter}"
                    if [[ ! "${meta_extended}" =~ https?://.* || ${#meta_extended} -gt 128 ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: invalid extended URL format or more than 64 chars in length"
                      waitToProceed && continue
                    else
                      meta_extended_option=",\"extended\":\"${meta_extended}\""
                    fi
                esac
                new_pool_meta_file="${POOL_FOLDER}/${pool_name}/poolmeta-$(date '+%Y%m%d%H%M%S').json"
                echo -e "{\"name\":\"${meta_name}\",\"ticker\":\"${meta_ticker}\",\"description\":\"${meta_description}\",\"homepage\":\"${meta_homepage}\",\"nonce\":\"$(date +%s)\"${meta_extended_option}}" > "${new_pool_meta_file}"
                jq . "${new_pool_meta_file}"
                metadata_size=$(stat -c%s "${new_pool_meta_file}")
                [[ -n "${meta_extended_option}" ]] && meta_max_size=1024 || meta_max_size=512
                if [[ ${metadata_size} -gt ${meta_max_size} ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: Total metadata size cannot exceed ${meta_max_size} bytes, current length: ${metadata_size}"
                  waitToProceed && continue
                else
                  cp -f "${new_pool_meta_file}" "${pool_meta_file}"
                fi
                println DEBUG "\n${FG_YELLOW}Please host file ${pool_meta_file} as-is at ${meta_json_url}${NC}"
                waitToProceed "Press any key to proceed with registration after metadata file is uploaded"
              fi
              relay_output=""
              relay_array=()
              println DEBUG "\nPool Relay Registration"
              if [[ -f "${pool_config}" && $(jq '.relays | length' "${pool_config}") -gt 0 ]]; then
                println DEBUG "\nPrevious relay configuration:\n"
                jq -r '["TYPE","ADDRESS","PORT"], (.relays[] | [.type //"-",.address //"-",.port //"-"]) | @tsv' "${pool_config}" | column -t
                println DEBUG "\nReuse previous relay configuration?"
                select_opt "[y] Yes" "[n] No" "[Esc] Cancel"
                case $? in
                  0) while read -r type address port; do
                      relay_array+=( "type" "${type}" "address" "${address}" "port" "${port}" )
                      if [[ ${type} = "DNS_A" ]]; then
                        relay_output+="--single-host-pool-relay ${address} --pool-relay-port ${port} "
                      elif [[ ${type} = "IPv4" ]]; then
                        relay_output+="--pool-relay-port ${port} --pool-relay-ipv4 ${address} "
                      elif [[ ${type} = "IPv6" ]]; then
                        relay_output+="--pool-relay-port ${port} --pool-relay-ipv6 ${address} "
		      elif [[ ${type} = "DNS_SRV" ]]; then
                        relay_output+="--multi-host-pool-relay ${address} "
                      fi
                    done< <(jq -r '.relays[] | "\(.type) \(.address) \(.port)"' "${pool_config}")
                    ;;
                  1) : ;; # Do nothing
                  2) continue ;;
                esac
              fi
              if [[ -z ${relay_output} ]]; then
                while true; do
                  select_opt "[d] A or AAAA DNS record" "[i] IPv4/v6 address" "[s] SRV DNS record" "[Esc] Cancel"
                  case $? in
                    0) getAnswerAnyCust relay_dns_a_enter "Enter relays's DNS record, only A or AAAA DNS records"
                      if [[ -z "${relay_dns_a_enter}" ]]; then
                        println ERROR "${FG_RED}ERROR${NC}: DNS record can not be empty!"
                      else
                        getAnswerAnyCust relay_port_enter "Enter relays's port"
                        if [[ -n "${relay_port_enter}" ]]; then
                          if ! isNumber ${relay_port_enter} || [[ ${relay_port_enter} -lt 1 || ${relay_port_enter} -gt 65535 ]]; then
                            println ERROR "${FG_RED}ERROR${NC}: invalid port number!"
                          else
                            relay_array+=( "type" "DNS_A" "address" "${relay_dns_a_enter}" "port" "${relay_port_enter}" )
                            relay_output+="--single-host-pool-relay ${relay_dns_a_enter} --pool-relay-port ${relay_port_enter} "
                          fi
                        else
                          println ERROR "${FG_RED}ERROR${NC}: Port can not be empty!"
                        fi
                      fi
                      ;;
                    1) getAnswerAnyCust relay_ip_enter "Enter relays's IPv4/v6 address"
                      if [[ -n "${relay_ip_enter}" ]]; then
                        if ! isValidIPv4 "${relay_ip_enter}" && ! isValidIPv6 "${relay_ip_enter}" && ! isValidHostnameOrDomain "${relay_ip_enter}"; then
                            println ERROR "${FG_RED}ERROR${NC}: Invalid IPv4/v6 address format or hostname/domain name format!"
                        else
                          getAnswerAnyCust relay_port_enter "Enter relays's port"
                          if [[ -n "${relay_port_enter}" ]]; then
                            if ! isNumber ${relay_port_enter} || [[ ${relay_port_enter} -lt 1 || ${relay_port_enter} -gt 65535 ]]; then
                              println ERROR "${FG_RED}ERROR${NC}: invalid port number!"
                            elif isValidIPv4 "${relay_ip_enter}" || isValidHostnameOrDomain "${relay_ip_enter}"; then
                              relay_array+=( "type" "IPv4" "address" "${relay_ip_enter}" "port" "${relay_port_enter}" )
                              relay_output+="--pool-relay-port ${relay_port_enter} --pool-relay-ipv4 ${relay_ip_enter} "
                            else
                              relay_array+=( "type" "IPv6" "address" "${relay_ip_enter}" "port" "${relay_port_enter}" )
                              relay_output+="--pool-relay-port ${relay_port_enter} --pool-relay-ipv6 ${relay_ip_enter} "
                            fi
                          else
                            println ERROR "${FG_RED}ERROR${NC}: Port can not be empty!"
                          fi
                        fi
                      else
                        println ERROR "${FG_RED}ERROR${NC}: IPv4/v6 address empty!"
                      fi
                      ;;
                    2) getAnswerAnyCust relay_dns_srv_enter "Enter relays's DNS record, only SRV records"
                      if [[ -z "${relay_dns_srv_enter}" ]]; then
                        println ERROR "${FG_RED}ERROR${NC}: DNS record can not be empty!"
                      else
                        relay_array+=( "type" "DNS_SRV" "address" "${relay_dns_srv_enter}" "port" "" )
                        relay_output+="--multi-host-pool-relay ${relay_dns_srv_enter} "
                      fi
                      ;;
                    3) continue 2 ;;
                  esac
                  println DEBUG "Add more relay entries?"
                  select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                  case $? in
                    0) break ;;
                    1) continue ;;
                    2) continue 2 ;;
                  esac
                done
              fi
              echo

              owner_wallets=()
              reward_wallet=""
              hw_reward_wallet='N'
              hw_owner_wallets='N'
              reuse_wallets='N'
              # Old owner/reward wallets
              if [[ -f ${pool_config} ]]; then

                println DEBUG "Previous Owner(s)/Reward wallets"
                if jq -er '.pledgeWallet' "${pool_config}" &>/dev/null; then # legacy support
                  owner_wallets+=( "$(jq -r '.pledgeWallet' "${pool_config}")" )
                  println DEBUG "Owner wallet #1 : ${FG_GREEN}${owner_wallets[0]}${NC}"
                else
                  for owner in $(jq -c '.owners[]' "${pool_config}"); do
                    wallet_name=$(jq -r '.wallet_name' <<< "${owner}")
                    owner_wallets+=( "${wallet_name}" )
                    println DEBUG "Owner wallet #$(jq -r '.id' <<< "${owner}") : ${FG_GREEN}${wallet_name}${NC}"
                  done
                fi

                reward_wallet=$(jq -r '.rewardWallet //empty' "${pool_config}")
                println DEBUG "Reward wallet   : ${FG_GREEN}${reward_wallet}${NC}"
                println DEBUG "\nReuse previous Owner(s)/Reward wallets?"
                select_opt "[y] Yes" "[n] No" "[Esc] Cancel"
                case $? in
                  0) reuse_wallets='Y'
                    for wallet_name in "${owner_wallets[@]}"; do # Validate each wallet that they still exist and contain the correct keys
                      getWalletType ${wallet_name}
                      case $? in
                        0) if [[ ${wallet_name} = "${owner_wallets[0]}" ]]; then # main owner, must be a CLI wallet
                              println ERROR "${FG_RED}ERROR${NC}: main/first pool owner can NOT be a hardware wallet!"
                              println ERROR "Use a CLI wallet as owner with enough funds to pay for pool deposit and registration transaction fee"
                              println ERROR "Add the hardware wallet as an additional multi-owner to the pool later in the pool registration wizard"
                              waitToProceed "Unable to reuse old configuration, please set new owner(s) & reward wallet" && owner_wallets=() && reward_wallet="" && reuse_wallets='N' && break
                            else hw_owner_wallets='Y'; fi ;;
                        2) if [[ ${op_mode} = "online" ]]; then
                              println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted for wallet ${FG_GREEN}${wallet_name}${NC}, please decrypt before use!"
                              waitToProceed && continue 2
                            fi ;;
                        3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                            waitToProceed "Did you mean to run in Hybrid mode?  press any key to return home!" && continue 2 ;;
                        4) if [[ ${wallet_name} != "${owner_wallets[0]}" && ! -f "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}" ]]; then # ignore if payment vkey is missing for multi-owner, only stake vkey important
                              println ERROR "${FG_RED}ERROR${NC}: stake verification key missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                              waitToProceed "Unable to reuse old configuration, please set new owner(s) & reward wallet" && owner_wallets=() && reward_wallet="" && reuse_wallets='N' && break
                            fi ;;
                      esac
                      if [[ ${wallet_name} = "${owner_wallets[0]}" ]] && ! isWalletRegistered ${wallet_name}; then # make sure at least main owner is registered
                        if [[ ${op_mode} = "hybrid" ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: wallet ${FG_GREEN}${wallet_name}${NC} not a registered wallet on chain and CNTools run in hybrid mode"
                          println ERROR "Please first register main owner wallet to use in pool registration using 'Wallet >> Register'"
                          waitToProceed && continue 2
                        fi
                        getWalletBalance ${wallet_name} true true false true
                        if [[ ${base_lovelace} -eq 0 ]]; then
                          println ERROR "${FG_RED}ERROR${NC}: no funds available on base address for wallet ${FG_GREEN}${wallet_name}${NC}, needed to pay for registration fee"
                          waitToProceed && continue 2
                        fi
                        println DEBUG "Wallet Registration Transaction"
                        if ! registerStakeWallet ${wallet_name}; then waitToProceed && continue 2; fi
                      fi
                    done

                    if [[ ${reuse_wallets} = 'Y' ]]; then # re-check reuse_wallets in case flow was broken
                      getWalletType ${reward_wallet}
                      case $? in
                        0) hw_reward_wallet='Y' ;;
                        4) if [[ ! -f "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}" ]]; then # ignore if payment vkey is missing for reward wallet, only stake vkey important
                              println ERROR "${FG_RED}ERROR${NC}: stake verification key missing from reward wallet ${FG_GREEN}${wallet_name}${NC}!"
                              waitToProceed "Unable to reuse old configuration, please set new owner(s) & reward wallet" && owner_wallets=() && reward_wallet="" && reuse_wallets='N'
                            fi ;;
                      esac
                    fi

                    ;;
                  1) owner_wallets=() && reward_wallet="" && reuse_wallets='N'
                    println DEBUG "\n${FG_YELLOW}If new wallets are chosen for owner(s)/reward, a manual delegation to the pool for each wallet is needed if not done already!${NC}\n"
                    ;;
                  2) continue ;;
                esac
              fi

              if [[ ${reuse_wallets} = 'N' ]]; then
                println DEBUG "Select main ${FG_YELLOW}owner/pledge${NC} wallet (normal CLI wallet)"
                if [[ ${op_mode} = "online" ]]; then
                  if ! selectWallet "delegate"; then # ${wallet_name} populated by selectWallet function
                    [[ "${dir_name}" != "[Esc] Cancel" ]] && waitToProceed; continue
                  fi
                  getWalletType ${wallet_name}
                  case $? in
                    0) println ERROR "${FG_RED}ERROR${NC}: main pool owner can NOT be a hardware wallet!"
                      println ERROR "Use a CLI wallet as owner with enough funds to pay for pool deposit and registration transaction fee"
                      println ERROR "Add the hardware wallet as an additional multi-owner to the pool later in the pool registration wizard"
                      waitToProceed && continue ;;
                    2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                    3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                    5) println ERROR "${FG_RED}ERROR${NC}: MultiSig wallet pool owners not supported!"
                      println ERROR "Use a CLI wallet as owner with enough funds to pay for pool deposit and registration transaction fee"
                      waitToProceed && continue ;;
                  esac
                else
                  selectWallet "delegate"
                  case $? in
                    1) waitToProceed; continue ;;
                    2) continue ;;
                  esac
                  getWalletType ${wallet_name}
                fi
                if ! isWalletRegistered ${wallet_name}; then
                  if [[ ${op_mode} = "hybrid" ]]; then
                    println ERROR "\n${FG_RED}ERROR${NC}: wallet ${FG_GREEN}${wallet_name}${NC} not a registered wallet on chain and CNTools run in hybrid mode"
                    println ERROR "Please first register the main CLI wallet to use in pool registration using 'Wallet >> Register'"
                    waitToProceed && continue
                  fi
                  getWalletBalance ${wallet_name} true true false true
                  if [[ ${base_lovelace} -eq 0 ]]; then
                    println ERROR "${FG_RED}ERROR${NC}: no funds available on base address for wallet ${FG_GREEN}${wallet_name}${NC}, needed to pay for registration fee"
                    waitToProceed && continue
                  fi
                  println DEBUG "Wallet Registration Transaction"
                  if ! registerStakeWallet ${wallet_name}; then waitToProceed && continue; fi
                fi
                owner_wallets+=( "${wallet_name}" )
                println DEBUG "Owner #1 : ${FG_GREEN}${wallet_name}${NC} added!"
              fi

              if [[ ${reuse_wallets} = 'N' ]]; then
                println DEBUG "\nRegister a multi-owner pool (you need to have stake.vkey of any additional owner in a seperate wallet folder under $CNODE_HOME/priv/wallet)?"
                while true; do
                  select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                  case $? in
                    0) break ;;
                    1) if selectWallet "delegate" "${owner_wallets[@]}"; then # ${wallet_name} populated by selectWallet function
                        getWalletType ${wallet_name}
                        case $? in
                          0) hw_owner_wallets='Y' ;;
                          2) if [[ ${op_mode} = "online" ]]; then
                              println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted for wallet ${FG_GREEN}${wallet_name}${NC}, please decrypt before use!"
                              waitToProceed && continue 2
                            fi ;;
                          3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                            waitToProceed "Did you mean to run in Hybrid mode?  press any key to return home!" && continue 2 ;;
                          4) if [[ ! -f "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}" ]]; then # ignore if payment vkey is missing
                              println ERROR "${FG_RED}ERROR${NC}: stake verification key missing from wallet ${FG_GREEN}${wallet_name}${NC}!"
                              println DEBUG "Add another owner?" && continue
                            fi ;;
                          5) println ERROR "${FG_RED}ERROR${NC}: MultiSig wallet pool owner not supported!"
                            waitToProceed && println DEBUG "Add more owners?" && continue ;;
                        esac
                      else
                        println DEBUG "Add more owners?" && continue
                      fi
                      owner_wallets+=( "${wallet_name}" )
                      println DEBUG "Owner #${#owner_wallets[@]} : ${FG_GREEN}${wallet_name}${NC} added!"
                      ;;
                    2) continue 2 ;;
                  esac
                  println DEBUG "Add more owners?"
                done
              fi

              if [[ ${reuse_wallets} = 'N' ]]; then
                println DEBUG "\nUse a separate rewards wallet from main owner?"
                select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                case $? in
                  0) reward_wallet="${owner_wallets[0]}" ;;
                  1) if ! selectWallet "none" "${owner_wallets[0]}"; then # ${wallet_name} populated by selectWallet function
                      [[ "${dir_name}" != "[Esc] Cancel" ]] && waitToProceed; continue
                    fi
                    reward_wallet="${wallet_name}"
                    getWalletType ${reward_wallet}
                    case $? in
                      0) hw_reward_wallet='Y' ;;
                      4) if [[ ! -f "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}" ]]; then # ignore if payment vkey is missing
                            println ERROR "${FG_RED}ERROR${NC}: stake verification key missing from wallet ${FG_GREEN}${wallet_name}${NC}!" && waitToProceed && continue
                          fi ;;
                    esac
                    ;;
                  2) continue ;;
                  5) println ERROR "${FG_RED}ERROR${NC}: MultiSig wallet as rewards wallet not supported!" && waitToProceed && continue ;;
                esac
              fi

              getWalletBalance ${owner_wallets[0]} true true false true
              if [[ ${base_lovelace} -eq 0 ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: no funds available on owner wallet base address ${FG_GREEN}${owner_wallets[0]}${NC}"
                waitToProceed && continue
              fi

              multi_owner_output=""
              for wallet_name in "${owner_wallets[@]}"; do
                [[ "${wallet_name}" = "${owner_wallets[0]}" ]] && continue # skip main owner
                multi_owner_output+="--pool-owner-stake-verification-key-file ${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME} "
              done

              owner_payment_sk_file="${WALLET_FOLDER}/${owner_wallets[0]}/${WALLET_PAY_SK_FILENAME}"
              owner_payment_vk_file="${WALLET_FOLDER}/${owner_wallets[0]}/${WALLET_PAY_VK_FILENAME}"
              owner_stake_vk_file="${WALLET_FOLDER}/${owner_wallets[0]}/${WALLET_STAKE_VK_FILENAME}"
              owner_stake_sk_file="${WALLET_FOLDER}/${owner_wallets[0]}/${WALLET_STAKE_SK_FILENAME}"
              owner_delegation_cert_file="${WALLET_FOLDER}/${owner_wallets[0]}/${WALLET_DELEGCERT_FILENAME}"
              reward_stake_vk_file="${WALLET_FOLDER}/${reward_wallet}/${WALLET_STAKE_VK_FILENAME}"

              pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
              pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
              #pool_coldkey_vk_file set by getPoolType at start
              #pool_coldkey_sk_file set by getPoolType at start
              pool_vrf_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_VRF_VK_FILENAME}"
              pool_opcert_counter_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_COUNTER_FILENAME}"
              pool_opcert_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_FILENAME}"
              pool_saved_kes_start="${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}"
              pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"
              pool_deregcert_file="${POOL_FOLDER}/${pool_name}/${POOL_DEREGCERT_FILENAME}"

              # Make a backup of current reg cert if available
              [[ -f "${pool_regcert_file}" ]] && cp -f "${pool_regcert_file}" "${pool_regcert_file}.tmp"

              if [[ ${SUBCOMMAND} = "register" ]]; then
                if [[ ${op_mode} = "online" ]]; then
                  current_kes_period=$(getCurrentKESperiod)
                  echo "${current_kes_period}" > ${pool_saved_kes_start}

                  if [[ ! -f "${pool_opcert_file}" ]]; then
                    if [[ ${isHWpool} = 'Y' ]]; then
                      if ! unlockHWDevice "issue the opcert"; then return 1; fi
                        println ACTION "cardano-hw-cli node issue-op-cert --kes-verification-key-file ${pool_hotkey_vk_file} --hw-signing-file ${pool_coldkey_sk_file} --operational-certificate-issue-counter-file ${pool_opcert_counter_file} --kes-period ${current_kes_period} --out-file ${pool_opcert_file}"
                        if ! stdout=$(cardano-hw-cli node issue-op-cert \
                          --kes-verification-key-file "${pool_hotkey_vk_file}" \
                          --hw-signing-file "${pool_coldkey_sk_file}" \
                          --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" \
                          --kes-period "${current_kes_period}" \
                          --out-file "${pool_opcert_file}" 2>&1); then
                          println ERROR "\n${FG_RED}ERROR${NC}: failure during HW operational certificate creation!\n${stdout}"
                          return 1
                        fi
                    else
                      println ACTION "${CCLI} node issue-op-cert --kes-verification-key-file ${pool_hotkey_vk_file} --cold-signing-key-file ${pool_coldkey_sk_file} --operational-certificate-issue-counter-file ${pool_opcert_counter_file} --kes-period ${current_kes_period} --out-file ${pool_opcert_file}"
                      if ! stdout=$(${CCLI} node issue-op-cert --kes-verification-key-file "${pool_hotkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" --kes-period "${current_kes_period}" --out-file "${pool_opcert_file}" 2>&1); then
                        println ERROR "\n${FG_RED}ERROR${NC}: failure during operational certificate creation!\n${stdout}"; waitToProceed && continue
                      fi
                    fi
                  fi

                elif [[ ! -f ${pool_hotkey_vk_file} || ! -f ${pool_hotkey_sk_file} || ! -f ${pool_opcert_file} ]]; then
                  println DEBUG "\n${FG_YELLOW}Pool operational certificate not generated in hybrid mode,"
                  println DEBUG "please use 'Pool >> Rotate' in offline mode to generate new hot keys, op cert and KES start period and transfer to online node!${NC}"
                  println DEBUG "Files generated when running 'Pool >> Rotate' to be transferred:"
                  println DEBUG "${FG_LGRAY}${pool_hotkey_vk_file}${NC}"
                  println DEBUG "${FG_LGRAY}${pool_hotkey_sk_file}${NC}"
                  println DEBUG "${FG_LGRAY}${pool_opcert_file}${NC}"
                  println DEBUG "${FG_LGRAY}${pool_saved_kes_start}${NC}"
                  waitToProceed "press any key to continue"
                fi
              fi

              println LOG "creating registration certificate"
              println ACTION "${CCLI} latest stake-pool registration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --vrf-verification-key-file ${pool_vrf_vk_file} --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file ${reward_stake_vk_file} --pool-owner-stake-verification-key-file ${owner_stake_vk_file} ${multi_owner_output} --metadata-url ${meta_json_url} --metadata-hash \$\(${CCLI} latest stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} \) ${relay_output} ${NETWORK_IDENTIFIER} --out-file ${pool_regcert_file}"
              if ! stdout=$(${CCLI} latest stake-pool registration-certificate --cold-verification-key-file "${pool_coldkey_vk_file}" --vrf-verification-key-file "${pool_vrf_vk_file}" --pool-pledge ${pledge_lovelace} --pool-cost ${cost_lovelace} --pool-margin ${margin_fraction} --pool-reward-account-verification-key-file "${reward_stake_vk_file}" --pool-owner-stake-verification-key-file "${owner_stake_vk_file}" ${multi_owner_output} --metadata-url "${meta_json_url}" --metadata-hash "$(${CCLI} latest stake-pool metadata-hash --pool-metadata-file ${pool_meta_file} )" ${relay_output} ${NETWORK_IDENTIFIER} --out-file "${pool_regcert_file}" 2>&1); then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during stake pool registration certificate creation!\n${stdout}"; waitToProceed && continue
              fi

              delegate_owner_wallet='N'
              if [[ ${SUBCOMMAND} = "register" ]]; then
                if [[ ${hw_owner_wallets} = 'Y' || ${hw_reward_wallet} = 'Y' || ${isHWpool} = 'Y' ]]; then
                  println DEBUG "\n${FG_BLUE}INFO${NC}: hardware wallet included as reward or multi-owner or hardware pool, automatic owner/reward wallet delegation disabled"
                  println DEBUG "${FG_BLUE}INFO${NC}: ${FG_YELLOW}please manually delegate all wallets to the pool!!!${NC}"
                  waitToProceed "press any key to continue"
                else
                  println LOG "creating delegation certificate for main owner wallet"
                  println ACTION "${CCLI} latest stake-address stake-delegation-certificate --stake-verification-key-file ${owner_stake_vk_file} --cold-verification-key-file ${pool_coldkey_vk_file} --out-file ${owner_delegation_cert_file}"
                  if ! stdout=$(${CCLI} latest stake-address stake-delegation-certificate --stake-verification-key-file "${owner_stake_vk_file}" --cold-verification-key-file "${pool_coldkey_vk_file}" --out-file "${owner_delegation_cert_file}" 2>&1); then
                    println ERROR "\n${FG_RED}ERROR${NC}: failure during stake delegation certificate creation!\n${stdout}"; waitToProceed && continue
                  fi
                  delegate_owner_wallet='Y'
                  if [[ "${owner_wallets[0]}" != "${reward_wallet}" ]]; then
                    println DEBUG "\n${FG_BLUE}INFO${NC}: reward wallet not the same as owner, automatic reward wallet delegation disabled"
                    println DEBUG "${FG_BLUE}INFO${NC}: ${FG_YELLOW}please manually delegate reward wallet to the pool!!!${NC}"
                    waitToProceed "press any key to continue"
                  fi
                fi
              fi

              if [[ ${SUBCOMMAND} = "register" ]]; then
                println DEBUG "\nPool Registration Transaction"
                registerPool
                rc=$?
              else
                println DEBUG "\nPool Update Transaction"
                modifyPool
                rc=$?
              fi

              if [[ $rc -eq 0 ]]; then
                [[ -f "${pool_regcert_file}.tmp" ]] && rm -f "${pool_regcert_file}.tmp" # remove backup of old reg cert if it exist (modify)
                [[ -f "${pool_deregcert_file}" ]] && rm -f "${pool_deregcert_file}" # delete de-registration cert if available
              else # rc=1 failed | rc=2 used for offline mode, treat as failed for now, files written on submission
                [[ $rc -eq 1 ]] && echo && println ERROR "\n${FG_RED}ERROR${NC}: failure during pool ${SUBCOMMAND}!"
                if [[ ${SUBCOMMAND} = "register" ]]; then
                  [[ -f "${pool_regcert_file}" ]] && rm -f "${pool_regcert_file}"
                else
                  [[ -f "${pool_regcert_file}.tmp" ]] && mv -f "${pool_regcert_file}.tmp" "${pool_regcert_file}" # restore reg cert backup
                fi
                [[ $rc -eq 1 ]] && waitToProceed && continue
              fi

              # Save pool config
              # Construct relay json array
              relay_json=$({
                printf '['
                printf '{"%s":"%s","%s":"%s","%s":"%s"},\n' "${relay_array[@]}" | sed '$s/,$//'
                printf ']'
              } | jq -c .)
              # Construct owner json array
              owner_array=()
              for index in "${!owner_wallets[@]}"; do
                owner_array+=( "$((index+1))" "${owner_wallets[${index}]}" )
              done
              owner_json=$({
                printf '['
                printf '{"id":"%s","wallet_name":"%s"},\n' "${owner_array[@]}" | sed '$s/,$//'
                printf ']'
              } | jq -c .)
              echo "{\"owners\":$owner_json,\"rewardWallet\":\"$reward_wallet\",\"pledgeADA\":\"$pledge_ada\",\"margin\":\"$margin\",\"costADA\":\"$cost_ada\",\"json_url\":\"$meta_json_url\",\"relays\": $relay_json}" > "${pool_config}"
              chmod 600 "${POOL_FOLDER}/${pool_name}/"*
              [[ -f "${pool_deregcert_file}" ]] && rm -f ${pool_deregcert_file} # delete de-registration cert if available
              echo
              if [[ ${op_mode} = "online" ]]; then
                getBaseAddress ${owner_wallets[0]}
                if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
                echo
                if [[ ${SUBCOMMAND} = "register" ]]; then
                  println "Pool ${FG_GREEN}${pool_name}${NC} successfully registered!"
                else
                  println "Pool ${FG_GREEN}${pool_name}${NC} successfully updated!"
                fi
              else
                println "Pool ${FG_GREEN}${pool_name}${NC} built!"
                println "${FG_YELLOW}Follow the steps above to sign and submit transaction!${NC}"
              fi
              for index in "${!owner_wallets[@]}"; do
                println "Owner #$((index+1))      : ${FG_GREEN}${owner_wallets[${index}]}${NC}"
              done
              println "Reward Wallet : ${FG_GREEN}${reward_wallet}${NC}"
              println "Pledge        : ${FG_LBLUE}$(formatLovelace "$(ADAToLovelace ${pledge_ada})")${NC} ADA"
              println "Margin        : ${FG_LBLUE}${margin}${NC} %"
              println "Cost          : ${FG_LBLUE}$(formatLovelace ${cost_lovelace})${NC} ADA"
              if [[ ${SUBCOMMAND} = "register" ]]; then
                if [[ ${op_mode} = "hybrid" ]]; then
                  println DEBUG "\n${FG_YELLOW}After offline pool transaction is signed and submitted, uncomment and set value for POOL_NAME in ${PARENT}/env with${NC} '${FG_GREEN}${pool_name}${NC}'"
                else
                  println DEBUG "\n${FG_YELLOW}Uncomment and set value for POOL_NAME in ${PARENT}/env with${NC} '${FG_GREEN}${pool_name}${NC}'"
                fi
              fi
              echo
              if [[ ${op_mode} = "online" ]]; then
                total_pledge=0
                if [[ -n ${KOIOS_API} ]]; then
                  addr_list=()
                  reward_addr_list=()
                  for wallet_name in "${owner_wallets[@]}"; do
                    getBaseAddress ${wallet_name} && addr_list+=(${base_addr})
                    getRewardAddress ${wallet_name} && reward_addr_list+=(${reward_addr})
                  done
                  [[ ${#addr_list[@]} -gt 0 ]] && getBalanceKoios false
                  [[ ${#reward_addr_list[@]} -gt 0 ]] && getRewardInfoKoios
                  for key in "${!assets[@]}"; do
                    [[ ${key} = *lovelace ]] && total_pledge=$(( total_pledge + assets[${key}] ))
                  done
                  for value in "${rewards_available[@]}"; do
                    [[ ${value} -gt 0 ]] && total_pledge=$(( total_pledge + value ))
                  done
                else
                  for wallet_name in "${owner_wallets[@]}"; do
                    getBaseAddress ${wallet_name}
                    getBalance ${base_addr}
                    total_pledge=$(( total_pledge + assets[lovelace] ))
                    getWalletRewards ${wallet_name}
                    [[ ${reward_lovelace} -gt 0 ]] && total_pledge=$(( total_pledge + reward_lovelace ))
                  done
                fi
                println DEBUG "${FG_BLUE}INFO${NC}: Total balance in ${FG_LBLUE}${#owner_wallets[@]}${NC} owner/pledge wallet(s) are: ${FG_LBLUE}$(formatLovelace ${total_pledge})${NC} ADA"
                if [[ ${total_pledge} -lt ${pledge_lovelace} ]]; then
                  println ERROR "${FG_YELLOW}Not enough funds in owner/pledge wallet(s) to meet set pledge, please manually verify!!!${NC}"
                fi
              fi
              if [[ ${#owner_wallets[@]} -gt 1 ]]; then
                if [[ ${op_mode} = "hybrid" ]]; then
                  println DEBUG "${FG_BLUE}INFO${NC}: please verify that all owner/reward wallets are delegated to the pool after the pool registration has been signed and submitted, if not do so!"
                else
                  println DEBUG "${FG_BLUE}INFO${NC}: please verify that all owner/reward wallets are delegated to the pool, if not do so!"
                fi
              fi
              waitToProceed && continue
              ;; ###################################################################
            retire)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> RETIRE"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitToProceed && continue
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available to pay for pool de-registration!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "Select pool to retire"
              if [[ ${op_mode} = "online" ]]; then
                selectPool "all" "${POOL_COLDKEY_VK_FILENAME}"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getPoolType ${pool_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: signing keys missing from pool!" && waitToProceed && continue ;;
                esac
              else
                selectPool "all" "${POOL_COLDKEY_VK_FILENAME}"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getPoolType ${pool_name}
              fi
              echo
              epoch=$(getEpoch)
              println DEBUG "Current epoch: ${FG_LBLUE}${epoch}${NC}"
              epoch_start=$((epoch + 1))
              epoch_end=$((epoch + POOL_RETIRE_MAX_EPOCH))
              println DEBUG "earliest epoch to retire pool is ${FG_LBLUE}${epoch_start}${NC} and latest ${FG_LBLUE}${epoch_end}${NC}"
              echo
              getAnswerAnyCust epoch_enter "Enter epoch in which to retire pool (blank for ${epoch_start})"
              [[ -z "${epoch_enter}" ]] && epoch_enter=${epoch_start}
              echo
              if [[ ${epoch_enter} -lt ${epoch_start} || ${epoch_enter} -gt ${epoch_end} ]]; then
                println ERROR "${FG_RED}ERROR${NC}: epoch invalid, valid range: ${epoch_start}-${epoch_end}"
                waitToProceed && continue
              fi
              println DEBUG "Select wallet for pool de-registration transaction fee"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "balance"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for pool de-registration transaction fee!" && waitToProceed && continue ;;
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                esac
              else
                selectWallet "balance"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for pool de-registration transaction fee!" && waitToProceed && continue ;;
                esac
              fi
              getWalletBalance ${wallet_name} true true true true
              if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
                # Both payment and base address available with funds, let user choose what to use
                println DEBUG "\nSelect wallet address to use"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
                select_opt "[b] Base (default)" "[e] Payment" "[Esc] Cancel"
                case $? in
                  0) addr="${base_addr}"; lovelace=${base_lovelace} ;;
                  1) addr="${pay_addr}";  lovelace=${pay_lovelace} ;;
                  2) continue ;;
                esac
              elif [[ ${pay_lovelace} -gt 0 ]]; then
                addr="${pay_addr}"
                lovelace=${pay_lovelace}
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "\n$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
              elif [[ ${base_lovelace} -gt 0 ]]; then
                addr="${base_addr}"
                lovelace=${base_lovelace}
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "\n$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                fi
              else
                println ERROR "\n${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                waitToProceed && continue
              fi
              pool_deregcert_file="${POOL_FOLDER}/${pool_name}/${POOL_DEREGCERT_FILENAME}"
              pool_regcert_file="${POOL_FOLDER}/${pool_name}/${POOL_REGCERT_FILENAME}"
              println LOG "creating de-registration cert"
              println ACTION "${CCLI} latest stake-pool deregistration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --epoch ${epoch_enter} --out-file ${pool_deregcert_file}"
              if ! stdout=$(${CCLI} latest stake-pool deregistration-certificate --cold-verification-key-file ${pool_coldkey_vk_file} --epoch ${epoch_enter} --out-file ${pool_deregcert_file} 2>&1); then
                println ERROR "\n${FG_RED}ERROR${NC}: failure during stake pool deregistration certificate creation!\n${stdout}"; waitToProceed && continue
              fi
              echo
              if ! deRegisterPool; then
                waitToProceed && continue
              fi
              [[ -f "${pool_regcert_file}" ]] && rm -f ${pool_regcert_file} # delete registration cert
              echo
              if ! verifyTx ${addr}; then waitToProceed && continue; fi
              echo
              println "Pool ${FG_GREEN}${pool_name}${NC} set to be retired in epoch ${FG_LBLUE}${epoch_enter}${NC}"
              println "Pool deposit will be returned to owner reward address after its retired"
              waitToProceed && continue
              ;; ###################################################################
            list)
              cntools_compatibility_dispatch_action pool.list
              action_status=$?
              case "${action_status}" in
                0|21) continue ;;
                20) break ;;
                22) myExit 0 "CNTools closed!" ;;
                *) waitToProceed; continue ;;
              esac
              ;; ###################################################################
            show)
              cntools_compatibility_dispatch_action pool.show
              action_status=$?
              case "${action_status}" in
                0|21) continue ;;
                20) break ;;
                22) myExit 0 "CNTools closed!" ;;
                *) waitToProceed; continue ;;
              esac
              ;; ###################################################################
            rotate)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> ROTATE KES"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "${FG_LGRAY}OFFLINE MODE${NC}: CNTools started in offline mode, please grab correct counter value from online node using pool info!\n"
              fi
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No pools available!${NC}" && waitToProceed && continue
              println DEBUG "Select pool to rotate KES keys on"
              selectPool "all" "${POOL_COLDKEY_VK_FILENAME}"
              case $? in
                1) waitToProceed; continue ;;
                2) continue ;;
              esac
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                getAnswerAnyCust new_counter "Enter new counter number"
                if ! isNumber ${new_counter}; then
                  println ERROR "\n${FG_RED}ERROR${NC}: not a number"
                  waitToProceed && continue
                fi
                if ! rotatePoolKeys ${new_counter}; then
                  waitToProceed && continue
                fi
              else
                if ! rotatePoolKeys; then
                  waitToProceed && continue
                fi
              fi
              echo
              println "Pool KES keys successfully updated"
              println "New KES start period : ${FG_LBLUE}${current_kes_period}${NC}"
              println "KES keys will expire : ${FG_LBLUE}$(( current_kes_period + MAX_KES_EVOLUTIONS ))${NC} - ${FG_LGRAY}${kes_expiration}${NC}"
              echo
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println DEBUG "Copy updated files to pool node replacing existing files:"
                println DEBUG "${FG_LGRAY}${pool_hotkey_sk_file}${NC}"
                println DEBUG "${FG_LGRAY}${pool_hotkey_vk_file}${NC}"
                println DEBUG "${FG_LGRAY}${pool_opcert_file}${NC}"
                println DEBUG "${FG_LGRAY}${pool_saved_kes_start}${NC}"
                echo
              fi
              println DEBUG "Restart your pool node for changes to take effect"
              waitToProceed && continue
              ;; ###################################################################
            decrypt)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> DECRYPT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No pools available!${NC}" && waitToProceed && continue
              println DEBUG "Select pool to decrypt"
              selectPool "encrypted"
              case $? in
                1) waitToProceed; continue ;;
                2) continue ;;
              esac
              filesUnlocked=0
              keysDecrypted=0
              echo
              println DEBUG "Removing write protection from all pool files"
              while IFS= read -r -d '' file; do
                unlockFile "${file}"
                filesUnlocked=$((++filesUnlocked))
                println DEBUG "${file}"
              done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -print0)
              if [[ $(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c) -gt 0 ]]; then
                echo
                println "Decrypting GPG encrypted pool files"
                if ! getPasswordCust; then # $password variable populated by getPasswordCust function
                  println "\n\n" && println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
                  waitToProceed && continue
                fi
                while IFS= read -r -d '' file; do
                  decryptFile "${file}" "${password}" && \
                  chmod 600 "${file::-4}" && \
                  keysDecrypted=$((++keysDecrypted))
                done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0)
                unset password
              fi
              echo
              println "Pool decrypted  : ${FG_GREEN}${pool_name}${NC}"
              println "Files unlocked  : ${FG_LBLUE}${filesUnlocked}${NC}"
              println "Files decrypted : ${FG_LBLUE}${keysDecrypted}${NC}"
              if [[ ${filesUnlocked} -ne 0 || ${keysDecrypted} -ne 0 ]]; then
                echo
                println DEBUG "${FG_YELLOW}Pool files are now unprotected${NC}"
                println DEBUG "Use 'POOL >> ENCRYPT / LOCK' to re-lock"
              fi
              waitToProceed && continue
              ;; ###################################################################
            encrypt)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> ENCRYPT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && println "${FG_YELLOW}No pools available!${NC}" && waitToProceed && continue
              println DEBUG "Select pool to encrypt"
              selectPool "encrypted"
              case $? in
                1) waitToProceed; continue ;;
                2) continue ;;
              esac
              filesLocked=0
              keysEncrypted=0
              if [[ $(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0 | wc -c) -le 0 ]]; then
                echo
                println DEBUG "Encrypting sensitive pool keys with GPG"
                if ! getPasswordCust confirm; then # $password variable populated by getPasswordCust function
                  println "\n\n" && println ERROR "${FG_RED}ERROR${NC}: password input aborted!"
                  waitToProceed && continue
                fi
                keyFiles=(
                  "${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
                )
                for keyFile in "${keyFiles[@]}"; do
                  if [[ -f "${keyFile}" ]]; then
                    chmod 400 "${keyFile}" && \
                    encryptFile "${keyFile}" "${password}" && \
                    keysEncrypted=$((++keysEncrypted))
                  fi
                done
                unset password
              else
                echo
                println DEBUG "${FG_YELLOW}NOTE${NC}: found GPG encrypted files in folder, please decrypt/unlock pool files before encrypting"
                waitToProceed && continue
              fi
              echo
              println DEBUG "Write protecting all pool files with 400 permission and if enabled 'chattr +i'"
              while IFS= read -r -d '' file; do
                lockFile "$file"
                filesLocked=$((++filesLocked))
                println DEBUG "$file"
              done < <(find "${POOL_FOLDER}/${pool_name}" -mindepth 1 -maxdepth 1 -type f -print0)
              echo
              println "Pool encrypted  : ${FG_GREEN}${pool_name}${NC}"
              println "Files locked    : ${FG_LBLUE}${filesLocked}${NC}"
              println "Files encrypted : ${FG_LBLUE}${keysEncrypted}${NC}"
              if [[ ${filesLocked} -ne 0 || ${keysEncrypted} -ne 0 ]]; then
                echo
                println DEBUG "${FG_BLUE}INFO${NC}: pool files are now protected"
                println DEBUG "Use 'POOL >> DECRYPT / UNLOCK' to unlock"
              fi
              waitToProceed && continue
              ;; ###################################################################
            calidus)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> POOL >> CALIDUS"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${POOL_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No pools available!${NC}" && waitToProceed && continue
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available to pay for pool calidus metadata registration!${NC}" && waitToProceed && continue
              if ! cmdAvailable "cardano-signer" &>/dev/null; then
                println ERROR "\n${FG_RED}ERROR${NC}: prerequisite tool cardano-signer missing or not executable, please install using ${FG_LGRAY}guild-deploy.sh${NC}"
                waitToProceed && continue
              fi
              if ! cardano_signer_minimum_version="$(cnodeManifestToolMinimumVersion "cardano-signer")"; then
                println ERROR "\n${FG_RED}ERROR${NC}: invalid cardano-signer compatibility metadata in the installed cnode release manifest."
                waitToProceed && continue
              fi
              cardano_signer_version=$(cardano-signer -version)
              if ! versionCheck "${cardano_signer_minimum_version}" "${cardano_signer_version##* }"; then
                println INFO "${FG_YELLOW}Please upgrade cardano-signer, this feature requires at least version ${cardano_signer_minimum_version}, found ${cardano_signer_version##* }!${NC}"; waitToProceed && continue
              fi
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "Select pool to create / rotate calidus keys for"
              if [[ ${op_mode} = "online" ]]; then
                selectPool "all" "${POOL_COLDKEY_VK_FILENAME}"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getPoolType ${pool_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: signing keys missing from pool!" && waitToProceed && continue ;;
                esac
              else
                selectPool "all" "${POOL_COLDKEY_VK_FILENAME}"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getPoolType ${pool_name}
              fi
              metatype="no-schema"
              calidus_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_CALIDUS_SK_FILENAME}"
              calidus_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_CALIDUS_VK_FILENAME}"
              calidus_id_file="${POOL_FOLDER}/${pool_name}/${POOL_CALIDUS_ID_FILENAME}"
              calidus_reg_file="${POOL_FOLDER}/${pool_name}/${POOL_CALIDUS_REG_FILENAME}"
              if [[ -f ${calidus_reg_file} ]]; then
                CS_CIP88_META_VERIFY=(
                  cardano-signer verify
                  --cip88
                  --data-file "${calidus_reg_file}"
                )
                println ACTION "${CS_CIP88_META_VERIFY[*]}"
                if ! stdout=$("${CS_CIP88_META_VERIFY[@]}" 2>&1) || [[ ${stdout} = *false* ]]; then
                  println ERROR "\n${FG_RED}ERROR${NC}: failure during calidus metadata verification!\n  result: ${stdout}\n"
                  select_opt "[d] Delete metadata file and continue" "[Esc] Return"
                  case $? in
                    0) safeDel "${calidus_reg_file}" ;;
                    1) continue ;;
                  esac
                else
                  println DEBUG "\nCalidus metadata registration found and is valid, continue to submit?"
                  select_opt "[y] Yes" "[n] No, delete and create a new" "[Esc] Return"
                  case $? in
                    0) : ;;
                    1) safeDel "${calidus_reg_file}" ;;
                    2) continue ;;
                  esac
                fi
              fi
              if [[ ! -f ${calidus_reg_file} ]]; then
                generate_calidus_keys=true
                if [[ -f ${calidus_vk_file} ]]; then
                  println DEBUG "\nCalidus keys already exist, how do you want to proceed?"
                  select_opt "[k] Keep existing keys" "[o] Overwrite to rotate keys" "[Esc] Return"
                  case $? in
                    0) generate_calidus_keys=false ;;
                    1) safeDel "${calidus_sk_file}"; safeDel "${calidus_vk_file}"; safeDel "${calidus_id_file}" ;;
                    2) continue ;;
                  esac
                fi
                if [[ ${generate_calidus_keys} = true ]]; then
                  CS_CALIDUS_KEYS=(
                    cardano-signer keygen
                    --path calidus
                    --out-skey "${calidus_sk_file}"
                    --out-vkey "${calidus_vk_file}"
                    --out-id "${calidus_id_file}"
                    --out-mnemonics "${TMP_DIR}/calidus.mnemonics"
                  )
                  println ACTION "${CS_CALIDUS_KEYS[*]}"
                  if ! stdout=$("${CS_CALIDUS_KEYS[@]}" 2>&1); then
                    println ERROR "\n${FG_RED}ERROR${NC}: failure during calidus key creation!\n${stdout}"
                    waitToProceed && continue
                  fi
                  echo
                  word_len=0
                  IFS=' ' read -r -a words < "${TMP_DIR}/calidus.mnemonics"
                  rm -f "${TMP_DIR}/calidus.mnemonics"
                  for word in "${words[@]}"; do
                    [[ ${#word} -gt ${word_len} ]] && word_len=${#word}
                  done
                  println DEBUG "${FG_YELLOW}OPTIONAL!${NC} Write down and store below words in a secure place to be able to restore the generated pool calidus key in for example a light wallet."
                  for i in "${!words[@]}"; do
                    idx=$(( i + 1 ))
                    printf "%2s: ${FG_GREEN}%-${word_len}s${NC}  " "$idx" "${words[$i]}"
                    [[ $(( idx % 4 )) -eq 0 ]] && echo
                  done
                  unset words
                  waitToProceed
                elif [[ ! -f ${calidus_vk_file} ]]; then
                  println ERROR "\n${FG_RED}ERROR${NC}: missing existing calidus public key, cannot continue!"
                  waitToProceed && continue
                fi
                current_slot=$(getSlotTipRef)
                CS_CIP88_META_FILE=(
                  cardano-signer sign
                  --cip88
                  --calidus-public-key "${calidus_vk_file}"
                  --secret-key "${pool_coldkey_sk_file}"
                  --nonce ${current_slot}
                  --json
                  --out-file "${calidus_reg_file}"
                )
                if [[ ${op_mode} = "hybrid" && ! -f "${calidus_reg_file}" ]]; then
                  println INFO "\n1. Move '${FG_LGRAY}${calidus_vk_file}${NC}' to offline machine that contain ${FG_GREEN}${pool_name}${NC} pool cold key."\
                    "2. Run below command to generate registration metadata replacing paths as needed."\
                    "3. Move generated '${FG_LGRAY}${POOL_CALIDUS_REG_FILENAME}${NC}' file back into ${FG_GREEN}${pool_name}${NC} pool folder on this machine."\
                    "4. Rerun this command to complete calidus key registration keeping existing keys.\n"
                  println INFO "${FG_LGRAY}${CS_CIP88_META_FILE[*]}${NC}"
                  waitToProceed && continue
                fi
                println ACTION "${CS_CIP88_META_FILE[*]}"
                if ! stdout=$("${CS_CIP88_META_FILE[@]}" 2>&1); then
                  println ERROR "\n${FG_RED}ERROR${NC}: failure during calidus metadata generation!\n${stdout}"
                  waitToProceed && continue
                fi
              fi
              println DEBUG "\nSelect wallet for calidus registration transaction fee"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "balance"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                esac
              else
                selectWallet "balance"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
              fi
              getWalletBalance ${wallet_name} true true true true
              if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
                # Both payment and base address available with funds, let user choose what to use
                println DEBUG "\nSelect wallet address to use"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
                select_opt "[b] Base (default)" "[e] Payment" "[Esc] Cancel"
                case $? in
                  0) addr="${base_addr}"; lovelace=${base_lovelace} ;;
                  1) addr="${pay_addr}";  lovelace=${pay_lovelace} ;;
                  2) continue ;;
                esac
              elif [[ ${pay_lovelace} -gt 0 ]]; then
                addr="${pay_addr}"
                lovelace=${pay_lovelace}
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "\n$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
              elif [[ ${base_lovelace} -gt 0 ]]; then
                addr="${base_addr}"
                lovelace=${base_lovelace}
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "\n$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                fi
              else
                println ERROR "\n${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                waitToProceed && continue
              fi
              metafile="${calidus_reg_file}"
              if ! sendMetadata; then
                waitToProceed && continue
              fi
              rm -f "${calidus_reg_file}"
              echo
              if ! verifyTx ${addr}; then waitToProceed && continue; fi
              echo
              println "Pool calidus key registration metadata successfully posted on-chain"
              waitToProceed && continue
              ;; ###################################################################
          esac # pool sub OPERATION
        done # Pool loop
        ;; ###################################################################
      transaction)
        while true; do # Transaction loop
          clear
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println " >> TRANSACTION"
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println OFF " Transaction Management\n"\
						" ) Sign    - witness/sign offline tx with signing keys"\
						" ) Submit  - submit signed offline tx to blockchain"\
						"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println DEBUG " Select Transaction Operation\n"
          select_opt "[s] Sign" "[t] Submit" "[h] Home"
          case $? in
            0) SUBCOMMAND="sign" ;;
            1) SUBCOMMAND="submit" ;;
            2) break ;;
          esac
          case $SUBCOMMAND in
            sign)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> TRANSACTION >> SIGN"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              fileDialog "Enter path to transaction file to sign" "${TMP_DIR}/" && echo
              offline_tx=${file}
              [[ -z "${offline_tx}" ]] && continue
              if [[ ! -f "${offline_tx}" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: file not found: ${offline_tx}"
                waitToProceed && continue
              elif ! offlineJSON=$(jq -erc . "${offline_tx}"); then
                println ERROR "${FG_RED}ERROR${NC}: invalid JSON file: ${offline_tx}"
                waitToProceed && continue
              fi
              if ! otx_type="$(jq -er '.type' <<< ${offlineJSON})"; then println ERROR "${FG_RED}ERROR${NC}: field 'type' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_date_created="$(jq -er '."date-created"' <<< ${offlineJSON})"; then println ERROR "${FG_RED}ERROR${NC}: field 'date-created' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_date_expire="$(jq -er '."date-expire"' <<< ${offlineJSON})"; then println ERROR "${FG_RED}ERROR${NC}: field 'date-expire' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_txFee=$(jq -er '.txFee' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'txFee' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_txBody=$(jq -er '.txBody' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'txBody' not found in: ${offline_tx}" && waitToProceed && continue; fi
              echo -e "${otx_txBody}" > "${TMP_DIR}"/tx.raw
              println DEBUG "Transaction type : ${FG_GREEN}${otx_type}${NC}"
              if wallet_name=$(jq -er '."wallet-name"' <<< ${offlineJSON}); then
                println DEBUG "Transaction fee  : ${FG_LBLUE}$(formatLovelace ${otx_txFee})${NC} ADA, payed by ${FG_GREEN}${wallet_name}${NC}"
                [[ $(cat "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}" 2>/dev/null) = "${addr}" ]] && wallet_source="payment" || wallet_source="base"
              else
                println DEBUG "Transaction fee  : ${FG_LBLUE}$(formatLovelace ${otx_txFee})${NC} ADA"
              fi
              println DEBUG "Created          : ${FG_LGRAY}$(date '+%F %T %Z' --date="${otx_date_created}")${NC}"
              [[ $(date '+%s' --date="${otx_date_expire}") -lt $(date '+%s') ]] && expire_color="${FG_RED}" || expire_color="${FG_LGRAY}"
              println DEBUG "Expire           : ${expire_color}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}"
              echo
              tx_witness_files=()
              case "${otx_type}" in
                "Pool Registration"|"Pool Update")
                  println DEBUG "Pool name        : ${FG_LGRAY}$(jq -r '."pool-metadata".name' <<< ${offlineJSON})${NC}"
                  println DEBUG "Ticker           : ${FG_LGRAY}$(jq -r '."pool-metadata".ticker' <<< ${offlineJSON})${NC}"
                  println DEBUG "Pledge           : ${FG_LBLUE}$(formatLovelace "$(ADAToLovelace "$(jq -r '."pool-pledge"' <<< ${offlineJSON})")")${NC} ADA"
                  println DEBUG "Margin           : ${FG_LBLUE}$(jq -r '."pool-margin"' <<< ${offlineJSON})${NC} %"
                  println DEBUG "Cost             : ${FG_LBLUE}$(formatLovelace "$(ADAToLovelace "$(jq -r '."pool-cost"' <<< ${offlineJSON})")")${NC} ADA"
                  echo
                  ;;
                *)
                  [[ ${otx_type} = "Wallet De-Registration" ]] && println DEBUG "Amount returned  : ${FG_LBLUE}$(formatLovelace "$(jq -r '."amount-returned"' <<< ${offlineJSON})")${NC} ADA"
                  if [[ ${otx_type} = "Payment" ]]; then
                    println DEBUG "Source addr      : ${FG_LGRAY}$(jq -r '."source-address"' <<< ${offlineJSON})${NC}"
                    println DEBUG "Destination addr : ${FG_LGRAY}$(jq -r '."destination-address"' <<< ${offlineJSON})${NC}"
                    println DEBUG "Amount           : ${FG_LBLUE}$(formatLovelace "$(jq -r '.assets[] | select(.asset=="lovelace") | .amount' <<< ${offlineJSON})")${NC} ADA"
                    for otx_assets in $(jq -r '.assets[] | @base64' <<< "${offlineJSON}"); do
                      _jq() { base64 -d <<< ${otx_assets} | jq -r "${1}"; }
                      otx_asset=$(_jq '.asset')
                      [[ ${otx_asset} = "lovelace" ]] && continue
                      println DEBUG "                   ${FG_LBLUE}$(formatAsset "$(_jq '.amount')")${NC} ${FG_LGRAY}${otx_asset}${NC}"
                    done
                  fi
                  jq -er '.rewards' <<< ${offlineJSON} &>/dev/null && println DEBUG "Rewards          : ${FG_LBLUE}$(formatLovelace "$(jq -r '.rewards' <<< ${offlineJSON})")${NC} ADA"
                  jq -er '."pool-id"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Pool ID          : ${FG_LGRAY}$(jq -r '."pool-id"' <<< ${offlineJSON})${NC}"
                  jq -er '."pool-name"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Pool name        : ${FG_LGRAY}$(jq -r '."pool-name"' <<< ${offlineJSON})${NC}"
                  jq -er '."pool-ticker"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Ticker           : ${FG_LGRAY}$(jq -r '."pool-ticker"' <<< ${offlineJSON})${NC}"
                  jq -er '."retire-epoch"' <<< ${offlineJSON} &>/dev/null && println DEBUG "To be retired    : epoch ${FG_LGRAY}$(jq -r '."retire-epoch"' <<< ${offlineJSON})${NC}"
                  jq -er '.metadata' <<< ${offlineJSON} &>/dev/null && println DEBUG "Metadata         :\n$(jq -r '.metadata' <<< ${offlineJSON})\n"
                  jq -er '."policy-name"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Policy Name      : ${FG_LGRAY}$(jq -r '."policy-name"' <<< ${offlineJSON})${NC}"
                  jq -er '."policy-id"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Policy ID        : ${FG_LGRAY}$(jq -r '."policy-id"' <<< ${offlineJSON})${NC}"
                  jq -er '."asset-name"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Asset Name       : ${FG_LGRAY}$(jq -r '."asset-name"' <<< ${offlineJSON})${NC}"
                  [[ ${otx_type} = "Asset Minting" ]] && println DEBUG "Assets To Mint   : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-amount"' <<< ${offlineJSON})")${NC}"
                  [[ ${otx_type} = "Asset Minting" ]] && println DEBUG "Assets Minted    : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-minted"' <<< ${offlineJSON})")${NC}"
                  [[ ${otx_type} = "Asset Burning" ]] && println DEBUG "Assets To Burn   : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-amount"' <<< ${offlineJSON})")${NC}"
                  [[ ${otx_type} = "Asset Burning" ]] && println DEBUG "Assets Left      : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-minted"' <<< ${offlineJSON})")${NC}"
                  jq -er '."drep-wallet-name"' <<< ${offlineJSON} &>/dev/null && println DEBUG "DRep Wallet      : ${FG_GREEN}$(jq -r '."drep-wallet-name"' <<< ${offlineJSON})${NC}"
                  jq -er '."drep-id"' <<< ${offlineJSON} &>/dev/null && println DEBUG "DRep ID          : ${FG_LGRAY}$(jq -r '."drep-id"' <<< ${offlineJSON})${NC}"
                  jq -er '."action-id"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Action ID        : ${FG_LGRAY}$(jq -r '."action-id"' <<< ${offlineJSON})${NC}"
                  jq -er '.vote' <<< ${offlineJSON} &>/dev/null && println DEBUG "Vote             : ${FG_LGRAY}$(jq -r '.vote' <<< ${offlineJSON})${NC}"
                  echo
                  ;;
              esac
              println DEBUG "Signing keys required:"
              for otx_signing_name_b64 in $(jq -r '."signing-file"[].name | @base64' <<< "${offlineJSON}"); do
                otx_signing_name=$(base64 -d <<< "${otx_signing_name_b64}")
                unset hasWitness
                for otx_witness_name in $(jq -r '.witness[].name' <<< "${offlineJSON}"); do
                  [[ ${otx_witness_name} = "${otx_signing_name}" ]] && hasWitness=true && break
                done
                [[ -z ${hasWitness} ]] && println DEBUG "${FG_LGRAY}${otx_signing_name}${NC} ${FG_RED}${ICON_CROSS}${NC}" || println DEBUG "${FG_LGRAY}${otx_signing_name}${NC} ${FG_GREEN}${ICON_CHECK}${NC}"
              done
              for otx_script in $(jq -r '."script-file"[] | @base64' <<< "${offlineJSON}"); do
                _jq() { base64 -d <<< ${otx_script} | jq -r "${1}"; }
                otx_script_name=$(_jq '.name')
                otx_script_scripts="$(_jq '.script' 2>/dev/null)"
                getAllMultiSigKeys "${otx_script_scripts}"
                unset required_total
                validateMultiSigScript false "${otx_script_scripts}"
                println DEBUG "${FG_LGRAY}${otx_script_name}${NC} - required signatures: ${FG_LBLUE}${required_total}${NC}"
                for sig in "${!script_sig_list[@]}"; do
                  unset hasWitness found_wallet_name
                  for otx_witness_name in $(jq -r '.witness[].name' <<< "${offlineJSON}"); do
                    [[ ${otx_witness_name} = "${sig}" ]] && hasWitness=true && break
                  done
                  while IFS= read -r -d '' wallet; do
                    wallet_name=$(basename ${wallet})
                    getWalletType "${wallet_name}"
                    getCredentials "${wallet_name}"
                    getGovKeyInfo "${wallet_name}"
                    if [[ ${ms_pay_cred} = "${sig}" || ${ms_stake_cred} = "${sig}" || ${pay_cred} = "${sig}" || ${stake_cred} = "${sig}" || ${ms_drep_hash} = "${sig}" || ${drep_hash} = "${sig}" ]]; then
                      found_wallet_name="${wallet_name}"; break
                    fi
                  done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0)
                  [[ -z ${hasWitness} ]] && println DEBUG "  ${FG_LGRAY}${sig}${NC} ${FG_RED}${ICON_CROSS}${NC}" || println DEBUG "  ${FG_LGRAY}$([[ -n ${found_wallet_name} ]] && echo ${found_wallet_name} || echo ${sig})${NC} ${FG_GREEN}${ICON_CHECK}${NC}"
                done
              done

              [[ $(jq -r '."signed-txBody" | length' <<< ${offlineJSON}) -gt 0 ]] && println INFO "\n${FG_GREEN}${ICON_CHECK}${NC} Transaction already signed, please submit transaction to complete!" && waitToProceed && continue
              [[ $(date '+%s' --date="${otx_date_expire}") -lt $(date '+%s') ]] && println ERROR "\n${FG_RED}ERROR${NC}: Transaction expired!  please create a new one with long enough Time To Live (TTL)" && waitToProceed && continue

              for otx_signing_file in $(jq -r '."signing-file"[] | @base64' <<< "${offlineJSON}"); do
                _jq() { base64 -d <<< ${otx_signing_file} | jq -r "${1}"; }
                otx_signing_name=$(_jq '.name')
                otx_vkey_cborHex="$(_jq '.vkey.cborHex' 2>/dev/null)"
                skey_path=""
                for otx_witness in $(jq -r '.witness[] | @base64' <<< "${offlineJSON}"); do
                  __jq() { base64 -d <<< ${otx_witness} | jq -r "${1}"; }
                  [[ $(_jq '.name') = $(__jq '.name') ]] && continue 2 # offline transaction already witnessed by this signing key
                done
                # look for signing key in wallet folder
                while IFS= read -r -d '' w_file; do
                  if [[ ${w_file} = */"${WALLET_PAY_SK_FILENAME}" || ${w_file} = */"${WALLET_STAKE_SK_FILENAME}" || ${w_file} = */"${WALLET_GOV_DREP_SK_FILENAME}" ]]; then
                    ! ${CCLI} key verification-key --signing-key-file "${w_file}" --verification-key-file "${TMP_DIR}"/tmp.vkey && continue
                    if [[ $(jq -er '.type' "${w_file}" 2>/dev/null) = *"Extended"* ]]; then
                      ! ${CCLI} key non-extended-key --extended-verification-key-file "${TMP_DIR}/tmp.vkey" --verification-key-file "${TMP_DIR}/tmp2.vkey" && continue
                      mv -f "${TMP_DIR}/tmp2.vkey" "${TMP_DIR}/tmp.vkey"
                    fi
                    grep -q "${otx_vkey_cborHex}" "${TMP_DIR}"/tmp.vkey && skey_path="${w_file}" && break
                  elif [[ ${w_file} = */"${WALLET_HW_PAY_SK_FILENAME}" || ${w_file} = */"${WALLET_HW_STAKE_SK_FILENAME}" ]]; then
                    grep -q "${otx_vkey_cborHex:4}" "${w_file}" && skey_path="${w_file}" && break # strip 5820 prefix
                  fi
                done < <(find "${WALLET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -print0 2>/dev/null)
                # look for cold signing key in pool folder
                if [[ -z ${skey_path} ]]; then
                  while IFS= read -r -d '' p_file; do
                    ! ${CCLI} key verification-key --signing-key-file "${p_file}" --verification-key-file "${TMP_DIR}"/tmp.vkey && continue
                    grep -q "${otx_vkey_cborHex}" "${TMP_DIR}"/tmp.vkey && skey_path="${p_file}" && break
                  done < <(find "${POOL_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${POOL_COLDKEY_SK_FILENAME}" -print0 2>/dev/null)
                fi
                # look for signing key in asset folder
                if [[ -z ${skey_path} ]]; then
                  while IFS= read -r -d '' a_file; do
                    ! ${CCLI} key verification-key --signing-key-file "${a_file}" --verification-key-file "${TMP_DIR}"/tmp.vkey && continue
                    grep -q "${otx_vkey_cborHex}" "${TMP_DIR}"/tmp.vkey && skey_path="${a_file}" && break
                  done < <(find "${ASSET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${ASSET_POLICY_SK_FILENAME}" -print0 2>/dev/null)
                fi

                if [[ -n ${skey_path} ]]; then
                  println DEBUG "\nFound a match for ${otx_signing_name}, use this file ? : ${FG_LGRAY}${skey_path}${NC}"
                  select_opt "[y] Yes" "[s] Skip"
                  case $? in
                    0)  if ! witnessTx "${TMP_DIR}/tx.raw" "${skey_path}"; then waitToProceed && continue 2; fi
                        if ! offlineJSON=$(jq ".witness += [{ name: \"${otx_signing_name}\", witnessBody: $(jq -c . "${tx_witness_files[0]}") }]" <<< ${offlineJSON}); then return 1; fi
                        jq -r . <<< "${offlineJSON}" > "${offline_tx}" # save this witness to disk
                        continue ;;
                    1)  continue ;;
                  esac
                else
                  println DEBUG "\nDo you want to sign ${otx_type} with: ${FG_LGRAY}${otx_signing_name}${NC} ?"
                  select_opt "[y] Yes" "[s] Skip"
                  selection=$?
                fi
                [[ ${selection} -eq 1 ]] && continue
                if [[ ${otx_signing_name} = "Pool "* ]]; then dialog_start_path="${POOL_FOLDER}"
                elif [[ ${otx_signing_name} = "Asset "* ]]; then dialog_start_path="${ASSET_FOLDER}"
                else dialog_start_path="${WALLET_FOLDER}"; fi
                fileDialog "\nEnter path to ${otx_signing_name}" "${dialog_start_path}/"
                [[ ! -f "${file}" ]] && println ERROR "${FG_RED}ERROR${NC}: file not found: ${file}" && waitToProceed && continue
                if [[ ${file} = "${ASSET_POLICY_SCRIPT_FILENAME}" ]]; then
                  if ! grep -q "$(_jq '.script.keyHash')" "${file}"; then
                    println ERROR "${FG_RED}ERROR${NC}: script file provided doesn't match with script hash in transaction for: ${otx_signing_name}"
                    println ERROR "Provided asset script keyHash: $(jq -r '.keyHash' "${file}")"
                    println ERROR "Transaction asset script keyHash: $(_jq '.script.keyHash')"
                    waitToProceed && continue 2
                  fi
                elif [[ $(jq -er '.description' "${file}" 2>/dev/null) = *"Hardware"* ]]; then
                  if ! grep -q "${otx_vkey_cborHex:4}" "${file}"; then # strip 5820 prefix
                    println ERROR "${FG_RED}ERROR${NC}: signing key provided doesn't match with verification key in transaction for: ${otx_signing_name}"
                    println ERROR "Provided hardware signing key's verification cborXPubKeyHex: $(jq -r .cborXPubKeyHex "${file}")"
                    println ERROR "Transaction verification cborHex: ${otx_vkey_cborHex:4}"
                    waitToProceed && continue 2
                  fi
                else
                  println ACTION "${CCLI} key verification-key --signing-key-file ${file} --verification-key-file ${TMP_DIR}/tmp.vkey"
                  if ! stdout=$(${CCLI} key verification-key --signing-key-file "${file}" --verification-key-file "${TMP_DIR}"/tmp.vkey 2>&1); then
                    println ERROR "\n${FG_RED}ERROR${NC}: failure during verification key creation!\n${stdout}"; waitToProceed && continue 2
                  fi
                  if [[ $(jq -r '.type' "${file}") = *"Extended"* ]]; then
                    println ACTION "${CCLI} key non-extended-key --extended-verification-key-file ${TMP_DIR}/tmp.vkey --verification-key-file ${TMP_DIR}/tmp2.vkey"
                    if ! stdout=$(${CCLI} key non-extended-key --extended-verification-key-file "${TMP_DIR}/tmp.vkey" --verification-key-file "${TMP_DIR}/tmp2.vkey" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during non-extended verification key creation!\n${stdout}"; waitToProceed && continue 2
                    fi
                    mv -f "${TMP_DIR}/tmp2.vkey" "${TMP_DIR}/tmp.vkey"
                  fi
                  if [[ ${otx_vkey_cborHex} != $(jq -r .cborHex "${TMP_DIR}"/tmp.vkey) ]]; then
                    println ERROR "${FG_RED}ERROR${NC}: signing key provided doesn't match with verification key in transaction for: ${otx_signing_name}"
                    println ERROR "Provided signing key's verification cborHex: $(jq -r .cborHex "${TMP_DIR}"/tmp.vkey)"
                    println ERROR "Transaction verification cborHex: ${otx_vkey_cborHex}"
                    waitToProceed && continue 2
                  fi
                fi
                if ! witnessTx "${TMP_DIR}/tx.raw" "${file}"; then waitToProceed && continue 2; fi
                if ! offlineJSON=$(jq ".witness += [{ name: \"${otx_signing_name}\", witnessBody: $(jq -c . "${tx_witness_files[0]}") }]" <<< ${offlineJSON}); then return 1; fi
                jq -r . <<< "${offlineJSON}" > "${offline_tx}" # save this witness to disk
              done
              unset script_failed pay_script_signers stake_script_signers drep_script_signers
              for otx_script in $(jq -r '."script-file"[] | @base64' <<< "${offlineJSON}"); do
                _jq() { base64 -d <<< ${otx_script} | jq -r "${1}"; }
                otx_script_name=$(_jq '.name')
                otx_script_scripts="$(_jq '.script' 2>/dev/null)"
                getAllMultiSigKeys "${otx_script_scripts}"
                # loop once to add all already signed creds
                missing_creds=()
                script_sig_creds=()
                for sig in "${!script_sig_list[@]}"; do
                  for otx_witness in $(jq -r '.witness[] | @base64' <<< "${offlineJSON}"); do
                    __jq() { base64 -d <<< ${otx_witness} | jq -r "${1}"; }
                    [[ ${sig} = $(__jq '.name') ]] && script_sig_creds+=( ${sig} ) && continue 2 # offline transaction already witnessed by this signing key
                  done
                  missing_creds+=( "${sig}" )
                done
                # Check if script meets requirement
                if validateMultiSigScript false "${otx_script_scripts}" "${script_sig_creds[@]}"; then
                  # script successfully validated, no more signatures needed
                  println DEBUG "\n${FG_LGRAY}${otx_script_name}${NC} validation ${FG_GREEN}passed${NC}! No more signatures needed!"
                  continue
                fi
                # loop again if needed
                for sig in "${missing_creds[@]}"; do
                  # Check if script meets requirement
                  if validateMultiSigScript false "${otx_script_scripts}" "${script_sig_creds[@]}"; then
                    # script successfully validated, no more signatures needed
                    println DEBUG "\n${FG_LGRAY}${otx_script_name}${NC} validation ${FG_GREEN}passed${NC}! No more signatures needed!"
                    break
                  fi
                  unset skey_path
                  # look for matching credential in wallet folder
                  while IFS= read -r -d '' wallet; do
                    wallet_name=$(basename ${wallet})
                    getWalletType "${wallet_name}"
                    getCredentials "${wallet_name}"
                    getGovKeyInfo "${wallet_name}"
                    if [[ ${ms_pay_cred} = "${sig}" ]]; then
                      skey_path="${ms_payment_sk_file}"; break
                    elif [[ ${ms_stake_cred} = "${sig}" ]]; then
                      skey_path="${ms_stake_sk_file}"; break
                    elif [[ ${pay_cred} = "${sig}" ]]; then
                      skey_path="${payment_sk_file}"; break
                    elif [[ ${stake_cred} = "${sig}" ]]; then
                      skey_path="${stake_sk_file}"; break
                    elif [[ ${ms_drep_hash} = "${sig}" ]]; then
                      skey_path="${ms_drep_sk_file}"; break
                    elif [[ ${drep_hash} = "${sig}" ]]; then
                      skey_path="${drep_sk_file}"; break
                    fi
                  done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0)
                  [[ -n ${skey_path} && ! -f "${skey_path}" ]] && println ERROR "\n${FG_YELLOW}WARN${NC}: Wallet match found but signing key missing: ${skey_path}" && unset skey_path
                  # matching MultiSig participant wallet found?
                  if [[ -n ${skey_path} ]]; then
                    println DEBUG "\nFound a matching wallet for ${FG_LGRAY}${otx_script_name}${NC}, use this file ? : ${FG_LGRAY}${skey_path}${NC}"
                    select_opt "[y] Yes" "[s] Skip participant"
                    case $? in
                      0)  if ! witnessTx "${TMP_DIR}/tx.raw" "${skey_path}"; then waitToProceed && continue; fi
                          if ! offlineJSON=$(jq ".witness += [{ name: \"${sig}\", witnessBody: $(jq -c . "${tx_witness_files[0]}") }]" <<< ${offlineJSON}); then return 1; fi
                          jq -r . <<< "${offlineJSON}" > "${offline_tx}" # save this witness to disk
                          script_sig_creds+=( ${sig} )
                          continue ;;
                      1)  continue ;;
                    esac
                  else
                    println DEBUG "\nNo match found, continue with manual input to signature file for ${FG_LGRAY}${otx_script_name}${NC} with credential below?\n${FG_LGRAY}${sig}${NC}"
                    select_opt "[p] Enter path" "[s] Skip participant"
                    selection=$?
                  fi
                  if [[ ${selection} -eq 1 ]]; then
                    continue
                  else
                    # choose
                    fileDialog "\nEnter path to signing key for MultiSig participant" "${WALLET_FOLDER}/"
                    [[ ! -f "${file}" ]] && println ERROR "${FG_RED}ERROR${NC}: file not found: ${file}" && waitToProceed && continue
                    file_desc=$(jq -er '.description' "${file}" 2>/dev/null)
                    if [[ ${file_desc} = *"Hardware"* ]]; then
                      dir_path=$(dirname "${file}")
                      if ! vkey=$(jq -er .cborXPubKeyHex "${file}"); then
                        println ERROR "${FG_RED}ERROR${NC}: signing key provided is invalid, missing field 'cborXPubKeyHex'" && continue
                      fi
                      vkey=${vkey:4:64}
                      # find vkey file in same folder
                      if ! vkey_file=$(grep -l "cborHex.*${vkey}" "${dir_path}"/*); then
                        println ERROR "${FG_RED}ERROR${NC}: unable to find a matching verification key file for provided hardware signing key in same folder" && continue
                      fi
                      vkey_file=$(echo "${vkey_file}" | head -n 1) # make sure there is a single match
                      if [[ ${file_desc} = *"Payment"* ]]; then
                        cred_type=payment
                      elif [[ ${file_desc} = *"Stake"* ]]; then
                        cred_type=stake
                      else
                        cred_type=drep
                      fi
                      getCredential ${cred_type} ${vkey_file}
                    else
                      println ACTION "${CCLI} key verification-key --signing-key-file ${file} --verification-key-file ${TMP_DIR}/tmp.vkey"
                      if ! stdout=$(${CCLI} key verification-key --signing-key-file "${file}" --verification-key-file "${TMP_DIR}"/tmp.vkey 2>&1); then
                        println ERROR "\n${FG_RED}ERROR${NC}: failure during verification key creation!\n${stdout}"; waitToProceed && continue
                      fi
                      file_type=$(jq -r '.type' "${file}")
                      if [[ ${file_type} = *"Extended"* ]]; then
                        println ACTION "${CCLI} key non-extended-key --extended-verification-key-file ${TMP_DIR}/tmp.vkey --verification-key-file ${TMP_DIR}/tmp2.vkey"
                        if ! stdout=$(${CCLI} key non-extended-key --extended-verification-key-file "${TMP_DIR}/tmp.vkey" --verification-key-file "${TMP_DIR}/tmp2.vkey" 2>&1); then
                          println ERROR "\n${FG_RED}ERROR${NC}: failure during non-extended verification key creation!\n${stdout}"; waitToProceed && continue
                        fi
                        mv -f "${TMP_DIR}/tmp2.vkey" "${TMP_DIR}/tmp.vkey"
                      fi
                      if [[ ${file_desc} = *"Payment"* ]]; then
                        cred_type=payment
                      elif [[ ${file_desc} = *"Stake"* ]]; then
                        cred_type=stake
                      else
                        cred_type=drep
                      fi
                      getCredential ${cred_type} "${TMP_DIR}"/tmp.vkey
                    fi
                    if [[ ${cred} != "${sig}" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: signing key provided doesn't match with credential in MultiSig script:${FG_LGRAY}${otx_script_name}${NC}"
                      println ERROR "Provided signing key's credential  : ${FG_LGRAY}${cred}${NC}"
                      println ERROR "Looking for credential             : ${FG_LGRAY}${sig}${NC}"
                      waitToProceed && continue
                    fi
                    if ! witnessTx "${TMP_DIR}/tx.raw" "${file}"; then waitToProceed && continue; fi
                    if ! offlineJSON=$(jq ".witness += [{ name: \"${sig}\", witnessBody: $(jq -c . "${tx_witness_files[0]}") }]" <<< ${offlineJSON}); then return 1; fi
                    jq -r . <<< "${offlineJSON}" > "${offline_tx}" # save this witness to disk
                    script_sig_creds+=( ${sig} )
                  fi
                done
                unset required_total
                if ! validateMultiSigScript true "${otx_script_scripts}" "${script_sig_creds[@]}"; then
                  # script failed validation
                  script_failed=true
                  println ERROR "\nUnable to submit transaction until needed signatures are added and/or time lock conditions if set pass!"
                  println DEBUG "If external participant signatures are needed, pass transaction file along to add additional signatures."
                  waitToProceed
                fi
                if [[ ${otx_script_name} = *"payment"* ]]; then
                  pay_script_signers=${required_total}
                elif [[ ${otx_script_name} = *"stake"* ]]; then
                  stake_script_signers=${required_total}
                else
                  drep_script_signers=${required_total}
                fi
              done
              signatures_needed=$(( $(jq -r '."signing-file" | length' <<< "${offlineJSON}") + pay_script_signers + stake_script_signers + drep_script_signers ))
              witness_cnt=$(jq -r '.witness | length' <<< "${offlineJSON}")
              if [[ ${witness_cnt} -ge ${signatures_needed} && -z ${script_failed} ]]; then # witnessed by all needed signing keys
                tx_witness_files=()
                for otx_witness in $(jq -r '.witness[] | @base64' <<< "${offlineJSON}"); do
                  _jq() { base64 -d <<< ${otx_witness} | jq -r "${1}"; }
                  tx_witness="$(mktemp "${TMP_DIR}/tx.witness_XXXXXXXXXX")"
                  jq -r . <<< "$(_jq '.witnessBody')" > "${tx_witness}"
                  tx_witness_files+=( "${tx_witness}" )
                done
                if ! assembleTx "${TMP_DIR}/tx.raw"; then waitToProceed && continue; fi
                if jq ". += { \"signed-txBody\": $(jq -c . "${tx_signed}") }" <<< "${offlineJSON}" > "${offline_tx}"; then
                  println "\nTransaction successfully assembled and signed by all needed signing keys"
                  println "please submit on online node before ${FG_LGRAY}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}!"
                else
                  println ERROR "${FG_RED}ERROR${NC}: failed to write signed tx body to offline transaction file!"
                fi
              else
                println "Transaction need to be signed by ${FG_LBLUE}${signatures_needed}${NC} signing keys, signed by ${FG_LBLUE}${witness_cnt}${NC} so far!"
              fi
              waitToProceed && continue
              ;; ###################################################################
            submit)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> TRANSACTION >> SUBMIT"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              fi
              echo
              fileDialog "Enter path to offline tx file to submit" "${TMP_DIR}/" && echo
              offline_tx=${file}
              [[ -z "${offline_tx}" ]] && continue
              if [[ ! -f "${offline_tx}" ]]; then
                println ERROR "${FG_RED}ERROR${NC}: file not found: ${offline_tx}"
                waitToProceed && continue
              elif ! offlineJSON=$(jq -erc . "${offline_tx}"); then
                println ERROR "${FG_RED}ERROR${NC}: invalid JSON file: ${offline_tx}"
                waitToProceed && continue
              fi
              if ! otx_type=$(jq -er '.type' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'type' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_date_created=$(jq -er '."date-created"' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'date-created' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_date_expire=$(jq -er '."date-expire"' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'date-expire' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_txFee=$(jq -er '.txFee' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'txFee' not found in: ${offline_tx}" && waitToProceed && continue; fi
              if ! otx_signed_txBody=$(jq -er '."signed-txBody"' <<< ${offlineJSON}); then println ERROR "${FG_RED}ERROR${NC}: field 'signed-txBody' not found in: ${offline_tx}" && waitToProceed && continue; fi
              [[ $(jq 'length' <<< ${otx_signed_txBody}) -eq 0 ]] && println ERROR "${FG_RED}ERROR${NC}: transaction not signed, please sign transaction first!" && waitToProceed && continue
              println DEBUG "Transaction type : ${FG_YELLOW}${otx_type}${NC}"
              if jq -er '."wallet-name"' &>/dev/null <<< ${offlineJSON}; then
                println DEBUG "Transaction fee  : ${FG_LBLUE}$(formatLovelace ${otx_txFee})${NC} ADA, payed by ${FG_GREEN}$(jq -r '."wallet-name"' <<< ${offlineJSON})${NC}"
              else
                println DEBUG "Transaction fee  : ${FG_LBLUE}$(formatLovelace ${otx_txFee})${NC} ADA"
              fi
              println DEBUG "Created          : ${FG_LGRAY}$(date '+%F %T %Z' --date="${otx_date_created}")${NC}"
              [[ $(date '+%s' --date="${otx_date_expire}") -lt $(date '+%s') ]] && expire_color="${FG_RED}" || expire_color="${FG_LGRAY}"
              println DEBUG "Expire           : ${expire_color}$(date '+%F %T %Z' --date="${otx_date_expire}")${NC}"
              echo
              [[ ${otx_type} = "Wallet De-Registration" ]] && println DEBUG "Amount returned  : ${FG_LBLUE}$(formatLovelace "$(jq -r '."amount-returned"' <<< ${offlineJSON})")${NC} ADA"
              if [[ ${otx_type} = "Payment" ]]; then
                println DEBUG "Source addr      : ${FG_LGRAY}$(jq -r '."source-address"' <<< ${offlineJSON})${NC}"
                println DEBUG "Destination addr : ${FG_LGRAY}$(jq -r '."destination-address"' <<< ${offlineJSON})${NC}"
                println DEBUG "Amount           : ${FG_LBLUE}$(formatLovelace "$(jq -r '.assets[] | select(.asset=="lovelace") | .amount' <<< ${offlineJSON})")${NC} ${FG_GREEN}ADA${NC}"
                for otx_assets in $(jq -r '.assets[] | @base64' <<< "${offlineJSON}"); do
                  _jq() { base64 -d <<< ${otx_assets} | jq -r "${1}"; }
                  otx_asset=$(_jq '.asset')
                  [[ ${otx_asset} = "lovelace" ]] && continue
                  println DEBUG "                   ${FG_LBLUE}$(formatAsset "$(_jq '.amount')")${NC} ${FG_LGRAY}${otx_asset}${NC}"
                done
              fi
              [[ ${otx_type} = "Wallet Rewards Withdrawal" ]] && println DEBUG "Rewards          : ${FG_LBLUE}$(formatLovelace "$(jq -r '.rewards' <<< ${offlineJSON})")${NC} ADA"
              jq -er '."pool-id"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Pool ID          : ${FG_LGRAY}$(jq -r '."pool-id"' <<< ${offlineJSON})${NC}"
              if jq -er '."pool-name"' <<< ${offlineJSON} &>/dev/null; then
                [[ ${otx_type} != "Pool Registration" ]] && println DEBUG "Pool name        : ${FG_LGRAY}$(jq -r '."pool-name"' <<< ${offlineJSON})${NC}"
              fi
              [[ ${otx_type} = "Pool De-Registration" ]] && println DEBUG "Ticker           : ${FG_LGRAY}$(jq -r '."pool-ticker"' <<< ${offlineJSON})${NC}"
              [[ ${otx_type} = "Pool De-Registration" ]] && println DEBUG "To be retired    : epoch ${FG_LGRAY}$(jq -r '."retire-epoch"' <<< ${offlineJSON})${NC}"
              jq -er '.metadata' <<< ${offlineJSON} &>/dev/null && println DEBUG "Metadata         :\n$(jq -r '.metadata' <<< ${offlineJSON})\n"
              [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Pool name        : ${FG_LGRAY}$(jq -r '."pool-metadata".name' <<< ${offlineJSON})${NC}"
              [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Ticker           : ${FG_LGRAY}$(jq -r '."pool-metadata".ticker' <<< ${offlineJSON})${NC}"
              [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Pledge           : ${FG_LBLUE}$(formatLovelace "$(ADAToLovelace "$(jq -r '."pool-pledge"' <<< ${offlineJSON})")")${NC} ADA"
              [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Margin           : ${FG_LBLUE}$(jq -r '."pool-margin"' <<< ${offlineJSON})${NC} %"
              [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]] && println DEBUG "Cost             : ${FG_LBLUE}$(formatLovelace "$(ADAToLovelace "$(jq -r '."pool-cost"' <<< ${offlineJSON})")")${NC} ADA"
              [[ ${otx_type} = "Asset Minting" || ${otx_type} = "Asset Burning" ]] && println DEBUG "Policy Name      : ${FG_LGRAY}$(jq -r '."policy-name"' <<< ${offlineJSON})${NC}"
              [[ ${otx_type} = "Asset Minting" || ${otx_type} = "Asset Burning" ]] && println DEBUG "Policy ID        : ${FG_LGRAY}$(jq -r '."policy-id"' <<< ${offlineJSON})${NC}"
              [[ ${otx_type} = "Asset Minting" || ${otx_type} = "Asset Burning" ]] && println DEBUG "Asset Name       : ${FG_LGRAY}$(jq -r '."asset-name"' <<< ${offlineJSON})${NC}"
              [[ ${otx_type} = "Asset Minting" ]] && println DEBUG "Assets To Mint   : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-amount"' <<< ${offlineJSON})")${NC}"
              [[ ${otx_type} = "Asset Minting" ]] && println DEBUG "Assets Minted    : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-minted"' <<< ${offlineJSON})")${NC}"
              [[ ${otx_type} = "Asset Burning" ]] && println DEBUG "Assets To Burn   : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-amount"' <<< ${offlineJSON})")${NC}"
              [[ ${otx_type} = "Asset Burning" ]] && println DEBUG "Assets Left      : ${FG_LBLUE}$(formatAsset "$(jq -r '."asset-minted"' <<< ${offlineJSON})")${NC}"
              if [[ ${otx_type} = "Asset Minting" || ${otx_type} = "Asset Burning" ]] && otx_metadata=$(jq -er '.metadata' <<< ${offlineJSON}); then println DEBUG "Metadata         : \n${otx_metadata}\n"; fi
              jq -er '."drep-wallet-name"' <<< ${offlineJSON} &>/dev/null && println DEBUG "DRep Wallet      : ${FG_GREEN}$(jq -r '."drep-wallet-name"' <<< ${offlineJSON})${NC}"
              jq -er '."drep-hash"' <<< ${offlineJSON} &>/dev/null && println DEBUG "DRep Hash        : ${FG_LGRAY}$(jq -r '."drep-hash"' <<< ${offlineJSON})${NC}"
              jq -er '."drep-id-cip105"' <<< ${offlineJSON} &>/dev/null && println DEBUG "DRep ID CIP-105  : ${FG_LGRAY}$(jq -r '."drep-id-cip105"' <<< ${offlineJSON})${NC}"
              jq -er '."drep-id-cip129"' <<< ${offlineJSON} &>/dev/null && println DEBUG "DRep ID CIP-129  : ${FG_LGRAY}$(jq -r '."drep-id-cip129"' <<< ${offlineJSON})${NC}"
              jq -er '."action-id"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Action ID        : ${FG_LGRAY}$(jq -r '."action-id"' <<< ${offlineJSON})${NC}"
              jq -er '."action-id-cip129"' <<< ${offlineJSON} &>/dev/null && println DEBUG "Action ID CIP-129: ${FG_LGRAY}$(jq -r '."action-id-cip129"' <<< ${offlineJSON})${NC}"
              jq -er '.vote' <<< ${offlineJSON} &>/dev/null && println DEBUG "Vote             : ${FG_LGRAY}$(jq -r '.vote' <<< ${offlineJSON})${NC}"

              if [[ $(date '+%s' --date="${otx_date_expire}") -lt $(date '+%s') ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: Transaction expired!  please create a new one with long enough Time To Live (TTL)"
                waitToProceed && continue
              fi

              tx_signed="${TMP_DIR}/tx.signed_$(date +%s)"
              println DEBUG "\nProceed to submit transaction?"
              select_opt "[y] Yes" "[n] No"
              case $? in
                0) : ;;
                1) continue ;;
              esac
              echo -e "${otx_signed_txBody}" > "${tx_signed}"
              if ! submitTx "${tx_signed}"; then waitToProceed && continue; fi
              if [[ ${otx_type} = "Pool Registration" || ${otx_type} = "Pool Update" ]]; then
                if otx_pool_name=$(jq -er '."pool-name"' <<< ${offlineJSON}); then
                  if ! jq '."pool-reg-cert"' <<< "${offlineJSON}" > "${POOL_FOLDER}/${otx_pool_name}/${POOL_REGCERT_FILENAME}"; then println ERROR "${FG_RED}ERROR${NC}: failed to write pool cert to disk"; fi
                  [[ -f "${POOL_FOLDER}/${otx_pool_name}/${POOL_DEREGCERT_FILENAME}" ]] && rm -f "${POOL_FOLDER}/${otx_pool_name}/${POOL_DEREGCERT_FILENAME}" # delete de-registration cert if available
                else
                  println ERROR "${FG_RED}ERROR${NC}: field 'pool-name' not found in: ${offline_tx}"
                fi
              fi
              echo
              verifyTx
              echo
              println DEBUG "Delete submitted offline transaction file?"
              select_opt "[y] Yes" "[n] No"
              case $? in
                0) rm -f "${offline_tx}" ;;
                1) : ;;
              esac
              waitToProceed && continue
              ;; ###################################################################
          esac # transaction sub OPERATION
        done # Transaction loop
        ;; ###################################################################
      vote)
        while true; do # Vote loop
          clear
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println " >> VOTE"
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println OFF " Voting and Governance\n"\
            " ) Governance  - on-chain governance according to CIP-1694"\
            " ) Catalyst    - project funding platform"\
            "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println DEBUG " Select Vote Operation\n"
          select_opt "[g] Governance" "[c] Catalyst" "[h] Home"
          case $? in
            0) SUBCOMMAND="governance" ;;
            1) SUBCOMMAND="catalyst" ;;
            2) break ;;
          esac
          case $SUBCOMMAND in
            governance)
              while true; do # Governance loop
                clear
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println " >> VOTE >> GOVERNANCE (CIP-1694)"
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println OFF " Governance\n"\
                  " ) Info & Status  - show wallet governance information and status"\
                  " ) Delegate       - delegate wallet vote power to a DRep (own, external, or one of the pre-defined 'abstain' / 'no confidence')"\
                  " ) List proposals - show a list of active proposals to vote on and their current vote status"\
                  " ) Cast Vote      - vote on governance actions as an SPO, DRep, or Committee member"\
                  " ) DRep Reg / Upd - register wallet as a DRep for voting or submit updated anchor data for already DRep registered wallet"\
                  " ) DRep Retire    - retire wallet as a DRep"\
                  " ) MultiSig DRep  - create a multi-participant (MultiSig) DRep coalition"\
                  " ) Derive Keys    - derive delegate representative (DRep) and committee member keys (if needed)"\
                  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println DEBUG " Select Governance Operation\n"
                select_opt "[i] Info & Status" "[d] Delegate" "[l] List Proposals" "[v] Cast vote" "[r] DRep Registration / Update" "[x] DRep Retire" "[m] MultiSig DRep" "[k] Derive Keys" "[b] Back" "[h] Home"
                case $? in
                  0) SUBCOMMAND="info-status" ;;
                  1) SUBCOMMAND="delegate" ;;
                  2) SUBCOMMAND="list-proposals" ;;
                  3) SUBCOMMAND="vote" ;;
                  4) SUBCOMMAND="drep-reg" ;;
                  5) SUBCOMMAND="drep-ret" ;;
                  6) SUBCOMMAND="create-ms-drep" ;;
                  7) SUBCOMMAND="derive-gov-keys" ;;
                  8) break ;;
                  9) break 2 ;;
                esac
                case $SUBCOMMAND in
                  info-status)
                    cntools_compatibility_dispatch_action vote.governance.info
                    action_status=$?
                    case "${action_status}" in
                      0) continue ;;
                      20|21) break 2 ;;
                      22) myExit ;;
                      *) waitToProceed; continue ;;
                    esac
                    ;; ###################################################################
                  delegate)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> GOVERNANCE >> DELEGATE"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    unset drep_id_cip129
                    if ! versionCheck "9.0" "${PROT_VERSION}"; then
                      println INFO "\n${FG_YELLOW}Not yet in Conway era, please revisit once network has crossed into Cardano governance era!${NC}"; waitToProceed && continue
                    fi
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    println DEBUG "\nSelect wallet"
                    selectWallet "balance"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    _wallet_name="${wallet_name}"
                    if ! isWalletRegistered ${wallet_name}; then
                      if [[ ${op_mode} = "online" ]]; then
                        # maybe this block below should be a part of registerStakeWallet?
                        getWalletBalance ${wallet_name} true true false true
                        if [[ ${base_lovelace} -lt ${KEY_DEPOSIT} ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: insufficient funds (${base_lovelace}) available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                          println DEBUG "Funds for key deposit($(formatLovelace ${KEY_DEPOSIT}) ADA) + transaction fee needed to register the wallet"
                          waitToProceed && continue
                        fi

                        if ! registerStakeWallet ${wallet_name}; then waitToProceed && continue; fi
                      else
                        println ERROR "\n${FG_YELLOW}The wallet is not a registered wallet on chain and CNTools run in hybrid mode${NC}"
                        println ERROR "Please first register the wallet using 'Wallet >> Register'"
                        waitToProceed && continue
                      fi
                    fi
                    unset drep_wallet drep_hash
                    println DEBUG "\nDo you want to delegate to a local CNTools DRep registered wallet, pre-defined type or specify the DRep?"
                    select_opt "[w] CNTools DRep Wallet" "[i] DRep ID" "[a] Always Abstain" "[c] Always No Confidence" "[Esc] Cancel"
                    case $? in
                      0) selectWallet "none"
                        case $? in
                          1) waitToProceed; continue ;;
                          2) continue ;;
                        esac
                        drep_wallet="${wallet_name}"
                        wallet_name="${_wallet_name}"
                        getGovKeyInfo "${drep_wallet}"
                        if [[ -z ${drep_id} ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: unable to get DRep id from selected wallet :("
                          waitToProceed && continue
                        fi
                        ;;
                      1) getAnswerAnyCust drep_id "DRep ID [CIP-105 or CIP-129] (blank to cancel)"
                        [[ -z "${drep_id}" ]] && continue
                        parseDRepId "${drep_id}"
                        [[ -z ${drep_id} ]] && println ERROR "\n${FG_RED}ERROR${NC}: invalid DRep ID entered!" && waitToProceed && continue
                        ;;
                      2) drep_id="alwaysAbstain"; vote_param_arr=("--always-abstain") ;;
                      3) drep_id="alwaysNoConfidence"; vote_param_arr=("--always-no-confidence") ;;
                      4) continue ;;
                    esac
                    unset drep_expiry
                    if [[ ${drep_id} != always* ]]; then
                      getDRepStatus ${hash_type} ${drep_hash}
                      if [[ -z ${drep_expiry} ]]; then
                        println ERROR "\n${FG_RED}ERROR${NC}: selected DRep not registered"
                        waitToProceed && continue
                      fi
                      if [[ $(getEpoch) -ge ${drep_expiry} ]]; then
                        println ERROR "\n${FG_YELLOW}WARN${NC}: selected DRep is marked as inactive and its vote power doesn't currently count, continue anyway?"
                        select_opt "[y] Yes" "[n] No"
                        case $? in
                          0) : ;; # do nothing
                          1) continue ;;
                        esac
                      fi
                      [[ ${hash_type} = keyHash ]] && vote_param_arr=("--drep-key-hash" "${drep_hash}") || vote_param_arr=("--drep-script-hash" "${drep_hash}")
                      getDRepVotePower keyHash ${drep_hash}
                      [[ -z ${vote_power} ]] && getDRepVotePower scriptHash ${drep_hash}
                      if [[ -z ${vote_power} ]]; then
                        println ERROR "\n${FG_YELLOW}WARN${NC}: selected DRep has no active vote power associated with it, continue?"
                        select_opt "[y] Yes" "[n] No"
                        case $? in
                          0) : ;; # do nothing
                          1) continue ;;
                        esac
                      fi
                    else
                      getDRepVotePower "${drep_id}"
                    fi
                    getWalletBalance ${wallet_name} true true false true
                    if [[ ${base_lovelace} -le 0 ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                      println DEBUG "Funds for transaction fee needed to create vote delegation transaction"
                      waitToProceed && continue
                    fi
                    if ! voteDelegation; then
                      [[ -f ${vote_deleg_cert_file} ]] && rm -f ${vote_deleg_cert_file}
                      waitToProceed && continue
                    fi
                    echo
                    if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
                    echo
                    println "${FG_GREEN}${wallet_name}${NC} successfully delegated to DRep!"
                    echo
                    println "DRep ID                : CIP-105 => ${FG_LGRAY}${drep_id}${NC}"
                    if [[ -n ${drep_id_cip129} ]]; then
                      println "                       : CIP-129 => ${FG_LGRAY}${drep_id_cip129}${NC}"
                    fi
                    if [[ -n ${drep_expiry} ]]; then
                      [[ $(getEpoch) -lt ${drep_expiry} ]] && expire_status="${FG_GREEN}active${NC}" || expire_status="${FG_RED}inactive${NC} (vote power does not count)"
                      println "DRep expiry            : epoch ${FG_LBLUE}${drep_expiry}${NC} - ${expire_status}"
                    fi
                    println "Active DRep vote power : ${FG_LBLUE}$(formatLovelace ${vote_power:=0})${NC} ADA (${FG_LBLUE}${vote_power_pct:=0} %${NC})"
                    waitToProceed && continue
                    ;; ###################################################################
                  list-proposals)
                    cntools_compatibility_dispatch_action vote.governance.proposals
                    action_status=$?
                    case "${action_status}" in
                      0) continue ;;
                      20|21) break 2 ;;
                      22) myExit ;;
                      *) waitToProceed; continue ;;
                    esac
                    ;; ###################################################################
                  vote)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> GOVERNANCE >> CAST VOTE"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    if ! versionCheck "9.0" "${PROT_VERSION}"; then
                      println INFO "${FG_YELLOW}Not yet in Conway era, please revisit once network has crossed into Cardano governance era!${NC}"; waitToProceed && continue
                    fi
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    println DEBUG "\nSelect role to vote as"
                    select_opt "[s] SPO" "[d] DRep" "[c] Committee member" "[Esc] Cancel"
                    case $? in
                      0) vote_mode="spo"
                        selectPool "reg" "${POOL_COLDKEY_VK_FILENAME}"
                        case $? in
                          1) waitToProceed; continue ;;
                          2) continue ;;
                        esac
                        println DEBUG "\nSelect wallet to pay for transaction fee"
                        selectWallet "balance" ${WALLET_PAY_VK_FILENAME}
                        case $? in
                          1) waitToProceed; continue ;;
                          2) continue ;;
                        esac
                        getPoolID "${pool_name}"
                        pool_coldkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_VK_FILENAME}"
                        pool_coldkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_COLDKEY_SK_FILENAME}"
                        ;;
                      1) vote_mode="drep"
                        selectWallet "none"
                        case $? in
                          1) waitToProceed; continue ;;
                          2) continue ;;
                        esac
                        drep_wallet_name="${wallet_name}"
                        getGovKeyInfo ${drep_wallet_name}
                        if [[ -z ${hash_type} ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: Wallet missing governance keys!"
                          waitToProceed && continue
                        elif [[ ${hash_type} = "scriptHash" ]]; then
                          println DEBUG "\nSelect wallet to pay for transaction fee"
                          selectWallet "balance" ${WALLET_PAY_VK_FILENAME}
                          case $? in
                            1) waitToProceed; continue ;;
                            2) continue ;;
                          esac
                        fi
                        ;;
                      2) vote_mode="committee"
                        selectWallet "none" "${WALLET_GOV_CC_HOT_VK_FILENAME}"
                        case $? in
                          1) waitToProceed; continue ;;
                          2) continue ;;
                        esac
                        getGovKeyInfo ${wallet_name}
                        if [[ -z ${cc_cold_id} || -z ${cc_hot_id} ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: Wallet missing governance committee keys!"
                          waitToProceed && continue
                        fi
                        ;;
                      4) continue ;;
                    esac
                    if [[ ${vote_mode} = "committee" ]]; then
                      isCommitteeMember "$(bech32 <<< ${cc_cold_id})" "$(bech32 <<< ${cc_hot_id})"
                      case $? in
                        0) : ;; # ok
                        1) println ERROR "\n${FG_RED}ERROR${NC}: selected wallet is not an active committee member!"
                           waitToProceed && continue ;;
                        2) println ERROR "\n${FG_RED}ERROR${NC}: selected wallet is an active committee member but have not authorized hot credential for voting!"
                           waitToProceed && continue ;;
                        3) println ERROR "\n${FG_RED}ERROR${NC}: selected wallet has resigned as a committee member!"
                           waitToProceed && continue ;;
                      esac
                      hash_type="keyHash"
                    elif [[ ${vote_mode} = "drep" ]]; then
                      if ! getDRepStatus ${hash_type} ${drep_hash}; then
                        println ERROR "\n${FG_RED}ERROR${NC}: wallet not registered as a DRep!"
                        waitToProceed && continue
                      fi
                      if ! getDRepVotePower ${hash_type} ${drep_hash}; then
                        println ERROR "\n${FG_RED}ERROR${NC}: selected wallet has no vote power associated with it!"
                        waitToProceed && continue
                      fi
                    fi
                    echo
                    getAnswerAnyCust action_id "Governance Action ID [<tx_id>#<action_idx> | CIP-129] (blank to cancel)"
                    [[ -z "${action_id}" ]] && continue
                    [[ ${action_id} = gov_action* ]] && parseGovActionId ${action_id} || IFS='#' read -r action_tx_id action_idx <<< "${action_id}"
                    ! isNumber "${action_idx}" && println ERROR "\n${FG_RED}ERROR${NC}: invalid action id!" && waitToProceed && continue
                    getGovActionId "${action_tx_id}" "${action_idx}"
                    getGovAction "${action_tx_id}" "${action_idx}"
                    case $? in
                      1) println ERROR "\n${FG_RED}ERROR${NC}: governance action id not found!"; waitToProceed && continue ;;
                      2) println ERROR "\n${FG_YELLOW}WARN${NC}: invalid governance action proposal anchor url or content"
                        println DEBUG "URL : ${FG_LGRAY}${proposal_url}${NC}"
                        println DEBUG "\nContinue?"
                        select_opt "[n] No" "[y] Yes"
                        case $? in
                          0) continue ;;
                          1) : ;; # do nothing
                        esac
                        ;;
                      3) println ERROR "\n${FG_YELLOW}WARN${NC}: invalid governance action proposal anchor hash"
                        println DEBUG "Action hash : ${FG_LGRAY}${proposal_hash}${NC}"
                        println DEBUG "Real hash   : ${FG_LGRAY}${proposal_meta_hash}${NC}"
                        println DEBUG "\nContinue?"
                        select_opt "[n] No" "[y] Yes"
                        case $? in
                          0) continue ;;
                          1) : ;; # do nothing
                        esac
                        ;;
                    esac
                    isAllowedToVote ${vote_mode} ${proposal_type} ${isParameterSecurityGroup:=N}
                    case $? in
                      1) println ERROR "\n${FG_RED}ERROR${NC}: Voter of type '${vote_mode}' is not allowed to vote on an action of type '${proposal_type}'!"; waitToProceed && continue ;;
                      2) println ERROR "\n${FG_RED}ERROR${NC}: This proposal does not contain a parameter of the SecurityGroup, so voter of type '${vote_mode}' is not allowed to vote!"; waitToProceed && continue ;;
                      3) println ERROR "\n${FG_RED}ERROR${NC}: Voter of type '${vote_mode}' is not allowed to vote on an action of type '${proposal_type}' during Conway bootstrap phase (Chang-1)!"; waitToProceed && continue ;;
                    esac
                    println DEBUG "\nPrint governance action details?"
                    select_opt "[y] Yes" "[n] No"
                    case $? in
                      0) println DEBUG "\nGovernance Action Details${FG_LGRAY}"
                         jq -er <<< "${vote_action}" 2>/dev/null || echo "${vote_action}"
                         ;;
                      1) : ;; # do nothing
                    esac
                    if [[ -f "${proposal_meta_file}" ]]; then
                      println DEBUG "\nPrint anchor content?"
                      select_opt "[y] Yes" "[n] No"
                      case $? in
                        0) println DEBUG "\nGovernance Action Anchor Content${FG_LGRAY}"
                           jq -er "${proposal_meta_file}" 2>/dev/null || cat "${proposal_meta_file}"
                           ;;
                        1) : ;; # do nothing
                      esac
                    fi
                    println DEBUG "${NC}\nHow do you want to vote?"
                    select_opt "[y] Yes" "[n] No" "[a] Abstain" "[Esc] Cancel"
                    case $? in
                      0) vote_param="--yes" ;;
                      1) vote_param="--no" ;;
                      2) vote_param="--abstain" ;;
                      3) continue ;;
                    esac
                    vote_file="${TMP_DIR}/${action_tx_id}_${action_idx}_$(date '+%Y%m%d%H%M%S').vote"
                    VOTE_CMD=(
                      ${CCLI} latest governance vote create
                      ${vote_param}
                      --governance-action-tx-id "${action_tx_id}"
                      --governance-action-index "${action_idx}"
                      --out-file "${vote_file}"
                    )
                    if [[ ${vote_mode} = "spo" ]]; then
                      VOTE_CMD+=(--cold-verification-key-file "${pool_coldkey_vk_file}")
                    elif [[ ${vote_mode} = "drep" ]]; then
                      if [[ ${hash_type} = "keyHash" ]]; then
                        VOTE_CMD+=(--drep-verification-key-file "${drep_vk_file}")
                      else
                        VOTE_CMD+=(--drep-script-hash "${drep_hash}")
                      fi
                    else
                      VOTE_CMD+=(--cc-hot-verification-key-file "${cc_hot_vk_file}")
                    fi
                    println ACTION "${VOTE_CMD[*]}"
                    if ! stdout=$("${VOTE_CMD[@]}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during governance vote creation!\n${stdout}"; waitToProceed && continue
                    fi
                    getWalletBalance ${wallet_name} true true false true
                    if [[ ${base_lovelace} -le 0 ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                      println DEBUG "Funds for transaction fee needed to cast governance vote"
                      waitToProceed && continue
                    fi
                    if ! governanceVote; then
                      [[ -f ${vote_file} ]] && rm -f ${vote_file}
                      waitToProceed && continue
                    fi
                    echo
                    if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
                    echo
                    println "successfully cast vote!"
                    waitToProceed && continue
                    ;; ###################################################################
                  drep-reg)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> GOVERNANCE >> DREP REGISTRATION / UPDATE"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    if ! versionCheck "9.0" "${PROT_VERSION}"; then
                      println INFO "\n${FG_YELLOW}Not yet in Conway era, please revisit once network has crossed into Cardano governance era!${NC}"; waitToProceed && continue
                    fi
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    println DEBUG "\nSelect wallet"
                    selectWallet "balance"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    drep_wallet_name=${wallet_name}
                    getGovKeyInfo "${drep_wallet_name}"
                    if [[ -z ${drep_id} ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: Wallet missing governance keys, please first derive them!"
                      waitToProceed && continue
                    fi
                    getDRepStatus ${hash_type} ${drep_hash} && is_update=Y || is_update=N
                    if [[ ${hash_type} = "scriptHash" ]]; then
                      println DEBUG "\nSelect wallet to pay for transaction fee"
                      selectWallet "balance" ${WALLET_PAY_VK_FILENAME}
                      case $? in
                        1) waitToProceed; continue ;;
                        2) continue ;;
                      esac
                    fi
                    getWalletBalance ${wallet_name} true true false true
                    if [[ ${is_update} = Y && ${base_lovelace} -le 0 ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                      println DEBUG "Funds for transaction fee needed to update DRep registration"
                      waitToProceed && continue
                    elif [[ ${is_update} = N && ${base_lovelace} -le ${DREP_DEPOSIT} ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: insufficient funds in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                      println DEBUG "Funds for DRep deposit($(formatLovelace ${DREP_DEPOSIT}) ADA) + transaction fee needed to register as DRep"
                      waitToProceed && continue
                    fi
                    drep_cert_file="${WALLET_FOLDER}/${drep_wallet_name}/${WALLET_GOV_DREP_REGISTER_CERT_FILENAME}"
                    drep_meta_file="${WALLET_FOLDER}/${drep_wallet_name}/drep_meta.json"
                    unset drep_anchor_url drep_anchor_hash
                    println DEBUG "\nAdd DRep anchor URL?"
                    select_opt "[n] No" "[y] Yes"
                    case $? in
                      0) unset drep_meta_file ;;
                      1) getAnswerAnyCust drep_anchor_url "Enter DRep's anchor URL"
                        if [[ ! "${drep_anchor_url}" =~ https?://.* || ${#drep_anchor_url} -gt 128 ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: invalid URL format or more than 128 characters in length"
                          waitToProceed && continue
                        fi
                        if curl -sL -f -m ${CURL_TIMEOUT} -o "${drep_meta_file}" ${drep_anchor_url} && jq -er . "${drep_meta_file}" &>/dev/null; then
                          println ACTION "${CCLI} latest governance drep metadata-hash --drep-metadata-file ${drep_meta_file}"
                          if ! drep_anchor_hash=$(${CCLI} latest governance drep metadata-hash --drep-metadata-file "${drep_meta_file}" 2>&1); then
                            println ERROR "\n${FG_RED}ERROR${NC}: failure during governance drep metadata hash creation!\n${drep_anchor_hash}"; waitToProceed && continue
                          fi
                        else
                          println ERROR "\n${FG_RED}ERROR${NC}: failed to download anchor file or invalid json format"; waitToProceed && continue
                        fi
                        println DEBUG "\nDRep anchor metadata:"
                        jq -r . "${drep_meta_file}"
                        println DEBUG "\nDRep anchor metadata hash: ${FG_LGRAY}${drep_anchor_hash}${NC}"
                        ;;
                    esac
                    if [[ ${hash_type} = "scriptHash" ]]; then
                      drep_reg_param=(--drep-script-hash "${drep_hash}")
                    else
                      drep_reg_param=(--drep-verification-key-file "${drep_vk_file}")
                    fi
                    if [[ ${is_update} = N ]]; then
                      # registration
                      DREP_REG_CMD=(
                        ${CCLI} latest governance drep registration-certificate
                        "${drep_reg_param[@]}"
                        --key-reg-deposit-amt ${DREP_DEPOSIT}
                        --out-file "${drep_cert_file}"
                      )
                    else
                      # update
                      DREP_REG_CMD=(
                        ${CCLI} latest governance drep update-certificate
                        "${drep_reg_param[@]}"
                        --out-file "${drep_cert_file}"
                      )
                    fi
                    if [[ -n ${drep_anchor_url} ]]; then
                      DREP_REG_CMD+=(
                        --drep-metadata-url ${drep_anchor_url}
                        --drep-metadata-hash "${drep_anchor_hash}"
                      )
                    fi
                    println ACTION "${DREP_REG_CMD[*]}"
                    if ! stdout=$("${DREP_REG_CMD[@]}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during DRep registration certificate creation!\n${stdout}"; waitToProceed && continue
                    fi
                    if ! registerDRep; then
                      [[ -f ${drep_cert_file} ]] && rm -f ${drep_cert_file}
                      waitToProceed && continue
                    fi
                    echo
                    if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
                    echo
                    if [[ ${is_update} = N ]]; then
                      println "${FG_GREEN}${drep_wallet_name}${NC} successfully registered as DRep on chain!"
                      println "DRep deposit : ${FG_LBLUE}$(formatLovelace ${DREP_DEPOSIT})${NC} ADA (returned when retired)"
                      println DEBUG "\n${FG_YELLOW}NOTE:${NC} A DRep registration does not automatically delegate own wallet stake power to self!"
                    else
                      println "${FG_GREEN}${drep_wallet_name}${NC} DRep details updated!"
                    fi
                    waitToProceed && continue
                    ;; ###################################################################
                  drep-ret)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> GOVERNANCE >> DREP RETIRE"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    if ! versionCheck "9.0" "${PROT_VERSION}"; then
                      println INFO "\n${FG_YELLOW}Not yet in Conway era, please revisit once network has crossed into Cardano governance era!${NC}"; waitToProceed && continue
                    fi
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    println DEBUG "\nSelect wallet (derive governance keys if missing)"
                    selectWallet "balance"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    drep_wallet_name=${wallet_name}
                    getGovKeyInfo ${drep_wallet_name}
                    if [[ -z ${drep_id} ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: Wallet missing governance keys!"
                      waitToProceed && continue
                    fi
                    if ! getDRepStatus ${hash_type} ${drep_hash}; then
                      println ERROR "\n${FG_RED}ERROR${NC}: Wallet not registered as a DRep, unable to retire!"
                      waitToProceed && continue
                    fi
                    drep_cert_file="${WALLET_FOLDER}/${drep_wallet_name}/${WALLET_GOV_DREP_RETIRE_CERT_FILENAME}"
                    if [[ ${hash_type} = "scriptHash" ]]; then
                      drep_ret_param=(--drep-script-hash "${drep_hash}")
                    else
                      drep_ret_param=(--drep-verification-key-file "${drep_vk_file}")
                    fi
                    DREP_RET_CMD=(
                      ${CCLI} latest governance drep retirement-certificate
                      "${drep_ret_param[@]}"
                      --deposit-amt ${drep_deposit_amt}
                      --out-file "${drep_cert_file}"
                    )
                    println ACTION "${DREP_RET_CMD[*]}"
                    if ! stdout=$("${DREP_RET_CMD[@]}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during DRep retirement certificate creation!\n${stdout}"; waitToProceed && continue
                    fi
                    if [[ ${hash_type} = "scriptHash" ]]; then
                      println DEBUG "\nSelect wallet to pay for the transaction fee and that gets the returned DRep deposit"
                      selectWallet "balance" ${WALLET_PAY_VK_FILENAME}
                      case $? in
                        1) waitToProceed; continue ;;
                        2) continue ;;
                      esac
                    fi
                    getWalletBalance ${wallet_name} true true false true
                    if [[ ${base_lovelace} -le 0 ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: no funds available in base address for wallet ${FG_GREEN}${wallet_name}${NC}"
                      println DEBUG "Funds for transaction fee needed to retire as a DRep"
                      waitToProceed && continue
                    fi
                    if ! retireDRep; then
                      [[ -f ${drep_cert_file} ]] && rm -f ${drep_cert_file}
                      waitToProceed && continue
                    fi
                    echo
                    if ! verifyTx ${base_addr}; then waitToProceed && continue; fi
                    echo
                    println "${FG_GREEN}${drep_wallet_name}${NC} successfully retired as DRep!"
                    println "DRep deposit : ${FG_LBLUE}$(formatLovelace ${drep_deposit_amt})${NC} ADA returned"
                    waitToProceed && continue
                    ;; ###################################################################
                  create-ms-drep)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> GOVERNANCE >> MULTISIG DREP"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    createNewWallet || continue
                    ms_wallet_name="${wallet_name}"
                    # Wallet key filenames
                    ms_drep_script_file="${WALLET_FOLDER}/${ms_wallet_name}/${WALLET_GOV_DREP_SCRIPT_FILENAME}"
                    if [[ $(find "${WALLET_FOLDER}/${ms_wallet_name}" -type f -print0 | wc -c) -gt 0 ]]; then
                      println "${FG_RED}WARN${NC}: A wallet ${FG_GREEN}${ms_wallet_name}${NC} already exists"
                      println "      Choose another name or delete the existing one"
                      waitToProceed && continue
                    fi
                    # drep key hashes as keys to associative array to act as a set
                    declare -gA key_hashes=()
                    println OFF "Select wallet(s) / DRep IDs to include in MultiSig DRep"
                    println OFF "${FG_YELLOW}!${NC} Please use 1854H (MultiSig) derived keys according to CIP-1854!"
                    println OFF "${FG_YELLOW}!${NC} Only wallets with these keys will be listed, use 'Derive Keys' option to generate them."
                    echo
                    selected_wallets=()
                    while true; do
                      println DEBUG "Select wallet or manually enter DRep ID?"
                      select_opt "[w] Wallet" "[i] DRep (ID or hash)" "[d] I'm done" "[Esc] Cancel"
                      case $? in
                        0) selectWallet "none" "${selected_wallets[@]}" "${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"
                          case $? in
                            1) waitToProceed; continue ;;
                            2) continue ;;
                          esac
                          getWalletType ${wallet_name}
                          if [[ $? -eq 0 ]]; then
                            println ERROR "\n${FG_YELLOW}HW wallets currently not supported in a MultiSig DRep, please select only normal mnemonic or cli wallets${NC}" && waitToProceed && continue
                          fi
                          getGovKeyInfo ${wallet_name}
                          [[ -z ${ms_drep_id} || ${ms_drep_id} != drep* ]] && println ERROR "\n${FG_RED}ERROR${NC}: invalid wallet, MultiSig DRep keys not found!" && waitToProceed && continue
                          key_hashes["${ms_drep_hash}"]=1
                          selected_wallets+=("${wallet_name}")
                          ;;
                        1) getAnswerAnyCust drep_id "MultiSig DRep ID [CIP-105 or CIP-129] (blank to cancel)"
                          [[ -z "${drep_id}" ]] && continue
                          parseDRepId "${drep_id}"
                          [[ -z ${drep_id} ]] && println ERROR "\n${FG_RED}ERROR${NC}: invalid DRep ID entered!" && waitToProceed && continue
                          key_hashes[${drep_hash}]=1
                          ;;
                        2) break ;;
                        3) safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; continue 2 ;;
                      esac
                      println DEBUG "\nMultiSig size: ${#key_hashes[@]} - Add more wallets / DRep IDs to MultiSig?"
                      select_opt "[n] No" "[y] Yes" "[Esc] Cancel"
                      case $? in
                        0) break ;;
                        1) : ;;
                        2) safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; continue 2 ;;
                      esac
                    done
                    if [[ ${#key_hashes[@]} -eq 0 ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: no signers added, please add at least one"; safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; waitToProceed; continue
                    fi
                    println DEBUG "\n${#key_hashes[@]} wallets / DRep IDs added to MultiSig, how many are required to witness the transaction?"
                    getAnswerAnyCust required_sig_cnt "Number of Required signatures"
                    if ! isNumber ${required_sig_cnt} || [[ ${required_sig_cnt} -lt 1 || ${required_sig_cnt} -gt ${#key_hashes[@]} ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: invalid signature count entered, must be above 1 and max ${#key_hashes[@]}"; safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; waitToProceed; continue
                    fi
                    # build MultiSig script
                    drep_script=$(jq -n --argjson req_sig "${required_sig_cnt}" '{type:"atLeast",required:$req_sig,scripts:[]}')
                    for sig in "${!key_hashes[@]}"; do
                      drep_script=$(jq --arg sig "${sig}" '.scripts += [{type:"sig",keyHash:$sig}]' <<< "${drep_script}")
                    done
                    if ! stdout=$(jq -e . <<< "${drep_script}" > "${ms_drep_script_file}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during DRep script file creation!\n${stdout}"; safeDel "${WALLET_FOLDER}/${ms_wallet_name}"; waitToProceed && continue
                    fi
                    chmod 600 "${WALLET_FOLDER}/${ms_wallet_name}/"*
                    getGovKeyInfo ${ms_wallet_name}
                    getDRepIds scriptHash ${drep_hash}
                    echo
                    println "New MultiSig DRep : ${FG_GREEN}${ms_wallet_name}${NC}"
                    println "DRep ID           : CIP-105 => ${FG_LGRAY}${drep_id}${NC}"
                    println "                  : CIP-129 => ${FG_LGRAY}${drep_id_cip129}${NC}"
                    println "DRep Script Hash  : ${FG_LGRAY}${drep_hash}${NC}"
                    println DEBUG "\nNote that this is not a normal wallet and can only be used to vote as a DRep coalition."
                    waitToProceed && continue
                    ;; ###################################################################
                  derive-gov-keys)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> GOVERNANCE >> DERIVE"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    println DEBUG "Select wallet to derive governance keys for (only wallets with missing keys shown)"
                    selectWallet "non-gov"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    getWalletType ${wallet_name}
                    case $? in
                      0) # Hardware wallet
                        if ! cmdAvailable "cardano-hw-cli" &>/dev/null; then
                          println ERROR "${FG_RED}ERROR${NC}: cardano-hw-cli not found in path or executable permission not set."
                          println ERROR "Please run '${FG_YELLOW}guild-deploy.sh -s w${NC}' to add hardware wallet support and install Vaccumlabs cardano-hw-cli, '${FG_YELLOW}guild-deploy.sh -h${NC}' shows all available options"
                          waitToProceed && continue
                        fi
                        if ! HWCLIversionCheck; then waitToProceed && continue; fi
                        drep_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_DREP_VK_FILENAME}"
                        drep_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_HW_DREP_SK_FILENAME}"
                        cc_cold_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_COLD_VK_FILENAME}"
                        cc_cold_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_HW_CC_COLD_SK_FILENAME}"
                        cc_hot_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_HOT_VK_FILENAME}"
                        cc_hot_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_HW_CC_HOT_SK_FILENAME}"
                        ms_drep_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_HW_DREP_SK_FILENAME}"
                        ms_drep_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"
                        if [[ -f ${drep_sk_file} || -f ${cc_cold_sk_file} || -f ${cc_hot_sk_file} || -f ${ms_drep_sk_file} ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: some governance signing keys already exist!\n${stdout}"; waitToProceed && continue
                        fi
                        derivation_path_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DERIVATION_PATH_FILENAME}"
                        if ! getSavedDerivationPath "${derivation_path_file}"; then
                          getCustomDerivationPath || continue
                          echo "1852H/1815H/${acct_idx}H/x/${key_idx}" > "${derivation_path_file}"
                        fi
                        if ! unlockHWDevice "extract ${FG_LGRAY}governance keys${NC}"; then waitToProceed && continue; fi
                        HW_CLI_CMD=(
                          cardano-hw-cli address key-gen
                          --path 1852H/1815H/${acct_idx}H/3/${key_idx}
                          --path 1852H/1815H/${acct_idx}H/4/${key_idx}
                          --path 1852H/1815H/${acct_idx}H/5/${key_idx}
                          --verification-key-file "${drep_vk_file}"
                          --verification-key-file "${cc_cold_vk_file}"
                          --verification-key-file "${cc_hot_vk_file}"
                          --hw-signing-file "${drep_sk_file}"
                          --hw-signing-file "${cc_cold_sk_file}"
                          --hw-signing-file "${cc_hot_sk_file}"
                        )
                        println ACTION "${HW_CLI_CMD[*]}"
                        if ! stdout=$("${HW_CLI_CMD[@]}" 2>&1); then
                          println ERROR "\n${FG_RED}ERROR${NC}: failure during governance key extraction!\n${stdout}"; waitToProceed && continue
                        fi
                        cp "${drep_sk_file}" "${ms_drep_sk_file}"
                        cp "${drep_vk_file}" "${ms_drep_vk_file}"
                        jq '.description = "Delegate Representative Hardware Verification Key"' "${drep_vk_file}" > "${TMP_DIR}/$(basename "${drep_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${drep_vk_file}").tmp" "${drep_vk_file}"
                        jq '.description = "Constitutional Committee Cold Hardware Verification Key"' "${cc_cold_vk_file}" > "${TMP_DIR}/$(basename "${cc_cold_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${cc_cold_vk_file}").tmp" "${cc_cold_vk_file}"
                        jq '.description = "Constitutional Committee Hot Hardware Verification Key"' "${cc_hot_sk_file}" > "${TMP_DIR}/$(basename "${cc_hot_sk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${cc_hot_sk_file}").tmp" "${cc_hot_sk_file}"
                        jq '.description = "MultiSig Delegate Representative Hardware Verification Key"' "${ms_drep_vk_file}" > "${TMP_DIR}/$(basename "${ms_drep_vk_file}").tmp" && mv -f "${TMP_DIR}/$(basename "${ms_drep_vk_file}").tmp" "${ms_drep_vk_file}"
                        ;;
                      5) println ERROR "\n${FG_RED}ERROR${NC}: MultiSig wallets not supported as DRep wallet, only vote delegation supported!\n${stdout}"; waitToProceed && continue ;;
                      *)
                        drep_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_DREP_VK_FILENAME}"
                        drep_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_DREP_SK_FILENAME}"
                        cc_cold_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_COLD_VK_FILENAME}"
                        cc_cold_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_COLD_SK_FILENAME}"
                        cc_hot_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_HOT_VK_FILENAME}"
                        cc_hot_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_HOT_SK_FILENAME}"
                        ms_drep_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"
                        ms_drep_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_SK_FILENAME}"
                        if [[ -f ${drep_sk_file} || -f ${cc_cold_sk_file} || -f ${cc_hot_sk_file} || -f ${ms_drep_sk_file} ]]; then
                          println ERROR "\n${FG_RED}ERROR${NC}: some governance signing keys already exist!\n${stdout}"; waitToProceed && continue
                        fi
                        println DEBUG "Is selected wallet a CLI generated wallet or derived from mnemonic?"
                        select_opt "[c] CLI" "[m] Mnemonic"
                        case $? in
                          0) println ACTION "${CCLI} latest governance drep key-gen --verification-key-file ${drep_vk_file} --signing-key-file ${drep_sk_file}"
                            if ! stdout=$(${CCLI} latest governance drep key-gen --verification-key-file "${drep_vk_file}" --signing-key-file "${drep_sk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during governance drep key creation!\n${stdout}"; waitToProceed && continue
                            fi
                            println ACTION "${CCLI} latest governance committee key-gen-cold --cold-verification-key-file ${cc_cold_vk_file} --cold-signing-key-file ${cc_cold_sk_file}"
                            if ! stdout=$(${CCLI} latest governance committee key-gen-cold --cold-verification-key-file "${cc_cold_vk_file}" --cold-signing-key-file "${cc_cold_sk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during governance committee cold key creation!\n${stdout}"; waitToProceed && continue
                            fi
                            println ACTION "${CCLI} latest governance committee key-gen-hot --verification-key-file ${cc_hot_vk_file} --signing-key-file ${cc_hot_sk_file}"
                            if ! stdout=$(${CCLI} latest governance committee key-gen-hot --verification-key-file "${cc_hot_vk_file}" --signing-key-file "${cc_hot_sk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during governance committee hot key creation!\n${stdout}"; waitToProceed && continue
                            fi
                            println ACTION "${CCLI} latest governance drep key-gen --verification-key-file ${ms_drep_vk_file} --signing-key-file ${ms_drep_sk_file}"
                            if ! stdout=$(${CCLI} latest governance drep key-gen --verification-key-file "${ms_drep_vk_file}" --signing-key-file "${ms_drep_sk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig governance drep key creation!\n${stdout}"; waitToProceed && continue
                            fi
                            ;;
                          1) if ! cmdAvailable "bech32" &>/dev/null || \
                              ! cmdAvailable "cardano-address" &>/dev/null; then
                              println ERROR "${FG_RED}ERROR${NC}: bech32 and/or cardano-address not found in '\$PATH'"
                              println ERROR "Please run updated guild-deploy.sh and re-build/re-download cardano-node"
                              waitToProceed && continue
                            fi
                            getAnswerAnyCust mnemonic false "24 or 15 word mnemonic(space separated)"
                            echo
                            IFS=" " read -r -a words <<< "${mnemonic}"
                            if [[ ${#words[@]} -ne 24 ]] && [[ ${#words[@]} -ne 15 ]]; then
                              println ERROR "${FG_RED}ERROR${NC}: 24 or 15 words expected, found ${FG_RED}${#words[@]}${NC}"
                              unset mnemonic; unset words
                              waitToProceed && continue
                            fi
                            derivation_path_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DERIVATION_PATH_FILENAME}"
                            if ! getSavedDerivationPath "${derivation_path_file}"; then
                              getCustomDerivationPath || continue
                              echo "1852H/1815H/${acct_idx}H/x/${key_idx}" > "${derivation_path_file}"
                            fi
                            caddr_v="$(cardano-address -v | awk '{print $1}')"
                            [[ "${caddr_v}" == 3* ]] && caddr_arg="--with-chain-code" || caddr_arg=""
                            if ! root_prv=$(cardano-address key from-recovery-phrase Shelley <<< ${mnemonic}); then
                              unset mnemonic; unset words
                              waitToProceed && continue
                            fi
                            unset mnemonic; unset words
                            drep_xprv=$(cardano-address key child 1852H/1815H/${acct_idx}H/3/${key_idx} <<< ${root_prv})
                            cc_cold_xprv=$(cardano-address key child 1852H/1815H/${acct_idx}H/4/${key_idx} <<< ${root_prv})
                            cc_hot_xprv=$(cardano-address key child 1852H/1815H/${acct_idx}H/5/${key_idx} <<< ${root_prv})
                            ms_drep_xprv=$(cardano-address key child 1854H/1815H/${acct_idx}H/3/${key_idx} <<< ${root_prv})
                            drep_xpub=$(cardano-address key public ${caddr_arg} <<< ${drep_xprv})
                            cc_cold_xpub=$(cardano-address key public ${caddr_arg} <<< ${cc_cold_xprv})
                            cc_hot_xpub=$(cardano-address key public ${caddr_arg} <<< ${cc_hot_xprv})
                            ms_drep_xpub=$(cardano-address key public ${caddr_arg} <<< ${ms_drep_xprv})
                            drep_es_key=$(bech32 <<< ${drep_xprv} | cut -b -128)$(bech32 <<< ${drep_xpub})
                            cc_cold_es_key=$(bech32 <<< ${cc_cold_xprv} | cut -b -128)$(bech32 <<< ${cc_cold_xpub})
                            cc_hot_es_key=$(bech32 <<< ${cc_hot_xprv} | cut -b -128)$(bech32 <<< ${cc_hot_xpub})
                            ms_drep_es_key=$(bech32 <<< ${ms_drep_xprv} | cut -b -128)$(bech32 <<< ${ms_drep_xpub})
                            cat <<-EOF > "${drep_sk_file}"
															{
																	"type": "DRepExtendedSigningKey_ed25519_bip32",
																	"description": "Delegate Representative Signing Key",
																	"cborHex": "5880${drep_es_key}"
															}
															EOF
                            cat <<-EOF > "${cc_cold_sk_file}"
															{
																	"type": "ConstitutionalCommitteeColdExtendedSigningKey_ed25519_bip32",
																	"description": "Constitutional Committee Cold Signing Key",
																	"cborHex": "5880${cc_cold_es_key}"
															}
															EOF
                            cat <<-EOF > "${cc_hot_sk_file}"
															{
																	"type": "ConstitutionalCommitteeHotExtendedSigningKey_ed25519_bip32",
																	"description": "Constitutional Committee Hot Signing Key",
																	"cborHex": "5880${cc_hot_es_key}"
															}
															EOF
                            cat <<-EOF > "${ms_drep_sk_file}"
															{
																	"type": "DRepExtendedSigningKey_ed25519_bip32",
																	"description": "MultiSig Delegate Representative Signing Key",
																	"cborHex": "5880${drep_es_key}"
															}
															EOF
                            println ACTION "${CCLI} latest key verification-key --signing-key-file ${drep_sk_file} --verification-key-file ${TMP_DIR}/drep.evkey"
                            if ! stdout=$(${CCLI} latest key verification-key --signing-key-file "${drep_sk_file}" --verification-key-file "${TMP_DIR}/drep.evkey" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during drep extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            println ACTION "${CCLI} latest key verification-key --signing-key-file ${cc_cold_sk_file} --verification-key-file ${TMP_DIR}/cc-cold.evkey"
                            if ! stdout=$(${CCLI} latest key verification-key --signing-key-file "${cc_cold_sk_file}" --verification-key-file "${TMP_DIR}/cc-cold.evkey" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during cc-cold extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            println ACTION "${CCLI} latest key verification-key --signing-key-file ${cc_hot_sk_file} --verification-key-file ${TMP_DIR}/cc-hot.evkey"
                            if ! stdout=$(${CCLI} latest key verification-key --signing-key-file "${cc_hot_sk_file}" --verification-key-file "${TMP_DIR}/cc-hot.evkey" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during cc-hot extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            println ACTION "${CCLI} latest key verification-key --signing-key-file ${ms_drep_sk_file} --verification-key-file ${TMP_DIR}/ms_drep.evkey"
                            if ! stdout=$(${CCLI} latest key verification-key --signing-key-file "${ms_drep_sk_file}" --verification-key-file "${TMP_DIR}/ms_drep.evkey" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig drep extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            println ACTION "${CCLI} latest key non-extended-key --extended-verification-key-file ${TMP_DIR}/drep.evkey --verification-key-file ${drep_vk_file}"
                            if ! stdout=$(${CCLI} latest key non-extended-key --extended-verification-key-file "${TMP_DIR}/drep.evkey" --verification-key-file "${drep_vk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during drep verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            println ACTION "${CCLI} latest key non-extended-key --extended-verification-key-file ${TMP_DIR}/cc-cold.evkey --verification-key-file ${cc_cold_vk_file}"
                            if ! stdout=$(${CCLI} latest key non-extended-key --extended-verification-key-file "${TMP_DIR}/cc-cold.evkey" --verification-key-file "${cc_cold_vk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during cc-cold verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            println ACTION "${CCLI} latest key non-extended-key --extended-verification-key-file ${TMP_DIR}/cc-hot.evkey --verification-key-file ${cc_hot_vk_file}"
                            if ! stdout=$(${CCLI} latest key non-extended-key --extended-verification-key-file "${TMP_DIR}/cc-hot.evkey" --verification-key-file "${cc_hot_vk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during cc-hot verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            println ACTION "${CCLI} latest key non-extended-key --extended-verification-key-file ${TMP_DIR}/ms_drep.evkey --verification-key-file ${ms_drep_vk_file}"
                            if ! stdout=$(${CCLI} latest key non-extended-key --extended-verification-key-file "${TMP_DIR}/ms_drep.evkey" --verification-key-file "${ms_drep_vk_file}" 2>&1); then
                              println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig drep verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
                            fi
                            ;;
                        esac
                        ;;
                    esac
                    chmod 600 "${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}"*
                    echo
                    getGovKeyInfo ${wallet_name}
                    println "Wallet            : ${FG_GREEN}${wallet_name}${NC}"
                    println "DRep ID           : CIP-105 => ${FG_LGRAY}${drep_id}${NC}"
                    println "                  : CIP-129 => ${FG_LGRAY}${drep_id_cip129}${NC}"
                    println "Committee Cold ID : CIP-105 => ${FG_LGRAY}${cc_cold_id}${NC}"
                    println "                  : CIP-129 => ${FG_LGRAY}${cc_cold_id_cip129}${NC}"
                    println "Committee Hot ID  : CIP-105 => ${FG_LGRAY}${cc_hot_id}${NC}"
                    println "                  : CIP-129 => ${FG_LGRAY}${cc_hot_id_cip129}${NC}"
                    waitToProceed && continue
                    ;; ###################################################################
                esac # vote sub OPERATION
              done # vote loop
              ;; ###################################################################
            catalyst)
              while true; do # Catalyst loop
                clear
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println " >> VOTE >> CATALYST"
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println OFF " Catalyst\n"\
                  " ) Register    - register wallet for Catalyst"\
                  " ) Display QR  - show QR code from previous Catalyst registration"\
                  " ) Verify      - check registration status for own or external vote key"\
                  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println DEBUG " Select Catalyst Operation\n"
                select_opt "[r] Registration" "[q] Display QR" "[v] Verify" "[b] Back" "[h] Home"
                case $? in
                  0) SUBCOMMAND="catalyst_reg" ;;
                  1) SUBCOMMAND="catalyst_qr" ;;
                  2) SUBCOMMAND="catalyst_verify" ;;
                  3) break ;;
                  4) break 2 ;;
                esac
                case $SUBCOMMAND in
                  catalyst_reg)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> CATALYST >> REGISTER"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "\n${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    println DEBUG "Select wallet to register for Catalyst"
                    unset isHWwallet
                    selectWallet "balance"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    getWalletType ${wallet_name}
                    case $? in
                      0) isHWwallet=true ;;
                      2) [[ ${op_mode} = "online" ]] && println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                      3) [[ ${op_mode} = "online" ]] && println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                    esac
                    if ! isWalletRegistered ${wallet_name}; then
                      println ERROR "\n${FG_RED}ERROR${NC}: wallet ${FG_GREEN}${wallet_name}${NC} not a registered wallet on chain, please register/delegate it before Catalyst registration."
                      waitToProceed && continue
                    fi
                    getWalletBalance ${wallet_name} true true true true
                    if [[ ${base_lovelace} -gt 0 ]]; then
                      addr="${base_addr}"
                      lovelace=${base_lovelace}
                      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                        println DEBUG "\n$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                      fi
                    else
                      println ERROR "\n${FG_RED}ERROR${NC}: no base funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                      waitToProceed && continue
                    fi
                    getBaseAddress ${wallet_name}
                    download_catalyst_toolbox || continue
                    metafile="${TMP_DIR}/catalyst_reg_metadata_$(printf '%(%s)T\n' -1).cbor"
                    metatype="cbor"
                    if ! cmdAvailable "cardano-signer" &>/dev/null; then
                      println ERROR "\n${FG_RED}ERROR${NC}: prerequisite tool cardano-signer missing or not executable, please install using ${FG_LGRAY}guild-deploy.sh${NC}"
                      waitToProceed && continue
                    fi
                    catalyst_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_CATALYST_SK_FILENAME}"
                    catalyst_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_CATALYST_VK_FILENAME}"
                    catalyst_qr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_CATALYST_QR_FILENAME}"
                    if [[ ! -f "${catalyst_vk_file}" && ! -f "${catalyst_sk_file}" ]]; then
                      println ACTION "cardano-signer keygen --cip36 --out-skey ${catalyst_sk_file} --out-vkey ${catalyst_vk_file}"
                      if ! stdout=$(cardano-signer keygen --cip36 --out-skey "${catalyst_sk_file}" --out-vkey "${catalyst_vk_file}" 2>&1); then
                        println ERROR "\n${FG_RED}ERROR${NC}: failure during catalyst key creation!\n${stdout}"; waitToProceed && continue
                      fi
                    fi
                    generateCatalystBech32 ${wallet_name} || continue
                    if [[ -f "${catalyst_qr_file}" ]]; then
                      println "A previous registration found, continue with registration and overwrite?"
                      select_opt "[y] Yes" "[n] No"
                      case $? in
                        0) : ;; # do nothing
                        1) waitToProceed && continue ;;
                      esac
                    fi
                    if [[ -z ${isHWwallet} ]]; then
                      catalyst_meta_cmd=(
                        cardano-signer sign --cip36
                        ${NETWORK_IDENTIFIER}
                        --payment-address "${base_addr}"
                        --vote-public-key "${catalyst_vk_file}"
                        --secret-key "${stake_sk_file}"
                        --out-cbor "${metafile}"
                      )
                    else
                      # HW Wallet
                      if ! cmdAvailable "cardano-hw-cli" &>/dev/null; then
                        println ERROR "\n${FG_RED}ERROR${NC}: prerequisite tool cardano-hw-cli missing or not executable, please install using ${FG_LGRAY}guild-deploy.sh${NC}"
                        waitToProceed && continue
                      fi
                      if ! HWCLIversionCheck; then waitToProceed && continue; fi
                      if ! unlockHWDevice "create Catalyst vote metadata"; then waitToProceed && continue; fi
                      current_slot=$(getSlotTipRef)
                      catalyst_meta_cmd=(
                        cardano-hw-cli vote registration-metadata
                        ${NETWORK_IDENTIFIER}
                        --vote-public-key-file "${catalyst_vk_file}"
                        --payment-address "${base_addr}"
                        --stake-signing-key-hwsfile "${stake_sk_file}"
                        --nonce ${current_slot}
                        --payment-address-signing-key-hwsfile "${payment_sk_file}"
                        --metadata-cbor-out-file "${metafile}"
                      )
                    fi
                    println ACTION "${catalyst_meta_cmd[*]}"
                    if ! stdout=$("${catalyst_meta_cmd[@]}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during catalyst metadata creation!\n${stdout}"; waitToProceed && continue
                    fi
                    if ! sendMetadata; then
                      waitToProceed && continue
                    fi
                    echo
                    if ! verifyTx ${addr}; then waitToProceed && continue; fi
                    echo
                    println "Catalyst registration metadata successfully posted on-chain"
                    while true; do
                      echo
                      getAnswerAnyCust pin_enter "Enter a 4-Digit PIN"
                      if ! isNumber ${pin_enter} || [[ ${#pin_enter} -ne 4 ]]; then
                        println ERROR "\n${FG_RED}ERROR${NC}: invalid PIN entered! Please try again"
                        continue
                      fi
                      break
                    done
                    # save QR
                    catalyst_qr_cmd=(
                      catalyst-toolbox qr-code encode
                      --pin ${pin_enter}
                      --input "${catalyst_sk_file_bech32}"
                      --output "${catalyst_qr_file}"
                      --opts img
                    )
                    println ACTION "${catalyst_qr_cmd[*]}"
                    if ! stdout=$("${catalyst_qr_cmd[@]}" 2>&1); then
                      println ERROR "\n${FG_RED}ERROR${NC}: failure during catalyst QR code creation!\n${stdout}"; waitToProceed && continue
                    fi
                    # print QR
                    println DEBUG "QR Code image generated: ${catalyst_qr_file}"
                    catalyst_qr_cmd=(
                      catalyst-toolbox qr-code encode
                      --pin ${pin_enter}
                      --input "${catalyst_sk_file_bech32}"
                      --opts img
                    )
                    println ACTION "${catalyst_qr_cmd[*]}"
                    "${catalyst_qr_cmd[@]}"
                    println DEBUG "\nScan QR code using Catalyst app on mobile device"
                    println DEBUG "iOS:     https://apps.apple.com/in/app/catalyst-voting/id1517473397"
                    println DEBUG "Android: https://play.google.com/store/apps/details?id=io.iohk.vitvoting"
                    println DEBUG "\nCardano Catalyst Telegram Announcements Channel: https://t.me/cardanocatalyst"
                    waitToProceed && continue
                    ;; ###################################################################
                  catalyst_qr)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> VOTE >> CATALYST >> QR CODE"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    echo
                    println DEBUG "Select a Catalyst registered wallet"
                    selectWallet "none" "${WALLET_CATALYST_SK_FILENAME}"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    download_catalyst_toolbox || continue
                    while true; do
                      echo
                      getAnswerAnyCust pin_enter "Enter 4-Digit PIN"
                      if ! isNumber ${pin_enter} || [[ ${#pin_enter} -ne 4 ]]; then
                        println ERROR "\n${FG_RED}ERROR${NC}: invalid PIN entered! Please try again"
                        continue
                      fi
                      break
                    done
                    catalyst_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_CATALYST_SK_FILENAME}"
                    catalyst_qr_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_CATALYST_QR_FILENAME}"
                    generateCatalystBech32 ${wallet_name} || continue
                    unset save_catalyst_qr
                    if [[ -f "${catalyst_qr_file}" ]]; then
                      catalyst_qr_cmd=(
                        catalyst-toolbox qr-code verify
                        --stop-at-fail
                        --pin ${pin_enter}
                        --file "${catalyst_qr_file}"
                        --opts img
                      )
                      println ACTION "${catalyst_qr_cmd[*]}"
                      if ! "${catalyst_qr_cmd[@]}" &>/dev/null; then
                        println "PIN code invalid, overwrite existing QR code with updated PIN code?"
                        select_opt "[y] Yes" "[n] No (return)" "[c] Continue (display QR code)"
                        case $? in
                          0) save_catalyst_qr=true ;;
                          1) continue ;;
                          2) : ;;
                        esac
                      fi
                    else
                      save_catalyst_qr=true
                    fi
                    if [[ ${save_catalyst_qr} = true ]]; then
                      catalyst_qr_cmd=(
                        catalyst-toolbox qr-code encode
                        --pin ${pin_enter}
                        --input "${catalyst_sk_file_bech32}"
                        --output "${catalyst_qr_file}"
                        --opts img
                      )
                      println ACTION "${catalyst_qr_cmd[*]}"
                      if ! stdout=$("${catalyst_qr_cmd[@]}" 2>&1); then
                        println ERROR "\n${FG_RED}ERROR${NC}: failure during catalyst QR code creation!\n${stdout}"; waitToProceed && continue
                      fi
                    fi
                    catalyst_qr_cmd=(
                      catalyst-toolbox qr-code encode
                      --pin ${pin_enter}
                      --input "${catalyst_sk_file_bech32}"
                      --opts img
                    )
                    println ACTION "${catalyst_qr_cmd[*]}"
                    "${catalyst_qr_cmd[@]}"
                    println DEBUG "\nScan QR code using Catalyst app on mobile device"
                    println DEBUG "iOS:     https://apps.apple.com/in/app/catalyst-voting/id1517473397"
                    println DEBUG "Android: https://play.google.com/store/apps/details?id=io.iohk.vitvoting"
                    println DEBUG "\nCardano Catalyst Telegram Announcements Channel: https://t.me/cardanocatalyst"
                    waitToProceed && continue
                    ;; ###################################################################
                  catalyst_verify)
                    cntools_compatibility_dispatch_action vote.catalyst.verify
                    case $? in
                      0) continue ;;
                      20|21) break 2 ;;
                      22) myExit ;;
                      *) waitToProceed; continue ;;
                    esac
                    ;; ###################################################################
                esac # vote sub OPERATION
              done # vote loop
              ;; ###################################################################
          esac # vote sub OPERATION
        done # vote loop
        ;; ###################################################################
      blocks)
        clear
        println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        println " >> BLOCKS"
        println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        if ! command -v sqlite3 >/dev/null; then
          println ERROR "${FG_RED}ERROR${NC}: sqlite3 not found!"
          waitToProceed && continue
        fi
        current_epoch=$(getEpoch)
        println DEBUG "Current epoch: ${FG_LBLUE}${current_epoch}${NC}\n"
        println DEBUG "Show a block summary for all epochs or a detailed view for a specific epoch?"
        select_opt "[s] Summary" "[e] Epoch" "[Esc] Cancel"
        case $? in
          0) cntools_compatibility_dispatch_action blocks.summary
             action_status=$?
             case "${action_status}" in
               0) waitToProceed; continue ;;
               20|21) continue ;;
               22) myExit 0 "CNTools closed!" ;;
               *) waitToProceed; continue ;;
             esac
             ;;
          1) cntools_compatibility_dispatch_action blocks.epoch
             action_status=$?
             case "${action_status}" in
               0|20|21) continue ;;
               22) myExit 0 "CNTools closed!" ;;
               *) waitToProceed; continue ;;
             esac
             ;;
          2) continue ;;
        esac
        waitToProceed && continue
        ;; ###################################################################
      backup)
        clear
        println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        println " >> BACKUP & RESTORE"
        println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        echo
        println DEBUG "Create or restore a backup of CNTools wallets & pools"
        echo
        println DEBUG "Backup or Restore?"
        select_opt "[b] Backup" "[r] Restore" "[Esc] Cancel"
        case $? in
          0) echo
            dirDialog "Enter backup destination directory (created if non existent)" && echo
            [[ "${dir}" != */ ]] && backup_path="${dir}/" || backup_path="${dir}"
            if [[ ! "${backup_path}" =~ ^/[-0-9A-Za-z_]+ ]]; then
              println ERROR "${FG_RED}ERROR${NC}: invalid path, please specify the full path to backup directory (space not allowed)"
              waitToProceed && continue
            fi
            if ! mkdir -p "${backup_path}"; then println ERROR "${FG_RED}ERROR${NC}: failed to create backup directory:\n${backup_path}" && waitToProceed && continue; fi
            missing_keys="false"
            excluded_files=()
            [[ -d "${ASSET_FOLDER}" ]] && asset_out=" and asset ${ASSET_POLICY_SK_FILENAME}" || asset_out=""
            println DEBUG "Include private keys in backup?"
            println DEBUG "- No  > create a backup excluding wallets ${WALLET_PAY_SK_FILENAME}/${WALLET_STAKE_SK_FILENAME}, pools ${POOL_COLDKEY_SK_FILENAME}${asset_out}"
            println DEBUG "- Yes > create a backup including all available files"
            select_opt "[n] No" "[y] Yes"
            case $? in
              0) excluded_files=(
                   --exclude=${WALLET_PAY_SK_FILENAME}
                   --exclude=${WALLET_PAY_SK_FILENAME}.gpg
                   --exclude=${WALLET_STAKE_SK_FILENAME}
                   --exclude=${WALLET_STAKE_SK_FILENAME}.gpg
                   --exclude=${POOL_COLDKEY_SK_FILENAME}
                   --exclude=${POOL_COLDKEY_SK_FILENAME}.gpg
                   --exclude=${ASSET_POLICY_SK_FILENAME}
                   --exclude=${ASSET_POLICY_SK_FILENAME}.gpg
                 )
                 backup_file="${backup_path}online_cntools_backup-$(date '+%Y%m%d%H%M%S').${CNODE_NAME}.tar"
                 ;;
              1) backup_file="${backup_path}offline_cntools_backup-$(date '+%Y%m%d%H%M%S').${CNODE_NAME}.tar" ;;
            esac
            echo
            backup_source=(
              "${WALLET_FOLDER}"
              "${POOL_FOLDER}"
              "${ASSET_FOLDER}"
            )
            backup_list=()
            backup_cnt=0
            println DEBUG "Backup job include:\n"
            for item in "${backup_source[@]}"; do
              [[ ! -d "${item}" ]] && continue
              println DEBUG "$(basename "${item}")"
              while IFS= read -r -d '' dir; do
                backup_list+=( "${dir}" )
                println DEBUG "  ${FG_LGRAY}$(basename "${dir}")${NC}"
                ((backup_cnt++))
              done < <(find "${item}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
            done
            [[ ${backup_cnt} -eq 0 ]] && println "\nNo folders found to include in backup :(" && waitToProceed && continue
            echo
            if [[ ${#excluded_files[@]} -gt 0 ]]; then
              println ACTION "tar ${excluded_files[*]} -cf ${backup_file} ${backup_list[*]}"
              if ! stdout=$(tar "${excluded_files[@]}" -cf "${backup_file}" "${backup_list[@]}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: during tarball creation:\n${stdout}" && waitToProceed && continue; fi
              println ACTION "gzip ${backup_file}"
              if ! stdout=$(gzip "${backup_file}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: gzip error:\n${stdout}" && waitToProceed && continue; fi
              backup_file+=".gz"
            else
              println ACTION "tar -cf ${backup_file} ${backup_list[*]}"
              if ! stdout=$(tar -cf "${backup_file}" "${backup_list[@]}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: during tarball creation:\n${stdout}" && waitToProceed && continue; fi
              println ACTION "gzip ${backup_file}"
              if ! stdout=$(gzip "${backup_file}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: gzip error:\n${stdout}" && waitToProceed && continue; fi
              backup_file+=".gz"
              while IFS= read -r -d '' wallet; do # check for missing signing keys
                wallet_name=$(basename ${wallet})
                [[ -z "$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f \( -name "${WALLET_PAY_SK_FILENAME}*" -o -name "${WALLET_HW_PAY_SK_FILENAME}" \) -print)" ]] && \
                  println "${FG_YELLOW}WARN${NC}: Wallet ${FG_GREEN}${wallet_name}${NC} missing payment signing key file" && missing_keys="true"
                [[ -z "$(find "${wallet}" -mindepth 1 -maxdepth 1 -type f \( -name "${WALLET_STAKE_SK_FILENAME}*" -o -name "${WALLET_HW_STAKE_SK_FILENAME}" \) -print)" ]] && \
                  println "${FG_YELLOW}WARN${NC}: Wallet ${FG_GREEN}${wallet_name}${NC} missing stake signing key file" && missing_keys="true"
              done < <(find "${WALLET_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
              while IFS= read -r -d '' pool; do
                pool_name=$(basename ${pool})
                [[ -z "$(find "${pool}" -mindepth 1 -maxdepth 1 -type f -name "${POOL_COLDKEY_SK_FILENAME}*" -print)" ]] && \
                  println "${FG_YELLOW}WARN${NC}: Pool ${FG_GREEN}${pool_name}${NC} missing file ${POOL_COLDKEY_SK_FILENAME}" && missing_keys="true"
              done < <(find "${POOL_FOLDER}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
              [[ ${missing_keys} = "true" ]] && echo
            fi
             println DEBUG "Encrypt backup?"
             select_opt "[y] Yes" "[n] No"
             case $? in
               0) echo
                  if getPasswordCust confirm; then # $password variable populated by getPasswordCust function
                    encryptFile "${backup_file}" "${password}"
                    backup_file="${backup_file}.gpg"
                    unset password
                  else
                    println ERROR "\n${FG_RED}ERROR${NC}: password input aborted!"
                  fi
                  ;;
               1) : ;; # do nothing
             esac
             echo
             if [[ ${missing_keys} = "true" ]]; then
               println DEBUG "${FG_YELLOW}There are wallets and/or pools with missing keys.\nIf removed in a previous backup, make sure to keep that master backup safe!${NC}"
               println "\nIncremental backup file ${backup_file} successfully created"
             else
               println "Backup file ${FG_LGRAY}${backup_file}${NC} successfully created"
             fi
             ;;
          1) println DEBUG "\n${FG_BLUE}INFO${NC}: a backup of existing wallet and pool folders will be made before restore is executed\n"
            fileDialog "Enter backup file to restore" && echo
            backup_file=${file}
            if [[ ! -f "${backup_file}" ]]; then
              println ERROR "${FG_RED}ERROR${NC}: file not found: ${backup_file}"
              waitToProceed && continue
            fi
            if ! restore_path="$(mktemp -d "${TMP_DIR}/restore_XXXXXXXXXX")"; then println ERROR "${FG_RED}ERROR${NC}: failed to create restore directory:\n${restore_path}" && waitToProceed && continue; fi
            tmp_bkp_file=""
            if [ "${backup_file##*.}" = "gpg" ]; then
              println DEBUG "Backup GPG encrypted, enter password to decrypt"
              if getPasswordCust; then # $password variable populated by getPasswordCust function
                tmp_bkp_file=$(mktemp "${TMP_DIR}/bkp_file_XXXXXXXXXX.tar.gz.gpg")
                cp -f "${backup_file}" "${tmp_bkp_file}"
                decryptFile "${backup_file}" "${password}"
                backup_file="${backup_file%.*}"
                unset password
                echo
              else
                println ERROR "\n${FG_RED}ERROR${NC}: password input aborted!"
                waitToProceed && continue
              fi
            fi
            println ACTION "tar xfzk ${backup_file} -C ${restore_path}"
            if ! stdout=$(tar xfzk "${backup_file}" -C "${restore_path}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: during tarball extraction:\n${stdout}" && waitToProceed && continue; fi
            [[ -n "${tmp_bkp_file}" ]] && mv -f "${tmp_bkp_file}" "${backup_file}.gpg" && rm -f "${backup_file}" # restore original encrypted backup file
            restore_source=(
              "${restore_path}${WALLET_FOLDER}"
              "${restore_path}${POOL_FOLDER}"
              "${restore_path}${ASSET_FOLDER}"
            )
            restore_list=()
            restore_cnt=0
            println DEBUG "Restore job include:\n"
            for item in "${restore_source[@]}"; do
              [[ ! -d "${item}" ]] && continue
              println DEBUG "$(basename "${item}")"
              while IFS= read -r -d '' dir; do
                restore_list+=( "${dir}" )
                println DEBUG "  ${FG_LGRAY}$(basename "${dir}")${NC}"
                ((restore_cnt++))
              done < <(find "${item}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
            done
            [[ ${restore_cnt} -eq 0 ]] && println "\nNothing in backup file to restore :(" && waitToProceed && continue
            echo
            println DEBUG "Continue with restore?"
            select_opt "[n] No" "[y] Yes"
            case $? in
              0) continue ;;
              1) : ;; # do nothing
            esac
            echo
            # Archive/backup existing priv folders
            archive_source=(
              "${WALLET_FOLDER}"
              "${POOL_FOLDER}"
              "${ASSET_FOLDER}"
            )
            archive_list=()
            source_cnt=0
            for item in "${archive_source[@]}"; do
              [[ ! -d "${item}" ]] && continue
              while IFS= read -r -d '' dir; do
                archive_list+=( "${item}" )
                ((source_cnt++))
              done < <(find "${item}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
            done
            if [[ ${source_cnt} -gt 0 ]]; then
              archive_dest="${CNODE_HOME}/priv/archive"
              if ! mkdir -p "${archive_dest}"; then println ERROR "${FG_RED}ERROR${NC}: failed to create archive directory:\n${archive_dest}" && waitToProceed && continue; fi
              archive_file="${archive_dest}/archive_$(date '+%Y%m%d%H%M%S').tar.gz"
              println ACTION "tar cfz ${archive_file} ${archive_list[*]}"
              if ! stdout=$(tar cfz "${archive_file}" "${archive_list[@]}" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: during archive/backup:\n${stdout}" && waitToProceed && continue; fi
              println DEBUG "An archive of current priv folder has been taken and stored in ${FG_LGRAY}${archive_file}${NC}"
              println DEBUG "Please set a password to GPG encrypt the archive"
              if getPasswordCust confirm; then # $password variable populated by getPasswordCust function
                encryptFile "${archive_file}" "${password}"
                archive_file="${archive_file}.gpg"
                unset password
              else
                println ERROR "\n${FG_RED}ERROR${NC}: password input aborted!"
                println DEBUG "${FG_YELLOW}archive stored unencrypted !!${NC}"
              fi
              echo
            fi
            for item in "${restore_list[@]}"; do
              dest_path="${item:${#restore_path}}"
              while IFS= read -r -d '' file; do # unlock files to make sure restore is successful
                unlockFile "${file}"
              done < <(find "${dest_path}" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
              println ACTION "cp -rf ${item} $(dirname "${dest_path}")"
              if ! stdout=$(cp -rf "${item}" "$(dirname "${dest_path}")" 2>&1); then println ERROR "${FG_RED}ERROR${NC}: during retore copy:\n${stdout}" && waitToProceed && continue; fi
            done
            println "Backup ${FG_LGRAY}$(basename "${backup_file}")${NC} successfully restored!"
            ;;
          2) continue ;;
        esac
        waitToProceed && continue
        ;; ###################################################################
      advanced)
        while true; do # Advanced loop
          clear
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println " >> ADVANCED"
          println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println OFF " Developer & Advanced features\n"\
						" ) Metadata       - create and optionally post metadata on-chain"\
						" ) Asset          - asset nanagement"\
						" ) MultiSig       - create a multi-signature wallet"\
						" ) Delete Keys    - delete all sign/cold keys from CNTools (wallet|pool|asset)"\
						"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
          println DEBUG " Select Operation\n"
          select_opt "[m] Metadata" "[a] Asset" "[s] MultiSig" "[x] Delete Private Keys" "[h] Home"
          case $? in
            0) SUBCOMMAND="metadata" ;;
            1) SUBCOMMAND="asset" ;;
            2) SUBCOMMAND="multisig" ;;
            3) SUBCOMMAND="del-keys" ;;
            4) break ;;
          esac
          case $SUBCOMMAND in
            metadata)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> ADVANCED >> METADATA"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available to pay for transaction fee!${NC}" && waitToProceed && continue
              if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                println ERROR "\n${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                waitToProceed && continue
              else
                if ! selectOpMode; then continue; fi
              fi
              echo
              println DEBUG "Select the type of metadata to post on-chain"
              println DEBUG "ref: https://github.com/input-output-hk/cardano-node-wiki/wiki/tx-metadata"
              select_opt "[n] No JSON Schema (default)" "[d] Detailed JSON Schema" "[c] Raw CBOR"
              case $? in
                0) metatype="no-schema" ;;
                1) metatype="detailed-schema" ;;
                2) metatype="cbor" ;;
              esac
              if [[ ${metatype} = "cbor" ]]; then
                fileDialog "Enter path to raw CBOR metadata file" && echo
                metafile="${file}"
              else
                metafile="${TMP_DIR}/metadata_$(date '+%Y%m%d%H%M%S').json"
                println DEBUG "\nDo you want to select a metadata file, enter URL to metadata file, or enter/paste metadata content?"
                select_opt "[f] File" "[u] URL" "[e] Enter"
                case $? in
                  0) fileDialog "Enter path to JSON metadata file" && echo
                    metafile="${file}"
                    if [[ ! -f "${metafile}" ]] || ! jq -er . "${metafile}" &>/dev/null; then
                      println ERROR "${FG_RED}ERROR${NC}: invalid JSON format or file not found"
                      waitToProceed && continue
                    fi
                    println DEBUG "$(cat "${metafile}")\n"
                    ;;
                  1) tput sc && echo
                    getAnswerAnyCust meta_json_url "Enter URL to JSON metadata file"
                    if [[ ! "${meta_json_url}" =~ https?://.* ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: invalid URL format"
                      waitToProceed && continue
                    fi
                    if ! curl -sL -m ${CURL_TIMEOUT} -o "${metafile}" ${meta_json_url} || ! jq -er . "${metafile}" &>/dev/null; then
                      println ERROR "${FG_RED}ERROR${NC}: metadata download failed, please make sure the URL point to a valid JSON file!"
                      waitToProceed && continue
                    fi
                    tput rc && tput ed
                    println "Metadata file successfully downloaded to: ${FG_LGRAY}${metafile}${NC}"
                    ;;
                  2) println "Add an example metadata JSON scaffold?"
                    select_opt "[y] Yes" "[n] No"
                    case $? in
                      0) jq . <<< '{"1815":{"name":"ADA Lovelace","age":36,"parents":[{"id":0,"name":"George Gordon Byron"},{"id":1,"name":"Anne Isabella Byron"}]}}' > "${metafile}" ;;
                      1) : ;; # do nothing
                    esac
                    tput sc
                    DEFAULTEDITOR="$(command -v nano &>/dev/null && echo 'nano' || echo 'vi')"
                    println OFF "\nPaste or enter the metadata text, opening text editor ${FG_LGRAY}${DEFAULTEDITOR}${NC}"
                    println OFF "${FG_YELLOW}Please don't change default file path when saving${NC}"
                    waitToProceed "press any key to open ${DEFAULTEDITOR}"
                    ${DEFAULTEDITOR} "${metafile}"
                    if [[ ! -f "${metafile}" ]] || ! jq -er . "${metafile}" &>/dev/null; then
                      println ERROR "${FG_RED}ERROR${NC}: file not found or invalid JSON format"
                      println ERROR "File: ${FG_LGRAY}${metafile}${NC}"
                      waitToProceed && continue
                    fi
                    tput rc && tput ed
                    println "Metadata file successfully saved to: ${FG_LGRAY}${metafile}${NC}"
                    ;;
                esac
              fi
              println DEBUG "\nContinue to post metadata on-chain or stop at this point?"
              select_opt "[c] Continue" "[s] Stop"
              case $? in
                0) : ;; # do nothing
                1) continue ;;
              esac
              println DEBUG "\nSelect wallet to pay for metadata transaction fee"
              if [[ ${op_mode} = "online" ]]; then
                selectWallet "balance"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for metadata transaction fee!" && waitToProceed && continue ;;
                  2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                  3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                esac
              else
                selectWallet "balance"
                case $? in
                  1) waitToProceed; continue ;;
                  2) continue ;;
                esac
                getWalletType ${wallet_name}
                case $? in
                  0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet to pay for metadata transaction fee!" && waitToProceed && continue ;;
                esac
              fi
              echo
              getWalletBalance ${wallet_name} true true true true
              if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
                # Both payment and base address available with funds, let user choose what to use
                println DEBUG "Select source wallet address"
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
                echo
                select_opt "[b] Base (default)" "[e] Payment" "[Esc] Cancel"
                case $? in
                  0) addr="${base_addr}"; lovelace=${base_lovelace} ;;
                  1) addr="${pay_addr}";  lovelace=${pay_lovelace} ;;
                  2) continue ;;
                esac
              elif [[ ${pay_lovelace} -gt 0 ]]; then
                addr="${pay_addr}"
                lovelace=${pay_lovelace}
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                fi
              elif [[ ${base_lovelace} -gt 0 ]]; then
                addr="${base_addr}"
                lovelace=${base_lovelace}
                if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                  println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                fi
              else
                println ERROR "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                waitToProceed && continue
              fi
              if ! sendMetadata; then
                waitToProceed && continue
              fi
              echo
              if ! verifyTx ${addr}; then waitToProceed && continue; fi
              echo
              println "Metadata successfully posted on-chain"
              waitToProceed && continue
              ;; ###################################################################
            asset)
              while true; do # Asset loop
                clear
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println " >> ADVANCED >> ASSET"
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println OFF " Asset Token Management\n"\
									" ) Create Policy  - create a new asset policy"\
									" ) List Assets    - list created/minted policies/assets (local)"\
									" ) Show Asset     - show minted asset information"\
									" ) Decrypt Policy - remove write protection and decrypt policy"\
									" ) Encrypt Policy - encrypt policy sign key and make all files immutable"\
									" ) Mint Asset     - mint new assets for selected policy"\
									" ) Burn Asset     - burn a given amount of assets in selected wallet"\
									" ) Register Asset - create/update JSON submission file for Cardano Token Registry"\
									"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println DEBUG " Select Asset Operation\n"
                select_opt "[c] Create Policy" "[l] List Assets" "[s] Show Asset" "[d] Decrypt / Unlock Policy" "[e] Encrypt / Lock Policy" "[m] Mint Asset" "[x] Burn Asset" "[r] Register Asset" "[b] Back" "[h] Home"
                case $? in
                  0) SUBCOMMAND="create-policy" ;;
                  1) SUBCOMMAND="list-assets" ;;
                  2) SUBCOMMAND="show-asset" ;;
                  3) SUBCOMMAND="decrypt-policy" ;;
                  4) SUBCOMMAND="encrypt-policy" ;;
                  5) SUBCOMMAND="mint-asset" ;;
                  6) SUBCOMMAND="burn-asset" ;;
                  7) SUBCOMMAND="register-asset" ;;
                  8) break ;;
                  9) break 2 ;;
                esac
                case $SUBCOMMAND in
                  create-policy)
                    cntools_compatibility_dispatch_action advanced.asset.create-policy
                    action_status=$?
                    case "${action_status}" in
                      0) continue ;;
                      20|21) break 2 ;;
                      22) myExit 0 "CNTools closed!" ;;
                      *) waitToProceed; continue ;;
                    esac
                    ;; ###################################################################
                  list-assets)
                    cntools_compatibility_dispatch_action advanced.asset.list
                    action_status=$?
                    case "${action_status}" in
                      0) waitToProceed; continue ;;
                      20|21) break 2 ;;
                      22) myExit 0 "CNTools closed!" ;;
                      *) waitToProceed; continue ;;
                    esac
                    ;; ###################################################################
                  show-asset)
                    cntools_compatibility_dispatch_action advanced.asset.show
                    action_status=$?
                    case "${action_status}" in
                      0) continue ;;
                      20|21) break 2 ;;
                      22) myExit 0 "CNTools closed!" ;;
                      *) waitToProceed; continue ;;
                    esac
                    ;; ###################################################################
                  decrypt-policy)
                    cntools_compatibility_dispatch_action advanced.asset.decrypt-policy
                    action_status=$?
                    case "${action_status}" in
                      0) continue ;;
                      20|21) break 2 ;;
                      22) myExit 0 "CNTools closed!" ;;
                      *) waitToProceed; continue ;;
                    esac
                    ;; ###################################################################
                  encrypt-policy)
                    cntools_compatibility_dispatch_action advanced.asset.encrypt-policy
                    action_status=$?
                    case "${action_status}" in
                      0) continue ;;
                      20|21) break 2 ;;
                      22) myExit 0 "CNTools closed!" ;;
                      *) waitToProceed; continue ;;
                    esac
                    ;; ###################################################################
                  mint-asset)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> ASSET >> MINT ASSET"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    echo
                    [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No policies found!${NC}\n\nPlease first create a policy to mint asset with" && waitToProceed && continue
                    println DEBUG "Select the policy to use when minting the asset"
                    selectPolicy "all" "${ASSET_POLICY_SK_FILENAME}" "${ASSET_POLICY_VK_FILENAME}" "${ASSET_POLICY_SCRIPT_FILENAME}" "${ASSET_POLICY_ID_FILENAME}"
                    case $? in
                      1) waitToProceed; continue ;;
                      2) continue ;;
                    esac
                    policy_folder="${ASSET_FOLDER}/${policy_name}"
                    # Policy filenames
                    policy_sk_file="${policy_folder}/${ASSET_POLICY_SK_FILENAME}"
                    policy_vk_file="${policy_folder}/${ASSET_POLICY_VK_FILENAME}"
                    policy_script_file="${policy_folder}/${ASSET_POLICY_SCRIPT_FILENAME}"
                    policy_id_file="${policy_folder}/${ASSET_POLICY_ID_FILENAME}"
                    policy_id="$(cat "${policy_id_file}")"
                    policy_ttl=$(jq -r '.scripts[0].slot //0' "${policy_script_file}")
                    [[ ${policy_ttl} -gt 0 && ${policy_ttl} -lt $(getSlotTipRef) ]] && println ERROR "${FG_RED}ERROR${NC}: Policy expired!" && waitToProceed && continue
                    echo
                    if [[ $(find "${policy_folder}" -type f -name '*.asset' -print0 | wc -c) -gt 0 ]]; then
                      println DEBUG "Assets minted for this Policy\n"
                      asset_name_maxlen=5; asset_amount_maxlen=12
                      while IFS= read -r -d '' asset; do
                        asset_name=$(jq -r '.name //empty' "${asset}")
                        [[ ${#asset_name} -gt ${asset_name_maxlen} ]] && asset_name_maxlen=${#asset_name}
                        asset_minted=$(jq -r '.minted //0' "${asset}")
                        [[ ${#asset_minted} -gt ${asset_amount_maxlen} ]] && asset_amount_maxlen=${#asset_minted}
                      done < <(find "${policy_folder}" -mindepth 1 -maxdepth 1 -type f -name '*.asset' -print0 | sort -z)
                      println DEBUG "$(printf "%${asset_amount_maxlen}s | %s\n" "Total Amount" "Policy ID[.AssetName]")"
                      println DEBUG "$(printf "%$((asset_amount_maxlen+1))s+%$((asset_name_maxlen+58))s\n" "" "" | tr " " "-")"
                      while IFS= read -r -d '' asset; do
                        asset_name=$(jq -r '.name //empty' "${asset}")
                        [[ -z ${asset_name} ]] && asset_name="${FG_LGRAY}${policy_id}${NC}" || asset_name="${FG_LGRAY}${policy_id}.${FG_MAGENTA}${asset_name}${NC}"
                        asset_minted=$(jq -r '.minted //0' "${asset}")
                        println DEBUG "$(printf "${FG_LBLUE}%${asset_amount_maxlen}s${NC} | %s\n" "${asset_minted}" "${asset_name}")"
                      done < <(find "${policy_folder}" -mindepth 1 -maxdepth 1 -type f -name '*.asset' -print0 | sort -z)
                      println DEBUG "\nEnter an existing AssetName to mint more tokens or enter a new name to create a new Asset for this Policy"
                    fi
                    getAnswerAnyCust asset_name "Asset Name (empty valid)"
                    [[ ${asset_name} =~ ^[^[:alnum:]]$ ]] && println ERROR "${FG_RED}ERROR${NC}: Asset name should only contain alphanummeric chars!" && waitToProceed && continue
                    [[ ${#asset_name} -gt 32 ]] && println ERROR "${FG_RED}ERROR${NC}: Asset name is limited to 32 chars in length!" && waitToProceed && continue
                    asset_file="${policy_folder}/${asset_name// /_}.asset"
                    echo
                    getAnswerAnyCust assets_to_mint "Amount (commas allowed as thousand separator)"
                    assets_to_mint="${assets_to_mint//,}"
                    [[ -z "${assets_to_mint}" ]] && println ERROR "${FG_RED}ERROR${NC}: Amount empty, please set a valid integer number!" && waitToProceed && continue
                    if ! isNumber ${assets_to_mint}; then println ERROR "${FG_RED}ERROR${NC}: Invalid number, should be an integer number. Decimals not allowed!" && waitToProceed && continue; fi
                    [[ -f "${asset_file}" ]] && asset_minted=$(( $(jq -r .minted "${asset_file}") + assets_to_mint )) || asset_minted=${assets_to_mint}
                    metafile_param=""
                    println DEBUG "\nDo you want to attach a metadata JSON file to the minting transaction?"
                    select_opt "[n] No" "[y] Yes"
                    case $? in
                      0) : ;; # do nothing
                      1) fileDialog "Enter path to metadata JSON file" "${TMP_DIR}/" && echo
                        metafile=${file}
                        [[ -z "${metafile}" ]] && println ERROR "${FG_RED}ERROR${NC}: Metadata file path empty!" && waitToProceed && continue
                        [[ ! -f "${metafile}" ]] && println ERROR "${FG_RED}ERROR${NC}: File not found: ${metafile}" && waitToProceed && continue
                        if ! jq -er . "${metafile}"; then println ERROR "${FG_RED}ERROR${NC}: Metadata file not a valid json file!" && waitToProceed && continue; fi
                        metafile_param="--metadata-json-file ${metafile}"
                        ;;
                    esac
                    println DEBUG "\nSelect wallet to mint assets on (also used for transaction fee)"
                    if [[ ${op_mode} = "online" ]]; then
                      selectWallet "balance"
                      case $? in
                        1) waitToProceed; continue ;;
                        2) continue ;;
                      esac
                      getWalletType ${wallet_name}
                      case $? in
                        2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                        3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                      esac
                    else
                      selectWallet "balance"
                      case $? in
                        1) waitToProceed; continue ;;
                        2) continue ;;
                      esac
                    fi
                    echo
                    getWalletBalance ${wallet_name} true true true true
                    if [[ ${pay_lovelace} -gt 0 && ${base_lovelace} -gt 0 ]]; then
                      # Both payment and base address available with funds, let user choose what to use
                      println DEBUG "Select source wallet address"
                      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                        println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                        println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                      fi
                      echo
                      select_opt "[b] Base (default)" "[e] Payment" "[Esc] Cancel"
                      case $? in
                        0) addr="${base_addr}"; lovelace=${base_lovelace} ;;
                        1) addr="${pay_addr}" ; lovelace=${pay_lovelace} ;;
                        2) continue ;;
                      esac
                      echo
                    elif [[ ${pay_lovelace} -gt 0 ]]; then
                      addr="${pay_addr}"
                      lovelace=${pay_lovelace}
                      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                        println DEBUG "$(printf "%s\t${FG_LBLUE}%s${NC} ADA\n" "Payment Funds :"  "$(formatLovelace ${pay_lovelace})")"
                      fi
                    elif [[ ${base_lovelace} -gt 0 ]]; then
                      addr="${base_addr}"
                      lovelace=${base_lovelace}
                      if [[ -n ${wallet_count} && ${wallet_count} -gt ${WALLET_SELECTION_FILTER_LIMIT} ]]; then
                        println DEBUG "$(printf "%s\t\t${FG_LBLUE}%s${NC} ADA\n" "Base Funds :"  "$(formatLovelace ${base_lovelace})")"
                      fi
                    else
                      println ERROR "${FG_RED}ERROR${NC}: no funds available for wallet ${FG_GREEN}${wallet_name}${NC}"
                      waitToProceed && continue
                    fi
                    if ! mintAsset; then
                      waitToProceed && continue
                    fi
                    if [[ ! -f "${asset_file}" ]]; then echo "{}" > "${asset_file}"; fi
                    assetJSON=$( jq ". += {minted: \"${asset_minted}\", name: \"${asset_name}\", policyID: \"${policy_id}\", assetName: \"$(asciiToHex "${asset_name}")\", policyValidBeforeSlot: \"${policy_ttl}\", lastUpdate: \"$(date -R)\", lastAction: \"Minted $(formatAsset ${assets_to_mint})\"}" < "${asset_file}")
                    echo -e "${assetJSON}" > "${asset_file}"
                    echo
                    if ! verifyTx ${addr}; then waitToProceed && continue; fi
                    echo
                    println "Assets successfully minted!"
                    println "Policy Name    : ${FG_GREEN}${policy_name}${NC}"
                    println "Policy ID      : ${FG_LGRAY}${policy_id}${NC}"
                    [[ -z ${asset_name} ]] && asset_name_hex="" || asset_name_hex="$(asciiToHex "${asset_name}")"
                    println "Asset Name     : ${FG_MAGENTA}${asset_name}${NC}${FG_LGRAY} (${asset_name_hex})${NC}"
                    getAssetInfo "${policy_id}" "${asset_name_hex}"
                    case $? in
                      0) println "Fingerprint    : ${FG_LGRAY}${a_fingerprint}${NC}"
                         println "Minted         : ${FG_LBLUE}$(formatAsset ${assets_to_mint})${NC}"
                         println "In Circulation : ${FG_LBLUE}$(formatAsset ${a_total_supply})${NC}"
                         println "Mint Count     : ${FG_LBLUE}${a_mint_cnt}${NC}"
                         println "Burn Count     : ${FG_LBLUE}${a_burn_cnt}${NC}" ;;
                      1) println "ERROR" "${FG_RED}KOIOS_API ERROR${NC}: ${error_msg}" ;;
                      2) println "Minted         : ${FG_LBLUE}$(formatAsset ${assets_to_mint})${NC}"
                         println "In Circulation : ${FG_LBLUE}$(formatAsset ${asset_minted})${NC} (local tracking)" ;;
                    esac
                    println DEBUG "\n${FG_YELLOW}Please note that it can take a couple of minutes before minted asset show in wallet${NC}"
                    waitToProceed && continue
                    ;; ###################################################################
                  burn-asset)
                    clear
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    println " >> ADVANCED >> ASSET >> BURN ASSET"
                    println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    [[ ! $(ls -A "${WALLET_FOLDER}" 2>/dev/null) ]] && echo && println "${FG_YELLOW}No wallets available!${NC}" && waitToProceed && continue
                    if [[ ${CNTOOLS_MODE} = "OFFLINE" ]]; then
                      println ERROR "${FG_RED}ERROR${NC}: CNTools started in offline mode, option not available!"
                      waitToProceed && continue
                    else
                      if ! selectOpMode; then continue; fi
                    fi
                    echo
                    println DEBUG "Select wallet with assets to burn"
                    if [[ ${op_mode} = "online" ]]; then
                      selectWallet "balance"
                      case $? in
                        1) waitToProceed; continue ;;
                        2) continue ;;
                      esac
                      getWalletType ${wallet_name}
                      case $? in
                        0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet for asset burning!" && waitToProceed && continue ;;
                        2) println ERROR "${FG_RED}ERROR${NC}: signing keys encrypted, please decrypt before use!" && waitToProceed && continue ;;
                        3) println ERROR "${FG_RED}ERROR${NC}: payment and/or stake signing keys missing from wallet!" && waitToProceed && continue ;;
                      esac
                    else
                      selectWallet "balance"
                      case $? in
                        1) waitToProceed; continue ;;
                        2) continue ;;
                      esac
                      getWalletType ${wallet_name}
                      case $? in
                        0) println ERROR "${FG_RED}ERROR${NC}: please use a CLI wallet for asset burning!" && waitToProceed && continue ;;
                      esac
                    fi
                    # Let user choose asset on wallet to burn, both base and payment, fee payed with same address
                    assets_on_wallet=()
                    getWalletBalance ${wallet_name} true true true true
                    for asset in "${!base_assets[@]}"; do
                      [[ ${asset} = "lovelace" ]] && continue
                      IFS='.' read -ra asset_arr <<< "${asset}"
                      [[ -z ${asset_arr[1]} ]] && asset_ascii_name="" || asset_ascii_name=$(hexToAscii ${asset_arr[1]})
                      assets_on_wallet+=( "${asset} (${asset_ascii_name}) [base addr]" )
                    done
                    for asset in "${!pay_assets[@]}"; do
                      [[ ${asset} = "lovelace" ]] && continue
                      IFS='.' read -ra asset_arr <<< "${asset}"
                      [[ -z ${asset_arr[1]} ]] && asset_ascii_name="" || asset_ascii_name=$(hexToAscii ${asset_arr[1]})
                      assets_on_wallet+=( "${asset} (${asset_ascii_name}) [payment addr]" )
                    done
                    echo
                    [[ ${#assets_on_wallet[@]} -eq 0 ]] && println ERROR "${FG_RED}ERROR${NC}: Wallet doesn't contain any assets!" && waitToProceed && continue
                    println DEBUG "Select Asset to burn"
                    select_opt "${assets_on_wallet[@]}" "[Esc] Cancel"
                    selection=$?
                    [[ ${selected_value} = "[Esc] Cancel" ]] && continue
                    IFS=' ' read -ra selection_arr <<< "${assets_on_wallet[${selection}]}"
                    asset="${selection_arr[0]}"
                    IFS='.' read -ra asset_arr <<< "${selection_arr[0]}"
                    selection_arr_length=${#selection_arr[@]}
                    if [[ ${selection_arr[*]:$((selection_arr_length-2))} = "[base addr]" ]]; then
                      addr=${base_addr}
                      wallet_source="base"
                      curr_asset_amount=${base_assets[${asset}]}
                      lovelace=${base_assets[lovelace]}
                    else
                      addr=${pay_addr}
                      wallet_source="payment"
                      curr_asset_amount=${pay_assets[${asset}]}
                      lovelace=${pay_assets[lovelace]}
                    fi
                    echo

                    # Search policies for a match
                    asset_file=""
                    while IFS= read -r -d '' file; do
                      [[ ${asset_arr[0]} = "$(jq -r .policyID ${file})" ]] && asset_file="${file}" && break
                    done < <(find "${ASSET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name '*.asset' -print0)
                    [[ -z "${asset_file}" ]] && println ERROR "${FG_RED}ERROR${NC}: Searched all available policies in '${ASSET_FOLDER}' for matching '.asset' file but non found!" && waitToProceed && continue

                    [[ ${#asset_arr[@]} -eq 1 ]] && asset_name="" || asset_name="${asset_arr[1]}"

                    # Policy filenames
                    policy_folder="$(dirname "${asset_file}")"
                    policy_name="$(basename "${policy_folder}")"
                    policy_sk_file="${policy_folder}/${ASSET_POLICY_SK_FILENAME}"
                    policy_vk_file="${policy_folder}/${ASSET_POLICY_VK_FILENAME}"
                    policy_script_file="${policy_folder}/${ASSET_POLICY_SCRIPT_FILENAME}"
                    policy_id_file="${policy_folder}/${ASSET_POLICY_ID_FILENAME}"
                    policy_id="$(cat "${policy_id_file}")"
                    policy_ttl=$(jq -r '.scripts[0].slot //0' "${policy_script_file}")
                    [[ ${policy_ttl} -gt 0 && ${policy_ttl} -lt $(getSlotTipRef) ]] && println ERROR "${FG_RED}ERROR${NC}: Policy expired!" && waitToProceed && continue
                    # ask amount to burn
                    println DEBUG "Available assets to burn: ${FG_LBLUE}$(formatAsset "${curr_asset_amount}")${NC}\n"
                    getAnswerAnyCust assets_to_burn "Amount (commas allowed as thousand separator)"
                    assets_to_burn="${assets_to_burn//,}"
                    [[ ${assets_to_burn} = "all" ]] && assets_to_burn=${curr_asset_amount}
                    if ! isNumber ${assets_to_burn}; then println ERROR "${FG_RED}ERROR${NC}: Invalid number, should be an integer number. Decimals not allowed!" && waitToProceed && continue; fi
                    [[ ${assets_to_burn} -gt ${curr_asset_amount} ]] && println ERROR "${FG_RED}ERROR${NC}: Amount exceeding assets in address, you can only burn ${FG_LBLUE}$(formatAsset "${asset_amount}")${NC}" && waitToProceed && continue
                    asset_minted=$(( $(jq -r .minted "${asset_file}") - assets_to_burn ))
                    # Attach metadata?
                    metafile_param=""
                    println DEBUG "\nDo you want to attach a metadata JSON file to the burning transaction?"
                    select_opt "[n] No" "[y] Yes"
                    case $? in
                      0) : ;; # do nothing
                      1) fileDialog "Enter path to metadata JSON file" "${TMP_DIR}/" && echo
                        metafile=${file}
                        [[ -z "${metafile}" ]] && println ERROR "${FG_RED}ERROR${NC}: Metadata file path empty!" && waitToProceed && continue
                        [[ ! -f "${metafile}" ]] && println ERROR "${FG_RED}ERROR${NC}: File not found: ${metafile}" && waitToProceed && continue
                        if ! jq -er . "${metafile}"; then println ERROR "${FG_RED}ERROR${NC}: Metadata file not a valid json file!" && waitToProceed && continue; fi
                        metafile_param="--metadata-json-file ${metafile}"
                        ;;
                    esac
                    echo
                    # Call burn helper function
                    if ! burnAsset; then
                      waitToProceed && continue
                    fi
                    # Update asset file
                    if [[ ! -f "${asset_file}" ]]; then echo "{}" > "${asset_file}"; fi
                    assetJSON=$( jq ". += {minted: \"${asset_minted}\", name: \"$(hexToAscii "${asset_name}")\", policyID: \"${policy_id}\", policyValidBeforeSlot: \"${policy_ttl}\", lastUpdate: \"$(date -R)\", lastAction: \"Burned $(formatAsset ${assets_to_burn})\"}" < "${asset_file}")
                    echo -e "${assetJSON}" > "${asset_file}"
                    echo
                    if ! verifyTx ${addr}; then waitToProceed && continue; fi
                    echo
                    println "Assets successfully burned!"
                    println "Policy Name     : ${FG_GREEN}${policy_name}${NC}"
                    println "Policy ID       : ${FG_LGRAY}${policy_id}${NC}"
                    [[ -z ${asset_name} ]] && asset_name_ascii="" || asset_name_ascii="$(hexToAscii "${asset_name}")"
                    println "Asset Name      : ${FG_MAGENTA}${asset_name_ascii}${NC}${FG_LGRAY} (${asset_name})${NC}"
                    println "Left in Address : ${FG_LBLUE}$(formatAsset $(( curr_asset_amount - assets_to_burn )))${NC}"
                    getAssetInfo "${policy_id}" "${asset_name}"
                    case $? in
                      0) println "Fingerprint     : ${FG_LGRAY}${a_fingerprint}${NC}"
                         println "Burned          : ${FG_LBLUE}$(formatAsset ${assets_to_burn})${NC}"
                         println "In Circulation  : ${FG_LBLUE}$(formatAsset ${a_total_supply})${NC}"
                         println "Mint Count      : ${FG_LBLUE}${a_mint_cnt}${NC}"
                         println "Burn Count      : ${FG_LBLUE}${a_burn_cnt}${NC}" ;;
                      1) println "ERROR" "${FG_RED}KOIOS_API ERROR${NC}: ${error_msg}" ;;
                      2) println "Burned          : ${FG_LBLUE}$(formatAsset ${assets_to_burn})${NC}"
                         println "In Circulation  : ${FG_LBLUE}$(formatAsset ${asset_minted})${NC} (local tracking)" ;;
                    esac
                    println DEBUG "\n${FG_YELLOW}Please note that burned assets can take a couple of minutes before being reflected in wallet${NC}"
                    waitToProceed && continue
                    ;; ###################################################################
                  register-asset)
                    cntools_compatibility_dispatch_action advanced.asset.register
                    action_status=$?
                    case "${action_status}" in
                      0) continue ;;
                      20|21) break 2 ;;
                      22) myExit 0 "CNTools closed!" ;;
                      *) waitToProceed; continue ;;
                    esac
                    ;; ###################################################################
                esac # advanced >> asset sub OPERATION
              done # Asset loop
              ;; ###################################################################
            multisig)
              while true; do # MultiSig loop
                clear
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println " >> ADVANCED >> MULTISIG"
                println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println OFF " Multi Signature Wallet Management\n"\
                  " ) Create Wallet  - create a new multi-signature wallet"\
                  " ) Derive Keys    - derive MultiSig keys using the 1854H paths according to CIP-1854"\
                  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                println DEBUG " Select MultiSig Operation\n"
                select_opt "[c] Create" "[d] Derive Keys" "[b] Back" "[h] Home"
                case $? in
                  0) SUBCOMMAND="create-ms-wallet" ;;
                  1) SUBCOMMAND="derive-ms-keys" ;;
                  2) break ;;
                  3) break 2 ;;
                esac
                case $SUBCOMMAND in
                  create-ms-wallet)
                    cntools_compatibility_dispatch_action advanced.multisig.create
                    action_status=$?
                    case "${action_status}" in
                      0) continue ;;
                      20|21) break 2 ;;
                      22) myExit 0 "CNTools closed!" ;;
                      *) waitToProceed; continue ;;
                    esac
                    ;; ###################################################################
                  derive-ms-keys)
                    cntools_compatibility_dispatch_action advanced.multisig.derive-keys
                    action_status=$?
                    case "${action_status}" in
                      0) continue ;;
                      20|21) break 2 ;;
                      22) myExit 0 "CNTools closed!" ;;
                      *) waitToProceed; continue ;;
                    esac
                    ;; ###################################################################
                esac # advanced >> MultiSig sub OPERATION
              done # MultiSig loop
              ;; ###################################################################
            del-keys)
              clear
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              println " >> ADVANCED >> DELETE PRIVATE KEYS"
              println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
              echo
              println DEBUG "The following files will be removed"
              println DEBUG "Wallet ${FG_LGRAY}${WALLET_PAY_SK_FILENAME}${NC} / ${FG_LGRAY}${WALLET_STAKE_SK_FILENAME}${NC}"
              println DEBUG "Pool   ${FG_LGRAY}${POOL_COLDKEY_SK_FILENAME}${NC}"
              [[ -d "${ASSET_FOLDER}" ]] && println DEBUG "Asset  ${FG_LGRAY}${ASSET_POLICY_SK_FILENAME}${NC}"
              echo
              println DEBUG "${FG_RED}Do you acknowledge that you have already taken a full backup, and are OK to simply delete the private keys? There is no going back !!!${NC}"
              select_opt "[n] No" "[y] Yes"
              case $? in
                0) continue ;;
                1) : ;; # do nothing
              esac
              echo
              println DEBUG "${FG_YELLOW}Please confirm!${NC} If unsure, cancel and verify that you have a valid backup. Continue with delete action?"
              select_opt "[n] No" "[y] Yes"
              case $? in
                0) continue ;;
                1) : ;; # do nothing
              esac
              echo
              println DEBUG "Delete encrypted keys as well?"
              select_opt "[n] No" "[y] Yes"
              case $? in
                0) enc_postfix="" ;;
                1) enc_postfix="*" ;;
              esac
              echo
              key_del_cnt=0
              while IFS= read -r -d '' file; do
                unlockFile "${file}" && safeDel "${file}" && ((key_del_cnt++))
              done < <(find "${WALLET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${WALLET_PAY_SK_FILENAME}${enc_postfix}" -print0 2>/dev/null)
              while IFS= read -r -d '' file; do
                unlockFile "${file}" && safeDel "${file}" && ((key_del_cnt++))
              done < <(find "${WALLET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${WALLET_STAKE_SK_FILENAME}${enc_postfix}" -print0 2>/dev/null)
              while IFS= read -r -d '' file; do
                unlockFile "${file}" && safeDel "${file}" && ((key_del_cnt++))
              done < <(find "${POOL_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${POOL_COLDKEY_SK_FILENAME}${enc_postfix}" -print0 2>/dev/null)
              while IFS= read -r -d '' file; do
                unlockFile "${file}" && safeDel "${file}" && ((key_del_cnt++))
              done < <(find "${ASSET_FOLDER}" -mindepth 2 -maxdepth 2 -type f -name "${ASSET_POLICY_SK_FILENAME}${enc_postfix}" -print0 2>/dev/null)
              if [[ ${key_del_cnt} -eq 0 ]]; then
                println "No private keys found!"
              else
                println "\n${FG_LBLUE}${key_del_cnt}${NC} private key(s) found and deleted!"
              fi
              waitToProceed && continue
              ;; ###################################################################
          esac # advanced sub OPERATION
        done # Advanced loop
        ;; ###################################################################
    esac # main OPERATION
  done # main loop
}

##############################################################

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
