CREATE TABLE IF NOT EXISTS grest.epoch_info_cache (
  epoch_no word31type PRIMARY KEY NOT NULL,
  i_out_sum word128type NOT NULL,
  i_fees lovelace NOT NULL,
  i_tx_count word31type NOT NULL,
  i_blk_count word31type NOT NULL,
  i_first_block_time numeric UNIQUE NOT NULL,
  i_last_block_time numeric UNIQUE NOT NULL,
  i_total_rewards lovelace DEFAULT NULL,
  i_avg_blk_reward lovelace DEFAULT NULL,
  i_last_tx_id bigint DEFAULT NULL,
  p_min_fee_a word31type NULL,
  p_min_fee_b word31type NULL,
  p_max_block_size word31type NULL,
  p_max_tx_size word31type NULL,
  p_max_bh_size word31type NULL,
  p_key_deposit lovelace NULL,
  p_pool_deposit lovelace NULL,
  p_max_epoch word31type NULL,
  p_optimal_pool_count word31type NULL,
  p_influence double precision NULL,
  p_monetary_expand_rate double precision NULL,
  p_treasury_growth_rate double precision NULL,
  p_decentralisation double precision NULL,
  p_extra_entropy text,
  p_protocol_major word31type NULL,
  p_protocol_minor word31type NULL,
  p_min_utxo_value lovelace NULL,
  p_min_pool_cost lovelace NULL,
  p_nonce text,
  p_block_hash text NOT NULL,
  p_cost_models character varying,
  p_price_mem double precision,
  p_price_step double precision,
  p_max_tx_ex_mem word64type,
  p_max_tx_ex_steps word64type,
  p_max_block_ex_mem word64type,
  p_max_block_ex_steps word64type,
  p_max_val_size word64type,
  p_collateral_percent word31type,
  p_max_collateral_inputs word31type,
  p_coins_per_utxo_size lovelace
);

COMMENT ON TABLE grest.epoch_info_cache IS 'Contains detailed info for epochs including protocol parameters';

CREATE FUNCTION grest.EPOCH_INFO_CACHE_UPDATE (
    _epoch_no_to_insert_from bigint default NULL
  )
  RETURNS void
  LANGUAGE plpgsql
  AS $$
DECLARE
  _curr_epoch bigint;
  _latest_epoch_no_in_cache bigint;
BEGIN
  -- Check previous cache update completed before running
  IF (
    SELECT
      COUNT(pid) > 1
    FROM
      pg_stat_activity
    WHERE
      state = 'active' AND query ILIKE '%GREST.EPOCH_INFO_CACHE_UPDATE%'
      AND datname = (SELECT current_database())
    ) THEN
        RAISE EXCEPTION 'Previous EPOCH_INFO_CACHE_UPDATE query still running but should have completed! Exiting...';
  END IF;

  -- GREST control table entry
  PERFORM grest.update_control_table(
    'epoch_info_cache_last_updated',
    (now() at time zone 'utc')::text
  );

  SELECT
    MAX(no) INTO _curr_epoch
  FROM
    public.epoch;

  IF _epoch_no_to_insert_from IS NULL THEN
    SELECT
      COALESCE(MAX(epoch_no), 0) INTO _latest_epoch_no_in_cache
    FROM
      grest.epoch_info_cache;

    IF _latest_epoch_no_in_cache = 0 THEN
      RAISE NOTICE 'Epoch info cache table is empty, starting initial population...';
      PERFORM grest.EPOCH_INFO_CACHE_UPDATE (0);
      RETURN;
    END IF;

    RAISE NOTICE 'Latest epoch in cache: %, current epoch: %.', _latest_epoch_no_in_cache, _curr_epoch;

    IF _curr_epoch = _latest_epoch_no_in_cache THEN
      RAISE NOTICE 'Updating latest epoch info in cache...';
      PERFORM grest.UPDATE_LATEST_EPOCH_INFO_CACHE(_curr_epoch, _latest_epoch_no_in_cache);
      RETURN;
    END IF;

    IF _latest_epoch_no_in_cache > _curr_epoch THEN
      RAISE NOTICE 'No update needed, exiting...';
      RETURN;
    END IF;

    RAISE NOTICE 'Updating cache with new epoch(s) data...';
    -- We need to update last epoch one last time before going to new one
    PERFORM grest.UPDATE_LATEST_EPOCH_INFO_CACHE(_curr_epoch, _latest_epoch_no_in_cache);
    -- Populate rewards data for epoch n - 2
    PERFORM grest.UPDATE_TOTAL_REWARDS_EPOCH_INFO_CACHE(_latest_epoch_no_in_cache - 1);
    -- Continue new epoch data insert
    _epoch_no_to_insert_from := _latest_epoch_no_in_cache + 1;
  END IF;  

  RAISE NOTICE 'Deleting cache records from epoch % onwards...', _epoch_no_to_insert_from;
  DELETE FROM grest.epoch_info_cache
  WHERE epoch_no >= _epoch_no_to_insert_from;

  INSERT INTO grest.epoch_info_cache
    SELECT DISTINCT ON (b.time)
      e.no AS epoch_no,
      e.out_sum AS i_out_sum,
      e.fees AS i_fees,
      e.tx_count AS i_tx_count,
      e.blk_count AS i_blk_count,
      EXTRACT(epoch from e.start_time) AS i_first_block_time,
      EXTRACT(epoch from e.end_time) AS i_last_block_time,
      CASE -- populated in epoch n + 2
        WHEN e.no <= _curr_epoch - 2 THEN reward_pot.amount 
        ELSE NULL
      END AS i_total_rewards,
      CASE -- populated in epoch n + 2
        WHEN e.no <= _curr_epoch THEN ROUND(reward_pot.amount / e.blk_count)
        ELSE NULL
      END AS i_avg_blk_reward, 
      last_tx.tx_id AS i_last_tx_id,
      ep.min_fee_a AS p_min_fee_a,
      ep.min_fee_b AS p_min_fee_b,
      ep.max_block_size AS p_max_block_size,
      ep.max_tx_size AS p_max_tx_size,
      ep.max_bh_size AS p_max_bh_size,
      ep.key_deposit AS p_key_deposit,
      ep.pool_deposit AS p_pool_deposit,
      ep.max_epoch AS p_max_epoch,
      ep.optimal_pool_count AS p_optimal_pool_count,
      ep.influence AS p_influence,
      ep.monetary_expand_rate AS p_monetary_expand_rate,
      ep.treasury_growth_rate AS p_treasury_growth_rate,
      ep.decentralisation AS p_decentralisation,
      ENCODE(ep.extra_entropy, 'hex') AS p_extra_entropy,
      ep.protocol_major AS p_protocol_major,
      ep.protocol_minor AS p_protocol_minor,
      ep.min_utxo_value AS p_min_utxo_value,
      ep.min_pool_cost AS p_min_pool_cost,
      ENCODE(ep.nonce, 'hex') AS p_nonce,
      ENCODE(b.hash, 'hex') AS p_block_hash,
      cm.costs AS p_cost_models,
      ep.price_mem AS p_price_mem,
      ep.price_step AS p_price_step,
      ep.max_tx_ex_mem AS p_max_tx_ex_mem,
      ep.max_tx_ex_steps AS p_max_tx_ex_steps,
      ep.max_block_ex_mem AS p_max_block_ex_mem,
      ep.max_block_ex_steps AS p_max_block_ex_steps,
      ep.max_val_size AS p_max_val_size,
      ep.collateral_percent AS p_collateral_percent,
      ep.max_collateral_inputs AS p_max_collateral_inputs,
      ep.coins_per_utxo_size AS p_coins_per_utxo_size
    FROM
      epoch e
      LEFT JOIN epoch_param ep ON ep.epoch_no = e.no
      LEFT JOIN cost_model cm ON cm.id = ep.cost_model_id
      INNER JOIN block b ON b.time = e.start_time
      LEFT JOIN LATERAL (
        SELECT
          e.no,
          SUM(r.amount) as amount
        FROM
          reward r
        WHERE
          r.earned_epoch = e.no
        GROUP BY
          e.no
      ) reward_pot ON TRUE
      LEFT JOIN LATERAL (
        SELECT
          MAX(tx.id) AS tx_id
        FROM
          block b
          INNER JOIN tx ON tx.block_id = b.id
        WHERE
          b.epoch_no = e.no
      ) last_tx ON TRUE
    WHERE
      e.no >= _epoch_no_to_insert_from
    ORDER BY
      b.time ASC,
      b.id ASC,
      e.no ASC;
