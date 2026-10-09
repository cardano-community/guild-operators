#!/usr/bin/env bash
# CIP-151 (CIP-88 v2) authorization and Koios nonce lookup. No transaction I/O.
# shellcheck disable=SC2034,SC2015
CNTOOLS_CALIDUS_REG_DIRECTORY='' CNTOOLS_CALIDUS_REG_POOL='' CNTOOLS_CALIDUS_REG_HEX=''
CNTOOLS_CALIDUS_REG_COLD='' CNTOOLS_CALIDUS_REG_PUBLIC='' CNTOOLS_CALIDUS_REG_ID=''
CNTOOLS_CALIDUS_REG_METADATA='' CNTOOLS_CALIDUS_REG_NONCE=''
CNTOOLS_CALIDUS_OPERATION=register
CNTOOLS_CALIDUS_CHAIN_STATE='' CNTOOLS_CALIDUS_CHAIN_NONCE='' CNTOOLS_CALIDUS_CHAIN_PUBLIC=''
CNTOOLS_CALIDUS_CHAIN_ID='' CNTOOLS_CALIDUS_CHAIN_TX='' CNTOOLS_CALIDUS_CHAIN_STATUS='Not checked'

cntools_calidus_registration_fail() { cntools_transaction_set_error "$1"; return 1; }

cntools_calidus_registration_directory_safe() {
  [[ -d "${CNTOOLS_CALIDUS_REG_DIRECTORY}" && ! -L "${CNTOOLS_CALIDUS_REG_DIRECTORY}" && -O "${CNTOOLS_CALIDUS_REG_DIRECTORY}" ]] &&
    cntools_transaction_path_components_safe "${CNTOOLS_CALIDUS_REG_DIRECTORY}" &&
    cntools_transaction_directory_ancestry_safe "${CNTOOLS_CALIDUS_REG_DIRECTORY}" || {
    cntools_calidus_registration_fail 'The pool directory is unsafe. No authorization was prepared.'; return 1;
  }
}

cntools_calidus_signer_require() {
  local version='' response='' errors='' status=0
  if [[ -z "${CNTOOLS_CARDANO_SIGNER:-}" ]]; then CNTOOLS_CARDANO_SIGNER="$(type -P cardano-signer || true)"; fi
  [[ -n "${CNTOOLS_CARDANO_SIGNER}" && -f "${CNTOOLS_CARDANO_SIGNER}" && -x "${CNTOOLS_CARDANO_SIGNER}" ]] || {
    cntools_calidus_registration_fail 'Cardano Signer is required to authorize and verify Calidus registration metadata. Install it using Guild Deploy.'; return 1;
  }
  cntools_transaction_temp_file response calidus-signer-version && cntools_transaction_temp_file errors calidus-signer-errors || return 1
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CARDANO_SIGNER}" --version || status=$?
  version="$(< "${response}")"
  if ((status != 0)) || [[ ! "${version}" =~ ^cardano-signer[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] ||
      (( BASH_REMATCH[1] < 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] < 24) )); then
    cntools_calidus_registration_fail 'Cardano Signer 1.24.0 or newer is required for Calidus authorization.'; return 1
  fi
}

