CREATE FUNCTION grest.pool_blocks (_pool_bech32 text, _epoch_no word31type DEFAULT NULL)
    RETURNS TABLE (
        epoch_no word31type,
        epoch_slot word31type,
        abs_slot word31type,
        block_height word31type,
        block_hash text,
        block_time double precision
    )
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN query
    SELECT
        b.epoch_no,
        b.epoch_slot_no as epoch_slot,
        b.slot_no as abs_slot,
        b.block_no as block_height,
        encode(b.hash::bytea, 'hex'),
        EXTRACT(epoch from b.time)
    FROM
        public.block b
    INNER JOIN
        public.slot_leader AS sl ON b.slot_leader_id = sl.id
    WHERE
        sl.pool_hash_id = (SELECT pool_hash_id FROM grest.pool_info_cache WHERE pool_id_bech32 = _pool_bech32 ORDER BY tx_id DESC LIMIT 1)
        AND
        (
            _epoch_no IS NULL
            OR
            b.epoch_no = _epoch_no
        );
END;
$$;

COMMENT ON FUNCTION grest.pool_blocks IS 'Return information about blocks minted by a given pool in current epoch (or epoch nbr if provided)';
