#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2317,SC2329
# Kept configuration on a GenesisMode network. A plain refresh leaves the
# operator's config and topology as they are and records what this release
# would change; -s u moves them from PraosMode to GenesisMode in place,
# keeping everything else they set and a backup; -s f replaces them. The peer
# snapshot and checkpoints are installed every time, and guild stays as it is.
# cnode.sh only warns, and Amaru's environment file follows the same rule.
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

# refresh [u]: a refresh, with -s u when asked.
refresh() {
  CNODE_DEPLOY_UPDATE_CONFIG=N
  [[ "${1:-}" != u ]] || CNODE_DEPLOY_UPDATE_CONFIG=Y
  cd "${FILES}"
  cnode_deploy_install_network_files
  cd "${TEST_ROOT}"
  [[ -z "$(find "${FILES}" -name '*.tmp' -o -name '*.migrated')" ]] || fail "staged files were left behind"
}

backups() { find "${FILES}" -name '*_bkp*' | wc -l | tr -d ' '; }

# --- a mainnet relay ---------------------------------------------------------------
CNODE_DEPLOY_FORCE_CONFIG="N"
old_deployment mainnet
shipped_ulas="$(jq -r '.useLedgerAfterSlot' "${FILES}/topology.json.tmp")"
cp "${FILES}/shelley-genesis.json" "${TEST_ROOT}/operator-genesis.json"
jq '.operatorMark = true' "${TEST_ROOT}/operator-genesis.json" > "${FILES}/shelley-genesis.json"
config="${FILES}/config.json"
topology="${FILES}/topology.json"

# A plain refresh changes neither file, says what -s u would do, and records it.
cp "${config}" "${TEST_ROOT}/kept-config.json"
cp "${topology}" "${TEST_ROOT}/kept-topology.json"
refresh
cmp -s "${config}" "${TEST_ROOT}/kept-config.json" || fail "a plain refresh changed config.json"
cmp -s "${topology}" "${TEST_ROOT}/kept-topology.json" || fail "a plain refresh changed topology.json"
[[ "$(backups)" == "0" ]] || fail "a plain refresh made backups"
[[ "${PROFILE_PENDING_CONFIG_FILES}" == "files/config.json files/topology.json" ]] ||
  fail "the pending files were not recorded: '${PROFILE_PENDING_CONFIG_FILES}'"
[[ "${PROFILE_PENDING_CONFIG_REASON}" == "GenesisMode: the public bootstrap peers are being shut down" ]] ||
  fail "the pending reason was not recorded: '${PROFILE_PENDING_CONFIG_REASON}'"
grep -qF "config.json and topology.json still need this release's GenesisMode changes" "${WARNINGS}" ||
  fail "a plain refresh did not warn about the pending changes"
grep -qF -- "-s u" "${WARNINGS}" || fail "the warning does not name -s u"
cmp -s "${FILES}/peer-snapshot.json" "${ROOT_DIR}/files/configs/cnode/mainnet/peer-snapshot.json" ||
  fail "a plain refresh did not install the peer snapshot"

# The manifest carries the record for gLiveView and cnode.sh.
dispatcher_detect_node_version() { printf '11.1.3'; }
NODE_IMPLEMENTATION=cnode BRANCH=test G_ACCOUNT=cardano-community NODE_SERVICE=cnode
DEPLOYMENT_FILE="${NODE_HOME}/.deployment.json"
dispatcher_write_manifest deployed N
[[ "$(jq -c '.pendingConfigUpdate' "${DEPLOYMENT_FILE}")" == \
   '{"reason":"GenesisMode: the public bootstrap peers are being shut down","files":["files/config.json","files/topology.json"]}' ]] ||
  fail "the manifest does not record the pending update: $(jq -c '.pendingConfigUpdate' "${DEPLOYMENT_FILE}")"
grep -qF "${NODE_HOME}/scripts/guild-deploy.sh -s u" <<< "$(dispatcher_pending_config_report)" ||
  fail "the end of the deployment does not repeat the pending update"

# -s u makes the changes.
stage mainnet
rm -f "${WARNINGS}"
refresh u
[[ -z "${PROFILE_PENDING_CONFIG_FILES}" ]] || fail "-s u left files pending"
dispatcher_write_manifest deployed N
jq -e 'has("pendingConfigUpdate") | not' "${DEPLOYMENT_FILE}" >/dev/null || fail "the manifest still records a pending update after -s u"
[[ -z "$(dispatcher_pending_config_report)" ]] || fail "the end of the deployment reports a pending update after -s u"
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

# A second refresh changes nothing, makes no new backups and has nothing pending.
before="$(cat "${config}" "${topology}" | sha256sum)"
stage mainnet
refresh u
[[ "$(cat "${config}" "${topology}" | sha256sum)" == "${before}" ]] || fail "a second refresh changed the files"
[[ "$(backups)" == "2" ]] || fail "a second refresh made new backups"
stage mainnet
refresh
[[ -z "${PROFILE_PENDING_CONFIG_FILES}" ]] || fail "an updated deployment still has files pending"

