#!/usr/bin/env bash
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'amaru leaderlog tests skipped: Bash 4+ required\n'
  exit 0
fi
for required_command in b2sum bc jq sqlite3 xxd; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    printf 'amaru leaderlog tests skipped: %s is not installed\n' "${required_command}"
    exit 0
  fi
done

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${message}: expected '${expected}', got '${actual}'"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-amaru-leaderlog.XXXXXX")"
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
service_pid=""
stop_service() {
  [[ -n "${service_pid}" ]] || return 0
  kill "${service_pid}" 2>/dev/null || true
  wait "${service_pid}" 2>/dev/null || true
  service_pid=""
}
trap 'stop_service; rm -rf "${TEST_ROOT}"' EXIT

SERVICE="amaru-test"
NODE_ROOT="${TEST_ROOT}/${SERVICE}"
SCRIPT_ROOT="${NODE_ROOT}/scripts"
UNIT_ROOT="${TEST_ROOT}/units"
STATE_ROOT="${TEST_ROOT}/state"
FAKE_BIN="${TEST_ROOT}/bin"
POOL_DIR="${NODE_ROOT}/priv/pool/TESTPOOL"
LEADERLOG="${SCRIPT_ROOT}/amaru-leaderlog.sh"
LEADERLOG_UNIT="${SERVICE}-leaderlog.service"
VALIDATE_UNIT="${SERVICE}-validate.service"
BLOCKLOG_DB_FILE="${NODE_ROOT}/guild-db/blocklog/blocklog.db"
SERVICE_LOG="${TEST_ROOT}/service.log"
mkdir -p \
  "${SCRIPT_ROOT}/lib" \
  "${SCRIPT_ROOT}/adapters" \
  "${NODE_ROOT}/bin" \
  "${NODE_ROOT}/state" \
  "${UNIT_ROOT}" \
  "${STATE_ROOT}" \
  "${FAKE_BIN}" \
  "${TEST_ROOT}/home"

