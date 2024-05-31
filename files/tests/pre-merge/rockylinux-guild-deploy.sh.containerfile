FROM rockylinux/rockylinux:9
ARG G_ACCOUNT
ARG COMMIT
ARG BRANCH
ARG CNODE_HOME=/opt/cardano/cnode

ENV \
  LANG=C.UTF-8 \
  USER=root \
  PATH=$CNODE_HOME/scripts:/root/.local/bin:/root/.ghcup/bin:$PATH \
  G_ACCOUNT=$G_ACCOUNT \
  BRANCH=$BRANCH \
  COMMIT=$COMMIT

WORKDIR /

RUN dnf -y --allowerasing install findutils jq &&\
    dnf clean all &&\
    mkdir -pv /root/.local/bin /root/.ghcup/bin &&\
    curl -s -f -k -o guild-deploy.sh "https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${BRANCH}/scripts/cnode-helper-scripts/guild-deploy.sh" &&\
    chmod 755 guild-deploy.sh &&\
    export SUDO='N' &&\
    export G_ACCOUNT="${G_ACCOUNT}" &&\
    export UPDATE_CHECK='N' &&\
    ./guild-deploy.sh -b "${BRANCH}" -s pblcowx

