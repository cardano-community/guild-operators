DROP FUNCTION IF EXISTS grest.address_utxos (text);

CREATE FUNCTION grest.address_utxos (_payment_address text DEFAULT NULL)
    RETURNS TABLE (
        tx_hash text,
        tx_output_index txindex,
        value lovelace)
    LANGUAGE PLPGSQL
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        encode(tx.hash, 'hex') AS tx_hash,
        tx_out.index AS tx_output_index,
        tx_out.value
    FROM
        public.tx_out
        INNER JOIN public.tx ON tx_out.tx_id = tx.id
        LEFT JOIN public.tx_in ON tx_in.tx_out_id = tx_out.tx_id
            AND tx_in.tx_out_index = tx_out.index
    WHERE
        tx_in.id IS NULL
        AND tx_out.address = _payment_address;
END;
$$;

COMMENT ON FUNCTION grest.address_utxos IS 'Get all UTXOs associated with an address';

