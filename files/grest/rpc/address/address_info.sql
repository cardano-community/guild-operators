CREATE FUNCTION grest.address_info (_addresses text[])
  RETURNS TABLE (
    address varchar,
    balance text,
    stake_address character varying,
    script_address boolean,
    utxo_set json
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  known_addresses varchar[];
BEGIN

  CREATE TEMPORARY TABLE _known_addresses AS
    SELECT
      DISTINCT ON (tx_out.address) tx_out.address,
      sa.view as stake_address,
      COALESCE(tx_out.address_has_script, 'false') as script_address
    FROM
      tx_out
      LEFT JOIN stake_address SA on sa.id = tx_out.stake_address_id
    WHERE
      tx_out.address = ANY(_addresses)
  ;

  RETURN QUERY
    WITH _all_utxos AS (
      SELECT
        tx.id,
        tx.hash,
        tx_out.id as txo_id,
        tx_out.address,
        tx_out.value,
        tx_out.index,
        tx.block_id,
        tx_out.data_hash,
        tx_out.inline_datum_id,
        tx_out.reference_script_id
      FROM
        tx_out
        LEFT JOIN tx_in ON tx_in.tx_out_id = tx_out.tx_id
          AND tx_in.tx_out_index = tx_out.index
        INNER JOIN tx ON tx.id = tx_out.tx_id
      WHERE
        tx_in.id IS NULL
        AND
        tx_out.address = ANY(_addresses)
    )

      SELECT
        ka.address,
        COALESCE(SUM(au.value), '0')::text AS balance,
        ka.stake_address,
        ka.script_address,
        CASE WHEN EXISTS (
          SELECT TRUE FROM _all_utxos aus WHERE aus.address = ka.address
        ) THEN
          JSON_AGG(
            JSON_BUILD_OBJECT(
              'tx_hash', ENCODE(au.hash, 'hex'), 
              'tx_index', au.index,
              'block_height', block.block_no,
              'block_time', EXTRACT(epoch from block.time)::integer,
              'value', au.value::text,
              'datum_hash', ENCODE(au.data_hash, 'hex'),
              'inline_datum', ( CASE WHEN au.inline_datum_id IS NULL THEN NULL
                ELSE
                  JSONB_BUILD_OBJECT(
                    'bytes', ENCODE(datum.bytes, 'hex'),
                    'value', datum.value
                  )
                END
              ),
              'reference_script', ( CASE WHEN au.reference_script_id IS NULL THEN NULL
                ELSE
                  JSONB_BUILD_OBJECT(
                    'hash', ENCODE(script.hash, 'hex'),
                    'bytes', ENCODE(script.bytes, 'hex'),
                    'value', script.json,
                    'type', script.type::text,
                    'size', script.serialised_size
                  )
                END
              ),
              'asset_list', COALESCE(
                (
                  SELECT
                    JSON_AGG(JSON_BUILD_OBJECT(
                      'policy_id', ENCODE(MA.policy, 'hex'),
                      'asset_name', ENCODE(MA.name, 'hex'),
                      'fingerprint', MA.fingerprint,
                      'quantity', MTX.quantity::text
                      ))
                  FROM
                      ma_tx_out MTX
                      INNER JOIN multi_asset MA ON MA.id = MTX.ident
                  WHERE
                      MTX.tx_out_id = au.txo_id
                ),
                JSON_BUILD_ARRAY()
              )
            )
          )
        ELSE
          '[]'::json
        END as utxo_set
      FROM
        _known_addresses ka
        LEFT OUTER JOIN _all_utxos au ON au.address = ka.address
        LEFT JOIN public.block ON block.id = au.block_id
        LEFT JOIN datum ON datum.id = au.inline_datum_id
        LEFT JOIN script ON script.id = au.reference_script_id
      GROUP BY
        ka.address, ka.stake_address, ka.script_address
      ;
    DROP TABLE _known_addresses;
END;
$$;

COMMENT ON FUNCTION grest.address_info IS 'Get bulk address info - balance, associated stake address (if any) and UTXO set';
