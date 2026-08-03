#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'amaru metrics tests skipped: Bash 4+ required\n'
  exit 0
fi

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${TEST_DIR}/../.." && pwd -P)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-amaru-metrics.XXXXXX")"
trap 'rm -rf -- "${TEMP_ROOT}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${message}: expected '${expected}', got '${actual}'"
}

assert_metric_available() {
  node_metric_has "$1" || fail "metric should be available: $1"
}

assert_metric_unavailable() {
  ! node_metric_has "$1" || fail "metric should be unavailable: $1"
}

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library"
# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/amaru-helper-scripts/amaru.adapter"

unset NODE_HOME CNODE_HOME NODE_METRICS_HOST NODE_METRICS_PORT
unset NODE_METRICS_PATH NODE_METRICS_URL AMARU_PROMETHEUS_URL
NODE_HOME="${TEMP_ROOT}/amaru"
GUILD_NODE_HOME="${NODE_HOME}"
GUILD_NODE_SERVICE="amaru-test"
AMARU_NETWORK="preview"
mkdir -p "${NODE_HOME}"

node_adapter_defaults
assert_eq "${NODE_METRICS_URL}" "http://127.0.0.1:8889/metrics" \
  "Amaru Prometheus bridge URL"
node_has metrics || fail "Amaru adapter does not advertise metrics"
node_has prometheus_bridge || fail "Amaru adapter does not advertise its Prometheus bridge"

configured_network=""
common_configure_known_network() {
  configured_network="${NODE_NETWORK}"
}
node_adapter_init monitor
assert_eq "${configured_network}" "preview" "monitor network initialization"
if node_adapter_init full; then
  fail "Amaru full helper profile should remain unsupported"
else
  assert_eq "$?" "${NODE_ADAPTER_UNSUPPORTED}" "unsupported full profile status"
fi

for network in preprod preview; do
  (
    unset AMARU_WITH_OPEN_TELEMETRY AMARU_PROMETHEUS_URL
    unset OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_METRICS_ENDPOINT
    unset OTEL_METRIC_EXPORT_INTERVAL
    # shellcheck source=/dev/null
    . "${REPO_ROOT}/files/configs/amaru/${network}/amaru.env"
    assert_eq "${AMARU_WITH_OPEN_TELEMETRY}" "true" \
      "${network} enables Amaru OpenTelemetry"
    assert_eq "${OTEL_EXPORTER_OTLP_ENDPOINT}" "http://127.0.0.1:4317" \
      "${network} trace/log OTLP endpoint"
    assert_eq "${OTEL_EXPORTER_OTLP_METRICS_ENDPOINT}" \
      "http://127.0.0.1:4318/v1/metrics" \
      "${network} metrics OTLP endpoint"
    assert_eq "${OTEL_METRIC_EXPORT_INTERVAL}" "2000" \
      "${network} metrics export interval"
    assert_eq "${AMARU_PROMETHEUS_URL}" "http://127.0.0.1:8889/metrics" \
      "${network} Prometheus bridge endpoint"
  )
done
grep -Fq \
  'translation_strategy: UnderscoreEscapingWithoutSuffixes' \
  "${REPO_ROOT}/files/configs/amaru/otelcol.yaml" ||
  fail "Amaru collector does not preserve source metric names"
grep -Fq 'metric_expiration: 5s' \
  "${REPO_ROOT}/files/configs/amaru/otelcol.yaml" ||
  fail "Amaru collector does not use the upstream stale-series expiry"
grep -Fq 'processors: [resource/drop_prometheus_labels, batch]' \
  "${REPO_ROOT}/files/configs/amaru/otelcol.yaml" ||
  fail "Amaru collector does not retain the upstream metrics processors"
if grep -Fq 'add_metric_suffixes:' \
  "${REPO_ROOT}/files/configs/amaru/otelcol.yaml"; then
  fail "Amaru collector retains the deprecated metric-suffix setting"
fi

