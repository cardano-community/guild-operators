#!/usr/bin/env bash
set -euo pipefail

head -n 8 "${HOME}/.scripts/banner.txt"

# shellcheck disable=SC1090
. "${HOME}/.bashrc" >/dev/null 2>&1

IMAGE_NODE_IMPLEMENTATION="${IMAGE_NODE_IMPLEMENTATION:-cnode}"
IMAGE_NODE_NETWORK="${IMAGE_NODE_NETWORK:-mainnet}"
IMAGE_NODE_HOME="${IMAGE_NODE_HOME:-/opt/cardano/${IMAGE_NODE_IMPLEMENTATION}}"
DEPLOYMENT_FILE="${IMAGE_NODE_HOME}/.deployment.json"

case "${IMAGE_NODE_IMPLEMENTATION}:${IMAGE_NODE_NETWORK}" in
  cnode:mainnet|cnode:guild|cnode:preprod|cnode:preview|dingo:preprod|dingo:preview|amaru:preprod|amaru:preview) ;;
  *)
    printf 'ERROR: unsupported image identity %s:%s\n' \
      "${IMAGE_NODE_IMPLEMENTATION}" "${IMAGE_NODE_NETWORK}" >&2
    exit 1
    ;;
esac

[[ -f "${DEPLOYMENT_FILE}" && ! -L "${DEPLOYMENT_FILE}" ]] || {
  printf 'ERROR: deployment manifest is missing or unsafe: %s\n' "${DEPLOYMENT_FILE}" >&2
  exit 1
}

manifest_implementation="$(jq -er '.implementation' "${DEPLOYMENT_FILE}")"
manifest_network="$(jq -er '.network' "${DEPLOYMENT_FILE}")"
manifest_status="$(jq -er '.deploymentStatus' "${DEPLOYMENT_FILE}")"
[[ "${manifest_status}" == "deployed" ]] || {
  printf 'ERROR: deployment manifest is not finalized: %s\n' "${DEPLOYMENT_FILE}" >&2
  exit 1
}
[[ "${manifest_implementation}" == "${IMAGE_NODE_IMPLEMENTATION}" &&
   "${manifest_network}" == "${IMAGE_NODE_NETWORK}" ]] || {
  printf 'ERROR: image identity %s:%s conflicts with deployment manifest %s:%s\n' \
    "${IMAGE_NODE_IMPLEMENTATION}" "${IMAGE_NODE_NETWORK}" \
    "${manifest_implementation}" "${manifest_network}" >&2
  exit 1
}

runtime_implementation="${NODE_IMPLEMENTATION:-${IMAGE_NODE_IMPLEMENTATION}}"
runtime_network="${NETWORK:-${NODE_NETWORK:-${IMAGE_NODE_NETWORK}}}"
runtime_home="${NODE_HOME:-${IMAGE_NODE_HOME}}"
[[ "${runtime_implementation}" == "${manifest_implementation}" ]] || {
  printf 'ERROR: NODE_IMPLEMENTATION=%s conflicts with image deployment %s\n' \
    "${runtime_implementation}" "${manifest_implementation}" >&2
  exit 1
}
[[ "${runtime_network}" == "${manifest_network}" ]] || {
  printf 'ERROR: NETWORK=%s conflicts with image deployment network %s; rebuild with --build-arg NODE_NETWORK=%s\n' \
    "${runtime_network}" "${manifest_network}" "${runtime_network}" >&2
  exit 1
}
[[ "${runtime_home}" == "${IMAGE_NODE_HOME}" ]] || {
  printf 'ERROR: NODE_HOME=%s conflicts with image deployment root %s\n' \
    "${runtime_home}" "${IMAGE_NODE_HOME}" >&2
  exit 1
}

export NODE_IMPLEMENTATION="${manifest_implementation}"
export NODE_NETWORK="${manifest_network}"
export NETWORK="${manifest_network}"
export NODE_HOME="${IMAGE_NODE_HOME}"
export CNODE_HOME="${IMAGE_NODE_HOME}"

case "${UPDATE_CHECK:-N}" in
  N) ;;
  Y)
    printf '%s\n' \
      'ERROR: UPDATE_CHECK=Y is not supported in immutable Guild images; rebuild from a pinned revision and recreate the container.' >&2
    exit 1
    ;;
  *)
    printf 'ERROR: UPDATE_CHECK must be N for Guild images, got: %s\n' \
      "${UPDATE_CHECK:-}" >&2
    exit 1
    ;;
esac

