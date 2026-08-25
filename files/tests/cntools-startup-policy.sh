#!/usr/bin/env bash
# Characterize CNTools startup flags and implementation support policy without
# contacting external services or using a real node installation.
# shellcheck disable=SC1090,SC1091,SC2016,SC2034,SC2154
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'CNTools startup policy tests skipped: Bash 4.4+ is required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SCRIPT="${REPO_ROOT}/scripts/common-helper-scripts/cntools.sh"
CNTOOLS_LIBRARY="${REPO_ROOT}/scripts/common-helper-scripts/cntools.library"
CNTOOLS_LEGACY_BUNDLE_ID="6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59"
COMMON_ENV="${REPO_ROOT}/scripts/common-helper-scripts/env"
# Keep Unix-domain socket fixture paths below the platform length limit even
# when the caller has a deeply nested TMPDIR (notably macOS launchd paths).
TEST_ROOT="$(mktemp -d "/tmp/guild-cntools-policy.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
BASE_PATH="${PATH}"
BASH_BIN="${BASH}"
FAKE_BIN="${TEST_ROOT}/fake-bin"
NETWORK_LOG="${TEST_ROOT}/network.log"
DISPATCH_LOG="${TEST_ROOT}/dispatcher.log"
SIDE_EFFECT_LOG="${TEST_ROOT}/side-effects.log"
CLI_LOG="${TEST_ROOT}/cli.log"
STATE_LOG="${TEST_ROOT}/state.log"
STATE_ENV="${TEST_ROOT}/state-env.sh"
SIGNAL_ENV="${TEST_ROOT}/signal-env.sh"
RUN_COUNTER=0
RUN_STATUS=0
RUN_OUTPUT_FILE=""
RUN_NODE_ADAPTER_PATH=""
ENV_STATUS=0
ENV_OUTPUT_FILE=""

cleanup_test() {
  if [[ "${CNTOOLS_PRESERVE_TEST_ROOT:-N}" == "Y" ]]; then
    printf 'Preserved startup-policy fixture: %s\n' "${TEST_ROOT}" >&2
    return
  fi
  chmod -R u+rwX "${TEST_ROOT}" >/dev/null 2>&1 || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test EXIT

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

assert_contains() {
  local content="$1"
  local expected="$2"
  local context="$3"
  [[ "${content}" == *"${expected}"* ]] ||
    fail "${context}: missing '${expected}'"
}

assert_file_line() {
  local file="$1"
  local expected="$2"
  local context="$3"
  grep -Fqx -- "${expected}" "${file}" ||
    fail "${context}: missing exact line '${expected}' in ${file}"
}

assert_no_network() {
  local context="$1"
  [[ ! -s "${NETWORK_LOG}" ]] ||
    fail "${context}: unexpected intercepted network command: $(< "${NETWORK_LOG}")"
}

reset_logs() {
  : > "${NETWORK_LOG}"
  : > "${DISPATCH_LOG}"
  : > "${SIDE_EFFECT_LOG}"
  : > "${CLI_LOG}"
  : > "${STATE_LOG}"
}

for required_command in awk grep jq python3 sort; do
  command -v "${required_command}" >/dev/null 2>&1 ||
    fail "required command is unavailable: ${required_command}"
done

write_fake_tools() {
  local command_name destination

  mkdir -p "${FAKE_BIN}"
  destination="${FAKE_BIN}/curl"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "curl" >> "${CNTOOLS_NETWORK_LOG:?}"' \
    'printf " %q" "$@" >> "${CNTOOLS_NETWORK_LOG:?}"' \
    'printf "\n" >> "${CNTOOLS_NETWORK_LOG:?}"' \
    'case " $* " in' \
    '  *"/tip"*)' \
    '    if [[ "${CNTOOLS_ALLOW_KOIOS:-N}" == "Y" ]]; then' \
    '      printf "200"' \
    '      exit 0' \
    '    fi' \
    '    ;;' \
    '  *"/alpha/LICENSE"*)' \
    '    [[ "${CNTOOLS_ALLOW_BRANCH_PROBE:-N}" == "Y" ]] && exit 0' \
    '    ;;' \
    'esac' \
    'exit 97' \
    > "${destination}"
  chmod 0755 "${destination}"

  for command_name in wget git ssh nc; do
    destination="${FAKE_BIN}/${command_name}"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf "%s" "${0##*/}" >> "${CNTOOLS_NETWORK_LOG:?}"' \
      'printf " %q" "$@" >> "${CNTOOLS_NETWORK_LOG:?}"' \
      'printf "\n" >> "${CNTOOLS_NETWORK_LOG:?}"' \
      'exit 97' \
      > "${destination}"
    chmod 0755 "${destination}"
  done

  for command_name in clear less pkill tput; do
    destination="${FAKE_BIN}/${command_name}"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf "%s" "${0##*/}" >> "${CNTOOLS_SIDE_EFFECT_LOG:?}"' \
      'printf " %q" "$@" >> "${CNTOOLS_SIDE_EFFECT_LOG:?}"' \
      'printf "\n" >> "${CNTOOLS_SIDE_EFFECT_LOG:?}"' \
      'exit 0' \
      > "${destination}"
    chmod 0755 "${destination}"
  done

  destination="${FAKE_BIN}/stty"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "stty" >> "${CNTOOLS_SIDE_EFFECT_LOG:?}"' \
    'printf " %q" "$@" >> "${CNTOOLS_SIDE_EFFECT_LOG:?}"' \
    'printf "\n" >> "${CNTOOLS_SIDE_EFFECT_LOG:?}"' \
    'if [[ "${CNTOOLS_STTY_MODE:-fail}" == "success" ]]; then' \
    '  [[ "${1:-}" == "-g" ]] && printf "%s\n" "${CNTOOLS_STTY_STATE:-cntools-test-state}"' \
    '  exit 0' \
    'fi' \
    'exit 1' \
    > "${destination}"
  chmod 0755 "${destination}"

  for command_name in bc column ss; do
    destination="${FAKE_BIN}/${command_name}"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${destination}"
    chmod 0755 "${destination}"
  done

  destination="${FAKE_BIN}/cardano-node"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "cardano-node %s\n" "$*" >> "${CNTOOLS_CLI_LOG:?}"' \
    'if [[ "$#" -eq 1 && "$1" == "version" ]]; then' \
    '  printf "cardano-node 11.0.1 - linux-aarch64 - ghc-9.6\n"' \
    '  printf "git rev 0123456789abcdef\n"' \
    '  exit 0' \
    'fi' \
    'exit 98' \
    > "${destination}"
  chmod 0755 "${destination}"

  destination="${FAKE_BIN}/cardano-cli"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "cardano-cli %s\n" "$*" >> "${CNTOOLS_CLI_LOG:?}"' \
    'if [[ "$#" -eq 1 && ( "$1" == "version" || "$1" == "--version" ) ]]; then' \
    '  printf "cardano-cli 11.0.0.0\n"' \
    '  exit 0' \
    'fi' \
    'if [[ "$#" -eq 4 && "$1" == "hash" && "$2" == "genesis-file" && "$3" == "--genesis" ]]; then' \
    '  printf "00000000000000000000000000000000000000000000000000000000\n"' \
    '  exit 0' \
    'fi' \
    'exit 98' \
    > "${destination}"
  chmod 0755 "${destination}"
}

