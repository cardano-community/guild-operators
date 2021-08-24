DROP FUNCTION IF EXISTS grest.account_assets (text);

CREATE FUNCTION grest.account_assets (_address text DEFAULT NULL)
    RETURNS TABLE (
        asset_policy text,
        asset_name text,
        quantity numeric)
    LANGUAGE PLPGSQL
    AS $$
DECLARE
    SA_ID integer DEFAULT NULL;
BEGIN
    IF _address LIKE 'stake%' THEN
        -- Shelley stake address
        SELECT
            STAKE_ADDRESS.ID INTO SA_ID
        FROM
            STAKE_ADDRESS
        WHERE
            STAKE_ADDRESS.VIEW = _address
        LIMIT 1;
    ELSE
        -- Payment address
        SELECT
            TX_OUT.STAKE_ADDRESS_ID INTO SA_ID
        FROM
            TX_OUT
        WHERE
            TX_OUT.ADDRESS = _address
        LIMIT 1;
    END IF;
    IF SA_ID IS NOT NULL THEN
        RETURN QUERY
        SELECT
            ENCODE(MTX.POLICY::bytea, 'hex') AS asset_policy,
            ENCODE(MTX.NAME::bytea, 'escape') AS asset_name,
            sum(MTX.QUANTITY)
        FROM
            MA_TX_OUT MTX
            INNER JOIN TX_OUT TXO ON TXO.ID = MTX.TX_OUT_ID
                AND TXO.STAKE_ADDRESS_ID = SA_ID
        WHERE
            NOT EXISTS (
                SELECT
                    TX_OUT.ID
                FROM
                    TX_OUT
                    INNER JOIN TX_IN ON TX_OUT.TX_ID = TX_IN.TX_OUT_ID
                        AND TX_OUT.INDEX = TX_IN.TX_OUT_INDEX
                WHERE
                    TXO.ID = TX_OUT.ID)
        GROUP BY
            MTX.POLICY,
            MTX.NAME;
    END IF;
END;
$$;

COMMENT ON FUNCTION grest.account_assets IS 'Get the native asset balance of an account';

