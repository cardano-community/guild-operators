#!/usr/bin/env bash
# Move a relay from a standard Guild cnode deployment to the Amaru deployment
# this script is installed in. Amaru runs next to cnode until it has caught up,
# then takes over cnode's port. cnode's folder and database are never changed,
# so rollback only swaps the services back. Other setups: follow the manual
# steps in docs/Build/amaru.md.
set -euo pipefail

AMARU_MIGRATE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
AMARU_MIGRATE_HOME="$(cd -- "${AMARU_MIGRATE_DIR}/.." && pwd -P)"
AMARU_MIGRATE_LAUNCHER="${AMARU_MIGRATE_LAUNCHER:-${AMARU_MIGRATE_DIR}/amaru.sh}"
AMARU_MIGRATE_ENV_FILE="${AMARU_MIGRATE_ENV_FILE:-${AMARU_MIGRATE_DIR}/amaru.env}"
AMARU_MIGRATE_STATE="${AMARU_MIGRATE_HOME}/files/.migrate-from-cnode"
: "${AMARU_MIGRATE_CNODE_HOME:=/opt/cardano/cnode}"
# cnode's own CLI, or the user's shared copy when cnode predates per-deployment binaries.
if [[ -x "${AMARU_MIGRATE_CNODE_HOME}/bin/cardano-cli" ]]; then
  : "${AMARU_MIGRATE_CLI:=${AMARU_MIGRATE_CNODE_HOME}/bin/cardano-cli}"
fi
: "${AMARU_MIGRATE_CLI:=${HOME}/.local/bin/cardano-cli}"
# Slots Amaru may trail cnode before a switch, and seconds to wait for it.
: "${AMARU_MIGRATE_MAX_LAG:=120}"
: "${AMARU_MIGRATE_SYNC_TIMEOUT:=7200}"
: "${AMARU_MIGRATE_VERIFY_TIMEOUT:=180}"
: "${AMARU_MIGRATE_POLL:=10}"
# Inbound connections Amaru accepts at least once it takes over cnode's public port.
: "${AMARU_MIGRATE_MIN_DOWNSTREAM:=50}"

amaru_migrate_usage() {
  cat <<EOF
Usage: $(basename "$0") [-c cnode_home] <prepare|switch|rollback|status>

Move a relay from a standard Guild cnode deployment (default ${AMARU_MIGRATE_CNODE_HOME})
to this Amaru deployment (${AMARU_MIGRATE_HOME}).

  prepare   Copy cnode's localRoots into amaru.env, bootstrap Amaru if needed and
            run it next to cnode on its own port until it reaches cnode's tip
  switch    Stop and disable cnode, move Amaru to cnode's port and verify it;
            rolls back automatically if Amaru does not come up
  rollback  Stop and disable Amaru, restore its own port and start cnode again
  status    Show both services, their ports and tips

Requires a running cnode relay deployed by guild-deploy.sh; block producers are
refused. For other setups follow the manual steps in the Amaru documentation.
EOF
}

amaru_migrate_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

amaru_migrate_info() {
  printf '%s\n' "$*"
}

amaru_migrate_load_libraries() {
  # shellcheck source=/dev/null
  . "${AMARU_MIGRATE_DIR}/lib/systemd.library"
}

amaru_migrate_load_amaru_env() {
  [[ -r "${AMARU_MIGRATE_ENV_FILE}" ]] ||
    amaru_migrate_fail "Amaru environment file is missing: ${AMARU_MIGRATE_ENV_FILE}" || return 1
  set -a
  # shellcheck source=/dev/null
  . "${AMARU_MIGRATE_ENV_FILE}"
  set +a
  : "${GUILD_NODE_SERVICE:=amaru}"
  : "${AMARU_PROMETHEUS_URL:=http://127.0.0.1:8889/metrics}"
}

