#!/usr/bin/env bash
# Read-only CNCLI journal snapshots. No env helpers, node queries or migrations.
# shellcheck disable=SC2034
CNTOOLS_BLOCKLOG_WORK=''
CNTOOLS_BLOCKLOG_ERROR=''
CNTOOLS_BLOCKLOG_DATA='[]'
CNTOOLS_BLOCKLOG_HAS_EPOCHDATA=N

cntools_blocklog_error() {
  CNTOOLS_BLOCKLOG_ERROR="$1"
  cntools_log ERROR "${CNTOOLS_BLOCKLOG_ERROR}" || true
  return 1
}

cntools_blocklog_cleanup() {
  if [[ -n "${CNTOOLS_BLOCKLOG_WORK}" && -d "${CNTOOLS_BLOCKLOG_WORK}" &&
        ! -L "${CNTOOLS_BLOCKLOG_WORK}" &&
        "${CNTOOLS_BLOCKLOG_WORK}" == "${CNTOOLS_TMP_DIR}/.cntools-blocklog."* ]]; then
    rm -f -- "${CNTOOLS_BLOCKLOG_WORK}/result" "${CNTOOLS_BLOCKLOG_WORK}/error"
    rmdir -- "${CNTOOLS_BLOCKLOG_WORK}" || true
  fi
  CNTOOLS_BLOCKLOG_WORK=''
}

