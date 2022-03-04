DROP FUNCTION IF EXISTS grest.epoch_info (numeric);

CREATE FUNCTION grest.epoch_info (_epoch_no numeric DEFAULT NULL)
  RETURNS TABLE (
    epoch_no uinteger,
    out_sum text,
    fees text,
    tx_count uinteger,
    blk_count uinteger,
    start_time timestamp without time zone,
    end_time timestamp without time zone,
    first_block_time timestamp without time zone,
    last_block_time timestamp without time zone,
    active_stake text)
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  shelley_epoch_duration numeric := (select epochlength::numeric * slotlength::numeric as epochduration from grest.genesis);
  shelley_ref_epoch numeric := (select (ep.epoch_no::numeric + 1) from epoch_param ep ORDER BY ep.epoch_no LIMIT 1);
  shelley_ref_time timestamp := (select ei.i_first_block_time from grest.epoch_info_cache ei where ei.epoch_no = shelley_ref_epoch);
BEGIN
  RETURN QUERY
  SELECT
    ei.epoch_no,
    ei.i_out_sum::text AS tx_output_sum,
    ei.i_fees::text AS tx_fees_sum,
    ei.i_tx_count AS tx_count,
    ei.i_blk_count AS blk_count,
    CASE WHEN ei.epoch_no < shelley_ref_epoch THEN
        ei.i_first_block_time
      ELSE
        (shelley_ref_time + ((ei.epoch_no - shelley_ref_epoch) * shelley_epoch_duration)::text::interval)
      END AS start_time,
    CASE WHEN ei.epoch_no < shelley_ref_epoch THEN
        ei.i_first_block_time::timestamp + shelley_epoch_duration::text::interval
      ELSE
        (shelley_ref_time + (((ei.epoch_no+1) - shelley_ref_epoch) * shelley_epoch_duration)::text::interval)
    END AS end_time,
    ei.i_first_block_time AS first_block_time,
    ei.i_last_block_time AS last_block_time,
    eas.amount::text AS active_stake
  FROM
    grest.epoch_info_cache ei
    LEFT JOIN grest.EPOCH_ACTIVE_STAKE_CACHE eas ON eas.epoch_no = ei.epoch_no
  WHERE
    ei.epoch_no::text LIKE CASE WHEN _epoch_no IS NULL THEN '%' ELSE _epoch_no::text END;
END;
$$;

COMMENT ON FUNCTION grest.epoch_info IS 'Get the epoch information, all epochs if no epoch specified';

