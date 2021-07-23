CREATE OR REPLACE FUNCTION grest.pool_updates(_pool_bech32 text, _current_epoch_no numeric default 0, _state text default '' )
RETURNS JSON STABLE LANGUAGE PLPGSQL AS $$
BEGIN
    RETURN ( SELECT json_agg(js) json_final FROM ( SELECT json_build_object(
        'vrf_key_hash', encode(pu.vrf_key_hash::bytea, 'hex'),
        'reward_address', sa.view,
        'owner_address', tout.address,
        'active_epoch_no', pu.active_epoch_no,
        'pledge', pu.pledge,
        'margin', pu.margin,
        'fixed_cost', pu.fixed_cost,
        'meta_url', pmd.url,
        'meta_hash', encode(pmd.hash::bytea, 'hex')
    ) js
    FROM public.pool_update AS pu
    INNER JOIN public.pool_hash AS ph ON pu.hash_id = ph.id
    LEFT JOIN public.pool_retire AS pr ON pu.hash_id = pr.hash_id
    LEFT JOIN public.pool_metadata_ref as pmd ON pmd.id = pu.meta_id
    LEFT JOIN public.tx_out as tout ON tout.id = pu.registered_tx_id
    LEFT JOIN public.stake_address as sa ON sa.hash_raw = pu.reward_addr
    WHERE ph.view = _pool_bech32
    AND CASE
        WHEN _state = 'active' AND pu.active_epoch_no <= _current_epoch_no THEN 'True'
        WHEN _state = 'active' THEN 'False'
        ELSE 'True'
    END = 'True'
    ORDER BY pu.id DESC
    LIMIT CASE
        WHEN _state = 'active' OR _state = 'latest' THEN 1
    END
    ) t );
END; $$;
COMMENT ON FUNCTION grest.pool_updates IS 'Grab latest, active or all pool updates for specified pool';
