CREATE FUNCTION grest.pool_metadata ()
    RETURNS TABLE (
        pool_id_bech32 character varying,
        meta_url character varying,
        meta_hash text,
        meta_json jsonb 
    )
    LANGUAGE plpgsql
    AS $$
    #variable_conflict use_column
BEGIN
    RETURN QUERY
    SELECT
        DISTINCT ON (pic.pool_id_bech32) pool_id_bech32,
        pic.meta_url,
        pic.meta_hash,
        pod.json
    FROM
        grest.pool_info_cache AS pic
    LEFT JOIN
        public.pool_offline_data AS pod ON pod.pmr_id = pic.meta_id
    WHERE
        pic.pool_status != 'retired'
    ORDER BY
        pic.pool_id_bech32, pic.tx_id DESC;
END;
$$;

COMMENT ON FUNCTION grest.pool_metadata IS 'Metadata(on & off-chain) for all currently registered/retiring (not retired) pools';
