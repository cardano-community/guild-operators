#!/usr/bin/env bash
# shellcheck disable=SC2086,SC1090,SC2059,SC2016
# shellcheck source=/dev/null

unset CNODE_HOME

##########################################
# User Variables - Change as desired     #
# command line flags override set values #
##########################################
#G_ACCOUNT="cardano-community"    # Override github GUILD account if you forked the project
#NETWORK='mainnet'      # Connect to specified network instead of public network (Default: connect to public cardano network)
#WANT_BUILD_DEPS='Y'    # Skip installing OS level dependencies (Default: will check and install any missing OS level prerequisites)
#FORCE_OVERWRITE='N'    # Force overwrite of all files including normally saved user config sections in env, cnode.sh and gLiveView.sh
                        # topology.json, config.json and genesis files normally saved will also be overwritten
#LIBSODIUM_FORK='Y'     # Use IOG fork of libsodium instead of official repositories - Recommended as per IOG instructions (Default: IOG fork)
#INSTALL_CNCLI='N'      # Install/Upgrade and build CNCLI with RUST
#INSTALL_CWHCLI='N'       # Install/Upgrade Vacuumlabs cardano-hw-cli for hardware wallet support
#INSTALL_OGMIOS='N'     # Install Ogmios Server
#INSTALL_CSIGNER='N'    # Install/Upgrade Cardano Signer
#CNODE_NAME='cnode'     # Alternate name for top level folder, non alpha-numeric chars will be replaced with underscore (Default: cnode)
#CURL_TIMEOUT=60        # Maximum time in seconds that you allow the file download operation to take before aborting (Default: 60s)
#UPDATE_CHECK='Y'       # Check if there is an updated version of guild-deploy.sh script to download
#SUDO='Y'               # Used by docker builds to disable sudo, leave unchanged if unsure.
#SKIP_DBSYNC_DOWNLOAD='N' # When using -i d switch, used by docker builds or users who might not want to download dbsync binary
######################################
# Do NOT modify code below           #
######################################

PARENT="$(dirname $0)"

#get_input() {
#  printf "%s (default: %s): " "$1" "$2" >&2; read -r answer
#  if [ -z "$answer" ]; then echo "$2"; else echo "$answer"; fi
#}

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
  cat <<-EOF >&2
		
		Usage: $(basename "$0") [-n <mainnet|guild|preprod|preview|sanchonet>] [-p path] [-t <name>] [-b <branch>] [-u] [-s [p][b][l][m][f][d][c][o][w][x]]
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
		  f   Force overwrite entire content of scripts and config files (backups of existing ones will be created) (Default: skip)
		  d   Download latest (released) binaries for bech32, cardano-address, cardano-node, cardano-cli, cardano-db-sync and cardano-submit-api (Default: skip)
		  c   Install/Upgrade CNCLI binary (Default: skip)
		  o   Install/Upgrade Ogmios Server binary (Default: skip)
		  w   Install/Upgrade Cardano Hardware CLI (Default: skip)
		  x   Install/Upgrade Cardano Signer binary (Default: skip)
		
		EOF
  exit 1
}

# Set Default Environment Variables
set_defaults() {
  [[ -z ${G_ACCOUNT} ]] && G_ACCOUNT="cardano-community"
  [[ -z ${NETWORK} ]] && NETWORK='mainnet'
  [[ -z ${WANT_BUILD_DEPS} ]] && WANT_BUILD_DEPS='N'
  [[ -z ${FORCE_OVERWRITE} ]] && FORCE_OVERWRITE='N'
  [[ -z ${LIBSODIUM_FORK} ]] && LIBSODIUM_FORK='N'
  [[ -z ${INSTALL_MITHRIL} ]] && INSTALL_MITHRIL='N'
  [[ -z ${INSTALL_CNCLI} ]] && INSTALL_CNCLI='N'
  [[ -z ${INSTALL_CWHCLI} ]] && INSTALL_CWHCLI='N'
  [[ -z ${INSTALL_OGMIOS} ]] && INSTALL_OGMIOS='N'
  [[ -z ${INSTALL_CSIGNER} ]] && INSTALL_CSIGNER='N'
  [[ -z ${CNODE_PATH} ]] && CNODE_PATH="/opt/cardano"
  [[ -z ${CNODE_NAME} ]] && CNODE_NAME='cnode'
  [[ -z ${CURL_TIMEOUT} ]] && CURL_TIMEOUT=60
  [[ -z ${UPDATE_CHECK} ]] && UPDATE_CHECK='Y'
  [[ -z ${SKIP_DBSYNC_DOWNLOAD} ]] && SKIP_DBSYNC_DOWNLOAD='N'
  [[ -z ${SUDO} ]] && SUDO='Y'
  [[ -z "${BRANCH}" ]] && BRANCH="master"
  [[ "${SUDO}" = 'Y' ]] && sudo="sudo" || sudo=""
  [[ "${SUDO}" = 'Y' && $(id -u) -eq 0 ]] && err_exit "Please run as non-root user."
  CNODE_HOME="${CNODE_PATH}/${CNODE_NAME}"
  CNODE_VNAME=$(echo "$CNODE_NAME" | awk '{print toupper($0)}')
  CARDANO_NODE_VERSION="8.9.2"
  REPO="https://github.com/${G_ACCOUNT}/guild-operators"
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
    echo -e "\nWARN!! ${BRANCH} branch does not exist, falling back to master branch\n"
    BRANCH=master
    URL_RAW="${REPO_RAW}/${BRANCH}"
  fi
}

