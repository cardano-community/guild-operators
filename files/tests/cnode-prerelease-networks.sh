#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2317,SC2329
# The Dijkstra and Musashi testnets pin their own node builds on top of release.json.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

BASE_RELEASE="${ROOT_DIR}/files/node-implementations/cnode/release.json"

# shellcheck source=../../scripts/cnode-helper-scripts/guild-deploy.sh
. "${ROOT_DIR}/scripts/cnode-helper-scripts/guild-deploy.sh"
# shellcheck source=../../scripts/cnode-helper-scripts/deploy-cnode.sh
. "${ROOT_DIR}/scripts/cnode-helper-scripts/deploy-cnode.sh"
GIT_SOURCE_ROOT="${ROOT_DIR}"

log_progress() { :; }
log_info() { :; }
log_ok() { :; }
err_exit() { fail "err_exit: $*"; }

render_release() { # $1 = network, sets RELEASE
  NETWORK="$1"
  RELEASE="${TEST_ROOT}/$1-release.json"
  rm -f -- "${RELEASE}"
  cnode_deploy_render_release_metadata "${RELEASE}" || fail "$1 release metadata did not render"
  cnode_deploy_validate_release_metadata "${RELEASE}" || fail "$1 release metadata is invalid"
}

# --- other networks keep release.json unchanged --------------------------------
for network in mainnet preprod preview guild; do
  render_release "${network}"
  cmp -s "${BASE_RELEASE}" "${RELEASE}" || fail "${network} must use release.json as it is"
done
assert_eq "$(jq -er '.companions | has("cardano-db-sync")' "${BASE_RELEASE}")" "true" "release.json pins db-sync"

