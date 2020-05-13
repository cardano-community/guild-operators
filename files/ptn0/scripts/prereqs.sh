#!/bin/sh

# For who runs the script within containers and running it as root.
SUDO="Y";
if [ "${SUDO}" = "Y" ] || [ "${SUDO}" = "y" ] ; then sudo="sudo"; else sudo="" ; fi

# Variables
export CNODE_HOME=/opt/cardano/cnode

# Determine OS platform
OS_ID=$(grep -i ^id_like= /etc/os-release | cut -d= -f 2)
DISTRO=$(grep -i ^NAME= /etc/os-release | cut -d= -f 2)

if [ -z "${OS_ID##*debian*}" ]; then
  #Debian/Ubuntu
  echo "Using apt to prepare packages for ${DISTRO} system"
  sleep 2
  $sudo apt-get -y install curl
  curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | $sudo apt-key add -
  echo "deb https://dl.yarnpkg.com/debian/ stable main" | $sudo tee /etc/apt/sources.list.d/yarn.list
  $sudo apt-get update
  $sudo apt-get -y install python3 build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev libsystemd-dev zlib1g-dev npm yarn make g++ tmux git jq wget libncursesw5
elif [ -z "${OS_ID##*rhel*}" ]; then
  #CentOS/RHEL/Fedora
  echo "USING yum to prepare packages for ${DISTRO} system"
  $sudo yum -y install curl
  curl --silent --location https://dl.yarnpkg.com/rpm/yarn.repo | $sudo tee /etc/yum.repos.d/yarn.repo
  $sudo rpm --import https://dl.yarnpkg.com/rpm/pubkey.gpg
  $sudo yum update
  $sudo yum -y install python3 pkgconfig libffi-devel gmp-devel openssl-devel ncurses-libs systemd-devel zlib-devel npm yarn make gcc-c++ tmux git wget epel-release jq
  if [ -f /usr/lib64/libtinfo.so ] && [ -f /usr/lib64/libtinfo.so.5 ]; then
    echo "ncurse libs already set up, skipping symlink.."
  else
    $sudo ln -s "$(find /usr/lib64/libtinfo.so* | tail -1)" /usr/lib64/libtinfo.so
    $sudo ln -s "$(find /usr/lib64/libtinfo.so* | tail -1)" /usr/lib64/libtinfo.so.5
  fi
else
  echo "We have no automated procedures for this ${DISTRO} system"
  echo "please manually install required packages."
  echo "Their relative names are:"
  echo "Debian: curl build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev libsystemd-dev zlib1g-dev tmux"
  echo "CentOS: curl pkgconfig libffi-devel gmp-devel openssl-devel ncurses-libs systemd-devel zlib-devel tmux"
  exit;
fi

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

echo "Installing Cabal 3.2.0 .."

wget https://downloads.haskell.org/~cabal/cabal-install-3.2.0.0/cabal-install-3.2.0.0-x86_64-unknown-linux.tar.xz
tar xf cabal-install-3.2.0.0-x86_64-unknown-linux.tar.xz
chmod 755 cabal
mkdir -p ~/.cabal/bin
mv cabal ~/.ghcup/bin
rm -f cabal-install-3.2.0.0-x86_64-unknown-linux.tar.xz cabal.sig

echo "Creating Folder Structure .."

if grep -q CNODE_HOME ~/.bashrc; then
  echo "Environment Variable already set up!"
else
  echo "Setting up Environment Variable"
  echo "export CNODE_HOME=${CNODE_HOME}" >> ~/.bashrc
  # shellcheck source=/dev/null
  . "${HOME}/.bashrc"
fi
$sudo mkdir -p $CNODE_HOME/files $CNODE_HOME/db $CNODE_HOME/logs $CNODE_HOME/scripts $CNODE_HOME/sockets $CNODE_HOME/priv
$sudo chown -R "$USER":"$USER" "$CNODE_HOME"
chmod -R 755 "$CNODE_HOME"

mkdir ~/git # To hold git repositories that will be used for building binaries

cd "$CNODE_HOME/files" || return

curl -s -o ptn0.yaml https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/files/ptn0.yaml
curl -s https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/files/genesis.json | jq '.' > genesis.json
curl -s https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/files/topology.json | jq '.' > topology.json

# If using a different CNODE_HOME than in this example, execute the below:
# sed -i -e "s#/opt/cardano/cnode#${CNODE_HOME}#" $CNODE_HOME/files/ptn0.yaml
## For future use:
## It generates random NodeID:
## -e "s#NodeId:.*#NodeId:`od -A n -t u8 -N 8 /dev/urandom`#" \

cd $CNODE_HOME/scripts || return
curl -s -o env https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/env
curl -s -o createAddr.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/createAddr.sh
curl -s -o sendADA.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/sendADA.sh
curl -s -o cnode.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/scripts/cnode.sh.templ
curl -s -o cabal-build-all.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/scripts/cabal-build-all.sh
curl -s -o stack-build.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/scripts/stack-build.sh
curl -s -o system-info.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/scripts/system-info.sh
curl -s -o $CNODE_HOME/priv/delegate.counter https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/ptn0/files/delegate.counter
chmod 755 ./*.sh
# If you opt for an alternate CNODE_HOME, please run the below:
# sed -i -e "s#/opt/cardano/cnode#${CNODE_HOME}#" *.sh
cd - || return
