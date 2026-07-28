#!/usr/bin/env bash
# cnode implementation profile for the common guild-deploy.sh dispatcher.
# shellcheck disable=SC2086,SC1090,SC2059,SC2016,SC2034,SC2035,SC2329
# shellcheck source=/dev/null

# This file is an internal, source-only implementation profile.
# User-configurable deployment inputs belong in guild-deploy.sh.

export LANG="C.UTF-8"
export LC_ALL=${LANG}

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

if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" =~ (UTF-8|utf-8|utf8) ]]; then
  SYMBOL_RUN="…"
  SYMBOL_OK="✓"
  SYMBOL_INFO="i"
  SYMBOL_WARN="!"
  SYMBOL_ERROR="✗"
else
  SYMBOL_RUN=".."
  SYMBOL_OK="OK"
  SYMBOL_INFO="i"
  SYMBOL_WARN="!"
  SYMBOL_ERROR="X"
fi

ACTIVE_STEP="Initialize deployment"
ACTIVE_FLAG=""
CNODE_DEPLOY_NO_SELECTIVE_FLAGS="N"
CNODE_DEPLOY_ADDED_LOCAL_BIN_PATH="N"
CNODE_DEPLOY_FRESH_TARGET="N"

log_header() {
  printf "\n%sGuild Operators deployment%s\n" "${STYLE_BOLD}" "${STYLE_RESET}"
  printf "  Target  : %s\n" "${NODE_HOME}"
  printf "  Network : %s\n" "${NETWORK}"
  printf "  Branch  : %s\n" "${BRANCH}"
  if [[ -n "${S_ARGS}" ]]; then
    printf "  Flags   : -s %s\n" "${S_ARGS}"
  else
    printf "  Flags   : script/config refresh\n"
  fi
}

log_section() {
  printf "\n%s%s%s\n" "${STYLE_CYAN}${STYLE_BOLD}" "${1}" "${STYLE_RESET}"
}

log_progress() {
  ACTIVE_STEP="${1}"
  local detail="${2:-}"
  local line="  ${SYMBOL_RUN} ${1}"
  [[ -n "${detail}" ]] && line="${line} (${detail})"
  if [[ -t 1 ]]; then
    printf "\r\033[K%s" "${line}"
  else
    printf "%s\n" "${line}"
  fi
}

log_ok() {
  local step="${1:-${ACTIVE_STEP}}"
  local detail="${2:-}"
  local line="  ${SYMBOL_OK} ${step}"
  [[ -n "${detail}" ]] && line="${line} (${detail})"
  if [[ -t 1 ]]; then
    printf "\r\033[K%s%s%s\n" "${STYLE_GREEN}" "${line}" "${STYLE_RESET}"
  else
    printf "%s\n" "${line}"
  fi
  ACTIVE_STEP="${step}"
}

log_info() {
  [[ -t 1 ]] && printf "\r\033[K"
  printf "%s  ${SYMBOL_INFO} %s%s\n" "${STYLE_CYAN}" "${1}" "${STYLE_RESET}"
}

log_warn() {
  [[ -t 1 ]] && printf "\r\033[K"
  printf "%s  ${SYMBOL_WARN} %s%s\n" "${STYLE_YELLOW}" "${1}" "${STYLE_RESET}"
}

run_step() {
  local label="${1}"
  local flag="${2}"
  shift 2
  ACTIVE_STEP="${label}"
  ACTIVE_FLAG="${flag}"
  log_section "${label}"
  "$@"
}

get_answer() {
  printf "%s (yes/no): " "$*" >&2; read -r answer
  while :
  do
    case $answer in
    [Yy]*)
      return 0;;
    [Nn]*)
      return 1;;
    *) printf "%s" "Please enter 'yes' or 'no' to continue: " >&2; read -r answer
    esac
  done
}

# Description : Exit with error message
#             : $1 = Error message we'd like to display before exiting.
err_exit() {
  [[ -t 2 ]] && printf "\r\033[K" >&2
  printf "\n%s${SYMBOL_ERROR} Deployment failed%s\n" "${STYLE_RED}" "${STYLE_RESET}" >&2
  [[ -n "${ACTIVE_STEP}" ]] && printf "  Step : %s\n" "${ACTIVE_STEP}" >&2
  [[ -n "${ACTIVE_FLAG}" ]] && printf "  Flag : %s\n" "${ACTIVE_FLAG}" >&2
  printf "  Cause: %s\n" "${1:-Unknown error}" >&2
  pushd -0 >/dev/null && dirs -c
  exit 1
}

# Validate dispatcher context and initialise cnode-specific profile state.
cnode_deploy_init_context() {
  [[ "${PROFILE_MANAGED:-N}" == "Y" ]] ||
    err_exit "deploy-cnode.sh must be loaded by guild-deploy.sh."
  [[ "${NODE_IMPLEMENTATION:-}" == "cnode" ]] ||
    err_exit "cnode profile selected with NODE_IMPLEMENTATION='${NODE_IMPLEMENTATION:-unset}'."
  [[ -n "${NODE_HOME:-}" && -n "${NODE_NAME:-}" &&
     -n "${NODE_SERVICE:-}" && -n "${NETWORK:-}" &&
     -n "${BRANCH:-}" && -n "${G_ACCOUNT:-}" &&
     -n "${URL_RAW:-}" && -n "${CURL_TIMEOUT:-}" &&
     -n "${DOWNLOAD_TIMEOUT:-}" ]] ||
    err_exit "cnode profile received incomplete dispatcher context."
  [[ "${CNODE_SKIP_DBSYNC_DOWNLOAD:-}" =~ ^[YN]$ ]] ||
    err_exit "CNODE_SKIP_DBSYNC_DOWNLOAD must be Y or N."
  sudo="${sudo:-}"

  dirs -c # clear dir stack
  mkdir -p "${HOME}"/tmp "${HOME}"/git > /dev/null 2>&1
  [[ ! -d "${HOME}"/.local/bin ]] && mkdir -p "${HOME}"/.local/bin
  if ! grep -q '/.local/bin' "${HOME}"/.bashrc; then
    printf '\nexport PATH="${HOME}/.local/bin:${PATH}"\n' >> "${HOME}"/.bashrc
    CNODE_DEPLOY_ADDED_LOCAL_BIN_PATH="Y"
  fi

  # All cnode payload, toolchain and source dependency versions are loaded from
  # the validated release manifest installed by populate_cnode.
  CNODE_DEPLOY_ENV_PREFIX="$(printf '%s' "${NODE_NAME}" | tr '[:lower:]' '[:upper:]')"
  MITHRIL_HOME="${NODE_HOME}/mithril"
  U_ID="$(id -u)"
  G_ID="$(id -g)"
  OS_ID="$(grep -i ^id_like= /etc/os-release | cut -d= -f 2)"
  [[ -z "${OS_ID}" ]] && OS_ID="$(grep -i ^id= /etc/os-release | cut -d= -f 2)"
  DISTRO="$(grep -i ^NAME= /etc/os-release | cut -d= -f 2)"
  VERSION_ID="$(grep -i ^version_id= /etc/os-release | cut -d= -f 2 | tr -d '"' | cut -d. -f 1)"
  ARCH="$(uname -a)"
}

