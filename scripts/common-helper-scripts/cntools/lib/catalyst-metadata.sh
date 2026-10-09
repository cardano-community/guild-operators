#!/usr/bin/env bash
# Exact CIP-36 registration schema, CBOR hash and stake-signature binding.
# shellcheck disable=SC2034,SC2015
CNTOOLS_CATALYST_METADATA='' CNTOOLS_CATALYST_NONCE='' CNTOOLS_CATALYST_STAKE_PUBLIC=''
CNTOOLS_CATALYST_REWARD='' CNTOOLS_CATALYST_REWARD_HEX=''

cntools_catalyst_identity() {
  local directory="$1" normalized='' response='' errors='' form='' status=0
  cntools_payment_prepare_wallet "${directory}" &&
    cntools_wallet_key_validate "${directory}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" stake any || {
    cntools_catalyst_fail 'Catalyst registration needs a payment wallet with a key-based stake identity.'; return 1;
  }
  cntools_transaction_snapshot_into normalized "${directory}/${CNTOOLS_WALLET_STAKE_VKEY_FILENAME}" 65536 catalyst-stake-public || return 1
  CNTOOLS_CATALYST_STAKE_PUBLIC="$(jq -r '.cborHex[4:68]|ascii_downcase' "${normalized}")"
  [[ "${CNTOOLS_CATALYST_STAKE_PUBLIC}" =~ ^[0-9a-f]{64}$ ]] || return 1
  CNTOOLS_CATALYST_REWARD="${CNTOOLS_PAYMENT_ADDRESS}"
  cntools_catalyst_address_hex_into CNTOOLS_CATALYST_REWARD_HEX "${CNTOOLS_CATALYST_REWARD}" || return 1
}

