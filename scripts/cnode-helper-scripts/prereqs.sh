#!/bin/bash
# shellcheck disable=SC2086,SC1090

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

err_exit() {
  printf "%s\nExiting...\n" "$*" >&2
  pushd -0 >/dev/null && dirs -c
  exit 1
}

usage() {
  cat <<EOF >&2

Usage: $(basename "$0") [-f] [-s] [-i] [-l] [-c] [-b <branch>] [-n <testnet|guild>] [-t <name>] [-m <seconds>]
Install pre-requisites for building cardano node and using CNTools

-f    Force overwrite of all files including normally saved user config sections in env, cnode.sh and gLiveView.sh
      topology.json, config.json and genesis files normally saved will also be overwritten
-s    Skip installing OS level dependencies (Default: will check and install any missing OS level prerequisites)
-n    Connect to specified network instead of public network (Default: connect to public cardano network)
      eg: -n testnet
-t    Alternate name for top level folder, non alpha-numeric chars will be replaced with underscore (Default: cnode)
-m    Maximum time in seconds that you allow the file download operation to take before aborting (Default: 60s)
-l    Use IOG fork of libsodium - Recommended as per IOG instructions (Default: system build)
-c    Install/Upgrade and build CNCLI with RUST - IOG fork of libsodium required
-b    Use alternate branch of scripts to download - only recommended for testing/development (Default: master)
-i    Interactive mode (Default: silent mode)

EOF
  exit 1
}

# Initialize defaults
unset CNODE_HOME
INTERACTIVE='N'
NETWORK='mainnet'
WANT_BUILD_DEPS='Y'
FORCE_OVERWRITE='N'
LIBSODIUM_FORK='N'
INSTALL_CNCLI='N'
CNODE_NAME='cnode'
CURL_TIMEOUT=60

while getopts :in:sflct:m:b: opt; do
  case ${opt} in
    i ) INTERACTIVE='Y' ;;
    n ) NETWORK=${OPTARG} ;;
    s ) WANT_BUILD_DEPS='N' ;;
    f ) FORCE_OVERWRITE='Y' ;;
    l ) LIBSODIUM_FORK='Y' ;;
    c ) INSTALL_CNCLI='Y' ;;
    t ) CNODE_NAME=${OPTARG//[^[:alnum:]]/_} ;;
    m ) CURL_TIMEOUT=${OPTARG} ;;
    b ) BRANCH=${OPTARG} ;;
    \? ) usage ;;
    esac
done
shift $((OPTIND -1))

# For who runs the script within containers and running it as root.
U_ID=$(id -u)
G_ID=$(id -g)

dirs -c # clear dir stack
CNODE_PATH="/opt/cardano"
CNODE_HOME=${CNODE_PATH}/${CNODE_NAME}
CNODE_VNAME=$(echo "$CNODE_NAME" | awk '{print toupper($0)}')
if [[ -z "${BRANCH}" ]]; then
  [[ -f "${CNODE_HOME}"/scripts/.env_branch ]] && BRANCH="$(cat ${CNODE_HOME}/scripts/.env_branch)" || BRANCH="master"
fi

REPO="https://github.com/cardano-community/guild-operators"
REPO_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators"

#if [ $(id -u$( -eq 0 ]; then
#  err_exit "Please run as non-root user."
#fi

SUDO="Y";
if [ "${SUDO}" = "Y" ] || [ "${SUDO}" = "y" ] ; then sudo="sudo"; else sudo="" ; fi

if [ "${INTERACTIVE}" = 'Y' ]; then
  clear;
  CNODE_PATH=$(get_input "Please enter the project path" ${CNODE_PATH})
  CNODE_NAME=$(get_input "Please enter directory name" ${CNODE_NAME})
  CNODE_HOME=${CNODE_PATH}/${CNODE_NAME}
  CNODE_VNAME=$(echo "$CNODE_NAME" | awk '{print toupper($0)}')

  if [ -d "${CNODE_HOME}" ]; then
    err_exit "The \"${CNODE_HOME}\" directory exist, pls remove or choose an other one."
  fi

  if ! get_answer "Do you want to install build dependencies for cardano node?"; then
    WANT_BUILD_DEPS='N'
  fi
