#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2154,SC2329
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'dingo-metrics skipped: Bash 4+ required\n'
  exit 0
fi

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local description="$3"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${description}: expected '${expected}', got '${actual}'"
}

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library"
# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/dingo-helper-scripts/dingo.adapter"

node_has metrics || fail "Dingo adapter does not advertise normalized metrics"
node_has native_prometheus ||
  fail "Dingo adapter does not advertise its native Prometheus endpoint"

(
  unset NODE_METRICS_HOST NODE_METRICS_PORT NODE_METRICS_PATH
  unset NODE_METRICS_URL DINGO_PROMETHEUS_URL CARDANO_METRICS_PORT
  PROM_HOST="192.0.2.10"
  PROM_PORT="18080"
  node_adapter_defaults
  assert_eq "$(node_adapter_metrics_url)" \
    "http://192.0.2.10:18080/metrics" \
    "Dingo Prometheus host and port override"
)

CONFIGURED_NETWORK=""
common_configure_known_network() {
  CONFIGURED_NETWORK="$1"
}
curl() {
  printf '%s\n' "${DINGO_METRICS_FIXTURE}"
}
date() {
  printf '1700000101\n'
}

NODE_NETWORK="preview"
node_adapter_init monitor || fail "Dingo monitor profile initialization failed"
assert_eq "${CONFIGURED_NETWORK}" "preview" \
  "Dingo monitor profile known-network initialization"

fake_dingo="${TEST_ROOT}/dingo"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "v0.67.1 (commit c29a0099d22f8d8814557bd94de59d969d55cba9)"' \
  > "${fake_dingo}"
chmod 0755 "${fake_dingo}"
NODE_BINARY="${fake_dingo}"
assert_eq "$(node_adapter_installed_version)" $'v0.67.1\tc29a0099' \
  "installed Dingo version and revision mapping"

DINGO_METRICS_FIXTURE='
cardano_node_metrics_blockNum_int{network="preview"} 12345
cardano_node_metrics_epoch_int{network="preview"} 834
cardano_node_metrics_slotInEpoch_int{network="preview"} 321
cardano_node_metrics_slotNum_int{network="preview"} 76543210
cardano_node_metrics_density_real{network="preview"} 0.0425
cardano_node_metrics_txsProcessedNum_int{network="preview"} 900
cardano_node_metrics_txsInMempool_int{network="preview"} 3
cardano_node_metrics_mempoolBytes_int{network="preview"} 4096
cardano_node_metrics_RTS_gcLiveBytes_int{network="preview"} 268435456
cardano_node_metrics_RTS_gcHeapBytes_int{network="preview"} 536870912
cardano_node_metrics_RTS_gcMinorNum_int{network="preview"} 71
cardano_node_metrics_RTS_gcMajorNum_int{network="preview"} 2
cardano_node_metrics_forks_int{network="preview"} 4
cardano_node_metrics_peerSelection_cold{network="preview"} 12
cardano_node_metrics_peerSelection_warm{network="preview"} 5
cardano_node_metrics_peerSelection_hot{network="preview"} 3
cardano_node_metrics_connectionManager_incomingConns{network="preview"} 8
cardano_node_metrics_connectionManager_outgoingConns{network="preview"} 11
cardano_node_metrics_connectionManager_unidirectionalConns{network="preview"} 7
cardano_node_metrics_connectionManager_duplexConns{network="preview"} 6
cardano_node_metrics_connectionManager_fullDuplexConns{network="preview"} 2
cardano_node_metrics_forging_enabled{network="preview"} 0
cardano_node_metrics_nodeStartTime_int{network="preview"} 1700000001
cardano_node_metrics_blockfetchclient_blockdelay_cdfOne_real{network="preview"} 95.582861
cardano_node_metrics_blockfetchclient_blockdelay_cdfThree_real{network="preview"} 98.234567
cardano_node_metrics_blockfetchclient_blockdelay_cdfFive_real{network="preview"} 100
dingo_metrics_peerSelection_InboundWarmHeld{network="preview"} 6
dingo_metrics_peerSelection_InboundHotHeld{network="preview"} 2
dingo_build_info{commit="c29a0099d22f8d8814557bd94de59d969d55cba9",goversion="go1.26.1",network="preview",version="v0.67.1 (commit c29a0099d22f8d8814557bd94de59d969d55cba9)"} 1
dingo_tip_gap_slots{network="preview"} 2
dingo_epoch_length_slots{network="preview"} 86400
dingo_shelley_start_time{network="preview"} 1666656000
'

node_metric_reset_availability
node_adapter_collect_metrics ||
  fail "Dingo metrics collection rejected a valid labelled scrape"