cntools_blocklog_prepare() {
  local schema=''
  CNTOOLS_BLOCKLOG_ERROR=''; CNTOOLS_BLOCKLOG_DATA='[]'
  command -v sqlite3 >/dev/null 2>&1 || { cntools_blocklog_error 'Install sqlite3 to read the CNCLI block log.'; return 1; }
  [[ "${CNTOOLS_BLOCKLOG_DB:-}" == /* && -f "${CNTOOLS_BLOCKLOG_DB}" &&
     ! -L "${CNTOOLS_BLOCKLOG_DB}" && -r "${CNTOOLS_BLOCKLOG_DB}" ]] || {
    cntools_blocklog_error "No readable CNCLI block log at ${CNTOOLS_BLOCKLOG_DB:-unset}. Configure BLOCKLOG_DIR or initialize CNCLI block monitoring first."
    return 1
  }
  if [[ -z "${CNTOOLS_BLOCKLOG_WORK}" ]]; then
    cntools_log_private_directory_safe "${CNTOOLS_TMP_DIR:-}" || { cntools_blocklog_error 'The CNTools temporary directory is unsafe.'; return 1; }
    CNTOOLS_BLOCKLOG_WORK="$(umask 077; mktemp -d "${CNTOOLS_TMP_DIR}/.cntools-blocklog.XXXXXX")" || return 1
  fi
  # Only real base tables are accepted. Optional epochdata can be absent in old
  # journals; ambiguous multi-pool statistics are deliberately not selected.
  cntools_blocklog_sql schema "SELECT json_object(
    'blocklog', EXISTS(SELECT 1 FROM main.sqlite_master WHERE name='blocklog' AND type='table')
      AND (SELECT count(*) FROM pragma_table_info('blocklog') WHERE name IN
        ('slot','at','epoch','block','slot_in_epoch','hash','size','status'))=8,
    'epochdata', EXISTS(SELECT 1 FROM main.sqlite_master WHERE name='epochdata' AND type='table')
      AND (SELECT count(*) FROM pragma_table_info('epochdata') WHERE name IN
        ('epoch','pool_id','epoch_slots_ideal','max_performance'))=4);" || return 1
  jq -e '.blocklog == 1' <<< "${schema}" >/dev/null || { cntools_blocklog_error 'The block log does not contain a supported CNCLI blocklog table.'; return 1; }
  CNTOOLS_BLOCKLOG_HAS_EPOCHDATA=N
  if jq -e '.epochdata == 1' <<< "${schema}" >/dev/null; then CNTOOLS_BLOCKLOG_HAS_EPOCHDATA=Y; fi
}

# SQL is internal, with bounded, normalized decimal inputs only. SQLite opens
# the original read-only (including current WAL contents), never immutable.
# One connection/transaction captures each screen snapshot; .sqliterc is bypassed.
cntools_blocklog_sql() {
  local -n _blocklog_output="$1"
  local sql="$2" status=0 mask='' detail=''
  # Limit the SQLite child only: a large existing CNTools log must not hit the
  # query-output file-size limit while the parent records the command/result.
  local -a arguments=("${BASH}" -c 'ulimit -f 32768 || exit 1; exec "$@"' cntools-blocklog
    sqlite3 -readonly -batch -bail -init /dev/null -cmd '.timeout 3000'
    "${CNTOOLS_BLOCKLOG_DB}" "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; BEGIN; ${sql} COMMIT;")
  _blocklog_output=''
  printf -v mask '%*s' "${#arguments[@]}" ''; mask="${mask// /0}"
  # ulimit uses 1024-byte blocks in Bash: cap disk output at 32 MiB. Timeouts
  # and errors are recorded without leaking terminal control bytes to the UI.
  (umask 077
    cntools_run_command_timeout 15 "${mask}" -- "${arguments[@]}" \
      > "${CNTOOLS_BLOCKLOG_WORK}/result" 2> "${CNTOOLS_BLOCKLOG_WORK}/error") || status=$?
  if (( status != 0 )); then
    IFS= read -r -n 4096 detail < "${CNTOOLS_BLOCKLOG_WORK}/error" || true
    cntools_log ERROR "Block log query status=${status}: ${detail}" || true
    cntools_blocklog_error 'Could not read the CNCLI block log. Check permissions, database locks and the CNTools log.'
    return 1
  fi
  _blocklog_output="$(< "${CNTOOLS_BLOCKLOG_WORK}/result")"
  jq -e . <<< "${_blocklog_output}" >/dev/null || { cntools_blocklog_error 'The block log returned invalid JSON; sqlite3 with JSON functions is required.'; return 1; }
}

cntools_blocklog_integer_into() {
  local -n _blocklog_integer="$1"
  local _blocklog_normalized=''
  _blocklog_integer=''
  cntools_number_normalize_into _blocklog_normalized "$2" || return 1
  [[ "${_blocklog_normalized}" =~ ^(0|[1-9][0-9]{0,8})$ ]] || return 1
  _blocklog_integer="${_blocklog_normalized}"
}

cntools_blocklog_summary() {
  local count='' sql='' epoch_source='' stats=''
  cntools_blocklog_integer_into count "$1" && (( count >= 1 && count <= 100 )) || return 2
  cntools_blocklog_prepare || return 1
  epoch_source='SELECT epoch FROM main.blocklog'
  stats="NULL AS ideal, NULL AS luck"
  if [[ "${CNTOOLS_BLOCKLOG_HAS_EPOCHDATA}" == Y ]]; then
    epoch_source+=' UNION SELECT epoch FROM main.epochdata'
    stats="(SELECT CASE WHEN count(*)=1 THEN max(epoch_slots_ideal) END FROM main.epochdata e WHERE e.epoch=epochs.epoch) AS ideal,
      (SELECT CASE WHEN count(*)=1 THEN max(max_performance) END FROM main.epochdata e WHERE e.epoch=epochs.epoch) AS luck"
  fi
  sql="WITH epochs AS (SELECT DISTINCT epoch FROM (${epoch_source}) WHERE typeof(epoch)='integer' AND epoch BETWEEN 0 AND 999999999 ORDER BY epoch DESC LIMIT ${count}),
    totals AS (SELECT epochs.epoch, ${stats}, count(b.slot) AS scheduled,
      coalesce(sum(b.status IN ('adopted','confirmed')),0) AS adopted,
      coalesce(sum(b.status='confirmed'),0) AS confirmed,
      coalesce(sum(b.status='leader'),0) AS pending,
      coalesce(sum(b.status='missed'),0) AS missed,
      coalesce(sum(b.status='ghosted'),0) AS ghosted,
      coalesce(sum(b.status='stolen'),0) AS stolen,
      coalesce(sum(b.status='invalid'),0) AS invalid,
      coalesce(sum(b.status IS NOT NULL AND b.status NOT IN ('leader','adopted','confirmed','missed','ghosted','stolen','invalid')),0) AS unknown
      FROM epochs LEFT JOIN main.blocklog b ON b.epoch=epochs.epoch GROUP BY epochs.epoch ORDER BY epochs.epoch DESC)
    SELECT coalesce(json_group_array(json_object('epoch',epoch,'ideal',ideal,'luck',luck,
      'scheduled',scheduled,'adopted',adopted,'confirmed',confirmed,'pending',pending,
      'missed',missed,'ghosted',ghosted,'stolen',stolen,'invalid',invalid,'unknown',unknown)),json('[]')) FROM totals;"
  cntools_blocklog_sql CNTOOLS_BLOCKLOG_DATA "${sql}" || return 1
  jq -e 'type=="array" and all(.[];
    all(.epoch,.scheduled,.adopted,.confirmed,.pending,.missed,.ghosted,.stolen,.invalid,.unknown;
      type=="number" and .>=0 and .<=9007199254740991 and .==floor) and
    all(.ideal,.luck; .==null or (type=="number" and .>=0 and .<=9007199254740991)))' \
    <<< "${CNTOOLS_BLOCKLOG_DATA}" >/dev/null || { cntools_blocklog_error 'The block log contains malformed epoch statistics.'; return 1; }
}

cntools_blocklog_epoch() {
  local epoch=''
  cntools_blocklog_integer_into epoch "$1" || return 2
  cntools_blocklog_prepare || return 1
  # Read one more than the bound so truncation is rejected, not hidden.
  cntools_blocklog_sql CNTOOLS_BLOCKLOG_DATA "SELECT coalesce(json_group_array(json_object(
    'slot',slot,'epoch',epoch,'block',block,'slot_in_epoch',slot_in_epoch,'hash',substr(coalesce(hash,''),1,8192),
    'size',size,'status',substr(status,1,128),'at',at,'timestamp',cast(strftime('%s',at) AS INTEGER))),json('[]'))
    FROM (SELECT * FROM main.blocklog WHERE epoch=${epoch} ORDER BY slot ASC LIMIT 100001);" || return 1
  jq -e 'length <= 100000 and all(.[]; (.status|type)=="string" and
    all(.slot,.block,.slot_in_epoch,.size; type=="number" and .>=0 and .<=9007199254740991 and .==floor))' \
    <<< "${CNTOOLS_BLOCKLOG_DATA}" >/dev/null || { cntools_blocklog_error 'This epoch exceeds the safe display limit or contains malformed block records.'; return 1; }
}
