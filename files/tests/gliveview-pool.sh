#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2329
# gLiveView's pool data from Koios: the background jobs and what the page
# takes from them, with Koios answering, failing and answering nonsense.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'gliveview-pool skipped: Bash 4+ required\n'
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

command -v jq >/dev/null 2>&1 || { printf 'gliveview-pool skipped: jq required\n'; exit 0; }

GLIVEVIEW="${REPO_ROOT}/scripts/common-helper-scripts/gLiveView.sh"
for glv_function in glv_is_int ui_scale ui_fmt_int ui_fmt_tenths glv_koios_usable glv_koios glv_koios_count \
  glv_pool_id_find glv_blocks_per_epoch glv_pool_job_run glv_pool_failed glv_pool_load \
  glv_history_job_run glv_history_load glv_history_rows glv_ada_short glv_ada_int glv_pool_vital; do
  glv_definition="$(sed -n "/^${glv_function}() {/,/^}/p" "${GLIVEVIEW}")"
  [[ -n "${glv_definition}" ]] || fail "gLiveView no longer defines ${glv_function}"
  eval "${glv_definition}"
done
# The pool section's state, as the script declares it.
eval "$(sed -n "/^POOL_JOB_PID=''$/,/^declare -gA D_LED=/p" "${GLIVEVIEW}")"
[[ "${POOL_STATE}" == off ]] || fail "the pool section's state could not be loaded"

C_OK="ok"; C_WARN="warn"; C_DANGER="danger"
KOIOS_API="https://koios.test/api/v1"
KOIOS_API_HEADERS=()
ENABLE_KOIOS=Y
EPOCH_LENGTH=432000
ACTIVE_SLOTS_COEFF=0.05
POOL_FOLDER="${TEST_ROOT}/priv/pool"
POOL_NAME="POOL1"
POOL_ID=""
CCLI=""
D_NOW=1000
declare -A D_STATUS=()
D_SCHEDULE_EPOCH=""
HIST_JOB_FILE="${TEST_ROOT}/history"
POOL_JOB_FILE="${TEST_ROOT}/pool"
epochnum=668
POOL_B32="pool1edqwpnln3zr9gj9sfsmyl72pen6hdwev07xgqj7uz5mkjrgfj6h"
POOL_HEX="cb40e0cff388865448b04c364ff9419cf576bb2c7f8c804bdc153769"

