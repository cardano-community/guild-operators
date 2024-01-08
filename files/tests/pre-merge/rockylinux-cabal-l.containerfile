ARG COMMIT
ARG G_ACCOUNT
FROM ghcr.io/${G_ACCOUNT}/pre-merge-rockylinux:guild-deploy-l_${COMMIT}
ARG BRANCH
ARG CNODE_HOME=/opt/cardano/cnode

ENV \
  LANG=C.UTF-8 \
  USER=root \
  PATH=$CNODE_HOME/scripts:/root/.local/bin:/root/.ghcup/bin:$PATH \
  LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH \
  BRANCH=$BRANCH \
  G_ACCOUNT=$G_ACCOUNT \
  COMMIT=$COMMIT

RUN git clone https://github.com/intersectmbo/cardano-node

WORKDIR /cardano-node

RUN curl -s -f -k -o cardano-node-latest.txt "https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${BRANCH}/files/docker/node/release-versions/cardano-node-latest.txt" &&\
    CNODE_VERSION=$(cat cardano-node-latest.txt) &&\
    echo "Checking out Cardano node: ${CNODE_VERSION}" &&\
    git fetch --tags --all &&\
    git checkout tags/"${CNODE_VERSION}" &&\
    git status &&\
    /opt/cardano/cnode/scripts/cabal-build-all.sh &&\
    /root/.local/bin/cardano-cli version ; /root/.local/bin/cardano-node version
