CREATE FUNCTION grest.pool_delegators (_pool_bech32 text, _epoch_no word31type DEFAULT NULL)
  RETURNS TABLE (
    stake_address character varying,
    amount text,
    active_epoch_no bigint
  )
  LANGUAGE plpgsql
  AS $$
  #variable_conflict use_column
DECLARE
  _pool_id bigint;
BEGIN

  IF _epoch_no IS NULL THEN

    RETURN QUERY (
      WITH 
        _all_delegations AS (
          SELECT
            SA.id AS stake_address_id,
            SDC.stake_address,
            (
              CASE WHEN SDC.total_balance >= 0
                THEN SDC.total_balance
                ELSE 0
              END
            ) AS total_balance
          FROM
            grest.stake_distribution_cache AS SDC
            INNER JOIN public.stake_address SA ON SA.view = SDC.stake_address
          WHERE
            SDC.pool_id = _pool_bech32
        )

      SELECT
        AD.stake_address,
        AD.total_balance::text,
        max(D.active_epoch_no)
      FROM
        _all_delegations AS AD
        INNER JOIN public.delegation D ON D.addr_id = AD.stake_address_id
      GROUP BY
        AD.stake_address, AD.total_balance
      ORDER BY
        AD.total_balance DESC
    )

  ELSE

    SELECT id INTO _pool_id FROM pool_hash WHERE pool_hash.view = _pool_bech32;

    RETURN QUERY
      SELECT
        SA.view,
        ES.amount::text,
        max(D.active_epoch_no)
      FROM
        public.epoch_stake ES
        INNER JOIN public.stake_address SA ON ES.addr_id = SA.id
        INNER JOIN public.delegation D ON D.addr_id = SA.id
      WHERE
        ES.pool_id = _pool_id
        AND
        ES.epoch_no = _epoch_no
      GROUP BY
        SA.view, ES.amount
      ORDER BY
        ES.amount DESC;

  END IF;
END;
$$;

COMMENT ON FUNCTION grest.pool_delegators IS 'Return information about delegators by a given pool and epoch number, current if no epoch provided.';
