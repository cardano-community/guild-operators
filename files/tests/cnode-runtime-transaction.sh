#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2012,SC2016,SC2030,SC2031,SC2034,SC2329
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-cnode-runtime.XXXXXX")"
BASE_PATH="${PATH}"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="$3"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

for required_command in awk bash curl find git jq sed sha256sum; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

set +u
# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"
# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/cnode-helper-scripts/deploy-cnode.sh"
set -u

run_profile_state_test() (
  set +u
  NODE_HOME="${TEST_ROOT}/profile-state"
  mkdir -p "${NODE_HOME}/files"
  S_ARGS="dx"

  # Inherited execution state must not trigger unrelated profile actions.
  CNODE_DEPLOY_INSTALL_CNCLI="Y"
  CNODE_DEPLOY_INSTALL_OGMIOS="Y"
  INSTALL_CNCLI="Y"
  INSTALL_OGMIOS="Y"
  INSTALL_CSIGNER="Y"
  cnode_deploy_init_context() { :; }

  cnode_deploy_parse_flags
  assert_eq "${CNODE_DEPLOY_INSTALL_BINARY}" "Y" "cnode binary flag"
  assert_eq "${CNODE_DEPLOY_INSTALL_SIGNER}" "Y" "cnode signer flag"
  assert_eq "${CNODE_DEPLOY_INSTALL_CNCLI}" "N" "inherited CNCLI state"
  assert_eq "${CNODE_DEPLOY_INSTALL_OGMIOS}" "N" "inherited Ogmios state"
  assert_eq "${CNODE_DEPLOY_INSTALL_BLOCKPERF}" "N" "inherited blockperf state"
  assert_eq "${CNODE_DEPLOY_FORCE_CONFIG}" "N" "inherited config state"
)

run_initial_port_seed_test() (
  local node_root="${TEST_ROOT}/initial-port"
  mkdir -p "${node_root}/scripts"
  cp "${REPO_ROOT}/scripts/common-helper-scripts/env" \
    "${node_root}/scripts/env"
  NODE_HOME="${node_root}"
  NODE_PORT=4242

  cnode_deploy_seed_initial_env_port "N"
  grep -q '^CNODE_PORT=4242$' "${node_root}/scripts/env" ||
    fail "fresh cnode environment did not receive dispatcher NODE_PORT"

  sed 's/^CNODE_PORT=.*/CNODE_PORT=7777/' \
    "${node_root}/scripts/env" > "${node_root}/scripts/env.updated"
  mv -f "${node_root}/scripts/env.updated" "${node_root}/scripts/env"
  NODE_PORT=5252
  cnode_deploy_seed_initial_env_port "Y"
  grep -q '^CNODE_PORT=7777$' "${node_root}/scripts/env" ||
    fail "existing cnode environment port was overwritten"
)

run_release_metadata_test() (
  local node_root="${TEST_ROOT}/release-metadata"
  local valid_manifest="${REPO_ROOT}/files/node-implementations/cnode/release.json"
  local invalid_manifest="${node_root}/invalid-release.json"
  local request_log="${node_root}/request.log"
  local release_fixture="${valid_manifest}"

  mkdir -p "${node_root}/files"
  jq '.implementation = "dingo"' "${valid_manifest}" > "${invalid_manifest}"
  NODE_HOME="${node_root}"

  dispatcher_source_copy() {
    local relative_path="$1"
    local destination="$2"
    printf '%s\n' "${relative_path}" >> "${request_log}"
    cp -- "${release_fixture}" "${destination}"
  }

  cnode_deploy_install_release_metadata
  cmp -s "${valid_manifest}" "${node_root}/files/cnode-release.json" ||
    fail "cnode release metadata was not installed atomically"
  assert_eq "${CARDANO_NODE_VERSION}" \
    "$(jq -er '.version' "${valid_manifest}")" \
    "cardano-node manifest version"
  assert_eq "${CARDANO_CLI_VERSION}" \
    "$(jq -er '.companions["cardano-cli"].version' "${valid_manifest}")" \
    "cardano-cli manifest version"
  assert_eq "${CNODE_BUILD_GHC_VERSION}" \
    "$(jq -er '.build.toolchain.ghc' "${valid_manifest}")" \
    "GHC manifest version"
  assert_eq "${CNODE_BUILD_CABAL_VERSION}" \
    "$(jq -er '.build.toolchain.cabal' "${valid_manifest}")" \
    "Cabal manifest version"
  assert_eq "${CNODE_BUILD_LIBSODIUM_REF}" \
    "$(jq -er '.build.sourceDependencies.libsodium.ref' "${valid_manifest}")" \
    "libsodium manifest ref"
  assert_eq "${CNODE_BUILD_LIBSODIUM_VERSION}" \
    "$(jq -er '.build.sourceDependencies.libsodium.version' "${valid_manifest}")" \
    "libsodium manifest version"
  assert_eq "${CNODE_BUILD_SECP256K1_REF}" \
    "$(jq -er '.build.sourceDependencies.secp256k1.ref' "${valid_manifest}")" \
    "secp256k1 manifest ref"
  assert_eq "${CNODE_BUILD_SECP256K1_VERSION}" \
    "$(jq -er '.build.sourceDependencies.secp256k1.version' "${valid_manifest}")" \
    "secp256k1 manifest version"
  assert_eq "${CNODE_BUILD_BLST_REF}" \
    "$(jq -er '.build.sourceDependencies.blst.ref' "${valid_manifest}")" \
    "BLST manifest ref"
  assert_eq "${CNODE_BUILD_BLST_VERSION}" \
    "$(jq -er '.build.sourceDependencies.blst.version' "${valid_manifest}")" \
    "BLST manifest version"
  grep -q '^files/node-implementations/cnode/release.json$' \
    "${request_log}" ||
    fail "cnode release metadata used the wrong snapshot path"

  release_fixture="${invalid_manifest}"
  if (cnode_deploy_install_release_metadata >/dev/null 2>&1); then
    fail "invalid cnode release metadata was accepted"
  fi
  cmp -s "${valid_manifest}" "${node_root}/files/cnode-release.json" ||
    fail "invalid cnode release metadata replaced the installed manifest"
)