cntools_calidus_registration_identity() {
  local index="$1" cold='' frozen='' derived_pool='' derived_hex='' response='' errors='' status=0
  CNTOOLS_CALIDUS_REG_METADATA='' CNTOOLS_CALIDUS_REG_NONCE=''
  CNTOOLS_CALIDUS_REG_PUBLIC='' CNTOOLS_CALIDUS_REG_ID='' CNTOOLS_CALIDUS_REG_COLD=''
  CNTOOLS_CALIDUS_REG_POOL='' CNTOOLS_CALIDUS_REG_HEX=''
  CNTOOLS_CALIDUS_CHAIN_STATUS='Not checked'; CNTOOLS_CALIDUS_CHAIN_STATE=''
  CNTOOLS_CALIDUS_CHAIN_NONCE=''; CNTOOLS_CALIDUS_CHAIN_PUBLIC=''; CNTOOLS_CALIDUS_CHAIN_ID=''; CNTOOLS_CALIDUS_CHAIN_TX=''
  [[ "${CNTOOLS_POOL_IDENTITIES[index]}" == 'Verified cold public key' ]] || {
    cntools_calidus_registration_fail 'A verified pool cold public key is required.'; return 1;
  }
  CNTOOLS_CALIDUS_REG_DIRECTORY="${CNTOOLS_POOL_DIRECTORIES[index]}"
  cntools_calidus_registration_directory_safe || return 1
  case "${CNTOOLS_CALIDUS_OPERATION}" in
    revoke)
      # Revoking a compromised/lost key must not read or require local Calidus
      # material. The pool cold key authorizes CIP-151's all-zero replacement.
      printf -v CNTOOLS_CALIDUS_REG_PUBLIC '%064d' 0 ;;
    register)
      cntools_calidus_inspect "${CNTOOLS_CALIDUS_REG_DIRECTORY}" &&
        [[ -n "${CNTOOLS_CALIDUS_PUBLIC}" || "${2:-}" == allow-missing ]] || {
        cntools_calidus_registration_fail "${CNTOOLS_POOL_WRITE_ERROR:-Prepare a Calidus identity first.}"; return 1;
      }
      CNTOOLS_CALIDUS_REG_PUBLIC="${CNTOOLS_CALIDUS_PUBLIC}"; CNTOOLS_CALIDUS_REG_ID="${CNTOOLS_CALIDUS_ID}" ;;
    *) cntools_calidus_registration_fail 'Unknown Calidus authorization operation.'; return 1 ;;
  esac
  cntools_pool_file_name_into cold cold-vkey && cntools_pool_public_file_safe "${CNTOOLS_CALIDUS_REG_DIRECTORY}/${cold}" &&
    cntools_transaction_snapshot_into frozen "${CNTOOLS_CALIDUS_REG_DIRECTORY}/${cold}" 65536 calidus-cold-public &&
    cntools_pool_key_validate "${frozen}" cold verification || return 1
  CNTOOLS_CALIDUS_REG_COLD="${frozen}"
  cntools_transaction_temp_file response calidus-pool-hash && cntools_transaction_temp_file errors calidus-pool-errors || return 1
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" latest stake-pool id \
    --cold-verification-key-file "${frozen}" --output-bech32 || status=$?
  if ((status != 0)); then cntools_transaction_log_cli_failure 'Calidus pool identity failed' "${status}" "${errors}" "${response}"; return 1; fi
  cntools_pool_id_into derived_pool derived_hex "$(< "${response}")" || return 1
  [[ "${derived_pool}" == "${CNTOOLS_POOL_IDS[index]}" ]] || {
    cntools_calidus_registration_fail 'The pool identity changed. Reopen Calidus before continuing.'; return 1;
  }
  CNTOOLS_CALIDUS_REG_POOL="${derived_pool}"; CNTOOLS_CALIDUS_REG_HEX="${derived_hex}"
}

