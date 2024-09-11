#!/usr/bin/env bash
#shellcheck disable=SC2086,SC2001,SC2154
#shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################


######################################
# Do NOT modify code below           #
######################################

# If the log entry matches one of the monitored traces and is enabled, process it
processLogInfo() {
  case "$1" in 
    TraceNodeIsLeader )
      if [[ "$BLOCKLOG_ENABLED" = true ]]; then
        if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceNodeIsLeader]: invalid json schema, '.at' not found" && :; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
        if ! slot="$(jq -er '.data.val.slot' <<< ${logentry})"; then echo "ERROR[TraceNodeIsLeader]: invalid json schema, '.data.val.slot' not found" && :; fi
        getNodeMetrics
        [[ ${epochnum} -le 0 ]] && echo "ERROR[TraceNodeIsLeader]: failed to grab current epoch number from node metrics" && :
        echo "LEADER: epoch[${epochnum}] slot[${slot}] at[${at}]"
        sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO blocklog (slot,at,epoch,status) values (${slot},'${at}',${epochnum},'leader');"
      fi
      ;;
    TraceAdoptedBLock )
      if [[ "$BLOCKLOG_ENABLED" = true ]]; then
        if ! slot="$(jq -er '.data.val.slot' <<< ${logentry})"; then echo "ERROR[TraceAdoptedBlock]: invalid json schema, '.data.val.slot' not found" && :; fi
        if ! hash="$(jq -er '.data.val.blockHash' <<< ${logentry})"; then echo "ERROR[TraceAdoptedBlock]: invalid json schema, '.data.val.blockHash' not found" && :; fi
        if ! size="$(jq -er '.data.val.blockSize' <<< ${logentry})"; then echo "ERROR[TraceAdoptedBlock]: invalid json schema, '.data.val.blockSize' not found" && :; fi
        echo "ADOPTED: slot[${slot}] size=${size} hash=${hash}"
        sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'adopted', size = ${size}, hash = '${hash}' WHERE slot = ${slot};"
      fi
      ;;
    TraceForgedInvalidBlock )
      if [[ "$BLOCKLOG_ENABLED" = true ]]; then
        if ! slot="$(jq -er '.data.val.slot' <<< ${logentry})"; then echo "ERROR[TraceForgedInvalidBlock]: invalid json schema, '.data.val.slot' not found" && :; fi
        json_trace="$(jq -c -r '. | @jiggy1739' <<< ${logentry})"
        echo "INVALID: slot[${slot}] - base 64 encoded json trace, run this command to decode:"
        echo "echo ${json_trace} | jiggy1739 -d | jq -r"
        sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'invalid', hash = '${json_trace}' WHERE slot = ${slot};"
      fi
      ;;
    TraceOpenEvent.StartedOpeningDB )
      if [[ "$CHUNKVALIDATAIONLOG_ENABLED" = true ]]; then
        if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.at' not found" && :; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
        if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.env' not found" && :; fi
        if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.data.kind' not found" && :; fi
        sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO statistics (event,start,env) values ('OpenDB','${at}','${env}');"
      fi
      ;;
    TraceOpenEvent.OpenedDB )
      if [[ "$CHUNKVALIDATAIONLOG_ENABLED" = true ]]; then
        if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.at' not found" && :; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
        if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.env' not found" && :; fi
        if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.data.kind' not found" && :; fi
        sqlite3 "${BLOCKLOG_DB}" "UPDATE statistics SET end = '${at}' WHERE id IN (SELECT id FROM (SELECT * FROM statistics WHERE event = 'OpenDB' AND env = '${env}' AND end is Null ORDER BY event DESC) ORDER BY id DESC LIMIT 1) ;"
      fi
      ;;
    TraceOpenEvent.StartedOpeningImmutableDB )
      if [[ "$CHUNKVALIDATAIONLOG_ENABLED" = true ]]; then
        if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.at' not found" && :; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
        if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.env' not found" && :; fi
        if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.data.kind' not found" && :; fi
        sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO statistics (event,start,env) values ('OpenImmutableDB','${at}','${env}');"
      fi
      ;;
    TraceOpenEvent.OpenedImmutableDB )
      if [[ "$CHUNKVALIDATAIONLOG_ENABLED" = true ]]; then
        if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.at' not found" && :; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
        if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.env' not found" && :; fi
        if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.data.kind' not found" && :; fi
        sqlite3 "${BLOCKLOG_DB}" "UPDATE statistics SET end = '${at}' WHERE id IN (SELECT id FROM (SELECT * FROM statistics WHERE event = 'OpenImmutableDB' AND env = '${env}' AND end is Null ORDER BY event DESC) ORDER BY id DESC LIMIT 1) ;" 
      fi
      ;;
    TraceOpenEvent.StartedOpeningLgrDB )
      if [[ "$LEDGERREPLAYLOG_ENABLED" = true ]]; then
        if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.at' not found" && :; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
        if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.env' not found" && :; fi
        if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.data.kind' not found" && :; fi
        sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO statistics (event,start,env) values ('OpenLedgerDB','${at}','${env}');"
      fi
      ;;
    TraceOpenEvent.OpenedLgrDB )
      if [[ "$LEDGERREPLAYLOG_ENABLED" = true ]]; then
        if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.at' not found" && :; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
        if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.env' not found" && :; fi
        if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceOpenEvent]: invalid json schema, '.data.kind' not found" && :; fi
        sqlite3 "${BLOCKLOG_DB}" "UPDATE statistics SET end = '${at}' WHERE id IN (SELECT id FROM (SELECT * FROM statistics WHERE event = 'OpenLedgerDB' AND env = '${env}' AND end is Null ORDER BY event DESC) ORDER BY id DESC LIMIT 1) ;" 
      fi
      ;;
    TraceImmutableDBEvent.StartedValidatingChunk )
      if [[ "$LEDGERREPLAYLOG_ENABLED" = true ]]; then
        if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.at' not found" && :; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
        if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.env' not found" && :; fi
        if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.data.kind' not found" && :; fi
        if ! initialChunk="$(jq -er '.data.initialChunk' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.data.initialChunk' not found" && :; fi
        if ! finalChunk="$(jq -er '.data.finalChunk' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.data.finalChunk' not found" && :; fi
        sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO validationlog (event,at,env,final_chunk,initial_chunk) values ('${event}','${at}','${env}',${finalChunk},${initialChunk});"
      fi
      ;;
    TraceImmutableDBEvent.ValidatedLastLocation )
      if [[ "$LEDGERREPLAYLOG_ENABLED" = true ]]; then
        if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.at' not found" && :; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
        if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.env' not found" && :; fi
        if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.data.kind' not found" && :; fi
        if ! initialChunk="$(jq -er '.data.initialChunk' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.data.initialChunk' not found" && :; fi
        if ! finalChunk="$(jq -er '.data.finalChunk' <<< ${logentry})"; then echo "ERROR[TraceImmutableDBEvent]: invalid json schema, '.data.finalChunk' not found" && :; fi
        sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO validationlog (event,at,env,final_chunk,initial_chunk) values ('${event}','${at}','${env}',${finalChunk},${initialChunk});"
      fi
      ;;
    TraceLedgerReplayEvent.ReplayedBlock )
      if [[ "$LEDGERREPLAYLOG_ENABLED" = true ]]; then
        if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceLedgerReplayEvent]: invalid json schema, '.at' not found" && :; else at="$(sed 's/\.[0-9]\{2\}Z/+00:00/' <<< ${at})"; fi
        if ! env="$(jq -er '.env' <<< ${logentry})"; then echo "ERROR[TraceLedgerReplayEvent]: invalid json schema, '.env' not found" && :; fi
        if ! event="$(jq -er '.data.kind' <<< ${logentry})"; then echo "ERROR[TraceLedgerReplayEvent]: invalid json schema, '.data.kind' not found" && :; fi
        if ! slot="$(jq -er '.data.slot' <<< ${logentry})"; then echo "ERROR[TraceLedgerReplayEvent]: invalid json schema, '.data.slot' not found" && :; fi
        if ! tip="$(jq -er '. .data.tip' <<< ${logentry})"; then echo "ERROR[TraceLedgerReplayEvent]: invalid json schema, '.data.tip' not found" && :; fi
        sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO replaylog (event,at,env,slot,tip) values ('${event}','${at}','${env}',${slot},${tip});"
      fi
      ;;
    * ) : ;; # ignore
  esac
}


