CREATE OR REPLACE FUNCTION grest.pool_metadata(_pool_bech32 text)
RETURNS JSON STABLE LANGUAGE PLPGSQL AS $$
BEGIN
    RETURN ( SELECT json_build_object(
        'meta_url', pmd.url,
        'meta_hash', encode(pmd.hash::bytea, 'hex')
    )
    FROM public.pool_meta_data AS pmd
    WHERE pmd.id = (SELECT id from public.pool_hash where view=_pool_bech32)
    );
END; $$;
