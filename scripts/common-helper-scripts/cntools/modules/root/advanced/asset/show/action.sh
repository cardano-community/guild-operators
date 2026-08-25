#!/usr/bin/env bash
# shellcheck disable=SC2034
# Stage 4 compatibility action for the characterized legacy asset display.
# Sourcing defines functions only; the dispatcher supplies the inherited
# legacy helpers and globals inside its isolated compatibility subshell.

cntools_action_main() {
  local context_file="${1:-}"
  local result_file="${2:-}"
  local policy_dir="" asset_name="" asset_file="" dir_name=""
  local dir="" asset="" policy_id="" ttl="" current_slot=""
  local asset_name_hex="" asset_info="" asset_info_tsv="" error_msg=""
  local a_asset_name_ascii="" a_fingerprint="" a_minting_tx_hash=""
  local a_total_supply="" a_mint_cnt="" a_burn_cnt=""
  local a_creation_time="" a_minting_tx_metadata=""
  local a_token_registry_metadata="" a_minted=""
  local a_last_update="" a_last_action=""
  local -a dirs=() asset_list=() asset_info_arr=()

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64

  clear
  println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println " >> ADVANCED >> ASSET >> SHOW ASSET"
  println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  if [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]]; then
    echo
    println "${FG_YELLOW}No policies or assets found!${NC}"
    waitToProceed
    return 0
  fi
  println DEBUG "Select minted asset to show information for"
  selectAsset
  case $? in
    1) waitToProceed; return 0 ;;
    2) return 0 ;;
  esac
  echo
  policy_id=$(cat "${ASSET_FOLDER}/${policy_dir}/${ASSET_POLICY_ID_FILENAME}")
  println "Policy Name    : ${FG_GREEN}${policy_dir}${NC}"
  println "Policy ID      : ${FG_LGRAY}${policy_id}${NC}"
  ttl=$(jq -er '.scripts[0].slot //0' \
    "${ASSET_FOLDER}/${policy_dir}/${ASSET_POLICY_SCRIPT_FILENAME}")
  current_slot=$(getSlotTipRef)
  if [[ ${ttl} -eq 0 ]]; then
    println "Policy Expire  : ${FG_LGRAY}unlimited${NC}"
  elif [[ ${ttl} -gt ${current_slot} ]]; then
    println "Policy Expire  : ${FG_LGRAY}$(getDateFromSlot "${ttl}" '%(%F %T %Z)T')${NC}, ${FG_LGRAY}$(timeLeft $((ttl-current_slot)))${NC} remaining"
  else
    println "Policy Expire  : ${FG_LGRAY}$(getDateFromSlot "${ttl}" '%(%F %T %Z)T')${NC}, ${FG_RED}expired $(timeLeft $((current_slot-ttl))) ago !!${NC}"
  fi
  asset_name=$(jq -r '.name //empty' "${asset_file}")
  if [[ -z ${asset_name} ]]; then
    asset_name_hex=""
  else
    asset_name_hex="$(asciiToHex "${asset_name}")"
  fi
  println "Asset Name     : ${FG_MAGENTA}${asset_name}${NC}${FG_LGRAY} (${asset_name_hex})${NC}"
  getAssetInfo "${policy_id}" "${asset_name_hex}"
  case $? in
    0)
      println "Fingerprint    : ${FG_LGRAY}${a_fingerprint}${NC}"
      println "In Circulation : ${FG_LBLUE}$(formatAsset "${a_total_supply}")${NC}"
      println "Mint Count     : ${FG_LBLUE}${a_mint_cnt}${NC}"
      println "Burn Count     : ${FG_LBLUE}${a_burn_cnt}${NC}"
      println "Mint Tx Meta   :"
      if [[ ${a_minting_tx_metadata} != '-' ]]; then
        jq -r . <<< "${a_minting_tx_metadata}"
      fi
      println "Token Reg Meta :"
      if [[ ${a_token_registry_metadata} != '-' ]]; then
        jq -r . <<< "${a_token_registry_metadata}"
      fi
      ;;
    1)
      println "ERROR" "${FG_RED}KOIOS_API ERROR${NC}: ${error_msg}"
      ;;
    2)
      a_minted=$(jq -er '.minted //0' "${asset_file}")
      println "In Circulation : ${FG_LBLUE}$(formatAsset "$(jq -er '.minted //0' "${asset_file}")")${NC} (local tracking)"
      ;;
  esac
  a_last_update=$(jq -er '.lastUpdate //"-"' "${asset_file}")
  a_last_action=$(jq -er '.lastAction //"-"' "${asset_file}")
  println "Last Updated   : ${FG_LGRAY}${a_last_update}${NC}"
  println "Last Action    : ${FG_LGRAY}${a_last_action}${NC}"
  waitToProceed
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
