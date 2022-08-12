CREATE FUNCTION grest.pool_stake_snapshot (_pool_bech32 text)
  RETURNS TABLE (
    snapshot text,
    epoch_no numeric,
    nonce text,
    pool_stake text,
    active_stake text
  )
  LANGUAGE plpgsql
  AS $$
DECLARE
  _epoch_no bigint;
  _mark     bigint;
  _set      bigint;
  _go       bigint;
BEGIN
  SELECT MAX(epoch.no) INTO _epoch_no FROM public.epoch;
  _mark := (_epoch_no-3);
  _set  := (_epoch_no-2);
  _go   := (_epoch_no-1);

  RETURN QUERY
  SELECT
    CASE
      WHEN (pasc.epoch_no = _mark) THEN 'Mark'
      WHEN (pasc.epoch_no = _set)  THEN 'Set'
      ELSE 'Go'
    END AS snapshot,
    eic.epoch_no,
    eic.p_nonce,
    pasc.amount::text,
    easc.amount::text
  FROM
    grest.pool_active_stake_cache pasc
    INNER JOIN grest.epoch_active_stake_cache easc ON easc.epoch_no = pasc.epoch_no
    INNER JOIN grest.epoch_info_cache eic ON eic.epoch_no = pasc.epoch_no
  WHERE
    pasc.pool_id = _pool_bech32
    AND pasc.epoch_no BETWEEN _mark AND _go
  ORDER BY
    pasc.epoch_no;
END;
$$;

COMMENT ON FUNCTION grest.pool_relays IS 'Returns Mark, Set and Go stake snapshots for the selected pool, useful for leaderlog calculation';