write_probe_envs() {
  printf '%s\n' \
    '# Loaded by Bash before the isolated CNTools process.' \
    'cntools_state_probe() {' \
    '  local cntools_probe_status="$1"' \
    '  {' \
    '    printf "exit_status=%s\n" "${cntools_probe_status}"' \
    '    printf "mode=%s\n" "${CNTOOLS_MODE-}"' \
    '    printf "advanced=%s\n" "${ADVANCED_MODE-}"' \
    '    printf "skip_update=%s\n" "${SKIP_UPDATE-}"' \
    '    printf "print_version=%s\n" "${PRINT_VERSION-}"' \
    '    printf "branch=%s\n" "${BRANCH-}"' \
    '    printf "branch_explicit=%s\n" "${BRANCH_EXPLICIT-}"' \
    '    printf "requested_branch=%s\n" "${REQUESTED_BRANCH-}"' \
    '  } > "${CNTOOLS_STATE_LOG:?}"' \
    '}' \
    'if [[ "${CNTOOLS_INSTALL_STATE_PROBE:-N}" == "Y" ]]; then' \
    '    unset CNTOOLS_INSTALL_STATE_PROBE' \
    "    trap 'cntools_state_probe \"\$?\"' EXIT" \
    'fi' \
    > "${STATE_ENV}"

  printf '%s\n' \
    '# Pause at the first clear, after production installed its signal traps.' \
    'if [[ "${CNTOOLS_INSTALL_SIGNAL_PROBE:-N}" == "Y" ]]; then' \
    '    unset CNTOOLS_INSTALL_SIGNAL_PROBE' \
    '    clear() {' \
    '      printf "CNTOOLS_SIGNAL_READY\n"' \
    '      while :; do' \
    '        IFS= read -r -t 1 _cntools_signal_input || :' \
    '      done' \
    '    }' \
    'fi' \
    > "${SIGNAL_ENV}"
}

write_manifest() {
  local node_root="$1"
  local implementation="$2"
  local metrics_provider n2c local_cli metrics forging

  case "${implementation}" in
    cnode|dingo)
      metrics_provider="prometheus"
      n2c=true
      local_cli=true
      metrics=true
      forging=true
      ;;
    amaru)
      metrics_provider="otel"
      n2c=false
      local_cli=false
      metrics=true
      forging=false
      ;;
    *) fail "unsupported fixture implementation: ${implementation}" ;;
  esac

  jq -n \
    --arg implementation "${implementation}" \
    --arg service_name "$(basename "${node_root}")" \
    --arg metrics_provider "${metrics_provider}" \
    --argjson n2c "${n2c}" \
    --argjson local_cli "${local_cli}" \
    --argjson metrics "${metrics}" \
    --argjson forging "${forging}" \
    '{
      schemaVersion: 1,
      deploymentStatus: "deployed",
      implementation: $implementation,
      network: "preview",
      branch: "master",
      repository: "cardano-community/guild-operators",
      serviceName: $service_name,
      nodeVersion: "fixture",
      targetNodeVersion: "fixture",
      metricsProvider: $metrics_provider,
      capabilities: {
        n2c: $n2c,
        localCli: $local_cli,
        metrics: $metrics,
        forging: $forging
      }
    }' > "${node_root}/.deployment.json"
}