# Koios stand-in. KOIOS_MODE: ok, down (no connection), html (an error page
# with status 200), empty (Koios does not know the pool).
KOIOS_MODE=ok
CURL_CALLS="${TEST_ROOT}/curl.calls"
curl() {
  local url='' headers='' body='' path offset
  while (( $# > 0 )); do
    case "$1" in
      -D) headers="$2"; shift ;;
      -d) body="$2"; shift ;;
      -H|-X|-m) shift ;;
      http*) url="$1" ;;
    esac
    shift
  done
  printf '%s %s\n' "${url}" "${body}" >> "${CURL_CALLS}"
  case "${KOIOS_MODE}" in
    down) return 7 ;;
    html) printf '<html><body>502 Bad Gateway</body></html>\n'; return 0 ;;
  esac
  path="${url#"${KOIOS_API}"/}"
  case "${path}" in
    pool_info)
      if [[ "${KOIOS_MODE}" == empty ]]; then printf '[]\n'; return 0; fi
      # The name carries a terminal escape and the field separator.
      printf '%s\n' '[{"pool_id_bech32":"'"${POOL_B32}"'","margin":0.015,"fixed_cost":"170000000","pledge":"250000000000",
        "meta_json":{"name":"Evil\u001b[31m|Pool","ticker":"PL1"},"pool_status":"registered","retiring_epoch":null,
        "active_stake":"22412000000000","block_count":4812,"live_pledge":"263412000000","live_stake":"22414000000000",
        "live_delegators":412,"live_saturation":28.73}]' ;;
    pool_stake_snapshot*)
      printf '%s\n' '[{"snapshot":"Go","epoch_no":667,"pool_stake":"22390000000000","active_stake":"21513866539443887"},
        {"snapshot":"Set","epoch_no":668,"pool_stake":"22410000000000","active_stake":"21493865594180608"},
        {"snapshot":"Mark","epoch_no":669,"pool_stake":"22430000000000","active_stake":"21495937909689689"}]' ;;
    pool_blocks*_epoch_no=668*) printf '%s\n' "[$(printf '{"block_height":%s},' 1 2 3 4 5 6 7 8)"'{"block_height":9}]' ;;
    pool_blocks*_epoch_no=667*) printf '[%s{"block_height":0}]\n' "$(for i in $(seq 1 23); do printf '{"block_height":%s},' "${i}"; done)" ;;
    pool_list*pool_id_hex=eq.${POOL_HEX}*) printf '[{"pool_id_bech32":"%s"}]\n' "${POOL_B32}" ;;
    pool_delegators_history*)
      # Counted through Content-Range. Koios has not counted the next epoch.
      offset="${path##*_epoch_no=}"; offset="${offset%%&*}"
      case "${offset}" in 669) offset=0 ;; 668) offset=412 ;; 667) offset=409 ;; *) offset=400 ;; esac
      [[ -z "${headers}" ]] || printf 'HTTP/2 200\r\ncontent-range: 0-0/%s\r\n\r\n' "${offset}" > "${headers}"
      printf '[{"stake_address":"stake1u0"}]\n' ;;
    pool_history*)
      [[ "${path}" == *"epoch_no=lt.667"* ]] || { printf '[]\n'; return 0; }
      offset="${path##*offset=}"; offset="${offset%%&*}"
      # Twelve settled epochs, 666 down to 655.
      [[ -z "${headers}" ]] || printf 'HTTP/2 200\r\ncontent-range: %s-%s/12\r\n\r\n' "${offset}" "$((offset + 9))" > "${headers}"
      jq -nc --argjson offset "${offset}" '[range($offset; ([$offset + 10, 12] | min)) as $i |
        {epoch_no: (666 - $i), active_stake: "22400000000000", active_stake_pct: 0.1045, delegator_cnt: (405 - $i),
         block_cnt: (20 + $i), pool_fees: "271000000", deleg_rewards: "10184000000", epoch_ros: 2.41}]' ;;
    *) return 22 ;;
  esac
}

# ── no pool ID, and an ID from the pool folder ───────────────────────────────
glv_pool_job_run 668 21600 > "${TEST_ROOT}/job"
assert_eq "$(cat "${TEST_ROOT}/job")" "none" "no pool ID anywhere"
glv_pool_load "${TEST_ROOT}/job"
assert_eq "${POOL_STATE}" "none" "state without a pool ID"
[[ ! -s "${CURL_CALLS}" ]] || fail "Koios was asked without a pool ID"

mkdir -p "${POOL_FOLDER}/${POOL_NAME}"
printf '%s\n' "${POOL_B32}" > "${POOL_FOLDER}/${POOL_NAME}/pool.id-bech32"
assert_eq "$(glv_pool_id_find)" "${POOL_B32}" "pool ID from the pool folder"
rm -f -- "${POOL_FOLDER}/${POOL_NAME}/pool.id-bech32"
POOL_ID="${POOL_HEX}"
assert_eq "$(glv_pool_id_find)" "${POOL_B32}" "hex POOL_ID through Koios"
KOIOS_MODE=down
status=0; glv_pool_id_find >/dev/null || status=$?
assert_eq "${status}" "2" "hex POOL_ID while Koios is down"
POOL_ID="${POOL_B32}"

# ── Koios down before there is any data ──────────────────────────────────────
glv_pool_job_run 668 21600 > "${TEST_ROOT}/job"
assert_eq "$(cat "${TEST_ROOT}/job")" "id|${POOL_B32}
fail|Koios did not answer" "pool job with Koios down"
glv_pool_load "${TEST_ROOT}/job"
assert_eq "${POOL_STATE}|${POOL_FAILED_AT}|${POOL_NOTE}" "failed|1000|Koios did not answer" "state after a failure"
glv_pool_vital text colour
assert_eq "${text}" "" "no Pool vital without data"

KOIOS_MODE=html
glv_pool_job_run 668 21600 > "${TEST_ROOT}/job"
assert_eq "$(tail -n 1 "${TEST_ROOT}/job")" "fail|Koios did not answer" "an HTML error page is not an answer"

