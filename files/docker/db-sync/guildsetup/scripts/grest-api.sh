#!/bin/bash
BRANCH=alpha
CURL_TIMEOUT=60

echo -e "Downloading DBSync RPC functions from Guild Operators GitHub store .."
if ! rpc_file_list=$(curl -s -f -m ${CURL_TIMEOUT} https://api.github.com/repos/cardano-community/guild-operators/contents/files/grest/rpc?ref=${BRANCH} 2>&1); then
  err_exit "\e[31mERROR\e[0m: ${rpc_file_list}"
fi

jqDecode() {
  base64 -d <<< $2 | jq -r "$1"
}

deployRPC() {
  file_name=$(jqDecode '.name' "${1}")
  [[ -z ${file_name} || ${file_name} != *.sql ]] && return
  dl_url=$(jqDecode '.download_url //empty' "${1}")
  [[ -z ${dl_url} ]] && return
  ! rpc_desc=$(curl -s -f -m ${CURL_TIMEOUT} ${dl_url} 2>/dev/null | grep 'COMMENT ON FUNCTION' | cut -d\' -f2) && echo -e "\e[31mERROR\e[0m: download failed: ${dl_url}" && return 1
  ! rpc_sql=$(curl -s -f -m ${CURL_TIMEOUT} ${dl_url} 2>/dev/null) && echo -e "\e[31mERROR\e[0m: download failed: ${dl_url%.json}.sql" && return 1
  echo -e "\nFunction:    \e[32m${file_name%.sql}\e[0m"
  echo -e "  Description: \e[37m${rpc_desc}\e[0m"
  ! output=$(psql cexplorer -v "ON_ERROR_STOP=1" <<< ${rpc_sql} 2>&1) && echo -e "  \e[31mERROR\e[0m: ${output}"
}

# add grest schema if missing and grant usage for web_anon
echo -e "\e[32mAdd grest schema if missing and grant usage for web_anon\e[0m"
psql cexplorer >/dev/null << 'SQL'
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
ALTER ROLE web_anon SET search_path TO grest, public;
COMMIT;
SQL

echo -e "\e[32mDeploying RPCs to DBSync ..\e[0m"

for row in $(jq -r '.[] | @base64' <<< ${rpc_file_list}); do
  if [[ $(jqDecode '.type' "${row}") = 'dir' ]]; then
    echo -e "\nDownloading RPC functions from subdir $(jqDecode '.name' "${row}")"
    if ! rpc_file_list_subdir=$(curl -s -m ${CURL_TIMEOUT} "https://api.github.com/repos/cardano-community/guild-operators/contents/files/grest/rpc/$(jqDecode '.name' "${row}")?ref=${BRANCH}"); then
      echo -e "  \e[31mERROR\e[0m: ${rpc_file_list_subdir}" && continue
    fi
    for row2 in $(jq -r '.[] | @base64' <<< ${rpc_file_list_subdir}); do
      deployRPC ${row2}
    done
  else
    deployRPC ${row}
  fi
done

