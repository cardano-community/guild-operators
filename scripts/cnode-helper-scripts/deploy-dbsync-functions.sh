#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2086

PARENT="$(dirname "$0")" 
. "${PARENT}"/env offline

if ! command -v psql &>/dev/null; then 
  echo -e "${FG_RED}ERROR${NC}: psql command not found, make sure that you have Cardano DBSync setup correctly"
  echo -e "\nhttps://cardano-community.github.io/guild-operators/#/Appendix/postgres\n"
  exit 1
fi

if [[ -z ${PGPASSFILE} || ! -f "${PGPASSFILE}" ]]; then
  echo -e "${FG_RED}ERROR${NC}: PGPASSFILE env variable not set or pointing to a non-existing file: ${PGPASSFILE}"
  echo -e "\nhttps://cardano-community.github.io/guild-operators/#/Build/dbsync\n"
  exit 1
fi

if ! dbsync_network=$(psql -qtAX -d cexplorer -c "select network_name from meta;" 2>&1); then
  echo -e "${FG_RED}ERROR${NC}: querying Cardano DBSync PostgreSQL DB:\n${dbsync_network}"
  echo -e "\nhttps://cardano-community.github.io/guild-operators/#/Build/dbsync\n"
  exit 1
fi
echo -e "Successfully connected to ${FG_LBLUE}${dbsync_network}${NC} Cardano DBSync PostgreSQL DB!"

echo -e "\nDownloading DBSync RPC functions from Guild Operators GitHub store ..\n"
if ! rpc_file_list=$(curl -s -m ${CURL_TIMEOUT} https://api.github.com/repos/cardano-community/guild-operators/contents/files/dbsync/rpc?ref=${BRANCH}); then
  echo -e "${FG_RED}ERROR${NC}: ${rpc_file_list}" && exit 1
fi

jqDecode() {
  base64 --decode <<< $2 | jq -r "$1"
}

for row in $(jq -r '.[] | @base64' <<< ${rpc_file_list}); do
  file_name=$(jqDecode '.name' "${row}")
  dl_url=$(jqDecode '.download_url //empty' "${row}")
  [[ -z ${dl_url} ]] && continue
  ! file_content=$(curl -s -f -m ${CURL_TIMEOUT} ${dl_url} 2>/dev/null) && echo -e "${FG_RED}ERROR${NC}: download failed: ${dl_url}" && exit 1
  echo -e "Function:    ${FG_GREEN}$(jq -r '.function' <<< ${file_content})${NC}"
  echo -e "Description: ${FG_LGRAY}$(jq -r '.description' <<< ${file_content})${NC}"
  for param in $(jq -r '.parameters[] | @base64' <<< ${file_content}); do
    echo -e "Parameter:   ${FG_LBLUE}$(jqDecode '.name' "${param}")${NC} => ${FG_LGRAY}$(jqDecode '.description' "${param}")${NC}"
  done
  for example in $(jq -r '.example[] | @base64' <<< ${file_content}); do
    echo -e "Example $(jqDecode '.type' "${example}") query: ${FG_LGRAY}$(jqDecode '.command' "${example}")${NC}"
  done
  ! output=$(jq -r '.sql | join("\n")' <<< ${file_content} | psql cexplorer 2>&1) && echo -e "${FG_RED}ERROR${NC}: ${output}" && exit 1
  echo
done

echo -e "${FG_GREEN}All RPC functions successfully added to DBSync!${NC}"
echo -e "${FG_YELLOW}Please restart PostgREST before attempting to use the added functions${NC}\n"
