#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2317,SC2329
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${TEST_DIR}/../.." && pwd -P)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-amaru-migrate.XXXXXX")"
trap 'rm -rf -- "${TEMP_ROOT}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

assert_env() {
  local key="$1" expected="$2" actual
  actual="$(sed -n "s/^${key}=\"\\(.*\\)\"$/\\1/p" "${AMARU_MIGRATE_ENV_FILE}")"
  assert_eq "${actual}" "${expected}" "amaru.env ${key}"
}

# Layout: an Amaru deployment with the script and a cnode deployment next to it.
AMARU_HOME_DIR="${TEMP_ROOT}/opt/amaru"
CNODE_HOME_DIR="${TEMP_ROOT}/opt/cnode"
mkdir -p "${AMARU_HOME_DIR}/scripts/lib" "${AMARU_HOME_DIR}/files" "${CNODE_HOME_DIR}/files"
cp "${REPO_ROOT}/scripts/amaru-helper-scripts/migrate-from-cnode.sh" "${AMARU_HOME_DIR}/scripts/"
cp "${REPO_ROOT}/scripts/common-helper-scripts/lib/systemd.library" "${AMARU_HOME_DIR}/scripts/lib/"

write_amaru_env() {
  sed -e "s|@NODE_HOME@|${AMARU_HOME_DIR}|g" -e "s|@NODE_SERVICE@|amaru|g" \
    -e "s|@BINARY_PATH@|/bin/true|g" -e "s|@NODE_PORT@|3000|g" \
    "${REPO_ROOT}/files/configs/amaru/preview/amaru.env" > "${AMARU_HOME_DIR}/scripts/amaru.env"
}

write_cnode_manifest() {
  printf '{"schemaVersion":1,"deploymentStatus":"deployed","implementation":"%s","network":"%s","serviceName":"cnode"}\n' \
    "$1" "$2" > "${CNODE_HOME_DIR}/.deployment.json"
}

cat > "${CNODE_HOME_DIR}/files/topology.json" <<'EOF'
{"localRoots":[{"accessPoints":[{"address":"10.0.0.5","port":6000},{"address":"relay2.example.com","port":3001},{"address":"2001:db8::7","port":6000},{"address":"10.0.0.5","port":6000}]}],
 "publicRoots":[{"accessPoints":[{"address":"public.example.com","port":3001}]}]}
EOF

# Stubs for the system boundaries: systemctl, the launcher, both tips and the listening port.
CALLS="${TEMP_ROOT}/calls.log"
mkdir -p "${TEMP_ROOT}/bin"
cat > "${TEMP_ROOT}/bin/systemctl" <<EOF
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "${CALLS}"
EOF
cat > "${TEMP_ROOT}/bin/amaru.sh" <<EOF
#!/usr/bin/env bash
printf 'amaru.sh %s\n' "\$*" >> "${CALLS}"
EOF
chmod 0755 "${TEMP_ROOT}/bin/systemctl" "${TEMP_ROOT}/bin/amaru.sh"

export SYSTEMCTL_BIN="${TEMP_ROOT}/bin/systemctl" SUDO=N
AMARU_MIGRATE_LAUNCHER="${TEMP_ROOT}/bin/amaru.sh"
AMARU_MIGRATE_CNODE_HOME="${CNODE_HOME_DIR}"
AMARU_MIGRATE_POLL=0
AMARU_MIGRATE_VERIFY_TIMEOUT=3

# shellcheck source=/dev/null
. "${AMARU_HOME_DIR}/scripts/migrate-from-cnode.sh"
amaru_migrate_load_libraries

reset_case() {
  write_amaru_env
  write_cnode_manifest cnode preview
  rm -f -- "${CALLS}" "${AMARU_MIGRATE_STATE}"
  : > "${CALLS}"
  amaru_migrate_load_amaru_env
  amaru_migrate_check_cnode_deployment
}

relay_args() {
  printf '%s\n' run --topology "${CNODE_HOME_DIR}/files/topology.json" \
    --database-path "${CNODE_HOME_DIR}/db" --socket-path "${CNODE_HOME_DIR}/sockets/node.socket" \
    --port 6000 --config "${CNODE_HOME_DIR}/files/config.json"
}

# --- peer translation -------------------------------------------------------
assert_eq "$(amaru_migrate_local_roots "${CNODE_HOME_DIR}/files/topology.json")" \
  "10.0.0.5:6000,[2001:db8::7]:6000,relay2.example.com:3001" "localRoots as host:port, IPv6 bracketed, unique"
assert_eq "$(amaru_migrate_merge_peers "a:1,b:2" "b:2,c:3")" "a:1,b:2,c:3" "merged peers keep order without duplicates"

# --- amaru.env editing ------------------------------------------------------
reset_case
amaru_migrate_set_env AMARU_PEERS_MAX_UPSTREAM "5"
assert_env AMARU_PEERS_MAX_UPSTREAM "5"
amaru_migrate_set_env AMARU_SUBMIT_API_LISTEN_ON "127.0.0.1:8090"
assert_env AMARU_SUBMIT_API_LISTEN_ON "127.0.0.1:8090"
grep -q '^#AMARU_SUBMIT_API_LISTEN_ON=' "${AMARU_MIGRATE_ENV_FILE}" &&
  fail "commented setting should be replaced, not duplicated"
