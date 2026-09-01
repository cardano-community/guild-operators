#!/usr/bin/env bash
# Charm Gum prerequisite, Koios-inspired presentation and menu navigation.
# Functions only; sourced by the CNTools entrypoint.
# shellcheck disable=SC2034,SC2153

CNTOOLS_GUM_REQUIRED_VERSION="2.0.0"
CNTOOLS_GUM_RELEASE_ROOT="https://github.com/charmbracelet/gum/releases/download/v${CNTOOLS_GUM_REQUIRED_VERSION}"
CNTOOLS_GUM_SHA256_X86_64="c99b0005bb5b514770eea404b24c7987e08eba35bb0b2d7bc6545bb676c36861"
CNTOOLS_GUM_SHA256_ARM64="ed51e91457a48f5681f67dd925bd40eb1794d41d1f48cf1d7e19e2517b7fac76"
CNTOOLS_GUM_BIN="${CNTOOLS_GUM_BIN:-}"
CNTOOLS_GUM_INSTALL_TMP=""
CNTOOLS_GUM_INSTALL_STAGE=""
CNTOOLS_GUM_LAST_HEADER_ROWS=""
CNTOOLS_GUM_LAST_HEADER_MODE=""
CNTOOLS_GUM_STATIC_HEADER_KEY=""
CNTOOLS_GUM_STATIC_HEADER_TITLE=""
CNTOOLS_GUM_STATIC_HEADER_RUNTIME=""
CNTOOLS_GUM_HEALTH_FRAGMENT_KEY=""
CNTOOLS_GUM_HEALTH_FRAGMENT=""
declare -Ag CNTOOLS_GUM_BREADCRUMB_KEYS=()
declare -Ag CNTOOLS_GUM_BREADCRUMB_FRAGMENTS=()
declare -Ag CNTOOLS_GUM_HEADER_RENDER_KEYS=()
declare -Ag CNTOOLS_GUM_HEADER_RENDERED=()
declare -Ag CNTOOLS_GUM_HEADER_RENDER_ROWS=()
declare -Ag CNTOOLS_GUM_MENU_ROW_KEYS=()
declare -Ag CNTOOLS_GUM_MENU_ROWS=()

# Gum subtracts its help and vertical padding from the explicit filter height
# to size the choice viewport. The input is already part of the rendered
# widget, and Gum v2's complete frame occupies one row less than the requested
# height, so the final available terminal row can safely be used by a choice.
CNTOOLS_GUM_HEADER_ROWS=6
CNTOOLS_GUM_STATUS_ROWS=4
CNTOOLS_GUM_UPDATE_SUMMARY_ROWS=5
CNTOOLS_GUM_FILTER_CHROME_ROWS=4

cntools_gum_usage() {
  cat <<EOF
Usage: cntools.sh [-n|-l|-o] [-a] [-u] [-b BRANCH] [-v] [-h]

CNTools - Cardano pool and wallet operations

  -n          Local node mode (default)
  -l          Light mode using Koios
  -o          Offline mode
  -a          Show advanced features
  -u          Skip the automatic update-availability check
  -b BRANCH   Redeploy from this Guild branch, then exit
  -v          Print the CNTools version
  -h          Show this help
EOF
}

cntools_gum_log() {
  local record_type="${1:-INFO}"
  local message="${2:-}"

  if declare -F cntools_log >/dev/null 2>&1; then
    cntools_log "${record_type}" "${message}" || true
  fi
}

cntools_gum_prerequisite_error() {
  local detail="${1:-}"

  [[ -z "${detail}" ]] || printf 'CNTools: %s\n' "${detail}" >&2
  printf 'CNTools: Charm Gum v%s is required. Install it and try again.\n' \
    "${CNTOOLS_GUM_REQUIRED_VERSION}" >&2
  cntools_gum_log ERROR \
    "Gum prerequisite unavailable${detail:+: ${detail}}"
  return 1
}

cntools_gum_absolute_command() {
  local candidate="${1:-}"
  local parent=""

  [[ -n "${candidate}" && -x "${candidate}" && ! -d "${candidate}" ]] ||
    return 1
  if [[ "${candidate}" != /* ]]; then
    parent="$(dirname "${candidate}")" || return 1
    parent="$(cd -- "${parent}" 2>/dev/null && pwd -P)" || return 1
    candidate="${parent}/$(basename "${candidate}")"
  fi
  printf '%s\n' "${candidate}"
}

cntools_gum_install_directory() {
  local install_directory="${CNTOOLS_GUM_INSTALL_DIR:-}"

  if [[ -z "${install_directory}" ]]; then
    [[ "${HOME:-}" = /* ]] || return 1
    install_directory="${HOME}/.local/bin"
  fi
  [[ "${install_directory}" = /* &&
     "${install_directory}" != *$'\n'* &&
     "${install_directory}" != *$'\r'* ]] || return 1
  printf '%s\n' "${install_directory}"
}

cntools_gum_version_exact() {
  local candidate="${1:-}"

  [[ -n "${candidate}" && "${candidate}" = /* && -x "${candidate}" ]] ||
    return 1
  "${candidate}" version-check "= ${CNTOOLS_GUM_REQUIRED_VERSION}" \
    >/dev/null 2>&1
}

cntools_gum_find() {
  local candidate=""
  local command_path=""
  local install_directory=""
  local -a candidates=()

  if [[ -n "${CNTOOLS_GUM_BIN:-}" ]]; then
    if candidate="$(cntools_gum_absolute_command \
        "${CNTOOLS_GUM_BIN}" 2>/dev/null)" &&
       cntools_gum_version_exact "${candidate}"; then
      CNTOOLS_GUM_BIN="${candidate}"
      export CNTOOLS_GUM_BIN
      return 0
    fi
    CNTOOLS_GUM_BIN=""
  fi

  install_directory="$(cntools_gum_install_directory 2>/dev/null || true)"
  [[ -z "${install_directory}" ]] || candidates+=("${install_directory}/gum")
  command_path="$(type -P gum 2>/dev/null || true)"
  [[ -z "${command_path}" ]] || candidates+=("${command_path}")

  for candidate in "${candidates[@]}"; do
    candidate="$(cntools_gum_absolute_command "${candidate}" 2>/dev/null)" ||
      continue
    if cntools_gum_version_exact "${candidate}"; then
      CNTOOLS_GUM_BIN="${candidate}"
      export CNTOOLS_GUM_BIN
      return 0
    fi
  done
  return 1
}

cntools_gum_install_cleanup() {
  local temporary="${CNTOOLS_GUM_INSTALL_TMP:-}"
  local stage="${CNTOOLS_GUM_INSTALL_STAGE:-}"

  if [[ -n "${stage}" && "${stage}" = */.gum.* &&
        -f "${stage}" && ! -L "${stage}" && -O "${stage}" ]]; then
    rm -f -- "${stage}" 2>/dev/null || true
  fi
  if [[ -n "${temporary}" && -d "${temporary}" &&
        ! -L "${temporary}" && -O "${temporary}" ]]; then
    rm -f -- \
      "${temporary}/extract/gum" \
      "${temporary}/checksums.txt" \
      "${temporary}/archive.tar.gz" 2>/dev/null || true
    rmdir -- "${temporary}/extract" 2>/dev/null || true
    rmdir -- "${temporary}" 2>/dev/null || true
  fi
  CNTOOLS_GUM_INSTALL_TMP=""
  CNTOOLS_GUM_INSTALL_STAGE=""
}

