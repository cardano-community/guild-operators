#!/usr/bin/env bash
# Explicit, guarded key deletion. No recursion, glob deletion or backup copies.
# shellcheck disable=SC2034,SC2015
declare -ag CNTOOLS_PRIVATE_KEY_FILES=() CNTOOLS_PRIVATE_KEY_STAMPS=() CNTOOLS_PRIVATE_KEY_LABELS=()
declare -ag CNTOOLS_PRIVATE_KEY_UNLOCKED=()
declare -ag CNTOOLS_PRIVATE_KEY_PUBLIC_FILES=() CNTOOLS_PRIVATE_KEY_PUBLIC_STAMPS=()
CNTOOLS_PRIVATE_KEY_PUBLIC_FILE=''
CNTOOLS_PRIVATE_KEY_REMOVED=0 CNTOOLS_PRIVATE_KEY_ERROR=''

cntools_private_keys_fail() {
  CNTOOLS_PRIVATE_KEY_ERROR="$1"; cntools_log ERROR "$1" || true; return 1;
}

cntools_private_key_stamp_into() {
  local -n pk_stamp="$1"
  local pk_path="$2" pk_stat='' pk_digest='' pk_links=''
  cntools_transaction_file_safe "${pk_path}" 65536 && [[ -O "${pk_path}" ]] &&
    cntools_transaction_directory_safe "${pk_path%/*}" || return 1
  pk_stat="$(stat -c '%d:%i:%h:%s' -- "${pk_path}" 2>/dev/null || stat -f '%d:%i:%l:%z' "${pk_path}" 2>/dev/null)" || return 1
  [[ "${pk_stat}" =~ ^[0-9]+:[0-9]+:1:[0-9]+$ ]] || return 1
  # Hashes and inode identities stay in memory. Never log private file contents.
  pk_digest="$(sha256sum -- "${pk_path}")" || return 1
  pk_digest="${pk_digest%% *}"
  [[ "${pk_digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  pk_stamp="${pk_stat}:${pk_digest}"
}

cntools_private_keys_names_into() {
  local -n pn_names="$1"
  local pn_role="$2" pn_name='' pn_prefix="${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}"
  pn_names=()
  case "${pn_role}" in
    wallets)
      pn_names=("${CNTOOLS_WALLET_PAY_SKEY_FILENAME:-payment.skey}" "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME:-stake.skey}" \
        "${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}" "${CNTOOLS_WALLET_CATALYST_SKEY_FILENAME:-catalyst.skey}" \
        "${CNTOOLS_WALLET_CC_COLD_SKEY_FILENAME:-cc-cold.skey}" "${CNTOOLS_WALLET_CC_HOT_SKEY_FILENAME:-cc-hot.skey}")
      for pn_name in "${pn_names[@]}"; do pn_names+=("${pn_prefix}${pn_name}"); done ;;
    pools) pn_names=("${CNTOOLS_POOL_COLD_SKEY_FILENAME:-cold.skey}" "${CNTOOLS_POOL_CALIDUS_SKEY_FILENAME:-calidus.skey}") ;;
    assets) pn_names=("${CNTOOLS_POLICY_SKEY_FILENAME:-policy.skey}") ;;
    *) return 2 ;;
  esac
  local -A pn_seen=()
  for pn_name in "${pn_names[@]}"; do
    [[ "${pn_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "${pn_name}" != *.gpg && "${pn_name}" != *.hwsfile && -z "${pn_seen[${pn_name}]+x}" ]] || return 1
    pn_seen["${pn_name}"]=1
    # A broken custom configuration must not select operational keys or public
    # artifacts, even when they happen to have signing-key-shaped JSON.
    local pn_variable='' pn_value=''
    for pn_variable in ${!CNTOOLS_WALLET_@} ${!CNTOOLS_POOL_@} ${!CNTOOLS_POLICY_@}; do
      [[ "${pn_variable}" == *_FILENAME ]] || continue
      if [[ "${pn_variable}" == *VKEY* || "${pn_variable}" == *_HW_* || "${pn_variable}" == *ADDR* ||
            "${pn_variable}" == *SCRIPT* || "${pn_variable}" == *CRED* || "${pn_variable}" == *KES* || "${pn_variable}" == *VRF* || "${pn_variable}" == *ID_FILENAME ]]; then
        pn_value="${!pn_variable}"
        [[ "${pn_name}" != "${pn_value}" && "${pn_name}" != "${pn_prefix}${pn_value}" ]] || return 1
      fi
    done
  done
}

cntools_private_keys_public_check() {
  local role="$1" directory="$2" name="$3" public='' derived='' response='' errors='' signing='' status=0
  CNTOOLS_PRIVATE_KEY_PUBLIC_FILE=''
  [[ "${name}" != *-bech32 ]] || {
    CNTOOLS_PRIVATE_KEY_PUBLIC_FILE="${directory}/${CNTOOLS_WALLET_CATALYST_VKEY_FILENAME:-catalyst.vkey}"
    cntools_transaction_file_safe "${directory}/${CNTOOLS_WALLET_CATALYST_VKEY_FILENAME:-catalyst.vkey}" 65536; return $?;
  }
  # Known role names are mapped explicitly, not by assuming a .skey suffix.
  if [[ "${role}" == wallets ]]; then
    local prefix='' plain="${name}"
    [[ "${plain}" != "${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}"* ]] || { prefix="${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}"; plain="${plain#"${prefix}"}"; }
    case "${plain}" in
      "${CNTOOLS_WALLET_PAY_SKEY_FILENAME:-payment.skey}") public="${prefix}${CNTOOLS_WALLET_PAY_VKEY_FILENAME:-payment.vkey}" ;;
      "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME:-stake.skey}") public="${prefix}${CNTOOLS_WALLET_STAKE_VKEY_FILENAME:-stake.vkey}" ;;
      "${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}") public="${prefix}${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}" ;;
      "${CNTOOLS_WALLET_CATALYST_SKEY_FILENAME:-catalyst.skey}") public="${prefix}${CNTOOLS_WALLET_CATALYST_VKEY_FILENAME:-catalyst.vkey}" ;;
      "${CNTOOLS_WALLET_CC_COLD_SKEY_FILENAME:-cc-cold.skey}") public="${prefix}${CNTOOLS_WALLET_CC_COLD_VKEY_FILENAME:-cc-cold.vkey}" ;;
      "${CNTOOLS_WALLET_CC_HOT_SKEY_FILENAME:-cc-hot.skey}") public="${prefix}${CNTOOLS_WALLET_CC_HOT_VKEY_FILENAME:-cc-hot.vkey}" ;;
      *) return 1 ;;
    esac
  elif [[ "${role}" == pools ]]; then
    case "${name}" in
      "${CNTOOLS_POOL_COLD_SKEY_FILENAME:-cold.skey}") public="${CNTOOLS_POOL_COLD_VKEY_FILENAME:-cold.vkey}" ;;
      "${CNTOOLS_POOL_CALIDUS_SKEY_FILENAME:-calidus.skey}") public="${CNTOOLS_POOL_CALIDUS_VKEY_FILENAME:-calidus.vkey}" ;;
      *) return 1 ;;
    esac
  else public="${CNTOOLS_POLICY_VKEY_FILENAME:-policy.vkey}"; fi
  CNTOOLS_PRIVATE_KEY_PUBLIC_FILE="${directory}/${public}"
  cntools_transaction_file_safe "${directory}/${public}" 65536 || {
    cntools_private_keys_fail "Public key missing/unsafe for ${directory##*/}/${name}. Prepare public artifacts before deleting its private key."; return 1;
  }
  # Encrypted sources cannot be paired without decryption. Require an existing
  # valid public envelope and explicit backup acknowledgement; never decrypt.
  jq -es 'length==1 and (.[0]|(.type|type=="string" and contains("VerificationKey")) and
    (.cborHex|type=="string" and test("^(5820[0-9a-fA-F]{64}|5840[0-9a-fA-F]{128})$")))' "${directory}/${public}" >/dev/null || return 1
  [[ "${4:-}" != encrypted ]] || return 0
  signing="${directory}/${name}"
  cntools_transaction_snapshot_into signing "${signing}" 65536 delete-key-validation &&
    cntools_transaction_temp_file derived delete-key-public && cntools_transaction_temp_file response delete-key-output &&
    cntools_transaction_temp_file errors delete-key-errors || return 1
  if [[ "${role}" == wallets && "${plain}" == "${CNTOOLS_WALLET_CATALYST_SKEY_FILENAME:-catalyst.skey}" ]]; then
    cntools_catalyst_pair_valid "${directory}/${name}" "${directory}/${public}"
    return $?
  fi
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" key verification-key \
    --signing-key-file "${signing}" --verification-key-file "${derived}" || status=$?
  ((status == 0)) && jq -es 'length==2 and (.[0].cborHex[4:68]|ascii_downcase)==(.[1].cborHex[4:68]|ascii_downcase)' \
    "${derived}" "${directory}/${public}" >/dev/null || {
    cntools_private_keys_fail "Private/public identity mismatch for ${directory##*/}/${name}. No keys were deleted."; return 1;
  }
}

