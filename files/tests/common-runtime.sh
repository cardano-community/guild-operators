#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2012,SC2016,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-common-runtime.XXXXXX")"

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
  local context="${3:-values differ}"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${context}: expected '${expected}', got '${actual}'"
}

assert_file_unchanged() {
  local file="$1"
  local expected="$2"
  local context="$3"
  assert_eq "$(cat "${file}")" "${expected}" "${context}"
}

write_deployment_manifest() {
  local node_root="$1"
  local implementation="$2"
  local network="$3"
  local branch="$4"
  local service_name

  service_name="$(basename "${node_root}" | tr '[:upper:]' '[:lower:]')"
  jq -n \
    --arg implementation "${implementation}" \
    --arg network "${network}" \
    --arg branch "${branch}" \
    --arg service_name "${service_name}" \
    '{
      schemaVersion: 1,
      deploymentStatus: "deployed",
      implementation: $implementation,
      network: $network,
      branch: $branch,
      repository: "cardano-community/guild-operators",
      serviceName: $service_name,
      nodeVersion: "",
      targetNodeVersion: "test-target",
      metricsProvider: (if $implementation == "amaru" then "otel" else "prometheus" end),
      capabilities: {
        n2c: ($implementation != "amaru"),
        localCli: ($implementation == "cnode"),
        metrics: true,
        forging: ($implementation == "cnode")
      }
    }' > "${node_root}/.deployment.json"
}

for required_command in awk find jq sha256sum; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

run_manifest_tests() (
  local node_root="${TEST_ROOT}/runtime-test"
  local manifest="${node_root}/.deployment.json"
  local inode_before inode_after valid_content invalid
  mkdir -p "${node_root}"

  jq -n '{
    schemaVersion: 1,
    deploymentStatus: "deployed",
    implementation: "dingo",
    network: "preprod",
    branch: "alpha",
    repository: "cardano-community/guild-operators",
    serviceName: "runtime-test",
    nodeVersion: "",
    targetNodeVersion: "test-target",
    metricsProvider: "prometheus",
    capabilities: {
      n2c: true,
      localCli: false,
      metrics: true,
      forging: false
    },
    preserved: {
      string: "keep-me",
      list: [1, 2, 3]
    }
  }' > "${manifest}"

  NODE_HOME="${node_root}"
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"
  deployment_branch_exists() {
    [[ "${1:-}" == "feature/common-runtime" ]]
  }

  assert_eq "$(deployment_get implementation)" "dingo" "implementation read"
  assert_eq "$(deployment_get network)" "preprod" "network read"
  assert_eq "$(deployment_get branch)" "alpha" "branch read"
  assert_eq "$(deployment_get capabilities.n2c)" "true" "nested boolean read"
  jq -e '.n2c == true and .forging == false' \
    <<< "$(deployment_get capabilities)" >/dev/null ||
    fail "object-valued deployment_get result was invalid"
  if deployment_get missing.key >/dev/null 2>&1; then
    fail "deployment_get unexpectedly found a missing key"
  fi

  inode_before="$(ls -di "${manifest}" | awk '{print $1}')"
  deployment_set_branch "feature/common-runtime"
  inode_after="$(ls -di "${manifest}" | awk '{print $1}')"
  [[ "${inode_before}" != "${inode_after}" ]] ||
    fail "branch update did not atomically replace the manifest"

  assert_eq "$(deployment_get branch)" "feature/common-runtime" "updated branch"
  jq -e '
    .schemaVersion == 1 and
    .deploymentStatus == "deployed" and
    .implementation == "dingo" and
    .network == "preprod" and
    .serviceName == "runtime-test" and
    .metricsProvider == "prometheus" and
    .capabilities.n2c == true and
    .capabilities.forging == false and
    .preserved.string == "keep-me" and
    .preserved.list == [1, 2, 3]
  ' "${manifest}" >/dev/null || fail "branch update did not preserve manifest fields"
  if find "${node_root}" -maxdepth 1 -name '.deployment.json.tmp.*' -print -quit |
     grep -q .; then
    fail "branch update left a staged manifest behind"
  fi

  valid_content="$(cat "${manifest}")"
  if deployment_set_branch "feature/not-on-remote" >/dev/null 2>&1; then
    fail "branch update accepted a branch rejected by the remote validator"
  fi
  assert_file_unchanged "${manifest}" "${valid_content}" \
    "remote branch rejection changed the manifest"

  for invalid in \
    "" \
    "../unsafe" \
    "/absolute" \
    "trailing/" \
    "double//slash" \
    "bad branch" \
    "ref.lock"; do
    if deployment_set_branch "${invalid}" >/dev/null 2>&1; then
      fail "invalid branch was accepted: '${invalid}'"
    fi
    assert_file_unchanged "${manifest}" "${valid_content}" \
      "invalid branch changed the manifest"
  done
)

