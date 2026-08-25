# Command     : sendAssets
# Description : send Assets from source to destination
#             : can also be used to defrag address by sending all to self
#             : supports fee to be payed by sender(default) or receiver by reducing amount to send
sendAssets() {

  [[ $(cat "${WALLET_FOLDER}/${s_wallet}/${WALLET_PAY_ADDR_FILENAME}" 2>/dev/null) = "${s_addr}" ]] && wallet_source="payment" || wallet_source="base"

  getWalletType ${s_wallet}
  wallet_type=$?

  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    utxo_cnt=${utxos_cnt[${s_addr}]}
    tx_in=${tx_in_arr[${s_addr}]}
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

  if [[ -n ${metafile} && -f ${metafile} ]]; then
    metafile_param="--json-metadata-no-schema --metadata-json-file ${metafile}"
  else
    metafile_param=""
  fi

  [[ ${#assets_left[@]} -eq 0 ]] && outCount=1 || outCount=2

  assets_tx_out_s=""
  assets_tx_out_d=""
  for idx in "${!assets_left[@]}"; do
    [[ ${idx} = "lovelace" ]] && continue
    [[ ${assets_left[${idx}]} -gt 0 ]] && assets_tx_out_s+="+${assets_left[${idx}]} ${idx}"
  done
  for idx in "${!assets_to_send[@]}"; do
    [[ ${idx} = "lovelace" ]] && continue
    [[ ${assets_to_send[${idx}]} -gt 0 ]] && assets_tx_out_d+="+${assets_to_send[${idx}]} ${idx}"
  done

  unset script_args
  if [[ ${wallet_type} -eq 5 ]]; then
    script_args=( --tx-in-script-file "${payment_script_file}" )
  fi

  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    ${metafile_param}
    --out-file "${TMP_DIR}"/tx0.tmp
  )
  if [[ ${outCount} -eq 1 ]]; then
    build_args+=( --tx-out "${d_addr}+${assets_to_send[lovelace]}${assets_tx_out_d}" )
  else
    build_args+=( --tx-out "${s_addr}+${assets_left[lovelace]}${assets_tx_out_s}" --tx-out "${d_addr}+${assets_to_send[lovelace]}${assets_tx_out_d}" )
  fi

  buildTx || return 1

  calcMinFee "${TMP_DIR}"/tx0.tmp ${utxo_cnt} ${outCount} ${witness_cnt} || return 1

  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --invalid-hereafter ${ttl}
    --fee ${min_fee}
    ${metafile_param}
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${outCount} -eq 1 ]]; then # all assets to destination, nothing to return
    newBalance=0
    tx_out="${d_addr}+$(( ${assets_to_send[lovelace]} - min_fee ))${assets_tx_out_d}"
    getMinUTxO "${tx_out}" || return 1
    if [[ ${assets_to_send[lovelace]} -lt ${min_utxo_out} ]]; then
      println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA in address ( $(formatLovelace ${assets_to_send[lovelace]}) < $(formatLovelace ${min_utxo_out}) )"
      println ERROR "Top up wallet with enough ADA to cover minimum UTxO balance"
      return 1
    fi
    build_args+=( --tx-out "${tx_out}" )
  else
    if [[ ${include_fee} = "no" ]]; then
      newBalance=$(( ${assets[${index_prefix}lovelace]} - ${assets_to_send[lovelace]} - min_fee ))
      tx_out_d="${d_addr}+${assets_to_send[lovelace]}${assets_tx_out_d}"
    else
      newBalance=$(( ${assets[${index_prefix}lovelace]} - ${assets_to_send[lovelace]} ))
      tx_out_d="${d_addr}+$(( ${assets_to_send[lovelace]} - min_fee ))${assets_tx_out_d}"
    fi
    getMinUTxO "${tx_out_d}"
    min_utxo_out_d=${min_utxo_out}
    build_args+=( --tx-out "${tx_out_d}" )

    tx_out_s="${s_addr}+${newBalance}${assets_tx_out_s}"
    getMinUTxO "${tx_out_s}"
    min_utxo_out_s=${min_utxo_out}
    build_args+=( --tx-out "${tx_out_s}" )

    if [[ ${newBalance} -lt ${min_utxo_out_s} ]]; then
      println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA left in source address ( $(formatLovelace ${newBalance}) < $(formatLovelace ${min_utxo_out_s}) )"
      println ERROR "Send all ADA or top up wallet with enough ADA to cover minimum UTxO balance"
      return 1
    elif [[ ${assets_to_send[lovelace]} -lt ${min_utxo_out_d} ]]; then
      println ERROR "\n${FG_RED}ERROR${NC}: minimum UTxO value not fulfilled, requires ${FG_LBLUE}$(formatLovelace ${min_utxo_out_d})${NC} ADA to be sent along!"
      return 1
    fi
  fi

  if [[ ${wallet_type} -eq 0 ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Payment"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${s_wallet}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"source-address\": \"${s_addr}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"destination-address\": \"${d_addr}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { "assets": [] }" <<< ${offlineJSON}); then return 1; fi
    for idx in "${!assets_to_send[@]}"; do
      [[ ${assets_to_send[${idx}]} -gt 0 ]] && if ! offlineJSON=$(jq "."assets" += [{ asset: \"${idx}\", amount: \"${assets_to_send[${idx}]}\" }]" <<< ${offlineJSON}); then return 1; fi
    done
    if [[ -n ${metafile_param} ]]; then
      if ! offlineJSON=$(jq ". += { metadata: $(jq -c . "${metafile}") }" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ". += { txFee: \"${min_fee}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txBody: $(jq -c . "${TMP_DIR}"/tx.raw) }" <<< ${offlineJSON}); then return 1; fi
    if [[ ${wallet_type} -eq 5 ]]; then
      if ! offlineJSON=$(jq ".\"script-file\" += [{ name: \"Wallet '${s_wallet}' payment script\", script: $(jq -c . "${payment_script_file}") }]" <<< ${offlineJSON}); then return 1; fi
    else
      if ! offlineJSON=$(jq ".\"signing-file\" += [{ name: \"Wallet '${s_wallet}' payment signing key\", vkey: $(jq -c . "${s_payment_vk_file}") }]" <<< ${offlineJSON}); then return 1; fi
    fi
    if ! offlineJSON=$(jq ". += { \"signed-txBody\": {} }" <<< ${offlineJSON}); then return 1; fi
    offline_tx="${TMP_DIR}/offline_tx_$(jq -r .id <<< ${offlineJSON}).json"
    jq -r . <<< "${offlineJSON}" > "${offline_tx}"
    echo
    if [[ ${wallet_type} -eq 5 ]]; then
      println "MultiSig wallet transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "Use CNTools [Transaction >> Sign] to witness the transaction with MultiSig wallet participants."
    else
      println "Offline transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
      println DEBUG "move file to offline computer and sign it using CNTools in offline mode '-o' [Transaction >> Sign] with:"
      println DEBUG "Source Wallet ${FG_GREEN}${s_wallet} ${FG_LGRAY}$(basename ${s_payment_sk_file})${NC}"
    fi
    return 2 # return as failed to stop main processing and return to home menu
  fi

  if ! witnessTx "${TMP_DIR}/tx.raw" "${s_payment_sk_file}"; then return 1; fi
  if ! assembleTx "${TMP_DIR}/tx.raw"; then return 1; fi
  if ! submitTx "${tx_signed}"; then return 1; fi
}

# Command     : Delegate
# Description : Register pool with pledge on chain
delegate() {

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

  pool_delegcert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DELEGCERT_FILENAME}"
  println ACTION "${CCLI} latest stake-address stake-delegation-certificate ${stake_param[*]} --stake-pool-id ${pool_id} --out-file ${pool_delegcert_file}"
  if ! stdout=$(${CCLI} latest stake-address stake-delegation-certificate "${stake_param[@]}" --stake-pool-id "${pool_id}" --out-file "${pool_delegcert_file}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during stake delegation certificate creation!\n${stdout}"; return 1
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
    --certificate-file "${pool_delegcert_file}"
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
    --certificate-file "${pool_delegcert_file}"
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${wallet_type} -eq 0 ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Wallet Delegation"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"pool-id\": \"${pool_id}\" }" <<< ${offlineJSON}); then return 1; fi
    if [[ ${pool_name} != "${pool_id}" ]]; then
      if ! offlineJSON=$(jq ". += { \"pool-name\": \"${pool_name}\" }" <<< ${offlineJSON}); then return 1; fi
    fi
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
      println "MultiSig wallet delegation transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
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

# Command     : withdrawRewards
# Description : withdraw rewards earned and send to wallet base address
withdrawRewards() {

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
  else
    witness_cnt=2
  fi

  if ! getTTL "$([[ ${wallet_type} -eq 5 ]] && echo true)"; then return 1; fi

  getAssetsTxOut

  unset script_args
  if [[ ${wallet_type} -eq 5 ]]; then
    script_args=(
      --tx-in-script-file "${payment_script_file}"
      --withdrawal-script-file "${stake_script_file}"
    )
  fi

  tmpNewBalance=$(( base_lovelace + reward_lovelace ))
  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${base_addr}+${tmpNewBalance}${assets_tx_out}"
    --withdrawal ${reward_addr}+${reward_lovelace}
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    --out-file "${TMP_DIR}"/tx0.tmp
  )

  buildTx || return 1

  calcMinFee "${TMP_DIR}"/tx0.tmp ${utxo_cnt} 1 ${witness_cnt} || return 1

  newBalance=$(( base_lovelace - min_fee + reward_lovelace ))
  println LOG "Balance left to be returned in used UTxO is $(formatLovelace ${newBalance}) ADA ( $(formatLovelace ${base_lovelace}) - $(formatLovelace ${min_fee}) )"

  if [[ ${base_lovelace} -lt ${min_fee} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA in base address for tx fee!"\
			"Funds in address: ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"\
			"Minimum required: ${FG_LBLUE}$(formatLovelace $((min_fee - reward_lovelace)))${NC} ADA"
    return 1
  fi

  tx_out="${base_addr}+${newBalance}${assets_tx_out}"
  getMinUTxO "${tx_out}" || return 1
  if [[ ${newBalance} -lt ${min_utxo_out} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: minimum UTxO value not fulfilled, only ${FG_LBLUE}$(formatLovelace ${newBalance})${NC} ADA left in address after tx fee and withdrawal, at least ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA required!"
    return 1
  fi

  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${tx_out}"
    --withdrawal ${reward_addr}+${reward_lovelace}
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
    if ! buildOfflineJSON "Wallet Rewards Withdrawal"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { rewards: \"${reward_lovelace}\" }" <<< ${offlineJSON}); then return 1; fi
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
      println "MultiSig wallet withdrawal transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
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

