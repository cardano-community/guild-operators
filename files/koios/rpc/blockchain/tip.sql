DROP FUNCTION IF EXISTS koios.tip ();

CREATE FUNCTION koios.tip ()
  RETURNS TABLE (
    hash text,
    epoch uinteger,
    abs_slot uinteger,
    epoch_slot uinteger,
    block_no uinteger,
    block_time timestamp)
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
    b.TIME
  FROM
    BLOCK B
  ORDER BY
    B.ID DESC
  LIMIT 1;
END;
$$;

COMMENT ON FUNCTION koios.tip IS 'Get the tip info about the latest block seen by chain';