if renice_cmd="$(command -v renice)"; then ${renice_cmd} -n 19 $$ >/dev/null; fi

PARENT="$(dirname $0)"
if [[ ! -f "${PARENT}"/env ]]; then
  echo "ERROR: could not find common env file, please run guild-deploy.sh or manually download"
  exit 1
fi

. "${PARENT}"/env offline
return_code=$?
if [[ $return_code -eq 0 || $return_code -eq 2 ]]; then
  :
else
  echo "ERROR: Received exit code: ${return_code} from ${PARENT}/env."
  exit 1
fi

if [[ -z "$BLOCKLOG_ENABLED" ]]; then BLOCKLOG_ENABLED=true; fi
if [[ -z "$CHUNKVALIDATAIONLOG_ENABLED" ]]; then CHUNKVALIDATAIONLOG_ENABLED=true; fi
if [[ -z "$LEDGERREPLAYLOG_ENABLED" ]]; then LEDGERREPLAYLOG_ENABLED=true; fi

# get log file from config file specified in env
unset logfile
if [[ "${CONFIG##*.}" = "yaml" ]]; then
  [[ $(grep "scName.*\.json" "${CONFIG}") =~ scName:.\"(.+\.json)\" ]] && logfile="${BASH_REMATCH[1]}"
elif [[ "${CONFIG##*.}" = "json" ]]; then
  logfile=$(jq -r '.setupScribes[] | select (.scFormat == "ScJson") | .scName' "${CONFIG}")
fi
[[ -z "${logfile}" ]] && echo -e "${FG_RED}ERROR:${NC} failed to locate json logfile in node configuration file\na setupScribe of format ScJson with extension .json expected" && exit 1

[[ ! -f ${BLOCKLOG_DB} ]] && echo "${FG_RED}ERROR:${NC} blocklog db missing, please run 'cncli.sh init' to create and initialize it" && exit 1

echo "~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "~~ LOG MONITOR STARTED ~~"
echo "monitoring ${logfile} for traces"

# Continuously parse cardano-node json log file for traces and call processLogInfo()
while read -r logentry; do
  # Traces monitored: TraceNodeIsLeader, TraceAdoptedBlock, TraceForgedInvalidBlock
  case "${logentry}" in
    *TraceNodeIsLeader* )
      processLogInfo "TraceNodeIsLeader"
      ;;
    *TraceAdoptedBlock* )
      processLogInfo "TraceAdoptedBlock"
      ;;
    *TraceForgedInvalidBlock* )
      processLogInfo "TraceForgedInvalidBlock"
      ;;
    *TraceOpenEvent.StartedOpeningDB* )
      processLogInfo "TraceOpenEvent.StartedOpeningDB"
      ;;
    *TraceOpenEvent.OpenedDB* )
      processLogInfo "TraceOpenEvent.OpenedDB"
      ;;
    *TraceOpenEvent.StartedOpeningImmutableDB* )
      processLogInfo "TraceOpenEvent.StartedOpeningImmutableDB"
      ;;
    *TraceOpenEvent.OpenedImmutableDB* )
      processLogInfo "TraceOpenEvent.OpenedImmutableDB"
      ;;
    *TraceOpenEvent.StartedOpeningLgrDB* )
      processLogInfo "TraceOpenEvent.StartedOpeningLgrDB"
      ;;
    *TraceOpenEvent.OpenedLgrDB* )
      processLogInfo "TraceOpenEvent.OpenedLgrDB"
      ;;
    *TraceImmutableDBEvent.StartedValidatingChunk* )
      processLogInfo "TraceImmutableDBEvent.StartedValidatingChunk"
      ;;
    *TraceImmutableDBEvent.ValidatedLastLocation* )
      processLogInfo "TraceImmutableDBEvent.ValidatedLastLocation"
      ;;
    *TraceLedgerReplayEvent.ReplayedBlock* )
      processLogInfo "TraceLedgerReplayEvent.ReplayedBlock"
      ;;
    * ) : ;; # ignore
  esac
done < <(tail -F -n0 "${logfile}")