# Description : Validate the cnode deployment and set CNODE_SERVICE and CNODE_NETWORK.
amaru_migrate_check_cnode_deployment() {
  local manifest="${AMARU_MIGRATE_CNODE_HOME}/.deployment.json"
  [[ -f "${manifest}" ]] ||
    amaru_migrate_fail "No Guild deployment manifest at ${manifest}; follow the manual migration steps instead" || return 1
  jq -e '.schemaVersion == 1 and .implementation == "cnode" and .deploymentStatus == "deployed"' \
    "${manifest}" >/dev/null 2>&1 ||
    amaru_migrate_fail "${AMARU_MIGRATE_CNODE_HOME} is not a finalized cnode deployment" || return 1
  CNODE_SERVICE="$(jq -er '.serviceName' "${manifest}")" || return 1
  CNODE_NETWORK="$(jq -er '.network' "${manifest}")" || return 1
  [[ "${CNODE_NETWORK}" == "${AMARU_NETWORK:-}" ]] ||
    amaru_migrate_fail "cnode runs ${CNODE_NETWORK}, this Amaru deployment ${AMARU_NETWORK:-unset}" || return 1
}

# Description : Print the PID of the cardano-node process run by the cnode service.
amaru_migrate_cnode_pid() {
  local main_pid child children=()
  main_pid="$("${SYSTEMCTL_BIN}" show -p MainPID --value "${CNODE_SERVICE}.service" 2>/dev/null)" || return 1
  [[ "${main_pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  if [[ "$(cat "/proc/${main_pid}/comm" 2>/dev/null)" == "cardano-node" ]]; then
    printf '%s\n' "${main_pid}"
    return 0
  fi
  read -r -a children 2>/dev/null < "/proc/${main_pid}/task/${main_pid}/children" || true
  for child in "${children[@]}"; do
    if [[ "$(cat "/proc/${child}/comm" 2>/dev/null)" == "cardano-node" ]]; then
      printf '%s\n' "${child}"
      return 0
    fi
  done
  return 1
}

# Description : Print the cardano-node arguments, one per line.
amaru_migrate_cnode_args() {
  local pid
  pid="$(amaru_migrate_cnode_pid)" ||
    amaru_migrate_fail "${CNODE_SERVICE}.service is not running cardano-node; start cnode first, or run rollback after a switch" || return 1
  tr '\0' '\n' < "/proc/${pid}/cmdline"
}

# Description : Read port, topology, socket and role from the running node; set CNODE_PORT,
#             : CNODE_TOPOLOGY and CNODE_SOCKET. Refuses block producers.
amaru_migrate_read_cnode() {
  local args
  args="$(amaru_migrate_cnode_args)" || return 1
  if grep -qx -- '--shelley-kes-key' <<< "${args}"; then
    amaru_migrate_fail "cnode runs as a block producer; this profile only moves relays" || return 1
  fi
  CNODE_PORT="$(grep -A1 -x -- '--port' <<< "${args}" | tail -n 1)"
  CNODE_TOPOLOGY="$(grep -A1 -x -- '--topology' <<< "${args}" | tail -n 1)"
  CNODE_SOCKET="$(grep -A1 -x -- '--socket-path' <<< "${args}" | tail -n 1)"
  [[ "${CNODE_PORT}" =~ ^[0-9]+$ && -f "${CNODE_TOPOLOGY}" && -n "${CNODE_SOCKET}" ]] ||
    amaru_migrate_fail "could not read --port, --topology and --socket-path from the running cardano-node" || return 1
}

# Description : Print cnode's localRoots as host:port, comma separated, IPv6 in brackets.
amaru_migrate_local_roots() {
  jq -r '[.localRoots[]?.accessPoints[]? |
           (if (.address | test(":")) then "[\(.address)]" else .address end) + ":" + (.port | tostring)]
         | unique | join(",")' "$1"
}

# Description : Print the union of two comma separated lists, first list first, without duplicates.
amaru_migrate_merge_peers() {
  printf '%s\n%s\n' "${1//,/$'\n'}" "${2//,/$'\n'}" | awk 'NF && !seen[$0]++' | paste -sd, -
}

# Description : Set KEY="value" in amaru.env: replace an active or commented line, else append.
amaru_migrate_set_env() {
  local key="$1" value="$2" file="${AMARU_MIGRATE_ENV_FILE}" escaped
  escaped="$(printf '%s' "${value}" | sed 's/[&|\\]/\\&/g')"
  if grep -qE "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=\"${escaped}\"|" "${file}"
  elif grep -qE "^#${key}=" "${file}"; then
    sed -i "0,/^#${key}=.*/s||${key}=\"${escaped}\"|" "${file}"
  else
    printf '%s="%s"\n' "${key}" "${value}" >> "${file}"
  fi
}

amaru_migrate_backup_env() {
  mkdir -p -- "${AMARU_MIGRATE_DIR}/archive"
  cp -p -- "${AMARU_MIGRATE_ENV_FILE}" \
    "${AMARU_MIGRATE_DIR}/archive/amaru.env.$(date -u +%Y%m%dT%H%M%SZ)"
}

# Description : Write cnode's localRoots into amaru.env next to the existing static peers. The static
#             : floor covers every static peer and one upstream slot stays free for a discovered peer,
#             : since static peers also take spare slots first. Raises the inbound limit for the public port.
amaru_migrate_configure_peers() {
  local local_roots peers count upstream downstream
  local_roots="$(amaru_migrate_local_roots "${CNODE_TOPOLOGY}")"
  [[ -n "${local_roots}" ]] ||
    amaru_migrate_fail "${CNODE_TOPOLOGY} has no localRoots to carry over" || return 1
  peers="$(amaru_migrate_merge_peers "${local_roots}" "${AMARU_PEER:-}")"
  count="$(tr ',' '\n' <<< "${peers}" | wc -l)"
  upstream="${AMARU_PEERS_MAX_UPSTREAM:-3}"
  (( upstream > count )) || upstream=$(( count + 1 ))
  downstream="${AMARU_PEERS_MAX_DOWNSTREAM:-10}"
  (( downstream >= AMARU_MIGRATE_MIN_DOWNSTREAM )) || downstream="${AMARU_MIGRATE_MIN_DOWNSTREAM}"
  amaru_migrate_backup_env
  amaru_migrate_set_env AMARU_PEER "${peers}"
  amaru_migrate_set_env AMARU_PEERS_MAX_UPSTREAM "${upstream}"
  amaru_migrate_set_env AMARU_PEERS_MAX_DOWNSTREAM "${downstream}"
  if (( count > 2 )); then
    amaru_migrate_set_env AMARU_PEERS_MIX "static!${count}@15m, inbound~6, shared~6, snapshot~3@1h, ledger~3@24h"
  fi
  amaru_migrate_info "Static peers (${count}, from ${CNODE_TOPOLOGY} and amaru.env): ${peers}"
  amaru_migrate_info "Upstream peers: ${upstream}, inbound connections: up to ${downstream}"
  amaru_migrate_load_amaru_env
}

amaru_migrate_magic() {
  case "${CNODE_NETWORK}" in
    preprod) printf '1\n' ;;
    preview) printf '2\n' ;;
    *) return 1 ;;
  esac
}

