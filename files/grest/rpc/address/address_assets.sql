CREATE FUNCTION grest.address_assets (_addresses text[])
  RETURNS TABLE (
    address varchar,
    asset_list json
  )
  LANGUAGE PLPGSQL
  AS $$
BEGIN
  RETURN QUERY

  WITH _all_assets AS (
    SELECT
      txo.address,
      ma.policy,
      ma.name,
      ma.fingerprint,
      SUM(mtx.quantity) as quantity
    FROM
      MA_TX_OUT MTX
      INNER JOIN MULTI_ASSET MA ON MA.id = MTX.ident
      INNER JOIN TX_OUT TXO ON TXO.ID = MTX.TX_OUT_ID
      LEFT JOIN TX_IN ON TXO.TX_ID = TX_IN.TX_OUT_ID
        AND TXO.INDEX::smallint = TX_IN.TX_OUT_INDEX::smallint
    WHERE
      TXO.address = ANY(_addresses)
      AND TX_IN.TX_IN_ID IS NULL
    GROUP BY
      TXO.address, MA.policy, MA.name, ma.fingerprint
  )

  SELECT
    assets_grouped.address,
    assets_grouped.asset_list
  FROM (
    SELECT
      aa.address,
      JSON_AGG(
        JSON_BUILD_OBJECT(
          'policy_id', ENCODE(aa.policy, 'hex'),
          'asset_name', ENCODE(aa.name, 'hex'),
          'fingerprint', aa.fingerprint,
          'quantity', aa.quantity::text
        )
      ) as asset_list
    FROM 
      _all_assets aa
    GROUP BY
      aa.address
  ) assets_grouped;
END;
$$;

COMMENT ON FUNCTION grest.address_assets IS 'Get the list of all the assets (policy, name and quantity) for given addresses';

