#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2317,SC2329
# A refresh moves an operator's PraosMode config and topology to GenesisMode,
# keeps everything else they set, and installs the peer snapshot and checkpoints
# every time. guild stays as it is.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../../scripts/cnode-helper-scripts/guild-deploy.sh
. "${ROOT_DIR}/scripts/cnode-helper-scripts/guild-deploy.sh"
# shellcheck source=../../scripts/cnode-helper-scripts/deploy-cnode.sh
. "${ROOT_DIR}/scripts/cnode-helper-scripts/deploy-cnode.sh"

WARNINGS="${TEST_ROOT}/warnings"
log_progress() { :; }
log_info() { :; }
log_ok() { :; }
log_warn() { printf '%s\n' "$*" >> "${WARNINGS}"; }
err_exit() { fail "err_exit: $*"; }

NODE_HOME="${TEST_ROOT}/node"
FILES="${NODE_HOME}/files"

# Stage the shipped files for $1 as a refresh does: *.json.tmp with this
# deployment's paths.
stage() { # $1 = network
  local source="${ROOT_DIR}/files/configs/cnode/$1" name
  for name in alonzo-genesis.json byron-genesis.json conway-genesis.json shelley-genesis.json \
              dijkstra-genesis.json topology.json config.json peer-snapshot.json checkpoints.json; do
    [[ -f "${source}/${name}" ]] || continue
    sed -e "s@/opt/cardano/cnode@${NODE_HOME}@g" "${source}/${name}" > "${FILES}/${name}.tmp"
  done
  sed -e "s@/opt/cardano/cnode@${NODE_HOME}@g" "${source}/db-sync-config.json" > "${FILES}/dbsync.json.tmp"
}

# A deployment made before the switch: the shipped files as they were, in
# PraosMode with bootstrap peers and the old LedgerDB layout, plus the
# operator's own relays and settings.
old_deployment() { # $1 = network
  rm -rf -- "${NODE_HOME}" "${WARNINGS}"
  mkdir -p "${FILES}"
  NETWORK="$1"
  stage "$1"
  local name
  for name in alonzo-genesis.json byron-genesis.json conway-genesis.json shelley-genesis.json dijkstra-genesis.json dbsync.json; do
    [[ -f "${FILES}/${name}.tmp" ]] && cp "${FILES}/${name}.tmp" "${FILES}/${name}"
  done
  jq 'if has("Configuration") then .Configuration.Consensus.ConsensusMode = "PraosMode"
      else .ConsensusMode = "PraosMode" end |
      walk(if type == "object" then del(.CheckpointsFile, .MinBigLedgerPeersForTrustedState) else . end) |
      if (.LedgerDB.Snapshots | type) == "object" then .LedgerDB = (.LedgerDB | del(.Snapshots)) + .LedgerDB.Snapshots else . end |
      .MempoolCapacityBytesOverride = 12345' \
    "${FILES}/config.json.tmp" > "${FILES}/config.json"
  jq '.bootstrapPeers = [{address: "backbone.example", port: 3001}] |
      del(.peerSnapshotFile) | .useLedgerAfterSlot = 1 |
      .localRoots = [{accessPoints: [{address: "relay.operator.example", port: 6000}], advertise: false, trustable: false, valency: 1}]' \
    "${FILES}/topology.json.tmp" > "${FILES}/topology.json"
}

refresh() {
  (cd "${FILES}" && cnode_deploy_install_network_files)
  [[ -z "$(find "${FILES}" -name '*.tmp' -o -name '*.migrated')" ]] || fail "staged files were left behind"
}

backups() { find "${FILES}" -name '*_bkp*' | wc -l | tr -d ' '; }