assert_eq "${blocknum}" "12345" "Dingo block height normalization"
assert_eq "${epochnum}" "834" "Dingo epoch normalization"
assert_eq "${slot_in_epoch}" "321" "Dingo epoch slot normalization"
assert_eq "${slotnum}" "76543210" "Dingo absolute slot normalization"
assert_eq "${mempool_tx}" "3" "Dingo mempool transaction normalization"
assert_eq "${mempool_bytes}" "4096" "Dingo mempool byte normalization"
assert_eq "${peer_selection_hot}" "3" "Dingo hot-peer normalization"
assert_eq "${conn_incoming}" "8" "Dingo inbound connection normalization"
assert_eq "${inbound_governor_warm}" "6" \
  "Dingo inbound warm-peer normalization"
assert_eq "${inbound_governor_hot}" "2" \
  "Dingo inbound hot-peer normalization"
assert_eq "${mem_live}" "268435456" "Dingo live-memory normalization"
assert_eq "${forging_enabled}" "0" "Dingo relay forging state normalization"
assert_eq "${blocks_w1s}" "0.95582861" \
  "Dingo one-second propagation ratio normalization"
assert_eq "${blocks_w3s}" "0.98234567" \
  "Dingo three-second propagation ratio normalization"
assert_eq "${blocks_w5s}" "1.00000000" \
  "Dingo five-second propagation ratio normalization"
assert_eq "${running_node_version}" "v0.67.1" \
  "Dingo build version normalization"
assert_eq "${running_node_rev}" "c29a0099" \
  "Dingo build revision normalization"
assert_eq "${dingo_go_version}" "go1.26.1" "Dingo Go version collection"
assert_eq "${tip_gap}" "2" "Dingo normalized tip-gap collection"
assert_eq "${dingo_epoch_length_slots}" "86400" \
  "Dingo native epoch-length collection"
assert_eq "${dingo_shelley_start_time}" "1666656000" \
  "Dingo native Shelley-start collection"
assert_eq "${uptimes}" "100" "Dingo node-start uptime calculation"
assert_eq "${#NODE_CUSTOM_METRICS[@]}" "0" \
  "Dingo static metadata leaked into the live custom-metric registry"
assert_eq "${NODE_INFO_METRICS[*]}" \
  "dingo_go_version dingo_epoch_length_slots dingo_shelley_start_time" \
  "Dingo Network-page metric registration order"
assert_eq "${NODE_METRIC_LABEL[dingo_go_version]}" "Go runtime" \
  "Dingo Go version display label"
assert_eq "${NODE_METRIC_LABEL[dingo_epoch_length_slots]}" "Epoch length" \
  "Dingo epoch-length display label"
assert_eq "${NODE_METRIC_UNIT[dingo_epoch_length_slots]}" "slots" \
  "Dingo epoch-length display unit"
assert_eq "${NODE_METRIC_LABEL[dingo_shelley_start_time]}" "Shelley start" \
  "Dingo Shelley-start display label"
assert_eq "${NODE_METRIC_UNIT[dingo_shelley_start_time]}" "unix s" \
  "Dingo Shelley-start display unit"

for available_metric in \
  blocknum epochnum slot_in_epoch slotnum mempool_tx mempool_bytes \
  peer_selection_hot conn_incoming inbound_governor_warm \
  inbound_governor_hot mem_live forging_enabled \
  running_node_version running_node_rev dingo_go_version \
  tip_gap dingo_epoch_length_slots \
  dingo_shelley_start_time blocks_w1s blocks_w3s blocks_w5s \
  uptimes; do
  node_metric_has "${available_metric}" ||
    fail "Dingo metric '${available_metric}' was parsed but marked unavailable"
done
node_metric_has kesperiod &&
  fail "relay scrape without KES data marked KES period available"

DINGO_METRICS_FIXTURE='
cardano_node_metrics_blockNum_int{network="preview"} 12346
process_start_time_seconds 1.700000001e+09
'
node_metric_reset_availability
node_adapter_collect_metrics ||
  fail "Dingo metrics collection rejected process-start fallback scrape"
assert_eq "${uptimes}" "100" "Dingo process-start uptime fallback"
node_metric_has uptimes ||
  fail "Dingo process-start uptime fallback was marked unavailable"
node_metric_has tip_gap &&
  fail "missing normalized Dingo tip-gap metric was marked available"
node_metric_has dingo_epoch_length_slots &&
  fail "missing Dingo epoch-length metric was marked available"
node_metric_has dingo_shelley_start_time &&
  fail "missing Dingo Shelley-start metric was marked available"
node_metric_has running_node_version &&
  fail "missing Dingo build information was marked available"
[[ ${#NODE_CUSTOM_METRICS[@]} -eq 0 ]] ||
  fail "missing Dingo custom samples remained registered"
[[ ${#NODE_INFO_METRICS[@]} -eq 0 ]] ||
  fail "missing Dingo metadata samples remained registered"

printf 'dingo-metrics passed\n'
