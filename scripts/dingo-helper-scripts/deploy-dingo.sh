#!/usr/bin/env bash
# Source-only Dingo deployment profile for the common guild-deploy dispatcher.
# shellcheck disable=SC2034,SC2154

dingo_deploy_info() {
  if declare -F log_info >/dev/null 2>&1; then log_info "$1"; else printf 'INFO: %s\n' "$1"; fi
}

dingo_deploy_warn() {
  if declare -F log_warn >/dev/null 2>&1; then log_warn "$1"; else printf 'WARN: %s\n' "$1" >&2; fi
}

dingo_deploy_progress() {
  if declare -F log_progress >/dev/null 2>&1; then log_progress "$1" "${2:-}"; else printf '  .. %s%s\n' "$1" "$([[ -n "${2:-}" ]] && printf ' (%s)' "$2")"; fi
}

dingo_deploy_ok() {
  if declare -F log_ok >/dev/null 2>&1; then log_ok "$1" "${2:-}"; else printf '  OK %s%s\n' "$1" "$([[ -n "${2:-}" ]] && printf ' (%s)' "$2")"; fi
}

dingo_deploy_fail() {
  if declare -F err_exit >/dev/null 2>&1; then
    err_exit "$1"
  else
    printf 'ERROR: %s\n' "$1" >&2
  fi
  return 1
}

