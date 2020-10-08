#!/bin/bash
# shellcheck disable=SC2086

unset CNODE_HOME
REPO="https://github.com/cardano-community/guild-operators"
REPO_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators"
BRANCH="master"
URL_RAW="${REPO_RAW}/${BRANCH}"

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
  printf "%s\nExiting..." "$*" >&2
  exit 1
}

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") [-o] [-f] [-s] [-i] [-n <testnet|guild>] [-t <name>] [-m <seconds>]
Install pre-requisites for building cardano node and using CNTools

-o    Do *NOT* overwrite existing genesis.json, topology.json, config.json, cntools.config and topology-updater.sh files (Default: will overwrite)
-f    Force overwrite of all files including normally saved user config sections in env, cnode.sh and gLiveView.sh
      '-o' and '-f' are independent of each other, and can be used together
-s    Skip installing OS level dependencies (Default: will check and install any missing OS level prerequisites)
-i    Interactive mode (Default: silent mode)
-n    Connect to specified network instead of public network (Default: connect to public cardano network)
-t    Alternate name for top level folder (Default: cnode)
-m    Maximum time in seconds that you allow the file download operation to take before aborting (Default: 10s)
EOF
  exit 1
}

WANT_BUILD_DEPS='Y'
OVERWRITE=''

while getopts :in:soft:m: opt; do
  case ${opt} in
    i ) INTERACTIVE='Y' ;;
    n ) NETWORK=${OPTARG}
    s ) WANT_BUILD_DEPS='N' ;;
    o ) OVERWRITE='-C -' ;;
    f ) FORCE_OVERWRITE='Y' ;;
    t ) CNODE_NAME=${OPTARG} ;;
    m ) CURL_TIMEOUT=${OPTARG} ;;
    \? ) usage ;;
    esac
done
shift $((OPTIND -1))

# For who runs the script within containers and running it as root.
U_ID=$(id -u)
G_ID=$(id -g)

# Defaults
CNODE_PATH="/opt/cardano"
[[ -z "${CNODE_NAME}" ]] && CNODE_NAME="cnode"
CNODE_HOME=${CNODE_PATH}/${CNODE_NAME}
CNODE_VNAME=$(echo "$CNODE_NAME" | awk '{print toupper($0)}')
[[ -z ${CURL_TIMEOUT} ]] && CURL_TIMEOUT=10

#if [ $(id -u$( -eq 0 ]; then
#  err_exit "Please run as non-root user."
#fi

SUDO="Y";
if [ "${SUDO}" = "Y" ] || [ "${SUDO}" = "y" ] ; then sudo="sudo"; else sudo="" ; fi

if [ "$INTERACTIVE" = 'Y' ]; then
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
    pkg_list="libpq-dev python3 build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev systemd libsystemd-dev libsodium-dev zlib1g-dev make g++ tmux git jq libncursesw5 gnupg aptitude libtool autoconf secure-delete iproute2 bc tcptraceroute dialog shasum"
    $sudo apt-get -y install ${pkg_list} > /dev/null;rc=$?
    if [ $rc != 0 ]; then
      echo "An error occurred while installing the prerequisite packages, please investigate by using the command below:"
      echo "sudo apt-get -y install ${pkg_list}"
      echo "It would be best if you could submit an issue at ${REPO} with the details to tackle in future, as some errors may be due to external/already present dependencies"
      exit;
    fi
  elif [[ "${OS_ID}" =~ rhel ]] || [[ "${DISTRO}" =~ Fedora ]]; then
    #CentOS/RHEL/Fedora
    echo "Using yum to prepare packages for ${DISTRO} system"
    echo "  Updating system packages..."
    $sudo yum -y install curl > /dev/null
    $sudo yum -y update > /dev/null
    echo "  Installing missing prerequisite packages, if any.."
    pkg_list="python3 coreutils pkgconfig libffi-devel gmp-devel openssl-devel ncurses-libs ncurses-compat-libs systemd systemd-devel libsodium-devel zlib-devel make gcc-c++ tmux git jq gnupg libtool autoconf srm iproute bc tcptraceroute dialog shasum"
    [[ ! "${DISTRO}" =~ Fedora ]] && $sudo yum -y install epel-release > /dev/null
    $sudo yum -y install ${pkg_list} > /dev/null;rc=$?
    if [ $rc != 0 ]; then
      echo "An error occurred while installing the prerequisite packages, please investigate by using the command below:"
      echo "sudo yum -y install ${pkg_list}"
      echo "It would be best if you could submit an issue at ${REPO} with the details to tackle in future, as some errors may be due to external/already present dependencies"
      exit;
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
    exit;
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