run_release_manifest_validation_tests() (
  local valid_manifest="${REPO_ROOT}/files/node-implementations/cnode/release.json"
  local candidate="${TEST_ROOT}/release-validation.json"
  local mutation context

  assert_manifest_rejected() {
    mutation="$1"
    context="$2"
    jq "${mutation}" "${valid_manifest}" > "${candidate}" ||
      fail "could not prepare ${context} manifest fixture"
    if cnode_deploy_validate_release_metadata "${candidate}" >/dev/null 2>&1; then
      fail "${context} manifest was accepted"
    fi
  }

  cnode_deploy_validate_release_metadata "${valid_manifest}" ||
    fail "checked-in cnode release manifest was rejected"

  jq '
    .tools.cncli.assets["linux-x86_64"] =
      "\\Acncli-[^/]+-ubuntu22-x86_64-unknown-linux-musl[.]tar[.]gz\\z"
  ' "${valid_manifest}" > "${candidate}"
  cnode_deploy_validate_release_metadata "${candidate}" ||
    fail "absolute anchored latest artifact selector was rejected"

  assert_manifest_rejected \
    'del(.version)' \
    "missing primary version"
  assert_manifest_rejected \
    '.version = "latest"' \
    "moving primary version"
  assert_manifest_rejected \
    '.version = "../11.0.1"' \
    "unsafe primary version"
  assert_manifest_rejected \
    'del(.artifacts["linux-aarch64"])' \
    "missing primary architecture"
  assert_manifest_rejected \
    'del(.tools.cncli.minimumVersion)' \
    "missing required CNCLI minimum"
  assert_manifest_rejected \
    '.artifacts["linux-x86_64"].filename = "cardano-node.tar.gz"' \
    "unexpected artifact filename metadata"
  assert_manifest_rejected \
    '.artifacts["linux-x86_64"].url = "http://example.test/cardano-node.tar.gz"' \
    "non-HTTPS artifact URL"
  assert_manifest_rejected \
    '.artifacts["linux-x86_64"].url += "\n"' \
    "newline-terminated artifact URL"
  assert_manifest_rejected \
    '.artifacts["linux-x86_64"].sha256 |= ascii_upcase' \
    "uppercase artifact checksum"
  assert_manifest_rejected \
    '.artifacts["linux-x86_64"].sha256 += "\n"' \
    "newline-terminated artifact checksum"
  assert_manifest_rejected \
    '.releasePolicy = {"mode": "pinned"}' \
    "legacy primary release policy"
  assert_manifest_rejected \
    '.tools.cncli.assets["linux-x86_64"] = "cncli-.*"' \
    "unanchored artifact selector"
  assert_manifest_rejected \
    '.tools.cncli.assets["darwin-x86_64"] = "^cncli-darwin$"' \
    "unsupported selector architecture"
  assert_manifest_rejected \
    'del(.tools.cncli.github)' \
    "latest tool without a GitHub repository"
  assert_manifest_rejected \
    '.tools.cncli.github = "https://github.com/cardano-community/cncli"' \
    "invalid compact GitHub repository"
  assert_manifest_rejected \
    '.tools.cncli.channel = "prerelease"' \
    "unsupported latest channel"
  assert_manifest_rejected \
    'del(.tools["catalyst-toolbox"])' \
    "missing required pinned tool"
  assert_manifest_rejected \
    '.tools.unreviewed = .tools["catalyst-toolbox"]' \
    "invalid extra tool"
  assert_manifest_rejected \
    'del(.companions["cardano-db-sync"].version)' \
    "pinned companion without a version"
  assert_manifest_rejected \
    '.companions["cardano-db-sync"].version = "latest"' \
    "moving companion version"
  assert_manifest_rejected \
    'del(.companions["cardano-db-sync"].artifacts["linux-x86_64"].sha256)' \
    "incomplete companion artifact"
  assert_manifest_rejected \
    '.tools.ghcup.channel = "stable"' \
    "latest-only metadata on a pinned tool"
  assert_manifest_rejected \
    'del(.managedInstallers.openblockperf)' \
    "missing managed openBlockPerf installer"
  assert_manifest_rejected \
    '.managedInstallers.openblockperf.version = "rolling"' \
    "invalid openBlockPerf release policy"
  assert_manifest_rejected \
    '.managedInstallers.openblockperf.installer.url = "http://example.test/blockperf-install.sh"' \
    "insecure openBlockPerf installer URL"
  assert_manifest_rejected \
    '.managedInstallers.openblockperf.installer.url |= sub("[0-9a-f]{40}"; "main")' \
    "mutable openBlockPerf installer URL"
  assert_manifest_rejected \
    '.managedInstallers.openblockperf.installer.version = "0.2.0"' \
    "inferable openBlockPerf installer version"
  assert_manifest_rejected \
    '.managedInstallers.openblockperf.installer.sha256 = "invalid"' \
    "invalid openBlockPerf installer checksum"
  assert_manifest_rejected \
    '.supportArtifacts.hardwareWalletRules.ledger.snapshotId = "unexpected"' \
    "unexpected Ledger udev metadata"
  assert_manifest_rejected \
    '.supportArtifacts.hardwareWalletRules.ledger.url |= sub("[0-9a-f]{40}"; "main")' \
    "mutable Ledger udev URL"
  assert_manifest_rejected \
    '.supportArtifacts.hardwareWalletRules.trezor.sha256 = "invalid"' \
    "invalid Trezor udev checksum"
  assert_manifest_rejected \
    '.build.toolchain.ghc = {"version": "9.6.7"}' \
    "non-string GHC toolchain version"
  assert_manifest_rejected \
    '.build.sourceDependencies.blst.ref = "../outside-worktree"' \
    "unsafe source dependency ref"
  assert_manifest_rejected \
    '.build.sourceDependencies.blst.ref = "v0.3.14"' \
    "mutable source dependency tag"
)

