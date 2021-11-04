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
		WITH matched_txs AS (
            SELECT
                t.hash, b.block_no FROM block b, tx t
            WHERE
                t.hash::bytea = ANY (
                    SELECT
                        DECODE(HASHES, 'hex')
                FROM UNNEST(_tx_hashes) AS hashes)
        AND t.block_id = b.id)

	-- returns difference in block numbers, or null if tx was not found
	SELECT 
		HASHES, (_curr_block_no - m.block_no)
    FROM 
		UNNEST(_tx_hashes) WITH ORDINALITY HASHES
    LEFT OUTER JOIN 
		matched_txs m ON m.hash = DECODE(HASHES, 'hex')
	ORDER BY ORDINALITY);
END;
$$;

COMMENT ON FUNCTION grest.tx_status IS 'Returns number of blocks that were created since the block containing a transactions with a given hash';

