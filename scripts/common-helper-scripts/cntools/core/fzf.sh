#!/usr/bin/env bash
# fzf menu picker for CNTools. Functions only; sourced after gum.sh, whose
# install directory, checksum, archive and log helpers it reuses.
#
# fzf is optional. With it, typing the highlighted start of a menu item's name
# (or its number) opens it at once; without it the menu uses "gum filter".
# Gum still draws everything else. Settings → Navigation chooses between them.
# shellcheck disable=SC2034

CNTOOLS_FZF_VERSION="0.75.0"
CNTOOLS_FZF_RELEASE_ROOT="https://github.com/junegunn/fzf/releases/download/v${CNTOOLS_FZF_VERSION}"
# From the release's fzf_0.75.0_checksums.txt.
CNTOOLS_FZF_SHA256_AMD64="0d6640f83582d991cf429754baad64b07e3a4e439a6019670f4b91da1314141c"
CNTOOLS_FZF_SHA256_ARM64="bd0717badb6a5620387e014bb94209aac4d9eab6ab77b5348eabb0833aeb4d59"
CNTOOLS_FZF_BIN="${CNTOOLS_FZF_BIN:-}"
# The path whose version was checked this session; the menu uses fzf only then.
CNTOOLS_FZF_VERIFIED=""
CNTOOLS_FZF_INSTALL_TMP=""
CNTOOLS_FZF_INSTALL_STAGE=""
# Rows with highlighted names, rebuilt only when a menu's rows change.
declare -Ag CNTOOLS_FZF_LINES_KEYS=()
declare -Ag CNTOOLS_FZF_LINES=()

# --- Install ----------------------------------------------------------------
# The offer mirrors Gum's: same directory, pinned version and checksum, staged
# and verified before it replaces anything. Every failure is a warning, never a
# reason to stop CNTools.

cntools_fzf_warn() {
  local detail="${1:-}"

  [[ -z "${detail}" ]] || printf 'CNTools: %s\n' "${detail}" >&2
  cntools_gum_log ERROR "fzf install: ${detail}"
  return 1
}

# Prints "<release-arch> <pinned-sha256>" for this machine; fails on anything
# the pinned release cannot serve (non-Linux, other architectures).
cntools_fzf_release_target() {
  local system="" machine=""

  system="$(uname -s 2>/dev/null)" || return 1
  machine="$(uname -m 2>/dev/null)" || return 1
  [[ "${system}" == "Linux" ]] || return 1
  case "${machine}" in
    x86_64|amd64) printf 'amd64 %s\n' "${CNTOOLS_FZF_SHA256_AMD64}" ;;
    aarch64|arm64) printf 'arm64 %s\n' "${CNTOOLS_FZF_SHA256_ARM64}" ;;
    *) return 1 ;;
  esac
}

cntools_fzf_version_exact() {
  local candidate="${1:-}"
  local raw=""

  [[ -n "${candidate}" && "${candidate}" = /* && -x "${candidate}" ]] ||
    return 1
  raw="$("${candidate}" --version 2>/dev/null)" || return 1
  [[ "${raw}" == "${CNTOOLS_FZF_VERSION}" ||
     "${raw}" == "${CNTOOLS_FZF_VERSION} "* ]]
}

cntools_fzf_install_cleanup() {
  local temporary="${CNTOOLS_FZF_INSTALL_TMP:-}"
  local stage="${CNTOOLS_FZF_INSTALL_STAGE:-}"

  if [[ -n "${stage}" && "${stage}" = */.fzf.* &&
        -f "${stage}" && ! -L "${stage}" && -O "${stage}" ]]; then
    rm -f -- "${stage}" 2>/dev/null || true
  fi
  if [[ -n "${temporary}" && -d "${temporary}" &&
        ! -L "${temporary}" && -O "${temporary}" ]]; then
    rm -f -- \
      "${temporary}/extract/fzf" \
      "${temporary}/archive.tar.gz" 2>/dev/null || true
    rmdir -- "${temporary}/extract" 2>/dev/null || true
    rmdir -- "${temporary}" 2>/dev/null || true
  fi
  CNTOOLS_FZF_INSTALL_TMP=""
  CNTOOLS_FZF_INSTALL_STAGE=""
}

