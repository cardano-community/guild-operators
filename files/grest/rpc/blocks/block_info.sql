DROP FUNCTION IF EXISTS grest.block_info (_block_hash text);

CREATE FUNCTION grest.block_info (_block_hash text)
    RETURNS TABLE (
        HASH text,
        EPOCH uinteger,
        ABS_SLOT uinteger,
        EPOCH_SLOT uinteger,
        HEIGHT uinteger,
        BLOCK_TIME timestamp,
        TX_COUNT bigint,
        VRF_KEY varchar,
        OP_CERT_COUNTER word63type,
        POOL varchar,
        PARENT_HASH text,
        CHILD_HASH text)
    LANGUAGE PLPGSQL
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        _block_hash AS HASH,
        b.EPOCH_NO AS EPOCH,
        b.SLOT_NO AS ABS_SLOT,
        b.EPOCH_SLOT_NO AS EPOCH_SLOT,
        b.BLOCK_NO AS HEIGHT,
        b.TIME AS BLOCK_TIME,
        b.TX_COUNT,
        b.VRF_KEY,
        b.OP_CERT_COUNTER,
        ph.VIEW AS POOL,
        (
            SELECT
                ENCODE(tB.HASH::bytea, 'hex')
            FROM
                block tB
            WHERE
                id = b.id - 1) AS PARENT_HASH,
        (
            SELECT
                ENCODE(tB.HASH::bytea, 'hex')
            FROM
                block tB
            WHERE
                id = b.id + 1) AS CHILD_HASH
    FROM
        BLOCK B
    LEFT JOIN SLOT_LEADER SL ON SL.ID = B.SLOT_LEADER_ID
    LEFT JOIN POOL_HASH PH ON PH.ID = SL.POOL_HASH_ID
WHERE
    ENCODE(B.HASH::bytea, 'hex') = _block_hash;
END;
$$;

COMMENT ON FUNCTION grest.block_info IS 'Get detailed information about a specific block';

