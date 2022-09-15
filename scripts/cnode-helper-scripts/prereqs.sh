#!/usr/bin/env bash
# shellcheck disable=SC2086,SC1090,SC2059
# shellcheck source=/dev/null

unset CNODE_HOME

##########################################
# User Variables - Change as desired     #
# command line flags override set values #
##########################################

#INTERACTIVE='N'        # Interactive mode (Default: silent mode)
#NETWORK='mainnet'      # Connect to specified network instead of public network (Default: connect to public cardano network)
#WANT_BUILD_DEPS='Y'    # Skip installing OS level dependencies (Default: will check and install any missing OS level prerequisites)
#FORCE_OVERWRITE='N'    # Force overwrite of all files including normally saved user config sections in env, cnode.sh and gLiveView.sh
                        # topology.json, config.json and genesis files normally saved will also be overwritten
#LIBSODIUM_FORK='Y'     # Use IOG fork of libsodium instead of official repositories - Recommended as per IOG instructions (Default: IOG fork)
#INSTALL_CNCLI='N'      # Install/Upgrade and build CNCLI with RUST
#INSTALL_VCHC='N'       # Install/Upgrade Vacuumlabs cardano-hw-cli for hardware wallet support
#INSTALL_OGMIOS='N'     # Install Ogmios Server
#CNODE_NAME='cnode'     # Alternate name for top level folder, non alpha-numeric chars will be replaced with underscore (Default: cnode)
#CURL_TIMEOUT=60        # Maximum time in seconds that you allow the file download operation to take before aborting (Default: 60s)
#UPDATE_CHECK='Y'       # Check if there is an updated version of prereqs.sh script to download
#SUDO='Y'               # Used by docker builds to disable sudo, leave unchanged if unsure.
 
######################################
# Do NOT modify code below           #
######################################

get_input() {
  printf "%s (default: %s): " "$1" "$2" >&2; read -r answer
  if [ -z "$answer" ]; then echo "$2"; else echo "$answer"; fi
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
#             : $1 = Error message we'd like to display before exiting (function will pre-fix 'ERROR: ' to the argument)
err_exit() {
  printf "\e[31mERROR\e[0m: ${1}\n" >&2
  pushd -0 >/dev/null && dirs -c
  exit 1
}

versionCheck() { printf '%s\n%s' "${1//v/}" "${2//v/}" | sort -C -V; } #$1=available_version, $2=installed_version

usage() {
  cat <<EOF >&2

Usage: $(basename "$0") [-f] [-s] [-i] [-l] [-c] [-w] [-o] [-b <branch>] [-n <mainnet|preprod|guild|preview>] [-t <name>] [-m <seconds>]
Install pre-requisites for building cardano node and using CNTools

-f    Force overwrite of all files including normally saved user config sections in env, cnode.sh and gLiveView.sh
      topology.json, config.json and genesis files normally saved will also be overwritten
-s    Skip installing OS level dependencies (Default: will check and install any missing OS level prerequisites)
-n    Connect to specified network instead of mainnet network (Default: connect to cardano mainnet network)
      eg: -n guild
-t    Alternate name for top level folder, non alpha-numeric chars will be replaced with underscore (Default: cnode)
-m    Maximum time in seconds that you allow the file download operation to take before aborting (Default: 60s)
-l    Use system libsodium instead of IOG fork (Default: use libsodium from IOG fork)
-c    Install/Upgrade and build CNCLI with RUST
-w    Install/Upgrade Vacuumlabs cardano-hw-cli for hardware wallet support
-o    Install/Upgrade Ogmios Server binary
-b    Use alternate branch of scripts to download - only recommended for testing/development (Default: master)
-i    Interactive mode (Default: silent mode)

EOF
  exit 1
}

while getopts :in:sflcwot:m:b: opt; do
  case ${opt} in
    i ) INTERACTIVE='Y' ;;
    n ) NETWORK=${OPTARG} ;;
    s ) WANT_BUILD_DEPS='N' ;;
    f ) FORCE_OVERWRITE='Y' ;;
    l ) LIBSODIUM_FORK='N' ;;
    c ) INSTALL_CNCLI='Y' ;;
    w ) INSTALL_VCHC='Y' ;;
    o ) INSTALL_OGMIOS='Y' ;;
    t ) CNODE_NAME=${OPTARG//[^[:alnum:]]/_} ;;
    m ) CURL_TIMEOUT=${OPTARG} ;;
    b ) BRANCH=${OPTARG} ;;
    \? ) usage ;;
    esac
done
shift $((OPTIND -1))

