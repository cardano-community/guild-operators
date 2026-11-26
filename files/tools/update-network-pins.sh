#!/usr/bin/env bash
# Update a network's pins and network data from what its operators publish.
#
#   files/tools/update-network-pins.sh <mainnet|preprod|preview|dijkstra|musashi> [--summary FILE]
#
# Every network gets its peer snapshot, useLedgerAfterSlot and checkpoints from
# the book, copied into this repository, and always runs GenesisMode without
# bootstrap peers. The guild network is not handled here: it stays in PraosMode.
#
# The pre-release networks (dijkstra, musashi) also take their config, genesis
# files and node release from the book. MinNodeVersion in the book's config
# names the release the network runs, so a release it doesn't run yet is never
# picked up. On mainnet, preprod and preview only the network data changes: the
# config and the node pins there are Guild's own.
#
# Nothing in the repository changes unless every step succeeds. The working
# tree is left for a person, or the pins workflow, to review. Running it twice
# in a row changes nothing.
#
# cardano-cli is not pinned per network: every network uses the shared pin in
# files/node-implementations/cnode/release.json, which this tool never changes.
# What stays manual, and is listed in the summary: db-sync comes from a Hydra
# build, and whether the shared CLI still works with the new node.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BOOK_BASE="${PINS_BOOK_BASE:-https://book.world.dev.cardano.org/environments-pre}"
PUBLIC_BOOK_BASE="${PINS_PUBLIC_BOOK_BASE:-https://book.world.dev.cardano.org/environments}"
API_BASE="${PINS_API_BASE:-https://api.github.com}"
NODE_FILES="/opt/cardano/cnode/files"
# The node's default for MinBigLedgerPeersForTrustedState.
DEFAULT_TRUSTED_PEERS=5

die() {
  printf 'update-network-pins: %s\n' "$*" >&2
  exit 1
}

NETWORK="${1:-}"
SUMMARY=""
if [[ "${2:-}" == "--summary" ]]; then
  SUMMARY="${3:?--summary needs a file}"
fi
case "${NETWORK}" in
  mainnet|preprod|preview) KIND="public"; BOOK_URL="${PUBLIC_BOOK_BASE}/${NETWORK}" ;;
  dijkstra) KIND="prerelease"; BOOK_URL="${BOOK_BASE}/dijkstra"; REPOSITORY="IntersectMBO/cardano-node" ;;
  musashi) KIND="prerelease"; BOOK_URL="${BOOK_BASE}/leios"; REPOSITORY="input-output-hk/ouroboros-leios" ;;
  *) die "usage: update-network-pins.sh <mainnet|preprod|preview|dijkstra|musashi> [--summary FILE]" ;;
esac

CONFIG_DIR="${ROOT}/files/configs/cnode/${NETWORK}"
OVERLAY="${ROOT}/files/node-implementations/cnode/networks/${NETWORK}.json"
[[ -d "${CONFIG_DIR}" ]] || die "no configuration for ${NETWORK} in this checkout"
[[ "${KIND}" == "public" || -f "${OVERLAY}" ]] || die "no release overlay for ${NETWORK} in this checkout"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/guild-network-pins.XXXXXX")"
trap 'rm -rf -- "${STAGE}"' EXIT
mkdir "${STAGE}/book" "${STAGE}/new" "${STAGE}/binaries"

fetch() { # $1 = URL, $2 = destination
  curl --fail --silent --show-error --location --retry 2 --max-time 600 \
    ${GH_TOKEN:+--header "Authorization: Bearer ${GH_TOKEN}"} \
    --output "$2" "$1"
}

# Formatting alone, such as 2 and 2.0, must not count as a change.
canonical() {
  jq -S 'walk(if type == "number" then . + 0 else . end)' "$1"
}

same_json() {
  [[ -f "$1" && -f "$2" ]] && [[ "$(canonical "$1")" == "$(canonical "$2")" ]]
}

CONFIG_CHANGED=()
CONFIG_REMOVED=()
GENESIS_CHANGED=()

# Stage $1 (a file in ${STAGE}) as the new copy of $2 (its name in CONFIG_DIR)
# when it differs from what the repository has.
stage_if_changed() {
  if ! same_json "$1" "${CONFIG_DIR}/$2"; then
    cp "$1" "${STAGE}/new/$2"
    CONFIG_CHANGED+=("$2")
  fi
}

