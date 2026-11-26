#!/usr/bin/env bash
# Does a node implementation's current release work with Guild's scripts? Deploy
# it the way an operator would, start it, and read a rising slot through the same
# adapter gLiveView uses.
#
#   files/tests/latest-release-check.sh <dingo|amaru> <branch>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
IMPLEMENTATION="${1:?implementation}"
BRANCH="${2:?branch}"
ACCOUNT="${GUILD_SMOKE_ACCOUNT:-${GITHUB_REPOSITORY_OWNER:-cardano-community}}"
TARGET="${GUILD_SMOKE_TARGET:-releasecheck}"
PARENT="${GUILD_SMOKE_PARENT:-/opt/cardano}"
DEADLINE="${GUILD_SMOKE_SECONDS:-420}"
NODE_ROOT="${PARENT}/${TARGET}"
LAUNCHER="${NODE_ROOT}/scripts/${IMPLEMENTATION}.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

case "${IMPLEMENTATION}" in
  dingo|amaru) ;;
  *) fail "usage: latest-release-check.sh <dingo|amaru> <branch>" ;;
esac

bash "${ROOT_DIR}/scripts/cnode-helper-scripts/guild-deploy.sh" \
  -g "${ACCOUNT}" -i "${IMPLEMENTATION}" -n preview -t "${TARGET}" -p "${PARENT}" \
  -b "${BRANCH}" -s pd </dev/null
[[ -x "${NODE_ROOT}/bin/${IMPLEMENTATION}" ]] ||
  fail "the deploy did not install ${IMPLEMENTATION} in ${NODE_ROOT}/bin"
[[ -x "${NODE_ROOT}/bin/cardano-cli" ]] ||
  fail "the deploy did not install cardano-cli in ${NODE_ROOT}/bin"

log="$(mktemp "${TMPDIR:-/tmp}/guild-release-check.XXXXXX")"
pids=()
stop_all() {
  local pid
  for pid in "${pids[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  rm -f -- "${log}"
}
trap stop_all EXIT

if [[ "${IMPLEMENTATION}" == "amaru" ]]; then
  "${LAUNCHER}" bootstrap >"${log}" 2>&1 || { tail -n 20 "${log}" >&2; fail "bootstrap failed"; }
  "${LAUNCHER}" metrics >>"${log}" 2>&1 &
  pids+=("$!")
fi
"${LAUNCHER}" run >>"${log}" 2>&1 &
node_pid=$!
pids+=("${node_pid}")

read_slot() {
  (
    cd "${NODE_ROOT}/scripts" || exit 1
    set +eu
    # shellcheck source=/dev/null
    . ./env monitor >/dev/null 2>&1 || exit 1
    node_adapter_collect_metrics >/dev/null 2>&1 || exit 1
    node_metric_has slotnum || exit 1
    # shellcheck disable=SC2154  # set by the adapter
    printf '%s' "${slotnum}"
  )
}

first=""
slot=""
end=$(( SECONDS + DEADLINE ))
while (( SECONDS < end )); do
  kill -0 "${node_pid}" 2>/dev/null || { tail -n 20 "${log}" >&2; fail "${IMPLEMENTATION} stopped"; }
  slot="$(read_slot 2>/dev/null || true)"
  if [[ "${slot}" =~ ^[0-9]+$ ]] && (( slot > 0 )); then
    [[ -n "${first}" ]] || first="${slot}"
    if (( slot > first )); then
      printf 'latest-release-check: PASS, %s followed the chain from slot %s to %s\n' \
        "${IMPLEMENTATION}" "${first}" "${slot}"
      exit 0
    fi
  fi
  sleep 15
done
tail -n 20 "${log}" >&2
fail "${IMPLEMENTATION} showed no progress in ${DEADLINE} seconds (first slot ${first:-none}, last ${slot:-none})"
