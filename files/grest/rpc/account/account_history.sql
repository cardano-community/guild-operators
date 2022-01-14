DROP FUNCTION IF EXISTS grest.account_history (text, integer);

CREATE FUNCTION grest.account_history (
  _address text DEFAULT NULL,
  _epoch_no integer DEFAULT NULL
  ) RETURNS TABLE (
      stake_address varchar,
      pool_id varchar,
      epoch_no bigint,
      active_stake lovelace
    )
  LANGUAGE PLPGSQL
  AS
$$
  DECLARE
    SA_ID integer DEFAULT NULL;
  BEGIN
    -- Payment address
    IF
      _address NOT LIKE 'stake%'
    THEN
      SELECT
        STAKE_ADDRESS.VIEW INTO _address
      FROM
        PUBLIC.TX_OUT
        INNER JOIN PUBLIC.STAKE_ADDRESS ON STAKE_ADDRESS.ID = TX_OUT.STAKE_ADDRESS_ID
      WHERE
        TX_OUT.ADDRESS = _address
      LIMIT
        1;
    END IF;

    IF
      _epoch_no IS NOT NULL
    THEN
      RETURN QUERY
        SELECT
          ACCOUNT_ACTIVE_STAKE_CACHE.stake_address,
          ACCOUNT_ACTIVE_STAKE_CACHE.pool_id,
          ACCOUNT_ACTIVE_STAKE_CACHE.epoch_no,
          ACCOUNT_ACTIVE_STAKE_CACHE.amount as active_stake
        FROM
          GREST.ACCOUNT_ACTIVE_STAKE_CACHE
        WHERE
          ACCOUNT_ACTIVE_STAKE_CACHE.epoch_no = _epoch_no
            AND
          ACCOUNT_ACTIVE_STAKE_CACHE.stake_address = _address;
    ELSE
      RETURN QUERY
        SELECT
          ACCOUNT_ACTIVE_STAKE_CACHE.stake_address,
          ACCOUNT_ACTIVE_STAKE_CACHE.pool_id,
          ACCOUNT_ACTIVE_STAKE_CACHE.epoch_no,
          ACCOUNT_ACTIVE_STAKE_CACHE.amount as active_stake
        FROM
          GREST.ACCOUNT_ACTIVE_STAKE_CACHE
        WHERE
          ACCOUNT_ACTIVE_STAKE_CACHE.stake_address = _address;
    END IF;
  END;
$$;

COMMENT ON FUNCTION grest.account_history IS 'Get the active stake history of an account';