amaru_migrate_cnode_slot() {
  "${AMARU_MIGRATE_CLI}" query tip --testnet-magic "$(amaru_migrate_magic)" \
    --socket-path "${CNODE_SOCKET}" 2>/dev/null | jq -er '.slot'
}

amaru_migrate_amaru_slot() {
  curl -sf --max-time 5 "${AMARU_PROMETHEUS_URL}" 2>/dev/null |
    awk '$1 == "cardano_node_metrics_slotNum_int" { printf "%.0f\n", $2; found = 1 } END { exit !found }'
}

amaru_migrate_port_listening() {
  ss -Hltn "( sport = :$1 )" 2>/dev/null | grep -q .
}

amaru_migrate_listen_port() {
  printf '%s\n' "${AMARU_PEERS_LISTEN_ON##*:}"
}

amaru_migrate_service_active() {
  "${SYSTEMCTL_BIN}" is-active --quiet "$1.service"
}

# Amaru accepts empty state directories for bootstrap, so only content marks a bootstrapped database.
amaru_migrate_state_populated() {
  [[ -d "$1" ]] && [[ -n "$(ls -A "$1" 2>/dev/null)" ]]
}

amaru_migrate_prepare() {
  local own_port reference slot waited=0
  own_port="$(amaru_migrate_listen_port)"
  if [[ "${own_port}" == "${CNODE_PORT}" && -f "${AMARU_MIGRATE_STATE}" ]]; then
    amaru_migrate_fail "already switched: Amaru listens on cnode's port ${CNODE_PORT}; run status or rollback" || return 1
  elif [[ "${own_port}" == "${CNODE_PORT}" ]]; then
    amaru_migrate_fail "cnode uses port ${CNODE_PORT}, the port AMARU_PEERS_LISTEN_ON gives Amaru; set another port there to run both side by side" || return 1
  fi
  amaru_migrate_cnode_slot >/dev/null ||
    amaru_migrate_fail "cannot read cnode's tip with ${AMARU_MIGRATE_CLI} on ${CNODE_SOCKET}; set AMARU_MIGRATE_CLI to cnode's cardano-cli" || return 1
  amaru_migrate_configure_peers || return 1
  if amaru_migrate_state_populated "${AMARU_DB_CHAIN:-}" && amaru_migrate_state_populated "${AMARU_DB_LEDGER:-}"; then
    :
  elif amaru_migrate_state_populated "${AMARU_DB_CHAIN:-}" || amaru_migrate_state_populated "${AMARU_DB_LEDGER:-}"; then
    amaru_migrate_fail "Amaru's chain and ledger databases are only partly there, likely from an interrupted bootstrap; move or remove ${AMARU_DB_CHAIN} and ${AMARU_DB_LEDGER} and run prepare again" || return 1
  else
    "${AMARU_MIGRATE_LAUNCHER}" bootstrap || return 1
  fi
  [[ -f "${SYSTEMD_UNIT_DIR:-/etc/systemd/system}/${GUILD_NODE_SERVICE}.service" ]] ||
    "${AMARU_MIGRATE_LAUNCHER}" -d || return 1
  "${AMARU_MIGRATE_LAUNCHER}" restart || return 1
  amaru_migrate_info "Amaru runs next to cnode on port ${own_port}; waiting for it to reach cnode's tip.."
  while true; do
    reference="$(amaru_migrate_cnode_slot || true)"
    slot="$(amaru_migrate_amaru_slot || true)"
    if [[ -n "${reference}" && -n "${slot}" ]] && (( reference - slot <= AMARU_MIGRATE_MAX_LAG )); then
      amaru_migrate_info "Amaru is at slot ${slot}, cnode at ${reference}. Run '$(basename "$0") switch' to move over."
      return 0
    fi
    (( waited < AMARU_MIGRATE_SYNC_TIMEOUT )) ||
      amaru_migrate_fail "Amaru did not reach cnode's tip within ${AMARU_MIGRATE_SYNC_TIMEOUT}s (Amaru ${slot:-?}, cnode ${reference:-?}); run prepare again to keep waiting" || return 1
    amaru_migrate_info "  Amaru slot ${slot:-?}, cnode slot ${reference:-?}"
    sleep "${AMARU_MIGRATE_POLL}"
    waited=$(( waited + (AMARU_MIGRATE_POLL > 0 ? AMARU_MIGRATE_POLL : 1) ))
  done
}

