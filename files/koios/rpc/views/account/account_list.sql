DROP VIEW IF EXISTS koios.account_list;

CREATE VIEW koios.account_list AS
SELECT
  STAKE_ADDRESS.VIEW AS ID
FROM
  STAKE_ADDRESS;

COMMENT ON VIEW koios.account_list IS 'Get a list of all accounts';