cntools_private_keys_inventory() {
  local scope="$1" include_encrypted="$2" object="${3:-}" role='' root='' directory='' name='' file='' stamp='' public_stamp='' form='' label=''
  local -a names=() roles=()
  CNTOOLS_PRIVATE_KEY_FILES=(); CNTOOLS_PRIVATE_KEY_STAMPS=(); CNTOOLS_PRIVATE_KEY_LABELS=()
  CNTOOLS_PRIVATE_KEY_PUBLIC_FILES=(); CNTOOLS_PRIVATE_KEY_PUBLIC_STAMPS=()
  CNTOOLS_PRIVATE_KEY_ERROR=''; CNTOOLS_PRIVATE_KEY_REMOVED=0
  [[ "${include_encrypted}" == Y || "${include_encrypted}" == N ]] || return 2
  case "${scope}" in wallets|pools|assets) roles=("${scope}") ;; all) roles=(wallets pools assets) ;; *) return 2 ;; esac
  cntools_transaction_require_cli || return 1
  for role in "${roles[@]}"; do
    case "${role}" in wallets) root="${CNTOOLS_WALLET_DIR:-}" ;; pools) root="${CNTOOLS_POOL_DIR:-}" ;; assets) root="${CNTOOLS_ASSET_DIR:-}" ;; esac
    [[ -n "${root}" && "${root}" == /* && "${root}" != / && "${root}" != "${HOME}" && "${root}" != "${CNTOOLS_NODE_HOME:-}" ]] || return 1
    [[ -e "${root}" || -L "${root}" ]] || continue
    cntools_transaction_directory_safe "${root}" && cntools_private_keys_names_into names "${role}" || return 1
    for directory in "${root}"/*; do
      [[ -e "${directory}" || -L "${directory}" ]] || continue
      [[ -z "${object}" || "${directory##*/}" == "${object}" ]] || continue
      # Stray files and odd names are not objects; skip them as the catalogs do.
      if [[ ! -d "${directory}" || -L "${directory}" || ! "${directory##*/}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        cntools_log KEYS "Key deletion inventory skipped non-object entry=${directory}" || true
        continue
      fi
      cntools_transaction_directory_safe "${directory}" || {
        cntools_private_keys_fail "Unsafe folder: ${directory} (it must be owned by you and not group/world-writable). No keys were deleted."; return 1;
      }
      local -a candidates=("${names[@]}")
      [[ "${role}" != wallets ]] || candidates+=("${CNTOOLS_WALLET_CATALYST_SKEY_FILENAME:-catalyst.skey}-bech32")
      for name in "${candidates[@]}"; do
        for form in clear encrypted; do
          [[ "${form}" != encrypted || "${include_encrypted}" == Y ]] || continue
          file="${directory}/${name}"; [[ "${form}" != encrypted ]] || file+=.gpg
          [[ -e "${file}" || -L "${file}" ]] || continue
          cntools_private_key_stamp_into stamp "${file}" && cntools_private_keys_public_check "${role}" "${directory}" "${name}" "${form}" &&
            cntools_private_key_stamp_into public_stamp "${CNTOOLS_PRIVATE_KEY_PUBLIC_FILE}" || {
            [[ -n "${CNTOOLS_PRIVATE_KEY_ERROR}" ]] || cntools_private_keys_fail "Unsafe, linked or invalid key: ${file}. No keys were deleted."
            return 1;
          }
          CNTOOLS_PRIVATE_KEY_FILES+=("${file}"); CNTOOLS_PRIVATE_KEY_STAMPS+=("${stamp}")
          CNTOOLS_PRIVATE_KEY_PUBLIC_FILES+=("${CNTOOLS_PRIVATE_KEY_PUBLIC_FILE}"); CNTOOLS_PRIVATE_KEY_PUBLIC_STAMPS+=("${public_stamp}")
          case "${role}" in wallets) label=Wallet ;; pools) label=Pool ;; *) label=Policy ;; esac
          CNTOOLS_PRIVATE_KEY_LABELS+=("${label} ${directory##*/}")
        done
      done
    done
  done
}

