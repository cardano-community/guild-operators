ARG COMMIT
ARG G_ACCOUNT
# The account the guild-deploy image was tagged under. A fork's PR fetches
# its scripts from the fork (G_ACCOUNT) but builds on the image tagged in
# this repository's name, which stays local when the push is skipped.
ARG IMAGE_ACCOUNT=${G_ACCOUNT}
FROM --platform=$BUILDPLATFORM ghcr.io/${IMAGE_ACCOUNT}/pre-merge-ubuntu:guild-deploy-l_${COMMIT}
ARG BRANCH
ARG CNODE_HOME=/opt/cardano/cnode

ENV \
  DEBIAN_FRONTEND=noninteractive \
  LANG=C.UTF-8 \
  USER=root \
  PATH=$CNODE_HOME/bin:$CNODE_HOME/scripts:/root/.local/bin:/root/.ghcup/bin:$PATH \
  LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH \
  BRANCH=$BRANCH \
  G_ACCOUNT=$G_ACCOUNT \
  COMMIT=$COMMIT

RUN git clone https://github.com/intersectmbo/cardano-node

WORKDIR /cardano-node

RUN curl -s -f -k -o cnode-release.json "https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${BRANCH}/files/node-implementations/cnode/release.json" &&\
    CNODE_VERSION=$(jq -er '.version' cnode-release.json) &&\
    echo "Checking out Cardano node: ${CNODE_VERSION}" &&\
    git fetch --tags --all &&\
    git checkout tags/"${CNODE_VERSION}" &&\
    git status &&\
    /opt/cardano/cnode/scripts/cabal-build-all.sh -c &&\
    $CNODE_HOME/bin/cardano-node version

# The node's dependency plan has an older cardano-cli than the guild scripts
# require, so the pinned release is built from its own repository.
WORKDIR /
RUN CLI_VERSION=$(jq -er '.companions["cardano-cli"].version' /cardano-node/cnode-release.json) &&\
    echo "Building cardano-cli ${CLI_VERSION}" &&\
    git clone --depth 1 --branch "cardano-cli-${CLI_VERSION}" https://github.com/intersectmbo/cardano-cli &&\
    cd cardano-cli &&\
    /opt/cardano/cnode/scripts/cabal-build-all.sh &&\
    $CNODE_HOME/bin/cardano-cli version &&\
    $CNODE_HOME/bin/cardano-cli version | head -n 1 | grep -Fq "cardano-cli ${CLI_VERSION} "
