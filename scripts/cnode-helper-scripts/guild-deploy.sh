#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2154,SC2317
# shellcheck source=/dev/null

##########################################
# User Variables - Change as desired     #
# command line flags override set values #
##########################################
#G_ACCOUNT="cardano-community"       # Override GitHub account if using a fork
#NODE_IMPLEMENTATION="cnode"         # cnode | dingo | amaru
#NETWORK="mainnet"                   # Network selected for the node implementation
#BRANCH="master"                     # Guild Operators repository branch
#NODE_PARENT="/opt/cardano"          # Parent directory for the node installation
#NODE_NAME="cnode"                   # Top-level directory/service name
#NODE_PORT=                           # Node-to-node port (Default: cnode 6000, dingo 3001, amaru 3000)
#CURL_TIMEOUT=60                     # Download timeout in seconds
#DOWNLOAD_TIMEOUT=600                # Large binary download timeout in seconds
#UPDATE_CHECK="Y"                    # Check this dispatcher for updates
#SUDO="Y"                            # Set to N in containers already running as root
#PACKAGE_MANAGER_OUTPUT="compact"    # compact | verbose
#GUILD_SOURCE_MODE="managed"         # managed | cached | local
#GUILD_SOURCE_CHECKOUT=""             # Absolute checkout path required by local mode
#GUILD_SOURCE_ALLOW_DIRTY="N"         # Allow an explicitly selected dirty local checkout
#GUILD_SOURCE_ALLOW_REPOSITORY_CHANGE="N" # Allow an existing target to move to another fork
#GUILD_SOURCE_EXPECT_REVISION=""      # Optional bootstrap pin; mismatch fails before handoff
#
# cnode-specific variables
#CNODE_SKIP_DBSYNC_DOWNLOAD="N"      # Skip cardano-db-sync when using cnode -s d
######################################
# Do NOT modify code below           #
######################################

export LANG="C.UTF-8"
export LC_ALL="${LANG}"

DISPATCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER_LOCAL_REPO="N"
[[ -e "${DISPATCHER_DIR}/../../.git" ]] && DISPATCHER_LOCAL_REPO="Y"

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  STYLE_RESET="$(tput sgr0 2>/dev/null || true)"
  STYLE_BOLD="$(tput bold 2>/dev/null || true)"
  STYLE_RED="$(tput setaf 1 2>/dev/null || true)"
  STYLE_GREEN="$(tput setaf 2 2>/dev/null || true)"
  STYLE_YELLOW="$(tput setaf 3 2>/dev/null || true)"
  STYLE_CYAN="$(tput setaf 6 2>/dev/null || true)"
else
  STYLE_RESET=""
  STYLE_BOLD=""
  STYLE_RED=""
  STYLE_GREEN=""
  STYLE_YELLOW=""
  STYLE_CYAN=""
fi

log_info() {
  printf "%s  i %s%s\n" "${STYLE_CYAN}" "$1" "${STYLE_RESET}"
}

log_warn() {
  printf "%s  ! %s%s\n" "${STYLE_YELLOW}" "$1" "${STYLE_RESET}" >&2
}

log_progress() {
  local detail="${2:-}"
  printf "  .. %s%s\n" "$1" "$([[ -n "${detail}" ]] && printf ' (%s)' "${detail}")"
}

log_ok() {
  local detail="${2:-}"
  printf "%s  OK %s%s%s\n" "${STYLE_GREEN}" "$1" "$([[ -n "${detail}" ]] && printf ' (%s)' "${detail}")" "${STYLE_RESET}"
}

err_exit() {
  printf "\n%sDeployment failed: %s%s\n" "${STYLE_RED}" "${1:-unknown error}" "${STYLE_RESET}" >&2
  exit 1
}

dispatcher_package_output_summary() {
  local output_file="$1"
  local line=""
  local packages=""

  while IFS= read -r line; do
    [[ -n "${line}" ]] &&
      log_info "Package transaction: ${line}"
  done < <(
    awk '
      function emit(value) {
        if (!seen[value]++) {
          print value
        }
      }
      {
        sub(/\r$/, "")
        sub(/^[[:space:]]+/, "")
      }
      /^[0-9]+ upgraded, [0-9]+ newly installed, [0-9]+ to remove/ {
        emit($0)
      }
      /^(Install|Upgrade|Remove|Downgrade|Reinstall)[[:space:]]+[0-9]+ Package(s)?([[:space:](]|$)/ {
        emit($0)
      }
      /^(Installing|Upgrading|Reinstalling|Replacing|Removing|Downgrading|Skipping):[[:space:]]+[0-9]+ package(s)?([[:space:](]|$)/ {
        emit($0)
      }
      /^(Nothing to do|All packages are up to date)[.!]?$/ {
        emit($0)
      }
    ' "${output_file}"
  )

  packages="$(
    awk '
      function remember(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[,:][[:space:]]*$/, "", value)
        if (value != "" && !seen[value]++) {
          names[++count] = value
        }
      }
      {
        sub(/\r$/, "")
      }
      $1 == "Setting" && $2 == "up" {
        remember($3)
        next
      }
      $1 == "Removing" {
        remember($2)
        next
      }
      /^(Dependency )?(Installed|Updated|Upgraded|Removed|Downgraded|Reinstalled):[[:space:]]*$/ {
        result_section = 1
        next
      }
      /^(Installing|Upgrading|Reinstalling|Replacing|Removing|Downgrading)( dependencies| weak dependencies)?:[[:space:]]*$/ {
        result_section = 1
        next
      }
      result_section && /^[[:space:]]+/ {
        remember($1)
        next
      }
      result_section {
        result_section = 0
      }
      /^(Dependency )?(Installed|Updated|Upgraded|Removed|Downgraded|Reinstalled):[[:space:]]+[^[:space:]]/ {
        value = $0
        sub(/^[^:]+:[[:space:]]*/, "", value)
        split(value, fields, /[[:space:]]+/)
        remember(fields[1])
      }
      END {
        limit = count < 12 ? count : 12
        for (i = 1; i <= limit; i++) {
          printf "%s%s", (i > 1 ? ", " : ""), names[i]
        }
        if (count > limit) {
          printf " (+%d more)", count - limit
        }
      }
    ' "${output_file}"
  )"
  [[ -z "${packages}" ]] ||
    log_info "Changed packages: ${packages}"

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    case "${line}" in
      N:*) log_info "${line}" ;;
      *) log_warn "${line}" ;;
    esac
  done < <(
    awk '
      {
        sub(/\r$/, "")
        sub(/^[[:space:]]+/, "")
        normalized = tolower($0)
        if ($0 ~ /^[NWE]:/ || normalized ~ /^(warning:|error:|dpkg: warning:|debconf:|failed to )/) {
          if (!seen[$0]++) {
            if (++count <= 12) {
              print
            } else {
              omitted++
            }
          }
        }
      }
      END {
        if (omitted > 0) {
          printf "W: %d additional package-manager notices omitted; use verbose output to inspect them.\n", omitted
        }
      }
    ' "${output_file}"
  )
}

dispatcher_package_failure_summary() {
  local label="$1"
  local status="$2"
  local output_file="$3"
  local line=""
  local diagnostics=""

  log_warn "${label} failed (exit ${status})."
  diagnostics="$(
    awk '
      {
        sub(/\r$/, "")
        normalized = tolower($0)
        if ($0 ~ /^(E:|Err:)/ || normalized ~ /(^|[^[:alpha:]])(error|failed|failure|unable|cannot|could not|no match for argument|conflict|gpg error)([^[:alpha:]]|$)/) {
          if (!seen[$0]++) {
            if (++count <= 12) {
              print
            } else {
              omitted++
            }
          }
        }
      }
      END {
        if (omitted > 0) {
          printf "[%d additional diagnostic lines omitted]\n", omitted
        }
      }
    ' "${output_file}"
  )"

  if [[ -n "${diagnostics}" ]]; then
    printf "  Package-manager diagnostics:\n" >&2
    while IFS= read -r line; do
      printf "    %s\n" "${line}" >&2
    done <<< "${diagnostics}"
  fi

  printf "  Last 20 output lines:\n" >&2
  tail -n 20 "${output_file}" |
    while IFS= read -r line; do
      printf "    %s\n" "${line%$'\r'}" >&2
    done
  printf "  Full output: %s\n" "${output_file}" >&2
}

dispatcher_run_package_command() {
  local label="$1"
  local output_file=""
  local status=0
  shift

  [[ $# -gt 0 ]] || {
    log_warn "No command was provided for ${label}."
    return 2
  }

  if [[ "${PACKAGE_MANAGER_OUTPUT:-compact}" == "verbose" ]]; then
    "$@"
    return
  fi

  if ! output_file="$(
    umask 077
    mktemp "${TMPDIR:-/tmp}/guild-package-output.XXXXXX"
  )"; then
    log_warn "Could not create a compact output buffer; showing ${label} output."
    "$@"
    return
  fi

  if "$@" > "${output_file}" 2>&1; then
    dispatcher_package_output_summary "${output_file}"
    rm -f -- "${output_file}"
    return 0
  else
    status=$?
  fi

  dispatcher_package_failure_summary "${label}" "${status}" "${output_file}"
  return "${status}"
}

dispatcher_directory_has_entries() {
  local directory="${1:-}"
  local first_entry=""

  [[ -d "${directory}" ]] || return 1
  first_entry="$(find "${directory}" -mindepth 1 -print -quit 2>/dev/null)"
  [[ -n "${first_entry}" ]]
}

dispatcher_systemd_unit_installed() {
  local unit_name="${1:-}"
  local unit_directory="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"

  [[ "${unit_name}" =~ ^[A-Za-z0-9_.@:-]+[.]service$ ]] || return 1
  [[ -f "${unit_directory}/${unit_name}" &&
     ! -L "${unit_directory}/${unit_name}" ]]
}

dispatcher_resolve_github_release() {
  local component="$1"
  local repository="$2"
  local selector="$3"
  local api_url response_file resolved_line expected_url digest

  DISPATCHER_RELEASE_TAG=""
  DISPATCHER_RELEASE_VERSION=""
  DISPATCHER_RELEASE_ASSET=""
  DISPATCHER_RELEASE_URL=""
  DISPATCHER_RELEASE_SHA256=""
  DISPATCHER_RELEASE_PRERELEASE=""
  DISPATCHER_RELEASE_PUBLISHED_AT=""

  [[ "${component}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || {
    err_exit "Invalid component name supplied to the GitHub release resolver."
    return 1
  }
  [[ "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    err_exit "Invalid GitHub repository configured for ${component}."
    return 1
  }
  [[ -n "${selector}" && "${selector}" != *$'\n'* &&
     "${selector}" != *$'\r'* && "${selector}" != *$'\t'* ]] || {
    err_exit "Invalid release-asset selector configured for ${component}."
    return 1
  }

  api_url="https://api.github.com/repos/${repository}/releases?per_page=100"
  response_file="$(
    umask 077
    mktemp "${TMPDIR:-/tmp}/guild-${component}-release-api.XXXXXX"
  )" || {
    err_exit "Could not stage GitHub release metadata for ${component}."
    return 1
  }

  if ! curl --fail --silent --show-error --location \
    --connect-timeout "${CURL_TIMEOUT:-20}" \
    --max-time "${CURL_TIMEOUT:-60}" \
    --header "Accept: application/vnd.github+json" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    "${api_url}" --output "${response_file}"; then
    rm -f -- "${response_file}"
    err_exit "Could not resolve the newest published ${component} release from GitHub."
    return 1
  fi

  if ! resolved_line="$(
    jq -er --arg selector "${selector}" '
      [
        .[] |
        select(
          .draft == false and
          (.prerelease | type) == "boolean" and
          (.published_at | type) == "string" and
          (.published_at | length) > 0
        )
      ] |
      sort_by(.published_at) |
      last as $release |
      if ($release | type) != "object" or
         ($release.tag_name | type) != "string" or
         ($release.tag_name | length) == 0 or
         ($release.assets | type) != "array"
      then
        error("no published release")
      else
        [
          $release.assets[] |
          select(
            .state == "uploaded" and
            (.name | type) == "string" and
            (.name | test($selector))
          )
        ] as $matches |
        if ($matches | length) != 1 then
          error("asset selector did not match exactly one uploaded asset")
        else
          $matches[0] as $asset |
          if ($asset.browser_download_url | type) != "string" or
             ($asset.digest | type) != "string" or
             ($asset.size | type) != "number" or
             $asset.size <= 0
          then
            error("selected asset metadata is incomplete")
          else
            [
              $release.tag_name,
              $asset.name,
              $asset.browser_download_url,
              $asset.digest,
              ($release.prerelease | tostring),
              $release.published_at
            ] | @tsv
          end
        end
      end
    ' "${response_file}" 2>/dev/null
  )"; then
    rm -f -- "${response_file}"
    err_exit "Newest ${component} release metadata did not select exactly one valid asset."
    return 1
  fi
  rm -f -- "${response_file}"

  IFS=$'\t' read -r DISPATCHER_RELEASE_TAG DISPATCHER_RELEASE_ASSET \
    DISPATCHER_RELEASE_URL digest DISPATCHER_RELEASE_PRERELEASE \
    DISPATCHER_RELEASE_PUBLISHED_AT <<< "${resolved_line}"
  [[ "${DISPATCHER_RELEASE_TAG}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || {
    err_exit "Newest ${component} release returned an unsafe tag."
    return 1
  }
  [[ "${DISPATCHER_RELEASE_ASSET}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ &&
     "${DISPATCHER_RELEASE_ASSET}" != "." &&
     "${DISPATCHER_RELEASE_ASSET}" != ".." ]] || {
    err_exit "Newest ${component} release returned an unsafe asset filename."
    return 1
  }
  expected_url="https://github.com/${repository}/releases/download/${DISPATCHER_RELEASE_TAG}/${DISPATCHER_RELEASE_ASSET}"
  [[ "${DISPATCHER_RELEASE_URL}" == "${expected_url}" ]] || {
    err_exit "Newest ${component} asset URL does not match its repository, tag, and filename."
    return 1
  }
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    err_exit "Newest ${component} asset does not publish a valid GitHub SHA-256 digest."
    return 1
  }
  DISPATCHER_RELEASE_VERSION="${DISPATCHER_RELEASE_TAG#v}"
  [[ "${DISPATCHER_RELEASE_VERSION}" =~ ^[0-9][A-Za-z0-9._+-]*$ ]] || {
    err_exit "Newest ${component} release returned an unsupported version tag."
    return 1
  }
  DISPATCHER_RELEASE_SHA256="${digest#sha256:}"
}

dispatcher_usage() {
  cat <<-EOF

	Usage: $(basename "$0") [-i <cnode|dingo|amaru>] [-n <network>] [-p path] [-t name] [-b branch] [-a account] [-S mode] [-L checkout] [-D] [-R] [-E export-dir] [-u] [-s flags]

	Common Guild Operators deployment entrypoint.

	-i    Node implementation (Default: cnode)
	-n    Network. cnode defaults to mainnet; alternate implementations require an explicit supported network
	-p    Parent path below which the top-level folder is created (Default: /opt/cardano)
	-t    Alternate top-level folder/service name (Default: selected implementation)
	-b    Guild Operators repository branch (Default: stored deployment branch, then master)
	-a    Guild Operators GitHub account or fork owner
	-S    Source mode: managed (default), cached (explicit offline), or local
	-L    Absolute Git checkout used only with -S local
	-D    Allow a dirty local checkout; records a deterministic source tree digest
	-R    Explicitly allow an existing deployment to move to another repository/fork
	-E    Export the separately receipted Docker supplement to a new empty path
	-u    Skip dispatcher update check
	-s    Selective install flags. Common meanings:
	        p  runtime OS prerequisites
	        d  selected node implementation binaries
	        f  force configuration overwrite
	        s  force helper-script overwrite
	      cnode also supports b,l,m,c,o,w,x,r; alternate profiles reject them.
	      Unsupported flags fail explicitly.
	-h    Show this help

	Package-manager output is compact by default. Set
	PACKAGE_MANAGER_OUTPUT=verbose to stream it without filtering.

	Examples:
	  ./guild-deploy.sh -n mainnet -s pd
	  ./guild-deploy.sh -i dingo -n preprod -s pd
	  ./guild-deploy.sh -i amaru -n preview -t amaru-preview -s pd

	EOF
}

deployment_json_get() {
  local file="$1"
  local key="$2"
  [[ -s "${file}" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -er --arg key "${key}" '.[$key] // empty' "${file}" 2>/dev/null
    return
  fi
  sed -nE \
    -e 's/^[[:space:]]*"'"${key}"'"[[:space:]]*:[[:space:]]*"([^"]*)".*$/\1/p' \
    -e 's/^[[:space:]]*"'"${key}"'"[[:space:]]*:[[:space:]]*([0-9]+|true|false)[[:space:]]*,?.*$/\1/p' \
    "${file}" | head -n 1
}

validate_implementation() {
  case "$1" in
    cnode|dingo|amaru) return 0 ;;
    *) return 1 ;;
  esac
}

validate_branch_name() {
  local branch="$1"
  local component
  local -a components

  [[ "${branch}" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || return 1
  [[ "${branch}" != */ &&
     "${branch}" != *..* &&
     "${branch}" != *//* &&
     "${branch}" != *@\{* &&
     "${branch}" != "@" &&
     "${branch}" != *. ]] || return 1
  IFS='/' read -r -a components <<< "${branch}"
  for component in "${components[@]}"; do
    [[ -n "${component}" &&
       "${component}" != .* &&
       "${component}" != *.lock ]] || return 1
  done
}

validate_account_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]
}

validate_deployment_path() {
  [[ "${1:-}" =~ ^/[A-Za-z0-9._/+@:-]+$ ]]
}

# Managed-source provider ---------------------------------------------------------
#
# The bootstrap prepares one immutable source snapshot through this interface,
# releases the source-cache lock, and re-executes the dispatcher from that exact
# snapshot before acquiring a deployment-target lock. Profiles and the complete
# payload transaction then copy only from the adopted snapshot.
#
# Public contract:
#   guild_source_prepare <account/guild-operators> <channel> \
#     [managed|cached|local] [checkout]
#   guild_source_revision
#   guild_source_ref
#   guild_source_path <repository-relative-path>
#   guild_source_report
#   guild_source_release
#
# A managed preparation refreshes a private, account-scoped bare repository.
# Cached mode must be selected explicitly and never performs a remote request.
# Local mode reads an explicitly supplied checkout without fetching, switching,
# resetting, cleaning, updating its index, or changing its configuration.
# Every successful preparation eagerly copies the complete tracked scripts/ and
# files/ payload into an owner-only, read-only snapshot. Callers receive paths
# inside that snapshot; this API never accepts a deployment destination.

# Private state is initialized here instead of trusting inherited variables.
# In particular, guild_source_release never acts on caller-provided paths.
_GUILD_SOURCE_PREPARED="N"
_GUILD_SOURCE_REPOSITORY=""
_GUILD_SOURCE_CHANNEL=""
_GUILD_SOURCE_MODE=""
_GUILD_SOURCE_REF=""
_GUILD_SOURCE_REVISION=""
_GUILD_SOURCE_DIRTY="false"
_GUILD_SOURCE_TREE_DIGEST=""
_GUILD_SOURCE_SNAPSHOT=""
_GUILD_SOURCE_SNAPSHOT_CONTAINER=""
_GUILD_SOURCE_SNAPSHOT_PARENT=""
_GUILD_SOURCE_SNAPSHOT_TOKEN=""
_GUILD_SOURCE_GIT_EXEC=""

_guild_source_error() {
  printf 'Guild source error: %s\n' "$1" >&2
}

_guild_source_repository_valid() {
  local repository="${1:-}"
  local account=""

  [[ "${repository}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/guild-operators$ ]] ||
    return 1
  account="${repository%/guild-operators}"
  [[ "${account}" != "." &&
     "${account}" != ".." &&
     "${account}" != .* &&
     "${account}" != *..* &&
     "${account}" != *. ]] || return 1
}

_guild_source_channel_valid() {
  local channel="${1:-}"

  validate_branch_name "${channel}" || return 1
  _guild_source_git check-ref-format "refs/heads/${channel}" >/dev/null 2>&1 &&
    _guild_source_git check-ref-format "refs/tags/${channel}" >/dev/null 2>&1
}

_guild_source_relative_path_valid() {
  local relative_path="${1:-}"
  local component=""
  local -a components

  [[ -n "${relative_path}" &&
     "${relative_path}" != /* &&
     "${relative_path}" != */ &&
     "${relative_path}" != *//* &&
     ! "${relative_path}" =~ [[:cntrl:]] &&
     "${relative_path}" =~ ^(scripts|files)/[A-Za-z0-9._/+@:-]+$ ]] ||
    return 1
  IFS='/' read -r -a components <<< "${relative_path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" &&
       "${component}" != "." &&
       "${component}" != ".." ]] || return 1
  done
}

# This resolver is intentionally replaceable by isolated tests. Direct
# production execution uses only the canonical public HTTPS form below.
guild_source_repository_url() {
  local repository="${1:-}"
  _guild_source_repository_valid "${repository}" || return 2
  printf 'https://github.com/%s.git\n' "${repository}"
}

_guild_source_resolve_git() {
  local candidate="${GUILD_SOURCE_GIT_BIN:-}"

  if [[ -z "${candidate}" ]]; then
    candidate="$(command -v git 2>/dev/null || true)"
  fi
  [[ -n "${candidate}" && "${candidate}" == /* && -x "${candidate}" ]] || {
    _guild_source_error 'git is required to prepare a Guild source snapshot.'
    return 1
  }
  _GUILD_SOURCE_GIT_EXEC="${candidate}"
}

# Run Git without inherited repository selection, alternates, replacement
# objects, global/system configuration, credential helpers, or interactive
# prompts. Managed-cache configuration is validated separately before use.
_guild_source_git() (
  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG
  unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
  unset GIT_DIR GIT_EXEC_PATH GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
  unset GIT_PREFIX GIT_SSH GIT_SSH_COMMAND GIT_WORK_TREE
  unset GIT_ASKPASS GIT_CEILING_DIRECTORIES GIT_DEFAULT_HASH
  unset GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_GRAFT_FILE GIT_NAMESPACE
  unset GIT_PROXY_COMMAND GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE
  unset GIT_SSL_CAINFO GIT_SSL_CAPATH GIT_SSL_NO_VERIFY
  unset GIT_SSH_VARIANT GIT_TEMPLATE_DIR SSH_ASKPASS
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_TERMINAL_PROMPT=0
  export GIT_OPTIONAL_LOCKS=0
  export GIT_NO_REPLACE_OBJECTS=1
  export LC_ALL=C
  umask 077
  "${_GUILD_SOURCE_GIT_EXEC}" \
    -c credential.helper= \
    -c core.hooksPath=/dev/null \
    -c core.fsmonitor=false \
    "$@"
)

_guild_source_mode_has_write_bits() {
  local path="$1"
  find "${path}" -prune \
    \( -perm -0020 -o -perm -0002 \) -print -quit 2>/dev/null |
    grep -q .
}

_guild_source_directory_secure() {
  local path="$1"

  [[ -d "${path}" && ! -L "${path}" && -O "${path}" ]] || return 1
  ! _guild_source_mode_has_write_bits "${path}"
}

_guild_source_cache_parent_prepare() {
  local path="$1"
  local component=""
  local current_path="/"
  local root_owned="N"
  local -a components

  [[ "${path}" == /* && "${path}" != "/" ]] || return 1
  IFS='/' read -r -a components <<< "${path#/}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current_path="${current_path%/}/${component}"
    [[ ! -L "${current_path}" ]] || return 1
    if [[ ! -e "${current_path}" ]]; then
      (umask 077 && mkdir -- "${current_path}") || {
        [[ -d "${current_path}" && ! -L "${current_path}" ]] || return 1
      }
    fi
    [[ -d "${current_path}" && ! -L "${current_path}" ]] || return 1
    root_owned="N"
    if find "${current_path}" -prune -user root -print -quit 2>/dev/null |
       grep -q .; then
      root_owned="Y"
    elif [[ ! -O "${current_path}" ]]; then
      return 1
    fi
    if _guild_source_mode_has_write_bits "${current_path}"; then
      [[ "${root_owned}" == "Y" && -k "${current_path}" ]] || return 1
    fi
  done
}

_guild_source_cache_root() {
  local configured_root="${GUILD_SOURCE_CACHE_ROOT:-}"
  local root_parent=""
  local root_name=""
  local physical_parent=""
  local managed_root=""

  if [[ -z "${configured_root}" ]]; then
    [[ -n "${XDG_CACHE_HOME:-}" || -n "${HOME:-}" ]] || return 2
    configured_root="${XDG_CACHE_HOME:-${HOME}/.cache}/guild-operators"
  fi
  [[ "${configured_root}" == /* &&
     "${configured_root}" != "/" &&
     "${configured_root}" != *//* &&
     "${configured_root}" != */../* &&
     "${configured_root}" != */.. &&
     "${configured_root}" != */./* &&
     "${configured_root}" != */. &&
     ! "${configured_root}" =~ [[:cntrl:]] ]] || return 2

  root_parent="$(dirname -- "${configured_root}")" || return 2
  root_name="$(basename -- "${configured_root}")" || return 2
  [[ "${root_parent}" != "/" &&
     -n "${root_name}" &&
     "${root_name}" != "." &&
     "${root_name}" != ".." ]] ||
    return 2
  if [[ -L "${configured_root}" ]]; then
    return 2
  fi
  _guild_source_cache_parent_prepare "${root_parent}" || return 2
  physical_parent="$(cd -P -- "${root_parent}" 2>/dev/null && pwd -P)" ||
    return 2
  managed_root="${physical_parent%/}/${root_name}"
  if [[ -e "${managed_root}" ]]; then
    _guild_source_directory_secure "${managed_root}" || return 2
  else
    (umask 077 && mkdir -- "${managed_root}") || return 2
    chmod 0700 "${managed_root}" || return 2
  fi
  printf '%s\n' "${managed_root}"
}

_guild_source_lock_release() {
  case "${_GUILD_SOURCE_WORK_LOCK_BACKEND:-}" in
    flock)
      flock -u 7 >/dev/null 2>&1 || true
      exec 7>&-
      ;;
    directory)
      if [[ -n "${_GUILD_SOURCE_WORK_LOCK_PATH:-}" &&
            -d "${_GUILD_SOURCE_WORK_LOCK_PATH}" &&
            ! -L "${_GUILD_SOURCE_WORK_LOCK_PATH}" &&
            -O "${_GUILD_SOURCE_WORK_LOCK_PATH}" ]]; then
        rm -f -- "${_GUILD_SOURCE_WORK_LOCK_PATH}/owner" 2>/dev/null || true
        rmdir -- "${_GUILD_SOURCE_WORK_LOCK_PATH}" 2>/dev/null || true
      fi
      ;;
  esac
  _GUILD_SOURCE_WORK_LOCK_BACKEND=""
  _GUILD_SOURCE_WORK_LOCK_PATH=""
}

_guild_source_lock_acquire() {
  local managed_root="$1"
  local account_key="$2"
  local backend="${GUILD_SOURCE_LOCK_BACKEND:-auto}"
  local timeout="${GUILD_SOURCE_LOCK_TIMEOUT:-30}"
  local lock_root="${managed_root}/locks"
  local lock_path=""
  local owner_pid=""
  local started_at="${SECONDS}"
  local stale_path=""

  [[ "${timeout}" =~ ^[0-9]+$ ]] || return 2
  (( 10#${timeout} > 0 )) || return 2
  case "${backend}" in
    auto)
      if command -v flock >/dev/null 2>&1; then
        backend="flock"
      else
        backend="directory"
      fi
      ;;
    flock|directory) ;;
    *) return 2 ;;
  esac

  if [[ -e "${lock_root}" ]]; then
    _guild_source_directory_secure "${lock_root}" || return 2
  else
    (umask 077 && mkdir -- "${lock_root}") || return 2
    chmod 0700 "${lock_root}" || return 2
  fi

  if [[ "${backend}" == "flock" ]]; then
    command -v flock >/dev/null 2>&1 || return 2
    lock_path="${lock_root}/${account_key}.lock"
    if [[ -L "${lock_path}" ||
          ( -e "${lock_path}" && ( ! -f "${lock_path}" || ! -O "${lock_path}" ) ) ]]; then
      return 2
    fi
    (umask 077 && : >| "${lock_path}") || return 2
    chmod 0600 "${lock_path}" || return 2
    exec 7>>"${lock_path}" || return 2
    if ! flock -w "$((10#${timeout}))" 7; then
      exec 7>&-
      return 1
    fi
    _GUILD_SOURCE_WORK_LOCK_BACKEND="flock"
    _GUILD_SOURCE_WORK_LOCK_PATH="${lock_path}"
    return 0
  fi

  lock_path="${lock_root}/${account_key}.lock.d"
  while :; do
    if (umask 077 && mkdir -- "${lock_path}") 2>/dev/null; then
      _GUILD_SOURCE_WORK_LOCK_BACKEND="directory"
      _GUILD_SOURCE_WORK_LOCK_PATH="${lock_path}"
      printf '%s\n' "${BASHPID}" > "${lock_path}/owner" || return 2
      chmod 0600 "${lock_path}/owner" || return 2
      return 0
    fi
    [[ -d "${lock_path}" && ! -L "${lock_path}" && -O "${lock_path}" ]] ||
      return 2
    owner_pid="$(sed -n '1p' "${lock_path}/owner" 2>/dev/null || true)"
    [[ "${owner_pid}" =~ ^[0-9]+$ ]] || return 2
    if ! kill -0 "${owner_pid}" 2>/dev/null; then
      stale_path="${lock_path}.stale.${BASHPID}"
      if mv -- "${lock_path}" "${stale_path}" 2>/dev/null; then
        rm -f -- "${stale_path}/owner" 2>/dev/null || true
        rmdir -- "${stale_path}" 2>/dev/null || return 2
        continue
      fi
    fi
    (( SECONDS - started_at < 10#${timeout} )) || return 1
    sleep 1
  done
}

_guild_source_cache_marker_write() {
  local git_dir="$1"
  local repository="$2"
  local remote_url="$3"
  local marker="${git_dir}/guild-source-cache"

  {
    printf 'schemaVersion=1\n'
    printf 'repository=%s\n' "${repository}"
    printf 'remote=%s\n' "${remote_url}"
  } > "${marker}" || return 1
  chmod 0600 "${marker}" || return 1
}

_guild_source_cache_validate_config() {
  local git_dir="$1"
  local config_name=""
  local config_names=""
  local seen_names='|'

  [[ -f "${git_dir}/config" && ! -L "${git_dir}/config" ]] || return 1
  config_names="$(_guild_source_git config --file "${git_dir}/config" \
    --name-only --get-regexp '.*' 2>/dev/null)" || return 1
  while IFS= read -r config_name; do
    case "${config_name}" in
      core.repositoryformatversion|core.filemode|core.bare|core.logallrefupdates|core.ignorecase|core.precomposeunicode|remote.origin.url)
        ;;
      *) return 1 ;;
    esac
    [[ "${seen_names}" != *"|${config_name}|"* ]] || return 1
    seen_names="${seen_names}${config_name}|"
  done <<< "${config_names}"
}

_guild_source_cache_validate() {
  local git_dir="$1"
  local repository="$2"
  local remote_url="$3"
  local marker="${git_dir}/guild-source-cache"
  local origin_urls=""
  local owner_name=""

  _guild_source_directory_secure "${git_dir}" || return 2
  if find "${git_dir}" -type l -print -quit 2>/dev/null | grep -q .; then
    return 2
  fi
  owner_name="$(id -un)" || return 2
  if find "${git_dir}" ! -user "${owner_name}" -print -quit 2>/dev/null |
     grep -q .; then
    return 2
  fi
  if find "${git_dir}" \( -perm -0020 -o -perm -0002 \) -print -quit 2>/dev/null |
     grep -q .; then
    return 2
  fi
  [[ ! -e "${git_dir}/objects/info/alternates" &&
     ! -e "${git_dir}/shallow" &&
     -f "${marker}" && ! -L "${marker}" && -O "${marker}" ]] || return 2
  grep -Fqx 'schemaVersion=1' "${marker}" || return 2
  grep -Fqx "repository=${repository}" "${marker}" || return 2
  grep -Fqx "remote=${remote_url}" "${marker}" || return 2
  _guild_source_cache_validate_config "${git_dir}" || return 2
  [[ "$(_guild_source_git --git-dir="${git_dir}" \
    rev-parse --is-bare-repository 2>/dev/null)" == "true" ]] || return 2
  origin_urls="$(_guild_source_git --git-dir="${git_dir}" \
    config --get-all remote.origin.url 2>/dev/null)" || return 2
  [[ -n "${origin_urls}" &&
     "${origin_urls}" != *$'\n'* &&
     ! "${origin_urls}" =~ [[:cntrl:]] &&
     "${origin_urls}" == "${remote_url}" ]] || return 2
}

_guild_source_resolve_managed_ref() (
  local git_dir="$1"
  local channel="$2"
  local remote_refs=""
  local object_id=""
  local remote_ref=""
  local selected_ref=""
  local selected_object_id=""
  local destination_ref=""
  local opposite_ref=""
  local candidate_ref="refs/guild-source/candidates/${BASHPID}"
  local fetched_object_id=""
  local revision=""
  local match_count=0

  trap '_guild_source_git --git-dir="${git_dir}" update-ref -d \
    "${candidate_ref}" >/dev/null 2>&1 || true' EXIT
  trap 'exit 130' HUP INT TERM

  remote_refs="$(_guild_source_git --git-dir="${git_dir}" ls-remote --refs origin \
    "refs/heads/${channel}" "refs/tags/${channel}" 2>/dev/null)" || return 1
  while IFS=$'\t' read -r object_id remote_ref; do
    [[ -n "${object_id}" && -n "${remote_ref}" ]] || continue
    case "${remote_ref}" in
      "refs/heads/${channel}"|"refs/tags/${channel}")
        selected_ref="${remote_ref}"
        selected_object_id="${object_id}"
        match_count=$((match_count + 1))
        ;;
    esac
  done <<< "${remote_refs}"
  (( match_count == 1 )) || {
    (( match_count == 0 )) && return 1
    return 2
  }
  [[ "${selected_object_id}" =~ ^[0-9a-f]{40,64}$ ]] || return 1

  case "${selected_ref}" in
    refs/heads/*)
      destination_ref="refs/guild-source/heads/${channel}"
      opposite_ref="refs/guild-source/tags/${channel}"
      ;;
    refs/tags/*)
      destination_ref="refs/guild-source/tags/${channel}"
      opposite_ref="refs/guild-source/heads/${channel}"
      ;;
  esac
  _guild_source_git --git-dir="${git_dir}" update-ref -d \
    "${candidate_ref}" >/dev/null 2>&1 || return 1
  _guild_source_git --git-dir="${git_dir}" fetch --force --no-tags origin \
    "+${selected_ref}:${candidate_ref}" >/dev/null 2>&1 || return 1
  fetched_object_id="$(_guild_source_git --git-dir="${git_dir}" rev-parse \
    --verify "${candidate_ref}" 2>/dev/null)" || return 1
  [[ "${fetched_object_id}" == "${selected_object_id}" ]] || return 1
  revision="$(_guild_source_git --git-dir="${git_dir}" rev-parse --verify \
    "${candidate_ref}^{commit}" 2>/dev/null)" || return 1
  [[ "${revision}" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  _guild_source_git --git-dir="${git_dir}" cat-file -e \
    "${revision}^{commit}" 2>/dev/null || return 1
  {
    printf 'update %s %s\n' "${destination_ref}" "${fetched_object_id}"
    printf 'delete %s\n' "${opposite_ref}"
  } | _guild_source_git --git-dir="${git_dir}" update-ref --stdin || return 1
  printf '%s\n%s\n' "${selected_ref}" "${revision}"
)

_guild_source_resolve_cached_ref() {
  local git_dir="$1"
  local channel="$2"
  local head_ref="refs/guild-source/heads/${channel}"
  local tag_ref="refs/guild-source/tags/${channel}"
  local selected_ref=""
  local selected_cache_ref=""
  local revision=""
  local match_count=0

  if _guild_source_git --git-dir="${git_dir}" show-ref --verify --quiet \
    "${head_ref}"; then
    selected_ref="refs/heads/${channel}"
    selected_cache_ref="${head_ref}"
    match_count=$((match_count + 1))
  fi
  if _guild_source_git --git-dir="${git_dir}" show-ref --verify --quiet \
    "${tag_ref}"; then
    selected_ref="refs/tags/${channel}"
    selected_cache_ref="${tag_ref}"
    match_count=$((match_count + 1))
  fi
  (( match_count == 1 )) || {
    (( match_count == 0 )) && return 1
    return 2
  }
  revision="$(_guild_source_git --git-dir="${git_dir}" rev-parse --verify \
    "${selected_cache_ref}^{commit}" 2>/dev/null)" || return 1
  [[ "${revision}" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  _guild_source_git --git-dir="${git_dir}" cat-file -e \
    "${revision}^{commit}" 2>/dev/null || return 1
  printf '%s\n%s\n' "${selected_ref}" "${revision}"
}

_guild_source_snapshot_container_create() {
  local tmp_root="${GUILD_SOURCE_TMP_ROOT:-${TMPDIR:-/tmp}}"
  local physical_tmp=""
  local container=""

  [[ "${tmp_root}" == /* &&
     "${tmp_root}" != "/" &&
     "${tmp_root}" != *//* &&
     "${tmp_root}" != */../* &&
     "${tmp_root}" != */.. &&
     ! "${tmp_root}" =~ [[:cntrl:]] ]] || return 2
  (umask 077 && mkdir -p -- "${tmp_root}") || return 2
  physical_tmp="$(cd -P -- "${tmp_root}" 2>/dev/null && pwd -P)" || return 2
  container="$(mktemp -d "${physical_tmp}/guild-source-transaction.XXXXXX")" ||
    return 1
  chmod 0700 "${container}" || return 1
  printf '%s\n' "${container}"
}

_guild_source_snapshot_publish() {
  local container="$1"
  local build_path="${container}/build"
  local snapshot_path="${container}/snapshot"
  local token="${container##*.}"

  [[ -d "${build_path}" && ! -e "${snapshot_path}" ]] || return 1
  printf '%s\n' "${token}" > "${build_path}/guild-source-snapshot" || return 1
  chmod 0400 "${build_path}/guild-source-snapshot" || return 1
  while IFS= read -r directory; do
    chmod 0500 "${directory}" || return 1
  done < <(find "${build_path}" -depth -type d -print)
  mv -- "${build_path}" "${snapshot_path}" || return 1
  chmod 0500 "${container}" || return 1
  printf '%s\n%s\n' "${snapshot_path}" "${token}"
}

_guild_source_snapshot_from_git() {
  local git_dir="$1"
  local revision="$2"
  local container="$3"
  local build_path="${container}/build"
  local records="${container}/tree.records"
  local tree_entry=""
  local metadata=""
  local relative_path=""
  local object_mode=""
  local object_type=""
  local object_id=""
  local remainder=""
  local destination=""
  local destination_dir=""
  local file_count=0

  mkdir -- "${build_path}" || return 1
  chmod 0700 "${build_path}" || return 1
  _guild_source_git --git-dir="${git_dir}" ls-tree -r -z --full-tree \
    "${revision}" -- scripts files > "${records}" || return 1
  while IFS= read -r -d '' tree_entry; do
    metadata="${tree_entry%%$'\t'*}"
    relative_path="${tree_entry#*$'\t'}"
    object_mode="${metadata%% *}"
    remainder="${metadata#* }"
    object_type="${remainder%% *}"
    object_id="${remainder#* }"
    _guild_source_relative_path_valid "${relative_path}" || return 2
    [[ "${object_type}" == "blob" ]] || return 2
    case "${object_mode}" in
      100644|100755) ;;
      *) return 2 ;;
    esac
    [[ "${object_id}" =~ ^[0-9a-f]{40,64}$ ]] || return 1
    destination="${build_path}/${relative_path}"
    destination_dir="$(dirname -- "${destination}")"
    (umask 077 && mkdir -p -- "${destination_dir}") || return 1
    _guild_source_git --git-dir="${git_dir}" cat-file blob \
      "${object_id}" > "${destination}" || return 1
    if [[ "${object_mode}" == "100755" ]]; then
      chmod 0500 "${destination}" || return 1
    else
      chmod 0400 "${destination}" || return 1
    fi
    file_count=$((file_count + 1))
  done < "${records}"
  rm -f -- "${records}"
  (( file_count > 0 )) || return 1
}

_guild_source_snapshot_from_checkout() {
  local checkout="$1"
  local revision="$2"
  local container="$3"
  local build_path="${container}/build"
  local records="${container}/index.records"
  local records_after="${container}/index-after.records"
  local untracked_records="${container}/untracked.records"
  local digest_records="${container}/digest.records"
  local index_entry=""
  local metadata=""
  local relative_path=""
  local object_mode=""
  local object_id=""
  local stage_number=""
  local source_path=""
  local destination=""
  local destination_dir=""
  local actual_mode=""
  local file_digest=""
  local file_count=0
  local tree_digest=""

  mkdir -- "${build_path}" || return 1
  chmod 0700 "${build_path}" || return 1
  _guild_source_git -C "${checkout}" ls-files --stage -z -- \
    scripts files > "${records}" || return 1
  _guild_source_git -C "${checkout}" ls-files --others --exclude-standard \
    -z -- scripts files > "${untracked_records}" || return 1
  [[ ! -s "${untracked_records}" ]] || return 2
  : > "${digest_records}" || return 1
  printf 'revision %s\n' "${revision}" >> "${digest_records}" || return 1
  while IFS= read -r -d '' index_entry; do
    metadata="${index_entry%%$'\t'*}"
    relative_path="${index_entry#*$'\t'}"
    object_mode="${metadata%% *}"
    stage_number="${metadata##* }"
    object_id="${metadata#* }"
    object_id="${object_id%% *}"
    _guild_source_relative_path_valid "${relative_path}" || return 2
    [[ "${stage_number}" == "0" ]] || return 2
    case "${object_mode}" in
      100644|100755) ;;
      *) return 2 ;;
    esac
    source_path="${checkout}/${relative_path}"
    [[ -f "${source_path}" && ! -L "${source_path}" ]] || return 2
    destination="${build_path}/${relative_path}"
    destination_dir="$(dirname -- "${destination}")"
    (umask 077 && mkdir -p -- "${destination_dir}") || return 1
    cp -- "${source_path}" "${destination}" || return 1
    if [[ -x "${source_path}" ]]; then
      actual_mode="100755"
      chmod 0500 "${destination}" || return 1
    else
      actual_mode="100644"
      chmod 0400 "${destination}" || return 1
    fi
    cmp -s -- "${source_path}" "${destination}" || return 1
    file_digest="$(sha256sum "${destination}" | awk '{print $1}')" || return 1
    [[ "${file_digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s %s %s\n' "${actual_mode}" "${file_digest}" \
      "${relative_path}" >> "${digest_records}" || return 1
    file_count=$((file_count + 1))
  done < "${records}"
  (( file_count > 0 )) || return 1
  _guild_source_git -C "${checkout}" ls-files --stage -z -- \
    scripts files > "${records_after}" || return 1
  cmp -s -- "${records}" "${records_after}" || return 1
  while IFS= read -r -d '' index_entry; do
    relative_path="${index_entry#*$'\t'}"
    cmp -s -- "${checkout}/${relative_path}" \
      "${build_path}/${relative_path}" || return 1
  done < "${records}"
  tree_digest="$(sha256sum "${digest_records}" | awk '{print $1}')" || return 1
  [[ "${tree_digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  rm -f -- "${records}" "${records_after}" "${untracked_records}" \
    "${digest_records}"
  printf '%s\n' "${tree_digest}"
}

_guild_source_normalize_github_url() {
  local value="${1:-}"
  local repository=""

  case "${value}" in
    https://github.com/*)
      repository="${value#https://github.com/}"
      ;;
    git@github.com:*)
      repository="${value#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      repository="${value#ssh://git@github.com/}"
      ;;
    *) return 1 ;;
  esac
  repository="${repository%/}"
  repository="${repository%.git}"
  _guild_source_repository_valid "${repository}" || return 1
  printf '%s\n' "$(printf '%s' "${repository}" | tr '[:upper:]' '[:lower:]')"
}

_guild_source_local_origin_matches() {
  local actual="$1"
  local expected="$2"
  local actual_normalized=""
  local expected_normalized=""

  actual_normalized="$(_guild_source_normalize_github_url "${actual}" 2>/dev/null || true)"
  expected_normalized="$(_guild_source_normalize_github_url "${expected}" 2>/dev/null || true)"
  if [[ -n "${actual_normalized}" && -n "${expected_normalized}" ]]; then
    [[ "${actual_normalized}" == "${expected_normalized}" ]]
  else
    [[ "${actual}" == "${expected}" ]]
  fi
}

_guild_source_worker_cleanup() {
  _guild_source_lock_release
  if [[ "${_GUILD_SOURCE_WORK_SUCCESS:-N}" != "Y" ]]; then
    if [[ -n "${_GUILD_SOURCE_WORK_CACHE_STAGE:-}" &&
          "${_GUILD_SOURCE_WORK_CACHE_STAGE}" == */.repository.git.init.* &&
          -d "${_GUILD_SOURCE_WORK_CACHE_STAGE}" &&
          ! -L "${_GUILD_SOURCE_WORK_CACHE_STAGE}" ]]; then
      chmod -R u+rwX "${_GUILD_SOURCE_WORK_CACHE_STAGE}" 2>/dev/null || true
      rm -rf -- "${_GUILD_SOURCE_WORK_CACHE_STAGE}"
    fi
    if [[ -n "${_GUILD_SOURCE_WORK_CONTAINER:-}" &&
          "${_GUILD_SOURCE_WORK_CONTAINER}" == */guild-source-transaction.* &&
          -d "${_GUILD_SOURCE_WORK_CONTAINER}" &&
          ! -L "${_GUILD_SOURCE_WORK_CONTAINER}" ]]; then
      chmod -R u+rwX "${_GUILD_SOURCE_WORK_CONTAINER}" 2>/dev/null || true
      rm -rf -- "${_GUILD_SOURCE_WORK_CONTAINER}"
    fi
  fi
}

_guild_source_prepare_worker() (
  local repository="$1"
  local channel="$2"
  local mode="$3"
  local checkout="${4:-}"
  local normalized_repository=""
  local account=""
  local account_key=""
  local remote_url=""
  local managed_root=""
  local account_path=""
  local git_dir=""
  local resolution=""
  local resolved_ref=""
  local revision=""
  local container=""
  local publication=""
  local snapshot_path=""
  local snapshot_token=""
  local source_dirty="false"
  local tree_digest=""
  local checkout_root=""
  local checkout_git_dir=""
  local checkout_branch=""
  local checkout_origin=""
  local checkout_origins=""
  local checkout_status_before=""
  local checkout_status_after=""

  _GUILD_SOURCE_WORK_SUCCESS="N"
  _GUILD_SOURCE_WORK_CACHE_STAGE=""
  _GUILD_SOURCE_WORK_CONTAINER=""
  _GUILD_SOURCE_WORK_LOCK_BACKEND=""
  _GUILD_SOURCE_WORK_LOCK_PATH=""
  trap _guild_source_worker_cleanup EXIT
  trap 'exit 130' HUP INT TERM

  _guild_source_repository_valid "${repository}" || return 2
  _guild_source_channel_valid "${channel}" || return 2
  case "${mode}" in
    managed|cached)
      [[ -z "${checkout}" ]] || return 2
      ;;
    local)
      [[ -n "${checkout}" ]] || return 2
      ;;
    *) return 2 ;;
  esac
  normalized_repository="$(printf '%s' "${repository}" | tr '[:upper:]' '[:lower:]')"
  account="${repository%/guild-operators}"
  account_key="$(printf '%s' "${account}" | tr '[:upper:]' '[:lower:]')"
  remote_url="$(guild_source_repository_url "${repository}")" || return 2
  [[ -n "${remote_url}" && ! "${remote_url}" =~ [[:cntrl:]] ]] || return 2

  if [[ "${mode}" == "managed" || "${mode}" == "cached" ]]; then
    managed_root="$(_guild_source_cache_root)" || return $?
    _guild_source_lock_acquire "${managed_root}" "${account_key}" || return $?
    account_path="${managed_root}/${account_key}"
    git_dir="${account_path}/repository.git"
    if [[ -e "${account_path}" ]]; then
      _guild_source_directory_secure "${account_path}" || return 2
    else
      (umask 077 && mkdir -- "${account_path}") || return 2
      chmod 0700 "${account_path}" || return 2
    fi

    if [[ "${mode}" == "managed" && ! -e "${git_dir}" ]]; then
      _GUILD_SOURCE_WORK_CACHE_STAGE="$(mktemp -d \
        "${account_path}/.repository.git.init.XXXXXX")" || return 1
      chmod 0700 "${_GUILD_SOURCE_WORK_CACHE_STAGE}" || return 1
      (umask 077 && _guild_source_git init --bare \
        "${_GUILD_SOURCE_WORK_CACHE_STAGE}" >/dev/null 2>&1) || return 1
      _guild_source_git --git-dir="${_GUILD_SOURCE_WORK_CACHE_STAGE}" \
        config remote.origin.url "${remote_url}" || return 1
      _guild_source_cache_marker_write "${_GUILD_SOURCE_WORK_CACHE_STAGE}" \
        "${normalized_repository}" "${remote_url}" || return 1
      resolution="$(_guild_source_resolve_managed_ref \
        "${_GUILD_SOURCE_WORK_CACHE_STAGE}" "${channel}")" || return $?
      _guild_source_cache_validate "${_GUILD_SOURCE_WORK_CACHE_STAGE}" \
        "${normalized_repository}" "${remote_url}" || return $?
      mv -- "${_GUILD_SOURCE_WORK_CACHE_STAGE}" "${git_dir}" || return 1
      _GUILD_SOURCE_WORK_CACHE_STAGE=""
    else
      [[ -e "${git_dir}" ]] || return 1
      _guild_source_cache_validate "${git_dir}" \
        "${normalized_repository}" "${remote_url}" || return $?
      if [[ "${mode}" == "managed" ]]; then
        resolution="$(_guild_source_resolve_managed_ref \
          "${git_dir}" "${channel}")" || return $?
        _guild_source_cache_validate "${git_dir}" \
          "${normalized_repository}" "${remote_url}" || return $?
      else
        resolution="$(_guild_source_resolve_cached_ref \
          "${git_dir}" "${channel}")" || return $?
      fi
    fi
    resolved_ref="${resolution%%$'\n'*}"
    revision="${resolution#*$'\n'}"
    container="$(_guild_source_snapshot_container_create)" || return $?
    _GUILD_SOURCE_WORK_CONTAINER="${container}"
    _guild_source_snapshot_from_git "${git_dir}" "${revision}" \
      "${container}" || return $?
  else
    [[ "${checkout}" == /* && -d "${checkout}" && ! -L "${checkout}" ]] ||
      return 2
    checkout_root="$(cd -P -- "${checkout}" 2>/dev/null && pwd -P)" || return 2
    [[ "$(_guild_source_git -C "${checkout_root}" rev-parse \
      --is-inside-work-tree 2>/dev/null)" == "true" ]] || return 2
    [[ "$(_guild_source_git -C "${checkout_root}" rev-parse \
      --show-toplevel 2>/dev/null)" == "${checkout_root}" ]] || return 2
    checkout_git_dir="$(_guild_source_git -C "${checkout_root}" rev-parse \
      --absolute-git-dir 2>/dev/null)" || return 2
    [[ "${checkout_git_dir}" == /* && -d "${checkout_git_dir}" ]] || return 2
    checkout_branch="$(_guild_source_git -C "${checkout_root}" symbolic-ref \
      --quiet --short HEAD 2>/dev/null)" || return 2
    [[ "${checkout_branch}" == "${channel}" ]] || return 2
    resolved_ref="refs/heads/${channel}"
    revision="$(_guild_source_git -C "${checkout_root}" rev-parse --verify \
      HEAD 2>/dev/null)" || return 1
    [[ "${revision}" =~ ^[0-9a-f]{40,64}$ ]] || return 1
    checkout_origins="$(_guild_source_git -C "${checkout_root}" config \
      --get-all remote.origin.url 2>/dev/null)" || return 2
    [[ -n "${checkout_origins}" && "${checkout_origins}" != *$'\n'* ]] || return 2
    checkout_origin="${checkout_origins}"
    _guild_source_local_origin_matches "${checkout_origin}" "${remote_url}" ||
      return 2
    checkout_status_before="$(_guild_source_git -C "${checkout_root}" status \
      --porcelain=v1 --untracked-files=all -- scripts files 2>/dev/null)" ||
      return 1
    if [[ -n "${checkout_status_before}" ]]; then
      [[ "${GUILD_SOURCE_ALLOW_DIRTY:-N}" == "Y" ]] || return 1
      source_dirty="true"
    fi
    container="$(_guild_source_snapshot_container_create)" || return $?
    _GUILD_SOURCE_WORK_CONTAINER="${container}"
    if [[ "${source_dirty}" == "true" ]]; then
      tree_digest="$(_guild_source_snapshot_from_checkout \
        "${checkout_root}" "${revision}" "${container}")" || return $?
    else
      _guild_source_snapshot_from_git "${checkout_git_dir}" "${revision}" \
        "${container}" || return $?
    fi
    checkout_status_after="$(_guild_source_git -C "${checkout_root}" status \
      --porcelain=v1 --untracked-files=all -- scripts files 2>/dev/null)" ||
      return 1
    [[ "${checkout_status_after}" == "${checkout_status_before}" ]] || return 1
  fi

  publication="$(_guild_source_snapshot_publish "${container}")" || return $?
  snapshot_path="${publication%%$'\n'*}"
  snapshot_token="${publication#*$'\n'}"
  _guild_source_lock_release
  _GUILD_SOURCE_WORK_SUCCESS="Y"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "${repository}" "${channel}" "${mode}" "${resolved_ref}" \
    "${revision}" "${source_dirty}" "${tree_digest}" \
    "${snapshot_path}" "${container}" "${snapshot_token}"
)

guild_source_release() {
  local snapshot="${_GUILD_SOURCE_SNAPSHOT:-}"
  local container="${_GUILD_SOURCE_SNAPSHOT_CONTAINER:-}"
  local parent="${_GUILD_SOURCE_SNAPSHOT_PARENT:-}"
  local token="${_GUILD_SOURCE_SNAPSHOT_TOKEN:-}"
  local marker=""
  local safe_to_remove="N"

  if [[ "${_GUILD_SOURCE_PREPARED:-N}" == "Y" &&
        -n "${snapshot}" && -n "${container}" && -n "${parent}" &&
        -n "${token}" &&
        "$(dirname -- "${container}")" == "${parent}" &&
        "${container}" == "${parent}"/guild-source-transaction.* &&
        "${snapshot}" == "${container}/snapshot" &&
        -d "${container}" && ! -L "${container}" && -O "${container}" &&
        -d "${snapshot}" && ! -L "${snapshot}" && -O "${snapshot}" ]]; then
    marker="${snapshot}/guild-source-snapshot"
    if [[ -f "${marker}" && ! -L "${marker}" && -O "${marker}" &&
          "$(sed -n '1p' "${marker}" 2>/dev/null)" == "${token}" ]]; then
      safe_to_remove="Y"
    fi
  fi

  _GUILD_SOURCE_PREPARED="N"
  _GUILD_SOURCE_REPOSITORY=""
  _GUILD_SOURCE_CHANNEL=""
  _GUILD_SOURCE_MODE=""
  _GUILD_SOURCE_REF=""
  _GUILD_SOURCE_REVISION=""
  _GUILD_SOURCE_DIRTY="false"
  _GUILD_SOURCE_TREE_DIGEST=""
  _GUILD_SOURCE_SNAPSHOT=""
  _GUILD_SOURCE_SNAPSHOT_CONTAINER=""
  _GUILD_SOURCE_SNAPSHOT_PARENT=""
  _GUILD_SOURCE_SNAPSHOT_TOKEN=""

  if [[ "${safe_to_remove}" == "Y" ]]; then
    chmod -R u+rwX "${container}" 2>/dev/null || return 1
    rm -rf -- "${container}" || return 1
  fi
}

guild_source_prepare() {
  local repository="${1:-}"
  local channel="${2:-}"
  local mode="${3:-managed}"
  local checkout="${4:-}"
  local result_file=""
  local result_status=0
  local result_repository=""
  local result_channel=""
  local result_mode=""
  local result_ref=""
  local result_revision=""
  local result_dirty=""
  local result_digest=""
  local result_snapshot=""
  local result_container=""
  local result_token=""

  guild_source_release || return 1
  (( $# >= 2 && $# <= 4 )) || return 2
  _guild_source_resolve_git || return $?
  result_file="$(mktemp "${TMPDIR:-/tmp}/guild-source-result.XXXXXX")" || return 1
  chmod 0600 "${result_file}" || {
    rm -f -- "${result_file}"
    return 1
  }
  if _guild_source_prepare_worker "${repository}" "${channel}" "${mode}" \
    "${checkout}" >| "${result_file}"; then
    :
  else
    result_status=$?
    rm -f -- "${result_file}"
    return "${result_status}"
  fi
  {
    IFS= read -r result_repository
    IFS= read -r result_channel
    IFS= read -r result_mode
    IFS= read -r result_ref
    IFS= read -r result_revision
    IFS= read -r result_dirty
    IFS= read -r result_digest
    IFS= read -r result_snapshot
    IFS= read -r result_container
    IFS= read -r result_token
  } < "${result_file}" || {
    rm -f -- "${result_file}"
    return 1
  }
  rm -f -- "${result_file}"
  [[ -d "${result_snapshot}" &&
     "${result_snapshot}" == "${result_container}/snapshot" ]] || return 1

  _GUILD_SOURCE_REPOSITORY="${result_repository}"
  _GUILD_SOURCE_CHANNEL="${result_channel}"
  _GUILD_SOURCE_MODE="${result_mode}"
  _GUILD_SOURCE_REF="${result_ref}"
  _GUILD_SOURCE_REVISION="${result_revision}"
  _GUILD_SOURCE_DIRTY="${result_dirty}"
  _GUILD_SOURCE_TREE_DIGEST="${result_digest}"
  _GUILD_SOURCE_SNAPSHOT="${result_snapshot}"
  _GUILD_SOURCE_SNAPSHOT_CONTAINER="${result_container}"
  _GUILD_SOURCE_SNAPSHOT_PARENT="$(dirname -- "${result_container}")"
  _GUILD_SOURCE_SNAPSHOT_TOKEN="${result_token}"
  _GUILD_SOURCE_PREPARED="Y"
}

guild_source_revision() {
  [[ "${_GUILD_SOURCE_PREPARED:-N}" == "Y" &&
     -n "${_GUILD_SOURCE_REVISION:-}" ]] || return 1
  printf '%s\n' "${_GUILD_SOURCE_REVISION}"
}

guild_source_ref() {
  [[ "${_GUILD_SOURCE_PREPARED:-N}" == "Y" &&
     -n "${_GUILD_SOURCE_REF:-}" ]] || return 1
  printf '%s\n' "${_GUILD_SOURCE_REF}"
}

guild_source_path() {
  local relative_path="${1:-}"
  local source_path=""

  [[ "${_GUILD_SOURCE_PREPARED:-N}" == "Y" ]] || return 1
  _guild_source_relative_path_valid "${relative_path}" || return 2
  source_path="${_GUILD_SOURCE_SNAPSHOT}/${relative_path}"
  [[ -f "${source_path}" && ! -L "${source_path}" && -O "${source_path}" ]] ||
    return 2
  printf '%s\n' "${source_path}"
}

guild_source_report() {
  local digest_json="null"

  [[ "${_GUILD_SOURCE_PREPARED:-N}" == "Y" ]] || return 1
  if [[ "${_GUILD_SOURCE_DIRTY}" == "true" ]]; then
    [[ "${_GUILD_SOURCE_TREE_DIGEST}" =~ ^[0-9a-f]{64}$ ]] || return 1
    digest_json="\"${_GUILD_SOURCE_TREE_DIGEST}\""
  fi
  printf '{"repository":"%s","channel":"%s","mode":"%s",' \
    "${_GUILD_SOURCE_REPOSITORY}" "${_GUILD_SOURCE_CHANNEL}" \
    "${_GUILD_SOURCE_MODE}"
  printf '"ref":"%s","revision":"%s","dirty":%s,"treeDigest":%s}\n' \
    "${_GUILD_SOURCE_REF}" "${_GUILD_SOURCE_REVISION}" \
    "${_GUILD_SOURCE_DIRTY}" "${digest_json}"
}

# A prepared snapshot outlives exec(2), but shell-private provider state does
# not. The bootstrap therefore passes a narrowly validated descriptor to the
# dispatcher inside that same snapshot. Adoption is accepted only when the
# running file is the expected snapshot dispatcher and the private marker,
# owner, paths, source identity, and dirty-state invariants all agree.
guild_source_adopt_handoff() {
  local snapshot="${GUILD_SOURCE_HANDOFF_SNAPSHOT:-}"
  local container="${GUILD_SOURCE_HANDOFF_CONTAINER:-}"
  local token="${GUILD_SOURCE_HANDOFF_TOKEN:-}"
  local repository="${GUILD_SOURCE_HANDOFF_REPOSITORY:-}"
  local channel="${GUILD_SOURCE_HANDOFF_CHANNEL:-}"
  local mode="${GUILD_SOURCE_HANDOFF_MODE:-}"
  local source_ref="${GUILD_SOURCE_HANDOFF_REF:-}"
  local revision="${GUILD_SOURCE_HANDOFF_REVISION:-}"
  local dirty="${GUILD_SOURCE_HANDOFF_DIRTY:-}"
  local digest="${GUILD_SOURCE_HANDOFF_TREE_DIGEST:-}"
  local running_script=""
  local expected_script=""
  local marker=""

  [[ "${GUILD_SOURCE_HANDOFF_ACTIVE:-N}" == "Y" ]] || return 1
  running_script="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")" ||
    return 2
  expected_script="${snapshot}/scripts/cnode-helper-scripts/guild-deploy.sh"
  [[ -n "${snapshot}" && -n "${container}" && -n "${token}" &&
     "${container}" == "$(dirname -- "${container}")"/guild-source-transaction.* &&
     "${snapshot}" == "${container}/snapshot" &&
     "${running_script}" == "${expected_script}" &&
     -d "${container}" && ! -L "${container}" && -O "${container}" &&
     -d "${snapshot}" && ! -L "${snapshot}" && -O "${snapshot}" &&
     -f "${expected_script}" && ! -L "${expected_script}" && -O "${expected_script}" ]] ||
    return 2
  marker="${snapshot}/guild-source-snapshot"
  [[ -f "${marker}" && ! -L "${marker}" && -O "${marker}" &&
     "$(sed -n '1p' "${marker}" 2>/dev/null)" == "${token}" ]] || return 2
  _guild_source_resolve_git || return 2
  _guild_source_repository_valid "${repository}" || return 2
  _guild_source_channel_valid "${channel}" || return 2
  case "${mode}" in managed|cached|local) ;; *) return 2 ;; esac
  [[ "${source_ref}" == "refs/heads/${channel}" ||
     "${source_ref}" == "refs/tags/${channel}" ]] || return 2
  [[ "${revision}" =~ ^[0-9a-f]{40,64}$ ]] || return 2
  if [[ -n "${GUILD_SOURCE_EXPECT_REVISION:-}" ]]; then
    [[ "${GUILD_SOURCE_EXPECT_REVISION}" =~ ^[0-9a-f]{40,64}$ &&
       "${GUILD_SOURCE_EXPECT_REVISION}" == "${revision}" ]] || return 2
  fi
  case "${dirty}" in true|false) ;; *) return 2 ;; esac
  if [[ "${dirty}" == "true" ]]; then
    [[ "${mode}" == "local" && "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 2
  else
    [[ -z "${digest}" ]] || return 2
  fi

  _GUILD_SOURCE_PREPARED="Y"
  _GUILD_SOURCE_REPOSITORY="${repository}"
  _GUILD_SOURCE_CHANNEL="${channel}"
  _GUILD_SOURCE_MODE="${mode}"
  _GUILD_SOURCE_REF="${source_ref}"
  _GUILD_SOURCE_REVISION="${revision}"
  _GUILD_SOURCE_DIRTY="${dirty}"
  _GUILD_SOURCE_TREE_DIGEST="${digest}"
  _GUILD_SOURCE_SNAPSHOT="${snapshot}"
  _GUILD_SOURCE_SNAPSHOT_CONTAINER="${container}"
  _GUILD_SOURCE_SNAPSHOT_PARENT="$(dirname -- "${container}")"
  _GUILD_SOURCE_SNAPSHOT_TOKEN="${token}"

  unset GUILD_SOURCE_HANDOFF_ACTIVE GUILD_SOURCE_HANDOFF_SNAPSHOT
  unset GUILD_SOURCE_HANDOFF_CONTAINER GUILD_SOURCE_HANDOFF_TOKEN
  unset GUILD_SOURCE_HANDOFF_REPOSITORY GUILD_SOURCE_HANDOFF_CHANNEL
  unset GUILD_SOURCE_HANDOFF_MODE GUILD_SOURCE_HANDOFF_REF
  unset GUILD_SOURCE_HANDOFF_REVISION GUILD_SOURCE_HANDOFF_DIRTY
  unset GUILD_SOURCE_HANDOFF_TREE_DIGEST
}

dispatcher_source_path() {
  guild_source_path "$1"
}

dispatcher_source_copy() {
  local relative_path="${1:-}"
  local destination="${2:-}"
  local source_path=""

  (( $# == 2 )) || return 2
  source_path="$(dispatcher_source_path "${relative_path}")" || return $?
  [[ -n "${destination}" && "${destination}" == /* && ! -L "${destination}" ]] ||
    return 2
  cp -- "${source_path}" "${destination}"
}

dispatcher_canonical_target_path() {
  local target="${1:-}"
  local canonical="/"
  local candidate
  local component
  local -a components

  validate_deployment_path "${target}" || return 2
  IFS='/' read -r -a components <<< "${target}"
  for component in "${components[@]}"; do
    case "${component}" in
      ""|.)
        continue
        ;;
      ..)
        if [[ "${canonical}" != "/" ]]; then
          canonical="${canonical%/*}"
          [[ -n "${canonical}" ]] || canonical="/"
        fi
        ;;
      *)
        candidate="${canonical%/}/${component}"
        if [[ -L "${candidate}" && ! -e "${candidate}" ]]; then
          return 2
        elif [[ -d "${candidate}" ]]; then
          canonical="$(cd -P -- "${candidate}" 2>/dev/null && pwd -P)" ||
            return 2
        elif [[ -e "${candidate}" ]]; then
          return 2
        else
          canonical="${candidate}"
        fi
        ;;
    esac
  done
  printf '%s' "${canonical}"
}

sanitize_node_name() {
  local LC_ALL=C
  printf '%s' "${1//[^A-Za-z0-9]/_}"
}

dispatcher_lock_key() {
  local canonical_target
  canonical_target="$(dispatcher_canonical_target_path "${1:-${NODE_HOME:-}}")" ||
    return 2
  printf '%s' "${canonical_target}" |
    cksum |
    awk '{printf "%s-%s", $1, $2}'
}

dispatcher_process_identity() {
  local pid="${1:-}"
  local started="" checksum=""

  [[ "${pid}" =~ ^[0-9]+$ ]] || return 2
  if [[ -r "/proc/${pid}/stat" ]]; then
    started="$(sed 's/^.*) //' "/proc/${pid}/stat" 2>/dev/null |
      awk '{print $20}')"
    [[ "${started}" =~ ^[0-9]+$ ]] || return 1
    printf 'proc-%s' "${started}"
    return 0
  fi
  started="$(LC_ALL=C ps -o lstart= -p "${pid}" 2>/dev/null || true)"
  if [[ -n "${started//[[:space:]]/}" ]]; then
    checksum="$(printf '%s' "${started}" | cksum |
      awk '{printf "%s-%s", $1, $2}')"
    [[ "${checksum}" =~ ^[0-9]+-[0-9]+$ ]] || return 1
    printf 'ps-%s' "${checksum}"
    return 0
  fi
  # Some restricted environments deny process-start inspection. PID liveness
  # still permits safe dead-owner recovery; full process identity is used
  # whenever /proc or ps is available.
  printf 'pid-only'
}

dispatcher_directory_lock_is_owned() {
  local lock_path="${1:-}"
  local expected_pid="${2:-${BASHPID:-$$}}"
  local owner_pid="" owner_identity="" current_identity=""

  [[ -d "${lock_path}" && ! -L "${lock_path}" && -O "${lock_path}" &&
     -f "${lock_path}/owner" && ! -L "${lock_path}/owner" &&
     -O "${lock_path}/owner" ]] || return 1
  IFS=$'\t' read -r owner_pid owner_identity < "${lock_path}/owner" || return 1
  [[ "${owner_pid}" == "${expected_pid}" &&
     "${owner_identity}" =~ ^(proc-[0-9]+|ps-[0-9]+-[0-9]+|pid-only)$ ]] ||
    return 1
  current_identity="$(dispatcher_process_identity "${owner_pid}")" || return 1
  [[ "${current_identity}" == "${owner_identity}" ]]
}

dispatcher_directory_lock_acquire() {
  local lock_path="${1:-}"
  local owner_pid="" owner_identity="" current_identity="" stale_path=""
  local current_pid="${BASHPID:-$$}"

  [[ -n "${lock_path}" &&
     "${lock_path}" == /tmp/guild-operators-deployment-locks-[0-9]*/*.lock.d ]] ||
    return 2
  while :; do
    if (umask 077 && mkdir -- "${lock_path}") 2>/dev/null; then
      owner_identity="$(dispatcher_process_identity "${current_pid}")" || {
        rmdir -- "${lock_path}" 2>/dev/null || true
        return 2
      }
      if ! printf '%s\t%s\n' "${current_pid}" "${owner_identity}" > "${lock_path}/owner" ||
         ! chmod 0600 "${lock_path}/owner"; then
        rm -f -- "${lock_path}/owner" 2>/dev/null || true
        rmdir -- "${lock_path}" 2>/dev/null || true
        return 2
      fi
      return 0
    fi
    [[ -d "${lock_path}" && ! -L "${lock_path}" && -O "${lock_path}" &&
       -f "${lock_path}/owner" && ! -L "${lock_path}/owner" &&
       -O "${lock_path}/owner" ]] || return 2
    IFS=$'\t' read -r owner_pid owner_identity < "${lock_path}/owner" || return 2
    [[ "${owner_pid}" =~ ^[0-9]+$ &&
       "${owner_identity}" =~ ^(proc-[0-9]+|ps-[0-9]+-[0-9]+|pid-only)$ ]] ||
      return 2
    current_identity="$(dispatcher_process_identity "${owner_pid}" 2>/dev/null || true)"
    if kill -0 "${owner_pid}" 2>/dev/null &&
       [[ -n "${current_identity}" && "${current_identity}" == "${owner_identity}" ]]; then
      return 1
    fi
    stale_path="${lock_path}.stale.${current_pid}.$RANDOM"
    if mv -- "${lock_path}" "${stale_path}" 2>/dev/null; then
      [[ -d "${stale_path}" && ! -L "${stale_path}" && -O "${stale_path}" ]] ||
        return 2
      rm -f -- "${stale_path}/owner" || return 2
      rmdir -- "${stale_path}" || return 2
      continue
    fi
    return 1
  done
}

dispatcher_directory_lock_release() {
  local lock_path="${1:-}"
  dispatcher_directory_lock_is_owned "${lock_path}" "${BASHPID:-$$}" || return 1
  rm -f -- "${lock_path}/owner" 2>/dev/null || return 1
  rmdir -- "${lock_path}" 2>/dev/null
}

dispatcher_target_lock_is_owned() {
  local requested_target="${1:-}"
  local canonical_target
  canonical_target="$(dispatcher_canonical_target_path "${requested_target}")" ||
    return 1
  [[ "${DISPATCHER_LOCK_CANONICAL_TARGET:-}" = "${canonical_target}" &&
     "${DISPATCHER_LOCK_OWNER_PID:-}" = "${BASHPID:-$$}" ]] || return 1

  case "${DISPATCHER_LOCK_KIND:-}" in
    flock)
      [[ -n "${DISPATCHER_LOCK_PATH:-}" &&
         ! -L "${DISPATCHER_LOCK_PATH}" &&
         -f "${DISPATCHER_LOCK_PATH}" &&
         -O "${DISPATCHER_LOCK_PATH}" ]] || return 1
      : 2>/dev/null >&9 || return 1
      flock -n 9 >/dev/null 2>&1 || return 1
      ;;
    directory)
      dispatcher_directory_lock_is_owned "${DISPATCHER_LOCK_PATH:-}" "${BASHPID:-$$}" ||
        return 1
      ;;
    *)
      return 1
      ;;
  esac
}

dispatcher_acquire_target_lock() {
  local lock_base
  local lock_key
  local canonical_target
  local lock_backend="${GUILD_DEPLOY_LOCK_BACKEND:-auto}"
  lock_base="/tmp/guild-operators-deployment-locks-$(id -u)"
  canonical_target="$(dispatcher_canonical_target_path "${NODE_HOME:-}")" ||
    err_exit "Unable to resolve a safe physical deployment target for ${NODE_HOME:-unset}."

  if [[ -L "${lock_base}" ]] ||
     { [[ -e "${lock_base}" ]] && [[ ! -d "${lock_base}" || ! -O "${lock_base}" ]]; }; then
    err_exit "Unsafe deployment lock directory: ${lock_base}"
  fi
  (umask 077 && mkdir -p "${lock_base}") ||
    err_exit "Unable to create deployment lock directory ${lock_base}."
  chmod 0700 "${lock_base}" ||
    err_exit "Unable to secure deployment lock directory ${lock_base}."

  case "${lock_backend}" in
    auto)
      command -v flock >/dev/null 2>&1 && lock_backend="flock" ||
        lock_backend="directory"
      ;;
    flock)
      command -v flock >/dev/null 2>&1 ||
        err_exit "GUILD_DEPLOY_LOCK_BACKEND=flock requires flock."
      ;;
    directory) ;;
    *) err_exit "GUILD_DEPLOY_LOCK_BACKEND must be auto, flock, or directory." ;;
  esac

  if [[ "${lock_backend}" == "flock" ]]; then
    DISPATCHER_USER_LOCK_PATH="${lock_base}/user.lock"
    if [[ -L "${DISPATCHER_USER_LOCK_PATH}" ]] ||
       { [[ -e "${DISPATCHER_USER_LOCK_PATH}" ]] &&
         [[ ! -f "${DISPATCHER_USER_LOCK_PATH}" ||
            ! -O "${DISPATCHER_USER_LOCK_PATH}" ]]; }; then
      err_exit "Unsafe shared-user deployment lock: ${DISPATCHER_USER_LOCK_PATH}"
    fi
    (umask 077 && : >> "${DISPATCHER_USER_LOCK_PATH}") ||
      err_exit "Unable to create shared-user deployment lock."
    chmod 0600 "${DISPATCHER_USER_LOCK_PATH}" ||
      err_exit "Unable to secure shared-user deployment lock."
    exec 8>>"${DISPATCHER_USER_LOCK_PATH}" ||
      err_exit "Unable to open shared-user deployment lock."
    flock -n 8 || {
      exec 8>&-
      err_exit "Another Guild deployment is updating shared user resources."
    }
    DISPATCHER_USER_LOCK_KIND="flock"
  else
    DISPATCHER_USER_LOCK_PATH="${lock_base}/user.lock.d"
    dispatcher_directory_lock_acquire "${DISPATCHER_USER_LOCK_PATH}" || {
      case "$?" in
        1) err_exit "Another Guild deployment is updating shared user resources." ;;
        *) err_exit "Unsafe or unusable shared-user deployment lock: ${DISPATCHER_USER_LOCK_PATH}" ;;
      esac
    }
    DISPATCHER_USER_LOCK_KIND="directory"
  fi

  lock_key="$(dispatcher_lock_key "${canonical_target}")" ||
    err_exit "Unable to derive the deployment lock key."
  if [[ "${lock_backend}" == "flock" ]]; then
    DISPATCHER_LOCK_PATH="${lock_base}/${lock_key}.lock"
    if [[ -L "${DISPATCHER_LOCK_PATH}" ]] ||
       { [[ -e "${DISPATCHER_LOCK_PATH}" ]] && [[ ! -O "${DISPATCHER_LOCK_PATH}" ]]; }; then
      err_exit "Unsafe deployment lock file: ${DISPATCHER_LOCK_PATH}"
    fi
    (umask 077 && : >> "${DISPATCHER_LOCK_PATH}") ||
      err_exit "Unable to create deployment lock ${DISPATCHER_LOCK_PATH}."
    chmod 0600 "${DISPATCHER_LOCK_PATH}" ||
      err_exit "Unable to secure deployment lock ${DISPATCHER_LOCK_PATH}."
    if ! exec 9>>"${DISPATCHER_LOCK_PATH}"; then
      err_exit "Unable to open deployment lock ${DISPATCHER_LOCK_PATH}."
    fi
    if ! flock -n 9; then
      exec 9>&-
      err_exit "Another deployment or branch update is active for ${NODE_HOME}."
    fi
    DISPATCHER_LOCK_KIND="flock"
  else
    DISPATCHER_LOCK_PATH="${lock_base}/${lock_key}.lock.d"
    dispatcher_directory_lock_acquire "${DISPATCHER_LOCK_PATH}" || {
      case "$?" in
        1) err_exit "Another deployment or branch update is active for ${NODE_HOME}." ;;
        *) err_exit "Unsafe or unusable deployment lock: ${DISPATCHER_LOCK_PATH}" ;;
      esac
    }
    DISPATCHER_LOCK_KIND="directory"
  fi
  DISPATCHER_LOCK_CANONICAL_TARGET="${canonical_target}"
  DISPATCHER_LOCK_OWNER_PID="${BASHPID:-$$}"
  GUILD_DEPLOY_LOCK_HELD_FOR="${canonical_target}"
  export GUILD_DEPLOY_LOCK_HELD_FOR
}

dispatcher_release_target_lock() {
  case "${DISPATCHER_LOCK_KIND:-}" in
    flock)
      flock -u 9 2>/dev/null || true
      exec 9>&-
      ;;
    directory)
      dispatcher_directory_lock_release "${DISPATCHER_LOCK_PATH}" || true
      ;;
  esac
  DISPATCHER_LOCK_KIND=""
  DISPATCHER_LOCK_PATH=""
  DISPATCHER_LOCK_CANONICAL_TARGET=""
  DISPATCHER_LOCK_OWNER_PID=""
  unset GUILD_DEPLOY_LOCK_HELD_FOR
  case "${DISPATCHER_USER_LOCK_KIND:-}" in
    flock)
      flock -u 8 2>/dev/null || true
      exec 8>&-
      ;;
    directory)
      dispatcher_directory_lock_release "${DISPATCHER_USER_LOCK_PATH}" || true
      ;;
  esac
  DISPATCHER_USER_LOCK_KIND=""
  DISPATCHER_USER_LOCK_PATH=""
}

# Profiles use the same interface as the installed deployment library. The
# dispatcher already owns the target lock, so nested profile transactions are
# explicitly re-entrant without opening a second lock.
deployment_target_lock_acquire() {
  local requested_home="${1:-${NODE_HOME:-}}"
  local requested_canonical
  local node_canonical
  requested_canonical="$(dispatcher_canonical_target_path "${requested_home}")" ||
    return 2
  node_canonical="$(dispatcher_canonical_target_path "${NODE_HOME:-}")" ||
    return 2
  [[ "${requested_canonical}" = "${node_canonical}" ]] ||
    return 2
  if [[ "${GUILD_DEPLOY_LOCK_HELD_FOR:-}" = "${requested_canonical}" ]] &&
     dispatcher_target_lock_is_owned "${requested_home}"; then
    DEPLOYMENT_TARGET_LOCK_OWNED="N"
    return 0
  fi
  dispatcher_acquire_target_lock
  DEPLOYMENT_TARGET_LOCK_OWNED="Y"
}

deployment_target_lock_release() {
  if [[ "${DEPLOYMENT_TARGET_LOCK_OWNED:-N}" = "Y" ]]; then
    dispatcher_release_target_lock
  fi
  DEPLOYMENT_TARGET_LOCK_OWNED="N"
}

# Install the implementation adapter, common env, and four common libraries as
# one generation. Profiles supply their already-validated implementation name,
# payload fetch function, and force-overwrite choice. The function runs in a
# subshell so its traps and lock bookkeeping cannot leak into the dispatcher.
dispatcher_install_common_runtime_bundle() (
  local implementation="${1:-}"
  local fetch_function="${2:-}"
  local force_scripts="${3:-N}"
  local bundle_count=6
  local stage_root=""
  local target_lock_acquired="N"
  local transaction_active="N"
  local committed_count=0
  local i rollback_index rollback_ok restore_tmp
  local target_dir target_name relative_path archive_name archive_stamp
  local old_header new_runtime
  local -a targets sources downloads candidates changed
  local -a commit_tmps backups existed

  validate_implementation "${implementation}" || {
    log_warn "Cannot install a common runtime for unknown implementation '${implementation}'."
    return 2
  }
  declare -F "${fetch_function}" >/dev/null 2>&1 || {
    log_warn "Common runtime payload fetch function '${fetch_function}' is unavailable."
    return 2
  }
  case "${force_scripts}" in
    Y|N) ;;
    *)
      log_warn "Invalid common runtime force-overwrite value '${force_scripts}'."
      return 2
      ;;
  esac

  targets=(
    "${NODE_HOME}/scripts/lib/deployment.library"
    "${NODE_HOME}/scripts/lib/env.library"
    "${NODE_HOME}/scripts/lib/node-api.library"
    "${NODE_HOME}/scripts/lib/systemd.library"
    "${NODE_HOME}/scripts/adapters/${implementation}.adapter"
    "${NODE_HOME}/scripts/env"
  )
  sources=(
    "scripts/common-helper-scripts/lib"
    "scripts/common-helper-scripts/lib"
    "scripts/common-helper-scripts/lib"
    "scripts/common-helper-scripts/lib"
    "scripts/${implementation}-helper-scripts"
    "scripts/common-helper-scripts"
  )
  downloads=()
  candidates=()
  changed=()
  commit_tmps=()
  backups=()
  existed=()

  _dispatcher_runtime_rollback() {
    local rollback_count="$1"

    rollback_ok="Y"
    for (( rollback_index = rollback_count - 1; rollback_index >= 0; rollback_index-- )); do
      [[ "${changed[rollback_index]:-N}" == "Y" ]] || continue
      if [[ "${existed[rollback_index]:-N}" == "Y" ]]; then
        target_dir="$(dirname "${targets[rollback_index]}")"
        target_name="$(basename "${targets[rollback_index]}")"
        restore_tmp="$(mktemp "${target_dir}/.${target_name}.restore.XXXXXX")" || {
          rollback_ok="N"
          continue
        }
        if ! cp -p -- "${backups[rollback_index]}" "${restore_tmp}" ||
           ! mv -f -- "${restore_tmp}" "${targets[rollback_index]}"; then
          rm -f -- "${restore_tmp}"
          rollback_ok="N"
          continue
        fi
        if ! cmp -s "${backups[rollback_index]}" "${targets[rollback_index]}"; then
          rollback_ok="N"
        fi
      elif ! rm -f -- "${targets[rollback_index]}"; then
        rollback_ok="N"
      fi
    done
    [[ "${rollback_ok}" == "Y" ]]
  }

  _dispatcher_runtime_cleanup() {
    local saved_status="${1:-$?}"
    local cleanup_index

    trap - EXIT HUP INT TERM
    if [[ "${transaction_active}" == "Y" && ${committed_count} -gt 0 ]]; then
      _dispatcher_runtime_rollback "${committed_count}" || true
    fi
    for (( cleanup_index = 0; cleanup_index < bundle_count; cleanup_index++ )); do
      [[ -n "${commit_tmps[cleanup_index]:-}" ]] &&
        rm -f -- "${commit_tmps[cleanup_index]}"
    done
    [[ -n "${stage_root}" && -d "${stage_root}" ]] &&
      rm -rf -- "${stage_root}"
    if [[ "${target_lock_acquired}" == "Y" ]]; then
      deployment_target_lock_release
    fi
    return "${saved_status}"
  }

  trap '_dispatcher_runtime_cleanup "$?"' EXIT
  trap 'exit 2' HUP INT TERM

  deployment_target_lock_acquire "${NODE_HOME}" || return 2
  target_lock_acquired="Y"
  stage_root="$(mktemp -d "${NODE_HOME}/scripts/.common-runtime-install.XXXXXX")" ||
    return 2

  # A fetch or validation failure happens before any installed member changes.
  for (( i = 0; i < bundle_count; i++ )); do
    downloads[i]="${stage_root}/download.${i}"
    candidates[i]="${stage_root}/candidate.${i}"
    target_name="$(basename "${targets[i]}")"
    relative_path="${sources[i]}/${target_name}"
    if ! "${fetch_function}" "${relative_path}" "${downloads[i]}"; then
      log_warn "Failed to stage common runtime member: ${target_name}"
      return 2
    fi
    if [[ ! -s "${downloads[i]}" ]] ||
       ! "${BASH}" -n "${downloads[i]}" >/dev/null 2>&1; then
      log_warn "Downloaded common runtime member failed validation: ${target_name}"
      return 2
    fi
  done

  for (( i = 0; i < bundle_count - 1; i++ )); do
    cp -- "${downloads[i]}" "${candidates[i]}" || return 2
  done

  if [[ "${force_scripts}" != "Y" &&
        -f "${targets[5]}" &&
        -n "$(grep '^# Do NOT modify code below' "${targets[5]}" 2>/dev/null)" &&
        -n "$(grep '^# Do NOT modify code below' "${downloads[5]}" 2>/dev/null)" ]]; then
    old_header="$(awk '/^# Do NOT modify code below/{exit} {print}' "${targets[5]}")"
    new_runtime="$(awk 'copy || /^# Do NOT modify code below/{copy=1; print}' "${downloads[5]}")"
    printf '%s\n%s\n' "${old_header}" "${new_runtime}" > "${candidates[5]}" ||
      return 2
  else
    cp -- "${downloads[5]}" "${candidates[5]}" || return 2
  fi
  if ! "${BASH}" -n "${candidates[5]}" >/dev/null 2>&1; then
    log_warn "Preserved common env header failed shell validation."
    return 2
  fi

  for (( i = 0; i < bundle_count; i++ )); do
    chmod 0644 "${candidates[i]}" || return 2
    changed[i]="N"
    if [[ ! -f "${targets[i]}" ]] ||
       ! cmp -s "${targets[i]}" "${candidates[i]}" ||
       [[ -z "$(find "${targets[i]}" -prune -perm 0644 -print)" ]]; then
      changed[i]="Y"
    fi
  done

  # Prepare same-directory replacements and rollback copies before committing.
  for (( i = 0; i < bundle_count; i++ )); do
    [[ "${changed[i]}" == "Y" ]] || continue
    target_dir="$(dirname "${targets[i]}")"
    target_name="$(basename "${targets[i]}")"
    [[ -d "${target_dir}" ]] || return 2
    commit_tmps[i]="$(mktemp "${target_dir}/.${target_name}.commit.XXXXXX")" ||
      return 2
    if ! cp -- "${candidates[i]}" "${commit_tmps[i]}" ||
       ! chmod 0644 "${commit_tmps[i]}"; then
      return 2
    fi

    backups[i]="${stage_root}/backup.${i}"
    if [[ -e "${targets[i]}" ]]; then
      existed[i]="Y"
      cp -p -- "${targets[i]}" "${backups[i]}" || return 2
    else
      existed[i]="N"
    fi
  done

  transaction_active="Y"
  for (( i = 0; i < bundle_count; i++ )); do
    committed_count=$((i + 1))
    [[ "${changed[i]}" == "Y" ]] || continue
    if ! mv -f -- "${commit_tmps[i]}" "${targets[i]}"; then
      if _dispatcher_runtime_rollback "${committed_count}"; then
        transaction_active="N"
      fi
      return 2
    fi
    commit_tmps[i]=""
    if ! cmp -s "${candidates[i]}" "${targets[i]}" ||
       [[ -z "$(find "${targets[i]}" -prune -perm 0644 -print)" ]]; then
      if _dispatcher_runtime_rollback "${committed_count}"; then
        transaction_active="N"
      fi
      return 2
    fi
  done
  transaction_active="N"

  archive_stamp="$(date +%s)"
  for (( i = 0; i < bundle_count; i++ )); do
    [[ "${changed[i]}" == "Y" && "${existed[i]:-N}" == "Y" ]] || continue
    target_name="$(basename "${targets[i]}")"
    if [[ ${i} -eq 5 ]]; then
      archive_name="${target_name}_bkp${archive_stamp}"
    else
      archive_name="${sources[i]//\//_}_${target_name}_bkp${archive_stamp}"
    fi
    cp -f -- "${backups[i]}" "${NODE_HOME}/scripts/archive/${archive_name}" ||
      log_warn "Could not archive the previous ${target_name}; the runtime bundle is installed."
  done

  return 0
)

detect_legacy_network() {
  local genesis="${NODE_HOME}/files/shelley-genesis.json"
  local magic=""
  if [[ -s "${genesis}" ]] && command -v jq >/dev/null 2>&1; then
    magic="$(jq -er '.networkMagic' "${genesis}" 2>/dev/null || true)"
  fi
  case "${magic}" in
    764824073) printf 'mainnet' ;;
    141) printf 'guild' ;;
    1) printf 'preprod' ;;
    2) printf 'preview' ;;
    *) return 1 ;;
  esac
}

detect_partial_target_network() {
  case "${NODE_IMPLEMENTATION}" in
    cnode)
      detect_legacy_network
      ;;
    dingo)
      if [[ -s "${NODE_HOME}/scripts/dingo.env" ]]; then
        sed -n 's/^CARDANO_NETWORK="\([^"]*\)".*/\1/p' \
          "${NODE_HOME}/scripts/dingo.env" | head -n 1
      elif [[ -s "${NODE_HOME}/files/dingo.yaml" ]]; then
        sed -n 's/^[[:space:]]*network:[[:space:]]*"\([^"]*\)".*/\1/p' \
          "${NODE_HOME}/files/dingo.yaml" | head -n 1
      fi
      ;;
    amaru)
      if [[ -s "${NODE_HOME}/scripts/amaru.env" ]]; then
        sed -n 's/^AMARU_NETWORK="\([^"]*\)".*/\1/p' \
          "${NODE_HOME}/scripts/amaru.env" | head -n 1
      fi
      ;;
  esac
}

partial_target_matches_implementation() {
  local adapter="${NODE_HOME}/scripts/adapters/${NODE_IMPLEMENTATION}.adapter"
  if [[ -f "${adapter}" ]] &&
     grep -q "^NODE_ADAPTER_IMPLEMENTATION=\"${NODE_IMPLEMENTATION}\"$" "${adapter}"; then
    return 0
  fi

  case "${NODE_IMPLEMENTATION}" in
    cnode)
      [[ -f "${NODE_HOME}/scripts/cnode.sh" || -f "${NODE_HOME}/files/config.json" ]]
      ;;
    dingo)
      [[ -f "${NODE_HOME}/scripts/dingo.sh" &&
         ( -f "${NODE_HOME}/scripts/dingo.env" || -f "${NODE_HOME}/files/dingo.yaml" ) ]]
      ;;
    amaru)
      [[ -f "${NODE_HOME}/scripts/amaru.sh" && -f "${NODE_HOME}/scripts/amaru.env" ]]
      ;;
  esac
}

dispatcher_set_defaults() {
  : "${LEGACY_CNODE_TARGET:=N}"
  : "${NETWORK_PRESET:=N}"
  [[ -z "${G_ACCOUNT:-}" ]] && G_ACCOUNT="cardano-community"
  [[ -z "${CURL_TIMEOUT:-}" ]] && CURL_TIMEOUT=60
  [[ -z "${DOWNLOAD_TIMEOUT:-}" ]] && DOWNLOAD_TIMEOUT=600
  [[ -z "${UPDATE_CHECK:-}" ]] && UPDATE_CHECK="Y"
  [[ -z "${SUDO:-}" ]] && SUDO="Y"
  [[ -z "${PACKAGE_MANAGER_OUTPUT:-}" ]] && PACKAGE_MANAGER_OUTPUT="compact"
  [[ -z "${GUILD_SOURCE_MODE:-}" ]] && GUILD_SOURCE_MODE="managed"
  [[ -z "${GUILD_SOURCE_CHECKOUT:-}" ]] && GUILD_SOURCE_CHECKOUT=""
  [[ -z "${GUILD_SOURCE_ALLOW_DIRTY:-}" ]] && GUILD_SOURCE_ALLOW_DIRTY="N"
  [[ -z "${GUILD_SOURCE_ALLOW_REPOSITORY_CHANGE:-}" ]] &&
    GUILD_SOURCE_ALLOW_REPOSITORY_CHANGE="N"
  [[ -z "${GUILD_SOURCE_EXPECT_REVISION:-}" ]] &&
    GUILD_SOURCE_EXPECT_REVISION=""
  [[ -z "${GUILD_DOCKER_EXPORT_ROOT:-}" ]] && GUILD_DOCKER_EXPORT_ROOT=""
  case "${PACKAGE_MANAGER_OUTPUT}" in
    compact|verbose) ;;
    *) err_exit "PACKAGE_MANAGER_OUTPUT must be compact or verbose." ;;
  esac
  case "${GUILD_SOURCE_MODE}" in managed|cached|local) ;; *)
    err_exit "GUILD_SOURCE_MODE must be managed, cached, or local." ;;
  esac
  case "${GUILD_SOURCE_ALLOW_DIRTY}" in Y|N) ;; *)
    err_exit "GUILD_SOURCE_ALLOW_DIRTY must be Y or N." ;;
  esac
  case "${GUILD_SOURCE_ALLOW_REPOSITORY_CHANGE}" in Y|N) ;; *)
    err_exit "GUILD_SOURCE_ALLOW_REPOSITORY_CHANGE must be Y or N." ;;
  esac
  [[ -z "${GUILD_SOURCE_EXPECT_REVISION}" ||
     "${GUILD_SOURCE_EXPECT_REVISION}" =~ ^[0-9a-f]{40,64}$ ]] ||
    err_exit "GUILD_SOURCE_EXPECT_REVISION must be an exact lowercase Git commit ID."
  if [[ -n "${GUILD_DOCKER_EXPORT_ROOT}" ]]; then
    [[ "${GUILD_DOCKER_EXPORT_ROOT}" == /* &&
       "${GUILD_DOCKER_EXPORT_ROOT}" != "/" &&
       "${GUILD_DOCKER_EXPORT_ROOT}" != *//* &&
       "${GUILD_DOCKER_EXPORT_ROOT}" != */../* &&
       "${GUILD_DOCKER_EXPORT_ROOT}" != */.. &&
       "${GUILD_DOCKER_EXPORT_ROOT}" != */./* &&
       "${GUILD_DOCKER_EXPORT_ROOT}" != */. &&
       ! "${GUILD_DOCKER_EXPORT_ROOT}" =~ [[:cntrl:]] ]] ||
      err_exit "Docker supplement export path is unsafe: ${GUILD_DOCKER_EXPORT_ROOT}"
  fi

  [[ -z "${NODE_IMPLEMENTATION:-}" ]] && NODE_IMPLEMENTATION="${CNODE_IMPLEMENTATION:-cnode}"
  validate_implementation "${NODE_IMPLEMENTATION}" || err_exit "Unknown node implementation '${NODE_IMPLEMENTATION}'. Expected cnode, dingo, or amaru."

  if [[ -z "${NODE_PORT:-}" ]]; then
    case "${NODE_IMPLEMENTATION}" in
      cnode) NODE_PORT=6000 ;;
      dingo) NODE_PORT=3001 ;;
      amaru) NODE_PORT=3000 ;;
    esac
  fi
  if [[ ! "${DOWNLOAD_TIMEOUT}" =~ ^[0-9]+$ ]] ||
     (( 10#${DOWNLOAD_TIMEOUT} < 1 )); then
    err_exit "DOWNLOAD_TIMEOUT must be a positive integer."
  fi
  DOWNLOAD_TIMEOUT="$((10#${DOWNLOAD_TIMEOUT}))"

  if [[ -z "${CNODE_SKIP_DBSYNC_DOWNLOAD:-}" &&
        -n "${SKIP_DBSYNC_DOWNLOAD:-}" ]]; then
    CNODE_SKIP_DBSYNC_DOWNLOAD="${SKIP_DBSYNC_DOWNLOAD}"
  fi
  [[ -z "${CNODE_SKIP_DBSYNC_DOWNLOAD:-}" ]] &&
    CNODE_SKIP_DBSYNC_DOWNLOAD="N"
  case "${CNODE_SKIP_DBSYNC_DOWNLOAD}" in
    Y|N) ;;
    *) err_exit "CNODE_SKIP_DBSYNC_DOWNLOAD must be Y or N." ;;
  esac
  unset SKIP_DBSYNC_DOWNLOAD

  [[ -z "${NODE_PARENT:-}" ]] && NODE_PARENT="${CNODE_PATH:-/opt/cardano}"
  validate_deployment_path "${NODE_PARENT}" ||
    err_exit "The parent path must be absolute and contain only letters, digits, /, ., _, +, @, :, or -: ${NODE_PARENT}"
  while [[ "${NODE_PARENT}" != "/" && "${NODE_PARENT}" = */ ]]; do
    NODE_PARENT="${NODE_PARENT%/}"
  done
  validate_deployment_path "${HOME:-}" ||
    err_exit "HOME must be an absolute path containing only deployment-safe characters."

  if [[ -z "${NODE_NAME:-}" ]]; then
    if [[ "${NODE_IMPLEMENTATION}" = "cnode" && -n "${CNODE_NAME:-}" ]]; then
      NODE_NAME="${CNODE_NAME}"
    else
      NODE_NAME="${NODE_IMPLEMENTATION}"
    fi
  fi
  NODE_NAME="$(sanitize_node_name "${NODE_NAME}")"
  [[ "${NODE_NAME}" =~ ^[A-Za-z0-9_]+$ ]] ||
    err_exit "The top-level folder name must resolve to ASCII letters, digits, or underscore."

  NODE_HOME="${NODE_PARENT%/}/${NODE_NAME}"
  NODE_SERVICE="$(printf '%s' "${NODE_NAME}" | tr '[:upper:]' '[:lower:]')"
  validate_deployment_path "${NODE_HOME}" ||
    err_exit "The computed deployment path contains unsupported characters: ${NODE_HOME}"
  if [[ -n "${GUILD_DOCKER_EXPORT_ROOT:-}" &&
        ( "${GUILD_DOCKER_EXPORT_ROOT}" == "${NODE_HOME}" ||
          "${GUILD_DOCKER_EXPORT_ROOT}" == "${NODE_HOME}"/* ) ]]; then
    err_exit "Docker supplement export must be outside the deployment target: ${NODE_HOME}"
  fi
  [[ "${NODE_SERVICE}" =~ ^[a-z0-9_]+$ ]] ||
    err_exit "The computed service name is invalid: ${NODE_SERVICE}"
  DEPLOYMENT_FILE="${NODE_HOME}/.deployment.json"
  if [[ "${DISPATCHER_LOCK_TARGET:-N}" != "Y" ]]; then
    GUILD_SOURCE_TARGET_JOURNAL_ADMITTED="N"
    GUILD_SOURCE_TARGET_JOURNAL_TOKEN=""
    if [[ -e "${NODE_HOME}/.guild-deploy-transaction" ||
          -L "${NODE_HOME}/.guild-deploy-transaction" ]]; then
      GUILD_SOURCE_TARGET_JOURNAL_TOKEN="$(
        dispatcher_transaction_handoff_admission_token
      )" || err_exit "Unsafe interrupted deployment journal at ${NODE_HOME}/.guild-deploy-transaction."
      GUILD_SOURCE_TARGET_JOURNAL_ADMITTED="Y"
      log_info "Interrupted deployment journal detected; recovery will run after source handoff."
    fi
  fi
  if [[ "${DISPATCHER_LOCK_TARGET:-N}" = "Y" ]]; then
    dispatcher_acquire_target_lock
    dispatcher_transaction_handoff_revalidate ||
      err_exit "The interrupted deployment journal changed during source preparation; rerun the command."
    if [[ -d "${NODE_HOME}" && ! -L "${NODE_HOME}" ]]; then
      dispatcher_recover_interrupted_transaction
    fi
  fi

  local stored_implementation=""
  local stored_network=""
  local stored_branch=""
  local stored_schema=""
  local stored_status=""
  local stored_repository=""
  local stored_service=""
  local stored_account=""
  local stored_node_port=""
  if [[ -L "${DEPLOYMENT_FILE}" ||
        ( -e "${DEPLOYMENT_FILE}" && ! -s "${DEPLOYMENT_FILE}" ) ]]; then
    err_exit "Deployment metadata is empty or an unsafe symbolic link: ${DEPLOYMENT_FILE}"
  elif [[ -s "${DEPLOYMENT_FILE}" ]]; then
    command -v jq >/dev/null 2>&1 ||
      err_exit "jq is required to validate existing deployment metadata at ${DEPLOYMENT_FILE}."
    if ! jq -e '
      type == "object" and
      .schemaVersion == 1 and
      (.deploymentStatus == "deploying" or .deploymentStatus == "deployed") and
      (.implementation == "cnode" or .implementation == "dingo" or .implementation == "amaru") and
      (.network | type == "string" and length > 0) and
      (.branch | type == "string" and length > 0) and
      (.repository | type == "string" and test("^[A-Za-z0-9_.-]+/guild-operators$")) and
      (.serviceName | type == "string" and length > 0) and
      ((has("nodePort") | not) or
        (.nodePort | type == "number" and . >= 1 and . <= 65535 and
          . == floor)) and
      (.nodeVersion | type == "string") and
      (.targetNodeVersion | type == "string") and
      (.metricsProvider | type == "string" and length > 0) and
      (.capabilities | type == "object") and
      (.capabilities | keys == ["forging", "localCli", "metrics", "n2c"]) and
      (.capabilities.n2c | type == "boolean") and
      (.capabilities.localCli | type == "boolean") and
      (.capabilities.metrics | type == "boolean") and
      (.capabilities.forging | type == "boolean") and
      (
        (has("sourceSchemaVersion") | not) or
        (
          (.sourceSchemaVersion == 1 or .sourceSchemaVersion == 2) and
          (.sourceMode == "managed" or .sourceMode == "cached" or .sourceMode == "local") and
          (.sourceRef | type == "string" and test("^refs/(heads|tags)/")) and
          (.sourceRevision | type == "string" and test("^[0-9a-f]{40,64}$")) and
          (.sourceDirty | type == "boolean") and
          (
            (.sourceDirty == false and (has("sourceTreeDigest") | not)) or
            (.sourceDirty == true and .sourceMode == "local" and
              (.sourceTreeDigest | type == "string" and test("^[0-9a-f]{64}$")))
          ) and
          (.payloadReceipt | type == "string" and . == ".guild-source-receipt.json") and
          (.payloadReceiptSha256 | type == "string" and test("^[0-9a-f]{64}$")) and
          (.transactionId | type == "string" and test("^[0-9a-f]{16,64}$"))
        )
      ) and
      (
        (.implementation == "cnode" and
          .metricsProvider == "prometheus" and
          .capabilities.n2c == true and
          .capabilities.localCli == true and
          .capabilities.metrics == true and
          .capabilities.forging == true) or
        (.implementation == "dingo" and
          .metricsProvider == "prometheus" and
          .capabilities.n2c == true and
          .capabilities.localCli == true and
          .capabilities.metrics == true and
          .capabilities.forging == true) or
        (.implementation == "amaru" and
          .metricsProvider == "otel" and
          .capabilities.n2c == false and
          .capabilities.localCli == false and
          .capabilities.metrics == true and
          .capabilities.forging == false)
      )
    ' "${DEPLOYMENT_FILE}" >/dev/null 2>&1; then
      err_exit "Deployment metadata is malformed, incomplete, or unsupported: ${DEPLOYMENT_FILE}"
    fi
    stored_schema="$(deployment_json_get "${DEPLOYMENT_FILE}" schemaVersion || true)"
    stored_status="$(deployment_json_get "${DEPLOYMENT_FILE}" deploymentStatus || true)"
    stored_implementation="$(deployment_json_get "${DEPLOYMENT_FILE}" implementation || true)"
    stored_network="$(deployment_json_get "${DEPLOYMENT_FILE}" network || true)"
    stored_branch="$(deployment_json_get "${DEPLOYMENT_FILE}" branch || true)"
    stored_repository="$(deployment_json_get "${DEPLOYMENT_FILE}" repository || true)"
    stored_service="$(deployment_json_get "${DEPLOYMENT_FILE}" serviceName || true)"
    stored_node_port="$(deployment_json_get "${DEPLOYMENT_FILE}" nodePort || true)"

    [[ "${stored_schema}" = "1" ]] ||
      err_exit "Unsupported or invalid deployment manifest schema in ${DEPLOYMENT_FILE}."
    case "${stored_status}" in
      deploying|deployed) ;;
      *) err_exit "Invalid deployment status in ${DEPLOYMENT_FILE}." ;;
    esac
    [[ -n "${stored_implementation}" ]] || err_exit "Invalid deployment manifest: ${DEPLOYMENT_FILE}"
    [[ -n "${stored_network}" && -n "${stored_branch}" && -n "${stored_repository}" ]] ||
      err_exit "Deployment manifest is missing authoritative target metadata: ${DEPLOYMENT_FILE}"
    [[ "${stored_implementation}" = "${NODE_IMPLEMENTATION}" ]] || err_exit "Target ${NODE_HOME} belongs to '${stored_implementation}', not '${NODE_IMPLEMENTATION}'. Choose another -t value."
    case "${stored_implementation}:${stored_network}" in
      cnode:mainnet|cnode:guild|cnode:preprod|cnode:preview|dingo:preprod|dingo:preview|amaru:preprod|amaru:preview) ;;
      *) err_exit "Unsupported network '${stored_network}' for '${stored_implementation}' in ${DEPLOYMENT_FILE}." ;;
    esac
    [[ -n "${stored_service}" && "${stored_service}" = "${NODE_SERVICE}" ]] ||
      err_exit "Deployment manifest serviceName '${stored_service:-missing}' does not match target service '${NODE_SERVICE}'."

    if [[ -n "${stored_repository}" ]]; then
      [[ "${stored_repository}" =~ ^([A-Za-z0-9_.-]+)/guild-operators$ ]] ||
        err_exit "Invalid repository in deployment manifest: ${stored_repository}"
      stored_account="${BASH_REMATCH[1]}"
      if [[ "${G_ACCOUNT_PRESET:-N}" != "Y" ]]; then
        G_ACCOUNT="${stored_account}"
      elif [[ "${stored_account}" != "${G_ACCOUNT}" &&
              "${GUILD_SOURCE_ALLOW_REPOSITORY_CHANGE}" != "Y" ]]; then
        err_exit "Target ${NODE_HOME} belongs to '${stored_repository}'. Use -R with an explicit -a account to migrate it to '${G_ACCOUNT}/guild-operators'."
      fi
    fi

    if [[ "${NETWORK_EXPLICIT}" != "Y" && "${NETWORK_PRESET}" != "Y" && -n "${stored_network}" ]]; then
      NETWORK="${stored_network}"
    elif [[ -n "${NETWORK:-}" && -n "${stored_network}" && "${NETWORK}" != "${stored_network}" ]]; then
      err_exit "Target ${NODE_HOME} is configured for '${stored_network}', not '${NETWORK}'. Use a separate target directory."
    fi

    if [[ "${BRANCH_EXPLICIT}" != "Y" && "${BRANCH_PRESET}" != "Y" && -n "${stored_branch}" ]]; then
      BRANCH="${stored_branch}"
    fi
    if [[ "${NODE_PORT_PRESET:-N}" != "Y" && -n "${stored_node_port}" ]]; then
      NODE_PORT="${stored_node_port}"
    fi
  elif [[ -d "${NODE_HOME}" ]] && find "${NODE_HOME}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    local detected_network=""
    if [[ "${DISPATCHER_LOCK_TARGET:-N}" != "Y" &&
          "${GUILD_SOURCE_TARGET_JOURNAL_ADMITTED:-N}" == "Y" ]]; then
      # Exact journal identity was authenticated above regardless of whether
      # deployment metadata exists. Defer all mutation until the snapshot
      # dispatcher holds the target lock and revalidates the handed-off token.
      :
    elif partial_target_matches_implementation; then
      detected_network="$(detect_partial_target_network || true)"
      if [[ "${NETWORK_EXPLICIT}" != "Y" && "${NETWORK_PRESET}" != "Y" &&
            -z "${NETWORK:-}" && -n "${detected_network}" ]]; then
        NETWORK="${detected_network}"
      elif [[ -n "${NETWORK:-}" && -n "${detected_network}" &&
              "${NETWORK}" != "${detected_network}" ]]; then
        err_exit "Target ${NODE_HOME} is configured for '${detected_network}', not '${NETWORK}'. Use a separate target directory."
      fi

      if [[ "${NODE_IMPLEMENTATION}" = "cnode" ]]; then
        LEGACY_CNODE_TARGET="Y"
        if [[ "${BRANCH_EXPLICIT}" != "Y" && "${BRANCH_PRESET}" != "Y" && -s "${NODE_HOME}/scripts/.env_branch" ]]; then
          BRANCH="$(head -n 1 "${NODE_HOME}/scripts/.env_branch")"
        fi
        log_info "Legacy cnode target detected; it will be migrated to .deployment.json."
      else
        log_info "Incomplete ${NODE_IMPLEMENTATION} deployment detected; it will be resumed."
      fi
    elif ! find "${NODE_HOME}" -mindepth 1 \( -type f -o -type l \) -print -quit 2>/dev/null | grep -q .; then
      log_info "Empty deployment directory skeleton detected; deployment will resume."
    else
      err_exit "Refusing to deploy into non-empty unrecognized target ${NODE_HOME}."
    fi
  fi

  if [[ ! "${NODE_PORT}" =~ ^[0-9]+$ ]] ||
     (( 10#${NODE_PORT} < 1 || 10#${NODE_PORT} > 65535 )); then
    err_exit "NODE_PORT must be an integer from 1 to 65535."
  fi
  NODE_PORT="$((10#${NODE_PORT}))"

  if [[ -z "${NETWORK:-}" ]]; then
    if [[ "${NODE_IMPLEMENTATION}" = "cnode" && "${LEGACY_CNODE_TARGET}" != "Y" ]]; then
      NETWORK="mainnet"
    elif [[ "${NODE_IMPLEMENTATION}" = "cnode" ]]; then
      err_exit "Could not determine the network of legacy target ${NODE_HOME}; specify it with -n."
    else
      err_exit "The ${NODE_IMPLEMENTATION} profile requires -n preprod or -n preview."
    fi
  fi
  [[ -z "${BRANCH:-}" ]] && BRANCH="master"
  validate_branch_name "${BRANCH}" || err_exit "Invalid branch name '${BRANCH}'."
  validate_account_name "${G_ACCOUNT}" || err_exit "Invalid GitHub account '${G_ACCOUNT}'."
  if [[ "${_GUILD_SOURCE_PREPARED:-N}" == "Y" ]]; then
    [[ "${_GUILD_SOURCE_REPOSITORY,,}" == "${G_ACCOUNT,,}/guild-operators" &&
       "${_GUILD_SOURCE_CHANNEL}" == "${BRANCH}" &&
       "${_GUILD_SOURCE_MODE}" == "${GUILD_SOURCE_MODE}" ]] ||
      err_exit "The locked target identity disagrees with the prepared Guild source snapshot."
  fi

  [[ "${SUDO}" = "Y" ]] && sudo="sudo" || sudo=""
  if [[ "${SUDO}" = "Y" && "$(id -u)" -eq 0 ]]; then
    err_exit "Please run as a non-root user, or set SUDO=N for a controlled container build."
  fi

  export G_ACCOUNT CURL_TIMEOUT DOWNLOAD_TIMEOUT UPDATE_CHECK SUDO sudo
  export PACKAGE_MANAGER_OUTPUT
  export NODE_IMPLEMENTATION NODE_PARENT NODE_NAME NODE_HOME NODE_SERVICE
  export NODE_PORT NETWORK BRANCH S_ARGS
  export GUILD_SOURCE_MODE GUILD_SOURCE_CHECKOUT GUILD_SOURCE_ALLOW_DIRTY
  export GUILD_SOURCE_ALLOW_REPOSITORY_CHANGE
  if [[ "${NODE_IMPLEMENTATION}" = "cnode" ]]; then
    export CNODE_SKIP_DBSYNC_DOWNLOAD
  else
    unset CNODE_SKIP_DBSYNC_DOWNLOAD
  fi

  # Compatibility aliases used by the current cnode implementation profile.
  CNODE_PATH="${NODE_PARENT}"
  CNODE_NAME="${NODE_NAME}"
  CNODE_HOME="${NODE_HOME}"
  CNODE_VNAME="${NODE_SERVICE}"
  export CNODE_PATH CNODE_NAME CNODE_HOME CNODE_VNAME
}

dispatcher_sha256() {
  local file="$1"
  local digest=""

  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "${file}" 2>/dev/null)" || return 1
    digest="${digest%% *}"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 "${file}" 2>/dev/null)" || return 1
    digest="${digest%% *}"
  else
    return 1
  fi
  [[ "${digest}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s\n' "$(printf '%s' "${digest}" | tr '[:upper:]' '[:lower:]')"
}

dispatcher_validate_bootstrap_prerequisites() {
  local -a missing=()
  local lock_os=""

  _guild_source_resolve_git >/dev/null 2>&1 || missing+=(git)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  if ! command -v sha256sum >/dev/null 2>&1 &&
     ! command -v shasum >/dev/null 2>&1; then
    missing+=(sha256sum-or-shasum)
  fi
  # Before defaults/legacy metadata are restored, an omitted -i still means
  # cnode. Use that effective default so the lock backend is rejected during
  # bootstrap instead of much later while staging the generation transaction.
  if [[ "${NODE_IMPLEMENTATION:-cnode}" == "cnode" ||
        "${NODE_IMPLEMENTATION:-cnode}" == "dingo" ]]; then
    lock_os="$(command -p uname -s 2>/dev/null || true)"
    case "${lock_os}" in
      Linux)
        command -v flock >/dev/null 2>&1 || missing+=(flock)
        ;;
      Darwin|FreeBSD|OpenBSD|NetBSD)
        command -v lockf >/dev/null 2>&1 || missing+=(lockf)
        ;;
      *) missing+=(supported-advisory-lock-backend) ;;
    esac
  fi
  if (( ${#missing[@]} > 0 )); then
    err_exit "Missing bootstrap prerequisite(s): ${missing[*]}. Install Git, jq, a SHA-256 utility, and the platform advisory-lock utility before running guild-deploy.sh."
  fi
}

dispatcher_target_fingerprint() {
  local metadata="${1:-}"
  local digest=""

  [[ -n "${metadata}" && "${metadata}" == /* ]] || return 2
  if [[ -L "${metadata}" ]]; then
    printf 'symlink\n'
  elif [[ -f "${metadata}" ]]; then
    digest="$(dispatcher_sha256 "${metadata}")" || return 1
    printf 'file:%s\n' "${digest}"
  elif [[ -e "${metadata}" ]]; then
    printf 'other\n'
  else
    printf 'absent\n'
  fi
}

dispatcher_verify_target_fingerprint() {
  local current=""

  [[ -n "${GUILD_SOURCE_TARGET_METADATA:-}" &&
     -n "${GUILD_SOURCE_TARGET_FINGERPRINT:-}" &&
     "${DEPLOYMENT_FILE:-}" == "${GUILD_SOURCE_TARGET_METADATA}" ]] ||
    err_exit "The source handoff target identity is incomplete or changed."
  current="$(dispatcher_target_fingerprint "${DEPLOYMENT_FILE}")" ||
    err_exit "Could not revalidate deployment metadata after source preparation."
  [[ "${current}" == "${GUILD_SOURCE_TARGET_FINGERPRINT}" ]] ||
    err_exit "Deployment metadata changed while the source snapshot was prepared; rerun the command."
  unset GUILD_SOURCE_TARGET_METADATA GUILD_SOURCE_TARGET_FINGERPRINT
  unset GUILD_SOURCE_TARGET_JOURNAL_ADMITTED
  unset GUILD_SOURCE_TARGET_JOURNAL_TOKEN
  DISPATCHER_HANDOFF_JOURNAL_REFRESH_AUTHORIZED="N"
}

dispatcher_refresh_handoff_fingerprint_after_recovery() {
  local current=""

  dispatcher_target_lock_is_owned "${NODE_HOME}" || return 2
  if [[ -z "${GUILD_SOURCE_TARGET_METADATA:-}" &&
        -z "${GUILD_SOURCE_TARGET_FINGERPRINT:-}" ]]; then
    return 0
  fi
  [[ -n "${GUILD_SOURCE_TARGET_METADATA:-}" &&
     -n "${GUILD_SOURCE_TARGET_FINGERPRINT:-}" &&
     "${GUILD_SOURCE_TARGET_METADATA}" == "${DEPLOYMENT_FILE}" &&
     "${GUILD_SOURCE_TARGET_JOURNAL_ADMITTED:-N}" == "Y" &&
     -n "${GUILD_SOURCE_TARGET_JOURNAL_TOKEN:-}" &&
     "${DISPATCHER_HANDOFF_JOURNAL_REFRESH_AUTHORIZED:-N}" == "Y" ]] ||
    return 2
  current="$(dispatcher_target_fingerprint "${DEPLOYMENT_FILE}")" || return 2
  # Recovery is the sole authorized target mutation between handoff
  # fingerprints. Refresh only after the locked journal has been completely
  # authenticated, recovered/retired, and removed.
  GUILD_SOURCE_TARGET_FINGERPRINT="${current}"
  GUILD_SOURCE_TARGET_JOURNAL_ADMITTED="N"
  GUILD_SOURCE_TARGET_JOURNAL_TOKEN=""
  DISPATCHER_HANDOFF_JOURNAL_REFRESH_AUTHORIZED="N"
}

dispatcher_prepare_source_and_handoff() {
  local source_mode="${GUILD_SOURCE_MODE:-managed}"
  local source_checkout="${GUILD_SOURCE_CHECKOUT:-}"
  local source_dispatcher=""
  local launcher=""
  local launcher_header=""
  local installed_revision=""
  local resolved_revision=""

  case "${source_mode}" in
    managed|cached)
      [[ -z "${source_checkout}" ]] ||
        err_exit "GUILD_SOURCE_CHECKOUT is valid only with local source mode."
      ;;
    local)
      [[ -n "${source_checkout}" ]] ||
        err_exit "Local source mode requires -L or GUILD_SOURCE_CHECKOUT."
      ;;
    *) err_exit "Unknown Guild source mode '${source_mode}'." ;;
  esac
  case "${GUILD_SOURCE_ALLOW_DIRTY:-N}" in Y|N) ;; *)
    err_exit "GUILD_SOURCE_ALLOW_DIRTY must be Y or N." ;;
  esac
  export GUILD_SOURCE_ALLOW_DIRTY

  launcher="$(cd -P -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)/$(basename -- "$0")" ||
    err_exit "Could not resolve the bootstrap dispatcher path."
  [[ -f "${launcher}" && ! -L "${launcher}" && -O "${launcher}" &&
     -s "${launcher}" ]] ||
    err_exit "The bootstrap dispatcher must be a regular, owner-controlled file: ${launcher}"
  "${BASH}" -n "${launcher}" >/dev/null 2>&1 ||
    err_exit "The bootstrap dispatcher failed shell validation: ${launcher}"
  grep -q '^# Do NOT modify code below' "${launcher}" ||
    err_exit "The bootstrap dispatcher does not expose the user-header boundary: ${launcher}"
  launcher_header="$(awk '/^#!/{copy=1} /^# Do NOT modify/{exit} copy' "${launcher}")"
  [[ -n "${launcher_header}" ]] ||
    err_exit "Could not freeze the bootstrap dispatcher user header."

  log_progress "Preparing Guild source snapshot" "${G_ACCOUNT}/guild-operators ${BRANCH} (${source_mode})"
  guild_source_prepare "${G_ACCOUNT}/guild-operators" "${BRANCH}" \
    "${source_mode}" "${source_checkout}" ||
    err_exit "Could not prepare exact Guild source '${G_ACCOUNT}/guild-operators' channel '${BRANCH}' in ${source_mode} mode."
  resolved_revision="$(guild_source_revision)" ||
    err_exit "The prepared Guild source did not publish a revision."
  if [[ -n "${GUILD_SOURCE_EXPECT_REVISION:-}" &&
        "${resolved_revision}" != "${GUILD_SOURCE_EXPECT_REVISION}" ]]; then
    err_exit "Prepared Guild revision ${resolved_revision} does not match required revision ${GUILD_SOURCE_EXPECT_REVISION}."
  fi
  log_ok "Guild source snapshot ready" "${resolved_revision}"

  if [[ "${GUILD_SOURCE_CHECK_ONLY:-N}" == "Y" ]]; then
    if [[ -s "${DEPLOYMENT_FILE}" ]]; then
      installed_revision="$(deployment_json_get "${DEPLOYMENT_FILE}" sourceRevision || true)"
    fi
    printf '%s\n' "${resolved_revision}"
    guild_source_release || true
    [[ -n "${installed_revision}" && "${installed_revision}" == "${resolved_revision}" ]] &&
      return 0
    return 10
  fi

  source_dispatcher="$(guild_source_path scripts/cnode-helper-scripts/guild-deploy.sh)" ||
    err_exit "The prepared source does not contain guild-deploy.sh."
  [[ -s "${source_dispatcher}" ]] && "${BASH}" -n "${source_dispatcher}" ||
    err_exit "The prepared guild-deploy.sh failed validation."
  GUILD_SOURCE_HANDOFF_ACTIVE="Y"
  GUILD_SOURCE_HANDOFF_SNAPSHOT="${_GUILD_SOURCE_SNAPSHOT}"
  GUILD_SOURCE_HANDOFF_CONTAINER="${_GUILD_SOURCE_SNAPSHOT_CONTAINER}"
  GUILD_SOURCE_HANDOFF_TOKEN="${_GUILD_SOURCE_SNAPSHOT_TOKEN}"
  GUILD_SOURCE_HANDOFF_REPOSITORY="${_GUILD_SOURCE_REPOSITORY}"
  GUILD_SOURCE_HANDOFF_CHANNEL="${_GUILD_SOURCE_CHANNEL}"
  GUILD_SOURCE_HANDOFF_MODE="${_GUILD_SOURCE_MODE}"
  GUILD_SOURCE_HANDOFF_REF="${_GUILD_SOURCE_REF}"
  GUILD_SOURCE_HANDOFF_REVISION="${_GUILD_SOURCE_REVISION}"
  GUILD_SOURCE_HANDOFF_DIRTY="${_GUILD_SOURCE_DIRTY}"
  GUILD_SOURCE_HANDOFF_TREE_DIGEST="${_GUILD_SOURCE_TREE_DIGEST}"
  GUILD_SOURCE_LAUNCHER_PATH="${launcher}"
  GUILD_SOURCE_LAUNCHER_HEADER="${launcher_header}"
  GUILD_SOURCE_LAUNCHER_LOCAL_REPO="${DISPATCHER_LOCAL_REPO}"
  GUILD_SOURCE_LAUNCHER_MANAGED_TARGET="N"
  [[ "${launcher}" == "${NODE_HOME}/scripts/guild-deploy.sh" ]] &&
    GUILD_SOURCE_LAUNCHER_MANAGED_TARGET="Y"
  GUILD_SOURCE_TARGET_METADATA="${DEPLOYMENT_FILE}"
  GUILD_SOURCE_TARGET_FINGERPRINT="$(dispatcher_target_fingerprint "${DEPLOYMENT_FILE}")" ||
    err_exit "Could not fingerprint deployment metadata before source handoff."
  case "${GUILD_SOURCE_TARGET_JOURNAL_ADMITTED:-N}" in
    N)
      [[ -z "${GUILD_SOURCE_TARGET_JOURNAL_TOKEN:-}" ]] ||
        err_exit "The target journal handoff token is inconsistent."
      ;;
    Y)
      [[ -n "${GUILD_SOURCE_TARGET_JOURNAL_TOKEN:-}" ]] ||
        err_exit "The target journal handoff token is missing."
      ;;
    *) err_exit "The target journal handoff marker is invalid." ;;
  esac
  GUILD_SOURCE_REQUEST_ACCOUNT_PRESET="${G_ACCOUNT_PRESET:-N}"
  GUILD_SOURCE_REQUEST_BRANCH_PRESET="${BRANCH_PRESET:-N}"
  GUILD_SOURCE_REQUEST_NETWORK_PRESET="${NETWORK_PRESET:-N}"
  GUILD_SOURCE_REQUEST_MODE_PRESET="${GUILD_SOURCE_MODE_PRESET:-N}"
  GUILD_SOURCE_REQUEST_NODE_PORT_PRESET="${NODE_PORT_PRESET:-N}"

  export GUILD_SOURCE_HANDOFF_ACTIVE GUILD_SOURCE_HANDOFF_SNAPSHOT
  export GUILD_SOURCE_HANDOFF_CONTAINER GUILD_SOURCE_HANDOFF_TOKEN
  export GUILD_SOURCE_HANDOFF_REPOSITORY GUILD_SOURCE_HANDOFF_CHANNEL
  export GUILD_SOURCE_HANDOFF_MODE GUILD_SOURCE_HANDOFF_REF
  export GUILD_SOURCE_HANDOFF_REVISION GUILD_SOURCE_HANDOFF_DIRTY
  export GUILD_SOURCE_HANDOFF_TREE_DIGEST GUILD_SOURCE_LAUNCHER_PATH
  export GUILD_SOURCE_LAUNCHER_HEADER
  export GUILD_SOURCE_LAUNCHER_LOCAL_REPO GUILD_SOURCE_LAUNCHER_MANAGED_TARGET
  export GUILD_SOURCE_TARGET_METADATA GUILD_SOURCE_TARGET_FINGERPRINT
  export GUILD_SOURCE_TARGET_JOURNAL_ADMITTED
  export GUILD_SOURCE_TARGET_JOURNAL_TOKEN
  export GUILD_SOURCE_REQUEST_ACCOUNT_PRESET GUILD_SOURCE_REQUEST_BRANCH_PRESET
  export GUILD_SOURCE_REQUEST_NETWORK_PRESET GUILD_SOURCE_REQUEST_MODE_PRESET
  export GUILD_SOURCE_REQUEST_NODE_PORT_PRESET
  export G_ACCOUNT NODE_IMPLEMENTATION NETWORK NODE_PARENT NODE_NAME NODE_PORT
  export BRANCH S_ARGS UPDATE_CHECK SUDO PACKAGE_MANAGER_OUTPUT CURL_TIMEOUT
  export DOWNLOAD_TIMEOUT CNODE_SKIP_DBSYNC_DOWNLOAD GUILD_SOURCE_MODE
  export GUILD_SOURCE_CHECKOUT GUILD_SOURCE_ALLOW_REPOSITORY_CHANGE
  export GUILD_SOURCE_EXPECT_REVISION GUILD_DOCKER_EXPORT_ROOT

  # Replacing the bootstrap process is the handoff contract: no parent-side
  # deployment logic may continue after the exact snapshot is prepared.
  # shellcheck disable=SC2093
  exec "${BASH}" "${source_dispatcher}" "$@"
  err_exit "Could not execute the dispatcher from the prepared Guild source snapshot."
}

dispatcher_update_check() {
  [[ "${UPDATE_CHECK}" = "Y" ]] || return 0
  [[ "${GUILD_SOURCE_LAUNCHER_LOCAL_REPO:-N}" = "Y" ]] && return 0
  [[ "${GUILD_SOURCE_LAUNCHER_MANAGED_TARGET:-N}" = "Y" ]] && return 0

  local current_script="${GUILD_SOURCE_LAUNCHER_PATH:-}"
  local current_dir=""
  local current_name=""
  local source_script=""
  local staged_script=""
  local merged_script
  local backup_script
  local existing_user
  local new_code

  [[ -n "${current_script}" && "${current_script}" == /* &&
     -f "${current_script}" && ! -L "${current_script}" && -O "${current_script}" ]] ||
    err_exit "The bootstrap dispatcher path is unsafe or unavailable: ${current_script:-unset}"
  current_dir="$(dirname "${current_script}")"
  current_name="$(basename "${current_script}")"
  source_script="$(guild_source_path scripts/cnode-helper-scripts/guild-deploy.sh)" ||
    err_exit "The prepared snapshot no longer exposes guild-deploy.sh."
  staged_script="$(mktemp "${current_dir}/.${current_name}.source.XXXXXX")" ||
    err_exit "Unable to create dispatcher update staging file."
  merged_script="$(mktemp "${current_dir}/.${current_name}.merged.XXXXXX")" || {
    rm -f -- "${staged_script}"
    err_exit "Unable to create dispatcher update merge file."
  }

  log_progress "Checking bootstrap dispatcher" "$(guild_source_revision)"
  cp -- "${source_script}" "${staged_script}" || {
    rm -f -- "${staged_script}" "${merged_script}"
    err_exit "Unable to stage guild-deploy.sh from the prepared snapshot."
  }

  if [[ ! -s "${staged_script}" ]] ||
     ! grep -q '^# Do NOT modify code below' "${staged_script}" ||
     ! "${BASH}" -n "${staged_script}"; then
    rm -f -- "${staged_script}" "${merged_script}"
    err_exit "Snapshot guild-deploy.sh failed validation."
  fi

  if cmp -s "${current_script}" "${staged_script}"; then
    rm -f -- "${staged_script}" "${merged_script}"
    log_ok "guild-deploy.sh is current"
    return 0
  fi

  existing_user="$(awk '/^#!/{copy=1} /^# Do NOT modify/{exit} copy' "${current_script}")"
  new_code="$(awk '/^# Do NOT modify code below/{copy=1} copy' "${staged_script}")"
  if [[ -z "${existing_user}" || -z "${new_code}" ]] ||
     ! printf '%s\n%s\n' "${existing_user}" "${new_code}" > "${merged_script}" ||
     ! "${BASH}" -n "${merged_script}" ||
     ! chmod 0755 "${merged_script}"; then
    rm -f -- "${staged_script}" "${merged_script}"
    err_exit "Unable to prepare a validated guild-deploy.sh update."
  fi

  if cmp -s "${current_script}" "${merged_script}"; then
    rm -f -- "${staged_script}" "${merged_script}"
    log_ok "guild-deploy.sh is current"
    return 0
  fi

  backup_script="${current_script}_bkp$(date +%s).$$"
  if ! cp -p -- "${current_script}" "${backup_script}"; then
    rm -f -- "${staged_script}" "${merged_script}"
    err_exit "Unable to back up the current guild-deploy.sh."
  fi
  if ! mv -f -- "${merged_script}" "${current_script}"; then
    rm -f -- "${staged_script}" "${merged_script}"
    err_exit "Unable to atomically replace guild-deploy.sh; the current copy is unchanged."
  fi
  rm -f -- "${staged_script}"
  log_ok "Updated bootstrap guild-deploy.sh" "${_GUILD_SOURCE_REVISION}"
}

# Emit the complete directory contract for the selected implementation in
# parent-first order. Profiles must use this inventory instead of maintaining
# their own mkdir lists so dispatcher preflight and privileged setup cannot
# drift apart.
dispatcher_profile_layout_paths() {
  [[ -n "${NODE_HOME:-}" ]] || return 2
  case "${NODE_IMPLEMENTATION:-}" in
    cnode)
      printf '%s\n' \
        "${NODE_HOME}" \
        "${NODE_HOME}/files" \
        "${NODE_HOME}/db" \
        "${NODE_HOME}/guild-db" \
        "${NODE_HOME}/logs" \
        "${NODE_HOME}/scripts" \
        "${NODE_HOME}/scripts/adapters" \
        "${NODE_HOME}/scripts/archive" \
        "${NODE_HOME}/scripts/lib" \
        "${NODE_HOME}/sockets" \
        "${NODE_HOME}/priv" \
        "${NODE_HOME}/mithril" \
        "${NODE_HOME}/mithril/data-stores"
      ;;
    dingo)
      printf '%s\n' \
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
        "${NODE_HOME}/scripts/lib"
      ;;
    amaru)
      printf '%s\n' \
        "${NODE_HOME}" \
        "${NODE_HOME}/files" \
        "${NODE_HOME}/logs" \
        "${NODE_HOME}/runtime" \
        "${NODE_HOME}/snapshots" \
        "${NODE_HOME}/scripts" \
        "${NODE_HOME}/scripts/adapters" \
        "${NODE_HOME}/scripts/archive" \
        "${NODE_HOME}/scripts/lib"
      ;;
    *) return 2 ;;
  esac
}

dispatcher_layout_reject() {
  printf 'Unsafe deployment layout: %s\n' "${1:-validation failed}" >&2
  return 2
}

# Validate every existing path component without dereferencing symlinks.
# Missing components are allowed during preflight, but anything that exists at
# a contracted directory path must be a real directory. This function performs
# no mutation and is intentionally called both before profile execution and
# immediately before privileged ownership/mode changes.
dispatcher_validate_profile_layout() {
  local layout_output="" layout_path="" relative_path=""
  local component="" current="" path_count=0
  local -a components

  if [[ -z "${NODE_HOME:-}" || "${NODE_HOME}" != /* ||
        "${NODE_HOME}" == "/" ]]; then
    dispatcher_layout_reject "NODE_HOME is not a safe absolute target"
    return 2
  fi
  if ! layout_output="$(dispatcher_profile_layout_paths)"; then
    dispatcher_layout_reject \
      "no directory contract exists for ${NODE_IMPLEMENTATION:-unset}"
    return 2
  fi

  while IFS= read -r layout_path; do
    [[ -n "${layout_path}" ]] || continue
    path_count=$((path_count + 1))
    if [[ "${layout_path}" == "${NODE_HOME}" ]]; then
      relative_path=""
    elif [[ "${layout_path}" == "${NODE_HOME}/"* ]]; then
      relative_path="${layout_path#"${NODE_HOME}/"}"
      if [[ -z "${relative_path}" || "${relative_path}" == */ ||
            "${relative_path}" == *//* ||
            "${relative_path}" =~ [[:cntrl:]] ]]; then
        dispatcher_layout_reject "invalid contracted path ${layout_path}"
        return 2
      fi
    else
      dispatcher_layout_reject "contracted path escapes NODE_HOME: ${layout_path}"
      return 2
    fi

    current="${NODE_HOME}"
    if [[ -L "${current}" ]]; then
      dispatcher_layout_reject "symbolic link is not allowed at ${current}" || return 2
    elif [[ -e "${current}" && ! -d "${current}" ]]; then
      dispatcher_layout_reject "non-directory exists at ${current}" || return 2
    fi
    [[ -n "${relative_path}" ]] || continue

    IFS='/' read -r -a components <<< "${relative_path}"
    for component in "${components[@]}"; do
      if [[ -z "${component}" || "${component}" == "." ||
            "${component}" == ".." ]]; then
        dispatcher_layout_reject "invalid path component in ${layout_path}"
        return 2
      fi
      current="${current}/${component}"
      if [[ -L "${current}" ]]; then
        dispatcher_layout_reject "symbolic link is not allowed at ${current}" || return 2
      elif [[ -e "${current}" && ! -d "${current}" ]]; then
        dispatcher_layout_reject "non-directory exists at ${current}" || return 2
      fi
    done
  done <<< "${layout_output}"

  if (( path_count == 0 )); then
    dispatcher_layout_reject "directory contract is empty"
    return 2
  fi
}

# Create the profile directory contract one component at a time. A complete
# non-mutating preflight happens before the first mkdir. The entire contract is
# then revalidated immediately before and after every individual creation, so
# no later directory creation, chown, or chmod is attempted after a symlink or
# non-directory is observed. The callback is a profile-owned privilege wrapper.
dispatcher_prepare_profile_layout() {
  local privileged_runner="${1:-}"
  local layout_output="" layout_path=""

  if [[ ! "${privileged_runner}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    dispatcher_layout_reject "invalid privileged layout runner"
    return 2
  fi
  if ! declare -F "${privileged_runner}" >/dev/null 2>&1; then
    dispatcher_layout_reject "privileged layout runner is unavailable"
    return 2
  fi
  layout_output="$(dispatcher_profile_layout_paths)" || return 2
  dispatcher_validate_profile_layout || return 2

  while IFS= read -r layout_path; do
    [[ -n "${layout_path}" ]] || continue
    dispatcher_validate_profile_layout || return 2
    if [[ ! -e "${layout_path}" && ! -L "${layout_path}" ]]; then
      if [[ "${layout_path}" == "${NODE_HOME}" ]]; then
        "${privileged_runner}" mkdir -p -- "${layout_path}" || return 2
      else
        "${privileged_runner}" mkdir -- "${layout_path}" || return 2
      fi
    fi
    dispatcher_validate_profile_layout || return 2
  done <<< "${layout_output}"
}

dispatcher_profile_relative_path() {
  case "${NODE_IMPLEMENTATION}" in
    cnode) printf 'scripts/cnode-helper-scripts/deploy-cnode.sh' ;;
    dingo) printf 'scripts/dingo-helper-scripts/deploy-dingo.sh' ;;
    amaru) printf 'scripts/amaru-helper-scripts/deploy-amaru.sh' ;;
  esac
}

dispatcher_load_profile() {
  local relative_path
  relative_path="$(dispatcher_profile_relative_path)"
  PROFILE_PATH="$(guild_source_path "${relative_path}")" ||
    err_exit "The source snapshot does not contain ${relative_path}."
  log_progress "Loading ${NODE_IMPLEMENTATION} deployment profile" "${_GUILD_SOURCE_REVISION}"

  if ! "${BASH}" -n "${PROFILE_PATH}"; then
    err_exit "Deployment profile ${relative_path} failed shell validation."
  fi
  # shellcheck source=/dev/null
  if ! . "${PROFILE_PATH}"; then
    err_exit "Deployment profile ${relative_path} failed while loading."
  fi

  local function_name="deploy_${NODE_IMPLEMENTATION}_profile"
  declare -F "${function_name}" >/dev/null ||
    err_exit "Deployment profile ${relative_path} does not expose ${function_name}."
  PROFILE_ENTRYPOINT="${function_name}"
}

dispatcher_distribution_relative_path_valid() {
  local relative_path="${1:-}"
  local component=""
  local -a components

  [[ -n "${relative_path}" && "${relative_path}" != /* &&
     "${relative_path}" != */ && "${relative_path}" != *//* &&
     ! "${relative_path}" =~ [[:cntrl:]] &&
     "${relative_path}" =~ ^(scripts|files)/[A-Za-z0-9._/+@:-]+$ ]] ||
    return 1
  IFS='/' read -r -a components <<< "${relative_path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" && "${component}" != "." &&
       "${component}" != ".." ]] || return 1
  done
}

dispatcher_distribution_render_cnode() {
  local source_file="$1"
  local candidate="$2"
  local escaped_home=""
  local escaped_name=""

  escaped_home="$(printf '%s' "${NODE_HOME}" | sed 's/[&|\\]/\\&/g')"
  escaped_name="$(printf '%s' "${NODE_NAME}" | sed 's/[&|\\]/\\&/g')"
  sed \
    -e "s|/opt/cardano/cnode|${escaped_home}|g" \
    -e "s|\"TraceOptionNodeName\": \"cnode\"|\"TraceOptionNodeName\": \"${escaped_name}\"|g" \
    "${source_file}" > "${candidate}"
}

dispatcher_distribution_render_dingo() {
  local source_file="$1"
  local candidate="$2"
  local escaped_home="" escaped_service="" escaped_binary=""

  escaped_home="$(printf '%s' "${NODE_HOME}" | sed 's/[&|\\]/\\&/g')"
  escaped_service="$(printf '%s' "${NODE_SERVICE}" | sed 's/[&|\\]/\\&/g')"
  escaped_binary="$(printf '%s' "${HOME}/.local/bin/dingo" | sed 's/[&|\\]/\\&/g')"
  sed \
    -e "s|@NODE_HOME@|${escaped_home}|g" \
    -e "s|@NODE_SERVICE@|${escaped_service}|g" \
    -e "s|@BINARY_PATH@|${escaped_binary}|g" \
    -e "s|\"@NODE_PORT@\"|${NODE_PORT:-3001}|g" \
    "${source_file}" > "${candidate}"
}

dispatcher_distribution_render_amaru() {
  local source_file="$1"
  local candidate="$2"
  local escaped_home="" escaped_service="" escaped_binary=""

  escaped_home="$(printf '%s' "${NODE_HOME}" | sed 's/[&|\\]/\\&/g')"
  escaped_service="$(printf '%s' "${NODE_SERVICE}" | sed 's/[&|\\]/\\&/g')"
  escaped_binary="$(printf '%s' "${HOME}/.local/bin/amaru" | sed 's/[&|\\]/\\&/g')"
  sed \
    -e "s|@NODE_HOME@|${escaped_home}|g" \
    -e "s|@NODE_SERVICE@|${escaped_service}|g" \
    -e "s|@BINARY_PATH@|${escaped_binary}|g" \
    -e "s|@NODE_PORT@|${NODE_PORT:-3000}|g" \
    "${source_file}" > "${candidate}"
}

dispatcher_distribution_merge_header() {
  local source_file="$1"
  local installed_file="$2"
  local candidate="$3"
  local header_override="${4:-}"
  local old_header="" source_header="" new_runtime="" line="" variable=""
  local use_header_override="N"
  local insertion_index=0 index=0
  local -a installed_lines=() missing_variables=()
  local -A installed_variables=()

  if [[ ! -e "${installed_file}" && ! -L "${installed_file}" &&
        -n "${header_override}" ]]; then
    use_header_override="Y"
  fi
  if [[ "${DISPATCHER_FORCE_SCRIPTS:-N}" != "Y" &&
        ( ( -f "${installed_file}" && ! -L "${installed_file}" ) ||
          "${use_header_override}" == "Y" ) &&
        ( "${use_header_override}" == "Y" ||
          -n "$(grep '^# Do NOT modify' "${installed_file}" 2>/dev/null)" ) &&
        -n "$(grep '^# Do NOT modify' "${source_file}" 2>/dev/null)" ]]; then
    if [[ "${use_header_override}" == "Y" ]]; then
      old_header="${header_override}"
    else
      old_header="$(awk '/^# Do NOT modify/{exit} {print}' "${installed_file}")"
    fi
    source_header="$(awk '/^# Do NOT modify/{exit} {print}' "${source_file}")"
    [[ -n "${old_header}" && -n "${source_header}" ]] || return 1
    if [[ "${old_header}" == "${source_header}" ]]; then
      cp -- "${source_file}" "${candidate}"
    else
      while IFS= read -r line; do
        [[ "${line}" != '# Do NOT modify'* ]] || break
        installed_lines+=("${line}")
        if [[ "${line}" =~ ^\#*[[:space:]]*([[:alnum:]_]+)= ]]; then
          installed_variables["${BASH_REMATCH[1]}"]="Y"
        fi
      done <<< "${old_header}"
      while IFS= read -r line; do
        [[ "${line}" != '# Do NOT modify'* ]] || break
        if [[ "${line}" =~ ^\#*[[:space:]]*([[:alnum:]_]+)= ]]; then
          variable="${BASH_REMATCH[1]}"
          if [[ -z "${installed_variables[${variable}]+set}" ]]; then
            missing_variables+=("${line}")
            installed_variables["${variable}"]="Y"
          fi
        fi
      done < "${source_file}"
      new_runtime="$(awk 'copy || /^# Do NOT modify/{copy=1; print}' "${source_file}")"
      [[ -n "${new_runtime}" ]] || return 1
      insertion_index="${#installed_lines[@]}"
      while (( insertion_index > 0 )); do
        line="${installed_lines[insertion_index - 1]}"
        [[ -z "${line}" || "${line}" =~ ^#+[[:space:]]*$ ]] || break
        insertion_index=$((insertion_index - 1))
      done
      {
        for (( index = 0; index < insertion_index; index++ )); do
          printf '%s\n' "${installed_lines[index]}"
        done
        for line in "${missing_variables[@]}"; do
          printf '%s\n' "${line}"
        done
        for (( index = insertion_index; index < ${#installed_lines[@]}; index++ )); do
          printf '%s\n' "${installed_lines[index]}"
        done
        printf '%s\n' "${new_runtime}"
      } > "${candidate}"
    fi
  else
    cp -- "${source_file}" "${candidate}"
  fi
}

dispatcher_distribution_seed_cnode_port() {
  local candidate="$1"
  local seeded="${candidate}.seeded"

  [[ "${NODE_IMPLEMENTATION}" == "cnode" &&
     ! -e "${NODE_HOME}/scripts/env" ]] || return 0
  if ! awk -v node_port="${NODE_PORT}" '
    BEGIN { updated = 0 }
    /^#CNODE_PORT=/ && updated == 0 {
      printf "CNODE_PORT=%s\n", node_port
      updated = 1
      next
    }
    { print }
    END { if (updated == 0) exit 42 }
  ' "${candidate}" > "${seeded}"; then
    rm -f -- "${seeded}"
    return 1
  fi
  mv -- "${seeded}" "${candidate}"
}

dispatcher_distribution_validate_prior_receipt() {
  local receipt="${NODE_HOME}/.guild-source-receipt.json"
  local metadata="${NODE_HOME}/.deployment.json"
  local expected_hash="" actual_hash="" metadata_source_schema=""

  DISPATCHER_PRIOR_RECEIPT=""
  if [[ ! -e "${receipt}" && ! -L "${receipt}" ]]; then
    if [[ -f "${metadata}" ]] &&
       [[ -n "$(deployment_json_get "${metadata}" payloadReceiptSha256 || true)" ]]; then
      return 2
    fi
    return 0
  fi
  [[ -f "${receipt}" && ! -L "${receipt}" && -O "${receipt}" &&
     -f "${metadata}" && ! -L "${metadata}" ]] || return 2
  command -v jq >/dev/null 2>&1 || return 2
  expected_hash="$(deployment_json_get "${metadata}" payloadReceiptSha256 || true)"
  metadata_source_schema="$(deployment_json_get "${metadata}" sourceSchemaVersion || true)"
  [[ "${expected_hash}" =~ ^[0-9a-f]{64}$ ]] || return 2
  [[ "${metadata_source_schema}" == "1" ||
     "${metadata_source_schema}" == "2" ]] || return 2
  actual_hash="$(dispatcher_sha256 "${receipt}")" || return 2
  [[ "${actual_hash}" == "${expected_hash}" ]] || return 2
  jq -e '
    type == "object" and
    (.schemaVersion == 1 or .schemaVersion == 2) and
    (.files | type == "array") and
    (all(.files[];
      (.path | type == "string" and test("^(scripts|files)/[A-Za-z0-9._/+@:-]+$")) and
      (.installedSha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.managed | type == "boolean"))) and
    (([.files[].path] | length) == ([.files[].path] | unique | length)) and
    (
      if .schemaVersion == 1 then
        (has("cntoolsGeneration") | not)
      elif (.implementation == "cnode" or .implementation == "dingo") then
        (.cntoolsGeneration | type == "object" and
          keys == ["active", "fileCount", "generationReceipt",
            "generationReceiptSha256", "id", "path", "payloadManifest",
            "payloadManifestSha256", "schemaVersion", "version"] and
          .schemaVersion == 1 and .active == false and
          (.fileCount == 20 or .fileCount == 30 or .fileCount == 152) and
          (.id | type == "string" and test("^[0-9a-f]{64}$")) and
          .path == ("scripts/.cntools/generations/" + .id) and
          .payloadManifest == (.path + "/cntools/manifest.json") and
          .generationReceipt == (.path + "/.generation.json") and
          (.payloadManifestSha256 | type == "string" and test("^[0-9a-f]{64}$")) and
          (.generationReceiptSha256 | type == "string" and test("^[0-9a-f]{64}$")))
      else
        (has("cntoolsGeneration") | not)
      end
    )
  ' "${receipt}" >/dev/null 2>&1 || return 2
  [[ "$(jq -er '.schemaVersion' "${receipt}")" == \
     "${metadata_source_schema}" ]] || return 2
  DISPATCHER_PRIOR_RECEIPT="${receipt}"
}

dispatcher_path_mode() {
  local file="${1:-}"
  local mode=""

  [[ -e "${file}" && ! -L "${file}" ]] || return 2
  mode="$(find "${file}" -prune -printf '%m' 2>/dev/null || true)"
  if [[ -z "${mode}" ]]; then
    mode="$(stat -f '%Lp' "${file}" 2>/dev/null || true)"
  fi
  case "${mode}" in
    [0-7][0-7][0-7]) mode="0${mode}" ;;
    [0-7][0-7][0-7][0-7]) ;;
    *) return 2 ;;
  esac
  printf '%s\n' "${mode}"
}

dispatcher_file_mode() {
  [[ -f "${1:-}" && ! -L "${1:-}" ]] || return 2
  dispatcher_path_mode "$1"
}

# Existing preserve-render targets are operator data. Without -f their bytes
# and mode remain untouched. When the prior receipt still describes those
# bytes, retain its policy label so an identical refresh is fully idempotent;
# otherwise classify the file explicitly as operator-preserved.
dispatcher_distribution_preserve_existing() {
  local target_path="$1"
  local target="${NODE_HOME}/${target_path}"
  local record="" managed="" installed_hash="" prior_policy=""
  local actual_hash=""

  DISPATCHER_PRESERVED_POLICY="operator-preserved"
  DISPATCHER_PRESERVED_MODE=""

  [[ -f "${target}" && ! -L "${target}" ]] || return 1
  DISPATCHER_PRESERVED_MODE="$(dispatcher_file_mode "${target}")" || return 2
  if [[ ! "${DISPATCHER_PRESERVED_MODE}" =~ ^0[4-7][0145][0145]$ ]]; then
    printf 'Cannot preserve %s with unsafe mode %s; make it owner-readable and remove group/world write access, or use -s f to replace it.\n' \
      "${target}" "${DISPATCHER_PRESERVED_MODE}" >&2
    return 2
  fi
  [[ -n "${DISPATCHER_PRIOR_RECEIPT:-}" ]] || return 0
  record="$(jq -er --arg path "${target_path}" '
    [.files[] | select(.path == $path)] |
    if length == 0 then "missing"
    elif length == 1 then
      (.[0].managed | tostring) + "\t" + .[0].installedSha256 +
        "\t" + .[0].policy
    else error("duplicate receipt path") end
  ' "${DISPATCHER_PRIOR_RECEIPT}")" || return 2
  [[ "${record}" != "missing" ]] || return 0
  IFS=$'\t' read -r managed installed_hash prior_policy <<< "${record}"
  [[ "${managed}" == "true" || "${managed}" == "false" ]] || return 2
  [[ "${installed_hash}" =~ ^[0-9a-f]{64}$ ]] || return 2
  case "${prior_policy}" in
    render-cnode|render-dingo|render-amaru|operator-preserved) ;;
    *) return 2 ;;
  esac
  actual_hash="$(dispatcher_sha256 "${target}")" || return 2
  if [[ "${actual_hash}" == "${installed_hash}" ]]; then
    DISPATCHER_PRESERVED_POLICY="${prior_policy}"
  fi
  return 0
}

# Return the immutable Stage 1 CNTools member contract for a generation path.
# Output fields are repository source, installed mode, and validator. Keeping
# this allowlist independent of the nested JSON prevents a modified manifest
# from turning the package installer into an arbitrary repository copier.
dispatcher_cntools_expected_record() {
  case "${1:-}" in
    cntools.sh)
      printf '%s\t%s\t%s\n' \
        'scripts/common-helper-scripts/cntools/launcher.sh' 0555 shell
      ;;
    cntools.library)
      printf '%s\t%s\t%s\n' \
        'scripts/common-helper-scripts/cntools.library' 0444 shell
      ;;
    cntools.conf.example)
      printf '%s\t%s\t%s\n' \
        'scripts/common-helper-scripts/cntools.conf.example' 0444 config
      ;;
    cntools/VERSION)
      printf '%s\t%s\t%s\n' \
        'scripts/common-helper-scripts/cntools/VERSION' 0444 text
      ;;
    cntools/core/bootstrap.sh|cntools/core/config.sh|cntools/core/context.sh|cntools/core/registry.sh|cntools/core/dispatcher.sh|cntools/core/lifecycle.sh|cntools/core/result.sh)
      printf 'scripts/common-helper-scripts/%s\t%s\t%s\n' "${1}" 0444 shell
      ;;
    cntools/schema/module.schema.json|cntools/libs/manifest.json|cntools/modules/root/module.json|cntools/templates/action/module.json)
      printf 'scripts/common-helper-scripts/%s\t%s\t%s\n' "${1}" 0444 json
      ;;
    cntools/modules/root/*/module.json)
      printf 'scripts/common-helper-scripts/%s\t%s\t%s\n' "${1}" 0444 json
      ;;
    cntools/modules/root/*/action.sh)
      printf 'scripts/common-helper-scripts/%s\t%s\t%s\n' "${1}" 0444 shell
      ;;
    cntools/docs/ARCHITECTURE.md|cntools/docs/DEVELOPMENT.md|cntools/docs/TESTING.md)
      printf 'scripts/common-helper-scripts/%s\t%s\t%s\n' "${1}" 0444 text
      ;;
    cntools/templates/action/action.sh)
      printf 'scripts/common-helper-scripts/%s\t%s\t%s\n' "${1}" 0444 shell
      ;;
    cntools/libs/legacy/6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59/010-common-dialog.sh|cntools/libs/legacy/6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59/020-terminal-selection-security.sh|cntools/libs/legacy/6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59/030-governance-query.sh|cntools/libs/legacy/6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59/040-address-wallet-query.sh|cntools/libs/legacy/6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59/050-wallet-create-registration.sh|cntools/libs/legacy/6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59/060-wallet-actions.sh|cntools/libs/legacy/6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59/070-pool-actions.sh|cntools/libs/legacy/6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59/080-metadata-assets.sh|cntools/libs/legacy/6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59/090-governance-actions.sh|cntools/libs/legacy/6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59/100-transaction-hardware-price.sh)
      printf 'scripts/common-helper-scripts/%s\t%s\t%s\n' "${1}" 0444 shell
      ;;
    *) return 1 ;;
  esac
}

dispatcher_cntools_generation_manifest_valid() {
  local manifest="${1:-}"

  [[ -f "${manifest}" && ! -L "${manifest}" && -s "${manifest}" ]] ||
    return 2
  jq -e '
    type == "object" and
    keys == [
      "compatibilityLibrary", "contextApiVersion", "entrypoint", "files",
      "generationIdAlgorithm", "legacyBundle", "libraryManifest",
      "moduleApiVersion", "moduleSchema", "moduleSchemaVersion",
      "releaseStage", "rootModule", "runtimeApiVersion", "schemaVersion",
      "version"
    ] and
    .schemaVersion == 3 and
    .version == "13.5.7" and
    .releaseStage == "shadow" and
    .runtimeApiVersion == 1 and
    .contextApiVersion == 1 and
    .moduleApiVersion == 1 and
    .moduleSchemaVersion == 2 and
    .generationIdAlgorithm == "sha256-path-mode-content-v1" and
    .entrypoint == "cntools.sh" and
    .compatibilityLibrary == "cntools.library" and
    .moduleSchema == "cntools/schema/module.schema.json" and
    .libraryManifest == "cntools/libs/manifest.json" and
    .rootModule == "cntools/modules/root/module.json" and
    (.files | type == "array" and length == 151) and
    ([.files[].path] == ([.files[].path] | sort)) and
    ([.files[].path] | length == (unique | length)) and
    ([.files[].source] | length == (unique | length)) and
    ([.files[] | select(.path | startswith("cntools/modules/root/")) |
      select(.path | endswith("/module.json"))] | length == 69) and
    ([.files[] | select(.path | startswith("cntools/modules/root/")) |
      select(.path | endswith("/action.sh"))] | length == 54) and
    all(.files[];
      type == "object" and
      keys == ["mode", "path", "sha256", "source", "validator"] and
      (.path | type == "string" and
        test("^[A-Za-z0-9._/+@:-]+$") and
        (contains("//") | not) and
        (split("/") | all(. != "" and . != "." and . != ".."))) and
      (.source | type == "string" and test("^scripts/[A-Za-z0-9._/+@:-]+$") and
        (contains("//") | not) and
        (split("/") | all(. != "" and . != "." and . != ".."))) and
      (.mode == "0444" or .mode == "0555") and
      (.validator == "shell" or .validator == "json" or
        .validator == "text" or .validator == "config") and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
  ' "${manifest}" >/dev/null 2>&1 || return 2
  dispatcher_cntools_legacy_bundle_metadata_valid "${manifest}"
}

# Parse the only two durable generation-record shapes. Stage 1/2 recovery
# retains the exact six-field record. Stage 3 appends an authenticated schema
# discriminator so recovery remains unambiguous after both trees are retracted.
dispatcher_cntools_generation_record_parse() {
  local record="${1:-}" line="" tabless="" tab_count=0
  local id="" relative="" root_existed="" generations_existed=""
  local target_existed="" lifecycle_sha="" manifest_schema=""
  local manifest_count="" receipt_schema="" receipt_count="" extra=""
  local -a lines=()

  DISPATCHER_CNTOOLS_RECORD_SHAPE=""
  DISPATCHER_CNTOOLS_RECORD_ID=""
  DISPATCHER_CNTOOLS_RECORD_RELATIVE=""
  DISPATCHER_CNTOOLS_RECORD_ROOT_EXISTED=""
  DISPATCHER_CNTOOLS_RECORD_GENERATIONS_EXISTED=""
  DISPATCHER_CNTOOLS_RECORD_TARGET_EXISTED=""
  DISPATCHER_CNTOOLS_RECORD_LIFECYCLE_SHA256=""
  DISPATCHER_CNTOOLS_RECORD_MANIFEST_SCHEMA=""
  DISPATCHER_CNTOOLS_RECORD_MANIFEST_COUNT=""
  DISPATCHER_CNTOOLS_RECORD_RECEIPT_SCHEMA=""
  DISPATCHER_CNTOOLS_RECORD_RECEIPT_COUNT=""
  [[ -f "${record}" && ! -L "${record}" && -O "${record}" ]] || return 2
  mapfile -t lines < "${record}" || return 2
  (( ${#lines[@]} == 1 )) || return 2
  line="${lines[0]}"
  builtin printf '%s\n' "${line}" | cmp -s - "${record}" || return 2
  # Tabs are the record delimiter, so reject carriage returns explicitly;
  # embedded newlines are already rejected by the exact one-line mapfile
  # check and every field below has its own closed lexical contract.
  [[ -n "${line}" && "${line}" != *$'\r'* ]] || return 2
  tabless="${line//$'\t'/}"
  tab_count=$(( ${#line} - ${#tabless} ))
  [[ ${tab_count} -eq 5 || ${tab_count} -eq 9 ]] || return 2
  IFS=$'\t' read -r id relative root_existed generations_existed \
    target_existed lifecycle_sha manifest_schema manifest_count \
    receipt_schema receipt_count extra <<< "${line}" || return 2
  [[ -z "${extra}" && "${id}" =~ ^[0-9a-f]{64}$ &&
     "${relative}" == "scripts/.cntools/generations/${id}" &&
     "${lifecycle_sha}" =~ ^[0-9a-f]{64}$ ]] || return 2
  case "${root_existed}:${generations_existed}:${target_existed}" in
    Y:Y:Y|Y:Y:N|Y:N:N|N:N:N) ;;
    *) return 2 ;;
  esac
  if [[ ${tab_count} -eq 5 ]]; then
    [[ -z "${manifest_schema}${manifest_count}${receipt_schema}${receipt_count}" ]] ||
      return 2
    DISPATCHER_CNTOOLS_RECORD_SHAPE="legacy"
  else
    [[ "${manifest_schema}:${manifest_count}:${receipt_schema}:${receipt_count}" == \
       "3:151:3:152" ]] || return 2
    DISPATCHER_CNTOOLS_RECORD_SHAPE="stage3"
  fi
  DISPATCHER_CNTOOLS_RECORD_ID="${id}"
  DISPATCHER_CNTOOLS_RECORD_RELATIVE="${relative}"
  DISPATCHER_CNTOOLS_RECORD_ROOT_EXISTED="${root_existed}"
  DISPATCHER_CNTOOLS_RECORD_GENERATIONS_EXISTED="${generations_existed}"
  DISPATCHER_CNTOOLS_RECORD_TARGET_EXISTED="${target_existed}"
  DISPATCHER_CNTOOLS_RECORD_LIFECYCLE_SHA256="${lifecycle_sha}"
  DISPATCHER_CNTOOLS_RECORD_MANIFEST_SCHEMA="${manifest_schema}"
  DISPATCHER_CNTOOLS_RECORD_MANIFEST_COUNT="${manifest_count}"
  DISPATCHER_CNTOOLS_RECORD_RECEIPT_SCHEMA="${receipt_schema}"
  DISPATCHER_CNTOOLS_RECORD_RECEIPT_COUNT="${receipt_count}"
}

dispatcher_cntools_legacy_bundle_metadata_valid() {
  local manifest="${1:-}"

  jq -e '
    . as $manifest |
    (.legacyBundle | type == "object" and
      keys == [
        "facade", "id", "idAlgorithm", "logicalBodySha256",
        "logicalBodySize", "members", "path", "schemaVersion"
      ] and
      .schemaVersion == 1 and
      .idAlgorithm == "sha256-cntools-legacy-bundle-v1" and
      .id == "6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59" and
      .path == "cntools/libs/legacy/6e40118f106169924a372a9d98fbc946cfc5362fcd1cd5a3ff048ae9287d5d59" and
      .facade == "cntools.library" and
      .logicalBodySize == 357616 and
      .logicalBodySha256 == "f86a3753a2c4b2251a4bc2fcc4f8ac69b5ca42cf3c527979580f0d931641575a" and
      .members == [
        {"mode":"0444","path":"010-common-dialog.sh","sha256":"5408355794fa187dbac5af7b66b956ab84216fd91ee4b6ec8bbe420b05fea8a7","size":14532},
        {"mode":"0444","path":"020-terminal-selection-security.sh","sha256":"bb6f10e533f45cb90577e32d0d7a57ca86fe0c97d950938911be8eecec4a1460","size":31976},
        {"mode":"0444","path":"030-governance-query.sh","sha256":"9e9179c73ccdd945c6ed6b7921038b7f6bc7679c4609af86565f7ad99ff8d519","size":46236},
        {"mode":"0444","path":"040-address-wallet-query.sh","sha256":"b23fdfec65fd7e991a3e46d2bef1d5c9ed09102e345cac7f3f5b75c761957df0","size":38284},
        {"mode":"0444","path":"050-wallet-create-registration.sh","sha256":"2ff4b5f29674fb1cf65e5cda736c9e4f41af51adbe76b29fa5a41bb369f63fdc","size":114081},
        {"mode":"0444","path":"060-wallet-actions.sh","sha256":"73f150b684713b6c64211ff8c900a6deedb90a4aa15afde85dae44b8af220db5","size":18393},
        {"mode":"0444","path":"070-pool-actions.sh","sha256":"689a52e0e8f18a30984cebda6ef29dd929b66fb4cdba7ff03f673debb6e25257","size":27577},
        {"mode":"0444","path":"080-metadata-assets.sh","sha256":"1444e366a79483bdcd538b59e01f8a623e3c6b4bf4fe58f5deaedc53ec247c80","size":17503},
        {"mode":"0444","path":"090-governance-actions.sh","sha256":"91fd56011304f4528851f8cd3b241ca63393440a51faa5c5380a22081a146ec8","size":22753},
        {"mode":"0444","path":"100-transaction-hardware-price.sh","sha256":"237b3847db52432ff523c36c5ca7bcb08b437f8b8978389259789a70fee5071f","size":22300}
      ]) and
    ([.legacyBundle.members[] as $member |
      $manifest.files[] |
      select(.path == ($manifest.legacyBundle.path + "/" + $member.path) and
        .source == ("scripts/common-helper-scripts/" +
          $manifest.legacyBundle.path + "/" + $member.path) and
        .mode == $member.mode and .validator == "shell" and
        .sha256 == $member.sha256)] | length == 10) and
    ([.files[] |
      select(.path | startswith($manifest.legacyBundle.path + "/"))] |
      length == 10)
  ' "${manifest}" >/dev/null 2>&1
}

# Validate a data-only bundle contract retained in a durable transaction. This
# generic shape permits dispatcher B to recover an interrupted bundle A while
# still requiring the frozen Stage 2 fragment inventory. IDs, hashes, and sizes
# may change across legitimate revisions; fragment roles and ordering may not.
dispatcher_cntools_legacy_bundle_data_manifest_valid() {
  local manifest="${1:-}"

  [[ -f "${manifest}" && ! -L "${manifest}" && -O "${manifest}" ]] || return 2
  jq -e '
    type == "object" and keys == ["legacyBundle"] and
    (.legacyBundle | type == "object" and
      keys == [
        "facade", "id", "idAlgorithm", "logicalBodySha256",
        "logicalBodySize", "members", "path", "schemaVersion"
      ] and
      .schemaVersion == 1 and .facade == "cntools.library" and
      .idAlgorithm == "sha256-cntools-legacy-bundle-v1" and
      (.id | type == "string" and test("^[0-9a-f]{64}$")) and
      .path == ("cntools/libs/legacy/" + .id) and
      (.logicalBodySha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.logicalBodySize | type == "number" and . > 0 and . <= 16777216 and
        floor == .) and
      (.members | type == "array") and
      ([.members[].path] == [
          "010-common-dialog.sh",
          "020-terminal-selection-security.sh",
          "030-governance-query.sh",
          "040-address-wallet-query.sh",
          "050-wallet-create-registration.sh",
          "060-wallet-actions.sh",
          "070-pool-actions.sh",
          "080-metadata-assets.sh",
          "090-governance-actions.sh",
          "100-transaction-hardware-price.sh"
        ]) and
      all(.members[];
        type == "object" and keys == ["mode", "path", "sha256", "size"] and
        .mode == "0444" and
        (.path | type == "string" and
          test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and
          (contains("/") | not)) and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.size | type == "number" and . > 0 and . <= 16777216 and floor == .)))
  ' "${manifest}" >/dev/null 2>&1
}

# Bind the transaction-owned bundle description to the generation that was
# independently validated as inert data. Recovery may legitimately find that
# generation at either its durable staged path or its published path. If an
# earlier cleanup already retracted both, the authenticated bundle snapshot is
# sufficient for the idempotent remainder of rollback.
dispatcher_cntools_legacy_bundle_matches_transaction_generation() {
  local root="${1:-}" data_manifest="${2:-}"
  local record="${root}/cntools-generation.tsv"
  local id="" relative="" root_existed="" generations_existed=""
  local target_existed="" lifecycle_sha=""
  local target="" staged="" generation="" generation_manifest=""
  local target_present="N" staged_present="N"

  dispatcher_cntools_generation_record_parse "${record}" || return 2
  id="${DISPATCHER_CNTOOLS_RECORD_ID}"
  relative="${DISPATCHER_CNTOOLS_RECORD_RELATIVE}"
  root_existed="${DISPATCHER_CNTOOLS_RECORD_ROOT_EXISTED}"
  generations_existed="${DISPATCHER_CNTOOLS_RECORD_GENERATIONS_EXISTED}"
  target_existed="${DISPATCHER_CNTOOLS_RECORD_TARGET_EXISTED}"
  lifecycle_sha="${DISPATCHER_CNTOOLS_RECORD_LIFECYCLE_SHA256}"
  target="${NODE_HOME}/${relative}"
  staged="${root}/cntools-generation/${id}"
  if [[ "${target_existed}" == "Y" ]]; then
    [[ -d "${target}" && ! -L "${target}" && -O "${target}" ]] || return 2
    generation="${target}"
  else
    if [[ -e "${target}" || -L "${target}" ]]; then
      [[ -d "${target}" && ! -L "${target}" && -O "${target}" ]] || return 2
      target_present="Y"
    fi
    if [[ -e "${staged}" || -L "${staged}" ]]; then
      [[ -d "${staged}" && ! -L "${staged}" && -O "${staged}" ]] || return 2
      staged_present="Y"
    fi
    case "${target_present}:${staged_present}" in
      Y:N) generation="${target}" ;;
      N:Y) generation="${staged}" ;;
      N:N) return 0 ;;
      *) return 2 ;;
    esac
  fi
  dispatcher_cntools_absolute_path_has_no_symlinks "${generation}" || return 2
  generation_manifest="${generation}/cntools/manifest.json"
  [[ -f "${generation_manifest}" && ! -L "${generation_manifest}" &&
     -O "${generation_manifest}" &&
     "$(dispatcher_file_mode "${generation_manifest}")" == "0444" ]] ||
    return 2
  jq -e -s '
    length == 2 and
    .[0].legacyBundle == .[1].legacyBundle
  ' "${data_manifest}" "${generation_manifest}" >/dev/null 2>&1
}

dispatcher_cntools_generation_validate_member() {
  local file="${1:-}"
  local validator="${2:-}"

  [[ -f "${file}" && ! -L "${file}" && -s "${file}" ]] || return 2
  case "${validator}" in
    shell) "${BASH}" -n "${file}" >/dev/null 2>&1 ;;
    json) jq -e . "${file}" >/dev/null 2>&1 ;;
    text) : ;;
    # The complete generation validator applies its own data-only parser after
    # all member bytes and the content-addressed ID have been verified.
    config) : ;;
    *) return 2 ;;
  esac
}

dispatcher_cntools_absolute_path_has_no_symlinks() {
  local target="${1:-}" current="" component=""
  local -a components=()

  [[ "${target}" == /* && "${target}" != "/" ]] || return 2
  IFS='/' read -r -a components <<< "${target}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current}/${component}"
    [[ ! -L "${current}" ]] || return 2
    if [[ -e "${current}" && "${current}" != "${target}" ]]; then
      [[ -d "${current}" ]] || return 2
    fi
  done
}

# Source lifecycle code only after authenticating it against a hash retained
# outside the generation being inspected. This avoids allowing a modified
# installed generation to execute code merely because it is being validated.
dispatcher_cntools_source_trusted_lifecycle() {
  local lifecycle="${1:-}" expected_sha="${2:-}" expected_mode="${3:-0444}"
  local actual_sha="" actual_mode=""

  [[ "${expected_sha}" =~ ^[0-9a-f]{64}$ &&
     ( "${expected_mode}" == "0400" || "${expected_mode}" == "0444" ) &&
     -f "${lifecycle}" && ! -L "${lifecycle}" && -O "${lifecycle}" ]] ||
    return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${lifecycle}" || return 2
  actual_mode="$(dispatcher_file_mode "${lifecycle}")" || return 2
  actual_sha="$(dispatcher_sha256 "${lifecycle}")" || return 2
  [[ "${actual_mode}" == "${expected_mode}" &&
     "${actual_sha}" == "${expected_sha}" ]] || return 2
  "${BASH}" -n "${lifecycle}" >/dev/null 2>&1 || return 2
  # shellcheck source=/dev/null
  builtin source "${lifecycle}" || return 2
  declare -F cntools_generation_validate >/dev/null 2>&1 || return 2
}

# Load the generic lifecycle implementation only from the already-adopted,
# owner-controlled Guild source snapshot. Recovery must not bootstrap trust
# from an executable snapshot and checksum stored together in its mutable
# interrupted transaction journal.
dispatcher_cntools_source_snapshot_lifecycle() {
  local manifest="" path="" source="" mode="" validator="" expected_sha=""
  local expected="" expected_source="" expected_mode=""
  local expected_validator="" lifecycle_source="" lifecycle_sha=""
  local actual_sha="" count=0

  manifest="$(guild_source_path \
    scripts/common-helper-scripts/cntools/manifest.json)" || return 2
  dispatcher_cntools_generation_manifest_valid "${manifest}" || return 2
  while IFS=$'\t' read -r path source mode validator expected_sha; do
    expected="$(dispatcher_cntools_expected_record "${path}")" || return 2
    IFS=$'\t' read -r expected_source expected_mode expected_validator \
      <<< "${expected}"
    [[ "${source}" == "${expected_source}" &&
       "${mode}" == "${expected_mode}" &&
       "${validator}" == "${expected_validator}" &&
       "${expected_sha}" =~ ^[0-9a-f]{64}$ ]] || return 2
    if [[ "${path}" == "cntools/core/lifecycle.sh" ]]; then
      lifecycle_source="${source}"
      lifecycle_sha="${expected_sha}"
    fi
    count=$((count + 1))
  done < <(jq -er '.files[] |
    [.path,.source,.mode,.validator,.sha256] | @tsv' "${manifest}")
  (( count == 151 )) || return 2
  [[ "${lifecycle_source}" == \
       "scripts/common-helper-scripts/cntools/core/lifecycle.sh" &&
     "${lifecycle_sha}" =~ ^[0-9a-f]{64}$ ]] || return 2
  lifecycle_source="$(guild_source_path "${lifecycle_source}")" || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${lifecycle_source}" ||
    return 2
  actual_sha="$(dispatcher_sha256 "${lifecycle_source}")" || return 2
  [[ "${actual_sha}" == "${lifecycle_sha}" ]] || return 2
  "${BASH}" -n "${lifecycle_source}" >/dev/null 2>&1 || return 2
  # shellcheck source=/dev/null
  builtin source "${lifecycle_source}" || return 2
  declare -F cntools_generation_validate >/dev/null 2>&1 || return 2
  declare -F cntools_generation_deployment_lock_acquire >/dev/null 2>&1 ||
    return 2
  DISPATCHER_CNTOOLS_GENERATION_SOURCE_LIFECYCLE_SHA256="${lifecycle_sha}"
}

dispatcher_cntools_generation_lock_acquire() {
  local lifecycle="${1:-}" expected_sha="${2:-}" mode="${3:-0444}"
  local recovery_authorized="${4:-N}"
  local root="${NODE_HOME}/scripts/.cntools"

  [[ "${DISPATCHER_CNTOOLS_GENERATION_LOCK_OWNED:-N}" != "Y" ]] || {
    cntools_generation_lock_is_owned "${root}"
    return $?
  }
  dispatcher_cntools_source_trusted_lifecycle \
    "${lifecycle}" "${expected_sha}" "${mode}" || return 2
  cntools_generation_deployment_lock_acquire \
    "${root}" "${recovery_authorized}" || return $?
  DISPATCHER_CNTOOLS_GENERATION_LOCK_ROOT="${root}"
  DISPATCHER_CNTOOLS_GENERATION_LOCK_OWNED="Y"
}

dispatcher_cntools_generation_lock_release() {
  local root="${DISPATCHER_CNTOOLS_GENERATION_LOCK_ROOT:-}"

  [[ "${DISPATCHER_CNTOOLS_GENERATION_LOCK_OWNED:-N}" == "Y" ]] || return 0
  [[ "${root}" == "${NODE_HOME}/scripts/.cntools" ]] || return 2
  declare -F cntools_generation_lock_release >/dev/null 2>&1 || return 2
  cntools_generation_lock_release "${root}" || return 2
  DISPATCHER_CNTOOLS_GENERATION_LOCK_OWNED="N"
  DISPATCHER_CNTOOLS_GENERATION_LOCK_ROOT=""
  unset CNTOOLS_GENERATION_LOCK_PATH CNTOOLS_GENERATION_LOCK_ROOT
  unset CNTOOLS_GENERATION_LOCK_BACKEND CNTOOLS_GENERATION_LOCK_CONTROL
  unset CNTOOLS_GENERATION_LOCK_HOLDER_PID
  unset CNTOOLS_GENERATION_LOCK_HOLDER_IDENTITY CNTOOLS_GENERATION_LOCK_PID
}

dispatcher_cntools_generation_recovery_lock_acquire() {
  local durable_root="${1:-}"
  local record="${durable_root}/cntools-generation.tsv"
  local validator="${durable_root}/cntools-generation-validator.sh"
  local id="" relative="" root_existed="" generations_existed=""
  local target_existed="" lifecycle_sha="" receipt_lifecycle_sha=""
  local root="${NODE_HOME}/scripts/.cntools" target="" staged="" inspected=""
  local validator_sha="" validator_mode=""
  local target_present="N" staged_present="N" inspected_mode=""

  [[ -e "${record}" || -L "${record}" ]] || return 0
  dispatcher_cntools_generation_record_parse "${record}" || return 2
  id="${DISPATCHER_CNTOOLS_RECORD_ID}"
  relative="${DISPATCHER_CNTOOLS_RECORD_RELATIVE}"
  root_existed="${DISPATCHER_CNTOOLS_RECORD_ROOT_EXISTED}"
  generations_existed="${DISPATCHER_CNTOOLS_RECORD_GENERATIONS_EXISTED}"
  target_existed="${DISPATCHER_CNTOOLS_RECORD_TARGET_EXISTED}"
  lifecycle_sha="${DISPATCHER_CNTOOLS_RECORD_LIFECYCLE_SHA256}"
  dispatcher_cntools_source_snapshot_lifecycle || return 2
  target="${NODE_HOME}/${relative}"
  staged="${durable_root}/cntools-generation/${id}"
  if [[ "${target_existed}" == "Y" ]]; then
    [[ -d "${target}" && ! -L "${target}" && -O "${target}" ]] || return 2
    inspected="${target}"
  else
    if [[ -e "${target}" || -L "${target}" ]]; then
      [[ -d "${target}" && ! -L "${target}" && -O "${target}" ]] || return 2
      target_present="Y"
    fi
    if [[ -e "${staged}" || -L "${staged}" ]]; then
      [[ -d "${staged}" && ! -L "${staged}" && -O "${staged}" ]] || return 2
      staged_present="Y"
    fi
    # A newly-created generation is always in exactly one recorded location:
    # the durable stage before publish, or the public target after publish.
    # Rollback moves the latter back into the former. Both copies at once are
    # impossible; neither copy means an earlier transaction-root cleanup was
    # interrupted after retracting this tree and is idempotently complete.
    case "${target_present}:${staged_present}" in
      Y:N) inspected="${target}" ;;
      N:Y) inspected="${staged}" ;;
      N:N) inspected="" ;;
      *) return 2 ;;
    esac
    # A hard crash on either side of an APFS-compatible rename can leave only
    # the transaction-owned root at its temporary 0755 mode. Normalize that
    # one root before full validation; descendants are never relaxed.
    if [[ -n "${inspected}" ]]; then
      inspected_mode="$(dispatcher_path_mode "${inspected}")" || return 2
      case "${inspected_mode}" in
        0555) ;;
        0755) chmod 0555 "${inspected}" || return 2 ;;
        *) return 2 ;;
      esac
    fi
  fi
  if [[ -n "${inspected}" ]]; then
    cntools_generation_validate "${inspected}" "${id}" || return 2
    receipt_lifecycle_sha="$(jq -er '
      [.files[] | select(
        .path == "cntools/core/lifecycle.sh" and
        .source == "scripts/common-helper-scripts/cntools/core/lifecycle.sh" and
        .mode == "0444" and .validator == "shell")] |
      if length == 1 then .[0].sha256 else error("lifecycle record") end
    ' "${inspected}/.generation.json")" || return 2
    [[ "${receipt_lifecycle_sha}" =~ ^[0-9a-f]{64}$ &&
       "${receipt_lifecycle_sha}" == "${lifecycle_sha}" ]] || return 2
  else
    receipt_lifecycle_sha="${lifecycle_sha}"
  fi
  [[ -f "${validator}" && ! -L "${validator}" && -O "${validator}" ]] ||
    return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${validator}" || return 2
  validator_mode="$(dispatcher_file_mode "${validator}")" || return 2
  validator_sha="$(dispatcher_sha256 "${validator}")" || return 2
  [[ "${validator_mode}" == "0400" &&
     "${validator_sha}" == "${receipt_lifecycle_sha}" ]] || return 2
  "${BASH}" -n "${validator}" >/dev/null 2>&1 || return 2
  cntools_generation_deployment_lock_acquire "${root}" Y || return $?
  DISPATCHER_CNTOOLS_GENERATION_LIFECYCLE_SHA256="${receipt_lifecycle_sha}"
  DISPATCHER_CNTOOLS_GENERATION_LOCK_ROOT="${root}"
  DISPATCHER_CNTOOLS_GENERATION_LOCK_OWNED="Y"
}

dispatcher_cntools_generation_prepare() {
  local source_manifest="${1:-}"
  local source_manifest_path="${2:-}"
  local target_root="${3:-}"
  local work_root="" candidate="" records="" canonical="" files_json=""
  local path="" source="" mode="" validator="" expected_sha=""
  local expected="" expected_source="" expected_mode="" expected_validator=""
  local source_file="" destination="" actual_sha="" manifest_sha=""
  local generation_id="" generation_receipt="" version="" count=0
  local seen='|'

  [[ "${NODE_IMPLEMENTATION}" == "cnode" ||
     "${NODE_IMPLEMENTATION}" == "dingo" ]] || return 2
  [[ "${DISPATCHER_CNTOOLS_GENERATION_PREPARED:-N}" != "Y" ]] || return 2
  [[ "${source_manifest_path}" == \
       'scripts/common-helper-scripts/cntools/manifest.json' &&
     "${target_root}" == 'scripts/.cntools' ]] || return 2
  dispatcher_cntools_generation_manifest_valid "${source_manifest}" || return 2

  work_root="${DISPATCHER_TX_STAGE_ROOT}/cntools-generation"
  candidate="${work_root}/candidate"
  records="${work_root}/records.tsv"
  canonical="${work_root}/canonical.tsv"
  files_json="${work_root}/files.json"
  mkdir -- "${work_root}" "${candidate}" || return 2
  chmod 0700 "${work_root}" "${candidate}" || return 2
  : > "${records}" || return 2
  chmod 0600 "${records}" || return 2

  while IFS=$'\t' read -r path source mode validator expected_sha; do
    [[ -n "${path}" && -n "${source}" && -n "${mode}" &&
       -n "${validator}" && "${expected_sha}" =~ ^[0-9a-f]{64}$ ]] ||
      return 2
    [[ "${seen}" != *"|${path}|"* ]] || return 2
    seen="${seen}${path}|"
    expected="$(dispatcher_cntools_expected_record "${path}")" || return 2
    IFS=$'\t' read -r expected_source expected_mode expected_validator \
      <<< "${expected}"
    [[ "${source}" == "${expected_source}" &&
       "${mode}" == "${expected_mode}" &&
       "${validator}" == "${expected_validator}" ]] || return 2
    source_file="$(guild_source_path "${source}")" || return 2
    actual_sha="$(dispatcher_sha256 "${source_file}")" || return 2
    [[ "${actual_sha}" == "${expected_sha}" ]] || return 2
    dispatcher_cntools_generation_validate_member \
      "${source_file}" "${validator}" || return 2
    if [[ "${path}" == "cntools/core/lifecycle.sh" ]]; then
      DISPATCHER_CNTOOLS_GENERATION_LIFECYCLE_SHA256="${actual_sha}"
    fi
    destination="${candidate}/${path}"
    mkdir -p -- "$(dirname -- "${destination}")" || return 2
    cp -- "${source_file}" "${destination}" || return 2
    chmod "${mode}" "${destination}" || return 2
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${path}" "${source}" "${mode}" "${validator}" "${actual_sha}" \
      >> "${records}" || return 2
    count=$((count + 1))
  done < <(jq -er '.files[] | [.path,.source,.mode,.validator,.sha256] | @tsv' \
    "${source_manifest}")
  (( count == 151 )) || return 2
  [[ "${DISPATCHER_CNTOOLS_GENERATION_LIFECYCLE_SHA256:-}" =~ \
       ^[0-9a-f]{64}$ ]] || return 2

  destination="${candidate}/cntools/manifest.json"
  mkdir -p -- "$(dirname -- "${destination}")" || return 2
  cp -- "${source_manifest}" "${destination}" || return 2
  chmod 0444 "${destination}" || return 2
  manifest_sha="$(dispatcher_sha256 "${destination}")" || return 2
  printf '%s\t%s\t%s\t%s\t%s\n' \
    'cntools/manifest.json' "${source_manifest_path}" 0444 json \
    "${manifest_sha}" >> "${records}" || return 2

  LC_ALL=C sort -t $'\t' -k1,1 "${records}" |
    awk -F '\t' 'BEGIN { OFS="\t" } { print $1, $3, $5 }' \
    > "${canonical}" || return 2
  generation_id="$(dispatcher_sha256 "${canonical}")" || return 2
  [[ "${generation_id}" =~ ^[0-9a-f]{64}$ ]] || return 2
  version="$(jq -er '.version' "${source_manifest}")" || return 2

  LC_ALL=C sort -t $'\t' -k1,1 "${records}" |
    jq -Rn '[inputs | split("\t") |
      {path:.[0],source:.[1],mode:.[2],validator:.[3],sha256:.[4]}]' \
      > "${files_json}" || return 2
  generation_receipt="${candidate}/.generation.json"
  jq -n \
    --arg id "${generation_id}" \
    --arg version "${version}" \
    --arg manifest_sha "${manifest_sha}" \
    --slurpfile files "${files_json}" '
      {
        schemaVersion: 3,
        id: $id,
        version: $version,
        generationIdAlgorithm: "sha256-path-mode-content-v1",
        payloadManifest: "cntools/manifest.json",
        payloadManifestSha256: $manifest_sha,
        files: $files[0]
      }
    ' > "${generation_receipt}" || return 2
  chmod 0444 "${generation_receipt}" || return 2

  while IFS= read -r destination; do
    chmod 0555 "${destination}" || return 2
  done < <(find "${candidate}" -depth -type d -print)
  mv -- "${candidate}" "${work_root}/${generation_id}" || return 2
  candidate="${work_root}/${generation_id}"

  DISPATCHER_CNTOOLS_GENERATION_STAGE="${candidate}"
  DISPATCHER_CNTOOLS_GENERATION_ID="${generation_id}"
  DISPATCHER_CNTOOLS_GENERATION_VERSION="${version}"
  DISPATCHER_CNTOOLS_GENERATION_MANIFEST_SHA256="${manifest_sha}"
  DISPATCHER_CNTOOLS_GENERATION_FILE_COUNT=152
  DISPATCHER_CNTOOLS_GENERATION_TARGET_ROOT="${target_root}"
  DISPATCHER_CNTOOLS_GENERATION_PREPARED="Y"
}

dispatcher_cntools_generation_validate_staged() {
  local stage="${DISPATCHER_CNTOOLS_GENERATION_STAGE:-}"
  local lifecycle="${stage}/cntools/core/lifecycle.sh"

  [[ "${DISPATCHER_CNTOOLS_GENERATION_PREPARED:-N}" == "Y" &&
     -d "${stage}" && ! -L "${stage}" && -f "${lifecycle}" &&
     ! -L "${lifecycle}" ]] || return 2
  (
    dispatcher_cntools_source_trusted_lifecycle \
      "${lifecycle}" \
      "${DISPATCHER_CNTOOLS_GENERATION_LIFECYCLE_SHA256}" 0444 || exit 2
    cntools_generation_validate \
      "${stage}" "${DISPATCHER_CNTOOLS_GENERATION_ID}"
  )
}

dispatcher_cntools_generation_validate_prior_installed() {
  local prior="${DISPATCHER_PRIOR_RECEIPT:-}" schema="" id="" path=""
  local manifest_hash="" receipt_hash="" generation="" root=""
  local file_count="" version=""
  local lifecycle="${1:-${DISPATCHER_CNTOOLS_GENERATION_STAGE:-}/cntools/core/lifecycle.sh}"
  local lifecycle_mode="${2:-0444}"

  root="${NODE_HOME}/scripts/.cntools"
  if [[ -n "${prior}" ]]; then
    schema="$(jq -er '.schemaVersion' "${prior}")" || return 2
    [[ "${schema}" == "1" || "${schema}" == "2" ]] || return 2
  fi
  if [[ "${schema}" == "2" ]]; then
    jq -e --arg implementation "${NODE_IMPLEMENTATION}" \
      '.implementation == $implementation' "${prior}" >/dev/null 2>&1 || return 2
    id="$(jq -er '.cntoolsGeneration.id' "${prior}")" || return 2
    path="$(jq -er '.cntoolsGeneration.path' "${prior}")" || return 2
    manifest_hash="$(jq -er \
      '.cntoolsGeneration.payloadManifestSha256' "${prior}")" || return 2
    receipt_hash="$(jq -er \
      '.cntoolsGeneration.generationReceiptSha256' "${prior}")" || return 2
    file_count="$(jq -er '.cntoolsGeneration.fileCount' "${prior}")" ||
      return 2
    version="$(jq -er '.cntoolsGeneration.version' "${prior}")" || return 2
    [[ "${id}" =~ ^[0-9a-f]{64}$ &&
       "${path}" == "scripts/.cntools/generations/${id}" &&
       "${manifest_hash}" =~ ^[0-9a-f]{64}$ &&
       "${receipt_hash}" =~ ^[0-9a-f]{64}$ &&
       "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ &&
       ( "${file_count}" == "20" || "${file_count}" == "30" ||
         "${file_count}" == "152" ) ]] || return 2
    generation="${NODE_HOME}/${path}"
    [[ -d "${generation}" && ! -L "${generation}" && -O "${generation}" &&
       "$(dispatcher_sha256 "${generation}/cntools/manifest.json")" == \
         "${manifest_hash}" &&
       "$(dispatcher_sha256 "${generation}/.generation.json")" == \
         "${receipt_hash}" ]] || return 2
    jq -e -s --arg version "${version}" --argjson count "${file_count}" '
      length == 2 and .[0].version == $version and .[1].version == $version and
      (if $count == 20 then
         .[0].schemaVersion == 1 and (.[0].files | length == 19) and
         .[1].schemaVersion == 1 and (.[1].files | length == 20)
       elif $count == 30 then
         .[0].schemaVersion == 2 and (.[0].files | length == 29) and
         .[1].schemaVersion == 2 and (.[1].files | length == 30)
       elif $count == 152 then
         .[0].schemaVersion == 3 and (.[0].files | length == 151) and
         .[1].schemaVersion == 3 and (.[1].files | length == 152)
       else false end)
    ' "${generation}/cntools/manifest.json" \
      "${generation}/.generation.json" >/dev/null 2>&1 || return 2
  fi
  [[ -e "${root}" || -L "${root}" ]] || return 0

  dispatcher_cntools_source_trusted_lifecycle \
    "${lifecycle}" \
    "${DISPATCHER_CNTOOLS_GENERATION_LIFECYCLE_SHA256}" \
    "${lifecycle_mode}" || return 2
  if [[ "${schema}" == "2" ]]; then
    cntools_generation_validate "${generation}" "${id}" || return 2
  fi
  cntools_generation_pointers_validate "${root}"
}

dispatcher_cntools_generation_prepare_durable() {
  local prepare_root="${1:-}"
  local durable_parent="${prepare_root}/cntools-generation"
  local durable_stage="${durable_parent}/${DISPATCHER_CNTOOLS_GENERATION_ID:-}"
  local validator_snapshot="${prepare_root}/cntools-generation-validator.sh"
  local record="${prepare_root}/cntools-generation.tsv"
  local target_relative="scripts/.cntools/generations/${DISPATCHER_CNTOOLS_GENERATION_ID:-}"
  local target="${NODE_HOME}/${target_relative}"
  local root="${NODE_HOME}/scripts/.cntools"
  local generations="${root}/generations"
  local root_existed="N" generations_existed="N" target_existed="N"

  [[ "${DISPATCHER_CNTOOLS_GENERATION_PREPARED:-N}" == "Y" &&
     -d "${prepare_root}" && ! -L "${prepare_root}" &&
     "${DISPATCHER_CNTOOLS_GENERATION_ID}" =~ ^[0-9a-f]{64}$ ]] || return 2
  [[ -e "${root}" || -L "${root}" ]] && root_existed="Y"
  [[ -e "${generations}" || -L "${generations}" ]] &&
    generations_existed="Y"
  [[ -e "${target}" || -L "${target}" ]] && target_existed="Y"
  mkdir -- "${durable_parent}" || return 2
  chmod 0700 "${durable_parent}" || return 2
  cp -a -- "${DISPATCHER_CNTOOLS_GENERATION_STAGE}" "${durable_stage}" ||
    return 2
  cp -- "${DISPATCHER_CNTOOLS_GENERATION_STAGE}/cntools/core/lifecycle.sh" \
    "${validator_snapshot}" || return 2
  chmod 0400 "${validator_snapshot}" || return 2
  (
    dispatcher_cntools_source_trusted_lifecycle \
      "${validator_snapshot}" \
      "${DISPATCHER_CNTOOLS_GENERATION_LIFECYCLE_SHA256}" 0400 || exit 2
    cntools_generation_validate \
      "${durable_stage}" "${DISPATCHER_CNTOOLS_GENERATION_ID}"
  ) || return 2
  dispatcher_cntools_generation_lock_acquire \
    "${validator_snapshot}" \
    "${DISPATCHER_CNTOOLS_GENERATION_LIFECYCLE_SHA256}" 0400 N || return 2
  # Repeat receipt/pointer preflight immediately before the durable journal is
  # created. Candidate validation performs the same check earlier; this closes
  # the normal staging window while publish still revalidates same-ID reuse.
  dispatcher_cntools_generation_validate_prior_installed \
    "${validator_snapshot}" 0400 || return 2
  if [[ "${target_existed}" == "Y" ]]; then
    [[ -d "${target}" && ! -L "${target}" && -O "${target}" ]] || return 2
    (
      dispatcher_cntools_source_trusted_lifecycle \
        "${validator_snapshot}" \
        "${DISPATCHER_CNTOOLS_GENERATION_LIFECYCLE_SHA256}" 0400 || exit 2
      cntools_generation_validate \
        "${target}" "${DISPATCHER_CNTOOLS_GENERATION_ID}"
    ) || return 2
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t3\t151\t3\t152\n' \
    "${DISPATCHER_CNTOOLS_GENERATION_ID}" "${target_relative}" \
    "${root_existed}" "${generations_existed}" "${target_existed}" \
    "${DISPATCHER_CNTOOLS_GENERATION_LIFECYCLE_SHA256}" \
    > "${record}" || return 2
  chmod 0600 "${record}" || return 2
}

dispatcher_cntools_generation_publish() {
  local durable_root="${1:-}"
  local record="${durable_root}/cntools-generation.tsv"
  local id="" relative="" root_existed="" generations_existed=""
  local target_existed="" lifecycle_sha=""
  local root="${NODE_HOME}/scripts/.cntools"
  local generations="${root}/generations" target="" staged=""

  dispatcher_cntools_generation_record_parse "${record}" || return 2
  [[ "${DISPATCHER_CNTOOLS_RECORD_SHAPE}" == "stage3" ]] || return 2
  id="${DISPATCHER_CNTOOLS_RECORD_ID}"
  relative="${DISPATCHER_CNTOOLS_RECORD_RELATIVE}"
  root_existed="${DISPATCHER_CNTOOLS_RECORD_ROOT_EXISTED}"
  generations_existed="${DISPATCHER_CNTOOLS_RECORD_GENERATIONS_EXISTED}"
  target_existed="${DISPATCHER_CNTOOLS_RECORD_TARGET_EXISTED}"
  lifecycle_sha="${DISPATCHER_CNTOOLS_RECORD_LIFECYCLE_SHA256}"
  [[ "${DISPATCHER_CNTOOLS_GENERATION_LOCK_OWNED:-N}" == "Y" &&
     "${DISPATCHER_CNTOOLS_GENERATION_LOCK_ROOT:-}" == "${root}" ]] || return 2
  cntools_generation_lock_is_owned "${root}" || return 2
  [[ "${lifecycle_sha}" == \
       "${DISPATCHER_CNTOOLS_GENERATION_LIFECYCLE_SHA256:-}" ]] || return 2
  declare -F cntools_generation_validate >/dev/null 2>&1 || return 2
  target="${NODE_HOME}/${relative}"
  staged="${durable_root}/cntools-generation/${id}"
  [[ -d "${staged}" && ! -L "${staged}" ]] || return 2
  cntools_generation_validate "${staged}" "${id}" || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${root}" || return 2

  if [[ "${root_existed}" == "Y" ]]; then
    [[ -d "${root}" && ! -L "${root}" && -O "${root}" &&
       "$(dispatcher_path_mode "${root}")" == "0700" ]] || return 2
  else
    [[ ! -e "${root}" && ! -L "${root}" ]] || return 2
    mkdir -- "${root}" || return 2
    chmod 0700 "${root}" || return 2
    [[ -d "${root}" && ! -L "${root}" && -O "${root}" &&
       "$(dispatcher_path_mode "${root}")" == "0700" ]] || return 2
  fi
  if [[ "${generations_existed}" == "Y" ]]; then
    [[ -d "${generations}" && ! -L "${generations}" &&
       -O "${generations}" &&
       "$(dispatcher_path_mode "${generations}")" == "0700" ]] || return 2
  else
    [[ ! -e "${generations}" && ! -L "${generations}" ]] || return 2
    mkdir -- "${generations}" || return 2
    chmod 0700 "${generations}" || return 2
    [[ -d "${generations}" && ! -L "${generations}" &&
       -O "${generations}" &&
       "$(dispatcher_path_mode "${generations}")" == "0700" ]] || return 2
  fi

  if [[ "${target_existed}" == "Y" ]]; then
    [[ -d "${target}" && ! -L "${target}" && -O "${target}" ]] || return 2
    cntools_generation_validate "${target}" "${id}" || return 2
    # Keep the redundant immutable stage inside the private transaction.
    # Commit/rollback quarantine cleanup removes it by relaxing directories
    # only; publication must never chmod packaged files or hard links.
  else
    [[ ! -e "${target}" && ! -L "${target}" ]] || return 2
    # BSD/APFS mv refuses to rename a directory whose own mode is 0555.
    # Temporarily make only the already-validated generation root writable;
    # all member files and descendant directories remain immutable. Restore
    # the required root mode immediately after the atomic directory rename.
    chmod 0755 "${staged}" || return 2
    if ! mv -- "${staged}" "${target}"; then
      chmod 0555 "${staged}" 2>/dev/null || true
      return 2
    fi
    dispatcher_test_failpoint after-cntools-generation-rename || return $?
    chmod 0555 "${target}" || return 2
  fi
  cntools_generation_validate "${target}" "${id}" || return 2
  DISPATCHER_CNTOOLS_GENERATION_INSTALLED_PATH="${relative}"
  DISPATCHER_CNTOOLS_GENERATION_PUBLISHED="Y"
}

dispatcher_cntools_generation_rollback_root() {
  local root="${1:-}"
  local record="${root}/cntools-generation.tsv"
  local id="" relative="" root_existed="" generations_existed=""
  local target_existed="" lifecycle_sha="" target=""
  local cntools_root="" generations="" staged="" inspected="" mode=""
  local target_present="N" staged_present="N"

  [[ -e "${record}" || -L "${record}" ]] || return 0
  dispatcher_cntools_generation_record_parse "${record}" || return 2
  id="${DISPATCHER_CNTOOLS_RECORD_ID}"
  relative="${DISPATCHER_CNTOOLS_RECORD_RELATIVE}"
  root_existed="${DISPATCHER_CNTOOLS_RECORD_ROOT_EXISTED}"
  generations_existed="${DISPATCHER_CNTOOLS_RECORD_GENERATIONS_EXISTED}"
  target_existed="${DISPATCHER_CNTOOLS_RECORD_TARGET_EXISTED}"
  lifecycle_sha="${DISPATCHER_CNTOOLS_RECORD_LIFECYCLE_SHA256}"
  [[ "${DISPATCHER_CNTOOLS_GENERATION_LOCK_OWNED:-N}" == "Y" &&
     "${DISPATCHER_CNTOOLS_GENERATION_LOCK_ROOT:-}" == \
       "${NODE_HOME}/scripts/.cntools" ]] || return 2
  cntools_generation_lock_is_owned "${NODE_HOME}/scripts/.cntools" || return 2
  [[ "${lifecycle_sha}" == \
       "${DISPATCHER_CNTOOLS_GENERATION_LIFECYCLE_SHA256:-}" ]] || return 2
  declare -F cntools_generation_validate >/dev/null 2>&1 || return 2
  target="${NODE_HOME}/${relative}"
  cntools_root="${NODE_HOME}/scripts/.cntools"
  generations="${cntools_root}/generations"
  staged="${root}/cntools-generation/${id}"
  if [[ "${target_existed}" == "N" ]]; then
    if [[ -e "${target}" || -L "${target}" ]]; then
      [[ -d "${target}" && ! -L "${target}" && -O "${target}" ]] || return 2
      target_present="Y"
    fi
    if [[ -e "${staged}" || -L "${staged}" ]]; then
      [[ -d "${staged}" && ! -L "${staged}" && -O "${staged}" ]] || return 2
      staged_present="Y"
    fi
    case "${target_present}:${staged_present}" in
      Y:N) inspected="${target}" ;;
      N:Y) inspected="${staged}" ;;
      N:N) inspected="" ;;
      *) return 2 ;;
    esac
    if [[ -n "${inspected}" ]]; then
      mode="$(dispatcher_path_mode "${inspected}")" || return 2
      case "${mode}" in
        0555) ;;
        0755) chmod 0555 "${inspected}" || return 2 ;;
        *) return 2 ;;
      esac
      cntools_generation_validate "${inspected}" "${id}" || return 2
    fi
    if [[ "${target_present}" == "Y" ]]; then
      # Move the validated target back into the now-empty durable stage. This
      # is atomic on the NODE_HOME filesystem and keeps every member and
      # descendant directory immutable through all rollback crash windows.
      chmod 0755 "${target}" || return 2
      if ! mv -- "${target}" "${staged}"; then
        [[ ! -d "${target}" || -L "${target}" ]] ||
          chmod 0555 "${target}" 2>/dev/null || true
        [[ ! -d "${staged}" || -L "${staged}" ]] ||
          chmod 0555 "${staged}" 2>/dev/null || true
        return 2
      fi
      chmod 0555 "${staged}" || return 2
      cntools_generation_validate "${staged}" "${id}" || return 2
    fi
  fi
  if [[ "${generations_existed}" == "N" && -d "${generations}" &&
        ! -L "${generations}" ]]; then
    [[ -O "${generations}" &&
       "$(dispatcher_path_mode "${generations}")" == "0700" ]] || return 2
    rmdir -- "${generations}" || return 2
  elif [[ "${generations_existed}" == "N" &&
          ( -e "${generations}" || -L "${generations}" ) ]]; then
    return 2
  fi
  if [[ "${root_existed}" == "N" && -d "${cntools_root}" &&
        ! -L "${cntools_root}" ]]; then
    [[ -O "${cntools_root}" &&
       "$(dispatcher_path_mode "${cntools_root}")" == "0700" ]] || return 2
    rmdir -- "${cntools_root}" || return 2
  elif [[ "${root_existed}" == "N" &&
          ( -e "${cntools_root}" || -L "${cntools_root}" ) ]]; then
    return 2
  fi
}

dispatcher_cntools_legacy_bundle_validate_tree() {
  local tree="${1:-}" manifest="${2:-}" contract="${3:-current}"
  local root_mode_contract="${4:-immutable}"
  local id="" expected_path=""
  local member="" mode="" size="" sha="" member_file=""
  local actual_mode="" actual_size="" actual_sha="" canonical_id=""
  local actual_inventory="" expected_inventory=""

  case "${contract}" in
    current) dispatcher_cntools_legacy_bundle_metadata_valid "${manifest}" ;;
    durable) dispatcher_cntools_legacy_bundle_data_manifest_valid "${manifest}" ;;
    *) return 2 ;;
  esac || return 2
  id="$(jq -er '.legacyBundle.id' "${manifest}")" || return 2
  expected_path="$(jq -er '.legacyBundle.path' "${manifest}")" || return 2
  [[ "${id}" =~ ^[0-9a-f]{64}$ && "$(basename -- "${tree}")" == "${id}" &&
     "$(basename -- "${expected_path}")" == "${id}" &&
     -d "${tree}" && ! -L "${tree}" && -O "${tree}" ]] || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${tree}" || return 2
  actual_mode="$(dispatcher_path_mode "${tree}")" || return 2
  case "${root_mode_contract}" in
    immutable) [[ "${actual_mode}" == "0555" ]] || return 2 ;;
    rollback-transient)
      [[ "${actual_mode}" == "0555" || "${actual_mode}" == "0755" ]] ||
        return 2
      ;;
    *) return 2 ;;
  esac
  while IFS=$'\t' read -r member mode size sha; do
    [[ "${member}" != */* && "${mode}" == "0444" &&
       "${size}" =~ ^(0|[1-9][0-9]*)$ && "${sha}" =~ ^[0-9a-f]{64}$ ]] ||
      return 2
    member_file="${tree}/${member}"
    [[ -f "${member_file}" && ! -L "${member_file}" &&
       -O "${member_file}" ]] || return 2
    actual_mode="$(dispatcher_file_mode "${member_file}")" || return 2
    actual_size="$(wc -c < "${member_file}" 2>/dev/null)" || return 2
    actual_size="${actual_size//[[:space:]]/}"
    actual_sha="$(dispatcher_sha256 "${member_file}")" || return 2
    [[ "${actual_mode}" == "${mode}" && "${actual_size}" == "${size}" &&
       "${actual_sha}" == "${sha}" ]] || return 2
  done < <(jq -er '.legacyBundle.members[] |
    [.path,.mode,(.size|tostring),.sha256] | @tsv' "${manifest}")
  actual_inventory="$(find "${tree}" -mindepth 1 -maxdepth 1 -type f -print |
    sed "s#^${tree}/##" | LC_ALL=C sort)" || return 2
  expected_inventory="$(jq -er '.legacyBundle.members[].path' "${manifest}" |
    LC_ALL=C sort)" || return 2
  [[ "${actual_inventory}" == "${expected_inventory}" &&
     -z "$(find "${tree}" -mindepth 1 -maxdepth 1 ! -type f -print -quit \
       2>/dev/null)" ]] || return 2
  canonical_id="$({
    printf 'cntools-legacy-bundle-v1\n'
    printf 'facade\t%s\n' "$(jq -er '.legacyBundle.facade' "${manifest}")" ||
      return 2
    printf 'logical-body\t%s\t%s\n' \
      "$(jq -er '.legacyBundle.logicalBodySize' "${manifest}")" \
      "$(jq -er '.legacyBundle.logicalBodySha256' "${manifest}")"
    jq -er '.legacyBundle.members[] |
      "member\t\(.path)\t\(.mode)\t\(.size)\t\(.sha256)"' \
      "${manifest}" || return 2
  } | if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi)" || return 2
  canonical_id="${canonical_id%% *}"
  [[ "${canonical_id}" == "${id}" ]]
}

dispatcher_cntools_legacy_bundle_prepare() {
  local source_manifest="${1:-}" source_manifest_path="${2:-}"
  local target_root="${3:-}" id="" bundle_path="" work_root="" candidate=""
  local member="" mode="" size="" sha="" source="" source_file=""
  local destination="" actual_size="" actual_sha=""

  [[ "${NODE_IMPLEMENTATION}" == "cnode" ||
     "${NODE_IMPLEMENTATION}" == "dingo" ]] || return 2
  [[ "${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_PREPARED:-N}" != "Y" &&
     "${source_manifest_path}" == \
       'scripts/common-helper-scripts/cntools/manifest.json' &&
     "${target_root}" == 'scripts/cntools/libs/legacy' ]] || return 2
  dispatcher_cntools_generation_manifest_valid "${source_manifest}" || return 2
  id="$(jq -er '.legacyBundle.id' "${source_manifest}")" || return 2
  bundle_path="$(jq -er '.legacyBundle.path' "${source_manifest}")" || return 2
  [[ "${id}" =~ ^[0-9a-f]{64}$ &&
     "${bundle_path}" == "cntools/libs/legacy/${id}" ]] || return 2
  work_root="${DISPATCHER_TX_STAGE_ROOT}/cntools-legacy-bundle"
  candidate="${work_root}/${id}"
  mkdir -- "${work_root}" "${candidate}" || return 2
  chmod 0700 "${work_root}" "${candidate}" || return 2
  while IFS=$'\t' read -r member mode size sha; do
    source="scripts/common-helper-scripts/${bundle_path}/${member}"
    source_file="$(guild_source_path "${source}")" || return 2
    [[ -f "${source_file}" && ! -L "${source_file}" ]] || return 2
    actual_size="$(wc -c < "${source_file}" 2>/dev/null)" || return 2
    actual_size="${actual_size//[[:space:]]/}"
    actual_sha="$(dispatcher_sha256 "${source_file}")" || return 2
    [[ "${mode}" == "0444" && "${actual_size}" == "${size}" &&
       "${actual_sha}" == "${sha}" ]] || return 2
    destination="${candidate}/${member}"
    cp -- "${source_file}" "${destination}" || return 2
    chmod 0444 "${destination}" || return 2
  done < <(jq -er '.legacyBundle.members[] |
    [.path,.mode,(.size|tostring),.sha256] | @tsv' "${source_manifest}")
  chmod 0555 "${candidate}" || return 2
  dispatcher_cntools_legacy_bundle_validate_tree \
    "${candidate}" "${source_manifest}" || return 2
  DISPATCHER_CNTOOLS_LEGACY_BUNDLE_MANIFEST="${source_manifest}"
  DISPATCHER_CNTOOLS_LEGACY_BUNDLE_STAGE="${candidate}"
  DISPATCHER_CNTOOLS_LEGACY_BUNDLE_ID="${id}"
  DISPATCHER_CNTOOLS_LEGACY_BUNDLE_TARGET_ROOT="${target_root}"
  DISPATCHER_CNTOOLS_LEGACY_BUNDLE_PREPARED="Y"
}

dispatcher_cntools_legacy_bundle_parent_safe() {
  local directory="${1:-}" mode=""

  [[ -d "${directory}" && ! -L "${directory}" && -O "${directory}" ]] ||
    return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${directory}" || return 2
  mode="$(dispatcher_path_mode "${directory}")" || return 2
  [[ "${mode}" == "0700" || "${mode}" == "0755" ]]
}

dispatcher_cntools_legacy_bundle_prepare_durable() {
  local prepare_root="${1:-}" id="${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_ID:-}"
  local durable_parent="${prepare_root}/cntools-legacy-bundle"
  local durable_stage="${durable_parent}/${id}"
  local record="${prepare_root}/cntools-legacy-bundle.tsv"
  local data_manifest="${prepare_root}/cntools-legacy-bundle-manifest.json"
  local data_manifest_sha=""
  local target_relative="scripts/cntools/libs/legacy/${id}"
  local cntools="${NODE_HOME}/scripts/cntools" libs="" legacy="" target=""
  local cntools_existed="N" libs_existed="N" legacy_existed="N"
  local target_existed="N"

  libs="${cntools}/libs"
  legacy="${libs}/legacy"
  target="${legacy}/${id}"
  [[ "${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_PREPARED:-N}" == "Y" &&
     -d "${prepare_root}" && ! -L "${prepare_root}" &&
     "${id}" =~ ^[0-9a-f]{64}$ ]] || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${cntools}" || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${libs}" || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${legacy}" || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${target}" || return 2
  [[ -e "${cntools}" || -L "${cntools}" ]] && cntools_existed="Y"
  [[ -e "${libs}" || -L "${libs}" ]] && libs_existed="Y"
  [[ -e "${legacy}" || -L "${legacy}" ]] && legacy_existed="Y"
  [[ -e "${target}" || -L "${target}" ]] && target_existed="Y"
  case "${cntools_existed}:${libs_existed}:${legacy_existed}:${target_existed}" in
    Y:Y:Y:Y|Y:Y:Y:N|Y:Y:N:N|Y:N:N:N|N:N:N:N) ;;
    *) return 2 ;;
  esac
  [[ "${cntools_existed}" == "N" ]] ||
    dispatcher_cntools_legacy_bundle_parent_safe "${cntools}" || return 2
  [[ "${libs_existed}" == "N" ]] ||
    dispatcher_cntools_legacy_bundle_parent_safe "${libs}" || return 2
  [[ "${legacy_existed}" == "N" ]] ||
    dispatcher_cntools_legacy_bundle_parent_safe "${legacy}" || return 2
  if [[ "${target_existed}" == "Y" ]]; then
    dispatcher_cntools_legacy_bundle_validate_tree \
      "${target}" "${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_MANIFEST}" || return 2
  fi
  mkdir -- "${durable_parent}" || return 2
  chmod 0700 "${durable_parent}" || return 2
  cp -a -- "${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_STAGE}" "${durable_stage}" ||
    return 2
  jq -e '{legacyBundle:.legacyBundle}' \
    "${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_MANIFEST}" > "${data_manifest}" ||
    return 2
  chmod 0400 "${data_manifest}" || return 2
  dispatcher_cntools_legacy_bundle_data_manifest_valid "${data_manifest}" ||
    return 2
  data_manifest_sha="$(dispatcher_sha256 "${data_manifest}")" || return 2
  dispatcher_cntools_legacy_bundle_validate_tree \
    "${durable_stage}" "${data_manifest}" durable || return 2
  dispatcher_cntools_legacy_bundle_matches_transaction_generation \
    "${prepare_root}" "${data_manifest}" || return 2
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${id}" "${target_relative}" "${cntools_existed}" "${libs_existed}" \
    "${legacy_existed}" "${target_existed}" "${data_manifest_sha}" \
    > "${record}" || return 2
  chmod 0600 "${record}" || return 2
}

dispatcher_cntools_legacy_bundle_publish() {
  local durable_root="${1:-}"
  local record="${durable_root}/cntools-legacy-bundle.tsv"
  local id="" relative="" cntools_existed="" libs_existed=""
  local legacy_existed="" target_existed="" extra="" staged="" target=""
  local data_manifest="${durable_root}/cntools-legacy-bundle-manifest.json"
  local data_manifest_sha="" actual_manifest_sha=""
  local cntools="${NODE_HOME}/scripts/cntools" libs="" legacy=""

  libs="${cntools}/libs"
  legacy="${libs}/legacy"
  [[ -f "${record}" && ! -L "${record}" && -O "${record}" ]] || return 2
  IFS=$'\t' read -r id relative cntools_existed libs_existed legacy_existed \
    target_existed data_manifest_sha extra < "${record}" || return 2
  [[ -z "${extra}" && "${id}" == \
       "${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_ID:-}" &&
     "${relative}" == "scripts/cntools/libs/legacy/${id}" &&
     "${data_manifest_sha}" =~ ^[0-9a-f]{64}$ ]] || return 2
  case "${cntools_existed}:${libs_existed}:${legacy_existed}:${target_existed}" in
    Y:Y:Y:Y|Y:Y:Y:N|Y:Y:N:N|Y:N:N:N|N:N:N:N) ;;
    *) return 2 ;;
  esac
  staged="${durable_root}/cntools-legacy-bundle/${id}"
  target="${NODE_HOME}/${relative}"
  dispatcher_cntools_absolute_path_has_no_symlinks "${staged}" || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${target}" || return 2
  [[ -f "${data_manifest}" && ! -L "${data_manifest}" &&
     -O "${data_manifest}" &&
     "$(dispatcher_file_mode "${data_manifest}")" == "0400" ]] || return 2
  actual_manifest_sha="$(dispatcher_sha256 "${data_manifest}")" || return 2
  [[ "${actual_manifest_sha}" == "${data_manifest_sha}" &&
     "$(jq -er '.legacyBundle.id' "${data_manifest}")" == "${id}" ]] || return 2
  dispatcher_cntools_legacy_bundle_data_manifest_valid "${data_manifest}" ||
    return 2
  dispatcher_cntools_legacy_bundle_matches_transaction_generation \
    "${durable_root}" "${data_manifest}" || return 2
  dispatcher_cntools_legacy_bundle_validate_tree \
    "${staged}" "${data_manifest}" durable || return 2
  if [[ "${cntools_existed}" == "N" ]]; then
    dispatcher_cntools_absolute_path_has_no_symlinks "${cntools}" || return 2
    mkdir -- "${cntools}" && chmod 0700 "${cntools}" || return 2
  else
    dispatcher_cntools_legacy_bundle_parent_safe "${cntools}" || return 2
  fi
  if [[ "${libs_existed}" == "N" ]]; then
    dispatcher_cntools_absolute_path_has_no_symlinks "${libs}" || return 2
    mkdir -- "${libs}" && chmod 0700 "${libs}" || return 2
  else
    dispatcher_cntools_legacy_bundle_parent_safe "${libs}" || return 2
  fi
  if [[ "${legacy_existed}" == "N" ]]; then
    dispatcher_cntools_absolute_path_has_no_symlinks "${legacy}" || return 2
    mkdir -- "${legacy}" && chmod 0700 "${legacy}" || return 2
  else
    dispatcher_cntools_legacy_bundle_parent_safe "${legacy}" || return 2
  fi
  if [[ "${target_existed}" == "Y" ]]; then
    dispatcher_cntools_legacy_bundle_validate_tree \
      "${target}" "${data_manifest}" durable || return 2
    # Leave the redundant immutable stage under the durable journal. The
    # quarantined transaction cleanup owns deletion and never chmods files.
  else
    [[ ! -e "${target}" && ! -L "${target}" ]] || return 2
    dispatcher_cntools_absolute_path_has_no_symlinks "${staged}" || return 2
    dispatcher_cntools_absolute_path_has_no_symlinks "${target}" || return 2
    chmod 0755 "${staged}" || return 2
    if ! mv -- "${staged}" "${target}"; then
      chmod 0555 "${staged}" 2>/dev/null || true
      return 2
    fi
    dispatcher_test_failpoint after-cntools-legacy-bundle-rename || return $?
    chmod 0555 "${target}" || return 2
  fi
  dispatcher_cntools_legacy_bundle_validate_tree \
    "${target}" "${data_manifest}" durable || return 2
  DISPATCHER_CNTOOLS_LEGACY_BUNDLE_INSTALLED_PATH="${relative}"
  DISPATCHER_CNTOOLS_LEGACY_BUNDLE_PUBLISHED="Y"
}

dispatcher_cntools_legacy_bundle_rollback_root() {
  local root="${1:-}"
  local record="${root}/cntools-legacy-bundle.tsv"
  local id="" relative="" cntools_existed="" libs_existed=""
  local legacy_existed="" target_existed="" extra="" target=""
  local data_manifest="${root}/cntools-legacy-bundle-manifest.json"
  local data_manifest_sha="" actual_manifest_sha=""
  local cntools="${NODE_HOME}/scripts/cntools" libs="" legacy="" staged=""
  local inspected="" mode="" target_present="N" staged_present="N"

  [[ -e "${record}" || -L "${record}" ]] || return 0
  [[ -f "${record}" && ! -L "${record}" && -O "${record}" ]] || return 2
  IFS=$'\t' read -r id relative cntools_existed libs_existed legacy_existed \
    target_existed data_manifest_sha extra < "${record}" || return 2
  [[ -z "${extra}" && "${id}" =~ ^[0-9a-f]{64}$ &&
     "${relative}" == "scripts/cntools/libs/legacy/${id}" &&
     "${data_manifest_sha}" =~ ^[0-9a-f]{64}$ ]] || return 2
  case "${cntools_existed}:${libs_existed}:${legacy_existed}:${target_existed}" in
    Y:Y:Y:Y|Y:Y:Y:N|Y:Y:N:N|Y:N:N:N|N:N:N:N) ;;
    *) return 2 ;;
  esac
  target="${NODE_HOME}/${relative}"
  staged="${root}/cntools-legacy-bundle/${id}"
  libs="${cntools}/libs"
  legacy="${libs}/legacy"
  dispatcher_cntools_absolute_path_has_no_symlinks "${target}" || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${staged}" || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${cntools}" || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${libs}" || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${legacy}" || return 2
  [[ -f "${data_manifest}" && ! -L "${data_manifest}" &&
     -O "${data_manifest}" &&
     "$(dispatcher_file_mode "${data_manifest}")" == "0400" ]] || return 2
  actual_manifest_sha="$(dispatcher_sha256 "${data_manifest}")" || return 2
  [[ "${actual_manifest_sha}" == "${data_manifest_sha}" &&
     "$(jq -er '.legacyBundle.id' "${data_manifest}")" == "${id}" ]] || return 2
  dispatcher_cntools_legacy_bundle_data_manifest_valid "${data_manifest}" ||
    return 2
  dispatcher_cntools_legacy_bundle_matches_transaction_generation \
    "${root}" "${data_manifest}" || return 2
  if [[ "${target_existed}" == "Y" ]]; then
    # A pre-existing content-addressed target is part of the authoritative
    # baseline. Authenticate it from the transaction-owned data manifest
    # before allowing receipt/metadata rollback to restore that authority.
    dispatcher_cntools_legacy_bundle_validate_tree \
      "${target}" "${data_manifest}" durable || return 2
  else
    if [[ -e "${target}" || -L "${target}" ]]; then
      [[ -d "${target}" && ! -L "${target}" && -O "${target}" ]] || return 2
      target_present="Y"
    fi
    if [[ -e "${staged}" || -L "${staged}" ]]; then
      [[ -d "${staged}" && ! -L "${staged}" && -O "${staged}" ]] || return 2
      staged_present="Y"
    fi
    case "${target_present}:${staged_present}" in
      Y:N) inspected="${target}" ;;
      N:Y) inspected="${staged}" ;;
      N:N) inspected="" ;;
      *) return 2 ;;
    esac
    if [[ -n "${inspected}" ]]; then
      mode="$(dispatcher_path_mode "${inspected}")" || return 2
      case "${mode}" in
        0555) ;;
        0755) chmod 0555 "${inspected}" || return 2 ;;
        *) return 2 ;;
      esac
      dispatcher_cntools_legacy_bundle_validate_tree \
        "${inspected}" "${data_manifest}" durable || return 2
    fi
    if [[ "${target_present}" == "Y" ]]; then
      # Preserve the complete immutable bundle by moving it back under the
      # durable transaction root. Transaction cleanup, after all rollback
      # legs succeed, owns deletion of this staged tree.
      dispatcher_cntools_absolute_path_has_no_symlinks "${target}" || return 2
      dispatcher_cntools_absolute_path_has_no_symlinks "${staged}" || return 2
      chmod 0755 "${target}" || return 2
      if ! mv -- "${target}" "${staged}"; then
        [[ ! -d "${target}" || -L "${target}" ]] ||
          chmod 0555 "${target}" 2>/dev/null || true
        [[ ! -d "${staged}" || -L "${staged}" ]] ||
          chmod 0555 "${staged}" 2>/dev/null || true
        return 2
      fi
      chmod 0555 "${staged}" || return 2
      dispatcher_cntools_legacy_bundle_validate_tree \
        "${staged}" "${data_manifest}" durable || return 2
    fi
  fi
  if [[ "${legacy_existed}" == "N" ]]; then
    if [[ -e "${legacy}" || -L "${legacy}" ]]; then
      dispatcher_cntools_absolute_path_has_no_symlinks "${legacy}" || return 2
      [[ -d "${legacy}" && ! -L "${legacy}" && -O "${legacy}" &&
         "$(dispatcher_path_mode "${legacy}")" == "0700" ]] || return 2
      rmdir -- "${legacy}" || return 2
    fi
  fi
  if [[ "${libs_existed}" == "N" ]]; then
    if [[ -e "${libs}" || -L "${libs}" ]]; then
      dispatcher_cntools_absolute_path_has_no_symlinks "${libs}" || return 2
      [[ -d "${libs}" && ! -L "${libs}" && -O "${libs}" &&
         "$(dispatcher_path_mode "${libs}")" == "0700" ]] || return 2
      rmdir -- "${libs}" || return 2
    fi
  fi
  if [[ "${cntools_existed}" == "N" ]]; then
    if [[ -e "${cntools}" || -L "${cntools}" ]]; then
      dispatcher_cntools_absolute_path_has_no_symlinks "${cntools}" || return 2
      [[ -d "${cntools}" && ! -L "${cntools}" && -O "${cntools}" &&
         "$(dispatcher_path_mode "${cntools}")" == "0700" ]] || return 2
      rmdir -- "${cntools}" || return 2
    fi
  fi
}

dispatcher_cntools_legacy_bundle_managed_path() {
  [[ "${1:-}" =~ ^scripts/cntools/libs/legacy/[0-9a-f]{64}/[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

dispatcher_distribution_prepare() {
  local manifest="" stage_root="" candidate_root="" plan=""
  local first_line=""
  local implementation="" source_path="" target_path="" mode=""
  local policy="" validator="" extra="" source_file="" candidate=""
  local effective_policy="" source_hash="" seen='|' record_count=0
  local force_scripts="N" force_config="N"
  local merge_header_override=""
  local first_plan_target=""

  [[ "${_GUILD_SOURCE_PREPARED:-N}" == "Y" ]] || return 2
  dispatcher_distribution_validate_prior_receipt || return 2
  manifest="$(guild_source_path files/node-implementations/source-manifest.tsv)" ||
    return 2
  IFS= read -r first_line < "${manifest}" || return 2
  [[ "${first_line}" == '# Guild Operators deployment source manifest, schema 2.' ]] ||
    return 2
  stage_root="$(mktemp -d "${TMPDIR:-/tmp}/guild-deploy-distribution.XXXXXX")" ||
    return 2
  DISPATCHER_TX_STAGE_ROOT="${stage_root}"
  chmod 0700 "${stage_root}" || return 2
  candidate_root="${stage_root}/candidates"
  plan="${stage_root}/plan.tsv"
  mkdir -- "${candidate_root}" || return 2
  chmod 0700 "${candidate_root}" || return 2
  : > "${plan}" || return 2
  chmod 0600 "${plan}" || return 2
  [[ "${S_ARGS:-}" == *s* ]] && force_scripts="Y"
  [[ "${S_ARGS:-}" == *f* ]] && force_config="Y"
  DISPATCHER_FORCE_SCRIPTS="${force_scripts}"
  DISPATCHER_FORCE_CONFIG="${force_config}"

  while IFS=$'\t' read -r implementation source_path target_path mode policy validator extra; do
    [[ -n "${implementation}" && "${implementation}" != \#* ]] || continue
    [[ -z "${extra}" ]] || return 2
    [[ -n "${source_path}" && -n "${target_path}" && -n "${mode}" &&
       -n "${policy}" && -n "${validator}" ]] || return 2
    case "${implementation}" in common|cnode|dingo|amaru) ;; *) return 2 ;; esac
    [[ "${implementation}" == "common" ||
       "${implementation}" == "${NODE_IMPLEMENTATION}" ]] || continue
    source_path="${source_path//\{implementation\}/${NODE_IMPLEMENTATION}}"
    source_path="${source_path//\{network\}/${NETWORK}}"
    target_path="${target_path//\{implementation\}/${NODE_IMPLEMENTATION}}"
    target_path="${target_path//\{network\}/${NETWORK}}"
    [[ "${source_path}" != *'{'* && "${target_path}" != *'{'* ]] || return 2
    dispatcher_distribution_relative_path_valid "${target_path}" || return 2
    [[ "${seen}" != *"|${target_path}|"* ]] || return 2
    seen="${seen}${target_path}|"
    case "${policy}" in
      exact|merge-header|render-cnode|render-dingo|render-amaru|preserve-render)
        [[ "${mode}" == "0644" || "${mode}" == "0640" ||
           "${mode}" == "0755" ]] || return 2
        case "${validator}" in shell|json|text) ;; *) return 2 ;; esac
        _guild_source_relative_path_valid "${source_path}" || return 2
        ;;
      cntools-generation)
        [[ "${source_path}" == \
             'scripts/common-helper-scripts/cntools/manifest.json' &&
           "${target_path}" == 'scripts/.cntools' &&
           "${mode}" == '0700' && "${validator}" == 'cntools' &&
           ( "${implementation}" == 'cnode' ||
             "${implementation}" == 'dingo' ) ]] || return 2
        _guild_source_relative_path_valid "${source_path}" || return 2
        source_file="$(guild_source_path "${source_path}")" || return 2
        dispatcher_cntools_generation_prepare "${source_file}" \
          "${source_path}" "${target_path}" || return 2
        record_count=$((record_count + 1))
        continue
        ;;
      cntools-legacy-bundle)
        [[ "${source_path}" == \
             'scripts/common-helper-scripts/cntools/manifest.json' &&
           "${target_path}" == 'scripts/cntools/libs/legacy' &&
           "${mode}" == '0700' && "${validator}" == 'cntools' &&
           ( "${implementation}" == 'cnode' ||
             "${implementation}" == 'dingo' ) ]] || return 2
        _guild_source_relative_path_valid "${source_path}" || return 2
        source_file="$(guild_source_path "${source_path}")" || return 2
        dispatcher_cntools_legacy_bundle_prepare "${source_file}" \
          "${source_path}" "${target_path}" || return 2
        record_count=$((record_count + 1))
        continue
        ;;
      retire)
        [[ "${source_path}" == "-" && "${mode}" == "-" &&
           "${validator}" == "-" ]] || return 2
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "${source_path}" "${target_path}" "${mode}" "${policy}" \
          "${policy}" "${validator}" "-" >> "${plan}" || return 2
        record_count=$((record_count + 1))
        continue
        ;;
      *) return 2 ;;
    esac

    source_file="$(guild_source_path "${source_path}")" || return 2
    source_hash="$(dispatcher_sha256 "${source_file}")" || return 2
    candidate="${candidate_root}/${target_path}"
    mkdir -p -- "$(dirname -- "${candidate}")" || return 2
    effective_policy="${policy}"
    case "${policy}" in
      exact)
        cp -- "${source_file}" "${candidate}" || return 2
        ;;
      merge-header)
        merge_header_override=""
        if [[ "${target_path}" == "scripts/guild-deploy.sh" &&
              ! -e "${NODE_HOME}/${target_path}" &&
              ! -L "${NODE_HOME}/${target_path}" ]]; then
          merge_header_override="${GUILD_SOURCE_LAUNCHER_HEADER:-}"
        fi
        dispatcher_distribution_merge_header "${source_file}" \
          "${NODE_HOME}/${target_path}" "${candidate}" \
          "${merge_header_override}" || return 2
        if [[ "${target_path}" == "scripts/env" ]]; then
          dispatcher_distribution_seed_cnode_port "${candidate}" || return 2
        fi
        ;;
      render-cnode)
        dispatcher_distribution_render_cnode "${source_file}" "${candidate}" ||
          return 2
        ;;
      render-dingo)
        dispatcher_distribution_render_dingo "${source_file}" "${candidate}" ||
          return 2
        ;;
      render-amaru)
        dispatcher_distribution_render_amaru "${source_file}" "${candidate}" ||
          return 2
        ;;
      preserve-render)
        if [[ -f "${NODE_HOME}/${target_path}" &&
              "${force_config}" != "Y" ]]; then
          dispatcher_distribution_preserve_existing "${target_path}" || return 2
          cp -- "${NODE_HOME}/${target_path}" "${candidate}" || return 2
          effective_policy="${DISPATCHER_PRESERVED_POLICY}"
          mode="${DISPATCHER_PRESERVED_MODE}"
        else
          case "${NODE_IMPLEMENTATION}" in
            cnode) dispatcher_distribution_render_cnode "${source_file}" "${candidate}" ;;
            dingo) dispatcher_distribution_render_dingo "${source_file}" "${candidate}" ;;
            amaru) dispatcher_distribution_render_amaru "${source_file}" "${candidate}" ;;
          esac || return 2
          effective_policy="render-${NODE_IMPLEMENTATION}"
        fi
        ;;
    esac
    [[ -s "${candidate}" && ! -L "${candidate}" ]] || return 2
    chmod "${mode}" "${candidate}" || return 2
    if [[ "${validator}" == "shell" ]]; then
      "${BASH}" -n "${candidate}" >/dev/null 2>&1 || return 2
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${source_path}" "${target_path}" "${mode}" "${policy}" \
      "${effective_policy}" "${validator}" "${source_hash}" >> "${plan}" ||
      return 2
    record_count=$((record_count + 1))
  done < "${manifest}"

  (( record_count > 0 )) || return 2
  first_plan_target="$(awk -F '\t' 'NR == 1 { print $2 }' "${plan}")" ||
    return 2
  case "${NODE_IMPLEMENTATION}" in
    cnode|dingo)
      [[ "${first_plan_target}" == "scripts/cntools.library" ]] || return 2
      ;;
    amaru) ;;
    *) return 2 ;;
  esac
  grep -Fq $'scripts/cnode-helper-scripts/guild-deploy.sh\tscripts/guild-deploy.sh\t' \
    "${plan}" || return 2
  case "${NODE_IMPLEMENTATION}" in
    cnode|dingo)
      [[ "${DISPATCHER_CNTOOLS_GENERATION_PREPARED:-N}" == "Y" &&
         "${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_PREPARED:-N}" == "Y" ]] ||
        return 2
      ;;
    amaru)
      [[ "${DISPATCHER_CNTOOLS_GENERATION_PREPARED:-N}" != "Y" &&
         "${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_PREPARED:-N}" != "Y" ]] ||
        return 2
      ;;
  esac
  DISPATCHER_TX_CANDIDATE_ROOT="${candidate_root}"
  DISPATCHER_TX_PLAN="${plan}"
  DISPATCHER_TX_PREPARED="Y"
  DISPATCHER_TX_ACTIVE="N"
  DISPATCHER_TX_ACTIVATED="N"
}

dispatcher_distribution_validate_candidates() {
  local source_path="" target_path="" mode="" policy=""
  local effective_policy="" validator="" source_hash="" candidate=""

  [[ "${DISPATCHER_TX_PREPARED:-N}" == "Y" &&
     -f "${DISPATCHER_TX_PLAN:-}" &&
     -d "${DISPATCHER_TX_CANDIDATE_ROOT:-}" ]] || return 2
  while IFS=$'\t' read -r source_path target_path mode policy effective_policy validator source_hash; do
    [[ "${policy}" != "retire" ]] || continue
    candidate="${DISPATCHER_TX_CANDIDATE_ROOT}/${target_path}"
    [[ -s "${candidate}" && -f "${candidate}" && ! -L "${candidate}" &&
       -n "$(find "${candidate}" -prune -perm "${mode}" -print 2>/dev/null)" ]] ||
      return 2
    case "${validator}" in
      shell) "${BASH}" -n "${candidate}" >/dev/null 2>&1 || return 2 ;;
      json)
        command -v jq >/dev/null 2>&1 || return 2
        jq -e . "${candidate}" >/dev/null 2>&1 || return 2
        ;;
      text) : ;;
      *) return 2 ;;
    esac
    case "${effective_policy}" in
      render-cnode|render-dingo|render-amaru)
        if grep -q '@\(NODE_HOME\|NODE_SERVICE\|BINARY_PATH\|NODE_PORT\)@' \
          "${candidate}" 2>/dev/null; then
          return 2
        fi
        ;;
    esac
  done < "${DISPATCHER_TX_PLAN}"

  case "${NODE_IMPLEMENTATION}" in
    cnode|dingo)
      dispatcher_cntools_legacy_bundle_validate_tree \
        "${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_STAGE}" \
        "${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_MANIFEST}" || return 2
      dispatcher_cntools_generation_validate_staged || return 2
      dispatcher_cntools_generation_validate_prior_installed || return 2
      ;;
    amaru)
      [[ "${DISPATCHER_CNTOOLS_GENERATION_PREPARED:-N}" != "Y" &&
         "${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_PREPARED:-N}" != "Y" ]] ||
        return 2
      ;;
  esac

  case "${NODE_IMPLEMENTATION}" in
    cnode)
      declare -F cnode_deploy_validate_release_metadata >/dev/null 2>&1 &&
        cnode_deploy_validate_release_metadata \
          "${DISPATCHER_TX_CANDIDATE_ROOT}/files/cnode-release.json" || return 2
      ;;
    dingo)
      declare -F dingo_deploy_validate_release_metadata >/dev/null 2>&1 &&
        dingo_deploy_validate_release_metadata \
          "${DISPATCHER_TX_CANDIDATE_ROOT}/files/dingo-release.json" || return 2
      ;;
    amaru)
      declare -F amaru_deploy_validate_release_metadata >/dev/null 2>&1 &&
        amaru_deploy_validate_release_metadata \
          "${DISPATCHER_TX_CANDIDATE_ROOT}/files/amaru-release.json" || return 2
      ;;
  esac
}

dispatcher_transaction_relative_path_valid() {
  dispatcher_distribution_relative_path_valid "${1:-}" ||
    [[ "${1:-}" == ".deployment.json" ||
       "${1:-}" == ".guild-source-receipt.json" ]]
}

dispatcher_transaction_path_has_symlink() {
  local relative_path="$1"
  local component="" current="${NODE_HOME}"
  local -a components

  [[ -d "${NODE_HOME}" && ! -L "${NODE_HOME}" ]] || return 0
  IFS='/' read -r -a components <<< "${relative_path}"
  for component in "${components[@]}"; do
    current="${current}/${component}"
    [[ ! -L "${current}" ]] || return 0
    [[ -e "${current}" ]] || return 1
  done
  return 1
}

# Deterministic transaction failures are available only to the Stage 0C
# contract test. A failpoint name alone is deliberately inert: activation also
# requires the exact test mode, a private context beside TMPDIR, and context
# records bound to this local-source invocation. This keeps the hooks useful for
# crash/rollback coverage without exposing a plausible production switch.
dispatcher_test_failpoint() {
  local reached="${1:-}"
  local configured="${GUILD_DEPLOY_TEST_FAILPOINT:-}"
  local action="${GUILD_DEPLOY_TEST_ACTION:-return}"
  local context="${GUILD_DEPLOY_TEST_CONTEXT:-}"
  local context_dir="" context_name="" context_mode="" context_dir_mode=""
  local canonical_tmp="" marker="" target_record="" source_record="" extra=""
  local ready_file="" release_file="" deadline=0 release_mode=""

  [[ -n "${configured}" ]] || return 0
  [[ "${GUILD_DEPLOY_TEST_MODE:-}" == "stage0c-transaction-failure-injection-v1" ]] ||
    return 0
  case "${configured}" in
    before-durable-journal|after-durable-journal|after-cntools-generation-rename|after-cntools-generation-publish|after-cntools-legacy-bundle-rename|after-cntools-legacy-bundle-publish|after-retire-archive|after-history-archive|after-obsolete-remove|before-receipt-publish|after-receipt-publish|before-metadata-publish|after-metadata-publish|after-transaction-quarantine) ;;
    *) [[ "${configured}" =~ ^after-payload:[1-9][0-9]*$ ]] || return 2 ;;
  esac
  [[ "${reached}" == "${configured}" ]] || return 0
  case "${action}" in
    return|enospc|crash|pause|HUP|INT|TERM) ;;
    *) return 2 ;;
  esac

  [[ -n "${TMPDIR:-}" && "${context}" == /* &&
     -f "${context}" && ! -L "${context}" && -O "${context}" ]] || return 2
  context_dir="$(cd -P -- "$(dirname -- "${context}")" 2>/dev/null && pwd -P)" ||
    return 2
  context_name="$(basename -- "${context}")"
  canonical_tmp="$(cd -P -- "${TMPDIR}" 2>/dev/null && pwd -P)" || return 2
  [[ "${context}" == "${context_dir}/${context_name}" &&
     "${context_name}" == "guild-deploy-failure.context" &&
     "${canonical_tmp}" == "${context_dir}/tmp" ]] || return 2
  context_mode="$(dispatcher_file_mode "${context}")" || return 2
  context_dir_mode="$(find "${context_dir}" -prune -printf '%m' 2>/dev/null || true)"
  if [[ -z "${context_dir_mode}" ]]; then
    context_dir_mode="$(stat -f '%Lp' "${context_dir}" 2>/dev/null || true)"
  fi
  [[ "${context_mode}" == "0600" &&
     ( "${context_dir_mode}" == "700" ||
       "${context_dir_mode}" == "0700" ) &&
     -d "${context_dir}" && ! -L "${context_dir}" &&
     -O "${context_dir}" ]] || return 2
  {
    IFS= read -r marker &&
      IFS= read -r target_record &&
      IFS= read -r source_record &&
      ! IFS= read -r extra
  } < "${context}" || return 2
  [[ "${marker}" == "guild-deploy-stage0c-transaction-context-v1" &&
     "${target_record}" == "target=${NODE_HOME}" &&
     "${source_record}" == "source=${GUILD_SOURCE_CHECKOUT:-}" &&
     "${_GUILD_SOURCE_MODE:-}" == "local" &&
     "${GUILD_SOURCE_ALLOW_DIRTY:-N}" == "Y" ]] || return 2

  log_warn "TEST ONLY: injecting '${action}' at transaction failpoint '${reached}'."
  case "${action}" in
    return) return 97 ;;
    enospc)
      log_warn "TEST ONLY: simulated write failure: No space left on device (ENOSPC)."
      return 28
      ;;
    crash)
      kill -s KILL "${BASHPID}"
      return 137
      ;;
    pause)
      ready_file="${context_dir}/guild-deploy-failure.ready"
      release_file="${context_dir}/guild-deploy-failure.release"
      [[ ! -e "${ready_file}" && ! -L "${ready_file}" &&
         ! -e "${release_file}" && ! -L "${release_file}" ]] || return 2
      printf 'failpoint=%s\npid=%s\n' "${reached}" "${BASHPID}" \
        > "${ready_file}" || return 2
      chmod 0600 "${ready_file}" || return 2
      deadline=$((SECONDS + 60))
      while (( SECONDS < deadline )); do
        if [[ -e "${release_file}" || -L "${release_file}" ]]; then
          [[ -f "${release_file}" && ! -L "${release_file}" &&
             -O "${release_file}" ]] || return 2
          release_mode="$(dispatcher_file_mode "${release_file}")" || return 2
          [[ "${release_mode}" == "0600" ]] || return 2
          rm -f -- "${ready_file}" "${release_file}" || return 2
          return 0
        fi
        sleep 0.1
      done
      rm -f -- "${ready_file}" 2>/dev/null || true
      return 124
      ;;
    HUP|INT|TERM)
      kill -s "${action}" "${BASHPID}"
      return 128
      ;;
  esac
}

dispatcher_transaction_cleanup_root_remove() {
  local root="${1:-}" directory="" cleanup_name=""

  dispatcher_target_lock_is_owned "${NODE_HOME}" || return 2
  [[ "${root}" == "${NODE_HOME}"/* ]] || return 2
  cleanup_name="${root#"${NODE_HOME}"/}"
  [[ "${cleanup_name}" =~ ^\.guild-deploy-transaction\.(prepare|cleanup)\.[0-9]{1,20}\.[0-9]{1,20}\.[0-9]{1,5}$ &&
     "${root}" == "${NODE_HOME}/${cleanup_name}" && -d "${root}" &&
     ! -L "${root}" && -O "${root}" ]] || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${root}" || return 2
  # Only directories need write/search permission for unlinking. Never chmod
  # immutable files (or hard links) during cleanup; a crash can safely retry
  # this strictly named, non-authoritative quarantine from any directory-mode
  # prefix already normalized by an earlier attempt.
  while IFS= read -r -d '' directory; do
    [[ "${directory}" == "${root}" || "${directory}" == "${root}"/* ]] ||
      return 2
    [[ -d "${directory}" && ! -L "${directory}" && -O "${directory}" ]] ||
      return 2
    chmod 0700 "${directory}" || return 2
  done < <(find "${root}" -depth -type d -print0)
  rm -rf -- "${root}" || return 2
  [[ ! -e "${root}" && ! -L "${root}" ]]
}

dispatcher_transaction_remove_root() {
  local root="${1:-}" cleanup_id="" cleanup_root="" attempt=0
  local canonical="${NODE_HOME}/.guild-deploy-transaction"

  dispatcher_target_lock_is_owned "${NODE_HOME}" || return 2
  if [[ "${root}" == "${canonical}" ]]; then
    [[ -d "${root}" && ! -L "${root}" && -O "${root}" ]] || return 2
    dispatcher_cntools_absolute_path_has_no_symlinks "${root}" || return 2
    # Retire the authoritative journal atomically before relaxing or deleting
    # any byte. Once this rename succeeds, CNTools readers may proceed and a
    # future dispatcher can finish deleting the non-authoritative quarantine.
    while (( attempt < 10 )); do
      cleanup_id="$(date +%s).${BASHPID}.${RANDOM}"
      cleanup_root="${NODE_HOME}/.guild-deploy-transaction.cleanup.${cleanup_id}"
      if [[ ! -e "${cleanup_root}" && ! -L "${cleanup_root}" ]]; then
        break
      fi
      cleanup_root=""
      attempt=$((attempt + 1))
    done
    [[ -n "${cleanup_root}" ]] || return 2
    mv -- "${root}" "${cleanup_root}" || return 2
    dispatcher_test_failpoint after-transaction-quarantine || return $?
    dispatcher_transaction_cleanup_root_remove "${cleanup_root}"
    return $?
  fi
  dispatcher_transaction_cleanup_root_remove "${root}"
}

dispatcher_transaction_control_file_valid() {
  local file="${1:-}" expected_mode="${2:-}" allow_empty="${3:-N}"
  local bytes="" actual_mode=""

  [[ "${file}" == "${NODE_HOME}/.guild-deploy-transaction"/* &&
     -f "${file}" && ! -L "${file}" && -O "${file}" ]] || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${file}" || return 2
  actual_mode="$(dispatcher_file_mode "${file}")" || return 2
  [[ "${actual_mode}" == "${expected_mode}" ]] || return 2
  bytes="$(wc -c < "${file}" 2>/dev/null)" || return 2
  bytes="${bytes//[[:space:]]/}"
  [[ "${bytes}" =~ ^(0|[1-9][0-9]*)$ && "${bytes}" -le 1048576 ]] ||
    return 2
  [[ "${allow_empty}" == "Y" || "${bytes}" != "0" ]] || return 2
  if (( bytes > 0 )); then
    # Bash variables cannot represent NUL bytes. Reject them before parsing,
    # and require a final LF so every durable row is visited by read.
    if LC_ALL=C od -An -v -t u1 "${file}" 2>/dev/null |
        grep -Eq '(^|[[:space:]])0([[:space:]]|$)'; then
      return 2
    fi
    [[ -z "$(tail -c 1 -- "${file}")" ]] || return 2
  fi
}

dispatcher_transaction_journal_record() {
  local root="${1:-}"
  local journal="${root}/journal"
  local schema_line="" transaction_line="" state_line="" extra=""
  local transaction_id="" state=""

  dispatcher_transaction_control_file_valid "${journal}" 0600 N || return 2
  {
    IFS= read -r schema_line &&
      IFS= read -r transaction_line &&
      IFS= read -r state_line &&
      ! IFS= read -r extra
  } < "${journal}" || return 2
  [[ "${schema_line}" == "schemaVersion=1" &&
     "${transaction_line}" == transactionId=* &&
     "${state_line}" == state=* ]] || return 2
  transaction_id="${transaction_line#transactionId=}"
  state="${state_line#state=}"
  case "${state}" in
    prepared|activated)
      [[ "${transaction_id}" =~ ^[0-9]{1,20}\.[0-9]{1,20}\.[0-9]{1,5}$ ]] ||
        return 2
      ;;
    committed)
      [[ "${transaction_id}" =~ ^[0-9a-f]{24}$ ]] || return 2
      ;;
    *) return 2 ;;
  esac
  # Byte-for-byte equality rejects appended, torn, CRLF, and hidden-byte
  # journals even when their first three parsed lines look plausible.
  printf 'schemaVersion=1\ntransactionId=%s\nstate=%s\n' \
    "${transaction_id}" "${state}" | cmp -s - "${journal}" || return 2
  printf '%s\t%s\n' "${state}" "${transaction_id}"
}

dispatcher_transaction_handoff_admission_token() {
  local root="${NODE_HOME}/.guild-deploy-transaction"
  local journal_record="" state="" transaction_id="" extra="" digest=""

  [[ -d "${root}" && ! -L "${root}" && -O "${root}" &&
     "$(dispatcher_path_mode "${root}")" == "0700" ]] || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${root}" || return 2
  journal_record="$(dispatcher_transaction_journal_record "${root}")" || return 2
  IFS=$'\t' read -r state transaction_id extra <<< "${journal_record}"
  [[ -z "${extra}" ]] || return 2
  digest="$(dispatcher_sha256 "${root}/journal")" || return 2
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 2
  # State and transaction ID make the token human-auditable; the digest binds
  # the exact byte-validated journal across the source-preparation exec.
  printf '%s:%s:%s\n' "${state}" "${transaction_id}" "${digest}"
}

dispatcher_transaction_handoff_admission_valid() {
  dispatcher_transaction_handoff_admission_token >/dev/null
}

dispatcher_transaction_handoff_revalidate() {
  local root="${NODE_HOME}/.guild-deploy-transaction"
  local admitted="${GUILD_SOURCE_TARGET_JOURNAL_ADMITTED:-N}"
  local expected_token="${GUILD_SOURCE_TARGET_JOURNAL_TOKEN:-}"
  local current_token=""

  dispatcher_target_lock_is_owned "${NODE_HOME}" || return 2
  DISPATCHER_HANDOFF_JOURNAL_REFRESH_AUTHORIZED="N"
  case "${admitted}" in
    N)
      [[ -z "${expected_token}" && ! -e "${root}" && ! -L "${root}" ]] ||
        return 2
      ;;
    Y)
      [[ -n "${expected_token}" ]] || return 2
      if [[ ! -e "${root}" && ! -L "${root}" ]]; then
        # A peer may have completed recovery before this process obtained the
        # lock. The metadata fingerprint, not stale journal authority, decides
        # whether the handoff may continue.
        GUILD_SOURCE_TARGET_JOURNAL_ADMITTED="N"
        GUILD_SOURCE_TARGET_JOURNAL_TOKEN=""
        return 0
      fi
      current_token="$(dispatcher_transaction_handoff_admission_token)" ||
        return 2
      [[ "${current_token}" == "${expected_token}" ]] || return 2
      DISPATCHER_HANDOFF_JOURNAL_REFRESH_AUTHORIZED="Y"
      ;;
    *) return 2 ;;
  esac
}

dispatcher_transaction_target_parent_safe() {
  local target="${1:-}" parent="" relative_parent="" component=""
  local current="${NODE_HOME}"
  local -a components=()

  [[ "${target}" == "${NODE_HOME}"/* && -d "${NODE_HOME}" &&
     ! -L "${NODE_HOME}" && -O "${NODE_HOME}" ]] || return 2
  parent="$(dirname -- "${target}")" || return 2
  [[ "${parent}" == "${NODE_HOME}" || "${parent}" == "${NODE_HOME}"/* ]] ||
    return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${parent}" || return 2
  [[ -d "${parent}" && ! -L "${parent}" && -O "${parent}" ]] || return 2
  [[ "${parent}" != "${NODE_HOME}" ]] || return 0
  relative_parent="${parent#"${NODE_HOME}"/}"
  IFS='/' read -r -a components <<< "${relative_parent}"
  for component in "${components[@]}"; do
    [[ -n "${component}" && "${component}" != "." &&
       "${component}" != ".." ]] || return 2
    current="${current}/${component}"
    [[ -d "${current}" && ! -L "${current}" && -O "${current}" ]] ||
      return 2
  done
  [[ "${current}" == "${parent}" ]]
}

# Validate an immutable generation without changing a transient 0755 root left
# by a crash between rename and mode restoration. The trusted lifecycle still
# validates every descendant byte, mode, directory, and content-addressed ID;
# only the already-inspected generation root is presented as its final 0555
# mode inside this subshell.
dispatcher_cntools_generation_rollback_tree_preflight() (
  local generation="${1:-}" expected_id="${2:-}" actual_mode=""

  [[ "${expected_id}" =~ ^[0-9a-f]{64}$ &&
     -d "${generation}" && ! -L "${generation}" && -O "${generation}" ]] ||
    return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${generation}" || return 2
  actual_mode="$(dispatcher_path_mode "${generation}")" || return 2
  case "${actual_mode}" in
    0555) ;;
    0755)
      _cntools_generation_file_mode() {
        if [[ "${1:-}" == "${generation}" ]]; then
          printf '0555\n'
        else
          dispatcher_path_mode "${1:-}"
        fi
      }
      ;;
    *) return 2 ;;
  esac
  cntools_generation_validate "${generation}" "${expected_id}"
)

dispatcher_cntools_generation_rollback_preflight() {
  local root="${1:-}"
  local record="${root}/cntools-generation.tsv"
  local validator="${root}/cntools-generation-validator.sh"
  local id="" relative="" root_existed=""
  local generations_existed="" target_existed="" lifecycle_sha=""
  local target="" staged="" cntools_root="${NODE_HOME}/scripts/.cntools"
  local generations="${NODE_HOME}/scripts/.cntools/generations"
  local durable_parent="${root}/cntools-generation" path="" mode=""
  local receipt_lifecycle_sha="" target_present="N" staged_present="N"
  local inventory_count=0

  dispatcher_transaction_control_file_valid "${record}" 0600 N || return 2
  dispatcher_transaction_control_file_valid "${validator}" 0400 N || return 2
  dispatcher_cntools_generation_record_parse "${record}" || return 2
  id="${DISPATCHER_CNTOOLS_RECORD_ID}"
  relative="${DISPATCHER_CNTOOLS_RECORD_RELATIVE}"
  root_existed="${DISPATCHER_CNTOOLS_RECORD_ROOT_EXISTED}"
  generations_existed="${DISPATCHER_CNTOOLS_RECORD_GENERATIONS_EXISTED}"
  target_existed="${DISPATCHER_CNTOOLS_RECORD_TARGET_EXISTED}"
  lifecycle_sha="${DISPATCHER_CNTOOLS_RECORD_LIFECYCLE_SHA256}"
  [[ "$(dispatcher_sha256 "${validator}")" == "${lifecycle_sha}" ]] || return 2
  "${BASH}" -n "${validator}" >/dev/null 2>&1 || return 2
  declare -F cntools_generation_validate >/dev/null 2>&1 || return 2
  target="${NODE_HOME}/${relative}"
  staged="${durable_parent}/${id}"
  for path in "${cntools_root}" "${generations}" "${target}" \
    "${durable_parent}" "${staged}"; do
    dispatcher_cntools_absolute_path_has_no_symlinks "${path}" || return 2
  done
  [[ -d "${durable_parent}" && ! -L "${durable_parent}" &&
     -O "${durable_parent}" &&
     "$(dispatcher_path_mode "${durable_parent}")" == "0700" ]] || return 2

  if [[ -e "${target}" || -L "${target}" ]]; then
    [[ -d "${target}" && ! -L "${target}" && -O "${target}" ]] || return 2
    target_present="Y"
  fi
  if [[ -e "${staged}" || -L "${staged}" ]]; then
    [[ -d "${staged}" && ! -L "${staged}" && -O "${staged}" ]] || return 2
    staged_present="Y"
  fi
  case "${target_existed}:${target_present}:${staged_present}" in
    Y:Y:Y|Y:Y:N|N:Y:N|N:N:Y|N:N:N) ;;
    *) return 2 ;;
  esac
  for path in "${target}" "${staged}"; do
    [[ -e "${path}" || -L "${path}" ]] || continue
    dispatcher_cntools_generation_rollback_tree_preflight \
      "${path}" "${id}" || return 2
    receipt_lifecycle_sha="$(jq -er '
      [.files[] | select(
        .path == "cntools/core/lifecycle.sh" and
        .source == "scripts/common-helper-scripts/cntools/core/lifecycle.sh" and
        .mode == "0444" and .validator == "shell")] |
      if length == 1 then .[0].sha256 else error("lifecycle record") end
    ' "${path}/.generation.json")" || return 2
    [[ "${receipt_lifecycle_sha}" == "${lifecycle_sha}" ]] || return 2
  done
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    inventory_count=$((inventory_count + 1))
    [[ "${path}" == "${staged}" ]] || return 2
  done < <(find "${durable_parent}" -mindepth 1 -maxdepth 1 -print)
  case "${staged_present}:${inventory_count}" in
    Y:1|N:0) ;;
    *) return 2 ;;
  esac

  case "${root_existed}" in
    Y)
      [[ -d "${cntools_root}" && ! -L "${cntools_root}" &&
         -O "${cntools_root}" &&
         "$(dispatcher_path_mode "${cntools_root}")" == "0700" ]] || return 2
      ;;
    N)
      if [[ -e "${cntools_root}" || -L "${cntools_root}" ]]; then
        [[ -d "${cntools_root}" && ! -L "${cntools_root}" &&
           -O "${cntools_root}" &&
           "$(dispatcher_path_mode "${cntools_root}")" == "0700" ]] ||
          return 2
      fi
      ;;
    *) return 2 ;;
  esac
  case "${generations_existed}" in
    Y)
      [[ -d "${generations}" && ! -L "${generations}" &&
         -O "${generations}" &&
         "$(dispatcher_path_mode "${generations}")" == "0700" ]] || return 2
      ;;
    N)
      if [[ -e "${generations}" || -L "${generations}" ]]; then
        [[ -d "${generations}" && ! -L "${generations}" &&
           -O "${generations}" &&
           "$(dispatcher_path_mode "${generations}")" == "0700" ]] ||
          return 2
      fi
      ;;
    *) return 2 ;;
  esac
}

dispatcher_cntools_generation_rollback_schema_pair() {
  local root="${1:-}" expected_manifest_schema="${2:-}"
  local expected_manifest_count="${3:-}" expected_receipt_schema="${4:-}"
  local expected_receipt_count="${5:-}" record="${root}/cntools-generation.tsv"
  local allow_retracted="${6:-N}"
  local expected_pair="" expected_shape="" id="" relative="" path=""
  local inspected=0

  expected_pair="${expected_manifest_schema}:${expected_manifest_count}:"
  expected_pair+="${expected_receipt_schema}:${expected_receipt_count}"
  case "${expected_pair}" in
    1:19:1:20|2:29:2:30) expected_shape="legacy" ;;
    3:151:3:152) expected_shape="stage3" ;;
    *) return 2 ;;
  esac
  case "${allow_retracted}" in Y|N) ;; *) return 2 ;; esac
  dispatcher_cntools_generation_record_parse "${record}" || return 2
  [[ "${DISPATCHER_CNTOOLS_RECORD_SHAPE}" == "${expected_shape}" ]] ||
    return 2
  id="${DISPATCHER_CNTOOLS_RECORD_ID}"
  relative="${DISPATCHER_CNTOOLS_RECORD_RELATIVE}"
  for path in "${NODE_HOME}/${relative}" \
    "${root}/cntools-generation/${id}"; do
    [[ -e "${path}" || -L "${path}" ]] || continue
    jq -e --argjson manifest_schema "${expected_manifest_schema}" \
      --argjson manifest_count "${expected_manifest_count}" '
        type == "object" and .schemaVersion == $manifest_schema and
        (.files | type == "array" and length == $manifest_count)
      ' "${path}/cntools/manifest.json" >/dev/null 2>&1 || return 2
    jq -e --argjson receipt_schema "${expected_receipt_schema}" \
      --argjson receipt_count "${expected_receipt_count}" '
        type == "object" and .schemaVersion == $receipt_schema and
        (.files | type == "array" and length == $receipt_count)
      ' "${path}/.generation.json" >/dev/null 2>&1 || return 2
    inspected=$((inspected + 1))
  done
  if (( inspected == 0 )); then
    # Paired Stage 2 records remain distinguishable by their exact legacy
    # six-field shape; Stage 3 records carry the exact appended schema/count
    # discriminator. A lone Stage 1 record has no independent discriminator
    # and remains fail-closed when its tree is absent.
    [[ "${allow_retracted}" == "Y" ]] || return 2
  fi
}

dispatcher_cntools_legacy_bundle_rollback_preflight() {
  local root="${1:-}"
  local record="${root}/cntools-legacy-bundle.tsv"
  local data_manifest="${root}/cntools-legacy-bundle-manifest.json"
  local durable_parent="${root}/cntools-legacy-bundle"
  local line="" tabs="" id="" relative="" cntools_existed=""
  local libs_existed="" legacy_existed="" target_existed=""
  local data_manifest_sha="" extra="" actual_manifest_sha=""
  local cntools="${NODE_HOME}/scripts/cntools" libs="" legacy=""
  local target="" staged="" path="" target_present="N" staged_present="N"
  local inventory_count=0

  libs="${cntools}/libs"
  legacy="${libs}/legacy"
  dispatcher_transaction_control_file_valid "${record}" 0600 N || return 2
  dispatcher_transaction_control_file_valid "${data_manifest}" 0400 N || return 2
  IFS= read -r line < "${record}" || return 2
  tabs="${line//[^$'\t']/}"
  [[ "${#tabs}" -eq 6 ]] || return 2
  IFS=$'\t' read -r id relative cntools_existed libs_existed \
    legacy_existed target_existed data_manifest_sha extra <<< "${line}"
  [[ -z "${extra}" && "${id}" =~ ^[0-9a-f]{64}$ &&
     "${relative}" == "scripts/cntools/libs/legacy/${id}" &&
     "${data_manifest_sha}" =~ ^[0-9a-f]{64}$ ]] || return 2
  case "${cntools_existed}:${libs_existed}:${legacy_existed}:${target_existed}" in
    Y:Y:Y:Y|Y:Y:Y:N|Y:Y:N:N|Y:N:N:N|N:N:N:N) ;;
    *) return 2 ;;
  esac
  actual_manifest_sha="$(dispatcher_sha256 "${data_manifest}")" || return 2
  [[ "${actual_manifest_sha}" == "${data_manifest_sha}" &&
     "$(jq -er '.legacyBundle.id' "${data_manifest}")" == "${id}" ]] ||
    return 2
  dispatcher_cntools_legacy_bundle_data_manifest_valid "${data_manifest}" ||
    return 2
  target="${NODE_HOME}/${relative}"
  staged="${durable_parent}/${id}"
  for path in "${cntools}" "${libs}" "${legacy}" "${target}" \
    "${durable_parent}" "${staged}"; do
    dispatcher_cntools_absolute_path_has_no_symlinks "${path}" || return 2
  done
  [[ -d "${durable_parent}" && ! -L "${durable_parent}" &&
     -O "${durable_parent}" &&
     "$(dispatcher_path_mode "${durable_parent}")" == "0700" ]] || return 2
  if [[ -e "${target}" || -L "${target}" ]]; then
    [[ -d "${target}" && ! -L "${target}" && -O "${target}" ]] || return 2
    target_present="Y"
  fi
  if [[ -e "${staged}" || -L "${staged}" ]]; then
    [[ -d "${staged}" && ! -L "${staged}" && -O "${staged}" ]] || return 2
    staged_present="Y"
  fi
  case "${target_existed}:${target_present}:${staged_present}" in
    Y:Y:Y|Y:Y:N|N:Y:N|N:N:Y|N:N:N) ;;
    *) return 2 ;;
  esac
  for path in "${target}" "${staged}"; do
    [[ -e "${path}" || -L "${path}" ]] || continue
    dispatcher_cntools_legacy_bundle_validate_tree \
      "${path}" "${data_manifest}" durable rollback-transient || return 2
  done
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    inventory_count=$((inventory_count + 1))
    [[ "${path}" == "${staged}" ]] || return 2
  done < <(find "${durable_parent}" -mindepth 1 -maxdepth 1 -print)
  case "${staged_present}:${inventory_count}" in
    Y:1|N:0) ;;
    *) return 2 ;;
  esac
  dispatcher_cntools_legacy_bundle_matches_transaction_generation \
    "${root}" "${data_manifest}" || return 2

  for path in "${cntools}" "${libs}" "${legacy}"; do
    case "${path}" in
      "${cntools}") extra="${cntools_existed}" ;;
      "${libs}") extra="${libs_existed}" ;;
      "${legacy}") extra="${legacy_existed}" ;;
    esac
    case "${extra}" in
      Y) dispatcher_cntools_legacy_bundle_parent_safe "${path}" || return 2 ;;
      N)
        if [[ -e "${path}" || -L "${path}" ]]; then
          [[ -d "${path}" && ! -L "${path}" && -O "${path}" &&
             "$(dispatcher_path_mode "${path}")" == "0700" ]] || return 2
        fi
        ;;
      *) return 2 ;;
    esac
  done
}

dispatcher_transaction_special_rollback_preflight() {
  local root="${1:-}" generation_present="N" bundle_present="N"
  local auxiliary="" generation_shape="" manifest_schema=""
  local manifest_count="" receipt_schema="" receipt_count=""

  [[ ! -e "${root}/cntools-generation.tsv" &&
     ! -L "${root}/cntools-generation.tsv" ]] || generation_present="Y"
  [[ ! -e "${root}/cntools-legacy-bundle.tsv" &&
     ! -L "${root}/cntools-legacy-bundle.tsv" ]] || bundle_present="Y"
  case "${generation_present}:${bundle_present}" in
    Y:Y)
      dispatcher_cntools_generation_record_parse \
        "${root}/cntools-generation.tsv" || return 2
      generation_shape="${DISPATCHER_CNTOOLS_RECORD_SHAPE}"
      case "${generation_shape}" in
        legacy)
          manifest_schema=2
          manifest_count=29
          receipt_schema=2
          receipt_count=30
          ;;
        stage3)
          manifest_schema=3
          manifest_count=151
          receipt_schema=3
          receipt_count=152
          ;;
        *) return 2 ;;
      esac
      # Never trust a caller/imported function with this public name. Source
      # the lifecycle unconditionally from the authenticated Guild snapshot
      # before it is allowed to inspect transaction-controlled paths.
      dispatcher_cntools_source_snapshot_lifecycle || return 2
      dispatcher_cntools_generation_rollback_preflight "${root}" || return 2
      dispatcher_cntools_generation_rollback_schema_pair \
        "${root}" "${manifest_schema}" "${manifest_count}" \
        "${receipt_schema}" "${receipt_count}" Y || return 2
      dispatcher_cntools_legacy_bundle_rollback_preflight "${root}" || return 2
      printf 'modular\n'
      ;;
    Y:N)
      # Stage 1 transactions predate the content-addressed legacy bundle but
      # already contain the generic 19/20-file generation contract. The Stage
      # 2 lifecycle is intentionally able to validate and roll back that
      # exact generation-only durable shape without executing candidate code.
      for auxiliary in cntools-legacy-bundle \
        cntools-legacy-bundle-manifest.json; do
        [[ ! -e "${root}/${auxiliary}" && ! -L "${root}/${auxiliary}" ]] ||
          return 2
      done
      dispatcher_cntools_generation_record_parse \
        "${root}/cntools-generation.tsv" || return 2
      [[ "${DISPATCHER_CNTOOLS_RECORD_SHAPE}" == "legacy" ]] || return 2
      dispatcher_cntools_source_snapshot_lifecycle || return 2
      dispatcher_cntools_generation_rollback_preflight "${root}" || return 2
      dispatcher_cntools_generation_rollback_schema_pair \
        "${root}" 1 19 1 20 || return 2
      printf 'generation-only\n'
      ;;
    N:N)
      for auxiliary in cntools-generation cntools-generation-validator.sh \
        cntools-legacy-bundle cntools-legacy-bundle-manifest.json; do
        [[ ! -e "${root}/${auxiliary}" && ! -L "${root}/${auxiliary}" ]] ||
          return 2
      done
      printf 'plain\n'
      ;;
    *) return 2 ;;
  esac
}

dispatcher_transaction_rollback_control_preflight() {
  local root="${1:-}"
  local baseline="${root}/baseline.tsv"
  local activation="${root}/activation.tsv"
  local targets_file="${root}/targets.tsv"
  local journal_record="" journal_state="" transaction_id=""
  local line="" tabs="" relative_path="" existed_state="" mode=""
  local backup_name="" extra="" target="" backup="" actual_mode=""
  local normalized_mode="" commit_tmp="" commit_name="" commit_parent=""
  local expected_parent="" facade_count=0 baseline_count=0 target_count=0
  local activation_count=0 backup_count=0 inventory_backup_count=0
  local transaction_shape="" transaction_pid="" inventory_backup_name=""
  local inventory_backup_index=""
  local first_baseline_path=""
  local -A baseline_paths=() target_paths=() activation_paths=()

  [[ "${root}" == "${NODE_HOME}/.guild-deploy-transaction" &&
     -d "${root}" && ! -L "${root}" && -O "${root}" &&
     "$(dispatcher_path_mode "${root}")" == "0700" ]] || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${root}" || return 2
  journal_record="$(dispatcher_transaction_journal_record "${root}")" ||
    return 2
  IFS=$'\t' read -r journal_state transaction_id extra <<< "${journal_record}"
  [[ -z "${extra}" &&
     ( "${journal_state}" == "prepared" ||
       "${journal_state}" == "activated" ) ]] || return 2
  dispatcher_transaction_control_file_valid "${baseline}" 0600 N || return 2
  dispatcher_transaction_control_file_valid "${activation}" 0600 Y || return 2
  dispatcher_transaction_control_file_valid "${targets_file}" 0600 N || return 2
  transaction_shape="$(dispatcher_transaction_special_rollback_preflight \
    "${root}")" || return 2
  transaction_pid="${transaction_id#*.}"
  transaction_pid="${transaction_pid%%.*}"
  [[ "${transaction_pid}" =~ ^[0-9]{1,20}$ ]] || return 2

  while IFS= read -r line; do
    tabs="${line//[^$'\t']/}"
    [[ "${#tabs}" -eq 3 ]] || return 2
    IFS=$'\t' read -r relative_path existed_state mode backup_name extra \
      <<< "${line}"
    [[ -z "${extra}" ]] || return 2
    dispatcher_transaction_relative_path_valid "${relative_path}" || return 2
    [[ -z "${baseline_paths[${relative_path}]+set}" ]] || return 2
    baseline_paths["${relative_path}"]=1
    [[ -n "${first_baseline_path}" ]] || first_baseline_path="${relative_path}"
    target="${NODE_HOME}/${relative_path}"
    dispatcher_cntools_absolute_path_has_no_symlinks "${target}" || return 2
    case "${existed_state}" in
      Y)
        [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 2
        backup_count=$((backup_count + 1))
        [[ "${backup_name}" == "backup.${backup_count}" ]] || return 2
        backup="${root}/${backup_name}"
        [[ -f "${backup}" && ! -L "${backup}" && -O "${backup}" ]] ||
          return 2
        dispatcher_cntools_absolute_path_has_no_symlinks "${backup}" || return 2
        actual_mode="$(dispatcher_file_mode "${backup}")" || return 2
        normalized_mode="${mode}"
        [[ "${#normalized_mode}" -eq 4 ]] || normalized_mode="0${normalized_mode}"
        [[ "${actual_mode}" == "${normalized_mode}" ]] || return 2
        dispatcher_transaction_target_parent_safe "${target}" || return 2
        ;;
      N)
        [[ "${mode}" == "-" && "${backup_name}" == "-" ]] || return 2
        ;;
      *) return 2 ;;
    esac
    if [[ -e "${target}" || -L "${target}" ]]; then
      [[ -f "${target}" && ! -L "${target}" && -O "${target}" ]] ||
        return 2
    fi
    [[ "${relative_path}" == "scripts/cntools.library" ]] &&
      facade_count=$((facade_count + 1))
    baseline_count=$((baseline_count + 1))
  done < "${baseline}"
  (( baseline_count > 0 )) || return 2

  while IFS= read -r line; do
    [[ "${line}" != *$'\t'* ]] || return 2
    relative_path="${line}"
    dispatcher_transaction_relative_path_valid "${relative_path}" || return 2
    [[ -z "${target_paths[${relative_path}]+set}" ]] || return 2
    target_paths["${relative_path}"]=1
    [[ -n "${baseline_paths[${relative_path}]+set}" ]] || return 2
    target_count=$((target_count + 1))
  done < "${targets_file}"
  (( target_count == baseline_count )) || return 2
  # Baseline is produced directly from targets.tsv; require exact order as
  # well as set equality so a forged duplicate cannot hide behind counts.
  cmp -s <(cut -f 1 "${baseline}") "${targets_file}" || return 2

  while IFS= read -r line; do
    tabs="${line//[^$'\t']/}"
    [[ "${#tabs}" -eq 1 ]] || return 2
    IFS=$'\t' read -r relative_path commit_tmp extra <<< "${line}"
    [[ -z "${extra}" && -n "${commit_tmp}" ]] || return 2
    dispatcher_transaction_relative_path_valid "${relative_path}" || return 2
    [[ -n "${baseline_paths[${relative_path}]+set}" &&
       -z "${activation_paths[${relative_path}]+set}" ]] || return 2
    activation_paths["${relative_path}"]=1
    target="${NODE_HOME}/${relative_path}"
    expected_parent="$(dirname -- "${target}")" || return 2
    commit_parent="$(dirname -- "${commit_tmp}")" || return 2
    commit_name="$(basename -- "${commit_tmp}")" || return 2
    [[ "${commit_tmp}" == "${expected_parent}"/* &&
       "${commit_parent}" == "${expected_parent}" ]] || return 2
    case "${relative_path}" in
      .guild-source-receipt.json)
        [[ "${commit_name}" == ".guild-deploy-receipt.${transaction_pid}" ]] ||
          return 2
        ;;
      .deployment.json)
        [[ "${commit_name}" == ".guild-deploy-metadata.${transaction_pid}" ]] ||
          return 2
        ;;
      *)
        [[ "${commit_name}" =~ ^\.guild-deploy-${transaction_id}\.[1-9][0-9]*$ ]] ||
          return 2
        ;;
    esac
    dispatcher_cntools_absolute_path_has_no_symlinks "${target}" || return 2
    dispatcher_cntools_absolute_path_has_no_symlinks "${commit_tmp}" || return 2
    if [[ -e "${commit_tmp}" || -L "${commit_tmp}" ]]; then
      [[ -f "${commit_tmp}" && ! -L "${commit_tmp}" &&
         -O "${commit_tmp}" ]] || return 2
    fi
    activation_count=$((activation_count + 1))
  done < "${activation}"

  while IFS= read -r -d '' backup; do
    [[ -n "${backup}" ]] || continue
    inventory_backup_count=$((inventory_backup_count + 1))
    inventory_backup_name="$(basename -- "${backup}")" || return 2
    [[ "${inventory_backup_name}" =~ ^backup\.([1-9][0-9]*)$ ]] || return 2
    inventory_backup_index="${inventory_backup_name#backup.}"
    (( inventory_backup_index <= backup_count )) || return 2
  done < <(find "${root}" -mindepth 1 -maxdepth 1 -name 'backup.*' -print0)
  (( inventory_backup_count == backup_count )) || return 2
  case "${transaction_shape}" in
    modular|generation-only)
      [[ "${NODE_IMPLEMENTATION}" == "cnode" ||
         "${NODE_IMPLEMENTATION}" == "dingo" ]] || return 2
      (( facade_count == 1 )) || return 2
      ;;
    plain)
      if [[ "${NODE_IMPLEMENTATION}" == "amaru" ]]; then
        (( facade_count == 0 )) || return 2
      elif [[ "${NODE_IMPLEMENTATION}" == "cnode" ||
              "${NODE_IMPLEMENTATION}" == "dingo" ]]; then
        # Stage 0 cnode/Dingo journals have no special controls and use the
        # legacy ordinary ordering. Stage 2 starts with the facade, so deleting
        # both special records from a current journal cannot masquerade as A.
        (( facade_count == 1 )) || return 2
        [[ "${first_baseline_path}" == "scripts/guild-deploy.sh" ]] || return 2
      else
        return 2
      fi
      ;;
    *) return 2 ;;
  esac
}

dispatcher_transaction_committed_preflight() {
  local root="${1:-}" journal_record="" state="" transaction_id="" extra=""
  local receipt_candidate="${root}/receipt.candidate.json"
  local metadata_candidate="${root}/deployment.candidate.json"
  local receipt_target="${NODE_HOME}/.guild-source-receipt.json"
  local metadata_target="${NODE_HOME}/.deployment.json"
  local receipt_sha="" metadata_receipt_sha="" metadata_transaction_id=""
  local relative_path="" mode="" installed_sha="" managed="" target=""
  local actual_mode="" actual_sha=""
  local receipt_schema="" receipt_implementation="" generation_id=""
  local generation_path="" generation="" generation_manifest_sha=""
  local generation_receipt_sha=""

  [[ "${root}" == "${NODE_HOME}/.guild-deploy-transaction" &&
     -d "${root}" && ! -L "${root}" && -O "${root}" &&
     "$(dispatcher_path_mode "${root}")" == "0700" ]] || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${root}" || return 2
  journal_record="$(dispatcher_transaction_journal_record "${root}")" ||
    return 2
  IFS=$'\t' read -r state transaction_id extra <<< "${journal_record}"
  [[ "${state}" == "committed" && -z "${extra}" ]] || return 2
  dispatcher_transaction_control_file_valid \
    "${receipt_candidate}" 0644 N || return 2
  dispatcher_transaction_control_file_valid \
    "${metadata_candidate}" 0644 N || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${receipt_target}" || return 2
  dispatcher_cntools_absolute_path_has_no_symlinks "${metadata_target}" || return 2
  [[ -f "${receipt_target}" && ! -L "${receipt_target}" &&
     -O "${receipt_target}" &&
     "$(dispatcher_file_mode "${receipt_target}")" == "0644" &&
     -f "${metadata_target}" && ! -L "${metadata_target}" &&
     -O "${metadata_target}" &&
     "$(dispatcher_file_mode "${metadata_target}")" == "0644" ]] || return 2
  cmp -s "${receipt_candidate}" "${receipt_target}" || return 2
  cmp -s "${metadata_candidate}" "${metadata_target}" || return 2
  ( dispatcher_distribution_validate_prior_receipt ) || return 2
  jq -e '
    type == "object" and
    (
      if .schemaVersion == 1 then
        keys == ["files", "implementation", "network", "schemaVersion",
          "source"] and (has("cntoolsGeneration") | not)
      elif .schemaVersion == 2 then
        (keys == ["cntoolsGeneration", "files", "implementation", "network",
          "schemaVersion", "source"] or
         keys == ["files", "implementation", "network", "schemaVersion",
          "source"])
      else false end
    ) and
    (.implementation == "cnode" or .implementation == "dingo" or
      .implementation == "amaru") and
    (.network | type == "string" and length > 0) and
    (.source | type == "object") and
    (
      (.source.dirty == false and
        (.source | keys == ["channel", "dirty", "mode", "ref", "repository",
          "revision"])) or
      (.source.dirty == true and
        (.source | keys == ["channel", "dirty", "mode", "ref", "repository",
          "revision", "treeDigest"]) and
        (.source.treeDigest | type == "string" and test("^[0-9a-f]{64}$")))
    ) and
    (.source.repository | type == "string" and length > 0) and
    (.source.channel | type == "string" and length > 0) and
    (.source.ref | type == "string" and test("^refs/(heads|tags)/")) and
    (.source.revision | type == "string" and test("^[0-9a-f]{40,64}$")) and
    (.source.mode == "managed" or .source.mode == "cached" or
      .source.mode == "local") and
    (.files | type == "array" and length > 0) and
    (all(.files[];
      type == "object" and
      keys == ["installedSha256", "managed", "mode", "path", "policy",
        "source", "sourceSha256"] and
      (.path | type == "string" and
        test("^(scripts|files)/[A-Za-z0-9._/+@:-]+$")) and
      (.source | type == "string" and length > 0) and
      (.mode | type == "string" and test("^0[0-7]{3}$")) and
      (.policy | type == "string" and length > 0) and
      (.sourceSha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.installedSha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.managed | type == "boolean"))) and
    (([.files[].path] | length) == ([.files[].path] | unique | length)) and
    (
      if .schemaVersion == 1 then
        (if .implementation == "cnode" then (.files | length == 38)
         elif .implementation == "dingo" then (.files | length == 15)
         else (.files | length == 12) end)
      elif (.implementation == "cnode" or .implementation == "dingo") then
        (. as $receipt | .cntoolsGeneration as $generation |
          ($generation |
            type == "object" and
            keys == ["active", "fileCount", "generationReceipt",
              "generationReceiptSha256", "id", "path", "payloadManifest",
              "payloadManifestSha256", "schemaVersion", "version"] and
            .schemaVersion == 1 and .active == false and
            (.fileCount == 20 or .fileCount == 30 or
              .fileCount == 152) and
            (.id | type == "string" and test("^[0-9a-f]{64}$")) and
            .path == ("scripts/.cntools/generations/" + .id) and
            .payloadManifest == (.path + "/cntools/manifest.json") and
            .generationReceipt == (.path + "/.generation.json") and
            (.payloadManifestSha256 | type == "string" and
              test("^[0-9a-f]{64}$")) and
            (.generationReceiptSha256 | type == "string" and
              test("^[0-9a-f]{64}$"))) and
          (if $receipt.implementation == "cnode" then
             ($receipt.files | length == (if $generation.fileCount == 20
               then 38 else 48 end))
           else
             ($receipt.files | length == (if $generation.fileCount == 20
               then 15 else 25 end))
           end))
      else
        (has("cntoolsGeneration") | not) and (.files | length == 12)
      end
    )
  ' "${receipt_candidate}" >/dev/null 2>&1 || return 2
  while IFS=$'\t' read -r relative_path mode installed_sha managed; do
    dispatcher_distribution_relative_path_valid "${relative_path}" || return 2
    [[ "${mode}" =~ ^0[0-7]{3}$ &&
       "${installed_sha}" =~ ^[0-9a-f]{64}$ &&
       ( "${managed}" == "true" || "${managed}" == "false" ) ]] || return 2
    target="${NODE_HOME}/${relative_path}"
    dispatcher_cntools_absolute_path_has_no_symlinks "${target}" || return 2
    dispatcher_transaction_target_parent_safe "${target}" || return 2
    [[ -f "${target}" && ! -L "${target}" && -O "${target}" ]] || return 2
    actual_mode="$(dispatcher_file_mode "${target}")" || return 2
    actual_sha="$(dispatcher_sha256 "${target}")" || return 2
    [[ "${actual_mode}" == "${mode}" &&
       "${actual_sha}" == "${installed_sha}" ]] || return 2
  done < <(jq -er '.files[] |
    [.path,.mode,.installedSha256,(.managed|tostring)] | @tsv' \
    "${receipt_candidate}")
  receipt_schema="$(jq -er '.schemaVersion' "${receipt_candidate}")" || return 2
  receipt_implementation="$(jq -er '.implementation' \
    "${receipt_candidate}")" || return 2
  if [[ "${receipt_schema}" == "2" &&
        ( "${receipt_implementation}" == "cnode" ||
          "${receipt_implementation}" == "dingo" ) ]]; then
    generation_id="$(jq -er '.cntoolsGeneration.id' \
      "${receipt_candidate}")" || return 2
    generation_path="$(jq -er '.cntoolsGeneration.path' \
      "${receipt_candidate}")" || return 2
    [[ "${generation_id}" =~ ^[0-9a-f]{64}$ &&
       "${generation_path}" == \
         "scripts/.cntools/generations/${generation_id}" ]] || return 2
    generation="${NODE_HOME}/${generation_path}"
    dispatcher_cntools_absolute_path_has_no_symlinks "${generation}" || return 2
    [[ -d "${generation}" && ! -L "${generation}" &&
       -O "${generation}" ]] || return 2
    dispatcher_cntools_source_snapshot_lifecycle || return 2
    cntools_generation_validate "${generation}" "${generation_id}" || return 2
    generation_manifest_sha="$(dispatcher_sha256 \
      "${generation}/cntools/manifest.json")" || return 2
    generation_receipt_sha="$(dispatcher_sha256 \
      "${generation}/.generation.json")" || return 2
    [[ "${generation_manifest_sha}" == "$(jq -er \
         '.cntoolsGeneration.payloadManifestSha256' \
         "${receipt_candidate}")" &&
       "${generation_receipt_sha}" == "$(jq -er \
         '.cntoolsGeneration.generationReceiptSha256' \
         "${receipt_candidate}")" ]] || return 2
    jq -e -s '
      .[0].cntoolsGeneration as $outer |
      $outer.version == .[1].version and $outer.version == .[2].version and
      (if $outer.fileCount == 20 then
         .[1].schemaVersion == 1 and (.[1].files | length == 19) and
         .[2].schemaVersion == 1 and (.[2].files | length == 20)
       elif $outer.fileCount == 30 then
         .[1].schemaVersion == 2 and (.[1].files | length == 29) and
         .[2].schemaVersion == 2 and (.[2].files | length == 30)
       elif $outer.fileCount == 152 then
         .[1].schemaVersion == 3 and (.[1].files | length == 151) and
         .[2].schemaVersion == 3 and (.[2].files | length == 152)
       else false end)
    ' "${receipt_candidate}" "${generation}/cntools/manifest.json" \
      "${generation}/.generation.json" >/dev/null 2>&1 || return 2
  fi
  jq -e '
    type == "object" and
    ((keys - ["sourceTreeDigest"]) == ["branch", "capabilities",
      "deploymentStatus", "implementation", "metricsProvider", "network",
      "nodePort", "nodeVersion", "payloadReceipt", "payloadReceiptSha256",
      "repository", "schemaVersion", "serviceName", "sourceDirty",
      "sourceMode", "sourceRef", "sourceRevision", "sourceSchemaVersion",
      "targetNodeVersion", "transactionId"]) and
    .schemaVersion == 1 and
    .deploymentStatus == "deployed" and
    (.implementation == "cnode" or .implementation == "dingo" or
      .implementation == "amaru") and
    (.network | type == "string" and length > 0) and
    (.branch | type == "string" and length > 0) and
    (.repository | type == "string" and
      test("^[A-Za-z0-9_.-]+/guild-operators$")) and
    (.serviceName | type == "string" and length > 0) and
    (.nodePort | type == "number" and . >= 1 and . <= 65535 and . == floor) and
    (.nodeVersion | type == "string") and
    (.targetNodeVersion | type == "string") and
    (.metricsProvider | type == "string" and length > 0) and
    (.capabilities | type == "object" and
      keys == ["forging", "localCli", "metrics", "n2c"]) and
    (all(.capabilities[]; type == "boolean")) and
    (.sourceSchemaVersion == 1 or .sourceSchemaVersion == 2) and
    (.sourceMode == "managed" or .sourceMode == "cached" or
      .sourceMode == "local") and
    (.sourceRef | type == "string" and test("^refs/(heads|tags)/")) and
    (.sourceRevision | type == "string" and test("^[0-9a-f]{40,64}$")) and
    (.sourceDirty | type == "boolean") and
    ((.sourceDirty == false and (has("sourceTreeDigest") | not)) or
     (.sourceDirty == true and .sourceMode == "local" and
       (.sourceTreeDigest | type == "string" and test("^[0-9a-f]{64}$")))) and
    .payloadReceipt == ".guild-source-receipt.json" and
    (.payloadReceiptSha256 | type == "string" and
      test("^[0-9a-f]{64}$")) and
    (.transactionId | type == "string" and test("^[0-9a-f]{24}$"))
  ' "${metadata_candidate}" >/dev/null 2>&1 || return 2
  receipt_sha="$(dispatcher_sha256 "${receipt_candidate}")" || return 2
  metadata_receipt_sha="$(jq -er '.payloadReceiptSha256' \
    "${metadata_candidate}")" || return 2
  metadata_transaction_id="$(jq -er '.transactionId' \
    "${metadata_candidate}")" || return 2
  [[ "${receipt_sha}" == "${metadata_receipt_sha}" &&
     "${transaction_id}" == "${metadata_transaction_id}" &&
     "${transaction_id}" == "${receipt_sha:0:24}" ]] || return 2
  jq -e -s '
    .[0] as $receipt | .[1] as $metadata |
    ($receipt | type == "object" and
      (.schemaVersion == 1 or .schemaVersion == 2)) and
    ($metadata.implementation == $receipt.implementation) and
    ($metadata.network == $receipt.network) and
    ($metadata.repository == $receipt.source.repository) and
    ($metadata.branch == $receipt.source.channel) and
    ($metadata.sourceSchemaVersion == $receipt.schemaVersion) and
    ($metadata.sourceMode == $receipt.source.mode) and
    ($metadata.sourceRef == $receipt.source.ref) and
    ($metadata.sourceRevision == $receipt.source.revision) and
    ($metadata.sourceDirty == $receipt.source.dirty) and
    (if $receipt.source.dirty then
       $metadata.sourceTreeDigest == $receipt.source.treeDigest
     else
       ($metadata | has("sourceTreeDigest") | not) and
       ($receipt.source | has("treeDigest") | not)
     end)
  ' "${receipt_candidate}" "${metadata_candidate}" >/dev/null 2>&1 || return 2
}

dispatcher_transaction_rollback_root() {
  local root="$1"
  local baseline="${root}/baseline.tsv"
  local activation="${root}/activation.tsv"
  local rollback_relative_path="" existed_state="" backup_name="" target=""
  local backup="" restore_tmp="" commit_tmp="" mode=""
  local rollback_ok="Y"
  local facade_found="N" facade_existed_state="" facade_mode=""
  local facade_backup_name=""

  [[ -d "${root}" && ! -L "${root}" && -O "${root}" &&
     -f "${baseline}" && ! -L "${baseline}" && -O "${baseline}" ]] ||
    return 2
  # This shared gate is deliberately repeated by recovery and in-process
  # rollback. It is read-only and authenticates every durable control and
  # special-tree leg before the first chmod, move, remove, or baseline restore.
  dispatcher_transaction_rollback_control_preflight "${root}" || return 2
  # Authenticate the durable bundle contract before any other rollback leg
  # can mutate generation or ordinary payload state. A forged or malformed
  # bundle journal must leave the complete transaction untouched for manual
  # inspection or a trusted retry.
  dispatcher_cntools_legacy_bundle_rollback_root "${root}" || return $?
  dispatcher_cntools_generation_rollback_root "${root}" || rollback_ok="N"
  if [[ -f "${activation}" && ! -L "${activation}" ]]; then
    while IFS=$'\t' read -r rollback_relative_path commit_tmp; do
      dispatcher_transaction_relative_path_valid "${rollback_relative_path}" || return 2
      [[ "${commit_tmp}" == "${NODE_HOME}"/* &&
         "$(basename -- "${commit_tmp}")" == .guild-deploy-* ]] || return 2
      dispatcher_cntools_absolute_path_has_no_symlinks \
        "${NODE_HOME}/${rollback_relative_path}" || return 2
      dispatcher_cntools_absolute_path_has_no_symlinks "${commit_tmp}" || return 2
      rm -f -- "${commit_tmp}" 2>/dev/null || rollback_ok="N"
    done < "${activation}"
  fi

  while IFS=$'\t' read -r rollback_relative_path existed_state mode backup_name; do
    dispatcher_transaction_relative_path_valid "${rollback_relative_path}" || return 2
    if [[ "${rollback_relative_path}" == "scripts/cntools.library" ]]; then
      [[ "${facade_found}" == "N" ]] || return 2
      facade_found="Y"
      facade_existed_state="${existed_state}"
      facade_mode="${mode}"
      facade_backup_name="${backup_name}"
      continue
    fi
    target="${NODE_HOME}/${rollback_relative_path}"
    dispatcher_cntools_absolute_path_has_no_symlinks "${target}" || return 2
    case "${existed_state}" in
      Y)
        [[ "${backup_name}" =~ ^backup\.[0-9]+$ ]] || return 2
        backup="${root}/${backup_name}"
        [[ -f "${backup}" && ! -L "${backup}" && -O "${backup}" ]] ||
          return 2
        dispatcher_transaction_target_parent_safe "${target}" || {
          rollback_ok="N"
          continue
        }
        restore_tmp="$(mktemp \
          "$(dirname -- "${target}")/.guild-deploy-restore.XXXXXX")" || {
          rollback_ok="N"
          continue
        }
        dispatcher_transaction_target_parent_safe "${target}" || return 2
        dispatcher_cntools_absolute_path_has_no_symlinks "${target}" || return 2
        dispatcher_cntools_absolute_path_has_no_symlinks "${restore_tmp}" || return 2
        [[ -f "${restore_tmp}" && ! -L "${restore_tmp}" &&
           -O "${restore_tmp}" ]] || return 2
        if ! cp -p -- "${backup}" "${restore_tmp}" ||
           ! chmod "${mode}" "${restore_tmp}" ||
           ! mv -f -- "${restore_tmp}" "${target}"; then
          rm -f -- "${restore_tmp}"
          rollback_ok="N"
        fi
        ;;
      N)
        rm -f -- "${target}" 2>/dev/null || rollback_ok="N"
        ;;
      *) return 2 ;;
    esac
  done < "${baseline}"

  case "${NODE_IMPLEMENTATION}" in
    cnode|dingo) [[ "${facade_found}" == "Y" ]] || return 2 ;;
    amaru) [[ "${facade_found}" == "N" ]] || return 2 ;;
    *) return 2 ;;
  esac

  # Keep the journal-aware facade installed until every other baseline member
  # has been restored. If any earlier leg fails, leave both facade and journal
  # in place so concurrent CNTools readers continue to fail closed. The
  # deferred record is idempotent when recovery retries this journal.
  if [[ "${rollback_ok}" == "Y" && "${facade_found}" == "Y" ]]; then
    rollback_relative_path="scripts/cntools.library"
    target="${NODE_HOME}/${rollback_relative_path}"
    dispatcher_cntools_absolute_path_has_no_symlinks "${target}" || return 2
    case "${facade_existed_state}" in
      Y)
        [[ "${facade_backup_name}" =~ ^backup\.[0-9]+$ ]] || return 2
        backup="${root}/${facade_backup_name}"
        [[ -f "${backup}" && ! -L "${backup}" && -O "${backup}" ]] ||
          return 2
        dispatcher_transaction_target_parent_safe "${target}" || rollback_ok="N"
        if [[ "${rollback_ok}" == "Y" ]]; then
          restore_tmp="$(mktemp \
            "$(dirname -- "${target}")/.guild-deploy-restore.XXXXXX")" ||
            rollback_ok="N"
        fi
        if [[ "${rollback_ok}" == "Y" ]]; then
          dispatcher_transaction_target_parent_safe "${target}" || return 2
          dispatcher_cntools_absolute_path_has_no_symlinks "${target}" || return 2
          dispatcher_cntools_absolute_path_has_no_symlinks "${restore_tmp}" || return 2
          [[ -f "${restore_tmp}" && ! -L "${restore_tmp}" &&
             -O "${restore_tmp}" ]] || return 2
          if ! cp -p -- "${backup}" "${restore_tmp}" ||
             ! chmod "${facade_mode}" "${restore_tmp}" ||
             ! mv -f -- "${restore_tmp}" "${target}"; then
            rm -f -- "${restore_tmp}"
            rollback_ok="N"
          fi
        fi
        ;;
      N)
        rm -f -- "${target}" 2>/dev/null || rollback_ok="N"
        ;;
      *) return 2 ;;
    esac
  fi
  [[ "${rollback_ok}" == "Y" ]] || return 1
  dispatcher_transaction_remove_root "${root}"
}

dispatcher_recover_interrupted_transaction() {
  local root="${NODE_HOME}/.guild-deploy-transaction"
  local prepare="" cleanup_root="" journal_record="" journal_state=""
  local transaction_id="" extra=""

  while IFS= read -r cleanup_root; do
    [[ -n "${cleanup_root}" ]] || continue
    dispatcher_transaction_remove_root "${cleanup_root}" ||
      err_exit "Could not remove completed transaction quarantine at ${cleanup_root}."
  done < <(find "${NODE_HOME}" -mindepth 1 -maxdepth 1 \
    -name '.guild-deploy-transaction.cleanup.*' -print 2>/dev/null)

  while IFS= read -r prepare; do
    [[ -n "${prepare}" ]] || continue
    dispatcher_transaction_remove_root "${prepare}" ||
      err_exit "Could not remove an incomplete pre-activation transaction at ${prepare}."
  done < <(find "${NODE_HOME}" -mindepth 1 -maxdepth 1 \
    -name '.guild-deploy-transaction.prepare.*' -print 2>/dev/null)
  [[ -e "${root}" || -L "${root}" ]] || return 0
  [[ -d "${root}" && ! -L "${root}" && -O "${root}" ]] ||
    err_exit "Unsafe interrupted deployment transaction at ${root}."
  journal_record="$(dispatcher_transaction_journal_record "${root}")" ||
    err_exit "Unsafe interrupted deployment transaction journal at ${root}."
  IFS=$'\t' read -r journal_state transaction_id extra <<< "${journal_record}"
  [[ -z "${extra}" ]] ||
    err_exit "Unsafe interrupted deployment transaction journal at ${root}."
  if [[ "${journal_state}" == "committed" ]]; then
    dispatcher_transaction_committed_preflight "${root}" ||
      err_exit "Committed deployment transaction at ${root} failed authentication."
    dispatcher_transaction_remove_root "${root}" ||
      err_exit "Could not remove the completed transaction journal at ${root}."
    dispatcher_refresh_handoff_fingerprint_after_recovery ||
      err_exit "Could not refresh target identity after committed transaction recovery."
    return 0
  fi
  dispatcher_transaction_rollback_control_preflight "${root}" ||
    err_exit "Interrupted deployment transaction at ${root} failed recovery preflight."
  dispatcher_cntools_generation_recovery_lock_acquire "${root}" ||
    err_exit "Could not reclaim the interrupted CNTools generation transaction lock."
  log_warn "Recovering an interrupted Guild payload transaction before continuing."
  dispatcher_transaction_rollback_root "${root}" ||
    err_exit "Automatic rollback of ${root} failed; manual recovery is required."
  dispatcher_cntools_generation_lock_release ||
    err_exit "Could not release the recovered CNTools generation transaction lock."
  dispatcher_refresh_handoff_fingerprint_after_recovery ||
    err_exit "Could not refresh target identity after interrupted transaction recovery."
  log_ok "Interrupted Guild payload transaction recovered" "${NODE_HOME}"
}

dispatcher_distribution_old_managed_paths() {
  local receipt="${NODE_HOME}/.guild-source-receipt.json"
  local metadata="${NODE_HOME}/.deployment.json"
  local expected_hash="" actual_hash=""

  [[ -e "${receipt}" || -L "${receipt}" ]] || return 0
  [[ -f "${receipt}" && ! -L "${receipt}" && -O "${receipt}" &&
     -f "${metadata}" && ! -L "${metadata}" ]] || return 2
  command -v jq >/dev/null 2>&1 || return 2
  expected_hash="$(deployment_json_get "${metadata}" payloadReceiptSha256 || true)"
  [[ "${expected_hash}" =~ ^[0-9a-f]{64}$ ]] || return 2
  actual_hash="$(dispatcher_sha256 "${receipt}")" || return 2
  [[ "${actual_hash}" == "${expected_hash}" ]] || return 2
  jq -er '
    select(type == "object" and
      (.schemaVersion == 1 or .schemaVersion == 2) and
      (.files | type == "array")) |
    .files[] |
    select(.managed == true) |
    select(
      (.path | type == "string") and
      (.installedSha256 | type == "string" and test("^[0-9a-f]{64}$"))) |
    [.path, .installedSha256] | @tsv
  ' "${receipt}"
}

dispatcher_distribution_rollback() {
  local root="${DISPATCHER_TX_DURABLE_ROOT:-}"
  local status=0

  [[ "${DISPATCHER_TX_ACTIVE:-N}" == "Y" && -n "${root}" ]] || return 0
  dispatcher_transaction_rollback_root "${root}" || status=$?
  DISPATCHER_TX_ACTIVE="N"
  DISPATCHER_TX_ACTIVATED="N"
  DISPATCHER_TX_DURABLE_ROOT=""
  return "${status}"
}

dispatcher_distribution_activate() {
  local txid="" prepare_root="" durable_root=""
  local baseline="" activation="" targets_file="" current_file="" old_paths_file=""
  local archives_file="" history_file="" archive_path="" archive_target=""
  local history_path="" history_target="" history_name=""
  local validated_old_paths=""
  local source_path="" target_path="" mode="" policy=""
  local effective_policy="" validator="" source_hash="" old_path=""
  local old_hash="" actual_hash=""
  local target="" candidate="" backup_name="" commit_tmp=""
  local seen='|' old_seen='|' index=0 target_mode=""

  [[ "${DISPATCHER_TX_PREPARED:-N}" == "Y" &&
     "${DISPATCHER_TX_ACTIVATED:-N}" != "Y" ]] || return 2
  dispatcher_distribution_validate_candidates || return 2
  [[ -d "${NODE_HOME}" && ! -L "${NODE_HOME}" && -O "${NODE_HOME}" ]] ||
    return 2
  durable_root="${NODE_HOME}/.guild-deploy-transaction"
  [[ ! -e "${durable_root}" && ! -L "${durable_root}" ]] || return 2
  validated_old_paths="${DISPATCHER_TX_STAGE_ROOT}/old-managed-paths.validated"
  dispatcher_distribution_old_managed_paths > "${validated_old_paths}" || return 2
  while IFS=$'\t' read -r old_path old_hash; do
    [[ -n "${old_path}" ]] || continue
    dispatcher_distribution_relative_path_valid "${old_path}" || return 2
    [[ "${old_hash}" =~ ^[0-9a-f]{64}$ ]] || return 2
    [[ "${old_seen}" != *"|${old_path}|"* ]] || return 2
    old_seen="${old_seen}${old_path}|"
  done < "${validated_old_paths}"
  txid="$(date +%s).${BASHPID}.${RANDOM}"
  prepare_root="${NODE_HOME}/.guild-deploy-transaction.prepare.${txid}"
  (umask 077 && mkdir -- "${prepare_root}") || return 2
  DISPATCHER_TX_PREPARE_ROOT="${prepare_root}"
  chmod 0700 "${prepare_root}" || return 2
  baseline="${prepare_root}/baseline.tsv"
  activation="${prepare_root}/activation.tsv"
  targets_file="${prepare_root}/targets.tsv"
  current_file="${prepare_root}/current-targets"
  old_paths_file="${prepare_root}/old-managed-paths"
  archives_file="${prepare_root}/archives.tsv"
  history_file="${prepare_root}/history.tsv"
  : > "${baseline}" && : > "${activation}" && : > "${targets_file}" &&
    : > "${current_file}" && : > "${old_paths_file}" &&
    : > "${archives_file}" && : > "${history_file}" || return 2
  chmod 0600 "${baseline}" "${activation}" "${targets_file}" \
    "${current_file}" "${old_paths_file}" "${archives_file}" \
    "${history_file}" || return 2
  cp -- "${validated_old_paths}" "${old_paths_file}" || return 2

  while IFS=$'\t' read -r source_path target_path mode policy effective_policy validator source_hash; do
    dispatcher_transaction_relative_path_valid "${target_path}" || return 2
    printf '%s\n' "${target_path}" >> "${current_file}" || return 2
    if [[ "${seen}" != *"|${target_path}|"* ]]; then
      printf '%s\n' "${target_path}" >> "${targets_file}" || return 2
      seen="${seen}${target_path}|"
    fi
    if [[ "${policy}" == "retire" &&
          ( -e "${NODE_HOME}/${target_path}" ||
            -L "${NODE_HOME}/${target_path}" ) ]]; then
      case "${target_path}" in
        scripts/deploy-as-systemd.sh)
          archive_path="scripts/archive/deploy-as-systemd.sh_deprecated_${txid}"
          ;;
        scripts/.env_branch)
          archive_path="scripts/archive/.env_branch_migrated_${txid}"
          ;;
        *)
          archive_path="scripts/archive/$(basename -- "${target_path}")_retired_${txid}"
          ;;
      esac
      dispatcher_transaction_relative_path_valid "${archive_path}" || return 2
      [[ ! -e "${NODE_HOME}/${archive_path}" &&
         ! -L "${NODE_HOME}/${archive_path}" &&
         "${seen}" != *"|${archive_path}|"* ]] || return 2
      printf '%s\n' "${archive_path}" >> "${targets_file}" || return 2
      printf '%s\t%s\n' "${target_path}" "${archive_path}" \
        >> "${archives_file}" || return 2
      seen="${seen}${archive_path}|"
    elif [[ -f "${NODE_HOME}/${target_path}" &&
            ! -L "${NODE_HOME}/${target_path}" &&
            ( ( "${policy}" == "merge-header" &&
                "${DISPATCHER_FORCE_SCRIPTS:-N}" == "Y" ) ||
              ( "${policy}" == "preserve-render" &&
                "${DISPATCHER_FORCE_CONFIG:-N}" == "Y" ) ) ]]; then
      candidate="${DISPATCHER_TX_CANDIDATE_ROOT}/${target_path}"
      target_mode="$(dispatcher_file_mode "${NODE_HOME}/${target_path}")" ||
        return 2
      if ! cmp -s "${candidate}" "${NODE_HOME}/${target_path}" ||
         [[ "${target_mode}" != "${mode}" ]]; then
        history_name="${target_path//\//_}"
        history_path="scripts/archive/${history_name}_bkp${txid}"
        dispatcher_transaction_relative_path_valid "${history_path}" || return 2
        [[ ! -e "${NODE_HOME}/${history_path}" &&
           ! -L "${NODE_HOME}/${history_path}" &&
           "${seen}" != *"|${history_path}|"* ]] || return 2
        printf '%s\n' "${history_path}" >> "${targets_file}" || return 2
        printf '%s\t%s\n' "${target_path}" "${history_path}" \
          >> "${history_file}" || return 2
        seen="${seen}${history_path}|"
      fi
    fi
  done < "${DISPATCHER_TX_PLAN}"
  for target_path in .guild-source-receipt.json .deployment.json; do
    if [[ "${seen}" != *"|${target_path}|"* ]]; then
      printf '%s\n' "${target_path}" >> "${targets_file}" || return 2
      seen="${seen}${target_path}|"
    fi
  done
  while IFS=$'\t' read -r old_path old_hash; do
    [[ -n "${old_path}" ]] || continue
    dispatcher_distribution_relative_path_valid "${old_path}" || return 2
    dispatcher_cntools_legacy_bundle_managed_path "${old_path}" && continue
    if [[ "${seen}" != *"|${old_path}|"* ]]; then
      printf '%s\n' "${old_path}" >> "${targets_file}" || return 2
      seen="${seen}${old_path}|"
    fi
  done < "${old_paths_file}"

  while IFS= read -r target_path; do
    [[ -n "${target_path}" ]] || continue
    dispatcher_transaction_relative_path_valid "${target_path}" || return 2
    target="${NODE_HOME}/${target_path}"
    dispatcher_transaction_path_has_symlink "${target_path}" && return 2
    if [[ -e "${target}" ]]; then
      [[ -f "${target}" && ! -L "${target}" && -O "${target}" ]] || return 2
      index=$((index + 1))
      backup_name="backup.${index}"
      cp -p -- "${target}" "${prepare_root}/${backup_name}" || return 2
      target_mode="$(find "${target}" -prune -printf '%m' 2>/dev/null || true)"
      if [[ -z "${target_mode}" ]]; then
        target_mode="$(stat -f '%Lp' "${target}" 2>/dev/null || true)"
      fi
      [[ "${target_mode}" =~ ^[0-7]{3,4}$ ]] || return 2
      printf '%s\tY\t%s\t%s\n' "${target_path}" "${target_mode}" \
        "${backup_name}" >> "${baseline}" || return 2
    else
      printf '%s\tN\t-\t-\n' "${target_path}" >> "${baseline}" || return 2
    fi
  done < "${targets_file}"

  case "${NODE_IMPLEMENTATION}" in
    cnode|dingo)
      dispatcher_cntools_generation_prepare_durable "${prepare_root}" || return 2
      dispatcher_cntools_legacy_bundle_prepare_durable "${prepare_root}" ||
        return 2
      ;;
  esac

  dispatcher_test_failpoint before-durable-journal || return $?
  printf 'schemaVersion=1\ntransactionId=%s\nstate=prepared\n' "${txid}" \
    > "${prepare_root}/journal" || return 2
  chmod 0600 "${prepare_root}/journal" || return 2
  mv -- "${prepare_root}" "${durable_root}" || return 2
  DISPATCHER_TX_PREPARE_ROOT=""
  prepare_root="${durable_root}"
  baseline="${durable_root}/baseline.tsv"
  activation="${durable_root}/activation.tsv"
  archives_file="${durable_root}/archives.tsv"
  history_file="${durable_root}/history.tsv"
  DISPATCHER_TX_DURABLE_ROOT="${durable_root}"
  DISPATCHER_TX_ACTIVE="Y"
  dispatcher_test_failpoint after-durable-journal || return $?

  case "${NODE_IMPLEMENTATION}" in
    cnode|dingo)
      dispatcher_cntools_generation_publish "${durable_root}" || return 2
      dispatcher_test_failpoint after-cntools-generation-publish || return $?
      dispatcher_cntools_legacy_bundle_publish "${durable_root}" || return 2
      dispatcher_test_failpoint after-cntools-legacy-bundle-publish || return $?
      ;;
  esac

  index=0
  while IFS=$'\t' read -r source_path target_path mode policy effective_policy validator source_hash; do
    target="${NODE_HOME}/${target_path}"
    if [[ "${policy}" == "retire" ]]; then
      if [[ -e "${target}" || -L "${target}" ]]; then
        archive_path="$(awk -F '\t' -v path="${target_path}" \
          '$1 == path { print $2 }' "${archives_file}")"
        dispatcher_transaction_relative_path_valid "${archive_path}" || return 2
        archive_target="${NODE_HOME}/${archive_path}"
        [[ ! -e "${archive_target}" && ! -L "${archive_target}" ]] || return 2
        mkdir -p -- "$(dirname -- "${archive_target}")" || return 2
        mv -- "${target}" "${archive_target}" || return 2
        dispatcher_test_failpoint after-retire-archive || return $?
      fi
      continue
    fi
    candidate="${DISPATCHER_TX_CANDIDATE_ROOT}/${target_path}"
    history_path="$(awk -F '\t' -v path="${target_path}" \
      '$1 == path { print $2 }' "${history_file}")"
    if [[ -n "${history_path}" ]]; then
      dispatcher_transaction_relative_path_valid "${history_path}" || return 2
      history_target="${NODE_HOME}/${history_path}"
      [[ -f "${target}" && ! -L "${target}" &&
         ! -e "${history_target}" && ! -L "${history_target}" ]] || return 2
      mkdir -p -- "$(dirname -- "${history_target}")" || return 2
      cp -p -- "${target}" "${history_target}" || return 2
      dispatcher_test_failpoint after-history-archive || return $?
    fi
    mkdir -p -- "$(dirname -- "${target}")" || return 2
    index=$((index + 1))
    commit_tmp="$(dirname -- "${target}")/.guild-deploy-${txid}.${index}"
    printf '%s\t%s\n' "${target_path}" "${commit_tmp}" >> "${activation}" ||
      return 2
    [[ ! -e "${commit_tmp}" && ! -L "${commit_tmp}" ]] || return 2
    (umask 077 && cp -- "${candidate}" "${commit_tmp}") || return 2
    chmod "${mode}" "${commit_tmp}" || return 2
    if [[ -f "${target}" ]] && cmp -s "${candidate}" "${target}" &&
       [[ -n "$(find "${target}" -prune -perm "${mode}" -print 2>/dev/null)" ]]; then
      rm -f -- "${commit_tmp}" || return 2
    else
      mv -f -- "${commit_tmp}" "${target}" || return 2
    fi
    dispatcher_test_failpoint "after-payload:${index}" || return $?
  done < "${DISPATCHER_TX_PLAN}"

  while IFS=$'\t' read -r old_path old_hash; do
    [[ -n "${old_path}" ]] || continue
    dispatcher_cntools_legacy_bundle_managed_path "${old_path}" && continue
    if ! grep -Fqx "${old_path}" "${durable_root}/current-targets"; then
      target="${NODE_HOME}/${old_path}"
      if [[ -e "${target}" || -L "${target}" ]]; then
        [[ -f "${target}" && ! -L "${target}" ]] || return 2
        actual_hash="$(dispatcher_sha256 "${target}")" || return 2
        if [[ "${actual_hash}" == "${old_hash}" ]]; then
          rm -f -- "${target}" || return 2
          dispatcher_test_failpoint after-obsolete-remove || return $?
        else
          log_warn "Preserving customized obsolete Guild payload path: ${target}"
        fi
      fi
    fi
  done < "${durable_root}/old-managed-paths"

  printf 'schemaVersion=1\ntransactionId=%s\nstate=activated\n' "${txid}" \
    > "${durable_root}/journal" || return 2
  DISPATCHER_TX_ACTIVATED="Y"
}

dispatcher_capability_default() {
  local capability="$1"
  case "${NODE_IMPLEMENTATION}:${capability}" in
    cnode:n2c|cnode:local_cli|cnode:metrics|cnode:forging) printf 'true' ;;
    dingo:n2c|dingo:local_cli|dingo:metrics|dingo:forging) printf 'true' ;;
    amaru:metrics) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

dispatcher_metrics_provider() {
  if [[ -n "${PROFILE_METRICS_PROVIDER:-}" ]]; then
    printf '%s' "${PROFILE_METRICS_PROVIDER}"
  else
    case "${NODE_IMPLEMENTATION}" in
      cnode|dingo) printf 'prometheus' ;;
      amaru) printf 'otel' ;;
    esac
  fi
}

dispatcher_detect_node_version() {
  local binary=""
  local binary_path=""
  case "${NODE_IMPLEMENTATION}" in
    cnode) binary="cardano-node" ;;
    dingo) binary="dingo" ;;
    amaru) binary="amaru" ;;
  esac
  if [[ -x "${HOME}/.local/bin/${binary}" ]]; then
    binary_path="${HOME}/.local/bin/${binary}"
  elif command -v "${binary}" >/dev/null 2>&1; then
    binary_path="$(command -v "${binary}")"
  else
    return 0
  fi

  if [[ "${NODE_IMPLEMENTATION}" = "amaru" ]]; then
    "${binary_path}" --version 2>/dev/null | head -n 1 | tr -d '\r' || true
  else
    "${binary_path}" version 2>/dev/null | head -n 1 | tr -d '\r' || true
  fi
}

dispatcher_json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\b'/\\b}"
  value="${value//$'\f'/\\f}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "${value}"
}

dispatcher_validate_capability() {
  case "$1" in
    true|false) return 0 ;;
    *) err_exit "Deployment profile supplied an invalid capability value '$1'." ;;
  esac
}

dispatcher_distribution_write_receipt() {
  local output="$1"
  local source_path="" target_path="" mode="" policy=""
  local effective_policy="" validator="" source_hash=""
  local installed_hash="" target="" managed="true" first="Y"
  local digest_line=""
  local generation_path="" generation_root="" generation_manifest=""
  local generation_receipt="" generation_receipt_hash=""
  local bundle_manifest="" bundle_id="" bundle_path="" bundle_root=""
  local bundle_member="" bundle_mode="" bundle_sha="" bundle_size=""

  [[ "${DISPATCHER_TX_ACTIVE:-N}" == "Y" &&
     "${DISPATCHER_TX_ACTIVATED:-N}" == "Y" &&
     "${output}" == "${DISPATCHER_TX_DURABLE_ROOT}"/* ]] || return 2
  if [[ "${_GUILD_SOURCE_DIRTY}" == "true" ]]; then
    digest_line="    \"treeDigest\": \"$(dispatcher_json_escape "${_GUILD_SOURCE_TREE_DIGEST}")\","
  fi
  if [[ "${NODE_IMPLEMENTATION}" == "cnode" ||
        "${NODE_IMPLEMENTATION}" == "dingo" ]]; then
    generation_path="scripts/.cntools/generations/${DISPATCHER_CNTOOLS_GENERATION_ID:-}"
    [[ "${DISPATCHER_CNTOOLS_GENERATION_PUBLISHED:-N}" == "Y" &&
       "${DISPATCHER_CNTOOLS_GENERATION_INSTALLED_PATH:-}" == "${generation_path}" &&
       "${DISPATCHER_CNTOOLS_GENERATION_ID:-}" =~ ^[0-9a-f]{64}$ ]] ||
      return 2
    generation_root="${NODE_HOME}/${generation_path}"
    generation_manifest="${generation_root}/cntools/manifest.json"
    generation_receipt="${generation_root}/.generation.json"
    [[ "$(dispatcher_sha256 "${generation_manifest}")" == \
       "${DISPATCHER_CNTOOLS_GENERATION_MANIFEST_SHA256}" ]] || return 2
    generation_receipt_hash="$(dispatcher_sha256 "${generation_receipt}")" ||
      return 2
    bundle_manifest="${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_MANIFEST:-}"
    bundle_id="${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_ID:-}"
    bundle_path="scripts/cntools/libs/legacy/${bundle_id}"
    bundle_root="${NODE_HOME}/${bundle_path}"
    [[ "${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_PUBLISHED:-N}" == "Y" &&
       "${DISPATCHER_CNTOOLS_LEGACY_BUNDLE_INSTALLED_PATH:-}" == \
         "${bundle_path}" ]] || return 2
    dispatcher_cntools_legacy_bundle_validate_tree \
      "${bundle_root}" "${bundle_manifest}" || return 2
  fi
  {
    printf '{\n'
    printf '  "schemaVersion": 2,\n'
    printf '  "implementation": "%s",\n' "$(dispatcher_json_escape "${NODE_IMPLEMENTATION}")"
    printf '  "network": "%s",\n' "$(dispatcher_json_escape "${NETWORK}")"
    printf '  "source": {\n'
    printf '    "repository": "%s",\n' "$(dispatcher_json_escape "${_GUILD_SOURCE_REPOSITORY}")"
    printf '    "channel": "%s",\n' "$(dispatcher_json_escape "${_GUILD_SOURCE_CHANNEL}")"
    printf '    "ref": "%s",\n' "$(dispatcher_json_escape "${_GUILD_SOURCE_REF}")"
    printf '    "revision": "%s",\n' "$(dispatcher_json_escape "${_GUILD_SOURCE_REVISION}")"
    printf '    "mode": "%s",\n' "$(dispatcher_json_escape "${_GUILD_SOURCE_MODE}")"
    printf '    "dirty": %s' "${_GUILD_SOURCE_DIRTY}"
    if [[ -n "${digest_line}" ]]; then
      printf ',\n%s\n' "${digest_line%,}"
    else
      printf '\n'
    fi
    printf '  },\n'
    if [[ "${NODE_IMPLEMENTATION}" == "cnode" ||
          "${NODE_IMPLEMENTATION}" == "dingo" ]]; then
      printf '  "cntoolsGeneration": {\n'
      printf '    "schemaVersion": 1,\n'
      printf '    "id": "%s",\n' "${DISPATCHER_CNTOOLS_GENERATION_ID}"
      printf '    "version": "%s",\n' \
        "$(dispatcher_json_escape "${DISPATCHER_CNTOOLS_GENERATION_VERSION}")"
      printf '    "path": "%s",\n' "${generation_path}"
      printf '    "payloadManifest": "%s/cntools/manifest.json",\n' \
        "${generation_path}"
      printf '    "payloadManifestSha256": "%s",\n' \
        "${DISPATCHER_CNTOOLS_GENERATION_MANIFEST_SHA256}"
      printf '    "generationReceipt": "%s/.generation.json",\n' \
        "${generation_path}"
      printf '    "generationReceiptSha256": "%s",\n' \
        "${generation_receipt_hash}"
      printf '    "fileCount": %s,\n' \
        "${DISPATCHER_CNTOOLS_GENERATION_FILE_COUNT}"
      printf '    "active": false\n'
      printf '  },\n'
    fi
    printf '  "files": [\n'
    if [[ "${NODE_IMPLEMENTATION}" == "cnode" ||
          "${NODE_IMPLEMENTATION}" == "dingo" ]]; then
      while IFS=$'\t' read -r bundle_member bundle_mode bundle_size bundle_sha; do
        source_path="scripts/common-helper-scripts/cntools/libs/legacy/${bundle_id}/${bundle_member}"
        target_path="${bundle_path}/${bundle_member}"
        target="${NODE_HOME}/${target_path}"
        installed_hash="$(dispatcher_sha256 "${target}")" || return 2
        [[ "${bundle_mode}" == "0444" &&
           "${installed_hash}" == "${bundle_sha}" ]] || return 2
        [[ "${first}" == "Y" ]] || printf ',\n'
        first="N"
        printf '    {"path":"%s","source":"%s","mode":"%s",' \
          "$(dispatcher_json_escape "${target_path}")" \
          "$(dispatcher_json_escape "${source_path}")" "${bundle_mode}"
        printf '"policy":"cntools-legacy-bundle","sourceSha256":"%s",' \
          "${bundle_sha}"
        printf '"installedSha256":"%s","managed":true}' "${installed_hash}"
      done < <(jq -er '.legacyBundle.members[] |
        [.path,.mode,(.size|tostring),.sha256] | @tsv' "${bundle_manifest}")
    fi
    while IFS=$'\t' read -r source_path target_path mode policy effective_policy validator source_hash; do
      [[ "${policy}" != "retire" ]] || continue
      target="${NODE_HOME}/${target_path}"
      installed_hash="$(dispatcher_sha256 "${target}")" || return 2
      managed="true"
      [[ "${policy}" == "preserve-render" ||
         "${effective_policy}" == "operator-preserved" ]] && managed="false"
      if [[ "${effective_policy}" == "exact" &&
            "${installed_hash}" != "${source_hash}" ]]; then
        return 2
      fi
      [[ "${first}" == "Y" ]] || printf ',\n'
      first="N"
      printf '    {"path":"%s","source":"%s","mode":"%s",' \
        "$(dispatcher_json_escape "${target_path}")" \
        "$(dispatcher_json_escape "${source_path}")" \
        "$(dispatcher_json_escape "${mode}")"
      printf '"policy":"%s","sourceSha256":"%s",' \
        "$(dispatcher_json_escape "${effective_policy}")" "${source_hash}"
      printf '"installedSha256":"%s","managed":%s}' \
        "${installed_hash}" "${managed}"
    done < "${DISPATCHER_TX_PLAN}"
    printf '\n  ]\n}\n'
  } > "${output}" || return 2
  chmod 0644 "${output}" || return 2
  command -v jq >/dev/null 2>&1 || return 2
  jq -e '
    type == "object" and .schemaVersion == 2 and
    (.source.revision | test("^[0-9a-f]{40,64}$")) and
    (.files | type == "array" and length > 0) and
    (all(.files[];
      (.path | type == "string" and length > 0) and
      (.source | type == "string" and length > 0) and
      (.mode | type == "string" and test("^0[0-7]{3}$")) and
      (.policy | type == "string" and length > 0) and
      (.sourceSha256 | test("^[0-9a-f]{64}$")) and
      (.installedSha256 | test("^[0-9a-f]{64}$")) and
      (.managed | type == "boolean"))) and
    (
      if (.implementation == "cnode" or .implementation == "dingo") then
        (.cntoolsGeneration | type == "object" and
          keys == ["active", "fileCount", "generationReceipt",
            "generationReceiptSha256", "id", "path", "payloadManifest",
            "payloadManifestSha256", "schemaVersion", "version"] and
          .schemaVersion == 1 and .active == false and
          .fileCount == 152 and
          (.id | test("^[0-9a-f]{64}$")) and
          .path == ("scripts/.cntools/generations/" + .id) and
          .payloadManifest == (.path + "/cntools/manifest.json") and
          .generationReceipt == (.path + "/.generation.json") and
          (.payloadManifestSha256 | test("^[0-9a-f]{64}$")) and
          (.generationReceiptSha256 | test("^[0-9a-f]{64}$")))
      else
        (has("cntoolsGeneration") | not)
      end
    ) and
    (if .implementation == "cnode" then (.files | length == 48)
     elif .implementation == "dingo" then (.files | length == 25)
     elif .implementation == "amaru" then (.files | length == 12)
     else false end)
  ' "${output}" >/dev/null 2>&1
}

dispatcher_distribution_commit_receipt_and_metadata() {
  local receipt_candidate="$1"
  local metadata_candidate="$2"
  local receipt_target="${NODE_HOME}/.guild-source-receipt.json"
  local metadata_target="${NODE_HOME}/.deployment.json"
  local receipt_tmp="${NODE_HOME}/.guild-deploy-receipt.${BASHPID}"
  local metadata_tmp="${NODE_HOME}/.guild-deploy-metadata.${BASHPID}"
  local activation="${DISPATCHER_TX_DURABLE_ROOT:-}/activation.tsv"
  local expected_receipt_hash="${DISPATCHER_PAYLOAD_RECEIPT_SHA256:-}"

  [[ "${DISPATCHER_TX_ACTIVE:-N}" == "Y" &&
     "${DISPATCHER_TX_ACTIVATED:-N}" == "Y" &&
     -f "${receipt_candidate}" && -f "${metadata_candidate}" &&
     -f "${activation}" && ! -L "${activation}" && -O "${activation}" &&
     "${expected_receipt_hash}" =~ ^[0-9a-f]{64}$ ]] || return 2
  rm -f -- "${receipt_tmp}" "${metadata_tmp}" || return 2
  printf '.guild-source-receipt.json\t%s\n' "${receipt_tmp}" >> "${activation}" ||
    return 2
  printf '.deployment.json\t%s\n' "${metadata_tmp}" >> "${activation}" ||
    return 2
  cp -- "${receipt_candidate}" "${receipt_tmp}" &&
    chmod 0644 "${receipt_tmp}" || return 2
  cp -- "${metadata_candidate}" "${metadata_tmp}" &&
    chmod 0644 "${metadata_tmp}" || return 2

  dispatcher_test_failpoint before-receipt-publish || return $?
  if [[ -f "${receipt_target}" ]] &&
     cmp -s "${receipt_candidate}" "${receipt_target}" &&
     [[ -n "$(find "${receipt_target}" -prune -perm 0644 -print 2>/dev/null)" ]]; then
    rm -f -- "${receipt_tmp}" || return 2
  else
    mv -f -- "${receipt_tmp}" "${receipt_target}" || return 2
  fi
  [[ "$(dispatcher_sha256 "${receipt_target}")" == "${expected_receipt_hash}" ]] ||
    return 2
  dispatcher_test_failpoint after-receipt-publish || return $?

  dispatcher_test_failpoint before-metadata-publish || return $?
  if [[ -f "${metadata_target}" ]] &&
     cmp -s "${metadata_candidate}" "${metadata_target}" &&
     [[ -n "$(find "${metadata_target}" -prune -perm 0644 -print 2>/dev/null)" ]]; then
    rm -f -- "${metadata_tmp}" || return 2
  else
    mv -f -- "${metadata_tmp}" "${metadata_target}" || return 2
  fi
  cmp -s "${metadata_candidate}" "${metadata_target}" || return 2
  dispatcher_test_failpoint after-metadata-publish || return $?

  printf 'schemaVersion=1\ntransactionId=%s\nstate=committed\n' \
    "${DISPATCHER_TRANSACTION_ID:-unknown}" \
    > "${DISPATCHER_TX_DURABLE_ROOT}/journal" || return 2
  DISPATCHER_TX_ACTIVE="N"
  DISPATCHER_TX_ACTIVATED="N"
  dispatcher_transaction_remove_root "${DISPATCHER_TX_DURABLE_ROOT}" || return 2
  DISPATCHER_TX_DURABLE_ROOT=""
  return 0
}

dispatcher_write_manifest() {
  local deployment_status="${1:-deployed}"
  [[ -d "${NODE_HOME}" ]] || err_exit "Deployment profile completed without creating ${NODE_HOME}."
  case "${deployment_status}" in
    deploying) return 0 ;;
    deployed) ;;
    *) err_exit "Invalid deployment status '${deployment_status}'." ;;
  esac

  local node_version
  local manifest_tmp
  local receipt_tmp
  local receipt_hash
  local transaction_id
  local cap_n2c
  local cap_local_cli
  local cap_metrics
  local cap_forging
  local metrics_provider
  local target_node_version
  [[ "${DISPATCHER_TX_ACTIVE:-N}" == "Y" &&
     "${DISPATCHER_TX_ACTIVATED:-N}" == "Y" &&
     -d "${DISPATCHER_TX_DURABLE_ROOT:-}" ]] ||
    err_exit "Deployment metadata can be published only by an active complete payload transaction."
  receipt_tmp="${DISPATCHER_TX_DURABLE_ROOT}/receipt.candidate.json"
  dispatcher_distribution_write_receipt "${receipt_tmp}" ||
    err_exit "Could not build or validate the installed Guild payload receipt."
  receipt_hash="$(dispatcher_sha256 "${receipt_tmp}")" ||
    err_exit "Could not hash the installed Guild payload receipt."
  transaction_id="${receipt_hash:0:24}"
  DISPATCHER_PAYLOAD_RECEIPT_SHA256="${receipt_hash}"
  DISPATCHER_TRANSACTION_ID="${transaction_id}"
  node_version="$(dispatcher_detect_node_version)"
  target_node_version="${PROFILE_TARGET_NODE_VERSION:-}"
  manifest_tmp="${DISPATCHER_TX_DURABLE_ROOT}/deployment.candidate.json"
  cap_n2c="${PROFILE_CAP_N2C:-$(dispatcher_capability_default n2c)}"
  cap_local_cli="${PROFILE_CAP_LOCAL_CLI:-$(dispatcher_capability_default local_cli)}"
  cap_metrics="${PROFILE_CAP_METRICS:-$(dispatcher_capability_default metrics)}"
  cap_forging="${PROFILE_CAP_FORGING:-$(dispatcher_capability_default forging)}"
  metrics_provider="$(dispatcher_metrics_provider)"
  dispatcher_validate_capability "${cap_n2c}"
  dispatcher_validate_capability "${cap_local_cli}"
  dispatcher_validate_capability "${cap_metrics}"
  dispatcher_validate_capability "${cap_forging}"

  if ! {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "deploymentStatus": "%s",\n' "$(dispatcher_json_escape "${deployment_status}")"
    printf '  "implementation": "%s",\n' "$(dispatcher_json_escape "${NODE_IMPLEMENTATION}")"
    printf '  "network": "%s",\n' "$(dispatcher_json_escape "${NETWORK}")"
    printf '  "branch": "%s",\n' "$(dispatcher_json_escape "${BRANCH}")"
    printf '  "repository": "%s",\n' \
      "$(dispatcher_json_escape "${_GUILD_SOURCE_REPOSITORY}")"
    printf '  "sourceSchemaVersion": 2,\n'
    printf '  "sourceMode": "%s",\n' "$(dispatcher_json_escape "${_GUILD_SOURCE_MODE}")"
    printf '  "sourceRef": "%s",\n' "$(dispatcher_json_escape "${_GUILD_SOURCE_REF}")"
    printf '  "sourceRevision": "%s",\n' "$(dispatcher_json_escape "${_GUILD_SOURCE_REVISION}")"
    printf '  "sourceDirty": %s,\n' "${_GUILD_SOURCE_DIRTY}"
    if [[ "${_GUILD_SOURCE_DIRTY}" == "true" ]]; then
      printf '  "sourceTreeDigest": "%s",\n' \
        "$(dispatcher_json_escape "${_GUILD_SOURCE_TREE_DIGEST}")"
    fi
    printf '  "payloadReceipt": ".guild-source-receipt.json",\n'
    printf '  "payloadReceiptSha256": "%s",\n' "${receipt_hash}"
    printf '  "transactionId": "%s",\n' "${transaction_id}"
    printf '  "serviceName": "%s",\n' "$(dispatcher_json_escape "${NODE_SERVICE}")"
    printf '  "nodePort": %s,\n' "${NODE_PORT}"
    printf '  "nodeVersion": "%s",\n' "$(dispatcher_json_escape "${node_version}")"
    printf '  "targetNodeVersion": "%s",\n' "$(dispatcher_json_escape "${target_node_version}")"
    printf '  "metricsProvider": "%s",\n' "$(dispatcher_json_escape "${metrics_provider}")"
    printf '  "capabilities": {\n'
    printf '    "n2c": %s,\n' "${cap_n2c}"
    printf '    "localCli": %s,\n' "${cap_local_cli}"
    printf '    "metrics": %s,\n' "${cap_metrics}"
    printf '    "forging": %s\n' "${cap_forging}"
    printf '  }\n'
    printf '}\n'
  } > "${manifest_tmp}"; then
    rm -f -- "${manifest_tmp}"
    err_exit "Unable to write the temporary deployment manifest."
  fi

  command -v jq >/dev/null 2>&1 ||
    err_exit "jq is required to validate generated deployment metadata."
  if ! jq -e . "${manifest_tmp}" >/dev/null 2>&1; then
    rm -f -- "${manifest_tmp}"
    err_exit "Generated deployment manifest is invalid."
  fi
  if ! chmod 644 "${manifest_tmp}"; then
    rm -f -- "${manifest_tmp}"
    err_exit "Unable to set deployment manifest permissions."
  fi

  dispatcher_distribution_commit_receipt_and_metadata \
    "${receipt_tmp}" "${manifest_tmp}" ||
    err_exit "Could not commit payload receipt and deployment metadata; the previous target was restored."
  log_ok "Deployment metadata updated" "${DEPLOYMENT_FILE}"
}

dispatcher_cntools_generation_prune_after_commit() {
  local generation_root=""

  case "${NODE_IMPLEMENTATION}" in
    cnode|dingo) ;;
    *) return 0 ;;
  esac
  [[ "${DISPATCHER_CNTOOLS_GENERATION_ID:-}" =~ ^[0-9a-f]{64}$ ]] ||
    return 2
  generation_root="${NODE_HOME}/scripts/.cntools"
  declare -F cntools_generation_validate >/dev/null 2>&1 || return 2
  declare -F cntools_generation_prune_locked >/dev/null 2>&1 || return 2
  cntools_generation_lock_is_owned "${generation_root}" || return 2
  cntools_generation_validate \
    "${generation_root}/generations/${DISPATCHER_CNTOOLS_GENERATION_ID}" \
    "${DISPATCHER_CNTOOLS_GENERATION_ID}" || return 2
  cntools_generation_prune_locked \
    "${generation_root}" "${DISPATCHER_CNTOOLS_GENERATION_ID}"
}

dispatcher_docker_export_relative_path_valid() {
  local relative_path="${1:-}"
  local component=""
  local -a components=()

  [[ -n "${relative_path}" && "${relative_path}" != /* &&
     "${relative_path}" != */ && "${relative_path}" != *//* &&
     ! "${relative_path}" =~ [[:cntrl:]] &&
     "${relative_path}" =~ ^rootfs/[A-Za-z0-9._/+@:-]+$ ]] || return 1
  IFS='/' read -r -a components <<< "${relative_path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" && "${component}" != "." &&
       "${component}" != ".." ]] || return 1
  done
}

dispatcher_docker_export_supplement() {
  local export_root="${GUILD_DOCKER_EXPORT_ROOT:-}"
  local export_parent="" export_name="" physical_parent="" stage_root=""
  local manifest="" first_line="" line="" without_tabs="" plan=""
  local implementation="" source_path="" export_path="" mode=""
  local validator="" extra="" source_file="" exported_file=""
  local source_hash="" exported_hash="" final_path="" seen='|' count=0
  local host_receipt="${NODE_HOME}/.guild-source-receipt.json"
  local host_receipt_hash="" metadata_receipt_hash="" transaction_id=""
  local receipt="" receipt_hash="" first="Y" digest_line=""

  [[ -n "${export_root}" ]] || return 0
  [[ "${export_root}" == /* && "${export_root}" != "/" &&
     ! -e "${export_root}" && ! -L "${export_root}" ]] || return 2
  export_parent="$(dirname -- "${export_root}")" || return 2
  export_name="$(basename -- "${export_root}")" || return 2
  [[ "${export_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 2
  _guild_source_cache_parent_prepare "${export_parent}" || return 2
  physical_parent="$(cd -P -- "${export_parent}" 2>/dev/null && pwd -P)" || return 2
  export_root="${physical_parent}/${export_name}"
  [[ ! -e "${export_root}" && ! -L "${export_root}" &&
     "${export_root}" != "${NODE_HOME}" &&
     "${export_root}" != "${NODE_HOME}"/* ]] || return 2
  stage_root="$(mktemp -d "${physical_parent}/.${export_name}.prepare.XXXXXX")" ||
    return 2
  DISPATCHER_DOCKER_EXPORT_STAGE="${stage_root}"
  chmod 0700 "${stage_root}" || return 2
  plan="${stage_root}/export-plan.tsv"
  : > "${plan}" || return 2
  chmod 0600 "${plan}" || return 2

  manifest="$(guild_source_path files/docker/node/source-manifest.tsv)" || return 2
  IFS= read -r first_line < "${manifest}" || return 2
  [[ "${first_line}" == '# Guild Operators Docker supplement source manifest, schema 1.' ]] ||
    return 2
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    without_tabs="${line//$'\t'/}"
    (( ${#line} - ${#without_tabs} == 4 )) || return 2
    IFS=$'\t' read -r implementation source_path export_path mode validator extra <<< "${line}"
    [[ -n "${implementation}" && -n "${source_path}" &&
       -n "${export_path}" && -n "${mode}" && -n "${validator}" &&
       -z "${extra}" ]] || return 2
    case "${implementation}" in common|cnode|dingo|amaru) ;; *) return 2 ;; esac
    case "${mode}" in 0644|0755) ;; *) return 2 ;; esac
    case "${validator}" in shell|json|text) ;; *) return 2 ;; esac
    _guild_source_relative_path_valid "${source_path}" || return 2
    [[ "${source_path}" != *'{'* && "${source_path}" != *'}'* ]] || return 2
    export_path="${export_path//\{implementation\}/${NODE_IMPLEMENTATION}}"
    [[ "${export_path}" != *'{'* && "${export_path}" != *'}'* ]] || return 2
    dispatcher_docker_export_relative_path_valid "${export_path}" || return 2
    source_file="$(guild_source_path "${source_path}")" || return 2
    case "${validator}" in
      shell) "${BASH}" -n "${source_file}" >/dev/null 2>&1 || return 2 ;;
      json) jq -e . "${source_file}" >/dev/null 2>&1 || return 2 ;;
      text) [[ -s "${source_file}" ]] || return 2 ;;
    esac
    [[ "${implementation}" == "common" ||
       "${implementation}" == "${NODE_IMPLEMENTATION}" ]] || continue
    [[ "${seen}" != *"|${export_path}|"* ]] || return 2
    seen="${seen}${export_path}|"
    exported_file="${stage_root}/${export_path}"
    mkdir -p -- "$(dirname -- "${exported_file}")" || return 2
    cp -- "${source_file}" "${exported_file}" || return 2
    chmod "${mode}" "${exported_file}" || return 2
    source_hash="$(dispatcher_sha256 "${source_file}")" || return 2
    exported_hash="$(dispatcher_sha256 "${exported_file}")" || return 2
    [[ "${source_hash}" == "${exported_hash}" ]] || return 2
    printf '%s\t%s\t%s\t%s\n' "${source_path}" "${export_path}" \
      "${mode}" "${source_hash}" >> "${plan}" || return 2
    count=$((count + 1))
  done < "${manifest}"
  (( count > 0 )) || return 2
  find "${stage_root}/rootfs" -type d -exec chmod 0755 {} + || return 2

  [[ -f "${host_receipt}" && ! -L "${host_receipt}" ]] || return 2
  host_receipt_hash="$(dispatcher_sha256 "${host_receipt}")" || return 2
  metadata_receipt_hash="$(deployment_json_get "${DEPLOYMENT_FILE}" payloadReceiptSha256 || true)"
  transaction_id="$(deployment_json_get "${DEPLOYMENT_FILE}" transactionId || true)"
  [[ "${host_receipt_hash}" == "${metadata_receipt_hash}" &&
     "${host_receipt_hash}" =~ ^[0-9a-f]{64}$ &&
     "${transaction_id}" =~ ^[0-9a-f]{16,64}$ ]] || return 2
  if [[ "${_GUILD_SOURCE_DIRTY}" == "true" ]]; then
    digest_line="    \"treeDigest\": \"$(dispatcher_json_escape "${_GUILD_SOURCE_TREE_DIGEST}")\","
  fi
  receipt="${stage_root}/docker-source-receipt.json"
  {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "implementation": "%s",\n' "$(dispatcher_json_escape "${NODE_IMPLEMENTATION}")"
    printf '  "network": "%s",\n' "$(dispatcher_json_escape "${NETWORK}")"
    printf '  "source": {\n'
    printf '    "repository": "%s",\n' "$(dispatcher_json_escape "${_GUILD_SOURCE_REPOSITORY}")"
    printf '    "channel": "%s",\n' "$(dispatcher_json_escape "${_GUILD_SOURCE_CHANNEL}")"
    printf '    "ref": "%s",\n' "$(dispatcher_json_escape "${_GUILD_SOURCE_REF}")"
    printf '    "revision": "%s",\n' "$(dispatcher_json_escape "${_GUILD_SOURCE_REVISION}")"
    printf '    "mode": "%s",\n' "$(dispatcher_json_escape "${_GUILD_SOURCE_MODE}")"
    printf '    "dirty": %s' "${_GUILD_SOURCE_DIRTY}"
    if [[ -n "${digest_line}" ]]; then
      printf ',\n%s\n' "${digest_line%,}"
    else
      printf '\n'
    fi
    printf '  },\n'
    printf '  "hostPayloadReceipt": ".guild-source-receipt.json",\n'
    printf '  "hostPayloadReceiptSha256": "%s",\n' "${host_receipt_hash}"
    printf '  "hostTransactionId": "%s",\n' "${transaction_id}"
    printf '  "files": [\n'
    while IFS=$'\t' read -r source_path export_path mode source_hash; do
      exported_file="${stage_root}/${export_path}"
      exported_hash="$(dispatcher_sha256 "${exported_file}")" || return 2
      final_path="/${export_path#rootfs/}"
      [[ "${first}" == "Y" ]] || printf ',\n'
      first="N"
      printf '    {"source":"%s","path":"%s","mode":"%s",' \
        "$(dispatcher_json_escape "${source_path}")" \
        "$(dispatcher_json_escape "${final_path}")" "${mode}"
      printf '"sourceSha256":"%s","exportedSha256":"%s"}' \
        "${source_hash}" "${exported_hash}"
    done < "${plan}"
    printf '\n  ]\n}\n'
  } > "${receipt}" || return 2
  chmod 0644 "${receipt}" || return 2
  jq -e --arg revision "${_GUILD_SOURCE_REVISION}" \
    --arg host_hash "${host_receipt_hash}" --arg transaction "${transaction_id}" '
    type == "object" and .schemaVersion == 1 and
    .source.revision == $revision and
    .hostPayloadReceiptSha256 == $host_hash and
    .hostTransactionId == $transaction and
    (.files | type == "array" and length > 0) and
    (all(.files[];
      (.source | type == "string" and test("^(scripts|files)/")) and
      (.path | type == "string" and test("^/")) and
      (.mode == "0644" or .mode == "0755") and
      (.sourceSha256 | test("^[0-9a-f]{64}$")) and
      (.exportedSha256 == .sourceSha256)))
  ' "${receipt}" >/dev/null 2>&1 || return 2
  receipt_hash="$(dispatcher_sha256 "${receipt}")" || return 2
  printf '%s  docker-source-receipt.json\n' "${receipt_hash}" \
    > "${stage_root}/docker-source-receipt.sha256" || return 2
  chmod 0644 "${stage_root}/docker-source-receipt.sha256" || return 2
  rm -f -- "${plan}" || return 2
  mv -- "${stage_root}" "${export_root}" || return 2
  DISPATCHER_DOCKER_EXPORT_STAGE=""
  log_ok "Docker supplement exported" "${export_root}"
}

dispatcher_mark_in_progress() {
  # Progress lives only in the private transaction journal. The last deployed
  # manifest remains authoritative until receipt and metadata commit together.
  return 0
}

dispatcher_signal_exit() {
  local signal_name="${1:-TERM}"
  local status=143

  case "${signal_name}" in
    HUP) status=129 ;;
    INT) status=130 ;;
    TERM) status=143 ;;
    *) status=143 ;;
  esac
  trap - HUP INT TERM
  exit "${status}"
}

cleanup_dispatcher() {
  local cleanup_status="${1:-0}"

  trap - EXIT
  trap '' HUP INT TERM
  if [[ "${DISPATCHER_TX_ACTIVE:-N}" == "Y" ]]; then
    dispatcher_distribution_rollback ||
      log_warn "Automatic Guild payload rollback failed; inspect ${NODE_HOME:-target} before retrying."
  fi
  if [[ -n "${DISPATCHER_TX_PREPARE_ROOT:-}" &&
        -n "${NODE_HOME:-}" &&
        "${DISPATCHER_TX_PREPARE_ROOT}" == "${NODE_HOME}"/.guild-deploy-transaction.prepare.* &&
        -d "${DISPATCHER_TX_PREPARE_ROOT}" &&
        ! -L "${DISPATCHER_TX_PREPARE_ROOT}" &&
        -O "${DISPATCHER_TX_PREPARE_ROOT}" ]]; then
    dispatcher_transaction_remove_root "${DISPATCHER_TX_PREPARE_ROOT}" ||
      log_warn "Could not remove incomplete Guild transaction preparation at ${DISPATCHER_TX_PREPARE_ROOT}."
  fi
  if [[ -n "${DISPATCHER_TX_STAGE_ROOT:-}" &&
        "${DISPATCHER_TX_STAGE_ROOT}" == "${TMPDIR:-/tmp}"/guild-deploy-distribution.* &&
        -d "${DISPATCHER_TX_STAGE_ROOT}" && ! -L "${DISPATCHER_TX_STAGE_ROOT}" &&
        -O "${DISPATCHER_TX_STAGE_ROOT}" ]]; then
    chmod -R u+rwX "${DISPATCHER_TX_STAGE_ROOT}" 2>/dev/null || true
    rm -rf -- "${DISPATCHER_TX_STAGE_ROOT}"
  fi
  if [[ -n "${DISPATCHER_DOCKER_EXPORT_STAGE:-}" &&
        "${DISPATCHER_DOCKER_EXPORT_STAGE}" == */.*.prepare.* &&
        -d "${DISPATCHER_DOCKER_EXPORT_STAGE}" &&
        ! -L "${DISPATCHER_DOCKER_EXPORT_STAGE}" &&
        -O "${DISPATCHER_DOCKER_EXPORT_STAGE}" ]]; then
    chmod -R u+rwX "${DISPATCHER_DOCKER_EXPORT_STAGE}" 2>/dev/null || true
    rm -rf -- "${DISPATCHER_DOCKER_EXPORT_STAGE}"
  fi
  if [[ "${DISPATCHER_PROFILE_TMP_OWNED:-N}" = "Y" &&
        -n "${PROFILE_TMP_DIR:-}" &&
        -d "${PROFILE_TMP_DIR}" ]]; then
    rm -rf -- "${PROFILE_TMP_DIR}"
  fi
  # The durable outer journal, not this process-scoped kernel lock, blocks
  # standalone lifecycle operations. Release the generation lock before the
  # target lock; authenticated recovery will reacquire it under that lock.
  if ! dispatcher_cntools_generation_lock_release; then
    log_warn "Could not release the CNTools generation transaction lock."
    [[ "${cleanup_status}" -ne 0 ]] || cleanup_status=2
  fi
  dispatcher_release_target_lock
  guild_source_release || true
  return "${cleanup_status}"
}

guild_deploy_main() {
  local -a original_args=("$@")
  local source_handoff="${GUILD_SOURCE_HANDOFF_ACTIVE:-N}"
  local target_journal_admitted="${GUILD_SOURCE_TARGET_JOURNAL_ADMITTED:-}"
  local target_journal_token="${GUILD_SOURCE_TARGET_JOURNAL_TOKEN:-}"
  local requested_account_preset="${GUILD_SOURCE_REQUEST_ACCOUNT_PRESET:-}"
  local requested_branch_preset="${GUILD_SOURCE_REQUEST_BRANCH_PRESET:-}"
  local requested_network_preset="${GUILD_SOURCE_REQUEST_NETWORK_PRESET:-}"
  local requested_mode_preset="${GUILD_SOURCE_REQUEST_MODE_PRESET:-}"
  local requested_node_port_preset="${GUILD_SOURCE_REQUEST_NODE_PORT_PRESET:-}"

  # Never trust cleanup paths inherited from the caller's environment.
  PROFILE_TMP_DIR=""
  DISPATCHER_PROFILE_TMP_OWNED="N"
  DISPATCHER_TX_STAGE_ROOT=""
  DISPATCHER_TX_CANDIDATE_ROOT=""
  DISPATCHER_TX_PLAN=""
  DISPATCHER_TX_DURABLE_ROOT=""
  DISPATCHER_TX_PREPARE_ROOT=""
  DISPATCHER_DOCKER_EXPORT_STAGE=""
  DISPATCHER_TX_PREPARED="N"
  DISPATCHER_TX_ACTIVE="N"
  DISPATCHER_TX_ACTIVATED="N"
  DISPATCHER_CNTOOLS_GENERATION_PREPARED="N"
  DISPATCHER_CNTOOLS_GENERATION_PUBLISHED="N"
  DISPATCHER_CNTOOLS_GENERATION_STAGE=""
  DISPATCHER_CNTOOLS_GENERATION_ID=""
  DISPATCHER_CNTOOLS_GENERATION_VERSION=""
  DISPATCHER_CNTOOLS_GENERATION_MANIFEST_SHA256=""
  DISPATCHER_CNTOOLS_GENERATION_LIFECYCLE_SHA256=""
  DISPATCHER_CNTOOLS_GENERATION_LOCK_OWNED="N"
  DISPATCHER_CNTOOLS_GENERATION_LOCK_ROOT=""
  unset CNTOOLS_GENERATION_LOCK_PATH CNTOOLS_GENERATION_LOCK_ROOT
  unset CNTOOLS_GENERATION_LOCK_BACKEND CNTOOLS_GENERATION_LOCK_CONTROL
  unset CNTOOLS_GENERATION_LOCK_HOLDER_PID
  unset CNTOOLS_GENERATION_LOCK_HOLDER_IDENTITY CNTOOLS_GENERATION_LOCK_PID
  DISPATCHER_CNTOOLS_GENERATION_FILE_COUNT=""
  DISPATCHER_CNTOOLS_GENERATION_TARGET_ROOT=""
  DISPATCHER_CNTOOLS_GENERATION_INSTALLED_PATH=""
  DISPATCHER_CNTOOLS_LEGACY_BUNDLE_PREPARED="N"
  DISPATCHER_CNTOOLS_LEGACY_BUNDLE_PUBLISHED="N"
  DISPATCHER_CNTOOLS_LEGACY_BUNDLE_MANIFEST=""
  DISPATCHER_CNTOOLS_LEGACY_BUNDLE_STAGE=""
  DISPATCHER_CNTOOLS_LEGACY_BUNDLE_ID=""
  DISPATCHER_CNTOOLS_LEGACY_BUNDLE_TARGET_ROOT=""
  DISPATCHER_CNTOOLS_LEGACY_BUNDLE_INSTALLED_PATH=""
  DISPATCHER_HANDOFF_JOURNAL_REFRESH_AUTHORIZED="N"
  unset GUILD_DEPLOY_LOCK_HELD_FOR
  unset DISPATCHER_LOCK_KIND DISPATCHER_LOCK_PATH
  unset DISPATCHER_LOCK_CANONICAL_TARGET DISPATCHER_LOCK_OWNER_PID
  unset DISPATCHER_USER_LOCK_KIND DISPATCHER_USER_LOCK_PATH
  unset PROFILE_PATH PROFILE_ENTRYPOINT PROFILE_TARGET_NODE_VERSION
  unset PROFILE_METRICS_PROVIDER PROFILE_CAP_N2C PROFILE_CAP_LOCAL_CLI
  unset PROFILE_CAP_METRICS PROFILE_CAP_FORGING
  trap 'cleanup_dispatcher "$?"' EXIT
  trap 'dispatcher_signal_exit HUP' HUP
  trap 'dispatcher_signal_exit INT' INT
  trap 'dispatcher_signal_exit TERM' TERM

  if [[ "${source_handoff}" == "Y" ]]; then
    guild_source_adopt_handoff ||
      err_exit "The prepared Guild source handoff is invalid or does not match the running dispatcher."
    case "${target_journal_admitted:-N}" in
      N)
        [[ -z "${target_journal_token}" ]] ||
          err_exit "The prepared target journal handoff is inconsistent."
        GUILD_SOURCE_TARGET_JOURNAL_ADMITTED="N"
        GUILD_SOURCE_TARGET_JOURNAL_TOKEN=""
        ;;
      Y)
        [[ "${target_journal_token}" =~ ^(prepared|activated):[0-9]{1,20}\.[0-9]{1,20}\.[0-9]{1,5}:[0-9a-f]{64}$ ||
           "${target_journal_token}" =~ ^committed:[0-9a-f]{24}:[0-9a-f]{64}$ ]] ||
          err_exit "The prepared target journal handoff token is invalid."
        GUILD_SOURCE_TARGET_JOURNAL_ADMITTED="Y"
        GUILD_SOURCE_TARGET_JOURNAL_TOKEN="${target_journal_token}"
        ;;
      *) err_exit "The prepared target journal handoff marker is invalid." ;;
    esac
  elif [[ "${source_handoff}" != "N" ]]; then
    err_exit "Invalid Guild source handoff marker."
  else
    # Caller-provided target recovery authority is never trusted. Phase 1
    # derives a new exact marker/token only after inspecting the target.
    GUILD_SOURCE_TARGET_JOURNAL_ADMITTED="N"
    GUILD_SOURCE_TARGET_JOURNAL_TOKEN=""
  fi

  NODE_IMPLEMENTATION_EXPLICIT="N"
  NETWORK_EXPLICIT="N"
  NETWORK_PRESET="N"
  NODE_NAME_EXPLICIT="N"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  G_ACCOUNT_PRESET="N"
  GUILD_SOURCE_MODE_PRESET="N"
  NODE_PORT_PRESET="N"
  LEGACY_CNODE_TARGET="N"
  DISPATCHER_LOCK_TARGET="Y"
  S_ARGS="${S_ARGS:-}"
  [[ -n "${BRANCH:-}" ]] && BRANCH_PRESET="Y"
  [[ -n "${NETWORK:-}" ]] && NETWORK_PRESET="Y"
  [[ -n "${G_ACCOUNT:-}" ]] && G_ACCOUNT_PRESET="Y"
  [[ -n "${GUILD_SOURCE_MODE:-}" ]] && GUILD_SOURCE_MODE_PRESET="Y"
  [[ -n "${NODE_PORT:-}" ]] && NODE_PORT_PRESET="Y"
  if [[ "${source_handoff}" == "Y" ]]; then
    G_ACCOUNT_PRESET="${requested_account_preset:-N}"
    BRANCH_PRESET="${requested_branch_preset:-N}"
    NETWORK_PRESET="${requested_network_preset:-N}"
    GUILD_SOURCE_MODE_PRESET="${requested_mode_preset:-N}"
    NODE_PORT_PRESET="${requested_node_port_preset:-N}"
  fi
  OPTIND=1

  while getopts ":i:n:p:t:s:b:a:S:L:E:DRuh" opt; do
    case "${opt}" in
      i)
        NODE_IMPLEMENTATION="${OPTARG}"
        NODE_IMPLEMENTATION_EXPLICIT="Y"
        ;;
      n)
        NETWORK="${OPTARG}"
        NETWORK_EXPLICIT="Y"
        ;;
      p) NODE_PARENT="${OPTARG}" ;;
      t)
        NODE_NAME="${OPTARG}"
        NODE_NAME_EXPLICIT="Y"
        ;;
      s) S_ARGS="${OPTARG}" ;;
      b)
        BRANCH="${OPTARG}"
        BRANCH_EXPLICIT="Y"
        ;;
      a)
        G_ACCOUNT="${OPTARG}"
        G_ACCOUNT_PRESET="Y"
        ;;
      S)
        GUILD_SOURCE_MODE="${OPTARG}"
        GUILD_SOURCE_MODE_PRESET="Y"
        ;;
      L) GUILD_SOURCE_CHECKOUT="${OPTARG}" ;;
      E) GUILD_DOCKER_EXPORT_ROOT="${OPTARG}" ;;
      D) GUILD_SOURCE_ALLOW_DIRTY="Y" ;;
      R) GUILD_SOURCE_ALLOW_REPOSITORY_CHANGE="Y" ;;
      u) UPDATE_CHECK="N" ;;
      h)
        dispatcher_usage
        return 0
        ;;
      :)
        err_exit "Option -${OPTARG} requires an argument."
        ;;
      \?)
        dispatcher_usage >&2
        err_exit "Unknown option -${OPTARG}."
        ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ $# -eq 0 ]] || err_exit "Unexpected positional arguments: $*"

  # Help is intentionally available without deployment tools. Every real run
  # validates source and receipt tooling before source preparation, target
  # locking, recovery, directory creation, or payload mutation.
  dispatcher_validate_bootstrap_prerequisites

  if [[ "${source_handoff}" != "Y" ]]; then
    DISPATCHER_LOCK_TARGET="N"
    dispatcher_set_defaults
    dispatcher_prepare_source_and_handoff "${original_args[@]}"
    return $?
  fi

  DISPATCHER_LOCK_TARGET="Y"
  dispatcher_set_defaults
  dispatcher_verify_target_fingerprint
  dispatcher_update_check

  printf "\n%sGuild Operators deployment%s\n" "${STYLE_BOLD}" "${STYLE_RESET}"
  printf "  Implementation : %s\n" "${NODE_IMPLEMENTATION}"
  printf "  Target         : %s\n" "${NODE_HOME}"
  printf "  Network        : %s\n" "${NETWORK:-not selected}"
  printf "  Branch         : %s\n" "${BRANCH}"
  printf "  Flags          : %s\n" "${S_ARGS:-script/config refresh}"

  PROFILE_MANAGED="Y"
  export PROFILE_MANAGED
  dispatcher_load_profile
  # Reject every pre-existing symlink or non-directory in the selected
  # implementation's layout before candidate rendering can read through it or
  # the profile can perform any privileged layout mutation.
  dispatcher_validate_profile_layout ||
    err_exit "The ${NODE_IMPLEMENTATION} target contains an unsafe directory layout."
  dispatcher_distribution_prepare ||
    err_exit "Could not stage and validate the complete ${NODE_IMPLEMENTATION} Guild payload."
  "${PROFILE_ENTRYPOINT}" ||
    err_exit "${NODE_IMPLEMENTATION} deployment profile failed."
  [[ "${DISPATCHER_TX_ACTIVATED:-N}" == "Y" ]] ||
    err_exit "${NODE_IMPLEMENTATION} profile returned without activating the prepared Guild payload."
  dispatcher_write_manifest deployed
  if ! dispatcher_cntools_generation_prune_after_commit; then
    log_warn "Could not prune one or more unreferenced CNTools generations; preserved them for inspection."
  fi
  dispatcher_cntools_generation_lock_release ||
    err_exit "Could not release the committed CNTools generation transaction lock."
  dispatcher_docker_export_supplement ||
    err_exit "Could not export the Docker supplement from the prepared Guild revision."

  printf "\n%sDeployment finished%s\n" "${STYLE_GREEN}${STYLE_BOLD}" "${STYLE_RESET}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  guild_deploy_main "$@"
fi
