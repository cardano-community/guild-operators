#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/guild-docker-deployment.XXXXXX")"

cleanup() {
  rm -rf -- "${TEST_DIR}"
}
trap cleanup EXIT

fail() {
  printf 'docker deployment test failed: %s\n' "$1" >&2
  exit 1
}

DOCKERFILE="${ROOT_DIR}/files/docker/node/dockerfile_bin"
ENTRYPOINT="${ROOT_DIR}/files/docker/node/addons/entrypoint.sh"
WORKFLOW="${ROOT_DIR}/.github/workflows/docker_bin.yml"

grep -q '^ARG NODE_IMPLEMENTATION=cnode$' "${DOCKERFILE}" ||
  fail "Dockerfile does not default to cnode"
grep -q '^ARG NODE_NETWORK=mainnet$' "${DOCKERFILE}" ||
  fail "Dockerfile does not default to mainnet"
if grep -q '^FROM --platform=\$BUILDPLATFORM' "${DOCKERFILE}"; then
  fail "Dockerfile forces target images to use the builder architecture"
fi
grep -q -- '-i "${IMAGE_NODE_IMPLEMENTATION}"' "${DOCKERFILE}" ||
  fail "Dockerfile does not pass the implementation to guild-deploy.sh"
grep -q -- '-n "${IMAGE_NODE_NETWORK}"' "${DOCKERFILE}" ||
  fail "Dockerfile does not pass the network to guild-deploy.sh"
grep -Fq 'locales apt-utils curl git wget' "${DOCKERFILE}" ||
  fail "Dockerfile does not install the Git snapshot prerequisite"
grep -Fq '&& "${IMAGE_NODE_HOME}/scripts/guild-deploy.sh" \' "${DOCKERFILE}" ||
  fail "Dockerfile does not reuse the dispatcher installed from the snapshot"
grep -Fq 'CNODE_SKIP_HARDWARE_WALLET_RULES=Y' "${DOCKERFILE}" ||
  fail "Dockerfile does not leave hardware-wallet udev rules to the host"
grep -Fq 'cnode) install_flags=dcmowx ;;' "${DOCKERFILE}" ||
  fail "Dockerfile no longer installs Cardano Hardware CLI for cnode"
if grep -Fq 'scripts/cnode-helper-scripts/guild-deploy.sh ${IMAGE_NODE_HOME}/scripts/' \
  "${DOCKERFILE}"; then
  fail "Dockerfile overwrites the snapshot-installed dispatcher with a raw file"
fi
[[ "$(grep -c 'raw.githubusercontent.com' "${DOCKERFILE}")" == "1" ]] ||
  fail "Dockerfile performs raw Guild downloads beyond the initial bootstrap"
grep -Fq 'source_revision="$(jq -er '\''.sourceRevision'\'' "${IMAGE_NODE_HOME}/.deployment.json")"' \
  "${DOCKERFILE}" ||
  fail "Dockerfile does not read the deployed source revision"
grep -Fq 'test "$(git -C /guild-container-source rev-parse HEAD)" = "${source_revision}"' \
  "${DOCKERFILE}" ||
  fail "Dockerfile does not bind container assets to the deployed revision"
grep -Fq '"${IMAGE_NODE_HOME}/files/config.json"' "${DOCKERFILE}" ||
  fail "Dockerfile does not cache the snapshot-deployed cnode configuration"
if grep -Fq 'api.github.com/repos/${G_ACCOUNT}/guild-operators/commits' \
  "${DOCKERFILE}"; then
  fail "Dockerfile still looks up a mutable branch revision after deployment"
fi
grep -Fq 'alias gLiveView=${IMAGE_NODE_HOME}/scripts/gLiveView.sh' "${DOCKERFILE}" ||
  fail "Dockerfile does not expose gLiveView for every implementation"
grep -Fq 'alias cntools=${IMAGE_NODE_HOME}/scripts/cntools.sh' "${DOCKERFILE}" ||
  fail "Dockerfile does not expose CNTools for every implementation"
if grep -Eq 'customise_cntools|ENABLE_(CHATTR|DIALOG)' "${ENTRYPOINT}"; then
  fail "container entrypoint still customizes removed legacy CNTools settings"
