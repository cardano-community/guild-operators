DROP FUNCTION IF EXISTS grest.registered_pools ();

CREATE FUNCTION grest.registered_pools ()
    RETURNS TABLE (
        pool_id_bech32 varchar,
        pool_id_hex text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN query
    SELECT
        ph.view,
        encode(ph.hash_raw::bytea, 'hex')
    FROM
        public.pool_hash ph
    WHERE
        NOT EXISTS (
            SELECT
                NULL
            FROM
                public.pool_retire pr
            WHERE
                pr.retiring_epoch < (
                    SELECT
                        max(id)
                    FROM
                        public.epoch)
                    AND pr.hash_id = ph.id
                    AND pr.announced_tx_id > (
                        SELECT
                            max(registered_tx_id)
                        FROM
                            public.pool_update
                        WHERE
                            hash_id = ph.id));
END;
$$;

COMMENT ON FUNCTION grest.registered_pools IS 'List of pool IDs of registered (not retired) stake pools';
