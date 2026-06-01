#!/usr/bin/env bash
# shellcheck disable=SC1090
# executes cabal build all
# parses executables created from compiler output and copies it to ~/.local/bin folder.

set -o pipefail

######################################
# Do NOT modify code below           #
######################################

run_logged() {
  local log_file="$1"
  shift
  "$@" 2>&1 | tee "${log_file}"
  local rc=${PIPESTATUS[0]}
  [[ ${rc} -eq 0 ]] || exit "${rc}"
}

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
	
	allow-newer:
	  *:aeson
	
	package HsOpenSSL
	  flags: +use-pkg-config
	EOF
chmod 640 .tmp.cabal.project.local

echo "Running cabal update to ensure you're on latest dependencies.."
run_logged /tmp/cabal-update.log cabal update
echo "Building.."

if [[ -z "${USE_SYSTEM_LIBSODIUM}" ]] ; then # Build using default cabal.project first and then add cabal.project.local for additional packages
  if [[ "${PWD##*/}" == "cardano-node" ]] || [[ "${PWD##*/}" == "cardano-db-sync" ]]; then
    [[ "${PWD##*/}" == "cardano-node" ]] && run_logged /tmp/build.log cabal build cardano-node cardano-cli cardano-submit-api --disable-tests --disable-profiling
    [[ "${PWD##*/}" == "cardano-db-sync" ]] && run_logged /tmp/build.log cabal build cardano-db-sync --disable-tests --disable-profiling
    if [[ "${CUSTOM_CABAL}" == "Y" ]]; then
      mv .tmp.cabal.project.local cabal.project.local
      run_logged /tmp/build-b32-caddr.log cabal install cardano-cli --overwrite-policy=always
    else
      [[ -f "cabal.project.local" ]] && mv cabal.project.local cabal.project.local_disabled
    fi
  else
    run_logged /tmp/build.log cabal build all --disable-tests --disable-profiling
  fi
else # Add cabal.project.local customisations first before building
  if [[ "${PWD##*/}" == "cardano-node" ]] || [[ "${PWD##*/}" == "cardano-db-sync" ]]; then
    if [[ "${CUSTOM_CABAL}" == "Y" ]]; then
      mv .tmp.cabal.project.local cabal.project.local
    else
      [[ -f "cabal.project.local" ]] && mv cabal.project.local cabal.project.local_disabled
    fi
    [[ "${PWD##*/}" == "cardano-node" ]] && run_logged /tmp/build.log cabal build cardano-node cardano-cli cardano-submit-api --disable-tests --disable-profiling
    [[ "${PWD##*/}" == "cardano-db-sync" ]] && run_logged /tmp/build.log cabal build cardano-db-sync --disable-tests --disable-profiling
  else
    run_logged /tmp/build.log cabal build all --disable-tests --disable-profiling
  fi
  [[ -f cabal.project.local ]] && run_logged /tmp/build-b32-caddr.log cabal install cardano-cli --overwrite-policy=always
fi

grep "Linking /" /tmp/build.log | grep -Ev 'test|golden|demo|chairman|locli|ledger|topology' | sed -e 's#^.*.Linking#Linking#g' | while read -r line ; do
    act_bin_path=$(echo "$line" | awk '{print $2}')
    act_bin=$(echo "$act_bin_path" | awk -F "/" '{print $NF}')
    echo "Copying $act_bin to ${HOME}/.local/bin/"
    cp -f "$act_bin_path" "${HOME}/.local/bin/"
done