KOIOS_MODE=empty
glv_pool_job_run 668 21600 > "${TEST_ROOT}/job"
glv_pool_load "${TEST_ROOT}/job"
assert_eq "${POOL_STATE}|${POOL_ID_B32}" "unknown|${POOL_B32}" "a pool Koios does not know"

# ── Koios answers ────────────────────────────────────────────────────────────
KOIOS_MODE=ok
glv_pool_job_run 668 21600 > "${TEST_ROOT}/job"
[[ "$(tail -n 1 "${TEST_ROOT}/job")" == ok\|*\|668 ]] || fail "pool job did not finish: $(cat "${TEST_ROOT}/job")"
glv_pool_load "${TEST_ROOT}/job"
assert_eq "${POOL_STATE}" "ok" "state with an answer"
assert_eq "${POOL_INFO[ticker]}|${POOL_INFO[status]}|${POOL_INFO[retiring]}|${POOL_INFO[delegators]}" \
  "PL1|registered||412" "pool fields"
assert_eq "${POOL_INFO[name]}" "Evil [31m/Pool" "control characters and the separator are blanked in the name"
assert_eq "${POOL_INFO[margin]}|${POOL_INFO[saturation]}|${POOL_INFO[pledge]}|${POOL_INFO[live_pledge]}" \
  "0.015|28.73|250000000000|263412000000" "pool numbers"
# 22.43 M of 21,495.9 M active stake, of 21,600 blocks: 22.54 blocks.
assert_eq "${POOL_SNAP[669]}" "22430000000000|2254" "next epoch's stake and ideal blocks"
assert_eq "${POOL_SNAP[667]%%|*}|${POOL_BLOCKS[668]}|${POOL_BLOCKS[667]}" "22390000000000|9|24" \
  "previous epoch's stake, and blocks of the current and previous epoch"
grep -q '^deleg|669|0$' "${TEST_ROOT}/job" || fail "the next epoch's count was not asked for"
assert_eq "${POOL_DELEG[668]}|${POOL_DELEG[667]}|${POOL_DELEG[669]:-unset}" "412|409|unset" \
  "delegators counted, and a count of 0 is taken as not counted yet"
glv_pool_vital text colour
assert_eq "${text}|${colour}" "PL1 · 28.7 %|ok" "Pool vital"

# A later failure keeps the data and marks it stale.
KOIOS_MODE=down
D_NOW=1700
glv_pool_job_run 668 21600 > "${TEST_ROOT}/job"
glv_pool_load "${TEST_ROOT}/job"
assert_eq "${POOL_STATE}|${POOL_INFO[ticker]}|${POOL_FAILED_AT}" "stale|PL1|1700" "data kept through a failure"
KOIOS_MODE=ok

POOL_INFO[live_pledge]=249000000000
glv_pool_vital text colour
assert_eq "${text}|${colour}" "pledge not met|danger" "live pledge below the pledge"
POOL_INFO[live_pledge]=263412000000
POOL_INFO[retiring]=672
glv_pool_vital text colour
assert_eq "${text}|${colour}" "retiring 672|warn" "a retiring pool"
POOL_INFO[retiring]=""
POOL_INFO[saturation]=103.2
glv_pool_vital text colour
assert_eq "${text}|${colour}" "PL1 · 103.2 %|warn" "an over-saturated pool"
POOL_INFO[saturation]=28.73

# ── epoch history ────────────────────────────────────────────────────────────
HIST_EPOCH=668
glv_history_job_run "${POOL_B32}" 668 0 21600 > "${TEST_ROOT}/history.0"
assert_eq "$(head -n 1 "${TEST_ROOT}/history.0")" "total|12" "count of settled epochs from Content-Range"
assert_eq "$(sed -n 2p "${TEST_ROOT}/history.0")" "row|0|666|22400000000000|2257|405|20|271000000|10184000000|241" \
  "first settled epoch"
glv_history_load "${TEST_ROOT}/history.0" 0
assert_eq "${HIST_TOTAL}|${HIST_KNOWN}|${HIST_LOADED[0]}" "12|10|1" "first chunk taken in"

