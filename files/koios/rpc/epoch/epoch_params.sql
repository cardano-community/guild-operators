DROP FUNCTION IF EXISTS koios.epoch_params (numeric);

CREATE FUNCTION koios.epoch_params (_epoch_no numeric DEFAULT NULL)
  RETURNS TABLE (
    min_fee_a uinteger,
    min_fee_b uinteger,
    max_block_size uinteger,
    max_tx_size uinteger,
    max_bh_size uinteger,
    key_deposit lovelace,
    pool_deposit lovelace,
    max_epoch uinteger,
    optimal_pool_count uinteger,
    influence double precision,
    monetary_expand_rate double precision,
    treasury_growth_rate double precision,
    decentralisation double precision,
    entropy text,
    protocol_major uinteger,
    protocol_minor uinteger,
    min_utxo_value lovelace,
    min_pool_cost lovelace,
    nonce text,
    block_hash text,
    cost_models character varying,
    price_mem double precision,
    price_step double precision,
    max_tx_ex_mem word64type,
    max_tx_ex_steps word64type,
    max_block_ex_mem word64type,
    max_block_ex_steps word64type,
    max_val_size word64type,
    collateral_percent uinteger,
    max_collateral_inputs uinteger,
    coins_per_utxo_word lovelace)
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  IF _epoch_no IS NULL THEN
    RETURN QUERY
    SELECT
      ei.p_min_fee_a AS min_fee_a,
      ei.p_min_fee_b AS min_fee_b,
      ei.p_max_block_size AS max_block_size,
      ei.p_max_tx_size AS max_tx_size,
      ei.p_max_bh_size AS max_bh_size,
      ei.p_key_deposit AS key_deposit,
      ei.p_pool_deposit AS pool_deposit,
      ei.p_max_epoch AS max_epoch,
      ei.p_optimal_pool_count AS optimal_pool_count,
      ei.p_influence AS influence,
      ei.p_monetary_expand_rate AS monetary_expand_rate,
      ei.p_treasury_growth_rate AS treasury_growth_rate,
      ei.p_decentralisation AS decentralisation,
      ei.p_entropy AS entropy,
      ei.p_protocol_major AS protocol_major,
      ei.p_protocol_minor AS protocol_minor,
      ei.p_min_utxo_value AS min_utxo_value,
      ei.p_min_pool_cost AS min_pool_cost,
      ei.p_nonce AS nonce,
      ei.p_block_hash AS block_hash,
      ei.p_cost_models AS cost_models,
      ei.p_price_mem AS price_mem,
      ei.p_price_step AS price_step,
      ei.p_max_tx_ex_mem AS max_tx_ex_mem,
      ei.p_max_tx_ex_steps AS max_tx_ex_steps,
      ei.p_max_block_ex_mem AS max_block_ex_mem,
      ei.p_max_block_ex_steps AS max_block_ex_steps,
      ei.p_max_val_size AS max_val_size,
      ei.p_collateral_percent AS collateral_percent,
      ei.p_max_collateral_inputs AS max_collateral_inputs,
      ei.p_coins_per_utxo_word AS coins_per_utxo_word
    FROM
      koios.epoch_info_cache ei
    ORDER BY
      ei.epoch DESC;
  ELSE
    RETURN QUERY
    SELECT
      ei.p_min_fee_a AS min_fee_a,
      ei.p_min_fee_b AS min_fee_b,
      ei.p_max_block_size AS max_block_size,
      ei.p_max_tx_size AS max_tx_size,
      ei.p_max_bh_size AS max_bh_size,
      ei.p_key_deposit AS key_deposit,
      ei.p_pool_deposit AS pool_deposit,
      ei.p_max_epoch AS max_epoch,
      ei.p_optimal_pool_count AS optimal_pool_count,
      ei.p_influence AS influence,
      ei.p_monetary_expand_rate AS monetary_expand_rate,
      ei.p_treasury_growth_rate AS treasury_growth_rate,
      ei.p_decentralisation AS decentralisation,
      ei.p_entropy AS entropy,
      ei.p_protocol_major AS protocol_major,
      ei.p_protocol_minor AS protocol_minor,
      ei.p_min_utxo_value AS min_utxo_value,
      ei.p_min_pool_cost AS min_pool_cost,
      ei.p_nonce AS nonce,
      ei.p_block_hash AS block_hash,
      ei.p_cost_models AS cost_models,
      ei.p_price_mem AS price_mem,
      ei.p_price_step AS price_step,
      ei.p_max_tx_ex_mem AS max_tx_ex_mem,
      ei.p_max_tx_ex_steps AS max_tx_ex_steps,
      ei.p_max_block_ex_mem AS max_block_ex_mem,
      ei.p_max_block_ex_steps AS max_block_ex_steps,
      ei.p_max_val_size AS max_val_size,
      ei.p_collateral_percent AS collateral_percent,
      ei.p_max_collateral_inputs AS max_collateral_inputs,
      ei.p_coins_per_utxo_word AS coins_per_utxo_word
    FROM
      koios.epoch_info_cache ei
    WHERE
      ei.epoch = _epoch_no;
  END IF;
END;
$$;

COMMENT ON FUNCTION koios.epoch_params IS 'Get the epoch parameters, all epochs if no epoch specified';

