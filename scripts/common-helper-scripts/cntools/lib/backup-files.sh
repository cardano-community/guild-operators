#!/usr/bin/env bash
# Private backup staging and bounded, non-executing archive import.
# Uses filesystem.sh for common filesystem facts, never the CLI runtime.
# shellcheck disable=SC2034,SC2015
CNTOOLS_BACKUP_WORK=''
CNTOOLS_BACKUP_ERROR=''
CNTOOLS_BACKUP_RESULT=''
CNTOOLS_BACKUP_KIND=''
CNTOOLS_BACKUP_NETWORK=''
CNTOOLS_BACKUP_TAR_VERSION=''
CNTOOLS_BACKUP_IMPORTED=0
CNTOOLS_BACKUP_SKIPPED=0
CNTOOLS_BACKUP_MAX_BYTES=536870912
CNTOOLS_BACKUP_MAX_ENTRIES=20000
declare -ag CNTOOLS_BACKUP_MEMBERS=() CNTOOLS_BACKUP_FILES=() CNTOOLS_BACKUP_OBJECTS=() CNTOOLS_BACKUP_STAGES=()
declare -Ag CNTOOLS_BACKUP_SIZES=()

cntools_backup_error() {
  CNTOOLS_BACKUP_ERROR="$1"
  cntools_log ERROR "${CNTOOLS_BACKUP_ERROR}" || true
  return 1
}

cntools_backup_command() {
  local mask=''
  local -a command=("$@")
  if [[ "$1" == tar ]]; then
    # Never let inherited options add transforms, absolute extraction,
    # checkpoints or executable hooks that were absent from validation/logs.
    if [[ "${CNTOOLS_BACKUP_TAR_VERSION}" == *'GNU tar'* ]]; then
      command=(env -u TAR_OPTIONS tar --force-local "${@:2}")
    else command=(env -u TAR_OPTIONS tar "${@:2}"); fi
  fi
  printf -v mask '%*s' "${#command[@]}" ''; mask="${mask// /0}"
  cntools_run_command_timeout 300 "${mask}" -- "${command[@]}"
}

cntools_backup_cleanup() {
  local stage=''
  # Only this action's freshly allocated workspace is disposable. Published
  # backups/recovery folders and original archives are never cleanup targets.
  if [[ "${CNTOOLS_BACKUP_WORK}" == "${CNTOOLS_TMP_DIR%/}/.cntools-backup."* &&
        -d "${CNTOOLS_BACKUP_WORK}" && ! -L "${CNTOOLS_BACKUP_WORK}" && -O "${CNTOOLS_BACKUP_WORK}" ]]; then
    chmod -R u+rwX -- "${CNTOOLS_BACKUP_WORK}" || true
    rm -rf -- "${CNTOOLS_BACKUP_WORK}"
  fi
  CNTOOLS_BACKUP_WORK=''
  for stage in "${CNTOOLS_BACKUP_STAGES[@]}"; do
    [[ ! -L "${stage}" && -O "${stage}" ]] || continue
    case "${stage##*/}" in
      .cntools-backup.*) [[ ! -f "${stage}" ]] || rm -f -- "${stage}" ;;
      .cntools-restore.*) [[ ! -d "${stage}" ]] || rm -rf -- "${stage}" ;;
    esac
  done
  CNTOOLS_BACKUP_STAGES=()
}

