#!/usr/bin/env bash
#shellcheck disable=SC2086,SC2001,SC2154
#shellcheck source=/dev/null

# STARTUPLOG_DIR="/opt/cardano/cnode/guild-db/startuplog"
# STARTUPLOG_DB="${STARTUPLOG_DIR}/startuplog.db"
#logfile="/opt/cardano/cnode/logs/node0.json"

######################################
# Do NOT modify code below           #
######################################

PARENT="$(dirname $0)"
if [[ ! -f "${PARENT}"/env ]]; then
  echo "ERROR: could not find common env file, please run guild-deploy.sh or manually download"
  exit 1
fi
if ! . "${PARENT}"/env offline; then exit 1; fi

# get log file from config file specified in env
unset logfile
if [[ "${CONFIG##*.}" = "yaml" ]]; then
  [[ $(grep "scName.*\.json" "${CONFIG}") =~ scName:.\"(.+\.json)\" ]] && logfile="${BASH_REMATCH[1]}"
elif [[ "${CONFIG##*.}" = "json" ]]; then
  logfile=$(jq -r '.setupScribes[] | select (.scFormat == "ScJson") | .scName' "${CONFIG}")
fi
[[ -z "${logfile}" ]] && echo -e "${FG_RED}ERROR:${NC} failed to locate json logfile in node configuration file\na setupScribe of format ScJson with extension .json expected" && exit 1


[[ -z "${STARTUPLOG_DIR}" ]] && export STARTUPLOG_DIR="/opt/cardano/cnode/guild-db/startuplog"
[[ -z "${STARTUPLOG_DB}" ]] && export STARTUPLOG_DB="${STARTUPLOG_DIR}/startuplog.db"

createStartuplogDB() {
  if ! mkdir -p "${STARTUPLOG_DIR}" 2>/dev/null; then echo "ERROR: failed to create directory to store blocklog: ${STARTUPLOG_DIR}" && return 1; fi
  if [[ ! -f ${STARTUPLOG_DB} ]]; then # create a fresh DB with latest schema
    sqlite3 ${STARTUPLOG_DB} <<-EOF
			CREATE TABLE validationlog (id INTEGER PRIMARY KEY AUTOINCREMENT, event TEXT NOT NULL, at TEXT NOT NULL UNIQUE, env TEXT NOT NULL, final_chunk INTEGER, initial_chunk INTEGER);
			CREATE TABLE replaylog (id INTEGER PRIMARY KEY AUTOINCREMENT, event TEXT NOT NULL, at TEXT NOT NULL UNIQUE, env TEXT NOT NULL, slot INTEGER, tip INTEGER);
      CREATE TABLE statistics (id INTEGER PRIMARY KEY AUTOINCREMENT, event TEXT NOT NULL, start INTEGER, end INTEGER, env TEXT NOT NULL);
			EOF
    echo "SQLite startuplog DB created: ${STARTUPLOG_DB}"
  fi
}


if renice_cmd="$(command -v renice)"; then ${renice_cmd} -n 19 $$ >/dev/null; fi

[[ ! -f ${STARTUPLOG_DB} ]] && createStartuplogDB

echo "~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "~~ STARTUP LOG MONITOR STARTED ~~"
echo "monitoring ${logfile} for traces"

# Continuously parse cardano-node json log file for traces
while read -r logentry; do
  # Traces monitored:
  # - TraceOpenEvent.StartedOpeningDB
  # - TraceOpenEvent.OpenedDB
  # - TraceOpenEvent.StartedOpeningImmutableDB
  # - TraceOpenEvent.OpenedImmutableDB
  # - TraceOpenEvent.StartedOpeningLgrDB 
  # - TraceOpenEvent.OpenedLgrDB
  # - TraceImmutableDBEvent.StartedValidatingChunk
  # - TraceImmutableDBEvent.ValidatedLastLocation
  # - TraceLedgerReplayEvent

  case "${logentry}" in
    *TraceOpenEvent.StartedOpeningDB* )
      if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.at' not found" && continue; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
      if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.env' not found" && continue; fi
      if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.data.kind' not found" && continue; fi
      sqlite3 "${STARTUPLOG_DB}" "INSERT OR IGNORE INTO statistics (event,start,env) values ('OpenDB','${at}','${env}');"
      ;;
    *TraceOpenEvent.OpenedDB* )
      if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.at' not found" && continue; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
      if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.env' not found" && continue; fi
      if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.data.kind' not found" && continue; fi
      sqlite3 "${STARTUPLOG_DB}" "UPDATE statistics SET end = '${at}' WHERE id IN (SELECT id FROM (SELECT * FROM statistics WHERE event = 'OpenDB' AND env = '${env}' AND end is Null ORDER BY event DESC) ORDER BY id DESC LIMIT 1) ;"
      ;;
    *TraceOpenEvent.StartedOpeningImmutableDB* )
      if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.at' not found" && continue; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
      if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.env' not found" && continue; fi
      if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.data.kind' not found" && continue; fi
      sqlite3 "${STARTUPLOG_DB}" "INSERT OR IGNORE INTO statistics (event,start,env) values ('OpenImmutableDB','${at}','${env}');"
      ;;
    *TraceOpenEvent.OpenedImmutableDB* )
      if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.at' not found" && continue; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
      if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.env' not found" && continue; fi
      if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.data.kind' not found" && continue; fi
      sqlite3 "${STARTUPLOG_DB}" "UPDATE statistics SET end = '${at}' WHERE id IN (SELECT id FROM (SELECT * FROM statistics WHERE event = 'OpenImmutableDB' AND env = '${env}' AND end is Null ORDER BY event DESC) ORDER BY id DESC LIMIT 1) ;" 
      ;;
    *TraceOpenEvent.StartedOpeningLgrDB* )
      if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.at' not found" && continue; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
      if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.env' not found" && continue; fi
      if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.data.kind' not found" && continue; fi
      sqlite3 "${STARTUPLOG_DB}" "INSERT OR IGNORE INTO statistics (event,start,env) values ('OpenLedgerDB','${at}','${env}');"
      ;;
    *TraceOpenEvent.OpenedLgrDB* )
      if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.at' not found" && continue; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
      if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.env' not found" && continue; fi
      if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.data.kind' not found" && continue; fi
      sqlite3 "${STARTUPLOG_DB}" "UPDATE statistics SET end = '${at}' WHERE id IN (SELECT id FROM (SELECT * FROM statistics WHERE event = 'OpenLedgerDB' AND env = '${env}' AND end is Null ORDER BY event DESC) ORDER BY id DESC LIMIT 1) ;" 
      ;;
    *TraceImmutableDBEvent.StartedValidatingChunk* )
      if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.at' not found" && continue; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
      if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.env' not found" && continue; fi
      if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.data.kind' not found" && continue; fi
      if ! initialChunk="$(jq -er '.data.initialChunk' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.data.initialChunk' not found" && continue; fi
      if ! finalChunk="$(jq -er '.data.finalChunk' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.data.finalChunk' not found" && continue; fi
      sqlite3 "${STARTUPLOG_DB}" "INSERT OR IGNORE INTO validationlog (event,at,env,final_chunk,initial_chunk) values ('${event}','${at}','${env}',${finalChunk},${initialChunk});"
      ;;
    *TraceImmutableDBEvent.ValidatedLastLocation* )
      if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.at' not found" && continue; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
      if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.env' not found" && continue; fi
      if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.data.kind' not found" && continue; fi
      if ! initialChunk="$(jq -er '.data.initialChunk' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.data.initialChunk' not found" && continue; fi
      if ! finalChunk="$(jq -er '.data.finalChunk' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.data.finalChunk' not found" && continue; fi
      sqlite3 "${STARTUPLOG_DB}" "INSERT OR IGNORE INTO validationlog (event,at,env,final_chunk,initial_chunk) values ('${event}','${at}','${env}',${finalChunk},${initialChunk});"
      ;;
    *TraceLedgerReplayEvent.ReplayedBlock* )
      if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceLedgerReplayEvent]: invalid json schema, '.at' not found" && continue; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
      if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceLedgerReplayEvent]: invalid json schema, '.env' not found" && continue; fi
      if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceLedgerReplayEvent]: invalid json schema, '.data.kind' not found" && continue; fi
      if ! slot="$(jq -er '.data.slot' <<< ${logentry})"; then echo "ERROR[TraceLedgerReplayEvent]: invalid json schema, '.data.slot' not found" && continue; fi
      if ! tip="$(jq -er '. .data.tip' <<< ${logentry})"; then echo "ERROR[TraceLedgerReplayEvent]: invalid json schema, '.data.tip' not found" && continue; fi
      sqlite3 "${STARTUPLOG_DB}" "INSERT OR IGNORE INTO replaylog (event,at,env,slot,tip) values ('${event}','${at}','${env}',${slot},${tip});"
      ;;
    * ) : ;; # ignore
  esac
done < <(tail -F -n0 "${logfile}")

