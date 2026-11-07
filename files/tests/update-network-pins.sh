#!/usr/bin/env bash
# The pin tool against a fake book and a fake GitHub: what it updates, what it
# refuses, and that a refusal leaves the checkout untouched.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-network-pins-test.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

REPO="${TEST_ROOT}/repo"
BOOK="${TEST_ROOT}/book"
API="${TEST_ROOT}/api"
TOOL="${REPO}/files/tools/update-network-pins.sh"
export PINS_BOOK_BASE="file://${BOOK}"
export PINS_API_BASE="file://${API}"
unset GH_TOKEN

reset_fixtures() {
  rm -rf -- "${REPO}" "${BOOK}" "${API}"
  mkdir -p "${REPO}/files/tools" "${REPO}/files/configs/cnode" \
    "${REPO}/files/node-implementations/cnode/networks" \
    "${BOOK}/leios" "${BOOK}/dijkstra" "${API}"
  cp "${ROOT_DIR}/files/tools/update-network-pins.sh" "${TOOL}"
  local network folder path name
  for network in dijkstra musashi; do
    cp -R "${ROOT_DIR}/files/configs/cnode/${network}" "${REPO}/files/configs/cnode/${network}"
    cp "${ROOT_DIR}/files/node-implementations/cnode/networks/${network}.json" \
      "${REPO}/files/node-implementations/cnode/networks/${network}.json"
    folder="${network/musashi/leios}"
    for path in "${REPO}/files/configs/cnode/${network}"/*; do
      name="${path##*/}"
      case "${name}" in
        submitapi.json|db-sync-config.json) ;;
        config.json)
          # The book's own tracing and relative paths, which the tool replaces.
          jq 'walk(if type == "object" then with_entries(
                if (.key | endswith("GenesisFile")) then .value = (.value | split("/") | last) else . end
              ) else . end) |
              if has("Configuration")
              then .Configuration.HermodTracing.TraceOptions = {"": {severity: "Debug"}} | del(.Configuration.HermodTracing.TraceOptionNodeName)
              else .TraceOptions = {"": {severity: "Debug"}} | del(.TraceOptionNodeName) end' \
            "${path}" > "${BOOK}/${folder}/${name}"
          ;;
        topology.json)
          jq '.localRoots = []' "${path}" > "${BOOK}/${folder}/${name}"
          ;;
        *) cp "${path}" "${BOOK}/${folder}/${name}" ;;
      esac
    done
  done
}

checkout_hash() {
  (cd "${REPO}/files" && find configs node-implementations -type f -exec sha256sum {} + | sort | sha256sum)
}

book_requires() { # $1 = book folder, $2 = MinNodeVersion
  local file="${BOOK}/$1/config.json"
  jq --arg version "$2" '.MinNodeVersion = $version' "${file}" > "${file}.next"
  mv -f "${file}.next" "${file}"
}

fake_release() { # $1 = repository, $2 = tag, $3 = node version, $4 = cli version, $5 and $6 = asset names
  local repository="$1" tag="$2" node="$3" cli="$4" asset_x86="$5" asset_arm="$6"
  local stage="${TEST_ROOT}/stage"
  local archive="${API}/assets/${tag}.tar.gz"
  rm -rf -- "${stage}"
  mkdir -p "${stage}/bin" "${API}/assets" "${API}/repos/${repository}/releases/tags"
  printf '#!/usr/bin/env bash\nprintf "cardano-node %s - linux\\n"\n' "${node}" > "${stage}/bin/cardano-node"
  printf '#!/usr/bin/env bash\nprintf "cardano-cli %s - linux\\n"\n' "${cli}" > "${stage}/bin/cardano-cli"
  chmod 0755 "${stage}/bin/cardano-node" "${stage}/bin/cardano-cli"
  tar -czf "${archive}" -C "${stage}" bin
  local sha
  sha="$(sha256sum "${archive}" | awk '{print $1}')"
  jq -n --arg x86 "${asset_x86}" --arg arm "${asset_arm}" --arg url "file://${archive}" --arg digest "sha256:${sha}" '{
    assets: [
      {name: $x86, browser_download_url: $url, digest: $digest},
      {name: $arm, browser_download_url: $url, digest: $digest}
    ]
  }' > "${API}/repos/${repository}/releases/tags/${tag}"
}

expect_refusal() { # $1 = network, $2 = text the error must contain
  local before output
  before="$(checkout_hash)"
  if output="$(bash "${TOOL}" "$1" 2>&1)"; then
    fail "expected a refusal mentioning '$2', got: ${output}"
  fi
  grep -qF -- "$2" <<< "${output}" || fail "refusal did not mention '$2': ${output}"
  [[ "$(checkout_hash)" == "${before}" ]] || fail "a refusal changed the checkout: $2"
}