cntools_calidus_registration_lookup() {
  local response='' record='' nonce=''
  CNTOOLS_CALIDUS_CHAIN_STATE=''; CNTOOLS_CALIDUS_CHAIN_STATUS=Unavailable
  CNTOOLS_CALIDUS_CHAIN_NONCE='' CNTOOLS_CALIDUS_CHAIN_PUBLIC='' CNTOOLS_CALIDUS_CHAIN_ID='' CNTOOLS_CALIDUS_CHAIN_TX=''
  [[ "${CNTOOLS_MODE:-}" != offline && "${CNTOOLS_KOIOS_ENABLED:-N}" == Y && "${CNTOOLS_KOIOS_API:-}" =~ ^https://[^[:space:]]+$ &&
     "${CNTOOLS_CALIDUS_REG_POOL}" =~ ^pool1[0-9a-z]+$ ]] || {
    cntools_calidus_registration_fail 'Calidus on-chain lookup requires Koios. Offline key setup and metadata authorization remain available.'; return 1;
  }
  cntools_transaction_temp_file response calidus-status || return 1
  cntools_funding_get "${CNTOOLS_KOIOS_API%/}/pool_calidus_keys?pool_id_bech32=eq.${CNTOOLS_CALIDUS_REG_POOL}&select=pool_id_bech32%2Ccalidus_nonce%3A%3Atext%2Ccalidus_pub_key%2Ccalidus_id_bech32%2Ctx_hash%2Cregistered" "${response}" || {
    cntools_calidus_registration_fail 'Koios could not check Calidus registration. An unavailable query is not an unregistered key.'; return 1;
  }
  jq -e --arg pool "${CNTOOLS_CALIDUS_REG_POOL}" '
    type=="array" and length<=1 and all(.[];
      .pool_id_bech32==$pool and (.calidus_nonce|type=="string" and test("^(0|[1-9][0-9]*)$")) and
      (.calidus_pub_key|type=="string" and test("^[0-9a-f]{64}$")) and
      (.tx_hash|type=="string" and test("^[0-9a-f]{64}$")) and
      (.registered|type=="boolean") and
      (.registered == (.calidus_pub_key != ("0"*64))) and
      (if .registered then (.calidus_id_bech32|type=="string" and test("^calidus1[0-9a-z]+$")) else true end))
  ' "${response}" >/dev/null || {
    cntools_calidus_registration_fail 'Koios returned invalid Calidus registration data.'; return 1;
  }
  record="$(jq -cS 'map({nonce:.calidus_nonce,public:.calidus_pub_key,registered,tx:.tx_hash})' "${response}")" || return 1
  CNTOOLS_CALIDUS_CHAIN_STATE="${record}"
  if [[ "${record}" == '[]' ]]; then CNTOOLS_CALIDUS_CHAIN_STATUS='Not indexed'; return 0; fi
  nonce="$(jq -r '.[0].calidus_nonce' "${response}")"
  cntools_uint_greater_equal 9007199254740991 "${nonce}" || {
    cntools_calidus_registration_fail 'The indexed Calidus nonce exceeds the supported exact Cardano Signer range.'; return 1;
  }
  CNTOOLS_CALIDUS_CHAIN_NONCE="${nonce}"
  CNTOOLS_CALIDUS_CHAIN_PUBLIC="$(jq -r '.[0].calidus_pub_key' "${response}")"
  CNTOOLS_CALIDUS_CHAIN_ID="$(jq -r '.[0].calidus_id_bech32 // empty' "${response}")"
  CNTOOLS_CALIDUS_CHAIN_TX="$(jq -r '.[0].tx_hash' "${response}")"
  CNTOOLS_CALIDUS_CHAIN_STATUS=Revoked
  if jq -e '.[0].registered' "${response}" >/dev/null; then
    if [[ "${CNTOOLS_CALIDUS_OPERATION}" == revoke ]]; then
      CNTOOLS_CALIDUS_CHAIN_STATUS=Registered
    else
      CNTOOLS_CALIDUS_CHAIN_STATUS='Different key registered'
      [[ -n "${CNTOOLS_CALIDUS_REG_PUBLIC}" ]] || CNTOOLS_CALIDUS_CHAIN_STATUS='Registered (no local key)'
      [[ "${CNTOOLS_CALIDUS_CHAIN_PUBLIC}" != "${CNTOOLS_CALIDUS_REG_PUBLIC}" ]] || CNTOOLS_CALIDUS_CHAIN_STATUS='This key registered'
    fi
  fi
}

cntools_calidus_registration_nonce_valid() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]] && cntools_uint_greater_equal 9007199254740991 "$1" || return 1
  [[ -z "${CNTOOLS_CALIDUS_CHAIN_NONCE}" ]] || cntools_uint_greater "$1" "${CNTOOLS_CALIDUS_CHAIN_NONCE}"
}