dingo_deploy_privileged() {
  if [[ -n "${sudo:-}" ]]; then
    ${sudo} "$@"
  elif [[ "${SUDO:-Y}" == "Y" ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

dingo_deploy_validate_context() {
  [[ "${NODE_IMPLEMENTATION:-}" == "dingo" ]] || {
    dingo_deploy_fail "Dingo profile was selected with NODE_IMPLEMENTATION='${NODE_IMPLEMENTATION:-unset}'"
    return 1
  }
  case "${NETWORK:-}" in
    preprod|preview) ;;
    *)
      dingo_deploy_fail "Experimental Dingo deployment supports only preprod or preview (got '${NETWORK:-unset}')"
      return 1
      ;;
  esac
  [[ "${NODE_HOME:-}" =~ ^/[A-Za-z0-9._/+@:-]+$ ]] || {
    dingo_deploy_fail "NODE_HOME must be an absolute path containing only deployment-safe characters"
    return 1
  }
  [[ "${NODE_SERVICE:-}" =~ ^[A-Za-z0-9_.@-]+$ ]] || {
    dingo_deploy_fail "Invalid NODE_SERVICE '${NODE_SERVICE:-unset}'"
    return 1
  }
  [[ "${HOME:-}" =~ ^/[A-Za-z0-9._/+@:-]+$ ]] || {
    dingo_deploy_fail "HOME must be an absolute path containing only deployment-safe characters"
    return 1
  }
  local configured_port="${NODE_PORT:-3001}"
  if [[ ! "${configured_port}" =~ ^[0-9]+$ ]] ||
     (( 10#${configured_port} < 1 || 10#${configured_port} > 65535 )); then
    dingo_deploy_fail "NODE_PORT must be an integer from 1 to 65535"
    return 1
  fi
  NODE_PORT="$((10#${configured_port}))"
  [[ "$(uname -s)" == "Linux" ]] || {
    dingo_deploy_fail "The Dingo deployment profile currently supports Linux only"
    return 1
  }
}

dingo_deploy_parse_flags() {
  DINGO_DEPLOY_INSTALL_DEPS="N"
  DINGO_DEPLOY_INSTALL_BINARY="N"
  DINGO_DEPLOY_FORCE_CONFIG="N"
  DINGO_DEPLOY_FORCE_SCRIPTS="N"

  local unsupported="${S_ARGS:-}"
  unsupported="${unsupported//[pdfs]/}"
  [[ -z "${unsupported}" ]] || {
    dingo_deploy_fail "Unsupported Dingo -s flag(s): '${unsupported}'. Allowed: p,d,f,s; cnode-only b,l,m,c,o,w,x,r are rejected."
    return 1
  }

  [[ "${S_ARGS:-}" == *p* ]] && DINGO_DEPLOY_INSTALL_DEPS="Y"
  [[ "${S_ARGS:-}" == *d* ]] && DINGO_DEPLOY_INSTALL_BINARY="Y"
  [[ "${S_ARGS:-}" == *f* ]] && DINGO_DEPLOY_FORCE_CONFIG="Y"
  [[ "${S_ARGS:-}" == *s* ]] && DINGO_DEPLOY_FORCE_SCRIPTS="Y"
  return 0
}

dingo_deploy_install_dependencies() {
  dingo_deploy_progress "Installing Dingo runtime prerequisites"
  if command -v apt-get >/dev/null 2>&1; then
    dispatcher_run_package_command "Dingo package metadata update" \
      dingo_deploy_privileged apt-get \
      -o Dpkg::Use-Pty=0 -o APT::Color=0 update || return 1
    dispatcher_run_package_command "Dingo prerequisite package installation" \
      dingo_deploy_privileged env DEBIAN_FRONTEND=noninteractive apt-get \
      -o Dpkg::Use-Pty=0 -o APT::Color=0 install -y \
      bc bsdmainutils ca-certificates coreutils curl diffutils e2fsprogs findutils \
      gawk git gnupg grep gzip iproute2 jq less ncurses-bin procps sed sqlite3 tar \
      unzip xxd || return 1
  elif command -v dnf >/dev/null 2>&1; then
    dispatcher_run_package_command "Dingo prerequisite package installation" \
      dingo_deploy_privileged dnf install -y \
      bc ca-certificates coreutils curl diffutils e2fsprogs findutils gawk git gnupg2 \
      grep gzip iproute jq less ncurses procps-ng sed sqlite tar unzip util-linux \
      vim-common || return 1
  elif command -v yum >/dev/null 2>&1; then
    dispatcher_run_package_command "Dingo prerequisite package installation" \
      dingo_deploy_privileged yum install -y \
      bc ca-certificates coreutils curl diffutils e2fsprogs findutils gawk git gnupg2 \
      grep gzip iproute jq less ncurses procps-ng sed sqlite tar unzip util-linux \
      vim-common || return 1
  else
    dingo_deploy_fail "Unsupported package manager; install bc, chattr, column, coreutils, curl, findutils, gawk, git, gpg, grep, gzip, iproute, jq, less, ncurses, procps, sed, sqlite3, tar, unzip, and xxd"
    return 1
  fi
  dingo_deploy_ok "Dingo runtime prerequisites"
}

dingo_deploy_require_commands() {
  local command_name
  for command_name in awk cmp cp curl find git grep head install jq mktemp mv sed sha256sum tar; do
    command -v "${command_name}" >/dev/null 2>&1 || {
      dingo_deploy_fail "Required command '${command_name}' is missing; re-run with -s p"
      return 1
    }
  done
}

dingo_deploy_fetch() {
  declare -F dispatcher_source_copy >/dev/null 2>&1 || {
    dingo_deploy_fail "Guild source snapshot helper is unavailable"
    return 1
  }
  dispatcher_source_copy "$1" "$2"
}

dingo_deploy_preflight_snapshot() {
  local release_path=""
  local dingo_config=""
  local dingo_environment=""
  local -a shell_payloads source_payloads

  shell_payloads=(
    scripts/dingo-helper-scripts/dingo.sh
    scripts/common-helper-scripts/lib/deployment.library
    scripts/common-helper-scripts/lib/env.library
    scripts/common-helper-scripts/lib/node-api.library
    scripts/common-helper-scripts/lib/systemd.library
    scripts/dingo-helper-scripts/dingo.adapter
    scripts/common-helper-scripts/env
    scripts/common-helper-scripts/gLiveView.sh
    scripts/common-helper-scripts/cntools.library
    scripts/common-helper-scripts/cntools.sh
    "files/configs/dingo/${NETWORK}/dingo.env"
  )
  source_payloads=(
    "files/configs/dingo/${NETWORK}/dingo.yaml"
  )

  GUILD_DEPLOY_PREFLIGHT_BASH_BIN="${DINGO_DEPLOY_BASH_BIN:-bash}" \
    dispatcher_preflight_shell_payloads "${shell_payloads[@]}" || return 1
  dispatcher_preflight_source_payloads "${source_payloads[@]}" || return 1
  dispatcher_preflight_json_payloads \
    files/node-implementations/dingo/release.json || return 1
  dingo_config="$(dispatcher_source_path "${source_payloads[0]}")" || return 1
  grep -Fq "network: \"${NETWORK}\"" "${dingo_config}" || {
    dingo_deploy_fail "Dingo configuration failed network validation during preflight"
    return 1
  }
  dingo_environment="$(
    dispatcher_source_path "files/configs/dingo/${NETWORK}/dingo.env"
  )" || return 1
  grep -Fq "CARDANO_NETWORK=\"${NETWORK}\"" "${dingo_environment}" || {
    dingo_deploy_fail "Dingo environment failed network validation during preflight"
    return 1
  }
  release_path="$(dispatcher_source_path 'files/node-implementations/dingo/release.json')" ||
    return 1
  dingo_deploy_validate_release_metadata "${release_path}" || {
    dingo_deploy_fail "Dingo release metadata failed preflight validation"
    return 1
  }
}

dingo_deploy_prepare_layout() {
  dingo_deploy_progress "Creating Dingo node layout" "${NODE_HOME}"
  dingo_deploy_privileged mkdir -p \
    "${NODE_HOME}" \
    "${NODE_HOME}/db" \
    "${NODE_HOME}/files" \
    "${NODE_HOME}/logs" \
    "${NODE_HOME}/priv/pool" \
    "${NODE_HOME}/snapshots" \
    "${NODE_HOME}/sockets" \
    "${NODE_HOME}/scripts" \
    "${NODE_HOME}/scripts/adapters" \
    "${NODE_HOME}/scripts/archive" \
    "${NODE_HOME}/scripts/lib" || return 1

  local owner
  owner="$(id -u):$(id -g)"
  dingo_deploy_privileged chown "${owner}" \
    "${NODE_HOME}" \
    "${NODE_HOME}/db" \
    "${NODE_HOME}/files" \
    "${NODE_HOME}/logs" \
    "${NODE_HOME}/priv" \
    "${NODE_HOME}/priv/pool" \
    "${NODE_HOME}/snapshots" \
    "${NODE_HOME}/sockets" \
    "${NODE_HOME}/scripts" \
    "${NODE_HOME}/scripts/adapters" \
    "${NODE_HOME}/scripts/archive" \
    "${NODE_HOME}/scripts/lib" || return 1
  dingo_deploy_privileged chmod 0700 \
    "${NODE_HOME}/priv" "${NODE_HOME}/priv/pool" || return 1
  dingo_deploy_ok "Dingo node layout" "${NODE_HOME}"
}

dingo_deploy_install_code_payload() {
  local relative_path="$1"
  local destination="$2"
  local mode="$3"
  local preserve_user_header="${4:-N}"
  local temporary backup merged
  temporary="$(mktemp "${destination}.tmp.XXXXXX")" || return 1
  if ! dingo_deploy_fetch "${relative_path}" "${temporary}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  "${DINGO_DEPLOY_BASH_BIN:-bash}" -n "${temporary}" || {
    rm -f -- "${temporary}"
    dingo_deploy_fail "Shell validation failed for ${relative_path}"
    return 1
  }
  if [[ "${preserve_user_header}" == "Y" &&
        "${DINGO_DEPLOY_FORCE_SCRIPTS}" != "Y" &&
        -f "${destination}" ]]; then
    if grep -q '^# Do NOT modify code below' "${destination}" &&
       grep -q '^# Do NOT modify code below' "${temporary}"; then
      merged="$(mktemp "${destination}.merged.XXXXXX")" || {
        rm -f -- "${temporary}"
        return 1
      }
      awk '/^# Do NOT modify code below/{exit} {print}' "${destination}" > "${merged}"
      awk 'copy || /^# Do NOT modify code below/{copy=1; print}' "${temporary}" >> "${merged}"
      if ! "${DINGO_DEPLOY_BASH_BIN:-bash}" -n "${merged}"; then
        rm -f -- "${temporary}" "${merged}"
        dingo_deploy_fail "Preserved user-variable block makes ${relative_path} invalid"
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

dingo_deploy_render_file() {
  local template_file="$1"
  local rendered_file="$2"
  local escaped_home escaped_service escaped_binary
  escaped_home="$(printf '%s' "${NODE_HOME}" | sed 's/[&|\\]/\\&/g')"
  escaped_service="$(printf '%s' "${NODE_SERVICE}" | sed 's/[&|\\]/\\&/g')"
  escaped_binary="$(printf '%s' "${HOME}/.local/bin/dingo" | sed 's/[&|\\]/\\&/g')"
  sed \
    -e "s|@NODE_HOME@|${escaped_home}|g" \
    -e "s|@NODE_SERVICE@|${escaped_service}|g" \
    -e "s|@BINARY_PATH@|${escaped_binary}|g" \
    -e "s|\"@NODE_PORT@\"|${NODE_PORT:-3001}|g" \
    "${template_file}" > "${rendered_file}"
}

dingo_deploy_install_config_file() {
  local payload_name="$1"
  local destination="$2"
  local mode="$3"
  local template rendered
  template="$(mktemp "${NODE_HOME}/files/dingo-template.XXXXXX")" || return 1
  rendered="$(mktemp "${NODE_HOME}/files/dingo-rendered.XXXXXX")" || {
    rm -f -- "${template}"
    return 1
  }
  if ! dingo_deploy_fetch "files/configs/dingo/${NETWORK}/${payload_name}" "${template}"; then
    rm -f -- "${template}" "${rendered}"
    return 1
  fi
  dingo_deploy_render_file "${template}" "${rendered}" || {
    rm -f -- "${template}" "${rendered}"
    return 1
  }
  rm -f -- "${template}"

  if [[ -f "${destination}" && "${DINGO_DEPLOY_FORCE_CONFIG}" != "Y" ]]; then
    rm -f -- "${rendered}"
    dingo_deploy_info "Preserved existing ${destination}; use -s f to replace implementation config"
    return 0
  fi
  if [[ -f "${destination}" ]]; then
    cp -p -- "${destination}" \
      "${NODE_HOME}/scripts/archive/$(basename "${destination}").$(date -u +%Y%m%dT%H%M%SZ)" || {
      rm -f -- "${rendered}"
      return 1
    }
  fi
  install -m "${mode}" "${rendered}" "${destination}" || {
    rm -f -- "${rendered}"
    return 1
  }
  rm -f -- "${rendered}"
}

dingo_deploy_check_network_change() {
  local current_network=""
  if [[ -f "${NODE_HOME}/scripts/dingo.env" ]]; then
    current_network="$(sed -n 's/^CARDANO_NETWORK="\([^"]*\)".*/\1/p' "${NODE_HOME}/scripts/dingo.env" | head -n 1)"
  elif [[ -f "${NODE_HOME}/files/dingo.yaml" ]]; then
    current_network="$(sed -n 's/^[[:space:]]*network:[[:space:]]*"\([^"]*\)".*/\1/p' "${NODE_HOME}/files/dingo.yaml" | head -n 1)"
  fi
  [[ -z "${current_network}" || "${current_network}" == "${NETWORK}" ]] && return 0

  if find "${NODE_HOME}/db" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    dingo_deploy_fail "Refusing network change from ${current_network} to ${NETWORK} while Dingo state exists; use a new NODE_HOME"
    return 1
  fi
  if [[ "${DINGO_DEPLOY_FORCE_CONFIG}" != "Y" ]]; then
    dingo_deploy_fail "Existing Dingo config targets ${current_network}; use -s f to replace it before bootstrap"
    return 1
  fi
}

dingo_deploy_validate_release_metadata() {
  local manifest="$1"

  [[ -f "${manifest}" && ! -L "${manifest}" && -s "${manifest}" ]] ||
    return 1
  jq -e \
    --arg implementation "dingo" '
      def repository:
        type == "string" and
        . == "blinklabs-io/dingo";
      def selector:
        type == "string" and
        length > 0 and
        test("[[:space:]]") == false;
      def artifact:
        type == "object" and
        keys == ["sha256", "url"] and
        (.url | type == "string" and startswith("https://")) and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$"));
      type == "object" and
      keys == ["assets", "companions", "github", "implementation", "schemaVersion", "version"] and
      .schemaVersion == 1 and
      .implementation == $implementation and
      .version == "latest" and
      (.github | repository) and
      (.assets | type == "object" and
        keys == ["linux-aarch64", "linux-x86_64"]) and
      all(.assets[]; selector) and
      (.companions | type == "object" and keys == ["cardano-cli"]) and
      (.companions["cardano-cli"] | type == "object" and
        keys == ["artifacts", "version"] and
        (.version | type == "string" and test("^[0-9]+([.][0-9]+){2,3}$")) and
        (.artifacts | type == "object" and
          keys == ["linux-aarch64", "linux-x86_64"]) and
        all(.artifacts[]; artifact))
    ' "${manifest}" >/dev/null
}

dingo_deploy_install_payloads() {
  dingo_deploy_progress "Refreshing Dingo scripts and configuration" "${BRANCH:-master}"
  dingo_deploy_install_code_payload \
    "scripts/dingo-helper-scripts/dingo.sh" \
    "${NODE_HOME}/scripts/dingo.sh" 0755 || return 1
  if ! declare -F dispatcher_install_common_runtime_bundle >/dev/null 2>&1; then
    dingo_deploy_fail "Common runtime transaction helper is unavailable; run this profile through guild-deploy.sh"
    return 1
  fi
  dispatcher_install_common_runtime_bundle \
    "dingo" "dingo_deploy_fetch" "${DINGO_DEPLOY_FORCE_SCRIPTS}" || return 1
  dingo_deploy_install_code_payload \
    "scripts/common-helper-scripts/gLiveView.sh" \
    "${NODE_HOME}/scripts/gLiveView.sh" 0755 Y || return 1
  dingo_deploy_install_code_payload \
    "scripts/common-helper-scripts/cntools.library" \
    "${NODE_HOME}/scripts/cntools.library" 0644 || return 1
  dingo_deploy_install_code_payload \
    "scripts/common-helper-scripts/cntools.sh" \
    "${NODE_HOME}/scripts/cntools.sh" 0755 Y || return 1
  dingo_deploy_check_network_change || return 1
  dingo_deploy_install_config_file "dingo.yaml" "${NODE_HOME}/files/dingo.yaml" 0640 || return 1
  dingo_deploy_install_config_file "dingo.env" "${NODE_HOME}/scripts/dingo.env" 0640 || return 1

  local manifest_tmp
  manifest_tmp="$(mktemp "${NODE_HOME}/files/.dingo-release.json.tmp.XXXXXX")" ||
    return 1
  if ! dingo_deploy_fetch \
    "files/node-implementations/dingo/release.json" "${manifest_tmp}"; then
    rm -f -- "${manifest_tmp}"
    return 1
  fi
  if ! dingo_deploy_validate_release_metadata "${manifest_tmp}"; then
    rm -f -- "${manifest_tmp}"
    dingo_deploy_fail "Invalid Dingo release manifest"
    return 1
  fi
  if ! chmod 0644 "${manifest_tmp}" ||
     ! mv -f -- "${manifest_tmp}" "${NODE_HOME}/files/dingo-release.json"; then
    rm -f -- "${manifest_tmp}"
    dingo_deploy_fail "Could not atomically replace Dingo release metadata"
    return 1
  fi
  PROFILE_TARGET_NODE_VERSION="$(jq -er '.version' "${NODE_HOME}/files/dingo-release.json")" || return 1
  PROFILE_METRICS_PROVIDER="prometheus"
  PROFILE_CAP_N2C="true"
  PROFILE_CAP_LOCAL_CLI="true"
  PROFILE_CAP_METRICS="true"
  PROFILE_CAP_FORGING="true"
  dingo_deploy_ok "Dingo scripts and configuration"
}

dingo_deploy_architecture() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'linux-x86_64\n' ;;
    aarch64|arm64) printf 'linux-aarch64\n' ;;
    *) return 1 ;;
  esac
}

dingo_deploy_resolve_binary() {
  local manifest="$1"
  local architecture="$2"
  local repository selector

  declare -F dispatcher_resolve_github_release >/dev/null 2>&1 || {
    dingo_deploy_fail "The common GitHub release resolver is unavailable; refresh guild-deploy.sh"
    return 1
  }
  repository="$(jq -er '.github' "${manifest}")" || return 1
  selector="$(
    jq -er --arg arch "${architecture}" '.assets[$arch]' "${manifest}"
  )" || {
    dingo_deploy_fail "No Dingo release-asset selector is defined for ${architecture}"
    return 1
  }
  dingo_deploy_progress "Resolving newest published Dingo release" "${architecture}"
  dispatcher_resolve_github_release "dingo" "${repository}" "${selector}" ||
    return 1
  DINGO_RESOLVED_VERSION="${DISPATCHER_RELEASE_VERSION}"
  DINGO_RESOLVED_URL="${DISPATCHER_RELEASE_URL}"
  DINGO_RESOLVED_SHA256="${DISPATCHER_RELEASE_SHA256}"
  DINGO_RESOLVED_PRERELEASE="${DISPATCHER_RELEASE_PRERELEASE}"
}

dingo_deploy_resolve_cardano_cli() {
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

dingo_deploy_verify_binary_version() {
  local binary="$1"
  local expected_version="$2"
  local version_output

  version_output="$("${binary}" version 2>/dev/null)" || return 1
  grep -F "${expected_version}" <<< "${version_output}" >/dev/null
}

dingo_deploy_install_binary() (
  set -e
  dingo_deploy_require_commands

  local manifest="${NODE_HOME}/files/dingo-release.json"
  local architecture version url expected_sha
  local cli_version cli_url cli_expected_sha
  if ! dingo_deploy_validate_release_metadata "${manifest}"; then
    dingo_deploy_fail "Invalid installed Dingo release manifest"
    exit 1
  fi
  architecture="$(dingo_deploy_architecture)" || {
    dingo_deploy_fail "Unsupported Dingo architecture: $(uname -m)"
    exit 1
  }
  dingo_deploy_resolve_binary "${manifest}" "${architecture}" || exit 1
  version="${DINGO_RESOLVED_VERSION}"
  url="${DINGO_RESOLVED_URL}"
  expected_sha="${DINGO_RESOLVED_SHA256}"
  IFS=$'\t' read -r cli_version cli_url cli_expected_sha <<< "$(
    dingo_deploy_resolve_cardano_cli "${manifest}" "${architecture}"
  )"

  local temporary_dir archive binary cli_archive cli_binary cli_member archive_stamp
  temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/dingo-install.XXXXXX")"
  trap '[[ -z "${temporary_dir:-}" ]] || rm -rf -- "${temporary_dir}"' EXIT
  archive="${temporary_dir}/release.tar.gz"
  cli_archive="${temporary_dir}/cardano-cli.tar.gz"

  dingo_deploy_progress "Downloading Dingo ${version}" "${architecture}"
  curl --fail --silent --show-error --location \
    --connect-timeout "${CURL_TIMEOUT:-20}" \
    --max-time "${DOWNLOAD_TIMEOUT:-600}" \
    "${url}" --output "${archive}"
  if ! printf '%s  %s\n' "${expected_sha}" "${archive}" |
    sha256sum --check --status; then
    dingo_deploy_fail "Dingo ${version} archive failed SHA-256 verification"
    exit 1
  fi

  dingo_deploy_progress "Downloading cardano-cli for Dingo" "${cli_version}"
  curl --fail --silent --show-error --location \
    --connect-timeout "${CURL_TIMEOUT:-20}" \
    --max-time "${DOWNLOAD_TIMEOUT:-600}" \
    "${cli_url}" --output "${cli_archive}"
  if ! printf '%s  %s\n' "${cli_expected_sha}" "${cli_archive}" |
    sha256sum --check --status; then
    dingo_deploy_fail "cardano-cli ${cli_version} archive failed SHA-256 verification"
    exit 1
  fi

  mkdir "${temporary_dir}/extract"
  tar -xzf "${archive}" -C "${temporary_dir}/extract"
  binary="${temporary_dir}/extract/dingo"
  [[ -f "${binary}" && ! -L "${binary}" ]] || {
    dingo_deploy_fail "Verified Dingo archive does not contain the dingo executable"
    exit 1
  }
  cli_member="cardano-cli-${architecture#linux-}-linux"
  tar -xzf "${cli_archive}" -C "${temporary_dir}/extract" "${cli_member}"
  cli_binary="${temporary_dir}/extract/${cli_member}"
  [[ -f "${cli_binary}" && ! -L "${cli_binary}" ]] || {
    dingo_deploy_fail "Verified cardano-cli archive does not contain ${cli_member}"
    exit 1
  }
  chmod 0755 "${binary}" "${cli_binary}"
  dingo_deploy_verify_binary_version "${binary}" "${version}" || {
    dingo_deploy_fail "Staged Dingo binary does not report resolved version ${version}"
    exit 1
  }
  dingo_deploy_verify_binary_version "${cli_binary}" "${cli_version}" || {
    dingo_deploy_fail "Staged cardano-cli does not report manifest version ${cli_version}"
    exit 1
  }

  mkdir -p "${HOME}/.local/bin" "${HOME}/.local/bin/archive"
  archive_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ -f "${HOME}/.local/bin/dingo" ]]; then
    cp -p -- "${HOME}/.local/bin/dingo" \
      "${HOME}/.local/bin/archive/dingo.${archive_stamp}"
  fi
  if [[ -f "${HOME}/.local/bin/cardano-cli-dingo" ]]; then
    cp -p -- "${HOME}/.local/bin/cardano-cli-dingo" \
      "${HOME}/.local/bin/archive/cardano-cli-dingo.${archive_stamp}"
  fi
  install -m 0755 "${binary}" "${HOME}/.local/bin/dingo"
  install -m 0755 "${cli_binary}" "${HOME}/.local/bin/cardano-cli-dingo"
  dingo_deploy_ok "Installed verified Dingo" "${version}"
  dingo_deploy_ok "Installed Dingo cardano-cli companion" "${cli_version} as cardano-cli-dingo"
)

