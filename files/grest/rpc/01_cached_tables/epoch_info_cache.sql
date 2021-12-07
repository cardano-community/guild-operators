DROP TABLE IF EXISTS grest.epoch_info_cache;

CREATE TABLE grest.epoch_info_cache (
  epoch uinteger PRIMARY KEY NOT NULL,
  i_out_sum word128type NOT NULL,
  i_fees lovelace NOT NULL,
  i_tx_count uinteger NOT NULL,
  i_blk_count uinteger NOT NULL,
  i_first_block_time timestamp without time zone UNIQUE NOT NULL,
  i_last_block_time timestamp without time zone UNIQUE NOT NULL,
  p_min_fee_a uinteger NULL,
  p_min_fee_b uinteger NULL,
  p_max_block_size uinteger NULL,
  p_max_tx_size uinteger NULL,
  p_max_bh_size uinteger NULL,
  p_key_deposit lovelace NULL,
  p_pool_deposit lovelace NULL,
  p_max_epoch uinteger NULL,
  p_optimal_pool_count uinteger NULL,
  p_influence double precision NULL,
  p_monetary_expand_rate double precision NULL,
  p_treasury_growth_rate double precision NULL,
  p_decentralisation double precision NULL,
  p_entropy text,
  p_protocol_major uinteger NULL,
  p_protocol_minor uinteger NULL,
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
  p_collateral_percent uinteger,
  p_max_collateral_inputs uinteger,
  p_coins_per_utxo_word lovelace
);

COMMENT ON TABLE grest.epoch_info_cache IS 'Get detailed info for epoch including protocol parameters';

INSERT INTO grest.epoch_info_cache SELECT DISTINCT ON (b.time)
  e.no AS epoch,
  e.out_sum AS i_out_sum,
  e.fees AS i_fees,
  e.tx_count AS i_tx_count,
  e.blk_count AS i_blk_count,
  e.start_time AS i_first_block_time,
  e.end_time AS i_last_block_time,
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
  ENCODE(ep.entropy, 'hex') AS p_entropy,
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
  ep.coins_per_utxo_word AS p_coins_per_utxo_word
FROM
  epoch e
  LEFT JOIN epoch_param ep ON ep.epoch_no = e.no
  LEFT JOIN cost_model cm ON cm.id = ep.cost_model_id
  INNER JOIN block b ON b.time = e.start_time
ORDER BY
  b.time ASC,
  b.id ASC,
  e.no ASC;

-- Trigger for updating current epoch data
DROP TRIGGER IF EXISTS epoch_info_update_trigger ON public.block;

DROP FUNCTION IF EXISTS grest.epoch_info_update;

CREATE FUNCTION grest.epoch_info_update ()
  RETURNS TRIGGER
  AS $epoch_info_update$
DECLARE
  _current_epoch integer DEFAULT NULL;
  _current_end_time timestamp without time zone DEFAULT NULL;
  _current_end_time_cache timestamp without time zone DEFAULT NULL;
BEGIN
  SELECT
    end_time
  FROM
    epoch
  WHERE
    NO = (
      SELECT
        MAX(NO)
      FROM
        epoch) INTO _current_end_time;
  SELECT
    i_last_block_time
  FROM
    grest.epoch_info_cache
  WHERE
    epoch = (
      SELECT
        MAX(epoch)
      FROM
        grest.epoch_info_cache) INTO _current_end_time_cache;
  IF (
    SELECT
      EXTRACT(EPOCH FROM (_current_end_time - _current_end_time_cache)) >= 900) THEN
    SELECT
      MAX(epoch)
    FROM
      grest.epoch_info_cache INTO _current_epoch;
    UPDATE
      grest.epoch_info_cache
    SET
      i_out_sum = update_table.out_sum,
      i_fees = update_table.fees,
      i_tx_count = update_table.tx_count,
      i_blk_count = update_table.blk_count,
      i_last_block_time = update_table.end_time
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
        e.no = _current_epoch) update_table
  WHERE
    epoch = _current_epoch;
  END IF;
  RETURN NULL;
END;
$epoch_info_update$
LANGUAGE plpgsql;

CREATE TRIGGER epoch_info_update_trigger
  AFTER INSERT ON public.block
  FOR EACH STATEMENT
  EXECUTE PROCEDURE grest.epoch_info_update ();

-- Trigger for inserting new epoch data
DROP TRIGGER IF EXISTS new_epoch_insert_trigger ON public.epoch;

DROP FUNCTION IF EXISTS grest.new_epoch_insert CASCADE;

CREATE FUNCTION grest.new_epoch_insert ()
  RETURNS TRIGGER
  AS $new_epoch_insert$
DECLARE
  _previous_epoch integer DEFAULT NULL;
BEGIN
  -- First, we have to make sure that the previous epoch has been updated one last time
  SELECT
    MAX(epoch)
  FROM
    grest.epoch_info_cache INTO _previous_epoch;
  UPDATE
    grest.epoch_info_cache
  SET
    i_out_sum = update_table.out_sum,
    i_fees = update_table.fees,
    i_tx_count = update_table.tx_count,
    i_blk_count = update_table.blk_count,
    i_last_block_time = update_table.end_time
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
      e.no = _previous_epoch) update_table
WHERE
  epoch = _previous_epoch;
  -- Then, insert the new epoch data
  INSERT INTO grest.epoch_info_cache
  SELECT
    e.no AS epoch,
    e.out_sum AS i_out_sum,
    e.fees AS i_fees,
    e.tx_count AS i_tx_count,
    e.blk_count AS i_blk_count,
    e.start_time AS i_first_block_time,
    e.end_time AS i_last_block_time,
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
    ENCODE(ep.entropy, 'hex') AS p_entropy,
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
    ep.coins_per_utxo_word AS p_coins_per_utxo_word
  FROM
    epoch e
    INNER JOIN epoch_param ep ON ep.epoch_no = e.no
    LEFT JOIN cost_model cm ON cm.id = ep.cost_model_id
    INNER JOIN block b ON b.id = ep.block_id
  WHERE
    e.no = (
      SELECT
        MAX(NO)
      FROM
        epoch);
  RETURN NULL;
END;
$new_epoch_insert$
LANGUAGE plpgsql;

CREATE TRIGGER new_epoch_insert_trigger
  AFTER INSERT ON public.epoch
  FOR EACH ROW
  EXECUTE PROCEDURE grest.new_epoch_insert ();

