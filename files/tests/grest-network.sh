#!/usr/bin/env bash
# gRest fails over only to a public Koios instance on the same network, and a
# network without one gets a valid haproxy config with no failover server.
# shellcheck disable=SC2034  # read by the functions under test
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guild-grest-network.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
SCRIPT="${ROOT_DIR}/scripts/grest-helper-scripts/setup-grest.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Load only the functions under test. Running the script would start the setup.
eval "$(sed -n '/^  set_environment_variables() {/,/^  }/p; /^  deploy_configs() {/,/^  }/p' "${SCRIPT}")"
declare -F set_environment_variables >/dev/null || fail "set_environment_variables not found"
declare -F deploy_configs >/dev/null || fail "deploy_configs not found"

# The real script needs root for ownership changes that don't matter here.
sudo() {
  case "$1" in
    chown) return 0 ;;
    *) "$@" ;;
  esac
}

G_ACCOUNT="cardano-community"
SGVERSION="test"
USER="$(id -un)"

# setup-grest.sh builds a current haproxy, and the config uses 3.x settings, so an
# older distribution package can't check it.
HAPROXY_CHECK="N"
if command -v haproxy >/dev/null 2>&1 &&
   [[ "$(haproxy -v 2>/dev/null | head -n 1)" =~ version\ ([0-9]+)\. ]] &&
   (( BASH_REMATCH[1] >= 3 )); then
  HAPROXY_CHECK="Y"
fi

check_network() { # $1 = magic, $2 = expected failover host, or "none"
  local magic="$1" expected="$2"
  (
    # The setup script relies on unset variables meaning "use the default".
    set +u
    NWMAGIC="${magic}"
    CNODE_HOME="${TEST_ROOT}/${magic}"
    mkdir -p "${CNODE_HOME}/priv" "${CNODE_HOME}/files" "${CNODE_HOME}/sockets"
    : > "${CNODE_HOME}/files/grestrpcs"
    unset HAPROXY_CFG PGDATABASE CRON_SCRIPTS_DIR CRON_DIR DB_SCRIPTS_URL PGPASSFILE
    set_environment_variables
    deploy_configs >/dev/null
    config="${HAPROXY_CFG}"
    failover="$(sed -n '/^backend grest_failover/,/^$/p' "${config}")"
    if [[ "${expected}" == "none" ]]; then
      [[ -z "${KOIOS_SRV}" ]] || fail "magic ${magic} fails over to ${KOIOS_SRV}"
      grep -qE '^[[:space:]]+server ' <<< "${failover}" &&
        fail "magic ${magic} has a failover server: ${failover}"
      grep -q 'nothing to fail over to' <<< "${failover}" || fail "magic ${magic} does not say why"
    else
      [[ "${KOIOS_SRV}" == "${expected}" ]] || fail "magic ${magic} fails over to '${KOIOS_SRV}', expected ${expected}"
      grep -qF "server koios-ssl ${expected}:443 ssl verify none" <<< "${failover}" ||
        fail "magic ${magic} has no failover server for ${expected}: ${failover}"
      grep -qF "X-HAProxy-Hostname \"${expected}\"" <<< "${failover}" ||
        fail "magic ${magic} does not set the failover host header"
    fi
    # The API definition is the same everywhere, so every network has a source for it.
    [[ "${KOIOS_SPEC_SRV}" == "${KOIOS_SRV:-api.koios.rest}" ]] || fail "magic ${magic} has spec source ${KOIOS_SPEC_SRV}"
    if [[ "${HAPROXY_CHECK}" == "Y" ]]; then
      GRESTTOP="${CNODE_HOME}" HAPROXY_SOCKET_USER="${USER}" haproxy -c -q -f "${config}" ||
        fail "haproxy rejects the config for magic ${magic}"
    fi
  ) || exit 1
}

check_network 764824073 api.koios.rest
check_network 1 preprod.koios.rest
check_network 2 preview.koios.rest
check_network 141 guild.koios.rest
check_network 6 none
check_network 164 none

if [[ "${HAPROXY_CHECK}" == "Y" ]]; then
  printf 'grest-network: PASS, haproxy %s accepted every config\n' "$(haproxy -v | head -n 1 | awk '{print $3}')"
else
  printf 'grest-network: PASS, no haproxy 3.x installed, so its own check was skipped\n'
fi
