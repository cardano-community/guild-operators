DROP FUNCTION IF EXISTS koios.pool_delegators (text);

CREATE FUNCTION koios.pool_delegators (_pool_bech32 text)
  RETURNS TABLE (
    stake_address character varying,
    live_stake numeric)
  LANGUAGE plpgsql
  AS $$
  # variable_conflict use_column
BEGIN
  RETURN QUERY
  SELECT
    stake_address,
    total_balance
  FROM
    koios.stake_distribution_cache AS sdc
  WHERE
    sdc.pool_id = _pool_bech32
  ORDER BY
    sdc.total_balance DESC;
END;
$$;

COMMENT ON FUNCTION koios.pool_delegators IS 'Return information about current delegators by a given pool';