fi
grep -Fq '"${NODE_HOME}/scripts/amaru.sh" metrics &' "${ENTRYPOINT}" ||
  fail "container entrypoint does not start the Amaru metrics bridge"
grep -Fq 'wait -n -p completed_pid "${metrics_pid}" "${node_pid}"' "${ENTRYPOINT}" ||
  fail "container entrypoint does not supervise both Amaru processes"
grep -Fq 'http://127.0.0.1:12798/metrics' \
  "${ROOT_DIR}/files/docker/node/addons/healthcheck.sh" ||
  fail "container healthcheck does not verify Dingo metrics"
grep -Fq 'http://127.0.0.1:8889/metrics' \
  "${ROOT_DIR}/files/docker/node/addons/healthcheck.sh" ||
  fail "container healthcheck does not verify Amaru metrics"
for watched_path in \
  "scripts/common-helper-scripts/**" \
  "scripts/cnode-helper-scripts/**" \
  "scripts/dingo-helper-scripts/**" \
  "scripts/amaru-helper-scripts/**" \
  "files/node-implementations/**" \
  "files/configs/**" \
  "files/docker/node/**"; do
  grep -Fq -- "- '${watched_path}'" "${WORKFLOW}" ||
    fail "Docker workflow does not rebuild for ${watched_path}"
done

home_dir="${TEST_DIR}/home/guild"
node_home="${TEST_DIR}/opt/cardano/dingo"
fake_bin="${TEST_DIR}/bin"
launcher_log="${TEST_DIR}/launcher.log"
mkdir -p "${home_dir}/.scripts" "${node_home}/scripts" "${fake_bin}"
: > "${home_dir}/.bashrc"
printf 'Guild Operators test\n' > "${home_dir}/.scripts/banner.txt"

cat > "${node_home}/.deployment.json" <<'EOF'
{
  "schemaVersion": 1,
  "deploymentStatus": "deployed",
  "implementation": "dingo",
  "network": "preprod",
  "branch": "master",
  "repository": "cardano-community/guild-operators",
  "serviceName": "dingo",
  "nodeVersion": "dingo v0.67.1",
  "targetNodeVersion": "0.67.1",
  "metricsProvider": "prometheus",
  "capabilities": {
    "n2c": true,
    "localCli": true,
    "metrics": true,
    "forging": true
  }
}
EOF

cat > "${fake_bin}/dingo" <<'EOF'
#!/usr/bin/env bash
printf 'dingo test version\n'
EOF
cat > "${node_home}/scripts/dingo.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${LAUNCHER_LOG}"
EOF
chmod 0755 "${fake_bin}/dingo" "${node_home}/scripts/dingo.sh"

(
  unset CNODE_HOME NETWORK NODE_NETWORK NODE_IMPLEMENTATION NODE_HOME
  HOME="${home_dir}" \
  PATH="${fake_bin}:${PATH}" \
  IMAGE_NODE_IMPLEMENTATION="dingo" \
  IMAGE_NODE_NETWORK="preprod" \
  IMAGE_NODE_HOME="${node_home}" \
  UPDATE_CHECK="N" \
  LAUNCHER_LOG="${launcher_log}" \
    bash "${ENTRYPOINT}" bootstrap --verify
)
[[ "$(cat "${launcher_log}")" == "bootstrap --verify" ]] ||
  fail "Dingo container entrypoint did not dispatch to the selected launcher"

if (
  unset CNODE_HOME NODE_NETWORK NODE_IMPLEMENTATION NODE_HOME
  HOME="${home_dir}" \
  PATH="${fake_bin}:${PATH}" \
  IMAGE_NODE_IMPLEMENTATION="dingo" \
  IMAGE_NODE_NETWORK="preprod" \
  IMAGE_NODE_HOME="${node_home}" \
  NETWORK="preview" \
  UPDATE_CHECK="N" \
  LAUNCHER_LOG="${launcher_log}" \
    bash "${ENTRYPOINT}" >/dev/null 2>&1
); then
  fail "container entrypoint accepted a runtime network conflicting with its manifest"
fi

printf 'docker deployment tests passed\n'
