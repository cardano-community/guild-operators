CREATE FUNCTION grest.asset_address_list (_asset_policy text, _asset_name text)
  RETURNS TABLE (
    payment_address varchar,
    quantity text
  ) LANGUAGE PLPGSQL
  AS $$
DECLARE
  _asset_policy_decoded bytea;
  _asset_name_decoded bytea;
  _asset_id int;
BEGIN
  SELECT DECODE(_asset_policy, 'hex') INTO _asset_policy_decoded;
  SELECT DECODE(_asset_name, 'hex') INTO _asset_name_decoded;
  SELECT id INTO _asset_id FROM multi_asset MA WHERE MA.policy = _asset_policy_decoded AND MA.name = _asset_name_decoded;

  RETURN QUERY
  SELECT
    TXO.ADDRESS,
    SUM(MTX.QUANTITY)::text
  FROM
    MA_TX_OUT MTX
    INNER JOIN MULTI_ASSET MA ON MA.id = MTX.ident
    INNER JOIN TX_OUT TXO ON TXO.ID = MTX.TX_OUT_ID
    LEFT JOIN TX_IN ON TXO.TX_ID = TX_IN.TX_OUT_ID
      AND TXO.INDEX::smallint = TX_IN.TX_OUT_INDEX::smallint
  WHERE
    MA.id = _asset_id
    AND TX_IN.TX_IN_ID IS NULL
  GROUP BY
    TXO.ADDRESS;
END;
$$;

COMMENT ON FUNCTION grest.asset_address_list IS 'Get the list of all addresses containing a specific asset';

