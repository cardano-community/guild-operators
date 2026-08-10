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
done

jq -e '
    .schemaVersion == 1 and
    .implementation == "cnode" and
    (.version |
      type == "string" and
      test("^[0-9]+([.][0-9]+){1,3}([+-][A-Za-z0-9.-]+)?$")) and
    (.artifacts | keys == ["linux-aarch64", "linux-x86_64"]) and
    all(.artifacts[];
      keys == ["sha256", "url"] and
      (.url | type == "string" and startswith("https://")) and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    )
  ' "${ROOT_DIR}/files/node-implementations/cnode/release.json" >/dev/null ||
    fail "invalid cnode release metadata"

for implementation in dingo amaru; do
  release_file="${ROOT_DIR}/files/node-implementations/${implementation}/release.json"
  jq -e --arg implementation "${implementation}" '
    .schemaVersion == 1 and
    .implementation == $implementation and
    .version == "latest" and
    (.github | type == "string" and
      test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
    (.assets | keys == ["linux-aarch64", "linux-x86_64"]) and
    all(.assets[];
      type == "string" and
      length > 0 and
      (test("[[:space:]]") | not)
    ) and
    (has("artifacts") | not)
  ' "${release_file}" >/dev/null ||
    fail "invalid rolling ${implementation} release metadata"
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

for profile in \
  "${ROOT_DIR}/scripts/cnode-helper-scripts/deploy-cnode.sh" \
  "${ROOT_DIR}/scripts/dingo-helper-scripts/deploy-dingo.sh" \
  "${ROOT_DIR}/scripts/amaru-helper-scripts/deploy-amaru.sh"; do
  grep -q 'dispatcher_run_package_command' "${profile}" ||
    fail "$(basename "${profile}") bypasses compact package-manager output"
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

(
  # shellcheck source=../../scripts/dingo-helper-scripts/deploy-dingo.sh
  . "${ROOT_DIR}/scripts/dingo-helper-scripts/deploy-dingo.sh"
  dingo_deploy_validate_release_metadata \
    "${ROOT_DIR}/files/node-implementations/dingo/release.json"
) || fail "runtime validator rejected compact Dingo release metadata"

(
  # shellcheck source=../../scripts/amaru-helper-scripts/deploy-amaru.sh
  . "${ROOT_DIR}/scripts/amaru-helper-scripts/deploy-amaru.sh"
  amaru_deploy_validate_release_metadata \
    "${ROOT_DIR}/files/node-implementations/amaru/release.json"
) || fail "runtime validator rejected compact Amaru release metadata"

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

  NETWORK="preview"
  request_log="$(mktemp "${TMPDIR:-/tmp}/cnode-config-requests.XXXXXX")"
  output_file="$(mktemp "${TMPDIR:-/tmp}/cnode-config-output.XXXXXX")"
  trap 'rm -f -- "${request_log}" "${output_file}"' EXIT

  dispatcher_source_copy() {
    local relative_path="$1"
    local destination="$2"
    printf '%s\n' "${relative_path}" >> "${request_log}"
    cp -- "${ROOT_DIR}/${relative_path}" "${destination}"
  }

  cnode_deploy_fetch_network_config "config.json" "${output_file}" ||
    fail "canonical cnode configuration fetch failed"
  [[ "$(wc -l < "${request_log}" | tr -d '[:space:]')" == "1" ]] ||
    fail "cnode configuration fetch made more than one request"
  grep -q '^files/configs/cnode/preview/config.json$' \
    "${request_log}" ||
    fail "cnode configuration request used the wrong snapshot path"
  cmp -s "${ROOT_DIR}/files/configs/cnode/preview/config.json" \
    "${output_file}" ||
    fail "cnode configuration fetch did not copy the snapshot payload"
)

layout_expected_relative_paths() {
  case "$1" in
    cnode)
      printf '%s\n' \
        . files db guild-db logs scripts scripts/adapters scripts/archive \
        scripts/lib sockets priv mithril mithril/data-stores
      ;;
    dingo)
      printf '%s\n' \
        . db files logs priv priv/pool snapshots sockets scripts \
        scripts/adapters scripts/archive scripts/lib
      ;;
    amaru)
      printf '%s\n' \
        . files logs runtime snapshots scripts scripts/adapters \
        scripts/archive scripts/lib
      ;;
    *) return 1 ;;
  esac
}

layout_profile_path() {
  case "$1" in
    cnode) printf '%s\n' "${ROOT_DIR}/scripts/cnode-helper-scripts/deploy-cnode.sh" ;;
    dingo) printf '%s\n' "${ROOT_DIR}/scripts/dingo-helper-scripts/deploy-dingo.sh" ;;
    amaru) printf '%s\n' "${ROOT_DIR}/scripts/amaru-helper-scripts/deploy-amaru.sh" ;;
    *) return 1 ;;
  esac
}

