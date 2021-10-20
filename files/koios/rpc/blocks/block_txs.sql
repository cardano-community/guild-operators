DROP FUNCTION IF EXISTS koios.block_txs (_block_hash text);

CREATE FUNCTION koios.block_txs (_block_hash text)
  RETURNS TABLE (
    TX_HASH text)
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _BLOCK_ID integer DEFAULT NULL;
BEGIN
  SELECT
    B.ID
  FROM
    BLOCK B
  WHERE
    DECODE(_block_hash, 'hex') = B.HASH INTO _BLOCK_ID;
  RETURN QUERY
  SELECT
    ENCODE(TX.HASH::bytea, 'hex') AS TX_HASH
  FROM
    BLOCK B
    INNER JOIN TX ON TX.BLOCK_ID = B.ID
  WHERE
    B.ID = _BLOCK_ID;
END;
$$;

COMMENT ON FUNCTION koios.block_txs IS 'Get all transactions contained in a block';