# ---- what the network publishes ----------------------------------------------
fetch "${BOOK_URL}/config.json" "${STAGE}/book/config.json" ||
  die "could not read the ${NETWORK} config from the book"
fetch "${BOOK_URL}/topology.json" "${STAGE}/book/topology.json" ||
  die "could not read the ${NETWORK} topology from the book"
jq -e . "${STAGE}/book/config.json" >/dev/null || die "the book's config is not valid JSON"
jq -e . "${STAGE}/book/topology.json" >/dev/null || die "the book's topology is not valid JSON"

if [[ "${KIND}" == "prerelease" ]]; then
  MIN_NODE_VERSION="$(jq -er '.MinNodeVersion // empty' "${STAGE}/book/config.json")" ||
    die "the book's ${NETWORK} config has no MinNodeVersion, so it doesn't say which release to pin"

  # Musashi names a Leios build, such as 11.2.0.164-rc-2026w44. Dijkstra names a
  # cardano-node release, such as 11.2.0.
  case "${NETWORK}" in
    musashi)
      [[ "${MIN_NODE_VERSION}" == *-* ]] ||
        die "expected a Leios build in MinNodeVersion, found '${MIN_NODE_VERSION}'"
      VERSION="${MIN_NODE_VERSION%%-*}"
      TAG="${MIN_NODE_VERSION#*-}"
      ASSET_X86="cardano-node-leios-x86_64-linux.tar.gz"
      ASSET_ARM="cardano-node-leios-aarch64-linux.tar.gz"
      ;;
    dijkstra)
      VERSION="${MIN_NODE_VERSION}"
      TAG="${MIN_NODE_VERSION}"
      ASSET_X86="cardano-node-${VERSION}-linux-amd64.tar.gz"
      ASSET_ARM="cardano-node-${VERSION}-linux-arm64.tar.gz"
      ;;
  esac
  [[ "${VERSION}" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || die "unexpected node version '${VERSION}'"
  [[ "${TAG}" =~ ^[A-Za-z0-9._-]+$ ]] || die "unexpected release tag '${TAG}'"

  # ---- genesis files, and anything else the config points at -------------------
  genesis_files() {
    jq -r '[.. | objects | to_entries[] | select(.key | endswith("GenesisFile")) | .value] | .[]' "$1"
  }
  while IFS= read -r referenced; do
    referenced="${referenced##*/}"
    [[ -f "${CONFIG_DIR}/${referenced}" ]] ||
      die "the book's config now uses ${referenced}, which this repository doesn't deploy. Add it to populate_cnode, then run this again."
  done < <(genesis_files "${STAGE}/book/config.json")

  for path in "${CONFIG_DIR}"/*-genesis.json; do
    [[ -f "${path}" ]] || continue
    name="${path##*/}"
    fetch "${BOOK_URL}/${name}" "${STAGE}/book/${name}" ||
      die "could not read ${name} for ${NETWORK} from the book"
    jq -e . "${STAGE}/book/${name}" >/dev/null || die "the book's ${name} is not valid JSON"
    if ! same_json "${STAGE}/book/${name}" "${path}"; then
      stage_if_changed "${STAGE}/book/${name}" "${name}"
      GENESIS_CHANGED+=("${name}")
    fi
  done
fi

# ---- peer snapshot ----------------------------------------------------------------
# The network magic comes from the genesis this change deploys.
MAGIC_SOURCE="${CONFIG_DIR}/shelley-genesis.json"
[[ -f "${STAGE}/new/shelley-genesis.json" ]] && MAGIC_SOURCE="${STAGE}/new/shelley-genesis.json"
MAGIC="$(jq -er '.networkMagic | numbers' "${MAGIC_SOURCE}")" || die "no networkMagic in ${NETWORK}'s shelley-genesis.json"

fetch "${BOOK_URL}/peer-snapshot.json" "${STAGE}/book/peer-snapshot.json" ||
  die "could not read peer-snapshot.json for ${NETWORK} from the book"
jq -e . "${STAGE}/book/peer-snapshot.json" >/dev/null || die "the book's peer-snapshot.json is not valid JSON"
BOOK_ULAS="$(jq -er '.useLedgerAfterSlot | numbers' "${STAGE}/book/topology.json")" ||
  die "the book's ${NETWORK} topology has no useLedgerAfterSlot"
(( BOOK_ULAS >= 0 )) || die "the book's ${NETWORK} topology turns ledger peers off (useLedgerAfterSlot ${BOOK_ULAS})"

# The node refuses to start with a snapshot of another network, or one older
# than useLedgerAfterSlot.
jq -e --argjson magic "${MAGIC}" --argjson ulas "${BOOK_ULAS}" '
  .NetworkMagic == $magic
  and (.NodeToClientVersion | type == "number")
  and (.Point | type == "object")
  and (.Point.blockPointHash | type == "string")
  and (.Point.blockPointSlot | type == "number")
  and .Point.blockPointSlot >= $ulas
  and ([.bigLedgerPools[]?.relays[]?] | length > 0)
' "${STAGE}/book/peer-snapshot.json" >/dev/null ||
  die "the book's ${NETWORK} peer snapshot is not usable: it must be for network magic ${MAGIC}, name a point at or after useLedgerAfterSlot ${BOOK_ULAS}, and list relays"

snapshot_slot() { jq -r '.Point.blockPointSlot // "none"' "$1" 2>/dev/null || printf 'none'; }
snapshot_pools() { jq -r '.bigLedgerPools | length' "$1" 2>/dev/null || printf 'none'; }
snapshot_relays() { jq -r '[.bigLedgerPools[].relays[]] | unique | length' "$1" 2>/dev/null || printf 'none'; }

OLD_SNAPSHOT="${CONFIG_DIR}/peer-snapshot.json"
OLD_SLOT="$(snapshot_slot "${OLD_SNAPSHOT}")"
OLD_POOLS="$(snapshot_pools "${OLD_SNAPSHOT}")"
OLD_RELAYS="$(snapshot_relays "${OLD_SNAPSHOT}")"
OLD_ULAS="$(jq -r '.useLedgerAfterSlot // "none"' "${CONFIG_DIR}/topology.json")"
SNAPSHOT="${STAGE}/book/peer-snapshot.json"
ULAS="${BOOK_ULAS}"
SNAPSHOT_NOTE=""
# A book that went back to an older snapshot is not followed.
if [[ "${OLD_SLOT}" =~ ^[0-9]+$ && "${OLD_ULAS}" =~ ^[0-9]+$ ]] &&
   (( OLD_SLOT > $(snapshot_slot "${SNAPSHOT}") )); then
  SNAPSHOT="${OLD_SNAPSHOT}"
  ULAS="${OLD_ULAS}"
  SNAPSHOT_NOTE="The book's snapshot is older than the one in this repository, so the repository keeps its own."
fi
stage_if_changed "${SNAPSHOT}" "peer-snapshot.json"
NEW_SLOT="$(snapshot_slot "${SNAPSHOT}")"
NEW_POOLS="$(snapshot_pools "${SNAPSHOT}")"
NEW_RELAYS="$(snapshot_relays "${SNAPSHOT}")"

# ---- checkpoints --------------------------------------------------------------------
CHECKPOINTS_FILE="$(jq -r '[.. | objects | .CheckpointsFile? | strings][0] // empty' "${STAGE}/book/config.json")"
if [[ -n "${CHECKPOINTS_FILE}" ]]; then
  [[ "${CHECKPOINTS_FILE##*/}" == "checkpoints.json" ]] ||
    die "the book's ${NETWORK} config names checkpoints file ${CHECKPOINTS_FILE##*/}; this repository deploys checkpoints.json"
  fetch "${BOOK_URL}/checkpoints.json" "${STAGE}/book/checkpoints.json" ||
    die "could not read checkpoints.json for ${NETWORK} from the book"
  jq -e '.checkpoints | arrays | length > 0' "${STAGE}/book/checkpoints.json" >/dev/null ||
    die "the book's ${NETWORK} checkpoints.json lists no checkpoints"
  stage_if_changed "${STAGE}/book/checkpoints.json" "checkpoints.json"
elif [[ -f "${CONFIG_DIR}/checkpoints.json" ]]; then
  CONFIG_REMOVED+=("checkpoints.json")
fi

# ---- config ---------------------------------------------------------------------------
if [[ "${KIND}" == "prerelease" ]]; then
  # The network's settings with Guild's tracing and absolute paths.
  if ! jq --arg files "${NODE_FILES}" --slurpfile guild "${CONFIG_DIR}/config.json" '
    $guild[0] as $g |
    walk(
      if type == "object" then
        with_entries(
          if (.key | endswith("GenesisFile") or . == "CheckpointsFile") and (.value | type == "string")
          then .value = ($files + "/" + (.value | split("/") | last))
          else . end
        )
      else . end
    ) |
    if has("Configuration") then
      .Configuration.HermodTracing.TraceOptions = $g.Configuration.HermodTracing.TraceOptions |
      .Configuration.HermodTracing.TraceOptionNodeName = $g.Configuration.HermodTracing.TraceOptionNodeName
    else
      .TraceOptions = $g.TraceOptions |
      .TraceOptionNodeName = $g.TraceOptionNodeName
    end
  ' "${STAGE}/book/config.json" > "${STAGE}/config.base.json"; then
    die "could not apply Guild's tracing to the book's config"
  fi
  # A config that changed shape, such as flat to nested, has no tracing to keep.
  if [[ "$(jq -r 'if has("Configuration") then .Configuration.HermodTracing.TraceOptions else .TraceOptions end | type' "${STAGE}/config.base.json")" != "object" ]]; then
    die "the book's config changed shape, so Guild's tracing can't be applied automatically"
  fi
  # The trust threshold the book asks for, which the snapshot may not be able to meet.
  BASE_TRUSTED="$(jq -r '(.Configuration.Network // .).MinBigLedgerPeersForTrustedState // empty' "${STAGE}/config.base.json")"
else
  # Guild's own config, with only the network data the book decides.
  jq --arg checkpoints "${CHECKPOINTS_FILE:+${NODE_FILES}/checkpoints.json}" '
    if $checkpoints == "" then del(.CheckpointsFile) else .CheckpointsFile = $checkpoints end
  ' "${CONFIG_DIR}/config.json" > "${STAGE}/config.base.json" ||
    die "could not update ${NETWORK}'s config"
  BASE_TRUSTED=""
fi
[[ -z "${BASE_TRUSTED}" || "${BASE_TRUSTED}" =~ ^[0-9]+$ ]] ||
  die "unexpected MinBigLedgerPeersForTrustedState '${BASE_TRUSTED}' in ${NETWORK}'s config"
BASE_TRUSTED="${BASE_TRUSTED:-${DEFAULT_TRUSTED_PEERS}}"

# A fresh node leaves PreSyncing only once this many big ledger peers are active.
# Each distinct relay in the snapshot is one peer, so a snapshot with fewer
# relays than the threshold would leave every new node waiting forever.
TRUSTED="${BASE_TRUSTED}"
TRUSTED_NOTE=""
if (( NEW_RELAYS < BASE_TRUSTED )); then
  TRUSTED="${NEW_RELAYS}"
  TRUSTED_NOTE="The snapshot has only ${NEW_RELAYS} distinct relay addresses, fewer than the ${BASE_TRUSTED} big ledger peers a node waits for before it syncs, so MinBigLedgerPeersForTrustedState is set to ${TRUSTED}. A fresh node then trusts the snapshot's relays alone."
fi

# GenesisMode on every network this tool handles, and no hashes Guild doesn't need.
jq --argjson trusted "${TRUSTED}" --argjson default "${DEFAULT_TRUSTED_PEERS}" '
  walk(if type == "object" then del(.CheckpointsFileHash) else . end) |
  if has("Configuration") then
    .Configuration.Consensus.ConsensusMode = "GenesisMode" |
    if $trusted == $default and (.Configuration.Network.MinBigLedgerPeersForTrustedState // $default) == $default
    then .Configuration.Network |= del(.MinBigLedgerPeersForTrustedState)
    else .Configuration.Network.MinBigLedgerPeersForTrustedState = $trusted end
  else
    .ConsensusMode = "GenesisMode" |
    if $trusted == $default and (.MinBigLedgerPeersForTrustedState // $default) == $default
    then del(.MinBigLedgerPeersForTrustedState)
    else .MinBigLedgerPeersForTrustedState = $trusted end
  end
' "${STAGE}/config.base.json" > "${STAGE}/config.json" || die "could not set GenesisMode in ${NETWORK}'s config"
stage_if_changed "${STAGE}/config.json" "config.json"

# ---- topology: the book's ledger settings with Guild's local roots --------------------
jq --slurpfile guild "${CONFIG_DIR}/topology.json" --argjson ulas "${ULAS}" '
  del(.bootstrapPeers) |
  .localRoots = $guild[0].localRoots |
  .peerSnapshotFile = "peer-snapshot.json" |
  .useLedgerAfterSlot = $ulas
' "${STAGE}/book/topology.json" > "${STAGE}/topology.json" ||
  die "could not apply Guild's local roots to the book's topology"
stage_if_changed "${STAGE}/topology.json" "topology.json"

# ---- binaries -------------------------------------------------------------------
PIN_CHANGED="N"
if [[ "${KIND}" == "prerelease" ]]; then
  OLD_TAG="$(jq -r '.releaseTag // "unknown"' "${OVERLAY}")"
  OLD_VERSION="$(jq -r '.version // "unknown"' "${OVERLAY}")"
  SHARED_CLI="$(jq -r '.companions["cardano-cli"].version // "unknown"' "${ROOT}/files/node-implementations/cnode/release.json")"
  RELEASE_URL="https://github.com/${REPOSITORY}/releases/tag/${TAG}"
  cp "${OVERLAY}" "${STAGE}/overlay.json"

  if [[ "${TAG}" != "${OLD_TAG}" ]]; then
    fetch "${API_BASE}/repos/${REPOSITORY}/releases/tags/${TAG}" "${STAGE}/release.json" ||
      die "the network requires ${MIN_NODE_VERSION}, but ${REPOSITORY} has no release ${TAG}"
    asset_field() { # $1 = asset name, $2 = field
      jq -er --arg name "$1" --arg field "$2" \
        '[.assets[] | select(.name == $name)][0][$field] // empty' "${STAGE}/release.json"
    }
    for asset in "${ASSET_X86}" "${ASSET_ARM}"; do
      asset_field "${asset}" browser_download_url >/dev/null ||
        die "release ${TAG} has no asset ${asset}"
      [[ "$(asset_field "${asset}" digest)" =~ ^sha256:[0-9a-f]{64}$ ]] ||
        die "GitHub publishes no sha256 digest for ${asset} in release ${TAG}"
    done
    SHA_X86="$(asset_field "${ASSET_X86}" digest)"; SHA_X86="${SHA_X86#sha256:}"
    SHA_ARM="$(asset_field "${ASSET_ARM}" digest)"; SHA_ARM="${SHA_ARM#sha256:}"
    URL_X86="$(asset_field "${ASSET_X86}" browser_download_url)"
    URL_ARM="$(asset_field "${ASSET_ARM}" browser_download_url)"

    # Run what the network requires, so the pin records what it really reports.
    case "$(uname -m)" in
      aarch64|arm64) probe_url="${URL_ARM}"; probe_sha="${SHA_ARM}" ;;
      *) probe_url="${URL_X86}"; probe_sha="${SHA_X86}" ;;
    esac
    fetch "${probe_url}" "${STAGE}/binaries/release.tar.gz" ||
      die "could not download ${probe_url}"
    [[ "$(sha256sum "${STAGE}/binaries/release.tar.gz" | awk '{print $1}')" == "${probe_sha}" ]] ||
      die "${probe_url} does not match GitHub's published digest"
    tar -xzf "${STAGE}/binaries/release.tar.gz" -C "${STAGE}/binaries" ||
      die "could not extract ${probe_url}"
    node_binary="$(find "${STAGE}/binaries" -type f -name cardano-node | head -n 1)"
    [[ -n "${node_binary}" ]] || die "release ${TAG} has no cardano-node"
    reported="$("${node_binary}" version | head -n 1 | awk '{print $2}')"
    [[ "${reported}" == "${VERSION}" ]] ||
      die "the network requires cardano-node ${VERSION}, but release ${TAG} reports ${reported:-nothing}"

    jq --arg tag "${TAG}" --arg version "${VERSION}" \
      --arg url_x86 "${URL_X86}" --arg sha_x86 "${SHA_X86}" \
      --arg url_arm "${URL_ARM}" --arg sha_arm "${SHA_ARM}" '
        .releaseTag = $tag | .version = $version |
        .artifacts = {
          "linux-x86_64": {url: $url_x86, sha256: $sha_x86},
          "linux-aarch64": {url: $url_arm, sha256: $sha_arm}
        }
      ' "${OVERLAY}" > "${STAGE}/overlay.json"
  fi
  same_json "${STAGE}/overlay.json" "${OVERLAY}" || PIN_CHANGED="Y"
fi

# ---- everything worked, so update the checkout ----------------------------------
[[ "${PIN_CHANGED}" == "Y" ]] && cp "${STAGE}/overlay.json" "${OVERLAY}"
for path in "${STAGE}/new"/*; do
  [[ -e "${path}" ]] || continue
  cp "${path}" "${CONFIG_DIR}/${path##*/}"