run_release_resolver_tests() (
  local node_root="${TEST_ROOT}/release-resolver"
  local manifest="${node_root}/files/cnode-release.json"
  local manifest_tmp="${node_root}/files/cnode-release.json.tmp"
  local api_fixture="${node_root}/api.json"
  local api_base="${node_root}/api-base.json"
  local request_log="${node_root}/requests.log"
  local payload="${node_root}/payload"
  local downloaded="${node_root}/downloaded"
  local payload_sha expected_tag expected_url expected_sha destination url
  local component architecture minimum_version

  mkdir -p "${node_root}/files"
  cp "${REPO_ROOT}/files/node-implementations/cnode/release.json" "${manifest}"
  NODE_HOME="${node_root}"
  CNODE_RELEASE_MANIFEST="${manifest}"
  CURL_TIMEOUT=30
  DOWNLOAD_TIMEOUT=60

  # A compact pinned tool consumes only its concrete version and verified
  # architecture artifacts, and must never contact a release API.
  minimum_version="$(jq -er '.tools.cncli.minimumVersion' "${manifest}")"
  jq --arg minimum_version "${minimum_version}" '
    .tools.cncli = {
      version: "6.7.0",
      minimumVersion: $minimum_version,
      artifacts: {
        "linux-x86_64": {
          url: "https://example.test/cncli-6.7.0-linux-x86_64.tar.gz",
          sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        },
        "linux-aarch64": {
          url: "https://example.test/cncli-6.7.0-linux-aarch64.tar.gz",
          sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }
      }
    }
  ' "${manifest}" > "${manifest_tmp}"
  mv -f "${manifest_tmp}" "${manifest}"
  cnode_deploy_validate_release_metadata "${manifest}" ||
    fail "valid compact pinned tool metadata was rejected"
  curl() {
    printf 'unexpected pinned resolver request\n' >> "${request_log}"
    return 22
  }
  while IFS=$'\t' read -r component architecture expected_tag expected_url \
    expected_sha; do
    cnode_deploy_resolve_tool "${component}" "${architecture}"
    assert_eq "${CNODE_RESOLVED_MODE}" "pinned" \
      "${component}/${architecture} pinned resolver mode"
    assert_eq "${CNODE_RESOLVED_TAG}" "${expected_tag}" \
      "${component}/${architecture} pinned resolver tag"
    assert_eq "${CNODE_RESOLVED_URL}" "${expected_url}" \
      "${component}/${architecture} pinned resolver URL"
    assert_eq "${CNODE_RESOLVED_SHA256}" "${expected_sha}" \
      "${component}/${architecture} pinned resolver checksum"
  done < <(
    jq -r '
      .tools.cncli as $tool |
      $tool.artifacts | to_entries[] |
      [
        "cncli",
        .key,
        $tool.version,
        .value.url,
        .value.sha256
      ] | @tsv
    ' "${manifest}"
  )
  [[ ! -e "${request_log}" ]] ||
    fail "pinned release policy contacted a release API"

  jq '.tools.cncli.minimumVersion = "99.0.0"' \
    "${manifest}" > "${manifest_tmp}"
  mv -f "${manifest_tmp}" "${manifest}"
  if (cnode_deploy_resolve_tool "cncli" "linux-x86_64" >/dev/null 2>&1); then
    fail "pinned resolver accepted a release below its tool minimum"
  fi
  jq --arg minimum_version "${minimum_version}" \
    '.tools.cncli.minimumVersion = $minimum_version' \
    "${manifest}" > "${manifest_tmp}"
  mv -f "${manifest_tmp}" "${manifest}"

  # Latest mode makes exactly one metadata request, selects the matching asset
  # from that response, and requires its GitHub-published SHA-256 digest.
  jq --arg minimum_version "${minimum_version}" '
    .tools.cncli = {
      version: "latest",
      github: "example/tool",
      minimumVersion: $minimum_version,
      assets: {
        "linux-x86_64": "^tool-linux-x86_64[.]tar[.]gz$",
        "linux-aarch64": "^tool-linux-aarch64[.]tar[.]gz$"
      }
    }
  ' "${manifest}" > "${manifest_tmp}"
  mv -f "${manifest_tmp}" "${manifest}"
  printf '%s\n' '{
    "tag_name": "v9.8.7",
    "draft": false,
    "prerelease": false,
    "assets": [
      {
        "name": "tool-linux-x86_64.tar.gz",
        "browser_download_url": "https://github.com/example/tool/releases/download/v9.8.7/tool-linux-x86_64.tar.gz",
        "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      },
      {
        "name": "tool-linux-aarch64.tar.gz",
        "browser_download_url": "https://github.com/example/tool/releases/download/v9.8.7/tool-linux-aarch64.tar.gz",
        "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      }
    ]
  }' > "${api_base}"
  cp -- "${api_base}" "${api_fixture}"
  : > "${request_log}"
  curl() {
    destination=""
    url=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -o)
          destination="$2"
          shift 2
          ;;
        -m)
          shift 2
          ;;
        -*)
          shift
          ;;
        *)
          url="$1"
          shift
          ;;
      esac
    done
    printf '%s\n' "${url}" >> "${request_log}"
    cp -- "${api_fixture}" "${destination}"
  }
  cnode_deploy_resolve_tool "cncli" "linux-aarch64"
  assert_eq "${CNODE_RESOLVED_MODE}" "latest" "latest resolver mode"
  assert_eq "${CNODE_RESOLVED_TAG}" "v9.8.7" "latest resolver tag"
  assert_eq "${CNODE_RESOLVED_VERSION}" "9.8.7" "latest resolver version"
  assert_eq "${CNODE_RESOLVED_FILENAME}" "tool-linux-aarch64.tar.gz" \
    "latest resolver architecture selection"
  assert_eq "${CNODE_RESOLVED_SHA256}" \
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    "latest resolver digest"
  assert_eq "$(wc -l < "${request_log}" | tr -d '[:space:]')" "1" \
    "latest resolver API request count"
  grep -q '^https://api.github.com/repos/example/tool/releases/latest$' \
    "${request_log}" ||
    fail "stable latest resolver used the wrong GitHub endpoint"

  # Multiple matching assets, prereleases on the stable channel, missing
  # digests and cross-repository URLs must all fail closed.
  jq '.assets += [.assets[1]]' "${api_base}" > "${api_fixture}.invalid"
  mv -f "${api_fixture}.invalid" "${api_fixture}"
  if (cnode_deploy_resolve_tool "cncli" "linux-aarch64" >/dev/null 2>&1); then
    fail "latest resolver accepted multiple matching assets"
  fi

  jq '.assets = [.assets[0]] | .prerelease = true' \
    "${api_base}" > "${api_fixture}.invalid"
  mv -f "${api_fixture}.invalid" "${api_fixture}"
  if (cnode_deploy_resolve_tool "cncli" "linux-x86_64" >/dev/null 2>&1); then
    fail "stable latest resolver accepted a prerelease"
  fi

  jq '.prerelease = false | .assets[0].digest = null' \
    "${api_base}" > "${api_fixture}.invalid"
  mv -f "${api_fixture}.invalid" "${api_fixture}"
  if (cnode_deploy_resolve_tool "cncli" "linux-x86_64" >/dev/null 2>&1); then
    fail "latest resolver accepted an asset without a GitHub digest"
  fi

  jq '
    .assets[0].digest =
      "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" |
    .assets[0].browser_download_url =
      "https://github.com/other/tool/releases/download/v9.8.7/tool-linux-x86_64.tar.gz"
  ' "${api_base}" > "${api_fixture}.invalid"
  mv -f "${api_fixture}.invalid" "${api_fixture}"
  if (cnode_deploy_resolve_tool "cncli" "linux-x86_64" >/dev/null 2>&1); then
    fail "latest resolver accepted a cross-repository asset URL"
  fi

  jq '
    .assets[0].browser_download_url =
      "https://github.com/example/tool/releases/download/v9.8.6/tool-linux-x86_64.tar.gz"
  ' "${api_base}" > "${api_fixture}"
  if (cnode_deploy_resolve_tool "cncli" "linux-x86_64" >/dev/null 2>&1); then
    fail "latest resolver accepted an asset URL for a stale release tag"
  fi

  jq '
    .assets[0].browser_download_url =
      "https://github.com/example/tool/releases/download/v9.8.7/different.tar.gz"
  ' "${api_base}" > "${api_fixture}"
  if (cnode_deploy_resolve_tool "cncli" "linux-x86_64" >/dev/null 2>&1); then
    fail "latest resolver accepted an asset URL with a different basename"
  fi

  minimum_version="$(jq -er '.tools.cncli.minimumVersion' "${manifest}")"
  jq '.tools.cncli.minimumVersion = "99.0.0"' \
    "${manifest}" > "${manifest_tmp}"
  mv -f "${manifest_tmp}" "${manifest}"
  cp -- "${api_base}" "${api_fixture}"
  if (cnode_deploy_resolve_tool "cncli" "linux-x86_64" >/dev/null 2>&1); then
    fail "latest resolver accepted a release below its tool minimum"
  fi
  jq --arg minimum_version "${minimum_version}" \
    '.tools.cncli.minimumVersion = $minimum_version' \
    "${manifest}" > "${manifest_tmp}"
  mv -f "${manifest_tmp}" "${manifest}"

  # The explicit "any" channel uses one release-list request and may select a
  # prerelease, while retaining the same exact-asset and digest requirements.
  jq '
    .tools.cncli.channel = "any"
  ' "${manifest}" > "${manifest_tmp}"
  mv -f "${manifest_tmp}" "${manifest}"
  jq '
    .prerelease = true |
    .assets[0].browser_download_url =
      "https://github.com/example/tool/releases/download/v9.8.7/tool-linux-x86_64.tar.gz" |
    .assets[0].digest =
      "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" |
    [.]
  ' "${api_base}" > "${api_fixture}.any"
  mv -f "${api_fixture}.any" "${api_fixture}"
  : > "${request_log}"
  cnode_deploy_resolve_tool "cncli" "linux-x86_64"
  assert_eq "${CNODE_RESOLVED_TAG}" "v9.8.7" \
    "any-channel prerelease resolver tag"
  assert_eq "$(wc -l < "${request_log}" | tr -d '[:space:]')" "1" \
    "any-channel resolver API request count"
  grep -q '^https://api.github.com/repos/example/tool/releases?per_page=20$' \
    "${request_log}" ||
    fail "any-channel resolver used the wrong GitHub endpoint"

  # Artifact downloads use the resolved checksum for both pinned and latest
  # policies and leave checksum failures fatal.
  printf 'verified release payload\n' > "${payload}"
  payload_sha="$(sha256sum "${payload}" | awk '{print $1}')"
  CNODE_RESOLVED_COMPONENT="fixture-tool"
  CNODE_RESOLVED_VERSION="1.0.0"
  CNODE_RESOLVED_FILENAME="fixture-tool.tar.gz"
  CNODE_RESOLVED_URL="https://github.com/example/tool/releases/download/v1.0.0/fixture-tool.tar.gz"
  CNODE_RESOLVED_SHA256="${payload_sha}"
  curl() {
    destination=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -o)
          destination="$2"
          shift 2
          ;;
        -m)
          shift 2
          ;;
        -*)
          shift
          ;;
        *)
          shift
          ;;
      esac
    done
    cp -- "${payload}" "${destination}"
  }
  cnode_deploy_download_resolved_artifact "${downloaded}"
  cmp -s "${payload}" "${downloaded}" ||
    fail "verified artifact download changed the payload"
  CNODE_RESOLVED_SHA256="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  if (cnode_deploy_download_resolved_artifact "${downloaded}.bad" >/dev/null 2>&1); then
    fail "artifact download accepted a checksum mismatch"
  fi
)

