#!/usr/bin/env bash
# After a KES rotation CNTools offers to load the new set. cardano-node reloads
# on SIGHUP, Dingo through dingo.sh reload, and Amaru reads the key only at
# startup and ends on SIGHUP, so CNTools restarts it with amaru.sh restart.
# Checks the hint without an active unit, the reload and restart flows, the
# leader-slot check before an Amaru restart and the metrics confirmation.
set -uo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  printf 'cntools kes reload hint tests skipped: Bash 5+ required\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
# Resolved, since CNTools refuses a temporary folder below a symlink (macOS /var).
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-kes-reload.XXXXXX")" && pwd -P)" || exit 1
trap 'rm -rf "${WORK}"' EXIT
failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
expect() { [[ "$1" == *"$2"* ]] || fail "$3: '$2' not in: $1"; }
refuse() { [[ "$1" != *"$2"* ]] || fail "$3: '$2' in: $1"; }

# shellcheck source=/dev/null
source "${CNTOOLS_SOURCE}/lib/pool-kes-ui.sh"

# The UI, the unit lookup, the leader schedule and metrics are stubbed.
cntools_ui_render_status() { printf 'STATUS %s %s\n' "$1" "$2"; }
cntools_kes_installed_summary() { printf 'SUMMARY %s\n' "$1"; }
cntools_ui_spin_function() { shift; "$@"; }
cntools_transaction_log() { :; }
cntools_transaction_temp_file() { printf -v "$1" '%s' "$(mktemp "${WORK}/tmp.XXXXXX")"; }
cntools_kes_systemd_pid_into() { [[ "${ACTIVE:-N}" == Y ]] || return 1; printf -v "$1" '%s' 4242; }
# Chooses CHOOSE, or the first offered option, and records the order.
cntools_kes_choose() {
  local -n _test_choice="$1"; shift 2
  printf 'CHOICES %s\n' "$(IFS='|'; printf '%s' "$*")"
  _test_choice="${CHOOSE:-$1}"
}
cntools_kes_next_leader_into() {
  [[ -n "${LEADER:-}" ]] || return 2
  [[ "${LEADER}" != none ]] || return 1
  printf -v "$1" '%s' "${LEADER}"
}
cntools_kes_reload_confirmed() { printf 'CONFIRM %s\n' "$*"; [[ "${CONFIRMED:-Y}" == Y ]]; }
# sudo would need a password: the restart runs in the open.
sudo() { return 1; }

