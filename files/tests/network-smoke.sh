#!/usr/bin/env bash
# Deploy a pre-release network from a branch the way an operator would, check its
# CLI with CNTools' checks, and make sure a real node follows the chain.
#
#   files/tests/network-smoke.sh <dijkstra|musashi> <branch>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
NETWORK="${1:?network}"
BRANCH="${2:?branch}"
ACCOUNT="${GUILD_SMOKE_ACCOUNT:-${GITHUB_REPOSITORY_OWNER:-cardano-community}}"
TARGET="${GUILD_SMOKE_TARGET:-pinsmoke}"
PARENT="${GUILD_SMOKE_PARENT:-/opt/cardano}"
DEADLINE="${GUILD_SMOKE_SECONDS:-300}"
NODE_ROOT="${PARENT}/${TARGET}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

bash "${ROOT_DIR}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  -g "${ACCOUNT}" -n "${NETWORK}" -t "${TARGET}" -p "${PARENT}" -b "${BRANCH}" -s pd </dev/null

[[ -x "${NODE_ROOT}/bin/cardano-node" ]] || fail "the deploy did not install cardano-node in ${NODE_ROOT}/bin"
bash "${ROOT_DIR}/scripts/compatibility/cntools/cntools-check.sh" \
  --suite cli --cli "${NODE_ROOT}/bin/cardano-cli" --network "${NETWORK}"

metrics_port="$(grep -oE 'PrometheusSimple suffix 127\.0\.0\.1 [0-9]+' "${NODE_ROOT}/files/config.json" | awk '{print $NF}')"
[[ -n "${metrics_port}" ]] || fail "no Prometheus port in the deployed config"

log="$(mktemp "${TMPDIR:-/tmp}/guild-network-smoke.XXXXXX")"
"${NODE_ROOT}/scripts/cnode.sh" >"${log}" 2>&1 &
node_pid=$!
trap 'kill "${node_pid}" 2>/dev/null || true; rm -f -- "${log}"' EXIT

first=""
block=""
end=$(( SECONDS + DEADLINE ))
while (( SECONDS < end )); do
  kill -0 "${node_pid}" 2>/dev/null || { tail -n 20 "${log}" >&2; fail "the node stopped"; }
  # The metrics port isn't open until the node has started.
  block="$(curl -s -m 5 "http://127.0.0.1:${metrics_port}/metrics" |
    awk '/^cardano_node_metrics_blockNum_int /{print $2}' || true)"
  if [[ -n "${block}" ]]; then
    [[ -n "${first}" ]] || first="${block}"
    if (( block > first )); then
      printf 'network-smoke: PASS, %s followed the chain from block %s to %s\n' "${NETWORK}" "${first}" "${block}"
      exit 0
    fi
  fi
  sleep 10
done
tail -n 20 "${log}" >&2
fail "${NETWORK} gained no blocks in ${DEADLINE} seconds (first ${first:-none}, last ${block:-none})"