fi

if [ "$WANT_BUILD_DEPS" = 'Y' ]; then

  # Determine OS platform
  OS_ID=$(grep -i ^id_like= /etc/os-release | cut -d= -f 2)
  DISTRO=$(grep -i ^NAME= /etc/os-release | cut -d= -f 2)

  if [[ "${OS_ID}" =~ ebian ]] || [[ "${DISTRO}" =~ ebian ]]; then
    #Debian/Ubuntu
    echo "Using apt to prepare packages for ${DISTRO} system"
    echo "  Updating system packages..."
    $sudo apt-get -y install curl > /dev/null
    $sudo apt-get -y update > /dev/null
    echo "  Installing missing prerequisite packages, if any.."
    pkg_list="libpq-dev python3 build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev systemd libsystemd-dev libsodium-dev zlib1g-dev make g++ tmux git jq libncursesw5 gnupg aptitude libtool autoconf secure-delete iproute2 bc tcptraceroute dialog sqlite libsqlite3-dev"
    $sudo apt-get -y install ${pkg_list} > /dev/null;rc=$?
    if [ $rc != 0 ]; then
      echo "An error occurred while installing the prerequisite packages, please investigate by using the command below:"
      echo "sudo apt-get -y install ${pkg_list}"
      echo "It would be best if you could submit an issue at ${REPO} with the details to tackle in future, as some errors may be due to external/already present dependencies"
      err_exit
    fi
  elif [[ "${OS_ID}" =~ rhel ]] || [[ "${DISTRO}" =~ Fedora ]]; then
    #CentOS/RHEL/Fedora
    echo "Using yum to prepare packages for ${DISTRO} system"
    echo "  Updating system packages..."
    $sudo yum -y install curl > /dev/null
    $sudo yum -y update > /dev/null
    echo "  Installing missing prerequisite packages, if any.."
    pkg_list="python3 coreutils pkgconfig libffi-devel gmp-devel openssl-devel ncurses-libs ncurses-compat-libs systemd systemd-devel libsodium-devel zlib-devel make gcc-c++ tmux git jq gnupg libtool autoconf srm iproute bc tcptraceroute dialog sqlite libsqlite3x-devel"
    [[ ! "${DISTRO}" =~ Fedora ]] && $sudo yum -y install epel-release > /dev/null
    $sudo yum -y install ${pkg_list} > /dev/null;rc=$?
    if [ $rc != 0 ]; then
      echo "An error occurred while installing the prerequisite packages, please investigate by using the command below:"
      echo "sudo yum -y install ${pkg_list}"
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
  else
    echo "We have no automated procedures for this ${DISTRO} system"
    echo "please manually install required packages."
    echo "Their relative names are:"
    echo "Debian: curl build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev libsystemd-dev zlib1g-dev tmux"
    echo "CentOS: curl pkgconfig libffi-devel gmp-devel openssl-devel ncurses-libs ncurses-compat-libs systemd-devel zlib-devel tmux"
    err_exit
  fi
  ghc_v=$(ghc --version | grep 8\.6\.5 2>/dev/null)
  cabal_v=$(cabal --version | grep version\ 3 2>/dev/null)
  if [ "${ghc_v}" = "" ] || [ "${cabal_v}" = "" ]; then
    echo "Install ghcup (The Haskell Toolchain installer) .."
    # TMP: Dirty hack to prevent ghcup interactive setup, yet allow profile set up
    unset BOOTSTRAP_HASKELL_NONINTERACTIVE
    export BOOTSTRAP_HASKELL_NO_UPGRADE=1
    curl -s -m ${CURL_TIMEOUT} --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sed -e 's#read.*#answer=Y;next_answer=Y;hls_answer=N#' | bash
    # shellcheck source=/dev/null
    . ~/.ghcup/env

    ghcup install 8.6.5
    ghcup set 8.6.5
    ghc --version

    echo "Installing bundled Cabal .."
    ghcup install-cabal
  fi
