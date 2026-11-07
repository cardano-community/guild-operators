#!/usr/bin/env bash
# Update a pre-release network's pins from what its operators publish.
#
#   files/tools/update-network-pins.sh <dijkstra|musashi> [--summary FILE]
#
# MinNodeVersion in the book's config names the release the network runs, so a
# release it doesn't run yet is never picked up. Nothing in the repository
# changes unless every step succeeds. The working tree is left for a person, or
# the pins workflow, to review. Running it twice in a row changes nothing.
#
# What stays manual, and is listed in the summary: db-sync comes from a Hydra
# build, and the book doesn't name a CLI for Dijkstra.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BOOK_BASE="${PINS_BOOK_BASE:-https://book.world.dev.cardano.org/environments-pre}"
API_BASE="${PINS_API_BASE:-https://api.github.com}"
NODE_FILES="/opt/cardano/cnode/files"

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
  dijkstra) BOOK_FOLDER="dijkstra"; REPOSITORY="IntersectMBO/cardano-node" ;;
  musashi) BOOK_FOLDER="leios"; REPOSITORY="input-output-hk/ouroboros-leios" ;;
  *) die "usage: update-network-pins.sh <dijkstra|musashi> [--summary FILE]" ;;
esac

CONFIG_DIR="${ROOT}/files/configs/cnode/${NETWORK}"
OVERLAY="${ROOT}/files/node-implementations/cnode/networks/${NETWORK}.json"
[[ -d "${CONFIG_DIR}" && -f "${OVERLAY}" ]] || die "no configuration for ${NETWORK} in this checkout"

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

# ---- what the network publishes ----------------------------------------------
fetch "${BOOK_BASE}/${BOOK_FOLDER}/config.json" "${STAGE}/book/config.json" ||
  die "could not read the ${NETWORK} config from the book"
fetch "${BOOK_BASE}/${BOOK_FOLDER}/topology.json" "${STAGE}/book/topology.json" ||
  die "could not read the ${NETWORK} topology from the book"
jq -e . "${STAGE}/book/config.json" >/dev/null || die "the book's config is not valid JSON"
jq -e . "${STAGE}/book/topology.json" >/dev/null || die "the book's topology is not valid JSON"

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

GENESIS_CHANGED=()
CONFIG_CHANGED=()
for path in "${CONFIG_DIR}"/*-genesis.json "${CONFIG_DIR}/peer-snapshot.json"; do
  [[ -f "${path}" ]] || continue
  name="${path##*/}"
  fetch "${BOOK_BASE}/${BOOK_FOLDER}/${name}" "${STAGE}/book/${name}" ||
    die "could not read ${name} for ${NETWORK} from the book"
  jq -e . "${STAGE}/book/${name}" >/dev/null || die "the book's ${name} is not valid JSON"
  if ! same_json "${STAGE}/book/${name}" "${path}"; then
    cp "${STAGE}/book/${name}" "${STAGE}/new/${name}"
    CONFIG_CHANGED+=("${name}")
    [[ "${name}" != *-genesis.json ]] || GENESIS_CHANGED+=("${name}")
  fi
done

