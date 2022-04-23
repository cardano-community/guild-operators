CREATE FUNCTION grest.asset_policy_info (_asset_policy text)
  RETURNS TABLE (
    asset_name text,
    asset_name_ascii text,
    fingerprint varchar,
    minting_tx_metadata jsonb,
    token_registry_metadata jsonb,
    total_supply text,
    creation_time timestamp without time zone
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _asset_policy_decoded bytea;
  _policy_asset_ids bigint[];
BEGIN
  SELECT DECODE(_asset_policy, 'hex') INTO _asset_policy_decoded;
  SELECT INTO _policy_asset_ids ARRAY_AGG(id) FROM multi_asset MA WHERE MA.policy = _asset_policy_decoded;

  RETURN QUERY (
    WITH
      minting_tx_metadatas AS (
        SELECT DISTINCT ON (MTM.ident)
          MTM.ident,
          JSONB_BUILD_OBJECT(
            'key', TM.key::text,
            'json', TM.json
          ) AS metadata
        FROM
          tx_metadata TM
          INNER JOIN ma_tx_mint MTM on MTM.tx_id = TM.tx_id
        WHERE
          MTM.ident = ANY(_policy_asset_ids)
        ORDER BY
          MTM.ident,
          TM.tx_id ASC
      ),
      token_registry_metadatas AS (
        SELECT DISTINCT ON (asset_policy, asset_name)
          asset_policy,
          ARC.asset_name,
          JSONB_BUILD_OBJECT(
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
          asset_policy = _asset_policy
        ORDER BY
          asset_policy,
          ARC.asset_name
      ),
      total_supplies AS (
        SELECT
          MTM.ident,
          SUM(MTM.quantity)::text AS amount
        FROM
          ma_tx_mint MTM
        WHERE
          MTM.ident = ANY(_policy_asset_ids)
        GROUP BY
          MTM.ident
      ),
      creation_times AS (
        SELECT
          MTM.ident,
          MIN(B.time) AS date
        FROM
          ma_tx_mint MTM
          INNER JOIN tx ON tx.id = MTM.tx_id
          INNER JOIN block B ON B.id = tx.block_id
        WHERE
          MTM.ident = ANY(_policy_asset_ids)
        GROUP BY
          MTM.ident
      )

    SELECT
      ENCODE(MA.name, 'hex') as asset_name,
      ENCODE(MA.name, 'escape') as asset_name_ascii,
      MA.fingerprint as fingerprint,
      mtm.metadata as minting_tx_metadata,
      trm.metadata as token_registry_metadata,
      ts.amount::text as total_supply,
      ct.date
    FROM 
      multi_asset MA
      LEFT JOIN minting_tx_metadatas mtm ON mtm.ident = MA.id
      LEFT JOIN token_registry_metadatas trm ON trm.asset_policy = _asset_policy
        AND DECODE(trm.asset_name, 'hex') = MA.name
      INNER JOIN total_supplies ts on ts.ident = MA.id
      INNER JOIN  creation_times ct ON ct.ident = MA.id
    WHERE
      MA.id = ANY(_policy_asset_ids)
    GROUP BY
      MA.policy,
      MA.name,
      MA.fingerprint,
      MA.id,
      mtm.metadata,
      trm.metadata,
      ts.amount,
      ct.date
  );
END;
$$;

COMMENT ON FUNCTION grest.asset_policy_info IS 'Get the asset information of all assets under a policy';

