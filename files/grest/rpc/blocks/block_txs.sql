CREATE FUNCTION grest.block_txs (_block_hashes text[])
  RETURNS TABLE (
    block_hash text,
    tx_hashes text[]
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _block_hashes_bytea bytea[];
  _BLOCK_IDS integer[];
BEGIN
  SELECT INTO _block_hashes_bytea
    ARRAY_AGG(block_hashes_bytea)
  FROM (
    SELECT
      DECODE(hex, 'hex') AS block_hashes_bytea
    FROM
      UNNEST(_block_hashes) AS hex
  ) AS tmp;

  SELECT INTO _BLOCK_IDS
    ARRAY_AGG(B.ID)
  FROM
    public.BLOCK B
  WHERE
    B.HASH = ANY(_block_hashes_bytea);

  RETURN QUERY
    SELECT
      encode(b.hash, 'hex'),
      ARRAY_AGG(ENCODE(TX.HASH::bytea, 'hex'))
    FROM
      public.BLOCK B
      INNER JOIN public.TX ON TX.BLOCK_ID = B.ID
    WHERE
      B.ID = ANY(_BLOCK_IDS)
    GROUP BY
      B.hash;
END;
$$;

COMMENT ON FUNCTION grest.block_txs IS 'Get all transactions contained in given blocks';

