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
  WITH asset_txs AS (
    SELECT
      TXO.*,
      MTX.quantity
    FROM
      MA_TX_OUT MTX
      INNER JOIN TX_OUT TXO ON TXO.ID = MTX.TX_OUT_ID
    WHERE
      MTX.policy = _asset_policy_decoded
      AND MTX.name = _asset_name_decoded
),
asset_utxos AS (
  SELECT
    asset_txs.*
  FROM
    asset_txs
    LEFT JOIN TX_IN ON asset_txs.TX_ID = TX_IN.TX_OUT_ID
      AND asset_txs.INDEX::smallint = TX_IN.TX_OUT_INDEX::smallint
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
      SUM(COALESCE(asset_utxos.quantity, 0)) as total_supply
    FROM
      asset_utxos) supply_t
  LEFT JOIN (
    SELECT
      COUNT(*) as total_transactions
    FROM
      asset_txs
      -- Excluding minting transactions
      LEFT JOIN MA_TX_MINT MTM ON MTM.TX_ID = asset_txs.id
    WHERE
      MTM.ID is null) tx_t ON TRUE
  LEFT JOIN (
    SELECT
      COUNT(DISTINCT (sa.id)) as total_wallets
    from
      asset_utxos
      INNER JOIN STAKE_ADDRESS SA ON SA.id = asset_utxos.STAKE_ADDRESS_ID) wallets_t ON TRUE
  LEFT JOIN (
    SELECT
      b.time as creation_time
    FROM
      asset_txs
      INNER JOIN MA_TX_MINT MTM ON MTM.TX_ID = asset_txs.TX_ID
      INNER JOIN TX ON TX.ID = MTM.TX_ID
      INNER JOIN BLOCK B ON B.id = TX.block_id
    ORDER BY
      TX.ID ASC
    LIMIT 1) creation_t ON TRUE;
END;
$$;

COMMENT ON FUNCTION grest.asset_summary IS 'Get the summary of an asset (total transactions exclude minting/total wallets include only wallets with asset balance)';

