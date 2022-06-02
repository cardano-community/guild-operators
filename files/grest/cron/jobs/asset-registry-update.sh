#!/bin/bash
CNODE_VNAME=cnode
DB_NAME=cexplorer
TR_URL=https://github.com/cardano-foundation/cardano-token-registry
TR_SUBDIR=mappings
TR_DIR=${HOME}/git
TR_NAME=${CNODE_VNAME}-token-registry

echo "$(date +%F_%H:%M:%S) - START - Asset Registry Update"

if [[ ! -d "${TR_DIR}/${TR_NAME}" ]]; then
  [[ -z ${HOME} ]] && echo "HOME variable not set, aborting..." && exit 1
  mkdir -p "${TR_DIR}"
  cd "${TR_DIR}" >/dev/null || exit 1
  git clone ${TR_URL} ${TR_NAME} >/dev/null || exit 1
fi
pushd "${TR_DIR}/${TR_NAME}" >/dev/null || exit 1
git pull >/dev/null || exit 1

last_commit="$(psql ${DB_NAME} -c "select last_value from grest.control_table where key='asset_registry_commit'" -t | xargs)"
[[ -z "${last_commit}" ]] && last_commit="$(git rev-list HEAD | tail -n 1)"
latest_commit="$(git rev-list HEAD | head -n 1)"

[[ "${last_commit}" == "${latest_commit}" ]] && echo "$(date +%F_%H:%M:%S) - END - Asset Registry Update, no updates necessary." && exit 0

asset_cnt=0

[[ -f '.assetregistry.sql' ]] && rm -f .assetregistry.sql
while IFS= read -re assetfile; do
  if ! asset_data_csv=$(jq -er '[
      .subject,
      .name.value,
      .description.value,
      .ticker.value //empty,
      .url.value //empty,
      .logo.value //empty,
      .decimals.value //0
      ] | @csv' "${assetfile}"); then
    echo "Failure parsing '${assetfile}', skipping..."
    continue
  fi
  while IFS=, read -r asset name description ticker url logo decimals; do
    asset="${asset//\"}"; name="${name//\"}"; description="${description//\"}"; ticker="${ticker//\"}"; url="${url//\"}"; logo="${logo//\"}"; 
    [[ ${#asset} -lt 56 || ! ${asset} =~ ^[a-f0-9]+$ ]] && continue # invalid subject
    asset_policy=${asset:0:56}
    asset_name=${asset:56}
    # validate data, silently skip entry for required fields or set null for optional
    [[ -z ${name} || ${#name} -gt 50 ]] && continue
    [[ -z ${description} || ${#description} -gt 500 ]] && continue
    [[ -z ${ticker} || ${#ticker} -lt 3 || ${#ticker} -gt 5 ]] && ticker=NULL || ticker="\$\$${ticker}\$\$"
    [[ -z ${url} || ! ${url//\"} =~ ^https?:// || ${#url} -gt 250 ]] && url=NULL || url="\$\$${url}\$\$"
    [[ -z ${logo} ]] && logo=NULL || logo="\$\$${logo}\$\$"
    [[ ! ${decimals} =~ ^[0-9]+$ ]] && decimals=0
    echo "SELECT grest.asset_registry_cache_update(\$\$${asset_policy}\$\$, \$\$${asset_name}\$\$, \$\$${name}\$\$, \$\$${description}\$\$, ${ticker}, ${url}, ${logo}, ${decimals});" >> .assetregistry.sql
    ((asset_cnt++))
  done <<< ${asset_data_csv}
done < <(git diff --name-only "${last_commit}" "${latest_commit}" | grep ^${TR_SUBDIR})
psql ${DB_NAME} -qb -f .assetregistry.sql >/dev/null
psql ${DB_NAME} -qb -c "INSERT INTO grest.control_table (key, last_value) VALUES ('asset_registry_commit','${latest_commit}') ON CONFLICT(key) DO UPDATE SET last_value='${latest_commit}'"
echo "$(date +%F_%H:%M:%S) - END - Asset Registry Update, ${asset_cnt} assets added/updated for commits ${last_commit} to ${latest_commit}."
