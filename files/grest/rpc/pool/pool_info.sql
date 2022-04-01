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
    retiring_epoch uinteger,
    op_cert text,
    op_cert_counter word63type,
    active_stake text,
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
  SELECT epoch.no INTO _epoch_no FROM public.epoch ORDER BY epoch.no DESC LIMIT 1;

  SELECT FLOOR(supply::bigint / (
      SELECT p_optimal_pool_count 
      FROM grest.epoch_info_cache
      WHERE epoch_no = _epoch_no
    ))::bigint INTO _saturation_limit FROM grest.totals(_epoch_no);

  RETURN QUERY
  SELECT DISTINCT ON (pic.pool_id_bech32)
    pic.pool_id_bech32,
    pic.pool_id_hex,
    pic.active_epoch_no,
    pic.vrf_key_hash,
    pic.margin,
    pic.fixed_cost::text,
    pic.pledge::text,
    pic.reward_addr,
    pic.owners,
    pic.relays,
    pic.meta_url,
    pic.meta_hash,
    pod.json,
    pic.pool_status,
    pic.retiring_epoch,
    ENCODE(block_data.op_cert::bytea, 'hex'),
    block_data.op_cert_counter,
    active_stake.as_sum::text,
    block_data.cnt,
    live.pledge::text,
    live.stake::text,
    live.delegators,
    ROUND((live.stake / _saturation_limit) * 100, 2)
  FROM
    grest.pool_info_cache AS pic
  LEFT JOIN
    public.pool_offline_data AS pod ON pod.pmr_id = pic.meta_id
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
      sl.pool_hash_id = pic.pool_hash_id
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
      grest.pool_active_stake_cache AS easc
    WHERE 
      easc.pool_id = pic.pool_id_bech32
      AND
      easc.epoch_no = _epoch_no
  ) active_stake ON TRUE
  LEFT JOIN LATERAL(
    SELECT
      CASE WHEN pic.pool_status = 'retired'
        THEN NULL
      ELSE
        SUM (total_balance)::lovelace
      END AS stake,
      COUNT (stake_address) AS delegators,
      SUM (CASE WHEN sdc.stake_address = ANY (pic.owners) THEN total_balance ELSE 0 END)::lovelace AS pledge
    FROM
      grest.stake_distribution_cache AS sdc
    WHERE
      sdc.pool_id = pic.pool_id_bech32
  ) live ON TRUE
  WHERE
    pic.pool_id_bech32 = ANY(SELECT UNNEST(_pool_bech32_ids))
  ORDER BY
    pic.pool_id_bech32,
    pic.tx_id DESC;
END;
$$;

COMMENT ON FUNCTION grest.pool_info IS 'Current pool status and details for a specified list of pool ids';
