#!/usr/bin/env bash
# Source-only Amaru deployment profile for the common guild-deploy dispatcher.
# shellcheck disable=SC2034,SC2154

AMARU_DEPLOY_OPENSSL_ERROR=""
AMARU_DEPLOY_OPENSSL_BIN=""

amaru_deploy_info() {
  if declare -F log_info >/dev/null 2>&1; then log_info "$1"; else printf 'INFO: %s\n' "$1"; fi
}

amaru_deploy_warn() {
  if declare -F log_warn >/dev/null 2>&1; then log_warn "$1"; else printf 'WARN: %s\n' "$1" >&2; fi
}

amaru_deploy_progress() {
  if declare -F log_progress >/dev/null 2>&1; then log_progress "$1" "${2:-}"; else printf '  .. %s%s\n' "$1" "$([[ -n "${2:-}" ]] && printf ' (%s)' "$2")"; fi
}

amaru_deploy_ok() {
  if declare -F log_ok >/dev/null 2>&1; then log_ok "$1" "${2:-}"; else printf '  OK %s%s\n' "$1" "$([[ -n "${2:-}" ]] && printf ' (%s)' "$2")"; fi
}

amaru_deploy_fail() {
  if declare -F err_exit >/dev/null 2>&1; then
    err_exit "$1"
  else
    printf 'ERROR: %s\n' "$1" >&2
  fi
  return 1
}

