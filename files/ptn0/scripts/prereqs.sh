#!/bin/sh

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
Usage: $(basename "$0") [-i]
Install pre-requisites for 'cardano-node'

-i                  Interactive mode
EOF
  exit 1
}

while getopts "i" opt
do
  case "$opt" in
    i)
      INTERACTIVE='Y'
      ;;
    *)
      usage
      ;;
    esac
done

# For who runs the script within containers and running it as root.
U_ID=$(id -u)
G_ID=$(id -g)

# Defaults
CNODE_PATH="/opt/cardano"
CNODE_NAME="cnode"
CNODE_HOME=${CNODE_PATH}/${CNODE_NAME}
CNODE_VNAME=$(echo "$CNODE_NAME" | awk '{print toupper($0)}')

WANT_BUILD_DEPS='Y'

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

  if [ -z "${OS_ID##*debian*}" ]; then
    #Debian/Ubuntu
    echo "Using apt to prepare packages for ${DISTRO} system"
    echo "  Updating system packages..."
    $sudo apt-get -y install curl > /dev/null
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | $sudo apt-key add - > /dev/null
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | $sudo tee /etc/apt/sources.list.d/yarn.list > /dev/null
    $sudo apt-get -y update > /dev/null
    echo "  Installing missing prerequisite packages, if any.."
    $sudo apt-get -y install libpq-dev python3 build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev systemd libsystemd-dev libsodium-dev zlib1g-dev yarn make g++ tmux git jq wget libncursesw5 gnupg aptitude libtool autoconf > /dev/null;rc=$?
    if [ $rc != 0 ]; then
      echo "An error occurred while installing the prerequisite packages, please investigate by using the command below:"
      echo "sudo apt-get -y install python3 build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev systemd libsystemd-dev libsodium-dev zlib1g-dev npm yarn make g++ tmux git jq wget libncursesw5 gnupg libtool autoconf"
      echo "It would be best if you could submit an issue at https://github.com/cardano-community/guild-operators with the details to tackle in future, as some errors may be due to external/already present dependencies"
      exit;
    else
      $sudo aptitude install npm -yq > /dev/null
    fi
  elif [ -z "${OS_ID##*rhel*}" ]; then
    #CentOS/RHEL/Fedora
    echo "Using yum to prepare packages for ${DISTRO} system"
    echo "  Updating system packages..."
    $sudo yum -y install curl > /dev/null
    curl --silent --location https://dl.yarnpkg.com/rpm/yarn.repo | $sudo tee /etc/yum.repos.d/yarn.repo > /dev/null
    $sudo rpm --import https://dl.yarnpkg.com/rpm/pubkey.gpg > /dev/null
    $sudo yum -y update > /dev/null
    echo "  Installing missing prerequisite packages, if any.."
    $sudo yum -y install python3 coreutils pkgconfig libffi-devel gmp-devel openssl-devel ncurses-libs ncurses-compat-libs systemd systemd-devel libsodium-devel zlib-devel npm yarn make gcc-c++ tmux git wget epel-release jq gnupg libtool autoconf > /dev/null;rc=$?
    if [ $rc != 0 ]; then
      echo "An error occurred while installing the prerequisite packages, please investigate by using the command below:"
      echo "sudo yum -y install coreutils python3 pkgconfig libffi-devel gmp-devel openssl-devel ncurses-libs ncurses-compat-libs systemd systemd-devel libsodium-devel zlib-devel npm yarn make gcc-c++ tmux git wget epel-release jq gnupg libtool autoconf"
      echo "It would be best if you could submit an issue at https://github.com/cardano-community/guild-operators with the details to tackle in future, as some errors may be due to external/already present dependencies"
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
    curl -s --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sed -e 's#read.*#answer=Y;next_answer=Y#' | bash
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

cd "$CNODE_HOME/files" || return

curl -s -o ptn0.yaml https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/files/ptn0.yaml
curl -s -o ptn0-combinator.yaml https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/files/ptn0-combinator.yaml
curl -s https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/files/genesis.json | jq '.' > genesis.json
curl -s https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/files/topology.json | jq '.' > topology.json

# If using a different CNODE_HOME than in this example, execute the below:
# sed -i -e "s#/opt/cardano/cnode#${CNODE_HOME}#" $CNODE_HOME/files/ptn0.yaml
## For future use:
## It generates random NodeID:
## -e "s#NodeId:.*#NodeId:$(od -A n -t u8 -N 8 /dev/urandom$(#" \

cd "$CNODE_HOME"/scripts || return
curl -s -o env https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/env
sed -e "s@CNODE_HOME@${CNODE_VNAME}_HOME@g" -i env
curl -s -o createAddr.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/createAddr.sh
curl -s -o sendADA.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/sendADA.sh
curl -s -o balance.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/balance.sh
curl -s -o cnode.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/scripts/cnode.sh.templ
curl -s -o cntools.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.sh
curl -s -o cntools.config https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.config
curl -s -o cntools.library https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntools.library
curl -s -o cntoolsBlockCollector.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntoolsBlockCollector.sh
curl -s -o cntoolsUpdater.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/cntoolsUpdater.sh
curl -s -o setup_mon.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/setup_mon.sh
curl -s -o topologyUpdater.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/topologyUpdater.sh
sed -e "s@CNODE_HOME=.*@${CNODE_VNAME}_HOME=${CNODE_HOME}@g" -e "s@CNODE_HOME@${CNODE_VNAME}_HOME@g" -i cnode.sh
curl -s -o cabal-build-all.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/scripts/cabal-build-all.sh
curl -s -o stack-build.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/scripts/stack-build.sh
curl -s -o system-info.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/scripts/system-info.sh
curl -s -o "$CNODE_HOME"/priv/delegate.counter https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/files/delegate.counter
chmod 755 ./*.sh
# If you opt for an alternate CNODE_HOME, please run the below:
# sed -i -e "s#/opt/cardano/cnode#${CNODE_HOME}#" *.sh
cd - || return
