DROP TABLE IF EXISTS GREST.STAKE_DISTRIBUTION_CACHE ;
CREATE TABLE GREST.STAKE_DISTRIBUTION_CACHE (
  STAKE_ADDRESS varchar PRIMARY KEY,
  POOL_ID varchar,
  TOTAL_BALANCE numeric,
  UTXO numeric,
  REWARDS numeric,
  WITHDRAWALS numeric,
  REWARDS_AVAILABLE numeric
);

CREATE OR REPLACE PROCEDURE GREST.UPDATE_STAKE_DISTRIBUTION_CACHE () LANGUAGE PLPGSQL AS $$
DECLARE -- Last block height to control future re-runs of the query
  _last_accounted_block_height bigint;
  _active_stake_epoch bigint;
  _last_active_stake_blockid bigint;
BEGIN
  SELECT block_no FROM PUBLIC.BLOCK
    WHERE block_no IS NOT NULL
      AND block_no = (SELECT MAX(BLOCK_NO) FROM PUBLIC.BLOCK) INTO _last_accounted_block_height;
  
  SELECT (last_value::integer - 2)::integer INTO _active_stake_epoch FROM GREST.CONTROL_TABLE WHERE key = 'last_active_stake_validated_epoch';

  SELECT id INTO _last_active_stake_blockid FROM PUBLIC.BLOCK
    WHERE epoch_no = _active_stake_epoch
    ORDER BY block_no DESC LIMIT 1 ;

  WITH 
    accounts_with_delegated_pools AS (
      SELECT DISTINCT ON (STAKE_ADDRESS.ID) stake_address.id as stake_address_id, stake_address.view as stake_address, pool_hash_id
      FROM STAKE_ADDRESS
        INNER JOIN DELEGATION ON DELEGATION.ADDR_ID = STAKE_ADDRESS.ID
        WHERE
          NOT EXISTS (
            SELECT TRUE FROM DELEGATION D
              WHERE D.ADDR_ID = DELEGATION.ADDR_ID AND D.ID > DELEGATION.ID
          )
          AND NOT EXISTS (
            SELECT TRUE FROM STAKE_DEREGISTRATION
              WHERE STAKE_DEREGISTRATION.ADDR_ID = DELEGATION.ADDR_ID
                AND STAKE_DEREGISTRATION.TX_ID > DELEGATION.TX_ID
          )
    ),
    pool_ids as (
      SELECT awdp.stake_address_id,
        pool_hash.view AS pool_id
      FROM POOL_HASH
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.pool_hash_id = pool_hash.id
    ),
    account_active_stake AS (
      SELECT awdp.stake_address_id, acsc.amount
      FROM grest.account_active_stake_cache acsc
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.stake_address = acsc.stake_address
        WHERE epoch_no = _active_stake_epoch
    ),
    account_delta_tx_ins AS (
      SELECT awdp.stake_address_id, tx_in.tx_out_id AS txoid, tx_in.tx_out_index AS txoidx FROM tx_in
        LEFT JOIN tx_out ON tx_in.tx_out_id = tx_out.tx_id AND tx_in.tx_out_index::smallint = tx_out.index::smallint
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.stake_address_id = tx_out.stake_address_id
        WHERE tx_in.tx_in_id > (SELECT MAX(id) FROM tx WHERE block_id = _last_active_stake_blockid)
    ),
    account_delta_input AS (
      SELECT tx_out.stake_address_id, COALESCE(SUM(tx_out.value), 0) AS amount
      FROM account_delta_tx_ins
        LEFT JOIN tx_out ON account_delta_tx_ins.txoid=tx_out.tx_id AND account_delta_tx_ins.txoidx = tx_out.index
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.stake_address_id = tx_out.stake_address_id
        GROUP BY tx_out.stake_address_id
    ),
    account_delta_output AS (
      SELECT awdp.stake_address_id, COALESCE(SUM(tx_out.value), 0) AS amount
      FROM tx_out
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.stake_address_id = tx_out.stake_address_id
        INNER JOIN tx ON tx.id = tx_out.tx_id
        LEFT JOIN tx_in ON tx_out.tx_id = tx_in.tx_out_id AND tx_out.index::smallint = tx_in.tx_out_index::smallint
      WHERE TX.BLOCK_ID > _last_active_stake_blockid
      GROUP BY awdp.stake_address_id
    ),
    account_delta_rewards AS (
      SELECT awdp.stake_address_id, COALESCE(SUM(reward.amount), 0) AS REWARDS
      FROM REWARD
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.stake_address_id = reward.addr_id
      WHERE REWARD.SPENDABLE_EPOCH >= _active_stake_epoch
      GROUP BY awdp.stake_address_id
    ),
    account_delta_withdrawals AS (
      SELECT accounts_with_delegated_pools.stake_address_id, COALESCE(SUM(withdrawal.amount), 0) AS withdrawals
      FROM withdrawal
        INNER JOIN accounts_with_delegated_pools ON accounts_with_delegated_pools.stake_address_id = withdrawal.addr_id
      WHERE withdrawal.tx_id > (SELECT max(id) FROM tx WHERE block_id = _last_active_stake_blockid)
      GROUP BY accounts_with_delegated_pools.stake_address_id
    ),
    account_total_rewards as (
      SELECT accounts_with_delegated_pools.stake_address_id,
        COALESCE(SUM(REWARD.AMOUNT), 0) AS REWARDS
      FROM REWARD
        INNER JOIN accounts_with_delegated_pools ON accounts_with_delegated_pools.stake_address_id = reward.addr_id
      WHERE REWARD.SPENDABLE_EPOCH <= (
          SELECT MAX(NO)
          FROM EPOCH
        )
      GROUP BY accounts_with_delegated_pools.stake_address_id
    ),
    account_total_withdrawals as (
      SELECT accounts_with_delegated_pools.stake_address_id,
        COALESCE(SUM(WITHDRAWAL.AMOUNT), 0) AS WITHDRAWALS
      FROM WITHDRAWAL
        INNER JOIN accounts_with_delegated_pools ON accounts_with_delegated_pools.stake_address_id = WITHDRAWAL.addr_id
      GROUP BY accounts_with_delegated_pools.stake_address_id
    )

  -- INSERT QUERY START
  INSERT INTO GREST.STAKE_DISTRIBUTION_CACHE
    SELECT
      awdp.stake_address,
      pi.pool_id,
      COALESCE(aas.amount, 0) + COALESCE(ado.amount, 0) - COALESCE(adi.amount, 0) + COALESCE(adr.rewards, 0) - COALESCE(adw.withdrawals, 0) AS TOTAL_BALANCE,
      CASE
        WHEN (
          COALESCE(atrew.REWARDS, 0) - COALESCE(atw.WITHDRAWALS, 0)
        ) <= 0 THEN COALESCE(aas.amount, 0) + COALESCE(ado.amount, 0) - COALESCE(adi.amount, 0) + COALESCE(adr.rewards, 0) - COALESCE(adw.withdrawals, 0)
        ELSE
          COALESCE(aas.amount, 0) + COALESCE(ado.amount, 0) - COALESCE(adi.amount, 0) + COALESCE(adr.rewards, 0) - COALESCE(adw.withdrawals, 0) - (COALESCE(atrew.REWARDS, 0) - COALESCE(atw.WITHDRAWALS, 0))
      END AS UTXO,
      COALESCE(atrew.REWARDS, 0) AS REWARDS,
      COALESCE(atw.WITHDRAWALS, 0) AS WITHDRAWALS,
      CASE
        WHEN (
          COALESCE(atrew.REWARDS, 0) - COALESCE(atw.WITHDRAWALS, 0)
        ) <= 0 THEN 0
        ELSE COALESCE(atrew.REWARDS, 0) - COALESCE(atw.WITHDRAWALS, 0)
      END AS REWARDS_AVAILABLE
    from accounts_with_delegated_pools awdp
      INNER JOIN pool_ids pi ON pi.stake_address_id = awdp.stake_address_id
      LEFT JOIN account_active_stake aas ON aas.stake_address_id = awdp.stake_address_id
      LEFT JOIN account_total_rewards atrew ON atrew.stake_address_id = awdp.stake_address_id
      LEFT JOIN account_total_withdrawals atw ON atw.stake_address_id = awdp.stake_address_id
      LEFT JOIN account_delta_input adi ON adi.stake_address_id = awdp.stake_address_id
      LEFT JOIN account_delta_output ado ON ado.stake_address_id = awdp.stake_address_id
      LEFT JOIN account_delta_rewards adr ON adr.stake_address_id = awdp.stake_address_id
      LEFT JOIN account_delta_withdrawals adw ON adw.stake_address_id = awdp.stake_address_id;

  INSERT INTO GREST.CONTROL_TABLE (key, last_value)
    VALUES (
        'stake_distribution_lbh',
        _last_accounted_block_height
      ) ON CONFLICT (key) DO
    UPDATE
    SET last_value = _last_accounted_block_height;

