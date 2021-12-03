DROP FUNCTION IF EXISTS grest.tx_utxos (text[]);

CREATE FUNCTION grest.tx_utxos (_tx_hashes text[])
  RETURNS TABLE (
    tx_hash text,
    inputs json,
    outputs json
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _tx_hashes_bytea  bytea[];
  _tx_id_list       bigint[];
BEGIN
  -- convert input _tx_hashes array into bytea array
  SELECT INTO _tx_hashes_bytea ARRAY_AGG(hashes_bytea)
  FROM (
    SELECT
      DECODE(hashes_hex, 'hex') AS hashes_bytea
    FROM
      UNNEST(_tx_hashes) AS hashes_hex
  ) AS tmp;

  -- all tx ids
  SELECT INTO _tx_id_list ARRAY_AGG(id)
  FROM (
    SELECT
      id
    FROM 
      tx
    WHERE tx.hash = ANY (_tx_hashes_bytea)
  ) AS tmp;

  RETURN QUERY (
    WITH

      -- tx id / hash mapping
      _all_tx AS (
        SELECT
          tx.id AS tx_id,
          tx.hash AS tx_hash
        FROM
          tx
        WHERE tx.id = ANY (_tx_id_list)
      ),

      _all_outputs AS (
        SELECT
          tx_id,
          JSON_AGG(t_outputs) AS list
        FROM (
          SELECT 
            tx_out.tx_id,
            JSON_BUILD_OBJECT(
              'payment_addr', JSON_BUILD_OBJECT(
                'bech32', tx_out.address,
                'cred', ENCODE(tx_out.payment_cred, 'hex')
              ),
              'stake_addr', SA.view,
              'tx_hash', ENCODE(_all_tx.tx_hash, 'hex'),
              'tx_index', tx_out.index,
              'value', tx_out.value,
              'asset_list', COALESCE((
                SELECT
                  JSON_AGG(JSON_BUILD_OBJECT(
                    'policy_id', ENCODE(MTX.policy, 'hex'),
                    'asset_name', ENCODE(MTX.name, 'hex'),
                    'quantity', MTX.quantity
                  ))
                FROM 
                  ma_tx_out MTX
                WHERE 
                  MTX.tx_out_id = tx_out.id
              ), JSON_BUILD_ARRAY())
            ) AS t_outputs
          FROM
            tx_out
            INNER JOIN _all_tx ON tx_out.tx_id = _all_tx.tx_id
            LEFT JOIN stake_address SA on tx_out.stake_address_id = SA.id
          WHERE 
            tx_out.tx_id = ANY (_tx_id_list)
        ) AS tmp

        GROUP BY tx_id
        ORDER BY tx_id
      ),

      _all_inputs AS (
        SELECT
          tx_id,
          JSON_AGG(t_inputs) AS list
        FROM (
          SELECT 
            tx_in.tx_in_id AS tx_id,
            JSON_BUILD_OBJECT(
              'payment_addr', JSON_BUILD_OBJECT(
                'bech32', tx_out.address,
                'cred', ENCODE(tx_out.payment_cred, 'hex')
              ),
              'stake_addr', SA.view,
              'tx_hash', ENCODE(tx.hash, 'hex'),
              'tx_index', tx_out.index,
              'value', tx_out.value,
              'asset_list', COALESCE((
                SELECT 
                  JSON_AGG(JSON_BUILD_OBJECT(
                    'policy_id', ENCODE(MTX.policy, 'hex'),
                    'asset_name', ENCODE(MTX.name, 'hex'),
                    'quantity', MTX.quantity
                  ))
                FROM 
                  ma_tx_out MTX
                WHERE 
                  MTX.tx_out_id = tx_out.id
              ), JSON_BUILD_ARRAY())
            ) AS t_inputs
          FROM
            tx_in
            INNER JOIN tx_out ON tx_out.tx_id = tx_in.tx_out_id
              AND tx_out.index = tx_in.tx_out_index
            INNER JOIN tx on tx_out.tx_id = tx.id
            LEFT JOIN stake_address SA on tx_out.stake_address_id = SA.id
          WHERE 
            tx_in.tx_in_id = ANY (_tx_id_list)
        ) AS tmp

        GROUP BY tx_id
        ORDER BY tx_id
      )

    SELECT
      ENCODE(ATX.tx_hash, 'hex'),
      COALESCE(AI.list, JSON_BUILD_ARRAY()),
      COALESCE(AO.list, JSON_BUILD_ARRAY())
    FROM
      _all_tx ATX
      LEFT JOIN _all_inputs AI ON AI.tx_id = ATX.tx_id
      LEFT JOIN _all_outputs AO ON AO.tx_id = ATX.tx_id
    WHERE ATX.tx_hash = ANY (_tx_hashes_bytea)
);

END;
$$;

COMMENT ON FUNCTION grest.tx_utxos IS 'Get UTXO set (inputs/outputs) of transactions.';