run_binary_staging_test() (
  local node_root="${TEST_ROOT}/binary-staging"
  local binary
  local -a expected_binaries=(
    cardano-node
    cardano-cli
    cardano-submit-api
    bech32
    cardano-address
    cardano-db-sync
  )

  HOME="${node_root}/home"
  TMPDIR="${node_root}/tmp"
  mkdir -p "${HOME}/.local/bin" "${HOME}/tmp" "${TMPDIR}"
  for binary in "${expected_binaries[@]}"; do
    printf 'installed-%s\n' "${binary}" > "${HOME}/.local/bin/${binary}"
    printf 'stale-%s\n' "${binary}" > "${HOME}/tmp/${binary}"
  done

  CNODE_SKIP_DBSYNC_DOWNLOAD="N"
  CARDANO_NODE_VERSION="fixture-node"
  CARDANO_CLI_VERSION="fixture-cli"
  STUB_NODE_ARCHIVE_COMPLETE="N"

  cnode_deploy_load_release_metadata() { :; }
  cnode_deploy_architecture() { printf 'linux-x86_64\n'; }
  cnode_deploy_resolve_primary() {
    CNODE_RESOLVED_COMPONENT="cardano-node"
    CNODE_RESOLVED_VERSION="fixture-node"
  }
  cnode_deploy_resolve_companion() {
    CNODE_RESOLVED_COMPONENT="$1"
    CNODE_RESOLVED_VERSION="fixture-${1}"
  }
  cnode_deploy_download_resolved_artifact() {
    printf 'fixture archive\n' > "$1"
  }
  cnode_deploy_verify_binary_version() { return 0; }
  log_progress() { :; }
  log_info() { :; }
  log_ok() { :; }
  tar() {
    case "$2" in
      cnode.tar.gz)
        printf 'fresh-cardano-node\n' > cardano-node
        if [[ "${STUB_NODE_ARCHIVE_COMPLETE}" == "Y" ]]; then
          printf 'fresh-cardano-submit-api\n' > cardano-submit-api
          printf 'fresh-bech32\n' > bech32
        fi
        ;;
      ccli.tar.gz)
        printf 'fresh-cardano-cli\n' > cardano-cli-x86_64-linux
        ;;
      caddress.tar.gz)
        printf 'fresh-cardano-address\n' > cardano-address
        ;;
      cnodedbsync.tar.gz)
        printf 'fresh-cardano-db-sync\n' > cardano-db-sync
        ;;
      *)
        return 2
        ;;
    esac
  }

  if (download_cnodebins >/dev/null 2>&1); then
    fail "an incomplete node archive was completed with stale shared temporary files"
  fi
  for binary in "${expected_binaries[@]}"; do
    grep -q "^installed-${binary}$" "${HOME}/.local/bin/${binary}" ||
      fail "failed binary staging changed the installed ${binary}"
  done

  STUB_NODE_ARCHIVE_COMPLETE="Y"
  download_cnodebins
  for binary in "${expected_binaries[@]}"; do
    grep -q "^fresh-${binary}$" "${HOME}/.local/bin/${binary}" ||
      fail "validated binary staging did not install fresh ${binary}"
  done
)

