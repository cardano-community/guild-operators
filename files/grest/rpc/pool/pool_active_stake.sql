DROP FUNCTION IF EXISTS grest.pool_active_stake(text, numeric);

CREATE FUNCTION grest.pool_active_stake(_pool_bech32 text default null, _epoch_no numeric default null)
RETURNS JSON STABLE LANGUAGE PLPGSQL AS $$
BEGIN
    IF _epoch_no IS NULL THEN
    SELECT epoch.no INTO _epoch_no FROM public.epoch ORDER BY epoch.no DESC LIMIT 1;
    END IF;
    IF _pool_bech32 IS NULL THEN
    RETURN ( SELECT json_build_object(
        'active_stake_sum', SUM (es.amount)
        )
        FROM public.epoch_stake AS es
        WHERE es.epoch_no = _epoch_no
    );
    ELSE
    RETURN ( SELECT json_build_object(
        'active_stake_sum', SUM (es.amount)
        )
        FROM public.epoch_stake AS es
        WHERE es.epoch_no = _epoch_no
        AND es.pool_id =  (SELECT id from public.pool_hash where view=_pool_bech32)
    );
    END IF;
END; $$;
COMMENT ON FUNCTION grest.pool_active_stake IS 'Get the pools active stake in lovelace for specified epoch, current epoch if empty';