run_missing_and_malformed_manifest_tests() (
  local node_root="${TEST_ROOT}/manifest-invalid"
  local manifest="${node_root}/.deployment.json"
  local malformed incomplete
  mkdir -p "${node_root}"

  NODE_HOME="${node_root}"
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"

  if deployment_set_branch "alpha" >/dev/null 2>&1; then
    fail "branch update created a missing deployment manifest"
  fi
  [[ ! -e "${manifest}" ]] ||
    fail "missing-manifest branch update created ${manifest}"

  printf '%s\n' '{"schemaVersion": 1, broken-json' > "${manifest}"
  malformed="$(cat "${manifest}")"
  if deployment_set_branch "alpha" >/dev/null 2>&1; then
    fail "branch update accepted malformed JSON"
  fi
  assert_file_unchanged "${manifest}" "${malformed}" \
    "malformed manifest was modified"

  jq -n '{
    schemaVersion: 1,
    implementation: "cnode",
    branch: "master"
  }' > "${manifest}"
  incomplete="$(cat "${manifest}")"
  if deployment_set_branch "alpha" >/dev/null 2>&1; then
    fail "branch update accepted a manifest without network metadata"
  fi
  assert_file_unchanged "${manifest}" "${incomplete}" \
    "incomplete manifest was modified"

  for invalid_identity in \
    '{"implementation":"dingo","network":"mainnet","serviceName":"manifest-invalid"}' \
    '{"implementation":"dingo","network":"preprod","serviceName":"another-service"}'; do
    jq -n --argjson identity "${invalid_identity}" '
      {
        schemaVersion: 1,
        deploymentStatus: "deployed",
        branch: "master",
        repository: "cardano-community/guild-operators",
        nodeVersion: "",
        targetNodeVersion: "test-target",
        metricsProvider: "prometheus",
        capabilities: {
          n2c: true,
          localCli: false,
          metrics: true,
          forging: false
        }
      } + $identity
    ' > "${manifest}"
    incomplete="$(cat "${manifest}")"
    if deployment_set_branch "alpha" >/dev/null 2>&1; then
      fail "branch update accepted an invalid implementation/network or service identity"
    fi
    assert_file_unchanged "${manifest}" "${incomplete}" \
      "identity rejection changed the manifest"
  done

  if find "${node_root}" -maxdepth 1 -name '.deployment.json.tmp.*' -print -quit |
     grep -q .; then
    fail "rejected manifest update left a staged file behind"
  fi
)

install_runtime_fixture() {
  local implementation="$1"
  local network="$2"
  local metrics_provider="$3"
  local node_root="${TEST_ROOT}/runtime-${implementation}"
  mkdir -p "${node_root}/scripts/lib" "${node_root}/scripts/adapters"

  cp "${REPO_ROOT}/scripts/common-helper-scripts/env" \
    "${node_root}/scripts/env"
  cp "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library" \
    "${node_root}/scripts/lib/"
  cp "${REPO_ROOT}/scripts/${implementation}-helper-scripts/${implementation}.adapter" \
    "${node_root}/scripts/adapters/${implementation}.adapter"

  jq -n \
    --arg implementation "${implementation}" \
    --arg network "${network}" \
    --arg service "runtime-${implementation}" \
    --arg metrics_provider "${metrics_provider}" \
    '{
      schemaVersion: 1,
      deploymentStatus: "deployed",
      implementation: $implementation,
      network: $network,
      branch: "test/common-runtime",
      repository: "cardano-community/guild-operators",
      serviceName: $service,
      nodeVersion: "",
      targetNodeVersion: "test-target",
      metricsProvider: $metrics_provider,
      capabilities: {
        n2c: ($implementation != "amaru"),
        localCli: ($implementation == "cnode"),
        metrics: true,
        forging: ($implementation == "cnode")
      }
    }' > "${node_root}/.deployment.json"
}

run_adapter_case() (
  local implementation="$1"
  local expected_network="$2"
  local expected_metrics_provider="$3"
  local expected_capability="$4"
  local node_root="${TEST_ROOT}/runtime-${implementation}"

  unset BRANCH CNODE_HOME GUILD_ENV_ENTRY_DIR GUILD_NODE_IMPLEMENTATION_OVERRIDE
  unset GUILD_NODE_NETWORK_OVERRIDE GUILD_NODE_SERVICE_OVERRIDE NODE_ADAPTER_PATH
  unset NODE_IMPLEMENTATION NODE_IMPL NODE_NETWORK NODE_SERVICE
  NODE_HOME="${TEST_ROOT}/hostile-node-home"
  CNODE_HOME="${TEST_ROOT}/hostile-cnode-home"
  TMP_DIR="${node_root}/tmp"
  USESYSVARS="N"

  set +u
  if ! . "${node_root}/scripts/env" definitions; then
    set -u
    fail "definitions load failed for ${implementation}"
  fi
  set -u

  assert_eq "${NODE_HOME}" "$(cd "${node_root}" && pwd -P)" \
    "${implementation} ignored script-derived NODE_HOME"
  assert_eq "${CNODE_HOME}" "${NODE_HOME}" \
    "${implementation} retained hostile CNODE_HOME"
  assert_eq "${NODE_IMPLEMENTATION}" "${implementation}" \
    "${implementation} implementation selection"
  assert_eq "${NODE_ADAPTER_IMPLEMENTATION}" "${implementation}" \
    "${implementation} adapter declaration"
  assert_eq "${NODE_NETWORK}" "${expected_network}" \
    "${implementation} network metadata"
  assert_eq "${NODE_SERVICE}" "runtime-${implementation}" \
    "${implementation} service metadata"
  assert_eq "${NODE_METRICS_PROVIDER}" "${expected_metrics_provider}" \
    "${implementation} metrics provider metadata"
  assert_eq "${BRANCH}" "test/common-runtime" \
    "${implementation} branch metadata"
  assert_eq "${DEPLOYMENT_SCHEMA_VERSION}" "1" \
    "${implementation} schema metadata"

  declare -F node_adapter_defaults >/dev/null ||
    fail "${implementation} adapter lacks node_adapter_defaults"
  declare -F node_adapter_init >/dev/null ||
    fail "${implementation} adapter lacks node_adapter_init"
  node_adapter_contract_valid ||
    fail "${implementation} adapter contract validation failed"
  node_has "${expected_capability}" ||
    fail "${implementation} adapter lacks expected capability ${expected_capability}"
  if [[ "${implementation}" == "dingo" ]] &&
     { node_has local_query || node_has local_submit; }; then
    fail "dingo adapter exposed unverified cardano-cli capabilities"
  fi
  jq -e 'type == "object" and has("n2c") and has("metrics")' \
    <<< "${NODE_DEPLOYMENT_CAPABILITIES}" >/dev/null ||
    fail "${implementation} deployment capabilities were not loaded"
)

