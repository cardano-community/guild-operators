DROP FUNCTION IF EXISTS grest.pool_list ();

CREATE FUNCTION grest.pool_list ()
    RETURNS TABLE (
        pool_id_bech32 character varying,
        pool_id_hex text,
        ticker character varying
    )
    LANGUAGE plpgsql
    AS $$
    #variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT
        DISTINCT ON (pic.pool_id_bech32) pool_id_bech32,
        pic.pool_id_hex,
        pod.ticker_name
    FROM
        grest.pool_info_cache AS pic
    LEFT JOIN
        public.pool_offline_data AS pod ON pod.pmr_id = pic.meta_id
    ORDER BY
        pool_id_bech32, tx_id DESC;
END;
$$;

COMMENT ON FUNCTION grest.pool_list IS 'A list of all currently registered/retiring (not retired) pools';
