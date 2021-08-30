DROP FUNCTION IF EXISTS grest.pools_retired ();

CREATE FUNCTION grest.pools_retired ()
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
DECLARE
    _current_epoch_no uinteger;
BEGIN
    SELECT COALESCE(MAX(no), 0) INTO _current_epoch_no FROM public.epoch;
    RETURN QUERY
    SELECT
        DISTINCT ON (pool_id_bech32) pool_id_bech32,
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
        retiring_epoch IS NOT NULL 
        AND
        retiring_epoch <= _current_epoch_no
    ORDER BY
        pool_id_bech32, tx_id DESC;
END;
$$;

COMMENT ON FUNCTION grest.pools_retired IS 'List of retired stake pools';