# --- a mainnet relay ---------------------------------------------------------------
CNODE_DEPLOY_FORCE_CONFIG="N"
old_deployment mainnet
shipped_ulas="$(jq -r '.useLedgerAfterSlot' "${FILES}/topology.json.tmp")"
cp "${FILES}/shelley-genesis.json" "${TEST_ROOT}/operator-genesis.json"
jq '.operatorMark = true' "${TEST_ROOT}/operator-genesis.json" > "${FILES}/shelley-genesis.json"
refresh
config="${FILES}/config.json"
topology="${FILES}/topology.json"
[[ "$(jq -r '.ConsensusMode' "${config}")" == "GenesisMode" ]] || fail "mainnet config is not in GenesisMode"
[[ "$(jq -r '.CheckpointsFile' "${config}")" == "${FILES}/checkpoints.json" ]] || fail "mainnet config does not use the checkpoints"
[[ "$(jq -r '.MempoolCapacityBytesOverride' "${config}")" == "12345" ]] || fail "the operator's own setting was lost"
[[ "$(jq -c '.LedgerDB.Snapshots' "${config}")" == '{"NumOfDiskSnapshots":2,"SlotOffset":0,"SnapshotInterval":43200}' ]] ||
  fail "LedgerDB snapshot options did not move into LedgerDB.Snapshots"
jq -e '.LedgerDB | has("NumOfDiskSnapshots", "SnapshotInterval", "SlotOffset") | not' "${config}" >/dev/null ||
  fail "LedgerDB snapshot options are set twice, which the node refuses"
jq -e 'has("bootstrapPeers") | not' "${topology}" >/dev/null || fail "bootstrap peers are still there"
[[ "$(jq -r '.localRoots[0].accessPoints[0].address' "${topology}")" == "relay.operator.example" ]] || fail "the operator's relay was lost"
[[ "$(jq -r '.localRoots[0].trustable' "${topology}")" == "false" ]] || fail "a relay's local roots were made trustable"
[[ "$(jq -r '.peerSnapshotFile' "${topology}")" == "peer-snapshot.json" ]] || fail "no peer snapshot in the topology"
[[ "$(jq -r '.useLedgerAfterSlot' "${topology}")" == "${shipped_ulas}" ]] || fail "useLedgerAfterSlot does not follow the snapshot"
cmp -s "${FILES}/peer-snapshot.json" "${ROOT_DIR}/files/configs/cnode/mainnet/peer-snapshot.json" || fail "peer snapshot not installed"
cmp -s "${FILES}/checkpoints.json" "${ROOT_DIR}/files/configs/cnode/mainnet/checkpoints.json" || fail "checkpoints not installed"
jq -e '.operatorMark' "${FILES}/shelley-genesis.json" >/dev/null || fail "an existing genesis file was replaced without -s f"
[[ "$(backups)" == "2" ]] || fail "expected a backup of config.json and topology.json, found $(backups)"
[[ "$(jq -r '.ConsensusMode' "$(find "${FILES}" -name 'config.json_bkp*')")" == "PraosMode" ]] || fail "the backup is not the old config"

# A second refresh changes nothing and makes no new backups.
before="$(cat "${config}" "${topology}" | sha256sum)"
stage mainnet
refresh
[[ "$(cat "${config}" "${topology}" | sha256sum)" == "${before}" ]] || fail "a second refresh changed the files"
[[ "$(backups)" == "2" ]] || fail "a second refresh made new backups"

# --- a block producer: ledger peers off, only its own relays -------------------------
old_deployment preprod
jq '.useLedgerAfterSlot = -1 | .publicRoots = [] |
    .localRoots = [
      {accessPoints: [{address: "relay1.operator.example", port: 6000}], advertise: false, trustable: true, valency: 1},
      {accessPoints: [{address: "relay2.operator.example", port: 6000}], advertise: false, trustable: false, valency: 1}
    ]' "${FILES}/topology.json" > "${FILES}/topology.next" && mv "${FILES}/topology.next" "${FILES}/topology.json"
refresh
topology="${FILES}/topology.json"
jq -e '[.localRoots[].trustable] | all' "${topology}" >/dev/null || fail "a block producer's local roots are not all trustable"
[[ "$(jq -r '.useLedgerAfterSlot' "${topology}")" == "-1" ]] || fail "a block producer's ledger peers were turned on"
jq -e 'has("peerSnapshotFile") | not' "${topology}" >/dev/null || fail "a block producer got a peer snapshot"
jq -e 'has("bootstrapPeers") | not' "${topology}" >/dev/null || fail "a block producer kept bootstrap peers"
[[ "$(jq '.localRoots | length' "${topology}")" == "2" ]] || fail "a block producer's relays changed"
jq -e 'has("CheckpointsFile") | not' "${FILES}/config.json" >/dev/null || fail "preprod has no checkpoints to use"
[[ ! -e "${FILES}/checkpoints.json" ]] || fail "preprod got a checkpoints file"

