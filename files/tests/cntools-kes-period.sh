#!/usr/bin/env bash
# CNTools on a node without a Shelley genesis file or local query (Amaru):
# the KES constants come from the common network table, and the current KES
# period from the node's metrics, so KES health and Rotate need no typed
# period. A genesis file and a local node query still come first.
set -uo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  printf 'cntools kes period tests skipped: Bash 5+ required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-kes-period.XXXXXX")" && pwd -P)" || exit 1
trap 'rm -rf "${WORK}"' EXIT
failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/common-helper-scripts/lib/node-api.library" || exit 1
for file in core/startup.sh core/health.sh lib/pool-kes.sh; do
  # shellcheck source=/dev/null
  source "${CNTOOLS_SOURCE}/${file}" || exit 1
done

# ── KES constants: genesis file first, then the network table ────────────────
constants() {
  CNTOOLS_SLOTS_PER_KES_PERIOD="${1}" CNTOOLS_MAX_KES_EVOLUTIONS='' CNTOOLS_SHELLEY_GENESIS="${2}" CNTOOLS_NETWORK="${3}"
  cntools_startup_kes_constants
  printf '%s/%s' "${CNTOOLS_SLOTS_PER_KES_PERIOD}" "${CNTOOLS_MAX_KES_EVOLUTIONS}"
}
assert_eq "$(constants '' '' preprod)" "129600/62" "preprod without a genesis file"
assert_eq "$(constants '' '' mainnet)" "129600/62" "mainnet without a genesis file"
assert_eq "$(constants '' "${WORK}/missing.json" preview)" "129600/62" "an unreadable genesis path"
printf '{"slotsPerKESPeriod":3600,"maxKESEvolutions":120}\n' > "${WORK}/shelley-genesis.json"
assert_eq "$(constants '' "${WORK}/shelley-genesis.json" preprod)" "/" "a genesis file wins"
assert_eq "$(constants '' '' dijkstra)" "/" "a network outside the table"
assert_eq "$(constants 7200 '' preprod)" "7200/62" "an env SLOTS_PER_KES_PERIOD is kept"

# ── one value from the node's metrics ────────────────────────────────────────
METRICS='# HELP cardano_node_metrics_currentKESPeriod_int current KES period
# TYPE cardano_node_metrics_currentKESPeriod_int gauge
cardano_node_metrics_currentKESPeriod_int 1.075e+03
cardano_node_metrics_slotNum_int 1.39418226e+08
dingo_forge_opcert_counter_loaded{pool="x"} 3'
cntools_health_local_metrics_url() { [[ "${METRICS_UP:-Y}" == Y ]] || return 1; printf 'http://127.0.0.1:8889/metrics\n'; }
cntools_health_fetch_local() { printf '%s\n' "${METRICS}"; }
value=''
cntools_health_local_metric_into value cardano_node_metrics_currentKESPeriod_int
assert_eq "${value}" "1075" "a gauge in exponent notation"
cntools_health_local_metric_into value dingo_forge_opcert_counter_loaded
assert_eq "${value}" "3" "a labelled gauge"
cntools_health_local_metric_into value cardano_node_metrics_operationalCertificateStartKESPeriod_int &&
  fail "a gauge the node does not export"
METRICS_UP=N cntools_health_local_metric_into value cardano_node_metrics_currentKESPeriod_int &&
  fail "metrics that cannot be read"

# ── Rotate: local node, then node metrics, then Koios ────────────────────────
cntools_pool_public_file_safe() { [[ -f "$1" && ! -L "$1" ]]; }
LOCAL=N KOIOS_TIP=139418226
cntools_transaction_local_backend_ready() { [[ "${LOCAL}" == Y ]]; }
cntools_funding_tip_into() {
  case "$2" in
    local) printf -v "$1" '%s' 139400000 ;;
    koios) printf -v "$1" '%s' "${KOIOS_TIP}" ;;
  esac
}
period() {
  CNTOOLS_MODE=local CNTOOLS_KOIOS_ENABLED=Y CNTOOLS_SHELLEY_GENESIS='' CNTOOLS_SLOTS_PER_KES_PERIOD=129600
  cntools_kes_period_collect
  printf '%s · %s' "${CNTOOLS_KES_CURRENT}" "${CNTOOLS_KES_PERIOD_SOURCE}"
}
assert_eq "$(period)" "1075 · Node metrics" "Amaru: the node's metrics"
assert_eq "$(LOCAL=Y period)" "1075 · Local node" "a local node query comes first"
assert_eq "$(METRICS_UP=N period)" "1075 · Koios API" "Koios when the node reports nothing"
assert_eq "$(CNTOOLS_MODE=offline CNTOOLS_SLOTS_PER_KES_PERIOD=129600; cntools_kes_period_collect; printf '%s' "${CNTOOLS_KES_CURRENT}")" "" "offline asks for the period"

if (( failures > 0 )); then
  printf '%s cntools kes period check(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'cntools kes period tests passed\n'
