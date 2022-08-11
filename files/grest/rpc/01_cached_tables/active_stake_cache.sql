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
        EPOCH_STAKE.EPOCH_NO >= _last_pool_active_stake_cache_epoch_no
          AND
        EPOCH_STAKE.EPOCH_NO <= _epoch_no
      GROUP BY
        POOL_HASH.VIEW,
        EPOCH_STAKE.EPOCH_NO
    ON CONFLICT (
      POOL_ID,
      EPOCH_NO
    ) DO UPDATE
      SET AMOUNT = EXCLUDED.AMOUNT
      WHERE AMOUNT IS DISTINCT FROM EXCLUDED.AMOUNT;
    
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
        EPOCH_STAKE.EPOCH_NO >= _last_epoch_active_stake_cache_epoch_no
          AND
        EPOCH_STAKE.EPOCH_NO <= _epoch_no
      GROUP BY
        EPOCH_STAKE.EPOCH_NO
      ON CONFLICT (
        EPOCH_NO
      ) DO UPDATE
        SET AMOUNT = EXCLUDED.AMOUNT
        WHERE AMOUNT IS DISTINCT FROM EXCLUDED.AMOUNT;

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
