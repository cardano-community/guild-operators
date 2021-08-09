CREATE OR REPLACE FUNCTION grest.pool_metadata (_pool_bech32 text DEFAULT NULL)
    RETURNS json STABLE
    LANGUAGE PLPGSQL
    AS $$
BEGIN
    IF _pool_bech32 IS NULL THEN
        RETURN (
            SELECT
                json_agg(js) json_final
            FROM ( SELECT DISTINCT ON (ph.id)
                    json_build_object('pool_id', ph.view, 'meta_url', pmr.url, 'meta_hash', encode(pmr.hash::bytea, 'hex'), 'metadata', to_json(pod.metadata)) js
                FROM
                    public.pool_metadata_ref AS pmr
                    INNER JOIN pool_hash AS ph ON ph.id = pmr.pool_id
                    INNER JOIN pool_offline_data AS pod ON ph.id = pod.pool_id
                ORDER BY
                    ph.id,
                    pmr.registered_tx_id DESC) t);
    ELSE
        RETURN (
            SELECT
                json_build_object('pool_id', ph.view, 'meta_url', pmr.url, 'meta_hash', encode(pmr.hash::bytea, 'hex'), 'metadata', to_json(pod.metadata)) js
            FROM
                public.pool_metadata_ref AS pmr
                INNER JOIN pool_hash AS ph ON ph.id = pmr.pool_id
                INNER JOIN pool_offline_data AS pod ON ph.id = pod.pool_id
            WHERE
                pmr.pool_id = (
                    SELECT
                        id
                    FROM
                        public.pool_hash
                    WHERE
                        VIEW = _pool_bech32)
                ORDER BY
                    pmr.registered_tx_id DESC
                LIMIT 1);
    END IF;
END;
$$;

COMMENT ON FUNCTION grest.pool_metadata IS 'Get pool metadata url, hash, and contents, all pools if pool_id empty';

