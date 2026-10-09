#!/usr/bin/env bash
# Snapshot creation and conservative restore. Never merges existing objects.
# shellcheck disable=SC2034,SC2015,SC2153

# Coverage is filename-based advice, not proof that a key is valid or belongs
# to its public artifact. Never read a signing key, password or mnemonic here.
declare -ag CNTOOLS_BACKUP_COVERAGE_LABELS=() CNTOOLS_BACKUP_COVERAGE_VALUES=()
CNTOOLS_BACKUP_MISSING_KEYS=0

cntools_backup_recovery_coverage() {
  local role='' root='' directory='' public='' secret='' hardware='' prefix='' label='' value=''
  CNTOOLS_BACKUP_COVERAGE_LABELS=(); CNTOOLS_BACKUP_COVERAGE_VALUES=(); CNTOOLS_BACKUP_MISSING_KEYS=0
  for role in wallets pools assets; do
    cntools_backup_role_root_into root "${role}" || return 1
    [[ -e "${root}" || -L "${root}" ]] || continue
    cntools_backup_directory_safe "${root}" || return 1
    for directory in "${root}"/*; do
      [[ -d "${directory}" && ! -L "${directory}" && -O "${directory}" ]] || continue
      local -a public_names=() secret_names=() hardware_names=()
      case "${role}" in
        wallets)
          public_names=("${CNTOOLS_WALLET_PAY_VKEY_FILENAME:-payment.vkey}" "${CNTOOLS_WALLET_STAKE_VKEY_FILENAME:-stake.vkey}" "${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}" "${CNTOOLS_WALLET_CATALYST_VKEY_FILENAME:-catalyst.vkey}" "${CNTOOLS_WALLET_CC_COLD_VKEY_FILENAME:-cc-cold.vkey}" "${CNTOOLS_WALLET_CC_HOT_VKEY_FILENAME:-cc-hot.vkey}")
          secret_names=("${CNTOOLS_WALLET_PAY_SKEY_FILENAME:-payment.skey}" "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME:-stake.skey}" "${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}" "${CNTOOLS_WALLET_CATALYST_SKEY_FILENAME:-catalyst.skey}" "${CNTOOLS_WALLET_CC_COLD_SKEY_FILENAME:-cc-cold.skey}" "${CNTOOLS_WALLET_CC_HOT_SKEY_FILENAME:-cc-hot.skey}")
          hardware_names=("${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME:-payment.hwsfile}" "${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME:-stake.hwsfile}" "${CNTOOLS_WALLET_HW_DREP_SKEY_FILENAME:-drep.hwsfile}" '' '' '')
          ;;
        pools)
          public_names=("${CNTOOLS_POOL_COLD_VKEY_FILENAME:-cold.vkey}" "${CNTOOLS_POOL_VRF_VKEY_FILENAME:-vrf.vkey}" "${CNTOOLS_POOL_KES_VKEY_FILENAME:-hot.vkey}" "${CNTOOLS_POOL_CALIDUS_VKEY_FILENAME:-calidus.vkey}")
          secret_names=("${CNTOOLS_POOL_COLD_SKEY_FILENAME:-cold.skey}" "${CNTOOLS_POOL_VRF_SKEY_FILENAME:-vrf.skey}" "${CNTOOLS_POOL_KES_SKEY_FILENAME:-hot.skey}" "${CNTOOLS_POOL_CALIDUS_SKEY_FILENAME:-calidus.skey}")
          hardware_names=("${CNTOOLS_POOL_COLD_HW_FILENAME:-cold.hwsfile}" '' '' '')
          ;;
        assets)
          public_names=("${CNTOOLS_POLICY_VKEY_FILENAME:-policy.vkey}")
          secret_names=("${CNTOOLS_POLICY_SKEY_FILENAME:-policy.skey}"); hardware_names=('') ;;
      esac
      local index=0 coverage_start="${#CNTOOLS_BACKUP_COVERAGE_LABELS[@]}"
      local -a prefixes=('')
      [[ "${role}" != wallets ]] || prefixes+=("${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}")
      for prefix in "${prefixes[@]}"; do
        for ((index=0; index<${#public_names[@]}; index++)); do
          public="${prefix}${public_names[index]}"; secret="${prefix}${secret_names[index]}"
          hardware="${hardware_names[index]}"; [[ -z "${hardware}" ]] || hardware="${prefix}${hardware}"
          [[ -f "${directory}/${public}" || -f "${directory}/${secret}" || -f "${directory}/${secret}.gpg" ]] || continue
          label="${role}/${directory##*/} · ${public}"
          if [[ -f "${directory}/${secret}" && ! -L "${directory}/${secret}" ]] ||
             [[ -f "${directory}/${secret}.gpg" && ! -L "${directory}/${secret}.gpg" ]]; then
            value='Signing key present (plain or encrypted)'
          elif [[ -n "${hardware}" && -f "${directory}/${hardware}" && ! -L "${directory}/${hardware}" ]]; then
            value='Hardware reference only · original device/recovery seed required'
          else
            value="Missing ${secret} · watch-only/external signer; cannot recover this key from the backup"
            CNTOOLS_BACKUP_MISSING_KEYS=$((CNTOOLS_BACKUP_MISSING_KEYS+1))
            cntools_log WARN "Backup recovery coverage: ${label}: ${value}" || true
          fi
          CNTOOLS_BACKUP_COVERAGE_LABELS+=("${label}"); CNTOOLS_BACKUP_COVERAGE_VALUES+=("${value}")
        done
      done
      if (( coverage_start == ${#CNTOOLS_BACKUP_COVERAGE_LABELS[@]} )); then
        label="${role}/${directory##*/}"
        value='No recognized local signing keys · external keys/recovery material may be required'
        CNTOOLS_BACKUP_COVERAGE_LABELS+=("${label}"); CNTOOLS_BACKUP_COVERAGE_VALUES+=("${value}")
        cntools_log WARN "Backup recovery coverage: ${label}: ${value}" || true
      fi
    done
  done
}

cntools_backup_public_file() {
  local role="$1" name="${2##*/}" configured='' value=''
  # Allow known public artifacts only; an exclude list could leak a custom
  # private key, seed or password file. Nested/unknown files are full-only.
  case "${name}" in *.skey|*.gpg) return 1 ;; esac
  for configured in ${!CNTOOLS_WALLET_@} ${!CNTOOLS_POOL_@} ${!CNTOOLS_POLICY_@}; do
    # HWS files contain public keys and device derivation paths, not secrets.
    [[ "${configured}" == *SKEY_FILENAME && "${configured}" != *_HW_* ]] || continue
    value="${!configured}"
    [[ "${name}" != "${value}" && "${name}" != "${value}.gpg" ]] || return 1
    if [[ "${configured}" == CNTOOLS_WALLET_* ]]; then
      [[ "${name}" != "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}${value}" &&
         "${name}" != "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}${value}.gpg" ]] || return 1
    fi
  done
  case "${role}" in
    wallets)
      case "${name}" in
        "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}derivation.json"|\
        "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}${CNTOOLS_WALLET_PAY_VKEY_FILENAME}"|\
        "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}"|\
        "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}${CNTOOLS_WALLET_PAY_CRED_FILENAME}"|\
        "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}${CNTOOLS_WALLET_STAKE_CRED_FILENAME}"|\
        "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}"|\
        "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}") return 0 ;;
      esac
      for configured in ${!CNTOOLS_WALLET_@}; do
        [[ "${configured}" == *_FILENAME && ( "${configured}" != *SKEY* || "${configured}" == *_HW_* ) ]] || continue
        value="${!configured}"
        [[ "${name}" != "${value}" ]] || return 0
      done
      ;;
    pools)
      for configured in ${!CNTOOLS_POOL_@}; do
        [[ "${configured}" == *_FILENAME && "${configured}" != *SKEY* ]] || continue
        value="${!configured}"
        [[ "${name}" != "${value}" ]] || return 0
      done
      ;;
    assets)
      case "${name}" in
        "${CNTOOLS_POLICY_VKEY_FILENAME:-policy.vkey}"|"${CNTOOLS_POLICY_ID_FILENAME:-policy.id}"|"${CNTOOLS_POLICY_SCRIPT_FILENAME:-policy.script}") return 0 ;;
      esac ;;
  esac
  return 1
}