# A newer snapshot is no change to make: the topology keeps its slot.
jq '.useLedgerAfterSlot = 1000' "${topology}" > "${topology}.next" && mv "${topology}.next" "${topology}"
stage mainnet
refresh
[[ -z "${PROFILE_PENDING_CONFIG_FILES}" ]] || fail "an older useLedgerAfterSlot made the topology pending"
stage mainnet
refresh u
[[ "$(jq -r '.useLedgerAfterSlot' "${topology}")" == "1000" ]] || fail "-s u moved useLedgerAfterSlot of a topology that reads the snapshot"
jq ".useLedgerAfterSlot = ${shipped_ulas}" "${topology}" > "${topology}.next" && mv "${topology}.next" "${topology}"

# A config that cannot be read is reported on a plain refresh, and stops -s u.
stage mainnet
printf 'not json\n' > "${config}"
rm -f "${WARNINGS}"
refresh 2>/dev/null
grep -qF "Could not read config.json" "${WARNINGS}" || fail "an unreadable config.json was not reported"
stage mainnet
( refresh u ) 2>/dev/null && fail "-s u went on with an unreadable config.json"
rm -f -- "${FILES}"/*.tmp "${FILES}"/*.migrated

# --- a block producer: ledger peers off, only its own relays -------------------------
old_deployment preprod
jq '.useLedgerAfterSlot = -1 | .publicRoots = [] |
    .localRoots = [
      {accessPoints: [{address: "relay1.operator.example", port: 6000}], advertise: false, trustable: true, valency: 1},
      {accessPoints: [{address: "relay2.operator.example", port: 6000}], advertise: false, trustable: false, valency: 1}
    ]' "${FILES}/topology.json" > "${FILES}/topology.next" && mv "${FILES}/topology.next" "${FILES}/topology.json"
refresh u
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
refresh u
cmp -s "${FILES}/topology.json" "${TEST_ROOT}/peerless.json" || fail "a topology without peers was changed"
grep -qF "has no local roots" "${WARNINGS}" || fail "a topology without peers was not reported"

# --- Musashi and Dijkstra: the shipped trust threshold, in either config layout -----
old_deployment musashi
refresh u
[[ "$(jq -r '.ConsensusMode' "${FILES}/config.json")" == "GenesisMode" ]] || fail "musashi config is not in GenesisMode"
[[ "$(jq -r '.MinBigLedgerPeersForTrustedState' "${FILES}/config.json")" == "1" ]] || fail "musashi did not get the shipped trust threshold"

old_deployment dijkstra
refresh u
[[ "$(jq -r '.Configuration.Consensus.ConsensusMode' "${FILES}/config.json")" == "GenesisMode" ]] || fail "dijkstra config is not in GenesisMode"
[[ "$(jq -r '.Configuration.Network.MinBigLedgerPeersForTrustedState' "${FILES}/config.json")" == "1" ]] ||
  fail "dijkstra did not get the shipped trust threshold"
jq -e 'has("ConsensusMode") | not' "${FILES}/config.json" >/dev/null || fail "a flat key was added to a nested config"

# A config in another layout than the shipped one is left alone, with a warning.
old_deployment dijkstra
jq '{ConsensusMode: "PraosMode", Protocol: "Cardano"}' "${FILES}/config.json" > "${FILES}/config.next" &&
  mv "${FILES}/config.next" "${FILES}/config.json"
refresh u
[[ "$(jq -r '.ConsensusMode' "${FILES}/config.json")" == "PraosMode" ]] || fail "a config in another layout was changed"
grep -qF "another layout" "${WARNINGS}" || fail "a config in another layout was not reported"

# --- guild stays in PraosMode --------------------------------------------------------
old_deployment guild
cp "${FILES}/config.json" "${TEST_ROOT}/guild-config.json"
cp "${FILES}/topology.json" "${TEST_ROOT}/guild-topology.json"
refresh u
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
refresh u
CNODE_DEPLOY_FORCE_CONFIG="N"
[[ -z "${PROFILE_PENDING_CONFIG_FILES}" ]] || fail "-s f left files pending"
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
# It only warns: the node starts as it is, also under systemd.
eval "$(sed -n '/^check_genesis_topology() {/,/^}/p' "${ROOT_DIR}/scripts/cnode-helper-scripts/cnode.sh")"
eval "$(sed -n '/^check_pending_config() {/,/^}/p' "${ROOT_DIR}/scripts/cnode-helper-scripts/cnode.sh")"
declare -F check_genesis_topology check_pending_config >/dev/null || fail "cnode.sh has no start checks"
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
cp "${TOPOLOGY}" "${TEST_ROOT}/bp-untrusted.json"
output="$(check_genesis_topology)" || fail "check_genesis_topology failed, which would stop the start"
grep -qF "may wait in PreSyncing" <<< "${output}" || fail "cnode.sh did not warn about untrusted local roots"
grep -qF -- "-s u" <<< "${output}" || fail "cnode.sh did not say how to fix the topology"
cmp -s "${TOPOLOGY}" "${TEST_ROOT}/bp-untrusted.json" || fail "cnode.sh changed the topology"
[[ "$(backups)" == "0" ]] || fail "cnode.sh made a backup"
jq 'del(.bootstrapPeers) | .localRoots[].trustable = true' "${TOPOLOGY}" > "${TOPOLOGY}.next" && mv "${TOPOLOGY}.next" "${TOPOLOGY}"
[[ -z "$(check_genesis_topology)" ]] || fail "cnode.sh warned about a topology that is right"

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

# The pending update the last refresh recorded.
CNODE_HOME="${NODE_HOME}"
[[ -z "$(check_pending_config)" ]] || fail "cnode.sh warned without a manifest"
jq -n '{schemaVersion: 1, pendingConfigUpdate: {reason: "GenesisMode: test", files: ["files/config.json", "files/topology.json"]}}' \
  > "${NODE_HOME}/.deployment.json"
output="$(check_pending_config)" || fail "check_pending_config failed, which would stop the start"
[[ "${output}" == "WARN: files/config.json, files/topology.json still need this release's changes (GenesisMode: test). Run guild-deploy.sh -s u"* ]] ||
  fail "cnode.sh pending warning: ${output}"
jq '.pendingConfigUpdate.files = ["files/topology.json"]' "${NODE_HOME}/.deployment.json" > "${TEST_ROOT}/m" &&
  mv "${TEST_ROOT}/m" "${NODE_HOME}/.deployment.json"
[[ "$(check_pending_config)" == "WARN: files/topology.json still needs this release's changes"* ]] || fail "cnode.sh pending warning for one file"
jq 'del(.pendingConfigUpdate)' "${NODE_HOME}/.deployment.json" > "${TEST_ROOT}/m" && mv "${TEST_ROOT}/m" "${NODE_HOME}/.deployment.json"
[[ -z "$(check_pending_config)" ]] || fail "cnode.sh warned without a pending update"

# --- Amaru's environment file -------------------------------------------------------
# The retired bootstrap peer leaves AMARU_PEER, and the snapshot is added,
# only with -s u. The Amaru profile runs on Linux only (GNU sed).
[[ "$(uname -s)" == Linux ]] && (
  # shellcheck source=../../scripts/amaru-helper-scripts/deploy-amaru.sh
  . "${ROOT_DIR}/scripts/amaru-helper-scripts/deploy-amaru.sh"
  amaru_deploy_info() { :; }
  amaru_deploy_warn() { printf '%s\n' "$1" >> "${WARNINGS}"; }
  NETWORK=preprod
  rm -rf -- "${NODE_HOME}" "${WARNINGS}"
  mkdir -p "${NODE_HOME}/scripts/archive"
  env_file="${NODE_HOME}/scripts/amaru.env"
  printf 'AMARU_NETWORK="preprod"\nAMARU_PEER="preprod-node.play.dev.cardano.org:3001,relay.operator.example:3001"\n' > "${env_file}"
  cp "${env_file}" "${TEST_ROOT}/amaru.env"
  AMARU_DEPLOY_UPDATE_CONFIG=N
  amaru_deploy_migrate_environment "${env_file}"
  cmp -s "${env_file}" "${TEST_ROOT}/amaru.env" || fail "a plain refresh changed amaru.env"
  [[ "${PROFILE_PENDING_CONFIG_FILES}" == "scripts/amaru.env" ]] || fail "the pending amaru.env was not recorded"
  [[ "${PROFILE_PENDING_CONFIG_REASON}" == "Peers: the public bootstrap peers are being shut down" ]] || fail "the Amaru reason"
  grep -qF "retired bootstrap peer preprod-node.play.dev.cardano.org:3001" "${WARNINGS}" || fail "a plain refresh did not warn about the retired peer"
  AMARU_DEPLOY_UPDATE_CONFIG=Y
  amaru_deploy_migrate_environment "${env_file}"
  grep -qx 'AMARU_PEER="relay.operator.example:3001"' "${env_file}" || fail "-s u did not drop only the retired peer"
  grep -qx "AMARU_PEERS_SNAPSHOT=\"${NODE_HOME}/files/peer-snapshot.json\"" "${env_file}" || fail "-s u did not add the peer snapshot"
  [[ -z "${PROFILE_PENDING_CONFIG_FILES}" ]] || fail "-s u left amaru.env pending"
  [[ "$(find "${NODE_HOME}/scripts/archive" -name 'amaru.env.*' | wc -l | tr -d ' ')" == "1" ]] || fail "-s u did not archive amaru.env"
  AMARU_DEPLOY_UPDATE_CONFIG=N
  amaru_deploy_migrate_environment "${env_file}"
  [[ -z "${PROFILE_PENDING_CONFIG_FILES}" ]] || fail "an updated amaru.env is still pending"
  # Only the snapshot missing.
  sed -i.bak '/AMARU_PEERS_SNAPSHOT/d' "${env_file}"
  amaru_deploy_migrate_environment "${env_file}"
  [[ "${PROFILE_PENDING_CONFIG_REASON}" == "Peers: start from the shipped peer snapshot" ]] || fail "the reason without a snapshot"
) || [[ "$(uname -s)" != Linux ]] || fail "the Amaru environment checks failed"

printf 'cnode-genesis-migration: PASS\n'