# ---- config: the network's settings with Guild's tracing and absolute paths ---
if ! jq --arg files "${NODE_FILES}" --slurpfile guild "${CONFIG_DIR}/config.json" '
  $guild[0] as $g |
  walk(
    if type == "object" then
      with_entries(
        if (.key | endswith("GenesisFile")) and (.value | type == "string")
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
' "${STAGE}/book/config.json" > "${STAGE}/config.json"; then
  die "could not apply Guild's tracing to the book's config"
fi
# A config that changed shape, such as flat to nested, has no tracing to keep.
if [[ "$(jq -r 'if has("Configuration") then .Configuration.HermodTracing.TraceOptions else .TraceOptions end | type' "${STAGE}/config.json")" != "object" ]]; then
  die "the book's config changed shape, so Guild's tracing can't be applied automatically"
fi
if ! same_json "${STAGE}/config.json" "${CONFIG_DIR}/config.json"; then
  cp "${STAGE}/config.json" "${STAGE}/new/config.json"
  CONFIG_CHANGED+=("config.json")
fi

# ---- topology: the network's peers with Guild's placeholder local roots --------
jq --slurpfile guild "${CONFIG_DIR}/topology.json" '.localRoots = $guild[0].localRoots' \
  "${STAGE}/book/topology.json" > "${STAGE}/topology.json" ||
  die "could not apply Guild's local roots to the book's topology"
if ! same_json "${STAGE}/topology.json" "${CONFIG_DIR}/topology.json"; then
  cp "${STAGE}/topology.json" "${STAGE}/new/topology.json"
  CONFIG_CHANGED+=("topology.json")
fi

# ---- binaries -------------------------------------------------------------------
OLD_TAG="$(jq -r '.releaseTag // "unknown"' "${OVERLAY}")"
OLD_VERSION="$(jq -r '.version // "unknown"' "${OVERLAY}")"
OLD_CLI="$(jq -r '.companions["cardano-cli"].version // "unknown"' "${OVERLAY}")"
NEW_CLI="${OLD_CLI}"
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

  # A Leios archive carries the CLI that belongs with its node.
  if [[ "${NETWORK}" == "musashi" ]]; then
    cli_binary="$(find "${STAGE}/binaries" -type f -name cardano-cli | head -n 1)"
    [[ -n "${cli_binary}" ]] || die "release ${TAG} has no cardano-cli"
    NEW_CLI="$("${cli_binary}" version | head -n 1 | awk '{print $2}')"
    [[ "${NEW_CLI}" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] ||
      die "release ${TAG} reports an unexpected cardano-cli version '${NEW_CLI}'"
    jq --arg cli "${NEW_CLI}" '
      .companions["cardano-cli"] = {version: $cli, artifacts: .artifacts}
    ' "${STAGE}/overlay.json" > "${STAGE}/overlay.next" &&
      mv -f "${STAGE}/overlay.next" "${STAGE}/overlay.json"
  fi
fi

# ---- everything worked, so update the checkout ----------------------------------
PIN_CHANGED="N"
if ! same_json "${STAGE}/overlay.json" "${OVERLAY}"; then
  cp "${STAGE}/overlay.json" "${OVERLAY}"
  PIN_CHANGED="Y"
fi
for path in "${STAGE}/new"/*; do
  [[ -e "${path}" ]] || continue
  cp "${path}" "${CONFIG_DIR}/${path##*/}"
done

if [[ "${PIN_CHANGED}" == "N" && ${#CONFIG_CHANGED[@]} -eq 0 ]]; then
  printf '%s is up to date: release %s, cardano-node %s.\n' "${NETWORK}" "${TAG}" "${VERSION}"
  exit 0
fi

{
  printf '## %s pins\n\n' "${NETWORK}"
  printf 'The book now requires `%s`.\n\n' "${MIN_NODE_VERSION}"
  printf '| | Now | Proposed |\n| --- | --- | --- |\n'
  printf '| Release | %s | [%s](%s) |\n' "${OLD_TAG}" "${TAG}" "${RELEASE_URL}"
  printf '| cardano-node | %s | %s |\n' "${OLD_VERSION}" "${VERSION}"
  printf '| cardano-cli | %s | %s |\n\n' "${OLD_CLI}" "${NEW_CLI}"
  if [[ ${#CONFIG_CHANGED[@]} -gt 0 ]]; then
    printf 'Config files changed: `%s`\n\n' "${CONFIG_CHANGED[*]}"
  fi
  if [[ ${#GENESIS_CHANGED[@]} -gt 0 ]]; then
    printf '**Respin: the genesis changed (`%s`).** ' "${GENESIS_CHANGED[*]}"
    printf 'Operators need new config files and a new chain database, not just a redeploy:\n\n'
    printf '```bash\n./guild-deploy.sh -s df -n %s -t %s\n```\n\n' "${NETWORK}" "${NETWORK}"
    printf 'Then stop the service, delete its `db` folder and start it again.\n\n'
  fi
  printf '### Needs a person\n\n'
  if [[ "${NETWORK}" == "dijkstra" ]]; then
    newest_cli="$(curl --fail --silent --location --max-time 30 \
      ${GH_TOKEN:+--header "Authorization: Bearer ${GH_TOKEN}"} \
      "${API_BASE}/repos/IntersectMBO/cardano-cli/releases/latest" 2>/dev/null |
      jq -r '.tag_name // empty' 2>/dev/null || true)"
    printf -- '- The book does not name a CLI for this network. It stays at %s. Newest release: %s.\n' \
      "${OLD_CLI}" "${newest_cli:-unknown}"
    printf -- '- db-sync comes from a Hydra build, which this tool cannot watch. Check it still matches this node.\n'
  else
    printf -- '- `bech32` and `cardano-submit-api` come from the pinned cardano-node archive, which this tool does not change.\n'
  fi
} > "${STAGE}/summary.md"
if [[ -n "${SUMMARY}" ]]; then
  cp "${STAGE}/summary.md" "${SUMMARY}"
else
  cat "${STAGE}/summary.md"
fi
