# Command     : createNewWallet
# Description : creates a new empty wallet folder
createNewWallet() {
  getAnswerAnyCust wallet_name "Name of wallet (non-alphanumeric characters will be replaced with a space)"
  # Remove unwanted characters from wallet name
  wallet_name=${wallet_name//[^[:alnum:]]/_}
  if [[ -z "${wallet_name}" ]]; then
    println ERROR "${FG_RED}ERROR${NC}: Empty wallet name, please retry!"
    waitToProceed && return 1
  fi
  echo
  if ! mkdir -p "${WALLET_FOLDER}/${wallet_name}"; then
    println ERROR "${FG_RED}ERROR${NC}: Failed to create directory for wallet:\n${WALLET_FOLDER}/${wallet_name}"
    waitToProceed && return 1
  fi
  if [[ $(find "${WALLET_FOLDER}/${wallet_name}" -type f -print0 | wc -c) -gt 0 ]]; then
    println "${FG_RED}WARN${NC}: A wallet ${FG_GREEN}$wallet_name${NC} already exists"
    println "      Choose another name or delete the existing one"
    waitToProceed && return 1
  fi
  return 0
}

# Command     : createNewWallet
# Description : creates a new
# Return      : populates: ${acct_idx} ${key_idx}
createMnemonicWallet() {
  if ! cmdAvailable "bech32" &>/dev/null || \
    ! cmdAvailable "cardano-address" &>/dev/null; then
    println ERROR "${FG_RED}ERROR${NC}: bech32 and/or cardano-address not found in '\$PATH'"
    println ERROR "Please run updated guild-deploy.sh and re-build/re-download cardano-node"
    waitToProceed && return 1
  fi
  derivation_path_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_DERIVATION_PATH_FILENAME}"
  payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
  payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}"
  stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
  stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"
  drep_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_DREP_VK_FILENAME}"
  drep_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_DREP_SK_FILENAME}"
  cc_cold_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_COLD_VK_FILENAME}"
  cc_cold_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_COLD_SK_FILENAME}"
  cc_hot_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_HOT_VK_FILENAME}"
  cc_hot_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_GOV_CC_HOT_SK_FILENAME}"
  ms_payment_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_SK_FILENAME}"
  ms_payment_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_PAY_VK_FILENAME}"
  ms_stake_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_SK_FILENAME}"
  ms_stake_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_STAKE_VK_FILENAME}"
  ms_drep_sk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_SK_FILENAME}"
  ms_drep_vk_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_MULTISIG_PREFIX}${WALLET_GOV_DREP_VK_FILENAME}"
  isImport=true
  if [[ -z ${mnemonic} ]]; then
    println ACTION "cardano-address recovery-phrase generate"
    mnemonic=$(cardano-address recovery-phrase generate)
    isImport=false
  fi
  IFS=" " read -r -a words <<< "${mnemonic}"
  if [[ ${#words[@]} -ne 24 ]] && [[ ${#words[@]} -ne 15 ]]; then
    println ERROR "${FG_RED}ERROR${NC}: 24 or 15 words expected, found ${FG_RED}${#words[@]}${NC}"
    echo && safeDel "${WALLET_FOLDER}/${wallet_name}"
    unset mnemonic; unset words
    waitToProceed && return 1
  fi
  getCustomDerivationPath || return 1
  echo "1852H/1815H/${acct_idx}H/x/${key_idx}" > "${derivation_path_file}"
  caddr_v="$(cardano-address -v | awk '{print $1}')"
  [[ "${caddr_v}" == 3* ]] && caddr_arg="--with-chain-code" || caddr_arg=""
  println ACTION "cardano-address key from-recovery-phrase Shelley <<< <mnemonic words>"
  if ! root_prv=$(cardano-address key from-recovery-phrase Shelley <<< ${mnemonic}); then
    echo && safeDel "${WALLET_FOLDER}/${wallet_name}"
    unset mnemonic; unset words
    waitToProceed && return 1
  fi
  unset mnemonic
  [[ ${isImport} = true ]] && unset words
  println ACTION "cardano-address key child "1852H/1815H/${acct_idx}H/0/${key_idx}" <<< <root private key>"
  payment_xprv=$(cardano-address key child "1852H/1815H/${acct_idx}H/0/${key_idx}" <<< ${root_prv})
  println ACTION "cardano-address key child "1852H/1815H/${acct_idx}H/2/${key_idx}" <<< <root private key>"
  stake_xprv=$(cardano-address key child "1852H/1815H/${acct_idx}H/2/${key_idx}" <<< ${root_prv})
  println ACTION "cardano-address key child "1852H/1815H/${acct_idx}H/3/${key_idx}" <<< <root private key>"
  drep_xprv=$(cardano-address key child "1852H/1815H/${acct_idx}H/3/${key_idx}" <<< ${root_prv})
  println ACTION "cardano-address key child "1852H/1815H/${acct_idx}H/4/${key_idx}" <<< <root private key>"
  cc_cold_xprv=$(cardano-address key child "1852H/1815H/${acct_idx}H/4/${key_idx}" <<< ${root_prv})
  println ACTION "cardano-address key child "1852H/1815H/${acct_idx}H/5/${key_idx}" <<< <root private key>"
  cc_hot_xprv=$(cardano-address key child "1852H/1815H/${acct_idx}H/5/${key_idx}" <<< ${root_prv})
  println ACTION "cardano-address key child "1854H/1815H/${acct_idx}H/0/${key_idx}" <<< <root private key>"
  ms_payment_xprv=$(cardano-address key child "1854H/1815H/${acct_idx}H/0/${key_idx}" <<< ${root_prv})
  println ACTION "cardano-address key child "1854H/1815H/${acct_idx}H/2/${key_idx}" <<< <root private key>"
  ms_stake_xprv=$(cardano-address key child "1854H/1815H/${acct_idx}H/2/${key_idx}" <<< ${root_prv})
  println ACTION "cardano-address key child "1854H/1815H/${acct_idx}H/3/${key_idx}" <<< <root private key>"
  ms_drep_xprv=$(cardano-address key child "1854H/1815H/${acct_idx}H/3/${key_idx}" <<< ${root_prv})
  println ACTION "cardano-address key public ${caddr_arg} <<< <payment xprv>"
  payment_xpub=$(cardano-address key public ${caddr_arg} <<< ${payment_xprv})
  println ACTION "cardano-address key public ${caddr_arg} <<< <stake xprv>"
  stake_xpub=$(cardano-address key public ${caddr_arg} <<< ${stake_xprv})
  println ACTION "cardano-address key public ${caddr_arg} <<< <drep xprv>"
  drep_xpub=$(cardano-address key public ${caddr_arg} <<< ${drep_xprv})
  println ACTION "cardano-address key public ${caddr_arg} <<< <cc_cold xprv>"
  cc_cold_xpub=$(cardano-address key public ${caddr_arg} <<< ${cc_cold_xprv})
  println ACTION "cardano-address key public ${caddr_arg} <<< <cc_hot xprv>"
  cc_hot_xpub=$(cardano-address key public ${caddr_arg} <<< ${cc_hot_xprv})
  println ACTION "cardano-address key public ${caddr_arg} <<< <payment xprv>"
  ms_payment_xpub=$(cardano-address key public ${caddr_arg} <<< ${ms_payment_xprv})
  println ACTION "cardano-address key public ${caddr_arg} <<< <stake xprv>"
  ms_stake_xpub=$(cardano-address key public ${caddr_arg} <<< ${ms_stake_xprv})
  println ACTION "cardano-address key public ${caddr_arg} <<< <drep xprv>"
  ms_drep_xpub=$(cardano-address key public ${caddr_arg} <<< ${ms_drep_xprv})
  [[ "${NWMAGIC}" == "764824073" ]] && network_tag=1 || network_tag=0
  println ACTION "cardano-address address delegation ${stake_xpub} <<< $(cardano-address address payment --network-tag ${network_tag} <<< ${payment_xpub})"
  base_addr_candidate=$(cardano-address address delegation ${stake_xpub} <<< "$(cardano-address address payment --network-tag ${network_tag} <<< ${payment_xpub})")
  if [[ "${caddr_v}" == 2* ]] && [[ "${NWMAGIC}" != "764824073" ]]; then
    println LOG "TestNet, converting address to 'addr_test'"
    println ACTION "bech32 addr_test <<< ${base_addr_candidate}"
    base_addr_candidate=$(bech32 addr_test <<< ${base_addr_candidate})
  fi
  println LOG "Base address candidate = ${base_addr_candidate}"
  println LOG "Address Inspection:\n$(cardano-address address inspect <<< ${base_addr_candidate})"
  println ACTION "\$(bech32 <<< \${payment_xprv} | cut -b -128)\$(bech32 <<< ${payment_xpub})"
  pes_key=$(bech32 <<< ${payment_xprv} | cut -b -128)$(bech32 <<< ${payment_xpub})
  println ACTION "\$(bech32 <<< \${stake_xprv} | cut -b -128)\$(bech32 <<< ${stake_xpub})"
  ses_key=$(bech32 <<< ${stake_xprv} | cut -b -128)$(bech32 <<< ${stake_xpub})
  println ACTION "\$(bech32 <<< \${drep_xprv} | cut -b -128)\$(bech32 <<< ${drep_xpub})"
  drep_es_key=$(bech32 <<< ${drep_xprv} | cut -b -128)$(bech32 <<< ${drep_xpub})
  println ACTION "\$(bech32 <<< \${cc_cold_xprv} | cut -b -128)\$(bech32 <<< ${cc_cold_xpub})"
  cc_cold_es_key=$(bech32 <<< ${cc_cold_xprv} | cut -b -128)$(bech32 <<< ${cc_cold_xpub})
  println ACTION "\$(bech32 <<< \${cc_hot_xprv} | cut -b -128)\$(bech32 <<< ${cc_hot_xpub})"
  cc_hot_es_key=$(bech32 <<< ${cc_hot_xprv} | cut -b -128)$(bech32 <<< ${cc_hot_xpub})
  println ACTION "\$(bech32 <<< \${ms_payment_xprv} | cut -b -128)\$(bech32 <<< ${ms_payment_xpub})"
  ms_pes_key=$(bech32 <<< ${ms_payment_xprv} | cut -b -128)$(bech32 <<< ${ms_payment_xpub})
  println ACTION "\$(bech32 <<< \${ms_stake_xprv} | cut -b -128)\$(bech32 <<< ${ms_stake_xpub})"
  ms_ses_key=$(bech32 <<< ${ms_stake_xprv} | cut -b -128)$(bech32 <<< ${ms_stake_xpub})
  println ACTION "\$(bech32 <<< \${ms_drep_xprv} | cut -b -128)\$(bech32 <<< ${ms_drep_xpub})"
  ms_drep_es_key=$(bech32 <<< ${ms_drep_xprv} | cut -b -128)$(bech32 <<< ${ms_drep_xpub})
  cat <<-EOF > "${payment_sk_file}"
		{
				"type": "PaymentExtendedSigningKeyShelley_ed25519_bip32",
				"description": "Payment Signing Key",
				"cborHex": "5880${pes_key}"
		}
		EOF
  cat <<-EOF > "${stake_sk_file}"
		{
				"type": "StakeExtendedSigningKeyShelley_ed25519_bip32",
				"description": "Stake Signing Key",
				"cborHex": "5880${ses_key}"
		}
		EOF
	cat <<-EOF > "${drep_sk_file}"
		{
				"type": "DRepExtendedSigningKey_ed25519_bip32",
				"description": "Delegate Representative Signing Key",
				"cborHex": "5880${drep_es_key}"
		}
		EOF
	cat <<-EOF > "${cc_cold_sk_file}"
		{
				"type": "ConstitutionalCommitteeColdExtendedSigningKey_ed25519_bip32",
				"description": "Constitutional Committee Cold Signing Key",
				"cborHex": "5880${cc_cold_es_key}"
		}
		EOF
	cat <<-EOF > "${cc_hot_sk_file}"
		{
				"type": "ConstitutionalCommitteeHotExtendedSigningKey_ed25519_bip32",
				"description": "Constitutional Committee Hot Signing Key",
				"cborHex": "5880${cc_hot_es_key}"
		}
		EOF
	cat <<-EOF > "${ms_payment_sk_file}"
		{
				"type": "PaymentExtendedSigningKeyShelley_ed25519_bip32",
				"description": "MultiSig Payment Signing Key",
				"cborHex": "5880${pes_key}"
		}
		EOF
  cat <<-EOF > "${ms_stake_sk_file}"
		{
				"type": "StakeExtendedSigningKeyShelley_ed25519_bip32",
				"description": "MultiSig Stake Signing Key",
				"cborHex": "5880${ses_key}"
		}
		EOF
 	cat <<-EOF > "${ms_drep_sk_file}"
		{
				"type": "DRepExtendedSigningKey_ed25519_bip32",
				"description": "MultiSig Delegate Representative Signing Key",
				"cborHex": "5880${drep_es_key}"
		}
		EOF
  println ACTION "${CCLI} key verification-key --signing-key-file ${payment_sk_file} --verification-key-file ${TMP_DIR}/payment.evkey"
  if ! stdout=$(${CCLI} key verification-key --signing-key-file "${payment_sk_file}" --verification-key-file "${TMP_DIR}/payment.evkey" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during payment extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} key verification-key --signing-key-file ${stake_sk_file} --verification-key-file ${TMP_DIR}/stake.evkey"
  if ! stdout=$(${CCLI} key verification-key --signing-key-file "${stake_sk_file}" --verification-key-file "${TMP_DIR}/stake.evkey" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during stake extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} latest key verification-key --signing-key-file ${drep_sk_file} --verification-key-file ${TMP_DIR}/drep.evkey"
  if ! stdout=$(${CCLI} latest key verification-key --signing-key-file "${drep_sk_file}" --verification-key-file "${TMP_DIR}/drep.evkey" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during drep extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} latest key verification-key --signing-key-file ${cc_cold_sk_file} --verification-key-file ${TMP_DIR}/cc-cold.evkey"
  if ! stdout=$(${CCLI} latest key verification-key --signing-key-file "${cc_cold_sk_file}" --verification-key-file "${TMP_DIR}/cc-cold.evkey" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during cc-cold extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} latest key verification-key --signing-key-file ${cc_hot_sk_file} --verification-key-file ${TMP_DIR}/cc-hot.evkey"
  if ! stdout=$(${CCLI} latest key verification-key --signing-key-file "${cc_hot_sk_file}" --verification-key-file "${TMP_DIR}/cc-hot.evkey" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during cc-hot extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} key verification-key --signing-key-file ${ms_payment_sk_file} --verification-key-file ${TMP_DIR}/ms_payment.evkey"
  if ! stdout=$(${CCLI} key verification-key --signing-key-file "${ms_payment_sk_file}" --verification-key-file "${TMP_DIR}/ms_payment.evkey" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig payment extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} key verification-key --signing-key-file ${ms_stake_sk_file} --verification-key-file ${TMP_DIR}/ms_stake.evkey"
  if ! stdout=$(${CCLI} key verification-key --signing-key-file "${ms_stake_sk_file}" --verification-key-file "${TMP_DIR}/ms_stake.evkey" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig stake extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} latest key verification-key --signing-key-file ${ms_drep_sk_file} --verification-key-file ${TMP_DIR}/ms_drep.evkey"
  if ! stdout=$(${CCLI} latest key verification-key --signing-key-file "${ms_drep_sk_file}" --verification-key-file "${TMP_DIR}/ms_drep.evkey" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig drep extended verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} key non-extended-key --extended-verification-key-file ${TMP_DIR}/payment.evkey --verification-key-file ${payment_vk_file}"
  if ! stdout=$(${CCLI} key non-extended-key --extended-verification-key-file "${TMP_DIR}/payment.evkey" --verification-key-file "${payment_vk_file}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during payment verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} key non-extended-key --extended-verification-key-file ${TMP_DIR}/stake.evkey --verification-key-file ${stake_vk_file}"
  if ! stdout=$(${CCLI} key non-extended-key --extended-verification-key-file "${TMP_DIR}/stake.evkey" --verification-key-file "${stake_vk_file}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during stake verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} latest key non-extended-key --extended-verification-key-file ${TMP_DIR}/drep.evkey --verification-key-file ${drep_vk_file}"
  if ! stdout=$(${CCLI} latest key non-extended-key --extended-verification-key-file "${TMP_DIR}/drep.evkey" --verification-key-file "${drep_vk_file}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during drep verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} latest key non-extended-key --extended-verification-key-file ${TMP_DIR}/cc-cold.evkey --verification-key-file ${cc_cold_vk_file}"
  if ! stdout=$(${CCLI} latest key non-extended-key --extended-verification-key-file "${TMP_DIR}/cc-cold.evkey" --verification-key-file "${cc_cold_vk_file}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during cc-cold verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} latest key non-extended-key --extended-verification-key-file ${TMP_DIR}/cc-hot.evkey --verification-key-file ${cc_hot_vk_file}"
  if ! stdout=$(${CCLI} latest key non-extended-key --extended-verification-key-file "${TMP_DIR}/cc-hot.evkey" --verification-key-file "${cc_hot_vk_file}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during cc-hot verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} key non-extended-key --extended-verification-key-file ${TMP_DIR}/ms_payment.evkey --verification-key-file ${ms_payment_vk_file}"
  if ! stdout=$(${CCLI} key non-extended-key --extended-verification-key-file "${TMP_DIR}/ms_payment.evkey" --verification-key-file "${ms_payment_vk_file}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig payment verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} key non-extended-key --extended-verification-key-file ${TMP_DIR}/ms_stake.evkey --verification-key-file ${ms_stake_vk_file}"
  if ! stdout=$(${CCLI} key non-extended-key --extended-verification-key-file "${TMP_DIR}/ms_stake.evkey" --verification-key-file "${ms_stake_vk_file}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig stake verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  println ACTION "${CCLI} latest key non-extended-key --extended-verification-key-file ${TMP_DIR}/ms_drep.evkey --verification-key-file ${ms_drep_vk_file}"
  if ! stdout=$(${CCLI} latest key non-extended-key --extended-verification-key-file "${TMP_DIR}/ms_drep.evkey" --verification-key-file "${ms_drep_vk_file}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during MultiSig drep verification key extraction!\n${stdout}"; safeDel "${WALLET_FOLDER}/${wallet_name}"; waitToProceed && return 1
  fi
  chmod 600 "${WALLET_FOLDER}/${wallet_name}/"*
  getBaseAddress ${wallet_name}
  getPayAddress ${wallet_name}
  getRewardAddress ${wallet_name}
  getCredentials ${wallet_name}
  if [[ ${base_addr} != "${base_addr_candidate}" ]]; then
    println ERROR "${FG_RED}ERROR${NC}: base address generated doesn't match base address candidate."
    println ERROR "base_addr[${FG_LGRAY}${base_addr}${NC}]\n!=\nbase_addr_candidate[${FG_LGRAY}${base_addr_candidate}${NC}]"
    println ERROR "Create a GitHub issue and include log file from failed CNTools session."
    echo && safeDel "${WALLET_FOLDER}/${wallet_name}"
    waitToProceed && return 1
  fi
  return 0
}

printWalletInfo() {
  println DEBUG "You can now send and receive ADA using the above addresses. Note that Payment Address will not take part in staking"
  println DEBUG "Wallet will be automatically registered on chain if you choose to delegate or pledge wallet when registering a stake pool"
  echo
  println DEBUG "${FG_FG_LBLUE}INFO!${NC} Using a mnemonic or hardware wallet in CNTools comes with a few limitations"
  echo
  println DEBUG "Only the specified address in the HD wallet is extracted and because of this the following apply if used elsewhere:"
  println DEBUG " ${FG_LGRAY}>${NC} If restored wallet balance doesn't match, send all ADA to address shown in CNTools"
  println DEBUG " ${FG_LGRAY}>${NC} Only use receive address shown in CNTools (enable 'Single Address Mode' in wallet if available)"
  echo
  println DEBUG "Some of the advantages of using a mnemonic imported wallet instead of CLI are:"
  println DEBUG " ${FG_LGRAY}>${NC} Wallet can be restored from saved mnemonic/hardware device if keys are lost/deleted"
  println DEBUG " ${FG_LGRAY}>${NC} Wallet can be shared and used in multiple wallets concurrently, including CNTools"
  echo
  println DEBUG "Please read more about HD wallets at:"
  println DEBUG "https://cardano-community.github.io/support-faq/Wallets/wallets/#heirarchical-deterministic-hd-wallets"
}

# Command     : buildOfflineJSON [type]
# Description : construct a json containing all data for offline signing
# Parameters  : type  >  type of transaction, e.g 'payment'
buildOfflineJSON() {
  offlineJSON="{}"
  if ! offlineJSON=$(jq ". += { id: \"$(date +%s)\" }" <<< ${offlineJSON}); then return 1; fi
  if ! offlineJSON=$(jq ". += { type: \"${1}\" }" <<< ${offlineJSON}); then return 1; fi
  if ! offlineJSON=$(jq ". += { \"date-created\": \"$(date --iso-8601=s)\" }" <<< ${offlineJSON}); then return 1; fi
  if ! offlineJSON=$(jq ". += { \"date-expire\": \"$(date --iso-8601=s --date="@$(($(date +%s)+ttl_enter))")\" }" <<< ${offlineJSON}); then return 1; fi
  if ! offlineJSON=$(jq ". += { ttl: \"${ttl}\" }" <<< ${offlineJSON}); then return 1; fi
  if ! offlineJSON=$(jq ". += { \"signing-file\": [] }" <<< ${offlineJSON}); then return 1; fi
  if ! offlineJSON=$(jq ". += { \"script-file\": [] }" <<< ${offlineJSON}); then return 1; fi
  if ! offlineJSON=$(jq ". += { witness: [] }" <<< ${offlineJSON}); then return 1; fi
}

# Command     : registerStakeWallet [wallet name] [optional: skip validation]
# Description : Register stake keys on chain and move funds from payment address to payment base address
# Parameters  : wallet name      >  the name of the wallet
# Parameters  : skip validation  >  [optional] [true|false] if true, skip wallet registration check
registerStakeWallet() {

  wallet_name=$1
  wallet_source="base"

  getWalletType ${wallet_name}
  wallet_type=$?

  if [[ ${CNTOOLS_MODE} = "LIGHT" ]]; then
    utxo_cnt=${utxos_cnt[${base_addr}]}
    tx_in=${tx_in_arr[${base_addr}]}
  fi

  if [[ -z $2 || $2 = "false" ]]; then
    println DEBUG "Wallet ${FG_GREEN}${wallet_name}${NC} not registered on chain"
    waitToProceed "press any key to continue with registration"
  fi

  stake_cert_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_CERT_FILENAME}"

  if [[ ${wallet_type} -eq 5 ]]; then
    op_mode=hybrid
    unset required_total
    validateMultiSigScript false "$(cat "${payment_script_file}")"
    witness_cnt=${required_total}
    unset required_totalMore actions
    validateMultiSigScript false "$(cat "${stake_script_file}")"
    witness_cnt=$(( witness_cnt + required_total ))
    stake_param=("--stake-script-file" "${stake_script_file}")
  else
    witness_cnt=2
    stake_param=("--stake-verification-key-file" "${stake_vk_file}")
  fi

  if versionCheck "9.0" "${PROT_VERSION}"; then
    stake_param+=("--key-reg-deposit-amt" ${KEY_DEPOSIT})
  fi

  println ACTION "${CCLI} latest stake-address registration-certificate ${stake_param[*]} --out-file ${stake_cert_file}"
  if ! stdout=$(${CCLI} latest stake-address registration-certificate "${stake_param[@]}" --out-file "${stake_cert_file}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during stake registration certificate creation!\n${stdout}"; return 1
  fi

  if ! getTTL "$([[ ${wallet_type} -eq 5 ]] && echo true)"; then return 1; fi

  println LOG "Key Deposit is ${KEY_DEPOSIT}"

  getAssetsTxOut

  unset script_args
  if [[ ${wallet_type} -eq 5 ]]; then
    script_args=(More actions
      --tx-in-script-file "${payment_script_file}"
      --certificate-script-file "${stake_script_file}"
    )
  fi

  tmpNewBalance=$(( base_lovelace - KEY_DEPOSIT ))
  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${base_addr}+${tmpNewBalance}${assets_tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    --certificate-file "${stake_cert_file}"
    --out-file "${TMP_DIR}"/tx0.tmp
  )

  buildTx || return 1

  calcMinFee "${TMP_DIR}"/tx0.tmp ${utxo_cnt} 1 ${witness_cnt} || return 1

  newBalance=$(( base_lovelace - min_fee - KEY_DEPOSIT ))
  println LOG "New balance after tx fee and key deposit is $(formatLovelace ${newBalance}) ADA ($(formatLovelace ${base_lovelace}) - $(formatLovelace ${min_fee}) - $(formatLovelace ${KEY_DEPOSIT}))"

  if [[ ${base_lovelace} -lt $(( min_fee + KEY_DEPOSIT )) ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA in base address for tx fee and key deposit!"\
			"Funds in address: ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"\
			"Minimum required: ${FG_LBLUE}$(formatLovelace $(( min_fee + KEY_DEPOSIT )))${NC} ADA"
    return 1
  fi

  tx_out="${base_addr}+${newBalance}${assets_tx_out}"
  getMinUTxO "${tx_out}" || return 1
  if [[ ${newBalance} -lt ${min_utxo_out} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: minimum UTxO value not fulfilled, only ${FG_LBLUE}$(formatLovelace ${newBalance})${NC} ADA left in address after tx fee and key deposit, at least ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA required!"
    return 1
  fi

  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${min_fee}
    --certificate-file "${stake_cert_file}"
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${wallet_type} -eq 0 ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Wallet Registration"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { txFee: \"$(( min_fee + KEY_DEPOSIT ))\" }" <<< ${offlineJSON}); then return 1; fi
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
      println "MultiSig wallet registration transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
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
  echo
  if ! verifyTx ${base_addr}; then return 1; fi
  echo

  reward_lovelace=0
}

# Command     : deregisterStakeWallet
# Description : Deregister stake keys/wallet from chain, key deposit fee returned to wallets base address
deregisterStakeWallet() {

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

  if versionCheck "9.0" "${PROT_VERSION}"; then
    stake_param+=("--key-reg-deposit-amt" ${stake_deposit})
  fi

  stake_dereg_file="${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_DEREG_FILENAME}"
  println ACTION "${CCLI} latest stake-address deregistration-certificate ${stake_param[*]} --out-file ${stake_dereg_file}"
  if ! stdout=$(${CCLI} latest stake-address deregistration-certificate "${stake_param[@]}" --out-file "${stake_dereg_file}" 2>&1); then
    println ERROR "\n${FG_RED}ERROR${NC}: failure during stake deregistration certificate creation!\n${stdout}"; return 1
  fi

  if ! getTTL "$([[ ${wallet_type} -eq 5 ]] && echo true)"; then return 1; fi

  println LOG "Key Deposit is ${KEY_DEPOSIT}"

  getAssetsTxOut

  unset script_args
  if [[ ${wallet_type} -eq 5 ]]; then
    script_args=(
      --tx-in-script-file "${payment_script_file}"
      --certificate-script-file "${stake_script_file}"
    )
  fi

  tmpNewBalance=$(( base_lovelace + KEY_DEPOSIT ))
  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${base_addr}+${tmpNewBalance}${assets_tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${DUMMYFEE}
    --certificate-file "${stake_dereg_file}"
    --out-file "${TMP_DIR}"/tx0.tmp
  )

  buildTx || return 1

  calcMinFee "${TMP_DIR}"/tx0.tmp ${utxo_cnt} 1 ${witness_cnt} || return 1

  newBalance=$(( base_lovelace + KEY_DEPOSIT - min_fee ))
  println LOG "New balance after returned key deposit and subtracted tx fee is $(formatLovelace ${newBalance}) ADA ($(formatLovelace ${base_lovelace}) + $(formatLovelace ${KEY_DEPOSIT}) - $(formatLovelace ${min_fee}))"

  if [[ $(( ${base_lovelace} + KEY_DEPOSIT )) -lt ${min_fee} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: Not enough ADA in base address for tx fee!"\
			"Funds in address: ${FG_LBLUE}$(formatLovelace ${base_lovelace})${NC} ADA"\
			"Minimum required: ${FG_LBLUE}$(formatLovelace $(( min_fee - KEY_DEPOSIT )))${NC} ADA"
    return 1
  fi

  tx_out="${base_addr}+${newBalance}${assets_tx_out}"
  getMinUTxO "${tx_out}" || return 1
  if [[ ${newBalance} -lt ${min_utxo_out} ]]; then
    println ERROR "\n${FG_RED}ERROR${NC}: minimum UTxO value not fulfilled, only ${FG_LBLUE}$(formatLovelace ${newBalance})${NC} ADA left in address after tx fee and returned key deposit, at least ${FG_LBLUE}$(formatLovelace ${min_utxo_out})${NC} ADA required!"
    return 1
  fi

  build_args=(
    ${tx_in}
    "${script_args[@]}"
    --tx-out "${tx_out}"
    --invalid-hereafter ${ttl}
    --fee ${min_fee}
    --certificate-file "${stake_dereg_file}"
    --out-canonical-cbor
    --out-file "${TMP_DIR}"/tx.raw
  )

  if [[ ${wallet_type} -eq 0 ]]; then
    buildTx "${TMP_DIR}/tx.raw" || return 1
  else
    buildTx || return 1
  fi

  if [[ ${op_mode} = "hybrid" ]]; then
    if ! buildOfflineJSON "Wallet De-Registration"; then return 1; fi
    if ! offlineJSON=$(jq ". += { \"wallet-name\": \"${wallet_name}\" }" <<< ${offlineJSON}); then return 1; fi
    if ! offlineJSON=$(jq ". += { \"amount-returned\": \"${KEY_DEPOSIT}\" }" <<< ${offlineJSON}); then return 1; fi
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
      println "MultiSig wallet de-registration transaction successfully built and saved to: ${FG_LGRAY}${offline_tx}${NC}"
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