# --- pinned versions ------------------------------------------------------------
render_release dijkstra
assert_eq "$(jq -er '.version' "${RELEASE}")" "11.2.0" "Dijkstra node"
assert_eq "$(jq -er '.companions["cardano-cli"].version' "${RELEASE}")" "11.6.0.0" "Dijkstra cli"
assert_eq "$(jq -er '.companions["cardano-db-sync"].version' "${RELEASE}")" "13.8.0.0" "Dijkstra db-sync"
[[ "$(jq -er '.artifacts["linux-x86_64"].url' "${RELEASE}")" == */cardano-node/releases/download/11.2.0/* ]] ||
  fail "Dijkstra node comes from the 11.2.0 release"

render_release musashi
assert_eq "$(jq -er '.version' "${RELEASE}")" "11.2.0.164" "Musashi node"
assert_eq "$(jq -er '.companions["cardano-cli"].version' "${RELEASE}")" "11.3.1.0" "Musashi cli"
assert_eq "$(jq -er '.companions | has("cardano-db-sync")' "${RELEASE}")" "false" "Musashi has no db-sync build"
assert_eq "$(jq -er '.companions["cardano-node-support"].version' "${RELEASE}")" "11.2.0" "Musashi support tools"
[[ "$(jq -er '.artifacts["linux-aarch64"].url' "${RELEASE}")" == */ouroboros-leios/releases/download/rc-*/* ]] ||
  fail "Musashi node comes from a Leios release"
assert_eq "$(jq -c '.tools' "${RELEASE}")" "$(jq -c '.tools' "${BASE_RELEASE}")" "tools stay in release.json"

# A missing overlay must not silently deploy the mainnet build.
( cnode_deploy_release_overlay_path() { printf 'files/node-implementations/cnode/networks/missing.json'; }
  NETWORK=dijkstra
  ! cnode_deploy_render_release_metadata "${TEST_ROOT}/missing-release.json" 2>/dev/null ||
    fail "a missing overlay should fail" )

# --- CNTools accepts each network's CLI, and only on that network ----------------
eval "$(sed -n '/^cntools_transaction_cli_version_supported() {/,/^}/p' \
  "${ROOT_DIR}/scripts/common-helper-scripts/cntools/lib/transaction.sh")"
CNTOOLS_TRANSACTION_CARDANO_CLI_VERSION="$(jq -er '.companions["cardano-cli"].version' "${BASE_RELEASE}")"
CNTOOLS_TRANSACTION_SOURCE_BUILD_CLI_VERSION="$(jq -er '.build.cardanoCli' "${BASE_RELEASE}")"
for network in dijkstra musashi; do
  cli="$(jq -er '.companions["cardano-cli"].version' \
    "${ROOT_DIR}/files/node-implementations/cnode/networks/${network}.json")"
  CNTOOLS_NETWORK="${network}"
  cntools_transaction_cli_version_supported "${cli}" || fail "CNTools rejects the ${network} cli ${cli}"
  CNTOOLS_NETWORK="mainnet"
  ! cntools_transaction_cli_version_supported "${cli}" || fail "CNTools accepts the ${network} cli on mainnet"
done
unset CNTOOLS_NETWORK

# --- CNTools maps both networks everywhere it maps a network ---------------------
for spec in \
  lib/transaction.sh:cntools_transaction_network_arguments_into \
  lib/wallet-address.sh:cntools_wallet_address_network_arguments \
  lib/wallet-query-transport.sh:cntools_wallet_query_network_arguments \
  core/health.sh:cntools_health_reference_slot \
  core/health.sh:cntools_slot_datetime_into \
  core/health.sh:cntools_epoch_start_slot_into; do
  file="${spec%%:*}"
  definition="$(sed -n "/^${spec##*:}() {/,/^}/p" \
    "${ROOT_DIR}/scripts/common-helper-scripts/cntools/${file}")"
  [[ -n "${definition}" ]] || fail "CNTools no longer defines ${spec##*:}"
  eval "${definition}"
done
for spec in dijkstra:6:86400 musashi:164:21600; do
  IFS=: read -r network magic epoch_length <<< "${spec}"
  CNTOOLS_NETWORK="${network}"
  arguments=()
  cntools_transaction_network_arguments_into arguments "${network}" || fail "${network} has no transaction magic"
  assert_eq "${arguments[*]}" "--testnet-magic ${magic}" "${network} transaction magic"
  cntools_wallet_address_network_arguments || fail "${network} has no address magic"
  assert_eq "${CNTOOLS_WALLET_ADDRESS_NETWORK_ARGS[*]}" "--testnet-magic ${magic}" "${network} address magic"
  cntools_wallet_query_network_arguments || fail "${network} has no query magic"
  assert_eq "${CNTOOLS_WALLET_NETWORK_ARGS[*]}" "--testnet-magic ${magic}" "${network} query magic"
  genesis="${ROOT_DIR}/files/configs/cnode/${network}/shelley-genesis.json"
  start="$(jq -er '.systemStart | fromdateiso8601' "${genesis}")"
  assert_eq "$(cntools_health_reference_slot "${network}" "$((start + 1000))")" "1000" "${network} slot from its start"
  assert_eq "$(jq -er '.epochLength' "${genesis}")" "${epoch_length}" "${network} epoch length"
  first_slot=""
  CNTOOLS_SHELLEY_GENESIS=""
  cntools_epoch_start_slot_into first_slot 3 || fail "${network} has no epoch mapping"
  assert_eq "${first_slot}" "$((3 * epoch_length))" "${network} epoch start slot"
  # A slot converts back to its time, though these networks started after the conversion's old reference date.
  slot_time=""
  cntools_timestamp_datetime_into() { printf -v "$1" '%s' "$2"; }
  cntools_slot_datetime_into slot_time 1000 || fail "${network} has no slot time"
  assert_eq "${slot_time}" "$((start + 1000))" "${network} slot time"
done
for network in mainnet guild preprod preview; do
  CNTOOLS_NETWORK="${network}"
  arguments=()
  cntools_transaction_network_arguments_into arguments "${network}" || fail "${network} lost its transaction magic"
  # Moving the conversion's reference date must not change slot times on the networks that already worked.
  old_reference="$(cntools_health_reference_slot "${network}" 1700000000)"
  cntools_slot_datetime_into slot_time 90000000 || fail "${network} has no slot time"
  assert_eq "${slot_time}" "$((1700000000 + 90000000 - old_reference))" "${network} slot time unchanged"
done
unset CNTOOLS_NETWORK

# --- CNTools runs without Koios on these networks only ---------------------------
for glv_function in cntools_startup_resolve_koios_api cntools_startup_default_koios_api; do
  definition="$(sed -n "/^${glv_function}() {/,/^}/p" \
    "${ROOT_DIR}/scripts/common-helper-scripts/cntools/core/startup.sh")"
  [[ -n "${definition}" ]] || fail "CNTools no longer defines ${glv_function}"
  eval "${definition}"
done
cntools_startup_error() { STARTUP_ERROR="$*"; }
for network in dijkstra musashi; do
  CNTOOLS_NETWORK="${network}" CNTOOLS_KOIOS_API="" CNTOOLS_KOIOS_ENABLED="Y"
  cntools_startup_resolve_koios_api || fail "CNTools should start on ${network} without Koios"
  assert_eq "${CNTOOLS_KOIOS_ENABLED}" "N" "${network} runs from the local node"
  CNTOOLS_KOIOS_API="https://koios.example/api/v1" CNTOOLS_KOIOS_ENABLED="Y"
  cntools_startup_resolve_koios_api || fail "a configured Koios endpoint should work on ${network}"
  assert_eq "${CNTOOLS_KOIOS_ENABLED}" "Y" "a configured endpoint stays enabled on ${network}"
done
CNTOOLS_NETWORK="preview" CNTOOLS_KOIOS_API="" CNTOOLS_KOIOS_ENABLED="Y"
cntools_startup_resolve_koios_api || fail "preview should have a default Koios endpoint"
assert_eq "${CNTOOLS_KOIOS_ENABLED}" "Y" "preview keeps Koios"
[[ "${CNTOOLS_KOIOS_API}" == https://preview.koios.rest/* ]] || fail "preview default endpoint"
CNTOOLS_NETWORK="unknown" CNTOOLS_KOIOS_API=""
! cntools_startup_resolve_koios_api || fail "an unknown network should still be refused"
unset CNTOOLS_NETWORK

# --- network configuration ------------------------------------------------------
for spec in dijkstra:6 musashi:164; do
  network="${spec%%:*}"
  config_dir="${ROOT_DIR}/files/configs/cnode/${network}"
  assert_eq "$(jq -er '.networkMagic' "${config_dir}/shelley-genesis.json")" "${spec##*:}" "${network} magic"
  jq -e '(.Configuration.HermodTracing // .) |
    .TraceOptionNodeName == "cnode" and
    (.TraceOptions[""].backends | any(. == "PrometheusSimple suffix 127.0.0.1 12798"))' \
    "${config_dir}/config.json" >/dev/null || fail "${network} tracing does not suit gLiveView"
  jq -e '(.Configuration.Protocol // .) | .ShelleyGenesisFile == "/opt/cardano/cnode/files/shelley-genesis.json"' \
    "${config_dir}/config.json" >/dev/null || fail "${network} genesis paths are not deployment paths"
  [[ "$(jq -er '.peerSnapshotFile' "${config_dir}/topology.json")" == "peer-snapshot.json" ]] ||
    fail "${network} topology does not use the peer snapshot"
done

# --- the adapter reads both config formats --------------------------------------
adapter_section="$(sed -n '/read -ra CONFIG_CONTENTS/,/if \[\[ -n "\${PROM_HOST}" && -n "\${PROM_PORT}" \]\]; then/p' \
  "${ROOT_DIR}/scripts/cnode-helper-scripts/cnode.adapter" | sed '$d')"
[[ -n "${adapter_section}" ]] || fail "the adapter's config section was not found"
eval "read_adapter_config() { CCLI=true; PROM_HOST=''; PROM_PORT=''; ${adapter_section}
}"

for spec in dijkstra:nested musashi:flat preview:flat; do
  network="${spec%%:*}"
  files="${TEST_ROOT}/${network}-files"
  mkdir -p "${files}"
  cp "${ROOT_DIR}/files/configs/cnode/${network}/"*.json "${files}/"
  sed -i.bak "s#/opt/cardano/cnode/files#${files}#g" "${files}/config.json"
  CONFIG="${files}/config.json"
  read_adapter_config || fail "${network} config was not read"
  assert_eq "${GENESIS_JSON}" "${files}/shelley-genesis.json" "${network} Shelley genesis"
  assert_eq "${CONWAY_GENESIS_JSON}" "${files}/conway-genesis.json" "${network} Conway genesis"
  assert_eq "${PROM_PORT}" "12798" "${network} Prometheus port"
  assert_eq "${PROM_HOST}" "127.0.0.1" "${network} Prometheus host"
  if [[ "${network}" == "preview" ]]; then
    assert_eq "${DIJKSTRA_GENESIS_JSON}" "null" "preview has no Dijkstra genesis"
  else
    assert_eq "${DIJKSTRA_GENESIS_JSON}" "${files}/dijkstra-genesis.json" "${network} Dijkstra genesis"
  fi
done

# --- installing the binaries ----------------------------------------------------
if ! tar --version 2>/dev/null | grep -q GNU; then
  printf 'cnode pre-release network tests passed (binary install skipped: needs GNU tar)\n'
  exit 0
fi

fake_binary() { # $1 = path, $2 = name, $3 = version
  mkdir -p "$(dirname -- "$1")"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s %s - linux-x86_64"\n' "$2" "$3" > "$1"
  chmod 755 "$1"
}

# Archives with each release's real layout, picked by what is being downloaded.
cnode_deploy_download_resolved_artifact() {
  local destination="$1" work
  work="$(mktemp -d "${TEST_ROOT}/archive.XXXXXX")"
  case "${CNODE_RESOLVED_URL}" in
    */ouroboros-leios/*)
      fake_binary "${work}/bin/cardano-node" cardano-node "${CNODE_RESOLVED_VERSION}"
      fake_binary "${work}/bin/cardano-cli" cardano-cli "${LEIOS_CLI}"
      tar czf "${destination}" -C "${work}" bin/cardano-node bin/cardano-cli
      LEIOS_DOWNLOADS=$((LEIOS_DOWNLOADS + 1))
      ;;
    */cardano-node/releases/*)
      fake_binary "${work}/bin/cardano-node" cardano-node "${CNODE_RESOLVED_VERSION}"
      fake_binary "${work}/bin/cardano-submit-api" cardano-submit-api "${CNODE_RESOLVED_VERSION}"
      fake_binary "${work}/bin/bech32" bech32 "${CNODE_RESOLVED_VERSION}"
      tar czf "${destination}" -C "${work}" ./bin/cardano-node ./bin/cardano-submit-api ./bin/bech32
      ;;
    */cardano-cli/releases/*)
      fake_binary "${work}/cardano-cli-x86_64-linux" cardano-cli "${CNODE_RESOLVED_VERSION}"
      tar czf "${destination}" -C "${work}" cardano-cli-x86_64-linux
      ;;
    */ci.iog.io/*)
      fake_binary "${work}/bin/cardano-db-sync" cardano-db-sync "${CNODE_RESOLVED_VERSION}"
      tar czf "${destination}" -C "${work}" ./bin/cardano-db-sync
      ;;
    */cardano-db-sync-*)
      fake_binary "${work}/cardano-db-sync" cardano-db-sync "${CNODE_RESOLVED_VERSION}"
      tar czf "${destination}" -C "${work}" ./cardano-db-sync
      ;;
    */cardano-address-*)
      fake_binary "${work}/cardano-address" cardano-address "${CNODE_RESOLVED_VERSION}"
      tar czf "${destination}" -C "${work}" cardano-address
      ;;
    *) fail "unexpected download ${CNODE_RESOLVED_URL}" ;;
  esac
}

