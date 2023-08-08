#!/usr/bin/env bash
#shellcheck disable=SC2086,SC2001,SC2154
#shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

#STARTUPLOG_DIR="/opt/cardano/cnode/guild-db/startuplog"
#STARTUPLOG_DB="${STARTUPLOG_DIR}/startuplog.db"
#BATCH_AUTO_UPDATE="Y"

######################################
# Do NOT modify code below           #
######################################


#####################
# Functions         #
#####################

usage() {
  cat <<-EOF >&2
		
		Usage: $(basename "$0") [operation <sub arg>]
		Script to run startupLogMonitor, best launched through systemd deployed by 'deploy-as-systemd.sh'

		-d    Deploy startupLogMonitor as a systemd service
		-u    Skip script update check overriding UPDATE_CHECK value in env (must be first argument to script)
		EOF
  exit 1
}

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

deploy_systemd() {
  echo "Deploying ${CNODE_VNAME}-startup-logmonitor as systemd service.."
  ${sudo} bash -c "cat <<-'EOF' > /etc/systemd/system/${CNODE_VNAME}-startup-logmonitor.service
	[Unit]
	Description=Cardano Node - Startup Log Monitor
	Wants=network-online.target
	After=network-online.target
	
	[Service]
	Type=simple
	Restart=on-failure
	RestartSec=20
	User=${USER}
	WorkingDirectory=${CNODE_HOME}/scripts
	ExecStart=/bin/bash -l -c \"exec ${CNODE_HOME}/scripts/startupLogMonitor.sh -u\"
	ExecStop=/bin/bash -l -c \"exec kill -2 \$(ps -ef | grep -m1 ${CNODE_HOME}/scripts/startupLogMonitor.sh | tr -s ' ' | cut -d ' ' -f2) &>/dev/null\"
	KillSignal=SIGINT
	SuccessExitStatus=143
	StandardOutput=syslog
	StandardError=syslog
	SyslogIdentifier=${CNODE_VNAME}-startup-logmonitor
	TimeoutStopSec=5
	KillMode=mixed
	
	[Install]
	WantedBy=multi-user.target
	EOF" && echo "${CNODE_VNAME}-startup-logmonitor.service deployed successfully!!" && ${sudo} systemctl daemon-reload && ${sudo} systemctl enable ${CNODE_VNAME}-startup-logmonitor.service
}

###################
# Execution       #
###################

while getopts du opt; do
  case ${opt} in
    d ) DEPLOY_SYSTEMD="Y" ;;
    u ) SKIP_UPDATE=Y ;;
    \? ) usage ;;
  esac
done
shift $((OPTIND -1))

[[ -z "${SKIP_UPDATE}" ]] && SKIP_UPDATE=N

PARENT="$(dirname $0)"

[[ ! -f "$(dirname $0)"/env ]] && echo -e "\nCommon env file missing, please ensure latest guild-deploy.sh was run and this script is being run from ${CNODE_HOME}/scripts folder! \n" && exit 1
. "$(dirname $0)"/env offline
case $? in
  1) echo -e "ERROR: Failed to load common env file\nPlease verify set values in 'User Variables' section in env file or log an issue on GitHub" && exit 1;;
  2) clear ;;
esac

[[ -z "${BATCH_AUTO_UPDATE}" ]] && BATCH_AUTO_UPDATE=N
[[ -z "${STARTUPLOG_DIR}" ]] && export STARTUPLOG_DIR="${CNODE_HOME}/guild-db/startuplog"
[[ -z "${STARTUPLOG_DB}" ]] && export STARTUPLOG_DB="${STARTUPLOG_DIR}/startuplog.db"
[[ -z ${SUDO} ]] && SUDO='Y'
[[ "${SUDO}" = 'Y' ]] && sudo="sudo" || sudo=""

#######################################################
# Version Check                                       #
#######################################################
clear

if [[ ${UPDATE_CHECK} = Y && ${SKIP_UPDATE} != Y ]]; then

  echo "Checking for script updates..."

  # Check availability of checkUpdate function
  if [[ ! $(command -v checkUpdate) ]]; then
    echo -e "\nCould not find checkUpdate function in env, make sure you're using official guild docs for installation!"
    exit 1
  fi

  # check for env update
  ENV_UPDATED=${BATCH_AUTO_UPDATE}
  checkUpdate "${PARENT}"/env N N N
  case $? in
    1) ENV_UPDATED=Y ;;
    2) exit 1 ;;
  esac

  # check for startupLogMonitor.sh update
    checkUpdate "${PARENT}"/startupLogMonitor.sh ${ENV_UPDATED}
  case $? in
    1) $0 "-u" "$@"; exit 0 ;; # re-launch script with same args skipping update check
    2) exit 1 ;;
  esac

  # source common env variables in case it was updated
  . "${PARENT}"/env offline &>/dev/null
  case $? in
    0) : ;; # ok
    2) echo "continuing with startup log monitoring..." ;;
    *) exit 1 ;;
  esac

fi

# get log file from config file specified in env
unset logfile
if [[ "${CONFIG##*.}" = "yaml" ]]; then
  [[ $(grep "scName.*\.json" "${CONFIG}") =~ scName:.\"(.+\.json)\" ]] && logfile="${BASH_REMATCH[1]}"
elif [[ "${CONFIG##*.}" = "json" ]]; then
  logfile=$(jq -r '.setupScribes[] | select (.scFormat == "ScJson") | .scName' "${CONFIG}")
fi
[[ -z "${logfile}" ]] && echo -e "${FG_RED}ERROR:${NC} failed to locate json logfile in node configuration file\na setupScribe of format ScJson with extension .json expected" && exit 1


if renice_cmd="$(command -v renice)"; then ${renice_cmd} -n 19 $$ >/dev/null; fi

#Deploy systemd if -d argument was specified
if [[ "${DEPLOY_SYSTEMD}" == "Y" ]]; then
  deploy_systemd && exit 0
  exit 2
fi

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
