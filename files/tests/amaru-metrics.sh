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
    assert_eq "${AMARU_WITH_OPEN_TELEMETRY}" "metrics" \
      "${network} exports only Amaru metrics to the local collector"
    assert_eq "${AMARU_DB_CHAIN_AUTOMATIC_MIGRATION}" "true" \
      "${network} lets Amaru migrate its chain database"
    assert_eq "${AMARU_PEER}" "${network}-node.play.dev.cardano.org:3001" \
      "${network} upstream peer"
    assert_eq "${OTEL_EXPORTER_OTLP_ENDPOINT}" "http://127.0.0.1:4317" \
      "${network} metrics OTLP/gRPC endpoint"
    if [[ -v OTEL_EXPORTER_OTLP_METRICS_ENDPOINT ]]; then
      fail "${network} config overrides the shared OTLP/gRPC metrics endpoint"
    fi
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
  fail "Amaru collector does not expire stale series quickly"
grep -Fq 'processors: [resource/drop_prometheus_labels, batch]' \
  "${REPO_ROOT}/files/configs/amaru/otelcol.yaml" ||
  fail "Amaru collector does not retain the upstream metrics processors"
if grep -Fq 'add_metric_suffixes:' \
  "${REPO_ROOT}/files/configs/amaru/otelcol.yaml"; then
  fail "Amaru collector contains an unsupported metric-suffix setting"
fi

# The adapter follows the deployed listener settings without sourcing the
# environment file.
(
  unset NODE_PORT CNODE_PORT AMARU_PEERS_LISTEN_ON AMARU_SUBMIT_API_LISTEN_ON
  unset AMARU_ADAPTER_CONFIG_LOADED
  NODE_HOME="${TEMP_ROOT}/deployed"
  mkdir -p "${NODE_HOME}/scripts"
  printf '%s\n' \
    'AMARU_PEERS_LISTEN_ON="0.0.0.0:3102"' \
    'AMARU_SUBMIT_API_LISTEN_ON="127.0.0.1:8090"' \
    > "${NODE_HOME}/scripts/amaru.env"
  node_adapter_defaults
  assert_eq "${NODE_PORT}" "3102" "Amaru deployed listen port"
  assert_eq "${NODE_HAS_HTTP_SUBMIT}" "Y" "Amaru deployed submit API"
)

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
cardano_node_metrics_currentKESPeriod_int 587
cardano_node_metrics_remainingKESPeriods_int 0
cardano_node_metrics_served_block_count_int 12
cardano_node_metrics_cardano_build_info{arch="x86_64",dirty="false",os="linux",revision="8be10a21",version="10.11.20261022"} 1
host_memory_total 1.6768262144e+10
process_runtime 4123168576
process_cpu_live 12.5
process_disk_live_read 2048
process_disk_live_write 1024
process_memory_live_resident 536870912
process_open_files 42 1785232800000
cardano_node_metrics_txsSyncDuration_int 18
amaru_metrics_mempoolTxInsertionsNum_int{origin="local",result="accepted"} 3
amaru_metrics_mempoolTxInsertionsNum_int{origin="remote",result="accepted"} 7
amaru_metrics_mempoolTxInsertionsNum_int{origin="local",result="rejected_invalid"} 2
amaru_metrics_mempoolTxInsertionsNum_int{origin="remote",result="rejected_duplicate"} 1
amaru_consensus_header_total{outcome="valid"} 100 1785232800000
amaru_consensus_header_total{outcome="invalid"} 2
amaru_consensus_header_total{outcome="invalid_header"} 2
amaru_consensus_header_total{outcome="undecodable_header"} 3 1785232800000
amaru_consensus_header_total{outcome="store_header_error"} 4
amaru_consensus_header_total{outcome="duplicate_header"} 9
amaru_consensus_header_total{outcome="pruned"} 5
amaru_consensus_fork_switch_total{outcome="valid"} 3
amaru_consensus_fork_switch_total{outcome="invalid"} 1
amaru_consensus_fork_switch_total{outcome="superseded_fork"} 2 1785232800000
amaru_consensus_slot_start_to_header_duration_microseconds_sum{outcome="valid"} 6000000
amaru_consensus_slot_start_to_header_duration_microseconds_count{outcome="valid"} 3
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

