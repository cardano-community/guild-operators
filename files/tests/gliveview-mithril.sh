#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2034,SC2153,SC2154,SC2329
# gLiveView's Mithril signer panel: where the signer's metrics are read
# (MITHRIL_SIGNER_HOST and MITHRIL_SIGNER_PORT in env, else mithril.env), the
# background read against a stand-in metrics endpoint (a local signer, one on
# another host without mithril.env, one that does not answer, one without any
# registration yet), the notices, the rail's Mithril line, the panel, the
# overview strip and where the pages put them. With python3 the read also runs
# against a real HTTP server.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf 'gliveview-mithril skipped: Bash 4.4+ required\n'
  exit 0
fi

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
HTTP_PID=''
cleanup() {
  [[ -z "${HTTP_PID}" ]] || kill "${HTTP_PID}" 2>/dev/null || true
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: '$2' not in '$1'"
}

for test_locale in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if LC_ALL="${test_locale}" "${BASH}" -c '[[ ${#1} -eq 1 ]]' _ '█' 2>/dev/null; then
    export LC_ALL="${test_locale}"
    break
  fi
done
[[ "${LC_ALL:-}" == *[Uu][Tt][Ff]* ]] || fail "no UTF-8 locale is available for the test"

GLIVEVIEW="${REPO_ROOT}/scripts/common-helper-scripts/gLiveView.sh"

# glv_load <file> <function>...: define functions copied from a script, both
# one-line and multi-line ones, without running the script.
glv_load() {
  local file="$1" name definition
  shift
  for name in "$@"; do
    definition="$(awk -v name="${name}" '
      !found && index($0, name "() {") == 1 {
        found = 1
        print
        if ($0 ~ /}[[:space:]]*$/) exit
        next
      }
      found { print; if ($0 == "}") exit }' "${file}")"
    [[ -n "${definition}" ]] || fail "${file##*/} no longer defines ${name}"
    eval "${definition}"
  done
}

glv_load "${GLIVEVIEW}" ui_colour_256 ui_colour ui_theme ui_put ui_gap ui_putw ui_kv ui_endl ui_grid ui_wrap \
  ui_scale ui_fmt_int ui_box_top ui_panel glv_is_int glv_cell glv_fmt_span glv_note_panel \
  glv_data_init glv_data_stamp glv_data_event glv_notice glv_notices_sweep glv_notices_tally glv_notices_load \
  glv_main_begin glv_main_room glv_main_add glv_view_overview glv_help_add glv_help_mithril \
  glv_mithril_enabled glv_mithril_target glv_mithril_job_run glv_mithril_job_start glv_mithril_job_poll \
  glv_mithril_failed glv_mithril_load glv_mithril_tick glv_mithril_answering glv_mithril_epoch \
  glv_mithril_count glv_mithril_status glv_panel_mithril glv_mithril_vital glv_notices_mithril
eval "$(grep -E '^(GLV_VERSION|UI_RESET|UI_BOLD|UI_REVERSE|UI_L|UI_LW|GLV_ROWS_MAX|GLV_EVENTS_MAX|GLV_NOTICE_NEEDS_NODE|GLV_NOTICE_QUIET)=' "${GLIVEVIEW}")"
# The Mithril section's state, as the script declares it.
eval "$(sed -n "/^MITHRIL_JOB_PID=''$/,/^declare -gA MITHRIL_M=/p" "${GLIVEVIEW}")"
assert_eq "${MITHRIL_STATE}" off "the Mithril section's state could not be loaded"
assert_eq "${MITHRIL_POLL}" 30 "the signer's metrics are read every 30 s"
[[ "${GLV_NOTICE_NEEDS_NODE}" == *" mithril-reg "* ]] || fail "the registration notice stays while the node is away"
[[ "${GLV_VERSION}" == v2.1.* ]] || fail "gLiveView with the Mithril panel is 2.1: ${GLV_VERSION}"

printf -v UI_SPACES '%500s' ''
UI_DASHES="${UI_SPACES// /─}"
UI_DOUBLE="${UI_SPACES// /═}"
UI_HELP=''
UI_FOCUS=''
declare -gA UI_PANEL_KEY=() UI_PANEL_TITLE=()
UI_PANELS=()
GLV_COLORS=truecolor
ui_theme default
glv_strip() { sed $'s/\e\\[[0-9;]*m//g'; }

