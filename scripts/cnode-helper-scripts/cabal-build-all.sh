#!/bin/bash

# executes cabal build all
# parses executables created from compiler output and copies it to ~./cabal/bin folder.

OVERWRITE_LOCAL="N"

[[ -f "${CNODE_HOME}"/scripts/.env_branch ]] && BRANCH="$(cat "${CNODE_HOME}"/scripts/.env_branch)" || BRANCH="master"
URL_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators/${BRANCH}/files/cabal.project.local"
[[ "$1" == "-o" ]] && OVERWRITE_LOCAL="Y"

if [[ "${PWD##*/}" == "cardano-node" ]] && [[ "${OVERWRITE_LOCAL}" == "Y" ]]; then
  echo "Overwriting cabal.project.local with latest file from guild-repo (previous file, if any, will be saved as cabal.project.local.swp).."
  [[ -f cabal.project.local ]] && mv cabal.project.local cabal.project.local.swp
  curl -s -f -o cabal.project.local -C - "${URL_RAW}"
  chmod 640 cabal.project.local
fi

echo "Running cabal update to ensure you're on latest dependencies.."
cabal update 2>&1 | tee /tmp/cabal-build.log
echo "Building.."
cabal build all 2>&1 | tee /tmp/build.log

grep "^Linking" /tmp/build.log | grep -Ev 'test|golden|demo' | while read -r line ; do
    act_bin_path=$(echo "$line" | awk '{print $2}')
    act_bin=$(echo "$act_bin_path" | awk -F "/" '{print $NF}')
    echo "Copying $act_bin to $HOME/.cabal/bin/"
    cp -f "$act_bin_path" "$HOME/.cabal/bin/"
done

