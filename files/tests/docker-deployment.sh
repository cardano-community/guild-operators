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

extract_docker_receipt_files() {
  local receipt="$1"
  local output="$2"

  jq -er '
    def valid_file:
      type == "object" and
      keys == ["exportedSha256", "mode", "path", "source", "sourceSha256"] and
      (.source | type == "string" and test("^(scripts|files)/")) and
      (.path | type == "string" and
        test("^/[A-Za-z0-9._/+@:-]+$") and
        (contains("//") | not) and
        ((contains("\t") or contains("\r") or contains("\n")) | not) and
        (split("/") | all(. != "." and . != ".."))) and
      (.mode == "0644" or .mode == "0755") and
      (.sourceSha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.exportedSha256 == .sourceSha256);
    if ((.files | type == "array" and length > 0) and
        all(.files[]; valid_file) and
        ((.files | map(.path) | length) ==
         (.files | map(.path) | unique | length)))
    then .files[] | [.path, .mode, .exportedSha256] | @tsv
    else error("invalid or empty Docker supplement file inventory")
    end
  ' "${receipt}" > "${output}"
  [[ -s "${output}" ]]
}

validate_docker_receipt_jq_continuations() {
  local dockerfile="$1"

  awk '
    /^[[:space:]]*&& jq -er / {
      found++
      in_filter = 1
    }
    in_filter && $0 !~ /\\[[:space:]]*$/ {
      invalid = 1
      exit
    }
    in_filter && /docker-source-receipt[.]json > .*receipt_files/ {
      in_filter = 0
      complete = 1
    }
    END {
      if (found != 1 || invalid || in_filter || !complete) {
        exit 1
      }
    }
  ' "${dockerfile}"
}

DOCKERFILE="${ROOT_DIR}/files/docker/node/dockerfile_bin"
ENTRYPOINT="${ROOT_DIR}/files/docker/node/addons/entrypoint.sh"
WORKFLOW="${ROOT_DIR}/.github/workflows/docker_bin.yml"
PREMERGE_WORKFLOW="${ROOT_DIR}/.github/workflows/premerge.yml"
LINT_WORKFLOW="${ROOT_DIR}/.github/workflows/lint.yml"
DOCKER_SOURCE_MANIFEST="${ROOT_DIR}/files/docker/node/source-manifest.tsv"
HOST_SOURCE_MANIFEST="${ROOT_DIR}/files/node-implementations/source-manifest.tsv"

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
grep -Fq 'COPY scripts/cnode-helper-scripts/guild-deploy.sh /guild-deploy.sh' \
  "${DOCKERFILE}" ||
  fail "Dockerfile does not use a build-context bootstrap seed"
[[ "$(grep -Ec '^[[:space:]]*&& /guild-deploy[.]sh \\' "${DOCKERFILE}")" == "1" ]] ||
  fail "Dockerfile does not invoke guild-deploy.sh exactly once"
grep -q 'ca-certificates git' "${DOCKERFILE}" ||
  fail "Dockerfile does not install Git before the bootstrap dispatcher"
grep -Fq 'GUILD_SOURCE_CACHE_ROOT=/var/cache/guild-operators' "${DOCKERFILE}" ||
  fail "Dockerfile does not use a root-owned cache while deploying"
grep -q '^ARG GUILD_DEPLOY_REVISION=$' "${DOCKERFILE}" ||
  fail "Dockerfile does not accept an exact workflow source revision"
grep -Fq "grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$'" "${DOCKERFILE}" ||
  fail "Dockerfile does not require a non-empty full source revision"
grep -Fq '[ "${source_revision}" = "${GUILD_DEPLOY_REVISION}" ]' \
  "${DOCKERFILE}" ||
  fail "Dockerfile does not enforce the exact deployed revision"
grep -Fq 'GUILD_SOURCE_EXPECT_REVISION="${GUILD_DEPLOY_REVISION}"' \
  "${DOCKERFILE}" ||
  fail "Dockerfile does not pin source preparation to the workflow revision"
grep -Fq -- '-E "${docker_export}"' "${DOCKERFILE}" ||
  fail "Dockerfile does not request the separately receipted Docker supplement"
grep -Fq 'cp -a "${docker_export}/rootfs/." /' "${DOCKERFILE}" ||
  fail "Dockerfile does not populate image assets from the snapshot supplement"