NODE_HOME="${TEST_ROOT}/node"
MITHRIL_HOME="${NODE_HOME}/mithril"
mkdir -p "${MITHRIL_HOME}"
GLV_NOTICE_STATE_FILE="${TEST_ROOT}/gLiveView.sh.notices"
MITHRIL_JOB_FILE="${TEST_ROOT}/mithril.job"
NODE_SERVICE=cnode.service
SLOT_LENGTH=1

# fresh_state: gLiveView as it starts on a block producer in epoch 612, two
# hours into the epoch, with the Mithril signer enabled.
fresh_state() {
  glv_data_init
  D_OK=Y; D_ROLE=Core; D_IMPL=cardano-node; D_COLLECTED_AT=10000; D_NOW=10000
  epochnum=612; slot_in_epoch=7200
  MITHRIL_SIGNER_ENABLED=Y
  unset MITHRIL_SIGNER_HOST MITHRIL_SIGNER_PORT
  MITHRIL_JOB_PID=''; MITHRIL_STATE=off; MITHRIL_URL=''; MITHRIL_ENDPOINT=''; MITHRIL_NOTE=''
  MITHRIL_ASKED_AT=0; MITHRIL_FETCHED_AT=0; MITHRIL_FAILED_AT=0; MITHRIL_FAILS=0
  MITHRIL_M=()
}

# The mithril.env that mithril-signer.sh -e writes, metrics on. A line that
# would run a command if the file were sourced, and the signer's own NETWORK.
write_env() {
  cat > "${MITHRIL_HOME}/mithril.env" <<-EOF
	NETWORK=preprod
	RUN_INTERVAL=60000
	TOUCHED=\$(touch ${TEST_ROOT}/sourced)
	ERA_READER_ADAPTER_PARAMS={"address":"abc","verification_key":"def"}
	ENABLE_METRICS_SERVER=${1:-true}
	METRICS_SERVER_IP=${2:-0.0.0.0}
	METRICS_SERVER_PORT=${3:-9091}
	EOF
}

# What mithril-signer 2642.0 serves: the prometheus crate's text format, with
# whole numbers as the counters and gauges keep them.
METRICS_DIR="${TEST_ROOT}/www"
mkdir -p "${METRICS_DIR}"
# write_metrics <registered epoch> <signed epoch> <registrations ok> <registrations> <signatures ok> <signatures>
write_metrics() {
  local name value
  : > "${METRICS_DIR}/metrics"
  while read -r name value; do
    printf '# HELP mithril_signer_%s Number of %s on a Mithril signer node\n# TYPE mithril_signer_%s counter\nmithril_signer_%s %s\n' \
      "${name}" "${name//_/ }" "${name}" "${name}" "${value}" >> "${METRICS_DIR}/metrics"
  done <<-EOF
	runtime_cycle_success_since_startup 1204
	runtime_cycle_total_since_startup 1206.0
	signature_registration_success_last_epoch $2
	signature_registration_success_since_startup $5
	signature_registration_total_since_startup $6
	signer_registration_success_last_epoch $1
	signer_registration_success_since_startup $3
	signer_registration_total_since_startup $4
	EOF
}
write_metrics 612 612 6 6 318 320

# The metrics endpoint stand-in. CURL_MODE: ok, refused, timeout, notfound,
# foreign (another exporter on the port).
CURL_MODE=ok
CURL_URL=''
curl() {
  local url=''
  while (( $# > 0 )); do
    case "$1" in
      -w|-m|--connect-timeout) shift ;;
      http*) url="$1" ;;
    esac
    shift
  done
  printf '%s\n' "${url}" > "${TEST_ROOT}/curl.url"
  case "${CURL_MODE}" in
    refused) printf '\n000'; return 7 ;;
    timeout) printf '\n000'; return 28 ;;
    notfound) printf 'Not Found\n\n404'; return 0 ;;
    foreign) printf '# TYPE prometheus_build_info gauge\nprometheus_build_info 1\n\n200'; return 0 ;;
  esac
  cat "${METRICS_DIR}/metrics"
  printf '\n200'
}

# read_now: one read, run in the foreground, taken in.
read_now() {
  glv_mithril_target
  glv_mithril_job_run "${MITHRIL_URL}" > "${TEST_ROOT}/read"
  glv_mithril_load "${TEST_ROOT}/read"
}

