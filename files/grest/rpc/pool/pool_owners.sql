CREATE OR REPLACE FUNCTION grest.pool_owners(_pool_bech32 text)
RETURNS JSON STABLE LANGUAGE PLPGSQL AS $$
BEGIN
    RETURN ( SELECT json_agg(js) json_final FROM ( SELECT json_build_object(
        'owner', sa.view
    ) js
    FROM public.pool_owner AS po
    INNER JOIN public.stake_address AS sa ON sa.id = po.addr_id
    WHERE po.registered_tx_id = (
        SELECT MAX(pool_owner.registered_tx_id)
        FROM public.pool_owner
        INNER JOIN public.pool_hash ON pool_owner.pool_hash_id = pool_hash.id
        AND pool_hash.view=_pool_bech32
        ) GROUP BY sa.view
    ) t );
END; $$;
COMMENT ON FUNCTION grest.pool_owners IS 'Get registered pool owners';
