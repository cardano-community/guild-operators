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
node_has forge || fail "Dingo adapter does not advertise block production"
node_has kes || fail "Dingo adapter does not advertise KES metrics"

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
cardano_node_metrics_peerSelection_KnownPeers{network="preview"} 20
cardano_node_metrics_peerSelection_EstablishedPeers{network="preview"} 7
cardano_node_metrics_peerSelection_ActivePeers{network="preview"} 3
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
dingo_metrics_peerSelection_peers_by_source{network="preview",source="inbound",state="cold"} 0
dingo_metrics_peerSelection_peers_by_source{network="preview",source="inbound",state="warm"} 2
dingo_metrics_peerSelection_peers_by_source{network="preview",source="inbound",state="hot"} 1
dingo_metrics_peerSelection_peers_by_source{network="preview",source="ledger",state="hot"} 2
dingo_mempool_capacity_bytes{network="preview"} 1048576
dingo_ledger_block_adoption_delay_seconds_sum{network="preview"} 25
dingo_ledger_block_adoption_delay_seconds_count{network="preview"} 20
go_gc_duration_seconds_count 73
go_sched_gomaxprocs_threads 4
dingo_metrics_mempool_info{network="preview",implementation="fifo"} 1
dingo_build_info{commit="c29a0099d22f8d8814557bd94de59d969d55cba9",goversion="go1.26.1",network="preview",version="v0.67.1 (commit c29a0099d22f8d8814557bd94de59d969d55cba9)"} 1
dingo_tip_gap_slots{network="preview"} 2
dingo_epoch_length_slots{network="preview"} 86400
dingo_shelley_start_time{network="preview"} 1666656000
go_goroutines 41
process_open_fds 128
process_max_fds 1048576
dingo_database_size_bytes{store="blob"} 1000
dingo_database_size_bytes{store="metadata"} 500
dingo_cbor_cache_utxo_hot_hits_total 80
dingo_cbor_cache_utxo_hot_misses_total 20
dingo_cbor_cache_block_lru_hits_total 0
dingo_cbor_cache_block_lru_misses_total 0
dingo_forge_slot_clock_errors_total 2
dingo_governance_proposal_decode_failures_total 0
dingo_chainsync_unrecoverable_rollback_total 1
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
assert_eq "${peer_selection_hot}" "2" "Dingo outbound hot peers exclude inbound peers"
assert_eq "${peer_selection_warm}" "3" "Dingo outbound warm peers exclude inbound peers"
assert_eq "${peer_selection_cold}" "12" "Dingo outbound cold peers exclude inbound peers"
assert_eq "${peer_known}" "20" "Dingo known-peer normalization"
assert_eq "${peer_established}" "7" "Dingo established-peer normalization"
assert_eq "${peer_active}" "3" "Dingo active-peer normalization"
assert_eq "${conn_incoming}" "8" "Dingo inbound connection normalization"
assert_eq "${inbound_governor_warm}" "6" \
  "Dingo inbound warm-peer normalization"
assert_eq "${inbound_governor_hot}" "2" \
  "Dingo inbound hot-peer normalization"
assert_eq "${mem_live}" "268435456" "Dingo live-memory normalization"
node_metric_has gc_minor &&
  fail "Go collections were reported as GHC minor collections"
node_metric_has gc_major &&
  fail "Go forced collections were reported as GHC major collections"
assert_eq "${dingo_gc_cycles}" "73" "Dingo total Go GC cycles"
assert_eq "${dingo_mempool_fill}" "0.4" "Dingo mempool fill percentage"
assert_eq "${dingo_adopt_delay}" "1.25" "Dingo mean block adoption delay"
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
assert_eq "${open_files}" "128" "Dingo open-file collection"
assert_eq "${max_files}" "1048576" "Dingo maximum-file collection"
assert_eq "${dingo_goroutines}" "41" "Dingo goroutine collection"
assert_eq "${dingo_database_bytes}" "1500" "Dingo database-size aggregation"
assert_eq "${dingo_utxo_cache_hits}" "80.0" \
  "Dingo UTxO-cache hit-ratio calculation"
assert_eq "${dingo_block_cache_hits}" "n/a" \
  "Dingo empty block-cache hit-ratio handling"
assert_eq "${dingo_slot_clock_errors}" "2" \
  "Dingo nonzero slot-clock error collection"
assert_eq "${dingo_rollback_errors}" "1" \
  "Dingo nonzero rollback error collection"