END;
$$;

-- Helper function for updating current epoch data
CREATE FUNCTION grest.UPDATE_LATEST_EPOCH_INFO_CACHE (_curr_epoch bigint, _epoch_no_to_update bigint)
  RETURNS void
  LANGUAGE plpgsql
  AS $$
BEGIN

  -- only update last tx id in case of new epoch
  IF _curr_epoch <> _epoch_no_to_update THEN
    UPDATE
      grest.epoch_info_cache
    SET
      i_last_tx_id = last_tx.tx_id
    FROM (
      SELECT
        MAX(tx.id) AS tx_id
      FROM
        block b
        INNER JOIN tx ON tx.block_id = b.id
      WHERE
        b.epoch_no = _epoch_no_to_update
    ) last_tx
    WHERE epoch_no = _epoch_no_to_update;
  END IF;

  UPDATE
    grest.epoch_info_cache
  SET
    i_out_sum = update_table.out_sum,
    i_fees = update_table.fees,
    i_tx_count = update_table.tx_count,
    i_blk_count = update_table.blk_count,
    i_last_block_time = EXTRACT(epoch from update_table.end_time)
  FROM (
    SELECT
      e.out_sum,
      e.fees,
      e.tx_count,
      e.blk_count,
      e.end_time
    FROM
      epoch e
    WHERE
      e.no = _epoch_no_to_update
  ) update_table
  WHERE
    epoch_no = _epoch_no_to_update;
END;
$$;

-- Helper function for updating epoch total rewards (epoch n - 2)
CREATE FUNCTION grest.UPDATE_TOTAL_REWARDS_EPOCH_INFO_CACHE (_epoch_no_to_update bigint)
  RETURNS void
  LANGUAGE plpgsql
  AS $$
BEGIN
  UPDATE
    grest.epoch_info_cache
  SET
    i_total_rewards = update_t.amount,
    i_avg_blk_reward = update_t.avg_blk_reward
  FROM (
    SELECT
      reward_pot.amount,
      ROUND(reward_pot.amount /  e.blk_count) AS avg_blk_reward
    FROM (
      SELECT
        r.earned_epoch,
        SUM(r.amount) AS amount
      FROM
        reward r
      WHERE
        r.earned_epoch = _epoch_no_to_update
      GROUP BY
        r.earned_epoch
    ) reward_pot
    INNER JOIN epoch e ON reward_pot.earned_epoch = e.no
      AND e.no = _epoch_no_to_update
  ) update_t
  WHERE
    epoch_no = _epoch_no_to_update;
END;
$$;

