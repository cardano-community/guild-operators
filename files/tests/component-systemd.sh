#!/usr/bin/env bash
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'component systemd tests skipped: Bash 4+ is required\n'
  exit 0
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-component-systemd.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

NODE_ROOT="${TEST_ROOT}/cnode"
SCRIPT_ROOT="${NODE_ROOT}/scripts"
UNIT_ROOT="${TEST_ROOT}/units"
TEST_HOME="${TEST_ROOT}/home"
mkdir -p "${SCRIPT_ROOT}/lib" "${SCRIPT_ROOT}/adapters" "${UNIT_ROOT}" "${TEST_HOME}"

cp "${REPO_ROOT}/scripts/common-helper-scripts/env" "${SCRIPT_ROOT}/env"
cp "${REPO_ROOT}"/scripts/common-helper-scripts/lib/*.library "${SCRIPT_ROOT}/lib/"
cp "${REPO_ROOT}/scripts/cnode-helper-scripts/cnode.adapter" \
  "${SCRIPT_ROOT}/adapters/cnode.adapter"

for component in \
  blockPerf.sh \
  cncli.sh \
  cnode.sh \
  dbsync.sh \
  logMonitor.sh \
  mithril-signer.sh \
  ogmios.sh \
  submitapi.sh \
  topologyUpdater.sh; do
  cp "${REPO_ROOT}/scripts/cnode-helper-scripts/${component}" "${SCRIPT_ROOT}/${component}"
done
cp "${REPO_ROOT}/scripts/cnode-helper-scripts/mithril.library" \
  "${SCRIPT_ROOT}/mithril.library"

cat > "${NODE_ROOT}/.deployment.json" <<'JSON'
{
  "schemaVersion": 1,
  "deploymentStatus": "deployed",
  "implementation": "cnode",
  "network": "preview",
  "branch": "master",
  "repository": "cardano-community/guild-operators",
  "serviceName": "cnode",
  "nodeVersion": "",
  "targetNodeVersion": "",
  "metricsProvider": "prometheus",
  "capabilities": {
    "n2c": true,
    "localCli": true,
    "metrics": true,
    "forging": true
  }
}
JSON

cat > "${TEST_ROOT}/systemctl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG}"
exit 0
SCRIPT
chmod 755 "${TEST_ROOT}/systemctl"

export SUDO=N
export UPDATE_CHECK=N
export HOME="${TEST_HOME}"
export SYSTEMCTL_BIN="${TEST_ROOT}/systemctl"
export SYSTEMCTL_LOG="${TEST_ROOT}/systemctl.log"
export SYSTEMD_UNIT_DIR="${UNIT_ROOT}"

# These management paths must work after node binaries, configs, genesis files,
# sockets, and databases have already disappeared.
[[ ! -e "${HOME}/.local/bin/cardano-node" ]]
[[ ! -e "${NODE_ROOT}/files/config.json" ]]

"${BASH}" "${SCRIPT_ROOT}/cncli.sh" -d
[[ ! -e "${UNIT_ROOT}/cnode-cncli-ptsendtip.service" &&
   ! -e "${UNIT_ROOT}/cnode-cncli-ptsendslots.service" ]] || {
  printf 'FAIL: default CNCLI -d unexpectedly installed PoolTool units\n' >&2
  exit 1
}
"${BASH}" "${SCRIPT_ROOT}/cncli.sh" systemd install all
"${BASH}" "${SCRIPT_ROOT}/topologyUpdater.sh" -d

# The former orchestrator/library generated this unit without referencing the
# launcher path. Its historical description is the migration signature.
cat > "${UNIT_ROOT}/cnode-mithril-signer.service" <<'UNIT'
[Unit]
Description=Cardano Mithril signer service
[Service]
ExecStart=/bin/bash -l -c "exec /home/operator/.local/bin/mithril-signer -vv"
UNIT

for expected in \
  cnode-cncli-sync.service \
  cnode-cncli-leaderlog.service \
  cnode-cncli-validate.service \
  cnode-cncli-ptsendtip.service \
  cnode-cncli-ptsendslots.service \
  cnode-tu-push.service \
  cnode-tu-push.timer \
  cnode-tu-fetch.service \
  cnode-tu-restart.service \
  cnode-tu-restart.timer; do
  [[ -f "${UNIT_ROOT}/${expected}" ]] || {
    printf 'FAIL: systemd install alias did not create %s\n' "${expected}" >&2
    exit 1
  }
done

for cncli_unit in "${UNIT_ROOT}"/cnode-cncli-*.service; do
  grep -Fq 'KillSignal=SIGINT' "${cncli_unit}" ||
    fail "CNCLI unit does not request graceful SIGINT: ${cncli_unit}"
  grep -Fq 'KillMode=control-group' "${cncli_unit}" ||
    fail "CNCLI unit does not signal the complete process group: ${cncli_unit}"
done

# Model units written by the retired deploy-as-systemd.sh orchestrator. These
# did not carry ownership markers, so each replacement launcher must recognize
# only its own historical ExecStart signature.
for legacy_component in \
  cnode \
  dbsync \
  submitapi \
  ogmios \
  blockPerf \
  logMonitor; do
  case "${legacy_component}" in
    cnode) legacy_unit="cnode.service" ;;
    dbsync) legacy_unit="cnode-dbsync.service" ;;
    submitapi) legacy_unit="cnode-submit-api.service" ;;
    ogmios) legacy_unit="cnode-ogmios.service" ;;
    blockPerf) legacy_unit="cnode-tu-blockperf.service" ;;
    logMonitor) legacy_unit="cnode-logmonitor.service" ;;
  esac
  cat > "${UNIT_ROOT}/${legacy_unit}" <<UNIT
[Unit]
Description=Legacy ${legacy_component} fixture
[Service]
ExecStart=/bin/bash -l -c "exec ${SCRIPT_ROOT}/${legacy_component}.sh"
UNIT
done

"${BASH}" "${SCRIPT_ROOT}/cnode.sh" systemd remove
"${BASH}" "${SCRIPT_ROOT}/dbsync.sh" systemd remove
"${BASH}" "${SCRIPT_ROOT}/submitapi.sh" systemd remove
"${BASH}" "${SCRIPT_ROOT}/ogmios.sh" systemd remove
"${BASH}" "${SCRIPT_ROOT}/cncli.sh" systemd remove all
"${BASH}" "${SCRIPT_ROOT}/topologyUpdater.sh" systemd remove
"${BASH}" "${SCRIPT_ROOT}/mithril-signer.sh" systemd remove
[[ ! -e "${UNIT_ROOT}/cnode-mithril-signer.service" ]] ||
  fail "legacy Mithril signer unit was not migrated by component ownership"
"${BASH}" "${SCRIPT_ROOT}/blockPerf.sh" systemd remove
"${BASH}" "${SCRIPT_ROOT}/logMonitor.sh" systemd remove

for expected in \
  cnode.service \
  cnode-dbsync.service \
  cnode-submit-api.service \
  cnode-ogmios.service \
  cnode-cncli-sync.service \
  cnode-cncli-leaderlog.service \
  cnode-cncli-validate.service \
  cnode-cncli-ptsendtip.service \
  cnode-cncli-ptsendslots.service \
  cnode-tu-push.service \
  cnode-tu-push.timer \
  cnode-tu-fetch.service \
  cnode-tu-restart.service \
  cnode-tu-restart.timer \
  cnode-mithril-signer.service \
  cnode-tu-blockperf.service \
  cnode-logmonitor.service; do
  grep -Fq "${expected}" "${SYSTEMCTL_LOG}" || {
    printf 'FAIL: systemd management did not address %s\n' "${expected}" >&2
    exit 1
  }
done

AMARU_NODE_ROOT="${TEST_ROOT}/amaru-test"
AMARU_SCRIPT_ROOT="${AMARU_NODE_ROOT}/scripts"
AMARU_UNIT_ROOT="${TEST_ROOT}/amaru-units"
AMARU_BIN="${HOME}/.local/bin/amaru"
AMARU_OTELCOL_BIN="${HOME}/.local/bin/otelcol-contrib"
AMARU_SERVICE="amaru-test"
AMARU_MAIN_UNIT="${AMARU_SERVICE}.service"
AMARU_METRICS_UNIT="${AMARU_SERVICE}-metrics.service"
mkdir -p \
  "${AMARU_SCRIPT_ROOT}/lib" \
  "${AMARU_NODE_ROOT}/files" \
  "${AMARU_UNIT_ROOT}" \
  "${HOME}/.local/bin"
cp "${REPO_ROOT}/scripts/amaru-helper-scripts/amaru.sh" \
  "${AMARU_SCRIPT_ROOT}/amaru.sh"
cp "${REPO_ROOT}/scripts/common-helper-scripts/lib/systemd.library" \
  "${AMARU_SCRIPT_ROOT}/lib/systemd.library"
chmod 0755 "${AMARU_SCRIPT_ROOT}/amaru.sh"

cat > "${AMARU_NODE_ROOT}/.deployment.json" <<JSON
{
  "schemaVersion": 1,
  "deploymentStatus": "deployed",
  "implementation": "amaru",
  "network": "preprod",
  "branch": "master",
  "repository": "cardano-community/guild-operators",
  "serviceName": "${AMARU_SERVICE}",
  "nodeVersion": "",
  "targetNodeVersion": "test",
  "metricsProvider": "otel",
  "capabilities": {
    "n2c": false,
    "localCli": false,
    "metrics": true,
    "forging": false
  }
}
JSON

cat > "${AMARU_SCRIPT_ROOT}/amaru.env" <<EOF
GUILD_NODE_IMPLEMENTATION="amaru"
GUILD_NODE_HOME="${AMARU_NODE_ROOT}"
GUILD_NODE_SERVICE="${AMARU_SERVICE}"
AMARU_BIN="${AMARU_BIN}"
AMARU_NETWORK="preprod"
AMARU_CHAIN_DIR="${AMARU_NODE_ROOT}/chain"
AMARU_LEDGER_DIR="${AMARU_NODE_ROOT}/ledger"
AMARU_LISTEN_ADDRESS="0.0.0.0:3000"
AMARU_WITH_OPEN_TELEMETRY="true"
AMARU_OTELCOL_BIN="${AMARU_OTELCOL_BIN}"
AMARU_OTELCOL_CONFIG="${AMARU_NODE_ROOT}/files/otelcol.yaml"
EOF

cat > "${AMARU_NODE_ROOT}/files/otelcol.yaml" <<'YAML'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:4317
      http:
        endpoint: 127.0.0.1:4318
exporters:
  prometheus:
    endpoint: 127.0.0.1:8889
service:
  pipelines:
    metrics:
      receivers: [otlp]
      exporters: [prometheus]
YAML

cat > "${AMARU_BIN}" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf 'amaru test\n'
fi
SCRIPT
cat > "${AMARU_OTELCOL_BIN}" <<'SCRIPT'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'otelcol-contrib version test\n' ;;
  validate) exit 0 ;;
esac
SCRIPT
chmod 0755 "${AMARU_BIN}" "${AMARU_OTELCOL_BIN}"

SYSTEMD_UNIT_DIR="${AMARU_UNIT_ROOT}"
: > "${SYSTEMCTL_LOG}"
"${BASH}" "${AMARU_SCRIPT_ROOT}/amaru.sh" install

[[ -f "${AMARU_UNIT_ROOT}/${AMARU_MAIN_UNIT}" ]] ||
  fail "Amaru node unit was not installed"
[[ -f "${AMARU_UNIT_ROOT}/${AMARU_METRICS_UNIT}" ]] ||
  fail "Amaru metrics unit was not installed"
grep -Fq "Wants=network-online.target time-sync.target ${AMARU_METRICS_UNIT}" \
  "${AMARU_UNIT_ROOT}/${AMARU_MAIN_UNIT}" ||
  fail "Amaru node unit does not require its metrics bridge"
grep -Fq "After=network-online.target time-sync.target ${AMARU_METRICS_UNIT}" \
  "${AMARU_UNIT_ROOT}/${AMARU_MAIN_UNIT}" ||
  fail "Amaru node unit is not ordered after its metrics bridge"
grep -Fq "ExecStart=${AMARU_OTELCOL_BIN} --config=${AMARU_NODE_ROOT}/files/otelcol.yaml" \
  "${AMARU_UNIT_ROOT}/${AMARU_METRICS_UNIT}" ||
  fail "Amaru metrics unit does not launch the configured collector"
grep -Fxq "enable ${AMARU_METRICS_UNIT} ${AMARU_MAIN_UNIT}" \
  "${SYSTEMCTL_LOG}" ||
  fail "Amaru install did not enable both services"
if grep -Eq '^start ' "${SYSTEMCTL_LOG}"; then
  fail "Amaru install unexpectedly started a service"
fi

: > "${SYSTEMCTL_LOG}"
"${BASH}" "${AMARU_SCRIPT_ROOT}/amaru.sh" status
"${BASH}" "${AMARU_SCRIPT_ROOT}/amaru.sh" start
"${BASH}" "${AMARU_SCRIPT_ROOT}/amaru.sh" restart
"${BASH}" "${AMARU_SCRIPT_ROOT}/amaru.sh" stop
grep -Fxq -- \
  "--no-pager status ${AMARU_MAIN_UNIT} ${AMARU_METRICS_UNIT}" \
  "${SYSTEMCTL_LOG}" ||
  fail "Amaru status did not inspect both services"
for action in start restart stop; do
  grep -Fxq "${action} ${AMARU_METRICS_UNIT} ${AMARU_MAIN_UNIT}" \
    "${SYSTEMCTL_LOG}" ||
    fail "Amaru ${action} did not address both services"
done

# Recovery operations must remain available when runtime prerequisites have
# disappeared, just as they do for the individual cnode component services.
rm -f \
  "${AMARU_SCRIPT_ROOT}/amaru.env" \
  "${AMARU_BIN}" \
  "${AMARU_OTELCOL_BIN}" \
  "${AMARU_NODE_ROOT}/files/otelcol.yaml"
"${BASH}" "${AMARU_SCRIPT_ROOT}/amaru.sh" status
"${BASH}" "${AMARU_SCRIPT_ROOT}/amaru.sh" remove

[[ ! -e "${AMARU_UNIT_ROOT}/${AMARU_MAIN_UNIT}" ]] ||
  fail "Amaru node unit was not removed"
[[ ! -e "${AMARU_UNIT_ROOT}/${AMARU_METRICS_UNIT}" ]] ||
  fail "Amaru metrics unit was not removed"
grep -Fxq "disable --now ${AMARU_MAIN_UNIT}" "${SYSTEMCTL_LOG}" ||
  fail "Amaru remove did not disable its node service"
grep -Fxq "disable --now ${AMARU_METRICS_UNIT}" "${SYSTEMCTL_LOG}" ||
  fail "Amaru remove did not disable its metrics service"

printf 'component systemd recovery tests passed\n'