cntools_fzf_install() {
  local target_info=""
  local release_arch=""
  local pinned_digest=""
  local archive_name=""
  local archive_url=""
  local install_directory=""
  local target=""
  local archive=""
  local extract_directory=""
  local member=""
  local actual=""
  local previous_umask=""
  local command_name=""
  local -a missing=()

  if [[ "${CNTOOLS_MODE:-}" == "offline" ]]; then
    cntools_fzf_warn "Automatic fzf installation is unavailable in offline mode."
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
    cntools_fzf_warn "Cannot install fzf; required command(s) missing: ${missing[*]}."
    return 1
  fi
  target_info="$(cntools_fzf_release_target)" || {
    cntools_fzf_warn "Automatic fzf installation supports Linux on x86_64 and arm64 only."
    return 1
  }
  release_arch="${target_info%% *}"
  pinned_digest="${target_info#* }"

  install_directory="$(cntools_gum_install_directory 2>/dev/null)" || {
    cntools_fzf_warn "The install directory must be an absolute, single-line path."
    return 1
  }
  if declare -F cntools_filesystem_path_components_safe >/dev/null 2>&1 &&
     ! cntools_filesystem_path_components_safe "${install_directory}"; then
    cntools_fzf_warn "The install directory contains an unsafe symbolic link: ${install_directory}."
    return 1
  fi
  previous_umask="$(umask)"
  umask 077
  if ! mkdir -p -- "${install_directory}"; then
    umask "${previous_umask}"
    cntools_fzf_warn "Could not create the install directory: ${install_directory}."
    return 1
  fi
  umask "${previous_umask}"
  [[ -d "${install_directory}" && ! -L "${install_directory}" &&
     -O "${install_directory}" && -w "${install_directory}" ]] || {
    cntools_fzf_warn "The install directory is not a safe user-owned directory: ${install_directory}."
    return 1
  }
  install_directory="$(cd -- "${install_directory}" && pwd -P)" || return 1
  target="${install_directory}/fzf"
  if [[ -e "${target}" || -L "${target}" ]]; then
    [[ -f "${target}" && ! -L "${target}" && -O "${target}" ]] || {
      cntools_fzf_warn "The local fzf target is unsafe and was not replaced: ${target}."
      return 1
    }
  fi

  archive_name="fzf-${CNTOOLS_FZF_VERSION}-linux_${release_arch}.tar.gz"
  archive_url="${CNTOOLS_FZF_RELEASE_ROOT}/${archive_name}"
  previous_umask="$(umask)"
  umask 077
  CNTOOLS_FZF_INSTALL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cntools-fzf-install.XXXXXX")" || {
    umask "${previous_umask}"
    cntools_fzf_warn "Could not create a private fzf staging directory."
    return 1
  }
  umask "${previous_umask}"
  archive="${CNTOOLS_FZF_INSTALL_TMP}/archive.tar.gz"
  extract_directory="${CNTOOLS_FZF_INSTALL_TMP}/extract"
  mkdir -- "${extract_directory}" || {
    cntools_fzf_install_cleanup
    return 1
  }

  cntools_gum_log DEPENDENCY \
    "install fzf v${CNTOOLS_FZF_VERSION} archive=${archive_name}"
  cntools_gum_log API \
    "GET /junegunn/fzf/releases/download/v${CNTOOLS_FZF_VERSION}/${archive_name}"
  if ! curl --fail --silent --show-error --location --proto '=https' \
      --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 180 \
      --max-filesize 16777216 --output "${archive}" "${archive_url}"; then
    cntools_fzf_install_cleanup
    cntools_fzf_warn "Could not download the official fzf archive."
    return 1
  fi
  # The digest is pinned in this file (from the release's own checksum list),
  # so a tampered or substituted download cannot pass.
  actual="$(cntools_gum_sha256 "${archive}" 2>/dev/null)" || actual=""
  if [[ -z "${actual}" || "${actual}" != "${pinned_digest}" ]]; then
    cntools_fzf_install_cleanup
    cntools_fzf_warn "The downloaded fzf archive failed checksum verification."
    return 1
  fi
  member="$(cntools_gum_archive_member "${archive}" "fzf" 2>/dev/null)" || {
    cntools_fzf_install_cleanup
    cntools_fzf_warn "The downloaded fzf archive has an unsafe structure."
    return 1
  }
  if ! tar -xOzf "${archive}" -- "${member}" > "${extract_directory}/fzf" ||
     [[ ! -f "${extract_directory}/fzf" ||
        -L "${extract_directory}/fzf" ||
        ! -s "${extract_directory}/fzf" ]]; then
    cntools_fzf_install_cleanup
    cntools_fzf_warn "Could not safely extract the fzf executable."
    return 1
  fi
  CNTOOLS_FZF_INSTALL_STAGE="$(mktemp "${install_directory}/.fzf.XXXXXX")" || {
    cntools_fzf_install_cleanup
    cntools_fzf_warn "Could not stage fzf in ${install_directory}."
    return 1
  }
  if ! install -m 0755 "${extract_directory}/fzf" "${CNTOOLS_FZF_INSTALL_STAGE}" ||
     ! cntools_fzf_version_exact "${CNTOOLS_FZF_INSTALL_STAGE}"; then
    cntools_fzf_install_cleanup
    cntools_fzf_warn "The staged fzf executable is not v${CNTOOLS_FZF_VERSION}."
    return 1
  fi
  if ! mv -f -- "${CNTOOLS_FZF_INSTALL_STAGE}" "${target}" ||
     ! chmod 0755 "${target}" ||
     ! cntools_fzf_version_exact "${target}"; then
    cntools_fzf_install_cleanup
    cntools_fzf_warn "Could not activate fzf at ${target}."
    return 1
  fi
  CNTOOLS_FZF_INSTALL_STAGE=""
  CNTOOLS_FZF_BIN="${target}"
  CNTOOLS_FZF_VERIFIED="${target}"
  export CNTOOLS_FZF_BIN
  cntools_fzf_install_cleanup
  cntools_gum_log DEPENDENCY \
    "installed fzf v${CNTOOLS_FZF_VERSION} path=${CNTOOLS_FZF_BIN}"
  printf 'CNTools: installed fzf v%s at %s.\n' \
    "${CNTOOLS_FZF_VERSION}" "${CNTOOLS_FZF_BIN}"
}