# ── where the metrics are ────────────────────────────────────────────────────
fresh_state
NETWORK=mainnet
write_env
glv_mithril_target
assert_eq "${MITHRIL_URL}" "http://127.0.0.1:9091/metrics" "0.0.0.0 in mithril.env is read on the loopback"
assert_eq "${MITHRIL_ENDPOINT}" "127.0.0.1:9091" "endpoint for the title"
assert_eq "${MITHRIL_REMOTE}" N "a loopback signer is local"
assert_eq "${MITHRIL_OFF}" N "mithril.env turns the metrics on"
assert_eq "${NETWORK}" mainnet "mithril.env is not sourced"
[[ ! -e "${TEST_ROOT}/sourced" ]] || fail "a command in mithril.env ran"

write_env true 192.168.1.20 9092
glv_mithril_target
assert_eq "${MITHRIL_URL}" "http://192.168.1.20:9092/metrics" "METRICS_SERVER_IP and METRICS_SERVER_PORT from mithril.env"
assert_eq "${MITHRIL_REMOTE}" Y "another address is remote"

# Quotes, export and Windows line ends are taken off.
printf 'export ENABLE_METRICS_SERVER="true"\r\nMETRICS_SERVER_IP='"'"'0.0.0.0'"'"'\r\nMETRICS_SERVER_PORT="9093"   \r\n' > "${MITHRIL_HOME}/mithril.env"
glv_mithril_target
assert_eq "${MITHRIL_URL}" "http://127.0.0.1:9093/metrics" "quoted and exported settings"
assert_eq "${MITHRIL_OFF}" N "a quoted true turns the metrics on"

# MITHRIL_SIGNER_HOST overrides METRICS_SERVER_IP and keeps its port; the
# port has its own override.
write_env
MITHRIL_SIGNER_HOST=10.0.0.5
glv_mithril_target
assert_eq "${MITHRIL_URL}" "http://10.0.0.5:9091/metrics" "MITHRIL_SIGNER_HOST with the port of mithril.env"
assert_eq "${MITHRIL_REMOTE}" Y "a signer on another host"
MITHRIL_SIGNER_PORT=12345
glv_mithril_target
assert_eq "${MITHRIL_URL}" "http://10.0.0.5:12345/metrics" "MITHRIL_SIGNER_PORT"
MITHRIL_SIGNER_HOST=http://signer.pod.local/
unset MITHRIL_SIGNER_PORT
glv_mithril_target
assert_eq "${MITHRIL_URL}" "http://signer.pod.local:9091/metrics" "a host given as a URL"

# A signer on another host has no mithril.env on this one.
rm -f "${MITHRIL_HOME}/mithril.env"
MITHRIL_SIGNER_HOST=10.0.0.5
glv_mithril_target
assert_eq "${MITHRIL_URL}" "http://10.0.0.5:9090/metrics" "a remote signer without mithril.env reads port 9090"
assert_eq "${MITHRIL_OFF}" N "no mithril.env does not turn the metrics off"
MITHRIL_SIGNER_HOST=fd00::5
glv_mithril_target
assert_eq "${MITHRIL_URL}" "http://[fd00::5]:9090/metrics" "an IPv6 host in brackets"
unset MITHRIL_SIGNER_HOST
glv_mithril_target
assert_eq "${MITHRIL_URL}" "http://127.0.0.1:9090/metrics" "neither env nor mithril.env: the loopback and 9090"
write_env true '::' 9090
glv_mithril_target
assert_eq "${MITHRIL_URL}" "http://[::1]:9090/metrics" ":: is read on the IPv6 loopback"

# A local signer without its metrics server.
write_env false
glv_mithril_target
assert_eq "${MITHRIL_OFF}" Y "ENABLE_METRICS_SERVER=false turns the metrics off"
MITHRIL_SIGNER_HOST=10.0.0.5
glv_mithril_target
assert_eq "${MITHRIL_OFF}" N "mithril.env does not speak for a signer elsewhere"
unset MITHRIL_SIGNER_HOST