grep -Fq '/usr/share/guild-operators/docker-source-receipt.json' \
  "${DOCKERFILE}" ||
  fail "Dockerfile does not retain separate Docker provenance"
grep -Fq '.hostPayloadReceiptSha256 == $host_hash' "${DOCKERFILE}" ||
  fail "Dockerfile does not bind Docker provenance to the host payload receipt"
grep -Fq '.files[] | [.path, .mode, .exportedSha256] | @tsv' \
  "${DOCKERFILE}" ||
  fail "Dockerfile does not verify every final supplement file"
grep -Fq 'invalid or empty Docker supplement file inventory' "${DOCKERFILE}" ||
  fail "Dockerfile does not reject invalid or empty receipt inventories"
validate_docker_receipt_jq_continuations "${DOCKERFILE}" ||
  fail "Dockerfile receipt jq filter escapes from its RUN instruction"
broken_continuation_fixture="${TEST_DIR}/dockerfile-broken-jq-continuation"
awk '
  !changed && /def valid_file:/ {
    sub(/[[:space:]]*\\[[:space:]]*$/, "")
    changed = 1
  }
  { print }
  END {
    if (!changed) {
      exit 1
    }
  }
' "${DOCKERFILE}" > "${broken_continuation_fixture}" ||
  fail "could not create the broken Dockerfile continuation fixture"
if validate_docker_receipt_jq_continuations "${broken_continuation_fixture}"; then
  fail "Dockerfile receipt jq continuation check accepts a split RUN instruction"
fi
grep -Fq 'done < "${receipt_files}"' "${DOCKERFILE}" ||
  fail "Dockerfile does not verify receipt files without a masking pipeline"
if grep -Fq '| while' "${DOCKERFILE}"; then
  fail "Dockerfile receipt verification still uses a status-masking pipeline"
fi
docker_verifier="${receipt_dir:-${TEST_DIR}/receipts}/verify-docker-files.sh"
mkdir -p "$(dirname -- "${docker_verifier}")"
{
  printf '%s\n' '#!/bin/sh' 'set -eu' 'receipt_files=$1'
  sed -n \
    '/^[[:space:]]*&& while IFS=.*read -r final_path/,/done < "${receipt_files}"/p' \
    "${DOCKERFILE}" |
    sed -e '1s/^[[:space:]]*&& //' -e 's/[[:space:]]*\\$//'
} > "${docker_verifier}"
grep -Fq '] || exit 1;' "${docker_verifier}" ||
  fail "Dockerfile receipt verifier does not fail explicitly per record"
grep -Fq "source_revision=\"\$(jq -er '.sourceRevision'" "${DOCKERFILE}" ||
  fail "Dockerfile does not derive its image revision from deployment metadata"
grep -Fq "printf '%s\\n' \"\${source_revision}\" > \"\${USER_HOME}/guild-latest.txt\"" \
  "${DOCKERFILE}" ||
  fail "Dockerfile does not publish the retained source revision"
if grep -Eq 'raw[.]githubusercontent[.]com|api[.]github[.]com|^ADD[[:space:]]+https?://' \
  "${DOCKERFILE}"; then
  fail "Dockerfile still fans Guild payloads out through raw/API downloads"
fi
grep -Fq 'full_sha: ${{ steps.set_short_sha.outputs.full_sha }}' "${WORKFLOW}" ||
  fail "Docker workflow does not retain the full resolved source revision"
[[ "$(grep -Fc 'GUILD_DEPLOY_REVISION=${{ needs.set_environment_vars.outputs.full_sha }}' "${WORKFLOW}")" == "2" ]] ||
  fail "Docker workflow does not pin both image builds to the resolved revision"
for compatibility_test in guild-deploy-dispatcher.sh common-runtime.sh; do
  [[ "$(grep -Fc "files/tests/${compatibility_test}" "${PREMERGE_WORKFLOW}")" -ge 2 ]] ||
    fail "Bash compatibility matrix omits ${compatibility_test}"
done
for docker_shell_file in entrypoint.sh healthcheck.sh block_watcher.sh; do
  grep -Fq "files/docker/node/addons/${docker_shell_file}" "${PREMERGE_WORKFLOW}" ||
    fail "pre-merge shellcheck omits ${docker_shell_file}"
  grep -Fq "files/docker/node/addons/${docker_shell_file}" "${LINT_WORKFLOW}" ||
    fail "lint workflow shellcheck omits ${docker_shell_file}"