write_fake_dispatcher() {
  local destination="$1"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'dispatcher_prepare_source_and_handoff() { :; }' \
    'dispatcher_distribution_prepare() { :; }' \
    '# GUILD_SOURCE_CHECK_ONLY is the source-comparison contract marker.' \
    'phase=apply' \
    '[[ "${GUILD_SOURCE_CHECK_ONLY:-N}" == "Y" ]] && phase=check' \
    '{ printf "%s" "${phase}"; printf "\\t%s" "$@"; printf "\\n"; } >> "${CNTOOLS_DISPATCH_LOG:?}"' \
    'implementation=""; network=""; node_parent=""; node_name=""; branch=""; account=""; source_mode=""' \
    'while (( $# > 0 )); do' \
    '  case "$1" in' \
    '    -i) implementation="$2"; shift 2 ;;' \
    '    -n) network="$2"; shift 2 ;;' \
    '    -p) node_parent="$2"; shift 2 ;;' \
    '    -t) node_name="$2"; shift 2 ;;' \
    '    -b) branch="$2"; shift 2 ;;' \
    '    -a) account="$2"; shift 2 ;;' \
    '    -S) source_mode="$2"; shift 2 ;;' \
    '    -s) shift 2 ;;' \
    '    -u) shift ;;' \
    '    *) exit 64 ;;' \
    '  esac' \
    'done' \
    '[[ -n "${implementation}" && -n "${network}" && -n "${node_parent}" && -n "${node_name}" ]]' \
    '[[ -n "${branch}" && -n "${account}" && "${source_mode}" == "managed" ]]' \
    'revision="$(printf "%s" "${account}:${branch}" | sha256sum | awk '\''{print $1}'\'')"' \
    'revision="${revision:0:40}"' \
    'if [[ "${phase}" == "check" ]]; then printf "%s\n" "${revision}"; exit 10; fi' \
    '[[ "${GUILD_SOURCE_EXPECT_REVISION:-${revision}}" == "${revision}" ]] || exit 66' \
    'node_root="${node_parent}/${node_name}"' \
    'manifest="${node_root}/.deployment.json"' \
    'receipt="${node_root}/.guild-source-receipt.json"' \
    'dispatcher="${node_root}/scripts/guild-deploy.sh"' \
    'dispatcher_hash="$(sha256sum -- "${dispatcher}" | awk '\''{print $1}'\'')"' \
    'receipt_tmp="$(mktemp "${node_root}/.guild-source-receipt.tmp.XXXXXX")"' \
    'metadata_tmp="$(mktemp "${node_root}/.deployment.tmp.XXXXXX")"' \
    'jq -n --arg implementation "${implementation}" --arg network "${network}" --arg repository "${account}/guild-operators" --arg branch "${branch}" --arg revision "${revision}" --arg mode "${source_mode}" --arg digest "${dispatcher_hash}" '\''{schemaVersion: 1, implementation: $implementation, network: $network, source: {repository: $repository, channel: $branch, ref: ("refs/heads/" + $branch), revision: $revision, mode: $mode, dirty: false}, files: [{path: "scripts/guild-deploy.sh", source: "scripts/cnode-helper-scripts/guild-deploy.sh", mode: "0755", policy: "exact", sourceSha256: $digest, installedSha256: $digest, managed: true}]}'\'' > "${receipt_tmp}"' \
    'receipt_hash="$(sha256sum -- "${receipt_tmp}" | awk '\''{print $1}'\'')"' \
    'jq --arg branch "${branch}" --arg repository "${account}/guild-operators" --arg mode "${source_mode}" --arg ref "refs/heads/${branch}" --arg revision "${revision}" --arg receipt_hash "${receipt_hash}" '\''.branch = $branch | .repository = $repository | .sourceSchemaVersion = 1 | .sourceMode = $mode | .sourceRef = $ref | .sourceRevision = $revision | .sourceDirty = false | del(.sourceTreeDigest) | .payloadReceipt = ".guild-source-receipt.json" | .payloadReceiptSha256 = $receipt_hash | .transactionId = $receipt_hash[0:16]'\'' "${manifest}" > "${metadata_tmp}"' \
    'chmod 0644 "${receipt_tmp}" "${metadata_tmp}"' \
    'mv -f -- "${receipt_tmp}" "${receipt}"' \
    'mv -f -- "${metadata_tmp}" "${manifest}"' \
    > "${destination}"
  chmod 0755 "${destination}"
}

write_cnode_files() {
  local node_root="$1"

  cp "${REPO_ROOT}/files/node-implementations/cnode/release.json" \
    "${node_root}/files/cnode-release.json"
  jq -n '{
    AlonzoGenesisFile: "alonzo-genesis.json",
    ByronGenesisFile: "byron-genesis.json",
    ShelleyGenesisFile: "shelley-genesis.json",
    ConwayGenesisFile: "conway-genesis.json",
    Protocol: "Cardano",
    TraceOptions: {"": {backends: ["PrometheusSimple 127.0.0.1 12798"]}}
  }' > "${node_root}/files/config.json"
  jq -n '{
    networkMagic: 2,
    systemStart: "2022-10-25T00:00:00Z",
    epochLength: 86400,
    slotLength: 1,
    activeSlotsCoeff: 0.05,
    slotsPerKESPeriod: 129600,
    maxKESEvolutions: 62
  }' > "${node_root}/files/shelley-genesis.json"
  jq -n '{
    startTime: 1666656000,
    protocolConsts: {k: 432},
    blockVersionData: {slotDuration: 20000}
  }' > "${node_root}/files/byron-genesis.json"
  printf '{}\n' > "${node_root}/files/alonzo-genesis.json"
  printf '{}\n' > "${node_root}/files/conway-genesis.json"
}

