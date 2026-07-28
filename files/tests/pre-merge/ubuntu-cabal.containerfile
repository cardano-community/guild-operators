ARG COMMIT
ARG G_ACCOUNT 
FROM --platform=$BUILDPLATFORM ghcr.io/${G_ACCOUNT}/pre-merge-ubuntu:guild-deploy-l_${COMMIT}
ARG BRANCH
ARG CNODE_HOME=/opt/cardano/cnode

ENV \
  DEBIAN_FRONTEND=noninteractive \
  LANG=C.UTF-8 \
  USER=root \
  PATH=$CNODE_HOME/scripts:/root/.local/bin:/root/.ghcup/bin:$PATH \
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
    /root/.local/bin/cardano-cli version ; /root/.local/bin/cardano-node version
