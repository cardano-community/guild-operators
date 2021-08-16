DROP FUNCTION IF EXISTS grest.pool_blocks_in_epoch (_pool_bech32 text, _epoch_no uinteger);

CREATE FUNCTION grest.pool_blocks_in_epoch (_pool_bech32 text, _epoch_no uinteger DEFAULT NULL)
    RETURNS TABLE (
        block_hash text,
        block_no uinteger,
        epoch_no uinteger,
        epoch_slot_no uinteger,
        slot_no uinteger,
        block_time timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN query
    SELECT
        encode(b.hash::bytea, 'hex'),
        b.block_no,
        b.epoch_no,
        b.epoch_slot_no,
        b.slot_no,
        b.time
    FROM
        public.block b,
        public.pool_hash ph,
        public.slot_leader sl
    WHERE
        ph."view" = _pool_bech32
        AND ph.id = sl.pool_hash_id
        AND sl.id = b.slot_leader_id
        AND b.epoch_no = coalesce(_epoch_no, (
                SELECT
                    max(b2.epoch_no)
                FROM public.block b2))
    ORDER BY
        b.id DESC;
END;
$$;

COMMENT ON FUNCTION grest.pool_blocks_in_epoch IS 'Return information about blocks minted by a given pool in specified epoch (if _epoch_no was 
not provided, information for current epoch is returned)';

