#!/usr/bin/env bash
# Stage 4 compatibility action for the characterized legacy asset listing.
# Sourcing defines functions only; the dispatcher supplies the inherited
# legacy helpers and globals inside its isolated compatibility subshell.

cntools_action_main() {
  local context_file="${1:-}"
  local result_file="${2:-}"
  local policy="" ttl="" current_slot="" asset="" asset_name=""
  local asset_name_hex=""

  (( $# == 2 )) || return 64
  [[ -n "${context_file}" && -n "${result_file}" ]] || return 64

  clear
  println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  println " >> ADVANCED >> ASSET >> LIST ASSETS"
  println DEBUG "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  if [[ ! $(ls -A "${ASSET_FOLDER}" 2>/dev/null) ]]; then
    echo
    println "${FG_YELLOW}No policies or assets found!${NC}"
    return 0
  fi
  while IFS= read -r -d '' policy; do
    echo
    println "Policy Name   : ${FG_GREEN}$(basename "${policy}")${NC}"
    println "Policy ID     : ${FG_LGRAY}$(cat "${policy}/${ASSET_POLICY_ID_FILENAME}")${NC}"
    ttl=$(jq -er '.scripts[0].slot //0' \
      "${policy}/${ASSET_POLICY_SCRIPT_FILENAME}")
    current_slot=$(getSlotTipRef)
    if [[ ${ttl} -eq 0 ]]; then
      println "Policy Expire : ${FG_LGRAY}unlimited${NC}"
    elif [[ ${ttl} -gt ${current_slot} ]]; then
      println "Policy Expire : ${FG_LGRAY}$(getDateFromSlot "${ttl}" '%(%F %T %Z)T')${NC}, ${FG_LGRAY}$(timeLeft $((ttl-current_slot)))${NC} remaining"
    else
      println "Policy Expire : ${FG_LGRAY}$(getDateFromSlot "${ttl}" '%(%F %T %Z)T')${NC}, ${FG_RED}expired $(timeLeft $((current_slot-ttl))) ago !!${NC}"
    fi
    if [[ $(find "${policy}" -mindepth 1 -maxdepth 1 -type f \
        -name '*.asset' -print0 | wc -c) -gt 0 ]]; then
      while IFS= read -r -d '' asset; do
        asset_name=$(jq -r '.name //empty' "${asset}")
        if [[ -z ${asset_name} ]]; then
          asset_name_hex=""
        else
          asset_name_hex="$(asciiToHex "${asset_name}")"
        fi
        println "Asset         : Name: ${FG_MAGENTA}${asset_name}${NC} (${FG_LGRAY}${asset_name_hex}${NC}) - Minted: ${FG_LBLUE}$(formatAsset "$(jq -r .minted "${asset}")")${NC}"
      done < <(find "${policy}" -mindepth 1 -maxdepth 1 -type f \
        -name '*.asset' -print0 | sort -z)
    else
      println "Asset         : ${FG_LGRAY}No assets minted for this policy!${NC}"
    fi
  done < <(find "${ASSET_FOLDER}" -mindepth 1 -maxdepth 1 -type d \
    -print0 | sort -z)
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'CNTools actions are launched by the dispatcher, not directly.' >&2
  exit 64
fi
