DROP FUNCTION IF EXISTS grest.address_assets (_address text);

CREATE FUNCTION grest.address_assets (_address text)
  RETURNS TABLE (
    asset_policy_hex text,
    asset_name_hex text,
    quantity text)
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  return QUERY
  select
    ENCODE(MA.policy, 'hex') as hex_policy,
    ENCODE(MA.name, 'escape') escaped_name,
    mtx.quantity::text
  from
    MA_TX_OUT MTX
    INNER JOIN MULTI_ASSET MA ON MA.id = MTX.ident
    inner join TX_OUT TXO on TXO.ID = MTX.TX_OUT_ID
    left join TX_IN on TXO.TX_ID = TX_IN.TX_OUT_ID
      and TXO.INDEX::smallint = TX_IN.TX_OUT_INDEX::smallint
  where
    txo.address = _address
    and TX_IN.TX_IN_ID is null;
END;
$$;

COMMENT ON FUNCTION grest.address_assets IS 'Get the list of all the assets (policy, name and quantity) for a given address';