MUSASHI_X86="cardano-node-leios-x86_64-linux.tar.gz"
MUSASHI_ARM="cardano-node-leios-aarch64-linux.tar.gz"
LEIOS="input-output-hk/ouroboros-leios"
MUSASHI_OVERLAY="${REPO}/files/node-implementations/cnode/networks/musashi.json"
DIJKSTRA_OVERLAY="${REPO}/files/node-implementations/cnode/networks/dijkstra.json"

# Nothing new upstream means nothing changes, even though the book's tracing and
# paths differ from the repository's.
reset_fixtures
before="$(checkout_hash)"
bash "${TOOL}" musashi | grep -qF "is up to date" || fail "musashi should be up to date"
bash "${TOOL}" dijkstra | grep -qF "is up to date" || fail "dijkstra should be up to date"
[[ "$(checkout_hash)" == "${before}" ]] || fail "no upstream change, but the checkout changed"

# A new Leios build: node, CLI and tag come from the release the book names.
reset_fixtures
book_requires leios "11.3.0.200-rc-2026w99"
fake_release "${LEIOS}" rc-2026w99 11.3.0.200 11.5.0.0 "${MUSASHI_X86}" "${MUSASHI_ARM}"
summary="${TEST_ROOT}/summary.md"
bash "${TOOL}" musashi --summary "${summary}" || fail "musashi update failed"
[[ "$(jq -r '.releaseTag' "${MUSASHI_OVERLAY}")" == "rc-2026w99" ]] || fail "tag not recorded"
[[ "$(jq -r '.version' "${MUSASHI_OVERLAY}")" == "11.3.0.200" ]] || fail "node version not recorded"
[[ "$(jq -r '.companions["cardano-cli"].version' "${MUSASHI_OVERLAY}")" == "11.5.0.0" ]] || fail "cli version not recorded"
[[ "$(jq -r '.artifacts["linux-x86_64"].sha256' "${MUSASHI_OVERLAY}")" =~ ^[0-9a-f]{64}$ ]] || fail "digest not recorded"
[[ "$(jq -r '.companions["cardano-node-support"].version' "${MUSASHI_OVERLAY}")" == "11.2.0" ]] || fail "support archive changed"
jq -e '.companions | has("cardano-db-sync")' "${MUSASHI_OVERLAY}" >/dev/null || fail "db-sync removal was lost"
config="${REPO}/files/configs/cnode/musashi/config.json"
[[ "$(jq -r '.MinNodeVersion' "${config}")" == "11.3.0.200-rc-2026w99" ]] || fail "config not updated"
[[ "$(jq -r '.TraceOptionNodeName' "${config}")" == "cnode" ]] || fail "Guild's node name was lost"
[[ "$(jq -cS '.TraceOptions' "${config}")" == "$(jq -cS '.TraceOptions' "${ROOT_DIR}/files/configs/cnode/musashi/config.json")" ]] ||
  fail "Guild's tracing was lost"
[[ "$(jq -r '.ShelleyGenesisFile' "${config}")" == "/opt/cardano/cnode/files/shelley-genesis.json" ]] || fail "paths are not absolute"
[[ "$(jq -cS '.localRoots' "${REPO}/files/configs/cnode/musashi/topology.json")" == \
   "$(jq -cS '.localRoots' "${ROOT_DIR}/files/configs/cnode/musashi/topology.json")" ]] || fail "Guild's local roots were lost"
grep -qF "rc-2026w99" "${summary}" || fail "summary does not name the release"
grep -qF "Respin" "${summary}" && fail "a release with the same genesis is not a respin"

# Running it again changes nothing.
before="$(checkout_hash)"
bash "${TOOL}" musashi | grep -qF "is up to date" || fail "second run should be up to date"
[[ "$(checkout_hash)" == "${before}" ]] || fail "second run changed the checkout"

# A changed genesis is a respin, and it is said out loud.
reset_fixtures
jq '.systemStart = "2030-01-01T00:00:00Z"' "${BOOK}/leios/shelley-genesis.json" > "${BOOK}/leios/shelley-genesis.next"
mv -f "${BOOK}/leios/shelley-genesis.next" "${BOOK}/leios/shelley-genesis.json"
bash "${TOOL}" musashi --summary "${summary}" || fail "respin update failed"
[[ "$(jq -r '.systemStart' "${REPO}/files/configs/cnode/musashi/shelley-genesis.json")" == "2030-01-01T00:00:00Z" ]] ||
  fail "genesis was not updated"
