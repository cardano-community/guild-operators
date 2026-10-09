#!/usr/bin/env bash
# Real SQLite journal safety/aggregation plus deterministic Gum wizard checks.
# shellcheck disable=SC1090,SC1091,SC2034,SC2317,SC2329
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
. "${REPO_ROOT}/files/tests/fixtures/cntools-shared-libraries.sh"
CNTOOLS_ROOT="${REPO_ROOT}/scripts/common-helper-scripts/cntools"
TEST_ROOT="$(mktemp -d)"; TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
CNTOOLS_TMP_DIR="${TEST_ROOT}"
cleanup() { cntools_blocklog_cleanup; rm -r -- "${TEST_ROOT}"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$1 != $2"; }
. "${CNTOOLS_ROOT}/core/log.sh"
. "${CNTOOLS_ROOT}/core/health.sh"
. "${CNTOOLS_ROOT}/lib/number.sh"
. "${CNTOOLS_ROOT}/lib/blocklog.sh"
. "${CNTOOLS_ROOT}/lib/blocklog-ui.sh"
cntools_log() { printf '%s %s\n' "$1" "$2" >> "${TEST_ROOT}/trace"; }
cntools_http_json() { fail 'Unexpected network call'; }
cardano-cli() { fail 'Unexpected node/CLI call'; }
CNTOOLS_BLOCKLOG_DB="${TEST_ROOT}/blocklog.db"
schema="CREATE TABLE blocklog(slot INTEGER UNIQUE,at TEXT,epoch INTEGER,block INTEGER,slot_in_epoch INTEGER,hash TEXT,size INTEGER,status TEXT);
CREATE TABLE epochdata(epoch INTEGER,pool_id TEXT,epoch_slots_ideal INTEGER,max_performance REAL);"
sqlite3 "${CNTOOLS_BLOCKLOG_DB}" "${schema}
INSERT INTO epochdata VALUES(100,'one',10,70.0),(101,'one',0,0),(99,'one',3,100),(99,'two',9,20);
INSERT INTO blocklog VALUES
 (1000,'2026-10-08T10:00:00Z',100,1,0,'0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',100,'confirmed'),
 (1001,'2026-10-08T10:00:01Z',100,2,1,'',200,'adopted'),
 (1002,'2026-10-08T10:00:02Z',100,0,2,'',0,'leader'),
 (1003,'2026-10-08T10:00:03Z',100,0,3,'',0,'missed'),
 (1004,'2026-10-08T10:00:04Z',100,0,4,'',0,'ghosted'),
 (1005,'2026-10-08T10:00:05Z',100,0,5,'',0,'stolen'),
 (1006,'2026-10-08T10:00:06Z',100,0,6,'base64 diagnostic',0,'invalid'),
 (1007,'2026-10-08T10:00:07Z',100,0,7,'',0,'future-status');"
before="$(shasum -a 256 "${CNTOOLS_BLOCKLOG_DB}")"
for CNTOOLS_MODE in local light offline; do
  cntools_blocklog_summary 10
  jq -e 'length==3 and .[0].epoch==101 and .[0].scheduled==0 and .[2].ideal==null and .[2].luck==null and
    .[1] == {epoch:100,ideal:10,luck:70,scheduled:8,adopted:2,confirmed:1,pending:1,missed:1,ghosted:1,stolen:1,invalid:1,unknown:1}' \
    <<< "${CNTOOLS_BLOCKLOG_DATA}" >/dev/null || fail 'incorrect or duplicated summary'
  cntools_blocklog_epoch 100
  jq -e 'length==8 and .[0].slot==1000 and .[0].timestamp==1791453600 and .[7].status=="future-status"' \
    <<< "${CNTOOLS_BLOCKLOG_DATA}" >/dev/null || fail 'incorrect epoch snapshot'
done
eq "$(shasum -a 256 "${CNTOOLS_BLOCKLOG_DB}")" "${before}"
cntools_blocklog_epoch 102; eq "${CNTOOLS_BLOCKLOG_DATA}" '[]'
cntools_blocklog_summary 1; eq "$(jq length <<< "${CNTOOLS_BLOCKLOG_DATA}")" 1
for invalid in '1;DROP TABLE blocklog' -1 '1.2' '1,00' 1000000000 ''; do
  if cntools_blocklog_epoch "${invalid}"; then fail 'unsafe epoch accepted'; fi
done
for invalid in 0 101 '10;DELETE FROM blocklog'; do
  if cntools_blocklog_summary "${invalid}"; then fail 'unsafe count accepted'; fi
done
normalized=''; cntools_blocklog_integer_into normalized '1,234'; eq "${normalized}" 1234
cntools_blocklog_integer_into normalized 000; eq "${normalized}" 0
saved="${CNTOOLS_BLOCKLOG_DB}"
CNTOOLS_BLOCKLOG_DB="${TEST_ROOT}/missing.db"
if cntools_blocklog_prepare; then fail 'missing journal accepted'; fi
[[ ! -e "${CNTOOLS_BLOCKLOG_DB}" ]] || fail 'read created a database'
sqlite3 "${TEST_ROOT}/old.db" "CREATE TABLE blocklog(slot INTEGER,at TEXT,epoch INTEGER,block INTEGER,slot_in_epoch INTEGER,hash TEXT,size INTEGER,status TEXT);"
CNTOOLS_BLOCKLOG_DB="${TEST_ROOT}/old.db"; cntools_blocklog_summary 10
eq "${CNTOOLS_BLOCKLOG_DATA}" '[]'; eq "${CNTOOLS_BLOCKLOG_HAS_EPOCHDATA}" N
sqlite3 "${CNTOOLS_BLOCKLOG_DB}" "INSERT INTO blocklog VALUES(1,'2026-10-08T10:00:00Z',1,0,0,'',0,'leader'),(2,'2026-10-08T10:00:01Z',1,0,1,'',0,'leader');"
cntools_blocklog_summary 10; eq "$(jq length <<< "${CNTOOLS_BLOCKLOG_DATA}")" 1
eq "$(jq '.[0].scheduled' <<< "${CNTOOLS_BLOCKLOG_DATA}")" 2
sqlite3 "${TEST_ROOT}/view.db" 'CREATE VIEW blocklog AS SELECT 1 AS slot,1 AS at,1 AS epoch,1 AS block,1 AS slot_in_epoch,1 AS hash,1 AS size,1 AS status;'
CNTOOLS_BLOCKLOG_DB="${TEST_ROOT}/view.db"
if cntools_blocklog_prepare; then fail 'view journal accepted'; fi
CNTOOLS_BLOCKLOG_DB="${TEST_ROOT}/trace"
if cntools_blocklog_prepare; then fail 'corrupt journal accepted'; fi
ln -s "${saved}" "${TEST_ROOT}/linked.db"; CNTOOLS_BLOCKLOG_DB="${TEST_ROOT}/linked.db"
if cntools_blocklog_prepare; then fail 'symlink journal accepted'; fi
CNTOOLS_BLOCKLOG_DB="${saved}"

(
  CNTOOLS_BLOCKLOG_DB="${TEST_ROOT}/old.db"
  sqlite3 "${CNTOOLS_BLOCKLOG_DB}" "UPDATE blocklog SET size=-1 WHERE slot=1;"
  if cntools_blocklog_epoch 1; then fail 'malformed numeric record accepted'; fi
)
(
  CNTOOLS_BLOCKLOG_DB="${TEST_ROOT}/limit.db"
  sqlite3 "${CNTOOLS_BLOCKLOG_DB}" "${schema}
    WITH RECURSIVE slots(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM slots WHERE n<100001)
    INSERT INTO blocklog SELECT n,'2026-10-08T10:00:00Z',1,0,n,'',0,'leader' FROM slots;"
  if cntools_blocklog_epoch 1; then fail 'epoch silently truncated'; fi
  [[ "${CNTOOLS_BLOCKLOG_ERROR}" == *'safe display limit'* ]] || fail 'missing limit explanation'
)
CNTOOLS_BLOCKLOG_DB="${saved}"

# Keep a writing connection open: read-only queries must see the committed WAL,
# not an immutable or database-file-only snapshot. Reads must not change it.
coproc WAL_WRITER { sqlite3 "${CNTOOLS_BLOCKLOG_DB}"; }
writer_pid="${WAL_WRITER_PID}"
printf '%s\n' 'PRAGMA journal_mode=WAL;' "INSERT INTO epochdata VALUES(102,'one',1,100);" '.print ready' >& "${WAL_WRITER[1]}"
IFS= read -r reply <& "${WAL_WRITER[0]}"; eq "${reply}" wal
IFS= read -r reply <& "${WAL_WRITER[0]}"; eq "${reply}" ready
wal_before="$(shasum -a 256 "${saved}" "${saved}-wal")"
cntools_blocklog_summary 1; eq "$(jq '.[0].epoch' <<< "${CNTOOLS_BLOCKLOG_DATA}")" 102
eq "$(shasum -a 256 "${saved}" "${saved}-wal")" "${wal_before}"
printf '.quit\n' >& "${WAL_WRITER[1]}"; wait "${writer_pid}"

# Locked reads fail within the configured busy timeout; errors are logged.
sqlite3 "${CNTOOLS_BLOCKLOG_DB}" 'PRAGMA journal_mode=DELETE;' >/dev/null
coproc LOCK_WRITER { sqlite3 "${CNTOOLS_BLOCKLOG_DB}"; }
writer_pid="${LOCK_WRITER_PID}"
printf '%s\n' 'BEGIN EXCLUSIVE;' '.print locked' >& "${LOCK_WRITER[1]}"
IFS= read -r reply <& "${LOCK_WRITER[0]}"; eq "${reply}" locked
if cntools_blocklog_summary 1; then fail 'exclusive lock unexpectedly read'; fi
[[ "${CNTOOLS_BLOCKLOG_ERROR}" == *'Could not read'* ]] || fail 'missing error explanation'
printf '%s\n' 'ROLLBACK;' '.quit' >& "${LOCK_WRITER[1]}"; wait "${writer_pid}"
grep -F 'sqlite3 -readonly -batch -bail -init /dev/null' "${TEST_ROOT}/trace" >/dev/null || fail 'query not logged'
grep -F 'database is locked' "${TEST_ROOT}/trace" >/dev/null || fail 'SQLite diagnostic not logged'
mode=''; cntools_filesystem_mode_into mode "${CNTOOLS_BLOCKLOG_WORK}/result"
eq "${mode}" 600

# Presentation is replaced only at the Gum boundary, retaining real data reads.
cntools_ui_action_begin() { printf 'VIEW %s\n' "$1"; }
cntools_ui_render_status() { printf '%s %s\n' "$1" "$2"; }
cntools_ui_wait() { :; }
cntools_ui_spin_function() { shift; "$@"; }
cntools_table_pair() { printf '%s: %s [%s]\n' "$1" "$2" "${3:-value}"; }
cntools_table_render() { printf 'TABLE %s\n' "$1"; while IFS= read -r row; do printf '%s\n' "${row}"; done; }
CNTOOLS_TIMEZONE=Europe/Stockholm
cntools_blocks_record_rows "$(jq -cn '{status:"confirmed",timestamp:1791453600,slot:1000,slot_in_epoch:0,block:1,size:100,hash:("a"*64)}')" Y > "${TEST_ROOT}/render"
grep -F '2026-10-08 12:00:00 CEST (+0200)' "${TEST_ROOT}/render" >/dev/null || fail 'timezone not used'
grep -F 'Slot: 1,000' "${TEST_ROOT}/render" >/dev/null || fail 'number not formatted'
grep -F 'Confirmed [success]' "${TEST_ROOT}/render" >/dev/null || fail 'status not themed'
rendered='' role=''
cntools_blocks_status_into rendered role strange; eq "${rendered}" 'Unknown · strange'; eq "${role}" warning

for cancel in 1 130; do
  (
    cntools_ui_input() { return "${cancel}"; }
    cntools_blocks_action Summary >/dev/null
    eq "${CNTOOLS_BLOCKS_CANCELLED}" Y
  )
done
(
  calls=0
  cntools_ui_input() { calls=$((calls+1)); if (( calls==1 )); then printf -v "$1" '%s' invalid; else printf -v "$1" '%s' ''; fi; }
  value=''; CNTOOLS_BLOCKS_CANCELLED=N
  cntools_blocks_prompt_integer value 'Recent epochs' 10 1 100 >/dev/null
  eq "${value}" 10; eq "${calls}" 2
)
(
  menus=0
  cntools_ui_choose() {
    menus=$((menus+1))
    case "${menus}" in
      1) [[ " $* " == *' Next page '* && " $* " != *' Previous page '* ]] || fail 'first-page choices'; printf -v "$1" '%s' 'Next page' ;;
      2) [[ " $* " != *' Next page '* && " $* " == *' Previous page '* ]] || fail 'last-page choices'; printf -v "$1" '%s' 'Show block details' ;;
      3) printf -v "$1" '%s' Refresh ;;
      *) printf -v "$1" '%s' Back ;;
    esac
  }
  cntools_ui_input() { printf -v "$1" '%s' ''; }
  CNTOOLS_BLOCKS_CANCELLED=N
  cntools_blocks_epoch_view 100 > "${TEST_ROOT}/epoch-view"
  eq "${menus}" 4
  grep -F 'Slot: 1,005' "${TEST_ROOT}/epoch-view" >/dev/null || fail 'details default did not use current page'
)
(
  # Summary stays stable after visiting an epoch; the child uses the same
  # shared reader state but must not replace the parent's displayed snapshot.
  menus=0
  cntools_ui_input() { printf -v "$1" '%s' ''; }
  cntools_ui_choose() {
    menus=$((menus+1))
    case "${menus}" in
      1) printf -v "$1" '%s' 'View epoch' ;;
      2) printf -v "$1" '%s' Back ;;
      *) printf -v "$1" '%s' Back ;;
    esac
  }
  cntools_blocks_action Summary > "${TEST_ROOT}/summary-view"
  eq "${menus}" 3
  eq "$(grep -c 'TABLE Epoch 100' "${TEST_ROOT}/summary-view")" 2
)
(
  cntools_ui_input() { eq "$3" 102; printf -v "$1" '%s' ''; }
  cntools_ui_choose() { printf -v "$1" '%s' Back; }
  cntools_blocks_action Epoch > "${TEST_ROOT}/empty-view"
  grep -F 'No scheduled blocks recorded' "${TEST_ROOT}/empty-view" >/dev/null || fail 'empty schedule failed'
)
(
  command() { if [[ "$*" == '-v sqlite3' ]]; then return 1; fi; builtin command "$@"; }
  if cntools_blocklog_prepare; then fail 'missing SQLite accepted'; fi
  [[ "${CNTOOLS_BLOCKLOG_ERROR}" == 'Install sqlite3'* ]] || fail 'missing dependency explanation'
)
work="${CNTOOLS_BLOCKLOG_WORK}"
cntools_blocklog_cleanup
[[ ! -d "${work}" ]] || fail 'staging survived cleanup'
printf 'CNTools block history tests passed\n'
