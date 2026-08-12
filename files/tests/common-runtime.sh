#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2012,SC2016,SC2030,SC2031,SC2034,SC2154,SC2329
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-common-runtime.XXXXXX")"
TEST_ROOT="$(cd -P -- "${TEST_ROOT}" && pwd -P)"

cleanup() {
  if [[ "${GUILD_COMMON_RUNTIME_PRESERVE_TEST_ROOT:-N}" == "Y" ]]; then
    printf 'Preserving test root: %s\n' "${TEST_ROOT}" >&2
    return
  fi
  chmod -R u+rwX "${TEST_ROOT}" >/dev/null 2>&1 || true
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

runtime_stat_inode() {
  stat -f '%i' "$1" 2>/dev/null || stat -c '%i' "$1"
}

runtime_stat_mtime() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1"
}

runtime_stat_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

# Record every descendant without recording the node-home directory itself.
# Read-only currentness may briefly create its sibling generation lock, which
# necessarily updates NODE_HOME's directory mtime, but must leave no namespace,
# payload, pointer, or metadata mutation behind after releasing that lock.
runtime_tree_state() {
  local root="$1"
  local output="$2"
  local path="" relative_path="" kind="" content=""

  : > "${output}"
  while IFS= read -r path; do
    relative_path="${path#"${root}"/}"
    content=""
    if [[ -L "${path}" ]]; then
      kind="link"
      content="$(readlink "${path}")"
    elif [[ -d "${path}" ]]; then
      kind="dir"
    elif [[ -f "${path}" ]]; then
      kind="file"
      content="$(sha256sum -- "${path}" | awk '{print $1}')"
    else
      kind="other"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${relative_path}" "${kind}" "$(runtime_stat_inode "${path}")" \
      "$(runtime_stat_mtime "${path}")" "$(runtime_stat_mode "${path}")" \
      "${content}" >> "${output}"
  done < <(find "${root}" -mindepth 1 -print | LC_ALL=C sort)
}

assert_runtime_tree_unchanged() {
  local root="$1"
  local before="$2"
  local after="$3"
  local context="$4"

  runtime_tree_state "${root}" "${after}"
  cmp -s "${before}" "${after}" || {
    diff -u "${before}" "${after}" >&2 || true
    fail "${context} changed the node tree"
  }
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
        localCli: ($implementation != "amaru"),
        metrics: true,
        forging: ($implementation == "cnode" or $implementation == "dingo")
      }
    }' > "${node_root}/.deployment.json"
}

for required_command in awk chmod cmp diff find jq readlink sha256sum sort stat; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

run_manifest_tests() (
  local node_root="${TEST_ROOT}/runtime-test"
  local manifest="${node_root}/.deployment.json"
  local valid_content invalid
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
      localCli: true,
      metrics: true,
      forging: true
    },
    preserved: {
      string: "keep-me",
      list: [1, 2, 3]
    }
  }' > "${manifest}"

  NODE_HOME="${node_root}"
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"
  assert_eq "$(deployment_get implementation)" "dingo" "implementation read"
  assert_eq "$(deployment_get network)" "preprod" "network read"
  assert_eq "$(deployment_get branch)" "alpha" "branch read"
  assert_eq "$(deployment_get capabilities.n2c)" "true" "nested boolean read"
  jq -e '.n2c == true and .forging == true' \
    <<< "$(deployment_get capabilities)" >/dev/null ||
    fail "object-valued deployment_get result was invalid"
  if deployment_get missing.key >/dev/null 2>&1; then
    fail "deployment_get unexpectedly found a missing key"
  fi

  valid_content="$(cat "${manifest}")"
  deployment_branch_valid "feature/common-runtime" ||
    fail "valid deployment branch was rejected"

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
          localCli: true,
          metrics: true,
          forging: true
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
        localCli: ($implementation != "amaru"),
        metrics: true,
        forging: ($implementation == "cnode" or $implementation == "dingo")
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
     { ! node_has local_query || ! node_has local_submit; }; then
    fail "dingo adapter lacks cardano-cli query/submission capabilities"
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

run_glive_helper_tests() (
  local expected_patch

  # The normalized metric registries require associative arrays.
  (( BASH_VERSINFO[0] >= 4 )) || return 0
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library"

  node_metric_reset_availability
  node_metric_set_info runtime_version "go1.26.5" "Go runtime"
  node_metric_set_info epoch_size "432000" "Epoch length" "slots"
  node_metric_set_info runtime_version "go1.26.6" "Go runtime"
  assert_eq "${NODE_INFO_METRICS[*]}" "runtime_version epoch_size" \
    "Network-page metric registration and de-duplication"
  assert_eq "${runtime_version}" "go1.26.6" \
    "Network-page metric replacement"
  assert_eq "${NODE_METRIC_LABEL[epoch_size]}" "Epoch length" \
    "Network-page metric label"
  assert_eq "${NODE_METRIC_UNIT[epoch_size]}" "slots" \
    "Network-page metric unit"
  node_metric_unset_info runtime_version
  assert_eq "${NODE_INFO_METRICS[*]}" "epoch_size" \
    "Network-page metric removal"
  node_metric_has runtime_version &&
    fail "removed Network-page metric remained available"
  [[ -z "${NODE_METRIC_LABEL[runtime_version]+present}" ]] ||
    fail "removed Network-page metric retained its label"
  node_metric_reset_availability
  assert_eq "${#NODE_INFO_METRICS[@]}" "0" \
    "Network-page metrics were not reset between scrapes"

  assert_eq "$(glv_text_clip 5 abc)" "abc" \
    "short display text clipping"
  assert_eq "$(glv_text_clip 5 abcde)" "abcde" \
    "exact-width display text clipping"
  assert_eq "$(glv_text_clip 5 abcdef)" "abcd~" \
    "over-width display text clipping"
  assert_eq "$(glv_text_clip 1 abcdef)" "~" \
    "single-column display text clipping"
  assert_eq "$(glv_text_pad 5 abc)" "abc  " \
    "short display text padding"
  assert_eq "$(glv_text_pad 5 abcdef)" "abcd~" \
    "over-width display text padding"
  if glv_text_clip 0 abc >/dev/null 2>&1; then
    fail "display text clipping accepted a zero width"
  fi
  if glv_text_pad -1 abc >/dev/null 2>&1; then
    fail "display text padding accepted a negative width"
  fi

  assert_eq "$(glv_ratio_percent 0)" "0.00" \
    "zero propagation ratio formatting"
  assert_eq "$(glv_ratio_percent 0.95582861)" "95.58" \
    "propagation ratio formatting"
  assert_eq "$(glv_ratio_percent 1)" "100.00" \
    "complete propagation ratio formatting"
  assert_eq "$(glv_ratio_percent -0.5)" "0.00" \
    "negative propagation ratio lower bound"
  assert_eq "$(glv_ratio_percent 1.5)" "100.00" \
    "propagation ratio upper bound"
  if glv_ratio_percent invalid >/dev/null 2>&1; then
    fail "propagation ratio formatter accepted a non-numeric value"
  fi

  local theme_green='\e[32m'
  local theme_title='\e[35m\e[1m'
  glv_resolve_theme_escapes theme_green theme_title
  assert_eq "${theme_green}" $'\033[32m' \
    "single terminal theme escape resolution"
  assert_eq "${theme_title}" $'\033[35m\033[1m' \
    "combined terminal theme escape resolution"
  [[ "${theme_green}${theme_title}" != *'\e['* ]] ||
    fail "terminal theme resolver left visible escape text"
  if glv_resolve_theme_escapes 'invalid-name' >/dev/null 2>&1; then
    fail "terminal theme resolver accepted an invalid variable name"
  fi

  unset GLV_FRAME_NEXT GLV_FRAME_PREV GLV_FRAME_PATCH
  unset GLV_FRAME_LAST_FULL_REPAINT
  glv_frame_reset
  glv_frame_add "${theme_green}colored"
  glv_frame_build_patch N 99 10
  [[ "${GLV_FRAME_PATCH}" == *$'\033[32mcolored'* ]] ||
    fail "buffered frame omitted the resolved terminal theme escape"
  [[ "${GLV_FRAME_PATCH}" != *'\e['* ]] ||
    fail "buffered frame emitted visible terminal escape text"

  unset GLV_FRAME_NEXT GLV_FRAME_PREV GLV_FRAME_PATCH
  unset GLV_FRAME_LAST_FULL_REPAINT
  glv_frame_reset
  glv_frame_add "header"
  glv_frame_add "value 123456"
  glv_frame_build_patch N 100 10
  expected_patch=$'\033[1;1H\033[2Kheader\033[2;1H\033[2Kvalue 123456'
  assert_eq "${GLV_FRAME_PATCH}" "${expected_patch}" \
    "initial frame repaint"
  assert_eq "${GLV_FRAME_LAST_FULL_REPAINT}" "100" \
    "initial full-repaint timestamp"
  [[ "${GLV_FRAME_PATCH}" != *$'\033[2J'* ]] ||
    fail "initial frame patch cleared the whole screen"

  glv_frame_reset
  glv_frame_add "header"
  glv_frame_add "value 123456"
  glv_frame_build_patch N 105 10
  assert_eq "${GLV_FRAME_PATCH}" "" \
    "unchanged frame emitted terminal output"

  glv_frame_reset
  glv_frame_add "header"
  glv_frame_add "value 9"
  glv_frame_build_patch N 106 10
  expected_patch=$'\033[2;1H\033[2Kvalue 9'
  assert_eq "${GLV_FRAME_PATCH}" "${expected_patch}" \
    "changed-row-only frame patch"
  [[ "${GLV_FRAME_PATCH}" == *$'\033[2Kvalue 9' ]] ||
    fail "shorter replacement row was not erased before repaint"
  [[ "${GLV_FRAME_PATCH}" != *$'\033[1;1H'* ]] ||
    fail "changed-row patch repainted an unchanged row"

  glv_frame_reset
  glv_frame_add "header"
  glv_frame_build_patch N 107 10
  expected_patch=$'\033[2;1H\033[2K'
  assert_eq "${GLV_FRAME_PATCH}" "${expected_patch}" \
    "removed-row clearing patch"

  glv_frame_reset
  glv_frame_add "header"
  glv_frame_build_patch N 109 10
  assert_eq "${GLV_FRAME_PATCH}" "" \
    "unchanged frame before reconciliation emitted output"

  glv_frame_reset
  glv_frame_add "header"
  glv_frame_build_patch N 110 10
  expected_patch=$'\033[1;1H\033[2Kheader'
  assert_eq "${GLV_FRAME_PATCH}" "${expected_patch}" \
    "periodic full frame reconciliation"
  assert_eq "${GLV_FRAME_LAST_FULL_REPAINT}" "110" \
    "periodic full-repaint timestamp"

  glv_frame_reset
  glv_frame_add "header"
  glv_frame_add "detail"
  glv_frame_build_patch N 111 10
  expected_patch=$'\033[2;1H\033[2Kdetail'
  assert_eq "${GLV_FRAME_PATCH}" "${expected_patch}" \
    "new-row-only frame patch"

  glv_frame_reset
  glv_frame_add "header"
  glv_frame_add "detail"
  glv_frame_build_patch N 119 10
  assert_eq "${GLV_FRAME_PATCH}" "" \
    "unchanged multi-row frame emitted terminal output"

  glv_frame_reset
  glv_frame_add "header"
  glv_frame_add "detail"
  glv_frame_build_patch N 120 10
  expected_patch=$'\033[1;1H\033[2Kheader\033[2;1H\033[2Kdetail'
  assert_eq "${GLV_FRAME_PATCH}" "${expected_patch}" \
    "elapsed multi-row frame reconciliation"
  [[ "${GLV_FRAME_PATCH}" != *$'\033[2J'* ]] ||
    fail "periodic reconciliation cleared the whole screen"

  glv_frame_reset
  glv_frame_add "header"
  glv_frame_add "detail"
  glv_frame_build_patch Y 121 10
  assert_eq "${GLV_FRAME_PATCH}" "${expected_patch}" \
    "explicit forced frame reconciliation"
  assert_eq "${GLV_FRAME_LAST_FULL_REPAINT}" "121" \
    "forced full-repaint timestamp"
)

run_cnode_metrics_url_tests() (
  NODE_HOME="${TEST_ROOT}/cnode-metrics-url"
  CNODE_HOME="${NODE_HOME}"
  mkdir -p "${NODE_HOME}"
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/cnode-helper-scripts/cnode.adapter"

  PROM_HOST="192.0.2.20"
  PROM_PORT="18080"
  unset NODE_METRICS_HOST NODE_METRICS_PORT NODE_METRICS_PATH
  assert_eq "$(node_adapter_metrics_url)" \
    "http://192.0.2.20:18080/metrics" \
    "cnode legacy Prometheus endpoint compatibility"

  NODE_METRICS_HOST="127.0.0.2"
  NODE_METRICS_PORT="19090"
  NODE_METRICS_PATH="/custom-metrics"
  assert_eq "$(node_adapter_metrics_url)" \
    "http://127.0.0.2:19090/custom-metrics" \
    "cnode normalized metrics endpoint"

  unset NODE_METRICS_HOST NODE_METRICS_PORT
  unset PROM_HOST PROM_PORT
  if node_adapter_metrics_url >/dev/null 2>&1; then
    fail "cnode metrics URL accepted a missing host and port"
  fi
)