cp "${REPO_ROOT}/scripts/amaru-helper-scripts/amaru-leaderlog.sh" "${LEADERLOG}"
cp "${REPO_ROOT}/scripts/common-helper-scripts/env" "${SCRIPT_ROOT}/env"
cp "${REPO_ROOT}"/scripts/common-helper-scripts/lib/*.library "${SCRIPT_ROOT}/lib/"
cp "${REPO_ROOT}/scripts/amaru-helper-scripts/amaru.adapter" \
  "${SCRIPT_ROOT}/adapters/amaru.adapter"
chmod 0755 "${LEADERLOG}"

cat > "${NODE_ROOT}/.deployment.json" <<JSON
{
  "schemaVersion": 1,
  "deploymentStatus": "deployed",
  "implementation": "amaru",
  "network": "preview",
  "branch": "master",
  "repository": "cardano-community/guild-operators",
  "serviceName": "${SERVICE}",
  "nodeVersion": "",
  "targetNodeVersion": "test",
  "metricsProvider": "otel",
  "capabilities": {
    "n2c": false,
    "localCli": false,
    "metrics": true,
    "forging": true
  }
}
JSON

# The state root shows that the script resolves the databases the same way
# the launcher does.
write_amaru_env() {
  cat > "${SCRIPT_ROOT}/amaru.env" <<EOF
GUILD_NODE_IMPLEMENTATION="amaru"
GUILD_NODE_HOME="${NODE_ROOT}"
GUILD_NODE_SERVICE="${SERVICE}"
AMARU_BIN="${NODE_ROOT}/bin/amaru"
AMARU_NETWORK="preview"
AMARU_STATE_ROOT="${NODE_ROOT}/state"
AMARU_PEERS_LISTEN_ON="0.0.0.0:3000"
EOF
}
write_amaru_env

# A node that follows the wall clock on preview, where a slot is one second
# and epoch 0 starts with the Shelley era. Files in the state directory move
# it away from the tip.
PREVIEW_START=1666656000
PREVIEW_EPOCH_LENGTH=86400
cat > "${FAKE_BIN}/curl" <<SCRIPT
#!/usr/bin/env bash
state="${STATE_ROOT}"
[[ ! -f "\${state}/metrics-down" ]] || exit 7
slot=\$(( \$(date +%s) - ${PREVIEW_START} ))
epoch=\$(( slot / ${PREVIEW_EPOCH_LENGTH} ))
slot_in_epoch=\$(( slot % ${PREVIEW_EPOCH_LENGTH} ))
[[ ! -f "\${state}/slot-lag" ]] || slot=\$(( slot - \$(< "\${state}/slot-lag") ))
[[ ! -f "\${state}/epoch-lag" ]] || epoch=\$(( epoch - \$(< "\${state}/epoch-lag") ))
[[ ! -f "\${state}/slot-in-epoch" ]] || slot_in_epoch=\$(< "\${state}/slot-in-epoch")
printf 'cardano_node_metrics_blockNum_int 12345\n'
printf 'cardano_node_metrics_epoch_int %s\n' "\${epoch}"
printf 'cardano_node_metrics_slotInEpoch_int %s\n' "\${slot_in_epoch}"
printf 'cardano_node_metrics_slotNum_int %s\n' "\${slot}"
SCRIPT

cat > "${NODE_ROOT}/bin/amaru" <<SCRIPT
#!/usr/bin/env bash
state="${STATE_ROOT}"
if [[ "\${1:-}" == "--version" ]]; then
  printf 'amaru test\n'
  exit 0
fi
if [[ "\$*" == "pool schedule inspect --help" ]]; then
  [[ ! -f "\${state}/no-schedule-command" ]] || exit 2
  exit 0
fi
printf '%s\n' "\$*" >> "\${state}/amaru-calls"
epoch=""
while (( \$# )); do
  [[ "\$1" != "--epoch" ]] || epoch="\${2:-}"
  shift
done
printf 'INFO stake_distribution.snapshot epoch=%s\n' "\${epoch}" >&2
if [[ ! -f "\${state}/schedule-\${epoch}.json" ]]; then
  printf 'ERROR no ledger snapshot for epoch %s\n' "\${epoch}" >&2
  exit 1
fi
cat "\${state}/schedule-\${epoch}.json"
SCRIPT

cat > "${TEST_ROOT}/systemctl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG}"
exit 0
SCRIPT
chmod 0755 "${FAKE_BIN}/curl" "${NODE_ROOT}/bin/amaru" "${TEST_ROOT}/systemctl"

export SUDO=N
export UPDATE_CHECK=N
export HOME="${TEST_ROOT}/home"
export PATH="${FAKE_BIN}:${PATH}"
export SYSTEMCTL_BIN="${TEST_ROOT}/systemctl"
export SYSTEMCTL_LOG="${TEST_ROOT}/systemctl.log"
export SYSTEMD_UNIT_DIR="${UNIT_ROOT}"
unset POOL_ID POOL_VRF_SKEY POOL_NAME POOL_FOLDER SLEEP_RATE
unset BLOCKLOG_DIR BLOCKLOG_DB BLOCKLOG_TZ
: > "${SYSTEMCTL_LOG}"

# The fake node follows the real clock, so stay clear of an epoch boundary.
while (( ( $(date +%s) - PREVIEW_START ) % PREVIEW_EPOCH_LENGTH > PREVIEW_EPOCH_LENGTH - 120 )); do
  sleep 5
done
EPOCH=$(( ( $(date +%s) - PREVIEW_START ) / PREVIEW_EPOCH_LENGTH ))
NEXT_EPOCH=$(( EPOCH + 1 ))
# 4k/f slots before the end of the epoch, plus the margin of 600 slots.
NEXT_EPOCH_GATE=$(( PREVIEW_EPOCH_LENGTH - 4 * 432 * 20 + 600 ))

# $1 = epoch, remaining arguments = slots in the epoch (any order). The report
# carries SCHEDULE_NONCE when it is set, as Amaru 10.11.20261119 and later do.
write_schedule() {
  local epoch="$1" slot_in_epoch slot entries=""
  shift
  for slot_in_epoch in "$@"; do
    slot=$(( epoch * PREVIEW_EPOCH_LENGTH + slot_in_epoch ))
    entries+="${entries:+,}{\"relative_slot\":${slot_in_epoch},\"slot\":${slot},\"time\":\"$(date -u -d "@$(( PREVIEW_START + slot ))" '+%FT%TZ')\"}"
  done
  printf '{"active_stake":1000000000000000,"epoch":%s,%s"pool_stake":50000000000000,"schedule":[%s],"share":"5.00%%"}\n' \
    "${epoch}" "${SCHEDULE_NONCE:+\"nonce\":\"${SCHEDULE_NONCE}\",}" "${entries}" > "${STATE_ROOT}/schedule-${epoch}.json"
}

run_leaderlog() {
  set +e
  output="$("${BASH}" "${LEADERLOG}" "$@" 2>&1)"
  status=$?
  set -e
}

start_service() {
  : > "${SERVICE_LOG}"
  SLEEP_RATE=1 "${BASH}" "${LEADERLOG}" leaderlog > "${SERVICE_LOG}" 2>&1 &
  service_pid=$!
}

wait_for_log() {
  local attempt
  for (( attempt = 0; attempt < 150; attempt++ )); do
    ! grep -Fq -- "$1" "${SERVICE_LOG}" || return 0
    kill -0 "${service_pid}" 2>/dev/null ||
      fail "leaderlog service stopped before logging '$1': $(< "${SERVICE_LOG}")"
    sleep 0.2
  done
  fail "leaderlog service did not log '$1': $(< "${SERVICE_LOG}")"
}

db() {
  sqlite3 "${BLOCKLOG_DB_FILE}" "$1"
}

calls_for_epoch() {
  [[ -f "${STATE_ROOT}/amaru-calls" ]] || { printf '0\n'; return 0; }
  grep -c -- "--epoch $1 " "${STATE_ROOT}/amaru-calls" || true
}

# The blocklog database is shared with the cnode tooling: both scripts create
# it through the common env library and keep no schema of their own.
for script in scripts/amaru-helper-scripts/amaru-leaderlog.sh scripts/cnode-helper-scripts/cncli.sh; do
  grep -Fq 'blocklogCreateDB' "${REPO_ROOT}/${script}" || fail "${script} does not use the shared blocklog schema"
  ! grep -Eq '^[[:space:]]*CREATE (TABLE|UNIQUE INDEX|INDEX)' "${REPO_ROOT}/${script}" ||
    fail "${script} has a blocklog schema of its own"
done

for arguments in "" "leaderlog now" "validate now" "validate all 1" "systemd" "systemd install all" "-d all" "sync"; do
  # shellcheck disable=SC2086
  run_leaderlog ${arguments}
  assert_eq "${status}" "1" "exit status for arguments '${arguments}'"
  [[ "${output}" == *"Usage: amaru-leaderlog.sh"* ]] ||
    fail "no usage for arguments '${arguments}': ${output}"
done

# A relay has no VRF key: nothing is installed and nothing is calculated.
run_leaderlog -d
assert_eq "${status}" "1" "unit install without a pool"
[[ "${output}" == *"VRF signing key is missing or not readable: ${NODE_ROOT}/priv/pool/CHANGE_ME/vrf.skey"* ]] ||
  fail "unit install without a pool does not name the VRF key: ${output}"
[[ ! -e "${UNIT_ROOT}/${LEADERLOG_UNIT}" ]] || fail "unit installed without a pool"
run_leaderlog leaderlog force
assert_eq "${status}" "1" "leaderlog without a pool"
[[ ! -e "${BLOCKLOG_DB_FILE}" && ! -e "${STATE_ROOT}/amaru-calls" ]] ||
  fail "leaderlog ran without a pool"

# The pool: a VRF key and an operational certificate, as the Amaru launcher
# requires them. The certificate ends with the cold verification key
# (a1 repeated 32 times here), which gives the pool id.
COLD_VKEY="$(printf 'a1%.0s' {1..32})"
POOL_ID_FROM_OPCERT="f28fb5faea3891894af50b657a1c421cc03ede34b1d07649dc40c024"
mkdir -p "${POOL_DIR}"
printf '{"type":"VrfSigningKey_PraosVRF","description":"","cborHex":"5840%s"}\n' \
  "$(printf '00%.0s' {1..64})" > "${POOL_DIR}/vrf.skey"
printf '{"type":"NodeOperationalCertificate","description":"","cborHex":"82845820%s021903e85840%s5820%s"}\n' \
  "$(printf 'B2%.0s' {1..32})" "$(printf 'c3%.0s' {1..64})" "${COLD_VKEY^^}" > "${POOL_DIR}/op.cert"
sed -i 's|^#POOL_NAME=.*|POOL_NAME="TESTPOOL"|' "${SCRIPT_ROOT}/env"
grep -Fxq 'POOL_NAME="TESTPOOL"' "${SCRIPT_ROOT}/env" ||
  fail "test setup could not set POOL_NAME in the common env"

run_leaderlog -d
assert_eq "${status}" "0" "unit install: ${output}"
unit_file="${UNIT_ROOT}/${LEADERLOG_UNIT}"
[[ -f "${unit_file}" ]] || fail "leaderlog unit was not installed"
for expected in \
  "BindsTo=${SERVICE}.service" \
  "After=${SERVICE}.service" \
  "User=$(id -un)" \
  "Group=$(id -gn)" \
  "WorkingDirectory=${SCRIPT_ROOT}" \
  "ExecStart=${LEADERLOG} leaderlog" \
  "Restart=on-failure" \
  "KillMode=control-group" \
  "NoNewPrivileges=true" \
  "ReadWritePaths=${NODE_ROOT}" \
  "WantedBy=${SERVICE}.service"; do
  grep -Fxq -- "${expected}" "${unit_file}" ||
    fail "leaderlog unit lacks '${expected}': $(< "${unit_file}")"
done
validate_unit_file="${UNIT_ROOT}/${VALIDATE_UNIT}"
[[ -f "${validate_unit_file}" ]] || fail "validate unit was not installed"
for expected in \
  "BindsTo=${SERVICE}.service" \
  "User=$(id -un)" \
  "SupplementaryGroups=systemd-journal" \
  "ExecStart=${LEADERLOG} validate" \
  "SyslogIdentifier=${SERVICE}-validate" \
  "ReadWritePaths=${NODE_ROOT}" \
  "WantedBy=${SERVICE}.service"; do
  grep -Fxq -- "${expected}" "${validate_unit_file}" ||
    fail "validate unit lacks '${expected}': $(< "${validate_unit_file}")"
done
! grep -Fq "SupplementaryGroups" "${unit_file}" ||
  fail "the leaderlog unit does not read the journal and needs no extra group"
grep -Fxq "enable ${LEADERLOG_UNIT} ${VALIDATE_UNIT}" "${SYSTEMCTL_LOG}" ||
  fail "unit install did not enable the leaderlog and validate services: $(< "${SYSTEMCTL_LOG}")"
if grep -Eq '^(start|restart) ' "${SYSTEMCTL_LOG}"; then
  fail "unit install unexpectedly started a service"
fi
: > "${SYSTEMCTL_LOG}"
run_leaderlog systemd status
assert_eq "${status}" "0" "unit status: ${output}"
grep -Fxq -- "--no-pager status ${LEADERLOG_UNIT} ${VALIDATE_UNIT}" "${SYSTEMCTL_LOG}" ||
  fail "unit status did not inspect the leaderlog and validate services"
[[ ! -e "${BLOCKLOG_DB_FILE}" ]] || fail "systemd management created the blocklog database"

# Nothing is calculated while the node is away from the tip.
write_schedule "${EPOCH}" 40000 100 86399
: > "${STATE_ROOT}/metrics-down"
run_leaderlog leaderlog force
assert_eq "${status}" "1" "leaderlog without node metrics"
[[ "${output}" == *"Node metrics not available"* ]] ||
  fail "leaderlog without node metrics: ${output}"
rm -f "${STATE_ROOT}/metrics-down"
printf '301\n' > "${STATE_ROOT}/slot-lag"
run_leaderlog leaderlog force
assert_eq "${status}" "1" "leaderlog on a syncing node"
[[ "${output}" == *"Node still syncing"* ]] ||
  fail "leaderlog on a syncing node: ${output}"
rm -f "${STATE_ROOT}/slot-lag"
printf '1\n' > "${STATE_ROOT}/epoch-lag"
run_leaderlog leaderlog force
assert_eq "${status}" "1" "leaderlog before the first block of the epoch"
[[ "${output}" == *"Waiting for the first block of epoch ${EPOCH}"* ]] ||
  fail "leaderlog before the first block of the epoch: ${output}"
rm -f "${STATE_ROOT}/epoch-lag"
[[ ! -e "${STATE_ROOT}/amaru-calls" ]] || fail "leaderlog was calculated away from the tip"

# An Amaru release without the schedule command is named as the cause.
: > "${STATE_ROOT}/no-schedule-command"
run_leaderlog leaderlog force
assert_eq "${status}" "1" "leaderlog on an Amaru release without the schedule command"
[[ "${output}" == *"amaru test has no 'pool schedule inspect' command"* ]] ||
  fail "missing schedule command is not reported: ${output}"
rm -f "${STATE_ROOT}/no-schedule-command"

# A failing calculation or an unexpected report leaves no trace in the database.
printf '0\n' > "${STATE_ROOT}/slot-in-epoch"
mv "${STATE_ROOT}/schedule-${EPOCH}.json" "${STATE_ROOT}/schedule.keep"
run_leaderlog leaderlog force
assert_eq "${status}" "1" "failing calculation"
[[ "${output}" == *"ERROR: failure in leaderlog"* &&
   "${output}" == *"no ledger snapshot for epoch ${EPOCH}"* ]] ||
  fail "failing calculation does not show the cause: ${output}"
for report in \
  'not json' \
  "{\"active_stake\":1000,\"epoch\":$(( EPOCH - 1 )),\"pool_stake\":50,\"schedule\":[]}" \
  "{\"active_stake\":0,\"epoch\":${EPOCH},\"pool_stake\":0,\"schedule\":[]}" \
  "{\"active_stake\":1000,\"epoch\":${EPOCH},\"pool_stake\":50}" \
  "{\"active_stake\":1000,\"epoch\":${EPOCH},\"pool_stake\":50,\"schedule\":[{\"relative_slot\":1,\"slot\":\"1\",\"time\":\"2026-01-01T00:00:00Z\"}]}" \
  "{\"active_stake\":1000,\"epoch\":${EPOCH},\"pool_stake\":50,\"schedule\":[{\"relative_slot\":1,\"slot\":1,\"time\":\"x'); DROP TABLE blocklog; --\"}]}" \
  "{\"active_stake\":1000,\"epoch\":${EPOCH},\"nonce\":null,\"pool_stake\":50,\"schedule\":[]}" \
  "{\"active_stake\":1000,\"epoch\":${EPOCH},\"nonce\":\"x'); DROP TABLE epochdata; --\",\"pool_stake\":50,\"schedule\":[]}"; do
  printf '%s\n' "${report}" > "${STATE_ROOT}/schedule-${EPOCH}.json"
  run_leaderlog leaderlog force
  assert_eq "${status}" "1" "unexpected report '${report}'"
  [[ "${output}" == *"unexpected leader schedule report"* ]] ||
    fail "unexpected report '${report}' is not rejected: ${output}"
done
assert_eq "$(db 'SELECT (SELECT COUNT(*) FROM epochdata) + (SELECT COUNT(*) FROM blocklog);')" "0" \
  "rows after failed calculations"
assert_eq "$(db 'PRAGMA user_version;')" "2" "blocklog schema version"
assert_eq "$(db "SELECT COUNT(*) FROM sqlite_master WHERE name = 'blockdetail';")" "1" "blockdetail table"
mv "${STATE_ROOT}/schedule.keep" "${STATE_ROOT}/schedule-${EPOCH}.json"

# The current epoch, before the nonce of the next one is final.
: > "${STATE_ROOT}/amaru-calls"
run_leaderlog leaderlog force
assert_eq "${status}" "0" "leaderlog for the current epoch: ${output}"
assert_eq "$(< "${STATE_ROOT}/amaru-calls")" \
  "pool schedule inspect --network preview --db-chain ${NODE_ROOT}/state/chain --db-ledger ${NODE_ROOT}/state/ledger --operator-vrf ${POOL_DIR}/vrf.skey --epoch ${EPOCH} --time-utc" \
  "Amaru command line"
assert_eq "$(db 'SELECT epoch, epoch_nonce, pool_id, sigma, d, epoch_slots_ideal, max_performance, active_stake, total_active_stake FROM epochdata;')" \
  "${EPOCH}||${POOL_ID_FROM_OPCERT}|0.050000000000000000|0.0|216|1.39|50000000000000|1000000000000000" \
  "epoch data"
first_slot=$(( EPOCH * PREVIEW_EPOCH_LENGTH + 100 ))
assert_eq "$(db 'SELECT slot, slot_in_epoch, epoch, at, block, hash, size, status FROM blocklog ORDER BY slot;')" \
  "${first_slot}|100|${EPOCH}|$(date -u -d "@$(( PREVIEW_START + first_slot ))" '+%FT%T+00:00')|0||0|leader
$(( first_slot + 39900 ))|40000|${EPOCH}|$(date -u -d "@$(( PREVIEW_START + first_slot + 39900 ))" '+%FT%T+00:00')|0||0|leader
$(( first_slot + 86299 ))|86399|${EPOCH}|$(date -u -d "@$(( PREVIEW_START + first_slot + 86299 ))" '+%FT%T+00:00')|0||0|leader" \
  "leader slots"
[[ "${output}" == *"LEADER: slot[${first_slot}] slotInEpoch[100] at["* &&
   "${output}" == *"Leaderlog calculation for epoch[${EPOCH}] completed and saved to blocklog DB"* &&
   "${output}" == *"Leaderslots: 3 - Ideal slots for epoch based on active stake: 216.00 - Luck factor 1.39%"* ]] ||
  fail "leaderlog summary: ${output}"

# pool.id takes precedence over the certificate, BLOCKLOG_TZ sets the offset
# of the stored times, the epoch nonce is stored when Amaru reports it, and a
# forced run past the nonce point covers the next epoch as well.
POOL_ID_FROM_FILE="$(printf '0f%.0s' {1..28})"
NONCE="$(printf 'a1%.0s' {1..32})"
printf '%s\n' "${POOL_ID_FROM_FILE}" > "${POOL_DIR}/pool.id"
SCHEDULE_NONCE="${NONCE}" write_schedule "${EPOCH}" 200 300
write_schedule "${NEXT_EPOCH}"
printf '%s\n' "${NEXT_EPOCH_GATE}" > "${STATE_ROOT}/slot-in-epoch"
BLOCKLOG_TZ="XXX-2" run_leaderlog leaderlog force
assert_eq "${status}" "0" "forced leaderlog past the nonce point: ${output}"
assert_eq "$(db "SELECT epoch, COUNT(*) FROM blocklog WHERE at LIKE '%+02:00' GROUP BY epoch;")" \
  "${EPOCH}|2" "leader slots after a forced run"
assert_eq "$(db 'SELECT COUNT(*) FROM blocklog;')" "2" "replaced leader slots"
assert_eq "$(db "SELECT epoch, max_performance, epoch_nonce FROM epochdata WHERE pool_id='${POOL_ID_FROM_FILE}' ORDER BY epoch;")" \
  "${EPOCH}|0.93|${NONCE}
${NEXT_EPOCH}|0.0|" "epoch data after a forced run"
[[ "${output}" == *"No leader slots found for epoch ${NEXT_EPOCH}"* ]] ||
  fail "an empty schedule is not reported: ${output}"
rm -f "${POOL_DIR}/pool.id"
db 'DELETE FROM epochdata; DELETE FROM blocklog;'

# As a service: the current epoch at start, the next epoch once, when the node
# is past the nonce point.
write_schedule "${EPOCH}" 40000 100 86399
write_schedule "${NEXT_EPOCH}" 7 8
printf '%s\n' "$(( NEXT_EPOCH_GATE - 1 ))" > "${STATE_ROOT}/slot-in-epoch"
: > "${STATE_ROOT}/amaru-calls"
start_service
wait_for_log "Leaderlog calculation for epoch[${EPOCH}] completed and saved to blocklog DB"
sleep 3
assert_eq "$(calls_for_epoch "${EPOCH}")" "1" "calculations of the current epoch"
assert_eq "$(calls_for_epoch "${NEXT_EPOCH}")" "0" \
  "calculations of the next epoch before its nonce is final"
printf '%s\n' "${NEXT_EPOCH_GATE}" > "${STATE_ROOT}/slot-in-epoch"
wait_for_log "Leaderlog calculation for epoch[${NEXT_EPOCH}] completed and saved to blocklog DB"
sleep 3
assert_eq "$(calls_for_epoch "${NEXT_EPOCH}")" "1" "calculations of the next epoch"
assert_eq "$(db 'SELECT epoch, COUNT(*) FROM blocklog GROUP BY epoch ORDER BY epoch;')" \
  "${EPOCH}|3
${NEXT_EPOCH}|2" "leader slots stored by the service"
stop_service

# A restart keeps a stored schedule that is still valid, here with a status
# another tool recorded for one of the slots. A schedule stored without a nonce
# gets it once Amaru reports one.
db "UPDATE blocklog SET status='confirmed', block=7 WHERE slot=${first_slot};"
SCHEDULE_NONCE="${NONCE}" write_schedule "${EPOCH}" 40000 100 86399
start_service
wait_for_log "Leaderlogs already calculated for epoch ${EPOCH} and still valid, 3 leader slots"
stop_service
assert_eq "$(db "SELECT status, block FROM blocklog WHERE slot=${first_slot};")" "confirmed|7" \
  "slot status after a restart"
assert_eq "$(db "SELECT epoch, epoch_nonce FROM epochdata ORDER BY epoch;")" "${EPOCH}|${NONCE}
${NEXT_EPOCH}|" "epoch nonce added to a kept schedule"

# A stored schedule that the node no longer agrees with is replaced; a failed
# calculation is tried again.
write_schedule "${EPOCH}" 500 600 700 800
db "DELETE FROM epochdata WHERE epoch=${NEXT_EPOCH}; DELETE FROM blocklog WHERE epoch=${NEXT_EPOCH};"
mv "${STATE_ROOT}/schedule-${NEXT_EPOCH}.json" "${STATE_ROOT}/schedule.keep"
start_service
wait_for_log "Stored leaderlog for epoch ${EPOCH} is no longer valid, replacing it"
wait_for_log "no ledger snapshot for epoch ${NEXT_EPOCH}"
mv "${STATE_ROOT}/schedule.keep" "${STATE_ROOT}/schedule-${NEXT_EPOCH}.json"
wait_for_log "Leaderlog calculation for epoch[${NEXT_EPOCH}] completed and saved to blocklog DB"
stop_service
assert_eq "$(db 'SELECT epoch, COUNT(*), MIN(slot_in_epoch), MAX(slot_in_epoch) FROM blocklog GROUP BY epoch ORDER BY epoch;')" \
  "${EPOCH}|4|500|800
${NEXT_EPOCH}|2|7|8" "leader slots after a replaced schedule"
assert_eq "$(db 'SELECT COUNT(*) FROM epochdata;')" "2" "epoch data rows"

# The unit can be inspected and removed after the pool, the node binary and
# its configuration are gone; the database stays.
rm -rf "${POOL_DIR}" "${NODE_ROOT}/bin/amaru" "${SCRIPT_ROOT}/amaru.env"
: > "${SYSTEMCTL_LOG}"
run_leaderlog systemd status
assert_eq "${status}" "0" "unit status without the pool: ${output}"
run_leaderlog systemd remove
assert_eq "${status}" "0" "unit removal: ${output}"
[[ ! -e "${unit_file}" && ! -e "${validate_unit_file}" ]] || fail "leaderlog or validate unit was not removed"
grep -Fxq "disable --now ${LEADERLOG_UNIT}" "${SYSTEMCTL_LOG}" ||
  fail "unit removal did not disable the leaderlog service"
grep -Fxq "disable --now ${VALIDATE_UNIT}" "${SYSTEMCTL_LOG}" ||
  fail "unit removal did not disable the validate service"
[[ -f "${BLOCKLOG_DB_FILE}" ]] || fail "unit removal deleted the blocklog database"

printf 'amaru leaderlog tests passed\n'