done
smoke_job="$(sed -n '/^  docker-node-smoke:/,/^  guild-deploy-and-build:/p' \
  "${PREMERGE_WORKFLOW}")"
grep -Fq 'docker build .' <<< "${smoke_job}" ||
  fail "pre-merge workflow does not smoke-build the node Dockerfile"
grep -Fq 'GUILD_DEPLOY_REVISION=${SOURCE_REVISION}' <<< "${smoke_job}" ||
  fail "pre-merge Docker smoke build is not pinned to the PR revision"
if grep -Eq 'docker push|push:[[:space:]]*true' <<< "${smoke_job}"; then
  fail "pre-merge Docker smoke build can publish an image"
fi

[[ -s "${DOCKER_SOURCE_MANIFEST}" && ! -L "${DOCKER_SOURCE_MANIFEST}" ]] ||
  fail "Docker supplement source manifest is missing or unsafe"
IFS= read -r docker_manifest_header < "${DOCKER_SOURCE_MANIFEST}"
[[ "${docker_manifest_header}" == '# Guild Operators Docker supplement source manifest, schema 1.' ]] ||
  fail "Docker supplement source manifest has an unsupported schema"
docker_manifest_records="$(awk -F '\t' '!/^#/ && NF { count++ } END { print count + 0 }' "${DOCKER_SOURCE_MANIFEST}")"
[[ "${docker_manifest_records}" == "32" ]] ||
  fail "Docker supplement inventory must contain exactly 32 records"
for common_asset in banner.txt healthcheck.sh entrypoint.sh; do
  grep -Fq "files/docker/node/addons/${common_asset}" "${DOCKER_SOURCE_MANIFEST}" ||
    fail "Docker supplement omits ${common_asset}"
done
grep -Fq 'files/docker/node/addons/block_watcher.sh' "${DOCKER_SOURCE_MANIFEST}" ||
  fail "Docker supplement omits cnode block_watcher.sh"
for network in guild mainnet preprod preview; do
  for config in alonzo-genesis.json byron-genesis.json conway-genesis.json \
    shelley-genesis.json config.json db-sync-config.json topology.json; do
    grep -Fq $'cnode\tfiles/configs/cnode/'"${network}/${config}"$'\trootfs/conf/'"${network}/${config}" \
      "${DOCKER_SOURCE_MANIFEST}" ||
      fail "Docker supplement omits ${network}/${config}"
  done
done
if grep -Fq 'files/docker/node/' "${HOST_SOURCE_MANIFEST}"; then
  fail "host payload receipt inventory incorrectly owns Docker supplement assets"
fi
grep -Fq 'alias gLiveView=${IMAGE_NODE_HOME}/scripts/gLiveView.sh' "${DOCKERFILE}" ||
  fail "Dockerfile does not expose gLiveView for every implementation"
grep -Fq '"${IMAGE_NODE_IMPLEMENTATION}" = "dingo"' "${DOCKERFILE}" ||
  fail "Dockerfile does not expose CNTools for Dingo"
grep -Fq 'ENABLE_CHATTR=false' "${DOCKERFILE}" ||
  fail "Dockerfile does not set the CNTools chattr container default"
grep -Fq 'ENABLE_DIALOG=false' "${DOCKERFILE}" ||
  fail "Dockerfile does not set the CNTools dialog container default"
if grep -Eq 'customise_cntools|sed .*cntools[.]sh|refresh_deployment' "${ENTRYPOINT}"; then
  fail "container entrypoint still mutates or refreshes the receipted payload"
fi
grep -Fq 'UPDATE_CHECK=Y is not supported in immutable Guild images' \
  "${ENTRYPOINT}" ||
  fail "container entrypoint does not reject mutable runtime updates"
grep -Fq 'cnode_prepare_runtime_configs' "${ENTRYPOINT}" ||
  fail "container entrypoint does not create a non-receipted cnode config overlay"
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
  "scripts/grest-helper-scripts/**" \
  "files/node-implementations/**" \
  "files/configs/**" \
  "files/docker/node/**" \
  ".github/workflows/docker_bin.yml"; do
  grep -Fq -- "- '${watched_path}'" "${WORKFLOW}" ||
    fail "Docker workflow does not rebuild for ${watched_path}"
done

