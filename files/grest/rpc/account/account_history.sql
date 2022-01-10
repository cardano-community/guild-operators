DROP FUNCTION IF EXISTS grest.account_history (text, integer);

CREATE FUNCTION grest.account_history (
  _address text DEFAULT NULL,
  _epoch_no integer DEFAULT NULL
  ) RETURNS TABLE (
      stake_address varchar,
      pool_id varchar,
      epoch_no bigint,
      amount lovelace
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
        TX_OUT
        INNER JOIN STAKE_ADDRESS ON STAKE_ADDRESS.ID = TX_OUT.STAKE_ADDRESS_ID
      WHERE
        TX_OUT.ADDRESS = _address
      LIMIT
        1;
    END IF;
    

    RETURN QUERY
      SELECT
        *
      FROM
        GREST.ACCOUNT_ACTIVE_STAKE_CACHE
      WHERE
        ACCOUNT_ACTIVE_STAKE_CACHE.stake_address = _address;
  END;
$$;

COMMENT ON FUNCTION grest.account_history IS 'Get the active stake history of an account';

