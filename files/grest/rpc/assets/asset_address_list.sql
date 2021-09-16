DROP FUNCTION IF EXISTS grest.asset_address_list (text);

CREATE FUNCTION grest.asset_address_list (_asset_identifier text DEFAULT NULL)
  RETURNS TABLE (
    address varchar,
    quantity numeric)
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  RETURN QUERY
  SELECT
    TXO.ADDRESS,
    SUM(MTX.QUANTITY)
  FROM
    MA_TX_OUT MTX
    INNER JOIN TX_OUT TXO ON TXO.ID = MTX.TX_OUT_ID
    LEFT JOIN TX_IN ON TXO.TX_ID = TX_IN.TX_OUT_ID
      AND TXO.INDEX::smallint = TX_IN.TX_OUT_INDEX::smallint
  WHERE
    DECODE(_asset_identifier, 'hex') = MTX.POLICY || MTX.NAME
    AND TX_IN.TX_IN_ID IS NULL
  GROUP BY
    TXO.ADDRESS;
END;
$$;

COMMENT ON FUNCTION grest.asset_address_list IS 'Get the list of all addresses containing a specific asset';

