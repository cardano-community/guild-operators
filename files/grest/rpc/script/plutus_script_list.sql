DROP FUNCTION IF EXISTS grest.plutus_script_list ();
CREATE FUNCTION grest.plutus_script_list ()
RETURNS TABLE (
    script_hash text,
    creation_tx_hash text
)
LANGUAGE PLPGSQL AS
$$
BEGIN 
RETURN QUERY
SELECT 
    ENCODE(script.hash, 'hex') as script_hash, 
    ENCODE(tx.hash, 'hex') as creation_tx_hash
FROM script
    INNER JOIN tx ON tx.id = script.tx_id
WHERE script.type = 'plutus';
END;
$$;

COMMENT ON FUNCTION grest.plutus_script_list IS 'Get a list of all plutus script hashes with creation tx hash.';
