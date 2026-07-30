#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_not_exists() {
  [[ ! -e "$1" ]] || fail "unexpected path: $1"
}

write_fake_executable() {
  local destination="$1"
  local version_output="$2"
  mkdir -p "$(dirname "${destination}")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "${1:-}" in' \
    "  version|--version) printf '%s\\n' '${version_output}' ;;" \
    'esac' \
    > "${destination}"
  chmod 0755 "${destination}"
}

write_fake_systemctl() {
  local destination="$1"
  mkdir -p "$(dirname "${destination}")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "${SYSTEMCTL_LOG:?}"' \
    > "${destination}"
  chmod 0755 "${destination}"
}

assert_rendered_yaml() {
  local config_file="$1"
  local expected_port="$2"
  ruby -ryaml -e '
    document = YAML.safe_load(File.read(ARGV.fetch(0)), permitted_classes: [], aliases: false)
    expected_port = Integer(ARGV.fetch(1), 10)
    abort "relayPort is not a rendered integer" unless document.fetch("relayPort") == expected_port
    abort "block production must remain disabled" unless document.fetch("blockProducer") == false
  ' "${config_file}" "${expected_port}"
}

assert_otelcol_yaml() {
  local config_file="$1"
  ruby -ryaml -e '
    document = YAML.safe_load(File.read(ARGV.fetch(0)), permitted_classes: [], aliases: false)
    receiver = document.fetch("receivers").fetch("otlp").fetch("protocols")
    abort "OTLP gRPC must be loopback-only" unless
      receiver.fetch("grpc").fetch("endpoint") == "127.0.0.1:4317"
    abort "OTLP HTTP must be loopback-only" unless
      receiver.fetch("http").fetch("endpoint") == "127.0.0.1:4318"

    exporters = document.fetch("exporters")
    abort "nop exporter is missing" unless exporters.key?("nop")
    prometheus = exporters.fetch("prometheus")
    abort "Prometheus bridge must be loopback-only" unless
      prometheus.fetch("endpoint") == "127.0.0.1:8889"
    abort "metric suffixes must remain disabled" unless
      prometheus.fetch("translation_strategy") == "UnderscoreEscapingWithoutSuffixes"
    abort "scope labels must remain disabled" unless
      prometheus.fetch("without_scope_info") == true

    pipelines = document.fetch("service").fetch("pipelines")
    abort "unexpected telemetry pipelines" unless
      pipelines.keys.sort == %w[logs metrics traces]
    %w[logs traces].each do |name|
      pipeline = pipelines.fetch(name)
      abort "#{name} pipeline must receive OTLP" unless pipeline.fetch("receivers") == ["otlp"]
      abort "#{name} pipeline must discard with nop" unless pipeline.fetch("exporters") == ["nop"]
    end
    metrics = pipelines.fetch("metrics")
    abort "metrics pipeline must receive OTLP" unless metrics.fetch("receivers") == ["otlp"]
    abort "metrics pipeline must drop unstable resource labels" unless
      metrics.fetch("processors") == ["resource/drop_prometheus_labels"]
    abort "metrics pipeline must export Prometheus" unless
      metrics.fetch("exporters") == ["prometheus"]
  ' "${config_file}"
}

