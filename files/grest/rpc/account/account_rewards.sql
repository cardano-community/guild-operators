CREATE FUNCTION grest.account_rewards (_stake_addresses text[], _epoch_no numeric DEFAULT NULL)
  RETURNS TABLE (
    stake_address varchar,
    rewards json
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

  IF _epoch_no IS NULL THEN
    RETURN QUERY
      SELECT
        sa.view,
        JSON_AGG(
          JSON_BUILD_OBJECT(
          'earned_epoch', r.earned_epoch,
          'spendable_epoch', r.spendable_epoch,
          'amount', r.amount::text,
          'type', r.type,
          'pool_id', ph.view
          )
        ) as rewards
      FROM
        reward AS r
        LEFT JOIN pool_hash AS ph ON r.pool_id = ph.id
        INNER JOIN stake_address sa ON sa.id = r.addr_id
      WHERE
        r.addr_id = ANY(sa_id_list)
      GROUP BY
        sa.id;
  ELSE
    RETURN QUERY
      SELECT
        sa.view,
        JSON_AGG(
          JSON_BUILD_OBJECT(
            'earned_epoch', r.earned_epoch,
            'spendable_epoch', r.spendable_epoch,
            'amount', r.amount::text,
            'type', r.type,
            'pool_id', ph.view
          )
        ) as rewards
      FROM
        reward r
        LEFT JOIN pool_hash ph ON r.pool_id = ph.id
        INNER JOIN stake_address sa ON sa.id = r.addr_id
      WHERE
        r.addr_id = ANY(sa_id_list)
        AND r.earned_epoch = _epoch_no
      GROUP BY
        sa.id;
  END IF;
END;
$$;

COMMENT ON FUNCTION grest.account_rewards IS 'Get the full rewards history (including MIR) for given stake addresses, or certain epoch if specified';