amaru_deploy_privileged() {
  if [[ -n "${sudo:-}" ]]; then
    ${sudo} "$@"
  elif [[ "${SUDO:-Y}" == "Y" ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

amaru_deploy_validate_context() {
  [[ "${NODE_IMPLEMENTATION:-}" == "amaru" ]] || {
    amaru_deploy_fail "Amaru profile was selected with NODE_IMPLEMENTATION='${NODE_IMPLEMENTATION:-unset}'"
    return 1
  }
  case "${NETWORK:-}" in
    preprod|preview) ;;
    *)
      amaru_deploy_fail "Experimental Amaru deployment supports only preprod or preview (got '${NETWORK:-unset}')"
      return 1
      ;;
  esac
  [[ "${NODE_HOME:-}" =~ ^/[A-Za-z0-9._/+@:-]+$ ]] || {
    amaru_deploy_fail "NODE_HOME must be an absolute path containing only deployment-safe characters"
    return 1
  }
  [[ "${NODE_SERVICE:-}" =~ ^[A-Za-z0-9_.@-]+$ ]] || {
    amaru_deploy_fail "Invalid NODE_SERVICE '${NODE_SERVICE:-unset}'"
    return 1
  }
  [[ "${HOME:-}" =~ ^/[A-Za-z0-9._/+@:-]+$ ]] || {
    amaru_deploy_fail "HOME must be an absolute path containing only deployment-safe characters"
    return 1
  }
  local configured_port="${NODE_PORT:-3000}"
  if [[ ! "${configured_port}" =~ ^[0-9]+$ ]] ||
     (( 10#${configured_port} < 1 || 10#${configured_port} > 65535 )); then
    amaru_deploy_fail "NODE_PORT must be an integer from 1 to 65535"
    return 1
  fi
  NODE_PORT="$((10#${configured_port}))"
  [[ "$(uname -s)" == "Linux" ]] || {
    amaru_deploy_fail "The Amaru deployment profile currently supports Linux only"
    return 1
  }
}

amaru_deploy_parse_flags() {
  AMARU_DEPLOY_INSTALL_DEPS="N"
  AMARU_DEPLOY_INSTALL_BINARY="N"
  AMARU_DEPLOY_INSTALL_HWCLI="N"
  AMARU_DEPLOY_FORCE_CONFIG="N"
  AMARU_DEPLOY_FORCE_SCRIPTS="N"

  local unsupported="${S_ARGS:-}"
  unsupported="${unsupported//[pdfsw]/}"
  [[ -z "${unsupported}" ]] || {
    amaru_deploy_fail "Unsupported Amaru -s flag(s): '${unsupported}'. Allowed: p,d,f,s,w; cnode-only b,l,m,c,o,x,r are rejected."
    return 1
  }

  [[ "${S_ARGS:-}" == *p* ]] && AMARU_DEPLOY_INSTALL_DEPS="Y"
  [[ "${S_ARGS:-}" == *d* ]] && AMARU_DEPLOY_INSTALL_BINARY="Y"
  if [[ "${S_ARGS:-}" == *w* ]]; then
    AMARU_DEPLOY_INSTALL_DEPS="Y"
    AMARU_DEPLOY_INSTALL_HWCLI="Y"
  fi
  [[ "${S_ARGS:-}" == *f* ]] && AMARU_DEPLOY_FORCE_CONFIG="Y"
  [[ "${S_ARGS:-}" == *s* ]] && AMARU_DEPLOY_FORCE_SCRIPTS="Y"
  return 0
}

amaru_deploy_validate_openssl3() {
  local candidate=""
  local openssl_path=""
  local openssl_version=""
  local openssl_major=""
  local observed=""

  AMARU_DEPLOY_OPENSSL_ERROR=""
  AMARU_DEPLOY_OPENSSL_BIN=""
  for candidate in openssl openssl3; do
    openssl_path="$(type -P "${candidate}" 2>/dev/null || true)"
    [[ "${openssl_path}" = /* && -x "${openssl_path}" &&
       ! -d "${openssl_path}" ]] || continue
    if ! openssl_version="$(LC_ALL=C "${openssl_path}" version 2>/dev/null)"; then
      [[ -z "${observed}" ]] || observed+="; "
      observed+="'${openssl_path}' could not report its version"
      continue
    fi
    if [[ "${openssl_version}" =~ ^OpenSSL[[:space:]]+([0-9]+)\. ]]; then
      openssl_major="${BASH_REMATCH[1]}"
      if (( openssl_major >= 3 )); then
        AMARU_DEPLOY_OPENSSL_BIN="${openssl_path}"
        return 0
      fi
    fi
    [[ -z "${observed}" ]] || observed+="; "
    observed+="'${openssl_path}' reported '${openssl_version:-no version}'"
  done

  if [[ -n "${observed}" ]]; then
    AMARU_DEPLOY_OPENSSL_ERROR="OpenSSL 3 or newer is required for CNTools transaction witness validation. Checked ${observed}. Install OpenSSL 3 so either 'openssl' or 'openssl3' resolves to it, then rerun guild-deploy.sh. On Rocky/RHEL 8, enable EPEL and install its 'openssl3' package."
  else
    AMARU_DEPLOY_OPENSSL_ERROR="OpenSSL 3 or newer is required for CNTools transaction witness validation. Neither 'openssl' nor 'openssl3' was found on PATH. Install OpenSSL 3 under either name, then rerun guild-deploy.sh. On Rocky/RHEL 8, enable EPEL and install its 'openssl3' package."
  fi
  return 1
}

amaru_deploy_install_dependencies() {
  local -a hardware_packages

  amaru_deploy_progress "Installing Amaru runtime prerequisites"
  if command -v apt-get >/dev/null 2>&1; then
    hardware_packages=()
    [[ "${AMARU_DEPLOY_INSTALL_HWCLI:-N}" == "Y" ]] &&
      hardware_packages=(libusb-1.0-0-dev libudev-dev udev)
    dispatcher_run_package_command "Amaru package metadata update" \
      amaru_deploy_privileged apt-get \
      -o Dpkg::Use-Pty=0 -o APT::Color=0 update || return 1
    dispatcher_run_package_command "Amaru prerequisite package installation" \
      amaru_deploy_privileged env DEBIAN_FRONTEND=noninteractive apt-get \
      -o Dpkg::Use-Pty=0 -o APT::Color=0 install -y \
      bc ca-certificates coreutils curl diffutils findutils gawk git gnupg grep gzip iproute2 jq \
      ncurses-bin openssl procps sed tar xxd "${hardware_packages[@]}" || return 1
  elif command -v dnf >/dev/null 2>&1; then
    hardware_packages=()
    [[ "${AMARU_DEPLOY_INSTALL_HWCLI:-N}" == "Y" ]] &&
      hardware_packages=(libusbx udev)
    dispatcher_run_package_command "Amaru prerequisite package installation" \
      amaru_deploy_privileged dnf install -y \
      bc ca-certificates coreutils curl diffutils findutils gawk git gnupg2 grep gzip iproute jq \
      ncurses openssl procps-ng sed tar vim-common "${hardware_packages[@]}" || return 1
  elif command -v yum >/dev/null 2>&1; then
    hardware_packages=()
    [[ "${AMARU_DEPLOY_INSTALL_HWCLI:-N}" == "Y" ]] &&
      hardware_packages=(libusbx udev)
    dispatcher_run_package_command "Amaru prerequisite package installation" \
      amaru_deploy_privileged yum install -y \
      bc ca-certificates coreutils curl diffutils findutils gawk git gnupg2 grep gzip iproute jq \
      ncurses openssl procps-ng sed tar vim-common "${hardware_packages[@]}" || return 1
  else
    amaru_deploy_fail "Unsupported package manager; install bc, coreutils, curl, findutils, git, gpg, grep, gzip, iproute, jq, ncurses, OpenSSL 3 or newer, procps, sed, tar, and xxd"
    return 1
  fi
  amaru_deploy_ok "Amaru runtime prerequisites"
}

amaru_deploy_require_commands() {
  local command_name
  for command_name in awk cmp cp curl find git grep head install jq mktemp mv sed sha256sum tar xxd; do
    command -v "${command_name}" >/dev/null 2>&1 || {
      amaru_deploy_fail "Required command '${command_name}' is missing; re-run with -s p"
      return 1
    }
  done
  amaru_deploy_validate_openssl3 || {
    amaru_deploy_fail "${AMARU_DEPLOY_OPENSSL_ERROR}"
    return 1
  }
  [[ "${AMARU_DEPLOY_OPENSSL_BIN##*/}" != "openssl3" ]] ||
    amaru_deploy_info \
      "Using OpenSSL 3 compatibility executable: ${AMARU_DEPLOY_OPENSSL_BIN}"
}

amaru_deploy_fetch() {
  declare -F dispatcher_source_copy >/dev/null 2>&1 || {
    amaru_deploy_fail "Guild source snapshot helper is unavailable"
    return 1
  }
  dispatcher_source_copy "$1" "$2"
}

amaru_deploy_preflight_snapshot() {
  local environment_path=""
  local otel_path=""
  local release_path=""
  local -a shell_payloads source_payloads

  shell_payloads=(
    scripts/amaru-helper-scripts/amaru.sh
    scripts/common-helper-scripts/lib/deployment.library
    scripts/common-helper-scripts/lib/env.library
    scripts/common-helper-scripts/lib/node-api.library
    scripts/common-helper-scripts/lib/systemd.library
    scripts/amaru-helper-scripts/amaru.adapter
    scripts/common-helper-scripts/env
    scripts/common-helper-scripts/gLiveView.sh
    "files/configs/amaru/${NETWORK}/amaru.env"
  )
  source_payloads=(
    files/configs/amaru/otelcol.yaml
  )

  dispatcher_preflight_shell_payloads "${shell_payloads[@]}" || return 1
  dispatcher_preflight_source_payloads "${source_payloads[@]}" || return 1
  dispatcher_preflight_json_payloads \
    files/node-implementations/amaru/release.json || return 1
  if ! declare -F dispatcher_preflight_cntools_tree >/dev/null 2>&1 ||
     ! dispatcher_preflight_cntools_tree; then
    amaru_deploy_fail "CNTools tree preflight failed"
    return 1
  fi
  if ! declare -F dispatcher_preflight_cntools_launcher >/dev/null 2>&1 ||
     ! dispatcher_preflight_cntools_launcher; then
    amaru_deploy_fail "CNTools launcher preflight failed"
    return 1
  fi
  environment_path="$(
    dispatcher_source_path "files/configs/amaru/${NETWORK}/amaru.env"
  )" || return 1
  grep -Fq "AMARU_NETWORK=\"${NETWORK}\"" "${environment_path}" || {
    amaru_deploy_fail "Amaru environment failed network validation during preflight"
    return 1
  }
  otel_path="$(dispatcher_source_path 'files/configs/amaru/otelcol.yaml')" ||
    return 1
  grep -Fq 'endpoint: 127.0.0.1:8889' "${otel_path}" || {
    amaru_deploy_fail "Amaru collector configuration failed preflight validation"
    return 1
  }
  release_path="$(dispatcher_source_path 'files/node-implementations/amaru/release.json')" ||
    return 1
  amaru_deploy_validate_release_metadata "${release_path}" || {
    amaru_deploy_fail "Amaru release metadata failed preflight validation"
    return 1
  }
}

amaru_deploy_prepare_layout() {
  amaru_deploy_progress "Creating Amaru relay layout" "${NODE_HOME}"
  amaru_deploy_privileged mkdir -p \
    "${NODE_HOME}" \
    "${NODE_HOME}/files" \
    "${NODE_HOME}/logs" \
    "${NODE_HOME}/runtime" \
    "${NODE_HOME}/snapshots" \
    "${NODE_HOME}/scripts" \
    "${NODE_HOME}/scripts/adapters" \
    "${NODE_HOME}/scripts/archive" \
    "${NODE_HOME}/scripts/lib" || return 1

  local owner
  owner="$(id -u):$(id -g)"
  amaru_deploy_privileged chown "${owner}" \
    "${NODE_HOME}" \
    "${NODE_HOME}/files" \
    "${NODE_HOME}/logs" \
    "${NODE_HOME}/runtime" \
    "${NODE_HOME}/snapshots" \
    "${NODE_HOME}/scripts" \
    "${NODE_HOME}/scripts/adapters" \
    "${NODE_HOME}/scripts/archive" \
    "${NODE_HOME}/scripts/lib" || return 1

  # Do not create chain or ledger here. `amaru node bootstrap` intentionally
  # refuses to operate when either destination directory already exists.
  amaru_deploy_ok "Amaru relay layout" "${NODE_HOME}"
}

amaru_deploy_install_code_payload() {
  local relative_path="$1"
  local destination="$2"
  local mode="$3"
  local preserve_user_header="${4:-N}"
  local temporary backup merged
  temporary="$(mktemp "${destination}.tmp.XXXXXX")" || return 1
  if ! amaru_deploy_fetch "${relative_path}" "${temporary}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  bash -n "${temporary}" || {
    rm -f -- "${temporary}"
    amaru_deploy_fail "Shell validation failed for ${relative_path}"
    return 1
  }
  if [[ "${preserve_user_header}" == "Y" &&
        "${AMARU_DEPLOY_FORCE_SCRIPTS}" != "Y" &&
        -f "${destination}" ]]; then
    if grep -q '^# Do NOT modify code below' "${destination}" &&
       grep -q '^# Do NOT modify code below' "${temporary}"; then
      merged="$(mktemp "${destination}.merged.XXXXXX")" || {
        rm -f -- "${temporary}"
        return 1
      }
      awk '/^# Do NOT modify code below/{exit} {print}' "${destination}" > "${merged}"
      awk 'copy || /^# Do NOT modify code below/{copy=1; print}' "${temporary}" >> "${merged}"
      if ! bash -n "${merged}"; then
        rm -f -- "${temporary}" "${merged}"
        amaru_deploy_fail "Preserved user-variable block makes ${relative_path} invalid"
        return 1
      fi
      mv -f -- "${merged}" "${temporary}"
    fi
  fi
  if [[ -f "${destination}" ]] && cmp -s "${destination}" "${temporary}"; then
    rm -f -- "${temporary}"
    return 0
  fi
  if [[ -f "${destination}" ]]; then
    backup="${NODE_HOME}/scripts/archive/$(basename "${destination}").$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p -- "${destination}" "${backup}" || {
      rm -f -- "${temporary}"
      return 1
    }
  fi
  install -m "${mode}" "${temporary}" "${destination}" || {
    rm -f -- "${temporary}"
    return 1
  }
  rm -f -- "${temporary}"
}

amaru_deploy_render_environment() {
  local template_file="$1"
  local rendered_file="$2"
  local escaped_home escaped_service escaped_binary
  escaped_home="$(printf '%s' "${NODE_HOME}" | sed 's/[&|\\]/\\&/g')"
  escaped_service="$(printf '%s' "${NODE_SERVICE}" | sed 's/[&|\\]/\\&/g')"
  escaped_binary="$(printf '%s' "${HOME}/.local/bin/amaru" | sed 's/[&|\\]/\\&/g')"
  sed \
    -e "s|@NODE_HOME@|${escaped_home}|g" \
    -e "s|@NODE_SERVICE@|${escaped_service}|g" \
    -e "s|@BINARY_PATH@|${escaped_binary}|g" \
    -e "s|@NODE_PORT@|${NODE_PORT:-3000}|g" \
    "${template_file}" > "${rendered_file}"
}

amaru_deploy_install_environment() {
  local destination="${NODE_HOME}/scripts/amaru.env"
  local template rendered current_network=""
  template="$(mktemp "${NODE_HOME}/files/amaru-env-template.XXXXXX")" || return 1
  rendered="$(mktemp "${NODE_HOME}/scripts/amaru-env-rendered.XXXXXX")" || {
    rm -f -- "${template}"
    return 1
  }
  if ! amaru_deploy_fetch "files/configs/amaru/${NETWORK}/amaru.env" "${template}"; then
    rm -f -- "${template}" "${rendered}"
    return 1
  fi
  amaru_deploy_render_environment "${template}" "${rendered}" || {
    rm -f -- "${template}" "${rendered}"
    return 1
  }
  rm -f -- "${template}"

  if [[ -f "${destination}" ]]; then
    current_network="$(sed -n 's/^AMARU_NETWORK="\([^"]*\)".*/\1/p' "${destination}" | head -n 1)"
    if [[ -n "${current_network}" && "${current_network}" != "${NETWORK}" ]]; then
      if [[ -d "${NODE_HOME}/chain" || -d "${NODE_HOME}/ledger" ]]; then
        rm -f -- "${rendered}"
        amaru_deploy_fail "Refusing network change from ${current_network} to ${NETWORK} while Amaru state exists; use a new NODE_HOME"
        return 1
      fi
      if [[ "${AMARU_DEPLOY_FORCE_CONFIG}" != "Y" ]]; then
        rm -f -- "${rendered}"
        amaru_deploy_fail "Existing Amaru config targets ${current_network}; use -s f to replace it before bootstrap"
        return 1
      fi
    fi
    if [[ "${AMARU_DEPLOY_FORCE_CONFIG}" != "Y" ]]; then
      rm -f -- "${rendered}"
      amaru_deploy_info "Preserved existing ${destination}; use -s f to replace implementation config"
      return 0
    fi
    cp -p -- "${destination}" "${NODE_HOME}/scripts/archive/amaru.env.$(date -u +%Y%m%dT%H%M%SZ)" || {
      rm -f -- "${rendered}"
      return 1
    }
  fi
  install -m 0640 "${rendered}" "${destination}" || {
    rm -f -- "${rendered}"
    return 1
  }
  rm -f -- "${rendered}"
}

amaru_deploy_validate_release_metadata() {
  local manifest="$1"

  [[ -f "${manifest}" && ! -L "${manifest}" && -s "${manifest}" ]] ||
    return 1
  jq -e \
    --arg implementation "amaru" '
      def repository:
        type == "string" and
        . == "pragma-org/amaru";
      def selector:
        type == "string" and
        length > 0 and
        test("[[:space:]]") == false;
      def https_url:
        type == "string" and test("\\Ahttps://[^[:space:]]+\\z");
      def artifact:
        type == "object" and
        keys == ["sha256", "url"] and
        (.url | https_url) and
        (.sha256 | type == "string" and test("\\A[0-9a-f]{64}\\z"));
      type == "object" and
      keys == ["assets", "companions", "github", "implementation", "otelcol", "schemaVersion", "version"] and
      .schemaVersion == 1 and
      .implementation == $implementation and
      (.companions | type == "object" and keys == ["cardano-cli"]) and
      (.companions["cardano-cli"] | type == "object" and
        keys == ["artifacts", "version"] and
        (.version |
          type == "string" and
          test("\\A[0-9]+([.][0-9]+){2,3}\\z")) and
        (.artifacts | type == "object" and
          keys == ["linux-aarch64", "linux-x86_64"]) and
        all(.artifacts[]; artifact)) and
      (.otelcol | type == "object" and
        keys == ["artifacts", "version"] and
        (.version |
          type == "string" and
          test("\\A[0-9][0-9A-Za-z.+-]*\\z")) and
        (.artifacts | type == "object" and
          keys == ["linux-aarch64", "linux-x86_64"]) and
        all(.artifacts[]; artifact)) and
      .version == "latest" and
      (.github | repository) and
      (.assets | type == "object" and
        keys == ["linux-aarch64", "linux-x86_64"]) and
      all(.assets[]; selector)
    ' "${manifest}" >/dev/null
}

amaru_deploy_install_payloads() {
  amaru_deploy_progress "Refreshing Amaru scripts and configuration" "${BRANCH:-master}"
  amaru_deploy_install_code_payload \
    "scripts/amaru-helper-scripts/amaru.sh" \
    "${NODE_HOME}/scripts/amaru.sh" 0755 || return 1
  if ! declare -F dispatcher_install_common_runtime_bundle >/dev/null 2>&1; then
    amaru_deploy_fail "Common runtime transaction helper is unavailable; run this profile through guild-deploy.sh"
    return 1
  fi
  dispatcher_install_common_runtime_bundle \
    "amaru" "amaru_deploy_fetch" "${AMARU_DEPLOY_FORCE_SCRIPTS}" || return 1
  if ! declare -F dispatcher_install_cntools_tree >/dev/null 2>&1; then
    amaru_deploy_fail "CNTools tree transaction helper is unavailable; run this profile through guild-deploy.sh"
    return 1
  fi
  dispatcher_install_cntools_tree || return 1
  if ! declare -F dispatcher_install_cntools_launcher >/dev/null 2>&1; then
    amaru_deploy_fail "CNTools launcher transaction helper is unavailable; run this profile through guild-deploy.sh"
    return 1
  fi
  dispatcher_install_cntools_launcher || return 1
  amaru_deploy_install_code_payload \
    "scripts/common-helper-scripts/gLiveView.sh" \
    "${NODE_HOME}/scripts/gLiveView.sh" 0755 Y || return 1
  amaru_deploy_install_environment || return 1
  amaru_deploy_fetch \
    "files/configs/amaru/otelcol.yaml" \
    "${NODE_HOME}/files/otelcol.yaml" || return 1
  chmod 0644 "${NODE_HOME}/files/otelcol.yaml" || return 1

  local manifest_tmp
  manifest_tmp="$(mktemp "${NODE_HOME}/files/.amaru-release.json.tmp.XXXXXX")" ||
    return 1
  if ! amaru_deploy_fetch \
    "files/node-implementations/amaru/release.json" "${manifest_tmp}"; then
    rm -f -- "${manifest_tmp}"
    return 1
  fi
  if ! amaru_deploy_validate_release_metadata "${manifest_tmp}"; then
    rm -f -- "${manifest_tmp}"
    amaru_deploy_fail "Invalid Amaru release manifest"
    return 1
  fi
  if ! chmod 0644 "${manifest_tmp}" ||
     ! mv -f -- "${manifest_tmp}" "${NODE_HOME}/files/amaru-release.json"; then
    rm -f -- "${manifest_tmp}"
    amaru_deploy_fail "Could not atomically replace Amaru release metadata"
    return 1
  fi
  PROFILE_TARGET_NODE_VERSION="$(jq -er '.version' "${NODE_HOME}/files/amaru-release.json")" || return 1
  PROFILE_METRICS_PROVIDER="otel"
  PROFILE_CAP_N2C="false"
  PROFILE_CAP_LOCAL_CLI="false"
  PROFILE_CAP_METRICS="true"
  PROFILE_CAP_FORGING="false"
  amaru_deploy_ok "Amaru scripts and configuration"
}

amaru_deploy_architecture() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'linux-x86_64\n' ;;
    aarch64|arm64) printf 'linux-aarch64\n' ;;
    *) return 1 ;;
  esac
}

