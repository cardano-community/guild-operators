CREATE FUNCTION grest.asset_txs (_asset_policy text, _asset_name text default '')
  RETURNS TABLE (
    tx_hash text,
    epoch_no word31type,
    block_height word31type,
    block_time numeric
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
      ENCODE(tx_hashes.hash, 'hex') as tx_hash,
      tx_hashes.epoch_no,
      tx_hashes.block_no,
      EXTRACT(epoch from tx_hashes.time)
    FROM (
      SELECT DISTINCT ON (tx.hash)
        tx.hash,
        block.epoch_no,
        block.block_no,
        block.time
      FROM
        ma_tx_out MTO
        INNER JOIN tx_out TXO ON TXO.id = MTO.tx_out_id
        INNER JOIN tx ON tx.id = TXO.tx_id
        INNER JOIN block ON block.id = tx.block_id
      WHERE
        MTO.ident = _asset_id
      GROUP BY
        ident,
        tx.hash,
        block.epoch_no,
        block.block_no,
        block.time
    ) tx_hashes ORDER BY tx_hashes.block_no DESC;
END;
$$;

COMMENT ON FUNCTION grest.asset_txs IS 'Get the list of all asset transaction hashes (newest first)';
