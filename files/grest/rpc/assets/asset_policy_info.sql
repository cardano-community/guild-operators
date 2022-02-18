DROP FUNCTION IF EXISTS grest.asset_policy_info (text);

CREATE FUNCTION grest.asset_policy_info (_asset_policy text)
  RETURNS TABLE (
    policy_id text,
    assets json
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
          JSON_BUILD_OBJECT(
            'key', TM.key,
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
          asset_name,
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
          asset_policy = _asset_policy
        ORDER BY
          asset_policy,
          asset_name
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
      ENCODE(MA.policy, 'hex'),
      JSON_AGG(
        JSON_BUILD_OBJECT(
          'asset_name', ENCODE(MA.name, 'hex'),
          'asset_name_ascii', ENCODE(MA.name, 'escape'),
          'fingerprint', MA.fingerprint,
          'minting_tx_metadata', (
            SELECT
              metadata
            FROM
              minting_tx_metadatas
            WHERE
              minting_tx_metadatas.ident = MA.id
          ),
          'token_registry_metadata', (
            SELECT 
              metadata
            FROM
              token_registry_metadatas
            WHERE
              token_registry_metadatas.asset_policy = _asset_policy
              AND
              DECODE(token_registry_metadatas.asset_name, 'hex') = MA.name
              
          ),
          'total_supply', (
            SELECT
              amount::text
            FROM
              total_supplies
            WHERE
              total_supplies.ident = MA.id
          ),
          'creation_time', (
            SELECT
              date
            FROM
              creation_times
            WHERE
              creation_times.ident = MA.id
          )
        )
      ) AS assets
    FROM 
      multi_asset MA
    WHERE
      MA.id = ANY(_policy_asset_ids)
    GROUP BY
      MA.policy
  );
END;
$$;

COMMENT ON FUNCTION grest.asset_info IS 'Get the asset information of all assets under a policy';

