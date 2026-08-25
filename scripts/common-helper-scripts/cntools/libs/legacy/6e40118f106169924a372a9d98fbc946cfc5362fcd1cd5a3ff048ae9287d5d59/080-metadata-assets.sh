# Command     : sendMetadata
# Description : post metadata file on chain using specified wallet to pay for the transaction fee
sendMetadata() {

  [[ $(cat "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}" 2>/dev/null) = "${addr}" ]] && wallet_source="payment" || wallet_source="base"

  getWalletType ${wallet_name}
  wallet_type=$?

  if [[ ${metatype} = "no-schema" ]]; then
    metafile_param="--json-metadata-no-schema --metadata-json-file ${metafile}"
  elif [[ ${metatype} = "detailed-schema" ]]; then
    metafile_param="--json-metadata-detailed-schema --metadata-json-file ${metafile}"
  elif [[ ${metatype} = "cbor" ]]; then
    metafile_param="--metadata-cbor-file ${metafile}"
  else
    println ERROR "${FG_RED}ERROR${NC}: unknown metadata type '${metatype}'"
    return 1
  fi

  if [[ ${wallet_type} -eq 5 ]]; then
    op_mode=hybrid
    unset required_total
    validateMultiSigScript false "$(cat "${payment_script_file}")"
    witness_cnt=${required_total}
  else
    witness_cnt=1
  fi

  if ! getTTL "$([[ ${wallet_type} -eq 5 ]] && echo true)"; then return 1; fi

  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    for key in "${!assets[@]}"; do
      [[ ${key} != "${addr},"* ]] && unset 'assets[$key]'
    done
    utxo_cnt=${utxos_cnt[${addr}]}
    tx_in=${tx_in_arr[${addr}]}
  else
    getBalance ${addr}
  fi

  getAssetsTxOut

  unset script_args
  if [[ ${wallet_type} -eq 5 ]]; then
    script_args=( --tx-in-script-file "${payment_script_file}" )
  fi

  tmpNewBalance=$(( lovelace ))
  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${addr}+${tmpNewBalance}${assets_tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    ${metafile_param}
    --out-file "${TMP_DIR}"/tx0.tmp
  )

  buildTx || return 1

  calcMinFee "${TMP_DIR}"/tx0.tmp ${utxo_cnt} 1 ${witness_cnt} || return 1

  newBalance=$(( lovelace - min_fee ))
  println LOG "Balance left to be returned in used UTxO is $(formatLovelace ${newBalance}) ADA ( $(formatLovelace ${lovelace}) - $(formatLovelace ${min_fee}) )"

  if [[ ${lovelace} -lt ${min_fee} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA in ${wallet_source} address for tx fee!"\
			"Funds in address: ${FG_LBLUE}$(formatLovelace ${lovelace})${NC} ADA"\
			"Minimum required: ${FG_LBLUE}$(formatLovelace ${min_fee})${NC} ADA"
    return 1
  fi

  tx_out="${addr}+${newBalance}${assets_tx_out}"
  getMinUTxO "${tx_out}" || return 1
  if [[ ${newBalance} -lt ${min_utxo_out} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: minimum UTxO value not fulfilled, only ${FG_LBLUE}$(formatLovelace ${newBalance})${NC} ADA left in address after tx fee, at least ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA required!"
    return 1
  fi

  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${tx_out}"
    ${metafile_param}
    --invalid-hereafter ${ttl}
    --fee ${min_fee}
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${wallet_type} -eq 0 ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Metadata"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { metadata: $(jq -c . "${metafile}") }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txFee: \"${min_fee}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txBody: $(jq -c . "${TMP_DIR}"/tx.raw) }" <<< ${offlineJSON}); then return 1; fi
    if [[ ${wallet_type} -eq 5 ]]; then
      if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Wallet '${wallet_name}' payment script\", script: $(jq -c . "${payment_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
    else
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${wallet_name}' payment signing key\", vkey: $(jq -c . "${payment_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ". += { \"signed-txBody\": {} }" <<< ${offlineJSON}); then return 1; fi
    offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"
    jq -r . <<< "${offlineJSON}" > "${offline_tx}"
    echo
    if [[ ${wallet_type} -eq 5 ]]; then
      println "Metadata transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "Use CNTools [Transaction >> Sign] to witness the transaction with MultiSig wallet participants."
    else
      println "Offline transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "move file to offline computer and sign it using CNTools in offline mode '-o' [Transaction >> Sign] with:"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${payment_sk_file})${NC}"
    fi
    return 2 # return as failed to stop main processing and return to home menu
  fi

  if ! witnessTx "${TMP_DIR}/tx.raw" "${payment_sk_file}"; then return 1; fi
  if ! assembleTx "${TMP_DIR}/tx.raw"; then return 1; fi
  if ! submitTx "${tx_signed}"; then return 1; fi
}


# Command     : mintAsset
# Description : mint a custom asset using specified wallet to pay for the transaction fee
mintAsset() {

  [[ $(cat "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}" 2>/dev/null) = "${addr}" ]] && wallet_source="payment" || wallet_source="base"

  getWalletType ${wallet_name}
  wallet_type=$?

  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    for key in "${!assets[@]}"; do
      [[ ${key} != "${addr},"* ]] && unset 'assets[$key]'
    done
    index_prefix="${addr},"
    utxo_cnt=${utxos_cnt[${addr}]}
    tx_in=${tx_in_arr[${addr}]}
  else
    getBalance ${addr}
    unset index_prefix
  fi

  if [[ ${wallet_type} -eq 5 ]]; then
    op_mode=hybrid
    unset required_total
    validateMultiSigScript false "$(cat "${payment_script_file}")"
    witness_cnt=$(( required_total + 1 ))
  else
    witness_cnt=2
  fi

  if [[ ${policy_ttl} -eq 0 ]]; then
    if ! getTTL "$([[ ${wallet_type} -eq 5 ]] && echo true)"; then return 1; fi
  else
    ttl=${policy_ttl}
    tip_ref=$(getSlotTipRef)
    println LOG "Current slot is ${tip_ref}, setting ttl to ${ttl} based on policy expiration"
  fi

  [[ -z ${asset_name} ]] && asset_name_out="" || asset_name_out=".$(asciiToHex "${asset_name}")"
  getAssetsTxOut "${index_prefix}${policy_id}${asset_name_out}" "${assets_to_mint}"

  unset script_args
  if [[ ${wallet_type} -eq 5 ]]; then
    script_args=( --tx-in-script-file "${payment_script_file}" )
  fi

  tmpNewBalance=$(( lovelace ))
  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${addr}+${tmpNewBalance}${assets_tx_out}"
    --mint "${assets_to_mint} ${policy_id}${asset_name_out}"
    --mint-script-file "${policy_script_file}"
    ${metafile_param}
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    --out-file "${TMP_DIR}"/tx0.tmp
  )

  buildTx || return 1

  calcMinFee "${TMP_DIR}"/tx0.tmp ${utxo_cnt} 1 ${witness_cnt} || return 1

  newBalance=$(( lovelace - min_fee ))
  println LOG "Balance left to be returned in used UTxO is $(formatLovelace ${newBalance}) ADA ( $(formatLovelace ${lovelace}) - $(formatLovelace ${min_fee}) )"

  if [[ ${lovelace} -lt ${min_fee} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA in ${wallet_source} address for tx fee!"\
			"Funds in address: ${FG_LBLUE}$(formatLovelace ${lovelace})${NC} ADA"\
			"Minimum required: ${FG_LBLUE}$(formatLovelace ${min_fee})${NC} ADA"
    return 1
  fi

  tx_out="${addr}+${newBalance}${assets_tx_out}"
  getMinUTxO "${tx_out}"
  if [[ ${newBalance} -lt ${min_utxo_out} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: minimum UTxO value not fulfilled, only ${FG_LBLUE}$(formatLovelace ${newBalance})${NC} ADA left in address after tx fee, at least ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA required!"
    return 1
  fi

  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${tx_out}"
    --mint "${assets_to_mint} ${policy_id}${asset_name_out}"
    --mint-script-file "${policy_script_file}"
    ${metafile_param}
    --invalid-hereafter ${ttl}
    --fee ${min_fee}
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${wallet_type} -eq 0 ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Asset Minting"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"policy-name\": \"${policy_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"policy-id\": \"${policy_id}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"asset-name\": \"$(asciiToHex "${asset_name}") (${asset_name})\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"asset-amount\": \"${assets_to_mint}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"asset-minted\": \"${asset_minted}\" }" <<< ${offlineJSON}); then return 1; fi
    if [[ -n ${metafile_param} ]]; then
      if ! offlineJSON=$(jq ". += { metadata: $(jq -c . "${metafile}") }" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ". += { txFee: \"${min_fee}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txBody: $(jq -c . "${TMP_DIR}"/tx.raw) }" <<< ${offlineJSON}); then return 1; fi
    if [[ ${wallet_type} -eq 5 ]]; then
      if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Wallet '${wallet_name}' payment script\", script: $(jq -c . "${payment_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
    else
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${wallet_name}' payment signing key\", vkey: $(jq -c . "${payment_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Asset '${policy_sk_file}' policy signing key\", vkey: $(jq -c . "${policy_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"signed-txBody\": {} }" <<< ${offlineJSON}); then return 1; fi
    offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"
    jq -r . <<< "${offlineJSON}" > "${offline_tx}"
    echo
    if [[ ${wallet_type} -eq 5 ]]; then
      println "Asset mint transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "Use CNTools [Transaction >> Sign] to witness the transaction with MultiSig wallet participants."
    else
      println "Offline transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "move file to offline computer and sign it using CNTools in offline mode '-o' [Transaction >> Sign] with:"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${payment_sk_file})${NC}"
      println DEBUG "Policy ${FG_GREEN}${policy_name} ${FG_LGRAY}$(basename ${policy_sk_file})${NC}"
    fi
    return 2 # return as failed to stop main processing and return to home menu
  fi

  if ! witnessTx "${TMP_DIR}/tx.raw" "${payment_sk_file}" "${policy_sk_file}"; then return 1; fi
  if ! assembleTx "${TMP_DIR}/tx.raw"; then return 1; fi
  if ! submitTx "${tx_signed}"; then return 1; fi
}


# Command     : burnAsset
# Description : burn custom assets on specified wallet
burnAsset() {

  getWalletType ${wallet_name}
  wallet_type=$?

  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    for key in "${!assets[@]}"; do
      [[ ${key} != "${addr},"* ]] && unset 'assets[$key]'
    done
    index_prefix="${addr},"
    utxo_cnt=${utxos_cnt[${addr}]}
    tx_in=${tx_in_arr[${addr}]}
  else
    getBalance ${addr}
    unset index_prefix
  fi

  if [[ ${wallet_type} -eq 5 ]]; then
    op_mode=hybrid
    unset required_total
    validateMultiSigScript false "$(cat "${payment_script_file}")"
    witness_cnt=$(( required_total + 1 ))
  else
    witness_cnt=2
  fi

  if [[ ${policy_ttl} -eq 0 ]]; then
    if ! getTTL "$([[ ${wallet_type} -eq 5 ]] && echo true)"; then return 1; fi
  else
    ttl=${policy_ttl}
    tip_ref=$(getSlotTipRef)
    println LOG "Current slot is ${tip_ref}, setting ttl to ${ttl} based on policy expiration"
  fi

  [[ -z ${asset_name} ]] && asset_name_out="" || asset_name_out=".${asset_name}"
  getAssetsTxOut "${index_prefix}${policy_id}${asset_name_out}" "-${assets_to_burn}"

  unset script_args
  if [[ ${wallet_type} -eq 5 ]]; then
    script_args=( --tx-in-script-file "${payment_script_file}" )
  fi

  tmpNewBalance=$(( lovelace ))
  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${addr}+${tmpNewBalance}${assets_tx_out}"
    --mint "-${assets_to_burn} ${policy_id}${asset_name_out}"
    --mint-script-file "${policy_script_file}"
    ${metafile_param}
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    --out-file "${TMP_DIR}"/tx0.tmp
  )

  buildTx || return 1

  calcMinFee "${TMP_DIR}"/tx0.tmp ${utxo_cnt} 1 ${witness_cnt} || return 1

  newBalance=$(( lovelace - min_fee ))
  println LOG "Balance left to be returned in used UTxO is $(formatLovelace ${newBalance}) ADA ( $(formatLovelace ${lovelace}) - $(formatLovelace ${min_fee}) )"

  if [[ ${lovelace} -lt ${min_fee} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA in ${wallet_source} address for tx fee!"\
			"Funds in address: ${FG_LBLUE}$(formatLovelace ${lovelace})${NC} ADA"\
			"Minimum required: ${FG_LBLUE}$(formatLovelace ${min_fee})${NC} ADA"
    return 1
  fi

  tx_out="${addr}+${newBalance}${assets_tx_out}"
  getMinUTxO "${tx_out}" || return 1
  if [[ ${newBalance} -lt ${min_utxo_out} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: minimum UTxO value not fulfilled, only ${FG_LBLUE}$(formatLovelace ${newBalance})${NC} ADA left in address after tx fee, at least ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA required!"
    return 1
  fi

  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${tx_out}"
    --mint "-${assets_to_burn} ${policy_id}${asset_name_out}"
    --mint-script-file "${policy_script_file}"
    ${metafile_param}
    --invalid-hereafter ${ttl}
    --fee ${min_fee}
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${wallet_type} -eq 0 ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Asset Burning"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"policy-name\": \"${policy_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"policy-id\": \"${policy_id}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"asset-name\": \"${asset_name} ($(hexToAscii ${asset_name}))\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"asset-amount\": \"${assets_to_burn}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"asset-minted\": \"${asset_minted}\" }" <<< ${offlineJSON}); then return 1; fi
    if [[ -n ${metafile_param} ]]; then
      if ! offlineJSON=$(jq ". += { metadata: $(jq -c . "${metafile}") }" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ". += { txFee: \"${min_fee}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txBody: $(jq -c . "${TMP_DIR}"/tx.raw) }" <<< ${offlineJSON}); then return 1; fi
    if [[ ${wallet_type} -eq 5 ]]; then
      if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Wallet '${wallet_name}' payment script\", script: $(jq -c . "${payment_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
    else
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${wallet_name}' payment signing key\", vkey: $(jq -c . "${payment_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Asset '${policy_sk_file}' policy signing key\", vkey: $(jq -c . "${policy_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"signed-txBody\": {} }" <<< ${offlineJSON}); then return 1; fi
    offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"
    jq -r . <<< "${offlineJSON}" > "${offline_tx}"
    echo
    if [[ ${wallet_type} -eq 5 ]]; then
      println "Asset burn transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "Use CNTools [Transaction >> Sign] to witness the transaction with MultiSig wallet participants."
    else
      println "Offline transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "move file to offline computer and sign it using CNTools in offline mode '-o' [Transaction >> Sign] with:"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${payment_sk_file})${NC}"
      println DEBUG "Policy ${FG_GREEN}${policy_name} ${FG_LGRAY}$(basename ${policy_sk_file})${NC}"
    fi
    return 2 # return as failed to stop main processing and return to home menu
  fi

  if ! witnessTx "${TMP_DIR}/tx.raw" "${payment_sk_file}" "${policy_sk_file}"; then return 1; fi
  if ! assembleTx "${TMP_DIR}/tx.raw"; then return 1; fi
  if ! submitTx "${tx_signed}"; then return 1; fi
}

