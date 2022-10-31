CREATE FUNCTION grest.account_assets (_stake_addresses text[])
  RETURNS TABLE (
    stake_address varchar,
    asset_list json
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  sa_id_list integer[];
BEGIN
  SELECT INTO sa_id_list
    ARRAY_AGG(STAKE_ADDRESS.ID)
  FROM
    STAKE_ADDRESS
  WHERE
    STAKE_ADDRESS.VIEW = ANY(_stake_addresses);

  RETURN QUERY
    WITH _all_assets AS (
      SELECT
        sa.view,
        ma.policy,
        ma.name,
        ma.fingerprint,
        SUM(mtx.quantity) as quantity
      FROM
        MA_TX_OUT MTX
        INNER JOIN MULTI_ASSET MA ON MA.id = MTX.ident
        INNER JOIN TX_OUT TXO ON TXO.ID = MTX.TX_OUT_ID
        INNER JOIN STAKE_ADDRESS sa ON sa.id = TXO.stake_address_id
        LEFT JOIN TX_IN on TXO.TX_ID = TX_IN.TX_OUT_ID
          AND TXO.INDEX::smallint = TX_IN.TX_OUT_INDEX::smallint
      WHERE
        sa.id = ANY(sa_id_list)
        AND TX_IN.TX_IN_ID IS NULL
      GROUP BY
        sa.view, MA.policy, MA.name, MA.fingerprint
    )

  SELECT
    assets_grouped.view as stake_address,
    assets_grouped.assets
  FROM (
    SELECT
      aa.view,
      JSON_AGG(
        JSON_BUILD_OBJECT(
          'policy_id', ENCODE(aa.policy, 'hex'),
          'asset_name', ENCODE(aa.name, 'hex'),
          'fingerprint', aa.fingerprint,
          'quantity', aa.quantity::text
        )
      ) as assets
    FROM 
      _all_assets aa
    GROUP BY
      aa.view
  ) assets_grouped;
END;
$$;

COMMENT ON FUNCTION grest.account_assets IS 'Get the native asset balance of given accounts';

