#!/bin/bash
# shellcheck disable=SC1090,SC2086

PARENT="$(dirname "$0")" 
. "${PARENT}"/env offline

if ! command -v psql &>/dev/null; then 
  echo -e "${FG_RED}ERROR${NC}: psql command not found, make sure that you have Cardano DBSync setup correctly"
  echo -e "\nhttps://cardano-community.github.io/guild-operators/#/Build/dbsync\n"
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

echo
echo -e "${FG_GREEN}get_pool_update(_pool_bech32 text, _current_epoch_no numeric default 0, _state text default '')${NC}"
echo -e "Function to grab latest, active or all pool updates for specified pool"
echo -e "${FG_LGRAY}_pool_bech32${NC}: the pool id in bech32 format"
echo -e "${FG_LGRAY}_current_epoch_no${NC}: only needed when using 'active' state"
echo -e "${FG_LGRAY}_state${NC}: only needed when using 'active' state"
echo -e "Example rest query: curl -d _pool_bech32=pool1pvyt2d468tlzr77cymae90hgj73aret457zfktnvgev6kmx5nk3 -d _current_epoch_no=121 -d _state=active -s http://localhost:8050/rpc/get_pool_update"
! output=$(cat <<'SQL' | tr '\n' ' ' | psql cexplorer 2>&1
CREATE OR REPLACE FUNCTION get_pool_update(
  _pool_bech32 text,
  _current_epoch_no numeric default 0,
  _state text default ''
)
RETURNS TABLE(
  update_id bigint,
  hash_id bigint,
  tx_id bigint,
  active_epoch_no bigint,
  pledge lovelace,
  margin double precision,
  fixed_cost lovelace,
  reward_addr text,
  meta_id bigint
) AS $$
BEGIN
  RETURN QUERY (
    SELECT
      pu.id AS update_id,
      pu.hash_id,
      pu.registered_tx_id,
      pu.active_epoch_no,
      pu.pledge,
      pu.margin,
      pu.fixed_cost,
      RIGHT(encode(pu.reward_addr::bytea, 'hex'), -2),
      pu.meta_id
    FROM pool_update AS pu
    INNER JOIN pool_hash AS ph ON pu.hash_id = ph.id
    WHERE ph.view = _pool_bech32
    AND CASE
      WHEN _state = 'active' AND pu.active_epoch_no <= _current_epoch_no THEN 'True'
      WHEN _state = 'active' THEN 'False'
      ELSE 'True'
    END = 'True'
    ORDER BY pu.id DESC
    LIMIT CASE
      WHEN _state = 'active' OR _state = 'latest' THEN 1
    END
  );
END; $$ LANGUAGE PLPGSQL IMMUTABLE;
SQL
) && echo -e "${FG_RED}ERROR${NC}: ${output}" && exit 1

echo
echo -e "${FG_GREEN}get_pool_retire(_pool_hash_id numeric)${NC}"
echo -e "Function to check if a pool retire transaction has been sent"
echo -e "${FG_LGRAY}_pool_hash_id${NC}: hash_id from get_pool_update()"
echo -e "Example rest query: curl -d _pool_hash_id=127 -s http://localhost:8050/rpc/get_pool_retire"
! output=$(cat <<'SQL' | tr '\n' ' ' | psql cexplorer
CREATE OR REPLACE FUNCTION get_pool_retire(
  _pool_hash_id numeric
)
RETURNS TABLE(
  retiring_epoch uinteger,
  announced_tx_id bigint
) AS $$
BEGIN
  RETURN QUERY (
    SELECT pr.retiring_epoch, pr.announced_tx_id
    FROM pool_retire AS pr
    WHERE pr.hash_id = _pool_hash_id
    ORDER BY pr.id DESC
    LIMIT 1
  );
END; $$ LANGUAGE PLPGSQL IMMUTABLE;
SQL
2>&1) && echo -e "${FG_RED}ERROR${NC}: ${output}" && exit 1

echo
echo -e "${FG_GREEN}get_pool_metadata(_pool_meta_id numeric)${NC}"
echo -e "Function to get pool metadata url and hash"
echo -e "${FG_LGRAY}_pool_meta_id${NC}: meta_id from get_pool_update()"
echo -e "Example rest query: curl -d _pool_meta_id=125 -s http://localhost:8050/rpc/get_pool_metadata"
! output=$(cat <<'SQL' | tr '\n' ' ' | psql cexplorer 2>&1
CREATE OR REPLACE FUNCTION get_pool_metadata(
  _pool_meta_id numeric
)
RETURNS TABLE(
  meta_url character varying,
  meta_hash text
) AS $$
BEGIN
  RETURN QUERY (
    SELECT pmd.url, encode(pmd.hash::bytea, 'hex')
    FROM pool_meta_data AS pmd
    WHERE pmd.id = _pool_meta_id
  );
END; $$ LANGUAGE PLPGSQL IMMUTABLE;
SQL
) && echo -e "${FG_RED}ERROR${NC}: ${output}" && exit 1

