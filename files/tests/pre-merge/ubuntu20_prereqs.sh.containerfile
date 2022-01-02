FROM ubuntu:20.04
ARG BRANCH
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
    curl --silent --show-error --insecure --output prereqs.sh "https://raw.githubusercontent.com/cardano-community/guild-operators/${BRANCH}/scripts/cnode-helper-scripts/prereqs.sh" &&\
    chmod 0755 prereqs.sh &&\
    export SUDO='N' &&\
    export UPDATE_CHECK='N' &&\
    ./prereqs.sh -b "${BRANCH}"