run_alternate_profile_test() (
  local implementation="$1"
  local network="$2"
  local default_port="$3"
  local expected_version
  local test_root
  local profile
  local deploy_function
  local install_payloads_function
  local runtime_bundle_function="dispatcher_install_common_runtime_bundle"
  local runtime_fetch_function
  local release_validator
  local binary_resolver_function
  local next_steps_function
  local validate_function
  local parse_function
  local launcher
  local config_env
  local service_name
  local fake_systemctl
  local systemctl_log
  local unit_dir
  local unit_file
  local metrics_unit_file
  local release_path
  local release_checksum
  local source_release_manifest
  local validation_manifest
  local resolved_node_home
  local valid_deployment_manifest
  local manifest_corruption
  local runtime_before
  local runtime_after
  local runtime_failure_path
  local runtime_mutation
  local runtime_mv_fail_target
  local runtime_mv_fail_sentinel
  local runtime_env_tmp
  local captured_state_path
  local stale_environment
  local stale_environment_error
  local -a runtime_targets

  test_root="$(mktemp -d "${TMPDIR:-/tmp}/guild-${implementation}-profile.XXXXXX")"
  trap 'rm -rf -- "${test_root}"' EXIT

  HOME="${test_root}/home"
  NODE_IMPLEMENTATION="${implementation}"
  NODE_PARENT="${test_root}/opt/cardano"
  NODE_NAME="${implementation}-test"
  NODE_HOME="${NODE_PARENT}/${NODE_NAME}"
  NODE_SERVICE="${implementation}-test"
  NETWORK="${network}"
  BRANCH="master"
  URL_RAW="https://not-used.invalid"
  S_ARGS=""
  UPDATE_CHECK="N"
  SUDO="N"
  sudo=""
  unset NODE_PORT
  export HOME NODE_IMPLEMENTATION NODE_PARENT NODE_NAME NODE_HOME NODE_SERVICE
  export NETWORK BRANCH URL_RAW S_ARGS UPDATE_CHECK SUDO sudo

  uname() {
    case "${1:-}" in
      -s) printf 'Linux\n' ;;
      -m) printf 'x86_64\n' ;;
      *) command uname "$@" ;;
    esac
  }

  curl() {
    fail "profile attempted network access: $*"
  }

  case "${implementation}" in
    dingo)
      profile="${REPO_ROOT}/scripts/dingo-helper-scripts/deploy-dingo.sh"
      deploy_function="deploy_dingo_profile"
      install_payloads_function="dingo_deploy_install_payloads"
      runtime_fetch_function="dingo_deploy_fetch"
      release_validator="dingo_deploy_validate_release_metadata"
      binary_resolver_function="dingo_deploy_resolve_binary"
      next_steps_function="dingo_deploy_show_next_steps"
      validate_function="dingo_deploy_validate_context"
      parse_function="dingo_deploy_parse_flags"
      ;;
    amaru)
      profile="${REPO_ROOT}/scripts/amaru-helper-scripts/deploy-amaru.sh"
      deploy_function="deploy_amaru_profile"
      install_payloads_function="amaru_deploy_install_payloads"
      runtime_fetch_function="amaru_deploy_fetch"
      release_validator="amaru_deploy_validate_release_metadata"
      binary_resolver_function="amaru_deploy_resolve_binary"
      next_steps_function="amaru_deploy_show_next_steps"
      validate_function="amaru_deploy_validate_context"
      parse_function="amaru_deploy_parse_flags"
      ;;
    *)
      fail "unknown test implementation: ${implementation}"
      ;;
  esac

  # Alternate profiles receive their shared transaction and lock helpers from
  # the minimal dispatcher that downloads and sources them in production.
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh"
  # Profiles normally delegate fatal errors to the dispatcher's exiting
  # handler. Tests need a return value so expected validation failures can be
  # asserted without terminating this isolated profile case.
  err_exit() {
    printf 'ERROR: %s\n' "$1" >&2
    return 1
  }
  dispatcher_mark_in_progress() {
    return 0
  }
  # shellcheck source=/dev/null
  . "${profile}"

  source_release_manifest="${REPO_ROOT}/files/node-implementations/${implementation}/release.json"
  validation_manifest="${test_root}/${implementation}-release-validation.json"
  expected_version="$(jq -er '.version' "${source_release_manifest}")"
  "${release_validator}" "${source_release_manifest}" ||
    fail "${implementation} rejected its compact release manifest"

  assert_release_manifest_rejected() {
    local context="$1"
    local jq_filter="$2"
    jq "${jq_filter}" "${source_release_manifest}" > "${validation_manifest}"
    if "${release_validator}" "${validation_manifest}" >/dev/null 2>&1; then
      fail "${implementation} accepted release metadata with ${context}"
    fi
  }

  assert_release_manifest_rejected \
    "an unsupported schema" '.schemaVersion = 2'
  assert_release_manifest_rejected \
    "the wrong implementation" '.implementation = "wrong-node"'
  assert_release_manifest_rejected \
    "a missing version" 'del(.version)'
  assert_release_manifest_rejected \
    "an unsafe version" '.version = "../wrong-version"'
  assert_release_manifest_rejected \
    "a legacy policy field" '.releasePolicy = {"mode": "pinned"}'
  assert_release_manifest_rejected \
    "one rolling architecture missing" 'del(.assets["linux-aarch64"])'
  assert_release_manifest_rejected \
    "an unexpected rolling-release field" '.unexpected = true'
  assert_release_manifest_rejected \
    "an unapproved GitHub repository" '.github = "example/wrong-node"'
  assert_release_manifest_rejected \
    "an empty rolling asset selector" '.assets["linux-x86_64"] = ""'
  assert_release_manifest_rejected \
    "whitespace in a rolling asset selector" \
    '.assets["linux-x86_64"] += "\n"'
  assert_release_manifest_rejected \
    "a non-string rolling asset selector" \
    '.assets["linux-x86_64"] = {"pattern": "archive"}'
  if [[ "${implementation}" == "amaru" ]]; then
    assert_release_manifest_rejected \
      "a missing OpenTelemetry Collector companion" 'del(.otelcol)'
    assert_release_manifest_rejected \
      "an unsafe OpenTelemetry Collector version" \
      '.otelcol.version = "../wrong-version"'
    assert_release_manifest_rejected \
      "one OpenTelemetry Collector architecture missing" \
      'del(.otelcol.artifacts["linux-aarch64"])'
    assert_release_manifest_rejected \
      "unexpected OpenTelemetry Collector metadata" \
      '.otelcol.artifacts["linux-x86_64"].filename = "otelcol-contrib.tar.gz"'
    assert_release_manifest_rejected \
      "an insecure OpenTelemetry Collector URL" \
      '.otelcol.artifacts["linux-x86_64"].url = "http://example.invalid/otelcol.tar.gz"'
    assert_release_manifest_rejected \
      "an invalid OpenTelemetry Collector checksum" \
      '.otelcol.artifacts["linux-x86_64"].sha256 = "not-a-sha256"'
  fi

  NETWORK="mainnet"
  if "${validate_function}" >/dev/null 2>&1; then
    fail "${implementation} accepted an unsupported network"
  fi
  NETWORK="${network}"

  S_ARGS="blmcowxr"
  if "${parse_function}" >/dev/null 2>&1; then
    fail "${implementation} accepted cnode-only selective-install flags"
  fi
  S_ARGS=""

  "${deploy_function}"

  launcher="${NODE_HOME}/scripts/${implementation}.sh"
  resolved_node_home="$(cd "${NODE_HOME}" && pwd -P)"
  config_env="${NODE_HOME}/scripts/${implementation}.env"
  service_name="${NODE_SERVICE}.service"

  [[ "${NODE_PORT}" == "${default_port}" ]] ||
    fail "${implementation} selected unexpected default port ${NODE_PORT}"
  [[ -x "${launcher}" ]] || fail "launcher is not executable: ${launcher}"
  assert_file "${config_env}"
  assert_file "${NODE_HOME}/files/${implementation}-release.json"
  assert_file "${NODE_HOME}/scripts/adapters/${implementation}.adapter"
  assert_file "${NODE_HOME}/scripts/env"
  assert_file "${NODE_HOME}/scripts/lib/deployment.library"
  assert_file "${NODE_HOME}/scripts/lib/env.library"
  assert_file "${NODE_HOME}/scripts/lib/node-api.library"
  assert_file "${NODE_HOME}/scripts/lib/systemd.library"
  [[ -x "${NODE_HOME}/scripts/gLiveView.sh" ]] ||
    fail "gLiveView is not executable: ${NODE_HOME}/scripts/gLiveView.sh"
  assert_not_exists "${NODE_HOME}/scripts/cntools.sh"
  assert_not_exists "${NODE_HOME}/scripts/cntools.library"
  assert_not_exists "${NODE_HOME}/scripts/.env_branch"
  assert_not_exists "${NODE_HOME}/scripts/.node_implementation"

  if [[ "${implementation}" == "amaru" ]]; then
    stale_environment="${test_root}/amaru.env.stale"
    sed 's/^AMARU_WITH_OPEN_TELEMETRY="true"$/AMARU_WITH_OPEN_TELEMETRY="false"/' \
      "${config_env}" > "${stale_environment}"
    command mv -f -- "${stale_environment}" "${config_env}"
    AMARU_DEPLOY_FORCE_CONFIG="N"
    if stale_environment_error="$(
      amaru_deploy_install_environment 2>&1
    )"; then
      fail "Amaru preserved a pre-metrics environment while advertising metrics support"
    fi
    grep -F -- '-s f' <<< "${stale_environment_error}" >/dev/null ||
      fail "Amaru incompatible-environment error did not explain the -s f upgrade"
    grep -F 'AMARU_WITH_OPEN_TELEMETRY="false"' "${config_env}" >/dev/null ||
      fail "Amaru compatibility rejection unexpectedly replaced the existing environment"

    AMARU_DEPLOY_FORCE_CONFIG="Y"
    amaru_deploy_install_environment
    grep -F 'AMARU_WITH_OPEN_TELEMETRY="true"' "${config_env}" >/dev/null ||
      fail "Amaru -s f recovery did not install the managed telemetry settings"

    grep -v '^OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=' \
      "${config_env}" > "${stale_environment}"
    command mv -f -- "${stale_environment}" "${config_env}"
    AMARU_DEPLOY_FORCE_CONFIG="N"
    if stale_environment_error="$(
      amaru_deploy_install_environment 2>&1
    )"; then
      fail "Amaru preserved an environment without its managed OTLP metrics endpoint"
    fi
    grep -F -- '-s f' <<< "${stale_environment_error}" >/dev/null ||
      fail "Amaru missing-endpoint error did not explain the -s f upgrade"

    AMARU_DEPLOY_FORCE_CONFIG="Y"
    amaru_deploy_install_environment
    AMARU_DEPLOY_FORCE_CONFIG="N"
  fi

  runtime_targets=(
    "${NODE_HOME}/scripts/lib/deployment.library"
    "${NODE_HOME}/scripts/lib/env.library"
    "${NODE_HOME}/scripts/lib/node-api.library"
    "${NODE_HOME}/scripts/lib/systemd.library"
    "${NODE_HOME}/scripts/adapters/${implementation}.adapter"
    "${NODE_HOME}/scripts/env"
  )
  runtime_bundle_snapshot() {
    local target
    for target in "${runtime_targets[@]}"; do
      sha256sum "${target}"
    done
  }
  assert_no_runtime_staging() {
    if find "${NODE_HOME}/scripts" \
      \( -name '.common-runtime-install.*' -o \
         -name '.*.commit.*' -o \
         -name '.*.restore.*' \) \
      -print -quit | grep -q .; then
      fail "${implementation} left common runtime transaction files"
    fi
  }

  # Keep one installed member intentionally different. A later fetch or
  # validation failure must occur before the first replacement.
  runtime_mutation="${runtime_targets[0]}"
  printf '# retained-local-generation\n' >> "${runtime_mutation}"
  runtime_before="$(runtime_bundle_snapshot)"
  runtime_failure_path="scripts/common-helper-scripts/lib/node-api.library"
  RUNTIME_FAILURE_MODE="fetch"
  case "${implementation}" in
    dingo)
      eval "$(declare -f dingo_deploy_fetch |
        sed '1s/dingo_deploy_fetch/dingo_deploy_fetch_original/')"
      dingo_deploy_fetch() {
        if [[ "${RUNTIME_FAILURE_MODE}" == "fetch" &&
              "$1" == "${runtime_failure_path}" ]]; then
          return 1
        fi
        dingo_deploy_fetch_original "$@" || return 1
        if [[ "${RUNTIME_FAILURE_MODE}" == "validation" &&
              "$1" == "${runtime_failure_path}" ]]; then
          printf '\nif (\n' >> "$2"
        fi
      }
      ;;
    amaru)
      eval "$(declare -f amaru_deploy_fetch |
        sed '1s/amaru_deploy_fetch/amaru_deploy_fetch_original/')"
      amaru_deploy_fetch() {
        if [[ "${RUNTIME_FAILURE_MODE}" == "fetch" &&
              "$1" == "${runtime_failure_path}" ]]; then
          return 1
        fi
        amaru_deploy_fetch_original "$@" || return 1
        if [[ "${RUNTIME_FAILURE_MODE}" == "validation" &&
              "$1" == "${runtime_failure_path}" ]]; then
          printf '\nif (\n' >> "$2"
        fi
      }
      ;;
  esac

  if "${runtime_bundle_function}" \
    "${implementation}" "${runtime_fetch_function}" N >/dev/null 2>&1; then
    fail "${implementation} runtime transaction ignored a fetch failure"
  fi
  runtime_after="$(runtime_bundle_snapshot)"
  [[ "${runtime_after}" == "${runtime_before}" ]] ||
    fail "${implementation} fetch failure changed an installed runtime member"
  assert_no_runtime_staging

  RUNTIME_FAILURE_MODE="validation"
  if "${runtime_bundle_function}" \
    "${implementation}" "${runtime_fetch_function}" N >/dev/null 2>&1; then
    fail "${implementation} runtime transaction ignored a validation failure"
  fi
  runtime_after="$(runtime_bundle_snapshot)"
  [[ "${runtime_after}" == "${runtime_before}" ]] ||
    fail "${implementation} validation failure changed an installed runtime member"
  assert_no_runtime_staging

  # Make every member differ, fail the third commit exactly once, and verify
  # that the first two replacements are rolled back to the same generation.
  for runtime_mutation in "${runtime_targets[@]}"; do
    printf '# rollback-generation-%s\n' "${implementation}" >> "${runtime_mutation}"
  done
  runtime_before="$(runtime_bundle_snapshot)"
  RUNTIME_FAILURE_MODE="none"
  runtime_mv_fail_target="${runtime_targets[2]}"
  runtime_mv_fail_sentinel="${test_root}/runtime-mv-failed"
  mv() {
    local destination=""
    local argument
    for argument in "$@"; do
      destination="${argument}"
    done
    if [[ "${destination}" == "${runtime_mv_fail_target}" &&
          ! -e "${runtime_mv_fail_sentinel}" ]]; then
      : > "${runtime_mv_fail_sentinel}"
      return 1
    fi
    command mv "$@"
  }
  if "${runtime_bundle_function}" \
    "${implementation}" "${runtime_fetch_function}" N >/dev/null 2>&1; then
    fail "${implementation} runtime transaction ignored a commit failure"
  fi
  unset -f mv
  [[ -f "${runtime_mv_fail_sentinel}" ]] ||
    fail "${implementation} runtime commit failure was not injected"
  runtime_after="$(runtime_bundle_snapshot)"
  [[ "${runtime_after}" == "${runtime_before}" ]] ||
    fail "${implementation} commit failure left mixed runtime generations"
  assert_no_runtime_staging

  case "${implementation}" in
    dingo)
      unset -f dingo_deploy_fetch
      eval "$(declare -f dingo_deploy_fetch_original |
        sed '1s/dingo_deploy_fetch_original/dingo_deploy_fetch/')"
      unset -f dingo_deploy_fetch_original
      ;;
    amaru)
      unset -f amaru_deploy_fetch
      eval "$(declare -f amaru_deploy_fetch_original |
        sed '1s/amaru_deploy_fetch_original/amaru_deploy_fetch/')"
      unset -f amaru_deploy_fetch_original
      ;;
  esac
  "${runtime_bundle_function}" \
    "${implementation}" "${runtime_fetch_function}" N

  # A normal refresh keeps operator content above env's template boundary.
  runtime_env_tmp="$(mktemp "${NODE_HOME}/scripts/.env-header-test.XXXXXX")"
  awk '
    /^# Do NOT modify code below/ && !inserted {
      print "# ALT_RUNTIME_HEADER_PRESERVED=Y"
      inserted=1
    }
    { print }
  ' "${NODE_HOME}/scripts/env" > "${runtime_env_tmp}"
  command mv -f -- "${runtime_env_tmp}" "${NODE_HOME}/scripts/env"
  "${runtime_bundle_function}" \
    "${implementation}" "${runtime_fetch_function}" N
  grep -q '^# ALT_RUNTIME_HEADER_PRESERVED=Y$' "${NODE_HOME}/scripts/env" ||
    fail "${implementation} runtime refresh discarded the common env header"
  assert_no_runtime_staging

  if [[ "${implementation}" == "amaru" ]]; then
    jq -e \
      --arg implementation "${implementation}" \
      --arg version "${expected_version}" \
      '.implementation == $implementation and
       .version == $version and
       .github == "pragma-org/amaru" and
       (.assets | keys == ["linux-aarch64", "linux-x86_64"]) and
       (.otelcol.version | type == "string" and length > 0) and
       (.otelcol.artifacts | keys == ["linux-aarch64", "linux-x86_64"]) and
       (keys == ["assets", "github", "implementation", "otelcol", "schemaVersion", "version"])' \
      "${NODE_HOME}/files/${implementation}-release.json" >/dev/null
  else
    jq -e \
      --arg implementation "${implementation}" \
      --arg version "${expected_version}" \
      '.implementation == $implementation and
       .version == $version and
       .github == "blinklabs-io/dingo" and
       (.assets | keys == ["linux-aarch64", "linux-x86_64"]) and
       (keys == ["assets", "github", "implementation", "schemaVersion", "version"])' \
      "${NODE_HOME}/files/${implementation}-release.json" >/dev/null
  fi
  "${release_validator}" "${NODE_HOME}/files/${implementation}-release.json" ||
    fail "${implementation} installed invalid release metadata"

  release_path="${NODE_HOME}/files/${implementation}-release.json"

  # Rolling node releases select the most recently published non-draft entry,
  # including prereleases, and require one exact asset with a GitHub digest.
  local resolver_fixture="${test_root}/${implementation}-release-api.json"
  local resolver_valid="${resolver_fixture}.valid"
  local resolver_capture="${test_root}/${implementation}-release-api-url"
  local resolver_repository
  local resolver_asset
  local resolver_version="99.1-test"
  local resolver_tag="v${resolver_version}"
  local resolver_url
  local resolver_digest="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  local resolved_variable

  resolver_repository="$(jq -er '.github' "${release_path}")"
  case "${implementation}" in
    dingo) resolver_asset="dingo-${resolver_tag}-linux-amd64.tar.gz" ;;
    amaru) resolver_asset="amaru-${resolver_version}-linux-x86_64.tar.gz" ;;
  esac
  resolver_url="https://github.com/${resolver_repository}/releases/download/${resolver_tag}/${resolver_asset}"
  jq -n \
    --arg tag "${resolver_tag}" \
    --arg asset "${resolver_asset}" \
    --arg url "${resolver_url}" \
    --arg digest "sha256:${resolver_digest}" '
    [
      {
        tag_name: "v100.0-draft",
        draft: true,
        prerelease: false,
        published_at: "2030-01-01T00:00:00Z",
        assets: []
      },
      {
        tag_name: "v1.0-old",
        draft: false,
        prerelease: false,
        published_at: "2025-01-01T00:00:00Z",
        assets: []
      },
      {
        tag_name: $tag,
        draft: false,
        prerelease: true,
        published_at: "2029-01-01T00:00:00Z",
        assets: [{
          name: $asset,
          state: "uploaded",
          size: 123,
          browser_download_url: $url,
          digest: $digest
        }]
      }
    ]
  ' > "${resolver_fixture}"
  cp -- "${resolver_fixture}" "${resolver_valid}"

  curl() {
    local output=""
    local argument=""
    local -a arguments=("$@")
    local index
    for ((index = 0; index < ${#arguments[@]}; index++)); do
      if [[ "${arguments[index]}" == "--output" ]]; then
        output="${arguments[index + 1]}"
      fi
      [[ "${arguments[index]}" == https://api.github.com/* ]] &&
        argument="${arguments[index]}"
    done
    [[ -n "${output}" && -n "${argument}" ]] || return 1
    printf '%s\n' "${argument}" > "${resolver_capture}"
    cp -- "${resolver_fixture}" "${output}"
  }
  "${binary_resolver_function}" "${release_path}" "linux-x86_64"
  resolved_variable="${implementation^^}_RESOLVED_VERSION"
  [[ "${!resolved_variable}" == "${resolver_version}" ]] ||
    fail "${implementation} rolling resolver selected the wrong published release"
  resolved_variable="${implementation^^}_RESOLVED_PRERELEASE"
  [[ "${!resolved_variable}" == "true" ]] ||
    fail "${implementation} rolling resolver excluded the newest prerelease"
  grep -Fx \
    "https://api.github.com/repos/${resolver_repository}/releases?per_page=100" \
    "${resolver_capture}" >/dev/null ||
    fail "${implementation} rolling resolver used the wrong GitHub endpoint"

  assert_release_resolution_rejected() {
    local context="$1"
    local filter="$2"
    jq "${filter}" "${resolver_valid}" > "${resolver_fixture}"
    if "${binary_resolver_function}" \
      "${release_path}" "linux-x86_64" >/dev/null 2>&1; then
      fail "${implementation} rolling resolver accepted ${context}"
    fi
  }
  assert_release_resolution_rejected \
    "an asset without a digest" '.[2].assets[0].digest = null'
  assert_release_resolution_rejected \
    "two matching assets" '.[2].assets += [.[2].assets[0]]'
  assert_release_resolution_rejected \
    "a cross-repository asset URL" \
    '.[2].assets[0].browser_download_url = "https://github.com/example/wrong/releases/download/v99.1-test/\(.[2].assets[0].name)"'
  assert_release_resolution_rejected \
    "an asset with zero bytes" '.[2].assets[0].size = 0'
  assert_release_resolution_rejected \
    "an older compatible release after the newest lacked its asset" \
    '.[1].assets = (
       .[2].assets |
       map(.browser_download_url |=
         gsub("/v99[.]1-test/"; "/v1.0-old/"))
     ) |
     .[2].assets = []'
  curl() {
    fail "profile attempted network access: $*"
  }

  if [[ "${implementation}" == "amaru" ]]; then
    local archive_root="${test_root}/amaru-archive"
    local archive_file="${test_root}/amaru-test.tar.gz"
    local archive_sha
    local collector_root="${test_root}/otelcol-archive"
    local collector_file="${test_root}/otelcol-test.tar.gz"
    local collector_sha
    local collector_version
    local collector_test_url="https://not-used.invalid/collector-upstream-name.tar.gz"
    local release_backup="${test_root}/amaru-release.json"
    local release_tmp="${test_root}/amaru-release.tmp.json"
    local binary_status

    mkdir -p "${archive_root}/amaru-test/bin"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      "printf 'amaru %s\\n' '${resolver_version}'" \
      > "${archive_root}/amaru-test/bin/amaru"
    chmod 0644 "${archive_root}/amaru-test/bin/amaru"
    tar -czf "${archive_file}" -C "${archive_root}" amaru-test
    archive_sha="$(sha256sum "${archive_file}" | awk '{print $1}')"
    collector_version="$(jq -er '.otelcol.version' "${release_path}")"
    mkdir -p "${collector_root}"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'case "${1:-}" in' \
      "  --version) printf 'otelcol-contrib version %s\\n' '${collector_version}' ;;" \
      '  validate) exit 0 ;;' \
      'esac' \
      > "${collector_root}/otelcol-contrib"
    chmod 0644 "${collector_root}/otelcol-contrib"
    tar -czf "${collector_file}" -C "${collector_root}" otelcol-contrib
    collector_sha="$(sha256sum "${collector_file}" | awk '{print $1}')"
    cp -- "${release_path}" "${release_backup}"

    jq \
      --arg collector_url "${collector_test_url}" \
      --arg collector_sha "${collector_sha}" \
      '.otelcol.artifacts["linux-x86_64"] = {
        url: $collector_url,
        sha256: $collector_sha
      }' \
      "${release_path}" > "${release_tmp}"
    command mv -f -- "${release_tmp}" "${release_path}"

    jq -n \
      --arg tag "${resolver_tag}" \
      --arg asset "${resolver_asset}" \
      --arg url "${resolver_url}" \
      --arg digest "sha256:${archive_sha}" '
      [{
        tag_name: $tag,
        draft: false,
        prerelease: true,
        published_at: "2029-01-01T00:00:00Z",
        assets: [{
          name: $asset,
          state: "uploaded",
          size: 123,
          browser_download_url: $url,
          digest: $digest
        }]
      }]
    ' > "${resolver_fixture}"
    AMARU_TEST_ARCHIVE="${archive_file}"
    AMARU_TEST_COLLECTOR_ARCHIVE="${collector_file}"
    curl() {
      local output=""
      local request_url=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --output)
            output="$2"
            shift 2
            ;;
          https://*)
            request_url="$1"
            shift
            ;;
          *) shift ;;
        esac
      done
      [[ -n "${output}" && -n "${request_url}" ]] || return 1
      case "${request_url}" in
        https://api.github.com/*)
          cp -- "${resolver_fixture}" "${output}"
          ;;
        "${resolver_url}")
          cp -- "${AMARU_TEST_ARCHIVE}" "${output}"
          ;;
        "${collector_test_url}")
          cp -- "${AMARU_TEST_COLLECTOR_ARCHIVE}" "${output}"
          ;;
        *)
          fail "Amaru installer requested an unexpected URL: ${request_url}"
          ;;
      esac
    }
    sha256sum() {
      local expected_checksum
      local checksum_file
      local actual_checksum
      if [[ "${1:-}" == "--check" && "${2:-}" == "--status" ]]; then
        read -r expected_checksum checksum_file
        actual_checksum="$(command sha256sum "${checksum_file}" | awk '{print $1}')"
        [[ "${actual_checksum}" == "${expected_checksum}" ]]
      else
        command sha256sum "$@"
      fi
    }

    jq '.[0].assets[0].digest = ("sha256:" + ("0" * 64))' \
      "${resolver_fixture}" > "${resolver_fixture}.invalid"
    command mv -f -- "${resolver_fixture}.invalid" "${resolver_fixture}"
    set +e
    amaru_deploy_install_binary >/dev/null 2>&1
    binary_status=$?
    set -e
    [[ "${binary_status}" -ne 0 ]] ||
      fail "Amaru binary install ignored a checksum mismatch"
    assert_not_exists "${HOME}/.local/bin/amaru"
    assert_not_exists "${HOME}/.local/bin/otelcol-contrib"

    jq --arg digest "sha256:${archive_sha}" \
      '.[0].assets[0].digest = $digest' \
      "${resolver_fixture}" > "${resolver_fixture}.valid"
    command mv -f -- "${resolver_fixture}.valid" "${resolver_fixture}"
    amaru_deploy_install_binary >/dev/null
    [[ -x "${HOME}/.local/bin/amaru" ]] ||
      fail "Amaru installer did not make the mode-0644 archive member executable"
    [[ -x "${HOME}/.local/bin/otelcol-contrib" ]] ||
      fail "Amaru installer did not install its OpenTelemetry Collector companion"
    "${HOME}/.local/bin/amaru" --version | grep -F "${resolver_version}" >/dev/null
    "${HOME}/.local/bin/otelcol-contrib" --version |
      grep -F "${collector_version}" >/dev/null
    command mv -f -- "${release_backup}" "${release_path}"
    unset -f sha256sum
    curl() {
      fail "profile attempted network access: $*"
    }
  fi
  release_checksum="$(sha256sum "${release_path}" | awk '{print $1}')"
  if (
    mv() {
      local destination="${*: -1}"
      if [[ "${destination}" == "${release_path}" ]]; then
        return 1
      fi
      command mv "$@"
    }
    "${install_payloads_function}"
  ) >/dev/null 2>&1; then
    fail "${implementation} payload refresh ignored a failed release metadata replacement"
  fi
  [[ "$(sha256sum "${release_path}" | awk '{print $1}')" == "${release_checksum}" ]] ||
    fail "${implementation} release metadata changed after failed replacement"
  if find "${NODE_HOME}/files" \
    -name ".${implementation}-release.json.tmp.*" -print -quit | grep -q .; then
    fail "${implementation} left temporary release metadata after failed replacement"
  fi

  if [[ "${implementation}" == "dingo" ]]; then
    assert_file "${NODE_HOME}/files/dingo.yaml"
    grep -F "network: \"${network}\"" "${NODE_HOME}/files/dingo.yaml" >/dev/null
    grep -F "relayPort: ${default_port}" "${NODE_HOME}/files/dingo.yaml" >/dev/null
    grep -F 'blockProducer: false' "${NODE_HOME}/files/dingo.yaml" >/dev/null
    grep -F 'DINGO_STORAGE_MODE="core"' "${config_env}" >/dev/null
    assert_rendered_yaml "${NODE_HOME}/files/dingo.yaml" "${default_port}"
  else
    assert_not_exists "${NODE_HOME}/chain"
    assert_not_exists "${NODE_HOME}/ledger"
    grep -F "AMARU_NETWORK=\"${network}\"" "${config_env}" >/dev/null
    grep -F "AMARU_LISTEN_ADDRESS=\"0.0.0.0:${default_port}\"" "${config_env}" >/dev/null
    grep -F 'AMARU_WITH_OPEN_TELEMETRY="true"' "${config_env}" >/dev/null
    grep -F 'OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4317"' \
      "${config_env}" >/dev/null
    grep -F 'OTEL_EXPORTER_OTLP_METRICS_ENDPOINT="http://127.0.0.1:4318/v1/metrics"' \
      "${config_env}" >/dev/null
    grep -F 'OTEL_METRIC_EXPORT_INTERVAL="2000"' "${config_env}" >/dev/null
    grep -F 'AMARU_PROMETHEUS_URL="http://127.0.0.1:8889/metrics"' \
      "${config_env}" >/dev/null
    assert_file "${NODE_HOME}/files/otelcol.yaml"
    assert_otelcol_yaml "${NODE_HOME}/files/otelcol.yaml"
  fi

  # guild-deploy next-step guidance must reflect existing state. Refreshing an
  # already bootstrapped deployment with installed units should print no
  # bootstrap or systemd deployment suggestion.
  local guidance_output
  local guidance_unit_dir="${test_root}/guidance-systemd"
  local guidance_node_unit="${guidance_unit_dir}/${NODE_SERVICE}.service"
  local guidance_metrics_unit="${guidance_unit_dir}/${NODE_SERVICE}-metrics.service"
  mkdir -p "${guidance_unit_dir}"

  guidance_output="$(
    SYSTEMD_UNIT_DIR="${guidance_unit_dir}" "${next_steps_function}"
  )"
  grep -F "Bootstrap node state:" <<< "${guidance_output}" >/dev/null ||
    fail "${implementation} omitted bootstrap guidance for an empty state"
  grep -F "Deploy the systemd service" <<< "${guidance_output}" >/dev/null ||
    fail "${implementation} omitted service guidance when units were absent"
  if grep -Eq 'Monitor the node|CNTools|Mithril|db-sync|Ogmios' \
    <<< "${guidance_output}"; then
    fail "${implementation} next-step guidance contains unrelated suggestions"
  fi

  : > "${guidance_node_unit}"
  if [[ "${implementation}" == "amaru" ]]; then
    : > "${guidance_metrics_unit}"
  fi
  guidance_output="$(
    SYSTEMD_UNIT_DIR="${guidance_unit_dir}" "${next_steps_function}"
  )"
  grep -F "Bootstrap node state:" <<< "${guidance_output}" >/dev/null ||
    fail "${implementation} lost bootstrap guidance after service deployment"
  if grep -F "Deploy the systemd service" <<< "${guidance_output}" >/dev/null; then
    fail "${implementation} suggested redeploying an installed service"
  fi

  case "${implementation}" in
    dingo) : > "${NODE_HOME}/db/.guidance-state" ;;
    amaru) mkdir "${NODE_HOME}/chain" "${NODE_HOME}/ledger" ;;
  esac
  guidance_output="$(
    SYSTEMD_UNIT_DIR="${guidance_unit_dir}" "${next_steps_function}"
  )"
  [[ -z "${guidance_output}" ]] ||
    fail "${implementation} printed next steps for a ready existing deployment"

  command rm -f -- "${guidance_node_unit}" "${guidance_metrics_unit}"
  guidance_output="$(
    SYSTEMD_UNIT_DIR="${guidance_unit_dir}" "${next_steps_function}"
  )"
  grep -F "Deploy the systemd service" <<< "${guidance_output}" >/dev/null ||
    fail "${implementation} omitted service guidance when units were removed"
  if grep -F "Bootstrap node state:" <<< "${guidance_output}" >/dev/null; then
    fail "${implementation} suggested bootstrapping existing node state"
  fi
  case "${implementation}" in
    dingo) command rm -f -- "${NODE_HOME}/db/.guidance-state" ;;
    amaru) rmdir "${NODE_HOME}/chain" "${NODE_HOME}/ledger" ;;
  esac

  # Both alternate adapters expose the common monitoring contract used by
  # gLiveView and populate immutable timing constants for their public network.
  # shellcheck source=/dev/null
  . "${NODE_HOME}/scripts/lib/node-api.library"
  # shellcheck source=/dev/null
  . "${NODE_HOME}/scripts/adapters/${implementation}.adapter"
  node_adapter_contract_valid
  node_adapter_defaults
  node_adapter_init monitor ||
    fail "${implementation} adapter rejected the monitor profile"
  node_has metrics ||
    fail "${implementation} adapter does not advertise metrics"
  [[ "${NODE_NETWORK_NAME}" == "$([[ "${network}" == "preprod" ]] && printf PreProd || printf Preview)" ]] ||
    fail "${implementation} adapter selected unexpected network constants"
  [[ "${EPOCH_LENGTH}" == "$([[ "${network}" == "preprod" ]] && printf 432000 || printf 86400)" ]] ||
    fail "${implementation} adapter selected unexpected epoch length"

  jq -n \
    --arg implementation "${implementation}" \
    --arg network "${network}" \
    --arg service "${NODE_SERVICE}" \
    --arg target_version "${expected_version}" \
    '{
      schemaVersion: 1,
      deploymentStatus: "deployed",
      implementation: $implementation,
      network: $network,
      branch: "master",
      repository: "cardano-community/guild-operators",
      serviceName: $service,
      nodeVersion: "",
      targetNodeVersion: $target_version,
      metricsProvider: (if $implementation == "dingo" then "prometheus" else "otel" end),
      capabilities: {
        n2c: ($implementation == "dingo"),
        localCli: false,
        metrics: true,
        forging: false
      }
    }' > "${NODE_HOME}/.deployment.json"
  valid_deployment_manifest="$(cat "${NODE_HOME}/.deployment.json")"

  write_fake_executable \
    "${HOME}/.local/bin/${implementation}" \
    "${implementation} ${expected_version}"
  "${launcher}" --help >/dev/null
  "${launcher}" version | grep -F "${expected_version}" >/dev/null

  if [[ "${implementation}" == "amaru" ]]; then
    local state_root="${test_root}/container-state"
    local state_capture="${test_root}/amaru-state.log"
    local telemetry_capture="${test_root}/amaru-telemetry.log"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'case "${2:-}" in' \
      '  bootstrap)' \
      '    printf "%s\n%s\n%s\n" "${AMARU_CHAIN_DIR}" "${AMARU_LEDGER_DIR}" "${AMARU_WITH_OPEN_TELEMETRY:-unset}" > "${AMARU_STATE_CAPTURE}"' \
      '    ;;' \
      '  run)' \
      '    printf "%s\n" "${AMARU_WITH_OPEN_TELEMETRY:-unset}" > "${AMARU_TELEMETRY_CAPTURE}"' \
      '    ;;' \
      'esac' \
      > "${HOME}/.local/bin/amaru"
    chmod 0755 "${HOME}/.local/bin/amaru"
    AMARU_STATE_ROOT="${state_root}" \
      AMARU_STATE_CAPTURE="${state_capture}" \
      "${launcher}" bootstrap
    [[ -d "${state_root}" ]] ||
      fail "Amaru state parent override was not created"
    assert_not_exists "${state_root}/chain"
    assert_not_exists "${state_root}/ledger"
    captured_state_path="$(sed -n '1p' "${state_capture}")"
    [[ "${captured_state_path}" == "${state_root}/chain" ]] ||
      fail "Amaru chain state override was not passed to the binary"
    captured_state_path="$(sed -n '2p' "${state_capture}")"
    [[ "${captured_state_path}" == "${state_root}/ledger" ]] ||
      fail "Amaru ledger state override was not passed to the binary"
    [[ "$(sed -n '3p' "${state_capture}")" == "false" ]] ||
      fail "Amaru bootstrap did not suppress OpenTelemetry export"
    mkdir -p "${state_root}/chain" "${state_root}/ledger"
    AMARU_STATE_ROOT="${state_root}" \
      AMARU_TELEMETRY_CAPTURE="${telemetry_capture}" \
      "${launcher}" run
    [[ "$(sed -n '1p' "${telemetry_capture}")" == "true" ]] ||
      fail "Amaru run did not restore configured OpenTelemetry export"
    if AMARU_STATE_ROOT="/" "${launcher}" bootstrap >/dev/null 2>&1; then
      fail "Amaru launcher accepted / as its state root"
    fi
    write_fake_executable \
      "${HOME}/.local/bin/${implementation}" \
      "${implementation} ${expected_version}"
  fi

  fake_systemctl="${test_root}/bin/systemctl"
  systemctl_log="${test_root}/systemctl.log"
  unit_dir="${test_root}/systemd"
  unit_file="${unit_dir}/${service_name}"
  metrics_unit_file="${unit_dir}/${NODE_SERVICE}-metrics.service"
  mkdir -p "${unit_dir}"
  : > "${systemctl_log}"
  write_fake_systemctl "${fake_systemctl}"

  assert_launcher_rejects_manifest() {
    local context="$1"
    if SYSTEMD_UNIT_DIR="${unit_dir}" \
      SYSTEMCTL_BIN="${fake_systemctl}" \
      SYSTEMCTL_LOG="${systemctl_log}" \
      SUDO="N" \
      "${launcher}" status >/dev/null 2>&1; then
      fail "${implementation} launcher accepted ${context} deployment metadata"
    fi
  }

  jq '.schemaVersion = 2' <<< "${valid_deployment_manifest}" \
    > "${NODE_HOME}/.deployment.json"
  assert_launcher_rejects_manifest "an unsupported manifest schema"
  jq '.deploymentStatus = "deploying"' <<< "${valid_deployment_manifest}" \
    > "${NODE_HOME}/.deployment.json"
  assert_launcher_rejects_manifest "unfinished"

  for manifest_corruption in metrics-provider capability-value extra-capability; do
    case "${manifest_corruption}" in
      metrics-provider)
        jq '.metricsProvider = "corrupt-provider"' \
          <<< "${valid_deployment_manifest}" > "${NODE_HOME}/.deployment.json"
        ;;
      capability-value)
        jq '.capabilities.localCli = true' \
          <<< "${valid_deployment_manifest}" > "${NODE_HOME}/.deployment.json"
        ;;
      extra-capability)
        jq '.capabilities.unverified = true' \
          <<< "${valid_deployment_manifest}" > "${NODE_HOME}/.deployment.json"
        ;;
    esac
    assert_launcher_rejects_manifest "semantic ${manifest_corruption} corruption"
    if (
      unset GUILD_NODE_IMPLEMENTATION_OVERRIDE GUILD_NODE_NETWORK_OVERRIDE
      unset GUILD_NODE_SERVICE_OVERRIDE GUILD_REPOSITORY_ACCOUNT_OVERRIDE
      USESYSVARS="N"
      set +u
      # shellcheck source=/dev/null
      . "${NODE_HOME}/scripts/env" definitions
    ) >/dev/null 2>&1; then
      fail "common env accepted ${implementation} semantic ${manifest_corruption} corruption"
    fi
  done
  printf '%s\n' "${valid_deployment_manifest}" > "${NODE_HOME}/.deployment.json"

  assert_common_env_rejects_override() {
    local override_name="$1"
    local override_value="$2"
    if (
      unset GUILD_NODE_IMPLEMENTATION_OVERRIDE GUILD_NODE_NETWORK_OVERRIDE
      unset GUILD_NODE_SERVICE_OVERRIDE GUILD_REPOSITORY_ACCOUNT_OVERRIDE
      export "${override_name}=${override_value}"
      USESYSVARS="N"
      set +u
      # shellcheck source=/dev/null
      . "${NODE_HOME}/scripts/env" definitions
    ) >/dev/null 2>&1; then
      fail "common env accepted conflicting ${override_name} for ${implementation}"
    fi
  }

  assert_common_env_rejects_override GUILD_NODE_IMPLEMENTATION_OVERRIDE cnode
  assert_common_env_rejects_override GUILD_NODE_NETWORK_OVERRIDE mainnet
  assert_common_env_rejects_override GUILD_NODE_SERVICE_OVERRIDE wrong-service
  assert_common_env_rejects_override GUILD_REPOSITORY_ACCOUNT_OVERRIDE wrong-account

  rm -f -- "${NODE_HOME}/.deployment.json"
  "${launcher}" --help >/dev/null
  assert_launcher_rejects_manifest "a missing"
  if SYSTEMD_UNIT_DIR="${unit_dir}" \
    SYSTEMCTL_BIN="${fake_systemctl}" \
    SYSTEMCTL_LOG="${systemctl_log}" \
    SUDO="N" \
    "${launcher}" remove >/dev/null 2>&1; then
    fail "${implementation} launcher allowed removal without a deployment manifest"
  fi
  if ! (
    unset GUILD_NODE_IMPLEMENTATION_OVERRIDE GUILD_NODE_NETWORK_OVERRIDE
    unset GUILD_NODE_SERVICE_OVERRIDE GUILD_REPOSITORY_ACCOUNT_OVERRIDE
    export GUILD_NODE_IMPLEMENTATION_OVERRIDE="${implementation}"
    export GUILD_NODE_NETWORK_OVERRIDE="${network}"
    export GUILD_NODE_SERVICE_OVERRIDE="${NODE_SERVICE}"
    export GUILD_REPOSITORY_ACCOUNT_OVERRIDE="legacy-account"
    USESYSVARS="N"
    set +u
    # shellcheck source=/dev/null
    . "${NODE_HOME}/scripts/env" definitions
    [[ "${NODE_IMPLEMENTATION}" == "${implementation}" ]]
    [[ "${NODE_NETWORK}" == "${network}" ]]
    [[ "${NODE_SERVICE}" == "${implementation}-test" ]]
    [[ "${G_ACCOUNT}" == "legacy-account" ]]
  ) >/dev/null 2>&1; then
    fail "common env rejected no-manifest legacy overrides for ${implementation}"
  fi

  ln -s "${NODE_HOME}/missing-deployment-target.json" \
    "${NODE_HOME}/.deployment.json"
  if (
    unset GUILD_NODE_IMPLEMENTATION_OVERRIDE GUILD_NODE_NETWORK_OVERRIDE
    unset GUILD_NODE_SERVICE_OVERRIDE GUILD_REPOSITORY_ACCOUNT_OVERRIDE
    USESYSVARS="N"
    set +u
    # shellcheck source=/dev/null
    . "${NODE_HOME}/scripts/env" definitions
  ) >/dev/null 2>&1; then
    fail "common env treated a dangling deployment manifest symlink as legacy fallback"
  fi
  rm -f -- "${NODE_HOME}/.deployment.json"

  printf '%s\n' "${valid_deployment_manifest}" \
    > "${test_root}/linked-deployment.json"
  ln -s "${test_root}/linked-deployment.json" "${NODE_HOME}/.deployment.json"
  if (
    unset GUILD_NODE_IMPLEMENTATION_OVERRIDE GUILD_NODE_NETWORK_OVERRIDE
    unset GUILD_NODE_SERVICE_OVERRIDE GUILD_REPOSITORY_ACCOUNT_OVERRIDE
    USESYSVARS="N"
    set +u
    # shellcheck source=/dev/null
    . "${NODE_HOME}/scripts/env" definitions
  ) >/dev/null 2>&1; then
    fail "common env accepted a symlinked deployment manifest"
  fi
  rm -f -- "${NODE_HOME}/.deployment.json" \
    "${test_root}/linked-deployment.json"

  printf '%s\n' "${valid_deployment_manifest}" > "${NODE_HOME}/.deployment.json"

  SYSTEMD_UNIT_DIR="${unit_dir}" \
    SYSTEMCTL_BIN="${fake_systemctl}" \
    SYSTEMCTL_LOG="${systemctl_log}" \
    SUDO="N" \
    "${launcher}" install

  assert_file "${unit_file}"
  grep -F "WorkingDirectory=${resolved_node_home}" "${unit_file}" >/dev/null
  grep -E "ExecStart=.*/scripts/${implementation}\\.sh run$" "${unit_file}" >/dev/null
  grep -F "ReadWritePaths=${resolved_node_home}" "${unit_file}" >/dev/null
  if [[ "${implementation}" == "amaru" ]]; then
    grep -F 'Restart=always' "${unit_file}" >/dev/null
    assert_file "${metrics_unit_file}"
    grep -F "Wants=network-online.target time-sync.target ${NODE_SERVICE}-metrics.service" \
      "${unit_file}" >/dev/null
    grep -F "After=network-online.target time-sync.target ${NODE_SERVICE}-metrics.service" \
      "${unit_file}" >/dev/null
    grep -F "ExecStart=${HOME}/.local/bin/otelcol-contrib --config=${resolved_node_home}/files/otelcol.yaml" \
      "${metrics_unit_file}" >/dev/null
    grep -F "ReadOnlyPaths=${resolved_node_home}/files/otelcol.yaml" \
      "${metrics_unit_file}" >/dev/null
    grep -F 'Restart=on-failure' "${metrics_unit_file}" >/dev/null
    grep -Fx "enable ${NODE_SERVICE}-metrics.service ${service_name}" \
      "${systemctl_log}" >/dev/null
  else
    grep -F 'Restart=on-failure' "${unit_file}" >/dev/null
    assert_not_exists "${metrics_unit_file}"
    grep -Fx "enable ${service_name}" "${systemctl_log}" >/dev/null
  fi
  if grep -Eq '^start ' "${systemctl_log}"; then
    fail "${implementation} service install started the service"
  fi

  printf '%s\n' \
    'GUILD_NODE_HOME="/tmp/wrong-node-home"' \
    'GUILD_NODE_SERVICE="wrong-service"' \
    'GUILD_NODE_IMPLEMENTATION="cnode"' \
    >> "${config_env}"
  if [[ "${implementation}" == "dingo" ]]; then
    printf '%s\n' 'CARDANO_NETWORK="mainnet"' >> "${config_env}"
  else
    printf '%s\n' 'AMARU_NETWORK="mainnet"' >> "${config_env}"
  fi

  : > "${systemctl_log}"
  SYSTEMD_UNIT_DIR="${unit_dir}" \
    SYSTEMCTL_BIN="${fake_systemctl}" \
    SYSTEMCTL_LOG="${systemctl_log}" \
    SUDO="N" \
    "${launcher}" status
  if [[ "${implementation}" == "amaru" ]]; then
    grep -Fx -- "--no-pager status ${service_name} ${NODE_SERVICE}-metrics.service" \
      "${systemctl_log}" >/dev/null
    for lifecycle_action in start restart stop; do
      SYSTEMD_UNIT_DIR="${unit_dir}" \
        SYSTEMCTL_BIN="${fake_systemctl}" \
        SYSTEMCTL_LOG="${systemctl_log}" \
        SUDO="N" \
        "${launcher}" "${lifecycle_action}"
      grep -Fx \
        "${lifecycle_action} ${NODE_SERVICE}-metrics.service ${service_name}" \
        "${systemctl_log}" >/dev/null
    done
  else
    grep -Fx -- "--no-pager status ${service_name}" "${systemctl_log}" >/dev/null
  fi
  if grep -Fq "wrong-service" "${systemctl_log}"; then
    fail "${implementation} lifecycle command trusted conflicting env identity"
  fi
  if SYSTEMD_UNIT_DIR="${unit_dir}" \
    SYSTEMCTL_BIN="${fake_systemctl}" \
    SYSTEMCTL_LOG="${systemctl_log}" \
    SUDO="N" \
    "${launcher}" install >/dev/null 2>&1; then
    fail "${implementation} install accepted env identity conflicting with the manifest"
  fi

  rm -f -- "${config_env}" "${HOME}/.local/bin/${implementation}"
  [[ "${implementation}" == "dingo" ]] &&
    rm -f -- "${NODE_HOME}/files/dingo.yaml"

  SYSTEMD_UNIT_DIR="${unit_dir}" \
    SYSTEMCTL_BIN="${fake_systemctl}" \
    SYSTEMCTL_LOG="${systemctl_log}" \
    SUDO="N" \
    "${launcher}" status
  if [[ "${implementation}" == "amaru" ]]; then
    grep -Fx -- "--no-pager status ${service_name} ${NODE_SERVICE}-metrics.service" \
      "${systemctl_log}" >/dev/null
  else
    grep -Fx -- "--no-pager status ${service_name}" "${systemctl_log}" >/dev/null
  fi

  SYSTEMD_UNIT_DIR="${unit_dir}" \
    SYSTEMCTL_BIN="${fake_systemctl}" \
    SYSTEMCTL_LOG="${systemctl_log}" \
    SUDO="N" \
    "${launcher}" remove

  assert_not_exists "${unit_file}"
  assert_not_exists "${metrics_unit_file}"
  grep -Fx "disable --now ${service_name}" "${systemctl_log}" >/dev/null
  if [[ "${implementation}" == "amaru" ]]; then
    grep -Fx "disable --now ${NODE_SERVICE}-metrics.service" \
      "${systemctl_log}" >/dev/null
  fi
)

run_alternate_profile_test dingo preview 3001
run_alternate_profile_test amaru preprod 3000

printf 'alternate deployment tests passed\n'
