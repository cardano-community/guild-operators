#!/bin/bash

# executes cabal build all
# parses cardano-node binaries location from compiler output and copy it to ~./local/bin folder.

my_bin_path="$HOME/.local/bin"

mkdir -p $my_bin_path
source $HOME/.local/bin

cabal build all 2>&1 | tee /tmp/cardano-node-build.log

cat /tmp/cardano-node-build.log | egrep "Linking+.*ghc+.*cardano-node" | while read -r line ; do
    act_bin_path=$(echo $line | awk '{print $2}')
    act_bin=$(echo $act_bin_path | awk -F "/" '{print $NF}')
    echo "Processing $act_bin"
    cp $act_bin_path "${my_bin_path}/${act_bin}"
done