mkdir "${HOME}/git" > /dev/null 2>&1 # To hold git repositories that will be used for building binaries

# This part is commented out as if-and-when libsodium at system causes a conflict with fork, IOHK would need to fix this in a more acceptable manner.

# if grep -q "/usr/local/lib:$LD_LIBRARY_PATH" ~/.bashrc; then
#   echo "Load Library Paths already set up!"
# else
#   echo "export LD_LIBRARY_PATH=/usr/lib64\:\$LD_LIBRARY_PATH" >> ~/.bashrc
#   cd "$HOME/git" || return
#   git clone https://github.com/input-output-hk/libsodium >/dev/null 2>&1
#   cd libsodium
#   git checkout 66f017f1
#   ./autogen.sh > autogen.log 2&1
#   ./configure > configure.log 2&1
#   make > make.log 2>&1
#   $sudo make install > install.log 2>&1
# fi

$sudo mkdir -p "$CNODE_HOME"/files "$CNODE_HOME"/db "$CNODE_HOME"/logs "$CNODE_HOME"/scripts "$CNODE_HOME"/sockets "$CNODE_HOME"/priv
$sudo chown -R "$U_ID":"$G_ID" "$CNODE_HOME"
chmod -R 755 "$CNODE_HOME"
chmod -R 700 "$CNODE_HOME/priv"

cd "$CNODE_HOME/files" || return
[[ -z ${OVERWRITE} && -f topology.json ]] && cp -f topology.json "topology.json_bkp$(date +%s)"
[[ -z ${OVERWRITE} && -f config.json ]] && cp -f config.json "config.json_bkp$(date +%s)"
if [[ ${NETWORK} = "testnet" ]]; then
  curl -sL -m ${CURL_TIMEOUT} -o byron-genesis.json ${OVERWRITE} https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/mainnet-byron-genesis.json
  curl -sL -m ${CURL_TIMEOUT} -o genesis.json ${OVERWRITE} https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/mainnet-shelley-genesis.json
  curl -sL -m ${CURL_TIMEOUT} -o topology.json ${OVERWRITE} https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/mainnet-topology.json
  curl -s -m ${CURL_TIMEOUT} -o config.json ${OVERWRITE} ${URL_RAW}/files/config-testnet.json
elif [[ ${NETWORK} = "guild" ]]; then
  curl -s -m ${CURL_TIMEOUT} -o genesis.json ${OVERWRITE} ${URL_RAW}/files/genesis.json
  curl -s -m ${CURL_TIMEOUT} -o byron-genesis.json ${OVERWRITE} ${URL_RAW}/files/byron-genesis.json
  curl -s -m ${CURL_TIMEOUT} -o topology.json ${OVERWRITE} ${URL_RAW}/files/topology.json
  curl -s -m ${CURL_TIMEOUT} -o config.json ${OVERWRITE} ${URL_RAW}/files/config-guild.json
else
  curl -sL -m ${CURL_TIMEOUT} -o byron-genesis.json ${OVERWRITE} https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/mainnet-byron-genesis.json
  curl -sL -m ${CURL_TIMEOUT} -o genesis.json ${OVERWRITE} https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/mainnet-shelley-genesis.json
  curl -sL -m ${CURL_TIMEOUT} -o topology.json ${OVERWRITE} https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/mainnet-topology.json
  curl -s -m ${CURL_TIMEOUT} -o config.json ${OVERWRITE} ${URL_RAW}/files/config-mainnet.json
