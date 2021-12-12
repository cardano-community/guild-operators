CREATE TABLE IF NOT EXISTS GREST.STAKE_DISTRIBUTION_CACHE (
  STAKE_ADDRESS varchar PRIMARY KEY,
  POOL_ID varchar,
  TOTAL_BALANCE numeric,
  UTXO numeric,
  REWARDS numeric,
  WITHDRAWALS numeric,
  REWARDS_AVAILABLE numeric,
  RESERVES numeric,
  TREASURY numeric
);
DROP PROCEDURE IF EXISTS GREST.UPDATE_STAKE_DISTRIBUTION_CACHE ();
DROP FUNCTION IF EXISTS GREST.UPDATE_STAKE_DISTRIBUTION_CACHE ();
CREATE PROCEDURE GREST.UPDATE_STAKE_DISTRIBUTION_CACHE () LANGUAGE PLPGSQL AS $$
DECLARE -- Last block height to control future re-runs of the query
  _last_accounted_block_height bigint;
_last_accounted_block_id bigint;
BEGIN
SELECT block_no,
  id
FROM PUBLIC.BLOCK
WHERE block_no IS NOT NULL
  AND block_no = (
    SELECT MAX(BLOCK_NO) - 5
    FROM PUBLIC.BLOCK
  ) INTO _last_accounted_block_height,
  _last_accounted_block_id;
/* 
 * TEMPORARY TABLES TO GATHER LIVE STAKE DATA 
 */
DROP TABLE IF EXISTS accounts_with_delegated_pools;
DROP TABLE IF EXISTS pool_ids;
DROP TABLE IF EXISTS account_total_utxo;
DROP TABLE IF EXISTS account_total_rewards;
DROP TABLE IF EXISTS account_total_withdrawals;
DROP TABLE IF EXISTS account_last_withdrawal;
DROP TABLE IF EXISTS account_total_reserves;
DROP TABLE IF EXISTS account_total_treasury;
/* 
 * TABLE: accounts_with_delegated_pools
 * stake_addresss_id
 * stake_address (bech32)
 * pool_hash_id (of delegated pool for that account)
 */
CREATE TEMP TABLE accounts_with_delegated_pools AS (
  SELECT DISTINCT ON (STAKE_ADDRESS.ID) stake_address.id as stake_address_id,
    stake_address.view as stake_address,
    pool_hash_id
  FROM STAKE_ADDRESS
    INNER JOIN DELEGATION ON DELEGATION.ADDR_ID = STAKE_ADDRESS.ID
  WHERE NOT EXISTS (
      SELECT TRUE
      FROM DELEGATION D
      WHERE D.ADDR_ID = DELEGATION.ADDR_ID
        AND D.ID > DELEGATION.ID
    )
    AND NOT EXISTS (
      SELECT TRUE
      FROM STAKE_DEREGISTRATION
      WHERE STAKE_DEREGISTRATION.ADDR_ID = DELEGATION.ADDR_ID
        AND STAKE_DEREGISTRATION.TX_ID > DELEGATION.TX_ID
    )
);
CREATE INDEX IF NOT EXISTS idx_stake_address_id ON accounts_with_delegated_pools (stake_address_id);
CREATE INDEX IF NOT EXISTS idx_pool_hash_id ON accounts_with_delegated_pools (pool_hash_id);
/* 
 * TABLE: pool_ids
 * stake_addresss_id
 * pool_id
 */
CREATE TEMP TABLE pool_ids as (
  SELECT accounts_with_delegated_pools.stake_address_id,
    pool_hash.view as pool_id
  FROM pool_hash
    inner join accounts_with_delegated_pools on accounts_with_delegated_pools.pool_hash_id = pool_hash.id
);
-- possibly should remove this as a TEMP table selecting a column that is indexed will carry the index over
CREATE INDEX IF NOT EXISTS idx_stake_address_id ON pool_ids (stake_address_id);
/* 
 * TABLE: account_total_utxo
 * stake_addresss_id
 * UTXO (total utxo value for each account)
 */