### Update file retaining existing custom configs
updateWithCustomConfig() {
  file=$1
  [[ $# -ne 2 ]] && subdir="cnode-helper-scripts" || subdir=$2
  ACTIVE_STEP="Refreshing ${file}"
  curl -s -f -m ${CURL_TIMEOUT} -o ${file}.tmp "${URL_RAW}/scripts/${subdir}/${file}"
  [[ ! -f ${file}.tmp ]] && err_exit "Failed to download '${file}' from GitHub"
  if [[ -f ${file} && ${CNODE_DEPLOY_FORCE_SCRIPTS} != 'Y' ]]; then
    if grep '^# Do NOT modify' ${file}.tmp >/dev/null 2>&1; then
      TEMPL_CMD=$(awk '/^# Do NOT modify/,0' ${file}.tmp)
      STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' ${file})
      printf '%s\n%s\n' "${STATIC_CMD}" "${TEMPL_CMD}" > ${file}.tmp
    else
      rm -f ${file}.tmp
      err_exit "Problems encountered while fetching \"${file}\" from Github, could be an issue with connectivity or Github site!"
    fi
  fi
  [[ ! -d ./archive ]] && mkdir archive
  [[ -f ${file} ]] && cp -f ${file} ./archive/"${file}_bkp$(date +%s)"
  mv -f ${file}.tmp ${file}
  [[ "${file}" == *.sh ]] && chmod 755 ${file}
}

# Install the complete common runtime as one transaction. All six members are
# downloaded and shell-validated before any installed member is replaced.
# Existing env user variables are retained unless script overwrite was
# explicitly requested. A failed or interrupted commit restores every member.
updateCommonRuntimeBundle() (
  local bundle_count=6
  local stage_root=""
  local target_lock_acquired="N"
  local transaction_active="N"
  local committed_count=0
  local i rollback_index rollback_ok restore_tmp
  local target_dir target_name remote_url
  local static_cmd templ_cmd archive_name archive_stamp
  local -a targets sources downloads candidates changed
  local -a commit_tmps backups existed

  targets=(
    "${NODE_HOME}/scripts/lib/deployment.library"
    "${NODE_HOME}/scripts/lib/env.library"
    "${NODE_HOME}/scripts/lib/node-api.library"
    "${NODE_HOME}/scripts/lib/systemd.library"
    "${NODE_HOME}/scripts/adapters/cnode.adapter"
    "${NODE_HOME}/scripts/env"
  )
  sources=(
    "common-helper-scripts/lib"
    "common-helper-scripts/lib"
    "common-helper-scripts/lib"
    "common-helper-scripts/lib"
    "cnode-helper-scripts"
    "common-helper-scripts"
  )
  downloads=()
  candidates=()
  changed=()
  commit_tmps=()
  backups=()
  existed=()

  _cnode_runtime_rollback() {
    local rollback_count="$1"

    rollback_ok="Y"
    for (( rollback_index = rollback_count - 1; rollback_index >= 0; rollback_index-- )); do
      [[ "${changed[rollback_index]:-N}" == "Y" ]] || continue
      if [[ "${existed[rollback_index]:-N}" == "Y" ]]; then
        target_dir="$(dirname "${targets[rollback_index]}")"
        target_name="$(basename "${targets[rollback_index]}")"
        restore_tmp="$(mktemp "${target_dir}/.${target_name}.restore.XXXXXX")" ||
          {
            rollback_ok="N"
            continue
          }
        if ! cp -p "${backups[rollback_index]}" "${restore_tmp}" ||
           ! mv -f "${restore_tmp}" "${targets[rollback_index]}"; then
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

  _cnode_runtime_cleanup() {
    local saved_status="${1:-$?}"
    local cleanup_index

    trap - EXIT HUP INT TERM
    if [[ "${transaction_active}" == "Y" && ${committed_count} -gt 0 ]]; then
      _cnode_runtime_rollback "${committed_count}" || true
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

  trap '_cnode_runtime_cleanup "$?"' EXIT
  trap 'exit 2' HUP INT TERM

  if ! declare -F deployment_target_lock_acquire >/dev/null 2>&1 ||
     ! deployment_target_lock_acquire "${NODE_HOME}"; then
    log_warn "Another deployment or runtime update is active for ${NODE_HOME}."
    return 2
  fi
  target_lock_acquired="Y"
  stage_root="$(mktemp -d "${NODE_HOME}/scripts/.common-runtime-install.XXXXXX")" ||
    return 2

  # Stage and validate all upstream files before deriving the env candidate.
  for (( i = 0; i < bundle_count; i++ )); do
    downloads[i]="${stage_root}/download.${i}"
    candidates[i]="${stage_root}/candidate.${i}"
    target_name="$(basename "${targets[i]}")"
    remote_url="${URL_RAW}/scripts/${sources[i]}/${target_name}"
    if ! curl -s -f -m "${CURL_TIMEOUT}" \
      -o "${downloads[i]}" "${remote_url}" 2>/dev/null; then
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
    cp "${downloads[i]}" "${candidates[i]}" || return 2
  done

  if [[ -f "${targets[5]}" && ${CNODE_DEPLOY_FORCE_SCRIPTS:-N} != "Y" ]]; then
    if ! grep -q '^# Do NOT modify' "${downloads[5]}"; then
      log_warn "Downloaded env file does not contain the expected template boundary."
      return 2
    fi
    static_cmd="$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${targets[5]}")"
    templ_cmd="$(awk '/^# Do NOT modify/,0' "${downloads[5]}")"
    printf '%s\n%s\n' "${static_cmd}" "${templ_cmd}" > "${candidates[5]}" ||
      return 2
  else
    cp "${downloads[5]}" "${candidates[5]}" || return 2
  fi
  bash -n "${candidates[5]}" >/dev/null 2>&1 || {
    log_warn "Merged common runtime env failed shell validation."
    return 2
  }

  for (( i = 0; i < bundle_count; i++ )); do
    chmod 0644 "${candidates[i]}" || return 2
    changed[i]="N"
    if [[ ! -f "${targets[i]}" ]] ||
       ! cmp -s "${targets[i]}" "${candidates[i]}" ||
       [[ -z "$(find "${targets[i]}" -prune -perm 0644 -print)" ]]; then
      changed[i]="Y"
    fi
  done

  # Prepare every same-directory replacement and rollback copy first.
  for (( i = 0; i < bundle_count; i++ )); do
    [[ "${changed[i]}" == "Y" ]] || continue
    target_dir="$(dirname "${targets[i]}")"
    target_name="$(basename "${targets[i]}")"
    [[ -d "${target_dir}" ]] || return 2

    commit_tmps[i]="$(mktemp "${target_dir}/.${target_name}.commit.XXXXXX")" ||
      return 2
    if ! cp "${candidates[i]}" "${commit_tmps[i]}" ||
       ! chmod 0644 "${commit_tmps[i]}"; then
      return 2
    fi

    backups[i]="${stage_root}/backup.${i}"
    if [[ -e "${targets[i]}" ]]; then
      existed[i]="Y"
      cp -p "${targets[i]}" "${backups[i]}" || return 2
    else
      existed[i]="N"
    fi
  done

  transaction_active="Y"
  for (( i = 0; i < bundle_count; i++ )); do
    committed_count=$((i + 1))
    [[ "${changed[i]}" == "Y" ]] || continue
    if ! mv -f "${commit_tmps[i]}" "${targets[i]}"; then
      if _cnode_runtime_rollback "${committed_count}"; then
        transaction_active="N"
      fi
      return 2
    fi
    commit_tmps[i]=""
    if ! cmp -s "${candidates[i]}" "${targets[i]}" ||
       [[ -z "$(find "${targets[i]}" -prune -perm 0644 -print)" ]]; then
      if _cnode_runtime_rollback "${committed_count}"; then
        transaction_active="N"
      fi
      return 2
    fi
  done
  transaction_active="N"

  # Preserve the existing archive convention after the whole bundle commits.
  archive_stamp="$(date +%s)"
  for (( i = 0; i < bundle_count; i++ )); do
    [[ "${changed[i]}" == "Y" && "${existed[i]:-N}" == "Y" ]] || continue
    target_name="$(basename "${targets[i]}")"
    if [[ ${i} -eq 5 ]]; then
      archive_name="${target_name}_bkp${archive_stamp}"
    else
      archive_name="${sources[i]//\//_}_${target_name}_bkp${archive_stamp}"
    fi
    cp -f "${backups[i]}" "${NODE_HOME}/scripts/archive/${archive_name}" ||
      log_warn "Could not archive the previous ${target_name}; the runtime bundle is installed."
  done

  return 0
)

# Description : Add epel repository when needed
#             : $1 = DISTRO
#             : $2 = Epel repository VERSION_ID
#             : $3 = pkg_opts for repo install
add_epel_repository() {
  if [[ "${1}" =~ Fedora ]]; then return; fi
  log_progress "Enabling EPEL repository"
  ! grep -q ^epel <<< "$(dnf repolist)" && $sudo dnf install ${3} https://dl.fedoraproject.org/pub/epel/epel-release-latest-"${2}".noarch.rpm > /dev/null
  log_ok "EPEL repository ready"
}

# OS Dependencies
os_dependencies() {
  pkg_opts="-y"
  log_info "Preparing OS packages for ${DISTRO}."
  if [[ "${OS_ID}" =~ ebian ]] || [[ "${OS_ID}" =~ buntu ]] || [[ "${DISTRO}" =~ ebian ]] || [[ "${DISTRO}" =~ buntu ]]; then
    #Debian/Ubuntu
    pkgmgrcmd="env NEEDRESTART_MODE=a env DEBIAN_FRONTEND=noninteractive env DEBIAN_PRIORITY=critical apt-get"
    pkg_list="python3 pkg-config systemd tmux git jq libtool bc gnupg libtool iproute2 tcptraceroute sqlite3 bsdmainutils unzip procps xxd"
    if [[ "${CNODE_DEPLOY_INSTALL_LIBSODIUM}" == "Y" ]] ||
       [[ "${CNODE_DEPLOY_BUILD_DEPS}" == "Y" ]]; then
      pkg_list="${pkg_list} build-essential make g++ autoconf automake"
    fi
    if [[ "${CNODE_DEPLOY_BUILD_DEPS}" == "Y" ]]; then
      libncurses_pkg="libncursesw5"
      [[ -f /etc/debian_version ]] && grep -qE '(trixie|13)' /etc/debian_version && libncurses_pkg="libncursesw6"
      [[ "${DISTRO}" =~ Ubuntu && ${VERSION_ID} -ge 26 ]] && libncurses_pkg="libncursesw6"
      pkg_list="${pkg_list} ${libncurses_pkg} libtinfo-dev libnuma-dev libpq-dev liblmdb-dev libsnappy-dev protobuf-compiler liburing-dev libffi-dev libgmp-dev libssl-dev libsystemd-dev zlib1g-dev llvm clang"
    fi
    if [[ "${CNODE_DEPLOY_INSTALL_HWCLI}" == "Y" ]]; then
      pkg_list="${pkg_list} libusb-1.0-0-dev libudev-dev"
    fi
  elif [[ "${OS_ID}" =~ rhel ]] || [[ "${OS_ID}" =~ fedora ]] || [[ "${DISTRO}" =~ Fedora ]]; then
    #CentOS/RHEL/Fedora/RockyLinux
    pkgmgrcmd="dnf"
    pkg_list="python3 coreutils systemd tmux git jq gnupg2 libtool iproute bc traceroute sqlite util-linux xz unzip procps-ng udev vim-common"
    if [[ "${VERSION_ID}" =~ "8" ]] || [[ "${VERSION_ID}" =~ "9" ]]; then
      #RHEL/CentOS/RockyLinux 8/9
      if ${pkgmgrcmd} install -h  | grep -q "\ --allowerasing"; then pkg_opts="${pkg_opts} --allowerasing"; fi
      if [[ "${DISTRO}" =~ Rocky ]]; then
        #RockyLinux 8/9
        pkg_list="${pkg_list} --enablerepo=devel,crb libusbx ncurses-compat-libs pkgconf-pkg-config"
      elif [[ "${DISTRO}" =~ "Red Hat" ]]; then
        pkg_list="${pkg_list} --enablerepo=codeready-builder-for-rhel-${VERSION_ID/.*/}-x86_64-rpms libusbx ncurses-compat-libs pkgconf-pkg-config"
      fi
    elif [[ "${DISTRO}" =~ Fedora ]]; then
      #Fedora
      if ${pkgmgrcmd} install -h  | grep -q "\ --allowerasing"; then pkg_opts="${pkg_opts} --allowerasing"; fi
      pkg_list="${pkg_list} libusbx ncurses-compat-libs pkgconf-pkg-config"
    fi
    if [[ "${CNODE_DEPLOY_INSTALL_LIBSODIUM}" == "Y" ]] ||
       [[ "${CNODE_DEPLOY_BUILD_DEPS}" == "Y" ]]; then
      pkg_list="${pkg_list} make gcc-c++ autoconf automake"
    fi
    if [[ "${CNODE_DEPLOY_BUILD_DEPS}" == "Y" ]]; then
      pkg_list="${pkg_list} ncurses-libs ncurses-devel openssl-devel systemd-devel llvm clang numactl-devel libffi-devel gmp-devel zlib-devel lmdb-devel lmdb liburing-devel snappy-devel protobuf-compiler"
    fi
    add_epel_repository "${DISTRO}" "${VERSION_ID}" "${pkg_opts}"
  else
    err_exit "No automated OS dependency procedure is available for ${DISTRO}."
  fi
  log_progress "Updating package metadata"
  $sudo ${pkgmgrcmd} update ${pkg_opts} > /dev/null;rc=$?
  if [[ $rc != 0 ]]; then
    err_exit "Package metadata update failed: ${pkgmgrcmd} ${pkg_opts} update"
  fi
  log_ok "Package metadata updated"
  log_progress "Installing prerequisite packages"
  $sudo ${pkgmgrcmd} install ${pkg_opts} ${pkg_list} > /dev/null;rc=$?
  if [[ $rc != 0 ]]; then
    err_exit "Prerequisite package installation failed. Re-run manually to inspect: $sudo ${pkgmgrcmd} install ${pkg_opts} ${pkg_list}"
  fi
  log_ok "Prerequisite packages ready"
  if [[ "${OS_ID}" =~ rhel ]] || [[ "${OS_ID}" =~ fedora ]] || [[ "${DISTRO}" =~ Fedora ]]; then
    if [ -e /usr/lib64/libtinfo.so ] && [ -e /usr/lib64/libtinfo.so.5 ]; then
      log_info "ncurses compatibility symlinks already present."
    else
      log_progress "Updating ncurses compatibility symlinks"
      $sudo ln -s "$(find /usr/lib64/libtinfo.so* | tail -1)" /usr/lib64/libtinfo.so
      $sudo ln -s "$(find /usr/lib64/libtinfo.so* | tail -1)" /usr/lib64/libtinfo.so.5
      log_ok "ncurses compatibility symlinks updated"
    fi
  fi
  log_ok "OS dependencies checked" "${DISTRO}"
}

cnode_deploy_install_ghcup() {
  local architecture ghcup_version staging_dir staged_binary target_binary
  local actual_sha

  architecture="$(cnode_deploy_architecture)" ||
    err_exit "Unsupported GHCup architecture: $(uname -m)"
  cnode_deploy_resolve_tool "ghcup" "${architecture}"
  ghcup_version="${CNODE_RESOLVED_VERSION}"
  target_binary="${HOME}/.local/bin/ghcup"

  if [[ -f "${target_binary}" && ! -L "${target_binary}" ]]; then
    actual_sha="$(sha256sum "${target_binary}" 2>/dev/null | awk '{print $1}')"
    if [[ "${actual_sha}" == "${CNODE_RESOLVED_SHA256}" ]] &&
       cnode_deploy_verify_binary_version \
         "${target_binary}" "${ghcup_version}"; then
      export PATH="${HOME}/.ghcup/bin:${HOME}/.local/bin:${PATH}"
      log_info "GHCup already matches release policy v${ghcup_version}."
      return 0
    fi
  fi

  log_progress "Installing GHCup" "v${ghcup_version}"
  staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/guild-ghcup.XXXXXX")" ||
    err_exit "Could not create a private GHCup staging directory."
  staged_binary="${staging_dir}/${CNODE_RESOLVED_FILENAME}"
  cnode_deploy_download_resolved_artifact "${staged_binary}"
  chmod 0755 "${staged_binary}" ||
    err_exit "Could not set executable permissions on the staged GHCup binary."
  cnode_deploy_verify_binary_version \
    "${staged_binary}" "${ghcup_version}" ||
    err_exit "Staged GHCup does not report manifest version ${ghcup_version}."
  mkdir -p "${HOME}/.local/bin" "${HOME}/.ghcup/bin" ||
    err_exit "Could not create GHCup binary directories."
  mv -f "${staged_binary}" "${target_binary}" ||
    err_exit "Could not install the validated GHCup binary."
  rm -rf -- "${staging_dir}"

  export PATH="${HOME}/.ghcup/bin:${HOME}/.local/bin:${PATH}"
  if ! grep -q '/.ghcup/bin' "${HOME}/.bashrc"; then
    printf '\nexport PATH="${HOME}/.ghcup/bin:${PATH}"\n' >> "${HOME}/.bashrc"
  fi
  log_ok "GHCup installed" "v${ghcup_version}"
}

# Build Dependencies for cabal builds
build_dependencies() {
  cnode_deploy_load_release_metadata
  log_info "Preparing Haskell toolchain dependencies."
  export BOOTSTRAP_HASKELL_GHC_VERSION="${CNODE_BUILD_GHC_VERSION}"
  export BOOTSTRAP_HASKELL_CABAL_VERSION="${CNODE_BUILD_CABAL_VERSION}"
  export GHCUP_SKIP_UPDATE_CHECK=1
  cnode_deploy_install_ghcup
  [[ -f "${HOME}/.ghcup/env" ]] && source "${HOME}/.ghcup/env"
  if ! ghc --version 2>/dev/null | grep -q ${BOOTSTRAP_HASKELL_GHC_VERSION}; then
    log_progress "Installing GHC" "v${BOOTSTRAP_HASKELL_GHC_VERSION}"
    # BEGIN TEMPORARY GHCUP DEBUG BLOCK
    # Keep this block noisy while investigating RockyLinux CI stalls during GHC installation.
    # Restore the production command below when replacing this diagnostics block.
    # ghcup install ghc ${BOOTSTRAP_HASKELL_GHC_VERSION} >/dev/null 2>&1 || err_exit "Command failed: ghcup install ghc ${BOOTSTRAP_HASKELL_GHC_VERSION}"
    log_info "ghcup version: $(ghcup --version 2>&1 | head -n 1)"
    ghcup tool-requirements || true
    printf "\n"
    df -h || true
    free -h || true
    env | sort | grep -E '^(BOOTSTRAP_HASKELL|GHCUP|PATH|HOME|LANG|LC_|TERM|SHELL)=' || true

    ghcup_log="${HOME}/ghcup-install-ghc-${BOOTSTRAP_HASKELL_GHC_VERSION}.log"
    ghcup --verbose install ghc "${BOOTSTRAP_HASKELL_GHC_VERSION}" > >(tee "${ghcup_log}") 2>&1 &
    ghcup_pid=$!
    ghcup_start=${SECONDS}
    while kill -0 "${ghcup_pid}" 2>/dev/null; do
      sleep 15
      if kill -0 "${ghcup_pid}" 2>/dev/null; then
        log_info "Still installing GHC v${BOOTSTRAP_HASKELL_GHC_VERSION} ($((SECONDS-ghcup_start))s elapsed)."
        df -h / /root /tmp "${HOME}/.ghcup" 2>/dev/null || df -h || true
        du -sh "${HOME}/.ghcup" "${HOME}/.ghcup/tmp" /tmp 2>/dev/null || true
        if ps -ef --forest >/dev/null 2>&1; then
          ps -ef --forest
        else
          ps -ef 2>/dev/null
        fi | grep -E 'ghcup|ghc|make|configure|install' | grep -v grep || true
        tail -n 30 "${ghcup_log}" || true
      fi
    done
    wait "${ghcup_pid}"
    ghcup_rc=$?
    tail -n 200 "${ghcup_log}" || true
    [[ ${ghcup_rc} -eq 0 ]] || err_exit "Command failed: ghcup install ghc ${BOOTSTRAP_HASKELL_GHC_VERSION}"
    # END TEMPORARY GHCUP DEBUG BLOCK
    ghcup set ghc ${BOOTSTRAP_HASKELL_GHC_VERSION} >/dev/null 2>&1
    log_ok "GHC ready" "v${BOOTSTRAP_HASKELL_GHC_VERSION}"
  fi
  cabal_version=$(cabal --version 2>/dev/null | head -n 1 | cut -d' ' -f3)
  if [[ -z ${cabal_version} || ! ${cabal_version} = "${BOOTSTRAP_HASKELL_CABAL_VERSION}" ]]; then
    if [[ -n ${cabal_version} ]]; then
      log_progress "Removing previous Cabal release"
      ghcup rm cabal ${cabal_version} >/dev/null 2>&1
      log_ok "Previous Cabal release removed"
    fi
    log_progress "Installing Cabal" "v${BOOTSTRAP_HASKELL_CABAL_VERSION}"
    ghcup install cabal ${BOOTSTRAP_HASKELL_CABAL_VERSION} >/dev/null 2>&1 || err_exit "Command failed: ghcup install cabal ${BOOTSTRAP_HASKELL_CABAL_VERSION}"
    log_ok "Cabal ready" "v${BOOTSTRAP_HASKELL_CABAL_VERSION}"
  fi
  build_libsecp
  build_libblst
  log_info "Toolchain ready: GHC v${BOOTSTRAP_HASKELL_GHC_VERSION}, Cabal v${BOOTSTRAP_HASKELL_CABAL_VERSION}."
}

cnode_deploy_checkout_source() {
  local repository="$1"
  local checkout_dir="$2"
  local source_ref="$3"
  local component_name="$4"
  local origin_url expected_commit actual_commit

  if [[ ! -e "${checkout_dir}" ]]; then
    git clone "${repository}" "${checkout_dir}" >/dev/null 2>&1 ||
      err_exit "Could not clone ${component_name} from ${repository}."
  fi
  [[ -d "${checkout_dir}/.git" ]] ||
    err_exit "${component_name} source path is not a Git checkout: ${checkout_dir}"

  origin_url="$(git -C "${checkout_dir}" remote get-url origin 2>/dev/null)" ||
    err_exit "Could not read the ${component_name} origin repository."
  if [[ "${origin_url%.git}" != "${repository%.git}" ]]; then
    err_exit "${component_name} origin '${origin_url}' does not match release policy repository '${repository}'."
  fi

  git -C "${checkout_dir}" fetch --force --tags origin >/dev/null 2>&1 ||
    err_exit "Could not fetch the selected ${component_name} source ref."
  expected_commit="$(
    git -C "${checkout_dir}" rev-parse --verify "${source_ref}^{commit}" 2>/dev/null
  )" || err_exit "Could not resolve ${component_name} source ref '${source_ref}'."
  git -C "${checkout_dir}" checkout --detach "${expected_commit}" \
    >/dev/null 2>&1 ||
    err_exit "Could not check out ${component_name} source ref '${source_ref}'."
  actual_commit="$(git -C "${checkout_dir}" rev-parse --verify HEAD 2>/dev/null)" ||
    err_exit "Could not verify the checked-out ${component_name} commit."
  [[ "${actual_commit}" == "${expected_commit}" ]] ||
    err_exit "${component_name} checkout does not match source ref '${source_ref}'."
  if ! git -C "${checkout_dir}" diff --quiet -- ||
     ! git -C "${checkout_dir}" diff --cached --quiet --; then
    err_exit "${component_name} checkout has tracked local changes; refusing to build a payload that differs from the release policy."
  fi
}

# Build fork of libsodium
build_libsodium() {
  cnode_deploy_load_release_metadata
  SODIUM_VERSION="${CNODE_BUILD_LIBSODIUM_VERSION}"
  SODIUM_REF="${CNODE_BUILD_LIBSODIUM_REF}"
  if ! grep -q "/usr/local/lib:\$LD_LIBRARY_PATH" "${HOME}"/.bashrc; then
    printf '\nexport LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH\n' >> "${HOME}"/.bashrc
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
    log_info "Added /usr/local/lib to LD_LIBRARY_PATH in ${HOME}/.bashrc."
  fi
  log_progress "Building libsodium"
  pushd "${HOME}"/git >/dev/null || err_exit "Could not enter build directory: ${HOME}/git"
  cnode_deploy_checkout_source \
    "${CNODE_BUILD_LIBSODIUM_REPOSITORY}" \
    "${HOME}/git/libsodium" \
    "${SODIUM_REF}" \
    "libsodium"
  pushd "${HOME}/git/libsodium" >/dev/null ||
    err_exit "Could not enter libsodium source directory."
  local sodium_log="/tmp/libsodium.log"
  : > "${sodium_log}"
  DO_NOT_UPDATE_CONFIG_SCRIPTS=1 ./autogen.sh >> "${sodium_log}" 2>&1 || { cat "${sodium_log}"; err_exit "Could not prepare libsodium build files. See ${sodium_log} for details."; }
  ./configure >> "${sodium_log}" 2>&1 || { cat "${sodium_log}"; err_exit "Could not configure libsodium. See ${sodium_log} for details."; }
  make >> "${sodium_log}" 2>&1 || { cat "${sodium_log}"; err_exit "Could not complete make for libsodium. See ${sodium_log} for details."; }
  $sudo make install >> "${sodium_log}" 2>&1 || { cat "${sodium_log}"; err_exit "Could not install libsodium. See ${sodium_log} for details."; }
  command -v pkg-config >/dev/null 2>&1 || err_exit "libsodium installed, but pkg-config is not available to verify it."
  export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  pkg-config --exists libsodium || { pkg-config --list-all | grep -i sodium || true; err_exit "libsodium installed, but pkg-config metadata was not found."; }
  local sodium_version sodium_detail
  sodium_version="$(pkg-config --modversion libsodium 2>/dev/null || true)"
  sodium_detail="v${SODIUM_VERSION} (${SODIUM_REF:0:12})"
  [[ -n "${sodium_version}" ]] && sodium_detail="${sodium_detail}, ${sodium_version}"
  log_ok "libsodium installed" "${sodium_detail}"
}

build_libsecp() {
  SECP256K1_VERSION="${CNODE_BUILD_SECP256K1_VERSION}"
  SECP256K1_REF="${CNODE_BUILD_SECP256K1_REF}"
  log_progress "Building libsecp256k1"
  pushd "${HOME}"/git >/dev/null || err_exit "Could not enter build directory: ${HOME}/git"
  cnode_deploy_checkout_source \
    "${CNODE_BUILD_SECP256K1_REPOSITORY}" \
    "${HOME}/git/secp256k1" \
    "${SECP256K1_REF}" \
    "libsecp256k1"
  pushd "${HOME}/git/secp256k1" >/dev/null ||
    err_exit "Could not enter libsecp256k1 source directory."
  ./autogen.sh > autogen.log > /tmp/secp256k1.log 2>&1
  ./configure --enable-module-schnorrsig --enable-experimental > configure.log >> /tmp/secp256k1.log 2>&1
  make > make.log 2>&1 || err_exit "Could not complete make for libsecp256k1. See make.log for details."
  make check >>make.log 2>&1
  $sudo make install > install.log 2>&1
  if ! grep -q "/usr/local/lib:\$LD_LIBRARY_PATH" "${HOME}"/.bashrc; then
    printf '\nexport LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH\n' >> "${HOME}"/.bashrc
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
    log_info "Added /usr/local/lib to LD_LIBRARY_PATH in ${HOME}/.bashrc."
  fi
  log_ok "libsecp256k1 installed" "v${SECP256K1_VERSION} (${SECP256K1_REF:0:12})"
}

build_libblst() {
  BLST_VERSION="${CNODE_BUILD_BLST_VERSION}"
  BLST_REF="${CNODE_BUILD_BLST_REF}"
  if ! grep -q "/usr/local/lib:\$LD_LIBRARY_PATH" "${HOME}"/.bashrc; then
    printf '\nexport LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH\n' >> "${HOME}"/.bashrc
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
    log_info "Added /usr/local/lib to LD_LIBRARY_PATH in ${HOME}/.bashrc."
  fi
  log_progress "Building BLST"
  pushd "${HOME}"/git >/dev/null || err_exit "Could not enter build directory: ${HOME}/git"
  cnode_deploy_checkout_source \
    "${CNODE_BUILD_BLST_REPOSITORY}" \
    "${HOME}/git/blst" \
    "${BLST_REF}" \
    "BLST"
  pushd "${HOME}/git/blst" >/dev/null ||
    err_exit "Could not enter BLST source directory."
  ./build.sh >/dev/null 2>&1
  cat <<-EOF >libblst.pc
		prefix=/usr/local
		exec_prefix=\${prefix}
		libdir=\${exec_prefix}/lib
		includedir=\${prefix}/include

		Name: libblst
		Description: Multilingual BLS12-381 signature library
		URL: https://github.com/supranational/blst
		Version: ${BLST_VERSION}
		Cflags: -I\${includedir}
		Libs: -L\${libdir} -lblst
		EOF
  [[ ! -d /usr/local/lib/pkgconfig ]] && $sudo mkdir -p /usr/local/lib/pkgconfig
  $sudo cp -f libblst.pc /usr/local/lib/pkgconfig/
  $sudo cp bindings/blst_aux.h bindings/blst.h bindings/blst.hpp  /usr/local/include/
  $sudo cp libblst.a /usr/local/lib
  $sudo chmod u=rw,go=r /usr/local/{lib/{libblst.a,pkgconfig/libblst.pc},include/{blst.{h,hpp},blst_aux.h}}
  log_ok "BLST installed" "v${BLST_VERSION} (${BLST_REF:0:12})"
}

cnode_deploy_architecture() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'linux-x86_64\n' ;;
    aarch64|arm64) printf 'linux-aarch64\n' ;;
    *) return 1 ;;
  esac
}

