CREATE FUNCTION grest.account_history (
  _address text,
  _epoch_no integer DEFAULT NULL
  ) RETURNS TABLE (
      stake_address varchar,
      pool_id varchar,
      epoch_no bigint,
      active_stake text
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
          sa.view as stake_address,
          ph.view as pool_id,
          es.epoch_no::bigint,
          es.amount::text as active_stake
        FROM
          EPOCH_STAKE es
        LEFT JOIN stake_address sa ON sa.id = es.addr_id
        LEFT JOIN pool_hash ph ON ph.id = es.pool_id
        WHERE
          es.epoch_no = _epoch_no
            AND
          sa.view = _address;
    ELSE
      RETURN QUERY
        SELECT
          sa.view as stake_address,
          ph.view as pool_id,
          es.epoch_no::bigint,
          es.amount::text as active_stake
        FROM
          EPOCH_STAKE es
        LEFT JOIN stake_address sa ON sa.id = es.addr_id
        LEFT JOIN pool_hash ph ON ph.id = es.pool_id
        WHERE
          sa.view = _address;
    END IF;
  END;
$$;

COMMENT ON FUNCTION grest.account_history IS 'Get the active stake history of an account';