cntools_backup_tree_inventory() {
  local role='' root='' path='' relative='' size='' hash='' total=0 count=0 kind='' mode=''
  for role in wallets pools assets; do
    cntools_backup_role_root_into root "${role}" || return 1
    [[ -n "${root}" && "${root}" == /* && "${root}" != / ]] || return 1
    [[ -e "${root}" || -L "${root}" ]] || continue
    cntools_backup_directory_safe "${root}" || return 1
    cntools_backup_command find "${root}" -mindepth 1 -print0 > "${CNTOOLS_BACKUP_WORK}/tree" || return 1
    while IFS= read -r -d '' path; do
      relative="${path#"${root}/"}"
      cntools_backup_member_valid "${relative}" && [[ ! -L "${path}" && -O "${path}" ]] || {
        cntools_backup_error 'Source data contains unsupported paths, links or files not owned by this user.'; return 1;
      }
      # Issuance/install can cross several files. Refuse active operations,
      # rather than blessing a torn cold-counter/opcert snapshot.
      [[ "${relative}" != */.cntools-opcert-lock/busy* ]] || {
        cntools_backup_error 'A pool certificate operation is in progress. Finish it before creating a backup.'; return 1;
      }
      count=$((count+1)); (( count <= CNTOOLS_BACKUP_MAX_ENTRIES )) || return 1
      if [[ -d "${path}" ]]; then
        cntools_filesystem_mode_into mode "${path}" && (( (8#${mode} & 0022) == 0 )) || {
          cntools_backup_error 'A source subdirectory permits group or public writes. Protect it before creating a backup.'; return 1;
        }
        kind=d; hash='-'; size=0
      elif [[ -f "${path}" && -r "${path}" ]]; then
        [[ "${relative}" == */* ]] || {
          cntools_backup_error 'Backup roots must contain named folders, not loose files. Move loose files into their wallet, pool or asset folder first.'; return 1;
        }
        kind=f
        cntools_filesystem_size_into size "${path}" && cntools_backup_hash_into hash "${path}" || return 1
        [[ ${#size} -le 9 ]] || return 1
        total=$((total+size)); (( total <= CNTOOLS_BACKUP_MAX_BYTES )) || return 1
      else
        cntools_backup_error 'Source data contains a socket, device or other unsupported file.'; return 1
      fi
      printf '%s\t%s\t%s\t%s\n' "${role}/${relative}" "${kind}" "${size}" "${hash}"
    done < "${CNTOOLS_BACKUP_WORK}/tree"
  done
}

cntools_backup_create() {
  local destination="$1" include="$2" encryption="$3" password="${4:-}"
  local path='' kind='' size='' hash='' root='' role='' relative='' filename='' binary='' output='' verified=''
  [[ "${include}" == full || "${include}" == public ]] &&
    [[ "${encryption}" == encrypted || "${encryption}" == plain ]] || return 2
  cntools_backup_environment && cntools_backup_directory_safe "${destination}" || {
    cntools_backup_error 'Backup destination must be an existing owned, writable directory with no group/public write access.'; return 1;
  }
  for role in wallets pools assets; do
    cntools_backup_role_root_into root "${role}" || return 1
    [[ "${destination%/}" != "${root%/}" && "${destination}" != "${root%/}/"* &&
       "${CNTOOLS_BACKUP_WORK}" != "${root%/}/"* ]] || {
      cntools_backup_error 'Backup and temporary directories must be outside wallet, pool and asset data.'; return 1;
    }
  done
  if [[ "${encryption}" == encrypted ]]; then
    [[ -n "${password}" && ${#password} -ge 12 && "${password}" != *$'\n'* && "${password}" != *$'\r'* ]] || return 1
    binary="$(type -P gpg || type -P gpg2)" || { cntools_backup_error 'Install GnuPG to encrypt backups.'; return 1; }
  fi
  cntools_backup_tree_inventory > "${CNTOOLS_BACKUP_WORK}/before" || return 1
  [[ -s "${CNTOOLS_BACKUP_WORK}/before" ]] || { cntools_backup_error 'There are no wallet, pool or asset folders to back up.'; return 1; }
  mkdir -m 0700 -- "${CNTOOLS_BACKUP_WORK}/snapshot" || return 1
  : > "${CNTOOLS_BACKUP_WORK}/records"
  while IFS=$'\t' read -r path kind size hash; do
    role="${path%%/*}"; relative="${path#*/}"
    if [[ "${kind}" == d ]]; then
      [[ "${include}" == public ]] || (umask 077; mkdir -p -- "${CNTOOLS_BACKUP_WORK}/snapshot/${path}") || return 1
      continue
    fi
    if [[ "${include}" == public ]]; then
      [[ "${relative}" != */*/* && "${relative%%/*}" != .* ]] || continue
      cntools_backup_public_file "${role}" "${relative}" || continue
    fi
    cntools_backup_role_root_into root "${role}" || return 1
    output="${CNTOOLS_BACKUP_WORK}/snapshot/${path}"
    (umask 077; mkdir -p -- "${output%/*}") || return 1
    cntools_backup_command cp -- "${root}/${relative}" "${output}" && chmod 0600 -- "${output}" || return 1
    cntools_backup_hash_into verified "${output}" && [[ "${verified}" == "${hash}" ]] || {
      cntools_backup_error 'Source files changed during backup. Retry without other wallet/pool operations running.'; return 1;
    }
    printf '%s\t%s\n' "${path}" "${hash}" >> "${CNTOOLS_BACKUP_WORK}/records"
  done < "${CNTOOLS_BACKUP_WORK}/before"
  # Recheck the complete inventory, including removed/added files and counters.
  cntools_backup_tree_inventory > "${CNTOOLS_BACKUP_WORK}/after" &&
    cmp -s "${CNTOOLS_BACKUP_WORK}/before" "${CNTOOLS_BACKUP_WORK}/after" || {
    cntools_backup_error 'Source data changed during backup. Nothing was published.'; return 1;
  }
  [[ -s "${CNTOOLS_BACKUP_WORK}/records" ]] || { cntools_backup_error 'No eligible public artifacts were found.'; return 1; }
  jq -Rn --arg network "${CNTOOLS_NETWORK:-unknown}" --arg kind "${include}" --arg created "$(date -u +%FT%TZ)" \
    '[inputs | split("\t") | {path:.[0],sha256:.[1]}] as $files |
    {schema:"org.cardano-community.cntools.backup",version:1,network:$network,kind:$kind,created:$created,files:$files}' \
    < "${CNTOOLS_BACKUP_WORK}/records" > "${CNTOOLS_BACKUP_WORK}/snapshot/manifest.json" || return 1
  cntools_filesystem_size_into size "${CNTOOLS_BACKUP_WORK}/snapshot/manifest.json" && (( size <= 8388608 )) || return 1
  local -a roots=(manifest.json)
  for role in wallets pools assets; do [[ ! -d "${CNTOOLS_BACKUP_WORK}/snapshot/${role}" ]] || roots+=("${role}"); done
  output="${CNTOOLS_BACKUP_WORK}/backup.tar.gz"
  cntools_backup_command tar --format=ustar -czf "${output}" -C "${CNTOOLS_BACKUP_WORK}/snapshot" "${roots[@]}" || return 1
  chmod 0600 -- "${output}" || return 1
  cntools_backup_archive_index "${output}" || return 1
  filename="cntools-${include}-$(date -u +%Y%m%dT%H%M%SZ)-${CNTOOLS_BACKUP_WORK##*.}.tar.gz"
  if [[ "${encryption}" == encrypted ]]; then
    : > "${CNTOOLS_BACKUP_WORK}/encrypted"; : > "${CNTOOLS_BACKUP_WORK}/roundtrip"; : > "${CNTOOLS_BACKUP_WORK}/errors"
    cntools_backup_crypto "${binary}" encrypt "${output}" "${CNTOOLS_BACKUP_WORK}/encrypted" "${password}" &&
      cntools_backup_crypto "${binary}" decrypt "${CNTOOLS_BACKUP_WORK}/encrypted" "${CNTOOLS_BACKUP_WORK}/roundtrip" "${password}" &&
      cmp -s "${output}" "${CNTOOLS_BACKUP_WORK}/roundtrip" || {
      cntools_backup_error 'Backup encryption could not be round-trip verified. No backup was published.'; return 1;
    }
    output="${CNTOOLS_BACKUP_WORK}/encrypted"; filename+=.gpg
  fi
  # Publication stage must be on the destination filesystem for atomic rename.
  local stage=''
  stage="$(umask 077; mktemp "${destination%/}/.cntools-backup.XXXXXXXX")" || return 1
  CNTOOLS_BACKUP_STAGES+=("${stage}")
  if ! cntools_backup_command cp -- "${output}" "${stage}" || ! cmp -s "${output}" "${stage}" ||
     ! cntools_backup_publish "${stage}" "${destination%/}/${filename}"; then
    rm -f -- "${stage}"; cntools_backup_error 'The backup could not be published without overwriting a file.'; return 1
  fi
  CNTOOLS_BACKUP_RESULT="${destination%/}/${filename}"
  cntools_log BACKUP "created kind=${include} encryption=${encryption} file=${CNTOOLS_BACKUP_RESULT}" || true
}

# Reuse the private-key GPG transport, with bounded archive output and timeout.
cntools_backup_crypto() {
  : > "${CNTOOLS_BACKUP_WORK}/errors"
  cntools_key_crypto_run "$1" "$2" "$3" "$4" "$5" "${CNTOOLS_BACKUP_WORK}/errors" 300 "${CNTOOLS_BACKUP_MAX_BYTES}"
}

cntools_backup_restore_path_into() {
  local -n mapped_output="$1"
  local member="${2%/}" legacy="$3" role='' root='' prefix=''
  mapped_output=''
  if [[ "${legacy}" == N ]]; then
    case "${member}" in wallets|pools|assets|wallets/*|pools/*|assets/*) mapped_output="${member}"; return 0 ;; *) return 1 ;; esac
  fi
  # Legacy tar removed the leading slash from absolute source paths. Accept
  # configured roots, plus the standard priv/{wallet,pool,asset} layout from
  # a different deployment; never reinterpret arbitrary archive paths.
  for role in wallets pools assets; do
    cntools_backup_role_root_into root "${role}" || return 1
    prefix="${root#/}"
    if [[ "${member}" == "${prefix}/"* ]]; then mapped_output="${role}/${member#"${prefix}/"}"; return 0; fi
    case "${role}:${member}" in
      wallets:*/priv/wallet/*) mapped_output="wallets/${member#*/priv/wallet/}"; return 0 ;;
      pools:*/priv/pool/*) mapped_output="pools/${member#*/priv/pool/}"; return 0 ;;
      assets:*/priv/asset/*) mapped_output="assets/${member#*/priv/asset/}"; return 0 ;;
    esac
  done
  return 1
}

cntools_backup_restore_prepare() {
  local source="$1" password="${2:-}" archive='' binary='' legacy=Y member='' mapped='' role='' relative='' object='' target='' hash='' expected='' manifest=''
  local -A paths=() objects=() expected_hashes=()
  CNTOOLS_BACKUP_OBJECTS=(); CNTOOLS_BACKUP_KIND=legacy; CNTOOLS_BACKUP_NETWORK=unknown
  cntools_backup_environment || return 1
  cntools_transaction_file_safe "${source}" "${CNTOOLS_BACKUP_MAX_BYTES}" || {
    cntools_backup_error 'Select a regular, readable backup file with no linked path components.'; return 1;
  }
  archive="${CNTOOLS_BACKUP_WORK}/input.tar.gz"
  # A private immutable-to-the-caller copy isolates preview/import from later
  # replacement of the original. The original encrypted archive stays intact.
  cntools_backup_command cp -- "${source}" "${CNTOOLS_BACKUP_WORK}/input" || return 1
  chmod 0600 -- "${CNTOOLS_BACKUP_WORK}/input" || return 1
  if [[ "${source}" == *.gpg ]]; then
    binary="$(type -P gpg || type -P gpg2)" || { cntools_backup_error 'Install GnuPG to open this backup.'; return 1; }
    : > "${archive}"
    cntools_backup_crypto "${binary}" decrypt "${CNTOOLS_BACKUP_WORK}/input" "${archive}" "${password}" || {
      cntools_backup_error 'The backup could not be decrypted. Check the password and GPG installation.'; return 1;
    }
  else
    cntools_backup_command mv -- "${CNTOOLS_BACKUP_WORK}/input" "${archive}" || return 1
  fi
  cntools_backup_archive_index "${archive}" || {
    [[ -n "${CNTOOLS_BACKUP_ERROR}" ]] || cntools_backup_error 'The backup contains unsupported archive entries.'; return 1;
  }
  if [[ -v 'CNTOOLS_BACKUP_SIZES[manifest.json]' ]]; then
    legacy=N
    (( ${CNTOOLS_BACKUP_SIZES[manifest.json]} <= 8388608 )) || return 1
    cntools_backup_payload "${archive}" manifest.json "${CNTOOLS_BACKUP_WORK}/manifest.json" || return 1
    manifest="${CNTOOLS_BACKUP_WORK}/manifest.json"
    jq -e 'type=="object" and .schema=="org.cardano-community.cntools.backup" and .version==1 and
      (.kind=="full" or .kind=="public") and (.network|type=="string") and (.network|test("^[a-zA-Z0-9_-]+$")) and
      (.files|type=="array" and length>0 and all(.[]; (.path|type=="string") and (.sha256|type=="string" and test("^[0-9a-f]{64}$")))) and
      ([.files[].path]|length== (unique|length))' "${manifest}" >/dev/null || {
      cntools_backup_error 'Backup manifest is invalid.'; return 1;
    }
    CNTOOLS_BACKUP_KIND="$(jq -r .kind "${manifest}")"; CNTOOLS_BACKUP_NETWORK="$(jq -r .network "${manifest}")"
    (( $(jq '.files|length' "${manifest}") == ${#CNTOOLS_BACKUP_FILES[@]}-1 )) || return 1
    jq -r '.files[] | [.path,.sha256] | @tsv' "${manifest}" > "${CNTOOLS_BACKUP_WORK}/manifest-records" || return 1
    while IFS=$'\t' read -r member hash; do
      cntools_backup_member_valid "${member}" && [[ "${member}" != */ ]] || return 1
      expected_hashes["${member}"]="${hash}"
    done < "${CNTOOLS_BACKUP_WORK}/manifest-records"
  fi
  cntools_backup_archive_unpack "${archive}" || {
    cntools_backup_error 'The validated archive could not be unpacked safely into private staging.'; return 1;
  }
  mkdir -m 0700 -- "${CNTOOLS_BACKUP_WORK}/restore" || return 1
  for member in "${CNTOOLS_BACKUP_MEMBERS[@]}"; do
    [[ "${member}" != manifest.json || "${legacy}" == Y ]] || continue
    cntools_backup_restore_path_into mapped "${member}" "${legacy}" && cntools_backup_member_valid "${mapped}" || {
      cntools_backup_error 'Archive paths are outside the supported wallet, pool and asset backup layout.'; return 1;
    }
    [[ ! -v 'paths[$mapped]' ]] || return 1
    paths["${mapped}"]=1
    role="${mapped%%/*}"; relative="${mapped#*/}"
    if [[ "${mapped}" != "${role}" ]]; then
      [[ "${relative}" == */* || "${member}" == */ ]] || return 1
      object="${role}/${relative%%/*}"; objects["${object}"]=1
    fi
    target="${CNTOOLS_BACKUP_WORK}/restore/${mapped}"
    if [[ "${member}" == */ ]]; then (umask 077; mkdir -p -- "${target}") || return 1; continue; fi
    (umask 077; mkdir -p -- "${target%/*}") || return 1
    cntools_backup_payload "${archive}" "${member}" "${target}" || return 1
    if [[ "${legacy}" == N ]]; then
      expected="${expected_hashes[${member}]:-}"
      cntools_backup_hash_into hash "${target}" && [[ "${hash}" == "${expected}" ]] || {
        cntools_backup_error 'Backup checksum validation failed. No live data was changed.'; return 1;
      }
    fi
  done
  (( ${#objects[@]} > 0 )) || return 1
  if [[ "${legacy}" == N ]]; then
    cntools_backup_command cp -- "${manifest}" "${CNTOOLS_BACKUP_WORK}/restore/manifest.json" || return 1
  fi
  mapfile -t CNTOOLS_BACKUP_OBJECTS < <(printf '%s\n' "${!objects[@]}" | LC_ALL=C sort)
  cntools_log BACKUP "validated restore kind=${CNTOOLS_BACKUP_KIND} network=${CNTOOLS_BACKUP_NETWORK} objects=${#CNTOOLS_BACKUP_OBJECTS[@]}" || true
}

cntools_backup_restore_apply() {
  local object='' root='' name='' source='' stage='' recovery='' target=''
  CNTOOLS_BACKUP_IMPORTED=0; CNTOOLS_BACKUP_SKIPPED=0
  [[ -d "${CNTOOLS_BACKUP_WORK}/restore" && ${#CNTOOLS_BACKUP_OBJECTS[@]} -gt 0 ]] || return 1
  # Check all destinations before importing the first object. Empty missing
  # roots may be created, but an unsafe later root cannot cause a partial plan.
  for object in "${CNTOOLS_BACKUP_OBJECTS[@]}"; do
    cntools_backup_role_root_into root "${object%%/*}" || return 1
    if [[ -e "${root}" || -L "${root}" ]]; then
      cntools_backup_directory_safe "${root}" || {
        cntools_backup_error 'A restore destination is linked, unowned or writable by another user. Nothing was imported.'; return 1;
      }
    else
      cntools_backup_directory_safe "${root%/*}" || {
        cntools_backup_error 'The parent of a missing restore root must already exist and be owned, writable and safe.'; return 1;
      }
    fi
  done
  # Preserve a complete recovery copy, including conflicts and hidden KES
  # handoff/rotation archives, before importing anything into live data.
  recovery="${CNTOOLS_NODE_HOME}/backups"
  cntools_backup_directory_safe "${CNTOOLS_NODE_HOME}" || return 1
  if [[ ! -e "${recovery}" && ! -L "${recovery}" ]]; then mkdir -m 0700 -- "${recovery}" || return 1; fi
  cntools_backup_directory_safe "${recovery}" || return 1
  target="${recovery}/restored-${CNTOOLS_BACKUP_WORK##*.}"
  stage="$(umask 077; mktemp -d "${recovery}/.cntools-restore.XXXXXXXX")" || return 1
  CNTOOLS_BACKUP_STAGES+=("${stage}")
  if ! cntools_backup_command cp -R -- "${CNTOOLS_BACKUP_WORK}/restore/." "${stage}/" || ! cntools_backup_publish "${stage}" "${target}"; then
    rm -rf -- "${stage}"; return 1
  fi
  CNTOOLS_BACKUP_RESULT="${target}"
  for object in "${CNTOOLS_BACKUP_OBJECTS[@]}"; do
    name="${object#*/}"
    # Recovery locks and hidden KES work contain absolute-path intent and must
    # never be activated automatically on a new/different node.
    if [[ "${name}" == .* || -e "${target}/${object}/.cntools-opcert-lock" ]]; then
      CNTOOLS_BACKUP_SKIPPED=$((CNTOOLS_BACKUP_SKIPPED+1)); continue
    fi
    cntools_backup_role_root_into root "${object%%/*}" || return 1
    if [[ ! -e "${root}" && ! -L "${root}" ]]; then
      cntools_backup_directory_safe "${root%/*}" && mkdir -m 0700 -- "${root}" || return 1
    fi
    cntools_backup_directory_safe "${root}" || return 1
    if [[ -e "${root}/${name}" || -L "${root}/${name}" ]]; then
      CNTOOLS_BACKUP_SKIPPED=$((CNTOOLS_BACKUP_SKIPPED+1)); continue
    fi
    source="${target}/${object}"
    [[ -d "${source}" && ! -L "${source}" ]] || return 1
    stage="$(umask 077; mktemp -d "${root}/.cntools-restore.XXXXXXXX")" || return 1
    CNTOOLS_BACKUP_STAGES+=("${stage}")
    if ! cntools_backup_command cp -R -- "${source}/." "${stage}/" || ! cntools_backup_publish "${stage}" "${root}/${name}"; then
      rm -rf -- "${stage}"; cntools_backup_error 'Restore stopped before an unsafe overwrite. Already imported folders and the recovery copy were retained.'; return 1
    fi
    CNTOOLS_BACKUP_IMPORTED=$((CNTOOLS_BACKUP_IMPORTED+1))
    cntools_log BACKUP "imported ${object}" || true
  done
  cntools_log BACKUP "restore imported=${CNTOOLS_BACKUP_IMPORTED} skipped=${CNTOOLS_BACKUP_SKIPPED} recovery=${CNTOOLS_BACKUP_RESULT}" || true
}