# Object folders of a category (wallets, pools or assets) holding deletable
# key files, plain or encrypted, with a file count each; others are left out.
cntools_private_keys_objects_into() {
  local -n po_objects="$1" po_counts="$2"
  local po_role="$3" po_root='' po_directory='' po_name='' po_count=0
  local -a po_names=()
  po_objects=(); po_counts=()
  case "${po_role}" in wallets) po_root="${CNTOOLS_WALLET_DIR:-}" ;; pools) po_root="${CNTOOLS_POOL_DIR:-}" ;; assets) po_root="${CNTOOLS_ASSET_DIR:-}" ;; *) return 2 ;; esac
  [[ -n "${po_root}" && -d "${po_root}" && ! -L "${po_root}" ]] || return 0
  cntools_private_keys_names_into po_names "${po_role}" || return 1
  [[ "${po_role}" != wallets ]] || po_names+=("${CNTOOLS_WALLET_CATALYST_SKEY_FILENAME:-catalyst.skey}-bech32")
  for po_directory in "${po_root}"/*; do
    [[ -d "${po_directory}" && ! -L "${po_directory}" && "${po_directory##*/}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
    po_count=0
    for po_name in "${po_names[@]}" "${po_names[@]/%/.gpg}"; do
      [[ ! -e "${po_directory}/${po_name}" && ! -L "${po_directory}/${po_name}" ]] || po_count=$((po_count+1))
    done
    (( po_count > 0 )) || continue
    po_objects+=("${po_directory##*/}"); po_counts+=("${po_count}")
  done
}