echo
echo -e "${FG_GREEN}get_pool_relays(_pool_update_id numeric)${NC}"
echo -e "Function to get registered pool relays"
echo -e "${FG_LGRAY}_pool_update_id${NC}: update_id from get_pool_update()"
echo -e "Example rest query: curl -d _pool_update_id=1296 -s http://localhost:8050/rpc/get_pool_relays"
! output=$(cat <<'SQL' | tr '\n' ' ' | psql cexplorer 2>&1
CREATE OR REPLACE FUNCTION get_pool_relays(
  _pool_update_id numeric
)
RETURNS TABLE(
  ipv4 character varying,
  ipv6 character varying,
  dns character varying,
  srv character varying,
  port integer
) AS $$
BEGIN
  RETURN QUERY (
    SELECT pr.ipv4, pr.ipv6, pr.dns_name, pr.dns_srv_name, pr.port
    FROM pool_relay AS pr
    WHERE pr.update_id = _pool_update_id
  );
END; $$ LANGUAGE PLPGSQL IMMUTABLE;
SQL
) && echo -e "${FG_RED}ERROR${NC}: ${output}" && exit 1

echo
echo -e "${FG_GREEN}get_pool_owners(_pool_tx_id numeric)${NC}"
echo -e "Function to get registered pool owners"
echo -e "${FG_LGRAY}_pool_tx_id${NC}: tx_id from get_pool_update()"
echo -e "Example rest query: curl -d _pool_tx_id=142292 -s http://localhost:8050/rpc/get_pool_owners"
! output=$(cat <<'SQL' | tr '\n' ' ' | psql cexplorer 2>&1
CREATE OR REPLACE FUNCTION get_pool_owners(
  _pool_tx_id numeric
)
RETURNS TABLE(
  owner_hash text,
  reward_addr character varying
) AS $$
BEGIN
  RETURN QUERY (
    SELECT DISTINCT encode(po.hash::bytea, 'hex'), sa.view
    FROM pool_owner AS po
    LEFT JOIN stake_address AS sa ON RIGHT(encode(sa.hash_raw::bytea, 'hex'), -2) = encode(po.hash::bytea, 'hex')
    WHERE po.registered_tx_id = _pool_tx_id
  );
END; $$ LANGUAGE PLPGSQL IMMUTABLE;
SQL
) && echo -e "${FG_RED}ERROR${NC}: ${output}" && exit 1

echo
echo -e "${FG_GREEN}get_active_stake(_pool_hash_id numeric default null, _epoch_no numeric default null)${NC}"
echo -e "Function to get the pools active stake in lovelace for specified epoch, current epoch if empty"
echo -e "${FG_LGRAY}_pool_hash_id${NC}: hash_id from get_pool_update()"
echo -e "${FG_LGRAY}_epoch_no${NC}: the epoch number to get active stake for"
echo -e "Example rest query: curl -d _pool_hash_id=127 -d _epoch_no=122 -s http://localhost:8050/rpc/get_active_stake"
! output=$(cat <<'SQL' | tr '\n' ' ' | psql cexplorer 2>&1
CREATE OR REPLACE FUNCTION get_active_stake(
  _pool_hash_id numeric default null,
  _epoch_no numeric default null
)
RETURNS TABLE(
  active_stake_sum numeric
) AS $$
BEGIN
  IF _epoch_no IS NULL THEN
    SELECT epoch.no INTO _epoch_no FROM epoch ORDER BY epoch.no DESC LIMIT 1;
  END IF;
  IF _pool_hash_id IS NULL THEN
    RETURN QUERY (
      SELECT SUM (es.amount)
      FROM epoch_stake AS es
      WHERE es.epoch_no = _epoch_no
    );
  ELSE
    RETURN QUERY (
      SELECT SUM (es.amount)
      FROM epoch_stake AS es
      WHERE es.epoch_no = _epoch_no
        AND es.pool_id = _pool_hash_id
      GROUP BY pool_id
    );
  END IF;
END; $$ LANGUAGE PLPGSQL IMMUTABLE;
SQL
) && echo -e "${FG_RED}ERROR${NC}: ${output}" && exit 1

echo
echo -e "${FG_GREEN}get_delegator_count(_pool_hash_id numeric)${NC}"
echo -e "Function to get live delegator count"
echo -e "${FG_LGRAY}_pool_hash_id${NC}: hash_id from get_pool_update()"
echo -e "Example rest query: curl -d _pool_hash_id=127 -s http://localhost:8050/rpc/get_delegator_count"
! output=$(cat <<'SQL' | tr '\n' ' ' | psql cexplorer 2>&1
CREATE OR REPLACE FUNCTION get_delegator_count(
  _pool_hash_id numeric
)
RETURNS TABLE(
  delegator_count bigint
) AS $$
BEGIN
  RETURN QUERY (
    SELECT COUNT(*)
    FROM delegation d
    WHERE pool_hash_id=_pool_hash_id
      AND NOT EXISTS
        (SELECT TRUE
         FROM delegation d2
         WHERE d2.addr_id=d.addr_id
           AND d2.id > d.id)
      AND NOT EXISTS
        (SELECT TRUE
         FROM stake_deregistration sd
         WHERE sd.addr_id=d.addr_id
           AND sd.tx_id > d.tx_id)
  );
END; $$ LANGUAGE PLPGSQL IMMUTABLE;
SQL
) && echo -e "${FG_RED}ERROR${NC}: ${output}" && exit 1

echo
echo "All functions successfully injected in DBSync"
echo "Please restart PostgREST before attempting to use the added functions"
echo
