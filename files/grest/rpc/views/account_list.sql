CREATE VIEW grest.account_list AS
    SELECT
        STAKE_ADDRESS.VIEW AS ID
    FROM
        STAKE_ADDRESS;

COMMENT ON VIEW grest.account_list IS 'Get a list of all accounts';