ENTRYPOINT_PROCESS="${ENTRYPOINT_PROCESS:-${NODE_IMPLEMENTATION}.sh}"
case "${ENTRYPOINT_PROCESS}" in
  /*)
    entrypoint_path="${ENTRYPOINT_PROCESS}"
    ;;
  *[!A-Za-z0-9_.-]*|'')
    printf 'ERROR: invalid ENTRYPOINT_PROCESS: %s\n' "${ENTRYPOINT_PROCESS}" >&2
    exit 1
    ;;
  *)
    entrypoint_path="${NODE_HOME}/scripts/${ENTRYPOINT_PROCESS}"
    ;;
esac
[[ -x "${entrypoint_path}" ]] || {
  printf 'ERROR: entrypoint process is missing or not executable: %s\n' "${entrypoint_path}" >&2
  exit 1
}

printf 'IMPLEMENTATION: %s\n' "${NODE_IMPLEMENTATION}"
printf 'NETWORK: %s\n' "${NETWORK}"
printf 'ENTRYPOINT_PROCESS: %s\n' "${ENTRYPOINT_PROCESS}"

case "${NODE_IMPLEMENTATION}" in
  cnode)
    CNODE_PORT="${CNODE_PORT:-6000}"
    export CNODE_PORT
    printf 'NODE: %s - Port:%s - %s\n' \
      "${HOSTNAME}" "${CNODE_PORT}" "${POOL_NAME:-relay}"
    cardano-node --version
    ;;
  dingo)
    dingo version
    ;;
  amaru)
    amaru --version
    ;;
esac

cnode_backup_or_restore() {
  [[ "${ENABLE_BACKUP:-N}" == "Y" || "${ENABLE_RESTORE:-N}" == "Y" ]] || return 0

  local backup_dir dbsize bksizedb
  backup_dir="${CNODE_HOME}/backup/${NETWORK}-db"
  mkdir -p "${backup_dir}"
  dbsize="$(du -s "${CNODE_HOME}/db" 2>/dev/null | awk '{print $1}')"
  bksizedb="$(du -s "${backup_dir}" 2>/dev/null | awk '{print $1}')"
  dbsize="${dbsize:-0}"
  bksizedb="${bksizedb:-0}"

  if [[ "${ENABLE_RESTORE:-N}" == "Y" && "${dbsize}" -lt "${bksizedb}" ]]; then
    echo "Restore started"
    cp -rf "${backup_dir}/." "${CNODE_HOME}/db/"
    echo "Restore finished"
  fi

  if [[ "${ENABLE_BACKUP:-N}" == "Y" && "${dbsize}" -gt "${bksizedb}" ]]; then
    echo "Backup started"
    cp -rf "${CNODE_HOME}/db/." "${backup_dir}/"
    echo "Backup finished"
  fi
}

cnode_prepare_runtime_configs() {
  local config_root="${GUILD_DOCKER_CONFIG_ROOT:-/conf}"
  local config_source="${config_root}/${NETWORK}"
  local runtime_root="${GUILD_RUNTIME_ROOT:-${HOME}/.cache/guild-operators/runtime}"
  local runtime_parent="${runtime_root}/cnode"
  local runtime_config_dir="${runtime_parent}/${NETWORK}"
  local config_file=""

  [[ -d "${config_source}" && ! -L "${config_source}" ]] || {
    printf 'ERROR: cnode configuration cache is missing: %s\n' "${config_source}" >&2
    return 1
  }

  for config_file in alonzo-genesis.json byron-genesis.json \
    conway-genesis.json shelley-genesis.json config.json db-sync-config.json \
    topology.json; do
    [[ -f "${config_source}/${config_file}" &&
       ! -L "${config_source}/${config_file}" ]] || {
      printf 'ERROR: cnode configuration cache file is missing or unsafe: %s\n' \
        "${config_source}/${config_file}" >&2
      return 1
    }
  done

  # Node startup may add genesis hashes and needs a container-wide metrics
  # bind. Apply those changes only to a disposable runtime overlay so the host
  # payload and Docker supplement receipts keep describing the image bytes.
  mkdir -p "${runtime_parent}"
  rm -rf -- "${runtime_config_dir}"
  mkdir -p "${runtime_config_dir}"
  cp -a "${config_source}/." "${runtime_config_dir}/"
  while IFS= read -r -d '' config_file; do
    sed 's/127.0.0.1/0.0.0.0/g' "${config_file}" > "${config_file}.tmp"
    chmod 0644 "${config_file}.tmp"
    mv -f "${config_file}.tmp" "${config_file}"
  done < <(find "${runtime_config_dir}" -type f -name '*config*.json' -print0)
  export CONFIG="${runtime_config_dir}/config.json"
  export TOPOLOGY="${runtime_config_dir}/topology.json"
}

if [[ "${NODE_IMPLEMENTATION}" == "cnode" ]]; then
  cnode_backup_or_restore
  cnode_prepare_runtime_configs
fi

if [[ "${NODE_IMPLEMENTATION}" == "amaru" &&
      "$(basename -- "${entrypoint_path}")" == "amaru.sh" &&
      ( $# -eq 0 || "${1:-}" == "run" ) ]]; then
  metrics_pid=""
  node_pid=""
  forward_amaru_signal() {
    local signal_name="$1"
    [[ -n "${node_pid}" ]] && kill "-${signal_name}" "${node_pid}" 2>/dev/null || true
    [[ -n "${metrics_pid}" ]] && kill "-${signal_name}" "${metrics_pid}" 2>/dev/null || true
  }
  trap 'forward_amaru_signal INT' INT
  trap 'forward_amaru_signal TERM' TERM
  trap 'forward_amaru_signal HUP' HUP

  "${NODE_HOME}/scripts/amaru.sh" metrics &
  metrics_pid=$!
  "${entrypoint_path}" "$@" &
  node_pid=$!

  child_status=0
  completed_pid=""
  wait -n -p completed_pid "${metrics_pid}" "${node_pid}" || child_status=$?
  if [[ "${completed_pid}" == "${metrics_pid}" &&
        "${child_status}" -eq 0 ]] &&
     kill -0 "${node_pid}" 2>/dev/null; then
    # A collector that stops while the node is still live is a failed
    # monitoring contract, even if the collector returned a clean status.
    child_status=1
  fi
  kill -TERM "${node_pid}" "${metrics_pid}" 2>/dev/null || true
  wait "${node_pid}" "${metrics_pid}" 2>/dev/null || true
  exit "${child_status}"
fi

exec "${entrypoint_path}" "$@"