grep -qF "Respin" "${summary}" || fail "respin was not flagged"
grep -qF "delete its \`db\` folder" "${summary}" || fail "respin has no operator steps"

# Dijkstra: the release comes from cardano-node, its CLI stays put, and the
# nested config keeps Guild's tracing.
reset_fixtures
book_requires dijkstra "11.3.0"
fake_release IntersectMBO/cardano-node 11.3.0 11.3.0 99.0.0.0 \
  cardano-node-11.3.0-linux-amd64.tar.gz cardano-node-11.3.0-linux-arm64.tar.gz
cli_before="$(jq -r '.companions["cardano-cli"].version' "${DIJKSTRA_OVERLAY}")"
bash "${TOOL}" dijkstra --summary "${summary}" || fail "dijkstra update failed"
[[ "$(jq -r '.version' "${DIJKSTRA_OVERLAY}")" == "11.3.0" ]] || fail "dijkstra version not recorded"
[[ "$(jq -r '.companions["cardano-cli"].version' "${DIJKSTRA_OVERLAY}")" == "${cli_before}" ]] || fail "dijkstra cli changed"
config="${REPO}/files/configs/cnode/dijkstra/config.json"
[[ "$(jq -r '.Configuration.HermodTracing.TraceOptionNodeName' "${config}")" == "cnode" ]] || fail "nested node name was lost"
[[ "$(jq -r '.Configuration.Protocol.ShelleyGenesisFile' "${config}")" == "/opt/cardano/cnode/files/shelley-genesis.json" ]] ||
  fail "nested paths are not absolute"
grep -qF "does not name a CLI" "${summary}" || fail "summary hides the manual CLI step"
grep -qF "db-sync" "${summary}" || fail "summary hides the manual db-sync step"

# Refusals, each leaving the checkout as it was.
reset_fixtures
book_requires leios "11.3.0.200-rc-2026w99"
expect_refusal musashi "has no release rc-2026w99"

reset_fixtures
book_requires leios "11.3.0.200-rc-2026w99"
fake_release "${LEIOS}" rc-2026w99 11.3.0.999 11.5.0.0 "${MUSASHI_X86}" "${MUSASHI_ARM}"
expect_refusal musashi "but release rc-2026w99 reports 11.3.0.999"

reset_fixtures
book_requires leios "11.3.0.200-rc-2026w99"
fake_release "${LEIOS}" rc-2026w99 11.3.0.200 11.5.0.0 "wrong-name.tar.gz" "${MUSASHI_ARM}"
expect_refusal musashi "has no asset ${MUSASHI_X86}"

reset_fixtures
book_requires leios "11.3.0.200-rc-2026w99"
fake_release "${LEIOS}" rc-2026w99 11.3.0.200 11.5.0.0 "${MUSASHI_X86}" "${MUSASHI_ARM}"
release="${API}/repos/${LEIOS}/releases/tags/rc-2026w99"
jq 'del(.assets[].digest)' "${release}" > "${release}.next" && mv -f "${release}.next" "${release}"
expect_refusal musashi "no sha256 digest"

reset_fixtures
book_requires leios "11.3.0.200-rc-2026w99"
fake_release "${LEIOS}" rc-2026w99 11.3.0.200 11.5.0.0 "${MUSASHI_X86}" "${MUSASHI_ARM}"
release="${API}/repos/${LEIOS}/releases/tags/rc-2026w99"
jq '.assets[].digest = ("sha256:" + ("0" * 64))' "${release}" > "${release}.next" && mv -f "${release}.next" "${release}"
expect_refusal musashi "does not match GitHub's published digest"

reset_fixtures
book_requires leios "11.3.0"
expect_refusal musashi "expected a Leios build"

reset_fixtures
jq 'del(.MinNodeVersion)' "${BOOK}/leios/config.json" > "${BOOK}/leios/config.next"
mv -f "${BOOK}/leios/config.next" "${BOOK}/leios/config.json"
expect_refusal musashi "has no MinNodeVersion"

reset_fixtures
jq '.LeiosGenesisFile = "leios-genesis.json"' "${BOOK}/leios/config.json" > "${BOOK}/leios/config.next"
mv -f "${BOOK}/leios/config.next" "${BOOK}/leios/config.json"
expect_refusal musashi "now uses leios-genesis.json"

reset_fixtures
rm -f "${BOOK}/leios/peer-snapshot.json"
expect_refusal musashi "could not read peer-snapshot.json"

expect_usage="$(bash "${TOOL}" mainnet 2>&1 || true)"
grep -qF "usage:" <<< "${expect_usage}" || fail "unknown network should show usage"

printf 'update-network-pins: PASS\n'
