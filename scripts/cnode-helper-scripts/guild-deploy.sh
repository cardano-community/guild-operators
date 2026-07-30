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

	Usage: $(basename "$0") [-i <cnode|dingo|amaru>] [-n <network>] [-p path] [-t name] [-b branch] [-u] [-s flags]

	Common Guild Operators deployment entrypoint.

	-i    Node implementation (Default: cnode)
	-n    Network. cnode defaults to mainnet; alternate implementations require an explicit supported network
	-p    Parent path below which the top-level folder is created (Default: /opt/cardano)
	-t    Alternate top-level folder/service name (Default: selected implementation)
	-b    Guild Operators repository branch (Default: stored deployment branch, then master)
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

dispatcher_target_lock_is_owned() {
  local requested_target="${1:-}"
  local canonical_target
  canonical_target="$(dispatcher_canonical_target_path "${requested_target}")" ||
    return 1
  [[ "${DISPATCHER_LOCK_CANONICAL_TARGET:-}" = "${canonical_target}" &&
     "${DISPATCHER_LOCK_OWNER_PID:-}" = "$$" ]] || return 1

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
      [[ -n "${DISPATCHER_LOCK_PATH:-}" &&
         -d "${DISPATCHER_LOCK_PATH}" &&
         ! -L "${DISPATCHER_LOCK_PATH}" &&
         -O "${DISPATCHER_LOCK_PATH}" ]] || return 1
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

  lock_key="$(dispatcher_lock_key "${canonical_target}")" ||
    err_exit "Unable to derive the deployment lock key."
  if command -v flock >/dev/null 2>&1; then
    DISPATCHER_LOCK_PATH="${lock_base}/${lock_key}.lock"
    if [[ -L "${DISPATCHER_LOCK_PATH}" ]] ||
       { [[ -e "${DISPATCHER_LOCK_PATH}" ]] && [[ ! -O "${DISPATCHER_LOCK_PATH}" ]]; }; then
      err_exit "Unsafe deployment lock file: ${DISPATCHER_LOCK_PATH}"
    fi
    if ! exec 9>"${DISPATCHER_LOCK_PATH}"; then
      err_exit "Unable to open deployment lock ${DISPATCHER_LOCK_PATH}."
    fi
    if ! flock -n 9; then
      exec 9>&-
      err_exit "Another deployment or branch update is active for ${NODE_HOME}."
    fi
    DISPATCHER_LOCK_KIND="flock"
  else
    DISPATCHER_LOCK_PATH="${lock_base}/${lock_key}.lock.d"
    if ! mkdir "${DISPATCHER_LOCK_PATH}" 2>/dev/null; then
      err_exit "Another deployment or branch update is active for ${NODE_HOME}, or a stale lock exists at ${DISPATCHER_LOCK_PATH}."
    fi
    DISPATCHER_LOCK_KIND="directory"
  fi
  DISPATCHER_LOCK_CANONICAL_TARGET="${canonical_target}"
  DISPATCHER_LOCK_OWNER_PID="$$"
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
      rmdir "${DISPATCHER_LOCK_PATH}" 2>/dev/null || true
      ;;
  esac
  DISPATCHER_LOCK_KIND=""
  DISPATCHER_LOCK_PATH=""
  DISPATCHER_LOCK_CANONICAL_TARGET=""
  DISPATCHER_LOCK_OWNER_PID=""
  unset GUILD_DEPLOY_LOCK_HELD_FOR
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
       ! bash -n "${downloads[i]}" >/dev/null 2>&1; then
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
  if ! bash -n "${candidates[5]}" >/dev/null 2>&1; then
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
  case "${PACKAGE_MANAGER_OUTPUT}" in
    compact|verbose) ;;
    *) err_exit "PACKAGE_MANAGER_OUTPUT must be compact or verbose." ;;
  esac

  [[ -z "${NODE_IMPLEMENTATION:-}" ]] && NODE_IMPLEMENTATION="${CNODE_IMPLEMENTATION:-cnode}"
  validate_implementation "${NODE_IMPLEMENTATION}" || err_exit "Unknown node implementation '${NODE_IMPLEMENTATION}'. Expected cnode, dingo, or amaru."

  if [[ -z "${NODE_PORT:-}" ]]; then
    case "${NODE_IMPLEMENTATION}" in
      cnode) NODE_PORT=6000 ;;
      dingo) NODE_PORT=3001 ;;
      amaru) NODE_PORT=3000 ;;
    esac
  fi
  if [[ ! "${NODE_PORT}" =~ ^[0-9]+$ ]] ||
     (( 10#${NODE_PORT} < 1 || 10#${NODE_PORT} > 65535 )); then
    err_exit "NODE_PORT must be an integer from 1 to 65535."
  fi
  NODE_PORT="$((10#${NODE_PORT}))"
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
  [[ "${NODE_SERVICE}" =~ ^[a-z0-9_]+$ ]] ||
    err_exit "The computed service name is invalid: ${NODE_SERVICE}"
  DEPLOYMENT_FILE="${NODE_HOME}/.deployment.json"
  if [[ "${DISPATCHER_LOCK_TARGET:-N}" = "Y" ]]; then
    dispatcher_acquire_target_lock
  fi

  local stored_implementation=""
  local stored_network=""
  local stored_branch=""
  local stored_schema=""
  local stored_status=""
  local stored_repository=""
  local stored_service=""
  local stored_account=""
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
        (.implementation == "cnode" and
          .metricsProvider == "prometheus" and
          .capabilities.n2c == true and
          .capabilities.localCli == true and
          .capabilities.metrics == true and
          .capabilities.forging == true) or
        (.implementation == "dingo" and
          .metricsProvider == "prometheus" and
          .capabilities.n2c == true and
          .capabilities.localCli == false and
          .capabilities.metrics == true and
          .capabilities.forging == false) or
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
  elif [[ -d "${NODE_HOME}" ]] && find "${NODE_HOME}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    local detected_network=""
    if partial_target_matches_implementation; then
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

  [[ "${SUDO}" = "Y" ]] && sudo="sudo" || sudo=""
  if [[ "${SUDO}" = "Y" && "$(id -u)" -eq 0 ]]; then
    err_exit "Please run as a non-root user, or set SUDO=N for a controlled container build."
  fi

  REPO_RAW="https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators"
  URL_RAW="${REPO_RAW}/${BRANCH}"

  export G_ACCOUNT CURL_TIMEOUT DOWNLOAD_TIMEOUT UPDATE_CHECK SUDO sudo
  export PACKAGE_MANAGER_OUTPUT
  export NODE_IMPLEMENTATION NODE_PARENT NODE_NAME NODE_HOME NODE_SERVICE
  export NODE_PORT NETWORK BRANCH REPO_RAW URL_RAW S_ARGS
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

dispatcher_validate_branch() {
  if curl -sSf -m "${CURL_TIMEOUT}" "${REPO_RAW}/${BRANCH}/LICENSE" -o /dev/null 2>/dev/null; then
    return 0
  fi
  if [[ "${BRANCH}" != "master" ]]; then
    log_warn "Branch '${BRANCH}' was not found; falling back to master."
    BRANCH="master"
    URL_RAW="${REPO_RAW}/${BRANCH}"
    export BRANCH URL_RAW
    curl -sSf -m "${CURL_TIMEOUT}" "${URL_RAW}/LICENSE" -o /dev/null 2>/dev/null ||
      err_exit "Unable to reach ${G_ACCOUNT}/guild-operators."
  else
    err_exit "Unable to reach ${G_ACCOUNT}/guild-operators branch master."
  fi
}

dispatcher_update_check() {
  [[ "${UPDATE_CHECK}" = "Y" ]] || return 0
  [[ "${DISPATCHER_LOCAL_REPO}" = "Y" ]] && return 0

  local current_script
  local current_dir
  local current_name
  local downloaded_script
  local merged_script
  local backup_script
  local existing_user
  local new_code
  current_script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  current_dir="$(dirname "${current_script}")"
  current_name="$(basename "${current_script}")"
  downloaded_script="$(mktemp "${current_dir}/.${current_name}.download.XXXXXX")" ||
    err_exit "Unable to create dispatcher update staging file."
  merged_script="$(mktemp "${current_dir}/.${current_name}.merged.XXXXXX")" || {
    rm -f -- "${downloaded_script}"
    err_exit "Unable to create dispatcher update merge file."
  }

  log_progress "Checking guild-deploy.sh update" "${BRANCH}"
  if ! curl -sSf -m "${CURL_TIMEOUT}" \
    -o "${downloaded_script}" \
    "${URL_RAW}/scripts/cnode-helper-scripts/guild-deploy.sh"; then
    rm -f -- "${downloaded_script}" "${merged_script}"
    log_warn "Could not check for a dispatcher update; continuing with the current copy."
    return 0
  fi

  if [[ ! -s "${downloaded_script}" ]] ||
     ! grep -q '^# Do NOT modify code below' "${downloaded_script}" ||
     ! bash -n "${downloaded_script}"; then
    rm -f -- "${downloaded_script}" "${merged_script}"
    err_exit "Downloaded guild-deploy.sh failed validation."
  fi

  if cmp -s "${current_script}" "${downloaded_script}"; then
    rm -f -- "${downloaded_script}" "${merged_script}"
    log_ok "guild-deploy.sh is current"
    return 0
  fi

  existing_user="$(awk '/^#!/{copy=1} /^# Do NOT modify/{exit} copy' "${current_script}")"
  new_code="$(awk '/^# Do NOT modify code below/{copy=1} copy' "${downloaded_script}")"
  if [[ -z "${existing_user}" || -z "${new_code}" ]] ||
     ! printf '%s\n%s\n' "${existing_user}" "${new_code}" > "${merged_script}" ||
     ! bash -n "${merged_script}" ||
     ! chmod 0755 "${merged_script}"; then
    rm -f -- "${downloaded_script}" "${merged_script}"
    err_exit "Unable to prepare a validated guild-deploy.sh update."
  fi

  if cmp -s "${current_script}" "${merged_script}"; then
    rm -f -- "${downloaded_script}" "${merged_script}"
    log_ok "guild-deploy.sh is current"
    return 0
  fi

  backup_script="${current_script}_bkp$(date +%s).$$"
  if ! cp -p -- "${current_script}" "${backup_script}"; then
    rm -f -- "${downloaded_script}" "${merged_script}"
    err_exit "Unable to back up the current guild-deploy.sh."
  fi
  if ! mv -f -- "${merged_script}" "${current_script}"; then
    rm -f -- "${downloaded_script}" "${merged_script}"
    err_exit "Unable to atomically replace guild-deploy.sh; the current copy is unchanged."
  fi
  rm -f -- "${downloaded_script}"
  log_ok "Updated guild-deploy.sh" "run it again"
  exit 0
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
  PROFILE_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/guild-deploy-profile.XXXXXX")" ||
    err_exit "Unable to create a temporary profile directory."
  DISPATCHER_PROFILE_TMP_OWNED="Y"
  PROFILE_PATH="${PROFILE_TMP_DIR}/$(basename "${relative_path}")"
  log_progress "Downloading ${NODE_IMPLEMENTATION} deployment profile" "${BRANCH}"
  curl -sSf -m "${CURL_TIMEOUT}" -o "${PROFILE_PATH}" "${URL_RAW}/${relative_path}" ||
    err_exit "Could not download ${relative_path}."

  if ! bash -n "${PROFILE_PATH}"; then
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

dispatcher_capability_default() {
  local capability="$1"
  case "${NODE_IMPLEMENTATION}:${capability}" in
    cnode:n2c|cnode:local_cli|cnode:metrics|cnode:forging) printf 'true' ;;
    dingo:n2c|dingo:metrics) printf 'true' ;;
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

dispatcher_write_manifest() {
  local deployment_status="${1:-deployed}"
  [[ -d "${NODE_HOME}" ]] || err_exit "Deployment profile completed without creating ${NODE_HOME}."
  case "${deployment_status}" in
    deploying|deployed) ;;
    *) err_exit "Invalid deployment status '${deployment_status}'." ;;
  esac

  local node_version
  local manifest_tmp
  local cap_n2c
  local cap_local_cli
  local cap_metrics
  local cap_forging
  local metrics_provider
  local target_node_version
  node_version="$(dispatcher_detect_node_version)"
  target_node_version="${PROFILE_TARGET_NODE_VERSION:-}"
  manifest_tmp="$(mktemp "${NODE_HOME}/.deployment.json.tmp.XXXXXX")" ||
    err_exit "Unable to create a temporary deployment manifest in ${NODE_HOME}."
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
    printf '  "repository": "%s/guild-operators",\n' "$(dispatcher_json_escape "${G_ACCOUNT}")"
    printf '  "serviceName": "%s",\n' "$(dispatcher_json_escape "${NODE_SERVICE}")"
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

  if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "${manifest_tmp}" >/dev/null 2>&1; then
      rm -f -- "${manifest_tmp}"
      err_exit "Generated deployment manifest is invalid."
    fi
  fi
  if ! chmod 644 "${manifest_tmp}"; then
    rm -f -- "${manifest_tmp}"
    err_exit "Unable to set deployment manifest permissions."
  fi

  if [[ "${deployment_status}" = "deployed" && -f "${NODE_HOME}/scripts/.env_branch" ]]; then
    if ! mkdir -p "${NODE_HOME}/scripts/archive"; then
      rm -f -- "${manifest_tmp}"
      err_exit "Unable to create the legacy branch archive directory."
    fi
    if ! mv -f -- "${NODE_HOME}/scripts/.env_branch" \
      "${NODE_HOME}/scripts/archive/.env_branch_migrated_$(date +%s).$$"; then
      rm -f -- "${manifest_tmp}"
      err_exit "Unable to archive the legacy scripts/.env_branch file."
    fi
  fi
  if ! mv -f -- "${manifest_tmp}" "${DEPLOYMENT_FILE}"; then
    rm -f -- "${manifest_tmp}"
    err_exit "Unable to atomically replace ${DEPLOYMENT_FILE}."
  fi
  if [[ "${deployment_status}" = "deployed" ]]; then
    log_ok "Deployment metadata updated" "${DEPLOYMENT_FILE}"
  fi
}