CREATE TEMP TABLE account_total_utxo AS (
  SELECT accounts_with_delegated_pools.stake_address_id,
    COALESCE(SUM(TX_OUT.VALUE), 0) AS UTXO
  FROM tx_out
    INNER JOIN accounts_with_delegated_pools on tx_out.stake_address_id = accounts_with_delegated_pools.stake_address_id
    INNER JOIN TX ON TX.ID = TX_OUT.TX_ID
    LEFT JOIN TX_IN ON TX_OUT.TX_ID = TX_IN.TX_OUT_ID
    AND TX_OUT.INDEX::smallint = TX_IN.TX_OUT_INDEX::smallint
  WHERE TX.BLOCK_ID <= 6668337
    AND TX_IN.TX_IN_ID IS NULL
  GROUP BY accounts_with_delegated_pools.stake_address_id,
    accounts_with_delegated_pools.stake_address
);
-- possibly should remove this as a TEMP table selecting a column that is indexed will carry the index over
CREATE INDEX IF NOT EXISTS idx_stake_address_id ON account_total_utxo (stake_address_id);
/* 
 * TABLE: account_total_rewards
 * stake_addresss_id
 * REWARDS (total spendable rewards value for each account)
 */
CREATE TEMP TABLE account_total_rewards as (
  SELECT accounts_with_delegated_pools.stake_address_id,
    COALESCE(SUM(REWARD.AMOUNT), 0) AS REWARDS
  FROM REWARD
    INNER JOIN accounts_with_delegated_pools ON accounts_with_delegated_pools.stake_address_id = reward.addr_id
  WHERE REWARD.SPENDABLE_EPOCH <= (
      SELECT MAX(NO)
      FROM EPOCH
    )
  GROUP BY accounts_with_delegated_pools.stake_address_id
);
-- possibly should remove this as a TEMP table selecting a column that is indexed will carry the index over
CREATE INDEX IF NOT EXISTS idx_stake_address_id ON account_total_rewards (stake_address_id);
/* 
 * TABLE: account_total_withdrawals
 * stake_addresss_id
 * REWARDS (total withdrawals value for each account)
 */
CREATE TEMP TABLE account_total_withdrawals as (
  SELECT accounts_with_delegated_pools.stake_address_id,
    COALESCE(SUM(WITHDRAWAL.AMOUNT), 0) AS WITHDRAWALS
  FROM WITHDRAWAL
    INNER JOIN accounts_with_delegated_pools ON accounts_with_delegated_pools.stake_address_id = WITHDRAWAL.addr_id
  GROUP BY accounts_with_delegated_pools.stake_address_id
);
-- possibly should remove this as a TEMP table selecting a column that is indexed will carry the index over
CREATE INDEX IF NOT EXISTS idx_stake_address_id ON account_total_withdrawals (stake_address_id);
/* 
 * TABLE: account_last_withdrawal
 * stake_addresss_id
 * latest_withdrawal_tx_id (used to determine correct values left in treasury/reserves for the account)
 */
CREATE TEMP TABLE account_last_withdrawal as (
  SELECT accounts_with_delegated_pools.stake_address_id,
    max(withdrawal.tx_id) as latest_withdrawal_tx_id
  FROM WITHDRAWAL
    INNER JOIN accounts_with_delegated_pools ON accounts_with_delegated_pools.stake_address_id = WITHDRAWAL.addr_id
  GROUP BY accounts_with_delegated_pools.stake_address_id
);
-- possibly should remove this as a TEMP table selecting a column that is indexed will carry the index over
CREATE INDEX IF NOT EXISTS idx_stake_address_id ON account_last_withdrawal (stake_address_id);
/* 
 * TABLE: account_total_reserves
 * stake_addresss_id
 * RESERVES (total reserves value for each account - excluding already withdrawn funds, which are accounted for in the UTXO)
 */
CREATE TEMP TABLE account_total_reserves as (
  SELECT accounts_with_delegated_pools.stake_address_id,
    COALESCE(SUM(RESERVE.AMOUNT), 0) AS RESERVES
  FROM RESERVE
    INNER JOIN accounts_with_delegated_pools ON accounts_with_delegated_pools.stake_address_id = RESERVE.addr_id
    LEFT JOIN account_last_withdrawal ON account_last_withdrawal.stake_address_id = reserve.addr_id
  WHERE RESERVE.tx_id >= COALESCE(
      account_last_withdrawal.latest_withdrawal_tx_id,
      0
    )
  GROUP BY accounts_with_delegated_pools.stake_address_id
);
-- possibly should remove this as a TEMP table selecting a column that is indexed will carry the index over
CREATE INDEX IF NOT EXISTS idx_stake_address_id ON account_total_reserves (stake_address_id);
/* 
 * TABLE: account_total_treasury
 * stake_addresss_id
 * TREASURY (total treasury value for each account - excluding already withdrawn funds, which are accounted for in the UTXO)
 */
