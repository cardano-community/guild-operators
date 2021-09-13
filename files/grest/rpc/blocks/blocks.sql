DROP FUNCTION IF EXISTS grest.blocks ();

CREATE FUNCTION grest.blocks ()
  RETURNS TABLE (
    HASH text,
    EPOCH uinteger,
    ABS_SLOT uinteger,
    EPOCH_SLOT uinteger,
    HEIGHT uinteger,
    TIME timestamp,
    TX_COUNT bigint,
    VRF_KEY varchar,
    OP_CERT_COUNTER word63type,
    POOL varchar,
    PARENT_HASH text)
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  RETURN QUERY
  SELECT
    ENCODE(B.HASH::bytea, 'hex') AS HASH,
    b.EPOCH_NO AS EPOCH,
    b.SLOT_NO AS ABS_SLOT,
    b.EPOCH_SLOT_NO AS EPOCH_SLOT,
    b.BLOCK_NO AS HEIGHT,
    b.TIME,
    b.TX_COUNT,
    b.VRF_KEY,
    b.OP_CERT_COUNTER,
    ph.VIEW AS POOL,
    LAG(ENCODE(b.HASH::bytea, 'hex')) OVER (ORDER BY b.ID) AS PARENT_HASH
  FROM
    BLOCK B
  LEFT JOIN SLOT_LEADER SL ON SL.ID = B.SLOT_LEADER_ID
  LEFT JOIN POOL_HASH PH ON PH.ID = SL.POOL_HASH_ID
ORDER BY
  B.ID DESC;
END;
$$;

COMMENT ON FUNCTION grest.blocks IS 'Get detailed information about all blocks (paginated - latest first)';