cnode_deploy_verify_binary_version() {
  local binary="$1"
  local expected_version="$2"
  local version_output

  [[ -f "${binary}" && ! -L "${binary}" && -x "${binary}" ]] || return 1
  version_output="$("${binary}" --version 2>&1)" || return 1
  printf '%s\n' "${version_output}" |
    grep -Eo '[0-9]+([.][0-9]+){1,3}([+-][A-Za-z0-9.-]+)?' |
    grep -Fxq "${expected_version}"
}

cnode_deploy_validate_release_metadata() {
  local manifest="$1"

  [[ -f "${manifest}" && ! -L "${manifest}" && -s "${manifest}" ]] ||
    return 1
  jq -e '
    def strict_https:
      type == "string" and test("\\Ahttps://[^[:space:]]+\\z");
    def concrete_version:
      type == "string" and
      test("\\A[0-9]+([.][0-9]+){1,3}([+-][A-Za-z0-9.-]+)?\\z");
    def sha256:
      type == "string" and test("\\A[0-9a-f]{64}\\z");
    def safe_ref:
      type == "string" and test("\\A[0-9a-f]{40}\\z");
    def artifact:
      keys == ["sha256", "url"] and
      (.url | strict_https) and
      (.sha256 | sha256);
    def artifact_map:
      type == "object" and
      length > 0 and
      ((keys - ["linux-aarch64", "linux-x86_64"]) | length == 0) and
      all(.[]; artifact);
    def pinned_component:
      keys == ["artifacts", "version"] and
      (.version | concrete_version) and
      (.artifacts | artifact_map);
    def anchored_selector:
      type == "string" and
      length > 2 and
      (
        (startswith("^") and endswith("$")) or
        (startswith("\\A") and endswith("\\z"))
      );
    def tool:
      . as $tool |
      ($tool.version | type == "string") and
      (
        if $tool.version == "latest" then
          (($tool | keys) -
            ["assets", "channel", "github", "minimumVersion", "version"] |
            length == 0) and
          ($tool.github |
            type == "string" and
            test("\\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\z")) and
          (($tool.channel // "stable") == "stable" or
            ($tool.channel // "stable") == "any") and
          ($tool.assets | type == "object" and length > 0) and
          (($tool.assets | keys) -
            ["linux-aarch64", "linux-x86_64"] | length == 0) and
          all($tool.assets[]; anchored_selector)
        else
          (($tool | keys) -
            ["artifacts", "minimumVersion", "version"] | length == 0) and
          ($tool.version | concrete_version) and
          ($tool.artifacts | artifact_map)
        end
      ) and
      (
        ($tool | has("minimumVersion") | not) or
        ($tool.minimumVersion | concrete_version)
      );
    def managed_installer:
      keys == ["installer", "version"] and
      (.version == "latest" or (.version | concrete_version)) and
      (.installer | artifact) and
      (.installer.url |
        type == "string" and
        test("\\Ahttps://raw\\.githubusercontent\\.com/cardano-foundation/openblockperf/[0-9a-f]{40}/blockperf-install\\.sh\\z"));
    def hardware_wallet_rules:
      keys == ["ledger", "trezor"] and
      (.ledger | artifact) and
      (.trezor | artifact) and
      (.ledger.url |
        test("\\Ahttps://raw\\.githubusercontent\\.com/LedgerHQ/udev-rules/[0-9a-f]{40}/add_udev_rules\\.sh\\z")) and
      .trezor.url == "https://data.trezor.io/udev/51-trezor.rules";
    def source_dependency:
      keys == ["ref", "repository", "version"] and
      (.repository | strict_https) and
      (.version | concrete_version) and
      (.ref | safe_ref);
    keys == [
      "artifacts",
      "build",
      "companions",
      "implementation",
      "managedInstallers",
      "schemaVersion",
      "supportArtifacts",
      "tools",
      "version"
    ] and
    .schemaVersion == 1 and
    .implementation == "cnode" and
    (.version | concrete_version) and
    (.artifacts | keys == ["linux-aarch64", "linux-x86_64"]) and
    (.artifacts | artifact_map) and
    (.companions | keys == [
      "cardano-address",
      "cardano-cli",
      "cardano-db-sync"
    ]) and
    all(.companions[];
      pinned_component and
      (.artifacts | keys == ["linux-aarch64", "linux-x86_64"])
    ) and
    (.tools | keys == [
      "cardano-hw-cli",
      "cardano-signer",
      "catalyst-toolbox",
      "cncli",
      "ghcup",
      "mithril",
      "ogmios"
    ]) and
    all(.tools[]; tool) and
    (.tools.cncli.minimumVersion | concrete_version) and
    (.tools["cardano-hw-cli"].minimumVersion | concrete_version) and
    (.tools["cardano-signer"].minimumVersion | concrete_version) and
    (.managedInstallers | keys == ["openblockperf"]) and
    (.managedInstallers.openblockperf | managed_installer) and
    (.supportArtifacts | keys == ["hardwareWalletRules"]) and
    (.supportArtifacts.hardwareWalletRules | hardware_wallet_rules) and
    (.build | keys == ["sourceDependencies", "toolchain"]) and
    (.build.toolchain | keys == ["cabal", "ghc"]) and
    all(.build.toolchain[]; concrete_version) and
    (.build.sourceDependencies | keys == [
      "blst",
      "libsodium",
      "secp256k1"
    ]) and
    all(.build.sourceDependencies[]; source_dependency)
  ' "${manifest}" >/dev/null
}

cnode_deploy_load_release_metadata() {
  local manifest="${NODE_HOME}/files/cnode-release.json"

  if ! cnode_deploy_validate_release_metadata "${manifest}"; then
    err_exit "Invalid cnode release metadata: ${manifest}"
  fi

  CNODE_RELEASE_MANIFEST="${manifest}"
  CARDANO_NODE_VERSION="$(jq -er '.version' "${manifest}")" ||
    err_exit "Could not read cardano-node version from ${manifest}"
  CARDANO_CLI_VERSION="$(jq -er '.companions["cardano-cli"].version' "${manifest}")" ||
    err_exit "Could not read cardano-cli version from ${manifest}"
  CNODE_BUILD_GHC_VERSION="$(jq -er '.build.toolchain.ghc' "${manifest}")" ||
    err_exit "Could not read GHC version from ${manifest}"
  CNODE_BUILD_CABAL_VERSION="$(jq -er '.build.toolchain.cabal' "${manifest}")" ||
    err_exit "Could not read Cabal version from ${manifest}"
  CNODE_BUILD_LIBSODIUM_REPOSITORY="$(
    jq -er '.build.sourceDependencies.libsodium.repository' "${manifest}"
  )" || err_exit "Could not read libsodium repository from ${manifest}"
  CNODE_BUILD_LIBSODIUM_VERSION="$(
    jq -er '.build.sourceDependencies.libsodium.version' "${manifest}"
  )" || err_exit "Could not read libsodium version from ${manifest}"
  CNODE_BUILD_LIBSODIUM_REF="$(
    jq -er '.build.sourceDependencies.libsodium.ref' "${manifest}"
  )" || err_exit "Could not read libsodium ref from ${manifest}"
  CNODE_BUILD_SECP256K1_REPOSITORY="$(
    jq -er '.build.sourceDependencies.secp256k1.repository' "${manifest}"
  )" || err_exit "Could not read secp256k1 repository from ${manifest}"
  CNODE_BUILD_SECP256K1_VERSION="$(
    jq -er '.build.sourceDependencies.secp256k1.version' "${manifest}"
  )" || err_exit "Could not read secp256k1 version from ${manifest}"
  CNODE_BUILD_SECP256K1_REF="$(
    jq -er '.build.sourceDependencies.secp256k1.ref' "${manifest}"
  )" || err_exit "Could not read secp256k1 ref from ${manifest}"
  CNODE_BUILD_BLST_REPOSITORY="$(
    jq -er '.build.sourceDependencies.blst.repository' "${manifest}"
  )" || err_exit "Could not read BLST repository from ${manifest}"
  CNODE_BUILD_BLST_VERSION="$(
    jq -er '.build.sourceDependencies.blst.version' "${manifest}"
  )" || err_exit "Could not read BLST version from ${manifest}"
  CNODE_BUILD_BLST_REF="$(
    jq -er '.build.sourceDependencies.blst.ref' "${manifest}"
  )" || err_exit "Could not read BLST ref from ${manifest}"
}

