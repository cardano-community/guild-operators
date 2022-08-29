CREATE FUNCTION grest.address_txs (_addresses text[], _after_block_height integer DEFAULT 0)
  RETURNS TABLE (
    tx_hash text,
    epoch_no word31type,
    block_height word31type,
    block_time integer
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _tx_id_list bigint[];
BEGIN
  -- all tx_out & tx_in tx ids
  SELECT INTO _tx_id_list ARRAY_AGG(tx_id)
  FROM (
    SELECT
      tx_id
    FROM
      tx_out
    WHERE
      address = ANY (_addresses)
    --
    UNION
    --
    SELECT
      tx_in_id AS tx_id
    FROM
      tx_out
      LEFT JOIN tx_in ON tx_out.tx_id = tx_in.tx_out_id
        AND tx_out.index = tx_in.tx_out_index
    WHERE
      tx_in.tx_in_id IS NOT NULL
      AND tx_out.address = ANY (_addresses)
  ) AS tmp;

  RETURN QUERY
    SELECT
      DISTINCT(ENCODE(tx.hash, 'hex')) as tx_hash,
      block.epoch_no,
      block.block_no,
      EXTRACT(epoch from block.time)::integer
    FROM
      public.tx
      INNER JOIN public.block ON block.id = tx.block_id
    WHERE
      tx.id = ANY (_tx_id_list)
      AND block.block_no >= _after_block_height
    ORDER BY
      block.block_no DESC;
END;
$$;

COMMENT ON FUNCTION grest.address_txs IS 'Get the transaction hash list of a Cardano address array, optionally filtering after specified block height (inclusive).';

