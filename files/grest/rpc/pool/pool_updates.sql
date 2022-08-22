CREATE FUNCTION grest.pool_updates (_pool_bech32 text DEFAULT NULL)
    RETURNS TABLE (
        tx_hash text,
        block_time integer,
        pool_id_bech32 character varying,
        pool_id_hex text,
        active_epoch_no bigint,
        vrf_key_hash text,
        margin double precision,
        fixed_cost text,
        pledge text,
        reward_addr character varying,
        owners character varying [],
        relays jsonb [],
        meta_url character varying,
        meta_hash text,
        meta_json jsonb,
        pool_status text,
        retiring_epoch word31type
    )
    LANGUAGE plpgsql
    AS $$
    #variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT
        tx_hash,
        block_time::integer,
        pool_id_bech32,
        pool_id_hex,
        active_epoch_no,
        vrf_key_hash,
        margin,
        fixed_cost::text,
        pledge::text,
        reward_addr,
        owners,
        relays,
        meta_url,
        meta_hash,
        pod.json,
        pool_status,
        retiring_epoch
    FROM
        grest.pool_info_cache pic
        LEFT JOIN public.pool_offline_data pod ON pod.id = pic.meta_id 
    WHERE
        _pool_bech32 IS NULL
        OR
        pool_id_bech32 = _pool_bech32
    ORDER BY
        tx_id DESC;
END;
$$;

COMMENT ON FUNCTION grest.pool_updates IS 'Return all pool_updates for all pools or only updates for specific pool if specified';
