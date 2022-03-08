CREATE FUNCTION grest.asset_txs (_asset_policy text, _asset_name text)
  RETURNS TABLE (
    policy_id text,
    asset_name text,
    tx_hashes text[]
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
    SELECT
      _asset_policy,
      _asset_name,
      array_agg(
        ENCODE(tx_hashes.hash, 'hex')
          ORDER BY tx_hashes.id DESC
      )
    FROM (
      SELECT DISTINCT ON (tx.hash)
        tx.id,
        tx.hash
      FROM
        ma_tx_out MTO
        INNER JOIN tx_out TXO ON TXO.id = MTO.tx_out_id
        INNER JOIN tx ON tx.id = TXO.tx_id
      WHERE
        MTO.ident = _asset_id
      GROUP BY
        ident,
        tx.id
    ) tx_hashes;
END;
$$;

COMMENT ON FUNCTION grest.asset_txs IS 'Get the list of all asset transaction hashes (newest first)';