# Accept only the one reviewed pool/Calidus authorization; no extra labels,
# features, witnesses or unsigned payload fields can hitchhike on the transfer.
cntools_calidus_registration_verify() {
  local source="$1" frozen='' normalized='' response='' errors='' status=0 nonce='' cold_public=''
  # Bind import/signature verification to the selected operation, not merely a
  # caller's public-key value: registration cannot silently import revocation.
  [[ "${CNTOOLS_CALIDUS_REG_PUBLIC}" =~ ^[0-9a-f]{64}$ ]] &&
    { [[ "${CNTOOLS_CALIDUS_OPERATION}" == revoke && "${CNTOOLS_CALIDUS_REG_PUBLIC}" =~ ^0{64}$ ]] ||
      [[ "${CNTOOLS_CALIDUS_OPERATION}" == register && ! "${CNTOOLS_CALIDUS_REG_PUBLIC}" =~ ^0{64}$ ]]; } || {
    cntools_calidus_registration_fail 'The authorization target does not match the selected Calidus operation.'; return 1;
  }
  cntools_calidus_signer_require && cntools_transaction_snapshot_into frozen "${source}" 65536 calidus-authorization || return 1
  cntools_metadata_validate_json "${frozen}" || {
    cntools_calidus_registration_fail "${CNTOOLS_METADATA_ERROR:-Invalid registration JSON.}"; return 1;
  }
  cold_public="$(jq -er '.cborHex[4:]|ascii_downcase' "${CNTOOLS_CALIDUS_REG_COLD}")" || return 1
  jq -e --arg pool "0x${CNTOOLS_CALIDUS_REG_HEX}" --arg public "0x${CNTOOLS_CALIDUS_REG_PUBLIC}" --arg cold "0x${cold_public}" '
    keys==["867"] and (."867"|keys)==["0","1","2"] and ."867"."0"==2 and
    (."867"."1"|keys)==["1","2","3","4","7"] and
    ."867"."1"."1"==[1,$pool] and ."867"."1"."2"==[] and ."867"."1"."3"==[2] and ."867"."1"."7"==$public and
    (."867"."1"."4"|type=="number" and floor==. and .>=0 and .<=9007199254740991) and
    (."867"."2"|type=="array" and length==1) and
    (."867"."2"[0]|keys)==["1","2"] and
    ."867"."2"[0]."1"=={"1":1,"3":-8,"-1":6,"-2":$cold} and
    (."867"."2"[0]."2"|type=="array" and length==4 and
      (.[0]|type=="string" and test("^0x[0-9a-f]+$")) and .[1]==0 and
      (.[2]|type=="string" and test("^0x[0-9a-f]{64}$")) and
      (.[3]|type=="string" and test("^0x[0-9a-f]{128}$")))
  ' "${frozen}" >/dev/null || {
    cntools_calidus_registration_fail 'Metadata does not match this pool, selected Calidus operation or supported CIP-151 authorization.'; return 1;
  }
  nonce="$(jq -r '."867"."1"."4"|tostring' "${frozen}")"
  cntools_calidus_registration_nonce_valid "${nonce}" || {
    cntools_calidus_registration_fail 'The authorization nonce must be higher than the last indexed registration (including revocation).'; return 1;
  }
  # Explicit ordering matches the CIP payload and Signer/CLI CBOR conversion.
  cntools_transaction_temp_file normalized calidus-canonical || return 1
  jq '{"867":{"0":2,"1":(."867"."1"|{"1":."1","2":[],"3":[2],"4":."4","7":."7"}),
    "2":[(."867"."2"[0]|{"1":(."1"|{"1":1,"3":-8,"-1":6,"-2":."-2"}),"2":."2"})]}}' "${frozen}" > "${normalized}" || return 1
  cntools_transaction_temp_file response calidus-verified && cntools_transaction_temp_file errors calidus-verify-errors || return 1
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CARDANO_SIGNER}" verify --cip88 --data-file "${normalized}" --json-extended || status=$?
  if ((status != 0)); then cntools_transaction_log_cli_failure 'Calidus authorization verification failed' "${status}" "${errors}" "${response}"; return 1; fi
  jq -es --arg pool "${CNTOOLS_CALIDUS_REG_HEX}" --arg key "${CNTOOLS_CALIDUS_REG_PUBLIC}" --arg cold "${cold_public}" --arg nonce "${nonce}" '
    length==1 and (.[0]|.workMode=="verify-cip88" and .result=="true" and .poolIdHex==$pool and
      .calidusPublicKey==$key and .publicKey==$cold and (.nonce|tostring)==$nonce)
  ' "${response}" >/dev/null || { cntools_calidus_registration_fail 'The Calidus authorization signature is invalid or belongs to another identity.'; return 1; }
  CNTOOLS_CALIDUS_REG_METADATA="${normalized}"; CNTOOLS_CALIDUS_REG_NONCE="${nonce}"
  cntools_transaction_log POOL "Verified Calidus authorization operation=${CNTOOLS_CALIDUS_OPERATION} pool=${CNTOOLS_CALIDUS_REG_POOL} id=${CNTOOLS_CALIDUS_REG_ID} nonce=${nonce} metadata=$(jq -c . "${normalized}")"
}

