CREATE OR REPLACE FUNCTION grest.pool_retire(_pool_bech32 text)
RETURNS JSON STABLE LANGUAGE PLPGSQL AS $$
DECLARE
    _pool_id bigint;
    _last_update bigint;
BEGIN
    SELECT COALESCE(id, 0) FROM public.pool_hash WHERE view=_pool_bech32 LIMIT 1 INTO _pool_id;
    SELECT COALESCE(registered_tx_id, 0) FROM public.pool_update WHERE hash_id=_pool_id ORDER BY registered_tx_id DESC LIMIT 1 INTO _last_update;
    RETURN ( SELECT json_build_object(
        'retiring_epoch', pr.retiring_epoch
    )
    FROM public.pool_retire AS pr
    WHERE pr.hash_id = _pool_id
        AND pr.announced_tx_id > _last_update
    ORDER BY pr.id DESC
    LIMIT 1
    );
END; $$;