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

asset_cnt=0

while IFS= read -r -d '' assetfile; do
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
    psql ${DB_NAME} -qbt -c "SELECT grest.asset_registry_cache_update(\$\$${asset_policy}\$\$, \$\$${asset_name}\$\$, \$\$${name}\$\$, \$\$${description}\$\$, ${ticker}, ${url}, ${logo}, ${decimals});" >/dev/null
    ((asset_cnt++))
  done <<< ${asset_data_csv}
done < <(find "${TR_DIR}/${TR_NAME}/${TR_SUBDIR}" -mindepth 1 -maxdepth 1 -type f -name "*.json" -mmin -15 -print0)

echo "$(date +%F_%H:%M:%S) - END - Asset Registry Update, ${asset_cnt} assets added/updated."
