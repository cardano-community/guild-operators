CREATE FUNCTION grest.datum_info (_datum_hash text)
  RETURNS TABLE (
    hash text,
    value jsonb,
    bytes text
  )
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  RETURN QUERY
    SELECT
      _datum_hash,
      d.value,
      d.bytes::text
    FROM 
      datum d
    WHERE
      d.hash = DECODE(_datum_hash, 'hex');
END;
$$;

COMMENT ON FUNCTION grest.datum_info IS 'Get the information about a given datum.';