run_hardware_wallet_rule_policy_test() (
  local install_calls=0
  local info_message=""

  cnode_deploy_install_hardware_wallet_rules() {
    install_calls=$((install_calls + 1))
  }
  log_info() {
    info_message="$1"
  }

  unset CNODE_SKIP_HW_UDEV_RULES
  cnode_deploy_configure_hardware_wallet_rules
  assert_eq "${install_calls}" "1" \
    "default host hardware-wallet rule installation"

  CNODE_SKIP_HW_UDEV_RULES="Y"
  cnode_deploy_configure_hardware_wallet_rules
  assert_eq "${install_calls}" "1" \
    "container hardware-wallet rule installation skip"
  [[ "${info_message}" == *"container host"* ]] ||
    fail "container hardware-wallet rule skip omitted host guidance"
)

run_managed_installer_policy_test() (
  local node_root="${TEST_ROOT}/managed-installer"
  local manifest="${node_root}/files/cnode-release.json"
  local manifest_tmp="${manifest}.tmp"
  local fake_installer="${node_root}/fake-blockperf-install.sh"
  local invocation_log="${node_root}/invocations.log"
  local installer_sha

  mkdir -p "${node_root}/files" "${node_root}/scripts"
  cp "${REPO_ROOT}/files/node-implementations/cnode/release.json" "${manifest}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == "--version" ]]; then' \
    '  printf "blockperf-install.sh version 0.2.0\\n"' \
    '  exit 0' \
    'fi' \
    'printf "PACKAGE_VERSION=%s|%s\\n" "${PACKAGE_VERSION:-}" "$*" >> "${BLOCKPERF_TEST_LOG}"' \
    > "${fake_installer}"
  chmod 0755 "${fake_installer}"
  installer_sha="$(sha256sum "${fake_installer}" | awk '{print $1}')"
  jq --arg sha "${installer_sha}" \
    '.managedInstallers.openblockperf.installer.sha256 = $sha' \
    "${manifest}" > "${manifest_tmp}"
  mv -f "${manifest_tmp}" "${manifest}"

  NODE_HOME="${node_root}"
  NODE_NAME="cnode-test"
  NETWORK="preview"
  DOWNLOAD_TIMEOUT=30
  CNODE_RELEASE_MANIFEST="${manifest}"
  BLOCKPERF_TEST_LOG="${invocation_log}"
  sudo=""
  export BLOCKPERF_TEST_LOG

  cnode_deploy_load_release_metadata() {
    CNODE_RELEASE_MANIFEST="${manifest}"
  }
  curl() {
    local destination=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -o)
          destination="$2"
          shift 2
          ;;
        -m)
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    cp -- "${fake_installer}" "${destination}"
  }
  log_progress() { :; }
  log_info() { :; }
  log_ok() { :; }

  download_blockperf
  grep -q '^PACKAGE_VERSION=|--yes ' "${invocation_log}" ||
    fail "latest openBlockPerf policy did not delegate an unpinned stable package"

  jq '.managedInstallers.openblockperf.version = "0.0.35"' \
    "${manifest}" > "${manifest_tmp}"
  mv -f "${manifest_tmp}" "${manifest}"
  download_blockperf
  tail -n 1 "${invocation_log}" |
    grep -q '^PACKAGE_VERSION=0.0.35|--update ' ||
    fail "pinned openBlockPerf policy did not pass the configured package version"
)