run_dispatcher_refresh_tests() (
  local suite_root="${TEST_ROOT}/dispatcher-refresh"
  local controller="${suite_root}/fake-dispatcher-controller.sh"
  local fake_bin="${suite_root}/bin"
  mkdir -p "${fake_bin}"

  cat > "${controller}" <<'CONTROLLER'
#!/usr/bin/env bash
set -euo pipefail

phase=apply
[[ "${GUILD_SOURCE_CHECK_ONLY:-N}" == "Y" ]] && phase=check
{
  printf '%s' "${phase}"
  printf '\t%s' "$@"
  printf '\n'
} >> "${FAKE_DISPATCHER_LOG:?}"

implementation=""
network=""
node_parent=""
node_name=""
branch=""
account=""
source_mode=""
while (( $# > 0 )); do
  case "$1" in
    -i) implementation="$2"; shift 2 ;;
    -n) network="$2"; shift 2 ;;
    -p) node_parent="$2"; shift 2 ;;
    -t) node_name="$2"; shift 2 ;;
    -b) branch="$2"; shift 2 ;;
    -a) account="$2"; shift 2 ;;
    -S) source_mode="$2"; shift 2 ;;
    -s) shift 2 ;;
    -u) shift ;;
    *) exit 64 ;;
  esac
done
[[ "${implementation}" == "cnode" && "${network}" == "mainnet" ]]
[[ -n "${node_parent}" && -n "${node_name}" && -n "${branch}" ]]
[[ -n "${account}" && -n "${source_mode}" ]]
node_root="${node_parent}/${node_name}"
manifest="${node_root}/.deployment.json"
receipt="${node_root}/.guild-source-receipt.json"
candidate="${FAKE_DISPATCHER_CANDIDATE:?}"
candidate_revision="$(jq -er '.sourceRevision' \
  "${candidate}/.deployment.json")"

receipt_matches_manifest() {
  local expected actual
  [[ -f "${manifest}" && ! -L "${manifest}" &&
     -f "${receipt}" && ! -L "${receipt}" ]] || return 1
  expected="$(jq -er '.payloadReceiptSha256' "${manifest}")" || return 1
  actual="$(sha256sum -- "${receipt}" | awk '{print $1}')" || return 1
  [[ "${actual}" == "${expected}" ]]
}

if [[ "${phase}" == "check" ]]; then
  if [[ "${FAKE_REFUSE_RECEIPT_DRIFT:-N}" == "Y" ]] &&
     ! receipt_matches_manifest; then
    exit 65
  fi
  printf '%s\n' "${candidate_revision}"
  exit "${FAKE_CHECK_STATUS:-0}"
fi

if [[ "${FAKE_REFUSE_RECEIPT_DRIFT:-N}" == "Y" ]] &&
   ! receipt_matches_manifest; then
  exit 65
fi
[[ "${GUILD_SOURCE_EXPECT_REVISION:-}" =~ ^[0-9a-f]{40,64}$ ]]
[[ "${GUILD_SOURCE_EXPECT_REVISION}" == \
   "${FAKE_APPLY_REVISION_OVERRIDE:-${candidate_revision}}" ]] || exit 66
[[ "$(jq -r '.implementation' "${candidate}/.deployment.json")" == "${implementation}" ]]
[[ "$(jq -r '.network' "${candidate}/.deployment.json")" == "${network}" ]]
[[ "$(jq -r '.branch' "${candidate}/.deployment.json")" == "${branch}" ]]
[[ "$(jq -r '.repository' "${candidate}/.deployment.json")" == "${account}/guild-operators" ]]
[[ "$(jq -r '.sourceMode' "${candidate}/.deployment.json")" == "${source_mode}" ]]

mkdir -p "${node_root}/payload" "${node_root}/scripts"
cp -- "${candidate}/payload/alpha" "${node_root}/payload/alpha"
printf 'payload-alpha\t%s\n' "$(jq -r '.branch' "${manifest}")" \
  >> "${FAKE_DISPATCHER_EVENT_LOG:?}"
cp -- "${candidate}/payload/beta" "${node_root}/payload/beta"
printf 'payload-beta\t%s\n' "$(jq -r '.branch' "${manifest}")" \
  >> "${FAKE_DISPATCHER_EVENT_LOG}"
cp -- "${candidate}/scripts/guild-deploy.sh" \
  "${node_root}/scripts/guild-deploy.sh"
chmod 0755 "${node_root}/scripts/guild-deploy.sh"
printf 'dispatcher\t%s\n' "$(jq -r '.branch' "${manifest}")" \
  >> "${FAKE_DISPATCHER_EVENT_LOG}"
cp -- "${candidate}/.guild-source-receipt.json" "${receipt}"
printf 'receipt\t%s\n' "$(jq -r '.branch' "${manifest}")" \
  >> "${FAKE_DISPATCHER_EVENT_LOG}"
cp -- "${candidate}/.deployment.json" "${manifest}"
printf 'metadata\t%s\n' "$(jq -r '.branch' "${manifest}")" \
  >> "${FAKE_DISPATCHER_EVENT_LOG}"
CONTROLLER
  chmod 0755 "${controller}"

  cat > "${fake_bin}/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