CREATE TEMP TABLE account_total_treasury as (
  SELECT accounts_with_delegated_pools.stake_address_id,
    COALESCE(SUM(TREASURY.AMOUNT), 0) AS TREASURY
  FROM TREASURY
    INNER JOIN accounts_with_delegated_pools ON accounts_with_delegated_pools.stake_address_id = TREASURY.addr_id
    LEFT JOIN account_last_withdrawal ON account_last_withdrawal.stake_address_id = accounts_with_delegated_pools.stake_address_id
  WHERE TREASURY.tx_id >= COALESCE(
      account_last_withdrawal.latest_withdrawal_tx_id,
      0
    )
  GROUP BY accounts_with_delegated_pools.stake_address_id
);
-- possibly should remove this as a TEMP table selecting a column that is indexed will carry the index over
CREATE INDEX IF NOT EXISTS idx_stake_address_id ON account_total_treasury (stake_address_id);
/* 
 * INSERT QUERY START
 */
INSERT INTO GREST.STAKE_DISTRIBUTION_CACHE
SELECT awdp.stake_address,
  pi.pool_id,
  CASE
    WHEN (
      COALESCE(atrew.REWARDS, 0) - COALESCE(atw.WITHDRAWALS, 0)
    ) < 0 THEN COALESCE(atu.UTXO, 0) + COALESCE(atrew.REWARDS, 0) - COALESCE(atw.WITHDRAWALS, 0) + COALESCE(atres.RESERVES, 0) + COALESCE(att.TREASURY, 0) - (
      COALESCE(atrew.REWARDS, 0) - COALESCE(atw.WITHDRAWALS, 0)
    )
    ELSE COALESCE(atu.UTXO, 0) + COALESCE(atrew.REWARDS, 0) - COALESCE(atw.WITHDRAWALS, 0) + COALESCE(atres.RESERVES, 0) + COALESCE(att.TREASURY, 0)
  END AS TOTAL_BALANCE,
  COALESCE(atu.UTXO, 0) AS UTXO,
  COALESCE(atrew.REWARDS, 0) AS REWARDS,
  COALESCE(atw.WITHDRAWALS, 0) AS WITHDRAWALS,
  CASE
    WHEN (
      COALESCE(atrew.REWARDS, 0) - COALESCE(atw.WITHDRAWALS, 0)
    ) <= 0 THEN 0
    ELSE COALESCE(atrew.REWARDS, 0) - COALESCE(atw.WITHDRAWALS, 0)
  END AS REWARDS_AVAILABLE,
  COALESCE(atres.RESERVES, 0) AS RESERVES,
  COALESCE(att.TREASURY, 0) AS TREASURY
from accounts_with_delegated_pools awdp
  INNER JOIN pool_ids pi ON pi.stake_address_id = awdp.stake_address_id
  LEFT JOIN account_total_utxo atu ON atu.stake_address_id = awdp.stake_address_id
  LEFT JOIN account_total_rewards atrew ON atrew.stake_address_id = awdp.stake_address_id
  LEFT JOIN account_total_withdrawals atw ON atw.stake_address_id = awdp.stake_address_id
  LEFT JOIN account_total_reserves atres ON atres.stake_address_id = awdp.stake_address_id
  LEFT JOIN account_total_treasury att ON att.stake_address_id = awdp.stake_address_id ON CONFLICT (STAKE_ADDRESS) DO
UPDATE
SET POOL_ID = EXCLUDED.POOL_ID,
  TOTAL_BALANCE = EXCLUDED.TOTAL_BALANCE,
  UTXO = EXCLUDED.UTXO,
  REWARDS = EXCLUDED.REWARDS,
  WITHDRAWALS = EXCLUDED.WITHDRAWALS,
  REWARDS_AVAILABLE = EXCLUDED.REWARDS_AVAILABLE,
  RESERVES = EXCLUDED.RESERVES,
  TREASURY = EXCLUDED.TREASURY