cntools_catalyst_address_hex_into() {
  local -n ca_output="$1"
  local ca_address="$2" ca_charset=qpzry9x8gf2tvdw0s3jn54khce6mua7l ca_data='' ca_suffix='' ca_hex='' ca_byte=''
  local ca_i=0 ca_n=0 ca_acc=0 ca_bits=0
  cntools_recipient_validate "${ca_address}" || return 1
  ca_data="${ca_address#*1}"; ca_data="${ca_data:0:${#ca_data}-6}"
  for ((ca_i=0;ca_i<${#ca_data};ca_i++)); do
    ca_suffix="${ca_charset#*"${ca_data:ca_i:1}"}"; ca_n=$((31-${#ca_suffix}))
    ca_acc=$(((ca_acc << 5 | ca_n) & 4095)); ca_bits=$((ca_bits+5))
    if ((ca_bits >= 8)); then
      ca_bits=$((ca_bits-8)); printf -v ca_byte '%02x' "$((ca_acc >> ca_bits & 255))"; ca_hex+="${ca_byte}"
    fi
  done
  ca_output="${ca_hex}"
}

# Fixed schema encoder, not a general CBOR parser. All values validated first.
cntools_catalyst_cbor_uint_into() {
  local -n cb_output="$1"
  local cb_number="$2"
  [[ "${cb_number}" =~ ^(0|[1-9][0-9]*)$ ]] && cntools_uint_greater_equal 9007199254740991 "${cb_number}" || return 1
  if ((cb_number < 24)); then printf -v cb_output '%02x' "${cb_number}"
  elif ((cb_number < 256)); then printf -v cb_output '18%02x' "${cb_number}"
  elif ((cb_number < 65536)); then printf -v cb_output '19%04x' "${cb_number}"
  elif ((cb_number < 4294967296)); then printf -v cb_output '1a%08x' "${cb_number}"
  else printf -v cb_output '1b%016x' "${cb_number}"; fi
}

cntools_catalyst_verify_metadata() {
  local source="$1" frozen='' nonce='' encoded_nonce='' cbor='' binary='' response='' errors='' digest='' signature='' status=0
  CNTOOLS_CATALYST_METADATA=''
  cntools_catalyst_signer_require && cntools_transaction_require_cli &&
    cntools_transaction_snapshot_into frozen "${source}" 65536 catalyst-metadata &&
    cntools_metadata_validate_json "${frozen}" || return 1
  jq -e --arg vote "0x${CNTOOLS_CATALYST_PUBLIC}" --arg stake "0x${CNTOOLS_CATALYST_STAKE_PUBLIC}" --arg reward "0x${CNTOOLS_CATALYST_REWARD_HEX}" '
    keys==["61284","61285"] and (."61284"|keys)==["1","2","3","4","5"] and
    ."61284"."1"==[[$vote,1]] and ."61284"."2"==$stake and ."61284"."3"==$reward and ."61284"."5"==0 and
    (."61284"."4"|type=="number" and floor==. and .>=0 and .<=9007199254740991) and
    (."61285"|keys)==["1"] and (."61285"."1"|type=="string" and test("^0x[0-9a-f]{128}$"))
  ' "${frozen}" >/dev/null || { cntools_catalyst_fail 'Registration metadata does not match the reviewed wallet, voting key or reward address.'; return 1; }
  nonce="$(jq -r '."61284"."4"|tostring' "${frozen}")"
  cntools_catalyst_cbor_uint_into encoded_nonce "${nonce}" || return 1
  printf -v cbor 'a119ef64a50181825820%s01025820%s0358%02x%s04%s0500' \
    "${CNTOOLS_CATALYST_PUBLIC}" "${CNTOOLS_CATALYST_STAKE_PUBLIC}" "$(( ${#CNTOOLS_CATALYST_REWARD_HEX}/2 ))" "${CNTOOLS_CATALYST_REWARD_HEX}" "${encoded_nonce}"
  cntools_transaction_temp_file binary catalyst-payload && cntools_transaction_temp_file response catalyst-hash &&
    cntools_transaction_temp_file errors catalyst-hash-errors || return 1
  printf '%s' "${cbor}" | xxd -r -p > "${binary}" || return 1
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" hash anchor-data --file-binary "${binary}" || status=$?
  ((status == 0)) || { cntools_transaction_log_cli_failure 'Catalyst metadata hashing failed' "${status}" "${errors}" "${response}"; return 1; }
  digest="$(< "${response}")"; signature="$(jq -r '."61285"."1"[2:]' "${frozen}")"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CARDANO_SIGNER}" verify --data-hex "${digest}" \
    --signature "${signature}" --public-key "${CNTOOLS_CATALYST_STAKE_PUBLIC}" --json || status=$?
  ((status == 0)) && jq -es 'length==1 and .[0].result=="true"' "${response}" >/dev/null || {
    cntools_catalyst_fail 'The Catalyst metadata stake signature is invalid.'; return 1;
  }
  # Explicit key order preserves the canonical signed payload across CLI input.
  cntools_transaction_temp_file CNTOOLS_CATALYST_METADATA catalyst-canonical || return 1
  jq '{"61284":(."61284"|{"1":."1","2":."2","3":."3","4":."4","5":."5"}),"61285":."61285"}' "${frozen}" > "${CNTOOLS_CATALYST_METADATA}" || return 1
  CNTOOLS_CATALYST_NONCE="${nonce}"
  cntools_transaction_log REVIEW "Verified CIP-36 wallet=${CNTOOLS_CATALYST_DIRECTORY##*/} nonce=${nonce} metadata=$(jq -c . "${CNTOOLS_CATALYST_METADATA}")"
}

cntools_catalyst_authorize() {
  local nonce="$1" signing='' public='' metadata='' response='' errors='' status=0
  cntools_catalyst_cbor_uint_into response "${nonce}" && cntools_catalyst_signer_require || return 1
  cntools_transaction_temp_file response catalyst-sign-output && cntools_transaction_temp_file errors catalyst-sign-errors &&
    cntools_transaction_temp_file metadata catalyst-signed-metadata || return 1
  local -a arguments=()
  [[ "${CNTOOLS_NETWORK}" == mainnet ]] || arguments+=(--testnet)
  if [[ "${CNTOOLS_PAYMENT_TYPE}" == Hardware ]]; then
    cntools_transaction_require_hwcli || return 1
    cntools_catalyst_authorize_hardware "${nonce}" "${metadata}" || return 1
  else
    signing="${CNTOOLS_CATALYST_DIRECTORY}/${CNTOOLS_WALLET_STAKE_SKEY_FILENAME}"
    [[ ! -e "${signing}.gpg" && ! -L "${signing}.gpg" ]] && cntools_transaction_private_file_safe "${signing}" &&
      cntools_wallet_key_signing_type stake "${signing}" public &&
      cntools_transaction_snapshot_into signing "${signing}" 65536 catalyst-stake-signing || {
      cntools_catalyst_fail 'Decrypt the stake key first or import registration metadata signed offline.'; return 1;
    }
    cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CARDANO_SIGNER}" sign --cip36 "${arguments[@]}" \
      --vote-public-key "${CNTOOLS_CATALYST_PUBLIC}" --payment-address "${CNTOOLS_CATALYST_REWARD}" \
      --secret-key "${signing}" --nonce "${nonce}" --vote-purpose 0 --json --out-file "${metadata}" || status=$?
    if ((status != 0)); then cntools_transaction_log_cli_failure 'Catalyst authorization failed' "${status}" "${errors}" "${response}"; return 1; fi
  fi
  cntools_catalyst_verify_metadata "${metadata}"
}

cntools_catalyst_authorize_hardware() {
  local nonce="$1" metadata="$2" raw='' body='' view='' response='' errors='' stake='' payment='' status=0
  local -a network=()
  stake="${CNTOOLS_CATALYST_DIRECTORY}/${CNTOOLS_WALLET_HW_STAKE_SKEY_FILENAME}"
  payment="${CNTOOLS_CATALYST_DIRECTORY}/${CNTOOLS_WALLET_HW_PAY_SKEY_FILENAME}"
  cntools_transaction_private_file_safe "${stake}" && cntools_transaction_private_file_safe "${payment}" &&
    cntools_transaction_network_arguments_into network "${CNTOOLS_NETWORK}" &&
    cntools_transaction_temp_file raw catalyst-hardware-cbor && cntools_transaction_temp_file body catalyst-hardware-body &&
    cntools_transaction_temp_file response catalyst-hardware-output && cntools_transaction_temp_file errors catalyst-hardware-errors || return 1
  # Device confirmation needs the shared hardware timeout, not the short CLI
  # timeout. Keep the longer bound scoped to this one interactive operation.
  (
    CNTOOLS_TRANSACTION_TIMEOUT="${CNTOOLS_TRANSACTION_HARDWARE_TIMEOUT:-300}"
    cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_TRANSACTION_HWCLI}" vote registration-metadata "${network[@]}" \
      --vote-public-key-file "${CNTOOLS_CATALYST_DIRECTORY}/${CNTOOLS_WALLET_CATALYST_VKEY_FILENAME:-catalyst.vkey}" \
      --payment-address "${CNTOOLS_CATALYST_REWARD}" --stake-signing-key-hwsfile "${stake}" --nonce "${nonce}" \
      --payment-address-signing-key-hwsfile "${payment}" --metadata-cbor-out-file "${raw}"
  ) || status=$?
  if ((status != 0)); then cntools_transaction_log_cli_failure 'Hardware Catalyst authorization failed' "${status}" "${errors}" "${response}"; return 1; fi
  # Decode hardware-produced CBOR with the pinned CLI, not a second CBOR parser.
  cntools_transaction_run_cli "${response}" "${errors}" -- "${CNTOOLS_CLI}" latest transaction build-raw \
    --tx-in "$(printf '%064d' 0)#0" --tx-out "${CNTOOLS_CATALYST_REWARD}+0" --fee 0 --metadata-cbor-file "${raw}" --out-file "${body}" || return 1
  cntools_transaction_view_into view "${body}" || return 1
  jq '
    def unledger:
      if type=="array" then
        if length>0 and all(.[];type=="array" and length==2 and (.[0]|type=="number")) then
          map({key:(.[0]|tostring),value:(.[1]|unledger)})|from_entries
        else map(unledger) end
      elif type=="string" and startswith("[0x") then
        "0x"+([scan("0x([0-9a-f]+)")[]|if length==1 then "0"+. else . end]|join(""))
      else . end;
    .metadata|with_entries(.value|=unledger)
  ' <<< "${view}" > "${metadata}"
}
