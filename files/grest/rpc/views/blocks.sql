CREATE VIEW grest.blocks AS
  SELECT
    ENCODE(B.HASH::bytea, 'hex') AS HASH,
    b.EPOCH_NO AS EPOCH,
    b.SLOT_NO AS ABS_SLOT,
    b.EPOCH_SLOT_NO AS EPOCH_SLOT,
    b.BLOCK_NO AS BLOCK_HEIGHT,
    b.SIZE AS BLOCK_SIZE,
    b.TIME AS BLOCK_TIME,
    b.TX_COUNT,
    b.VRF_KEY,
    ph.VIEW AS POOL,
    b.OP_CERT_COUNTER
  FROM
    BLOCK B
    LEFT JOIN SLOT_LEADER SL ON SL.ID = B.SLOT_LEADER_ID
    LEFT JOIN POOL_HASH PH ON PH.ID = SL.POOL_HASH_ID
  WHERE
    B.BLOCK_NO IS NOT NULL
  ORDER BY
    B.ID DESC;

COMMENT ON VIEW grest.blocks IS 'Get detailed information about all blocks (paginated - latest first)';
