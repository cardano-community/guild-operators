#!/usr/bin/env bash
# shellcheck disable=SC2086,SC1090,SC2059,SC2016,SC2035
# shellcheck source=/dev/null

##########################################
# User Variables - Change as desired     #
# command line flags override set values #
##########################################
#G_ACCOUNT="cardano-community"  # Override github GUILD account if you forked the project
#NETWORK='mainnet'              # Connect to specified network instead of public network (Default: connect to public cardano network)
#WANT_BUILD_DEPS='Y'            # Skip installing OS level dependencies (Default: will check and install any missing OS level prerequisites)
#FORCE_OVERWRITE='N'            # Force overwrite of all config files (topology.json, config.json and genesis files)
#SCRIPTS_FORCE_OVERWRITE='N'    # Force overwrite of all scripts (including normally saved user config sections in env, cnode.sh and gLiveView.sh)
#LIBSODIUM_FORK='Y'             # Use IOG fork of libsodium instead of official repositories - Recommended as per IOG instructions (Default: IOG fork)
#INSTALL_CNCLI='N'              # Install/Upgrade and build CNCLI with RUST
#INSTALL_CWHCLI='N'             # Install/Upgrade Vacuumlabs cardano-hw-cli for hardware wallet support
#INSTALL_OGMIOS='N'             # Install Ogmios Server
#INSTALL_CSIGNER='N'            # Install/Upgrade Cardano Signer
#INSTALL_BLOCKPERF='N'          # Install openBlockPerf (enhanced global network monitoring)
#CNODE_NAME='cnode'             # Alternate name for top level folder, non alpha-numeric chars will be replaced with underscore (Default: cnode)
#CURL_TIMEOUT=60                # Maximum time in seconds that you allow the file download operation to take before aborting (Default: 60s)
#UPDATE_CHECK='Y'               # Check if there is an updated version of guild-deploy.sh script to download
#SUDO='Y'                       # Used by docker builds to disable sudo, leave unchanged if unsure.
#SKIP_DBSYNC_DOWNLOAD='N'       # When using -i d switch, used by docker builds or users who might not want to download dbsync binary
######################################
# Do NOT modify code below           #
######################################

unset CNODE_HOME

PARENT="$(dirname $0)"

export LANG="C.UTF-8"
export LC_ALL=${LANG}

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  STYLE_RESET="$(tput sgr0 2>/dev/null || true)"
  STYLE_BOLD="$(tput bold 2>/dev/null || true)"
  STYLE_RED="$(tput setaf 1 2>/dev/null || true)"
  STYLE_GREEN="$(tput setaf 2 2>/dev/null || true)"
  STYLE_YELLOW="$(tput setaf 3 2>/dev/null || true)"
  STYLE_CYAN="$(tput setaf 6 2>/dev/null || true)"
else
  STYLE_RESET=""
  STYLE_BOLD=""
  STYLE_RED=""
  STYLE_GREEN=""
  STYLE_YELLOW=""
  STYLE_CYAN=""
fi

if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" =~ (UTF-8|utf-8|utf8) ]]; then
  SYMBOL_RUN="…"
  SYMBOL_OK="✓"
  SYMBOL_INFO="i"
  SYMBOL_WARN="!"
  SYMBOL_ERROR="✗"
else
  SYMBOL_RUN=".."
  SYMBOL_OK="OK"
  SYMBOL_INFO="i"
  SYMBOL_WARN="!"
  SYMBOL_ERROR="X"
fi

ACTIVE_STEP="Initialize deployment"
ACTIVE_FLAG=""
NO_SELECTIVE_FLAGS="N"
ADDED_LOCAL_BIN_PATH="N"
FRESH_TARGET="N"

log_header() {
  printf "\n%sGuild Operators deployment%s\n" "${STYLE_BOLD}" "${STYLE_RESET}"
  printf "  Target  : %s\n" "${CNODE_HOME}"
  printf "  Network : %s\n" "${NETWORK}"
  printf "  Branch  : %s\n" "${BRANCH}"
  if [[ -n "${S_ARGS}" ]]; then
    printf "  Flags   : -s %s\n" "${S_ARGS}"
  else
    printf "  Flags   : script/config refresh\n"
  fi
}

log_section() {
  printf "\n%s%s%s\n" "${STYLE_CYAN}${STYLE_BOLD}" "${1}" "${STYLE_RESET}"
}

log_progress() {
  ACTIVE_STEP="${1}"
  local detail="${2:-}"
  local line="  ${SYMBOL_RUN} ${1}"
  [[ -n "${detail}" ]] && line="${line} (${detail})"
  if [[ -t 1 ]]; then
    printf "\r\033[K%s" "${line}"
  else
    printf "%s\n" "${line}"
  fi
}

log_ok() {
  local step="${1:-${ACTIVE_STEP}}"
  local detail="${2:-}"
  local line="  ${SYMBOL_OK} ${step}"
  [[ -n "${detail}" ]] && line="${line} (${detail})"
  if [[ -t 1 ]]; then
    printf "\r\033[K%s%s%s\n" "${STYLE_GREEN}" "${line}" "${STYLE_RESET}"
  else
    printf "%s\n" "${line}"
  fi
  ACTIVE_STEP="${step}"
}

log_info() {
  [[ -t 1 ]] && printf "\r\033[K"
  printf "%s  ${SYMBOL_INFO} %s%s\n" "${STYLE_CYAN}" "${1}" "${STYLE_RESET}"
}

log_warn() {
  [[ -t 1 ]] && printf "\r\033[K"
  printf "%s  ${SYMBOL_WARN} %s%s\n" "${STYLE_YELLOW}" "${1}" "${STYLE_RESET}"
}

run_step() {
  local label="${1}"
  local flag="${2}"
  shift 2
  ACTIVE_STEP="${label}"
  ACTIVE_FLAG="${flag}"
  log_section "${label}"
  "$@"
}

get_answer() {
  printf "%s (yes/no): " "$*" >&2; read -r answer
  while :
  do
    case $answer in
    [Yy]*)
      return 0;;
    [Nn]*)
      return 1;;
    *) printf "%s" "Please enter 'yes' or 'no' to continue: " >&2; read -r answer
    esac
  done
}

# Description : Exit with error message
#             : $1 = Error message we'd like to display before exiting.
err_exit() {
  [[ -t 2 ]] && printf "\r\033[K" >&2
  printf "\n%s${SYMBOL_ERROR} Deployment failed%s\n" "${STYLE_RED}" "${STYLE_RESET}" >&2
  [[ -n "${ACTIVE_STEP}" ]] && printf "  Step : %s\n" "${ACTIVE_STEP}" >&2
  [[ -n "${ACTIVE_FLAG}" ]] && printf "  Flag : %s\n" "${ACTIVE_FLAG}" >&2
  printf "  Cause: %s\n" "${1:-Unknown error}" >&2
  pushd -0 >/dev/null && dirs -c
  exit 1
}

usage() {
  cat <<-EOF >&2

		Usage: $(basename "$0") [-n <mainnet|guild|preprod|preview>] [-p path] [-t <name>] [-b <branch>] [-u] [-s [p][b][l][m][d][c][o][w][x][f][s]]
		Set up dependencies for building/using common tools across cardano ecosystem.
		The script will always update dynamic content from existing scripts retaining existing user variables

		-n    Connect to specified network instead of mainnet network (Default: connect to cardano mainnet network) eg: -n guild
		-p    Parent folder path underneath which the top-level folder will be created (Default: /opt/cardano)
		-t    Alternate name for top level folder - only alpha-numeric chars allowed (Default: cnode)
		-b    Use alternate branch of scripts to download - only recommended for testing/development (Default: master)
		-u    Skip update check for script itself
		-s    Selective Install, only deploy specific components as below:
		  p   Install common pre-requisite OS-level Dependencies for most tools on this repo (Default: skip)
		  b   Install OS level dependencies for tools required while building cardano-node/cardano-db-sync components (Default: skip)
		  l   Build and Install libsodium fork from IO repositories (Default: skip)
		  m   Download latest (released) binaries for mithril-signer, mithril-client (Default: skip)
		  d   Download latest (released) binaries for bech32, cardano-address, cardano-node, cardano-cli, cardano-db-sync and cardano-submit-api (Default: skip)
		  c   Download latest (released) binaries for CNCLI (Default: skip)
		  o   Download latest (released) binaries for Ogmios (Default: skip)
		  w   Download latest (released) binaries for Cardano Hardware CLI (Default: skip)
		  x   Download latest (released) binaries for Cardano Signer binary (Default: skip)
		  r   Download and install latest (released) openBlockPerf Network Monitoring (Default: skip)
		  f   Force overwrite config files (backups of existing ones will be created) (Default: skip)
		  s   Force overwrite entire content [including user variables] of scripts (Default: skip)

		EOF
  exit 1
}