# ── reading the metrics ──────────────────────────────────────────────────────
fresh_state
write_env
glv_mithril_target
glv_mithril_job_run "${MITHRIL_URL}" > "${TEST_ROOT}/read"
assert_eq "$(head -1 "${TEST_ROOT}/read")" ok "a read that answers"
assert_eq "$(cat "${TEST_ROOT}/curl.url")" "http://127.0.0.1:9091/metrics" "the read asks the resolved address"
assert_eq "$(grep -c '^m' "${TEST_ROOT}/read")" 8 "the eight signer metrics"
glv_mithril_load "${TEST_ROOT}/read"
assert_eq "${MITHRIL_STATE}" ok "state after an answer"
assert_eq "${MITHRIL_M[signer_registration_success_last_epoch]}" 612 "registered epoch"
assert_eq "${MITHRIL_M[signature_registration_total_since_startup]}" 320 "signature attempts"
assert_eq "${MITHRIL_M[runtime_cycle_total_since_startup]}" 1206 "a value written as 1206.0"

for mode in refused timeout notfound foreign; do
  CURL_MODE="${mode}"
  glv_mithril_job_run "${MITHRIL_URL}" > "${TEST_ROOT}/read"
  assert_eq "$(cut -f1 "${TEST_ROOT}/read")" fail "a read that fails (${mode})"
  case "${mode}" in
    refused) assert_eq "$(cut -f2 "${TEST_ROOT}/read")" "no connection to it" "reason without a connection" ;;
    timeout) assert_eq "$(cut -f2 "${TEST_ROOT}/read")" "no answer within 5 s" "reason for a timeout" ;;
    notfound) assert_eq "$(cut -f2 "${TEST_ROOT}/read")" "it answers with HTTP status 404" "reason for an HTTP error" ;;
    foreign) assert_eq "$(cut -f2 "${TEST_ROOT}/read")" "the answer has no Mithril signer metrics" "reason for another exporter" ;;
  esac
done

# A failed read keeps the figures; two in a row are "no metrics".
CURL_MODE=refused
D_NOW=10030
read_now
assert_eq "${MITHRIL_STATE}" stale "one failed read after an answer"
assert_eq "${MITHRIL_FAILS}" 1 "failed reads counted"
assert_eq "${MITHRIL_M[signer_registration_success_last_epoch]}" 612 "the figures stay"
glv_mithril_answering || fail "one missed read still shows the figures"
D_NOW=10060
read_now
assert_eq "${MITHRIL_FAILS}" 2 "two failed reads"
! glv_mithril_answering || fail "two missed reads show no figures"
CURL_MODE=ok
read_now
assert_eq "${MITHRIL_STATE}:${MITHRIL_FAILS}:${MITHRIL_NOTE}" "ok:0:" "an answer clears the failures"

# ── the background read ──────────────────────────────────────────────────────
fresh_state
MITHRIL_SIGNER_ENABLED=N
glv_mithril_tick
assert_eq "${MITHRIL_STATE}:${MITHRIL_JOB_PID}" "off:" "nothing is read with MITHRIL_SIGNER_ENABLED=N"
MITHRIL_SIGNER_ENABLED=Y
glv_mithril_tick
[[ -n "${MITHRIL_JOB_PID}" ]] || fail "the first tick starts a read"
assert_eq "${MITHRIL_STATE}" waiting "state while the first read runs"
wait "${MITHRIL_JOB_PID}" 2>/dev/null || true
D_NOW=10001
glv_mithril_tick
assert_eq "${MITHRIL_STATE}:${MITHRIL_JOB_PID}" "ok:" "the tick takes in the finished read"
assert_eq "${MITHRIL_FETCHED_AT}" 10001 "time of the answer"
D_NOW=10029
glv_mithril_tick
assert_eq "${MITHRIL_JOB_PID}" "" "no new read before 30 s"
D_NOW=10031
glv_mithril_tick
[[ -n "${MITHRIL_JOB_PID}" ]] || fail "a new read after 30 s"
wait "${MITHRIL_JOB_PID}" 2>/dev/null || true
glv_mithril_tick
# A changed address drops the figures of the old one.
write_env true 0.0.0.0 9099
D_NOW=10070
glv_mithril_tick
assert_eq "${MITHRIL_STATE}" waiting "a new address starts again"
assert_eq "${#MITHRIL_M[@]}" 0 "the figures of the old address are dropped"
wait "${MITHRIL_JOB_PID}" 2>/dev/null || true
glv_mithril_tick
# Metrics off: no read at all.
write_env false
D_NOW=10110
glv_mithril_tick
assert_eq "${MITHRIL_STATE}:${MITHRIL_JOB_PID}" "disabled:" "no read while mithril.env turns the metrics off"

