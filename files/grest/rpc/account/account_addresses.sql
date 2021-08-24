DROP FUNCTION IF EXISTS grest.account_addresses (text);

CREATE FUNCTION grest.account_addresses (_address text DEFAULT NULL)
    RETURNS TABLE (
        address varchar)
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
        RETURN QUERY SELECT DISTINCT
            TX_OUT.address
        FROM
            TX_OUT
        WHERE
            TX_OUT.STAKE_ADDRESS_ID = SA_ID;
    END IF;
END;
$$;

COMMENT ON FUNCTION grest.account_addresses IS 'Get all addresses associated with an account';

