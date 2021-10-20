DROP VIEW IF EXISTS koios.tx_metalabels;

CREATE VIEW koios.tx_metalabels AS SELECT DISTINCT
  key as metalabel
FROM
  public.tx_metadata;

COMMENT ON VIEW koios.tx_metalabels IS 'Get a list of all transaction metalabels';