# Where a "no" is remembered, so the offer is not repeated on every launch. It
# records the version that was declined, so a newer pinned fzf is offered again.
cntools_fzf_declined_file() {
  declare -F cntools_settings_state_directory_ready >/dev/null 2>&1 || return 1
  cntools_settings_state_directory_ready || return 1
  printf '%s/fzf-offer-declined\n' "${CNTOOLS_SETTINGS_STATE_DIR}"
}

cntools_fzf_declined() {
  local file="" recorded=""

  file="$(cntools_fzf_declined_file 2>/dev/null)" || return 1
  [[ -f "${file}" && ! -L "${file}" && -O "${file}" ]] || return 1
  IFS= read -r recorded < "${file}" || true
  [[ "${recorded}" == "${CNTOOLS_FZF_VERSION}" ]]
}

cntools_fzf_remember_decline() {
  local file="" previous_umask=""

  file="$(cntools_fzf_declined_file 2>/dev/null)" || return 0
  previous_umask="$(umask)"
  umask 077
  printf '%s\n' "${CNTOOLS_FZF_VERSION}" > "${file}" 2>/dev/null || true
  umask "${previous_umask}"
}

# Settings → Navigation asks again even after a "no" at startup.
cntools_fzf_forget_decline() {
  local file=""

  file="$(cntools_fzf_declined_file 2>/dev/null)" || return 0
  [[ -f "${file}" && ! -L "${file}" && -O "${file}" ]] || return 0
  rm -f -- "${file}" 2>/dev/null || true
}

