CREATE FUNCTION grest.credential_txs (_payment_credentials text[], _after_block_height integer DEFAULT 0)
  RETURNS TABLE (
    tx_hash text,
    epoch_no word31type,
    block_height word31type,
    block_time double precision
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _payment_cred_bytea  bytea[];
  _tx_id_list     bigint[];
BEGIN
  -- convert input _payment_credentials array into bytea array
  SELECT INTO _payment_cred_bytea ARRAY_AGG(cred_bytea)
  FROM (
    SELECT
      DECODE(cred_hex, 'hex') AS cred_bytea
    FROM
      UNNEST(_payment_credentials) AS cred_hex
  ) AS tmp;

  -- all tx_out & tx_in tx ids
  SELECT INTO _tx_id_list ARRAY_AGG(tx_id)
  FROM (
    SELECT
      tx_id
    FROM
      tx_out
    WHERE
      payment_cred = ANY (_payment_cred_bytea)
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
      AND tx_out.payment_cred = ANY (_payment_cred_bytea)
  ) AS tmp;

  RETURN QUERY
    SELECT
      DISTINCT(ENCODE(tx.hash, 'hex')) as tx_hash,
      block.epoch_no,
      block.block_no,
      EXTRACT(epoch from block.time)
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

COMMENT ON FUNCTION grest.address_txs IS 'Get the transaction hash list of a payment credentials array, optionally filtering after specified block height (inclusive).';

