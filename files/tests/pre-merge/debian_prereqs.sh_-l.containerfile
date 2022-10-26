FROM debian:stable
ARG G_ACCOUNT
ARG COMMIT
ARG BRANCH
ARG CNODE_HOME=/opt/cardano/cnode

ENV \
  DEBIAN_FRONTEND=noninteractive \
  LANG=C.UTF-8 \
  USER=root \
  PATH=$CNODE_HOME/scripts:/root/.cabal/bin:/root/.ghcup/bin:$PATH \
  BRANCH=$BRANCH \
  COMMIT=$COMMIT

WORKDIR /

RUN rm /bin/sh && ln -s /bin/bash /bin/sh

RUN set -x && apt update \
    && mkdir -pv /root/.{cabal,ghcup}/bin \
    && apt install -y apt-utils curl gnupg git udev ca-certificates \
    && curl --silent --show-error --insecure --output prereqs.sh "https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${BRANCH}/scripts/cnode-helper-scripts/prereqs.sh" \
    && chmod 0755 prereqs.sh \
    && export SUDO='N' \
    && export UPDATE_CHECK='N' \
    && export G_ACCOUNT="${G_ACCOUNT}" \
    && ./prereqs.sh -l -b "${BRANCH}"
