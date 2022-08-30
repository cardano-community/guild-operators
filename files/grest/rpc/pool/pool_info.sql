CREATE FUNCTION grest.pool_info (_pool_bech32_ids text[])
  RETURNS TABLE (
    pool_id_bech32 character varying,
    pool_id_hex text,
    active_epoch_no bigint,
    vrf_key_hash text,
    margin double precision,
    fixed_cost text,
    pledge text,
    reward_addr character varying,
    owners character varying [],
    relays jsonb [],
    meta_url character varying,
    meta_hash text,
    meta_json jsonb,
    pool_status text,
    retiring_epoch word31type,
    op_cert text,
    op_cert_counter word63type,
    active_stake text,
    sigma numeric,
    block_count numeric,
    live_pledge text,
    live_stake text,
    live_delegators bigint,
    live_saturation numeric
  )
  LANGUAGE plpgsql
  AS $$
  #variable_conflict use_column
DECLARE
  _epoch_no bigint;
  _saturation_limit bigint;
BEGIN
  SELECT MAX(epoch.no) INTO _epoch_no FROM public.epoch;

  SELECT FLOOR(supply::bigint / (
      SELECT p_optimal_pool_count 
      FROM grest.epoch_info_cache
      WHERE epoch_no = _epoch_no
    ))::bigint INTO _saturation_limit FROM grest.totals(_epoch_no);

  RETURN QUERY
    WITH
      _all_pool_info AS (
        SELECT DISTINCT ON (pic.pool_id_bech32)
          *
        FROM
          grest.pool_info_cache AS pic
        WHERE
          pic.pool_id_bech32 = ANY(SELECT UNNEST(_pool_bech32_ids))
        ORDER BY
          pic.pool_id_bech32, pic.tx_id DESC
      )

    SELECT
      api.pool_id_bech32,
      api.pool_id_hex,
      api.active_epoch_no,
      api.vrf_key_hash,
      api.margin,
      api.fixed_cost::text,
      api.pledge::text,
      api.reward_addr,
      api.owners,
      api.relays,
      api.meta_url,
      api.meta_hash,
      offline_data.json,
      api.pool_status,
      api.retiring_epoch,
      ENCODE(block_data.op_cert::bytea, 'hex'),
      block_data.op_cert_counter,
      active_stake.as_sum::text,
      active_stake.as_sum / epoch_stake.es_sum,
      block_data.cnt,
      live.pledge::text,
      live.stake::text,
      live.delegators,
      ROUND((live.stake / _saturation_limit) * 100, 2)
    FROM
      _all_pool_info AS api
    LEFT JOIN LATERAL (
      (
        SELECT
          pod.json
        FROM
          public.pool_offline_data AS pod
        WHERE
          pod.pool_id = api.pool_hash_id
          AND
          pod.pmr_id = api.meta_id
      )
      UNION ALL
      (
        SELECT
          pod.json
        FROM
          public.pool_offline_data AS pod
        WHERE
          pod.pool_id = api.pool_hash_id
          AND
          pod.json IS NOT NULL
        ORDER BY
          pod.pmr_id DESC
      )
      LIMIT 1
    ) offline_data ON TRUE
    LEFT JOIN LATERAL (
      SELECT
        SUM(COUNT(b.id)) OVER () AS cnt,
        b.op_cert,
        b.op_cert_counter
      FROM 
        public.block AS b
      INNER JOIN 
        public.slot_leader AS sl ON b.slot_leader_id = sl.id
      WHERE
        sl.pool_hash_id = api.pool_hash_id
      GROUP BY
        b.op_cert,
        b.op_cert_counter
      ORDER BY
        b.op_cert_counter DESC
      LIMIT 1
    ) block_data ON TRUE
    LEFT JOIN LATERAL(
      SELECT
        amount::lovelace AS as_sum
      FROM
        grest.pool_active_stake_cache AS pasc
      WHERE 
        pasc.pool_id = api.pool_id_bech32
        AND
        pasc.epoch_no = _epoch_no
    ) active_stake ON TRUE
    LEFT JOIN LATERAL(
      SELECT
        amount::lovelace AS es_sum
      FROM
        grest.epoch_active_stake_cache AS easc
      WHERE 
        easc.epoch_no = _epoch_no
    ) epoch_stake ON TRUE
    LEFT JOIN LATERAL(
      SELECT
        CASE WHEN api.pool_status = 'retired'
          THEN NULL
        ELSE
          SUM (
            CASE WHEN total_balance >= 0
              THEN total_balance
              ELSE 0
            END
          )::lovelace
        END AS stake,
        COUNT (stake_address) AS delegators,
        CASE WHEN api.pool_status = 'retired'
          THEN NULL
        ELSE
          SUM (CASE WHEN sdc.stake_address = ANY (api.owners) THEN total_balance ELSE 0 END)::lovelace
        END AS pledge
      FROM
        grest.stake_distribution_cache AS sdc
      WHERE
        sdc.pool_id = api.pool_id_bech32
    ) live ON TRUE;
END;
$$;

COMMENT ON FUNCTION grest.pool_info IS 'Current pool status and details for a specified list of pool ids';
