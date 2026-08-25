# Command     : registerPool
# Description : Register pool with pledge on chain
registerPool() {

  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    utxo_cnt=${utxos_cnt[${base_addr}]}
    tx_in=${tx_in_arr[${base_addr}]}
  fi

  println LOG "Pool Deposit is ${POOL_DEPOSIT}"

  owner_delegation_cert=""
  [[ ${delegate_owner_wallet} = 'Y' ]] && owner_delegation_cert="--certificate-file ${owner_delegation_cert_file}"

  # owner payment + cold + multi-owners(main owner included)
  unset witness_cnt hasScriptOwner
  script_args=()
  for index in "${!owner_wallets[@]}"; do
    getWalletType ${owner_wallets[${index}]}
    if [[ ${wallet_type} -eq 5 ]]; then
      op_mode=hybrid
      hasScriptOwner=true
      if [[ ${index} -eq 0 ]]; then
        unset required_total
        validateMultiSigScript false "$(cat "${payment_script_file}")"
        witness_cnt=${required_total}
        script_args+=( --tx-in-script-file "${payment_script_file}" )
      fi
      unset required_total
      validateMultiSigScript false "$(cat "${stake_script_file}")"
      witness_cnt=$(( witness_cnt + required_total ))
      script_args+=( --certificate-script-file "${stake_script_file}" )
    else
      [[ ${index} -eq 0 ]] && witness_cnt=1
      witness_cnt=$(( witness_cnt + 1 ))
    fi
  done
  witness_cnt=$(( witness_cnt + 1 )) # cold key witness

  if ! getTTL "$([[ ${hasScriptOwner} = true ]] && echo true)"; then return 1; fi

  owner_delegation_cert=""
  if [[ ${delegate_owner_wallet} = 'Y' ]]; then
    owner_delegation_cert="${owner_delegation_cert_file}"
  fi

  getAssetsTxOut

  tmpNewBalance=$(( base_lovelace - POOL_DEPOSIT ))
  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${base_addr}+${tmpNewBalance}${assets_tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    --certificate-file "${pool_regcert_file}"
    --out-file "${TMP_DIR}"/tx0.tmp
  )
  [[ -n ${owner_delegation_cert} ]] && build_args+=( --certificate-file "${owner_delegation_cert}" )

  buildTx || return 1

  calcMinFee "${TMP_DIR}"/tx0.tmp ${utxo_cnt} 1 ${witness_cnt} || return 1

  newBalance=$(( base_lovelace - min_fee - POOL_DEPOSIT ))
  println LOG "Balance left to be returned in used UTxO is $(formatLovelace ${newBalance}) ADA ( $(formatLovelace ${base_lovelace}) - $(formatLovelace ${min_fee}) - $(formatLovelace ${POOL_DEPOSIT}) )"

  if [[ ${base_lovelace} -lt $(( min_fee + POOL_DEPOSIT )) ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA in base address for tx fee and pool registration deposit!"\
			"Funds in address: ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"\
			"Minimum required: ${FG_LBLUE}$(formatLovelace $(( min_fee + POOL_DEPOSIT )))${NC} ADA"
    return 1
  fi

  tx_out="${base_addr}+${newBalance}${assets_tx_out}"
  getMinUTxO "${tx_out}" || return 1
  if [[ ${newBalance} -lt ${min_utxo_out} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: minimum UTxO value not fulfilled, only ${FG_LBLUE}$(formatLovelace ${newBalance})${NC} ADA left in address after tx fee and pool registration deposit, at least ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA required!"
    return 1
  fi

  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${min_fee}
    --certificate-file "${pool_regcert_file}"
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )
  [[ -n ${owner_delegation_cert} ]] && build_args+=( --certificate-file "${owner_delegation_cert}" )

  if [[ ${hw_owner_wallets} = 'Y' || ${hw_reward_wallet} = 'Y' || ${isHWpool} = 'Y' ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Pool Registration"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"pool-name\": \"${pool_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"pool-metadata\": $(jq -c . "${pool_meta_file}") }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"pool-pledge\": \"${pledge_ada}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"pool-margin\": \"${margin}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"pool-cost\": \"${cost_ada}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"pool-reg-cert\": $(jq -c . "${pool_regcert_file}") }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txFee: \"$(( min_fee + POOL_DEPOSIT ))\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txBody: $(jq -c . "${TMP_DIR}"/tx.raw) }" <<< ${offlineJSON}); then return 1; fi
    for index in "${!owner_wallets[@]}"; do
      getWalletType ${owner_wallets[${index}]}
      if [[ ${index} -eq 0 ]]; then
        if [[ ${wallet_type} -eq 5 ]]; then
          if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Owner #1 '${owner_wallets[0]}' payment script\", script: $(jq -c . "${payment_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
        else
          if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Owner #1 '${owner_wallets[0]}' payment signing key\", vkey: $(jq -c . "${payment_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
        fi
      fi
      if [[ ${wallet_type} -eq 5 ]]; then
        if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Owner #$((index+1)) '${owner_wallets[${index}]}' stake script\", script: $(jq -c . "${stake_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
      else
        if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Owner #$((index+1)) '${owner_wallets[${index}]}' stake signing key\", vkey: $(jq -c . "${stake_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
      fi
    done
    if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Pool '${pool_name}' cold signing key\", vkey: $(jq -c . "${pool_coldkey_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"signed-txBody\": {} }" <<< ${offlineJSON}); then return 1; fi
    offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"
    jq -r . <<< "${offlineJSON}" > "${offline_tx}"
    echo
    if [[ ${hasScriptOwner} = true ]]; then
      println "Pool registration transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "Use CNTools [Transaction >> Sign] to witness the transaction with owner wallets and pool cold key."
    else
      println "Offline transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "move file to offline computer and sign it using CNTools in offline mode '-o' [Transaction >> Sign] with:"
      println DEBUG "Pool ${FG_GREEN}${pool_name} ${FG_LGRAY}${POOL_COLDKEY_SK_FILENAME}${NC}"
      println DEBUG "Owner #1 ${FG_GREEN}${owner_wallets[0]} ${FG_LGRAY}${WALLET_PAY_SK_FILENAME}${NC} & ${FG_LGRAY}${WALLET_STAKE_SK_FILENAME}${NC}"
      for index in "${!owner_wallets[@]}"; do
        [[ ${index} -eq 0 ]] && continue # skip main owner
        println DEBUG "Owner #$((index+1)) ${FG_GREEN}${owner_wallets[${index}]} ${FG_LGRAY}${WALLET_STAKE_SK_FILENAME}${NC}"
      done
    fi
    return 2 # return as failed to stop main processing and return to home menu
  fi

  multi_owner_keys=()
  for index in "${!owner_wallets[@]}"; do
    [[ ${index} -eq 0 ]] && continue # skip main owner
    getWalletType ${owner_wallets[${index}]}
    multi_owner_keys+=( "${stake_sk_file}" )
  done

  if ! witnessTx "${TMP_DIR}/tx.raw" "${owner_payment_sk_file}" "${pool_coldkey_sk_file}" "${owner_stake_sk_file}" "${multi_owner_keys[@]}"; then return 1; fi
  if ! assembleTx "${TMP_DIR}/tx.raw"; then return 1; fi
  if ! submitTx "${tx_signed}"; then return 1; fi
}


# Command     : modifyPool
# Description : Register pool with pledge on chain
modifyPool() {

  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    utxo_cnt=${utxos_cnt[${base_addr}]}
    tx_in=${tx_in_arr[${base_addr}]}
  fi

  # owner payment + cold + multi-owners(main owner included)
  unset witness_cnt hasScriptOwner
  script_args=()
  for index in "${!owner_wallets[@]}"; do
    getWalletType ${owner_wallets[${index}]}
    if [[ ${wallet_type} -eq 5 ]]; then
      op_mode=hybrid
      hasScriptOwner=true
      if [[ ${index} -eq 0 ]]; then
        unset required_total
        validateMultiSigScript false "$(cat "${payment_script_file}")"
        witness_cnt=${required_total}
        script_args+=( --tx-in-script-file "${payment_script_file}" )
      fi
      unset required_total
      validateMultiSigScript false "$(cat "${stake_script_file}")"
      witness_cnt=$(( witness_cnt + required_total ))
      script_args+=( --certificate-script-file "${stake_script_file}" )
    else
      [[ ${index} -eq 0 ]] && witness_cnt=1
      witness_cnt=$(( witness_cnt + 1 ))
    fi
  done
  witness_cnt=$(( witness_cnt + 1 )) # cold key witness

  if ! getTTL "$([[ ${hasScriptOwner} = true ]] && echo true)"; then return 1; fi

  getAssetsTxOut

  tmpNewBalance=${base_lovelace}
  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${base_addr}+${tmpNewBalance}${assets_tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    --certificate-file "${pool_regcert_file}"
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
    --certificate-file "${pool_regcert_file}"
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${hw_owner_wallets} = 'Y' || ${hw_reward_wallet} = 'Y' || ${isHWpool} = 'Y' ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Pool Update"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"pool-name\": \"${pool_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"pool-metadata\": $(jq -c . "${pool_meta_file}") }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"pool-pledge\": \"${pledge_ada}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"pool-margin\": \"${margin}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"pool-cost\": \"${cost_ada}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"pool-reg-cert\": $(jq -c . "${pool_regcert_file}") }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txFee: \"${min_fee}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txBody: $(jq -c . "${TMP_DIR}"/tx.raw) }" <<< ${offlineJSON}); then return 1; fi
    for index in "${!owner_wallets[@]}"; do
      getWalletType ${owner_wallets[${index}]}
      if [[ ${index} -eq 0 ]]; then
        if [[ ${wallet_type} -eq 5 ]]; then
          if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Owner #1 '${owner_wallets[0]}' payment script\", script: $(jq -c . "${payment_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
        else
          if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Owner #1 '${owner_wallets[0]}' payment signing key\", vkey: $(jq -c . "${payment_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
        fi
      fi
      if [[ ${wallet_type} -eq 5 ]]; then
        if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Owner #$((index+1)) '${owner_wallets[${index}]}' stake script\", script: $(jq -c . "${stake_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
      else
        if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Owner #$((index+1)) '${owner_wallets[${index}]}' stake signing key\", vkey: $(jq -c . "${stake_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
      fi
    done
    if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Pool '${pool_name}' cold signing key\", vkey: $(jq -c . "${pool_coldkey_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"signed-txBody\": {} }" <<< ${offlineJSON}); then return 1; fi
    offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"
    jq -r . <<< "${offlineJSON}" > "${offline_tx}"
    echo
    if [[ ${hasScriptOwner} = true ]]; then
      println "Pool update transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "Use CNTools [Transaction >> Sign] to witness the transaction with owner wallets and pool cold key."
    else
      println "Offline transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "move file to offline computer and sign it using CNTools in offline mode '-o' [Transaction >> Sign] with:"
      println DEBUG "Pool ${FG_GREEN}${pool_name} ${FG_LGRAY}${POOL_COLDKEY_SK_FILENAME}${NC}"
      println DEBUG "Owner #1 ${FG_GREEN}${owner_wallets[0]} ${FG_LGRAY}${WALLET_PAY_SK_FILENAME}${NC} & ${FG_LGRAY}${WALLET_STAKE_SK_FILENAME}${NC}"
      for index in "${!owner_wallets[@]}"; do
        [[ ${index} -eq 0 ]] && continue # skip main owner
        println DEBUG "Owner #$((index+1)) ${FG_GREEN}${owner_wallets[${index}]} ${FG_LGRAY}${WALLET_STAKE_SK_FILENAME}${NC}"
      done
    fi
    return 2 # return as failed to stop main processing and return to home menu
  fi

  multi_owner_keys=()
  for index in "${!owner_wallets[@]}"; do
    [[ ${index} -eq 0 ]] && continue # skip main owner
    getWalletType ${owner_wallets[${index}]}
    multi_owner_keys+=( "${stake_sk_file}" )
  done

  if ! witnessTx "${TMP_DIR}/tx.raw" "${owner_payment_sk_file}" "${pool_coldkey_sk_file}" "${owner_stake_sk_file}" "${multi_owner_keys[@]}"; then return 1; fi
  if ! assembleTx "${TMP_DIR}/tx.raw"; then return 1; fi
  if ! submitTx "${tx_signed}"; then return 1; fi
}

# Command     : deRegisterPool
# Description : Retire pool
deRegisterPool() {

  [[ $(cat "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}" 2>/dev/null) = "${addr}" ]] && wallet_source="payment" || wallet_source="base"

  getWalletType ${wallet_name}
  wallet_type=$?

  if [[ ${wallet_type} -eq 5 ]]; then
    op_mode=hybrid
    unset required_total
    validateMultiSigScript false "$(cat "${payment_script_file}")"
    witness_cnt=$(( required_total + 1 ))
  else
    witness_cnt=2
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
    --certificate-file "${pool_deregcert_file}"
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
    --invalid-hereafter ${ttl}
    --fee ${min_fee}
    --certificate-file "${pool_deregcert_file}"
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${wallet_type} -eq 0 ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Pool De-Registration"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if [[ -f "${POOL_FOLDER}/${pool_name}/poolmeta.json" ]]; then
      if ! offlineJSON=$(jq ". += { \"pool-name\": \"$(jq -r .name "${POOL_FOLDER}/${pool_name}/poolmeta.json")\" }" <<< ${offlineJSON}); then return 1; fi
      if ! offlineJSON=$(jq ". += { \"pool-ticker\": \"$(jq -r .ticker "${POOL_FOLDER}/${pool_name}/poolmeta.json")\" }" <<< ${offlineJSON}); then return 1; fi
    else
      if ! offlineJSON=$(jq ". += { \"pool-name\": \"${pool_name}\" }" <<< ${offlineJSON}); then return 1; fi
      if ! offlineJSON=$(jq ". += { \"pool-ticker\": \"\" }" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ". += { \"retire-epoch\": \"${epoch_enter}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txFee: \"${min_fee}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txBody: $(jq -c . "${TMP_DIR}"/tx.raw) }" <<< ${offlineJSON}); then return 1; fi
    if [[ ${wallet_type} -eq 5 ]]; then
      if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Wallet '${wallet_name}' payment script\", script: $(jq -c . "${payment_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
    else
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${wallet_name}' payment signing key\", vkey: $(jq -c . "${payment_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Pool '${pool_name}' cold signing key\", vkey: $(jq -c . "${pool_coldkey_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"signed-txBody\": {} }" <<< ${offlineJSON}); then return 1; fi
    offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"
    jq -r . <<< "${offlineJSON}" > "${offline_tx}"
    echo
    if [[ ${wallet_type} -eq 5 ]]; then
      println "Pool de-registration transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "Use CNTools [Transaction >> Sign] to witness the transaction with MultiSig wallet participants."
    else
      println "Offline transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "move file to offline computer and sign it using CNTools in offline mode '-o' [Transaction >> Sign] with:"
      println DEBUG "Wallet ${FG_GREEN}${wallet_name} ${FG_LGRAY}$(basename ${payment_sk_file})${NC}"
      println DEBUG "Pool ${FG_GREEN}${pool_name} ${FG_LGRAY}$(basename ${pool_coldkey_sk_file})${NC}"
    fi
    return 2 # return as failed to stop main processing and return to home menu
  fi

  if ! witnessTx "${TMP_DIR}/tx.raw" "${payment_sk_file}" "${pool_coldkey_sk_file}"; then return 1; fi
  if ! assembleTx "${TMP_DIR}/tx.raw"; then return 1; fi
  if ! submitTx "${tx_signed}"; then return 1; fi
}

# Command     : rotatePoolKeys
# Description : Rotate pool's KES keys
# parameters  : $1 = cold counter (offline mode)
rotatePoolKeys() {

  # cold keys
  if getPoolType ${pool_name}; then needHWCLI="true"; else needHWCLI="false" ;fi

  # generated files
  pool_hotkey_vk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_VK_FILENAME}"
  pool_hotkey_sk_file="${POOL_FOLDER}/${pool_name}/${POOL_HOTKEY_SK_FILENAME}"
  pool_opcert_counter_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_COUNTER_FILENAME}"
  pool_saved_kes_start="${POOL_FOLDER}/${pool_name}/${POOL_CURRENT_KES_START}"
  pool_opcert_file="${POOL_FOLDER}/${pool_name}/${POOL_OPCERT_FILENAME}"

  if [[ ! -f ${pool_coldkey_vk_file} ]]; then # lets re-generate it from cold signing key
    println ACTION "${CCLI} key verification-key --signing-key-file ${pool_coldkey_sk_file} --verification-key-file ${pool_coldkey_vk_file}"
    if ! stdout=$(${CCLI} key verification-key --signing-key-file "${pool_coldkey_sk_file}" --verification-key-file "${pool_coldkey_vk_file}" 2>&1); then
      println ERROR "\n${FG_RED}ERROR${NC}: failure during cold verification key creation!\n${stdout}"; return 1
    fi
    println ACTION "jq '.description = \"Stake Pool Operator Verification Key\"' ${pool_coldkey_vk_file}"
    if ! stdout=$(jq '.description = "Stake Pool Operator Verification Key"' "${pool_coldkey_vk_file}" 2>&1); then
      println ERROR "\n${FG_RED}ERROR${NC}: failure during cold verification key description update!\n${stdout}"; return 1
    else
      jq <<< ${stdout} > "${pool_coldkey_vk_file}"
    fi
  fi

  current_kes_period=$(getCurrentKESperiod)
  echo "${current_kes_period}" > ${pool_saved_kes_start}

  println ACTION "${CCLI} node key-gen-KES --verification-key-file ${pool_hotkey_vk_file} --signing-key-file ${pool_hotkey_sk_file}"
  if ! stdout=$(${CCLI} node key-gen-KES --verification-key-file "${pool_hotkey_vk_file}" --signing-key-file "${pool_hotkey_sk_file}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during KES key creation!\n${stdout}"; return 1
  fi

  p_opcert=""
  if [[ $# -eq 1 ]]; then
    println ACTION "${CCLI} node new-counter --cold-verification-key-file ${pool_coldkey_vk_file} --counter-value $1 --operational-certificate-issue-counter-file ${pool_opcert_counter_file}"
    if ! stdout=$(${CCLI} node new-counter --cold-verification-key-file "${pool_coldkey_vk_file}" --counter-value $1 --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" 2>&1); then
      println ERROR "\n${FG_RED}ERROR${NC}: failure during operational certificate counter creation!\n${stdout}"; return 1
    fi
  elif [[ -n ${KOIOS_API} ]]; then
    ! getPoolID "${pool_name}" && println "ERROR" "\n${FG_RED}ERROR${NC}: failed to get pool ID!\n" && return 1
    HEADERS=("${KOIOS_API_HEADERS[@]}" -H "Content-Type: application/json")
    println ACTION "curl -sSL -f -X POST ${HEADERS[*]} -d '{\"_pool_bech32_ids\":[\"${pool_id_bech32}\"]}' ${KOIOS_API}/pool_info"
    ! pool_info=$(curl -sSL -f -X POST "${HEADERS[@]}" -d '{"_pool_bech32_ids":["'${pool_id_bech32}'"]}' "${KOIOS_API}/pool_info" 2>&1) && println "ERROR" "\n${FG_RED}KOIOS_API ERROR${NC}: ${pool_info}\n" && p_opcert="" # print error but ignore
    if old_counter_nbr=$(jq -er '.[0].op_cert_counter' <<< "${pool_info}" 2>/dev/null); then
      new_counter_nbr=$(( old_counter_nbr + 1 ))
    else
      new_counter_nbr=0 # null returned = no block on chain for this pool
    fi
    println ACTION "${CCLI} node new-counter --cold-verification-key-file ${pool_coldkey_vk_file} --counter-value ${new_counter_nbr} --operational-certificate-issue-counter-file ${pool_opcert_counter_file}"
    if ! stdout=$(${CCLI} node new-counter --cold-verification-key-file "${pool_coldkey_vk_file}" --counter-value ${new_counter_nbr} --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" 2>&1); then
      println ERROR "\n${FG_RED}ERROR${NC}: failure during operational certificate counter creation!\n${stdout}"; return 1
    fi
  elif [[ -f ${pool_opcert_file} ]]; then
    println ACTION "${CCLI} query kes-period-info --op-cert-file ${pool_opcert_file} ${NETWORK_IDENTIFIER}"
    if ! kes_period_info=$(${CCLI} query kes-period-info --op-cert-file "${pool_opcert_file}" ${NETWORK_IDENTIFIER}); then
      println "ERROR" "\n${FG_RED}ERROR${NC}: failed to grab counter from node: [${kes_period_info}]\n" && return 1
    fi
    if old_counter_nbr=$(awk '/{/,0' <<< "${kes_period_info}" | jq -er '.qKesNodeStateOperationalCertificateNumber' 2>/dev/null); then
      new_counter_nbr=$(( old_counter_nbr + 1 ))
    else
      new_counter_nbr=0 # null returned = no block on chain for this pool
    fi
    println ACTION "${CCLI} node new-counter --cold-verification-key-file ${pool_coldkey_vk_file} --counter-value ${new_counter_nbr} --operational-certificate-issue-counter-file ${pool_opcert_counter_file}"
    if ! stdout=$(${CCLI} node new-counter --cold-verification-key-file "${pool_coldkey_vk_file}" --counter-value ${new_counter_nbr} --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" 2>&1); then
      println ERROR "\n${FG_RED}ERROR${NC}: failure during operational certificate counter creation!\n${stdout}"; return 1
    fi
  else
    println "ERROR" "\n${FG_RED}ERROR${NC}: op cert file missing and Koios disabled/unavailable. Unable to get current on-chain counter value!\n" && return 1
  fi

  if [[ ${needHWCLI} = true ]]; then
    if ! unlockHWDevice "issue the opcert"; then return 1; fi
    println ACTION "cardano-hw-cli node issue-op-cert --kes-verification-key-file ${pool_hotkey_vk_file} --hw-signing-file ${pool_coldkey_sk_file} --operational-certificate-issue-counter-file ${pool_opcert_counter_file} --kes-period ${current_kes_period} --out-file ${pool_opcert_file}"
    if ! stdout=$(cardano-hw-cli node issue-op-cert \
    --kes-verification-key-file "${pool_hotkey_vk_file}" \
    --hw-signing-file "${pool_coldkey_sk_file}" \
    --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" \
    --kes-period "${current_kes_period}" \
    --out-file "${pool_opcert_file}" 2>&1); then
      println ERROR "\n${FG_RED}ERROR${NC}: failure during hardware operational certificate creation!\n${stdout}"; return 1
    fi
  else
    println ACTION "${CCLI} node issue-op-cert --kes-verification-key-file ${pool_hotkey_vk_file} --cold-signing-key-file ${pool_coldkey_sk_file} --operational-certificate-issue-counter-file ${pool_opcert_counter_file} --kes-period ${current_kes_period} --out-file ${pool_opcert_file}"
    if ! stdout=$(${CCLI} node issue-op-cert --kes-verification-key-file "${pool_hotkey_vk_file}" --cold-signing-key-file "${pool_coldkey_sk_file}" --operational-certificate-issue-counter-file "${pool_opcert_counter_file}" --kes-period "${current_kes_period}" --out-file "${pool_opcert_file}" 2>&1); then
      println ERROR "\n${FG_RED}ERROR${NC}: failure during operational certificate creation!\n${stdout}"; return 1
    fi
  fi

  chmod 700 ${POOL_FOLDER}/${pool_name}/*

  unset remaining_kes_periods
  kesExpiration ${current_kes_period}
}