write_dingo_cli() {
  local node_root="$1"
  local cli_version

  cp "${REPO_ROOT}/files/node-implementations/dingo/release.json" \
    "${node_root}/files/dingo-release.json"
  cli_version="$(jq -er '.companions["cardano-cli"].version' \
    "${node_root}/files/dingo-release.json")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "cardano-cli-dingo %s\n" "$*" >> "${CNTOOLS_CLI_LOG:?}"' \
    'if [[ "$#" -eq 1 && ( "$1" == "version" || "$1" == "--version" ) ]]; then' \
    "  printf '%s\\n' 'cardano-cli ${cli_version}'" \
    '  exit 0' \
    'fi' \
    'exit 98' \
    > "${node_root}/home/.local/bin/cardano-cli-dingo"
  chmod 0755 "${node_root}/home/.local/bin/cardano-cli-dingo"
}

create_socket_fixture() {
  local socket_path="$1"
  python3 - "${socket_path}" <<'PY'
import os
import socket
import sys

path = sys.argv[1]
os.makedirs(os.path.dirname(path), exist_ok=True)
fixture = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
fixture.bind(path)
fixture.close()
PY
}

prepare_fixture() {
  local node_root="$1"
  local implementation="$2"
  local with_socket="${3:-Y}"
  local with_adapter="${4:-Y}"
  local with_cli="${5:-Y}"
  local adapter_source

  mkdir -p \
    "${node_root}/files" \
    "${node_root}/home/.local/bin" \
    "${node_root}/logs" \
    "${node_root}/scripts/adapters" \
    "${node_root}/scripts/lib" \
    "${node_root}/sockets" \
    "${node_root}/tmp/runtime"
  cp "${CNTOOLS_SCRIPT}" "${node_root}/scripts/cntools.sh"
  cp "${CNTOOLS_LIBRARY}" "${node_root}/scripts/cntools.library"
  mkdir -p "${node_root}/scripts/cntools/libs/legacy"
  cp -R \
    "${REPO_ROOT}/scripts/common-helper-scripts/cntools/libs/legacy/${CNTOOLS_LEGACY_BUNDLE_ID}" \
    "${node_root}/scripts/cntools/libs/legacy/${CNTOOLS_LEGACY_BUNDLE_ID}"
  find "${node_root}/scripts/cntools/libs/legacy/${CNTOOLS_LEGACY_BUNDLE_ID}" \
    -type f -exec chmod 0444 {} +
  find "${node_root}/scripts/cntools/libs/legacy/${CNTOOLS_LEGACY_BUNDLE_ID}" \
    -depth -type d -exec chmod 0555 {} +
  cp "${COMMON_ENV}" "${node_root}/scripts/env"
  write_fake_dispatcher "${node_root}/scripts/guild-deploy.sh"
  cp \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/deployment.library" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/env.library" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library" \
    "${REPO_ROOT}/scripts/common-helper-scripts/lib/systemd.library" \
    "${node_root}/scripts/lib/"
  # Startup-policy characterization uses a one-file fake dispatcher only to
  # observe branch delegation. Exact deployment inventories/currentness are
  # exercised by common-runtime.sh, so keep that concern out of this fixture.
  printf '%s\n' 'deployment_payload_is_current() { return 0; }' >> \
    "${node_root}/scripts/lib/deployment.library"

  case "${implementation}" in
    cnode) adapter_source="${REPO_ROOT}/scripts/cnode-helper-scripts/cnode.adapter" ;;
    dingo) adapter_source="${REPO_ROOT}/scripts/dingo-helper-scripts/dingo.adapter" ;;
    amaru) adapter_source="${REPO_ROOT}/scripts/amaru-helper-scripts/amaru.adapter" ;;
    *) fail "unsupported fixture implementation: ${implementation}" ;;
  esac
  if [[ "${with_adapter}" == "Y" ]]; then
    cp "${adapter_source}" \
      "${node_root}/scripts/adapters/${implementation}.adapter"
  fi

  write_manifest "${node_root}" "${implementation}"
  case "${implementation}" in
    cnode) write_cnode_files "${node_root}" ;;
    dingo)
      cp "${REPO_ROOT}/files/node-implementations/dingo/release.json" \
        "${node_root}/files/dingo-release.json"
      [[ "${with_cli}" == "Y" ]] && write_dingo_cli "${node_root}"
      ;;
    amaru) : ;;
  esac
  [[ "${with_socket}" == "Y" ]] &&
    create_socket_fixture "${node_root}/sockets/node.socket"
  return 0
}

run_env_profile() {
  local node_root="$1"
  local profile="$2"
  local adapter_path="${3:-}"

  RUN_COUNTER=$((RUN_COUNTER + 1))
  ENV_STATUS=0
  ENV_OUTPUT_FILE="${TEST_ROOT}/env-${RUN_COUNTER}.out"
  env -i \
    PATH="${FAKE_BIN}:${BASE_PATH}" \
    HOME="${node_root}/home" \
    TMPDIR="${node_root}/tmp" \
    TERM=dumb \
    LC_ALL=C \
    TZ=UTC \
    USESYSVARS=Y \
    NODE_HOME="${node_root}" \
    CNODE_HOME="${node_root}" \
    TMP_DIR="${node_root}/tmp/runtime" \
    SOCKET="${node_root}/sockets/node.socket" \
    NODE_SOCKET="${node_root}/sockets/node.socket" \
    CONFIG="${node_root}/files/config.json" \
    UPDATE_CHECK=N \
    ENABLE_CHATTR=false \
    CHECK_KES=false \
    NODE_ADAPTER_PATH="${adapter_path}" \
    CNTOOLS_NETWORK_LOG="${NETWORK_LOG}" \
    CNTOOLS_DISPATCH_LOG="${DISPATCH_LOG}" \
    CNTOOLS_SIDE_EFFECT_LOG="${SIDE_EFFECT_LOG}" \
    CNTOOLS_CLI_LOG="${CLI_LOG}" \
    http_proxy=http://127.0.0.1:9 \
    https_proxy=http://127.0.0.1:9 \
    HTTP_PROXY=http://127.0.0.1:9 \
    HTTPS_PROXY=http://127.0.0.1:9 \
    "${BASH_BIN}" --noprofile --norc -c '
      set +u
      env_path="$1"
      profile="$2"
      . "${env_path}" "${profile}"
      status=$?
      printf "__PROFILE_STATUS=%s\n" "${status}"
      printf "implementation=%s\n" "${NODE_IMPLEMENTATION-}"
      printf "profile=%s\n" "${ENV_PROFILE-}"
      printf "offline_mode=%s\n" "${OFFLINE_MODE-}"
      exit "${status}"
    ' cntools-env-policy "${node_root}/scripts/env" "${profile}" \
    > "${ENV_OUTPUT_FILE}" 2>&1 || ENV_STATUS=$?
}