amaru_migrate_rollback() {
  local own_port=""
  [[ -f "${AMARU_MIGRATE_STATE}" ]] && own_port="$(sed -n 's/^own_listen=//p' "${AMARU_MIGRATE_STATE}")"
  systemd_control disable --now "${GUILD_NODE_SERVICE}.service" "${GUILD_NODE_SERVICE}-metrics.service" || true
  # Start cnode even when amaru.env cannot be restored: getting the relay back comes first.
  if [[ -n "${own_port}" ]] && ! amaru_migrate_set_env AMARU_PEERS_LISTEN_ON "${own_port}"; then
    printf 'WARNING: could not restore AMARU_PEERS_LISTEN_ON="%s" in %s\n' "${own_port}" "${AMARU_MIGRATE_ENV_FILE}" >&2
  fi
  systemd_control enable --now "${CNODE_SERVICE}.service" || return 1
  rm -f -- "${AMARU_MIGRATE_STATE}"
  amaru_migrate_info "Rolled back: ${CNODE_SERVICE} runs again, Amaru is stopped and disabled."
}

amaru_migrate_switch() {
  local reference slot start_slot listen waited=0
  reference="$(amaru_migrate_cnode_slot)" ||
    amaru_migrate_fail "cannot read cnode's tip from ${CNODE_SOCKET}" || return 1
  slot="$(amaru_migrate_amaru_slot)" ||
    amaru_migrate_fail "Amaru is not running or exports no metrics; run prepare first" || return 1
  (( reference - slot <= AMARU_MIGRATE_MAX_LAG )) ||
    amaru_migrate_fail "Amaru is $(( reference - slot )) slots behind cnode; run prepare first" || return 1

  listen="${AMARU_PEERS_LISTEN_ON%:*}:${CNODE_PORT}"
  printf 'own_listen=%s\ncnode_service=%s\n' "${AMARU_PEERS_LISTEN_ON}" "${CNODE_SERVICE}" > "${AMARU_MIGRATE_STATE}"
  amaru_migrate_backup_env
  systemd_control disable --now "${CNODE_SERVICE}.service" || { amaru_migrate_rollback; return 1; }
  amaru_migrate_set_env AMARU_PEERS_LISTEN_ON "${listen}" || { amaru_migrate_rollback; return 1; }
  systemd_control enable "${GUILD_NODE_SERVICE}-metrics.service" "${GUILD_NODE_SERVICE}.service" || true
  "${AMARU_MIGRATE_LAUNCHER}" restart || { amaru_migrate_rollback; return 1; }

  # Amaru counts as switched once it listens on cnode's port and adopts new blocks.
  start_slot="${slot}"
  while (( waited < AMARU_MIGRATE_VERIFY_TIMEOUT )); do
    slot="$(amaru_migrate_amaru_slot || true)"
    if amaru_migrate_port_listening "${CNODE_PORT}" && [[ -n "${slot}" ]] && (( slot > start_slot )); then
      amaru_migrate_info "Switched: Amaru listens on ${listen} and follows the chain (slot ${slot})."
      amaru_migrate_info "Rollback: $(basename "$0") rollback"
      return 0
    fi
    sleep "${AMARU_MIGRATE_POLL}"
    waited=$(( waited + (AMARU_MIGRATE_POLL > 0 ? AMARU_MIGRATE_POLL : 1) ))
  done
  printf 'ERROR: Amaru did not come up on port %s within %ss; rolling back\n' \
    "${CNODE_PORT}" "${AMARU_MIGRATE_VERIFY_TIMEOUT}" >&2
  amaru_migrate_rollback
  return 1
}

