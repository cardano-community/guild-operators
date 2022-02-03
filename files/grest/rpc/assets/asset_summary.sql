DROP FUNCTION IF EXISTS grest.asset_summary (text, text);

CREATE FUNCTION grest.asset_summary (_asset_policy text, _asset_name text)
  RETURNS TABLE (
    policy_id text,
    asset_name text,
    total_transactions bigint,
    staked_wallets bigint,
    unstaked_addresses bigint
  )
  LANGUAGE PLPGSQL
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
  with _asset_utxos as (
    SELECT
      TXO.tx_id AS tx_id,
      TXO.id AS tx_out_id,
      TXO.index AS tx_out_idx,
      TXO.address AS address,
      TXO.stake_address_id AS sa_id
    FROM
      ma_tx_out MTO
      INNER JOIN tx_out TXO ON TXO.id = MTO.tx_out_id
      LEFT JOIN tx_in TXI ON TXI.tx_out_id = TXO.tx_id
    WHERE
      MTO.ident = _asset_id
      AND
      TXI.tx_out_id IS NULL)

  SELECT
    _asset_policy,
    _asset_name,
    (
      SELECT
        COUNT(DISTINCT(TXO.tx_id))
      FROM
        ma_tx_out MTO
        INNER JOIN tx_out TXO ON TXO.id = MTO.tx_out_id
      WHERE
        ident = _asset_id
    ) AS total_transactions,
    (
      SELECT
        COUNT(DISTINCT(_asset_utxos.sa_id))
      FROM
        _asset_utxos
      WHERE
        _asset_utxos.sa_id IS NOT NULL
    ) AS staked_wallets,
    (
      SELECT
        COUNT(DISTINCT(_asset_utxos.address))
      FROM
        _asset_utxos
      WHERE
        _asset_utxos.sa_id IS NULL
    ) AS unstaked_addresses
  FROM 
    multi_asset MA
  WHERE
    MA.id = _asset_id;
END;
$$;

COMMENT ON FUNCTION grest.asset_summary IS 'Get the summary of an asset (total transactions exclude minting/total wallets include only wallets with asset balance)';
