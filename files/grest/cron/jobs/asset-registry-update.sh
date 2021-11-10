#!/bin/bash
CNODE_VNAME=cnode
DB_NAME=cexplorer
TR_URL=https://github.com/cardano-foundation/cardano-token-registry
TR_SUBDIR=mappings
TR_DIR=${HOME}/git
TR_NAME=${CNODE_VNAME}-token-registry

echo "$(date +%F_%H:%M:%S) Running asset registry update..."

if [[ ! -d "${TR_DIR}/${TR_NAME}" ]]; then
  mkdir -p "${TR_DIR}"
  cd "${TR_DIR}" >/dev/null || exit 1
  git clone ${TR_URL} ${TR_NAME} >/dev/null || exit 1
fi
pushd "${TR_DIR}/${TR_NAME}" >/dev/null || exit 1
git pull >/dev/null || exit 1

while IFS= read -r -d '' assetfile; do
  echo ${assetfile}
done < <(find "${TR_DIR}/${TR_NAME}/${TR_SUBDIR}" -mindepth 1 -maxdepth 1 -type f -print0)

#psql cexplorer -qbt -c "SELECT GREST.UPDATE_STAKE_DISTRIBUTION_CACHE_CHECK();" 2>&1 1>/dev/null