run_cntools() {
  local node_root="$1"
  local allow_koios="$2"
  local allow_branch_probe="$3"
  shift 3

  RUN_COUNTER=$((RUN_COUNTER + 1))
  RUN_STATUS=0
  RUN_OUTPUT_FILE="${TEST_ROOT}/cntools-${RUN_COUNTER}.out"
  : > "${STATE_LOG}"
  env -i \
    PATH="${FAKE_BIN}:${BASE_PATH}" \
    HOME="${node_root}/home" \
    TMPDIR="${node_root}/tmp" \
    TERM=dumb \
    LC_ALL=C \
    TZ=UTC \
    BASH_ENV="${STATE_ENV}" \
    CNTOOLS_INSTALL_STATE_PROBE=Y \
    USESYSVARS=Y \
    NODE_HOME="${node_root}" \
    CNODE_HOME="${node_root}" \
    TMP_DIR="${node_root}/tmp/runtime" \
    SOCKET="${node_root}/sockets/node.socket" \
    NODE_SOCKET="${node_root}/sockets/node.socket" \
    CONFIG="${node_root}/files/config.json" \
    UPDATE_CHECK=N \
    ENABLE_CHATTR=false \
    ENABLE_ADVANCED=false \
    CHECK_KES=false \
    NODE_ADAPTER_PATH="${RUN_NODE_ADAPTER_PATH:-}" \
    CNTOOLS_NETWORK_LOG="${NETWORK_LOG}" \
    CNTOOLS_DISPATCH_LOG="${DISPATCH_LOG}" \
    CNTOOLS_SIDE_EFFECT_LOG="${SIDE_EFFECT_LOG}" \
    CNTOOLS_CLI_LOG="${CLI_LOG}" \
    CNTOOLS_STATE_LOG="${STATE_LOG}" \
    CNTOOLS_STTY_MODE=fail \
    CNTOOLS_ALLOW_KOIOS="${allow_koios}" \
    CNTOOLS_ALLOW_BRANCH_PROBE="${allow_branch_probe}" \
    http_proxy=http://127.0.0.1:9 \
    https_proxy=http://127.0.0.1:9 \
    HTTP_PROXY=http://127.0.0.1:9 \
    HTTPS_PROXY=http://127.0.0.1:9 \
    python3 -c '
import os
import signal
import subprocess
import sys

process = subprocess.Popen(sys.argv[1:], start_new_session=True)
try:
    status = process.wait(timeout=20)
except subprocess.TimeoutExpired:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    raise SystemExit(124)
raise SystemExit(status if status >= 0 else 128 - status)
' "${BASH_BIN}" --noprofile --norc \
      "${node_root}/scripts/cntools.sh" "$@" \
    > "${RUN_OUTPUT_FILE}" 2>&1 || RUN_STATUS=$?

  [[ "${RUN_STATUS}" != 124 ]] ||
    fail "CNTools command timed out after 20 seconds: $*"
}

assert_profile() {
  local node_root="$1"
  local implementation="$2"
  local profile="$3"
  local expected_status="$4"
  local expected_offline_mode
  local output

  case "${profile}" in
    definitions|basic|offline|light) expected_offline_mode=Y ;;
    *) expected_offline_mode=N ;;
  esac

  reset_logs
  run_env_profile "${node_root}" "${profile}"
  output="$(< "${ENV_OUTPUT_FILE}")"
  assert_eq "${ENV_STATUS}" "${expected_status}" \
    "${implementation} ${profile} env status"
  assert_contains "${output}" "__PROFILE_STATUS=${expected_status}" \
    "${implementation} ${profile} reported status"
  assert_contains "${output}" "implementation=${implementation}" \
    "${implementation} ${profile} selection"
  assert_contains "${output}" "profile=${profile}" \
    "${implementation} ${profile} profile propagation"
  assert_contains "${output}" "offline_mode=${expected_offline_mode}" \
    "${implementation} ${profile} offline-mode propagation"
  assert_no_network "${implementation} ${profile} env"
}

run_support_matrix_contract() {
  local cnode_root="${TEST_ROOT}/matrix-cnode"
  local dingo_root="${TEST_ROOT}/matrix-dingo"
  local dingo_preprod_root="${TEST_ROOT}/matrix-dingo-preprod"
  local amaru_root="${TEST_ROOT}/matrix-amaru"
  local updated_manifest
  local profile

  prepare_fixture "${cnode_root}" cnode Y
  prepare_fixture "${dingo_root}" dingo Y
  prepare_fixture "${dingo_preprod_root}" dingo Y
  updated_manifest="${dingo_preprod_root}/.deployment.updated.json"
  jq '.network = "preprod"' "${dingo_preprod_root}/.deployment.json" \
    > "${updated_manifest}"
  mv "${updated_manifest}" "${dingo_preprod_root}/.deployment.json"
  prepare_fixture "${amaru_root}" amaru N

  for profile in offline light local; do
    assert_profile "${cnode_root}" cnode "${profile}" 0
    assert_profile "${dingo_root}" dingo "${profile}" 0
    assert_profile "${dingo_preprod_root}" dingo "${profile}" 0
    assert_profile "${amaru_root}" amaru "${profile}" 3
  done
  assert_profile "${amaru_root}" amaru definitions 0
}

