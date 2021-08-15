DROP TABLE IF EXISTS grest.epoch_info_cache;

DROP TABLE IF EXISTS temp_active_stake;

DROP TABLE IF EXISTS temp_last_block_time;

DROP TABLE IF EXISTS temp_epoch_start_end_time;

CREATE TABLE grest.epoch_info_cache (
    epoch uinteger PRIMARY KEY NOT NULL,
    i_out_sum word128type NOT NULL,
    i_fees lovelace NOT NULL,
    i_tx_count uinteger NOT NULL,
    i_blk_count uinteger NOT NULL,
    i_start_time timestamp without time zone UNIQUE,
    i_end_time timestamp without time zone UNIQUE,
    i_first_block_time timestamp without time zone UNIQUE,
    i_last_block_time timestamp without time zone UNIQUE,
    i_active_stake lovelace,
    p_min_fee_a uinteger NOT NULL,
    p_min_fee_b uinteger NOT NULL,
    p_max_block_size uinteger NOT NULL,
    p_max_tx_size uinteger NOT NULL,
    p_max_bh_size uinteger NOT NULL,
    p_key_deposit lovelace NOT NULL,
    p_pool_deposit lovelace NOT NULL,
    p_max_epoch uinteger NOT NULL,
    p_optimal_pool_count uinteger NOT NULL,
    p_influence double precision NOT NULL,
    p_monetary_expand_rate double precision NOT NULL,
    p_treasury_growth_rate double precision NOT NULL,
    p_decentralisation double precision NOT NULL,
    p_entropy text,
    p_protocol_major uinteger NOT NULL,
    p_protocol_minor uinteger NOT NULL,
    p_min_utxo_value lovelace NOT NULL,
    p_min_pool_cost lovelace NOT NULL,
    p_nonce text,
    p_block_id bigint NOT NULL,
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

CREATE TEMP TABLE temp_active_stake AS
SELECT
    epoch_no,
    SUM(es.amount) AS i_active_stake
FROM
    epoch_stake es
GROUP BY
    es.epoch_no;

CREATE TEMP TABLE temp_last_block_time AS SELECT DISTINCT ON (epoch_no)
    epoch_no,
    time
FROM
    block
ORDER BY
    epoch_no,
    time DESC;

CREATE TEMP TABLE temp_epoch_start_end_time (
    epoch serial PRIMARY KEY,
    start_time timestamp without time zone NOT NULL,
    end_time timestamp without time zone NOT NULL
);

INSERT INTO temp_epoch_start_end_time
    VALUES (0, '2017-09-23 21:44:51'::timestamp WITHOUT time zone, '2017-09-28 21:44:50'::timestamp WITHOUT time zone);

DO $$
DECLARE
    i integer DEFAULT 1;
    _current_epoch integer DEFAULT NULL;
BEGIN
    SELECT
        max(NO)
    FROM
        epoch INTO _current_epoch;
    LOOP
        exit
        WHEN i > _current_epoch;
        INSERT INTO temp_epoch_start_end_time (start_time, end_time)
        SELECT
            max(start_time) + INTERVAL '5 DAY',
            max(end_time) + INTERVAL '5 DAY'
        FROM
            temp_epoch_start_end_time;
        i = i + 1;
    END LOOP;
END;
$$;

INSERT INTO grest.epoch_info_cache
SELECT
    e.no AS epoch,
    e.out_sum AS i_out_sum,
    e.fees AS i_fees,
    e.tx_count AS i_tx_count,
    e.blk_count AS i_blk_count,
    teset.start_time AS i_start_time,
    teset.end_time AS i_end_time,
    b.time AS i_first_block_time,
    tlbt.time AS i_last_block_time,
    tas.i_active_stake AS i_active_stake,
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
    encode(ep.entropy, 'hex') AS p_entropy,
    ep.protocol_major AS p_protocol_major,
    ep.protocol_minor AS p_protocol_minor,
    ep.min_utxo_value AS p_min_utxo_value,
    ep.min_pool_cost AS p_min_pool_cost,
    encode(ep.nonce, 'hex') AS p_nonce,
    ep.block_id AS p_block_id,
    ep.cost_models AS p_cost_models,
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
    INNER JOIN block b ON b.id = ep.block_id
    INNER JOIN temp_active_stake tas ON tas.epoch_no = e.no
    INNER JOIN temp_last_block_time tlbt ON tlbt.epoch_no = e.no
    INNER JOIN temp_epoch_start_end_time teset ON teset.epoch = e.no;

