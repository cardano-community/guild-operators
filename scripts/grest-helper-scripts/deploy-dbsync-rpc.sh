#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2086

PARENT="$(dirname "$0")" 
. "${PARENT}"/env offline

if ! command -v psql &>/dev/null; then 
  echo -e "${FG_RED}ERROR${NC}: psql command not found, make sure that you have Cardano DBSync setup correctly"
  echo -e "\nhttps://cardano-community.github.io/guild-operators/Appendix/postgres\n"
  exit 1
fi

if [[ -z ${PGPASSFILE} || ! -f "${PGPASSFILE}" ]]; then
  echo -e "${FG_RED}ERROR${NC}: PGPASSFILE env variable not set or pointing to a non-existing file: ${PGPASSFILE}"
  echo -e "\nhttps://cardano-community.github.io/guild-operators/Build/dbsync\n"
  exit 1
fi

if ! dbsync_network=$(psql -qtAX -d cexplorer -c "select network_name from meta;" 2>&1); then
  echo -e "${FG_RED}ERROR${NC}: querying Cardano DBSync PostgreSQL DB:\n${dbsync_network}"
  echo -e "\nhttps://cardano-community.github.io/guild-operators/Build/dbsync\n"
  exit 1
fi
echo -e "Successfully connected to ${FG_LBLUE}${dbsync_network}${NC} Cardano DBSync PostgreSQL DB!"

echo -e "\nDownloading DBSync RPC functions from Guild Operators GitHub store ..\n"
if ! rpc_file_list=$(curl -s -m ${CURL_TIMEOUT} https://api.github.com/repos/cardano-community/guild-operators/contents/files/grest/rpc?ref=${BRANCH}); then
  echo -e "${FG_RED}ERROR${NC}: ${rpc_file_list}" && exit 1
fi

jqDecode() {
  base64 --decode <<< $2 | jq -r "$1"
}

deployRPC() {
  file_name=$(jqDecode '.name' "${1}")
  [[ -z ${file_name} || ${file_name} != *.json ]] && return
  dl_url=$(jqDecode '.download_url //empty' "${1}")
  [[ -z ${dl_url} ]] && return
  ! rpc_desc=$(curl -s -f -m ${CURL_TIMEOUT} ${dl_url} 2>/dev/null) && echo -e "${FG_RED}ERROR${NC}: download failed: ${dl_url}" && return 1
  ! rpc_sql=$(curl -s -f -m ${CURL_TIMEOUT} ${dl_url%.json}.sql 2>/dev/null) && echo -e "${FG_RED}ERROR${NC}: download failed: ${dl_url%.json}.sql" && return 1
  echo -e "Function:    ${FG_GREEN}$(jq -r '.function' <<< ${rpc_desc})${NC}"
  echo -e "Description: ${FG_LGRAY}$(jq -r '.description' <<< ${rpc_desc})${NC}"
  for param in $(jq -r '.parameters[] | @base64' <<< ${rpc_desc}); do
    echo -e "Parameter:   ${FG_LBLUE}$(jqDecode '.name' "${param}")${NC} => ${FG_LGRAY}$(jqDecode '.description' "${param}")${NC}"
  done
  for example in $(jq -r '.example[] | @base64' <<< ${rpc_desc}); do
    echo -e "Example $(jqDecode '.type' "${example}") query: ${FG_LGRAY}$(jqDecode '.command' "${example}")${NC}"
  done
  ! output=$(psql cexplorer -v "ON_ERROR_STOP=1" <<< ${rpc_sql} 2>&1) && echo -e "\n${FG_RED}ERROR${NC}: ${output}"
  echo
}

# add grest schema if missing and grant usage for web_anon
echo -e "\n${FG_GREEN}Add grest schema if missing and grant usage for web_anon${NC}\n"
psql cexplorer << 'SQL'
BEGIN;

DO
$$
BEGIN
	CREATE ROLE web_anon nologin;
	EXCEPTION WHEN DUPLICATE_OBJECT THEN
		RAISE NOTICE 'web_anon exists, skipping...';
END
$$;

CREATE SCHEMA IF NOT EXISTS grest;
GRANT USAGE ON SCHEMA public TO web_anon;
GRANT USAGE ON SCHEMA grest TO web_anon;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO web_anon;
GRANT SELECT ON ALL TABLES IN SCHEMA grest TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA grest GRANT SELECT ON TABLES TO web_anon;
ALTER ROLE CURRENT_USER SET search_path TO grest, public;
ALTER ROLE web_anon SET search_path TO grest, public;
COMMIT;
SQL

echo -e "\n${FG_GREEN}Deploying RPCs to DBSync..${NC}\n"

for row in $(jq -r '.[] | @base64' <<< ${rpc_file_list}); do
  if [[ $(jqDecode '.type' "${row}") = 'dir' ]]; then
    echo -e "\nDownloading DBSync RPC functions from subdir $(jqDecode '.name' "${row}")\n"
    if ! rpc_file_list_subdir=$(curl -s -m ${CURL_TIMEOUT} https://api.github.com/repos/cardano-community/guild-operators/contents/files/grest/rpc/$(jqDecode '.name' "${row}")?ref=${BRANCH}); then
      echo -e "${FG_RED}ERROR${NC}: ${rpc_file_list_subdir}" && continue
    fi
    for row2 in $(jq -r '.[] | @base64' <<< ${rpc_file_list_subdir}); do
      deployRPC ${row2}
    done
  else
    deployRPC ${row}
  fi
done

echo -e "${FG_GREEN}All RPC functions successfully added to DBSync!${NC}\n"
echo -e "${FG_YELLOW}Please restart PostgREST before attempting to use the added functions${NC}"
echo -e "  ${FG_LBLUE}sudo systemctl restart postgrest.service${NC}\n"
