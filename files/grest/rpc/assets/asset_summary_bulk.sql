DROP FUNCTION IF EXISTS grest.asset_summary_bulk (text);

-- Search by policy id? explore options
CREATE FUNCTION grest.asset_summary_bulk (_asset_policy text)
  RETURNS TABLE (
    asset_name text,
    total_supply numeric,
    total_transactions bigint,
    total_wallets bigint,
    creation_time timestamp without time zone)
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _asset_policy_decoded bytea;
BEGIN
  SELECT
    DECODE(_asset_policy, 'hex') INTO _asset_policy_decoded;
  --
  RETURN QUERY
  --
  WITH asset_names AS (
    SELECT
      MTM.name
    FROM
      MA_TX_MINT MTM
    WHERE
      policy = _asset_policy_decoded),
      asset_txs AS (SELECT TXO.*,
      asset_names.name as asset_name,
      MTX.quantity
    FROM
      MA_TX_OUT MTX
      INNER JOIN TX_OUT TXO ON TXO.ID = MTX.TX_OUT_ID
      INNER JOIN asset_names on asset_names.name = MTX.name
        AND MTX.policy = _asset_policy_decoded),
        asset_utxos AS (
          SELECT
            asset_txs.*
          FROM
            asset_txs
        LEFT JOIN TX_IN ON asset_txs.TX_ID = TX_IN.TX_OUT_ID
          AND asset_txs.INDEX::smallint = TX_IN.TX_OUT_INDEX::smallint
      WHERE
        TX_IN.TX_IN_ID IS NULL),
        asset_minting_txs AS (
          SELECT
            asset_txs.*
          FROM
            asset_txs
            INNER JOIN MA_TX_MINT MTM ON MTM.TX_ID = asset_txs.TX_ID)
          SELECT
            creation_t.asset_name, supply_t.total_supply, tx_t.total_transactions, wallets_t.total_wallets, creation_t.creation_time
          FROM (
            SELECT
              asset_utxos.asset_name, SUM(COALESCE(asset_utxos.quantity, 0)) as total_supply
              FROM
                asset_utxos
              GROUP BY
                asset_utxos.asset_name) supply_t
        LEFT JOIN (
          SELECT
            asset_txs.asset_name, COUNT(*) as total_transactions
            FROM
              asset_txs
              -- Excluding minting txs in total count
              -- If excluded: LEFT JOIN asset_minting_txs ON asset_minting_txs.id = asset_txs.id
              -- If excluded: WHERE
              -- If excluded: asset_minting_txs.id is null
            GROUP BY
              asset_txs.asset_name) tx_t ON tx_t.asset_name = supply_t.asset_name
      LEFT JOIN (
        SELECT
          asset_utxos.asset_name, COUNT(DISTINCT (sa.id)) as total_wallets
          from
            asset_utxos
            INNER JOIN TX_OUT TXO ON TXO.ID = asset_utxos.id
            INNER JOIN STAKE_ADDRESS SA ON SA.id = TXO.STAKE_ADDRESS_ID
          GROUP BY
            asset_utxos.asset_name) wallets_t ON wallets_t.asset_name = tx_t.asset_name
    LEFT JOIN (
      SELECT
        DISTINCT ON (asset_name)
          b.time as creation_time, ENCODE(asset_minting_txs.asset_name, 'escape') as asset_name
          FROM
            asset_minting_txs
            INNER JOIN TX ON TX.ID = asset_minting_txs.TX_ID
            INNER JOIN BLOCK B ON B.id = TX.block_id
          ORDER BY
            asset_name, b.time ASC) creation_t ON TRUE;
END;
$$;

COMMENT ON FUNCTION grest.asset_summary_bulk IS 'Get the summary of all assets under the same policy';