cnode_deploy_architecture() { printf 'linux-x86_64'; }

install_network() { # $1 = network; leaves the result in HOME
  HOME="${TEST_ROOT}/$1-home"
  NODE_HOME="${TEST_ROOT}/$1-node"
  mkdir -p "${HOME}" "${NODE_HOME}/files"
  NETWORK="$1"
  TMPDIR="${TEST_ROOT}"
  CNODE_SKIP_DBSYNC_DOWNLOAD="N"
  LEIOS_DOWNLOADS=0
  LEIOS_CLI="11.3.1.0"
  render_release "$1"
  cp "${RELEASE}" "${NODE_HOME}/files/cnode-release.json"
  download_cnodebins
  popd -0 >/dev/null 2>&1 || true
}

reports() { # $1 = binary, $2 = version
  "${HOME}/.local/bin/$1" --version | grep -qF " $2 " || fail "$1 does not report $2"
}

install_network dijkstra
reports cardano-node 11.2.0
reports cardano-cli 11.6.0.0
reports cardano-db-sync 13.8.0.0
reports cardano-submit-api 11.2.0
reports bech32 11.2.0

install_network musashi
reports cardano-node 11.2.0.164
reports cardano-cli 11.3.1.0
reports cardano-submit-api 11.2.0
reports bech32 11.2.0
[[ ! -e "${HOME}/.local/bin/cardano-db-sync" ]] || fail "Musashi has no db-sync to install"
assert_eq "${LEIOS_DOWNLOADS}" "1" "the Leios archive holds both the node and its CLI"

install_network preview
reports cardano-node "$(jq -er '.version' "${BASE_RELEASE}")"
reports cardano-cli "$(jq -er '.companions["cardano-cli"].version' "${BASE_RELEASE}")"
reports cardano-db-sync "$(jq -er '.companions["cardano-db-sync"].version' "${BASE_RELEASE}")"

printf 'cnode pre-release network tests passed\n'
