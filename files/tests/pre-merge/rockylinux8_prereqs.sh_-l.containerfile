FROM rockylinux/rockylinux:8
ARG COMMIT
ARG G_ACCOUNT
ARG BRANCH
ARG CNODE_HOME=/opt/cardano/cnode

ENV \
  LANG=C.UTF-8 \
  USER=root \
  PATH=$CNODE_HOME/scripts:/root/.cabal/bin:/root/.ghcup/bin:$PATH \
  BRANCH=$BRANCH \
  COMMIT=$COMMIT

WORKDIR /

RUN dnf -y install epel-release-8 &&\
    dnf -y --allowerasing install python3 coreutils pkgconf-pkg-config libffi-devel gmp-devel openssl-devel ncurses-libs ncurses-compat-libs systemd systemd-devel zlib-devel make gcc-c++ git gnupg libtool autoconf srm iproute bc traceroute diffutils &&\
    dnf clean all &&\
    mkdir -pv /root/.cabal/bin /root/.ghcup/bin &&\
    curl -sS -o prereqs.sh "https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${BRANCH}/scripts/cnode-helper-scripts/prereqs.sh" &&\
    chmod 755 prereqs.sh &&\
    export SUDO='N' &&\
    export UPDATE_CHECK='N' &&\
    export G_ACCOUNT="${G_ACCOUNT}" &&\
    ./prereqs.sh -l -b "${BRANCH}"
