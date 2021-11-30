DROP FUNCTION IF EXISTS grest.credential_txs (text[], integer);

CREATE FUNCTION grest.credential_txs (_payment_credentials text[], _after_block_height integer DEFAULT NULL)
  RETURNS TABLE (
    tx_hash text)
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _payment_cred_bytea  bytea[];
  _addresses           text[];
BEGIN
  -- convert input _payment_credentials array into bytea array
  SELECT INTO _payment_cred_bytea ARRAY_AGG(cred_bytea)
  FROM (
    SELECT
      DECODE(cred_hex, 'hex') AS cred_bytea
    FROM
      UNNEST(_payment_credentials) AS cred_hex
  ) AS tmp;

  -- all used base/enterprise addresses
  SELECT INTO _addresses ARRAY_AGG(address)
  FROM (
    SELECT DISTINCT ON (address) address
    FROM tx_out
    WHERE payment_cred = ANY (_payment_cred_bytea)
  ) AS tmp;

  IF _after_block_height IS NOT NULL THEN
    RETURN QUERY
    SELECT
      DISTINCT ON (tx.hash) ENCODE(tx.hash, 'hex') as tx_hash
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
      DISTINCT ON (tx.hash) ENCODE(tx.hash, 'hex') as tx_hash
    FROM
      public.tx_out
      INNER JOIN public.tx ON tx_out.tx_id = tx.id
    WHERE
      tx_out.address = ANY (_addresses);
  END IF;
END;
$$;

COMMENT ON FUNCTION grest.address_txs IS 'Get the transaction hash list of a payment credentials array, optionally filtering after specified block height (inclusive).';