cntools_gum_sha256() {
  local file="${1:-}"
  local digest=""

  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "${file}" 2>/dev/null)" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 "${file}" 2>/dev/null)" || return 1
  else
    return 127
  fi
  digest="${digest%%[[:space:]]*}"
  [[ "${digest}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s\n' "${digest,,}"
}

cntools_gum_archive_member() {
  local archive="${1:-}"
  local expected_member="${2:-}"
  local listing=""
  local member=""
  local normalized=""
  local component=""
  local gum_member=""
  local gum_count=0
  local -a components=()

  listing="$(tar -tzf "${archive}" 2>/dev/null)" || return 1
  while IFS= read -r member; do
    [[ -n "${member}" && "${member}" != /* ]] || return 1
    normalized="${member#./}"
    IFS='/' read -r -a components <<< "${normalized}"
    for component in "${components[@]}"; do
      [[ -n "${component}" && "${component}" != "." &&
         "${component}" != ".." ]] || return 1
    done
    if [[ "${normalized}" == "${expected_member}" ]]; then
      gum_member="${member}"
      gum_count=$((gum_count + 1))
    fi
  done <<< "${listing}"
  [[ ${gum_count} -eq 1 ]] || return 1
  printf '%s\n' "${gum_member}"
}

cntools_gum_install() {
  local system=""
  local machine=""
  local release_arch=""
  local pinned_digest=""
  local archive_name=""
  local archive_url=""
  local checksums_url=""
  local install_directory=""
  local target=""
  local archive=""
  local checksums=""
  local extract_directory=""
  local member=""
  local member_path=""
  local expected=""
  local actual=""
  local line_digest=""
  local line_file=""
  local extra=""
  local previous_umask=""
  local command_name=""
  local -a missing=()

  if [[ "${CNTOOLS_MODE:-}" == "offline" ]]; then
    cntools_gum_prerequisite_error \
      "Automatic Gum installation is unavailable in offline mode."
    return 1
  fi

  for command_name in curl tar install uname mktemp mkdir chmod mv rm rmdir; do
    command -v "${command_name}" >/dev/null 2>&1 || missing+=("${command_name}")
  done
  if ! command -v sha256sum >/dev/null 2>&1 &&
     ! command -v shasum >/dev/null 2>&1; then
    missing+=("sha256sum")
  fi
  if (( ${#missing[@]} > 0 )); then
    cntools_gum_prerequisite_error \
      "Cannot install Gum; required command(s) missing: ${missing[*]}."
    return 1
  fi

  system="$(uname -s 2>/dev/null)" || return 1
  machine="$(uname -m 2>/dev/null)" || return 1
  [[ "${system}" == "Linux" ]] || {
    cntools_gum_prerequisite_error \
      "Automatic Gum installation is supported on Linux only (found ${system:-unknown})."
    return 1
  }
  case "${machine}" in
    x86_64|amd64)
      release_arch="x86_64"
      pinned_digest="${CNTOOLS_GUM_SHA256_X86_64}"
      ;;
    aarch64|arm64)
      release_arch="arm64"
      pinned_digest="${CNTOOLS_GUM_SHA256_ARM64}"
      ;;
    *)
      cntools_gum_prerequisite_error \
        "Automatic Gum installation does not support architecture ${machine:-unknown}."
      return 1
      ;;
  esac

  install_directory="$(cntools_gum_install_directory 2>/dev/null)" || {
    cntools_gum_prerequisite_error \
      "The Gum install directory must be an absolute, single-line path."
    return 1
  }
  if declare -F cntools_log_path_components_safe >/dev/null 2>&1 &&
     ! cntools_log_path_components_safe "${install_directory}"; then
    cntools_gum_prerequisite_error \
      "The Gum install directory contains an unsafe symbolic link: ${install_directory}."
    return 1
  fi
  previous_umask="$(umask)"
  umask 077
  if ! mkdir -p -- "${install_directory}"; then
    umask "${previous_umask}"
    cntools_gum_prerequisite_error \
      "Could not create the Gum install directory: ${install_directory}."
    return 1
  fi
  umask "${previous_umask}"
  [[ -d "${install_directory}" && ! -L "${install_directory}" &&
     -O "${install_directory}" && -w "${install_directory}" ]] || {
    cntools_gum_prerequisite_error \
      "The Gum install directory is not a safe user-owned directory: ${install_directory}."
    return 1
  }
  install_directory="$(cd -- "${install_directory}" && pwd -P)" || return 1
  target="${install_directory}/gum"
  if [[ -e "${target}" || -L "${target}" ]]; then
    [[ -f "${target}" && ! -L "${target}" && -O "${target}" ]] || {
      cntools_gum_prerequisite_error \
        "The local Gum target is unsafe and was not replaced: ${target}."
      return 1
    }
  fi

  archive_name="gum_${CNTOOLS_GUM_REQUIRED_VERSION}_Linux_${release_arch}.tar.gz"
  archive_url="${CNTOOLS_GUM_RELEASE_ROOT}/${archive_name}"
  checksums_url="${CNTOOLS_GUM_RELEASE_ROOT}/checksums.txt"
  previous_umask="$(umask)"
  umask 077
  CNTOOLS_GUM_INSTALL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cntools-gum.XXXXXX")" || {
    umask "${previous_umask}"
    cntools_gum_prerequisite_error "Could not create a private Gum staging directory."
    return 1
  }
  umask "${previous_umask}"
  archive="${CNTOOLS_GUM_INSTALL_TMP}/archive.tar.gz"
  checksums="${CNTOOLS_GUM_INSTALL_TMP}/checksums.txt"
  extract_directory="${CNTOOLS_GUM_INSTALL_TMP}/extract"
  mkdir -- "${extract_directory}" || {
    cntools_gum_install_cleanup
    return 1
  }

  cntools_gum_log DEPENDENCY \
    "install Gum v${CNTOOLS_GUM_REQUIRED_VERSION} archive=${archive_name}"
  cntools_gum_log API "GET /charmbracelet/gum/releases/download/v${CNTOOLS_GUM_REQUIRED_VERSION}/checksums.txt"
  if ! curl --fail --silent --show-error --location --proto '=https' \
      --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
      --max-filesize 65536 --output "${checksums}" "${checksums_url}"; then
    cntools_gum_log ERROR "Gum checksum download failed"
    cntools_gum_install_cleanup
    cntools_gum_prerequisite_error "Could not download the official Gum checksums."
    return 1
  fi
  cntools_gum_log API \
    "GET /charmbracelet/gum/releases/download/v${CNTOOLS_GUM_REQUIRED_VERSION}/${archive_name}"
  if ! curl --fail --silent --show-error --location --proto '=https' \
      --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 180 \
      --max-filesize 16777216 --output "${archive}" "${archive_url}"; then
    cntools_gum_log ERROR "Gum archive download failed"
    cntools_gum_install_cleanup
    cntools_gum_prerequisite_error "Could not download the official Gum archive."
    return 1
  fi

  while read -r line_digest line_file extra; do
    line_file="${line_file#\*}"
    [[ "${line_file}" == "${archive_name}" && -z "${extra}" ]] || continue
    [[ "${line_digest}" =~ ^[0-9a-fA-F]{64}$ ]] || continue
    [[ -z "${expected}" ]] || {
      expected="duplicate"
      break
    }
    expected="${line_digest,,}"
  done < "${checksums}"
  actual="$(cntools_gum_sha256 "${archive}" 2>/dev/null)" || actual=""
  if [[ -z "${expected}" || "${expected}" == "duplicate" ||
        "${expected}" != "${pinned_digest}" ||
        -z "${actual}" || "${actual}" != "${pinned_digest}" ]]; then
    cntools_gum_log ERROR "Gum archive checksum verification failed"
    cntools_gum_install_cleanup
    cntools_gum_prerequisite_error "The downloaded Gum archive failed checksum verification."
    return 1
  fi

  member_path="gum_${CNTOOLS_GUM_REQUIRED_VERSION}_Linux_${release_arch}/gum"
  member="$(cntools_gum_archive_member \
    "${archive}" "${member_path}" 2>/dev/null)" || {
    cntools_gum_log ERROR "Gum archive structure validation failed"
    cntools_gum_install_cleanup
    cntools_gum_prerequisite_error "The downloaded Gum archive has an unsafe structure."
    return 1
  }
  if ! tar -xOzf "${archive}" -- "${member}" > "${extract_directory}/gum" ||
     [[ ! -f "${extract_directory}/gum" ||
        -L "${extract_directory}/gum" ||
        ! -s "${extract_directory}/gum" ]]; then
    cntools_gum_log ERROR "Gum archive extraction failed"
    cntools_gum_install_cleanup
    cntools_gum_prerequisite_error "Could not safely extract the Gum executable."
    return 1
  fi

  CNTOOLS_GUM_INSTALL_STAGE="$(mktemp "${install_directory}/.gum.XXXXXX")" || {
    cntools_gum_install_cleanup
    cntools_gum_prerequisite_error "Could not stage Gum in ${install_directory}."
    return 1
  }
  if ! install -m 0755 "${extract_directory}/gum" "${CNTOOLS_GUM_INSTALL_STAGE}" ||
     ! cntools_gum_version_exact "${CNTOOLS_GUM_INSTALL_STAGE}"; then
    cntools_gum_log ERROR "Staged Gum executable failed exact version validation"
    cntools_gum_install_cleanup
    cntools_gum_prerequisite_error \
      "The staged Gum executable is not v${CNTOOLS_GUM_REQUIRED_VERSION}."
    return 1
  fi
  if ! mv -f -- "${CNTOOLS_GUM_INSTALL_STAGE}" "${target}" ||
     ! chmod 0755 "${target}" ||
     ! cntools_gum_version_exact "${target}"; then
    cntools_gum_log ERROR "Could not activate the staged Gum executable"
    cntools_gum_install_cleanup
    cntools_gum_prerequisite_error "Could not activate Gum at ${target}."
    return 1
  fi
  CNTOOLS_GUM_INSTALL_STAGE=""
  CNTOOLS_GUM_BIN="${target}"
  export CNTOOLS_GUM_BIN
  cntools_gum_install_cleanup
  cntools_gum_log DEPENDENCY \
    "installed Gum v${CNTOOLS_GUM_REQUIRED_VERSION} path=${CNTOOLS_GUM_BIN}"
  printf 'CNTools: installed Charm Gum v%s at %s.\n' \
    "${CNTOOLS_GUM_REQUIRED_VERSION}" "${CNTOOLS_GUM_BIN}"
}

cntools_gum_require() {
  local answer=""
  local detected=""
  local detected_version=""
  local install_directory=""

  if cntools_gum_find; then
    cntools_gum_log DEPENDENCY \
      "using Gum v${CNTOOLS_GUM_REQUIRED_VERSION} path=${CNTOOLS_GUM_BIN}"
    return 0
  fi
  install_directory="$(cntools_gum_install_directory 2>/dev/null)" || {
    cntools_gum_prerequisite_error \
      "Could not determine a safe user-local Gum install directory."
    return 1
  }
  if [[ -x "${install_directory}/gum" && ! -d "${install_directory}/gum" ]]; then
    detected="${install_directory}/gum"
  else
    detected="$(type -P gum 2>/dev/null || true)"
  fi
  cntools_gum_log DEPENDENCY \
    "required Gum v${CNTOOLS_GUM_REQUIRED_VERSION} not found${detected:+; candidate=${detected}}"

  if [[ ! -t 0 || ! -t 1 ]]; then
    cntools_gum_prerequisite_error \
      "Gum is missing, or its version is not exactly v${CNTOOLS_GUM_REQUIRED_VERSION}; automatic installation needs an interactive terminal."
    return 1
  fi
  if [[ -n "${detected}" ]]; then
    detected_version="$("${detected}" --version 2>/dev/null || true)"
    detected_version="${detected_version%%$'\n'*}"
    detected_version="${detected_version//$'\r'/}"
    detected_version="${detected_version//$'\033'/}"
    [[ -n "${detected_version}" ]] || detected_version="unknown version"
    printf 'CNTools found %s at %s.\n' "${detected_version}" "${detected}"
    printf 'This interface requires exactly Charm Gum v%s.\n' \
      "${CNTOOLS_GUM_REQUIRED_VERSION}"
  else
    printf 'CNTools requires Charm Gum v%s, but Gum was not found.\n' \
      "${CNTOOLS_GUM_REQUIRED_VERSION}"
  fi
  printf 'Install the official release for this user in %s? [y/N]: ' \
    "${install_directory}"
  IFS= read -r answer || answer=""
  case "${answer,,}" in
    y|yes)
      cntools_gum_log DEPENDENCY "Gum installation accepted"
      cntools_gum_install || return 1
      cntools_gum_version_exact "${CNTOOLS_GUM_BIN}" || {
        cntools_gum_prerequisite_error "Installed Gum did not pass exact version validation."
        return 1
      }
      ;;
    *)
      cntools_gum_log DEPENDENCY "Gum installation declined"
      cntools_gum_prerequisite_error \
        "Gum installation was declined; the Gum interface cannot start."
      return 1
      ;;
  esac
}

cntools_gum_require_terminal() {
  if [[ ! -t 0 || ! -t 1 ]] ||
     ! (: </dev/tty >/dev/tty) 2>/dev/null; then
    printf 'CNTools: the Gum interface requires an accessible interactive terminal.\n' >&2
    cntools_gum_log ERROR \
      "Gum interface requires an interactive terminal accessible through /dev/tty"
    return 1
  fi
}

cntools_gum() {
  [[ -n "${CNTOOLS_GUM_BIN:-}" && "${CNTOOLS_GUM_BIN}" = /* ]] || return 127
  "${CNTOOLS_GUM_BIN}" "$@"
}

# Header fragments are composed through command substitutions. Gum correctly
# treats those pipes as non-interactive, so explicitly retain ANSI styling for
# the fragments that will immediately be rendered back to the user's terminal.
cntools_gum_capture() {
  if [[ -n "${NO_COLOR:-}" ]]; then
    NO_COLOR=1 CLICOLOR_FORCE='' cntools_gum "$@"
  else
    CLICOLOR_FORCE=1 cntools_gum "$@"
  fi
}

cntools_gum_width() {
  local width="${COLUMNS:-}"

  if [[ ! "${width}" =~ ^[0-9]+$ ]]; then
    width="$(tput cols 2>/dev/null || printf '80')"
  fi
  [[ "${width}" =~ ^[0-9]+$ ]] || width=80
  (( width >= 44 )) || width=44
  (( width <= 100 )) || width=100
  printf '%s\n' "$((width - 2))"
}

# Content views may need more horizontal room than the deliberately compact
# menu/header frame. Resolve the live terminal width once at the start of a
# render, keep two columns clear of the terminal edge, and retain a readable
# upper bound. Table producers can then wrap against one stable snapshot.
cntools_ui_content_width() {
  local maximum="${1:-180}"
  local minimum="${2:-42}"
  local terminal_columns=""
  local width=""

  [[ "${maximum}" =~ ^[1-9][0-9]*$ &&
     "${minimum}" =~ ^[1-9][0-9]*$ &&
     ${maximum} -ge ${minimum} ]] || return 2
  if [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == "Y" || -t 1 ]]; then
    terminal_columns="$(tput cols 2>/dev/null || true)"
    if [[ "${terminal_columns}" =~ ^[0-9]+$ &&
          ${terminal_columns} -gt 2 ]]; then
      width="$((terminal_columns - 2))"
    fi
  fi
  [[ -n "${width}" ]] || width="${CNTOOLS_UI_COLUMNS:-}"
  if [[ ! "${width}" =~ ^[0-9]+$ ]]; then
    width="$(cntools_gum_width 2>/dev/null || true)"
  fi
  [[ "${width}" =~ ^[0-9]+$ ]] || width=80
  (( width >= minimum )) || width="${minimum}"
  (( width <= maximum )) || width="${maximum}"
  printf '%s\n' "${width}"
}

cntools_gum_terminal_lines() {
  local lines=""

  lines="$(tput lines 2>/dev/null || true)"
  if [[ ! "${lines}" =~ ^[0-9]+$ || ${lines} -lt 1 ]]; then
    lines="${LINES:-24}"
  fi
  [[ "${lines}" =~ ^[0-9]+$ && ${lines} -ge 1 ]] || lines=24
  printf '%s\n' "${lines}"
}

cntools_gum_filter_height() {
  local choice_count="${1:-}"
  local rows_above="${2:-${CNTOOLS_GUM_HEADER_ROWS}}"
  local terminal_lines=""
  local visible_choices=1

  [[ "${choice_count}" =~ ^[0-9]+$ && ${choice_count} -ge 1 ]] || return 2
  [[ "${rows_above}" =~ ^[0-9]+$ ]] || return 2
  terminal_lines="$(cntools_gum_terminal_lines)" || return 1
  [[ "${terminal_lines}" =~ ^[0-9]+$ && ${terminal_lines} -ge 1 ]] || return 1

  visible_choices=$((terminal_lines - rows_above + 1 -
    CNTOOLS_GUM_FILTER_CHROME_ROWS))
  (( visible_choices >= 1 )) || visible_choices=1
  (( visible_choices <= choice_count )) || visible_choices="${choice_count}"
  printf '%s\n' "$((visible_choices + CNTOOLS_GUM_FILTER_CHROME_ROWS))"
}

cntools_gum_clear() {
  [[ -t 1 ]] || return 0
  tput clear 2>/dev/null || printf '\033[2J\033[H'
}

cntools_gum_header_rows() {
  if [[ "${CNTOOLS_GUM_LAST_HEADER_ROWS:-}" =~ ^[0-9]+$ &&
        "${CNTOOLS_GUM_LAST_HEADER_MODE:-}" == "${CNTOOLS_MODE:-}" ]]; then
    printf '%s\n' "${CNTOOLS_GUM_LAST_HEADER_ROWS}"
  elif [[ "${CNTOOLS_MODE:-}" != "offline" &&
          "${CNTOOLS_MENU_ID:-/}" == "/" ]]; then
    printf '%s\n' "${CNTOOLS_GUM_HEADER_ROWS}"
  else
    printf '5\n'
  fi
}

cntools_ui_path_into() {
  local output_name="${1:-}"
  local value="${2:-/}"

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  case "${value}" in
    CNTools) value="/" ;;
    'CNTools / '*) value="/ ${value#CNTools / }" ;;
    /*) ;;
    *) value="/ ${value}" ;;
  esac
  output_ref="${value}"
}

cntools_ui_runtime_context_into() {
  local output_name="${1:-}"
  local separator=" | "

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  if [[ "${CNTOOLS_MODE:-}" == "offline" ]]; then
    output_ref="Offline"
    return 0
  fi
  [[ "${CNTOOLS_UI_UTF8:-N}" != "Y" ]] || separator=" · "
  printf -v output_ref '%s%s%s%s%s' \
    "${CNTOOLS_MODE:-unknown}" "${separator}" \
    "${CNTOOLS_BACKEND:-unknown}" "${separator}" \
    "${CNTOOLS_NETWORK:-unknown}"
}

cntools_gum_header_cache_id() {
  local output_name="${1:-}"
  local candidate="${CNTOOLS_ACTION_ID:-${CNTOOLS_MENU_ID:-@adhoc}}"

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  [[ "${candidate}" != "/" ]] || candidate="@root"
  if [[ "${candidate}" != "@root" &&
        ! "${candidate}" =~ ^[a-z0-9][a-z0-9._/-]*$ ]]; then
    candidate="@adhoc"
  fi
  output_ref="${candidate}"
}

cntools_gum_breadcrumb_into() {
  local output_name="${1:-}"
  local breadcrumb="${2:-/}"
  local cache_id="${3:-@adhoc}"
  local cache_key=""
  local parent=""
  local leaf=""
  local styled_parent=""
  local styled_leaf=""

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  cache_key="${breadcrumb}"$'\037'"${CNTOOLS_GUM_COLOR_MUTED}"$'\037'\
"${CNTOOLS_GUM_COLOR_BRAND}"$'\037'"${CNTOOLS_GUM_COLOR_SURFACE}"$'\037'\
"${NO_COLOR+x}:${NO_COLOR:-}"
  if [[ "${CNTOOLS_GUM_BREADCRUMB_KEYS[${cache_id}]:-}" == "${cache_key}" &&
        -n "${CNTOOLS_GUM_BREADCRUMB_FRAGMENTS[${cache_id}]+set}" ]]; then
    output_ref="${CNTOOLS_GUM_BREADCRUMB_FRAGMENTS[${cache_id}]}"
    return 0
  fi

  if [[ "${breadcrumb}" == "/" ]]; then
    output_ref="$(cntools_gum_capture style \
      --foreground "${CNTOOLS_GUM_COLOR_BRAND}" \
      --background "${CNTOOLS_GUM_COLOR_SURFACE}" --bold "/")" || return 1
  else
    if [[ "${breadcrumb}" == *" / "* ]]; then
      parent="${breadcrumb% / *} / "
      leaf="${breadcrumb##* / }"
    else
      parent="/ "
      leaf="${breadcrumb#/ }"
    fi
    styled_parent="$(cntools_gum_capture style \
      --foreground "${CNTOOLS_GUM_COLOR_MUTED}" \
      --background "${CNTOOLS_GUM_COLOR_SURFACE}" \
      "${parent}")" || return 1
    styled_leaf="$(cntools_gum_capture style \
      --foreground "${CNTOOLS_GUM_COLOR_BRAND}" \
      --background "${CNTOOLS_GUM_COLOR_SURFACE}" --bold \
      "${leaf}")" || return 1
    output_ref="${styled_parent}${styled_leaf}"
  fi
  CNTOOLS_GUM_BREADCRUMB_KEYS["${cache_id}"]="${cache_key}"
  CNTOOLS_GUM_BREADCRUMB_FRAGMENTS["${cache_id}"]="${output_ref}"
}

cntools_gum_breadcrumb() {
  local breadcrumb=""
  local rendered=""

  cntools_ui_path_into breadcrumb "${1:-/}" || return 1
  cntools_gum_breadcrumb_into rendered "${breadcrumb}" "@adhoc" || return 1
  printf '%s' "${rendered}"
}

cntools_gum_health_color_into() {
  local output_name="${1:-}"

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  case "${CNTOOLS_HEALTH_TONE:-quiet}" in
    success) output_ref="${CNTOOLS_GUM_COLOR_SUCCESS}" ;;
    warning) output_ref="${CNTOOLS_GUM_COLOR_WARNING}" ;;
    danger) output_ref="${CNTOOLS_GUM_COLOR_DANGER}" ;;
    *) output_ref="${CNTOOLS_GUM_COLOR_QUIET}" ;;
  esac
}

cntools_gum_static_header_fragments() {
  local runtime="${1:-}"
  local static_key="${2:-}"
  local styled_name=""
  local styled_title_gap=""
  local styled_version=""

  if [[ "${CNTOOLS_GUM_STATIC_HEADER_KEY}" == "${static_key}" ]]; then
    return 0
  fi
  styled_name="$(cntools_gum_capture style \
    --foreground "${CNTOOLS_GUM_COLOR_BRAND}" \
    --background "${CNTOOLS_GUM_COLOR_SURFACE}" --bold "CNTools")" || return 1
  styled_version="$(cntools_gum_capture style \
    --foreground "${CNTOOLS_GUM_COLOR_MUTED}" \
    --background "${CNTOOLS_GUM_COLOR_SURFACE}" \
    "v${CNTOOLS_VERSION:-?}")" || return 1
  styled_title_gap="$(cntools_gum_capture style \
    --background "${CNTOOLS_GUM_COLOR_SURFACE}" " ")" || return 1
  CNTOOLS_GUM_STATIC_HEADER_TITLE="${styled_name}${styled_title_gap}${styled_version}"
  CNTOOLS_GUM_STATIC_HEADER_RUNTIME="$(cntools_gum_capture style \
    --foreground "${CNTOOLS_GUM_COLOR_MUTED}" \
    --background "${CNTOOLS_GUM_COLOR_SURFACE}" "${runtime}")" || return 1
  CNTOOLS_GUM_STATIC_HEADER_KEY="${static_key}"
}

cntools_gum_health_fragment_into() {
  local output_name="${1:-}"
  local health_color="${2:-}"
  local health_key="${3:-}"

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  if [[ "${CNTOOLS_GUM_HEALTH_FRAGMENT_KEY}" != "${health_key}" ]]; then
    CNTOOLS_GUM_HEALTH_FRAGMENT="$(cntools_gum_capture style \
      --foreground "${health_color}" \
      --background "${CNTOOLS_GUM_COLOR_SURFACE}" \
      "${CNTOOLS_HEALTH_TEXT:-node offline}")" || return 1
    CNTOOLS_GUM_HEALTH_FRAGMENT_KEY="${health_key}"
  fi
  output_ref="${CNTOOLS_GUM_HEALTH_FRAGMENT}"
}

cntools_gum_text_rows_into() {
  local output_name="${1:-}"
  local remaining="${2:-}"
  local rows=1

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  while [[ "${remaining}" == *$'\n'* ]]; do
    remaining="${remaining#*$'\n'}"
    ((rows++))
  done
  output_ref="${rows}"
}

cntools_gum_header() {
  local breadcrumb="${1:-/}"
  local normalized_breadcrumb=""
  local cache_id=""
  local static_key=""
  local health_key=""
  local render_key=""
  local width=""
  local runtime=""
  local styled_path=""
  local styled_health=""
  local health_color=""
  local content=""
  local rendered_header=""
  local rendered_rows=""
  local show_health="N"

  width="$(cntools_gum_width)"
  cntools_ui_path_into normalized_breadcrumb "${breadcrumb}" || return 1
  cntools_ui_runtime_context_into runtime || return 1
  cntools_gum_header_cache_id cache_id || return 1
  if [[ "${normalized_breadcrumb}" == "/" &&
        "${CNTOOLS_MODE:-}" != "offline" ]]; then
    show_health="Y"
    cntools_gum_health_color_into health_color || return 1
  fi
  static_key="${CNTOOLS_VERSION:-?}"$'\037'"${runtime}"$'\037'\
"${CNTOOLS_GUM_COLOR_BRAND}"$'\037'"${CNTOOLS_GUM_COLOR_MUTED}"$'\037'\
"${CNTOOLS_GUM_COLOR_SURFACE}"$'\037'"${NO_COLOR+x}:${NO_COLOR:-}"
  if [[ "${show_health}" == "Y" ]]; then
    health_key="${CNTOOLS_HEALTH_TONE:-quiet}"$'\037'\
"${CNTOOLS_HEALTH_TEXT:-node offline}"$'\037'"${health_color}"$'\037'\
"${CNTOOLS_GUM_COLOR_SURFACE}"$'\037'"${NO_COLOR+x}:${NO_COLOR:-}"
  else
    health_key="hidden"
  fi
  render_key="${width}"$'\037'"${normalized_breadcrumb}"$'\037'\
"${static_key}"$'\037'"${health_key}"$'\037'"${CNTOOLS_GUM_COLOR_DIVIDER}"$'\037'\
"${CNTOOLS_GUM_COLOR_TEXT}"
  cntools_gum_clear
  if [[ "${CNTOOLS_GUM_HEADER_RENDER_KEYS[${cache_id}]:-}" == "${render_key}" &&
        -n "${CNTOOLS_GUM_HEADER_RENDERED[${cache_id}]+set}" ]]; then
    CNTOOLS_GUM_LAST_HEADER_ROWS="${CNTOOLS_GUM_HEADER_RENDER_ROWS[${cache_id}]}"
    CNTOOLS_GUM_LAST_HEADER_MODE="${CNTOOLS_MODE:-}"
    printf '%s\n' "${CNTOOLS_GUM_HEADER_RENDERED[${cache_id}]}"
    return 0
  fi

  cntools_gum_static_header_fragments "${runtime}" "${static_key}" || return 1
  cntools_gum_breadcrumb_into styled_path \
    "${normalized_breadcrumb}" "${cache_id}" || return 1
  content="${CNTOOLS_GUM_STATIC_HEADER_TITLE}"$'\n'"${styled_path}"$'\n'\
"${CNTOOLS_GUM_STATIC_HEADER_RUNTIME}"
  if [[ "${show_health}" == "Y" ]]; then
    cntools_gum_health_fragment_into styled_health \
      "${health_color}" "${health_key}" || return 1
    content+=$'\n'"${styled_health}"
  fi
  rendered_header="$(cntools_gum_capture style --no-strip-ansi \
    --width "${width}" --padding "0 2" --border rounded \
    --border-foreground "${CNTOOLS_GUM_COLOR_DIVIDER}" \
    --background "${CNTOOLS_GUM_COLOR_SURFACE}" \
    --foreground "${CNTOOLS_GUM_COLOR_TEXT}" "${content}")" || return 1
  cntools_gum_text_rows_into rendered_rows "${rendered_header}" || return 1
  [[ "${rendered_rows}" =~ ^[1-9][0-9]*$ ]] || return 1
  CNTOOLS_GUM_HEADER_RENDER_KEYS["${cache_id}"]="${render_key}"
  CNTOOLS_GUM_HEADER_RENDERED["${cache_id}"]="${rendered_header}"
  CNTOOLS_GUM_HEADER_RENDER_ROWS["${cache_id}"]="${rendered_rows}"
  CNTOOLS_GUM_LAST_HEADER_ROWS="${rendered_rows}"
  CNTOOLS_GUM_LAST_HEADER_MODE="${CNTOOLS_MODE:-}"
  printf '%s\n' "${rendered_header}"
}

# Generic CNTools UI driver backed by Charm Gum.
cntools_ui_init() {
  CNTOOLS_UI_INTERACTIVE="N"
  [[ -t 0 && -t 1 ]] && CNTOOLS_UI_INTERACTIVE="Y"
  CNTOOLS_UI_CAPABLE="Y"
  CNTOOLS_UI_CLEANED="N"
  CNTOOLS_UI_UTF8="Y"
  CNTOOLS_UI_COLUMNS="$(cntools_gum_width)"
  CNTOOLS_UI_LINES="$(tput lines 2>/dev/null || printf '24')"
  CNTOOLS_UI_RESET=""
  CNTOOLS_UI_BOLD=""
  CNTOOLS_UI_DIM=""
  CNTOOLS_UI_CYAN=""
  CNTOOLS_UI_GREEN=""
  CNTOOLS_UI_YELLOW=""
  CNTOOLS_UI_RED=""
  CNTOOLS_GUM_LAST_HEADER_ROWS=""
  CNTOOLS_GUM_LAST_HEADER_MODE=""
  CNTOOLS_GUM_STATIC_HEADER_KEY=""
  CNTOOLS_GUM_STATIC_HEADER_TITLE=""
  CNTOOLS_GUM_STATIC_HEADER_RUNTIME=""
  CNTOOLS_GUM_HEALTH_FRAGMENT_KEY=""
  CNTOOLS_GUM_HEALTH_FRAGMENT=""
  CNTOOLS_GUM_BREADCRUMB_KEYS=()
  CNTOOLS_GUM_BREADCRUMB_FRAGMENTS=()
  CNTOOLS_GUM_HEADER_RENDER_KEYS=()
  CNTOOLS_GUM_HEADER_RENDERED=()
  CNTOOLS_GUM_HEADER_RENDER_ROWS=()
  CNTOOLS_GUM_MENU_ROW_KEYS=()
  CNTOOLS_GUM_MENU_ROWS=()
  return 0
}

cntools_ui_mark_resize() { return 0; }
cntools_ui_restore_terminal() { return 0; }

cntools_ui_suspend_for_job_control() {
  local process_id="${BASHPID:-$$}"

  trap - TSTP
  kill -s TSTP "${process_id}" 2>/dev/null || true
  trap 'cntools_ui_suspend_for_job_control' TSTP
}

cntools_ui_cleanup() {
  [[ "${CNTOOLS_UI_CLEANED:-N}" != "Y" ]] || return 0
  cntools_gum_install_cleanup
  CNTOOLS_UI_CLEANED="Y"
}

cntools_ui_render_begin() {
  local _label="${1:-CNTools}"
  local breadcrumb="${2:-/}"

  : "${_label}"
  cntools_gum_header "${breadcrumb}"
}

cntools_ui_action_begin() {
  cntools_ui_render_begin "${1:-Action}" "${2:-/}"
}

cntools_ui_render_status() {
  local level="${1:-info}"
  local message="${2:-}"
  local color="${CNTOOLS_GUM_COLOR_BRAND}"

  [[ -n "${message}" ]] || return 0
  case "${level}" in
    error) color="${CNTOOLS_GUM_COLOR_DANGER}" ;;
    warn) color="${CNTOOLS_GUM_COLOR_WARNING}" ;;
    success) color="${CNTOOLS_GUM_COLOR_SUCCESS}" ;;
  esac
  cntools_gum style --margin "0 2 1 2" --padding "0 1" --border normal \
    --border-foreground "${color}" --foreground "${color}" "${message}"
}

cntools_ui_render_field() {
  local label="${1:-}"
  local value="${2:-}"
  local styled_label=""
  local styled_value=""

  styled_label="$(cntools_gum style --width 13 --foreground \
    "${CNTOOLS_GUM_COLOR_MUTED}" --bold "${label}")" || return 1
  styled_value="$(cntools_gum style --foreground \
    "${CNTOOLS_GUM_COLOR_TEXT}" "${value}")" || return 1
  cntools_gum join --horizontal "${styled_label}" "${styled_value}"
}

cntools_ui_render_detail() {
  cntools_gum style --margin "0 2" --bold \
    --foreground "${CNTOOLS_GUM_COLOR_BRAND}" "${1:-}"
}

cntools_ui_render_empty() {
  cntools_ui_render_status warn "No actions are available in this menu."
}

cntools_ui_confirm() {
  local prompt="${1:-Continue?}"

  cntools_gum confirm --default=false \
    --prompt.foreground "${CNTOOLS_GUM_COLOR_TEXT}" \
    --selected.background "${CNTOOLS_GUM_COLOR_BRAND_DARK}" \
    --selected.foreground "${CNTOOLS_GUM_COLOR_TEXT}" "${prompt}"
}

cntools_ui_wait() {
  [[ "${CNTOOLS_UI_INTERACTIVE:-N}" == "Y" ]] || return 0
  printf '\n'
  cntools_gum input --no-show-help \
    --prompt "" --placeholder "Press Enter to return…" \
    --cursor.foreground "${CNTOOLS_GUM_COLOR_BRAND}" >/dev/null || true
}

cntools_ui_read_key() {
  local _cntools_output_name="${1:-}"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  cntools_ui_wait
  _cntools_output_ref="enter"
}

# Reusable interaction helpers for actions added later.
cntools_ui_input() {
  local _cntools_output_name="${1:-}"
  local _cntools_prompt="${2:-Value}"
  local _cntools_value=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_value="$(cntools_gum input --prompt "${_cntools_prompt}: " \
    --prompt.foreground "${CNTOOLS_GUM_COLOR_BRAND}" \
    --cursor.foreground "${CNTOOLS_GUM_COLOR_BRAND}")" || return $?
  _cntools_output_ref="${_cntools_value}"
}

# Capture a secret without echoing it. Callers own validation and must unset
# the returned value as soon as the operation completes.
cntools_ui_password() {
  local _cntools_output_name="${1:-}"
  local _cntools_prompt="${2:-Passphrase}"
  local _cntools_value=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_value="$(cntools_gum input --password \
    --prompt "${_cntools_prompt}: " \
    --prompt.foreground "${CNTOOLS_GUM_COLOR_BRAND}" \
    --cursor.foreground "${CNTOOLS_GUM_COLOR_BRAND}")" || return $?
  _cntools_output_ref="${_cntools_value}"
}

cntools_ui_choose() {
  local _cntools_output_name="${1:-}"
  local _cntools_placeholder="${2:-Select…}"
  local _cntools_value=""
  local _cntools_status=0
  local _cntools_width=""
  local _cntools_height=0
  local _cntools_rows_above=""
  shift 2 || return 2

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  (( $# > 0 )) || return 2
  _cntools_width="$(cntools_gum_width)" || return 1
  _cntools_rows_above="$(cntools_gum_header_rows)" || return 1
  _cntools_height="$(cntools_gum_filter_height \
    "$#" "${_cntools_rows_above}")" || return 1
  if _cntools_value="$(printf '%s\n' "$@" | cntools_gum filter \
      --limit 1 --height "${_cntools_height}" --width "${_cntools_width}" \
      --padding "0 2 1 2" --no-show-help \
      --placeholder "${_cntools_placeholder}" \
      --placeholder.foreground "${CNTOOLS_GUM_COLOR_MUTED}" \
      --prompt "› " --prompt.foreground "${CNTOOLS_GUM_COLOR_BRAND}" \
      --indicator "▸ " \
      --indicator.foreground "${CNTOOLS_GUM_COLOR_BRAND}" \
      --match.foreground "${CNTOOLS_GUM_COLOR_SUCCESS}" \
      --text.foreground "${CNTOOLS_GUM_COLOR_TEXT}" \
      --text.background "${CNTOOLS_GUM_COLOR_CANVAS}" \
      --cursor-text.foreground "${CNTOOLS_GUM_COLOR_TEXT}" \
      --cursor-text.background "${CNTOOLS_GUM_COLOR_SURFACE}")"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  _cntools_output_ref="${_cntools_value}"
  return "${_cntools_status}"
}

cntools_ui_static_table() {
  local header="${1:-}"
  local row=""
  shift || return 2

  [[ -n "${header}" ]] || return 2
  cntools_gum style --margin "0 2" --padding "0 1" --bold \
    --foreground "${CNTOOLS_GUM_COLOR_BRAND}" \
    --background "${CNTOOLS_GUM_COLOR_SURFACE}" "${header}" || return 1
  for row in "$@"; do
    cntools_gum style --margin "0 2" --padding "0 1" \
      --foreground "${CNTOOLS_GUM_COLOR_TEXT}" "${row}" || return 1
  done
}

cntools_ui_pager() {
  cntools_gum pager --show-line-numbers=false \
    --border rounded \
    --border-foreground "${CNTOOLS_GUM_COLOR_DIVIDER}" \
    --border-background "${CNTOOLS_GUM_COLOR_CANVAS}" \
    --foreground "${CNTOOLS_GUM_COLOR_TEXT}" \
    --background "${CNTOOLS_GUM_COLOR_CANVAS}" \
    --match.foreground "${CNTOOLS_GUM_COLOR_BRAND}" \
    --match.background "${CNTOOLS_GUM_COLOR_CANVAS}" \
    --match-highlight.foreground "${CNTOOLS_GUM_COLOR_CANVAS}" \
    --match-highlight.background "${CNTOOLS_GUM_COLOR_BRAND}" "$@"
}

cntools_ui_page_file() {
  local source_file="${1:-}"

  [[ -f "${source_file}" && ! -L "${source_file}" ]] || return 2
  cntools_ui_pager --soft-wrap < "${source_file}"
}

cntools_ui_table() {
  local -a table_arguments=(
    table --print --border rounded --no-show-help
    --border.foreground "${CNTOOLS_GUM_COLOR_DIVIDER}"
    --header.foreground "${CNTOOLS_GUM_COLOR_TEXT}"
    --header.background "${CNTOOLS_GUM_COLOR_CANVAS}"
    --cell.foreground "${CNTOOLS_GUM_COLOR_TEXT}"
    --cell.background "${CNTOOLS_GUM_COLOR_CANVAS}"
    --selected.foreground "${CNTOOLS_GUM_COLOR_TEXT}"
    --selected.background "${CNTOOLS_GUM_COLOR_CANVAS}"
  )

  # Gum v2.0.0's static table renderer applies its header style to the first
  # data row instead of Lip Gloss's header row. Keep every Gum-owned row color
  # neutral and use the section label above the table for the brand accent.
  # Selected colors are also pinned because a static table must never imply
  # that its first data row is an active choice. Gum otherwise strips ANSI
  # styles from piped table input even when its output is a terminal, so force
  # color parsing for trusted, pre-sanitized CNTools rows. Respect NO_COLOR.
  if [[ -n "${NO_COLOR:-}" ]]; then
    NO_COLOR=1 CLICOLOR_FORCE='' \
      cntools_gum "${table_arguments[@]}" "$@"
  else
    CLICOLOR_FORCE=1 cntools_gum "${table_arguments[@]}" "$@"
  fi
}

cntools_ui_spin() {
  local title="${1:-Working…}"
  shift || true
  (( $# > 0 )) || return 2
  cntools_gum spin --spinner dot --title "${title}" \
    --spinner.foreground "${CNTOOLS_GUM_COLOR_BRAND}" -- "$@"
}

# Run a shell function in this process while Gum owns only the spinner. Running
# the function itself through `gum spin --` would put it in a child process and
# discard any arrays or status values it prepared for the calling action.
cntools_ui_spin_function() {
  local title="${1:-Working…}"
  local temporary_directory="${CNTOOLS_TMP_DIR:-}"
  local marker=""
  local previous_umask=""
  local spinner_pid=""
  local callback_status=0
  local spinner_status=0
  local parent_pid="${BASHPID:-$$}"
  shift || true

  (( $# > 0 )) || return 2
  [[ -n "${temporary_directory}" &&
     "${temporary_directory}" = /* &&
     -d "${temporary_directory}" &&
     ! -L "${temporary_directory}" &&
     -O "${temporary_directory}" &&
     -w "${temporary_directory}" &&
     -n "${BASH:-}" && -x "${BASH}" ]] || return 1

  previous_umask="$(umask)"
  umask 077
  marker="$(mktemp \
    "${temporary_directory}/.cntools-spin.XXXXXX")" || {
    umask "${previous_umask}"
    return 1
  }
  umask "${previous_umask}"
  chmod 0600 "${marker}" || {
    rm -f -- "${marker}"
    return 1
  }

  cntools_gum spin --spinner dot --title "${title}" \
    --spinner.foreground "${CNTOOLS_GUM_COLOR_BRAND}" -- \
    "${BASH}" -c '
      marker=$1
      parent_pid=$2
      cleanup() {
        [[ ! -f "${marker}" || -L "${marker}" ]] || rm -f -- "${marker}"
      }
      trap cleanup EXIT HUP INT TERM
      while [[ -e "${marker}" ]] &&
            kill -0 "${parent_pid}" 2>/dev/null; do
        sleep 0.1
      done
    ' _ "${marker}" "${parent_pid}" &
  spinner_pid=$!

  if "$@"; then
    callback_status=0
  else
    callback_status=$?
  fi
  if [[ -e "${marker}" || -L "${marker}" ]]; then
    if [[ -f "${marker}" && ! -L "${marker}" && -O "${marker}" ]]; then
      if rm -f -- "${marker}"; then
        :
      else
        kill "${spinner_pid}" 2>/dev/null || true
        wait "${spinner_pid}" 2>/dev/null || true
        return 1
      fi
    else
      kill "${spinner_pid}" 2>/dev/null || true
      wait "${spinner_pid}" 2>/dev/null || true
      return 1
    fi
  fi
  if wait "${spinner_pid}"; then
    spinner_status=0
  else
    spinner_status=$?
  fi
  if [[ -f "${marker}" && ! -L "${marker}" && -O "${marker}" ]]; then
    rm -f -- "${marker}" 2>/dev/null || true
  fi

  (( callback_status == 0 )) || return "${callback_status}"
  return "${spinner_status}"
}

cntools_gum_filter() {
  local _cntools_output_name="${1:-}"
  local _cntools_height="${2:-12}"
  local _cntools_result=""
  local _cntools_status=0
  local _cntools_width=""
  shift 2 || return 2

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  (( $# > 0 )) || return 2
  _cntools_width="$(cntools_gum_width)"
  if _cntools_result="$(printf '%s\n' "$@" | cntools_gum filter \
      --limit 1 --height "${_cntools_height}" --width "${_cntools_width}" \
      --padding "0 2 1 2" \
      --placeholder "Filter actions…" \
      --placeholder.foreground "${CNTOOLS_GUM_COLOR_MUTED}" \
      --prompt "› " --prompt.foreground "${CNTOOLS_GUM_COLOR_BRAND}" \
      --indicator "▸ " \
      --indicator.foreground "${CNTOOLS_GUM_COLOR_BRAND}" \
      --match.foreground "${CNTOOLS_GUM_COLOR_SUCCESS}" \
      --text.foreground "${CNTOOLS_GUM_COLOR_TEXT}" \
      --text.background "${CNTOOLS_GUM_COLOR_CANVAS}" \
      --cursor-text.foreground "${CNTOOLS_GUM_COLOR_TEXT}" \
      --cursor-text.background "${CNTOOLS_GUM_COLOR_SURFACE}")"; then
    _cntools_status=0
  else
    _cntools_status=$?
  fi
  _cntools_output_ref="${_cntools_result}"
  return "${_cntools_status}"
}

cntools_gum_menu_row_into() {
  local output_name="${1:-}"
  local index="${2:-0}"
  local marker="•"
  local suffix=""

  [[ "${output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n output_ref="${output_name}"
  [[ "${CNTOOLS_MENU_KINDS[index]:-action}" != "menu" ]] || marker="›"
  if [[ "${CNTOOLS_MENU_ENABLED[index]:-Y}" != "Y" ]]; then
    marker="×"
    suffix="  [${CNTOOLS_MENU_DISABLED_REASONS[index]}]"
  fi
  printf -v output_ref '%02d  %s %-22s  %s%s' "$((index + 1))" "${marker}" \
    "${CNTOOLS_MENU_LABELS[index]}" \
    "${CNTOOLS_MENU_DESCRIPTIONS[index]}" "${suffix}"
}

cntools_gum_menu_row() {
  local index="${1:-0}"
  local row=""

  cntools_gum_menu_row_into row "${index}" || return 1
  printf '%s\n' "${row}"
}

cntools_gum_menu_run() {
  local -a menu_stack=()
  local -a rows=()
  local -a row_types=()
  local -a row_indices=()
  local current=""
  local root_directory=""
  local cache_menu_id=""
  local context="N"
  local breadcrumb="/"
  local selected_row=""
  local selected_type=""
  local selected_index=-1
  local status_level=""
  local status_message=""
  local filter_status=0
  local action_status=0
  local stack_index=0
  local count=0
  local index=0
  local height=12
  local mapping=-1
  local rows_above_filter=""
  local row=""
  local row_key=""
  local row_signature=""

  if [[ "${CNTOOLS_MENU_CACHE_READY:-N}" != "Y" ]] &&
     ! cntools_menu_cache_build; then
    cntools_gum_log ERROR "${CNTOOLS_MENU_ERROR}"
    printf 'CNTools: %s\n' "${CNTOOLS_MENU_ERROR}" >&2
    return 1
  fi
  menu_stack=("${CNTOOLS_MENU_CACHE_MENU_DIRS[${CNTOOLS_MENU_ROOT_ID}]}")

  while :; do
    stack_index=$((${#menu_stack[@]} - 1))
    current="${menu_stack[stack_index]}"
    context="N"
    (( stack_index > 0 )) && context="Y"
    if ! cntools_menu_cache_open "${current}"; then
      cntools_gum_log ERROR "${CNTOOLS_MENU_ERROR}"
      printf 'CNTools: %s\n' "${CNTOOLS_MENU_ERROR}" >&2
      return 1
    fi
    count="${#CNTOOLS_MENU_PATHS[@]}"
    breadcrumb="${CNTOOLS_MENU_BREADCRUMB}"
    root_directory="${CNTOOLS_MENU_CACHE_MENU_DIRS[${CNTOOLS_MENU_ROOT_ID}]}"
    if [[ "${current}" == "${root_directory}" ]]; then
      cache_menu_id="${CNTOOLS_MENU_ROOT_ID}"
      CNTOOLS_MENU_ID="/"
    elif [[ "${current}" == "${root_directory}/"* ]]; then
      cache_menu_id="${current#"${root_directory}/"}"
      CNTOOLS_MENU_ID="${cache_menu_id}"
    else
      cntools_gum_log ERROR "Cached menu path is outside the module root: ${current}"
      return 1
    fi

    if [[ "${context}" == "N" ]] &&
       declare -F cntools_health_refresh >/dev/null 2>&1; then
      cntools_health_refresh || true
    fi
    cntools_gum_header "${breadcrumb}" || return 1
    rows_above_filter="$(cntools_gum_header_rows)" || return 1
    cntools_update_state_load || true
    if [[ "${context}" == "N" &&
          "${CNTOOLS_UPDATE_STATUS:-}" == "available" ]]; then
      cntools_ui_render_status warn \
        "CNTools v${CNTOOLS_UPDATE_REMOTE_VERSION} is available in Update."
      rows_above_filter=$((rows_above_filter + CNTOOLS_GUM_STATUS_ROWS))
    elif [[ "${CNTOOLS_MENU_ID}" == "update" ]]; then
      cntools_update_render_summary
      rows_above_filter=$((rows_above_filter + CNTOOLS_GUM_UPDATE_SUMMARY_ROWS))
    fi
    if [[ -n "${status_message}" ]]; then
      cntools_ui_render_status "${status_level}" "${status_message}"
      rows_above_filter=$((rows_above_filter + CNTOOLS_GUM_STATUS_ROWS))
      status_level=""
      status_message=""
    fi

    rows=()
    row_types=()
    row_indices=()
    for (( index = 0; index < count; index++ )); do
      row_key="${cache_menu_id}:${index}"
      row_signature="${index}"$'\037'"${CNTOOLS_MENU_KINDS[index]:-action}"$'\037'\
"${CNTOOLS_MENU_ENABLED[index]:-Y}"$'\037'\
"${CNTOOLS_MENU_DISABLED_REASONS[index]:-}"$'\037'\
"${CNTOOLS_MENU_LABELS[index]}"$'\037'"${CNTOOLS_MENU_DESCRIPTIONS[index]}"
      if [[ "${CNTOOLS_GUM_MENU_ROW_KEYS[${row_key}]:-}" == "${row_signature}" &&
            -n "${CNTOOLS_GUM_MENU_ROWS[${row_key}]+set}" ]]; then
        row="${CNTOOLS_GUM_MENU_ROWS[${row_key}]}"
      else
        cntools_gum_menu_row_into row "${index}" || return 1
        CNTOOLS_GUM_MENU_ROW_KEYS["${row_key}"]="${row_signature}"
        CNTOOLS_GUM_MENU_ROWS["${row_key}"]="${row}"
      fi
      rows+=("${row}")
      row_types+=("item")
      row_indices+=("${index}")
    done
    if [[ "${context}" == "Y" ]]; then
      rows+=("← Back" "⌂ Home")
      row_types+=("back" "home")
      row_indices+=("-1" "-1")
    fi
    rows+=("✕ Quit CNTools")
    row_types+=("quit")
    row_indices+=("-1")
    height="$(cntools_gum_filter_height \
      "${#rows[@]}" "${rows_above_filter}")" || return 1

    selected_row=""
    if cntools_gum_filter selected_row "${height}" "${rows[@]}"; then
      filter_status=0
    else
      filter_status=$?
    fi
    if (( filter_status == 1 )); then
      # Gum v2 reports its second-Escape cancellation as status 1 and writes
      # "nothing selected" after restoring the terminal. Clear that transient
      # diagnostic before drawing the parent or root menu.
      cntools_gum_clear
      if [[ "${context}" == "Y" ]]; then
        unset 'menu_stack[stack_index]'
        cntools_gum_log MENU "back (filter cancelled)"
      else
        cntools_gum_log MENU "root menu redraw (filter cancelled)"
      fi
      continue
    elif (( filter_status == 130 )); then
      cntools_gum_log MENU "abort (filter interrupted)"
      return 130
    elif (( filter_status != 0 )); then
      cntools_gum_log ERROR "Gum filter failed with status ${filter_status}"
      printf 'CNTools: Gum menu selection failed (status %s).\n' \
        "${filter_status}" >&2
      return "${filter_status}"
    fi

    mapping=-1
    for (( index = 0; index < ${#rows[@]}; index++ )); do
      if [[ "${selected_row}" == "${rows[index]}" ]]; then
        mapping="${index}"
        break
      fi
    done
    if (( mapping < 0 )); then
      cntools_gum_log ERROR "Gum filter returned an unknown menu row"
      status_level="error"
      status_message="The selected row was not recognized; please try again."
      continue
    fi
    selected_type="${row_types[mapping]}"
    selected_index="${row_indices[mapping]}"

    case "${selected_type}" in
      back)
        unset 'menu_stack[stack_index]'
        cntools_gum_log MENU "back"
        continue
        ;;
      home)
        menu_stack=("${CNTOOLS_MENU_CACHE_MENU_DIRS[${CNTOOLS_MENU_ROOT_ID}]}")
        cntools_gum_log MENU "home"
        continue
        ;;
      quit)
        cntools_gum_log MENU "quit"
        return 0
        ;;
      item) ;;
      *)
        cntools_gum_log ERROR "Unknown Gum menu row type: ${selected_type}"
        return 1
        ;;
    esac

    if [[ "${CNTOOLS_MENU_KINDS[selected_index]}" == "menu" ]]; then
      cntools_gum_log MENU "selected ${CNTOOLS_MENU_IDS[selected_index]}"
      menu_stack+=("${CNTOOLS_MENU_PATHS[selected_index]}")
      continue
    fi
    if [[ "${CNTOOLS_MENU_ENABLED[selected_index]}" != "Y" ]]; then
      status_level="warn"
      status_message="${CNTOOLS_MENU_DISABLED_REASONS[selected_index]}"
      cntools_gum_log ACTION \
        "blocked ${CNTOOLS_MENU_IDS[selected_index]}: ${CNTOOLS_MENU_DISABLED_REASONS[selected_index]}"
      continue
    fi

    cntools_gum_log MENU "selected ${CNTOOLS_MENU_IDS[selected_index]}"
    if cntools_action_run "${CNTOOLS_MENU_PATHS[selected_index]}"; then
      action_status=0
    else
      action_status=$?
    fi
    if declare -F cntools_startup_deployment_was_started >/dev/null 2>&1 &&
       cntools_startup_deployment_was_started; then
      cntools_gum_log SESSION \
        "Guild Deploy completed with status ${action_status}; closing the current CNTools process"
      return "${action_status}"
    fi
    # Actions run in an isolated shell. Only the Theme action can change the
    # persisted selection, so avoid filesystem work after every other action.
    if [[ "${CNTOOLS_MENU_IDS[selected_index]}" == "advanced/theme" ]] &&
       declare -F cntools_theme_reload >/dev/null 2>&1 &&
       ! cntools_theme_reload; then
      cntools_gum_log ERROR \
        "Could not activate the saved CNTools theme in the parent session"
      (( action_status != 0 )) || action_status=1
    fi
    if (( action_status != 0 )); then
      status_level="error"
      status_message="${CNTOOLS_MENU_LABELS[selected_index]} failed (status ${action_status})."
      cntools_gum_log ERROR \
        "action ${CNTOOLS_MENU_IDS[selected_index]} failed with status ${action_status}"
    fi
  done
}
