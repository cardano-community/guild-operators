CREATE TABLE IF NOT EXISTS koios.ACTIVE_STAKE_CACHE (
  POOL_ID varchar NOT NULL,
  EPOCH_NO bigint NOT NULL,
  AMOUNT LOVELACE NOT NULL,
  PRIMARY KEY (POOL_ID, EPOCH_NO)
);

INSERT INTO koios.ACTIVE_STAKE_CACHE
SELECT
  POOL_HASH.VIEW,
  EPOCH_STAKE.EPOCH_NO,
  SUM(EPOCH_STAKE.AMOUNT) AS AMOUNT
FROM
  EPOCH_STAKE
  INNER JOIN POOL_HASH ON POOL_HASH.ID = EPOCH_STAKE.POOL_ID
GROUP BY
  POOL_HASH.VIEW,
  EPOCH_STAKE.EPOCH_NO
ON CONFLICT (POOL_ID,
  EPOCH_NO)
  DO UPDATE SET
    AMOUNT = EXCLUDED.AMOUNT;

-- Trigger for inserting new epoch active stake data
DROP FUNCTION IF EXISTS koios.ACTIVE_STAKE_EPOCH_UPDATE CASCADE;

CREATE FUNCTION koios.ACTIVE_STAKE_EPOCH_UPDATE ()
  RETURNS TRIGGER
  AS $active_stake_epoch_update$
DECLARE
  _pool_id_bech32 varchar;
BEGIN
  SELECT
    ph.view
  FROM
    pool_hash ph
  WHERE
    ph.id = NEW.pool_id INTO _pool_id_bech32;
  -- Insert or update cache table
  << insert_update >> LOOP
    UPDATE
      koios.ACTIVE_STAKE_CACHE
    SET
      amount = amount + NEW.amount
    WHERE
      pool_id = _pool_id_bech32
      AND epoch_no = NEW.epoch_no;
    EXIT insert_update
    WHEN found;
    BEGIN
      INSERT INTO koios.ACTIVE_STAKE_CACHE (pool_id, epoch_no, amount)
        VALUES (_pool_id_bech32, NEW.epoch_no, NEW.amount);
      EXIT insert_update;
    EXCEPTION
      WHEN UNIQUE_VIOLATION THEN
        RAISE NOTICE 'Unique violation for : % %', _pool_id_bech32, NEW.epoch_no;
    END;
  END LOOP
    insert_update;
    RETURN NULL;
END;

$active_stake_epoch_update$
LANGUAGE PLPGSQL;

DROP TRIGGER IF EXISTS ACTIVE_STAKE_EPOCH_UPDATE_TRIGGER ON PUBLIC.EPOCH_STAKE;

CREATE TRIGGER ACTIVE_STAKE_EPOCH_UPDATE_TRIGGER
  AFTER INSERT ON PUBLIC.EPOCH_STAKE
  FOR EACH ROW
  EXECUTE FUNCTION koios.ACTIVE_STAKE_EPOCH_UPDATE ();