# A block producer without local roots has nobody to sync from: leave it and say so.
old_deployment preprod
jq '.useLedgerAfterSlot = -1 | .localRoots = []' "${FILES}/topology.json" > "${FILES}/topology.next" &&
  mv "${FILES}/topology.next" "${FILES}/topology.json"
cp "${FILES}/topology.json" "${TEST_ROOT}/peerless.json"
refresh
cmp -s "${FILES}/topology.json" "${TEST_ROOT}/peerless.json" || fail "a topology without peers was changed"
grep -qF "has no local roots" "${WARNINGS}" || fail "a topology without peers was not reported"

# --- Musashi and Dijkstra: the shipped trust threshold, in either config layout -----
old_deployment musashi
refresh
[[ "$(jq -r '.ConsensusMode' "${FILES}/config.json")" == "GenesisMode" ]] || fail "musashi config is not in GenesisMode"
[[ "$(jq -r '.MinBigLedgerPeersForTrustedState' "${FILES}/config.json")" == "1" ]] || fail "musashi did not get the shipped trust threshold"

old_deployment dijkstra
refresh
[[ "$(jq -r '.Configuration.Consensus.ConsensusMode' "${FILES}/config.json")" == "GenesisMode" ]] || fail "dijkstra config is not in GenesisMode"
[[ "$(jq -r '.Configuration.Network.MinBigLedgerPeersForTrustedState' "${FILES}/config.json")" == "1" ]] ||
  fail "dijkstra did not get the shipped trust threshold"
jq -e 'has("ConsensusMode") | not' "${FILES}/config.json" >/dev/null || fail "a flat key was added to a nested config"

# A config in another layout than the shipped one is left alone, with a warning.
old_deployment dijkstra
jq '{ConsensusMode: "PraosMode", Protocol: "Cardano"}' "${FILES}/config.json" > "${FILES}/config.next" &&
  mv "${FILES}/config.next" "${FILES}/config.json"
refresh
[[ "$(jq -r '.ConsensusMode' "${FILES}/config.json")" == "PraosMode" ]] || fail "a config in another layout was changed"
grep -qF "another layout" "${WARNINGS}" || fail "a config in another layout was not reported"

# --- guild stays in PraosMode --------------------------------------------------------
old_deployment guild
cp "${FILES}/config.json" "${TEST_ROOT}/guild-config.json"
cp "${FILES}/topology.json" "${TEST_ROOT}/guild-topology.json"
refresh
cmp -s "${FILES}/config.json" "${TEST_ROOT}/guild-config.json" || fail "the guild config was changed"
cmp -s "${FILES}/topology.json" "${TEST_ROOT}/guild-topology.json" || fail "the guild topology was changed"
[[ ! -e "${FILES}/peer-snapshot.json" ]] || fail "guild got a peer snapshot"

# --- only the missing file is installed --------------------------------------------
old_deployment preview
rm -f "${FILES}/conway-genesis.json"
cp "${FILES}/topology.json" "${TEST_ROOT}/preview-topology.json"
refresh
[[ -f "${FILES}/conway-genesis.json" ]] || fail "a missing genesis file was not installed"
[[ "$(jq -r '.localRoots[0].accessPoints[0].address' "${FILES}/topology.json")" == "relay.operator.example" ]] ||
  fail "a missing genesis file replaced the operator's topology"

# --- a forced overwrite installs the shipped files ------------------------------------
old_deployment mainnet
CNODE_DEPLOY_FORCE_CONFIG="Y"
refresh
CNODE_DEPLOY_FORCE_CONFIG="N"
cmp -s "${FILES}/topology.json" <(sed -e "s@/opt/cardano/cnode@${NODE_HOME}@g" "${ROOT_DIR}/files/configs/cnode/mainnet/topology.json") ||
  fail "-s f did not install the shipped topology"
[[ "$(jq -r '.MempoolCapacityBytesOverride' "${FILES}/config.json")" == "67108864" ]] || fail "-s f did not install the shipped config"

