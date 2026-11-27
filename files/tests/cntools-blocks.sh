#!/usr/bin/env bash
# CNTools Blocks → Epoch must not report "no blocks" for an epoch whose leader
# schedule is not calculated. Checks the schedule state read from the block log
# (recorded, empty, pending, missing, unknown) and what the epoch view says for
# each: the Scheduled slots row and the note under an epoch without slots.
set -uo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  printf 'cntools blocks tests skipped: Bash 5+ required\n'
  exit 0
fi
if ! command -v sqlite3 >/dev/null 2>&1 || ! sqlite3 :memory: "SELECT json_object('a',1);" >/dev/null 2>&1; then
  printf 'cntools blocks tests skipped: sqlite3 with JSON functions is not installed\n'
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CNTOOLS_SOURCE="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
# Resolved, since CNTools refuses a temporary folder below a symlink (macOS /var).
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/guild-cntools-blocks.XXXXXX")" && pwd -P)" || exit 1
trap 'rm -rf "${WORK}"' EXIT
failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }
expect() { [[ "$1" == *"$2"* ]] || fail "$3: '$2' not in: $1"; }
refuse() { [[ "$1" != *"$2"* ]] || fail "$3: '$2' in: $1"; }

for file in lib/filesystem.sh core/log.sh lib/number.sh lib/blocklog.sh lib/blocklog-ui.sh; do
  # shellcheck source=/dev/null
  source "${CNTOOLS_SOURCE}/${file}"
done
# The UI is stubbed: rows and notes are printed as plain lines.
cntools_log() { :; }
cntools_table_pair() { printf 'ROW %s | %s | %s\n' "$1" "$2" "${3:-}"; }
cntools_ui_render_status() { printf 'STATUS %s %s\n' "$1" "$2"; }
CNTOOLS_TMP_DIR="${WORK}/tmp"; mkdir -m 0700 "${CNTOOLS_TMP_DIR}"

# The tables as env.library creates them, with epochs 10 (two slots), 11
# (calculated, no slots), 13 (one slot) and no schedule for 12.
CNTOOLS_BLOCKLOG_DB="${WORK}/blocklog.db"
sqlite3 "${CNTOOLS_BLOCKLOG_DB}" "
  CREATE TABLE blocklog (id INTEGER PRIMARY KEY AUTOINCREMENT, slot INTEGER NOT NULL UNIQUE, at TEXT NOT NULL UNIQUE,
    epoch INTEGER NOT NULL, block INTEGER NOT NULL DEFAULT 0, slot_in_epoch INTEGER NOT NULL DEFAULT 0,
    hash TEXT NOT NULL DEFAULT '', size INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL);
  CREATE TABLE epochdata (id INTEGER PRIMARY KEY AUTOINCREMENT, epoch INTEGER NOT NULL, epoch_nonce TEXT NOT NULL,
    pool_id TEXT NOT NULL, sigma TEXT NOT NULL, d REAL NOT NULL, epoch_slots_ideal INTEGER NOT NULL,
    max_performance REAL NOT NULL, active_stake TEXT NOT NULL, total_active_stake TEXT NOT NULL, UNIQUE(epoch,pool_id));
  INSERT INTO blocklog (slot,at,epoch,slot_in_epoch,status) VALUES
    (1000,'2026-11-01T00:00:00+00:00',10,100,'confirmed'),
    (1200,'2026-11-01T01:00:00+00:00',10,300,'missed'),
    (3100,'2026-11-03T00:00:00+00:00',13,100,'leader');
  INSERT INTO epochdata (epoch,epoch_nonce,pool_id,sigma,d,epoch_slots_ideal,max_performance,active_stake,total_active_stake) VALUES
    (10,'n','pool','0.001',0,2.1,95.2,'1','1000'),
    (11,'n','pool','0.001',0,0.4,0,'1','1000'),
    (13,'n','pool','0.001',0,1.2,83.3,'1','1000');"

