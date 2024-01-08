#!/usr/bin/env bash
# shellcheck disable=SC1090
# executes cabal build all
# parses executables created from compiler output and copies it to ~/.local/bin folder.

######################################
# Do NOT modify code below           #
######################################

echo "Deleting build config artifact to remove cached version, this prevents invalid Git Rev"
find dist-newstyle/build/x86_64-linux/ghc-8.10.?/cardano-config-* >/dev/null 2>&1 && rm -rf "dist-newstyle/build/x86_64-linux/ghc-8.*/cardano-config-*"

[[ -f /usr/lib/libsecp256k1.so ]] && export LD_LIBRARY_PATH=/usr/lib:"${LD_LIBRARY_PATH}"
[[ -f /usr/lib64/libsecp256k1.so ]] && export LD_LIBRARY_PATH=/usr/lib64:"${LD_LIBRARY_PATH}"
[[ -f /usr/local/lib/libsecp256k1.so ]] && export LD_LIBRARY_PATH=/usr/local/lib:"${LD_LIBRARY_PATH}"
[[ -d /usr/lib/pkgconfig ]] && export PKG_CONFIG_PATH=/usr/lib/pkgconfig:"${PKG_CONFIG_PATH}"
[[ -d /usr/lib64/pkgconfig ]] && export PKG_CONFIG_PATH=/usr/lib64/pkgconfig:"${PKG_CONFIG_PATH}"
[[ -d /usr/local/lib/pkgconfig ]] && export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:"${PKG_CONFIG_PATH}"

if [[ "$1" == "-l" ]] || [[ "$2" == "-l" ]]; then
  USE_SYSTEM_LIBSODIUM="package cardano-crypto-praos
    flags: -external-libsodium-vrf"
else
  unset USE_SYSTEM_LIBSODIUM
fi

if [[ "$1" == "-c" ]]; then
  CUSTOM_CABAL="Y"
else
  CUSTOM_CABAL="N"
fi

[[ -f cabal.project.local ]] && mv cabal.project.local cabal.project.local_bkp"$(date +%s)"
cat <<-EOF > .tmp.cabal.project.local
	${USE_SYSTEM_LIBSODIUM}
	
	source-repository-package
	    type: git
	    location: https://github.com/input-output-hk/hjsonpointer
	    tag: bb99294424e0c5b3c2942c743b545e4b01c12ce8
	    --sha256: 11z5s4xmm6cxy6sdcf9ly4lr0qh3c811hpm0bmlp4c3yq8v3m9rk
	
	source-repository-package
	    type: git
	    location: https://github.com/input-output-hk/hjsonschema
	    tag: 1546af7fc267d5eea805ef223dd2b59ac120b784
	    --sha256: 0sdikhsq6nnhmmvcpwzzrwfn9cn7rg75629qnrx01i5vm5ci4314
	
	source-repository-package
	    type: git
	    location: https://github.com/haskell-works/hw-aeson
	    tag: d99d2f3e39a287607418ae605b132a3deb2b753f
	    --sha256: 1vxqcwjg9q37wbwi27y9ba5163lzfz51f1swbi0rp681yg63zvn4
	
	source-repository-package
	  type: git
	  location: https://github.com/intersectmbo/bech32
	  tag: v1.1.2
	  subdir: bech32
	
	source-repository-package
	  type: git
	  location: https://github.com/intersectmbo/cardano-addresses
	  tag: 3.12.0
	  subdir:
	    command-line
	    core
	
	allow-newer:
	  *:aeson
	
	EOF
chmod 640 .tmp.cabal.project.local

echo "Running cabal update to ensure you're on latest dependencies.."
cabal update 2>&1 | tee /tmp/cabal-update.log
echo "Building.."

if [[ -z "${USE_SYSTEM_LIBSODIUM}" ]] ; then # Build using default cabal.project first and then add cabal.project.local for additional packages
  if [[ "${PWD##*/}" == "cardano-node" ]] || [[ "${PWD##*/}" == "cardano-db-sync" ]]; then
    #cabal install cardano-crypto-class --disable-tests --disable-profiling | tee /tmp/build.log
    [[ "${PWD##*/}" == "cardano-node" ]] && cabal build cardano-node cardano-cli cardano-submit-api --disable-tests --disable-profiling | tee /tmp/build.log
    [[ "${PWD##*/}" == "cardano-db-sync" ]] && cabal build cardano-db-sync --disable-tests --disable-profiling | tee /tmp/build.log
    if [[ "${CUSTOM_CABAL}" == "Y" ]]; then
      mv .tmp.cabal.project.local cabal.project.local
      cabal install bech32 cardano-addresses-cli --overwrite-policy=always 2>&1 | tee /tmp/build-b32-caddr.log
    else
      [[ -f "cabal.project.local" ]] && mv cabal.project.local cabal.project.local_disabled
    fi
  else
    cabal build all --disable-tests --disable-profiling 2>&1 | tee /tmp/build.log
  fi
else # Add cabal.project.local customisations first before building
  if [[ "${PWD##*/}" == "cardano-node" ]] || [[ "${PWD##*/}" == "cardano-db-sync" ]]; then
    if [[ "${CUSTOM_CABAL}" == "Y" ]]; then
      mv .tmp.cabal.project.local cabal.project.local
    else
      [[ -f "cabal.project.local" ]] && mv cabal.project.local cabal.project.local_disabled
    fi
    [[ "${PWD##*/}" == "cardano-node" ]] && cabal build cardano-node cardano-cli cardano-submit-api --disable-tests --disable-profiling | tee /tmp/build.log
    [[ "${PWD##*/}" == "cardano-db-sync" ]] && cabal build cardano-db-sync --disable-tests --disable-profiling | tee /tmp/build.log
  else
    cabal build all --disable-tests --disable-profiling 2>&1 | tee /tmp/build.log
  fi
  [[ -f cabal.project.local ]] && cabal install bech32 cardano-addresses-cli --overwrite-policy=always 2>&1 | tee /tmp/build-b32-caddr.log
fi

grep "^Linking" /tmp/build.log | grep -Ev 'test|golden|demo|chairman|locli|ledger|topology' | while read -r line ; do
    act_bin_path=$(echo "$line" | awk '{print $2}')
    act_bin=$(echo "$act_bin_path" | awk -F "/" '{print $NF}')
    echo "Copying $act_bin to ${HOME}/.local/bin/"
    cp -f "$act_bin_path" "${HOME}/.local/bin/"
done
