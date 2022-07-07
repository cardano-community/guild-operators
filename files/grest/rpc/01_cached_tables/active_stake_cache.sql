CREATE TABLE IF NOT EXISTS GREST.POOL_ACTIVE_STAKE_CACHE (
  POOL_ID varchar NOT NULL,
  EPOCH_NO bigint NOT NULL,
  AMOUNT LOVELACE NOT NULL,
  PRIMARY KEY (POOL_ID, EPOCH_NO)
);

CREATE TABLE IF NOT EXISTS GREST.EPOCH_ACTIVE_STAKE_CACHE (
  EPOCH_NO bigint NOT NULL,
  AMOUNT LOVELACE NOT NULL,
  PRIMARY KEY (EPOCH_NO)
);

CREATE TABLE IF NOT EXISTS GREST.ACCOUNT_ACTIVE_STAKE_CACHE (
  STAKE_ADDRESS varchar NOT NULL,
  POOL_ID varchar NOT NULL,
  EPOCH_NO bigint NOT NULL,
  AMOUNT LOVELACE NOT NULL,
  PRIMARY KEY (STAKE_ADDRESS, POOL_ID, EPOCH_NO)
);

CREATE TABLE IF NOT EXISTS GREST.LAST_TWO_EPOCHS_ACCOUNT_ACTIVE_STAKE_CACHE (
  STAKE_ADDRESS varchar,
  POOL_ID varchar,
  TOTAL_BALANCE numeric,
  EPOCH_NO bigint,
  PRIMARY KEY (STAKE_ADDRESS, EPOCH_NO)
);

CREATE FUNCTION grest.active_stake_cache_update_check ()
  RETURNS BOOLEAN
  LANGUAGE plpgsql
  AS
$$
  DECLARE
  _current_epoch_no integer;
  _last_active_stake_validated_epoch text;
  BEGIN

    -- Get Last Active Stake Validated Epoch
    SELECT last_value
      INTO _last_active_stake_validated_epoch
    FROM
      grest.control_table
    WHERE
      key = 'last_active_stake_validated_epoch';

    -- Get Current Epoch
    SELECT MAX(NO)
      INTO _current_epoch_no
    FROM epoch;

    RAISE NOTICE 'Current epoch: %',
      _current_epoch_no;
    RAISE NOTICE 'Last active stake validated epoch: %',
      _last_active_stake_validated_epoch;

    IF 
      _current_epoch_no > COALESCE(_last_active_stake_validated_epoch::integer, 0)
    THEN 
      RETURN TRUE;
    END IF;

    RETURN FALSE;
  END;
$$;

COMMENT ON FUNCTION grest.active_stake_cache_update_check
  IS 'Internal function to determine whether active stake cache should be updated';

CREATE FUNCTION grest.active_stake_cache_update (_epoch_no integer)
  RETURNS VOID
  LANGUAGE plpgsql
  AS