run_metadata_and_dependency_contracts() {
  local malformed_root="${TEST_ROOT}/malformed-metadata"
  local capability_metadata_root="${TEST_ROOT}/missing-metadata-capability"
  local missing_adapter_root="${TEST_ROOT}/missing-adapter"
  local missing_cli_root="${TEST_ROOT}/missing-cli"
  local missing_socket_root="${TEST_ROOT}/missing-socket"
  local missing_adapter_cap_root="${TEST_ROOT}/missing-adapter-capability"
  local reduced_adapter
  local output

  prepare_fixture "${malformed_root}" dingo Y
  printf '{not-json\n' > "${malformed_root}/.deployment.json"
  reset_logs
  run_env_profile "${malformed_root}" definitions
  output="$(< "${ENV_OUTPUT_FILE}")"
  assert_eq "${ENV_STATUS}" 1 "malformed deployment metadata status"
  assert_contains "${output}" "Deployment metadata is malformed, incomplete, unsupported, or not finalized:" \
    "malformed deployment metadata diagnostic"
  assert_no_network "malformed deployment metadata"
  reset_logs
  run_cntools "${malformed_root}" N N -o -u -v
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" 1 "malformed metadata entrypoint status"
  assert_contains "${output}" "ERROR: CNTools failed to load common env definitions" \
    "malformed metadata entrypoint diagnostic"
  assert_no_network "malformed metadata entrypoint"

  prepare_fixture "${capability_metadata_root}" dingo Y
  jq 'del(.capabilities.localCli)' \
    "${capability_metadata_root}/.deployment.json" \
    > "${capability_metadata_root}/.deployment.missing-capability.json"
  mv "${capability_metadata_root}/.deployment.missing-capability.json" \
    "${capability_metadata_root}/.deployment.json"
  reset_logs
  run_env_profile "${capability_metadata_root}" definitions
  output="$(< "${ENV_OUTPUT_FILE}")"
  assert_eq "${ENV_STATUS}" 1 "missing metadata capability status"
  assert_contains "${output}" "Deployment metadata is malformed, incomplete, unsupported, or not finalized:" \
    "missing metadata capability diagnostic"
  assert_no_network "missing metadata capability"
  reset_logs
  run_cntools "${capability_metadata_root}" N N -o -u -v
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" 1 "missing metadata capability entrypoint status"
  assert_contains "${output}" "ERROR: CNTools failed to load common env definitions" \
    "missing metadata capability entrypoint diagnostic"
  assert_no_network "missing metadata capability entrypoint"

  prepare_fixture "${missing_adapter_root}" dingo Y N
  reset_logs
  run_env_profile "${missing_adapter_root}" definitions
  output="$(< "${ENV_OUTPUT_FILE}")"
  assert_eq "${ENV_STATUS}" 1 "missing adapter status"
  assert_contains "${output}" "Node adapter not found for implementation 'dingo'" \
    "missing adapter diagnostic"
  assert_no_network "missing adapter"
  reset_logs
  run_cntools "${missing_adapter_root}" N N -o -u -v
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" 1 "missing adapter entrypoint status"
  assert_contains "${output}" "ERROR: CNTools failed to load common env definitions" \
    "missing adapter entrypoint diagnostic"
  assert_no_network "missing adapter entrypoint"

  prepare_fixture "${missing_cli_root}" dingo Y Y N
  reset_logs
  run_env_profile "${missing_cli_root}" offline
  output="$(< "${ENV_OUTPUT_FILE}")"
  assert_eq "${ENV_STATUS}" 1 "missing Dingo CLI status"
  assert_contains "${output}" "Dingo cardano-cli is not executable:" \
    "missing Dingo CLI diagnostic"
  assert_no_network "missing Dingo CLI"
  reset_logs
  run_cntools "${missing_cli_root}" N N -o -u -v
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" 1 "missing Dingo CLI entrypoint status"
  assert_contains "${output}" "ERROR: CNTools failed to initialize the selected node adapter" \
    "missing Dingo CLI entrypoint diagnostic"
  assert_no_network "missing Dingo CLI entrypoint"

  prepare_fixture "${missing_socket_root}" dingo N
  reset_logs
  run_env_profile "${missing_socket_root}" local
  output="$(< "${ENV_OUTPUT_FILE}")"
  assert_eq "${ENV_STATUS}" 2 "missing Dingo socket status"
  assert_contains "${output}" "Dingo expects node-to-client socket ${missing_socket_root}/sockets/node.socket, but it does not exist." \
    "missing Dingo socket diagnostic"
  assert_no_network "missing Dingo socket"
  reset_logs
  run_cntools "${missing_socket_root}" N N -n -u -v
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" 1 "missing Dingo socket entrypoint status"
  assert_contains "${output}" "ERROR: The selected node is not ready for CNTools LOCAL mode" \
    "missing Dingo socket entrypoint diagnostic"
  assert_no_network "missing Dingo socket entrypoint"

  prepare_fixture "${missing_adapter_cap_root}" dingo Y
  reduced_adapter="${missing_adapter_cap_root}/scripts/adapters/dingo-no-local.adapter"
  awk '
    /^NODE_CAPABILITIES=/ {
      print "NODE_CAPABILITIES=\"process process_pid metrics native_prometheus n2c local_submit forge kes\""
      next
    }
    { print }
  ' "${REPO_ROOT}/scripts/dingo-helper-scripts/dingo.adapter" > "${reduced_adapter}"
  reset_logs
  run_env_profile "${missing_adapter_cap_root}" local "${reduced_adapter}"
  output="$(< "${ENV_OUTPUT_FILE}")"
  assert_eq "${ENV_STATUS}" 3 "missing adapter capability status"
  assert_contains "${output}" "does not support local_query" \
    "missing adapter capability diagnostic"
  assert_no_network "missing adapter capability"
  reset_logs
  RUN_NODE_ADAPTER_PATH="${reduced_adapter}"
  run_cntools "${missing_adapter_cap_root}" N N -n -u -v
  RUN_NODE_ADAPTER_PATH=""
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" 1 "missing adapter capability entrypoint status"
  assert_contains "${output}" "ERROR: dingo does not provide the capabilities required by CNTools LOCAL mode" \
    "missing adapter capability entrypoint diagnostic"
  assert_no_network "missing adapter capability entrypoint"
}

