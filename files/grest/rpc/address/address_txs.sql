DROP FUNCTION IF EXISTS grest.address_txs (text[], integer);

CREATE FUNCTION grest.address_txs (_addresses text[], _after_block_height integer DEFAULT NULL)
  RETURNS TABLE (
    tx_hash text)
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  IF _after_block_height IS NOT NULL THEN
    RETURN QUERY
    SELECT
      DISTINCT(ENCODE(tx.hash, 'hex')) as tx_hash
    FROM
      public.tx_out
      INNER JOIN public.tx ON tx_out.tx_id = tx.id
      INNER JOIN public.block ON block.id = tx.block_id
    WHERE
      tx_out.address = ANY (_addresses)
      AND block.block_no >= _after_block_height;
  ELSE
    RETURN QUERY
    SELECT
      DISTINCT(ENCODE(tx.hash, 'hex')) as tx_hash
    FROM
      public.tx_out
      INNER JOIN public.tx ON tx_out.tx_id = tx.id
    WHERE
      tx_out.address = ANY (_addresses);
  END IF;
END;
$$;

COMMENT ON FUNCTION grest.address_txs IS 'Get the transaction hash list of a Cardano address array, optionally filtering after specified block height (inclusive).';

