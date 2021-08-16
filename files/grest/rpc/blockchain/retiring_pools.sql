DROP FUNCTION IF EXISTS grest.retiring_pools ();

CREATE FUNCTION grest.retiring_pools ()
    RETURNS TABLE (
        pool_id_bech32 varchar,
        retiring_epoch uinteger)
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
        AND pr.retiring_epoch >= (
            SELECT
                max(id)
            FROM
                public.epoch)
        AND pr.announced_tx_id > (
            SELECT
                max(registered_tx_id)
            FROM
                public.pool_update
            WHERE
                hash_id = ph.id);
END;
$$;

COMMENT ON FUNCTION grest.retiring_pools IS 'List of pool IDs and target retirement epochs of pools currently scheduled for retirement';

