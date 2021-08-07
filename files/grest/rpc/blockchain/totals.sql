CREATE OR REPLACE FUNCTION grest.totals(_epoch_no numeric default null)
RETURNS JSON STABLE LANGUAGE PLPGSQL AS $$
BEGIN
  IF _epoch_no is NULL THEN
    RETURN (SELECT json_agg(js) json_final FROM
      (SELECT json_build_object(
        'epoch_no', epoch_no,
        'circulation', utxo,
        'treasury', treasury,
        'rewards', rewards,
        'supply', (treasury+rewards+utxo+deposits+fees),
        'reserves', reserves
        ) js
          FROM public.ada_pots ORDER BY epoch_no DESC) t );
  ELSE
    RETURN (SELECT json_agg(js) json_final FROM
      (SELECT json_build_object(
        'epoch_no', epoch_no,
        'circulation', utxo,
        'treasury', treasury,
        'rewards', rewards,
        'supply', (treasury+rewards+utxo+deposits+fees),
        'reserves', reserves
        ) js
          FROM public.ada_pots WHERE epoch_no = _epoch_no ORDER BY epoch_no DESC) t );
  END IF;
END; $$;
COMMENT ON FUNCTION grest.totals IS 'Get the treasury, total active supply in lovelace for specified epoch, all epochs if empty';
