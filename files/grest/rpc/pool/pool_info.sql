DROP FUNCTION IF EXISTS grest.pool_info (text);

CREATE FUNCTION grest.pool_info (_pool_bech32 text)
    RETURNS TABLE (
        pool_id_bech32 character varying,
        pool_id_hex text,
        active_epoch_no bigint,
        vrf_key_hash text,
        margin double precision,
        fixed_cost lovelace,
        pledge lovelace,
        reward_addr character varying,
        owners character varying [],
        relays jsonb [],
        meta_url character varying,
        meta_hash text,
        retiring_epoch uinteger
    )
    LANGUAGE plpgsql
    AS $$
    #variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT
        pool_id_bech32,
        pool_id_hex,
        active_epoch_no,
        vrf_key_hash,
        margin,
        fixed_cost,
        pledge,
        reward_addr,
        owners,
        relays,
        meta_url,
        meta_hash,
        retiring_epoch
    FROM
        grest.pool_info_cache
    WHERE
        pool_id_bech32 = _pool_bech32
    ORDER BY
        tx_id DESC
    LIMIT 1;
END;
$$;

COMMENT ON FUNCTION grest.pool_info IS 'The current pool details for specified pool';
