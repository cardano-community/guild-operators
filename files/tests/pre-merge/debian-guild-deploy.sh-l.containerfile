FROM debian:stable
ARG G_ACCOUNT
ARG COMMIT
ARG BRANCH
ARG CNODE_HOME=/opt/cardano/cnode

ENV \
  DEBIAN_FRONTEND=noninteractive \
  LANG=C.UTF-8 \
  USER=root \
  PATH=$CNODE_HOME/scripts:/root/.local/bin:/root/.ghcup/bin:$PATH \
  G_ACCOUNT=$G_ACCOUNT \
  BRANCH=$BRANCH \
  COMMIT=$COMMIT

WORKDIR /

RUN rm /bin/sh && ln -s /bin/bash /bin/sh

RUN set -x && apt-get -y update && apt-get -y --no-install-recommends install curl git ca-certificates gnupg apt-utils udev &&\
    rm -rf /var/lib/apt/lists/* &&\
    mkdir -pv /root/.{local,ghcup}/bin &&\
    curl -s -f -k -o guild-deploy.sh "https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${BRANCH}/scripts/cnode-helper-scripts/guild-deploy.sh" &&\
    chmod 0755 guild-deploy.sh &&\
    export SUDO='N' &&\
    export G_ACCOUNT="${G_ACCOUNT}" &&\
    export UPDATE_CHECK='N' &&\
    ./guild-deploy.sh -b "${BRANCH}" -s pblcowx
