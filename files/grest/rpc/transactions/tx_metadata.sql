CREATE FUNCTION grest.tx_metadata (_tx_hashes text[])
  RETURNS TABLE (
    tx_hash text,
    metadata jsonb)
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
          UNNEST(_tx_hashes) AS hashes
      )
    ) T1
  LEFT JOIN LATERAL (
    SELECT
      tx_id,
      JSONB_AGG(data) AS metadata
    FROM
      (
        SELECT
          TM.tx_id,
          JSONB_BUILD_OBJECT(
            'key', TM.key::text,
            'json', TM.json
          ) AS data
        FROM 
          tx_metadata TM
        WHERE
          TM.tx_id = T1.id
      ) as tmp
    GROUP BY
      tx_id
  ) METADATA_T ON METADATA_T.tx_id = T1.id;
END;
$$;

COMMENT ON FUNCTION grest.tx_metadata IS 'Get transaction metadata.';

