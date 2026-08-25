# Command     : voteDelegation
# Description : delegate wallet to a DRep for governance actions
voteDelegation() {

  wallet_source="base"

  getWalletType ${wallet_name}
  wallet_type=$?

  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    utxo_cnt=${utxos_cnt[${base_addr}]}
    tx_in=${tx_in_arr[${base_addr}]}
  fi

  if [[ ${wallet_type} -eq 5 ]]; then
    op_mode=hybrid
    unset required_total
    validateMultiSigScript false "$(cat "${payment_script_file}")"
    witness_cnt=${required_total}
    unset required_total
    validateMultiSigScript false "$(cat "${stake_script_file}")"
    witness_cnt=$(( witness_cnt + required_total ))
    stake_param=("--stake-script-file" "${stake_script_file}")
  else
    witness_cnt=2
    stake_param=("--stake-verification-key-file" "${stake_vk_file}")
  fi

  vote_deleg_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_VOTE_DELEG_CERT_FILENAME}"
  VOTE_DELEG_CMD=(
    ${CCLI} latest stake-address vote-delegation-certificate
    "${stake_param[@]}"
    "${vote_param_arr[@]}"
    --out-file "${vote_deleg_cert_file}"
  )
  println ACTION "${VOTE_DELEG_CMD[*]}"
  if ! stdout=$("${VOTE_DELEG_CMD[@]}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during vote delegation certificate creation!\n${stdout}"; return 1
  fi

  if ! getTTL "$([[ ${wallet_type} -eq 5 ]] && echo true)"; then return 1; fi

  getAssetsTxOut

  unset script_args
  if [[ ${wallet_type} -eq 5 ]]; then
    script_args=(
      --tx-in-script-file "${payment_script_file}"
      --certificate-script-file "${stake_script_file}"
    )
  fi

  tmpNewBalance=${base_lovelace}
  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${base_addr}+${tmpNewBalance}${assets_tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    --certificate-file "${vote_deleg_cert_file}"
    --out-file "${TMP_DIR}"/tx0.tmp
  )

  buildTx || return 1

  calcMinFee "${TMP_DIR}"/tx0.tmp ${utxo_cnt} 1 ${witness_cnt} || return 1

  newBalance=$(( base_lovelace - min_fee ))
  println LOG "Balance left to be returned in used UTxO is $(formatLovelace ${newBalance}) ADA ( $(formatLovelace ${base_lovelace}) - $(formatLovelace ${min_fee}) )"

  if [[ ${base_lovelace} -lt ${min_fee} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA in base address for tx fee!"\
			"Funds in address: ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"\
			"Minimum required: ${FG_LBLUE}$(formatLovelace ${min_fee})${NC} ADA"
    return 1
  fi

  tx_out="${base_addr}+${newBalance}${assets_tx_out}"
  getMinUTxO "${tx_out}" || return 1
  if [[ ${newBalance} -lt ${min_utxo_out} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: minimum UTxO value not fulfilled, only ${FG_LBLUE}$(formatLovelace ${newBalance})${NC} ADA left in address after tx fee, at least ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA required!"
    return 1
  fi

  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${min_fee}
    --certificate-file "${vote_deleg_cert_file}"
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${wallet_type} -eq 0 ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Wallet Vote Delegation"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"drep-hash\": \"${drep_hash}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"drep-id-cip105\": \"${drep_id}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"drep-id-cip129\": \"${drep_id_cip129}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txFee: \"${min_fee}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txBody: $(jq -c . "${TMP_DIR}"/tx.raw) }" <<< ${offlineJSON}); then return 1; fi
    if [[ ${wallet_type} -eq 5 ]]; then
      if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Wallet '${wallet_name}' payment script\", script: $(jq -c . "${payment_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
      if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Wallet '${wallet_name}' stake script\", script: $(jq -c . "${stake_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
    else
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${wallet_name}' payment signing key\", vkey: $(jq -c . "${payment_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${wallet_name}' stake signing key\", vkey: $(jq -c . "${stake_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ". += { \"signed-txBody\": {} }" <<< ${offlineJSON}); then return 1; fi
    offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"
    jq -r . <<< "${offlineJSON}" > "${offline_tx}"
    echo
    if [[ ${wallet_type} -eq 5 ]]; then
      println "MultiSig wallet vote delegation transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "Use CNTools [Transaction >> Sign] to witness the transaction with MultiSig wallet participants."
    else
      println "Offline transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "move file to offline computer and sign it using CNTools in offline mode '-o' [Transaction >> Sign] with:"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${payment_sk_file})${NC}"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${stake_sk_file})${NC}"
    fi
    return 2 # return as failed to stop main processing and return to home menu
  fi

  if ! witnessTx "${TMP_DIR}/tx.raw" "${stake_sk_file}" "${payment_sk_file}"; then return 1; fi
  if ! assembleTx "${TMP_DIR}/tx.raw"; then return 1; fi
  if ! submitTx "${tx_signed}"; then return 1; fi
}

# Command     : registerDRep
# Description : register as a DRep
registerDRep() {

  getWalletType ${wallet_name}
  wallet_type=$?
  wallet_source="base"

  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    utxo_cnt=${utxos_cnt[${base_addr}]}
    tx_in=${tx_in_arr[${base_addr}]}
  fi

  if [[ ${hash_type} = "scriptHash" ]]; then
    op_mode=hybrid
    unset required_total
    validateMultiSigScript false "$(cat "${drep_script_file}")"
    witness_cnt=$(( required_total + 1 ))
  else
    witness_cnt=2
  fi

  if ! getTTL; then return 1; fi

  [[ ${is_update} = N ]] && println LOG "DRep deposit is ${FG_LBLUE}$(formatLovelace ${DREP_DEPOSIT})${NC}"

  getAssetsTxOut

  unset script_args
  if [[ ${hash_type} = "scriptHash" ]]; then
    script_args=(
      --certificate-script-file "${drep_script_file}"
    )
  fi

  if [[ ${is_update} = N ]]; then
    tmpNewBalance=$(( base_lovelace - DREP_DEPOSIT ))
  else
     tmpNewBalance=${base_lovelace}
  fi

  build_args=(
    ${tx_in}
    --tx-out "${base_addr}+${tmpNewBalance}${assets_tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    --certificate-file "${drep_cert_file}"
    "${script_args[@]}"
    --out-file "${TMP_DIR}"/tx0.tmp
  )

  buildTx || return 1

  calcMinFee "${TMP_DIR}"/tx0.tmp ${utxo_cnt} 1 ${witness_cnt} || return 1

  if [[ ${is_update} = N ]]; then
    fee=$(( DREP_DEPOSIT + min_fee ))
    newBalance=$(( base_lovelace - fee ))
    println LOG "New balance after DRep deposit and subtracted tx fee is $(formatLovelace ${newBalance}) ADA ($(formatLovelace ${base_lovelace}) - $(formatLovelace ${DREP_DEPOSIT}) - $(formatLovelace ${min_fee}))"
  else
    fee=${min_fee}
    newBalance=$(( base_lovelace - min_fee ))
    println LOG "New balance after subtracted tx fee is $(formatLovelace ${newBalance}) ADA ($(formatLovelace ${base_lovelace}) - $(formatLovelace ${min_fee}))"
  fi

  if [[ ${base_lovelace} -lt ${fee} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA in base address!"\
			"Funds in address: ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"\
			"Minimum required: ${FG_LBLUE}$(formatLovelace ${fee})${NC} ADA"
    return 1
  fi

  tx_out="${base_addr}+${newBalance}${assets_tx_out}"
  getMinUTxO "${tx_out}" || return 1
  if [[ ${newBalance} -lt ${min_utxo_out} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: minimum UTxO value not fulfilled, only ${FG_LBLUE}$(formatLovelace ${newBalance})${NC} ADA left in address after tx fee and DRep deposit, at least ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA required!"
    return 1
  fi

  build_args=(
    ${tx_in}
    --tx-out "${tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${min_fee}
    --certificate-file "${drep_cert_file}"
    "${script_args[@]}"
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${wallet_type} -eq 0 ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Wallet DRep Registration"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"drep-wallet-name\": \"${drep_wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txFee: \"${min_fee}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txBody: $(jq -c . "${TMP_DIR}"/tx.raw) }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${wallet_name}' payment signing key\", vkey: $(jq -c . "${payment_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    if [[ ${hash_type} = "scriptHash" ]]; then
      if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Wallet '${drep_wallet_name}' DRep script\", script: $(jq -c . "${drep_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
    else
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${drep_wallet_name}' DRep signing key\", vkey: $(jq -c . "${drep_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ". += { \"signed-txBody\": {} }" <<< ${offlineJSON}); then return 1; fi
    offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"
    jq -r . <<< "${offlineJSON}" > "${offline_tx}"
    echo
    if [[ ${hash_type} = "scriptHash" ]]; then
      println "MultiSig DRep registration transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "Use CNTools [Transaction >> Sign] to witness the transaction with fee wallet and MultiSig DRep participants."
    else
      println "Offline transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "move file to offline computer and sign it using CNTools in offline mode '-o' [Transaction >> Sign] with:"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${payment_sk_file})${NC}"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${drep_sk_file})${NC}"
    fi
    return 2 # return as failed to stop main processing and return to home menu
  fi

  if ! witnessTx "${TMP_DIR}/tx.raw" "${drep_sk_file}" "${payment_sk_file}"; then return 1; fi
  if ! assembleTx "${TMP_DIR}/tx.raw"; then return 1; fi
  if ! submitTx "${tx_signed}"; then return 1; fi
}

# Command     : retireDRep
# Description : retire as a DRep and get DRep deposit back
retireDRep() {

  getWalletType ${wallet_name}
  wallet_type=$?
  wallet_source="base"

  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    utxo_cnt=${utxos_cnt[${base_addr}]}
    tx_in=${tx_in_arr[${base_addr}]}
  fi

  if [[ ${hash_type} = "scriptHash" ]]; then
    op_mode=hybrid
    unset required_total
    validateMultiSigScript false "$(cat "${drep_script_file}")"
    witness_cnt=$(( required_total + 1 ))
  else
    witness_cnt=2
  fi

  if ! getTTL; then return 1; fi

  println LOG "DRep deposit to be returned is ${FG_LBLUE}$(formatLovelace ${drep_deposit_amt})${NC}"

  getAssetsTxOut

  unset script_args
  if [[ ${hash_type} = "scriptHash" ]]; then
    script_args=(
      --certificate-script-file "${drep_script_file}"
    )
  fi

  tmpNewBalance=$(( base_lovelace + drep_deposit_amt ))
  build_args=(
    ${tx_in}
    --tx-out "${base_addr}+${tmpNewBalance}${assets_tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    --certificate-file "${drep_cert_file}"
    "${script_args[@]}"
    --out-file "${TMP_DIR}"/tx0.tmp
  )

  buildTx || return 1

  calcMinFee "${TMP_DIR}"/tx0.tmp ${utxo_cnt} 1 ${witness_cnt} || return 1

  newBalance=$(( base_lovelace + drep_deposit_amt - min_fee ))
  println LOG "New balance after returned DRep deposit and subtracted tx fee is $(formatLovelace ${newBalance}) ADA ($(formatLovelace ${base_lovelace}) + $(formatLovelace ${drep_deposit_amt}) - $(formatLovelace ${min_fee}))"

  if [[ $(( base_lovelace + drep_deposit_amt )) -lt ${min_fee} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA in base address for tx fee!"\
			"Funds in address: ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"\
			"Returned deposit: ${FG_LBLUE}$(formatLovelace ${drep_deposit_amt})${NC} ADA"\
			"Minimum required: ${FG_LBLUE}$(formatLovelace ${min_fee} )))${NC} ADA"
    return 1
  fi

  tx_out="${base_addr}+${newBalance}${assets_tx_out}"
  getMinUTxO "${tx_out}" || return 1
  if [[ ${newBalance} -lt ${min_utxo_out} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: minimum UTxO value not fulfilled, only ${FG_LBLUE}$(formatLovelace ${newBalance})${NC} ADA left in address after tx fee and DRep deposit, at least ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA required!"
    return 1
  fi

  build_args=(
    ${tx_in}
    --tx-out "${tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${min_fee}
    --certificate-file "${drep_cert_file}"
    "${script_args[@]}"
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${wallet_type} -eq 0 ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Wallet DRep Retire"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"drep-wallet-name\": \"${drep_wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txFee: \"${min_fee}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txBody: $(jq -c . "${TMP_DIR}"/tx.raw) }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${wallet_name}' payment signing key\", vkey: $(jq -c . "${payment_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    if [[ ${hash_type} = "scriptHash" ]]; then
      if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Wallet '${drep_wallet_name}' DRep script\", script: $(jq -c . "${drep_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
    else
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${drep_wallet_name}' DRep signing key\", vkey: $(jq -c . "${drep_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ". += { \"signed-txBody\": {} }" <<< ${offlineJSON}); then return 1; fi
    offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"
    jq -r . <<< "${offlineJSON}" > "${offline_tx}"
    echo
    if [[ ${hash_type} = "scriptHash" ]]; then
      println "MultiSig DRep retire transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "Use CNTools [Transaction >> Sign] to witness the transaction with fee wallet and MultiSig DRep participants."
    else
      println "Offline transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "move file to offline computer and sign it using CNTools in offline mode '-o' [Transaction >> Sign] with:"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${payment_sk_file})${NC}"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${drep_sk_file})${NC}"
    fi
    return 2 # return as failed to stop main processing and return to home menu
  fi

  if ! witnessTx "${TMP_DIR}/tx.raw" "${drep_sk_file}" "${payment_sk_file}"; then return 1; fi
  if ! assembleTx "${TMP_DIR}/tx.raw"; then return 1; fi
  if ! submitTx "${tx_signed}"; then return 1; fi
}

# Command     : governanceVote
# Description : cast governance vote
governanceVote() {

  getWalletType ${wallet_name}
  wallet_type=$?
  wallet_source="base"

  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    utxo_cnt=${utxos_cnt[${base_addr}]}
    tx_in=${tx_in_arr[${base_addr}]}
  fi

  if [[ ${vote_mode} = "drep" && ${hash_type} = "scriptHash" ]]; then
    op_mode=hybrid
    unset required_total
    validateMultiSigScript false "$(cat "${drep_script_file}")"
    witness_cnt=$(( required_total + 1 ))
  else
    witness_cnt=2
  fi

  if ! getTTL; then return 1; fi

  getAssetsTxOut

  unset script_args
  if [[ ${vote_mode} = "drep" && ${hash_type} = "scriptHash" ]]; then
    script_args=(
      --tx-in-script-file "${drep_script_file}"
    )
  fi

  tmpNewBalance=${base_lovelace}
  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${base_addr}+${tmpNewBalance}${assets_tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    --vote-file "${vote_file}"
    --out-file "${TMP_DIR}"/tx0.tmp
  )

  buildTx || return 1

  calcMinFee "${TMP_DIR}"/tx0.tmp ${utxo_cnt} 1 ${witness_cnt} || return 1

  newBalance=$(( base_lovelace - min_fee ))
  println LOG "New balance after subtracted tx fee is $(formatLovelace ${newBalance}) ADA ($(formatLovelace ${base_lovelace}) - $(formatLovelace ${min_fee}))"

  if [[ ${base_lovelace} -lt ${min_fee} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA in base address!"\
			"Funds in address: ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"\
			"Minimum required: ${FG_LBLUE}$(formatLovelace ${min_fee})${NC} ADA"
    return 1
  fi

  tx_out="${base_addr}+${newBalance}${assets_tx_out}"
  getMinUTxO "${tx_out}" || return 1
  if [[ ${newBalance} -lt ${min_utxo_out} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: minimum UTxO value not fulfilled, only ${FG_LBLUE}$(formatLovelace ${newBalance})${NC} ADA left in address after tx fee, at least ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA required!"
    return 1
  fi

  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${min_fee}
    --vote-file "${vote_file}"
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${wallet_type} -eq 0 ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Wallet Governance Vote"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"action-id\": \"${action_id}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"action-id-cip129\": \"${action_id_cip129}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { vote: \"${vote_param//-}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txFee: \"${min_fee}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txBody: $(jq -c . "${TMP_DIR}"/tx.raw) }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${wallet_name}' payment signing key\", vkey: $(jq -c . "${payment_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    if [[ ${vote_mode} = "spo" ]]; then
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Pool '${pool_name}' cold signing key\", vkey: $(jq -c . "${pool_coldkey_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    elif [[ ${vote_mode} = "drep" ]]; then
      if ! offlineJSON=$(jq ". += { \"drep-wallet-name\": \"${drep_wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
      if [[ ${hash_type} = "scriptHash" ]]; then
        if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Wallet '${drep_wallet_name}' DRep script\", script: $(jq -c . "${drep_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
      else
        if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${drep_wallet_name}' DRep signing key\", vkey: $(jq -c . "${drep_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
      fi
    else
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${wallet_name}' committee hot signing key\", vkey: $(jq -c . "${cc_hot_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ". += { \"signed-txBody\": {} }" <<< ${offlineJSON}); then return 1; fi
    offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"
    jq -r . <<< "${offlineJSON}" > "${offline_tx}"
    echo
    if [[ ${vote_mode} = "drep" && ${hash_type} = "scriptHash" ]]; then
      println "MultiSig DRep vote transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "Use CNTools [Transaction >> Sign] to witness the transaction with fee wallet and MultiSig DRep participants."
    else
      println "Offline transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "move file to offline computer and sign it using CNTools in offline mode '-o' [Transaction >> Sign] with:"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${payment_sk_file})${NC}"
      if [[ ${vote_mode} = "spo" ]]; then
        println DEBUG "Pool ${FG_GREEN}${pool_name} ${FG_LGRAY}$(basename ${pool_coldkey_sk_file})${NC}"
      elif [[ ${vote_mode} = "drep" ]]; then
        println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${drep_sk_file})${NC}"
      else
        println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${cc_hot_sk_file})${NC}"
      fi
    fi
    return 2 # return as failed to stop main processing and return to home menu
  fi

  if [[ ${vote_mode} = "spo" ]]; then
    vote_key="${pool_coldkey_sk_file}"
  elif [[ ${vote_mode} = "drep" ]]; then
    vote_key="${drep_sk_file}"
  else
    vote_key="${cc_hot_sk_file}"
  fi
  if ! witnessTx "${TMP_DIR}/tx.raw" "${vote_key}" "${payment_sk_file}"; then return 1; fi
  if ! assembleTx "${TMP_DIR}/tx.raw"; then return 1; fi
  if ! submitTx "${tx_signed}"; then return 1; fi
}