NODE_HOME_TEST="${WORK}/node"
mkdir -p "${NODE_HOME_TEST}/scripts"
for script in amaru dingo; do
  cat > "${NODE_HOME_TEST}/scripts/${script}.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s %s SUDO=%s\n' "${0##*/}" "$1" "${SUDO:-}" >> "${SCRIPT_LOG}"
[[ "${SCRIPT_STATUS:-0}" == 0 ]] || printf 'ERROR: %s\n' "${SCRIPT_ERROR:-failed}" >&2
exit "${SCRIPT_STATUS:-0}"
EOF
  chmod +x "${NODE_HOME_TEST}/scripts/${script}.sh"
done
export SCRIPT_LOG="${WORK}/script.log"
CNTOOLS_KES_START=990 CNTOOLS_KES_NEXT=3

offer() {
  : > "${SCRIPT_LOG}"
  CNTOOLS_IMPLEMENTATION="$1" CNTOOLS_SERVICE="$2" CNTOOLS_NODE_HOME="${NODE_HOME_TEST}" cntools_kes_reload_offer
}
amaru=amaru.sh dingo=dingo.sh

# ── no active unit: the hint names each implementation's own action ──────────
out="$(offer amaru amaru.service)"
expect "${out}" "${NODE_HOME_TEST}/scripts/${amaru} restart" "amaru without a unit: restart command"
expect "${out}" "Do not send it SIGHUP, which ends Amaru without its orderly shutdown" "amaru without a unit: SIGHUP warning"
refuse "${out}" "cardano-node process" "amaru without a unit"
expect "${out}" "SUMMARY Still using the previous key · restart it" "amaru without a unit: summary"
[[ "$(grep -c '^SUMMARY' <<< "${out}")" == 1 ]] || fail "amaru without a unit: one summary: ${out}"

out="$(offer dingo dingo.service)"
expect "${out}" "${NODE_HOME_TEST}/scripts/${dingo} reload" "dingo without a unit: reload command"
refuse "${out}" "cardano-node process" "dingo without a unit"

out="$(offer cnode cnode.service)"
expect "${out}" "sending SIGHUP to the cardano-node process" "cnode without a unit: hint unchanged"

# ── Amaru: restart, after a look at the leader schedule ──────────────────────
out="$(ACTIVE=Y LEADER=7260 offer amaru amaru.service)"
expect "${out}" "The next leader slot of this node is in 2 hours 1 minute." "amaru: leader slot shown"
expect "${out}" "CHOICES Restart Amaru now|I will restart it myself" "amaru: restart offered first"
if (( EUID == 0 )); then
  refuse "${out}" "sudo may ask for your password" "amaru as root: no sudo prompt"
else
  expect "${out}" "sudo may ask for your password" "amaru: sudo prompt announced"
fi
expect "$(< "${SCRIPT_LOG}")" "${amaru} restart SUDO=Y" "amaru: amaru.sh restart run"
expect "${out}" "CONFIRM cardano_node_metrics_operationalCertificateStartKESPeriod_int 990 180" "amaru: start period confirmed"
expect "${out}" "SUMMARY Restarted · now using the new key (confirmed by node metrics)" "amaru: confirmed summary"

out="$(ACTIVE=Y LEADER=300 offer amaru amaru.service)"
expect "${out}" "STATUS warn The next leader slot of this node is in 5 minutes. Restart Amaru after that slot." "amaru: close leader slot warned"
expect "${out}" "CHOICES I will restart it myself|Restart Amaru now" "amaru: waiting offered first"
[[ ! -s "${SCRIPT_LOG}" ]] || fail "amaru: nothing restarted by default near a leader slot: $(< "${SCRIPT_LOG}")"
expect "${out}" "SUMMARY Still using the previous key · restart it" "amaru: not restarted"

out="$(ACTIVE=Y LEADER=none offer amaru amaru.service)"
expect "${out}" "The stored leader schedule has no upcoming slot" "amaru: empty schedule"
out="$(ACTIVE=Y offer amaru amaru.service)"
expect "${out}" "could not read the leader schedule of this node" "amaru: no schedule"

out="$(ACTIVE=Y LEADER=7260 SCRIPT_STATUS=1 SCRIPT_ERROR='amaru.service is not installed' offer amaru amaru.service)"
expect "${out}" "could not restart amaru.service (amaru.service is not installed). Run: ${NODE_HOME_TEST}/scripts/${amaru} restart" "amaru: failed restart"
refuse "${out}" "CONFIRM" "amaru: no confirmation after a failed restart"
expect "${out}" "SUMMARY Still using the previous key · restart it" "amaru: failed restart summary"

out="$(ACTIVE=Y LEADER=7260 CONFIRMED=N offer amaru amaru.service)"
expect "${out}" "did not show start period 990" "amaru: unconfirmed restart"
expect "${out}" "SUMMARY Restarted · not confirmed" "amaru: unconfirmed summary"

# ── Dingo: dingo.sh reload, never with sudo ──────────────────────────────────
out="$(ACTIVE=Y offer dingo dingo.service)"
expect "${out}" "CHOICES Reload Dingo now (dingo.sh reload)|I will reload or restart it myself" "dingo: reload offered"
expect "$(< "${SCRIPT_LOG}")" "${dingo} reload SUDO=N" "dingo: dingo.sh reload run without sudo"
expect "${out}" "CONFIRM dingo_forge_opcert_counter_loaded 3 15" "dingo: certificate counter confirmed"
expect "${out}" "SUMMARY Reloaded · now using the new key (confirmed by node metrics)" "dingo: confirmed summary"

out="$(ACTIVE=Y SCRIPT_STATUS=1 SCRIPT_ERROR='dingo.service runs as a relay; use restart to change its role' offer dingo dingo.service)"
expect "${out}" "dingo.sh reload failed (dingo.service runs as a relay; use restart to change its role)" "dingo: failed reload"
expect "${out}" "SUMMARY Still using the previous key · reload or restart it" "dingo: failed reload summary"

out="$(ACTIVE=Y CONFIRMED=N offer dingo dingo.service)"
expect "${out}" "did not show certificate counter 3" "dingo: unconfirmed reload"
expect "${out}" "SUMMARY Reload requested · not confirmed" "dingo: unconfirmed summary"

out="$(ACTIVE=Y CHOOSE='I will reload or restart it myself' offer dingo dingo.service)"
[[ ! -s "${SCRIPT_LOG}" ]] || fail "dingo: declined reload ran the script"

# ── durations ────────────────────────────────────────────────────────────────
text=""
for pair in '59:less than a minute' '60:1 minute' '600:10 minutes' '7260:2 hours 1 minute' \
            '86400:1 day' '90000:1 day 1 hour' '180000:2 days 2 hours'; do
  cntools_kes_duration_into text "${pair%%:*}"
  [[ "${text}" == "${pair#*:}" ]] || fail "duration ${pair%%:*}: expected '${pair#*:}', got '${text}'"
done

# ── the confirmation waits for the expected value, then gives up ─────────────
# shellcheck source=/dev/null
source "${CNTOOLS_SOURCE}/lib/pool-kes-ui.sh"
CLOCK="${WORK}/clock" SEEN="${WORK}/seen"
cntools_health_local_metrics_url() { printf 'http://127.0.0.1:1/metrics\n'; }
cntools_health_now() { local now; now="$(< "${CLOCK}")"; printf '%s\n' "$((now + 1))" > "${CLOCK}"; printf '%s\n' "${now}"; }
cntools_health_local_metric_into() {
  local values=() count
  mapfile -t values < "${SEEN}"; count="$(wc -l < "${CLOCK}.reads")"; printf 'x\n' >> "${CLOCK}.reads"
  [[ "${2}" == cardano_node_metrics_operationalCertificateStartKESPeriod_int ]] || return 1
  printf -v "$1" '%s' "${values[count]:-${values[-1]}}"
}
sleep() { :; }
printf '1000\n' > "${CLOCK}"; printf '989\n989\n990\n' > "${SEEN}"; : > "${CLOCK}.reads"
cntools_kes_reload_confirmed || fail "confirmation: the third reading matches"
printf '1000\n' > "${CLOCK}"; printf '989\n' > "${SEEN}"; : > "${CLOCK}.reads"
cntools_kes_reload_confirmed cardano_node_metrics_operationalCertificateStartKESPeriod_int 990 5 && fail "confirmation: a stale value never matches"
(( $(wc -l < "${CLOCK}.reads") <= 7 )) || fail "confirmation: gives up after its deadline"

# ── the closing note fits whichever node the other system runs ───────────────
# shellcheck source=/dev/null
source "${CNTOOLS_SOURCE}/lib/pool-kes-ui.sh"
cntools_pool_file_name_into() { printf -v "$1" '%s' "$2"; }
cntools_table_pair() { :; }
cntools_table_render() { cat >/dev/null; }
cntools_number_format() { printf '%s' "$1"; }
cntools_ui_wait() { :; }
cntools_ui_render_status() { printf 'STATUS %s %s\n' "$1" "$2"; }
CNTOOLS_POOL_NAMES=(LABPOOL) CNTOOLS_KES_INDEX=0 CNTOOLS_KES_STAGE=''
for implementation in amaru cnode; do
  note="$(CNTOOLS_IMPLEMENTATION="${implementation}" cntools_kes_installed_summary state warning)"
  expect "${note}" "copy the new hot.skey and op.cert there, then reload cardano-node or Dingo, or restart Amaru." "closing note on ${implementation}"
done

# ── the next leader slot comes from the block log ────────────────────────────
if command -v sqlite3 >/dev/null 2>&1 && sqlite3 :memory: "SELECT json_object('a',1);" >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CNTOOLS_SOURCE}/lib/filesystem.sh"
  # shellcheck source=/dev/null
  source "${CNTOOLS_SOURCE}/core/log.sh"
  # shellcheck source=/dev/null
  source "${CNTOOLS_SOURCE}/lib/blocklog.sh"
  # shellcheck source=/dev/null
  source "${CNTOOLS_SOURCE}/lib/pool-kes-ui.sh"
  cntools_log() { :; }
  CNTOOLS_TMP_DIR="${WORK}/tmp"; mkdir -m 0700 "${CNTOOLS_TMP_DIR}"
  CNTOOLS_BLOCKLOG_DB="${WORK}/blocklog.db"
  sqlite3 "${CNTOOLS_BLOCKLOG_DB}" "CREATE TABLE blocklog (id INTEGER PRIMARY KEY, slot INTEGER, at TEXT, epoch INTEGER,
      block INTEGER, slot_in_epoch INTEGER, hash TEXT, size INTEGER, status TEXT);
    INSERT INTO blocklog (slot, at, epoch, status) VALUES
      (1, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now', '-1 hour'), 1, 'leader'),
      (2, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now', '+2 hours'), 1, 'leader'),
      (3, strftime('%Y-%m-%dT%H:%M:%S+00:00', 'now', '+1 hour'), 1, 'adopted');"
  seconds=''
  if cntools_kes_next_leader_into seconds; then
    (( seconds > 7100 && seconds <= 7200 )) || fail "next leader slot: expected about 7200 seconds, got ${seconds}"
  else
    fail "next leader slot: not read from the block log"
  fi
  [[ -z "$(ls -A "${CNTOOLS_TMP_DIR}")" ]] || fail "next leader slot: block log work files left behind"
  sqlite3 "${CNTOOLS_BLOCKLOG_DB}" "DELETE FROM blocklog WHERE slot = 2;"
  cntools_kes_next_leader_into seconds; status=$?
  [[ "${status}" == 1 ]] || fail "next leader slot: no upcoming slot returns 1, got ${status}"
  CNTOOLS_BLOCKLOG_DB="${WORK}/missing.db"
  cntools_kes_next_leader_into seconds; status=$?
  [[ "${status}" == 2 ]] || fail "next leader slot: no block log returns 2, got ${status}"
else
  printf 'next leader slot check skipped: sqlite3 with JSON functions is not installed\n'
fi

if (( failures > 0 )); then
  printf '%s cntools kes reload check(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'cntools kes reload hint tests passed\n'
