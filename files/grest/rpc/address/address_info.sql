DROP FUNCTION IF EXISTS grest.address_info (text);

CREATE FUNCTION grest.address_info (_address text DEFAULT NULL)
  RETURNS TABLE (
    balance text,
    stake_address character varying,
    utxo_set json)
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  RETURN QUERY
  SELECT
    SUM(tx_out.value)::text,
    SA.view,
    JSON_AGG(JSON_BUILD_OBJECT(
    'tx_hash', ENCODE(tx.hash, 'hex'), 
    'tx_index', tx_out.index, 
    'value', tx_out.value::text,
    'asset_list', COALESCE((
      SELECT 
        JSON_AGG(JSON_BUILD_OBJECT(
          'policy_id', ENCODE(MA.policy, 'hex'),
          'asset_name', ENCODE(MA.name, 'hex'),
          'quantity', MTX.quantity::text
          ))
      FROM 
          ma_tx_out MTX
          INNER JOIN multi_asset MA ON MA.id = MTX.ident
      WHERE 
          MTX.tx_out_id = tx_out.id
    ), JSON_BUILD_ARRAY())
  )) utxo_set
  FROM
    public.tx_out
    INNER JOIN public.tx ON tx_out.tx_id = tx.id
    LEFT JOIN public.tx_in ON tx_in.tx_out_id = tx_out.tx_id
      AND tx_in.tx_out_index = tx_out.index
    LEFT JOIN stake_address SA on tx_out.stake_address_id = SA.id
  WHERE
    tx_in.id IS NULL
    AND tx_out.address = _address
  GROUP BY SA.view;
END;
$$;

COMMENT ON FUNCTION grest.address_info IS 'Get address info - balance, associated stake address (if any) and UTXO set';