assert_startup_state() {
  local mode="$1"
  local advanced="$2"
  local branch="$3"
  local branch_explicit="$4"
  local requested_branch="$5"

  assert_file_line "${STATE_LOG}" "exit_status=0" "startup exit probe"
  assert_file_line "${STATE_LOG}" "mode=${mode}" "startup mode probe"
  assert_file_line "${STATE_LOG}" "advanced=${advanced}" "startup advanced probe"
  assert_file_line "${STATE_LOG}" "skip_update=Y" "startup update probe"
  assert_file_line "${STATE_LOG}" "print_version=true" "startup version probe"
  assert_file_line "${STATE_LOG}" "branch=${branch}" "startup branch probe"
  assert_file_line "${STATE_LOG}" "branch_explicit=${branch_explicit}" \
    "startup explicit branch probe"
  assert_file_line "${STATE_LOG}" "requested_branch=${requested_branch}" \
    "startup requested branch probe"
}

run_flag_contracts() {
  local cnode_root="${TEST_ROOT}/flags-cnode"
  local dingo_root="${TEST_ROOT}/flags-dingo"
  local amaru_root="${TEST_ROOT}/flags-amaru"
  local output network_count

  prepare_fixture "${cnode_root}" cnode Y
  prepare_fixture "${dingo_root}" dingo Y
  prepare_fixture "${amaru_root}" amaru N

  reset_logs
  run_cntools "${cnode_root}" N N -n -a -u -v
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" 0 "cnode local advanced version status"
  assert_contains "${output}" "CNTools v" "cnode local version output"
  assert_startup_state LOCAL true master N ""
  assert_no_network "cnode -n -a -u -v"

  reset_logs
  run_cntools "${cnode_root}" Y N -l -u -v
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" 0 "cnode light version status"
  assert_contains "${output}" "CNTools v" "cnode light version output"
  assert_startup_state LIGHT false master N ""
  network_count="$(wc -l < "${NETWORK_LOG}" | tr -d '[:space:]')"
  assert_eq "${network_count}" 1 "cnode light intercepted request count"
  assert_contains "$(< "${NETWORK_LOG}")" "/tip" \
    "cnode light Koios health probe"

  reset_logs
  run_cntools "${cnode_root}" N N -o -a -u -v
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" 0 "cnode offline advanced version status"
  assert_contains "${output}" "CNTools v" "cnode offline version output"
  assert_startup_state OFFLINE true master N ""
  assert_no_network "cnode -o -a -u -v"

  reset_logs
  run_cntools "${cnode_root}" N N -n -l -o -u -v
  assert_eq "${RUN_STATUS}" 0 "mode precedence status"
  assert_startup_state OFFLINE false master N ""
  assert_no_network "cnode mode flag precedence"

  reset_logs
  run_cntools "${dingo_root}" N Y -o -u -b alpha -v
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" 0 "Dingo explicit branch version status"
  assert_contains "${output}" "(branch: alpha)" \
    "Dingo explicit branch version output"
  assert_startup_state OFFLINE false alpha Y alpha
  assert_eq "$(jq -r '.branch' "${dingo_root}/.deployment.json")" alpha \
    "persisted alternate branch"
  assert_eq "$(wc -l < "${DISPATCH_LOG}" | tr -d '[:space:]')" 2 \
    "branch transaction dispatcher invocation count"
  assert_contains "$(sed -n '1p' "${DISPATCH_LOG}")" $'check\t' \
    "branch transaction source check"
  assert_contains "$(sed -n '2p' "${DISPATCH_LOG}")" $'apply\t' \
    "branch transaction apply"
  assert_contains "$(< "${DISPATCH_LOG}")" $'-b\talpha' \
    "branch transaction requested branch"
  assert_contains "$(< "${DISPATCH_LOG}")" $'-S\tmanaged' \
    "branch transaction managed source mode"
  jq -e '.payloadReceipt == ".guild-source-receipt.json" and
         (.payloadReceiptSha256 | test("^[0-9a-f]{64}$"))' \
    "${dingo_root}/.deployment.json" >/dev/null ||
    fail "branch transaction did not publish receipt-backed metadata"
  assert_no_network "Dingo transactional branch change"

  reset_logs
  run_cntools "${amaru_root}" N N -n -u -v
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" 1 "Amaru local policy entrypoint status"
  assert_contains "${output}" "ERROR: amaru does not provide the capabilities required by CNTools LOCAL mode" \
    "Amaru local policy diagnostic"
  assert_no_network "Amaru -n -u -v"

  reset_logs
  run_cntools "${amaru_root}" N N -l -a -u -v
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" 1 "Amaru light policy entrypoint status"
  assert_contains "${output}" "ERROR: amaru does not provide the capabilities required by CNTools LIGHT mode" \
    "Amaru light policy diagnostic"
  assert_no_network "Amaru -l -a -u -v"

  reset_logs
  run_cntools "${amaru_root}" N N -o -u -v
  output="$(< "${RUN_OUTPUT_FILE}")"
  assert_eq "${RUN_STATUS}" 1 "Amaru offline policy entrypoint status"
  assert_contains "${output}" "ERROR: amaru does not provide the capabilities required by CNTools OFFLINE mode" \
    "Amaru offline policy diagnostic"
  assert_no_network "Amaru -o -u -v"
}