cntools_backup_directory_safe() {
  local directory="$1" mode='' physical=''
  [[ "${directory}" == /* && "${directory}" != / && -d "${directory}" &&
     ! -L "${directory}" && -O "${directory}" && -w "${directory}" && -x "${directory}" ]] &&
    cntools_filesystem_path_components_safe "${directory}" &&
    cntools_filesystem_directory_ancestry_safe "${directory}" &&
    cntools_filesystem_mode_into mode "${directory}" || return 1
  physical="$(cd -- "${directory}" && pwd -P)" || return 1
  [[ "${physical}" == "${directory%/}" ]] || return 1
  (( (8#${mode} & 0022) == 0 ))
}

cntools_backup_environment() {
  local tool='' version=''
  for tool in tar gzip sha256sum jq cp mv find sort cmp head cat env; do
    type -P "${tool}" >/dev/null || { cntools_backup_error "Backup requires ${tool}."; return 1; }
  done
  CNTOOLS_BACKUP_TAR_VERSION="$(env -u TAR_OPTIONS tar --version)" || return 1
  [[ "${CNTOOLS_BACKUP_TAR_VERSION}" == *'GNU tar'* || "${CNTOOLS_BACKUP_TAR_VERSION}" == bsdtar* ]] || return 1
  version="$(mv --help 2>/dev/null)" || return 1
  [[ "${version}" == *--no-target-directory* && "${version}" == *--no-clobber* ]] || {
    cntools_backup_error 'GNU coreutils mv is required for no-overwrite publication.'; return 1;
  }
  cntools_backup_directory_safe "${CNTOOLS_TMP_DIR:-}" || {
    cntools_backup_error 'The configured temporary directory must be owned, writable and protected from other users changing its contents.'; return 1;
  }
  cntools_backup_cleanup
  CNTOOLS_BACKUP_ERROR=''; CNTOOLS_BACKUP_RESULT=''
  CNTOOLS_BACKUP_WORK="$(umask 077; mktemp -d "${CNTOOLS_TMP_DIR%/}/.cntools-backup.XXXXXXXX")" || return 1
}

cntools_backup_listing() {
  local archive="$1" operation="$2" output="$3" limit="$4" size=''
  # Bound listing storage and memory before mapfile, including pathological
  # archives with millions of members or enormous PAX path strings.
  (set -o pipefail; cntools_backup_command tar "${operation}" "${archive}" 2> "${CNTOOLS_BACKUP_WORK}/errors" | head -c "$((limit+1))" > "${output}") || return 1
  cntools_filesystem_size_into size "${output}" && (( size <= limit ))
}

cntools_backup_role_root_into() {
  local -n root_output="$1"
  case "$2" in
    wallets) root_output="${CNTOOLS_WALLET_DIR:-}" ;;
    pools) root_output="${CNTOOLS_POOL_DIR:-}" ;;
    assets) root_output="${CNTOOLS_ASSET_DIR:-}" ;;
    *) return 1 ;;
  esac
  root_output="${root_output%/}"
}

cntools_backup_member_valid() {
  local member="${1%/}" part='' LC_ALL=C
  local -a parts=()
  [[ -n "${member}" && "${member}" != /* && "${member}" != *//* &&
     "${member}" =~ ^[A-Za-z0-9._/-]+$ && ${#member} -le 1024 ]] || return 1
  IFS=/ read -r -a parts <<< "${member}"
  for part in "${parts[@]}"; do [[ "${part}" != . && "${part}" != .. ]] || return 1; done
}

# Inspect types, names, duplicates and declared expansion before reading even
# one archive payload. Extraction is confined to a fresh, private workspace.
cntools_backup_archive_index() {
  local archive="$1" name='' verbose='' type='' size='' bytes=0 index=0 tar_version=''
  local -a lines=() fields=()
  local -A seen=()
  CNTOOLS_BACKUP_MEMBERS=(); CNTOOLS_BACKUP_FILES=(); CNTOOLS_BACKUP_SIZES=()
  cntools_transaction_file_safe "${archive}" "${CNTOOLS_BACKUP_MAX_BYTES}" || return 1
  cntools_backup_listing "${archive}" -tzf "${CNTOOLS_BACKUP_WORK}/names" 8388608 &&
    cntools_backup_listing "${archive}" -tvzf "${CNTOOLS_BACKUP_WORK}/listing" 16777216 || {
    cntools_backup_error 'The backup is not a readable gzip-compressed tar archive.'; return 1;
  }
  mapfile -t CNTOOLS_BACKUP_MEMBERS < "${CNTOOLS_BACKUP_WORK}/names"
  mapfile -t lines < "${CNTOOLS_BACKUP_WORK}/listing"
  (( ${#lines[@]} == ${#CNTOOLS_BACKUP_MEMBERS[@]} && ${#lines[@]} > 0 && ${#lines[@]} <= CNTOOLS_BACKUP_MAX_ENTRIES )) || return 1
  tar_version="${CNTOOLS_BACKUP_TAR_VERSION}"
  for name in "${CNTOOLS_BACKUP_MEMBERS[@]}"; do
    cntools_backup_member_valid "${name}" && [[ ! -v 'seen[${name%/}]' ]] || {
      cntools_backup_error 'The backup contains an unsafe or duplicate archive path.'; return 1;
    }
    seen["${name%/}"]=1
    verbose="${lines[index]}"; index=$((index+1)); type="${verbose:0:1}"
    # GNU tar and bsdtar verbose layouts differ. Neither may introduce a
    # symlink, hard link, device, FIFO or socket, even inside a private stage.
    read -r -a fields <<< "${verbose}"
    size="${fields[2]:-}"
    [[ "${tar_version}" != bsdtar* ]] || size="${fields[4]:-}"
    [[ "${size}" =~ ^[0-9]+$ && ${#size} -le 9 ]] || return 1
    bytes=$((bytes + 10#${size}))
    (( bytes <= CNTOOLS_BACKUP_MAX_BYTES )) || {
      cntools_backup_error 'The backup exceeds the 512 MiB expanded-data limit.'; return 1;
    }
    case "${type}" in
      d) [[ "${name}" == */ && "${size}" == 0 && "${verbose:3:1}" == x ]] || return 1 ;;
      -) [[ "${name}" != */ ]] || return 1
        CNTOOLS_BACKUP_FILES+=("${name}"); CNTOOLS_BACKUP_SIZES["${name}"]="${size}" ;;
      *) cntools_backup_error 'Backups may contain only ordinary files and directories, not links or special files.'; return 1 ;;
    esac
  done
  # A file cannot also be a parent directory. Reject before any import.
  for name in "${CNTOOLS_BACKUP_MEMBERS[@]}"; do
    verbose="${name%/}"
    while [[ "${verbose}" == */* ]]; do
      verbose="${verbose%/*}"
      [[ ! -v 'CNTOOLS_BACKUP_SIZES[$verbose]' ]] || return 1
    done
  done
}

cntools_backup_archive_unpack() {
  local archive="$1" member='' path='' version=''
  local -a options=(--no-same-owner --no-same-permissions --no-acls --no-xattrs)
  [[ ! -e "${CNTOOLS_BACKUP_WORK}/unpacked" && ${#CNTOOLS_BACKUP_MEMBERS[@]} -gt 0 ]] || return 1
  mkdir -m 0700 -- "${CNTOOLS_BACKUP_WORK}/unpacked" || return 1
  version="${CNTOOLS_BACKUP_TAR_VERSION}"
  if [[ "${version}" == bsdtar* ]]; then options+=(--no-fflags); else options+=(--no-selinux); fi
  # Index validation rejects all links, special files, absolute/traversing paths,
  # duplicate names and file/parent collisions. This frozen archive can therefore
  # be unpacked once into an empty private directory, never a live destination.
  # Avoid decompressing an entire potentially large backup once per key file.
  (umask 077; COPYFILE_DISABLE=1 cntools_backup_command tar -xzf "${archive}" "${options[@]}" -C "${CNTOOLS_BACKUP_WORK}/unpacked") || return 1
  for member in "${CNTOOLS_BACKUP_MEMBERS[@]}"; do
    path="${CNTOOLS_BACKUP_WORK}/unpacked/${member%/}"
    [[ ! -L "${path}" && -O "${path}" ]] || return 1
    if [[ "${member}" == */ ]]; then
      [[ -d "${path}" ]] && chmod 0700 -- "${path}" || return 1
    else
      [[ -f "${path}" ]] && chmod 0600 -- "${path}" || return 1
    fi
  done
}