amaru_deploy_resolve_binary() {
  local manifest="$1"
  local architecture="$2"
  local repository selector

  declare -F dispatcher_resolve_github_release >/dev/null 2>&1 || {
    amaru_deploy_fail "The common GitHub release resolver is unavailable; refresh guild-deploy.sh"
    return 1
  }
  repository="$(jq -er '.github' "${manifest}")" || return 1
  selector="$(
    jq -er --arg arch "${architecture}" '.assets[$arch]' "${manifest}"
  )" || {
    amaru_deploy_fail "No Amaru release-asset selector is defined for ${architecture}"
    return 1
  }
  amaru_deploy_progress "Resolving newest published Amaru release" "${architecture}"
  dispatcher_resolve_github_release "amaru" "${repository}" "${selector}" ||
    return 1
  AMARU_RESOLVED_VERSION="${DISPATCHER_RELEASE_VERSION}"
  AMARU_RESOLVED_URL="${DISPATCHER_RELEASE_URL}"
  AMARU_RESOLVED_SHA256="${DISPATCHER_RELEASE_SHA256}"
  AMARU_RESOLVED_PRERELEASE="${DISPATCHER_RELEASE_PRERELEASE}"
}

amaru_deploy_resolve_cardano_cli() {
  local manifest="$1"
  local architecture="$2"

  jq -er --arg arch "${architecture}" '
    .companions["cardano-cli"] as $cli |
    [
      $cli.version,
      $cli.artifacts[$arch].url,
      $cli.artifacts[$arch].sha256
    ] | @tsv
  ' "${manifest}"
}