cnode_deploy_resolve_snapshot() {
  local section="$1"
  local component="$2"
  local architecture="$3"
  local manifest="${CNODE_RELEASE_MANIFEST:-${NODE_HOME}/files/cnode-release.json}"

  CNODE_RESOLVED_COMPONENT="${component}"
  CNODE_RESOLVED_MODE="pinned"
  CNODE_RESOLVED_VERSION="$(
    jq -er --arg section "${section}" --arg component "${component}" '
      if $section == "primary" then .version
      else .[$section][$component].version end
    ' "${manifest}"
  )" || err_exit "Could not read pinned version for ${component}."
  CNODE_RESOLVED_TAG="${CNODE_RESOLVED_VERSION}"
  CNODE_RESOLVED_URL="$(
    jq -er --arg section "${section}" --arg component "${component}" \
      --arg arch "${architecture}" '
      if $section == "primary" then .artifacts[$arch].url
      else .[$section][$component].artifacts[$arch].url end
    ' "${manifest}"
  )" || err_exit "No pinned ${component} URL is defined for ${architecture}."
  CNODE_RESOLVED_SHA256="$(
    jq -er --arg section "${section}" --arg component "${component}" \
      --arg arch "${architecture}" '
      if $section == "primary" then .artifacts[$arch].sha256
      else .[$section][$component].artifacts[$arch].sha256 end
    ' "${manifest}"
  )" || err_exit "No pinned ${component} checksum is defined for ${architecture}."
  CNODE_RESOLVED_FILENAME="${CNODE_RESOLVED_URL%%[\?#]*}"
  CNODE_RESOLVED_FILENAME="${CNODE_RESOLVED_FILENAME##*/}"
  if [[ ! "${CNODE_RESOLVED_FILENAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ||
     "${CNODE_RESOLVED_FILENAME}" == "." ||
     "${CNODE_RESOLVED_FILENAME}" == ".." ]]; then
    CNODE_RESOLVED_FILENAME="${component}"
  fi
}

cnode_deploy_version_at_least() {
  local minimum="${1#v}"
  local candidate="${2#v}"
  local minimum_base candidate_base minimum_core candidate_core
  local version_pattern='^[0-9]+([.][0-9]+)+([-+][0-9A-Za-z.-]+)?$'

  [[ "${minimum}" =~ ${version_pattern} &&
     "${candidate}" =~ ${version_pattern} ]] ||
    return 1

  minimum_base="${minimum%%+*}"
  candidate_base="${candidate%%+*}"
  minimum_core="${minimum_base%%-*}"
  candidate_core="${candidate_base%%-*}"

  if [[ "${minimum_core}" != "${candidate_core}" ]]; then
    printf '%s\n%s\n' "${minimum_core}" "${candidate_core}" |
      LC_ALL=C sort -C -V
    return
  fi

  # For an equal numeric core, a prerelease is older than the final release.
  if [[ "${minimum_base}" == "${minimum_core}" ]]; then
    [[ "${candidate_base}" == "${candidate_core}" ]]
  elif [[ "${candidate_base}" == "${candidate_core}" ]]; then
    return 0
  else
    printf '%s\n%s\n' "${minimum_base}" "${candidate_base}" |
      LC_ALL=C sort -C -V
  fi
}