run_source_checkout_test() (
  local source_root="${TEST_ROOT}/source-checkout"
  local upstream="${source_root}/upstream"
  local checkout="${source_root}/checkout"
  local other_upstream="${source_root}/other-upstream"
  local selected_commit

  mkdir -p "${upstream}" "${other_upstream}"
  git -C "${upstream}" init -q
  git -C "${upstream}" config user.name "Guild Operators Test"
  git -C "${upstream}" config user.email "guild-test@example.invalid"
  printf 'selected source\n' > "${upstream}/source.txt"
  git -C "${upstream}" add source.txt
  git -C "${upstream}" commit -q -m "selected source"
  selected_commit="$(git -C "${upstream}" rev-parse HEAD)"

  cnode_deploy_checkout_source \
    "${upstream}" "${checkout}" "${selected_commit}" "fixture source"
  assert_eq "$(git -C "${checkout}" rev-parse HEAD)" "${selected_commit}" \
    "source checkout commit"

  printf 'locally modified source\n' > "${checkout}/source.txt"
  if (cnode_deploy_checkout_source \
    "${upstream}" "${checkout}" "${selected_commit}" "fixture source" \
    >/dev/null 2>&1); then
    fail "source checkout accepted tracked content outside the manifest commit"
  fi
  git -C "${checkout}" checkout -q -- source.txt

  if (cnode_deploy_checkout_source \
    "${other_upstream}" "${checkout}" "${selected_commit}" "fixture source" \
    >/dev/null 2>&1); then
    fail "source checkout accepted a repository other than the manifest origin"
  fi
  if (cnode_deploy_checkout_source \
    "${upstream}" "${checkout}" "missing-source-ref" "fixture source" \
    >/dev/null 2>&1); then
    fail "source checkout accepted an unresolved manifest ref"
  fi
)