metrics_fixture='
# HELP cardano_node_metrics_blockNum_int block height
cardano_node_metrics_blockNum_int 12345
cardano_node_metrics_epoch_int 900
cardano_node_metrics_slotInEpoch_int 321
cardano_node_metrics_slotNum_int 7.6137225e+07
cardano_node_metrics_density_real 0.048
cardano_node_metrics_txsProcessedNum_int 88
cardano_node_metrics_txsInMempool_int 3
cardano_node_metrics_mempoolBytes_int 2048
cardano_node_metrics_currentKESPeriod_int 0
cardano_node_metrics_remainingKESPeriods_int 0
cardano_node_metrics_connectionManager_inboundConns_int 4
cardano_node_metrics_connectionManager_outboundConns_int 5
cardano_node_metrics_connectionManager_unidirectionalConns_int 6
cardano_node_metrics_served_block_count_int 12
cardano_node_metrics_cardano_build_info{arch="x86_64",dirty="false",os="linux",revision="8be10a21",version="10.11.20260723"} 1
process_runtime 4123168576
process_cpu_live 12.5
process_disk_live_read 2048
process_disk_live_write 1024
process_memory_live_resident 536870912
process_memory_available_virtual 1073741824
process_open_files 42 1785232800000
cardano_node_metrics_txsSyncDuration_int 18
amaru_metrics_mempoolTxInsertionsNum_int{origin="local",result="accepted"} 3
amaru_metrics_mempoolTxInsertionsNum_int{origin="remote",result="accepted"} 7
amaru_metrics_mempoolTxInsertionsNum_int{origin="local",result="rejected_invalid"} 2
amaru_metrics_mempoolTxInsertionsNum_int{origin="remote",result="rejected_duplicate"} 1
amaru_consensus_header_total{outcome="valid"} 100 1785232800000
amaru_consensus_header_total{outcome="invalid"} 2
amaru_consensus_header_total{outcome="invalid header"} 2
amaru_consensus_header_total{outcome="undecodable header"} 3 1785232800000
amaru_consensus_header_total{outcome="store header error"} 4
amaru_consensus_header_total{outcome="duplicate header"} 9
amaru_consensus_fork_switch_total{outcome="valid"} 3
amaru_consensus_fork_switch_total{outcome="invalid"} 1
amaru_consensus_fork_switch_total{outcome="superseded fork"} 2 1785232800000
amaru_consensus_block_fetch_wait_duration_microseconds_sum{outcome="valid"} 9000
amaru_consensus_block_fetch_wait_duration_microseconds_count{outcome="valid"} 3
amaru_consensus_block_fetch_duration_microseconds_sum{outcome="valid"} 12000
amaru_consensus_block_fetch_duration_microseconds_count{outcome="valid"} 3
amaru_consensus_header_forward_duration_microseconds_sum{outcome="valid"} 30000
amaru_consensus_header_forward_duration_microseconds_count{outcome="valid"} 3
'

curl() {
  printf '%s\n' "${metrics_fixture}"
}

node_adapter_process_pid() {
  printf '4242\n'
}

ps() {
  printf '  61\n'
}

getNodeMetrics
assert_eq "${blocknum}" "12345" "block height"
assert_eq "${slotnum}" "76137225" "scientific slot normalization"
assert_eq "${epochnum}" "900" "epoch"
assert_eq "${slot_in_epoch}" "321" "slot in epoch"
assert_eq "${conn_incoming}" "4" "inbound connections"
assert_eq "${conn_outgoing}" "5" "outbound connections"
assert_eq "${conn_uni_dir}" "6" "unidirectional connections"
assert_eq "${blocks_served}" "12" "served blocks"
assert_eq "${running_node_version}" "10.11.20260723" "running version"
assert_eq "${running_node_rev}" "8be10a21" "running revision"
assert_eq "${uptimes}" "61" "service PID uptime"
assert_eq "${amaru_cpu_percent}" "12.5" "Amaru process CPU"
assert_eq "${open_files}" "42" "Amaru open files"
assert_eq "${amaru_disk_read_kib}" "2.0" "Amaru live disk reads"
assert_eq "${amaru_disk_write_kib}" "1.0" "Amaru live disk writes"
assert_eq "${amaru_mempool_sync_ms}" "18" "Amaru latest mempool sync"
assert_eq "${amaru_mempool_insertions_accepted}" "10" "accepted insertions"
assert_eq "${amaru_mempool_insertions_rejected}" "3" "rejected insertions"
assert_eq "${amaru_headers_valid}" "100" "valid consensus headers"
assert_eq "${amaru_headers_rejected}" "11" "rejected consensus headers"
assert_eq "${amaru_fork_switches}" "6" "consensus fork switches"
assert_eq "${amaru_fetch_wait_ms}" "3.00" "mean valid-header fetch wait"
assert_eq "${amaru_block_fetch_ms}" "4.00" "mean valid block fetch"
assert_eq "${amaru_header_forward_ms}" "10.00" \
  "mean valid-header forwarding"
assert_eq "${NODE_METRIC_LABEL[amaru_cpu_percent]}" "Process CPU" \
  "Amaru CPU display label"
