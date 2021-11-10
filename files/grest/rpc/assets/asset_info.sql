DROP FUNCTION IF EXISTS grest.asset_info (text, text);

CREATE FUNCTION grest.asset_info (_asset_policy text, _asset_name_hex text)
  RETURNS TABLE (
    policy_id_hex text,
    asset_name_hex text,
    asset_name_escaped text,
    minting_tx_metadata jsonb,
    token_registry_metadata jsonb,
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
    DECODE(_asset_name_hex, 'hex') INTO _asset_name_decoded;
  --
  RETURN QUERY WITH
  --
  asset_txs AS (
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
    _asset_policy as asset_policy,
    _asset_name_hex as asset_name_hex,
    ENCODE(_asset_name_decoded, 'escape') as asset_name_escaped,
    creation_t.minting_tx_metadata,
    token_registry.metadata,
    supply_t.total_supply,
    tx_t.total_transactions,
    registered_wallets_t.registered_wallets + unregistered_wallets_t.unregistered_wallets,
    creation_t.creation_time
  FROM (
    SELECT
      SUM(COALESCE(asset_utxos.quantity, 0)) as total_supply
    FROM
      asset_utxos) supply_t
  LEFT JOIN (
    SELECT
      COUNT(DISTINCT (asset_txs.tx_id)) as total_transactions
    FROM
      asset_txs
      -- Excluding minting transactions
      LEFT JOIN MA_TX_MINT MTM ON MTM.TX_ID = asset_txs.id
    WHERE
      MTM.ID is null) tx_t ON TRUE
  LEFT JOIN (
    SELECT
      COUNT(DISTINCT (sa.id)) as registered_wallets
    from
      asset_utxos
      INNER JOIN STAKE_ADDRESS SA ON SA.id = asset_utxos.STAKE_ADDRESS_ID) registered_wallets_t ON TRUE
  LEFT JOIN (
    SELECT
      COUNT(DISTINCT (asset_utxos.address)) as unregistered_wallets
    from
      asset_utxos
      LEFT JOIN STAKE_ADDRESS SA ON SA.id = asset_utxos.STAKE_ADDRESS_ID
    WHERE
      SA.ID IS NULL) unregistered_wallets_t ON TRUE
  LEFT JOIN (
    SELECT
      JSONB_BUILD_OBJECT(ENCODE(TX.hash, 'hex'), JSONB_BUILD_OBJECT(COALESCE(CAST(TXM.key as varchar), 'null'), TXM.json)) as minting_tx_metadata,
      b.time as creation_time
    FROM
      asset_txs
      INNER JOIN MA_TX_MINT MTM ON MTM.TX_ID = asset_txs.TX_ID
      INNER JOIN TX ON TX.ID = MTM.TX_ID
      INNER JOIN BLOCK B ON B.id = TX.block_id
      LEFT JOIN TX_METADATA TXM ON TX.ID = TXM.TX_ID
    ORDER BY
      TX.ID ASC
    LIMIT 1) creation_t ON TRUE;
  LEFT JOIN (
    SELECT
      JSONB_BUILD_OBJECT(
        'name', ARC.name,
        'description', ARC.description,
        'ticker', ARC.ticker,
        'url', ARC.url,
        'logo', ARC.logo,
        'decimals', ARC.decimals,
      ) as metadata
    FROM
      grest.asset_registry_cache ARC
    WHERE
      ARC.asset_policy = _asset_policy_decoded
      AND 
      ARC.asset_name = _asset_name_decoded
    LIMIT 1) token_registry ON TRUE;
END;
$$;

COMMENT ON FUNCTION grest.asset_info IS 'Get the summary of an asset (total transactions exclude minting/total wallets include only wallets with asset balance)';