fi

if [ ! -d ~/.cabal/bin ]; then mkdir -p ~/.cabal/bin; fi

# END OF Install build deps.

echo "Creating Folder Structure .."

if grep -q "${CNODE_VNAME}_HOME" ~/.bashrc; then
  echo "Environment Variable already set up!"
else
  echo "Setting up Environment Variable"
  echo "export ${CNODE_VNAME}_HOME=${CNODE_HOME}" >> ~/.bashrc
  # shellcheck source=/dev/null
  . "${HOME}/.bashrc"
fi

mkdir -p "${HOME}/git" > /dev/null 2>&1 # To hold git repositories that will be used for building binaries

if [[ "${LIBSODIUM_FORK}" = "Y" ]]; then
  if ! grep -q "/usr/local/lib:\$LD_LIBRARY_PATH" ~/.bashrc; then
    echo "export LD_LIBRARY_PATH=/usr/local/lib:\$LD_LIBRARY_PATH" >> ~/.bashrc
  fi
  pushd "${HOME}"/git >/dev/null || err_exit
  git clone https://github.com/input-output-hk/libsodium &>/dev/null
  pushd libsodium >/dev/null || err_exit
  git checkout 66f017f1 &>/dev/null
  ./autogen.sh > autogen.log > /tmp/libsodium.log 2>&1
  ./configure > configure.log >> /tmp/libsodium.log 2>&1
  make > make.log 2>&1
  $sudo make install > install.log 2>&1
fi