layout_owner_mode() {
  stat -c '%u:%g:%a' "$1" 2>/dev/null || stat -f '%u:%g:%Lp' "$1"
}

layout_external_tree() {
  find "$1" -mindepth 1 -print | LC_ALL=C sort
}

LAYOUT_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-layout-contract.XXXXXX")"
trap 'rm -rf -- "${LAYOUT_TEST_ROOT}"' EXIT

# Every profile directory is security-sensitive at setup time: a symlink at a
# parent (for example scripts) is just as dangerous as one at a private leaf.
# Exercise the exact contract table for every implementation. The privilege
# callback must remain untouched, proving preflight aborts before mkdir, chown,
# or chmod, while the external referent's metadata and contents remain stable.
for implementation in cnode dingo amaru; do
  while IFS= read -r relative_path; do
    [[ -n "${relative_path}" ]] || continue
    case_name="${relative_path//\//_}"
    [[ "${case_name}" != "." ]] || case_name="node-home"
    case_root="${LAYOUT_TEST_ROOT}/${implementation}-${case_name}"
    node_home="${case_root}/node"
    external_dir="${case_root}/external"
    runner_log="${case_root}/privileged.log"
    profile_path="$(layout_profile_path "${implementation}")"
    mkdir -p "${case_root}" "${external_dir}"
    chmod 0777 "${external_dir}"
    printf 'external-layout-marker\n' > "${external_dir}/marker"
    : > "${runner_log}"

    if [[ "${relative_path}" == "." ]]; then
      ln -s "${external_dir}" "${node_home}"
    else
      mkdir -p "${node_home}"
      relative_parent="${relative_path%/*}"
      if [[ "${relative_parent}" != "${relative_path}" ]]; then
        mkdir -p "${node_home}/${relative_parent}"
      fi
      ln -s "${external_dir}" "${node_home}/${relative_path}"
    fi
    external_owner_mode_before="$(layout_owner_mode "${external_dir}")"
    external_tree_before="$(layout_external_tree "${external_dir}")"

    if (
      # shellcheck source=../../scripts/cnode-helper-scripts/guild-deploy.sh
      . "${ROOT_DIR}/scripts/cnode-helper-scripts/guild-deploy.sh"
      # shellcheck source=/dev/null
      . "${profile_path}"
      NODE_IMPLEMENTATION="${implementation}"
      NODE_HOME="${node_home}"
      SUDO="N"
      sudo=""
      U_ID="$(id -u)"
      G_ID="$(id -g)"

      layout_test_privileged() {
        printf '%s\n' "$*" >> "${runner_log}"
        case "$1" in
          chown) return 0 ;;
          *) command "$@" ;;
        esac
      }
      case "${implementation}" in
        cnode)
          cnode_deploy_privileged() { layout_test_privileged "$@"; }
          cnode_deploy_prepare_layout
          ;;
        dingo)
          dingo_deploy_privileged() { layout_test_privileged "$@"; }
          dingo_deploy_prepare_layout
          ;;
        amaru)
          amaru_deploy_privileged() { layout_test_privileged "$@"; }
          amaru_deploy_prepare_layout
          ;;
      esac
    ) >/dev/null 2>&1; then
      fail "${implementation} accepted symlinked layout path ${relative_path}"
    fi

    [[ ! -s "${runner_log}" ]] ||
      fail "${implementation} performed privileged layout mutation after rejecting ${relative_path}"
    [[ "$(layout_owner_mode "${external_dir}")" == "${external_owner_mode_before}" ]] ||
      fail "${implementation} changed external owner/mode through ${relative_path}"
    [[ "$(layout_external_tree "${external_dir}")" == "${external_tree_before}" ]] ||
      fail "${implementation} changed external directory contents through ${relative_path}"
    [[ "$(cat "${external_dir}/marker")" == "external-layout-marker" ]] ||
      fail "${implementation} changed external marker through ${relative_path}"
  done < <(layout_expected_relative_paths "${implementation}")
done

