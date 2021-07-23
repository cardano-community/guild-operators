CREATE OR REPLACE FUNCTION grest.pool_delegator_count(_pool_bech32 text)
RETURNS JSON STABLE LANGUAGE PLPGSQL AS $$
BEGIN
    RETURN ( SELECT json_build_object(
        'delegator_count', COUNT(*)
    )
    FROM public.delegation d
    WHERE pool_hash_id = (SELECT id from public.pool_hash where view=_pool_bech32)
        AND NOT EXISTS
        (SELECT TRUE FROM public.delegation d2 WHERE d2.addr_id=d.addr_id AND d2.id > d.id)
        AND NOT EXISTS
        (SELECT TRUE FROM public.stake_deregistration sd WHERE sd.addr_id=d.addr_id AND sd.tx_id > d.tx_id)
    );
END; $$;
COMMENT ON FUNCTION grest.pool_delegator_count IS 'Get live delegator count';