# Check and prompt/apply update for guild-deploy.sh itself
update_check() {
  if curl -s -f -m ${CURL_TIMEOUT} -o "${PARENT}"/guild-deploy.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/guild-deploy.sh 2>/dev/null; then
    TEMPL_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/guild-deploy.sh)
    TEMPL2_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/guild-deploy.sh.tmp)
    if [[ "$(echo ${TEMPL_CMD} | sha256sum)" != "$(echo ${TEMPL2_CMD} | sha256sum)" ]]; then
      cp "${PARENT}"/guild-deploy.sh "${PARENT}/guild-deploy.sh_bkp$(date +%s)"
      STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/guild-deploy.sh)
      printf '%s\n%s\n' "$STATIC_CMD" "$TEMPL2_CMD" > "${PARENT}"/guild-deploy.sh.tmp
      {
        mv -f "${PARENT}"/guild-deploy.sh.tmp "${PARENT}"/guild-deploy.sh && \
        chmod 755 "${PARENT}"/guild-deploy.sh && \
        echo -e "\nUpdate applied successfully, please run the script again!\n" && \
        exit 0; 
      } || {
        echo -e "Update failed!\n\nPlease manually download latest version of guild-deploy.sh script from GitHub" && \
        exit 1;
      }
    fi
  fi
  rm -f "${PARENT}"/guild-deploy.sh.tmp
}

# Initialise all variables
common_init() {
  dirs -c # clear dir stack
  set_defaults
  mkdir -p "${HOME}"/tmp
  [[ ! -d "${HOME}"/.local/bin ]] && mkdir -p "${HOME}"/.local/bin
  if ! grep -q '/.local/bin' "${HOME}"/.bashrc; then
    echo -e '\nexport PATH="${HOME}/.local/bin:${PATH}"' >> "${HOME}"/.bashrc
  fi
  NODE_DEPS="$(curl -sfL "${URL_RAW}"/files/node-deps.json)"
  BLST_REF="$(jq -r '."'${CARDANO_NODE_VERSION}'".blst' <<< ${NODE_DEPS})"
  SODIUM_REF="$(jq -r '."'${CARDANO_NODE_VERSION}'".secp256k1' <<< ${NODE_DEPS})"
  SECP256K1_REF="$(jq -r '."'${CARDANO_NODE_VERSION}'".sodium' <<< ${NODE_DEPS})"
}