run_transaction_tests() (
  local fixture_root="${TEST_ROOT}/transaction"
  local fake_bin="${fixture_root}/bin"
  local fake_mv_bin="${fixture_root}/mv-bin"
  local real_mv
  local node_root remote_root curl_counter mv_counter
  local target remote_file env_tmp before after status target_count
  mkdir -p "${fake_bin}" "${fake_mv_bin}"
  real_mv="$(command -v mv)"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'output=""' \
    'url=""' \
    'while (( $# > 0 )); do' \
    '  case "$1" in' \
    '    -o) output="$2"; shift 2 ;;' \
    '    -m) shift 2 ;;' \
    '    -*) shift ;;' \
    '    *) url="$1"; shift ;;' \
    '  esac' \
    'done' \
    'count=0' \
    '[[ ! -f "${FAKE_CURL_COUNTER}" ]] || read -r count < "${FAKE_CURL_COUNTER}"' \
    'count=$((count + 1))' \
    'printf "%s\\n" "${count}" > "${FAKE_CURL_COUNTER}"' \
    'if [[ -n "${FAKE_CURL_FAIL_AT:-}" && "${count}" -eq "${FAKE_CURL_FAIL_AT}" ]]; then' \
    '  exit 22' \
    'fi' \
    'relative="${url#*/scripts/}"' \
    'cp -- "${FAKE_CURL_ROOT}/${relative}" "${output}"' \
    > "${fake_bin}/curl"
  chmod 0755 "${fake_bin}/curl"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'count=0' \
    '[[ ! -f "${FAKE_MV_COUNTER}" ]] || read -r count < "${FAKE_MV_COUNTER}"' \
    'count=$((count + 1))' \
    'printf "%s\\n" "${count}" > "${FAKE_MV_COUNTER}"' \
    'if [[ "${count}" -eq "${FAKE_MV_FAIL_AT}" ]]; then' \
    '  exit 73' \
    'fi' \
    'exec "${FAKE_MV_REAL}" "$@"' \
    > "${fake_mv_bin}/mv"
  chmod 0755 "${fake_mv_bin}/mv"

  runtime_paths() {
    printf '%s\n' \
      "${node_root}/scripts/lib/deployment.library" \
      "${node_root}/scripts/lib/env.library" \
      "${node_root}/scripts/lib/node-api.library" \
      "${node_root}/scripts/lib/systemd.library" \
      "${node_root}/scripts/adapters/cnode.adapter" \
      "${node_root}/scripts/env"
  }

  runtime_snapshot() {
    while IFS= read -r target; do
      printf '%s ' "$(basename "${target}")"
      ls -ld "${target}" | awk '{printf "%s ", $1}'
      sha256sum "${target}" | awk '{print $1}'
    done < <(runtime_paths)
  }

  assert_no_transaction_artifacts() {
    if [[ -e "${node_root}/scripts/.common-runtime-install.lock" ]]; then
      fail "$1 left the common runtime lock behind"
    fi
    if find "${node_root}/scripts" \
      \( -name '.common-runtime-install.*' -o \
         -name '.*.commit.*' -o \
         -name '.*.restore.*' \) -print -quit | grep -q .; then
      fail "$1 left transaction staging files behind"
    fi
  }

  prepare_fixture() {
    local fixture_name="$1"

    node_root="${fixture_root}/${fixture_name}/node"
    remote_root="${fixture_root}/${fixture_name}/remote/scripts"
    curl_counter="${fixture_root}/${fixture_name}/curl.count"
    mv_counter="${fixture_root}/${fixture_name}/mv.count"
    mkdir -p \
      "${node_root}/scripts/archive" \
      "${node_root}/scripts/lib" \
      "${node_root}/scripts/adapters" \
      "${remote_root}/common-helper-scripts/lib" \
      "${remote_root}/common-helper-scripts" \
      "${remote_root}/cnode-helper-scripts"

    cp "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library" \
      "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library" \
      "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library" \
      "${REPO_ROOT}/scripts/common-helper-scripts/lib/systemd.library" \
      "${node_root}/scripts/lib/"
    cp "${REPO_ROOT}/scripts/common-helper-scripts/env" \
      "${node_root}/scripts/env"
    cp "${REPO_ROOT}/scripts/cnode-helper-scripts/cnode.adapter" \
      "${node_root}/scripts/adapters/cnode.adapter"

    cp "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library" \
      "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library" \
      "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library" \
      "${REPO_ROOT}/scripts/common-helper-scripts/lib/systemd.library" \
      "${remote_root}/common-helper-scripts/lib/"
    cp "${REPO_ROOT}/scripts/common-helper-scripts/env" \
      "${remote_root}/common-helper-scripts/env"
    cp "${REPO_ROOT}/scripts/cnode-helper-scripts/cnode.adapter" \
      "${remote_root}/cnode-helper-scripts/cnode.adapter"

    env_tmp="${node_root}/scripts/.env-custom"
    sed \
      's/^#UPDATE_CHECK="Y".*/UPDATE_CHECK="N" # cnode-runtime-user-setting/' \
      "${node_root}/scripts/env" > "${env_tmp}"
    mv -f "${env_tmp}" "${node_root}/scripts/env"

    while IFS= read -r remote_file; do
      printf '\n# cnode-runtime-version=2\n' >> "${remote_file}"
    done <<EOF
${remote_root}/common-helper-scripts/lib/deployment.library
${remote_root}/common-helper-scripts/lib/env.library
${remote_root}/common-helper-scripts/lib/node-api.library
${remote_root}/common-helper-scripts/lib/systemd.library
${remote_root}/cnode-helper-scripts/cnode.adapter
${remote_root}/common-helper-scripts/env
EOF

    chmod 0644 \
      "${node_root}/scripts/env" \
      "${node_root}/scripts/lib/"*.library \
      "${node_root}/scripts/adapters/cnode.adapter" \
      "${remote_root}/common-helper-scripts/env" \
      "${remote_root}/common-helper-scripts/lib/"*.library \
      "${remote_root}/cnode-helper-scripts/cnode.adapter"

    NODE_HOME="${node_root}"
    URL_RAW="https://invalid.example/guild-operators/master"
    CURL_TIMEOUT=1
    CNODE_DEPLOY_FORCE_SCRIPTS="N"
    FAKE_CURL_ROOT="${remote_root}"
    FAKE_CURL_COUNTER="${curl_counter}"
    export NODE_HOME URL_RAW CURL_TIMEOUT CNODE_DEPLOY_FORCE_SCRIPTS
    export FAKE_CURL_ROOT FAKE_CURL_COUNTER
  }

  dispatcher_source_copy() {
    local relative_path="$1"
    local destination="$2"
    local count=0
    [[ ! -f "${curl_counter}" ]] || read -r count < "${curl_counter}"
    count=$((count + 1))
    printf '%s\n' "${count}" > "${curl_counter}"
    if [[ -n "${FAKE_CURL_FAIL_AT:-}" &&
          "${count}" -eq "${FAKE_CURL_FAIL_AT}" ]]; then
      return 22
    fi
    cp -- "${remote_root}/${relative_path#scripts/}" "${destination}"
  }

  PATH="${fake_bin}:${BASE_PATH}"
  export PATH

  prepare_fixture "download-failure"
  before="$(runtime_snapshot)"
  printf '0\n' > "${curl_counter}"
  FAKE_CURL_FAIL_AT=3
  export FAKE_CURL_FAIL_AT
  if updateCommonRuntimeBundle; then
    status=0
  else
    status=$?
  fi
  unset FAKE_CURL_FAIL_AT
  assert_eq "${status}" "2" "mid-download transaction status"
  after="$(runtime_snapshot)"
  assert_eq "${after}" "${before}" \
    "mid-download transaction changed installed runtime files"
  assert_no_transaction_artifacts "mid-download transaction"

  prepare_fixture "commit-failure"
  before="$(runtime_snapshot)"
  printf '0\n' > "${curl_counter}"
  printf '0\n' > "${mv_counter}"
  FAKE_MV_COUNTER="${mv_counter}"
  FAKE_MV_FAIL_AT=2
  FAKE_MV_REAL="${real_mv}"
  export FAKE_MV_COUNTER FAKE_MV_FAIL_AT FAKE_MV_REAL
  PATH="${fake_mv_bin}:${fake_bin}:${BASE_PATH}"
  export PATH
  if updateCommonRuntimeBundle; then
    status=0
  else
    status=$?
  fi
  PATH="${fake_bin}:${BASE_PATH}"
  export PATH
  assert_eq "${status}" "2" "mid-commit transaction status"
  after="$(runtime_snapshot)"
  assert_eq "${after}" "${before}" \
    "mid-commit transaction did not restore the original runtime bundle"
  assert_no_transaction_artifacts "mid-commit transaction"
  if find "${node_root}/scripts/archive" -type f -print -quit | grep -q .; then
    fail "failed transaction published runtime archives"
  fi

  prepare_fixture "success"
  printf '0\n' > "${curl_counter}"
  if updateCommonRuntimeBundle; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "0" "successful runtime transaction status"
  target_count=0
  while IFS= read -r target; do
    target_count=$((target_count + 1))
    grep -q '^# cnode-runtime-version=2$' "${target}" ||
      fail "successful transaction omitted $(basename "${target}")"
    find "${target}" -prune -perm 0644 -print -quit | grep -q . ||
      fail "successful transaction used the wrong mode for ${target}"
  done < <(runtime_paths)
  assert_eq "${target_count}" "6" "installed common runtime member count"
  grep -q '^UPDATE_CHECK="N" # cnode-runtime-user-setting$' \
    "${node_root}/scripts/env" ||
    fail "runtime transaction did not preserve the env user header"
  assert_eq \
    "$(find "${node_root}/scripts/archive" -type f | wc -l | tr -d '[:space:]')" \
    "6" \
    "successful runtime archive count"
  assert_no_transaction_artifacts "successful transaction"
)