dingo_deploy_show_next_steps() {
  if ! dispatcher_directory_has_entries "${NODE_HOME}/db"; then
    dingo_deploy_info \
      "Bootstrap node state: ${NODE_HOME}/scripts/dingo.sh bootstrap"
  fi
  if ! dispatcher_systemd_unit_installed "${NODE_SERVICE}.service"; then
    dingo_deploy_info \
      "Deploy the systemd service: ${NODE_HOME}/scripts/dingo.sh -d"
  fi
}

deploy_dingo_profile() {
  dingo_deploy_validate_context || return 1
  dingo_deploy_parse_flags || return 1

  dingo_deploy_warn "Dingo deployment and block production are experimental and limited to ${NETWORK}."
  if [[ "${DINGO_DEPLOY_INSTALL_DEPS}" == "Y" ]]; then
    dingo_deploy_install_dependencies || return 1
  fi
  dingo_deploy_require_commands || return 1
  dingo_deploy_preflight_snapshot || return 1
  dingo_deploy_prepare_layout || return 1
  if declare -F dispatcher_mark_in_progress >/dev/null 2>&1; then
    dispatcher_mark_in_progress || return 1
  fi
  dingo_deploy_install_payloads || return 1
  if [[ "${DINGO_DEPLOY_INSTALL_BINARY}" == "Y" ]]; then
    dingo_deploy_install_binary || return 1
  fi

  if [[ ! -x "${HOME}/.local/bin/dingo" ]]; then
    dingo_deploy_warn "Dingo binary is not installed; re-run with -s d."
  fi
  if [[ ! -x "${HOME}/.local/bin/cardano-cli-dingo" ]]; then
    dingo_deploy_warn "Dingo cardano-cli companion is not installed; re-run with -s d."
  fi
  dingo_deploy_show_next_steps
  dingo_deploy_warn "Dingo metrics share the public bind address; protect TCP 12798 with a firewall."
}
