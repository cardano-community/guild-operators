#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2086,SC2154
function usage() {
  printf "\n%s\n\n" "Usage: $(basename "$0") <Pool Name>"
  printf "  %-20s\t%s\n\n" "Pool Name" "Pool name used in CNTools, see cntools.config for pool folder"
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

# source files
. "$(dirname $0)"/env
. "$(dirname $0)"/cntools.library
. "$(dirname $0)"/cntools.config

pool_name="${1}"

if [[ ! -d "${POOL_FOLDER}/${pool_name}" ]]; then
  say "${RED}ERROR${NC}: pool folder not found!"
  say "${POOL_FOLDER}/${pool_name}"
  exit 1
fi

if ! rotatePoolKeys "${pool_name}"; then
  say "" && exit 1
fi

say ""
say "Pool KES Keys Updated: ${GREEN}${pool_name}${NC}"
say "New KES start period: ${start_kes_period}"
say "KES keys will expire on kes period ${kes_expiration_period}, ${expiration_date}"
say "Restart your pool node for changes to take effect"
say ""