run_signal_process() {
  local signal_name="$1"
  local signal_root="${TEST_ROOT}/signal-${signal_name,,}"
  local output_file="${TEST_ROOT}/signal-${signal_name,,}.out"
  local status=0

  mkdir -p "${signal_root}/scripts" "${signal_root}/home"
  cp "${CNTOOLS_SCRIPT}" "${signal_root}/scripts/cntools.sh"
  reset_logs

  env -i \
    PATH="${FAKE_BIN}:${BASE_PATH}" \
    HOME="${signal_root}/home" \
    TERM=dumb \
    LC_ALL=C \
    BASH_ENV="${SIGNAL_ENV}" \
    CNTOOLS_INSTALL_SIGNAL_PROBE=Y \
    CNTOOLS_NETWORK_LOG="${NETWORK_LOG}" \
    CNTOOLS_SIDE_EFFECT_LOG="${SIDE_EFFECT_LOG}" \
    CNTOOLS_CLI_LOG="${CLI_LOG}" \
    CNTOOLS_STTY_MODE=success \
    CNTOOLS_STTY_STATE=cntools-test-state \
    python3 - "${BASH_BIN}" "${signal_root}/scripts/cntools.sh" "${signal_name}" \
    > "${output_file}" 2>&1 <<'PY' || status=$?
import errno
import os
import pty
import select
import signal
import sys
import time

bash_path, script_path, signal_name = sys.argv[1:]
requested_signal = getattr(signal, "SIG" + signal_name)
pid, master_fd = pty.fork()
if pid == 0:
    os.execv(bash_path, [bash_path, "--noprofile", "--norc", script_path])

deadline = time.monotonic() + 20
status = None
ready = False
output = bytearray()
while status is None and time.monotonic() < deadline:
    waited_pid, child_status = os.waitpid(pid, os.WNOHANG)
    if waited_pid == pid:
        status = child_status
        break
    readable, _, _ = select.select([master_fd], [], [], 0.2)
    if readable:
        try:
            data = os.read(master_fd, 4096)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            data = b""
        if data:
            output.extend(data)
            os.write(sys.stdout.fileno(), data)
            if not ready and b"CNTOOLS_SIGNAL_READY" in output:
                os.kill(pid, requested_signal)
                ready = True

if status is None:
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    terminate_deadline = time.monotonic() + 1
    while time.monotonic() < terminate_deadline:
        waited_pid, child_status = os.waitpid(pid, os.WNOHANG)
        if waited_pid == pid:
            status = child_status
            break
        time.sleep(0.05)
    if status is None:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        _, status = os.waitpid(pid, 0)
    os.close(master_fd)
    raise SystemExit(124)

os.close(master_fd)
if not ready:
    raise SystemExit(125)
if os.WIFEXITED(status):
    raise SystemExit(os.WEXITSTATUS(status))
if os.WIFSIGNALED(status):
    raise SystemExit(128 + os.WTERMSIG(status))
raise SystemExit(126)
PY

  [[ "${status}" != 124 ]] || fail "${signal_name} cleanup test timed out"
  [[ "${status}" != 125 ]] || fail "${signal_name} cleanup test exited before ready"
  assert_eq "${status}" 1 "${signal_name} cleanup status"
  assert_no_network "${signal_name} cleanup"
}

assert_signal_lifecycle() {
  local signal_name="$1"
  local -a events=()

  run_signal_process "${signal_name}"
  mapfile -t events < <(
    awk '$1 == "stty" || $1 == "tput" || $1 == "pkill" { print }' \
      "${SIDE_EFFECT_LOG}"
  )
  assert_eq "${#events[@]}" 5 "${signal_name} lifecycle event count"
  assert_eq "${events[0]}" "stty -g" "${signal_name} terminal capture"
  assert_eq "${events[1]}" "tput cnorm" "${signal_name} cursor restoration"
  assert_eq "${events[2]}" "tput sgr0" "${signal_name} attribute restoration"
  [[ "${events[3]}" =~ ^pkill[[:space:]]-TERM[[:space:]]-P[[:space:]][1-9][0-9]*$ ]] ||
    fail "${signal_name} child cleanup event is malformed: ${events[3]}"
  assert_eq "${events[4]}" "stty cntools-test-state" \
    "${signal_name} terminal state restoration"
}

write_fake_tools
write_probe_envs
reset_logs

run_support_matrix_contract
run_metadata_and_dependency_contracts
run_flag_contracts
assert_signal_lifecycle INT
assert_signal_lifecycle TERM

printf 'CNTools startup and support-policy characterization tests passed\n'
