--------------------------------------------------------------------------------
-- Pool active stake cache setup
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS GREST.POOL_ACTIVE_STAKE_CACHE (
  POOL_ID varchar NOT NULL,
  EPOCH_NO bigint NOT NULL,
  AMOUNT LOVELACE NOT NULL,
  PRIMARY KEY (POOL_ID, EPOCH_NO)
);

INSERT INTO GREST.POOL_ACTIVE_STAKE_CACHE
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

-- Trigger for inserting new pool active stake values on epoch transition
DROP FUNCTION IF EXISTS GREST.POOL_ACTIVE_STAKE_EPOCH_UPDATE CASCADE;

CREATE FUNCTION GREST.POOL_ACTIVE_STAKE_EPOCH_UPDATE ()
  RETURNS TRIGGER
  AS $pool_active_stake_epoch_update$
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
      grest.POOL_ACTIVE_STAKE_CACHE
    SET
      amount = amount + NEW.amount
    WHERE
      pool_id = _pool_id_bech32
      AND epoch_no = NEW.epoch_no;
    EXIT insert_update
    WHEN found;
    BEGIN
      INSERT INTO grest.POOL_ACTIVE_STAKE_CACHE (pool_id, epoch_no, amount)
        VALUES (_pool_id_bech32, NEW.epoch_no, NEW.amount);
      EXIT insert_update;
    EXCEPTION
      WHEN UNIQUE_VIOLATION THEN
        RAISE NOTICE 'Unique violation for pool: %, epoch: %', _pool_id_bech32, NEW.epoch_no;
    END;
  END LOOP
    insert_update;
    RETURN NULL;
END;

$pool_active_stake_epoch_update$
LANGUAGE PLPGSQL;

DROP TRIGGER IF EXISTS POOL_ACTIVE_STAKE_EPOCH_UPDATE_TRIGGER ON PUBLIC.EPOCH_STAKE;

CREATE TRIGGER POOL_ACTIVE_STAKE_EPOCH_UPDATE_TRIGGER
  AFTER INSERT ON PUBLIC.EPOCH_STAKE
  FOR EACH ROW
  EXECUTE FUNCTION GREST.POOL_ACTIVE_STAKE_EPOCH_UPDATE ();

--------------------------------------------------------------------------------
-- Epoch total active stake cache setup
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS GREST.EPOCH_ACTIVE_STAKE_CACHE (
  EPOCH_NO bigint NOT NULL,
  AMOUNT LOVELACE NOT NULL,
  PRIMARY KEY (EPOCH_NO)
);

INSERT INTO GREST.EPOCH_ACTIVE_STAKE_CACHE
SELECT
  EPOCH_STAKE.EPOCH_NO,
  SUM(EPOCH_STAKE.AMOUNT) AS AMOUNT
FROM
  EPOCH_STAKE
GROUP BY
  EPOCH_STAKE.EPOCH_NO
ON CONFLICT (EPOCH_NO)
  DO UPDATE SET
    AMOUNT = EXCLUDED.AMOUNT;

-- Trigger for inserting new epoch active stake totals on epoch transition
DROP FUNCTION IF EXISTS GREST.EPOCH_ACTIVE_STAKE_EPOCH_UPDATE CASCADE;

CREATE FUNCTION GREST.EPOCH_ACTIVE_STAKE_EPOCH_UPDATE ()
  RETURNS TRIGGER
  AS $epoch_active_stake_epoch_update$
BEGIN
  -- Insert or update cache table
  << insert_update >> LOOP
    UPDATE
      grest.EPOCH_ACTIVE_STAKE_CACHE
    SET
      amount = amount + NEW.amount
    WHERE
      epoch_no = NEW.epoch_no;
    EXIT insert_update
    WHEN found;
    BEGIN
      INSERT INTO grest.EPOCH_ACTIVE_STAKE_CACHE (epoch_no, amount)
        VALUES (NEW.epoch_no, NEW.amount);
      EXIT insert_update;
    EXCEPTION
      WHEN UNIQUE_VIOLATION THEN
        RAISE NOTICE 'Unique violation for epoch: %', NEW.epoch_no;
    END;
  END LOOP
    insert_update;
    RETURN NULL;
END;

$epoch_active_stake_epoch_update$
LANGUAGE PLPGSQL;

DROP TRIGGER IF EXISTS EPOCH_ACTIVE_STAKE_EPOCH_UPDATE_TRIGGER ON PUBLIC.EPOCH_STAKE;

CREATE TRIGGER EPOCH_ACTIVE_STAKE_EPOCH_UPDATE_TRIGGER
  AFTER INSERT ON PUBLIC.EPOCH_STAKE
  FOR EACH ROW
  EXECUTE FUNCTION GREST.EPOCH_ACTIVE_STAKE_EPOCH_UPDATE ();

