DROP FUNCTION IF EXISTS grest.blocks ();

CREATE FUNCTION grest.blocks ()
  RETURNS TABLE (
    hash text,
    epoch uinteger,
    abs_slot uinteger,
    epoch_slot uinteger,
    block_no uinteger,
    block_time timestamp,
    tx_count bigint,
    vrf_key varchar,
    op_cert_counter word63type,
    pool varchar,
    parent_hash text)
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  RETURN QUERY
  SELECT
    ENCODE(B.HASH::bytea, 'hex') AS BLOCK_HASH,
    b.EPOCH_NO AS EPOCH,
    b.SLOT_NO AS ABS_SLOT,
    b.EPOCH_SLOT_NO AS EPOCH_SLOT,
    b.BLOCK_NO,
    b.TIME,
    b.TX_COUNT,
    b.VRF_KEY,
    b.OP_CERT_COUNTER,
    ph.VIEW,
    (
      SELECT
        ENCODE(tB.HASH::bytea, 'hex')
      FROM
        block tB
      WHERE
        id = b.id - 1) AS parent_hash
  FROM
    BLOCK B
  LEFT JOIN SLOT_LEADER SL ON SL.ID = B.SLOT_LEADER_ID
  LEFT JOIN POOL_HASH PH ON PH.ID = SL.POOL_HASH_ID
ORDER BY
  B.ID DESC;
END;
$$;

COMMENT ON FUNCTION grest.blocks IS 'Get detailed information about all blocks (paginated - latest first)';
