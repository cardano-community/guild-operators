DROP FUNCTION IF EXISTS grest.tx_status (_tx_hashes text[]);

CREATE FUNCTION grest.tx_status (_tx_hashes text[])
    RETURNS TABLE (
        tx_hash text,
        num_confirmations integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    _curr_block_no uinteger;
BEGIN
    SELECT
        max(block_no) INTO _curr_block_no
    FROM
        block b;

    RETURN QUERY (
    	select HASHES, (_curr_block_no - b.block_no)
    	from UNNEST(_tx_hashes) WITH ORDINALITY HASHES
    	left outer join tx t on t.hash = DECODE(HASHES, 'hex')
    	left outer join block b on t.block_id = b.id
    	ORDER BY ordinality
    	);
END;
$$;

COMMENT ON FUNCTION grest.tx_status IS 'Returns number of blocks that were created since the block containing a transactions with a given hash';