run_env_manifest_fail_closed_tests() (
  local node_root="${TEST_ROOT}/runtime-cnode"
  local manifest="${node_root}/.deployment.json"
  local valid_manifest
  local invalid_case
  valid_manifest="$(cat "${manifest}")"

  for invalid_case in malformed missing-schema future-schema deploying incomplete wrong-service bad-network; do
    case "${invalid_case}" in
      malformed)
        printf '%s\n' '{"schemaVersion": 1, broken-json' > "${manifest}"
        ;;
      missing-schema)
        jq 'del(.schemaVersion)' <<< "${valid_manifest}" > "${manifest}"
        ;;
      future-schema)
        jq '.schemaVersion = 2' <<< "${valid_manifest}" > "${manifest}"
        ;;
      deploying)
        jq '.deploymentStatus = "deploying"' <<< "${valid_manifest}" > "${manifest}"
        ;;
      incomplete)
        jq 'del(.repository, .capabilities.metrics)' <<< "${valid_manifest}" > "${manifest}"
        ;;
      wrong-service)
        jq '.serviceName = "another-node"' <<< "${valid_manifest}" > "${manifest}"
        ;;
      bad-network)
        jq '.network = "unsupported-network"' <<< "${valid_manifest}" > "${manifest}"
        ;;
    esac

    if (
      unset BRANCH CNODE_HOME GUILD_ENV_ENTRY_DIR
      unset GUILD_NODE_IMPLEMENTATION_OVERRIDE GUILD_NODE_NETWORK_OVERRIDE
      unset GUILD_NODE_SERVICE_OVERRIDE NODE_ADAPTER_PATH NODE_IMPLEMENTATION
      USESYSVARS="N"
      # shellcheck source=/dev/null
      . "${node_root}/scripts/env" definitions
    ) >/dev/null 2>&1; then
      fail "common env accepted ${invalid_case} deployment metadata"
    fi
  done
  printf '%s\n' "${valid_manifest}" > "${manifest}"
)

run_exponent_tests() (
  local normalized stream labelled_metrics
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library"

  assert_eq "$(prometheus_normalize_number '7.6137225e+07')" "76137225" \
    "positive exponent normalization"
  assert_eq "$(prometheus_normalize_number '1E3')" "1000" \
    "uppercase exponent normalization"
  assert_eq "$(prometheus_normalize_number '1e-3')" "0.001" \
    "negative exponent normalization"
  assert_eq "$(prometheus_normalize_number '-2.50E+2')" "-250" \
    "signed exponent normalization"
  assert_eq "$(prometheus_normalize_number '.5e1')" "5" \
    "leading-decimal exponent normalization"
  assert_eq "$(prometheus_normalize_number 'NaN')" "NaN" \
    "non-finite value preservation"
  assert_eq "$(node_epoch_progress_percent 159521 432000)" "36.9" \
    "epoch progress calculation"
  assert_eq "$(node_epoch_progress_percent 500000 432000)" "100.0" \
    "epoch progress upper bound"
  if node_epoch_progress_percent 1 0 >/dev/null 2>&1; then
    fail "epoch progress accepted a zero epoch length"
  fi
  if node_epoch_progress_percent invalid 432000 >/dev/null 2>&1; then
    fail "epoch progress accepted a non-numeric epoch slot"
  fi

  normalized="$(prometheus_normalize_number '7.6137225e+07')"
  (( normalized + 1 == 76137226 )) ||
    fail "normalized exponent was not safe for Bash arithmetic"

  stream="$(
    printf '%s\n' \
      '# HELP slot current slot' \
      'cardano_node_metrics_slotNum_int 7.6137225e+07' \
      'with_timestamp 1.25E+2 1710000000000' |
      prometheus_normalize_metrics
  )"
  grep -q '^# HELP slot current slot$' <<< "${stream}" ||
    fail "metrics stream normalization dropped comments"
  grep -q '^cardano_node_metrics_slotNum_int 76137225$' <<< "${stream}" ||
    fail "metrics stream exponent normalization failed"
  grep -q '^with_timestamp 125 1710000000000$' <<< "${stream}" ||
    fail "metrics stream timestamp handling failed"

  if (( BASH_VERSINFO[0] >= 4 )); then
    labelled_metrics='
