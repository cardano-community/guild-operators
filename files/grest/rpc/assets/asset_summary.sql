DROP FUNCTION IF EXISTS grest.asset_summary (text, text);

-- Search by policy id? explore options
CREATE FUNCTION grest.asset_summary (_asset_policy text, _asset_name text)
  RETURNS TABLE (
    policy_id text,
    asset_name text,
    total_supply numeric,
    total_transactions bigint,
    total_wallets bigint,
    creation_time timestamp without time zone)
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _asset_policy_decoded bytea;
  _asset_name_decoded bytea;
BEGIN
  SELECT
    DECODE(_asset_policy, 'hex') INTO _asset_policy_decoded;
  SELECT
    DECODE(_asset_name::text, 'escape') INTO _asset_name_decoded;
  --
  RETURN QUERY
  --
  WITH asset_tx_ids AS (
    SELECT
      TX.ID
    FROM
      MA_TX_OUT MTX
      INNER JOIN TX_OUT TXO ON TXO.ID = MTX.TX_OUT_ID
      INNER JOIN TX ON TXO.TX_ID = TX.ID
    WHERE
      MTX.policy = _asset_policy_decoded
      AND MTX.name = _asset_name_decoded
),
asset_utxo_ids AS (
  SELECT
    asset_tx_ids.ID
  FROM
    asset_tx_ids
    INNER JOIN TX_OUT TXO ON TXO.TX_ID = asset_tx_ids.id
    LEFT JOIN TX_IN ON TXO.TX_ID = TX_IN.TX_OUT_ID
      AND TXO.INDEX::smallint = TX_IN.TX_OUT_INDEX::smallint
  WHERE
    TX_IN.TX_IN_ID IS NULL)
  --
  SELECT
    _asset_policy,
    _asset_name,
    supply_t.total_supply,
    tx_t.total_transactions,
    wallets_t.total_wallets,
    creation_t.creation_time
  FROM (
    SELECT
      SUM(COALESCE(MTX.quantity, 0)) as total_supply
    FROM
      MA_TX_OUT MTX
      INNER JOIN TX_OUT TXO ON TXO.ID = MTX.TX_OUT_ID
      INNER JOIN asset_tx_ids ON asset_tx_ids.id = TXO.TX_ID
      LEFT JOIN TX_IN ON TXO.TX_ID = TX_IN.TX_OUT_ID
        AND TXO.INDEX::smallint = TX_IN.TX_OUT_INDEX::smallint
    WHERE
      TXO.TX_ID = asset_tx_ids.id
      AND TX_IN.TX_IN_ID IS NULL) supply_t
  LEFT JOIN (
    SELECT
      COUNT(*) as total_transactions
    from
      asset_tx_ids
      LEFT JOIN MA_TX_MINT MTM ON MTM.TX_ID = asset_tx_ids.id
    WHERE
      MTM.ID is null) tx_t ON TRUE
  LEFT JOIN (
    SELECT
      COUNT(DISTINCT (sa.id)) as total_wallets
    from
      asset_utxo_ids
      INNER JOIN TX_OUT TXO ON TXO.ID = asset_utxo_ids.id
      INNER JOIN STAKE_ADDRESS SA ON SA.id = TXO.STAKE_ADDRESS_ID) wallets_t ON TRUE
  LEFT JOIN (
    SELECT
      b.time as creation_time
    FROM
      MA_TX_MINT MTM
      INNER JOIN TX ON TX.ID = MTM.TX_ID
      INNER JOIN BLOCK B ON B.id = TX.block_id
    WHERE
      MTM.policy = _asset_policy_decoded
      AND MTM.name = _asset_name_decoded
    ORDER BY
      TX.ID ASC
    LIMIT 1) creation_t ON TRUE;
END;
$$;

COMMENT ON FUNCTION grest.asset_summary IS 'Get the summary of an asset
 (total transactions exclude minting/total wallets includes only wallets with some balance)';

