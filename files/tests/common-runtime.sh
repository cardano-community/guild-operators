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
        localCli: ($implementation != "amaru"),
        metrics: true,
        forging: ($implementation == "cnode" or $implementation == "dingo")
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

printf 'common runtime tests passed\n'
