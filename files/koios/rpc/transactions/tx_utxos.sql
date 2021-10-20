DROP FUNCTION IF EXISTS koios.tx_utxos (text[]);

CREATE FUNCTION koios.tx_utxos (_tx_hashes text[])
  RETURNS TABLE (
    tx_hash text,
    inputs json,
    outputs json)
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  RETURN QUERY
  SELECT
    T1.tx_hash,
    INPUTS_T.inputs,
    OUTPUTS_T.outputs
  FROM (
    SELECT
      tx.id,
      ENCODE(tx.hash, 'hex') as tx_hash
    FROM
      public.tx
    WHERE
      tx.hash::bytea = ANY (
        SELECT
          DECODE(hashes, 'hex')
        FROM
          UNNEST(_tx_hashes) AS hashes)) T1
  LEFT JOIN LATERAL (
    SELECT
      JSON_AGG(JSON_BUILD_OBJECT('index', tx_out.index, 'address', tx_out.address, 'value', tx_out.value)) as outputs
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
      tx_out
      INNER JOIN tx_in ON tx_out.tx_id = tx_in.tx_out_id
      INNER JOIN tx ON tx.id = tx_in.tx_in_id
        AND tx_in.tx_out_index = tx_out.index
    WHERE
      tx_in_id = T1.id
    GROUP BY
      tx_in_id) INPUTS_T ON TRUE;
END;
$$;

COMMENT ON FUNCTION koios.tx_utxos IS 'Get UTXO set (inputs/outputs) of transactions.';

