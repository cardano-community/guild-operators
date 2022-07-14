CREATE FUNCTION grest.asset_info (_asset_policy text, _asset_name text default '')
  RETURNS TABLE (
    policy_id text,
    asset_name text,
    asset_name_ascii text,
    fingerprint character varying,
    minting_tx_hash text,
    total_supply text,
    mint_cnt bigint,
    burn_cnt bigint,
    creation_time integer,
    minting_tx_metadata json,
    token_registry_metadata json
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _asset_policy_decoded bytea;
  _asset_name_decoded bytea;
  _asset_id int;
BEGIN
  SELECT DECODE(_asset_policy, 'hex') INTO _asset_policy_decoded;
  SELECT DECODE(
    CASE WHEN _asset_name IS NULL
      THEN ''
    ELSE
      _asset_name
    END,
    'hex'
  ) INTO _asset_name_decoded;
  SELECT id INTO _asset_id FROM multi_asset MA WHERE MA.policy = _asset_policy_decoded AND MA.name = _asset_name_decoded;

  RETURN QUERY
  SELECT
    _asset_policy,
    _asset_name,
    ENCODE(_asset_name_decoded, 'escape'),
    MA.fingerprint,
    (
      SELECT
        ENCODE(tx.hash, 'hex')
      FROM
        ma_tx_mint MTM
        INNER JOIN tx ON tx.id = MTM.tx_id
      WHERE
        MTM.ident = _asset_id
      ORDER BY
        MTM.tx_id ASC
      LIMIT 1
    ) AS tx_hash,
    minting_data.total_supply,
    minting_data.mint_cnt,
    minting_data.burn_cnt,
    EXTRACT(epoch from minting_data.date)::integer,
    (
      SELECT
        JSON_BUILD_OBJECT(
          'key', TM.key::text,
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
    ) AS token_registry_metadata
  FROM 
    multi_asset MA
    LEFT JOIN LATERAL (
      SELECT
        MIN(B.time) AS date,
        SUM(MTM.quantity)::text AS total_supply,
        SUM(CASE WHEN quantity > 0 then 1 else 0 end) AS mint_cnt,
        SUM(CASE WHEN quantity < 0 then 1 else 0 end) AS burn_cnt
      FROM
        ma_tx_mint MTM
        INNER JOIN tx ON tx.id = MTM.tx_id
        INNER JOIN block B ON B.id = tx.block_id
      WHERE
        MTM.ident = MA.id
    ) minting_data ON TRUE
  WHERE
    MA.id = _asset_id;
END;
$$;

COMMENT ON FUNCTION grest.asset_info IS 'Get the information of an asset incl first minting & token registry metadata';