receipt_dir="${TEST_DIR}/receipts"
valid_receipt="${receipt_dir}/valid.json"
receipt_rows="${receipt_dir}/files.tsv"
mkdir -p "${receipt_dir}"
cat > "${valid_receipt}" <<'EOF'
{
  "files": [
    {
      "source": "files/docker/node/addons/banner.txt",
      "path": "/home/guild/.scripts/banner.txt",
      "mode": "0644",
      "sourceSha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "exportedSha256": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
EOF
extract_docker_receipt_files "${valid_receipt}" "${receipt_rows}" ||
  fail "strict Docker receipt extraction rejected a valid inventory"
[[ "$(awk -F '\t' 'END { print NR ":" NF }' "${receipt_rows}")" == "1:3" ]] ||
  fail "strict Docker receipt extraction did not emit one complete record"

jq '.files = []' "${valid_receipt}" > "${receipt_dir}/empty.json"
if extract_docker_receipt_files \
  "${receipt_dir}/empty.json" "${receipt_rows}" 2>/dev/null; then
  fail "strict Docker receipt extraction accepted an empty inventory"
fi
jq '.files[0].exportedSha256 = "bad"' "${valid_receipt}" \
  > "${receipt_dir}/malformed-record.json"
if extract_docker_receipt_files \
  "${receipt_dir}/malformed-record.json" "${receipt_rows}" 2>/dev/null; then
  fail "strict Docker receipt extraction accepted a malformed record"
fi
jq '.files += [.files[0]]' "${valid_receipt}" \
  > "${receipt_dir}/duplicate-path.json"
if extract_docker_receipt_files \
  "${receipt_dir}/duplicate-path.json" "${receipt_rows}" 2>/dev/null; then
  fail "strict Docker receipt extraction accepted a duplicate path"
fi
jq '.files[0].path = "/home/guild/../unsafe"' "${valid_receipt}" \
  > "${receipt_dir}/unsafe-path.json"
if extract_docker_receipt_files \
  "${receipt_dir}/unsafe-path.json" "${receipt_rows}" 2>/dev/null; then
  fail "strict Docker receipt extraction accepted an unsafe path"
fi
printf '{\n' > "${receipt_dir}/malformed-json.json"
if extract_docker_receipt_files \
  "${receipt_dir}/malformed-json.json" "${receipt_rows}" 2>/dev/null; then
  fail "strict Docker receipt extraction accepted malformed JSON"
fi

verified_files="$(cd -P -- "${receipt_dir}" && pwd -P)/verified-files"
fake_docker_bin="${receipt_dir}/docker-bin"
mkdir -p "${verified_files}" "${fake_docker_bin}"
for verified_name in early middle final; do
  printf '%s\n' "expected-${verified_name}" > "${verified_files}/${verified_name}"
done
jq -n \
  --arg early_path "${verified_files}/early" \
  --arg early_hash "$(sha256sum "${verified_files}/early" | awk '{print $1}')" \
  --arg middle_path "${verified_files}/middle" \
  --arg middle_hash "$(sha256sum "${verified_files}/middle" | awk '{print $1}')" \
  --arg final_path "${verified_files}/final" \
  --arg final_hash "$(sha256sum "${verified_files}/final" | awk '{print $1}')" '
    {files: [
      {source: "files/early", path: $early_path, mode: "0644",
       sourceSha256: $early_hash, exportedSha256: $early_hash},
      {source: "files/middle", path: $middle_path, mode: "0644",
       sourceSha256: $middle_hash, exportedSha256: $middle_hash},
      {source: "files/final", path: $final_path, mode: "0644",
       sourceSha256: $final_hash, exportedSha256: $final_hash}
    ]}
  ' > "${receipt_dir}/verification.json"
extract_docker_receipt_files \
  "${receipt_dir}/verification.json" "${receipt_rows}" ||
  fail "strict Docker receipt extraction rejected the verification inventory"
cat > "${fake_docker_bin}/stat" <<'EOF'
#!/bin/sh
[ "$#" -eq 3 ] && [ "$1" = '-c' ] && [ "$2" = '%a' ] && [ -f "$3" ] || exit 1
printf '%s\n' '644'
EOF
chmod 0755 "${docker_verifier}" "${fake_docker_bin}/stat"
PATH="${fake_docker_bin}:${PATH}" /bin/sh "${docker_verifier}" "${receipt_rows}" ||
  fail "Dockerfile receipt verifier rejected an intact final inventory"
printf '%s\n' 'tampered-early' > "${verified_files}/early"
if PATH="${fake_docker_bin}:${PATH}" \
  /bin/sh "${docker_verifier}" "${receipt_rows}"; then
  fail "Dockerfile receipt verifier masked an early hash mismatch"
fi
printf '%s\n' 'expected-early' > "${verified_files}/early"
printf '%s\n' 'tampered-middle' > "${verified_files}/middle"
if PATH="${fake_docker_bin}:${PATH}" \
  /bin/sh "${docker_verifier}" "${receipt_rows}"; then
  fail "Dockerfile receipt verifier masked a middle hash mismatch"
fi

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

if (
  unset CNODE_HOME NETWORK NODE_NETWORK NODE_IMPLEMENTATION NODE_HOME
  HOME="${home_dir}" \
  PATH="${fake_bin}:${PATH}" \
  IMAGE_NODE_IMPLEMENTATION="dingo" \
  IMAGE_NODE_NETWORK="preprod" \
  IMAGE_NODE_HOME="${node_home}" \
  UPDATE_CHECK="Y" \
  LAUNCHER_LOG="${launcher_log}" \
    bash "${ENTRYPOINT}" >/dev/null 2>"${TEST_DIR}/update-check.err"
); then
  fail "container entrypoint accepted a mutable runtime update"
fi
grep -Fq 'rebuild from a pinned revision' "${TEST_DIR}/update-check.err" ||
  fail "container entrypoint did not explain the immutable update policy"

cnode_home="${TEST_DIR}/opt/cardano/cnode"
cnode_conf_root="${TEST_DIR}/conf"
cnode_conf="${cnode_conf_root}/mainnet"
cnode_runtime_root="${TEST_DIR}/runtime"
cnode_launcher_log="${TEST_DIR}/cnode-launcher.log"
mkdir -p "${cnode_home}/files" "${cnode_home}/scripts" "${cnode_conf}"
cat > "${cnode_home}/.deployment.json" <<'EOF'
{
  "schemaVersion": 1,
  "deploymentStatus": "deployed",
  "implementation": "cnode",
  "network": "mainnet",
  "branch": "master",
  "repository": "cardano-community/guild-operators",
  "serviceName": "cnode",
  "nodeVersion": "cardano-node 10.1.4",
  "targetNodeVersion": "10.1.4",
  "metricsProvider": "prometheus",
  "capabilities": {
    "n2c": true,
    "localCli": true,
    "metrics": true,
    "forging": true
  }
}
EOF
cat > "${cnode_home}/files/config.json" <<'EOF'
{"receiptManaged":"unchanged","endpoint":"127.0.0.1"}
EOF
cat > "${cnode_home}/scripts/cntools.sh" <<'EOF'
#!/usr/bin/env bash
#ENABLE_CHATTR=true
#ENABLE_DIALOG=false
EOF
cat > "${cnode_conf}/config.json" <<'EOF'
{"TraceOptions":{"":{"backends":["PrometheusSimple suffix 127.0.0.1 12798"]}}}
EOF
for config_file in alonzo-genesis.json byron-genesis.json conway-genesis.json \
  shelley-genesis.json topology.json db-sync-config.json; do
  printf '{}\n' > "${cnode_conf}/${config_file}"
done
cat > "${fake_bin}/cardano-node" <<'EOF'
#!/usr/bin/env bash
printf 'cardano-node test version\n'
EOF
cat > "${cnode_home}/scripts/cnode.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n%s\n' "${CONFIG}" "${TOPOLOGY}" > "${LAUNCHER_LOG}"
EOF
chmod 0755 "${fake_bin}/cardano-node" "${cnode_home}/scripts/cnode.sh" \
  "${cnode_home}/scripts/cntools.sh"

cnode_receipt_inventory="${TEST_DIR}/cnode-receipt-files.ndjson"
cnode_receipt="${cnode_home}/.guild-source-receipt.json"
cnode_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
: > "${cnode_receipt_inventory}"
for relative_path in files/config.json scripts/cnode.sh scripts/cntools.sh; do
  receipt_file="${cnode_home}/${relative_path}"
  receipt_digest="$(sha256sum "${receipt_file}" | awk '{print $1}')"
  case "${relative_path}" in
    scripts/*) receipt_mode=0755 ;;
    *) receipt_mode=0644 ;;
  esac
  jq -cn --arg path "${relative_path}" --arg mode "${receipt_mode}" \
    --arg digest "${receipt_digest}" '{
      path: $path,
      source: $path,
      mode: $mode,
      policy: "exact",
      sourceSha256: $digest,
      installedSha256: $digest,
      managed: true
    }' >> "${cnode_receipt_inventory}"
done
jq -s --arg revision "${cnode_revision}" '{
    schemaVersion: 1,
    implementation: "cnode",
    network: "mainnet",
    source: {
      repository: "cardano-community/guild-operators",
      channel: "master",
      ref: "refs/heads/master",
      revision: $revision,
      mode: "managed",
      dirty: false
    },
    files: .
  }' "${cnode_receipt_inventory}" > "${cnode_receipt}"
rm -f -- "${cnode_receipt_inventory}"
cnode_receipt_hash="$(sha256sum "${cnode_receipt}" | awk '{print $1}')"
jq --arg revision "${cnode_revision}" --arg receipt_hash "${cnode_receipt_hash}" '
    . + {
      sourceSchemaVersion: 1,
      sourceMode: "managed",
      sourceRef: "refs/heads/master",
      sourceRevision: $revision,
      sourceDirty: false,
      payloadReceipt: ".guild-source-receipt.json",
      payloadReceiptSha256: $receipt_hash,
      transactionId: ($receipt_hash[0:16]),
      nodePort: 6000
    }
  ' "${cnode_home}/.deployment.json" > "${cnode_home}/.deployment.json.tmp"
mv -f "${cnode_home}/.deployment.json.tmp" "${cnode_home}/.deployment.json"

target_config_hash="$(sha256sum "${cnode_home}/files/config.json" | awk '{print $1}')"
target_cntools_hash="$(sha256sum "${cnode_home}/scripts/cntools.sh" | awk '{print $1}')"
cached_config_hash="$(sha256sum "${cnode_conf}/config.json" | awk '{print $1}')"
(
  unset CNODE_HOME NETWORK NODE_NETWORK NODE_IMPLEMENTATION NODE_HOME CONFIG TOPOLOGY
  HOME="${home_dir}" \
  PATH="${fake_bin}:${PATH}" \
  IMAGE_NODE_IMPLEMENTATION="cnode" \
  IMAGE_NODE_NETWORK="mainnet" \
  IMAGE_NODE_HOME="${cnode_home}" \
  GUILD_DOCKER_CONFIG_ROOT="${cnode_conf_root}" \
  GUILD_RUNTIME_ROOT="${cnode_runtime_root}" \
  UPDATE_CHECK="N" \
  ENABLE_BACKUP="N" \
  ENABLE_RESTORE="N" \
  LAUNCHER_LOG="${cnode_launcher_log}" \
    bash "${ENTRYPOINT}" run
)
runtime_config="$(sed -n '1p' "${cnode_launcher_log}")"
runtime_topology="$(sed -n '2p' "${cnode_launcher_log}")"
[[ "${runtime_config}" == "${cnode_runtime_root}/cnode/mainnet/config.json" &&
   "${runtime_topology}" == "${cnode_runtime_root}/cnode/mainnet/topology.json" ]] ||
  fail "cnode entrypoint did not launch against the runtime config overlay"
grep -Fq '0.0.0.0' "${runtime_config}" ||
  fail "cnode runtime config overlay was not customized for container metrics"
if grep -Fq '0.0.0.0' "${cnode_conf}/config.json"; then
  fail "cnode entrypoint mutated the receipted Docker config cache"
fi
[[ "$(sha256sum "${cnode_home}/files/config.json" | awk '{print $1}')" == "${target_config_hash}" ]] ||
  fail "cnode entrypoint mutated a host-receipted config file"
[[ "$(sha256sum "${cnode_home}/scripts/cntools.sh" | awk '{print $1}')" == "${target_cntools_hash}" ]] ||
  fail "container entrypoint mutated the receipted CNTools script"
[[ "$(sha256sum "${cnode_conf}/config.json" | awk '{print $1}')" == "${cached_config_hash}" ]] ||
  fail "cnode entrypoint changed the Docker supplement cache"
(
  NODE_HOME="${cnode_home}"
  # shellcheck source=/dev/null
  . "${ROOT_DIR}/scripts/common-helper-scripts/lib/deployment.library"
  deployment_payload_is_current
) || fail "cnode entrypoint invalidated the committed host payload receipt"

printf 'docker deployment tests passed\n'