done
for name in ${CONFIG_REMOVED[@]+"${CONFIG_REMOVED[@]}"}; do
  rm -f -- "${CONFIG_DIR:?}/${name}"
done

if [[ "${PIN_CHANGED}" == "N" && ${#CONFIG_CHANGED[@]} -eq 0 && ${#CONFIG_REMOVED[@]} -eq 0 ]]; then
  if [[ "${KIND}" == "prerelease" ]]; then
    printf '%s is up to date: release %s, cardano-node %s, peer snapshot at slot %s.\n' "${NETWORK}" "${TAG}" "${VERSION}" "${NEW_SLOT}"
  else
    printf '%s is up to date: peer snapshot at slot %s.\n' "${NETWORK}" "${NEW_SLOT}"
  fi
  exit 0
fi

{
  if [[ "${KIND}" == "prerelease" ]]; then
    printf '## %s pins\n\n' "${NETWORK}"
    printf 'The book now requires `%s`.\n\n' "${MIN_NODE_VERSION}"
    printf '| | Now | Proposed |\n| --- | --- | --- |\n'
    printf '| Release | %s | [%s](%s) |\n' "${OLD_TAG}" "${TAG}" "${RELEASE_URL}"
    printf '| cardano-node | %s | %s |\n\n' "${OLD_VERSION}" "${VERSION}"
  else
    printf '## %s network data\n\n' "${NETWORK}"
    printf 'Copied from %s.\n\n' "${BOOK_URL}"
  fi
  printf '| Peer snapshot | Now | Proposed |\n| --- | --- | --- |\n'
  printf '| Slot | %s | %s |\n' "${OLD_SLOT}" "${NEW_SLOT}"
  printf '| useLedgerAfterSlot | %s | %s |\n' "${OLD_ULAS}" "${ULAS}"
  printf '| Big ledger pools | %s | %s |\n' "${OLD_POOLS}" "${NEW_POOLS}"
  printf '| Distinct relays | %s | %s |\n\n' "${OLD_RELAYS}" "${NEW_RELAYS}"
  [[ -z "${SNAPSHOT_NOTE}" ]] || printf '%s\n\n' "${SNAPSHOT_NOTE}"
  [[ -z "${TRUSTED_NOTE}" ]] || printf '%s\n\n' "${TRUSTED_NOTE}"
  if [[ ${#CONFIG_CHANGED[@]} -gt 0 ]]; then
    printf 'Config files changed: `%s`\n\n' "${CONFIG_CHANGED[*]}"
  fi
  if [[ ${#CONFIG_REMOVED[@]} -gt 0 ]]; then
    printf 'Config files removed: `%s`\n\n' "${CONFIG_REMOVED[*]}"
  fi
  if [[ ${#GENESIS_CHANGED[@]} -gt 0 ]]; then
    printf '**Respin: the genesis changed (`%s`).** ' "${GENESIS_CHANGED[*]}"
    printf 'Operators need new config files and a new chain database, not just a redeploy:\n\n'
    printf '```bash\n./guild-deploy.sh -s df -n %s -t %s\n```\n\n' "${NETWORK}" "${NETWORK}"
    printf 'Then stop the service, delete its `db` folder and start it again.\n\n'
  fi
  if [[ "${KIND}" == "prerelease" ]]; then
    printf '### Needs a person\n\n'
    printf -- '- cardano-cli stays at the shared pin %s, which every network uses. Check that CNTools still works with it against this node.\n' \
      "${SHARED_CLI}"
    if [[ "${NETWORK}" == "dijkstra" ]]; then
      printf -- '- db-sync comes from a Hydra build, which this tool cannot watch. Check it still matches this node.\n'
    else
      printf -- '- `bech32` and `cardano-submit-api` come from the pinned cardano-node archive, which this tool does not change.\n'
    fi
  else
    printf 'Existing deployments pick these files up on their next `guild-deploy.sh` refresh.\n'
  fi
} > "${STAGE}/summary.md"
if [[ -n "${SUMMARY}" ]]; then
  cp "${STAGE}/summary.md" "${SUMMARY}"
else
  cat "${STAGE}/summary.md"
fi