END;
$$;
 
-- HELPER FUNCTION: GREST.STAKE_DISTRIBUTION_CACHE_UPDATE_CHECK
-- Determines whether or not the stake distribution cache should be updated
-- based on the time rule (max once in 60 mins), and ensures previous run completed.

CREATE FUNCTION GREST.STAKE_DISTRIBUTION_CACHE_UPDATE_CHECK () RETURNS VOID LANGUAGE PLPGSQL AS $$
  DECLARE
    _last_update_block_height bigint DEFAULT NULL;
    _current_block_height bigint DEFAULT NULL;
    _last_update_block_diff bigint DEFAULT NULL;
  BEGIN IF (
    SELECT COUNT(pid) > 1
    FROM pg_stat_activity
    WHERE state = 'active'
      AND query ILIKE '%GREST.STAKE_DISTRIBUTION_CACHE_UPDATE_CHECK(%'
      AND datname = (
        SELECT current_database()
      )
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
    IF (_last_update_block_diff >= 185 -- Special case for db-sync restart rollback to epoch start
        OR _last_update_block_diff < 0
      ) THEN
      RAISE NOTICE 'Re-running...';
      CALL GREST.UPDATE_STAKE_DISTRIBUTION_CACHE ();
    ELSE
      RAISE NOTICE 'Minimum block height difference(180) for update not reached, skipping...';
    END IF;

    RETURN;
  END;
$$;

DROP INDEX IF EXISTS GREST.idx_pool_id;
CREATE INDEX idx_pool_id ON GREST.STAKE_DISTRIBUTION_CACHE (POOL_ID);
-- Populated by first crontab execution