amaru_migrate_status() {
  local cnode_state amaru_state
  cnode_state="$("${SYSTEMCTL_BIN}" is-active "${CNODE_SERVICE}.service" 2>/dev/null || true)"
  amaru_state="$("${SYSTEMCTL_BIN}" is-active "${GUILD_NODE_SERVICE}.service" 2>/dev/null || true)"
  printf 'cnode : %-10s %s\n' "${cnode_state}" "${CNODE_SERVICE}.service"
  printf 'Amaru : %-10s %s, listening on %s, slot %s\n' "${amaru_state}" \
    "${GUILD_NODE_SERVICE}.service" "${AMARU_PEERS_LISTEN_ON}" "$(amaru_migrate_amaru_slot || printf '?')"
}

amaru_migrate_main() {
  local command_name
  while getopts ":c:h" opt; do
    case "${opt}" in
      c) AMARU_MIGRATE_CNODE_HOME="${OPTARG%/}" ;;
      h) amaru_migrate_usage; return 0 ;;
      *) amaru_migrate_usage >&2; return 2 ;;
    esac
  done
  shift $(( OPTIND - 1 ))
  command_name="${1:-}"
  case "${command_name}" in
    prepare|switch|rollback|status) ;;
    -h|--help|help|"") amaru_migrate_usage; [[ -n "${command_name}" ]]; return ;;
    *) amaru_migrate_usage >&2; return 2 ;;
  esac
  amaru_migrate_load_libraries
  amaru_migrate_load_amaru_env || return 1
  amaru_migrate_check_cnode_deployment || return 1
  case "${command_name}" in
    prepare) amaru_migrate_read_cnode && amaru_migrate_prepare ;;
    switch) amaru_migrate_read_cnode && amaru_migrate_switch ;;
    rollback) amaru_migrate_rollback ;;
    status) amaru_migrate_status ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  amaru_migrate_main "$@"
fi