cntools_calidus_registration_authorize() {
  local nonce="$1" name='' hardware='' frozen='' public='' metadata='' response='' errors='' status=0 source=''
  cntools_calidus_registration_nonce_valid "${nonce}" && cntools_calidus_signer_require || return 1
  cntools_pool_file_name_into name cold-skey || return 1
  cntools_pool_file_name_into hardware cold-hardware || return 1
  source="${CNTOOLS_CALIDUS_REG_DIRECTORY}/${name}"
  [[ ! -e "${source}.gpg" && ! -L "${source}.gpg" &&
     ! -e "${CNTOOLS_CALIDUS_REG_DIRECTORY}/${hardware}" && ! -L "${CNTOOLS_CALIDUS_REG_DIRECTORY}/${hardware}" ]] &&
    cntools_transaction_private_file_safe "${source}" &&
    cntools_transaction_snapshot_into frozen "${source}" 65536 calidus-cold-signing && cntools_pool_key_validate "${frozen}" cold signing || {
    cntools_calidus_registration_fail 'A private unencrypted CLI cold key is needed for local authorization. Otherwise import metadata signed on your offline system; do not copy the cold key online.'; return 1;
  }
  cntools_transaction_temp_file public calidus-derived-cold &&
    cntools_pool_cli key verification-key --signing-key-file "${frozen}" --verification-key-file "${public}" &&
    jq -es 'length==2 and (.[0].cborHex|ascii_downcase)==(.[1].cborHex|ascii_downcase)' "${public}" "${CNTOOLS_CALIDUS_REG_COLD}" >/dev/null || {
    cntools_calidus_registration_fail 'The cold signing key does not match this pool.'; return 1;
  }
  cntools_transaction_temp_file metadata calidus-generated && cntools_transaction_temp_file response calidus-sign-output &&
    cntools_transaction_temp_file errors calidus-sign-errors || return 1
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CARDANO_SIGNER}" sign --cip88 \
    --calidus-public-key "${CNTOOLS_CALIDUS_REG_PUBLIC}" --secret-key "${frozen}" --nonce "${nonce}" --json --out-file "${metadata}" || status=$?
  if ((status != 0)); then cntools_transaction_log_cli_failure 'Calidus authorization failed' "${status}" "${errors}" "${response}"; return 1; fi
  cntools_calidus_registration_verify "${metadata}" || return 1
  [[ "${CNTOOLS_CALIDUS_REG_NONCE}" == "${nonce}" ]] || {
    cntools_calidus_registration_fail 'Cardano Signer returned a different authorization nonce. No metadata was exported.'; return 1;
  }
}
