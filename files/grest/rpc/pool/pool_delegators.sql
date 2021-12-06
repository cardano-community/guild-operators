DROP FUNCTION IF EXISTS grest.pool_delegators (text, uinteger);

CREATE FUNCTION grest.pool_delegators (_pool_bech32 text, _epoch_no uinteger DEFAULT NULL)
  RETURNS TABLE (
    stake_address character varying,
    amount lovelace
  )
  LANGUAGE plpgsql
  AS $$
  #variable_conflict use_column
DECLARE
  _pool_id bigint;
BEGIN
  SELECT id INTO _pool_id FROM pool_hash WHERE pool_hash.view = _pool_bech32;

  IF _epoch_no IS NULL THEN
    RETURN QUERY
      SELECT
        stake_address,
        total_balance::lovelace
      FROM
        grest.stake_distribution_cache AS sdc
      WHERE
        sdc.pool_id = _pool_bech32
      ORDER BY
        sdc.total_balance DESC;
  ELSE
    RETURN QUERY
      SELECT
        SA.view,
        ES.amount
      FROM
        public.epoch_stake ES
        INNER JOIN public.stake_address SA ON ES.addr_id = SA.id
      WHERE
        ES.pool_id = _pool_id
        AND
        ES.epoch_no = _epoch_no
      ORDER BY
        ES.amount DESC;
  END IF;
END;
$$;

COMMENT ON FUNCTION grest.pool_delegators IS 'Return information about delegators by a given pool and epoch number, current if no epoch provided.';
