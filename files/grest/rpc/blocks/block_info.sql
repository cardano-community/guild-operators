CREATE FUNCTION grest.block_info (_block_hashes text[])
  RETURNS TABLE (
    hash text,
    epoch_no uinteger,
    abs_slot uinteger,
    epoch_slot uinteger,
    block_height uinteger,
    block_size uinteger,
    block_time double precision,
    tx_count bigint,
    vrf_key varchar,
    op_cert text,
    op_cert_counter word63type,
    pool varchar,
    total_output text,
    total_fees text,
    num_confirmations integer,
    parent_hash text,
    child_hash text
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _block_hashes_bytea   bytea[];
  _block_id_list        bigint[];
  _curr_block_no        uinteger;
BEGIN
  SELECT max(block_no) INTO _curr_block_no FROM block b;

  -- convert input _block_hashes array into bytea array
  SELECT INTO _block_hashes_bytea ARRAY_AGG(hashes_bytea)
  FROM (
    SELECT
      DECODE(hashes_hex, 'hex') AS hashes_bytea
    FROM
      UNNEST(_block_hashes) AS hashes_hex
  ) AS tmp;

  -- all block ids
  SELECT INTO _block_id_list ARRAY_AGG(id)
  FROM (
    SELECT
      id
    FROM 
      block
    WHERE block.hash = ANY (_block_hashes_bytea)
  ) AS tmp;

  RETURN QUERY
  SELECT
    ENCODE(B.hash, 'hex') AS hash,
    B.epoch_no AS epoch,
    B.slot_no AS abs_slot,
    B.epoch_slot_no AS epoch_slot,
    B.block_no AS block_height,
    B.size AS block_size,
    EXTRACT(epoch from B.time) AS block_time,
    B.tx_count,
    B.vrf_key,
    ENCODE(B.op_cert::bytea, 'hex') as op_cert,
    B.op_cert_counter,
    PH.view AS pool,
    block_data.total_output::text,
    block_data.total_fees::text,
    (_curr_block_no - B.block_no) AS num_confirmations,
    (
      SELECT
        ENCODE(tB.hash::bytea, 'hex')
      FROM
        block tB
      WHERE
        id = b.id - 1
    ) AS parent_hash,
    (
      SELECT
        ENCODE(tB.hash::bytea, 'hex')
      FROM
        block tB
      WHERE
        id = b.id + 1
    ) AS child_hash
  FROM
    block B
    LEFT JOIN slot_leader SL ON SL.id = B.slot_leader_id
    LEFT JOIN pool_hash PH ON PH.id = SL.pool_hash_id
    LEFT JOIN LATERAL (
      SELECT
        SUM(tx_data.total_output) AS total_output,
        SUM(tx.fee) AS total_fees
      FROM
        tx
        JOIN LATERAL (
          SELECT
            SUM(tx_out.value) AS total_output
          FROM
            tx_out
          WHERE
            tx_out.tx_id = tx.id
        ) tx_data ON TRUE
      WHERE
        tx.block_id = b.id
    ) block_data ON TRUE
  WHERE
    B.id = ANY (_block_id_list)
    AND B.block_no IS NOT NULL;
END;
$$;

COMMENT ON FUNCTION grest.block_info IS 'Get detailed information about list of block hashes';