amaru_deploy_verify_cardano_cli_version() {
  local binary="$1"
  local expected_version="$2"
  local version_output

  version_output="$("${binary}" version 2>/dev/null)" || return 1
  grep -F "${expected_version}" <<< "${version_output}" >/dev/null
}

amaru_deploy_install_binary() (
  set -e
  amaru_deploy_require_commands

  local manifest="${NODE_HOME}/files/amaru-release.json"
  local architecture version url expected_sha
  local cli_version cli_url cli_expected_sha
  local collector_version collector_url collector_sha
  if ! amaru_deploy_validate_release_metadata "${manifest}"; then
    amaru_deploy_fail "Invalid installed Amaru release manifest"
    exit 1
  fi
  architecture="$(amaru_deploy_architecture)" || {
    amaru_deploy_fail "Unsupported Amaru architecture: $(uname -m)"
    exit 1
  }
  amaru_deploy_resolve_binary "${manifest}" "${architecture}" || exit 1
  version="${AMARU_RESOLVED_VERSION}"
  url="${AMARU_RESOLVED_URL}"
  expected_sha="${AMARU_RESOLVED_SHA256}"
  IFS=$'\t' read -r cli_version cli_url cli_expected_sha <<< "$(
    amaru_deploy_resolve_cardano_cli "${manifest}" "${architecture}"
  )"
  collector_version="$(jq -er '.otelcol.version' "${manifest}")"
  collector_url="$(jq -er --arg arch "${architecture}" '.otelcol.artifacts[$arch].url' "${manifest}")"
  collector_sha="$(jq -er --arg arch "${architecture}" '.otelcol.artifacts[$arch].sha256' "${manifest}")"

  local temporary_dir archive binary cli_archive cli_binary cli_member
  local collector_archive collector_binary archive_stamp
  temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/amaru-install.XXXXXX")"
  trap '[[ -z "${temporary_dir:-}" ]] || rm -rf -- "${temporary_dir}"' EXIT
  archive="${temporary_dir}/release.tar.gz"
  cli_archive="${temporary_dir}/cardano-cli.tar.gz"

  amaru_deploy_progress "Downloading Amaru ${version}" "${architecture}"
  curl --fail --silent --show-error --location \
    --connect-timeout "${CURL_TIMEOUT:-20}" \
    --max-time "${DOWNLOAD_TIMEOUT:-600}" \
    "${url}" --output "${archive}"
  if ! printf '%s  %s\n' "${expected_sha}" "${archive}" |
    sha256sum --check --status; then
    amaru_deploy_fail "Amaru ${version} archive failed SHA-256 verification"
    exit 1
  fi

  amaru_deploy_progress "Downloading cardano-cli for Amaru" "${cli_version}"
  curl --fail --silent --show-error --location \
    --connect-timeout "${CURL_TIMEOUT:-20}" \
    --max-time "${DOWNLOAD_TIMEOUT:-600}" \
    "${cli_url}" --output "${cli_archive}"
  if ! printf '%s  %s\n' "${cli_expected_sha}" "${cli_archive}" |
    sha256sum --check --status; then
    amaru_deploy_fail "cardano-cli ${cli_version} archive failed SHA-256 verification"
    exit 1
  fi

  mkdir "${temporary_dir}/extract"
  tar -xzf "${archive}" -C "${temporary_dir}/extract"
  binary="$(find "${temporary_dir}/extract" -type f -path '*/bin/amaru' -print -quit)"
  # The official release archive stores bin/amaru with mode 0644. Validate the
  # resolved release layout here; install(1) applies the executable mode below.
  [[ -n "${binary}" && -f "${binary}" ]] || {
    amaru_deploy_fail "Verified Amaru archive does not contain bin/amaru"
    exit 1
  }
  cli_member="cardano-cli-${architecture#linux-}-linux"
  tar -xzf "${cli_archive}" -C "${temporary_dir}/extract" "${cli_member}"
  cli_binary="${temporary_dir}/extract/${cli_member}"
  [[ -f "${cli_binary}" && ! -L "${cli_binary}" ]] || {
    amaru_deploy_fail "Verified cardano-cli archive does not contain ${cli_member}"
    exit 1
  }

  collector_archive="${temporary_dir}/otelcol-contrib.tar.gz"
  amaru_deploy_progress \
    "Downloading pinned OpenTelemetry Collector ${collector_version}" \
    "${architecture}"
  curl --fail --silent --show-error --location \
    --connect-timeout "${CURL_TIMEOUT:-20}" \
    --max-time "${DOWNLOAD_TIMEOUT:-600}" \
    "${collector_url}" --output "${collector_archive}"
  if ! printf '%s  %s\n' "${collector_sha}" "${collector_archive}" |
    sha256sum --check --status; then
    amaru_deploy_fail \
      "OpenTelemetry Collector ${collector_version} archive failed SHA-256 verification"
    exit 1
  fi

  mkdir "${temporary_dir}/collector"
  tar -xzf "${collector_archive}" -C "${temporary_dir}/collector"
  collector_binary="$(
    find "${temporary_dir}/collector" -type f -name otelcol-contrib -print -quit
  )"
  [[ -n "${collector_binary}" && -f "${collector_binary}" ]] || {
    amaru_deploy_fail \
      "Verified OpenTelemetry Collector archive does not contain otelcol-contrib"
    exit 1
  }

  chmod 0755 "${binary}" "${cli_binary}" "${collector_binary}"
  "${binary}" --version | grep -F "${version}" >/dev/null || {
    amaru_deploy_fail "Staged Amaru binary does not report resolved version ${version}"
    exit 1
  }
  amaru_deploy_verify_cardano_cli_version \
    "${cli_binary}" "${cli_version}" || {
    amaru_deploy_fail "Staged cardano-cli does not report manifest version ${cli_version}"
    exit 1
  }
  "${collector_binary}" --version | grep -F "${collector_version}" >/dev/null || {
    amaru_deploy_fail \
      "Staged OpenTelemetry Collector does not report manifest version ${collector_version}"
    exit 1
  }

  mkdir -p "${HOME}/.local/bin" "${HOME}/.local/bin/archive"
  archive_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ -f "${HOME}/.local/bin/amaru" ]]; then
    cp -p -- "${HOME}/.local/bin/amaru" \
      "${HOME}/.local/bin/archive/amaru.${archive_stamp}"
  fi
  if [[ -f "${HOME}/.local/bin/cardano-cli-amaru" ]]; then
    cp -p -- "${HOME}/.local/bin/cardano-cli-amaru" \
      "${HOME}/.local/bin/archive/cardano-cli-amaru.${archive_stamp}"
  fi
  if [[ -f "${HOME}/.local/bin/otelcol-contrib" ]]; then
    cp -p -- "${HOME}/.local/bin/otelcol-contrib" \
      "${HOME}/.local/bin/archive/otelcol-contrib.${archive_stamp}"
  fi
  install -m 0755 "${binary}" "${HOME}/.local/bin/amaru"
  install -m 0755 "${cli_binary}" "${HOME}/.local/bin/cardano-cli-amaru"
  install -m 0755 "${collector_binary}" "${HOME}/.local/bin/otelcol-contrib"
  amaru_deploy_ok "Installed verified Amaru" "${version}"
  amaru_deploy_ok \
    "Installed Amaru cardano-cli companion" \
    "${cli_version} as cardano-cli-amaru"
  amaru_deploy_ok \
    "Installed verified OpenTelemetry Collector" "${collector_version}"
)

