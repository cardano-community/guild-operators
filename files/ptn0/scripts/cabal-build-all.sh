#!/bin/sh

# executes cabal build all
# parses executables created from compiler output and copies it to ~./cabal/bin folder.

cabal build all 2>&1 | tee /tmp/build.log

grep "^Linking" /tmp/build.log | while read -r line ; do
    act_bin_path=$(echo "$line" | awk '{print $2}')
    act_bin=$(echo "$act_bin_path" | awk -F "/" '{print $NF}')
    echo "Copying $act_bin to $HOME/.cabal/bin/"
    cp "$act_bin_path" "$HOME/.cabal/bin/"
done

