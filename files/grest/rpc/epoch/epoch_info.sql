DROP FUNCTION IF EXISTS grest.epoch_info (numeric);

CREATE FUNCTION grest.epoch_info (_epoch_no numeric DEFAULT NULL)
  RETURNS TABLE (
    epoch_no uinteger,
    out_sum text,
    fees text,
    tx_count uinteger,
    blk_count uinteger,
    first_block_time timestamp without time zone,
    last_block_time timestamp without time zone,
    active_stake text)
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  IF _epoch_no IS NULL THEN
    RETURN QUERY
    SELECT
      ei.epoch_no,
      ei.i_out_sum::text AS tx_output_sum,
      ei.i_fees::text AS tx_fees_sum,
      ei.i_tx_count AS tx_count,
      ei.i_blk_count AS blk_count,
      ei.i_first_block_time AS first_block_time,
      ei.i_last_block_time AS last_block_time,
      eas.amount::text AS active_stake
    FROM
      grest.epoch_info_cache ei
      INNER JOIN grest.EPOCH_ACTIVE_STAKE_CACHE eas ON eas.epoch_no = ei.epoch_no
    ORDER BY
      ei.epoch_no DESC;
  ELSE
    RETURN QUERY
    SELECT
      ei.epoch_no,
      ei.i_out_sum::text AS tx_output_sum,
      ei.i_fees::text AS tx_fees_sum,
      ei.i_tx_count AS tx_count,
      ei.i_blk_count AS blk_count,
      ei.i_first_block_time AS first_block_time,
      ei.i_last_block_time AS last_block_time,
      eas.amount::text AS active_stake
    FROM
      grest.epoch_info_cache ei
      INNER JOIN grest.EPOCH_ACTIVE_STAKE_CACHE eas ON eas.epoch_no = ei.epoch_no
    WHERE
      ei.epoch_no = _epoch_no;
  END IF;
END;
$$;

COMMENT ON FUNCTION grest.epoch_info IS 'Get the epoch information, all epochs if no epoch specified';

