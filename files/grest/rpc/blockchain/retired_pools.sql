DROP FUNCTION IF EXISTS grest.retired_pools ();

CREATE FUNCTION grest.retired_pools ()
    RETURNS TABLE (
        pool_id_bech32 varchar,
        retired_epoch uinteger)
    LANGUAGE plpgsql
    AS $$
DECLARE
BEGIN
    RETURN query
    SELECT
        ph.view,
        pr.retiring_epoch
    FROM
        public.pool_hash ph,
        public.pool_retire pr
    WHERE
        pr.hash_id = ph.id
        AND pr.retiring_epoch < (
            SELECT
                max(id)
            FROM
                epoch)
        AND NOT EXISTS (
            SELECT
                NULL
            FROM
                public.pool_update pu
            WHERE
                pu.hash_id = ph.id
                AND pu.registered_tx_id > pr.announced_tx_id)
    ORDER BY
        pr.retiring_epoch DESC;
END;
$$;

COMMENT ON FUNCTION grest.retired_pools IS 'List of pool IDs and epochs when they were most recently retired';