# Fresh creation and partial-layout migration use the same parent-first helper.
# Recreate one removed leaf on the second pass while retaining an operator file
# in an existing directory.
for implementation in cnode dingo amaru; do
  case_root="${LAYOUT_TEST_ROOT}/${implementation}-normal"
  node_home="${case_root}/node"
  runner_log="${case_root}/privileged.log"
  profile_path="$(layout_profile_path "${implementation}")"
  mkdir -p "${case_root}"
  : > "${runner_log}"

  for layout_pass in fresh migration; do
    if [[ "${layout_pass}" == "migration" ]]; then
      printf 'operator-data\n' > "${node_home}/files/operator-marker"
      case "${implementation}" in
        cnode) rmdir "${node_home}/mithril/data-stores" ;;
        dingo) rmdir "${node_home}/priv/pool" ;;
        amaru) rmdir "${node_home}/runtime" ;;
      esac
    fi

    (
      # shellcheck source=../../scripts/cnode-helper-scripts/guild-deploy.sh
      . "${ROOT_DIR}/scripts/cnode-helper-scripts/guild-deploy.sh"
      # shellcheck source=/dev/null
      . "${profile_path}"
      NODE_IMPLEMENTATION="${implementation}"
      NODE_HOME="${node_home}"
      SUDO="N"
      sudo=""
      U_ID="$(id -u)"
      G_ID="$(id -g)"

      layout_test_privileged() {
        printf '%s\n' "$*" >> "${runner_log}"
        case "$1" in
          chown) return 0 ;;
          *) command "$@" ;;
        esac
      }
      case "${implementation}" in
        cnode)
          cnode_deploy_privileged() { layout_test_privileged "$@"; }
          cnode_deploy_prepare_layout
          ;;
        dingo)
          dingo_deploy_privileged() { layout_test_privileged "$@"; }
          dingo_deploy_prepare_layout
          ;;
        amaru)
          amaru_deploy_privileged() { layout_test_privileged "$@"; }
          amaru_deploy_prepare_layout
          ;;
      esac
      dispatcher_validate_profile_layout
    ) >/dev/null || fail "${implementation} ${layout_pass} layout setup failed"

    while IFS= read -r relative_path; do
      [[ -n "${relative_path}" ]] || continue
      if [[ "${relative_path}" == "." ]]; then
        layout_path="${node_home}"
      else
        layout_path="${node_home}/${relative_path}"
      fi
      [[ -d "${layout_path}" && ! -L "${layout_path}" ]] ||
        fail "${implementation} ${layout_pass} layout omitted ${relative_path}"
    done < <(layout_expected_relative_paths "${implementation}")
  done

  [[ "$(cat "${node_home}/files/operator-marker")" == "operator-data" ]] ||
    fail "${implementation} migration did not preserve existing operator data"
  grep -q '^mkdir ' "${runner_log}" ||
    fail "${implementation} layout helper did not create missing directories"
  grep -q '^chown ' "${runner_log}" ||
    fail "${implementation} layout helper did not reach validated ownership setup"
done

GLIVEVIEW="${ROOT_DIR}/scripts/common-helper-scripts/gLiveView.sh"
grep -Fq 'tip_gap "Tip gap" "slots"' "${GLIVEVIEW}" ||
  fail "gLiveView does not render the normalized Tip gap in the chain grid"
if grep -Eq 'Tip [(](ref|diff)[)]' "${GLIVEVIEW}"; then
  fail "gLiveView still renders the retired Tip ref/diff fields"
fi
grep -Fq 'glvRenderNetworkPage' "${GLIVEVIEW}" ||
  fail "gLiveView does not provide the Network details page"
grep -Fq 'glvRenderProducerMetrics' "${GLIVEVIEW}" ||
  fail "gLiveView does not provide the shared producer metrics section"
grep -Fq 'glvMetricGrid "BLOCK PRODUCTION"' "${GLIVEVIEW}" ||
  fail "gLiveView does not render normalized block-production metrics"
grep -Fq '[n] Network' "${GLIVEVIEW}" ||
  fail "gLiveView does not advertise the Network page shortcut"
grep -Fq \
  'https://cardano-community.github.io/guild-operators/Scripts/gliveview' \
  "${GLIVEVIEW}" ||
  fail "gLiveView built-in information does not link to the detailed guide"

GLIVEVIEW_DOCS="${ROOT_DIR}/docs/Scripts/gliveview.md"
for documentation_heading in \
  '## Common live sections' \
  '### cardano-node / cnode' \
  '### Dingo' \
  '### Amaru'; do
  grep -Fq "${documentation_heading}" "${GLIVEVIEW_DOCS}" ||
    fail "gLiveView documentation is missing ${documentation_heading}"
done
for documented_metric in \
  'Tip gap' 'Disk util' 'OpCert starts / expires' \
  'Goroutines' 'Forge validation' 'Replay err' \
  'Process CPU' 'Mempool rejected' 'Fetch wait'; do
  grep -Fq "| ${documented_metric} |" "${GLIVEVIEW_DOCS}" ||
    fail "gLiveView documentation is missing metric: ${documented_metric}"
done
if grep -Eq '^!\[' "${GLIVEVIEW_DOCS}"; then
  fail "gLiveView documentation contains a dashboard image that can drift"
fi

printf 'deployment layout tests passed\n'
