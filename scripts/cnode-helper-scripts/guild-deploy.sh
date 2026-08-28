#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2154,SC2317,SC2329
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
#SUDO="Y"                            # Set to N in containers already running as root
#PACKAGE_MANAGER_OUTPUT="compact"    # compact | verbose
#
# cnode-specific variables
#CNODE_SKIP_DBSYNC_DOWNLOAD="N"      # Skip cardano-db-sync when using cnode -s d
#CNODE_SKIP_HARDWARE_WALLET_RULES="N" # Skip host udev rules when using cnode -s w
######################################
# Do NOT modify code below           #
######################################

export LANG="C.UTF-8"
export LC_ALL="${LANG}"
GUILD_DEPLOY_SNAPSHOT_CAPABLE="Y"

DISPATCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER_SCRIPT_PATH="${DISPATCHER_DIR}/$(basename "${BASH_SOURCE[0]}")"

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

	Usage: $(basename "$0") [-g account] [-i <cnode|dingo|amaru>] [-n <network>] [-p path] [-t name] [-b branch] [-s flags]

	Common Guild Operators deployment entrypoint.

	-g    GitHub account that owns the Guild Operators repository (Default: stored deployment account, then cardano-community)
	-i    Node implementation (Default: cnode)
	-n    Network. cnode defaults to mainnet; alternate implementations require an explicit supported network
	-p    Parent path below which the top-level folder is created (Default: /opt/cardano)
	-t    Alternate top-level folder/service name (Default: selected implementation)
	-b    Guild Operators repository branch (Default: stored deployment branch, then master)
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
	Set GUILD_DEPLOY_STRICT_REF=Y to reject a missing selected ref instead
	of falling back to master.

	Examples:
	  ./guild-deploy.sh -n mainnet -s pd
	  ./guild-deploy.sh -g my-guild-fork -n mainnet
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