# Plaintext and encrypted (.gpg) deletable key files in scope, counted apart.
cntools_private_keys_form_counts_into() {
  local -n pf_plain="$1" pf_encrypted="$2"
  local pf_scope="$3" pf_object="${4:-}" pf_role='' pf_root='' pf_directory='' pf_name=''
  local -a pf_roles=() pf_names=()
  pf_plain=0; pf_encrypted=0
  case "${pf_scope}" in wallets|pools|assets) pf_roles=("${pf_scope}") ;; all) pf_roles=(wallets pools assets) ;; *) return 2 ;; esac
  for pf_role in "${pf_roles[@]}"; do
    case "${pf_role}" in wallets) pf_root="${CNTOOLS_WALLET_DIR:-}" ;; pools) pf_root="${CNTOOLS_POOL_DIR:-}" ;; assets) pf_root="${CNTOOLS_ASSET_DIR:-}" ;; esac
    [[ -n "${pf_root}" && -d "${pf_root}" && ! -L "${pf_root}" ]] || continue
    cntools_private_keys_names_into pf_names "${pf_role}" || return 1
    [[ "${pf_role}" != wallets ]] || pf_names+=("${CNTOOLS_WALLET_CATALYST_SKEY_FILENAME:-catalyst.skey}-bech32")
    for pf_directory in "${pf_root}"/*; do
      [[ -d "${pf_directory}" && ! -L "${pf_directory}" && "${pf_directory##*/}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
      [[ -z "${pf_object}" || "${pf_directory##*/}" == "${pf_object}" ]] || continue
      for pf_name in "${pf_names[@]}"; do
        [[ ! -e "${pf_directory}/${pf_name}" && ! -L "${pf_directory}/${pf_name}" ]] || pf_plain=$((pf_plain + 1))
        [[ ! -e "${pf_directory}/${pf_name}.gpg" && ! -L "${pf_directory}/${pf_name}.gpg" ]] || pf_encrypted=$((pf_encrypted + 1))
      done
    done
  done
}