[[ -z ${INTERACTIVE} ]] && INTERACTIVE='N'
[[ -z ${NETWORK} ]] && NETWORK='mainnet'
[[ -z ${WANT_BUILD_DEPS} ]] && WANT_BUILD_DEPS='Y'
[[ -z ${FORCE_OVERWRITE} ]] && FORCE_OVERWRITE='N'
[[ -z ${LIBSODIUM_FORK} ]] && LIBSODIUM_FORK='Y'
[[ -z ${INSTALL_CNCLI} ]] && INSTALL_CNCLI='N'
[[ -z ${INSTALL_VCHC} ]] && INSTALL_VCHC='N'
[[ -z ${INSTALL_OGMIOS} ]] && INSTALL_OGMIOS='N'
[[ -z ${CNODE_NAME} ]] && CNODE_NAME='cnode'
[[ -z ${CURL_TIMEOUT} ]] && CURL_TIMEOUT=60
[[ -z ${UPDATE_CHECK} ]] && UPDATE_CHECK='Y'
[[ -z ${SUDO} ]] && SUDO='Y'
[[ "${SUDO}" = 'Y' ]] && sudo="sudo" || sudo=""
[[ "${SUDO}" = 'Y' && $(id -u) -eq 0 ]] && err_exit "Please run as non-root user."

# For who runs the script within containers and running it as root.
U_ID=$(id -u)
G_ID=$(id -g)

dirs -c # clear dir stack
CNODE_PATH="/opt/cardano"
CNODE_HOME=${CNODE_PATH}/${CNODE_NAME}
CNODE_VNAME=$(echo "$CNODE_NAME" | awk '{print toupper($0)}')
[[ -z "${BRANCH}" ]] && BRANCH="master"

REPO="https://github.com/cardano-community/guild-operators"
REPO_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators"
URL_RAW="${REPO_RAW}/${BRANCH}"

# Check if prereqs.sh update is available
PARENT="$(dirname $0)"
if [[ ${UPDATE_CHECK} = 'Y' ]] && curl -s -f -m ${CURL_TIMEOUT} -o "${PARENT}"/prereqs.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/prereqs.sh 2>/dev/null; then
  TEMPL_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/prereqs.sh)
  TEMPL2_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/prereqs.sh.tmp)
  if [[ "$(echo ${TEMPL_CMD} | sha256sum)" != "$(echo ${TEMPL2_CMD} | sha256sum)" ]]; then
    if get_answer "A new version of prereqs script is available, do you want to download the latest version?"; then
      cp "${PARENT}"/prereqs.sh "${PARENT}/prereqs.sh_bkp$(date +%s)"
      STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/prereqs.sh)
      printf '%s\n%s\n' "$STATIC_CMD" "$TEMPL2_CMD" > "${PARENT}"/prereqs.sh.tmp
      {
        mv -f "${PARENT}"/prereqs.sh.tmp "${PARENT}"/prereqs.sh && \
        chmod 755 "${PARENT}"/prereqs.sh && \
        echo -e "\nUpdate applied successfully, please run prereqs again!\n" && \
        exit 0; 
      } || {
        echo -e "Update failed!\n\nPlease manually download latest version of prereqs.sh script from GitHub" && \
        exit 1;
      }
    fi
  fi
fi
rm -f "${PARENT}"/prereqs.sh.tmp

mkdir -p "${HOME}"/git > /dev/null 2>&1 # To hold git repositories that will be used for building binaries