printf 'called\n' >> "${FAKE_CURL_LOG:?}"
exit 97
FAKE_CURL
  chmod 0755 "${fake_bin}/curl"
  PATH="${fake_bin}:${PATH}"
  export PATH

  write_fake_dispatcher() {
    local target="$1"
    cat > "${target}" <<'DISPATCHER'
#!/usr/bin/env bash
set -euo pipefail
dispatcher_prepare_source_and_handoff() { :; }
dispatcher_distribution_prepare() { :; }
# GUILD_SOURCE_CHECK_ONLY is the source-comparison contract marker.
exec "${BASH}" "${FAKE_DISPATCHER_CONTROLLER:?}" "$@"
DISPATCHER
    chmod 0755 "${target}"
  }

  publish_source_fixture() {
    local node_root="$1"
    local branch="$2"
    local source_mode="$3"
    local source_dirty="$4"
    local version="$5"
    local service_name="${6:-$(basename "${node_root}" | tr '[:upper:]' '[:lower:]')}"
    local receipt="${node_root}/.guild-source-receipt.json"
    local manifest="${node_root}/.deployment.json"
    local inventory="${node_root}/.receipt-files.ndjson"
    local relative_path file mode digest revision ref tree_digest receipt_hash

    mkdir -p "${node_root}/payload" "${node_root}/scripts"
    printf 'payload-alpha=%s\n' "${version}" > "${node_root}/payload/alpha"
    printf 'payload-beta=%s\n' "${version}" > "${node_root}/payload/beta"
    chmod 0644 "${node_root}/payload/alpha" "${node_root}/payload/beta"
    write_fake_dispatcher "${node_root}/scripts/guild-deploy.sh"

    : > "${inventory}"
    for relative_path in \
      payload/alpha \
      payload/beta \
      scripts/guild-deploy.sh; do
      file="${node_root}/${relative_path}"
      case "${relative_path}" in
        scripts/*) mode=0755 ;;
        *) mode=0644 ;;
      esac
      digest="$(sha256sum -- "${file}" | awk '{print $1}')"
      jq -cn \
        --arg path "${relative_path}" \
        --arg mode "${mode}" \
        --arg digest "${digest}" \
        '{
          path: $path,
          source: $path,
          mode: $mode,
          policy: "exact",
          sourceSha256: $digest,
          installedSha256: $digest,
          managed: true
        }' >> "${inventory}"
    done

    revision="$(printf '%s' "${branch}:${version}" | sha256sum | awk '{print $1}')"
    revision="${revision:0:40}"
    ref="refs/heads/${branch}"
    tree_digest="$(printf '%s' "${branch}:${version}:dirty" | sha256sum | awk '{print $1}')"
    jq -s \
      --arg repository "cardano-community/guild-operators" \
      --arg channel "${branch}" \
      --arg ref "${ref}" \
      --arg revision "${revision}" \
      --arg mode "${source_mode}" \
      --argjson dirty "${source_dirty}" \
      --arg tree_digest "${tree_digest}" \
      '{
        schemaVersion: 1,
        implementation: "cnode",
        network: "mainnet",
        source: ({
          repository: $repository,
          channel: $channel,
          ref: $ref,
          revision: $revision,
          mode: $mode,
          dirty: $dirty
        } + if $dirty then {treeDigest: $tree_digest} else {} end),
        files: .
      }' "${inventory}" > "${receipt}"
    rm -f -- "${inventory}"

    receipt_hash="$(sha256sum -- "${receipt}" | awk '{print $1}')"
    jq -n \
      --arg branch "${branch}" \
      --arg service "${service_name}" \
      --arg source_mode "${source_mode}" \
      --arg source_ref "${ref}" \
      --arg source_revision "${revision}" \
      --argjson source_dirty "${source_dirty}" \
      --arg tree_digest "${tree_digest}" \
      --arg receipt_hash "${receipt_hash}" \
      --arg transaction_id "${receipt_hash:0:16}" \
      '{
        schemaVersion: 1,
        deploymentStatus: "deployed",
        implementation: "cnode",
        network: "mainnet",
        branch: $branch,
        repository: "cardano-community/guild-operators",
        serviceName: $service,
        nodeVersion: "",
        targetNodeVersion: "test-target",
        metricsProvider: "prometheus",
        capabilities: {
          n2c: true,
          localCli: true,
          metrics: true,
          forging: true
        },
        sourceSchemaVersion: 1,
        sourceMode: $source_mode,
        sourceRef: $source_ref,
        sourceRevision: $source_revision,
        sourceDirty: $source_dirty,
        payloadReceipt: ".guild-source-receipt.json",
        payloadReceiptSha256: $receipt_hash,
        transactionId: $transaction_id
      } + if $source_dirty then {sourceTreeDigest: $tree_digest} else {} end' \
      > "${manifest}"
  }

  prepare_refresh_case() {
    local name="$1"
    local installed_branch="$2"
    local installed_mode="$3"
    local installed_dirty="$4"
    local candidate_branch="$5"
    local candidate_mode="$6"
    local installed_version="${7:-1}"
    local candidate_version="${8:-2}"
    local service

    CASE_ROOT="${suite_root}/${name}"
    NODE_HOME="${CASE_ROOT}/node"
    CANDIDATE_ROOT="${CASE_ROOT}/candidate"
    DISPATCH_LOG="${CASE_ROOT}/dispatcher.log"
    EVENT_LOG="${CASE_ROOT}/events.log"
    CURL_LOG="${CASE_ROOT}/curl.log"
    service="$(basename "${NODE_HOME}" | tr '[:upper:]' '[:lower:]')"
    mkdir -p "${CASE_ROOT}"
    : > "${DISPATCH_LOG}"
    : > "${EVENT_LOG}"
    : > "${CURL_LOG}"
    publish_source_fixture "${NODE_HOME}" "${installed_branch}" \
      "${installed_mode}" "${installed_dirty}" "${installed_version}" "${service}"
    publish_source_fixture "${CANDIDATE_ROOT}" "${candidate_branch}" \
      "${candidate_mode}" false "${candidate_version}" "${service}"

    FAKE_DISPATCHER_CONTROLLER="${controller}"
    FAKE_DISPATCHER_CANDIDATE="${CANDIDATE_ROOT}"
    FAKE_DISPATCHER_LOG="${DISPATCH_LOG}"
    FAKE_DISPATCHER_EVENT_LOG="${EVENT_LOG}"
    FAKE_CURL_LOG="${CURL_LOG}"
    export NODE_HOME FAKE_DISPATCHER_CONTROLLER FAKE_DISPATCHER_CANDIDATE
    export FAKE_DISPATCHER_LOG FAKE_DISPATCHER_EVENT_LOG FAKE_CURL_LOG
  }

  load_refresh_libraries() {
    unset GUILD_PAYLOAD_REFRESH_OWNER_PID GUILD_PAYLOAD_REFRESH_STATE
    unset GUILD_PAYLOAD_REFRESH_SIGNATURE GUILD_PAYLOAD_REFRESH_RESULT
    unset GUILD_SOURCE_MODE FAKE_REFUSE_RECEIPT_DRIFT
    UPDATE_CHECK=Y
    OFFLINE_MODE=N
    FG_YELLOW=""
    NC=""
    # shellcheck source=/dev/null
    . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"
    # shellcheck source=/dev/null
    . "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library"

    # These cases exercise refresh orchestration with a deliberately small
    # three-file dispatcher fixture. Production currentness requires the exact
    # historical/current deployment inventories and is covered independently
    # by run_stage1_payload_currentness_tests below.
    deployment_payload_is_current() {
      local receipt="${NODE_HOME}/.guild-source-receipt.json"
      local metadata="${NODE_HOME}/.deployment.json"
      local expected_hash="" actual_hash="" path="" mode="" digest=""
      local actual_digest=""

      [[ -f "${receipt}" && ! -L "${receipt}" && -O "${receipt}" &&
         -f "${metadata}" && ! -L "${metadata}" && -O "${metadata}" ]] ||
        return 1
      jq -e '
        .schemaVersion == 1 and .implementation == "cnode" and
        .network == "mainnet" and
        [.files[].path] == [
          "payload/alpha", "payload/beta", "scripts/guild-deploy.sh"
        ] and
        all(.files[];
          keys == ["installedSha256","managed","mode","path","policy",
            "source","sourceSha256"] and
          .managed == true and .policy == "exact" and
          .source == .path and .sourceSha256 == .installedSha256)
      ' "${receipt}" >/dev/null || return 1
      expected_hash="$(jq -er '.payloadReceiptSha256' "${metadata}")" ||
        return 1
      actual_hash="$(sha256sum -- "${receipt}" | awk '{print $1}')" ||
        return 1
      [[ "${actual_hash}" == "${expected_hash}" ]] || return 1

      while IFS=$'\t' read -r path mode digest; do
        actual_digest="$(sha256sum -- "${NODE_HOME}/${path}" | awk '{print $1}')" ||
          return 1
        [[ -f "${NODE_HOME}/${path}" && ! -L "${NODE_HOME}/${path}" &&
           -O "${NODE_HOME}/${path}" &&
           "0$(runtime_stat_mode "${NODE_HOME}/${path}")" == "${mode}" &&
           "${actual_digest}" == "${digest}" ]] || return 1
      done < <(jq -r '.files[] | [.path,.mode,.installedSha256] | @tsv' \
        "${receipt}")
      return 0
    }
  }

  assert_dispatch_call() {
    local log_file="$1"
    local line_number="$2"
    local expected_phase="$3"
    local expected_branch="$4"
    local expected_mode="$5"
    local expected_parent="$6"
    local expected_target="$7"

    awk -F '\t' \
      -v line_number="${line_number}" \
      -v phase="${expected_phase}" \
      -v branch="${expected_branch}" \
      -v mode="${expected_mode}" \
      -v parent="${expected_parent}" \
      -v target="${expected_target}" '
        NR == line_number {
          found = 1
          if (NF != 18) found = 0
          if ($1 != phase) found = 0
          if ($2 != "-i" || $3 != "cnode") found = 0
          if ($4 != "-n" || $5 != "mainnet") found = 0
          if ($6 != "-p" || $7 != parent) found = 0
          if ($8 != "-t" || $9 != target) found = 0
          if ($10 != "-b" || $11 != branch) found = 0
          if ($12 != "-a" || $13 != "cardano-community") found = 0
          if ($14 != "-S" || $15 != mode) found = 0
          if ($16 != "-s" || $17 != "" || $18 != "-u") found = 0
        }
        END { exit(found ? 0 : 1) }
      ' "${log_file}" ||
      fail "dispatcher call ${line_number} did not use the expected ${expected_phase}/${expected_mode} complete-refresh arguments"
  }

  assert_no_partial_downloads() {
    local context="$1"
    [[ ! -s "${CURL_LOG}" ]] ||
      fail "${context} attempted a legacy per-file download"
  }

  run_default_delegation_case() (
    local status=0 call_count
    prepare_refresh_case default-delegation master managed false \
      master managed 1 2
    load_refresh_libraries
    assert_eq "${COMMON_RUNTIME_UPDATE_API_VERSION}" "1" \
      "common runtime updater API version"
    declare -F deployment_refresh_payload >/dev/null ||
      fail "complete deployment refresh entry point is unavailable"
    declare -F checkUpdate >/dev/null ||
      fail "historical checkUpdate compatibility entry point is unavailable"
    declare -F checkCommonRuntimeUpdates >/dev/null ||
      fail "common runtime refresh entry point is unavailable"
    FAKE_CHECK_STATUS=10
    export FAKE_CHECK_STATUS

    if checkUpdate "${NODE_HOME}/payload/alpha" Y N N \
         "common-helper-scripts/lib" exact; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "1" \
      "checkUpdate complete dispatcher refresh status"
    assert_file_unchanged "${NODE_HOME}/payload/alpha" "payload-alpha=2" \
      "complete refresh omitted alpha payload"
    assert_file_unchanged "${NODE_HOME}/payload/beta" "payload-beta=2" \
      "complete refresh omitted beta payload"
    call_count="$(wc -l < "${DISPATCH_LOG}" | tr -d '[:space:]')"
    assert_eq "${call_count}" "2" "check/apply dispatcher call count"
    assert_dispatch_call "${DISPATCH_LOG}" 1 check master managed \
      "$(dirname "${NODE_HOME}")" "$(basename "${NODE_HOME}")"
    assert_dispatch_call "${DISPATCH_LOG}" 2 apply master managed \
      "$(dirname "${NODE_HOME}")" "$(basename "${NODE_HOME}")"
    if grep -Fq "${NODE_HOME}/payload/alpha" "${DISPATCH_LOG}"; then
      fail "legacy checkUpdate target leaked into dispatcher arguments"
    fi
    assert_no_partial_downloads "complete checkUpdate refresh"

    if checkCommonRuntimeUpdates Y; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "1" \
      "process-cached common runtime refresh result"
    call_count="$(wc -l < "${DISPATCH_LOG}" | tr -d '[:space:]')"
    assert_eq "${call_count}" "2" \
      "process-level result cache repeated dispatcher calls"
  )

  run_up_to_date_case() (
    local status=0
    prepare_refresh_case up-to-date master managed false master managed 1 1
    load_refresh_libraries
    FAKE_CHECK_STATUS=0
    export FAKE_CHECK_STATUS

    if checkCommonRuntimeUpdates Y; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "0" "up-to-date complete refresh status"
    assert_eq "$(wc -l < "${DISPATCH_LOG}" | tr -d '[:space:]')" "1" \
      "up-to-date refresh invoked apply dispatcher"
    assert_dispatch_call "${DISPATCH_LOG}" 1 check master managed \
      "$(dirname "${NODE_HOME}")" "$(basename "${NODE_HOME}")"
    [[ ! -s "${EVENT_LOG}" ]] ||
      fail "up-to-date source check mutated the target"
    assert_no_partial_downloads "up-to-date source check"
  )

  run_cached_selection_case() (
    local status=0
    prepare_refresh_case cached-selection master managed false \
      master cached 1 2
    load_refresh_libraries
    GUILD_SOURCE_MODE=cached
    FAKE_CHECK_STATUS=10
    export GUILD_SOURCE_MODE FAKE_CHECK_STATUS

    if checkCommonRuntimeUpdates Y; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "1" "explicit cached complete refresh status"
    assert_dispatch_call "${DISPATCH_LOG}" 1 check master cached \
      "$(dirname "${NODE_HOME}")" "$(basename "${NODE_HOME}")"
    assert_dispatch_call "${DISPATCH_LOG}" 2 apply master cached \
      "$(dirname "${NODE_HOME}")" "$(basename "${NODE_HOME}")"
    assert_eq "$(jq -r '.sourceMode' "${NODE_HOME}/.deployment.json")" \
      "cached" "cached source selection was not committed"
    assert_no_partial_downloads "cached complete refresh"
  )

  run_branch_transaction_case() (
    local status=0
    prepare_refresh_case branch-transaction master managed false \
      feature/stage0c managed 1 2
    load_refresh_libraries
    FAKE_CHECK_STATUS=10
    export FAKE_CHECK_STATUS

    if deployment_set_branch feature/stage0c; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "0" "transactional branch update status"
    assert_dispatch_call "${DISPATCH_LOG}" 1 check feature/stage0c managed \
      "$(dirname "${NODE_HOME}")" "$(basename "${NODE_HOME}")"
    assert_dispatch_call "${DISPATCH_LOG}" 2 apply feature/stage0c managed \
      "$(dirname "${NODE_HOME}")" "$(basename "${NODE_HOME}")"
    assert_eq "$(jq -r '.branch' "${NODE_HOME}/.deployment.json")" \
      "feature/stage0c" "branch transaction metadata"
    assert_file_unchanged "${NODE_HOME}/payload/alpha" "payload-alpha=2" \
      "branch transaction omitted alpha payload"
    assert_file_unchanged "${NODE_HOME}/payload/beta" "payload-beta=2" \
      "branch transaction omitted beta payload"
    assert_eq "$(awk -F '\t' 'NR < 5 {print $2}' "${EVENT_LOG}" | sort -u)" \
      "master" "branch metadata changed before payload and receipt activation"
    assert_eq "$(tail -n 1 "${EVENT_LOG}")" \
      $'metadata\tfeature/stage0c' \
      "deployment metadata was not the final branch transaction event"
    assert_no_partial_downloads "branch transaction"
  )

  run_local_dirty_refusal_cases() (
    local status=0

    prepare_refresh_case installed-local master local false master managed 1 2
    load_refresh_libraries
    if checkCommonRuntimeUpdates Y >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "2" "installed local source refresh refusal"
    [[ ! -s "${DISPATCH_LOG}" ]] ||
      fail "installed local source refusal invoked dispatcher"

    prepare_refresh_case installed-dirty master managed true master managed 1 2
    load_refresh_libraries
    if checkCommonRuntimeUpdates Y >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "2" "installed dirty source refresh refusal"
    [[ ! -s "${DISPATCH_LOG}" ]] ||
      fail "installed dirty source refusal invoked dispatcher"

    prepare_refresh_case selected-local master managed false master managed 1 2
    load_refresh_libraries
    GUILD_SOURCE_MODE=local
    if checkCommonRuntimeUpdates Y >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "2" "automatic local source selection refusal"
    [[ ! -s "${DISPATCH_LOG}" ]] ||
      fail "automatic local source selection invoked dispatcher"
    assert_no_partial_downloads "local and dirty refusals"
  )

  run_receipt_drift_refusal_case() (
    local status=0 before_manifest before_alpha
    prepare_refresh_case receipt-drift master managed false master managed 1 2
    load_refresh_libraries
    before_manifest="$(cat "${NODE_HOME}/.deployment.json")"
    before_alpha="$(cat "${NODE_HOME}/payload/alpha")"
    printf '\n' >> "${NODE_HOME}/.guild-source-receipt.json"
    FAKE_CHECK_STATUS=10
    FAKE_REFUSE_RECEIPT_DRIFT=Y
    export FAKE_CHECK_STATUS FAKE_REFUSE_RECEIPT_DRIFT

    if checkCommonRuntimeUpdates Y >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "2" "receipt drift refusal status"
    assert_eq "$(wc -l < "${DISPATCH_LOG}" | tr -d '[:space:]')" "1" \
      "receipt drift refusal reached dispatcher apply"
    assert_dispatch_call "${DISPATCH_LOG}" 1 check master managed \
      "$(dirname "${NODE_HOME}")" "$(basename "${NODE_HOME}")"
    assert_file_unchanged "${NODE_HOME}/.deployment.json" \
      "${before_manifest}" "receipt drift changed deployment metadata"
    assert_file_unchanged "${NODE_HOME}/payload/alpha" \
      "${before_alpha}" "receipt drift changed managed payload"
    [[ ! -s "${EVENT_LOG}" ]] ||
      fail "receipt drift refusal activated candidate files"
    assert_no_partial_downloads "receipt drift refusal"
  )

  run_moved_revision_refusal_case() (
    local status=0 before_manifest before_alpha
    prepare_refresh_case moved-revision master managed false master managed 1 2
    load_refresh_libraries
    before_manifest="$(cat "${NODE_HOME}/.deployment.json")"
    before_alpha="$(cat "${NODE_HOME}/payload/alpha")"
    FAKE_CHECK_STATUS=10
    FAKE_APPLY_REVISION_OVERRIDE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    export FAKE_CHECK_STATUS FAKE_APPLY_REVISION_OVERRIDE

    if checkCommonRuntimeUpdates Y >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "2" "moved revision refusal status"
    assert_eq "$(wc -l < "${DISPATCH_LOG}" | tr -d '[:space:]')" "2" \
      "moved revision dispatcher call count"
    [[ ! -s "${EVENT_LOG}" ]] ||
      fail "moved revision refusal activated candidate files"
    assert_file_unchanged "${NODE_HOME}/.deployment.json" \
      "${before_manifest}" "moved revision changed deployment metadata"
    assert_file_unchanged "${NODE_HOME}/payload/alpha" \
      "${before_alpha}" "moved revision changed managed payload"
    assert_no_partial_downloads "moved revision refusal"
  )

  run_dispatcher_safety_cases() (
    local status=0

    prepare_refresh_case missing-dispatcher master managed false master managed 1 2
    load_refresh_libraries
    rm -f -- "${NODE_HOME}/scripts/guild-deploy.sh"
    if checkCommonRuntimeUpdates Y >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "2" "missing dispatcher refusal"
    [[ ! -s "${DISPATCH_LOG}" ]] ||
      fail "missing dispatcher refusal invoked a dispatcher"

    prepare_refresh_case unsafe-dispatcher master managed false master managed 1 2
    load_refresh_libraries
    rm -f -- "${NODE_HOME}/scripts/guild-deploy.sh"
    ln -s "${controller}" "${NODE_HOME}/scripts/guild-deploy.sh"
    if checkCommonRuntimeUpdates Y >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "2" "unsafe dispatcher symlink refusal"
    [[ ! -s "${DISPATCH_LOG}" ]] ||
      fail "unsafe dispatcher refusal invoked a dispatcher"
    assert_no_partial_downloads "missing and unsafe dispatcher refusals"
  )

  run_update_disabled_case() (
    local status=0
    prepare_refresh_case update-disabled master managed false master managed 1 2
    load_refresh_libraries
    UPDATE_CHECK=N
    if checkUpdate "${NODE_HOME}/payload/alpha" Y N N ignored exact; then
      status=0
    else
      status=$?
    fi
    assert_eq "${status}" "0" "disabled update check status"
    [[ ! -s "${DISPATCH_LOG}" ]] ||
      fail "disabled update check invoked dispatcher"
    assert_no_partial_downloads "disabled update check"
  )

  run_default_delegation_case
  run_up_to_date_case
  run_cached_selection_case
  run_branch_transaction_case
  run_local_dirty_refusal_cases
  run_receipt_drift_refusal_case
  run_moved_revision_refusal_case
  run_dispatcher_safety_cases
  run_update_disabled_case
)

run_stage1_payload_currentness_tests() (
  local suite_root="${TEST_ROOT}/stage1-stage2-payload-currentness"
  local node_root="${suite_root}/node"
  local cntools_root="${node_root}/scripts/.cntools"
  local revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local candidate_id=""
  local schema2_id=""
  local schema1_id=""
  local missing_module_schema_id=""
  local wrong_module_schema_id=""
  local active_id=""
  local receipt="${node_root}/.guild-source-receipt.json"
  local metadata="${node_root}/.deployment.json"
  local receipt_hash=""
  local sentinel=""
  local tampered=""
  local saved=""
  local lifecycle=""
  local before=""
  local after=""
  local artifact=""
  local artifact_name=""
  local host_files_json="${suite_root}/host-files.json"
  local authority_receipt_saved="${suite_root}/authority.receipt.saved"
  local authority_metadata_saved="${suite_root}/authority.metadata.saved"
  local real_jq=""
  local transaction_id_length="" original_owner=""
  local fake_target="" fake_hash="" bundle_path="" bundle_source=""
  local fake_bundle_path="" fake_bundle_source=""
  local config_target="" config_hash="" managed_path="" managed_target=""
  local generation="" generation_manifest="" generation_receipt=""
  local generation_core_saved=""
  local directory="" target_file=""
  local fault_bin="" fault_jq="" saved_path=""

  build_currentness_generation() {
    local variant="$1"
    local payload_schema="${2:-3}"
    local module_schema_variant="${3:-canonical}"
    local payload="${suite_root}/payload-${variant}"
    local common="${payload}/scripts/common-helper-scripts"
    local manifest="${common}/cntools/manifest.json"
    local root_module="${common}/cntools/modules/root/module.json"
    local inventory="${suite_root}/${variant}.inventory.ndjson"
    local canonical="${suite_root}/${variant}.canonical.tsv"
    local manifest_hash=""
    local generation_id=""
    local generation=""
    local path="" source="" mode="" validator="" hash="" extra=""
    local source_file="" target_file=""

    mkdir -p -- "${common}"
    cp -- "${REPO_ROOT}/scripts/common-helper-scripts/cntools.library" \
      "${common}/cntools.library"
    cp -- "${REPO_ROOT}/scripts/common-helper-scripts/cntools.conf.example" \
      "${common}/cntools.conf.example"
    cp -R -- "${REPO_ROOT}/scripts/common-helper-scripts/cntools" \
      "${common}/cntools"
    if [[ "${payload_schema}" == "1" ]]; then
      jq -S '.schemaVersion = 1 | del(.controlPolicy)' \
        "${root_module}" > "${root_module}.tmp"
      mv -f -- "${root_module}.tmp" "${root_module}"
      jq '
        .schemaVersion = 1 |
        .moduleApiVersion = 1 |
        del(.moduleSchemaVersion) |
        del(.legacyBundle) |
        .files |= map(select(
          (.path | startswith("cntools/libs/legacy/") | not) and
          ((.path | startswith("cntools/modules/root/") | not) or
           .path == "cntools/modules/root/module.json")
        ))
      ' "${manifest}" > "${manifest}.tmp"
      mv -f -- "${manifest}.tmp" "${manifest}"
    elif [[ "${payload_schema}" == "2" ]]; then
      jq -S '.schemaVersion = 1 | del(.controlPolicy)' \
        "${root_module}" > "${root_module}.tmp"
      mv -f -- "${root_module}.tmp" "${root_module}"
      jq '
        .schemaVersion = 2 |
        .moduleApiVersion = 1 |
        del(.moduleSchemaVersion) |
        .files |= map(select(
          (.path | startswith("cntools/modules/root/") | not) or
          .path == "cntools/modules/root/module.json"
        ))
      ' "${manifest}" > "${manifest}.tmp"
      mv -f -- "${manifest}.tmp" "${manifest}"
    elif [[ "${payload_schema}" == "3" ]]; then
      case "${module_schema_variant}" in
        canonical) : ;;
        missing)
          jq 'del(.moduleSchemaVersion)' "${manifest}" > "${manifest}.tmp"
          mv -f -- "${manifest}.tmp" "${manifest}"
          ;;
        wrong)
          jq '.moduleSchemaVersion = 1' "${manifest}" > "${manifest}.tmp"
          mv -f -- "${manifest}.tmp" "${manifest}"
          ;;
        *) return 2 ;;
      esac
    else
      return 2
    fi
    while IFS= read -r source; do
      hash="$(sha256sum -- "${payload}/${source}" | awk '{print $1}')"
      jq --arg source "${source}" --arg hash "${hash}" \
        '(.files[] | select(.source == $source) | .sha256) = $hash' \
        "${manifest}" > "${manifest}.tmp"
      mv -f -- "${manifest}.tmp" "${manifest}"
    done < <(jq -r '.files[].source' "${manifest}")
    case "${payload_schema}" in
      1) [[ "$(jq -er '.files | length' "${manifest}")" == 19 ]] || return 2 ;;
      2) [[ "$(jq -er '.files | length' "${manifest}")" == 29 ]] || return 2 ;;
      3) [[ "$(jq -er '.files | length' "${manifest}")" == 151 ]] || return 2 ;;
    esac
    if [[ "${variant}" == "active-a" ]]; then
      chmod u+w "${common}/cntools/docs/TESTING.md" "${manifest}"
      printf '\nCurrentness retained-active fixture.\n' >> \
        "${common}/cntools/docs/TESTING.md"
      hash="$(sha256sum -- "${common}/cntools/docs/TESTING.md" | awk '{print $1}')"
      jq --arg source scripts/common-helper-scripts/cntools/docs/TESTING.md \
        --arg hash "${hash}" \
        '(.files[] | select(.source == $source) | .sha256) = $hash' \
        "${manifest}" > "${manifest}.tmp"
      mv -f -- "${manifest}.tmp" "${manifest}"
    fi
    manifest_hash="$(sha256sum -- "${manifest}" | awk '{print $1}')"
    jq -cn --arg hash "${manifest_hash}" '{
      path: "cntools/manifest.json",
      source: "scripts/common-helper-scripts/cntools/manifest.json",
      mode: "0444", validator: "json", sha256: $hash
    }' > "${inventory}"
    jq -c '.files[]' "${manifest}" >> "${inventory}"
    jq -r -s 'sort_by(.path)[] | [.path,.mode,.sha256] | @tsv' \
      "${inventory}" > "${canonical}"
    generation_id="$(sha256sum -- "${canonical}" | awk '{print $1}')"
    generation="${cntools_root}/generations/${generation_id}"
    mkdir -p -- "${generation}/cntools"
    cp -- "${manifest}" "${generation}/cntools/manifest.json"
    chmod 0444 "${generation}/cntools/manifest.json"
    while IFS=$'\t' read -r path source mode validator hash extra; do
      [[ -n "${path}" && -n "${source}" && -n "${mode}" &&
         -n "${validator}" && -n "${hash}" && -z "${extra}" ]] || return 2
      source_file="${payload}/${source}"
      target_file="${generation}/${path}"
      mkdir -p -- "$(dirname -- "${target_file}")"
      cp -- "${source_file}" "${target_file}"
      chmod "${mode}" "${target_file}"
    done < <(jq -r '.files[] |
      [.path,.source,.mode,.validator,.sha256] | @tsv' "${manifest}")
    jq -s --arg id "${generation_id}" --arg hash "${manifest_hash}" \
      --argjson schema_version "${payload_schema}" '{
        schemaVersion: $schema_version,
        id: $id,
        version: "13.5.7",
        generationIdAlgorithm: "sha256-path-mode-content-v1",
        payloadManifest: "cntools/manifest.json",
        payloadManifestSha256: $hash,
        files: sort_by(.path)
      }' "${inventory}" > "${generation}/.generation.json"
    chmod 0444 "${generation}/.generation.json"
    find "${generation}" -depth -type d -exec chmod 0555 {} +
    printf '%s\n' "${generation_id}"
  }

  build_host_file_inventory() {
    local implementation="$1"
    local network="$2"
    local generation_id="${3:-}"
    local include_bundle="$4"
    local order_class="$5"
    local generation="${cntools_root}/generations/${generation_id}"
    local generation_manifest="${generation}/cntools/manifest.json"
    local records="${suite_root}/host-files.ndjson"
    local ordinary_records="${suite_root}/host-ordinary.tsv"
    local source_fixture=""
    local source_path="" target_path="" mode="" policy=""
    local effective_policy="" managed="" source_hash="" installed_hash=""
    local bundle_id="" member="" member_hash="" bundle_root="" target=""
    local predecessor="" index=0 expected_count=0

    [[ "${order_class}" == "legacy" ||
       "${order_class}" == "reader-isolated" ]] || return 2
    [[ "${include_bundle}" != "Y" ||
       "${order_class}" == "reader-isolated" ]] || return 2
    : > "${records}"
    if [[ "${include_bundle}" == "Y" ]]; then
      [[ "${implementation}" == "cnode" ||
         "${implementation}" == "dingo" ]] || return 2
      bundle_id="$(jq -er '.legacyBundle.id' "${generation_manifest}")" ||
        return 2
      bundle_root="${node_root}/scripts/cntools/libs/legacy/${bundle_id}"
      mkdir -p -- "${bundle_root}"
      chmod 0700 "${node_root}/scripts/cntools" \
        "${node_root}/scripts/cntools/libs" \
        "${node_root}/scripts/cntools/libs/legacy"
      chmod 0755 "${bundle_root}"
      while IFS=$'\t' read -r member mode member_hash; do
        source_path="scripts/common-helper-scripts/cntools/libs/legacy/${bundle_id}/${member}"
        target_path="scripts/cntools/libs/legacy/${bundle_id}/${member}"
        target="${node_root}/${target_path}"
        [[ ! -e "${target}" || -f "${target}" ]] || return 2
        [[ ! -e "${target}" ]] || chmod 0644 "${target}"
        cp -- "${generation}/cntools/libs/legacy/${bundle_id}/${member}" \
          "${target}"
        chmod 0444 "${target}"
        installed_hash="$(sha256sum -- "${target}" | awk '{print $1}')"
        [[ "${installed_hash}" == "${member_hash}" ]] || return 2
        jq -cn --arg path "${target_path}" --arg source "${source_path}" \
          --arg mode "${mode}" --arg hash "${member_hash}" '{
            path: $path, source: $source, mode: $mode,
            policy: "cntools-legacy-bundle", sourceSha256: $hash,
            installedSha256: $hash, managed: true
          }' >> "${records}"
      done < <(jq -er '.legacyBundle.members[] |
        [.path,.mode,.sha256] | @tsv' "${generation_manifest}")
      chmod 0555 "${bundle_root}"
    fi

    awk -F '\t' -v implementation="${implementation}" -v network="${network}" \
      -v order_class="${order_class}" '
      ($1 == "common" || $1 == implementation) &&
        $5 != "retire" && $5 != "cntools-generation" &&
        $5 != "cntools-legacy-bundle" {
        source_path = $2
        target_path = $3
        gsub(/\{implementation\}/, implementation, source_path)
        gsub(/\{implementation\}/, implementation, target_path)
        gsub(/\{network\}/, network, source_path)
        gsub(/\{network\}/, network, target_path)
        row = source_path "\t" target_path "\t" $4 "\t" $5
        if (target_path == "scripts/cntools.library") {
          facade = row
        } else if ($1 == "common") {
          common_rows[++common_count] = row
        } else {
          profile_rows[++profile_count] = row
          profile_targets[profile_count] = target_path
        }
      }
      END {
        if (order_class == "reader-isolated" && facade != "") {
          print facade
          facade = ""
        }
        for (i = 1; i <= common_count; i++) print common_rows[i]
        for (i = 1; i <= profile_count; i++) {
          print profile_rows[i]
          if (order_class == "legacy" && facade != "" &&
              ((implementation == "cnode" &&
                profile_targets[i] == "scripts/cntools.sh") ||
               (implementation == "dingo" &&
                profile_targets[i] == "scripts/gLiveView.sh"))) {
            print facade
            facade = ""
          }
        }
        if (facade != "") exit 2
      }
    ' "${REPO_ROOT}/files/node-implementations/source-manifest.tsv" > \
      "${ordinary_records}"
    while IFS=$'\t' read -r source_path target_path mode policy; do
      index=$((index + 1))
      source_fixture="${suite_root}/host-source.${index}"
      printf 'currentness source fixture: %s\n' "${source_path}" > \
        "${source_fixture}"
      source_hash="$(sha256sum -- "${source_fixture}" | awk '{print $1}')"
      target="${node_root}/${target_path}"
      mkdir -p -- "$(dirname -- "${target}")"
      effective_policy="${policy}"
      managed=true
      if [[ "${policy}" == "preserve-render" ]]; then
        effective_policy="render-${implementation}"
        managed=false
        printf 'currentness rendered fixture: %s\n' "${target_path}" > \
          "${target}"
      else
        cp -- "${source_fixture}" "${target}"
      fi
      chmod "${mode}" "${target}"
      installed_hash="$(sha256sum -- "${target}" | awk '{print $1}')"
      jq -cn --arg path "${target_path}" --arg source "${source_path}" \
        --arg mode "${mode}" --arg policy "${effective_policy}" \
        --arg source_hash "${source_hash}" \
        --arg installed_hash "${installed_hash}" \
        --argjson managed "${managed}" '{
          path: $path, source: $source, mode: $mode, policy: $policy,
          sourceSha256: $source_hash, installedSha256: $installed_hash,
          managed: $managed
        }' >> "${records}"
    done < "${ordinary_records}"
    jq -s '.' "${records}" > "${host_files_json}"
    case "${implementation}:${include_bundle}" in
      cnode:N) expected_count=38 ;;
      cnode:Y) expected_count=48 ;;
      dingo:N) expected_count=15 ;;
      dingo:Y) expected_count=25 ;;
      amaru:N) expected_count=12 ;;
      *) return 2 ;;
    esac
    jq -e --argjson count "${expected_count}" '
      length == $count and (map(.path) | length == (unique | length)) and
      all(.[];
        keys == ["installedSha256","managed","mode","path","policy",
          "source","sourceSha256"])
    ' "${host_files_json}" >/dev/null || return 2
    if [[ "${implementation}" == "cnode" ||
          "${implementation}" == "dingo" ]]; then
      if [[ "${order_class}" == "legacy" ]]; then
        if [[ "${implementation}" == "cnode" ]]; then
          predecessor=scripts/cntools.sh
        else
          predecessor=scripts/gLiveView.sh
        fi
        jq -e --arg predecessor "${predecessor}" '
          .[0].path == "scripts/guild-deploy.sh" and
          ((map(.path) | index("scripts/cntools.library")) ==
           ((map(.path) | index($predecessor)) + 1))
        ' "${host_files_json}" >/dev/null || return 2
      else
        jq -e '
          (.[0:10] | all(.policy == "cntools-legacy-bundle")) and
          .[10].path == "scripts/cntools.library" and
          .[11].path == "scripts/guild-deploy.sh"
        ' "${host_files_json}" >/dev/null || return 2
      fi
    else
      jq -e '.[0].path == "scripts/guild-deploy.sh"' \
        "${host_files_json}" >/dev/null || return 2
    fi
  }

  write_host_authority() {
    local implementation="$1"
    local source_schema="$2"
    local generation_id="${3:-}"
    local source_shape="${4:-clean}"
    local transaction_id_length="${5:-24}"
    local generation="${cntools_root}/generations/${generation_id}"
    local manifest_hash="" generation_receipt_hash=""
    local generation_file_count=0 generation_version="" include_bundle=N
    local order_class=legacy
    local has_generation=false source_dirty=false source_mode=managed
    local tree_digest=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    local expected_file_count=0 metrics_provider=prometheus
    local n2c=true local_cli=true metrics=true forging=true
    local network=mainnet

    if [[ "${source_schema}" == "2" &&
          ( "${implementation}" == "cnode" ||
            "${implementation}" == "dingo" ) ]]; then
      has_generation=true
      manifest_hash="$(sha256sum -- \
        "${generation}/cntools/manifest.json" | awk '{print $1}')"
      generation_receipt_hash="$(sha256sum -- \
        "${generation}/.generation.json" | awk '{print $1}')"
      generation_file_count="$(jq -er '.files | length' \
        "${generation}/.generation.json")"
      generation_version="$(jq -er '.version' \
        "${generation}/.generation.json")"
      [[ "${generation_file_count}" == "20" ||
         "${generation_file_count}" == "30" ||
         "${generation_file_count}" == "152" ]] || return 2
      if [[ "${generation_file_count}" == "30" ||
            "${generation_file_count}" == "152" ]]; then
        include_bundle=Y
        order_class=reader-isolated
      fi
    elif [[ "${source_schema}" == "2" &&
            "${implementation}" == "amaru" ]]; then
      :
    elif [[ "${source_schema}" != "1" ]]; then
      return 2
    fi
    if [[ "${source_shape}" == "dirty" ]]; then
      source_dirty=true
      source_mode=local
    elif [[ "${source_shape}" != "clean" ]]; then
      return 2
    fi
    if [[ "${implementation}" == "amaru" ]]; then
      metrics_provider=otel
      n2c=false
      local_cli=false
      forging=false
      network=preview
    elif [[ "${implementation}" == "dingo" ]]; then
      network=preprod
    fi
    build_host_file_inventory "${implementation}" "${network}" \
      "${generation_id}" "${include_bundle}" "${order_class}"
    expected_file_count="$(jq -er 'length' "${host_files_json}")"
    jq -n --argjson schema_version "${source_schema}" \
      --arg implementation "${implementation}" --arg revision "${revision}" \
      --arg network "${network}" \
      --arg source_mode "${source_mode}" --argjson dirty "${source_dirty}" \
      --arg tree_digest "${tree_digest}" --arg id "${generation_id}" \
      --arg version "${generation_version}" \
      --arg manifest_hash "${manifest_hash}" \
      --arg generation_receipt_hash "${generation_receipt_hash}" \
      --argjson generation_file_count "${generation_file_count}" \
      --argjson has_generation "${has_generation}" \
      --slurpfile files "${host_files_json}" '{
        schemaVersion: $schema_version,
        implementation: $implementation,
        network: $network,
        source: ({
          repository: "cardano-community/guild-operators",
          channel: "master", ref: "refs/heads/master",
          revision: $revision, mode: $source_mode, dirty: $dirty
        } + if $dirty then {treeDigest: $tree_digest} else {} end)
      } + if $has_generation then {
        cntoolsGeneration: {
          schemaVersion: 1, id: $id, version: $version,
          path: ("scripts/.cntools/generations/" + $id),
          payloadManifest: ("scripts/.cntools/generations/" + $id +
            "/cntools/manifest.json"),
          payloadManifestSha256: $manifest_hash,
          generationReceipt: ("scripts/.cntools/generations/" + $id +
            "/.generation.json"),
          generationReceiptSha256: $generation_receipt_hash,
          fileCount: $generation_file_count, active: false
        }
      } else {} end + {files: $files[0]}' > "${receipt}"
    receipt_hash="$(sha256sum -- "${receipt}" | awk '{print $1}')"
    jq -n --argjson source_schema "${source_schema}" \
      --arg implementation "${implementation}" --arg revision "${revision}" \
      --arg network "${network}" \
      --arg source_mode "${source_mode}" --argjson dirty "${source_dirty}" \
      --arg tree_digest "${tree_digest}" --arg receipt_hash "${receipt_hash}" \
      --argjson transaction_id_length "${transaction_id_length}" \
      --arg metrics_provider "${metrics_provider}" --argjson n2c "${n2c}" \
      --argjson local_cli "${local_cli}" --argjson metrics "${metrics}" \
      --argjson forging "${forging}" '{
        schemaVersion: 1, deploymentStatus: "deployed",
        implementation: $implementation, network: $network, branch: "master",
        repository: "cardano-community/guild-operators",
        serviceName: $implementation, nodePort: 6000,
        nodeVersion: "", targetNodeVersion: "test-target",
        metricsProvider: $metrics_provider,
        capabilities: {
          n2c: $n2c, localCli: $local_cli,
          metrics: $metrics, forging: $forging
        },
        sourceSchemaVersion: $source_schema, sourceMode: $source_mode,
        sourceRef: "refs/heads/master", sourceRevision: $revision,
        sourceDirty: $dirty,
        payloadReceipt: ".guild-source-receipt.json",
        payloadReceiptSha256: $receipt_hash,
        transactionId: $receipt_hash[0:$transaction_id_length]
      } + if $dirty then {sourceTreeDigest: $tree_digest} else {} end' > \
      "${metadata}"
    chmod 0644 "${receipt}" "${metadata}"
    jq -e --argjson source_schema "${source_schema}" \
      --argjson has_generation "${has_generation}" \
      --argjson dirty "${source_dirty}" \
      --argjson count "${expected_file_count}" '
        .schemaVersion == $source_schema and (.files | length) == $count and
        (if $has_generation then
          keys == ["cntoolsGeneration","files","implementation","network",
            "schemaVersion","source"]
         else
          keys == ["files","implementation","network","schemaVersion","source"]
         end) and
        (.source | keys) ==
          (if $dirty then
             ["channel","dirty","mode","ref","repository","revision","treeDigest"]
           else ["channel","dirty","mode","ref","repository","revision"] end)
      ' "${receipt}" >/dev/null || return 2
    jq -e --argjson dirty "${source_dirty}" '
      (keys - ["sourceTreeDigest"]) == ["branch","capabilities",
        "deploymentStatus","implementation","metricsProvider","network",
        "nodePort","nodeVersion","payloadReceipt","payloadReceiptSha256",
        "repository","schemaVersion","serviceName","sourceDirty","sourceMode",
        "sourceRef","sourceRevision","sourceSchemaVersion","targetNodeVersion",
        "transactionId"] and
      (if $dirty then has("sourceTreeDigest") else
         (has("sourceTreeDigest") | not) end)
    ' "${metadata}" >/dev/null || return 2
  }

  refresh_host_receipt_hash() {
    local transaction_id_length=""
    transaction_id_length="$(jq -er '.transactionId | length' "${metadata}")"
    receipt_hash="$(sha256sum -- "${receipt}" | awk '{print $1}')"
    jq --arg hash "${receipt_hash}" \
      --argjson length "${transaction_id_length}" '
      .payloadReceiptSha256 = $hash |
      .transactionId = $hash[0:$length]
    ' "${metadata}" > "${metadata}.tmp"
    mv -f -- "${metadata}.tmp" "${metadata}"
    chmod 0644 "${metadata}"
  }

  save_host_authority() {
    cp -- "${receipt}" "${authority_receipt_saved}"
    cp -- "${metadata}" "${authority_metadata_saved}"
  }

  restore_host_authority() {
    cp -- "${authority_receipt_saved}" "${receipt}"
    cp -- "${authority_metadata_saved}" "${metadata}"
    chmod 0644 "${receipt}" "${metadata}"
  }

  assert_currentness_rejected() {
    local context="$1"
    if deployment_payload_is_current; then
      fail "payload currentness accepted ${context}"
    fi
  }

  assert_receipt_mutation_rejected() {
    local context="$1"
    local filter="$2"
    save_host_authority
    jq "${filter}" "${receipt}" > "${receipt}.tmp"
    mv -f -- "${receipt}.tmp" "${receipt}"
    chmod 0644 "${receipt}"
    refresh_host_receipt_hash
    assert_currentness_rejected "${context}"
    restore_host_authority
  }

  assert_metadata_mutation_rejected() {
    local context="$1"
    local filter="$2"
    save_host_authority
    jq "${filter}" "${metadata}" > "${metadata}.tmp"
    mv -f -- "${metadata}.tmp" "${metadata}"
    chmod 0644 "${metadata}"
    assert_currentness_rejected "${context}"
    restore_host_authority
  }

  assert_profile_count_closed() {
    local context="$1"
    assert_receipt_mutation_rejected "truncated ${context} inventory" \
      '.files = .files[:-1]'
    assert_receipt_mutation_rejected "extra ${context} inventory" \
      '.files += [.files[0]]'
  }

  mkdir -p -- "${node_root}/files" "${cntools_root}/generations"
  chmod 0700 "${cntools_root}" "${cntools_root}/generations"
  candidate_id="$(build_currentness_generation candidate-b)"
  active_id="$(build_currentness_generation active-a)"
  schema2_id="$(build_currentness_generation schema2-a 2)"
  schema1_id="$(build_currentness_generation schema1-a 1)"
  missing_module_schema_id="$(build_currentness_generation \
    schema3-missing-module-schema 3 missing)"
  wrong_module_schema_id="$(build_currentness_generation \
    schema3-wrong-module-schema 3 wrong)"
  jq -e '.schemaVersion == 3 and .moduleApiVersion == 1 and
    .moduleSchemaVersion == 2 and (.files | length == 151)' \
    "${cntools_root}/generations/${candidate_id}/cntools/manifest.json" \
    >/dev/null || fail 'currentness schema-3 manifest fixture is not 3/151'
  jq -e '.schemaVersion == 3 and (.files | length == 152)' \
    "${cntools_root}/generations/${candidate_id}/.generation.json" \
    >/dev/null || fail 'currentness schema-3 receipt fixture is not 3/152'
  NODE_HOME="${node_root}"
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library"

  # The outer receipt inventory is a closed source-manifest expansion, not a
  # cardinality hint. Schema 1 and schema-2 fileCount20 predate the public
  # ten-member legacy bundle; fileCount30/152 include it before ordinary rows.
  write_host_authority cnode 1 '' clean 16
  deployment_payload_is_current ||
    fail 'valid schema-1 cnode38 authority with legacy 16-hex txid was not current'
  write_host_authority cnode 1 '' clean 24
  deployment_payload_is_current ||
    fail 'valid schema-1 cnode38 authority with 24-hex txid was not current'
  assert_profile_count_closed 'schema-1 cnode38'
  write_host_authority cnode 1 '' dirty 24
  deployment_payload_is_current ||
    fail 'valid dirty schema-1 source7/metadata21 authority was not current'
  write_host_authority dingo 1 '' clean 24
  deployment_payload_is_current ||
    fail 'valid schema-1 Dingo15 authority was not current'
  assert_profile_count_closed 'schema-1 Dingo15'
  write_host_authority amaru 1 '' clean 24
  deployment_payload_is_current ||
    fail 'valid schema-1 Amaru12 authority was not current'
  assert_profile_count_closed 'schema-1 Amaru12'

  write_host_authority cnode 2 "${schema1_id}" clean 24
  deployment_payload_is_current ||
    fail 'valid schema-2 cnode38/fileCount20 authority was not current'
  assert_profile_count_closed 'schema-2 cnode38/fileCount20'
  write_host_authority cnode 2 "${schema2_id}" clean 24
  deployment_payload_is_current ||
    fail 'valid schema-2 cnode48/fileCount30 authority was not current'
  assert_profile_count_closed 'schema-2 cnode48/fileCount30'
  write_host_authority cnode 2 "${candidate_id}" clean 24
  deployment_payload_is_current ||
    fail 'valid schema-2 cnode48/fileCount152 authority was not current'
  assert_profile_count_closed 'schema-2 cnode48/fileCount152'
  write_host_authority dingo 2 "${schema1_id}" clean 24
  deployment_payload_is_current ||
    fail 'valid schema-2 Dingo15/fileCount20 authority was not current'
  assert_profile_count_closed 'schema-2 Dingo15/fileCount20'
  write_host_authority dingo 2 "${schema2_id}" clean 24
  deployment_payload_is_current ||
    fail 'valid schema-2 Dingo25/fileCount30 authority was not current'
  assert_profile_count_closed 'schema-2 Dingo25/fileCount30'
  write_host_authority dingo 2 "${candidate_id}" clean 24
  deployment_payload_is_current ||
    fail 'valid schema-2 Dingo25/fileCount152 authority was not current'
  assert_profile_count_closed 'schema-2 Dingo25/fileCount152'
  write_host_authority amaru 2 '' clean 24
  deployment_payload_is_current ||
    fail 'valid schema-2 Amaru12 authority without generation was not current'
  assert_profile_count_closed 'schema-2 Amaru12'

  write_host_authority cnode 2 "${candidate_id}" clean 24

  jq '.cntoolsGeneration.fileCount = 30' "${receipt}" > "${receipt}.tmp"
  mv -f -- "${receipt}.tmp" "${receipt}"
  refresh_host_receipt_hash
  if deployment_payload_is_current; then
    fail 'schema-3 generation receipt was accepted with host fileCount 30'
  fi
  write_host_authority cnode 2 "${candidate_id}" clean 24

  write_host_authority cnode 2 "${schema2_id}" clean 24
  deployment_payload_is_current ||
    fail 'valid nested schema-2 payload29/receipt30 was not current'
  jq '.cntoolsGeneration.fileCount = 152' "${receipt}" > "${receipt}.tmp"
  mv -f -- "${receipt}.tmp" "${receipt}"
  refresh_host_receipt_hash
  if deployment_payload_is_current; then
    fail 'schema-2 generation receipt was accepted with host fileCount 152'
  fi

  write_host_authority cnode 2 "${schema1_id}" clean 24
  deployment_payload_is_current ||
    fail 'valid nested schema-1 payload/receipt 19/20 was not current'
  jq '.cntoolsGeneration.fileCount = 30' "${receipt}" > "${receipt}.tmp"
  mv -f -- "${receipt}.tmp" "${receipt}"
  refresh_host_receipt_hash
  if deployment_payload_is_current; then
    fail 'schema-1 generation receipt was accepted with host fileCount 30'
  fi

  write_host_authority cnode 2 "${missing_module_schema_id}" clean 24
  if deployment_payload_is_current; then
    fail 'schema-3 payload without moduleSchemaVersion was current'
  fi
  write_host_authority cnode 2 "${wrong_module_schema_id}" clean 24
  if deployment_payload_is_current; then
    fail 'schema-3 payload with wrong moduleSchemaVersion was current'
  fi
  write_host_authority cnode 2 "${candidate_id}" clean 24

  # Transaction IDs are receipt-hash prefixes keyed to the outer receipt
  # schema. Legacy schema 1 accepts only 16 or 24 hex characters; schema 2 is
  # exactly 24, irrespective of the nested generation schema or file count.
  write_host_authority cnode 1 '' clean 24
  for transaction_id_length in 15 {17..23} {25..64}; do
    assert_metadata_mutation_rejected \
      "schema-1 transactionId length ${transaction_id_length}" \
      ".transactionId = .payloadReceiptSha256[0:${transaction_id_length}]"
  done
  assert_metadata_mutation_rejected 'schema-1 transactionId length 65' \
    '.transactionId = (.payloadReceiptSha256 + "0")'
  assert_metadata_mutation_rejected 'schema-1 non-prefix transactionId' \
    '.transactionId = ("0" * 24)'
  write_host_authority cnode 2 "${candidate_id}" clean 24
  for transaction_id_length in {15..23} {25..64}; do
    assert_metadata_mutation_rejected \
      "schema-2 transactionId length ${transaction_id_length}" \
      ".transactionId = .payloadReceiptSha256[0:${transaction_id_length}]"
  done
  assert_metadata_mutation_rejected 'schema-2 transactionId length 65' \
    '.transactionId = (.payloadReceiptSha256 + "0")'
  assert_metadata_mutation_rejected 'schema-2 non-prefix transactionId' \
    '.transactionId = ("0" * 24)'
  write_host_authority cnode 2 "${schema1_id}" clean 24
  assert_metadata_mutation_rejected \
    'schema-2/fileCount20 legacy 16-hex transactionId' \
    '.transactionId = .payloadReceiptSha256[0:16]'
  write_host_authority cnode 2 "${schema2_id}" clean 24
  assert_metadata_mutation_rejected \
    'schema-2/fileCount30 legacy 16-hex transactionId' \
    '.transactionId = .payloadReceiptSha256[0:16]'
  write_host_authority cnode 2 "${candidate_id}" clean 24

  # Receipt, source, metadata, and file-record objects are closed shapes.
  assert_receipt_mutation_rejected 'extra receipt root key' \
    '.unexpected = true'
  assert_receipt_mutation_rejected 'missing receipt root key' \
    'del(.network)'
  assert_receipt_mutation_rejected 'extra source key' \
    '.source.unexpected = true'
  assert_receipt_mutation_rejected 'missing source key' \
    'del(.source.ref)'
  assert_receipt_mutation_rejected 'extra generation authority key' \
    '.cntoolsGeneration.unexpected = true'
  assert_receipt_mutation_rejected 'missing generation authority key' \
    'del(.cntoolsGeneration.version)'
  assert_receipt_mutation_rejected 'extra file-record key' \
    '.files[0].unexpected = true'
  assert_receipt_mutation_rejected 'missing file-record key' \
    'del(.files[0].source)'
  assert_metadata_mutation_rejected 'extra metadata key' \
    '.unexpected = true'
  assert_metadata_mutation_rejected 'missing metadata key' \
    'del(.nodePort)'
  assert_receipt_mutation_rejected 'treeDigest on a clean receipt source' \
    '.source.treeDigest = ("b" * 64)'
  assert_metadata_mutation_rejected 'sourceTreeDigest on clean metadata' \
    '.sourceTreeDigest = ("b" * 64)'

  write_host_authority cnode 2 "${candidate_id}" dirty 24
  deployment_payload_is_current ||
    fail 'valid dirty source7/metadata21 authority was not current'
  assert_receipt_mutation_rejected 'dirty receipt without treeDigest' \
    'del(.source.treeDigest)'
  assert_metadata_mutation_rejected 'dirty metadata without sourceTreeDigest' \
    'del(.sourceTreeDigest)'
  assert_metadata_mutation_rejected 'dirty metadata tree digest mismatch' \
    '.sourceTreeDigest = ("c" * 64)'
  save_host_authority
  jq '.source.mode = "managed"' "${receipt}" > "${receipt}.tmp"
  mv -f -- "${receipt}.tmp" "${receipt}"
  chmod 0644 "${receipt}"
  jq '.sourceMode = "managed"' "${metadata}" > "${metadata}.tmp"
  mv -f -- "${metadata}.tmp" "${metadata}"
  chmod 0644 "${metadata}"
  refresh_host_receipt_hash
  assert_currentness_rejected 'self-consistent dirty managed source mode'
  restore_host_authority
  write_host_authority cnode 2 "${candidate_id}" clean 24

  # Authority files themselves are confined regular files owned by the reader
  # and fixed at 0644. Root-only CI additionally exercises negative ownership.
  [[ -O "${receipt}" && -O "${metadata}" ]] ||
    fail 'valid outer authority files are not owned by the test user'
  chmod 0600 "${receipt}"
  assert_currentness_rejected 'receipt mode 0600'
  chmod 0644 "${receipt}"
  chmod 0600 "${metadata}"
  assert_currentness_rejected 'metadata mode 0600'
  chmod 0644 "${metadata}"
  save_host_authority
  rm -- "${receipt}"
  ln -s "${authority_receipt_saved}" "${receipt}"
  assert_currentness_rejected 'symlink receipt authority'
  rm -- "${receipt}"
  restore_host_authority
  save_host_authority
  rm -- "${metadata}"
  ln -s "${authority_metadata_saved}" "${metadata}"
  assert_currentness_rejected 'symlink metadata authority'
  rm -- "${metadata}"
  restore_host_authority
  if (( EUID == 0 )) && command -v chown >/dev/null 2>&1; then
    original_owner="$(stat -f '%u:%g' "${receipt}" 2>/dev/null ||
      stat -c '%u:%g' "${receipt}")"
    chown 65534:65534 "${receipt}"
    assert_currentness_rejected 'non-owner receipt authority'
    chown "${original_owner}" "${receipt}"
    original_owner="$(stat -f '%u:%g' "${metadata}" 2>/dev/null ||
      stat -c '%u:%g' "${metadata}")"
    chown 65534:65534 "${metadata}"
    assert_currentness_rejected 'non-owner metadata authority'
    chown "${original_owner}" "${metadata}"
  fi

  # A durable outer journal invalidates an otherwise coherent authority pair
  # for every supported profile, including receipts without a generation.
  write_host_authority cnode 1 '' clean 24
  printf 'interrupted schema-1 transaction\n' > \
    "${node_root}/.guild-deploy-transaction"
  assert_currentness_rejected 'schema-1 outer transaction journal'
  rm -- "${node_root}/.guild-deploy-transaction"
  write_host_authority amaru 2 '' clean 24
  mkdir -- "${node_root}/.guild-deploy-transaction"
  assert_currentness_rejected 'Amaru outer transaction journal'
  rmdir -- "${node_root}/.guild-deploy-transaction"
  write_host_authority cnode 2 "${candidate_id}" clean 24
  ln -s "${suite_root}" "${node_root}/.guild-deploy-transaction"
  assert_currentness_rejected 'symlink outer transaction journal'
  rm -- "${node_root}/.guild-deploy-transaction"

  # Exact counts cannot be satisfied by omissions, duplicate unmanaged
  # padding, invented operator files, or a count-preserving bundle substitute.
  assert_receipt_mutation_rejected \
    'truncated cnode47 inventory omitting scripts/guild-deploy.sh' \
    'del(.files[] | select(.path == "scripts/guild-deploy.sh"))'
  assert_receipt_mutation_rejected 'extra cnode49 inventory record' \
    '.files += [.files[0]]'
  assert_receipt_mutation_rejected 'reordered exact inventory records' \
    '.files |= reverse'
  assert_receipt_mutation_rejected \
    'duplicate unmanaged padding replacing scripts/guild-deploy.sh' '
      .files = ((.files | map(select(.path != "scripts/guild-deploy.sh"))) +
        [(.files[] | select(.path == "files/config.json"))])
    '
  fake_target="${node_root}/files/fake-operator.json"
  printf 'invented unmanaged outer record\n' > "${fake_target}"
  chmod 0644 "${fake_target}"
  fake_hash="$(sha256sum -- "${fake_target}" | awk '{print $1}')"
  save_host_authority
  jq --arg hash "${fake_hash}" '
    .files = ((.files | map(select(.path != "scripts/guild-deploy.sh"))) + [{
      path: "files/fake-operator.json",
      source: "files/configs/cnode/mainnet/fake-operator.json",
      mode: "0644", policy: "operator-preserved",
      sourceSha256: $hash, installedSha256: $hash, managed: false
    }])
  ' "${receipt}" > "${receipt}.tmp"
  mv -f -- "${receipt}.tmp" "${receipt}"
  chmod 0644 "${receipt}"
  refresh_host_receipt_hash
  assert_currentness_rejected \
    'count-preserving fake unique unmanaged inventory path'
  restore_host_authority
  rm -- "${fake_target}"

  bundle_path="$(jq -er '
    first(.files[] | select(.policy == "cntools-legacy-bundle") | .path)
  ' "${receipt}")"
  bundle_source="$(jq -er --arg path "${bundle_path}" '
    .files[] | select(.path == $path) | .source
  ' "${receipt}")"
  fake_bundle_path="${bundle_path%/*}/forged.library"
  fake_bundle_source="${bundle_source%/*}/forged.library"
  fake_target="${node_root}/${fake_bundle_path}"
  chmod 0755 "$(dirname -- "${fake_target}")"
  cp -- "${node_root}/${bundle_path}" "${fake_target}"
  chmod 0444 "${fake_target}"
  chmod 0555 "$(dirname -- "${fake_target}")"
  save_host_authority
  jq --arg old_path "${bundle_path}" --arg path "${fake_bundle_path}" \
    --arg source "${fake_bundle_source}" '
      (.files[] | select(.path == $old_path) | .path) = $path |
      (.files[] | select(.path == $path) | .source) = $source
    ' "${receipt}" > "${receipt}.tmp"
  mv -f -- "${receipt}.tmp" "${receipt}"
  chmod 0644 "${receipt}"
  refresh_host_receipt_hash
  assert_currentness_rejected 'count-preserving legacy bundle member substitute'
  restore_host_authority
  chmod 0755 "$(dirname -- "${fake_target}")"
  rm -- "${fake_target}"
  chmod 0555 "$(dirname -- "${fake_target}")"

  # Every path/source is the exact confined source-manifest spelling, and
  # modes, policies, and ownership classification are bound to that path.
  assert_receipt_mutation_rejected 'dot-component receipt path' \
    '.files[0].path = ("./" + .files[0].path)'
  assert_receipt_mutation_rejected 'traversal receipt path' \
    '.files[0].path = ("../" + .files[0].path)'
  assert_receipt_mutation_rejected 'dot-component receipt source' \
    '.files[0].source = ("./" + .files[0].source)'
  assert_receipt_mutation_rejected 'traversal receipt source' \
    '.files[0].source = ("../" + .files[0].source)'
  save_host_authority
  chmod 0755 "${node_root}/scripts/lib/deployment.library"
  jq '(.files[] | select(.path == "scripts/lib/deployment.library") |
      .mode) = "0755"' "${receipt}" > "${receipt}.tmp"
  mv -f -- "${receipt}.tmp" "${receipt}"
  chmod 0644 "${receipt}"
  refresh_host_receipt_hash
  assert_currentness_rejected 'self-consistent wrong mode for deployment.library'
  chmod 0644 "${node_root}/scripts/lib/deployment.library"
  restore_host_authority
  assert_receipt_mutation_rejected 'wrong policy for deployment.library' '
    (.files[] | select(.path == "scripts/lib/deployment.library") |
      .policy) = "merge-header"
  '
  assert_receipt_mutation_rejected 'managed=false on an exact library' '
    (.files[] | select(.path == "scripts/lib/deployment.library") |
      .managed) = false
  '
  assert_receipt_mutation_rejected 'managed=true on a rendered config' '
    (.files[] | select(.path == "files/config.json") | .managed) = true
  '
  save_host_authority
  chmod 0600 "${node_root}/files/config.json"
  jq '(.files[] | select(.path == "files/config.json") | .mode) = "0600"' \
    "${receipt}" > "${receipt}.tmp"
  mv -f -- "${receipt}.tmp" "${receipt}"
  chmod 0644 "${receipt}"
  refresh_host_receipt_hash
  assert_currentness_rejected 'render-cnode config with non-manifest mode 0600'
  chmod 0644 "${node_root}/files/config.json"
  restore_host_authority

  # Known preserve-render targets may retain operator bytes, but their receipt
  # path, physical type, ownership, recorded mode, and installed hash remain
  # mandatory. No arbitrary path inherits this content-freshness exemption.
  config_target="${node_root}/files/config.json"
  printf '{"operator":"preserved-currentness-fixture"}\n' > "${config_target}"
  chmod 0600 "${config_target}"
  config_hash="$(sha256sum -- "${config_target}" | awk '{print $1}')"
  jq --arg hash "${config_hash}" '
    (.files[] | select(.path == "files/config.json")) |=
      (.policy = "operator-preserved" | .mode = "0600" |
       .installedSha256 = $hash | .managed = false)
  ' "${receipt}" > "${receipt}.tmp"
  mv -f -- "${receipt}.tmp" "${receipt}"
  chmod 0644 "${receipt}"
  refresh_host_receipt_hash
  deployment_payload_is_current ||
    fail 'legitimate known operator-preserved config bytes were not current'
  cp -- "${config_target}" "${suite_root}/operator-authority.saved"
  printf '{"operator":"edited-after-receipt"}\n' > "${config_target}"
  chmod 0600 "${config_target}"
  deployment_payload_is_current ||
    fail 'known operator-preserved post-receipt byte edit was not current'
  cp -- "${suite_root}/operator-authority.saved" "${config_target}"
  chmod 0600 "${config_target}"
  save_host_authority
  chmod 0666 "${config_target}"
  jq '(.files[] | select(.path == "files/config.json") | .mode) = "0666"' \
    "${receipt}" > "${receipt}.tmp"
  mv -f -- "${receipt}.tmp" "${receipt}"
  chmod 0644 "${receipt}"
  refresh_host_receipt_hash
  assert_currentness_rejected \
    'self-consistent peer-writable operator-preserved config mode 0666'
  chmod 0600 "${config_target}"
  restore_host_authority
  cp -- "${config_target}" "${suite_root}/config.saved"
  rm -- "${config_target}"
  assert_currentness_rejected 'missing required operator-preserved config'
  cp -- "${suite_root}/config.saved" "${config_target}"
  chmod 0600 "${config_target}"
  : > "${config_target}"
  chmod 0600 "${config_target}"
  assert_currentness_rejected 'empty operator-preserved config leaf'
  cp -- "${suite_root}/config.saved" "${config_target}"
  chmod 0600 "${config_target}"
  chmod 0644 "${config_target}"
  assert_currentness_rejected 'operator-preserved config mode mismatch'
  chmod 0600 "${config_target}"
  rm -- "${config_target}"
  ln -s "${suite_root}/config.saved" "${config_target}"
  assert_currentness_rejected 'operator-preserved config leaf symlink'
  rm -- "${config_target}"
  cp -- "${suite_root}/config.saved" "${config_target}"
  chmod 0600 "${config_target}"

  if (( EUID == 0 )) && command -v chown >/dev/null 2>&1; then
    original_owner="$(stat -f '%u:%g' "${config_target}" 2>/dev/null ||
      stat -c '%u:%g' "${config_target}")"
    chown 65534:65534 "${config_target}"
    assert_currentness_rejected 'non-owner operator-preserved config leaf'
    chown "${original_owner}" "${config_target}"
    managed_target="${node_root}/scripts/guild-deploy.sh"
    original_owner="$(stat -f '%u:%g' "${managed_target}" 2>/dev/null ||
      stat -c '%u:%g' "${managed_target}")"
    chown 65534:65534 "${managed_target}"
    assert_currentness_rejected 'non-owner managed payload leaf'
    chown "${original_owner}" "${managed_target}"
  fi

  mv -- "${node_root}/files" "${suite_root}/outer-files.saved"
  ln -s "${suite_root}/outer-files.saved" "${node_root}/files"
  assert_currentness_rejected 'operator-preserved path through ancestor symlink'
  rm -- "${node_root}/files"
  mv -- "${suite_root}/outer-files.saved" "${node_root}/files"
  mv -- "${node_root}/scripts/lib" "${suite_root}/outer-lib.saved"
  ln -s "${suite_root}/outer-lib.saved" "${node_root}/scripts/lib"
  assert_currentness_rejected 'managed path through ancestor symlink'
  rm -- "${node_root}/scripts/lib"
  mv -- "${suite_root}/outer-lib.saved" "${node_root}/scripts/lib"

  # The last declared managed row must be visited; no short/off-by-one walk may
  # validate a receipt after an otherwise self-consistent authority check.
  managed_path="$(jq -er '[.files[] | select(.managed == true)][-1].path' \
    "${receipt}")"
  managed_target="${node_root}/${managed_path}"
  cp -- "${managed_target}" "${suite_root}/last-managed.saved"
  chmod u+w "${managed_target}"
  printf '\ntampered last managed row\n' >> "${managed_target}"
  assert_currentness_rejected 'tampered final managed inventory row'
  cp -- "${suite_root}/last-managed.saved" "${managed_target}"
  chmod "$(jq -er --arg path "${managed_path}" '
    .files[] | select(.path == $path) | .mode
  ' "${receipt}")" "${managed_target}"

  write_host_authority cnode 2 "${candidate_id}" clean 24

  # Generation authority is validated before sourcing lifecycle code. The
  # private state/generations roots are 0700; generation/all descendant
  # directories are 0555. The executable cntools.sh entrypoint is the sole
  # 0555 manifest member; the other 150 members and generation receipt are
  # 0444, including the manifest and lifecycle trust anchors.
  generation="${cntools_root}/generations/${candidate_id}"
  generation_manifest="${generation}/cntools/manifest.json"
  generation_receipt="${generation}/.generation.json"
  lifecycle="${generation}/cntools/core/lifecycle.sh"
  [[ "$(runtime_stat_mode "${cntools_root}")" == "700" &&
     "$(runtime_stat_mode "${cntools_root}/generations")" == "700" ]] ||
    fail 'valid CNTools state roots are not mode 0700'
  while IFS= read -r directory; do
    [[ "$(runtime_stat_mode "${directory}")" == "555" ]] ||
      fail "valid generation directory is not mode 0555: ${directory}"
  done < <(find "${generation}" -type d -print)
  jq -e '
    (.files | length == 151) and
    ([.files[] | select(.mode == "0555") | .path] == ["cntools.sh"]) and
    ([.files[] | select(.mode == "0444")] | length == 150)
  ' "${generation_manifest}" >/dev/null ||
    fail 'valid Stage 3 manifest file-mode inventory is not 150:1'
  while IFS= read -r target_file; do
    if [[ "${target_file}" == "${generation}/cntools.sh" ]]; then
      [[ "$(runtime_stat_mode "${target_file}")" == "555" ]] ||
        fail "valid generation entrypoint is not mode 0555: ${target_file}"
    else
      [[ "$(runtime_stat_mode "${target_file}")" == "444" ]] ||
        fail "valid generation control/data file is not mode 0444: ${target_file}"
    fi
  done < <(find "${generation}" -type f -print)
  chmod 0755 "${cntools_root}"
  assert_currentness_rejected 'CNTools state-root mode 0755'
  chmod 0700 "${cntools_root}"
  chmod 0755 "${cntools_root}/generations"
  assert_currentness_rejected 'CNTools generations-root mode 0755'
  chmod 0700 "${cntools_root}/generations"
  chmod 0755 "${generation}"
  assert_currentness_rejected 'generation-root mode 0755'
  chmod 0555 "${generation}"
  chmod 0755 "${generation}/cntools/core"
  assert_currentness_rejected 'generation descendant directory mode 0755'
  chmod 0555 "${generation}/cntools/core"
  chmod 0644 "${generation_manifest}"
  assert_currentness_rejected 'generation manifest mode 0644'
  chmod 0444 "${generation_manifest}"
  chmod 0644 "${generation_receipt}"
  assert_currentness_rejected 'generation receipt mode 0644'
  chmod 0444 "${generation_receipt}"
  chmod 0644 "${lifecycle}"
  assert_currentness_rejected 'generation lifecycle mode 0644'
  chmod 0444 "${lifecycle}"
  if (( EUID == 0 )) && command -v chown >/dev/null 2>&1; then
    original_owner="$(stat -f '%u:%g' "${lifecycle}" 2>/dev/null ||
      stat -c '%u:%g' "${lifecycle}")"
    chown 65534:65534 "${lifecycle}"
    assert_currentness_rejected 'non-owner generation lifecycle leaf'
    chown "${original_owner}" "${lifecycle}"
  fi

  # BSD rename requires the directory entry itself to be owner-writable in
  # addition to its parent; restore both immutable directory modes afterward.
  generation_core_saved="${suite_root}/generation-core.saved.${BASHPID:-$$}.${RANDOM}"
  [[ ! -e "${generation_core_saved}" && ! -L "${generation_core_saved}" &&
     -d "${suite_root}" && ! -L "${suite_root}" && -O "${suite_root}" &&
     -w "${suite_root}" && -x "${suite_root}" ]] ||
    fail 'generation symlink fixture does not have an absent safe save path'
  chmod 0755 "${generation}/cntools" "${generation}/cntools/core"
  mv -- "${generation}/cntools/core" "${generation_core_saved}"
  ln -s "${generation_core_saved}" \
    "${generation}/cntools/core"
  chmod 0555 "${generation}/cntools"
  assert_currentness_rejected 'generation lifecycle through symlink component'
  chmod 0755 "${generation}/cntools"
  rm -- "${generation}/cntools/core"
  mv -- "${generation_core_saved}" "${generation}/cntools/core"
  chmod 0555 "${generation}/cntools/core" "${generation}/cntools"
  [[ ! -e "${generation_core_saved}" && ! -L "${generation_core_saved}" ]] ||
    fail 'generation symlink fixture left its saved path behind'

  # A failed or short producer feeding the final file walk must not disappear
  # behind process-substitution status semantics. This PATH executable is the
  # jq resolved by currentness and faults only the installed-file TSV query.
  real_jq="$(command -v jq)"
  fault_bin="${suite_root}/fault-bin"
  fault_jq="${fault_bin}/jq"
  mkdir -- "${fault_bin}"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '%s\n' 'inventory_query=N' 'for argument in "$@"; do'
    printf '%s\n' \
      '  if [[ "${argument}" == *".installedSha256"* && "${argument}" == *"@tsv"* ]]; then' \
      '    inventory_query=Y' '  fi' 'done'
    printf '%s\n' 'if [[ "${inventory_query}" == Y ]]; then' \
      '  case "${CURRENTNESS_JQ_FAULT:-}" in' \
      '    empty) exit 0 ;;' \
      '    short)' \
      '      "${CURRENTNESS_REAL_JQ}" "$@" | awk '\''NR == 1 { print; exit }'\'''
    printf '%s\n' '      exit 42' '      ;;' \
      '    journal) mkdir -- "${CURRENTNESS_NODE_ROOT}/.guild-deploy-transaction" ;;' \
      '  esac' 'fi' 'exec "${CURRENTNESS_REAL_JQ}" "$@"'
  } > "${fault_jq}"
  chmod 0755 "${fault_jq}"
  saved_path="${PATH}"
  PATH="${fault_bin}:${PATH}"
  export PATH CURRENTNESS_REAL_JQ="${real_jq}" \
    CURRENTNESS_NODE_ROOT="${node_root}"
  CURRENTNESS_JQ_FAULT=empty
  export CURRENTNESS_JQ_FAULT
  assert_currentness_rejected 'zero-row successful final inventory producer'
  CURRENTNESS_JQ_FAULT=short
  export CURRENTNESS_JQ_FAULT
  assert_currentness_rejected 'short failing final inventory producer'
  CURRENTNESS_JQ_FAULT=journal
  export CURRENTNESS_JQ_FAULT
  assert_currentness_rejected \
    'outer journal appearing during final inventory validation'
  rmdir -- "${node_root}/.guild-deploy-transaction"
  PATH="${saved_path}"
  export PATH
  unset CURRENTNESS_JQ_FAULT CURRENTNESS_REAL_JQ CURRENTNESS_NODE_ROOT

  ln -s "generations/${active_id}" "${cntools_root}/active"
  deployment_payload_is_current ||
    fail 'candidate B was not current while retained generation A was active'

  lifecycle="${cntools_root}/generations/${candidate_id}/cntools/core/lifecycle.sh"
  # shellcheck source=/dev/null
  . "${lifecycle}"
  cntools_generation_pointers_validate "${cntools_root}" ||
    fail 'valid retained-active pointer state failed direct validation'

  # Currentness is read-only and the shared lock is a NODE_HOME child, so a
  # deployment whose scripts directory is not writable must still validate.
  chmod 0555 "${node_root}/scripts"
  before="${suite_root}/readonly.before"
  after="${suite_root}/readonly.after"
  runtime_tree_state "${node_root}" "${before}"
  deployment_payload_is_current || {
    chmod 0755 "${node_root}/scripts"
    fail 'payload currentness required a writable scripts directory'
  }
  assert_runtime_tree_unchanged "${node_root}" "${before}" "${after}" \
    'read-only payload currentness'
  chmod 0755 "${node_root}/scripts"

  # A canary transaction journal makes even individually valid half-switched
  # pointers unsettled. Neither direct lifecycle validation nor host receipt
  # currentness may repair or otherwise mutate that state.
  rm -- "${cntools_root}/active"
  ln -s "generations/${candidate_id}" "${cntools_root}/active"
  ln -s "generations/${active_id}" "${cntools_root}/previous"
  printf 'schemaVersion=1\nactive=%s\nprevious=absent\n' "${active_id}" > \
    "${cntools_root}/.generation-transaction"
  chmod 0600 "${cntools_root}/.generation-transaction"
  before="${suite_root}/half-switched.before"
  after="${suite_root}/half-switched.after"
  runtime_tree_state "${node_root}" "${before}"
  if cntools_generation_pointers_validate "${cntools_root}"; then
    fail 'pointer validation accepted a half-switched canary transaction'
  fi
  if deployment_payload_is_current; then
    fail 'payload currentness accepted a half-switched canary transaction'
  fi
  assert_runtime_tree_unchanged "${node_root}" "${before}" "${after}" \
    'half-switched canary refusal'
  rm -- "${cntools_root}/.generation-transaction" \
    "${cntools_root}/active" "${cntools_root}/previous"
  ln -s "generations/${active_id}" "${cntools_root}/active"

  # Every reserved transaction/pointer temporary is fail-closed. These cases
  # also prove that validation never opportunistically deletes ambiguous state.
  for artifact_name in \
    .generation-transaction.new.fixture \
    .active.fixture \
    .previous.fixture; do
    artifact="${cntools_root}/${artifact_name}"
    case "${artifact_name}" in
      .generation-transaction.new.fixture)
        printf 'schemaVersion=1\nactive=%s\nprevious=absent\n' \
          "${active_id}" > "${artifact}"
        chmod 0600 "${artifact}"
        ;;
      *) ln -s "generations/${active_id}" "${artifact}" ;;
    esac
    before="${suite_root}/${artifact_name}.before"
    after="${suite_root}/${artifact_name}.after"
    runtime_tree_state "${node_root}" "${before}"
    if cntools_generation_pointers_validate "${cntools_root}"; then
      fail "pointer validation accepted reserved temporary ${artifact_name}"
    fi
    if deployment_payload_is_current; then
      fail "payload currentness accepted reserved temporary ${artifact_name}"
    fi
    assert_runtime_tree_unchanged "${node_root}" "${before}" "${after}" \
      "reserved temporary ${artifact_name} refusal"
    rm -- "${artifact}"
  done

  # The advisory lock is outside NODE_HOME. A live lifecycle owner excludes a
  # second shell and receipt currentness without mutating the target tree.
  cntools_generation_lock_acquire "${cntools_root}" ||
    fail 'could not acquire lifecycle lock for two-contender fixture'
  before="${suite_root}/live-advisory-lock.before"
  after="${suite_root}/live-advisory-lock.after"
  runtime_tree_state "${node_root}" "${before}"
  if "${BASH}" -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    . "$1"
    cntools_generation_pointers_validate "$2"
  ' bash "${lifecycle}" "${cntools_root}" >/dev/null 2>&1; then
    cntools_generation_lock_release "${cntools_root}" || true
    fail 'a second lifecycle contender acquired the live advisory lock'
  fi
  if deployment_payload_is_current; then
    cntools_generation_lock_release "${cntools_root}" || true
    fail 'payload currentness bypassed a live advisory lock'
  fi
  assert_runtime_tree_unchanged "${node_root}" "${before}" "${after}" \
    'live advisory-lock refusal'
  cntools_generation_lock_release "${cntools_root}" ||
    fail 'could not release lifecycle lock after contention fixture'

  rm -- "${cntools_root}/active"
  ln -s ../../outside-generation "${cntools_root}/active"
  if deployment_payload_is_current; then
    fail 'payload currentness accepted an unsafe active generation pointer'
  fi
  rm -- "${cntools_root}/active"
  ln -s "generations/${active_id}" "${cntools_root}/active"

  for member in lifecycle config registry; do
    case "${member}" in
      lifecycle) tampered="${cntools_root}/generations/${candidate_id}/cntools/core/lifecycle.sh" ;;
      config) tampered="${cntools_root}/generations/${candidate_id}/cntools/core/config.sh" ;;
      registry) tampered="${cntools_root}/generations/${candidate_id}/cntools/core/registry.sh" ;;
    esac
    saved="${suite_root}/${member}.saved"
    sentinel="${suite_root}/${member}.executed"
    cp -- "${tampered}" "${saved}"
    chmod 0644 "${tampered}"
    printf '#!/usr/bin/env bash\nprintf executed > %q\n' "${sentinel}" > "${tampered}"
    if [[ "${member}" == "lifecycle" ]]; then
      printf 'cntools_generation_validate() { return 2; }\n' >> "${tampered}"
    fi
    chmod 0444 "${tampered}"
    if deployment_payload_is_current; then
      fail "payload currentness accepted tampered ${member}.sh"
    fi
    [[ ! -e "${sentinel}" && ! -L "${sentinel}" ]] ||
      fail "payload currentness executed tampered ${member}.sh before validation"
    chmod 0644 "${tampered}"
    cp -- "${saved}" "${tampered}"
    chmod 0444 "${tampered}"
  done
  deployment_payload_is_current ||
    fail 'restored Stage 3 candidate did not return to current'

  # The existing refresh fixtures remain schema 1; retain an explicit direct
  # assertion so Stage 1 cannot accidentally drop that migration contract.
  write_host_authority cnode 1 '' clean 16
  deployment_payload_is_current ||
    fail 'Stage 0 schema 1 receipt compatibility was not retained'
)

case "${GUILD_COMMON_RUNTIME_FOCUS:-}" in
  currentness)
    run_stage1_payload_currentness_tests
    printf 'common runtime payload currentness tests passed\n'
    exit 0
    ;;
  '') ;;
  *) fail "unsupported common-runtime focus: ${GUILD_COMMON_RUNTIME_FOCUS}" ;;
esac

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
run_glive_helper_tests
run_cnode_metrics_url_tests
run_dispatcher_refresh_tests
run_stage1_payload_currentness_tests

printf 'common runtime tests passed\n'