cnode_deploy_resolve_latest_tool() {
  local component="$1"
  local architecture="$2"
  local manifest="${CNODE_RELEASE_MANIFEST:-${NODE_HOME}/files/cnode-release.json}"
  local channel repository selector
  local api_url response_file resolved_line digest expected_url

  channel="$(jq -er --arg tool "${component}" \
    '.tools[$tool].channel // "stable"' "${manifest}")" ||
    err_exit "Could not read latest-release channel for ${component}."
  repository="$(jq -er --arg tool "${component}" \
    '.tools[$tool].github' "${manifest}")" ||
    err_exit "Could not read GitHub repository for ${component}."
  selector="$(jq -er --arg tool "${component}" --arg arch "${architecture}" \
    '.tools[$tool].assets[$arch]' \
    "${manifest}")" ||
    err_exit "No latest ${component} artifact selector is defined for ${architecture}."
  [[ "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    err_exit "Invalid GitHub repository configured for ${component}."

  case "${channel}" in
    stable)
      api_url="https://api.github.com/repos/${repository}/releases/latest"
      ;;
    any)
      api_url="https://api.github.com/repos/${repository}/releases?per_page=20"
      ;;
    *)
      err_exit "Unsupported latest-release channel '${channel}' for ${component}."
      ;;
  esac

  response_file="$(mktemp "${NODE_HOME}/files/.${component}-release-api.XXXXXX")" ||
    err_exit "Could not stage latest-release metadata for ${component}."
  if ! curl -sSfL -m "${CURL_TIMEOUT}" -o "${response_file}" "${api_url}"; then
    rm -f -- "${response_file}"
    err_exit "Could not resolve the latest ${component} release from GitHub."
  fi

  if ! resolved_line="$(
    jq -er --arg channel "${channel}" --arg selector "${selector}" '
      def selected_release:
        if $channel == "stable" then .
        else ([.[] | select(.draft == false)][0] // null)
        end;
      selected_release as $release |
      if ($release | type) != "object" or
         $release.draft != false or
         ($channel == "stable" and $release.prerelease != false) or
         ($release.tag_name | type) != "string" or
         ($release.tag_name | length) == 0 or
         ($release.assets | type) != "array"
      then
        error("invalid selected release")
      else
        [$release.assets[] | select(.name | test($selector))] as $matches |
        if ($matches | length) != 1 then
          error("artifact selector did not match exactly one asset")
        else
          $matches[0] as $asset |
          if ($asset.name | type) != "string" or
             ($asset.browser_download_url | type) != "string" or
             ($asset.digest | type) != "string"
          then
            error("selected asset metadata is incomplete")
          else
            [
              $release.tag_name,
              $asset.name,
              $asset.browser_download_url,
              $asset.digest
            ] | @tsv
          end
        end
      end
    ' "${response_file}" 2>/dev/null
  )"; then
    rm -f -- "${response_file}"
    err_exit "Latest ${component} metadata did not select exactly one valid ${architecture} asset."
  fi
  rm -f -- "${response_file}"

  IFS=$'\t' read -r CNODE_RESOLVED_TAG CNODE_RESOLVED_FILENAME \
    CNODE_RESOLVED_URL digest <<< "${resolved_line}"
  [[ "${CNODE_RESOLVED_TAG}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] ||
    err_exit "Latest ${component} returned an unsafe release tag."
  [[ "${CNODE_RESOLVED_FILENAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ &&
     "${CNODE_RESOLVED_FILENAME}" != "." &&
     "${CNODE_RESOLVED_FILENAME}" != ".." ]] ||
    err_exit "Latest ${component} returned an unsafe asset filename."
  expected_url="https://github.com/${repository}/releases/download/${CNODE_RESOLVED_TAG}/${CNODE_RESOLVED_FILENAME}"
  [[ "${CNODE_RESOLVED_URL}" == "${expected_url}" ]] ||
    err_exit "Latest ${component} asset URL does not match its repository, release tag and filename."
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    err_exit "Latest ${component} did not publish a valid GitHub SHA-256 asset digest."

  CNODE_RESOLVED_COMPONENT="${component}"
  CNODE_RESOLVED_MODE="latest"
  CNODE_RESOLVED_VERSION="${CNODE_RESOLVED_TAG#v}"
  CNODE_RESOLVED_SHA256="${digest#sha256:}"
}

cnode_deploy_resolve_primary() {
  cnode_deploy_resolve_snapshot "primary" "cardano-node" "$1"
}

cnode_deploy_resolve_companion() {
  cnode_deploy_resolve_snapshot "companions" "$1" "$2"
}

cnode_deploy_resolve_tool() {
  local component="$1"
  local architecture="$2"
  local manifest="${CNODE_RELEASE_MANIFEST:-${NODE_HOME}/files/cnode-release.json}"
  local configured_version mode minimum_version

  configured_version="$(jq -er --arg tool "${component}" \
    '.tools[$tool].version' "${manifest}")" ||
    err_exit "Could not read configured version for ${component}."
  [[ "${configured_version}" == "latest" ]] &&
    mode="latest" || mode="pinned"
  case "${mode}" in
    pinned)
      cnode_deploy_resolve_snapshot "tools" "${component}" "${architecture}"
      ;;
    latest)
      cnode_deploy_resolve_latest_tool "${component}" "${architecture}"
      ;;
    *)
      err_exit "Unsupported release selection '${mode}' for ${component}."
      ;;
  esac

  minimum_version="$(jq -r --arg tool "${component}" \
    '.tools[$tool].minimumVersion // empty' "${manifest}")" ||
    err_exit "Could not read the minimum supported ${component} version."
  if [[ -n "${minimum_version}" ]] &&
     ! cnode_deploy_version_at_least \
       "${minimum_version}" "${CNODE_RESOLVED_VERSION}"; then
    err_exit "Selected ${component} release ${CNODE_RESOLVED_VERSION} is older than the required minimum ${minimum_version}."
  fi
}