assert_eq "${uptimes}" "100" "Dingo node-start uptime calculation"
assert_eq "${NODE_CUSTOM_METRICS[*]}" \
  "dingo_goroutines dingo_gc_cycles dingo_database_bytes dingo_utxo_cache_hits dingo_block_cache_hits dingo_mempool_fill dingo_adopt_delay dingo_slot_clock_errors dingo_rollback_errors" \
  "Dingo live custom-metric registration order"
assert_eq "${NODE_INFO_METRICS[*]}" \
  "dingo_go_version dingo_epoch_length_slots dingo_shelley_start_time dingo_gomaxprocs dingo_mempool_impl dingo_mempool_capacity" \
  "Dingo Network-page metric registration order"
for custom_metric in "${NODE_CUSTOM_METRICS[@]}"; do
  (( ${#NODE_METRIC_LABEL[${custom_metric}]} <= 10 )) ||
    fail "Dingo custom label is clipped by gLiveView: ${NODE_METRIC_LABEL[${custom_metric}]}"
done
for relay_hidden in leader_lost leader_sched_slots forge_keys_valid \
  dingo_slot_battles dingo_forge_sync_skips node_alert sync_phase; do
  node_metric_has "${relay_hidden}" &&
    fail "Dingo relay reported producer or status field ${relay_hidden}"
done
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
assert_eq "${NODE_METRIC_LABEL[dingo_database_bytes]}" "DB size" \
  "Dingo database-size display label"
assert_eq "${NODE_METRIC_UNIT[dingo_database_bytes]}" "B" \
  "Dingo database-size display unit"
assert_eq "${NODE_METRIC_UNIT[dingo_utxo_cache_hits]}" "%" \
  "Dingo UTxO-cache display unit"
assert_eq "${NODE_METRIC_UNIT[dingo_block_cache_hits]}" "" \
  "Dingo undefined block-cache display unit"

for available_metric in \
  blocknum epochnum slot_in_epoch slotnum mempool_tx mempool_bytes \
  peer_selection_hot conn_incoming inbound_governor_warm \
  inbound_governor_hot mem_live forging_enabled \
  running_node_version running_node_rev dingo_go_version \
  tip_gap dingo_epoch_length_slots \
  dingo_shelley_start_time blocks_w1s blocks_w3s blocks_w5s \
  peer_known peer_established peer_active open_files max_files \
  dingo_goroutines dingo_database_bytes dingo_utxo_cache_hits \
  dingo_block_cache_hits dingo_slot_clock_errors dingo_rollback_errors \
  uptimes; do
  node_metric_has "${available_metric}" ||
    fail "Dingo metric '${available_metric}' was parsed but marked unavailable"
done
node_metric_has kesperiod &&
  fail "relay scrape without KES data marked KES period available"

DINGO_METRICS_FIXTURE='
cardano_node_metrics_blockNum_int{network="preview"} 12346
cardano_node_metrics_forging_enabled{network="preview"} 1
cardano_node_metrics_currentKESPeriod_int{network="preview"} 500
cardano_node_metrics_remainingKESPeriods_int{network="preview"} 12
cardano_node_metrics_operationalCertificateStartKESPeriod_int{network="preview"} 480
cardano_node_metrics_operationalCertificateExpiryKESPeriod_int{network="preview"} 512
cardano_node_metrics_Forge_about_to_lead_int{network="preview"} 1003
cardano_node_metrics_Forge_node_is_leader_int{network="preview"} 3
cardano_node_metrics_Forge_node_not_leader_int{network="preview"} 1000
cardano_node_metrics_Forge_forged_int{network="preview"} 3
cardano_node_metrics_Forge_adopted_int{network="preview"} 2
cardano_node_metrics_Forge_could_not_forge_int{network="preview"} 1
cardano_node_metrics_nodeStartTime_int{network="preview"} 1700000001
cardano_node_metrics_epoch_int{network="preview"} 834
dingo_metrics_slotBattlesTotal_int{network="preview"} 2
dingo_forge_sync_skip_total{network="preview"} 4
dingo_forge_validation_failed_total{network="preview"} 0
dingo_forge_missed_leader_slots_total{network="preview"} 1
dingo_metrics_leader_last_evaluated_epoch_int{network="preview"} 835
dingo_metrics_leader_last_epoch_slots_won_int{network="preview"} 4
dingo_forge_credentials_valid{network="preview"} 1
dingo_forge_opcert_counter_loaded{network="preview"} 7
dingo_forge_opcert_counter_onchain{network="preview"} NaN
dingo_forge_stale_tip_skip_total{network="preview",reason="applied_tip_stale"} 2
dingo_forge_stale_tip_skip_total{network="preview",reason="peer_height_gap"} 3
dingo_metrics_blockForgingLatency_seconds_sum{network="preview"} 1.5
dingo_metrics_blockForgingLatency_seconds_count{network="preview"} 6
dingo_forge_slots_per_kes_period{network="preview"} 129600
'
node_metric_reset_availability
node_adapter_collect_metrics ||
  fail "Dingo metrics collection rejected a producer scrape"
assert_eq "${leader_lost}" "1" "Dingo lost leader slots"
assert_eq "${leader_sched_slots}" "4" "Dingo scheduled leader slots"
assert_eq "${leader_sched_epoch}" "835" "Dingo leader schedule epoch"
assert_eq "${forge_keys_valid}" "1" "Dingo forging credential state"
assert_eq "${opcert_counter_disk}" "7" "Dingo loaded OpCert counter"
node_metric_has opcert_counter_chain &&
  fail "Dingo NaN on-chain OpCert counter was marked available"
node_metric_has missed_slots &&
  fail "Dingo lost leader slots were reported as missed leadership checks"
assert_eq "${dingo_forge_tip_skips}" "5" "Dingo stale-tip forge skips"
assert_eq "${dingo_forge_latency}" "0.25" "Dingo mean forging latency"
assert_eq "${dingo_slots_per_kes}" "129600" "Dingo KES period length"
node_metric_has dingo_forge_validation_failures &&
  fail "Dingo zero forged-block validation failures were displayed"
assert_eq "${forging_enabled}" "1" "Dingo producer forging state"
assert_eq "${kesperiod}" "500" "Dingo current KES period"
assert_eq "${remaining_kes_periods}" "12" "Dingo remaining KES periods"
assert_eq "${opcert_start_kes}" "480" "Dingo OpCert start KES period"
assert_eq "${opcert_expiry_kes}" "512" "Dingo OpCert expiry KES period"
assert_eq "${about_to_lead}" "1003" "Dingo leadership checks"
assert_eq "${isleader}" "3" "Dingo leader slots"
assert_eq "${not_leader}" "1000" "Dingo non-leader slots"
assert_eq "${adopted}" "2" "Dingo adopted blocks"
assert_eq "${didntadopt}" "1" "Dingo non-adopted forged blocks"
assert_eq "${could_not_forge}" "1" "Dingo failed forge attempts"
assert_eq "${dingo_slot_battles}" "2" "Dingo slot battles"
assert_eq "${dingo_forge_sync_skips}" "4" "Dingo forge sync skips"
for producer_metric in \
  forging_enabled kesperiod remaining_kes_periods opcert_start_kes \
  opcert_expiry_kes about_to_lead isleader not_leader adopted didntadopt \
  could_not_forge dingo_slot_battles dingo_forge_sync_skips; do
  node_metric_has "${producer_metric}" ||
    fail "Dingo producer metric '${producer_metric}' was marked unavailable"
done

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
node_metric_has peer_known &&
  fail "missing Dingo peer-set metrics were marked available"
node_metric_has open_files &&
  fail "missing Dingo process-file metrics were marked available"
[[ ${#NODE_CUSTOM_METRICS[@]} -eq 0 ]] ||
  fail "missing Dingo custom samples remained registered"
[[ ${#NODE_INFO_METRICS[@]} -eq 0 ]] ||
  fail "missing Dingo metadata samples remained registered"

DINGO_METRICS_FIXTURE='
cardano_node_metrics_blockNum_int{network="preview"} 12346
cardano_node_metrics_forging_enabled{network="preview"} 1
dingo_ledger_pipeline_halted{network="preview"} 1
dingo_ledger_pipeline_stuck{network="preview"} 0
dingo_equivocation_total{network="preview",pool_id="pool1other",self_key="false"} 3
dingo_equivocation_total{network="preview",pool_id="pool1self",self_key="true"} 1
dingo_forge_credentials_valid{network="preview"} 0
dingo_mithril_snapshot_restore_state{network="preview"} 3
dingo_ledger_pipeline_no_progress_restarts{network="preview"} 2
'
node_metric_reset_availability
node_adapter_collect_metrics ||
  fail "Dingo metrics collection rejected an alerting scrape"
assert_eq "${node_alert}" \
  "Ledger halted, Own pool equivocation, Forging keys invalid, Mithril restore waiting" \
  "Dingo operator alerts"
assert_eq "${forge_keys_valid}" "0" "Dingo invalid forging credentials"
assert_eq "${dingo_pipe_restarts}" "2" "Dingo ledger pipeline restarts"

DINGO_METRICS_FIXTURE='
dingo_mithril_sync_completed{network="preview"} 0
dingo_mithril_sync_errors_total{network="preview"} 0
dingo_mithril_sync_phase_active{network="preview",phase="bootstrap"} 0
dingo_mithril_sync_phase_active{network="preview",phase="ledger_import"} 1
dingo_mithril_sync_ledger_import_percent{network="preview",stage="accounts"} 57.3
dingo_mithril_sync_ledger_import_percent{network="preview",stage="utxo"} 100
dingo_mithril_sync_ledger_import_total{network="preview",stage="accounts"} 197911
dingo_mithril_sync_ledger_import_total{network="preview",stage="utxo"} 2147553
process_start_time_seconds 1.700000001e+09
'
node_metric_reset_availability
node_adapter_collect_metrics ||
  fail "Dingo metrics collection rejected a bootstrap scrape"
assert_eq "${sync_phase}" "Ledger accounts" "Dingo bootstrap phase"
assert_eq "${sync_progress}" "57.3" "Dingo bootstrap progress"
assert_eq "${running_node_version}" "v0.67.1" \
  "Dingo bootstrap falls back to the installed version"
node_metric_has node_alert &&
  fail "healthy Dingo bootstrap raised an alert"

DINGO_METRICS_FIXTURE='
dingo_mithril_sync_completed{network="preview"} 0
dingo_mithril_sync_phase_active{network="preview",phase="bootstrap"} 1
dingo_mithril_sync_download_percent{network="preview"} 12.5
dingo_mithril_sync_download_bytes_per_second{network="preview"} 52428800
dingo_mithril_sync_errors_total{network="preview"} 2
'
node_metric_reset_availability
node_adapter_collect_metrics ||
  fail "Dingo metrics collection rejected a download scrape"
assert_eq "${sync_phase}" "Mithril download" "Dingo download phase"
assert_eq "${sync_progress}" "12.5" "Dingo download progress"
assert_eq "${sync_rate}" "50.0 MiB/s" "Dingo download rate"
assert_eq "${node_alert}" "Mithril sync errors" "Dingo Mithril sync error alert"

# The adapter follows the deployed listener settings and sends an optional
# metrics token on stdin instead of argv.
(
  unset NODE_PORT CNODE_PORT NODE_METRICS_HOST NODE_METRICS_PORT
  unset NODE_METRICS_URL PROM_HOST PROM_PORT CARDANO_METRICS_PORT
  unset DINGO_ADAPTER_CONFIG_LOADED DINGO_METRICS_AUTH_TOKEN NODE_CONFIG
  NODE_HOME="${TEST_ROOT}/dingo-home"
  mkdir -p "${NODE_HOME}/files" "${NODE_HOME}/scripts"
  printf '%s\n' \
    'relayPort: 3101' \
    'metricsBindAddr: "10.1.2.3"' \
    'metricsPort: 12898' \
    > "${NODE_HOME}/files/dingo.yaml"
  printf '%s\n' 'DINGO_METRICS_AUTH_TOKEN="s3cr3t-token"' \
    > "${NODE_HOME}/scripts/dingo.env"
  node_adapter_defaults
  assert_eq "${NODE_PORT}" "3101" "Dingo deployed relay port"
  assert_eq "${NODE_METRICS_URL}" "http://10.1.2.3:12898/metrics" \
    "Dingo deployed metrics listener"
  curl() {
    local argument
    for argument in "$@"; do
      [[ "${argument}" != *s3cr3t-token* ]] ||
        fail "Dingo metrics token was passed in argv"
    done
    [[ " $* " == *" --config - "* ]] ||
      fail "Dingo metrics token was not passed as a curl config"
    grep -Fqx 'header = "Authorization: Bearer s3cr3t-token"' ||
      fail "Dingo metrics token header was not sent"
    printf 'cardano_node_metrics_blockNum_int{network="preview"} 1\n'
  }
  node_metric_reset_availability
  node_adapter_collect_metrics ||
    fail "Dingo authenticated metrics collection failed"
  assert_eq "${blocknum}" "1" "Dingo authenticated scrape"
)

printf 'dingo-metrics passed\n'
