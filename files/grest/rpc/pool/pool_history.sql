DROP FUNCTION IF EXISTS grest.pool_history (text, uinteger);

CREATE FUNCTION grest.pool_history (_pool_bech32_id text, _epoch_no uinteger DEFAULT NULL)
  RETURNS TABLE (
    epoch_no bigint,
    active_stake public.lovelace,
    active_stake_pct numeric,
    saturation_pct numeric,
    block_cnt bigint,
    delegator_cnt bigint,
    pool_fee_variable double precision,
    pool_fee_fixed public.lovelace,
    pool_fees double precision,
    deleg_rewards double precision,
    epoch_ros numeric
  )
  LANGUAGE plpgsql
  AS $$
  #variable_conflict use_column
DECLARE

BEGIN

  RETURN QUERY
  SELECT    epoch_no, active_stake, active_stake_pct, saturation_pct, block_cnt,
            delegator_cnt, pool_fee_variable, pool_fee_fixed, pool_fees,
            deleg_rewards, epoch_ros
  FROM grest.pool_history_cache phc
  WHERE phc.pool_id = _pool_bech32_id and 
    (_epoch_no is null or 
        phc.epoch_no = _epoch_no)
   ORDER by phc.epoch_no desc;

END;
$$;

COMMENT ON FUNCTION grest.pool_history IS 'Pool block production and reward history for a given epoch (or all epochs if not specified)';