cnode_deploy_download_resolved_artifact() {
  local destination="$1"
  local actual_sha256

  [[ -n "${CNODE_RESOLVED_COMPONENT:-}" &&
     -n "${CNODE_RESOLVED_URL:-}" &&
     "${CNODE_RESOLVED_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] ||
    err_exit "No validated release artifact is resolved for download."
  curl -m "${DOWNLOAD_TIMEOUT}" -sfL "${CNODE_RESOLVED_URL}" \
    -o "${destination}" ||
    err_exit "Could not download ${CNODE_RESOLVED_COMPONENT} release ${CNODE_RESOLVED_VERSION}."
  actual_sha256="$(sha256sum "${destination}" | awk '{print $1}')" ||
    err_exit "Could not calculate the checksum for ${CNODE_RESOLVED_FILENAME}."
  actual_sha256="$(printf '%s' "${actual_sha256}" | tr '[:upper:]' '[:lower:]')"
  [[ "${actual_sha256}" == "${CNODE_RESOLVED_SHA256}" ]] ||
    err_exit "Checksum verification failed for ${CNODE_RESOLVED_FILENAME}."
}

cnode_deploy_install_release_metadata() {
  local destination="${NODE_HOME}/files/cnode-release.json"
  local temporary

  temporary="$(mktemp "${NODE_HOME}/files/.cnode-release.json.tmp.XXXXXX")" ||
    err_exit "Could not create cnode release metadata staging file."
  if ! curl -sSfL -m "${CURL_TIMEOUT}" \
    "${URL_RAW}/files/node-implementations/cnode/release.json" \
    -o "${temporary}"; then
    rm -f -- "${temporary}"
    err_exit "Could not download cnode release metadata."
  fi
  if ! cnode_deploy_validate_release_metadata "${temporary}"; then
    rm -f -- "${temporary}"
    err_exit "Downloaded cnode release metadata is invalid."
  fi
  if ! chmod 0644 "${temporary}" ||
     ! mv -f -- "${temporary}" "${destination}"; then
    rm -f -- "${temporary}"
    err_exit "Could not atomically install cnode release metadata."
  fi
  cnode_deploy_load_release_metadata
}

# Download cardano-node, cardano-cli, cardano-db-sync, bech32 and cardano-submit-api.
# The node and CLI archives are selected from the same pinned, checksum-verified
# release metadata format used by the Dingo and Amaru profiles.
download_cnodebins() {
  local architecture staging_dir binary
  local node_version cli_version address_version dbsync_version
  local -a install_binaries=(
    cardano-node
    cardano-cli
    cardano-submit-api
    bech32
    cardano-address
  )

  cnode_deploy_load_release_metadata
  architecture="$(cnode_deploy_architecture)" ||
    err_exit "Unsupported cnode architecture: $(uname -m)"
  staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/guild-cnode-binaries.XXXXXX")" ||
    err_exit "Could not create a private staging directory for cnode binaries."

  pushd "${staging_dir}" >/dev/null ||
    err_exit "Could not enter cnode binary staging directory."
  cnode_deploy_resolve_primary "${architecture}"
  node_version="${CNODE_RESOLVED_VERSION}"
  log_progress "Downloading cardano-node" "${CARDANO_NODE_VERSION}"
  cnode_deploy_download_resolved_artifact "cnode.tar.gz"
  if ! tar zxf cnode.tar.gz --strip-components 2 \
    ./bin/cardano-node \
    ./bin/cardano-submit-api \
    ./bin/bech32 &>/dev/null; then
    err_exit "Could not extract the expected cardano-node binaries."
  fi
  rm -f cnode.tar.gz
  [[ -f cardano-node ]] || err_exit "cardano-node archive downloaded, but binary 'cardano-node' was not found after extraction."
  [[ -f cardano-submit-api ]] || err_exit "cardano-node archive downloaded, but binary 'cardano-submit-api' was not found after extraction."
  [[ -f bech32 ]] || err_exit "cardano-node archive downloaded, but binary 'bech32' was not found after extraction."

  cnode_deploy_resolve_companion "cardano-cli" "${architecture}"
  cli_version="${CNODE_RESOLVED_VERSION}"
  log_progress "Downloading cardano-cli" "${CARDANO_CLI_VERSION}"
  cnode_deploy_download_resolved_artifact "ccli.tar.gz"
  if ! tar zxf ccli.tar.gz --strip-components 0 \
    "cardano-cli-${architecture#linux-}-linux" &>/dev/null ||
     ! mv "cardano-cli-${architecture#linux-}-linux" cardano-cli; then
    err_exit "Could not extract the expected cardano-cli binary."
  fi
  rm -f ccli.tar.gz
  [[ -f cardano-cli ]] || err_exit "cardano-cli archive downloaded, but binary 'cardano-cli' was not found after extraction."

  cnode_deploy_resolve_companion "cardano-address" "${architecture}"
  address_version="${CNODE_RESOLVED_VERSION}"
  log_progress "Downloading cardano-address" "${address_version}"
  cnode_deploy_download_resolved_artifact "caddress.tar.gz"
  if ! tar zxf caddress.tar.gz \
    --transform='s#.*\/##g' --wildcards cardano-address &>/dev/null; then
    err_exit "Could not extract the expected cardano-address binary."
  fi
  rm -f caddress.tar.gz
  [[ -f cardano-address ]] || err_exit "cardano-address archive downloaded, but binary 'cardano-address' was not found after extraction."

  if [[ "${CNODE_SKIP_DBSYNC_DOWNLOAD}" == "N" ]]; then
    cnode_deploy_resolve_companion "cardano-db-sync" "${architecture}"
    dbsync_version="${CNODE_RESOLVED_VERSION}"
    log_progress "Downloading cardano-db-sync" "${dbsync_version}"
    cnode_deploy_download_resolved_artifact "cnodedbsync.tar.gz"
    if ! tar zxf cnodedbsync.tar.gz \
      --strip-components 1 ./cardano-db-sync &>/dev/null; then
      err_exit "Could not extract the expected cardano-db-sync binary."
    fi
    rm -f cnodedbsync.tar.gz
    [[ -f cardano-db-sync ]] || err_exit "cardano-db-sync archive downloaded, but binary 'cardano-db-sync' was not found after extraction."
    install_binaries+=(cardano-db-sync)
  else
    log_info "Skipped cardano-db-sync binary download."
  fi

  # Do not replace any installed binary until every requested archive has
  # downloaded, verified and yielded its complete expected payload.
  for binary in "${install_binaries[@]}"; do
    [[ -f "${binary}" && ! -L "${binary}" ]] ||
      err_exit "Refusing to install an invalid staged cnode binary: ${binary}"
    chmod 0755 "${binary}" ||
      err_exit "Could not set executable permissions on staged binary: ${binary}"
  done
  cnode_deploy_verify_binary_version \
    "./cardano-node" "${node_version}" ||
    err_exit "Staged cardano-node does not report manifest version ${node_version}."
  cnode_deploy_verify_binary_version \
    "./cardano-cli" "${cli_version}" ||
    err_exit "Staged cardano-cli does not report manifest version ${cli_version}."
  cnode_deploy_verify_binary_version \
    "./cardano-address" "${address_version}" ||
    err_exit "Staged cardano-address does not report manifest version ${address_version}."
  if [[ "${CNODE_SKIP_DBSYNC_DOWNLOAD}" == "N" ]]; then
    cnode_deploy_verify_binary_version \
      "./cardano-db-sync" "${dbsync_version}" ||
      err_exit "Staged cardano-db-sync does not report manifest version ${dbsync_version}."
  fi
  mkdir -p "${HOME}/.local/bin" ||
    err_exit "Could not create ${HOME}/.local/bin."
  mv -f "${install_binaries[@]}" "${HOME}/.local/bin/" ||
    err_exit "Could not install the validated cnode binary set."
  popd >/dev/null || true
  rm -rf -- "${staging_dir}"

  log_ok "Deployed cardano-node" "${node_version}"
  log_ok "Deployed cardano-cli" "${cli_version}"
  log_ok "Deployed cardano-submit-api" "${node_version}"
  log_ok "Deployed bech32" "${node_version}"
  log_ok "Deployed cardano-address" "${address_version}"
  if [[ "${CNODE_SKIP_DBSYNC_DOWNLOAD}" == "N" ]]; then
    log_ok "Deployed cardano-db-sync" "${dbsync_version}"
  fi
}

# Download CNCLI
download_cncli() {
  local architecture cncli_version staging_dir

  cnode_deploy_load_release_metadata
  architecture="$(cnode_deploy_architecture)" ||
    err_exit "Unsupported CNCLI architecture: $(uname -m)"
  log_progress "Resolving CNCLI release"
  cnode_deploy_resolve_tool "cncli" "${architecture}"
  cncli_version="${CNODE_RESOLVED_VERSION}"
  log_progress "Downloading CNCLI" "${cncli_version}"
  staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/guild-cncli.XXXXXX")" ||
    err_exit "Could not create a private CNCLI staging directory."
  pushd "${staging_dir}" >/dev/null ||
    err_exit "Could not enter temporary CNCLI directory."
  cnode_deploy_download_resolved_artifact "cncli.tar.gz"
  tar zxf cncli.tar.gz &>/dev/null ||
    err_exit "Could not extract the resolved CNCLI release."
  rm -f cncli.tar.gz
  [[ -f cncli && ! -L cncli ]] ||
    err_exit "CNCLI downloaded but binary (cncli) not found after extracting package!"
  chmod 0755 cncli ||
    err_exit "Could not set executable permissions on the staged CNCLI binary."
  mv -f cncli "${HOME}"/.local/bin/ ||
    err_exit "Could not install the validated CNCLI binary."
  popd >/dev/null || true
  rm -rf -- "${staging_dir}"
  rm -f "${HOME}"/.cargo/bin/cncli # Remove duplicate file in $PATH (old convention)
  log_ok "Deployed CNCLI" "${cncli_version}"
}

cnode_deploy_install_hardware_wallet_rules() {
  local manifest="${CNODE_RELEASE_MANIFEST:-${NODE_HOME}/files/cnode-release.json}"
  local release_data ledger_url ledger_sha trezor_url trezor_sha
  local staging_dir ledger_file trezor_file actual_sha

  [[ ! -f "/etc/udev/rules.d/20-hw1.rules" ||
     ! -f "/etc/udev/rules.d/51-trezor.rules" ]] ||
    return 0
  release_data="$(
    jq -er '
      .supportArtifacts.hardwareWalletRules |
      [
        .ledger.url,
        .ledger.sha256,
        .trezor.url,
        .trezor.sha256
      ] | @tsv
    ' "${manifest}"
  )" || err_exit "Could not read hardware-wallet rules policy."
  IFS=$'\t' read -r ledger_url ledger_sha trezor_url trezor_sha \
    <<< "${release_data}"

  staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/guild-hardware-rules.XXXXXX")" ||
    err_exit "Could not create a private hardware-wallet rules staging directory."
  ledger_file="${staging_dir}/add_udev_rules.sh"
  trezor_file="${staging_dir}/51-trezor.rules"

  if [[ ! -f "/etc/udev/rules.d/20-hw1.rules" ]]; then
    curl -sSfL -m "${DOWNLOAD_TIMEOUT}" \
      "${ledger_url}" -o "${ledger_file}" ||
      err_exit "Could not download the pinned Ledger udev installer."
    actual_sha="$(sha256sum "${ledger_file}" | awk '{print $1}')" ||
      err_exit "Could not calculate the Ledger udev installer checksum."
    if [[ "${actual_sha}" != "${ledger_sha}" ]] ||
       ! bash -n "${ledger_file}" >/dev/null 2>&1; then
      err_exit "Ledger udev installer failed checksum or syntax validation."
    fi
    $sudo bash "${ledger_file}" >/dev/null 2>&1 ||
      err_exit "Could not install Ledger udev rules."
    $sudo sed -e "s@TAG+=\"uaccess\"@OWNER=\"$USER\", TAG+=\"uaccess\"@g" \
      -i /etc/udev/rules.d/20-hw1.rules ||
      err_exit "Could not set the Ledger udev rule owner."
    log_info "Installed checksum-verified Ledger udev rules."
  fi

  if [[ ! -f "/etc/udev/rules.d/51-trezor.rules" ]]; then
    curl -sSfL -m "${DOWNLOAD_TIMEOUT}" \
      "${trezor_url}" -o "${trezor_file}" ||
      err_exit "Could not download the pinned Trezor udev rules."
    actual_sha="$(sha256sum "${trezor_file}" | awk '{print $1}')" ||
      err_exit "Could not calculate the Trezor udev rules checksum."
    [[ "${actual_sha}" == "${trezor_sha}" ]] ||
      err_exit "Trezor udev rules failed checksum validation."
    $sudo install -m 0644 "${trezor_file}" \
      /etc/udev/rules.d/51-trezor.rules ||
      err_exit "Could not install Trezor udev rules."
    $sudo sed -e "s@TAG+=\"uaccess\"@OWNER=\"$USER\", TAG+=\"uaccess\"@g" \
      -i /etc/udev/rules.d/51-trezor.rules ||
      err_exit "Could not set the Trezor udev rule owner."
    log_info "Installed checksum-verified Trezor udev rules."
  fi

  rm -rf -- "${staging_dir}"
  $sudo udevadm control --reload-rules >/dev/null 2>&1 ||
    err_exit "Could not reload udev rules."
  $sudo udevadm trigger >/dev/null 2>&1 ||
    err_exit "Could not trigger updated udev rules."
}

# Download pre-build cardano-hw-cli binary and it's dependencies
download_cardanohwcli() {
  local architecture hwcli_version staging_dir

  cnode_deploy_load_release_metadata
  architecture="$(cnode_deploy_architecture)" ||
    err_exit "Unsupported cardano-hw-cli architecture: $(uname -m)"
  log_progress "Resolving cardano-hw-cli release"
  cnode_deploy_resolve_tool "cardano-hw-cli" "${architecture}"
  hwcli_version="${CNODE_RESOLVED_VERSION}"
  log_progress "Downloading cardano-hw-cli" "${hwcli_version}"
  staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/guild-cardano-hw-cli.XXXXXX")" ||
    err_exit "Could not create a private cardano-hw-cli staging directory."
  pushd "${staging_dir}" >/dev/null ||
    err_exit "Could not enter temporary cardano-hw-cli directory."
  cnode_deploy_download_resolved_artifact "cardano-hw-cli.tar.gz"
  tar zxf cardano-hw-cli.tar.gz &>/dev/null ||
    err_exit "Could not extract the resolved cardano-hw-cli release."
  rm -f cardano-hw-cli.tar.gz
  [[ -f cardano-hw-cli/cardano-hw-cli &&
     ! -L cardano-hw-cli/cardano-hw-cli ]] ||
    err_exit "cardano-hw-cli downloaded but binary not found after extracting package!"
  mkdir -p "${HOME}"/.local/bin ||
    err_exit "Could not create ${HOME}/.local/bin."
  rm -rf "${HOME}"/bin/cardano-hw-cli # Remove duplicate file in $PATH (old convention)
  rm -rf "${HOME}"/.local/bin/cardano-hw-cli
  mv -f cardano-hw-cli/* "${HOME}"/.local/bin/ ||
    err_exit "Could not install the validated cardano-hw-cli release."
  popd >/dev/null || true
  rm -rf -- "${staging_dir}"

  cnode_deploy_install_hardware_wallet_rules
  log_ok "Deployed cardano-hw-cli" "${hwcli_version}"
}

# Download pre-built ogmios binary
download_ogmios() {
  local OGMIOSPATH=""
  local architecture ogmios_version staging_dir

  cnode_deploy_load_release_metadata
  architecture="$(cnode_deploy_architecture)" ||
    err_exit "Unsupported Ogmios architecture: $(uname -m)"
  log_progress "Resolving Ogmios release"
  cnode_deploy_resolve_tool "ogmios" "${architecture}"
  ogmios_version="${CNODE_RESOLVED_VERSION}"
  log_progress "Downloading Ogmios" "${ogmios_version}"
  staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/guild-ogmios.XXXXXX")" ||
    err_exit "Could not create a private Ogmios staging directory."
  pushd "${staging_dir}" >/dev/null ||
    err_exit "Could not enter temporary Ogmios directory."
  cnode_deploy_download_resolved_artifact "ogmios.zip"
  unzip ogmios.zip &>/dev/null ||
    err_exit "Could not extract the resolved Ogmios release."
  rm -f ogmios.zip
  [[ -f bin/ogmios && ! -L bin/ogmios ]] && OGMIOSPATH=bin/ogmios
  [[ -f ogmios && ! -L ogmios ]] && OGMIOSPATH=ogmios
  [[ -n ${OGMIOSPATH} ]] ||
    err_exit "ogmios downloaded but binary not found after extracting package!"
  chmod 0755 "${OGMIOSPATH}" ||
    err_exit "Could not set executable permissions on the staged Ogmios binary."
  mv -f "${OGMIOSPATH}" "${HOME}"/.local/bin/ ||
    err_exit "Could not install the validated Ogmios binary."
  popd >/dev/null || true
  rm -rf -- "${staging_dir}"
  rm -f "${HOME}"/.cabal/bin/ogmios # Remove duplicate from $PATH
  log_ok "Deployed Ogmios" "${ogmios_version}"
}

# Download pre-built cardano-signer binary
download_cardanosigner() {
  local architecture signer_version staging_dir

  cnode_deploy_load_release_metadata
  architecture="$(cnode_deploy_architecture)" ||
    err_exit "Unsupported cardano-signer architecture: $(uname -m)"
  log_progress "Resolving Cardano Signer release"
  cnode_deploy_resolve_tool "cardano-signer" "${architecture}"
  signer_version="${CNODE_RESOLVED_VERSION}"
  log_progress "Downloading Cardano Signer" "${signer_version}"
  staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/guild-cardano-signer.XXXXXX")" ||
    err_exit "Could not create a private Cardano Signer staging directory."
  pushd "${staging_dir}" >/dev/null ||
    err_exit "Could not enter temporary Cardano Signer directory."
  cnode_deploy_download_resolved_artifact "csigner.tar.gz"
  tar zxf csigner.tar.gz &>/dev/null ||
    err_exit "Could not extract the resolved Cardano Signer release."
  rm -f csigner.tar.gz
  [[ -f cardano-signer && ! -L cardano-signer ]] ||
    err_exit "Cardano Signer downloaded but binary(cardano-signer) not found after extracting package!"
  chmod 0755 cardano-signer ||
    err_exit "Could not set executable permissions on the staged Cardano Signer binary."
  mv -f cardano-signer "${HOME}"/.local/bin/ ||
    err_exit "Could not install the validated Cardano Signer binary."
  popd >/dev/null || true
  rm -rf -- "${staging_dir}"
  rm -f "${HOME}"/.cabal/bin/cardano-signer # Remove duplicate from $PATH
  log_ok "Deployed Cardano Signer" "${signer_version}"
}

# Download and execute openBlockPerf installer
download_blockperf() {
  local installer_dir blockperf_installer staged_installer
  local -a blockperf_common_args=(--yes --api-key-mode relay --node-unit-name "${NODE_NAME}" --network "${NETWORK}")
  local release_data policy_mode package_version installer_version
  local installer_url expected_sha actual_sha version_output
  local blockperf_mode="install" rc

  log_info "Preparing openBlockPerf installer."
  cnode_deploy_load_release_metadata

  # Use cntools scripts path when available; fallback to ~/tmp for non-cntools environments.
  if [[ -n "${NODE_HOME}" && -d "${NODE_HOME}/scripts" ]]; then
    installer_dir="${NODE_HOME}/scripts"
  else
    installer_dir="${HOME}/tmp"
    mkdir -p "${installer_dir}" || err_exit "Failed to create installer directory: ${installer_dir}"
  fi
  blockperf_installer="${installer_dir}/blockperf-install.sh"
  [[ -f "${blockperf_installer}" ]] && blockperf_mode="update"

  release_data="$(
    jq -er '
      .managedInstallers.openblockperf |
      [
        .version,
        .installer.url,
        .installer.sha256
      ] | @tsv
    ' "${CNODE_RELEASE_MANIFEST}"
  )" || err_exit "Could not read openBlockPerf release policy."
  IFS=$'\t' read -r package_version installer_url expected_sha \
    <<< "${release_data}"
  case "${package_version}" in
    latest)
      policy_mode="latest"
      package_version=""
      ;;
    *)
      policy_mode="pinned"
      ;;
  esac

  staged_installer="$(mktemp "${installer_dir}/.blockperf-install.XXXXXX")" ||
    err_exit "Could not stage the openBlockPerf installer."
  log_progress "Downloading checksum-pinned openBlockPerf installer"
  if ! curl -fsSL -m "${DOWNLOAD_TIMEOUT}" \
    "${installer_url}" -o "${staged_installer}"; then
    rm -f -- "${staged_installer}"
    err_exit "Download of the release-policy openBlockPerf installer failed."
  fi
  actual_sha="$(sha256sum "${staged_installer}" | awk '{print $1}')" ||
    {
      rm -f -- "${staged_installer}"
      err_exit "Could not calculate the openBlockPerf installer checksum."
    }
  if [[ "${actual_sha}" != "${expected_sha}" ]] ||
     ! bash -n "${staged_installer}" >/dev/null 2>&1 ||
     ! chmod 0755 "${staged_installer}"; then
    rm -f -- "${staged_installer}"
    err_exit "openBlockPerf installer failed checksum, syntax, or permission validation."
  fi
  version_output="$("${staged_installer}" --version 2>/dev/null)" ||
    {
      rm -f -- "${staged_installer}"
      err_exit "openBlockPerf installer could not report its version."
    }
  if [[ ! "${version_output}" =~ ^blockperf-install\.sh[[:space:]]version[[:space:]]([0-9]+([.][0-9]+){1,3}([+-][A-Za-z0-9.-]+)?)$ ]]; then
    rm -f -- "${staged_installer}"
    err_exit "openBlockPerf installer did not report a valid version."
  fi
  installer_version="${BASH_REMATCH[1]}"
  log_info "Validated openBlockPerf installer v${installer_version}."
  mv -f "${staged_installer}" "${blockperf_installer}" ||
    {
      rm -f -- "${staged_installer}"
      err_exit "Could not install the validated openBlockPerf installer."
    }

  log_progress "Running openBlockPerf installer" "${blockperf_mode}/${policy_mode}"
  [[ -t 1 ]] && printf "\n"
  if [[ "${blockperf_mode}" == "update" ]]; then
    $sudo env PACKAGE_VERSION="${package_version}" \
      "${blockperf_installer}" --update "${blockperf_common_args[@]}"
  else
    $sudo env PACKAGE_VERSION="${package_version}" \
      "${blockperf_installer}" "${blockperf_common_args[@]}"
  fi
  rc=$?
  [[ ${rc} -eq 0 ]] ||
    err_exit "openBlockPerf installer failed with exit code ${rc}."
  if [[ "${policy_mode}" == "pinned" ]]; then
    log_ok "Deployed openBlockPerf" "${package_version}, pinned"
  else
    log_ok "Deployed openBlockPerf" "latest stable"
  fi
}

# Download pre-built mithril-signer binary
download_mithril() {
    local architecture mithril_version staging_dir

    cnode_deploy_load_release_metadata
    architecture="$(cnode_deploy_architecture)" ||
      err_exit "Unsupported Mithril architecture: $(uname -m)"
    log_progress "Resolving Mithril release"
    cnode_deploy_resolve_tool "mithril" "${architecture}"
    mithril_version="${CNODE_RESOLVED_VERSION}"
    log_progress "Downloading Mithril signer/client" "${mithril_version}"
    staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/guild-mithril.XXXXXX")" ||
      err_exit "Could not create a private Mithril staging directory."
    pushd "${staging_dir}" >/dev/null ||
      err_exit "Could not enter temporary Mithril directory."
    cnode_deploy_download_resolved_artifact "mithril.tar.gz"
    tar zxf mithril.tar.gz mithril-signer mithril-client &>/dev/null ||
      err_exit "Could not extract the resolved Mithril release."
    rm -f mithril.tar.gz
    [[ -f mithril-signer && ! -L mithril-signer ]] ||
      err_exit "Mithril archive downloaded, but binary 'mithril-signer' was not found after extraction."
    [[ -f mithril-client && ! -L mithril-client ]] ||
      err_exit "Mithril archive downloaded, but binary 'mithril-client' was not found after extraction."
    chmod 0755 mithril-signer mithril-client ||
      err_exit "Could not set executable permissions on the staged Mithril binaries."
    mv -f mithril-signer mithril-client "${HOME}"/.local/bin/ ||
      err_exit "Could not install the validated Mithril binaries."
    popd >/dev/null || true
    rm -rf -- "${staging_dir}"
    log_ok "Deployed mithril-signer" "${mithril_version}"
    log_ok "Deployed mithril-client" "${mithril_version}"
}

# Create folder structure and set up permissions/ownerships
setup_folder() {
  log_progress "Creating folder structure" "${NODE_HOME}"

  if grep -q "export ${CNODE_DEPLOY_ENV_PREFIX}_HOME=" "${HOME}"/.bashrc; then
    log_info "${CNODE_DEPLOY_ENV_PREFIX}_HOME already present in ${HOME}/.bashrc."
  else
    printf '\nexport %s_HOME=%s\n' "${CNODE_DEPLOY_ENV_PREFIX}" "${NODE_HOME}" >> "${HOME}"/.bashrc
    log_info "Added ${CNODE_DEPLOY_ENV_PREFIX}_HOME=${NODE_HOME} to ${HOME}/.bashrc."
  fi

  $sudo mkdir -p "${NODE_HOME}"/files "${NODE_HOME}"/db "${NODE_HOME}"/guild-db "${NODE_HOME}"/logs "${NODE_HOME}"/scripts "${NODE_HOME}"/scripts/adapters "${NODE_HOME}"/scripts/archive "${NODE_HOME}"/scripts/lib "${NODE_HOME}"/sockets "${NODE_HOME}"/priv "${MITHRIL_HOME}"/data-stores
  $sudo chown -R "$U_ID":"$G_ID" "${NODE_HOME}" 2>/dev/null
  log_ok "Folder structure ready" "${NODE_HOME}"

}

retire_legacy_systemd_orchestrator() {
  local legacy_script="${NODE_HOME}/scripts/deploy-as-systemd.sh"
  local archived_script

  [[ -e "${legacy_script}" || -L "${legacy_script}" ]] || return 0
  archived_script="${NODE_HOME}/scripts/archive/deploy-as-systemd.sh_deprecated_$(date +%s).$$"
  if ! mv -f -- "${legacy_script}" "${archived_script}"; then
    err_exit "Could not archive the retired deploy-as-systemd.sh orchestrator."
  fi
  log_info "Archived retired deploy-as-systemd.sh as ${archived_script}."
}

cnode_deploy_fetch_network_config() {
  local remote_name="$1"
  local destination="$2"
  local canonical_url="${URL_RAW}/files/configs/cnode/${NETWORK}/${remote_name}"

  curl -sSfL -m "${CURL_TIMEOUT}" -o "${destination}" "${canonical_url}"
}

cnode_deploy_seed_initial_env_port() {
  local env_preexisted="$1"
  local env_file="${NODE_HOME}/scripts/env"
  local staged_env

  [[ "${env_preexisted}" == "N" ]] || return 0
  [[ -f "${env_file}" ]] ||
    err_exit "Common runtime installation did not create ${env_file}."
  staged_env="$(mktemp "${NODE_HOME}/scripts/.env-port.XXXXXX")" ||
    err_exit "Could not stage the initial cnode port setting."
  if ! awk -v node_port="${NODE_PORT}" '
    BEGIN { updated = 0 }
    /^#CNODE_PORT=/ && updated == 0 {
      printf "CNODE_PORT=%s\n", node_port
      updated = 1
      next
    }
    { print }
    END {
      if (updated == 0) {
        exit 42
      }
    }
  ' "${env_file}" > "${staged_env}"; then
    rm -f -- "${staged_env}"
    err_exit "Could not seed NODE_PORT in the initial cnode environment."
  fi
  if ! chmod 0644 "${staged_env}"; then
    rm -f -- "${staged_env}"
    err_exit "Could not set permissions on the initial cnode environment."
  fi
  if ! mv -f -- "${staged_env}" "${env_file}"; then
    rm -f -- "${staged_env}"
    err_exit "Could not install the initial cnode port setting."
  fi
}

# Download and update scripts for cnode
populate_cnode() {
  local cnode_env_preexisted="N"
  [[ -f "${NODE_HOME}/scripts/env" ]] && cnode_env_preexisted="Y"

  if [[ ! -d "${NODE_HOME}"/files ]]; then
    setup_folder
  else
    # Older cnode deployments predate the shared runtime directories. Ensure
    # they can be migrated even when the network configuration already exists.
    $sudo mkdir -p \
      "${NODE_HOME}/scripts" \
      "${NODE_HOME}/scripts/adapters" \
      "${NODE_HOME}/scripts/archive" \
      "${NODE_HOME}/scripts/lib" || err_exit "Could not create shared runtime directories."
    $sudo chown "$U_ID":"$G_ID" \
      "${NODE_HOME}/scripts" \
      "${NODE_HOME}/scripts/adapters" \
      "${NODE_HOME}/scripts/archive" \
      "${NODE_HOME}/scripts/lib" 2>/dev/null ||
      err_exit "Could not update shared runtime directory ownership."
  fi
  if declare -F dispatcher_mark_in_progress >/dev/null 2>&1; then
    dispatcher_mark_in_progress
  fi
  log_progress "Installing cnode release metadata"
  cnode_deploy_install_release_metadata
  log_ok "cnode release metadata ready" "${CARDANO_NODE_VERSION}"
  log_progress "Downloading network configuration" "${NETWORK}"
  pushd "${NODE_HOME}"/files >/dev/null || err_exit "Could not enter files directory: ${NODE_HOME}/files"

  local err_msg="Could not download network configuration file:"
  # Download node config, genesis and topology from the cnode namespace.
  if [[ ${NETWORK} =~ ^(mainnet|preprod|preview|guild)$ ]]; then
    cnode_deploy_fetch_network_config "alonzo-genesis.json" "alonzo-genesis.json.tmp" || err_exit "${err_msg} alonzo-genesis.json"
    cnode_deploy_fetch_network_config "byron-genesis.json" "byron-genesis.json.tmp" || err_exit "${err_msg} byron-genesis.json"
    cnode_deploy_fetch_network_config "conway-genesis.json" "conway-genesis.json.tmp" || err_exit "${err_msg} conway-genesis.json"
    cnode_deploy_fetch_network_config "shelley-genesis.json" "shelley-genesis.json.tmp" || err_exit "${err_msg} shelley-genesis.json"
    cnode_deploy_fetch_network_config "topology.json" "topology.json.tmp" || err_exit "${err_msg} topology.json"
    cnode_deploy_fetch_network_config "config.json" "config.json.tmp" || err_exit "${err_msg} config.json"
    cnode_deploy_fetch_network_config "db-sync-config.json" "dbsync.json.tmp" || err_exit "${err_msg} db-sync-config.json"
    cnode_deploy_fetch_network_config "submitapi.json" "submitapi.json" || err_exit "${err_msg} submitapi.json"
  else
    err_exit "Unknown network specified! Kindly re-check the network name, valid options are: mainnet, guild, preprod, or preview."
  fi
  log_ok "Network configuration downloaded" "${NETWORK}"
  sed -e "s@/opt/cardano/cnode@${NODE_HOME}@g" -i ./*.json.tmp
  sed -e "s@\"TraceOptionNodeName\": \"cnode\"@\"TraceOptionNodeName\": \"${NODE_NAME}\"@" -i ./config.json.tmp
  if [[ ${CNODE_DEPLOY_FORCE_CONFIG} = 'Y' ]]; then
    [[ -f topology.json ]] && cp -f topology.json "topology.json_bkp$(date +%s)"
    [[ -f config.json ]] && cp -f config.json "config.json_bkp$(date +%s)"
    [[ -f dbsync.json ]] && cp -f dbsync.json "dbsync.json_bkp$(date +%s)"
    log_info "Backed up existing topology/config/dbsync files before overwrite."
  fi
  log_progress "Applying network configuration" "${NETWORK}"
  if [[ ${CNODE_DEPLOY_FORCE_CONFIG} = 'Y' || ! -f byron-genesis.json || ! -f shelley-genesis.json || ! -f alonzo-genesis.json || ! -f topology.json || ! -f config.json || ! -f dbsync.json ]]; then
    mv -f byron-genesis.json.tmp byron-genesis.json
    mv -f shelley-genesis.json.tmp shelley-genesis.json
    mv -f alonzo-genesis.json.tmp alonzo-genesis.json
    mv -f conway-genesis.json.tmp conway-genesis.json
    mv -f topology.json.tmp topology.json
    mv -f config.json.tmp config.json
    mv -f dbsync.json.tmp dbsync.json
  else
    rm -f byron-genesis.json.tmp
    rm -f shelley-genesis.json.tmp
    rm -f alonzo-genesis.json.tmp
    rm -f conway-genesis.json.tmp
    rm -f topology.json.tmp
    rm -f config.json.tmp
    rm -f dbsync.json.tmp
  fi
  log_ok "Network configuration ready" "${NETWORK}"

  pushd "${NODE_HOME}"/scripts >/dev/null || err_exit "Could not enter scripts directory: ${NODE_HOME}/scripts"

  [[ ${CNODE_DEPLOY_FORCE_SCRIPTS} = 'Y' ]] && log_warn "Script force overwrite enabled; review user variables in refreshed scripts and configs."

  log_progress "Refreshing helper scripts" "${BRANCH}"
  ACTIVE_STEP="Refreshing common runtime bundle"
  updateCommonRuntimeBundle ||
    err_exit "Common runtime bundle validation or installation failed; installed runtime files were left unchanged."
  cnode_deploy_seed_initial_env_port "${cnode_env_preexisted}"
  updateWithCustomConfig "blockPerf.sh"
  updateWithCustomConfig "cabal-build-all.sh"
  updateWithCustomConfig "cncli.sh"
  updateWithCustomConfig "cnode.sh"
  updateWithCustomConfig "cntools.sh" "common-helper-scripts"
  updateWithCustomConfig "cntools.library" "common-helper-scripts"
  updateWithCustomConfig "dbsync.sh"
  updateWithCustomConfig "gLiveView.sh" "common-helper-scripts"
  updateWithCustomConfig "topologyUpdater.sh"
  updateWithCustomConfig "logMonitor.sh"
  updateWithCustomConfig "ogmios.sh"
  updateWithCustomConfig "submitapi.sh"
  updateWithCustomConfig "setup_mon.sh"
  updateWithCustomConfig "setup-grest.sh" "grest-helper-scripts"
  updateWithCustomConfig "mithril-client.sh"
  updateWithCustomConfig "mithril-relay.sh"
  updateWithCustomConfig "mithril-signer.sh"
  updateWithCustomConfig "mithril.library"
  # All former orchestrator-owned units now have component-local lifecycle
  # commands. Retire an installed legacy copy only after those scripts refresh.
  retire_legacy_systemd_orchestrator

  find "${NODE_HOME}/scripts" -name '*.sh' -exec chmod 755 {} \; 2>/dev/null
  chmod 750 "${NODE_HOME}"/priv 2>/dev/null
  log_ok "Helper scripts refreshed" "${BRANCH}"
}

# Parse arguments supplied to script
cnode_deploy_parse_flags() {
  local unsupported_flags=""

  CNODE_DEPLOY_INSTALL_OS_DEPS="N"
  CNODE_DEPLOY_BUILD_DEPS="N"
  CNODE_DEPLOY_INSTALL_LIBSODIUM="N"
  CNODE_DEPLOY_INSTALL_MITHRIL="N"
  CNODE_DEPLOY_INSTALL_BINARY="N"
  CNODE_DEPLOY_INSTALL_CNCLI="N"
  CNODE_DEPLOY_INSTALL_OGMIOS="N"
  CNODE_DEPLOY_INSTALL_HWCLI="N"
  CNODE_DEPLOY_INSTALL_SIGNER="N"
  CNODE_DEPLOY_INSTALL_BLOCKPERF="N"
  CNODE_DEPLOY_FORCE_CONFIG="N"
  CNODE_DEPLOY_FORCE_SCRIPTS="N"
  CNODE_DEPLOY_REFRESH_PAYLOAD="Y"
  CNODE_DEPLOY_NO_SELECTIVE_FLAGS="N"
  CNODE_DEPLOY_ADDED_LOCAL_BIN_PATH="N"
  CNODE_DEPLOY_FRESH_TARGET="N"

  if [[ -n "${S_ARGS}" ]]; then
    unsupported_flags="${S_ARGS//[pblmdcowxrsf]/}"
    [[ -z "${unsupported_flags}" ]] ||
      err_exit "Unsupported cnode -s flag(s): '${unsupported_flags}'."
    [[ "${S_ARGS}" =~ "p" ]] && CNODE_DEPLOY_INSTALL_OS_DEPS="Y"
    [[ "${S_ARGS}" =~ "b" ]] &&
      CNODE_DEPLOY_INSTALL_OS_DEPS="Y" &&
      CNODE_DEPLOY_BUILD_DEPS="Y"
    [[ "${S_ARGS}" =~ "l" ]] &&
      CNODE_DEPLOY_INSTALL_OS_DEPS="Y" &&
      CNODE_DEPLOY_INSTALL_LIBSODIUM="Y"
    [[ "${S_ARGS}" =~ "m" ]] && CNODE_DEPLOY_INSTALL_MITHRIL="Y"
    [[ "${S_ARGS}" =~ "f" ]] && CNODE_DEPLOY_FORCE_CONFIG="Y"
    [[ "${S_ARGS}" =~ "s" ]] && CNODE_DEPLOY_FORCE_SCRIPTS="Y"
    [[ "${S_ARGS}" =~ "d" ]] && CNODE_DEPLOY_INSTALL_BINARY="Y"
    [[ "${S_ARGS}" =~ "c" ]] && CNODE_DEPLOY_INSTALL_CNCLI="Y"
    [[ "${S_ARGS}" =~ "o" ]] && CNODE_DEPLOY_INSTALL_OGMIOS="Y"
    [[ "${S_ARGS}" =~ "w" ]] &&
      CNODE_DEPLOY_INSTALL_OS_DEPS="Y" &&
      CNODE_DEPLOY_INSTALL_HWCLI="Y"
    [[ "${S_ARGS}" =~ "x" ]] && CNODE_DEPLOY_INSTALL_SIGNER="Y"
    [[ "${S_ARGS}" =~ "r" ]] && CNODE_DEPLOY_INSTALL_BLOCKPERF="Y"
  else
    CNODE_DEPLOY_NO_SELECTIVE_FLAGS="Y"
  fi

  cnode_deploy_init_context
  if [[ ! -d "${NODE_HOME}"/files ]]; then
    # Guess this is a fresh machine and set minimal params
    CNODE_DEPLOY_INSTALL_OS_DEPS="Y"
    CNODE_DEPLOY_FRESH_TARGET="Y"
  fi
}

# Main Flow for calling different functions
cnode_deploy_main_flow() {
  [[ "${CNODE_DEPLOY_NO_SELECTIVE_FLAGS}" == "Y" ]] && log_info "No selective install flags supplied; refreshing scripts and configuration only."
  [[ "${CNODE_DEPLOY_ADDED_LOCAL_BIN_PATH}" == "Y" ]] && log_info "Added ${HOME}/.local/bin to PATH in ${HOME}/.bashrc."
  [[ "${CNODE_DEPLOY_FRESH_TARGET}" == "Y" ]] && log_info "Fresh target detected; OS dependency check enabled."
  [[ "${CNODE_DEPLOY_INSTALL_OS_DEPS}" == "Y" ]] && run_step "OS dependencies" "auto/-s p/b/l/w" os_dependencies
  [[ "${CNODE_DEPLOY_REFRESH_PAYLOAD}" == "Y" ]] && run_step "Scripts and configuration" "default/-s f/s" populate_cnode
  [[ "${CNODE_DEPLOY_BUILD_DEPS}" == "Y" ]] && run_step "Haskell build toolchain" "-s b" build_dependencies
  [[ "${CNODE_DEPLOY_INSTALL_LIBSODIUM}" == "Y" ]] && run_step "libsodium" "-s l" build_libsodium
  [[ "${CNODE_DEPLOY_INSTALL_MITHRIL}" == "Y" ]] && run_step "Mithril binaries" "-s m" download_mithril
  [[ "${CNODE_DEPLOY_INSTALL_BINARY}" == "Y" ]] && run_step "Cardano node binaries" "-s d" download_cnodebins
  [[ "${CNODE_DEPLOY_INSTALL_CNCLI}" == "Y" ]] && run_step "CNCLI" "-s c" download_cncli
  [[ "${CNODE_DEPLOY_INSTALL_OGMIOS}" == "Y" ]] && run_step "Ogmios" "-s o" download_ogmios
  [[ "${CNODE_DEPLOY_INSTALL_HWCLI}" == "Y" ]] && run_step "Cardano hardware CLI" "-s w" download_cardanohwcli
  [[ "${CNODE_DEPLOY_INSTALL_SIGNER}" == "Y" ]] && run_step "Cardano Signer" "-s x" download_cardanosigner
  [[ "${CNODE_DEPLOY_INSTALL_BLOCKPERF}" == "Y" ]] && run_step "openBlockPerf" "-s r" download_blockperf
}

deploy_cnode_profile() {
  ACTIVE_STEP="Initialize cnode deployment"
  cnode_deploy_parse_flags
  log_header
  cnode_deploy_main_flow
  PROFILE_TARGET_NODE_VERSION="${CARDANO_NODE_VERSION:-}"

  pushd -0 >/dev/null || err_exit "Could not restore original working directory."
  dirs -c
  log_ok "cnode profile completed"
  printf "\n"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "deploy-cnode.sh is an internal profile. Run guild-deploy.sh -i cnode instead." >&2
  exit 1
fi