$$
  DECLARE
  _last_pool_active_stake_cache_epoch_no integer;
  _last_epoch_active_stake_cache_epoch_no integer;
  _last_account_active_stake_cache_epoch_no integer;
  BEGIN

    /* CHECK PREVIOUS QUERY FINISHED RUNNING */
    IF (
      SELECT
        COUNT(pid) > 1
      FROM
        pg_stat_activity
      WHERE
        state = 'active'
          AND 
        query ILIKE '%grest.active_stake_cache_update(%'
          AND 
        datname = (
          SELECT
          current_database()
      )
    ) THEN 
      RAISE EXCEPTION 
        'Previous query still running but should have completed! Exiting...';
    END IF;
    
    /* POOL ACTIVE STAKE CACHE */
    SELECT
      COALESCE(MAX(epoch_no), 0)
    INTO
      _last_pool_active_stake_cache_epoch_no
    FROM
      GREST.POOL_ACTIVE_STAKE_CACHE;

    INSERT INTO GREST.POOL_ACTIVE_STAKE_CACHE
      SELECT
        POOL_HASH.VIEW AS POOL_ID,
        EPOCH_STAKE.EPOCH_NO,
        SUM(EPOCH_STAKE.AMOUNT) AS AMOUNT
      FROM
        PUBLIC.EPOCH_STAKE
        INNER JOIN PUBLIC.POOL_HASH ON POOL_HASH.ID = EPOCH_STAKE.POOL_ID
      WHERE
        -- no need to worry about epoch 0 as no stake then
        EPOCH_STAKE.EPOCH_NO > _last_pool_active_stake_cache_epoch_no
          AND
        EPOCH_STAKE.EPOCH_NO <= _epoch_no
      GROUP BY
        POOL_HASH.VIEW,
        EPOCH_STAKE.EPOCH_NO
    ON CONFLICT (
      POOL_ID,
      EPOCH_NO
    ) DO UPDATE
      SET AMOUNT = EXCLUDED.AMOUNT;
    
    /* EPOCH ACTIVE STAKE CACHE */
    SELECT
      COALESCE(MAX(epoch_no), 0)
    INTO _last_epoch_active_stake_cache_epoch_no
    FROM
      GREST.EPOCH_ACTIVE_STAKE_CACHE;

    INSERT INTO GREST.EPOCH_ACTIVE_STAKE_CACHE
      SELECT
        EPOCH_STAKE.EPOCH_NO,
        SUM(EPOCH_STAKE.AMOUNT) AS AMOUNT
      FROM
        PUBLIC.EPOCH_STAKE
      WHERE
        EPOCH_STAKE.EPOCH_NO > _last_epoch_active_stake_cache_epoch_no
          AND
        EPOCH_STAKE.EPOCH_NO <= _epoch_no
      GROUP BY
        EPOCH_STAKE.EPOCH_NO
      ON CONFLICT (
        EPOCH_NO
      ) DO UPDATE
        SET AMOUNT = EXCLUDED.AMOUNT;

    /* ACCOUNT ACTIVE STAKE CACHE */
    SELECT
      COALESCE(MAX(epoch_no), (_epoch_no - 4) )
    INTO _last_account_active_stake_cache_epoch_no
    FROM
      GREST.ACCOUNT_ACTIVE_STAKE_CACHE;

    INSERT INTO GREST.ACCOUNT_ACTIVE_STAKE_CACHE
      SELECT
        STAKE_ADDRESS.VIEW AS STAKE_ADDRESS,
        POOL_HASH.VIEW AS POOL_ID,
        EPOCH_STAKE.EPOCH_NO AS EPOCH_NO,
        SUM(EPOCH_STAKE.AMOUNT) AS AMOUNT
      FROM
        PUBLIC.EPOCH_STAKE
        INNER JOIN PUBLIC.POOL_HASH ON POOL_HASH.ID = EPOCH_STAKE.POOL_ID
        INNER JOIN PUBLIC.STAKE_ADDRESS ON STAKE_ADDRESS.ID = EPOCH_STAKE.ADDR_ID
      WHERE
        EPOCH_STAKE.EPOCH_NO > _last_account_active_stake_cache_epoch_no
          AND
        EPOCH_STAKE.EPOCH_NO <= _epoch_no
      GROUP BY
        STAKE_ADDRESS.ID,
        POOL_HASH.ID,
        EPOCH_STAKE.EPOCH_NO
    ON CONFLICT (
      STAKE_ADDRESS,
      POOL_ID,
      EPOCH_NO
    ) DO UPDATE
      SET AMOUNT = EXCLUDED.AMOUNT;

    DELETE FROM GREST.ACCOUNT_ACTIVE_STAKE_CACHE
      WHERE EPOCH_NO <= (_epoch_no - 4);

    /* CONTROL TABLE ENTRY */
    PERFORM grest.update_control_table(
      'last_active_stake_validated_epoch',
      _epoch_no::text
    );
  END;
$$;

COMMENT ON FUNCTION grest.active_stake_cache_update
  IS 'Internal function to update active stake cache (epoch, pool, and account tables).';

-- This function captures the stake snapshot of previous epoch (and the one before)
CREATE OR REPLACE PROCEDURE GREST.CAPTURE_LAST_EPOCH_SNAPSHOT ()
LANGUAGE PLPGSQL
AS $$
DECLARE
  _previous_epoch_no bigint;
  _previous_epoch_last_block_id bigint;
  _active_stake_baseline_epoch bigint;
  _last_active_stake_block_id bigint;
  _lower_bound_account_tx_id bigint;
  _upper_bound_account_tx_id bigint;