ss() {
  printf '%s\n' \
    '0 0 10.0.0.5:3000 192.0.2.1:3001 users:(("amaru",pid=4242,fd=20))' \
    '0 0 10.0.0.5:3000 192.0.2.2:41234 users:(("amaru",pid=4242,fd=21))' \
    '0 0 127.0.0.1:51234 127.0.0.1:4317 users:(("amaru",pid=4242,fd=9))' \
    '0 0 10.0.0.5:22 198.51.100.9:5555 users:(("sshd",pid=1,fd=3))'
}

limits_root="${TEMP_ROOT}/limits"
mkdir -p "${limits_root}/4242"
printf '%s\n' \
  'Limit                     Soft Limit           Hard Limit           Units' \
  'Max open files            65536                524288               files' \
  > "${limits_root}/4242/limits"
AMARU_PROCFS_ROOT="${limits_root}"

getNodeMetrics
assert_eq "${blocknum}" "12345" "block height"
assert_eq "${slotnum}" "76137225" "scientific slot normalization"
assert_eq "${epochnum}" "900" "epoch"
assert_eq "${slot_in_epoch}" "321" "slot in epoch"
assert_eq "${forks}" "3" "fork switches that changed the selected chain"
assert_eq "${conn_total}" "2" "established non-loopback node sessions"
assert_eq "${blocks_served}" "12" "served blocks"
assert_eq "${running_node_version}" "10.11.20261022" "running version"
assert_eq "${running_node_rev}" "8be10a21" "running revision"
assert_eq "${uptimes}" "61" "service PID uptime"
assert_eq "${open_files}" "42" "Amaru open files"
assert_eq "${max_files}" "65536" "Amaru open-file soft limit"
assert_eq "${amaru_cpu_percent}" "12.5" "Amaru process CPU"
assert_eq "${amaru_disk_read_rate}" "2048" "Amaru live disk reads"
assert_eq "${amaru_disk_write_rate}" "1024" "Amaru live disk writes"
assert_eq "${amaru_mempool_sync_ms}" "18" "Amaru latest mempool sync"
assert_eq "${amaru_tx_accepted}" "10" "accepted insertions"
assert_eq "${amaru_tx_rejected}" "3" "rejected insertions"
assert_eq "${amaru_headers_rejected}" "11" "rejected consensus headers"
assert_eq "${amaru_kes_period}" "587" "network KES period on the Network page"
assert_eq "${amaru_platform}" "linux/x86_64" "Amaru build platform"
assert_eq "${amaru_host_memory}" "15.6" "Amaru host memory"
for metric in kesperiod remaining_kes_periods conn_incoming conn_outgoing \
  block_delay blocks_w1s amaru_header_delay_ms amaru_block_fetch_ms; do
  assert_metric_unavailable "${metric}"
done
assert_eq "${NODE_CUSTOM_METRICS[*]}" \
  "amaru_cpu_percent amaru_disk_read_rate amaru_disk_write_rate amaru_tx_accepted amaru_tx_rejected amaru_mempool_sync_ms amaru_headers_rejected" \
  "Amaru custom metric registration order before a second scrape"