cntools_backup_payload() {
  local archive="$1" member="$2" target="$3" size=''
  [[ -v 'CNTOOLS_BACKUP_SIZES[$member]' && ! -e "${target}" && ! -L "${target}" ]] || return 1
  # Validated names are literal ASCII paths (no glob metacharacters/options).
  # Exclusive destination creation prevents any accidental counterpart reuse.
  if [[ -d "${CNTOOLS_BACKUP_WORK}/unpacked" ]]; then
    (umask 077; set -o noclobber; cntools_backup_command cat -- "${CNTOOLS_BACKUP_WORK}/unpacked/${member}" > "${target}") || return 1
  else
    (umask 077; set -o noclobber; cntools_backup_command tar -xOzf "${archive}" -- "${member}" > "${target}") || return 1
  fi
  cntools_filesystem_size_into size "${target}" || return 1
  [[ "${size}" == "${CNTOOLS_BACKUP_SIZES[${member}]}" ]]
}

cntools_backup_hash_into() {
  local -n hash_output="$1"
  local result=''
  result="$(sha256sum -- "$2")" || return 1
  hash_output="${result%% *}"
  [[ "${hash_output}" =~ ^[0-9a-f]{64}$ ]]
}

cntools_backup_publish() {
  local source="$1" target="$2"
  [[ ! -e "${target}" && ! -L "${target}" ]] || return 1
  cntools_backup_command mv -T -n -- "${source}" "${target}" || return 1
  [[ ! -e "${source}" && -e "${target}" && ! -L "${target}" ]]
}
