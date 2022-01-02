FROM debian:stable
ARG BRANCH
ARG CNODE_HOME=/opt/cardano/cnode

ENV \
  DEBIAN_FRONTEND=noninteractive \
  LANG=C.UTF-8 \
  USER=root \
  PATH=$CNODE_HOME/scripts:/root/.cabal/bin:/root/.ghcup/bin:$PATH

WORKDIR /

RUN set -x && apt-get -y update && apt-get -y --no-install-recommends install curl=7.74.0-1.3+deb11u1 git=1:2.30.2-1 ca-certificates=20210119 gnupg=2.2.27-2 apt-utils=2.2.4 udev=247.3-6 &&\
    rm -rf /var/lib/apt/lists/* &&\
    mkdir -pv /root/.cabal/bin /root/.ghcup/bin &&\
    curl --silent --show-error --insecure --output prereqs.sh "https://raw.githubusercontent.com/cardano-community/guild-operators/${BRANCH}/scripts/cnode-helper-scripts/prereqs.sh" &&\
    chmod 0755 prereqs.sh &&\
    export SUDO='N' &&\
    export UPDATE_CHECK='N' &&\
    ./prereqs.sh -l -b "${BRANCH}"
