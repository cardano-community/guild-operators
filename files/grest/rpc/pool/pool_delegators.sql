CREATE FUNCTION grest.pool_delegators (_pool_bech32 text)
  RETURNS TABLE (
    stake_address character varying,
    amount text,
    active_epoch_no bigint,
    latest_delegation_tx_hash text
  )
  LANGUAGE plpgsql
  AS $$
  #variable_conflict use_column
DECLARE
  _pool_id bigint;
BEGIN
  RETURN QUERY 
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

    SELECT DISTINCT ON (AD.stake_address)
      AD.stake_address,
      AD.total_balance::text,
      D.active_epoch_no,
      ENCODE(tx.hash, 'hex')
    FROM
      _all_delegations AS AD
      INNER JOIN public.delegation D ON D.addr_id = AD.stake_address_id
      INNER JOIN public.tx ON tx.id = D.tx_id
    ORDER BY
      AD.stake_address, D.tx_id DESC;
END;
$$;

COMMENT ON FUNCTION grest.pool_delegators IS 'Return information about live delegators for a given pool.';