WHERE STAKE_DISTRIBUTION_CACHE.POOL_ID IS DISTINCT
FROM EXCLUDED.POOL_ID
  OR STAKE_DISTRIBUTION_CACHE.TOTAL_BALANCE IS DISTINCT
FROM EXCLUDED.TOTAL_BALANCE
  OR STAKE_DISTRIBUTION_CACHE.UTXO IS DISTINCT
FROM EXCLUDED.UTXO
  OR STAKE_DISTRIBUTION_CACHE.REWARDS IS DISTINCT
FROM EXCLUDED.REWARDS
  OR STAKE_DISTRIBUTION_CACHE.WITHDRAWALS IS DISTINCT
FROM EXCLUDED.WITHDRAWALS
  OR STAKE_DISTRIBUTION_CACHE.REWARDS_AVAILABLE IS DISTINCT
FROM EXCLUDED.REWARDS_AVAILABLE
  OR STAKE_DISTRIBUTION_CACHE.RESERVES IS DISTINCT
FROM EXCLUDED.RESERVES
  OR STAKE_DISTRIBUTION_CACHE.TREASURY IS DISTINCT
FROM EXCLUDED.TREASURY;
/* 
 * CONTROL TABLE
 * Store last block height in the control table
 */
INSERT INTO GREST.CONTROL_TABLE (key, last_value)
VALUES (
    'stake_distribution_lbh',
    _last_accounted_block_height
  ) ON CONFLICT (key) DO
UPDATE
SET last_value = _last_accounted_block_height;
END;
$$;
/* 
 * HELPER FUNCTION: GREST.STAKE_DISTRIBUTION_CACHE_UPDATE_CHECK
 * Determines whether or not the stake distribution cache should be updated
 * based on the time rule (max once in 60 mins), and ensures previous run completed.
 */
DROP FUNCTION IF EXISTS GREST.STAKE_DISTRIBUTION_CACHE_UPDATE_CHECK;
CREATE FUNCTION GREST.STAKE_DISTRIBUTION_CACHE_UPDATE_CHECK () RETURNS VOID LANGUAGE PLPGSQL AS $$
DECLARE _last_update_block_height bigint DEFAULT NULL;
_current_block_height bigint DEFAULT NULL;
_last_update_block_diff bigint DEFAULT NULL;
StartTime timestamptz;
EndTime timestamptz;
-- In minutes
Delta numeric;
BEGIN IF (
  SELECT COUNT(pid) > 1
  FROM pg_stat_activity
  WHERE state = 'active'
    AND query ILIKE '%GREST.STAKE_DISTRIBUTION_CACHE_UPDATE_CHECK(%'
) THEN RAISE EXCEPTION 'Previous query still running but should have completed! Exiting...';
END IF;
-- QUERY START --
SELECT COALESCE(
    (
      SELECT last_value::bigint
      FROM GREST.control_table
      WHERE key = 'stake_distribution_lbh'
    ),
    0
  ) INTO _last_update_block_height;
SELECT MAX(block_no)
FROM PUBLIC.BLOCK
WHERE BLOCK_NO IS NOT NULL INTO _current_block_height;
SELECT (
    _current_block_height - _last_update_block_height
  ) INTO _last_update_block_diff;
-- Do nothing until there is a 180 blocks difference in height - 60 minutes theoretical time
-- 185 in check because last block height considered is 5 blocks behind tip
Raise NOTICE 'Last stake distribution update was % blocks ago...',
_last_update_block_diff;
IF (
  _last_update_block_diff >= 185 -- Special case for db-sync restart rollback to epoch start
  OR _last_update_block_diff < 0
) THEN RAISE NOTICE 'Re-running...';
CALL GREST.UPDATE_STAKE_DISTRIBUTION_CACHE ();
-- Time recording
EndTime := CLOCK_TIMESTAMP();
Delta := 1000 * (
  EXTRACT(
    epoch
    from EndTime
  ) - EXTRACT(
    epoch
    from StartTime
  )
) / 60000;
RAISE NOTICE 'Job completed in % minutes',
Delta;
END IF;
RAISE NOTICE 'Minimum block height difference(180) for update not reached, skipping...';
RETURN;
END;
$$;
CREATE INDEX IF NOT EXISTS idx_pool_id ON GREST.STAKE_DISTRIBUTION_CACHE (POOL_ID);
-- Populated by first crontab execution