for metric in "${NODE_CUSTOM_METRICS[@]}"; do
  (( ${#NODE_METRIC_LABEL[${metric}]} <= 10 )) ||
    fail "Amaru custom label is clipped by gLiveView: ${NODE_METRIC_LABEL[${metric}]}"
done
assert_eq "${NODE_METRIC_UNIT[amaru_disk_read_rate]}" "B" \
  "Amaru disk-read rate uses auto-scaled bytes"

# One new live block between scrapes: 0.8 s to the header, 2 ms waiting and
# 150 ms fetching.
metrics_fixture="$(
  printf '%s\n' "${metrics_fixture}" | awk '
    /slot_start_to_header_duration_microseconds_sum/ { print $1, 6800000; next }
    /slot_start_to_header_duration_microseconds_count/ { print $1, 4; next }
    /block_fetch_wait_duration_microseconds_sum/ { print $1, 11000; next }
    /block_fetch_wait_duration_microseconds_count/ { print $1, 4; next }
    /block_fetch_duration_microseconds_sum/ { print $1, 162000; next }
    /block_fetch_duration_microseconds_count/ { print $1, 4; next }
    /header_forward_duration_microseconds_sum/ { print $1, 70000; next }
    /header_forward_duration_microseconds_count/ { print $1, 4; next }
    { print }
  '
)"
getNodeMetrics
assert_eq "${block_delay}" "0.952" "slot start to block received"
assert_eq "${blocks_w1s}" "1.0000" "live blocks received within one second"
assert_eq "${amaru_header_delay_ms}" "800.0" "latest header delay"
assert_eq "${amaru_fetch_wait_ms}" "2.0" "latest block fetch wait"
assert_eq "${amaru_block_fetch_ms}" "150.0" "latest block fetch"
assert_eq "${amaru_header_forward_ms}" "40.0" "latest header forwarding"

# A quiet interval keeps the latest values; a slow block lowers the shares.
getNodeMetrics
assert_eq "${block_delay}" "0.952" "block delay persists between blocks"
metrics_fixture="$(
  printf '%s\n' "${metrics_fixture}" | awk '
    /slot_start_to_header_duration_microseconds_sum/ { print $1, 10800000; next }
    /slot_start_to_header_duration_microseconds_count/ { print $1, 5; next }
    /block_fetch_wait_duration_microseconds_sum/ { print $1, 12000; next }
    /block_fetch_wait_duration_microseconds_count/ { print $1, 5; next }
    /block_fetch_duration_microseconds_sum/ { print $1, 362000; next }
    /block_fetch_duration_microseconds_count/ { print $1, 5; next }
    { print }
  '
)"
getNodeMetrics
assert_eq "${block_delay}" "4.201" "slow live block delay"
assert_eq "${blocks_w1s}" "0.5000" "share of live blocks within one second"
assert_eq "${blocks_w5s}" "1.0000" "share of live blocks within five seconds"

# Durations expire when no new block arrives for a long time.
for key in "${!AMARU_HIST_LAST_AT[@]}"; do
  AMARU_HIST_LAST_AT["${key}"]=1
done
getNodeMetrics
assert_metric_unavailable block_delay
assert_metric_unavailable amaru_block_fetch_ms

metrics_fixture='
cardano_node_metrics_blockNum_int 12346
cardano_node_metrics_slotNum_int 76137226
'
getNodeMetrics
for metric in forks conn_incoming amaru_cpu_percent open_files \
  amaru_disk_read_rate amaru_disk_write_rate amaru_mempool_sync_ms \
  amaru_tx_accepted amaru_tx_rejected amaru_headers_rejected \
  amaru_fetch_wait_ms amaru_block_fetch_ms amaru_header_forward_ms; do
  assert_metric_unavailable "${metric}"
done
assert_eq "${#NODE_CUSTOM_METRICS[@]}" "0" \
  "unavailable Amaru metrics were removed from the custom display"
assert_eq "${#NODE_INFO_METRICS[@]}" "0" \
  "unavailable Amaru metadata was removed from the Network page"

curl() {
  return 22
}
if getNodeMetrics; then
  fail "failed Amaru metrics scrape returned success"
fi
assert_metric_unavailable blocknum
assert_eq "${#NODE_CUSTOM_METRICS[@]}" "0" \
  "failed scrape retained custom Amaru metrics"
unset -f ss
unset AMARU_PROCFS_ROOT

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
  'printf "%s\n" "amaru 10.11.20261022 (8be10a21)"' > "${fake_binary}"
chmod 0755 "${fake_binary}"
NODE_BINARY="${fake_binary}"
assert_eq "$(node_adapter_installed_version)" $'10.11.20261022\t8be10a21' \
  "installed version parsing"

printf 'amaru metrics tests passed\n'