# Set Default Environment Variables
set_defaults() {
  [[ -z ${G_ACCOUNT} ]] && G_ACCOUNT="cardano-community"
  [[ -z ${NETWORK} ]] && NETWORK='mainnet'
  [[ -z ${WANT_BUILD_DEPS} ]] && WANT_BUILD_DEPS='N'
  [[ -z ${FORCE_OVERWRITE} ]] && FORCE_OVERWRITE='N'
  [[ -z ${SCRIPTS_FORCE_OVERWRITE} ]] && SCRIPTS_FORCE_OVERWRITE='N'
  [[ -z ${LIBSODIUM_FORK} ]] && LIBSODIUM_FORK='N'
  [[ -z ${INSTALL_MITHRIL} ]] && INSTALL_MITHRIL='N'
  [[ -z ${INSTALL_CNCLI} ]] && INSTALL_CNCLI='N'
  [[ -z ${INSTALL_CWHCLI} ]] && INSTALL_CWHCLI='N'
  [[ -z ${INSTALL_OGMIOS} ]] && INSTALL_OGMIOS='N'
  [[ -z ${INSTALL_CSIGNER} ]] && INSTALL_CSIGNER='N'
  [[ -z ${INSTALL_BLOCKPERF} ]] && INSTALL_BLOCKPERF='N'
  [[ -z ${CNODE_PATH} ]] && CNODE_PATH="/opt/cardano"
  [[ -z ${CNODE_NAME} ]] && CNODE_NAME='cnode'
  [[ -z ${CURL_TIMEOUT} ]] && CURL_TIMEOUT=60
  [[ -z ${UPDATE_CHECK} ]] && UPDATE_CHECK='Y'
  [[ -z ${SKIP_DBSYNC_DOWNLOAD} ]] && SKIP_DBSYNC_DOWNLOAD='N'
  [[ -z ${SUDO} ]] && SUDO='Y'
  [[ -z "${BRANCH}" ]] && BRANCH="master"
  [[ "${SUDO}" = 'Y' ]] && sudo="sudo" || sudo=""
  [[ "${SUDO}" = 'Y' && $(id -u) -eq 0 ]] && err_exit "Please run as non-root user."
  [[ -z "${CARDANO_NODE_VERSION}" ]] && CARDANO_NODE_VERSION="$(curl -sfk "https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${BRANCH}/files/docker/node/release-versions/cardano-node-latest.txt" || echo "10.6.2")"
  [[ -z "${CARDANO_CLI_VERSION}" ]] && CARDANO_CLI_VERSION="$(curl -sfk "https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${BRANCH}/files/docker/node/release-versions/cardano-cli-latest.txt" || echo "10.15.0.1")"
  CNODE_HOME="${CNODE_PATH}/${CNODE_NAME}"
  CNODE_VNAME=$(echo "$CNODE_NAME" | awk '{print toupper($0)}')
  [[ -z ${MITHRIL_HOME} ]] && MITHRIL_HOME="${CNODE_HOME}/mithril"
  REPO_RAW="https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators"
  URL_RAW="${REPO_RAW}/${BRANCH}"
  U_ID=$(id -u)
  G_ID=$(id -g)
  # Determine OS platform
  OS_ID=$(grep -i ^id_like= /etc/os-release | cut -d= -f 2)
  [[ -z "${OS_ID}" ]] && OS_ID=$(grep -i ^id= /etc/os-release | cut -d= -f 2)
  DISTRO=$(grep -i ^NAME= /etc/os-release | cut -d= -f 2)
  VERSION_ID=$(grep -i ^version_id= /etc/os-release | cut -d= -f 2 | tr -d '"' | cut -d. -f 1)
  ARCH=$(uname -a)
  if ! curl -s -f -m ${CURL_TIMEOUT} "${REPO_RAW}/${BRANCH}/LICENSE" -o /dev/null ; then
    log_warn "Branch '${BRANCH}' was not found, falling back to master."
    BRANCH=master
    URL_RAW="${REPO_RAW}/${BRANCH}"
  fi
}

# Check and prompt/apply update for guild-deploy.sh itself
update_check() {
  log_progress "Checking guild-deploy.sh update" "${BRANCH}"
  if ! curl -s -f -m ${CURL_TIMEOUT} -o "${PARENT}"/guild-deploy.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/guild-deploy.sh 2>/dev/null; then
    rm -f "${PARENT}"/guild-deploy.sh.tmp
    log_warn "Could not check guild-deploy.sh update; continuing with the local copy."
    return 0
  fi

  TEMPL_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/guild-deploy.sh)
  TEMPL2_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/guild-deploy.sh.tmp)
  if [[ "$(echo ${TEMPL_CMD} | sha256sum)" != "$(echo ${TEMPL2_CMD} | sha256sum)" ]]; then
    cp "${PARENT}"/guild-deploy.sh "${PARENT}/guild-deploy.sh_bkp$(date +%s)"
    STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/guild-deploy.sh)
    printf '%s\n%s\n' "$STATIC_CMD" "$TEMPL2_CMD" > "${PARENT}"/guild-deploy.sh.tmp
    {
      mv -f "${PARENT}"/guild-deploy.sh.tmp "${PARENT}"/guild-deploy.sh && \
      chmod 755 "${PARENT}"/guild-deploy.sh && \
      log_ok "Updated guild-deploy.sh" "run the script again" && \
      exit 0;
    } || {
      err_exit "Update failed. Please manually download guild-deploy.sh from GitHub."
    }
  fi
  rm -f "${PARENT}"/guild-deploy.sh.tmp
  log_ok "guild-deploy.sh is current"
}

# Initialise all variables
common_init() {
  dirs -c # clear dir stack
  set_defaults
  mkdir -p "${HOME}"/tmp "${HOME}"/git > /dev/null 2>&1
  [[ ! -d "${HOME}"/.local/bin ]] && mkdir -p "${HOME}"/.local/bin
  if ! grep -q '/.local/bin' "${HOME}"/.bashrc; then
    printf '\nexport PATH="${HOME}/.local/bin:${PATH}"\n' >> "${HOME}"/.bashrc
    ADDED_LOCAL_BIN_PATH="Y"
  fi
  NODE_DEPS="$(curl -sfL "${URL_RAW}"/files/node-deps.json)"
}