assert_eq "${NODE_METRIC_UNIT[amaru_cpu_percent]}" "%" \
  "Amaru CPU display unit"
assert_eq "${NODE_METRIC_UNIT[amaru_disk_read_kib]}" "KiB/s" \
  "Amaru disk-read display unit"
assert_eq "${NODE_METRIC_UNIT[amaru_fetch_wait_ms]}" "ms" \
  "Amaru consensus-duration display unit"
assert_eq "${NODE_CUSTOM_METRICS[*]}" \
  "amaru_cpu_percent amaru_disk_read_kib amaru_disk_write_kib amaru_mempool_sync_ms amaru_mempool_insertions_accepted amaru_mempool_insertions_rejected amaru_headers_valid amaru_headers_rejected amaru_fork_switches amaru_fetch_wait_ms amaru_block_fetch_ms amaru_header_forward_ms" \
  "Amaru custom metric registration order"

for metric in \
  blocknum slotnum epochnum slot_in_epoch conn_incoming conn_outgoing \
  conn_uni_dir blocks_served running_node_version running_node_rev uptimes \
  open_files amaru_cpu_percent amaru_disk_read_kib amaru_disk_write_kib \
  amaru_mempool_sync_ms amaru_mempool_insertions_accepted \
  amaru_mempool_insertions_rejected amaru_headers_valid \
  amaru_headers_rejected amaru_fork_switches amaru_fetch_wait_ms \
  amaru_block_fetch_ms amaru_header_forward_ms; do
  assert_metric_available "${metric}"
done

metrics_fixture='
cardano_node_metrics_blockNum_int 12346
cardano_node_metrics_slotNum_int 76137226
'
getNodeMetrics
assert_metric_unavailable amaru_cpu_percent
assert_metric_unavailable open_files
assert_metric_unavailable amaru_disk_read_kib
assert_metric_unavailable amaru_disk_write_kib
assert_metric_unavailable amaru_mempool_sync_ms
assert_metric_unavailable amaru_mempool_insertions_accepted
assert_metric_unavailable amaru_mempool_insertions_rejected
assert_metric_unavailable amaru_headers_valid
assert_metric_unavailable amaru_headers_rejected
assert_metric_unavailable amaru_fork_switches
assert_metric_unavailable amaru_fetch_wait_ms
assert_metric_unavailable amaru_block_fetch_ms
assert_metric_unavailable amaru_header_forward_ms
assert_eq "${#NODE_CUSTOM_METRICS[@]}" "0" \
  "unavailable Amaru metrics were removed from the custom display"

curl() {
  return 22
}
if getNodeMetrics; then
  fail "failed Amaru metrics scrape returned success"
fi
assert_metric_unavailable blocknum
assert_eq "${#NODE_CUSTOM_METRICS[@]}" "0" \
  "failed scrape retained custom Amaru metrics"

proc_root="${TEMP_ROOT}/proc"
mkdir -p "${proc_root}/4242"
stat_tail="S"
for (( field=0; field<18; field++ )); do
  stat_tail+=" 0"
done
printf '4242 (amaru worker) %s 123400\n' "${stat_tail}" \
  > "${proc_root}/4242/stat"
printf '1300.25 0.00\n' > "${proc_root}/uptime"
getconf() {
  [[ "${1:-}" == "CLK_TCK" ]] && printf '100\n'
}
ps() {
  printf '  4123168448\n'
}
assert_eq "$(
  AMARU_PROCFS_ROOT="${proc_root}" amaru_adapter_process_uptime 4242
)" "66" "monotonic procfs process uptime"

rm -f -- "${proc_root}/4242/stat"
if AMARU_PROCFS_ROOT="${proc_root}" \
  amaru_adapter_process_uptime 4242 >/dev/null 2>&1; then
  fail "process uptime accepted a ps wraparound larger than host uptime"
fi

ps() {
  printf '  77\n'
}
assert_eq "$(
  AMARU_PROCFS_ROOT="${proc_root}" amaru_adapter_process_uptime 4242
)" "77" "bounded ps process uptime fallback"
unset -f ps
unset -f getconf

fake_binary="${TEMP_ROOT}/fake-amaru"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\n" "amaru 10.11.20260723 (8be10a21)"' > "${fake_binary}"
chmod 0755 "${fake_binary}"
NODE_BINARY="${fake_binary}"
assert_eq "$(node_adapter_installed_version)" $'10.11.20260723\t8be10a21' \
  "installed version parsing"

printf 'amaru metrics tests passed\n'
