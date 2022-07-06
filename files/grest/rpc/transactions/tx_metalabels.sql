DROP FUNCTION IF EXISTS grest.tx_metalabels;

CREATE FUNCTION grest.tx_metalabels()
  RETURNS TABLE (key word64type)
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  RETURN QUERY
  WITH RECURSIVE t AS (
    (SELECT tm.key FROM public.tx_metadata tm ORDER BY key LIMIT 1) 
    UNION ALL
    SELECT (SELECT tm.key FROM tx_metadata tm WHERE tm.key > t.key ORDER BY key LIMIT 1)
    FROM t
      WHERE t.key IS NOT NULL
  )
  SELECT t.key FROM t WHERE t.key IS NOT NULL;
END;
$$;

COMMENT ON FUNCTION grest.tx_metalabels IS 'Get a list of all transaction metalabels';

