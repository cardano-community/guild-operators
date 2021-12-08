DROP FUNCTION IF EXISTS grest.script_list ();
CREATE FUNCTION grest.script_list ()
RETURNS TABLE (
    tx_hash text,
    script_hash text
)
LANGUAGE PLPGSQL AS
$$
BEGIN 
RETURN QUERY
SELECT ENCODE(tx.hash, 'hex') as tx_hash,
    ENCODE(script.hash, 'hex') as script_hash
FROM script
    INNER JOIN tx ON tx.id = script.tx_id
WHERE script.type = 'plutus';
END;
$$;

COMMENT ON FUNCTION grest.script_list IS 'Get a list of all script hashes with creation tx hashes.';