# epoch, expected schedule, expected latest calculated epoch
check_schedule() {
  CNTOOLS_BLOCKLOG_EPOCH_SCHEDULE=''; CNTOOLS_BLOCKLOG_LATEST_EPOCH='x'
  cntools_blocklog_epoch "$1" || fail "epoch $1: the block log could not be read: ${CNTOOLS_BLOCKLOG_ERROR}"
  assert_eq "${CNTOOLS_BLOCKLOG_EPOCH_SCHEDULE}" "$2" "epoch $1 schedule"
  assert_eq "${CNTOOLS_BLOCKLOG_LATEST_EPOCH}" "$3" "epoch $1 latest calculated epoch"
}

# ── schedule state from the block log ────────────────────────────────────────
check_schedule 10 recorded ''
check_schedule 11 empty 13
check_schedule 12 missing 13
check_schedule 14 pending 13
check_schedule 34356 pending 13
check_schedule 0 missing 13
cntools_blocklog_cleanup
[[ -z "$(ls -A "${CNTOOLS_TMP_DIR}")" ]] || fail "block log work files left behind"

# A schedule the leaderlog service stored with no slots, then nothing at all.
sqlite3 "${CNTOOLS_BLOCKLOG_DB}" "INSERT INTO epochdata (epoch,epoch_nonce,pool_id,sigma,d,epoch_slots_ideal,max_performance,active_stake,total_active_stake)
  VALUES (14,'n','pool','0.001',0,0.3,0,'1','1000');"
check_schedule 14 empty 14
check_schedule 15 pending 14
sqlite3 "${CNTOOLS_BLOCKLOG_DB}" "DELETE FROM blocklog; DELETE FROM epochdata;"
check_schedule 11 pending ''

# A block log without epochdata cannot tell; the epoch view keeps its old note.
sqlite3 "${CNTOOLS_BLOCKLOG_DB}" "DROP TABLE epochdata;
  INSERT INTO blocklog (slot,at,epoch,slot_in_epoch,status) VALUES (1000,'2026-11-01T00:00:00+00:00',10,100,'confirmed');"
check_schedule 10 recorded ''
check_schedule 11 unknown ''

# ── what the epoch view says ─────────────────────────────────────────────────
row="$(cntools_blocks_schedule_rows 2 recorded '')"
assert_eq "${row}" "ROW Scheduled slots | 2 | number" "recorded epoch row"
row="$(cntools_blocks_schedule_rows 0 empty 13)"
assert_eq "${row}" "ROW Scheduled slots | 0 | number" "epoch without slots row"
row="$(cntools_blocks_schedule_rows 0 pending 1234)"
assert_eq "${row}" "ROW Scheduled slots | Not calculated · latest calculated is epoch 1,234 | warning" "uncalculated epoch row"
row="$(cntools_blocks_schedule_rows 0 pending '')"
assert_eq "${row}" "ROW Scheduled slots | Not calculated | warning" "uncalculated epoch row without any schedule"
row="$(cntools_blocks_schedule_rows 0 missing 13)"
assert_eq "${row}" "ROW Scheduled slots | Not recorded · latest calculated is epoch 13 | warning" "unrecorded epoch row"
row="$(cntools_blocks_schedule_rows 0 unknown '')"
assert_eq "${row}" "ROW Scheduled slots | 0 | number" "old block log row"

note="$(cntools_blocks_schedule_note 11 empty 13)"
expect "${note}" "STATUS info The leader schedule of epoch 11 is calculated: no slots were assigned to this pool." "epoch without slots note"
note="$(cntools_blocks_schedule_note 34356 pending 13)"
expect "${note}" "STATUS warn The leader schedule of epoch 34,356 is not calculated. The latest calculated epoch is 13" "uncalculated epoch note"
refuse "${note}" "No scheduled blocks" "uncalculated epoch note"
note="$(cntools_blocks_schedule_note 11 pending '')"
expect "${note}" "STATUS warn No leader schedule is calculated yet." "note without any schedule"
note="$(cntools_blocks_schedule_note 12 missing 13)"
expect "${note}" "STATUS warn No leader schedule was recorded for epoch 12, while the block log has schedules up to epoch 13." "unrecorded epoch note"
note="$(cntools_blocks_schedule_note 11 unknown '')"
assert_eq "${note}" "STATUS info No scheduled blocks recorded for this epoch." "old block log note"

if (( failures > 0 )); then
  printf '%s cntools blocks check(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'cntools blocks tests passed\n'