fi
sed -i -e "s#/opt/cardano/cnode#${CNODE_HOME}#" $CNODE_HOME/files/*.json

cd "${CNODE_HOME}"/scripts || return
curl -s -m ${CURL_TIMEOUT} -o env.tmp ${URL_RAW}/scripts/cnode-helper-scripts/env
curl -s -m ${CURL_TIMEOUT} -o createAddr.sh ${URL_RAW}/scripts/cnode-helper-scripts/createAddr.sh
curl -s -m ${CURL_TIMEOUT} -o sendADA.sh ${URL_RAW}/scripts/cnode-helper-scripts/sendADA.sh
curl -s -m ${CURL_TIMEOUT} -o balance.sh ${URL_RAW}/scripts/cnode-helper-scripts/balance.sh
curl -s -m ${CURL_TIMEOUT} -o rotatePoolKeys.sh ${URL_RAW}/scripts/cnode-helper-scripts/rotatePoolKeys.sh
curl -s -m ${CURL_TIMEOUT} -o cnode.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/cnode.sh
curl -s -m ${CURL_TIMEOUT} -o cntools.sh ${URL_RAW}/scripts/cnode-helper-scripts/cntools.sh
curl -s -m ${CURL_TIMEOUT} -o cntools.config ${OVERWRITE} ${URL_RAW}/scripts/cnode-helper-scripts/cntools.config
curl -s -m ${CURL_TIMEOUT} -o cntools.library ${URL_RAW}/scripts/cnode-helper-scripts/cntools.library
curl -s -m ${CURL_TIMEOUT} -o cntoolsBlockCollector.sh ${URL_RAW}/scripts/cnode-helper-scripts/cntoolsBlockCollector.sh
curl -s -m ${CURL_TIMEOUT} -o setup_mon.sh ${URL_RAW}/scripts/cnode-helper-scripts/setup_mon.sh
[[ -z ${OVERWRITE} && -f topologyUpdater.sh ]] && cp -f topologyUpdater.sh "topologyUpdater.sh_bkp$(date +%s)"
curl -s -m ${CURL_TIMEOUT} -o topologyUpdater.sh ${OVERWRITE} ${URL_RAW}/scripts/cnode-helper-scripts/topologyUpdater.sh
curl -s -m ${CURL_TIMEOUT} -o itnRewards.sh ${URL_RAW}/scripts/cnode-helper-scripts/itnRewards.sh
curl -s -m ${CURL_TIMEOUT} -o cabal-build-all.sh ${URL_RAW}/scripts/cnode-helper-scripts/cabal-build-all.sh
curl -s -m ${CURL_TIMEOUT} -o stack-build.sh ${URL_RAW}/scripts/cnode-helper-scripts/stack-build.sh
curl -s -m ${CURL_TIMEOUT} -o system-info.sh ${URL_RAW}/scripts/cnode-helper-scripts/system-info.sh
curl -s -m ${CURL_TIMEOUT} -o sLiveView.sh ${URL_RAW}/scripts/cnode-helper-scripts/sLiveView.sh
curl -s -m ${CURL_TIMEOUT} -o gLiveView.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/gLiveView.sh
curl -s -m ${CURL_TIMEOUT} -o deploy-as-systemd.sh ${URL_RAW}/scripts/cnode-helper-scripts/deploy-as-systemd.sh
sed -e "s@SyslogIdentifier=.*@SyslogIdentifier=${CNODE_NAME}@g" -e "s@cnode.service@${CNODE_NAME}.service@g" -i deploy-as-systemd.sh
sed -e "s@CNODE_HOME=[^ ]*\\(.*\\)@${CNODE_VNAME}_HOME=\"${CNODE_HOME}\"\\1@g" -e "s@CNODE_HOME@${CNODE_VNAME}_HOME@g" -i ./*.*

### Update file retaining existing custom configs
updateWithCustomConfig() {
  file=$1
  [[ -f ${file} ]] && cp -f ${file} "${file}.bkp_$(date +%s)"
  if [[ ${FORCE_OVERWRITE} = 'Y' ]]; then
    echo "Forced full upgrade! Please edit ${file} for User Variables"
  elif grep '^# Do NOT modify' ${file}.tmp >/dev/null 2>&1; then
    TEMPL_CMD=$(awk '/^# Do NOT modify/,0' ${file}.tmp)
    STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' ${file})
    printf '%s\n%s\n' "${STATIC_CMD}" "${TEMPL_CMD}" > ${file}.tmp
  fi
  mv -f ${file}.tmp ${file}
}

updateWithCustomConfig "env"
updateWithCustomConfig "cnode.sh"
updateWithCustomConfig "gLiveView.sh"

chmod 755 ./*.sh

cd - || return
