#!/bin/bash

# executes cabal build all
# parses executables created from compiler output and copies it to ~./cabal/bin folder.

echo "Deleting build config artifact to remove cached version, this prevents invalid Git Rev"
[[ -d "dist-newstyle/build/x86_64-linux/ghc-8.6.5/cardano-config-0.1.0.0" ]] && rm -rf "dist-newstyle/build/x86_64-linux/ghc-8.6.5/cardano-config-0.1.0.0"
echo "Running cabal update to ensure you're on latest dependencies.."
cabal update 2>&1 | tee /tmp/cabal-build.log
echo "Building.."
cabal build all 2>&1 | tee /tmp/build.log

grep "^Linking" /tmp/build.log | while read -r line ; do
    act_bin_path=$(echo "$line" | awk '{print $2}')
    act_bin=$(echo "$act_bin_path" | awk -F "/" '{print $NF}')
    echo "Copying $act_bin to $HOME/.cabal/bin/"
    cp "$act_bin_path" "$HOME/.cabal/bin/"
done

