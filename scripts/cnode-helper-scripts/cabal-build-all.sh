#!/usr/bin/env bash

# executes cabal build all
# parses executables created from compiler output and copies it to ~./cabal/bin folder.

[[ -f /usr/local/lib/libsodium.so ]] && export LD_LIBRARY_PATH=/usr/local/lib:"${LD_LIBRARY_PATH}" && PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:"${PKG_CONFIG_PATH}"

[[ "$1" == "-l" ]] && USE_SYSTEM_LIBSODIUM="package cardano-crypto-praos
  flags: -external-libsodium-vrf"

echo "Deleting build config artifact to remove cached version, this prevents invalid Git Rev"
find dist-newstyle/build/x86_64-linux/ghc-8.10.?/cardano-config-* >/dev/null 2>&1 && rm -rf "dist-newstyle/build/x86_64-linux/ghc-8.*/cardano-config-*"

if [[ "${PWD##*/}" == "cardano-node" ]] || [[ "${PWD##*/}" == "cardano-db-sync" ]]; then
  echo "Overwriting cabal.project.local to include cardano-addresses and bech32 (previous file, if any, will be saved as cabal.project.local.swp).."
  [[ -f cabal.project.local ]] && mv cabal.project.local cabal.project.local.swp
  cat <<-EOF > cabal.project.local
	${USE_SYSTEM_LIBSODIUM}
	
	source-repository-package
	  type: git
	  location: https://github.com/input-output-hk/bech32
	  tag: c33dbf2edeb6930328503871e145f011cb20127e
	  subdir: bech32
	
	source-repository-package
	  type: git
	  location: https://github.com/input-output-hk/cardano-addresses
	  tag: 9fe7084c9c53b9edf3eba34ee8459c896734ac7a
	  subdir:
	    command-line
	    core
	
	EOF
  chmod 640 cabal.project.local
  cabal install bech32 cardano-addresses-cli  --overwrite-policy=always 2>&1 | tee /tmp/build-b32-caddr.log
fi

echo "Running cabal update to ensure you're on latest dependencies.."
cabal update 2>&1 | tee /tmp/cabal-build.log
echo "Building.."
cabal build all 2>&1 | tee /tmp/build.log

grep "^Linking" /tmp/build.log | grep -Ev 'test|golden|demo|chairman|locli|ledger|topology' | while read -r line ; do
    act_bin_path=$(echo "$line" | awk '{print $2}')
    act_bin=$(echo "$act_bin_path" | awk -F "/" '{print $NF}')
    echo "Copying $act_bin to $HOME/.cabal/bin/"
    cp -f "$act_bin_path" "$HOME/.cabal/bin/"
done

