DROP FUNCTION IF EXISTS grest.script_redeemers (_script_hash text);

CREATE FUNCTION grest.script_redeemers (_script_hash text) 
RETURNS TABLE (
    script_hash text,
    redeemers json
) 
LANGUAGE PLPGSQL AS 
$$
DECLARE _script_hash_bytea bytea;
BEGIN
SELECT INTO _script_hash_bytea DECODE(_script_hash, 'hex');
RETURN QUERY
select _script_hash,
    JSON_AGG(
        JSON_BUILD_OBJECT(
            'tx_hash',
            ENCODE(tx.hash, 'hex'),
            'tx_index',
            redeemer.index,
            'unit_mem',
            redeemer.unit_mem,
            'unit_steps',
            redeemer.unit_steps,
            'fee',
            redeemer.fee::text,
            'purpose',
            redeemer.purpose,
            'datum_hash',
            ENCODE(datum.hash, 'hex'),
            'datum_value',
            datum.value
        )
    ) as redeemers
FROM redeemer
    INNER JOIN TX ON tx.id = redeemer.tx_id
    INNER JOIN DATUM on datum.id = redeemer.datum_id
WHERE redeemer.script_hash = _script_hash_bytea
GROUP BY redeemer.script_hash;
END;
$$;

COMMENT ON FUNCTION grest.script_redeemers IS 'Get all redeemers for a given script hash.';