run_install_order_test() {
  local deploy_file="${REPO_ROOT}/scripts/cnode-helper-scripts/deploy-cnode.sh"
  local runtime_line dependent_line blockperf_line logmonitor_line retirement_line

  runtime_line="$(
    grep -n '^[[:space:]]*updateCommonRuntimeBundle ||' "${deploy_file}" |
      head -1 | cut -d: -f1
  )"
  dependent_line="$(
    grep -n 'updateWithCustomConfig "cntools.sh"' "${deploy_file}" |
      head -1 | cut -d: -f1
  )"
  blockperf_line="$(
    grep -n '^[[:space:]]*updateWithCustomConfig "blockPerf.sh"' "${deploy_file}" |
      head -1 | cut -d: -f1
  )"
  logmonitor_line="$(
    grep -n '^[[:space:]]*updateWithCustomConfig "logMonitor.sh"' "${deploy_file}" |
      head -1 | cut -d: -f1
  )"
  retirement_line="$(
    grep -n '^[[:space:]]*retire_legacy_systemd_orchestrator$' "${deploy_file}" |
      head -1 | cut -d: -f1
  )"
  [[ -n "${runtime_line}" && -n "${dependent_line}" &&
     -n "${blockperf_line}" && -n "${logmonitor_line}" &&
     -n "${retirement_line}" ]] ||
    fail "could not locate cnode runtime/dependent installation calls"
  (( runtime_line < dependent_line )) ||
    fail "common runtime is not installed before dependent common scripts"
  (( blockperf_line < retirement_line && logmonitor_line < retirement_line )) ||
    fail "legacy systemd orchestrator is retired before every replacement component refreshes"
  if grep -q 'updateWithCustomConfig "env"' "${deploy_file}"; then
    fail "env is still installed outside the common runtime transaction"
  fi
}

run_legacy_orchestrator_retirement_test() (
  local node_root="${TEST_ROOT}/legacy-systemd-orchestrator"
  local legacy_script="${node_root}/scripts/deploy-as-systemd.sh"
  local archived_script

  mkdir -p "${node_root}/scripts/archive"
  printf '%s\n' '#!/usr/bin/env bash' '# retired orchestrator fixture' \
    > "${legacy_script}"
  NODE_HOME="${node_root}"

  retire_legacy_systemd_orchestrator >/dev/null

  [[ ! -e "${legacy_script}" ]] ||
    fail "retired deploy-as-systemd.sh remained in the active scripts folder"
  archived_script="$(
    find "${node_root}/scripts/archive" -type f \
      -name 'deploy-as-systemd.sh_deprecated_*' -print -quit
  )"
  [[ -n "${archived_script}" ]] ||
    fail "retired deploy-as-systemd.sh was not archived"
  grep -q '^# retired orchestrator fixture$' "${archived_script}" ||
    fail "archived deploy-as-systemd.sh did not preserve its content"
)

run_profile_state_test
run_initial_port_seed_test
run_release_metadata_test
run_release_manifest_validation_tests
run_release_resolver_tests
run_binary_staging_test
run_hardware_wallet_rule_policy_test
run_managed_installer_policy_test
run_source_checkout_test
run_transaction_tests
run_install_order_test
run_legacy_orchestrator_retirement_test

printf 'cnode runtime transaction tests passed\n'