### Update file retaining existing custom configs
updateWithCustomConfig() {
  file=$1
  [[ $# -ne 2 ]] && subdir="cnode-helper-scripts" || subdir=$2
  ACTIVE_STEP="Refreshing ${file}"
  curl -s -f -m ${CURL_TIMEOUT} -o ${file}.tmp "${URL_RAW}/scripts/${subdir}/${file}"
  [[ ! -f ${file}.tmp ]] && err_exit "Failed to download '${file}' from GitHub"
  if [[ -f ${file} && ${SCRIPTS_FORCE_OVERWRITE} != 'Y' ]]; then
    if grep '^# Do NOT modify' ${file}.tmp >/dev/null 2>&1; then
      TEMPL_CMD=$(awk '/^# Do NOT modify/,0' ${file}.tmp)
      STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' ${file})
      printf '%s\n%s\n' "${STATIC_CMD}" "${TEMPL_CMD}" > ${file}.tmp
    else
      rm -f ${file}.tmp
      err_exit "Problems encountered while fetching \"${file}\" from Github, could be an issue with connectivity or Github site!"
    fi
  fi
  [[ ! -d ./archive ]] && mkdir archive
  [[ -f ${file} ]] && cp -f ${file} ./archive/"${file}_bkp$(date +%s)"
  mv -f ${file}.tmp ${file}
  [[ "${file}" == *.sh ]] && chmod 755 ${file}
}

# Description : Add epel repository when needed
#             : $1 = DISTRO
#             : $2 = Epel repository VERSION_ID
#             : $3 = pkg_opts for repo install
add_epel_repository() {
  if [[ "${1}" =~ Fedora ]]; then return; fi
  log_progress "Enabling EPEL repository"
  ! grep -q ^epel <<< "$(dnf repolist)" && $sudo dnf install ${3} https://dl.fedoraproject.org/pub/epel/epel-release-latest-"${2}".noarch.rpm > /dev/null
  log_ok "EPEL repository ready"
}

# OS Dependencies
os_dependencies() {
  pkg_opts="-y"
  log_info "Preparing OS packages for ${DISTRO}."
  if [[ "${OS_ID}" =~ ebian ]] || [[ "${OS_ID}" =~ buntu ]] || [[ "${DISTRO}" =~ ebian ]] || [[ "${DISTRO}" =~ buntu ]]; then
    #Debian/Ubuntu
    pkgmgrcmd="env NEEDRESTART_MODE=a env DEBIAN_FRONTEND=noninteractive env DEBIAN_PRIORITY=critical apt-get"
    pkg_list="python3 pkg-config systemd tmux git jq libtool bc gnupg libtool iproute2 tcptraceroute sqlite3 bsdmainutils unzip procps xxd"
    if [[ "${LIBSODIUM_FORK}" == "Y" ]] || [[ "${WANT_BUILD_DEPS}" == "Y" ]]; then
      pkg_list="${pkg_list} build-essential make g++ autoconf automake"
    fi
    if [[ "${WANT_BUILD_DEPS}" == "Y" ]]; then
      libncurses_pkg="libncursesw5"
      [[ -f /etc/debian_version ]] && grep -qE '(trixie|13)' /etc/debian_version && libncurses_pkg="libncursesw6"
      [[ "${DISTRO}" =~ Ubuntu && ${VERSION_ID} -ge 26 ]] && libncurses_pkg="libncursesw6"
      pkg_list="${pkg_list} ${libncurses_pkg} libtinfo-dev libnuma-dev libpq-dev liblmdb-dev libsnappy-dev protobuf-compiler liburing-dev libffi-dev libgmp-dev libssl-dev libsystemd-dev zlib1g-dev llvm clang"
    fi
    if [[ "${INSTALL_CWHCLI}" == "Y" ]]; then
      pkg_list="${pkg_list} libusb-1.0-0-dev libudev-dev"
    fi
  elif [[ "${OS_ID}" =~ rhel ]] || [[ "${OS_ID}" =~ fedora ]] || [[ "${DISTRO}" =~ Fedora ]]; then
    #CentOS/RHEL/Fedora/RockyLinux
    pkgmgrcmd="dnf"
    pkg_list="python3 coreutils systemd tmux git jq gnupg2 libtool iproute bc traceroute sqlite util-linux xz unzip procps-ng udev vim-common"
    if [[ "${VERSION_ID}" =~ "8" ]] || [[ "${VERSION_ID}" =~ "9" ]]; then
      #RHEL/CentOS/RockyLinux 8/9
      if ${pkgmgrcmd} install -h  | grep -q "\ --allowerasing"; then pkg_opts="${pkg_opts} --allowerasing"; fi
      if [[ "${DISTRO}" =~ Rocky ]]; then
        #RockyLinux 8/9
        pkg_list="${pkg_list} --enablerepo=devel,crb libusbx ncurses-compat-libs pkgconf-pkg-config"
      elif [[ "${DISTRO}" =~ "Red Hat" ]]; then
        pkg_list="${pkg_list} --enablerepo=codeready-builder-for-rhel-${VERSION_ID/.*/}-x86_64-rpms libusbx ncurses-compat-libs pkgconf-pkg-config"
      fi
    elif [[ "${DISTRO}" =~ Fedora ]]; then
      #Fedora
      if ${pkgmgrcmd} install -h  | grep -q "\ --allowerasing"; then pkg_opts="${pkg_opts} --allowerasing"; fi
      pkg_list="${pkg_list} libusbx ncurses-compat-libs pkgconf-pkg-config"
    fi
    if [[ "${LIBSODIUM_FORK}" == "Y" ]] || [[ "${WANT_BUILD_DEPS}" == "Y" ]]; then
      pkg_list="${pkg_list} make gcc-c++ autoconf automake"
    fi
    if [[ "${WANT_BUILD_DEPS}" == "Y" ]]; then
      pkg_list="${pkg_list} ncurses-libs ncurses-devel openssl-devel systemd-devel llvm clang numactl-devel libffi-devel gmp-devel zlib-devel lmdb-devel lmdb liburing-devel snappy-devel protobuf-compiler"
    fi
    add_epel_repository "${DISTRO}" "${VERSION_ID}" "${pkg_opts}"
  else
    err_exit "No automated OS dependency procedure is available for ${DISTRO}."
  fi
  log_progress "Updating package metadata"
  $sudo ${pkgmgrcmd} update ${pkg_opts} > /dev/null;rc=$?
  if [[ $rc != 0 ]]; then
    err_exit "Package metadata update failed: ${pkgmgrcmd} ${pkg_opts} update"
  fi
  log_ok "Package metadata updated"
  log_progress "Installing prerequisite packages"
  $sudo ${pkgmgrcmd} install ${pkg_opts} ${pkg_list} > /dev/null;rc=$?
  if [[ $rc != 0 ]]; then
    err_exit "Prerequisite package installation failed. Re-run manually to inspect: $sudo ${pkgmgrcmd} install ${pkg_opts} ${pkg_list}"
  fi
  log_ok "Prerequisite packages ready"
  if [[ "${OS_ID}" =~ rhel ]] || [[ "${OS_ID}" =~ fedora ]] || [[ "${DISTRO}" =~ Fedora ]]; then
    if [ -e /usr/lib64/libtinfo.so ] && [ -e /usr/lib64/libtinfo.so.5 ]; then
      log_info "ncurses compatibility symlinks already present."
    else
      log_progress "Updating ncurses compatibility symlinks"
      $sudo ln -s "$(find /usr/lib64/libtinfo.so* | tail -1)" /usr/lib64/libtinfo.so
      $sudo ln -s "$(find /usr/lib64/libtinfo.so* | tail -1)" /usr/lib64/libtinfo.so.5
      log_ok "ncurses compatibility symlinks updated"
    fi
  fi
  log_ok "OS dependencies checked" "${DISTRO}"
}

# Build Dependencies for cabal builds
build_dependencies() {
  log_info "Preparing Haskell toolchain dependencies."
  export BOOTSTRAP_HASKELL_NO_UPGRADE=1
  export BOOTSTRAP_HASKELL_GHC_VERSION=9.6.7
  export BOOTSTRAP_HASKELL_CABAL_VERSION=3.12.1.0
  export GHCUP_SKIP_UPDATE_CHECK=1
  if ! command -v ghcup &>/dev/null; then
    log_progress "Installing ghcup"
    BOOTSTRAP_HASKELL_NONINTERACTIVE=1
    BOOTSTRAP_HASKELL_MINIMAL=1
    BOOTSTRAP_HASKELL_ADJUST_BASHRC=1
    unset BOOTSTRAP_HASKELL_INSTALL_HLS
    export BOOTSTRAP_HASKELL_NONINTERACTIVE BOOTSTRAP_HASKELL_MINIMAL BOOTSTRAP_HASKELL_ADJUST_BASHRC
    curl -s -m ${CURL_TIMEOUT} --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | bash >/dev/null 2>&1
    log_ok "ghcup installed"
  fi
  [[ -f "${HOME}/.ghcup/env" ]] && source "${HOME}/.ghcup/env"
  if ! ghc --version 2>/dev/null | grep -q ${BOOTSTRAP_HASKELL_GHC_VERSION}; then
    log_progress "Updating ghcup metadata"
    ghcup upgrade >/dev/null 2>&1
    log_ok "ghcup metadata updated"
    log_progress "Installing GHC" "v${BOOTSTRAP_HASKELL_GHC_VERSION}"
    # BEGIN TEMPORARY GHCUP DEBUG BLOCK
    # Keep this block noisy while investigating RockyLinux CI stalls during GHC installation.
    # Restore the production command below when replacing this diagnostics block.
    # ghcup install ghc ${BOOTSTRAP_HASKELL_GHC_VERSION} >/dev/null 2>&1 || err_exit "Command failed: ghcup install ghc ${BOOTSTRAP_HASKELL_GHC_VERSION}"
    log_info "ghcup version: $(ghcup --version 2>&1 | head -n 1)"
    ghcup tool-requirements || true
    printf "\n"
    df -h || true
    free -h || true
    env | sort | grep -E '^(BOOTSTRAP_HASKELL|GHCUP|PATH|HOME|LANG|LC_|TERM|SHELL)=' || true

    ghcup_log="${HOME}/ghcup-install-ghc-${BOOTSTRAP_HASKELL_GHC_VERSION}.log"
    ghcup --verbose install ghc "${BOOTSTRAP_HASKELL_GHC_VERSION}" > >(tee "${ghcup_log}") 2>&1 &
    ghcup_pid=$!
    ghcup_start=${SECONDS}
    while kill -0 "${ghcup_pid}" 2>/dev/null; do
      sleep 15
      if kill -0 "${ghcup_pid}" 2>/dev/null; then
        log_info "Still installing GHC v${BOOTSTRAP_HASKELL_GHC_VERSION} ($((SECONDS-ghcup_start))s elapsed)."
        df -h / /root /tmp "${HOME}/.ghcup" 2>/dev/null || df -h || true
        du -sh "${HOME}/.ghcup" "${HOME}/.ghcup/tmp" /tmp 2>/dev/null || true
        if ps -ef --forest >/dev/null 2>&1; then
          ps -ef --forest
        else
          ps -ef 2>/dev/null
        fi | grep -E 'ghcup|ghc|make|configure|install' | grep -v grep || true
        tail -n 30 "${ghcup_log}" || true
      fi
    done
    wait "${ghcup_pid}"
    ghcup_rc=$?
    tail -n 200 "${ghcup_log}" || true
    [[ ${ghcup_rc} -eq 0 ]] || err_exit "Command failed: ghcup install ghc ${BOOTSTRAP_HASKELL_GHC_VERSION}"
    # END TEMPORARY GHCUP DEBUG BLOCK
    ghcup set ghc ${BOOTSTRAP_HASKELL_GHC_VERSION} >/dev/null 2>&1
    log_ok "GHC ready" "v${BOOTSTRAP_HASKELL_GHC_VERSION}"
  fi
  cabal_version=$(cabal --version 2>/dev/null | head -n 1 | cut -d' ' -f3)
  if [[ -z ${cabal_version} || ! ${cabal_version} = "${BOOTSTRAP_HASKELL_CABAL_VERSION}" ]]; then
    if [[ -n ${cabal_version} ]]; then
      log_progress "Removing previous Cabal release"
      ghcup rm cabal ${cabal_version} >/dev/null 2>&1
      log_ok "Previous Cabal release removed"
    fi
    log_progress "Installing Cabal" "v${BOOTSTRAP_HASKELL_CABAL_VERSION}"
    ghcup install cabal ${BOOTSTRAP_HASKELL_CABAL_VERSION} >/dev/null 2>&1 || err_exit "Command failed: ghcup install cabal ${BOOTSTRAP_HASKELL_CABAL_VERSION}"
    log_ok "Cabal ready" "v${BOOTSTRAP_HASKELL_CABAL_VERSION}"
  fi
  build_libsecp
  build_libblst
  log_info "Toolchain ready: GHC v${BOOTSTRAP_HASKELL_GHC_VERSION}, Cabal v${BOOTSTRAP_HASKELL_CABAL_VERSION}."
}

# Build fork of libsodium
build_libsodium() {
  SODIUM_REF="$(jq -r '."'${CARDANO_NODE_VERSION}'".sodium' <<< ${NODE_DEPS} 2>/dev/null)"
  if ! grep -q "/usr/local/lib:\$LD_LIBRARY_PATH" "${HOME}"/.bashrc; then
    printf '\nexport LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH\n' >> "${HOME}"/.bashrc
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
    log_info "Added /usr/local/lib to LD_LIBRARY_PATH in ${HOME}/.bashrc."
  fi
  log_progress "Building libsodium"
  pushd "${HOME}"/git >/dev/null || err_exit "Could not enter build directory: ${HOME}/git"
  [[ ! -d "./libsodium" ]] && git clone https://github.com/intersectmbo/libsodium >/dev/null
  pushd libsodium >/dev/null || err_exit "Could not enter libsodium source directory."
  git fetch >/dev/null 2>&1
  [[ -z "${SODIUM_REF}" || "${SODIUM_REF}" == "null" ]] && SODIUM_REF="dbb48cc"
  git checkout "${SODIUM_REF}" &>/dev/null
  local sodium_log="/tmp/libsodium.log"
  : > "${sodium_log}"
  DO_NOT_UPDATE_CONFIG_SCRIPTS=1 ./autogen.sh >> "${sodium_log}" 2>&1 || { cat "${sodium_log}"; err_exit "Could not prepare libsodium build files. See ${sodium_log} for details."; }
  ./configure >> "${sodium_log}" 2>&1 || { cat "${sodium_log}"; err_exit "Could not configure libsodium. See ${sodium_log} for details."; }
  make >> "${sodium_log}" 2>&1 || { cat "${sodium_log}"; err_exit "Could not complete make for libsodium. See ${sodium_log} for details."; }
  $sudo make install >> "${sodium_log}" 2>&1 || { cat "${sodium_log}"; err_exit "Could not install libsodium. See ${sodium_log} for details."; }
  command -v pkg-config >/dev/null 2>&1 || err_exit "libsodium installed, but pkg-config is not available to verify it."
  export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  pkg-config --exists libsodium || { pkg-config --list-all | grep -i sodium || true; err_exit "libsodium installed, but pkg-config metadata was not found."; }
  local sodium_version sodium_detail
  sodium_version="$(pkg-config --modversion libsodium 2>/dev/null || true)"
  sodium_detail="${SODIUM_REF}"
  [[ -n "${sodium_version}" ]] && sodium_detail="${sodium_detail}, ${sodium_version}"
  log_ok "libsodium installed" "${sodium_detail}"
}

build_libsecp() {
  SECP256K1_REF="$(jq -r '."'${CARDANO_NODE_VERSION}'".secp256k1' <<< ${NODE_DEPS} 2>/dev/null)"
  log_progress "Building libsecp256k1"
  pushd "${HOME}"/git >/dev/null || err_exit "Could not enter build directory: ${HOME}/git"
  [[ ! -d "./secp256k1" ]] && git clone https://github.com/bitcoin-core/secp256k1 &>/dev/null
  pushd secp256k1 >/dev/null || err_exit "Could not enter libsecp256k1 source directory."
  git fetch >/dev/null 2>&1
  [[ -z "${SECP256K1_REF}" || "${SECP256K1_REF}" == "null" ]] && SECP256K1_REF="ac83be33"
  git checkout ${SECP256K1_REF} &>/dev/null
  ./autogen.sh > autogen.log > /tmp/secp256k1.log 2>&1
  ./configure --enable-module-schnorrsig --enable-experimental > configure.log >> /tmp/secp256k1.log 2>&1
  make > make.log 2>&1 || err_exit "Could not complete make for libsecp256k1. See make.log for details."
  make check >>make.log 2>&1
  $sudo make install > install.log 2>&1
  if ! grep -q "/usr/local/lib:\$LD_LIBRARY_PATH" "${HOME}"/.bashrc; then
    printf '\nexport LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH\n' >> "${HOME}"/.bashrc
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
    log_info "Added /usr/local/lib to LD_LIBRARY_PATH in ${HOME}/.bashrc."
  fi
  log_ok "libsecp256k1 installed" "${SECP256K1_REF}"
}

build_libblst() {
  BLST_REF="$(jq -r '."'${CARDANO_NODE_VERSION}'".blst' <<< ${NODE_DEPS} 2>/dev/null)"
  if ! grep -q "/usr/local/lib:\$LD_LIBRARY_PATH" "${HOME}"/.bashrc; then
    printf '\nexport LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH\n' >> "${HOME}"/.bashrc
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
    log_info "Added /usr/local/lib to LD_LIBRARY_PATH in ${HOME}/.bashrc."
  fi
  log_progress "Building BLST"
  pushd "${HOME}"/git >/dev/null || err_exit "Could not enter build directory: ${HOME}/git"
  [[ ! -d "./blst" ]] && git clone https://github.com/supranational/blst &>/dev/null
  pushd blst >/dev/null || err_exit "Could not enter BLST source directory."
  git fetch >/dev/null 2>&1
  [[ -z "${BLST_REF}" || "${BLST_REF}" == "null" ]] && BLST_REF="v0.3.14"
  git checkout ${BLST_REF} &>/dev/null
  ./build.sh >/dev/null 2>&1
  cat <<-EOF >libblst.pc
		prefix=/usr/local
		exec_prefix=\${prefix}
		libdir=\${exec_prefix}/lib
		includedir=\${prefix}/include

		Name: libblst
		Description: Multilingual BLS12-381 signature library
		URL: https://github.com/supranational/blst
		Version: 0.3.14
		Cflags: -I\${includedir}
		Libs: -L\${libdir} -lblst
		EOF
  [[ ! -d /usr/local/lib/pkgconfig ]] && $sudo mkdir -p /usr/local/lib/pkgconfig
  $sudo cp -f libblst.pc /usr/local/lib/pkgconfig/
  $sudo cp bindings/blst_aux.h bindings/blst.h bindings/blst.hpp  /usr/local/include/
  $sudo cp libblst.a /usr/local/lib
  $sudo chmod u=rw,go=r /usr/local/{lib/{libblst.a,pkgconfig/libblst.pc},include/{blst.{h,hpp},blst_aux.h}}
  log_ok "BLST installed" "${BLST_REF}"
}

# Download cardano-node, cardano-cli, cardano-db-sync, bech32 and cardano-submit-api
# TODO: Replace these with self-hosted ones (potentially consider snapshots.koios.rest as upload destination for CI)
download_cnodebins() {
  pushd "${HOME}"/tmp >/dev/null || err_exit "Could not enter temporary directory: ${HOME}/tmp"
  log_progress "Downloading cardano-node" "${CARDANO_NODE_VERSION}"
  rm -f cardano-node cardano-address
  [[ -z ${ARCH##*aarch64*} ]] && node_arch="arm64" || node_arch="amd64"
  curl -m 200 -sfL "https://github.com/intersectmbo/cardano-node/releases/download/${CARDANO_NODE_VERSION}/cardano-node-${CARDANO_NODE_VERSION}-linux-${node_arch}.tar.gz" -o cnode.tar.gz || err_exit "Could not download cardano-node release ${CARDANO_NODE_VERSION} from GitHub."
  tar zxf cnode.tar.gz --strip-components 2 ./bin/cardano-node ./bin/cardano-submit-api ./bin/bech32 ./bin/snapshot-converter &>/dev/null
  rm -f cnode.tar.gz
  [[ -f cardano-node ]] || err_exit "cardano-node archive downloaded, but binary 'cardano-node' was not found after extraction."
  [[ -f cardano-submit-api ]] || err_exit "cardano-node archive downloaded, but binary 'cardano-submit-api' was not found after extraction."
  [[ -f bech32 ]] || err_exit "cardano-node archive downloaded, but binary 'bech32' was not found after extraction."
  log_progress "Downloading cardano-cli" "${CARDANO_CLI_VERSION}"
  [[ -z ${ARCH##*aarch64*} ]] && cli_arch="aarch64" || cli_arch="x86_64"
  curl -m 200 -sfL "https://github.com/IntersectMBO/cardano-cli/releases/download/cardano-cli-${CARDANO_CLI_VERSION}/cardano-cli-${CARDANO_CLI_VERSION}-${cli_arch}-linux.tar.gz" -o ccli.tar.gz || err_exit "Could not download cardano-cli release ${CARDANO_CLI_VERSION} from GitHub."
  tar zxf ccli.tar.gz --strip-components 0 cardano-cli-${cli_arch}-linux &>/dev/null && mv cardano-cli-${cli_arch}-linux cardano-cli
  rm -f ccli.tar.gz
  [[ -f cardano-cli ]] || err_exit "cardano-cli archive downloaded, but binary 'cardano-cli' was not found after extraction."
  log_progress "Downloading cardano-address" "4.0.2"
  [[ -n ${ARCH##*arch64*} ]] && curl -m 200 -sfL https://github.com/intersectmbo/cardano-addresses/releases/download/4.0.2/cardano-address-4.0.2-linux.tar.gz -o caddress.tar.gz || err_exit "Could not download cardano-address release 4.0.2 from GitHub."
  tar zxf caddress.tar.gz --transform='s#.*\/##g' --wildcards */cardano-address &>/dev/null
  rm -f caddress.tar.gz
  [[ -f cardano-address ]] || err_exit "cardano-address archive downloaded, but binary 'cardano-address' was not found after extraction."
  if [[ "${SKIP_DBSYNC_DOWNLOAD}" == "N" ]]; then
    log_progress "Downloading cardano-db-sync" "13.7.1.0"
    curl -m 200 -sfL "https://share.koios.rest/api/public/dl/xFdZDfM4/bin/cardano-db-sync-13.7.1.0-$(uname -m).tar.gz" -o cnodedbsync.tar.gz || err_exit "Could not download cardano-db-sync release 13.7.1.0."
    tar zxf cnodedbsync.tar.gz --strip-components 1 ./cardano-db-sync ./cardano-db-tool &>/dev/null
    [[ -f cardano-db-sync ]] || err_exit "cardano-db-sync archive downloaded, but binary 'cardano-db-sync' was not found after extraction."
    rm -f cnodedbsync.tar.gz
    mv -f -t "${HOME}"/.local/bin cardano-db-sync
    log_ok "Deployed cardano-db-sync" "13.7.1.0"
  else
    log_info "Skipped cardano-db-sync binary download."
  fi
  mv -f -t "${HOME}"/.local/bin cardano-node cardano-cli cardano-submit-api bech32 cardano-address
  chmod +x "${HOME}"/.local/bin/*
  log_ok "Deployed cardano-node" "${CARDANO_NODE_VERSION}"
  log_ok "Deployed cardano-cli" "${CARDANO_CLI_VERSION}"
  log_ok "Deployed cardano-submit-api" "${CARDANO_NODE_VERSION}"
  log_ok "Deployed bech32" "${CARDANO_NODE_VERSION}"
  log_ok "Deployed cardano-address" "4.0.2"
}

# Download CNCLI
download_cncli() {
  [[ -z ${ARCH##*aarch64*} ]] && err_exit "The CNCLI pre-compiled binary is not available for ARM; build it manually instead."
  log_progress "Resolving CNCLI release"
  cncli_git_version="$(curl -s https://api.github.com/repos/cardano-community/cncli/releases/latest | jq -r '.tag_name' 2>/dev/null)"
  [[ -n "${cncli_git_version}" && "${cncli_git_version}" != "null" ]] || err_exit "Could not resolve CNCLI release from GitHub."
  log_progress "Downloading CNCLI" "${cncli_git_version}"
  rm -rf /tmp/cncli-bin && mkdir /tmp/cncli-bin
  pushd /tmp/cncli-bin >/dev/null || err_exit "Could not enter temporary CNCLI directory."
  cncli_asset_url="$(curl -s https://api.github.com/repos/cardano-community/cncli/releases/latest | jq -r '.assets[].browser_download_url' 2>/dev/null | grep 'ubuntu22.*.linux-musl.tar.gz')"
  [[ -n "${cncli_asset_url}" ]] || err_exit "No CNCLI Linux release asset was found for this installer."
  if curl -sL -f -m ${CURL_TIMEOUT} -o cncli.tar.gz ${cncli_asset_url}; then
    tar zxf cncli.tar.gz &>/dev/null
    rm -f cncli.tar.gz
    [[ -f cncli ]] || err_exit "CNCLI downloaded but binary (cncli) not found after extracting package!"
    chmod +x /tmp/cncli-bin/cncli
    mv -f /tmp/cncli-bin/cncli "${HOME}"/.local/bin/
    rm -f "${HOME}"/.cargo/bin/cncli # Remove duplicate file in $PATH (old convention)
    log_ok "Deployed CNCLI" "${cncli_git_version}"
  else
    err_exit "Download of latest release of CNCLI from GitHub failed! Please retry or install it manually."
  fi
}

# Download pre-build cardano-hw-cli binary and it's dependencies
download_cardanohwcli() {
  [[ -z ${ARCH##*aarch64*} ]] && err_exit "The cardano-hw-cli pre-compiled binary is not available for ARM; build it manually instead."
  log_progress "Resolving cardano-hw-cli release"
  rm -rf /tmp/chwcli-bin && mkdir -p /tmp/chwcli-bin
  pushd /tmp/chwcli-bin >/dev/null || err_exit "Could not enter temporary cardano-hw-cli directory."
  rm -rf cardano-hw-cli*
  vchc_release_json="$(curl -s https://api.github.com/repos/vacuumlabs/cardano-hw-cli/releases)"
  vchc_git_version="$(jq -r '.[0].tag_name' <<< "${vchc_release_json}" 2>/dev/null)"
  [[ -n "${vchc_git_version}" && "${vchc_git_version}" != "null" ]] || err_exit "Could not resolve cardano-hw-cli release from GitHub."
  #vchc_asset_url="$(curl -s https://api.github.com/repos/vacuumlabs/cardano-hw-cli/releases/latest | jq -r '.assets[].browser_download_url' | grep '_linux-x64.tar.gz')"
  vchc_asset_url="$(jq -r '.[0].assets[].browser_download_url' <<< "${vchc_release_json}" 2>/dev/null | grep '_linux-x64.tar.gz')"
  [[ -n "${vchc_asset_url}" ]] || err_exit "No cardano-hw-cli Linux x64 release asset was found."
  log_progress "Downloading cardano-hw-cli" "${vchc_git_version}"
  if curl -sL -f -m ${CURL_TIMEOUT} -o cardano-hw-cli_linux-x64.tar.gz ${vchc_asset_url}; then
    tar zxf cardano-hw-cli_linux-x64.tar.gz &>/dev/null
    rm -f cardano-hw-cli_linux-x64.tar.gz
    [[ -f cardano-hw-cli/cardano-hw-cli ]] || err_exit "cardano-hw-cli downloaded but binary not found after extracting package!"
    mkdir -p "${HOME}"/.local/bin
    rm -rf "${HOME}"/bin/cardano-hw-cli # Remove duplicate file in $PATH (old convention)
    if [ -f "${HOME}"/.local/bin/cardano-hw-cli ]; then
      rm -rf "${HOME}"/.local/bin/cardano-hw-cli
    fi
    pushd "${HOME}"/.local/bin >/dev/null || err_exit "Could not enter binary directory: ${HOME}/.local/bin"
    mv -f /tmp/chwcli-bin/cardano-hw-cli/* ./
    if [[ ! -f "/etc/udev/rules.d/20-hw1.rules" ]]; then
      # Ledger udev rules
      curl -s -f -m ${CURL_TIMEOUT} https://raw.githubusercontent.com/LedgerHQ/udev-rules/master/add_udev_rules.sh | $sudo bash >/dev/null 2>&1
      $sudo sed -e "s@TAG+=\"uaccess\"@OWNER=\"$USER\", TAG+=\"uaccess\"@g" -i /etc/udev/rules.d/20-hw1.rules
      log_info "Installed Ledger udev rules."
    fi
    if [[ ! -f "/etc/udev/rules.d/51-trezor.rules" ]]; then
      # Trezor udev rules
      $sudo curl -s -f -m ${CURL_TIMEOUT} https://data.trezor.io/udev/51-trezor.rules -o /etc/udev/rules.d/51-trezor.rules
      $sudo sed -e "s@TAG+=\"uaccess\"@OWNER=\"$USER\", TAG+=\"uaccess\"@g" -i /etc/udev/rules.d/51-trezor.rules
      log_info "Installed Trezor udev rules."
    fi
    # Trigger rules update
    $sudo udevadm control --reload-rules >/dev/null 2>&1
    $sudo udevadm trigger >/dev/null 2>&1
    log_ok "Deployed cardano-hw-cli" "${vchc_git_version}"
  else
    err_exit "Download of latest release of cardano-hw-cli from GitHub failed! Please retry or manually install it."
  fi
}

# Download pre-built ogmios binary
download_ogmios() {
  [[ -z ${ARCH##*aarch64*} ]] && err_exit "The Ogmios pre-compiled binary is not available for ARM; build it manually instead."
  local OGMIOSPATH=""
  log_progress "Resolving Ogmios release"
  rm -rf /tmp/ogmios && mkdir /tmp/ogmios
  pushd /tmp/ogmios >/dev/null || err_exit "Could not enter temporary Ogmios directory."
  ogmios_release_json="$(curl -s https://api.github.com/repos/IntersectMBO/ogmios/releases)"
  ogmios_git_version="$(jq -r '.[0].tag_name' <<< "${ogmios_release_json}" 2>/dev/null)"
  [[ -n "${ogmios_git_version}" && "${ogmios_git_version}" != "null" ]] || err_exit "Could not resolve Ogmios release from GitHub."
  ogmios_asset_url="$(jq -r '.[].assets[].browser_download_url' <<< "${ogmios_release_json}" 2>/dev/null | grep x86_64-linux.tar.gz | head -1)"
  [[ -n "${ogmios_asset_url}" ]] || err_exit "No Ogmios Linux x86_64 release asset was found."
  log_progress "Downloading Ogmios" "${ogmios_git_version}"
  if curl -sL -f -m ${CURL_TIMEOUT} -o ogmios.tar.gz ${ogmios_asset_url}; then
    tar -xf ogmios.tar.gz &>/dev/null
    rm -f ogmios.tar.gz
    [[ -f bin/ogmios ]] && OGMIOSPATH=bin/ogmios
    [[ -f ogmios ]] && OGMIOSPATH=ogmios
    [[ -n ${OGMIOSPATH} ]] || err_exit "ogmios downloaded but binary not found after extracting package!"
    chmod +x /tmp/ogmios/${OGMIOSPATH}
    mv -f /tmp/ogmios/${OGMIOSPATH} "${HOME}"/.local/bin/
    rm -f "${HOME}"/.cabal/bin/ogmios # Remove duplicate from $PATH
    log_ok "Deployed Ogmios" "${ogmios_git_version}"
  else
    err_exit "Download of latest release of ogmios archive from GitHub failed! Please retry or manually install it."
  fi
}

# Download pre-built cardano-signer binary
download_cardanosigner() {
  [[ -z ${ARCH##*aarch64*} ]] && err_exit "The cardano-signer pre-compiled binary is not available for ARM; build it manually instead."
  log_progress "Resolving Cardano Signer release"
  csigner_git_version="$(curl -s https://api.github.com/repos/gitmachtl/cardano-signer/releases/latest | jq -r '.tag_name' 2>/dev/null)"
  [[ -n "${csigner_git_version}" && "${csigner_git_version}" != "null" ]] || err_exit "Could not resolve Cardano Signer release from GitHub."
  rm -rf /tmp/csigner && mkdir /tmp/csigner
  pushd /tmp/csigner >/dev/null || err_exit "Could not enter temporary Cardano Signer directory."
  csigner_asset_url="$(curl -s https://api.github.com/repos/gitmachtl/cardano-signer/releases/latest | jq -r '.assets[].browser_download_url' 2>/dev/null)"
  [[ -n "${csigner_asset_url}" ]] || err_exit "No Cardano Signer release assets were found."
  csigner_release_url=""
  while IFS= read -r release; do
    if [[ -z ${ARCH##*x86_64*} && ${release} = *linux-x64.tar.gz ]]; then # Linux x64
      csigner_release_url=${release}; break
    fi
  done <<< "${csigner_asset_url}"
  if [[ -n ${csigner_release_url} ]]; then
    log_progress "Downloading Cardano Signer" "${csigner_git_version}"
    if curl -sL -f -m ${CURL_TIMEOUT} -o csigner.tar.gz ${csigner_release_url}; then
      tar zxf csigner.tar.gz &>/dev/null
      rm -f csigner.tar.gz
      [[ -f cardano-signer ]] || err_exit "Cardano Signer downloaded but binary(cardano-signer) not found after extracting package!"
      chmod +x /tmp/csigner/cardano-signer
      mv -f /tmp/csigner/cardano-signer "${HOME}"/.local/bin/
      rm -f "${HOME}"/.cabal/bin/cardano-signer # Remove duplicate from $PATH
      log_ok "Deployed Cardano Signer" "${csigner_git_version}"
    else
      err_exit "Download of latest release of Cardano Signer archive from GitHub failed! Please retry or install it manually."
    fi
  else
    err_exit "Unsupported system, no cardano-signer release found matching system architecture."
  fi
}

# Download and execute openBlockPerf installer
download_blockperf() {
  local installer_dir blockperf_installer blockperf_installer_url branch_installer_url
  local -a blockperf_common_args=(--yes --api-key-mode relay --node-unit-name "${CNODE_NAME}" --network "${NETWORK}")
  local before_hash after_hash blockperf_mode="install" rc attempt=1 max_attempts=3

  log_info "Preparing openBlockPerf installer."

  # Use cntools scripts path when available; fallback to ~/tmp for non-cntools environments.
  if [[ -n "${CNODE_HOME}" && -d "${CNODE_HOME}/scripts" ]]; then
    installer_dir="${CNODE_HOME}/scripts"
  else
    installer_dir="${HOME}/tmp"
    mkdir -p "${installer_dir}" || err_exit "Failed to create installer directory: ${installer_dir}"
  fi
  blockperf_installer="${installer_dir}/blockperf-install.sh"
  blockperf_installer_url="https://raw.githubusercontent.com/cardano-foundation/openblockperf/main/blockperf-install.sh"

  # If guild-deploy branch exists in openblockperf repo, use installer from that branch.
  if [[ -n "${BRANCH}" ]]; then
    branch_installer_url="https://raw.githubusercontent.com/cardano-foundation/openblockperf/${BRANCH}/blockperf-install.sh"
    if curl -s -f -m ${CURL_TIMEOUT} -I "${branch_installer_url}" >/dev/null 2>&1; then
      blockperf_installer_url="${branch_installer_url}"
    fi
  fi

  pushd "${installer_dir}" >/dev/null || err_exit "Could not enter openBlockPerf installer directory: ${installer_dir}"

  if [[ ! -f "${blockperf_installer}" ]]; then
    log_progress "Downloading openBlockPerf installer" "${blockperf_installer_url}"
    curl -fsSL -m ${CURL_TIMEOUT} "${blockperf_installer_url}" -o "${blockperf_installer}" || err_exit "Download of openBlockPerf installer failed! Please retry or install it manually."
  else
    blockperf_mode="update"
    log_info "Using existing openBlockPerf installer at ${blockperf_installer}."
  fi

  chmod +x "${blockperf_installer}" || err_exit "Failed setting executable bit on openBlockPerf installer."

  while (( attempt <= max_attempts )); do
    before_hash="$(sha256sum "${blockperf_installer}" 2>/dev/null | awk '{print $1}')"
    log_progress "Running openBlockPerf installer" "${blockperf_mode}"
    [[ -t 1 ]] && printf "\n"
    if [[ "${blockperf_mode}" == "update" ]]; then
      $sudo "${blockperf_installer}" --update "${blockperf_common_args[@]}"
    else
      $sudo "${blockperf_installer}" "${blockperf_common_args[@]}"
    fi
    rc=$?
    after_hash="$(sha256sum "${blockperf_installer}" 2>/dev/null | awk '{print $1}')"

    if [[ ${rc} -eq 0 ]]; then
      log_ok "Deployed openBlockPerf" "${blockperf_mode}"
      return 0
    fi

    # If the installer self-updated, run it again with --update.
    if [[ -n "${before_hash}" && -n "${after_hash}" && "${before_hash}" != "${after_hash}" ]]; then
      log_info "openBlockPerf installer self-updated; running the updated installer."
      blockperf_mode="update"
      ((attempt++))
      continue
    fi

    err_exit "openBlockPerf installer failed with exit code ${rc}."
  done

  err_exit "openBlockPerf installer kept updating itself but did not complete after ${max_attempts} attempts."
}

# Download pre-built mithril-signer binary
download_mithril() {
    pushd "${HOME}"/tmp >/dev/null || err_exit "Could not enter temporary directory: ${HOME}/tmp"
    log_progress "Resolving Mithril release"
    mithril_release="$(curl -s https://api.github.com/repos/input-output-hk/mithril/releases/latest | jq -r '.tag_name' 2>/dev/null)"
    [[ -n "${mithril_release}" && "${mithril_release}" != "null" ]] || err_exit "Could not resolve Mithril release from GitHub."
    log_progress "Downloading Mithril signer/client" "${mithril_release}"
    rm -f mithril-signer mithril-client
    curl -m 200 -sfL https://github.com/input-output-hk/mithril/releases/download/${mithril_release}/mithril-${mithril_release}-linux-x64.tar.gz -o mithril.tar.gz || err_exit "Could not download Mithril release ${mithril_release} from GitHub."
    tar zxf mithril.tar.gz mithril-signer mithril-client &>/dev/null
    rm -f mithril.tar.gz
    [[ -f mithril-signer ]] || err_exit "Mithril archive downloaded, but binary 'mithril-signer' was not found after extraction."
    [[ -f mithril-client ]] || err_exit "Mithril archive downloaded, but binary 'mithril-client' was not found after extraction."
    mv -t "${HOME}"/.local/bin mithril-signer mithril-client
    chmod +x "${HOME}"/.local/bin/*
    log_ok "Deployed mithril-signer" "${mithril_release}"
    log_ok "Deployed mithril-client" "${mithril_release}"
}

# Create folder structure and set up permissions/ownerships
setup_folder() {
  log_progress "Creating folder structure" "${CNODE_HOME}"

  if grep -q "export ${CNODE_VNAME}_HOME=" "${HOME}"/.bashrc; then
    log_info "${CNODE_VNAME}_HOME already present in ${HOME}/.bashrc."
  else
    printf '\nexport %s_HOME=%s\n' "${CNODE_VNAME}" "${CNODE_HOME}" >> "${HOME}"/.bashrc
    log_info "Added ${CNODE_VNAME}_HOME=${CNODE_HOME} to ${HOME}/.bashrc."
  fi

  $sudo mkdir -p "${CNODE_HOME}"/files "${CNODE_HOME}"/db "${CNODE_HOME}"/guild-db "${CNODE_HOME}"/logs "${CNODE_HOME}"/scripts "${CNODE_HOME}"/scripts/archive "${CNODE_HOME}"/sockets "${CNODE_HOME}"/priv "${MITHRIL_HOME}"/data-stores
  $sudo chown -R "$U_ID":"$G_ID" "${CNODE_HOME}" 2>/dev/null
  log_ok "Folder structure ready" "${CNODE_HOME}"

}

# Download and update scripts for cnode
populate_cnode() {
  [[ ! -d "${CNODE_HOME}"/files ]] && setup_folder
  log_progress "Downloading network configuration" "${NETWORK}"
  pushd "${CNODE_HOME}"/files >/dev/null || err_exit "Could not enter files directory: ${CNODE_HOME}/files"
  echo "${BRANCH}" > "${CNODE_HOME}"/scripts/.env_branch

  local err_msg="Could not download network configuration file:"
  # Download node config, genesis and topology from template
  #NWCONFURL="https://raw.githubusercontent.com/input-output-hk/cardano-playground/main/static/book.play.dev.cardano.org/environments"
  NWCONFURL="${URL_RAW}/files/configs/${NETWORK}/"
  #CHKPTURL="https://book.play.dev.cardano.org/environments/${NETWORK}/checkpoints.json"
  if [[ ${NETWORK} =~ ^(mainnet|preprod|preview|guild)$ ]]; then
    curl -sL -f -m ${CURL_TIMEOUT} -o alonzo-genesis.json.tmp "${NWCONFURL}/alonzo-genesis.json" || err_exit "${err_msg} alonzo-genesis.json"
    curl -sL -f -m ${CURL_TIMEOUT} -o byron-genesis.json.tmp "${NWCONFURL}/byron-genesis.json" || err_exit "${err_msg} byron-genesis.json"
    curl -sL -f -m ${CURL_TIMEOUT} -o conway-genesis.json.tmp "${NWCONFURL}/conway-genesis.json" || err_exit "${err_msg} conway-genesis.json"
    curl -sL -f -m ${CURL_TIMEOUT} -o shelley-genesis.json.tmp "${NWCONFURL}/shelley-genesis.json" || err_exit "${err_msg} shelley-genesis.json"
    curl -sL -f -m ${CURL_TIMEOUT} -o topology.json.tmp "${NWCONFURL}/topology.json" || err_exit "${err_msg} topology.json"
    curl -sL -f -m ${CURL_TIMEOUT} -o config.json.tmp "${NWCONFURL}/config.json" || err_exit "${err_msg} config.json"
    curl -sL -f -m ${CURL_TIMEOUT} -o dbsync.json.tmp "${NWCONFURL}/db-sync-config.json" || err_exit "${err_msg} dbsync-sync-config.json"
    curl -sL -f -m ${CURL_TIMEOUT} -o submitapi.json "${NWCONFURL}/submitapi.json" || err_exit "${err_msg} submitapi.json"
    #curl -sL -m ${CURL_TIMEOUT} -o checkpoints.json "${CHKPTURL}" || err_exit "${err_msg} checkpoints.json"
  else
    err_exit "Unknown network specified! Kindly re-check the network name, valid options are: mainnet, guild, preprod, or preview."
  fi
  log_ok "Network configuration downloaded" "${NETWORK}"
  sed -e "s@/opt/cardano/cnode@${CNODE_HOME}@g" -i ./*.json.tmp
  sed -e "s@\"TraceOptionNodeName\": \"cnode\"@\"TraceOptionNodeName\": \"${CNODE_NAME}\"@" -i ./config.json.tmp
  if [[ ${FORCE_OVERWRITE} = 'Y' ]]; then
    [[ -f topology.json ]] && cp -f topology.json "topology.json_bkp$(date +%s)"
    [[ -f config.json ]] && cp -f config.json "config.json_bkp$(date +%s)"
    [[ -f dbsync.json ]] && cp -f dbsync.json "dbsync.json_bkp$(date +%s)"
    log_info "Backed up existing topology/config/dbsync files before overwrite."
  fi
  log_progress "Applying network configuration" "${NETWORK}"
  if [[ ${FORCE_OVERWRITE} = 'Y' || ! -f byron-genesis.json || ! -f shelley-genesis.json || ! -f alonzo-genesis.json || ! -f topology.json || ! -f config.json || ! -f dbsync.json ]]; then
    mv -f byron-genesis.json.tmp byron-genesis.json
    mv -f shelley-genesis.json.tmp shelley-genesis.json
    mv -f alonzo-genesis.json.tmp alonzo-genesis.json
    mv -f conway-genesis.json.tmp conway-genesis.json
    mv -f topology.json.tmp topology.json
    mv -f config.json.tmp config.json
    mv -f dbsync.json.tmp dbsync.json
  else
    rm -f byron-genesis.json.tmp
    rm -f shelley-genesis.json.tmp
    rm -f alonzo-genesis.json.tmp
    rm -f conway-genesis.json.tmp
    rm -f topology.json.tmp
    rm -f config.json.tmp
    rm -f dbsync.json.tmp
  fi
  log_ok "Network configuration ready" "${NETWORK}"

  pushd "${CNODE_HOME}"/scripts >/dev/null || err_exit "Could not enter scripts directory: ${CNODE_HOME}/scripts"

  [[ ${SCRIPTS_FORCE_OVERWRITE} = 'Y' ]] && log_warn "Script force overwrite enabled; review user variables in refreshed scripts and configs."

  log_progress "Refreshing helper scripts" "${BRANCH}"
  #updateWithCustomConfig "blockPerf.sh"
  updateWithCustomConfig "cabal-build-all.sh"
  updateWithCustomConfig "cncli.sh"
  updateWithCustomConfig "cnode.sh"
  updateWithCustomConfig "cntools.sh"
  updateWithCustomConfig "cntools.library"
  updateWithCustomConfig "dbsync.sh"
  updateWithCustomConfig "deploy-as-systemd.sh"
  updateWithCustomConfig "env"
  updateWithCustomConfig "gLiveView.sh"
  #updateWithCustomConfig "logMonitor.sh"
  updateWithCustomConfig "ogmios.sh"
  updateWithCustomConfig "submitapi.sh"
  updateWithCustomConfig "setup_mon.sh"
  updateWithCustomConfig "setup-grest.sh" "grest-helper-scripts"
  updateWithCustomConfig "mithril-client.sh"
  updateWithCustomConfig "mithril-relay.sh"
  updateWithCustomConfig "mithril-signer.sh"
  updateWithCustomConfig "mithril.library"

  find "${CNODE_HOME}/scripts" -name '*.sh' -exec chmod 755 {} \; 2>/dev/null
  chmod 750 "${CNODE_HOME}"/priv 2>/dev/null
  log_ok "Helper scripts refreshed" "${BRANCH}"
}

# Parse arguments supplied to script
parse_args() {
  POPULATE_CNODE="Y"
  if [[ -n "${S_ARGS}" ]]; then
    [[ "${S_ARGS}" =~ "p" ]] && INSTALL_OS_DEPS="Y"
    [[ "${S_ARGS}" =~ "b" ]] && INSTALL_OS_DEPS="Y" && WANT_BUILD_DEPS="Y"
    [[ "${S_ARGS}" =~ "l" ]] && INSTALL_OS_DEPS="Y" && LIBSODIUM_FORK="Y"
    [[ "${S_ARGS}" =~ "m" ]] && INSTALL_MITHRIL="Y"
    [[ "${S_ARGS}" =~ "f" ]] && FORCE_OVERWRITE="Y" && POPULATE_CNODE="Y"
    [[ "${S_ARGS}" =~ "s" ]] && SCRIPTS_FORCE_OVERWRITE="Y" && POPULATE_CNODE="Y"
    [[ "${S_ARGS}" =~ "d" ]] && INSTALL_CNODEBINS="Y"
    [[ "${S_ARGS}" =~ "c" ]] && INSTALL_CNCLI="Y"
    [[ "${S_ARGS}" =~ "o" ]] && INSTALL_OGMIOS="Y"
    [[ "${S_ARGS}" =~ "w" ]] && INSTALL_OS_DEPS="Y" && INSTALL_CWHCLI="Y"
    [[ "${S_ARGS}" =~ "x" ]] && INSTALL_CARDANO_SIGNER="Y"
    [[ "${S_ARGS}" =~ "r" ]] && INSTALL_BLOCKPERF="Y"
  else
    NO_SELECTIVE_FLAGS="Y"
  fi
  common_init
  if [[ ! -d "${CNODE_HOME}"/files ]]; then
    # Guess this is a fresh machine and set minimal params
    INSTALL_OS_DEPS="Y"
    FRESH_TARGET="Y"
  fi
}

# Main Flow for calling different functions
main_flow() {
  [[ "${NO_SELECTIVE_FLAGS}" == "Y" ]] && log_info "No selective install flags supplied; refreshing scripts and configuration only."
  [[ "${ADDED_LOCAL_BIN_PATH}" == "Y" ]] && log_info "Added ${HOME}/.local/bin to PATH in ${HOME}/.bashrc."
  [[ "${FRESH_TARGET}" == "Y" ]] && log_info "Fresh target detected; OS dependency check enabled."
  [[ "${UPDATE_CHECK}" == "Y" ]] && run_step "Deployment script update check" "default" update_check
  [[ "${INSTALL_OS_DEPS}" == "Y" ]] && run_step "OS dependencies" "auto/-s p/b/l/w" os_dependencies
  [[ "${WANT_BUILD_DEPS}" == "Y" ]] && run_step "Haskell build toolchain" "-s b" build_dependencies
  [[ "${LIBSODIUM_FORK}" == "Y" ]] && run_step "libsodium" "-s l" build_libsodium
  [[ "${INSTALL_MITHRIL}" == "Y" ]] && run_step "Mithril binaries" "-s m" download_mithril
  [[ "${POPULATE_CNODE}" == "Y" ]] && run_step "Scripts and configuration" "default/-s f/s" populate_cnode
  [[ "${INSTALL_CNODEBINS}" == "Y" ]] && run_step "Cardano node binaries" "-s d" download_cnodebins
  [[ "${INSTALL_CNCLI}" == "Y" ]] && run_step "CNCLI" "-s c" download_cncli
  [[ "${INSTALL_OGMIOS}" == "Y" ]] && run_step "Ogmios" "-s o" download_ogmios
  [[ "${INSTALL_CWHCLI}" == "Y" ]] && run_step "Cardano hardware CLI" "-s w" download_cardanohwcli
  [[ "${INSTALL_CARDANO_SIGNER}" == "Y" ]] && run_step "Cardano Signer" "-s x" download_cardanosigner
  [[ "${INSTALL_BLOCKPERF}" == "Y" ]] && run_step "openBlockPerf" "-s r" download_blockperf
}

while getopts :n:p:t:s:b:u opt; do
  case ${opt} in
    n ) NETWORK=${OPTARG} ;;
    p ) CNODE_PATH=${OPTARG} ;;
    t ) CNODE_NAME=${OPTARG//[^[:alnum:]]/_} ;;
    b ) BRANCH=${OPTARG} ;;
    u ) UPDATE_CHECK='N' ;;
    s ) S_ARGS="${OPTARG}" ;;
    \? ) usage ;;
    esac
done
shift $((OPTIND -1))

ACTIVE_STEP="Initialize deployment"
parse_args
log_header
main_flow

pushd -0 >/dev/null || err_exit "Could not restore original working directory."; dirs -c
log_section "Deployment finished"
log_ok "All requested steps completed"
printf "\n"