amaru_deploy_show_next_steps() {
  if [[ ! -e "${NODE_HOME}/chain" && ! -e "${NODE_HOME}/ledger" ]]; then
    amaru_deploy_info \
      "Bootstrap node state: ${NODE_HOME}/scripts/amaru.sh bootstrap"
  fi
  if ! dispatcher_systemd_unit_installed "${NODE_SERVICE}.service" ||
     ! dispatcher_systemd_unit_installed "${NODE_SERVICE}-metrics.service"; then
    amaru_deploy_info \
      "Deploy the systemd services: ${NODE_HOME}/scripts/amaru.sh -d"
  fi
}

deploy_amaru_profile() {
  amaru_deploy_validate_context || return 1
  amaru_deploy_parse_flags || return 1

  amaru_deploy_warn "Amaru deployment is experimental, relay-only, and limited to ${NETWORK}."
  if [[ "${AMARU_DEPLOY_INSTALL_DEPS}" == "Y" ]]; then
    amaru_deploy_install_dependencies || return 1
  fi
  amaru_deploy_require_commands || return 1
  amaru_deploy_preflight_snapshot || return 1
  amaru_deploy_prepare_layout || return 1
  if declare -F dispatcher_mark_in_progress >/dev/null 2>&1; then
    dispatcher_mark_in_progress || return 1
  fi
  amaru_deploy_install_payloads || return 1
  if [[ "${AMARU_DEPLOY_INSTALL_BINARY}" == "Y" ]]; then
    amaru_deploy_install_binary || return 1
  fi
  if [[ "${AMARU_DEPLOY_INSTALL_HWCLI}" == "Y" ]]; then
    declare -F dispatcher_install_cardano_hw_cli >/dev/null 2>&1 || {
      amaru_deploy_fail "Common cardano-hw-cli installer is unavailable; refresh guild-deploy.sh"
      return 1
    }
    dispatcher_install_cardano_hw_cli || return 1
  fi

  if [[ ! -x "${HOME}/.local/bin/amaru" ]]; then
    amaru_deploy_warn "Amaru binary is not installed; re-run with -s d."
  fi
  if [[ ! -x "${HOME}/.local/bin/otelcol-contrib" ]]; then
    amaru_deploy_warn \
      "OpenTelemetry Collector is not installed; re-run with -s d before using gLiveView."
  fi
  if [[ ! -x "${HOME}/.local/bin/cardano-cli-amaru" ]]; then
    amaru_deploy_warn \
      "Amaru cardano-cli companion is not installed; re-run with -s d before using CNTools transaction or wallet operations."
  fi
  amaru_deploy_show_next_steps
}
