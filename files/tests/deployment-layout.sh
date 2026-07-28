#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2329
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

fail() {
  printf 'deployment layout test failed: %s\n' "$1" >&2
  exit 1
}

for implementation in cnode dingo amaru; do
  release_file="${ROOT_DIR}/files/node-implementations/${implementation}/release.json"
  [[ -s "${release_file}" ]] ||
    fail "missing ${implementation} release metadata"
  jq -e --arg implementation "${implementation}" '
    .schemaVersion == 1 and
    .implementation == $implementation and
    (.version |
      type == "string" and
      test("^[0-9]+([.][0-9]+){1,3}([+-][A-Za-z0-9.-]+)?$")) and
    (.artifacts | keys == ["linux-aarch64", "linux-x86_64"]) and
    all(.artifacts[];
      keys == ["sha256", "url"] and
      (.url | type == "string" and startswith("https://")) and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    )
  ' "${release_file}" >/dev/null ||
    fail "invalid ${implementation} release metadata"
done

for profile in \
  "${ROOT_DIR}/scripts/cnode-helper-scripts/deploy-cnode.sh" \
  "${ROOT_DIR}/scripts/dingo-helper-scripts/deploy-dingo.sh" \
  "${ROOT_DIR}/scripts/amaru-helper-scripts/deploy-amaru.sh"; do
  if grep -Eq \
    '^(# *User Variables|#?(G_ACCOUNT|NODE_IMPLEMENTATION|NETWORK|BRANCH|NODE_PARENT|NODE_NAME|NODE_PORT|CURL_TIMEOUT|DOWNLOAD_TIMEOUT|UPDATE_CHECK|SUDO)=)' \
    "${profile}"; then
    fail "$(basename "${profile}") contains dispatcher-owned user variables"
  fi
done
grep -q '^# User Variables' \
  "${ROOT_DIR}/scripts/cnode-helper-scripts/guild-deploy.sh" ||
  fail "guild-deploy.sh does not own the common user-variable block"

CNODE_RELEASE="${ROOT_DIR}/files/node-implementations/cnode/release.json"
jq -e '
  (
    [
      .. |
      objects |
      keys[] |
      select(
        . == "checksumSource" or
        . == "experimentalDeployment" or
        . == "filename" or
        . == "prerelease" or
        . == "provides" or
        . == "publishedAt" or
        . == "release" or
        . == "releasePolicy" or
        . == "upstreamChecksumManifest"
      )
    ] |
    length == 0
  ) and
  (.tools | to_entries | all(
    if .value.version == "latest" then
      (.value.github | type == "string") and
      (.value.assets | type == "object" and length > 0) and
      (.value | has("artifacts") | not)
    else
      (.value.artifacts | type == "object" and length > 0) and
      (.value | has("assets") | not)
    end
  )) and
  (.build.toolchain | all(
    type == "string" and
    test("^[0-9]+([.][0-9]+){1,3}([+-][A-Za-z0-9.-]+)?$")
  ))
' "${CNODE_RELEASE}" >/dev/null ||
  fail "cnode release metadata contains redundant or malformed fields"

(
  # shellcheck source=../../scripts/cnode-helper-scripts/deploy-cnode.sh
  . "${ROOT_DIR}/scripts/cnode-helper-scripts/deploy-cnode.sh"
  cnode_deploy_validate_release_metadata "${CNODE_RELEASE}"
) || fail "runtime validator rejected compact cnode release metadata"

if grep -Eq 'get-ghcup[.]haskell[.]org|ghcup upgrade' \
  "${ROOT_DIR}/scripts/cnode-helper-scripts/deploy-cnode.sh"; then
  fail "cnode source-build bootstrap still bypasses pinned GHCup metadata"
fi
if grep -Eq \
  'LedgerHQ/udev-rules/master|curl.*https://data[.]trezor[.]io' \
  "${ROOT_DIR}/scripts/cnode-helper-scripts/deploy-cnode.sh"; then
  fail "hardware-wallet support still downloads mutable privileged rules"
fi
if grep -q 'cmdAvailable "catalyst-toolbox".*return 0' \
  "${ROOT_DIR}/scripts/common-helper-scripts/cntools.library"; then
  fail "Catalyst Toolbox still bypasses pinned release verification when present"
fi
grep -q 'sha256sum "${installed_binary}"' \
  "${ROOT_DIR}/scripts/common-helper-scripts/cntools.library" ||
  fail "installed Catalyst Toolbox is not compared with the pinned artifact"

[[ ! -e "${ROOT_DIR}/files/node-deps.json" ]] ||
  fail "legacy node-deps.json still exists"

expected_config_names="$(
  printf '%s\n' \
    alonzo-genesis.json \
    byron-genesis.json \
    config.json \
    conway-genesis.json \
    db-sync-config.json \
    shelley-genesis.json \
    submitapi.json \
    topology.json |
    LC_ALL=C sort
)"

for network in guild mainnet preprod preview; do
  canonical_dir="${ROOT_DIR}/files/configs/cnode/${network}"
  [[ -d "${canonical_dir}" ]] ||
    fail "missing canonical cnode configuration for ${network}"
  [[ ! -e "${ROOT_DIR}/files/configs/${network}" ]] ||
    fail "legacy cnode configuration path still exists for ${network}"

  canonical_names="$(find "${canonical_dir}" -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort)"
  [[ "${canonical_names}" == "${expected_config_names}" ]] ||
    fail "canonical cnode configuration file set is incomplete for ${network}"
done

(
  # shellcheck source=../../scripts/cnode-helper-scripts/deploy-cnode.sh
  . "${ROOT_DIR}/scripts/cnode-helper-scripts/deploy-cnode.sh"

  URL_RAW="https://raw.example/fork/guild-operators/test-branch"
  NETWORK="preview"
  CURL_TIMEOUT=10
  request_log="$(mktemp "${TMPDIR:-/tmp}/cnode-config-requests.XXXXXX")"
  output_file="$(mktemp "${TMPDIR:-/tmp}/cnode-config-output.XXXXXX")"
  trap 'rm -f -- "${request_log}" "${output_file}"' EXIT

  curl() {
    local destination=""
    local url=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -o)
          destination="$2"
          shift 2
          ;;
        -*)
          shift
          [[ "$1" =~ ^[0-9]+$ ]] && shift || true
          ;;
        *)
          url="$1"
          shift
          ;;
      esac
    done
    printf '%s\n' "${url}" >> "${request_log}"
    printf '%s\n' "${url}" > "${destination}"
  }

  cnode_deploy_fetch_network_config "config.json" "${output_file}" ||
    fail "canonical cnode configuration fetch failed"
  [[ "$(wc -l < "${request_log}" | tr -d '[:space:]')" == "1" ]] ||
    fail "cnode configuration fetch made more than one request"
  grep -q '^https://raw.example/fork/guild-operators/test-branch/files/configs/cnode/preview/config.json$' \
    "${request_log}" ||
    fail "cnode configuration request used the wrong repository, branch, or path"
)

printf 'deployment layout tests passed\n'