cardano_node_metrics_blockNum_int{network="preview"} 123
cardano_node_metrics_slotNum_int{network="preview"} 7.6137225e+07
cardano_node_metrics_forks_int{network="preview"} NaN
cardano_node_metrics_cardano_build_info{revision="abcdef012345",version="9.9.9"} 1
'
    node_metric_reset_availability
    common_parse_cardano_metrics "${labelled_metrics}"
    assert_eq "${blocknum}" "123" "labelled block metric"
    assert_eq "${slotnum}" "76137225" "labelled exponent metric"
    assert_eq "${running_node_version}" "9.9.9" "build-info version label"
    assert_eq "${running_node_rev}" "abcdef01" "build-info revision label"
    node_metric_has blocknum ||
      fail "observed labelled metric was marked unavailable"
    node_metric_has epochnum &&
      fail "missing metric was marked available"
    assert_eq "${epochnum}" "0" "missing metric safe default"
    node_metric_has forks &&
      fail "non-finite metric was allowed into the arithmetic interface"

    node_metric_set_custom test_metric 42 "Test metric" "units"
    assert_eq "${NODE_CUSTOM_METRICS[*]}" "test_metric" \
      "custom metric registration"
    node_metric_reset_availability
    assert_eq "${#NODE_CUSTOM_METRICS[@]}" "0" \
      "custom metrics were not reset between scrapes"
  fi
)

