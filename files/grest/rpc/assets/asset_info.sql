DROP FUNCTION IF EXISTS grest.asset_info (text, text);

CREATE FUNCTION grest.asset_info (_asset_policy text, _asset_name text)
  RETURNS TABLE (
    policy_id text,
    asset_name text,
    asset_name_ascii text,
    fingerprint character varying,
    minting_tx_metadata json,
    token_registry_metadata json,
    total_supply numeric,
    creation_time timestamp without time zone)
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
  SELECT
    _asset_policy,
    _asset_name,
    ENCODE(_asset_name_decoded, 'escape'),
    MA.fingerprint,
    (
      SELECT
        JSON_BUILD_OBJECT(
          'key', TM.key,
          'json', TM.json
        )
      FROM
        tx_metadata TM
        INNER JOIN ma_tx_mint MTM on MTM.tx_id = TM.tx_id
      WHERE
        MTM.ident = _asset_id
      ORDER BY
        TM.tx_id ASC
      LIMIT 1
    ) AS minting_tx_metadata,
    (
      SELECT
        JSON_BUILD_OBJECT(
          'name', ARC.name,
          'description', ARC.description,
          'ticker', ARC.ticker,
          'url', ARC.url,
          'logo', ARC.logo,
          'decimals', ARC.decimals
        ) as metadata
      FROM
        grest.asset_registry_cache ARC
      WHERE
        ARC.asset_policy = _asset_policy
        AND 
        ARC.asset_name = _asset_name
      LIMIT 1
    ) AS token_registry_metadata,
    (
      SELECT
        SUM(MTM.quantity) AS amount
      FROM
        ma_tx_mint MTM
      WHERE
        MTM.ident = _asset_id
    ) AS total_supply,
    (
      SELECT
        MIN(B.time) AS date
      FROM
        ma_tx_mint MTM
        INNER JOIN tx ON tx.id = MTM.tx_id
        INNER JOIN block B ON B.id = tx.block_id
      WHERE
        MTM.ident = _asset_id
    ) AS creation_time
  FROM 
    multi_asset MA
  WHERE
    MA.id = _asset_id;
END;
$$;

COMMENT ON FUNCTION grest.asset_info IS 'Get the information of an asset incl first minting & token registry metadata';

