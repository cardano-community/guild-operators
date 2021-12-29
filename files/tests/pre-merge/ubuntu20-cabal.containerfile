FROM ubuntu:20.04

ARG CNODE_HOME=/opt/cardano/cnode

ENV \
  DEBIAN_FRONTEND=noninteractive \
  LANG=C.UTF-8 \
  USER=root \
  PATH=$CNODE_HOME/scripts:/root/.cabal/bin:/root/.ghcup/bin:$PATH

WORKDIR /

RUN set -x && apt-get -y update && apt-get -y --no-install-recommends install curl=7.68.0-1ubuntu2.7 git=1:2.25.1-1ubuntu3.2 ca-certificates=20190110ubuntu1 gnupg=2.2.19-3ubuntu2.1 apt-utils=2.0.6 udev=245.4-4ubuntu3.13 &&\
    rm -rf /var/lib/apt/lists/* &&\
    mkdir -pv /root/.cabal/bin /root/.ghcup/bin &&\
    curl --silent --show-error --insecure --output prereqs.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/prereqs.sh &&\
    chmod 0755 prereqs.sh &&\
    export SUDO='N' &&\
    export UPDATE_CHECK='N' &&\
    export export BOOTSTRAP_HASKELL_NO_UPGRADE=1 &&\
    ./prereqs.sh

RUN git clone https://github.com/input-output-hk/cardano-node &&\
    pwd ; ls -l

WORKDIR /cardano-node

RUN curl --silent --show-error --insecure --output cardano-node-latest.txt https://raw.githubusercontent.com/chaincrucial/guild-ops-containers/master/containers/guild-ops-base/cardano-node-latest.txt &&\
    CNODE_VERSION=$(cat cardano-node-latest.txt) &&\
    echo "Checking out Cardano node: ${CNODE_VERSION}" &&\
    git fetch --tags --all &&\
    git checkout tags/"${CNODE_VERSION}" &&\
    git status &&\
    curl -o cabal.project.local https://raw.githubusercontent.com/cardano-community/guild-operators/master/files/cabal.project.local &&\
    /opt/cardano/cnode/scripts/cabal-build-all.sh &&\
    cabal install cardano-ping &&\
    /root/.cabal/bin/cardano-cli version ; /root/.cabal/bin/cardano-node version