D_LED=([669]=21 [668]=23 [666]=20)
D_STATUS=([adopted]=10 [confirmed]=1 [total]=23)
D_SCHEDULE_EPOCH=668
HIST_SCROLL=0
glv_history_rows 5
assert_eq "${HIST_ROWS_TOTAL}" "15" "rows: next, now, previous and twelve settled"
assert_eq "${HIST_VIEW[0]}" "next|669|22430000000000||21||2254|||" "next epoch row"
assert_eq "${HIST_VIEW[1]}" "now|668|22410000000000|412|23|11|2252|||" "current epoch row uses the block log when it is ahead"
assert_eq "${HIST_VIEW[2]}" "previous|667|22390000000000|409||24|2248|||" "previous epoch row"
assert_eq "${HIST_VIEW[3]}" "settled|666|22400000000000|405|20|20|2257|271000000|10184000000|241" "settled epoch row"
assert_eq "${HIST_VIEW[4]%%|*}" "settled" "fifth row"

# Scrolling past the loaded chunk shows rows waiting for Koios, then a failure.
# Row 11 is past the end for five rows, so the window stops at row 10:
# offsets 7 to 9 are loaded, 10 and 11 are not.
HIST_SCROLL=11
glv_history_rows 5
assert_eq "${HIST_SCROLL}|${HIST_VIEW[2]%%|*}|${HIST_VIEW[3]}|${HIST_VIEW[4]}" "10|settled|loading||loading|" \
  "rows not fetched yet"
HIST_FAILED[10]=1690
glv_history_rows 5
assert_eq "${HIST_VIEW[3]}" "failed|" "a chunk that failed less than a minute ago"
glv_history_job_run "${POOL_B32}" 668 10 21600 > "${TEST_ROOT}/history.10"
glv_history_load "${TEST_ROOT}/history.10" 10
glv_history_rows 5
assert_eq "${HIST_VIEW[4]%%|*}|${HIST_SCROLL}" "settled|10" "the last rows, scrolled to the end"
assert_eq "$(cut -d'|' -f2 <<< "${HIST_VIEW[4]}")" "655" "oldest epoch"
[[ -z "${HIST_FAILED[10]+set}" ]] || fail "a loaded chunk is still marked failed"

# A failed chunk is marked, and loads nothing.
KOIOS_MODE=down
glv_history_job_run "${POOL_B32}" 668 20 21600 > "${TEST_ROOT}/history.20"
assert_eq "$(cat "${TEST_ROOT}/history.20")" "fail" "history job with Koios down"
glv_history_load "${TEST_ROOT}/history.20" 20
assert_eq "${HIST_FAILED[20]}|${HIST_LOADED[20]:-}" "1700|" "failed chunk"
KOIOS_MODE=ok

# ── formats and settings ─────────────────────────────────────────────────────
glv_ada_short value 22412345678901; assert_eq "${value}" "22.41 M" "millions of ada"
glv_ada_short value 1234567890123456; assert_eq "${value}" "1.23 B" "billions of ada"
glv_ada_short value 250000000000; assert_eq "${value}" "250 k" "thousands of ada"
glv_ada_short value 2500000000; assert_eq "${value}" "2.5 k" "a few thousand ada"
glv_ada_short value 170000000; assert_eq "${value}" "170" "a few hundred ada"
glv_ada_short value ""; assert_eq "${value}" "—" "missing value"
glv_ada_int value 10184123456; assert_eq "${value}" "10,184 ₳" "whole ada"
glv_blocks_per_epoch value; assert_eq "${value}" "21600" "blocks per epoch"
ENABLE_KOIOS=N
if glv_koios_usable; then fail "Koios used although ENABLE_KOIOS=N"; fi
ENABLE_KOIOS=Y
KOIOS_API=""
if glv_koios_usable; then fail "Koios used on a network without Koios"; fi

grep -q '^#POOL_ID=""' "${GLIVEVIEW}" || fail "POOL_ID is not among the user variables"
grep -q '^#POOL_HISTORY_EPOCHS=5' "${GLIVEVIEW}" || fail "POOL_HISTORY_EPOCHS is not among the user variables"

printf 'gliveview-pool: ok\n'