# Only the pinned version is used, as with Gum: the picker relies on options
# and events that older releases do not have.
cntools_fzf_find() {
  local candidate=""
  local install_directory=""
  local command_path=""
  local -a candidates=()

  if [[ -n "${CNTOOLS_FZF_BIN:-}" ]]; then
    if candidate="$(cntools_gum_absolute_command \
        "${CNTOOLS_FZF_BIN}" 2>/dev/null)" &&
       cntools_fzf_version_exact "${candidate}"; then
      CNTOOLS_FZF_BIN="${candidate}"
      CNTOOLS_FZF_VERIFIED="${candidate}"
      export CNTOOLS_FZF_BIN
      return 0
    fi
    CNTOOLS_FZF_BIN=""
  fi
  CNTOOLS_FZF_VERIFIED=""
  install_directory="$(cntools_gum_install_directory 2>/dev/null || true)"
  [[ -z "${install_directory}" ]] || candidates+=("${install_directory}/fzf")
  command_path="$(type -P fzf 2>/dev/null || true)"
  [[ -z "${command_path}" ]] || candidates+=("${command_path}")
  for candidate in "${candidates[@]}"; do
    candidate="$(cntools_gum_absolute_command "${candidate}" 2>/dev/null)" ||
      continue
    if cntools_fzf_version_exact "${candidate}"; then
      CNTOOLS_FZF_BIN="${candidate}"
      CNTOOLS_FZF_VERIFIED="${candidate}"
      export CNTOOLS_FZF_BIN
      return 0
    fi
  done
  return 1
}

# Another fzf on this machine, as "<version> <path>", for the install offer.
cntools_fzf_other_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_path="" _cntools_version=""

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  _cntools_path="$(type -P fzf 2>/dev/null)" || return 1
  _cntools_path="$(cntools_gum_absolute_command "${_cntools_path}" 2>/dev/null)" ||
    return 1
  _cntools_version="$("${_cntools_path}" --version 2>/dev/null)" || return 1
  _cntools_version="${_cntools_version%% *}"
  [[ "${_cntools_version}" =~ ^[0-9][0-9.]*$ ]] || _cntools_version="unknown"
  _cntools_output_ref="${_cntools_version} ${_cntools_path}"
}

# Adds to the main menu's status line, after any message from earlier startup
# steps, which keeps its level.
cntools_fzf_startup_status() {
  local level="${1:-info}"
  local message="${2:-}"
  local earlier="${CNTOOLS_GUM_STARTUP_STATUS_MESSAGE:-}"

  [[ -n "${earlier}" ]] || CNTOOLS_GUM_STARTUP_STATUS_LEVEL="${level}"
  CNTOOLS_GUM_STARTUP_STATUS_MESSAGE="${earlier:+${earlier} }${message}"
}

# Offer the pinned fzf at startup when it is missing. Always succeeds: a "no",
# an unsupported platform, offline mode or a failed download all keep the Gum
# filter. A "no" is remembered until the pinned version changes.
cntools_fzf_require() {
  local answer=""
  local install_directory=""
  local other=""

  [[ "${CNTOOLS_MENU_NAVIGATION:-}" != "filter" ]] || return 0
  if cntools_fzf_find; then
    cntools_gum_log DEPENDENCY "using fzf path=${CNTOOLS_FZF_BIN}"
    return 0
  fi
  [[ -t 0 && -t 1 ]] || return 0
  [[ "${CNTOOLS_MODE:-}" != "offline" ]] || return 0
  cntools_fzf_release_target >/dev/null 2>&1 || return 0
  ! cntools_fzf_declined || return 0
  install_directory="$(cntools_gum_install_directory 2>/dev/null)" || return 0

  printf 'CNTools menus can open an item as soon as you type the highlighted start of its name.\n'
  if cntools_fzf_other_into other; then
    printf 'This uses fzf %s; the fzf found here is %s at %s.\n' \
      "${CNTOOLS_FZF_VERSION}" "${other%% *}" "${other#* }"
  else
    printf 'This uses fzf %s, which was not found. Without it, menus use the Gum filter.\n' \
      "${CNTOOLS_FZF_VERSION}"
  fi
  printf 'Install fzf v%s in %s? [y/N]: ' \
    "${CNTOOLS_FZF_VERSION}" "${install_directory}"
  IFS= read -r answer || answer=""
  case "${answer,,}" in
    y|yes)
      cntools_gum_log DEPENDENCY "fzf installation accepted"
      if cntools_fzf_install; then
        cntools_fzf_startup_status success \
          "fzf ${CNTOOLS_FZF_VERSION} installed: type the highlighted letters to open a menu item."
      else
        cntools_fzf_startup_status warn \
          "fzf could not be installed, so menus use the Gum filter. See ${CNTOOLS_LOG:-the CNTools log}."
      fi
      ;;
    *)
      cntools_gum_log DEPENDENCY "fzf installation declined"
      cntools_fzf_remember_decline
      cntools_fzf_startup_status info \
        "Menus use the Gum filter. Settings → Navigation can install fzf later."
      ;;
  esac
  return 0
}

