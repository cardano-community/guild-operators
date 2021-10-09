DROP FUNCTION IF EXISTS grest.tx_info (text[]);

CREATE FUNCTION grest.tx_info (_tx_hashes text[])
  RETURNS TABLE (
    tx_hash text,
    block_hash text,
    block_height uinteger,
    epoch uinteger,
    epoch_slot uinteger,
    absolute_slot uinteger,
    tx_timestamp timestamp without time zone,
    tx_block_index uinteger,
    fee lovelace,
    deposit bigint,
    inputs json,
    outputs json,
    invalid_before word64type,
    invalid_after word64type --,
    -- TODO: certificate_type,
    -- TODO: certificate_info
)
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  RETURN QUERY
  SELECT
    T1.tx_hash,
    T1.block_hash,
    T1.block_height,
    T1.epoch,
    T1.epoch_slot,
    T1.absolute_slot,
    T1.tx_timestamp,
    T1.tx_block_index,
    T1.fee,
    T1.deposit,
    INPUTS_T.inputs,
    OUTPUTS_T.outputs,
    T1.invalid_before,
    T1.invalid_after --,
    -- TODO: certificate_type,
    -- TODO: certificate_info
  FROM (
    SELECT
      tx.id,
      ENCODE(tx.hash, 'hex') as tx_hash,
      ENCODE(b.hash, 'hex') as block_hash,
      b.block_no as block_height,
      b.epoch_no as epoch,
      b.epoch_slot_no as epoch_slot,
      b.slot_no as absolute_slot,
      b.time as tx_timestamp,
      tx.block_index as tx_block_index,
      tx.fee,
      tx.deposit,
      tx.invalid_before,
      tx.invalid_hereafter as invalid_after
    FROM
      public.tx
      INNER JOIN public.block b ON b.id = tx.block_id
    WHERE
      tx.hash::bytea = ANY (
        SELECT
          DECODE(hashes, 'hex')
        FROM
          UNNEST(_tx_hashes) AS hashes)) T1
  LEFT JOIN LATERAL (
    SELECT
      JSON_AGG(JSON_BUILD_OBJECT('index', index, 'address', address, 'value', value)) as outputs
      FROM
        tx_out
      WHERE
        tx_id = T1.id
      GROUP BY
        tx_id) OUTPUTS_T ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      JSON_AGG(JSON_BUILD_OBJECT('index', tx_out.index, 'address', tx_out.address, 'value', tx_out.value)) as inputs
    FROM
      tx_in
      INNER JOIN tx_out ON tx_out.id = tx_in.tx_out_id
    WHERE
      tx_in_id = T1.id
    GROUP BY
      tx_id) INPUTS_T ON TRUE;
END;
$$;

COMMENT ON FUNCTION grest.tx_info IS 'Get information about transactions.';

