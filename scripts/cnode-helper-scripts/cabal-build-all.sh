#!/usr/bin/env bash
# shellcheck disable=SC1090
# executes cabal build all
# parses executables created from compiler output and copies it to ~./cabal/bin folder.

echo "Deleting build config artifact to remove cached version, this prevents invalid Git Rev"
find dist-newstyle/build/x86_64-linux/ghc-8.10.?/cardano-config-* >/dev/null 2>&1 && rm -rf "dist-newstyle/build/x86_64-linux/ghc-8.*/cardano-config-*"

if [[ "$1" == "-l" ]] ; then
  USE_SYSTEM_LIBSODIUM="package cardano-crypto-praos
    flags: -external-libsodium-vrf"
  # In case Custom libsodium module is present, exclude it from Load Library Path
  [[ -f /usr/local/lib/libsodium.so ]] && export LD_LIBRARY_PATH=${LD_LIBRARY_PATH/\/usr\/local\/lib:/}
else
  unset USE_SYSTEM_LIBSODIUM
  source "${HOME}"/.bashrc
  [[ -d /usr/local/lib/pkgconfig ]] && export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:"${PKG_CONFIG_PATH}"
  [[ -f /usr/local/lib/libsodium.so ]] && export LD_LIBRARY_PATH=/usr/local/lib:"${LD_LIBRARY_PATH}"
fi

[[ -f cabal.project.local ]] && mv cabal.project.local cabal.project.local.bkp_"$(date +%s)"
cat <<-EOF > .tmp.cabal.project.local
	${USE_SYSTEM_LIBSODIUM}
	
	source-repository-package
	  type: git
	  location: https://github.com/input-output-hk/bech32
	  tag: ab61914443e5f53624d3b2995767761b3f68e576
	  subdir: bech32
	
	source-repository-package
	  type: git
	  location: https://github.com/input-output-hk/cardano-addresses
	  tag: b6f2f3cef01a399376064194fd96711a5bdba4a7
	  subdir:
	    command-line
	    core
	
	EOF
chmod 640 .tmp.cabal.project.local

if [[ -z "${USE_SYSTEM_LIBSODIUM}" ]] ; then
  echo "Running cabal update to ensure you're on latest dependencies.."
  cabal update 2>&1 | tee /tmp/cabal-update.log
  echo "Building.."
  cabal build all 2>&1 | tee tee /tmp/build.log
  if [[ "${PWD##*/}" == "cardano-node" ]] || [[ "${PWD##*/}" == "cardano-db-sync" ]]; then
    echo "Overwriting cabal.project.local to include cardano-addresses and bech32 .."
    mv .tmp.cabal.project.local cabal.project.local
    cabal install bech32 cardano-addresses-cli  --overwrite-policy=always 2>&1 | tee /tmp/build-b32-caddr.log
  fi
else
  if [[ "${PWD##*/}" == "cardano-node" ]] || [[ "${PWD##*/}" == "cardano-db-sync" ]]; then
    echo "Overwriting cabal.project.local to include cardano-addresses and bech32 .."
    mv .tmp.cabal.project.local cabal.project.local
  fi
  echo "Running cabal update to ensure you're on latest dependencies.."
  cabal update 2>&1 | tee /tmp/cabal-update.log
  echo "Building.."
  cabal build all 2>&1 | tee tee /tmp/build.log
  [[ -f cabal.project.local ]] && cabal install bech32 cardano-addresses-cli  --overwrite-policy=always 2>&1 | tee /tmp/build-b32-caddr.log
fi

grep "^Linking" /tmp/build.log | grep -Ev 'test|golden|demo|chairman|locli|ledger|topology' | while read -r line ; do
    act_bin_path=$(echo "$line" | awk '{print $2}')
    act_bin=$(echo "$act_bin_path" | awk -F "/" '{print $NF}')
    echo "Copying $act_bin to ${HOME}/.cabal/bin/"
    cp -f "$act_bin_path" "${HOME}/.cabal/bin/"
done