if [[ "${INSTALL_CNCLI}" = "Y" ]]; then
  [[ ! -f /usr/local/lib/libsodium.so ]] && err_exit "IOG fork of libsodium is a pre-requisite for CNCLI, run '$(basename "$0") -h' to list available options"
  if command -v cncli >/dev/null; then cncli_version="$(cncli -V | cut -d' ' -f2)"; else cncli_version=""; fi
  pushd "${HOME}"/git >/dev/null || err_exit
  if [[ -d ./cncli ]]; then
    echo "previous CNCLI installation found, pulling latest version from GitHub..."
    pushd ./cncli >/dev/null || err_exit
    if ! output=$(git pull 2>&1); then echo -e "${output}" && err_exit; fi
  else
    echo "downloading CNCLI..."
    if ! output=$(git clone https://github.com/AndrewWestberg/cncli.git 2>&1); then echo -e "${output}" && err_exit; fi
    pushd ./cncli >/dev/null || err_exit
  fi
  cncli_git_version=$(awk -F ' = ' '$1 ~ /version/ { gsub(/[\"]/, "", $2); printf("%s",$2) }' Cargo.toml)
  if [[ "${cncli_version}" != "${cncli_git_version}" ]]; then
    # install rust if not available
    if ! command -v "rustup" &>/dev/null; then
      echo "installing RUST..."
      if ! output=$(curl https://sh.rustup.rs -sSf | sh -s -- -y 2>&1); then echo -e "${output}" && err_exit; fi
    else
      echo "updating RUST if needed..."
      rustup update &>/dev/null #ignore any errors, not crucial that update succeed
    fi
    if ! output=$(cargo install --path . --force 2>&1); then echo -e "${output}" && err_exit; fi
    . "${HOME}"/.profile # source profile to load ${HOME}/.cargo/bin into PATH
    echo "$(cncli -V) installed!"
  else
    echo "CNCLI already latest version [${cncli_version}], skipping!"
  fi
fi

$sudo mkdir -p "${CNODE_HOME}"/files "${CNODE_HOME}"/db "${CNODE_HOME}"/guild-db "${CNODE_HOME}"/logs "${CNODE_HOME}"/scripts "${CNODE_HOME}"/sockets "${CNODE_HOME}"/priv
$sudo chown -R "$U_ID":"$G_ID" "${CNODE_HOME}" 2>/dev/null

echo "Downloading files..."

URL_RAW="${REPO_RAW}/${BRANCH}"
pushd "${CNODE_HOME}"/files >/dev/null || err_exit
curl -s -m ${CURL_TIMEOUT} -o config.json.tmp ${URL_RAW}/files/config-combinator.json 2>/dev/null

if grep -i '404: Not Found' config.json.tmp >/dev/null ; then
  err_exit "ERROR!! Specified branch could not be found! Kindly re-check the branch name and internet connection from the server"
else
  echo "${BRANCH}" > "${CNODE_HOME}"/scripts/.env_branch
fi

if [[ ${NETWORK} = "testnet" ]]; then
  curl -sL -m ${CURL_TIMEOUT} -o byron-genesis.json.tmp https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/testnet-byron-genesis.json
  curl -sL -m ${CURL_TIMEOUT} -o genesis.json.tmp https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/testnet-shelley-genesis.json
  curl -sL -m ${CURL_TIMEOUT} -o topology.json.tmp https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/testnet-topology.json
  curl -s -m ${CURL_TIMEOUT} -o config.json.tmp ${URL_RAW}/files/config-combinator.json
elif [[ ${NETWORK} = "guild" ]]; then
  curl -s -m ${CURL_TIMEOUT} -o byron-genesis.json.tmp ${URL_RAW}/files/byron-genesis.json
  curl -s -m ${CURL_TIMEOUT} -o genesis.json.tmp ${URL_RAW}/files/genesis.json
  curl -s -m ${CURL_TIMEOUT} -o topology.json.tmp ${URL_RAW}/files/topology.json
  curl -s -m ${CURL_TIMEOUT} -o config.json.tmp ${URL_RAW}/files/config-praos.json
else
  curl -sL -m ${CURL_TIMEOUT} -o byron-genesis.json.tmp https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/mainnet-byron-genesis.json
  curl -sL -m ${CURL_TIMEOUT} -o genesis.json.tmp https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/mainnet-shelley-genesis.json
  curl -sL -m ${CURL_TIMEOUT} -o topology.json.tmp https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/mainnet-topology.json
  curl -s -m ${CURL_TIMEOUT} -o config.json.tmp ${URL_RAW}/files/config-mainnet.json
fi
sed -e "s@/opt/cardano/cnode@${CNODE_HOME}@g" -i ./*.json.tmp
[[ ${FORCE_OVERWRITE} = 'Y' && -f topology.json ]] && cp -f topology.json "topology.json_bkp$(date +%s)"
[[ ${FORCE_OVERWRITE} = 'Y' && -f config.json ]] && cp -f config.json "config.json_bkp$(date +%s)"
if [[ ${FORCE_OVERWRITE} = 'Y' || ! -f byron-genesis.json ]]; then mv -f byron-genesis.json.tmp byron-genesis.json; else rm -f byron-genesis.json.tmp; fi
if [[ ${FORCE_OVERWRITE} = 'Y' || ! -f genesis.json ]]; then mv -f genesis.json.tmp genesis.json; else rm -f genesis.json.tmp; fi
if [[ ${FORCE_OVERWRITE} = 'Y' || ! -f topology.json ]]; then mv -f topology.json.tmp topology.json; else rm -f topology.json.tmp; fi
if [[ ${FORCE_OVERWRITE} = 'Y' || ! -f config.json ]]; then mv -f config.json.tmp config.json; else rm -f config.json.tmp; fi

pushd "${CNODE_HOME}"/scripts >/dev/null || err_exit
curl -s -m ${CURL_TIMEOUT} -o env.tmp ${URL_RAW}/scripts/cnode-helper-scripts/env
curl -s -m ${CURL_TIMEOUT} -o createAddr.sh ${URL_RAW}/scripts/cnode-helper-scripts/createAddr.sh
curl -s -m ${CURL_TIMEOUT} -o sendADA.sh ${URL_RAW}/scripts/cnode-helper-scripts/sendADA.sh
curl -s -m ${CURL_TIMEOUT} -o balance.sh ${URL_RAW}/scripts/cnode-helper-scripts/balance.sh
curl -s -m ${CURL_TIMEOUT} -o rotatePoolKeys.sh ${URL_RAW}/scripts/cnode-helper-scripts/rotatePoolKeys.sh
curl -s -m ${CURL_TIMEOUT} -o cnode.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/cnode.sh
curl -s -m ${CURL_TIMEOUT} -o cntools.sh ${URL_RAW}/scripts/cnode-helper-scripts/cntools.sh
curl -s -m ${CURL_TIMEOUT} -o cntools.config.tmp ${URL_RAW}/scripts/cnode-helper-scripts/cntools.config
curl -s -m ${CURL_TIMEOUT} -o cntools.library ${URL_RAW}/scripts/cnode-helper-scripts/cntools.library
curl -s -m ${CURL_TIMEOUT} -o logMonitor.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/logMonitor.sh
curl -s -m ${CURL_TIMEOUT} -o setup_mon.sh ${URL_RAW}/scripts/cnode-helper-scripts/setup_mon.sh
curl -s -m ${CURL_TIMEOUT} -o topologyUpdater.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/topologyUpdater.sh
curl -s -m ${CURL_TIMEOUT} -o itnRewards.sh ${URL_RAW}/scripts/cnode-helper-scripts/itnRewards.sh
curl -s -m ${CURL_TIMEOUT} -o cabal-build-all.sh ${URL_RAW}/scripts/cnode-helper-scripts/cabal-build-all.sh
curl -s -m ${CURL_TIMEOUT} -o stack-build.sh ${URL_RAW}/scripts/cnode-helper-scripts/stack-build.sh
curl -s -m ${CURL_TIMEOUT} -o system-info.sh ${URL_RAW}/scripts/cnode-helper-scripts/system-info.sh
curl -s -m ${CURL_TIMEOUT} -o sLiveView.sh ${URL_RAW}/scripts/cnode-helper-scripts/sLiveView.sh
curl -s -m ${CURL_TIMEOUT} -o gLiveView.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/gLiveView.sh
curl -s -m ${CURL_TIMEOUT} -o deploy-as-systemd.sh ${URL_RAW}/scripts/cnode-helper-scripts/deploy-as-systemd.sh
curl -s -m ${CURL_TIMEOUT} -o cncli.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/cncli.sh
sed -e "s@%vname%@${CNODE_NAME}@g" -i deploy-as-systemd.sh
sed -e "s@/opt/cardano/cnode@${CNODE_HOME}@g" -e "s@CNODE_HOME@${CNODE_VNAME}_HOME@g" -i ./*.*

### Update file retaining existing custom configs
updateWithCustomConfig() {
  file=$1
  if [[ -f ${file} && ${FORCE_OVERWRITE} = 'N' ]]; then
    if grep '^# Do NOT modify' ${file} >/dev/null 2>&1; then
      TEMPL_CMD=$(awk '/^# Do NOT modify/,0' ${file}.tmp)
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

[[ ${FORCE_OVERWRITE} = 'Y' ]] && echo "Forced full upgrade! Please edit scripts/env, scripts/cnode.sh, scripts/gLiveView.sh and scripts/topologyUpdater.sh (alongwith files/topology.json, files/config.json) as required/"

updateWithCustomConfig "env"
updateWithCustomConfig "cnode.sh"
updateWithCustomConfig "gLiveView.sh"
updateWithCustomConfig "topologyUpdater.sh"
updateWithCustomConfig "cntools.config"
updateWithCustomConfig "logMonitor.sh"
updateWithCustomConfig "cncli.sh"

chmod -R 755 "${CNODE_HOME}"
chmod -R 700 "${CNODE_HOME}"/priv 2>/dev/null

pushd -0 >/dev/null || err_exit; dirs -c