dispatcher_mark_in_progress() {
  dispatcher_write_manifest deploying
}

cleanup_dispatcher() {
  if [[ "${DISPATCHER_PROFILE_TMP_OWNED:-N}" = "Y" &&
        -n "${PROFILE_TMP_DIR:-}" &&
        -d "${PROFILE_TMP_DIR}" ]]; then
    rm -rf -- "${PROFILE_TMP_DIR}"
  fi
  dispatcher_release_target_lock
}

guild_deploy_main() {
  # Never trust cleanup paths inherited from the caller's environment.
  PROFILE_TMP_DIR=""
  DISPATCHER_PROFILE_TMP_OWNED="N"
  unset GUILD_DEPLOY_LOCK_HELD_FOR
  unset DISPATCHER_LOCK_KIND DISPATCHER_LOCK_PATH
  unset DISPATCHER_LOCK_CANONICAL_TARGET DISPATCHER_LOCK_OWNER_PID
  unset PROFILE_PATH PROFILE_ENTRYPOINT PROFILE_TARGET_NODE_VERSION
  unset PROFILE_METRICS_PROVIDER PROFILE_CAP_N2C PROFILE_CAP_LOCAL_CLI
  unset PROFILE_CAP_METRICS PROFILE_CAP_FORGING
  trap cleanup_dispatcher EXIT

  NODE_IMPLEMENTATION_EXPLICIT="N"
  NETWORK_EXPLICIT="N"
  NETWORK_PRESET="N"
  NODE_NAME_EXPLICIT="N"
  BRANCH_EXPLICIT="N"
  BRANCH_PRESET="N"
  G_ACCOUNT_PRESET="N"
  LEGACY_CNODE_TARGET="N"
  DISPATCHER_LOCK_TARGET="Y"
  S_ARGS="${S_ARGS:-}"
  [[ -n "${BRANCH:-}" ]] && BRANCH_PRESET="Y"
  [[ -n "${NETWORK:-}" ]] && NETWORK_PRESET="Y"
  [[ -n "${G_ACCOUNT:-}" ]] && G_ACCOUNT_PRESET="Y"
  OPTIND=1

  while getopts ":i:n:p:t:s:b:uh" opt; do
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

  dispatcher_set_defaults
  dispatcher_validate_branch
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
  "${PROFILE_ENTRYPOINT}" ||
    err_exit "${NODE_IMPLEMENTATION} deployment profile failed."
  dispatcher_write_manifest deployed

  printf "\n%sDeployment finished%s\n" "${STYLE_GREEN}${STYLE_BOLD}" "${STYLE_RESET}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  guild_deploy_main "$@"
fi
