DROP FUNCTION IF EXISTS grest.pool_list ();

CREATE FUNCTION grest.pool_list ()
  RETURNS TABLE (
    pool_id_bech32 character varying,
    ticker character varying)
  LANGUAGE plpgsql
  AS $$
  # variable_conflict use_column
BEGIN

  RETURN QUERY (
    WITH
      -- Get last pool update for each pool
      _pool_updates AS (
        SELECT
          DISTINCT ON (pic.pool_id_bech32) pool_id_bech32,
          pod.ticker_name,
          pic.pool_status
        FROM
          grest.pool_info_cache AS pic
          LEFT JOIN public.pool_offline_data AS pod ON pod.pmr_id = pic.meta_id
        ORDER BY
          pool_id_bech32,
          tx_id DESC
      )

    SELECT
      pool_id_bech32,
      ticker_name
    FROM
      _pool_updates
    WHERE
      pool_status != 'retired'

  );

END;
$$;