# --- Menu picker ------------------------------------------------------------

# How the menu answers typing, from Settings → Navigation:
#   hotkeys        fzf; the highlighted start of a name or a number opens it
#   hotkeys-enter  fzf; the same keys narrow the list, Enter opens
#   filter         gum filter over the whole row, Enter opens
# Unset means hotkeys. Both fzf choices fall back to the Gum filter without fzf.
cntools_fzf_available() {
  [[ "${CNTOOLS_MENU_NAVIGATION:-}" != "filter" &&
     -n "${CNTOOLS_FZF_VERIFIED:-}" &&
     "${CNTOOLS_FZF_BIN:-}" == "${CNTOOLS_FZF_VERIFIED}" &&
     -x "${CNTOOLS_FZF_BIN}" ]]
}

# The fzf --color spec from the active theme, matching the Gum filter: plain
# weight where fzf would bold the prompt, pointer and current row, which also
# keeps the hotkeys the only bold text. A role whose
# colour is not #rrggbb is left out, so a partial theme cannot break fzf.
cntools_fzf_color_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_pair="" _cntools_value=""
  local -a _cntools_pairs=(
    "fg ${CNTOOLS_GUM_COLOR_TEXT:-}"
    "fg+ ${CNTOOLS_GUM_COLOR_TEXT:-}"
    "bg+ ${CNTOOLS_GUM_COLOR_SURFACE:-}"
    "query ${CNTOOLS_GUM_COLOR_TEXT:-}"
    "disabled ${CNTOOLS_GUM_COLOR_TEXT:-}"
    "prompt ${CNTOOLS_GUM_COLOR_BRAND:-}"
    "pointer ${CNTOOLS_GUM_COLOR_BRAND:-}"
    "ghost ${CNTOOLS_GUM_COLOR_MUTED:-}"
    "footer ${CNTOOLS_GUM_COLOR_MUTED:-}"
  )

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  _cntools_output_ref=""
  for _cntools_pair in "${_cntools_pairs[@]}"; do
    _cntools_value="${_cntools_pair#* }"
    [[ "${_cntools_value}" =~ ^#[0-9A-Fa-f]{6}$ ]] || continue
    _cntools_pair="${_cntools_pair%% *}:${_cntools_value}"
    case "${_cntools_pair%%:*}" in
      fg+|prompt|pointer) _cntools_pair+=":regular" ;;
    esac
    _cntools_output_ref="${_cntools_output_ref:+${_cntools_output_ref},}${_cntools_pair}"
  done
}