BEGIN

  -- Set-up interval limits for previous epoch
  SELECT MAX(NO) - 1 INTO _previous_epoch_no FROM PUBLIC.EPOCH;

  SELECT _previous_epoch_no - 2 INTO _active_stake_baseline_epoch;

  SELECT id INTO _last_active_stake_block_id FROM PUBLIC.BLOCK
    WHERE epoch_no = _active_stake_baseline_epoch
      AND block_no IS NOT NULL
    ORDER BY block_no DESC LIMIT 1;

  SELECT id INTO _previous_epoch_last_block_id FROM PUBLIC.BLOCK
    WHERE epoch_no = _previous_epoch_no
      AND block_no IS NOT NULL
    ORDER BY block_no DESC LIMIT 1;

  SELECT MAX(id) INTO _lower_bound_account_tx_id FROM PUBLIC.TX
    WHERE block_id <= _last_active_stake_block_id;

  SELECT MAX(id) INTO _upper_bound_account_tx_id FROM PUBLIC.TX
    WHERE block_id <= _previous_epoch_last_block_id;

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
          -- Account must be present in epoch_stake table for the last validated epoch
          AND EXISTS (
            SELECT TRUE FROM EPOCH_STAKE
              WHERE EPOCH_STAKE.EPOCH_NO = _previous_epoch_no
                AND EPOCH_STAKE.ADDR_ID = STAKE_ADDRESS.ID
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
        WHERE epoch_no = _previous_epoch_no
    ),
    account_delta_tx_ins AS (
      SELECT awdp.stake_address_id, tx_in.tx_out_id AS txoid, tx_in.tx_out_index AS txoidx FROM tx_in
        LEFT JOIN tx_out ON tx_in.tx_out_id = tx_out.tx_id AND tx_in.tx_out_index::smallint = tx_out.index::smallint
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.stake_address_id = tx_out.stake_address_id
        WHERE tx_in.tx_in_id > _lower_bound_account_tx_id
          AND tx_in.tx_in_id <= _upper_bound_account_tx_id
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
      WHERE TX_OUT.TX_ID > _lower_bound_account_tx_id
        AND TX_OUT.TX_ID <= _upper_bound_account_tx_id
      GROUP BY awdp.stake_address_id
    ),
    account_delta_rewards AS (
      SELECT awdp.stake_address_id, COALESCE(SUM(reward.amount), 0) AS REWARDS
      FROM REWARD
        INNER JOIN accounts_with_delegated_pools awdp ON awdp.stake_address_id = reward.addr_id
      WHERE
        REWARD.SPENDABLE_EPOCH >= _previous_epoch_no
          AND REWARD.SPENDABLE_EPOCH <= _previous_epoch_no + 1
      GROUP BY awdp.stake_address_id
    ),
    account_delta_withdrawals AS (
      SELECT accounts_with_delegated_pools.stake_address_id, COALESCE(SUM(withdrawal.amount), 0) AS withdrawals
      FROM withdrawal
        INNER JOIN accounts_with_delegated_pools ON accounts_with_delegated_pools.stake_address_id = withdrawal.addr_id
      WHERE withdrawal.tx_id > _lower_bound_account_tx_id
        AND withdrawal.tx_id <= _upper_bound_account_tx_id
      GROUP BY accounts_with_delegated_pools.stake_address_id
    )

  -- INSERT QUERY START
  INSERT INTO GREST.last_two_epochs_account_active_stake_cache
    SELECT
      awdp.stake_address,
      pi.pool_id,
      COALESCE(aas.amount, 0) + COALESCE(ado.amount, 0) - COALESCE(adi.amount, 0) + COALESCE(adr.rewards, 0) - COALESCE(adw.withdrawals, 0)
        AS TOTAL_BALANCE,
      _previous_epoch_no
    from accounts_with_delegated_pools awdp
      INNER JOIN pool_ids pi ON pi.stake_address_id = awdp.stake_address_id
      LEFT JOIN account_active_stake aas ON aas.stake_address_id = awdp.stake_address_id
      LEFT JOIN account_delta_input adi ON adi.stake_address_id = awdp.stake_address_id
      LEFT JOIN account_delta_output ado ON ado.stake_address_id = awdp.stake_address_id
      LEFT JOIN account_delta_rewards adr ON adr.stake_address_id = awdp.stake_address_id
      LEFT JOIN account_delta_withdrawals adw ON adw.stake_address_id = awdp.stake_address_id
    ON CONFLICT (STAKE_ADDRESS, EPOCH_NO) DO
      UPDATE
        SET POOL_ID = EXCLUDED.POOL_ID,
          TOTAL_BALANCE = EXCLUDED.TOTAL_BALANCE;

    INSERT INTO GREST.CONTROL_TABLE (key, last_value)
    VALUES (
        'last_stake_snapshot_epoch',
        _previous_epoch_no
      ) ON CONFLICT (key) DO
    UPDATE
    SET last_value = _previous_epoch_no;

    DELETE FROM grest.last_two_epochs_account_active_stake_cache
      WHERE epoch_no <= _previous_epoch_no - 2;
END;
$$;