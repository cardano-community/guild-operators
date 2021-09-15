DROP FUNCTION IF EXISTS grest.asset_address_list (text);

CREATE FUNCTION grest.asset_address_list (_asset_identifier text DEFAULT NULL)
    RETURNS TABLE (
        address varchar,
        quantity numeric)
    LANGUAGE PLPGSQL
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        TXO.ADDRESS,
        sum(MTX.QUANTITY)
    FROM
        MA_TX_OUT MTX
        INNER JOIN TX_OUT TXO ON TXO.ID = MTX.TX_OUT_ID
    WHERE
        DECODE(_asset_identifier, 'hex') = MTX.POLICY || MTX.NAME
        AND NOT EXISTS (
            SELECT
                TX_OUT.ID
            FROM
                TX_OUT
                INNER JOIN TX_IN ON TX_OUT.TX_ID = TX_IN.TX_OUT_ID
                    AND TX_OUT.INDEX = TX_IN.TX_OUT_INDEX
            WHERE
                TXO.ID = TX_OUT.ID)
    GROUP BY
        TXO.ADDRESS;
END;
$$;

COMMENT ON FUNCTION grest.asset_address_list IS 'Get the list of all addresses containing a specific asset';