# For each name, the length of its shortest start that no other name in the
# menu shares, ignoring case: the keys that open it. 0 when there is none
# (the whole name starts another one).
cntools_fzf_hotkey_lengths_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_names_name="${2:-}"
  local _cntools_i=0 _cntools_j=0 _cntools_length=0 _cntools_found=0
  local _cntools_prefix="" _cntools_unique=""
  local -a _cntools_lower=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_names_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_lengths_ref="${_cntools_output_name}"
  local -n _cntools_names_ref="${_cntools_names_name}"
  _cntools_lengths_ref=()
  for (( _cntools_i = 0; _cntools_i < ${#_cntools_names_ref[@]}; _cntools_i++ )); do
    _cntools_lower[_cntools_i]="${_cntools_names_ref[_cntools_i],,}"
  done
  for (( _cntools_i = 0; _cntools_i < ${#_cntools_lower[@]}; _cntools_i++ )); do
    _cntools_found=0
    for (( _cntools_length = 1;
           _cntools_length <= ${#_cntools_lower[_cntools_i]};
           _cntools_length++ )); do
      _cntools_prefix="${_cntools_lower[_cntools_i]:0:_cntools_length}"
      _cntools_unique=Y
      for (( _cntools_j = 0; _cntools_j < ${#_cntools_lower[@]}; _cntools_j++ )); do
        (( _cntools_j != _cntools_i )) || continue
        if [[ "${_cntools_lower[_cntools_j]}" == "${_cntools_prefix}"* ]]; then
          _cntools_unique=N
          break
        fi
      done
      if [[ "${_cntools_unique}" == Y ]]; then
        _cntools_found="${_cntools_length}"
        break
      fi
    done
    _cntools_lengths_ref+=("${_cntools_found}")
  done
}

# The terminal codes that mark hotkeys: bold in the theme's brand colour, or
# underlined when NO_COLOR is set.
cntools_fzf_hotkey_style_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_hex="${CNTOOLS_GUM_COLOR_BRAND:-}"

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  if [[ -n "${NO_COLOR:-}" || ! "${_cntools_hex}" =~ ^#[0-9A-Fa-f]{6}$ ]]; then
    _cntools_output_ref=$'\033[4m'
    return 0
  fi
  _cntools_hex="${_cntools_hex#\#}"
  printf -v _cntools_output_ref '\033[1;38;2;%d;%d;%dm' \
    "$((16#${_cntools_hex:0:2}))" "$((16#${_cntools_hex:2:2}))" \
    "$((16#${_cntools_hex:4:2}))"
}

# Lines for fzf: "<index>TAB<number>TAB<name>TAB<row>", where <row> is the menu
# row with the hotkey part of its name highlighted. Keys are "<number>TAB<name>"
# (number empty for Back, Home and Quit). Cached per menu until a row changes.
cntools_fzf_menu_lines_into() {
  local _cntools_output_name="${1:-}"
  local _cntools_cache_key="${2:-}"
  local _cntools_keys_name="${3:-}"
  local _cntools_rows_name="${4:-}"
  local _cntools_signature="" _cntools_style="" _cntools_off=$'\033[0m'
  local _cntools_row="" _cntools_name="" _cntools_number="" _cntools_head=""
  local _cntools_index=0 _cntools_length=0
  local -a _cntools_names=() _cntools_numbers=() _cntools_lengths=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_keys_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_rows_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
  local -n _cntools_lines_ref="${_cntools_output_name}"
  local -n _cntools_keys_ref="${_cntools_keys_name}"
  local -n _cntools_rows_ref="${_cntools_rows_name}"
  _cntools_lines_ref=()
  (( ${#_cntools_rows_ref[@]} > 0 &&
     ${#_cntools_keys_ref[@]} == ${#_cntools_rows_ref[@]} )) || return 2

  cntools_fzf_hotkey_style_into _cntools_style || return 1
  printf -v _cntools_signature '%s\036' "${_cntools_style}" \
    "${_cntools_keys_ref[@]}" "${_cntools_rows_ref[@]}"
  if [[ -n "${_cntools_cache_key}" &&
        "${CNTOOLS_FZF_LINES_KEYS[${_cntools_cache_key}]:-}" == "${_cntools_signature}" ]]; then
    mapfile -t _cntools_lines_ref <<< "${CNTOOLS_FZF_LINES[${_cntools_cache_key}]}"
    return 0
  fi

  for (( _cntools_index = 0;
         _cntools_index < ${#_cntools_keys_ref[@]};
         _cntools_index++ )); do
    _cntools_row="${_cntools_keys_ref[_cntools_index]}"
    [[ "${_cntools_row}" == *$'\t'* && "${_cntools_row}" != *$'\t'*$'\t'* &&
       "${_cntools_rows_ref[_cntools_index]}" != *[$'\t\n']* ]] || return 2
    _cntools_numbers[_cntools_index]="${_cntools_row%%$'\t'*}"
    _cntools_names[_cntools_index]="${_cntools_row#*$'\t'}"
  done
  cntools_fzf_hotkey_lengths_into _cntools_lengths _cntools_names || return 1

  for (( _cntools_index = 0;
         _cntools_index < ${#_cntools_rows_ref[@]};
         _cntools_index++ )); do
    _cntools_row="${_cntools_rows_ref[_cntools_index]}"
    _cntools_name="${_cntools_names[_cntools_index]}"
    _cntools_number="${_cntools_numbers[_cntools_index]}"
    _cntools_length="${_cntools_lengths[_cntools_index]}"
    # The name follows the number and marker, which never contain it.
    _cntools_head="${_cntools_row%%"${_cntools_name}"*}"
    if (( _cntools_length > 0 )) && [[ "${_cntools_head}" != "${_cntools_row}" ]]; then
      _cntools_row="${_cntools_head}${_cntools_style}${_cntools_name:0:_cntools_length}${_cntools_off}${_cntools_row:${#_cntools_head}+_cntools_length}"
    fi
    _cntools_lines_ref+=("${_cntools_index}"$'\t'"${_cntools_number}"$'\t'"${_cntools_name}"$'\t'"${_cntools_row}")
  done
  if [[ -n "${_cntools_cache_key}" ]]; then
    printf -v _cntools_head '%s\n' "${_cntools_lines_ref[@]}"
    CNTOOLS_FZF_LINES["${_cntools_cache_key}"]="${_cntools_head%$'\n'}"
    CNTOOLS_FZF_LINES_KEYS["${_cntools_cache_key}"]="${_cntools_signature}"
  fi
}

# The rule fzf runs on every keystroke (it only draws the list; --disabled
# turns its own matching off). A query that starts with a digit keeps rows
# whose number contains it; anything else keeps rows whose name starts with it,
# ignoring case. Descriptions are never searched.
cntools_fzf_filter_program() {
  cat <<'AWK'
BEGIN {
  FS = "\t"
  q = tolower(ENVIRON["Q"])
  sub(/^ +/, "", q)
  sub(/ +$/, "", q)
}
q == "" { print; next }
q ~ /^[0-9]/ { if ($2 != "" && index($2, q) > 0) print; next }
{ if (index(tolower($3), q) == 1) print }
AWK
}

# What fzf does when the query changes. A key that would leave no row is
# dropped, so a wrong key does nothing, as in earlier CNTools menus; otherwise
# the list is refreshed. Checking here, against the query itself, avoids the
# stale counts fzf reports between reloads.
cntools_fzf_step_program() {
  cat <<'SH'
dir=${0%/*}
if Q="$1" awk -f "$dir/filter.awk" "$dir/rows" | grep -q .; then
  printf '%s\n' "reload:env Q={q} awk -f '$dir/filter.awk' '$dir/rows'"
else
  printf '%s\n' backward-delete-char
fi
SH
}

# Name-prefix menu picker backed by fzf, laid out like the Gum filter beside
# it. Mirrors cntools_gum_filter's contract: the chosen row goes to the named
# variable; 0 selected, 1 back (Escape, Left, or no row), 130 interrupted, and
# 2 or more when fzf itself failed.
#   cntools_fzf_filter <output> <height> <keys array> <rows array> [cache key]
cntools_fzf_filter() {
  cntools_ui_seen
  local _cntools_output_name="${1:-}"
  local _cntools_height="${2:-12}"
  local _cntools_keys_name="${3:-}"
  local _cntools_rows_name="${4:-}"
  local _cntools_cache_key="${5:-}"
  local _cntools_color="" _cntools_ghost="" _cntools_footer=""
  local _cntools_result="" _cntools_status=0 _cntools_work=""
  local _cntools_width=0 _cntools_columns=0 _cntools_right=0
  local _cntools_pressed="" _cntools_chosen=""
  local -a _cntools_fzf_args=() _cntools_out_lines=() _cntools_lines=()

  [[ "${_cntools_output_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_keys_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_rows_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
     "${_cntools_height}" =~ ^[1-9][0-9]*$ ]] || return 2
  local -n _cntools_output_ref="${_cntools_output_name}"
  local -n _cntools_rows_ref="${_cntools_rows_name}"
  _cntools_output_ref=""
  cntools_fzf_available || return 127
  cntools_fzf_menu_lines_into _cntools_lines "${_cntools_cache_key}" \
    "${_cntools_keys_name}" "${_cntools_rows_name}" || return 2

  # fzf re-runs the filter in a child process on each keystroke, so the rows
  # and program live in a private scratch folder removed below.
  _cntools_work="$(umask 077; mktemp -d \
    "${CNTOOLS_TMP_DIR:-${TMPDIR:-/tmp}}/cntools-fzf.XXXXXX")" || return 2
  if [[ "${_cntools_work}" == *[\'$'\n']* ]]; then
    rm -rf -- "${_cntools_work}"
    return 2
  fi
  if ! printf '%s\n' "${_cntools_lines[@]}" >"${_cntools_work}/rows" ||
     ! cntools_fzf_filter_program >"${_cntools_work}/filter.awk" ||
     ! cntools_fzf_step_program >"${_cntools_work}/step"; then
    rm -rf -- "${_cntools_work}"
    return 2
  fi

  # The same frame as the Gum filter: its width, two columns of padding on
  # the left and one row below. The right edge sits where Gum's padding ends,
  # so the rows Gum shows in full are not cut off by fzf's wider pointer.
  _cntools_width="$(cntools_gum_width)" || _cntools_width=78
  _cntools_columns="${COLUMNS:-}"
  [[ "${_cntools_columns}" =~ ^[0-9]+$ ]] ||
    _cntools_columns="$(tput cols 2>/dev/null || printf '80')"
  [[ "${_cntools_columns}" =~ ^[0-9]+$ ]] || _cntools_columns=80
  _cntools_right=$((_cntools_columns - _cntools_width))
  (( _cntools_right >= 0 )) || _cntools_right=0

  if [[ "${CNTOOLS_MENU_NAVIGATION:-}" == "hotkeys-enter" ]]; then
    _cntools_ghost="Type the start of a name or a number…"
    _cntools_footer="↓↑ navigate • letters narrow • esc back • enter submit"
  else
    _cntools_ghost="Type the highlighted letters or a number…"
    _cntools_footer="↓↑ navigate • letters open • esc back • enter submit"
  fi

  # shellcheck disable=SC2054 # the commas separate fzf bindings
  _cntools_fzf_args=(
    --ansi --disabled --no-multi --layout=reverse
    --delimiter=$'\t' --with-nth=4 --accept-nth=1
    --with-shell='sh -c'
    --bind="change:transform:sh '${_cntools_work}/step' {q}"
    # Enter with nothing listed does nothing (accept-non-empty still exits
    # when matching is disabled).
    --bind='enter:transform:[ "$FZF_MATCH_COUNT" -gt 0 ] && echo accept || true'
    # fzf would abort on these; only Ctrl+C leaves CNTools, as with Gum.
    --bind=ctrl-g:ignore,ctrl-q:ignore
    # Escape and Left leave for the parent menu, like the Back row; fzf
    # accepts on either and names the key on the first output line.
    --expect=esc,left
    --height="${_cntools_height}" --margin="0,${_cntools_right},1,2"
    --info=hidden --no-separator --no-scrollbar --gutter=' '
    --prompt='› ' --pointer='▸ ' --ghost="${_cntools_ghost}"
    --footer="${_cntools_footer}" --footer-border=none
  )
  if [[ -n "${NO_COLOR:-}" ]]; then
    _cntools_fzf_args+=(--no-color)
  else
    cntools_fzf_color_into _cntools_color || true
    [[ -z "${_cntools_color}" ]] || _cntools_fzf_args+=(--color="${_cntools_color}")
  fi
  # A query that leaves one row opens it without another key.
  [[ "${CNTOOLS_MENU_NAVIGATION:-}" == "hotkeys-enter" ]] ||
    _cntools_fzf_args+=(--bind=one:accept)

  # The user's own fzf defaults (borders, previews, key bindings) would change
  # this picker, so they are left out.
  _cntools_result="$(
    unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE FZF_DEFAULT_COMMAND
    "${CNTOOLS_FZF_BIN}" "${_cntools_fzf_args[@]}" <"${_cntools_work}/rows"
  )" || _cntools_status=$?
  rm -rf -- "${_cntools_work}"

  (( _cntools_status != 130 )) || return 130
  # 1 is fzf's "nothing selected", which Escape with an empty list also gives.
  (( _cntools_status != 1 )) || return 1
  if (( _cntools_status != 0 )); then
    cntools_gum_log ERROR "fzf menu picker failed with status ${_cntools_status}"
    return "$(( _cntools_status < 2 ? 2 : _cntools_status ))"
  fi

  mapfile -t _cntools_out_lines <<< "${_cntools_result}"
  _cntools_pressed="${_cntools_out_lines[0]:-}"
  [[ "${_cntools_pressed}" != "esc" && "${_cntools_pressed}" != "left" ]] || return 1
  _cntools_chosen="${_cntools_out_lines[1]:-}"
  [[ "${_cntools_chosen}" =~ ^[0-9]+$ ]] &&
    (( _cntools_chosen < ${#_cntools_rows_ref[@]} )) || return 1
  _cntools_output_ref="${_cntools_rows_ref[_cntools_chosen]}"
}
