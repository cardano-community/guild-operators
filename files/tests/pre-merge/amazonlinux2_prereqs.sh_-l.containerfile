FROM amazonlinux:2
ARG COMMIT
ARG BRANCH
ARG CNODE_HOME=/opt/cardano/cnode

ENV \
  LANG=C.UTF-8 \
  USER=root \
  PATH=$CNODE_HOME/scripts:/root/.cabal/bin:/root/.ghcup/bin:$PATH

WORKDIR /

RUN amazon-linux-extras install epel -y && yum -y install git-2.32.0-1.amzn2.0.1 && yum clean all &&\
    mkdir -pv /root/.cabal/bin /root/.ghcup/bin &&\
    curl -sS -o prereqs.sh "https://raw.githubusercontent.com/cardano-community/guild-operators/${BRANCH}/scripts/cnode-helper-scripts/prereqs.sh" &&\
    chmod 755 prereqs.sh &&\
    export SUDO='N' &&\
    export UPDATE_CHECK='N' &&\
    ./prereqs.sh -l -b "${BRANCH}"
