#!/bin/bash
# shellcheck disable=SC2086,SC1090

# source files
. "$(dirname $0)"/env
. "$(dirname $0)"/cntools.config

function usage() {
  echo -e "\nUsage: $(basename "$0") <wallet name> <ITN signing key file> <ITN verification key file>\n"
  echo -e "Create a CNTools compatible wallet from ITN keys to be able to withdraw rewards\n"
  printf "  %-20s\t%s\n" "wallet name" "Wallet name shown in CNTools" \
    "ITN signing key file" "ITN Owner skey (ed25519_sk/ed25519e_sk)" \
    "ITN verification key file" "ITN Owner vkey (ed25519_pk)"
  echo ""
  exit 1
}

if [[ $# -ne 3 ]]; then
  usage
fi

wallet_name="$1"
itn_signing_key_file="$2"
itn_verification_key_file="$3"

if [[ ! -f "${itn_signing_key_file}" || ! $(cat "${itn_signing_key_file}") =~ ^ed25519e?_sk* ]]; then
  echo -e "\n${RED}ERROR${NC}: Invalid ITN Signing Key provided\n"
  exit 1
fi

if [[ ! -f "${itn_verification_key_file}" || $(cat "${itn_verification_key_file}") != ed25519_pk* ]]; then
  echo -e "\n${RED}ERROR${NC}: Invalid ITN Verification Key provided\n"
  exit 1
fi

if [[ -d "${WALLET_FOLDER}/${wallet_name}" ]]; then
  echo -e "\n${RED}ERROR${NC}: Wallet already exist, please use another name"
  echo -e "${WALLET_FOLDER}/${wallet_name}\n"
  exit 1
fi
mkdir -p "${WALLET_FOLDER}/${wallet_name}"
if [[ ! -d "${WALLET_FOLDER}/${wallet_name}" ]]; then
  echo -e "\n${RED}ERROR${NC}: Failed to create wallet directory?"
  echo -e "${WALLET_FOLDER}/${wallet_name}\n"
  exit 1
fi

if [[ $(cat "${itn_signing_key_file}") == ed25519e_* ]]; then
  if ! ${CCLI} key 2>&1 | grep -q "convert-itn-extended-key"; then
    echo -e "\n${ORANGE}WARNING${NC}: cardano-cli lacks support for extended ITN key conversion: ${CCLI}\n"
    echo -e "If a special version of cardano-cli is built with this support, please specify path below, else follow instructions available at:"
    echo -e "  https://cardano-community.github.io/guild-operators/#/Scripts/itnrewards\n"
    while true; do
      read -r -p "Enter path to cardano-cli with support for extended key conversion or press enter to quit: " CCLI
      [[ -z "${CCLI}" ]] && rm -rf "${WALLET_FOLDER:?}/${wallet_name}" && exit 1
      if ! ${CCLI} key 2>&1 | grep -q "convert-itn-extended-key"; then
        echo -e "\n${ORANGE}ERROR${NC}: specified file lacks support for extended ITN key conversion, please try again\n"
        continue
      fi
      break
    done
  fi
  ${CCLI} key convert-itn-extended-key --itn-signing-key-file ${itn_signing_key_file} --out-file "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
else
  ${CCLI} key convert-itn-key --itn-signing-key-file ${itn_signing_key_file} --out-file "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_SK_FILENAME}"
fi
${CCLI} key convert-itn-key --itn-verification-key-file ${itn_verification_key_file} --out-file "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}"

${CCLI} address key-gen --verification-key-file "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}" --signing-key-file "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_SK_FILENAME}"
echo -e "\n${BLUE}Payment/Enterprise address:${NC}"
${CCLI} address build --payment-verification-key-file "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}" ${HASH_IDENTIFIER} | tee "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_ADDR_FILENAME}"
echo -e "${BLUE}Base address:${NC}"
${CCLI} address build --payment-verification-key-file "${WALLET_FOLDER}/${wallet_name}/${WALLET_PAY_VK_FILENAME}" --stake-verification-key-file "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}" ${HASH_IDENTIFIER} | tee "${WALLET_FOLDER}/${wallet_name}/${WALLET_BASE_ADDR_FILENAME}"
echo -e "${BLUE}Reward address:${NC}"
${CCLI} stake-address build --stake-verification-key-file "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_VK_FILENAME}" ${HASH_IDENTIFIER} | tee "${WALLET_FOLDER}/${wallet_name}/${WALLET_STAKE_ADDR_FILENAME}"

echo -e "\nWallet ${GREEN}${wallet_name}${NC} created\n"
echo -e "1) Start CNTools and verify that correct balance is shown in the wallet reward address"
echo -e "2) Fund base address of wallet with enough funds to pay for withdraw tx fee"
echo -e "3) Use FUNDS >> WITHDRAW to move rewards to base address of wallet from were you can spend/move them as you like\n"