run_exact_update_tests() (
  local update_root="${TEST_ROOT}/exact-update"
  local fake_bin="${update_root}/bin"
  local node_root="${update_root}/node"
  local target="${update_root}/immutable.library"
  local installed="${update_root}/new.adapter"
  local remote="${update_root}/remote"
  local inode_before inode_after update_status
  mkdir -p "${fake_bin}" "${node_root}"

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
    '[[ -n "${output}" ]]' \
    'if [[ "${FAKE_CURL_FAIL_LICENSE:-N}" == "Y" && "${url}" == */LICENSE ]]; then' \
    '  exit 22' \
    'fi' \
    'if [[ -n "${FAKE_CURL_EXPECT_FRAGMENT:-}" && "${url}" != *"${FAKE_CURL_EXPECT_FRAGMENT}"* ]]; then' \
    '  exit 23' \
    'fi' \
    'if [[ -n "${FAKE_CURL_SOURCE:-}" ]]; then' \
    '  cp -- "${FAKE_CURL_SOURCE}" "${output}"' \
    'else' \
    '  relative="${url#*/scripts/}"' \
    '  cp -- "${FAKE_CURL_ROOT}/${relative}" "${output}"' \
    'fi' \
    > "${fake_bin}/curl"
  chmod 0755 "${fake_bin}/curl"

  printf '%s\n' '# immutable runtime' 'version=1' > "${remote}"
  cp "${remote}" "${target}"
  chmod 0644 "${target}"

  PATH="${fake_bin}:${PATH}"
  export PATH
  FAKE_CURL_SOURCE="${remote}"
  export FAKE_CURL_SOURCE
  UPDATE_CHECK=Y
  OFFLINE_MODE=N
  NODE_HOME="${node_root}"
  BRANCH=master
  URL_RAW="https://invalid.example/common-runtime"
  CURL_TIMEOUT=1
  FG_YELLOW=""
  NC=""
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library"
  assert_eq "${COMMON_RUNTIME_UPDATE_API_VERSION}" "1" \
    "common runtime updater API version"
  declare -F checkCommonRuntimeUpdates >/dev/null ||
    fail "central common runtime updater is unavailable"

  inode_before="$(ls -di "${target}" | awk '{print $1}')"
  if checkUpdate "${target}" N N N "common-helper-scripts/lib" exact; then
    update_status=0
  else
    update_status=$?
  fi
  assert_eq "${update_status}" "0" "identical immutable update status"
  inode_after="$(ls -di "${target}" | awk '{print $1}')"
  assert_eq "${inode_after}" "${inode_before}" \
    "identical immutable update rewrote the target"
  [[ ! -e "${target}.tmp" ]] ||
    fail "identical immutable update left a temporary file"
  if find "${update_root}" -name '.immutable.library.update.*' -print -quit |
     grep -q .; then
    fail "identical immutable update left a unique staging file"
  fi
  [[ ! -d "${update_root}/archive" ]] ||
    fail "identical immutable update created an archive"

  BRANCH="retired-test-branch"
  G_ACCOUNT="bundle-test-account"
  URL_RAW="https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${BRANCH}"
  FAKE_CURL_FAIL_LICENSE=Y
  FAKE_CURL_EXPECT_FRAGMENT="/${G_ACCOUNT}/guild-operators/master/"
  export FAKE_CURL_FAIL_LICENSE FAKE_CURL_EXPECT_FRAGMENT G_ACCOUNT
  if checkUpdate "${target}" N N N "common-helper-scripts/lib" exact; then
    update_status=0
  else
    update_status=$?
  fi
  assert_eq "${update_status}" "0" "legacy dead-branch fallback update status"
  assert_eq "${BRANCH}" "master" "legacy dead-branch fallback branch"
  assert_eq "${URL_RAW}" \
    "https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/master" \
    "legacy dead-branch fallback raw URL"
  unset FAKE_CURL_FAIL_LICENSE FAKE_CURL_EXPECT_FRAGMENT

  BRANCH="retired-test-branch"
  URL_RAW="https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${BRANCH}"
  write_deployment_manifest "${NODE_HOME}" cnode mainnet "${BRANCH}"
  FAKE_CURL_FAIL_LICENSE=Y
  export FAKE_CURL_FAIL_LICENSE
  if checkUpdate "${target}" N N N "common-helper-scripts/lib" exact \
       >/dev/null 2>&1; then
    update_status=0
  else
    update_status=$?
  fi
  assert_eq "${update_status}" "2" \
    "manifest-backed dead-branch update status"
  assert_eq "${BRANCH}" "retired-test-branch" \
    "manifest-backed dead-branch source identity"
  assert_eq "${URL_RAW}" \
    "https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/retired-test-branch" \
    "manifest-backed dead-branch raw URL"
  assert_eq "$(jq -r '.branch' "${NODE_HOME}/.deployment.json")" \
    "retired-test-branch" "manifest-backed update changed deployment metadata"
  assert_file_unchanged "${target}" "$(cat "${remote}")" \
    "manifest-backed dead-branch update changed the target"
  if find "${update_root}" -name '.immutable.library.update.*' -print -quit |
     grep -q .; then
    fail "manifest-backed dead-branch update left a unique staging file"
  fi
  rm -f -- "${NODE_HOME}/.deployment.json"
  unset FAKE_CURL_FAIL_LICENSE

  ln -s "missing-deployment-manifest" "${NODE_HOME}/.deployment.json"
  FAKE_CURL_FAIL_LICENSE=Y
  export FAKE_CURL_FAIL_LICENSE
  if checkUpdate "${target}" N N N "common-helper-scripts/lib" exact \
       >/dev/null 2>&1; then
    update_status=0
  else
    update_status=$?
  fi
  assert_eq "${update_status}" "2" \
    "dangling manifest symlink dead-branch update status"
  assert_eq "${BRANCH}" "retired-test-branch" \
    "dangling manifest symlink changed update source identity"
  [[ -L "${NODE_HOME}/.deployment.json" ]] ||
    fail "dangling manifest symlink was removed by the rejected update"
  rm -f -- "${NODE_HOME}/.deployment.json"
  unset FAKE_CURL_FAIL_LICENSE

  G_ACCOUNT="cardano-community"
  URL_RAW="https://invalid.example/common-runtime"
  export G_ACCOUNT

  FAKE_CURL_SOURCE="${update_root}/missing-download"
  export FAKE_CURL_SOURCE
  if checkUpdate "${target}" Y N N "common-helper-scripts/lib" exact; then
    update_status=0
  else
    update_status=$?
  fi
  assert_eq "${update_status}" "2" "failed immutable download status"
  if find "${update_root}" -name '.immutable.library.update.*' -print -quit |
     grep -q .; then
    fail "failed immutable download left a unique staging file"
  fi
  [[ ! -e "${target}.tmp" ]] ||
    fail "failed immutable download left a fixed temporary file"

  FAKE_CURL_SOURCE="${remote}"
  export FAKE_CURL_SOURCE
  printf '%s\n' '# immutable runtime' 'version=2' > "${remote}"
  if checkUpdate "${target}" Y N N "common-helper-scripts/lib" exact; then
    update_status=0
  else
    update_status=$?
  fi
  assert_eq "${update_status}" "1" "changed immutable update status"
  cmp -s "${target}" "${remote}" ||
    fail "changed immutable update was not copied exactly"
  find "${target}" -prune -perm 0644 -print -quit | grep -q . ||
    fail "changed immutable update did not retain mode 0644"
  find "${update_root}/archive" -maxdepth 1 -type f \
    -name 'immutable.library_bkp*' -print -quit | grep -q . ||
    fail "changed immutable update was not archived"
  if find "${update_root}" -name '.immutable.library.update.*' -print -quit |
     grep -q .; then
    fail "changed immutable update left a unique staging file"
  fi

  if checkUpdate "${installed}" Y N N "cnode-helper-scripts" exact; then
    update_status=0
  else
    update_status=$?
  fi
  assert_eq "${update_status}" "1" "missing immutable install status"
  cmp -s "${installed}" "${remote}" ||
    fail "missing immutable target was not installed exactly"
  find "${installed}" -prune -perm 0644 -print -quit | grep -q . ||
    fail "missing immutable target was not installed with mode 0644"

  local bundle_root="${update_root}/bundle"
  mkdir -p "${bundle_root}/scripts/lib" "${bundle_root}/scripts/adapters"
  cp "${REPO_ROOT}/scripts/common-helper-scripts/env" \
    "${bundle_root}/scripts/env"
  cp "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/systemd.library" \
    "${bundle_root}/scripts/lib/"
  cp "${REPO_ROOT}/scripts/cnode-helper-scripts/cnode.adapter" \
    "${bundle_root}/scripts/adapters/cnode.adapter"
  chmod 0644 \
    "${bundle_root}/scripts/env" \
    "${bundle_root}/scripts/lib/"*.library \
    "${bundle_root}/scripts/adapters/cnode.adapter"

  unset FAKE_CURL_SOURCE
  FAKE_CURL_ROOT="${REPO_ROOT}/scripts"
  export FAKE_CURL_ROOT
  PARENT="${bundle_root}/scripts"
  NODE_HOME="${bundle_root}"
  NODE_IMPLEMENTATION="cnode"
  NODE_ADAPTER_FILE="${bundle_root}/scripts/adapters/cnode.adapter"
  inode_before="$(ls -di "${bundle_root}/scripts/lib/deployment.library" | awk '{print $1}')"
  set +u
  if checkCommonRuntimeUpdates Y; then
    update_status=0
  else
    update_status=$?
  fi
  set -u
  assert_eq "${update_status}" "0" "identical common runtime bundle status"
  inode_after="$(ls -di "${bundle_root}/scripts/lib/deployment.library" | awk '{print $1}')"
  assert_eq "${inode_after}" "${inode_before}" \
    "identical common runtime bundle rewrote an immutable component"
  if find "${bundle_root}/scripts" -type d -name archive -print -quit | grep -q .; then
    fail "identical common runtime bundle created an archive"
  fi
)

