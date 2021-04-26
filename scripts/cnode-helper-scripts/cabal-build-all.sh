#!/usr/bin/env bash

# executes cabal build all
# parses executables created from compiler output and copies it to ~./cabal/bin folder.

if [[ "${PWD##*/}" == "cardano-node" ]]; then
  echo "Overwriting cabal.project.local with latest file from guild-repo (previous file, if any, will be saved as cabal.project.local.swp).."
  [[ -f cabal.project.local ]] && mv cabal.project.local cabal.project.local.swp
  cat <<-EOF > cabal.project.local
	package cardano-crypto-praos
	flags: -external-libsodium-vrf
	
	source-repository-package
	  type: git
	  location: https://github.com/input-output-hk/bech32
	  tag: v1.1.0
	  subdir: bech32
	
	source-repository-package
	  type: git
	  location: https://github.com/input-output-hk/cardano-addresses
	  tag: 2.1.0
	  subdir: core
	
	source-repository-package
	  type: git
	  location: https://github.com/input-output-hk/cardano-addresses
	  tag: 2.1.0
	  subdir: command-line
	EOF
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