amaru_migrate_set_env AMARU_TEST_ONLY "x|y&z"
assert_env AMARU_TEST_ONLY "x|y&z"

# --- deployment checks ------------------------------------------------------
reset_case
write_cnode_manifest dingo preview
amaru_migrate_check_cnode_deployment 2>/dev/null && fail "non-cnode deployment must be refused"
write_cnode_manifest cnode preprod
amaru_migrate_check_cnode_deployment 2>/dev/null && fail "network mismatch must be refused"
rm -f "${CNODE_HOME_DIR}/.deployment.json"
amaru_migrate_check_cnode_deployment 2>/dev/null && fail "missing manifest must be refused"

reset_case
amaru_migrate_cnode_args() { relay_args; printf '%s\n' --shelley-kes-key /x/hot.skey; }
amaru_migrate_read_cnode 2>/dev/null && fail "block producer must be refused"
amaru_migrate_cnode_args() { relay_args; }
amaru_migrate_read_cnode
assert_eq "${CNODE_PORT}" "6000" "cnode port from the node's command line"
assert_eq "${CNODE_SOCKET}" "${CNODE_HOME_DIR}/sockets/node.socket" "cnode socket from the node's command line"

# --- prepare: peers and peer mix ---------------------------------------------
amaru_migrate_configure_peers >/dev/null
assert_env AMARU_PEER "10.0.0.5:6000,[2001:db8::7]:6000,relay2.example.com:3001,preview-node.play.dev.cardano.org:3001"
assert_env AMARU_PEERS_MIX "static!3@15m, inbound~6, shared~6, snapshot~3@1h, ledger~3@24h"
assert_env AMARU_PEERS_MAX_UPSTREAM "4"
compgen -G "${AMARU_HOME_DIR}/scripts/archive/amaru.env.*" >/dev/null || fail "amaru.env backup missing"

reset_case
printf '{"localRoots":[{"accessPoints":[{"address":"10.0.0.5","port":6000}]}]}\n' > "${TEMP_ROOT}/one.json"
CNODE_TOPOLOGY="${TEMP_ROOT}/one.json"
amaru_migrate_configure_peers >/dev/null
grep -q '^AMARU_PEERS_MIX=' "${AMARU_MIGRATE_ENV_FILE}" && fail "default peer mix should be kept for up to two peers"
assert_env AMARU_PEERS_MAX_UPSTREAM "3"

# --- switch ------------------------------------------------------------------
reset_case
amaru_migrate_read_cnode
amaru_migrate_cnode_slot() { printf '1000\n'; }
amaru_migrate_amaru_slot() { printf '500\n'; }
amaru_migrate_switch 2>/dev/null && fail "switch must refuse while Amaru lags behind"
[[ -s "${CALLS}" ]] && fail "a refused switch must not touch any service"

reset_case
amaru_migrate_read_cnode
AMARU_SLOTS="${TEMP_ROOT}/slots"
printf '990\n' > "${AMARU_SLOTS}"
amaru_migrate_amaru_slot() { local s; s="$(cat "${AMARU_SLOTS}")"; printf '%s\n' "$(( s + 1 ))" > "${AMARU_SLOTS}"; printf '%s\n' "${s}"; }
amaru_migrate_port_listening() { [[ "$1" == "6000" ]]; }
amaru_migrate_switch >/dev/null
assert_env AMARU_PEERS_LISTEN_ON "0.0.0.0:6000"
assert_eq "$(sed -n 1p "${CALLS}")" "systemctl disable --now cnode.service" "cnode is stopped first"
grep -qx 'amaru.sh restart' "${CALLS}" || fail "Amaru not restarted on cnode's port"
grep -q '^own_listen=0.0.0.0:3000$' "${AMARU_MIGRATE_STATE}" || fail "state should record Amaru's own port"

# rollback after a successful switch restores Amaru's own port and cnode
: > "${CALLS}"
amaru_migrate_rollback >/dev/null
assert_env AMARU_PEERS_LISTEN_ON "0.0.0.0:3000"
grep -qx 'systemctl enable --now cnode.service' "${CALLS}" || fail "rollback should start cnode"
grep -qx 'systemctl disable --now amaru.service amaru-metrics.service' "${CALLS}" || fail "rollback should stop Amaru"
[[ -e "${AMARU_MIGRATE_STATE}" ]] && fail "rollback should clear the switch state"

# a switch whose verification fails rolls back on its own
reset_case
amaru_migrate_read_cnode
amaru_migrate_amaru_slot() { printf '995\n'; }
amaru_migrate_switch >/dev/null 2>&1 && fail "switch must fail when Amaru does not follow the chain"
assert_env AMARU_PEERS_LISTEN_ON "0.0.0.0:3000"
grep -qx 'systemctl enable --now cnode.service' "${CALLS}" || fail "failed switch should start cnode again"

printf 'amaru migrate tests passed\n'
