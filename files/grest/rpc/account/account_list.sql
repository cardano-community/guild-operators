DROP FUNCTION IF EXISTS grest.account_list (text);

CREATE FUNCTION grest.account_list ()
    RETURNS TABLE (
        id varchar)
    LANGUAGE PLPGSQL
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        STAKE_ADDRESS.VIEW
    FROM
        STAKE_ADDRESS;
END;
$$;

COMMENT ON FUNCTION grest.account_list IS 'Get a list of all accounts';