run_bundle_transaction_tests() (
  local transaction_root="${TEST_ROOT}/bundle-transactions"
  local fake_bin="${transaction_root}/bin"
  local fake_mv_bin="${transaction_root}/mv-bin"
  local fake_lock_bin="${transaction_root}/lock-bin"
  local real_mv
  local status before after prompt_count target
  local bundle_root remote_root curl_counter prompt_counter mv_counter
  mkdir -p "${fake_bin}" "${fake_mv_bin}" "${fake_lock_bin}"

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
    '[[ -n "${output}" ]]' \
    'if [[ "${FAKE_CURL_FAIL_LICENSE:-N}" == "Y" && "${url}" == */LICENSE ]]; then' \
    '  exit 22' \
    'fi' \
    'if [[ -n "${FAKE_CURL_EXPECT_FRAGMENT:-}" && "${url}" != *"${FAKE_CURL_EXPECT_FRAGMENT}"* ]]; then' \
    '  exit 23' \
    'fi' \
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
    'if [[ -n "${FAKE_MV_SIGNAL_AT:-}" && "${count}" -eq "${FAKE_MV_SIGNAL_AT}" ]]; then' \
    '  "${FAKE_MV_REAL}" "$@"' \
    '  kill -TERM "${PPID}"' \
    '  sleep 0.1' \
    '  exit 0' \
    'fi' \
    'exec "${FAKE_MV_REAL}" "$@"' \
    > "${fake_mv_bin}/mv"
  chmod 0755 "${fake_mv_bin}/mv"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exit 1' \
    > "${fake_lock_bin}/flock"
  chmod 0755 "${fake_lock_bin}/flock"

  bundle_paths() {
    printf '%s\n' \
      "${bundle_root}/scripts/lib/deployment.library" \
      "${bundle_root}/scripts/lib/env.library" \
      "${bundle_root}/scripts/lib/node-api.library" \
      "${bundle_root}/scripts/lib/systemd.library" \
      "${bundle_root}/scripts/adapters/cnode.adapter" \
      "${bundle_root}/scripts/env"
  }

  bundle_snapshot() {
    while IFS= read -r target; do
      printf '%s ' "$(basename "${target}")"
      ls -ld "${target}" | awk '{printf "%s ", $1}'
      sha256sum "${target}" | awk '{print $1}'
    done < <(bundle_paths)
  }

  assert_no_bundle_staging() {
    if find "${bundle_root}/scripts" \
      \( -name '.common-runtime-stage.*' -o \
         -name '.*.commit.*' -o \
         -name '.*.restore.*' -o \
         -name '*.tmp' \) -print -quit | grep -q .; then
      fail "$1 left common runtime staging files"
    fi
  }

  prepare_bundle_fixture() {
    local fixture_name="$1"
    local remote_file env_tmp

    bundle_root="${transaction_root}/${fixture_name}/node"
    remote_root="${transaction_root}/${fixture_name}/remote/scripts"
    curl_counter="${transaction_root}/${fixture_name}/curl.count"
    prompt_counter="${transaction_root}/${fixture_name}/prompt.count"
    mv_counter="${transaction_root}/${fixture_name}/mv.count"

    mkdir -p \
      "${bundle_root}/scripts/lib" \
      "${bundle_root}/scripts/adapters" \
      "${remote_root}/common-helper-scripts/lib" \
      "${remote_root}/common-helper-scripts" \
      "${remote_root}/cnode-helper-scripts"

    cp "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library" \
      "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library" \
      "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library" \
      "${REPO_ROOT}/scripts/common-helper-scripts/lib/systemd.library" \
      "${bundle_root}/scripts/lib/"
    cp "${REPO_ROOT}/scripts/common-helper-scripts/env" \
      "${bundle_root}/scripts/env"
    cp "${REPO_ROOT}/scripts/cnode-helper-scripts/cnode.adapter" \
      "${bundle_root}/scripts/adapters/cnode.adapter"

    cp "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library" \
      "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library" \
      "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library" \
      "${REPO_ROOT}/scripts/common-helper-scripts/lib/systemd.library" \
      "${remote_root}/common-helper-scripts/lib/"
    cp "${REPO_ROOT}/scripts/common-helper-scripts/env" \
      "${remote_root}/common-helper-scripts/env"
    cp "${REPO_ROOT}/scripts/cnode-helper-scripts/cnode.adapter" \
      "${remote_root}/cnode-helper-scripts/cnode.adapter"

    env_tmp="${bundle_root}/scripts/.env-custom"
    sed \
      's/^#UPDATE_CHECK="Y".*/UPDATE_CHECK="N" # bundle-test-user-setting/' \
      "${bundle_root}/scripts/env" > "${env_tmp}"
    mv -f "${env_tmp}" "${bundle_root}/scripts/env"

    while IFS= read -r remote_file; do
      printf '\n# remote-bundle-version=2\n' >> "${remote_file}"
    done <<EOF
${remote_root}/common-helper-scripts/lib/deployment.library
${remote_root}/common-helper-scripts/lib/env.library
${remote_root}/common-helper-scripts/lib/node-api.library
${remote_root}/common-helper-scripts/lib/systemd.library
${remote_root}/cnode-helper-scripts/cnode.adapter
${remote_root}/common-helper-scripts/env
EOF

    chmod 0644 \
      "${bundle_root}/scripts/env" \
      "${bundle_root}/scripts/lib/"*.library \
      "${bundle_root}/scripts/adapters/cnode.adapter" \
      "${remote_root}/common-helper-scripts/env" \
      "${remote_root}/common-helper-scripts/lib/"*.library \
      "${remote_root}/cnode-helper-scripts/cnode.adapter"

    PARENT="${bundle_root}/scripts"
    NODE_HOME="${bundle_root}"
    NODE_IMPLEMENTATION="cnode"
    NODE_ADAPTER_FILE="${bundle_root}/scripts/adapters/cnode.adapter"
    FAKE_CURL_ROOT="${remote_root}"
    FAKE_CURL_COUNTER="${curl_counter}"
    export PARENT NODE_HOME NODE_IMPLEMENTATION NODE_ADAPTER_FILE
    export FAKE_CURL_ROOT FAKE_CURL_COUNTER
  }

  PATH="${fake_bin}:${PATH}"
  export PATH
  UPDATE_CHECK=Y
  OFFLINE_MODE=N
  BRANCH=master
  URL_RAW="https://invalid.example/guild-operators/master"
  CURL_TIMEOUT=1
  FG_YELLOW=""
  NC=""
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library"

  prepare_bundle_fixture "download-failure"
  before="$(bundle_snapshot)"
  printf '0\n' > "${curl_counter}"
  FAKE_CURL_FAIL_AT=3
  export FAKE_CURL_FAIL_AT
  if checkCommonRuntimeUpdates Y; then
    status=0
  else
    status=$?
  fi
  unset FAKE_CURL_FAIL_AT
  assert_eq "${status}" "2" "mid-download bundle failure status"
  after="$(bundle_snapshot)"
  assert_eq "${after}" "${before}" \
    "mid-download bundle failure changed installed members"
  assert_no_bundle_staging "mid-download failure"

  prepare_bundle_fixture "declined"
  before="$(bundle_snapshot)"
  printf '0\n' > "${curl_counter}"
  : > "${prompt_counter}"
  PROMPT_COUNTER="${prompt_counter}"
  export PROMPT_COUNTER
  commonRuntimeIsInteractive() {
    return 0
  }
  getAnswer() {
    printf 'prompt\n' >> "${PROMPT_COUNTER}"
    return 1
  }
  if checkCommonRuntimeUpdates N; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "0" "declined bundle update status"
  prompt_count="$(wc -l < "${prompt_counter}" | tr -d '[:space:]')"
  assert_eq "${prompt_count}" "1" "bundle update prompt count"
  assert_eq "$(cat "${curl_counter}")" "6" \
    "declined bundle did not stage all six members before prompting"
  after="$(bundle_snapshot)"
  assert_eq "${after}" "${before}" \
    "declined bundle update changed installed members"
  assert_no_bundle_staging "declined bundle update"

  prepare_bundle_fixture "commit-failure"
  before="$(bundle_snapshot)"
  printf '0\n' > "${curl_counter}"
  printf '0\n' > "${mv_counter}"
  FAKE_MV_COUNTER="${mv_counter}"
  FAKE_MV_FAIL_AT=2
  FAKE_MV_REAL="${real_mv}"
  export FAKE_MV_COUNTER FAKE_MV_FAIL_AT FAKE_MV_REAL
  PATH="${fake_mv_bin}:${fake_bin}:${PATH#*:}"
  export PATH
  if checkCommonRuntimeUpdates Y; then
    status=0
  else
    status=$?
  fi
  PATH="${fake_bin}:${PATH#*:}"
  export PATH
  assert_eq "${status}" "2" "mid-commit bundle failure status"
  after="$(bundle_snapshot)"
  assert_eq "${after}" "${before}" \
    "mid-commit bundle failure was not rolled back"
  assert_no_bundle_staging "mid-commit failure"

  prepare_bundle_fixture "signal-rollback"
  before="$(bundle_snapshot)"
  printf '0\n' > "${curl_counter}"
  printf '0\n' > "${mv_counter}"
  FAKE_MV_COUNTER="${mv_counter}"
  FAKE_MV_FAIL_AT=999
  FAKE_MV_SIGNAL_AT=2
  FAKE_MV_REAL="${real_mv}"
  export FAKE_MV_COUNTER FAKE_MV_FAIL_AT FAKE_MV_SIGNAL_AT FAKE_MV_REAL
  PATH="${fake_mv_bin}:${fake_bin}:${PATH#*:}"
  export PATH
  if checkCommonRuntimeUpdates Y; then
    status=0
  else
    status=$?
  fi
  PATH="${fake_bin}:${PATH#*:}"
  export PATH
  unset FAKE_MV_SIGNAL_AT
  assert_eq "${status}" "2" "signalled bundle commit status"
  after="$(bundle_snapshot)"
  assert_eq "${after}" "${before}" \
    "signalled bundle commit was not rolled back"
  assert_no_bundle_staging "signalled bundle commit"

  prepare_bundle_fixture "lock-refusal"
  before="$(bundle_snapshot)"
  printf '0\n' > "${curl_counter}"
  PATH="${fake_lock_bin}:${fake_bin}:${PATH#*:}"
  export PATH
  if checkCommonRuntimeUpdates Y; then
    status=0
  else
    status=$?
  fi
  PATH="${fake_bin}:${PATH#*:}"
  export PATH
  assert_eq "${status}" "2" "bundle lock refusal status"
  after="$(bundle_snapshot)"
  assert_eq "${after}" "${before}" \
    "bundle lock refusal changed installed members"
  assert_no_bundle_staging "bundle lock refusal"

  prepare_bundle_fixture "manifest-branch-refusal"
  before="$(bundle_snapshot)"
  printf '0\n' > "${curl_counter}"
  BRANCH="retired-test-branch"
  G_ACCOUNT="bundle-test-account"
  URL_RAW="https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${BRANCH}"
  write_deployment_manifest "${NODE_HOME}" cnode mainnet "${BRANCH}"
  FAKE_CURL_FAIL_LICENSE=Y
  export G_ACCOUNT FAKE_CURL_FAIL_LICENSE
  if checkCommonRuntimeUpdates N >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "2" \
    "manifest-backed bundle dead-branch status"
  assert_eq "${BRANCH}" "retired-test-branch" \
    "manifest-backed bundle source identity"
  assert_eq "${URL_RAW}" \
    "https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/retired-test-branch" \
    "manifest-backed bundle raw URL"
  assert_eq "$(jq -r '.branch' "${NODE_HOME}/.deployment.json")" \
    "retired-test-branch" "manifest-backed bundle changed deployment metadata"
  assert_eq "$(cat "${curl_counter}")" "0" \
    "manifest-backed bundle fetched master members"
  after="$(bundle_snapshot)"
  assert_eq "${after}" "${before}" \
    "manifest-backed dead-branch bundle changed installed members"
  assert_no_bundle_staging "manifest-backed bundle dead-branch refusal"
  unset FAKE_CURL_FAIL_LICENSE

  prepare_bundle_fixture "legacy-branch-fallback"
  before="$(bundle_snapshot)"
  printf '0\n' > "${curl_counter}"
  BRANCH="retired-test-branch"
  G_ACCOUNT="bundle-test-account"
  URL_RAW="https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${BRANCH}"
  FAKE_CURL_FAIL_LICENSE=Y
  FAKE_CURL_EXPECT_FRAGMENT="/${G_ACCOUNT}/guild-operators/master/scripts/"
  export G_ACCOUNT FAKE_CURL_FAIL_LICENSE FAKE_CURL_EXPECT_FRAGMENT
  commonRuntimeIsInteractive() {
    return 1
  }
  if checkCommonRuntimeUpdates N; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "0" "legacy bundle dead-branch fallback status"
  assert_eq "$(cat "${curl_counter}")" "6" \
    "legacy bundle fallback did not fetch all members from the rebuilt master URL"
  after="$(bundle_snapshot)"
  assert_eq "${after}" "${before}" \
    "declined legacy fallback bundle changed installed members"
  assert_no_bundle_staging "legacy bundle dead-branch fallback"
  unset FAKE_CURL_FAIL_LICENSE FAKE_CURL_EXPECT_FRAGMENT
  BRANCH=master
  G_ACCOUNT="cardano-community"
  URL_RAW="https://invalid.example/guild-operators/master"
  export G_ACCOUNT

  prepare_bundle_fixture "success"
  printf '0\n' > "${curl_counter}"
  if checkCommonRuntimeUpdates Y; then
    status=0
  else
    status=$?
  fi
  assert_eq "${status}" "1" "successful bundle update status"
  while IFS= read -r target; do
    grep -q '^# remote-bundle-version=2$' "${target}" ||
      fail "successful bundle update omitted $(basename "${target}")"
    find "${target}" -prune -perm 0644 -print -quit | grep -q . ||
      fail "successful bundle update used the wrong mode for ${target}"
  done < <(bundle_paths)
  grep -q '^UPDATE_CHECK="N" # bundle-test-user-setting$' \
    "${bundle_root}/scripts/env" ||
    fail "bundle update did not preserve the env user header"
  assert_no_bundle_staging "successful bundle update"
)

run_manifest_tests
run_missing_and_malformed_manifest_tests

install_runtime_fixture cnode mainnet prometheus
install_runtime_fixture dingo preprod prometheus
install_runtime_fixture amaru preview otel

run_adapter_case cnode mainnet prometheus process
run_adapter_case dingo preprod prometheus n2c
run_adapter_case amaru preview otel process
run_env_manifest_fail_closed_tests

run_exponent_tests
run_exact_update_tests
run_bundle_transaction_tests

printf 'common runtime tests passed\n'
