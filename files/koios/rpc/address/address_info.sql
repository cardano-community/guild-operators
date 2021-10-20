DROP FUNCTION IF EXISTS koios.address_info (text);

CREATE FUNCTION koios.address_info (_payment_address text DEFAULT NULL)
  RETURNS TABLE (
    balance numeric,
    stake_address text,
    utxo_set json)
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _stake_address text default NULL;
  _stake_address_id bigint default NULL;
BEGIN
  SELECT
    stake_address_id
  FROM
    tx_out
  WHERE
    address = _payment_address
  LIMIT 1 INTO _stake_address_id;
  IF _stake_address_id IS NOT NULL THEN
    SELECT
      view
    FROM
      stake_address
    WHERE
      id = _stake_address_id INTO _stake_address;
  END IF;
  RETURN QUERY
  SELECT
    SUM(tx_out.value),
    _stake_address,
    JSON_AGG(JSON_BUILD_OBJECT('tx_hash', ENCODE(tx.hash, 'hex'), 'tx_index', tx_out.index, 'value', tx_out.value)) utxo_set
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

COMMENT ON FUNCTION koios.address_info IS 'Get payment address info - balance, associated stake address (if any) and UTXO set';