# ── notices ──────────────────────────────────────────────────────────────────
# notices: run the Mithril checks as glv_notices_check does.
notices() {
  N_RAISED=()
  glv_notices_mithril
  glv_notices_sweep
}

# A local signer, registered and signing in this epoch.
fresh_state
write_env
read_now
notices
assert_eq "${#N_IDS[@]}" 0 "a signer that registered and signed raises nothing"

write_metrics 611 611 5 6 300 301
read_now
notices
assert_eq "${N_LEVEL[mithril-reg]:-}" warning "not registered in this epoch is a warning"
assert_eq "${N_TITLE[mithril-reg]}" "Mithril not registered" "registration notice title"
contains "${N_TEXT[mithril-reg]}" "in epoch 612; it last registered in epoch 611" "the text names both epochs"
contains "${N_TEXT[mithril-reg]}" "journalctl -u cnode-mithril-signer" "a local signer's log"
assert_eq "${N_KEY[mithril-reg]}" "mithril-reg|registered|612" "acknowledged for the epoch"
(( ${#N_TITLE[mithril-reg]} <= 22 )) || fail "the title fits the rail"

# Not in the first hour of the epoch, nor in the signer's first cycles.
slot_in_epoch=1800
notices
assert_eq "${N_LEVEL[mithril-reg]:-}" "" "the first hour of an epoch is left to the registration"
slot_in_epoch=7200
sed -i.bak 's/^mithril_signer_runtime_cycle_total_since_startup .*/mithril_signer_runtime_cycle_total_since_startup 5/' "${METRICS_DIR}/metrics"
read_now
notices
assert_eq "${N_LEVEL[mithril-reg]:-}" "" "a signer in its first cycles is not judged"

# Zero registrations since the signer started.
write_metrics 0 0 0 3 0 0
read_now
notices
assert_eq "${N_TITLE[mithril-reg]:-}" "Mithril not registered" "no registration since the start"
contains "${N_TEXT[mithril-reg]}" "since it started (3 attempts)" "the attempts are counted"

# Registered, but no signature in this epoch.
write_metrics 612 611 6 6 300 305
read_now
notices
assert_eq "${N_TITLE[mithril-reg]:-}" "Mithril not signing" "no signature in this epoch"
contains "${N_TEXT[mithril-reg]}" "its last signature was in epoch 611" "the last signature's epoch"
contains "${N_TEXT[mithril-reg]}" "300 of 305 signature attempts succeeded" "the signature counts"
assert_eq "${N_KEY[mithril-reg]}" "mithril-reg|signed|612" "its own acknowledgement key"
# A signer that has not tried to sign since it started is still waiting for
# its first epoch as a signer.
write_metrics 612 0 1 1 0 0
read_now
notices
assert_eq "${N_LEVEL[mithril-reg]:-}" "" "no signing notice before the signer tried to sign"

# The node away keeps the notice: it needs the node's epoch.
write_metrics 611 611 5 6 300 301
read_now
notices
D_OK=N
notices
assert_eq "${N_LEVEL[mithril-reg]:-}" warning "the registration notice stays while the node is away"
D_OK=Y
write_metrics 612 612 6 6 318 320

# Metrics that do not answer: after two reads in a row.
fresh_state
write_env
read_now
CURL_MODE=refused
read_now
notices
assert_eq "${N_LEVEL[mithril]:-}" "" "one missed read raises nothing"
read_now
notices
assert_eq "${N_LEVEL[mithril]:-}" warning "two missed reads are a warning"
assert_eq "${N_TITLE[mithril]}" "No Mithril metrics" "metrics notice title"
contains "${N_TEXT[mithril]}" "at http://127.0.0.1:9091/metrics: no connection to it" "the text names the address and the reason"
contains "${N_TEXT[mithril]}" "set MITHRIL_SIGNER_HOST" "a local address points at MITHRIL_SIGNER_HOST"
assert_eq "${N_KEY[mithril]}" "mithril|http://127.0.0.1:9091/metrics" "acknowledged for the address"
assert_eq "${N_LEVEL[mithril-reg]:-}" "" "no registration notice without figures"

# The same for a signer on another host, without mithril.env here.
fresh_state
rm -f "${MITHRIL_HOME}/mithril.env"
MITHRIL_SIGNER_HOST=10.0.0.5
CURL_MODE=timeout
read_now
read_now
notices
contains "${N_TEXT[mithril]}" "at http://10.0.0.5:9090/metrics: no answer within 5 s" "a remote signer's address"
contains "${N_TEXT[mithril]}" "runs on that host" "remote advice"
CURL_MODE=ok
read_now
notices
assert_eq "${N_LEVEL[mithril]:-}" "" "an answer clears the metrics notice"
assert_eq "${#N_IDS[@]}" 0 "the remote signer is fine"
write_metrics 611 611 5 6 300 301
read_now
notices
contains "${N_TEXT[mithril-reg]}" "The signer's log on its host says why." "a remote signer's log is on its host"
write_metrics 612 612 6 6 318 320

# Metrics turned off in mithril.env.
fresh_state
write_env false
glv_mithril_job_start
notices
assert_eq "${N_TITLE[mithril]:-}" "Mithril metrics off" "metrics off is a notice"
contains "${N_TEXT[mithril]}" "ENABLE_METRICS_SERVER=true" "the text says what to set"
MITHRIL_SIGNER_ENABLED=N
notices
assert_eq "${#N_IDS[@]}" 0 "nothing with MITHRIL_SIGNER_ENABLED=N"

# ── the rail's Mithril line ──────────────────────────────────────────────────
vital() { local text colour; glv_mithril_vital text colour; printf '%s|%s' "${text}" "${colour}"; }
fresh_state
write_env
assert_eq "$(vital)" "asking…|${C_MUTED}" "before the first answer"
read_now
assert_eq "$(vital)" "signed e612|${C_OK}" "signed in this epoch"
write_metrics 612 611 6 6 300 300
read_now
slot_in_epoch=600
assert_eq "$(vital)" "registered|${C_OK}" "registered, not signed yet"
write_metrics 611 611 5 6 300 300
read_now
assert_eq "$(vital)" "online|${C_OK}" "early in the epoch"
slot_in_epoch=7200
notices
assert_eq "$(vital)" "not registered|${C_WARN}" "while the registration notice is raised"
CURL_MODE=refused
read_now
read_now
assert_eq "$(vital)" "no metrics|${C_DANGER}" "metrics that do not answer"
CURL_MODE=ok
write_env false
glv_mithril_job_start
assert_eq "$(vital)" "metrics off|${C_WARN}" "metrics off"
MITHRIL_SIGNER_ENABLED=N
assert_eq "$(vital)" "|${C_MUTED}" "no line without MITHRIL_SIGNER_ENABLED"
write_metrics 612 612 6 6 318 320

# ── the panel and the strip ──────────────────────────────────────────────────
# panel <width> [strip]: builds P_MITHRIL, and its lines as plain text in lines.
panel() {
  glv_panel_mithril "$@"
  mapfile -t lines < <(printf '%s\n' "${P_MITHRIL[@]}" | glv_strip)
}
squash() { tr -s ' '; }

fresh_state
write_env
D_NOW=10012
read_now
D_NOW=10024
panel 104
assert_eq "${#lines[@]}" 4 "the Production panel is two rows"
contains "${lines[0]}" "╭─ Mithril signer " "panel title"
contains "${lines[0]}" " 127.0.0.1:9091 · 12 s ago ─╮" "the address and the age of the answer"
for line in "${lines[@]}"; do assert_eq "${#line}" 104 "panel width"; done
contains "$(squash <<< "${lines[1]}")" "Status online Registered epoch 612 ✓ Signed epoch 612 ✓" "the first row: where the signer stands"
contains "$(squash <<< "${lines[2]}")" "Cycles 1,204 of 1,206 Registrations 6 of 6 Signatures 318 of 320" "the second row: counts since the start"
[[ "$(printf '%s\n' "${P_MITHRIL[1]}")" == *"${C_OK}online"* ]] || fail "online in green"

# A narrow page stacks the cells in two columns.
panel 80
assert_eq "${#lines[@]}" 5 "a narrow panel is three rows"
contains "$(squash <<< "${lines[1]}")" "Status online Cycles 1,204 of 1,206" "narrow first row"
contains "$(squash <<< "${lines[3]}")" "Signed epoch 612 ✓ Signatures 318 of 320" "narrow last row"

# The overview strip: one row, the signatures where there is room.
panel 104 strip
assert_eq "${#lines[@]}" 3 "the strip is one row"
contains "$(squash <<< "${lines[1]}")" "Status online Registered e612 ✓ Signed e612 ✓ │" "a standard strip"
panel 124 strip
contains "$(squash <<< "${lines[1]}")" "Signed e612 ✓ Signatures 318 of 320" "a wide strip adds the signatures"

# Zero registrations since the start, with the notice raised.
write_metrics 0 0 0 3 0 0
read_now
notices
panel 104
contains "$(squash <<< "${lines[1]}")" "Registered not yet Signed not yet" "nothing since the start"
contains "$(squash <<< "${lines[2]}")" "Registrations 0 of 3 Signatures 0 of 0" "zero registrations counted"
[[ "${P_MITHRIL[1]}" == *"${C_WARN}not yet"* ]] || fail "registration not yet in amber while the notice is raised"

# Behind by an epoch.
write_metrics 611 612 5 6 300 301
read_now
notices
panel 104
contains "$(squash <<< "${lines[1]}")" "Registered epoch 611 Signed epoch 612 ✓" "the epoch without a tick"
[[ "${P_MITHRIL[1]}" == *"${C_WARN}epoch 611"* ]] || fail "the late registration in amber"
write_metrics 612 612 6 6 318 320

# An answer missed: the figures stay, the title says from when.
fresh_state
write_env
D_NOW=36000
read_now
CURL_MODE=refused
D_NOW=36030
read_now
panel 104
printf -v when '%(%H:%M)T' 36000
contains "${lines[0]}" " not answering · data from ${when} ─╮" "stale title"
contains "$(squash <<< "${lines[1]}")" "Status not answering Registered epoch 612 ✓" "stale figures"
# Never answered: a note instead of figures.
fresh_state
write_env
read_now
panel 104
printf -v when '%(%H:%M)T' "${D_NOW}"
contains "${lines[0]}" " 127.0.0.1:9091 ─╮" "the address in the title"
contains "$(squash <<< "${lines[1]}")" "Not answering at ${when}: no connection to it. gLiveView asks again every 30 s." "the reason in the panel"
panel 104 strip
assert_eq "${#lines[@]}" 3 "the strip keeps one row for the note"
CURL_MODE=ok
# Metrics off.
write_env false
glv_mithril_job_start
panel 104
contains "$(squash <<< "${lines[1]}")" "Metrics off: mithril.env does not set ENABLE_METRICS_SERVER=true" "metrics off in the panel"

# ── where the pages put it ───────────────────────────────────────────────────
# Stand-ins for the overview's other panels: one titled row each.
stub_panel() {
  local -n _stub="$1"
  _stub=("[$2]")
  local i
  for ((i = 1; i < $3; i++)); do _stub+=("[$2]"); done
}
glv_panel_epoch() { stub_panel P_EPOCH epoch 4; }
glv_panel_chain() { stub_panel P_CHAIN chain 7; }
glv_panel_propagation() { stub_panel P_PROP prop 7; }
glv_panel_peers() { stub_panel P_PEERS peers 7; }
glv_panel_resources() { stub_panel P_RES res 7; }
glv_panel_production() { stub_panel P_PROD production 5; }
glv_panel_recent() { stub_panel P_RECENT recent "$2"; }
glv_panel_events() { stub_panel P_EVENTS events "$2"; }

fresh_state
write_env
read_now
LAYOUT=standard
glv_main_begin 40
glv_view_overview 104
overview="$(printf '%s\n' "${MAIN[@]}" | glv_strip)"
[[ "${overview}" == *"[production]"*"Mithril signer"*"[recent]"* ]] || fail "the strip comes under Block production, before Recent blocks"
assert_eq "$(grep -c 'Status' <<< "${overview}")" 1 "the overview strip is one row"
MITHRIL_SIGNER_ENABLED=N
glv_main_begin 40
glv_view_overview 104
[[ "$(printf '%s\n' "${MAIN[@]}")" != *"Mithril"* ]] || fail "no strip without MITHRIL_SIGNER_ENABLED"
MITHRIL_SIGNER_ENABLED=Y

# The Production page and the compact layout, from the script itself.
production="$(awk '/^glv_view_production\(\) \{/,/^}/' "${GLIVEVIEW}")"
[[ "${production}" == *'glv_main_add P_POOL'*'glv_panel_mithril "${width}"'*'glv_main_add P_MITHRIL'*'Leader schedule'* ]] ||
  fail "the Production page puts the panel under Pool, before the leader schedule"
compact="$(awk '/^glv_page_compact\(\) \{/,/^}/' "${GLIVEVIEW}")"
[[ "${compact}" == *'glv_main_add P_PROD'*'glv_panel_mithril "${width}" strip'*'glv_main_add P_RES'* ]] ||
  fail "the compact overview puts the strip under Production"
grep -q '^  glv_mithril_tick$' "${GLIVEVIEW}" || fail "the clock no longer ticks the Mithril read"
grep -q '^  glv_notices_mithril$' "${GLIVEVIEW}" || fail "the notice check no longer runs the Mithril notices"
grep -q 'glv_vital "${list}" "${colour}" "Mithril" "${text}"' "${GLIVEVIEW}" || fail "the rail has no Mithril line"
grep -q 'kill "${MITHRIL_JOB_PID}"' "${GLIVEVIEW}" || fail "the cleanup no longer stops the Mithril read"

# ── help ─────────────────────────────────────────────────────────────────────
eval "$(sed -n '/^HELP_PAGE_KEYS=/,/)$/p' "${GLIVEVIEW}")"
[[ " ${HELP_PAGE_KEYS[1]} " == *" production mithril "* ]] || fail "the overview's help lists the strip"
[[ " ${HELP_PAGE_KEYS[4]} " == *" pool mithril "* ]] || fail "the Production page's help lists the panel"
grep -q '\[mithril\]="Mithril signer"' "${GLIVEVIEW}" || fail "the help has a title for the panel"
fresh_state
write_env
read_now
HELP_ENTRIES=()
glv_help_mithril
assert_eq "${#HELP_ENTRIES[@]}" 5 "help entries for the panel"
contains "${HELP_ENTRIES[0]}" "|http://127.0.0.1:9091/metrics|" "the help quotes the address read"
contains "${HELP_ENTRIES[2]}" "Registered|" "the registration's help"
contains "${HELP_ENTRIES[2]}" "|epoch 612 ✓|ok" "the registration's current value"

# ── a real HTTP server ───────────────────────────────────────────────────────
if command -v python3 >/dev/null 2>&1 && type -P curl >/dev/null 2>&1; then
  unset -f curl
  for port in $(seq 39090 39110); do
    python3 -m http.server --bind 127.0.0.1 --directory "${METRICS_DIR}" "${port}" > "${TEST_ROOT}/http.log" 2>&1 &
    HTTP_PID=$!
    for _ in $(seq 1 50); do
      curl -s -o /dev/null "http://127.0.0.1:${port}/metrics" && break 2
      kill -0 "${HTTP_PID}" 2>/dev/null || break
      sleep 0.1
    done
    kill "${HTTP_PID}" 2>/dev/null || true
    HTTP_PID=''
  done
  [[ -n "${HTTP_PID}" ]] || fail "no port for the HTTP server"
  fresh_state
  rm -f "${MITHRIL_HOME}/mithril.env"
  MITHRIL_SIGNER_HOST=127.0.0.1
  MITHRIL_SIGNER_PORT="${port}"
  read_now
  assert_eq "${MITHRIL_STATE}" ok "a real metrics endpoint answers"
  assert_eq "${MITHRIL_M[signature_registration_success_since_startup]}" 318 "a real endpoint's figures"
  glv_mithril_job_run "http://127.0.0.1:${port}/missing" > "${TEST_ROOT}/read"
  assert_eq "$(cut -f2 "${TEST_ROOT}/read")" "it answers with HTTP status 404" "a real HTTP error"
  kill "${HTTP_PID}" 2>/dev/null || true
  wait "${HTTP_PID}" 2>/dev/null || true
  HTTP_PID=''
  glv_mithril_job_run "${MITHRIL_URL}" > "${TEST_ROOT}/read"
  assert_eq "$(cut -f2 "${TEST_ROOT}/read")" "no connection to it" "a real closed port"
else
  printf 'gliveview-mithril: no python3 or curl, the real HTTP check is skipped\n'
fi

printf 'gliveview-mithril tests passed\n'