cntools_private_keys_restore_locks() {
  local file='' index='' stamp='' unchanged=N
  for file in "${CNTOOLS_PRIVATE_KEY_UNLOCKED[@]}"; do
    [[ -e "${file}" || -L "${file}" ]] || continue
    unchanged=N
    for index in "${!CNTOOLS_PRIVATE_KEY_FILES[@]}"; do
      [[ "${CNTOOLS_PRIVATE_KEY_FILES[index]}" == "${file}" ]] || continue
      if cntools_private_key_stamp_into stamp "${file}" && [[ "${stamp}" == "${CNTOOLS_PRIVATE_KEY_STAMPS[index]}" ]]; then unchanged=Y; fi
      break
    done
    if [[ "${unchanged}" != Y ]]; then
      cntools_log ERROR "Immutable protection not restored on a replaced or changed path: ${file}" || true
      continue
    fi
    cntools_wallet_protection_chattr_run +i "${file}" || {
      cntools_log ERROR "Could not restore immutable protection: ${file}" || true;
    }
  done
  CNTOOLS_PRIVATE_KEY_UNLOCKED=()
}

# Before the confirmation: every listed key that is immutable must be
# unlockable without a sudo password. All blocked folders are named at once.
cntools_private_keys_unlock_ready() {
  local file='' folder='' seen=''
  local -a blocked=()
  for file in "${CNTOOLS_PRIVATE_KEY_FILES[@]}"; do
    cntools_wallet_protection_unlock_ready "${file%/*}" "${file}" && continue
    for folder in "${blocked[@]}"; do [[ "${folder}" != "${file%/*}" ]] || seen=Y; done
    [[ "${seen}" == Y ]] || blocked+=("${file%/*}")
    seen=''
  done
  (( ${#blocked[@]} == 0 )) && return 0
  CNTOOLS_PRIVATE_KEY_ERROR="$(cntools_wallet_immutable_remedy "${blocked[@]}")"
  cntools_log ERROR "${CNTOOLS_PRIVATE_KEY_ERROR}" || true
  return 1
}

cntools_private_keys_delete() {
  local acknowledgement="$1" index=0 file='' stamp='' directory='' attributes='' lsattr='' has_immutable=N
  CNTOOLS_PRIVATE_KEY_REMOVED=0
  [[ "${acknowledgement}" == 'DELETE PRIVATE KEYS' && ${#CNTOOLS_PRIVATE_KEY_FILES[@]} -gt 0 &&
    ${#CNTOOLS_PRIVATE_KEY_FILES[@]} == "${#CNTOOLS_PRIVATE_KEY_STAMPS[@]}" &&
    ${#CNTOOLS_PRIVATE_KEY_FILES[@]} == "${#CNTOOLS_PRIVATE_KEY_PUBLIC_FILES[@]}" &&
    ${#CNTOOLS_PRIVATE_KEY_FILES[@]} == "${#CNTOOLS_PRIVATE_KEY_PUBLIC_STAMPS[@]}" ]] || return 2
  # All inputs must still be exactly the previewed files before the first unlink.
  for index in "${!CNTOOLS_PRIVATE_KEY_FILES[@]}"; do
    cntools_private_key_stamp_into stamp "${CNTOOLS_PRIVATE_KEY_FILES[index]}" && [[ "${stamp}" == "${CNTOOLS_PRIVATE_KEY_STAMPS[index]}" ]] || {
      cntools_private_keys_fail 'The previewed key set changed. Nothing was deleted; reopen this action.'; return 1;
    }
    cntools_private_key_stamp_into stamp "${CNTOOLS_PRIVATE_KEY_PUBLIC_FILES[index]}" && [[ "${stamp}" == "${CNTOOLS_PRIVATE_KEY_PUBLIC_STAMPS[index]}" ]] || {
      cntools_private_keys_fail 'A retained public key changed. Nothing was deleted; reopen this action.'; return 1;
    }
  done
  # Each listed key is checked for the immutable flag itself: wallet, pool and
  # policy folders alike. Encrypted keys are read-only: rm -f, so rm never asks
  # inside the TUI, and a key counts as removed only once it is really gone.
  cntools_wallet_protection_resolve_command_into lsattr lsattr || lsattr=''
  for index in "${!CNTOOLS_PRIVATE_KEY_FILES[@]}"; do
    file="${CNTOOLS_PRIVATE_KEY_FILES[index]}"; directory="${file%/*}"
    has_immutable=N
    if [[ -n "${lsattr}" ]]; then
      # A filesystem without attributes makes lsattr fail: nothing to unlock.
      attributes="$(cntools_run_command 0000 -- "${lsattr}" -d -- "${file}" 2>/dev/null || true)"
      [[ "${attributes%% *}" != *i* ]] || has_immutable=Y
    fi
    if [[ "${has_immutable}" == Y ]]; then
      if ! cntools_wallet_protection_chattr_prepare "${directory}" || ! cntools_wallet_protection_chattr_run -i "${file}"; then
        cntools_private_keys_restore_locks
        cntools_private_keys_fail "Could not unlock ${file}. Removed ${CNTOOLS_PRIVATE_KEY_REMOVED} keys; remaining keys were retained."; return 1
      fi
      CNTOOLS_PRIVATE_KEY_UNLOCKED+=("${file}")
    fi
    if ! cntools_private_key_stamp_into stamp "${file}" || [[ "${stamp}" != "${CNTOOLS_PRIVATE_KEY_STAMPS[index]}" ]] ||
       ! cntools_private_key_stamp_into stamp "${CNTOOLS_PRIVATE_KEY_PUBLIC_FILES[index]}" || [[ "${stamp}" != "${CNTOOLS_PRIVATE_KEY_PUBLIC_STAMPS[index]}" ]] ||
       ! cntools_run_command 0000 -- rm -f -- "${file}" || [[ -e "${file}" || -L "${file}" ]]; then
      cntools_private_keys_restore_locks
      cntools_private_keys_fail "Deletion stopped at ${file}. Removed ${CNTOOLS_PRIVATE_KEY_REMOVED} keys; remaining keys were retained."; return 1
    fi
    CNTOOLS_PRIVATE_KEY_REMOVED=$((CNTOOLS_PRIVATE_KEY_REMOVED+1))
    cntools_log KEYS "Removed private key file=${file}; public and operational artifacts retained" || true
  done
  cntools_private_keys_restore_locks
}