if [[ "${INTERACTIVE}" = 'Y' ]]; then
  clear
  CNODE_PATH=$(get_input "Please enter the project path" ${CNODE_PATH})
  CNODE_NAME=$(get_input "Please enter directory name" ${CNODE_NAME})
  CNODE_NAME=${CNODE_NAME//[^[:alnum:]]/_}
  CNODE_HOME=${CNODE_PATH}/${CNODE_NAME}
  CNODE_VNAME=$(echo "$CNODE_NAME" | awk '{print toupper($0)}')

  if [ -d "${CNODE_HOME}" ]; then
    err_exit "The \"${CNODE_HOME}\" directory exist, pls remove or choose an other one."
  fi

  if ! get_answer "Do you want to install build dependencies for cardano node?"; then
    WANT_BUILD_DEPS='N'
  fi
fi

# Description : Add epel repository when needed
#             : $1 = DISTRO
#             : $2 = Epel repository VERSION_ID
#             : $3 = pkg_opts for repo install
add_epel_repository() {
  if [[ "${1}" =~ Fedora ]]; then return; fi
  echo "  Enabling epel repository..."
  ! grep -q ^epel <<< "$(yum repolist)" && $sudo yum ${3} install https://dl.fedoraproject.org/pub/epel/epel-release-latest-"${2}".noarch.rpm > /dev/null
}

if [ "$WANT_BUILD_DEPS" = 'Y' ]; then

  # Determine OS platform
  OS_ID=$(grep -i ^id_like= /etc/os-release | cut -d= -f 2)
  DISTRO=$(grep -i ^NAME= /etc/os-release | cut -d= -f 2)
  VERSION_ID=$(grep -i ^version_id= /etc/os-release | cut -d= -f 2 | tr -d '"' | cut -d. -f 1)
  ARCH=$(uname -i)

  if [[ "${OS_ID}" =~ ebian ]] || [[ "${DISTRO}" =~ ebian ]]; then
    #Debian/Ubuntu
    pkg_opts="-y"
    echo "Using apt to prepare packages for ${DISTRO} system"
    echo "  Updating system packages..."
    $sudo apt-get ${pkg_opts} install curl > /dev/null
    $sudo apt-get ${pkg_opts} update > /dev/null
    echo "  Installing missing prerequisite packages, if any.."
    pkg_list="libpq-dev python3 build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev systemd libsystemd-dev libsodium-dev zlib1g-dev make g++ tmux git jq libncursesw5 gnupg aptitude libtool autoconf secure-delete iproute2 bc tcptraceroute dialog automake sqlite3 bsdmainutils libusb-1.0-0-dev libudev-dev unzip"
    if [ -z "${ARCH##*aarch64*}" ]; then
      pkg_list="${pkg_list} llvm clang libnuma-dev"
    fi
    $sudo apt-get ${pkg_opts} install ${pkg_list} > /dev/null;rc=$?
    if [ $rc != 0 ]; then
      echo "An error occurred while installing the prerequisite packages, please investigate by using the command below:"
      echo "$sudo apt-get ${pkg_opts} install ${pkg_list}"
      echo "It would be best if you could submit an issue at ${REPO} with the details to tackle in future, as some errors may be due to external/already present dependencies"
      err_exit
    fi
  elif [[ "${OS_ID}" =~ rhel ]] || [[ "${OS_ID}" =~ fedora ]] || [[ "${DISTRO}" =~ Fedora ]]; then
    #CentOS/RHEL/Fedora/RockyLinux
    pkg_opts="-y"
    echo "Using yum to prepare packages for ${DISTRO} system"
    echo "  Updating system packages..."
    $sudo yum ${pkg_opts} install curl > /dev/null
    $sudo yum ${pkg_opts} update > /dev/null
    echo "  Installing missing prerequisite packages, if any.."
    pkg_list="python3 coreutils libffi-devel gmp-devel openssl-devel ncurses-devel ncurses-libs systemd systemd-devel libsodium-devel zlib-devel make gcc-c++ tmux git jq gnupg2 libtool autoconf iproute bc traceroute dialog sqlite util-linux xz wget unzip procps-ng"
    if [[ "${VERSION_ID}" == "2" ]] ; then
      #AmazonLinux2
      pkg_list="${pkg_list} libusb ncurses-compat-libs pkgconfig srm"
    elif [[ "${VERSION_ID}" == "7" ]]; then
      #RHEL/CentOS7
      pkg_list="${pkg_list} libusb pkgconfig srm"
    elif [[ "${VERSION_ID}" =~ "8" ]] || [[ "${VERSION_ID}" =~ "9" ]]; then
      #RHEL/CentOS/RockyLinux8
      pkg_opts="${pkg_opts} --allowerasing"
      pkg_list="${pkg_list} libusbx ncurses-compat-libs pkgconf-pkg-config"
    elif [[ "${DISTRO}" =~ Fedora ]]; then
      #Fedora
      pkg_opts="${pkg_opts} --allowerasing"
      pkg_list="${pkg_list} libusbx ncurses-compat-libs pkgconf-pkg-config srm"
    fi
    if [ -z "${ARCH##*aarch64*}" ]; then
      pkg_list="${pkg_list} llvm clang numactl-devel"
    fi    
    add_epel_repository "${DISTRO}" "${VERSION_ID}" "${pkg_opts}"
    $sudo yum ${pkg_opts} install ${pkg_list} > /dev/null;rc=$?
    if [ $rc != 0 ]; then
      echo "An error occurred while installing the prerequisite packages, please investigate by using the command below:"
      echo "$sudo yum ${pkg_opts} install ${pkg_list}"
      echo "It would be best if you could submit an issue at ${REPO} with the details to tackle in future, as some errors may be due to external/already present dependencies"
      err_exit
    fi
    if [ -f /usr/lib64/libtinfo.so ] && [ -f /usr/lib64/libtinfo.so.5 ]; then
      echo "  Symlink updates not required for ncurse libs, skipping.."
    else
      echo "  Updating symlinks for ncurse libs.."
      $sudo ln -s "$(find /usr/lib64/libtinfo.so* | tail -1)" /usr/lib64/libtinfo.so
      $sudo ln -s "$(find /usr/lib64/libtinfo.so* | tail -1)" /usr/lib64/libtinfo.so.5
    fi
  elif [[ $(uname) == Darwin ]]; then
    echo "MacOS detected";
    pkg_list="coreutils gnupg jq libsodium tcptraceroute"
    brew install ${pkg_list} > /dev/null;rc=$?

    if [ $rc != 0 ]; then
      echo "An error occurred while installing the prerequisite packages, please investigate by using the command below:"
      echo "brew install ${pkg_list}"
      echo "It would be best if you could submit an issue at ${REPO} with the details to tackle in future, as some errors may be due to external/already present dependencies"
      err_exit
    fi
  else
    echo "We have no automated procedures for this ${DISTRO} system"
    echo "please manually install required packages."
    echo "Their relative names are:"
    echo "Debian: curl build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev libsystemd-dev zlib1g-dev tmux"
    echo "CentOS: curl pkgconfig libffi-devel gmp-devel openssl-devel ncurses-libs ncurses-compat-libs systemd-devel zlib-devel tmux procps-ng"
    err_exit
  fi
  echo "Install libsecp256k1 ... "
  if ! grep -q "/usr/local/lib:\$LD_LIBRARY_PATH" "${HOME}"/.bashrc; then
    echo "export LD_LIBRARY_PATH=/usr/local/lib:\$LD_LIBRARY_PATH" >> "${HOME}"/.bashrc
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
  fi
  pushd "${HOME}"/git >/dev/null || err_exit
  [[ ! -d "./secp256k1" ]] && git clone https://github.com/bitcoin-core/secp256k1 &>/dev/null
  pushd secp256k1 >/dev/null || err_exit
  git checkout ac83be33 &>/dev/null
  ./autogen.sh > autogen.log > /tmp/secp256k1.log 2>&1
  ./configure --prefix=/usr --enable-module-schnorrsig --enable-experimental > configure.log >> /tmp/secp256k1.log 2>&1
  make > make.log 2>&1
  make check >>make.log 2>&1
  $sudo make install > install.log 2>&1
  export BOOTSTRAP_HASKELL_NO_UPGRADE=1
  export BOOTSTRAP_HASKELL_GHC_VERSION=8.10.7
  export BOOTSTRAP_HASKELL_CABAL_VERSION=3.6.2.0
  if ! command -v ghc &>/dev/null; then
    echo "Install ghcup (The Haskell Toolchain installer) .."
    BOOTSTRAP_HASKELL_NONINTERACTIVE=1
    BOOTSTRAP_HASKELL_INSTALL_STACK=1
    BOOTSTRAP_HASKELL_ADJUST_BASHRC=1
    unset BOOTSTRAP_HASKELL_INSTALL_HLS
    export BOOTSTRAP_HASKELL_NONINTERACTIVE BOOTSTRAP_HASKELL_INSTALL_STACK BOOTSTRAP_HASKELL_ADJUST_BASHRC
    curl -s -m ${CURL_TIMEOUT} --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | bash
  fi
  [ -f "${HOME}/.ghcup/env" ] && source "${HOME}/.ghcup/env"
  if ! ghc --version 2>/dev/null | grep -q ${BOOTSTRAP_HASKELL_GHC_VERSION}; then
    echo "Upgrading ghcup .."
    ghcup upgrade 2>/dev/null
    echo "Installing GHC v${BOOTSTRAP_HASKELL_GHC_VERSION} .."
    ghcup install ghc ${BOOTSTRAP_HASKELL_GHC_VERSION}
    ghcup set ghc ${BOOTSTRAP_HASKELL_GHC_VERSION}
    ghc --version
  fi
  cabal_version=$(cabal --version 2>/dev/null | head -n 1 | cut -d' ' -f3)
  if [[ -z ${cabal_version} || ! ${cabal_version} = "${BOOTSTRAP_HASKELL_CABAL_VERSION}" ]]; then
    if [[ -n ${cabal_version} ]]; then
      echo "Uninstalling Cabal v${cabal_version} .."
      ghcup rm cabal ${cabal_version}
    fi
    echo "Installing Cabal v${BOOTSTRAP_HASKELL_CABAL_VERSION}.."
    ghcup install cabal ${BOOTSTRAP_HASKELL_CABAL_VERSION}
  fi
fi

if [ ! -d "${HOME}"/.cabal/bin ]; then mkdir -p "${HOME}"/.cabal/bin; fi

# END OF Install build deps.

echo "Creating Folder Structure .."

if grep -q "export ${CNODE_VNAME}_HOME=" "${HOME}"/.bashrc; then
  echo "Environment Variable already set up!"
else
  echo "Setting up Environment Variable"
  echo -e "\nexport ${CNODE_VNAME}_HOME=${CNODE_HOME}" >> "${HOME}"/.bashrc
  
fi

if [[ "${LIBSODIUM_FORK}" = "Y" ]]; then
  if ! grep -q "/usr/local/lib:\$LD_LIBRARY_PATH" "${HOME}"/.bashrc; then
    echo "export LD_LIBRARY_PATH=/usr/local/lib:\$LD_LIBRARY_PATH" >> "${HOME}"/.bashrc
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
  fi
  pushd "${HOME}"/git >/dev/null || err_exit
  [[ ! -d "./libsodium" ]] && git clone https://github.com/input-output-hk/libsodium &>/dev/null
  pushd libsodium >/dev/null || err_exit
  git checkout 66f017f1 &>/dev/null
  ./autogen.sh > autogen.log > /tmp/libsodium.log 2>&1
  ./configure > configure.log >> /tmp/libsodium.log 2>&1
  make > make.log 2>&1
  $sudo make install > install.log 2>&1
  echo "IOG fork of libsodium installed to /usr/local/lib/"
fi

if [[ "${INSTALL_CNCLI}" = "Y" ]]; then
  echo "Installing CNCLI"
  if command -v cncli >/dev/null; then cncli_version="v$(cncli -V | cut -d' ' -f2)"; else cncli_version="v0.0.0"; fi
  pushd "${HOME}"/git >/dev/null || err_exit
  if [[ -d ./cncli ]]; then
    echo "  previous CNCLI installation found, pulling latest version from GitHub..."
  else
    echo "  downloading CNCLI..."
    if ! output=$(git clone https://github.com/cardano-community/cncli.git 2>&1); then echo -e "${output}" && err_exit; fi
  fi
  pushd ./cncli >/dev/null || err_exit
  git remote set-url origin https://github.com/cardano-community/cncli >/dev/null
  git checkout develop
  if ! output=$(git fetch --all --prune 2>&1); then echo -e "${output}" && err_exit; fi
  cncli_git_latestTag=$(git describe --tags "$(git rev-list --tags --max-count=1)")
  if ! output=$(git checkout ${cncli_git_latestTag} 2>&1 && git submodule update --init --recursive --force 2>&1); then echo -e "${output}" && err_exit; fi
  if ! versionCheck "${cncli_git_latestTag}" "${cncli_version}"; then
    [[ ${cncli_version} = "v0.0.0" ]] && echo "  latest version: ${cncli_git_latestTag}" || echo "  installed version: ${cncli_version}  |  latest version: ${cncli_git_latestTag}"
    # install rust if not available
    if ! command -v "rustup" &>/dev/null; then
      echo "  installing RUST..."
      if ! output=$(curl --proto '=https' --tlsv1.2 https://sh.rustup.rs -sSf | sh -s -- -y 2>&1); then echo -e "${output}" && err_exit; fi
      . $HOME/.cargo/env
      if ! output=$(rustup install stable 2>&1); then echo -e "${output}" && err_exit; fi
      if ! output=$(rustup default stable 2>&1); then echo -e "${output}" && err_exit; fi
    else
      echo "  updating RUST if needed..."
      rustup update &>/dev/null #ignore any errors, not crucial that update succeed
    fi
    . "${HOME}"/.profile # source profile to load ${HOME}/.cargo/bin into PATH
    git checkout --quiet ${cncli_git_latestTag}
    echo "  building CNCLI ${cncli_git_latestTag} ..."
    if ! output=$(cargo install --path . --force --locked 2>&1); then echo -e "${output}" && err_exit; fi
    echo "  $(cncli -V) installed!"
  else
    echo "  CNCLI already latest version [${cncli_version}], skipping!"
  fi
fi

if [[ "${INSTALL_VCHC}" = "Y" ]]; then
  echo "Installing Vacuumlabs cardano-hw-cli"
  if command -v cardano-hw-cli >/dev/null; then vchc_version="$(cardano-hw-cli version 2>/dev/null | head -n 1 | cut -d' ' -f6)"; else vchc_version="0.0.0"; fi
  echo "  downloading Vacuumlabs cardano-hw-cli..."
  pushd /tmp >/dev/null || err_exit
  rm -rf cardano-hw-cli*
  if [[ $(uname) == Darwin ]]; then
    vchc_asset_url="$(curl -s https://api.github.com/repos/vacuumlabs/cardano-hw-cli/releases/latest | jq -r '.assets[].browser_download_url' | grep '_mac-x64.tar.gz')"
  else
    vchc_asset_url="$(curl -s https://api.github.com/repos/vacuumlabs/cardano-hw-cli/releases/latest | jq -r '.assets[].browser_download_url' | grep '_linux-x64.tar.gz')"
  fi
  if curl -sL -f -m ${CURL_TIMEOUT} -o cardano-hw-cli_linux-x64.tar.gz ${vchc_asset_url}; then
    tar zxf cardano-hw-cli_linux-x64.tar.gz &>/dev/null
    rm -f cardano-hw-cli_linux-x64.tar.gz
    [[ -f cardano-hw-cli/cardano-hw-cli ]] || err_exit "cardano-hw-cli downloaded but binary not found after extracting package!"
    vchc_git_version="$(cardano-hw-cli/cardano-hw-cli version 2>/dev/null | head -n 1 | cut -d' ' -f6)"
    if ! versionCheck "${vchc_git_version}" "${vchc_version}"; then
      [[ ${vchc_version} = "0.0.0" ]] && echo "  latest version: ${vchc_git_version}" || echo "  installed version: ${vchc_version}  |  latest version: ${vchc_git_version}"
      mkdir -p "${HOME}"/bin
      if [ -d "${HOME}"/bin/cardano-hw-cli ]; then
        rm -rf "${HOME}"/bin/cardano-hw-cli 
      fi
      pushd "${HOME}"/bin >/dev/null || err_exit
      mv -f /tmp/cardano-hw-cli .
      if ! grep -q "cardano-hw-cli" "${HOME}"/.bashrc; then
        echo "  adding cardano-hw-cli to PATH and setting Ledger udev rules, reload shell to take effect!"
        echo "  PATH=\"$HOME/bin/cardano-hw-cli:\$PATH\"" >> "${HOME}"/.bashrc
      fi
      if [[ ! -f "/etc/udev/rules.d/20-hw1.rules" ]]; then
        # Ledger udev rules
        curl -s -f -m ${CURL_TIMEOUT} https://raw.githubusercontent.com/LedgerHQ/udev-rules/master/add_udev_rules.sh | $sudo bash
        $sudo sed -e "s@TAG+=\"uaccess\"@OWNER=\"$USER\", TAG+=\"uaccess\"@g" -i /etc/udev/rules.d/20-hw1.rules
      fi
      if [[ ! -f "/etc/udev/rules.d/51-trezor.rules" ]]; then
        # Trezor udev rules
        $sudo curl -s -f -m ${CURL_TIMEOUT} https://data.trezor.io/udev/51-trezor.rules -o /etc/udev/rules.d/51-trezor.rules
        $sudo sed -e "s@TAG+=\"uaccess\"@OWNER=\"$USER\", TAG+=\"uaccess\"@g" -i /etc/udev/rules.d/51-trezor.rules
      fi
      # Trigger rules update
      $sudo udevadm control --reload-rules
      $sudo udevadm trigger
      echo "  cardano-hw-cli v${vchc_git_version} installed!"
    else
      rm -rf cardano-hw-cli #cleanup in /tmp
      echo "  cardano-hw-cli already latest version [${vchc_version}], skipping!"
    fi
  else
    err_exit "Download of latest release of cardano-hw-cli from GitHub failed! Please retry or manually install it."
  fi
fi

if [[ "${INSTALL_OGMIOS}" = "Y" ]]; then
  echo "Installing Ogmios"
  if command -v ogmios >/dev/null; then ogmios_version="$(ogmios --version)"; else ogmios_version="v0.0.0"; fi
  rm -rf /tmp/ogmios && mkdir /tmp/ogmios
  pushd /tmp/ogmios >/dev/null || err_exit
  ogmios_asset_url="$(curl -s https://api.github.com/repos/CardanoSolutions/ogmios/releases/latest | jq -r '.assets[].browser_download_url')"
  if curl -sL -f -m ${CURL_TIMEOUT} -o ogmios.zip ${ogmios_asset_url}; then
    unzip ogmios.zip &>/dev/null
    rm -f ogmios.zip
    [[ -f bin/ogmios ]] || err_exit "ogmios downloaded but binary not found after extracting package!"
    ogmios_git_version="$(curl -s https://api.github.com/repos/CardanoSolutions/ogmios/releases/latest | jq -r '.tag_name')"
    if ! versionCheck "${ogmios_git_version}" "${ogmios_version}"; then
      [[ "${ogmios_version}" = "0.0.0" ]] && echo "  latest version: ${ogmios_git_version}" || echo "  installed version: ${ogmios_version} | latest version: ${ogmios_git_version}"
      chmod +x /tmp/ogmios/bin/ogmios
      mv -f /tmp/ogmios/bin/ogmios "${HOME}"/.cabal/bin/
      echo "  ogmios ${ogmios_git_version} installed!"
    else
      rm -rf /tmp/ogmios #cleanup in /tmp
      echo "  ogmios already latest version [${ogmios_version}], skipping!"
    fi
  else
    err_exit "Download of latest release of ogmios archive from GitHub failed! Please retry or manually install it."
  fi
fi

$sudo mkdir -p "${CNODE_HOME}"/files "${CNODE_HOME}"/db "${CNODE_HOME}"/guild-db "${CNODE_HOME}"/logs "${CNODE_HOME}"/scripts "${CNODE_HOME}"/sockets "${CNODE_HOME}"/priv
$sudo chown -R "$U_ID":"$G_ID" "${CNODE_HOME}" 2>/dev/null

echo "Downloading files..."

pushd "${CNODE_HOME}"/files >/dev/null || err_exit


if ! curl -s -f -m ${CURL_TIMEOUT} "https://api.github.com/repos/cardano-community/guild-operators/branches" | jq -e ".[] | select(.name == \"${BRANCH}\")" &>/dev/null ; then
  echo -e "\nWARN!! ${BRANCH} branch does not exist, falling back to alpha branch\n"
  BRANCH=alpha
  URL_RAW="${REPO_RAW}/${BRANCH}"
  echo "${BRANCH}" > "${CNODE_HOME}"/scripts/.env_branch
else
  echo "${BRANCH}" > "${CNODE_HOME}"/scripts/.env_branch
fi

# Download dbsync config
curl -sL -f -m ${CURL_TIMEOUT} -o dbsync.json.tmp ${URL_RAW}/files/config-dbsync.json
[[ "${NETWORK}" != "mainnet" ]] && sed -i 's#NetworkName": "mainnet"#NetworkName": "testnet"#g' dbsync.json.tmp

# Download node config, genesis and topology from template
if [[ ${NETWORK} = "guild" ]]; then
  curl -s -f -m ${CURL_TIMEOUT} -o byron-genesis.json.tmp ${URL_RAW}/files/byron-genesis-guild.json
  curl -s -f -m ${CURL_TIMEOUT} -o shelley-genesis.json.tmp ${URL_RAW}/files/genesis-guild.json
  curl -s -f -m ${CURL_TIMEOUT} -o alonzo-genesis.json.tmp ${URL_RAW}/files/alonzo-genesis-guild.json
  curl -s -f -m ${CURL_TIMEOUT} -o topology.json.tmp ${URL_RAW}/files/topology-guild.json
  curl -s -f -m ${CURL_TIMEOUT} -o config.json.tmp ${URL_RAW}/files/config-guild.json
elif [[ ${NETWORK} =~ ^(mainnet|preprod|preview|testnet)$ ]]; then # testnet will be retired , already marked as legacy soon
  NWCONFURL="https://raw.githubusercontent.com/input-output-hk/cardano-world/master/docs/environments"
  curl -sL -f -m ${CURL_TIMEOUT} -o byron-genesis.json.tmp "${NWCONFURL}/${NETWORK}/byron-genesis.json"
  curl -sL -f -m ${CURL_TIMEOUT} -o shelley-genesis.json.tmp "${NWCONFURL}/${NETWORK}/shelley-genesis.json"
  curl -sL -f -m ${CURL_TIMEOUT} -o alonzo-genesis.json.tmp "${NWCONFURL}/${NETWORK}/alonzo-genesis.json"
  curl -sL -f -m ${CURL_TIMEOUT} -o topology.json.tmp "${NWCONFURL}/${NETWORK}/topology.json"
  curl -s -f -m ${CURL_TIMEOUT} -o config.json.tmp "${URL_RAW}/files/config-${NETWORK}.json"
else
  err_exit "Unknown network specified! Kindly re-check the network name, valid options are: mainnet, preprod, guild or preview."
fi
sed -e "s@/opt/cardano/cnode@${CNODE_HOME}@g" -i ./*.json.tmp
[[ ${FORCE_OVERWRITE} = 'Y' && -f topology.json ]] && cp -f topology.json "topology.json_bkp$(date +%s)"
[[ ${FORCE_OVERWRITE} = 'Y' && -f config.json ]] && cp -f config.json "config.json_bkp$(date +%s)"
[[ ${FORCE_OVERWRITE} = 'Y' && -f dbsync.json ]] && cp -f dbsync.json "dbsync.json_bkp$(date +%s)"
if [[ ${FORCE_OVERWRITE} = 'Y' || ! -f byron-genesis.json ]]; then mv -f byron-genesis.json.tmp byron-genesis.json; else rm -f byron-genesis.json.tmp; fi
if [[ ${FORCE_OVERWRITE} = 'Y' || ! -f shelley-genesis.json ]]; then mv -f shelley-genesis.json.tmp shelley-genesis.json; else rm -f shelley-genesis.json.tmp; fi
if [[ ${FORCE_OVERWRITE} = 'Y' || ! -f alonzo-genesis.json ]]; then mv -f alonzo-genesis.json.tmp alonzo-genesis.json; else rm -f alonzo-genesis.json.tmp; fi
if [[ ${FORCE_OVERWRITE} = 'Y' || ! -f topology.json ]]; then mv -f topology.json.tmp topology.json; else rm -f topology.json.tmp; fi
if [[ ${FORCE_OVERWRITE} = 'Y' || ! -f config.json ]]; then mv -f config.json.tmp config.json; else rm -f config.json.tmp; fi
if [[ ${FORCE_OVERWRITE} = 'Y' || ! -f dbsync.json ]]; then mv -f dbsync.json.tmp dbsync.json; else rm -f dbsync.json.tmp; fi

pushd "${CNODE_HOME}"/scripts >/dev/null || err_exit
curl -s -f -m ${CURL_TIMEOUT} -o env.tmp ${URL_RAW}/scripts/cnode-helper-scripts/env
curl -s -f -m ${CURL_TIMEOUT} -o rotatePoolKeys.sh ${URL_RAW}/scripts/cnode-helper-scripts/rotatePoolKeys.sh
curl -s -f -m ${CURL_TIMEOUT} -o cnode.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/cnode.sh
curl -s -f -m ${CURL_TIMEOUT} -o dbsync.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/dbsync.sh
curl -s -f -m ${CURL_TIMEOUT} -o cntools.sh ${URL_RAW}/scripts/cnode-helper-scripts/cntools.sh
curl -s -f -m ${CURL_TIMEOUT} -o cntools.library ${URL_RAW}/scripts/cnode-helper-scripts/cntools.library
curl -s -f -m ${CURL_TIMEOUT} -o logMonitor.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/logMonitor.sh
curl -s -f -m ${CURL_TIMEOUT} -o setup_mon.sh ${URL_RAW}/scripts/cnode-helper-scripts/setup_mon.sh
curl -s -f -m ${CURL_TIMEOUT} -o setup-grest.sh.tmp ${URL_RAW}/scripts/grest-helper-scripts/setup-grest.sh
curl -s -f -m ${CURL_TIMEOUT} -o topologyUpdater.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/topologyUpdater.sh
curl -s -f -m ${CURL_TIMEOUT} -o cabal-build-all.sh ${URL_RAW}/scripts/cnode-helper-scripts/cabal-build-all.sh
curl -s -f -m ${CURL_TIMEOUT} -o submitapi.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/submitapi.sh
curl -s -f -m ${CURL_TIMEOUT} -o ogmios.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/ogmios.sh
curl -s -f -m ${CURL_TIMEOUT} -o system-info.sh ${URL_RAW}/scripts/cnode-helper-scripts/system-info.sh
curl -s -f -m ${CURL_TIMEOUT} -o gLiveView.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/gLiveView.sh
curl -s -f -m ${CURL_TIMEOUT} -o deploy-as-systemd.sh ${URL_RAW}/scripts/cnode-helper-scripts/deploy-as-systemd.sh
curl -s -f -m ${CURL_TIMEOUT} -o cncli.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/cncli.sh
curl -s -f -m ${CURL_TIMEOUT} -o blockPerf.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/blockPerf.sh
sed -e "s@/opt/cardano/cnode@${CNODE_HOME}@g" -e "s@CNODE_HOME@${CNODE_VNAME}_HOME@g" -i ./*.*

### Update file retaining existing custom configs
updateWithCustomConfig() {
  file=$1
  if [[ ! -f ${file}.tmp ]]; then
    echo "ERROR!! Failed to download '${file}' from GitHub"
    return
  fi
  if [[ -f ${file} && ${FORCE_OVERWRITE} = 'N' ]]; then
    if grep '^# Do NOT modify' ${file} >/dev/null 2>&1; then
      TEMPL_CMD=$(awk '/^# Do NOT modify/,0' ${file}.tmp)
      if [[ -z ${TEMPL_CMD} ]]; then
        echo "ERROR!! Script downloaded from GitHub corrupt, ignoring update for '${file}'"
        rm -f ${file}.tmp
        return
      fi
      STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' ${file})
      printf '%s\n%s\n' "${STATIC_CMD}" "${TEMPL_CMD}" > ${file}.tmp
    else
      rm -f ${file}.tmp
      return
    fi
  fi
  [[ -f ${file} ]] && cp -f ${file} "${file}_bkp$(date +%s)"
  mv -f ${file}.tmp ${file}
}

[[ ${FORCE_OVERWRITE} = 'Y' ]] && echo "Forced full upgrade! Please edit scripts/env, scripts/cnode.sh, scripts/dbsync.sh, scripts/submitapi.sh, scripts/ogmios.sh, scripts/gLiveView.sh and scripts/topologyUpdater.sh (alongwith files/topology.json, files/config.json, files/dbsync.json) as required/"

updateWithCustomConfig "env"
updateWithCustomConfig "cnode.sh"
updateWithCustomConfig "dbsync.sh"
updateWithCustomConfig "submitapi.sh"
updateWithCustomConfig "ogmios.sh"
updateWithCustomConfig "gLiveView.sh"
updateWithCustomConfig "topologyUpdater.sh"
updateWithCustomConfig "logMonitor.sh"
updateWithCustomConfig "cncli.sh"
updateWithCustomConfig "blockPerf.sh"
updateWithCustomConfig "setup-grest.sh"

find "${CNODE_HOME}/scripts" -name '*.sh' -exec chmod 755 {} \; 2>/dev/null
chmod -R 700 "${CNODE_HOME}"/priv 2>/dev/null

pushd -0 >/dev/null || err_exit; dirs -c
