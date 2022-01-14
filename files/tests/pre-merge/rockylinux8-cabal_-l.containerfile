ARG COMMIT
FROM ghcr.io/cardano-community/pre-merge-rockylinux8:prereqs_-l_${COMMIT}
ARG BRANCH
ARG CNODE_HOME=/opt/cardano/cnode

ENV \
  LANG=C.UTF-8 \
  USER=root \
  PATH=$CNODE_HOME/scripts:/root/.cabal/bin:/root/.ghcup/bin:$PATH

RUN git clone https://github.com/input-output-hk/cardano-node &&\
    pwd ; ls -l

WORKDIR /cardano-node

RUN curl -o cardano-node-latest.txt "https://raw.githubusercontent.com/cardano-community/guild-operators/${BRANCH}/files/docker/node/release-versions/cardano-node-latest.txt" &&\
    CNODE_VERSION=$(cat cardano-node-latest.txt) &&\
    echo "Checking out Cardano node: ${CNODE_VERSION}" &&\
    git fetch --tags --all &&\
    git checkout tags/"${CNODE_VERSION}" &&\
    git status &&\
    /opt/cardano/cnode/scripts/cabal-build-all.sh -l &&\
    cabal install cardano-ping &&\
    /root/.cabal/bin/cardano-cli version ; /root/.cabal/bin/cardano-node version