CREATE OR REPLACE FUNCTION grest.pool_metadata (_pool_bech32 text)
    RETURNS json STABLE
    LANGUAGE PLPGSQL
    AS $$
BEGIN
    RETURN (
        SELECT
            json_build_object('meta_url', pmd.url, 'meta_hash', encode(pmd.hash::bytea, 'hex'))
        FROM
            public.pool_metadata_ref AS pmd
        WHERE
            pmd.pool_id = (
                SELECT
                    id
                FROM
                    public.pool_hash
                WHERE
                    VIEW = _pool_bech32)
            ORDER BY
                pmd.registered_tx_id DESC
            LIMIT 1);
END;
$$;

COMMENT ON FUNCTION grest.pool_metadata IS 'Get pool metadata url and hash';

