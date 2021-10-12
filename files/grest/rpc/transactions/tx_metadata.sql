DROP FUNCTION IF EXISTS grest.tx_metadata (text[]);

CREATE FUNCTION grest.tx_metadata (_tx_hashes text[])
  RETURNS TABLE (
    tx_hash text,
    metadata json)
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  RETURN QUERY
  SELECT
    T1.tx_hash,
    METADATA_T.metadata
  FROM (
    SELECT
      tx.id,
      ENCODE(tx.hash, 'hex') as tx_hash
    FROM
      public.tx
    WHERE
      tx.hash::bytea = ANY (
        SELECT
          DECODE(hashes, 'hex')
        FROM
          UNNEST(_tx_hashes) AS hashes)) T1
  LEFT JOIN LATERAL (
    SELECT
      JSON_OBJECT_AGG(tx_metadata.key, tx_metadata.json) as metadata
    FROM
      tx_metadata
    WHERE
      tx_id = T1.id) METADATA_T ON TRUE;
END;
$$;

COMMENT ON FUNCTION grest.tx_metadata IS 'Get transaction metadata.';

