CREATE FUNCTION grest.account_history (_stake_addresses text[], _epoch_no integer DEFAULT NULL)
  RETURNS TABLE (
    stake_address varchar,
    history json
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  sa_id_list integer[];
BEGIN
  SELECT INTO sa_id_list
    ARRAY_AGG(STAKE_ADDRESS.ID)
  FROM
    STAKE_ADDRESS
  WHERE
    STAKE_ADDRESS.VIEW = ANY(_stake_addresses);

  IF _epoch_no IS NOT NULL THEN
    RETURN QUERY
      SELECT
        sa.view as stake_address,
        JSON_AGG(
          JSON_BUILD_OBJECT(
            'pool_id', ph.view,
            'epoch_no', es.epoch_no::bigint,
            'active_stake', es.amount::text
          )
        )
      FROM
        EPOCH_STAKE es
        LEFT JOIN stake_address sa ON sa.id = es.addr_id
        LEFT JOIN pool_hash ph ON ph.id = es.pool_id
      WHERE
        es.epoch_no = _epoch_no
        AND
        sa.id = ANY(sa_id_list)
      GROUP BY
        sa.view;
  ELSE
    RETURN QUERY
      SELECT
        sa.view as stake_address,
        JSON_AGG(
          JSON_BUILD_OBJECT(
            'pool_id', ph.view,
            'epoch_no', es.epoch_no::bigint,
            'active_stake', es.amount::text
          )
        )
      FROM
        EPOCH_STAKE es
        LEFT JOIN stake_address sa ON sa.id = es.addr_id
        LEFT JOIN pool_hash ph ON ph.id = es.pool_id
      WHERE
        sa.id = ANY(sa_id_list)
      GROUP BY
        sa.view;
  END IF;
END;
$$;

COMMENT ON FUNCTION grest.account_history IS 'Get the active stake history of given accounts';

