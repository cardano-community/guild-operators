#!/usr/bin/env bash
# Catalyst voting identities. Private material never travels through logs/argv.
# shellcheck disable=SC2034,SC2015
CNTOOLS_CATALYST_PUBLIC='' CNTOOLS_CATALYST_DIRECTORY=''
declare -ag CNTOOLS_CATALYST_LINK_SOURCES=() CNTOOLS_CATALYST_LINK_TARGETS=()

cntools_catalyst_fail() { cntools_transaction_set_error "$1"; return 1; }

cntools_catalyst_names_into() {
  local -n ck_names="$1"
  local ck_name='' ck_public='' ck_variable='' ck_prefix="${CNTOOLS_WALLET_MULTISIG_PREFIX:-ms_}"
  ck_names=("${CNTOOLS_WALLET_CATALYST_SKEY_FILENAME:-catalyst.skey}" "${CNTOOLS_WALLET_CATALYST_VKEY_FILENAME:-catalyst.vkey}" "${CNTOOLS_CATALYST_QR_FILENAME:-catalyst-qrcode.png}")
  local -A ck_seen=()
  for ck_name in "${ck_names[@]}"; do
    [[ "${ck_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "${ck_name}" != *.gpg && -z "${ck_seen[${ck_name}]+x}" ]] || return 1
    ck_seen["${ck_name}"]=1
    for ck_public in "${CNTOOLS_WALLET_PAY_SKEY_FILENAME:-payment.skey}" "${CNTOOLS_WALLET_STAKE_SKEY_FILENAME:-stake.skey}" \
      "${CNTOOLS_WALLET_PAY_VKEY_FILENAME:-payment.vkey}" "${CNTOOLS_WALLET_STAKE_VKEY_FILENAME:-stake.vkey}" \
      "${CNTOOLS_WALLET_DREP_SKEY_FILENAME:-drep.skey}" "${CNTOOLS_WALLET_DREP_VKEY_FILENAME:-drep.vkey}"; do
      [[ "${ck_name}" != "${ck_public}" ]] || return 1
    done
    for ck_variable in ${!CNTOOLS_WALLET_@}; do
      [[ "${ck_variable}" == *_FILENAME && "${ck_variable}" != CNTOOLS_WALLET_CATALYST_SKEY_FILENAME &&
         "${ck_variable}" != CNTOOLS_WALLET_CATALYST_VKEY_FILENAME ]] || continue
      ck_public="${!ck_variable}"
      [[ "${ck_name}" != "${ck_public}" && "${ck_name}" != "${ck_prefix}${ck_public}" ]] || return 1
    done
  done
}

cntools_catalyst_signer_require() {
  local response='' errors='' version='' status=0
  [[ -n "${CNTOOLS_CARDANO_SIGNER:-}" ]] || CNTOOLS_CARDANO_SIGNER="$(type -P cardano-signer || true)"
  [[ -f "${CNTOOLS_CARDANO_SIGNER}" && -x "${CNTOOLS_CARDANO_SIGNER}" ]] || {
    cntools_catalyst_fail 'Cardano Signer is required for Catalyst key generation and metadata verification. Install it using Guild Deploy.'; return 1;
  }
  cntools_transaction_temp_file response catalyst-version && cntools_transaction_temp_file errors catalyst-version-errors || return 1
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CARDANO_SIGNER}" --version || status=$?
  version="$(< "${response}")"
  ((status == 0)) && [[ "${version}" =~ ^cardano-signer[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] &&
    ((BASH_REMATCH[1] > 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] >= 24))) || {
    cntools_catalyst_fail 'Cardano Signer 1.24.0 or newer is required.'; return 1;
  }
}

cntools_catalyst_public_into() {
  local -n ck_output="$1"
  ck_output=''
  cntools_transaction_file_safe "$2" 65536 || return 1
  ck_output="$(jq -ers 'length==1 and (.[0]|.type=="CIP36VoteVerificationKey_ed25519" and (.cborHex|test("^5820[0-9a-fA-F]{64}$")))' "$2" >/dev/null && jq -r '.cborHex[4:]|ascii_downcase' "$2")" || return 1
}

cntools_catalyst_private_public_into() {
  local -n cp_output="$1"
  local signing="$2" normalized='' derived='' errors='' status=0
  cp_output=''
  cntools_transaction_private_file_safe "${signing}" &&
    jq -es 'length==1 and (.[0]|.type=="CIP36VoteExtendedSigningKey_ed25519" and (.cborHex|test("^5880[0-9a-fA-F]{256}$")))' "${signing}" >/dev/null || return 1
  cntools_transaction_temp_file normalized catalyst-key-normalized && cntools_transaction_temp_file derived catalyst-key-derived &&
    cntools_transaction_temp_file errors catalyst-key-errors || return 1
  # Same ed25519-bip32 bytes, staging-only role conversion understood by CLI.
  jq '.type="PaymentExtendedSigningKeyShelley_ed25519_bip32"' "${signing}" > "${normalized}" || return 1
  cntools_transaction_run_cli "${derived}" "${errors}" -- "${CNTOOLS_CLI}" key verification-key \
    --signing-key-file "${normalized}" --verification-key-file "${derived}" || status=$?
  ((status == 0)) || return 1
  cp_output="$(jq -er '.cborHex[4:68]|ascii_downcase' "${derived}")" || return 1
  [[ "${cp_output}" =~ ^[0-9a-f]{64}$ ]]
}

cntools_catalyst_pair_valid() {
  local public='' derived_public=''
  cntools_catalyst_public_into public "$2" && cntools_catalyst_private_public_into derived_public "$1" &&
    [[ "${derived_public}" == "${public}" ]]
}

cntools_catalyst_cleanup() {
  local index=0
  for index in "${!CNTOOLS_CATALYST_LINK_TARGETS[@]}"; do
    [[ ! -L "${CNTOOLS_CATALYST_LINK_TARGETS[index]}" && "${CNTOOLS_CATALYST_LINK_TARGETS[index]}" -ef "${CNTOOLS_CATALYST_LINK_SOURCES[index]}" ]] || continue
    rm -f -- "${CNTOOLS_CATALYST_LINK_TARGETS[index]}" || true
  done
  CNTOOLS_CATALYST_LINK_TARGETS=(); CNTOOLS_CATALYST_LINK_SOURCES=()
  cntools_wallet_material_cleanup
  cntools_transaction_cleanup
}

cntools_catalyst_keys_prepare() {
  local directory="$1" signing='' verification='' index=0 response='' errors='' status=0
  local -a names=()
  CNTOOLS_CATALYST_PUBLIC=''; CNTOOLS_CATALYST_DIRECTORY="${directory}"
  cntools_catalyst_names_into names && cntools_transaction_directory_safe "${directory}" &&
    cntools_wallet_directory_safe "${directory}" && cntools_transaction_require_cli || return 1
  signing="${directory}/${names[0]}"; verification="${directory}/${names[1]}"
  if [[ -e "${verification}" || -L "${verification}" ]]; then
    cntools_catalyst_public_into CNTOOLS_CATALYST_PUBLIC "${verification}" || {
      cntools_catalyst_fail 'The existing Catalyst public key is invalid. No files were replaced.'; return 1;
    }
    if [[ -e "${signing}" || -L "${signing}" ]]; then
      cntools_catalyst_pair_valid "${signing}" "${verification}" || {
        cntools_catalyst_fail 'The Catalyst signing/public keys do not match. No files were replaced.'; return 1;
      }
    fi
    return 0
  fi
  if [[ -e "${signing}" || -L "${signing}" ]]; then
    local repaired='' public_hex=''
    [[ ! -e "${signing}.gpg" && ! -L "${signing}.gpg" ]] &&
      cntools_catalyst_private_public_into public_hex "${signing}" &&
      cntools_wallet_material_temp_file repaired "${directory}" catalyst-public-repair || {
      cntools_catalyst_fail 'The existing Catalyst private key cannot safely restore its public key. No replacement identity was generated.'; return 1;
    }
    jq -n --arg key "5820${public_hex}" '{type:"CIP36VoteVerificationKey_ed25519",description:"Catalyst Vote Verification Key",cborHex:$key}' > "${repaired}" || return 1
    cntools_catalyst_pair_valid "${signing}" "${repaired}" && ln -- "${repaired}" "${verification}" || return 1
    cntools_log CATALYST "Restored missing voting public key wallet=${directory##*/}; existing private identity retained" || true
    cntools_catalyst_public_into CNTOOLS_CATALYST_PUBLIC "${verification}"
    return $?
  fi
  [[ ! -e "${signing}.gpg" && ! -L "${signing}.gpg" ]] || {
    cntools_catalyst_fail 'Incomplete Catalyst key material exists. Restore its public key from backup; no replacement key was generated.'; return 1;
  }
  [[ "${2:-}" == create ]] || { cntools_catalyst_fail 'No Catalyst public key exists for this wallet.'; return 1; }
  cntools_catalyst_signer_require && cntools_wallet_material_temp_file signing "${directory}" catalyst-signing &&
    cntools_wallet_material_temp_file verification "${directory}" catalyst-verification &&
    cntools_transaction_temp_file response catalyst-key-output && cntools_transaction_temp_file errors catalyst-key-errors || return 1
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CARDANO_SIGNER}" keygen --cip36 \
    --out-skey "${signing}" --out-vkey "${verification}" || status=$?
  # Keygen stdout may contain secrets. Never report its diagnostic contents.
  ((status == 0)) && chmod 0600 -- "${signing}" "${verification}" && cntools_catalyst_pair_valid "${signing}" "${verification}" || {
    cntools_catalyst_fail "Catalyst key generation/validation failed (status ${status}). Existing files were retained."; return 1;
  }
  local -a sources=("${signing}" "${verification}")
  for index in 0 1; do
    CNTOOLS_CATALYST_LINK_SOURCES+=("${sources[index]}"); CNTOOLS_CATALYST_LINK_TARGETS+=("${directory}/${names[index]}")
    ln -- "${sources[index]}" "${directory}/${names[index]}" || return 1
  done
  CNTOOLS_CATALYST_LINK_SOURCES=(); CNTOOLS_CATALYST_LINK_TARGETS=()
  cntools_catalyst_public_into CNTOOLS_CATALYST_PUBLIC "${directory}/${names[1]}"
}
