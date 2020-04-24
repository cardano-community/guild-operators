### Building Cardano Node and Cardano CLI

#### Pre-Requisites

##### System Packages

The Haskell cardano-node build requires the following dependency packages to be available to the system:

**Tip**: The steps described individually below can be executed with the two scripts "[cabal_prepare](https://github.com/cardano-community/guild-operators/blob/master/files/ptn0/scripts/cabal-prepare.sh)" and "[build-all-install](https://github.com/cardano-community/guild-operators/blob/master/files/ptn0/scripts/cabal-build-all-install.sh)". (_prepare_ automatically recognizes Debian/Ubuntu or CentOS)

The instructions for **Debian and Ubuntu** are identical.
``` bash
sudo apt-get update
sudo apt-get -y install curl build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev libsystemd-dev zlib1g-dev tmux git
```

If you're using **CentOS**, the corresponding packages will be:
``` bash
sudo yum update
sudo yum -y install curl pkgconfig libffi-devel gmp-devel openssl-devel ncurses-libs systemd-devel zlib-devel tmux git
# You might need to create a symlink to /usr/lib64/libtinfo.so as per below if one does not already exist
# sudo ln -s $(ls -1 /usr/lib64/libtinfo.so* | tail -1) /usr/lib64/libtinfo.so
# sudo ln -s $(ls -1 /usr/lib64/libtinfo.so* | tail -1) /usr/lib64/libtinfo.so.5
```

#### GHC and Cabal

The node depends on very specific versions of [GHC 8.6.5](https://www.haskell.org/ghcup/) and [Cabal 3.0].
The best way to get them is with the Haskell Installer tool [ghcup].
``` bash
mkdir ~/tmp;cd ~/tmp
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh

# confirm by pressing ENTER twice and type YES at the end to add ghcup to your PATH variable.

source ~/.ghcup/env
```

Now install and activate the required GHC version

``` bash
ghcup install 8.6.5
ghcup set 8.6.5
ghc --version
```

To download and install cabal specific release, follow instructions below:

``` bash
wget https://downloads.haskell.org/cabal/cabal-install-3.0.0.0/cabal-install-3.0.0.0-x86_64-unknown-linux.tar.xz
tar xz cabal-install-3.0.0.0-x86_64-unknown-linux.tar.xz
cp cabal ~/.local/bin
cd -
```

#### Build Instructions

Now that the dependencies have been met, we can start setting up the node.
Start by cloning the Cardano Node git to build the binaries:

``` bash
cd ~/git
git clone https://github.com/input-output-hk/cardano-node
cd cardano-node
cabal build all | tee build.log | grep ^Linking
```

Now you can copy the binaries build (using location above) into ~/.local/bin folder (when part of the PATH variable).

```
cardano-node
cardano-cli
chairman
```

For example for cardano-cli 1.10.1 it is `~/git/cardano-node/dist-newstyle/build/x86_64-linux/ghc-8.6.5/cardano-node-1.10.1/x/cardano-cli/build/cardano-cli/cardano-cli`

#### Verify

Execute cardano-cli and cardano-node to verify output as below:

```bash
cardano-cli version
# cardano-cli 1.10.1 - linux-x86_64 - ghc-8.6
cardano-node
#Usage: cardano-node (run | run-mock) [--help]
#  Start node of the Cardano blockchain.
#
#Available options:
#  --help                   Show this help text
#
#Execute node with a real protocol.
#  run                      Execute node with a real protocol.
#
#Execute node with a mock protocol.
#  run-mock                 Execute node with a mock protocol.
