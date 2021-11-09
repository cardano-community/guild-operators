DROP TABLE IF EXISTS grest.genesis;

-- Data Types are intentionally kept varchar for single ID row to avoid future edge cases
CREATE TABLE grest.genesis (
  NETWORKMAGIC varchar,
  NETWORKID varchar,
  ACTIVESLOTCOEFF varchar,
  UPDATEQUORUM varchar,
  MAXLOVELACESUPPLY varchar,
  EPOCHLENGTH varchar,
  SYSTEMSTART varchar,
  SLOTSPERKESPERIOD varchar,
  SLOTLENGTH varchar,
  MAXKESREVOLUTIONS varchar,
  SECURITYPARAM varchar,
  ALONZOGENESIS varchar
);