### Update file retaining existing custom configs
updateWithCustomConfig() {
  file=$1
  [[ $# -ne 2 ]] && subdir="cnode-helper-scripts" || subdir=$2
  curl -s -f -m ${CURL_TIMEOUT} -o ${file}.tmp "${URL_RAW}/scripts/${subdir}/${file}"
  [[ ! -f ${file}.tmp ]] && err_exit "Failed to download '${file}' from GitHub"
  if [[ -f ${file} && ${FORCE_OVERWRITE} != 'Y' ]]; then
    if grep '^# Do NOT modify' ${file}.tmp >/dev/null 2>&1; then
      TEMPL_CMD=$(awk '/^# Do NOT modify/,0' ${file}.tmp)
      STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' ${file})
      printf '%s\n%s\n' "${STATIC_CMD}" "${TEMPL_CMD}" > ${file}.tmp
    else
      err_exit "Problems encountered while fetching \"${file}\" from Github, could be an issue with connectivity or Github site!"
      rm -f ${file}.tmp
      return
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
  echo -e "\n  Enabling epel repository..."
  ! grep -q ^epel <<< "$(yum repolist)" && $sudo yum ${3} install https://dl.fedoraproject.org/pub/epel/epel-release-latest-"${2}".noarch.rpm > /dev/null
}

# OS Dependencies
os_dependencies() {
  pkg_opts="-y"
  echo -e "\nPreparing OS dependency packages for ${DISTRO} system"
  echo -e "\n  Updating system packages..."
  if [[ "${OS_ID}" =~ ebian ]] || [[ "${OS_ID}" =~ buntu ]] || [[ "${DISTRO}" =~ ebian ]] || [[ "${DISTRO}" =~ buntu ]]; then
    #Debian/Ubuntu
    pkgmgrcmd="env NEEDRESTART_MODE=a env DEBIAN_FRONTEND=noninteractive env DEBIAN_PRIORITY=critical apt-get"
    pkg_list="python3 pkg-config libssl-dev libncursesw5 libtinfo-dev systemd libsystemd-dev libsodium-dev tmux git jq libtool bc gnupg aptitude libtool secure-delete iproute2 tcptraceroute sqlite3 bsdmainutils libusb-1.0-0-dev libudev-dev unzip llvm clang libnuma-dev libpq-dev build-essential libffi-dev libgmp-dev zlib1g-dev make g++ autoconf automake liblmdb-dev procps"
  elif [[ "${OS_ID}" =~ rhel ]] || [[ "${OS_ID}" =~ fedora ]] || [[ "${DISTRO}" =~ Fedora ]]; then
    #CentOS/RHEL/Fedora/RockyLinux
    pkgmgrcmd="yum"
    pkg_list="python3 coreutils ncurses-devel ncurses-libs openssl-devel systemd systemd-devel libsodium-devel tmux git jq gnupg2 libtool iproute bc traceroute sqlite util-linux xz wget unzip procps-ng llvm clang numactl-devel libffi-devel gmp-devel zlib-devel make gcc-c++ autoconf udev lmdb-devel"
    if [[ "${VERSION_ID}" == "2" ]] ; then
      #AmazonLinux2
      pkg_list="${pkg_list} libusb ncurses-compat-libs pkgconfig srm"
    elif [[ "${VERSION_ID}" =~ "8" ]] || [[ "${VERSION_ID}" =~ "9" ]]; then
      #RHEL/CentOS/RockyLinux 8/9
      pkg_opts="${pkg_opts} --allowerasing"
      if [[ "${DISTRO}" =~ Rocky ]]; then
        #RockyLinux 8/9
        pkg_list="${pkg_list} --enablerepo=devel,crb libusbx ncurses-compat-libs pkgconf-pkg-config"
      elif [[ "${DISTRO}" =~ "Red Hat" ]]; then
        pkg_list="${pkg_list} --enablerepo=codeready-builder-for-rhel-${VERSION_ID/.*/}-x86_64-rpms libusbx ncurses-compat-libs pkgconf-pkg-config"
      fi
    elif [[ "${DISTRO}" =~ Fedora ]]; then
      #Fedora
      pkg_opts="${pkg_opts} --allowerasing"
      pkg_list="${pkg_list} libusbx ncurses-compat-libs pkgconf-pkg-config srm"
    fi
    add_epel_repository "${DISTRO}" "${VERSION_ID}" "${pkg_opts}"
    if [ -f /usr/lib64/libtinfo.so ] && [ -f /usr/lib64/libtinfo.so.5 ]; then
      echo -e "\n  Symlink updates not required for ncurse libs, skipping.."
    else
      echo -e "\n  Updating symlinks for ncurse libs.."
      $sudo ln -s "$(find /usr/lib64/libtinfo.so* | tail -1)" /usr/lib64/libtinfo.so
      $sudo ln -s "$(find /usr/lib64/libtinfo.so* | tail -1)" /usr/lib64/libtinfo.so.5
    fi
  else
    echo -e "\nWe have no automated procedures for this ${DISTRO} system"
    err_exit
  fi
  $sudo ${pkgmgrcmd} ${pkg_opts} update > /dev/null;rc=$?
  if [[ $rc != 0 ]]; then
    echo -e "\nAn error occured while executing \"${pkgmgrcmd} ${pkg_opts} update\" which indicates an existing issue with your base OS, please investigate manually prior to running the script again"
    err_exit
  fi
  echo -e "\n  Installing missing prerequisite packages, if any.."
  $sudo ${pkgmgrcmd} ${pkg_opts} install ${pkg_list} > /dev/null;rc=$?
  if [[ $rc != 0 ]]; then
    echo -e "\nAn error occurred while installing the prerequisite packages, please investigate by using the command below:"
    echo -e "\n  $sudo ${pkgmgrcmd} ${pkg_opts} install ${pkg_list}"
    echo -e "\nIt would be best if you could submit an issue at ${REPO} with the details to tackle in future, as some errors may be due to external/already present dependencies"
    err_exit
  fi
  # Cannot verify the version and availability of libsecp256k1 package built previously, hence have to re-install each time
  echo -e "\n[Re]-Install libsecp256k1 ..."
  mkdir -p "${HOME}"/git > /dev/null 2>&1 # To hold git repositories that will be used for building binaries
  pushd "${HOME}"/git >/dev/null || err_exit
  [[ ! -d "./secp256k1" ]] && git clone https://github.com/bitcoin-core/secp256k1 &>/dev/null
  pushd secp256k1 >/dev/null || err_exit
  git fetch >/dev/null 2>&1
  [[ -z "${SECP256K1_REF}" ]] && SECP256K1_REF="ac83be33"
  git checkout ${SECP256K1_REF} &>/dev/null
  ./autogen.sh > autogen.log > /tmp/secp256k1.log 2>&1
  ./configure --enable-module-schnorrsig --enable-experimental > configure.log >> /tmp/secp256k1.log 2>&1
  make > make.log 2>&1 || err_exit " Could not complete \"make\" for libsecp256k1 package, please try to run it manually to diagnose!"
  make check >>make.log 2>&1
  $sudo make install > install.log 2>&1
  if ! grep -q "/usr/local/lib:\$LD_LIBRARY_PATH" "${HOME}"/.bashrc; then
    echo -e "\nexport LD_LIBRARY_PATH=/usr/local/lib:\$LD_LIBRARY_PATH" >> "${HOME}"/.bashrc
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
  fi
  echo -e "\nlibsecp256k1 installed to /usr/local/lib/"
  build_libblst
}

# Build Dependencies for cabal builds
build_dependencies() {
  echo -e "\nInstalling Haskell build/compiler dependencies (if missing)..."
  export BOOTSTRAP_HASKELL_NO_UPGRADE=1
  export BOOTSTRAP_HASKELL_GHC_VERSION=8.10.7
  export BOOTSTRAP_HASKELL_CABAL_VERSION=3.10.2.0
  if ! command -v ghcup &>/dev/null; then
    echo -e "\nInstalling ghcup (The Haskell Toolchain installer) .."
    BOOTSTRAP_HASKELL_NONINTERACTIVE=1
    BOOTSTRAP_HASKELL_INSTALL_STACK=1
    BOOTSTRAP_HASKELL_ADJUST_BASHRC=1
    unset BOOTSTRAP_HASKELL_INSTALL_HLS
    export BOOTSTRAP_HASKELL_NONINTERACTIVE BOOTSTRAP_HASKELL_INSTALL_STACK BOOTSTRAP_HASKELL_ADJUST_BASHRC
    curl -s -m ${CURL_TIMEOUT} --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | bash >/dev/null 2>&1
  fi
  [[ -f "${HOME}/.ghcup/env" ]] && source "${HOME}/.ghcup/env"
  if ! ghc --version 2>/dev/null | grep -q ${BOOTSTRAP_HASKELL_GHC_VERSION}; then
    echo -e "\nUpgrading ghcup .."
    ghcup upgrade 2>/dev/null
    echo -e "\n Installing GHC v${BOOTSTRAP_HASKELL_GHC_VERSION} .."
    ghcup install ghc ${BOOTSTRAP_HASKELL_GHC_VERSION} >/dev/null 2>&1 || err_exit " Executing \"ghcup install ghc ${BOOTSTRAP_HASKELL_GHC_VERSION}\" failed, please try to diagnose/execute it manually to diagnose!"
    ghcup set ghc ${BOOTSTRAP_HASKELL_GHC_VERSION} >/dev/null
  fi
  cabal_version=$(cabal --version 2>/dev/null | head -n 1 | cut -d' ' -f3)
  if [[ -z ${cabal_version} || ! ${cabal_version} = "${BOOTSTRAP_HASKELL_CABAL_VERSION}" ]]; then
    if [[ -n ${cabal_version} ]]; then
      echo -e "\n Uninstalling Cabal v${cabal_version} .."
      ghcup rm cabal ${cabal_version} 2>/dev/null
    fi
    echo -e "\n Installing Cabal v${BOOTSTRAP_HASKELL_CABAL_VERSION}.."
    ghcup install cabal ${BOOTSTRAP_HASKELL_CABAL_VERSION} >/dev/null 2>&1 || err_exit " Executing \"ghcup install cabal ${BOOTSTRAP_HASKELL_GHC_VERSION}\" failed, please try to diagnose/execute it manually to diagnose!"
  fi
}

# Build fork of libsodium
build_libsodium() {
  echo -e "\nBuilding libsodium ..."
  if ! grep -q "/usr/local/lib:\$LD_LIBRARY_PATH" "${HOME}"/.bashrc; then
    echo -e "\nexport LD_LIBRARY_PATH=/usr/local/lib:\$LD_LIBRARY_PATH" >> "${HOME}"/.bashrc
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
  fi
  pushd "${HOME}"/git >/dev/null || err_exit
  [[ ! -d "./libsodium" ]] && git clone https://github.com/intersectmbo/libsodium &>/dev/null
  pushd libsodium >/dev/null || err_exit
  git fetch >/dev/null 2>&1
  [[ -z "${SODIUM_REF}" ]] && SODIUM_REF="dbb48cc"
  git checkout "${SODIUM_REF}" &>/dev/null
  ./autogen.sh > autogen.log > /tmp/libsodium.log 2>&1
  ./configure > configure.log >> /tmp/libsodium.log 2>&1
  make > make.log 2>&1 || err_exit  " Could not complete \"make\" for libsodium package, please try to run it manually to diagnose!"
  $sudo make install > install.log 2>&1
  echo -e "\nIOG fork of libsodium installed to /usr/local/lib/"
}

build_libblst() {
  echo -e "\nBuilding BLST..."
  if ! grep -q "/usr/local/lib:\$LD_LIBRARY_PATH" "${HOME}"/.bashrc; then
    echo -e "\nexport LD_LIBRARY_PATH=/usr/local/lib:\$LD_LIBRARY_PATH" >> "${HOME}"/.bashrc
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
  fi
  pushd "${HOME}"/git >/dev/null || err_exit
  [[ ! -d "./blst" ]] && git clone https://github.com/supranational/blst &>/dev/null
  pushd blst >/dev/null || err_exit
  git fetch >/dev/null 2>&1
  [[ -z "${BLST_REF}" ]] && BLST_REF="v0.3.11"
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
		Version: 0.3.10
		Cflags: -I\${includedir}
		Libs: -L\${libdir} -lblst
		EOF
  [[ ! -d /usr/local/lib/pkgconfig ]] && $sudo mkdir -p /usr/local/lib/pkgconfig
  $sudo cp -f libblst.pc /usr/local/lib/pkgconfig/
  $sudo cp bindings/blst_aux.h bindings/blst.h bindings/blst.hpp  /usr/local/include/
  $sudo cp libblst.a /usr/local/lib
  $sudo chmod u=rw,go=r /usr/local/{lib/{libblst.a,pkgconfig/libblst.pc},include/{blst.{h,hpp},blst_aux.h}}
}

# Download cardano-node, cardano-cli, cardano-db-sync, bech32 and cardano-submit-api
# TODO: Replace these with self-hosted ones (potentially consider snapshots.koios.rest as upload destination for CI)
download_cnodebins() {
  [[ -z ${ARCH##*aarch64*} ]] && err_exit "  The build archives are not available for ARM, you might need to build them!"
  echo -e "\nDownloading binaries.."
  pushd "${HOME}"/tmp >/dev/null || err_exit
  echo -e "\n  Downloading Cardano Node archive created from GitHub.."
  rm -f cardano-node cardano-address
  curl -m 200 -sfL https://github.com/intersectmbo/cardano-node/releases/download/${CARDANO_NODE_VERSION}/cardano-node-${CARDANO_NODE_VERSION}-linux.tar.gz -o cnode.tar.gz || err_exit " Could not download cardano-node release ${CARDANO_NODE_VERSION} from GitHub!"
  tar zxf cnode.tar.gz --strip-components 2 ./bin/cardano-node ./bin/cardano-cli ./bin/cardano-submit-api ./bin/bech32 &>/dev/null
  rm -f cnode.tar.gz
  [[ -f cardano-node ]] || err_exit " cardano-node archive downloaded but binary (cardano-node) not found after extracting package!"
  echo -e "\n  Downloading Github release package for Cardano Wallet"
  curl -m 200 -sfL https://github.com/intersectmbo/cardano-addresses/releases/download/3.12.0/cardano-addresses-3.12.0-linux64.tar.gz -o caddress.tar.gz || err_exit " Could not download cardano-wallet's latest release archive from GitHub!"
  tar zxf caddress.tar.gz --strip-components 1 bin/cardano-address &>/dev/null
  rm -f caddress.tar.gz
  [[ -f cardano-address ]] || err_exit " cardano-address archive downloaded but binary (cardano-address) not found after extracting package!"
  if [[ "${SKIP_DBSYNC_DOWNLOAD}" == "N" ]]; then
    echo -e "\n  Downloading Cardano DB Sync archive created from GitHub.."

    # TODO: Replace CI Build artifact against 13.2.0.2 tag with release from github artefacts once available
    #curl -m 200 -sfL https://github.com/IntersectMBO/cardano-db-sync/releases/download/13.2.0.2/cardano-db-sync-13.2.0.1-linux.tar.gz -o cnodedbsync.tar.gz || err_exit "  Could not download cardano-db-sync release 13.2.0.2 from GitHub!"
    curl -m 200 -sfL https://ci.iog.io/build/3736263/download/1/cardano-db-sync-13.2.0.2-linux.tar.gz -o cnodedbsync.tar.gz || err_exit "  Could not download cardano-db-sync release 13.2.0.2 from GitHub!"
    tar zxf cnodedbsync.tar.gz --strip-components 1 ./cardano-db-sync &>/dev/null
    [[ -f cardano-db-sync ]] || err_exit " cardano-db-sync archive downloaded but binary (cardano-db-sync) not found after extracting package!"
    rm -f cnodedbsync.tar.gz
    mv -f -t "${HOME}"/.local/bin cardano-db-sync
  fi
  mv -f -t "${HOME}"/.local/bin cardano-node cardano-cli cardano-submit-api bech32 cardano-address
  chmod +x "${HOME}"/.local/bin/*
}

# Download CNCLI
download_cncli() {
  [[ -z ${ARCH##*aarch64*} ]] && err_exit "  The cncli pre-compiled binary is not available for ARM, you might need to build them!"
  echo -e "\nInstalling CNCLI.."
  if command -v cncli >/dev/null; then cncli_version="v$(cncli -V 2>/dev/null | cut -d' ' -f2)"; else cncli_version="v0.0.0"; fi
  cncli_git_version="$(curl -s https://api.github.com/repos/cardano-community/cncli/releases/latest | jq -r '.tag_name')"
  echo -e "\n  Downloading CNCLI..."
  rm -rf /tmp/cncli-bin && mkdir /tmp/cncli-bin
  pushd /tmp/cncli-bin >/dev/null || err_exit
  cncli_asset_url="$(curl -s https://api.github.com/repos/cardano-community/cncli/releases/latest | jq -r '.assets[].browser_download_url' | grep 'ubuntu22.*.linux-musl.tar.gz')"
  if curl -sL -f -m ${CURL_TIMEOUT} -o cncli.tar.gz ${cncli_asset_url}; then
    tar zxf cncli.tar.gz &>/dev/null
    rm -f cncli.tar.gz
    [[ -f cncli ]] || err_exit "CNCLI downloaded but binary (cncli) not found after extracting package!"
    [[ "${cncli_version}" = "v0.0.0" ]] && echo -e "\n latest_version: ${cncli_git_version}" || echo -e "\n installed version: ${cncli_version} | latest version: ${cncli_git_version}"
    chmod +x /tmp/cncli-bin/cncli
    mv -f /tmp/cncli-bin/cncli "${HOME}"/.local/bin/
    rm -f "${HOME}"/.cargo/bin/cncli # Remove duplicate file in $PATH (old convention)
    echo -e "\n cncli ${cncli_git_version} installed!"
  else
    err_exit "Download of latest release of CNCLI from GitHub failed! Please retry or install it manually."
  fi
}

# Download pre-build cardano-hw-cli binary and it's dependencies
download_cardanohwcli() {
  [[ -z ${ARCH##*aarch64*} ]] && err_exit "  The cardano-hw-cli pre-compiled binary is not available for ARM, you might need to build them!"
  echo -e "\nInstalling Vacuumlabs cardano-hw-cli"
  if command -v cardano-hw-cli >/dev/null; then vchc_version="$(cardano-hw-cli version 2>/dev/null | head -n 1 | cut -d' ' -f6)"; else vchc_version="0.0.0"; fi
  echo -e "\n  Downloading Vacuumlabs cardano-hw-cli..."
  rm -rf /tmp/chwcli-bin && mkdir -p /tmp/chwcli-bin
  pushd /tmp/chwcli-bin >/dev/null || err_exit
  rm -rf cardano-hw-cli*
  vchc_asset_url="$(curl -s https://api.github.com/repos/vacuumlabs/cardano-hw-cli/releases/latest | jq -r '.assets[].browser_download_url' | grep '_linux-x64.tar.gz')"
  if curl -sL -f -m ${CURL_TIMEOUT} -o cardano-hw-cli_linux-x64.tar.gz ${vchc_asset_url}; then
    tar zxf cardano-hw-cli_linux-x64.tar.gz &>/dev/null
    rm -f cardano-hw-cli_linux-x64.tar.gz
    [[ -f cardano-hw-cli/cardano-hw-cli ]] || err_exit "cardano-hw-cli downloaded but binary not found after extracting package!"
    vchc_git_version="$(cardano-hw-cli/cardano-hw-cli version 2>/dev/null | head -n 1 | cut -d' ' -f6)"
    if ! versionCheck "${vchc_git_version}" "${vchc_version}"; then
      [[ ${vchc_version} = "0.0.0" ]] && echo -e "\n  latest version: ${vchc_git_version}" || echo -e "\n  installed version: ${vchc_version}  |  latest version: ${vchc_git_version}"
      mkdir -p "${HOME}"/.local/bin
      rm -rf "${HOME}"/bin/cardano-hw-cli # Remove duplicate file in $PATH (old convention)
      if [ -f "${HOME}"/.local/bin/cardano-hw-cli ]; then
        rm -rf "${HOME}"/.local/bin/cardano-hw-cli 
      fi
      pushd "${HOME}"/.local/bin >/dev/null || err_exit
      mv -f /tmp/chwcli-bin/cardano-hw-cli/* ./
      if [[ ! -f "/etc/udev/rules.d/20-hw1.rules" ]]; then
        # Ledger udev rules
        curl -s -f -m ${CURL_TIMEOUT} https://raw.githubusercontent.com/LedgerHQ/udev-rules/master/add_udev_rules.sh | $sudo bash >/dev/null 2>&1
        $sudo sed -e "s@TAG+=\"uaccess\"@OWNER=\"$USER\", TAG+=\"uaccess\"@g" -i /etc/udev/rules.d/20-hw1.rules
      fi
      if [[ ! -f "/etc/udev/rules.d/51-trezor.rules" ]]; then
        # Trezor udev rules
        $sudo curl -s -f -m ${CURL_TIMEOUT} https://data.trezor.io/udev/51-trezor.rules -o /etc/udev/rules.d/51-trezor.rules
        $sudo sed -e "s@TAG+=\"uaccess\"@OWNER=\"$USER\", TAG+=\"uaccess\"@g" -i /etc/udev/rules.d/51-trezor.rules
      fi
      # Trigger rules update
      $sudo udevadm control --reload-rules >/dev/null 2>&1
      $sudo udevadm trigger >/dev/null 2>&1
      echo -e "\n  cardano-hw-cli v${vchc_git_version} installed!"
    else
      rm -rf cardano-hw-cli #cleanup in /tmp
      echo -e "\n  cardano-hw-cli already latest version [${vchc_version}], skipping!"
    fi
  else
    err_exit "Download of latest release of cardano-hw-cli from GitHub failed! Please retry or manually install it."
  fi
}

# Download pre-built ogmios binary
download_ogmios() {
  [[ -z ${ARCH##*aarch64*} ]] && err_exit "  The ogmios pre-compiled binary is not available for ARM, you might need to build them!"
  echo -e "\nInstalling Ogmios"
  if command -v ogmios >/dev/null; then ogmios_version="$(ogmios --version)" 2>/dev/null || ogmios_version="v0.0.0"; else ogmios_version="v0.0.0"; fi
  rm -rf /tmp/ogmios && mkdir /tmp/ogmios
  pushd /tmp/ogmios >/dev/null || err_exit
  ogmios_asset_url="$(curl -s https://api.github.com/repos/CardanoSolutions/ogmios/releases | jq -r '.[].assets[].browser_download_url' | grep x86_64-linux.zip | head -1)"
  if curl -sL -f -m ${CURL_TIMEOUT} -o ogmios.zip ${ogmios_asset_url}; then
    unzip ogmios.zip &>/dev/null
    rm -f ogmios.zip
    [[ -f bin/ogmios ]] && OGMIOSPATH=bin/ogmios
    [[ -f ogmios ]] && OGMIOSPATH=ogmios
    [[ -n ${OGMIOSPATH} ]] || err_exit "ogmios downloaded but binary not found after extracting package!"
    ogmios_git_version="$(curl -s https://api.github.com/repos/CardanoSolutions/ogmios/releases | jq -r '.[0].tag_name')"
    if ! versionCheck "${ogmios_git_version}" "${ogmios_version}"; then
      [[ "${ogmios_version}" = "0.0.0" ]] && echo -e "\n  latest version: ${ogmios_git_version}" || echo -e "\n  installed version: ${ogmios_version} | latest version: ${ogmios_git_version}"
      chmod +x /tmp/ogmios/${OGMIOSPATH}
      mv -f /tmp/ogmios/${OGMIOSPATH} "${HOME}"/.local/bin/
      rm -f "${HOME}"/.cabal/bin/ogmios # Remove duplicate from $PATH
      echo -e "\n  ogmios ${ogmios_git_version} installed!"
    else
      rm -rf /tmp/ogmios #cleanup in /tmp
      echo -e "\n  ogmios already latest version [${ogmios_version}], skipping!"
    fi
  else
    err_exit "Download of latest release of ogmios archive from GitHub failed! Please retry or manually install it."
  fi
}

# Download pre-built cardano-signer binary
download_cardanosigner() {
  [[ -z ${ARCH##*aarch64*} ]] && err_exit "  The cardano-signer pre-compiled binary is not available for ARM, you might need to build them!"
  echo -e "\nInstalling Cardano Signer"
  if command -v cardano-signer >/dev/null && [[ $(cardano-signer version) =~ ([0-9.]+) ]]; then
    csigner_version="v${BASH_REMATCH[1]}"
  else
    csigner_version="v0.0.0"
  fi
  csigner_git_version="$(curl -s https://api.github.com/repos/gitmachtl/cardano-signer/releases/latest | jq -r '.tag_name')"
  if ! versionCheck "${csigner_git_version}" "${csigner_version}"; then
    rm -rf /tmp/csigner && mkdir /tmp/csigner
    pushd /tmp/csigner >/dev/null || err_exit
    csigner_asset_url="$(curl -s https://api.github.com/repos/gitmachtl/cardano-signer/releases/latest | jq -r '.assets[].browser_download_url')"
    csigner_release_url=""
    while IFS= read -r release; do
      if [[ -z ${ARCH##*x86_64*} && ${release} = *linux-x64.tar.gz ]]; then # Linux x64
        csigner_release_url=${release}; break
      fi
    done <<< "${csigner_asset_url}"
    if [[ -n ${csigner_release_url} ]]; then
      if curl -sL -f -m ${CURL_TIMEOUT} -o csigner.tar.gz ${csigner_release_url}; then
        tar zxf csigner.tar.gz &>/dev/null
        rm -f csigner.tar.gz
        [[ -f cardano-signer ]] || err_exit "Cardano Signer downloaded but binary(cardano-signer) not found after extracting package!"
        [[ "${csigner_version}" = "v0.0.0" ]] && echo -e "\n  latest version: ${csigner_git_version}" || echo -e "\n  installed version: ${csigner_version} | latest version: ${csigner_git_version}"
        chmod +x /tmp/csigner/cardano-signer
        mv -f /tmp/csigner/cardano-signer "${HOME}"/.local/bin/
	rm -f "${HOME}"/.cabal/bin/cardano-signer # Remove duplicate from $PATH
        echo -e "\n  cardano-signer ${csigner_git_version} installed!"
      else
        err_exit "Download of latest release of Cardano Signer archive from GitHub failed! Please retry or install it manually."
      fi
    else
      err_exit "Unsupported system, no cardano-signer release found matching system architecture."
    fi
  else
    echo -e "\n  Cardano Signer already latest version [${csigner_version}], skipping!"
  fi
}

# Download pre-built mithril-signer binary
download_mithril() {
    echo -e "\nDownloading Mithril..."
    pushd "${HOME}"/tmp >/dev/null || err_exit
    mithril_release="$(curl -s https://api.github.com/repos/input-output-hk/mithril/releases/latest | jq -r '.tag_name')"
    echo -e "\n  Downloading Mithril Signer/Client ${mithril_release}..."
    rm -f mithril-signer mithril-client
    curl -m 200 -sfL https://github.com/input-output-hk/mithril/releases/download/${mithril_release}/mithril-${mithril_release}-linux-x64.tar.gz -o mithril.tar.gz || err_exit " Could not download mithril's latest release archive from IO github!"
    tar zxf mithril.tar.gz mithril-signer mithril-client &>/dev/null
    rm -f mithril.tar.gz
    [[ -f mithril-signer ]] || err_exit " mithril archive downloaded but binary (mithril-signer) not found after extracting package!"
    [[ -f mithril-client ]] || err_exit " mithril archive downloaded but binary (mithril-client) not found after extracting package!"
    mv -t "${HOME}"/.local/bin mithril-signer mithril-client
    chmod +x "${HOME}"/.local/bin/*
}

# Create folder structure and set up permissions/ownerships
setup_folder() {
  echo -e "\nCreating Folder Structure .."
  
  if grep -q "export ${CNODE_VNAME}_HOME=" "${HOME}"/.bashrc; then
    echo -e "\nEnvironment Variable already set up!"
  else
    echo -e "\nSetting up Environment Variable"
    echo -e "\nexport ${CNODE_VNAME}_HOME=${CNODE_HOME}" >> "${HOME}"/.bashrc
  fi
  
  $sudo mkdir -p "${CNODE_HOME}"/files "${CNODE_HOME}"/db "${CNODE_HOME}"/guild-db "${CNODE_HOME}"/logs "${CNODE_HOME}"/scripts "${CNODE_HOME}"/scripts/archive "${CNODE_HOME}"/sockets "${CNODE_HOME}"/priv "${CNODE_HOME}"/mithril/data-stores
  $sudo chown -R "$U_ID":"$G_ID" "${CNODE_HOME}" 2>/dev/null
  
}

# Download and update scripts for cnode
populate_cnode() {
  [[ ! -d "${CNODE_HOME}"/files ]] && setup_folder
  echo -e "\nDownloading files..."
  pushd "${CNODE_HOME}"/files >/dev/null || err_exit
  echo "${BRANCH}" > "${CNODE_HOME}"/scripts/.env_branch
  
  local err_msg=" Had Trouble downloading the file:"
  # Download node config, genesis and topology from template
  #NWCONFURL="https://raw.githubusercontent.com/input-output-hk/cardano-playground/main/static/book.play.dev.cardano.org/environments"
  NWCONFURL="${URL_RAW}/files/configs/${NETWORK}/"
  if [[ ${NETWORK} =~ ^(mainnet|preprod|preview|guild|sanchonet)$ ]]; then
    curl -sL -f -m ${CURL_TIMEOUT} -o alonzo-genesis.json.tmp "${NWCONFURL}/alonzo-genesis.json" || err_exit "${err_msg} alonzo-genesis.json"
    curl -sL -f -m ${CURL_TIMEOUT} -o byron-genesis.json.tmp "${NWCONFURL}/byron-genesis.json" || err_exit "${err_msg} byron-genesis.json"
    curl -sL -f -m ${CURL_TIMEOUT} -o conway-genesis.json.tmp "${NWCONFURL}/conway-genesis.json" || err_exit "${err_msg} conway-genesis.json"
    curl -sL -f -m ${CURL_TIMEOUT} -o shelley-genesis.json.tmp "${NWCONFURL}/shelley-genesis.json" || err_exit "${err_msg} shelley-genesis.json"
    curl -sL -f -m ${CURL_TIMEOUT} -o topology.json.tmp "${NWCONFURL}/topology.json" || err_exit "${err_msg} topology.json"
    curl -sL -f -m ${CURL_TIMEOUT} -o config.json.tmp "${NWCONFURL}/config.json" || err_exit "${err_msg} config.json"
    curl -sL -f -m ${CURL_TIMEOUT} -o dbsync.json.tmp "${NWCONFURL}/db-sync-config.json" || err_exit "${err_msg} dbsync-sync-config.json"
  else
    err_exit "Unknown network specified! Kindly re-check the network name, valid options are: mainnet, guild, preprod, preview or sanchonet."
  fi
  sed -e "s@/opt/cardano/cnode@${CNODE_HOME}@g" -i ./*.json.tmp
  if [[ ${FORCE_OVERWRITE} = 'Y' ]]; then
    [[ -f topology.json ]] && cp -f topology.json "topology.json_bkp$(date +%s)"
    [[ -f config.json ]] && cp -f config.json "config.json_bkp$(date +%s)"
    [[ -f dbsync.json ]] && cp -f dbsync.json "dbsync.json_bkp$(date +%s)"
  fi
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
  
  pushd "${CNODE_HOME}"/scripts >/dev/null || err_exit
  
  [[ ${FORCE_OVERWRITE} = 'Y' ]] && echo -e "\nForced full upgrade! Please edit scripts/env, scripts/cnode.sh, scripts/dbsync.sh, scripts/submitapi.sh, scripts/ogmios.sh, scripts/gLiveView.sh and scripts/topologyUpdater.sh scripts/mithril-client.sh scripts/mithril-relay.sh scripts/mithril-signer.sh (alongwith files/topology.json, files/config.json, files/dbsync.json) as required!"
  
  updateWithCustomConfig "blockPerf.sh"
  updateWithCustomConfig "cabal-build-all.sh"
  updateWithCustomConfig "cncli.sh"
  updateWithCustomConfig "cnode.sh"
  updateWithCustomConfig "cntools.sh"
  updateWithCustomConfig "cntools.library"
  updateWithCustomConfig "dbsync.sh"
  updateWithCustomConfig "deploy-as-systemd.sh"
  updateWithCustomConfig "env"
  updateWithCustomConfig "gLiveView.sh"
  updateWithCustomConfig "logMonitor.sh"
  updateWithCustomConfig "ogmios.sh"
  updateWithCustomConfig "submitapi.sh"
  updateWithCustomConfig "setup_mon.sh"
  updateWithCustomConfig "setup-grest.sh" "grest-helper-scripts"
  updateWithCustomConfig "topologyUpdater.sh"
  updateWithCustomConfig "mithril-client.sh"
  updateWithCustomConfig "mithril-relay.sh"
  updateWithCustomConfig "mithril-signer.sh"
  updateWithCustomConfig "mithril.library"
  
  find "${CNODE_HOME}/scripts" -name '*.sh' -exec chmod 755 {} \; 2>/dev/null
  chmod -R 700 "${CNODE_HOME}"/priv 2>/dev/null
}

# Parse arguments supplied to script
parse_args() {
  POPULATE_CNODE="Y"
  if [[ -n "${S_ARGS}" ]]; then
    [[ "${S_ARGS}" =~ "p" ]] && INSTALL_OS_DEPS="Y"
    [[ "${S_ARGS}" =~ "b" ]] && INSTALL_OS_DEPS="Y" && WANT_BUILD_DEPS="Y"
    [[ "${S_ARGS}" =~ "l" ]] && INSTALL_OS_DEPS="Y" && WANT_BUILD_DEPS="Y" && INSTALL_LIBSODIUM_FORK="Y"
    [[ "${S_ARGS}" =~ "m" ]] && INSTALL_MITHRIL="Y"
    [[ "${S_ARGS}" =~ "f" ]] && FORCE_OVERWRITE="Y" && POPULATE_CNODE="F"
    [[ "${S_ARGS}" =~ "d" ]] && INSTALL_CNODEBINS="Y"
    [[ "${S_ARGS}" =~ "c" ]] && INSTALL_CNCLI="Y"
    [[ "${S_ARGS}" =~ "o" ]] && INSTALL_OGMIOS="Y"
    [[ "${S_ARGS}" =~ "w" ]] && INSTALL_CWHCLI="Y"
    [[ "${S_ARGS}" =~ "x" ]] && INSTALL_CARDANO_SIGNER="Y"
  else
    echo -e "\nNothing to do.."
  fi
  common_init
  if [[ ! -d "${CNODE_HOME}"/files ]]; then
    # Guess this is a fresh machine and set minimal params
    INSTALL_OS_DEPS="Y"
  fi
}

# Main Flow for calling different functions
main_flow() {
  [[ "${UPDATE_CHECK}" == "Y" ]] && update_check
  [[ "${INSTALL_OS_DEPS}" == "Y" ]] && os_dependencies
  [[ "${WANT_BUILD_DEPS}" == "Y" ]] && build_dependencies
  [[ "${INSTALL_LIBSODIUM_FORK}" == "Y" ]] && build_libsodium
  [[ "${INSTALL_MITHRIL}" == "Y" ]] && download_mithril
  [[ "${FORCE_OVERWRITE}" == "Y" ]] && POPULATE_CNODE="F" && populate_cnode
  [[ "${POPULATE_CNODE}" == "Y" ]] && populate_cnode
  [[ "${INSTALL_CNODEBINS}" == "Y" ]] && download_cnodebins
  [[ "${INSTALL_CNCLI}" == "Y" ]] && download_cncli
  [[ "${INSTALL_OGMIOS}" == "Y" ]] && download_ogmios
  [[ "${INSTALL_CWHCLI}" == "Y" ]] && download_cardanohwcli
  [[ "${INSTALL_CARDANO_SIGNER}" == "Y" ]] && download_cardanosigner
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

parse_args
main_flow

pushd -0 >/dev/null || err_exit; dirs -c