dispatcher_source_relative_path_valid() {
  local relative_path="${1:-}"
  local component
  local -a components

  [[ -n "${relative_path}" &&
     "${relative_path}" != /* &&
     "${relative_path}" != *$'\n'* &&
     "${relative_path}" != *$'\r'* ]] || return 1
  IFS='/' read -r -a components <<< "${relative_path}"
  for component in "${components[@]}"; do
    [[ -n "${component}" &&
       "${component}" != "." &&
       "${component}" != ".." ]] || return 1
  done
}

dispatcher_source_path() {
  local relative_path="${1:-}"
  local current_path="${GIT_SOURCE_ROOT:-}"
  local component
  local repository_root=""
  local source_root=""
  local -a components

  dispatcher_source_relative_path_valid "${relative_path}" || return 2
  [[ -n "${current_path}" &&
     "${current_path}" = /* &&
     -d "${current_path}" &&
     ! -L "${current_path}" ]] || return 2
  source_root="$(cd -- "${current_path}" && pwd -P)" || return 2
  current_path="${source_root}"

  IFS='/' read -r -a components <<< "${relative_path}"
  for component in "${components[@]}"; do
    current_path="${current_path}/${component}"
    [[ ! -L "${current_path}" ]] || return 2
  done
  [[ -f "${current_path}" ]] || return 1
  repository_root="$(git -C "${source_root}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "${repository_root}" && "${repository_root}" = "${source_root}" ]]; then
    git -C "${source_root}" ls-files --error-unmatch \
      -- "${relative_path}" >/dev/null 2>&1 || return 2
  fi
  printf '%s\n' "${current_path}"
}

# Resolve a tracked source directory without following symbolic links. Directory
# payloads are kept separate from dispatcher_source_path so regular file
# callers retain their deliberately small contract.
dispatcher_source_directory() {
  local relative_path="${1:-}"
  local current_path="${GIT_SOURCE_ROOT:-}"
  local component
  local repository_root=""
  local source_root=""
  local -a components

  dispatcher_source_relative_path_valid "${relative_path}" || return 2
  [[ -n "${current_path}" &&
     "${current_path}" = /* &&
     -d "${current_path}" &&
     ! -L "${current_path}" ]] || return 2
  source_root="$(cd -- "${current_path}" && pwd -P)" || return 2
  current_path="${source_root}"

  IFS='/' read -r -a components <<< "${relative_path}"
  for component in "${components[@]}"; do
    current_path="${current_path}/${component}"
    [[ ! -L "${current_path}" ]] || return 2
  done
  [[ -d "${current_path}" ]] || return 1
  repository_root="$(git -C "${source_root}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "${repository_root}" && "${repository_root}" = "${source_root}" ]]; then
    [[ -n "$(git -C "${source_root}" ls-files -- "${relative_path}")" ]] || return 2
  fi
  printf '%s\n' "${current_path}"
}

dispatcher_source_copy() {
  local relative_path="${1:-}"
  local destination="${2:-}"
  local source_path=""

  [[ -n "${destination}" ]] || return 2
  source_path="$(dispatcher_source_path "${relative_path}")" || {
    log_warn "Guild source payload is missing or unsafe: ${relative_path:-empty path}"
    return 1
  }
  cp -- "${source_path}" "${destination}"
}

dispatcher_preflight_source_payloads() {
  local relative_path=""
  local source_path=""

  for relative_path in "$@"; do
    source_path="$(dispatcher_source_path "${relative_path}")" || {
      log_warn "Required Guild source payload is missing or unsafe: ${relative_path}"
      return 1
    }
    [[ -s "${source_path}" ]] || {
      log_warn "Required Guild source payload is empty: ${relative_path}"
      return 1
    }
  done
}

dispatcher_preflight_shell_payloads() {
  local relative_path=""
  local source_path=""
  local bash_bin="${GUILD_DEPLOY_PREFLIGHT_BASH_BIN:-bash}"

  for relative_path in "$@"; do
    source_path="$(dispatcher_source_path "${relative_path}")" || {
      log_warn "Required Guild shell payload is missing or unsafe: ${relative_path}"
      return 1
    }
    [[ -s "${source_path}" ]] || {
      log_warn "Required Guild shell payload is empty: ${relative_path}"
      return 1
    }
    "${bash_bin}" -n "${source_path}" || {
      log_warn "Required Guild shell payload failed validation: ${relative_path}"
      return 1
    }
  done
}

dispatcher_preflight_json_payloads() {
  local relative_path=""
  local source_path=""

  command -v jq >/dev/null 2>&1 || {
    log_warn "jq is required to validate Guild JSON payloads; re-run with -s p."
    return 1
  }
  for relative_path in "$@"; do
    source_path="$(dispatcher_source_path "${relative_path}")" || {
      log_warn "Required Guild JSON payload is missing or unsafe: ${relative_path}"
      return 1
    }
    jq -e 'type == "object"' "${source_path}" >/dev/null 2>&1 || {
      log_warn "Required Guild JSON payload failed validation: ${relative_path}"
      return 1
    }
  done
}

dispatcher_validate_cntools_tree() {
  local tree="${1:-}"
  local require_tracked="${2:-N}"
  local bash_bin="${GUILD_DEPLOY_PREFLIGHT_BASH_BIN:-bash}"
  local source_root="${GIT_SOURCE_ROOT:-}"
  local repository_root=""
  local entry=""
  local relative_path=""
  local source_tree_relative=""
  local tracked_found="N"
  local version=""
  local -a required_files required_directories retired_files

  case "${require_tracked}" in
    Y|N) ;;
    *) return 2 ;;
  esac
  [[ -n "${tree}" && "${tree}" = /* && -d "${tree}" && ! -L "${tree}" ]] || {
    log_warn "The CNTools source tree is missing or unsafe."
    return 1
  }
  tree="$(cd -- "${tree}" && pwd -P)" || return 1
  [[ -x "${bash_bin}" ]] || command -v "${bash_bin}" >/dev/null 2>&1 || {
    log_warn "Bash is required to validate CNTools."
    return 1
  }
  "${bash_bin}" -c '
    (( BASH_VERSINFO[0] > 4 ||
       (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) ))
  ' >/dev/null 2>&1 || {
    log_warn "Bash 4.4 or newer is required to run CNTools."
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    log_warn "jq is required to validate CNTools; re-run with -s p."
    return 1
  }

  required_directories=(
    core
    lib
    modules
    modules/root
  )
  required_files=(
    VERSION
    cntools_main.sh
    core/action.sh
    core/gum.sh
    core/health.sh
    core/log.sh
    core/menu.sh
    core/startup.sh
    core/update.sh
    modules/root/module.json
  )
  retired_files=(
    cntools.sh
    cntools_gum.sh
    core/ui.sh
  )
  for relative_path in "${required_directories[@]}"; do
    [[ -d "${tree}/${relative_path}" && ! -L "${tree}/${relative_path}" ]] || {
      log_warn "Required CNTools directory is missing or unsafe: ${relative_path}"
      return 1
    }
  done
  for relative_path in "${required_files[@]}"; do
    [[ -f "${tree}/${relative_path}" &&
       ! -L "${tree}/${relative_path}" &&
       -s "${tree}/${relative_path}" ]] || {
      log_warn "Required CNTools file is missing, empty, or unsafe: ${relative_path}"
      return 1
    }
  done
  for relative_path in "${retired_files[@]}"; do
    [[ ! -e "${tree}/${relative_path}" &&
       ! -L "${tree}/${relative_path}" ]] || {
      log_warn "Retired CNTools file is still present: ${relative_path}"
      return 1
    }
  done

  if [[ "${require_tracked}" = "Y" ]]; then
    [[ -n "${source_root}" && -d "${source_root}" && ! -L "${source_root}" ]] || return 1
    source_root="$(cd -- "${source_root}" && pwd -P)" || return 1
    repository_root="$(git -C "${source_root}" rev-parse --show-toplevel 2>/dev/null)" || return 1
    repository_root="$(cd -- "${repository_root}" && pwd -P)" || return 1
    [[ "${repository_root}" = "${source_root}" &&
       "${tree}" == "${source_root}/"* ]] || return 1
    source_tree_relative="${tree#"${source_root}"/}"
    git -C "${source_root}" diff --quiet --no-ext-diff \
      -- "${source_tree_relative}" || {
      log_warn "CNTools contains modified or deleted tracked files."
      return 1
    }
    git -C "${source_root}" diff --cached --quiet --no-ext-diff \
      -- "${source_tree_relative}" || {
      log_warn "CNTools contains staged tracked changes."
      return 1
    }
    while IFS= read -r -d '' relative_path; do
      tracked_found="Y"
      entry="${source_root}/${relative_path}"
      [[ -f "${entry}" && ! -L "${entry}" && -s "${entry}" ]] || {
        log_warn "CNTools tracked payload is missing, empty, or unsafe: ${relative_path#"${source_tree_relative}"/}"
        return 1
      }
    done < <(git -C "${source_root}" ls-files -z -- "${source_tree_relative}")
    [[ "${tracked_found}" = "Y" ]] || return 1
  fi

  while IFS= read -r -d '' entry; do
    relative_path="${entry#"${tree}"/}"
    [[ "${entry}" != "${tree}" &&
       -n "${relative_path}" &&
       "${relative_path}" != *$'\n'* &&
       "${relative_path}" != *$'\r'* ]] || {
      log_warn "CNTools contains an unsafe path."
      return 1
    }
    if [[ -L "${entry}" ]]; then
      log_warn "CNTools must not contain symbolic links: ${relative_path}"
      return 1
    elif [[ -d "${entry}" ]]; then
      :
    elif [[ -f "${entry}" ]]; then
      [[ -s "${entry}" ]] || {
        log_warn "CNTools contains an empty file: ${relative_path}"
        return 1
      }
      if [[ "${require_tracked}" = "Y" ]]; then
        git -C "${source_root}" ls-files --error-unmatch \
          -- "${entry#"${source_root}"/}" >/dev/null 2>&1 || {
          log_warn "CNTools contains an untracked file: ${relative_path}"
          return 1
        }
      fi
    else
      log_warn "CNTools contains an unsupported filesystem entry: ${relative_path}"
      return 1
    fi
  done < <(find "${tree}" -mindepth 1 -print0)

  version="$(< "${tree}/VERSION")"
  [[ "$(awk 'END { print NR }' "${tree}/VERSION")" = "1" &&
     "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
    log_warn "CNTools VERSION must contain one semantic version."
    return 1
  }

  while IFS= read -r -d '' entry; do
    "${bash_bin}" -n "${entry}" >/dev/null 2>&1 || {
      log_warn "CNTools shell validation failed: ${entry#"${tree}"/}"
      return 1
    }
  done < <(find "${tree}" -type f -name '*.sh' -print0)
  while IFS= read -r -d '' entry; do
    jq -e 'type == "object"' "${entry}" >/dev/null 2>&1 || {
      log_warn "CNTools metadata validation failed: ${entry#"${tree}"/}"
      return 1
    }
  done < <(find "${tree}/modules" -type f -name 'module.json' -print0)

  # shellcheck disable=SC2016
  "${bash_bin}" -c '
    tree="$1"
    CNTOOLS_MODULE_ROOT="${tree}/modules/root"
    CNTOOLS_LIB_DIR="${tree}/lib"
    CNTOOLS_VALIDATION_BASH="$2"
    source "${tree}/core/menu.sh"
    cntools_menu_validate_tree
  ' _ "${tree}" "${bash_bin}" >/dev/null 2>&1 || {
    log_warn "CNTools menu tree failed semantic validation."
    return 1
  }
}

dispatcher_preflight_cntools_tree() {
  local source_directory=""

  source_directory="$(
    dispatcher_source_directory 'scripts/common-helper-scripts/cntools'
  )" || {
    log_warn "The CNTools source directory is missing or unsafe."
    return 1
  }
  dispatcher_validate_cntools_tree "${source_directory}" Y
}

dispatcher_preflight_cntools_launcher() {
  dispatcher_preflight_shell_payloads \
    'scripts/common-helper-scripts/cntools.sh'
}

dispatcher_target_state_token() {
  local manifest_path="${1:-${DEPLOYMENT_FILE:-}}"
  local checksum_output=""

  [[ -n "${manifest_path}" ]] || return 2
  if [[ -L "${manifest_path}" ]]; then
    return 2
  elif [[ -e "${manifest_path}" ]]; then
    [[ -f "${manifest_path}" && -r "${manifest_path}" ]] || return 2
    checksum_output="$(cksum < "${manifest_path}")" || return 2
    [[ "${checksum_output}" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]] || return 2
    printf 'file:%s-%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf 'absent\n'
  fi
}

dispatcher_snapshot_revision() {
  local source_root="${1:-${GIT_SOURCE_ROOT:-}}"
  local revision=""

  revision="$(git -C "${source_root}" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" ||
    return 1
  [[ "${revision}" =~ ^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$ ]] || return 1
  printf '%s\n' "${revision}" | tr '[:upper:]' '[:lower:]'
}

dispatcher_validate_snapshot() {
  local source_root="${1:-}"
  local expected_dispatcher=""
  local profile_path=""
  local repository_root=""

  command -v git >/dev/null 2>&1 ||
    err_exit "Git is required. Install Git and re-run guild-deploy.sh."
  [[ -n "${source_root}" && -d "${source_root}" && ! -L "${source_root}" ]] ||
    err_exit "The prepared Guild Operators source snapshot is unavailable."
  source_root="$(cd -- "${source_root}" && pwd -P)" ||
    err_exit "Could not resolve the Guild Operators source snapshot."
  repository_root="$(git -C "${source_root}" rev-parse --show-toplevel 2>/dev/null)" ||
    err_exit "The prepared source snapshot is not a Git checkout."
  repository_root="$(cd -- "${repository_root}" && pwd -P)" ||
    err_exit "Could not resolve the prepared Git checkout."
  [[ "${repository_root}" = "${source_root}" ]] ||
    err_exit "The prepared source snapshot has an unexpected repository root."
  git -C "${source_root}" diff --quiet --no-ext-diff -- ||
    err_exit "The prepared source snapshot contains modified tracked files."
  git -C "${source_root}" diff --cached --quiet --no-ext-diff -- ||
    err_exit "The prepared source snapshot contains staged tracked changes."

  GIT_SOURCE_ROOT="${source_root}"
  GUILD_SOURCE_REVISION="$(dispatcher_snapshot_revision "${source_root}")" ||
    err_exit "Could not resolve the source snapshot revision."
  expected_dispatcher="$(dispatcher_source_path 'scripts/cnode-helper-scripts/guild-deploy.sh')" ||
    err_exit "The source snapshot does not contain a safe guild-deploy.sh."
  grep -qx 'GUILD_DEPLOY_SNAPSHOT_CAPABLE="Y"' "${expected_dispatcher}" ||
    err_exit "The selected branch predates snapshot deployment. Run its matching historical guild-deploy.sh instead."
  dispatcher_source_path 'LICENSE' >/dev/null ||
    err_exit "The source snapshot does not contain a safe LICENSE file."
  profile_path="$(dispatcher_source_path "$(dispatcher_profile_relative_path)")" ||
    err_exit "The source snapshot does not contain the selected deployment profile."
  bash -n "${expected_dispatcher}" ||
    err_exit "The source snapshot guild-deploy.sh failed shell validation."
  bash -n "${profile_path}" ||
    err_exit "The selected deployment profile failed shell validation."
  export GIT_SOURCE_ROOT GUILD_SOURCE_REVISION
}

dispatcher_adopt_snapshot() {
  local source_root=""

  source_root="$(cd -- "${DISPATCHER_DIR}/../.." && pwd -P)" ||
    err_exit "Could not resolve the source snapshot used to run guild-deploy.sh."
  dispatcher_validate_snapshot "${source_root}"
  dispatcher_validate_prepared_dispatcher "${DISPATCHER_SCRIPT_PATH}"
}

dispatcher_clone_snapshot() {
  local branch="${1:-}"
  local repository_url="${2:-}"
  local destination="${3:-}"

  GIT_TERMINAL_PROMPT=0 git -c advice.detachedHead=false \
    clone --quiet --depth 1 --single-branch --no-tags \
    --branch "${branch}" "${repository_url}" "${destination}"
}

dispatcher_remote_ref_status() {
  local ref_name="${1:-}"
  local repository_url="${2:-}"

  GIT_TERMINAL_PROMPT=0 git ls-remote --quiet --exit-code --refs \
    "${repository_url}" \
    "refs/heads/${ref_name}" \
    "refs/tags/${ref_name}" >/dev/null 2>&1
}

dispatcher_compose_snapshot_dispatcher() {
  local source_file="${1:-}"
  local staged_file=""
  local runtime_body=""

  [[ -n "${GUILD_DEPLOY_USER_HEADER:-}" &&
     -f "${source_file}" &&
     ! -L "${source_file}" ]] ||
    err_exit "Could not preserve the local guild-deploy.sh user header."
  [[ "$(grep -c '^# Do NOT modify code below' "${source_file}" 2>/dev/null)" = "1" ]] ||
    err_exit "The source snapshot guild-deploy.sh has an invalid user-variable boundary."
  runtime_body="$(awk '/^# Do NOT modify code below/{copy=1} copy' "${source_file}")"
  [[ -n "${runtime_body}" ]] ||
    err_exit "Could not read the source snapshot guild-deploy.sh runtime."

  staged_file="$(mktemp "$(dirname "${source_file}")/.guild-deploy.sh.prepared.XXXXXX")" ||
    err_exit "Could not stage the source snapshot guild-deploy.sh."
  if ! printf '%s\n%s\n' "${GUILD_DEPLOY_USER_HEADER}" "${runtime_body}" > "${staged_file}" ||
     ! bash -n "${staged_file}" ||
     ! chmod 0755 "${staged_file}"; then
    rm -f -- "${staged_file}"
    err_exit "Could not compose a validated source snapshot guild-deploy.sh."
  fi
  SNAPSHOT_DISPATCHER_PATH="${staged_file}"
}

dispatcher_validate_prepared_dispatcher() {
  local prepared_file="${1:-}"
  local source_file="${GIT_SOURCE_ROOT}/scripts/cnode-helper-scripts/guild-deploy.sh"
  local prepared_header=""
  local prepared_runtime=""
  local source_runtime=""

  [[ -f "${prepared_file}" && ! -L "${prepared_file}" &&
     "$(dirname "${prepared_file}")" = "${GIT_SOURCE_ROOT}/scripts/cnode-helper-scripts" ]] ||
    err_exit "Snapshot mode requires a prepared guild-deploy.sh inside the source checkout."
  case "$(basename "${prepared_file}")" in
    .guild-deploy.sh.prepared.*) ;;
    *) err_exit "Snapshot mode received an unexpected dispatcher path." ;;
  esac
  prepared_header="$(dispatcher_extract_user_header "${prepared_file}")" ||
    err_exit "The prepared guild-deploy.sh has an invalid user-variable header."
  [[ "${prepared_header}" = "${GUILD_DEPLOY_USER_HEADER:-}" ]] ||
    err_exit "The prepared guild-deploy.sh did not preserve the invoking user header."
  prepared_runtime="$(awk '/^# Do NOT modify code below/{copy=1} copy' "${prepared_file}")"
  source_runtime="$(awk '/^# Do NOT modify code below/{copy=1} copy' "${source_file}")"
  [[ -n "${prepared_runtime}" && "${prepared_runtime}" = "${source_runtime}" ]] ||
    err_exit "The prepared guild-deploy.sh runtime does not match the source snapshot."
  bash -n "${prepared_file}" ||
    err_exit "The prepared guild-deploy.sh failed shell validation."
}

dispatcher_prepare_snapshot() {
  local repository_url=""
  local snapshot_dispatcher=""
  local child_status=0
  local remote_ref_status=0
  local -a original_args=("$@")

  command -v git >/dev/null 2>&1 ||
    err_exit "Git is required. Install Git and re-run guild-deploy.sh."
  GUILD_SOURCE_TMP_DIR="$(
    umask 077
    mktemp -d "${TMPDIR:-/tmp}/guild-operators-source.XXXXXX"
  )" || err_exit "Could not create a temporary source directory."
  DISPATCHER_SOURCE_TMP_OWNED="Y"
  GIT_SOURCE_ROOT="${GUILD_SOURCE_TMP_DIR}/repository"
  GUILD_SOURCE_TMP_DIR="$(cd -- "${GUILD_SOURCE_TMP_DIR}" && pwd -P)" ||
    err_exit "Could not resolve the temporary source directory."
  GIT_SOURCE_ROOT="${GUILD_SOURCE_TMP_DIR}/repository"
  chmod 0700 "${GUILD_SOURCE_TMP_DIR}" ||
    err_exit "Could not secure the temporary source directory."
  repository_url="https://github.com/${G_ACCOUNT}/guild-operators.git"

  log_progress "Preparing Guild Operators source snapshot" "${G_ACCOUNT}/${BRANCH}"
  if ! dispatcher_clone_snapshot "${BRANCH}" "${repository_url}" "${GIT_SOURCE_ROOT}"; then
    if [[ "${BRANCH}" = "master" ]]; then
      err_exit "Could not clone ${G_ACCOUNT}/guild-operators branch master."
    fi
    if dispatcher_remote_ref_status "${BRANCH}" "${repository_url}"; then
      err_exit "Could not clone ${G_ACCOUNT}/guild-operators branch '${BRANCH}', although the remote ref exists."
    else
      remote_ref_status=$?
    fi
    [[ "${remote_ref_status}" -eq 2 ]] ||
      err_exit "Could not verify ${G_ACCOUNT}/guild-operators branch '${BRANCH}' after the clone failed."
    if [[ "${GUILD_DEPLOY_STRICT_REF:-N}" = "Y" ]]; then
      err_exit "Guild repository ref '${BRANCH}' was not found; strict ref selection prevents fallback to master."
    fi
    log_warn "Branch '${BRANCH}' was not found; falling back to master."
    [[ "${GIT_SOURCE_ROOT}" = "${GUILD_SOURCE_TMP_DIR}/repository" ]] ||
      err_exit "Refusing to clear an unexpected source checkout path."
    rm -rf -- "${GIT_SOURCE_ROOT}"
    BRANCH="master"
    URL_RAW="${REPO_RAW}/${BRANCH}"
    export BRANCH URL_RAW
    dispatcher_clone_snapshot "${BRANCH}" "${repository_url}" "${GIT_SOURCE_ROOT}" ||
      err_exit "Could not clone ${G_ACCOUNT}/guild-operators branch master."
  fi

  dispatcher_validate_snapshot "${GIT_SOURCE_ROOT}"
  snapshot_dispatcher="$(dispatcher_source_path 'scripts/cnode-helper-scripts/guild-deploy.sh')" ||
    err_exit "Could not locate guild-deploy.sh in the prepared source snapshot."
  dispatcher_compose_snapshot_dispatcher "${snapshot_dispatcher}"
  snapshot_dispatcher="${SNAPSHOT_DISPATCHER_PATH}"
  dispatcher_validate_prepared_dispatcher "${snapshot_dispatcher}"
  log_ok "Source snapshot ready" "${GUILD_SOURCE_REVISION:0:12}"

  if GUILD_DEPLOY_SNAPSHOT_STAGE="ready" \
     GUILD_DEPLOY_SOURCE_ACCOUNT="${G_ACCOUNT}" \
     GUILD_DEPLOY_SOURCE_BRANCH="${BRANCH}" \
     GUILD_DEPLOY_SOURCE_REVISION="${GUILD_SOURCE_REVISION}" \
     GUILD_DEPLOY_TARGET_PATH="${GUILD_DEPLOY_TARGET_PATH:-}" \
     GUILD_DEPLOY_TARGET_STATE_TOKEN="${GUILD_DEPLOY_TARGET_STATE_TOKEN:-}" \
     GUILD_DEPLOY_USER_HEADER="${GUILD_DEPLOY_USER_HEADER:-}" \
     bash "${snapshot_dispatcher}" "${original_args[@]}"; then
    child_status=0
  else
    child_status=$?
  fi
  return "${child_status}"
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
      log_warn "Staged common runtime member failed validation: ${target_name}"
      return 2
    fi
  done

  for (( i = 0; i < bundle_count - 1; i++ )); do
    cp -- "${downloads[i]}" "${candidates[i]}" || return 2
  done

  if [[ "${force_scripts}" != "Y" && -f "${targets[5]}" ]] &&
     grep -q '^# Do NOT modify code below' "${targets[5]}" 2>/dev/null &&
     grep -q '^# Do NOT modify code below' "${downloads[5]}" 2>/dev/null; then
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

dispatcher_cntools_copy_tree() {
  cp -R -- "$1/." "$2/"
}

dispatcher_cntools_move_tree() {
  mv -- "$1" "$2"
}

# Install the complete CNTools directory as a single generation. The old tree
# is kept inside the same-filesystem staging directory until the candidate has
# been installed and revalidated, which permits rollback on every failure.
dispatcher_install_cntools_tree() (
  local source_directory=""
  local scripts_directory="${NODE_HOME:-}/scripts"
  local target_directory="${NODE_HOME:-}/scripts/cntools"
  local stage_root=""
  local candidate_directory=""
  local previous_directory=""
  local target_lock_acquired="N"
  local target_existed="N"
  local previous_moved="N"
  local candidate_moved="N"
  local transaction_active="N"

  _dispatcher_cntools_safe_remove() {
    local remove_path="${1:-}"

    if [[ -n "${stage_root}" &&
          "${remove_path}" = "${stage_root}" &&
          "$(dirname "${remove_path}")" = "${scripts_directory}" &&
          "$(basename "${remove_path}")" == .cntools-install.* &&
          -d "${remove_path}" &&
          ! -L "${remove_path}" ]]; then
      rm -rf -- "${remove_path}"
    elif [[ "${remove_path}" = "${target_directory}" &&
            -d "${remove_path}" &&
            ! -L "${remove_path}" ]]; then
      rm -rf -- "${remove_path}"
    else
      return 1
    fi
  }

  _dispatcher_cntools_permissions_valid() {
    local cntools_tree="${1:-}"

    [[ -n "${cntools_tree}" &&
       -d "${cntools_tree}" &&
       ! -L "${cntools_tree}" &&
       -z "$(find "${cntools_tree}" -type d ! -perm 0755 -print -quit)" &&
       -z "$(find "${cntools_tree}" -type f \
         ! -path "${cntools_tree}/cntools_main.sh" \
         ! -perm 0644 -print -quit)" &&
       -n "$(find "${cntools_tree}/cntools_main.sh" -prune \
         -type f -perm 0755 -print)" ]]
  }

  _dispatcher_cntools_cleanup() {
    local saved_status="${1:-$?}"
    local cleanup_stage="Y"

    trap - EXIT HUP INT QUIT TERM
    if [[ "${transaction_active}" = "Y" ]]; then
      if [[ "${candidate_moved}" = "Y" &&
            ! -e "${candidate_directory}" &&
            ! -L "${candidate_directory}" &&
            ( -e "${target_directory}" || -L "${target_directory}" ) ]]; then
        _dispatcher_cntools_safe_remove "${target_directory}" || {
          log_warn "Could not remove an invalid CNTools candidate during rollback."
          cleanup_stage="N"
        }
      fi
      if [[ "${previous_moved}" = "Y" &&
            -d "${previous_directory}" &&
            ! -L "${previous_directory}" ]]; then
        if [[ -e "${target_directory}" || -L "${target_directory}" ]]; then
          log_warn "Could not restore the previous CNTools tree because the target is occupied; recovery copy remains at ${previous_directory}."
          cleanup_stage="N"
        elif ! command mv -- "${previous_directory}" "${target_directory}"; then
          log_warn "Could not restore the previous CNTools tree from ${previous_directory}."
          cleanup_stage="N"
        fi
      fi
    fi
    if [[ "${cleanup_stage}" = "Y" &&
          -n "${stage_root}" && -d "${stage_root}" ]]; then
      _dispatcher_cntools_safe_remove "${stage_root}" ||
        log_warn "Could not remove CNTools staging directory ${stage_root}."
    fi
    if [[ "${target_lock_acquired}" = "Y" ]]; then
      deployment_target_lock_release
    fi
    return "${saved_status}"
  }

  trap '_dispatcher_cntools_cleanup "$?"' EXIT
  trap 'exit 2' HUP INT QUIT TERM

  [[ -n "${NODE_HOME:-}" &&
     "${NODE_HOME}" = /* &&
     -d "${NODE_HOME}" &&
     ! -L "${NODE_HOME}" &&
     -d "${scripts_directory}" &&
     ! -L "${scripts_directory}" ]] || {
    log_warn "The CNTools target layout is missing or unsafe."
    return 2
  }
  deployment_target_lock_acquire "${NODE_HOME}" || return 2
  target_lock_acquired="Y"
  if [[ -e "${target_directory}" || -L "${target_directory}" ]]; then
    [[ -d "${target_directory}" &&
       ! -L "${target_directory}" &&
       -O "${target_directory}" ]] || {
      log_warn "The installed CNTools target is not a safe owned directory."
      return 2
    }
    target_existed="Y"
  fi

  source_directory="$(
    dispatcher_source_directory 'scripts/common-helper-scripts/cntools'
  )" || {
    log_warn "The CNTools source directory is missing or unsafe."
    return 2
  }
  dispatcher_validate_cntools_tree "${source_directory}" Y || return 2

  stage_root="$(mktemp -d "${scripts_directory}/.cntools-install.XXXXXX")" || return 2
  [[ "$(dirname "${stage_root}")" = "${scripts_directory}" &&
     "$(basename "${stage_root}")" == .cntools-install.* &&
     -d "${stage_root}" &&
     ! -L "${stage_root}" &&
     -O "${stage_root}" ]] || return 2
  candidate_directory="${stage_root}/candidate"
  previous_directory="${stage_root}/previous"
  mkdir "${candidate_directory}" || return 2

  dispatcher_cntools_copy_tree "${source_directory}" "${candidate_directory}" || {
    log_warn "Could not stage the CNTools source tree."
    return 2
  }
  dispatcher_validate_cntools_tree "${candidate_directory}" N || return 2
  find "${candidate_directory}" -type d -exec chmod 0755 {} + || return 2
  find "${candidate_directory}" -type f -exec chmod 0644 {} + || return 2
  chmod 0755 "${candidate_directory}/cntools_main.sh" || return 2
  _dispatcher_cntools_permissions_valid "${candidate_directory}" || {
    log_warn "Could not normalize CNTools file permissions."
    return 2
  }
  dispatcher_validate_cntools_tree "${candidate_directory}" N || return 2

  transaction_active="Y"
  if [[ "${target_existed}" = "Y" ]]; then
    previous_moved="Y"
    dispatcher_cntools_move_tree "${target_directory}" "${previous_directory}" || {
      log_warn "Could not stage the previous CNTools installation."
      return 2
    }
  fi
  candidate_moved="Y"
  dispatcher_cntools_move_tree "${candidate_directory}" "${target_directory}" || {
    log_warn "Could not install the staged CNTools tree."
    return 2
  }
  dispatcher_validate_cntools_tree "${target_directory}" N || return 2
  _dispatcher_cntools_permissions_valid "${target_directory}" || return 2
  transaction_active="N"
  return 0
)

# Replace the public CNTools entrypoint only after a complete modular tree is
# installed. Existing legacy files are archived before the exact launcher is
# moved into place, so a failed post-install check can restore the prior state.
dispatcher_install_cntools_launcher() (
  local scripts_directory="${NODE_HOME:-}/scripts"
  local target_tree="${NODE_HOME:-}/scripts/cntools"
  local target_launcher="${NODE_HOME:-}/scripts/cntools.sh"
  local legacy_library="${NODE_HOME:-}/scripts/cntools.library"
  local archive_directory="${NODE_HOME:-}/scripts/archive"
  local bash_bin="${GUILD_DEPLOY_PREFLIGHT_BASH_BIN:-bash}"
  local source_launcher=""
  local candidate_launcher=""
  local archive_launcher=""
  local archive_library=""
  local restore_tmp=""
  local target_lock_acquired="N"
  local target_existed="N"
  local library_existed="N"
  local launcher_changed="N"
  local launcher_installed="N"
  local library_retired="N"
  local transaction_active="N"

  _dispatcher_cntools_launcher_rollback() {
    local rollback_ok="Y"

    # Restore the library before the old launcher. If library recovery fails,
    # keep the new launcher active rather than restoring an unusable monolith.
    if [[ "${library_retired}" = "Y" &&
          "${library_existed}" = "Y" ]]; then
      if [[ -f "${legacy_library}" && ! -L "${legacy_library}" ]]; then
        library_retired="N"
      elif [[ -e "${legacy_library}" || -L "${legacy_library}" ]]; then
        rollback_ok="N"
      else
        restore_tmp="$(mktemp "${scripts_directory}/.cntools.library.restore.XXXXXX")" ||
          rollback_ok="N"
        if [[ -n "${restore_tmp}" ]] &&
           cp -p -- "${archive_library}" "${restore_tmp}" &&
           mv -f -- "${restore_tmp}" "${legacy_library}"; then
          restore_tmp=""
          library_retired="N"
        else
          [[ -n "${restore_tmp}" ]] && rm -f -- "${restore_tmp}"
          rollback_ok="N"
        fi
      fi
    fi
    if [[ "${launcher_installed}" = "Y" && "${rollback_ok}" = "Y" ]]; then
      if [[ "${target_existed}" = "Y" ]]; then
        restore_tmp="$(mktemp "${scripts_directory}/.cntools.sh.restore.XXXXXX")" ||
          rollback_ok="N"
        if [[ -n "${restore_tmp}" ]] &&
           cp -p -- "${archive_launcher}" "${restore_tmp}" &&
           mv -f -- "${restore_tmp}" "${target_launcher}"; then
          restore_tmp=""
        else
          [[ -n "${restore_tmp}" ]] && rm -f -- "${restore_tmp}"
          rollback_ok="N"
        fi
      elif ! rm -f -- "${target_launcher}"; then
        rollback_ok="N"
      fi
    fi
    [[ "${rollback_ok}" = "Y" ]]
  }

  _dispatcher_cntools_launcher_cleanup() {
    local saved_status="${1:-$?}"

    trap - EXIT HUP INT QUIT TERM
    if [[ "${transaction_active}" = "Y" ]]; then
      _dispatcher_cntools_launcher_rollback ||
        log_warn "Could not completely restore the previous CNTools launcher state."
    fi
    [[ -n "${candidate_launcher}" ]] && rm -f -- "${candidate_launcher}"
    [[ -n "${restore_tmp}" ]] && rm -f -- "${restore_tmp}"
    if [[ "${target_lock_acquired}" = "Y" ]]; then
      deployment_target_lock_release
    fi
    return "${saved_status}"
  }

  trap '_dispatcher_cntools_launcher_cleanup "$?"' EXIT
  trap 'exit 2' HUP INT QUIT TERM

  source_launcher="$(
    dispatcher_source_path 'scripts/common-helper-scripts/cntools.sh'
  )" || {
    log_warn "The CNTools launcher source is missing or unsafe."
    return 2
  }
  dispatcher_preflight_cntools_launcher || return 2
  [[ -n "${NODE_HOME:-}" &&
     "${NODE_HOME}" = /* &&
     -d "${NODE_HOME}" &&
     ! -L "${NODE_HOME}" &&
     -d "${scripts_directory}" &&
     ! -L "${scripts_directory}" ]] || {
    log_warn "The CNTools launcher target layout is missing or unsafe."
    return 2
  }

  deployment_target_lock_acquire "${NODE_HOME}" || return 2
  target_lock_acquired="Y"
  dispatcher_validate_cntools_tree "${target_tree}" N || {
    log_warn "The installed CNTools tree is unavailable or invalid."
    return 2
  }
  if [[ -e "${target_launcher}" || -L "${target_launcher}" ]]; then
    [[ -f "${target_launcher}" &&
       ! -L "${target_launcher}" &&
       -s "${target_launcher}" ]] || {
      log_warn "The installed CNTools launcher is not a safe regular file."
      return 2
    }
    target_existed="Y"
  fi
  if [[ -e "${legacy_library}" || -L "${legacy_library}" ]]; then
    [[ -f "${legacy_library}" &&
       ! -L "${legacy_library}" &&
       -s "${legacy_library}" ]] || {
      log_warn "The installed legacy CNTools library is not a safe regular file."
      return 2
    }
    library_existed="Y"
  fi
  if [[ -e "${archive_directory}" || -L "${archive_directory}" ]]; then
    [[ -d "${archive_directory}" &&
       ! -L "${archive_directory}" ]] || {
      log_warn "The CNTools archive directory is unsafe."
      return 2
    }
  else
    mkdir -m 0755 -- "${archive_directory}" || return 2
  fi

  candidate_launcher="$(mktemp "${scripts_directory}/.cntools.sh.install.XXXXXX")" ||
    return 2
  cp -- "${source_launcher}" "${candidate_launcher}" || return 2
  chmod 0755 "${candidate_launcher}" || return 2
  "${bash_bin}" -n "${candidate_launcher}" >/dev/null 2>&1 || return 2

  if [[ "${target_existed}" = "N" ]] ||
     ! cmp -s "${candidate_launcher}" "${target_launcher}" ||
     [[ -z "$(find "${target_launcher}" -prune -perm 0755 -print)" ]]; then
    launcher_changed="Y"
  fi
  if [[ "${launcher_changed}" = "N" &&
        "${library_existed}" = "N" ]]; then
    return 0
  fi

  if [[ "${launcher_changed}" = "Y" &&
        "${target_existed}" = "Y" ]]; then
    archive_launcher="$(
      mktemp "${archive_directory}/cntools.sh_bkp$(date +%s).XXXXXX"
    )" || return 2
    cp -p -- "${target_launcher}" "${archive_launcher}" || return 2
  fi
  if [[ "${library_existed}" = "Y" ]]; then
    archive_library="$(
      mktemp "${archive_directory}/cntools.library_bkp$(date +%s).XXXXXX"
    )" || return 2
    cp -p -- "${legacy_library}" "${archive_library}" || return 2
  fi

  transaction_active="Y"
  if [[ "${launcher_changed}" = "Y" ]]; then
    mv -f -- "${candidate_launcher}" "${target_launcher}" || return 2
    candidate_launcher=""
    launcher_installed="Y"
    "${bash_bin}" -n "${target_launcher}" >/dev/null 2>&1 || return 2
    cmp -s "${source_launcher}" "${target_launcher}" || return 2
    [[ -n "$(find "${target_launcher}" -prune -perm 0755 -print)" ]] ||
      return 2
  fi
  if [[ "${library_existed}" = "Y" ]]; then
    library_retired="Y"
    rm -f -- "${legacy_library}" || return 2
    [[ ! -e "${legacy_library}" && ! -L "${legacy_library}" ]] || return 2
  fi
  transaction_active="N"
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
  [[ -z "${GUILD_DEPLOY_STRICT_REF:-}" ]] && GUILD_DEPLOY_STRICT_REF="N"
  [[ -z "${CURL_TIMEOUT:-}" ]] && CURL_TIMEOUT=60
  [[ -z "${DOWNLOAD_TIMEOUT:-}" ]] && DOWNLOAD_TIMEOUT=600
  [[ -z "${SUDO:-}" ]] && SUDO="Y"
  [[ -z "${PACKAGE_MANAGER_OUTPUT:-}" ]] && PACKAGE_MANAGER_OUTPUT="compact"
  case "${PACKAGE_MANAGER_OUTPUT}" in
    compact|verbose) ;;
    *) err_exit "PACKAGE_MANAGER_OUTPUT must be compact or verbose." ;;
  esac
  case "${GUILD_DEPLOY_STRICT_REF}" in
    Y|N) ;;
    *) err_exit "GUILD_DEPLOY_STRICT_REF must be Y or N." ;;
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

  [[ -z "${CNODE_SKIP_HARDWARE_WALLET_RULES:-}" ]] &&
    CNODE_SKIP_HARDWARE_WALLET_RULES="N"
  case "${CNODE_SKIP_HARDWARE_WALLET_RULES}" in
    Y|N) ;;
    *) err_exit "CNODE_SKIP_HARDWARE_WALLET_RULES must be Y or N." ;;
  esac

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
      ((has("sourceRevision") | not) or
        (.sourceRevision | type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$"))) and
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

  export G_ACCOUNT GUILD_DEPLOY_STRICT_REF
  export CURL_TIMEOUT DOWNLOAD_TIMEOUT SUDO sudo
  export PACKAGE_MANAGER_OUTPUT
  export NODE_IMPLEMENTATION NODE_PARENT NODE_NAME NODE_HOME NODE_SERVICE
  export NODE_PORT NETWORK BRANCH REPO_RAW URL_RAW S_ARGS
  if [[ "${NODE_IMPLEMENTATION}" = "cnode" ]]; then
    export CNODE_SKIP_DBSYNC_DOWNLOAD CNODE_SKIP_HARDWARE_WALLET_RULES
  else
    unset CNODE_SKIP_DBSYNC_DOWNLOAD CNODE_SKIP_HARDWARE_WALLET_RULES
  fi

  # Compatibility aliases used by the current cnode implementation profile.
  CNODE_PATH="${NODE_PARENT}"
  CNODE_NAME="${NODE_NAME}"
  CNODE_HOME="${NODE_HOME}"
  CNODE_VNAME="${NODE_SERVICE}"
  export CNODE_PATH CNODE_NAME CNODE_HOME CNODE_VNAME
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
  PROFILE_PATH="$(dispatcher_source_path "${relative_path}")" ||
    err_exit "Could not load ${relative_path} from the prepared source snapshot."
  log_progress "Loading ${NODE_IMPLEMENTATION} deployment profile" "${BRANCH}"

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

dispatcher_extract_user_header() {
  local source_file="${1:-}"

  [[ -f "${source_file}" ]] || return 1
  [[ "$(grep -c '^# Do NOT modify code below' "${source_file}" 2>/dev/null)" = "1" ]] ||
    return 1
  awk '/^#!/{copy=1} /^# Do NOT modify code below/{exit} copy' "${source_file}"
}

dispatcher_install_self() {
  local source_file=""
  local target_file="${NODE_HOME}/scripts/guild-deploy.sh"
  local archive_dir="${NODE_HOME}/scripts/archive"
  local staged_file=""
  local user_header=""
  local runtime_body=""

  source_file="$(dispatcher_source_path 'scripts/cnode-helper-scripts/guild-deploy.sh')" ||
    err_exit "Could not stage guild-deploy.sh from the prepared source snapshot."
  [[ -d "${NODE_HOME}/scripts" ]] ||
    err_exit "Deployment profile completed without creating ${NODE_HOME}/scripts."
  if [[ -L "${target_file}" ||
        ( -e "${target_file}" && ! -f "${target_file}" ) ]]; then
    err_exit "Refusing to replace unsafe dispatcher target ${target_file}."
  fi

  if [[ -f "${target_file}" ]]; then
    user_header="$(dispatcher_extract_user_header "${target_file}")" ||
      err_exit "Installed guild-deploy.sh has an invalid user-variable header."
  elif [[ -n "${GUILD_DEPLOY_USER_HEADER:-}" ]]; then
    user_header="${GUILD_DEPLOY_USER_HEADER}"
  else
    user_header="$(dispatcher_extract_user_header "${source_file}")" ||
      err_exit "Source guild-deploy.sh has an invalid user-variable header."
  fi
  runtime_body="$(awk '/^# Do NOT modify code below/{copy=1} copy' "${source_file}")"
  [[ -n "${user_header}" && -n "${runtime_body}" ]] ||
    err_exit "Could not prepare the installed guild-deploy.sh."

  staged_file="$(mktemp "${NODE_HOME}/scripts/.guild-deploy.sh.install.XXXXXX")" ||
    err_exit "Could not create dispatcher installation staging file."
  if ! printf '%s\n%s\n' "${user_header}" "${runtime_body}" > "${staged_file}" ||
     ! bash -n "${staged_file}" ||
     ! chmod 0755 "${staged_file}"; then
    rm -f -- "${staged_file}"
    err_exit "Could not validate the installed guild-deploy.sh candidate."
  fi

  if [[ -f "${target_file}" ]] &&
     cmp -s "${target_file}" "${staged_file}" &&
     [[ -n "$(find "${target_file}" -prune -perm 0755 -print)" ]]; then
    rm -f -- "${staged_file}"
    log_ok "guild-deploy.sh is current" "${target_file}"
    return 0
  fi

  mkdir -p "${archive_dir}" || {
    rm -f -- "${staged_file}"
    err_exit "Could not create the dispatcher archive directory."
  }
  if [[ -f "${target_file}" ]]; then
    cp -p -- "${target_file}" \
      "${archive_dir}/guild-deploy.sh_bkp$(date +%s).$$" || {
      rm -f -- "${staged_file}"
      err_exit "Could not archive the installed guild-deploy.sh."
    }
  fi
  mv -f -- "${staged_file}" "${target_file}" || {
    rm -f -- "${staged_file}"
    err_exit "Could not atomically install guild-deploy.sh."
  }
  log_ok "guild-deploy.sh installed" "${target_file}"
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
    if [[ -n "${GUILD_SOURCE_REVISION:-}" ]]; then
      printf '  "sourceRevision": "%s",\n' "$(dispatcher_json_escape "${GUILD_SOURCE_REVISION}")"
    fi
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
  if [[ "${DISPATCHER_SOURCE_TMP_OWNED:-N}" = "Y" &&
        -n "${GUILD_SOURCE_TMP_DIR:-}" &&
        "${GIT_SOURCE_ROOT:-}" = "${GUILD_SOURCE_TMP_DIR}/repository" &&
        "$(basename "${GUILD_SOURCE_TMP_DIR}")" = guild-operators-source.* &&
        -d "${GUILD_SOURCE_TMP_DIR}" &&
        ! -L "${GUILD_SOURCE_TMP_DIR}" ]]; then
    rm -rf -- "${GUILD_SOURCE_TMP_DIR}"
  fi
  dispatcher_release_target_lock
}

guild_deploy_main() {
  local snapshot_stage="${GUILD_DEPLOY_SNAPSHOT_STAGE:-bootstrap}"
  local resolved_source_account="${GUILD_DEPLOY_SOURCE_ACCOUNT:-}"
  local resolved_source_branch="${GUILD_DEPLOY_SOURCE_BRANCH:-}"
  local expected_source_revision="${GUILD_DEPLOY_SOURCE_REVISION:-}"
  local expected_target_path="${GUILD_DEPLOY_TARGET_PATH:-}"
  local expected_target_state="${GUILD_DEPLOY_TARGET_STATE_TOKEN:-}"
  local current_target_state=""
  local inherited_user_header="${GUILD_DEPLOY_USER_HEADER:-}"
  local -a original_args=("$@")

  # Never trust source or cleanup paths inherited from the caller's environment.
  unset GUILD_DEPLOY_SNAPSHOT_STAGE GUILD_DEPLOY_SOURCE_ACCOUNT
  unset GUILD_DEPLOY_SOURCE_BRANCH GUILD_DEPLOY_SOURCE_REVISION
  unset GUILD_DEPLOY_TARGET_PATH
  unset GUILD_DEPLOY_TARGET_STATE_TOKEN
  unset GUILD_DEPLOY_USER_HEADER
  GIT_SOURCE_ROOT=""
  GUILD_SOURCE_REVISION=""
  GUILD_SOURCE_TMP_DIR=""
  DISPATCHER_SOURCE_TMP_OWNED="N"
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
  DISPATCHER_LOCK_TARGET="N"
  S_ARGS="${S_ARGS:-}"
  [[ -n "${BRANCH:-}" ]] && BRANCH_PRESET="Y"
  [[ -n "${NETWORK:-}" ]] && NETWORK_PRESET="Y"
  [[ -n "${G_ACCOUNT:-}" ]] && G_ACCOUNT_PRESET="Y"
  OPTIND=1

  while getopts ":g:i:n:p:t:s:b:h" opt; do
    case "${opt}" in
      g)
        G_ACCOUNT="${OPTARG}"
        G_ACCOUNT_PRESET="Y"
        ;;
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

  case "${snapshot_stage}" in
    bootstrap)
      GUILD_DEPLOY_USER_HEADER="$(dispatcher_extract_user_header "${DISPATCHER_SCRIPT_PATH}")" ||
        err_exit "The running guild-deploy.sh has an invalid user-variable header."
      DISPATCHER_LOCK_TARGET="Y"
      ;;
    ready)
      validate_account_name "${resolved_source_account}" ||
        err_exit "The prepared source snapshot has an invalid repository account."
      validate_branch_name "${resolved_source_branch}" ||
        err_exit "The prepared source snapshot has an invalid branch."
      [[ "${expected_source_revision}" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] ||
        err_exit "The prepared source snapshot has an invalid expected revision."
      G_ACCOUNT="${resolved_source_account}"
      BRANCH="${resolved_source_branch}"
      G_ACCOUNT_PRESET="Y"
      BRANCH_PRESET="Y"
      GUILD_DEPLOY_USER_HEADER="${inherited_user_header}"
      [[ -n "${expected_target_path}" &&
         "${expected_target_path}" = /* &&
         "${expected_target_path}" != *$'\n'* &&
         "${expected_target_path}" != *$'\r'* ]] ||
        err_exit "The prepared source snapshot has an invalid target path."
      [[ "${expected_target_state}" = "absent" ||
         "${expected_target_state}" =~ ^file:[0-9]+-[0-9]+$ ]] ||
        err_exit "The prepared source snapshot has invalid target-state metadata."
      DISPATCHER_LOCK_TARGET="Y"
      ;;
    *)
      err_exit "Invalid internal Guild source snapshot stage."
      ;;
  esac

  dispatcher_set_defaults
  if [[ "${snapshot_stage}" = "bootstrap" ]]; then
    GUILD_DEPLOY_TARGET_PATH="${DISPATCHER_LOCK_CANONICAL_TARGET}"
    GUILD_DEPLOY_TARGET_STATE_TOKEN="$(dispatcher_target_state_token "${DEPLOYMENT_FILE}")" ||
      err_exit "Could not record the deployment state before preparing the source snapshot."
    export GUILD_DEPLOY_TARGET_PATH GUILD_DEPLOY_TARGET_STATE_TOKEN
    dispatcher_release_target_lock
    dispatcher_prepare_snapshot "${original_args[@]}"
    return $?
  fi
  [[ "${DISPATCHER_LOCK_CANONICAL_TARGET}" = "${expected_target_path}" ]] ||
    err_exit "The deployment target path changed while its source snapshot was prepared. Re-run guild-deploy.sh."
  current_target_state="$(dispatcher_target_state_token "${DEPLOYMENT_FILE}")" ||
    err_exit "Could not verify the deployment state after preparing the source snapshot."
  [[ "${current_target_state}" = "${expected_target_state}" ]] ||
    err_exit "The deployment target changed while its source snapshot was prepared. Re-run guild-deploy.sh."
  dispatcher_adopt_snapshot
  [[ "${GUILD_SOURCE_REVISION}" = "${expected_source_revision}" ]] ||
    err_exit "The prepared source snapshot revision changed before deployment."

  printf "\n%sGuild Operators deployment%s\n" "${STYLE_BOLD}" "${STYLE_RESET}"
  printf "  Implementation : %s\n" "${NODE_IMPLEMENTATION}"
  printf "  Target         : %s\n" "${NODE_HOME}"
  printf "  Network        : %s\n" "${NETWORK:-not selected}"
  printf "  Branch         : %s\n" "${BRANCH}"
  printf "  Source         : %s\n" "${GUILD_SOURCE_REVISION:0:12}"
  printf "  Flags          : %s\n" "${S_ARGS:-script/config refresh}"

  PROFILE_MANAGED="Y"
  export PROFILE_MANAGED
  dispatcher_load_profile
  "${PROFILE_ENTRYPOINT}" ||
    err_exit "${NODE_IMPLEMENTATION} deployment profile failed."
  dispatcher_install_self
  dispatcher_write_manifest deployed

  printf "\n%sDeployment finished%s\n" "${STYLE_GREEN}${STYLE_BOLD}" "${STYLE_RESET}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  guild_deploy_main "$@"
fi