# --- a new deployment ----------------------------------------------------------------
rm -rf -- "${NODE_HOME}"
mkdir -p "${FILES}"
NETWORK=preview
stage preview
refresh
for name in alonzo-genesis.json byron-genesis.json conway-genesis.json shelley-genesis.json topology.json config.json \
            dbsync.json peer-snapshot.json checkpoints.json; do
  [[ -f "${FILES}/${name}" ]] || fail "a new deployment has no ${name}"
done
[[ "$(backups)" == "0" ]] || fail "a new deployment made backups"

# --- cnode.sh before every start ----------------------------------------------------
# Pool keys and the block producer layout usually come after the deployment, so
# the node's start script trusts the local roots of a GenesisMode node that turns
# ledger peers off.
eval "$(sed -n '/^check_genesis_topology() {/,/^}/p' "${ROOT_DIR}/scripts/cnode-helper-scripts/cnode.sh")"
declare -F check_genesis_topology >/dev/null || fail "cnode.sh has no check_genesis_topology"
rm -rf -- "${NODE_HOME}"
mkdir -p "${FILES}" "${NODE_HOME}/priv/pool/pool1"
CONFIG="${FILES}/config.json"
TOPOLOGY="${FILES}/topology.json"
POOL_FOLDER="${NODE_HOME}/priv/pool" POOL_NAME="pool1"
POOL_OPCERT_FILENAME="op.cert" POOL_VRF_SK_FILENAME="vrf.skey" POOL_HOTKEY_SK_FILENAME="hot.skey"
touch "${POOL_FOLDER}/pool1/op.cert" "${POOL_FOLDER}/pool1/vrf.skey" "${POOL_FOLDER}/pool1/hot.skey"
cp "${ROOT_DIR}/files/configs/cnode/preprod/config.json" "${CONFIG}"
jq '.useLedgerAfterSlot = -1 | .bootstrapPeers = [{address: "backbone.example", port: 3001}]' \
  "${ROOT_DIR}/files/configs/cnode/preprod/topology.json" > "${TOPOLOGY}"
output="$(check_genesis_topology)"
jq -e '[.localRoots[].trustable] | all' "${TOPOLOGY}" >/dev/null || fail "cnode.sh did not trust a block producer's local roots"
jq -e 'has("bootstrapPeers") | not' "${TOPOLOGY}" >/dev/null || fail "cnode.sh kept a block producer's bootstrap peers"
grep -qF "now trustable" <<< "${output}" || fail "cnode.sh did not say it changed the topology"
[[ "$(backups)" == "1" ]] || fail "cnode.sh changed the topology without a backup"
output="$(check_genesis_topology)"
[[ -z "${output}" && "$(backups)" == "1" ]] || fail "cnode.sh changed a topology that was already right"

# A block producer that reads ledger peers is told, not changed.
jq '.useLedgerAfterSlot = 100' "${TOPOLOGY}" > "${TOPOLOGY}.next" && mv "${TOPOLOGY}.next" "${TOPOLOGY}"
cp "${TOPOLOGY}" "${TEST_ROOT}/bp-relay-layout.json"
grep -qF "connects to public relays" <<< "$(check_genesis_topology)" || fail "cnode.sh did not warn about a block producer on ledger peers"
cmp -s "${TOPOLOGY}" "${TEST_ROOT}/bp-relay-layout.json" || fail "cnode.sh changed a block producer that reads ledger peers"

# PraosMode (guild) is left alone.
cp "${ROOT_DIR}/files/configs/cnode/guild/config.json" "${CONFIG}"
jq '.useLedgerAfterSlot = -1 | .localRoots[].trustable = false' "${TOPOLOGY}" > "${TOPOLOGY}.next" && mv "${TOPOLOGY}.next" "${TOPOLOGY}"
cp "${TOPOLOGY}" "${TEST_ROOT}/praos-topology.json"
[[ -z "$(check_genesis_topology)" ]] || fail "cnode.sh spoke about a PraosMode node"
cmp -s "${TOPOLOGY}" "${TEST_ROOT}/praos-topology.json" || fail "cnode.sh changed a PraosMode topology"

printf 'cnode-genesis-migration: PASS\n'
