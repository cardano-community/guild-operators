DROP FUNCTION IF EXISTS koios.pool_list ();

CREATE FUNCTION koios.pool_list ()
  RETURNS TABLE (
    pool_id_bech32 character varying,
    ticker character varying)
  LANGUAGE plpgsql
  AS $$
  # variable_conflict use_column
BEGIN
  RETURN QUERY SELECT DISTINCT ON (pic.pool_id_bech32)
    pool_id_bech32,
    pod.ticker_name
  FROM
    koios.pool_info_cache AS pic
  LEFT JOIN public.pool_offline_data AS pod ON pod.pmr_id = pic.meta_id
WHERE
  pic.pool_status != 'retired'
ORDER BY
  pic.pool_id_bech32,
  pic.tx_id DESC;
END;
$$;

COMMENT ON FUNCTION koios.pool_list IS 'A list of all currently registered/retiring (not retired) pools';

