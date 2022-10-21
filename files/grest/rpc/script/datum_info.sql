CREATE FUNCTION grest.datum_info (_datum_hashes text[])
  RETURNS TABLE (
    hash text,
    value jsonb,
    bytes text
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _datum_hashes_decoded bytea[];
BEGIN
  SELECT INTO _datum_hashes_decoded
    ARRAY_AGG(DECODE(d_hash, 'hex'))
  FROM UNNEST(_datum_hashes) AS d_hash;

  RETURN QUERY
    SELECT
      ENCODE(d.hash, 'hex'),
      d.value,
      ENCODE(d.bytes, 'hex')
    FROM 
      datum d
    WHERE
      d.hash = ANY(_datum_hashes_decoded);
END;
$$;

COMMENT ON FUNCTION grest.datum_info IS 'Get information about a given data from hashes.';
