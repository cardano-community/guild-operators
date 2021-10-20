DROP FUNCTION IF EXISTS koios.pool_relays ();

CREATE FUNCTION koios.pool_relays ()
  RETURNS TABLE (
    pool_id_bech32 character varying,
    relays jsonb[])
  LANGUAGE plpgsql
  AS $$
  # variable_conflict use_column
BEGIN
  RETURN QUERY SELECT DISTINCT ON (pool_id_bech32)
    pool_id_bech32,
    relays
  FROM
    koios.pool_info_cache
  WHERE
    pool_status != 'retired'
  ORDER BY
    pool_id_bech32,
    tx_id DESC;
END;
$$;

COMMENT ON FUNCTION koios.pool_relays IS 'A list of registered relays for all currently registered/retiring (not retired) pools';

